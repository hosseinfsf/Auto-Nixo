/// Telegram source adapter implementing the InputAdapter interface.
///
/// Uses TdLibClient. Includes a state machine and watchdog (no update/ping for
/// N seconds -> force reconnect). Never exits on network errors.
library;

import 'dart:async';
import 'dart:convert';

import '../db.dart';
import 'tdlib_client.dart';

abstract class InputAdapter {
  String get id;
  Future<void> start();
  Future<void> stop();
  Map<String, dynamic> health();
  Stream<RawMessageEvent> get messages;
}

class RawMessageEvent {
  RawMessageEvent({required this.inputId, required this.message});
  final String inputId;
  final Map<String, dynamic> message;
}

class TelegramSource implements InputAdapter {
  TelegramSource({
    required this.inputId,
    required this.target,
    required this.client,
    required this.db,
    this.watchdogSeconds = 30,
  });

  final String inputId;
  final String target; // @username, t.me link, numeric id, or invite link
  final TdLibClient client;
  final Database db;
  final int watchdogSeconds;

  final _controller = StreamController<RawMessageEvent>.broadcast();
  Timer? _watchdog;
  bool _running = false;
  String _status = 'stopped';
  int _lastMessageAt = 0;
  int _messagesToday = 0;
  String? _lastError;

  @override
  String get id => inputId;

  @override
  Stream<RawMessageEvent> get messages => _controller.stream;

  @override
  Future<void> start() async {
    _running = true;
    _status = 'connecting';
    await client.start();
    _resolveTarget();
    _startWatchdog();
    // Subscribe to updates.
    client.updates.listen(_onUpdate);
  }

  @override
  Future<void> stop() async {
    _running = false;
    _watchdog?.cancel();
    _status = 'stopped';
  }

  void _resolveTarget() {
    final t = target.trim();
    if (t.startsWith('@')) {
      client.searchPublicChat(t.substring(1));
    } else if (t.startsWith('t.me/') || t.startsWith('https://t.me/')) {
      client.joinChatByInviteLink(t);
    } else if (int.tryParse(t) != null) {
      client.searchPublicChat(t);
    } else {
      client.joinChatByInviteLink(t);
    }
  }

  void _onUpdate(TdUpdate update) {
    final type = update.raw['@type'] as String?;
    if (type == 'updateNewMessage') {
      final message = update.raw['message'] as Map<String, dynamic>?;
      if (message != null) {
        _handleMessage(message);
      }
    } else if (type == 'updateMessageContent') {
      final messageId = update.raw['message_id'];
      final content = update.raw['new_content'] as Map<String, dynamic>?;
      if (messageId != null && content != null) {
        _handleEdit(messageId.toString(), content);
      }
    }
  }

  void _handleMessage(Map<String, dynamic> message) {
    final messageId = message['id']?.toString() ?? '';
    final content = message['content'] as Map<String, dynamic>?;
    final text = _extractText(content);
    final caption = _extractCaption(content);
    final photo = _extractPhoto(content);

    _lastMessageAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _messagesToday++;
    _status = 'online';

    final raw = {
      'input_id': inputId,
      'message_id': messageId,
      'text': text,
      'caption': caption,
      'image_path': photo,
      'edit_version': 0,
      'is_forwarded': message['is_forwarded'] == true,
      'is_reply': message['reply_to_message_id'] != null,
      'reply_to_message_id': message['reply_to_message_id']?.toString(),
      'is_album': message['media_album_id'] != null,
      'timestamp': DateTime.now().toIso8601String(),
    };

    // Dedupe check (insert OR IGNORE).
    db.insertRawMessage(raw);
    _controller.add(RawMessageEvent(inputId: inputId, message: raw));
  }

  void _handleEdit(String messageId, Map<String, dynamic> content) {
    final text = _extractText(content);
    final raw = {
      'input_id': inputId,
      'message_id': messageId,
      'text': text,
      'caption': _extractCaption(content),
      'image_path': _extractPhoto(content),
      'edit_version': 1,
      'timestamp': DateTime.now().toIso8601String(),
    };
    db.insertRawMessage(raw);
    _controller.add(RawMessageEvent(inputId: inputId, message: raw));
  }

  String _extractText(Map<String, dynamic>? content) {
    if (content == null) return '';
    final text = content['text'] as Map<String, dynamic>?;
    if (text != null) return text['text'] as String? ?? '';
    return '';
  }

  String _extractCaption(Map<String, dynamic>? content) {
    if (content == null) return '';
    final caption = content['caption'] as Map<String, dynamic>?;
    if (caption != null) return caption['text'] as String? ?? '';
    return '';
  }

  String? _extractPhoto(Map<String, dynamic>? content) {
    if (content == null) return null;
    if (content['@type'] != 'messagePhoto') return null;
    final photo = content['photo'] as Map<String, dynamic>?;
    if (photo == null) return null;
    final sizes = photo['sizes'] as List?;
    if (sizes == null || sizes.isEmpty) return null;
    final last = sizes.last as Map<String, dynamic>;
    final photoPath = last['photo'] as Map<String, dynamic>?;
    if (photoPath == null) return null;
    final local = photoPath['local'] as Map<String, dynamic>?;
    if (local == null) return null;
    final path = local['path'] as String?;
    if (path != null && path.isNotEmpty) return path;
    // Trigger download.
    final fileId = photoPath['id'] as int?;
    if (fileId != null) client.downloadFile(fileId);
    return null;
  }

  void _startWatchdog() {
    _watchdog = Timer.periodic(Duration(seconds: watchdogSeconds), (_) {
      if (!_running) return;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (now - _lastMessageAt > watchdogSeconds) {
        // No activity -> force reconnect (never exit).
        _status = 'reconnecting';
        client.send({'@type': 'getAuthorizationState'});
      }
    });
  }

  @override
  Map<String, dynamic> health() => {
        'id': inputId,
        'status': _status,
        'last_message_at': _lastMessageAt,
        'messages_today': _messagesToday,
        'last_error': _lastError,
        'telegram_state': client.state.name,
      };
}
