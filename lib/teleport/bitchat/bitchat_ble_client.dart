/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BitChat BLE mesh client — scan for peers, advertise, connect,
 * send/receive BitchatPackets with TTL-based relay.
 *
 * Uses flutter_blue_plus (same as MeshCore BLE client) but operates
 * independently with BitChat's own BLE service UUID.
 *
 * Linux-specific handling:
 *   - Extended connection timeout (15s vs 10s)
 *   - Post-connect stabilization delay (500ms vs 200ms)
 *   - Retry logic for BlueZ "Bad state: No element" errors
 *   - Service discovery retries
 *   - BlueZ diagnostic logging
 */

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../services/log_service.dart';
import 'bitchat_protocol.dart';

/// Connection state of the BitChat BLE client.
enum BitchatBleState { disabled, scanning, idle, connected }

/// A discovered BitChat peer from BLE scan.
class BitchatBleScanResult {
  final BluetoothDevice device;
  final String name;
  final int rssi;

  const BitchatBleScanResult({
    required this.device,
    required this.name,
    required this.rssi,
  });
}

/// BLE client for communicating with BitChat mesh peers.
class BitchatBleClient {
  // BitChat BLE Service UUID (distinct from MeshCore's Nordic UART and geogram's FFE0)
  static final Guid _bitchatServiceGuid =
      Guid('B17C4A70-0001-4000-8000-00805F9B34FB');
  static final Guid _bitchatRxGuid = // App → Peer (write)
      Guid('B17C4A70-0002-4000-8000-00805F9B34FB');
  static final Guid _bitchatTxGuid = // Peer → App (notify)
      Guid('B17C4A70-0003-4000-8000-00805F9B34FB');

  final Map<String, BluetoothDevice> _connectedDevices = {};
  final Map<String, BluetoothCharacteristic> _rxChars = {};
  final Map<String, StreamSubscription<List<int>>> _txSubs = {};
  final Map<String, StreamSubscription<BluetoothConnectionState>> _connSubs =
      {};

  BitchatBleState _state = BitchatBleState.disabled;
  BitchatBleState get state => _state;

  /// Stream of raw received packets from any connected peer.
  final _packetController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get packets => _packetController.stream;

  /// Stream of connection state changes.
  final _stateController = StreamController<BitchatBleState>.broadcast();
  Stream<BitchatBleState> get stateChanges => _stateController.stream;

  /// Number of currently connected peers.
  int get connectedPeerCount => _connectedDevices.length;

  /// Receive buffer per device for reassembly.
  final Map<String, List<int>> _rxBuffers = {};

  void _setState(BitchatBleState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  /// Scan for BitChat peers (filters by BitChat service UUID).
  Future<List<BitchatBleScanResult>> scanForPeers({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (_state == BitchatBleState.disabled) return [];

    _setState(BitchatBleState.scanning);
    final results = <BitchatBleScanResult>[];

    try {
      // Check BLE adapter state
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        LogService().log('BitchatBLE: adapter not on ($adapterState)');
        if (Platform.isLinux) {
          LogService().log(
            'BitchatBLE: On Linux, ensure BlueZ is installed and bluetooth '
            'service is running. Try: sudo systemctl start bluetooth',
          );
        }
        _setState(BitchatBleState.idle);
        return [];
      }

      await FlutterBluePlus.startScan(
        withServices: [_bitchatServiceGuid],
        timeout: timeout,
        androidUsesFineLocation: true,
      );

      // Wait for the full scan duration instead of just the first batch.
      // Collect all results emitted during the scan period.
      await FlutterBluePlus.isScanning
          .firstWhere((scanning) => scanning == false);

      final scanResults = FlutterBluePlus.lastScanResults;
      for (final r in scanResults) {
        final name = r.device.platformName.isNotEmpty
            ? r.device.platformName
            : r.advertisementData.advName;
        results.add(BitchatBleScanResult(
          device: r.device,
          name: name.isEmpty ? r.device.remoteId.str : name,
          rssi: r.rssi,
        ));
      }

      LogService().log(
        'BitchatBLE: scan complete, found ${results.length} peer(s)',
      );
    } catch (e) {
      LogService().log('BitchatBLE: scan error: $e');
      if (Platform.isLinux) {
        LogService().log(
          'BitchatBLE: Linux BLE error — check: '
          '1) BlueZ installed, 2) bluetooth service running, '
          '3) user in bluetooth group',
        );
      }
    }

    _setState(BitchatBleState.idle);
    return results;
  }

  /// Connect to a peer device and set up packet exchange.
  /// Includes Linux-specific retry logic and timeout tuning.
  Future<bool> connectToPeer(BluetoothDevice device) async {
    final deviceId = device.remoteId.str;
    if (_connectedDevices.containsKey(deviceId)) return true;

    final connectTimeout = Platform.isLinux
        ? const Duration(seconds: 15)
        : const Duration(seconds: 10);

    try {
      // Retry connection up to 3 times with backoff (BlueZ reliability)
      bool connected = false;
      BluetoothDevice bleDevice = device;

      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          LogService().log(
            'BitchatBLE: connect attempt $attempt/3 to $deviceId',
          );
          await bleDevice.connect(
            autoConnect: false,
            timeout: connectTimeout,
          );
          connected = true;
          break;
        } catch (e) {
          LogService()
              .log('BitchatBLE: connect attempt $attempt failed: $e');
          // BlueZ can return "Bad state: No element" — recreate device ref
          if (e.toString().contains('Bad state: No element') && attempt < 3) {
            bleDevice = BluetoothDevice.fromId(device.remoteId.str);
          }
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(milliseconds: 500 * attempt));
        }
      }

      if (!connected) throw Exception('Failed to connect after 3 attempts');

      // Request higher MTU on Android
      if (Platform.isAndroid) {
        try {
          final mtu = await bleDevice.requestMtu(512);
          LogService().log('BitchatBLE: MTU negotiated: $mtu');
        } catch (e) {
          LogService().log('BitchatBLE: MTU request failed: $e');
        }
      }

      // Post-connect stabilization delay (BlueZ needs more time)
      final stabilizationDelay = Platform.isLinux
          ? const Duration(milliseconds: 500)
          : const Duration(milliseconds: 200);
      await Future.delayed(stabilizationDelay);

      // Discover services with retry
      List<BluetoothService> services = [];
      for (int attempt = 1; attempt <= 3; attempt++) {
        services = await bleDevice.discoverServices();
        if (services.isNotEmpty) break;
        LogService().log(
          'BitchatBLE: service discovery attempt $attempt empty',
        );
        await Future.delayed(Duration(milliseconds: 300 * attempt));
      }

      BluetoothService? bitchatService;
      for (final s in services) {
        if (s.serviceUuid == _bitchatServiceGuid) {
          bitchatService = s;
          break;
        }
      }

      if (bitchatService == null) {
        LogService().log('BitchatBLE: service not found on $deviceId');
        await bleDevice.disconnect();
        return false;
      }

      BluetoothCharacteristic? rxChar, txChar;
      for (final c in bitchatService.characteristics) {
        if (c.characteristicUuid == _bitchatRxGuid) rxChar = c;
        if (c.characteristicUuid == _bitchatTxGuid) txChar = c;
      }

      if (rxChar == null || txChar == null) {
        LogService().log(
          'BitchatBLE: characteristics not found on $deviceId '
          '(rx=${rxChar != null}, tx=${txChar != null})',
        );
        await bleDevice.disconnect();
        return false;
      }

      // Enable notifications with retry
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          await txChar.setNotifyValue(true);
          LogService().log('BitchatBLE: subscribed to TX notifications');
          break;
        } catch (e) {
          LogService().log(
            'BitchatBLE: TX subscribe attempt $attempt failed: $e',
          );
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(milliseconds: 200 * attempt));
        }
      }

      _rxBuffers[deviceId] = [];
      final txSub = txChar.onValueReceived.listen((data) {
        _onTxData(deviceId, data);
      });

      // Monitor connection state
      final connSub = bleDevice.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onPeerDisconnected(deviceId);
        }
      });

      _connectedDevices[deviceId] = bleDevice;
      _rxChars[deviceId] = rxChar;
      _txSubs[deviceId] = txSub;
      _connSubs[deviceId] = connSub;

      if (_connectedDevices.isNotEmpty) {
        _setState(BitchatBleState.connected);
      }

      LogService().log('BitchatBLE: connected to $deviceId');
      return true;
    } catch (e) {
      LogService().log('BitchatBLE: connect error for $deviceId: $e');
      return false;
    }
  }

  /// Send a packet to a specific connected peer.
  Future<void> sendToPeer(String deviceId, Uint8List data) async {
    final rxChar = _rxChars[deviceId];
    if (rxChar == null) return;

    try {
      // Chunk by MTU if needed
      final mtu = _connectedDevices[deviceId]?.mtuNow ?? 20;
      final chunkSize = mtu - 3; // ATT header overhead

      if (data.length <= chunkSize) {
        await rxChar.write(data, withoutResponse: false);
      } else {
        for (int i = 0; i < data.length; i += chunkSize) {
          final end =
              (i + chunkSize > data.length) ? data.length : i + chunkSize;
          await rxChar.write(data.sublist(i, end), withoutResponse: false);
        }
      }
    } catch (e) {
      LogService().log('BitchatBLE: send error to $deviceId: $e');
    }
  }

  /// Broadcast a packet to all connected peers.
  Future<void> broadcastToAll(Uint8List data) async {
    for (final deviceId in _connectedDevices.keys.toList()) {
      await sendToPeer(deviceId, data);
    }
  }

  /// Disconnect from a specific peer.
  Future<void> disconnectPeer(String deviceId) async {
    await _cleanupPeer(deviceId);
  }

  /// Disconnect from all peers and stop scanning.
  Future<void> disconnectAll() async {
    for (final deviceId in _connectedDevices.keys.toList()) {
      await _cleanupPeer(deviceId);
    }
    _setState(BitchatBleState.idle);
  }

  /// Enable BLE operations.
  void enable() {
    if (_state != BitchatBleState.disabled) return;
    _setState(BitchatBleState.idle);
    LogService().log('BitchatBLE: enabled');
  }

  /// Disable BLE operations and disconnect all peers.
  Future<void> disable() async {
    await disconnectAll();
    _setState(BitchatBleState.disabled);
  }

  void dispose() {
    disconnectAll();
    _packetController.close();
    _stateController.close();
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _onTxData(String deviceId, List<int> data) {
    final buffer = _rxBuffers[deviceId];
    if (buffer == null) return;

    buffer.addAll(data);

    // Try to decode complete packets from the buffer
    _processBuffer(deviceId);
  }

  void _processBuffer(String deviceId) {
    final buffer = _rxBuffers[deviceId];
    if (buffer == null) return;

    while (buffer.length >= bitchatHeaderSize + bitchatSenderIdSize) {
      final view = ByteData.sublistView(Uint8List.fromList(buffer));

      // Read payload length and flags from header
      final type = view.getUint8(1);
      final flags = view.getUint8(7);
      final payloadLength = view.getUint32(8, Endian.little);
      final hasRecipient = type == BitchatPacketType.direct;
      final hasSig = (flags & BitchatFlags.signed_) != 0;

      final expectedSize = bitchatHeaderSize +
          bitchatSenderIdSize +
          (hasRecipient ? bitchatRecipientIdSize : 0) +
          payloadLength +
          (hasSig ? bitchatSignatureSize : 0);

      if (buffer.length < expectedSize) break; // wait for more data

      final packetBytes = Uint8List.fromList(buffer.sublist(0, expectedSize));
      buffer.removeRange(0, expectedSize);
      _packetController.add(packetBytes);
    }
  }

  void _onPeerDisconnected(String deviceId) {
    LogService().log('BitchatBLE: peer disconnected: $deviceId');
    _cleanupPeerState(deviceId);
    if (_connectedDevices.isEmpty) {
      _setState(BitchatBleState.idle);
    }
  }

  Future<void> _cleanupPeer(String deviceId) async {
    try {
      await _connectedDevices[deviceId]?.disconnect();
    } catch (_) {}
    _cleanupPeerState(deviceId);
  }

  void _cleanupPeerState(String deviceId) {
    _txSubs[deviceId]?.cancel();
    _txSubs.remove(deviceId);
    _connSubs[deviceId]?.cancel();
    _connSubs.remove(deviceId);
    _connectedDevices.remove(deviceId);
    _rxChars.remove(deviceId);
    _rxBuffers.remove(deviceId);
  }
}
