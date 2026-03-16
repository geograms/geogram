import 'dart:async';

import 'package:flutter/foundation.dart';

import 'log_service.dart';
import 'profile_service.dart';

/// A mirror device discovered via station relay or LAN scan.
class MirrorDevice {
  final String deviceId; // Station connection ID
  final String? installId; // Per-install UUID (first 4 chars used as display suffix)
  final String callsign;
  final String? npub;
  final String? nickname; // User-chosen device name from remote peer
  final String platform;
  final String deviceType;
  final String connectionType; // 'station', 'lan'
  final bool verified;
  final String? directAddress; // LAN IP:port (from StationDiscoveryService)
  final String? stationRelayUrl; // station relay URL
  DateTime lastSeen;

  MirrorDevice({
    required this.deviceId,
    this.installId,
    required this.callsign,
    this.npub,
    this.nickname,
    this.platform = 'unknown',
    this.deviceType = 'unknown',
    this.connectionType = 'station',
    this.verified = false,
    this.directAddress,
    this.stationRelayUrl,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  /// Short display name: nickname if set, else "Android (a1b2)", else platform.
  String get displayName {
    if (nickname != null && nickname!.isNotEmpty) return nickname!;
    if (installId != null && installId!.length >= 4) {
      return '$platform (${installId!.substring(0, 4)})';
    }
    return platform;
  }

  @override
  String toString() => 'MirrorDevice($callsign, $platform, $connectionType, id=$deviceId)';
}

/// Singleton service that aggregates mirror device presence from:
/// - Station WebSocket (mirrors_update messages + hello_ack mirror_count)
/// - LAN scan (StationDiscoveryService results filtered for same callsign)
class MirrorDiscoveryService {
  static final MirrorDiscoveryService _instance = MirrorDiscoveryService._internal();
  factory MirrorDiscoveryService() => _instance;
  MirrorDiscoveryService._internal();

  /// Optional callback for peer auto-registration (set by app initialization).
  /// Serialized: only one call runs at a time; queued updates coalesce.
  static Future<void> Function(List<MirrorDevice> mirrors)? onMirrorsChanged;
  static bool _callbackRunning = false;
  static List<MirrorDevice>? _pendingCallback;

  /// Current list of discovered mirror devices.
  final ValueNotifier<List<MirrorDevice>> mirrors = ValueNotifier([]);

  /// Last mirror count reported by hello_ack.
  int _lastHelloAckMirrorCount = 0;
  int get lastHelloAckMirrorCount => _lastHelloAckMirrorCount;

  /// Handle a `mirrors_update` WebSocket message from the station.
  void handleMirrorsUpdate(Map<String, dynamic> data) {
    final callsign = data['callsign'] as String?;
    final mirrorsList = data['mirrors'] as List<dynamic>?;
    if (callsign == null || mirrorsList == null) return;

    // Verify this update is for our active callsign
    final activeProfile = ProfileService().getProfile();
    if (activeProfile.callsign.toUpperCase() != callsign.toUpperCase()) {
      LogService().log('MirrorDiscovery: Ignoring update for $callsign (active: ${activeProfile.callsign})');
      return;
    }

    final stationMirrors = <MirrorDevice>[];
    for (final s in mirrorsList) {
      if (s is! Map<String, dynamic>) continue;
      stationMirrors.add(MirrorDevice(
        deviceId: s['device_id'] as String? ?? '',
        installId: s['install_id'] as String?,
        callsign: callsign,
        npub: s['npub'] as String?,
        nickname: s['nickname'] as String?,
        platform: s['platform'] as String? ?? 'unknown',
        deviceType: s['device_type'] as String? ?? 'unknown',
        connectionType: 'station',
        verified: s['verified'] as bool? ?? false,
      ));
    }

    // Merge: replace all station-sourced mirrors, preserve LAN-sourced ones
    final lanMirrors = mirrors.value
        .where((s) => s.connectionType == 'lan')
        .toList();
    mirrors.value = [...stationMirrors, ...lanMirrors];

    LogService().log('MirrorDiscovery: ${stationMirrors.length} station mirror(s) for $callsign');

    // Notify listener (serialized — coalesces rapid updates)
    _scheduleCallback(stationMirrors);
  }

  /// Schedule the onMirrorsChanged callback, serializing concurrent calls.
  static void _scheduleCallback(List<MirrorDevice> mirrors) {
    final cb = onMirrorsChanged;
    if (cb == null) return;

    if (_callbackRunning) {
      // Coalesce: keep only the latest update
      _pendingCallback = mirrors;
      return;
    }

    _callbackRunning = true;
    cb(mirrors).whenComplete(() {
      _callbackRunning = false;
      final pending = _pendingCallback;
      if (pending != null) {
        _pendingCallback = null;
        _scheduleCallback(pending);
      }
    });
  }

  /// Update mirror count from hello_ack response.
  void handleHelloAckMirrorCount(int count) {
    _lastHelloAckMirrorCount = count;
    if (count == 0) {
      // Clear station mirrors (LAN ones might still exist)
      final lanMirrors = mirrors.value
          .where((s) => s.connectionType == 'lan')
          .toList();
      mirrors.value = lanMirrors;
    }
    LogService().log('MirrorDiscovery: hello_ack reports $count mirror(s)');
  }

  /// Clear all mirror state (e.g. on profile switch or disconnect).
  void clear() {
    mirrors.value = [];
    _lastHelloAckMirrorCount = 0;
  }

  void dispose() {
    mirrors.dispose();
  }
}
