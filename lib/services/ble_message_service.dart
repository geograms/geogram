/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/ble_message.dart';
import '../models/ble_parcel.dart';
import 'app_args.dart';
import 'ble_discovery_service.dart';
import 'ble_gatt_server_service.dart';
import 'ble_identity_service.dart';
import 'ble_queue_service.dart';
import 'ble_linux_peripheral.dart';
import 'bluetooth_classic_service.dart';
import 'bluetooth_classic_pairing_service.dart';
import 'log_service.dart';

/// Incoming chat message from BLE
class BLEChatMessage {
  final String deviceId;
  final String author;
  final String content;
  final String channel;
  final DateTime timestamp;
  final String? signature;
  final String? npub;

  BLEChatMessage({
    required this.deviceId,
    required this.author,
    required this.content,
    required this.channel,
    required this.timestamp,
    this.signature,
    this.npub,
  });
}

/// High-level BLE messaging service
/// Platform-aware: uses GATT server on Android/iOS, client on Linux/macOS/Windows
class BLEMessageService {
  static final BLEMessageService _instance = BLEMessageService._internal();
  factory BLEMessageService() => _instance;
  BLEMessageService._internal();

  /// Services
  final _discoveryService = BLEDiscoveryService();
  final _gattServer = BLEGattServerService();
  final BleLinuxPeripheral _linuxPeripheral = BleLinuxPeripheral();
  final _identityService = BLEIdentityService();
  final _queueService = BLEQueueService();

  /// Our identity for HELLO handshakes
  Map<String, dynamic>? _ourEvent;
  String? _ourCallsign;

  /// Active connections for parcel-based data transfer
  final Map<String, _BLEDataConnection> _dataConnections = {};

  /// Peer capabilities per device (from HELLO handshake)
  final Map<String, Set<String>> _peerCapabilities = {};

  /// Local Bluetooth Classic MAC for BLE+ support (Android only)
  String? _localClassicMac;
  String? get localClassicMac => _localClassicMac;

  /// Our supported capabilities
  static const List<String> _baseCapabilities = [
    'chat',
    'compression:deflate',
  ];

  static const String _blePlusPairChannel = '_ble_plus';

  static final RegExp _macPattern = RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$');

  List<String> get _ourCapabilities {
    final capabilities = [..._baseCapabilities];
    if (_localClassicMac != null) {
      capabilities.add('bluetooth_classic:spp');
    }
    return capabilities;
  }

  /// Stream controllers
  final _incomingChatsController = StreamController<BLEChatMessage>.broadcast();
  Stream<BLEChatMessage> get incomingChats => _incomingChatsController.stream;

  /// State
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Check if platform can act as server (Android/iOS)
  static bool get canBeServer {
    if (kIsWeb) return false;
    // Linux desktops can run the BlueZ backend to advertise + host GATT.
    return Platform.isAndroid || Platform.isIOS || Platform.isLinux;
  }

  /// Check if platform can act as client (all non-web platforms)
  static bool get canBeClient {
    return !kIsWeb;
  }

  /// Initialize the message service
  /// [event] - Our NOSTR-signed event for HELLO handshakes
  /// [callsign] - Our callsign for identification
  Future<void> initialize({
    required Map<String, dynamic> event,
    required String callsign,
  }) async {
    // Refuse to initialize in internet-only mode
    if (AppArgs().internetOnly) {
      LogService().log('BLEMessageService: Disabled in internet-only mode');
      return;
    }

    if (_isInitialized) {
      LogService().log('BLEMessageService: Already initialized');
      return;
    }

    LogService().log('BLEMessageService: Starting initialization for callsign: $callsign');

    _ourEvent = event;
    _ourCallsign = callsign;

    try {
      // Initialize identity service (generates device ID on first run)
      await _identityService.initialize();
      LogService().log('BLEMessageService: Identity service initialized (device: ${_identityService.deviceId})');

      // BLE+ (Bluetooth Classic) disabled - use pure BLE without pairing
      // if (BluetoothClassicService.isAvailable) {
      //   final btClassic = BluetoothClassicService();
      //   await btClassic.initialize();
      //   _localClassicMac = _sanitizeClassicMac(await btClassic.getLocalMacAddress());
      //   if (_localClassicMac != null) {
      //     LogService().log('BLEMessageService: Bluetooth Classic available (mac: $_localClassicMac)');
      //   } else {
      //     LogService().log('BLEMessageService: Bluetooth Classic MAC unavailable, BLE+ disabled');
      //   }
      // }
      LogService().log('BLEMessageService: BLE+ disabled - using pure BLE');

      // Initialize GATT server
      if (Platform.isLinux) {
        LogService().log('BLEMessageService: Platform can be server - initializing BlueZ peripheral');
        await _linuxPeripheral.initialize(
          callsign: callsign,
          deviceId: _identityService.deviceId,
          onMessage: _handleIncomingMessage,
        );
        await _linuxPeripheral.start(callsign);
        LogService().log('BLEMessageService: BlueZ peripheral started');
        _identityService.startPeriodicAdvertisement();
      } else if (canBeServer) {
        LogService().log('BLEMessageService: Platform can be server - initializing GATT server');
        await _gattServer.initialize();
        LogService().log('BLEMessageService: GATT server initialized');
        _gattServer.setMessageHandler(_handleIncomingMessage);
        LogService().log('BLEMessageService: Message handler set');
        await _gattServer.startServer(callsign);
        LogService().log('BLEMessageService: GATT server started (isRunning: ${_gattServer.isRunning})');

        // Start periodic advertisement on Android/iOS (every 30 seconds)
        _identityService.startPeriodicAdvertisement();
        LogService().log('BLEMessageService: Periodic identity advertisement started');
      } else {
        LogService().log('BLEMessageService: Platform cannot be server - client mode only');
      }

      // Start periodic scanning for peer discovery (every 45 seconds, 8 second duration)
      await _discoveryService.startPeriodicScanning();
      LogService().log('BLEMessageService: Periodic peer scanning started');

      _isInitialized = true;
      LogService().log('BLEMessageService: Initialized successfully '
          '(identity: ${_identityService.fullIdentity}, server: $canBeServer, client: $canBeClient)');
    } catch (e, stackTrace) {
      LogService().log('BLEMessageService: Initialization error: $e');
      LogService().log('BLEMessageService: Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Handle incoming message on GATT server
  Future<Map<String, dynamic>?> _handleIncomingMessage(
    String deviceId,
    Map<String, dynamic> rawMessage,
  ) async {
    try {
      final message = BLEMessage.fromJson(rawMessage);
      LogService().log('BLEMessageService: Received ${message.type.value} from $deviceId');

      switch (message.type) {
        case BLEMessageType.hello:
          return _handleHello(deviceId, message);

        case BLEMessageType.chat:
          return _handleChat(deviceId, message);

        case BLEMessageType.chatAck:
        case BLEMessageType.helloAck:
        case BLEMessageType.error:
          // These are responses, not requests - ignore
          return null;
      }
    } catch (e) {
      LogService().log('BLEMessageService: Error handling message: $e');
      return BLEMessageBuilder.error(
        requestId: rawMessage['id'] as String? ?? 'unknown',
        errorMessage: 'Invalid message format',
        code: 'PARSE_ERROR',
      ).toJson();
    }
  }

  /// Handle HELLO message
  Map<String, dynamic> _handleHello(String deviceId, BLEMessage message) {
    final payload = BLEHelloPayload.fromJson(message.payload);
    LogService().log('BLEMessageService: HELLO from ${payload.callsign ?? deviceId}');

    // Register the client's callsign for server-side responses
    if (payload.callsign != null && payload.callsign!.isNotEmpty) {
      _gattServer.registerClientCallsign(deviceId, payload.callsign!);
      // Also register on Linux peripheral for direct client tracking
      if (Platform.isLinux) {
        _linuxPeripheral.registerClientCallsign(deviceId, payload.callsign!);
      }
    }

    // Store peer capabilities
    final peerCaps = payload.capabilities;
    _peerCapabilities[deviceId] = peerCaps.toSet();
    LogService().log('BLEMessageService: Peer $deviceId capabilities: $peerCaps');

    // Build HELLO_ACK response with our capabilities
    final response = BLEMessageBuilder.helloAck(
      requestId: message.id,
      success: true,
      event: _ourEvent,
      capabilities: _ourCapabilities,
      classicMac: _localClassicMac,
    ).toJson();

    LogService().log('BLEMessageService: Sending HELLO_ACK to $deviceId (${json.encode(response).length} bytes)');
    return response;
  }

  /// Handle CHAT message
  Map<String, dynamic> _handleChat(String deviceId, BLEMessage message) {
    final payload = BLEChatPayload.fromJson(message.payload);

    // Register the client's callsign for server-side responses
    if (payload.author.isNotEmpty) {
      _gattServer.registerClientCallsign(deviceId, payload.author);
      // Also register on Linux peripheral for direct client tracking
      if (Platform.isLinux) {
        _linuxPeripheral.registerClientCallsign(deviceId, payload.author);
      }
    }

    if (_handleBlePlusPairRequest(deviceId, payload)) {
      return BLEMessageBuilder.chatAck(
        requestId: message.id,
        success: true,
      ).toJson();
    }

    // Emit chat to stream
    _incomingChatsController.add(BLEChatMessage(
      deviceId: deviceId,
      author: payload.author,
      content: payload.content,
      channel: payload.channel,
      timestamp: DateTime.fromMillisecondsSinceEpoch(payload.timestamp * 1000),
      signature: payload.signature,
      npub: payload.npub,
    ));

    LogService().log('BLEMessageService: Chat from ${payload.author}: ${payload.content}');

    // Send CHAT_ACK
    return BLEMessageBuilder.chatAck(
      requestId: message.id,
      success: true,
    ).toJson();
  }

  bool _handleBlePlusPairRequest(String deviceId, BLEChatPayload payload) {
    // BLE+ pairing disabled - using pure BLE without pairing
    if (payload.channel != _blePlusPairChannel) return false;
    LogService().log('BLEMessageService: BLE+ pair request ignored (feature disabled)');
    return false; // Don't process pair requests
  }

  /// Send HELLO to a discovered device (client mode)
  Future<bool> sendHello(BLEDevice device) async {
    if (!canBeClient || _ourEvent == null) {
      LogService().log('BLEMessageService: Cannot send HELLO - not initialized or not a client');
      return false;
    }

    try {
      final helloMessage = BLEMessageBuilder.hello(
        event: _ourEvent!,
        capabilities: _ourCapabilities,
      );

      final response = await _discoveryService.sendMessage(
        device,
        helloMessage.toJson(),
        timeout: const Duration(seconds: 10),
      );

      if (response == null) {
        LogService().log('BLEMessageService: No response to HELLO');
        return false;
      }

      final ackMessage = BLEMessage.fromJson(response);
      if (ackMessage.type == BLEMessageType.helloAck) {
        final ack = BLEHelloAckPayload.fromJson(ackMessage.payload);
        if (ack.success) {
          // Store peer capabilities from HELLO_ACK
          final peerCaps = ack.capabilities;
          _peerCapabilities[device.deviceId] = peerCaps.toSet();
          if (ack.event != null) {
            _discoveryService.updateFromHelloEvent(
              device.deviceId,
              ack.event!,
            );
          }
          if (ack.classicMac != null) {
            _discoveryService.updateClassicMac(device.deviceId, ack.classicMac!);
            LogService().log(
              'BLEMessageService: Stored BLE+ MAC for ${device.callsign ?? device.deviceId} (${ack.classicMac})',
            );
          }
          LogService().log('BLEMessageService: HELLO handshake successful with ${device.callsign ?? device.deviceId}');
          LogService().log('BLEMessageService: Peer ${device.deviceId} capabilities: $peerCaps');
          return true;
        }
      }

      return false;
    } catch (e) {
      LogService().log('BLEMessageService: HELLO error: $e');
      return false;
    }
  }

  /// Send chat message to a discovered device (client mode)
  ///
  /// Set [waitForAck] to false for fire-and-forget mode (used for API requests
  /// where we wait for the actual response, not just an ack)
  Future<bool> sendChat({
    required BLEDevice device,
    required String content,
    String channel = 'main',
    String? signature,
    String? npub,
    bool waitForAck = true,
  }) async {
    if (!canBeClient || _ourCallsign == null) {
      LogService().log('BLEMessageService: Cannot send chat - not initialized or not a client');
      return false;
    }

    try {
      final chatMessage = BLEMessageBuilder.chat(
        author: _ourCallsign!,
        content: content,
        channel: channel,
        signature: signature,
        npub: npub,
      );

      // Fire-and-forget mode: just send the message, don't wait for ack
      // Used for API requests where we wait for the actual api_response instead
      if (!waitForAck) {
        LogService().log('BLEMessageService: Sending in fire-and-forget mode (no ack wait)');
        final sent = await _discoveryService.sendMessageAsync(
          device,
          chatMessage.toJson(),
        );
        if (sent) {
          LogService().log('BLEMessageService: Message sent (fire-and-forget) to ${device.callsign ?? device.deviceId}');
        } else {
          LogService().log('BLEMessageService: Failed to send message (fire-and-forget)');
        }
        return sent;
      }

      // Normal mode: wait for chat_ack
      final response = await _discoveryService.sendMessage(
        device,
        chatMessage.toJson(),
        timeout: const Duration(seconds: 10),
      );

      if (response == null) {
        LogService().log('BLEMessageService: No response to chat');
        return false;
      }

      final ackMessage = BLEMessage.fromJson(response);
      if (ackMessage.type == BLEMessageType.chatAck) {
        final ack = BLEChatAckPayload.fromJson(ackMessage.payload);
        if (ack.success) {
          LogService().log('BLEMessageService: Chat delivered to ${device.callsign ?? device.deviceId}');
          return true;
        } else {
          LogService().log('BLEMessageService: Chat rejected: ${ack.error}');
        }
      }

      return false;
    } catch (e) {
      LogService().log('BLEMessageService: Chat send error: $e');
      return false;
    }
  }

  Future<bool> sendBlePlusPairRequest({
    required BLEDevice device,
    required String classicMac,
  }) async {
    final payload = jsonEncode({
      'type': 'pair_request',
      'classic_mac': classicMac,
    });
    return sendChat(
      device: device,
      content: payload,
      channel: _blePlusPairChannel,
    );
  }

  /// Send chat to a device by callsign (finds device first)
  /// Prefers sending via GATT server if the target is a connected client
  ///
  /// Set [waitForAck] to false for fire-and-forget mode (used for API requests)
  Future<bool> sendChatToCallsign({
    required String targetCallsign,
    required String content,
    String channel = 'main',
    String? signature,
    String? npub,
    bool? waitForAck,
  }) async {
    final target = targetCallsign.toUpperCase();
    // For API requests (_api channel), use fire-and-forget mode by default
    final shouldWaitForAck = waitForAck ?? (channel != '_api');
    LogService().log('BLEMessageService: [SEND] sendChatToCallsign to $target, channel=$channel, waitForAck=$shouldWaitForAck');

    // First, check if target is a connected client (server mode)
    // This is preferred because it uses the existing connection
    if (canBeServer && _ourCallsign != null) {
      LogService().log('BLEMessageService: [SEND] Checking if $target is connected client (we are server)');
      final clientDeviceId = _gattServer.getDeviceIdForCallsign(target);
      if (clientDeviceId != null) {
        LogService().log('BLEMessageService: [SEND] Found $target as connected client: $clientDeviceId');

        // For API responses, send raw JSON to preserve request ID
        if (channel == '_api_response') {
          try {
            final rawData = json.decode(content) as Map<String, dynamic>;
            LogService().log('BLEMessageService: [SEND] Sending raw API response to client');
            await sendRawToClient(deviceId: clientDeviceId, data: rawData);
            return true;
          } catch (e) {
            LogService().log('BLEMessageService: [SEND] Failed to parse API response as JSON: $e');
          }
        }

        if (!shouldWaitForAck) {
          // Fire-and-forget: use server notification (fast, no confirmation)
          LogService().log('BLEMessageService: [SEND] Sending wrapped chat to client (fire-and-forget)');
          await sendChatToClient(
            deviceId: clientDeviceId,
            content: content,
            channel: channel,
            signature: signature,
            npub: npub,
          );
          return true;
        }
        // For reliable delivery (DMs), fall through to client mode with ack
        LogService().log('BLEMessageService: [SEND] Skipping server path for $target (waitForAck=true), using client mode');
      } else {
        LogService().log('BLEMessageService: [SEND] $target is NOT a connected client');
      }
    } else {
      LogService().log('BLEMessageService: [SEND] We are not server (canBeServer=$canBeServer, ourCallsign=$_ourCallsign)');
    }

    // Fall back to client mode - find device and connect
    LogService().log('BLEMessageService: [SEND] Falling back to client mode');
    final devices = _discoveryService.getAllDevices();
    LogService().log('BLEMessageService: [SEND] Known devices: ${devices.length}');
    for (final d in devices) {
      LogService().log('BLEMessageService: [SEND]   - ${d.deviceId}: callsign=${d.callsign}');
    }

    final matchingDevices = devices
        .where((d) => d.callsign?.toUpperCase() == target)
        .toList();

    if (matchingDevices.isEmpty) {
      LogService().log('BLEMessageService: [SEND] FAILED - Device with callsign $target not found in ${devices.length} devices');
      return false;
    }

    // Sort by lastSeen (most recent first) and pick the freshest address
    // This handles BLE address rotation where old addresses become stale
    matchingDevices.sort((a, b) => (b.lastSeen).compareTo(a.lastSeen));
    final device = matchingDevices.first;

    LogService().log('BLEMessageService: [SEND] Found ${matchingDevices.length} devices for $target, using freshest: ${device.deviceId} (lastSeen: ${device.lastSeen})');
    return sendChat(
      device: device,
      content: content,
      channel: channel,
      signature: signature,
      npub: npub,
      waitForAck: shouldWaitForAck,
    );
  }

  /// Broadcast chat to all connected clients (server mode)
  Future<void> broadcastChat({
    required String content,
    String channel = 'main',
    String? signature,
    String? npub,
  }) async {
    if (!canBeServer || _ourCallsign == null) {
      LogService().log('BLEMessageService: Cannot broadcast - not a server');
      return;
    }

    final chatMessage = BLEMessageBuilder.chat(
      author: _ourCallsign!,
      content: content,
      channel: channel,
      signature: signature,
      npub: npub,
    );

    await _gattServer.broadcastNotification(chatMessage.toJson());
    LogService().log('BLEMessageService: Broadcast chat to all clients');
  }

  /// Send chat to a specific connected client (server mode)
  Future<void> sendChatToClient({
    required String deviceId,
    required String content,
    String channel = 'main',
    String? signature,
    String? npub,
  }) async {
    if (!canBeServer || _ourCallsign == null) {
      LogService().log('BLEMessageService: Cannot send to client - not a server');
      return;
    }

    final chatMessage = BLEMessageBuilder.chat(
      author: _ourCallsign!,
      content: content,
      channel: channel,
      signature: signature,
      npub: npub,
    );

    await _gattServer.sendNotification(deviceId, chatMessage.toJson());
  }

  /// Send raw data to a specific connected client (server mode)
  /// Used for API responses that need to preserve original request ID
  Future<void> sendRawToClient({
    required String deviceId,
    required Map<String, dynamic> data,
  }) async {
    if (!canBeServer) {
      LogService().log('BLEMessageService: Cannot send raw to client - not a server');
      return;
    }

    LogService().log('BLEMessageService: Sending raw data to client $deviceId');
    await _gattServer.sendNotification(deviceId, data);
  }

  /// Get list of connected client IDs (server mode)
  List<String> get connectedClients {
    if (!canBeServer) return [];
    return _gattServer.connectedDeviceIds;
  }

  /// Get list of discovered devices (client mode)
  List<BLEDevice> get discoveredDevices => _discoveryService.getAllDevices();

  /// Stream of discovered devices
  Stream<List<BLEDevice>> get devicesStream => _discoveryService.devicesStream;

  /// Start scanning for devices (client mode)
  Future<void> startScanning({Duration timeout = const Duration(seconds: 10)}) async {
    await _discoveryService.startScanning(timeout: timeout);
  }

  /// Stop scanning
  Future<void> stopScanning() async {
    await _discoveryService.stopScanning();
  }

  /// Check if BLE is available
  Future<bool> isAvailable() => _discoveryService.isAvailable();

  /// Get our device ID (1-15, hardware-derived, APRS SSID compatible)
  int get deviceId => _identityService.deviceId;

  /// Get our full identity (callsign-deviceId)
  String get fullIdentity => _identityService.fullIdentity;

  /// Check if a peer supports compression
  bool peerSupportsCompression(String deviceId) {
    return _peerCapabilities[deviceId]?.contains('compression:deflate') ?? false;
  }

  String? _sanitizeClassicMac(String? mac) {
    if (mac == null) return null;
    final trimmed = mac.trim();
    if (trimmed == '02:00:00:00:00:00') return null;
    if (!_macPattern.hasMatch(trimmed)) return null;
    return trimmed;
  }

  /// Send raw data to a device using the parcel protocol
  /// This is for sending large binary data (>300 bytes)
  /// Returns true if data was successfully transmitted
  Future<bool> sendData({
    required BLEDevice device,
    required Uint8List data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!canBeClient) {
      LogService().log('BLEMessageService: Cannot send data - not a client platform');
      return false;
    }

    final deviceId = device.deviceId;
    LogService().log('BLEMessageService: Sending ${data.length} bytes to $deviceId using parcel protocol');

    try {
      // Get or create data connection
      var connection = _dataConnections[deviceId];
      if (connection == null || !connection.isConnected) {
        connection = await _createDataConnection(device);
        if (connection == null) {
          LogService().log('BLEMessageService: Failed to create data connection to $deviceId');
          return false;
        }
        _dataConnections[deviceId] = connection;
      }

      // Configure queue service to use this connection for sending
      _queueService.setSendCallback((targetDeviceId, parcelData) async {
        final conn = _dataConnections[targetDeviceId];
        if (conn != null && conn.isConnected) {
          await conn.writeParcel(parcelData);
        } else {
          throw Exception('Connection lost to $targetDeviceId');
        }
      });

      // Create outgoing message and enqueue
      // Check if peer supports compression based on HELLO handshake
      final supportsCompression = peerSupportsCompression(deviceId);
      final message = BLEOutgoingMessage(
        payload: data,
        targetDeviceId: deviceId,
        peerSupportsCompression: supportsCompression,
      );
      if (supportsCompression) {
        LogService().log('BLEMessageService: Peer supports compression, will compress if beneficial');
      }

      LogService().log('BLEMessageService: Enqueuing message ${message.msgId} (${data.length} bytes)');
      final enqueued = await _queueService.enqueue(message);

      if (!enqueued) {
        LogService().log('BLEMessageService: Failed to enqueue message');
        return false;
      }

      // Wait for completion (the queue service handles the actual sending)
      // We need to monitor the queue until our message is processed
      final startTime = DateTime.now();
      while (DateTime.now().difference(startTime) < timeout) {
        // Check if queue is empty for this device (message processed)
        if (_queueService.getQueueLength(deviceId) == 0 && !_queueService.isSending(deviceId)) {
          LogService().log('BLEMessageService: Data transfer completed to $deviceId');
          return true;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }

      LogService().log('BLEMessageService: Data transfer timed out');
      return false;
    } catch (e) {
      LogService().log('BLEMessageService: Data send error: $e');
      return false;
    }
  }

  /// Create a data connection for parcel-based transfer
  Future<_BLEDataConnection?> _createDataConnection(BLEDevice device) async {
    if (device.bleDevice == null) {
      LogService().log('BLEMessageService: No BLE device reference');
      return null;
    }

    try {
      LogService().log('BLEMessageService: Creating data connection to ${device.deviceId}');

      // Connect to device
      await device.bleDevice!.connect(timeout: const Duration(seconds: 10));

      // Discover services
      final services = await device.bleDevice!.discoverServices();

      // Find Geogram service (0xFFE0)
      BluetoothService? geogramService;
      for (final service in services) {
        final uuid = service.uuid.toString().toLowerCase();
        if (uuid.contains('ffe0')) {
          geogramService = service;
          break;
        }
      }
      if (geogramService == null) {
        throw Exception('Geogram service not found');
      }

      // Find write characteristic
      BluetoothCharacteristic? writeChar;
      for (final characteristic in geogramService.characteristics) {
        if (characteristic.uuid.toString().toLowerCase().contains('fff1')) {
          writeChar = characteristic;
          break;
        }
      }
      if (writeChar == null) {
        throw Exception('Write characteristic not found');
      }

      // Find notify characteristic
      BluetoothCharacteristic? notifyChar;
      for (final characteristic in geogramService.characteristics) {
        if (characteristic.uuid.toString().toLowerCase().contains('fff2')) {
          notifyChar = characteristic;
          break;
        }
      }
      if (notifyChar == null) {
        throw Exception('Notify characteristic not found');
      }

      // Request higher MTU
      try {
        await device.bleDevice!.requestMtu(512);
      } catch (e) {
        LogService().log('BLEMessageService: MTU request failed: $e');
      }

      // Get actual MTU
      final mtu = await device.bleDevice!.mtu.first;

      // Subscribe to notifications
      await notifyChar.setNotifyValue(true);

      // Listen for incoming data (receipts and parcels from other side)
      notifyChar.onValueReceived.listen((data) {
        _queueService.onDataReceived(device.deviceId, Uint8List.fromList(data));
      });

      return _BLEDataConnection(
        deviceId: device.deviceId,
        writeChar: writeChar,
        mtu: mtu,
      );
    } catch (e) {
      LogService().log('BLEMessageService: Failed to create data connection: $e');
      try {
        await device.bleDevice?.disconnect();
      } catch (_) {}
      return null;
    }
  }

  /// Close data connection to a device
  Future<void> closeDataConnection(String deviceId) async {
    final connection = _dataConnections.remove(deviceId);
    if (connection != null) {
      await connection.close();
    }
    _queueService.cancelDevice(deviceId);
  }

  /// Dispose resources
  void dispose() {
    _identityService.dispose();
    _gattServer.dispose();
    _discoveryService.dispose();
    _queueService.dispose();
    for (final conn in _dataConnections.values) {
      conn.close();
    }
    _dataConnections.clear();
    _incomingChatsController.close();
    _isInitialized = false;
  }
}

/// Internal class to manage a BLE connection for parcel-based data transfer
class _BLEDataConnection {
  final String deviceId;
  final dynamic writeChar; // BluetoothCharacteristic
  final int mtu;
  bool _isConnected = true;

  _BLEDataConnection({
    required this.deviceId,
    required this.writeChar,
    required this.mtu,
  });

  bool get isConnected => _isConnected;

  /// Write a parcel to the device with proper chunking
  Future<void> writeParcel(Uint8List data) async {
    final chunkSize = mtu - 3; // Leave room for ATT header

    if (data.length <= chunkSize) {
      // Single write
      await writeChar.write(data.toList(), withoutResponse: true);
    } else {
      // Chunk the parcel
      for (int i = 0; i < data.length; i += chunkSize) {
        final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
        final chunk = data.sublist(i, end);
        await writeChar.write(chunk.toList(), withoutResponse: true);
        // Small delay between chunks
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }
  }

  Future<void> close() async {
    _isConnected = false;
  }
}
