/// MT5 link protocol: one message per line (LF), KEY=VALUE pairs separated by '|'.
///
/// Not JSON (avoids a JSON library in MQL5). Values are percent-encoded so
/// they can never contain the separators: '%' -> %25, '|' -> %7C, '=' -> %3D,
/// CR -> %0D, LF -> %0A. The EA implements the same encoding (Enc/Dec).
/// First message is AUTH with a random token; heartbeat both ways.
library;

class Mt5Message {
  Mt5Message(this.fields);
  final Map<String, String> fields;

  String? operator [](String key) => fields[key];

  /// Escape a value for the wire.
  static String escape(String v) {
    final b = StringBuffer();
    for (final c in v.runes) {
      if (c == 0x25) {
        b.write('%25');
      } else if (c == 0x7C) {
        b.write('%7C');
      } else if (c == 0x3D) {
        b.write('%3D');
      } else if (c == 0x0D) {
        b.write('%0D');
      } else if (c == 0x0A) {
        b.write('%0A');
      } else if (c == 0x00) {
        // NUL never goes on the wire.
      } else {
        b.writeCharCode(c);
      }
    }
    return b.toString();
  }

  static final RegExp _hex2 = RegExp(r'^[0-9A-Fa-f]{2}$');

  /// Reverse of [escape]. A '%' that is not followed by two hex digits is kept.
  static String unescape(String v) {
    if (!v.contains('%')) return v;
    final b = StringBuffer();
    var i = 0;
    while (i < v.length) {
      final c = v.codeUnitAt(i);
      if (c == 0x25 && i + 2 < v.length && _hex2.hasMatch(v.substring(i + 1, i + 3))) {
        b.writeCharCode(int.parse(v.substring(i + 1, i + 3), radix: 16));
        i += 3;
        continue;
      }
      b.writeCharCode(c);
      i++;
    }
    return b.toString();
  }

  /// Encode to wire format: `CMD=OPEN|SYMBOL=XAUUSD|...` (without the LF).
  String encode() {
    return fields.entries.map((e) => '${e.key}=${escape(e.value)}').join('|');
  }

  /// Decode one line. NUL bytes and CR are ignored. Returns null for blank lines.
  static Mt5Message? decode(String line) {
    final trimmed = line.replaceAll('\u0000', '').replaceAll('\r', '').trim();
    if (trimmed.isEmpty) return null;
    final fields = <String, String>{};
    for (final part in trimmed.split('|')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      fields[part.substring(0, idx)] = unescape(part.substring(idx + 1));
    }
    return Mt5Message(fields);
  }
}

/// Wire commands (engine -> EA).
class Cmd {
  static const auth = 'AUTH';
  static const heartbeat = 'HB';
  static const open = 'OPEN';
  static const modify = 'MODIFY';
  static const close = 'CLOSE';
  static const closeAll = 'CLOSE_ALL';
  static const cancel = 'CANCEL';
  static const getSymbols = 'GET_SYMBOLS';
  static const getSymbolInfo = 'GET_SYMBOL_INFO';
  static const getAccount = 'GET_ACCOUNT';
  static const getPositions = 'GET_POSITIONS';
  static const getRates = 'GET_RATES';
  static const getBars = 'GET_BARS';
  static const getCalendar = 'GET_CALENDAR';
  static const getRiskPerLot = 'GET_RISK_PER_LOT';
}

/// Wire events (EA -> engine).
class Evt {
  static const ack = 'ACK';
  static const fill = 'FILL';
  static const reject = 'REJECT';
  static const orderRemoved = 'ORDER_REMOVED';
  static const positionClosed = 'POSITION_CLOSED';
  static const account = 'ACCOUNT';
  static const marginMode = 'MARGIN_MODE';
  static const tradeMode = 'TRADE_MODE';
  static const serverTime = 'SERVER_TIME';
  static const symbols = 'SYMBOLS';
  static const symbolInfo = 'SYMBOL_INFO';
  static const positions = 'POSITIONS';
  static const rates = 'RATES';
  static const bars = 'BARS';
  static const calendar = 'CALENDAR';
}
