/// MT5 link server: the engine is the socket SERVER on 127.0.0.1.
///
/// Handles auth token handshake, bidirectional heartbeat, auto-reconnect, and
/// refuses non-local addresses. Implements the Executor interface used by the
/// pipeline.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:nixo_core/nixo_core.dart';

import '../pipeline.dart';
import 'protocol.dart';

class Mt5LinkServer implements Executor {
  Mt5LinkServer({
    required this.host,
    required this.port,
    required this.token,
  });

  final String host;
  final int port;
  final String token;

  ServerSocket? _server;
  Socket? _client;
  bool _authenticated = false;
  Timer? _heartbeat;
  final _events = StreamController<Mt5Message>.broadcast();
  final _pending = <String, Completer<Mt5Message>>{};
  int _seq = 0;

  Stream<Mt5Message> get events => _events.stream;
  bool get connected => _client != null && _authenticated;

  Future<void> start() async {
    _server = await ServerSocket.bind(host, port);
    _server!.listen(_onConnection, onError: (_) {});
  }

  void _onConnection(Socket socket) {
    // Refuse non-local addresses.
    final addr = socket.remoteAddress.address;
    if (addr != '127.0.0.1' && addr != '::1') {
      socket.destroy();
      return;
    }
    _client = socket;
    socket.listen(
      _onData,
      onDone: () => _onDisconnect(),
      onError: (_) => _onDisconnect(),
    );
  }

  void _onData(List<int> data) {
    final text = String.fromCharCodes(data);
    for (final line in text.split('\n')) {
      final msg = Mt5Message.decode(line);
      if (msg == null) continue;
      _handleMessage(msg);
    }
  }

  void _handleMessage(Mt5Message msg) {
    final cmd = msg['CMD'];
    if (cmd == Cmd.auth) {
      final t = msg['TOKEN'];
      if (t == token) {
        _authenticated = true;
        _send(Mt5Message({'CMD': 'AUTH_OK'}));
        _startHeartbeat();
      } else {
        _send(Mt5Message({'CMD': 'AUTH_FAIL'}));
        _client?.destroy();
      }
      return;
    }
    if (!_authenticated) return;

    if (cmd == Evt.heartbeat) {
      _send(Mt5Message({'CMD': Cmd.heartbeat}));
      return;
    }

    // Resolve a pending request if this is a response.
    final reqId = msg['REQ_ID'];
    if (reqId != null && _pending.containsKey(reqId)) {
      _pending.remove(reqId)!.complete(msg);
      return;
    }

    _events.add(msg);
  }

  void _onDisconnect() {
    _client = null;
    _authenticated = false;
    _heartbeat?.cancel();
    // Fail all pending requests.
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.complete(Mt5Message({'CMD': 'ERROR', 'MSG': 'disconnected'}));
      }
    }
    _pending.clear();
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_authenticated && _client != null) {
        _send(Mt5Message({'CMD': Cmd.heartbeat}));
      }
    });
  }

  void _send(Mt5Message msg) {
    final socket = _client;
    if (socket == null) return;
    socket.write('${msg.encode()}\n');
  }

  Future<Mt5Message> _request(String cmd, Map<String, String> fields) async {
    final reqId = '${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
    final completer = Completer<Mt5Message>();
    _pending[reqId] = completer;
    _send(Mt5Message({'CMD': cmd, 'REQ_ID': reqId, ...fields}));
    return completer.future.timeout(const Duration(seconds: 5),
        onTimeout: () => Mt5Message({'CMD': 'ERROR', 'MSG': 'timeout'}));
  }

  // --- Executor implementation ---

  @override
  Future<ExecutionAck> open(OrderPlan order) async {
    final resp = await _request(Cmd.open, {
      'SYMBOL': order.symbol,
      'SIDE': order.side.name,
      'TYPE': order.type.name,
      'LOTS': order.lots.toString(),
      'ENTRY': order.entry?.toString() ?? '',
      'SL': order.sl?.toString() ?? '',
      'TPS': order.tps.join(','),
      'MAGIC': order.magic.toString(),
      'COMMENT': order.comment,
      'CLIENT_ORDER_ID': order.clientOrderId ?? '',
      'DEVIATION': order.deviation.toString(),
    });
    if (resp['CMD'] == 'OK') {
      return ExecutionAck(ok: true, orderId: resp['ORDER_ID']);
    }
    return ExecutionAck(ok: false, error: resp['MSG'], retcode: int.tryParse(resp['RETCODE'] ?? ''));
  }

  @override
  Future<void> modify(String orderId, {double? sl, List<double>? tps}) async {
    await _request(Cmd.modify, {
      'ORDER_ID': orderId,
      'SL': sl?.toString() ?? '',
      'TPS': (tps ?? []).join(','),
    });
  }

  @override
  Future<void> close(String orderId, {double? lots}) async {
    await _request(Cmd.close, {
      'ORDER_ID': orderId,
      'LOTS': lots?.toString() ?? '',
    });
  }

  @override
  Future<void> closeAll() async {
    await _request(Cmd.closeAll, {});
  }

  @override
  Future<void> cancel(String orderId) async {
    await _request(Cmd.cancel, {'ORDER_ID': orderId});
  }

  @override
  Future<Quote?> quote(String symbol) async {
    final resp = await _request(Cmd.getSymbolInfo, {'SYMBOL': symbol});
    if (resp['CMD'] == 'ERROR') return null;
    return Quote(
      symbol: symbol,
      bid: double.tryParse(resp['BID'] ?? '') ?? 0,
      ask: double.tryParse(resp['ASK'] ?? '') ?? 0,
      spreadPoints: int.tryParse(resp['SPREAD'] ?? '0') ?? 0,
      point: double.tryParse(resp['POINT'] ?? '0') ?? 0,
      digits: int.tryParse(resp['DIGITS'] ?? '0') ?? 0,
      marketOpen: resp['MARKET_OPEN'] != '0',
      tickSize: double.tryParse(resp['TICK_SIZE'] ?? '0') ?? 0,
      stopsLevel: int.tryParse(resp['STOPS_LEVEL'] ?? '0') ?? 0,
    );
  }

  @override
  Future<AccountInfo> account() async {
    final resp = await _request(Cmd.getAccount, {});
    return AccountInfo(
      balance: double.tryParse(resp['BALANCE'] ?? '0') ?? 0,
      equity: double.tryParse(resp['EQUITY'] ?? '0') ?? 0,
      margin: double.tryParse(resp['MARGIN'] ?? '0') ?? 0,
      freeMargin: double.tryParse(resp['FREE_MARGIN'] ?? '0') ?? 0,
      tradeMode: resp['TRADE_MODE'] == 'real'
          ? TradeMode.real
          : resp['TRADE_MODE'] == 'contest'
              ? TradeMode.contest
              : TradeMode.demo,
      marginMode: resp['MARGIN_MODE'] == 'netting'
          ? MarginMode.netting
          : MarginMode.hedging,
      currency: resp['CURRENCY'] ?? 'USD',
      leverage: int.tryParse(resp['LEVERAGE'] ?? '0') ?? 0,
    );
  }

  @override
  Future<List<String>> symbols() async {
    final resp = await _request(Cmd.getSymbols, {});
    if (resp['SYMBOLS'] == null) return [];
    return resp['SYMBOLS']!.split(',').where((s) => s.isNotEmpty).toList();
  }

  @override
  Future<List<double>> rates(String symbol, int count) async {
    final resp = await _request(Cmd.getRates, {
      'SYMBOL': symbol,
      'COUNT': count.toString(),
    });
    if (resp['RATES'] == null) return [];
    return resp['RATES']!
        .split(',')
        .map((s) => double.tryParse(s) ?? 0)
        .toList();
  }

  @override
  Future<double?> riskPerLot(String symbol, Side side, double entry, double sl) async {
    final resp = await _request(Cmd.getRiskPerLot, {
      'SYMBOL': symbol,
      'SIDE': side.name,
      'ENTRY': entry.toString(),
      'SL': sl.toString(),
    });
    if (resp['CMD'] == 'ERROR') return null;
    final v = double.tryParse(resp['RISK_PER_LOT'] ?? '');
    return (v != null && v > 0) ? v : null;
  }

  Future<void> stop() async {
    _heartbeat?.cancel();
    await _server?.close();
    _client?.destroy();
  }
}
