/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Core IRC bridge service — singleton with event stream.
 * Multi-server: manages one IrcClient per configured server.
 * Follows the AprsService singleton + event stream pattern.
 *
 * UI events are throttled (500ms) so high-volume message streams
 * don't freeze the Flutter UI with per-message setState rebuilds.
 *
 * Storage: one SQLite database per server under teleport/irc/cache/{serverId}.db
 * Each DB stores both channel metadata and message history.
 */

import 'dart:async';

import '../../models/monitored_task.dart';
import '../../services/app_service.dart';
import '../../services/log_service.dart';
import '../../services/profile_service.dart';
import '../../services/profile_storage.dart';
import '../../util/event_bus.dart';
import '../../util/task_monitor_helpers.dart';
import 'irc_cache_service.dart';
import 'irc_client.dart';
import 'models/irc_channel.dart';
import 'models/irc_message.dart';
import 'models/irc_server_config.dart';

/// Event types emitted by the IRC bridge.
enum IrcEventType {
  connected,
  disconnected,
  messageReceived,
  channelJoined,
  channelLeft,
  userListUpdated,
  topicChanged,
  channelListReceived,
  typingUpdated,
  error,
  configChanged,
}

/// An event from the IRC bridge.
class IrcEvent {
  final IrcEventType type;
  final String? serverId;
  final dynamic data;

  const IrcEvent(this.type, {this.serverId, this.data});

  @override
  String toString() => 'IrcEvent($type, server=$serverId)';
}

/// Core IRC bridge singleton.
class IrcService {
  static final IrcService _instance = IrcService._internal();
  factory IrcService() => _instance;
  IrcService._internal();

  IrcCacheService? _cacheService;
  IrcCacheService? get cacheService => _cacheService;

  /// Active clients keyed by server config ID.
  final Map<String, IrcClient> _clients = {};

  /// Server configs keyed by ID.
  final Map<String, IrcServerConfig> _configs = {};

  /// Channels keyed by "serverId:channelName".
  final Map<String, IrcChannel> _channels = {};

  /// In-memory messages keyed by "serverId:channelName".
  final Map<String, List<IrcMessage>> _messages = {};

  /// Typing users keyed by "serverId:channelName".
  final Map<String, Set<String>> _typingUsers = {};

  /// Latest channel list from LIST command, keyed by serverId.
  final Map<String, List<Map<String, dynamic>>> _channelLists = {};

  /// Task monitor handles per server for background task visibility.
  final Map<String, MonitoredIsolateHandle> _taskHandles = {};

  // UI throttle — only runs when IRC pages are visible
  static const Duration _uiUpdateInterval = Duration(milliseconds: 500);
  MonitoredPeriodicTimer? _uiUpdateTimer;
  bool _uiDirty = false;
  int _uiObserverCount = 0;

  // Batch SQLite writes — per-server queues
  static const Duration _writeFlushInterval = Duration(seconds: 2);
  static const int _writeFlushThreshold = 50;

  /// System messages (join/part/quit) older than this are pruned from memory.
  static const Duration _systemMessageMaxAge = Duration(hours: 12);
  final Map<String, List<IrcMessage>> _writeQueues = {};
  MonitoredAsyncPeriodicTimer? _writeTimer;

  final StreamController<IrcEvent> _eventController =
      StreamController<IrcEvent>.broadcast();

  /// Stream of IRC bridge events.
  Stream<IrcEvent> get events => _eventController.stream;

  /// All configured servers.
  List<IrcServerConfig> get servers => _configs.values.toList();

  /// Whether any IRC server is connected.
  bool get isAnyConnected => _clients.values.any((c) => c.isConnected);

  /// Check if a specific server is connected.
  bool isConnected(String serverId) => _clients[serverId]?.isConnected ?? false;

  /// Check if a client exists (connecting or connected).
  bool isClientActive(String serverId) => _clients.containsKey(serverId);

  /// Get current nick for a server.
  String? currentNick(String serverId) => _clients[serverId]?.currentNick;

  /// Get channels for a specific server.
  List<IrcChannel> getChannels(String serverId) {
    return _channels.values
        .where((ch) => ch.serverConfigId == serverId)
        .toList();
  }

  /// Get messages for a specific channel.
  List<IrcMessage> getMessages(String serverId, String channel) {
    return _messages['$serverId:$channel'] ?? [];
  }


  /// Get typing users for a channel.
  List<String> getTypingUsers(String serverId, String channel) {
    return _typingUsers['$serverId:$channel']?.toList() ?? [];
  }

  /// Get latest channel list from LIST command.
  List<Map<String, dynamic>> getChannelList(String serverId) {
    return _channelLists[serverId] ?? [];
  }

  /// Wire up persistence via ProfileStorage.
  void setStorage(ProfileStorage storage) {
    _cacheService = IrcCacheService(storage);
  }

  /// Load saved configs and auto-connect servers marked as autoConnect.
  Future<void> autoStart(ProfileStorage storage) async {
    setStorage(storage);
    final servers = await _cacheService!.loadServers();
    for (final config in servers) {
      _configs[config.id] = config;
      // Restore cached channels for each server
      await _loadCachedChannels(config.id);
      if (config.autoConnect) {
        connect(config.id);
      }
    }
    if (servers.isNotEmpty) {
      LogService().log('IrcService: loaded ${servers.length} server configs');
    }
  }

  /// Rejoin cached channels that aren't in the server's autoJoinChannels list.
  /// Called after the IRC client emits 'connected' (auto-join from config is
  /// already handled by the client itself).
  void _rejoinCachedChannels(String serverId) {
    if (!isConnected(serverId)) return;
    final config = _configs[serverId];
    final autoJoin = config?.autoJoinChannels
            .map((c) => c.toLowerCase())
            .toSet() ??
        {};
    final cachedChannels = getChannels(serverId);
    for (final ch in cachedChannels) {
      if (!autoJoin.contains(ch.name.toLowerCase())) {
        LogService().log('IrcService: rejoining cached channel ${ch.name}');
        _clients[serverId]?.joinChannel(ch.name);
      }
    }
    if (cachedChannels.isNotEmpty) {
      LogService().log(
        'IrcService: rejoin complete — '
        '${cachedChannels.length} cached, '
        '${autoJoin.length} auto-join, '
        '${cachedChannels.where((c) => !autoJoin.contains(c.name.toLowerCase())).length} rejoined',
      );
    }
  }

  /// Load cached channels from the server's SQLite DB into memory.
  Future<void> _loadCachedChannels(String serverId) async {
    if (_cacheService == null) return;
    final cached = await _cacheService!.loadChannels(serverId);
    for (final ch in cached) {
      final key = '$serverId:${ch.name}';
      _channels.putIfAbsent(key, () => ch);
    }
  }

  // ---------------------------------------------------------------------------
  // Server management
  // ---------------------------------------------------------------------------

  /// Add a new server config.
  Future<void> addServer(IrcServerConfig config) async {
    _configs[config.id] = config;
    await _saveConfigs();
    _emitEvent(IrcEvent(IrcEventType.configChanged, serverId: config.id));
  }

  /// Update an existing server config.
  Future<void> updateServer(IrcServerConfig config) async {
    _configs[config.id] = config;
    await _saveConfigs();
    _emitEvent(IrcEvent(IrcEventType.configChanged, serverId: config.id));
  }

  /// Remove a server config and disconnect if connected.
  Future<void> removeServer(String serverId) async {
    disconnect(serverId);
    _configs.remove(serverId);
    // Remove channels and messages for this server
    _channels.removeWhere((k, v) => v.serverConfigId == serverId);
    _messages.removeWhere((k, _) => k.startsWith('$serverId:'));
    _writeQueues.remove(serverId);
    await _saveConfigs();
    _emitEvent(IrcEvent(IrcEventType.configChanged, serverId: serverId));
  }

  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------

  /// Sanitize a string for IRC: alphanumeric + _-[]{}|\, max 16 chars.
  String _sanitizeNick(String raw) {
    final sanitized =
        raw.replaceAll(RegExp(r'[^a-zA-Z0-9_\-\[\]{}|\\]'), '_');
    return sanitized.length > 16 ? sanitized.substring(0, 16) : sanitized;
  }

  /// Derive the IRC nickname from the user's profile (single source of truth).
  /// Returns displayName (nickname if set, else callsign), sanitized for IRC.
  String _getProfileNickname() {
    final profile = ProfileService().getProfile();
    final raw = profile.displayName.isNotEmpty
        ? profile.displayName
        : (AppService().currentCallsign ?? 'user');
    return _sanitizeNick(raw);
  }

  /// Get the callsign as a fallback nickname (used when primary nick is taken).
  String? _getFallbackNickname() {
    final callsign = AppService().currentCallsign;
    if (callsign == null || callsign.isEmpty) return null;
    final sanitized = _sanitizeNick(callsign);
    // Only useful as fallback if different from primary
    final primary = _getProfileNickname();
    return sanitized != primary ? sanitized : null;
  }

  /// Connect to a server by config ID.
  void connect(String serverId) {
    final config = _configs[serverId];
    if (config == null) {
      LogService().log('IrcService: no config for server $serverId');
      return;
    }

    if (_clients.containsKey(serverId)) {
      LogService().log('IrcService: already connected/connecting to $serverId');
      return;
    }

    _startWriteTimer();

    // Register background task for visibility in task monitor
    _taskHandles[serverId]?.dispose();
    _taskHandles[serverId] = MonitoredIsolateHandle(
      id: 'irc.client.$serverId',
      name: 'IRC ${config.name}',
      description: 'IRC connection to ${config.host}:${config.port}',
      serviceName: 'IrcService',
      priority: TaskPriority.normal,
    );

    final nick = _getProfileNickname();
    final fallback = _getFallbackNickname();
    final profile = ProfileService().getProfile();
    final realname = profile.displayName.isNotEmpty
        ? profile.displayName
        : (AppService().currentCallsign ?? nick);
    final client = IrcClient(config: config, nickname: nick, fallbackNickname: fallback, realname: realname);
    client.onEvent = (event) => _handleClientEvent(serverId, event);
    _clients[serverId] = client;
    client.connect();
    LogService().log('IrcService: connecting to ${config.host}:${config.port} as $nick${fallback != null ? ' (fallback: $fallback)' : ''}');
  }

  /// Disconnect from a server.
  void disconnect(String serverId) {
    final client = _clients.remove(serverId);
    if (client != null) {
      client.onEvent = null;
      client.disconnect();
      LogService().log('IrcService: disconnected from $serverId');
      _flushServerWrites(serverId);
      _emitEvent(IrcEvent(IrcEventType.disconnected, serverId: serverId));
    }
    // Unregister background task
    _taskHandles.remove(serverId)?.dispose();
    if (_clients.isEmpty) {
      _stopWriteTimer();
    }
  }

  // ---------------------------------------------------------------------------
  // Chat operations
  // ---------------------------------------------------------------------------

  /// Join a channel on a server.
  void joinChannel(String serverId, String channel) {
    final normalized = channel.startsWith('#') ? channel : '#$channel';
    _clients[serverId]?.joinChannel(normalized);
  }

  /// Part a channel on a server.
  /// Sends PART to the server, then immediately cleans up local state
  /// (memory, cache, auto-join config) and emits channelLeft so the UI
  /// closes without waiting for the server echo.
  void partChannel(String serverId, String channel) {
    _clients[serverId]?.partChannel(channel);

    final key = '$serverId:$channel';

    // Remove from in-memory channels and messages immediately
    _channels.remove(key);
    _messages.remove(key);
    _typingUsers.remove(key);

    // Remove from SQLite cache
    _cacheService?.removeChannel(serverId, channel);

    // Remove from autoJoinChannels config so it doesn't rejoin on reconnect
    final config = _configs[serverId];
    if (config != null &&
        config.autoJoinChannels
            .any((c) => c.toLowerCase() == channel.toLowerCase())) {
      final updated = config.copyWith(
        autoJoinChannels: config.autoJoinChannels
            .where((c) => c.toLowerCase() != channel.toLowerCase())
            .toList(),
      );
      _configs[serverId] = updated;
      _saveConfigs();
    }

    // Emit channelLeft immediately so the chat page pops
    _emitEvent(IrcEvent(
      IrcEventType.channelLeft,
      serverId: serverId,
      data: channel,
    ));

    // Remove from Now feed
    EventBus().fire(NowGroupRemoveEvent(
      appType: 'irc',
      sourceId: key,
    ));

    LogService().log('IrcService: parted $channel on $serverId');
  }

  /// Mark a channel as read — resets unread count in memory and persists
  /// last_read_ts to SQLite so unreads survive app restart.
  void markChannelRead(String serverId, String channel) {
    final key = '$serverId:$channel';
    final ch = _channels[key];
    if (ch != null) {
      ch.unreadCount = 0;
    }
    _cacheService?.markChannelRead(serverId, channel);
  }

  /// Send a message to a channel or user.
  IrcMessage? sendMessage(String serverId, String target, String text) {
    final client = _clients[serverId];
    if (client == null || !client.isConnected) return null;

    client.sendMessage(target, text);

    // Determine message type
    IrcMessageType type = IrcMessageType.privmsg;
    String displayText = text;
    if (text.startsWith('/me ')) {
      type = IrcMessageType.action;
      displayText = text.substring(4);
    }

    // Create local echo
    final echo = IrcMessage(
      serverConfigId: serverId,
      channel: target,
      sender: client.currentNick,
      text: displayText,
      timestamp: DateTime.now().toUtc(),
      isOutgoing: true,
      type: type,
    );

    _addMessage(echo);
    // Flush immediately so the user's own messages are persisted right away
    _flushServerWrites(serverId);
    return echo;
  }

  /// Request channel list from a server.
  void requestChannelList(String serverId) {
    _clients[serverId]?.requestChannelList();
  }

  /// Change nickname on a server.
  void changeNick(String serverId, String newNick) {
    _clients[serverId]?.changeNick(newNick);
  }

  /// Set topic for a channel.
  void setTopic(String serverId, String channel, String topic) {
    _clients[serverId]?.setTopic(channel, topic);
  }

  /// Handle slash commands from compose bar.
  /// Returns true if handled, false if it should be sent as text.
  bool handleSlashCommand(String serverId, String channel, String input) {
    final parts = input.split(' ');
    final cmd = parts[0].toLowerCase();

    switch (cmd) {
      case '/join':
        if (parts.length >= 2) {
          joinChannel(serverId, parts[1]);
          return true;
        }
        return false;
      case '/part':
        partChannel(serverId, parts.length >= 2 ? parts[1] : channel);
        return true;
      case '/nick':
        if (parts.length >= 2) {
          changeNick(serverId, parts[1]);
          return true;
        }
        return false;
      case '/msg':
        if (parts.length >= 3) {
          final target = parts[1];
          final text = parts.sublist(2).join(' ');
          sendMessage(serverId, target, text);
          return true;
        }
        return false;
      case '/topic':
        if (parts.length >= 2) {
          setTopic(serverId, channel, parts.sublist(1).join(' '));
          return true;
        }
        return false;
      case '/me':
        // Not a slash command to intercept — send as /me action
        return false;
      default:
        return false;
    }
  }

  
  /// Send typing notification for a channel.
  void sendTyping(String serverId, String target, bool isTyping) {
    _clients[serverId]?.sendTyping(target, isTyping);
  }

// ---------------------------------------------------------------------------
  // Client event handling
  // ---------------------------------------------------------------------------

  void _handleClientEvent(String serverId, Map<String, dynamic> event) {
    final type = event['type'] as String?;

    switch (type) {
      case 'connected':
        _taskHandles[serverId]?.markRunning();
        _emitEvent(IrcEvent(IrcEventType.connected, serverId: serverId));
        // Rejoin cached channels after a short delay to let auto-join from
        // config complete first (avoid flooding the server with JOINs)
        Future.delayed(const Duration(seconds: 2), () {
          _rejoinCachedChannels(serverId);
        });
        break;

      case 'disconnected':
        _taskHandles[serverId]?.markIdle();
        _flushServerWrites(serverId);
        // Persist current channel state so it's available on next launch
        _saveChannelState(serverId);
        _emitEvent(IrcEvent(IrcEventType.disconnected, serverId: serverId));
        break;

      case 'privmsg':
        final sender = event['sender'] as String;
        final target = event['target'] as String;
        final text = event['text'] as String;
        final nick = _clients[serverId]?.currentNick ?? '';
        // If target is our nick, it's a PM — use sender as channel key
        final channel = target.toLowerCase() == nick.toLowerCase()
            ? sender
            : target;
        final msg = IrcMessage(
          serverConfigId: serverId,
          channel: channel,
          sender: sender,
          text: text,
          timestamp: DateTime.now().toUtc(),
          type: IrcMessageType.privmsg,
        );
        final typingKey = '$serverId:$channel';
        _typingUsers[typingKey]?.remove(sender);
        _addMessage(msg);
        break;

      case 'typing':
        final sender = event['sender'] as String;
        final target = event['target'] as String;
        final status = (event['status'] as String?) ?? 'active';
        final key = '$serverId:$target';
        final set = _typingUsers.putIfAbsent(key, () => <String>{});
        if (status == 'active') {
          set.add(sender);
        } else {
          set.remove(sender);
        }
        _emitEvent(IrcEvent(
          IrcEventType.typingUpdated,
          serverId: serverId,
          data: {'channel': target, 'users': set.toList()},
        ));
        _uiDirty = true;
        break;

      case 'notice':
        final sender = event['sender'] as String;
        final target = event['target'] as String;
        final text = event['text'] as String;
        final nick = _clients[serverId]?.currentNick ?? '';
        final channel = target.toLowerCase() == nick.toLowerCase()
            ? sender
            : target;
        // Only store notices to channels, skip server notices
        if (channel.startsWith('#') || channel.startsWith('&')) {
          final msg = IrcMessage(
            serverConfigId: serverId,
            channel: channel,
            sender: sender,
            text: text,
            timestamp: DateTime.now().toUtc(),
            type: IrcMessageType.notice,
          );
          _addMessage(msg);
        }
        break;

      case 'action':
        final sender = event['sender'] as String;
        final target = event['target'] as String;
        final text = event['text'] as String;
        final nick = _clients[serverId]?.currentNick ?? '';
        final channel = target.toLowerCase() == nick.toLowerCase()
            ? sender
            : target;
        final msg = IrcMessage(
          serverConfigId: serverId,
          channel: channel,
          sender: sender,
          text: text,
          timestamp: DateTime.now().toUtc(),
          type: IrcMessageType.action,
        );
        _addMessage(msg);
        break;

      case 'join':
        final nick = event['nick'] as String;
        final channel = event['channel'] as String;
        final key = '$serverId:$channel';
        final ch = _channels.putIfAbsent(
          key,
          () => IrcChannel(serverConfigId: serverId, name: channel),
        );
        if (!ch.users.contains(nick)) ch.users.add(nick);
        final myNick = _clients[serverId]?.currentNick ?? '';
        if (nick == myNick) {
          // Save channel to cache
          _cacheService?.saveChannel(serverId, ch);
          _emitEvent(IrcEvent(
            IrcEventType.channelJoined,
            serverId: serverId,
            data: channel,
          ));
          // Request names and topic
          _clients[serverId]?.requestNames(channel);
        }
        // Add system message
        final msg = IrcMessage(
          serverConfigId: serverId,
          channel: channel,
          sender: nick,
          text: '$nick has joined $channel',
          timestamp: DateTime.now().toUtc(),
          type: IrcMessageType.join,
        );
        _addMessage(msg);
        break;

      case 'part':
        final nick = event['nick'] as String;
        final channel = event['channel'] as String;
        final key = '$serverId:$channel';
        _channels[key]?.users.remove(nick);
        final myNick = _clients[serverId]?.currentNick ?? '';
        if (nick == myNick) {
          // partChannel() already cleaned up; this handles server-initiated
          // removals (kick echo, etc.) or if the PART wasn't triggered locally.
          if (_channels.containsKey(key)) {
            _channels.remove(key);
            _cacheService?.removeChannel(serverId, channel);
            _emitEvent(IrcEvent(
              IrcEventType.channelLeft,
              serverId: serverId,
              data: channel,
            ));
          }
        } else {
          final msg = IrcMessage(
            serverConfigId: serverId,
            channel: channel,
            sender: nick,
            text: '$nick has left $channel',
            timestamp: DateTime.now().toUtc(),
            type: IrcMessageType.part,
          );
          _addMessage(msg);
        }
        break;

      case 'quit':
        final nick = event['nick'] as String;
        // Remove from all channels for this server
        for (final ch in _channels.values) {
          if (ch.serverConfigId == serverId) {
            ch.users.remove(nick);
          }
        }
        _uiDirty = true;
        break;

      case 'topic':
        final channel = event['channel'] as String;
        final topic = event['topic'] as String;
        final key = '$serverId:$channel';
        final ch = _channels[key];
        if (ch != null) {
          ch.topic = topic;
          // Update cache with new topic
          _cacheService?.saveChannel(serverId, ch);
        }
        _emitEvent(IrcEvent(
          IrcEventType.topicChanged,
          serverId: serverId,
          data: {'channel': channel, 'topic': topic},
        ));
        break;

      case 'names':
        final channel = event['channel'] as String;
        final users = (event['users'] as List).cast<String>();
        final key = '$serverId:$channel';
        final ch = _channels.putIfAbsent(
          key,
          () => IrcChannel(serverConfigId: serverId, name: channel),
        );
        ch.users
          ..clear()
          ..addAll(users);
        _emitEvent(IrcEvent(
          IrcEventType.userListUpdated,
          serverId: serverId,
          data: channel,
        ));
        break;

      case 'channel_list':
        final channels = (event['channels'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _channelLists[serverId] = channels;
        _emitEvent(IrcEvent(
          IrcEventType.channelListReceived,
          serverId: serverId,
          data: channels,
        ));
        break;

      case 'nick_changed':
        _uiDirty = true;
        break;

      case 'kick':
        final channel = event['channel'] as String;
        final kicked = event['kicked'] as String;
        final myNick = _clients[serverId]?.currentNick ?? '';
        if (kicked == myNick) {
          final key = '$serverId:$channel';
          _channels.remove(key);
          _cacheService?.removeChannel(serverId, channel);
          _emitEvent(IrcEvent(
            IrcEventType.channelLeft,
            serverId: serverId,
            data: channel,
          ));
        }
        final msg = IrcMessage(
          serverConfigId: serverId,
          channel: channel,
          sender: event['kicker'] as String,
          text: '$kicked was kicked (${event['reason']})',
          timestamp: DateTime.now().toUtc(),
          type: IrcMessageType.system,
        );
        _addMessage(msg);
        break;

      case 'error':
        LogService().log('IrcService[$serverId]: ${event['message']}');
        _taskHandles[serverId]?.markError(event['message']);
        _emitEvent(IrcEvent(
          IrcEventType.error,
          serverId: serverId,
          data: event['message'],
        ));
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Message storage
  // ---------------------------------------------------------------------------

  void _addMessage(IrcMessage msg) {
    final key = '${msg.serverConfigId}:${msg.channel}';

    // In-memory list
    final list = _messages.putIfAbsent(key, () => []);
    list.add(msg);
    if (list.length > 5000) {
      list.removeRange(0, list.length - 5000);
    }

    // Prune system messages (join/part/quit) older than 12 hours
    final cutoff = DateTime.now().toUtc().subtract(_systemMessageMaxAge);
    list.removeWhere((m) => m.isSystemMessage && m.timestamp.isBefore(cutoff));

    // Update channel's last message
    final ch = _channels[key];
    if (ch != null) {
      ch.lastMessage = msg;
      if (!msg.isOutgoing && !msg.isSystemMessage) ch.unreadCount++;
    }

    // Queue for batch write to per-server DB
    if (!msg.isSystemMessage) {
      final queue = _writeQueues.putIfAbsent(msg.serverConfigId, () => []);
      queue.add(msg);
      if (queue.length >= _writeFlushThreshold) {
        _flushServerWrites(msg.serverConfigId);
      }
    }

    // Fire NowItemEvent for incoming user messages (not system, not outgoing)
    if (!msg.isSystemMessage && !msg.isOutgoing) {
      final config = _configs[msg.serverConfigId];
      final serverName = config?.name ?? msg.serverConfigId;
      EventBus().fire(NowItemEvent(
        id: 'irc:${msg.serverConfigId}:${msg.channel}:${msg.timestamp.millisecondsSinceEpoch}',
        appType: 'irc',
        sourceId: '${msg.serverConfigId}:${msg.channel}',
        sourceName: '${msg.channel} ($serverName)',
        callsign: msg.sender,
        summary: msg.type == IrcMessageType.action
            ? '* ${msg.sender} ${msg.text}'
            : msg.text,
        priority: NowPriority.chat,
      ));
    }

    _uiDirty = true;
  }

  /// Load cached messages for a channel from the server's SQLite DB.
  /// Merges with any live messages already in memory (dedup by timestamp).
  Future<void> loadCachedMessages(String serverId, String channel) async {
    if (_cacheService == null) return;
    final cached = await _cacheService!.loadMessages(serverId, channel);
    if (cached.isEmpty) return;
    final key = '$serverId:$channel';
    final list = _messages.putIfAbsent(key, () => []);
    if (list.isEmpty) {
      list.addAll(cached);
    } else {
      // Build a set of existing message keys to avoid duplicates
      final existing = <String>{};
      for (final m in list) {
        existing.add('${m.timestamp.millisecondsSinceEpoch}|${m.sender}|${m.channel}');
      }
      // Prepend cached messages that aren't already in memory
      final toAdd = <IrcMessage>[];
      for (final m in cached) {
        final key2 = '${m.timestamp.millisecondsSinceEpoch}|${m.sender}|${m.channel}';
        if (!existing.contains(key2)) {
          toAdd.add(m);
        }
      }
      if (toAdd.isNotEmpty) {
        list.insertAll(0, toAdd);
        // Re-sort by timestamp
        list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      }
    }
    _uiDirty = true;
  }

  /// Flush pending writes for a specific server.
  Future<void> _flushServerWrites(String serverId) async {
    final queue = _writeQueues[serverId];
    if (queue == null || queue.isEmpty || _cacheService == null) return;
    final batch = List<IrcMessage>.from(queue);
    queue.clear();
    try {
      await _cacheService!.cacheMessages(serverId, batch);
    } catch (e) {
      LogService().log('IrcService: flush error for $serverId: $e');
    }
  }

  /// Flush all pending writes across all servers.
  Future<void> _flushAllWrites() async {
    for (final serverId in _writeQueues.keys.toList()) {
      await _flushServerWrites(serverId);
    }
  }

  /// Public API — flush pending writes and save channel state.
  /// Called from app lifecycle handler to ensure data is persisted on exit.
  void flushWrites() {
    _flushAllWrites();
    for (final serverId in _clients.keys) {
      _saveChannelState(serverId);
    }
  }

  /// Persist current channel state for a server to its SQLite DB.
  void _saveChannelState(String serverId) {
    final channels = getChannels(serverId);
    if (channels.isNotEmpty) {
      _cacheService?.saveChannels(serverId, channels);
    }
  }

  // ---------------------------------------------------------------------------
  // UI throttle timer
  // ---------------------------------------------------------------------------

  /// Called by IRC UI pages in initState to start the UI refresh timer.
  void addUiObserver() {
    _uiObserverCount++;
    if (_uiObserverCount == 1) _startUiTimer();
  }

  /// Called by IRC UI pages in dispose to stop the UI refresh timer
  /// when no pages are visible.
  void removeUiObserver() {
    _uiObserverCount--;
    if (_uiObserverCount <= 0) {
      _uiObserverCount = 0;
      _stopUiTimer();
    }
  }

  void _startUiTimer() {
    _uiUpdateTimer ??= MonitoredPeriodicTimer(
      id: 'irc.ui_update',
      name: 'IRC UI Update',
      description: 'Throttled UI refresh for incoming IRC messages (500ms)',
      serviceName: 'IrcService',
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
      id: 'irc.write_flush',
      name: 'IRC Write Flush',
      description: 'Batches IRC message writes to SQLite (2s interval)',
      serviceName: 'IrcService',
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
      _eventController.add(const IrcEvent(IrcEventType.messageReceived));
    }
  }

  void _emitEvent(IrcEvent event) {
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
      final channels = getChannels(config.id);
      serverList.add({
        'id': config.id,
        'name': config.name,
        'host': '${config.host}:${config.port}',
        'tls': config.useTls,
        'connected': client?.isConnected ?? false,
        'nick': client?.currentNick ?? _getProfileNickname(),
        'channels': channels.map((ch) {
          final key = '${config.id}:${ch.name}';
          final msgCount = _messages[key]?.length ?? 0;
          return {
              'name': ch.name,
              'topic': ch.topic,
              'users': ch.users.length,
              'messagesInMemory': msgCount,
              'unread': ch.unreadCount,
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
      handle.dispose();
    }
    _taskHandles.clear();
    _cacheService?.dispose();
    _cacheService = null;
    _eventController.close();
  }
}
