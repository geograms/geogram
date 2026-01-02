import 'dart:convert';

/// Transfer direction
enum TransferDirection {
  upload,
  download,
  stream,
}

/// Transfer status lifecycle
enum TransferStatus {
  queued,
  connecting,
  transferring,
  verifying,
  completed,
  failed,
  cancelled,
  paused,
  waiting,
}

/// Transfer priority levels
enum TransferPriority {
  low,
  normal,
  high,
  urgent,
}

/// Main Transfer model
class Transfer {
  final String id;
  final TransferDirection direction;
  final String sourceCallsign;
  final String? sourceStationUrl;
  final String targetCallsign;
  final String remotePath;
  final String localPath;
  final String? filename;
  int expectedBytes;
  final String? expectedHash;
  final String? mimeType;

  TransferStatus status;
  TransferPriority priority;
  int bytesTransferred;
  int retryCount;
  final DateTime createdAt;
  DateTime? startedAt;
  DateTime? completedAt;
  DateTime? lastActivityAt;
  DateTime? nextRetryAt;
  String? error;
  String? transportUsed;

  double? speedBytesPerSecond;
  Duration? estimatedTimeRemaining;

  final String? requestingApp;
  final Map<String, dynamic>? metadata;
  Duration? timeout;

  Transfer({
    required this.id,
    required this.direction,
    required this.sourceCallsign,
    this.sourceStationUrl,
    required this.targetCallsign,
    required this.remotePath,
    required this.localPath,
    this.filename,
    required this.expectedBytes,
    this.expectedHash,
    this.mimeType,
    this.status = TransferStatus.queued,
    this.priority = TransferPriority.normal,
    this.bytesTransferred = 0,
    this.retryCount = 0,
    DateTime? createdAt,
    this.startedAt,
    this.completedAt,
    this.lastActivityAt,
    this.nextRetryAt,
    this.error,
    this.transportUsed,
    this.speedBytesPerSecond,
    this.estimatedTimeRemaining,
    this.requestingApp,
    this.metadata,
    this.timeout,
  }) : createdAt = createdAt ?? DateTime.now();

  double get progressPercent =>
      expectedBytes > 0 ? (bytesTransferred / expectedBytes * 100) : 0;

  bool get isActive =>
      status == TransferStatus.connecting ||
      status == TransferStatus.transferring ||
      status == TransferStatus.verifying;

  bool get isPending =>
      status == TransferStatus.queued || status == TransferStatus.waiting;

  bool get isCompleted => status == TransferStatus.completed;

  bool get isFailed => status == TransferStatus.failed;

  bool get canRetry =>
      status == TransferStatus.failed || status == TransferStatus.cancelled;

  bool get canPause => isActive;

  bool get canResume => status == TransferStatus.paused;

  bool get canCancel =>
      status != TransferStatus.completed &&
      status != TransferStatus.cancelled;

  Transfer copyWith({
    String? id,
    TransferDirection? direction,
    String? sourceCallsign,
    String? sourceStationUrl,
    String? targetCallsign,
    String? remotePath,
    String? localPath,
    String? filename,
    int? expectedBytes,
    String? expectedHash,
    String? mimeType,
    TransferStatus? status,
    TransferPriority? priority,
    int? bytesTransferred,
    int? retryCount,
    DateTime? createdAt,
    DateTime? startedAt,
    DateTime? completedAt,
    DateTime? lastActivityAt,
    DateTime? nextRetryAt,
    String? error,
    String? transportUsed,
    double? speedBytesPerSecond,
    Duration? estimatedTimeRemaining,
    String? requestingApp,
    Map<String, dynamic>? metadata,
    Duration? timeout,
  }) {
    return Transfer(
      id: id ?? this.id,
      direction: direction ?? this.direction,
      sourceCallsign: sourceCallsign ?? this.sourceCallsign,
      sourceStationUrl: sourceStationUrl ?? this.sourceStationUrl,
      targetCallsign: targetCallsign ?? this.targetCallsign,
      remotePath: remotePath ?? this.remotePath,
      localPath: localPath ?? this.localPath,
      filename: filename ?? this.filename,
      expectedBytes: expectedBytes ?? this.expectedBytes,
      expectedHash: expectedHash ?? this.expectedHash,
      mimeType: mimeType ?? this.mimeType,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      retryCount: retryCount ?? this.retryCount,
      createdAt: createdAt ?? this.createdAt,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      lastActivityAt: lastActivityAt ?? this.lastActivityAt,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      error: error ?? this.error,
      transportUsed: transportUsed ?? this.transportUsed,
      speedBytesPerSecond: speedBytesPerSecond ?? this.speedBytesPerSecond,
      estimatedTimeRemaining:
          estimatedTimeRemaining ?? this.estimatedTimeRemaining,
      requestingApp: requestingApp ?? this.requestingApp,
      metadata: metadata ?? this.metadata,
      timeout: timeout ?? this.timeout,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'direction': direction.name,
      'source_callsign': sourceCallsign,
      'source_station_url': sourceStationUrl,
      'target_callsign': targetCallsign,
      'remote_path': remotePath,
      'local_path': localPath,
      'filename': filename,
      'expected_bytes': expectedBytes,
      'expected_hash': expectedHash,
      'mime_type': mimeType,
      'status': status.name,
      'priority': priority.name,
      'bytes_transferred': bytesTransferred,
      'retry_count': retryCount,
      'created_at': createdAt.toIso8601String(),
      'started_at': startedAt?.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
      'last_activity_at': lastActivityAt?.toIso8601String(),
      'next_retry_at': nextRetryAt?.toIso8601String(),
      'error': error,
      'transport_used': transportUsed,
      'speed_bytes_per_second': speedBytesPerSecond,
      'estimated_time_remaining_ms': estimatedTimeRemaining?.inMilliseconds,
      'requesting_app': requestingApp,
      'metadata': metadata,
      'timeout_ms': timeout?.inMilliseconds,
    };
  }

  factory Transfer.fromJson(Map<String, dynamic> json) {
    return Transfer(
      id: json['id'] as String,
      direction: TransferDirection.values.byName(json['direction'] as String),
      sourceCallsign: json['source_callsign'] as String,
      sourceStationUrl: json['source_station_url'] as String?,
      targetCallsign: json['target_callsign'] as String,
      remotePath: json['remote_path'] as String,
      localPath: json['local_path'] as String,
      filename: json['filename'] as String?,
      expectedBytes: json['expected_bytes'] as int? ?? 0,
      expectedHash: json['expected_hash'] as String?,
      mimeType: json['mime_type'] as String?,
      status: TransferStatus.values.byName(json['status'] as String),
      priority: TransferPriority.values.byName(
        json['priority'] as String? ?? 'normal',
      ),
      bytesTransferred: json['bytes_transferred'] as int? ?? 0,
      retryCount: json['retry_count'] as int? ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      startedAt: json['started_at'] != null
          ? DateTime.parse(json['started_at'] as String)
          : null,
      completedAt: json['completed_at'] != null
          ? DateTime.parse(json['completed_at'] as String)
          : null,
      lastActivityAt: json['last_activity_at'] != null
          ? DateTime.parse(json['last_activity_at'] as String)
          : null,
      nextRetryAt: json['next_retry_at'] != null
          ? DateTime.parse(json['next_retry_at'] as String)
          : null,
      error: json['error'] as String?,
      transportUsed: json['transport_used'] as String?,
      speedBytesPerSecond: json['speed_bytes_per_second'] as double?,
      estimatedTimeRemaining: json['estimated_time_remaining_ms'] != null
          ? Duration(milliseconds: json['estimated_time_remaining_ms'] as int)
          : null,
      requestingApp: json['requesting_app'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
      timeout: json['timeout_ms'] != null
          ? Duration(milliseconds: json['timeout_ms'] as int)
          : null,
    );
  }

  @override
  String toString() {
    return 'Transfer(id: $id, direction: $direction, status: $status, '
        'progress: ${progressPercent.toStringAsFixed(1)}%)';
  }
}

/// Transfer request from another app
class TransferRequest {
  final String? id;
  final TransferDirection direction;
  final String callsign;
  final String? stationUrl;
  final String remotePath;
  final String localPath;
  final int? expectedBytes;
  final String? expectedHash;
  final TransferPriority priority;
  final String? requestingApp;
  final Map<String, dynamic>? metadata;
  final Duration? timeout;

  const TransferRequest({
    this.id,
    required this.direction,
    required this.callsign,
    this.stationUrl,
    required this.remotePath,
    required this.localPath,
    this.expectedBytes,
    this.expectedHash,
    this.priority = TransferPriority.normal,
    this.requestingApp,
    this.metadata,
    this.timeout,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'direction': direction.name,
      'callsign': callsign,
      'station_url': stationUrl,
      'remote_path': remotePath,
      'local_path': localPath,
      'expected_bytes': expectedBytes,
      'expected_hash': expectedHash,
      'priority': priority.name,
      'requesting_app': requestingApp,
      'metadata': metadata,
      'timeout_ms': timeout?.inMilliseconds,
    };
  }

  factory TransferRequest.fromJson(Map<String, dynamic> json) {
    return TransferRequest(
      id: json['id'] as String?,
      direction: TransferDirection.values.byName(json['direction'] as String),
      callsign: json['callsign'] as String,
      stationUrl: json['station_url'] as String?,
      remotePath: json['remote_path'] as String,
      localPath: json['local_path'] as String,
      expectedBytes: json['expected_bytes'] as int?,
      expectedHash: json['expected_hash'] as String?,
      priority: TransferPriority.values.byName(
        json['priority'] as String? ?? 'normal',
      ),
      requestingApp: json['requesting_app'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
      timeout: json['timeout_ms'] != null
          ? Duration(milliseconds: json['timeout_ms'] as int)
          : null,
    );
  }
}

/// Transfer queue settings
class TransferSettings {
  bool enabled;
  int maxConcurrentTransfers;
  int maxRetries;
  Duration baseRetryDelay;
  Duration maxRetryDelay;
  double retryBackoffMultiplier;
  Duration patientModeTimeout;
  int maxQueueSize;
  List<String> bannedCallsigns;
  DateTime updatedAt;

  TransferSettings({
    this.enabled = true,
    this.maxConcurrentTransfers = 3,
    this.maxRetries = 10,
    this.baseRetryDelay = const Duration(seconds: 30),
    this.maxRetryDelay = const Duration(hours: 1),
    this.retryBackoffMultiplier = 2.0,
    this.patientModeTimeout = const Duration(days: 30),
    this.maxQueueSize = 1000,
    List<String>? bannedCallsigns,
    DateTime? updatedAt,
  })  : bannedCallsigns = bannedCallsigns ?? [],
        updatedAt = updatedAt ?? DateTime.now();

  TransferSettings copyWith({
    bool? enabled,
    int? maxConcurrentTransfers,
    int? maxRetries,
    Duration? baseRetryDelay,
    Duration? maxRetryDelay,
    double? retryBackoffMultiplier,
    Duration? patientModeTimeout,
    int? maxQueueSize,
    List<String>? bannedCallsigns,
    DateTime? updatedAt,
  }) {
    return TransferSettings(
      enabled: enabled ?? this.enabled,
      maxConcurrentTransfers:
          maxConcurrentTransfers ?? this.maxConcurrentTransfers,
      maxRetries: maxRetries ?? this.maxRetries,
      baseRetryDelay: baseRetryDelay ?? this.baseRetryDelay,
      maxRetryDelay: maxRetryDelay ?? this.maxRetryDelay,
      retryBackoffMultiplier:
          retryBackoffMultiplier ?? this.retryBackoffMultiplier,
      patientModeTimeout: patientModeTimeout ?? this.patientModeTimeout,
      maxQueueSize: maxQueueSize ?? this.maxQueueSize,
      bannedCallsigns: bannedCallsigns ?? List.from(this.bannedCallsigns),
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': '1.0',
      'enabled': enabled,
      'max_concurrent_transfers': maxConcurrentTransfers,
      'max_retries': maxRetries,
      'base_retry_delay_seconds': baseRetryDelay.inSeconds,
      'max_retry_delay_seconds': maxRetryDelay.inSeconds,
      'retry_backoff_multiplier': retryBackoffMultiplier,
      'patient_mode_timeout_days': patientModeTimeout.inDays,
      'max_queue_size': maxQueueSize,
      'banned_callsigns': bannedCallsigns,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory TransferSettings.fromJson(Map<String, dynamic> json) {
    return TransferSettings(
      enabled: json['enabled'] as bool? ?? true,
      maxConcurrentTransfers: json['max_concurrent_transfers'] as int? ?? 3,
      maxRetries: json['max_retries'] as int? ?? 10,
      baseRetryDelay: Duration(
        seconds: json['base_retry_delay_seconds'] as int? ?? 30,
      ),
      maxRetryDelay: Duration(
        seconds: json['max_retry_delay_seconds'] as int? ?? 3600,
      ),
      retryBackoffMultiplier:
          (json['retry_backoff_multiplier'] as num?)?.toDouble() ?? 2.0,
      patientModeTimeout: Duration(
        days: json['patient_mode_timeout_days'] as int? ?? 30,
      ),
      maxQueueSize: json['max_queue_size'] as int? ?? 1000,
      bannedCallsigns: (json['banned_callsigns'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : DateTime.now(),
    );
  }
}

/// Retry policy helper
class RetryPolicy {
  final int maxRetries;
  final Duration baseDelay;
  final Duration maxDelay;
  final double backoffMultiplier;
  final Duration patientModeTimeout;

  const RetryPolicy({
    this.maxRetries = 10,
    this.baseDelay = const Duration(seconds: 30),
    this.maxDelay = const Duration(hours: 1),
    this.backoffMultiplier = 2.0,
    this.patientModeTimeout = const Duration(days: 30),
  });

  factory RetryPolicy.fromSettings(TransferSettings settings) {
    return RetryPolicy(
      maxRetries: settings.maxRetries,
      baseDelay: settings.baseRetryDelay,
      maxDelay: settings.maxRetryDelay,
      backoffMultiplier: settings.retryBackoffMultiplier,
      patientModeTimeout: settings.patientModeTimeout,
    );
  }

  /// Calculate next retry delay with exponential backoff
  Duration getNextDelay(int retryCount) {
    final delayMs = baseDelay.inMilliseconds *
        _pow(backoffMultiplier, retryCount).toInt();
    final cappedMs = delayMs > maxDelay.inMilliseconds
        ? maxDelay.inMilliseconds
        : delayMs;
    return Duration(milliseconds: cappedMs);
  }

  /// Check if should retry
  bool shouldRetry(Transfer transfer) {
    return transfer.retryCount < maxRetries;
  }

  /// Check if transfer has exceeded patient mode timeout
  bool hasExceededPatientTimeout(Transfer transfer) {
    return DateTime.now().difference(transfer.createdAt) > patientModeTimeout;
  }

  /// Calculate next retry time
  DateTime getNextRetryTime(int retryCount) {
    return DateTime.now().add(getNextDelay(retryCount));
  }

  double _pow(double base, int exponent) {
    double result = 1.0;
    for (int i = 0; i < exponent; i++) {
      result *= base;
    }
    return result;
  }
}
