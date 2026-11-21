/// Roulette (risk ladder / order / volume) per source.
///
/// Ported EXACTLY from docs/ROULETTE_SPEC.md and the reference EA
/// (Nixo_v5.04_TradingModes_AdvancedAnalytics.mq5), with the documented engine
/// deviations (order roulette win doubles; defaults differ).
library;

enum RouletteModel { off, volume, order, combined }

class RouletteConfig {
  RouletteConfig({
    this.enabled = false,
    this.model = RouletteModel.off,
    this.baseRiskPct = 0.5,
    this.maxSteps = 3,
    this.maxRiskPct = 2.0,
    this.volumeStepFactor = 1.0,
    this.initialOrderCount = 1,
    this.maxOrderCount = 8,
    this.triggerPct = 3.0,
  });

  final bool enabled;
  final RouletteModel model;
  final double baseRiskPct;
  final int maxSteps;
  final double maxRiskPct;
  final double volumeStepFactor;
  final int initialOrderCount;
  final int maxOrderCount;
  final double triggerPct;
}

class RouletteState {
  RouletteState({
    required this.sourceId,
    this.model = RouletteModel.off,
    this.step = 1,
    this.maxStep = 3,
    this.activated = false,
  });

  final String sourceId;
  RouletteModel model;
  int step;
  int maxStep;
  bool activated;
}

class AccountRouletteTrigger {
  AccountRouletteTrigger({
    this.baselineEquity = 0,
    this.triggerPct = 3.0,
    this.activated = false,
  });

  double baselineEquity;
  final double triggerPct;
  bool activated;

  double gainPct(double currentEquity) {
    if (baselineEquity <= 0) return 0;
    return (currentEquity - baselineEquity) / baselineEquity * 100;
  }

  bool checkActivate(double currentEquity) {
    if (activated) return true;
    if (triggerPct <= 0) {
      activated = true;
      return true;
    }
    if (gainPct(currentEquity) >= triggerPct) {
      activated = true;
      return true;
    }
    return false;
  }

  void resetEpoch(double equity) {
    baselineEquity = equity;
    activated = false;
  }
}

class RouletteResult {
  RouletteResult({
    required this.sourceId,
    required this.activated,
    required this.stepBefore,
    required this.stepAfter,
    required this.action,
    this.netProfit,
  });

  final String sourceId;
  final bool activated;
  final int stepBefore;
  final int stepAfter;
  final String action; // win | loss | flat | not_activated
  final double? netProfit;
}

class RouletteManager {
  RouletteManager({
    required this.config,
    required this.accountTrigger,
  });

  final RouletteConfig config;
  final AccountRouletteTrigger accountTrigger;
  final Map<String, RouletteState> _states = {};

  RouletteState getState(String sourceId) {
    return _states.putIfAbsent(sourceId, () {
      return RouletteState(
        sourceId: sourceId,
        model: config.model,
        step: 1,
        maxStep: config.maxSteps,
        activated: false,
      );
    });
  }

  /// Volume roulette multiplier = 1 + factor * (step - 1).
  double volumeMultiplier(String sourceId) {
    final s = getState(sourceId);
    if (!s.activated || (config.model != RouletteModel.volume &&
        config.model != RouletteModel.combined)) {
      return 1.0;
    }
    return 1.0 + (config.volumeStepFactor < 0 ? 0 : config.volumeStepFactor) *
        (s.step - 1 < 0 ? 0 : s.step - 1);
  }

  /// Order roulette count.
  int orderCount(String sourceId) {
    final s = getState(sourceId);
    if (!s.activated || (config.model != RouletteModel.order &&
        config.model != RouletteModel.combined)) {
      return 1;
    }
    return s.step;
  }

  /// Current risk % = base_risk_pct * step (capped at max_risk_pct).
  double currentRiskPct(String sourceId) {
    final s = getState(sourceId);
    if (!s.activated) return config.baseRiskPct;
    final risk = config.baseRiskPct * s.step;
    return risk > config.maxRiskPct ? config.maxRiskPct : risk;
  }

  /// Update after a batch closes.
  RouletteResult onBatchResult(String sourceId, double netProfit, double riskMoney) {
    final s = getState(sourceId);
    if (!s.activated) {
      return RouletteResult(
        sourceId: sourceId,
        activated: false,
        stepBefore: s.step,
        stepAfter: s.step,
        action: 'not_activated',
      );
    }

    // Flat check: |profit| < 0.15 * riskMoney
    final flat = riskMoney > 0 && netProfit.abs() < 0.15 * riskMoney;
    final stepBefore = s.step;
    String action = 'flat';

    if (!flat && netProfit > 0) {
      // Win
      if (config.model == RouletteModel.volume ||
          config.model == RouletteModel.combined) {
        s.step = s.step + 1 > s.maxStep ? s.maxStep : s.step + 1;
      }
      if (config.model == RouletteModel.order ||
          config.model == RouletteModel.combined) {
        // Documented deviation: order win doubles.
        if (s.step > config.maxOrderCount / 2) {
          s.step = config.maxOrderCount;
        } else {
          s.step = s.step * 2;
        }
      }
      if (s.step > s.maxStep) s.step = s.maxStep;
      action = 'win';
    } else if (!flat && netProfit < 0) {
      // Loss
      s.step = s.step - 1 < 1 ? 1 : s.step - 1;
      action = 'loss';
    }

    return RouletteResult(
      sourceId: sourceId,
      activated: true,
      stepBefore: stepBefore,
      stepAfter: s.step,
      action: action,
      netProfit: netProfit,
    );
  }

  void activateSource(String sourceId) {
    getState(sourceId).activated = true;
  }

  void deactivateSource(String sourceId) {
    final s = getState(sourceId);
    s.activated = false;
    s.step = 1;
  }
}
