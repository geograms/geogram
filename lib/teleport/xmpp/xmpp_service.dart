/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Core XMPP bridge service — singleton with event stream.
 * Multi-server: manages one XmppClient per configured server.
 * Follows the IrcService singleton + event stream pattern.
 *
 * UI events are throttled (500ms) so high-volume message streams
 * don't freeze the Flutter UI with per-message setState rebuilds.
 *
 * Storage: one SQLite database per server under teleport/xmpp/cache/{serverId}.db
 * Each DB stores both room metadata and message history.
 */

import 'dart:async';

import '../../models/monitored_task.dart';
import '../../services/app_service.dart';
import '../../services/log_service.dart';
import '../../services/profile_service.dart';
import '../../services/profile_storage.dart';
import '../../util/task_monitor_helpers.dart';
import 'xmpp_cache_service.dart';
import 'xmpp_client.dart';
import 'models/xmpp_room.dart';
import 'models/xmpp_message.dart';
import 'models/xmpp_server_config.dart';

/// Event types emitted by the XMPP bridge.
enum XmppEventType {
  connected,
  disconnected,
  messageReceived,
  roomJoined,
  roomLeft,
  occupantListUpdated,
  subjectChanged,
  roomListReceived,
  error,
  configChanged,
}

/// An event from the XMPP bridge.
class XmppEvent {
  final XmppEventType type;
  final String? serverId;
  final dynamic data;

  const XmppEvent(this.type, {this.serverId, this.data});

  @override
  String toString() => 'XmppEvent($type, server=$serverId)';
}

/// Core XMPP bridge singleton.
class XmppService {
  static final XmppService _instance = XmppService._internal();
  factory XmppService() => _instance;
  XmppService._internal();

  XmppCacheService? _cacheService;
  XmppCacheService? get cacheService => _cacheService;

  /// Active clients keyed by server config ID.
  final Map<String, XmppClient> _clients = {};

  /// Server configs keyed by ID.
  final Map<String, XmppServerConfig> _configs = {};

  /// Rooms keyed by "serverId:roomJid".
  final Map<String, XmppRoom> _rooms = {};

  /// In-memory messages keyed by "serverId:roomJid".
  final Map<String, List<XmppMessage>> _messages = {};

  /// Latest room list from discovery, keyed by serverId.
  final Map<String, List<Map<String, dynamic>>> _roomLists = {};

  /// Task monitor handles per server for background task visibility.
  final Map<String, MonitoredPeriodicTimer> _taskHandles = {};

  // UI throttle — only runs when XMPP pages are visible
  static const Duration _uiUpdateInterval = Duration(milliseconds: 500);
  MonitoredPeriodicTimer? _uiUpdateTimer;
  bool _uiDirty = false;
  int _uiObserverCount = 0;

  // Batch SQLite writes — per-server queues
  static const Duration _writeFlushInterval = Duration(seconds: 2);
  static const int _writeFlushThreshold = 50;
  final Map<String, List<XmppMessage>> _writeQueues = {};
  MonitoredAsyncPeriodicTimer? _writeTimer;

  final StreamController<XmppEvent> _eventController =
      StreamController<XmppEvent>.broadcast();

  /// Stream of XMPP bridge events.
  Stream<XmppEvent> get events => _eventController.stream;

  /// All configured servers.
  List<XmppServerConfig> get servers => _configs.values.toList();

  /// Whether any XMPP server is connected.
  bool get isAnyConnected => _clients.values.any((c) => c.isConnected);

  /// Check if a specific server is connected.
  bool isConnected(String serverId) => _clients[serverId]?.isConnected ?? false;

  /// Check if a client exists (connecting or connected).
  bool isClientActive(String serverId) => _clients.containsKey(serverId);

  /// Get nickname for a server.
  String? currentNick(String serverId) => _clients[serverId]?.nickname;

  /// Get rooms for a specific server.
  List<XmppRoom> getRooms(String serverId) {
    return _rooms.values
        .where((r) => r.serverConfigId == serverId)
        .toList();
  }

  /// Get messages for a specific room.
  List<XmppMessage> getMessages(String serverId, String roomJid) {
    return _messages['$serverId:$roomJid'] ?? [];
  }

  /// Get latest room list from discovery.
  List<Map<String, dynamic>> getRoomList(String serverId) {
    return _roomLists[serverId] ?? [];
  }

  /// Wire up persistence via ProfileStorage.
  void setStorage(ProfileStorage storage) {
    _cacheService = XmppCacheService(storage);
  }

  /// Load saved configs and auto-connect servers marked as autoConnect.
  Future<void> autoStart(ProfileStorage storage) async {
    setStorage(storage);
    final servers = await _cacheService!.loadServers();
    var migrated = false;
    for (var config in servers) {
      // Migrate preset servers from STARTTLS (5222) to DirectTLS (5223)
      // — whixp 3.0.0 has a STARTTLS race condition causing TLS failures.
      if (!config.directTls && config.port == 5222) {
        final preset = XmppServerConfig.presets.cast<XmppServerConfig?>().firstWhere(
          (p) => p!.host == config.host,
          orElse: () => null,
        );
        if (preset != null && preset.directTls) {
          config = config.copyWith(port: 5223, directTls: true);
          migrated = true;
        }
      }
      _configs[config.id] = config;
      // Restore cached rooms for each server
      await _loadCachedRooms(config.id);
      if (config.autoConnect) {
        connect(config.id);
      }
    }
    if (migrated) {
      await _saveConfigs();
      LogService().log('XmppService: migrated servers to DirectTLS (port 5223)');
    }
    if (servers.isNotEmpty) {
      LogService().log('XmppService: loaded ${servers.length} server configs');
    }
  }

  /// Rejoin cached rooms that aren't in the server's autoJoinRooms list.
  void _rejoinCachedRooms(String serverId) {
    if (!isConnected(serverId)) return;
    final config = _configs[serverId];
    final autoJoin = config?.autoJoinRooms
            .map((r) => r.toLowerCase())
            .toSet() ??
        {};
    final cachedRooms = getRooms(serverId);
    final nick = _getProfileNickname();
    for (final room in cachedRooms) {
      if (!autoJoin.contains(room.jid.toLowerCase())) {
        LogService().log('XmppService: rejoining cached room ${room.jid}');
        _clients[serverId]?.joinRoom(room.jid, nick);
      }
    }
  }

  /// Load cached rooms from the server's SQLite DB into memory.
  Future<void> _loadCachedRooms(String serverId) async {
    if (_cacheService == null) return;
    final cached = await _cacheService!.loadRooms(serverId);
    for (final room in cached) {
      final key = '$serverId:${room.jid}';
      _rooms.putIfAbsent(key, () => room);
    }
  }

  // ---------------------------------------------------------------------------
  // Server management
  // ---------------------------------------------------------------------------

  /// Add a new server config.
  Future<void> addServer(XmppServerConfig config) async {
    _configs[config.id] = config;
    await _saveConfigs();
    _emitEvent(XmppEvent(XmppEventType.configChanged, serverId: config.id));
  }

  /// Update an existing server config.
  Future<void> updateServer(XmppServerConfig config) async {
    _configs[config.id] = config;
    await _saveConfigs();
    _emitEvent(XmppEvent(XmppEventType.configChanged, serverId: config.id));
  }

  /// Remove a server config and disconnect if connected.
  Future<void> removeServer(String serverId) async {
    await disconnectServer(serverId);
    _configs.remove(serverId);
    _rooms.removeWhere((k, v) => v.serverConfigId == serverId);
    _messages.removeWhere((k, _) => k.startsWith('$serverId:'));
    _writeQueues.remove(serverId);
    await _saveConfigs();
    _emitEvent(XmppEvent(XmppEventType.configChanged, serverId: serverId));
  }

  // ---------------------------------------------------------------------------
  // Account registration
  // ---------------------------------------------------------------------------

  /// Attempt XEP-0077 in-band registration on a server, then save config.
  /// Returns result map with 'success', 'jid', 'password', or 'error'.
  Future<Map<String, dynamic>> registerAccount({
    required String host,
    int port = 5222,
    String? username,
    String? password,
    bool directTls = false,
    String? conferenceService,
    bool autoConnect = true,
  }) async {
    // Generate username from callsign + random suffix if not provided
    username ??= _generateUsername();
    password ??= XmppClient.generatePassword();

    final result = await XmppClient.registerAccount(
      host: host,
      port: port,
      username: username,
      password: password,
      directTls: directTls,
    );

    if (result['success'] == true) {
      final jid = result['jid'] as String;
      final id = '${host}_${DateTime.now().millisecondsSinceEpoch}';
      final config = XmppServerConfig(
        id: id,
        name: host,
        host: host,
        port: port,
        directTls: directTls,
        jid: jid,
        password: result['password'] as String,
        conferenceService: conferenceService ?? 'conference.$host',
        autoConnect: autoConnect,
      );
      await addServer(config);
      result['serverId'] = id;
    }
    return result;
  }

  /// Generate a username from the profile callsign + random suffix.
  String _generateUsername() {
    final callsign = AppService().currentCallsign ?? 'geogram';
    // Sanitize: lowercase, only alphanumeric and underscores
    final base = callsign.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final suffix = DateTime.now().millisecondsSinceEpoch % 10000;
    return '${base.isNotEmpty ? base : 'geogram'}_$suffix';
  }

  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------

  /// Derive the XMPP nickname from the user's profile.
  String _getProfileNickname() {
    final profile = ProfileService().getProfile();
    final raw = profile.displayName.isNotEmpty
        ? profile.displayName
        : (AppService().currentCallsign ?? 'user');
    // XMPP nicks are more permissive than IRC — allow spaces, unicode
    return raw.length > 32 ? raw.substring(0, 32) : raw;
  }

  /// Connect to a server by config ID.
  void connect(String serverId) {
    final config = _configs[serverId];
    if (config == null) {
      LogService().log('XmppService: no config for server $serverId');
      return;
    }

    if (_clients.containsKey(serverId)) {
      LogService().log('XmppService: already connected/connecting to $serverId');
      return;
    }

    _startWriteTimer();

    final nick = _getProfileNickname();
    // Provide a writable database path for Whixp's internal DB
    final dbPath = _cacheService != null
        ? _cacheService!.getWhixpDbPath(serverId)
        : '';
    final client = XmppClient(config: config, nickname: nick, databasePath: dbPath);
    client.onEvent = (event) => _handleClientEvent(serverId, event);
    _clients[serverId] = client;
    client.connect();
    LogService().log('XmppService: connecting to ${config.host}:${config.port} as $nick');
  }

  /// Disconnect from a server.
  Future<void> disconnectServer(String serverId) async {
    final client = _clients.remove(serverId);
    if (client != null) {
      client.onEvent = null;
      await client.disconnect();
      LogService().log('XmppService: disconnected from $serverId');
      _flushServerWrites(serverId);
      _emitEvent(XmppEvent(XmppEventType.disconnected, serverId: serverId));
    }
    _taskHandles.remove(serverId)?.cancel();
    if (_clients.isEmpty) {
      _stopWriteTimer();
    }
  }

  // ---------------------------------------------------------------------------
  // Room operations
  // ---------------------------------------------------------------------------

  /// Join a room on a server.
  void joinRoom(String serverId, String roomJid) {
    final nick = _getProfileNickname();
    _clients[serverId]?.joinRoom(roomJid, nick);
  }

  /// Leave a room on a server.
  void leaveRoom(String serverId, String roomJid) {
    _clients[serverId]?.leaveRoom(roomJid);
  }

  /// Mark a room as read.
  void markRoomRead(String serverId, String roomJid) {
    final key = '$serverId:$roomJid';
    final room = _rooms[key];
    if (room != null) {
      room.unreadCount = 0;
    }
    _cacheService?.markRoomRead(serverId, roomJid);
  }

  /// Send a message to a room.
  XmppMessage? sendMessage(String serverId, String roomJid, String text) {
    final client = _clients[serverId];
    if (client == null || !client.isConnected) return null;

    client.sendGroupMessage(roomJid, text);

    // Create local echo
    final echo = XmppMessage(
      serverConfigId: serverId,
      roomJid: roomJid,
      sender: client.nickname,
      text: text,
      timestamp: DateTime.now().toUtc(),
      isOutgoing: true,
      type: XmppMessageType.groupchat,
    );

    _addMessage(echo);
    _flushServerWrites(serverId);
    return echo;
  }

  /// Request room discovery on a conference service.
  void discoverRooms(String serverId) {
    final config = _configs[serverId];
    if (config == null) return;
    _clients[serverId]?.discoverRooms(config.derivedConferenceService);
  }

  /// Set room subject/topic.
  void setRoomSubject(String serverId, String roomJid, String subject) {
    _clients[serverId]?.setRoomSubject(roomJid, subject);
  }

  /// Handle slash commands from compose bar.
  bool handleSlashCommand(String serverId, String roomJid, String input) {
    final parts = input.split(' ');
    final cmd = parts[0].toLowerCase();

    switch (cmd) {
      case '/join':
        if (parts.length >= 2) {
          joinRoom(serverId, parts[1]);
          return true;
        }
        return false;
      case '/part':
        leaveRoom(serverId, parts.length >= 2 ? parts[1] : roomJid);
        return true;
      case '/nick':
        // XMPP nick changes in MUC require rejoining
        return false;
      case '/subject':
        if (parts.length >= 2) {
          setRoomSubject(serverId, roomJid, parts.sublist(1).join(' '));
          return true;
        }
        return false;
      case '/msg':
        if (parts.length >= 3) {
          final target = parts[1];
          final text = parts.sublist(2).join(' ');
          final client = _clients[serverId];
          if (client != null && client.isConnected) {
            client.sendChatMessage(target, text);
          }
          return true;
        }
        return false;
      case '/me':
        return false; // Send as regular text
      default:
        return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Client event handling
  // ---------------------------------------------------------------------------

  void _handleClientEvent(String serverId, Map<String, dynamic> event) {
    final type = event['type'] as String?;

    switch (type) {
      case 'connected':
        _emitEvent(XmppEvent(XmppEventType.connected, serverId: serverId));
        // Rejoin cached rooms after a short delay
        Future.delayed(const Duration(seconds: 2), () {
          _rejoinCachedRooms(serverId);
        });
        break;

      case 'disconnected':
        _flushServerWrites(serverId);
        _saveRoomState(serverId);
        _emitEvent(XmppEvent(XmppEventType.disconnected, serverId: serverId));
        break;

      case 'message':
        final roomJid = event['roomJid'] as String;
        final sender = event['sender'] as String;
        final senderJid = event['senderJid'] as String?;
        final text = event['text'] as String;
        final nick = _clients[serverId]?.nickname ?? '';
        final isOutgoing = sender == nick;

        final msg = XmppMessage(
          serverConfigId: serverId,
          roomJid: roomJid,
          sender: sender,
          senderJid: senderJid,
          text: text,
          timestamp: DateTime.now().toUtc(),
          isOutgoing: isOutgoing,
          type: XmppMessageType.groupchat,
        );
        _addMessage(msg);
        break;

      case 'subject':
        final roomJid = event['roomJid'] as String;
        final subject = event['subject'] as String;
        final key = '$serverId:$roomJid';
        final room = _rooms[key];
        if (room != null) {
          room.subject = subject;
          _cacheService?.saveRoom(serverId, room);
        }
        _emitEvent(XmppEvent(
          XmppEventType.subjectChanged,
          serverId: serverId,
          data: {'roomJid': roomJid, 'subject': subject},
        ));
        break;

      case 'occupant_joined':
        final roomJid = event['roomJid'] as String;
        final nick = event['nick'] as String;
        final key = '$serverId:$roomJid';
        final room = _rooms.putIfAbsent(
          key,
          () => XmppRoom(serverConfigId: serverId, jid: roomJid),
        );
        if (!room.occupants.contains(nick)) room.occupants.add(nick);
        final myNick = _clients[serverId]?.nickname ?? '';
        if (nick == myNick) {
          // We joined the room
          _cacheService?.saveRoom(serverId, room);
          _emitEvent(XmppEvent(
            XmppEventType.roomJoined,
            serverId: serverId,
            data: roomJid,
          ));
        }
        // System message
        final msg = XmppMessage(
          serverConfigId: serverId,
          roomJid: roomJid,
          sender: nick,
          text: '$nick has joined',
          timestamp: DateTime.now().toUtc(),
          type: XmppMessageType.join,
        );
        _addMessage(msg);
        break;

      case 'occupant_left':
        final roomJid = event['roomJid'] as String;
        final nick = event['nick'] as String;
        final key = '$serverId:$roomJid';
        _rooms[key]?.occupants.remove(nick);
        final myNick = _clients[serverId]?.nickname ?? '';
        if (nick == myNick) {
          _rooms.remove(key);
          _cacheService?.removeRoom(serverId, roomJid);
          _emitEvent(XmppEvent(
            XmppEventType.roomLeft,
            serverId: serverId,
            data: roomJid,
          ));
        } else {
          final msg = XmppMessage(
            serverConfigId: serverId,
            roomJid: roomJid,
            sender: nick,
            text: '$nick has left',
            timestamp: DateTime.now().toUtc(),
            type: XmppMessageType.leave,
          );
          _addMessage(msg);
        }
        break;

      case 'room_left':
        final roomJid = event['roomJid'] as String;
        final key = '$serverId:$roomJid';
        _rooms.remove(key);
        _cacheService?.removeRoom(serverId, roomJid);
        _emitEvent(XmppEvent(
          XmppEventType.roomLeft,
          serverId: serverId,
          data: roomJid,
        ));
        break;

      case 'room_list':
        final rooms = (event['rooms'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _roomLists[serverId] = rooms;
        _emitEvent(XmppEvent(
          XmppEventType.roomListReceived,
          serverId: serverId,
          data: rooms,
        ));
        break;

      case 'error':
        LogService().log('XmppService[$serverId]: ${event['message']}');
        _emitEvent(XmppEvent(
          XmppEventType.error,
          serverId: serverId,
          data: event['message'],
        ));
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Message storage
  // ---------------------------------------------------------------------------

  void _addMessage(XmppMessage msg) {
    final key = '${msg.serverConfigId}:${msg.roomJid}';

    // In-memory list
    final list = _messages.putIfAbsent(key, () => []);
    list.add(msg);
    if (list.length > 5000) {
      list.removeRange(0, list.length - 5000);
    }

    // Update room's last message
    final room = _rooms[key];
    if (room != null) {
      room.lastMessage = msg;
      if (!msg.isOutgoing) room.unreadCount++;
    }

    // Queue for batch write to per-server DB
    if (!msg.isSystemMessage) {
      final queue = _writeQueues.putIfAbsent(msg.serverConfigId, () => []);
      queue.add(msg);
      if (queue.length >= _writeFlushThreshold) {
        _flushServerWrites(msg.serverConfigId);
      }
    }

    _uiDirty = true;
  }

  /// Load cached messages for a room from the server's SQLite DB.
  Future<void> loadCachedMessages(String serverId, String roomJid) async {
    if (_cacheService == null) return;
    final cached = await _cacheService!.loadMessages(serverId, roomJid);
    if (cached.isEmpty) return;
    final key = '$serverId:$roomJid';
    final list = _messages.putIfAbsent(key, () => []);
    if (list.isEmpty) {
      list.addAll(cached);
    } else {
      final existing = <String>{};
      for (final m in list) {
        existing.add('${m.timestamp.millisecondsSinceEpoch}|${m.sender}|${m.roomJid}');
      }
      final toAdd = <XmppMessage>[];
      for (final m in cached) {
        final key2 = '${m.timestamp.millisecondsSinceEpoch}|${m.sender}|${m.roomJid}';
        if (!existing.contains(key2)) {
          toAdd.add(m);
        }
      }
      if (toAdd.isNotEmpty) {
        list.insertAll(0, toAdd);
        list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      }
    }
    _uiDirty = true;
  }

  /// Flush pending writes for a specific server.
  Future<void> _flushServerWrites(String serverId) async {
    final queue = _writeQueues[serverId];
    if (queue == null || queue.isEmpty || _cacheService == null) return;
    final batch = List<XmppMessage>.from(queue);
    queue.clear();
    try {
      await _cacheService!.cacheMessages(serverId, batch);
    } catch (e) {
      LogService().log('XmppService: flush error for $serverId: $e');
    }
  }

  /// Flush all pending writes across all servers.
  Future<void> _flushAllWrites() async {
    for (final serverId in _writeQueues.keys.toList()) {
      await _flushServerWrites(serverId);
    }
  }

  /// Public API — flush pending writes and save room state.
  void flushWrites() {
    _flushAllWrites();
    for (final serverId in _clients.keys) {
      _saveRoomState(serverId);
    }
  }

  /// Persist current room state for a server to its SQLite DB.
  void _saveRoomState(String serverId) {
    final rooms = getRooms(serverId);
    if (rooms.isNotEmpty) {
      _cacheService?.saveRooms(serverId, rooms);
    }
  }

  // ---------------------------------------------------------------------------
  // UI throttle timer
  // ---------------------------------------------------------------------------

  void addUiObserver() {
    _uiObserverCount++;
    if (_uiObserverCount == 1) _startUiTimer();
  }

  void removeUiObserver() {
    _uiObserverCount--;
    if (_uiObserverCount <= 0) {
      _uiObserverCount = 0;
      _stopUiTimer();
    }
  }

  void _startUiTimer() {
    _uiUpdateTimer ??= MonitoredPeriodicTimer(
      id: 'xmpp.ui_update',
      name: 'XMPP UI Update',
      description: 'Throttled UI refresh for incoming XMPP messages (500ms)',
      serviceName: 'XmppService',
      interval: _uiUpdateInterval,
      priority: TaskPriority.low,
      callback: _onUiTick,
    );
  }

  void _stopUiTimer() {
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;
  }

  void _startWriteTimer() {
    _writeTimer ??= MonitoredAsyncPeriodicTimer(
      id: 'xmpp.write_flush',
      name: 'XMPP Write Flush',
      description: 'Batches XMPP message writes to SQLite (2s interval)',
      serviceName: 'XmppService',
      interval: _writeFlushInterval,
      priority: TaskPriority.normal,
      callback: (_) async => await _flushAllWrites(),
    );
  }

  void _stopWriteTimer() {
    _writeTimer?.cancel();
    _writeTimer = null;
    _flushAllWrites();
  }

  void _onUiTick(Timer _) {
    if (_uiDirty) {
      _uiDirty = false;
      _eventController.add(const XmppEvent(XmppEventType.messageReceived));
    }
  }

  void _emitEvent(XmppEvent event) {
    _eventController.add(event);
  }

  // ---------------------------------------------------------------------------
  // Config persistence
  // ---------------------------------------------------------------------------

  Future<void> _saveConfigs() async {
    if (_cacheService == null) return;
    await _cacheService!.saveServers(_configs.values.toList());
  }

  // ---------------------------------------------------------------------------
  // Status (for debug API)
  // ---------------------------------------------------------------------------

  Map<String, dynamic> getStatus() {
    final serverList = <Map<String, dynamic>>[];
    for (final config in _configs.values) {
      final client = _clients[config.id];
      final rooms = getRooms(config.id);
      serverList.add({
        'id': config.id,
        'name': config.name,
        'host': '${config.host}:${config.port}',
        'jid': config.jid,
        'connected': client?.isConnected ?? false,
        'nick': client?.nickname ?? _getProfileNickname(),
        'rooms': rooms.map((r) {
          final key = '${config.id}:${r.jid}';
          final msgCount = _messages[key]?.length ?? 0;
          return {
            'jid': r.jid,
            'name': r.name,
            'subject': r.subject,
            'occupants': r.occupants.length,
            'messagesInMemory': msgCount,
            'unread': r.unreadCount,
          };
        }).toList(),
        'writeQueueSize': _writeQueues[config.id]?.length ?? 0,
      });
    }
    return {
      'servers': serverList,
      'anyConnected': isAnyConnected,
    };
  }

  /// Dispose all resources.
  void dispose() {
    _stopUiTimer();
    _stopWriteTimer();
    for (final client in _clients.values) {
      client.onEvent = null;
      client.disconnect();
    }
    _clients.clear();
    for (final handle in _taskHandles.values) {
      handle.cancel();
    }
    _taskHandles.clear();
    _cacheService?.dispose();
    _cacheService = null;
    _eventController.close();
  }
}
