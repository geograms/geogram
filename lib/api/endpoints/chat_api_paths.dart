/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Chat API path utilities (pure Dart, no Flutter dependencies).
 * Used by both CLI and Flutter implementations.
 */

/// Chat API path utilities
class ChatApiPaths {
  // ============================================================
  // Path Builders
  // ============================================================

  /// Chat rooms list path: /api/chat/rooms
  static String roomsPath() => '/api/chat/rooms';

  /// Chat messages path: /api/chat/{roomId}/messages
  static String messagesPath(String roomId) => '/api/chat/$roomId/messages';

  /// Chat files path: /api/chat/{roomId}/files
  static String filesPath(String roomId) => '/api/chat/$roomId/files';

  /// Chat file download path: /api/chat/{roomId}/files/{filename}
  static String fileDownloadPath(String roomId, String filename) =>
      '/api/chat/$roomId/files/$filename';

  /// Chat message modification path: /api/chat/{roomId}/messages/{timestamp}
  static String messageModificationPath(String roomId, String timestamp) =>
      '/api/chat/rooms/$roomId/messages/$timestamp';

  /// Chat modifications log path: /api/chat/{roomId}/modifications
  static String modificationsPath(String roomId) =>
      '/api/chat/$roomId/modifications';

  /// Chat reactions path: /api/chat/{roomId}/messages/{timestamp}/reactions
  static String reactionsPath(String roomId, String timestamp) =>
      '/api/chat/$roomId/messages/$timestamp/reactions';

  /// Remote chat rooms path: /{callsign}/api/chat/rooms
  static String remoteRoomsPath(String callsign) => '/$callsign/api/chat/rooms';

  /// Remote chat messages path: /{callsign}/api/chat/{roomId}/messages
  static String remoteMessagesPath(String callsign, String roomId) =>
      '/$callsign/api/chat/$roomId/messages';

  /// Remote chat files path: /{callsign}/api/chat/{roomId}/files
  static String remoteFilesPath(String callsign, String roomId) =>
      '/$callsign/api/chat/$roomId/files';

  /// Remote chat file download path: /{callsign}/api/chat/{roomId}/files/{filename}
  static String remoteFileDownloadPath(String callsign, String roomId, String filename) =>
      '/$callsign/api/chat/$roomId/files/$filename';

  // ============================================================
  // URL Builders (with base URL)
  // ============================================================

  /// Build full URL for chat rooms endpoint
  static String roomsUrl(String baseUrl) {
    return '${_normalizeBaseUrl(baseUrl)}${roomsPath()}';
  }

  /// Build full URL for chat messages endpoint
  static String messagesUrl(String baseUrl, String roomId, {int? limit}) {
    final path = '${_normalizeBaseUrl(baseUrl)}${messagesPath(roomId)}';
    return limit != null ? '$path?limit=$limit' : path;
  }

  /// Build full URL for remote chat rooms endpoint
  static String remoteRoomsUrl(String baseUrl, String callsign) {
    return '${_normalizeBaseUrl(baseUrl)}${remoteRoomsPath(callsign)}';
  }

  /// Build full URL for remote chat messages endpoint
  static String remoteMessagesUrl(String baseUrl, String callsign, String roomId, {int? limit}) {
    final path = '${_normalizeBaseUrl(baseUrl)}${remoteMessagesPath(callsign, roomId)}';
    return limit != null ? '$path?limit=$limit' : path;
  }

  // ============================================================
  // Pattern Matchers
  // ============================================================

  /// Check if path matches chat rooms list pattern
  static bool isRoomsPath(String path) {
    return RegExp(r'^(/[A-Z0-9]+)?/api/chat/rooms/?$').hasMatch(path);
  }

  /// Check if path matches chat messages pattern
  static bool isMessagesPath(String path) {
    return RegExp(r'^(/[A-Z0-9]+)?/api/chat/(rooms/)?[^/]+/messages$').hasMatch(path);
  }

  /// Check if path matches chat files list pattern
  static bool isFilesListPath(String path) {
    return RegExp(r'^(/[A-Z0-9]+)?/api/chat/(rooms/)?[^/]+/files$').hasMatch(path);
  }

  /// Check if path matches chat file download pattern
  static bool isFileDownloadPath(String path) {
    return RegExp(r'^(/[A-Z0-9]+)?/api/chat/(rooms/)?[^/]+/files/.+$').hasMatch(path);
  }

  /// Check if path matches chat message modification pattern (DELETE/PUT)
  /// Matches /api/chat/{roomId}/messages/{timestamp} but NOT .../reactions
  static bool isMessageModificationPath(String path) {
    return RegExp(r'^(/[A-Z0-9]+)?/api/chat/(rooms/)?[^/]+/messages/[^/]+$').hasMatch(path) &&
        !path.endsWith('/reactions');
  }

  /// Check if path matches chat modifications log pattern
  /// Matches /api/chat/{roomId}/modifications
  static bool isModificationsPath(String path) {
    return RegExp(r'^(/[A-Z0-9]+)?/api/chat/(rooms/)?[^/]+/modifications$').hasMatch(path);
  }

  /// Check if path matches chat reactions pattern
  static bool isReactionsPath(String path) {
    return RegExp(r'^(/[A-Z0-9]+)?/api/chat/(rooms/)?[^/]+/messages/.+/reactions$').hasMatch(path);
  }

  // ============================================================
  // Extractors
  // ============================================================

  /// Extract callsign from a chat API path with callsign prefix
  static String? extractCallsign(String path) {
    final match = RegExp(r'^/([A-Z0-9]+)/api/').firstMatch(path);
    return match?.group(1);
  }

  /// Extract room ID from a chat messages or files path
  static String? extractRoomId(String path) {
    // Try format without 'rooms/': /api/chat/{roomId}/messages
    var match = RegExp(r'/api/chat/([^/]+)/(?:messages|files)').firstMatch(path);
    if (match != null) {
      final roomId = match.group(1);
      if (roomId != 'rooms') return roomId;
    }
    // Fallback to format with 'rooms/': /api/chat/rooms/{roomId}/messages
    match = RegExp(r'/api/chat/rooms/([^/]+)/(?:messages|files)').firstMatch(path);
    return match?.group(1);
  }

  /// Extract filename from a file download path
  static String? extractFilename(String path) {
    final match = RegExp(r'/files/(.+)$').firstMatch(path);
    return match?.group(1);
  }

  /// Extract timestamp from a reactions path
  static String? extractTimestamp(String path) {
    final match = RegExp(r'/messages/([^/]+)/reactions$').firstMatch(path);
    return match?.group(1);
  }

  /// Extract timestamp from a message modification path (DELETE/PUT)
  static String? extractModificationTimestamp(String path) {
    final match = RegExp(r'/messages/([^/]+)$').firstMatch(path);
    return match?.group(1);
  }

  // ============================================================
  // Helpers
  // ============================================================

  static String _normalizeBaseUrl(String baseUrl) {
    return baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  }
}

// Re-export as ChatApi for backward compatibility with pure_station.dart
// (which uses ChatApi.isRoomsPath, etc.)
typedef ChatApi = ChatApiPaths;
