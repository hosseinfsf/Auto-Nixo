import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

import '../lib/src/listener_queue_consumer.dart';

void main() {
  late Directory tempDir;
  late String dbPath;
  late ListenerQueueStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('nixo_queue_test_');
    dbPath = '${tempDir.path}${Platform.pathSeparator}queue.db';
    final seedDb = sqlite3.sqlite3.open(dbPath);
    seedDb.execute('''
      CREATE TABLE listener_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chat_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        edit_version INTEGER NOT NULL DEFAULT 0,
        date_utc TEXT NOT NULL,
        sender_id INTEGER,
        text TEXT,
        caption TEXT,
        media_path TEXT,
        media_hash TEXT,
        content_hash TEXT,
        update_type TEXT NOT NULL,
        ingested_at TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending',
        error TEXT,
        validity_seconds INTEGER NOT NULL DEFAULT 180,
        lease_owner TEXT,
        lease_until_utc TEXT,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_utc TEXT,
        processed_at TEXT,
        UNIQUE(chat_id, message_id, edit_version)
      )
    ''');
    seedDb.execute('''
      INSERT INTO listener_queue
      (chat_id, message_id, date_utc, update_type, ingested_at, state)
      VALUES (123, 456, '2026-11-23T10:00:00.000Z', 'new',
              '2026-11-23T10:00:01.000Z', 'pending')
    ''');
    seedDb.dispose();
    store = ListenerQueueStore(dbPath);
  });

  tearDown(() {
    store.close();
    tempDir.deleteSync(recursive: true);
  });

  test('claims a pending row with a lease and increments attempts', () {
    final row = store.claimNext(owner: 'worker-a');
    expect(row, isNotNull);
    expect(row!['state'], 'processing');
    expect(row['lease_owner'], 'worker-a');
    expect(row['attempts'], 1);
  });

  test('processed acknowledgement is tied to the active lease owner', () {
    final row = store.claimNext(owner: 'worker-a')!;
    store.markProcessed(row['id'] as int, 'worker-b');

    final verify = sqlite3.sqlite3.open(dbPath);
    expect(verify.select('SELECT state FROM listener_queue').first['state'],
        'processing');
    verify.dispose();

    store.markProcessed(row['id'] as int, 'worker-a');
    final verifyDone = sqlite3.sqlite3.open(dbPath);
    expect(verifyDone.select('SELECT state FROM listener_queue').first['state'],
        'processed');
    verifyDone.dispose();
  });

  test('expired lease is recoverable by the next worker', () {
    final first = store.claimNext(owner: 'worker-a', leaseSeconds: -1)!;
    final second = store.claimNext(owner: 'worker-b');
    expect(second, isNotNull);
    expect(second!['id'], first['id']);
    expect(second['lease_owner'], 'worker-b');
    expect(second['attempts'], 2);
  });

  test('retry limit parks the row as failed', () {
    final row = store.claimNext(owner: 'worker-a')!;
    store.retryOrFail(
      row['id'] as int,
      'worker-a',
      row['attempts'] as int,
      'test failure',
      maxAttempts: 1,
    );

    final verify = sqlite3.sqlite3.open(dbPath);
    expect(verify.select('SELECT state FROM listener_queue').first['state'],
        'failed');
    verify.dispose();
  });
}
