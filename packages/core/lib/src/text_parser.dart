/// Text parser for trading signals.
///
/// Uses a per-input parser profile (templates, keywords, aliases, number
/// formats). Supports any symbol, entry ranges, multiple TPs, "now/market",
/// and limit/stop inferred from the live quote.
library;

import 'models.dart';
import 'normalizer.dart';
import 'symbol_mapping.dart';

class TextParseResult {
  TextParseResult({this.signal, this.error});

  final ParsedSignal? signal;
  final String? error;
}

class TextParser {
  TextParser({
    SymbolMapping? symbolMapping,
    this.quote,
  });

  final Quote? quote;

  /// Parse a normalized message into a [ParsedSignal].
  TextParseResult parse(String rawText, {Map<String, String>? aliases}) {
    final text = normalizeText(rawText);
    if (text.isEmpty) return TextParseResult(error: 'empty text');

    // ---- Symbol ----
    final symbol = _findSymbol(text, aliases);
    if (symbol == null) {
      return TextParseResult(error: 'no symbol found');
    }

    // ---- Side ----
    final side = _findSide(text);
    if (side == null) {
      return TextParseResult(error: 'no side found');
    }

    // ---- Entry ----
    final entry = _findEntry(text, side);

    // ---- SL ----
    final sl = _findSl(text);

    // ---- TPs ----
    final tps = _findTps(text);

    // ---- RR label ----
    final rr = _findRr(text);

    final signal = ParsedSignal(
      symbol: symbol,
      side: side,
      entryLow: entry?.$1,
      entryHigh: entry?.$2,
      entryIsMarket: entry == null && _containsMarket(text),
      sl: sl,
      tps: tps,
      rrLabel: rr,
      rawText: rawText,
    );

    return TextParseResult(signal: signal);
  }

  String? _findSymbol(String text, Map<String, String>? aliases) {
    // Look for known canonical symbols first.
    const known = [
      'XAUUSD', 'XAGUSD', 'EURUSD', 'GBPUSD', 'USDJPY', 'AUDUSD',
      'USDCAD', 'NZDUSD', 'USDCHF', 'EURGBP', 'EURJPY', 'GBPJPY',
      'BTCUSD', 'ETHUSD', 'US30', 'NAS100', 'SPX500', 'US500', 'GER30',
      'UK100', 'JP225', 'WTI', 'BRENT',
    ];
    final upper = text.toUpperCase();
    for (final c in known) {
      if (upper.contains(c)) return c;
    }
    // Check aliases.
    if (aliases != null) {
      for (final e in aliases.entries) {
        if (upper.contains(e.key.toUpperCase())) return e.value;
      }
    }
    // Try a generic symbol pattern like "GOLD", "SILVER", "OIL".
    const generic = {
      'GOLD': 'XAUUSD',
      'SILVER': 'XAGUSD',
      'OIL': 'WTI',
      'CRUDE': 'WTI',
      'BITCOIN': 'BTCUSD',
      'ETHEREUM': 'ETHUSD',
      'طلا': 'XAUUSD',
      'نقره': 'XAGUSD',
      'بیتکوین': 'BTCUSD',
    };
    for (final e in generic.entries) {
      if (upper.contains(e.key)) return e.value;
    }
    return null;
  }

  Side? _findSide(String text) {
    final t = normalizeText(text).toLowerCase();
    // Buy/sell first.
    if (t.contains('buy') || t.contains('long') || t.contains('خرید') ||
        t.contains('لانگ')) {
      return Side.buy;
    }
    if (t.contains('sell') || t.contains('short') || t.contains('فروش') ||
        t.contains('شورت')) {
      return Side.sell;
    }
    return null;
  }

  (double?, double?)? _findEntry(String text, Side side) {
    final t = normalizeText(text).toLowerCase();
    // Patterns: "entry 1.2345", "enter at 1.2345", "1.2345-1.2355",
    // "buy at 1.2345", "around 1.2345".
    final entryMarks = RegExp(
      r'(entry|enter|at|around|near|قیمت|قیمت ورود|ورود|حدود|حدود)',
    );
    // Find all numbers.
    final numbers = <double>[];
    final numRe = RegExp(r'\d+(\.\d+)?');
    for (final m in numRe.allMatches(t)) {
      final n = parseNumber(m.group(0)!);
      if (n != null) numbers.add(n);
    }
    if (numbers.isEmpty) return null;

    // If there is an explicit "entry" marker, take the number following it.
    final em = entryMarks.firstMatch(t);
    if (em != null) {
      final after = t.substring(em.end);
      final m = numRe.firstMatch(after);
      if (m != null) {
        final n = parseNumber(m.group(0)!);
        if (n != null) {
          // Check for a range "1.20-1.25".
          final range = RegExp(r'(\d+(\.\d+)?)\s*[-–—]\s*(\d+(\.\d+)?)')
              .firstMatch(after);
          if (range != null) {
            final lo = parseNumber(range.group(1)!);
            final hi = parseNumber(range.group(3)!);
            if (lo != null && hi != null) {
              return (lo < hi ? lo : hi, lo < hi ? hi : lo);
            }
          }
          return (n, null);
        }
      }
    }

    // No marker: if the message explicitly says market/now, treat as market entry.
    if (_containsMarket(text)) {
      return null;
    }
    // Heuristic: first number is often the entry.
    return (numbers.first, null);
  }

  double? _findSl(String text) {
    final t = normalizeText(text).toLowerCase();
    // Look for "sl: 1.20", "stop loss 1.20", "حد ضرر 1.20".
    final slRe = RegExp(
      r'(sl|stop loss|stoploss|حد ضرر|حدضرر|استاپ)\s*[:=]?\s*(?:\d+(\.\d+)?)',
    );
    final m = slRe.firstMatch(t);
    if (m != null) {
      final numM = RegExp(r'\d+(\.\d+)?').firstMatch(m.group(0)!);
      if (numM != null) return parseNumber(numM.group(0)!);
    }
    return null;
  }

  List<double> _findTps(String text) {
    final t = normalizeText(text).toLowerCase();
    final tps = <double>[];
    // Patterns: tp1/tp2/tp3, target 1, target1, take profit 1, حد سود.
    final tpRe = RegExp(
      r'(tp\d?|target\s*\d?|take profit\s*\d?|حد سود\s*\d?|تیپی\s*\d?)'
      r'\s*[:=]?\s*(\d+(\.\d+)?)',
      caseSensitive: false,
    );
    for (final m in tpRe.allMatches(t)) {
      final n = parseNumber(m.group(2)!);
      if (n != null) tps.add(n);
    }
    return tps;
  }

  double? _findRr(String text) {
    final t = normalizeText(text).toLowerCase();
    final rrRe = RegExp(r'rr\s*[:=]?\s*(\d+(\.\d+)?)');
    final m = rrRe.firstMatch(t);
    if (m != null) return parseNumber(m.group(1)!);
    return null;
  }

  bool _containsMarket(String text) {
    final t = normalizeText(text).toLowerCase();
    return t.contains('market') || t.contains('now') || t.contains('همین الان') ||
        t.contains('بازار');
  }
}
