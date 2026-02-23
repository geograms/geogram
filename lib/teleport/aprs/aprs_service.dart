/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Core APRS bridge service — singleton with event stream.
 * Unlike Telegram/Signal, APRS has no authentication flow.
 * Wires AprsIsClient for live APRS-IS connectivity.
 * Integrates GPS via UserLocationService and persists packets via AprsCacheService.
 *
 * UI events are throttled (500ms) so high-volume packet streams don't freeze
 * the Flutter UI with per-packet setState rebuilds.
 */

import 'dart:async';
import 'dart:math';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../services/user_location_service.dart';
import 'aprs_cache_service.dart';
import 'aprs_is_client.dart';
import 'models/aprs_packet.dart';

/// Event types emitted by the APRS bridge.
enum AprsEventType {
  packetReceived,
  messageReceived,
  connected,
  disconnected,
  error,
}

/// An event from the APRS bridge.
class AprsEvent {
  final AprsEventType type;
  final dynamic data;

  const AprsEvent(this.type, [this.data]);

  @override
  String toString() => 'AprsEvent($type)';
}

/// Core APRS bridge singleton.
///
/// Follows the Signal/Telegram singleton pattern but much simpler —
/// no FFI client, no auth flow. Uses AprsIsClient for APRS-IS TCP connection.
class AprsService {
  static final AprsService _instance = AprsService._internal();
  factory AprsService() => _instance;
  AprsService._internal();

  bool _enabled = false;
  double _radiusKm = 100;
  String? _callsign;
  AprsIsClient? _client;

  // GPS tracking
  _VoidCallback? _locationDispose;
  double? _lastFilterLat;
  double? _lastFilterLon;
  DateTime? _lastFilterTime;

  // Persistence
  AprsCacheService? _cacheService;

  // Dedup — keeps recent rawTnc2 hashes to skip duplicates
  final Set<String> _recentPacketHashes = {};
  static const int _maxRecentHashes = 5000;

  static const int _maxStreamPackets = 10000;
  static const int _maxMessages = 5000;

  // GPS filter thresholds
  static const Duration _filterTimeThreshold = Duration(minutes: 10);
  static const double _filterDistanceThresholdKm = 5.0;

  // UI throttle — accumulate packets, emit events periodically
  static const Duration _uiUpdateInterval = Duration(milliseconds: 500);
  Timer? _uiUpdateTimer;
  bool _uiDirtyStream = false;
  bool _uiDirtyMessages = false;

  // Batch SQLite writes — queue packets and flush periodically
  static const Duration _writeFlushInterval = Duration(seconds: 2);
  static const int _writeFlushThreshold = 100;
  final List<AprsPacket> _writeQueue = [];
  Timer? _writeTimer;

  final StreamController<AprsEvent> _eventController =
      StreamController<AprsEvent>.broadcast();

  /// All received broadcast packets (stream tab).
  final List<AprsPacket> streamPackets = [];

  /// Directed messages addressed to this station (messages tab).
  final List<AprsPacket> messages = [];

  /// Stream of APRS bridge events.
  Stream<AprsEvent> get events => _eventController.stream;

  /// Whether the user has enabled APRS operations.
  bool get isEnabled => _enabled;

  /// Receive radius in km (1–1000, default 100).
  double get radiusKm => _radiusKm;
  set radiusKm(double value) {
    _radiusKm = value.clamp(1, 1000);
    _client?.updateFilter(radiusKm: _radiusKm);
  }

  /// Whether the APRS-IS client is connected.
  bool get isRunning => _client?.isConnected ?? false;

  /// Emit an event into the service stream (used by AprsIsClient).
  void emitEvent(AprsEvent event) {
    _eventController.add(event);
  }

  /// Wire up persistence via ProfileStorage (call before enable).
  void setStorage(ProfileStorage storage) {
    _cacheService = AprsCacheService(storage, '');
  }

  /// Try to auto-start APRS if it was enabled in a previous session.
  /// Call from main.dart post-frame callback.
  Future<void> autoStart(ProfileStorage storage) async {
    if (_enabled) return;
    setStorage(storage);
    final config = await _cacheService!.loadConfig();
    if (config == null || config['enabled'] != true) return;
    final callsign = config['callsign'] as String?;
    final radius = (config['radiusKm'] as num?)?.toDouble();
    if (callsign == null || callsign.isEmpty) return;
    if (radius != null) _radiusKm = radius;
    LogService().log('AprsService: auto-starting for $callsign');
    enable(callsign: callsign);
  }

  /// Enable APRS operations — connects to APRS-IS using GPS position.
  /// Fire-and-forget safe: loads cached packets, connects, and emits events
  /// without blocking the caller.
  void enable({required String callsign}) {
    if (_enabled) return;
    _enabled = true;
    _callsign = callsign;

    _startUiTimer();
    // Persist enabled state, then load cache + connect in background
    _saveConfig();
    _initAsync(callsign);
  }

  /// Async initialization — runs after enable() returns.
  Future<void> _initAsync(String callsign) async {
    // Load persisted packets from SQLite
    if (_cacheService != null) {
      try {
        final cached = await _cacheService!.loadPackets();
        for (final pkt in cached) {
          if (pkt.type == AprsPacketType.message && pkt.messageText != null) {
            messages.add(pkt);
            _uiDirtyMessages = true;
          } else {
            streamPackets.add(pkt);
            _uiDirtyStream = true;
          }
        }
      } catch (e) {
        LogService().log('AprsService: cache load error: $e');
      }
    }

    // Get initial position from GPS service (fallback: 0,0)
    final locService = UserLocationService();
    final loc = locService.currentLocation;
    final lat = loc?.latitude ?? 0.0;
    final lon = loc?.longitude ?? 0.0;

    _client = AprsIsClient(
      callsign: callsign,
      latitude: lat,
      longitude: lon,
      radiusKm: _radiusKm,
    );
    _client!.connect();

    _lastFilterLat = lat;
    _lastFilterLon = lon;
    _lastFilterTime = DateTime.now();

    // Register as GPS consumer — listen for location changes
    void onLocationChange() {
      _onPositionUpdate(locService.currentLocation);
    }
    locService.addListener(onLocationChange);
    _locationDispose = () => locService.removeListener(onLocationChange);
  }

  /// Handle GPS position update — update client and send filter if needed.
  void _onPositionUpdate(UserLocation? location) {
    if (location == null || !location.isValid || _client == null) return;

    final lat = location.latitude;
    final lon = location.longitude;

    // Always keep client coordinates fresh (used on reconnect)
    _client!.latitude = lat;
    _client!.longitude = lon;

    // Decide whether to send a filter update to APRS-IS
    final now = DateTime.now();
    bool shouldUpdate = false;

    if (_lastFilterTime == null) {
      shouldUpdate = true;
    } else {
      final elapsed = now.difference(_lastFilterTime!);
      if (elapsed >= _filterTimeThreshold) {
        shouldUpdate = true;
      } else if (_lastFilterLat != null && _lastFilterLon != null) {
        final dist = _haversineKm(
          _lastFilterLat!, _lastFilterLon!, lat, lon,
        );
        if (dist >= _filterDistanceThresholdKm) {
          shouldUpdate = true;
        }
      }
    }

    if (shouldUpdate) {
      _client!.updateFilter(latitude: lat, longitude: lon);
      _lastFilterLat = lat;
      _lastFilterLon = lon;
      _lastFilterTime = now;
    }
  }

  /// Disable APRS operations — disconnects from APRS-IS and unregisters GPS.
  void disable() {
    if (!_enabled) return;
    _enabled = false;
    _stopUiTimer();
    _locationDispose?.call();
    _locationDispose = null;
    _client?.disconnect();
    _client = null;
    _recentPacketHashes.clear();
    _saveConfig();
    _eventController.add(const AprsEvent(AprsEventType.disconnected));
  }

  /// Add a packet — dedup, queue for persistence, classify, and append to
  /// the appropriate list. Sets dirty flags; the UI timer emits batched events.
  void addPacket(AprsPacket packet) {
    // Dedup by rawTnc2
    if (_recentPacketHashes.contains(packet.rawTnc2)) return;
    _recentPacketHashes.add(packet.rawTnc2);
    if (_recentPacketHashes.length > _maxRecentHashes) {
      _recentPacketHashes.remove(_recentPacketHashes.first);
    }

    // Queue for batched SQLite write
    _writeQueue.add(packet);
    if (_writeQueue.length >= _writeFlushThreshold) {
      _flushWrites();
    }

    if (packet.type == AprsPacketType.message && packet.messageText != null) {
      messages.add(packet);
      if (messages.length > _maxMessages) {
        messages.removeRange(0, messages.length - _maxMessages);
      }
      _uiDirtyMessages = true;
    } else {
      streamPackets.add(packet);
      if (streamPackets.length > _maxStreamPackets) {
        streamPackets.removeRange(0, streamPackets.length - _maxStreamPackets);
      }
      _uiDirtyStream = true;
    }
  }

  /// Flush the write queue to SQLite in a single transaction.
  Future<void> _flushWrites() async {
    if (_writeQueue.isEmpty || _cacheService == null) return;
    final batch = List<AprsPacket>.from(_writeQueue);
    _writeQueue.clear();
    await _cacheService!.cachePackets(batch);
  }

  // ---------------------------------------------------------------------------
  // UI throttle timer
  // ---------------------------------------------------------------------------

  void _startUiTimer() {
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = Timer.periodic(_uiUpdateInterval, _onUiTick);
    _writeTimer?.cancel();
    _writeTimer = Timer.periodic(_writeFlushInterval, (_) => _flushWrites());
  }

  void _stopUiTimer() {
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;
    _writeTimer?.cancel();
    _writeTimer = null;
    _flushWrites(); // flush remaining packets on disable
  }

  void _onUiTick(Timer _) {
    if (_uiDirtyStream) {
      _uiDirtyStream = false;
      _eventController.add(const AprsEvent(AprsEventType.packetReceived));
    }
    if (_uiDirtyMessages) {
      _uiDirtyMessages = false;
      _eventController.add(const AprsEvent(AprsEventType.messageReceived));
    }
  }

  // ---------------------------------------------------------------------------
  // Config persistence
  // ---------------------------------------------------------------------------

  Future<void> _saveConfig() async {
    await _cacheService?.saveConfig({
      'enabled': _enabled,
      'callsign': _callsign,
      'radiusKm': _radiusKm,
    });
  }

  // ---------------------------------------------------------------------------
  // Haversine
  // ---------------------------------------------------------------------------

  static double _haversineKm(
    double lat1, double lon1, double lat2, double lon2,
  ) {
    const earthRadius = 6371.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) * cos(_deg2rad(lat2)) *
        sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  static double _deg2rad(double deg) => deg * pi / 180;

  /// Dispose resources.
  void dispose() {
    _stopUiTimer();
    _locationDispose?.call();
    _locationDispose = null;
    _client?.disconnect();
    _client = null;
    _cacheService?.dispose();
    _cacheService = null;
    _eventController.close();
  }
}

/// Typedef for dispose callbacks (private to avoid conflict with Flutter's VoidCallback).
typedef _VoidCallback = void Function();
