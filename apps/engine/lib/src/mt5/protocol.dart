/// MT5 link protocol: one message per line, KEY=VALUE pairs separated by '|'.
///
/// Not JSON (avoids a JSON library in MQL5). First message is AUTH with a
/// random token. Heartbeat every 2 seconds both ways.
library;

class Mt5Message {
  Mt5Message(this.fields);
  final Map<String, String> fields;

  String? operator [](String key) => fields[key];

  /// Encode to wire format: `CMD=OPEN|SYMBOL=XAUUSD|...`
  String encode() {
    return fields.entries.map((e) => '${e.key}=${e.value}').join('|');
  }

  static Mt5Message? decode(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    final fields = <String, String>{};
    for (final part in trimmed.split('|')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      fields[part.substring(0, idx)] = part.substring(idx + 1);
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
  static const getCalendar = 'GET_CALENDAR';
  static const getRiskPerLot = 'GET_RISK_PER_LOT';
}

/// Wire events (EA -> engine).
class Evt {
  static const ack = 'ACK';
  static const fill = 'FILL';
  static const reject = 'REJECT';
  static const positionClosed = 'POSITION_CLOSED';
  static const account = 'ACCOUNT';
  static const marginMode = 'MARGIN_MODE';
  static const tradeMode = 'TRADE_MODE';
  static const serverTime = 'SERVER_TIME';
  static const symbols = 'SYMBOLS';
  static const symbolInfo = 'SYMBOL_INFO';
  static const positions = 'POSITIONS';
  static const rates = 'RATES';
  static const calendar = 'CALENDAR';
}
