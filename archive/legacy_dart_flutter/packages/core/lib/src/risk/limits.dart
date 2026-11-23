/// Global and per-input trading limits.
///
/// When a limit trips: block NEW entries, keep managing open trades, alert
/// loudly.
library;

class GlobalLimits {
  GlobalLimits({
    this.maxOpenRiskPct = 5.0,
    this.maxPositions = 50,
    this.maxDailyLossPct = 3.0,
    this.maxDrawdownPct = 20.0,
  });

  final double maxOpenRiskPct;
  final int maxPositions;
  final double maxDailyLossPct;
  final double maxDrawdownPct;
}

class LimitsState {
  LimitsState({
    this.dayStartEquity,
    this.peakEquity,
    this.todayRealizedLoss = 0,
    this.todayTrades = 0,
    this.openRiskPct = 0,
    this.openPositions = 0,
  });

  double? dayStartEquity;
  double? peakEquity;
  double todayRealizedLoss;
  int todayTrades;
  double openRiskPct;
  int openPositions;
}

class LimitsCheck {
  LimitsCheck({required this.blocked, this.reasons = const []});

  final bool blocked;
  final List<String> reasons;
}

class LimitsManager {
  LimitsManager({GlobalLimits? limits}) : limits = limits ?? GlobalLimits();

  final GlobalLimits limits;
  final LimitsState state = LimitsState();

  /// Reset daily counters (called at day boundary).
  void rolloverDay(double equity) {
    state.dayStartEquity = equity;
    state.todayRealizedLoss = 0;
    state.todayTrades = 0;
  }

  void updateEquity(double equity) {
    if (state.peakEquity == null || equity > state.peakEquity!) {
      state.peakEquity = equity;
    }
    if (state.dayStartEquity == null) {
      state.dayStartEquity = equity;
    }
  }

  void recordTradeResult(double pnl) {
    state.todayTrades++;
    if (pnl < 0) state.todayRealizedLoss += pnl.abs();
  }

  double get drawdownPct {
    final peak = state.peakEquity;
    if (peak == null || peak <= 0) return 0;
    final current = state.dayStartEquity ?? peak;
    final dd = (peak - current) / peak * 100;
    return dd < 0 ? 0 : dd;
  }

  double get dailyLossPct {
    final base = state.dayStartEquity;
    if (base == null || base <= 0) return 0;
    return state.todayRealizedLoss / base * 100;
  }

  LimitsCheck check() {
    final reasons = <String>[];
    if (dailyLossPct >= limits.maxDailyLossPct) {
      reasons.add('daily loss limit reached (${dailyLossPct.toStringAsFixed(2)}%)');
    }
    if (drawdownPct >= limits.maxDrawdownPct) {
      reasons.add('max drawdown reached (${drawdownPct.toStringAsFixed(2)}%)');
    }
    if (state.openRiskPct >= limits.maxOpenRiskPct) {
      reasons.add('open risk limit reached (${state.openRiskPct.toStringAsFixed(2)}%)');
    }
    if (state.openPositions >= limits.maxPositions) {
      reasons.add('max positions reached (${state.openPositions})');
    }
    return LimitsCheck(blocked: reasons.isNotEmpty, reasons: reasons);
  }
}

/// Per-input limits.
class PerInputLimits {
  PerInputLimits({
    this.maxTradesPerDay = 10,
    this.maxConcurrent = 5,
    this.dailyLossPercent = 5.0,
    this.consecutiveLossPause = 3,
  });

  final int maxTradesPerDay;
  final int maxConcurrent;
  final double dailyLossPercent;
  final int consecutiveLossPause;
}

class PerInputState {
  PerInputState({
    this.todayTrades = 0,
    this.concurrent = 0,
    this.consecutiveLosses = 0,
    this.todayLoss = 0,
  });

  int todayTrades;
  int concurrent;
  int consecutiveLosses;
  double todayLoss;
}

class PerInputLimitsManager {
  PerInputLimitsManager({PerInputLimits? limits})
      : limits = limits ?? PerInputLimits();

  final PerInputLimits limits;
  final Map<String, PerInputState> _states = {};

  PerInputState state(String sourceId) =>
      _states.putIfAbsent(sourceId, () => PerInputState());

  bool canOpen(String sourceId, {double? equity}) {
    final s = state(sourceId);
    if (s.todayTrades >= limits.maxTradesPerDay) return false;
    if (s.concurrent >= limits.maxConcurrent) return false;
    if (s.consecutiveLosses >= limits.consecutiveLossPause) return false;
    if (equity != null && equity > 0 &&
        s.todayLoss / equity * 100 >= limits.dailyLossPercent) {
      return false;
    }
    return true;
  }

  void onOpen(String sourceId) {
    final s = state(sourceId);
    s.todayTrades++;
    s.concurrent++;
  }

  void onClose(String sourceId, double pnl) {
    final s = state(sourceId);
    s.concurrent = s.concurrent - 1 < 0 ? 0 : s.concurrent - 1;
    if (pnl < 0) {
      s.consecutiveLosses++;
      s.todayLoss += pnl.abs();
    } else {
      s.consecutiveLosses = 0;
    }
  }
}
