/// Deterministic validator. Mandatory for every signal (text or image).
///
/// A failed validator NEVER executes, regardless of any timeout or setting.
library;

import 'models.dart';

class ValidatorConfig {
  ValidatorConfig({
    this.maxEntryDeviationPoints = 200,
    this.maxSpreadPoints = 100,
    this.maxSignalAgeSeconds = 180,
    this.minRr = 0.5,
    this.requireSl = true,
    this.requireSide = true,
    this.requireSymbol = true,
  });

  final int maxEntryDeviationPoints;
  final int maxSpreadPoints;
  final int maxSignalAgeSeconds;
  final double minRr;
  final bool requireSl;
  final bool requireSide;
  final bool requireSymbol;
}

class SignalValidator {
  SignalValidator({ValidatorConfig? config}) : config = config ?? ValidatorConfig();

  final ValidatorConfig config;

  ValidationResult validate(ParsedSignal signal, Quote? quote, {
    DateTime? now,
    bool marketOpen = true,
  }) {
    final reasons = <String>[];

    // Symbol.
    if (config.requireSymbol && signal.symbol.isEmpty) {
      reasons.add('missing symbol');
    }

    // Side.
    if (config.requireSide && signal.side == null) {
      reasons.add('missing side');
    }

    // Entry.
    if (!signal.hasEntry) {
      reasons.add('missing entry');
    }

    // SL.
    if (config.requireSl && !signal.hasSl) {
      reasons.add('missing SL');
    }

    // Geometry: SL must be on the correct side of entry.
    if (signal.side != null && signal.hasEntry && signal.hasSl) {
      final entryMid = signal.entryIsMarket
          ? (quote?.mid() ?? 0)
          : ((signal.entryLow ?? 0) + (signal.entryHigh ?? signal.entryLow ?? 0)) / 2;
      final sl = signal.sl!;
      if (signal.side == Side.buy && sl >= entryMid) {
        reasons.add('SL above entry for a buy');
      }
      if (signal.side == Side.sell && sl <= entryMid) {
        reasons.add('SL below entry for a sell');
      }
    }

    // R:R consistency.
    if (signal.hasSl && signal.side != null && signal.hasEntry) {
      final entryMid = signal.entryIsMarket
          ? (quote?.mid() ?? 0)
          : ((signal.entryLow ?? 0) + (signal.entryHigh ?? signal.entryLow ?? 0)) / 2;
      final risk = (signal.sl! - entryMid).abs();
      if (risk <= 0) {
        reasons.add('zero risk');
      } else {
        for (final tp in signal.tps) {
          // Only enforce R:R for TPs that are on the profit side of the entry.
          final onProfitSide = signal.side == Side.buy
              ? tp > entryMid
              : tp < entryMid;
          if (!onProfitSide) continue;
          final reward = (tp - entryMid).abs();
          final rr = reward / risk;
          if (rr < config.minRr) {
            reasons.add('TP R:R below minimum (${rr.toStringAsFixed(2)})');
          }
        }
      }
    }

    // Entry vs live quote (max deviation).
    if (quote != null && !signal.entryIsMarket) {
      final entryMid = ((signal.entryLow ?? 0) + (signal.entryHigh ?? signal.entryLow ?? 0)) / 2;
      final quoteMid = quote.mid();
      if (quote.point > 0) {
        final devPoints = ((entryMid - quoteMid).abs() / quote.point).round();
        if (devPoints > config.maxEntryDeviationPoints) {
          reasons.add('entry deviation too large (${devPoints} pts)');
        }
      } else if (quote.tickSize > 0) {
        final devPoints = ((entryMid - quoteMid).abs() / quote.tickSize).round();
        if (devPoints > config.maxEntryDeviationPoints) {
          reasons.add('entry deviation too large (${devPoints} ticks)');
        }
      }
    }

    // Spread.
    if (quote != null && quote.spreadPoints > config.maxSpreadPoints) {
      reasons.add('spread too wide (${quote.spreadPoints} pts)');
    }

    // Market open.
    if (!marketOpen) {
      reasons.add('market closed');
    }

    // Signal age.
    if (now != null && signal.rawText != null) {
      // Age is computed by the pipeline; here we only check if a timestamp was
      // attached via the raw message. Keep it simple: age checked in pipeline.
    }

    return ValidationResult(valid: reasons.isEmpty, reasons: reasons);
  }
}
