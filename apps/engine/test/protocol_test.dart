import 'package:nixo_engine/src/mt5/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('Mt5Message', () {
    test('encodes KEY=VALUE pairs', () {
      final msg = Mt5Message({'CMD': 'OPEN', 'SYMBOL': 'XAUUSD'});
      expect(msg.encode(), 'CMD=OPEN|SYMBOL=XAUUSD');
    });

    test('decodes a line', () {
      final msg = Mt5Message.decode('CMD=OPEN|SYMBOL=XAUUSD');
      expect(msg, isNotNull);
      expect(msg!['CMD'], 'OPEN');
      expect(msg['SYMBOL'], 'XAUUSD');
    });

    test('returns null for empty line', () {
      expect(Mt5Message.decode(''), isNull);
      expect(Mt5Message.decode('   '), isNull);
    });
  });
}
