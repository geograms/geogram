/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'log_service.dart';
import 'app_args.dart';

/// Connection state for Bluetooth Classic connections
enum BluetoothClassicConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

/// Represents an active Bluetooth Classic connection
class BluetoothClassicConnection {
  final String macAddress;
  final String? callsign;
  final DateTime connectedAt;
  BluetoothClassicConnectionState state;

  BluetoothClassicConnection({
    required this.macAddress,
    this.callsign,
    required this.connectedAt,
    this.state = BluetoothClassicConnectionState.connected,
  });
}

/// Service for managing Bluetooth Classic (SPP/RFCOMM) connections
///
/// This service enables BLE+ functionality by providing faster data transfer
/// capabilities alongside BLE discovery. Android devices act as servers,
/// while desktop platforms (Linux, macOS, Windows) act as clients.
class BluetoothClassicService {
  static final BluetoothClassicService _instance = BluetoothClassicService._internal();
  factory BluetoothClassicService() => _instance;
  BluetoothClassicService._internal();

  /// Method channel for platform-specific implementations
  static const MethodChannel _channel = MethodChannel('geogram/bluetooth_classic');

  /// SPP (Serial Port Profile) UUID - standard for RFCOMM serial connections
  static const String sppUuid = '00001101-0000-1000-8000-00805f9b34fb';

  /// Geogram-specific SPP service name
  static const String serviceName = 'Geogram BLE+';

  /// Active connections by MAC address
  final Map<String, BluetoothClassicConnection> _connections = {};

  /// Stream controller for connection state changes
  final _connectionStateController = StreamController<BluetoothClassicConnection>.broadcast();
  Stream<BluetoothClassicConnection> get connectionStateStream => _connectionStateController.stream;

  /// Stream controller for incoming data
  final _dataController = StreamController<({String macAddress, Uint8List data})>.broadcast();
  Stream<({String macAddress, Uint8List data})> get dataStream => _dataController.stream;

  /// Server state (Android only)
  bool _isServerRunning = false;
  bool get isServerRunning => _isServerRunning;

  /// Initialization state
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Check if Bluetooth Classic is available on this platform
  /// Currently restricted to Android only as it's the only fully tested platform
  static bool get isAvailable {
    if (kIsWeb) return false;
    if (AppArgs().internetOnly) return false;
    // Only Android is fully tested for BLE+
    return Platform.isAndroid;
  }

  /// Check if this platform can act as a Bluetooth Classic server
  static bool get canBeServer {
    if (kIsWeb) return false;
    // Only Android can be an SPP server in our implementation
    return Platform.isAndroid;
  }

  /// Check if this platform can act as a Bluetooth Classic client
  static bool get canBeClient {
    if (kIsWeb) return false;
    // Only Android is currently supported (both server and client)
    return Platform.isAndroid;
  }

  /// Initialize the Bluetooth Classic service
  Future<void> initialize() async {
    if (_isInitialized) return;
    if (!isAvailable) {
      LogService().log('BluetoothClassic: Not available on this platform');
      return;
    }

    try {
      // Set up method channel handlers for incoming calls from native code
      _channel.setMethodCallHandler(_handleMethodCall);

      // Initialize native side
      await _channel.invokeMethod('initialize');
      _isInitialized = true;
      LogService().log('BluetoothClassic: Initialized successfully');
    } on PlatformException catch (e) {
      LogService().log('BluetoothClassic: Failed to initialize - ${e.message}');
    } on MissingPluginException {
      // Native implementation not available yet
      LogService().log('BluetoothClassic: Native plugin not implemented for this platform');
    }
  }

  /// Handle method calls from native code
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onConnectionStateChanged':
        final macAddress = call.arguments['macAddress'] as String;
        final stateStr = call.arguments['state'] as String;
        final callsign = call.arguments['callsign'] as String?;
        _handleConnectionStateChange(macAddress, stateStr, callsign);
        break;

      case 'onDataReceived':
        final macAddress = call.arguments['macAddress'] as String;
        final data = call.arguments['data'] as Uint8List;
        _dataController.add((macAddress: macAddress, data: data));
        break;

      case 'onServerClientConnected':
        final macAddress = call.arguments['macAddress'] as String;
        final callsign = call.arguments['callsign'] as String?;
        _handleIncomingConnection(macAddress, callsign);
        break;

      default:
        LogService().log('BluetoothClassic: Unknown method call ${call.method}');
    }
  }

  void _handleConnectionStateChange(String macAddress, String stateStr, String? callsign) {
    final state = BluetoothClassicConnectionState.values.firstWhere(
      (e) => e.name == stateStr,
      orElse: () => BluetoothClassicConnectionState.disconnected,
    );

    if (state == BluetoothClassicConnectionState.connected) {
      final connection = BluetoothClassicConnection(
        macAddress: macAddress,
        callsign: callsign,
        connectedAt: DateTime.now(),
        state: state,
      );
      _connections[macAddress] = connection;
      _connectionStateController.add(connection);
      LogService().log('BluetoothClassic: Connected to $macAddress');
    } else if (state == BluetoothClassicConnectionState.disconnected) {
      final connection = _connections.remove(macAddress);
      if (connection != null) {
        connection.state = state;
        _connectionStateController.add(connection);
      }
      LogService().log('BluetoothClassic: Disconnected from $macAddress');
    }
  }

  void _handleIncomingConnection(String macAddress, String? callsign) {
    final connection = BluetoothClassicConnection(
      macAddress: macAddress,
      callsign: callsign,
      connectedAt: DateTime.now(),
      state: BluetoothClassicConnectionState.connected,
    );
    _connections[macAddress] = connection;
    _connectionStateController.add(connection);
    LogService().log('BluetoothClassic: Incoming connection from $macAddress');
  }

  /// Get the Bluetooth Classic MAC address for this device (Android only)
  /// Returns null on platforms that don't support being a server
  Future<String?> getLocalMacAddress() async {
    if (!canBeServer) return null;

    try {
      final result = await _channel.invokeMethod<String>('getLocalMacAddress');
      return result;
    } on PlatformException catch (e) {
      LogService().log('BluetoothClassic: Failed to get local MAC - ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Start the SPP server (Android only)
  /// This allows desktop clients to connect to this device
  Future<bool> startServer() async {
    if (!canBeServer) {
      LogService().log('BluetoothClassic: Cannot start server on this platform');
      return false;
    }

    try {
      await _channel.invokeMethod('startServer', {
        'uuid': sppUuid,
        'name': serviceName,
      });
      _isServerRunning = true;
      LogService().log('BluetoothClassic: Server started');
      return true;
    } on PlatformException catch (e) {
      LogService().log('BluetoothClassic: Failed to start server - ${e.message}');
      return false;
    } on MissingPluginException {
      LogService().log('BluetoothClassic: Server not implemented');
      return false;
    }
  }

  /// Stop the SPP server
  Future<void> stopServer() async {
    if (!_isServerRunning) return;

    try {
      await _channel.invokeMethod('stopServer');
      _isServerRunning = false;
      LogService().log('BluetoothClassic: Server stopped');
    } on PlatformException catch (e) {
      LogService().log('BluetoothClassic: Failed to stop server - ${e.message}');
    } on MissingPluginException {
      // Ignore
    }
  }

  /// Connect to a device as a client
  Future<bool> connect(String macAddress) async {
    if (!canBeClient) {
      LogService().log('BluetoothClassic: Cannot connect on this platform');
      return false;
    }

    if (_connections.containsKey(macAddress)) {
      LogService().log('BluetoothClassic: Already connected to $macAddress');
      return true;
    }

    try {
      LogService().log('BluetoothClassic: Connecting to $macAddress...');
      await _channel.invokeMethod('connect', {
        'macAddress': macAddress,
        'uuid': sppUuid,
      });
      return true;
    } on PlatformException catch (e) {
      LogService().log('BluetoothClassic: Failed to connect to $macAddress - ${e.message}');
      return false;
    } on MissingPluginException {
      LogService().log('BluetoothClassic: Connect not implemented');
      return false;
    }
  }

  /// Disconnect from a device
  Future<void> disconnect(String macAddress) async {
    if (!_connections.containsKey(macAddress)) return;

    try {
      await _channel.invokeMethod('disconnect', {
        'macAddress': macAddress,
      });
    } on PlatformException catch (e) {
      LogService().log('BluetoothClassic: Failed to disconnect from $macAddress - ${e.message}');
    } on MissingPluginException {
      // Ignore
    }
  }

  /// Check if connected to a specific device
  bool isConnected(String macAddress) {
    final connection = _connections[macAddress];
    return connection?.state == BluetoothClassicConnectionState.connected;
  }

  /// Send data to a connected device
  Future<bool> sendData(String macAddress, Uint8List data) async {
    if (!isConnected(macAddress)) {
      LogService().log('BluetoothClassic: Cannot send - not connected to $macAddress');
      return false;
    }

    try {
      await _channel.invokeMethod('sendData', {
        'macAddress': macAddress,
        'data': data,
      });
      return true;
    } on PlatformException catch (e) {
      LogService().log('BluetoothClassic: Failed to send data - ${e.message}');
      return false;
    } on MissingPluginException {
      LogService().log('BluetoothClassic: Send not implemented');
      return false;
    }
  }

  /// Request pairing with a device
  /// This triggers the system Bluetooth pairing dialog
  Future<bool> requestPairing(String macAddress) async {
    try {
      LogService().log('BluetoothClassic: Requesting pairing with $macAddress');
      final result = await _channel.invokeMethod<bool>('requestPairing', {
        'macAddress': macAddress,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      LogService().log('BluetoothClassic: Failed to request pairing - ${e.message}');
      return false;
    } on MissingPluginException {
      LogService().log('BluetoothClassic: Pairing not implemented');
      return false;
    }
  }

  /// Get list of paired (bonded) devices from the system
  Future<List<({String macAddress, String? name})>> getPairedDevices() async {
    try {
      final result = await _channel.invokeMethod<List>('getPairedDevices');
      if (result == null) return [];

      return result.map((device) {
        final map = device as Map;
        return (
          macAddress: map['macAddress'] as String,
          name: map['name'] as String?,
        );
      }).toList();
    } on PlatformException catch (e) {
      LogService().log('BluetoothClassic: Failed to get paired devices - ${e.message}');
      return [];
    } on MissingPluginException {
      return [];
    }
  }

  /// Check if a device is paired (bonded) at the system level
  Future<bool> isPaired(String macAddress) async {
    try {
      final result = await _channel.invokeMethod<bool>('isPaired', {
        'macAddress': macAddress,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      LogService().log('BluetoothClassic: Failed to check pairing - ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Check if we can potentially connect to a MAC address
  /// (device is paired and Bluetooth is enabled)
  Future<bool> canConnect(String macAddress) async {
    if (!isAvailable) return false;
    return await isPaired(macAddress);
  }

  /// Dispose resources
  Future<void> dispose() async {
    // Disconnect all connections
    for (final macAddress in _connections.keys.toList()) {
      await disconnect(macAddress);
    }

    // Stop server if running
    await stopServer();

    await _connectionStateController.close();
    await _dataController.close();
    _isInitialized = false;
  }
}
