import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/tracker_proximity_track.dart';
import 'tracker_service.dart';
import '../../services/log_service.dart';
import '../../services/location_provider_service.dart';
import '../../services/devices_service.dart';
import '../../services/place_service.dart';
import '../../services/ble_foreground_service.dart';
import '../../services/power_aware_service.dart';

/// Service for detecting nearby devices (via Bluetooth) and places (via GPS).
/// Registers as a consumer of LocationProviderService to get GPS updates.
class ProximityDetectionService {
  static final ProximityDetectionService _instance =
      ProximityDetectionService._internal();
  factory ProximityDetectionService() => _instance;
  ProximityDetectionService._internal();

  TrackerService? _trackerService;
  Timer? _scanTimer;
  bool _isRunning = false;
  VoidCallback? _locationConsumerDispose;
  LockedPosition? _lastPosition;
  bool _scanInProgress = false;
  DateTime? _lastScanStartedAt;
  StreamSubscription<PowerMode>? _powerSubscription;
  bool _wasRunningBeforeDoze = false;

  /// Minimum interval between external trigger scans to avoid scan storms.
  static const _externalScanThrottle = Duration(seconds: 8);

  /// Active proximity sessions (id -> last detection time)
  final Map<String, DateTime> _activeSessions = {};
  static const _sessionTimeout = Duration(minutes: 2);

  /// Radius in meters for place detection (100m accounts for GPS error margin)
  static const double placeRadiusMeters = 100;

  bool get isRunning => _isRunning;

  /// Start the proximity detection service
  Future<void> start(TrackerService trackerService) async {
    LogService().log('ProximityDetectionService: start() called');

    if (_isRunning) {
      LogService().log('ProximityDetectionService: Already running');
      return;
    }

    try {
      _trackerService = trackerService;
      _isRunning = true;
      _scanInProgress = false;
      _lastScanStartedAt = null;

      // Register as a consumer of LocationProviderService to get GPS updates
      _locationConsumerDispose = await LocationProviderService().registerConsumer(
        intervalSeconds: 60,
        onPosition: (position) {
          _lastPosition = position;
          LogService().log(
            'ProximityDetectionService: Got position update: ${position.latitude}, ${position.longitude}',
          );
        },
      );

      // Run initial scan immediately
      unawaited(_requestScan(source: 'startup'));

      // On Android, use native foreground service for reliable background operation
      if (!kIsWeb && Platform.isAndroid) {
        BLEForegroundService().onBleScanPing = () {
          unawaited(
            _requestScan(
              source: 'foreground-service',
              minInterval: _externalScanThrottle,
            ),
          );
        };
        await BLEForegroundService().enableBleScanKeepAlive();
        LogService().log(
          'ProximityDetectionService: Started with native Android handler and GPS consumer',
        );
      } else {
        // Dart timer for other platforms (iOS, Linux, web)
        _scanTimer = Timer.periodic(const Duration(seconds: 60), (_) {
          unawaited(_requestScan(source: 'timer'));
        });
        LogService().log(
          'ProximityDetectionService: Started with 60-second timer and GPS consumer',
        );
      }
      // Listen for power mode changes (mobile battery saving)
      _powerSubscription?.cancel();
      _powerSubscription = PowerAwareService().onModeChanged.listen(_onPowerModeChanged);
    } catch (e, stack) {
      LogService().log('ProximityDetectionService: Failed to start: $e');
      LogService().log('ProximityDetectionService: Stack: $stack');
      _isRunning = false;
    }
  }

  /// Adjust behavior based on power mode.
  void _onPowerModeChanged(PowerMode mode) {
    if (!_isRunning && mode != PowerMode.foreground) return;

    switch (mode) {
      case PowerMode.foreground:
        // Resume if we were stopped by doze
        if (_wasRunningBeforeDoze && !_isRunning && _trackerService != null) {
          _wasRunningBeforeDoze = false;
          start(_trackerService!);
          LogService().log('ProximityDetectionService: foreground — resumed');
        }
        break;
      case PowerMode.background:
        // Reduce scan frequency to 120s on non-Android (Android uses native handler)
        if (_isRunning && _scanTimer != null) {
          _scanTimer?.cancel();
          _scanTimer = Timer.periodic(const Duration(seconds: 120), (_) {
            unawaited(_requestScan(source: 'timer-bg'));
          });
          LogService().log('ProximityDetectionService: background — scan interval 120s');
        }
        break;
      case PowerMode.doze:
        if (_isRunning) {
          _wasRunningBeforeDoze = true;
          stop();
          LogService().log('ProximityDetectionService: doze — stopped');
        }
        break;
    }
  }

  /// Stop the proximity detection service
  void stop() {
    if (!_isRunning) {
      return;
    }

    // Clean up native Android handler
    if (!kIsWeb && Platform.isAndroid) {
      BLEForegroundService().onBleScanPing = null;
      BLEForegroundService().disableBleScanKeepAlive();
    }

    _locationConsumerDispose?.call();
    _locationConsumerDispose = null;
    _scanTimer?.cancel();
    _scanTimer = null;
    _powerSubscription?.cancel();
    _powerSubscription = null;
    _isRunning = false;
    _activeSessions.clear();
    _lastPosition = null;
    _scanInProgress = false;
    _lastScanStartedAt = null;

    LogService().log('ProximityDetectionService: Stopped');
  }

  /// Public method to trigger a proximity scan from external code (e.g., BLE handler).
  /// This allows piggy-backing on the BLE scan cycle which is known to work.
  Future<void> triggerScan() async {
    await _requestScan(
      source: 'ble-callback',
      minInterval: _externalScanThrottle,
    );
  }

  Future<void> _requestScan({
    required String source,
    Duration minInterval = Duration.zero,
  }) async {
    if (!_isRunning || _trackerService == null) return;

    final now = DateTime.now();
    if (_scanInProgress) {
      return;
    }

    final lastScanStartedAt = _lastScanStartedAt;
    if (lastScanStartedAt != null &&
        now.difference(lastScanStartedAt) < minInterval) {
      return;
    }

    _scanInProgress = true;
    _lastScanStartedAt = now;
    try {
      if (source == 'ble-callback') {
        LogService().log(
          '[PROXIMITY] Scan triggered (background service callback)',
        );
      }
      await _scanNearbyDevices();
    } finally {
      _scanInProgress = false;
    }
  }

  /// Scan for nearby BLE devices (detected via bleRssi != null)
  Future<void> _scanNearbyDevices() async {
    if (!_isRunning || _trackerService == null) {
      LogService().log(
        'ProximityDetectionService: _scanNearbyDevices skipped (running=$_isRunning, tracker=${_trackerService != null})',
      );
      return;
    }

    try {
      final now = DateTime.now();
      final year = now.year;
      final week = getWeekNumber(now);
      final timestamp = now.toUtc().toIso8601String();

      // Get current position from our registered consumer or fallback to service's current position
      final currentPos =
          _lastPosition ?? LocationProviderService().currentPosition;
      final lat = currentPos?.latitude ?? 0.0;
      final lon = currentPos?.longitude ?? 0.0;

      LogService().log(
        'ProximityDetectionService: Scanning at GPS ($lat, $lon)',
      );

      if (lat == 0.0 && lon == 0.0) {
        LogService().log(
          'ProximityDetectionService: No GPS position available yet',
        );
      }

      // Get all devices from DevicesService
      final allDevices = DevicesService().getAllDevices();

      // Filter for devices CURRENTLY detected via BLE (bleRssi != null means active BLE detection)
      final nearbyDevices = allDevices
          .where((device) => device.bleRssi != null)
          .toList();

      LogService().log(
        '[PROXIMITY] Scan complete: ${nearbyDevices.length} nearby BLE devices found (of ${allDevices.length} total)',
      );

      for (final device in nearbyDevices) {
        await _recordProximity(
          id: device.callsign,
          type: ProximityTargetType.device,
          displayName: device.name.isNotEmpty ? device.name : device.callsign,
          lat: lat,
          lon: lon,
          timestamp: timestamp,
          year: year,
          week: week,
          callsign: device.callsign,
          npub: device.npub,
        );
      }

      // Also check for nearby places if we have a location
      if (lat != 0.0 || lon != 0.0) {
        LogService().log('[PROXIMITY] Checking places at ($lat, $lon)');
        await _checkNearbyPlaces(lat, lon);
      } else {
        LogService().log('[PROXIMITY] Skipping place check - no location');
      }

      // Clean up stale sessions
      _cleanupStaleSessions(now);
    } catch (e) {
      LogService().log('ProximityDetectionService: Error scanning: $e');
    }
  }

  /// Check for nearby places within the radius using PlaceService
  Future<void> _checkNearbyPlaces(double lat, double lon) async {
    // Use the reusable PlaceService function with disk caching
    final nearbyPlaces = await PlaceService.findPlacesWithinRadius(
      lat: lat,
      lon: lon,
      radiusMeters: placeRadiusMeters,
    );

    if (nearbyPlaces.isNotEmpty) {
      final placeNames = nearbyPlaces
          .map((p) => '"${p.name}" (${p.distanceMeters.toStringAsFixed(0)}m)')
          .join(', ');
      LogService().log(
        '[PROXIMITY] Found ${nearbyPlaces.length} places within ${placeRadiusMeters}m: $placeNames',
      );
    }

    if (nearbyPlaces.isEmpty) return;

    final now = DateTime.now();
    final year = now.year;
    final week = getWeekNumber(now);
    final timestamp = now.toUtc().toIso8601String();

    for (final place in nearbyPlaces) {
      final trackId = ProximityTrack.generatePlaceId(
        place.name,
        place.lat,
        place.lon,
      );
      await _recordProximity(
        id: trackId,
        type: ProximityTargetType.place,
        displayName: place.name,
        lat: lat,
        lon: lon,
        timestamp: timestamp,
        year: year,
        week: week,
        placeId: place.folderPath,
        placeSource: PlaceSource.internal,
        placeLat: place.lat,
        placeLon: place.lon,
      );
    }
  }

  /// Record a proximity detection
  Future<void> _recordProximity({
    required String id,
    required ProximityTargetType type,
    required String displayName,
    required double lat,
    required double lon,
    required String timestamp,
    required int year,
    required int week,
    String? npub,
    String? callsign,
    String? placeId,
    PlaceSource? placeSource,
    double? placeLat,
    double? placeLon,
  }) async {
    if (_trackerService == null) return;

    final now = DateTime.now();
    final lastSeen = _activeSessions[id];

    // Get or create track
    var track = await _trackerService!.getProximityTrack(
      id: id,
      year: year,
      week: week,
    );

    if (track == null) {
      // Create new track
      if (type == ProximityTargetType.device) {
        track = ProximityTrack.forDevice(
          callsign: callsign ?? id,
          displayName: displayName,
          npub: npub,
        );
      } else {
        track = ProximityTrack.forPlace(
          placeId: placeId ?? id,
          displayName: displayName,
          lat: placeLat ?? lat,
          lon: placeLon ?? lon,
          source: placeSource ?? PlaceSource.internal,
        );
      }
    }

    // Check if we should extend existing entry or create new one
    if (lastSeen != null && now.difference(lastSeen) < _sessionTimeout) {
      // Extend the most recent entry - update duration and handle GPS updates
      if (track.entries.isNotEmpty) {
        final lastEntry = track.entries.last;
        final startTime = lastEntry.timestampDateTime;
        final duration = now.difference(startTime).inSeconds;
        final lastHasLocation = lastEntry.lat != 0.0 || lastEntry.lon != 0.0;
        final currentHasLocation = lat != 0.0 || lon != 0.0;

        if (!lastHasLocation && currentHasLocation) {
          // Case 1: Entry had no GPS, now we have it → update coordinates
          final updatedEntry = lastEntry.copyWith(
            lat: lat,
            lon: lon,
            endedAt: timestamp,
            durationSeconds: duration,
          );
          final updatedEntries = List<ProximityEntry>.from(track.entries);
          updatedEntries[updatedEntries.length - 1] = updatedEntry;
          track = track.copyWith(entries: updatedEntries);
        } else if (lastHasLocation && currentHasLocation) {
          // Case 2: Both have location → check if we moved significantly
          final distance = _calculateDistance(
            lastEntry.lat,
            lastEntry.lon,
            lat,
            lon,
          );
          if (distance > 50) {
            // Moved >50m → create new entry (path segment)
            final newEntry = ProximityEntry(
              timestamp: timestamp,
              lat: lat,
              lon: lon,
              durationSeconds: 60,
            );
            track = track.copyWith(entries: [...track.entries, newEntry]);
          } else {
            // Same location → just extend duration
            final updatedEntry = lastEntry.copyWith(
              endedAt: timestamp,
              durationSeconds: duration,
            );
            final updatedEntries = List<ProximityEntry>.from(track.entries);
            updatedEntries[updatedEntries.length - 1] = updatedEntry;
            track = track.copyWith(entries: updatedEntries);
          }
        } else {
          // Case 3: No GPS before or now → just extend duration
          final updatedEntry = lastEntry.copyWith(
            endedAt: timestamp,
            durationSeconds: duration,
          );
          final updatedEntries = List<ProximityEntry>.from(track.entries);
          updatedEntries[updatedEntries.length - 1] = updatedEntry;
          track = track.copyWith(entries: updatedEntries);
        }
      }
    } else {
      // Create new entry - each detection counts as 60 seconds (scan interval)
      final entry = ProximityEntry(
        timestamp: timestamp,
        lat: lat,
        lon: lon,
        durationSeconds: 60,
      );

      track = track.copyWith(entries: [...track.entries, entry]);
    }

    // Update active session
    _activeSessions[id] = now;

    // Recalculate summary and save
    track = track.recalculateSummary();
    await _trackerService!.updateProximityTrack(track, year: year, week: week);
  }

  /// Clean up sessions that have timed out
  void _cleanupStaleSessions(DateTime now) {
    final staleIds = <String>[];
    for (final entry in _activeSessions.entries) {
      if (now.difference(entry.value) > _sessionTimeout) {
        staleIds.add(entry.key);
      }
    }
    for (final id in staleIds) {
      _activeSessions.remove(id);
    }
  }

  /// Calculate distance between two coordinates in meters (Haversine formula)
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000.0; // meters

    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return earthRadius * c;
  }

  double _toRadians(double degrees) => degrees * math.pi / 180;

  /// Record a device proximity detection (called from BLE service)
  Future<void> recordDeviceProximity({
    required String callsign,
    required String displayName,
    required double lat,
    required double lon,
    String? npub,
  }) async {
    if (!_isRunning || _trackerService == null) return;

    final now = DateTime.now();
    final year = now.year;
    final week = getWeekNumber(now);
    final timestamp = now.toUtc().toIso8601String();

    await _recordProximity(
      id: callsign,
      type: ProximityTargetType.device,
      displayName: displayName,
      lat: lat,
      lon: lon,
      timestamp: timestamp,
      year: year,
      week: week,
      callsign: callsign,
      npub: npub,
    );
  }
}
