import 'package:nixo_core/nixo_core.dart';
import 'package:test/test.dart';

void main() {
  final validator = SignalValidator();
  final quote = Quote(
    symbol: 'XAUUSD',
    bid: 4050.0,
    ask: 4050.5,
    spreadPoints: 5,
    point: 0.01,
    digits: 2,
    tickSize: 0.01,
  );

  group('validator', () {
    test('passes a valid signal', () {
      final s = ParsedSignal(
        symbol: 'XAUUSD',
        side: Side.buy,
        entryLow: 4050,
        sl: 4030,
        tps: [4080],
      );
      final r = validator.validate(s, quote);
      expect(r.valid, isTrue);
    });

    test('rejects SL above entry for buy', () {
      final s = ParsedSignal(
        symbol: 'XAUUSD',
        side: Side.buy,
        entryLow: 4050,
        sl: 4060,
        tps: [4080],
      );
      final r = validator.validate(s, quote);
      expect(r.valid, isFalse);
      expect(r.reasons.any((x) => x.contains('SL above')), isTrue);
    });

    test('rejects missing SL', () {
      final s = ParsedSignal(
        symbol: 'XAUUSD',
        side: Side.buy,
        entryLow: 4050,
      );
      final r = validator.validate(s, quote);
      expect(r.valid, isFalse);
    });

    test('rejects low R:R', () {
      final s = ParsedSignal(
        symbol: 'XAUUSD',
        side: Side.buy,
        entryLow: 4050,
        sl: 4030,
        tps: [4051], // 1 point reward vs 20 point risk, RR=0.05 < 0.5
      );
      final r = validator.validate(s, quote);
      expect(r.valid, isFalse);
      expect(r.reasons.any((x) => x.contains('R:R below minimum')), isTrue);
    });

    test('rejects SELL market with no quote', () {
      final s = ParsedSignal(
        symbol: 'XAUUSD',
        side: Side.sell,
        entryIsMarket: true,
        sl: 4060,
        tps: [4040],
      );
      final r = validator.validate(s, null);
      expect(r.valid, isFalse);
      expect(r.reasons.any((x) => x.contains('market entry requires a live quote')), isTrue);
    });

    test('rejects BUY with TP below entry', () {
      final s = ParsedSignal(
        symbol: 'XAUUSD',
        side: Side.buy,
        entryLow: 4050,
        sl: 4030,
        tps: [4040], // TP below entry for buy
      );
      final r = validator.validate(s, quote);
      expect(r.valid, isFalse);
      expect(r.reasons.any((x) => x.contains('TP on wrong side')), isTrue);
    });

    test('rejects SELL with TP above entry', () {
      final s = ParsedSignal(
        symbol: 'XAUUSD',
        side: Side.sell,
        entryLow: 4050,
        sl: 4070,
        tps: [4060], // TP above entry for sell
      );
      final r = validator.validate(s, quote);
      expect(r.valid, isFalse);
      expect(r.reasons.any((x) => x.contains('TP on wrong side')), isTrue);
    });

    test('rejects when market closed', () {
      final s = ParsedSignal(
        symbol: 'XAUUSD',
        side: Side.buy,
        entryLow: 4050,
        sl: 4030,
        tps: [4080],
      );
      final r = validator.validate(s, quote, marketOpen: false);
      expect(r.valid, isFalse);
    });
  });
}
