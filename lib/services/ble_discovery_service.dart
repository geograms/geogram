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
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'log_service.dart';

/// Represents a device discovered via BLE
class BLEDevice {
  final String deviceId;       // BLE device platform ID
  String? callsign;            // From HELLO handshake
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
    this.npub,
    this.nickname,
    this.latitude,
    this.longitude,
    required this.rssi,
    required this.proximity,
    required this.lastSeen,
    this.bleDevice,
  });

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
      // Check if Bluetooth adapter is available
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) {
        LogService().log('BLEDiscovery: Bluetooth not supported on this device');
        return false;
      }

      // Check adapter state
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        LogService().log('BLEDiscovery: Bluetooth is not enabled (state: $state)');
        return false;
      }

      return true;
    } catch (e) {
      LogService().log('BLEDiscovery: Error checking availability: $e');
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
          _processAdvertisement(result);
        }
      });

      // Start scanning with service UUID filter
      await FlutterBluePlus.startScan(
        withServices: [Guid(serviceUUID)],
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
  Future<void> startAdvertising(String callsign) async {
    if (_isAdvertising) {
      LogService().log('BLEDiscovery: Already advertising');
      return;
    }

    // BLE advertising not available on web or desktop (Linux/Windows/macOS)
    if (kIsWeb) {
      LogService().log('BLEDiscovery: Advertising not available on web');
      return;
    }

    try {
      // Initialize BLE peripheral
      await BlePeripheral.initialize();

      // Build advertising data: [marker][callsign]
      final List<int> serviceData = [geogramMarker, ...utf8.encode(callsign)];

      // Limit to 20 bytes (BLE advertising limit minus overhead)
      final truncatedData = serviceData.length > 20
          ? Uint8List.fromList(serviceData.sublist(0, 20))
          : Uint8List.fromList(serviceData);

      // Start advertising with our service UUID and data
      await BlePeripheral.startAdvertising(
        services: [serviceUUID],
        localName: 'Geogram',
        manufacturerData: ManufacturerData(
          manufacturerId: 0xFFFF, // Test manufacturer ID
          data: truncatedData,
        ),
      );

      _isAdvertising = true;
      LogService().log('BLEDiscovery: Started advertising as $callsign');
    } catch (e) {
      LogService().log('BLEDiscovery: Error starting advertising: $e');
      _isAdvertising = false;
    }
  }

  /// Stop advertising
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;

    try {
      await BlePeripheral.stopAdvertising();
      _isAdvertising = false;
      LogService().log('BLEDiscovery: Stopped advertising');
    } catch (e) {
      LogService().log('BLEDiscovery: Error stopping advertising: $e');
    }
  }

  /// Process a BLE advertisement
  void _processAdvertisement(ScanResult result) {
    // Check for Geogram service data
    final serviceData = result.advertisementData.serviceData;
    final data = serviceData[Guid(serviceUUID)];

    // Only accept devices with our service UUID and data
    if (data == null || data.isEmpty) {
      // No Geogram service data - ignore this device
      return;
    }

    // Check for Geogram marker (first byte must be '>')
    if (data[0] != geogramMarker) {
      LogService().log('BLEDiscovery: Device ${result.device.remoteId.str} has service but no Geogram marker');
      return;
    }

    _addOrUpdateDevice(result, data);
  }

  /// Add or update a discovered device
  void _addOrUpdateDevice(ScanResult result, List<int>? advertisingData) {
    final deviceId = result.device.remoteId.str;
    final rssi = result.rssi;
    final proximity = estimateProximity(rssi);

    // Parse callsign from advertising data if available
    String? callsign;
    if (advertisingData != null && advertisingData.length > 1) {
      // Skip the marker byte and try to extract callsign
      try {
        // Advertising data format: [marker][callsign bytes...]
        final callsignBytes = advertisingData.sublist(1);
        // Find null terminator or end
        final endIndex = callsignBytes.indexOf(0);
        final effectiveBytes = endIndex > 0 ? callsignBytes.sublist(0, endIndex) : callsignBytes;
        callsign = utf8.decode(effectiveBytes, allowMalformed: true).trim();
        if (callsign.isEmpty) callsign = null;
      } catch (e) {
        LogService().log('BLEDiscovery: Error parsing callsign: $e');
      }
    }

    if (_discoveredDevices.containsKey(deviceId)) {
      // Update existing device
      final device = _discoveredDevices[deviceId]!;
      device.rssi = rssi;
      device.proximity = proximity;
      device.lastSeen = DateTime.now();
      if (callsign != null) device.callsign = callsign;
    } else {
      // Add new device
      _discoveredDevices[deviceId] = BLEDevice(
        deviceId: deviceId,
        callsign: callsign,
        rssi: rssi,
        proximity: proximity,
        lastSeen: DateTime.now(),
        bleDevice: result.device,
      );
      LogService().log('BLEDiscovery: Found new device: $deviceId (callsign: $callsign, RSSI: $rssi, proximity: $proximity)');
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
  Future<void> _sendJsonOverBLE(BluetoothCharacteristic char, String jsonStr) async {
    final bytes = utf8.encode(jsonStr);
    final mtu = await char.device.mtu.first;
    final chunkSize = mtu - 3; // Leave room for ATT header

    LogService().log('BLEDiscovery: Sending ${bytes.length} bytes, MTU: $mtu, chunk size: $chunkSize');

    if (bytes.length <= chunkSize) {
      // Single write
      await char.write(bytes, withoutResponse: false);
    } else {
      // Chunked write
      for (int i = 0; i < bytes.length; i += chunkSize) {
        final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
        final chunk = bytes.sublist(i, end);
        await char.write(chunk, withoutResponse: false);
        await Future.delayed(const Duration(milliseconds: 20)); // Small delay between chunks
      }
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

  /// Dispose resources
  void dispose() {
    stopScanning();
    stopAdvertising();
    _devicesController.close();
  }
}
