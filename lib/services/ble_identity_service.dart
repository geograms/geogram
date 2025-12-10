/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'app_args.dart';
import 'collection_service.dart';
import 'log_service.dart';

/// Service for managing BLE device identity and MAC address tracking
class BLEIdentityService {
  static final BLEIdentityService _instance = BLEIdentityService._internal();
  factory BLEIdentityService() => _instance;
  BLEIdentityService._internal();

  /// Geogram BLE marker byte
  static const int geogramMarker = 0x3E; // '>'

  /// Device ID (1-15, derived from hardware)
  int? _deviceId;

  /// Last known MAC address (Android only)
  String? _lastKnownMac;

  /// Timer for periodic advertisement
  Timer? _advertisementTimer;

  /// Stream controller for identity changes
  final _identityChangeController = StreamController<BLEIdentityUpdate>.broadcast();

  /// Stream of identity updates (for broadcasting to connected peers)
  Stream<BLEIdentityUpdate> get identityChanges => _identityChangeController.stream;

  /// Callback to perform BLE advertisement
  Future<void> Function(Uint8List data)? _advertiseCallback;

  /// Callback to broadcast identity update to connected peers
  Future<void> Function(String json)? _broadcastCallback;

  /// Initialize the identity service
  Future<void> initialize() async {
    _deviceId = await _computeHardwareDeviceId();
    LogService().log('BLEIdentity: Initialized with device ID: $_deviceId');
  }

  /// Set the advertisement callback
  void setAdvertiseCallback(Future<void> Function(Uint8List data) callback) {
    _advertiseCallback = callback;
  }

  /// Set the broadcast callback for identity updates
  void setBroadcastCallback(Future<void> Function(String json) callback) {
    _broadcastCallback = callback;
  }

  /// Get the device ID (1-15)
  int get deviceId => _deviceId ?? 1;

  /// Get the device ID as string for display
  String get deviceIdString => deviceId.toString();

  /// Get the current callsign
  String get callsign => CollectionService().currentCallsign ?? 'UNKNOWN';

  /// Get the full identity string (callsign-deviceId)
  /// Compatible with APRS SSID format (e.g., "X34PSK-7")
  String get fullIdentity => '$callsign-$deviceId';

  /// Compute device ID (1-15) from hardware characteristics
  /// This produces a consistent ID on the same hardware across reinstalls
  Future<int> _computeHardwareDeviceId() async {
    try {
      String? hardwareFingerprint;

      if (kIsWeb) {
        // Web: use a fallback (cannot reliably identify hardware)
        hardwareFingerprint = 'web-default';
      } else if (Platform.isLinux) {
        // Linux: use /etc/machine-id (persistent unique machine identifier)
        hardwareFingerprint = await _getLinuxMachineId();
      } else if (Platform.isMacOS) {
        // macOS: use IOPlatformUUID via shell command
        hardwareFingerprint = await _getMacOSHardwareId();
      } else if (Platform.isWindows) {
        // Windows: use MachineGuid from registry
        hardwareFingerprint = await _getWindowsHardwareId();
      } else if (Platform.isAndroid) {
        // Android: use Build.FINGERPRINT or ANDROID_ID via platform channel
        // For now, use a combination approach
        hardwareFingerprint = await _getAndroidHardwareId();
      } else if (Platform.isIOS) {
        // iOS: identifierForVendor would need platform channel
        hardwareFingerprint = await _getIOSHardwareId();
      }

      if (hardwareFingerprint == null || hardwareFingerprint.isEmpty) {
        LogService().log('BLEIdentity: Could not get hardware ID, using fallback');
        hardwareFingerprint = 'fallback-${DateTime.now().millisecondsSinceEpoch}';
      }

      // Hash the fingerprint and reduce to 1-15
      final hash = _hashString(hardwareFingerprint);
      final deviceId = (hash % 15) + 1; // 1-15

      LogService().log('BLEIdentity: Hardware fingerprint hash -> device ID: $deviceId');
      return deviceId;
    } catch (e) {
      LogService().log('BLEIdentity: Error computing hardware ID: $e');
      return 1; // Default fallback
    }
  }

  /// Get Linux machine ID from /etc/machine-id
  Future<String?> _getLinuxMachineId() async {
    try {
      final file = File('/etc/machine-id');
      if (await file.exists()) {
        final content = await file.readAsString();
        return content.trim();
      }
    } catch (e) {
      LogService().log('BLEIdentity: Error reading /etc/machine-id: $e');
    }
    return null;
  }

  /// Get macOS hardware UUID
  Future<String?> _getMacOSHardwareId() async {
    // Would need to run: ioreg -rd1 -c IOPlatformExpertDevice | grep IOPlatformUUID
    // For now, use hostname as fallback
    return Platform.localHostname;
  }

  /// Get Windows hardware ID
  Future<String?> _getWindowsHardwareId() async {
    // Would need to read: HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography\MachineGuid
    // For now, use hostname as fallback
    return Platform.localHostname;
  }

  /// Get Android hardware ID
  Future<String?> _getAndroidHardwareId() async {
    // Would need platform channel to get Build.FINGERPRINT or ANDROID_ID
    // For now, use a combination of available info
    return 'android-${Platform.localHostname}';
  }

  /// Get iOS hardware ID
  Future<String?> _getIOSHardwareId() async {
    // Would need platform channel to get identifierForVendor
    // For now, use hostname as fallback
    return Platform.localHostname;
  }

  /// Simple hash function for strings (djb2 algorithm)
  int _hashString(String str) {
    int hash = 5381;
    for (int i = 0; i < str.length; i++) {
      hash = ((hash << 5) + hash) + str.codeUnitAt(i);
      hash = hash & 0x7FFFFFFF; // Keep it positive
    }
    return hash;
  }

  /// Build advertising data for BLE
  /// Format: [marker][device_id:1 byte (1-15)][callsign:up to 18]
  Uint8List buildAdvertisingData() {
    final callsignBytes = utf8.encode(callsign);

    // Max 20 bytes: 1 marker + 1 device_id + up to 18 callsign
    final maxCallsignBytes = 18;
    final truncatedCallsign = callsignBytes.length > maxCallsignBytes
        ? callsignBytes.sublist(0, maxCallsignBytes)
        : callsignBytes;

    final data = Uint8List(1 + 1 + truncatedCallsign.length);
    data[0] = geogramMarker;
    data[1] = deviceId; // 1-15 fits in one byte
    data.setRange(2, 2 + truncatedCallsign.length, truncatedCallsign);

    return data;
  }

  /// Parse advertising data to extract identity
  /// Returns null if not valid Geogram advertising data
  static BLEParsedIdentity? parseAdvertisingData(Uint8List data) {
    if (data.isEmpty) return null;
    if (data[0] != geogramMarker) return null;

    try {
      // New format: [marker][device_id:1 byte][callsign...]
      if (data.length >= 2) {
        final deviceIdByte = data[1];

        // Check if this looks like the new format (device_id is 1-15)
        if (deviceIdByte >= 1 && deviceIdByte <= 15 && data.length >= 3) {
          final callsignBytes = data.sublist(2);

          // Find null terminator if present
          int endIndex = callsignBytes.indexOf(0);
          final effectiveBytes = endIndex >= 0
              ? callsignBytes.sublist(0, endIndex)
              : callsignBytes;

          final callsign = utf8.decode(effectiveBytes, allowMalformed: true).trim();

          if (callsign.isNotEmpty) {
            return BLEParsedIdentity(
              callsign: callsign,
              deviceId: deviceIdByte,
              fullIdentity: '$callsign-$deviceIdByte',
            );
          }
        }
      }

      // Legacy format: [marker][callsign...] (no device_id)
      final callsignBytes = data.sublist(1);
      int endIndex = callsignBytes.indexOf(0);
      final effectiveBytes = endIndex >= 0
          ? callsignBytes.sublist(0, endIndex)
          : callsignBytes;

      final callsign = utf8.decode(effectiveBytes, allowMalformed: true).trim();
      if (callsign.isNotEmpty) {
        return BLEParsedIdentity(
          callsign: callsign,
          deviceId: null,
          fullIdentity: callsign,
        );
      }
    } catch (e) {
      LogService().log('BLEIdentity: Failed to parse advertising data: $e');
    }

    return null;
  }

  /// Start periodic advertisement (every 30 seconds)
  void startPeriodicAdvertisement() {
    if (kIsWeb) return;

    // Refuse in internet-only mode
    if (AppArgs().internetOnly) {
      LogService().log('BLEIdentity: Periodic advertisement disabled in internet-only mode');
      return;
    }

    // Stop any existing timer
    _advertisementTimer?.cancel();

    // Advertise immediately
    _advertiseIdentity();

    // Then every 30 seconds
    _advertisementTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _advertiseIdentity(),
    );

    LogService().log('BLEIdentity: Started periodic advertisement (30s interval)');
  }

  /// Stop periodic advertisement
  void stopPeriodicAdvertisement() {
    _advertisementTimer?.cancel();
    _advertisementTimer = null;
    LogService().log('BLEIdentity: Stopped periodic advertisement');
  }

  /// Perform BLE advertisement
  Future<void> _advertiseIdentity() async {
    if (_advertiseCallback == null) return;

    // On Android, check for MAC change
    if (!kIsWeb && Platform.isAndroid) {
      await _checkMacChange();
    }

    try {
      final data = buildAdvertisingData();
      await _advertiseCallback!(data);
      LogService().log('BLEIdentity: Advertised identity: $fullIdentity');
    } catch (e) {
      LogService().log('BLEIdentity: Failed to advertise: $e');
    }
  }

  /// Check if MAC address has changed (Android only)
  Future<void> _checkMacChange() async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      final currentMac = await _getCurrentMac();
      if (currentMac == null) return;

      if (_lastKnownMac != null && currentMac != _lastKnownMac) {
        LogService().log('BLEIdentity: MAC address changed: '
            '$_lastKnownMac -> $currentMac');
        await _broadcastIdentityUpdate(currentMac);
      }

      _lastKnownMac = currentMac;
    } catch (e) {
      LogService().log('BLEIdentity: Failed to check MAC change: $e');
    }
  }

  /// Get current MAC address (platform-specific)
  Future<String?> _getCurrentMac() async {
    // Note: Getting the local MAC address on Android requires
    // using BluetoothAdapter.getAddress() which may return a
    // different value than what's advertised due to MAC randomization.
    //
    // The actual implementation would need to use a MethodChannel
    // to call Android's BluetoothAdapter API.
    //
    // For now, we'll track the advertised MAC by observing
    // when we receive our own advertisements or through
    // the ble_peripheral library's callbacks.

    // TODO: Implement platform channel to get MAC address
    return null;
  }

  /// Broadcast identity update to connected peers
  Future<void> _broadcastIdentityUpdate(String newMac) async {
    final update = BLEIdentityUpdate(
      callsign: callsign,
      deviceId: deviceId,
      mac: newMac,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    // Notify local listeners
    _identityChangeController.add(update);

    // Broadcast to connected peers
    if (_broadcastCallback != null) {
      try {
        final json = jsonEncode(update.toJson());
        await _broadcastCallback!(json);
        LogService().log('BLEIdentity: Broadcast identity update');
      } catch (e) {
        LogService().log('BLEIdentity: Failed to broadcast update: $e');
      }
    }
  }

  /// Handle incoming identity update from a peer
  void handleIdentityUpdate(String deviceAddress, Map<String, dynamic> json) {
    try {
      final update = BLEIdentityUpdate.fromJson(json);
      LogService().log('BLEIdentity: Received identity update from '
          '${update.fullIdentity} (MAC: ${update.mac})');

      // Store in known identities
      _knownIdentities[update.fullIdentity] = update;

      // Notify listeners
      _identityChangeController.add(update);
    } catch (e) {
      LogService().log('BLEIdentity: Failed to parse identity update: $e');
    }
  }

  /// Known identities (callsign-deviceId -> last update)
  final Map<String, BLEIdentityUpdate> _knownIdentities = {};

  /// Get MAC address for a known identity
  String? getMacForIdentity(String fullIdentity) {
    return _knownIdentities[fullIdentity]?.mac;
  }

  /// Get all known identities
  List<BLEIdentityUpdate> get knownIdentities =>
      _knownIdentities.values.toList();

  /// Update MAC address for a known identity (from scan results)
  void updateMacForIdentity(String fullIdentity, String mac) {
    final existing = _knownIdentities[fullIdentity];
    if (existing != null) {
      _knownIdentities[fullIdentity] = BLEIdentityUpdate(
        callsign: existing.callsign,
        deviceId: existing.deviceId,
        mac: mac,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
    } else {
      // Parse the fullIdentity
      final parts = fullIdentity.split('-');
      if (parts.length == 2) {
        final parsedDeviceId = int.tryParse(parts[1]);
        if (parsedDeviceId != null) {
          _knownIdentities[fullIdentity] = BLEIdentityUpdate(
            callsign: parts[0],
            deviceId: parsedDeviceId,
            mac: mac,
            timestamp: DateTime.now().millisecondsSinceEpoch,
          );
        }
      }
    }
  }

  /// Dispose service
  void dispose() {
    _advertisementTimer?.cancel();
    _identityChangeController.close();
    _knownIdentities.clear();
  }
}

/// Parsed identity from BLE advertising data
class BLEParsedIdentity {
  final String callsign;
  final int? deviceId; // 1-15 or null for legacy format
  final String fullIdentity;

  BLEParsedIdentity({
    required this.callsign,
    this.deviceId,
    required this.fullIdentity,
  });

  @override
  String toString() => 'BLEParsedIdentity($fullIdentity)';
}

/// Identity update message
class BLEIdentityUpdate {
  final String callsign;
  final int deviceId; // 1-15
  final String mac;
  final int timestamp;

  String get fullIdentity => '$callsign-$deviceId';

  BLEIdentityUpdate({
    required this.callsign,
    required this.deviceId,
    required this.mac,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'type': 'identity_update',
        'callsign': callsign,
        'device_id': deviceId,
        'mac': mac,
        'timestamp': timestamp,
      };

  factory BLEIdentityUpdate.fromJson(Map<String, dynamic> json) {
    return BLEIdentityUpdate(
      callsign: json['callsign'] as String,
      deviceId: json['device_id'] as int,
      mac: json['mac'] as String,
      timestamp: json['timestamp'] as int,
    );
  }

  @override
  String toString() => 'BLEIdentityUpdate($fullIdentity, mac=$mac)';
}
