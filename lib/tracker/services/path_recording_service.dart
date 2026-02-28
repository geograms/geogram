import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/tracker_models.dart';
import 'tracker_service.dart';
import '../../models/monitored_task.dart';
import '../../services/log_service.dart';
import '../../services/location_provider_service.dart';
import '../../util/task_monitor_helpers.dart';

/// Service for managing GPS path recording.
/// Uses [LocationProviderService] for GPS positioning.
class PathRecordingService extends ChangeNotifier {
  static final PathRecordingService _instance = PathRecordingService._internal();
  factory PathRecordingService() => _instance;
  PathRecordingService._internal();

  TrackerService? _trackerService;
  TrackerRecordingState? _recordingState;
  TrackerPath? _activePath;
  VoidCallback? _locationConsumerDispose;
  MonitoredIsolateHandle? _taskHandle;
  DateTime? _startTime;
  int _pointCount = 0;
  double _totalDistance = 0;
  LockedPosition? _lastPosition;
  LockedPosition? _lastObservedPosition;
  DateTime? _lastRecordedAt;
  DateTime? _lastObservedAt;
  Timer? _gpsWatchdog;
  LockedPosition? _stationaryAnchor;
  DateTime? _stationaryStartAt;
  bool _stoppingForInactivity = false;
  static const int _autoBaseIntervalSeconds = 5;

  // Getters
  bool get isRecording => _recordingState?.isRecording ?? false;
  bool get isPaused => _recordingState?.isPaused ?? false;
  bool get hasActiveRecording => _recordingState != null;
  String? get activePathId => _recordingState?.activePathId;
  int get pointCount => _pointCount;
  double get totalDistance => _totalDistance;
  Duration get elapsedTime => _startTime != null
      ? DateTime.now().difference(_startTime!)
      : Duration.zero;
  TrackerRecordingState? get recordingState => _recordingState;
  TrackerPath? get activePath => _activePath;
  LockedPosition? get lastPosition => _lastObservedPosition ?? _lastPosition;

  /// Initialize the service with a TrackerService
  void initialize(TrackerService trackerService) {
    _trackerService = trackerService;
  }

  /// Register with TaskMonitorService for visibility in task settings.
  void _registerTaskMonitor() {
    _taskHandle?.dispose();
    _taskHandle = MonitoredIsolateHandle(
      id: 'tracker.path_recording',
      name: 'Path Recording',
      description: 'GPS path recording in progress',
      serviceName: 'PathRecordingService',
      priority: TaskPriority.critical,
    );
  }

  /// Check and resume any active recording from crash recovery.
  ///
  /// Crash-tolerant: if points file is corrupt or missing, resumes
  /// with zero counters — new CSV append will create a fresh file.
  Future<bool> checkAndResumeRecording() async {
    if (_trackerService == null) return false;

    try {
      final state = await _trackerService!.getRecordingState();
      if (state != null) {
        _recordingState = state;
        _startTime = DateTime.parse(state.startedAt);
        _activePath = await _trackerService!.getPath(
          state.activePathId,
          year: state.activePathYear,
        );

        // Load existing points — tolerate corrupt/missing files
        try {
          final points = await _trackerService!.getPathPoints(
            state.activePathId,
            year: state.activePathYear,
          );
          if (points != null && points.points.isNotEmpty) {
            _totalDistance = points.calculateTotalDistance();
            _pointCount = points.points.length;
            final lastPoint = points.points.last;
            _lastPosition = LockedPosition(
              latitude: lastPoint.lat,
              longitude: lastPoint.lon,
              altitude: lastPoint.altitude ?? 0,
              accuracy: lastPoint.accuracy ?? 0,
              speed: lastPoint.speed ?? 0,
              heading: lastPoint.bearing ?? 0,
              timestamp: DateTime.parse(lastPoint.timestamp),
              source: 'stored',
            );
            _lastObservedPosition = _lastPosition;
            _lastRecordedAt = _lastPosition?.timestamp;
          } else {
            // No points or null — start fresh counters
            _pointCount = 0;
            _totalDistance = 0;
          }
        } catch (e) {
          // Points file corrupt — resume with fresh counters
          LogService().log('PathRecordingService: Points corrupt, resuming fresh: $e');
          _pointCount = 0;
          _totalDistance = 0;
        }

        // Register with task monitor
        _registerTaskMonitor();

        if (state.isRecording) {
          _taskHandle?.markRunning();
          await _startGPSUpdates(state.intervalSeconds);
        }

        notifyListeners();
        return true;
      }
    } catch (e) {
      LogService().log('PathRecordingService: Error resuming recording: $e');
    }
    return false;
  }

  /// Start a new path recording
  ///
  /// [notificationTitle] and [notificationText] are used for the Android
  /// foreground service notification.
  Future<TrackerPath?> startRecording({
    required TrackerPathType pathType,
    required String title,
    String? description,
    int intervalSeconds = 60,
    String? notificationTitle,
    String? notificationText,
  }) async {
    if (_trackerService == null) {
      LogService().log('PathRecordingService: TrackerService not initialized');
      return null;
    }

    if (_recordingState != null) {
      LogService().log('PathRecordingService: Recording already in progress');
      return null;
    }

    try {
      // Start location provider first to validate GPS availability
      final started = await _startGPSUpdates(
        intervalSeconds <= 0 ? _autoBaseIntervalSeconds : intervalSeconds,
        notificationTitle: notificationTitle,
        notificationText: notificationText,
      );
      if (!started) {
        LogService().log('PathRecordingService: Could not start GPS');
        return null;
      }
      final now = DateTime.now();
      final year = now.year;

      // Create tags with path type
      final tags = <String>[pathType.toTag()];
      final segments = [
        TrackerPathSegment(
          typeId: pathType.id,
          startedAt: now.toIso8601String(),
          startPointIndex: 0,
        ),
      ];

      // Create the path
      final path = await _trackerService!.createPath(
        title: title,
        description: description,
        intervalSeconds: intervalSeconds,
        tags: tags,
        segments: segments,
      );

      if (path == null) {
        _stopGPSUpdates();
        LogService().log('PathRecordingService: Failed to create path');
        return null;
      }

      // Save recording state
      _recordingState = TrackerRecordingState(
        activePathId: path.id,
        activePathYear: year,
        status: RecordingStatus.recording,
        intervalSeconds: intervalSeconds,
        startedAt: now.toIso8601String(),
        pointCount: 0,
      );

      await _trackerService!.saveRecordingState(_recordingState!);

      _startTime = now;
      _pointCount = 0;
      _totalDistance = 0;
      _lastPosition = null;
      _lastObservedPosition = null;
      _lastRecordedAt = null;
      _lastObservedAt = null;
      _stationaryAnchor = null;
      _stationaryStartAt = null;
      _stoppingForInactivity = false;
      _activePath = path;

      // Register with task monitor
      _registerTaskMonitor();
      _taskHandle?.markRunning();

      // GPS already started above
      notifyListeners();
      return path;
    } catch (e) {
      _stopGPSUpdates();
      LogService().log('PathRecordingService: Error starting recording: $e');
      return null;
    }
  }

  /// Change the active path type and record a segment boundary.
  Future<bool> updatePathType(TrackerPathType type) async {
    if (_trackerService == null || _recordingState == null) {
      return false;
    }
    final path = _activePath ??
        await _trackerService!.getPath(
          _recordingState!.activePathId,
          year: _recordingState!.activePathYear,
        );
    if (path == null) return false;

    final segments = List<TrackerPathSegment>.from(path.segments);
    final now = DateTime.now().toIso8601String();

    if (segments.isNotEmpty) {
      final lastIndex = segments.length - 1;
      final lastSegment = segments[lastIndex];
      segments[lastIndex] = lastSegment.copyWith(
        endedAt: now,
        endPointIndex: _pointCount,
      );
    }

    segments.add(
      TrackerPathSegment(
        typeId: type.id,
        startedAt: now,
        startPointIndex: _pointCount,
      ),
    );

    final updatedTags = _replaceTypeTag(path.tags, type);
    final updatedPath = path.copyWith(
      tags: updatedTags,
      segments: segments,
    );

    final saved = await _trackerService!.updatePath(
      updatedPath,
      year: _recordingState!.activePathYear,
    );
    if (saved != null) {
      _activePath = saved;
      notifyListeners();
      return true;
    }
    return false;
  }

  List<String> _replaceTypeTag(List<String> tags, TrackerPathType type) {
    final nextTags = tags.where((tag) => !tag.startsWith('type:')).toList();
    nextTags.insert(0, type.toTag());
    return nextTags;
  }

  /// Pause the current recording
  Future<bool> pauseRecording() async {
    if (_recordingState == null || !_recordingState!.isRecording) {
      return false;
    }

    try {
      _stopGPSUpdates();
      _taskHandle?.markIdle();

      _recordingState = _recordingState!.copyWith(
        status: RecordingStatus.paused,
        pausedAt: DateTime.now().toIso8601String(),
      );

      await _trackerService?.saveRecordingState(_recordingState!);

      // Update path status
      await _trackerService?.pausePath(
        _recordingState!.activePathId,
        year: _recordingState!.activePathYear,
      );

      notifyListeners();
      return true;
    } catch (e) {
      LogService().log('PathRecordingService: Error pausing recording: $e');
      return false;
    }
  }

  /// Resume a paused recording
  Future<bool> resumeRecording() async {
    if (_recordingState == null || !_recordingState!.isPaused) {
      return false;
    }

    try {
      _recordingState = _recordingState!.copyWith(
        status: RecordingStatus.recording,
        pausedAt: null,
      );

      await _trackerService?.saveRecordingState(_recordingState!);

      // Update path status
      await _trackerService?.resumePath(
        _recordingState!.activePathId,
        year: _recordingState!.activePathYear,
      );

      // Resume GPS updates
      final interval = _recordingState!.intervalSeconds <= 0
          ? _autoBaseIntervalSeconds
          : _recordingState!.intervalSeconds;
      await _startGPSUpdates(interval);
      _stationaryAnchor = _lastPosition;
      _stationaryStartAt = null;
      _stoppingForInactivity = false;
      _taskHandle?.markRunning();

      notifyListeners();
      return true;
    } catch (e) {
      LogService().log('PathRecordingService: Error resuming recording: $e');
      return false;
    }
  }

  /// Stop and complete the current recording
  Future<TrackerPath?> stopRecording() async {
    if (_recordingState == null) {
      return null;
    }

    try {
      _stopGPSUpdates();

      final recordingPath = await _trackerService?.getPath(
        _recordingState!.activePathId,
        year: _recordingState!.activePathYear,
      );
      if (recordingPath != null && recordingPath.segments.isNotEmpty) {
        final now = DateTime.now().toIso8601String();
        final segments = List<TrackerPathSegment>.from(recordingPath.segments);
        final lastIndex = segments.length - 1;
        final lastSegment = segments[lastIndex];
        if (lastSegment.endedAt == null) {
          segments[lastIndex] = lastSegment.copyWith(
            endedAt: now,
            endPointIndex: _pointCount,
          );
          await _trackerService?.updatePath(
            recordingPath.copyWith(segments: segments),
            year: _recordingState!.activePathYear,
          );
        }
      }

      final path = await _trackerService?.completePath(
        _recordingState!.activePathId,
        year: _recordingState!.activePathYear,
      );

      await _trackerService?.clearRecordingState();

      _taskHandle?.markIdle();
      _taskHandle?.dispose();
      _taskHandle = null;

      _recordingState = null;
      _startTime = null;
      _pointCount = 0;
      _totalDistance = 0;
      _lastPosition = null;
      _lastObservedPosition = null;
      _lastRecordedAt = null;
      _lastObservedAt = null;
      _stationaryAnchor = null;
      _stationaryStartAt = null;
      _stoppingForInactivity = false;
      _activePath = null;

      notifyListeners();
      return path;
    } catch (e) {
      LogService().log('PathRecordingService: Error stopping recording: $e');
      return null;
    }
  }

  /// Cancel and discard the current recording
  Future<bool> cancelRecording() async {
    if (_recordingState == null) {
      return false;
    }

    try {
      _stopGPSUpdates();

      await _trackerService?.deletePath(
        _recordingState!.activePathId,
        year: _recordingState!.activePathYear,
      );

      await _trackerService?.clearRecordingState();

      _taskHandle?.dispose();
      _taskHandle = null;

      _recordingState = null;
      _startTime = null;
      _pointCount = 0;
      _totalDistance = 0;
      _lastPosition = null;
      _lastObservedPosition = null;
      _lastRecordedAt = null;
      _lastObservedAt = null;
      _stationaryAnchor = null;
      _stationaryStartAt = null;
      _stoppingForInactivity = false;

      notifyListeners();
      return true;
    } catch (e) {
      LogService().log('PathRecordingService: Error cancelling recording: $e');
      return false;
    }
  }

  /// Start GPS position updates via LocationProviderService
  Future<bool> _startGPSUpdates(
    int intervalSeconds, {
    String? notificationTitle,
    String? notificationText,
  }) async {
    _stopGPSUpdates();

    try {
      _locationConsumerDispose = await LocationProviderService().registerConsumer(
        intervalSeconds: intervalSeconds,
        onPosition: _onPositionUpdate,
        notificationTitle: notificationTitle,
        notificationText: notificationText,
      );
      _startGpsWatchdog(intervalSeconds);
      return true;
    } catch (e) {
      LogService().log('PathRecordingService: Failed to start GPS: $e');
      return false;
    }
  }

  /// Stop GPS position updates
  void _stopGPSUpdates() {
    _locationConsumerDispose?.call();
    _locationConsumerDispose = null;
    _gpsWatchdog?.cancel();
    _gpsWatchdog = null;
  }

  /// Handle a position update from LocationProviderService
  void _onPositionUpdate(LockedPosition position) {
    if (_recordingState == null || !_recordingState!.isRecording) {
      return;
    }

    _lastObservedPosition = position;
    _lastObservedAt = position.timestamp;
    _checkForInactivityStop(position);

    final intervalSeconds = _resolveIntervalSeconds(position);
    final now = position.timestamp;
    if (_lastRecordedAt != null &&
        now.difference(_lastRecordedAt!).inSeconds < intervalSeconds) {
      return;
    }

    _lastRecordedAt = now;
    _addPoint(position);
  }

  void _checkForInactivityStop(LockedPosition position) {
    if (_stoppingForInactivity) {
      return;
    }
    if (_stationaryAnchor == null) {
      _stationaryAnchor = position;
      _stationaryStartAt = null;
      return;
    }

    final distance = _calculateDistance(
      _stationaryAnchor!.latitude,
      _stationaryAnchor!.longitude,
      position.latitude,
      position.longitude,
    );

    if (distance > 10) {
      _stationaryAnchor = position;
      _stationaryStartAt = null;
      return;
    }

    _stationaryStartAt ??= position.timestamp;
    final idleDuration = position.timestamp.difference(_stationaryStartAt!);
    if (idleDuration >= const Duration(hours: 1)) {
      _stoppingForInactivity = true;
      unawaited(_stopDueToInactivity());
    }
  }

  Future<void> _stopDueToInactivity() async {
    if (_trackerService == null || _recordingState == null) {
      _stoppingForInactivity = false;
      return;
    }

    final stopTime = _stationaryStartAt ?? DateTime.now();
    try {
      _stopGPSUpdates();
      await _trimPointsForInactivity(stopTime);
      await _trackerService!.completePathAt(
        _recordingState!.activePathId,
        stopTime,
        year: _recordingState!.activePathYear,
      );
      await _trackerService?.clearRecordingState();
    } catch (e) {
      LogService().log('PathRecordingService: Inactivity stop error: $e');
    } finally {
      _taskHandle?.markIdle();
      _taskHandle?.dispose();
      _taskHandle = null;
      _recordingState = null;
      _startTime = null;
      _pointCount = 0;
      _totalDistance = 0;
      _lastPosition = null;
      _lastObservedPosition = null;
      _lastRecordedAt = null;
      _lastObservedAt = null;
      _stationaryAnchor = null;
      _stationaryStartAt = null;
      _activePath = null;
      _stoppingForInactivity = false;
      notifyListeners();
    }
  }

  Future<void> _trimPointsForInactivity(DateTime stopTime) async {
    if (_trackerService == null || _recordingState == null) {
      return;
    }

    final points = await _trackerService!.getPathPoints(
      _recordingState!.activePathId,
      year: _recordingState!.activePathYear,
    );
    if (points == null || points.points.isEmpty) {
      return;
    }

    final kept = points.points.where((point) {
      final timestamp = DateTime.tryParse(point.timestamp);
      if (timestamp == null) return true;
      return timestamp.isBefore(stopTime);
    }).toList();

    final trimmed = kept.isNotEmpty ? kept : [points.points.first];
    final reindexed = _reindexPoints(trimmed);
    await _trackerService!.replacePathPoints(
      _recordingState!.activePathId,
      points.copyWith(points: reindexed),
      year: _recordingState!.activePathYear,
    );

    await _trimSegmentsForInactivity(reindexed.length, stopTime);
  }

  Future<void> _trimSegmentsForInactivity(
    int lastPointIndex,
    DateTime stopTime,
  ) async {
    if (_trackerService == null || _recordingState == null) return;
    final path = await _trackerService!.getPath(
      _recordingState!.activePathId,
      year: _recordingState!.activePathYear,
    );
    if (path == null || path.segments.isEmpty) return;

    final adjusted = <TrackerPathSegment>[];
    for (final segment in path.segments) {
      final startIndex = segment.startPointIndex ?? 0;
      if (startIndex > lastPointIndex) {
        break;
      }
      final endIndex = segment.endPointIndex != null
          ? segment.endPointIndex!.clamp(0, lastPointIndex)
          : lastPointIndex;
      adjusted.add(
        segment.copyWith(
          endPointIndex: endIndex,
          endedAt: segment.endedAt ?? stopTime.toIso8601String(),
        ),
      );
    }

    if (adjusted.isNotEmpty) {
      final updatedPath = path.copyWith(segments: adjusted);
      await _trackerService!.updatePath(
        updatedPath,
        year: _recordingState!.activePathYear,
      );
    }
  }

  List<TrackerPoint> _reindexPoints(List<TrackerPoint> points) {
    final updated = <TrackerPoint>[];
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      updated.add(
        TrackerPoint(
          index: i,
          timestamp: point.timestamp,
          lat: point.lat,
          lon: point.lon,
          altitude: point.altitude,
          accuracy: point.accuracy,
          speed: point.speed,
          bearing: point.bearing,
        ),
      );
    }
    return updated;
  }

  /// Add a point to the current path
  Future<void> _addPoint(LockedPosition position) async {
    if (_recordingState == null || _trackerService == null) return;

    try {
      final lastPosition = _lastPosition;
      final pointTime = position.timestamp;
      double? segmentSpeed;
      if (lastPosition != null) {
        final distance = _calculateDistance(
          lastPosition.latitude,
          lastPosition.longitude,
          position.latitude,
          position.longitude,
        );
        final millis = pointTime.difference(lastPosition.timestamp).inMilliseconds;
        if (millis > 0) {
          segmentSpeed = distance / (millis / 1000.0);
        }
      }

      final point = TrackerPoint(
        index: _pointCount,
        timestamp: position.timestamp.toIso8601String(),
        lat: position.latitude,
        lon: position.longitude,
        altitude: position.altitude,
        accuracy: position.accuracy,
        speed: position.speed,
        bearing: position.heading,
      );

      final success = await _trackerService!.addPathPoint(
        _recordingState!.activePathId,
        point,
        year: _recordingState!.activePathYear,
      );

      if (success) {
        await _updateSegmentMaxSpeed(segmentSpeed);
        // Calculate distance from last point
        if (_lastPosition != null) {
          final distance = _calculateDistance(
            _lastPosition!.latitude,
            _lastPosition!.longitude,
            position.latitude,
            position.longitude,
          );
          _totalDistance += distance;
        }

        _lastPosition = position;
        _lastObservedPosition = position;
        _pointCount++;

        // Update path metadata stats from in-memory counters (avoids re-reading CSV)
        await _trackerService!.updatePathStats(
          _recordingState!.activePathId,
          totalPoints: _pointCount,
          totalDistanceMeters: _totalDistance,
          year: _recordingState!.activePathYear,
        );

        // Update recording state
        _recordingState = _recordingState!.copyWith(
          lastPointTimestamp: position.timestamp.toIso8601String(),
          pointCount: _pointCount,
        );

        await _trackerService!.saveRecordingState(_recordingState!);

        notifyListeners();
      } else {
        _taskHandle?.markError('Failed to write point');
      }
    } catch (e) {
      _taskHandle?.markError(e);
      LogService().log('PathRecordingService: Error adding point: $e');
    }
  }

  Future<void> _updateSegmentMaxSpeed(double? segmentSpeed) async {
    // Filter out unreasonable speeds (GPS errors)
    // Cap at 120 m/s = 432 km/h (fastest trains)
    if (segmentSpeed == null || segmentSpeed <= 0 || segmentSpeed > 120.0) {
      return;
    }
    final activePath = _activePath ??
        await _trackerService?.getPath(
          _recordingState!.activePathId,
          year: _recordingState!.activePathYear,
        );
    if (activePath == null || activePath.segments.isEmpty) {
      return;
    }

    final segments = List<TrackerPathSegment>.from(activePath.segments);
    final lastIndex = segments.length - 1;
    final lastSegment = segments[lastIndex];
    final currentMax = lastSegment.maxSpeedMps ?? 0;
    if (segmentSpeed <= currentMax) {
      return;
    }

    segments[lastIndex] = lastSegment.copyWith(maxSpeedMps: segmentSpeed);
    final pathMax = activePath.maxSpeedMps == null
        ? segmentSpeed
        : math.max(activePath.maxSpeedMps!, segmentSpeed);

    final updatedPath = activePath.copyWith(
      segments: segments,
      maxSpeedMps: pathMax,
    );
    final saved = await _trackerService?.updatePath(
      updatedPath,
      year: _recordingState!.activePathYear,
    );
    if (saved != null) {
      _activePath = saved;
    }
  }

  /// Calculate distance between two points using Haversine formula
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0; // Earth radius in meters
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return R * c;
  }

  int _resolveIntervalSeconds(LockedPosition position) {
    if (_recordingState == null) return _autoBaseIntervalSeconds;
    final intervalSeconds = _recordingState!.intervalSeconds;
    if (intervalSeconds > 0) {
      return intervalSeconds;
    }

    final speed = position.speed ?? _lastPosition?.speed ?? 0;
    if (speed >= 7.0) {
      return 5;
    }
    if (speed >= 2.5) {
      return 10;
    }
    return 20;
  }

  void _startGpsWatchdog(int intervalSeconds) {
    _gpsWatchdog?.cancel();
    final checkSeconds = intervalSeconds < 10 ? 10 : intervalSeconds;
    _gpsWatchdog = Timer.periodic(
      Duration(seconds: checkSeconds),
      (_) {
        if (_recordingState == null || !_recordingState!.isRecording) {
          return;
        }
        final lastSeen = _lastObservedAt ?? _lastRecordedAt;
        if (lastSeen == null) {
          unawaited(_forcePositionUpdate());
          return;
        }
        final staleSeconds = DateTime.now().difference(lastSeen).inSeconds;
        if (staleSeconds >= intervalSeconds * 3) {
          unawaited(_forcePositionUpdate());
        }
      },
    );
  }

  Future<void> _forcePositionUpdate() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        LogService().log('PathRecordingService: GPS disabled while recording');
        return;
      }
      final position =
          await LocationProviderService().requestImmediatePosition();
      if (position != null) {
        _onPositionUpdate(position);
      } else {
        LogService().log('PathRecordingService: No GPS fix yet, retrying');
      }
    } catch (e) {
      LogService().log('PathRecordingService: GPS watchdog error: $e');
    }
  }

  /// Clean up resources
  @override
  void dispose() {
    _stopGPSUpdates();
    _taskHandle?.dispose();
    _taskHandle = null;
    super.dispose();
  }
}
