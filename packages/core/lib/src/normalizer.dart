/// Text normalization: Persian/Arabic-Indic digits, separators, and common
/// replacements. All parsing goes through [normalizeText] first.
library;

/// Replace Arabic-Indic (٠-٩), Persian (۰-۹) and full-width digits with ASCII.
String normalizeDigits(String input) {
  final buf = StringBuffer();
  for (final rune in input.runes) {
    final digit = _asciiDigit(rune);
    if (digit != null) {
      buf.write(digit);
    } else {
      buf.writeCharCode(rune);
    }
  }
  return buf.toString();
}

/// Map a Unicode digit rune to its ASCII equivalent, or null if not a digit.
String? _asciiDigit(int rune) {
  // Persian (۰-۹) and Arabic-Indic (٠-٩) and full-width.
  if (rune >= 0x06F0 && rune <= 0x06F9) {
    return (rune - 0x06F0).toString();
  }
  if (rune >= 0x0660 && rune <= 0x0669) {
    return (rune - 0x0660).toString();
  }
  if (rune >= 0xFF10 && rune <= 0xFF19) {
    return (rune - 0xFF10).toString();
  }
  if (rune == 0x066B) return '.'; // Arabic decimal separator ٫
  if (rune == 0x066C) return ','; // Arabic thousands separator ٬
  return null;
}

/// Normalize separators: Persian/Arabic decimal separators and thousands
/// separators to a canonical form. Also collapse spaces around decimals.
String normalizeSeparators(String input) {
  var s = input;
  // Persian decimal separator (٫) -> '.'
  s = s.replaceAll('٫', '.');
  // Arabic decimal separator (٫) already handled in normalizeDigits.
  // Persian thousands separator (٬) -> remove (we strip commas later).
  s = s.replaceAll('٬', '');
  // Common full-width comma
  s = s.replaceAll('，', ',');
  // Replace comma used as decimal (e.g. "1,5") only when between digits with
  // no thousands grouping. We keep commas for thousands and let parsers
  // decide.
  return s;
}

/// Normalize Arabic/Persian letters that are commonly confused.
String normalizeLetters(String input) {
  var s = input;
  // Arabic yeh / Persian yeh -> 'y' is not needed; but unify Arabic yeh.
  s = s.replaceAll('\u064A', '\u06CC'); // ي -> ی
  s = s.replaceAll('\u0649', '\u06CC'); // ى -> ی
  s = s.replaceAll('\u0643', '\u06A9'); // ك -> ک
  s = s.replaceAll('\u0647', 'ه'); // ه stays
  s = s.replaceAll('\u0629', 'ه'); // ة -> ه
  s = s.replaceAll('\u0623', 'ا'); // أ -> ا
  s = s.replaceAll('\u0625', 'ا'); // إ -> ا
  s = s.replaceAll('\u0622', 'ا'); // آ -> ا
  s = s.replaceAll('\u0624', 'و'); // ؤ -> و
  s = s.replaceAll('\u0626', 'ی'); // ئ -> ی
  return s;
}

/// Full normalization pipeline for any incoming text.
String normalizeText(String input) {
  var s = input;
  s = normalizeDigits(s);
  s = normalizeSeparators(s);
  s = normalizeLetters(s);
  // Collapse whitespace.
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

/// Parse a number from a token that may contain thousands separators.
/// Returns null if not a valid number.
double? parseNumber(String token) {
  var t = token.trim();
  if (t.isEmpty) return null;
  // Remove thousands separators (commas or spaces between digits).
  t = t.replaceAll(RegExp(r'[,\s]'), '');
  // Allow leading +/- .
  final m = RegExp(r'^[+-]?\d+(\.\d+)?$').firstMatch(t);
  if (m == null) return null;
  return double.tryParse(t);
}
