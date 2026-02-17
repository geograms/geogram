/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * CommandContext — flat context object passed to every command.
 * Holds I/O, navigation state, and service references.
 */

import '../console_io.dart';

/// Context passed to every [Command.execute] call.
///
/// Services are held as [Object?] so that both CLI and Desktop can
/// provide their own implementations without import conflicts.
/// Commands cast to the concrete type they need (e.g., PureStationServer
/// for CLI, or StationServiceInterface for Desktop).
class CommandContext {
  /// Platform-agnostic I/O
  final ConsoleIO io;

  /// Current virtual filesystem path (e.g., '/', '/station', '/chat/general')
  final String currentPath;

  /// Current chat station callsign when inside /chat/<station>
  final String? currentChatStation;

  /// Current chat room ID when inside /chat/<station>/<room>
  final String? currentChatRoom;

  /// Command arguments (everything after the command name)
  final List<String> args;

  // --- Service references ---
  // Typed as Object? to avoid coupling commands to a specific platform.
  // CLI passes: PureStationServer, CliProfileService, SslCertificateManager, etc.
  // Desktop passes: StationServiceInterface, ProfileServiceInterface, etc.

  /// Station/server service (PureStationServer or StationServiceInterface)
  final Object? station;

  /// Profile service (CliProfileService or ProfileServiceInterface)
  final Object? profileService;

  /// SSL certificate manager (SslCertificateManager or null)
  final Object? sslManager;

  /// Game configuration
  final Object? gameConfig;

  /// Station cache service
  final Object? cacheService;

  /// Callback to mutate console state (e.g., navigate to a new path).
  /// This is set by the console host, not by commands.
  final void Function(String path, String? chatStation, String? chatRoom)? onNavigate;

  /// Callback for station restart (CLI-specific, wraps _station.restart())
  final Future<void> Function()? onStationRestart;

  /// Callback for station reload settings
  final Future<void> Function()? onStationReload;

  /// Callback for clean shutdown
  final Future<void> Function()? onShutdown;

  CommandContext({
    required this.io,
    this.currentPath = '/',
    this.currentChatStation,
    this.currentChatRoom,
    this.args = const [],
    this.station,
    this.profileService,
    this.sslManager,
    this.gameConfig,
    this.cacheService,
    this.onNavigate,
    this.onStationRestart,
    this.onStationReload,
    this.onShutdown,
  });

  // --- Convenience I/O ---

  void writeln([String text = '']) => io.writeln(text);
  void write(String text) => io.write(text);

  /// Print an error message (red on terminals that support ANSI)
  void error(String msg) => io.writeln('\x1B[31m$msg\x1B[0m');

  /// Print a success message (green on terminals that support ANSI)
  void success(String msg) => io.writeln('\x1B[32m$msg\x1B[0m');

  /// Print bold text
  void bold(String msg) => io.writeln('\x1B[1m$msg\x1B[0m');

  /// Print a section header (yellow)
  void section(String title) => io.writeln('\x1B[1;33m$title\x1B[0m');

  /// Print a colored category header
  void category(String title) => io.writeln('  \x1B[33m$title\x1B[0m');

  /// Print dim/gray text
  void dim(String msg) => io.writeln('\x1B[90m$msg\x1B[0m');

  // --- Context queries ---

  /// Whether the current path is under a given directory
  bool isInPath(String prefix) =>
      currentPath == prefix || currentPath.startsWith('$prefix/');

  /// Create a copy with different args (for sub-command dispatch)
  CommandContext copyWith({
    List<String>? args,
    String? currentPath,
    String? currentChatStation,
    String? currentChatRoom,
  }) {
    return CommandContext(
      io: io,
      currentPath: currentPath ?? this.currentPath,
      currentChatStation: currentChatStation ?? this.currentChatStation,
      currentChatRoom: currentChatRoom ?? this.currentChatRoom,
      args: args ?? this.args,
      station: station,
      profileService: profileService,
      sslManager: sslManager,
      gameConfig: gameConfig,
      cacheService: cacheService,
      onNavigate: onNavigate,
      onStationRestart: onStationRestart,
      onStationReload: onStationReload,
      onShutdown: onShutdown,
    );
  }
}
