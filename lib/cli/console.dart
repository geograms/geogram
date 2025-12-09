import 'dart:io';

import '../models/profile.dart';
import '../services/log_service.dart';
import '../services/config_service.dart';
import '../services/collection_service.dart';
import '../services/profile_service.dart';
import '../services/callsign_generator.dart';
import '../services/station_server_service.dart';
import '../services/web_theme_service.dart';
import '../services/log_api_service.dart';
import '../services/security_service.dart';
import '../services/storage_config.dart';
import '../services/app_args.dart';
import '../version.dart';

/// Main CLI console for geogram-desktop
class Console {
  /// Virtual filesystem current path
  String _currentPath = '/';

  /// Root directories in virtual filesystem
  static const List<String> rootDirs = ['profiles', 'config', 'logs', 'station'];

  /// Directory-specific commands
  static const Map<String, List<String>> dirCommands = {
    '/': ['ls', 'cd', 'pwd', 'status', 'help', 'quit', 'exit', 'clear', 'station', 'theme'],
    '/profiles': ['ls', 'cd', 'pwd', 'profile', 'status', 'help', 'quit', 'exit', 'clear'],
    '/config': ['ls', 'cd', 'pwd', 'set', 'get', 'theme', 'status', 'help', 'quit', 'exit', 'clear'],
    '/logs': ['ls', 'cd', 'pwd', 'tail', 'status', 'help', 'quit', 'exit', 'clear'],
    '/station': ['ls', 'cd', 'pwd', 'start', 'stop', 'status', 'port', 'cache', 'help', 'quit', 'exit', 'clear'],
  };

  /// Run CLI mode
  Future<void> run(List<String> args) async {
    await _initializeServices();
    _printBanner();
    await _commandLoop();
  }

  /// Initialize services for CLI mode
  Future<void> _initializeServices() async {
    try {
      // Initialize storage configuration first (uses custom data dir from CLI args)
      await StorageConfig().init(customBaseDir: AppArgs().dataDir);

      await LogService().init();
      await ConfigService().init();
      await CollectionService().init();
      await ProfileService().initialize();

      // Set active callsign
      final profile = ProfileService().getProfile();
      await CollectionService().setActiveCallsign(profile.callsign);

      // Initialize station server service
      await StationServerService().initialize();

      // Initialize web theme service
      await WebThemeService().init();

      // Start HTTP API if requested via command line
      if (AppArgs().httpApi) {
        SecurityService().httpApiEnabled = true;
        await LogApiService().start();
        LogService().log('HTTP API started on port ${LogApiService().port} (CLI mode)');
        stdout.writeln('HTTP API started on port ${LogApiService().port}');
      }

      // Enable Debug API if requested via command line
      if (AppArgs().debugApi) {
        SecurityService().debugApiEnabled = true;
        LogService().log('Debug API enabled (CLI mode)');
      }

      LogService().log('CLI services initialized');
    } catch (e) {
      _printError('Failed to initialize services: $e');
      exit(1);
    }
  }

  /// Print welcome banner
  void _printBanner() {
    final profile = ProfileService().getProfile();
    final isStation = CallsignGenerator.isStationCallsign(profile.callsign);

    stdout.writeln();
    stdout.writeln('\x1B[36m' + '=' * 60 + '\x1B[0m');
    stdout.writeln('\x1B[36m  Geogram Desktop v$appVersion - CLI Mode\x1B[0m');
    stdout.writeln('\x1B[36m  Active Profile: ${profile.callsign}${isStation ? ' (Relay)' : ''}\x1B[0m');
    stdout.writeln('\x1B[36m' + '=' * 60 + '\x1B[0m');
    stdout.writeln();
    stdout.writeln('Type "help" for available commands.');
    stdout.writeln();
  }

  /// Main command loop
  Future<void> _commandLoop() async {
    while (true) {
      stdout.write('\x1B[32mgeogram:$_currentPath\$ \x1B[0m');

      final input = stdin.readLineSync()?.trim();
      if (input == null || input.isEmpty) continue;

      final parts = input.split(RegExp(r'\s+'));
      final command = parts[0].toLowerCase();
      final args = parts.length > 1 ? parts.sublist(1) : <String>[];

      try {
        final shouldExit = await _processCommand(command, args);
        if (shouldExit) break;
      } catch (e) {
        _printError('Error: $e');
      }
    }
  }

  /// Process a single command
  Future<bool> _processCommand(String command, List<String> args) async {
    // Check if we're in /station directory for station-specific commands
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
      }
    }

    switch (command) {
      case 'help':
        _printHelp();
        break;
      case 'status':
        _printStatus();
        break;
      case 'ls':
        _handleLs(args);
        break;
      case 'cd':
        _handleCd(args);
        break;
      case 'pwd':
        stdout.writeln(_currentPath);
        break;
      case 'profile':
        await _handleProfile(args);
        break;
      case 'station':
        await _handleRelay(args);
        break;
      case 'theme':
        await _handleTheme(args);
        break;
      case 'clear':
        stdout.write('\x1B[2J\x1B[H');
        break;
      case 'quit':
      case 'exit':
        // Stop station server if running
        if (StationServerService().isRunning) {
          stdout.writeln('Stopping station server...');
          await StationServerService().stop();
        }
        stdout.writeln('Goodbye!');
        return true;
      default:
        _printError('Unknown command: $command. Type "help" for available commands.');
    }
    return false;
  }

  /// Print help message
  void _printHelp() {
    stdout.writeln();
    stdout.writeln('\x1B[1mAvailable Commands:\x1B[0m');
    stdout.writeln();
    stdout.writeln('  \x1B[33mNavigation:\x1B[0m');
    stdout.writeln('    ls [path]          List directory contents');
    stdout.writeln('    cd <path>          Change directory');
    stdout.writeln('    pwd                Print working directory');
    stdout.writeln();
    stdout.writeln('  \x1B[33mProfile Management:\x1B[0m');
    stdout.writeln('    profile list       List all profiles');
    stdout.writeln('    profile switch <id|callsign>  Switch active profile');
    stdout.writeln('    profile create [--station]      Create new profile');
    stdout.writeln('    profile info [id]  Show profile details');
    stdout.writeln();
    stdout.writeln('  \x1B[33mRelay Server:\x1B[0m');
    stdout.writeln('    station start        Start the station server');
    stdout.writeln('    station stop         Stop the station server');
    stdout.writeln('    station status       Show station server status');
    stdout.writeln('    station port <port>  Set station server port');
    stdout.writeln('    station cache clear  Clear tile cache');
    stdout.writeln('    station cache stats  Show cache statistics');
    stdout.writeln();
    stdout.writeln('  \x1B[33mWeb Themes:\x1B[0m');
    stdout.writeln('    theme              Show current web theme');
    stdout.writeln('    theme list         List available themes');
    stdout.writeln('    theme set <name>   Set the active web theme');
    stdout.writeln('    theme path         Show themes folder path');
    stdout.writeln('    theme reset        Re-extract bundled themes');
    stdout.writeln();
    stdout.writeln('  \x1B[33mGeneral:\x1B[0m');
    stdout.writeln('    status             Show application status');
    stdout.writeln('    help               Show this help message');
    stdout.writeln('    clear              Clear the screen');
    stdout.writeln('    quit / exit        Exit the CLI');
    stdout.writeln();
    stdout.writeln('  \x1B[33mVirtual Filesystem:\x1B[0m');
    stdout.writeln('    /profiles/         List all profiles/callsigns');
    stdout.writeln('    /config/           Configuration settings');
    stdout.writeln('    /logs/             View logs');
    stdout.writeln('    /station/            Station status and commands');
    stdout.writeln();
  }

  /// Print application status
  void _printStatus() {
    final profile = ProfileService().getProfile();
    final profiles = ProfileService().getAllProfiles();
    final isStation = CallsignGenerator.isStationCallsign(profile.callsign);
    final stationStatus = StationServerService().getStatus();

    stdout.writeln();
    stdout.writeln('\x1B[1mGeogram Desktop Status\x1B[0m');
    stdout.writeln('-' * 40);
    stdout.writeln('Version:        $appVersion');
    stdout.writeln('Profile:        ${profile.callsign}');
    stdout.writeln('Mode:           ${isStation ? 'Relay (X3 callsign)' : 'Standard'}');
    stdout.writeln('Total Profiles: ${profiles.length}');
    stdout.writeln('Nickname:       ${profile.nickname.isNotEmpty ? profile.nickname : '(not set)'}');
    stdout.writeln('NPub:           ${_truncateNpub(profile.npub)}');
    stdout.writeln();
    stdout.writeln('\x1B[1mRelay Server:\x1B[0m');
    stdout.writeln('-' * 40);
    if (stationStatus['running'] == true) {
      stdout.writeln('Status:         \x1B[32mRunning\x1B[0m');
      stdout.writeln('Port:           ${stationStatus['port']}');
      stdout.writeln('Devices:        ${stationStatus['connected_devices']}');
      stdout.writeln('Uptime:         ${_formatUptime(stationStatus['uptime'] as int)}');
      stdout.writeln('Cache:          ${stationStatus['cache_size']} tiles (${stationStatus['cache_size_mb']} MB)');
    } else {
      stdout.writeln('Status:         \x1B[33mStopped\x1B[0m');
      stdout.writeln('Port:           ${StationServerService().settings.port}');
    }
    stdout.writeln();
  }

  /// Handle station command
  Future<void> _handleRelay(List<String> args) async {
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
      case 'port':
        await _handleRelayPort(subargs);
        break;
      case 'cache':
        _handleRelayCache(subargs);
        break;
      default:
        _printError('Unknown station command: $subcommand');
        _printError('Available: start, stop, status, port, cache');
    }
  }

  /// Start station server
  Future<void> _handleRelayStart() async {
    if (StationServerService().isRunning) {
      stdout.writeln('\x1B[33mStation server is already running on port ${StationServerService().settings.port}\x1B[0m');
      return;
    }

    stdout.writeln('Starting station server on port ${StationServerService().settings.port}...');
    final success = await StationServerService().start();

    if (success) {
      stdout.writeln('\x1B[32mStation server started successfully\x1B[0m');
      stdout.writeln('  Port: ${StationServerService().settings.port}');
      stdout.writeln('  Status: http://localhost:${StationServerService().settings.port}/api/status');
      stdout.writeln('  Tiles:  http://localhost:${StationServerService().settings.port}/tiles/{callsign}/{z}/{x}/{y}.png');
    } else {
      _printError('Failed to start station server');
    }
  }

  /// Stop station server
  Future<void> _handleRelayStop() async {
    if (!StationServerService().isRunning) {
      stdout.writeln('\x1B[33mStation server is not running\x1B[0m');
      return;
    }

    stdout.writeln('Stopping station server...');
    await StationServerService().stop();
    stdout.writeln('\x1B[32mStation server stopped\x1B[0m');
  }

  /// Print station status
  void _printRelayStatus() {
    final status = StationServerService().getStatus();
    final settings = StationServerService().settings;

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
    stdout.writeln('Port:          ${settings.port}');
    stdout.writeln('Tile Server:   ${settings.tileServerEnabled ? 'Enabled' : 'Disabled'}');
    stdout.writeln('OSM Fallback:  ${settings.osmFallbackEnabled ? 'Enabled' : 'Disabled'}');
    stdout.writeln('Max Zoom:      ${settings.maxZoomLevel}');
    stdout.writeln('Max Cache:     ${settings.maxCacheSize} MB');
    stdout.writeln();
  }

  /// Handle station port command
  Future<void> _handleRelayPort(List<String> args) async {
    if (args.isEmpty) {
      stdout.writeln('Current port: ${StationServerService().settings.port}');
      return;
    }

    final portStr = args[0];
    final port = int.tryParse(portStr);

    if (port == null || port < 1 || port > 65535) {
      _printError('Invalid port number: $portStr (must be 1-65535)');
      return;
    }

    final settings = StationServerService().settings.copyWith(port: port);
    await StationServerService().updateSettings(settings);

    stdout.writeln('\x1B[32mPort set to $port\x1B[0m');

    if (StationServerService().isRunning) {
      stdout.writeln('Station server will restart on new port...');
    }
  }

  /// Handle station cache command
  void _handleRelayCache(List<String> args) {
    if (args.isEmpty) {
      final status = StationServerService().getStatus();
      stdout.writeln('Cache: ${status['cache_size']} tiles (${status['cache_size_mb']} MB)');
      return;
    }

    final subcommand = args[0].toLowerCase();

    switch (subcommand) {
      case 'clear':
        StationServerService().clearCache();
        stdout.writeln('\x1B[32mCache cleared\x1B[0m');
        break;
      case 'stats':
        final status = StationServerService().getStatus();
        stdout.writeln();
        stdout.writeln('\x1B[1mCache Statistics\x1B[0m');
        stdout.writeln('-' * 30);
        stdout.writeln('Tiles:    ${status['cache_size']}');
        stdout.writeln('Size:     ${status['cache_size_mb']} MB');
        stdout.writeln('Max Size: ${StationServerService().settings.maxCacheSize} MB');
        stdout.writeln();
        break;
      default:
        _printError('Unknown cache command: $subcommand');
        _printError('Available: clear, stats');
    }
  }

  /// Handle theme command
  Future<void> _handleTheme(List<String> args) async {
    final themeService = WebThemeService();

    if (args.isEmpty) {
      // Show current theme
      final currentTheme = themeService.getCurrentTheme();
      stdout.writeln('Current web theme: \x1B[32m$currentTheme\x1B[0m');
      return;
    }

    final subcommand = args[0].toLowerCase();
    final subargs = args.length > 1 ? args.sublist(1) : <String>[];

    switch (subcommand) {
      case 'list':
        await _handleThemeList();
        break;
      case 'set':
        await _handleThemeSet(subargs);
        break;
      case 'path':
        stdout.writeln('Themes folder: ${themeService.themesDir}');
        break;
      case 'reset':
        stdout.writeln('Re-extracting bundled themes...');
        await themeService.resetBundledThemes();
        stdout.writeln('\x1B[32mBundled themes extracted successfully\x1B[0m');
        break;
      default:
        _printError('Unknown theme command: $subcommand');
        _printError('Available: list, set, path, reset');
    }
  }

  /// List available themes
  Future<void> _handleThemeList() async {
    final themeService = WebThemeService();
    final themes = await themeService.getAvailableThemes();
    final currentTheme = themeService.getCurrentTheme();

    stdout.writeln();
    stdout.writeln('\x1B[1mAvailable Web Themes:\x1B[0m');
    stdout.writeln('-' * 40);

    for (final theme in themes) {
      final isActive = theme == currentTheme;
      final marker = isActive ? '\x1B[32m* \x1B[0m' : '  ';
      final label = isActive ? ' (active)' : '';
      stdout.writeln('$marker$theme$label');
    }

    stdout.writeln();
    stdout.writeln('Themes folder: ${themeService.themesDir}');
    stdout.writeln('To add themes, create a new folder with styles.css inside.');
    stdout.writeln();
  }

  /// Set the active theme
  Future<void> _handleThemeSet(List<String> args) async {
    if (args.isEmpty) {
      _printError('Usage: theme set <theme-name>');
      return;
    }

    final themeName = args[0];
    final themeService = WebThemeService();

    // Check if theme exists
    if (!await themeService.themeExists(themeName)) {
      _printError('Theme not found: $themeName');
      stdout.writeln('Use "theme list" to see available themes.');
      return;
    }

    themeService.setCurrentTheme(themeName);
    stdout.writeln('\x1B[32mWeb theme set to: $themeName\x1B[0m');
  }

  /// Handle ls command
  void _handleLs(List<String> args) {
    final path = args.isNotEmpty ? _resolvePath(args[0]) : _currentPath;

    if (path == '/') {
      // Root directory
      for (final dir in rootDirs) {
        stdout.writeln('\x1B[34m$dir/\x1B[0m');
      }
    } else if (path == '/profiles') {
      // List all profiles
      final profiles = ProfileService().getAllProfiles();
      final activeId = ProfileService().activeProfileId;

      for (final profile in profiles) {
        final isActive = profile.id == activeId;
        final isStation = CallsignGenerator.isStationCallsign(profile.callsign);
        final marker = isActive ? '\x1B[32m*\x1B[0m ' : '  ';
        final stationTag = isStation ? ' \x1B[33m[station]\x1B[0m' : '';

        stdout.writeln('$marker\x1B[34m${profile.callsign}/\x1B[0m$stationTag');
      }
    } else if (path.startsWith('/profiles/')) {
      // Contents of a specific profile
      final callsign = path.substring('/profiles/'.length).replaceAll('/', '');
      final profile = ProfileService().getProfileByCallsign(callsign);

      if (profile == null) {
        _printError('Profile not found: $callsign');
        return;
      }

      stdout.writeln('\x1B[34mcollections/\x1B[0m');
      stdout.writeln('\x1B[34mchat/\x1B[0m');
      stdout.writeln('\x1B[34msettings/\x1B[0m');
    } else if (path == '/config') {
      stdout.writeln('\x1B[34mprofile.json\x1B[0m');
      stdout.writeln('\x1B[34mconfig.json\x1B[0m');
      stdout.writeln('\x1B[34mstationServer.json\x1B[0m');
    } else if (path == '/logs') {
      stdout.writeln('\x1B[34mgeogram.log\x1B[0m');
    } else if (path == '/station') {
      final status = StationServerService().isRunning ? '\x1B[32mRunning\x1B[0m' : '\x1B[33mStopped\x1B[0m';
      stdout.writeln('status      $status');
      stdout.writeln('\x1B[34mdevices/\x1B[0m');
      stdout.writeln('\x1B[34mconfig/\x1B[0m');
      stdout.writeln('\x1B[34mcache/\x1B[0m');
    } else {
      _printError('Directory not found: $path');
    }
  }

  /// Handle cd command
  void _handleCd(List<String> args) {
    if (args.isEmpty) {
      _currentPath = '/';
      return;
    }

    final target = _resolvePath(args[0]);

    // Validate the path
    if (target == '/' ||
        rootDirs.contains(target.substring(1).split('/')[0])) {
      _currentPath = target;
    } else {
      _printError('Directory not found: ${args[0]}');
    }
  }

  /// Handle profile commands
  Future<void> _handleProfile(List<String> args) async {
    if (args.isEmpty) {
      _printError('Usage: profile <list|switch|create|info>');
      return;
    }

    final subcommand = args[0].toLowerCase();
    final subargs = args.length > 1 ? args.sublist(1) : <String>[];

    switch (subcommand) {
      case 'list':
        _handleProfileList();
        break;
      case 'switch':
        await _handleProfileSwitch(subargs);
        break;
      case 'create':
        await _handleProfileCreate(subargs);
        break;
      case 'info':
        _handleProfileInfo(subargs);
        break;
      default:
        _printError('Unknown profile command: $subcommand');
    }
  }

  /// List all profiles
  void _handleProfileList() {
    final profiles = ProfileService().getAllProfiles();
    final activeId = ProfileService().activeProfileId;

    stdout.writeln();
    stdout.writeln('\x1B[1mProfiles:\x1B[0m');
    stdout.writeln('-' * 50);

    for (final profile in profiles) {
      final isActive = profile.id == activeId;
      final isStation = CallsignGenerator.isStationCallsign(profile.callsign);
      final marker = isActive ? '\x1B[32m* \x1B[0m' : '  ';
      final modeTag = isStation ? '\x1B[33m[Relay]\x1B[0m' : '\x1B[36m[Standard]\x1B[0m';

      stdout.writeln('$marker${profile.callsign.padRight(12)} $modeTag');
      if (profile.nickname.isNotEmpty) {
        stdout.writeln('    Nickname: ${profile.nickname}');
      }
    }
    stdout.writeln();
  }

  /// Switch to a different profile
  Future<void> _handleProfileSwitch(List<String> args) async {
    if (args.isEmpty) {
      _printError('Usage: profile switch <callsign|id>');
      return;
    }

    final target = args[0];

    // Try to find by callsign first
    var profile = ProfileService().getProfileByCallsign(target);
    profile ??= ProfileService().getProfileById(target);

    if (profile == null) {
      _printError('Profile not found: $target');
      return;
    }

    await ProfileService().switchToProfile(profile.id);
    final isStation = CallsignGenerator.isStationCallsign(profile.callsign);
    stdout.writeln('\x1B[32mSwitched to profile: ${profile.callsign}${isStation ? ' (Relay Mode)' : ''}\x1B[0m');
  }

  /// Create a new profile
  Future<void> _handleProfileCreate(List<String> args) async {
    final isStation = args.contains('--station');

    stdout.writeln('Creating new profile...');

    final profile = await ProfileService().createNewProfile();

    // If station mode, derive X3 callsign
    if (isStation) {
      final x3Callsign = CallsignGenerator.deriveStationCallsign(profile.npub);
      // Update the profile with X3 callsign
      final updatedProfile = profile.copyWith(callsign: x3Callsign);
      await ProfileService().saveProfile(updatedProfile);
      stdout.writeln('\x1B[32mCreated station profile: $x3Callsign\x1B[0m');
    } else {
      stdout.writeln('\x1B[32mCreated profile: ${profile.callsign}\x1B[0m');
    }

    stdout.writeln('Use "profile switch ${isStation ? CallsignGenerator.deriveStationCallsign(profile.npub) : profile.callsign}" to activate.');
  }

  /// Show profile info
  void _handleProfileInfo(List<String> args) {
    Profile? profile;

    if (args.isNotEmpty) {
      profile = ProfileService().getProfileByCallsign(args[0]);
      profile ??= ProfileService().getProfileById(args[0]);
    } else {
      profile = ProfileService().getProfile();
    }

    if (profile == null) {
      _printError('Profile not found');
      return;
    }

    final isStation = CallsignGenerator.isStationCallsign(profile.callsign);
    final isActive = profile.id == ProfileService().activeProfileId;

    stdout.writeln();
    stdout.writeln('\x1B[1mProfile: ${profile.callsign}\x1B[0m${isActive ? ' \x1B[32m(active)\x1B[0m' : ''}');
    stdout.writeln('-' * 40);
    stdout.writeln('ID:       ${profile.id}');
    stdout.writeln('Mode:     ${isStation ? 'Relay (X3)' : 'Standard'}');
    stdout.writeln('Nickname: ${profile.nickname.isNotEmpty ? profile.nickname : '(not set)'}');
    stdout.writeln('NPub:     ${profile.npub}');
    stdout.writeln('Color:    ${profile.preferredColor}');
    if (profile.locationName?.isNotEmpty == true) {
      stdout.writeln('Location: ${profile.locationName}');
    }
    stdout.writeln();
  }

  /// Resolve a relative path to absolute
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

  /// Normalize a path (remove trailing slashes, etc.)
  String _normalizePath(String path) {
    if (path.isEmpty) return '/';
    var normalized = path.replaceAll(RegExp(r'/+'), '/');
    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// Format uptime in human-readable form
  String _formatUptime(int seconds) {
    if (seconds < 60) {
      return '${seconds}s';
    } else if (seconds < 3600) {
      return '${seconds ~/ 60}m ${seconds % 60}s';
    } else if (seconds < 86400) {
      final hours = seconds ~/ 3600;
      final minutes = (seconds % 3600) ~/ 60;
      return '${hours}h ${minutes}m';
    } else {
      final days = seconds ~/ 86400;
      final hours = (seconds % 86400) ~/ 3600;
      return '${days}d ${hours}h';
    }
  }

  /// Truncate npub for display
  String _truncateNpub(String npub) {
    if (npub.length <= 20) return npub;
    return '${npub.substring(0, 12)}...${npub.substring(npub.length - 6)}';
  }

  /// Print error message
  void _printError(String message) {
    stdout.writeln('\x1B[31m$message\x1B[0m');
  }
}

/// Entry point for CLI mode
Future<void> runCliMode(List<String> args) async {
  final console = Console();
  await console.run(args);
}
