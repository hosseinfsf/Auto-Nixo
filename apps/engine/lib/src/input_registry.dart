/// Input registry: every input is declared once and starts by itself.
library;

import 'dart:async';

import 'db.dart';
import 'telegram/telegram_source.dart';

class InputRegistry {
  InputRegistry({required this.db});

  final Database db;
  final Map<String, InputAdapter> _adapters = {};
  final _healthController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get healthUpdates => _healthController.stream;
  Map<String, InputAdapter> get adapters => Map.unmodifiable(_adapters);

  /// Register an adapter for an input id.
  void register(InputAdapter adapter) {
    _adapters[adapter.id] = adapter;
  }

  /// Start every enabled input in order.
  Future<void> startAll() async {
    for (final row in db.listInputs()) {
      final id = row['id'] as String;
      final enabled = row['enabled'] == 1;
      if (!enabled) continue;
      final adapter = _adapters[id];
      if (adapter == null) continue;
      try {
        await adapter.start();
        db.upsertInput({'id': id, 'status': 'starting'});
      } catch (e) {
        db.upsertInput({'id': id, 'status': 'error', 'last_error': '$e'});
      }
    }
  }

  Future<void> stopAll() async {
    for (final adapter in _adapters.values) {
      await adapter.stop();
    }
  }

  Map<String, dynamic> allHealth() {
    final out = <String, dynamic>{};
    for (final e in _adapters.entries) {
      out[e.key] = e.value.health();
    }
    return out;
  }
}
