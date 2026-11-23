library;

import 'dart:convert';
import 'dart:io';

enum TelegramProxyMode { disabled, proxyRequired, proxyPreferred }

enum TelegramProxyType { socks5, socks4, http, mtproto }

class TelegramProxyConfig {
  TelegramProxyConfig({
    this.enabled = false,
    this.mode = TelegramProxyMode.disabled,
    this.type = TelegramProxyType.socks5,
    this.host = '',
    this.port = 10808,
    this.username = '',
    this.password = '',
    this.secret = '',
    this.rdns = true,
    this.connectTimeoutSeconds = 10,
    this.maxRetries = 3,
    this.retryDelaySeconds = 5,
    this.reconnectOnFailure = true,
    this.directFallback = false,
  }) {
    _normalize();
  }

  bool enabled;
  TelegramProxyMode mode;
  TelegramProxyType type;
  String host;
  int port;
  String username;
  String password;
  String secret;
  bool rdns;
  int connectTimeoutSeconds;
  int maxRetries;
  int retryDelaySeconds;
  bool reconnectOnFailure;
  bool directFallback;

  void _normalize() {
    if (!enabled) mode = TelegramProxyMode.disabled;
    if (mode == TelegramProxyMode.disabled) {
      enabled = false;
    } else {
      enabled = true;
    }
    if (mode != TelegramProxyMode.proxyPreferred) directFallback = false;
    if (mode == TelegramProxyMode.proxyRequired) directFallback = false;
  }

  List<String> validate() {
    final errors = <String>[];
    if (mode == TelegramProxyMode.disabled) return errors;
    if (host.trim().isEmpty) errors.add('host must not be empty');
    if (port < 1 || port > 65535) errors.add('port must be 1..65535');
    if (type == TelegramProxyType.socks4) {
      errors.add('unsupported proxy type for TDLib: socks4');
    }
    if (type == TelegramProxyType.mtproto &&
        secret.trim().isEmpty &&
        password.trim().isEmpty) {
      errors.add('mtproto proxy requires a secret');
    }
    if (connectTimeoutSeconds < 1) {
      errors.add('connect_timeout_seconds must be >= 1');
    }
    if (maxRetries < 0) errors.add('max_retries must be >= 0');
    if (retryDelaySeconds < 0) errors.add('retry_delay_seconds must be >= 0');
    if (directFallback && mode != TelegramProxyMode.proxyPreferred) {
      errors.add('direct_fallback only allowed in proxy_preferred mode');
    }
    if (mode == TelegramProxyMode.proxyRequired && directFallback) {
      errors.add('direct_fallback not allowed in proxy_required mode');
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  Map<String, dynamic> toJson({bool includeSecrets = false}) => {
        'enabled': enabled,
        'mode': _modeName(mode),
        'type': type.name,
        'host': host,
        'port': port,
        'username': username,
        'password': includeSecrets
            ? password
            : (password.isEmpty ? '' : '***'),
        'secret': includeSecrets ? secret : (secret.isEmpty ? '' : '***'),
        'rdns': rdns,
        'connect_timeout_seconds': connectTimeoutSeconds,
        'max_retries': maxRetries,
        'retry_delay_seconds': retryDelaySeconds,
        'reconnect_on_failure': reconnectOnFailure,
        'direct_fallback': directFallback,
      };

  static String _modeName(TelegramProxyMode m) {
    switch (m) {
      case TelegramProxyMode.disabled:
        return 'disabled';
      case TelegramProxyMode.proxyRequired:
        return 'proxy_required';
      case TelegramProxyMode.proxyPreferred:
        return 'proxy_preferred';
    }
  }

  static TelegramProxyMode _parseMode(String? v) {
    switch (v) {
      case 'proxy_required':
      case 'required':
        return TelegramProxyMode.proxyRequired;
      case 'proxy_preferred':
      case 'preferred':
        return TelegramProxyMode.proxyPreferred;
      default:
        return TelegramProxyMode.disabled;
    }
  }

  static TelegramProxyType _parseType(String? v) {
    switch (v) {
      case 'socks4':
        return TelegramProxyType.socks4;
      case 'http':
      case 'http_connect':
        return TelegramProxyType.http;
      case 'mtproto':
        return TelegramProxyType.mtproto;
      default:
        return TelegramProxyType.socks5;
    }
  }

  factory TelegramProxyConfig.fromJson(Map<String, dynamic> map) {
    return TelegramProxyConfig(
      enabled: map['enabled'] == true,
      mode: _parseMode(map['mode'] as String?),
      type: _parseType(map['type'] as String?),
      host: map['host'] as String? ?? '',
      port: (map['port'] as num?)?.toInt() ?? 10808,
      username: map['username'] as String? ?? '',
      password: map['password'] as String? ?? '',
      secret: map['secret'] as String? ?? '',
      rdns: map['rdns'] != false,
      connectTimeoutSeconds:
          (map['connect_timeout_seconds'] as num?)?.toInt() ?? 10,
      maxRetries: (map['max_retries'] as num?)?.toInt() ?? 3,
      retryDelaySeconds: (map['retry_delay_seconds'] as num?)?.toInt() ?? 5,
      reconnectOnFailure: map['reconnect_on_failure'] != false,
      directFallback: map['direct_fallback'] == true,
    );
  }

  static TelegramProxyConfig load({String? path}) {
    final p = path ?? 'telegram_proxy.json';
    final f = File(p);
    if (!f.existsSync()) return TelegramProxyConfig();
    try {
      final map = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return TelegramProxyConfig.fromJson(map);
    } catch (_) {
      return TelegramProxyConfig();
    }
  }

  Future<void> save({String? path}) async {
    final p = path ?? 'telegram_proxy.json';
    final f = File(p);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(toJson(includeSecrets: true)),
    );
  }
}

Map<String, dynamic>? toTdlibProxy(TelegramProxyConfig cfg) {
  if (!cfg.enabled || cfg.mode == TelegramProxyMode.disabled) return null;
  Map<String, dynamic> typeObj;
  String typeStr;
  switch (cfg.type) {
    case TelegramProxyType.socks5:
      typeStr = 'socks5';
      typeObj = {
        '@type': 'proxyTypeSocks5',
        'username': cfg.username,
        'password': cfg.password,
      };
      break;
    case TelegramProxyType.http:
      typeStr = 'http';
      typeObj = {
        '@type': 'proxyTypeHttp',
        'username': cfg.username,
        'password': cfg.password,
        'http_only': false,
      };
      break;
    case TelegramProxyType.mtproto:
      typeStr = 'mtproto';
      typeObj = {
        '@type': 'proxyTypeMtproto',
        'secret': cfg.secret.isNotEmpty ? cfg.secret : cfg.password,
      };
      break;
    case TelegramProxyType.socks4:
      return null;
  }
  return {
    'enabled': true,
    'mode': cfg.mode.name,
    'type': typeStr,
    'host': cfg.host,
    'server': cfg.host,
    'port': cfg.port,
    'username': cfg.username,
    'password': cfg.password,
    'rdns': cfg.rdns,
    'connect_timeout_seconds': cfg.connectTimeoutSeconds,
    'type_obj': typeObj,
  };
}