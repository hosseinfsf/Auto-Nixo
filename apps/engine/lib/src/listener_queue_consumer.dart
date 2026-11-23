/// Durable consumer for the Python/Telethon Listener SQLite queue.
library;

import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'db.dart';
import 'pipeline.dart';
import 'telegram/telegram_source.dart';

class ListenerQueueStore {
  ListenerQueueStore(this.path);

  final String path;
  sqlite3.Database? _queueDb;

  bool get isOpen => _queueDb != null;

  void _openIfReady() {
    if (_queueDb != null || !File(path).existsSync()) return;
    final candidate = sqlite3.sqlite3.open(path);
    candidate.execute('PRAGMA busy_timeout=5000;');
    final tables = candidate.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='listener_queue'",
    );
    if (tables.isEmpty) {
      candidate.dispose();
      return;
    }

    final columns = candidate
        .select('PRAGMA table_info(listener_queue)')
        .map((row) => row['name'] as String)
        .toSet();
    const required = {
      'id', 'chat_id', 'message_id', 'edit_version', 'date_utc', 'text',
      'caption', 'media_path', 'media_hash', 'update_type', 'state', 'error',
      'validity_seconds', 'lease_owner', 'lease_until_utc', 'attempts',
      'next_attempt_utc', 'processed_at',
    };
    if (!columns.containsAll(required)) {
      candidate.dispose();
      return; // Listener applies additive schema migrations on its next start.
    }
    _queueDb = candidate;
  }

  Map<String, dynamic>? claimNext({
    required String owner,
    int leaseSeconds = 90,
  }) {
    _openIfReady();
    final q = _queueDb;
    if (q == null) return null;

    final now = DateTime.now().toUtc();
    final nowIso = now.toIso8601String();
    final leaseUntil = now.add(Duration(seconds: leaseSeconds)).toIso8601String();

    q.execute('BEGIN IMMEDIATE');
    try {
      q.execute(
        "UPDATE listener_queue SET state='pending', lease_owner=NULL, "
        "lease_until_utc=NULL, error=COALESCE(error, 'processing lease expired') "
        "WHERE state='processing' AND "
        "(lease_until_utc IS NULL OR lease_until_utc <= ?)",
        [nowIso],
      );

      final rows = q.select(
        "SELECT * FROM listener_queue WHERE state='pending' AND "
        "(next_attempt_utc IS NULL OR next_attempt_utc <= ?) "
        "ORDER BY id ASC LIMIT 1",
        [nowIso],
      );
      if (rows.isEmpty) {
        q.execute('COMMIT');
        return null;
      }

      final selected = Map<String, dynamic>.from(rows.first);
      final id = selected['id'] as int;
      q.execute(
        "UPDATE listener_queue SET state='processing', lease_owner=?, "
        "lease_until_utc=?, attempts=attempts+1 "
        "WHERE id=? AND state='pending'",
        [owner, leaseUntil, id],
      );
      final claimedRows = q.select(
        "SELECT * FROM listener_queue WHERE id=? AND state='processing' AND lease_owner=?",
        [id, owner],
      );
      q.execute('COMMIT');
      if (claimedRows.isEmpty) return null;
      return Map<String, dynamic>.from(claimedRows.first);
    } catch (_) {
      try {
        q.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  void renewLease(int id, String owner, {int leaseSeconds = 90}) {
    _openIfReady();
    final q = _queueDb;
    if (q == null) return;
    final until = DateTime.now()
        .toUtc()
        .add(Duration(seconds: leaseSeconds))
        .toIso8601String();
    q.execute(
      "UPDATE listener_queue SET lease_until_utc=? "
      "WHERE id=? AND state='processing' AND lease_owner=?",
      [until, id, owner],
    );
  }

  /// A queued item is trusted only while its Listener allowlist entry exists
  /// and remains enabled. Missing tables/columns fail closed.
  bool isSourceEnabled(int chatId) {
    _openIfReady();
    final q = _queueDb;
    if (q == null) return false;
    try {
      final table = q.select(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sources' LIMIT 1",
      );
      if (table.isEmpty) return false;
      final columns = q.select('PRAGMA table_info(sources)')
          .map((row) => row['name'] as String).toSet();
      if (!columns.containsAll({'chat_id', 'enabled'})) return false;
      final rows = q.select(
        'SELECT enabled FROM sources WHERE chat_id=? LIMIT 1', [chatId],
      );
      return rows.isNotEmpty && rows.first['enabled'] == 1;
    } catch (_) {
      return false;
    }
  }

  /// Older versions still pending/processing must finish before an edit.
  bool hasEarlierUnresolvedVersion(int chatId, int messageId, int editVersion) {
    _openIfReady();
    final q = _queueDb;
    if (q == null) return true;
    final rows = q.select(
      "SELECT 1 FROM listener_queue WHERE chat_id=? AND message_id=? "
      "AND edit_version < ? AND state IN ('pending','processing') LIMIT 1",
      [chatId, messageId, editVersion],
    );
    return rows.isNotEmpty;
  }

  /// Mark a blocked queue item terminally, without sending it to the pipeline.
  void markSkipped(int id, String owner, String reason) {
    _openIfReady();
    final q = _queueDb;
    if (q == null) return;
    q.execute(
      "UPDATE listener_queue SET state='failed', processed_at=?, error=?, "
      "lease_owner=NULL, lease_until_utc=NULL, next_attempt_utc=NULL "
      "WHERE id=? AND state='processing' AND lease_owner=?",
      [DateTime.now().toUtc().toIso8601String(), reason, id, owner],
    );
  }

  void markProcessed(int id, String owner) {
    _openIfReady();
    final q = _queueDb;
    if (q == null) return;
    q.execute(
      "UPDATE listener_queue SET state='processed', processed_at=?, "
      "lease_owner=NULL, lease_until_utc=NULL, next_attempt_utc=NULL, error=NULL "
      "WHERE id=? AND state='processing' AND lease_owner=?",
      [DateTime.now().toUtc().toIso8601String(), id, owner],
    );
  }

  void retryOrFail(
    int id,
    String owner,
    int attempts,
    String error, {
    int maxAttempts = 12,
  }) {
    _openIfReady();
    final q = _queueDb;
    if (q == null) return;

    final terminal = attempts >= maxAttempts;
    final exponent = attempts.clamp(1, 6).toInt();
    final backoffSeconds = (1 << exponent).clamp(2, 60).toInt();
    final nextAttempt = DateTime.now()
        .toUtc()
        .add(Duration(seconds: backoffSeconds))
        .toIso8601String();

    q.execute(
      "UPDATE listener_queue SET state=?, error=?, lease_owner=NULL, "
      "lease_until_utc=NULL, next_attempt_utc=? "
      "WHERE id=? AND state='processing' AND lease_owner=?",
      [
        terminal ? 'failed' : 'pending',
        error.length > 1000 ? error.substring(0, 1000) : error,
        terminal ? null : nextAttempt,
        id,
        owner,
      ],
    );
  }

  void close() {
    _queueDb?.dispose();
    _queueDb = null;
  }
}

class ListenerQueueConsumer {
  ListenerQueueConsumer({
    required this.path,
    required this.enabled,
    required this.allowExecution,
    required this.db,
    required this.pipeline,
    this.pollInterval = const Duration(milliseconds: 500),
  }) : _store = ListenerQueueStore(path);

  final String path;
  final bool enabled;
  final bool allowExecution;
  final Database db;
  final Pipeline pipeline;
  final Duration pollInterval;
  final ListenerQueueStore _store;

  Timer? _pollTimer;
  bool _busy = false;
  bool _stopping = false;
  final String _owner = 'nixo-$pid-${DateTime.now().microsecondsSinceEpoch}';

  Future<void> start() async {
    if (!enabled) {
      db.audit('info', 'Listener queue consumer disabled by configuration');
      return;
    }
    _stopping = false;
    db.audit(
      'info',
      'Listener queue consumer enabled; queue execution permission=${allowExecution ? "on" : "off"}',
    );
    _pollTimer = Timer.periodic(pollInterval, (_) {
      unawaited(_poll());
    });
    await _poll();
  }

  Future<void> _poll() async {
    if (_busy || _stopping) return;
    _busy = true;
    try {
      final row = _store.claimNext(owner: _owner);
      if (row != null) await _process(row);
    } catch (e) {
      db.audit('warn', 'Listener queue poll failed: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _process(Map<String, dynamic> row) async {
    final id = row['id'] as int;
    final attempts = row['attempts'] as int? ?? 1;
    final pulse = Timer.periodic(const Duration(seconds: 20), (_) {
      try {
        _store.renewLease(id, _owner);
      } catch (e) {
        db.audit('warn', 'Listener queue lease renewal failed for row $id: $e');
      }
    });

    try {
      final updateType = row['update_type'] as String? ?? 'new';
      if (updateType == 'delete') {
        _store.markProcessed(id, _owner);
        return;
      }
      if (updateType != 'new' && updateType != 'edit') {
        db.audit('warn', 'Listener queue row $id ignored: unsupported update type');
        _store.markProcessed(id, _owner);
        return;
      }

      final numericChatId = row['chat_id'] as int;
      if (!_store.isSourceEnabled(numericChatId)) {
        const reason = 'manual_review: Listener source is missing or disabled';
        _store.markSkipped(id, _owner, reason);
        db.audit('warn', 'Listener queue row $id blocked: $reason');
        return;
      }

      final chatId = numericChatId.toString();
      final inputId = 'telegram:$chatId';
      final existing = db.listInputs().where((item) => item['id'] == inputId);
      if (existing.isEmpty) {
        db.upsertInput({
          'id': inputId,
          'type': 'telegram_source',
          'name': 'Telegram $chatId',
          'enabled': true,
          'profile_id': null,
          'status': 'listener_queue',
          'last_message_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'last_error': null,
        });
      } else if (existing.first['enabled'] != 1) {
        db.audit('info', 'Listener queue row $id ignored: input $inputId disabled');
        _store.markProcessed(id, _owner);
        return;
      }

      final editVersion = row['edit_version'] as int? ?? 0;
      if (updateType == 'edit' &&
          (_store.hasEarlierUnresolvedVersion(
                numericChatId, row['message_id'] as int, editVersion,
              ) ||
              db.hasPriorExecutionForMessage(
                inputId, row['message_id'].toString(), editVersion,
              ))) {
        const reason = 'manual_review: edited Telegram message cannot create a second order after an earlier version was processed or may have reached MT5';
        _store.markSkipped(id, _owner, reason);
        db.audit('error', 'Listener queue row $id blocked: $reason');
        return;
      }

      final originalDate = row['date_utc'] as String?;
      final validity = row['validity_seconds'] as int? ?? 180;
      final message = <String, dynamic>{
        'input_id': inputId,
        'chat_id': row['chat_id'],
        'message_id': row['message_id'].toString(),
        'edit_version': row['edit_version'] as int? ?? 0,
        'text': row['text'] as String? ?? '',
        'caption': row['caption'] as String? ?? '',
        'image_path': row['media_path'] as String?,
        'media_hash': row['media_hash'] as String?,
        'update_type': updateType,
        'timestamp': originalDate,
        'validity_seconds': validity,
        'force_dry_run': !allowExecution,
      };

      db.insertRawMessage(message);
      final decision = await pipeline.process(
        RawMessageEvent(inputId: inputId, message: message),
      );

      _store.markProcessed(id, _owner);
      db.audit(
        'info',
        'Listener queue row $id completed: ${decision.action.name} (${decision.reason ?? "no reason"})',
      );
    } catch (e) {
      _store.retryOrFail(id, _owner, attempts, '$e');
      db.audit('warn', 'Listener queue row $id will be retried or parked: $e');
    } finally {
      pulse.cancel();
    }
  }

  Future<void> stop() async {
    _stopping = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _store.close();
    db.audit('info', 'Listener queue consumer stopped');
  }
}
