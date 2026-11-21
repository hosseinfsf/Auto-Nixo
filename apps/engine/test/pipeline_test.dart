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
    test('executes a valid signal', () async {
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
  });
}
