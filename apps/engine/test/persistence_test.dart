import 'dart:io';

import 'package:nixo_engine/src/db.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nixo_persist_');
    dbPath = '${tmp.path}/nixo.db';
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('persistence and recovery', () {
    test('roulette state survives restart', () {
      final db1 = Database.open(dbPath);
      db1.upsertRouletteState({
        'source_id': 'src1',
        'model': 'volume',
        'step': 7,
        'max_step': 50,
        'activated': true,
        'last_updated': 1000,
      });
      db1.close();

      final db2 = Database.open(dbPath);
      final states = db2.listRouletteStates();
      db2.close();

      expect(states, hasLength(1));
      expect(states.first['source_id'], 'src1');
      expect(states.first['step'], 7);
      expect(states.first['activated'], 1);
    });

    test('raw message dedup survives restart', () {
      final db1 = Database.open(dbPath);
      db1.insertRawMessage({
        'input_id': 'src1',
        'message_id': 'm100',
        'edit_version': 0,
        'text': 'BUY XAUUSD entry 4050 sl 4030',
      });
      db1.close();

      final db2 = Database.open(dbPath);
      final exists = db2.rawMessageExists('src1', 'm100', 0);
      db2.insertRawMessage({
        'input_id': 'src1',
        'message_id': 'm100',
        'edit_version': 0,
        'text': 'BUY XAUUSD entry 4050 sl 4030',
      });
      final rows = db2.listAudit(limit: 1);
      db2.close();

      expect(exists, isTrue);
      expect(rows, isEmpty);
    });

    test('unfinished signals are detected after restart', () {
      final db1 = Database.open(dbPath);
      db1.insertSignal({
        'id': 'sig-1',
        'input_id': 'src1',
        'message_id': 'm1',
        'symbol': 'XAUUSD',
      });
      db1.insertSignal({
        'id': 'sig-2',
        'input_id': 'src1',
        'message_id': 'm2',
        'symbol': 'EURUSD',
      });
      db1.insertDecision({
        'signal_id': 'sig-1',
        'action': 'execute',
        'reason': '',
        'validation': '',
        'sizing': '',
        'order_json': '',
      });
      db1.close();

      final db2 = Database.open(dbPath);
      final unfinished = db2.unfinishedSignals();
      db2.close();

      expect(unfinished, hasLength(1));
      expect(unfinished.first['id'], 'sig-2');
    });

    test('latest order and latest decision are readable after restart', () {
      final db1 = Database.open(dbPath);
      db1.insertSignal({
        'id': 'sig-1',
        'input_id': 'src1',
        'message_id': 'm1',
        'symbol': 'XAUUSD',
        'side': 'buy',
      });
      db1.insertDecision({
        'signal_id': 'sig-1',
        'action': 'execute',
        'reason': 'ok',
        'validation': '{}',
        'sizing': '{}',
        'order_json': '{}',
      });
      db1.insertOrder({
        'id': 'ord-1',
        'signal_id': 'sig-1',
        'client_order_id': 'cid-1',
        'symbol': 'XAUUSD',
        'side': 'buy',
        'type': 'market',
        'lots': 0.1,
        'entry': 4050,
        'sl': 4030,
        'tps': [4080],
        'magic': 260101,
        'comment': 'nixo',
        'status': 'sent',
      });
      db1.close();

      final db2 = Database.open(dbPath);
      final lastDecision = db2.latestDecision();
      final lastOrder = db2.latestOrder();
      db2.close();

      expect(lastDecision, isNotNull);
      expect(lastDecision!['action'], 'execute');
      expect(lastOrder, isNotNull);
      expect(lastOrder!['client_order_id'], 'cid-1');
      expect(lastOrder['status'], 'sent');
    });

    test('settings persist across restart', () {
      final db1 = Database.open(dbPath);
      db1.setSetting('roulette_base_risk_pct', '0.25');
      db1.setSetting('mt5_dry_run', '1');
      db1.close();

      final db2 = Database.open(dbPath);
      expect(db2.getSetting('roulette_base_risk_pct'), '0.25');
      expect(db2.getSetting('mt5_dry_run'), '1');
      db2.close();
    });

    test('execution intent and status survive restart', () {
      final db1 = Database.open(dbPath);
      db1.createExecutionIntent(
        signalId: 'sig_src1_m1_0',
        intent: {
          'order': {
            'symbol': 'XAUUSD',
            'side': 'buy',
            'type': 'market',
            'lots': 0.1,
            'client_order_id': 'sig_src1_m1_0',
          },
          'sizing': {'lots': 0.1, 'risk_percent': 0.25},
        },
      );
      db1.updateExecutionIntent(
        'sig_src1_m1_0',
        status: 'uncertain',
        lastError: 'MT5 response uncertain: timeout',
        incrementAttempts: true,
      );
      db1.close();

      final db2 = Database.open(dbPath);
      final intent = db2.executionIntentFor('sig_src1_m1_0');
      db2.close();

      expect(intent, isNotNull);
      expect(intent!['status'], 'uncertain');
      expect(intent['attempts'], 1);
      expect(intent['intent']['order']['client_order_id'], 'sig_src1_m1_0');
    });

    test('audit log persists across restart', () {
      final db1 = Database.open(dbPath);
      db1.audit('info', 'engine started');
      db1.audit('warn', 'mt5 link down');
      db1.close();

      final db2 = Database.open(dbPath);
      final rows = db2.listAudit(limit: 10);
      db2.close();

      expect(rows, hasLength(2));
      expect(rows.first['message'], 'mt5 link down');
    });
  });
}