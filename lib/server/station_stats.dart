// Server statistics for station server

import '../cli/commands/service_interfaces.dart';

/// Server statistics tracking
class StationStats implements StationStatsReadable {
  int totalConnections = 0;
  int totalMessages = 0;
  int totalTileRequests = 0;
  int totalApiRequests = 0;
  int tilesCached = 0;
  int tilesServedFromCache = 0;
  int tilesDownloaded = 0;
  DateTime? lastConnection;
  DateTime? lastMessage;
  DateTime? lastTileRequest;

  Map<String, dynamic> toJson() => {
    'total_connections': totalConnections,
    'total_messages': totalMessages,
    'total_tile_requests': totalTileRequests,
    'total_api_requests': totalApiRequests,
    'tiles_cached': tilesCached,
    'tiles_served_from_cache': tilesServedFromCache,
    'tiles_downloaded': tilesDownloaded,
    'last_connection': lastConnection?.toIso8601String(),
    'last_message': lastMessage?.toIso8601String(),
    'last_tile_request': lastTileRequest?.toIso8601String(),
  };

  /// Reset all statistics
  void reset() {
    totalConnections = 0;
    totalMessages = 0;
    totalTileRequests = 0;
    totalApiRequests = 0;
    tilesCached = 0;
    tilesServedFromCache = 0;
    tilesDownloaded = 0;
    lastConnection = null;
    lastMessage = null;
    lastTileRequest = null;
  }

  /// Record a new client connection
  void recordConnection() {
    totalConnections++;
    lastConnection = DateTime.now();
  }

  /// Record a new message
  void recordMessage() {
    totalMessages++;
    lastMessage = DateTime.now();
  }

  /// Record a tile request
  void recordTileRequest({bool fromCache = false}) {
    totalTileRequests++;
    lastTileRequest = DateTime.now();
    if (fromCache) {
      tilesServedFromCache++;
    } else {
      tilesDownloaded++;
    }
  }

  /// Record a cached tile
  void recordTileCached() {
    tilesCached++;
  }

  /// Record an API request
  void recordApiRequest() {
    totalApiRequests++;
  }
}

/// Log entry for CLI log history
class LogEntry implements LogEntryReadable {
  final DateTime timestamp;
  final String level;
  final String message;

  LogEntry(this.timestamp, this.level, this.message);

  @override
  String toString() =>
      '[${timestamp.toIso8601String()}] [$level] $message';

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'level': level,
    'message': message,
  };
}
