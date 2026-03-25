/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'log_service.dart';
import 'app_args.dart';
import 'usb_aoa_linux_stub.dart' if (dart.library.ui) 'usb_aoa_linux.dart';

/// Connection state for USB AOA connections
enum UsbAoaConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

/// Information about a connected USB accessory
class UsbAccessoryInfo {
  final String? manufacturer;
  final String? model;
  final String? description;
  final String? version;
  final String? uri;
  final String? serial;

  const UsbAccessoryInfo({
    this.manufacturer,
    this.model,
    this.description,
    this.version,
    this.uri,
    this.serial,
  });

  factory UsbAccessoryInfo.fromMap(Map<String, dynamic> map) {
    return UsbAccessoryInfo(
      manufacturer: map['manufacturer'] as String?,
      model: map['model'] as String?,
      description: map['description'] as String?,
      version: map['version'] as String?,
      uri: map['uri'] as String?,
      serial: map['serial'] as String?,
    );
  }

  @override
  String toString() => 'UsbAccessoryInfo($manufacturer $model)';
}

/// Service for managing USB AOA (Android Open Accessory) connections
///
/// USB AOA enables zero-config bidirectional communication between two
/// Android devices connected via USB cable. One device acts as "host"
/// (OTG-capable), the other as "accessory".
///
/// Priority: 5 (highest - USB is faster and more reliable than all other transports)
class UsbAoaService {
  static final UsbAoaService _instance = UsbAoaService._internal();
  factory UsbAoaService() => _instance;
  UsbAoaService._internal();

  /// Method channel for platform-specific implementations
  static const MethodChannel _channel = MethodChannel('geogram/usb_aoa');

  /// Current connection state
  UsbAoaConnectionState _connectionState = UsbAoaConnectionState.disconnected;
  UsbAoaConnectionState get connectionState => _connectionState;

  /// Connected accessory info
  UsbAccessoryInfo? _accessoryInfo;
  UsbAccessoryInfo? get accessoryInfo => _accessoryInfo;

  /// Remote device callsign (discovered during handshake)
  String? _remoteCallsign;
  String? get remoteCallsign => _remoteCallsign;

  /// Stream controller for connection state changes
  final _connectionStateController =
      StreamController<UsbAoaConnectionState>.broadcast();
  Stream<UsbAoaConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  /// Stream controller for incoming data
  final _dataController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get dataStream => _dataController.stream;

  /// Stream controller for remote callsign changes
  final _remoteCallsignController = StreamController<String?>.broadcast();
  Stream<String?> get remoteCallsignStream => _remoteCallsignController.stream;

  /// Stream that fires when channel is ready (Android has opened accessory)
  /// Only applies on Linux host mode. On Android accessory mode, the channel
  /// is ready immediately upon connection.
  Stream<void> get channelReadyStream =>
      _linuxImpl?.channelReadyStream ?? const Stream.empty();

  /// Initialization state
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Linux implementation (host mode)
  UsbAoaLinux? _linuxImpl;
  StreamSubscription<UsbAoaConnectionEvent>? _linuxConnectionSub;
  StreamSubscription<Uint8List>? _linuxDataSub;
  Timer? _linuxScanTimer;

  /// Auto-reconnect state
  Timer? _autoReconnectTimer;
  int _autoReconnectAttempts = 0;
  static const int _maxAutoReconnectAttempts = 3;
  bool _userInitiatedDisconnect = false;

  /// Check if USB AOA is available on this platform
  static bool get isAvailable {
    if (kIsWeb) return false;
    if (AppArgs().internetOnly) return false;
    // USB AOA: Android (accessory) + Linux (host)
    return Platform.isAndroid || Platform.isLinux;
  }

  /// Check if currently connected
  bool get isConnected => _connectionState == UsbAoaConnectionState.connected;

  /// Whether the Linux read loop is active (Linux only)
  bool get isReading => _linuxImpl?.isReading ?? false;

  /// Poll timeout count for debugging (Linux only)
  int get pollTimeoutCount => _linuxImpl?.pollTimeoutCount ?? 0;

  /// Initialize the USB AOA service
  Future<void> initialize() async {
    if (_isInitialized) return;
    if (!isAvailable) {
      LogService().log('UsbAoa: Not available on this platform');
      return;
    }

    try {
      if (Platform.isLinux) {
        // Use native Dart FFI implementation for Linux host mode
        _linuxImpl = UsbAoaLinux();
        await _linuxImpl!.initialize();

        // Subscribe to connection events
        _linuxConnectionSub = _linuxImpl!.connectionStream.listen(
          _handleLinuxConnection,
        );

        // Subscribe to incoming data
        _linuxDataSub = _linuxImpl!.dataStream.listen((data) {
          _dataController.add(data);
        });

        _isInitialized = true;
        LogService().log('UsbAoa: Linux host mode initialized');

        // Auto-connect on Linux: scan for devices and connect
        // Use Future.microtask to ensure this runs after current event completes
        // and doesn't block app startup
        Future.microtask(() => _autoConnectLinux());

        // Start periodic scanning for USB hotplug detection
        _startLinuxPeriodicScan();
      } else if (Platform.isAndroid) {
        // Use existing MethodChannel implementation for Android accessory mode
        _channel.setMethodCallHandler(_handleMethodCall);

        final result = await _channel.invokeMethod<bool>('initialize');
        LogService().log('UsbAoa: Android initialize result: $result');
        if (result == true) {
          _isInitialized = true;
          LogService().log('UsbAoa: Android accessory mode initialized');

          // Check if already connected (accessory may have been opened before handler was set)
          try {
            final isConnected =
                await _channel.invokeMethod<bool>('isConnected') ?? false;
            if (isConnected) {
              LogService().log('UsbAoa: Already connected to accessory');
              _connectionState = UsbAoaConnectionState.connected;
              _connectionStateController.add(_connectionState);
            }
          } catch (e) {
            LogService().log('UsbAoa: Error checking connection state: $e');
          }
        } else {
          LogService().log('UsbAoa: USB manager not available');
        }
      }
    } on PlatformException catch (e) {
      LogService().log('UsbAoa: Failed to initialize - ${e.message}');
    } on MissingPluginException {
      // Native implementation not available yet
      LogService().log(
        'UsbAoa: Native plugin not implemented for this platform',
      );
    }
  }

  /// Handle Linux connection events
  void _handleLinuxConnection(UsbAoaConnectionEvent event) {
    if (event.connected) {
      _accessoryInfo = UsbAccessoryInfo(
        manufacturer: event.device.manufacturer,
        model: event.device.product,
        serial: event.device.serial,
      );
      _connectionState = UsbAoaConnectionState.connected;
      _connectionStateController.add(_connectionState);
      LogService().log('UsbAoa: Linux connected to ${event.device}');
      // Reset auto-reconnect state on successful connection
      _cancelAutoReconnect();
      _autoReconnectAttempts = 0;
    } else {
      _accessoryInfo = null;
      _remoteCallsign = null;
      _connectionState = UsbAoaConnectionState.disconnected;
      _connectionStateController.add(_connectionState);
      LogService().log('UsbAoa: Linux disconnected');
      // Schedule auto-reconnect for unexpected disconnects
      if (!_userInitiatedDisconnect) {
        _scheduleAutoReconnect();
      }
      _userInitiatedDisconnect = false;
    }
  }

  /// Schedule auto-reconnect with exponential backoff
  void _scheduleAutoReconnect() {
    if (_autoReconnectAttempts >= _maxAutoReconnectAttempts) {
      LogService().log(
        'UsbAoa: Max auto-reconnect attempts reached ($_maxAutoReconnectAttempts)',
      );
      _autoReconnectAttempts = 0;
      return;
    }

    _cancelAutoReconnect();
    _autoReconnectAttempts++;
    // Exponential backoff: 1s, 2s, 4s
    final delay = Duration(seconds: 1 << (_autoReconnectAttempts - 1));
    LogService().log(
      'UsbAoa: Scheduling auto-reconnect attempt $_autoReconnectAttempts in ${delay.inSeconds}s',
    );

    _autoReconnectTimer = Timer(delay, () async {
      if (_connectionState == UsbAoaConnectionState.disconnected) {
        LogService().log(
          'UsbAoa: Auto-reconnect attempt $_autoReconnectAttempts',
        );
        await _autoConnectLinux();
      }
    });
  }

  /// Cancel pending auto-reconnect
  void _cancelAutoReconnect() {
    _autoReconnectTimer?.cancel();
    _autoReconnectTimer = null;
  }

  /// Auto-connect to Android devices on Linux
  Future<void> _autoConnectLinux() async {
    if (!Platform.isLinux || _linuxImpl == null) {
      LogService().log(
        'UsbAoa: _autoConnectLinux skipped (Linux=${Platform.isLinux}, impl=${_linuxImpl != null})',
      );
      return;
    }

    LogService().log('UsbAoa: _autoConnectLinux() starting...');

    try {
      final devices = await _linuxImpl!.listDevices();
      LogService().log('UsbAoa: Found ${devices.length} device(s)');

      for (final device in devices) {
        LogService().log(
          'UsbAoa: Found ${device.manufacturer ?? "unknown"} ${device.product ?? ""} (${device.vidHex}:${device.pidHex})',
        );
      }

      if (devices.isEmpty) {
        LogService().log('UsbAoa: No Android devices found');
        return;
      }

      // Try to connect to first available device
      for (final device in devices) {
        LogService().log(
          'UsbAoa: Attempting to connect to ${device.devPath}...',
        );
        _connectionState = UsbAoaConnectionState.connecting;
        _connectionStateController.add(_connectionState);

        final success = await _linuxImpl!.connect(device);
        if (success) {
          LogService().log('UsbAoa: Connected successfully!');
          return;
        } else {
          LogService().log('UsbAoa: Failed to connect to ${device.devPath}');
        }
      }

      _connectionState = UsbAoaConnectionState.disconnected;
      _connectionStateController.add(_connectionState);
    } catch (e) {
      LogService().log('UsbAoa: Auto-connect error: $e');
      _connectionState = UsbAoaConnectionState.disconnected;
      _connectionStateController.add(_connectionState);
    }
  }

  /// Counter for periodic scan logging (to avoid spam)
  int _periodicScanCount = 0;

  /// Start periodic scanning for USB devices on Linux (hotplug detection)
  void _startLinuxPeriodicScan() {
    if (!Platform.isLinux || _linuxImpl == null) return;
    _stopLinuxPeriodicScan();

    LogService().log('UsbAoa: Starting periodic USB scan (every 2s)');
    _periodicScanCount = 0;

    // Scan every 2 seconds when not connected for faster hotplug detection
    _linuxScanTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      _periodicScanCount++;
      if (_connectionState == UsbAoaConnectionState.connected ||
          _connectionState == UsbAoaConnectionState.connecting) {
        return; // Already connected or connecting, skip scan
      }

      try {
        final devices = await _linuxImpl!.listDevices();
        if (devices.isNotEmpty) {
          LogService().log(
            'UsbAoa: Hotplug detected ${devices.length} device(s)',
          );
          for (final d in devices) {
            LogService().log(
              'UsbAoa:   - ${d.vidHex}:${d.pidHex} ${d.manufacturer ?? ""} ${d.product ?? ""} isAoa=${d.isAoaDevice}',
            );
          }
          await _autoConnectLinux();
        } else if (_periodicScanCount % 30 == 0) {
          // Log every ~60 seconds when no devices found
          LogService().log(
            'UsbAoa: Periodic scan #$_periodicScanCount - no devices',
          );
        }
      } catch (e) {
        LogService().log('UsbAoa: Periodic scan error: $e');
      }
    });
  }

  /// Stop periodic scanning
  void _stopLinuxPeriodicScan() {
    _linuxScanTimer?.cancel();
    _linuxScanTimer = null;
  }

  /// Handle method calls from native code
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onAccessoryConnected':
        final args = call.arguments as Map?;
        if (args != null) {
          _accessoryInfo = UsbAccessoryInfo.fromMap(
            Map<String, dynamic>.from(args),
          );
        }
        _connectionState = UsbAoaConnectionState.connected;
        _connectionStateController.add(_connectionState);
        LogService().log('UsbAoa: Accessory connected - $_accessoryInfo');
        break;

      case 'onAccessoryDisconnected':
        _accessoryInfo = null;
        _remoteCallsign = null;
        _connectionState = UsbAoaConnectionState.disconnected;
        _connectionStateController.add(_connectionState);
        LogService().log('UsbAoa: Accessory disconnected');
        break;

      case 'onDataReceived':
        final args = call.arguments as Map?;
        if (args != null) {
          final data = args['data'];
          if (data is Uint8List) {
            LogService().log('UsbAoa: Received ${data.length} bytes');
            _dataController.add(data);
          } else if (data is List<int>) {
            LogService().log('UsbAoa: Received ${data.length} bytes');
            _dataController.add(Uint8List.fromList(data));
          } else {
            LogService().log('UsbAoa: Unknown data type: ${data.runtimeType}');
          }
        }
        break;

      case 'onError':
        final args = call.arguments as Map?;
        final error = args?['error'] as String? ?? 'Unknown error';
        LogService().log('UsbAoa: Error - $error');
        break;

      default:
        LogService().log('UsbAoa: Unknown method call ${call.method}');
    }
  }

  /// Open the USB accessory connection
  Future<bool> open() async {
    if (!isAvailable || !_isInitialized) {
      LogService().log('UsbAoa: Cannot open - not initialized');
      return false;
    }

    if (isConnected) {
      LogService().log('UsbAoa: Already connected');
      return true;
    }

    try {
      _connectionState = UsbAoaConnectionState.connecting;
      _connectionStateController.add(_connectionState);

      if (Platform.isLinux) {
        // Linux: Scan for Android devices and connect
        final devices = await _linuxImpl!.listDevices();
        if (devices.isEmpty) {
          LogService().log('UsbAoa: No Android devices found');
          _connectionState = UsbAoaConnectionState.disconnected;
          _connectionStateController.add(_connectionState);
          return false;
        }

        // Try to connect to first available device
        for (final device in devices) {
          LogService().log(
            'UsbAoa: Found ${device.manufacturer ?? "unknown"} ${device.product ?? ""} (${device.vidHex}:${device.pidHex})',
          );
          if (await _linuxImpl!.connect(device)) {
            return true;
          }
        }

        _connectionState = UsbAoaConnectionState.disconnected;
        _connectionStateController.add(_connectionState);
        return false;
      } else {
        // Android: Use method channel
        await _channel.invokeMethod('open');
        return true;
      }
    } on PlatformException catch (e) {
      LogService().log('UsbAoa: Failed to open - ${e.message}');
      _connectionState = UsbAoaConnectionState.disconnected;
      _connectionStateController.add(_connectionState);
      return false;
    } on MissingPluginException {
      LogService().log('UsbAoa: Open not implemented');
      _connectionState = UsbAoaConnectionState.disconnected;
      _connectionStateController.add(_connectionState);
      return false;
    }
  }

  /// List available USB devices (Linux only)
  Future<List<UsbDeviceInfo>> listDevices() async {
    if (!Platform.isLinux || _linuxImpl == null) {
      return [];
    }
    return await _linuxImpl!.listDevices();
  }

  /// Connect to a specific device (Linux only)
  Future<bool> connectToDevice(UsbDeviceInfo device) async {
    if (!Platform.isLinux || _linuxImpl == null) {
      return false;
    }

    _connectionState = UsbAoaConnectionState.connecting;
    _connectionStateController.add(_connectionState);

    final success = await _linuxImpl!.connect(device);
    if (!success) {
      _connectionState = UsbAoaConnectionState.disconnected;
      _connectionStateController.add(_connectionState);
    }
    return success;
  }

  /// Close the USB accessory connection
  Future<void> close() async {
    if (!isAvailable || !_isInitialized) return;

    // Mark as user-initiated to prevent auto-reconnect
    _userInitiatedDisconnect = true;
    _cancelAutoReconnect();

    try {
      _connectionState = UsbAoaConnectionState.disconnecting;
      _connectionStateController.add(_connectionState);

      if (Platform.isLinux) {
        await _linuxImpl?.disconnect();
      } else {
        await _channel.invokeMethod('close');
      }

      _accessoryInfo = null;
      _remoteCallsign = null;
      _connectionState = UsbAoaConnectionState.disconnected;
      _connectionStateController.add(_connectionState);
    } on PlatformException catch (e) {
      LogService().log('UsbAoa: Failed to close - ${e.message}');
    } on MissingPluginException {
      // Ignore
    }
  }

  /// Write data to the USB accessory
  Future<bool> write(Uint8List data) async {
    if (!isConnected) {
      LogService().log('UsbAoa: Cannot write - not connected');
      return false;
    }

    try {
      if (Platform.isLinux) {
        return await _linuxImpl!.write(data);
      } else {
        await _channel.invokeMethod('write', {'data': data});
        return true;
      }
    } on PlatformException catch (e) {
      LogService().log('UsbAoa: Failed to write - ${e.message}');
      return false;
    } on MissingPluginException {
      LogService().log('UsbAoa: Write not implemented');
      return false;
    }
  }

  /// Check if we have permission to access the USB accessory
  Future<bool> hasPermission() async {
    if (!isAvailable || !_isInitialized) return false;

    try {
      final result = await _channel.invokeMethod<bool>('hasPermission');
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Request permission to access the USB accessory
  Future<void> requestPermission() async {
    if (!isAvailable || !_isInitialized) return;

    try {
      await _channel.invokeMethod('requestPermission');
    } on PlatformException catch (e) {
      LogService().log('UsbAoa: Failed to request permission - ${e.message}');
    } on MissingPluginException {
      LogService().log('UsbAoa: Request permission not implemented');
    }
  }

  /// Get information about the connected accessory
  Future<UsbAccessoryInfo?> getAccessoryInfo() async {
    if (!isAvailable || !_isInitialized) return null;

    try {
      final result = await _channel.invokeMethod<Map>('getAccessoryInfo');
      if (result == null) return null;
      return UsbAccessoryInfo.fromMap(Map<String, dynamic>.from(result));
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Set the remote device's callsign (discovered during protocol handshake)
  void setRemoteCallsign(String callsign) {
    if (_remoteCallsign == callsign) return;
    _remoteCallsign = callsign;
    _remoteCallsignController.add(callsign);
    LogService().log('UsbAoa: Remote callsign set to $callsign');
  }

  /// Dispose resources
  Future<void> dispose() async {
    await close();

    // Clean up Linux subscriptions and timer
    _stopLinuxPeriodicScan();
    _cancelAutoReconnect();
    await _linuxConnectionSub?.cancel();
    _linuxConnectionSub = null;
    await _linuxDataSub?.cancel();
    _linuxDataSub = null;
    await _linuxImpl?.dispose();
    _linuxImpl = null;

    await _connectionStateController.close();
    await _dataController.close();
    await _remoteCallsignController.close();
    _isInitialized = false;
  }
}
