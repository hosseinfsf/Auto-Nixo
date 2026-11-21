/// The signal pipeline: classify -> parse -> validate -> risk -> execute.
///
/// A failed validator NEVER executes. The deterministic text fast path never
/// waits for AI.
library;

import 'dart:async';
import 'dart:convert';

import 'package:nixo_core/nixo_core.dart';

import 'db.dart';
import 'telegram/telegram_source.dart';

/// Abstraction over the MT5 link so the pipeline can be tested with a fake.
abstract class Executor {
  Future<ExecutionAck> open(OrderPlan order);
  Future<void> modify(String orderId, {double? sl, List<double>? tps});
  Future<void> close(String orderId, {double? lots});
  Future<void> closeAll();
  Future<void> cancel(String orderId);
  Future<Quote?> quote(String symbol);
  Future<AccountInfo> account();
  Future<List<String>> symbols();
  Future<List<double>> rates(String symbol, int count);

  /// Authoritative monetary risk per 1.0 lot at the given entry/SL, computed
  /// by the EA via OrderCalcProfit. Returns null when unavailable (in which
  /// case the trade must be rejected — never use an approximate lot size).
  Future<double?> riskPerLot(String symbol, Side side, double entry, double sl);
}

class ExecutionAck {
  ExecutionAck({required this.ok, this.orderId, this.error, this.retcode});
  final bool ok;
  final String? orderId;
  final String? error;
  final int? retcode;
}

class PipelineConfig {
  PipelineConfig({
    this.validitySeconds = 180,
    this.requireSl = true,
  });

  final int validitySeconds;
  final bool requireSl;
}

class Pipeline {
  Pipeline({
    required this.db,
    required this.executor,
    required this.classifier,
    required this.parser,
    required this.validator,
    required this.sizer,
    required this.slTp,
    required this.limits,
    required this.perInputLimits,
    required this.roulette,
    PipelineConfig? config,
  }) : config = config ?? PipelineConfig();

  final Database db;
  final Executor executor;
  final Classifier classifier;
  final TextParser parser;
  final SignalValidator validator;
  final Sizer sizer;
  final SlTpResolver slTp;
  final LimitsManager limits;
  final PerInputLimitsManager perInputLimits;
  final RouletteManager roulette;
  final PipelineConfig config;

  /// Process a raw message event. Returns the decision.
  Future<Decision> process(RawMessageEvent event) async {
    final inputId = event.inputId;
    final msg = event.message;

    // 1. Classify.
    final text = (msg['text'] as String? ?? '') +
        ' ' +
        (msg['caption'] as String? ?? '');
    final classification = classifier.classify(text);

    if (classification.kind == SignalKind.noise) {
      return _decision('', DecisionAction.skip, 'noise');
    }

    if (classification.kind == SignalKind.recap) {
      return _decision('', DecisionAction.skip, 'recap');
    }

    if (classification.kind == SignalKind.management) {
      // Management update -> handled by position manager (not in this pipeline).
      return _decision('', DecisionAction.skip, 'management_update');
    }

    // 2. Parse.
    final profile = _loadProfile(inputId);
    final parseResult = parser.parse(text, aliases: profile?.symbolAliases);
    if (parseResult.signal == null) {
      return _decision('', DecisionAction.skip, 'parse_failed: ${parseResult.error}');
    }
    final signal = parseResult.signal!;
    final signalId = 'sig_${DateTime.now().microsecondsSinceEpoch}';
    db.insertSignal({
      'id': signalId,
      'input_id': inputId,
      'message_id': msg['message_id'],
      'json': jsonEncode(signal.toJson()),
    });

    // 2b. Signal expiry check (per-source configurable, default 180s).
    final validitySeconds = profile?.validitySeconds ?? config.validitySeconds;
    final msgTimestamp = msg['timestamp'] as String?;
    if (msgTimestamp != null) {
      try {
        final msgTime = DateTime.parse(msgTimestamp);
        final age = DateTime.now().toUtc().difference(msgTime.toUtc()).inSeconds;
        if (age > validitySeconds) {
          db.insertDecision({
            'signal_id': signalId,
            'action': 'skip',
            'reason': 'signal expired (${age}s > ${validitySeconds}s)',
          });
          return _decision(signalId, DecisionAction.skip,
              'signal expired (${age}s > ${validitySeconds}s)');
        }
      } catch (_) {
        // Invalid timestamp — reject rather than silently treat as fresh.
        db.insertDecision({
          'signal_id': signalId,
          'action': 'skip',
          'reason': 'invalid timestamp',
        });
        return _decision(signalId, DecisionAction.skip, 'invalid timestamp');
      }
    }

    // 3. Validate.
    final quote = await executor.quote(signal.symbol);
    final validation = validator.validate(signal, quote);
    if (!validation.valid) {
      db.insertDecision({
        'signal_id': signalId,
        'action': 'skip',
        'reason': validation.reasons.join('; '),
        'validation': jsonEncode(validation.toJson()),
      });
      return _decision(signalId, DecisionAction.skip, validation.reasons.join('; '));
    }

    // 4. Risk / sizing.
    final account = await executor.account();
    // Build a per-source SlTpResolver from the profile's TP/SL policy.
    final slTpConfig = SlTpConfig(
      slPolicy: profile?.slPolicy ?? SlPolicy.signal,
      tpPolicy: profile?.tpPolicy ?? TpPolicy.signal,
      defaultTpRr: profile?.tpRr ?? 3.0,
    );
    final sourceSlTp = SlTpResolver(config: slTpConfig, tpRr: profile?.tpRr);
    final slTpResult = sourceSlTp.resolve(signal, quote, tpRr: profile?.tpRr);
    if (slTpResult.rejectReason != null) {
      return _decision(signalId, DecisionAction.skip, slTpResult.rejectReason!);
    }

    // Build an effective signal with resolved SL/TP.
    final effectiveSignal = ParsedSignal(
      symbol: signal.symbol,
      side: signal.side,
      entryLow: signal.entryLow,
      entryHigh: signal.entryHigh,
      entryIsMarket: signal.entryIsMarket,
      sl: slTpResult.sl,
      tps: slTpResult.tps,
      rrLabel: signal.rrLabel,
      rawText: signal.rawText,
    );

    // Authoritative risk per lot from MT5 (OrderCalcProfit). Never use an
    // approximate formula; if MT5 cannot compute it, reject the trade.
    final entry = effectiveSignal.entryIsMarket
        ? quote?.mid()
        : ((effectiveSignal.entryLow ?? 0) +
                (effectiveSignal.entryHigh ?? effectiveSignal.entryLow ?? 0)) /
            2;
    if (entry == null || effectiveSignal.sl == null) {
      return _decision(signalId, DecisionAction.block, 'missing entry or SL for risk calc');
    }
    final riskPerLot = await executor.riskPerLot(
        signal.symbol, signal.side!, entry, effectiveSignal.sl!);
    if (riskPerLot == null || riskPerLot <= 0) {
      return _decision(signalId, DecisionAction.block, 'risk_per_lot_unavailable');
    }
    final sizing = sizer.size(
      signal: effectiveSignal,
      account: account,
      riskPerLot: riskPerLot,
      entryPrice: entry,
      slPrice: effectiveSignal.sl,
    );
    if (sizing.lots <= 0) {
      return _decision(signalId, DecisionAction.block, 'sizing rejected: ${sizing.reason}');
    }

    // 5. Mode / limits.
    final mode = profile?.mode ?? ProfileMode.auto;
    if (mode == ProfileMode.off) {
      return _decision(signalId, DecisionAction.skip, 'mode=off');
    }

    final globalCheck = limits.check();
    if (globalCheck.blocked) {
      return _decision(signalId, DecisionAction.block, globalCheck.reasons.join('; '));
    }

    if (!perInputLimits.canOpen(inputId, equity: account.equity)) {
      return _decision(signalId, DecisionAction.block, 'per-input limits');
    }

    // Roulette volume multiplier.
    final volMult = roulette.volumeMultiplier(inputId);
    final finalLots = sizing.lots * volMult;

    final order = OrderPlan(
      symbol: signal.symbol,
      side: signal.side!,
      type: signal.entryIsMarket ? OrderType.market : OrderType.limit,
      lots: finalLots,
      entry: signal.entryIsMarket ? null : effectiveSignal.entryLow,
      sl: effectiveSignal.sl,
      tps: effectiveSignal.tps,
      magic: _magicFor(inputId),
      comment: 'NX|$inputId',
      clientOrderId: signalId,
    );

    // 6. Execute or shadow.
    if (mode == ProfileMode.shadow) {
      db.insertDecision({
        'signal_id': signalId,
        'action': 'shadow',
        'reason': 'shadow mode',
        'sizing': jsonEncode(sizing.toJson()),
        'order_json': jsonEncode(order.toJson()),
      });
      return _decision(signalId, DecisionAction.shadow, 'shadow mode');
    }

    final ack = await executor.open(order);
    perInputLimits.onOpen(inputId);
    db.insertOrder({
      'id': order.clientOrderId ?? signalId,
      'signal_id': signalId,
      'client_order_id': order.clientOrderId,
      'symbol': order.symbol,
      'side': order.side.name,
      'type': order.type.name,
      'lots': order.lots,
      'entry': order.entry,
      'sl': order.sl,
      'tps': order.tps,
      'magic': order.magic,
      'comment': order.comment,
      'status': ack.ok ? 'sent' : 'rejected: ${ack.error}',
    });
    db.insertJournal({
      'id': 'intent_${DateTime.now().microsecondsSinceEpoch}',
      'intent': jsonEncode(order.toJson()),
      'order_id': ack.orderId,
      'status': ack.ok ? 'acked' : 'failed',
    });

    if (!ack.ok) {
      return _decision(signalId, DecisionAction.block, 'execute failed: ${ack.error}');
    }

    return _decision(signalId, DecisionAction.execute, 'executed');
  }

  int _magicFor(String inputId) {
    return inputId.hashCode & 0x7FFFFFFF;
  }

  SourceProfile? _loadProfile(String inputId) {
    final row = db.listInputs().where((r) => r['id'] == inputId).firstOrNull;
    if (row == null) return null;
    final profileId = row['profile_id'] as String?;
    if (profileId == null) return null;
    final json = db.getProfile(profileId);
    if (json == null) return null;
    return _profileFromJson(json);
  }

  SourceProfile _profileFromJson(Map<String, dynamic> json) {
    return SourceProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      mode: ProfileMode.values.firstWhere(
        (m) => m.name == json['mode'],
        orElse: () => ProfileMode.shadow,
      ),
      allowedSymbols: (json['allowed_symbols'] as List? ?? []).cast<String>(),
      symbolAliases: (json['symbol_aliases'] as Map? ?? {}).map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      ),
      validitySeconds: json['validity_seconds'] as int? ?? config.validitySeconds,
      slPolicy: SlPolicy.values.firstWhere(
        (m) => m.name == json['sl_policy'],
        orElse: () => SlPolicy.signal,
      ),
      tpPolicy: TpPolicy.values.firstWhere(
        (m) => m.name == json['tp_policy'],
        orElse: () => TpPolicy.signal,
      ),
      tpRr: (json['tp_rr'] as num? ?? 3.0).toDouble(),
      riskPercent: (json['risk_percent'] as num? ?? 1.0).toDouble(),
      riskMultiplier: (json['risk_multiplier'] as num? ?? 1.0).toDouble(),
      minLot: (json['min_lot'] as num? ?? 0.01).toDouble(),
      maxLot: (json['max_lot'] as num? ?? 10.0).toDouble(),
      rouletteEnabled: json['roulette_enabled'] as bool? ?? false,
    );
  }

  Decision _decision(String signalId, DecisionAction action, String reason) {
    return Decision(
      signalId: signalId,
      action: action,
      reason: reason,
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
