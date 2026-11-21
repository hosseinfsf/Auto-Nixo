import 'package:nixo_core/nixo_core.dart';
import 'package:test/test.dart';

void main() {
  RouletteManager mgr({double baseRisk = 0.5, double maxRisk = 5.0, int maxSteps = 50}) {
    return RouletteManager(
      config: RouletteConfig(
        enabled: true,
        model: RouletteModel.volume,
        baseRiskPct: baseRisk,
        maxSteps: maxSteps,
        maxRiskPct: maxRisk,
        volumeStepFactor: 2.0,
      ),
      accountTrigger: AccountRouletteTrigger(),
    );
  }

  group('roulette defaults', () {
    test('defaults match owner spec', () {
      final c = RouletteConfig();
      expect(c.baseRiskPct, 0.5);
      expect(c.triggerPct, 3.0);
      expect(c.maxSteps, 50);
      expect(c.volumeStepFactor, 2.0);
      expect(c.model, RouletteModel.volume);
    });
  });

  group('volume roulette', () {
    test('multiplier follows doubling progression', () {
      final m = mgr();
      m.activateSource('src1');
      expect(m.volumeMultiplier('src1'), 1.0); // step 1 -> 0.5%

      m.onBatchResult('src1', 100, 50); // win -> step 2
      expect(m.volumeMultiplier('src1'), 2.0); // 1.0%
      expect(m.currentRiskPct('src1'), 1.0);

      m.onBatchResult('src1', 100, 50); // win -> step 3
      expect(m.volumeMultiplier('src1'), 4.0); // 2.0%
      expect(m.currentRiskPct('src1'), 2.0);
    });

    test('risk cap caps the multiplier', () {
      final m = mgr(baseRisk: 0.5, maxRisk: 2.0);
      m.activateSource('src1');
      // advance to step 4 (raw 4.0% -> capped at 2.0%)
      for (var i = 0; i < 3; i++) {
        m.onBatchResult('src1', 100, 50);
      }
      expect(m.currentRiskPct('src1'), 2.0);
      expect(m.volumeMultiplier('src1'), 4.0); // 2.0/0.5
    });

    test('loss decrements step', () {
      final m = mgr();
      m.activateSource('src1');
      m.onBatchResult('src1', 100, 50); // win -> step 2
      final r = m.onBatchResult('src1', -50, 50); // loss -> step 1
      expect(r.action, 'loss');
      expect(r.stepAfter, 1);
      expect(m.volumeMultiplier('src1'), 1.0);
    });

    test('flat does not change step', () {
      final m = mgr();
      m.activateSource('src1');
      m.onBatchResult('src1', 100, 50); // win -> step 2
      final r = m.onBatchResult('src1', 2, 50); // |2| < 7.5 -> flat
      expect(r.action, 'flat');
      expect(r.stepAfter, 2);
    });

    test('step caps at maxStep 50', () {
      final m = mgr(maxSteps: 50);
      m.activateSource('src1');
      for (var i = 0; i < 100; i++) {
        m.onBatchResult('src1', 100, 50);
      }
      expect(m.getState('src1').step, 50);
    });
  });

  group('account trigger', () {
    test('activates at exactly +3%', () {
      final t = AccountRouletteTrigger(triggerPct: 3.0);
      t.baselineEquity = 10000;
      expect(t.checkActivate(10300), isTrue);
    });

    test('does not activate below 3%', () {
      final t = AccountRouletteTrigger(triggerPct: 3.0);
      t.baselineEquity = 10000;
      expect(t.checkActivate(10299), isFalse);
    });

    test('activates above 3%', () {
      final t = AccountRouletteTrigger(triggerPct: 3.0);
      t.baselineEquity = 10000;
      expect(t.checkActivate(10400), isTrue);
    });
  });

  group('order roulette (independent, OFF by default)', () {
    test('default model is volume, not order', () {
      final c = RouletteConfig();
      expect(c.model, RouletteModel.volume);
    });

    test('order count is 1 when model is volume', () {
      final m = mgr();
      m.activateSource('src1');
      expect(m.orderCount('src1'), 1);
    });
  });

  group('persistence hook', () {
    test('restore keeps state and persist fires on change', () {
      final persisted = <RouletteState>[];
      final m = RouletteManager(
        config: RouletteConfig(model: RouletteModel.volume, maxSteps: 50),
        accountTrigger: AccountRouletteTrigger(),
        persist: persisted.add,
      );
      m.activateSource('src1');
      m.onBatchResult('src1', 100, 50);
      expect(persisted, isNotEmpty);
      expect(persisted.last.step, 2);

      // Simulate restart: restore from persisted state.
      final m2 = RouletteManager(
        config: RouletteConfig(model: RouletteModel.volume, maxSteps: 50),
        accountTrigger: AccountRouletteTrigger(),
      );
      m2.restore('src1', persisted.last);
      expect(m2.getState('src1').step, 2);
      expect(m2.getState('src1').activated, isTrue);
    });
  });
}
