import 'package:nixo_core/nixo_core.dart';
import 'package:nixo_engine/src/db.dart';
import 'package:nixo_engine/src/pipeline.dart';
import 'package:nixo_engine/src/replay.dart';
import 'package:nixo_engine/src/telegram/telegram_source.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late Pipeline pipeline;
  late FakeExecutor executor;

  setUp(() {
    db = Database.open(':memory:');
    executor = FakeExecutor(
      quoteForSymbol: {
        'XAUUSD': Quote(
          symbol: 'XAUUSD',
          bid: 4050.0,
          ask: 4050.5,
          spreadPoints: 5,
          point: 0.01,
          digits: 2,
          tickSize: 0.01,
        ),
      },
    );
    // Create a profile with auto mode for src1
    db.upsertProfile('p1', {
      'id': 'p1',
      'name': 'test profile',
      'mode': 'auto',
      'risk_percent': 0.5,
    });
    db.upsertInput({
      'id': 'src1',
      'type': 'telegram_source',
      'name': 'src1',
      'enabled': true,
      'profile_id': 'p1',
    });
    pipeline = Pipeline(
      db: db,
      executor: executor,
      classifier: Classifier(),
      parser: TextParser(),
      validator: SignalValidator(),
      sizer: Sizer(),
      slTp: SlTpResolver(),
      limits: LimitsManager(),
      perInputLimits: PerInputLimitsManager(),
      roulette: RouletteManager(
        config: RouletteConfig(),
        accountTrigger: AccountRouletteTrigger(),
      ),
    );
  });

  tearDown(() => db.close());

  group('pipeline', () {
    test('defaults to Dry Run when the setting is missing', () async {
      expect(db.getSetting('mt5_dry_run'), isNull);
      final decision = await pipeline.process(RawMessageEvent(
        inputId: 'src1',
        message: {
          'input_id': 'src1',
          'message_id': 'dry-run-default',
          'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
          'caption': '',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        },
      ));
      expect(decision.action, DecisionAction.shadow);
      expect(decision.reason, 'mt5_dry_run_enabled');
      expect(executor.opened, isEmpty);
    });

    test('defaults to shadow mode for unknown input', () async {
      final decision = await pipeline.process(RawMessageEvent(
        inputId: 'unknown_input',
        message: {
          'input_id': 'unknown_input',
          'message_id': 'm0',
          'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
          'caption': '',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        },
      ));
      expect(decision.action, DecisionAction.shadow);
    });
    test('executes a valid signal when Dry Run is explicitly disabled', () async {
      db.setSetting('mt5_dry_run', '0');
      final decision = await pipeline.process(RawMessageEvent(
        inputId: 'src1',
        message: {
          'input_id': 'src1',
          'message_id': 'm1',
          'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
          'caption': '',
        },
      ));
      expect(decision.action, DecisionAction.execute);
      expect(executor.opened, isNotEmpty);
    });

    test('recovers a lost MT5 acknowledgement without opening a duplicate', () async {
      db.setSetting('mt5_dry_run', '0');
      executor.failOpen = true;
      executor.failOpenError = 'timeout';
      executor.loseAckAfterAccept = true;

      final message = {
        'input_id': 'src1',
        'message_id': 'm-uncertain',
        'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
        'caption': '',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };

      await expectLater(
        pipeline.process(RawMessageEvent(inputId: 'src1', message: message)),
        throwsA(isA<ExecutionPendingException>()),
      );

      final signalId = 'sig_src1_m-uncertain_0';
      expect(db.executionIntentFor(signalId)?['status'], 'uncertain');
      expect(db.executionIntentFor(signalId)?['attempts'], 1);
      expect(db.decisionFor(signalId), isNull);
      expect(executor.opened, hasLength(1));

      executor.failOpen = false;
      executor.loseAckAfterAccept = false;
      final recovered = await pipeline.process(
        RawMessageEvent(inputId: 'src1', message: message),
      );

      expect(recovered.action, DecisionAction.execute);
      expect(db.executionIntentFor(signalId)?['status'], 'acked');
      expect(db.executionIntentFor(signalId)?['order_id'], 'fake_1');
      expect(executor.opened, hasLength(1));
      expect(db.decisionFor(signalId)?['action'], 'execute');
    });

    test('queue-specific Dry Run gate overrides a disabled global Dry Run', () async {
      db.setSetting('mt5_dry_run', '0');
      final decision = await pipeline.process(RawMessageEvent(
        inputId: 'src1',
        message: {
          'input_id': 'src1',
          'message_id': 'forced-shadow',
          'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
          'caption': '',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'force_dry_run': true,
        },
      ));

      expect(decision.action, DecisionAction.shadow);
      expect(decision.reason, 'mt5_dry_run_enabled');
      expect(executor.opened, isEmpty);
      expect(db.executionIntentFor('sig_src1_forced-shadow_0'), isNull);
    });

    test('expired uncertain intent is parked for manual reconciliation', () async {
      db.setSetting('mt5_dry_run', '0');
      executor.failOpen = true;
      executor.failOpenError = 'timeout';
      executor.loseAckAfterAccept = true;

      final message = {
        'input_id': 'src1',
        'message_id': 'm-expired-uncertain',
        'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
        'caption': '',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
      await expectLater(
        pipeline.process(RawMessageEvent(inputId: 'src1', message: message)),
        throwsA(isA<ExecutionPendingException>()),
      );

      message['timestamp'] = DateTime.now()
          .toUtc()
          .subtract(const Duration(seconds: 181))
          .toIso8601String();
      final decision = await pipeline.process(
        RawMessageEvent(inputId: 'src1', message: message),
      );

      final signalId = 'sig_src1_m-expired-uncertain_0';
      expect(decision.action, DecisionAction.block);
      expect(decision.reason, contains('manual reconciliation required'));
      expect(db.executionIntentFor(signalId)?['status'], 'manual_review');
      expect(executor.opened, hasLength(1));
    });

    test('skips noise', () async {
      final decision = await pipeline.process(RawMessageEvent(
        inputId: 'src1',
        message: {
          'input_id': 'src1',
          'message_id': 'm2',
          'text': 'hello world',
          'caption': '',
        },
      ));
      expect(decision.action, DecisionAction.skip);
      expect(executor.opened, isEmpty);
    });

    test('skips invalid signal (bad geometry)', () async {
      final decision = await pipeline.process(RawMessageEvent(
        inputId: 'src1',
        message: {
          'input_id': 'src1',
          'message_id': 'm3',
          'text': 'BUY XAUUSD entry 4050 sl 4060 tp1 4080',
          'caption': '',
        },
      ));
      expect(decision.action, DecisionAction.skip);
      expect(executor.opened, isEmpty);
    });

    test('skips recap', () async {
      final decision = await pipeline.process(RawMessageEvent(
        inputId: 'src1',
        message: {
          'input_id': 'src1',
          'message_id': 'm4',
          'text': 'weekly recap: closed with profit +120 pips',
          'caption': '',
        },
      ));
      expect(decision.action, DecisionAction.skip);
      expect(executor.opened, isEmpty);
    });

    test('blocks when risk-per-lot is unavailable', () async {
      executor.riskPerLotUnavailable = true;
      final decision = await pipeline.process(RawMessageEvent(
        inputId: 'src1',
        message: {
          'input_id': 'src1',
          'message_id': 'm5',
          'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
          'caption': '',
        },
      ));
      expect(decision.action, DecisionAction.block);
      expect(decision.reason, contains('risk_per_lot_unavailable'));
      expect(executor.opened, isEmpty);
    });

    test('blocks when sizing is rejected (below broker min)', () async {
      executor.riskPerLotForSymbol = {'XAUUSD': 5000000}; // 50/5e6 = 1e-5 lots
      final decision = await pipeline.process(RawMessageEvent(
        inputId: 'src1',
        message: {
          'input_id': 'src1',
          'message_id': 'm6',
          'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
          'caption': '',
        },
      ));
      expect(decision.action, DecisionAction.block);
      expect(decision.reason, contains('sizing rejected'));
      expect(executor.opened, isEmpty);
    });

    test('two inputs with different riskPercent get different lots', () async {
      db.setSetting('mt5_dry_run', '0');
      // src1 already uses p1 (risk_percent 0.5). Add a second input at 1.0.
      db.upsertProfile('p2', {
        'id': 'p2',
        'name': 'higher risk',
        'mode': 'auto',
        'risk_percent': 1.0,
      });
      db.upsertInput({
        'id': 'src2',
        'type': 'telegram_source',
        'name': 'src2',
        'enabled': true,
        'profile_id': 'p2',
      });

      await pipeline.process(RawMessageEvent(
        inputId: 'src1',
        message: {
          'input_id': 'src1',
          'message_id': 'risk-1',
          'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
          'caption': '',
        },
      ));
      await pipeline.process(RawMessageEvent(
        inputId: 'src2',
        message: {
          'input_id': 'src2',
          'message_id': 'risk-2',
          'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
          'caption': '',
        },
      ));

      expect(executor.opened, hasLength(2));
      final lots1 = executor.opened[0].lots;
      final lots2 = executor.opened[1].lots;
      expect(lots2, greaterThan(lots1));
      // 0.5% -> 50 USD risk / 1000 USD per lot = 0.05 lots
      expect(lots1, closeTo(0.05, 1e-9));
      // 1.0% -> 100 USD risk / 1000 USD per lot = 0.10 lots
      expect(lots2, closeTo(0.10, 1e-9));
    });

    test('default risk is 0.25% when the profile omits risk_percent', () async {
      db.setSetting('mt5_dry_run', '0');
      db.upsertProfile('p3', {'id': 'p3', 'name': 'defaults', 'mode': 'auto'});
      db.upsertInput({
        'id': 'src3',
        'type': 'telegram_source',
        'name': 'src3',
        'enabled': true,
        'profile_id': 'p3',
      });

      await pipeline.process(RawMessageEvent(
        inputId: 'src3',
        message: {
          'input_id': 'src3',
          'message_id': 'default-1',
          'text': 'BUY XAUUSD entry 4050 sl 4030 tp1 4080',
          'caption': '',
        },
      ));

      expect(executor.opened, hasLength(1));
      // 0.25% of 10000 = 25 USD risk / 1000 USD per lot = 0.025 lots,
      // floored to the 0.01 volume step.
      expect(executor.opened.first.lots, closeTo(0.02, 1e-9));
    });
  });
}
