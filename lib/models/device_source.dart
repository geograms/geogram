/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Represents a device source for chat rooms
/// Can be the local device, a relay, or a directly connected remote device
class DeviceSource {
  /// Unique identifier for this device source
  final String id;

  /// Display name (e.g., "This Device", relay name, or device callsign)
  final String name;

  /// Device callsign (X3 format)
  final String? callsign;

  /// Type of device source
  final DeviceSourceType type;

  /// Connection URL (for relays and direct connections)
  final String? url;

  /// Whether the device is currently reachable
  bool isOnline;

  /// Latency in milliseconds (if measurable)
  int? latency;

  /// Last time connection was checked
  DateTime? lastChecked;

  /// Location information
  final String? location;

  DeviceSource({
    required this.id,
    required this.name,
    this.callsign,
    required this.type,
    this.url,
    this.isOnline = true,
    this.latency,
    this.lastChecked,
    this.location,
  });

  /// Create local device source
  factory DeviceSource.local({
    required String callsign,
    String? nickname,
  }) {
    return DeviceSource(
      id: 'local',
      name: nickname ?? 'This Device',
      callsign: callsign,
      type: DeviceSourceType.local,
      isOnline: true,
    );
  }

  /// Create relay device source
  factory DeviceSource.relay({
    required String id,
    required String name,
    String? callsign,
    required String url,
    bool isOnline = true,
    int? latency,
    String? location,
  }) {
    return DeviceSource(
      id: id,
      name: name,
      callsign: callsign,
      type: DeviceSourceType.relay,
      url: url,
      isOnline: isOnline,
      latency: latency,
      location: location,
    );
  }

  /// Create direct connection device source (for future use)
  factory DeviceSource.direct({
    required String callsign,
    String? name,
    required String url,
    bool isOnline = false,
    int? latency,
  }) {
    return DeviceSource(
      id: 'direct_$callsign',
      name: name ?? callsign,
      callsign: callsign,
      type: DeviceSourceType.direct,
      url: url,
      isOnline: isOnline,
      latency: latency,
    );
  }

  /// Whether this is the local device
  bool get isLocal => type == DeviceSourceType.local;

  /// Whether this is a relay connection
  bool get isRelay => type == DeviceSourceType.relay;

  /// Whether this is a direct P2P connection
  bool get isDirect => type == DeviceSourceType.direct;

  /// Get status display string
  /// Only shows text when not reachable - no need to display when connected
  String get statusText {
    if (isLocal) return '';
    if (!isOnline) return 'Not reachable';
    return ''; // No text needed when online
  }

  /// Get icon for this device type
  String get iconName {
    switch (type) {
      case DeviceSourceType.local:
        return 'smartphone';
      case DeviceSourceType.relay:
        return 'cell_tower';
      case DeviceSourceType.direct:
        return 'wifi_tethering';
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceSource &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'DeviceSource(id: $id, name: $name, type: ${type.name}, online: $isOnline)';
}

/// Type of device connection
enum DeviceSourceType {
  /// The local device running this app
  local,

  /// A relay server (internet gateway)
  relay,

  /// Direct P2P connection to another device (future)
  direct,
}
