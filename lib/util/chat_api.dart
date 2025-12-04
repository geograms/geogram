/*
 * Shared Chat API definitions
 * Used by both relay server and client
 */

/// Chat API path utilities
/// All chat endpoints follow the pattern: /{callsign}/api/chat/...
class ChatApi {
  /// Get the chat rooms endpoint for a callsign
  /// Returns: /{callsign}/api/chat/rooms
  static String roomsPath(String callsign) => '/$callsign/api/chat/rooms';

  /// Get the room messages endpoint
  /// Returns: /{callsign}/api/chat/rooms/{roomId}/messages
  static String messagesPath(String callsign, String roomId) =>
      '/$callsign/api/chat/rooms/$roomId/messages';

  /// Build full URL for chat rooms endpoint
  static String roomsUrl(String baseUrl, String callsign) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$base${roomsPath(callsign)}';
  }

  /// Build full URL for room messages endpoint
  static String messagesUrl(String baseUrl, String callsign, String roomId, {int? limit}) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final path = '$base${messagesPath(callsign, roomId)}';
    if (limit != null) {
      return '$path?limit=$limit';
    }
    return path;
  }

  /// Check if a path matches the chat rooms pattern: /{callsign}/api/chat/rooms
  static bool isRoomsPath(String path) {
    return RegExp(r'^/[A-Z0-9]+/api/chat/rooms$').hasMatch(path);
  }

  /// Check if a path matches the messages pattern: /{callsign}/api/chat/rooms/{roomId}/messages
  static bool isMessagesPath(String path) {
    return RegExp(r'^/[A-Z0-9]+/api/chat/rooms/[^/]+/messages$').hasMatch(path);
  }

  /// Extract callsign from a chat API path
  /// Returns null if path doesn't match expected pattern
  static String? extractCallsign(String path) {
    final match = RegExp(r'^/([A-Z0-9]+)/api/chat/').firstMatch(path);
    return match?.group(1);
  }

  /// Extract room ID from a messages path
  /// Returns null if path doesn't match expected pattern
  static String? extractRoomId(String path) {
    final match = RegExp(r'^/[A-Z0-9]+/api/chat/rooms/([^/]+)/messages$').firstMatch(path);
    return match?.group(1);
  }
}
