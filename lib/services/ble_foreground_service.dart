/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'log_service.dart';

/// Callback type for when the foreground service triggers a keep-alive ping.
/// This allows the WebSocketService to receive periodic ping triggers from the
/// Android foreground service, which runs even when the display is off.
typedef KeepAlivePingCallback = void Function();

/// Service to manage the foreground service on Android.
/// This keeps BLE and WebSocket connections active when app goes to background.
///
/// On Android, when the display is off, the Flutter engine can be throttled,
/// causing timers to not fire reliably. This service uses a native Android
/// Handler that continues to run in the foreground service, triggering callbacks
/// to Dart to send WebSocket keep-alive pings.
class BLEForegroundService {
  static final BLEForegroundService _instance = BLEForegroundService._internal();
  factory BLEForegroundService() => _instance;
  BLEForegroundService._internal() {
    // Set up method call handler for callbacks from Android
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const _channel = MethodChannel('dev.geogram/ble_service');
  bool _isRunning = false;
  bool _keepAliveEnabled = false;

  /// Callback to invoke when the foreground service triggers a keep-alive ping
  KeepAlivePingCallback? onKeepAlivePing;

  /// Whether the foreground service is currently running
  bool get isRunning => _isRunning;

  /// Whether WebSocket keep-alive is enabled in the foreground service
  bool get keepAliveEnabled => _keepAliveEnabled;

  /// Handle method calls from Android native code
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onKeepAlivePing':
        LogService().log('BLEForegroundService: Keep-alive ping received from Android');
        onKeepAlivePing?.call();
        break;
      default:
        LogService().log('BLEForegroundService: Unknown method ${call.method}');
    }
  }

  /// Start the foreground service (Android only)
  /// This shows a persistent notification and keeps connections active in background
  Future<bool> start() async {
    if (kIsWeb || !Platform.isAndroid) {
      return false; // Only needed on Android
    }

    if (_isRunning) {
      LogService().log('BLEForegroundService: Already running');
      return true;
    }

    try {
      final result = await _channel.invokeMethod<bool>('startBLEService');
      _isRunning = result ?? false;
      if (_isRunning) {
        LogService().log('BLEForegroundService: Started successfully');
      } else {
        LogService().log('BLEForegroundService: Failed to start');
      }
      return _isRunning;
    } catch (e) {
      LogService().log('BLEForegroundService: Error starting: $e');
      return false;
    }
  }

  /// Stop the foreground service
  Future<bool> stop() async {
    if (kIsWeb || !Platform.isAndroid) {
      return false;
    }

    if (!_isRunning) {
      return true;
    }

    try {
      // Disable keep-alive first
      await disableKeepAlive();

      final result = await _channel.invokeMethod<bool>('stopBLEService');
      _isRunning = !(result ?? true);
      LogService().log('BLEForegroundService: Stopped');
      return !_isRunning;
    } catch (e) {
      LogService().log('BLEForegroundService: Error stopping: $e');
      return false;
    }
  }

  /// Enable WebSocket keep-alive in the foreground service.
  /// This should be called after WebSocket connects to the station.
  /// The foreground service will periodically trigger [onKeepAlivePing] even
  /// when the display is off, allowing the WebSocket connection to stay alive.
  ///
  /// [stationName] - Optional friendly name for the station (e.g., "P2P Radio")
  /// [stationUrl] - The station URL/hostname (e.g., "p2p.radio")
  Future<bool> enableKeepAlive({String? stationName, String? stationUrl}) async {
    if (kIsWeb || !Platform.isAndroid) {
      return false; // Only needed on Android
    }

    if (_keepAliveEnabled) {
      LogService().log('BLEForegroundService: Keep-alive already enabled');
      return true;
    }

    // Start the service if not running
    if (!_isRunning) {
      await start();
    }

    try {
      final result = await _channel.invokeMethod<bool>('enableKeepAlive', {
        'stationName': stationName,
        'stationUrl': stationUrl,
      });
      _keepAliveEnabled = result ?? false;
      if (_keepAliveEnabled) {
        LogService().log('BLEForegroundService: WebSocket keep-alive enabled for ${stationName ?? stationUrl ?? "station"}');
      } else {
        LogService().log('BLEForegroundService: Failed to enable keep-alive');
      }
      return _keepAliveEnabled;
    } catch (e) {
      LogService().log('BLEForegroundService: Error enabling keep-alive: $e');
      return false;
    }
  }

  /// Disable WebSocket keep-alive in the foreground service.
  /// This should be called when WebSocket disconnects from the station.
  Future<bool> disableKeepAlive() async {
    if (kIsWeb || !Platform.isAndroid) {
      return false;
    }

    if (!_keepAliveEnabled) {
      return true;
    }

    try {
      final result = await _channel.invokeMethod<bool>('disableKeepAlive');
      _keepAliveEnabled = !(result ?? true);
      LogService().log('BLEForegroundService: WebSocket keep-alive disabled');
      return !_keepAliveEnabled;
    } catch (e) {
      LogService().log('BLEForegroundService: Error disabling keep-alive: $e');
      return false;
    }
  }
}
