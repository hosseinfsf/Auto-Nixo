import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nixo_core/nixo_core.dart';
import 'package:nixo_engine/src/mt5/link_server.dart';
import 'package:nixo_engine/src/mt5/protocol.dart';
import 'package:test/test.dart';

class _Client {
  _Client(this.socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add, onDone: () => closed = true);
  }

  final Socket socket;
  final List<String> lines = <String>[];
  bool closed = false;

  void send(String s) => socket.add(utf8.encode(s));

  Future<void> waitFor(bool Function() cond,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final end = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(end)) {
        throw TimeoutException('condition not met; lines=$lines closed=$closed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  int count(String line) => lines.where((l) => l == line).length;
}

void main() {
  const token = 'unit-test-token-0123456789';
  late Mt5LinkServer server;

  setUp(() async {
    server = Mt5LinkServer(
      host: '127.0.0.1',
      port: 0,
      token: token,
      rxTimeout: const Duration(milliseconds: 600),
      heartbeatInterval: const Duration(seconds: 30),
      requestTimeout: const Duration(seconds: 2),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<_Client> connect() async =>
      _Client(await Socket.connect('127.0.0.1', server.boundPort));

  Future<_Client> authed() async {
    final c = await connect();
    c.send('CMD=AUTH|TOKEN=$token\n');
    await c.waitFor(() => c.lines.contains('CMD=AUTH_OK'));
    return c;
  }

  test('refuses an empty, short or placeholder token', () {
    for (final bad in ['', 'short', 'nixo-dev-token', 'CHANGE-ME']) {
      expect(() => Mt5LinkServer(host: '127.0.0.1', port: 0, token: bad),
          throwsArgumentError,
          reason: 'token "$bad" must be refused');
    }
  });

  test('auth ok, then a heartbeat split across two TCP chunks is handled', () async {
    final c = await authed();
    expect(server.connected, isTrue);
    c.send('CMD=H');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    c.send('B\n');
    await c.waitFor(() => c.count('CMD=HB') == 1);
  });

  test('two messages merged into one chunk are both handled', () async {
    final c = await authed();
    c.send('CMD=HB\nCMD=HB\n');
    await c.waitFor(() => c.count('CMD=HB') == 2);
  });

  test('NUL terminator bytes from the EA do not break the next message', () async {
    final c = await authed();
    c.socket.add(<int>[...utf8.encode('CMD=HB\n'), 0, ...utf8.encode('CMD=HB\n'), 0]);
    await c.waitFor(() => c.count('CMD=HB') == 2);
  });

  test('wrong token gets AUTH_FAIL and is closed', () async {
    final c = await connect();
    c.send('CMD=AUTH|TOKEN=wrong\n');
    await c.waitFor(() => c.closed);
    expect(c.lines, contains('CMD=AUTH_FAIL'));
    expect(server.connected, isFalse);
  });

  test('an unauthenticated socket is ignored and does not hijack the link', () async {
    final a = await authed();
    final b = await connect();
    b.send('CMD=HB\n');
    b.send('CMD=GET_ACCOUNT|REQ_ID=1\n');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(b.lines, isEmpty);
    expect(server.connected, isTrue);
    a.send('CMD=HB\n');
    await a.waitFor(() => a.count('CMD=HB') == 1);
  });

  test('an unauthenticated socket is dropped after the auth timeout', () async {
    final s2 = Mt5LinkServer(
      host: '127.0.0.1',
      port: 0,
      token: token,
      authTimeout: const Duration(milliseconds: 300),
    );
    await s2.start();
    final c = _Client(await Socket.connect('127.0.0.1', s2.boundPort));
    await c.waitFor(() => c.closed);
    await s2.stop();
  });

  test('a silent client is dropped after the rx timeout', () async {
    final c = await authed();
    await c.waitFor(() => c.closed, timeout: const Duration(seconds: 3));
    expect(server.connected, isFalse);
  });

  test('values with separators survive the event path', () async {
    final c = await authed();
    final got = server.events.first;
    c.send('${Mt5Message({'CMD': 'FILL', 'COMMENT': 'NX|a=b%c'}).encode()}\n');
    final msg = await got.timeout(const Duration(seconds: 2));
    expect(msg['COMMENT'], 'NX|a=b%c');
  });

  test('request/response round trip (riskPerLot)', () async {
    final c = await authed();
    final fut = server.riskPerLot('XAUUSD', Side.buy, 4050, 4030);
    await c.waitFor(() => c.lines.any((l) => l.startsWith('CMD=GET_RISK_PER_LOT')));
    final req = Mt5Message.decode(
        c.lines.firstWhere((l) => l.startsWith('CMD=GET_RISK_PER_LOT')))!;
    c.send('CMD=OK|REQ_ID=${req['REQ_ID']}|RISK_PER_LOT=2000.0\n');
    expect(await fut, 2000.0);
  });

  test('an ERROR reply gives null risk per lot', () async {
    final c = await authed();
    final fut = server.riskPerLot('XAUUSD', Side.buy, 4050, 4030);
    await c.waitFor(() => c.lines.any((l) => l.startsWith('CMD=GET_RISK_PER_LOT')));
    final req = Mt5Message.decode(
        c.lines.firstWhere((l) => l.startsWith('CMD=GET_RISK_PER_LOT')))!;
    c.send('CMD=ERROR|REQ_ID=${req['REQ_ID']}|MSG=order_calc_profit_failed\n');
    expect(await fut, isNull);
  });

  test('requests fail fast when no EA is connected', () async {
    final sw = Stopwatch()..start();
    final q = await server.quote('XAUUSD');
    final r = await server.riskPerLot('XAUUSD', Side.buy, 4050, 4030);
    expect(q, isNull);
    expect(r, isNull);
    expect(sw.elapsedMilliseconds, lessThan(500));
  });

  test('a new authenticated EA replaces the old connection', () async {
    final a = await authed();
    final b = await authed();
    await a.waitFor(() => a.closed);
    expect(server.connected, isTrue);
    b.send('CMD=HB\n');
    await b.waitFor(() => b.count('CMD=HB') == 1);
  });
}
