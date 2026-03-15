import 'dart:async';

import 'package:flutter/foundation.dart';

import 'log_service.dart';
import 'profile_service.dart';

/// A sibling device discovered via station relay or LAN scan.
class SiblingDevice {
  final String deviceId; // Station connection ID
  final String? installId; // Per-install UUID (first 4 chars used as display suffix)
  final String callsign;
  final String? npub;
  final String platform;
  final String deviceType;
  final String connectionType; // 'station', 'lan'
  final bool verified;
  final String? directAddress; // LAN IP:port (from StationDiscoveryService)
  final String? stationRelayUrl; // station relay URL
  DateTime lastSeen;

  SiblingDevice({
    required this.deviceId,
    this.installId,
    required this.callsign,
    this.npub,
    this.platform = 'unknown',
    this.deviceType = 'unknown',
    this.connectionType = 'station',
    this.verified = false,
    this.directAddress,
    this.stationRelayUrl,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  /// Short display name: "Android (a1b2)" or just "Android" if no install ID.
  String get displayName {
    if (installId != null && installId!.length >= 4) {
      return '$platform (${installId!.substring(0, 4)})';
    }
    return platform;
  }

  @override
  String toString() => 'SiblingDevice($callsign, $platform, $connectionType, id=$deviceId)';
}

/// Singleton service that aggregates sibling device presence from:
/// - Station WebSocket (siblings_update messages + hello_ack sibling_count)
/// - LAN scan (StationDiscoveryService results filtered for same callsign)
class SiblingDiscoveryService {
  static final SiblingDiscoveryService _instance = SiblingDiscoveryService._internal();
  factory SiblingDiscoveryService() => _instance;
  SiblingDiscoveryService._internal();

  /// Current list of discovered sibling devices.
  final ValueNotifier<List<SiblingDevice>> siblings = ValueNotifier([]);

  /// Last sibling count reported by hello_ack.
  int _lastHelloAckSiblingCount = 0;
  int get lastHelloAckSiblingCount => _lastHelloAckSiblingCount;

  /// Handle a `siblings_update` WebSocket message from the station.
  void handleSiblingsUpdate(Map<String, dynamic> data) {
    final callsign = data['callsign'] as String?;
    final siblingsList = data['siblings'] as List<dynamic>?;
    if (callsign == null || siblingsList == null) return;

    // Verify this update is for our active callsign
    final activeProfile = ProfileService().getProfile();
    if (activeProfile.callsign.toUpperCase() != callsign.toUpperCase()) {
      LogService().log('SiblingDiscovery: Ignoring update for $callsign (active: ${activeProfile.callsign})');
      return;
    }

    final stationSiblings = <SiblingDevice>[];
    for (final s in siblingsList) {
      if (s is! Map<String, dynamic>) continue;
      stationSiblings.add(SiblingDevice(
        deviceId: s['device_id'] as String? ?? '',
        installId: s['install_id'] as String?,
        callsign: callsign,
        npub: s['npub'] as String?,
        platform: s['platform'] as String? ?? 'unknown',
        deviceType: s['device_type'] as String? ?? 'unknown',
        connectionType: 'station',
        verified: s['verified'] as bool? ?? false,
      ));
    }

    // Merge: replace all station-sourced siblings, preserve LAN-sourced ones
    final lanSiblings = siblings.value
        .where((s) => s.connectionType == 'lan')
        .toList();
    siblings.value = [...stationSiblings, ...lanSiblings];

    LogService().log('SiblingDiscovery: ${stationSiblings.length} station sibling(s) for $callsign');
  }

  /// Update sibling count from hello_ack response.
  void handleHelloAckSiblingCount(int count) {
    _lastHelloAckSiblingCount = count;
    if (count == 0) {
      // Clear station siblings (LAN ones might still exist)
      final lanSiblings = siblings.value
          .where((s) => s.connectionType == 'lan')
          .toList();
      siblings.value = lanSiblings;
    }
    LogService().log('SiblingDiscovery: hello_ack reports $count sibling(s)');
  }

  /// Clear all sibling state (e.g. on profile switch or disconnect).
  void clear() {
    siblings.value = [];
    _lastHelloAckSiblingCount = 0;
  }

  void dispose() {
    siblings.dispose();
  }
}
