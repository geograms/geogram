// Pure Dart console for CLI mode (no Flutter dependencies)
import 'dart:async';
import 'dart:io';

import 'package:dart_console/dart_console.dart';

import 'pure_station.dart';
import 'cli_profile_service.dart';
import 'cli_location_service.dart';
import 'cli_station_cache_service.dart';
import '../models/profile.dart';
import '../models/chat_message.dart' as chat;
import '../util/event_bus.dart';
import 'game/game_config.dart';
import 'game/game_parser.dart';
import 'game/game_engine.dart';
import 'game/game_screen.dart';
import 'pure_storage_config.dart';
import '../util/nostr_key_generator.dart';

/// Completion candidate
class Candidate {
  final String value;
  final String display;
  final String? group;
  final bool complete;

  Candidate(this.value, {String? display, this.group, this.complete = true})
      : display = display ?? value;
}

/// Pure Dart CLI console for geogram-desktop
class PureConsole {
  /// Virtual filesystem current path
  String _currentPath = '/';

  /// Current chat room (when in /chat/<room>)
  String? _currentChatRoom;

  /// Root directories - station-only dirs filtered dynamically
  static const List<String> _allRootDirs = ['station', 'devices', 'chat', 'config', 'logs', 'ssl', 'games'];
  static const List<String> _stationOnlyDirs = ['station', 'ssl', 'logs'];

  /// Get root directories based on profile type (sorted alphabetically)
  List<String> get rootDirs {
    final profile = _profileService.activeProfile;
    final dirs = profile?.isRelay == true
        ? List<String>.from(_allRootDirs)
        : _allRootDirs.where((d) => !_stationOnlyDirs.contains(d)).toList();
    dirs.sort();
    return dirs;
  }

  /// Global commands - station-only commands filtered dynamically
  static const List<String> _allGlobalCommands = [
    'help', 'status', 'stats', 'ls', 'cd', 'pwd', 'df',
    'station', 'devices', 'chat', 'config', 'logs',
    'broadcast', 'kick', 'quiet', 'verbose', 'restart', 'reload',
    'clear', 'quit', 'exit', 'shutdown',
    'top', 'tail', 'head', 'cat', 'setup', 'ssl',
    'play', 'games', 'profile'
  ];
  static const List<String> _stationOnlyCommands = ['station', 'ssl', 'logs', 'broadcast', 'kick', 'restart', 'reload', 'shutdown'];

  /// Get global commands based on profile type
  List<String> get globalCommands {
    final profile = _profileService.activeProfile;
    if (profile?.isRelay == true) {
      return _allGlobalCommands;
    }
    return _allGlobalCommands.where((c) => !_stationOnlyCommands.contains(c)).toList();
  }

  /// Sub-commands for main commands
  static const Map<String, List<String>> subCommands = {
    'station': ['start', 'stop', 'status', 'restart', 'port', 'callsign', 'cache'],
    'devices': ['list', 'scan', 'ping'],
    'chat': ['list', 'info', 'create', 'delete', 'rename', 'history', 'say', 'delmsg'],
    'config': ['set', 'save'],
    'df': ['-h'],
    'ssl': ['domain', 'email', 'request', 'test', 'renew', 'autorenew', 'selfsigned', 'enable', 'disable'],
    'games': ['list', 'info'],
    'profile': ['list', 'add', 'switch', 'delete', 'show'],
  };

  /// Descriptions for sub-commands (shown in tab completion)
  static const Map<String, String> subCommandDescriptions = {
    // Station
    'station.start': 'Start the station server',
    'station.stop': 'Stop the station server',
    'station.status': 'Show station status',
    'station.restart': 'Restart the station',
    'station.port': 'Get/set port',
    'station.callsign': 'Get/set callsign',
    'station.cache': 'Manage cache',
    // Devices
    'devices.list': 'List all devices',
    'devices.scan': 'Scan network',
    'devices.ping': 'Ping a device',
    // Chat
    'chat.list': 'List chat rooms',
    'chat.info': 'Show room details',
    'chat.create': 'Create a room',
    'chat.delete': 'Delete a room',
    'chat.rename': 'Rename a room',
    'chat.history': 'Show messages',
    'chat.say': 'Send a message',
    'chat.delmsg': 'Delete a message',
    // Config
    'config.set': 'Set a value',
    'config.save': 'Save config',
    // SSL
    'ssl.domain': 'Get/set domain',
    'ssl.email': 'Get/set email',
    'ssl.request': 'Request certificate',
    'ssl.test': 'Test certificate',
    'ssl.renew': 'Renew certificate',
    'ssl.autorenew': 'Auto-renewal on/off',
    'ssl.selfsigned': 'Generate self-signed',
    'ssl.enable': 'Enable SSL',
    'ssl.disable': 'Disable SSL',
    // Games
    'games.list': 'List games',
    'games.info': 'Show game info',
    // Profile
    'profile.list': 'List profiles',
    'profile.add': 'Create profile',
    'profile.switch': 'Switch profile',
    'profile.delete': 'Delete profile',
    'profile.show': 'Show current',
    // df
    'df.-h': 'Human readable',
  };

  /// Command syntax help - shown when user types "command ?" or "command subcommand ?"
  static const Map<String, String> commandHelp = {
    // Global commands
    'help': 'help - Show available commands',
    'status': 'status - Show station/client status',
    'stats': 'stats - Show statistics',
    'ls': 'ls [path] - List directory contents',
    'cd': 'cd <path> - Change directory',
    'pwd': 'pwd - Print working directory',
    'df': 'df [-h] - Show disk usage',
    'clear': 'clear - Clear the screen',
    'quit': 'quit - Exit the console',
    'exit': 'exit - Exit the console',
    'setup': 'setup - Run initial setup wizard',
    'broadcast': 'broadcast <message> - Send message to all connected devices',
    'kick': 'kick <callsign> - Disconnect a device from the station',
    // Station commands
    'station': 'station <subcommand> - Manage station (start|stop|status|restart|port|callsign|cache)',
    'station start': 'station start - Start the station server',
    'station stop': 'station stop - Stop the station server',
    'station status': 'station status - Show station status',
    'station restart': 'station restart - Restart the station server',
    'station port': 'station port [port] - Get or set station port (1-65535)',
    'station callsign': 'station callsign [callsign] - Get or set station callsign',
    'station cache': 'station cache [clear] - Show cache stats or clear cache',
    'start': 'start - Start the station server',
    'stop': 'stop - Stop the station server',
    'restart': 'restart - Restart the station server',
    'port': 'port [port] - Get or set station port (1-65535)',
    'callsign': 'callsign - Show station callsign (derived from key pair)',
    'cache': 'cache [clear] - Show cache stats or clear cache',
    // Devices commands
    'devices': 'devices <subcommand> - Manage devices (list|scan|ping)',
    'devices list': 'devices list - List all known devices',
    'devices scan': 'devices scan [-t timeout_ms] - Scan network for devices',
    'devices ping': 'devices ping <ip[:port]> - Ping a device',
    'list': 'list - List items in current context',
    'scan': 'scan [-t timeout_ms] - Scan network for devices (default: 2000ms)',
    'ping': 'ping <ip[:port]> - Ping a device at the specified address',
    // Chat commands
    'chat': 'chat <subcommand> - Manage chat (list|info|create|delete|rename|history|say|delmsg)',
    'chat list': 'chat list - List all chat rooms',
    'chat info': 'chat info <room_id> - Show chat room details',
    'chat create': 'chat create <id> <name> [description] - Create a chat room (id: no spaces, use quotes for name/desc with spaces)',
    'chat delete': 'chat delete <room_id> - Delete a chat room',
    'chat rename': 'chat rename <room_id> <new_name> - Rename a chat room',
    'chat history': 'chat history <room_id> [limit] - Show chat history',
    'chat say': 'chat say <room_id> <message> - Send a message to a chat room',
    'chat delmsg': 'chat delmsg <message_id> - Delete a message',
    'info': 'info <room_id> - Show chat room details',
    'create': 'create <id> <name> [description] - Create a chat room (id: no spaces, use quotes for name/desc with spaces)',
    'delete': 'delete <room_id> - Delete a chat room',
    'rename': 'rename <room_id> <new_name> - Rename a chat room',
    'history': 'history [limit] - Show chat history (default: 50)',
    'say': 'say <message> - Send a message to the current chat room',
    'delmsg': 'delmsg <message_id> - Delete a message',
    'messages': 'messages [limit] - Show recent messages (default: 50)',
    // Config commands
    'config': 'config <subcommand> - Manage configuration (set|show|location)',
    'config set': 'config set <key> <value> - Set a configuration value',
    'config show': 'config show - Show all configuration values',
    'set': 'set <key> <value> - Set a configuration value',
    'show': 'show - Show all configuration values',
    'location': 'location - Auto-detect location via IP address',
    // SSL commands
    'ssl': 'ssl <subcommand> - Manage SSL certificates',
    'ssl domain': 'ssl domain [domain] - Get or set SSL domain',
    'ssl email': 'ssl email [email] - Get or set SSL contact email',
    'ssl request': 'ssl request - Request SSL certificate from Let\'s Encrypt',
    'ssl test': 'ssl test - Request test certificate (staging)',
    'ssl renew': 'ssl renew - Renew SSL certificate',
    'ssl autorenew': 'ssl autorenew [on|off] - Enable/disable auto-renewal',
    'ssl selfsigned': 'ssl selfsigned - Generate self-signed certificate',
    'ssl enable': 'ssl enable - Enable SSL',
    'ssl disable': 'ssl disable - Disable SSL',
    'ssl status': 'ssl status - Show SSL status',
    'domain': 'domain [domain] - Get or set SSL domain',
    'email': 'email [email] - Get or set SSL contact email',
    'request': 'request - Request SSL certificate from Let\'s Encrypt',
    'test': 'test - Request test certificate (staging)',
    'renew': 'renew - Renew SSL certificate',
    'autorenew': 'autorenew [on|off] - Enable/disable auto-renewal',
    'selfsigned': 'selfsigned - Generate self-signed certificate',
    'enable': 'enable - Enable SSL',
    'disable': 'disable - Disable SSL',
    // Profile commands
    'profile': 'profile <subcommand> - Manage profiles (list|add|switch|delete|show)',
    'profile list': 'profile list - List all profiles',
    'profile add': 'profile add - Create a new profile',
    'profile switch': 'profile switch <callsign> - Switch to a different profile',
    'profile delete': 'profile delete <callsign> - Delete a profile',
    'profile show': 'profile show - Show current profile details',
    // Games commands
    'games': 'games <subcommand> - Games (list|info|play)',
    'games list': 'games list - List available games',
    'games info': 'games info <game_id> - Show game details',
    'play': 'play <game_id> - Start playing a game',
  };

  /// Directory-specific commands (when inside these directories)
  Map<String, List<String>> get dirCommands {
    final profile = _profileService.activeProfile;
    final isRelay = profile?.isRelay == true;

    return {
      if (isRelay) '/station': ['start', 'stop', 'status', 'restart', 'port', 'callsign', 'cache'],
      '/devices': ['list', 'scan', 'ping'],
      '/chat': ['list', 'info', 'create', 'delete', 'rename', 'history', 'say', 'delmsg', 'messages'],
      '/config': ['set', 'show', 'location'],
      if (isRelay) '/logs': [],
      if (isRelay) '/ssl': ['domain', 'email', 'request', 'test', 'renew', 'autorenew', 'selfsigned', 'enable', 'disable', 'status'],
      '/games': ['list', 'info', 'play'],
    };
  }

  /// Config keys with their types for validation
  /// Types: 'string', 'bool', 'int', 'double'
  static const Map<String, String> configKeyTypes = {
    'nickname': 'string',
    'description': 'string',
    'preferredColor': 'string',
    'latitude': 'double',
    'longitude': 'double',
    'locationName': 'string',
    'enableAprs': 'bool',
    // Station-only settings
    'httpPort': 'int',
    'httpsPort': 'int',
    'tileServerEnabled': 'bool',
    'osmFallbackEnabled': 'bool',
    'maxZoomLevel': 'int',
    'maxCacheSizeMB': 'int',
    'enableCors': 'bool',
    'maxConnectedDevices': 'int',
  };

  /// Config keys that are station-only
  static const List<String> _stationOnlyConfigKeys = [
    'httpPort', 'httpsPort', 'tileServerEnabled', 'osmFallbackEnabled', 'maxZoomLevel',
    'maxCacheSizeMB', 'enableCors', 'maxConnectedDevices'
  ];

  /// Get config keys based on profile type
  List<String> get configKeys {
    final profile = _profileService.activeProfile;
    if (profile?.isRelay == true) {
      return configKeyTypes.keys.toList();
    }
    return configKeyTypes.keys.where((k) => !_stationOnlyConfigKeys.contains(k)).toList();
  }

  /// Command history
  final List<String> _history = [];
  int _historyIndex = 0;
  static const int _maxHistorySize = 100;
  static const String _historyFileName = '.cli_history';

  /// Double CTRL+C handling
  DateTime? _lastCtrlCTime;
  static const _ctrlCTimeout = Duration(seconds: 2);

  /// Station server instance
  final PureStationServer _station = PureStationServer();

  /// Event subscription for chat messages
  EventSubscription<ChatMessageEvent>? _chatMessageSubscription;

  /// CLI Profile service
  final CliProfileService _profileService = CliProfileService();

  /// CLI Station cache service
  final CliRelayCacheService _cacheService = CliRelayCacheService();

  /// SSL certificate manager
  SslCertificateManager? _sslManager;

  /// Game engine config
  final GameConfig _gameConfig = GameConfig();

  /// Run CLI mode
  Future<void> run(List<String> args) async {
    // Check for --setup flag
    final forceSetup = args.contains('--setup') || args.contains('-s');

    // Parse --data-dir argument for custom storage location
    final customDataDir = parseDataDirFromArgs(args);

    // Initialize storage configuration first
    await PureStorageConfig().init(customBaseDir: customDataDir);

    await _initializeServices();
    _printBanner();

    // Check if setup is needed (no profiles exist)
    if (forceSetup || _profileService.needsSetup()) {
      if (_profileService.needsSetup()) {
        stdout.writeln('\x1B[33mInitial setup required.\x1B[0m');
        stdout.writeln();
      }
      await _handleSetup();
    }

    // Check for daemon mode: ./geogram-cli station (runs station server without interactive prompt)
    if (args.isNotEmpty && args[0] == 'station') {
      await _runDaemonMode();
      return;
    }

    await _commandLoop();
  }

  Future<void> _initializeServices() async {
    try {
      // Initialize profile service first
      await _profileService.initialize();

      // Initialize station server
      await _station.initialize();

      // Sync profile location to station settings (for /status endpoint)
      final profile = _profileService.activeProfile;
      if (profile != null && profile.latitude != null && profile.longitude != null) {
        final updatedSettings = _station.settings.copyWith(
          latitude: profile.latitude,
          longitude: profile.longitude,
          location: profile.locationName,
        );
        await _station.updateSettings(updatedSettings);
      }

      // Enable quiet mode by default (logs go to buffer, not stderr)
      // Users can disable with 'verbose' command or view logs with 'top'/'tail'
      _station.quietMode = true;

      // Initialize SSL manager
      _sslManager = SslCertificateManager(_station.settings, _station.dataDir!);
      await _sslManager!.initialize();
      _sslManager!.setStationServer(_station);
      _sslManager!.startAutoRenewal();

      // Initialize game engine
      await _gameConfig.initialize(_station.dataDir!);

      // Initialize cache service
      await _cacheService.initialize();

      // Load command history
      await _loadHistory();

      // Subscribe to chat message events for real-time display
      _chatMessageSubscription = _station.eventBus.on<ChatMessageEvent>((event) {
        _handleIncomingChatMessage(event);
      });
    } catch (e) {
      _printError('Failed to initialize services: $e');
      exit(1);
    }
  }

  /// Run in daemon mode - start station server and wait indefinitely
  /// Used when running: ./geogram-cli station
  Future<void> _runDaemonMode() async {
    stdout.writeln('Starting in daemon mode...');

    // Start the station server
    final success = await _station.start();

    if (!success) {
      _printError('Failed to start station server');
      exit(1);
    }

    stdout.writeln('\x1B[32mRelay server started in daemon mode\x1B[0m');
    stdout.writeln('  HTTP Port:  ${_station.settings.httpPort}');
    stdout.writeln('  HTTPS Port: ${_station.settings.httpsPort}');
    stdout.writeln('  Callsign:   ${_station.settings.callsign}');
    stdout.writeln('');
    stdout.writeln('Press Ctrl+C to stop the server.');

    // Set up signal handler for graceful shutdown
    ProcessSignal.sigint.watch().listen((_) async {
      stdout.writeln('\nShutting down...');
      await _station.stop();
      await _cleanup();
      exit(0);
    });

    // Keep the process running
    await Future.delayed(const Duration(days: 365 * 100));
  }

  /// Handle incoming chat message event - display if in same room and not from self
  void _handleIncomingChatMessage(ChatMessageEvent event) {
    // Only display if we're in the same chat room
    if (_currentChatRoom != event.roomId) return;

    // Don't display our own messages (already shown when sent)
    final myCallsign = _profileService.activeProfile?.callsign;
    if (myCallsign != null && event.callsign == myCallsign) return;

    // Format timestamp
    final now = event.timestamp;
    final timeStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    // Determine verification indicator
    String verifyIndicator;
    if (event.signature != null && event.signature!.isNotEmpty) {
      verifyIndicator = event.verified ? '\x1B[32m✓\x1B[0m' : '\x1B[31m✗\x1B[0m';
    } else {
      verifyIndicator = '\x1B[90m○\x1B[0m'; // No signature (gray circle)
    }

    // Clear current line (prompt + any input), print message, restore input
    // \x1B[2K = clear entire line, \r = carriage return to start of line
    stdout.write('\r\x1B[2K');
    stdout.writeln('\x1B[33m[$timeStr]\x1B[0m $verifyIndicator \x1B[36m${event.callsign}:\x1B[0m ${event.content}');

    // Restore prompt and any partial input
    stdout.write(_currentPrompt);
    stdout.write(_currentInputBuffer);
    // Move cursor to correct position if not at end
    if (_currentInputIndex < _currentInputBuffer.length) {
      final backspaces = _currentInputBuffer.length - _currentInputIndex;
      stdout.write('\x1B[${backspaces}D');
    }
  }

  /// Cleanup all services before exit
  Future<void> _cleanup() async {
    // Cancel event subscriptions
    _chatMessageSubscription?.cancel();
    // Save command history (synchronous)
    _saveHistory();
    // Stop SSL auto-renewal timer
    _sslManager?.stop();
    // Stop station server
    if (_station.isRunning) {
      await _station.stop();
    }
    // Reset console to normal mode
    _cleanupAsyncStdin();
    stdin.echoMode = true;
    stdin.lineMode = true;
  }

  /// Load command history from file
  Future<void> _loadHistory() async {
    try {
      final historyFile = File('${PureStorageConfig().baseDir}/$_historyFileName');
      if (await historyFile.exists()) {
        final lines = await historyFile.readAsLines();
        _history.clear();
        _history.addAll(lines.where((line) => line.isNotEmpty));
        _historyIndex = _history.length;
      }
    } catch (e) {
      // Silently ignore history load errors
    }
  }

  /// Save command history to file (synchronous for reliability)
  void _saveHistory() {
    try {
      final historyFile = File('${PureStorageConfig().baseDir}/$_historyFileName');
      // Keep only last _maxHistorySize commands
      final historyToSave = _history.length > _maxHistorySize
          ? _history.sublist(_history.length - _maxHistorySize)
          : _history;
      historyFile.writeAsStringSync(historyToSave.join('\n'));
    } catch (e) {
      // Silently ignore history save errors
    }
  }

  void _printBanner() {
    stdout.writeln();
    stdout.writeln('\x1B[36m' + '=' * 60 + '\x1B[0m');
    stdout.writeln('\x1B[36m  Geogram Desktop v$cliAppVersion - CLI Mode\x1B[0m');

    final activeProfile = _profileService.activeProfile;
    if (activeProfile != null) {
      final typeStr = activeProfile.isRelay ? ' [station]' : '';
      stdout.writeln('\x1B[36m  Active Profile: ${activeProfile.callsign} ($typeStr)\x1B[0m');
    } else {
      stdout.writeln('\x1B[33m  No profile configured\x1B[0m');
    }

    stdout.writeln('\x1B[36m  Data Directory: ${PureStorageConfig().baseDir}\x1B[0m');
    stdout.writeln('\x1B[36m' + '=' * 60 + '\x1B[0m');
    stdout.writeln();
    stdout.writeln('Type "help" for available commands.');
    stdout.writeln();
  }

  Future<void> _commandLoop() async {
    while (true) {
      final prompt = _buildPrompt();
      final input = await _readLineWithCompletion(prompt);

      if (input == null || input.isEmpty) continue;

      // Handle double CTRL+C exit
      if (input == '__EXIT__') {
        await _cleanup();
        stdout.writeln('Goodbye!');
        exit(0);
      }

      // Add to history (avoid duplicates and limit size)
      if (_history.isEmpty || _history.last != input) {
        _history.add(input);
        // Trim history if it exceeds max size
        if (_history.length > _maxHistorySize) {
          _history.removeAt(0);
        }
        // Save history after each command (don't await to avoid blocking)
        _saveHistory();
      }
      _historyIndex = _history.length;

      // If in a chat room, treat non-command input as a message
      if (_currentChatRoom != null && !input.startsWith('/') && !_isCommand(input)) {
        // Use station's chat room management in CLI mode
        if (_station.chatRooms[_currentChatRoom!] != null) {
          await _station.postMessage(_currentChatRoom!, input);
          // IRC-style: show formatted message (replacing the raw input line)
          final now = DateTime.now();
          final timeStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          final callsign = _profileService.activeProfile?.callsign ?? 'You';
          // Move cursor up to replace the empty line after input, print message
          stdout.write('\x1B[A\x1B[2K');
          stdout.writeln('\x1B[33m[$timeStr]\x1B[0m \x1B[32m✓\x1B[0m \x1B[36m$callsign:\x1B[0m $input');
        } else {
          _printError('Room not found: $_currentChatRoom');
        }
        continue;
      }

      final parts = _parseInput(input);
      final command = parts[0].toLowerCase().replaceFirst('/', '');
      final args = parts.length > 1 ? parts.sublist(1) : <String>[];

      try {
        final shouldExit = await _processCommand(command, args);
        if (shouldExit) break;
      } catch (e) {
        _printError('Error: $e');
      }
    }
  }

  String _buildPrompt() {
    final chatPrefix = _currentChatRoom != null
        ? '\x1B[35m[$_currentChatRoom]\x1B[0m '
        : '';
    return '$chatPrefix\x1B[32mgeogram:$_currentPath\$ \x1B[0m';
  }

  /// Console instance for terminal control
  final Console _console = Console();

  /// Stdin byte queue for async reading
  final _stdinQueue = <int>[];
  StreamSubscription<List<int>>? _stdinSubscription;
  Completer<int>? _byteCompleter;

  /// Current input line state (for async message display)
  String _currentInputBuffer = '';
  int _currentInputIndex = 0;
  String _currentPrompt = '';

  /// Initialize async stdin reading
  void _initAsyncStdin() {
    if (_stdinSubscription != null) return;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
    } catch (e) {
      // Ignore terminal mode errors when running non-interactively (e.g., nohup, screen detached)
      // The station will still work, just without fancy input handling
    }
    _stdinSubscription = stdin.listen((data) {
      _stdinQueue.addAll(data);
      // Complete any pending read
      if (_byteCompleter != null && !_byteCompleter!.isCompleted && _stdinQueue.isNotEmpty) {
        _byteCompleter!.complete(_stdinQueue.removeAt(0));
        _byteCompleter = null;
      }
    });
  }

  /// Read a single byte asynchronously to allow event loop to process HTTP requests
  Future<int> _readByteAsync() async {
    if (_stdinQueue.isNotEmpty) {
      return _stdinQueue.removeAt(0);
    }
    _byteCompleter = Completer<int>();
    return _byteCompleter!.future;
  }

  /// Read a byte with timeout for escape sequence handling
  /// Returns -1 if no byte available within timeout
  Future<int> _readByteAsyncWithTimeout() async {
    // First check if there's already a byte in the queue
    if (_stdinQueue.isNotEmpty) {
      return _stdinQueue.removeAt(0);
    }
    // Wait briefly for escape sequence bytes (they should arrive quickly)
    // Use a short timeout to handle cases where ESC is pressed alone
    try {
      _byteCompleter = Completer<int>();
      final result = await _byteCompleter!.future.timeout(
        const Duration(milliseconds: 50),
        onTimeout: () => -1,
      );
      return result;
    } catch (e) {
      return -1;
    }
  }

  /// Cleanup async stdin
  void _cleanupAsyncStdin() {
    _stdinSubscription?.cancel();
    _stdinSubscription = null;
    _stdinQueue.clear();
    _byteCompleter = null;
  }

  /// Read a line with TAB completion and history support
  Future<String?> _readLineWithCompletion(String prompt) async {
    // Check if stdin is a terminal
    if (!stdin.hasTerminal) {
      stdout.write(prompt);
      return stdin.readLineSync()?.trim();
    }

    stdout.write(prompt);
    var buffer = '';
    var index = 0; // cursor position

    // Track state for async message display
    _currentPrompt = prompt;
    _currentInputBuffer = buffer;
    _currentInputIndex = index;

    // Use async stdin reading to allow HTTP server to process requests
    _initAsyncStdin();
    try {
      while (true) {
        final byte = await _readByteAsync();
        if (byte == -1) continue; // EOF, keep reading

        // Enter (CR or LF)
        if (byte == 13 || byte == 10) {
          _currentInputBuffer = '';
          _currentInputIndex = 0;
          stdout.writeln();
          return buffer.trim();
        }

        // CTRL+C
        if (byte == 3) {
          final now = DateTime.now();
          if (_lastCtrlCTime != null &&
              now.difference(_lastCtrlCTime!) < _ctrlCTimeout) {
            stdout.writeln();
            stdout.writeln('Shutting down...');
            return '__EXIT__';
          } else {
            _lastCtrlCTime = now;
            stdout.writeln();
            stdout.writeln('Press Ctrl+C again to exit (or wait 2 seconds to cancel)');
            _redrawLine(prompt, buffer, index);
          }
          continue;
        }

        // CTRL+D
        if (byte == 4) {
          if (buffer.isEmpty) {
            stdout.writeln();
            return 'quit';
          }
          continue;
        }

        // Escape sequence (arrow keys, etc.)
        if (byte == 27) {
          final byte1 = await _readByteAsyncWithTimeout();
          if (byte1 == -1) continue;

          // Handle ESC [ or ESC O sequences (most common)
          if (byte1 == 91 || byte1 == 79) { // '[' (91) or 'O' (79)
            final byte2 = await _readByteAsyncWithTimeout();
            if (byte2 == -1) continue;

            // Handle extended sequences like ESC [ 1 ~ (Home) or ESC [ 3 ~ (Delete)
            if (byte2 >= 49 && byte2 <= 54) { // '1' to '6'
              final byte3 = await _readByteAsyncWithTimeout();
              if (byte3 == 126) { // '~'
                // Extended key handling
                switch (byte2) {
                  case 49: // Home
                    _handleArrowKey(72, buffer, index, prompt, (newBuf, newIdx) {
                      buffer = newBuf;
                      index = newIdx;
                    });
                    break;
                  case 51: // Delete
                    _handleArrowKey(126, buffer, index, prompt, (newBuf, newIdx) {
                      buffer = newBuf;
                      index = newIdx;
                    });
                    break;
                  case 52: // End
                    _handleArrowKey(70, buffer, index, prompt, (newBuf, newIdx) {
                      buffer = newBuf;
                      index = newIdx;
                    });
                    break;
                }
                continue;
              }
              // Not a tilde, might be something else - just skip
              continue;
            }

            // Standard arrow keys (A=65, B=66, C=67, D=68), Home (H=72), End (F=70)
            _handleArrowKey(byte2, buffer, index, prompt, (newBuf, newIdx) {
              buffer = newBuf;
              index = newIdx;
            });
          }
          // Everything after ESC is consumed, continue to next byte
          continue;
        }

        // Backspace (127 or 8)
        if (byte == 127 || byte == 8) {
          if (index > 0) {
            buffer = buffer.substring(0, index - 1) + buffer.substring(index);
            index--;
            _redrawLine(prompt, buffer, index);
          }
          continue;
        }

        // CTRL+A - Home
        if (byte == 1) {
          while (index > 0) {
            index--;
            stdout.write('\x1B[D');
          }
          continue;
        }

        // CTRL+E - End
        if (byte == 5) {
          while (index < buffer.length) {
            index++;
            stdout.write('\x1B[C');
          }
          continue;
        }

        // CTRL+U - Clear line before cursor
        if (byte == 21) {
          if (index > 0) {
            buffer = buffer.substring(index);
            index = 0;
            _redrawLine(prompt, buffer, index);
          }
          continue;
        }

        // CTRL+K - Clear line after cursor
        if (byte == 11) {
          if (index < buffer.length) {
            buffer = buffer.substring(0, index);
            _redrawLine(prompt, buffer, index);
          }
          continue;
        }

        // CTRL+L - Clear screen
        if (byte == 12) {
          stdout.write('\x1B[2J\x1B[H');
          stdout.write(prompt + buffer);
          for (var i = buffer.length; i > index; i--) {
            stdout.write('\x1B[D');
          }
          continue;
        }

        // TAB - completion
        if (byte == 9) {
          final result = _handleTabCompletion(buffer, index, prompt);
          if (result != null) {
            buffer = result;
            index = buffer.length;
            _redrawLine(prompt, buffer, index);
          }
          continue;
        }

        // Regular printable character
        if (byte >= 32 && byte < 127) {
          final char = String.fromCharCode(byte);
          buffer = buffer.substring(0, index) + char + buffer.substring(index);
          index++;
          if (index == buffer.length) {
            stdout.write(char);
          } else {
            _redrawLine(prompt, buffer, index);
          }
        }

        // Sync state for async message display
        _currentInputBuffer = buffer;
        _currentInputIndex = index;
      }
    } catch (e) {
      // On error, just return what we have
      return buffer.isEmpty ? null : buffer.trim();
    }
  }

  /// Handle arrow key input
  void _handleArrowKey(int keyCode, String buffer, int index, String prompt,
      void Function(String, int) updateState) {
    switch (keyCode) {
      case 65: // Up arrow
        if (_history.isNotEmpty && _historyIndex > 0) {
          _historyIndex--;
          final newBuffer = _history[_historyIndex];
          _redrawLine(prompt, newBuffer, newBuffer.length);
          updateState(newBuffer, newBuffer.length);
        }
        break;
      case 66: // Down arrow
        if (_historyIndex < _history.length - 1) {
          _historyIndex++;
          final newBuffer = _history[_historyIndex];
          _redrawLine(prompt, newBuffer, newBuffer.length);
          updateState(newBuffer, newBuffer.length);
        } else if (_historyIndex >= _history.length - 1) {
          _historyIndex = _history.length;
          _redrawLine(prompt, '', 0);
          updateState('', 0);
        }
        break;
      case 67: // Right arrow
        if (index < buffer.length) {
          stdout.write('\x1B[C');
          updateState(buffer, index + 1);
        }
        break;
      case 68: // Left arrow
        if (index > 0) {
          stdout.write('\x1B[D');
          updateState(buffer, index - 1);
        }
        break;
      case 72: // Home
        var newIndex = index;
        while (newIndex > 0) {
          newIndex--;
          stdout.write('\x1B[D');
        }
        updateState(buffer, newIndex);
        break;
      case 70: // End
        var newIndex = index;
        while (newIndex < buffer.length) {
          newIndex++;
          stdout.write('\x1B[C');
        }
        updateState(buffer, newIndex);
        break;
      case 51: // Delete key (ESC [ 3 ~)
        final tilde = stdin.readByteSync(); // consume ~
        if (tilde == 126 && index < buffer.length) {
          final newBuffer = buffer.substring(0, index) + buffer.substring(index + 1);
          _redrawLine(prompt, newBuffer, index);
          updateState(newBuffer, index);
        }
        break;
    }
  }

  /// Redraw the current line with prompt and buffer
  void _redrawLine(String prompt, String buffer, int cursorIndex) {
    // Move to start of line, clear line, rewrite
    stdout.write('\r\x1B[K$prompt$buffer');
    // Move cursor to correct position
    for (var i = buffer.length; i > cursorIndex; i--) {
      stdout.write('\x1B[D');
    }
  }

  /// Handle TAB completion
  String? _handleTabCompletion(String buffer, int cursorPos, String prompt) {
    final beforeCursor = buffer.substring(0, cursorPos);
    final candidates = _getCompletions(beforeCursor);

    if (candidates.isEmpty) {
      return null;
    }

    if (candidates.length == 1) {
      // Single match - complete it
      final candidate = candidates.first;
      final parts = beforeCursor.split(RegExp(r'\s+'));
      if (parts.isEmpty) return candidate.value;

      parts[parts.length - 1] = candidate.value;
      final completed = parts.join(' ');
      return candidate.complete ? '$completed ' : completed;
    }

    // Multiple matches - show them and find common prefix
    _console.writeLine();
    _displayCandidates(candidates);

    // Find common prefix
    final commonPrefix = _findCommonPrefix(candidates.map((c) => c.value).toList());
    final parts = beforeCursor.split(RegExp(r'\s+'));
    final lastPart = parts.isNotEmpty ? parts.last : '';

    if (commonPrefix.length > lastPart.length) {
      parts[parts.length - 1] = commonPrefix;
      return parts.join(' ');
    }

    return buffer; // Return unchanged
  }

  /// Get completion candidates based on current input
  List<Candidate> _getCompletions(String buffer) {
    // Filter out empty strings from split (happens with trailing spaces)
    final parts = buffer.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) {
      return _getContextAwareCommands('');
    }

    final firstWord = parts[0].toLowerCase();
    final endsWithSpace = buffer.endsWith(' ');

    if (parts.length == 1 && !endsWithSpace) {
      // Completing first word (command)
      return _getContextAwareCommands(firstWord);
    }

    // If buffer ends with space and parts.length == 1, treat as completing second word with empty partial
    final effectivePartsLength = endsWithSpace ? parts.length + 1 : parts.length;

    // Check if it's a directory-local command
    if (dirCommands.containsKey(_currentPath)) {
      final localCmds = dirCommands[_currentPath]!;
      if (localCmds.contains(firstWord)) {
        return _completeLocalCommandArgs(firstWord, parts);
      }
    }

    // Completing subsequent words (sub-commands or arguments)
    if (effectivePartsLength == 2) {
      final partial = parts.length > 1 ? parts[1].toLowerCase() : '';

      // Check for sub-commands
      if (subCommands.containsKey(firstWord)) {
        return _filterSubCommands(firstWord, subCommands[firstWord]!, partial);
      }

      // Special completions based on command
      switch (firstWord) {
        case 'kick':
          return _completeCallsigns(partial);
        case 'ls':
        case 'cd':
          return _completePaths(partial);
        case 'play':
          return _completeGameFiles(partial);
      }
    }

    if (effectivePartsLength == 3) {
      final subCmd = parts.length > 1 ? parts[1].toLowerCase() : '';
      final partial = parts.length > 2 ? parts[2].toLowerCase() : '';

      // station cache <subcommand>
      if (firstWord == 'station' && subCmd == 'cache') {
        return _filterCandidates(['clear', 'stats'], partial);
      }

      // config set <key>
      if (firstWord == 'config' && subCmd == 'set') {
        return _filterCandidates(configKeys, partial);
      }

      // chat <subcommand> <roomId>
      if (firstWord == 'chat' && ['info', 'delete', 'rename', 'history', 'say', 'delmsg'].contains(subCmd)) {
        return _completeRoomIds(partial);
      }

      // devices ping/kick <target>
      if (firstWord == 'devices') {
        if (subCmd == 'kick') {
          return _completeCallsigns(partial);
        }
      }

      // profile switch <callsign>
      if (firstWord == 'profile' && subCmd == 'switch') {
        return _completeProfileCallsigns(partial);
      }
    }

    return [];
  }

  /// Get commands based on current directory context
  List<Candidate> _getContextAwareCommands(String partial) {
    final candidates = <Candidate>[];
    final lowerPartial = partial.toLowerCase();

    // First add directory-local commands (if in a special directory)
    if (dirCommands.containsKey(_currentPath)) {
      final localCmds = dirCommands[_currentPath]!;
      for (final cmd in localCmds) {
        if (cmd.toLowerCase().startsWith(lowerPartial)) {
          final dirName = _currentPath.substring(1).toUpperCase();
          candidates.add(Candidate(cmd, group: '$dirName commands'));
        }
      }
    }

    // Add chat room-specific commands
    if (_currentChatRoom != null) {
      for (final cmd in ['messages', 'delmsg']) {
        if (cmd.startsWith(lowerPartial)) {
          candidates.add(Candidate(cmd, group: 'CHAT commands'));
        }
      }
    }

    // Then add global commands
    for (final cmd in globalCommands) {
      if (cmd.toLowerCase().startsWith(lowerPartial)) {
        candidates.add(Candidate(cmd, group: 'Global commands'));
      }
    }

    return candidates;
  }

  /// Complete directory-local command arguments
  List<Candidate> _completeLocalCommandArgs(String localCmd, List<String> parts) {
    // Get partial - when buffer ends with space but parts.length == 1, partial is empty
    final partial = parts.length > 1 ? parts[1].toLowerCase() : '';

    if (_currentPath == '/config') {
      if (localCmd == 'set') {
        return _filterCandidates(configKeys, partial);
      }
    } else if (_currentPath == '/chat') {
      if (['info', 'delete', 'rename', 'history'].contains(localCmd)) {
        return _completeRoomIds(partial);
      }
    } else if (_currentPath == '/devices') {
      if (localCmd == 'kick') {
        return _completeCallsigns(partial);
      }
      if (localCmd == 'scan' && partial.startsWith('-')) {
        return _filterCandidates(['-t'], partial);
      }
    } else if (_currentPath == '/station') {
      if (localCmd == 'cache') {
        return _filterCandidates(['clear', 'stats'], partial);
      }
    } else if (_currentPath == '/games') {
      if (localCmd == 'play' || localCmd == 'info') {
        return _completeGameFiles(partial);
      }
    } else if (_currentPath == '/ssl') {
      if (localCmd == 'autorenew') {
        return _filterCandidates(['on', 'off'], partial);
      }
    }

    return [];
  }

  /// Complete with path entries (for ls, cd)
  List<Candidate> _completePaths(String partial) {
    final candidates = <Candidate>[];
    final lowerPartial = partial.toLowerCase();

    // Parent directory
    if ('..'.startsWith(lowerPartial)) {
      candidates.add(Candidate('..', group: 'parent'));
    }

    if (partial.isEmpty || partial == '/') {
      // Show root directories
      for (final dir in rootDirs) {
        candidates.add(Candidate(dir, display: '$dir/', group: 'directory', complete: false));
      }
      return candidates;
    }

    // Absolute path completion
    if (partial.startsWith('/')) {
      final pathParts = partial.substring(1).split('/');
      final baseDir = pathParts[0];

      if (pathParts.length == 1) {
        // Completing root directory name
        for (final dir in rootDirs) {
          if (dir.startsWith(baseDir.toLowerCase())) {
            candidates.add(Candidate('/$dir', display: '/$dir/', group: 'directory', complete: false));
          }
        }
      } else if (baseDir == 'chat' && pathParts.length == 2) {
        // Completing chat room name - use station's chat rooms in CLI mode
        final roomPartial = pathParts[1].toLowerCase();
        for (final room in _station.chatRooms.values) {
          if (room.id.toLowerCase().startsWith(roomPartial)) {
            candidates.add(Candidate('/chat/${room.id}', display: '/chat/${room.id}/', group: 'chat room', complete: false));
          }
        }
      }
      return candidates;
    }

    // Relative path completion based on current directory
    if (_currentPath == '/') {
      for (final dir in rootDirs) {
        if (dir.toLowerCase().startsWith(lowerPartial)) {
          candidates.add(Candidate(dir, display: '$dir/', group: 'directory', complete: false));
        }
      }
    } else if (_currentPath == '/chat') {
      // Use station's chat rooms in CLI mode
      for (final room in _station.chatRooms.values) {
        if (room.id.toLowerCase().startsWith(lowerPartial)) {
          candidates.add(Candidate(room.id, display: '${room.id}/', group: 'chat room', complete: false));
        }
      }
    } else if (_currentPath == '/devices') {
      for (final client in _station.clients.values) {
        final callsign = client.callsign ?? 'unknown';
        if (callsign.toLowerCase().startsWith(lowerPartial)) {
          candidates.add(Candidate(callsign, group: 'device'));
        }
      }
    }

    return candidates;
  }

  /// Complete with callsigns
  List<Candidate> _completeCallsigns(String partial) {
    final candidates = <Candidate>[];
    final upperPartial = partial.toUpperCase();

    for (final client in _station.clients.values) {
      final callsign = client.callsign ?? '';
      if (callsign.toUpperCase().startsWith(upperPartial)) {
        candidates.add(Candidate(callsign, group: 'device'));
      }
    }

    return candidates;
  }

  /// Complete with profile callsigns
  List<Candidate> _completeProfileCallsigns(String partial) {
    final candidates = <Candidate>[];
    final upperPartial = partial.toUpperCase();

    for (final profile in _profileService.profiles) {
      if (profile.callsign.toUpperCase().startsWith(upperPartial)) {
        final label = profile.nickname.isNotEmpty ? '${profile.callsign} (${profile.nickname})' : profile.callsign;
        candidates.add(Candidate(profile.callsign, display: label, group: profile.isRelay ? 'station' : 'client'));
      }
    }

    return candidates;
  }

  /// Complete with chat room IDs
  List<Candidate> _completeRoomIds(String partial) {
    final candidates = <Candidate>[];
    final lowerPartial = partial.toLowerCase();

    // Use station's chat rooms in CLI mode
    for (final room in _station.chatRooms.values) {
      if (room.id.toLowerCase().startsWith(lowerPartial)) {
        candidates.add(Candidate(room.id, display: '${room.id} (${room.name})', group: 'room'));
      }
    }

    return candidates;
  }

  /// Complete game file names for 'play' command
  List<Candidate> _completeGameFiles(String partial) {
    final candidates = <Candidate>[];
    final lowerPartial = partial.toLowerCase();

    if (!_gameConfig.isInitialized) return candidates;

    final games = _gameConfig.listGames();
    for (final game in games) {
      final fileName = game.path.split('/').last;
      if (fileName.toLowerCase().startsWith(lowerPartial)) {
        final info = _gameConfig.getGameInfo(fileName);
        final title = info?['title'] ?? fileName;
        candidates.add(Candidate(fileName, display: '$fileName ($title)', group: 'game'));
      }
    }

    return candidates;
  }

  /// Filter candidates by partial match
  List<Candidate> _filterCandidates(List<String> options, String partial) {
    final lowerPartial = partial.toLowerCase();
    return options
        .where((opt) => opt.toLowerCase().startsWith(lowerPartial))
        .map((opt) => Candidate(opt))
        .toList();
  }

  /// Filter sub-commands with descriptions
  List<Candidate> _filterSubCommands(String command, List<String> options, String partial) {
    final lowerPartial = partial.toLowerCase();
    return options
        .where((opt) => opt.toLowerCase().startsWith(lowerPartial))
        .map((opt) {
          final descKey = '$command.$opt';
          final desc = subCommandDescriptions[descKey];
          final display = desc != null ? '$opt - $desc' : opt;
          return Candidate(opt, display: display, group: '$command subcommands');
        })
        .toList();
  }

  /// Find common prefix among candidates
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

  /// Display completion candidates
  void _displayCandidates(List<Candidate> candidates) {
    // Group candidates
    final groups = <String?, List<Candidate>>{};
    for (final c in candidates) {
      groups.putIfAbsent(c.group, () => []).add(c);
    }

    for (final entry in groups.entries) {
      if (entry.key != null) {
        stdout.writeln('\x1B[33m${entry.key}:\x1B[0m');
      }
      // Use columns for command groups (compact display), one per line for others
      final isCommandGroup = entry.key != null &&
          (entry.key!.contains('commands') || entry.key!.contains('subcommands'));
      if (isCommandGroup) {
        _printColumns(entry.value.map((c) => c.display).toList());
      } else {
        for (final c in entry.value) {
          stdout.writeln('  ${c.display}');
        }
      }
    }
  }

  /// Print items in columns
  void _printColumns(List<String> items) {
    if (items.isEmpty) return;

    final maxLen = items.map((s) => s.length).reduce((a, b) => a > b ? a : b);
    final termWidth = stdout.hasTerminal ? stdout.terminalColumns : 80;
    final colWidth = maxLen + 2;
    final numCols = (termWidth / colWidth).floor().clamp(1, items.length);

    for (var i = 0; i < items.length; i += numCols) {
      final row = <String>[];
      for (var j = 0; j < numCols && i + j < items.length; j++) {
        row.add(items[i + j].padRight(colWidth));
      }
      stdout.writeln('  ${row.join('')}');
    }
  }

  List<String> _parseInput(String input) {
    final parts = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;
    var quoteChar = '';

    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      if ((c == '"' || c == "'") && !inQuotes) {
        inQuotes = true;
        quoteChar = c;
      } else if (c == quoteChar && inQuotes) {
        inQuotes = false;
        quoteChar = '';
      } else if (c == ' ' && !inQuotes) {
        if (buffer.isNotEmpty) {
          parts.add(buffer.toString());
          buffer.clear();
        }
      } else {
        buffer.write(c);
      }
    }
    if (buffer.isNotEmpty) {
      parts.add(buffer.toString());
    }
    return parts;
  }

  bool _isCommand(String input) {
    final commands = ['help', 'status', 'stats', 'ls', 'cd', 'pwd', 'station', 'devices',
      'chat', 'config', 'logs', 'clear', 'quit', 'exit', 'broadcast', 'kick', 'df',
      'quiet', 'verbose', 'restart', 'reload', 'messages', 'delmsg'];
    final firstWord = input.split(' ').first.toLowerCase();
    return commands.contains(firstWord);
  }

  Future<bool> _processCommand(String command, List<String> args) async {
    // Check for help request (command ends with ? or last arg is ?)
    if (command == '?' || (args.isNotEmpty && args.last == '?')) {
      _showCommandHelp(command == '?' ? null : command, args.where((a) => a != '?').toList());
      return false;
    }

    // Context-specific commands when in /station
    if (_currentPath == '/station' || _currentPath.startsWith('/station/')) {
      switch (command) {
        case 'start':
          await _handleRelayStart();
          return false;
        case 'stop':
          await _handleRelayStop();
          return false;
        case 'port':
          await _handleRelayPort(args);
          return false;
        case 'cache':
          _handleRelayCache(args);
          return false;
        case 'callsign':
          await _handleRelayCallsign(args);
          return false;
      }
    }

    // Context-specific commands when in /chat/<room>
    if (_currentChatRoom != null) {
      switch (command) {
        case 'messages':
          await _handleChatHistory(args);
          return false;
        case 'delmsg':
          await _handleDeleteMessage(args);
          return false;
        case 'ls':
          await _handleChatHistory(args);
          return false;
      }
    }

    // Context-specific commands when in /ssl
    if (_currentPath == '/ssl') {
      switch (command) {
        case 'domain':
          await _handleSslDomain(args);
          return false;
        case 'email':
          await _handleSslEmail(args);
          return false;
        case 'request':
          await _handleSslRequest(staging: false);
          return false;
        case 'test':
          await _handleSslRequest(staging: true);
          return false;
        case 'renew':
          await _handleSslRenew();
          return false;
        case 'autorenew':
          await _handleSslAutoRenew(args);
          return false;
        case 'selfsigned':
          await _handleSslSelfSigned(args);
          return false;
        case 'enable':
          await _handleSslEnable(true);
          return false;
        case 'disable':
          await _handleSslEnable(false);
          return false;
        case 'status':
          await _showSslStatus();
          return false;
      }
    }

    // Context-specific commands when in /devices
    if (_currentPath == '/devices') {
      switch (command) {
        case 'list':
          _listDevices();
          return false;
        case 'scan':
          await _scanDevices(args);
          return false;
        case 'ping':
          if (args.isEmpty) {
            _printError('Usage: ping <ip[:port]>');
          } else {
            await _pingDevice(args[0]);
          }
          return false;
      }
    }

    // Context-specific commands when in /chat
    if (_currentPath == '/chat') {
      switch (command) {
        case 'list':
          await _listChatRooms();
          return false;
        case 'info':
          if (args.isEmpty) {
            _printError('Usage: info <room_id>');
          } else {
            await _showChatInfo(args[0]);
          }
          return false;
        case 'create':
          if (args.length < 2) {
            _printError('Usage: create <id> <name> [description]');
          } else {
            final desc = args.length > 2 ? args.sublist(2).join(' ') : null;
            await _createChatRoom(args[0], args[1], desc);
          }
          return false;
        case 'delete':
          if (args.isEmpty) {
            _printError('Usage: delete <room_id>');
          } else {
            await _deleteChatRoom(args[0]);
          }
          return false;
        case 'rename':
          if (args.length < 2) {
            _printError('Usage: rename <room_id> <new_name>');
          } else {
            await _renameChatRoom(args[0], args[1]);
          }
          return false;
        case 'history':
          if (args.isEmpty) {
            _printError('Usage: history <room_id> [limit]');
          } else {
            final limit = args.length > 1 ? int.tryParse(args[1]) : null;
            await _showChatHistory(args[0], limit ?? 50);
          }
          return false;
        case 'say':
          if (args.length < 2) {
            _printError('Usage: say <room_id> <message>');
          } else {
            await _postMessage(args[0], args.sublist(1).join(' '));
          }
          return false;
      }
    }

    // Context-specific commands when in /config
    if (_currentPath == '/config') {
      switch (command) {
        case 'set':
          if (args.length < 2) {
            _printError('Usage: set <key> <value>');
          } else {
            await _setConfig(args[0], args.sublist(1).join(' '));
          }
          return false;
        case 'show':
          _showConfigList();
          return false;
        case 'location':
          await _handleLocationDetect();
          return false;
      }
    }

    // Global commands
    switch (command) {
      case 'help':
      case '?':
        _printHelp();
        break;
      case 'status':
        _printStatus();
        break;
      case 'stats':
        _printStats();
        break;
      case 'ls':
        _handleLs(args);
        break;
      case 'cd':
        await _handleCd(args);
        break;
      case 'pwd':
        stdout.writeln(_currentPath);
        break;
      case 'station':
        await _handleRelay(args);
        break;
      case 'devices':
        await _handleDevices(args);
        break;
      case 'chat':
        await _handleChat(args);
        break;
      case 'config':
        await _handleConfig(args);
        break;
      case 'logs':
        _handleLogs(args);
        break;
      case 'broadcast':
        _handleBroadcast(args);
        break;
      case 'kick':
        _handleKick(args);
        break;
      case 'df':
        await _handleDf(args);
        break;
      case 'quiet':
        _station.quietMode = true;
        stdout.writeln('Quiet mode enabled');
        break;
      case 'verbose':
        _station.quietMode = false;
        stdout.writeln('Verbose mode enabled');
        break;
      case 'restart':
        await _station.restart();
        break;
      case 'reload':
        await _station.reloadSettings();
        stdout.writeln('Settings reloaded');
        break;
      case 'clear':
        stdout.write('\x1B[2J\x1B[H');
        break;
      case 'top':
        await _handleTop();
        break;
      case 'tail':
        await _handleTail(args);
        break;
      case 'head':
        await _handleHead(args);
        break;
      case 'cat':
        await _handleCat(args);
        break;
      case 'setup':
        await _handleSetup();
        break;
      case 'profile':
        await _handleProfile(args);
        break;
      case 'ssl':
        await _handleSsl(args);
        break;
      case 'play':
        await _handlePlay(args);
        break;
      case 'games':
        await _handleGames(args);
        break;
      case 'quit':
      case 'exit':
      case 'shutdown':
        await _cleanup();
        stdout.writeln('Goodbye!');
        exit(0);
      default:
        _printError('Unknown command: $command. Type "help" for available commands.');
    }
    return false;
  }

  void _printHelp() {
    stdout.writeln();
    stdout.writeln('\x1B[1mAvailable Commands:\x1B[0m');
    stdout.writeln();
    stdout.writeln('  \x1B[33mNavigation:\x1B[0m');
    stdout.writeln('    ls [path]          List directory contents');
    stdout.writeln('    cd <path>          Change directory');
    stdout.writeln('    pwd                Print working directory');
    stdout.writeln('    df [-h]            Show disk usage');
    stdout.writeln();
    stdout.writeln('  \x1B[33mStatus & Monitoring:\x1B[0m');
    stdout.writeln('    status             Show application status');
    stdout.writeln('    stats              Show detailed statistics');
    stdout.writeln('    top                Live monitoring dashboard (q to exit)');
    stdout.writeln('    logs [n]           Show last n log entries (default: 20)');
    stdout.writeln('    tail [-n N] [file] Show last N lines (default: 10, logs)');
    stdout.writeln('    head [-n N] [file] Show first N lines (default: 10, logs)');
    stdout.writeln('    cat <file>         Show entire file (logs, config, or path)');
    stdout.writeln('    quiet              Enable quiet mode (suppress logs)');
    stdout.writeln('    verbose            Enable verbose mode (show logs)');
    stdout.writeln();
    stdout.writeln('  \x1B[33mRelay Server:\x1B[0m');
    stdout.writeln('    station start        Start the station server');
    stdout.writeln('    station stop         Stop the station server');
    stdout.writeln('    station status       Show station server status');
    stdout.writeln('    station restart      Restart the station server');
    stdout.writeln('    station port <port>  Set station server port');
    stdout.writeln('    station callsign <cs> Set station callsign');
    stdout.writeln('    station cache clear  Clear tile cache');
    stdout.writeln('    station cache stats  Show cache statistics');
    stdout.writeln();
    stdout.writeln('  \x1B[33mDevice Management:\x1B[0m');
    stdout.writeln('    devices list       List connected devices');
    stdout.writeln('    devices scan       Scan network for devices');
    stdout.writeln('    devices ping <ip>  Ping a specific device');
    stdout.writeln('    devices kick <cs>  Disconnect a device');
    stdout.writeln();
    stdout.writeln('  \x1B[33mChat Management:\x1B[0m');
    stdout.writeln('    chat list          List all chat rooms');
    stdout.writeln('    chat info <id>     Show room details');
    stdout.writeln('    chat create <id> <name> [desc]  Create room');
    stdout.writeln('    chat delete <id>   Delete a chat room');
    stdout.writeln('    chat history <id> [n]  Show room messages');
    stdout.writeln('    chat say <id> <msg>    Post message to room');
    stdout.writeln();
    stdout.writeln('  \x1B[33mConfiguration:\x1B[0m');
    stdout.writeln('    config             Show current configuration');
    stdout.writeln('    config set <key> <value>  Set a config value');
    stdout.writeln('    config save        Save configuration to file');
    stdout.writeln('    reload             Reload config from file');
    stdout.writeln();
    stdout.writeln('  \x1B[33mSSL/TLS Certificates:\x1B[0m');
    stdout.writeln('    ssl                Show SSL status');
    stdout.writeln('    ssl domain <name>  Set domain for SSL certificate');
    stdout.writeln('    ssl email <addr>   Set email for Let\'s Encrypt');
    stdout.writeln('    ssl request        Request Let\'s Encrypt certificate');
    stdout.writeln('    ssl test           Request test certificate (staging)');
    stdout.writeln('    ssl renew          Renew existing certificate');
    stdout.writeln('    ssl autorenew <on|off>  Enable/disable auto-renewal');
    stdout.writeln('    ssl selfsigned <domain> Generate self-signed cert');
    stdout.writeln('    ssl enable         Enable SSL/HTTPS');
    stdout.writeln('    ssl disable        Disable SSL/HTTPS');
    stdout.writeln();
    stdout.writeln('  \x1B[33mGames:\x1B[0m');
    stdout.writeln('    play <game.md>     Play a markdown game');
    stdout.writeln('    games list         List available games');
    stdout.writeln('    games info <game>  Show game details');
    stdout.writeln();
    stdout.writeln('  \x1B[33mConnection:\x1B[0m');
    stdout.writeln('    kick <callsign>    Disconnect a device');
    stdout.writeln('    broadcast <msg>    Send message to all devices');
    stdout.writeln();
    stdout.writeln('  \x1B[33mSystem:\x1B[0m');
    stdout.writeln('    setup              Run the setup wizard');
    stdout.writeln('    restart            Restart the station server');
    stdout.writeln('    clear              Clear the screen');
    stdout.writeln('    quit / exit        Exit the CLI');
    stdout.writeln();
    stdout.writeln('  \x1B[33mVirtual Filesystem:\x1B[0m');
    stdout.writeln('    /station/            Station status and settings');
    stdout.writeln('    /devices/          Connected devices');
    stdout.writeln('    /chat/             Chat rooms (cd into room to chat)');
    stdout.writeln('    /config/           Configuration');
    stdout.writeln('    /logs/             View logs');
    stdout.writeln('    /ssl/              SSL/TLS certificates (cd ssl, then run commands)');
    stdout.writeln('    /games/            Markdown-based text adventure games');
    stdout.writeln();
    stdout.writeln('  \x1B[90mTip: Type "command ?" for syntax help (e.g., "chat create ?")\x1B[0m');
    stdout.writeln();
  }

  /// Show help for a specific command
  void _showCommandHelp(String? command, List<String> subArgs) {
    String helpKey;

    if (command == null) {
      // Just "?" was typed - show general help
      _printHelp();
      return;
    }

    // Build the help key based on command and subcommand
    if (subArgs.isNotEmpty) {
      // Try "command subcommand" first (e.g., "chat create")
      helpKey = '$command ${subArgs.first}';
      if (!commandHelp.containsKey(helpKey)) {
        // Fall back to just the subcommand for context-specific help
        helpKey = subArgs.first;
      }
    } else {
      helpKey = command;
    }

    final help = commandHelp[helpKey];
    if (help != null) {
      stdout.writeln();
      stdout.writeln('\x1B[1mSyntax:\x1B[0m $help');
      stdout.writeln();
    } else {
      stdout.writeln();
      stdout.writeln('\x1B[33mNo help available for "$helpKey"\x1B[0m');
      stdout.writeln('Type "help" for a list of available commands.');
      stdout.writeln();
    }
  }

  void _printStatus() {
    final stationStatus = _station.getStatus();

    stdout.writeln();
    stdout.writeln('\x1B[1mGeogram Desktop Status\x1B[0m');
    stdout.writeln('-' * 40);
    stdout.writeln('Version:        $cliAppVersion');
    stdout.writeln('Callsign:       ${_station.settings.callsign}');
    stdout.writeln('Mode:           Station (CLI)');
    stdout.writeln('Data Dir:       ${_station.dataDir}');
    stdout.writeln();
    stdout.writeln('\x1B[1mRelay Server:\x1B[0m');
    stdout.writeln('-' * 40);
    if (stationStatus['running'] == true) {
      stdout.writeln('Status:         \x1B[32mRunning\x1B[0m');
      stdout.writeln('HTTP Port:      ${stationStatus['httpPort']}');
      stdout.writeln('HTTPS Port:     ${stationStatus['httpsPort']}');
      stdout.writeln('Devices:        ${stationStatus['connected_devices']}');
      stdout.writeln('Uptime:         ${_formatUptime(stationStatus['uptime'] as int)}');
      stdout.writeln('Cache:          ${stationStatus['cache_size']} tiles (${stationStatus['cache_size_mb']} MB)');
      stdout.writeln('Chat Rooms:     ${stationStatus['chat_rooms']}');
      stdout.writeln('Messages:       ${stationStatus['total_messages']}');
    } else {
      stdout.writeln('Status:         \x1B[33mStopped\x1B[0m');
      stdout.writeln('HTTP Port:      ${_station.settings.httpPort}');
      stdout.writeln('HTTPS Port:     ${_station.settings.httpsPort}');
    }
    stdout.writeln();
  }

  void _printStats() {
    final stats = _station.stats;

    stdout.writeln();
    stdout.writeln('\x1B[1mServer Statistics\x1B[0m');
    stdout.writeln('-' * 40);
    stdout.writeln('Total Connections:     ${stats.totalConnections}');
    stdout.writeln('Total Messages:        ${stats.totalMessages}');
    stdout.writeln('Total API Requests:    ${stats.totalApiRequests}');
    stdout.writeln('Total Tile Requests:   ${stats.totalTileRequests}');
    stdout.writeln();
    stdout.writeln('\x1B[1mTile Cache:\x1B[0m');
    stdout.writeln('-' * 40);
    stdout.writeln('Tiles Cached:          ${stats.tilesCached}');
    stdout.writeln('Served from Cache:     ${stats.tilesServedFromCache}');
    stdout.writeln('Downloaded:            ${stats.tilesDownloaded}');
    stdout.writeln();
    stdout.writeln('\x1B[1mLast Activity:\x1B[0m');
    stdout.writeln('-' * 40);
    stdout.writeln('Last Connection:       ${stats.lastConnection?.toLocal() ?? 'Never'}');
    stdout.writeln('Last Message:          ${stats.lastMessage?.toLocal() ?? 'Never'}');
    stdout.writeln('Last Tile Request:     ${stats.lastTileRequest?.toLocal() ?? 'Never'}');
    stdout.writeln();
  }

  // --- Station commands ---

  /// Check if station commands are allowed in current context
  bool _isRelayContextAllowed() {
    // Check if active profile is a station
    final activeProfile = _profileService.activeProfile;
    if (activeProfile != null && activeProfile.isRelay) {
      return true;
    }

    // Check if we're inside a managed station's device folder
    if (_currentPath.startsWith('/devices/')) {
      final parts = _currentPath.split('/');
      if (parts.length >= 3) {
        final callsign = parts[2];
        if (_profileService.isManagedRelay(callsign)) {
          return true;
        }
      }
    }

    return false;
  }

  /// Get the station callsign from current context
  String? _getStationCallsignFromContext() {
    // First check if we're in a device folder
    if (_currentPath.startsWith('/devices/')) {
      final parts = _currentPath.split('/');
      if (parts.length >= 3) {
        final callsign = parts[2];
        if (_profileService.isManagedRelay(callsign)) {
          return callsign;
        }
      }
    }

    // Fall back to active profile if it's a station
    final activeProfile = _profileService.activeProfile;
    if (activeProfile != null && activeProfile.isRelay) {
      return activeProfile.callsign;
    }

    return null;
  }

  Future<void> _handleRelay(List<String> args) async {
    // Check if station commands are allowed
    if (!_isRelayContextAllowed()) {
      _printError('Station commands require a station profile or being in a managed station folder.');
      stdout.writeln('Current profile: ${_profileService.activeProfile?.callsign ?? "none"}');
      stdout.writeln();
      stdout.writeln('Options:');
      stdout.writeln('  - Create a station profile: \x1B[36msetup\x1B[0m (choose option 2)');
      stdout.writeln('  - Switch to a station profile: \x1B[36mprofile switch <station-callsign>\x1B[0m');
      stdout.writeln('  - Navigate to a managed station: \x1B[36mcd /devices/<station-callsign>\x1B[0m');
      return;
    }

    if (args.isEmpty) {
      _printRelayStatus();
      return;
    }

    final subcommand = args[0].toLowerCase();
    final subargs = args.length > 1 ? args.sublist(1) : <String>[];

    switch (subcommand) {
      case 'start':
        await _handleRelayStart();
        break;
      case 'stop':
        await _handleRelayStop();
        break;
      case 'status':
        _printRelayStatus();
        break;
      case 'restart':
        await _station.restart();
        break;
      case 'port':
        await _handleRelayPort(subargs);
        break;
      case 'callsign':
        await _handleRelayCallsign(subargs);
        break;
      case 'cache':
        _handleRelayCache(subargs);
        break;
      default:
        _printError('Unknown station command: $subcommand');
        _printError('Available: start, stop, status, restart, port, callsign, cache');
    }
  }

  Future<void> _handleRelayStart() async {
    if (_station.isRunning) {
      stdout.writeln('\x1B[33mRelay server is already running on port ${_station.settings.httpPort}\x1B[0m');
      return;
    }

    stdout.writeln('Starting station server on port ${_station.settings.httpPort}...');
    final success = await _station.start();

    if (success) {
      stdout.writeln('\x1B[32mRelay server started successfully\x1B[0m');
      stdout.writeln('  HTTP Port:  ${_station.settings.httpPort}');
      stdout.writeln('  HTTPS Port: ${_station.settings.httpsPort}');
      stdout.writeln('  Callsign: ${_station.settings.callsign}');
      stdout.writeln('  Status: http://localhost:${_station.settings.httpPort}/api/status');
      stdout.writeln('  Tiles:  http://localhost:${_station.settings.httpPort}/tiles/{callsign}/{z}/{x}/{y}.png');
    } else {
      _printError('Failed to start station server');
    }
  }

  Future<void> _handleRelayStop() async {
    if (!_station.isRunning) {
      stdout.writeln('\x1B[33mRelay server is not running\x1B[0m');
      return;
    }

    stdout.writeln('Stopping station server...');
    await _station.stop();
    stdout.writeln('\x1B[32mRelay server stopped\x1B[0m');
  }

  void _printRelayStatus() {
    final status = _station.getStatus();
    final settings = _station.settings;

    stdout.writeln();
    stdout.writeln('\x1B[1mRelay Server Status\x1B[0m');
    stdout.writeln('-' * 40);

    if (status['running'] == true) {
      stdout.writeln('Status:        \x1B[32mRunning\x1B[0m');
      stdout.writeln('Port:          ${status['port']}');
      stdout.writeln('Callsign:      ${status['callsign']}');
      stdout.writeln('Devices:       ${status['connected_devices']}');
      stdout.writeln('Uptime:        ${_formatUptime(status['uptime'] as int)}');
      stdout.writeln('Cache:         ${status['cache_size']} tiles (${status['cache_size_mb']} MB)');
    } else {
      stdout.writeln('Status:        \x1B[33mStopped\x1B[0m');
    }

    stdout.writeln();
    stdout.writeln('\x1B[1mSettings:\x1B[0m');
    stdout.writeln('-' * 40);
    stdout.writeln('HTTP Port:     ${settings.httpPort}');
    stdout.writeln('HTTPS Port:    ${settings.httpsPort}');
    stdout.writeln('Callsign:      ${settings.callsign}');
    stdout.writeln('Description:   ${settings.description ?? '(not set)'}');
    stdout.writeln('Location:      ${settings.location ?? '(not set)'}');
    stdout.writeln('Tile Server:   ${settings.tileServerEnabled ? 'Enabled' : 'Disabled'}');
    stdout.writeln('OSM Fallback:  ${settings.osmFallbackEnabled ? 'Enabled' : 'Disabled'}');
    stdout.writeln('Max Zoom:      ${settings.maxZoomLevel}');
    stdout.writeln('Max Cache:     ${settings.maxCacheSizeMB} MB');
    stdout.writeln('APRS:          ${settings.enableAprs ? 'Enabled' : 'Disabled'}');
    stdout.writeln('CORS:          ${settings.enableCors ? 'Enabled' : 'Disabled'}');
    stdout.writeln();
  }

  Future<void> _handleRelayPort(List<String> args) async {
    if (args.isEmpty) {
      stdout.writeln('Current HTTP port: ${_station.settings.httpPort}');
      stdout.writeln('Current HTTPS port: ${_station.settings.httpsPort}');
      return;
    }

    final port = int.tryParse(args[0]);
    if (port == null || port < 1 || port > 65535) {
      _printError('Invalid port number: ${args[0]} (must be 1-65535)');
      return;
    }

    final settings = _station.settings.copyWith(httpPort: port);
    await _station.updateSettings(settings);
    stdout.writeln('\x1B[32mPort set to $port\x1B[0m');
  }

  Future<void> _handleRelayCallsign(List<String> args) async {
    // Callsign is derived from npub (X3 prefix for stations) - cannot be set manually
    stdout.writeln('Station callsign: ${_station.settings.callsign}');
    stdout.writeln('  (derived from npub: ${_station.settings.npub.substring(0, 20)}...)');
    if (args.isNotEmpty) {
      _printError('Callsign cannot be set manually - it is derived from the station key pair');
    }
  }

  void _handleRelayCache(List<String> args) {
    if (args.isEmpty) {
      final status = _station.getStatus();
      stdout.writeln('Cache: ${status['cache_size']} tiles (${status['cache_size_mb']} MB)');
      return;
    }

    switch (args[0].toLowerCase()) {
      case 'clear':
        _station.clearCache();
        stdout.writeln('\x1B[32mCache cleared\x1B[0m');
        break;
      case 'stats':
        final stats = _station.stats;
        stdout.writeln();
        stdout.writeln('\x1B[1mCache Statistics\x1B[0m');
        stdout.writeln('-' * 30);
        stdout.writeln('Tiles Cached:       ${stats.tilesCached}');
        stdout.writeln('Served from Cache:  ${stats.tilesServedFromCache}');
        stdout.writeln('Downloaded:         ${stats.tilesDownloaded}');
        stdout.writeln('Max Size:           ${_station.settings.maxCacheSizeMB} MB');
        stdout.writeln();
        break;
      default:
        _printError('Unknown cache command. Available: clear, stats');
    }
  }

  // --- Device commands ---

  Future<void> _handleDevices(List<String> args) async {
    if (args.isEmpty) {
      _listDevices();
      return;
    }

    switch (args[0].toLowerCase()) {
      case 'list':
        _listDevices();
        break;
      case 'scan':
        await _scanDevices(args.length > 1 ? args.sublist(1) : []);
        break;
      case 'ping':
        if (args.length < 2) {
          _printError('Usage: devices ping <ip[:port]>');
        } else {
          await _pingDevice(args[1]);
        }
        break;
      default:
        _printError('Unknown devices command. Available: list, scan, ping');
    }
  }

  void _listDevices() {
    stdout.writeln();

    // Get all devices sorted (owned first, then cached)
    final allDevices = _profileService.getAllDevicesSorted();

    // Section 1: My Devices (owned profiles)
    final ownedDevices = allDevices.where((d) => d['owned'] == true).toList();
    stdout.writeln('\x1B[1mMy Devices (${ownedDevices.length})\x1B[0m');
    stdout.writeln('-' * 60);

    if (ownedDevices.isEmpty) {
      stdout.writeln('  No profiles configured. Run "setup" to create one.');
    } else {
      for (final device in ownedDevices) {
        final isActive = device['active'] == true;
        final activeMarker = isActive ? '\x1B[32m*\x1B[0m' : ' ';
        final typeStr = device['type'] == 'station' ? '\x1B[33mstation\x1B[0m' : '\x1B[36mclient\x1B[0m';
        final callsign = device['callsign'] as String;
        final nickname = device['nickname'] as String;
        final displayName = nickname.isNotEmpty ? '$callsign ($nickname)' : callsign;
        stdout.writeln('$activeMarker \x1B[1m$displayName\x1B[0m - $typeStr');
      }
    }
    stdout.writeln();

    // Section 2: Cached/Known Devices
    final cachedDevices = allDevices.where((d) => d['owned'] != true).toList();
    if (cachedDevices.isNotEmpty) {
      stdout.writeln('\x1B[1mKnown Devices (${cachedDevices.length})\x1B[0m');
      stdout.writeln('-' * 60);
      for (final device in cachedDevices) {
        final callsign = device['callsign'] as String;
        final typeStr = device['type'] ?? 'unknown';
        stdout.writeln('  $callsign - $typeStr');
      }
      stdout.writeln();
    }

    // Section 3: Currently Connected (station clients)
    final clients = _station.clients;
    stdout.writeln('\x1B[1mConnected Now (${clients.length})\x1B[0m');
    stdout.writeln('-' * 60);

    if (clients.isEmpty) {
      stdout.writeln('  No devices connected to this station');
    } else {
      for (final client in clients.values) {
        final connectedAgo = DateTime.now().difference(client.connectedAt);
        final isOwned = _profileService.isOwnedCallsign(client.callsign ?? '');
        final ownedMarker = isOwned ? '\x1B[32m*\x1B[0m' : ' ';
        stdout.writeln(
          '$ownedMarker ${(client.callsign ?? 'Unknown').padRight(12)} '
          '${(client.deviceType ?? '-').padRight(10)} '
          '${_formatDuration(connectedAgo)} ago'
        );
      }
    }
    stdout.writeln();
  }

  Future<void> _scanDevices(List<String> args) async {
    int timeout = 2000;
    for (int i = 0; i < args.length - 1; i++) {
      if (args[i] == '-t') {
        timeout = int.tryParse(args[i + 1]) ?? 2000;
      }
    }

    stdout.writeln('Scanning network for Geogram devices (timeout: ${timeout}ms)...');
    final devices = await _station.scanNetwork(timeout: timeout);

    stdout.writeln();
    stdout.writeln('\x1B[1mDiscovered Devices (${devices.length})\x1B[0m');
    stdout.writeln('-' * 60);

    if (devices.isEmpty) {
      stdout.writeln('No devices found');
    } else {
      for (final device in devices) {
        stdout.writeln(
          '${device['callsign'].toString().padRight(12)} '
          '${device['type'].toString().padRight(8)} '
          '${device['ip']}:${device['port']} '
          'v${device['version']}'
        );
      }
    }
    stdout.writeln();
  }

  Future<void> _pingDevice(String address) async {
    stdout.writeln('Pinging $address...');
    final result = await _station.pingDevice(address);

    if (result != null) {
      stdout.writeln();
      stdout.writeln('\x1B[32mDevice found:\x1B[0m');
      stdout.writeln('  Callsign: ${result['callsign']}');
      stdout.writeln('  Type:     ${result['type']}');
      stdout.writeln('  Name:     ${result['name']}');
      stdout.writeln('  Version:  ${result['version']}');
      stdout.writeln('  Address:  ${result['ip']}:${result['port']}');
    } else {
      _printError('Device not responding at $address');
    }
  }

  void _handleKick(List<String> args) {
    if (args.isEmpty) {
      _printError('Usage: kick <callsign>');
      return;
    }

    final callsign = args[0];
    if (_station.kickDevice(callsign)) {
      stdout.writeln('\x1B[32mDevice $callsign disconnected\x1B[0m');
    } else {
      _printError('Device not found: $callsign');
    }
  }

  // --- Chat commands ---

  Future<void> _handleChat(List<String> args) async {
    if (args.isEmpty) {
      await _listChatRooms();
      return;
    }

    switch (args[0].toLowerCase()) {
      case 'list':
        await _listChatRooms();
        break;
      case 'info':
        if (args.length < 2) {
          _printError('Usage: chat info <room_id>');
        } else {
          await _showChatInfo(args[1]);
        }
        break;
      case 'create':
        if (args.length < 3) {
          _printError('Usage: chat create <id> <name> [description]');
        } else {
          final desc = args.length > 3 ? args.sublist(3).join(' ') : null;
          await _createChatRoom(args[1], args[2], desc);
        }
        break;
      case 'delete':
        if (args.length < 2) {
          _printError('Usage: chat delete <room_id>');
        } else {
          await _deleteChatRoom(args[1]);
        }
        break;
      case 'rename':
        if (args.length < 3) {
          _printError('Usage: chat rename <old_id> <new_name>');
        } else {
          await _renameChatRoom(args[1], args[2]);
        }
        break;
      case 'history':
        if (args.length < 2) {
          _printError('Usage: chat history <room_id> [count]');
        } else {
          await _showChatHistory(args[1], args.length > 2 ? int.tryParse(args[2]) : null);
        }
        break;
      case 'say':
        if (args.length < 3) {
          _printError('Usage: chat say <room_id> <message>');
        } else {
          await _postMessage(args[1], args.sublist(2).join(' '));
        }
        break;
      case 'delmsg':
        if (args.length < 3) {
          _printError('Usage: chat delmsg <room_id> <message_id>');
        } else {
          await _handleDeleteMessage([args[1], args[2]]);
        }
        break;
      default:
        _printError('Unknown chat command. Available: list, info, create, delete, rename, history, say, delmsg');
    }
  }

  Future<void> _listChatRooms() async {
    // Use station's chat rooms in CLI mode
    final rooms = _station.chatRooms.values.toList();

    stdout.writeln();
    stdout.writeln('\x1B[1mChat Rooms (${rooms.length})\x1B[0m');
    stdout.writeln('-' * 50);

    for (final room in rooms) {
      stdout.writeln(
        '${room.id.padRight(15)} '
        '${room.name.padRight(20)} '
        '${room.messages.length} msgs'
      );
    }
    stdout.writeln();
  }

  Future<void> _showChatInfo(String roomId) async {
    // Use station's chat rooms in CLI mode
    final room = _station.chatRooms[roomId];
    if (room == null) {
      _printError('Room not found: $roomId');
      return;
    }

    stdout.writeln();
    stdout.writeln('\x1B[1mChat Room: ${room.name}\x1B[0m');
    stdout.writeln('-' * 40);
    stdout.writeln('ID:          ${room.id}');
    stdout.writeln('Name:        ${room.name}');
    stdout.writeln('Description: ${room.description.isEmpty ? '(none)' : room.description}');
    stdout.writeln('Creator:     ${room.creatorCallsign}');
    stdout.writeln('Created:     ${room.createdAt.toLocal()}');
    stdout.writeln('Last Active: ${room.lastActivity.toLocal()}');
    stdout.writeln('Messages:    ${room.messages.length}');
    stdout.writeln('Public:      ${room.isPublic ? 'Yes' : 'No'}');
    stdout.writeln();
  }

  Future<void> _createChatRoom(String id, String name, String? description) async {
    // Use station's chat room management in CLI mode
    final room = _station.createChatRoom(id, name, description: description);
    if (room != null) {
      stdout.writeln('\x1B[32mChat room created: $name ($id)\x1B[0m');
    } else {
      _printError('Room with ID "$id" already exists');
    }
  }

  Future<void> _deleteChatRoom(String id) async {
    // Use station's chat room management in CLI mode
    if (id == 'general') {
      _printError('Cannot delete the general room');
      return;
    }
    if (_station.deleteChatRoom(id)) {
      stdout.writeln('\x1B[32mChat room deleted: $id\x1B[0m');
    } else {
      _printError('Room not found: $id');
    }
  }

  Future<void> _renameChatRoom(String id, String newName) async {
    // Use station's chat room management in CLI mode
    if (_station.renameChatRoom(id, newName)) {
      stdout.writeln('\x1B[32mRoom renamed to: $newName\x1B[0m');
    } else {
      _printError('Room not found: $id');
    }
  }

  Future<void> _showChatHistory(String roomId, int? limit) async {
    // Use station's chat rooms in CLI mode
    final room = _station.chatRooms[roomId];
    if (room == null) {
      _printError('Room not found: $roomId');
      return;
    }

    final messages = room.messages;
    if (messages.isEmpty) {
      return; // Silent if no messages
    }

    // Get last N messages
    final count = limit ?? 20;
    final startIdx = messages.length > count ? messages.length - count : 0;
    final recentMessages = messages.sublist(startIdx);

    for (final msg in recentMessages) {
      final time = msg.timestamp.toLocal();
      final timeStr = '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

      // Determine verification indicator
      String verifyIndicator;
      if (msg.hasSignature) {
        final isVerified = _station.verifyMessage(msg);
        verifyIndicator = isVerified ? '\x1B[32m✓\x1B[0m' : '\x1B[31m✗\x1B[0m';
      } else {
        verifyIndicator = '\x1B[90m○\x1B[0m'; // No signature (gray circle)
      }

      stdout.writeln('\x1B[33m[$timeStr]\x1B[0m $verifyIndicator \x1B[36m${msg.senderCallsign}:\x1B[0m ${msg.content}');
    }
  }

  Future<void> _postMessage(String roomId, String message) async {
    // Use station's chat room management in CLI mode
    if (_station.chatRooms[roomId] == null) {
      _printError('Room not found: $roomId');
      return;
    }

    await _station.postMessage(roomId, message);
    stdout.writeln('Message sent');
  }

  Future<void> _handleChatHistory(List<String> args) async {
    if (_currentChatRoom == null) return;
    final limit = args.isNotEmpty ? int.tryParse(args[0]) : null;
    await _showChatHistory(_currentChatRoom!, limit);
  }

  Future<void> _handleDeleteMessage(List<String> args) async {
    if (_currentChatRoom == null || args.isEmpty) return;

    // Use station's chat room management in CLI mode
    final messageId = args[0];
    if (_station.deleteMessage(_currentChatRoom!, messageId)) {
      stdout.writeln('\x1B[32mMessage deleted\x1B[0m');
    } else {
      _printError('Message not found');
    }
  }

  // --- Config commands ---

  Future<void> _handleConfig(List<String> args) async {
    if (args.isEmpty) {
      _showConfigList();
      return;
    }

    switch (args[0].toLowerCase()) {
      case 'set':
        if (args.length < 3) {
          _printError('Usage: set <key> <value>');
        } else {
          await _setConfig(args[1], args.sublist(2).join(' '));
        }
        break;
      case 'show':
        _showConfigList();
        break;
      default:
        _printError('Unknown config command. Available: set, show');
    }
  }

  /// Get the current value of a config key from the profile
  dynamic _getConfigValue(String key) {
    final profile = _profileService.activeProfile;
    if (profile == null) return null;

    switch (key) {
      case 'nickname': return profile.nickname;
      case 'description': return profile.description;
      case 'preferredColor': return profile.preferredColor;
      case 'latitude': return profile.latitude;
      case 'longitude': return profile.longitude;
      case 'locationName': return profile.locationName;
      case 'enableAprs': return profile.enableAprs;
      // Station settings
      case 'httpPort': return _station.settings.httpPort;
      case 'httpsPort': return _station.settings.httpsPort;
      case 'tileServerEnabled': return profile.tileServerEnabled;
      case 'osmFallbackEnabled': return profile.osmFallbackEnabled;
      case 'maxZoomLevel': return _station.settings.maxZoomLevel;
      case 'maxCacheSizeMB': return _station.settings.maxCacheSizeMB;
      case 'enableCors': return _station.settings.enableCors;
      case 'maxConnectedDevices': return _station.settings.maxConnectedDevices;
      default: return null;
    }
  }

  /// Show config keys with values (for ls in /config)
  void _showConfigList() {
    final keys = configKeys;
    final maxKeyLen = keys.map((k) => k.length).reduce((a, b) => a > b ? a : b);

    for (final key in keys) {
      final value = _getConfigValue(key);
      final type = configKeyTypes[key] ?? 'string';
      final valueStr = value?.toString() ?? '\x1B[90m(not set)\x1B[0m';
      final typeStr = '\x1B[90m[$type]\x1B[0m';

      stdout.writeln('${key.padRight(maxKeyLen)}  $valueStr  $typeStr');
    }
  }

  /// Validate a value against the expected type
  String? _validateConfigValue(String key, String value) {
    final type = configKeyTypes[key];
    if (type == null) {
      return 'Unknown config key: $key';
    }

    switch (type) {
      case 'bool':
        if (value.toLowerCase() != 'true' && value.toLowerCase() != 'false') {
          return '$key must be true or false';
        }
        break;
      case 'int':
        if (int.tryParse(value) == null) {
          return '$key must be an integer';
        }
        break;
      case 'double':
        if (double.tryParse(value) == null) {
          return '$key must be a number';
        }
        break;
      case 'string':
        // Any string is valid
        break;
    }
    return null;
  }

  Future<void> _setConfig(String key, String value) async {
    // Check if key is valid for this profile type
    if (!configKeys.contains(key)) {
      _printError('Unknown config key: $key');
      _printError('Available keys: ${configKeys.join(', ')}');
      return;
    }

    // Validate value
    final error = _validateConfigValue(key, value);
    if (error != null) {
      _printError(error);
      return;
    }

    try {
      // Parse value based on type
      final type = configKeyTypes[key]!;
      dynamic parsedValue;
      switch (type) {
        case 'bool':
          parsedValue = value.toLowerCase() == 'true';
          break;
        case 'int':
          parsedValue = int.parse(value);
          break;
        case 'double':
          parsedValue = double.parse(value);
          break;
        default:
          parsedValue = value;
      }

      // Update the profile
      final profile = _profileService.activeProfile;
      if (profile != null) {
        Profile updatedProfile;
        switch (key) {
          case 'nickname':
            updatedProfile = profile.copyWith(nickname: parsedValue);
            break;
          case 'description':
            updatedProfile = profile.copyWith(description: parsedValue);
            break;
          case 'preferredColor':
            updatedProfile = profile.copyWith(preferredColor: parsedValue);
            break;
          case 'latitude':
            updatedProfile = profile.copyWith(latitude: parsedValue);
            break;
          case 'longitude':
            updatedProfile = profile.copyWith(longitude: parsedValue);
            break;
          case 'locationName':
            updatedProfile = profile.copyWith(locationName: parsedValue);
            break;
          case 'enableAprs':
            updatedProfile = profile.copyWith(enableAprs: parsedValue);
            break;
          case 'port':
            updatedProfile = profile.copyWith(port: parsedValue);
            _station.setSetting(key, parsedValue);
            break;
          case 'tileServerEnabled':
            updatedProfile = profile.copyWith(tileServerEnabled: parsedValue);
            break;
          case 'osmFallbackEnabled':
            updatedProfile = profile.copyWith(osmFallbackEnabled: parsedValue);
            break;
          default:
            // Station-only settings stored in station settings
            _station.setSetting(key, parsedValue);
            stdout.writeln('\x1B[32m$key set to $value\x1B[0m');
            return;
        }

        await _profileService.updateProfile(updatedProfile);
        stdout.writeln('\x1B[32m$key set to $value\x1B[0m');
      }
    } catch (e) {
      _printError('Failed to set $key: $e');
    }
  }

  /// Auto-detect location via IP address
  Future<void> _handleLocationDetect() async {
    stdout.writeln('Detecting location via IP address...');

    final locationService = CliLocationService();
    final result = await locationService.detectLocationViaIP();

    if (result == null) {
      _printError('Failed to detect location. Please check your internet connection.');
      return;
    }

    // Update profile with detected location
    final profile = _profileService.activeProfile;
    if (profile == null) {
      _printError('No active profile');
      return;
    }

    final updatedProfile = profile.copyWith(
      latitude: result.latitude,
      longitude: result.longitude,
      locationName: result.locationName,
    );

    await _profileService.updateProfile(updatedProfile);

    // Also update station settings so /status endpoint returns coordinates
    final updatedStationSettings = _station.settings.copyWith(
      latitude: result.latitude,
      longitude: result.longitude,
      location: result.locationName,
    );
    await _station.updateSettings(updatedStationSettings);

    stdout.writeln('\x1B[32mLocation detected successfully:\x1B[0m');
    stdout.writeln('  Location: ${result.locationName}');
    stdout.writeln('  Latitude: ${result.latitude}');
    stdout.writeln('  Longitude: ${result.longitude}');
  }

  // --- Logs command ---

  void _handleLogs(List<String> args) {
    final limit = args.isNotEmpty ? int.tryParse(args[0]) ?? 20 : 20;
    final logs = _station.getLogs(limit: limit);

    stdout.writeln();
    stdout.writeln('\x1B[1mRecent Logs (${logs.length})\x1B[0m');
    stdout.writeln('-' * 60);

    if (logs.isEmpty) {
      stdout.writeln('No logs available');
    } else {
      for (final log in logs) {
        final levelColor = switch (log.level) {
          'ERROR' => '\x1B[31m',
          'WARN' => '\x1B[33m',
          'INFO' => '\x1B[32m',
          _ => '\x1B[0m',
        };
        final time = log.timestamp.toLocal();
        final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
        stdout.writeln('$timeStr $levelColor[${log.level}]\x1B[0m ${log.message}');
      }
    }
    stdout.writeln();
  }

  // --- Broadcast command ---

  void _handleBroadcast(List<String> args) {
    if (args.isEmpty) {
      _printError('Usage: broadcast <message>');
      return;
    }

    final message = args.join(' ');
    _station.broadcast(message);
    stdout.writeln('\x1B[32mBroadcast sent to ${_station.connectedDevices} devices\x1B[0m');
  }

  // --- Disk usage command ---

  Future<void> _handleDf(List<String> args) async {
    final humanReadable = args.contains('-h');
    final dataDir = _station.dataDir;

    if (dataDir == null) {
      _printError('Data directory not initialized');
      return;
    }

    stdout.writeln();
    stdout.writeln('\x1B[1mDisk Usage\x1B[0m');
    stdout.writeln('-' * 50);

    // Calculate directory sizes
    final tilesDir = Directory('$dataDir/tiles');
    int tilesSize = 0;
    if (await tilesDir.exists()) {
      await for (final entity in tilesDir.list(recursive: true)) {
        if (entity is File) {
          tilesSize += await entity.length();
        }
      }
    }

    final configFile = File('$dataDir/station_config.json');
    final configSize = await configFile.exists() ? await configFile.length() : 0;

    final total = tilesSize + configSize;

    if (humanReadable) {
      stdout.writeln('Tiles:  ${_formatBytes(tilesSize)}');
      stdout.writeln('Config: ${_formatBytes(configSize)}');
      stdout.writeln('Total:  ${_formatBytes(total)}');
    } else {
      stdout.writeln('Tiles:  $tilesSize bytes');
      stdout.writeln('Config: $configSize bytes');
      stdout.writeln('Total:  $total bytes');
    }
    stdout.writeln();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  // --- Top command (live monitoring dashboard) ---

  Future<void> _handleTop() async {
    stdout.writeln('Live monitoring - press q to exit');
    stdout.writeln();

    _console.rawMode = true;
    try {
      var running = true;
      while (running) {
        // Clear screen and move cursor to top
        stdout.write('\x1B[2J\x1B[H');

        // Header
        stdout.writeln('\x1B[1;36m=== Geogram Desktop - Live Monitor ===\x1B[0m');
        stdout.writeln('\x1B[33mPress q to exit\x1B[0m');
        stdout.writeln();

        // Status section
        final status = _station.getStatus();
        final stationStatus = status['running'] == true
            ? '\x1B[32mRunning\x1B[0m'
            : '\x1B[33mStopped\x1B[0m';
        stdout.writeln('\x1B[1mRelay:\x1B[0m $stationStatus  '
            '\x1B[1mPort:\x1B[0m ${status['port']}  '
            '\x1B[1mDevices:\x1B[0m ${status['connected_devices']}  '
            '\x1B[1mUptime:\x1B[0m ${_formatUptime(status['uptime'] as int)}');
        stdout.writeln();

        // Stats section
        final stats = _station.stats;
        stdout.writeln('\x1B[1mStats:\x1B[0m  '
            'Connections: ${stats.totalConnections}  '
            'Messages: ${stats.totalMessages}  '
            'API: ${stats.totalApiRequests}  '
            'Tiles: ${stats.totalTileRequests}');
        stdout.writeln();

        // Recent logs
        stdout.writeln('\x1B[1mRecent Logs:\x1B[0m');
        stdout.writeln('-' * 60);
        final logs = _station.getLogs(limit: 15);
        if (logs.isEmpty) {
          stdout.writeln('(no logs)');
        } else {
          for (final log in logs) {
            final levelColor = switch (log.level) {
              'ERROR' => '\x1B[31m',
              'WARN' => '\x1B[33m',
              'INFO' => '\x1B[32m',
              _ => '\x1B[0m',
            };
            final time = log.timestamp.toLocal();
            final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
            stdout.writeln('$timeStr $levelColor[${log.level}]\x1B[0m ${log.message}');
          }
        }

        // Check for q key (non-blocking)
        // Wait for up to 1 second, checking for input
        final stopwatch = Stopwatch()..start();
        while (stopwatch.elapsedMilliseconds < 1000) {
          // Check if there's input available
          if (stdin.hasTerminal) {
            try {
              final key = _console.readKey();
              if (key.char.toLowerCase() == 'q') {
                running = false;
                break;
              }
            } catch (_) {
              // No input available, continue waiting
            }
          }
          await Future.delayed(Duration(milliseconds: 100));
        }
      }
    } finally {
      _console.rawMode = false;
    }

    stdout.writeln();
    stdout.writeln('Exited live monitor');
  }

  // --- File viewing commands (tail, head, cat) ---

  Future<void> _handleTail(List<String> args) async {
    int lines = 10;
    String? target;

    // Parse arguments: tail [-n lines] [target]
    var i = 0;
    while (i < args.length) {
      if (args[i] == '-n' && i + 1 < args.length) {
        lines = int.tryParse(args[i + 1]) ?? 10;
        i += 2;
      } else {
        target = args[i];
        i++;
      }
    }

    await _viewFile(target ?? 'logs', lines: lines, mode: 'tail');
  }

  Future<void> _handleHead(List<String> args) async {
    int lines = 10;
    String? target;

    // Parse arguments: head [-n lines] [target]
    var i = 0;
    while (i < args.length) {
      if (args[i] == '-n' && i + 1 < args.length) {
        lines = int.tryParse(args[i + 1]) ?? 10;
        i += 2;
      } else {
        target = args[i];
        i++;
      }
    }

    await _viewFile(target ?? 'logs', lines: lines, mode: 'head');
  }

  Future<void> _handleCat(List<String> args) async {
    if (args.isEmpty) {
      _printError('Usage: cat <file>');
      _printError('Available: logs, config, /path/to/file');
      return;
    }

    await _viewFile(args[0], mode: 'cat');
  }

  Future<void> _viewFile(String target, {int lines = 10, required String mode}) async {
    List<String> content = [];

    // Handle virtual files
    switch (target.toLowerCase()) {
      case 'logs':
      case '/logs':
        final logs = _station.logs;
        content = logs.map((log) {
          final time = log.timestamp.toLocal();
          final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
          return '$timeStr [${log.level}] ${log.message}';
        }).toList();
        break;

      case 'config':
      case '/config':
      case 'station_config.json':
        final settings = _station.settings;
        content = [
          '{',
          '  "httpPort": ${settings.httpPort},',
          '  "httpsPort": ${settings.httpsPort},',
          '  "callsign": "${settings.callsign}",',
          '  "description": "${settings.description ?? ''}",',
          '  "location": "${settings.location ?? ''}",',
          '  "latitude": ${settings.latitude ?? 'null'},',
          '  "longitude": ${settings.longitude ?? 'null'},',
          '  "tileServerEnabled": ${settings.tileServerEnabled},',
          '  "osmFallbackEnabled": ${settings.osmFallbackEnabled},',
          '  "maxZoomLevel": ${settings.maxZoomLevel},',
          '  "maxCacheSizeMB": ${settings.maxCacheSizeMB},',
          '  "enableAprs": ${settings.enableAprs},',
          '  "enableCors": ${settings.enableCors},',
          '  "maxConnectedDevices": ${settings.maxConnectedDevices}',
          '}',
        ];
        break;

      default:
        // Try to read as real file
        final file = File(target);
        if (await file.exists()) {
          try {
            content = await file.readAsLines();
          } catch (e) {
            _printError('Cannot read file: $e');
            return;
          }
        } else {
          _printError('File not found: $target');
          _printError('Available virtual files: logs, config');
          return;
        }
    }

    if (content.isEmpty) {
      stdout.writeln('(empty)');
      return;
    }

    // Apply mode
    List<String> output;
    switch (mode) {
      case 'head':
        output = content.take(lines).toList();
        break;
      case 'tail':
        output = content.length > lines
            ? content.sublist(content.length - lines)
            : content;
        break;
      case 'cat':
      default:
        output = content;
    }

    // Print with line numbers for cat
    if (mode == 'cat') {
      final maxLineNum = output.length.toString().length;
      for (var i = 0; i < output.length; i++) {
        final lineNum = (i + 1).toString().padLeft(maxLineNum);
        stdout.writeln('\x1B[33m$lineNum\x1B[0m  ${output[i]}');
      }
    } else {
      for (final line in output) {
        stdout.writeln(line);
      }
    }
  }

  // --- Profile commands ---

  Future<void> _handleProfile(List<String> args) async {
    if (args.isEmpty) {
      // Show current profile
      await _showCurrentProfile();
      return;
    }

    final subCommand = args[0].toLowerCase();
    final subArgs = args.length > 1 ? args.sublist(1) : <String>[];

    switch (subCommand) {
      case 'list':
        await _listProfiles();
        break;
      case 'show':
        await _showCurrentProfile();
        break;
      case 'add':
        await _handleSetup(); // Reuse setup wizard
        break;
      case 'switch':
        if (subArgs.isEmpty) {
          _printError('Usage: profile switch <callsign>');
          return;
        }
        await _switchProfile(subArgs[0]);
        break;
      case 'delete':
        if (subArgs.isEmpty) {
          _printError('Usage: profile delete <callsign>');
          return;
        }
        await _deleteProfile(subArgs[0]);
        break;
      default:
        _printError('Unknown profile command: $subCommand');
        stdout.writeln('Available: list, show, add, switch, delete');
    }
  }

  Future<void> _showCurrentProfile() async {
    final profile = _profileService.activeProfile;
    if (profile == null) {
      stdout.writeln('\x1B[33mNo profile configured. Run "setup" to create one.\x1B[0m');
      return;
    }

    final typeStr = profile.isRelay ? 'station' : 'client';
    stdout.writeln();
    stdout.writeln('\x1B[1mActive Profile:\x1B[0m');
    stdout.writeln('  Type:        \x1B[36m$typeStr\x1B[0m');
    stdout.writeln('  Callsign:    \x1B[36m${profile.callsign}\x1B[0m');
    stdout.writeln('  Nickname:    \x1B[36m${profile.nickname.isEmpty ? '(not set)' : profile.nickname}\x1B[0m');
    stdout.writeln('  Description: \x1B[36m${profile.description.isEmpty ? '(not set)' : profile.description}\x1B[0m');
    if (profile.locationName != null) {
      stdout.writeln('  Location:    \x1B[36m${profile.locationName}\x1B[0m');
    }
    stdout.writeln('  npub:        \x1B[90m${profile.npub}\x1B[0m');
    stdout.writeln('  Created:     \x1B[90m${profile.createdAt.toIso8601String().substring(0, 10)}\x1B[0m');

    if (profile.isRelay) {
      stdout.writeln();
      stdout.writeln('\x1B[1mRelay Settings:\x1B[0m');
      stdout.writeln('  Port:        \x1B[36m${profile.port ?? 8080}\x1B[0m');
      stdout.writeln('  Role:        \x1B[36m${profile.stationRole ?? 'not set'}\x1B[0m');
      if (profile.parentStationUrl != null) {
        stdout.writeln('  Parent URL:  \x1B[36m${profile.parentStationUrl}\x1B[0m');
      }
    }
    stdout.writeln();
  }

  Future<void> _listProfiles() async {
    final profiles = _profileService.profiles;
    if (profiles.isEmpty) {
      stdout.writeln('\x1B[33mNo profiles configured. Run "setup" to create one.\x1B[0m');
      return;
    }

    stdout.writeln();
    stdout.writeln('\x1B[1mProfiles:\x1B[0m');
    stdout.writeln();

    for (final profile in profiles) {
      final isActive = profile.id == _profileService.activeProfile?.id;
      final typeStr = profile.isRelay ? 'station' : 'client';
      final activeStr = isActive ? '\x1B[32m*\x1B[0m ' : '  ';
      final displayName = profile.nickname.isNotEmpty
          ? '${profile.callsign} (${profile.nickname})'
          : profile.callsign;

      stdout.writeln('$activeStr\x1B[36m$displayName\x1B[0m - $typeStr');
    }
    stdout.writeln();
    stdout.writeln('Total: ${profiles.length} profile(s)');
    stdout.writeln('Use "profile switch <callsign>" to change active profile.');
    stdout.writeln();
  }

  Future<void> _switchProfile(String callsign) async {
    final profile = _profileService.getProfileByCallsign(callsign);
    if (profile == null) {
      _printError('Profile not found: $callsign');
      return;
    }

    await _profileService.setActiveProfile(profile.id);

    // If switching to a station, update station server settings
    if (profile.isRelay) {
      final newSettings = _station.settings.copyWith(
        httpPort: profile.port,
        description: profile.description,
        location: profile.locationName,
        latitude: profile.latitude,
        longitude: profile.longitude,
        tileServerEnabled: profile.tileServerEnabled,
        osmFallbackEnabled: profile.osmFallbackEnabled,
        enableAprs: profile.enableAprs,
        stationRole: profile.stationRole,
        networkId: profile.networkId,
        parentStationUrl: profile.parentStationUrl,
        setupComplete: true,
      );
      await _station.updateSettings(newSettings);
    }

    stdout.writeln('\x1B[32mSwitched to profile: ${profile.callsign}\x1B[0m');
  }

  Future<void> _deleteProfile(String callsign) async {
    final profile = _profileService.getProfileByCallsign(callsign);
    if (profile == null) {
      _printError('Profile not found: $callsign');
      return;
    }

    final confirm = await _promptConfirm(
      'Delete profile ${profile.callsign}? This cannot be undone',
      false,
    );

    if (!confirm) {
      stdout.writeln('Cancelled.');
      return;
    }

    await _profileService.deleteProfile(profile.id);
    stdout.writeln('\x1B[32mProfile deleted: ${profile.callsign}\x1B[0m');

    if (_profileService.profiles.isEmpty) {
      stdout.writeln('\x1B[33mNo profiles remaining. Run "setup" to create a new one.\x1B[0m');
    }
  }

  // --- Setup wizard ---

  Future<void> _handleSetup() async {
    stdout.writeln();
    stdout.writeln('\x1B[1;36m' + '=' * 60 + '\x1B[0m');
    stdout.writeln('\x1B[1;36m  Geogram Desktop Setup Wizard\x1B[0m');
    stdout.writeln('\x1B[1;36m' + '=' * 60 + '\x1B[0m');
    stdout.writeln();

    // Step 1: Choose profile type
    _printSection('STEP 1: PROFILE TYPE');
    stdout.writeln('What would you like to create?');
    stdout.writeln('  \x1B[33m1)\x1B[0m Client - Regular user profile for messaging and browsing');
    stdout.writeln('  \x1B[33m2)\x1B[0m Station  - Server that routes messages between devices');
    stdout.writeln();

    final typeChoice = await _promptChoice('Enter choice (1 or 2)', ['1', '2']);
    final isRelay = typeChoice == '2';

    if (isRelay) {
      await _handleRelaySetup();
    } else {
      await _handleClientSetup();
    }
  }

  /// Setup wizard for client profile
  Future<void> _handleClientSetup() async {
    stdout.writeln();
    stdout.writeln('Creating \x1B[32mClient Profile\x1B[0m...');
    stdout.writeln();

    // Step 2: Identity - generate or import
    _printSection('STEP 2: CLIENT IDENTITY');
    stdout.writeln('How would you like to set up your identity?');
    stdout.writeln('  \x1B[33m1)\x1B[0m Generate new keys (recommended for new users)');
    stdout.writeln('  \x1B[33m2)\x1B[0m Import existing NSEC (for restoring an identity)');
    stdout.writeln();

    final identityChoice = await _promptChoice('Enter choice (1 or 2)', ['1', '2']);

    late Map<String, String> keys;
    late String callsign;

    if (identityChoice == '2') {
      // Import existing NSEC
      stdout.writeln();
      stdout.writeln('Enter your NSEC (starts with nsec1):');
      while (true) {
        final nsec = await _promptInput('NSEC: ');
        if (nsec == null || nsec.isEmpty) {
          stdout.writeln('\x1B[31mNSEC cannot be empty\x1B[0m');
          continue;
        }
        if (!nsec.startsWith('nsec1')) {
          stdout.writeln('\x1B[31mInvalid NSEC format. Must start with "nsec1"\x1B[0m');
          continue;
        }
        // Validate and derive npub
        final npub = NostrKeyGenerator.derivePublicKey(nsec);
        if (npub == null) {
          stdout.writeln('\x1B[31mInvalid NSEC. Could not derive public key.\x1B[0m');
          continue;
        }
        keys = {'nsec': nsec, 'npub': npub};
        callsign = CliProfileService.generateCallsign(npub, ProfileType.client);
        stdout.writeln();
        stdout.writeln('Imported identity:');
        stdout.writeln('  npub: \x1B[90m$npub\x1B[0m');
        stdout.writeln('  Callsign: \x1B[32m$callsign\x1B[0m');
        break;
      }
    } else {
      // Generate new keys
      keys = CliProfileService.generateKeys();
      callsign = CliProfileService.generateCallsign(keys['npub']!, ProfileType.client);
      stdout.writeln('Generated client callsign: \x1B[32m$callsign\x1B[0m');
    }
    stdout.writeln();

    // Step 3: Client Info
    _printSection('STEP 3: PROFILE INFORMATION');

    final nickname = await _promptInputWithDefault('Nickname (display name)', '');
    final description = await _promptInputWithDefault('Description (about you)', '');
    final location = await _promptInputWithDefault('Location (optional)', '');

    double? latitude;
    double? longitude;
    if (location.isNotEmpty) {
      final latStr = await _promptInputWithDefault('Latitude (optional)', '');
      final lonStr = await _promptInputWithDefault('Longitude (optional)', '');
      latitude = latStr.isNotEmpty ? double.tryParse(latStr) : null;
      longitude = lonStr.isNotEmpty ? double.tryParse(lonStr) : null;
    }
    stdout.writeln();

    // Summary
    _printSection('SETUP SUMMARY');
    stdout.writeln('Client Profile:');
    stdout.writeln('  Callsign:    \x1B[36m$callsign\x1B[0m');
    stdout.writeln('  Nickname:    \x1B[36m${nickname.isEmpty ? '(not set)' : nickname}\x1B[0m');
    stdout.writeln('  Description: \x1B[36m${description.isEmpty ? '(not set)' : description}\x1B[0m');
    if (location.isNotEmpty) {
      stdout.writeln('  Location:    \x1B[36m$location\x1B[0m');
    }
    stdout.writeln();
    stdout.writeln('Identity Keys:');
    stdout.writeln('  npub: \x1B[90m${keys['npub']!}\x1B[0m');
    stdout.writeln('  nsec: \x1B[90m(stored securely)\x1B[0m');
    stdout.writeln();

    final confirm = await _promptConfirm('Save this profile?', true);
    if (!confirm) {
      stdout.writeln('\x1B[33mSetup cancelled. No profile created.\x1B[0m');
      return;
    }

    // Create profile
    final profile = Profile(
      type: ProfileType.client,
      callsign: callsign,
      nickname: nickname,
      description: description,
      npub: keys['npub']!,
      nsec: keys['nsec']!,
      locationName: location.isNotEmpty ? location : null,
      latitude: latitude,
      longitude: longitude,
    );

    await _profileService.addProfile(profile);

    stdout.writeln();
    stdout.writeln('\x1B[32mClient profile created successfully!\x1B[0m');
    stdout.writeln();
    stdout.writeln('Your callsign is: \x1B[36m$callsign\x1B[0m');
    stdout.writeln();
    stdout.writeln('Type "help" to see available commands.');
    stdout.writeln('Type "profile" to view your profile.');
    stdout.writeln();
  }

  /// Setup wizard for station profile
  Future<void> _handleRelaySetup() async {
    stdout.writeln();
    stdout.writeln('Creating \x1B[32mStation Profile\x1B[0m...');
    stdout.writeln();

    // Step 2: Identity - generate or import
    _printSection('STEP 2: STATION IDENTITY');
    stdout.writeln('How would you like to set up your station identity?');
    stdout.writeln('  \x1B[33m1)\x1B[0m Generate new keys (recommended for new stations)');
    stdout.writeln('  \x1B[33m2)\x1B[0m Import existing NSEC (for restoring a station)');
    stdout.writeln();

    final identityChoice = await _promptChoice('Enter choice (1 or 2)', ['1', '2']);

    late Map<String, String> keys;
    late String callsign;

    if (identityChoice == '2') {
      // Import existing NSEC
      stdout.writeln();
      stdout.writeln('Enter your NSEC (starts with nsec1):');
      while (true) {
        final nsec = await _promptInput('NSEC: ');
        if (nsec == null || nsec.isEmpty) {
          stdout.writeln('\x1B[31mNSEC cannot be empty\x1B[0m');
          continue;
        }
        if (!nsec.startsWith('nsec1')) {
          stdout.writeln('\x1B[31mInvalid NSEC format. Must start with "nsec1"\x1B[0m');
          continue;
        }
        // Validate and derive npub
        final npub = NostrKeyGenerator.derivePublicKey(nsec);
        if (npub == null) {
          stdout.writeln('\x1B[31mInvalid NSEC. Could not derive public key.\x1B[0m');
          continue;
        }
        keys = {'nsec': nsec, 'npub': npub};
        callsign = CliProfileService.generateCallsign(npub, ProfileType.station);
        stdout.writeln();
        stdout.writeln('Imported identity:');
        stdout.writeln('  npub: \x1B[90m$npub\x1B[0m');
        stdout.writeln('  Station Callsign: \x1B[32m$callsign\x1B[0m');
        break;
      }
    } else {
      // Generate new keys
      keys = CliProfileService.generateKeys();
      callsign = CliProfileService.generateCallsign(keys['npub']!, ProfileType.station);
      stdout.writeln('Generated station callsign: \x1B[32m$callsign\x1B[0m');
    }
    stdout.writeln();

    // Step 3: Station Role
    _printSection('STEP 3: STATION NETWORK ROLE');
    stdout.writeln('Select station role:');
    stdout.writeln('  \x1B[33m1)\x1B[0m Root Station - Primary station (accepts node connections)');
    stdout.writeln('  \x1B[33m2)\x1B[0m Node Station - Connects to an existing root station');
    stdout.writeln();

    final roleChoice = await _promptChoice('Enter choice (1 or 2)', ['1', '2']);
    final isRoot = roleChoice == '1';
    String? parentUrl;
    String? networkId;

    if (isRoot) {
      stdout.writeln('Configuring as \x1B[32mRoot Station\x1B[0m');
      networkId = await _promptInputWithDefault('Network ID (optional)', '');
    } else {
      stdout.writeln('Configuring as \x1B[33mNode Station\x1B[0m');
      stdout.writeln();

      while (parentUrl == null || parentUrl.isEmpty) {
        parentUrl = await _promptInput('Root station WebSocket URL (e.g., ws://station.example.com:8080): ');
        if (parentUrl != null && parentUrl.isNotEmpty) {
          if (!parentUrl.startsWith('ws://') && !parentUrl.startsWith('wss://')) {
            stdout.writeln('\x1B[31mInvalid URL format. Must start with "ws://" or "wss://"\x1B[0m');
            parentUrl = null;
          }
        }
      }
      networkId = await _promptInputWithDefault('Network ID (should match root station)', '');
    }
    stdout.writeln();

    // Step 4: Server Settings
    _printSection('STEP 4: SERVER SETTINGS');

    final portStr = await _promptInputWithDefault('Server port', '8080');
    final port = int.tryParse(portStr) ?? 8080;

    final description = await _promptInputWithDefault(
      'Server description',
      'Geogram Station',
    );

    // Auto-detect location via IP
    stdout.writeln('Detecting location via IP address...');
    final locationService = CliLocationService();
    final detectedLocation = await locationService.detectLocationViaIP();

    String location;
    double? latitude;
    double? longitude;

    if (detectedLocation != null) {
      stdout.writeln('\x1B[32mLocation detected: ${detectedLocation.locationName}\x1B[0m');
      location = await _promptInputWithDefault('Location', detectedLocation.locationName ?? '');
      latitude = detectedLocation.latitude;
      longitude = detectedLocation.longitude;
    } else {
      stdout.writeln('\x1B[33mCould not auto-detect location\x1B[0m');
      location = await _promptInputWithDefault('Location (optional)', '');
      if (location.isNotEmpty) {
        final latStr = await _promptInputWithDefault('Latitude (optional)', '');
        final lonStr = await _promptInputWithDefault('Longitude (optional)', '');
        latitude = latStr.isNotEmpty ? double.tryParse(latStr) : null;
        longitude = lonStr.isNotEmpty ? double.tryParse(lonStr) : null;
      }
    }
    stdout.writeln();

    // Step 5: Features
    _printSection('STEP 5: FEATURES');

    final enableAprs = await _promptConfirm('Enable APRS-IS announcements?', false);
    final enableTiles = await _promptConfirm('Enable tile server?', true);
    final enableOsmFallback = enableTiles && await _promptConfirm('Enable OSM fallback for tiles?', true);
    stdout.writeln();

    // Summary
    _printSection('SETUP SUMMARY');
    stdout.writeln('Station Profile:');
    stdout.writeln('  Callsign:       \x1B[36m$callsign\x1B[0m');
    stdout.writeln('  Role:           \x1B[36m${isRoot ? 'ROOT' : 'NODE'}\x1B[0m');
    if (!isRoot && parentUrl != null) {
      stdout.writeln('  Parent Station:   \x1B[36m$parentUrl\x1B[0m');
    }
    if (networkId != null && networkId.isNotEmpty) {
      stdout.writeln('  Network ID:     \x1B[36m$networkId\x1B[0m');
    }
    stdout.writeln();
    stdout.writeln('Server Settings:');
    stdout.writeln('  Port:           \x1B[36m$port\x1B[0m');
    stdout.writeln('  Description:    \x1B[36m$description\x1B[0m');
    if (location.isNotEmpty) {
      stdout.writeln('  Location:       \x1B[36m$location\x1B[0m');
    }
    stdout.writeln();
    stdout.writeln('Features:');
    stdout.writeln('  APRS:           ${enableAprs ? '\x1B[32mEnabled\x1B[0m' : '\x1B[33mDisabled\x1B[0m'}');
    stdout.writeln('  Tile Server:    ${enableTiles ? '\x1B[32mEnabled\x1B[0m' : '\x1B[33mDisabled\x1B[0m'}');
    if (enableTiles) {
      stdout.writeln('  OSM Fallback:   ${enableOsmFallback ? '\x1B[32mEnabled\x1B[0m' : '\x1B[33mDisabled\x1B[0m'}');
    }
    stdout.writeln();

    final confirm = await _promptConfirm('Save this configuration?', true);
    if (!confirm) {
      stdout.writeln('\x1B[33mSetup cancelled. No station created.\x1B[0m');
      return;
    }

    // Create station profile
    final profile = Profile(
      type: ProfileType.station,
      callsign: callsign,
      description: description,
      npub: keys['npub']!,
      nsec: keys['nsec']!,
      locationName: location.isNotEmpty ? location : null,
      latitude: latitude,
      longitude: longitude,
      port: port,
      stationRole: isRoot ? 'root' : 'node',
      parentStationUrl: parentUrl,
      networkId: networkId,
      tileServerEnabled: enableTiles,
      osmFallbackEnabled: enableOsmFallback,
      enableAprs: enableAprs,
    );

    await _profileService.addProfile(profile);

    // Also update station server settings
    final newSettings = _station.settings.copyWith(
      httpPort: port,
      description: description,
      location: location.isNotEmpty ? location : null,
      latitude: latitude,
      longitude: longitude,
      tileServerEnabled: enableTiles,
      osmFallbackEnabled: enableOsmFallback,
      enableAprs: enableAprs,
      stationRole: isRoot ? 'root' : 'node',
      networkId: networkId,
      parentStationUrl: parentUrl,
      setupComplete: true,
    );
    await _station.updateSettings(newSettings);

    stdout.writeln();
    stdout.writeln('\x1B[32mRelay profile created successfully!\x1B[0m');
    stdout.writeln();
    stdout.writeln('Your station callsign is: \x1B[36m$callsign\x1B[0m');
    stdout.writeln();
    stdout.writeln('To start the station server, type: \x1B[36mstation start\x1B[0m');
    stdout.writeln();
  }

  void _printSection(String title) {
    stdout.writeln('\x1B[1;33m--- $title ---\x1B[0m');
    stdout.writeln();
  }

  Future<String> _promptInput(String prompt) async {
    stdout.write('$prompt ');
    return stdin.readLineSync()?.trim() ?? '';
  }

  Future<String> _promptInputWithDefault(String prompt, String defaultValue) async {
    if (defaultValue.isNotEmpty) {
      stdout.write('$prompt [\x1B[36m$defaultValue\x1B[0m]: ');
    } else {
      stdout.write('$prompt: ');
    }
    final input = stdin.readLineSync()?.trim() ?? '';
    return input.isEmpty ? defaultValue : input;
  }

  Future<String> _promptChoice(String prompt, List<String> validChoices) async {
    while (true) {
      stdout.write('$prompt: ');
      final input = stdin.readLineSync()?.trim() ?? '';
      if (validChoices.contains(input)) {
        return input;
      }
      stdout.writeln('\x1B[31mInvalid choice. Please enter one of: ${validChoices.join(', ')}\x1B[0m');
    }
  }

  Future<bool> _promptConfirm(String prompt, bool defaultValue) async {
    final defaultStr = defaultValue ? 'Y/n' : 'y/N';
    stdout.write('$prompt [$defaultStr]: ');
    final input = stdin.readLineSync()?.trim().toLowerCase() ?? '';
    if (input.isEmpty) return defaultValue;
    return input == 'y' || input == 'yes';
  }

  // --- SSL commands ---

  Future<void> _handleSsl(List<String> args) async {
    if (args.isEmpty) {
      await _showSslStatus();
      return;
    }

    final subcommand = args[0].toLowerCase();
    final subargs = args.length > 1 ? args.sublist(1) : <String>[];

    switch (subcommand) {
      case 'domain':
        await _handleSslDomain(subargs);
        break;
      case 'email':
        await _handleSslEmail(subargs);
        break;
      case 'request':
        await _handleSslRequest(staging: false);
        break;
      case 'test':
        await _handleSslRequest(staging: true);
        break;
      case 'renew':
        await _handleSslRenew();
        break;
      case 'autorenew':
        await _handleSslAutoRenew(subargs);
        break;
      case 'selfsigned':
        await _handleSslSelfSigned(subargs);
        break;
      case 'enable':
        await _handleSslEnable(true);
        break;
      case 'disable':
        await _handleSslEnable(false);
        break;
      default:
        _printError('Unknown ssl command: $subcommand');
        _printError('Available: domain, email, request, test, renew, autorenew, selfsigned, enable, disable');
    }
  }

  Future<void> _showSslStatus() async {
    if (_sslManager == null) {
      _printError('SSL manager not initialized');
      return;
    }

    final status = await _sslManager!.getStatus();

    stdout.writeln();
    stdout.writeln('\x1B[1mSSL/TLS Certificate Status\x1B[0m');
    stdout.writeln('-' * 40);
    stdout.writeln('Domain:         ${status['domain']}');
    stdout.writeln('Email:          ${status['email']}');
    stdout.writeln('SSL Enabled:    ${status['enabled'] == true ? '\x1B[32mYes\x1B[0m' : '\x1B[33mNo\x1B[0m'}');
    stdout.writeln('Auto-Renew:     ${status['autoRenew'] == true ? '\x1B[32mEnabled\x1B[0m' : '\x1B[33mDisabled\x1B[0m'}');
    stdout.writeln('Certificate:    ${status['hasCertificate'] == true ? '\x1B[32mInstalled\x1B[0m' : '\x1B[33mNot installed\x1B[0m'}');

    if (status['hasCertificate'] == true) {
      if (status['expiresAt'] != null) {
        stdout.writeln('Expires:        ${status['expiresAt']}');
        stdout.writeln('Days Left:      ${status['daysUntilExpiry']}');
      }
      if (status['certPath'] != null) {
        stdout.writeln('Cert Path:      ${status['certPath']}');
      }
    }

    stdout.writeln();
    stdout.writeln('\x1B[33mSSL Commands:\x1B[0m');
    stdout.writeln('  ssl domain <domain>      Set domain for certificate');
    stdout.writeln('  ssl email <email>        Set email for Let\'s Encrypt');
    stdout.writeln('  ssl request              Request production certificate');
    stdout.writeln('  ssl test                 Request test certificate (staging)');
    stdout.writeln('  ssl renew                Force certificate renewal');
    stdout.writeln('  ssl autorenew <on|off>   Enable/disable auto-renewal');
    stdout.writeln('  ssl selfsigned [domain]  Generate self-signed certificate');
    stdout.writeln('  ssl enable               Enable SSL/HTTPS');
    stdout.writeln('  ssl disable              Disable SSL/HTTPS');
    stdout.writeln();
  }

  Future<void> _handleSslDomain(List<String> args) async {
    if (args.isEmpty) {
      stdout.writeln('Current domain: ${_station.settings.sslDomain ?? '(not set)'}');
      return;
    }

    final domain = args[0];
    final settings = _station.settings.copyWith(sslDomain: domain);
    await _station.updateSettings(settings);
    _sslManager?.updateSettings(_station.settings);
    stdout.writeln('\x1B[32mSSL domain set to: $domain\x1B[0m');
  }

  Future<void> _handleSslEmail(List<String> args) async {
    if (args.isEmpty) {
      stdout.writeln('Current email: ${_station.settings.sslEmail ?? '(not set)'}');
      return;
    }

    final email = args[0];
    if (!email.contains('@')) {
      _printError('Invalid email address');
      return;
    }

    final settings = _station.settings.copyWith(sslEmail: email);
    await _station.updateSettings(settings);
    _sslManager?.updateSettings(_station.settings);
    stdout.writeln('\x1B[32mSSL email set to: $email\x1B[0m');
  }

  Future<void> _handleSslRequest({required bool staging}) async {
    if (_sslManager == null) {
      _printError('SSL manager not initialized');
      return;
    }

    final envType = staging ? 'staging (test)' : 'production';
    stdout.writeln('Requesting $envType certificate...');
    stdout.writeln('Domain: ${_station.settings.sslDomain}');
    stdout.writeln('Email:  ${_station.settings.sslEmail}');
    stdout.writeln();

    try {
      final success = await _sslManager!.requestCertificate(staging: staging);
      if (success) {
        stdout.writeln('\x1B[32mCertificate request successful!\x1B[0m');
        stdout.writeln();
        stdout.writeln('To enable HTTPS, run: ssl enable');
        stdout.writeln('Then restart the station: restart');
      }
    } catch (e) {
      _printError('Certificate request failed: $e');
    }
  }

  Future<void> _handleSslRenew() async {
    if (_sslManager == null) {
      _printError('SSL manager not initialized');
      return;
    }

    stdout.writeln('Renewing certificate...');

    try {
      final success = await _sslManager!.renewCertificate(staging: false);
      if (success) {
        stdout.writeln('\x1B[32mCertificate renewed successfully!\x1B[0m');
      }
    } catch (e) {
      _printError('Certificate renewal failed: $e');
    }
  }

  Future<void> _handleSslAutoRenew(List<String> args) async {
    if (args.isEmpty) {
      final current = _station.settings.sslAutoRenew ? 'on' : 'off';
      stdout.writeln('Auto-renewal is currently: $current');
      return;
    }

    final value = args[0].toLowerCase();
    final enabled = value == 'on' || value == 'true' || value == '1';

    final settings = _station.settings.copyWith(sslAutoRenew: enabled);
    await _station.updateSettings(settings);
    _sslManager?.updateSettings(_station.settings);

    if (enabled) {
      _sslManager?.startAutoRenewal();
      stdout.writeln('\x1B[32mAuto-renewal enabled\x1B[0m');
    } else {
      _sslManager?.stop();
      stdout.writeln('\x1B[33mAuto-renewal disabled\x1B[0m');
    }
  }

  Future<void> _handleSslSelfSigned(List<String> args) async {
    if (_sslManager == null) {
      _printError('SSL manager not initialized');
      return;
    }

    final domain = args.isNotEmpty ? args[0] : (_station.settings.sslDomain ?? 'localhost');

    stdout.writeln('Generating self-signed certificate for: $domain');

    try {
      final success = await _sslManager!.generateSelfSigned(domain);
      if (success) {
        stdout.writeln('\x1B[32mSelf-signed certificate generated!\x1B[0m');
        stdout.writeln('\x1B[33mWarning: Self-signed certificates are not trusted by browsers.\x1B[0m');
        stdout.writeln();
        stdout.writeln('To enable HTTPS, run: ssl enable');
        stdout.writeln('Then restart the station: restart');
      }
    } catch (e) {
      _printError('Failed to generate self-signed certificate: $e');
    }
  }

  Future<void> _handleSslEnable(bool enable) async {
    if (_sslManager == null) {
      _printError('SSL manager not initialized');
      return;
    }

    if (enable && !_sslManager!.hasCertificate()) {
      _printError('No certificate installed. Run "ssl request" or "ssl selfsigned" first.');
      return;
    }

    final settings = _station.settings.copyWith(
      enableSsl: enable,
      sslCertPath: enable ? _sslManager!.certPath : null,
      sslKeyPath: enable ? _sslManager!.domainKeyPath : null,
    );
    await _station.updateSettings(settings);
    _sslManager?.updateSettings(_station.settings);

    if (enable) {
      stdout.writeln('\x1B[32mSSL/HTTPS enabled\x1B[0m');
      stdout.writeln('HTTPS will be available on port ${_station.settings.httpsPort} after restart');
    } else {
      stdout.writeln('\x1B[33mSSL/HTTPS disabled\x1B[0m');
    }
    stdout.writeln('Restart the station for changes to take effect: restart');
  }

  // --- Game commands ---

  Future<void> _handlePlay(List<String> args) async {
    if (args.isEmpty) {
      _printError('Usage: play <game-name.md>');
      stdout.writeln('Use "ls /games" or "games list" to see available games');
      return;
    }

    final gameName = args[0];
    final gamePath = _gameConfig.getGamePath(gameName);

    if (gamePath == null) {
      _printError('Game not found: $gameName');
      stdout.writeln('Use "ls /games" or "games list" to see available games');
      return;
    }

    try {
      final content = await File(gamePath).readAsString();
      final parser = GameParser();
      final game = parser.parse(content);

      final screen = GameScreen();
      final engine = GameEngine(game: game, screen: screen);

      stdout.writeln();
      stdout.writeln('\x1B[1;36mStarting game: ${game.title}\x1B[0m');
      stdout.writeln('\x1B[90mPress Ctrl+C or type "quit" to exit the game\x1B[0m');
      stdout.writeln();

      await engine.run();

      stdout.writeln();
      stdout.writeln('\x1B[1;33mGame ended. Returning to CLI.\x1B[0m');
      stdout.writeln();
    } catch (e) {
      _printError('Failed to start game: $e');
    }
  }

  Future<void> _handleGames(List<String> args) async {
    if (args.isEmpty) {
      _listGames();
      return;
    }

    switch (args[0].toLowerCase()) {
      case 'list':
        _listGames();
        break;
      case 'info':
        if (args.length < 2) {
          _printError('Usage: games info <game-name>');
        } else {
          _showGameInfo(args[1]);
        }
        break;
      default:
        _printError('Unknown games command: ${args[0]}');
        stdout.writeln('Available: list, info');
    }
  }

  void _listGames() {
    final games = _gameConfig.listGames();

    stdout.writeln();
    stdout.writeln('\x1B[1mAvailable Games (${games.length})\x1B[0m');
    stdout.writeln('-' * 40);

    if (games.isEmpty) {
      stdout.writeln('No games found in ${_gameConfig.gamesDirectory}');
      stdout.writeln('Add .md game files to play');
    } else {
      for (final game in games) {
        final name = game.path.split('/').last;
        final info = _gameConfig.getGameInfo(name);
        final title = info?['title'] ?? name.replaceAll('.md', '');
        stdout.writeln('  \x1B[36m${name.padRight(25)}\x1B[0m $title');
      }
    }

    stdout.writeln();
    stdout.writeln('Use "play <game-name>" to start a game');
    stdout.writeln();
  }

  void _showGameInfo(String name) {
    final info = _gameConfig.getGameInfo(name);

    if (info == null) {
      _printError('Game not found: $name');
      return;
    }

    stdout.writeln();
    stdout.writeln('\x1B[1mGame: ${info['title']}\x1B[0m');
    stdout.writeln('-' * 40);
    stdout.writeln('File:      ${info['name']}');
    stdout.writeln('Scenes:    ${info['scenes']}');
    stdout.writeln('Items:     ${info['items']}');
    stdout.writeln('Opponents: ${info['opponents']}');
    stdout.writeln('Actions:   ${info['actions']}');
    stdout.writeln();
    stdout.writeln('To play: play ${info['name']}');
    stdout.writeln();
  }

  // --- Navigation commands ---

  void _handleLs(List<String> args) {
    final path = args.isNotEmpty ? _resolvePath(args[0]) : _currentPath;

    if (path == '/') {
      for (final dir in rootDirs) {
        stdout.writeln('\x1B[34m$dir/\x1B[0m');
      }
    } else if (path == '/station') {
      final status = _station.isRunning ? '\x1B[32mRunning\x1B[0m' : '\x1B[33mStopped\x1B[0m';
      stdout.writeln('status      $status');
      stdout.writeln('\x1B[34mconfig/\x1B[0m');
      stdout.writeln('\x1B[34mcache/\x1B[0m');
    } else if (path == '/devices') {
      _listDevices();
    } else if (path == '/chat') {
      // Use station's chat rooms in CLI mode
      for (final room in _station.chatRooms.values) {
        stdout.writeln('\x1B[34m${room.id}/\x1B[0m  ${room.name}');
      }
    } else if (path.startsWith('/chat/')) {
      final roomId = path.substring('/chat/'.length);
      final room = _station.chatRooms[roomId];
      if (room != null) {
        stdout.writeln('${room.messages.length} messages');
        if (room.messages.isNotEmpty) {
          final lastMsg = room.messages.last;
          stdout.writeln('Last activity: ${lastMsg.timestamp.toLocal()}');
        }
      } else {
        _printError('Room not found');
      }
    } else if (path == '/config') {
      _showConfigList();
    } else if (path == '/logs') {
      stdout.writeln('(${_station.logs.length} log entries)');
    } else if (path == '/ssl') {
      final sslEnabled = _station.settings.enableSsl;
      final hasCert = _sslManager?.hasCertificate() == true;

      stdout.writeln('\x1B[1mSSL/TLS Status\x1B[0m');
      stdout.writeln('─' * 40);
      stdout.writeln('HTTPS:       ${sslEnabled ? '\x1B[32mEnabled\x1B[0m on port ${_station.settings.httpsPort}' : '\x1B[33mDisabled\x1B[0m'}');
      stdout.writeln('Certificate: ${hasCert ? '\x1B[32mInstalled\x1B[0m' : '\x1B[33mNot installed\x1B[0m'}');
      stdout.writeln('Domain:      ${_station.settings.sslDomain ?? '\x1B[33m(not set)\x1B[0m'}');
      stdout.writeln('Email:       ${_station.settings.sslEmail ?? '\x1B[33m(not set)\x1B[0m'}');
      stdout.writeln('Auto-renew:  ${_station.settings.sslAutoRenew ? '\x1B[32mon\x1B[0m' : '\x1B[33moff\x1B[0m'}');
      stdout.writeln('');
      stdout.writeln('\x1B[1mCommands\x1B[0m (run from /ssl)');
      stdout.writeln('─' * 40);
      stdout.writeln('domain <domain>   Set domain for certificate');
      stdout.writeln('email <email>     Set Let\'s Encrypt contact email');
      stdout.writeln('request           Request production certificate');
      stdout.writeln('test              Request staging (test) certificate');
      stdout.writeln('renew             Force certificate renewal');
      stdout.writeln('autorenew on|off  Toggle auto-renewal');
      stdout.writeln('selfsigned        Generate self-signed certificate');
      stdout.writeln('enable            Enable HTTPS server');
      stdout.writeln('disable           Disable HTTPS server');
      stdout.writeln('status            Show detailed certificate info');
    } else if (path == '/games') {
      _listGames();
    } else {
      _printError('Directory not found: $path');
    }
  }

  Future<void> _handleCd(List<String> args) async {
    if (args.isEmpty) {
      _currentPath = '/';
      _currentChatRoom = null;
      return;
    }

    final target = _resolvePath(args[0]);

    if (target == '/' || rootDirs.contains(target.substring(1).split('/')[0])) {
      _currentPath = target;

      // Check if we're entering a chat room
      if (target.startsWith('/chat/') && target.length > '/chat/'.length) {
        final roomId = target.substring('/chat/'.length).split('/')[0];
        // Use station's chat rooms in CLI mode
        final room = _station.chatRooms[roomId];
        if (room != null) {
          _currentChatRoom = roomId;
          stdout.writeln('--- ${room.name} ---');
          // Show recent messages when entering
          await _showChatHistory(roomId, 10);
        } else {
          _printError('Room not found: $roomId');
          _currentPath = '/chat';
          _currentChatRoom = null;
        }
      } else {
        _currentChatRoom = null;
      }
    } else {
      _printError('Directory not found: ${args[0]}');
    }
  }

  String _resolvePath(String path) {
    if (path.startsWith('/')) {
      return _normalizePath(path);
    }

    if (path == '..') {
      final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
      if (parts.isEmpty) return '/';
      parts.removeLast();
      return parts.isEmpty ? '/' : '/${parts.join('/')}';
    }

    if (path == '.') {
      return _currentPath;
    }

    final newPath = _currentPath == '/' ? '/$path' : '$_currentPath/$path';
    return _normalizePath(newPath);
  }

  String _normalizePath(String path) {
    if (path.isEmpty) return '/';
    var normalized = path.replaceAll(RegExp(r'/+'), '/');
    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  String _formatUptime(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
    if (seconds < 86400) {
      final hours = seconds ~/ 3600;
      final minutes = (seconds % 3600) ~/ 60;
      return '${hours}h ${minutes}m';
    }
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    return '${days}d ${hours}h';
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  void _printError(String message) {
    stdout.writeln('\x1B[31m$message\x1B[0m');
  }
}

/// Entry point for pure Dart CLI mode
Future<void> runPureCliMode(List<String> args) async {
  final console = PureConsole();
  await console.run(args);
}
