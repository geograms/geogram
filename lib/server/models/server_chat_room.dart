/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Server-side chat room model for station servers.
 * Used for in-memory chat room management with WebSocket support.
 */

import '../../cli/commands/service_interfaces.dart';
import 'server_chat_message.dart';

/// Server-side chat room for station servers.
///
/// This model is used by station servers (CLI and GUI) for managing
/// chat rooms with WebSocket clients. It maintains room metadata
/// and an in-memory list of messages.
///
/// For client-side chat message parsing, see `lib/models/chat_message.dart`.
/// For API response DTOs, see `lib/api/endpoints/chat_api.dart`.
class ServerChatRoom implements ChatRoomReadable {
  final String id;
  String name;
  String description;
  final String creatorCallsign;
  final DateTime createdAt;
  DateTime lastActivity;
  final List<ServerChatMessage> messages = [];
  bool isPublic;

  ServerChatRoom({
    required this.id,
    required this.name,
    this.description = '',
    required this.creatorCallsign,
    DateTime? createdAt,
    this.isPublic = true,
  })  : createdAt = createdAt ?? DateTime.now().toUtc(),
        lastActivity = createdAt ?? DateTime.now().toUtc();

  @override
  List<ChatMessageReadable> get readableMessages =>
      messages.cast<ChatMessageReadable>();

  factory ServerChatRoom.fromJson(Map<String, dynamic> json) {
    final room = ServerChatRoom(
      id: json['id'] as String,
      name: json['name'] as String? ?? json['id'] as String,
      description: json['description'] as String? ?? '',
      creatorCallsign: json['creator'] as String? ?? 'Unknown',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      isPublic: json['is_public'] as bool? ?? true,
    );
    if (json['last_activity'] != null) {
      final parsed = DateTime.tryParse(json['last_activity'] as String);
      room.lastActivity = parsed?.toUtc() ?? DateTime.now().toUtc();
    }
    return room;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'creator': creatorCallsign,
        'created_at': createdAt.toIso8601String(),
        'last_activity': lastActivity.toIso8601String(),
        'message_count': messages.length,
        'is_public': isPublic,
      };

  /// Full JSON including messages (for persistence)
  Map<String, dynamic> toJsonWithMessages() => {
        'id': id,
        'name': name,
        'description': description,
        'creator': creatorCallsign,
        'created_at': createdAt.toIso8601String(),
        'last_activity': lastActivity.toIso8601String(),
        'is_public': isPublic,
        'messages': messages.map((m) => m.toJson()).toList(),
      };
}
