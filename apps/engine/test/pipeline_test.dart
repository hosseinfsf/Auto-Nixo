import 'package:nixo_core/nixo_core.dart';
import 'package:nixo_engine/src/db.dart';
import 'package:nixo_engine/src/pipeline.dart';
import 'package:nixo_engine/src/replay.dart';
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
  });
}
