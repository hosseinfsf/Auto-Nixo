/// MT5 link server: the engine is the socket SERVER on 127.0.0.1.
///
/// - line framing with a per-connection buffer (TCP may split or merge messages)
/// - UTF-8 decoding, NUL/CR stripped
/// - authentication is tracked PER SOCKET; unauthenticated sockets are ignored
///   and dropped after [authTimeout]
/// - a new authenticated client replaces the old one; the old socket is closed
/// - heartbeat both ways; a silent client is dropped after [rxTimeout]
/// - requests fail fast when no EA is connected (no 5 s stalls)
/// - refuses non-loopback peers
///
/// Implements the Executor interface used by the pipeline.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nixo_core/nixo_core.dart';

import '../pipeline.dart';
import 'protocol.dart';

class _Conn {
  _Conn(this.socket)
      : connectedAt = DateTime.now(),
        lastRx = DateTime.now();

  final Socket socket;
  final DateTime connectedAt;
  DateTime lastRx;
  bool authed = false;
  bool dead = false;
  final List<int> buf = <int>[];
}

class Mt5LinkServer implements Executor {
  Mt5LinkServer({
    required this.host,
    required this.port,
    required this.token,
    this.rxTimeout = const Duration(seconds: 6),
    this.authTimeout = const Duration(seconds: 3),
    this.heartbeatInterval = const Duration(seconds: 2),
    this.requestTimeout = const Duration(seconds: 5),
  }) {
    if (token.length < 16 || token == 'nixo-dev-token' || token == 'CHANGE-ME') {
      throw ArgumentError(
          'MT5 link token is empty, too short (<16 chars) or a placeholder. Set a long '
          'random "api_token" in engine_config.json and the same value in the EA input InpAuthToken.');
    }
  }

  final String host;
  final int port;
  final String token;
  final Duration rxTimeout;
  final Duration authTimeout;
  final Duration heartbeatInterval;
  final Duration requestTimeout;

  static const int _maxBuffer = 1024 * 1024;

  ServerSocket? _server;
  _Conn? _active;
  final Set<_Conn> _conns = <_Conn>{};
  Timer? _heartbeat;
  Timer? _watchdog;
  final _events = StreamController<Mt5Message>.broadcast();
  final _pending = <String, Completer<Mt5Message>>{};
  int _seq = 0;

  Stream<Mt5Message> get events => _events.stream;
  bool get connected => _active != null;
  int get boundPort => _server!.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(host, port);
    _server!.listen(_onConnection, onError: (_) {});
    _watchdog = Timer.periodic(const Duration(milliseconds: 250), (_) => _check());
  }

  // ---------------------------------------------------------------- sockets

  void _onConnection(Socket socket) {
    // Refuse non-local peers.
    if (!socket.remoteAddress.isLoopback) {
      socket.destroy();
      return;
    }
    final conn = _Conn(socket);
    _conns.add(conn);
    socket.listen(
      (data) => _onData(conn, data),
      onDone: () => _onDisconnect(conn),
      onError: (_) => _onDisconnect(conn),
      cancelOnError: true,
    );
  }

  void _onData(_Conn conn, List<int> data) {
    conn.lastRx = DateTime.now();
    conn.buf.addAll(data);
    if (conn.buf.length > _maxBuffer) {
      _kill(conn);
      return;
    }
    while (true) {
      final nl = conn.buf.indexOf(10);
      if (nl < 0) break;
      final lineBytes = conn.buf.sublist(0, nl);
      conn.buf.removeRange(0, nl + 1);
      final clean = lineBytes.where((b) => b != 0 && b != 13).toList();
      if (clean.isEmpty) continue;
      final msg = Mt5Message.decode(utf8.decode(clean, allowMalformed: true));
      if (msg == null) continue;
      _handleMessage(conn, msg);
      if (conn.dead) break;
    }
  }

  void _kill(_Conn conn) {
    conn.dead = true;
    conn.socket.destroy();
  }

  bool _tokenOk(String? t) {
    if (t == null) return false;
    final a = utf8.encode(t);
    final b = utf8.encode(token);
    var diff = a.length ^ b.length;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  void _handleMessage(_Conn conn, Mt5Message msg) {
    final cmd = msg['CMD'];

    if (!conn.authed) {
      // Only AUTH is accepted from an unauthenticated socket.
      if (cmd != Cmd.auth) return;
      if (_tokenOk(msg['TOKEN'])) {
        _promote(conn);
      } else {
        _write(conn, Mt5Message({'CMD': 'AUTH_FAIL'}));
        _kill(conn);
      }
      return;
    }
    // Messages from a socket that is no longer the active one are ignored.
    if (!identical(_active, conn)) return;

    if (cmd == Cmd.heartbeat) {
      _write(conn, Mt5Message({'CMD': Cmd.heartbeat}));
      return;
    }

    final reqId = msg['REQ_ID'];
    if (reqId != null && _pending.containsKey(reqId)) {
      _pending.remove(reqId)!.complete(msg);
      return;
    }
    _events.add(msg);
  }

  void _promote(_Conn conn) {
    final old = _active;
    conn.authed = true;
    _active = conn;
    if (old != null && !identical(old, conn)) {
      _failPending('replaced');
      _kill(old);
    }
    _write(conn, Mt5Message({'CMD': 'AUTH_OK'}));
    _startHeartbeat();
  }

  void _onDisconnect(_Conn conn) {
    _conns.remove(conn);
    if (identical(_active, conn)) {
      _active = null;
      _heartbeat?.cancel();
      _failPending('disconnected');
    }
  }

  void _failPending(String why) {
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.complete(Mt5Message({'CMD': 'ERROR', 'MSG': why}));
      }
    }
    _pending.clear();
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      final a = _active;
      if (a != null) _write(a, Mt5Message({'CMD': Cmd.heartbeat}));
    });
  }

  void _check() {
    final now = DateTime.now();
    for (final c in _conns.toList()) {
      if (!c.authed) {
        if (now.difference(c.connectedAt) > authTimeout) _kill(c);
      } else if (identical(c, _active)) {
        if (now.difference(c.lastRx) > rxTimeout) _kill(c);
      }
    }
  }

  void _write(_Conn conn, Mt5Message msg) {
    try {
      conn.socket.add(utf8.encode('${msg.encode()}\n'));
    } catch (_) {
      // socket already closed; the onDone handler cleans up
    }
  }

  Future<Mt5Message> _request(String cmd, Map<String, String> fields) async {
    final active = _active;
    if (active == null) {
      return Mt5Message({'CMD': 'ERROR', 'MSG': 'not_connected'});
    }
    final reqId = '${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
    final completer = Completer<Mt5Message>();
    _pending[reqId] = completer;
    _write(active, Mt5Message({'CMD': cmd, 'REQ_ID': reqId, ...fields}));
    return completer.future.timeout(requestTimeout, onTimeout: () {
      _pending.remove(reqId);
      return Mt5Message({'CMD': 'ERROR', 'MSG': 'timeout'});
    });
  }

  // ------------------------------------------------- Executor implementation

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
      'FILLING': order.fillingMode.name,
    });
    if (resp['CMD'] == 'OK') {
      return ExecutionAck(ok: true, orderId: resp['ORDER_ID']);
    }
    return ExecutionAck(
        ok: false, error: resp['MSG'], retcode: int.tryParse(resp['RETCODE'] ?? ''));
  }

  /// Reconcile open positions after restart. Returns the tickets of positions
  /// opened by NIXO (comment prefix "NX").
  @override
  Future<List<int>> reconcilePositions() async {
    final resp = await _request(Cmd.getPositions, {});
    if (resp['CMD'] == 'ERROR' || resp['TICKETS'] == null) return [];
    return resp['TICKETS']!
        .split(',')
        .where((s) => s.isNotEmpty)
        .map((s) => int.tryParse(s) ?? 0)
        .where((t) => t > 0)
        .toList();
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
    if (resp['CMD'] != 'SYMBOL_INFO') return null;
    final bid = double.tryParse(resp['BID'] ?? '') ?? 0;
    final ask = double.tryParse(resp['ASK'] ?? '') ?? 0;
    if (bid <= 0 || ask <= 0) return null;
    return Quote(
      symbol: symbol,
      bid: bid,
      ask: ask,
      spreadPoints: int.tryParse(resp['SPREAD'] ?? '0') ?? 0,
      point: double.tryParse(resp['POINT'] ?? '0') ?? 0,
      digits: int.tryParse(resp['DIGITS'] ?? '0') ?? 0,
      marketOpen: resp['MARKET_OPEN'] == '1',
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
      marginMode: resp['MARGIN_MODE'] == 'netting' ? MarginMode.netting : MarginMode.hedging,
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
    return resp['RATES']!.split(',').map((s) => double.tryParse(s) ?? 0).toList();
  }

  @override
  Future<double?> riskPerLot(String symbol, Side side, double entry, double sl) async {
    final resp = await _request(Cmd.getRiskPerLot, {
      'SYMBOL': symbol,
      'SIDE': side.name,
      'ENTRY': entry.toString(),
      'SL': sl.toString(),
    });
    if (resp['CMD'] != 'OK') return null;
    final v = double.tryParse(resp['RISK_PER_LOT'] ?? '');
    return (v != null && v > 0) ? v : null;
  }

  Future<void> stop() async {
    _heartbeat?.cancel();
    _watchdog?.cancel();
    _failPending('stopped');
    for (final c in _conns.toList()) {
      _kill(c);
    }
    await _server?.close();
  }
}
