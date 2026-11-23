/// Canonical -> broker symbol mapping.
///
/// Signals use canonical symbols (XAUUSD, EURUSD, BTCUSD, US30, ...). Brokers
/// use suffixed/aliased symbols (XAUUSD.a, EURUSDm, etc.). The mapping is
/// auto-detected from the EA's symbol list (see engine) and stored here.
library;

class SymbolMapping {
  SymbolMapping({Map<String, String>? aliases})
      : _aliases = aliases ?? {};

  final Map<String, String> _aliases; // canonical -> broker

  /// Look up a broker symbol for a canonical symbol.
  /// Returns the canonical symbol itself if no mapping exists.
  String resolve(String canonical) => _aliases[canonical] ?? canonical;

  /// Register a mapping (canonical -> broker).
  void set(String canonical, String broker) {
    _aliases[canonical] = broker;
  }

  void setAll(Map<String, String> map) {
    _aliases.addAll(map);
  }

  Map<String, String> get all => Map.unmodifiable(_aliases);

  /// Build a mapping from a list of broker symbols + a list of canonical
  /// symbols by matching a normalized base name (strip suffixes).
  static SymbolMapping autoDetect(
    List<String> brokerSymbols, {
    List<String> canonicalSymbols = const [
      'XAUUSD', 'XAGUSD', 'EURUSD', 'GBPUSD', 'USDJPY', 'AUDUSD',
      'USDCAD', 'NZDUSD', 'USDCHF', 'EURGBP', 'EURJPY', 'GBPJPY',
      'BTCUSD', 'ETHUSD', 'US30', 'NAS100', 'SPX500', 'US500', 'GER30',
      'UK100', 'JP225', 'WTI', 'BRENT',
    ],
  }) {
    final map = <String, String>{};
    for (final broker in brokerSymbols) {
      final base = _baseName(broker);
      for (final canonical in canonicalSymbols) {
        if (_baseName(canonical) == base) {
          map[canonical] = broker;
          break;
        }
      }
    }
    return SymbolMapping(aliases: map);
  }

  /// Strip common broker suffixes/prefixes from a symbol to get a base name.
  ///
  /// Only strips clearly-delimited suffixes (`.a`, `-...`, `#...`, trailing
  /// `m`/`c` when the base is a known canonical). We never strip a bare
  /// trailing letter from an arbitrary symbol (would corrupt GBPUSD/USDCAD).
  static String _baseName(String s) {
    var upper = s.toUpperCase().trim();
    // Strip `.suffix` (e.g. XAUUSD.a)
    upper = upper.replaceAll(RegExp(r'\.\w+$'), '');
    // Strip `-...` / `#...` suffixes (e.g. US30.fut, BTCUSD#)
    upper = upper.replaceAll(RegExp(r'[#-].*$'), '');
    // Strip a single trailing 'm'/'c' ONLY if the remainder is a known
    // canonical base (e.g. EURUSDm -> EURUSD). Never touch GBPUSD/USDCAD.
    if (upper.length > 4) {
      final last = upper.substring(upper.length - 1);
      if (last == 'M' || last == 'C') {
        final base = upper.substring(0, upper.length - 1);
        const known = {
          'XAUUSD', 'XAGUSD', 'EURUSD', 'GBPUSD', 'USDJPY', 'AUDUSD',
          'USDCAD', 'NZDUSD', 'USDCHF', 'EURGBP', 'EURJPY', 'GBPJPY',
          'BTCUSD', 'ETHUSD', 'US30', 'NAS100', 'SPX500', 'US500',
          'GER30', 'UK100', 'JP225', 'WTI', 'BRENT',
        };
        if (known.contains(base)) return base;
      }
    }
    return upper;
  }

  /// Try to map an arbitrary symbol token (from a signal) to a canonical name.
  /// Returns null if no known canonical matches.
  String? canonicalize(String token) {
    final base = _baseName(token);
    // Check existing aliases first (reverse).
    for (final e in _aliases.entries) {
      if (_baseName(e.value) == base) return e.key;
    }
    // Check against a known canonical list.
    const known = [
      'XAUUSD', 'XAGUSD', 'EURUSD', 'GBPUSD', 'USDJPY', 'AUDUSD',
      'USDCAD', 'NZDUSD', 'USDCHF', 'EURGBP', 'EURJPY', 'GBPJPY',
      'BTCUSD', 'ETHUSD', 'US30', 'NAS100', 'SPX500', 'US500', 'GER30',
      'UK100', 'JP225', 'WTI', 'BRENT',
    ];
    for (final c in known) {
      if (_baseName(c) == base) return c;
    }
    return null;
  }
}
