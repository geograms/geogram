/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Monitoring commands: logs, tail, head, cat, df, top
 */

import 'dart:io';

import 'package:dart_console/dart_console.dart';

import '../../station.dart';
import 'command.dart';
import 'command_context.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Format byte count into human-readable string.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Format uptime in minutes to a short string.
String _formatUptime(int minutes) {
  if (minutes < 60) return '${minutes}m';
  if (minutes < 1440) {
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    return '${hours}h ${mins}m';
  }
  final days = minutes ~/ 1440;
  final hours = (minutes % 1440) ~/ 60;
  return '${days}d ${hours}h';
}

/// Resolve a virtual or real file path and apply head/tail/cat viewing mode.
///
/// Shared by [TailCommand], [HeadCommand], and [CatCommand].
Future<void> _viewFile(
  CommandContext ctx,
  String target, {
  int lines = 10,
  required String mode,
}) async {
  final station = ctx.station as StationServer;
  List<String> content = [];

  // Handle virtual files
  switch (target.toLowerCase()) {
    case 'logs':
    case '/logs':
      final logs = station.logs;
      content = logs.map((log) {
        final time = log.timestamp.toLocal();
        final timeStr =
            '${time.hour.toString().padLeft(2, '0')}:'
            '${time.minute.toString().padLeft(2, '0')}:'
            '${time.second.toString().padLeft(2, '0')}';
        return '$timeStr [${log.level}] ${log.message}';
      }).toList();
      break;

    case 'config':
    case '/config':
    case 'station_config.json':
      final settings = station.settings;
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
          ctx.error('Cannot read file: $e');
          return;
        }
      } else {
        ctx.error('File not found: $target');
        ctx.error('Available virtual files: logs, config');
        return;
      }
  }

  if (content.isEmpty) {
    ctx.writeln('(empty)');
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
      ctx.writeln('\x1B[33m$lineNum\x1B[0m  ${output[i]}');
    }
  } else {
    for (final line in output) {
      ctx.writeln(line);
    }
  }
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// logs — show recent station log entries
class LogsCommand extends Command {
  @override
  String get name => 'logs';
  @override
  String get description => 'Show recent log entries';
  @override
  String get usage => 'logs [n]';
  @override
  CommandCategory get category => CommandCategory.monitoring;
  @override
  bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    final station = ctx.station as StationServer;
    final limit = ctx.args.isNotEmpty ? int.tryParse(ctx.args[0]) ?? 20 : 20;
    final logs = station.getLogs(limit: limit);

    ctx.writeln();
    ctx.bold('Recent Logs (${logs.length})');
    ctx.writeln('-' * 60);

    if (logs.isEmpty) {
      ctx.writeln('No logs available');
    } else {
      for (final log in logs) {
        final levelColor = switch (log.level) {
          'ERROR' => '\x1B[31m',
          'WARN' => '\x1B[33m',
          'INFO' => '\x1B[32m',
          _ => '\x1B[0m',
        };
        final time = log.timestamp.toLocal();
        final timeStr =
            '${time.hour.toString().padLeft(2, '0')}:'
            '${time.minute.toString().padLeft(2, '0')}:'
            '${time.second.toString().padLeft(2, '0')}';
        ctx.writeln(
            '$timeStr $levelColor[${log.level}]\x1B[0m ${log.message}');
      }
    }
    ctx.writeln();
  }
}

/// tail — show last N lines of a file or virtual log
class TailCommand extends Command {
  @override
  String get name => 'tail';
  @override
  String get description => 'Show last N lines of a file';
  @override
  String get usage => 'tail [-n N] [file]';
  @override
  CommandCategory get category => CommandCategory.monitoring;
  @override
  bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    int lines = 10;
    String? target;

    // Parse arguments: tail [-n lines] [target]
    var i = 0;
    while (i < ctx.args.length) {
      if (ctx.args[i] == '-n' && i + 1 < ctx.args.length) {
        lines = int.tryParse(ctx.args[i + 1]) ?? 10;
        i += 2;
      } else {
        target = ctx.args[i];
        i++;
      }
    }

    await _viewFile(ctx, target ?? 'logs', lines: lines, mode: 'tail');
  }
}

/// head — show first N lines of a file or virtual log
class HeadCommand extends Command {
  @override
  String get name => 'head';
  @override
  String get description => 'Show first N lines of a file';
  @override
  String get usage => 'head [-n N] [file]';
  @override
  CommandCategory get category => CommandCategory.monitoring;
  @override
  bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    int lines = 10;
    String? target;

    // Parse arguments: head [-n lines] [target]
    var i = 0;
    while (i < ctx.args.length) {
      if (ctx.args[i] == '-n' && i + 1 < ctx.args.length) {
        lines = int.tryParse(ctx.args[i + 1]) ?? 10;
        i += 2;
      } else {
        target = ctx.args[i];
        i++;
      }
    }

    await _viewFile(ctx, target ?? 'logs', lines: lines, mode: 'head');
  }
}

/// cat — display an entire file with line numbers
class CatCommand extends Command {
  @override
  String get name => 'cat';
  @override
  String get description => 'Show entire file with line numbers';
  @override
  String get usage => 'cat <file>';
  @override
  CommandCategory get category => CommandCategory.monitoring;
  @override
  bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    if (ctx.args.isEmpty) {
      ctx.error('Usage: cat <file>');
      ctx.error('Available: logs, config, /path/to/file');
      return;
    }

    await _viewFile(ctx, ctx.args[0], mode: 'cat');
  }
}

/// df — show disk usage for station data
class DfCommand extends Command {
  @override
  String get name => 'df';
  @override
  String get description => 'Show disk usage for station data';
  @override
  String get usage => 'df [-h]';
  @override
  CommandCategory get category => CommandCategory.monitoring;
  @override
  bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    final station = ctx.station as StationServer;
    final humanReadable = ctx.args.contains('-h');
    final dataDir = station.dataDir;

    if (dataDir == null) {
      ctx.error('Data directory not initialized');
      return;
    }

    ctx.writeln();
    ctx.bold('Disk Usage');
    ctx.writeln('-' * 50);

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
    final configSize =
        await configFile.exists() ? await configFile.length() : 0;

    final total = tilesSize + configSize;

    if (humanReadable) {
      ctx.writeln('Tiles:  ${_formatBytes(tilesSize)}');
      ctx.writeln('Config: ${_formatBytes(configSize)}');
      ctx.writeln('Total:  ${_formatBytes(total)}');
    } else {
      ctx.writeln('Tiles:  $tilesSize bytes');
      ctx.writeln('Config: $configSize bytes');
      ctx.writeln('Total:  $total bytes');
    }
    ctx.writeln();
  }
}

/// top — live monitoring dashboard (press q to exit)
class TopCommand extends Command {
  @override
  String get name => 'top';
  @override
  String get description => 'Live monitoring dashboard (q to exit)';
  @override
  String get usage => 'top';
  @override
  CommandCategory get category => CommandCategory.monitoring;
  @override
  bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    final station = ctx.station as StationServer;
    final console = Console();

    ctx.writeln('Live monitoring - press q to exit');
    ctx.writeln();

    console.rawMode = true;
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
        final status = station.getStatus();
        final stationStatus = status['running'] == true
            ? '\x1B[32mRunning\x1B[0m'
            : '\x1B[33mStopped\x1B[0m';
        stdout.writeln('\x1B[1mRelay:\x1B[0m $stationStatus  '
            '\x1B[1mPort:\x1B[0m ${status['port']}  '
            '\x1B[1mDevices:\x1B[0m ${status['connected_devices']}  '
            '\x1B[1mUptime:\x1B[0m ${_formatUptime(status['uptime'] as int)}');
        stdout.writeln();

        // Stats section
        final stats = station.stats;
        stdout.writeln('\x1B[1mStats:\x1B[0m  '
            'Connections: ${stats.totalConnections}  '
            'Messages: ${stats.totalMessages}  '
            'API: ${stats.totalApiRequests}  '
            'Tiles: ${stats.totalTileRequests}');
        stdout.writeln();

        // Recent logs
        stdout.writeln('\x1B[1mRecent Logs:\x1B[0m');
        stdout.writeln('-' * 60);
        final logs = station.getLogs(limit: 15);
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
            final timeStr =
                '${time.hour.toString().padLeft(2, '0')}:'
                '${time.minute.toString().padLeft(2, '0')}:'
                '${time.second.toString().padLeft(2, '0')}';
            stdout.writeln(
                '$timeStr $levelColor[${log.level}]\x1B[0m ${log.message}');
          }
        }

        // Check for q key (non-blocking)
        // Wait for up to 1 second, checking for input
        final stopwatch = Stopwatch()..start();
        while (stopwatch.elapsedMilliseconds < 1000) {
          if (stdin.hasTerminal) {
            try {
              final key = console.readKey();
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
      console.rawMode = false;
    }

    stdout.writeln();
    stdout.writeln('Exited live monitor');
  }
}
