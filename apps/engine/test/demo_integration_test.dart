/// Demo integration test: drives the full pipeline (classify -> parse ->
/// validate -> risk -> roulette -> execute) against a fake MT5 executor.
///
/// This is the automated equivalent of the demo-account run: no real orders
/// are sent, but every scenario in the acceptance list is exercised end to end.
library;

import 'dart:io';

import 'package:nixo_core/nixo_core.dart';
import 'package:nixo_engine/src/db.dart';
import 'package:nixo_engine/src/pipeline.dart';
import 'package:nixo_engine/src/replay.dart';
import 'package:nixo_engine/src/telegram/telegram_source.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Database db;
  late FakeExecutor executor;
  late RouletteManager roulette;
  late Pipeline pipeline;
  var msgSeq = 0;

  Pipeline buildPipeline() {
    return Pipeline(
      db: db,
      executor: executor,
      classifier: Classifier(),
      parser: TextParser(),
      validator: SignalValidator(),
      sizer: Sizer(config: SizingConfig(riskPercent: 0.25)),
      slTp: SlTpResolver(),
      limits: LimitsManager(limits: GlobalLimits()),
      perInputLimits: PerInputLimitsManager(),
      roulette: roulette,
    );
  }

  RawMessageEvent msg(String text, {String input = 'demo', String? id}) {
    msgSeq++;
    return RawMessageEvent(
      inputId: input,
      message: {
        'message_id': id ?? 'm$msgSeq',
        'edit_version': 0,
        'text': text,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nixo_demo_');
    db = Database.open('${tmp.path}/demo.db');
    db.setSetting('mt5_dry_run', '0');
    executor = FakeExecutor(
      quoteForSymbol: {
        'XAUUSD': Quote(symbol: 'XAUUSD', bid: 4049.5, ask: 4050.5, point: 0.01),
        'EURUSD': Quote(symbol: 'EURUSD', bid: 1.0849, ask: 1.0851, point: 0.0001),
      },
      symbolsList: ['XAUUSD', 'EURUSD'],
      riskPerLotForSymbol: {'XAUUSD': 1000.0, 'EURUSD': 1000.0},
    );
    db.upsertProfile('demo-auto', {
      'id': 'demo-auto',
      'name': 'Demo Auto',
      'enabled': true,
      'mode': 'auto',
      'validity_seconds': 180,
      'risk_percent': 0.25,
      'min_lot': 0.01,
      'max_lot': 10.0,
    });
    db.upsertInput({
      'id': 'demo',
      'type': 'telegram_source',
      'name': 'Demo Channel',
      'enabled': true,
      'profile_id': 'demo-auto',
      'status': 'online',
      'last_message_at': null,
      'last_error': null,
    });
    roulette = RouletteManager(
      config: RouletteConfig(),
      accountTrigger: AccountRouletteTrigger(),
      persist: (state) => db.upsertRouletteState({
        'source_id': state.sourceId,
        'model': state.model.name,
        'step': state.step,
        'max_step': state.maxStep,
        'activated': state.activated,
        'last_updated': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }),
    );
    pipeline = buildPipeline();
  });

  tearDown(() {
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('demo integration', () {
    test('1. valid BUY signal executes', () async {
      final d = await pipeline.process(msg('BUY XAUUSD entry 4050 sl 4030 tp 4080'));
      expect(d.action, DecisionAction.execute);
      expect(executor.opened, hasLength(1));
      expect(executor.opened.first.side, Side.buy);
    });

    test('2. valid SELL signal executes', () async {
      final d = await pipeline.process(msg('SELL XAUUSD entry 4050 sl 4070 tp 4020'));
      expect(d.action, DecisionAction.execute);
      expect(executor.opened.first.side, Side.sell);
    });

    test('3. BUY LIMIT and SELL LIMIT are pending orders', () async {
      await pipeline.process(msg('BUY LIMIT XAUUSD entry 4049 sl 4030 tp 4080'));
      await pipeline.process(msg('SELL LIMIT XAUUSD entry 4051 sl 4070 tp 4020'));
      expect(executor.opened, hasLength(2));
      expect(executor.opened[0].type, OrderType.limit);
      expect(executor.opened[1].type, OrderType.limit);
    });

    test('4. multiple TPs are kept', () async {
      final d = await pipeline.process(
          msg('BUY XAUUSD entry 4050 sl 4030 tp1 4080 tp2 4110'));
      expect(d.action, DecisionAction.execute);
      expect(executor.opened.first.tps.length, greaterThanOrEqualTo(2));
    });

    test('5. missing SL is rejected', () async {
      final d = await pipeline.process(msg('BUY XAUUSD entry 4050 tp 4080'));
      expect(d.action, isNot(DecisionAction.execute));
      expect(executor.opened, isEmpty);
    });

    test('6. invalid SL direction is rejected', () async {
      final d = await pipeline.process(msg('BUY XAUUSD entry 4050 sl 4060 tp 4080'));
      expect(d.action, isNot(DecisionAction.execute));
      expect(executor.opened, isEmpty);
    });

    test('7. expired signal is rejected', () async {
      msgSeq++;
      final d = await pipeline.process(RawMessageEvent(
        inputId: 'demo',
        message: {
          'message_id': 'old1',
          'edit_version': 0,
          'text': 'BUY XAUUSD entry 4050 sl 4030 tp 4080',
          'timestamp': DateTime.now()
              .toUtc()
              .subtract(const Duration(hours: 2))
              .toIso8601String(),
        },
      ));
      expect(d.action, isNot(DecisionAction.execute));
      expect(executor.opened, isEmpty);
    });

    test('8. duplicate message is not executed twice', () async {
      final first = await pipeline.process(msg('BUY XAUUSD entry 4050 sl 4030 tp 4080', id: 'dup'));
      final second = await pipeline.process(msg('BUY XAUUSD entry 4050 sl 4030 tp 4080', id: 'dup'));
      expect(first.action, DecisionAction.execute);
      expect(second.action, isNot(DecisionAction.execute));
      expect(executor.opened, hasLength(1));
    });

    test('9. reposted signal with a new message id executes', () async {
      await pipeline.process(msg('BUY XAUUSD entry 4050 sl 4030 tp 4080', id: 'r1'));
      await pipeline.process(msg('BUY XAUUSD entry 4050 sl 4030 tp 4080', id: 'r2'));
      expect(executor.opened, hasLength(2));
    });

    test('10. invalid symbol is rejected', () async {
      final d = await pipeline.process(msg('BUY NOPE entry 1 sl 0.9 tp 2'));
      expect(d.action, isNot(DecisionAction.execute));
    });

    test('11. unknown input defaults to shadow (no order)', () async {
      final d = await pipeline.process(
          msg('BUY XAUUSD entry 4050 sl 4030 tp 4080', input: 'never-seen'));
      expect(d.action, DecisionAction.shadow);
      expect(executor.opened, isEmpty);
    });

    test('12. risk-per-lot unavailable blocks execution', () async {
      executor.riskPerLotUnavailable = true;
      final d = await pipeline.process(msg('BUY XAUUSD entry 4050 sl 4030 tp 4080'));
      expect(d.action, DecisionAction.block);
      expect(executor.opened, isEmpty);
    });

    test('13. broker rejection is reported, not recorded as success', () async {
      executor.failOpen = true;
      final d = await pipeline.process(msg('BUY XAUUSD entry 4050 sl 4030 tp 4080'));
      expect(d.action, isNot(DecisionAction.execute));
    });

    test('14. noise and recap never execute', () async {
      await pipeline.process(msg('good morning everyone'));
      await pipeline.process(msg('weekly recap: closed +120 pips'));
      expect(executor.opened, isEmpty);
    });

    test('15. management update does not open a new order', () async {
      final d = await pipeline.process(msg('move sl to entry XAUUSD'));
      expect(d.action, DecisionAction.skip);
      expect(executor.opened, isEmpty);
    });

    test('16. roulette win advances the step and lot size grows', () async {
      roulette.activateSource('demo');
      final before = roulette.currentRiskPct('demo');
      final r = roulette.onBatchResult('demo', 100.0, 50.0);
      expect(r.action, 'win');
      expect(roulette.currentRiskPct('demo'), greaterThan(before));
    });

    test('17. roulette loss does not increase risk', () async {
      roulette.activateSource('demo');
      roulette.onBatchResult('demo', 100.0, 50.0);
      final peak = roulette.currentRiskPct('demo');
      final r = roulette.onBatchResult('demo', -50.0, 50.0);
      expect(r.action, 'loss');
      expect(roulette.currentRiskPct('demo'), lessThan(peak));
    });

    test('18. roulette step is restored after restart', () async {
      roulette.activateSource('demo');
      roulette.onBatchResult('demo', 100.0, 50.0);
      final step = roulette.getState('demo').step;
      expect(step, greaterThan(1));

      final restored = RouletteManager(
        config: RouletteConfig(),
        accountTrigger: AccountRouletteTrigger(),
      );
      for (final row in db.listRouletteStates()) {
        restored.restore(row['source_id'] as String, RouletteState(
          sourceId: row['source_id'] as String,
          model: RouletteModel.values.firstWhere(
            (m) => m.name == row['model'],
            orElse: () => RouletteModel.volume,
          ),
          step: row['step'] as int,
          maxStep: row['max_step'] as int,
          activated: row['activated'] == 1,
        ));
      }
      expect(restored.getState('demo').step, step);
    });

    test('19. executed orders are journaled with a stable client order id', () async {
      await pipeline.process(msg('BUY XAUUSD entry 4050 sl 4030 tp 4080', id: 'j1'));
      final order = db.latestOrder();
      expect(order, isNotNull);
      expect(order!['client_order_id'], isNotNull);
      expect(order['symbol'], 'XAUUSD');
    });

    test('20. dashboard reads status while the engine keeps running', () async {
      await pipeline.process(msg('BUY XAUUSD entry 4050 sl 4030 tp 4080', id: 's1'));
      final last = db.latestDecision();
      expect(last, isNotNull);
      expect(last!['action'], 'execute');
      // Pipeline keeps processing after a dashboard read.
      final d2 = await pipeline.process(msg('SELL XAUUSD entry 4050 sl 4070 tp 4020', id: 's2'));
      expect(d2.action, DecisionAction.execute);
    });
  });
}