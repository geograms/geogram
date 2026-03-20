// Unified connected client model for station server
import 'dart:io';

import '../cli/commands/service_interfaces.dart';
import 'mixins/device_proxy_mixin.dart';
import 'mixins/email_handler_mixin.dart';
import 'mixins/mirror_notify_mixin.dart';

/// Connection type enum for categorizing how clients connect
enum ConnectionType {
  localWifi,
  internet,
  bluetooth,
  lora,
  radio,
  other;

  String get displayName {
    switch (this) {
      case ConnectionType.localWifi:
        return 'Local Wi-Fi';
      case ConnectionType.internet:
        return 'Internet';
      case ConnectionType.bluetooth:
        return 'Bluetooth';
      case ConnectionType.lora:
        return 'LoRa';
      case ConnectionType.radio:
        return 'Radio';
      case ConnectionType.other:
        return 'Other';
    }
  }

  String get code {
    switch (this) {
      case ConnectionType.localWifi:
        return 'wifi';
      case ConnectionType.internet:
        return 'internet';
      case ConnectionType.bluetooth:
        return 'bluetooth';
      case ConnectionType.lora:
        return 'lora';
      case ConnectionType.radio:
        return 'radio';
      case ConnectionType.other:
        return 'other';
    }
  }

  static ConnectionType fromCode(String code) {
    switch (code) {
      case 'wifi':
        return ConnectionType.localWifi;
      case 'internet':
        return ConnectionType.internet;
      case 'bluetooth':
        return ConnectionType.bluetooth;
      case 'lora':
        return ConnectionType.lora;
      case 'radio':
        return ConnectionType.radio;
      default:
        return ConnectionType.other;
    }
  }
}

/// Connected WebSocket client
/// Unified model combining PureConnectedClient (CLI) and ConnectedClient (App)
class StationClient implements EmailClient, ConnectedClientReadable, DeviceProxyClient, MirrorClient {
  @override
  final WebSocket socket;
  @override
  final String id;
  @override
  String? callsign;
  @override
  String? nickname;
  @override
  String? deviceName; // Device-chosen name (e.g., "thinkpad", "My Phone")
  String? color;
  @override
  String? deviceType;
  @override
  String? platform;
  String? version;
  String? remoteAddress;
  @override
  String? npub;
  @override
  String? deviceId;
  ConnectionType connectionType;
  double? latitude;
  double? longitude;
  int ssid; // APRS-style SSID for device identification (0-15)
  @override
  DateTime connectedAt;
  DateTime lastActivity;

  // Challenge-response authentication (HELLO protocol v2)
  String? pendingChallenge; // Nonce sent to client for verification
  int helloProtocol = 1; // Protocol version used by client (1=legacy, 2=challenge-response)
  @override
  bool verified = false; // Whether challenge-response passed

  // Multi-device responsiveness tracking
  @override
  int successCount = 0; // Successful proxy responses
  @override
  int failCount = 0; // Timeouts/errors

  // Device priority (lower = higher priority, 0 = no priority set)
  @override
  int priority = 0;

  /// MirrorClient address alias (maps to remoteAddress)
  @override
  String? get address => remoteAddress;

  /// Success rate for adaptive device ordering (0.0 to 1.0)
  @override
  double get successRate {
    final total = successCount + failCount;
    if (total == 0) return 0.5; // Neutral for new connections
    return successCount / total;
  }

  StationClient({
    required this.socket,
    required this.id,
    this.callsign,
    this.nickname,
    this.color,
    this.deviceType,
    this.platform,
    this.version,
    this.remoteAddress,
    this.npub,
    this.connectionType = ConnectionType.other,
    this.latitude,
    this.longitude,
    this.ssid = 0,
  })  : connectedAt = DateTime.now(),
        lastActivity = DateTime.now();

  /// Detect connection type from remote address
  static ConnectionType detectConnectionType(String? address) {
    if (address == null) return ConnectionType.other;

    // Local network addresses (Wi-Fi)
    if (address.startsWith('192.168.') ||
        address.startsWith('10.') ||
        address.startsWith('172.16.') ||
        address.startsWith('172.17.') ||
        address.startsWith('172.18.') ||
        address.startsWith('172.19.') ||
        address.startsWith('172.2') ||
        address.startsWith('172.30.') ||
        address.startsWith('172.31.') ||
        address == '127.0.0.1' ||
        address == 'localhost') {
      return ConnectionType.localWifi;
    }

    // Public IPs are likely internet
    return ConnectionType.internet;
  }

  /// Convert to JSON for API response
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'callsign': callsign ?? 'Unknown',
      'nickname': nickname ?? callsign,
      'color': color,
      'npub': npub,
      'device_name': deviceName,
      'device_type': deviceType ?? 'Unknown',
      'platform': platform,
      'version': version,
      'address': remoteAddress,
      'connection_type': connectionType.code,
      'latitude': latitude,
      'longitude': longitude,
      if (ssid > 0) 'ssid': ssid,
      'connected_at': connectedAt.toIso8601String(),
      'last_activity': lastActivity.toIso8601String(),
      'protocol': helloProtocol,
      'verified': verified,
      'success_count': successCount,
      'fail_count': failCount,
    };
  }
}

/// Backup provider entry for backup service discovery
class BackupProviderEntry {
  final String callsign;
  final String npub;
  final int maxTotalStorageBytes;
  final int defaultMaxClientStorageBytes;
  final int defaultMaxSnapshots;
  DateTime lastSeen;

  BackupProviderEntry({
    required this.callsign,
    required this.npub,
    required this.maxTotalStorageBytes,
    required this.defaultMaxClientStorageBytes,
    required this.defaultMaxSnapshots,
    required this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
    'callsign': callsign,
    'npub': npub,
    'max_total_storage_bytes': maxTotalStorageBytes,
    'default_max_client_storage_bytes': defaultMaxClientStorageBytes,
    'default_max_snapshots': defaultMaxSnapshots,
    'last_seen': lastSeen.toIso8601String(),
  };
}

/// Disconnect info for reconnection tolerance
class DisconnectInfo {
  final DateTime disconnectTime;
  final DateTime originalConnectTime;

  DisconnectInfo({
    required this.disconnectTime,
    required this.originalConnectTime,
  });
}
