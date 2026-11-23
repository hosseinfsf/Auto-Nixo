/// Proxy manager: MTProto, SOCKS5, HTTP, local proxy, direct.
///
/// Ordered priority, latency test, automatic failover and recovery.
library;

import 'dart:io';

enum ProxyType { mtproto, socks5, http, local, direct }

class ProxyEntry {
  ProxyEntry({
    required this.id,
    required this.type,
    this.server,
    this.port,
    this.secret,
    this.username,
    this.password,
    this.enabled = true,
    this.priority = 0,
    this.latencyMs,
    this.status = 'unknown',
  });

  final String id;
  final ProxyType type;
  final String? server;
  final int? port;
  final String? secret;
  final String? username;
  final String? password;
  bool enabled;
  final int priority;
  int? latencyMs;
  String status;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'server': server,
        'port': port,
        'enabled': enabled,
        'priority': priority,
        'latency_ms': latencyMs,
        'status': status,
      };
}

class ProxyManager {
  ProxyManager();

  final List<ProxyEntry> _proxies = [];
  ProxyEntry? _active;

  List<ProxyEntry> get proxies => List.unmodifiable(_proxies);
  ProxyEntry? get active => _active;

  ProxyEntry add(ProxyEntry proxy) {
    _proxies.add(proxy);
    _sort();
    return proxy;
  }

  void remove(String id) {
    _proxies.removeWhere((p) => p.id == id);
    if (_active?.id == id) _active = null;
  }

  void setEnabled(String id, bool enabled) {
    for (final p in _proxies) {
      if (p.id == id) {
        p.enabled = enabled;
        p.status = enabled ? 'unknown' : 'disabled';
      }
    }
  }

  void _sort() {
    _proxies.sort((a, b) {
      if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
      return a.priority.compareTo(b.priority);
    });
  }

  /// Test latency of a proxy by opening a TCP connection to its server:port.
  /// Direct proxies report 0.
  Future<int?> testLatency(ProxyEntry proxy) async {
    if (proxy.type == ProxyType.direct) {
      proxy.latencyMs = 0;
      proxy.status = 'ok';
      return 0;
    }
    if (proxy.server == null || proxy.port == null) {
      proxy.status = 'invalid';
      return null;
    }
    try {
      final sw = Stopwatch()..start();
      final socket = await Socket.connect(proxy.server!, proxy.port!,
          timeout: const Duration(seconds: 5));
      await socket.close();
      sw.stop();
      proxy.latencyMs = sw.elapsedMilliseconds;
      proxy.status = 'ok';
      return proxy.latencyMs;
    } catch (_) {
      proxy.status = 'fail';
      return null;
    }
  }

  /// Select the active proxy: the first enabled proxy that passes latency test.
  Future<ProxyEntry?> selectActive() async {
    _sort();
    for (final p in _proxies) {
      if (!p.enabled) continue;
      final lat = await testLatency(p);
      if (lat != null) {
        _active = p;
        return p;
      }
    }
    _active = null;
    return null;
  }

  /// Failover: mark current active as failed and pick next.
  Future<ProxyEntry?> failover() async {
    if (_active != null) {
      _active!.status = 'fail';
    }
    return selectActive();
  }
}
