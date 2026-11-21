import 'package:nixo_core/nixo_core.dart';
import 'package:test/test.dart';

void main() {
  group('roulette', () {
    test('volume roulette win increments step', () {
      final mgr = RouletteManager(
        config: RouletteConfig(
          enabled: true,
          model: RouletteModel.volume,
          baseRiskPct: 0.25,
          maxSteps: 50,
          maxRiskPct: 2.0,
          volumeStepFactor: 1.0,
        ),
        accountTrigger: AccountRouletteTrigger(),
      );
      mgr.activateSource('src1');
      expect(mgr.volumeMultiplier('src1'), 1.0);

      final r = mgr.onBatchResult('src1', 100, 50);
      expect(r.action, 'win');
      expect(r.stepAfter, 2);
      expect(mgr.volumeMultiplier('src1'), 2.0);
      expect(mgr.currentRiskPct('src1'), 0.5);
    });

    test('volume roulette loss decrements step', () {
      final mgr = RouletteManager(
        config: RouletteConfig(
          enabled: true,
          model: RouletteModel.volume,
          maxSteps: 50,
        ),
        accountTrigger: AccountRouletteTrigger(),
      );
      mgr.activateSource('src1');
      mgr.onBatchResult('src1', 100, 50); // win -> step 2
      final r = mgr.onBatchResult('src1', -50, 50); // loss -> step 1
      expect(r.action, 'loss');
      expect(r.stepAfter, 1);
    });

    test('flat does not change step', () {
      final mgr = RouletteManager(
        config: RouletteConfig(
          enabled: true,
          model: RouletteModel.volume,
          maxSteps: 50,
        ),
        accountTrigger: AccountRouletteTrigger(),
      );
      mgr.activateSource('src1');
      mgr.onBatchResult('src1', 100, 50); // win -> step 2
      final r = mgr.onBatchResult('src1', 2, 50); // |2| < 0.15*50=7.5 -> flat
      expect(r.action, 'flat');
      expect(r.stepAfter, 2);
    });

    test('order roulette win doubles', () {
      final mgr = RouletteManager(
        config: RouletteConfig(
          enabled: true,
          model: RouletteModel.order,
          maxSteps: 8,
          maxOrderCount: 8,
          initialOrderCount: 1,
        ),
        accountTrigger: AccountRouletteTrigger(),
      );
      mgr.activateSource('src1');
      final r = mgr.onBatchResult('src1', 100, 50);
      expect(r.stepAfter, 2);
      expect(mgr.orderCount('src1'), 2);
    });

    test('account trigger activates at +3%', () {
      final trigger = AccountRouletteTrigger(triggerPct: 3.0);
      trigger.baselineEquity = 10000;
      expect(trigger.checkActivate(10300), isTrue);
      expect(trigger.checkActivate(10100), isFalse);
    });
  });
}
