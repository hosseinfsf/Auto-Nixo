/// SQLite (WAL) store.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart' as sqlite3_open;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

class Database {
  Database(this._db);

  final sqlite3.Database _db;

  static Database open(String path) {
    // On Windows, prefer a bundled sqlite3.dll; fall back to the OS-provided
    // winsqlite3.dll when no bundled copy is available (common in dev/CI).
    if (Platform.isWindows) {
      try {
        DynamicLibrary.open('sqlite3.dll');
      } catch (_) {
        sqlite3_open.open.overrideForAll(() => DynamicLibrary.open('winsqlite3.dll'));
      }
    }
    Directory(File(path).parent.path).createSync(recursive: true);
    final db = sqlite3.sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('PRAGMA foreign_keys=ON;');
    db.execute('PRAGMA synchronous=NORMAL;');
    final d = Database(db);
    d._migrate();
    return d;
  }

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS inputs (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        name TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 0,
        profile_id TEXT,
        status TEXT,
        last_message_at INTEGER,
        last_error TEXT
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS profiles (
        id TEXT PRIMARY KEY,
        json TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS raw_messages (
        input_id TEXT NOT NULL,
        message_id TEXT NOT NULL,
        edit_version INTEGER NOT NULL DEFAULT 0,
        json TEXT NOT NULL,
        received_at INTEGER NOT NULL,
        PRIMARY KEY (input_id, message_id, edit_version)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS signals (
        id TEXT PRIMARY KEY,
        input_id TEXT NOT NULL,
        message_id TEXT,
        json TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS decisions (
        signal_id TEXT PRIMARY KEY,
        action TEXT NOT NULL,
        reason TEXT,
        validation TEXT,
        sizing TEXT,
        order_json TEXT,
        decided_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS orders (
        id TEXT PRIMARY KEY,
        signal_id TEXT,
        client_order_id TEXT,
        symbol TEXT NOT NULL,
        side TEXT NOT NULL,
        type TEXT NOT NULL,
        lots REAL NOT NULL,
        entry REAL,
        sl REAL,
        tps TEXT,
        magic INTEGER,
        comment TEXT,
        status TEXT,
        created_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS legs (
        id TEXT PRIMARY KEY,
        order_id TEXT NOT NULL,
        tp REAL,
        lots REAL,
        status TEXT
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS journal (
        id TEXT PRIMARY KEY,
        intent TEXT NOT NULL,
        order_id TEXT,
        status TEXT,
        created_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS samples (
        id TEXT PRIMARY KEY,
        input_id TEXT,
        expected TEXT,
        json TEXT,
        created_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS outcomes (
        signal_id TEXT PRIMARY KEY,
        input_id TEXT NOT NULL,
        result TEXT,
        r_result REAL,
        time_in_trade INTEGER,
        json TEXT,
        recorded_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS stats (
        input_id TEXT NOT NULL,
        window TEXT NOT NULL,
        json TEXT NOT NULL,
        PRIMARY KEY (input_id, window)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS audit (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL,
        level TEXT NOT NULL,
        message TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS roulette_states (
        source_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        step INTEGER NOT NULL,
        max_step INTEGER NOT NULL,
        activated INTEGER NOT NULL,
        last_updated INTEGER NOT NULL
      );
    ''');
  }

  void upsertInput(Map<String, dynamic> row) {
    _db.execute(
      'INSERT OR REPLACE INTO inputs (id,type,name,enabled,profile_id,status,last_message_at,last_error) '
      'VALUES (?,?,?,?,?,?,?,?)',
      [
        row['id'], row['type'], row['name'], row['enabled'] == true ? 1 : 0,
        row['profile_id'], row['status'], row['last_message_at'],
        row['last_error'],
      ],
    );
  }

  List<Map<String, dynamic>> listInputs() {
    final rows = _db.select('SELECT * FROM inputs');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  void upsertProfile(String id, Map<String, dynamic> json) {
    _db.execute(
      'INSERT OR REPLACE INTO profiles (id, json) VALUES (?,?)',
      [id, jsonEncode(json)],
    );
  }

  Map<String, dynamic>? getProfile(String id) {
    final rows = _db.select('SELECT json FROM profiles WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['json'] as String) as Map<String, dynamic>;
  }

  void insertRawMessage(Map<String, dynamic> row) {
    _db.execute(
      'INSERT OR IGNORE INTO raw_messages (input_id,message_id,edit_version,json,received_at) '
      'VALUES (?,?,?,?,?)',
      [
        row['input_id'], row['message_id'], row['edit_version'] ?? 0,
        jsonEncode(row), DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ],
    );
  }

  bool rawMessageExists(String inputId, String messageId, int editVersion) {
    final rows = _db.select(
      'SELECT 1 FROM raw_messages WHERE input_id=? AND message_id=? AND edit_version=?',
      [inputId, messageId, editVersion],
    );
    return rows.isNotEmpty;
  }

  void insertSignal(Map<String, dynamic> row) {
    _db.execute(
      'INSERT OR REPLACE INTO signals (id,input_id,message_id,json,created_at) '
      'VALUES (?,?,?,?,?)',
      [
        row['id'], row['input_id'], row['message_id'], jsonEncode(row),
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ],
    );
  }

  void insertDecision(Map<String, dynamic> row) {
    _db.execute(
      'INSERT OR REPLACE INTO decisions (signal_id,action,reason,validation,sizing,order_json,decided_at) '
      'VALUES (?,?,?,?,?,?,?)',
      [
        row['signal_id'], row['action'], row['reason'], row['validation'],
        row['sizing'], row['order_json'],
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ],
    );
  }

  void insertOrder(Map<String, dynamic> row) {
    _db.execute(
      'INSERT OR REPLACE INTO orders (id,signal_id,client_order_id,symbol,side,type,lots,entry,sl,tps,magic,comment,status,created_at) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        row['id'], row['signal_id'], row['client_order_id'], row['symbol'],
        row['side'], row['type'], row['lots'], row['entry'], row['sl'],
        jsonEncode(row['tps'] ?? []), row['magic'], row['comment'],
        row['status'] ?? 'new', DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ],
    );
  }

  void updateOrderStatus(String id, String status) {
    _db.execute('UPDATE orders SET status=? WHERE id=?', [status, id]);
  }

  void insertJournal(Map<String, dynamic> row) {
    _db.execute(
      'INSERT OR REPLACE INTO journal (id,intent,order_id,status,created_at) '
      'VALUES (?,?,?,?,?)',
      [
        row['id'], row['intent'], row['order_id'], row['status'],
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ],
    );
  }

  void insertOutcome(Map<String, dynamic> row) {
    _db.execute(
      'INSERT OR REPLACE INTO outcomes (signal_id,input_id,result,r_result,time_in_trade,json,recorded_at) '
      'VALUES (?,?,?,?,?,?,?)',
      [
        row['signal_id'], row['input_id'], row['result'], row['r_result'],
        row['time_in_trade'], jsonEncode(row),
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ],
    );
  }

  void setSetting(String key, String value) {
    _db.execute('INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)',
        [key, value]);
  }

  String? getSetting(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key=?', [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  void upsertRouletteState(Map<String, dynamic> row) {
    _db.execute(
      'INSERT OR REPLACE INTO roulette_states (source_id,model,step,max_step,activated,last_updated) '
      'VALUES (?,?,?,?,?,?)',
      [
        row['source_id'], row['model'], row['step'], row['max_step'],
        row['activated'] == true ? 1 : 0, row['last_updated'],
      ],
    );
  }

  List<Map<String, dynamic>> listRouletteStates() {
    final rows = _db.select('SELECT * FROM roulette_states');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  void audit(String level, String message) {
    _db.execute(
      'INSERT INTO audit (ts,level,message) VALUES (?,?,?)',
      [DateTime.now().millisecondsSinceEpoch ~/ 1000, level, message],
    );
  }

  List<Map<String, dynamic>> listAudit({int limit = 50}) {
    final rows = _db.select(
      'SELECT ts, level, message FROM audit ORDER BY id DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Map<String, dynamic>? latestDecision() {
    final rows = _db.select(
      'SELECT s.json AS signal_json, d.action AS action, d.reason AS reason, '
      'd.decided_at AS decided_at FROM decisions d '
      'JOIN signals s ON s.id = d.signal_id '
      'ORDER BY d.decided_at DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final signal = jsonDecode(row['signal_json'] as String) as Map<String, dynamic>;
    final ts = row['decided_at'] as int;
    return {
      ...signal,
      'action': row['action'],
      'reason': row['reason'],
      'timestamp': DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true)
          .toIso8601String(),
    };
  }

  Map<String, dynamic>? latestOrder() {
    final rows = _db.select(
      'SELECT * FROM orders ORDER BY created_at DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  /// Insert a decision only if none exists yet, so richer rows written by
  /// earlier pipeline stages are never overwritten by a bare one.
  void insertDecisionIfAbsent(Map<String, dynamic> row) {
    _db.execute(
      'INSERT OR IGNORE INTO decisions '
      '(signal_id,action,reason,validation,sizing,order_json,decided_at) '
      'VALUES (?,?,?,?,?,?,?)',
      [
        row['signal_id'], row['action'], row['reason'],
        row['validation'] ?? '', row['sizing'] ?? '', row['order_json'] ?? '',
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ],
    );
  }

  Map<String, dynamic>? decisionFor(String signalId) {
    final rows = _db.select(
      'SELECT action, reason FROM decisions WHERE signal_id=? LIMIT 1',
      [signalId],
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  List<Map<String, dynamic>> unfinishedSignals() {
    final rows = _db.select(
      'SELECT s.* FROM signals s '
      'LEFT JOIN decisions d ON d.signal_id = s.id '
      'WHERE d.signal_id IS NULL',
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  void close() => _db.dispose();
}
