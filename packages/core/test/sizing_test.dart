import 'package:nixo_core/nixo_core.dart';
import 'package:test/test.dart';

void main() {
  final account = AccountInfo(balance: 10000, equity: 10000);

  group('sizing', () {
    test('default config is risk percent 0.5%', () {
      final c = SizingConfig();
      expect(c.mode, SizeMode.riskPercent);
      expect(c.riskPercent, 0.5);
      expect(c.legacyFixedLotAllowed, isFalse);
    });

    test('risk percent sizing uses equity and risk per lot', () {
      final sizer = Sizer(
        config: SizingConfig(
          mode: SizeMode.riskPercent,
          riskPercent: 0.5,
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
      // risk = 0.5% of 10000 = 50; risk per lot = 1000 -> 0.05 lots
      final r = sizer.size(
        signal: signal,
        account: account,
        riskPerLot: 1000,
      );
      expect(r.lots, 0.05);
      expect(r.reason, 'risk_percent');
    });

    test('rejects when risk per lot is unknown', () {
      final sizer = Sizer();
      final signal = ParsedSignal(
        symbol: 'EURUSD',
        side: Side.buy,
        entryLow: 1.2,
        sl: 1.19,
      );
      final r = sizer.size(signal: signal, account: account, riskPerLot: null);
      expect(r.lots, 0);
      expect(r.reason, 'risk_per_lot_unknown');
    });

    test('fixed lot is rejected by default', () {
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
      expect(r.lots, 0);
      expect(r.reason, 'fixed_lot_disabled');
    });

    test('fixed lot works only when legacy explicitly allowed', () {
      final sizer = Sizer(
        config: SizingConfig(
          mode: SizeMode.fixedLot,
          fixedLot: 0.2,
          legacyFixedLotAllowed: true,
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
      expect(r.reason, 'fixed_lot_legacy');
    });

    test('rejects when below broker minimum (no silent bump)', () {
      final sizer = Sizer(
        config: SizingConfig(
          mode: SizeMode.riskPercent,
          riskPercent: 0.5,
          minLot: 0.01,
          maxLot: 10.0,
          lotStep: 0.01,
        ),
      );
      final signal = ParsedSignal(
        symbol: 'EURUSD',
        side: Side.buy,
        entryLow: 1.2,
        sl: 1.19,
      );
      // risk 50 / risk-per-lot 1,000,000 -> 0.00005 -> below min
      final r = sizer.size(signal: signal, account: account, riskPerLot: 1000000);
      expect(r.lots, 0);
      expect(r.reason, 'below_broker_minimum');
    });

    test('rejects when above maximum', () {
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
      // risk 10000 / risk-per-lot 100 -> 100 lots -> above max 1.0
      final r = sizer.size(signal: signal, account: account, riskPerLot: 100);
      expect(r.lots, 0);
      expect(r.reason, 'above_max_lot');
    });

    test('rounds down to volume step', () {
      final sizer = Sizer(
        config: SizingConfig(
          mode: SizeMode.riskPercent,
          riskPercent: 0.5,
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
      // risk 50 / risk-per-lot 333 -> 0.15015 -> round down to 0.15
      final r = sizer.size(signal: signal, account: account, riskPerLot: 333);
      expect(r.lots, 0.15);
    });
  });
}
