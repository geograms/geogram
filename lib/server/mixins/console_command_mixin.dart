// Console command mixin for station servers
// Provides shared /api/cli endpoint implementation using CommandRegistry + NavigationHandler

import 'dart:io';

import '../../cli/commands/command.dart';
import '../../cli/commands/command_context.dart';
import '../../cli/commands/command_registry.dart';
import '../../cli/commands/general_commands.dart';
import '../../cli/commands/station_command.dart';
import '../../cli/commands/devices_command.dart';
import '../../cli/commands/nip05_command.dart';
import '../../cli/commands/chat_command.dart';
import '../../cli/commands/config_command.dart';
import '../../cli/commands/monitoring_commands.dart';
import '../../cli/commands/navigation_handler.dart';
import '../../cli/commands/service_interfaces.dart';
import '../../cli/console_io.dart';
import '../../cli/console_io_buffer.dart';

/// Mixin providing shared console command execution for station servers.
///
/// Both [StationServer] (station.dart) and [PureStationServer] (pure_station.dart)
/// mix this in and call [executeConsoleCommand] from their `/api/cli` handler.
mixin ConsoleCommandMixin {
  // ── Abstract slots the host station must provide ──

  /// The station as [StationCommandInterface] for command dispatch and navigation.
  StationCommandInterface get consoleStationInterface;

  /// Profile service (null when running as a station server).
  ProfileCommandInterface? get consoleProfileInterface => null;

  /// Game configuration (null by default).
  Object? get consoleGameConfig => null;

  /// SSL manager (null by default).
  Object? get consoleSslManager => null;

  /// Root directories available in the virtual filesystem.
  List<String> get consoleRootDirs {
    final dirs = ['chat', 'devices', 'config', 'logs'];
    if (consoleStationInterface.isRunning) dirs.add('station');
    dirs.sort();
    return dirs;
  }

  // ── Lazily initialized console infrastructure ──

  BufferConsoleIO? _consoleIo;
  CommandRegistry? _consoleRegistry;
  NavigationHandler? _consoleNav;

  BufferConsoleIO get _io => _consoleIo ??= BufferConsoleIO();

  CommandRegistry get _registry {
    if (_consoleRegistry == null) {
      _consoleRegistry = CommandRegistry(environment: _detectEnvironment());
      _consoleRegistry!.registerAll([
        HelpCommand(_consoleRegistry!),
        StatusCommand(),
        StatsCommand(),
        StationCommand(),
        DevicesCommand(),
        Nip05Command(),
        ChatCommand(),
        ConfigCommand(),
        LogsCommand(),
        BroadcastCommand(),
        KickCommand(),
        QuietCommand(),
        VerboseCommand(),
        ReloadCommand(),
      ]);
    }
    return _consoleRegistry!;
  }

  NavigationHandler get _nav =>
      _consoleNav ??= NavigationHandler(_ConsoleDataProvider(this));

  /// Execute a console command and return the result as a JSON-encodable map.
  ///
  /// Navigation state (cd) is preserved across calls.
  Future<Map<String, dynamic>> executeConsoleCommand(String input) async {
    _io.clearOutput();

    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return {
        'status': 'ok',
        'output': '',
        'path': _nav.currentPath,
      };
    }

    final parts = trimmed.split(RegExp(r'\s+'));
    final command = parts[0].toLowerCase();
    final args = parts.length > 1 ? parts.sublist(1) : <String>[];

    // Handle navigation commands via shared handler
    if (command == 'ls') {
      _nav.handleLs(args);
      return _result();
    }
    if (command == 'cd') {
      await _nav.handleCd(args);
      return _result();
    }
    if (command == 'pwd') {
      _nav.handlePwd();
      return _result();
    }

    // Dispatch via registry
    final ctx = CommandContext(
      io: _io,
      currentPath: _nav.currentPath,
      currentChatStation: _nav.currentChatStation,
      currentChatRoom: _nav.currentChatRoom,
      args: args,
      station: consoleStationInterface,
      profileService: consoleProfileInterface,
      sslManager: consoleSslManager,
      gameConfig: consoleGameConfig,
    );
    final result = await _registry.dispatch(command, args, ctx);

    switch (result) {
      case DispatchResult.ok:
      case DispatchResult.exit:
        break;
      case DispatchResult.notFound:
        _io.writeln('Unknown command: $command');
        _io.writeln('Type "help" for available commands.');
        break;
      case DispatchResult.requiresStation:
        _io.writeln('Station not running. Start with "station start".');
        break;
    }

    return _result();
  }

  Map<String, dynamic> _result() {
    return {
      'status': 'ok',
      'output': _io.getOutput() ?? '',
      'path': _nav.currentPath,
    };
  }

  static CommandEnvironment _detectEnvironment() {
    if (Platform.isLinux) return CommandEnvironment.linux;
    if (Platform.isWindows) return CommandEnvironment.windows;
    if (Platform.isMacOS) return CommandEnvironment.macOS;
    if (Platform.isAndroid) return CommandEnvironment.android;
    if (Platform.isIOS) return CommandEnvironment.iOS;
    return CommandEnvironment.linux;
  }
}

/// NavigationDataProvider backed by the mixin's abstract slots.
class _ConsoleDataProvider implements NavigationDataProvider {
  final ConsoleCommandMixin _mixin;
  _ConsoleDataProvider(this._mixin);

  @override
  ConsoleIO get io => _mixin._io;

  @override
  List<String> get rootDirs => _mixin.consoleRootDirs;

  @override
  StationCommandInterface? get stationInterface =>
      _mixin.consoleStationInterface;

  @override
  ProfileCommandInterface? get profileInterface =>
      _mixin.consoleProfileInterface;

  @override
  Object? get gameConfig => _mixin.consoleGameConfig;

  @override
  Object? get sslManager => _mixin.consoleSslManager;
}
