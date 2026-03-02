/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * MeshCore BLE client — manages BLE connection to a MeshCore companion radio
 * via the Nordic UART Service (NUS). Handles scan, connect, send, receive.
 *
 * Uses flutter_blue_plus (same package as BLEDiscoveryService) but operates
 * independently with different UUIDs (Nordic UART vs Geogram FFE0).
 * Follows the same BlueZ retry/backoff patterns for Linux reliability.
 */

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../services/log_service.dart';
import 'meshcore_protocol.dart';

/// Connection state of the MeshCore BLE client.
enum MeshCoreBleState { disconnected, scanning, connecting, connected }

/// A discovered MeshCore device from BLE scan.
class MeshCoreScanResult {
  final BluetoothDevice device;
  final String name;
  final int rssi;

  const MeshCoreScanResult({
    required this.device,
    required this.name,
    required this.rssi,
  });
}

/// BLE client for communicating with a MeshCore companion radio.
class MeshCoreBleClient {
  // Nordic UART Service UUIDs
  static final Guid _nusServiceGuid =
      Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid _nusRxGuid = // App → Device (write)
      Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid _nusTxGuid = // Device → App (notify)
      Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxChar;
  BluetoothCharacteristic? _txChar;
  StreamSubscription<List<int>>? _txSub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;

  MeshCoreBleState _state = MeshCoreBleState.disconnected;
  MeshCoreBleState get state => _state;

  /// Stream of raw decoded responses from the device.
  final _responseController = StreamController<MeshCoreResponse>.broadcast();
  Stream<MeshCoreResponse> get responses => _responseController.stream;

  /// Stream of connection state changes.
  final _stateController = StreamController<MeshCoreBleState>.broadcast();
  Stream<MeshCoreBleState> get stateChanges => _stateController.stream;

  /// The currently connected device's remote ID.
  String? get connectedDeviceId => _device?.remoteId.str;

  /// Buffer for accumulating partial BLE notifications.
  final List<int> _rxBuffer = [];

  void _setState(MeshCoreBleState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  /// Scan for MeshCore devices (filters by Nordic UART Service UUID).
  /// Returns a list of discovered devices.
  Future<List<MeshCoreScanResult>> scanForDevices({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    _setState(MeshCoreBleState.scanning);
    final results = <String, MeshCoreScanResult>{};

    StreamSubscription<List<ScanResult>>? sub;
    try {
      sub = FlutterBluePlus.scanResults.listen((scanResults) {
        for (final sr in scanResults) {
          final id = sr.device.remoteId.str;
          if (results.containsKey(id)) continue;
          final name = sr.advertisementData.advName.isNotEmpty
              ? sr.advertisementData.advName
              : sr.device.platformName;
          results[id] = MeshCoreScanResult(
            device: sr.device,
            name: name.isNotEmpty ? name : id,
            rssi: sr.rssi,
          );
        }
      });

      await FlutterBluePlus.startScan(
        withServices: [_nusServiceGuid],
        timeout: timeout,
      );
      await Future.delayed(timeout);
    } catch (e) {
      LogService().log('MeshCoreBLE: scan error: $e');
    } finally {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await sub?.cancel();
    }

    _setState(MeshCoreBleState.disconnected);
    LogService().log('MeshCoreBLE: scan found ${results.length} devices');
    return results.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  /// Connect to a specific MeshCore device.
  /// After connection, discovers services, subscribes to TX notifications,
  /// and transitions to [MeshCoreBleState.connected].
  Future<bool> connect(BluetoothDevice device) async {
    if (_state == MeshCoreBleState.connected && _device == device) {
      return true;
    }

    // Disconnect previous device if any
    await disconnect();
    _setState(MeshCoreBleState.connecting);

    final connectTimeout = Platform.isLinux
        ? const Duration(seconds: 15)
        : const Duration(seconds: 10);

    try {
      // Retry connection up to 3 times with backoff
      bool connected = false;
      BluetoothDevice bleDevice = device;

      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          LogService().log(
            'MeshCoreBLE: connect attempt $attempt/3 to ${device.remoteId.str}',
          );
          await bleDevice.connect(timeout: connectTimeout);
          connected = true;
          break;
        } catch (e) {
          LogService().log('MeshCoreBLE: connect attempt $attempt failed: $e');
          if (e.toString().contains('Bad state: No element') && attempt < 3) {
            bleDevice = BluetoothDevice.fromId(device.remoteId.str);
          }
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(milliseconds: 500 * attempt));
        }
      }

      if (!connected) throw Exception('Failed to connect');
      _device = bleDevice;

      // Request higher MTU for MeshCore
      try {
        final mtu = await bleDevice.requestMtu(512);
        LogService().log('MeshCoreBLE: MTU negotiated: $mtu');
      } catch (e) {
        LogService().log('MeshCoreBLE: MTU request failed: $e');
      }

      // Discover services with retry
      List<BluetoothService> services = [];
      for (int attempt = 1; attempt <= 3; attempt++) {
        services = await bleDevice.discoverServices();
        if (services.isNotEmpty) break;
        LogService().log(
          'MeshCoreBLE: service discovery attempt $attempt empty',
        );
        await Future.delayed(Duration(milliseconds: 300 * attempt));
      }

      // Find Nordic UART Service
      BluetoothService? nusService;
      for (final svc in services) {
        if (svc.uuid == _nusServiceGuid) {
          nusService = svc;
          break;
        }
      }
      if (nusService == null) {
        throw Exception('Nordic UART Service not found');
      }

      // Find RX and TX characteristics
      for (final char in nusService.characteristics) {
        if (char.uuid == _nusRxGuid) _rxChar = char;
        if (char.uuid == _nusTxGuid) _txChar = char;
      }

      if (_rxChar == null || _txChar == null) {
        throw Exception(
          'NUS characteristics not found (rx=${_rxChar != null}, tx=${_txChar != null})',
        );
      }

      // Subscribe to TX notifications with retry
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          await _txChar!.setNotifyValue(true);
          LogService().log('MeshCoreBLE: subscribed to TX notifications');
          break;
        } catch (e) {
          LogService().log(
            'MeshCoreBLE: TX subscribe attempt $attempt failed: $e',
          );
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(milliseconds: 200 * attempt));
        }
      }

      // Stabilize delay for BlueZ
      final delay = Platform.isLinux
          ? const Duration(milliseconds: 500)
          : const Duration(milliseconds: 200);
      await Future.delayed(delay);

      // Listen for incoming data
      _txSub = _txChar!.onValueReceived.listen(_onTxData);

      // Listen for disconnection
      _connStateSub = bleDevice.connectionState.listen((connState) {
        if (connState == BluetoothConnectionState.disconnected) {
          LogService().log('MeshCoreBLE: device disconnected');
          _cleanupConnection();
          _setState(MeshCoreBleState.disconnected);
        }
      });

      _setState(MeshCoreBleState.connected);
      LogService().log(
        'MeshCoreBLE: connected to ${device.remoteId.str}',
      );
      return true;
    } catch (e) {
      LogService().log('MeshCoreBLE: connect failed: $e');
      _cleanupConnection();
      _setState(MeshCoreBleState.disconnected);
      return false;
    }
  }

  /// Send a raw binary command to the device.
  Future<void> send(Uint8List data) async {
    if (_rxChar == null || _state != MeshCoreBleState.connected) {
      throw Exception('Not connected');
    }

    // Chunk if larger than MTU
    int mtu;
    try {
      mtu = await _device!.mtu.first.timeout(const Duration(seconds: 2));
      if (mtu < 23) mtu = 23;
    } catch (_) {
      mtu = 23;
    }
    final chunkSize = mtu - 3;

    if (data.length <= chunkSize) {
      await _rxChar!.write(data.toList(), withoutResponse: false);
    } else {
      for (int i = 0; i < data.length; i += chunkSize) {
        final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
        await _rxChar!.write(
          data.sublist(i, end).toList(),
          withoutResponse: false,
        );
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }
  }

  /// Send a command and wait for the next response matching [expectedCode].
  Future<MeshCoreResponse> sendAndWait(
    Uint8List data, {
    required int expectedCode,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final completer = Completer<MeshCoreResponse>();
    StreamSubscription<MeshCoreResponse>? sub;

    sub = responses.listen((resp) {
      if (resp.code == expectedCode) {
        if (!completer.isCompleted) completer.complete(resp);
        sub?.cancel();
      }
    });

    try {
      await send(data);
      return await completer.future.timeout(timeout, onTimeout: () {
        sub?.cancel();
        throw TimeoutException('No response for code 0x${expectedCode.toRadixString(16)}');
      });
    } catch (e) {
      sub.cancel();
      rethrow;
    }
  }

  /// Disconnect from the device.
  Future<void> disconnect() async {
    final device = _device;
    _cleanupConnection();
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    _setState(MeshCoreBleState.disconnected);
  }

  /// Handle incoming TX notification data.
  void _onTxData(List<int> data) {
    _rxBuffer.addAll(data);

    // MeshCore BLE protocol: each response starts with a type byte.
    // For simplicity, treat each complete notification as a packet.
    // In practice, we may need length framing — for now, flush on each notify.
    _processBuffer();
  }

  void _processBuffer() {
    if (_rxBuffer.isEmpty) return;

    // MeshCore sends complete packets per notification in most cases.
    // Process the entire buffer as one response.
    try {
      final response = decodeResponse(Uint8List.fromList(_rxBuffer));
      _rxBuffer.clear();
      _responseController.add(response);
    } catch (e) {
      LogService().log('MeshCoreBLE: decode error: $e');
      _rxBuffer.clear();
    }
  }

  void _cleanupConnection() {
    _txSub?.cancel();
    _txSub = null;
    _connStateSub?.cancel();
    _connStateSub = null;
    _rxChar = null;
    _txChar = null;
    _device = null;
    _rxBuffer.clear();
  }

  /// Dispose all resources.
  void dispose() {
    disconnect();
    _responseController.close();
    _stateController.close();
  }
}
