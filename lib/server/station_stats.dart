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

  // Time-bucketed request counts (auto-reset on date change)
  int requestsToday = 0;
  int requestsThisWeek = 0;
  int requestsThisMonth = 0;
  int _currentDay = -1;
  int _currentWeek = -1;
  int _currentMonth = -1;

  // Bandwidth tracking (bytes served)
  int bytesServedTotal = 0;
  int bytesServedToday = 0;

  // Per-device request counts: callsign → count
  final Map<String, int> deviceRequestCounts = {};

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

  /// Full metrics including time buckets, bandwidth, and per-device stats
  Map<String, dynamic> toMetricsJson() => {
    ...toJson(),
    'requests_today': requestsToday,
    'requests_this_week': requestsThisWeek,
    'requests_this_month': requestsThisMonth,
    'bytes_served_total': bytesServedTotal,
    'bytes_served_today': bytesServedToday,
    'device_request_counts': deviceRequestCounts,
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
    requestsToday = 0;
    requestsThisWeek = 0;
    requestsThisMonth = 0;
    bytesServedTotal = 0;
    bytesServedToday = 0;
    deviceRequestCounts.clear();
  }

  /// Record an HTTP request with optional bandwidth and device attribution
  void recordRequest({int bytes = 0, String? callsign}) {
    final now = DateTime.now();
    final day = now.day + now.month * 100 + now.year * 10000;
    final week = (now.millisecondsSinceEpoch ~/ (7 * 86400000));
    final month = now.month + now.year * 100;

    // Reset daily counter on day change
    if (day != _currentDay) {
      requestsToday = 0;
      bytesServedToday = 0;
      _currentDay = day;
    }
    if (week != _currentWeek) {
      requestsThisWeek = 0;
      _currentWeek = week;
    }
    if (month != _currentMonth) {
      requestsThisMonth = 0;
      _currentMonth = month;
    }

    requestsToday++;
    requestsThisWeek++;
    requestsThisMonth++;
    totalApiRequests++;

    bytesServedTotal += bytes;
    bytesServedToday += bytes;

    if (callsign != null && callsign.isNotEmpty) {
      deviceRequestCounts[callsign] = (deviceRequestCounts[callsign] ?? 0) + 1;
    }
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

  /// Record an API request (legacy — prefer recordRequest for new code)
  void recordApiRequest() {
    totalApiRequests++;
  }

  /// Top devices sorted by request count (descending)
  List<MapEntry<String, int>> get topDevices {
    final sorted = deviceRequestCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted;
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
