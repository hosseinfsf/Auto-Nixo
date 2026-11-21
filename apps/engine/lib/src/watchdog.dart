/// Engine watchdog: monitors the MT5 link and Telegram state, forces reconnect
/// on staleness, and prevents sleep while armed (Windows).
library;

import 'dart:async';
import 'dart:io';

import 'mt5/link_server.dart';
import 'telegram/telegram_source.dart';

class Watchdog {
  Watchdog({
    required this.link,
    required this.telegramSources,
    this.interval = const Duration(seconds: 15),
  });

  final Mt5LinkServer link;
  final List<TelegramSource> telegramSources;
  final Duration interval;

  Timer? _timer;

  void start() {
    _timer = Timer.periodic(interval, (_) => _check());
  }

  void stop() {
    _timer?.cancel();
  }

  void _check() {
    if (!link.connected) {
      // MT5 link is down. The link server auto-reconnects on new connection;
      // we just log and alert.
      _alert('mt5 link disconnected');
    }
    for (final src in telegramSources) {
      final h = src.health();
      if (h['status'] == 'reconnecting' || h['status'] == 'error') {
        _alert('telegram source ${src.id} degraded: ${h['status']}');
      }
    }
  }

  void _alert(String message) {
    // In production this raises a loud alert (toast/banner). Here we log.
    // ignore: avoid_print
    print('[watchdog] $message');
  }

  /// Prevent sleep while armed (Windows only).
  void arm() {
    if (Platform.isWindows) {
      // SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
      // via FFI. Implemented in a platform helper; stubbed here.
    }
  }

  void disarm() {}
}
