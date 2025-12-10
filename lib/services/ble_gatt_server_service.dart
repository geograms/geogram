/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'app_args.dart';
import 'ble_permission_service.dart';
import 'log_service.dart';

/// Represents a connected BLE client
class ConnectedBLEClient {
  final String deviceId;
  final DateTime connectedAt;
  bool isSubscribed;
  final List<int> receiveBuffer;

  ConnectedBLEClient({
    required this.deviceId,
    required this.connectedAt,
    this.isSubscribed = false,
  }) : receiveBuffer = [];
}

/// Callback type for handling incoming BLE messages
typedef BLEMessageHandler = Future<Map<String, dynamic>?> Function(
  String deviceId,
  Map<String, dynamic> message,
);

/// GATT Server Service for Android/iOS devices
/// Handles incoming BLE connections from Linux/other clients
class BLEGattServerService {
  static final BLEGattServerService _instance = BLEGattServerService._internal();
  factory BLEGattServerService() => _instance;
  BLEGattServerService._internal();

  /// GATT service/characteristic UUIDs (same as ble_discovery_service.dart)
  static const String serviceUUID = '0000fff0-0000-1000-8000-00805f9b34fb';
  static const String writeCharUUID = '0000fff1-0000-1000-8000-00805f9b34fb';
  static const String notifyCharUUID = '0000fff2-0000-1000-8000-00805f9b34fb';
  static const String statusCharUUID = '0000fff3-0000-1000-8000-00805f9b34fb';

  /// Server state
  bool _isInitialized = false;
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  /// Connected clients
  final Map<String, ConnectedBLEClient> _connectedClients = {};
  List<String> get connectedDeviceIds => _connectedClients.keys.toList();

  /// Message handler
  BLEMessageHandler? _messageHandler;

  /// Stream controller for incoming messages (for listeners)
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  /// Check if platform supports GATT server
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// Initialize the GATT server (must be called before startServer)
  Future<void> initialize() async {
    if (_isInitialized) return;
    if (!isSupported) {
      LogService().log('BLEGattServer: Not supported on this platform');
      return;
    }

    // Refuse in internet-only mode
    if (AppArgs().internetOnly) {
      LogService().log('BLEGattServer: Disabled in internet-only mode');
      return;
    }

    try {
      // Initialize BLE peripheral
      await BlePeripheral.initialize();

      // Set up callbacks
      _setupCallbacks();

      // Add GATT service with characteristics
      await _addGattService();

      _isInitialized = true;
      LogService().log('BLEGattServer: Initialized successfully');
    } catch (e, stackTrace) {
      LogService().log('BLEGattServer: Failed to initialize: $e\n$stackTrace');
      rethrow;
    }
  }

  /// Set up BLE peripheral callbacks
  void _setupCallbacks() {
    // Handle connection state changes (Android)
    BlePeripheral.setConnectionStateChangeCallback((deviceId, connected) {
      if (connected) {
        _onClientConnected(deviceId);
      } else {
        _onClientDisconnected(deviceId);
      }
    });

    // Handle characteristic subscription changes (iOS and Android)
    BlePeripheral.setCharacteristicSubscriptionChangeCallback(
      (deviceId, characteristicId, subscribed, name) {
        _onSubscriptionChanged(deviceId, characteristicId, subscribed);
      },
    );

    // Handle write requests on 0xFFF1
    BlePeripheral.setWriteRequestCallback(
      (deviceId, characteristicId, offset, value) {
        return _handleWriteRequest(deviceId, characteristicId, offset, value);
      },
    );

    // Handle read requests on 0xFFF3 (status)
    BlePeripheral.setReadRequestCallback(
      (deviceId, characteristicId, offset, value) {
        return _handleReadRequest(deviceId, characteristicId, offset);
      },
    );
  }

  /// Add GATT service with characteristics
  Future<void> _addGattService() async {
    final service = BleService(
      uuid: serviceUUID,
      primary: true,
      characteristics: [
        // Write characteristic (0xFFF1) - clients write messages here
        BleCharacteristic(
          uuid: writeCharUUID,
          properties: [
            CharacteristicProperties.write.index,
            CharacteristicProperties.writeWithoutResponse.index,
          ],
          permissions: [AttributePermissions.writeable.index],
          value: null,
        ),
        // Notify characteristic (0xFFF2) - server sends responses here
        BleCharacteristic(
          uuid: notifyCharUUID,
          properties: [
            CharacteristicProperties.notify.index,
            CharacteristicProperties.read.index,
          ],
          permissions: [AttributePermissions.readable.index],
          value: null,
        ),
        // Status characteristic (0xFFF3) - connection status
        BleCharacteristic(
          uuid: statusCharUUID,
          properties: [CharacteristicProperties.read.index],
          permissions: [AttributePermissions.readable.index],
          value: Uint8List.fromList(utf8.encode('{"status":"ready"}')),
        ),
      ],
    );

    await BlePeripheral.addService(service);
    LogService().log('BLEGattServer: GATT service added');
  }

  /// Start the GATT server (begin advertising)
  Future<void> startServer(String callsign) async {
    // Refuse in internet-only mode
    if (AppArgs().internetOnly) {
      LogService().log('BLEGattServer: Disabled in internet-only mode');
      return;
    }

    if (!_isInitialized) {
      await initialize();
    }

    if (_isRunning) {
      LogService().log('BLEGattServer: Already running');
      return;
    }

    if (!isSupported) return;

    try {
      // Check BLE advertise permission via permission service
      final permissionService = BLEPermissionService();
      if (!permissionService.hasAdvertisePermission) {
        // Try to request permission
        final granted = await permissionService.requestAllPermissions();
        if (!granted || !permissionService.hasAdvertisePermission) {
          LogService().log('BLEGattServer: BLE permission not granted');
          return;
        }
      }

      // Build advertising data with Geogram marker
      final serviceData = Uint8List.fromList([
        0x3E, // Geogram marker '>'
        ...utf8.encode(callsign.length > 18 ? callsign.substring(0, 18) : callsign),
      ]);

      // Start advertising
      await BlePeripheral.startAdvertising(
        services: [serviceUUID],
        localName: 'Geogram',
        manufacturerData: ManufacturerData(
          manufacturerId: 0xFFFF,
          data: serviceData,
        ),
      );

      _isRunning = true;
      LogService().log('BLEGattServer: Started advertising as $callsign');
    } catch (e, stackTrace) {
      LogService().log('BLEGattServer: Failed to start: $e\n$stackTrace');
    }
  }

  /// Stop the GATT server
  Future<void> stopServer() async {
    if (!_isRunning) return;

    try {
      await BlePeripheral.stopAdvertising();
      _isRunning = false;
      LogService().log('BLEGattServer: Stopped');
    } catch (e) {
      LogService().log('BLEGattServer: Error stopping: $e');
      _isRunning = false;
    }
  }

  /// Register a message handler
  void setMessageHandler(BLEMessageHandler handler) {
    _messageHandler = handler;
  }

  /// Handle client connection
  void _onClientConnected(String deviceId) {
    LogService().log('BLEGattServer: Connection callback - deviceId: $deviceId');
    if (!_connectedClients.containsKey(deviceId)) {
      _connectedClients[deviceId] = ConnectedBLEClient(
        deviceId: deviceId,
        connectedAt: DateTime.now(),
      );
      LogService().log('BLEGattServer: Client connected: $deviceId (total: ${_connectedClients.length})');
    } else {
      LogService().log('BLEGattServer: Client already tracked: $deviceId');
    }
  }

  /// Handle client disconnection
  void _onClientDisconnected(String deviceId) {
    final client = _connectedClients.remove(deviceId);
    if (client != null) {
      LogService().log('BLEGattServer: Client disconnected: $deviceId (buffer had ${client.receiveBuffer.length} bytes)');
    } else {
      LogService().log('BLEGattServer: Disconnect for unknown client: $deviceId');
    }
  }

  /// Handle subscription changes
  void _onSubscriptionChanged(String deviceId, String characteristicId, bool subscribed) {
    LogService().log('BLEGattServer: Subscription change - device: $deviceId, char: $characteristicId, subscribed: $subscribed');

    // Match both short and long UUID forms
    final charIdLower = characteristicId.toLowerCase();
    final isNotifyChar = charIdLower == notifyCharUUID.toLowerCase() ||
                         charIdLower == 'fff2' ||
                         charIdLower.contains('fff2');

    if (isNotifyChar) {
      final client = _connectedClients[deviceId];
      if (client != null) {
        client.isSubscribed = subscribed;
        LogService().log('BLEGattServer: Client $deviceId ${subscribed ? "subscribed" : "unsubscribed"} to notifications');
      } else if (subscribed) {
        // Client subscribed before connection callback (iOS behavior)
        _connectedClients[deviceId] = ConnectedBLEClient(
          deviceId: deviceId,
          connectedAt: DateTime.now(),
          isSubscribed: true,
        );
        LogService().log('BLEGattServer: Client $deviceId connected via subscription');
      }
    } else {
      LogService().log('BLEGattServer: Subscription for non-notify char: $characteristicId');
    }
  }

  /// Handle write requests on 0xFFF1
  WriteRequestResult? _handleWriteRequest(
    String deviceId,
    String characteristicId,
    int? offset,
    Uint8List? value,
  ) {
    LogService().log('BLEGattServer: Write request from $deviceId on $characteristicId (${value?.length ?? 0} bytes)');

    // Check characteristic UUID - match both short and long forms
    final charIdLower = characteristicId.toLowerCase();
    final isWriteChar = charIdLower == writeCharUUID.toLowerCase() ||
                        charIdLower == 'fff1' ||
                        charIdLower.contains('fff1');

    if (!isWriteChar) {
      LogService().log('BLEGattServer: Wrong characteristic: $characteristicId (expected $writeCharUUID or fff1)');
      return WriteRequestResult(status: 1); // Error
    }

    if (value == null || value.isEmpty) {
      LogService().log('BLEGattServer: Empty write request');
      return WriteRequestResult(status: 0); // Success
    }

    // Get or create client
    final client = _connectedClients.putIfAbsent(
      deviceId,
      () => ConnectedBLEClient(deviceId: deviceId, connectedAt: DateTime.now()),
    );

    // Accumulate data in buffer
    client.receiveBuffer.addAll(value);
    LogService().log('BLEGattServer: Buffer now ${client.receiveBuffer.length} bytes');

    // Try to parse as complete JSON
    try {
      final jsonStr = utf8.decode(client.receiveBuffer);

      // Check if JSON is complete by trying to parse it
      // This is more robust than just checking for '}'
      try {
        final message = json.decode(jsonStr) as Map<String, dynamic>;

        // Successfully parsed - clear buffer and process
        LogService().log('BLEGattServer: Complete message received: ${message['type']}');
        client.receiveBuffer.clear();

        // Process message asynchronously
        _processMessage(deviceId, message);
      } on FormatException {
        // JSON not complete yet, wait for more chunks
        LogService().log('BLEGattServer: Waiting for more chunks (${client.receiveBuffer.length} bytes so far)');
      }
    } catch (e) {
      // UTF-8 decoding failed - likely incomplete multi-byte sequence
      LogService().log('BLEGattServer: UTF-8 decode pending (${client.receiveBuffer.length} bytes)');
    }

    return WriteRequestResult(status: 0); // Success
  }

  /// Handle read requests on 0xFFF3 (status)
  ReadRequestResult? _handleReadRequest(
    String deviceId,
    String characteristicId,
    int? offset,
  ) {
    if (characteristicId.toLowerCase() == statusCharUUID.toLowerCase()) {
      final status = {
        'status': 'ready',
        'clients': _connectedClients.length,
      };
      return ReadRequestResult(
        value: Uint8List.fromList(utf8.encode(json.encode(status))),
        status: 0, // Success
      );
    }

    return ReadRequestResult(
      value: Uint8List(0),
      status: 1, // Error
    );
  }

  /// Process received message
  Future<void> _processMessage(String deviceId, Map<String, dynamic> message) async {
    LogService().log('BLEGattServer: Received message from $deviceId: ${message['type']}');

    // Emit to stream
    _messageController.add({
      'deviceId': deviceId,
      'message': message,
    });

    // Call handler if registered
    if (_messageHandler != null) {
      try {
        final response = await _messageHandler!(deviceId, message);
        if (response != null) {
          await sendNotification(deviceId, response);
        }
      } catch (e) {
        LogService().log('BLEGattServer: Error in message handler: $e');
        // Send error response
        await sendNotification(deviceId, {
          'type': 'error',
          'id': message['id'],
          'payload': {'error': 'Internal server error'},
        });
      }
    }
  }

  /// Send notification to a specific client
  Future<void> sendNotification(String deviceId, Map<String, dynamic> message) async {
    LogService().log('BLEGattServer: sendNotification called for $deviceId');

    final client = _connectedClients[deviceId];
    if (client == null) {
      LogService().log('BLEGattServer: Cannot send notification - client not found: $deviceId');
      LogService().log('BLEGattServer: Known clients: ${_connectedClients.keys.toList()}');
      return;
    }

    if (!client.isSubscribed) {
      LogService().log('BLEGattServer: Cannot send notification - client not subscribed: $deviceId');
      return;
    }

    try {
      final jsonStr = json.encode(message);
      final bytes = utf8.encode(jsonStr);

      LogService().log('BLEGattServer: Sending notification (${bytes.length} bytes) to $deviceId on $notifyCharUUID');

      // Send data (chunked if necessary by the platform)
      await BlePeripheral.updateCharacteristic(
        characteristicId: notifyCharUUID,
        value: Uint8List.fromList(bytes),
        deviceId: deviceId,
      );

      LogService().log('BLEGattServer: Notification sent successfully to $deviceId');
    } catch (e, stackTrace) {
      LogService().log('BLEGattServer: Failed to send notification: $e');
      LogService().log('BLEGattServer: Stack trace: $stackTrace');
    }
  }

  /// Broadcast notification to all subscribed clients
  Future<void> broadcastNotification(Map<String, dynamic> message) async {
    final subscribedClients = _connectedClients.entries
        .where((e) => e.value.isSubscribed)
        .map((e) => e.key)
        .toList();

    for (final deviceId in subscribedClients) {
      await sendNotification(deviceId, message);
    }
  }

  /// Dispose resources
  void dispose() {
    stopServer();
    _messageController.close();
    _connectedClients.clear();
  }
}
