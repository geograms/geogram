/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' show Platform;
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'log_service.dart';

/// Service for managing BLE permissions on Android
/// Handles requesting and checking BLUETOOTH_SCAN, BLUETOOTH_CONNECT, and BLUETOOTH_ADVERTISE
class BLEPermissionService {
  static final BLEPermissionService _instance = BLEPermissionService._internal();
  factory BLEPermissionService() => _instance;
  BLEPermissionService._internal();

  bool _permissionsRequested = false;
  bool _scanPermissionGranted = false;
  bool _advertisePermissionGranted = false;
  bool _connectPermissionGranted = false;

  /// Check if BLE is available on this platform
  bool get isSupported {
    if (kIsWeb) return false;
    return true; // Android, iOS, Linux, macOS, Windows
  }

  /// Check if we're on Android (where runtime permissions are needed)
  bool get needsRuntimePermissions {
    if (kIsWeb) return false;
    return Platform.isAndroid;
  }

  /// Check if scan permission has been granted
  bool get hasScanPermission => _scanPermissionGranted;

  /// Check if advertise permission has been granted
  bool get hasAdvertisePermission => _advertisePermissionGranted;

  /// Request all BLE permissions
  /// Should be called early in app lifecycle (e.g., during onboarding)
  Future<bool> requestAllPermissions() async {
    if (!isSupported) return false;
    if (!needsRuntimePermissions) {
      // Non-Android platforms don't need runtime permissions
      _scanPermissionGranted = true;
      _connectPermissionGranted = true;
      _advertisePermissionGranted = true;
      return true;
    }

    if (_permissionsRequested && _scanPermissionGranted && _connectPermissionGranted && _advertisePermissionGranted) {
      // Already requested and granted
      LogService().log('BLEPermission: All permissions already granted');
      return true;
    }

    _permissionsRequested = true;
    LogService().log('BLEPermission: Requesting BLE permissions via permission_handler...');

    try {
      // Check if Bluetooth is supported
      if (!await FlutterBluePlus.isSupported) {
        LogService().log('BLEPermission: Bluetooth not supported on this device');
        return false;
      }

      // Request all BLE permissions explicitly using permission_handler
      // This shows actual system permission dialogs on Android 12+

      // 1. Request BLUETOOTH_SCAN permission
      LogService().log('BLEPermission: Requesting BLUETOOTH_SCAN...');
      final scanStatus = await Permission.bluetoothScan.request();
      _scanPermissionGranted = scanStatus.isGranted;
      LogService().log('BLEPermission: BLUETOOTH_SCAN: ${scanStatus.name}');

      // 2. Request BLUETOOTH_CONNECT permission
      LogService().log('BLEPermission: Requesting BLUETOOTH_CONNECT...');
      final connectStatus = await Permission.bluetoothConnect.request();
      _connectPermissionGranted = connectStatus.isGranted;
      LogService().log('BLEPermission: BLUETOOTH_CONNECT: ${connectStatus.name}');

      // 3. Request BLUETOOTH_ADVERTISE permission
      LogService().log('BLEPermission: Requesting BLUETOOTH_ADVERTISE...');
      final advertiseStatus = await Permission.bluetoothAdvertise.request();
      _advertisePermissionGranted = advertiseStatus.isGranted;
      LogService().log('BLEPermission: BLUETOOTH_ADVERTISE: ${advertiseStatus.name}');

      // 4. Also request location permission (required for BLE scanning on some devices)
      LogService().log('BLEPermission: Requesting location for BLE...');
      final locationStatus = await Permission.locationWhenInUse.request();
      LogService().log('BLEPermission: LOCATION: ${locationStatus.name}');

      // 5. Request battery optimization exemption (critical for background BLE)
      LogService().log('BLEPermission: Requesting battery optimization exemption...');
      final batteryStatus = await Permission.ignoreBatteryOptimizations.request();
      LogService().log('BLEPermission: BATTERY_OPTIMIZATION: ${batteryStatus.name}');

      // Try to turn on Bluetooth if not already on
      try {
        final adapterState = await FlutterBluePlus.adapterState.first;
        if (adapterState != BluetoothAdapterState.on) {
          LogService().log('BLEPermission: Attempting to turn on Bluetooth...');
          await FlutterBluePlus.turnOn();
          LogService().log('BLEPermission: Bluetooth turned on');
        }
      } catch (e) {
        LogService().log('BLEPermission: Could not turn on Bluetooth: $e');
      }

      // Initialize BlePeripheral for advertising
      if (_advertisePermissionGranted) {
        try {
          await BlePeripheral.initialize();
          LogService().log('BLEPermission: BlePeripheral initialized');
        } catch (e) {
          LogService().log('BLEPermission: BlePeripheral init error: $e');
        }
      }

      final allGranted = _scanPermissionGranted && _connectPermissionGranted && _advertisePermissionGranted;
      LogService().log('BLEPermission: All permissions granted: $allGranted (scan=$_scanPermissionGranted, connect=$_connectPermissionGranted, advertise=$_advertisePermissionGranted)');
      return allGranted;
    } catch (e, stackTrace) {
      LogService().log('BLEPermission: Error requesting permissions: $e');
      LogService().log('BLEPermission: Stack: $stackTrace');
      return false;
    }
  }

  /// Request scan permission only
  Future<bool> requestScanPermission() async {
    if (!isSupported) return false;
    if (!needsRuntimePermissions) {
      _scanPermissionGranted = true;
      return true;
    }

    try {
      if (!await FlutterBluePlus.isSupported) {
        return false;
      }

      // Start a scan to trigger permission dialog
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 1));
      await Future.delayed(const Duration(milliseconds: 500));
      await FlutterBluePlus.stopScan();
      _scanPermissionGranted = true;
      LogService().log('BLEPermission: Scan permission granted');
      return true;
    } catch (e) {
      LogService().log('BLEPermission: Scan permission denied: $e');
      _scanPermissionGranted = false;
      return false;
    }
  }

  /// Check current permission status without requesting
  Future<Map<String, bool>> checkPermissions() async {
    if (!isSupported) {
      return {
        'bluetooth_supported': false,
        'scan': false,
        'connect': false,
        'advertise': false,
      };
    }

    if (!needsRuntimePermissions) {
      return {
        'bluetooth_supported': true,
        'scan': true,
        'connect': true,
        'advertise': true,
      };
    }

    // NOTE: Do NOT call FlutterBluePlus.isSupported here as it triggers Bluetooth
    // platform initialization which can show permission dialogs on Android 12+.
    // We assume Bluetooth is supported on Android devices - actual support check
    // happens in requestAllPermissions() when permissions are requested.

    // Check actual permission status using permission_handler
    // These .status calls do NOT trigger permission dialogs
    final scanStatus = await Permission.bluetoothScan.status;
    final connectStatus = await Permission.bluetoothConnect.status;
    final advertiseStatus = await Permission.bluetoothAdvertise.status;

    _scanPermissionGranted = scanStatus.isGranted;
    _connectPermissionGranted = connectStatus.isGranted;
    _advertisePermissionGranted = advertiseStatus.isGranted;

    return {
      'bluetooth_supported': true, // Assume supported - verified in requestAllPermissions()
      'scan': _scanPermissionGranted,
      'connect': _connectPermissionGranted,
      'advertise': _advertisePermissionGranted,
    };
  }

  /// Update advertise permission status (called by BLE services after attempting to advertise)
  void setAdvertisePermissionGranted(bool granted) {
    _advertisePermissionGranted = granted;
    if (granted) {
      LogService().log('BLEPermission: BLUETOOTH_ADVERTISE permission granted');
    } else {
      LogService().log('BLEPermission: BLUETOOTH_ADVERTISE permission denied');
    }
  }

  /// Reset permission state (e.g., after app update that changes permissions)
  void reset() {
    _permissionsRequested = false;
    _scanPermissionGranted = false;
    _connectPermissionGranted = false;
    _advertisePermissionGranted = false;
  }
}
