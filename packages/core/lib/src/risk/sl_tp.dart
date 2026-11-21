/// SL/TP policy resolution.
///
/// SL policy: use signal / ATR default / fixed points / reject.
/// TP policy: use signal / default R:R / split ladder.
library;

import '../models.dart';

class SlTpConfig {
  SlTpConfig({
    this.slPolicy = SlPolicy.signal,
    this.atrPeriod = 14,
    this.atrMultiplier = 2.5,
    this.fixedSlPoints,
    this.minSlPoints = 300,
    this.defaultTpRr = 3.0,
    this.tpPolicy = TpPolicy.signal,
    this.tpLadder = const [1.0, 2.0, 3.0],
    this.tpLotsPercent = const [0.5, 0.5, 0.125],
    this.breakEvenTriggerR = 1.0,
    this.trailAtrMultiplier = 1.2,
  });

  final SlPolicy slPolicy;
  final int atrPeriod;
  final double atrMultiplier;
  final double? fixedSlPoints;
  final int minSlPoints;
  final double defaultTpRr;
  final TpPolicy tpPolicy;
  final List<double> tpLadder; // R multiples for split ladder
  final List<double> tpLotsPercent; // fraction of volume closed per TP
  final double breakEvenTriggerR;
  final double trailAtrMultiplier;
}

class SlTpResult {
  SlTpResult({
    this.sl,
    this.tps = const [],
    this.rejectReason,
    this.filledFields = const [],
  });

  final double? sl;
  final List<double> tps;
  final String? rejectReason;
  final List<String> filledFields; // e.g. ["sl_default", "tp_default_1:3"]
}

class SlTpResolver {
  SlTpResolver({SlTpConfig? config, this.atr, this.tpRr})
      : config = config ?? SlTpConfig();

  final SlTpConfig config;
  final double? atr; // current ATR value
  final double? tpRr; // per-source RR override

  SlTpResult resolve(ParsedSignal signal, Quote? quote, {double? tpRr}) {
    final effectiveRr = tpRr ?? this.tpRr ?? config.defaultTpRr;
    final filled = <String>[];
    double? sl;
    final tps = <double>[];

    // ---- SL ----
    switch (config.slPolicy) {
      case SlPolicy.signal:
        if (signal.sl != null) {
          sl = signal.sl;
        } else {
          return SlTpResult(rejectReason: 'SL policy=signal but signal has no SL');
        }
        break;
      case SlPolicy.atrDefault:
        if (atr != null && atr! > 0) {
          sl = _relativeFromEntry(signal, quote, atr! * config.atrMultiplier, isSl: true);
          filled.add('sl_default_atr');
        } else if (signal.sl != null) {
          sl = signal.sl;
          filled.add('sl_signal');
        } else {
          return SlTpResult(rejectReason: 'ATR default SL but no ATR and no signal SL');
        }
        break;
      case SlPolicy.fixedPoints:
        if (config.fixedSlPoints != null && quote?.point != null) {
          final dist = config.fixedSlPoints! * quote!.point;
          sl = _relativeFromEntry(signal, quote, dist, isSl: true);
          filled.add('sl_fixed_points');
        } else {
          return SlTpResult(rejectReason: 'fixed-points SL but no quote/point');
        }
        break;
      case SlPolicy.reject:
        if (signal.sl == null) {
          return SlTpResult(rejectReason: 'SL policy=reject and signal has no SL');
        }
        sl = signal.sl;
        break;
    }

    // ---- TP ----
    switch (config.tpPolicy) {
      case TpPolicy.signal:
        if (signal.tps.isNotEmpty) {
          tps.addAll(signal.tps);
        } else {
          // Default R:R fallback.
          final tp = _tpFromRr(signal, quote, effectiveRr);
          if (tp != null) {
            tps.add(tp);
            filled.add('tp_default_1:${effectiveRr.toStringAsFixed(1)}');
          }
        }
        break;
      case TpPolicy.defaultRR:
        final tp = _tpFromRr(signal, quote, effectiveRr);
        if (tp != null) {
          tps.add(tp);
          filled.add('tp_default_1:${effectiveRr.toStringAsFixed(1)}');
        }
        break;
      case TpPolicy.splitLadder:
        for (final r in config.tpLadder) {
          final tp = _tpFromRr(signal, quote, r);
          if (tp != null) tps.add(tp);
        }
        filled.add('tp_split_ladder');
        break;
    }

    // Enforce minimum valid SL distance (in points) when a quote is available.
    if (sl != null && quote != null && quote.point > 0) {
      final entry = _entryMid(signal, quote);
      if (entry > 0 && (entry - sl).abs() < config.minSlPoints * quote.point) {
        return SlTpResult(rejectReason: 'SL too close to entry');
      }
    }

    return SlTpResult(sl: sl, tps: tps, filledFields: filled);
  }

  double _entryMid(ParsedSignal signal, Quote? quote) {
    if (signal.entryIsMarket) return quote?.mid() ?? 0;
    return ((signal.entryLow ?? 0) + (signal.entryHigh ?? signal.entryLow ?? 0)) / 2;
  }

  double? _relativeFromEntry(ParsedSignal signal, Quote? quote, double distance,
      {required bool isSl}) {
    final entry = _entryMid(signal, quote);
    final side = signal.side;
    if (side == null) return null;
    if (isSl) {
      return side == Side.buy ? entry - distance : entry + distance;
    } else {
      return side == Side.buy ? entry + distance : entry - distance;
    }
  }

  double? _tpFromRr(ParsedSignal signal, Quote? quote, double rr) {
    final sl = signal.sl;
    if (sl == null) return null;
    final entry = _entryMid(signal, quote);
    final risk = (entry - sl).abs();
    if (risk <= 0) return null;
    if (signal.side == Side.buy) return entry + risk * rr;
    return entry - risk * rr;
  }
}
