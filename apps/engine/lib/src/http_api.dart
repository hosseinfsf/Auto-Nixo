/// Local HTTP API (shelf) + TradingView webhook endpoint.
///
/// The webhook endpoint responds 200 IMMEDIATELY and processes asynchronously
/// (TradingView cancels after 3 seconds).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'db.dart';
import 'pipeline.dart' as pipe;
import 'telegram/telegram_source.dart';

class HttpApi {
  HttpApi({
    required this.host,
    required this.port,
    required this.token,
    required this.db,
    required this.pipeline,
    this.webhookToken = '',
    this.webhookPassphrase = '',
    this.webDir = 'web',
  });

  final String host;
  final int port;
  final String token;
  final Database db;
  final pipe.Pipeline pipeline;
  final String webhookToken;
  final String webhookPassphrase;
  final String webDir;

  HttpServer? _server;
  final _router = Router();

  Future<void> start() async {
    // Liveness probe: intentionally unauthenticated (no data exposed) so the
    // launcher and health checks work before any token is configured.
    _router.get('/health', (Request req) {
      return Response.ok(jsonEncode({'ok': true, 'engine': 'running'}),
          headers: {'content-type': 'application/json'});
    });

    _router.get('/status', (Request req) {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      return Response.ok(jsonEncode(_status()), headers: {'content-type': 'application/json'});
    });

    // Dashboard configuration endpoints (persisted in the settings table).
    _router.get('/roulette', (Request req) {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      return _json(_rouletteSettings());
    });

    _router.post('/roulette', (Request req) async {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      db.setSetting('roulette_enabled', body['enabled'] == true ? '1' : '0');
      db.setSetting('roulette_base_risk_pct', '${body['base_risk_pct'] ?? 0.5}');
      db.setSetting('roulette_max_risk_pct', '${body['max_risk_pct'] ?? 5.0}');
      db.setSetting('roulette_trigger_pct', '${body['trigger_pct'] ?? 3.0}');
      db.setSetting('roulette_max_steps', '${body['max_steps'] ?? 50}');
      db.audit('info', 'roulette settings updated');
      return _json({'ok': true});
    });

    _router.get('/mt5', (Request req) {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      return _json({
        'terminal_path': db.getSetting('mt5_terminal_path') ?? '',
        'account': db.getSetting('mt5_account') ?? '',
        'server': db.getSetting('mt5_server') ?? '',
        'dry_run': db.getSetting('mt5_dry_run') == '1',
      });
    });

    _router.post('/mt5', (Request req) async {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      db.setSetting('mt5_terminal_path', '${body['terminal_path'] ?? ''}');
      db.setSetting('mt5_account', '${body['account'] ?? ''}');
      db.setSetting('mt5_server', '${body['server'] ?? ''}');
      db.setSetting('mt5_dry_run', body['dry_run'] == true ? '1' : '0');
      db.audit('info', 'mt5 settings updated');
      return _json({'ok': true});
    });

    _router.post('/mt5/test', (Request req) async {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      try {
        final account = await pipeline.executor.account();
        return _json({'ok': true, 'equity': account.equity});
      } catch (e) {
        return _json({'ok': false, 'error': '$e'});
      }
    });

    _router.get('/activity', (Request req) {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      final rows = db.listAudit(limit: 50);
      return _json(rows);
    });

    _router.get('/inputs', (Request req) {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      return Response.ok(jsonEncode(db.listInputs()), headers: {'content-type': 'application/json'});
    });

    _router.post('/inputs', (Request req) async {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      db.upsertInput(body);
      return Response.ok(jsonEncode({'ok': true}), headers: {'content-type': 'application/json'});
    });

    // TradingView webhook: secret path token.
    _router.post('/tv/$webhookToken', (Request req) async {
      // Respond 200 immediately, process async.
      unawaited(_processWebhook(req));
      return Response.ok('ok');
    });

    _router.get('/kill', (Request req) {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      // Kill switch: stop intake. (Engine listens to this via a callback.)
      _killCallback?.call();
      return Response.ok(jsonEncode({'ok': true, 'kill': true}),
          headers: {'content-type': 'application/json'});
    });

    // Static dashboard assets are public (they contain no secrets); every
    // data endpoint above still requires the bearer token.
    _router.get('/', (Request req) => _serveStatic(req, ''));
    _router.get('/<file|.*>', (Request req, String file) {
      return _serveStatic(req, file);
    });

    final handler = Pipeline().addMiddleware(_logMiddleware()).addHandler(_router.call);
    _server = await shelf_io.serve(handler, host, port);
  }

  void Function()? _killCallback;
  set onKill(void Function() cb) => _killCallback = cb;

  bool _authorized(Request req) {
    final auth = req.headers['authorization'];
    return auth == 'Bearer $token';
  }

  Future<void> _processWebhook(Request req) async {
    try {
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      // Passphrase check.
      if (webhookPassphrase.isNotEmpty &&
          body['passphrase'] != webhookPassphrase) {
        return;
      }
      final symbol = body['symbol'] as String? ?? '';
      final side = body['side'] as String? ?? '';
      final entry = body['entry'];
      final sl = body['sl'];
      final tp1 = body['tp1'];
      final tp2 = body['tp2'];
      final id = body['id'] as String? ?? 'webhook_${DateTime.now().microsecondsSinceEpoch}';

      final text = StringBuffer()
        ..write('$side $symbol ')
        ..write(entry != null ? 'entry $entry ' : 'market ')
        ..write(sl != null ? 'sl $sl ' : '')
        ..write(tp1 != null ? 'tp1 $tp1 ' : '')
        ..write(tp2 != null ? 'tp2 $tp2 ' : '');

      await pipeline.process(RawMessageEvent(
        inputId: 'tradingview_webhook',
        message: {
          'input_id': 'tradingview_webhook',
          'message_id': id,
          'text': text.toString(),
          'caption': '',
        },
      ));
    } catch (_) {}
  }

  Response _json(Object body) =>
      Response.ok(jsonEncode(body), headers: {'content-type': 'application/json'});

  Response _serveStatic(Request req, String file) {
    final name = file.isEmpty ? 'index.html' : file;
    final safe = name.replaceAll('\\', '/');
    if (safe.contains('..')) return Response.forbidden('forbidden');
    final path = '$webDir/$safe';
    final f = File(path);
    if (!f.existsSync()) {
      return Response.ok(File('$webDir/index.html').readAsStringSync(),
          headers: {'content-type': 'text/html; charset=utf-8'});
    }
    final lower = path.toLowerCase();
    final type = lower.endsWith('.html')
        ? 'text/html; charset=utf-8'
        : lower.endsWith('.css')
            ? 'text/css; charset=utf-8'
            : lower.endsWith('.js')
                ? 'application/javascript; charset=utf-8'
                : 'application/octet-stream';
    return Response.ok(f.readAsBytesSync(), headers: {'content-type': type});
  }

  Map<String, dynamic> _rouletteSettings() {
    return {
      'enabled': db.getSetting('roulette_enabled') != '0',
      'base_risk_pct': double.tryParse(db.getSetting('roulette_base_risk_pct') ?? '') ?? 0.5,
      'max_risk_pct': double.tryParse(db.getSetting('roulette_max_risk_pct') ?? '') ?? 5.0,
      'trigger_pct': double.tryParse(db.getSetting('roulette_trigger_pct') ?? '') ?? 3.0,
      'max_steps': int.tryParse(db.getSetting('roulette_max_steps') ?? '') ?? 50,
      'states': db.listRouletteStates(),
    };
  }

  Map<String, dynamic> _status() {
    final inputs = db.listInputs();
    final lastDecision = db.latestDecision();
    final lastOrder = db.latestOrder();
    return {
      'inputs': inputs,
      'roulette_states': db.listRouletteStates(),
      'last_signal': lastDecision,
      'last_order': lastOrder,
      'open_trades': const [],
      'today_pl': null,
      'limits': {},
      'ts': DateTime.now().toIso8601String(),
    };
  }

  Middleware _logMiddleware() {
    return (inner) {
      return (Request req) {
        db.audit('info', 'HTTP ${req.method} ${req.url.path}');
        return inner(req);
      };
    };
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }
}
