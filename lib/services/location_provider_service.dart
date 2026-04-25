import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/monitored_task.dart';
import '../util/geolocation_utils.dart';
import '../util/event_bus.dart';
import '../util/task_monitor_helpers.dart';
import 'log_service.dart';
import 'power_aware_service.dart';

/// Represents a locked GPS position with metadata
class LockedPosition {
  final double latitude;
  final double longitude;
  final double altitude;
  final double accuracy;
  final double speed;
  final double heading;
  final DateTime timestamp;
  final String source; // 'gps', 'network', 'ip'

  const LockedPosition({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.accuracy,
    required this.speed,
    required this.heading,
    required this.timestamp,
    required this.source,
  });

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'altitude': altitude,
        'accuracy': accuracy,
        'speed': speed,
        'heading': heading,
        'timestamp': timestamp.toIso8601String(),
        'source': source,
      };

  factory LockedPosition.fromJson(Map<String, dynamic> json) => LockedPosition(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        altitude: (json['altitude'] as num?)?.toDouble() ?? 0,
        accuracy: (json['accuracy'] as num?)?.toDouble() ?? 0,
        speed: (json['speed'] as num?)?.toDouble() ?? 0,
        heading: (json['heading'] as num?)?.toDouble() ?? 0,
        timestamp: DateTime.parse(json['timestamp'] as String),
        source: json['source'] as String? ?? 'unknown',
      );

  factory LockedPosition.fromGeolocator(Position pos, {String source = 'gps'}) =>
      LockedPosition(
        latitude: pos.latitude,
        longitude: pos.longitude,
        altitude: pos.altitude,
        accuracy: pos.accuracy,
        speed: pos.speed,
        heading: pos.heading,
        timestamp: pos.timestamp,
        source: source,
      );

  factory LockedPosition.fromGeolocationResult(GeolocationResult result) =>
      LockedPosition(
        latitude: result.latitude,
        longitude: result.longitude,
        altitude: 0,
        accuracy: result.accuracy ?? 0,
        speed: 0,
        heading: 0,
        timestamp: DateTime.now(),
        source: result.source,
      );

  /// Check if position is still fresh (within maxAge)
  bool isFresh({Duration maxAge = const Duration(minutes: 5)}) {
    return DateTime.now().difference(timestamp) < maxAge;
  }

  /// Check if position is high accuracy (< 50m)
  bool get isHighAccuracy => accuracy < 50;

  @override
  String toString() =>
      'LockedPosition($latitude, $longitude, accuracy: ${accuracy.toStringAsFixed(1)}m, source: $source)';
}

/// Singleton service that maintains a GPS lock and provides positions to consumers.
///
/// Other apps/features can:
/// 1. Query [currentPosition] to get the latest locked position
/// 2. Listen to [positionStream] for real-time updates
/// 3. Read from shared file for cross-app access (Android)
///
/// Usage:
/// ```dart
/// final service = LocationProviderService();
/// await service.start(intervalSeconds: 30);
///
/// // Get current position
/// final pos = service.currentPosition;
/// if (pos != null && pos.isFresh()) {
///   print('Using locked position: ${pos.latitude}, ${pos.longitude}');
/// }
///
/// // Or listen to updates
/// service.positionStream.listen((pos) {
///   print('New position: $pos');
/// });
/// ```
class LocationProviderService extends ChangeNotifier {
  static final LocationProviderService _instance =
      LocationProviderService._internal();
  factory LocationProviderService() => _instance;
  LocationProviderService._internal();

  StreamSubscription<Position>? _positionSubscription;
  MonitoredAsyncPeriodicTimer? _periodicTimer;
  LockedPosition? _currentPosition;
  DateTime? _lastUpdateTime;
  bool _isRunning = false;
  int _consumerCount = 0;
  int _highFidelityCount = 0;
  String? _sharedFilePath;
  int _currentIntervalSeconds = 60;
  StreamSubscription<PowerMode>? _powerSubscription;
  PowerMode _currentPowerMode = PowerMode.foreground;

  final _positionController = StreamController<LockedPosition>.broadcast();

  // ============ Public Getters ============

  /// Whether the service is actively acquiring GPS positions
  bool get isRunning => _isRunning;

  /// The current locked position (may be null if no lock acquired yet)
  LockedPosition? get currentPosition => _currentPosition;

  /// Stream of position updates for real-time consumers
  Stream<LockedPosition> get positionStream => _positionController.stream;

  /// Whether we have a valid, fresh position
  bool get hasValidPosition =>
      _currentPosition != null && _currentPosition!.isFresh();

  /// Number of active consumers using this service
  int get consumerCount => _consumerCount;

  // ============ Consumer Management ============

  /// Register as a consumer of location updates.
  /// The service stays running as long as there's at least one consumer.
  /// Returns a dispose function to call when done.
  ///
  /// [highFidelity] keeps distanceFilter=0 for this consumer (e.g., path recording).
  /// [notificationTitle] and [notificationText] are used for the Android
  /// foreground service notification.
  Future<VoidCallback> registerConsumer({
    int intervalSeconds = 60,
    void Function(LockedPosition)? onPosition,
    String? notificationTitle,
    String? notificationText,
    bool highFidelity = false,
  }) async {
    _consumerCount++;
    if (highFidelity) _highFidelityCount++;
    LogService().log(
        'LocationProviderService: Consumer registered (count: $_consumerCount, highFidelity: $_highFidelityCount)');

    StreamSubscription<LockedPosition>? subscription;
    if (onPosition != null) {
      subscription = positionStream.listen(onPosition);
    }

    // Start if not already running
    if (!_isRunning) {
      final started = await start(
        intervalSeconds: intervalSeconds,
        notificationTitle: notificationTitle,
        notificationText: notificationText,
      );
      if (!started) {
        // Clean up and throw if start failed
        subscription?.cancel();
        _consumerCount--;
        throw Exception('LocationProviderService: Failed to start - permission denied or services disabled');
      }
    }

    // Return dispose function
    return () {
      subscription?.cancel();
      _consumerCount--;
      if (highFidelity) _highFidelityCount--;
      LogService().log(
          'LocationProviderService: Consumer unregistered (count: $_consumerCount, highFidelity: $_highFidelityCount)');

      // Stop if no more consumers
      if (_consumerCount <= 0) {
        _consumerCount = 0;
        _highFidelityCount = 0;
        stop();
      }
    };
  }

  // ============ Service Control ============

  String? _notificationTitle;
  String? _notificationText;

  /// Start the location provider service.
  /// Set [sharedFilePath] to enable cross-app position sharing via file.
  /// Set [notificationTitle] and [notificationText] for Android foreground notification.
  Future<bool> start({
    int intervalSeconds = 60,
    String? sharedFilePath,
    String? notificationTitle,
    String? notificationText,
  }) async {
    if (_isRunning) {
      LogService().log('LocationProviderService: Already running');
      return true;
    }

    // Only check GPS permissions on mobile platforms
    // Desktop/Web will use fallbacks (IP geolocation, profile location)
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

    if (isMobile) {
      // Check GPS permission
      final permission = await GeolocationUtils.checkPermission();
      LogService().log('LocationProviderService: Current permission: $permission');

      if (permission == LocationPermission.denied) {
        // Permission not yet granted, request it
        final requested = await GeolocationUtils.requestPermission();
        LogService().log('LocationProviderService: Requested permission result: $requested');
        if (requested == LocationPermission.denied ||
            requested == LocationPermission.deniedForever) {
          LogService().log('LocationProviderService: GPS permission denied after request');
          return false;
        }
      } else if (permission == LocationPermission.deniedForever) {
        // Permission permanently denied, user must enable in settings
        LogService().log('LocationProviderService: GPS permission permanently denied');
        return false;
      }
      // permission is whileInUse or always - proceed

      // Check if GPS is enabled
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      LogService().log('LocationProviderService: Location service enabled: $serviceEnabled');
      if (!serviceEnabled) {
        LogService().log('LocationProviderService: Location services disabled');
        return false;
      }
    }

    _sharedFilePath = sharedFilePath;
    _notificationTitle = notificationTitle;
    _notificationText = notificationText;
    _currentIntervalSeconds = intervalSeconds;
    _isRunning = true;

    await _startPositionUpdates(intervalSeconds);

    // Listen for power mode changes (mobile battery saving)
    _powerSubscription ??= PowerAwareService().onModeChanged.listen(_onPowerModeChanged);

    LogService().log(
        'LocationProviderService: Started with ${intervalSeconds}s interval');
    notifyListeners();
    return true;
  }

  /// Stop the location provider service
  void stop() {
    if (!_isRunning) return;

    _stopPositionUpdates();
    _powerSubscription?.cancel();
    _powerSubscription = null;
    _isRunning = false;
    _currentPowerMode = PowerMode.foreground;
    LogService().log('LocationProviderService: Stopped');
    notifyListeners();
  }

  /// Force an immediate position update
  Future<LockedPosition?> requestImmediatePosition() async {
    if (!_isRunning) {
      // One-shot position request
      try {
        final result = await GeolocationUtils.detectViaGPS(requestPermission: true);
        if (result != null) {
          return LockedPosition.fromGeolocationResult(result);
        }
      } catch (e) {
        LogService()
            .log('LocationProviderService: Immediate position error: $e');
      }
      return null;
    }

    // If already have a valid position, return it immediately
    if (_currentPosition != null && _currentPosition!.isFresh()) {
      return _currentPosition;
    }

    // On mobile with position stream running, wait for stream to deliver position
    // rather than making a separate one-shot request (which fails without internet/A-GPS)
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    if (isMobile && _positionSubscription != null) {
      // Wait up to 5 seconds for stream to deliver a position
      // The stream is already listening for GPS, so this just waits for next update
      final completer = Completer<LockedPosition?>();
      StreamSubscription<LockedPosition>? sub;
      Timer? timeout;

      sub = positionStream.listen((pos) {
        if (!completer.isCompleted) {
          timeout?.cancel();
          sub?.cancel();
          completer.complete(pos);
        }
      });

      timeout = Timer(const Duration(seconds: 5), () {
        if (!completer.isCompleted) {
          sub?.cancel();
          // Return current position even if stale, or null
          completer.complete(_currentPosition);
        }
      });

      return completer.future;
    }

    // For non-mobile (desktop/web with timer), trigger an update
    await _capturePosition();
    return _currentPosition;
  }

  // ============ Cross-App Access ============

  /// Read the shared position file (for external apps)
  static Future<LockedPosition?> readSharedPosition(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return LockedPosition.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  /// Write current position to shared file
  Future<void> _writeSharedPosition(LockedPosition position) async {
    if (_sharedFilePath == null) return;

    try {
      final file = File(_sharedFilePath!);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(position.toJson()));
    } catch (e) {
      LogService().log('LocationProviderService: Error writing shared file: $e');
    }
  }

  // ============ Internal Methods ============

  Future<void> _startPositionUpdates(int intervalSeconds) async {
    _stopPositionUpdates();

    if (kIsWeb) {
      // Web: Timer-based
      _periodicTimer = MonitoredAsyncPeriodicTimer(
        id: 'location_provider.gps',
        name: 'GPS Updates',
        description: 'Periodic GPS location capture (web)',
        serviceName: 'LocationProviderService',
        interval: Duration(seconds: intervalSeconds),
        priority: TaskPriority.low,
        callback: (_) async => await _capturePosition(),
      );
      _capturePosition();
    } else if (Platform.isAndroid || Platform.isIOS) {
      // Mobile: Position stream with foreground service
      late LocationSettings locationSettings;

      // Use distanceFilter=0 only for high-fidelity consumers (path recording),
      // otherwise 10m to avoid unnecessary wakeups when stationary.
      // Power-aware: background uses 50m + medium accuracy, doze stops entirely.
      // High-fidelity uses bestForNavigation to force pure GPS — LocationAccuracy.high
      // on Android is fused location (GPS + Wi-Fi + cell), which produces
      // cell-tower-grade fixes during cold-start or weak signal.
      final int distanceFilter;
      final LocationAccuracy accuracy;
      final bool wakeLock;
      if (_highFidelityCount > 0) {
        distanceFilter = 0;
        accuracy = LocationAccuracy.bestForNavigation;
        wakeLock = true;
      } else if (_currentPowerMode == PowerMode.background) {
        distanceFilter = 50;
        accuracy = LocationAccuracy.medium;
        wakeLock = false;
      } else {
        distanceFilter = 10;
        accuracy = LocationAccuracy.high;
        wakeLock = true;
      }

      if (Platform.isAndroid) {
        locationSettings = AndroidSettings(
          accuracy: accuracy,
          distanceFilter: distanceFilter,
          intervalDuration: Duration(seconds: intervalSeconds),
          foregroundNotificationConfig: ForegroundNotificationConfig(
            notificationTitle: _notificationTitle ?? 'Location Active',
            notificationText: _notificationText ?? 'Providing GPS position',
            enableWakeLock: wakeLock,
          ),
        );
      } else {
        locationSettings = AppleSettings(
          accuracy: accuracy,
          distanceFilter: distanceFilter,
          activityType: ActivityType.other,
          pauseLocationUpdatesAutomatically: false,
          allowBackgroundLocationUpdates: true,
          showBackgroundLocationIndicator: true,
        );
      }

      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        _onPositionUpdate,
        onError: (e) {
          LogService().log('LocationProviderService: GPS stream error: $e');
        },
      );
      // Mobile uses event-driven stream from Geolocator, no timer needed
    } else {
      // Desktop: Timer-based
      _periodicTimer = MonitoredAsyncPeriodicTimer(
        id: 'location_provider.gps',
        name: 'GPS Updates',
        description: 'Periodic GPS location capture (desktop)',
        serviceName: 'LocationProviderService',
        interval: Duration(seconds: intervalSeconds),
        priority: TaskPriority.low,
        callback: (_) async => await _capturePosition(),
      );
      _capturePosition();
    }
  }

  void _stopPositionUpdates() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  /// Adjust GPS settings based on power mode.
  void _onPowerModeChanged(PowerMode mode) {
    _currentPowerMode = mode;
    if (!_isRunning) return;

    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    if (!isMobile) return;

    switch (mode) {
      case PowerMode.foreground:
        // Restart stream with normal settings
        _startPositionUpdates(_currentIntervalSeconds);
        LogService().log('LocationProviderService: foreground — normal GPS settings');
        break;
      case PowerMode.background:
        if (_highFidelityCount > 0) {
          // High-fidelity consumer active — keep full GPS
          LogService().log('LocationProviderService: background — high-fidelity active, no change');
        } else {
          // Restart with reduced settings (distanceFilter=50, medium accuracy)
          _startPositionUpdates(_currentIntervalSeconds);
          LogService().log('LocationProviderService: background — reduced GPS (distanceFilter=50, medium)');
        }
        break;
      case PowerMode.doze:
        if (_highFidelityCount > 0 || PowerAwareService().hasExemptions) {
          // Exempted — keep GPS alive
          LogService().log('LocationProviderService: doze — exempted, GPS stays active');
        } else {
          // Stop GPS entirely
          _stopPositionUpdates();
          LogService().log('LocationProviderService: doze — GPS stopped');
        }
        break;
    }
  }

  void _onPositionUpdate(Position position) {
    final locked = LockedPosition.fromGeolocator(position);
    _updatePosition(locked);
  }

  Future<void> _capturePosition() async {
    try {
      GeolocationResult? result;

      if (kIsWeb) {
        result = await GeolocationUtils.detectViaBrowser(requestPermission: false);
      } else {
        result = await GeolocationUtils.detectViaGPS(requestPermission: false);
        if (result == null && (Platform.isAndroid || Platform.isIOS)) {
          final lastKnown = await Geolocator.getLastKnownPosition();
          if (lastKnown != null) {
            result = GeolocationResult(
              latitude: lastKnown.latitude,
              longitude: lastKnown.longitude,
              source: 'gps',
              accuracy: lastKnown.accuracy,
            );
          }
        }
        if (result == null) {
          // IP fallback
          result = await GeolocationUtils.detectViaIP();
        }
        if (result == null) {
          // Profile location fallback (for desktop without GeoIP)
          result = GeolocationUtils.getProfileLocation();
        }
      }

      if (result != null) {
        final locked = LockedPosition.fromGeolocationResult(result);
        _updatePosition(locked);
        LogService().log('[LOCATION] Position captured: ${locked.latitude.toStringAsFixed(4)}, ${locked.longitude.toStringAsFixed(4)} (source: ${locked.source})');
      } else {
        LogService().log('[LOCATION] No position available from any source');
      }
    } catch (e) {
      LogService().log('LocationProviderService: Error capturing position: $e');
    }
  }

  void _updatePosition(LockedPosition position) {
    _currentPosition = position;
    _lastUpdateTime = DateTime.now();
    _positionController.add(position);
    _writeSharedPosition(position);

    // Fire EventBus event for decoupled subscribers
    EventBus().fire(PositionUpdatedEvent(
      latitude: position.latitude,
      longitude: position.longitude,
      altitude: position.altitude,
      accuracy: position.accuracy,
      speed: position.speed,
      heading: position.heading,
      source: position.source,
    ));

    notifyListeners();
  }

  @override
  void dispose() {
    _stopPositionUpdates();
    _positionController.close();
    super.dispose();
  }
}
