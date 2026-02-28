import 'dart:math' as math;

import 'tracker_metadata.dart';
import 'tracker_visibility.dart';

/// Status of a GPS path recording
enum TrackerPathStatus {
  recording,
  paused,
  completed,
  cancelled,
}

/// Bounding box for a path
class PathBounds {
  final double minLat;
  final double maxLat;
  final double minLon;
  final double maxLon;

  const PathBounds({
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
  });

  Map<String, dynamic> toJson() => {
        'min_lat': minLat,
        'max_lat': maxLat,
        'min_lon': minLon,
        'max_lon': maxLon,
      };

  factory PathBounds.fromJson(Map<String, dynamic> json) {
    return PathBounds(
      minLat: (json['min_lat'] as num).toDouble(),
      maxLat: (json['max_lat'] as num).toDouble(),
      minLon: (json['min_lon'] as num).toDouble(),
      maxLon: (json['max_lon'] as num).toDouble(),
    );
  }

  /// Calculate bounds from a list of points
  factory PathBounds.fromPoints(List<TrackerPoint> points) {
    if (points.isEmpty) {
      return const PathBounds(minLat: 0, maxLat: 0, minLon: 0, maxLon: 0);
    }

    double minLat = points.first.lat;
    double maxLat = points.first.lat;
    double minLon = points.first.lon;
    double maxLon = points.first.lon;

    for (final point in points) {
      if (point.lat < minLat) minLat = point.lat;
      if (point.lat > maxLat) maxLat = point.lat;
      if (point.lon < minLon) minLon = point.lon;
      if (point.lon > maxLon) maxLon = point.lon;
    }

    return PathBounds(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );
  }
}

/// Transport segment within a path recording.
class TrackerPathSegment {
  final String typeId;
  final String startedAt;
  final String? endedAt;
  final int? startPointIndex;
  final int? endPointIndex;
  final double? maxSpeedMps;

  const TrackerPathSegment({
    required this.typeId,
    required this.startedAt,
    this.endedAt,
    this.startPointIndex,
    this.endPointIndex,
    this.maxSpeedMps,
  });

  Map<String, dynamic> toJson() => {
        'type_id': typeId,
        'started_at': startedAt,
        if (endedAt != null) 'ended_at': endedAt,
        if (startPointIndex != null) 'start_point_index': startPointIndex,
        if (endPointIndex != null) 'end_point_index': endPointIndex,
        if (maxSpeedMps != null) 'max_speed_mps': maxSpeedMps,
      };

  factory TrackerPathSegment.fromJson(Map<String, dynamic> json) {
    return TrackerPathSegment(
      typeId: json['type_id'] as String,
      startedAt: json['started_at'] as String,
      endedAt: json['ended_at'] as String?,
      startPointIndex: json['start_point_index'] as int?,
      endPointIndex: json['end_point_index'] as int?,
      maxSpeedMps: (json['max_speed_mps'] as num?)?.toDouble(),
    );
  }

  TrackerPathSegment copyWith({
    String? typeId,
    String? startedAt,
    String? endedAt,
    int? startPointIndex,
    int? endPointIndex,
    double? maxSpeedMps,
  }) {
    return TrackerPathSegment(
      typeId: typeId ?? this.typeId,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      startPointIndex: startPointIndex ?? this.startPointIndex,
      endPointIndex: endPointIndex ?? this.endPointIndex,
      maxSpeedMps: maxSpeedMps ?? this.maxSpeedMps,
    );
  }
}

/// A GPS path recording
class TrackerPath {
  final String id;
  final String? title;
  final String? description;
  final String startedAt;
  final String? endedAt;
  final TrackerPathStatus status;
  final int intervalSeconds;
  final int totalPoints;
  final double totalDistanceMeters;
  final double? elevationGainMeters;
  final double? elevationLossMeters;
  final double? avgSpeedMps;
  final double? maxSpeedMps;
  final PathBounds? bounds;
  final List<String> tags;
  final List<TrackerPathSegment> segments;
  final String ownerCallsign;
  final TrackerVisibility? visibility;
  final TrackerNostrMetadata? metadata;
  final String? startCity;
  final String? endCity;

  const TrackerPath({
    required this.id,
    this.title,
    this.description,
    required this.startedAt,
    this.endedAt,
    this.status = TrackerPathStatus.recording,
    this.intervalSeconds = 60,
    this.totalPoints = 0,
    this.totalDistanceMeters = 0.0,
    this.elevationGainMeters,
    this.elevationLossMeters,
    this.avgSpeedMps,
    this.maxSpeedMps,
    this.bounds,
    this.tags = const [],
    this.segments = const [],
    required this.ownerCallsign,
    this.visibility,
    this.metadata,
    this.startCity,
    this.endCity,
  });

  /// Parse started timestamp to DateTime
  DateTime get startedAtDateTime {
    try {
      return DateTime.parse(startedAt);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Parse ended timestamp to DateTime
  DateTime? get endedAtDateTime {
    if (endedAt == null) return null;
    try {
      return DateTime.parse(endedAt!);
    } catch (e) {
      return null;
    }
  }

  /// Duration in seconds
  int? get durationSeconds {
    final end = endedAtDateTime;
    if (end == null) return null;
    return end.difference(startedAtDateTime).inSeconds;
  }

  /// Duration formatted as HH:MM:SS
  String? get durationFormatted {
    final seconds = durationSeconds;
    if (seconds == null) return null;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  /// Distance in kilometers
  double get totalDistanceKm => totalDistanceMeters / 1000.0;

  /// Get user-defined tags (excludes system tags like type:*)
  List<String> get userTags => tags.where((t) => !t.contains(':')).toList();

  /// Add a user tag (returns new instance with tag added)
  TrackerPath addUserTag(String tag) {
    final normalized = tag.toLowerCase().trim().replaceAll('#', '');
    if (normalized.isEmpty || tags.contains(normalized)) return this;
    return copyWith(tags: [...tags, normalized]);
  }

  /// Remove a user tag (returns new instance with tag removed)
  TrackerPath removeUserTag(String tag) {
    return copyWith(tags: tags.where((t) => t != tag).toList());
  }

  /// Set all user tags (preserves system tags like type:*)
  TrackerPath withUserTags(List<String> newUserTags) {
    final systemTags = tags.where((t) => t.contains(':')).toList();
    final normalizedUserTags = newUserTags
        .map((t) => t.toLowerCase().trim().replaceAll('#', ''))
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList();
    return copyWith(tags: [...systemTags, ...normalizedUserTags]);
  }

  /// Check if path matches search query
  bool matchesSearch(String query) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return true;

    // Check if searching for tag with # prefix
    // #train matches tags starting with "train" (e.g., "train", "training")
    if (q.startsWith('#')) {
      final tagQuery = q.substring(1);
      if (tagQuery.isEmpty) return userTags.isNotEmpty;
      return userTags.any((t) => t.startsWith(tagQuery));
    }

    // Search in title, description, and tags
    return (title?.toLowerCase().contains(q) ?? false) ||
        (description?.toLowerCase().contains(q) ?? false) ||
        userTags.any((t) => t.contains(q));
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        'started_at': startedAt,
        if (endedAt != null) 'ended_at': endedAt,
        'status': status.name,
        'interval_seconds': intervalSeconds,
        'total_points': totalPoints,
        'total_distance_meters': totalDistanceMeters,
        if (elevationGainMeters != null)
          'elevation_gain_meters': elevationGainMeters,
        if (elevationLossMeters != null)
          'elevation_loss_meters': elevationLossMeters,
        if (avgSpeedMps != null) 'avg_speed_mps': avgSpeedMps,
        if (maxSpeedMps != null) 'max_speed_mps': maxSpeedMps,
        if (bounds != null) 'bounds': bounds!.toJson(),
        if (tags.isNotEmpty) 'tags': tags,
        if (segments.isNotEmpty)
          'segments': segments.map((segment) => segment.toJson()).toList(),
        'owner_callsign': ownerCallsign,
        if (visibility != null) 'visibility': visibility!.toJson(),
        if (metadata != null) 'metadata': metadata!.toJson(),
        if (startCity != null) 'start_city': startCity,
        if (endCity != null) 'end_city': endCity,
      };

  factory TrackerPath.fromJson(Map<String, dynamic> json) {
    final statusStr = json['status'] as String? ?? 'recording';
    final status = TrackerPathStatus.values.firstWhere(
      (s) => s.name == statusStr,
      orElse: () => TrackerPathStatus.recording,
    );

    return TrackerPath(
      id: json['id'] as String,
      title: json['title'] as String?,
      description: json['description'] as String?,
      startedAt: json['started_at'] as String,
      endedAt: json['ended_at'] as String?,
      status: status,
      intervalSeconds: json['interval_seconds'] as int? ?? 60,
      totalPoints: json['total_points'] as int? ?? 0,
      totalDistanceMeters:
          (json['total_distance_meters'] as num?)?.toDouble() ?? 0.0,
      elevationGainMeters:
          (json['elevation_gain_meters'] as num?)?.toDouble(),
      elevationLossMeters:
          (json['elevation_loss_meters'] as num?)?.toDouble(),
      avgSpeedMps: (json['avg_speed_mps'] as num?)?.toDouble(),
      maxSpeedMps: (json['max_speed_mps'] as num?)?.toDouble(),
      bounds: json['bounds'] != null
          ? PathBounds.fromJson(json['bounds'] as Map<String, dynamic>)
          : null,
      tags: (json['tags'] as List<dynamic>?)
              ?.map((t) => t as String)
              .toList() ??
          const [],
      segments: (json['segments'] as List<dynamic>?)
              ?.map((segment) =>
                  TrackerPathSegment.fromJson(segment as Map<String, dynamic>))
              .toList() ??
          const [],
      ownerCallsign: json['owner_callsign'] as String,
      visibility: json['visibility'] != null
          ? TrackerVisibility.fromJson(
              json['visibility'] as Map<String, dynamic>)
          : null,
      metadata: json['metadata'] != null
          ? TrackerNostrMetadata.fromJson(
              json['metadata'] as Map<String, dynamic>)
          : null,
      startCity: json['start_city'] as String?,
      endCity: json['end_city'] as String?,
    );
  }

  TrackerPath copyWith({
    String? id,
    String? title,
    String? description,
    String? startedAt,
    String? endedAt,
    TrackerPathStatus? status,
    int? intervalSeconds,
    int? totalPoints,
    double? totalDistanceMeters,
    double? elevationGainMeters,
    double? elevationLossMeters,
    double? avgSpeedMps,
    double? maxSpeedMps,
    PathBounds? bounds,
    List<String>? tags,
    List<TrackerPathSegment>? segments,
    String? ownerCallsign,
    TrackerVisibility? visibility,
    TrackerNostrMetadata? metadata,
    String? startCity,
    String? endCity,
  }) {
    return TrackerPath(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      status: status ?? this.status,
      intervalSeconds: intervalSeconds ?? this.intervalSeconds,
      totalPoints: totalPoints ?? this.totalPoints,
      totalDistanceMeters: totalDistanceMeters ?? this.totalDistanceMeters,
      elevationGainMeters: elevationGainMeters ?? this.elevationGainMeters,
      elevationLossMeters: elevationLossMeters ?? this.elevationLossMeters,
      avgSpeedMps: avgSpeedMps ?? this.avgSpeedMps,
      maxSpeedMps: maxSpeedMps ?? this.maxSpeedMps,
      bounds: bounds ?? this.bounds,
      tags: tags ?? this.tags,
      segments: segments ?? this.segments,
      ownerCallsign: ownerCallsign ?? this.ownerCallsign,
      visibility: visibility ?? this.visibility,
      metadata: metadata ?? this.metadata,
      startCity: startCity ?? this.startCity,
      endCity: endCity ?? this.endCity,
    );
  }
}

/// A single GPS point in a path
class TrackerPoint {
  final int index;
  final String timestamp;
  final double lat;
  final double lon;
  final double? altitude;
  final double? accuracy;
  final double? speed;
  final double? bearing;

  const TrackerPoint({
    required this.index,
    required this.timestamp,
    required this.lat,
    required this.lon,
    this.altitude,
    this.accuracy,
    this.speed,
    this.bearing,
  });

  DateTime get timestampDateTime {
    try {
      return DateTime.parse(timestamp);
    } catch (e) {
      return DateTime.now();
    }
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'timestamp': timestamp,
        'lat': lat,
        'lon': lon,
        if (altitude != null) 'altitude': altitude,
        if (accuracy != null) 'accuracy': accuracy,
        if (speed != null) 'speed': speed,
        if (bearing != null) 'bearing': bearing,
      };

  factory TrackerPoint.fromJson(Map<String, dynamic> json) {
    return TrackerPoint(
      index: json['index'] as int,
      timestamp: json['timestamp'] as String,
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      speed: (json['speed'] as num?)?.toDouble(),
      bearing: (json['bearing'] as num?)?.toDouble(),
    );
  }

  /// Serialize to a single CSV line (no trailing newline).
  /// Format: index,timestamp,lat,lon,altitude,accuracy,speed,bearing
  String toCsvLine() {
    return '$index,$timestamp,$lat,$lon'
        ',${altitude ?? ''}'
        ',${accuracy ?? ''}'
        ',${speed ?? ''}'
        ',${bearing ?? ''}';
  }

  /// Parse a single CSV line. Returns null on parse failure.
  static TrackerPoint? fromCsvLine(String line) {
    try {
      final parts = line.split(',');
      if (parts.length < 4) return null;
      return TrackerPoint(
        index: int.parse(parts[0]),
        timestamp: parts[1],
        lat: double.parse(parts[2]),
        lon: double.parse(parts[3]),
        altitude: parts.length > 4 && parts[4].isNotEmpty
            ? double.parse(parts[4])
            : null,
        accuracy: parts.length > 5 && parts[5].isNotEmpty
            ? double.parse(parts[5])
            : null,
        speed: parts.length > 6 && parts[6].isNotEmpty
            ? double.parse(parts[6])
            : null,
        bearing: parts.length > 7 && parts[7].isNotEmpty
            ? double.parse(parts[7])
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Container for path points (stored in points.json)
class TrackerPathPoints {
  final String pathId;
  final List<TrackerPoint> points;

  const TrackerPathPoints({
    required this.pathId,
    this.points = const [],
  });

  Map<String, dynamic> toJson() => {
        'path_id': pathId,
        'points': points.map((p) => p.toJson()).toList(),
      };

  factory TrackerPathPoints.fromJson(Map<String, dynamic> json) {
    return TrackerPathPoints(
      pathId: json['path_id'] as String,
      points: (json['points'] as List<dynamic>?)
              ?.map((p) => TrackerPoint.fromJson(p as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  TrackerPathPoints copyWith({
    String? pathId,
    List<TrackerPoint>? points,
  }) {
    return TrackerPathPoints(
      pathId: pathId ?? this.pathId,
      points: points ?? this.points,
    );
  }

  /// Add a new point
  TrackerPathPoints addPoint(TrackerPoint point) {
    return copyWith(points: [...points, point]);
  }

  /// Parse from CSV content. Silently skips corrupt lines.
  factory TrackerPathPoints.fromCsv(String pathId, String csvContent) {
    final lines = csvContent.split('\n');
    final points = <TrackerPoint>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final point = TrackerPoint.fromCsvLine(line.trim());
      if (point != null) points.add(point);
    }
    return TrackerPathPoints(pathId: pathId, points: points);
  }

  /// Serialize all points to CSV format.
  String toCsv() {
    return points.map((p) => p.toCsvLine()).join('\n');
  }

  /// Calculate total distance using Haversine formula
  double calculateTotalDistance() {
    if (points.length < 2) return 0.0;

    double total = 0.0;
    for (int i = 1; i < points.length; i++) {
      total += _haversineDistance(
        points[i - 1].lat,
        points[i - 1].lon,
        points[i].lat,
        points[i].lon,
      );
    }
    return total;
  }

  /// Haversine distance calculation between two points (returns meters)
  static double _haversineDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusMeters = 6371000.0;
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180;
}
