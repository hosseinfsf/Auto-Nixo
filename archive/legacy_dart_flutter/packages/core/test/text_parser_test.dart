import 'package:nixo_core/nixo_core.dart';
import 'package:test/test.dart';

void main() {
  final parser = TextParser();

  group('text parser', () {
    test('parses full English signal', () {
      final r = parser.parse('BUY XAUUSD entry 4050 sl 4030 tp1 4080 tp2 4110');
      final s = r.signal!;
      expect(s.symbol, 'XAUUSD');
      expect(s.side, Side.buy);
      expect(s.entryLow, 4050);
      expect(s.sl, 4030);
      expect(s.tps, [4080, 4110]);
    });

    test('parses Persian signal', () {
      final r = parser.parse('خرید طلا در 4050 حد ضرر 4030 حد سود 4080');
      final s = r.signal!;
      expect(s.symbol, 'XAUUSD');
      expect(s.side, Side.buy);
    });

    test('parses sell', () {
      final r = parser.parse('SELL EURUSD entry 1.2000 sl 1.2050 tp1 1.1900');
      final s = r.signal!;
      expect(s.side, Side.sell);
      expect(s.symbol, 'EURUSD');
    });

    test('parses market entry', () {
      final r = parser.parse('BUY BTCUSD market sl 95000 tp1 100000');
      final s = r.signal!;
      expect(s.entryIsMarket, isTrue);
    });

    test('rejects missing symbol', () {
      final r = parser.parse('BUY entry 4050 sl 4030');
      expect(r.signal, isNull);
    });
  });
}
