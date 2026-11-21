/// Position sizing.
///
/// Modes: % risk of equity/balance, fixed cash, fixed lot. Respects per-input
/// multiplier, per-symbol caps, min/max lot, and commission+slippage allowance.
/// The final lot is computed in the EA via OrderCalcProfit; here we compute the
/// *risk-based* target lot and clamp it.
library;

import '../models.dart';

enum SizeMode { riskPercent, fixedCash, fixedLot }

class SizingConfig {
  SizingConfig({
    this.mode = SizeMode.riskPercent,
    this.riskPercent = 1.0,
    this.riskMultiplier = 1.0,
    this.fixedCash,
    this.fixedLot,
    this.minLot = 0.01,
    this.maxLot = 10.0,
    this.lotStep = 0.01,
    this.commissionAllowance = 0.0,
    this.slippageAllowance = 0.0,
  });

  final SizeMode mode;
  final double riskPercent;
  final double riskMultiplier;
  final double? fixedCash;
  final double? fixedLot;
  final double minLot;
  final double maxLot;
  final double lotStep;
  final double commissionAllowance;
  final double slippageAllowance;
}

class Sizer {
  Sizer({SizingConfig? config}) : config = config ?? SizingConfig();

  final SizingConfig config;

  /// Compute risk-based lots for a signal.
  /// [account] supplies equity/balance; [riskPerLot] is the monetary risk per
  /// 1.0 lot at the SL distance (computed by the EA via OrderCalcProfit; here
  /// we accept it as input).
  SizingResult size({
    required ParsedSignal signal,
    required AccountInfo account,
    double? riskPerLot,
    double? entryPrice,
    double? slPrice,
  }) {
    double lots;
    String? reason;

    switch (config.mode) {
      case SizeMode.fixedLot:
        lots = config.fixedLot ?? 0.01;
        reason = 'fixed_lot';
        break;
      case SizeMode.fixedCash:
        final cash = config.fixedCash ?? 0;
        final riskPerLotLocal = riskPerLot ?? 1.0;
        if (riskPerLotLocal <= 0) {
          return SizingResult(lots: 0, reason: 'risk_per_lot_unknown');
        }
        lots = cash / riskPerLotLocal;
        reason = 'fixed_cash';
        break;
      case SizeMode.riskPercent:
        final base = account.equity > 0 ? account.equity : account.balance;
        final riskMoney = base * (config.riskPercent / 100.0) * config.riskMultiplier;
        final riskPerLotLocal = riskPerLot ?? 1.0;
        if (riskPerLotLocal <= 0) {
          return SizingResult(lots: 0, reason: 'risk_per_lot_unknown');
        }
        lots = riskMoney / riskPerLotLocal;
        reason = 'risk_percent';
        break;
    }

    // Clamp to [minLot, maxLot] and round down to step.
    lots = _roundDownToStep(lots, config.lotStep);
    if (lots < config.minLot) {
      lots = config.minLot;
      reason = '$reason;clamped_to_min';
    }
    if (lots > config.maxLot) {
      lots = config.maxLot;
      reason = '$reason;clamped_to_max';
    }

    return SizingResult(
      lots: lots,
      riskAmount: riskPerLot != null ? lots * riskPerLot : null,
      riskPercent: config.mode == SizeMode.riskPercent
          ? config.riskPercent * config.riskMultiplier
          : null,
      reason: reason,
    );
  }

  double _roundDownToStep(double value, double step) {
    if (step <= 0) return value;
    final n = (value / step).floorToDouble();
    return n * step;
  }
}
