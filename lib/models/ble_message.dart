/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';

/// BLE Message types
enum BLEMessageType {
  hello,
  helloAck,
  chat,
  chatAck,
  error,
}

extension BLEMessageTypeExtension on BLEMessageType {
  String get value {
    switch (this) {
      case BLEMessageType.hello:
        return 'hello';
      case BLEMessageType.helloAck:
        return 'hello_ack';
      case BLEMessageType.chat:
        return 'chat';
      case BLEMessageType.chatAck:
        return 'chat_ack';
      case BLEMessageType.error:
        return 'error';
    }
  }

  static BLEMessageType fromString(String value) {
    switch (value) {
      case 'hello':
        return BLEMessageType.hello;
      case 'hello_ack':
        return BLEMessageType.helloAck;
      case 'chat':
        return BLEMessageType.chat;
      case 'chat_ack':
        return BLEMessageType.chatAck;
      case 'error':
        return BLEMessageType.error;
      default:
        throw ArgumentError('Unknown BLE message type: $value');
    }
  }
}

/// Base class for BLE messages with envelope format
class BLEMessage {
  static const int protocolVersion = 1;

  final int version;
  final String id;
  final BLEMessageType type;
  final int seq;
  final int total;
  final Map<String, dynamic> payload;

  BLEMessage({
    this.version = protocolVersion,
    required this.id,
    required this.type,
    this.seq = 0,
    this.total = 1,
    required this.payload,
  });

  /// Create from JSON map
  factory BLEMessage.fromJson(Map<String, dynamic> json) {
    return BLEMessage(
      version: json['v'] as int? ?? protocolVersion,
      id: json['id'] as String,
      type: BLEMessageTypeExtension.fromString(json['type'] as String),
      seq: json['seq'] as int? ?? 0,
      total: json['total'] as int? ?? 1,
      payload: json['payload'] as Map<String, dynamic>? ?? {},
    );
  }

  /// Convert to JSON map
  Map<String, dynamic> toJson() {
    return {
      'v': version,
      'id': id,
      'type': type.value,
      'seq': seq,
      'total': total,
      'payload': payload,
    };
  }

  /// Convert to JSON string
  String toJsonString() => json.encode(toJson());

  /// Get payload size in bytes
  int get payloadSize => utf8.encode(json.encode(payload)).length;

  @override
  String toString() => 'BLEMessage(type: ${type.value}, id: $id)';
}

/// HELLO message payload
class BLEHelloPayload {
  final Map<String, dynamic> event;
  final List<String> capabilities;

  BLEHelloPayload({
    required this.event,
    this.capabilities = const ['chat'],
  });

  factory BLEHelloPayload.fromJson(Map<String, dynamic> json) {
    return BLEHelloPayload(
      event: json['event'] as Map<String, dynamic>,
      capabilities: (json['capabilities'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          ['chat'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'event': event,
      'capabilities': capabilities,
    };
  }

  /// Extract callsign from event tags
  String? get callsign {
    final tags = event['tags'] as List<dynamic>?;
    if (tags == null) return null;
    for (final tag in tags) {
      if (tag is List && tag.length >= 2 && tag[0] == 'callsign') {
        return tag[1] as String;
      }
    }
    return null;
  }

  /// Extract nickname from event tags
  String? get nickname {
    final tags = event['tags'] as List<dynamic>?;
    if (tags == null) return null;
    for (final tag in tags) {
      if (tag is List && tag.length >= 2 && tag[0] == 'nickname') {
        return tag[1] as String;
      }
    }
    return null;
  }
}

/// HELLO_ACK message payload
class BLEHelloAckPayload {
  final bool success;
  final Map<String, dynamic>? event;
  final List<String> capabilities;
  final String? message;

  BLEHelloAckPayload({
    required this.success,
    this.event,
    this.capabilities = const ['chat'],
    this.message,
  });

  factory BLEHelloAckPayload.fromJson(Map<String, dynamic> json) {
    return BLEHelloAckPayload(
      success: json['success'] as bool? ?? false,
      event: json['event'] as Map<String, dynamic>?,
      capabilities: (json['capabilities'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          ['chat'],
      message: json['message'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'success': success,
      'capabilities': capabilities,
    };
    if (event != null) result['event'] = event;
    if (message != null) result['message'] = message;
    return result;
  }
}

/// Chat message payload
class BLEChatPayload {
  final String channel;
  final String author;
  final String content;
  final int timestamp;
  final String? signature;
  final String? npub;

  BLEChatPayload({
    this.channel = 'main',
    required this.author,
    required this.content,
    required this.timestamp,
    this.signature,
    this.npub,
  });

  factory BLEChatPayload.fromJson(Map<String, dynamic> json) {
    return BLEChatPayload(
      channel: json['channel'] as String? ?? 'main',
      author: json['author'] as String,
      content: json['content'] as String,
      timestamp: json['timestamp'] as int,
      signature: json['signature'] as String?,
      npub: json['npub'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'channel': channel,
      'author': author,
      'content': content,
      'timestamp': timestamp,
    };
    if (signature != null) result['signature'] = signature;
    if (npub != null) result['npub'] = npub;
    return result;
  }
}

/// Chat acknowledgment payload
class BLEChatAckPayload {
  final bool success;
  final String? messageId;
  final String? error;

  BLEChatAckPayload({
    required this.success,
    this.messageId,
    this.error,
  });

  factory BLEChatAckPayload.fromJson(Map<String, dynamic> json) {
    return BLEChatAckPayload(
      success: json['success'] as bool? ?? false,
      messageId: json['message_id'] as String?,
      error: json['error'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{'success': success};
    if (messageId != null) result['message_id'] = messageId;
    if (error != null) result['error'] = error;
    return result;
  }
}

/// Error message payload
class BLEErrorPayload {
  final String error;
  final String? code;

  BLEErrorPayload({
    required this.error,
    this.code,
  });

  factory BLEErrorPayload.fromJson(Map<String, dynamic> json) {
    return BLEErrorPayload(
      error: json['error'] as String,
      code: json['code'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{'error': error};
    if (code != null) result['code'] = code;
    return result;
  }
}

/// Helper to generate unique message IDs
class BLEMessageId {
  static int _counter = 0;

  static String generate() {
    _counter++;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'ble-$timestamp-$_counter';
  }
}

/// Builder for common message types
class BLEMessageBuilder {
  /// Create a HELLO message
  static BLEMessage hello({
    required Map<String, dynamic> event,
    List<String> capabilities = const ['chat'],
  }) {
    return BLEMessage(
      id: BLEMessageId.generate(),
      type: BLEMessageType.hello,
      payload: BLEHelloPayload(
        event: event,
        capabilities: capabilities,
      ).toJson(),
    );
  }

  /// Create a HELLO_ACK message
  static BLEMessage helloAck({
    required String requestId,
    required bool success,
    Map<String, dynamic>? event,
    List<String> capabilities = const ['chat'],
    String? message,
  }) {
    return BLEMessage(
      id: requestId,
      type: BLEMessageType.helloAck,
      payload: BLEHelloAckPayload(
        success: success,
        event: event,
        capabilities: capabilities,
        message: message,
      ).toJson(),
    );
  }

  /// Create a CHAT message
  static BLEMessage chat({
    required String author,
    required String content,
    String channel = 'main',
    String? signature,
    String? npub,
  }) {
    return BLEMessage(
      id: BLEMessageId.generate(),
      type: BLEMessageType.chat,
      payload: BLEChatPayload(
        channel: channel,
        author: author,
        content: content,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        signature: signature,
        npub: npub,
      ).toJson(),
    );
  }

  /// Create a CHAT_ACK message
  static BLEMessage chatAck({
    required String requestId,
    required bool success,
    String? error,
  }) {
    return BLEMessage(
      id: requestId,
      type: BLEMessageType.chatAck,
      payload: BLEChatAckPayload(
        success: success,
        messageId: requestId,
        error: error,
      ).toJson(),
    );
  }

  /// Create an ERROR message
  static BLEMessage error({
    required String requestId,
    required String errorMessage,
    String? code,
  }) {
    return BLEMessage(
      id: requestId,
      type: BLEMessageType.error,
      payload: BLEErrorPayload(
        error: errorMessage,
        code: code,
      ).toJson(),
    );
  }
}
