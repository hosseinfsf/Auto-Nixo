/// Roulette (risk ladder / volume / order) per source.
///
/// Defaults (per owner specification):
///   - Volume roulette: ON after activation (model = volume).
///   - Activation threshold: 3% account growth vs stored baseline equity.
///   - Base risk: 0.50%.
///   - Maximum step: 50 (step INDEX, not unlimited exposure).
///   - Volume multiplier per step: 2.0 (each step doubles the previous).
///   - Independent, configurable maximum risk percentage cap.
///   - Order roulette: OFF by default (independent of volume roulette).
///
/// The step is updated ONLY after a complete trade batch closes and its actual
/// net result (profit/loss + commission + swap) is known.
library;

import 'dart:math';

enum RouletteModel { off, volume, order, combined }

class RouletteConfig {
  RouletteConfig({
    this.enabled = true,
    this.model = RouletteModel.volume,
    this.baseRiskPct = 0.5,
    this.maxSteps = 50,
    this.maxRiskPct = 5.0,
    this.volumeStepFactor = 2.0,
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
    this.model = RouletteModel.volume,
    this.step = 1,
    this.maxStep = 50,
    this.activated = false,
  });

  final String sourceId;
  RouletteModel model;
  int step;
  int maxStep;
  bool activated;

  Map<String, dynamic> toJson() => {
        'source_id': sourceId,
        'model': model.name,
        'step': step,
        'max_step': maxStep,
        'activated': activated,
      };
}

/// Account-level activation trigger based on baseline equity.
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

/// Optional persistence hook. The engine wires this to SQLite
/// (roulette_states table) so state survives restarts.
typedef RoulettePersist = void Function(RouletteState state);

class RouletteManager {
  RouletteManager({
    required this.config,
    required this.accountTrigger,
    this.persist,
  });

  final RouletteConfig config;
  final AccountRouletteTrigger accountTrigger;
  final RoulettePersist? persist;
  final Map<String, RouletteState> _states = {};

  /// Restore a persisted state (called by the engine on startup).
  void restore(String sourceId, RouletteState state) {
    _states[sourceId] = state;
  }

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

  void _persist(String sourceId) {
    persist?.call(getState(sourceId));
  }

  /// Current risk % = base_risk_pct * 2^(step-1), capped at max_risk_pct.
  double currentRiskPct(String sourceId) {
    final s = getState(sourceId);
    if (!s.activated) return config.baseRiskPct;
    if (config.baseRiskPct <= 0) return 0;
    final raw = config.baseRiskPct * pow(2, s.step - 1).toDouble();
    return raw > config.maxRiskPct ? config.maxRiskPct : raw;
  }

  /// Volume roulette multiplier relative to base risk. Because exposure is
  /// capped by [currentRiskPct], the multiplier is capped accordingly.
  double volumeMultiplier(String sourceId) {
    final s = getState(sourceId);
    if (!s.activated || (config.model != RouletteModel.volume &&
        config.model != RouletteModel.combined)) {
      return 1.0;
    }
    if (config.baseRiskPct <= 0) return 1.0;
    return currentRiskPct(sourceId) / config.baseRiskPct;
  }

  /// Order roulette count (OFF by default).
  int orderCount(String sourceId) {
    final s = getState(sourceId);
    if (!s.activated || (config.model != RouletteModel.order &&
        config.model != RouletteModel.combined)) {
      return 1;
    }
    return s.step;
  }

  /// Update after a complete batch closes. The step changes ONLY here.
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
      // Win: advance one step (capped at maxStep).
      s.step = s.step + 1 > s.maxStep ? s.maxStep : s.step + 1;
      action = 'win';
    } else if (!flat && netProfit < 0) {
      // Loss: retreat one step (min 1).
      s.step = s.step - 1 < 1 ? 1 : s.step - 1;
      action = 'loss';
    }

    _persist(sourceId);

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
    _persist(sourceId);
  }

  void deactivateSource(String sourceId) {
    final s = getState(sourceId);
    s.activated = false;
    s.step = 1;
    _persist(sourceId);
  }
}
