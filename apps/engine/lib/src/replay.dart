/// Replay tool: feed saved messages (text+images) through the full pipeline
/// with a fake executor.
library;

import 'dart:convert';
import 'dart:io';

import 'package:nixo_core/nixo_core.dart';

import 'db.dart';
import 'pipeline.dart';
import 'telegram/telegram_source.dart';

class FakeExecutor implements Executor {
  FakeExecutor({
    this.quoteForSymbol = const {},
    Map<String, double> riskPerLotForSymbol = const {},
    this.defaultRiskPerLot = 1000.0,
    this.symbolsList = const [],
  }) : riskPerLotForSymbol = riskPerLotForSymbol;

  final Map<String, Quote> quoteForSymbol;

  /// Symbols reported by the (fake) broker. When non-empty, the pipeline
  /// rejects any signal whose symbol is not listed.
  final List<String> symbolsList;

  /// Authoritative risk-per-lot per symbol; falls back to [defaultRiskPerLot]
  /// (a test-only value — never used for live trading).
  Map<String, double> riskPerLotForSymbol;
  final double defaultRiskPerLot;
  final List<OrderPlan> opened = [];
  final List<String> closed = [];
  bool failOpen = false;
  String failOpenError = 'fake failure';
  bool loseAckAfterAccept = false;
  bool riskPerLotUnavailable = false;
  final Map<String, String> _acceptedOrders = {};

  @override
  Future<ExecutionAck> open(OrderPlan order) async {
    final cid = order.clientOrderId;
    if (cid != null && _acceptedOrders.containsKey(cid)) {
      return ExecutionAck(ok: true, orderId: _acceptedOrders[cid]);
    }
    if (failOpen) {
      if (loseAckAfterAccept) {
        opened.add(order);
        if (cid != null) {
          _acceptedOrders[cid] = 'fake_' + opened.length.toString();
        }
      }
      return ExecutionAck(ok: false, error: failOpenError);
    }
    opened.add(order);
    final ticket = 'fake_' + opened.length.toString();
    if (cid != null) _acceptedOrders[cid] = ticket;
    return ExecutionAck(ok: true, orderId: ticket);
  }

  @override
  Future<void> modify(String orderId, {double? sl, List<double>? tps}) async {}

  @override
  Future<void> close(String orderId, {double? lots}) async {
    closed.add(orderId);
  }

  @override
  Future<void> closeAll() async {}

  @override
  Future<void> cancel(String orderId) async {}

  @override
  Future<Quote?> quote(String symbol) async =>
      quoteForSymbol[symbol] ?? Quote(symbol: symbol, bid: 1.0, ask: 1.0001);

  @override
  Future<AccountInfo> account() async => AccountInfo(
        balance: 10000,
        equity: 10000,
        tradeMode: TradeMode.demo,
        marginMode: MarginMode.hedging,
      );

  @override
  Future<List<String>> symbols() async => symbolsList;

  @override
  Future<List<double>> rates(String symbol, int count) async => [];

  @override
  Future<double?> riskPerLot(String symbol, Side side, double entry, double sl) async {
    if (riskPerLotUnavailable) return null;
    return riskPerLotForSymbol[symbol] ?? defaultRiskPerLot;
  }

  @override
  Future<List<int>> reconcilePositions() async => [];
}

class ReplayTool {
  ReplayTool({required this.db, required this.pipeline});

  final Database db;
  final Pipeline pipeline;

  Future<int> replayFile(String path) async {
    final f = File(path);
    if (!f.existsSync()) {
      throw StateError('file not found: $path');
    }
    final data = jsonDecode(f.readAsStringSync()) as List;
    var count = 0;
    for (final item in data) {
      final map = item as Map<String, dynamic>;
      final decision = await pipeline.process(RawMessageEvent(
        inputId: map['input_id'] as String? ?? 'replay',
        message: map,
      ));
      count++;
      print('[$count] ${decision.action} — ${decision.reason}');
    }
    return count;
  }
}
