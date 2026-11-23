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
      expect(Mt5Message.decode('\u0000'), isNull);
    });

    test('values with separators round-trip (comment NX|input)', () {
      final original = {
        'CMD': 'OPEN',
        'COMMENT': 'NX|input_1',
        'NOTE': 'a=b|c%d\r\ne',
        'PERSIAN': 'خرید طلا ۴۰۵۰',
      };
      final wire = Mt5Message(original).encode();
      expect(wire.contains('\n'), isFalse);
      expect(wire.contains('\r'), isFalse);
      // only the field separators remain as '|'
      expect('|'.allMatches(wire).length, original.length - 1);
      final back = Mt5Message.decode(wire)!;
      expect(back.fields, original);
    });

    test('escape uses the exact codes the EA implements', () {
      expect(Mt5Message.escape('%'), '%25');
      expect(Mt5Message.escape('|'), '%7C');
      expect(Mt5Message.escape('='), '%3D');
      expect(Mt5Message.escape('\r'), '%0D');
      expect(Mt5Message.escape('\n'), '%0A');
    });

    test('a lone percent sign survives, invalid escapes are kept', () {
      expect(Mt5Message.unescape('100%'), '100%');
      expect(Mt5Message.unescape('%zz'), '%zz');
      expect(Mt5Message.unescape('%7'), '%7');
    });

    test('NUL bytes and CR are stripped on decode', () {
      final msg = Mt5Message.decode('\u0000CMD=HB\r')!;
      expect(msg['CMD'], 'HB');
    });
  });
}
