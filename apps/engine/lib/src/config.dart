/// Engine configuration.
library;

import 'dart:convert';
import 'dart:io';

class EngineConfig {
  EngineConfig({
    this.dataDir = 'data',
    this.mt5Host = '127.0.0.1',
    this.mt5Port = 9123,
    this.apiHost = '127.0.0.1',
    this.apiPort = 9124,
    this.apiToken = '',
    this.telegramApiId = 0,
    this.telegramApiHash = '',
    this.brokerTimeOffsetHours = 0,
    this.validitySeconds = 180,
  });

  final String dataDir;
  final String mt5Host;
  final int mt5Port;
  final String apiHost;
  final int apiPort;
  final String apiToken;
  final int telegramApiId;
  final String telegramApiHash;
  final int brokerTimeOffsetHours;
  final int validitySeconds;

  String get dbPath => '$dataDir/nixo.db';

  static EngineConfig load({String? path}) {
    final cfgPath = path ?? 'engine_config.json';
    final f = File(cfgPath);
    if (!f.existsSync()) return EngineConfig();
    try {
      final map = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return EngineConfig(
        dataDir: map['data_dir'] as String? ?? 'data',
        mt5Host: map['mt5_host'] as String? ?? '127.0.0.1',
        mt5Port: map['mt5_port'] as int? ?? 9123,
        apiHost: map['api_host'] as String? ?? '127.0.0.1',
        apiPort: map['api_port'] as int? ?? 9124,
        apiToken: map['api_token'] as String? ?? '',
        telegramApiId: map['telegram_api_id'] as int? ?? 0,
        telegramApiHash: map['telegram_api_hash'] as String? ?? '',
        brokerTimeOffsetHours: map['broker_time_offset_hours'] as int? ?? 0,
        validitySeconds: map['validity_seconds'] as int? ?? 180,
      );
    } catch (_) {
      return EngineConfig();
    }
  }
}
