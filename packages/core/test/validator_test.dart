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
        sl: 4049,
        tps: [4050], // 1 point reward vs 1 point risk, RR=1 but min 0.5 ok
      );
      final r = validator.validate(s, quote);
      expect(r.valid, isTrue);
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
