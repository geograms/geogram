/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Games command: list, info — plus standalone PlayCommand
 */

import 'dart:io';

import '../game/game_config.dart';
import '../game/game_engine.dart';
import '../game/game_parser.dart';
import '../game/game_screen.dart';
import 'command.dart';
import 'command_context.dart';

/// games — browse and inspect available games
class GamesCommand extends Command {
  @override
  String get name => 'games';
  @override
  String get description => 'Browse available games (list|info)';
  @override
  String get usage => 'games <list|info> [game-name]';
  @override
  CommandCategory get category => CommandCategory.games;
  @override
  List<String> get contextPaths => const ['/games'];

  @override
  List<SubCommand> get subcommands => [
        SubCommand(
          name: 'list',
          description: 'List all available games',
          execute: _list,
        ),
        SubCommand(
          name: 'info',
          description: 'Show details about a game',
          execute: _info,
          completer: _gameCompleter,
        ),
      ];

  @override
  Future<void> execute(CommandContext ctx) async {
    // No sub-command — show list
    await _list(ctx);
  }

  static Future<void> _list(CommandContext ctx) async {
    final gameConfig = ctx.gameConfig as GameConfig?;
    if (gameConfig == null || !gameConfig.isInitialized) {
      ctx.error('Games not initialized');
      return;
    }

    final games = gameConfig.listGames();

    ctx.writeln();
    ctx.bold('Available Games (${games.length})');
    ctx.writeln('-' * 40);

    if (games.isEmpty) {
      ctx.writeln('No games found in ${gameConfig.gamesDirectory}');
      ctx.writeln('Add .md game files to play');
    } else {
      for (final game in games) {
        final name = game.path.split('/').last;
        final info = gameConfig.getGameInfo(name);
        final title = info?['title'] ?? name.replaceAll('.md', '');
        ctx.writeln('  \x1B[36m${name.padRight(25)}\x1B[0m $title');
      }
    }

    ctx.writeln();
    ctx.writeln('Use "play <game-name>" to start a game');
    ctx.writeln();
  }

  static Future<void> _info(CommandContext ctx) async {
    final gameConfig = ctx.gameConfig as GameConfig?;
    if (gameConfig == null || !gameConfig.isInitialized) {
      ctx.error('Games not initialized');
      return;
    }

    if (ctx.args.isEmpty) {
      ctx.error('Usage: games info <game-name>');
      return;
    }

    final name = ctx.args[0];
    final info = gameConfig.getGameInfo(name);

    if (info == null) {
      ctx.error('Game not found: $name');
      return;
    }

    ctx.writeln();
    ctx.bold('Game: ${info['title']}');
    ctx.writeln('-' * 40);
    ctx.writeln('File:      ${info['name']}');
    ctx.writeln('Scenes:    ${info['scenes']}');
    ctx.writeln('Items:     ${info['items']}');
    ctx.writeln('Opponents: ${info['opponents']}');
    ctx.writeln('Actions:   ${info['actions']}');
    ctx.writeln();
    ctx.writeln('To play: play ${info['name']}');
    ctx.writeln();
  }

  static List<String> _gameCompleter(CommandContext ctx) {
    final gameConfig = ctx.gameConfig as GameConfig?;
    if (gameConfig == null || !gameConfig.isInitialized) return [];
    return gameConfig
        .listGames()
        .map((e) => e.path.split('/').last)
        .toList();
  }
}

/// play — launch a text-adventure game
class PlayCommand extends Command {
  @override
  String get name => 'play';
  @override
  String get description => 'Play a text-adventure game';
  @override
  String get usage => 'play <game-name.md>';
  @override
  CommandCategory get category => CommandCategory.games;

  @override
  Future<void> execute(CommandContext ctx) async {
    final gameConfig = ctx.gameConfig as GameConfig?;
    if (gameConfig == null || !gameConfig.isInitialized) {
      ctx.error('Games not initialized');
      return;
    }

    if (ctx.args.isEmpty) {
      ctx.error('Usage: play <game-name.md>');
      ctx.writeln('Use "ls /games" or "games list" to see available games');
      return;
    }

    final gameName = ctx.args[0];
    final gamePath = gameConfig.getGamePath(gameName);

    if (gamePath == null) {
      ctx.error('Game not found: $gameName');
      ctx.writeln('Use "ls /games" or "games list" to see available games');
      return;
    }

    try {
      final content = await File(gamePath).readAsString();
      final parser = GameParser();
      final game = parser.parse(content);

      final screen = GameScreen();
      final engine = GameEngine(game: game, screen: screen);

      ctx.writeln();
      ctx.writeln('\x1B[1;36mStarting game: ${game.title}\x1B[0m');
      ctx.dim('Press Ctrl+C or type "quit" to exit the game');
      ctx.writeln();

      await engine.run();

      ctx.writeln();
      ctx.writeln('\x1B[1;33mGame ended. Returning to CLI.\x1B[0m');
      ctx.writeln();
    } catch (e) {
      ctx.error('Failed to start game: $e');
    }
  }

  @override
  List<String> complete(CommandContext ctx) {
    final gameConfig = ctx.gameConfig as GameConfig?;
    if (gameConfig == null || !gameConfig.isInitialized) return [];
    return gameConfig
        .listGames()
        .map((e) => e.path.split('/').last)
        .toList();
  }
}
