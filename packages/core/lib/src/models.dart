/// Core domain models for NIXO LITE.
library;

import 'dart:convert';

/// Side of a trade.
enum Side { buy, sell }

/// Order type.
enum OrderType { market, limit, stop }

/// Signal classification.
enum SignalKind { signal, management, recap, noise }

/// Management action types.
enum ManagementAction { moveSl, breakEven, close, cancel, none }

/// Input (source) types.
enum InputType { telegramSource, tradingviewWebhook }

/// Per-input trading mode.
enum ProfileMode { off, shadow, confirm, auto }

/// Trade mode reported by MT5.
enum TradeMode { demo, real, contest }

/// Margin mode reported by MT5.
enum MarginMode { hedging, netting, unknown }

/// A raw message received from an input.
class RawSignalMessage {
  RawSignalMessage({
    required this.inputId,
    required this.messageId,
    required this.text,
    this.caption,
    this.imagePath,
    this.editVersion = 0,
    this.isForwarded = false,
    this.isReply = false,
    this.replyToMessageId,
    this.isAlbum = false,
    this.isDeleted = false,
    this.timestamp,
    this.raw,
  });

  final String inputId;
  final String messageId;
  final String text;
  final String? caption;
  final String? imagePath;
  final int editVersion;
  final bool isForwarded;
  final bool isReply;
  final String? replyToMessageId;
  final bool isAlbum;
  final bool isDeleted;
  final DateTime? timestamp;
  final Map<String, dynamic>? raw;

  /// Dedupe key: (input_id, message_id, edit_version).
  String dedupeKey() => '$inputId:$messageId:$editVersion';

  Map<String, dynamic> toJson() => {
        'input_id': inputId,
        'message_id': messageId,
        'text': text,
        'caption': caption,
        'image_path': imagePath,
        'edit_version': editVersion,
        'is_forwarded': isForwarded,
        'is_reply': isReply,
        'reply_to_message_id': replyToMessageId,
        'is_album': isAlbum,
        'is_deleted': isDeleted,
        'timestamp': timestamp?.toIso8601String(),
      };
}

/// A parsed trading signal.
class ParsedSignal {
  ParsedSignal({
    required this.symbol,
    this.side,
    this.entryLow,
    this.entryHigh,
    this.entryIsMarket = false,
    this.sl,
    this.tps = const [],
    this.rrLabel,
    this.timeframe,
    this.rawText,
    this.confidence = 1.0,
  });

  final String symbol;
  final Side? side;
  final double? entryLow;
  final double? entryHigh;
  final bool entryIsMarket;
  final double? sl;
  final List<double> tps;
  final double? rrLabel;
  final String? timeframe;
  final String? rawText;
  final double confidence;

  bool get hasEntry => entryLow != null || entryHigh != null || entryIsMarket;

  bool get hasSl => sl != null;

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'side': side?.name,
        'entry_low': entryLow,
        'entry_high': entryHigh,
        'entry_is_market': entryIsMarket,
        'sl': sl,
        'tps': tps,
        'rr_label': rrLabel,
        'timeframe': timeframe,
        'confidence': confidence,
      };
}

/// A management update (move SL, BE, close, ...).
class ManagementUpdate {
  ManagementUpdate({
    required this.action,
    this.targetMessageId,
    this.sl,
    this.symbol,
    this.rawText,
  });

  final ManagementAction action;
  final String? targetMessageId;
  final double? sl;
  final String? symbol;
  final String? rawText;

  Map<String, dynamic> toJson() => {
        'action': action.name,
        'target_message_id': targetMessageId,
        'sl': sl,
        'symbol': symbol,
      };
}

/// Validation result.
class ValidationResult {
  ValidationResult({required this.valid, this.reasons = const []});

  final bool valid;
  final List<String> reasons;

  Map<String, dynamic> toJson() => {'valid': valid, 'reasons': reasons};
}

/// A decision about a signal.
class Decision {
  Decision({
    required this.signalId,
    this.action = DecisionAction.none,
    this.reason,
    this.validation,
    this.sizing,
    this.order,
  });

  final String signalId;
  final DecisionAction action;
  final String? reason;
  final ValidationResult? validation;
  final SizingResult? sizing;
  final OrderPlan? order;

  Map<String, dynamic> toJson() => {
        'signal_id': signalId,
        'action': action.name,
        'reason': reason,
        'validation': validation?.toJson(),
        'sizing': sizing?.toJson(),
        'order': order?.toJson(),
      };
}

enum DecisionAction { none, execute, shadow, skip, block }

/// Sizing result.
class SizingResult {
  SizingResult({
    required this.lots,
    this.riskAmount,
    this.riskPercent,
    this.reason,
  });

  final double lots;
  final double? riskAmount;
  final double? riskPercent;
  final String? reason;

  Map<String, dynamic> toJson() => {
        'lots': lots,
        'risk_amount': riskAmount,
        'risk_percent': riskPercent,
        'reason': reason,
      };
}

/// An order plan sent to MT5.
class OrderPlan {
  OrderPlan({
    required this.symbol,
    required this.side,
    required this.type,
    required this.lots,
    this.entry,
    this.sl,
    this.tps = const [],
    this.magic = 0,
    this.comment = '',
    this.clientOrderId,
    this.deviation = 10,
  });

  final String symbol;
  final Side side;
  final OrderType type;
  final double lots;
  final double? entry;
  final double? sl;
  final List<double> tps;
  final int magic;
  final String comment;
  final String? clientOrderId;
  final int deviation;

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'side': side.name,
        'type': type.name,
        'lots': lots,
        'entry': entry,
        'sl': sl,
        'tps': tps,
        'magic': magic,
        'comment': comment,
        'client_order_id': clientOrderId,
        'deviation': deviation,
      };
}

/// A source (input) profile.
class SourceProfile {
  SourceProfile({
    this.id = '',
    this.name = '',
    this.type = InputType.telegramSource,
    this.enabled = false,
    this.mode = ProfileMode.shadow,
    this.allowedSymbols = const [],
    this.symbolAliases = const {},
    this.tradingHours,
    this.validitySeconds = 300,
    this.maxEntryDeviationPoints = 200,
    this.maxSpreadPoints = 100,
    this.maxSlippagePoints = 50,
    this.riskPercent = 0.5,
    this.riskMultiplier = 1.0,
    this.fixedCash,
    this.fixedLot,
    this.minLot = 0.01,
    this.maxLot = 10.0,
    this.maxTradesPerDay = 10,
    this.maxConcurrent = 5,
    this.dailyLossPercent = 5.0,
    this.consecutiveLossPause = 3,
    this.slPolicy = SlPolicy.signal,
    this.tpPolicy = TpPolicy.signal,
    this.rouletteEnabled = false,
    this.imageTimeoutSeconds = 10,
    this.imageAutoExecute = true,
  });

  final String id;
  final String name;
  final InputType type;
  final bool enabled;
  final ProfileMode mode;
  final List<String> allowedSymbols; // empty = any
  final Map<String, String> symbolAliases; // alias -> canonical
  final List<int>? tradingHours; // [openHour, closeHour] in server time
  final int validitySeconds;
  final int maxEntryDeviationPoints;
  final int maxSpreadPoints;
  final int maxSlippagePoints;
  final double riskPercent;
  final double riskMultiplier;
  final double? fixedCash;
  final double? fixedLot;
  final double minLot;
  final double maxLot;
  final int maxTradesPerDay;
  final int maxConcurrent;
  final double dailyLossPercent;
  final int consecutiveLossPause;
  final SlPolicy slPolicy;
  final TpPolicy tpPolicy;
  final bool rouletteEnabled;
  final int imageTimeoutSeconds;
  final bool imageAutoExecute;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'enabled': enabled,
        'mode': mode.name,
        'allowed_symbols': allowedSymbols,
        'symbol_aliases': symbolAliases,
        'trading_hours': tradingHours,
        'validity_seconds': validitySeconds,
        'max_entry_deviation_points': maxEntryDeviationPoints,
        'max_spread_points': maxSpreadPoints,
        'max_slippage_points': maxSlippagePoints,
        'risk_percent': riskPercent,
        'risk_multiplier': riskMultiplier,
        'fixed_cash': fixedCash,
        'fixed_lot': fixedLot,
        'min_lot': minLot,
        'max_lot': maxLot,
        'max_trades_per_day': maxTradesPerDay,
        'max_concurrent': maxConcurrent,
        'daily_loss_percent': dailyLossPercent,
        'consecutive_loss_pause': consecutiveLossPause,
        'sl_policy': slPolicy.name,
        'tp_policy': tpPolicy.name,
        'roulette_enabled': rouletteEnabled,
        'image_timeout_seconds': imageTimeoutSeconds,
        'image_auto_execute': imageAutoExecute,
      };
}

enum SlPolicy { signal, atrDefault, fixedPoints, reject }

enum TpPolicy { signal, defaultRR, splitLadder }

/// A live quote from MT5.
class Quote {
  Quote({
    required this.symbol,
    required this.bid,
    required this.ask,
    this.spreadPoints = 0,
    this.point = 0.0,
    this.digits = 0,
    this.marketOpen = true,
    this.tickSize = 0.0,
    this.stopsLevel = 0,
    this.time,
  });

  final String symbol;
  final double bid;
  final double ask;
  final int spreadPoints;
  final double point;
  final int digits;
  final bool marketOpen;
  final double tickSize;
  final int stopsLevel;
  final DateTime? time;

  double mid() => (bid + ask) / 2;

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'bid': bid,
        'ask': ask,
        'spread_points': spreadPoints,
        'point': point,
        'digits': digits,
        'market_open': marketOpen,
        'tick_size': tickSize,
        'stops_level': stopsLevel,
      };
}

/// Account snapshot from MT5.
class AccountInfo {
  AccountInfo({
    this.balance = 0,
    this.equity = 0,
    this.margin = 0,
    this.freeMargin = 0,
    this.tradeMode = TradeMode.demo,
    this.marginMode = MarginMode.unknown,
    this.currency = 'USD',
    this.leverage = 0,
    this.dayStartEquity,
    this.peakEquity,
  });

  final double balance;
  final double equity;
  final double margin;
  final double freeMargin;
  final TradeMode tradeMode;
  final MarginMode marginMode;
  final String currency;
  final int leverage;
  final double? dayStartEquity;
  final double? peakEquity;

  Map<String, dynamic> toJson() => {
        'balance': balance,
        'equity': equity,
        'margin': margin,
        'free_margin': freeMargin,
        'trade_mode': tradeMode.name,
        'margin_mode': marginMode.name,
        'currency': currency,
        'leverage': leverage,
      };
}
