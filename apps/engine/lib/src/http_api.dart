/// Local HTTP API (shelf) + TradingView webhook endpoint.
///
/// The webhook endpoint responds 200 IMMEDIATELY and processes asynchronously
/// (TradingView cancels after 3 seconds).
library;

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'db.dart';
import 'pipeline.dart';

class HttpApi {
  HttpApi({
    required this.host,
    required this.port,
    required this.token,
    required this.db,
    required this.pipeline,
    this.webhookToken = '',
    this.webhookPassphrase = '',
  });

  final String host;
  final int port;
  final String token;
  final Database db;
  final Pipeline pipeline;
  final String webhookToken;
  final String webhookPassphrase;

  HttpServer? _server;
  final _router = Router();

  Future<void> start() async {
    _router.get('/health', (Request req) {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      return Response.ok(jsonEncode({'ok': true, 'engine': 'running'}),
          headers: {'content-type': 'application/json'});
    });

    _router.get('/status', (Request req) {
      if (!_authorized(req)) return Response.forbidden('unauthorized');
      return Response.ok(jsonEncode(_status()), headers: {'content-type': 'application/json'});
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

    final handler = const Pipeline().addMiddleware(_logMiddleware()).addHandler(_router.call);
    _server = await serve(handler, host, port);
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

  Map<String, dynamic> _status() {
    return {
      'inputs': db.listInputs(),
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
