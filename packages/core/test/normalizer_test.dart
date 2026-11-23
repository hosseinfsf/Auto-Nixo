import 'package:nixo_core/nixo_core.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeDigits', () {
    test('converts Persian digits', () {
      expect(normalizeDigits('۱۲۳'), '123');
      expect(normalizeDigits('۰'), '0');
    });

    test('converts Arabic-Indic digits', () {
      expect(normalizeDigits('٥'), '5');
      expect(normalizeDigits('٩'), '9');
    });

    test('converts full-width digits', () {
      expect(normalizeDigits('１'), '1');
    });
  });

  group('normalizeText', () {
    test('normalizes separators and whitespace', () {
      expect(normalizeText('  خرید  ۱٫۵  '), 'خرید 1.5');
    });
  });

  group('parseNumber', () {
    test('handles thousands separators', () {
      expect(parseNumber('1,234.5'), 1234.5);
      expect(parseNumber('1 234'), 1234);
    });

    test('rejects non-numbers', () {
      expect(parseNumber('abc'), isNull);
    });
  });
}
