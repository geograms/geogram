/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Command abstraction for the CLI/Desktop console.
 * Each command is a self-describing class with metadata for dispatch,
 * help generation, and TAB completion.
 */

import 'command_context.dart';

/// Command categories for help grouping
enum CommandCategory {
  navigation('Navigation'),
  station('Relay Server'),
  devices('Device Management'),
  chat('Chat Management'),
  config('Configuration'),
  ssl('SSL/TLS Certificates'),
  monitoring('Status & Monitoring'),
  profile('Profile Management'),
  games('Games'),
  general('System');

  final String label;
  const CommandCategory(this.label);
}

/// Target environments for command filtering.
///
/// Commands declare which environments they support via [Command.environments].
/// The registry filters at registration time — dispatch, help, and TAB
/// completion automatically exclude unsupported commands.
enum CommandEnvironment {
  linux('Linux'),
  windows('Windows'),
  macOS('macOS'),
  android('Android'),
  iOS('iOS'),
  esp32('ESP32'),
  web('Web');

  final String label;
  const CommandEnvironment(this.label);

  /// All environments.
  static final Set<CommandEnvironment> all = Set.unmodifiable(values.toSet());

  /// Desktop platforms: Linux, Windows, macOS.
  static final Set<CommandEnvironment> desktop = Set.unmodifiable({linux, windows, macOS});

  /// Mobile platforms: Android, iOS.
  static final Set<CommandEnvironment> mobile = Set.unmodifiable({android, iOS});

  /// CLI-capable platforms: Linux, Windows, macOS, ESP32.
  static final Set<CommandEnvironment> cli = Set.unmodifiable({linux, windows, macOS, esp32});
}

/// Lightweight sub-command descriptor.
///
/// Used for commands like `station start`, `chat list`, etc.
/// Avoids the need for 40+ tiny Command subclasses.
class SubCommand {
  final String name;
  final String description;
  final Future<void> Function(CommandContext ctx) execute;

  /// Optional completer for this sub-command's arguments.
  /// Returns a list of candidate strings.
  final List<String> Function(CommandContext ctx)? completer;

  const SubCommand({
    required this.name,
    required this.description,
    required this.execute,
    this.completer,
  });
}

/// Abstract base class for console commands.
///
/// Each command declares its metadata (name, description, category, etc.)
/// and implements [execute]. Commands with sub-commands populate [subcommands]
/// with [SubCommand] instances; the registry handles dispatch to the right one.
abstract class Command {
  /// Primary command name (e.g., 'station', 'help', 'status')
  String get name;

  /// Alternative names (e.g., ['exit'] for 'quit')
  List<String> get aliases => const [];

  /// One-line description shown in help
  String get description;

  /// Category for help grouping
  CommandCategory get category;

  /// Usage string shown in detailed help (e.g., 'station <start|stop|status>')
  String get usage => name;

  /// Whether this command requires a station profile to run
  bool get requiresStation => false;

  /// Virtual filesystem paths where this command is available as a
  /// context-local command (e.g., ['/station'] means typing 'start'
  /// in /station dispatches to 'station start').
  List<String> get contextPaths => const [];

  /// Environments where this command is available.
  /// Defaults to all environments. Override to restrict.
  Set<CommandEnvironment> get environments => CommandEnvironment.all;

  /// Sub-commands (e.g., 'start', 'stop' for the 'station' command).
  /// Empty for simple commands like 'help' or 'clear'.
  List<SubCommand> get subcommands => const [];

  /// Execute the command.
  ///
  /// For commands with sub-commands, override this to handle the
  /// no-subcommand case (e.g., `station` with no args shows status).
  /// Sub-command dispatch is handled by the registry.
  Future<void> execute(CommandContext ctx);

  /// Return completion candidates for the current input.
  ///
  /// [ctx] contains the args typed so far. Override for custom completion
  /// beyond what subcommands provide automatically.
  List<String> complete(CommandContext ctx) => const [];
}
