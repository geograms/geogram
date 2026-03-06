/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BitChat Teleport service — singleton managing BLE mesh, identity,
 * geohash channels, peer tracking, message routing, and event stream.
 * Follows the MeshCoreService / IrcService pattern.
 */

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../util/bloom_filter.dart';
import '../../util/geohash.dart';
import '../../util/noise_xx.dart';
import 'bitchat_ble_client.dart';
import 'bitchat_cache_service.dart';
import 'bitchat_protocol.dart';
import 'models/bitchat_channel.dart';
import 'models/bitchat_config.dart';
import 'models/bitchat_message.dart';
import 'models/bitchat_peer.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

enum BitchatEventType {
  connected,
  disconnected,
  messageReceived,
  peerDiscovered,
  channelUpdated,
  configChanged,
  error,
}

class BitchatEvent {
  final BitchatEventType type;
  final dynamic data;
  const BitchatEvent(this.type, [this.data]);
}

// ---------------------------------------------------------------------------
// Conversation grouping
// ---------------------------------------------------------------------------

class BitchatConversation {
  final String id; // "geo:{hash}" for channels, sender/recipient ID for DMs
  final bool isChannel;
  final String displayName;
  final BitchatMessage? lastMessage;
  final int messageCount;

  const BitchatConversation({
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

class BitchatService {
  static final BitchatService _instance = BitchatService._internal();
  factory BitchatService() => _instance;
  BitchatService._internal();

  bool _enabled = false;
  bool _initializing = false;
  final BitchatBleClient _bleClient = BitchatBleClient();
  BitchatCacheService? _cacheService;
  BitchatConfig? _config;
  StreamSubscription<Uint8List>? _packetSub;
  StreamSubscription<BitchatBleState>? _bleStateSub;

  // In-memory state
  final List<BitchatMessage> _messages = [];
  final Map<String, BitchatPeer> _peers = {};
  final Map<String, BitchatChannel> _channels = {};

  // Active Noise sessions per peer (senderId -> transport)
  final Map<String, NoiseTransport> _noiseSessions = {};

  // Message dedup bloom filter
  final BloomFilter _seenMessages = BloomFilter(capacity: 50000);

  // Current location
  String _currentGeohash = '';

  // UI throttle (500ms)
  static const Duration _uiUpdateInterval = Duration(milliseconds: 500);
  Timer? _uiTimer;
  bool _uiDirty = false;

  // Write batch queue
  static const Duration _writeFlushInterval = Duration(seconds: 2);
  Timer? _writeTimer;
  final List<BitchatMessage> _writeQueue = [];

  // Event stream
  final _eventController = StreamController<BitchatEvent>.broadcast();
  Stream<BitchatEvent> get events => _eventController.stream;

  // Public state
  bool get isEnabled => _enabled;
  bool get isConnected => _bleClient.connectedPeerCount > 0;
  BitchatBleState get bleState => _bleClient.state;
  BitchatConfig? get config => _config;
  int get connectedPeerCount => _bleClient.connectedPeerCount;
  String get currentGeohash => _currentGeohash;
  List<BitchatPeer> get peers => _peers.values.toList();
  List<BitchatChannel> get channels => _channels.values.toList();
  BitchatCacheService? get cacheService => _cacheService;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> autoStart(ProfileStorage storage) async {
    if (_enabled || _initializing) return;
    _initializing = true;

    try {
      _cacheService = BitchatCacheService(storage);

      _config = await _cacheService!.loadConfig();
      if (_config == null || !_config!.autoStart) {
        _initializing = false;
        return;
      }

      // Migrate old configs that don't have public keys
      if (!_config!.hasValidKeys) {
        LogService().log('BitchatService: migrating config with invalid keys');
        _config = await BitchatConfig.generateNew(
          nickname: _config!.nickname,
        );
        await _cacheService!.saveConfig(_config!);
      }

      LogService().log('BitchatService: auto-starting');
      _enabled = true;
      _startUiTimer();
      _startWriteTimer();
      await _loadCachedData();
      _startListening();

      if (_config!.bleEnabled) {
        _bleClient.enable();
      }
    } catch (e) {
      LogService().log('BitchatService: autoStart error: $e');
    } finally {
      _initializing = false;
    }
  }

  /// Enable the service. Ensures identity exists first.
  Future<void> enableAsync() async {
    if (_enabled || _initializing) return;
    _initializing = true;

    try {
      await ensureIdentity();
      _enabled = true;
      _startUiTimer();
      _startWriteTimer();
      _startListening();
      _eventController.add(const BitchatEvent(BitchatEventType.configChanged));

      if (_config?.bleEnabled ?? true) {
        _bleClient.enable();
      }
      LogService().log('BitchatService: enabled');
    } catch (e) {
      LogService().log('BitchatService: enable error: $e');
    } finally {
      _initializing = false;
    }
  }

  void disable() {
    if (!_enabled) return;
    _enabled = false;
    _stopUiTimer();
    _stopWriteTimer();
    _flushWrites();
    _bleClient.disable();
    _packetSub?.cancel();
    _packetSub = null;
    _bleStateSub?.cancel();
    _bleStateSub = null;
    _eventController.add(const BitchatEvent(BitchatEventType.disconnected));
  }

  void setStorage(ProfileStorage storage) {
    _cacheService = BitchatCacheService(storage);
  }

  /// Initialize identity if not already configured. MUST be awaited.
  Future<void> ensureIdentity({String nickname = 'anon'}) async {
    if (_config != null && _config!.hasValidKeys) return;

    LogService().log('BitchatService: generating new identity');
    _config = await BitchatConfig.generateNew(nickname: nickname);
    await _cacheService?.saveConfig(_config!);
    _eventController.add(const BitchatEvent(BitchatEventType.configChanged));
  }

  /// Update configuration.
  Future<void> updateConfig(BitchatConfig newConfig) async {
    _config = newConfig;
    await _cacheService?.saveConfig(newConfig);
    _eventController.add(const BitchatEvent(BitchatEventType.configChanged));
  }

  // ---------------------------------------------------------------------------
  // Location
  // ---------------------------------------------------------------------------

  void updateLocation(double latitude, double longitude) {
    final precision = _config?.geohashPrecision ?? 4;
    _currentGeohash = geohashEncode(latitude, longitude, precision: precision);

    // Ensure channel exists for current geohash
    if (!_channels.containsKey(_currentGeohash)) {
      final channel = BitchatChannel(
        geohash: _currentGeohash,
        precision: precision,
      );
      _channels[_currentGeohash] = channel;
      _cacheService?.saveChannel(channel);
      _eventController
          .add(const BitchatEvent(BitchatEventType.channelUpdated));
    }
  }

  // ---------------------------------------------------------------------------
  // BLE
  // ---------------------------------------------------------------------------

  Future<List<BitchatBleScanResult>> scanForPeers() async {
    return _bleClient.scanForPeers();
  }

  Future<bool> connectToPeer(dynamic device) async {
    final success = await _bleClient.connectToPeer(device);
    if (!success) {
      _eventController.add(
        const BitchatEvent(BitchatEventType.error, 'Connection failed'),
      );
      return false;
    }

    // Send announce packet
    if (_config != null) {
      final announceData = encodeAnnounce(
        senderId: hexToBytes(_config!.senderId),
        nickname: _config!.nickname,
        geohash: _currentGeohash,
      );
      await _bleClient.broadcastToAll(announceData);
    }

    _eventController.add(const BitchatEvent(BitchatEventType.connected));
    return true;
  }

  Future<void> disconnectAllPeers() async {
    await _bleClient.disconnectAll();
    _eventController.add(const BitchatEvent(BitchatEventType.disconnected));
  }

  // ---------------------------------------------------------------------------
  // Messaging
  // ---------------------------------------------------------------------------

  /// Send a broadcast message to the current geohash channel.
  Future<BitchatMessage?> sendBroadcast(String text) async {
    if (_config == null || !_config!.hasValidKeys) return null;
    if (text.isEmpty) return null;

    final uuid = _generateUuid();
    final msg = BitchatMessage(
      uuid: uuid,
      channelGeohash: _currentGeohash,
      senderId: _config!.senderId,
      senderNickname: _config!.nickname,
      content: text,
      timestamp: DateTime.now().toUtc(),
      direction: BitchatMessageDirection.outgoing,
      status: BitchatMessageStatus.sent,
    );

    // Encode and send via BLE
    final packet = encodeBroadcast(
      senderId: hexToBytes(_config!.senderId),
      text: '$uuid\x00${_config!.nickname}\x00$_currentGeohash\x00$text',
    );
    await _bleClient.broadcastToAll(packet);

    // Store locally
    _seenMessages.addString(uuid);
    _messages.add(msg);
    _writeQueue.add(msg);
    _uiDirty = true;

    LogService().log('BitchatService: sent broadcast to #$_currentGeohash');
    return msg;
  }

  /// Send a direct (private) message to a specific peer.
  Future<BitchatMessage?> sendPrivate(String text, String recipientId) async {
    if (_config == null || !_config!.hasValidKeys) return null;
    if (text.isEmpty) return null;

    final uuid = _generateUuid();
    final msg = BitchatMessage(
      uuid: uuid,
      senderId: _config!.senderId,
      recipientId: recipientId,
      senderNickname: _config!.nickname,
      content: text,
      timestamp: DateTime.now().toUtc(),
      direction: BitchatMessageDirection.outgoing,
      status: BitchatMessageStatus.sent,
    );

    // Build payload: uuid\x00nickname\x00text
    final payloadText = '$uuid\x00${_config!.nickname}\x00$text';

    // Encrypt with Noise session if available, otherwise send plaintext
    final transport = _noiseSessions[recipientId];
    Uint8List packet;
    if (transport != null) {
      try {
        final plaintext = Uint8List.fromList(payloadText.codeUnits);
        final ciphertext = await transport.encrypt(plaintext);
        packet = encodeDirect(
          senderId: hexToBytes(_config!.senderId),
          recipientId: hexToBytes(recipientId),
          text: '', // payload override below
          encrypted: true,
        );
        // Replace payload with encrypted bytes
        packet = _replacePayload(packet, ciphertext);
      } catch (e) {
        LogService().log('BitchatService: encryption error, sending plain: $e');
        packet = encodeDirect(
          senderId: hexToBytes(_config!.senderId),
          recipientId: hexToBytes(recipientId),
          text: payloadText,
        );
      }
    } else {
      packet = encodeDirect(
        senderId: hexToBytes(_config!.senderId),
        recipientId: hexToBytes(recipientId),
        text: payloadText,
      );
    }
    await _bleClient.broadcastToAll(packet);

    // Store locally
    _seenMessages.addString(uuid);
    _messages.add(msg);
    _writeQueue.add(msg);
    _uiDirty = true;

    LogService().log(
        'BitchatService: sent DM to ${recipientId.substring(0, 8)}...');
    return msg;
  }

  /// Replace the payload bytes in an already-encoded packet.
  Uint8List _replacePayload(Uint8List original, Uint8List newPayload) {
    // Header is 13 bytes, sender is 8 bytes, recipient is 8 bytes for direct
    const headerAndIds = bitchatHeaderSize +
        bitchatSenderIdSize +
        bitchatRecipientIdSize;
    final header = ByteData.sublistView(original, 0, headerAndIds);

    // Update payload length in header
    header.setUint32(8, newPayload.length, Endian.little);

    final result = Uint8List(headerAndIds + newPayload.length);
    result.setRange(0, headerAndIds, original);
    result.setRange(headerAndIds, result.length, newPayload);
    return result;
  }

  // ---------------------------------------------------------------------------
  // Data access
  // ---------------------------------------------------------------------------

  List<BitchatConversation> getConversations() {
    final convMap = <String, List<BitchatMessage>>{};

    for (final msg in _messages) {
      final convId = msg.conversationId;
      convMap.putIfAbsent(convId, () => []).add(msg);
    }

    final conversations = <BitchatConversation>[];
    for (final entry in convMap.entries) {
      final msgs = entry.value;
      msgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      final isChannel = entry.key.startsWith('geo:');
      String displayName;
      if (isChannel) {
        final geohash = entry.key.substring(4);
        final ch = _channels[geohash];
        displayName = ch?.label ?? '#$geohash';
      } else {
        final peer = _peers[entry.key];
        displayName = peer?.displayName ?? '${entry.key.substring(0, 8)}...';
      }

      conversations.add(BitchatConversation(
        id: entry.key,
        isChannel: isChannel,
        displayName: displayName,
        lastMessage: msgs.last,
        messageCount: msgs.length,
      ));
    }

    // Sort by last message time, most recent first
    conversations.sort((a, b) {
      final aTime = a.lastMessageTime ?? DateTime(2000);
      final bTime = b.lastMessageTime ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return conversations;
  }

  List<BitchatMessage> getMessages(String conversationId) {
    return _messages
        .where((m) => m.conversationId == conversationId)
        .toList();
  }

  Map<String, dynamic> getStatus() {
    return {
      'enabled': _enabled,
      'bleState': _bleClient.state.name,
      'connectedPeers': _bleClient.connectedPeerCount,
      'currentGeohash': _currentGeohash,
      'messageCount': _messages.length,
      'peerCount': _peers.length,
      'channelCount': _channels.length,
      'noiseSessionCount': _noiseSessions.length,
      'identity': _config != null
          ? {
              'senderId': _config!.senderId,
              'nickname': _config!.nickname,
              'hasValidKeys': _config!.hasValidKeys,
            }
          : null,
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
    final toWrite = List<BitchatMessage>.from(_writeQueue);
    _writeQueue.clear();
    _cacheService?.saveMessages(toWrite);
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _startListening() {
    _packetSub?.cancel();
    _packetSub = _bleClient.packets.listen(_onPacketReceived);

    _bleStateSub?.cancel();
    _bleStateSub = _bleClient.stateChanges.listen((state) {
      if (state == BitchatBleState.connected) {
        _eventController.add(const BitchatEvent(BitchatEventType.connected));
      } else if (state == BitchatBleState.idle &&
          _bleClient.connectedPeerCount == 0) {
        _eventController
            .add(const BitchatEvent(BitchatEventType.disconnected));
      }
    });
  }

  Future<void> _onPacketReceived(Uint8List rawData) async {
    final packet = decodePacket(rawData);
    if (packet == null) {
      LogService().log(
        'BitchatService: received malformed packet (${rawData.length} bytes)',
      );
      return;
    }

    // Skip own messages
    if (_config != null && packet.senderIdHex == _config!.senderId) return;

    switch (packet) {
      case BitchatBroadcastPacket():
        _handleBroadcast(packet);
      case BitchatDirectPacket():
        await _handleDirect(packet);
      case BitchatAckPacket():
        _handleAck(packet);
      case BitchatAnnouncePacket():
        _handleAnnounce(packet);
    }

    // Relay if TTL > 1 (mesh forwarding)
    if (packet.ttl > 1) {
      _relayPacket(rawData, packet);
    }
  }

  void _handleBroadcast(BitchatBroadcastPacket packet) {
    final parts = packet.payloadText.split('\x00');
    if (parts.length < 4) return;

    final uuid = parts[0];
    if (_seenMessages.mightContainString(uuid)) return;
    _seenMessages.addString(uuid);

    final nickname = parts[1];
    final geohash = parts[2];
    final text = parts.sublist(3).join('\x00');

    final msg = BitchatMessage(
      uuid: uuid,
      channelGeohash: geohash,
      senderId: packet.senderIdHex,
      senderNickname: nickname,
      content: text,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        packet.timestamp * 1000,
        isUtc: true,
      ),
      direction: BitchatMessageDirection.incoming,
      status: BitchatMessageStatus.delivered,
      ttl: packet.ttl,
      hopCount: packet.hopCount,
    );

    _messages.add(msg);
    _writeQueue.add(msg);
    _uiDirty = true;

    // Track peer
    _trackPeer(packet.senderIdHex, nickname, geohash);
  }

  Future<void> _handleDirect(BitchatDirectPacket packet) async {
    // Only process if addressed to us
    if (_config != null && packet.recipientIdHex != _config!.senderId) {
      return;
    }

    // Try to decrypt if encrypted
    String payloadText;
    if (packet.isEncrypted) {
      final transport = _noiseSessions[packet.senderIdHex];
      if (transport != null) {
        try {
          final plaintext = await transport.decrypt(packet.payload);
          payloadText = String.fromCharCodes(plaintext);
        } catch (e) {
          LogService()
              .log('BitchatService: decrypt failed from ${packet.senderIdHex}: $e');
          payloadText = packet.payloadText;
        }
      } else {
        LogService().log(
          'BitchatService: no Noise session for ${packet.senderIdHex}, cannot decrypt',
        );
        payloadText = packet.payloadText;
      }
    } else {
      payloadText = packet.payloadText;
    }

    final parts = payloadText.split('\x00');
    if (parts.length < 3) return;

    final uuid = parts[0];
    if (_seenMessages.mightContainString(uuid)) return;
    _seenMessages.addString(uuid);

    final nickname = parts[1];
    final text = parts.sublist(2).join('\x00');

    final msg = BitchatMessage(
      uuid: uuid,
      senderId: packet.senderIdHex,
      recipientId: packet.recipientIdHex,
      senderNickname: nickname,
      content: text,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        packet.timestamp * 1000,
        isUtc: true,
      ),
      direction: BitchatMessageDirection.incoming,
      status: BitchatMessageStatus.delivered,
      ttl: packet.ttl,
      hopCount: packet.hopCount,
    );

    _messages.add(msg);
    _writeQueue.add(msg);
    _uiDirty = true;

    // Send ACK
    if (_config != null) {
      final ackData = encodeAck(
        senderId: hexToBytes(_config!.senderId),
        messageUuid: uuid,
      );
      await _bleClient.broadcastToAll(ackData);
    }

    _trackPeer(packet.senderIdHex, nickname, '');
  }

  void _handleAck(BitchatAckPacket packet) {
    final uuid = packet.payloadText;
    for (int i = 0; i < _messages.length; i++) {
      if (_messages[i].uuid == uuid && _messages[i].isOutgoing) {
        _messages[i] = _messages[i].copyWith(
          status: BitchatMessageStatus.delivered,
        );
        _cacheService?.updateMessageStatus(
            uuid, BitchatMessageStatus.delivered);
        _uiDirty = true;
        break;
      }
    }
  }

  void _handleAnnounce(BitchatAnnouncePacket packet) {
    final parts = packet.payloadText.split('\x00');
    final nickname = parts.isNotEmpty ? parts[0] : '';
    final geohash = parts.length > 1 ? parts[1] : '';
    _trackPeer(packet.senderIdHex, nickname, geohash);
  }

  void _trackPeer(String senderId, String nickname, String geohash) {
    final existing = _peers[senderId];
    final peer = BitchatPeer(
      publicKeyHex: senderId,
      nickname: nickname.isNotEmpty
          ? nickname
          : (existing?.nickname ?? ''),
      lastSeen: DateTime.now().toUtc(),
      geohash: geohash.isNotEmpty
          ? geohash
          : (existing?.geohash ?? ''),
    );
    _peers[senderId] = peer;
    _cacheService?.savePeer(peer);
    _eventController.add(BitchatEvent(BitchatEventType.peerDiscovered, peer));
  }

  void _relayPacket(Uint8List originalData, BitchatPacket packet) {
    // Decrement TTL, increment hop count, then broadcast
    if (originalData.length < bitchatHeaderSize) return;

    final relayed = Uint8List.fromList(originalData);
    relayed[2] = packet.ttl - 1; // TTL
    relayed[12] = packet.hopCount + 1; // hop count
    _bleClient.broadcastToAll(relayed);
  }

  Future<void> _loadCachedData() async {
    if (_cacheService == null) return;

    try {
      final cachedMessages = await _cacheService!.loadMessages(limit: 500);
      _messages.addAll(cachedMessages);

      final cachedPeers = await _cacheService!.loadPeers();
      for (final peer in cachedPeers) {
        _peers[peer.publicKeyHex] = peer;
      }

      final cachedChannels = await _cacheService!.loadChannels();
      for (final ch in cachedChannels) {
        _channels[ch.geohash] = ch;
      }

      // Populate bloom filter with known message UUIDs
      for (final msg in _messages) {
        _seenMessages.addString(msg.uuid);
      }
    } catch (e) {
      LogService().log('BitchatService: loadCachedData error: $e');
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
          .add(const BitchatEvent(BitchatEventType.messageReceived));
    }
  }

  // Write timer
  void _startWriteTimer() {
    _writeTimer?.cancel();
    _writeTimer = Timer.periodic(_writeFlushInterval, (_) => _flushWrites());
  }

  void _stopWriteTimer() {
    _writeTimer?.cancel();
    _writeTimer = null;
  }

  String _generateUuid() {
    final rng = Random.secure();
    final bytes = List.generate(16, (_) => rng.nextInt(256));
    // UUID v4 format
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}'
        '-${hex.substring(12, 16)}-${hex.substring(16, 20)}'
        '-${hex.substring(20)}';
  }

  void dispose() {
    _flushWrites();
    _stopUiTimer();
    _stopWriteTimer();
    _packetSub?.cancel();
    _bleStateSub?.cancel();
    _bleClient.dispose();
    _cacheService?.dispose();
    _eventController.close();
  }
}
