// Pure Dart console for CLI mode (no Flutter dependencies)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_console/dart_console.dart';

import '../station.dart';
import 'cli_profile_service.dart';
import 'cli_location_service.dart';
import 'cli_station_cache_service.dart';
import 'cli_args.dart';
import '../models/profile.dart';
import '../util/event_bus.dart';
import 'game/game_config.dart';
import 'pure_storage_config.dart';
import '../util/nostr_key_generator.dart';
import '../services/email_dns_service.dart';
import 'console_io.dart';
import 'console_io_cli.dart';
import 'commands/command.dart';
import 'commands/command_context.dart';
import 'commands/command_registry.dart';
import 'commands/general_commands.dart';
import 'commands/station_command.dart';
import 'commands/profile_command.dart';
import 'commands/chat_command.dart';
import 'commands/devices_command.dart';
import 'commands/config_command.dart';
import 'commands/ssl_command.dart';
import 'commands/games_command.dart';
import 'commands/monitoring_commands.dart';

/// Completion candidate
class Candidate {
  final String value;
  final String display;
  final String? group;
  final bool complete;

  Candidate(this.value, {String? display, this.group, this.complete = true})
      : display = display ?? value;
}

/// Pure Dart CLI console for geogram
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

  /// Console I/O adapter for command registry
  final ConsoleIO _io = CliConsoleIO();

  /// Command registry for dispatch and completion
  late final CommandRegistry _registry;

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

  /// Parsed CLI arguments
  late CliArgs _cliArgs;

  /// Run CLI mode
  Future<void> run(List<String> args) async {
    // Parse command-line arguments
    _cliArgs = CliArgs.parse(args);

    // Handle --help
    if (_cliArgs.showHelp) {
      CliArgs.printHelp();
      exit(0);
    }

    // Handle --version
    if (_cliArgs.showVersion) {
      CliArgs.printVersion();
      exit(0);
    }

    // Handle --email-dns (run diagnostics and exit)
    if (_cliArgs.emailDnsCheck) {
      await _runEmailDnsDiagnosticsCommand();
      exit(0);
    }

    // Initialize storage configuration first
    await PureStorageConfig().init(customBaseDir: _cliArgs.dataDir);

    await _initializeServices();

    // Apply port setting from CLI args if specified
    if (_cliArgs.port != null) {
      final updatedSettings = _station.settings.copyWith(
        httpPort: _cliArgs.port,
      );
      await _station.updateSettings(updatedSettings);
    }

    // Enable verbose mode if specified
    if (_cliArgs.verbose) {
      _station.quietMode = false;
    }

    _printBanner();

    // Handle --new-identity: create a new profile automatically
    if (_cliArgs.newIdentity) {
      await _createNewIdentity();
    }
    // Check if setup is needed (no profiles exist) and not skipping intro
    else if (_profileService.needsSetup()) {
      if (_cliArgs.skipIntro) {
        // Skip intro but still need a profile - create default one
        stdout.writeln('\x1B[33mNo profile found. Creating default profile...\x1B[0m');
        await _createNewIdentity();
      } else if (_cliArgs.forceSetup) {
        stdout.writeln('\x1B[33mInitial setup required.\x1B[0m');
        stdout.writeln();
        await _handleSetup();
      } else {
        stdout.writeln('\x1B[33mInitial setup required.\x1B[0m');
        stdout.writeln();
        await _handleSetup();
      }
    } else if (_cliArgs.forceSetup) {
      await _handleSetup();
    }

    // Check for daemon mode: ./geogram-cli station (runs station server without interactive prompt)
    if (_cliArgs.daemonMode) {
      await _runDaemonMode();
      return;
    }

    await _commandLoop();
  }

  /// Create a new identity based on CLI arguments
  Future<void> _createNewIdentity() async {
    final profileType = _cliArgs.isStation ? ProfileType.station : ProfileType.client;
    final typeStr = _cliArgs.isStation ? 'station' : 'client';

    stdout.writeln('Creating new $typeStr identity...');

    final profile = await _profileService.createProfile(
      type: profileType,
      nickname: _cliArgs.nickname,
    );

    stdout.writeln('\x1B[32mProfile created successfully!\x1B[0m');
    stdout.writeln('  Callsign: \x1B[36m${profile.callsign}\x1B[0m');
    stdout.writeln('  Type:     \x1B[36m$typeStr\x1B[0m');
    if (_cliArgs.nickname != null && _cliArgs.nickname!.isNotEmpty) {
      stdout.writeln('  Nickname: \x1B[36m${_cliArgs.nickname}\x1B[0m');
    }
    stdout.writeln();

    // Sync profile to station settings - for station profiles, sync the identity
    // so the station server uses the same npub/nsec as the profile
    var updatedSettings = _station.settings;

    if (_cliArgs.isStation && profile.npub.isNotEmpty && profile.nsec.isNotEmpty) {
      // Sync station identity from profile to station server
      updatedSettings = updatedSettings.copyWith(
        npub: profile.npub,
        nsec: profile.nsec,
      );
    }

    // Sync location if available (profile or CliLocationService fallback)
    double? latitude = profile.latitude;
    double? longitude = profile.longitude;
    String? locationName = profile.locationName;

    if (latitude == null || longitude == null) {
      // Try IP-based geolocation via parent station
      final parentUrl = _station.settings.parentStationUrl;
      if (parentUrl != null && parentUrl.isNotEmpty) {
        final geoIpResult = await CliLocationService().detectLocationViaIP(stationUrl: parentUrl);
        if (geoIpResult != null) {
          latitude = geoIpResult.latitude;
          longitude = geoIpResult.longitude;
          locationName = geoIpResult.locationName;
        }
      }
    }

    if (latitude != null && longitude != null) {
      updatedSettings = updatedSettings.copyWith(
        latitude: latitude,
        longitude: longitude,
        location: locationName,
      );
    }

    // Update settings and reinitialize chat if identity changed
    if (updatedSettings != _station.settings) {
      final identityChanged = _cliArgs.isStation &&
          (updatedSettings.npub != _station.settings.npub ||
           updatedSettings.nsec != _station.settings.nsec);

      await _station.updateSettings(updatedSettings);

      // If station identity changed, reinitialize chat for the new callsign
      if (identityChanged) {
        await _station.reinitializeChatForCurrentIdentity();
      }
    }
  }

  Future<void> _initializeServices() async {
    try {
      // Initialize profile service first
      await _profileService.initialize();

      // Initialize station server
      await _station.initialize();

      // Sync profile location to station settings (for /status endpoint)
      final profile = _profileService.activeProfile;
      if (profile != null) {
        double? latitude = profile.latitude;
        double? longitude = profile.longitude;
        String? locationName = profile.locationName;

        // Fallback to IP-based geolocation via parent station
        if (latitude == null || longitude == null) {
          final parentUrl = _station.settings.parentStationUrl;
          if (parentUrl != null && parentUrl.isNotEmpty) {
            final geoIpResult = await CliLocationService().detectLocationViaIP(stationUrl: parentUrl);
            if (geoIpResult != null) {
              latitude = geoIpResult.latitude;
              longitude = geoIpResult.longitude;
              locationName = geoIpResult.locationName;
            }
          }
        }

        if (latitude != null && longitude != null) {
          final updatedSettings = _station.settings.copyWith(
            latitude: latitude,
            longitude: longitude,
            location: locationName,
          );
          await _station.updateSettings(updatedSettings);
        }
      }

      // Enable quiet mode by default (logs go to buffer, not stderr)
      // Users can disable with 'verbose' command or view logs with 'top'/'tail'
      _station.quietMode = true;

      // Initialize SSL manager
      _sslManager = SslCertificateManager(_station.settings, _station.dataDir!);
      await _sslManager!.initialize();
      _sslManager!.setStationServer(_station);
      _sslManager!.startAutoRenewal();

      // Initialize game engine (games stored in console folder)
      await _gameConfig.initialize('${_station.dataDir!}/console');

      // Initialize cache service
      await _cacheService.initialize();

      // Load command history
      await _loadHistory();

      // Subscribe to chat message events for real-time display
      _chatMessageSubscription = _station.eventBus.on<ChatMessageEvent>((event) {
        _handleIncomingChatMessage(event);
      });
      // Build command registry
      _registry = _buildRegistry();
    } catch (e, stackTrace) {
      _printError('Failed to initialize services: $e');
      _printError('Stack trace: $stackTrace');
      exit(1);
    }
  }

  /// Detect the current platform environment.
  static CommandEnvironment _detectEnvironment() {
    if (Platform.isLinux) return CommandEnvironment.linux;
    if (Platform.isWindows) return CommandEnvironment.windows;
    if (Platform.isMacOS) return CommandEnvironment.macOS;
    // CLI doesn't run on mobile, but fall back to all-inclusive
    return CommandEnvironment.linux;
  }

  /// Build the command registry with all commands.
  CommandRegistry _buildRegistry() {
    final registry = CommandRegistry(environment: _detectEnvironment());

    registry.registerAll([
      // General / System
      HelpCommand(registry),
      ClearCommand(),
      QuitCommand(),
      BroadcastCommand(),
      KickCommand(),
      QuietCommand(),
      VerboseCommand(),
      RestartCommand(),
      ReloadCommand(),
      SetupCommand(onSetup: _handleSetup),
      StatusCommand(),
      StatsCommand(),
      // Station
      StationCommand(),
      // Profile
      ProfileCommand(onSetup: _handleSetup),
      // Chat
      ChatCommand(),
      // Devices
      DevicesCommand(),
      // Config
      ConfigCommand(),
      // SSL
      SslCommand(),
      // Games
      GamesCommand(),
      PlayCommand(),
      // Monitoring
      LogsCommand(),
      TailCommand(),
      HeadCommand(),
      CatCommand(),
      DfCommand(),
      TopCommand(),
    ]);

    return registry;
  }

  /// Build a [CommandContext] for the current console state.
  CommandContext _buildCommandContext(List<String> args) {
    return CommandContext(
      io: _io,
      currentPath: _currentPath,
      currentChatRoom: _currentChatRoom,
      args: args,
      station: _station,
      profileService: _profileService,
      sslManager: _sslManager,
      gameConfig: _gameConfig,
      cacheService: _cacheService,
      onNavigate: (path, chatRoom) {
        _currentPath = path;
        _currentChatRoom = chatRoom;
      },
      onStationRestart: () => _station.restart(),
      onStationReload: () => _station.reloadSettings(),
      onShutdown: _cleanup,
    );
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
  bool _stdinListenedTo = false; // Track if we've ever listened to stdin

  /// Current input line state (for async message display)
  String _currentInputBuffer = '';
  int _currentInputIndex = 0;
  String _currentPrompt = '';

  /// Initialize async stdin reading
  void _initAsyncStdin() {
    // stdin is a single-subscription stream - can only listen once
    if (_stdinListenedTo) return;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
    } catch (e) {
      // Ignore terminal mode errors when running non-interactively (e.g., nohup, screen detached)
      // The station will still work, just without fancy input handling
    }
    _stdinListenedTo = true;
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

  /// Read a line asynchronously for non-terminal input
  /// This allows the HTTP server to process requests while waiting for input
  Future<String?> _readLineAsync() async {
    _initAsyncStdin();
    final buffer = StringBuffer();

    while (true) {
      final byte = await _readByteAsync();
      if (byte == -1) continue; // EOF marker, keep reading

      // Enter (CR or LF)
      if (byte == 13 || byte == 10) {
        return buffer.toString().trim();
      }

      // CTRL+C
      if (byte == 3) {
        return '__EXIT__';
      }

      // CTRL+D (EOF)
      if (byte == 4) {
        if (buffer.isEmpty) {
          return 'quit';
        }
        continue;
      }

      // Regular character
      if (byte >= 32 && byte <= 126) {
        buffer.writeCharCode(byte);
      }
    }
  }

  /// Read a line with TAB completion and history support
  Future<String?> _readLineWithCompletion(String prompt) async {
    // Check if stdin is a terminal
    if (!stdin.hasTerminal) {
      stdout.write(prompt);
      // Use async reading for non-terminal input to not block the event loop
      // This allows HTTP server to process requests while waiting for input
      return await _readLineAsync();
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

  /// Get completion candidates based on current input.
  ///
  /// Delegates to the command registry for command/subcommand completion,
  /// but handles path completion for ls/cd directly.
  List<Candidate> _getCompletions(String buffer) {
    final parts = buffer.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final endsWithSpace = buffer.endsWith(' ');

    // Special case: ls/cd path completion (not in registry)
    if (parts.isNotEmpty) {
      final firstWord = parts[0].toLowerCase();
      if ((firstWord == 'ls' || firstWord == 'cd') && (parts.length > 1 || endsWithSpace)) {
        final partial = parts.length > 1 ? parts[1] : '';
        return _completePaths(partial);
      }
    }

    // Also add navigation commands (ls, cd, pwd) to first-word completion
    final ctx = _buildCommandContext(const []);
    final registryCandidates = _registry.getCompletions(buffer, ctx);

    // Convert CompletionCandidate → Candidate and merge with navigation commands
    final candidates = <Candidate>[];
    final seen = <String>{};

    for (final rc in registryCandidates) {
      if (seen.add(rc.value)) {
        candidates.add(Candidate(
          rc.value,
          display: rc.description != null ? '${rc.value} - ${rc.description}' : rc.value,
          group: rc.group,
          complete: rc.complete,
        ));
      }
    }

    // Add navigation commands for first-word completion
    if (parts.isEmpty || (parts.length == 1 && !endsWithSpace)) {
      final partial = parts.isNotEmpty ? parts[0].toLowerCase() : '';
      for (final nav in ['ls', 'cd', 'pwd']) {
        if (nav.startsWith(partial) && seen.add(nav)) {
          candidates.add(Candidate(nav, group: 'Navigation'));
        }
      }
    }

    return candidates;
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

    // Navigation commands stay on the console host (they mutate _currentPath)
    switch (command) {
      case 'ls':
        // Special: in chat room, ls shows chat history
        if (_currentChatRoom != null) {
          await _handleChatHistory(args);
        } else {
          _handleLs(args);
        }
        return false;
      case 'cd':
        await _handleCd(args);
        return false;
      case 'pwd':
        stdout.writeln(_currentPath);
        return false;
    }

    // Dispatch everything else through the command registry
    final ctx = _buildCommandContext(args);
    final result = await _registry.dispatch(command, args, ctx);

    switch (result) {
      case DispatchResult.ok:
        return false;
      case DispatchResult.exit:
        return true;
      case DispatchResult.requiresStation:
        _printError('This command requires a station profile.');
        return false;
      case DispatchResult.notFound:
        _printError('Unknown command: $command. Type "help" for available commands.');
        return false;
    }
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

  Future<void> _handleChatHistory(List<String> args) async {
    if (_currentChatRoom == null) return;
    final limit = args.isNotEmpty ? int.tryParse(args[0]) : null;
    await _showChatHistory(_currentChatRoom!, limit);
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

  String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  /// Run email DNS diagnostics command (handles auto-detection)
  Future<void> _runEmailDnsDiagnosticsCommand() async {
    String? domain = _cliArgs.emailDnsDomain;
    String? dkimPrivateKey;
    Map<String, dynamic>? configJson;
    String? configPath;

    // Initialize storage to find config file
    await PureStorageConfig().init(
      customBaseDir: _cliArgs.dataDir,
      createDirectories: false,
    );

    configPath = PureStorageConfig().stationConfigPath;
    final configFile = File(configPath);

    // If no domain specified, try to read from station config
    if (domain == null || domain.isEmpty) {
      stdout.writeln('\x1B[36mNo domain specified, checking station configuration...\x1B[0m');

      if (await configFile.exists()) {
        try {
          final content = await configFile.readAsString();
          configJson = jsonDecode(content) as Map<String, dynamic>;
          domain = configJson['sslDomain'] as String?;
          dkimPrivateKey = configJson['dkimPrivateKey'] as String?;

          if (domain != null && domain.isNotEmpty) {
            stdout.writeln('\x1B[32mFound domain in config: $domain\x1B[0m');
          }
        } catch (e) {
          stdout.writeln('\x1B[33mWarning: Could not read station config: $e\x1B[0m');
        }
      } else {
        stdout.writeln('\x1B[33mNo station config found at: $configPath\x1B[0m');
      }
    } else {
      // Domain specified on command line, but still need to read config for DKIM key
      if (await configFile.exists()) {
        try {
          final content = await configFile.readAsString();
          configJson = jsonDecode(content) as Map<String, dynamic>;
          dkimPrivateKey = configJson['dkimPrivateKey'] as String?;
        } catch (_) {}
      }
    }

    // If still no domain, show error
    if (domain == null || domain.isEmpty) {
      stdout.writeln();
      stdout.writeln('\x1B[31mError: No domain configured.\x1B[0m');
      stdout.writeln();
      stdout.writeln('Please either:');
      stdout.writeln('  1. Specify a domain: geogram-cli --email-dns=example.com');
      stdout.writeln('  2. Configure your station domain first:');
      stdout.writeln('     geogram-cli');
      stdout.writeln('     > ssl domain example.com');
      stdout.writeln();
      return;
    }

    // Generate DKIM key only if not present
    bool needsNewKey = dkimPrivateKey == null || dkimPrivateKey.isEmpty;

    if (needsNewKey) {
      stdout.writeln();
      stdout.writeln('\x1B[36mGenerating 1024-bit RSA key pair for DKIM...\x1B[0m');

      try {
        // Use 1024-bit for DNS provider compatibility (shorter public key)
        final keyPair = DkimKeyGenerator.generate(bitLength: 1024);
        dkimPrivateKey = keyPair.privateKeyPem;

        // Save to config
        configJson ??= {};
        configJson['dkimPrivateKey'] = dkimPrivateKey;

        await configFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(configJson),
        );

        stdout.writeln('\x1B[32mDKIM private key generated and saved to station config.\x1B[0m');
      } catch (e) {
        stdout.writeln('\x1B[31mError generating DKIM key: $e\x1B[0m');
      }
    } else {
      stdout.writeln('\x1B[32mUsing existing DKIM key from station config.\x1B[0m');
    }

    await _runEmailDnsDiagnostics(domain, dkimPrivateKey: dkimPrivateKey);
  }

  /// Run email DNS diagnostics for a domain
  Future<void> _runEmailDnsDiagnostics(String domain, {String? dkimPrivateKey}) async {
    stdout.writeln();
    stdout.writeln('\x1B[36mRunning email DNS diagnostics for: $domain\x1B[0m');
    stdout.writeln('Please wait...');

    try {
      final service = EmailDnsService(dkimPrivateKey: dkimPrivateKey);
      final report = await service.diagnose(domain);
      service.printReport(report);

      // If there are missing records, offer to print a zone file template
      if (!report.allPassed && report.serverIp != null) {
        stdout.writeln();
        stdout.writeln('\x1B[1mSuggested DNS Zone Records:\x1B[0m');
        stdout.writeln();
        stdout.writeln(service.generateDnsZone(domain, report.serverIp!));
      }
    } catch (e) {
      stdout.writeln('\x1B[31mError running diagnostics: $e\x1B[0m');
    }
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
