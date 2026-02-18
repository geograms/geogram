/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * CLI Console Controller for Flutter UI.
 * Uses the shared CommandRegistry with BufferConsoleIO.
 */

import 'dart:async';

import 'dart:io' show Platform;

import '../cli/commands/command.dart';
import '../cli/commands/command_context.dart';
import '../cli/commands/command_registry.dart';
export '../cli/commands/command_registry.dart' show CompletionCandidate;
import '../cli/commands/general_commands.dart';
import '../cli/commands/station_command.dart';
import '../cli/commands/devices_command.dart';
import '../cli/commands/nip05_command.dart';
import '../cli/commands/chat_command.dart';
import '../cli/commands/profile_command.dart';
import '../cli/commands/config_command.dart';
import '../cli/commands/monitoring_commands.dart';
import '../cli/commands/games_command.dart';
import '../cli/commands/navigation_handler.dart';
import '../cli/commands/service_interfaces.dart';
import '../cli/console_io.dart';
import '../cli/console_io_buffer.dart';
import '../cli/game/game_config.dart';
import '../cli/game/game_engine_io.dart';
import '../models/profile.dart';
import '../models/chat_channel.dart';
import '../models/chat_message.dart';
import '../services/profile_service.dart';
import '../services/callsign_generator.dart';
import '../services/chat_service.dart';
import '../services/station_server_service.dart';
import '../services/station_service.dart';
import '../services/station_cache_service.dart';
import '../services/storage_config.dart';
import '../models/station_chat_room.dart';
import '../version.dart';

// ---------------------------------------------------------------------------
// Adapters — bridge Desktop services to command interfaces
// ---------------------------------------------------------------------------

/// Adapter for Desktop ProfileService to implement ProfileCommandInterface.
class _ProfileServiceAdapter implements ProfileCommandInterface {
  final ProfileService _service = ProfileService();

  @override
  List<ProfileReadable> get profilesReadable =>
      _service.getAllProfiles().cast<ProfileReadable>();

  @override
  ProfileReadable? get activeProfileReadable {
    final p = _service.getProfile();
    // Empty callsign means no real profile
    return p.callsign.isEmpty ? null : p;
  }

  @override
  ProfileReadable? getProfileByCallsign(String callsign) =>
      _service.getProfileByCallsign(callsign);

  @override
  Future<void> setActiveProfile(String profileId) async {
    await _service.switchToProfile(profileId);
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    await _service.deleteProfile(profileId);
  }

  @override
  Future<void> updateProfile(covariant Profile profile) async {
    await _service.updateProfile(
      nickname: profile.nickname,
      description: profile.description,
      profileImagePath: profile.profileImagePath,
      preferredColor: profile.preferredColor,
      latitude: profile.latitude,
      longitude: profile.longitude,
      locationName: profile.locationName,
    );
  }

  @override
  List<Map<String, dynamic>> getAllDevicesSorted() {
    final profiles = _service.getAllProfiles();
    final result = profiles.map((p) => <String, dynamic>{
      'callsign': p.callsign,
      'type': p.isRelay ? 'station' : 'client',
      'nickname': p.nickname,
      'owned': true,
      'active': p.id == _service.activeProfileId,
    }).toList();

    // Include all known stations (preferred + backup + available)
    try {
      for (final station in StationService().getAllStations()) {
        final cs = station.callsign;
        if (cs != null &&
            cs.isNotEmpty &&
            !result.any((d) => d['callsign'] == cs)) {
          result.add({
            'callsign': cs,
            'type': 'station',
            'nickname': station.name,
            'owned': false,
          });
        }
      }
    } catch (_) {} // StationService may not be initialized

    return result;
  }

  @override
  bool isOwnedCallsign(String callsign) {
    return _service.getAllProfiles().any(
      (p) => p.callsign.toLowerCase() == callsign.toLowerCase(),
    );
  }
}

/// Adapter for Desktop StationServerService to implement StationCommandInterface.
///
/// Operations that don't apply on Desktop throw [UnsupportedError] or return
/// sensible defaults (empty maps, empty lists).
class _StationServiceAdapter implements StationCommandInterface {
  final StationServerService _service = StationServerService();

  /// Pre-loaded chat rooms with messages (keyed by room id)
  final Map<String, _PreloadedRoom> _preloadedRooms = {};

  /// IDs of rooms that belong to the station (not local channels)
  final Set<String> _stationRoomIds = {};

  /// Load all chat rooms and their messages for sync access.
  Future<void> loadAllRooms() async {
    _preloadedRooms.clear();
    _stationRoomIds.clear();

    // Load local channels + messages from ChatService
    try {
      final chatService = ChatService();
      for (final ch in chatService.channels) {
        final messages = await chatService.loadMessages(ch.id, limit: 50);
        _preloadedRooms[ch.id] = _PreloadedRoom(
          adapter: _ChatChannelAdapter(ch, messages.map(_wrapChatMessage).toList()),
          isStation: false,
        );
      }
    } catch (_) {}

    // Load preferred station's cached rooms + messages
    try {
      final preferred = StationService().getPreferredStation();
      final cs = preferred?.callsign;
      if (cs != null && cs.isNotEmpty) {
        final rooms = await RelayCacheService().loadChatRooms(cs, preferred!.url);
        final cache = RelayCacheService();
        for (final room in rooms) {
          if (_preloadedRooms.containsKey(room.id)) continue;
          final stationMsgs = await cache.loadMessages(cs, room.id, limit: 50);
          _preloadedRooms[room.id] = _PreloadedRoom(
            adapter: _StationChatRoomAdapter(
              room,
              stationMsgs.map(_wrapStationMessage).toList(),
            ),
            isStation: true,
          );
          _stationRoomIds.add(room.id);
        }
      }
    } catch (_) {}
  }

  static _ChatMessageReadableAdapter _wrapChatMessage(ChatMessage m) =>
      _ChatMessageReadableAdapter(m);

  static _StationChatMessageAdapter _wrapStationMessage(StationChatMessage m) =>
      _StationChatMessageAdapter(m);

  @override
  bool get isRunning => _service.isRunning;

  @override
  int get connectedDevices => _service.connectedDevices;

  @override
  String? get dataDir => null; // Desktop doesn't expose this

  @override
  bool get quietMode => false;

  @override
  set quietMode(bool value) {} // no-op on Desktop

  @override
  StationSettingsReadable get settings => _SettingsAdapter(_service.settings);

  @override
  StationStatsReadable get stats => _StatsAdapter(_service);

  @override
  Map<String, ChatRoomReadable> get chatRoomsReadable {
    return {
      for (final entry in _preloadedRooms.entries)
        entry.key: entry.value.adapter,
    };
  }

  @override
  Map<String, ConnectedClientReadable> get clientsReadable => {};

  @override
  List<LogEntryReadable> get logsReadable => [];

  @override
  Future<bool> start() async => await _service.start();

  @override
  Future<void> stop() async => await _service.stop();

  @override
  Future<void> restart() async {
    await _service.stop();
    await Future.delayed(const Duration(milliseconds: 500));
    await _service.start();
  }

  @override
  Future<void> reloadSettings() async {} // no-op

  @override
  Future<void> updateSettings(covariant Object settings) async {
    if (settings is StationServerSettings) {
      await _service.updateSettings(settings);
    }
  }

  @override
  Map<String, dynamic> getStatus() => _service.getStatus();

  @override
  void setSetting(String key, dynamic value) {
    final s = _service.settings;
    switch (key) {
      case 'httpPort':
        final updated = s.copyWith(port: value as int);
        _service.updateSettings(updated);
        break;
      default:
        // Many settings are not applicable on Desktop
        break;
    }
  }

  @override
  void clearCache() => _service.clearCache();

  @override
  bool kickDevice(String callsign) => false;

  @override
  void broadcast(String message) {}

  @override
  Future<List<Map<String, dynamic>>> scanNetwork({int timeout = 2000}) async => [];

  @override
  Future<Map<String, dynamic>?> pingDevice(String address) async => null;

  @override
  ChatRoomReadable? createChatRoom(String id, String name, {String? description}) {
    try {
      final channel = ChatChannel.group(
        id: id,
        name: name,
        participants: ['*'], // public by default
        description: description,
      );
      ChatService().createChannel(channel);
      return _ChatChannelAdapter(channel);
    } catch (_) {
      return null;
    }
  }

  @override
  bool deleteChatRoom(String id) {
    try {
      ChatService().deleteChannel(id);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  bool renameChatRoom(String oldId, String newName) {
    try {
      final channel = ChatService().getChannel(oldId);
      if (channel == null) return false;
      ChatService().updateChannel(channel.copyWith(name: newName));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> postMessage(String roomId, String content) async {
    final profile = ProfileService().getProfile();

    // Check if this is a station room (not a local channel)
    if (_stationRoomIds.contains(roomId)) {
      final preferred = StationService().getPreferredStation();
      if (preferred != null) {
        await StationService().postRoomMessage(
          preferred.url,
          roomId,
          profile.callsign,
          content,
        );
        return;
      }
    }

    // Local channel — save directly
    final message = ChatMessage.now(
      author: profile.callsign,
      content: content,
    );
    await ChatService().saveMessage(roomId, message);
  }

  @override
  bool deleteMessage(String roomId, String messageId) => false;

  @override
  bool verifyMessage(covariant Object message) => false;

  @override
  List<LogEntryReadable> getLogs({int limit = 20}) => [];
}

/// Read-only view over StationServerSettings.
class _SettingsAdapter implements StationSettingsReadable {
  final StationServerSettings _s;
  _SettingsAdapter(this._s);

  @override String get callsign {
    // Check if active profile is itself a station
    final profile = ProfileService().getProfile();
    if (CallsignGenerator.isStationCallsign(profile.callsign)) {
      return profile.callsign;
    }
    // Get preferred station's callsign
    try {
      final preferred = StationService().getPreferredStation();
      final cs = preferred?.callsign ?? '';
      if (cs.isNotEmpty && CallsignGenerator.isStationCallsign(cs)) return cs;
    } catch (_) {}
    // Fallback to StationServerService
    final status = StationServerService().getStatus();
    final cs = status['callsign'] as String? ?? '';
    return CallsignGenerator.isStationCallsign(cs) ? cs : '';
  }
  @override String get npub => '';
  @override int get httpPort => _s.port;
  @override int get httpsPort => _s.port + 363; // approximate
  @override String? get description => null;
  @override String? get location => null;
  @override double? get latitude => null;
  @override double? get longitude => null;
  @override bool get tileServerEnabled => _s.tileServerEnabled;
  @override bool get osmFallbackEnabled => _s.osmFallbackEnabled;
  @override int get maxZoomLevel => _s.maxZoomLevel;
  @override int get maxCacheSizeMB => _s.maxCacheSize;
  @override bool get enableAprs => false;
  @override bool get enableCors => true;
  @override int get maxConnectedDevices => 100;
  @override String? get sslDomain => null;
  @override String? get sslEmail => null;
  @override bool get sslAutoRenew => false;
  @override bool get enableSsl => false;
  @override String? get sslCertPath => null;
  @override String? get sslKeyPath => null;
}

/// Read-only view over station stats via service.
class _StatsAdapter implements StationStatsReadable {
  final StationServerService _service;
  _StatsAdapter(this._service);

  Map<String, dynamic> get _status => _service.getStatus();

  @override int get totalConnections => _status['total_connections'] as int? ?? 0;
  @override int get totalMessages => _status['total_messages'] as int? ?? 0;
  @override int get totalApiRequests => _status['total_api_requests'] as int? ?? 0;
  @override int get totalTileRequests => _status['total_tile_requests'] as int? ?? 0;
  @override int get tilesCached => 0;
  @override int get tilesServedFromCache => 0;
  @override int get tilesDownloaded => 0;
  @override DateTime? get lastConnection => null;
  @override DateTime? get lastMessage => null;
  @override DateTime? get lastTileRequest => null;
}

/// Helper to hold a room adapter + its origin.
class _PreloadedRoom {
  final ChatRoomReadable adapter;
  final bool isStation;
  _PreloadedRoom({required this.adapter, required this.isStation});
}

/// Adapter wrapping [ChatChannel] as [ChatRoomReadable] for navigation.
class _ChatChannelAdapter implements ChatRoomReadable {
  final ChatChannel _ch;
  final List<ChatMessageReadable> _messages;
  _ChatChannelAdapter(this._ch, [this._messages = const []]);

  @override String get id => _ch.id;
  @override String get name => _ch.name;
  @override String get description => _ch.description ?? '';
  @override String get creatorCallsign => '';
  @override DateTime get createdAt => _ch.created;
  @override DateTime get lastActivity => _ch.lastMessageTime ?? _ch.created;
  @override bool get isPublic => _ch.participants.contains('*');
  @override List<ChatMessageReadable> get readableMessages => _messages;
}

/// Adapter wrapping [StationChatRoom] as [ChatRoomReadable] for navigation.
class _StationChatRoomAdapter implements ChatRoomReadable {
  final StationChatRoom _room;
  final List<ChatMessageReadable> _messages;
  _StationChatRoomAdapter(this._room, [this._messages = const []]);

  @override String get id => _room.id;
  @override String get name => _room.name;
  @override String get description => _room.description;
  @override String get creatorCallsign => '';
  @override DateTime get createdAt => DateTime.now();
  @override DateTime get lastActivity =>
      _messages.isNotEmpty ? _messages.last.timestamp : DateTime.now();
  @override bool get isPublic => true;
  @override List<ChatMessageReadable> get readableMessages => _messages;
}

/// Adapter wrapping [ChatMessage] as [ChatMessageReadable].
class _ChatMessageReadableAdapter implements ChatMessageReadable {
  final ChatMessage _m;
  _ChatMessageReadableAdapter(this._m);

  @override String get id => _m.timestamp;
  @override String get roomId => '';
  @override String get senderCallsign => _m.author;
  @override String? get senderNpub => _m.metadata['npub'];
  @override String? get signature => _m.metadata['signature'];
  @override String get content => _m.content;
  @override DateTime get timestamp => _m.dateTime;
  @override bool get verified => _m.metadata.containsKey('signature');
  @override bool get hasSignature => _m.metadata.containsKey('signature');
}

/// Adapter wrapping [StationChatMessage] as [ChatMessageReadable].
class _StationChatMessageAdapter implements ChatMessageReadable {
  final StationChatMessage _m;
  _StationChatMessageAdapter(this._m);

  @override String get id => _m.timestamp;
  @override String get roomId => _m.roomId;
  @override String get senderCallsign => _m.callsign;
  @override String? get senderNpub => _m.npub;
  @override String? get signature => _m.signature;
  @override String get content => _m.content;
  @override DateTime get timestamp => _m.dateTime ?? DateTime.now();
  @override bool get verified => _m.verified;
  @override bool get hasSignature => _m.hasSignature;
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// CLI Console Controller for Flutter UI.
///
/// Uses the shared [CommandRegistry] with [BufferConsoleIO] for output.
/// Navigation (cd/ls/pwd) is delegated to the shared [NavigationHandler].
class CliConsoleController {
  late final CommandRegistry _registry;
  late final BufferConsoleIO _io;
  late final _ProfileServiceAdapter _profileAdapter;
  late final _StationServiceAdapter _stationAdapter;
  late final NavigationHandler _nav;
  GameConfig? _gameConfig;

  /// Root directories in virtual filesystem
  List<String> get rootDirs {
    final dirs = ['profiles', 'chat', 'devices', 'config', 'logs'];
    if (_stationAdapter.isRunning) dirs.add('station');
    if (_gameConfig != null) dirs.add('games');
    dirs.sort();
    return dirs;
  }

  /// Whether we're currently in game mode
  bool _inGame = false;

  /// Completer for game input
  Completer<String?>? _inputCompleter;

  /// Current game engine (if running)
  GameEngineIO? _currentGame;

  /// Callback for when game output is available
  void Function(String output)? onGameOutput;

  /// Detect the current platform environment.
  static CommandEnvironment _detectEnvironment() {
    if (Platform.isLinux) return CommandEnvironment.linux;
    if (Platform.isWindows) return CommandEnvironment.windows;
    if (Platform.isMacOS) return CommandEnvironment.macOS;
    if (Platform.isAndroid) return CommandEnvironment.android;
    if (Platform.isIOS) return CommandEnvironment.iOS;
    return CommandEnvironment.linux;
  }

  CliConsoleController() {
    _io = BufferConsoleIO();
    _profileAdapter = _ProfileServiceAdapter();
    _stationAdapter = _StationServiceAdapter();
    _registry = CommandRegistry(environment: _detectEnvironment());
    _nav = NavigationHandler(_DesktopDataProvider(this));
    _registerCommands();
    _nav.isKnownCommand = _registry.isKnownCommand;
  }

  void _registerCommands() {
    _registry.registerAll([
      HelpCommand(_registry),
      ClearCommand(),
      QuitCommand(),
      BroadcastCommand(),
      KickCommand(),
      QuietCommand(),
      VerboseCommand(),
      RestartCommand(),
      ReloadCommand(),
      SetupCommand(),
      StatusCommand(),
      StatsCommand(),
      StationCommand(),
      DevicesCommand(),
      Nip05Command(),
      ChatCommand(),
      ProfileCommand(),
      ConfigCommand(),
      LogsCommand(),
      TailCommand(),
      HeadCommand(),
      CatCommand(),
      DfCommand(),
      TopCommand(),
      GamesCommand(),
      PlayCommand(),
    ]);
  }

  /// Build a [CommandContext] for dispatching commands.
  CommandContext _buildContext({List<String> args = const []}) {
    return CommandContext(
      io: _io,
      currentPath: _nav.currentPath,
      currentChatStation: _nav.currentChatStation,
      currentChatRoom: _nav.currentChatRoom,
      args: args,
      station: _stationAdapter,
      profileService: _profileAdapter,
      sslManager: null, // SSL not available on Desktop
      gameConfig: _gameConfig,
      onNavigate: (path, chatStation, chatRoom) {
        // Navigation via commands — not typical but kept for compatibility
      },
    );
  }

  /// Initialize (loads games if available, pre-loads station rooms)
  Future<void> initialize() async {
    if (!StorageConfig().isInitialized) return;

    try {
      _gameConfig = GameConfig();
      final consoleDir = '${StorageConfig().baseDir}/console';
      await _gameConfig!.initialize(consoleDir);
    } catch (e) {
      _gameConfig = null;
    }

    // Pre-load all chat rooms with messages
    await _stationAdapter.loadAllRooms();
  }

  /// Whether we're currently in game mode
  bool get inGame => _inGame;

  /// Get current path
  String get currentPath => _nav.currentPath;

  /// Get prompt string
  String getPrompt() {
    if (_inGame) return '';
    return 'geogram:${_nav.currentPath}\$ ';
  }

  /// Get welcome banner
  String getBanner() {
    final profile = _profileAdapter.activeProfileReadable;
    final callsign = profile?.callsign ?? 'unknown';
    final isStation = profile?.isRelay == true;

    final buf = StringBuffer();
    buf.writeln();
    buf.writeln('=' * 50);
    buf.writeln('  Geogram v$appVersion - Console');
    buf.writeln('  Active Profile: $callsign${isStation ? ' (Relay)' : ''}');
    buf.writeln('=' * 50);
    buf.writeln();
    buf.writeln('Type "help" for available commands.');
    buf.writeln();
    return buf.toString();
  }

  /// Get TAB completions for the given input.
  ///
  /// Returns a [CompletionResult] compatible with the terminal page.
  CompletionResult getCompletions(String input) {
    final ctx = _buildContext();
    final candidates = _registry.getCompletions(input, ctx);

    // Also add navigation commands (ls, cd, pwd) + path completions
    final navCandidates = _getNavigationCompletions(input);
    final allCandidates = [...navCandidates, ...candidates];

    if (allCandidates.isEmpty) return CompletionResult();

    // Convert CompletionCandidate → Candidate-like for the page
    if (allCandidates.length == 1) {
      final c = allCandidates.first;
      final parts = input.split(RegExp(r'\s+'));
      if (parts.isEmpty) {
        return CompletionResult(
          completedText: c.value,
          exactMatch: true,
        );
      }
      parts[parts.length - 1] = c.value;
      final completed = '${parts.join(' ')} ';
      return CompletionResult(completedText: completed, exactMatch: true);
    }

    // Multiple matches — find common prefix
    final values = allCandidates.map((c) => c.value).toList();
    final commonPrefix = _findCommonPrefix(values);
    final parts = input.split(RegExp(r'\s+'));
    final lastPart = parts.isNotEmpty ? parts.last : '';

    String? completedText;
    if (commonPrefix.length > lastPart.length) {
      parts[parts.length - 1] = commonPrefix;
      completedText = parts.join(' ');
    }

    return CompletionResult(
      completedText: completedText,
      candidates: allCandidates,
    );
  }

  /// Get navigation-specific completions (ls, cd, pwd, path args).
  List<CompletionCandidate> _getNavigationCompletions(String input) {
    final parts = input.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final endsWithSpace = input.endsWith(' ');

    // Completing command name — add nav commands
    if (parts.isEmpty || (parts.length == 1 && !endsWithSpace)) {
      final partial = parts.isEmpty ? '' : parts[0].toLowerCase();
      final navCmds = ['ls', 'cd', 'pwd'];
      return navCmds
          .where((c) => c.startsWith(partial))
          .map((c) => CompletionCandidate(c, group: 'Navigation'))
          .toList();
    }

    // Completing arguments for ls/cd
    final cmd = parts[0].toLowerCase();
    if ((cmd == 'ls' || cmd == 'cd') && (parts.length == 1 && endsWithSpace || parts.length == 2 && !endsWithSpace)) {
      final partial = parts.length > 1 ? parts[1] : '';
      return _completePaths(partial);
    }

    return [];
  }

  List<CompletionCandidate> _completePaths(String partial) {
    final candidates = <CompletionCandidate>[];
    final lowerPartial = partial.toLowerCase();

    if ('..'.startsWith(lowerPartial) && _nav.currentPath != '/') {
      candidates.add(CompletionCandidate('..', group: 'path'));
    }

    if (partial.isEmpty || partial == '/') {
      for (final entry in _nav.getChildEntries('')) {
        candidates.add(CompletionCandidate(entry, description: 'directory', group: 'path'));
      }
      return candidates;
    }

    // Absolute path completion
    if (partial.startsWith('/')) {
      final pathParts = partial.substring(1).split('/');
      if (pathParts.length == 1) {
        final basePartial = pathParts[0].toLowerCase();
        for (final dir in rootDirs) {
          if (dir.toLowerCase().startsWith(basePartial)) {
            candidates.add(CompletionCandidate('/$dir', description: 'directory', group: 'path'));
          }
        }
      } else {
        final parentPath = '/${pathParts.sublist(0, pathParts.length - 1).join('/')}';
        final childPartial = pathParts.last.toLowerCase();
        for (final entry in _nav.getChildEntries(parentPath)) {
          if (entry.toLowerCase().startsWith(childPartial)) {
            candidates.add(CompletionCandidate('$parentPath/$entry', description: 'path', group: 'path'));
          }
        }
      }
      return candidates;
    }

    // Relative path completion
    final children = _nav.getChildEntries('');
    for (final entry in children) {
      if (entry.toLowerCase().startsWith(lowerPartial)) {
        candidates.add(CompletionCandidate(entry, description: 'directory', group: 'path'));
      }
    }

    return candidates;
  }

  /// Process a command and return the output.
  Future<String> processCommand(String input) async {
    // If in game mode, send input to game
    if (_inGame && _inputCompleter != null) {
      _inputCompleter!.complete(input);
      _inputCompleter = null;
      return '';
    }

    _io.clearOutput();

    final trimmed = input.trim();
    if (trimmed.isEmpty) return '';

    // Try to send as a chat message if inside a chat room
    if (await _nav.trySendChatMessage(trimmed)) {
      return _io.getOutput() ?? '';
    }

    final parts = trimmed.split(RegExp(r'\s+'));
    final command = parts[0].toLowerCase();
    final args = parts.length > 1 ? parts.sublist(1) : <String>[];

    // Handle navigation commands via shared handler
    if (command == 'ls') {
      if (_nav.isInChatRoom && args.isEmpty) {
        _showChatHistory();
      } else {
        _nav.handleLs(args);
      }
      return _io.getOutput() ?? '';
    }
    if (command == 'cd') {
      final entered = await _nav.handleCd(args);
      if (entered && _nav.isInChatRoom) {
        _showChatHistory(limit: 10);
      }
      return _io.getOutput() ?? '';
    }
    if (command == 'pwd') {
      _nav.handlePwd();
      return _io.getOutput() ?? '';
    }

    // Dispatch via registry
    final ctx = _buildContext(args: args);
    final result = await _registry.dispatch(command, args, ctx);

    switch (result) {
      case DispatchResult.ok:
      case DispatchResult.exit:
        break;
      case DispatchResult.notFound:
        _io.writeln('\x1B[31mUnknown command: $command\x1B[0m');
        _io.writeln('Type "help" for available commands.');
        break;
      case DispatchResult.requiresStation:
        _io.writeln('\x1B[33mStation not running. Start with "station start".\x1B[0m');
        break;
    }

    return _io.getOutput() ?? '';
  }

  // -------------------------------------------------------------------------
  // Chat history rendering
  // -------------------------------------------------------------------------

  /// Render chat messages for the current room.
  void _showChatHistory({int? limit}) {
    final roomId = _nav.currentChatRoom;
    if (roomId == null) return;

    final room = _stationAdapter.chatRoomsReadable[roomId];
    if (room == null) return;

    final messages = room.readableMessages;
    if (messages.isEmpty) {
      _io.writeln('(no messages)');
      return;
    }

    final count = limit ?? 20;
    final start = messages.length > count ? messages.length - count : 0;
    for (var i = start; i < messages.length; i++) {
      final m = messages[i];
      final ts = m.timestamp.toLocal();
      final timeStr = '${ts.year}-${ts.month.toString().padLeft(2, '0')}-'
          '${ts.day.toString().padLeft(2, '0')} '
          '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
      final sigIcon = m.hasSignature
          ? (m.verified ? '\x1B[32m\u2713\x1B[0m' : '\x1B[31m\u2717\x1B[0m')
          : '\x1B[90m\u25CB\x1B[0m';
      _io.writeln('\x1B[33m[$timeStr]\x1B[0m $sigIcon \x1B[36m${m.senderCallsign}:\x1B[0m ${m.content}');
    }
  }

  // -------------------------------------------------------------------------
  // Game support
  // -------------------------------------------------------------------------

  void quitGame() {
    if (_inGame && _currentGame != null) {
      _currentGame!.stop();
      if (_inputCompleter != null && !_inputCompleter!.isCompleted) {
        _inputCompleter!.complete(null);
        _inputCompleter = null;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  String _findCommonPrefix(List<String> strings) {
    if (strings.isEmpty) return '';
    if (strings.length == 1) return strings.first;
    var prefix = strings.first;
    for (var i = 1; i < strings.length; i++) {
      while (!strings[i].toLowerCase().startsWith(prefix.toLowerCase())) {
        prefix = prefix.substring(0, prefix.length - 1);
        if (prefix.isEmpty) return '';
      }
    }
    return prefix;
  }
}

// ---------------------------------------------------------------------------
// NavigationDataProvider implementation for Desktop
// ---------------------------------------------------------------------------

class _DesktopDataProvider implements NavigationDataProvider {
  final CliConsoleController _controller;
  _DesktopDataProvider(this._controller);

  @override
  ConsoleIO get io => _controller._io;

  @override
  List<String> get rootDirs => _controller.rootDirs;

  @override
  StationCommandInterface? get stationInterface => _controller._stationAdapter;

  @override
  ProfileCommandInterface? get profileInterface => _controller._profileAdapter;

  @override
  Object? get gameConfig => _controller._gameConfig;

  @override
  Object? get sslManager => null; // SSL not available on Desktop
}

// ---------------------------------------------------------------------------
// CompletionResult — kept for backward compatibility with console_terminal_page
// ---------------------------------------------------------------------------

/// Result of a completion operation.
class CompletionResult {
  final String? completedText;
  final List<CompletionCandidate> candidates;
  final bool exactMatch;

  CompletionResult({
    this.completedText,
    this.candidates = const [],
    this.exactMatch = false,
  });
}
