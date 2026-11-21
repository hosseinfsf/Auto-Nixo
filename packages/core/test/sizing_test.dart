import 'package:nixo_core/nixo_core.dart';
import 'package:test/test.dart';

void main() {
  final account = AccountInfo(balance: 10000, equity: 10000);

  group('sizing', () {
    test('risk percent sizing', () {
      final sizer = Sizer(
        config: SizingConfig(
          mode: SizeMode.riskPercent,
          riskPercent: 1.0,
          minLot: 0.01,
          maxLot: 10.0,
          lotStep: 0.01,
        ),
      );
      final signal = ParsedSignal(
        symbol: 'XAUUSD',
        side: Side.buy,
        entryLow: 4050,
        sl: 4030,
      );
      // risk = 1% of 10000 = 100; risk per lot = 20*100000 = 2,000,000
      final r = sizer.size(
        signal: signal,
        account: account,
        riskPerLot: 2000000,
      );
      expect(r.lots, 0.01); // 100/2e6 = 0.00005 -> clamped to min
    });

    test('fixed lot sizing', () {
      final sizer = Sizer(
        config: SizingConfig(
          mode: SizeMode.fixedLot,
          fixedLot: 0.2,
        ),
      );
      final signal = ParsedSignal(
        symbol: 'EURUSD',
        side: Side.buy,
        entryLow: 1.2,
        sl: 1.19,
      );
      final r = sizer.size(signal: signal, account: account, riskPerLot: 1000);
      expect(r.lots, 0.2);
    });

    test('clamps to max lot', () {
      final sizer = Sizer(
        config: SizingConfig(
          mode: SizeMode.riskPercent,
          riskPercent: 100.0,
          minLot: 0.01,
          maxLot: 1.0,
          lotStep: 0.01,
        ),
      );
      final signal = ParsedSignal(
        symbol: 'EURUSD',
        side: Side.buy,
        entryLow: 1.2,
        sl: 1.19,
      );
      final r = sizer.size(signal: signal, account: account, riskPerLot: 100);
      expect(r.lots, 1.0);
    });
  });
}
