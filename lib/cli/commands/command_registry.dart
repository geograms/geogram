/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * CommandRegistry — central registry for command dispatch, help, and completion.
 */

import 'command.dart';
import 'command_context.dart';

/// Result of a command dispatch.
enum DispatchResult {
  /// Command executed normally
  ok,
  /// Command signalled exit (quit/exit/shutdown)
  exit,
  /// Command not found in registry
  notFound,
  /// Command requires station but no station is available
  requiresStation,
}

/// Central registry that holds all commands and provides dispatch,
/// help generation, and TAB completion.
class CommandRegistry {
  final Map<String, Command> _commands = {};
  final Map<String, String> _aliases = {}; // alias → primary name

  /// Optional environment filter. When set, only commands that include this
  /// environment in their [Command.environments] set are registered.
  final CommandEnvironment? environment;

  CommandRegistry({this.environment});

  /// Register a command. All aliases are indexed for lookup.
  /// Skips the command if it doesn't support the current [environment].
  void register(Command command) {
    if (environment != null && !command.environments.contains(environment)) {
      return;
    }
    _commands[command.name] = command;
    for (final alias in command.aliases) {
      _aliases[alias] = command.name;
    }
  }

  /// Register multiple commands at once.
  void registerAll(List<Command> commands) {
    for (final cmd in commands) {
      register(cmd);
    }
  }

  /// Look up a command by name or alias.
  Command? lookup(String name) {
    final cmd = _commands[name];
    if (cmd != null) return cmd;
    final primary = _aliases[name];
    return primary != null ? _commands[primary] : null;
  }

  /// Dispatch a command by name.
  ///
  /// Handles context-aware dispatch: if [ctx.currentPath] matches a command's
  /// [contextPaths], the input is treated as a sub-command of that parent.
  /// For example, typing 'start' in /station dispatches to 'station start'.
  ///
  /// Returns [DispatchResult] indicating what happened.
  Future<DispatchResult> dispatch(
    String name,
    List<String> args,
    CommandContext ctx,
  ) async {
    // 1. Try direct lookup first
    var command = lookup(name);

    // 2. If not found, check context-aware dispatch
    if (command == null) {
      command = _resolveContextCommand(name, ctx.currentPath);
      if (command != null) {
        // Inject the context command name as the first arg
        args = [name, ...args];
      }
    }

    if (command == null) {
      return DispatchResult.notFound;
    }

    // 3. Check station requirement
    if (command.requiresStation && ctx.station == null) {
      return DispatchResult.requiresStation;
    }

    // 4. Dispatch to sub-command or main execute
    final subCtx = ctx.copyWith(args: args);

    if (args.isNotEmpty && command.subcommands.isNotEmpty) {
      final subName = args[0].toLowerCase();
      for (final sub in command.subcommands) {
        if (sub.name == subName) {
          final subSubCtx = subCtx.copyWith(args: args.length > 1 ? args.sublist(1) : []);
          await sub.execute(subSubCtx);
          return DispatchResult.ok;
        }
      }
    }

    // No matching sub-command (or no args) — call main execute
    await command.execute(subCtx);
    return DispatchResult.ok;
  }

  /// Find a command whose [contextPaths] match [currentPath] and whose
  /// subcommands include [name].
  Command? _resolveContextCommand(String name, String currentPath) {
    for (final cmd in _commands.values) {
      for (final ctxPath in cmd.contextPaths) {
        if (currentPath == ctxPath || currentPath.startsWith('$ctxPath/')) {
          // Check if 'name' is a sub-command of this command
          for (final sub in cmd.subcommands) {
            if (sub.name == name) {
              return cmd;
            }
          }
        }
      }
    }
    return null;
  }

  /// Get TAB completion candidates for the given input at the current path.
  List<CompletionCandidate> getCompletions(String input, CommandContext ctx) {
    final parts = input.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final endsWithSpace = input.endsWith(' ');

    if (parts.isEmpty) {
      return _getAvailableCommands('', ctx);
    }

    final firstWord = parts[0].toLowerCase();

    // Completing the command name itself
    if (parts.length == 1 && !endsWithSpace) {
      return _getAvailableCommands(firstWord, ctx);
    }

    // Look up the command
    var command = lookup(firstWord);
    command ??= _resolveContextCommand(firstWord, ctx.currentPath);

    if (command == null) return [];

    // Sub-command completion
    if (command.subcommands.isNotEmpty) {
      final effectiveLen = endsWithSpace ? parts.length + 1 : parts.length;

      if (effectiveLen == 2) {
        final partial = parts.length > 1 ? parts[1].toLowerCase() : '';
        return command.subcommands
            .where((s) => s.name.startsWith(partial))
            .map((s) => CompletionCandidate(
                  s.name,
                  description: s.description,
                  group: '${command!.name} commands',
                ))
            .toList();
      }

      // Try sub-command's own completer
      if (effectiveLen >= 3 && parts.length >= 2) {
        final subName = parts[1].toLowerCase();
        for (final sub in command.subcommands) {
          if (sub.name == subName && sub.completer != null) {
            final partial = parts.length > 2 ? parts.last.toLowerCase() : '';
            final subCtx = ctx.copyWith(
              args: parts.length > 2 ? parts.sublist(2) : [],
            );
            return sub.completer!(subCtx)
                .where((c) => c.toLowerCase().startsWith(partial))
                .map((c) => CompletionCandidate(c))
                .toList();
          }
        }
      }
    }

    // Fall back to command's own completer
    final completeCtx = ctx.copyWith(args: parts.sublist(1));
    final customs = command.complete(completeCtx);
    if (customs.isNotEmpty) {
      final partial = endsWithSpace ? '' : (parts.length > 1 ? parts.last.toLowerCase() : '');
      return customs
          .where((c) => c.toLowerCase().startsWith(partial))
          .map((c) => CompletionCandidate(c))
          .toList();
    }

    return [];
  }

  /// Get command candidates matching a partial input, including context commands.
  List<CompletionCandidate> _getAvailableCommands(String partial, CommandContext ctx) {
    final candidates = <CompletionCandidate>[];
    final seen = <String>{};
    final lowerPartial = partial.toLowerCase();

    // Context-local sub-commands (e.g., 'start' when in /station)
    for (final cmd in _commands.values) {
      for (final ctxPath in cmd.contextPaths) {
        if (ctx.currentPath == ctxPath || ctx.currentPath.startsWith('$ctxPath/')) {
          for (final sub in cmd.subcommands) {
            if (sub.name.startsWith(lowerPartial) && seen.add(sub.name)) {
              final dirName = ctxPath.substring(1).toUpperCase();
              candidates.add(CompletionCandidate(
                sub.name,
                description: sub.description,
                group: '$dirName commands',
              ));
            }
          }
        }
      }
    }

    // Global commands
    for (final cmd in _commands.values) {
      if (cmd.name.startsWith(lowerPartial) && seen.add(cmd.name)) {
        candidates.add(CompletionCandidate(
          cmd.name,
          description: cmd.description,
          group: cmd.category.label,
        ));
      }
      for (final alias in cmd.aliases) {
        if (alias.startsWith(lowerPartial) && seen.add(alias)) {
          candidates.add(CompletionCandidate(
            alias,
            description: cmd.description,
            group: cmd.category.label,
          ));
        }
      }
    }

    return candidates;
  }

  /// Generate help text grouped by category.
  ///
  /// If [stationOnly] is false, commands marked [requiresStation] are hidden.
  String generateHelp({bool stationAvailable = true}) {
    final buf = StringBuffer();
    buf.writeln();
    buf.writeln('\x1B[1mAvailable Commands:\x1B[0m');
    buf.writeln();

    // Group commands by category
    final grouped = <CommandCategory, List<Command>>{};
    for (final cmd in _commands.values) {
      if (cmd.requiresStation && !stationAvailable) continue;
      grouped.putIfAbsent(cmd.category, () => []).add(cmd);
    }

    // Print in enum order
    for (final cat in CommandCategory.values) {
      final cmds = grouped[cat];
      if (cmds == null || cmds.isEmpty) continue;

      buf.writeln('  \x1B[33m${cat.label}:\x1B[0m');
      for (final cmd in cmds) {
        final nameStr = cmd.usage.padRight(30);
        buf.writeln('    $nameStr ${cmd.description}');
      }
      buf.writeln();
    }

    buf.writeln('  \x1B[90mTip: Type "command ?" for syntax help (e.g., "chat create ?")\x1B[0m');
    buf.writeln();

    return buf.toString();
  }

  /// Whether [name] matches a registered command or alias.
  bool isKnownCommand(String name) {
    final lower = name.toLowerCase();
    return _commands.containsKey(lower) || _aliases.containsKey(lower);
  }

  /// Get all registered commands (for iteration).
  Iterable<Command> get commands => _commands.values;
}

/// Completion candidate with value, description, and grouping.
class CompletionCandidate {
  final String value;
  final String? description;
  final String? group;
  final bool complete;

  CompletionCandidate(
    this.value, {
    this.description,
    this.group,
    this.complete = true,
  });
}
