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
import 'app_args.dart';
import 'ble_identity_service.dart';
import 'ble_permission_service.dart';
import 'log_service.dart';
import '../util/event_bus.dart';

/// Represents a device discovered via BLE
class BLEDevice {
  final String deviceId; // BLE device platform ID (MAC address)
  String? callsign; // From HELLO handshake or advertisement
  int?
  geogramDeviceId; // Device ID 1-15 from advertisement (APRS SSID compatible)
  String? npub; // From HELLO handshake (pubkey)
  String? nickname; // From HELLO handshake
  double? latitude; // From HELLO handshake
  double? longitude; // From HELLO handshake
  String? classicMac; // From HELLO_ACK for BLE+ pairing
  int rssi; // Signal strength
  String proximity; // "Very close", "Nearby", etc.
  DateTime lastSeen;
  BluetoothDevice? bleDevice; // Reference to flutter_blue_plus device

  BLEDevice({
    required this.deviceId,
    this.callsign,
    this.geogramDeviceId,
    this.npub,
    this.nickname,
    this.latitude,
    this.longitude,
    this.classicMac,
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

  /// Geogram BLE Service UUID (0xFFE0 - custom, avoids conflict with Android's PKOC at 0xFFF0)
  static const String serviceUUID = '0000ffe0-0000-1000-8000-00805f9b34fb';

  /// Geogram marker in advertising data
  static const int geogramMarker = 0x3E; // '>'

  /// BLE GATT Characteristic UUIDs
  static const String writeCharUUID =
      '0000fff1-0000-1000-8000-00805f9b34fb'; // Write HELLO
  static const String notifyCharUUID =
      '0000fff2-0000-1000-8000-00805f9b34fb'; // Receive hello_ack

  /// Discovered devices
  final Map<String, BLEDevice> _discoveredDevices = {};

  /// Stream controller for device updates
  final _devicesController = StreamController<List<BLEDevice>>.broadcast();
  Stream<List<BLEDevice>> get devicesStream => _devicesController.stream;

  /// Stream controller for incoming chat messages from GATT client connections
  /// This allows messages received via GATT client notifications to be processed
  /// by higher-level services (like BleTransport)
  final _incomingChatsController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get incomingChatsFromClient =>
      _incomingChatsController.stream;

  /// Scanning state
  bool _isScanning = false;
  bool get isScanning => _isScanning;

  /// Advertising state
  bool _isAdvertising = false;
  bool get isAdvertising => _isAdvertising;

  /// Periodic scanning state
  bool _isPeriodicScanningActive = false;
  bool get isPeriodicScanning => _isPeriodicScanningActive;

  /// Periodic scan timer
  Timer? _periodicScanTimer;

  /// Scan configuration
  static const Duration _periodicScanInterval = Duration(seconds: 45);
  static const Duration _periodicScanDuration = Duration(seconds: 8);

  /// Scan results subscription
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  /// Guard to avoid scan/connect contention on Linux BlueZ.
  bool _connectionInProgress = false;

  /// Event bus for connection state changes
  final EventBus _eventBus = EventBus();

  /// Bluetooth adapter state subscription
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;

  /// Last known Bluetooth availability state (to avoid duplicate events)
  bool _lastBluetoothAvailable = false;

  /// Initialize the service and start monitoring Bluetooth adapter state
  Future<void> initialize() async {
    if (kIsWeb) return; // BLE not supported on web

    // Check initial state
    try {
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) {
        LogService().log('BLEDiscovery: Bluetooth not supported');
        return;
      }

      // Monitor adapter state changes
      _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
        final isAvailable = state == BluetoothAdapterState.on;
        _fireBluetoothStateChanged(isAvailable);
      });

      // Fire initial state
      final state = await FlutterBluePlus.adapterState.first;
      final isAvailable = state == BluetoothAdapterState.on;
      _fireBluetoothStateChanged(isAvailable);
    } catch (e) {
      LogService().log('BLEDiscovery: Error initializing: $e');
    }
  }

  /// Fire Bluetooth state changed event (only if state actually changed)
  void _fireBluetoothStateChanged(bool isAvailable) {
    if (isAvailable == _lastBluetoothAvailable) {
      return; // No change, don't fire duplicate event
    }

    _lastBluetoothAvailable = isAvailable;
    LogService().log(
      'ConnectionStateChanged: bluetooth ${isAvailable ? "available" : "unavailable"}',
    );

    _eventBus.fire(
      ConnectionStateChangedEvent(
        connectionType: ConnectionType.bluetooth,
        isConnected: isAvailable,
      ),
    );
  }

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
        LogService().log(
          'BLEDiscovery: Bluetooth not supported on this device',
        );
        if (Platform.isLinux) {
          LogService().log(
            'BLEDiscovery: On Linux, ensure BlueZ is installed and bluetooth service is running',
          );
        }
        return false;
      }

      // Check adapter state
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        LogService().log(
          'BLEDiscovery: Bluetooth is not enabled (state: $state)',
        );
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
        LogService().log(
          'BLEDiscovery: Linux BLE error - check: 1) BlueZ installed, 2) bluetooth service running, 3) user in bluetooth group',
        );
      }
      return false;
    }
  }

  /// Start scanning for nearby Geogram devices
  Future<void> startScanning({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    // Refuse to scan in internet-only mode
    if (AppArgs().internetOnly) {
      LogService().log('BLEDiscovery: Scanning disabled in internet-only mode');
      return;
    }

    if (_isScanning) {
      LogService().log('BLEDiscovery: Already scanning');
      return;
    }

    if (_connectionInProgress) {
      LogService().log(
        'BLEDiscovery: Skipping scan (BLE connection in progress)',
      );
      return;
    }

    try {
      if (!await isAvailable()) {
        return;
      }

      _isScanning = true;
      LogService().log('BLEDiscovery: Starting BLE scan...');

      // Fire UI status event
      _eventBus.fire(
        BLEStatusEvent(
          status: BLEStatusType.scanning,
          message: 'Scanning for nearby devices...',
        ),
      );

      // Listen for scan results
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
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
      LogService().log(
        'BLEDiscovery: Scan stopped. Found ${_discoveredDevices.length} devices',
      );

      // Fire UI status event
      _eventBus.fire(
        BLEStatusEvent(
          status: BLEStatusType.scanComplete,
          message: 'Found ${_discoveredDevices.length} nearby devices',
        ),
      );
    } catch (e) {
      LogService().log('BLEDiscovery: Error stopping scan: $e');
    }
  }

  /// Start periodic background scanning for peer devices
  /// Scans for 8 seconds every 45 seconds to balance discovery vs battery
  Future<void> startPeriodicScanning() async {
    // Refuse in internet-only mode
    if (AppArgs().internetOnly) {
      LogService().log(
        'BLEDiscovery: Periodic scanning disabled in internet-only mode',
      );
      return;
    }

    if (_isPeriodicScanningActive) {
      LogService().log('BLEDiscovery: Periodic scanning already active');
      return;
    }

    // Check if BLE is available
    if (!await isAvailable()) {
      LogService().log(
        'BLEDiscovery: BLE not available, cannot start periodic scanning',
      );
      return;
    }

    _isPeriodicScanningActive = true;
    LogService().log(
      'BLEDiscovery: Starting periodic scanning (45s interval, 8s duration)',
    );

    // Run first scan immediately
    _runPeriodicScan();

    // Then schedule periodic scans
    _periodicScanTimer = Timer.periodic(_periodicScanInterval, (_) {
      _runPeriodicScan();
    });
  }

  /// Stop periodic scanning
  Future<void> stopPeriodicScanning() async {
    if (!_isPeriodicScanningActive) return;

    _periodicScanTimer?.cancel();
    _periodicScanTimer = null;
    _isPeriodicScanningActive = false;

    // Stop any active scan
    if (_isScanning) {
      await stopScanning();
    }

    LogService().log('BLEDiscovery: Stopped periodic scanning');
  }

  /// Run a single periodic scan cycle
  Future<void> _runPeriodicScan() async {
    // Skip if already scanning (manual scan in progress)
    if (_isScanning) {
      LogService().log(
        'BLEDiscovery: Skipping periodic scan (manual scan active)',
      );
      return;
    }

    // Skip while establishing a connection; scanning can interrupt connect/discovery
    if (_connectionInProgress) {
      LogService().log(
        'BLEDiscovery: Skipping periodic scan (connection in progress)',
      );
      return;
    }

    // On Linux BlueZ, avoid periodic scanning while a GATT link is active
    if (_connectionPool.isNotEmpty) {
      LogService().log(
        'BLEDiscovery: Skipping periodic scan (active BLE connection)',
      );
      return;
    }

    // Check if BLE is still available
    if (!await isAvailable()) {
      LogService().log(
        'BLEDiscovery: BLE not available, skipping periodic scan',
      );
      return;
    }

    try {
      LogService().log('BLEDiscovery: Running periodic scan cycle...');
      await startScanning(timeout: _periodicScanDuration);

      // Clean up devices not seen in 90 seconds (2 scan cycles)
      removeStaleDevices(maxAge: const Duration(seconds: 90));

      LogService().log(
        'BLEDiscovery: Periodic scan complete - ${_discoveredDevices.length} devices known',
      );
    } catch (e) {
      LogService().log('BLEDiscovery: Periodic scan error: $e');
      // Continue scanning on next cycle despite error
    }
  }

  /// Start advertising as a Geogram device so others can discover us
  /// Uses BLEIdentityService to build advertising data with device_id
  Future<void> startAdvertising(String callsign) async {
    // Refuse to advertise in internet-only mode
    if (AppArgs().internetOnly) {
      LogService().log(
        'BLEDiscovery: Advertising disabled in internet-only mode',
      );
      return;
    }

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
        LogService().log(
          'BLEDiscovery: BLE advertising not supported on Linux (scanning works)',
        );
      } else {
        LogService().log(
          'BLEDiscovery: Advertising not available on this platform',
        );
      }
      return;
    }

    try {
      // On Android 12+, check if BLUETOOTH_ADVERTISE permission is granted
      if (Platform.isAndroid) {
        // Check Bluetooth state first - this also checks basic permissions
        final state = await FlutterBluePlus.adapterState.first;
        if (state != BluetoothAdapterState.on) {
          LogService().log(
            'BLEDiscovery: Bluetooth not enabled, skipping advertising',
          );
          return;
        }

        // Check if we have advertise permission from permission service
        final permissionService = BLEPermissionService();
        if (!permissionService.hasAdvertisePermission) {
          // Try to request permission
          final granted = await permissionService.requestAllPermissions();
          if (!granted || !permissionService.hasAdvertisePermission) {
            LogService().log(
              'BLEDiscovery: BLE advertise permission not granted',
            );
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
      // Note: We don't set localName to avoid changing the user's Bluetooth device name
      // Device identification is done via manufacturerData containing callsign
      await BlePeripheral.startAdvertising(
        services: [serviceUUID],
        manufacturerData: ManufacturerData(
          manufacturerId: 0xFFFF, // Test manufacturer ID
          data: advertisingData,
        ),
      );

      _isAdvertising = true;
      LogService().log(
        'BLEDiscovery: Started advertising as ${identityService.fullIdentity}',
      );

      // Fire UI status event
      _eventBus.fire(
        BLEStatusEvent(
          status: BLEStatusType.advertising,
          message: 'Broadcasting as ${identityService.fullIdentity}',
          deviceCallsign: callsign,
        ),
      );
    } catch (e, stackTrace) {
      // SecurityException on Android means BLUETOOTH_ADVERTISE permission not granted
      final errorStr = e.toString();
      if (errorStr.contains('SecurityException') ||
          errorStr.contains('BLUETOOTH_ADVERTISE')) {
        LogService().log(
          'BLEDiscovery: BLUETOOTH_ADVERTISE permission not granted, advertising disabled',
        );
      } else {
        LogService().log(
          'BLEDiscovery: Error starting advertising: $e\n$stackTrace',
        );
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
        LogService().log(
          'BLEDiscovery: Found Geogram device via serviceData: ${result.device.remoteId.str}',
        );
        _addOrUpdateDevice(result, data);
        return;
      }
    }

    // Also check manufacturer data (0xFFFF = test manufacturer ID)
    final mfgData = result.advertisementData.manufacturerData;
    if (mfgData.isNotEmpty) {
      // Check each manufacturer entry
      for (final entry in mfgData.entries) {
        final raw = entry.value;
        if (raw.isEmpty) continue;

        // Normal case: marker at index 0
        if (raw[0] == geogramMarker) {
          LogService().log(
            'BLEDiscovery: Found Geogram device via manufacturer data: ${result.device.remoteId.str}',
          );
          _addOrUpdateDevice(result, raw);
          return;
        }

        // BlueZ variants sometimes prepend bytes before payload; recover marker.
        final markerIndex = raw.indexOf(geogramMarker);
        if (markerIndex > 0) {
          final recovered = raw.sublist(markerIndex);
          LogService().log(
            'BLEDiscovery: Recovered Geogram marker at offset $markerIndex for ${result.device.remoteId.str}',
          );
          _addOrUpdateDevice(result, recovered);
          return;
        }

        // Fallback for payloads missing marker but still in Geogram format:
        // [device_id][callsign...], typically under manufacturer 0xFFFF.
        if (entry.key == 0xFFFF &&
            raw.length >= 2 &&
            raw[0] >= 1 &&
            raw[0] <= 15) {
          final firstCallsignByte = raw[1];
          final looksAsciiCallsign =
              (firstCallsignByte >= 0x30 && firstCallsignByte <= 0x39) ||
              (firstCallsignByte >= 0x41 && firstCallsignByte <= 0x5A);
          if (looksAsciiCallsign) {
            final synthesized = <int>[geogramMarker, ...raw];
            LogService().log(
              'BLEDiscovery: Recovered Geogram payload without marker for ${result.device.remoteId.str}',
            );
            _addOrUpdateDevice(result, synthesized);
            return;
          }
        }

        // Also accept explicit Geogram local name for devices with malformed payloads.
        if (entry.key == 0xFFFF &&
            (result.advertisementData.advName == 'Geogram' ||
                result.device.platformName == 'Geogram')) {
          LogService().log(
            'BLEDiscovery: Accepting Geogram-name device with non-standard manufacturer payload: ${result.device.remoteId.str}',
          );
          _addOrUpdateDevice(result, raw);
          return;
        }
      }
    }

    // Also accept devices advertising as "Geogram" by name
    final advName = result.advertisementData.advName;
    final platformName = result.device.platformName;
    if (advName == 'Geogram' || platformName == 'Geogram') {
      LogService().log(
        'BLEDiscovery: Found Geogram device by name: ${result.device.remoteId.str}',
      );
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
          final effectiveBytes = endIndex > 0
              ? callsignBytes.sublist(0, endIndex)
              : callsignBytes;
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
      LogService().log(
        'BLEDiscovery: Found new device: $deviceId '
        '(identity: ${newDevice.fullIdentity ?? "unknown"}, '
        'RSSI: $rssi, proximity: $proximity)',
      );

      // Clean up stale entries for the same callsign with different MAC addresses
      // BLE devices rotate addresses, so we only need the freshest address per callsign
      if (callsign != null) {
        final upperCallsign = callsign.toUpperCase();
        final staleEntries = _discoveredDevices.entries
            .where(
              (e) =>
                  e.key != deviceId &&
                  e.value.callsign?.toUpperCase() == upperCallsign,
            )
            .toList();

        for (final entry in staleEntries) {
          LogService().log(
            'BLEDiscovery: Removing stale address ${entry.key} for $callsign (new address: $deviceId)',
          );
          _discoveredDevices.remove(entry.key);
        }
      }

      // Fire UI status event for new device
      _eventBus.fire(
        BLEStatusEvent(
          status: BLEStatusType.deviceFound,
          message: 'Found: ${newDevice.fullIdentity ?? deviceId}',
          deviceCallsign: callsign,
        ),
      );
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
  /// Includes retry logic for Linux/BlueZ reliability
  Future<bool> connectAndHello(
    BLEDevice device,
    Map<String, dynamic> helloEvent,
  ) async {
    // Refuse in internet-only mode
    if (AppArgs().internetOnly) {
      LogService().log('BLEDiscovery: Connect disabled in internet-only mode');
      return false;
    }

    if (device.bleDevice == null) {
      LogService().log(
        'BLEDiscovery: No BLE device reference for ${device.deviceId}',
      );
      return false;
    }

    // Platform-specific timeout: Linux/BlueZ needs more time
    final connectTimeout = Platform.isLinux
        ? const Duration(seconds: 15)
        : const Duration(seconds: 10);

    try {
      LogService().log(
        'BLEDiscovery: Connecting to ${device.deviceId} for HELLO handshake...',
      );

      // Retry connection up to 3 times with exponential backoff
      bool connected = false;
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          LogService().log('BLEDiscovery: HELLO connection attempt $attempt/3');
          await device.bleDevice!.connect(timeout: connectTimeout);
          connected = true;
          break;
        } catch (e) {
          LogService().log(
            'BLEDiscovery: HELLO connection attempt $attempt failed: $e',
          );
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(milliseconds: 500 * attempt));
        }
      }

      if (!connected) {
        throw Exception('Failed to connect for HELLO');
      }

      // Discover services with retry
      List<BluetoothService> services = [];
      for (int attempt = 1; attempt <= 3; attempt++) {
        services = await device.bleDevice!.discoverServices();
        if (services.isNotEmpty) break;
        LogService().log(
          'BLEDiscovery: HELLO service discovery attempt $attempt returned empty',
        );
        await Future.delayed(Duration(milliseconds: 300 * attempt));
      }

      // Deduplicate services by UUID (BlueZ sometimes reports duplicates)
      final seenUuids = <String>{};
      final uniqueServices = <BluetoothService>[];
      for (final svc in services) {
        final uuid = svc.uuid.toString().toLowerCase();
        if (!seenUuids.contains(uuid)) {
          seenUuids.add(uuid);
          uniqueServices.add(svc);
        }
      }

      // Use helper to find Geogram service (handles BlueZ UUID formats)
      final geogramService = _findGeogramService(uniqueServices);
      if (geogramService == null) {
        LogService().log(
          'BLEDiscovery: HELLO: Geogram service FFE0 not found among ${services.length} services',
        );
        throw Exception('Geogram service not found');
      }

      // Find characteristics using helpers
      final writeChar = _findCharacteristic(
        geogramService.characteristics,
        'fff1',
        writeCharUUID,
      );
      final notifyChar = _findCharacteristic(
        geogramService.characteristics,
        'fff2',
        notifyCharUUID,
      );

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

        // Longer delay on Linux to let BlueZ stabilize
        final stabilizeDelay = Platform.isLinux
            ? const Duration(milliseconds: 300)
            : const Duration(milliseconds: 100);
        await Future.delayed(stabilizeDelay);
      }

      // Build HELLO message
      final helloMessage = {'type': 'hello', 'event': helloEvent};

      // Send HELLO (chunked if needed)
      await _sendJsonOverBLE(writeChar, json.encode(helloMessage));

      // Wait for hello_ack (with timeout) - longer on Linux
      final ackTimeout = Platform.isLinux
          ? const Duration(seconds: 8)
          : const Duration(seconds: 5);
      final response = await helloAckCompleter.future.timeout(
        ackTimeout,
        onTimeout: () => null,
      );

      if (response != null &&
          response['type'] == 'hello_ack' &&
          response['success'] == true) {
        LogService().log(
          'BLEDiscovery: HELLO handshake successful with ${device.deviceId}',
        );

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
    _applyHelloEvent(device, event);
    _notifyListeners();
  }

  void _applyHelloEvent(BLEDevice device, Map<String, dynamic> event) {
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
  }

  void updateFromHelloEvent(String deviceId, Map<String, dynamic> event) {
    final device = _discoveredDevices[deviceId];
    if (device == null) return;
    _applyHelloEvent(device, event);
    _notifyListeners();
  }

  /// Send JSON over BLE (chunked if needed)
  /// Uses 300-byte parcels with pauses between to avoid connection drops
  Future<void> _sendJsonOverBLE(
    BluetoothCharacteristic char,
    String jsonStr,
  ) async {
    final bytes = utf8.encode(jsonStr);
    final mtu = await _readCurrentMtu(char.device, phase: 'HELLO');
    final chunkSize = max(20, mtu - 3); // Leave room for ATT header
    const parcelSize = 280; // Max bytes per parcel (below 300 threshold)

    LogService().log(
      'BLEDiscovery: Sending ${bytes.length} bytes (MTU: $mtu, chunk: $chunkSize, parcel: $parcelSize)',
    );

    if (bytes.length <= chunkSize) {
      // Single write
      await char.write(bytes, withoutResponse: false);
    } else {
      // Send in parcels of ~280 bytes with longer pause between parcels
      final totalParcels = (bytes.length / parcelSize).ceil();
      LogService().log(
        'BLEDiscovery: Sending ${bytes.length} bytes in $totalParcels parcels',
      );

      for (
        int parcelStart = 0;
        parcelStart < bytes.length;
        parcelStart += parcelSize
      ) {
        final parcelEnd = (parcelStart + parcelSize < bytes.length)
            ? parcelStart + parcelSize
            : bytes.length;
        final parcelNum = (parcelStart / parcelSize).floor() + 1;

        LogService().log(
          'BLEDiscovery: Sending parcel $parcelNum/$totalParcels (bytes $parcelStart-$parcelEnd)',
        );

        // Send this parcel in MTU-sized chunks
        for (int i = parcelStart; i < parcelEnd; i += chunkSize) {
          final end = (i + chunkSize < parcelEnd) ? i + chunkSize : parcelEnd;
          final chunk = bytes.sublist(i, end);

          try {
            // Use write-with-response for parcel chunks to avoid dropped bytes on
            // Linux -> ESP32 links where large fire-and-forget writes can corrupt payloads.
            await char.write(chunk, withoutResponse: false);
            // Small delay between chunks within a parcel
            await Future.delayed(const Duration(milliseconds: 30));
          } catch (e) {
            LogService().log(
              'BLEDiscovery: Parcel $parcelNum chunk failed: $e',
            );
            rethrow;
          }
        }

        // Longer pause between parcels to let BLE stack recover
        if (parcelEnd < bytes.length) {
          LogService().log(
            'BLEDiscovery: Parcel $parcelNum complete, pausing before next...',
          );
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      LogService().log(
        'BLEDiscovery: All $totalParcels parcels sent successfully',
      );
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
    return _discoveredDevices.values.toList()..sort((a, b) {
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

  /// Update the Bluetooth Classic MAC for a discovered device
  void updateClassicMac(String deviceId, String classicMac) {
    final device = _discoveredDevices[deviceId];
    if (device == null) return;
    if (device.classicMac == classicMac) return;
    device.classicMac = classicMac;
    _notifyListeners();
  }

  // ============================================
  // Connection Pooling and Message Exchange
  // ============================================

  /// Connection pool for reusing BLE connections
  final Map<String, _BLEConnection> _connectionPool = {};

  /// Whether any pooled BLE connection is currently active.
  bool get hasActiveConnections =>
      _connectionPool.values.any((connection) => connection.isConnected);

  /// Whether we currently hold an active BLE link to the given callsign.
  bool hasActiveConnectionForCallsign(String callsign) {
    final target = callsign.toUpperCase();
    for (final entry in _connectionPool.entries) {
      final connection = entry.value;
      if (!connection.isConnected) continue;
      final discovered = _discoveredDevices[entry.key];
      if (discovered?.callsign?.toUpperCase() == target) {
        return true;
      }
    }
    return false;
  }

  /// Find the Geogram service from a list of discovered services
  /// Handles both short (ffe0) and full UUID formats from BlueZ
  /// Returns only a service that has both FFF1 (write) and FFF2 (notify) characteristics
  BluetoothService? _findGeogramService(List<BluetoothService> services) {
    const shortUUID = 'ffe0';
    final fullUUID = serviceUUID.toLowerCase();

    for (final service in services) {
      final uuid = service.uuid.toString().toLowerCase();
      if (uuid == fullUUID ||
          uuid == shortUUID ||
          uuid.contains(shortUUID) ||
          uuid.startsWith('0000ffe0')) {
        // Validate this service has the required characteristics
        final hasWrite =
            _findCharacteristic(
              service.characteristics,
              'fff1',
              writeCharUUID,
            ) !=
            null;
        final hasNotify =
            _findCharacteristic(
              service.characteristics,
              'fff2',
              notifyCharUUID,
            ) !=
            null;
        if (hasWrite && hasNotify) {
          return service;
        }
        LogService().log(
          'BLEDiscovery: Skipping FFE0 service without required characteristics (write=$hasWrite, notify=$hasNotify)',
        );
      }
    }
    return null; // Return null instead of throwing
  }

  /// Find a characteristic by UUID (handles short and long formats)
  BluetoothCharacteristic? _findCharacteristic(
    List<BluetoothCharacteristic> characteristics,
    String shortUUID,
    String fullUUID,
  ) {
    for (final char in characteristics) {
      final charUuid = char.uuid.toString().toLowerCase();
      if (charUuid == fullUUID.toLowerCase() ||
          charUuid == shortUUID ||
          charUuid.contains(shortUUID)) {
        return char;
      }
    }
    return null;
  }

  Future<int> _readCurrentMtu(
    BluetoothDevice device, {
    required String phase,
  }) async {
    const fallbackMtu = 23;
    try {
      final mtu = await device.mtu.first.timeout(const Duration(seconds: 2));
      if (mtu < fallbackMtu) return fallbackMtu;
      return mtu;
    } catch (e) {
      LogService().log(
        'BLEDiscovery: Failed to read MTU during $phase ($e), using fallback $fallbackMtu',
      );
      return fallbackMtu;
    }
  }

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
    // Refuse in internet-only mode
    if (AppArgs().internetOnly) {
      LogService().log(
        'BLEDiscovery: Send message disabled in internet-only mode',
      );
      return null;
    }

    if (device.bleDevice == null) {
      LogService().log(
        'BLEDiscovery: No BLE device reference for ${device.deviceId}',
      );
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

      // Prevent stale disconnect timers from dropping an active transfer.
      connection.resetTimeout();

      LogService().log(
        'BLEDiscovery: Connection ready, sending message ($messageSize bytes)',
      );

      // Send message and wait for response
      final response = await connection.sendAndReceive(
        messageJson,
        timeout: timeout,
      );
      LogService().log(
        'BLEDiscovery: Message sent, response: ${response != null}',
      );

      // Manage connection based on data size
      if (keepConnection) {
        // Large data - keep connection and reset timeout
        connection.resetTimeout();
        LogService().log(
          'BLEDiscovery: Keeping connection for large data ($messageSize bytes)',
        );
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

  /// Send a message to a BLE device without waiting for response (fire-and-forget)
  /// Used for async API requests where the response comes back later via notifications
  Future<bool> sendMessageAsync(
    BLEDevice device,
    Map<String, dynamic> message,
  ) async {
    // Refuse in internet-only mode
    if (AppArgs().internetOnly) {
      LogService().log(
        'BLEDiscovery: Send message disabled in internet-only mode',
      );
      return false;
    }

    if (device.bleDevice == null) {
      LogService().log(
        'BLEDiscovery: No BLE device reference for ${device.deviceId}',
      );
      return false;
    }

    final messageJson = json.encode(message);
    final messageSize = utf8.encode(messageJson).length;

    try {
      // Get or create connection
      final connection = await _getOrCreateConnection(device);
      if (connection == null) {
        LogService().log(
          'BLEDiscovery: Failed to get connection for async send',
        );
        return false;
      }

      // Prevent stale disconnect timers from dropping an active transfer.
      connection.resetTimeout();

      LogService().log(
        'BLEDiscovery: Connection ready, sending async message ($messageSize bytes)',
      );

      // Send message without waiting for response
      await connection.sendOnly(messageJson);
      LogService().log('BLEDiscovery: Async message sent successfully');

      // Keep the link warm for interactive chat/app browsing to reduce
      // reconnect churn and BlueZ stale-handle failures.
      connection.scheduleDisconnect(const Duration(minutes: 5));

      return true;
    } catch (e) {
      LogService().log('BLEDiscovery: Error sending async message: $e');
      // Remove failed connection from pool
      await _removeConnection(device.deviceId);
      return false;
    }
  }

  /// Get existing connection or create new one
  /// Includes retry logic with exponential backoff for Linux/BlueZ reliability
  Future<_BLEConnection?> _getOrCreateConnection(BLEDevice device) async {
    final deviceId = device.deviceId;

    // Check for existing valid connection
    if (_connectionPool.containsKey(deviceId)) {
      final existing = _connectionPool[deviceId]!;
      if (existing.isConnected) {
        LogService().log(
          'BLEDiscovery: Reusing existing connection to $deviceId',
        );
        return existing;
      } else {
        // Connection is stale, remove it
        await _removeConnection(deviceId);
      }
    }

    if (_connectionInProgress) {
      LogService().log(
        'BLEDiscovery: Waiting for existing connection attempt to complete',
      );
      final waitDeadline = DateTime.now().add(const Duration(seconds: 20));
      while (_connectionInProgress && DateTime.now().isBefore(waitDeadline)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (_connectionInProgress) {
        LogService().log('BLEDiscovery: Timeout waiting for connection slot');
        return null;
      }

      // Another attempt may have created the connection while we waited
      if (_connectionPool.containsKey(deviceId)) {
        final existing = _connectionPool[deviceId]!;
        if (existing.isConnected) {
          LogService().log(
            'BLEDiscovery: Reusing connection created by prior attempt',
          );
          return existing;
        }
      }
    }

    // Create new connection
    // For devices with known callsign, do a quick scan to get fresh MAC address
    // (Android phones rotate BLE MAC addresses for privacy)
    String currentDeviceId = deviceId;
    BluetoothDevice? currentBleDevice = device.bleDevice;

    if (device.callsign != null && Platform.isLinux) {
      // Linux/BlueZ quick-refresh scans can interfere with active BLE links
      // and stall connection establishment. Use the latest discovered address
      // already tracked by periodic scanning.
      LogService().log(
        'BLEDiscovery: Skipping quick MAC refresh on Linux for ${device.callsign}',
      );
    }

    // Get BluetoothDevice - either from device or create new from ID
    BluetoothDevice bleDevice =
        currentBleDevice ?? BluetoothDevice.fromId(currentDeviceId);

    // Platform-specific timeout: Linux/BlueZ needs more time
    final connectTimeout = Platform.isLinux
        ? const Duration(seconds: 15)
        : const Duration(seconds: 10);

    _connectionInProgress = true;
    try {
      if (_isScanning) {
        LogService().log(
          'BLEDiscovery: Stopping active scan before connection attempt',
        );
        await stopScanning();
        await Future.delayed(const Duration(milliseconds: 150));
      }

      LogService().log(
        'BLEDiscovery: Creating new connection to $currentDeviceId',
      );
      LogService().log(
        'BLEDiscovery: Using ${currentBleDevice != null ? "cached" : "new"} BluetoothDevice for $currentDeviceId',
      );
      LogService().log(
        'BLEDiscovery: Platform=${Platform.operatingSystem}, timeout=${connectTimeout.inSeconds}s',
      );

      // Retry connection up to 3 times with exponential backoff
      bool connected = false;
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          if (attempt > 1) {
            // Reset any half-open link before retrying.
            try {
              await bleDevice.disconnect().timeout(const Duration(seconds: 2));
            } catch (_) {}
            await Future.delayed(const Duration(milliseconds: 150));
          }

          LogService().log(
            'BLEDiscovery: Connection attempt $attempt/3 to $currentDeviceId',
          );
          await bleDevice
              .connect(timeout: connectTimeout)
              .timeout(connectTimeout + const Duration(seconds: 2));
          connected = true;
          LogService().log(
            'BLEDiscovery: Connection attempt $attempt succeeded',
          );
          break; // Success
        } catch (e) {
          LogService().log(
            'BLEDiscovery: Connection attempt $attempt failed: $e',
          );
          final errorText = e.toString();
          if (errorText.contains('Bad state: No element') && attempt < 3) {
            // Linux BlueZ + flutter_blue_plus can leave cached BluetoothDevice
            // handles in a stale state after disconnects. Recreate from ID.
            bleDevice = BluetoothDevice.fromId(currentDeviceId);
            LogService().log(
              'BLEDiscovery: Recreated BluetoothDevice from ID after stale-handle error',
            );
          }
          if (attempt == 3) {
            throw Exception('Connection failed after 3 attempts: $e');
          }
          // Exponential backoff: 500ms, 1000ms, 1500ms
          final delay = Duration(milliseconds: 500 * attempt);
          LogService().log(
            'BLEDiscovery: Retrying in ${delay.inMilliseconds}ms...',
          );
          await Future.delayed(delay);
        }
      }

      if (!connected) {
        throw Exception('Failed to connect after all attempts');
      }

      // Discover services with retry logic
      List<BluetoothService> services = [];
      for (int attempt = 1; attempt <= 3; attempt++) {
        LogService().log(
          'BLEDiscovery: Service discovery attempt $attempt/3 on $currentDeviceId',
        );
        services = await bleDevice.discoverServices().timeout(
          const Duration(seconds: 10),
        );
        if (services.isNotEmpty) {
          LogService().log(
            'BLEDiscovery: Service discovery attempt $attempt found ${services.length} services',
          );
          break;
        }
        LogService().log(
          'BLEDiscovery: Service discovery attempt $attempt returned empty, retrying...',
        );
        // Exponential backoff: 300ms, 600ms, 900ms
        await Future.delayed(Duration(milliseconds: 300 * attempt));
      }

      // Log all discovered services for debugging
      LogService().log(
        'BLEDiscovery: Discovered ${services.length} services on $currentDeviceId:',
      );
      for (final svc in services) {
        LogService().log('  - ${svc.uuid.toString()}');
      }

      if (services.isEmpty) {
        throw Exception('No services discovered after 3 attempts');
      }

      // Deduplicate services by UUID (BlueZ sometimes reports duplicates)
      final seenUuids = <String>{};
      final uniqueServices = <BluetoothService>[];
      for (final svc in services) {
        final uuid = svc.uuid.toString().toLowerCase();
        if (!seenUuids.contains(uuid)) {
          seenUuids.add(uuid);
          uniqueServices.add(svc);
        } else {
          LogService().log('BLEDiscovery: Skipping duplicate service: $uuid');
        }
      }

      // Find Geogram service using helper (handles BlueZ UUID formats)
      final geogramService = _findGeogramService(uniqueServices);
      if (geogramService == null) {
        LogService().log(
          'BLEDiscovery: Geogram service FFE0 not found among ${services.length} services',
        );
        throw Exception('Geogram service (FFE0) not found');
      }
      LogService().log(
        'BLEDiscovery: Found Geogram service: ${geogramService.uuid}',
      );

      // Log characteristics
      LogService().log(
        'BLEDiscovery: Found ${geogramService.characteristics.length} characteristics:',
      );
      for (final char in geogramService.characteristics) {
        LogService().log('  - ${char.uuid.toString()}');
      }

      // Find characteristics using helpers
      final writeChar = _findCharacteristic(
        geogramService.characteristics,
        'fff1',
        writeCharUUID,
      );
      final notifyChar = _findCharacteristic(
        geogramService.characteristics,
        'fff2',
        notifyCharUUID,
      );

      if (writeChar == null || notifyChar == null) {
        throw Exception(
          'Required characteristics not found (write: ${writeChar != null}, notify: ${notifyChar != null})',
        );
      }
      LogService().log(
        'BLEDiscovery: Found FFF1 (write) and FFF2 (notify) characteristics',
      );

      // Request higher MTU for faster transfer
      try {
        final requestedMtu = await bleDevice.requestMtu(512);
        LogService().log('BLEDiscovery: Requested MTU 512, got $requestedMtu');
      } catch (e) {
        LogService().log('BLEDiscovery: MTU request failed: $e');
      }

      // Subscribe to notifications with retry
      bool subscribed = false;
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          await notifyChar.setNotifyValue(true);
          subscribed = true;
          LogService().log('BLEDiscovery: Subscribed to FFF2 notifications');
          break;
        } catch (e) {
          LogService().log(
            'BLEDiscovery: Notification subscription attempt $attempt failed: $e',
          );
          if (attempt < 3) {
            await Future.delayed(Duration(milliseconds: 200 * attempt));
          }
        }
      }

      if (!subscribed) {
        LogService().log(
          'BLEDiscovery: WARNING: Could not subscribe to notifications, proceeding anyway',
        );
      }

      // Longer delay on Linux to let BlueZ stabilize the subscription
      final stabilizeDelay = Platform.isLinux
          ? const Duration(milliseconds: 500)
          : const Duration(milliseconds: 200);
      await Future.delayed(stabilizeDelay);

      // Create connection object
      final connection = _BLEConnection(
        deviceId: currentDeviceId,
        device: bleDevice,
        writeChar: writeChar,
        notifyChar: notifyChar,
        onDisconnect: () => _removeConnection(currentDeviceId),
        onChatReceived: (message) => _incomingChatsController.add(message),
      );

      _connectionPool[currentDeviceId] = connection;
      LogService().log('BLEDiscovery: Connection ready for $currentDeviceId');

      return connection;
    } catch (e) {
      LogService().log(
        'BLEDiscovery: Failed to connect to $currentDeviceId: $e',
      );
      try {
        await bleDevice.disconnect();
      } catch (_) {}
      return null;
    } finally {
      _connectionInProgress = false;
    }
  }

  /// Remove connection from pool and disconnect
  Future<void> _removeConnection(String deviceId) async {
    final connection = _connectionPool.remove(deviceId);
    if (connection != null) {
      await connection.dispose();
      LogService().log(
        'BLEDiscovery: Connection to $deviceId removed from pool',
      );
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
    _adapterStateSubscription?.cancel();
    _periodicScanTimer?.cancel();
    _periodicScanTimer = null;
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
  final void Function(Map<String, dynamic>)? onChatReceived;

  bool _isConnected = true;
  Timer? _disconnectTimer;
  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  // Buffer for receiving chunked data
  final List<int> _receiveBuffer = [];

  // Pending request completers
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  // Serialize outbound writes so concurrent API requests don't interleave chunks.
  Future<void> _sendChain = Future<void>.value();

  _BLEConnection({
    required this.deviceId,
    required this.device,
    required this.writeChar,
    required this.notifyChar,
    required this.onDisconnect,
    this.onChatReceived,
  }) {
    // Listen to notifications
    _notifySubscription = notifyChar.onValueReceived.listen(
      _handleNotification,
    );

    // Listen for disconnection
    _connectionStateSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        if (!_isConnected) return;
        _isConnected = false;
        onDisconnect();
      }
    });
  }

  bool get isConnected => _isConnected;

  Future<T> _runSerializedSend<T>(Future<T> Function() operation) {
    final completer = Completer<T>();

    _sendChain = _sendChain.catchError((_) {}).then((_) async {
      if (!_isConnected) {
        completer.completeError(Exception('BLE connection is disconnected'));
        return;
      }

      try {
        final result = await operation();
        completer.complete(result);
      } catch (e, stackTrace) {
        completer.completeError(e, stackTrace);
      }
    });

    return completer.future;
  }

  /// Handle incoming notification data
  void _handleNotification(List<int> data) {
    _receiveBuffer.addAll(data);
    LogService().log(
      'BLEDiscovery: [NOTIF] Received ${data.length} bytes, buffer now ${_receiveBuffer.length} bytes',
    );

    // Safety: if buffer grows beyond 64KB without producing valid JSON, clear it
    if (_receiveBuffer.length > 65536) {
      LogService().log(
        'BLEDiscovery: [NOTIF] Buffer overflow (${_receiveBuffer.length} bytes), clearing',
      );
      _receiveBuffer.clear();
      return;
    }

    // Extract and process all complete JSON objects from the buffer.
    // Multiple messages can arrive back-to-back (e.g. chat + api_response)
    // so we must parse each one individually.
    _processBuffer();
  }

  /// Extract complete JSON objects from _receiveBuffer and dispatch them.
  /// Uses brace-depth tracking to find object boundaries, handling
  /// concatenated messages like: {"type":"chat",...}{"type":"api_response",...}
  void _processBuffer() {
    while (_receiveBuffer.isNotEmpty) {
      final jsonStr = utf8.decode(_receiveBuffer, allowMalformed: true);

      // Find the start of the first JSON object
      final startIdx = jsonStr.indexOf('{');
      if (startIdx < 0) {
        // No JSON object start found - discard buffer
        LogService().log(
          'BLEDiscovery: [NOTIF] No JSON object start in buffer, clearing ${_receiveBuffer.length} bytes',
        );
        _receiveBuffer.clear();
        return;
      }

      // Track brace depth to find end of first complete JSON object
      int depth = 0;
      bool inString = false;
      bool escaped = false;
      int? endIdx;

      for (int i = startIdx; i < jsonStr.length; i++) {
        final c = jsonStr[i];
        if (escaped) {
          escaped = false;
          continue;
        }
        if (c == '\\' && inString) {
          escaped = true;
          continue;
        }
        if (c == '"') {
          inString = !inString;
          continue;
        }
        if (inString) continue;

        if (c == '{') {
          depth++;
        } else if (c == '}') {
          depth--;
          if (depth == 0) {
            endIdx = i;
            break;
          }
        }
      }

      if (endIdx == null) {
        // Incomplete JSON object - wait for more data
        LogService().log(
          'BLEDiscovery: [NOTIF] JSON incomplete, waiting for more chunks',
        );
        return;
      }

      // Extract the complete JSON substring and update buffer
      final objectStr = jsonStr.substring(startIdx, endIdx + 1);
      final consumedBytes = utf8.encode(jsonStr.substring(0, endIdx + 1));
      _receiveBuffer.removeRange(0, consumedBytes.length);

      // Parse and dispatch
      try {
        final response = json.decode(objectStr) as Map<String, dynamic>;
        LogService().log(
          'BLEDiscovery: [NOTIF] Parsed JSON object (${objectStr.length} chars, ${_receiveBuffer.length} bytes remaining)',
        );
        _dispatchMessage(response);
      } catch (e) {
        LogService().log(
          'BLEDiscovery: [NOTIF] Parse error on extracted object: $e',
        );
        // Skip this malformed object and continue with remaining buffer
      }
    }
  }

  /// Dispatch a single parsed JSON message
  void _dispatchMessage(Map<String, dynamic> response) {
    final messageId = response['id'] as String?;
    final msgType = response['type'] as String?;
    LogService().log(
      'BLEDiscovery: [NOTIF] Dispatching message: id=$messageId, type=$msgType',
    );

    if (messageId != null && _pendingRequests.containsKey(messageId)) {
      LogService().log(
        'BLEDiscovery: [NOTIF] Matched pending request $messageId - completing',
      );
      _pendingRequests[messageId]!.complete(response);
      _pendingRequests.remove(messageId);
    } else {
      // Forward to chat handler for messages not matched by pending requests
      LogService().log(
        'BLEDiscovery: [NOTIF] No match in local pending - forwarding to BleTransport (onChatReceived=${onChatReceived != null})',
      );
      if (onChatReceived != null) {
        response['_deviceId'] = deviceId;
        LogService().log(
          'BLEDiscovery: [NOTIF] Calling onChatReceived with type=$msgType, id=$messageId',
        );
        onChatReceived!(response);
      } else {
        LogService().log(
          'BLEDiscovery: [NOTIF] WARNING: onChatReceived is null! Message will be lost',
        );
      }
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
      await _runSerializedSend(() => _sendChunked(messageJson));

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

  /// Send message without waiting for response (fire-and-forget)
  /// Used for async API requests where the response comes back later via notifications
  Future<void> sendOnly(String messageJson) async {
    LogService().log(
      'BLEDiscovery: [SEND-ONLY] Sending message (no wait for response)',
    );
    await _runSerializedSend(() => _sendChunked(messageJson));
    LogService().log('BLEDiscovery: [SEND-ONLY] Message sent successfully');
  }

  /// Send data with chunking if needed
  /// Uses 280-byte parcels with pauses between to avoid connection drops
  Future<void> _sendChunked(String jsonStr) async {
    final bytes = utf8.encode(jsonStr);
    int mtu;
    try {
      mtu = await device.mtu.first.timeout(const Duration(seconds: 2));
      if (mtu < 23) mtu = 23;
    } catch (e) {
      LogService().log(
        'BLEDiscovery: Failed to read MTU for $deviceId ($e), using fallback 23',
      );
      mtu = 23;
    }
    final chunkSize = max(20, mtu - 3); // Leave room for ATT header
    const parcelSize = 280; // Max bytes per parcel (below 300 threshold)

    LogService().log(
      'BLEDiscovery: Sending ${bytes.length} bytes (MTU: $mtu, chunk: $chunkSize, parcel: $parcelSize)',
    );

    if (bytes.length <= chunkSize) {
      // Single write for small messages
      await writeChar.write(bytes, withoutResponse: false);
      LogService().log('BLEDiscovery: Message written successfully');
    } else {
      // Send in parcels of ~280 bytes with longer pause between parcels
      final totalParcels = (bytes.length / parcelSize).ceil();
      LogService().log(
        'BLEDiscovery: Sending ${bytes.length} bytes in $totalParcels parcels',
      );

      for (
        int parcelStart = 0;
        parcelStart < bytes.length;
        parcelStart += parcelSize
      ) {
        final parcelEnd = (parcelStart + parcelSize < bytes.length)
            ? parcelStart + parcelSize
            : bytes.length;
        final parcelNum = (parcelStart / parcelSize).floor() + 1;

        LogService().log(
          'BLEDiscovery: Sending parcel $parcelNum/$totalParcels (bytes $parcelStart-$parcelEnd)',
        );

        // Send this parcel in MTU-sized chunks
        for (int i = parcelStart; i < parcelEnd; i += chunkSize) {
          final end = (i + chunkSize < parcelEnd) ? i + chunkSize : parcelEnd;
          final chunk = bytes.sublist(i, end);

          try {
            // Use write-with-response for parcel chunks to avoid dropped bytes on
            // Linux -> ESP32 links where large fire-and-forget writes can corrupt payloads.
            await writeChar.write(chunk, withoutResponse: false);
            // Small delay between chunks within a parcel
            await Future.delayed(const Duration(milliseconds: 30));
          } catch (e) {
            LogService().log(
              'BLEDiscovery: Parcel $parcelNum chunk failed: $e',
            );
            rethrow;
          }
        }

        // Longer pause between parcels to let BLE stack recover
        if (parcelEnd < bytes.length) {
          LogService().log(
            'BLEDiscovery: Parcel $parcelNum complete, pausing before next...',
          );
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      LogService().log(
        'BLEDiscovery: All $totalParcels parcels sent successfully',
      );
    }
  }

  /// Schedule automatic disconnect after timeout
  void scheduleDisconnect(Duration timeout) {
    _disconnectTimer?.cancel();
    _disconnectTimer = Timer(timeout, () {
      LogService().log(
        'BLEDiscovery: Connection timeout, disconnecting $deviceId',
      );
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
    await _connectionStateSubscription?.cancel();
    _pendingRequests.clear();
    _receiveBuffer.clear();

    if (_isConnected) {
      _isConnected = false;
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }
}
