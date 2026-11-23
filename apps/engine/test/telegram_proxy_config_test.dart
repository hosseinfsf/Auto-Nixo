import 'package:nixo_engine/src/telegram/telegram_proxy_config.dart';
import 'package:test/test.dart';

void main() {
  group('TelegramProxyConfig validation', () {
    test('disabled mode has no errors', () {
      final cfg = TelegramProxyConfig();
      expect(cfg.validate(), isEmpty);
      expect(cfg.isValid, isTrue);
    });

    test('empty host rejected when enabled', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyRequired,
        host: '',
        port: 1080,
      );
      expect(cfg.validate(), contains('host must not be empty'));
    });

    test('invalid port rejected', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyRequired,
        host: '127.0.0.1',
        port: 0,
      );
      expect(cfg.validate(), contains('port must be 1..65535'));
    });

    test('socks4 unsupported for TDLib', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyRequired,
        type: TelegramProxyType.socks4,
        host: '127.0.0.1',
        port: 1080,
      );
      expect(cfg.validate(), contains('unsupported proxy type for TDLib: socks4'));
    });

    test('mtproto requires secret', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyRequired,
        type: TelegramProxyType.mtproto,
        host: '127.0.0.1',
        port: 443,
      );
      expect(cfg.validate(), contains('mtproto proxy requires a secret'));
    });

    test('direct_fallback cleared outside proxy_preferred', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyRequired,
        host: '127.0.0.1',
        port: 1080,
        directFallback: true,
      );
      expect(cfg.directFallback, isFalse);
      expect(cfg.validate(), isEmpty);
    });

    test('proxy_required disables direct_fallback', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyRequired,
        host: '127.0.0.1',
        port: 1080,
        directFallback: true,
      );
      expect(cfg.directFallback, isFalse);
    });

    test('disabled mode forces enabled false', () {
      final cfg = TelegramProxyConfig(enabled: true, mode: TelegramProxyMode.disabled);
      expect(cfg.enabled, isFalse);
    });

    test('json round trip preserves secrets', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyPreferred,
        type: TelegramProxyType.socks5,
        host: '1.2.3.4',
        port: 9050,
        username: 'u',
        password: 'p',
        directFallback: true,
      );
      final json = cfg.toJson(includeSecrets: true);
      final back = TelegramProxyConfig.fromJson(json);
      expect(back.host, '1.2.3.4');
      expect(back.port, 9050);
      expect(back.username, 'u');
      expect(back.password, 'p');
      expect(back.directFallback, isTrue);
      expect(back.mode, TelegramProxyMode.proxyPreferred);
    });

    test('sanitized json masks password', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyRequired,
        host: '1.2.3.4',
        port: 9050,
        password: 'secret',
      );
      final json = cfg.toJson(includeSecrets: false);
      expect(json['password'], '***');
    });

    test('toTdlibProxy returns null when disabled', () {
      final cfg = TelegramProxyConfig();
      expect(toTdlibProxy(cfg), isNull);
    });

    test('toTdlibProxy maps socks5', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyRequired,
        type: TelegramProxyType.socks5,
        host: '127.0.0.1',
        port: 1080,
        username: 'u',
        password: 'p',
      );
      final m = toTdlibProxy(cfg);
      expect(m, isNotNull);
      expect(m!['type'], 'socks5');
      expect(m['server'], '127.0.0.1');
      expect(m['port'], 1080);
      final typeObj = m['type_obj'] as Map<String, dynamic>;
      expect(typeObj['@type'], 'proxyTypeSocks5');
    });

    test('toTdlibProxy maps http', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyRequired,
        type: TelegramProxyType.http,
        host: '127.0.0.1',
        port: 8080,
      );
      final m = toTdlibProxy(cfg);
      expect(m!['type'], 'http');
      final typeObj = m['type_obj'] as Map<String, dynamic>;
      expect(typeObj['@type'], 'proxyTypeHttp');
    });

    test('toTdlibProxy maps mtproto', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyRequired,
        type: TelegramProxyType.mtproto,
        host: '127.0.0.1',
        port: 443,
        secret: 'abc123',
      );
      final m = toTdlibProxy(cfg);
      expect(m!['type'], 'mtproto');
      final typeObj = m['type_obj'] as Map<String, dynamic>;
      expect(typeObj['@type'], 'proxyTypeMtproto');
    });

    test('toTdlibProxy returns null for socks4', () {
      final cfg = TelegramProxyConfig(
        enabled: true,
        mode: TelegramProxyMode.proxyRequired,
        type: TelegramProxyType.socks4,
        host: '127.0.0.1',
        port: 1080,
      );
      // socks4 is invalid anyway, but toTdlibProxy returns null
      expect(toTdlibProxy(cfg), isNull);
    });

    test('load returns defaults when file missing', () {
      final cfg = TelegramProxyConfig.load(path: 'nonexistent_proxy.json');
      expect(cfg.mode, TelegramProxyMode.disabled);
      expect(cfg.enabled, isFalse);
    });
  });
}