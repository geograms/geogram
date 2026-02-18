/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared navigation handler for virtual filesystem (cd/ls/pwd).
 * Used by both CLI (PureConsole) and Desktop (CliConsoleController).
 *
 * The /chat directory uses a station hierarchy:
 *   /chat/<station>/<room>
 */

import '../console_io.dart';
import 'service_interfaces.dart';
import '../../services/callsign_generator.dart';

// ---------------------------------------------------------------------------
// NavigationDataProvider — abstract interface for host console data
// ---------------------------------------------------------------------------

/// Data provider that the host console implements to supply
/// platform-specific data to the shared [NavigationHandler].
abstract class NavigationDataProvider {
  /// Platform-agnostic I/O for writing output.
  ConsoleIO get io;

  /// Root directory names available in the virtual filesystem.
  List<String> get rootDirs;

  /// Station command interface (may be null if no station running).
  StationCommandInterface? get stationInterface;

  /// Profile command interface.
  ProfileCommandInterface? get profileInterface;

  /// Game configuration (GameConfig or null).
  Object? get gameConfig;

  /// SSL certificate manager (SslCertificateManager or null).
  Object? get sslManager;

  /// Local chat rooms that belong to the profile, not to any station.
  ///
  /// These are shown at `/chat/<roomId>` level alongside station callsigns.
  /// Default is empty (CLI stations don't have separate local rooms).
  Map<String, ChatRoomReadable> get localChatRooms => {};
}

// ---------------------------------------------------------------------------
// NavigationHandler — shared navigation state + logic
// ---------------------------------------------------------------------------

/// Owns all virtual-filesystem navigation state and logic.
///
/// Both PureConsole (CLI) and CliConsoleController (Desktop) delegate
/// `ls`, `cd`, and `pwd` to this handler.
class NavigationHandler {
  final NavigationDataProvider _provider;

  String _currentPath = '/';
  String? _currentChatStation; // station callsign in /chat/<station>
  String? _currentChatRoom; // room ID in /chat/<station>/<room>

  NavigationHandler(this._provider);

  // --- Public getters ---

  String get currentPath => _currentPath;
  String? get currentChatStation => _currentChatStation;
  String? get currentChatRoom => _currentChatRoom;

  /// Whether we are fully inside a chat room (station + room are set).
  bool get isInChatRoom => _currentChatStation != null && _currentChatRoom != null;

  ConsoleIO get _io => _provider.io;
  StationCommandInterface? get _station => _provider.stationInterface;

  /// Optional command checker — set by the host console so that
  /// [trySendChatMessage] can distinguish chat text from commands.
  IsKnownCommandFn? isKnownCommand;

  // --- Chat message interception ---

  /// Try to send [input] as a chat message when inside a chat room.
  ///
  /// Returns `true` if the input was handled (sent as a message or rejected).
  /// Returns `false` if the input should be processed as a command.
  Future<bool> trySendChatMessage(String input) async {
    if (!isInChatRoom) return false;
    if (input.startsWith('/')) return false;

    // Check if the first word is a known command
    final firstWord = input.split(' ').first.toLowerCase();
    const navCommands = ['ls', 'cd', 'pwd'];
    if (navCommands.contains(firstWord)) return false;
    if (isKnownCommand != null && isKnownCommand!(firstWord)) return false;

    final station = _station;
    if (station == null) return false;

    final roomId = _currentChatRoom!;
    final hasRoom = station.chatRoomsReadable.containsKey(roomId) ||
        _provider.localChatRooms.containsKey(roomId);
    if (!hasRoom) {
      _io.writeln('\x1B[31mRoom not found: $roomId\x1B[0m');
      return true;
    }

    await station.postMessage(roomId, input);

    // Format confirmation (IRC-style)
    final now = DateTime.now();
    final timeStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final callsign = _provider.profileInterface?.activeProfileReadable?.callsign ?? 'You';
    _io.writeln('\x1B[33m[$timeStr]\x1B[0m \x1B[32m✓\x1B[0m \x1B[36m$callsign:\x1B[0m $input');
    return true;
  }

  // --- Core navigation ---

  /// Handle `pwd` — print working directory.
  void handlePwd() {
    _io.writeln(_currentPath);
  }

  /// Handle `cd [path]` — change directory.
  ///
  /// Returns `true` when entering a chat room so the host can show
  /// the room header / last messages.
  Future<bool> handleCd(List<String> args) async {
    if (args.isEmpty) {
      _currentPath = '/';
      _currentChatStation = null;
      _currentChatRoom = null;
      return false;
    }

    final target = resolvePath(args[0]);

    if (!_isValidPath(target)) {
      _io.writeln('\x1B[31mDirectory not found: ${args[0]}\x1B[0m');
      return false;
    }

    _currentPath = target;
    _deriveChatContext(target);

    // When entering a room, signal to the host
    if (isInChatRoom) {
      final roomId = _currentChatRoom!;
      // Check local rooms first, then station rooms
      final localRoom = _provider.localChatRooms[roomId];
      final stationRoom = _station?.chatRoomsReadable[roomId];
      final room = localRoom ?? stationRoom;
      if (room != null) {
        _io.writeln('--- ${room.name} ---');
        return true; // host should show last messages
      } else {
        _io.writeln('\x1B[31mRoom not found: $roomId\x1B[0m');
        _currentPath = _isFlatRoomMode ? '/chat' : '/chat/$_currentChatStation';
        _currentChatRoom = null;
        return false;
      }
    }

    return false;
  }

  /// Handle `ls [path]`.
  void handleLs(List<String> args) {
    final path = args.isNotEmpty ? resolvePath(args[0]) : _currentPath;
    _listPath(path);
  }

  // --- Path utilities (public for tab completion) ---

  /// Resolve a user-supplied path (relative or absolute) against [_currentPath].
  String resolvePath(String path) {
    if (path.startsWith('/')) return _normalizePath(path);

    if (path == '..') {
      final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
      if (parts.isEmpty) return '/';
      parts.removeLast();
      return parts.isEmpty ? '/' : '/${parts.join('/')}';
    }

    if (path == '.') return _currentPath;

    final newPath = _currentPath == '/' ? '/$path' : '$_currentPath/$path';
    return _normalizePath(newPath);
  }

  /// Return child entries for a given path (for tab completion).
  List<String> getChildEntries(String path) {
    final resolved = path.isEmpty ? _currentPath : resolvePath(path);
    final entries = <String>[];

    if (resolved == '/') {
      entries.addAll(_provider.rootDirs);
    } else if (resolved == '/chat') {
      if (_isFlatRoomMode) {
        // Flat mode: list rooms directly
        final station = _station;
        if (station != null) {
          entries.addAll(station.chatRoomsReadable.keys);
        }
      } else {
        // Local rooms + station callsigns
        entries.addAll(_provider.localChatRooms.keys);
        entries.addAll(_getStationCallsigns());
      }
    } else if (resolved.startsWith('/chat/')) {
      final segments = resolved.substring(1).split('/');
      if (segments.length == 2 && !_isFlatRoomMode) {
        // /chat/<station> — list rooms if local
        final stationCs = segments[1];
        if (_isLocalStation(stationCs)) {
          final station = _station;
          if (station != null) {
            entries.addAll(station.chatRoomsReadable.keys);
          }
        }
      }
    } else if (resolved == '/devices') {
      final profile = _provider.profileInterface;
      if (profile != null) {
        for (final d in profile.getAllDevicesSorted()) {
          entries.add(d['callsign'] as String);
        }
      }
    }

    return entries;
  }

  // --- Private: listing ---

  void _listPath(String path) {
    if (path == '/') {
      for (final dir in _provider.rootDirs) {
        _io.writeln('\x1B[34m$dir/\x1B[0m');
      }
      return;
    }

    if (path == '/chat') {
      _listChatStations();
      return;
    }

    if (path.startsWith('/chat/')) {
      _listChatSubPath(path);
      return;
    }

    if (path == '/station') {
      _listStation();
      return;
    }

    if (path == '/devices') {
      _listDevices();
      return;
    }

    if (path == '/config') {
      _listConfig();
      return;
    }

    if (path == '/logs') {
      _listLogs();
      return;
    }

    if (path == '/ssl') {
      _listSsl();
      return;
    }

    if (path == '/games') {
      _listGames();
      return;
    }

    if (path == '/profiles') {
      _listProfiles();
      return;
    }

    _io.writeln('\x1B[31mDirectory not found: $path\x1B[0m');
  }

  /// `ls /chat` — list known stations.
  ///
  /// If station callsigns are found, show the station hierarchy.
  /// If none are found but chat rooms exist, list rooms directly (flat).
  void _listChatStations() {
    final stations = _getStationCallsigns();
    final localRooms = _provider.localChatRooms;

    if (stations.isNotEmpty) {
      // Show local rooms first (profile's own channels)
      for (final room in localRooms.values) {
        _io.writeln('\x1B[34m${room.id}/\x1B[0m  ${room.name}');
      }
      // Then station callsigns
      for (final cs in stations) {
        final local = _isLocalStation(cs);
        final suffix = local ? '' : '  \x1B[90m(remote)\x1B[0m';
        _io.writeln('\x1B[34m$cs/\x1B[0m$suffix');
      }
      return;
    }

    // Fallback: no station callsigns discovered, but we may still
    // have chat rooms (e.g. client profile connected to a station).
    // List rooms directly at /chat level for backward compat.
    final station = _station;
    if (station != null) {
      final rooms = station.chatRoomsReadable;
      if (rooms.isNotEmpty) {
        for (final room in rooms.values) {
          _io.writeln('\x1B[34m${room.id}/\x1B[0m  ${room.name}');
        }
        return;
      }
    }

    if (localRooms.isNotEmpty) {
      for (final room in localRooms.values) {
        _io.writeln('\x1B[34m${room.id}/\x1B[0m  ${room.name}');
      }
      return;
    }

    _io.writeln('(no stations)');
  }

  /// `ls /chat/<station>` or `ls /chat/<station>/<room>`.
  /// Also handles flat-room mode: `ls /chat/<room>`.
  void _listChatSubPath(String path) {
    final segments = path.substring(1).split('/'); // ['chat', station, ?room]
    final secondSegment = segments.length > 1 ? segments[1] : null;
    if (secondSegment == null) return;

    // Check if this is a local room at /chat/<roomId>
    final localRooms = _provider.localChatRooms;
    if (localRooms.containsKey(secondSegment)) {
      final room = localRooms[secondSegment]!;
      _io.writeln('${room.readableMessages.length} messages');
      if (room.readableMessages.isNotEmpty) {
        final lastMsg = room.readableMessages.last;
        _io.writeln('Last activity: ${lastMsg.timestamp.toLocal()}');
      }
      return;
    }

    // Check if we're in flat-room mode (second segment is a room, not station)
    if (_isFlatRoomMode) {
      final station = _station;
      if (station != null) {
        final room = station.chatRoomsReadable[secondSegment];
        if (room != null) {
          _io.writeln('${room.readableMessages.length} messages');
          if (room.readableMessages.isNotEmpty) {
            final lastMsg = room.readableMessages.last;
            _io.writeln('Last activity: ${lastMsg.timestamp.toLocal()}');
          }
          return;
        }
      }
      _io.writeln('\x1B[31mRoom not found\x1B[0m');
      return;
    }

    // Station hierarchy mode
    final stationCs = secondSegment;
    final roomId = segments.length > 2 ? segments[2] : null;

    if (roomId != null) {
      // ls /chat/<station>/<room> — show room metadata
      final station = _station;
      if (station != null && _isLocalStation(stationCs)) {
        final room = station.chatRoomsReadable[roomId];
        if (room != null) {
          _io.writeln('${room.readableMessages.length} messages');
          if (room.readableMessages.isNotEmpty) {
            final lastMsg = room.readableMessages.last;
            _io.writeln('Last activity: ${lastMsg.timestamp.toLocal()}');
          }
        } else {
          _io.writeln('\x1B[31mRoom not found\x1B[0m');
        }
      } else {
        _io.writeln('\x1B[33m(remote — rooms not available yet)\x1B[0m');
      }
      return;
    }

    // ls /chat/<station> — list rooms
    if (_isLocalStation(stationCs)) {
      final station = _station;
      if (station != null) {
        final rooms = station.chatRoomsReadable;
        if (rooms.isEmpty) {
          _io.writeln('(no rooms)');
        } else {
          for (final room in rooms.values) {
            _io.writeln('\x1B[34m${room.id}/\x1B[0m  ${room.name}');
          }
        }
      }
    } else {
      _io.writeln('\x1B[33m(remote — rooms not available yet)\x1B[0m');
    }
  }

  void _listStation() {
    final station = _station;
    if (station == null) {
      _io.writeln('\x1B[33m(station not available)\x1B[0m');
      return;
    }
    final status = station.isRunning
        ? '\x1B[32mRunning\x1B[0m'
        : '\x1B[33mStopped\x1B[0m';
    _io.writeln('status      $status');
    _io.writeln('\x1B[34mconfig/\x1B[0m');
    _io.writeln('\x1B[34mcache/\x1B[0m');
  }

  void _listDevices() {
    final profile = _provider.profileInterface;
    if (profile == null) return;

    final allDevices = profile.getAllDevicesSorted();

    // Owned devices
    final ownedDevices =
        allDevices.where((d) => d['owned'] == true).toList();
    _io.writeln();
    _io.writeln('\x1B[1mMy Devices (${ownedDevices.length})\x1B[0m');
    _io.writeln('-' * 60);

    if (ownedDevices.isEmpty) {
      _io.writeln('  No profiles configured. Run "setup" to create one.');
    } else {
      for (final device in ownedDevices) {
        final isActive = device['active'] == true;
        final activeMarker = isActive ? '\x1B[32m*\x1B[0m' : ' ';
        final typeStr = device['type'] == 'station'
            ? '\x1B[33mstation\x1B[0m'
            : '\x1B[36mclient\x1B[0m';
        final callsign = device['callsign'] as String;
        final nickname = device['nickname'] as String;
        final displayName =
            nickname.isNotEmpty ? '$callsign ($nickname)' : callsign;
        _io.writeln('$activeMarker \x1B[1m$displayName\x1B[0m - $typeStr');
      }
    }
    _io.writeln();

    // Cached/known devices
    final cachedDevices =
        allDevices.where((d) => d['owned'] != true).toList();
    if (cachedDevices.isNotEmpty) {
      _io.writeln('\x1B[1mKnown Devices (${cachedDevices.length})\x1B[0m');
      _io.writeln('-' * 60);
      for (final device in cachedDevices) {
        final callsign = device['callsign'] as String;
        final typeStr = device['type'] ?? 'unknown';
        _io.writeln('  $callsign - $typeStr');
      }
      _io.writeln();
    }

    // Connected clients (via station)
    final station = _station;
    if (station != null) {
      final clients = station.clientsReadable;
      _io.writeln('\x1B[1mConnected Now (${clients.length})\x1B[0m');
      _io.writeln('-' * 60);
      if (clients.isEmpty) {
        _io.writeln('  No devices connected to this station');
      } else {
        for (final client in clients.values) {
          final connectedAgo =
              DateTime.now().difference(client.connectedAt);
          final callsign = client.callsign ?? 'Unknown';
          final isOwned = profile.isOwnedCallsign(callsign);
          final ownedMarker = isOwned ? '\x1B[32m*\x1B[0m' : ' ';
          _io.writeln(
            '$ownedMarker ${callsign.padRight(12)} '
            '${(client.deviceType ?? '-').padRight(10)} '
            '${_formatDuration(connectedAgo)} ago',
          );
        }
      }
      _io.writeln();
    }
  }

  void _listConfig() {
    _io.writeln('profile.json');
    _io.writeln('config.json');
  }

  void _listLogs() {
    final station = _station;
    if (station != null) {
      _io.writeln('(${station.logsReadable.length} log entries)');
    } else {
      _io.writeln('(no logs)');
    }
  }

  void _listSsl() {
    final station = _station;
    if (station == null) {
      _io.writeln('\x1B[33m(SSL not available)\x1B[0m');
      return;
    }
    final settings = station.settings;
    final sslEnabled = settings.enableSsl;

    _io.writeln('\x1B[1mSSL/TLS Status\x1B[0m');
    _io.writeln('─' * 40);
    _io.writeln(
        'HTTPS:       ${sslEnabled ? '\x1B[32mEnabled\x1B[0m on port ${settings.httpsPort}' : '\x1B[33mDisabled\x1B[0m'}');
    _io.writeln(
        'Domain:      ${settings.sslDomain ?? '\x1B[33m(not set)\x1B[0m'}');
    _io.writeln(
        'Email:       ${settings.sslEmail ?? '\x1B[33m(not set)\x1B[0m'}');
    _io.writeln(
        'Auto-renew:  ${settings.sslAutoRenew ? '\x1B[32mon\x1B[0m' : '\x1B[33moff\x1B[0m'}');
    _io.writeln('');
    _io.writeln('\x1B[1mCommands\x1B[0m (run from /ssl)');
    _io.writeln('─' * 40);
    _io.writeln('domain <domain>   Set domain for certificate');
    _io.writeln('email <email>     Set Let\'s Encrypt contact email');
    _io.writeln('request           Request production certificate');
    _io.writeln('test              Request staging (test) certificate');
    _io.writeln('renew             Force certificate renewal');
    _io.writeln('autorenew on|off  Toggle auto-renewal');
    _io.writeln('selfsigned        Generate self-signed certificate');
    _io.writeln('enable            Enable HTTPS server');
    _io.writeln('disable           Disable HTTPS server');
    _io.writeln('status            Show detailed certificate info');
  }

  void _listGames() {
    final gameConfig = _provider.gameConfig;
    if (gameConfig == null) {
      _io.writeln('(no games)');
      return;
    }
    // Use dynamic dispatch since gameConfig is Object?
    try {
      final dynamic gc = gameConfig;
      if (gc.isInitialized == true) {
        final games = gc.listGames() as List<dynamic>;
        if (games.isEmpty) {
          _io.writeln('(no games)');
        } else {
          for (final game in games) {
            _io.writeln((game.path as String).split('/').last);
          }
        }
      } else {
        _io.writeln('(no games)');
      }
    } catch (_) {
      _io.writeln('(no games)');
    }
  }

  void _listProfiles() {
    final profile = _provider.profileInterface;
    if (profile == null) return;

    final profiles = profile.profilesReadable;
    final activeId = profile.activeProfileReadable?.id;
    for (final p in profiles) {
      final isActive = p.id == activeId;
      final marker = isActive ? '* ' : '  ';
      final stationTag = p.isRelay ? ' [station]' : '';
      _io.writeln('$marker${p.callsign}/$stationTag');
    }
  }

  // --- Private: helpers ---

  /// Derive chat station/room context from a path.
  void _deriveChatContext(String path) {
    if (!path.startsWith('/chat/')) {
      _currentChatStation = null;
      _currentChatRoom = null;
      return;
    }

    final segments = path.substring(1).split('/'); // ['chat', ...]

    if (_isFlatRoomMode) {
      // Flat mode: /chat/<room> — station callsign comes from station interface
      _currentChatStation = _station?.settings.callsign;
      _currentChatRoom = segments.length >= 2 ? segments[1] : null;
    } else if (segments.length >= 2 &&
        _provider.localChatRooms.containsKey(segments[1])) {
      // Local room at /chat/<room> — use local station callsign
      _currentChatStation = _station?.settings.callsign;
      _currentChatRoom = segments[1];
    } else {
      // Station hierarchy mode: /chat/<station>/<room>
      _currentChatStation = segments.length >= 2 ? segments[1] : null;
      _currentChatRoom = segments.length >= 3 ? segments[2] : null;
    }
  }

  /// Whether we are in flat-room mode (no station callsigns, but rooms exist).
  bool get _isFlatRoomMode {
    final stations = _getStationCallsigns();
    if (stations.isNotEmpty) return false;
    final station = _station;
    return station != null && station.chatRoomsReadable.isNotEmpty;
  }

  /// Validate that a path corresponds to an existing virtual directory.
  bool _isValidPath(String path) {
    if (path == '/') return true;
    final parts = path.substring(1).split('/');
    if (parts.isEmpty) return false;

    final rootDir = parts[0];
    if (!_provider.rootDirs.contains(rootDir)) return false;

    // /chat/<...> — validate station, local room, or flat-room paths
    if (rootDir == 'chat' && parts.length >= 2) {
      final secondSegment = parts[1];
      final knownStations = _getStationCallsigns();
      final localRooms = _provider.localChatRooms;

      if (knownStations.contains(secondSegment)) {
        // /chat/<station> — station hierarchy mode
        if (parts.length >= 3) {
          final roomId = parts[2];
          if (_isLocalStation(secondSegment)) {
            final station = _station;
            if (station == null) return false;
            if (!station.chatRoomsReadable.containsKey(roomId)) return false;
          } else {
            return false; // can't cd into remote station rooms
          }
        }
      } else if (localRooms.containsKey(secondSegment)) {
        // /chat/<room> — local room (profile's own channel)
        if (parts.length > 2) return false; // no deeper nesting
      } else if (_isFlatRoomMode) {
        // /chat/<room> — flat room mode (no station callsigns available)
        final station = _station;
        if (station == null) return false;
        if (!station.chatRoomsReadable.containsKey(secondSegment)) return false;
        if (parts.length > 2) return false; // no deeper nesting
      } else {
        return false;
      }
    }

    return true;
  }

  /// Get station callsigns for /chat listing.
  ///
  /// Includes: local station (if it has a valid callsign) + known remote
  /// stations from the device list. Does not require `isRunning` — a client
  /// profile connected to a station still has chat rooms available.
  List<String> _getStationCallsigns() {
    final stations = <String>{};

    // Local station callsign (include even if not "running" —
    // client profiles connected to stations have chat rooms too)
    final stationIf = _station;
    if (stationIf != null) {
      final cs = stationIf.settings.callsign;
      if (cs.isNotEmpty && CallsignGenerator.isStationCallsign(cs)) {
        stations.add(cs);
      }
    }

    // Known stations from device list
    final profile = _provider.profileInterface;
    if (profile != null) {
      for (final d in profile.getAllDevicesSorted()) {
        final cs = d['callsign'] as String;
        if (CallsignGenerator.isStationCallsign(cs)) {
          stations.add(cs);
        }
      }
    }

    final sorted = stations.toList()..sort();
    return sorted;
  }

  /// Whether a callsign is the local station's callsign.
  bool _isLocalStation(String callsign) {
    final stationIf = _station;
    if (stationIf == null) return false;
    return stationIf.settings.callsign == callsign;
  }

  String _normalizePath(String path) {
    if (path.isEmpty) return '/';
    var normalized = path.replaceAll(RegExp(r'/+'), '/');
    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    // Handle .. segments
    final parts = normalized.split('/');
    final resolved = <String>[];
    for (final part in parts) {
      if (part == '..') {
        if (resolved.isNotEmpty && resolved.last.isNotEmpty) {
          resolved.removeLast();
        }
      } else if (part != '.') {
        resolved.add(part);
      }
    }
    final result = resolved.join('/');
    return result.isEmpty || result == '' ? '/' : result;
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}
