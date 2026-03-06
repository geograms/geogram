/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Meshtastic BLE client — manages BLE connection to a Meshtastic radio.
 * Uses Meshtastic BLE service UUID and two-step notification model:
 *   1. FromNum notifies (counter changed)
 *   2. Read FromRadio characteristic repeatedly until empty
 *
 * Follows meshcore_ble_client.dart patterns with Linux retry/backoff.
 */

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../services/log_service.dart';
import 'meshtastic_protobuf.dart';

/// Connection state of the Meshtastic BLE client.
enum MeshtasticBleState { disconnected, scanning, connecting, connected }

/// A discovered Meshtastic device from BLE scan.
class MeshtasticScanResult {
  final BluetoothDevice device;
  final String name;
  final int rssi;

  const MeshtasticScanResult({
    required this.device,
    required this.name,
    required this.rssi,
  });
}

/// BLE client for communicating with a Meshtastic radio.
class MeshtasticBleClient {
  // Meshtastic BLE Service UUID
  static final Guid _serviceGuid =
      Guid('6ba1b218-15a8-461f-9fa8-5dcae273eafd');

  // Characteristic UUIDs
  static final Guid _toRadioGuid = // App -> Device (write)
      Guid('f75c76d2-129e-4dad-a1dd-7866124401e7');
  static final Guid _fromRadioGuid = // Device -> App (read)
      Guid('2c55e69e-4993-11ed-b878-0242ac120002');
  static final Guid _fromNumGuid = // Device -> App (notify, counter)
      Guid('ed9da18c-a800-4f66-a670-aa7547de15f6');

  BluetoothDevice? _device;
  BluetoothCharacteristic? _toRadioChar;
  BluetoothCharacteristic? _fromRadioChar;
  BluetoothCharacteristic? _fromNumChar;
  StreamSubscription<List<int>>? _fromNumSub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;

  MeshtasticBleState _state = MeshtasticBleState.disconnected;
  MeshtasticBleState get state => _state;

  /// Stream of decoded FromRadio messages from the device.
  final _responseController =
      StreamController<MeshtasticFromRadio>.broadcast();
  Stream<MeshtasticFromRadio> get responses => _responseController.stream;

  /// Stream of connection state changes.
  final _stateController = StreamController<MeshtasticBleState>.broadcast();
  Stream<MeshtasticBleState> get stateChanges => _stateController.stream;

  String? get connectedDeviceId => _device?.remoteId.str;

  bool _readingFromRadio = false;

  void _setState(MeshtasticBleState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  /// Scan for Meshtastic devices.
  Future<List<MeshtasticScanResult>> scanForDevices({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    _setState(MeshtasticBleState.scanning);
    final results = <String, MeshtasticScanResult>{};

    StreamSubscription<List<ScanResult>>? sub;
    try {
      sub = FlutterBluePlus.scanResults.listen((scanResults) {
        for (final sr in scanResults) {
          final id = sr.device.remoteId.str;
          if (results.containsKey(id)) continue;
          final name = sr.advertisementData.advName.isNotEmpty
              ? sr.advertisementData.advName
              : sr.device.platformName;
          results[id] = MeshtasticScanResult(
            device: sr.device,
            name: name.isNotEmpty ? name : id,
            rssi: sr.rssi,
          );
        }
      });

      await FlutterBluePlus.startScan(
        withServices: [_serviceGuid],
        timeout: timeout,
      );
      await Future.delayed(timeout);
    } catch (e) {
      LogService().log('MeshtasticBLE: scan error: $e');
    } finally {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await sub?.cancel();
    }

    _setState(MeshtasticBleState.disconnected);
    LogService().log('MeshtasticBLE: scan found ${results.length} devices');
    return results.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  /// Connect to a specific Meshtastic device.
  Future<bool> connect(BluetoothDevice device) async {
    if (_state == MeshtasticBleState.connected && _device == device) {
      return true;
    }

    await disconnect();
    _setState(MeshtasticBleState.connecting);

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
            'MeshtasticBLE: connect attempt $attempt/3 to ${device.remoteId.str}',
          );
          await bleDevice.connect(timeout: connectTimeout);
          connected = true;
          break;
        } catch (e) {
          LogService()
              .log('MeshtasticBLE: connect attempt $attempt failed: $e');
          if (e.toString().contains('Bad state: No element') && attempt < 3) {
            bleDevice = BluetoothDevice.fromId(device.remoteId.str);
          }
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(milliseconds: 500 * attempt));
        }
      }

      if (!connected) throw Exception('Failed to connect');
      _device = bleDevice;

      // Request higher MTU
      try {
        final mtu = await bleDevice.requestMtu(512);
        LogService().log('MeshtasticBLE: MTU negotiated: $mtu');
      } catch (e) {
        LogService().log('MeshtasticBLE: MTU request failed: $e');
      }

      // Discover services with retry
      List<BluetoothService> services = [];
      for (int attempt = 1; attempt <= 3; attempt++) {
        services = await bleDevice.discoverServices();
        if (services.isNotEmpty) break;
        LogService().log(
          'MeshtasticBLE: service discovery attempt $attempt empty',
        );
        await Future.delayed(Duration(milliseconds: 300 * attempt));
      }

      // Find Meshtastic service
      BluetoothService? meshService;
      for (final svc in services) {
        if (svc.uuid == _serviceGuid) {
          meshService = svc;
          break;
        }
      }
      if (meshService == null) {
        throw Exception('Meshtastic service not found');
      }

      // Find characteristics
      for (final char in meshService.characteristics) {
        if (char.uuid == _toRadioGuid) _toRadioChar = char;
        if (char.uuid == _fromRadioGuid) _fromRadioChar = char;
        if (char.uuid == _fromNumGuid) _fromNumChar = char;
      }

      if (_toRadioChar == null || _fromRadioChar == null) {
        throw Exception(
          'Meshtastic characteristics not found '
          '(toRadio=${_toRadioChar != null}, fromRadio=${_fromRadioChar != null}, '
          'fromNum=${_fromNumChar != null})',
        );
      }

      // Subscribe to FromNum notifications with retry
      if (_fromNumChar != null) {
        for (int attempt = 1; attempt <= 3; attempt++) {
          try {
            await _fromNumChar!.setNotifyValue(true);
            LogService()
                .log('MeshtasticBLE: subscribed to FromNum notifications');
            break;
          } catch (e) {
            LogService().log(
              'MeshtasticBLE: FromNum subscribe attempt $attempt failed: $e',
            );
            if (attempt == 3) rethrow;
            await Future.delayed(Duration(milliseconds: 200 * attempt));
          }
        }
      }

      // Stabilize delay for BlueZ
      final delay = Platform.isLinux
          ? const Duration(milliseconds: 500)
          : const Duration(milliseconds: 200);
      await Future.delayed(delay);

      // Listen for FromNum notifications (two-step model)
      _fromNumSub = _fromNumChar?.onValueReceived.listen((_) {
        _drainFromRadio();
      });

      // Listen for disconnection
      _connStateSub = bleDevice.connectionState.listen((connState) {
        if (connState == BluetoothConnectionState.disconnected) {
          LogService().log('MeshtasticBLE: device disconnected');
          _cleanupConnection();
          _setState(MeshtasticBleState.disconnected);
        }
      });

      _setState(MeshtasticBleState.connected);
      LogService().log(
        'MeshtasticBLE: connected to ${device.remoteId.str}',
      );
      return true;
    } catch (e) {
      LogService().log('MeshtasticBLE: connect failed: $e');
      _cleanupConnection();
      _setState(MeshtasticBleState.disconnected);
      return false;
    }
  }

  /// Send a ToRadio protobuf message to the device.
  Future<void> sendToRadio(MeshtasticToRadio toRadio) async {
    if (_toRadioChar == null || _state != MeshtasticBleState.connected) {
      throw Exception('Not connected');
    }

    final payload = toRadio.encode();
    final frame = frameBlePacket(payload);

    // Chunk if larger than MTU
    int mtu;
    try {
      mtu = await _device!.mtu.first.timeout(const Duration(seconds: 2));
      if (mtu < 23) mtu = 23;
    } catch (_) {
      mtu = 23;
    }
    final chunkSize = mtu - 3;

    if (frame.length <= chunkSize) {
      await _toRadioChar!.write(frame.toList(), withoutResponse: false);
    } else {
      for (int i = 0; i < frame.length; i += chunkSize) {
        final end =
            (i + chunkSize < frame.length) ? i + chunkSize : frame.length;
        await _toRadioChar!.write(
          frame.sublist(i, end).toList(),
          withoutResponse: false,
        );
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }
  }

  /// Read FromRadio repeatedly until empty (two-step notification model).
  Future<void> _drainFromRadio() async {
    if (_fromRadioChar == null || _readingFromRadio) return;
    _readingFromRadio = true;

    try {
      while (_state == MeshtasticBleState.connected) {
        final data = await _fromRadioChar!.read();
        if (data.isEmpty) break;

        try {
          // Strip BLE frame header if present
          Uint8List payload;
          final raw = Uint8List.fromList(data);
          final deframed = deframeBleData(raw);
          if (deframed != null) {
            payload = deframed.$1;
          } else {
            payload = raw;
          }

          if (payload.isNotEmpty) {
            final fromRadio = MeshtasticFromRadio.decode(payload);
            _responseController.add(fromRadio);
          }
        } catch (e) {
          LogService().log('MeshtasticBLE: decode error: $e');
        }
      }
    } catch (e) {
      LogService().log('MeshtasticBLE: drainFromRadio error: $e');
    } finally {
      _readingFromRadio = false;
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
    _setState(MeshtasticBleState.disconnected);
  }

  void _cleanupConnection() {
    _fromNumSub?.cancel();
    _fromNumSub = null;
    _connStateSub?.cancel();
    _connStateSub = null;
    _toRadioChar = null;
    _fromRadioChar = null;
    _fromNumChar = null;
    _device = null;
    _readingFromRadio = false;
  }

  void dispose() {
    disconnect();
    _responseController.close();
    _stateController.close();
  }
}
