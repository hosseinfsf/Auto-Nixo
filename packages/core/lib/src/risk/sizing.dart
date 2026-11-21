/// Position sizing.
///
/// Default mode: RISK PERCENTAGE OF ACCOUNT EQUITY (base risk 0.50%).
/// Fixed-lot sizing is NOT part of the normal workflow; it exists only as a
/// deprecated legacy option that is disabled by default and cannot be
/// activated accidentally (see [SizingConfig.legacyFixedLotAllowed]).
///
/// The final lot is computed in the EA via OrderCalcProfit; here we compute the
/// *risk-based* target lot from the authoritative risk-per-lot value supplied
/// by MT5 and clamp it. If the computed volume falls below the broker minimum
/// or above the maximum, the trade is REJECTED (never silently adjusted).
library;

import '../models.dart';

enum SizeMode { riskPercent, fixedCash, fixedLot }

class SizingConfig {
  SizingConfig({
    this.mode = SizeMode.riskPercent,
    this.riskPercent = 0.5,
    this.riskMultiplier = 1.0,
    this.fixedCash,
    this.fixedLot,
    this.legacyFixedLotAllowed = false,
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

  /// When false (default), fixed-lot sizing is rejected outright. Set to true
  /// only through a separate advanced/legacy configuration path.
  final bool legacyFixedLotAllowed;

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
  ///
  /// [account] supplies equity/balance; [riskPerLot] is the authoritative
  /// monetary risk per 1.0 lot at the SL distance, as computed by the EA via
  /// OrderCalcProfit. It must be > 0; otherwise the trade is rejected.
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
        if (!config.legacyFixedLotAllowed) {
          return SizingResult(lots: 0, reason: 'fixed_lot_disabled');
        }
        lots = config.fixedLot ?? 0.01;
        reason = 'fixed_lot_legacy';
        break;
      case SizeMode.fixedCash:
        final cash = config.fixedCash ?? 0;
        final riskPerLotLocal = riskPerLot ?? 0;
        if (riskPerLotLocal <= 0) {
          return SizingResult(lots: 0, reason: 'risk_per_lot_unknown');
        }
        lots = cash / riskPerLotLocal;
        reason = 'fixed_cash';
        break;
      case SizeMode.riskPercent:
        final base = account.equity > 0 ? account.equity : account.balance;
        final riskMoney = base * (config.riskPercent / 100.0) * config.riskMultiplier;
        final riskPerLotLocal = riskPerLot ?? 0;
        if (riskPerLotLocal <= 0) {
          return SizingResult(lots: 0, reason: 'risk_per_lot_unknown');
        }
        lots = riskMoney / riskPerLotLocal;
        reason = 'risk_percent';
        break;
    }

    // Round DOWN to the broker volume step.
    lots = _roundDownToStep(lots, config.lotStep);

    // Reject (do not silently adjust) if outside broker limits.
    if (lots < config.minLot) {
      return SizingResult(lots: 0, reason: 'below_broker_minimum');
    }
    if (lots > config.maxLot) {
      return SizingResult(lots: 0, reason: 'above_max_lot');
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
