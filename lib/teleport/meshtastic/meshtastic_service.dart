/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Meshtastic Teleport service — singleton managing BLE transport, node database,
 * channel list, message routing, and event stream.
 * Follows the BitchatService singleton pattern.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import 'meshtastic_ble_client.dart';
import 'meshtastic_cache_service.dart';
import 'meshtastic_crypto.dart';
import 'meshtastic_protobuf.dart';
import 'models/meshtastic_channel.dart';
import 'models/meshtastic_config.dart';
import 'models/meshtastic_message.dart';
import 'models/meshtastic_node.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

enum MeshtasticEventType {
  connected,
  disconnected,
  messageReceived,
  nodeUpdated,
  channelUpdated,
  configChanged,
  configComplete,
  error,
}

class MeshtasticEvent {
  final MeshtasticEventType type;
  final dynamic data;
  const MeshtasticEvent(this.type, [this.data]);
}

// ---------------------------------------------------------------------------
// Conversation grouping
// ---------------------------------------------------------------------------

class MeshtasticConversation {
  final String id;
  final bool isChannel;
  final String displayName;
  final MeshtasticMessage? lastMessage;
  final int messageCount;

  const MeshtasticConversation({
    required this.id,
    required this.isChannel,
    required this.displayName,
    this.lastMessage,
    this.messageCount = 0,
  });

  DateTime? get lastMessageTime => lastMessage?.timestamp;
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

class MeshtasticService {
  static final MeshtasticService _instance = MeshtasticService._internal();
  factory MeshtasticService() => _instance;
  MeshtasticService._internal() {
    _bleClient.onLog = _onBleLog;
  }

  bool _enabled = false;
  bool _initializing = false;
  bool _configReady = false;
  final MeshtasticBleClient _bleClient = MeshtasticBleClient();
  MeshtasticCacheService? _cacheService;
  MeshtasticConfig? _config;
  StreamSubscription<MeshtasticFromRadio>? _responseSub;
  StreamSubscription<MeshtasticBleState>? _bleStateSub;

  // Config request flow
  int _wantConfigId = 0;

  // In-memory state
  final List<MeshtasticMessage> _messages = [];
  final Map<int, MeshtasticNode> _nodes = {};
  final Map<int, MeshtasticChannelConfig> _channels = {};

  // Dedup by packet ID
  final Set<int> _seenPacketIds = {};

  // UI throttle (500ms)
  static const Duration _uiUpdateInterval = Duration(milliseconds: 500);
  Timer? _uiTimer;
  bool _uiDirty = false;

  // Write batch queue
  static const Duration _writeFlushInterval = Duration(seconds: 2);
  Timer? _writeTimer;
  final List<MeshtasticMessage> _writeQueue = [];

  // Event stream
  final _eventController = StreamController<MeshtasticEvent>.broadcast();
  Stream<MeshtasticEvent> get events => _eventController.stream;

  // Public state
  bool get isEnabled => _enabled;
  bool get isConnected =>
      _bleClient.state == MeshtasticBleState.connected;
  bool get isConfigReady => _configReady;
  MeshtasticBleState get bleState => _bleClient.state;
  MeshtasticConfig? get config => _config;
  int get myNodeNum => _config?.myNodeNum ?? 0;
  List<MeshtasticNode> get nodes => _nodes.values.toList();
  List<MeshtasticChannelConfig> get channels =>
      _channels.values.where((c) => c.isEnabled).toList();
  MeshtasticCacheService? get cacheService => _cacheService;
  MeshtasticLogLevel get logLevel =>
      _config?.logLevel ?? MeshtasticLogLevel.info;

  // ---------------------------------------------------------------------------
  // Logging
  // ---------------------------------------------------------------------------

  void _log(MeshtasticLogLevel level, String message) {
    final current = _config?.logLevel ?? MeshtasticLogLevel.info;
    if (current == MeshtasticLogLevel.off) return;
    if (level.index < current.index) return;
    LogService().log(message);
  }

  void _onBleLog(String level, String message) {
    final mapped = MeshtasticLogLevel.values.firstWhere(
      (l) => l.name == level,
      orElse: () => MeshtasticLogLevel.info,
    );
    _log(mapped, message);
  }

  void setLogLevel(MeshtasticLogLevel level) {
    if (_config == null) return;
    _config = _config!.copyWith(logLevel: level);
    _cacheService?.saveConfig(_config!);
    _log(MeshtasticLogLevel.info, 'MeshtasticService: log level set to ${level.name}');
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> autoStart(ProfileStorage storage) async {
    if (_enabled || _initializing) return;
    _initializing = true;

    try {
      _cacheService = MeshtasticCacheService(storage);

      _config = await _cacheService!.loadConfig();
      if (_config == null || !_config!.autoStart) {
        _initializing = false;
        return;
      }

      _log(MeshtasticLogLevel.info, 'MeshtasticService: auto-starting');
      _enabled = true;
      _startUiTimer();
      _startWriteTimer();
      await _loadCachedData();
      _startListening();
    } catch (e) {
      _log(MeshtasticLogLevel.error, 'MeshtasticService: autoStart error: $e');
    } finally {
      _initializing = false;
    }
  }

  Future<void> enableAsync() async {
    if (_enabled || _initializing) return;
    _initializing = true;

    try {
      if (_config == null) {
        _config = const MeshtasticConfig();
        await _cacheService?.saveConfig(_config!);
      }
      _enabled = true;
      _startUiTimer();
      _startWriteTimer();
      _startListening();
      _eventController
          .add(const MeshtasticEvent(MeshtasticEventType.configChanged));
      _log(MeshtasticLogLevel.info, 'MeshtasticService: enabled');
    } catch (e) {
      _log(MeshtasticLogLevel.error, 'MeshtasticService: enable error: $e');
    } finally {
      _initializing = false;
    }
  }

  void disable() {
    if (!_enabled) return;
    _enabled = false;
    _configReady = false;
    _stopUiTimer();
    _stopWriteTimer();
    _flushWrites();
    _responseSub?.cancel();
    _responseSub = null;
    _bleStateSub?.cancel();
    _bleStateSub = null;
    _eventController
        .add(const MeshtasticEvent(MeshtasticEventType.disconnected));
  }

  void setStorage(ProfileStorage storage) {
    _cacheService = MeshtasticCacheService(storage);
  }

  Future<void> updateConfig(MeshtasticConfig newConfig) async {
    _config = newConfig;
    await _cacheService?.saveConfig(newConfig);
    _eventController
        .add(const MeshtasticEvent(MeshtasticEventType.configChanged));
  }

  // ---------------------------------------------------------------------------
  // BLE
  // ---------------------------------------------------------------------------

  Future<List<MeshtasticScanResult>> scanForDevices() async {
    return _bleClient.scanForDevices();
  }

  Future<bool> connectBle(BluetoothDevice device) async {
    final success = await _bleClient.connect(device);
    if (!success) {
      _eventController.add(
        const MeshtasticEvent(MeshtasticEventType.error, 'Connection failed'),
      );
      return false;
    }

    // Request config dump from the radio
    _requestConfig();
    return true;
  }

  Future<void> disconnectBle() async {
    _configReady = false;
    await _bleClient.disconnect();
    _eventController
        .add(const MeshtasticEvent(MeshtasticEventType.disconnected));
  }

  /// Send wantConfigId to trigger config dump from the radio.
  void _requestConfig() {
    _wantConfigId = Random().nextInt(0x7FFFFFFF) + 1;
    _configReady = false;
    _log(MeshtasticLogLevel.debug,
      'MeshtasticService: requesting config (id=$_wantConfigId)');

    final toRadio = MeshtasticToRadio(wantConfigId: _wantConfigId);
    _bleClient.sendToRadio(toRadio).catchError((e) {
      _log(MeshtasticLogLevel.error, 'MeshtasticService: sendToRadio error: $e');
    });
  }

  // ---------------------------------------------------------------------------
  // Messaging
  // ---------------------------------------------------------------------------

  Future<MeshtasticMessage?> sendMessage(
    String text, {
    int toNode = 0xFFFFFFFF,
    int channelIndex = 0,
  }) async {
    if (!isConnected || !_configReady) return null;
    if (text.isEmpty || myNodeNum == 0) return null;

    final packetId = Random().nextInt(0xFFFFFFFF);
    final payload = utf8.encode(text);

    // Build the Data submessage
    final data = MeshtasticData(
      portnum: MeshtasticPortnum.textMessageApp,
      payload: Uint8List.fromList(payload),
    );

    // Get channel PSK for encryption
    final channel = _channels[channelIndex];
    Uint8List? encrypted;
    MeshtasticData? decoded;

    if (channel != null && channel.psk.isNotEmpty) {
      final key = expandPsk(channel.psk);
      if (key.isNotEmpty) {
        final dataBytes = data.encode().toBytes();
        encrypted = encryptMeshtastic(dataBytes, key, packetId, myNodeNum);
      } else {
        decoded = data;
      }
    } else {
      decoded = data;
    }

    final meshPacket = MeshtasticMeshPacket(
      from: myNodeNum,
      to: toNode,
      channel: channelIndex,
      decoded: decoded,
      encrypted: encrypted,
      id: packetId,
      hopLimit: 3,
      wantAck: toNode != 0xFFFFFFFF,
    );

    final toRadio = MeshtasticToRadio(packet: meshPacket);

    try {
      await _bleClient.sendToRadio(toRadio);
    } catch (e) {
      _log(MeshtasticLogLevel.error, 'MeshtasticService: send error: $e');
      return null;
    }

    // Find sender name from our own node
    final myNode = _nodes[myNodeNum];

    final msg = MeshtasticMessage(
      channelIndex: channelIndex,
      fromNode: myNodeNum,
      toNode: toNode,
      text: text,
      timestamp: DateTime.now().toUtc(),
      direction: MeshtasticMessageDirection.outgoing,
      status: MeshtasticMessageStatus.sent,
      hopLimit: 3,
      senderLongName: myNode?.longName ?? '',
      senderShortName: myNode?.shortName ?? '',
      packetId: packetId,
    );

    _seenPacketIds.add(packetId);
    _messages.add(msg);
    _writeQueue.add(msg);
    _uiDirty = true;

    _log(MeshtasticLogLevel.debug, 'MeshtasticService: sent message to ch:$channelIndex');
    return msg;
  }

  // ---------------------------------------------------------------------------
  // Data access
  // ---------------------------------------------------------------------------

  List<MeshtasticConversation> getConversations() {
    final convMap = <String, List<MeshtasticMessage>>{};

    for (final msg in _messages) {
      final convId = msg.conversationId;
      convMap.putIfAbsent(convId, () => []).add(msg);
    }

    final conversations = <MeshtasticConversation>[];
    for (final entry in convMap.entries) {
      final msgs = entry.value;
      msgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      final isChannel = entry.key.startsWith('ch:');
      String displayName;
      if (isChannel) {
        final chIdx = int.tryParse(entry.key.substring(3)) ?? 0;
        final ch = _channels[chIdx];
        displayName = ch?.displayName ?? 'Channel $chIdx';
      } else {
        // DM: use other party's node name
        final nodeHex = entry.key.substring(3);
        final nodeNum = int.tryParse(nodeHex, radix: 16) ?? 0;
        final node = _nodes[nodeNum];
        displayName = node?.displayName ?? '!$nodeHex';
      }

      conversations.add(MeshtasticConversation(
        id: entry.key,
        isChannel: isChannel,
        displayName: displayName,
        lastMessage: msgs.last,
        messageCount: msgs.length,
      ));
    }

    conversations.sort((a, b) {
      final aTime = a.lastMessageTime ?? DateTime(2000);
      final bTime = b.lastMessageTime ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return conversations;
  }

  List<MeshtasticMessage> getMessages(String conversationId) {
    return _messages
        .where((m) => m.conversationId == conversationId)
        .toList();
  }

  Map<String, dynamic> getStatus() {
    return {
      'enabled': _enabled,
      'bleState': _bleClient.state.name,
      'configReady': _configReady,
      'myNodeNum': myNodeNum,
      'messageCount': _messages.length,
      'nodeCount': _nodes.length,
      'channelCount': _channels.values.where((c) => c.isEnabled).length,
      'logLevel': logLevel.name,
    };
  }

  // ---------------------------------------------------------------------------
  // Write flushing
  // ---------------------------------------------------------------------------

  void flushWrites() {
    _flushWrites();
  }

  void _flushWrites() {
    if (_writeQueue.isEmpty) return;
    final toWrite = List<MeshtasticMessage>.from(_writeQueue);
    _writeQueue.clear();
    _cacheService?.saveMessages(toWrite);
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _startListening() {
    _responseSub?.cancel();
    _responseSub = _bleClient.responses.listen(_onFromRadio);

    _bleStateSub?.cancel();
    _bleStateSub = _bleClient.stateChanges.listen((state) {
      if (state == MeshtasticBleState.connected) {
        _eventController
            .add(const MeshtasticEvent(MeshtasticEventType.connected));
      } else if (state == MeshtasticBleState.disconnected) {
        _configReady = false;
        _eventController
            .add(const MeshtasticEvent(MeshtasticEventType.disconnected));
      }
    });
  }

  void _onFromRadio(MeshtasticFromRadio fromRadio) {
    // Config dump: MyNodeInfo
    if (fromRadio.myInfo != null) {
      _handleMyNodeInfo(fromRadio.myInfo!);
    }

    // Config dump: NodeInfo
    if (fromRadio.nodeInfo != null) {
      _handleNodeInfo(fromRadio.nodeInfo!);
    }

    // Config dump: Channel
    if (fromRadio.channel != null) {
      _handleChannel(fromRadio.channel!);
    }

    // Config dump complete
    if (fromRadio.configCompleteId != 0) {
      if (fromRadio.configCompleteId == _wantConfigId) {
        _configReady = true;
        _log(MeshtasticLogLevel.info,
          'MeshtasticService: config complete '
          '(nodes=${_nodes.length}, channels=${_channels.values.where((c) => c.isEnabled).length})');
        _eventController
            .add(const MeshtasticEvent(MeshtasticEventType.configComplete));
        _uiDirty = true;
      }
    }

    // Mesh packet
    if (fromRadio.packet != null) {
      _handleMeshPacket(fromRadio.packet!);
    }
  }

  void _handleMyNodeInfo(MeshtasticMyNodeInfo myInfo) {
    _log(MeshtasticLogLevel.debug,
      'MeshtasticService: my node num = ${myInfo.myNodeNum}');
    _config = (_config ?? const MeshtasticConfig())
        .copyWith(myNodeNum: myInfo.myNodeNum);
    _cacheService?.saveConfig(_config!);
  }

  void _handleNodeInfo(MeshtasticNodeInfo nodeInfo) {
    final user = nodeInfo.user;
    final pos = nodeInfo.position;
    final metrics = nodeInfo.deviceMetrics;

    final node = MeshtasticNode(
      nodeNum: nodeInfo.num,
      userId: user?.id ?? '',
      longName: user?.longName ?? '',
      shortName: user?.shortName ?? '',
      hwModel: user?.hwModel ?? 0,
      publicKey: user?.publicKey,
      latitude: pos != null && pos.latitudeI != 0 ? pos.latitude : null,
      longitude: pos != null && pos.longitudeI != 0 ? pos.longitude : null,
      altitude: pos?.altitude ?? 0,
      snr: nodeInfo.snr,
      lastHeard: nodeInfo.lastHeard,
      batteryLevel: metrics?.batteryLevel ?? 0,
      voltage: metrics?.voltage ?? 0.0,
    );

    _nodes[nodeInfo.num] = node;
    _cacheService?.saveNode(node);
    _eventController
        .add(MeshtasticEvent(MeshtasticEventType.nodeUpdated, node));
  }

  void _handleChannel(MeshtasticChannel channel) {
    final settings = channel.settings;
    final config = MeshtasticChannelConfig(
      index: channel.index,
      name: settings?.name ?? '',
      psk: settings?.psk ?? Uint8List(0),
      role: MeshtasticChannelRole.values[
          channel.role.clamp(0, MeshtasticChannelRole.values.length - 1)],
    );

    _channels[channel.index] = config;
    _cacheService?.saveChannel(config);
    _eventController
        .add(const MeshtasticEvent(MeshtasticEventType.channelUpdated));
  }

  void _handleMeshPacket(MeshtasticMeshPacket packet) {
    // Dedup by packet ID
    if (packet.id != 0 && _seenPacketIds.contains(packet.id)) return;
    if (packet.id != 0) _seenPacketIds.add(packet.id);

    // Keep dedup set bounded
    if (_seenPacketIds.length > 10000) {
      final excess = _seenPacketIds.length - 5000;
      final toRemove = _seenPacketIds.take(excess).toList();
      _seenPacketIds.removeAll(toRemove);
    }

    // Skip our own packets
    if (packet.from == myNodeNum) return;

    // Try to decrypt if encrypted
    MeshtasticData? data = packet.decoded;
    if (data == null && packet.encrypted != null) {
      data = _tryDecrypt(packet);
    }

    if (data == null) return;

    switch (data.portnum) {
      case MeshtasticPortnum.textMessageApp:
        _handleTextMessage(packet, data);
      case MeshtasticPortnum.positionApp:
        _handlePosition(packet, data);
      case MeshtasticPortnum.nodeinfoApp:
        _handleNodeInfoPacket(packet, data);
      case MeshtasticPortnum.telemetryApp:
        _handleTelemetry(packet, data);
    }
  }

  MeshtasticData? _tryDecrypt(MeshtasticMeshPacket packet) {
    // Try each enabled channel's PSK
    for (final ch in _channels.values) {
      if (!ch.isEnabled || ch.psk.isEmpty) continue;

      final key = expandPsk(ch.psk);
      if (key.isEmpty) continue;

      try {
        final decrypted = decryptMeshtastic(
          packet.encrypted!,
          key,
          packet.id,
          packet.from,
        );
        return MeshtasticData.decode(ProtobufReader(decrypted));
      } catch (_) {
        // Wrong key, try next channel
      }
    }
    return null;
  }

  void _handleTextMessage(
      MeshtasticMeshPacket packet, MeshtasticData data) {
    final text = utf8.decode(data.payload, allowMalformed: true);
    if (text.isEmpty) return;

    // Look up sender name
    final sender = _nodes[packet.from];

    final msg = MeshtasticMessage(
      channelIndex: packet.channel,
      fromNode: packet.from,
      toNode: packet.to,
      text: text,
      timestamp: packet.rxTime > 0
          ? DateTime.fromMillisecondsSinceEpoch(
              packet.rxTime * 1000,
              isUtc: true,
            )
          : DateTime.now().toUtc(),
      direction: MeshtasticMessageDirection.incoming,
      status: MeshtasticMessageStatus.delivered,
      rxSnr: packet.rxSnr != 0 ? packet.rxSnr : null,
      rxRssi: packet.rxRssi != 0 ? packet.rxRssi : null,
      hopStart: packet.hopStart,
      hopLimit: packet.hopLimit,
      senderLongName: sender?.longName ?? '',
      senderShortName: sender?.shortName ?? '',
      packetId: packet.id,
    );

    _messages.add(msg);
    _writeQueue.add(msg);
    _uiDirty = true;
  }

  void _handlePosition(
      MeshtasticMeshPacket packet, MeshtasticData data) {
    try {
      final pos = MeshtasticPosition.decode(ProtobufReader(data.payload));
      final existing = _nodes[packet.from];
      if (existing != null && pos.latitudeI != 0) {
        final updated = existing.copyWith(
          latitude: pos.latitude,
          longitude: pos.longitude,
          altitude: pos.altitude,
          lastHeard: pos.time > 0
              ? pos.time
              : DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );
        _nodes[packet.from] = updated;
        _cacheService?.saveNode(updated);
        _eventController.add(
          MeshtasticEvent(MeshtasticEventType.nodeUpdated, updated),
        );
      }
    } catch (e) {
      _log(MeshtasticLogLevel.warn, 'MeshtasticService: position decode error: $e');
    }
  }

  void _handleNodeInfoPacket(
      MeshtasticMeshPacket packet, MeshtasticData data) {
    try {
      final user = MeshtasticUser.decode(ProtobufReader(data.payload));
      final existing = _nodes[packet.from];
      final node = MeshtasticNode(
        nodeNum: packet.from,
        userId: user.id,
        longName: user.longName,
        shortName: user.shortName,
        hwModel: user.hwModel,
        publicKey: user.publicKey,
        latitude: existing?.latitude,
        longitude: existing?.longitude,
        altitude: existing?.altitude ?? 0,
        snr: existing?.snr ?? 0.0,
        lastHeard: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        batteryLevel: existing?.batteryLevel ?? 0,
        voltage: existing?.voltage ?? 0.0,
      );
      _nodes[packet.from] = node;
      _cacheService?.saveNode(node);
      _eventController.add(
        MeshtasticEvent(MeshtasticEventType.nodeUpdated, node),
      );
    } catch (e) {
      _log(MeshtasticLogLevel.warn, 'MeshtasticService: nodeinfo decode error: $e');
    }
  }

  void _handleTelemetry(
      MeshtasticMeshPacket packet, MeshtasticData data) {
    try {
      // Telemetry contains a oneof; field 1 = time, field 2 = device_metrics
      final reader = ProtobufReader(data.payload);
      MeshtasticDeviceMetrics? metrics;

      while (reader.hasMore) {
        final tag = reader.readTag();
        if (tag == null) break;
        final (field, wire) = tag;
        switch (field) {
          case 2:
            metrics = MeshtasticDeviceMetrics.decode(reader.readSubmessage());
          default:
            reader.skipField(wire);
        }
      }

      if (metrics != null) {
        final existing = _nodes[packet.from];
        if (existing != null) {
          final updated = existing.copyWith(
            batteryLevel: metrics.batteryLevel,
            voltage: metrics.voltage,
            lastHeard: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          );
          _nodes[packet.from] = updated;
          _cacheService?.saveNode(updated);
        }
      }
    } catch (e) {
      _log(MeshtasticLogLevel.warn, 'MeshtasticService: telemetry decode error: $e');
    }
  }

  Future<void> _loadCachedData() async {
    if (_cacheService == null) return;

    try {
      final cachedMessages =
          await _cacheService!.loadMessages(limit: 500);
      _messages.addAll(cachedMessages);

      final cachedNodes = await _cacheService!.loadNodes();
      for (final node in cachedNodes) {
        _nodes[node.nodeNum] = node;
      }

      final cachedChannels = await _cacheService!.loadChannels();
      for (final ch in cachedChannels) {
        _channels[ch.index] = ch;
      }

      // Populate dedup set
      for (final msg in _messages) {
        if (msg.packetId != 0) _seenPacketIds.add(msg.packetId);
      }
    } catch (e) {
      _log(MeshtasticLogLevel.error, 'MeshtasticService: loadCachedData error: $e');
    }
  }

  // UI timer
  void _startUiTimer() {
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(_uiUpdateInterval, _onUiTick);
  }

  void _stopUiTimer() {
    _uiTimer?.cancel();
    _uiTimer = null;
  }

  void _onUiTick(Timer _) {
    if (_uiDirty) {
      _uiDirty = false;
      _eventController
          .add(const MeshtasticEvent(MeshtasticEventType.messageReceived));
    }
  }

  // Write timer
  void _startWriteTimer() {
    _writeTimer?.cancel();
    _writeTimer =
        Timer.periodic(_writeFlushInterval, (_) => _flushWrites());
  }

  void _stopWriteTimer() {
    _writeTimer?.cancel();
    _writeTimer = null;
  }

  void dispose() {
    _flushWrites();
    _stopUiTimer();
    _stopWriteTimer();
    _responseSub?.cancel();
    _bleStateSub?.cancel();
    _bleClient.dispose();
    _cacheService?.dispose();
    _eventController.close();
  }
}
