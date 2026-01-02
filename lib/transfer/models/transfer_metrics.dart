import 'transfer_models.dart';

/// Complete metrics snapshot
class TransferMetrics {
  final int activeConnections;
  final int activeTransfers;
  final int queuedTransfers;
  final double currentSpeedBytesPerSecond;

  final TransferPeriodStats today;
  final TransferPeriodStats thisWeek;
  final TransferPeriodStats thisMonth;
  final TransferPeriodStats allTime;

  final Map<String, TransportStats> byTransport;
  final List<CallsignStats> topCallsigns;

  const TransferMetrics({
    this.activeConnections = 0,
    this.activeTransfers = 0,
    this.queuedTransfers = 0,
    this.currentSpeedBytesPerSecond = 0,
    this.today = const TransferPeriodStats(),
    this.thisWeek = const TransferPeriodStats(),
    this.thisMonth = const TransferPeriodStats(),
    this.allTime = const TransferPeriodStats(),
    this.byTransport = const {},
    this.topCallsigns = const [],
  });

  TransferMetrics copyWith({
    int? activeConnections,
    int? activeTransfers,
    int? queuedTransfers,
    double? currentSpeedBytesPerSecond,
    TransferPeriodStats? today,
    TransferPeriodStats? thisWeek,
    TransferPeriodStats? thisMonth,
    TransferPeriodStats? allTime,
    Map<String, TransportStats>? byTransport,
    List<CallsignStats>? topCallsigns,
  }) {
    return TransferMetrics(
      activeConnections: activeConnections ?? this.activeConnections,
      activeTransfers: activeTransfers ?? this.activeTransfers,
      queuedTransfers: queuedTransfers ?? this.queuedTransfers,
      currentSpeedBytesPerSecond:
          currentSpeedBytesPerSecond ?? this.currentSpeedBytesPerSecond,
      today: today ?? this.today,
      thisWeek: thisWeek ?? this.thisWeek,
      thisMonth: thisMonth ?? this.thisMonth,
      allTime: allTime ?? this.allTime,
      byTransport: byTransport ?? this.byTransport,
      topCallsigns: topCallsigns ?? this.topCallsigns,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'active_connections': activeConnections,
      'active_transfers': activeTransfers,
      'queued_transfers': queuedTransfers,
      'current_speed_bytes_per_second': currentSpeedBytesPerSecond,
      'today': today.toJson(),
      'this_week': thisWeek.toJson(),
      'this_month': thisMonth.toJson(),
      'all_time': allTime.toJson(),
      'by_transport':
          byTransport.map((key, value) => MapEntry(key, value.toJson())),
      'top_callsigns': topCallsigns.map((e) => e.toJson()).toList(),
    };
  }

  factory TransferMetrics.fromJson(Map<String, dynamic> json) {
    return TransferMetrics(
      activeConnections: json['active_connections'] as int? ?? 0,
      activeTransfers: json['active_transfers'] as int? ?? 0,
      queuedTransfers: json['queued_transfers'] as int? ?? 0,
      currentSpeedBytesPerSecond:
          (json['current_speed_bytes_per_second'] as num?)?.toDouble() ?? 0,
      today: json['today'] != null
          ? TransferPeriodStats.fromJson(json['today'] as Map<String, dynamic>)
          : const TransferPeriodStats(),
      thisWeek: json['this_week'] != null
          ? TransferPeriodStats.fromJson(
              json['this_week'] as Map<String, dynamic>)
          : const TransferPeriodStats(),
      thisMonth: json['this_month'] != null
          ? TransferPeriodStats.fromJson(
              json['this_month'] as Map<String, dynamic>)
          : const TransferPeriodStats(),
      allTime: json['all_time'] != null
          ? TransferPeriodStats.fromJson(
              json['all_time'] as Map<String, dynamic>)
          : const TransferPeriodStats(),
      byTransport: (json['by_transport'] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(
              key,
              TransportStats.fromJson(value as Map<String, dynamic>),
            ),
          ) ??
          {},
      topCallsigns: (json['top_callsigns'] as List<dynamic>?)
              ?.map(
                  (e) => CallsignStats.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// Statistics for a time period
class TransferPeriodStats {
  final int uploadCount;
  final int downloadCount;
  final int streamCount;
  final int bytesUploaded;
  final int bytesDownloaded;
  final int failedCount;
  final Duration totalTransferTime;
  final double averageSpeedBytesPerSecond;

  const TransferPeriodStats({
    this.uploadCount = 0,
    this.downloadCount = 0,
    this.streamCount = 0,
    this.bytesUploaded = 0,
    this.bytesDownloaded = 0,
    this.failedCount = 0,
    this.totalTransferTime = Duration.zero,
    this.averageSpeedBytesPerSecond = 0,
  });

  int get totalCount => uploadCount + downloadCount + streamCount;
  int get totalBytes => bytesUploaded + bytesDownloaded;
  double get successRate =>
      totalCount > 0 ? (totalCount - failedCount) / totalCount : 1.0;

  TransferPeriodStats copyWith({
    int? uploadCount,
    int? downloadCount,
    int? streamCount,
    int? bytesUploaded,
    int? bytesDownloaded,
    int? failedCount,
    Duration? totalTransferTime,
    double? averageSpeedBytesPerSecond,
  }) {
    return TransferPeriodStats(
      uploadCount: uploadCount ?? this.uploadCount,
      downloadCount: downloadCount ?? this.downloadCount,
      streamCount: streamCount ?? this.streamCount,
      bytesUploaded: bytesUploaded ?? this.bytesUploaded,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      failedCount: failedCount ?? this.failedCount,
      totalTransferTime: totalTransferTime ?? this.totalTransferTime,
      averageSpeedBytesPerSecond:
          averageSpeedBytesPerSecond ?? this.averageSpeedBytesPerSecond,
    );
  }

  TransferPeriodStats operator +(TransferPeriodStats other) {
    final combinedBytes = totalBytes + other.totalBytes;
    final combinedTime = totalTransferTime + other.totalTransferTime;
    final avgSpeed = combinedTime.inSeconds > 0
        ? combinedBytes / combinedTime.inSeconds
        : 0.0;

    return TransferPeriodStats(
      uploadCount: uploadCount + other.uploadCount,
      downloadCount: downloadCount + other.downloadCount,
      streamCount: streamCount + other.streamCount,
      bytesUploaded: bytesUploaded + other.bytesUploaded,
      bytesDownloaded: bytesDownloaded + other.bytesDownloaded,
      failedCount: failedCount + other.failedCount,
      totalTransferTime: combinedTime,
      averageSpeedBytesPerSecond: avgSpeed,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'upload_count': uploadCount,
      'download_count': downloadCount,
      'stream_count': streamCount,
      'bytes_uploaded': bytesUploaded,
      'bytes_downloaded': bytesDownloaded,
      'failed_count': failedCount,
      'total_transfer_time_ms': totalTransferTime.inMilliseconds,
      'average_speed_bytes_per_second': averageSpeedBytesPerSecond,
    };
  }

  factory TransferPeriodStats.fromJson(Map<String, dynamic> json) {
    return TransferPeriodStats(
      uploadCount: json['upload_count'] as int? ?? 0,
      downloadCount: json['download_count'] as int? ?? 0,
      streamCount: json['stream_count'] as int? ?? 0,
      bytesUploaded: json['bytes_uploaded'] as int? ?? 0,
      bytesDownloaded: json['bytes_downloaded'] as int? ?? 0,
      failedCount: json['failed_count'] as int? ?? 0,
      totalTransferTime: Duration(
        milliseconds: json['total_transfer_time_ms'] as int? ?? 0,
      ),
      averageSpeedBytesPerSecond:
          (json['average_speed_bytes_per_second'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Statistics per transport type
class TransportStats {
  final String transportId;
  final int transferCount;
  final int bytesTransferred;
  final double averageSpeed;
  final double successRate;

  const TransportStats({
    required this.transportId,
    this.transferCount = 0,
    this.bytesTransferred = 0,
    this.averageSpeed = 0,
    this.successRate = 1.0,
  });

  TransportStats copyWith({
    String? transportId,
    int? transferCount,
    int? bytesTransferred,
    double? averageSpeed,
    double? successRate,
  }) {
    return TransportStats(
      transportId: transportId ?? this.transportId,
      transferCount: transferCount ?? this.transferCount,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      averageSpeed: averageSpeed ?? this.averageSpeed,
      successRate: successRate ?? this.successRate,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'transport_id': transportId,
      'transfer_count': transferCount,
      'bytes_transferred': bytesTransferred,
      'average_speed': averageSpeed,
      'success_rate': successRate,
    };
  }

  factory TransportStats.fromJson(Map<String, dynamic> json) {
    return TransportStats(
      transportId: json['transport_id'] as String? ?? 'unknown',
      transferCount: json['transfer_count'] as int? ?? 0,
      bytesTransferred: json['bytes_transferred'] as int? ?? 0,
      averageSpeed: (json['average_speed'] as num?)?.toDouble() ?? 0,
      successRate: (json['success_rate'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

/// Statistics per callsign
class CallsignStats {
  final String callsign;
  final int uploadCount;
  final int downloadCount;
  final int bytesUploaded;
  final int bytesDownloaded;
  final DateTime lastActivity;

  CallsignStats({
    required this.callsign,
    this.uploadCount = 0,
    this.downloadCount = 0,
    this.bytesUploaded = 0,
    this.bytesDownloaded = 0,
    DateTime? lastActivity,
  }) : lastActivity = lastActivity ?? DateTime.now();

  int get totalTransfers => uploadCount + downloadCount;
  int get totalBytes => bytesUploaded + bytesDownloaded;

  CallsignStats copyWith({
    String? callsign,
    int? uploadCount,
    int? downloadCount,
    int? bytesUploaded,
    int? bytesDownloaded,
    DateTime? lastActivity,
  }) {
    return CallsignStats(
      callsign: callsign ?? this.callsign,
      uploadCount: uploadCount ?? this.uploadCount,
      downloadCount: downloadCount ?? this.downloadCount,
      bytesUploaded: bytesUploaded ?? this.bytesUploaded,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      lastActivity: lastActivity ?? this.lastActivity,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'callsign': callsign,
      'upload_count': uploadCount,
      'download_count': downloadCount,
      'bytes_uploaded': bytesUploaded,
      'bytes_downloaded': bytesDownloaded,
      'last_activity': lastActivity.toIso8601String(),
    };
  }

  factory CallsignStats.fromJson(Map<String, dynamic> json) {
    return CallsignStats(
      callsign: json['callsign'] as String,
      uploadCount: json['upload_count'] as int? ?? 0,
      downloadCount: json['download_count'] as int? ?? 0,
      bytesUploaded: json['bytes_uploaded'] as int? ?? 0,
      bytesDownloaded: json['bytes_downloaded'] as int? ?? 0,
      lastActivity: json['last_activity'] != null
          ? DateTime.parse(json['last_activity'] as String)
          : DateTime.now(),
    );
  }
}

/// History point for charts
class TransferHistoryPoint {
  final DateTime timestamp;
  final int bytesTransferred;
  final int activeConnections;
  final TransferDirection? direction;

  const TransferHistoryPoint({
    required this.timestamp,
    required this.bytesTransferred,
    this.activeConnections = 0,
    this.direction,
  });

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.toIso8601String(),
      'bytes_transferred': bytesTransferred,
      'active_connections': activeConnections,
      'direction': direction?.name,
    };
  }

  factory TransferHistoryPoint.fromJson(Map<String, dynamic> json) {
    return TransferHistoryPoint(
      timestamp: DateTime.parse(json['timestamp'] as String),
      bytesTransferred: json['bytes_transferred'] as int? ?? 0,
      activeConnections: json['active_connections'] as int? ?? 0,
      direction: json['direction'] != null
          ? TransferDirection.values.byName(json['direction'] as String)
          : null,
    );
  }
}

/// Daily statistics for storage
class DailyStats {
  final String date;
  final TransferPeriodStats stats;
  final List<HourlyStats> hourly;

  const DailyStats({
    required this.date,
    this.stats = const TransferPeriodStats(),
    this.hourly = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'date': date,
      'stats': stats.toJson(),
      'hourly': hourly.map((e) => e.toJson()).toList(),
    };
  }

  factory DailyStats.fromJson(Map<String, dynamic> json) {
    return DailyStats(
      date: json['date'] as String,
      stats: json['stats'] != null
          ? TransferPeriodStats.fromJson(json['stats'] as Map<String, dynamic>)
          : const TransferPeriodStats(),
      hourly: (json['hourly'] as List<dynamic>?)
              ?.map((e) => HourlyStats.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// Hourly statistics for charts
class HourlyStats {
  final int hour;
  final int bytesTransferred;
  final int connections;
  final int transfers;

  const HourlyStats({
    required this.hour,
    this.bytesTransferred = 0,
    this.connections = 0,
    this.transfers = 0,
  });

  Map<String, dynamic> toJson() {
    return {
      'hour': hour,
      'bytes': bytesTransferred,
      'connections': connections,
      'transfers': transfers,
    };
  }

  factory HourlyStats.fromJson(Map<String, dynamic> json) {
    return HourlyStats(
      hour: json['hour'] as int,
      bytesTransferred: json['bytes'] as int? ?? 0,
      connections: json['connections'] as int? ?? 0,
      transfers: json['transfers'] as int? ?? 0,
    );
  }
}

/// Stored metrics data structure
class StoredMetrics {
  static const String version = '1.0';

  final TransferPeriodStats allTime;
  final DateTime? firstTransferAt;
  final Map<String, DailyStats> daily;
  final Map<String, CallsignStats> byCallsign;
  final Map<String, TransportStats> byTransport;
  final DateTime updatedAt;

  StoredMetrics({
    this.allTime = const TransferPeriodStats(),
    this.firstTransferAt,
    Map<String, DailyStats>? daily,
    Map<String, CallsignStats>? byCallsign,
    Map<String, TransportStats>? byTransport,
    DateTime? updatedAt,
  })  : daily = daily ?? {},
        byCallsign = byCallsign ?? {},
        byTransport = byTransport ?? {},
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'updated_at': updatedAt.toIso8601String(),
      'all_time': {
        ...allTime.toJson(),
        'first_transfer_at': firstTransferAt?.toIso8601String(),
      },
      'daily': daily.map((key, value) => MapEntry(key, value.toJson())),
      'by_callsign':
          byCallsign.map((key, value) => MapEntry(key, value.toJson())),
      'by_transport':
          byTransport.map((key, value) => MapEntry(key, value.toJson())),
    };
  }

  factory StoredMetrics.fromJson(Map<String, dynamic> json) {
    final allTimeJson = json['all_time'] as Map<String, dynamic>?;
    return StoredMetrics(
      allTime: allTimeJson != null
          ? TransferPeriodStats.fromJson(allTimeJson)
          : const TransferPeriodStats(),
      firstTransferAt: allTimeJson?['first_transfer_at'] != null
          ? DateTime.parse(allTimeJson!['first_transfer_at'] as String)
          : null,
      daily: (json['daily'] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(
              key,
              DailyStats.fromJson(value as Map<String, dynamic>),
            ),
          ) ??
          {},
      byCallsign: (json['by_callsign'] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(
              key,
              CallsignStats.fromJson(value as Map<String, dynamic>),
            ),
          ) ??
          {},
      byTransport: (json['by_transport'] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(
              key,
              TransportStats.fromJson(value as Map<String, dynamic>),
            ),
          ) ??
          {},
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : DateTime.now(),
    );
  }
}
