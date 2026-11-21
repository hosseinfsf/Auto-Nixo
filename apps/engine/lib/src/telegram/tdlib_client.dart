/// Thin FFI wrapper around TDLib (tdjson).
///
/// Loads tdjson.dll (Windows) or libtdjson.so (Linux) via DynamicLibrary and
/// speaks the TDLib JSON protocol. This mirrors the `ivk1800/tdlib-dart`
/// approach but keeps the FFI surface minimal and testable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _TdJsonCreate = Pointer<Void> Function();
typedef _TdJsonCreateC = Pointer<Void> Function();
typedef _TdJsonSend = Void Function(Pointer<Void>, Pointer<Utf8>);
typedef _TdJsonSendC = void Function(Pointer<Void>, Pointer<Utf8>);
typedef _TdJsonReceive = Pointer<Utf8> Function(Pointer<Void>);
typedef _TdJsonReceiveC = Pointer<Utf8> Function(Pointer<Void>);
typedef _TdJsonExecute = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _TdJsonExecuteC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _TdJsonDestroy = Void Function(Pointer<Void>);
typedef _TdJsonDestroyC = void Function(Pointer<Void>);

/// A single update received from TDLib.
class TdUpdate {
  TdUpdate(this.raw);
  final Map<String, dynamic> raw;
}

/// Telegram connection state.
enum TelegramState { connecting, online, reconnecting, proxyFailover, loginRequired, stopped }

class TelegramConfig {
  TelegramConfig({
    required this.apiId,
    required this.apiHash,
    this.sessionDir = 'data/telegram',
    this.libraryPath,
    this.proxy,
    this.watchdogSeconds = 30,
  });

  final int apiId;
  final String apiHash;
  final String sessionDir;
  final String? libraryPath;
  final Map<String, dynamic>? proxy; // {type:'mtproto'|'socks5'|'http', ...}
  final int watchdogSeconds;
}

class TdLibClient {
  TdLibClient(this.config);

  final TelegramConfig config;

  Pointer<Void>? _client;
  bool _started = false;
  bool _destroyed = false;
  final _updates = StreamController<TdUpdate>.broadcast();
  TelegramState _state = TelegramState.stopped;

  Stream<TdUpdate> get updates => _updates.stream;
  TelegramState get state => _state;

  /// Load the TDLib shared library. Returns false if not found.
  bool loadLibrary() {
    final path = config.libraryPath ?? _defaultLibraryPath();
    final lib = DynamicLibrary.open(path);
    _create = lib.lookupFunction<_TdJsonCreateC, _TdJsonCreate>('td_json_client_create');
    _send = lib.lookupFunction<_TdJsonSendC, _TdJsonSend>('td_json_client_send');
    _receive = lib.lookupFunction<_TdJsonReceiveC, _TdJsonReceive>('td_json_client_receive');
    _execute = lib.lookupFunction<_TdJsonExecuteC, _TdJsonExecute>('td_json_client_execute');
    _destroy = lib.lookupFunction<_TdJsonDestroyC, _TdJsonDestroy>('td_json_client_destroy');
    return true;
  }

  String _defaultLibraryPath() {
    if (Platform.isWindows) return 'tdjson.dll';
    if (Platform.isLinux) return 'libtdjson.so';
    return 'tdjson.dll';
  }

  late _TdJsonCreate _create;
  late _TdJsonSend _send;
  late _TdJsonReceive _receive;
  late _TdJsonExecute _execute;
  late _TdJsonDestroy _destroy;

  /// Start the client and the receive loop.
  Future<void> start() async {
    if (_started) return;
    _client = _create();
    _started = true;
    _state = TelegramState.connecting;
    _setTdlibParameters();
    _receiveLoop();
  }

  void _setTdlibParameters() {
    Directory(config.sessionDir).createSync(recursive: true);
    send({
      '@type': 'setTdlibParameters',
      'parameters': {
        'use_test_dc': false,
        'database_directory': config.sessionDir,
        'files_directory': config.sessionDir,
        'use_file_database': true,
        'use_chat_info_database': true,
        'use_message_database': true,
        'use_secret_chats': false,
        'api_id': config.apiId,
        'api_hash': config.apiHash,
        'system_language_code': 'en',
        'device_model': 'Desktop',
        'system_version': 'Windows',
        'application_version': '1.0.0',
      },
    });
  }

  void _receiveLoop() {
    Future<void> loop() async {
      while (!_destroyed && _client != null) {
        final ptr = _receive(_client!);
        if (ptr == nullptr) {
          await Future.delayed(const Duration(milliseconds: 100));
          continue;
        }
        final json = ptr.toDartString();
        malloc.free(ptr);
        if (json.isEmpty) continue;
        try {
          final obj = jsonDecode(json) as Map<String, dynamic>;
          _handleUpdate(obj);
        } catch (_) {}
      }
    }

    loop();
  }

  void _handleUpdate(Map<String, dynamic> obj) {
    final type = obj['@type'] as String?;
    if (type == 'updateAuthorizationState') {
      final auth = obj['authorization_state'] as Map<String, dynamic>?;
      final authType = auth?['@type'] as String?;
      if (authType == 'authorizationStateWaitPhoneNumber' ||
          authType == 'authorizationStateWaitCode' ||
          authType == 'authorizationStateWaitPassword') {
        _state = TelegramState.loginRequired;
      } else if (authType == 'authorizationStateReady') {
        _state = TelegramState.online;
      }
    } else if (type == 'updateConnectionState') {
      final conn = obj['state'] as Map<String, dynamic>?;
      final connType = conn?['@type'] as String?;
      if (connType == 'connectionStateReady') {
        _state = TelegramState.online;
      } else if (connType == 'connectionStateConnecting' ||
          connType == 'connectionStateUpdating') {
        _state = TelegramState.reconnecting;
      }
    }
    _updates.add(TdUpdate(obj));
  }

  /// Send a raw JSON command to TDLib.
  void send(Map<String, dynamic> command) {
    if (_client == null) {
      throw StateError('TDLib client not started');
    }
    final json = jsonEncode(command);
    final cstr = json.toNativeUtf8();
    _send(_client!, cstr);
    malloc.free(cstr);
  }

  /// Execute a synchronous request (e.g. getTextEntities).
  Map<String, dynamic>? execute(Map<String, dynamic> command) {
    if (_client == null) return null;
    final json = jsonEncode(command);
    final cstr = json.toNativeUtf8();
    final ptr = _execute(_client!, cstr);
    malloc.free(cstr);
    if (ptr == nullptr) return null;
    final result = jsonDecode(ptr.toDartString()) as Map<String, dynamic>;
    malloc.free(ptr);
    return result;
  }

  // --- High-level convenience methods ---

  void setAuthenticationPhoneNumber(String phone) {
    send({'@type': 'setAuthenticationPhoneNumber', 'phone_number': phone});
  }

  void checkAuthenticationCode(String code) {
    send({'@type': 'checkAuthenticationCode', 'code': code});
  }

  void checkAuthenticationPassword(String password) {
    send({'@type': 'checkAuthenticationPassword', 'password': password});
  }

  Future<Map<String, dynamic>?> searchPublicChat(String username) async {
    send({'@type': 'searchPublicChat', 'username': username});
    return null; // result arrives via update
  }

  void joinChatByInviteLink(String link) {
    send({'@type': 'joinChatByInviteLink', 'invite_link': link});
  }

  void getChatHistory(String chatId, {int limit = 50}) {
    send({
      '@type': 'getChatHistory',
      'chat_id': chatId,
      'limit': limit,
      'offset': 0,
      'only_local': false,
    });
  }

  void downloadFile(int fileId, {int priority = 32}) {
    send({'@type': 'downloadFile', 'file_id': fileId, 'priority': priority});
  }

  void addProxy(Map<String, dynamic> proxy) {
    send({
      '@type': 'addProxy',
      'server': proxy['server'],
      'port': proxy['port'],
      'enable': true,
      'type': proxy['type'] ?? {'@type': 'proxyTypeMtproto', 'secret': proxy['secret'] ?? ''},
    });
  }

  void enableProxy(int proxyId) {
    send({'@type': 'enableProxy', 'proxy_id': proxyId});
  }

  void pingProxy(int proxyId) {
    send({'@type': 'pingProxy', 'proxy_id': proxyId});
  }

  void removeProxy(int proxyId) {
    send({'@type': 'removeProxy', 'proxy_id': proxyId});
  }

  void close() {
    _destroyed = true;
    if (_client != null) {
      _destroy(_client!);
      _client = null;
    }
    _state = TelegramState.stopped;
  }
}
