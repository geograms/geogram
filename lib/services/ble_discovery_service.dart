/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/foundation.dart' show VoidCallback, kIsWeb;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'ble_identity_service.dart';
import 'ble_permission_service.dart';
import 'log_service.dart';

/// Represents a device discovered via BLE
class BLEDevice {
  final String deviceId;       // BLE device platform ID (MAC address)
  String? callsign;            // From HELLO handshake or advertisement
  int? geogramDeviceId;        // Device ID 1-15 from advertisement (APRS SSID compatible)
  String? npub;                // From HELLO handshake (pubkey)
  String? nickname;            // From HELLO handshake
  double? latitude;            // From HELLO handshake
  double? longitude;           // From HELLO handshake
  int rssi;                    // Signal strength
  String proximity;            // "Very close", "Nearby", etc.
  DateTime lastSeen;
  BluetoothDevice? bleDevice;  // Reference to flutter_blue_plus device

  BLEDevice({
    required this.deviceId,
    this.callsign,
    this.geogramDeviceId,
    this.npub,
    this.nickname,
    this.latitude,
    this.longitude,
    required this.rssi,
    required this.proximity,
    required this.lastSeen,
    this.bleDevice,
  });

  /// Get full identity string (callsign-deviceId) for stable identification
  /// This remains constant even when MAC address changes (Android)
  /// Format is APRS SSID compatible (e.g., "X34PSK-7")
  String? get fullIdentity {
    if (callsign == null) return null;
    if (geogramDeviceId != null) {
      return '$callsign-$geogramDeviceId';
    }
    return callsign;
  }

  /// Get display name (nickname, callsign, or device ID)
  String get displayName => nickname ?? callsign ?? 'BLE Device $deviceId';
}

/// Service for discovering nearby Geogram devices via BLE
class BLEDiscoveryService {
  static final BLEDiscoveryService _instance = BLEDiscoveryService._internal();
  factory BLEDiscoveryService() => _instance;
  BLEDiscoveryService._internal();

  /// Geogram BLE Service UUID (0xFFF0)
  static const String serviceUUID = '0000fff0-0000-1000-8000-00805f9b34fb';

  /// Geogram marker in advertising data
  static const int geogramMarker = 0x3E; // '>'

  /// BLE GATT Characteristic UUIDs
  static const String writeCharUUID = '0000fff1-0000-1000-8000-00805f9b34fb';  // Write HELLO
  static const String notifyCharUUID = '0000fff2-0000-1000-8000-00805f9b34fb'; // Receive hello_ack

  /// Discovered devices
  final Map<String, BLEDevice> _discoveredDevices = {};

  /// Stream controller for device updates
  final _devicesController = StreamController<List<BLEDevice>>.broadcast();
  Stream<List<BLEDevice>> get devicesStream => _devicesController.stream;

  /// Scanning state
  bool _isScanning = false;
  bool get isScanning => _isScanning;

  /// Advertising state
  bool _isAdvertising = false;
  bool get isAdvertising => _isAdvertising;

  /// Scan results subscription
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  /// Check if BLE is supported and available
  Future<bool> isAvailable() async {
    try {
      // Log platform for debugging
      if (Platform.isLinux) {
        LogService().log('BLEDiscovery: Running on Linux - requires BlueZ');
      }

      // Check if Bluetooth adapter is available
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) {
        LogService().log('BLEDiscovery: Bluetooth not supported on this device');
        if (Platform.isLinux) {
          LogService().log('BLEDiscovery: On Linux, ensure BlueZ is installed and bluetooth service is running');
        }
        return false;
      }

      // Check adapter state
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        LogService().log('BLEDiscovery: Bluetooth is not enabled (state: $state)');
        if (Platform.isLinux && state == BluetoothAdapterState.off) {
          LogService().log('BLEDiscovery: Try: sudo systemctl start bluetooth');
        }
        return false;
      }

      LogService().log('BLEDiscovery: Bluetooth adapter available and enabled');
      return true;
    } catch (e) {
      LogService().log('BLEDiscovery: Error checking availability: $e');
      if (Platform.isLinux) {
        LogService().log('BLEDiscovery: Linux BLE error - check: 1) BlueZ installed, 2) bluetooth service running, 3) user in bluetooth group');
      }
      return false;
    }
  }

  /// Start scanning for nearby Geogram devices
  Future<void> startScanning({Duration timeout = const Duration(seconds: 10)}) async {
    if (_isScanning) {
      LogService().log('BLEDiscovery: Already scanning');
      return;
    }

    try {
      if (!await isAvailable()) {
        return;
      }

      _isScanning = true;
      LogService().log('BLEDiscovery: Starting BLE scan...');

      // Listen for scan results
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          // Log ALL devices found for debugging
          final name = result.device.platformName.isNotEmpty
              ? result.device.platformName
              : result.advertisementData.advName;
          final hasService = result.advertisementData.serviceUuids.any(
            (uuid) => uuid.toString().toLowerCase() == serviceUUID.toLowerCase()
          );
          LogService().log('BLEDiscovery: Found device ${result.device.remoteId.str} name="$name" rssi=${result.rssi} hasGeogramService=$hasService');
          _processAdvertisement(result);
        }
      });

      // Start scanning WITHOUT service filter to see all devices
      // Then filter in _processAdvertisement
      await FlutterBluePlus.startScan(
        // withServices: [Guid(serviceUUID)],  // Disabled for debugging
        timeout: timeout,
      );

      // Wait for scan to complete
      await Future.delayed(timeout);

      await stopScanning();
    } catch (e) {
      LogService().log('BLEDiscovery: Error starting scan: $e');
      _isScanning = false;
    }
  }

  /// Stop BLE scanning
  Future<void> stopScanning() async {
    if (!_isScanning) return;

    try {
      await FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      _isScanning = false;
      LogService().log('BLEDiscovery: Scan stopped. Found ${_discoveredDevices.length} devices');
    } catch (e) {
      LogService().log('BLEDiscovery: Error stopping scan: $e');
    }
  }

  /// Start advertising as a Geogram device so others can discover us
  /// Uses BLEIdentityService to build advertising data with device_id
  Future<void> startAdvertising(String callsign) async {
    if (_isAdvertising) {
      LogService().log('BLEDiscovery: Already advertising');
      return;
    }

    // BLE advertising only available on Android and iOS
    if (kIsWeb) {
      LogService().log('BLEDiscovery: Advertising not available on web');
      return;
    }

    // Check platform - ble_peripheral only works on Android/iOS
    // Linux/macOS/Windows can scan but not advertise
    if (!Platform.isAndroid && !Platform.isIOS) {
      if (Platform.isLinux) {
        LogService().log('BLEDiscovery: BLE advertising not supported on Linux (scanning works)');
      } else {
        LogService().log('BLEDiscovery: Advertising not available on this platform');
      }
      return;
    }

    try {
      // On Android 12+, check if BLUETOOTH_ADVERTISE permission is granted
      if (Platform.isAndroid) {
        // Check Bluetooth state first - this also checks basic permissions
        final state = await FlutterBluePlus.adapterState.first;
        if (state != BluetoothAdapterState.on) {
          LogService().log('BLEDiscovery: Bluetooth not enabled, skipping advertising');
          return;
        }

        // Check if we have advertise permission from permission service
        final permissionService = BLEPermissionService();
        if (!permissionService.hasAdvertisePermission) {
          // Try to request permission
          final granted = await permissionService.requestAllPermissions();
          if (!granted || !permissionService.hasAdvertisePermission) {
            LogService().log('BLEDiscovery: BLE advertise permission not granted');
            return;
          }
        }
      }

      // Initialize BLE peripheral
      await BlePeripheral.initialize();

      // Build advertising data using BLEIdentityService
      // Format: [0x3E marker][device_id: 2 bytes][callsign: up to 17 bytes]
      final identityService = BLEIdentityService();
      final advertisingData = identityService.buildAdvertisingData();

      // Start advertising with our service UUID and data
      await BlePeripheral.startAdvertising(
        services: [serviceUUID],
        localName: 'Geogram',
        manufacturerData: ManufacturerData(
          manufacturerId: 0xFFFF, // Test manufacturer ID
          data: advertisingData,
        ),
      );

      _isAdvertising = true;
      LogService().log('BLEDiscovery: Started advertising as ${identityService.fullIdentity}');
    } catch (e, stackTrace) {
      // SecurityException on Android means BLUETOOTH_ADVERTISE permission not granted
      final errorStr = e.toString();
      if (errorStr.contains('SecurityException') || errorStr.contains('BLUETOOTH_ADVERTISE')) {
        LogService().log('BLEDiscovery: BLUETOOTH_ADVERTISE permission not granted, advertising disabled');
      } else {
        LogService().log('BLEDiscovery: Error starting advertising: $e\n$stackTrace');
      }
      _isAdvertising = false;
    }
  }

  /// Stop advertising
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;

    // Only try to stop on platforms that support it
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      _isAdvertising = false;
      return;
    }

    try {
      await BlePeripheral.stopAdvertising();
      _isAdvertising = false;
      LogService().log('BLEDiscovery: Stopped advertising');
    } catch (e) {
      LogService().log('BLEDiscovery: Error stopping advertising: $e');
      _isAdvertising = false;
    }
  }

  /// Process a BLE advertisement
  void _processAdvertisement(ScanResult result) {
    // Check for Geogram service data
    final serviceData = result.advertisementData.serviceData;
    final data = serviceData[Guid(serviceUUID)];

    // Check for service data with our UUID
    if (data != null && data.isNotEmpty) {
      // Check for Geogram marker (first byte must be '>')
      if (data[0] == geogramMarker) {
        _addOrUpdateDevice(result, data);
        return;
      }
    }

    // Also check manufacturer data (0xFFFF = test manufacturer ID)
    final mfgData = result.advertisementData.manufacturerData;
    if (mfgData.isNotEmpty) {
      // Check each manufacturer entry
      for (final entry in mfgData.entries) {
        final mfgBytes = entry.value;
        if (mfgBytes.isNotEmpty && mfgBytes[0] == geogramMarker) {
          LogService().log('BLEDiscovery: Found Geogram device via manufacturer data: ${result.device.remoteId.str}');
          _addOrUpdateDevice(result, mfgBytes);
          return;
        }
      }
    }

    // Also accept devices advertising as "Geogram" by name
    final advName = result.advertisementData.advName;
    final platformName = result.device.platformName;
    if (advName == 'Geogram' || platformName == 'Geogram') {
      LogService().log('BLEDiscovery: Found Geogram device by name: ${result.device.remoteId.str}');
      // Try to extract callsign from manufacturer data if available
      List<int>? callsignData;
      if (mfgData.isNotEmpty) {
        for (final entry in mfgData.entries) {
          if (entry.value.isNotEmpty) {
            callsignData = entry.value;
            break;
          }
        }
      }
      _addOrUpdateDevice(result, callsignData);
      return;
    }
  }

  /// Add or update a discovered device
  void _addOrUpdateDevice(ScanResult result, List<int>? advertisingData) {
    final deviceId = result.device.remoteId.str;
    final rssi = result.rssi;
    final proximity = estimateProximity(rssi);

    // Parse identity from advertising data if available
    String? callsign;
    int? geogramDeviceId;

    if (advertisingData != null && advertisingData.length > 1) {
      try {
        // Use BLEIdentityService to parse advertising data
        // Format: [0x3E marker][device_id: 2 bytes][callsign: up to 17 bytes]
        final parsed = BLEIdentityService.parseAdvertisingData(
          Uint8List.fromList(advertisingData),
        );

        if (parsed != null) {
          callsign = parsed.callsign;
          geogramDeviceId = parsed.deviceId;
        } else {
          // Fallback: try legacy format [marker][callsign...]
          final callsignBytes = advertisingData.sublist(1);
          final endIndex = callsignBytes.indexOf(0);
          final effectiveBytes = endIndex > 0 ? callsignBytes.sublist(0, endIndex) : callsignBytes;
          callsign = utf8.decode(effectiveBytes, allowMalformed: true).trim();
          if (callsign.isEmpty) callsign = null;
        }
      } catch (e) {
        LogService().log('BLEDiscovery: Error parsing advertising data: $e');
      }
    }

    if (_discoveredDevices.containsKey(deviceId)) {
      // Update existing device
      final device = _discoveredDevices[deviceId]!;
      device.rssi = rssi;
      device.proximity = proximity;
      device.lastSeen = DateTime.now();
      if (callsign != null) device.callsign = callsign;
      if (geogramDeviceId != null) device.geogramDeviceId = geogramDeviceId;
    } else {
      // Add new device
      final newDevice = BLEDevice(
        deviceId: deviceId,
        callsign: callsign,
        geogramDeviceId: geogramDeviceId,
        rssi: rssi,
        proximity: proximity,
        lastSeen: DateTime.now(),
        bleDevice: result.device,
      );
      _discoveredDevices[deviceId] = newDevice;
      LogService().log('BLEDiscovery: Found new device: $deviceId '
          '(identity: ${newDevice.fullIdentity ?? "unknown"}, '
          'RSSI: $rssi, proximity: $proximity)');
    }

    // Update identity service with MAC-to-identity mapping
    if (callsign != null) {
      final fullIdentity = geogramDeviceId != null
          ? '$callsign-$geogramDeviceId'
          : callsign;
      BLEIdentityService().updateMacForIdentity(fullIdentity, deviceId);
    }

    _notifyListeners();
  }

  /// Connect to a device and perform HELLO handshake
  Future<bool> connectAndHello(BLEDevice device, Map<String, dynamic> helloEvent) async {
    if (device.bleDevice == null) {
      LogService().log('BLEDiscovery: No BLE device reference for ${device.deviceId}');
      return false;
    }

    try {
      LogService().log('BLEDiscovery: Connecting to ${device.deviceId}...');

      // Connect to the device
      await device.bleDevice!.connect(timeout: const Duration(seconds: 10));

      // Discover services
      final services = await device.bleDevice!.discoverServices();
      final geogramService = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase() == serviceUUID.toLowerCase(),
        orElse: () => throw Exception('Geogram service not found'),
      );

      // Find characteristics
      BluetoothCharacteristic? writeChar;
      BluetoothCharacteristic? notifyChar;

      for (final char in geogramService.characteristics) {
        final charUuid = char.uuid.toString().toLowerCase();
        if (charUuid == writeCharUUID.toLowerCase()) {
          writeChar = char;
        } else if (charUuid == notifyCharUUID.toLowerCase()) {
          notifyChar = char;
        }
      }

      if (writeChar == null) {
        throw Exception('Write characteristic not found');
      }

      // Set up notification listener for hello_ack
      Completer<Map<String, dynamic>?> helloAckCompleter = Completer();

      if (notifyChar != null) {
        await notifyChar.setNotifyValue(true);

        // Buffer for receiving chunked data
        List<int> receivedData = [];

        notifyChar.onValueReceived.listen((data) {
          // Accumulate data
          receivedData.addAll(data);

          // Try to parse as JSON (check if complete)
          try {
            final jsonStr = utf8.decode(receivedData);
            if (jsonStr.contains('}')) {
              final response = json.decode(jsonStr) as Map<String, dynamic>;
              if (!helloAckCompleter.isCompleted) {
                helloAckCompleter.complete(response);
              }
            }
          } catch (e) {
            // Not complete yet, wait for more data
          }
        });
      }

      // Build HELLO message
      final helloMessage = {
        'type': 'hello',
        'event': helloEvent,
      };

      // Send HELLO (chunked if needed)
      await _sendJsonOverBLE(writeChar, json.encode(helloMessage));

      // Wait for hello_ack (with timeout)
      final response = await helloAckCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );

      if (response != null && response['type'] == 'hello_ack' && response['success'] == true) {
        LogService().log('BLEDiscovery: HELLO handshake successful with ${device.deviceId}');

        // Extract device info from the response or original HELLO event
        // The responding device should send their own HELLO event in the ack
        if (response.containsKey('event')) {
          _parseHelloEvent(device, response['event'] as Map<String, dynamic>);
        }

        await device.bleDevice!.disconnect();
        return true;
      }

      await device.bleDevice!.disconnect();
      return false;
    } catch (e) {
      LogService().log('BLEDiscovery: Error during HELLO handshake: $e');
      try {
        await device.bleDevice?.disconnect();
      } catch (_) {}
      return false;
    }
  }

  /// Parse HELLO event and update device info
  void _parseHelloEvent(BLEDevice device, Map<String, dynamic> event) {
    final tags = event['tags'] as List<dynamic>?;
    if (tags == null) return;

    for (final tag in tags) {
      if (tag is List && tag.length >= 2) {
        final key = tag[0] as String;
        final value = tag[1] as String;

        switch (key) {
          case 'callsign':
            device.callsign = value;
            break;
          case 'nickname':
            device.nickname = value;
            break;
          case 'latitude':
            device.latitude = double.tryParse(value);
            break;
          case 'longitude':
            device.longitude = double.tryParse(value);
            break;
        }
      }
    }

    // Extract npub from pubkey
    final pubkey = event['pubkey'] as String?;
    if (pubkey != null) {
      device.npub = pubkey; // Store hex pubkey, can be converted to npub later
    }

    _notifyListeners();
  }

  /// Send JSON over BLE (chunked if needed)
  /// Uses 300-byte parcels with pauses between to avoid connection drops
  Future<void> _sendJsonOverBLE(BluetoothCharacteristic char, String jsonStr) async {
    final bytes = utf8.encode(jsonStr);
    final mtu = await char.device.mtu.first;
    final chunkSize = mtu - 3; // Leave room for ATT header
    const parcelSize = 280; // Max bytes per parcel (below 300 threshold)

    LogService().log('BLEDiscovery: Sending ${bytes.length} bytes (MTU: $mtu, chunk: $chunkSize, parcel: $parcelSize)');

    if (bytes.length <= chunkSize) {
      // Single write
      await char.write(bytes, withoutResponse: false);
    } else {
      // Send in parcels of ~280 bytes with longer pause between parcels
      final totalParcels = (bytes.length / parcelSize).ceil();
      LogService().log('BLEDiscovery: Sending ${bytes.length} bytes in $totalParcels parcels');

      for (int parcelStart = 0; parcelStart < bytes.length; parcelStart += parcelSize) {
        final parcelEnd = (parcelStart + parcelSize < bytes.length) ? parcelStart + parcelSize : bytes.length;
        final parcelNum = (parcelStart / parcelSize).floor() + 1;

        LogService().log('BLEDiscovery: Sending parcel $parcelNum/$totalParcels (bytes $parcelStart-$parcelEnd)');

        // Send this parcel in MTU-sized chunks
        for (int i = parcelStart; i < parcelEnd; i += chunkSize) {
          final end = (i + chunkSize < parcelEnd) ? i + chunkSize : parcelEnd;
          final chunk = bytes.sublist(i, end);

          try {
            await char.write(chunk, withoutResponse: true);
            // Small delay between chunks within a parcel
            await Future.delayed(const Duration(milliseconds: 30));
          } catch (e) {
            LogService().log('BLEDiscovery: Parcel $parcelNum chunk failed: $e');
            rethrow;
          }
        }

        // Longer pause between parcels to let BLE stack recover
        if (parcelEnd < bytes.length) {
          LogService().log('BLEDiscovery: Parcel $parcelNum complete, pausing before next...');
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      LogService().log('BLEDiscovery: All $totalParcels parcels sent successfully');
    }
  }

  /// Estimate proximity from RSSI
  static String estimateProximity(int rssi) {
    if (rssi > -50) return 'Very close';
    if (rssi > -70) return 'Nearby';
    if (rssi > -85) return 'In range';
    return 'Far';
  }

  /// Calculate approximate distance in meters from RSSI
  static double rssiToMeters(int rssi, {int txPower = -59}) {
    // txPower = RSSI at 1 meter (typically -59 dBm)
    // n = path-loss exponent (2.0 for free space, 2.7-4.3 indoors)
    const n = 2.5;
    return pow(10, (txPower - rssi) / (10 * n)).toDouble();
  }

  /// Get all discovered devices
  List<BLEDevice> getAllDevices() {
    return _discoveredDevices.values.toList()
      ..sort((a, b) {
        // Sort by RSSI (stronger signal first)
        return b.rssi.compareTo(a.rssi);
      });
  }

  /// Clear discovered devices
  void clearDevices() {
    _discoveredDevices.clear();
    _notifyListeners();
  }

  /// Remove stale devices (not seen in the last N seconds)
  void removeStaleDevices({Duration maxAge = const Duration(seconds: 30)}) {
    final now = DateTime.now();
    _discoveredDevices.removeWhere((id, device) {
      return now.difference(device.lastSeen) > maxAge;
    });
    _notifyListeners();
  }

  /// Notify listeners of changes
  void _notifyListeners() {
    _devicesController.add(getAllDevices());
  }

  // ============================================
  // Connection Pooling and Message Exchange
  // ============================================

  /// Connection pool for reusing BLE connections
  final Map<String, _BLEConnection> _connectionPool = {};

  /// Connection timeout for small data exchanges
  static const _connectionTimeout = Duration(minutes: 2);

  /// Threshold for keeping connection open (10KB)
  static const _largeDataThreshold = 10 * 1024;

  /// Send a message to a BLE device and wait for response
  Future<Map<String, dynamic>?> sendMessage(
    BLEDevice device,
    Map<String, dynamic> message, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (device.bleDevice == null) {
      LogService().log('BLEDiscovery: No BLE device reference for ${device.deviceId}');
      return null;
    }

    final messageJson = json.encode(message);
    final messageSize = utf8.encode(messageJson).length;
    final keepConnection = messageSize >= _largeDataThreshold;

    try {
      // Get or create connection
      final connection = await _getOrCreateConnection(device);
      if (connection == null) {
        return null;
      }

      LogService().log('BLEDiscovery: Connection ready, sending message ($messageSize bytes)');

      // Send message and wait for response
      final response = await connection.sendAndReceive(messageJson, timeout: timeout);
      LogService().log('BLEDiscovery: Message sent, response: ${response != null}');

      // Manage connection based on data size
      if (keepConnection) {
        // Large data - keep connection and reset timeout
        connection.resetTimeout();
        LogService().log('BLEDiscovery: Keeping connection for large data ($messageSize bytes)');
      } else {
        // Small data - schedule disconnect
        connection.scheduleDisconnect(_connectionTimeout);
      }

      return response;
    } catch (e) {
      LogService().log('BLEDiscovery: Error sending message: $e');
      // Remove failed connection from pool
      await _removeConnection(device.deviceId);
      return null;
    }
  }

  /// Get existing connection or create new one
  Future<_BLEConnection?> _getOrCreateConnection(BLEDevice device) async {
    final deviceId = device.deviceId;

    // Check for existing valid connection
    if (_connectionPool.containsKey(deviceId)) {
      final existing = _connectionPool[deviceId]!;
      if (existing.isConnected) {
        LogService().log('BLEDiscovery: Reusing existing connection to $deviceId');
        return existing;
      } else {
        // Connection is stale, remove it
        await _removeConnection(deviceId);
      }
    }

    // Create new connection
    // Get BluetoothDevice - either from device or create new from ID
    final bleDevice = device.bleDevice ?? BluetoothDevice.fromId(deviceId);

    try {
      LogService().log('BLEDiscovery: Creating new connection to $deviceId');
      LogService().log('BLEDiscovery: Using ${device.bleDevice != null ? "cached" : "new"} BluetoothDevice for $deviceId');

      await bleDevice.connect(timeout: const Duration(seconds: 10));

      // Discover services
      final services = await bleDevice.discoverServices();

      // Log all discovered services for debugging
      LogService().log('BLEDiscovery: Found ${services.length} services on $deviceId');
      for (final svc in services) {
        LogService().log('BLEDiscovery: Service: ${svc.uuid.toString()}');
      }

      // Match both short (fff0) and long UUID formats
      final shortServiceUUID = 'fff0';
      final geogramService = services.firstWhere(
        (s) {
          final uuid = s.uuid.toString().toLowerCase();
          return uuid == serviceUUID.toLowerCase() ||
                 uuid == shortServiceUUID ||
                 uuid.contains(shortServiceUUID);
        },
        orElse: () => throw Exception('Geogram service not found (looking for $serviceUUID or $shortServiceUUID)'),
      );

      // Find characteristics (match both short and long UUID formats)
      BluetoothCharacteristic? writeChar;
      BluetoothCharacteristic? notifyChar;
      const shortWriteCharUUID = 'fff1';
      const shortNotifyCharUUID = 'fff2';

      LogService().log('BLEDiscovery: Found ${geogramService.characteristics.length} characteristics');
      for (final char in geogramService.characteristics) {
        final charUuid = char.uuid.toString().toLowerCase();
        LogService().log('BLEDiscovery: Characteristic: $charUuid');
        if (charUuid == writeCharUUID.toLowerCase() || charUuid == shortWriteCharUUID || charUuid.contains(shortWriteCharUUID)) {
          writeChar = char;
        } else if (charUuid == notifyCharUUID.toLowerCase() || charUuid == shortNotifyCharUUID || charUuid.contains(shortNotifyCharUUID)) {
          notifyChar = char;
        }
      }

      if (writeChar == null || notifyChar == null) {
        throw Exception('Required characteristics not found (write: ${writeChar != null}, notify: ${notifyChar != null})');
      }

      // Request higher MTU for faster transfer
      try {
        final requestedMtu = await bleDevice.requestMtu(512);
        LogService().log('BLEDiscovery: Requested MTU 512, got $requestedMtu');
      } catch (e) {
        LogService().log('BLEDiscovery: MTU request failed: $e');
      }

      // Subscribe to notifications
      await notifyChar.setNotifyValue(true);
      LogService().log('BLEDiscovery: Subscribed to notifications');

      // Small delay to let subscription stabilize on the server side
      await Future.delayed(const Duration(milliseconds: 200));

      // Create connection object
      final connection = _BLEConnection(
        deviceId: deviceId,
        device: bleDevice,
        writeChar: writeChar,
        notifyChar: notifyChar,
        onDisconnect: () => _removeConnection(deviceId),
      );

      _connectionPool[deviceId] = connection;
      LogService().log('BLEDiscovery: Connection established to $deviceId');

      return connection;
    } catch (e) {
      LogService().log('BLEDiscovery: Failed to connect to $deviceId: $e');
      try {
        await bleDevice.disconnect();
      } catch (_) {}
      return null;
    }
  }

  /// Remove connection from pool and disconnect
  Future<void> _removeConnection(String deviceId) async {
    final connection = _connectionPool.remove(deviceId);
    if (connection != null) {
      await connection.dispose();
      LogService().log('BLEDiscovery: Connection to $deviceId removed from pool');
    }
  }

  /// Close all pooled connections
  Future<void> closeAllConnections() async {
    for (final deviceId in _connectionPool.keys.toList()) {
      await _removeConnection(deviceId);
    }
  }

  /// Dispose resources
  void dispose() {
    stopScanning();
    stopAdvertising();
    closeAllConnections();
    _devicesController.close();
  }
}

/// Internal class to manage a single BLE connection
class _BLEConnection {
  final String deviceId;
  final BluetoothDevice device;
  final BluetoothCharacteristic writeChar;
  final BluetoothCharacteristic notifyChar;
  final VoidCallback onDisconnect;

  bool _isConnected = true;
  Timer? _disconnectTimer;
  StreamSubscription<List<int>>? _notifySubscription;

  // Buffer for receiving chunked data
  final List<int> _receiveBuffer = [];

  // Pending request completers
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  _BLEConnection({
    required this.deviceId,
    required this.device,
    required this.writeChar,
    required this.notifyChar,
    required this.onDisconnect,
  }) {
    // Listen to notifications
    _notifySubscription = notifyChar.onValueReceived.listen(_handleNotification);

    // Listen for disconnection
    device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _isConnected = false;
        onDisconnect();
      }
    });
  }

  bool get isConnected => _isConnected;

  /// Handle incoming notification data
  void _handleNotification(List<int> data) {
    _receiveBuffer.addAll(data);

    // Try to parse as complete JSON
    try {
      final jsonStr = utf8.decode(_receiveBuffer);

      // Check if JSON is complete
      if (jsonStr.contains('}')) {
        final response = json.decode(jsonStr) as Map<String, dynamic>;
        _receiveBuffer.clear();

        // Complete pending request if ID matches
        final messageId = response['id'] as String?;
        if (messageId != null && _pendingRequests.containsKey(messageId)) {
          _pendingRequests[messageId]!.complete(response);
          _pendingRequests.remove(messageId);
        }
      }
    } catch (e) {
      // JSON not complete yet, wait for more chunks
    }
  }

  /// Send message and wait for response
  Future<Map<String, dynamic>?> sendAndReceive(
    String messageJson, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    // Parse message to get ID
    final message = json.decode(messageJson) as Map<String, dynamic>;
    final messageId = message['id'] as String?;

    if (messageId == null) {
      throw Exception('Message must have an ID');
    }

    // Create completer for response
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[messageId] = completer;

    try {
      // Send the message (chunked if needed)
      await _sendChunked(messageJson);

      // Wait for response with timeout
      final response = await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pendingRequests.remove(messageId);
          throw TimeoutException('No response received', timeout);
        },
      );

      return response;
    } catch (e) {
      _pendingRequests.remove(messageId);
      rethrow;
    }
  }

  /// Send data with chunking if needed
  /// Uses 280-byte parcels with pauses between to avoid connection drops
  Future<void> _sendChunked(String jsonStr) async {
    final bytes = utf8.encode(jsonStr);
    final mtu = await device.mtu.first;
    final chunkSize = mtu - 3; // Leave room for ATT header
    const parcelSize = 280; // Max bytes per parcel (below 300 threshold)

    LogService().log('BLEDiscovery: Sending ${bytes.length} bytes (MTU: $mtu, chunk: $chunkSize, parcel: $parcelSize)');

    if (bytes.length <= chunkSize) {
      // Single write for small messages
      await writeChar.write(bytes, withoutResponse: false);
      LogService().log('BLEDiscovery: Message written successfully');
    } else {
      // Send in parcels of ~280 bytes with longer pause between parcels
      final totalParcels = (bytes.length / parcelSize).ceil();
      LogService().log('BLEDiscovery: Sending ${bytes.length} bytes in $totalParcels parcels');

      for (int parcelStart = 0; parcelStart < bytes.length; parcelStart += parcelSize) {
        final parcelEnd = (parcelStart + parcelSize < bytes.length) ? parcelStart + parcelSize : bytes.length;
        final parcelNum = (parcelStart / parcelSize).floor() + 1;

        LogService().log('BLEDiscovery: Sending parcel $parcelNum/$totalParcels (bytes $parcelStart-$parcelEnd)');

        // Send this parcel in MTU-sized chunks
        for (int i = parcelStart; i < parcelEnd; i += chunkSize) {
          final end = (i + chunkSize < parcelEnd) ? i + chunkSize : parcelEnd;
          final chunk = bytes.sublist(i, end);

          try {
            await writeChar.write(chunk, withoutResponse: true);
            // Small delay between chunks within a parcel
            await Future.delayed(const Duration(milliseconds: 30));
          } catch (e) {
            LogService().log('BLEDiscovery: Parcel $parcelNum chunk failed: $e');
            rethrow;
          }
        }

        // Longer pause between parcels to let BLE stack recover
        if (parcelEnd < bytes.length) {
          LogService().log('BLEDiscovery: Parcel $parcelNum complete, pausing before next...');
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      LogService().log('BLEDiscovery: All $totalParcels parcels sent successfully');
    }
  }

  /// Schedule automatic disconnect after timeout
  void scheduleDisconnect(Duration timeout) {
    _disconnectTimer?.cancel();
    _disconnectTimer = Timer(timeout, () {
      LogService().log('BLEDiscovery: Connection timeout, disconnecting $deviceId');
      dispose();
      onDisconnect();
    });
  }

  /// Reset disconnect timer (for active connections)
  void resetTimeout() {
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
  }

  /// Dispose connection
  Future<void> dispose() async {
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    await _notifySubscription?.cancel();
    _pendingRequests.clear();
    _receiveBuffer.clear();

    if (_isConnected) {
      try {
        await device.disconnect();
      } catch (_) {}
      _isConnected = false;
    }
  }
}
