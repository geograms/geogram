/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Chat API endpoints for rooms and messages.
 *
 * Merged from lib/util/chat_api.dart - provides both path utilities
 * and API methods for chat operations.
 *
 * UNIFIED API PATH FORMAT:
 * - Chat: /api/chat/{roomId}/messages, /api/chat/{roomId}/files
 * - Remote (with callsign prefix): /{callsign}/api/chat/{roomId}/messages
 */

import '../api.dart';
import 'chat_api_paths.dart' as paths;
export 'chat_api_paths.dart' show ChatApiPaths;

/// Chat room info
class ChatRoom {
  final String id;
  final String? name;
  final String? description;
  final String? type; // 'public', 'private', 'restricted'
  final int memberCount;
  final int messageCount;
  final DateTime? lastActivity;
  final bool isJoined;

  const ChatRoom({
    required this.id,
    this.name,
    this.description,
    this.type,
    this.memberCount = 0,
    this.messageCount = 0,
    this.lastActivity,
    this.isJoined = false,
  });

  factory ChatRoom.fromJson(Map<String, dynamic> json) {
    return ChatRoom(
      id: json['id'] as String? ?? json['roomId'] as String? ?? '',
      name: json['name'] as String?,
      description: json['description'] as String?,
      type: json['type'] as String?,
      memberCount: json['memberCount'] as int? ?? json['member_count'] as int? ?? 0,
      messageCount: json['messageCount'] as int? ?? json['message_count'] as int? ?? 0,
      lastActivity: _parseDateTime(json['lastActivity'] ?? json['last_activity']),
      isJoined: json['isJoined'] as bool? ?? json['is_joined'] as bool? ?? false,
    );
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}

/// Chat message
class ChatMessage {
  final String id;
  final String? content;
  final String? author;
  final String? authorNpub;
  final DateTime timestamp;
  final bool isEdited;
  final Map<String, int> reactions;
  final String? replyTo;

  const ChatMessage({
    required this.id,
    this.content,
    this.author,
    this.authorNpub,
    required this.timestamp,
    this.isEdited = false,
    this.reactions = const {},
    this.replyTo,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String? ?? json['timestamp']?.toString() ?? '',
      content: json['content'] as String?,
      author: json['author'] as String? ?? json['callsign'] as String?,
      authorNpub: json['npub'] as String? ?? json['authorNpub'] as String?,
      timestamp: _parseDateTime(json['timestamp']) ?? DateTime.now(),
      isEdited: json['isEdited'] as bool? ?? json['edited'] as bool? ?? false,
      reactions: (json['reactions'] as Map<String, dynamic>?)?.cast<String, int>() ?? {},
      replyTo: json['replyTo'] as String? ?? json['reply_to'] as String?,
    );
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}

/// Chat file info
class ChatFile {
  final String name;
  final String? path;
  final int? size;
  final String? contentType;
  final DateTime? uploadedAt;
  final String? uploader;

  const ChatFile({
    required this.name,
    this.path,
    this.size,
    this.contentType,
    this.uploadedAt,
    this.uploader,
  });

  factory ChatFile.fromJson(Map<String, dynamic> json) {
    return ChatFile(
      name: json['name'] as String? ?? json['filename'] as String? ?? '',
      path: json['path'] as String?,
      size: json['size'] as int?,
      contentType: json['contentType'] as String? ?? json['content_type'] as String?,
      uploadedAt: json['uploadedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch((json['uploadedAt'] as num).toInt() * 1000)
          : null,
      uploader: json['uploader'] as String?,
    );
  }
}

/// Chat API endpoints
class ChatApi {
  final GeogramApi _api;

  ChatApi(this._api);

  // ============================================================
  // API Methods
  // ============================================================

  /// List chat rooms
  Future<ApiListResponse<ChatRoom>> rooms(String callsign) {
    return _api.list<ChatRoom>(
      callsign,
      '/api/chat/rooms',
      itemFromJson: (json) => ChatRoom.fromJson(json as Map<String, dynamic>),
      listKey: 'rooms',
    );
  }

  /// Get messages from a room
  ///
  /// [limit] - Maximum number of messages
  /// [since] - Get messages after this timestamp (Unix seconds)
  /// [before] - Get messages before this timestamp (Unix seconds)
  Future<ApiListResponse<ChatMessage>> messages(
    String callsign,
    String roomId, {
    int? limit,
    int? since,
    int? before,
  }) {
    return _api.list<ChatMessage>(
      callsign,
      '/api/chat/rooms/$roomId/messages',
      queryParams: {
        if (limit != null) 'limit': limit,
        if (since != null) 'since': since,
        if (before != null) 'before': before,
      },
      itemFromJson: (json) => ChatMessage.fromJson(json as Map<String, dynamic>),
      listKey: 'messages',
    );
  }

  /// Send a message to a room
  Future<ApiResponse<ChatMessage>> sendMessage(
    String callsign,
    String roomId,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.post<ChatMessage>(
      callsign,
      '/api/chat/rooms/$roomId/messages',
      body: {'event': signedEvent},
      fromJson: (json) => ChatMessage.fromJson(json as Map<String, dynamic>),
    );
  }

  /// Edit a message
  Future<ApiResponse<ChatMessage>> editMessage(
    String callsign,
    String roomId,
    String timestamp,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.put<ChatMessage>(
      callsign,
      '/api/chat/rooms/$roomId/messages/${Uri.encodeComponent(timestamp)}',
      body: {'event': signedEvent},
      fromJson: (json) => ChatMessage.fromJson(json as Map<String, dynamic>),
    );
  }

  /// Delete a message
  Future<ApiResponse<void>> deleteMessage(
    String callsign,
    String roomId,
    String timestamp,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.delete<void>(
      callsign,
      '/api/chat/rooms/$roomId/messages/${Uri.encodeComponent(timestamp)}',
      headers: {'X-Nostr-Event': signedEvent.toString()},
    );
  }

  /// Add reaction to a message
  Future<ApiResponse<Map<String, dynamic>>> react(
    String callsign,
    String roomId,
    String timestamp,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.post<Map<String, dynamic>>(
      callsign,
      '/api/chat/rooms/$roomId/messages/${Uri.encodeComponent(timestamp)}/reactions',
      body: signedEvent,
      fromJson: (json) => json as Map<String, dynamic>,
    );
  }

  /// List files in a room
  Future<ApiListResponse<ChatFile>> files(String callsign, String roomId) {
    return _api.list<ChatFile>(
      callsign,
      '/api/chat/rooms/$roomId/files',
      itemFromJson: (json) => ChatFile.fromJson(json as Map<String, dynamic>),
      listKey: 'files',
    );
  }

  /// Upload a file to a room
  Future<ApiResponse<ChatFile>> uploadFile(
    String callsign,
    String roomId,
    String filename,
    List<int> fileData, {
    String? contentType,
  }) {
    return _api.post<ChatFile>(
      callsign,
      '/api/chat/rooms/$roomId/files',
      body: fileData,
      headers: {
        if (contentType != null) 'Content-Type': contentType,
        'X-Filename': filename,
      },
      fromJson: (json) => ChatFile.fromJson(json as Map<String, dynamic>),
    );
  }

  /// Download a file from a room
  Future<ApiResponse<dynamic>> downloadFile(
    String callsign,
    String roomId,
    String filename,
  ) {
    return _api.get<dynamic>(
      callsign,
      '/api/chat/rooms/$roomId/files/$filename',
    );
  }

  // ============================================================
  // Room Management
  // ============================================================

  /// Add member to room
  Future<ApiResponse<void>> addMember(
    String callsign,
    String roomId,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.post<void>(
      callsign,
      '/api/chat/$roomId/members',
      body: {'event': signedEvent},
    );
  }

  /// Remove member from room
  Future<ApiResponse<void>> removeMember(
    String callsign,
    String roomId,
    String memberNpub,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.delete<void>(
      callsign,
      '/api/chat/$roomId/members/$memberNpub',
      headers: {'X-Nostr-Event': signedEvent.toString()},
    );
  }

  /// Ban user from room
  Future<ApiResponse<void>> banUser(
    String callsign,
    String roomId,
    String userNpub,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.post<void>(
      callsign,
      '/api/chat/$roomId/ban/$userNpub',
      body: {'event': signedEvent},
    );
  }

  /// Unban user from room
  Future<ApiResponse<void>> unbanUser(
    String callsign,
    String roomId,
    String userNpub,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.delete<void>(
      callsign,
      '/api/chat/$roomId/ban/$userNpub',
      headers: {'X-Nostr-Event': signedEvent.toString()},
    );
  }

  /// Get room roles
  Future<ApiResponse<Map<String, dynamic>>> getRoles(
    String callsign,
    String roomId,
  ) {
    return _api.get<Map<String, dynamic>>(
      callsign,
      '/api/chat/$roomId/roles',
      fromJson: (json) => json as Map<String, dynamic>,
    );
  }

  /// Promote member
  Future<ApiResponse<void>> promoteMember(
    String callsign,
    String roomId,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.post<void>(
      callsign,
      '/api/chat/$roomId/promote',
      body: {'event': signedEvent},
    );
  }

  /// Demote member
  Future<ApiResponse<void>> demoteMember(
    String callsign,
    String roomId,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.post<void>(
      callsign,
      '/api/chat/$roomId/demote',
      body: {'event': signedEvent},
    );
  }

  // ============================================================
  // Membership Application (for restricted rooms)
  // ============================================================

  /// Apply for membership
  Future<ApiResponse<void>> apply(
    String callsign,
    String roomId,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.post<void>(
      callsign,
      '/api/chat/$roomId/apply',
      body: {'event': signedEvent},
    );
  }

  /// List pending applicants
  Future<ApiListResponse<Map<String, dynamic>>> applicants(
    String callsign,
    String roomId,
  ) {
    return _api.list<Map<String, dynamic>>(
      callsign,
      '/api/chat/$roomId/applicants',
      itemFromJson: (json) => json as Map<String, dynamic>,
      listKey: 'applicants',
    );
  }

  /// Approve applicant
  Future<ApiResponse<void>> approveApplicant(
    String callsign,
    String roomId,
    String applicantNpub,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.post<void>(
      callsign,
      '/api/chat/$roomId/approve/$applicantNpub',
      body: {'event': signedEvent},
    );
  }

  /// Reject applicant
  Future<ApiResponse<void>> rejectApplicant(
    String callsign,
    String roomId,
    String applicantNpub,
    Map<String, dynamic> signedEvent,
  ) {
    return _api.delete<void>(
      callsign,
      '/api/chat/$roomId/reject/$applicantNpub',
      headers: {'X-Nostr-Event': signedEvent.toString()},
    );
  }

  // ============================================================
  // Path Utilities - delegated to ChatApiPaths for CLI compatibility
  // ============================================================

  static String roomsPath() => paths.ChatApiPaths.roomsPath();
  static String messagesPath(String roomId) => paths.ChatApiPaths.messagesPath(roomId);
  static String filesPath(String roomId) => paths.ChatApiPaths.filesPath(roomId);
  static String fileDownloadPath(String roomId, String filename) =>
      paths.ChatApiPaths.fileDownloadPath(roomId, filename);
  static String reactionsPath(String roomId, String timestamp) =>
      paths.ChatApiPaths.reactionsPath(roomId, timestamp);
  static String remoteRoomsPath(String callsign) => paths.ChatApiPaths.remoteRoomsPath(callsign);
  static String remoteMessagesPath(String callsign, String roomId) =>
      paths.ChatApiPaths.remoteMessagesPath(callsign, roomId);
  static String remoteFilesPath(String callsign, String roomId) =>
      paths.ChatApiPaths.remoteFilesPath(callsign, roomId);
  static String remoteFileDownloadPath(String callsign, String roomId, String filename) =>
      paths.ChatApiPaths.remoteFileDownloadPath(callsign, roomId, filename);

  static String roomsUrl(String baseUrl) => paths.ChatApiPaths.roomsUrl(baseUrl);
  static String messagesUrl(String baseUrl, String roomId, {int? limit}) =>
      paths.ChatApiPaths.messagesUrl(baseUrl, roomId, limit: limit);
  static String remoteRoomsUrl(String baseUrl, String callsign) =>
      paths.ChatApiPaths.remoteRoomsUrl(baseUrl, callsign);
  static String remoteMessagesUrl(String baseUrl, String callsign, String roomId, {int? limit}) =>
      paths.ChatApiPaths.remoteMessagesUrl(baseUrl, callsign, roomId, limit: limit);

  static bool isRoomsPath(String path) => paths.ChatApiPaths.isRoomsPath(path);
  static bool isMessagesPath(String path) => paths.ChatApiPaths.isMessagesPath(path);
  static bool isFilesListPath(String path) => paths.ChatApiPaths.isFilesListPath(path);
  static bool isFileDownloadPath(String path) => paths.ChatApiPaths.isFileDownloadPath(path);
  static bool isReactionsPath(String path) => paths.ChatApiPaths.isReactionsPath(path);

  static String? extractCallsign(String path) => paths.ChatApiPaths.extractCallsign(path);
  static String? extractRoomId(String path) => paths.ChatApiPaths.extractRoomId(path);
  static String? extractFilename(String path) => paths.ChatApiPaths.extractFilename(path);
  static String? extractTimestamp(String path) => paths.ChatApiPaths.extractTimestamp(path);
}
