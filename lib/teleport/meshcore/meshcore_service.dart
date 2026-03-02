/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * MeshCore Teleport service — singleton managing BLE connection to a
 * MeshCore companion radio, message sync, and event stream.
 * Follows the AprsService pattern.
 */

import 'dart:async';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import 'meshcore_ble_client.dart';
import 'meshcore_cache_service.dart';
import 'meshcore_protocol.dart';
import 'models/meshcore_channel.dart';
import 'models/meshcore_contact.dart';
import 'models/meshcore_device_info.dart';
import 'models/meshcore_message.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

enum MeshCoreEventType {
  connected,
  disconnected,
  messageReceived,
  contactsUpdated,
  channelsUpdated,
  deviceInfoUpdated,
  error,
}

class MeshCoreEvent {
  final MeshCoreEventType type;
  final dynamic data;
  const MeshCoreEvent(this.type, [this.data]);
}

// ---------------------------------------------------------------------------
// Conversation grouping
// ---------------------------------------------------------------------------

class MeshCoreConversation {
  final String id; // pubKeyHex for contacts, "ch:N" for channels
  final MeshCoreConversationType type;
  final String displayName;
  final MeshCoreMessage? lastMessage;
  final int messageCount;

  const MeshCoreConversation({
    required this.id,
    required this.type,
    required this.displayName,
    this.lastMessage,
    this.messageCount = 0,
  });

  DateTime? get lastMessageTime => lastMessage?.timestamp;
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

class MeshCoreService {
  static final MeshCoreService _instance = MeshCoreService._internal();
  factory MeshCoreService() => _instance;
  MeshCoreService._internal();

  bool _enabled = false;
  final MeshCoreBleClient _bleClient = MeshCoreBleClient();
  MeshCoreCacheService? _cacheService;
  StreamSubscription<MeshCoreResponse>? _responseSub;
  StreamSubscription<MeshCoreBleState>? _bleStateSub;

  // Device state
  MeshCoreDeviceInfo? _deviceInfo;
  final List<MeshCoreContact> _contacts = [];
  final List<MeshCoreChannel> _channels = [];
  final List<MeshCoreMessage> _messages = [];

  // Saved device ID for auto-reconnect
  String? _savedDeviceId;

  // UI throttle
  static const Duration _uiUpdateInterval = Duration(milliseconds: 500);
  Timer? _uiTimer;
  bool _uiDirty = false;

  // Event stream
  final _eventController = StreamController<MeshCoreEvent>.broadcast();
  Stream<MeshCoreEvent> get events => _eventController.stream;

  // Public state
  bool get isEnabled => _enabled;
  bool get isConnected => _bleClient.state == MeshCoreBleState.connected;
  MeshCoreBleState get bleState => _bleClient.state;
  MeshCoreDeviceInfo? get deviceInfo => _deviceInfo;
  List<MeshCoreContact> get contacts => List.unmodifiable(_contacts);
  List<MeshCoreChannel> get channels => List.unmodifiable(_channels);
  MeshCoreCacheService? get cacheService => _cacheService;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Wire up persistence and auto-start if previously enabled.
  Future<void> autoStart(ProfileStorage storage) async {
    if (_enabled) return;
    _cacheService = MeshCoreCacheService(storage, '');

    final config = await _cacheService!.loadConfig();
    if (config == null) return;

    _savedDeviceId = config['deviceId'] as String?;
    if (config['enabled'] != true) return;

    LogService().log('MeshCoreService: auto-starting');
    _enabled = true;
    _startUiTimer();
    await _loadCachedData();
    _startListening();
    // Auto-reconnect is not attempted here since we need a BluetoothDevice
    // instance from a scan. The user will reconnect from the UI.
  }

  void enable() {
    if (_enabled) return;
    _enabled = true;
    _startUiTimer();
    _saveConfig();
    _startListening();
  }

  void disable() {
    if (!_enabled) return;
    _enabled = false;
    _stopUiTimer();
    _bleClient.disconnect();
    _responseSub?.cancel();
    _responseSub = null;
    _bleStateSub?.cancel();
    _bleStateSub = null;
    _saveConfig();
    _eventController.add(const MeshCoreEvent(MeshCoreEventType.disconnected));
  }

  void setStorage(ProfileStorage storage) {
    _cacheService = MeshCoreCacheService(storage, '');
  }

  // ---------------------------------------------------------------------------
  // BLE Connection
  // ---------------------------------------------------------------------------

  /// Scan for MeshCore devices.
  Future<List<MeshCoreScanResult>> scanForDevices() async {
    return _bleClient.scanForDevices();
  }

  /// Connect to a specific device and run the init sequence.
  Future<bool> connectToDevice(dynamic device) async {
    // device is a BluetoothDevice from flutter_blue_plus
    final success = await _bleClient.connect(device);
    if (!success) {
      _eventController.add(
        const MeshCoreEvent(MeshCoreEventType.error, 'Connection failed'),
      );
      return false;
    }

    _savedDeviceId = _bleClient.connectedDeviceId;
    _saveConfig();

    // Run init sequence
    await _runInitSequence();
    return true;
  }

  /// Disconnect from the current device.
  Future<void> disconnectDevice() async {
    await _bleClient.disconnect();
    _savedDeviceId = null;
    _saveConfig();
  }

  // ---------------------------------------------------------------------------
  // Messaging
  // ---------------------------------------------------------------------------

  /// Send a direct message to a contact.
  Future<MeshCoreMessage?> sendContactMessage(
    String pubKeyHex,
    String text,
  ) async {
    if (!isConnected) return null;
    if (text.isEmpty) return null;

    // Enforce 133-char limit
    final trimmed = text.length > meshCoreMaxTextBytes
        ? text.substring(0, meshCoreMaxTextBytes)
        : text;

    try {
      final pubKey = hexToBytes(pubKeyHex);
      await _bleClient.send(encodeSendTxtMsg(pubKey, trimmed));

      final msg = MeshCoreMessage(
        conversationId: pubKeyHex,
        conversationType: MeshCoreConversationType.contact,
        text: trimmed,
        timestamp: DateTime.now().toUtc(),
        direction: MeshCoreMessageDirection.outgoing,
        status: MeshCoreMessageStatus.sent,
      );

      final id = await _cacheService?.saveMessage(msg);
      final saved = id != null && id > 0 ? msg.copyWith(id: id) : msg;
      _messages.add(saved);
      _uiDirty = true;

      LogService().log('MeshCoreService: sent contact message to ${pubKeyHex.substring(0, 8)}...');
      return saved;
    } catch (e) {
      LogService().log('MeshCoreService: send contact message error: $e');
      _eventController.add(MeshCoreEvent(MeshCoreEventType.error, '$e'));
      return null;
    }
  }

  /// Send a message to a channel.
  Future<MeshCoreMessage?> sendChannelMessage(
    int channelIdx,
    String text,
  ) async {
    if (!isConnected) return null;
    if (text.isEmpty) return null;

    final trimmed = text.length > meshCoreMaxTextBytes
        ? text.substring(0, meshCoreMaxTextBytes)
        : text;

    try {
      await _bleClient.send(encodeSendChannelTxtMsg(channelIdx, trimmed));

      final msg = MeshCoreMessage(
        conversationId: 'ch:$channelIdx',
        conversationType: MeshCoreConversationType.channel,
        text: trimmed,
        timestamp: DateTime.now().toUtc(),
        direction: MeshCoreMessageDirection.outgoing,
        status: MeshCoreMessageStatus.sent,
      );

      final id = await _cacheService?.saveMessage(msg);
      final saved = id != null && id > 0 ? msg.copyWith(id: id) : msg;
      _messages.add(saved);
      _uiDirty = true;

      LogService().log('MeshCoreService: sent channel $channelIdx message');
      return saved;
    } catch (e) {
      LogService().log('MeshCoreService: send channel message error: $e');
      _eventController.add(MeshCoreEvent(MeshCoreEventType.error, '$e'));
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Data access
  // ---------------------------------------------------------------------------

  /// Get all messages for a conversation.
  List<MeshCoreMessage> getMessages(String conversationId) {
    return _messages
        .where((m) => m.conversationId == conversationId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  /// Get grouped conversation list sorted by most recent message.
  List<MeshCoreConversation> getConversations() {
    final convMap = <String, List<MeshCoreMessage>>{};

    // Group messages by conversation
    for (final msg in _messages) {
      convMap.putIfAbsent(msg.conversationId, () => []).add(msg);
    }

    // Also include contacts and channels that have no messages yet
    for (final contact in _contacts) {
      convMap.putIfAbsent(contact.pubKeyHex, () => []);
    }
    for (final channel in _channels) {
      if (channel.name.isNotEmpty) {
        convMap.putIfAbsent('ch:${channel.index}', () => []);
      }
    }

    final conversations = <MeshCoreConversation>[];

    for (final entry in convMap.entries) {
      final id = entry.key;
      final msgs = entry.value..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      final MeshCoreConversationType type;
      final String displayName;

      if (id.startsWith('ch:')) {
        type = MeshCoreConversationType.channel;
        final idx = int.tryParse(id.substring(3)) ?? 0;
        final channel = _channels.where((c) => c.index == idx).firstOrNull;
        displayName = channel?.displayName ?? 'Channel $idx';
      } else {
        type = MeshCoreConversationType.contact;
        final contact = _contacts.where((c) => c.pubKeyHex == id).firstOrNull;
        displayName = contact?.displayName ?? id.substring(0, 8);
      }

      conversations.add(MeshCoreConversation(
        id: id,
        type: type,
        displayName: displayName,
        lastMessage: msgs.isNotEmpty ? msgs.last : null,
        messageCount: msgs.length,
      ));
    }

    // Sort: conversations with messages first, by most recent
    conversations.sort((a, b) {
      final aTime = a.lastMessageTime;
      final bTime = b.lastMessageTime;
      if (aTime == null && bTime == null) return a.displayName.compareTo(b.displayName);
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });

    return conversations;
  }

  // ---------------------------------------------------------------------------
  // Init sequence
  // ---------------------------------------------------------------------------

  Future<void> _runInitSequence() async {
    try {
      LogService().log('MeshCoreService: running init sequence...');

      // 1. APP_START → SELF_INFO
      final selfInfo = await _bleClient.sendAndWait(
        encodeAppStart(),
        expectedCode: MeshCoreResp.selfInfo,
        timeout: const Duration(seconds: 5),
      );
      if (selfInfo is SelfInfoResponse) {
        _deviceInfo = MeshCoreDeviceInfo(
          pubKeyHex: bytesToHex(selfInfo.pubKey),
          name: selfInfo.name,
          frequencyMhz: selfInfo.frequency,
          bandwidthKhz: selfInfo.bandwidth,
          spreadingFactor: selfInfo.spreadingFactor,
          txPowerDbm: selfInfo.txPower,
        );
        _eventController.add(
          const MeshCoreEvent(MeshCoreEventType.deviceInfoUpdated),
        );
      }

      // 2. SET_DEVICE_TIME
      await _bleClient.send(encodeSetDeviceTime(DateTime.now()));

      // 3. DEVICE_QUERY → DEVICE_INFO
      try {
        final devInfo = await _bleClient.sendAndWait(
          encodeDeviceQuery(),
          expectedCode: MeshCoreResp.deviceInfo,
          timeout: const Duration(seconds: 3),
        );
        if (devInfo is DeviceInfoResponse && _deviceInfo != null) {
          _deviceInfo = MeshCoreDeviceInfo(
            pubKeyHex: _deviceInfo!.pubKeyHex,
            name: _deviceInfo!.name,
            firmwareVersion: devInfo.firmwareVersion,
            boardModel: devInfo.boardModel,
            frequencyMhz: _deviceInfo!.frequencyMhz,
            bandwidthKhz: _deviceInfo!.bandwidthKhz,
            spreadingFactor: _deviceInfo!.spreadingFactor,
            txPowerDbm: _deviceInfo!.txPowerDbm,
          );
          _eventController.add(
            const MeshCoreEvent(MeshCoreEventType.deviceInfoUpdated),
          );
        }
      } catch (e) {
        LogService().log('MeshCoreService: device query timeout (non-fatal): $e');
      }

      // 4. GET_CONTACTS → contact list
      try {
        final contactsResp = await _bleClient.sendAndWait(
          encodeGetContacts(),
          expectedCode: MeshCoreResp.contactsList,
          timeout: const Duration(seconds: 5),
        );
        if (contactsResp is ContactsListResponse) {
          _contacts.clear();
          final cacheContacts = <MeshCoreContact>[];
          for (final entry in contactsResp.contacts) {
            final contact = MeshCoreContact(
              pubKeyHex: entry.pubKeyHex,
              name: entry.name,
              lastSeen: entry.lastSeen > 0
                  ? DateTime.fromMillisecondsSinceEpoch(
                      entry.lastSeen * 1000,
                      isUtc: true,
                    )
                  : null,
              isRepeater: entry.isRepeater,
            );
            _contacts.add(contact);
            cacheContacts.add(contact);
          }
          await _cacheService?.saveContacts(cacheContacts);
          _eventController.add(
            const MeshCoreEvent(MeshCoreEventType.contactsUpdated),
          );
          LogService().log(
            'MeshCoreService: loaded ${_contacts.length} contacts',
          );
        }
      } catch (e) {
        LogService().log('MeshCoreService: get contacts timeout: $e');
      }

      // 5. GET_CHANNEL for all 8 slots
      _channels.clear();
      for (int i = 0; i < 8; i++) {
        try {
          final chResp = await _bleClient.sendAndWait(
            encodeGetChannel(i),
            expectedCode: MeshCoreResp.channelInfo,
            timeout: const Duration(seconds: 2),
          );
          if (chResp is ChannelInfoResponse) {
            final channel = MeshCoreChannel(
              index: chResp.channelIndex,
              name: chResp.name,
            );
            _channels.add(channel);
            await _cacheService?.saveChannel(channel);
          }
        } catch (e) {
          // Channel may not exist, skip
        }
      }
      _eventController.add(
        const MeshCoreEvent(MeshCoreEventType.channelsUpdated),
      );
      LogService().log(
        'MeshCoreService: loaded ${_channels.length} channels',
      );

      // 6. Drain queued messages
      await _drainMessages();

      _eventController.add(
        const MeshCoreEvent(MeshCoreEventType.connected),
      );
      LogService().log('MeshCoreService: init sequence complete');
    } catch (e) {
      LogService().log('MeshCoreService: init sequence error: $e');
      _eventController.add(
        MeshCoreEvent(MeshCoreEventType.error, 'Init failed: $e'),
      );
    }
  }

  /// Poll messages until no more are waiting.
  Future<void> _drainMessages() async {
    int count = 0;
    for (int i = 0; i < 100; i++) {
      try {
        final resp = await _bleClient.sendAndWait(
          encodeSyncNextMessage(),
          expectedCode: -1, // Accept any response
          timeout: const Duration(seconds: 3),
        );

        if (resp is NoMoreMessagesResponse) break;
        if (resp is ContactMessageResponse) {
          await _handleContactMessage(resp);
          count++;
        } else if (resp is ChannelMessageResponse) {
          await _handleChannelMessage(resp);
          count++;
        } else {
          break;
        }
      } catch (e) {
        break;
      }
    }
    if (count > 0) {
      LogService().log('MeshCoreService: drained $count queued messages');
    }
  }

  // ---------------------------------------------------------------------------
  // Response handling
  // ---------------------------------------------------------------------------

  void _startListening() {
    _responseSub?.cancel();
    _responseSub = _bleClient.responses.listen(_handleResponse);

    _bleStateSub?.cancel();
    _bleStateSub = _bleClient.stateChanges.listen((state) {
      if (state == MeshCoreBleState.disconnected && _enabled) {
        _eventController.add(
          const MeshCoreEvent(MeshCoreEventType.disconnected),
        );
      }
    });
  }

  void _handleResponse(MeshCoreResponse resp) {
    switch (resp) {
      case PushMsgWaiting():
        _drainMessages();
        break;
      case PushSendConfirmed():
        _handleSendConfirmed(resp);
        break;
      case PushAdvert():
        _handleAdvert(resp);
        break;
      case PushNoRouteFound():
        LogService().log('MeshCoreService: no route found for last message');
        break;
      case ContactMessageResponse():
        _handleContactMessage(resp);
        break;
      case ChannelMessageResponse():
        _handleChannelMessage(resp);
        break;
      case PushBatteryLevel():
        LogService().log('MeshCoreService: battery ${resp.percent}%');
        break;
      default:
        break;
    }
  }

  Future<void> _handleContactMessage(ContactMessageResponse resp) async {
    // Try to match sender prefix to a known contact
    final prefix = resp.senderPrefixHex;
    final contact = await _cacheService?.findContactByPrefix(prefix);

    final msg = MeshCoreMessage(
      conversationId: contact?.pubKeyHex ?? prefix,
      conversationType: MeshCoreConversationType.contact,
      text: resp.text,
      timestamp: resp.timestamp,
      direction: MeshCoreMessageDirection.incoming,
      snr: resp.snr,
      status: MeshCoreMessageStatus.acknowledged,
      senderName: contact?.name,
      senderKeyPrefix: prefix,
    );

    final id = await _cacheService?.saveMessage(msg);
    _messages.add(id != null && id > 0 ? msg.copyWith(id: id) : msg);
    _uiDirty = true;

    LogService().log(
      'MeshCoreService: received contact message from ${contact?.displayName ?? prefix}',
    );
  }

  Future<void> _handleChannelMessage(ChannelMessageResponse resp) async {
    final prefix = resp.senderPrefixHex;
    final contact = prefix != null
        ? await _cacheService?.findContactByPrefix(prefix)
        : null;

    final msg = MeshCoreMessage(
      conversationId: 'ch:${resp.channelIndex}',
      conversationType: MeshCoreConversationType.channel,
      text: resp.text,
      timestamp: resp.timestamp,
      direction: MeshCoreMessageDirection.incoming,
      snr: resp.snr,
      status: MeshCoreMessageStatus.acknowledged,
      senderName: contact?.name,
      senderKeyPrefix: prefix,
    );

    final id = await _cacheService?.saveMessage(msg);
    _messages.add(id != null && id > 0 ? msg.copyWith(id: id) : msg);
    _uiDirty = true;

    LogService().log(
      'MeshCoreService: received channel ${resp.channelIndex} message',
    );
  }

  void _handleSendConfirmed(PushSendConfirmed resp) {
    // Mark most recent outgoing message as acknowledged
    for (int i = _messages.length - 1; i >= 0; i--) {
      final msg = _messages[i];
      if (msg.isOutgoing && msg.status == MeshCoreMessageStatus.sent) {
        _messages[i] = msg.copyWith(status: MeshCoreMessageStatus.acknowledged);
        if (msg.id != null) {
          _cacheService?.updateMessageStatus(
            msg.id!,
            MeshCoreMessageStatus.acknowledged,
          );
        }
        _uiDirty = true;
        LogService().log('MeshCoreService: send confirmed (ACK)');
        break;
      }
    }
  }

  void _handleAdvert(PushAdvert resp) {
    final pubKeyHex = bytesToHex(resp.pubKey);
    final existing = _contacts.indexWhere((c) => c.pubKeyHex == pubKeyHex);
    final updated = MeshCoreContact(
      pubKeyHex: pubKeyHex,
      name: resp.name,
      lastSeen: DateTime.now().toUtc(),
      lastSnr: resp.snr,
    );

    if (existing >= 0) {
      _contacts[existing] = updated;
    } else {
      _contacts.add(updated);
    }
    _cacheService?.saveContact(updated);
    _eventController.add(
      const MeshCoreEvent(MeshCoreEventType.contactsUpdated),
    );
  }

  // ---------------------------------------------------------------------------
  // Cached data loading
  // ---------------------------------------------------------------------------

  Future<void> _loadCachedData() async {
    if (_cacheService == null) return;
    try {
      _contacts.clear();
      _contacts.addAll(await _cacheService!.loadContacts());

      _channels.clear();
      _channels.addAll(await _cacheService!.loadChannels());

      _messages.clear();
      _messages.addAll(await _cacheService!.loadMessages(limit: 2000));

      LogService().log(
        'MeshCoreService: loaded cache — '
        '${_contacts.length} contacts, '
        '${_channels.length} channels, '
        '${_messages.length} messages',
      );
    } catch (e) {
      LogService().log('MeshCoreService: cache load error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // UI throttle
  // ---------------------------------------------------------------------------

  void _startUiTimer() {
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(_uiUpdateInterval, (_) {
      if (_uiDirty) {
        _uiDirty = false;
        _eventController.add(
          const MeshCoreEvent(MeshCoreEventType.messageReceived),
        );
      }
    });
  }

  void _stopUiTimer() {
    _uiTimer?.cancel();
    _uiTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Config persistence
  // ---------------------------------------------------------------------------

  Future<void> _saveConfig() async {
    await _cacheService?.saveConfig({
      'enabled': _enabled,
      'deviceId': _savedDeviceId,
    });
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  void dispose() {
    _stopUiTimer();
    _responseSub?.cancel();
    _bleStateSub?.cancel();
    _bleClient.dispose();
    _cacheService?.dispose();
    _eventController.close();
  }
}
