/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * General commands: help, clear, quit/exit/shutdown, broadcast, kick,
 * quiet, verbose, restart, reload, setup.
 */

import 'dart:io';

import '../../version.dart';
import 'command.dart';
import 'command_context.dart';
import 'command_registry.dart';
import 'service_interfaces.dart';

/// help — show available commands
class HelpCommand extends Command {
  final CommandRegistry registry;

  HelpCommand(this.registry);

  @override String get name => 'help';
  @override List<String> get aliases => const ['?'];
  @override String get description => 'Show available commands';
  @override CommandCategory get category => CommandCategory.general;

  @override
  Future<void> execute(CommandContext ctx) async {
    final station = ctx.station as StationCommandInterface?;
    ctx.writeln(registry.generateHelp(stationAvailable: station != null));
  }
}

/// clear — clear the screen
class ClearCommand extends Command {
  @override String get name => 'clear';
  @override String get description => 'Clear the screen';
  @override CommandCategory get category => CommandCategory.general;

  @override
  Future<void> execute(CommandContext ctx) async {
    ctx.io.clear();
  }
}

/// quit / exit / shutdown — exit the console
class QuitCommand extends Command {
  @override String get name => 'quit';
  @override List<String> get aliases => const ['exit', 'shutdown'];
  @override String get description => 'Exit the console';
  @override CommandCategory get category => CommandCategory.general;

  @override
  Future<void> execute(CommandContext ctx) async {
    if (ctx.onShutdown != null) {
      await ctx.onShutdown!();
    }
    ctx.writeln('Goodbye!');
    exit(0);
  }
}

/// broadcast <message> — send message to all connected devices
class BroadcastCommand extends Command {
  @override String get name => 'broadcast';
  @override String get description => 'Send message to all connected devices';
  @override String get usage => 'broadcast <message>';
  @override CommandCategory get category => CommandCategory.general;
  @override bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    if (ctx.args.isEmpty) {
      ctx.error('Usage: broadcast <message>');
      return;
    }
    final station = ctx.station as StationCommandInterface;
    final message = ctx.args.join(' ');
    station.broadcast(message);
    ctx.success('Broadcast sent to ${station.connectedDevices} devices');
  }
}

/// kick <callsign> — disconnect a device
class KickCommand extends Command {
  @override String get name => 'kick';
  @override String get description => 'Disconnect a device from the station';
  @override String get usage => 'kick <callsign>';
  @override CommandCategory get category => CommandCategory.general;
  @override bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    if (ctx.args.isEmpty) {
      ctx.error('Usage: kick <callsign>');
      return;
    }
    final station = ctx.station as StationCommandInterface;
    final callsign = ctx.args[0];
    if (station.kickDevice(callsign)) {
      ctx.success('Device $callsign disconnected');
    } else {
      ctx.error('Device not found: $callsign');
    }
  }

  @override
  List<String> complete(CommandContext ctx) {
    final station = ctx.station as StationCommandInterface?;
    if (station == null) return [];
    return station.clientsReadable.values
        .map((c) => c.callsign ?? '')
        .where((cs) => cs.isNotEmpty)
        .toList();
  }
}

/// quiet — enable quiet mode
class QuietCommand extends Command {
  @override String get name => 'quiet';
  @override String get description => 'Enable quiet mode (suppress logs)';
  @override CommandCategory get category => CommandCategory.monitoring;
  @override bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    final station = ctx.station as StationCommandInterface;
    station.quietMode = true;
    ctx.writeln('Quiet mode enabled');
  }
}

/// verbose — enable verbose mode
class VerboseCommand extends Command {
  @override String get name => 'verbose';
  @override String get description => 'Enable verbose mode (show logs)';
  @override CommandCategory get category => CommandCategory.monitoring;
  @override bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    final station = ctx.station as StationCommandInterface;
    station.quietMode = false;
    ctx.writeln('Verbose mode enabled');
  }
}

/// restart — restart the station server
class RestartCommand extends Command {
  @override String get name => 'restart';
  @override String get description => 'Restart the station server';
  @override CommandCategory get category => CommandCategory.general;
  @override bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    if (ctx.onStationRestart != null) {
      await ctx.onStationRestart!();
    } else {
      final station = ctx.station as StationCommandInterface;
      await station.restart();
    }
  }
}

/// reload — reload configuration from file
class ReloadCommand extends Command {
  @override String get name => 'reload';
  @override String get description => 'Reload config from file';
  @override CommandCategory get category => CommandCategory.general;
  @override bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    if (ctx.onStationReload != null) {
      await ctx.onStationReload!();
    } else {
      final station = ctx.station as StationCommandInterface;
      await station.reloadSettings();
    }
    ctx.writeln('Settings reloaded');
  }
}

/// setup — run the setup wizard
///
/// This command is interactive and uses stdin directly.
/// It remains a thin dispatcher — the actual setup logic stays in PureConsole
/// since it requires interactive prompting (stdin.readLineSync).
class SetupCommand extends Command {
  /// Callback that runs the actual setup wizard
  final Future<void> Function()? onSetup;

  SetupCommand({this.onSetup});

  @override String get name => 'setup';
  @override String get description => 'Run the setup wizard';
  @override CommandCategory get category => CommandCategory.general;

  @override
  Future<void> execute(CommandContext ctx) async {
    if (onSetup != null) {
      await onSetup!();
    } else {
      ctx.error('Setup wizard not available in this mode');
    }
  }
}

/// status — show application status
class StatusCommand extends Command {
  @override String get name => 'status';
  @override String get description => 'Show application status';
  @override CommandCategory get category => CommandCategory.monitoring;

  @override
  Future<void> execute(CommandContext ctx) async {
    final station = ctx.station as StationCommandInterface?;

    if (station == null) {
      ctx.writeln('Station not available');
      return;
    }

    final stationStatus = station.getStatus();

    ctx.writeln();
    ctx.bold('Geogram Status');
    ctx.writeln('-' * 40);
    ctx.writeln('Version:        $appVersion');
    ctx.writeln('Callsign:       ${station.settings.callsign}');
    ctx.writeln('Mode:           Station (CLI)');
    if (station.dataDir != null) {
      ctx.writeln('Data Dir:       ${station.dataDir}');
    }
    ctx.writeln();
    ctx.bold('Relay Server:');
    ctx.writeln('-' * 40);
    if (stationStatus['running'] == true) {
      ctx.success('Status:         Running');
      ctx.writeln('HTTP Port:      ${stationStatus['httpPort']}');
      ctx.writeln('HTTPS Port:     ${stationStatus['httpsPort']}');
      ctx.writeln('Devices:        ${stationStatus['connected_devices']}');
      ctx.writeln('Uptime:         ${_formatUptime(stationStatus['uptime'] as int)}');
      ctx.writeln('Cache:          ${stationStatus['cache_size']} tiles (${stationStatus['cache_size_mb']} MB)');
      ctx.writeln('Chat Rooms:     ${stationStatus['chat_rooms']}');
      ctx.writeln('Messages:       ${stationStatus['total_messages']}');
    } else {
      ctx.writeln('Status:         \x1B[33mStopped\x1B[0m');
      ctx.writeln('HTTP Port:      ${station.settings.httpPort}');
      ctx.writeln('HTTPS Port:     ${station.settings.httpsPort}');
    }
    ctx.writeln();
  }
}

/// stats — show detailed statistics
class StatsCommand extends Command {
  @override String get name => 'stats';
  @override String get description => 'Show detailed statistics';
  @override CommandCategory get category => CommandCategory.monitoring;
  @override bool get requiresStation => true;

  @override
  Future<void> execute(CommandContext ctx) async {
    final station = ctx.station as StationCommandInterface;
    final stats = station.stats;

    ctx.writeln();
    ctx.bold('Server Statistics');
    ctx.writeln('-' * 40);
    ctx.writeln('Total Connections:     ${stats.totalConnections}');
    ctx.writeln('Total Messages:        ${stats.totalMessages}');
    ctx.writeln('Total API Requests:    ${stats.totalApiRequests}');
    ctx.writeln('Total Tile Requests:   ${stats.totalTileRequests}');
    ctx.writeln();
    ctx.bold('Tile Cache:');
    ctx.writeln('-' * 40);
    ctx.writeln('Tiles Cached:          ${stats.tilesCached}');
    ctx.writeln('Served from Cache:     ${stats.tilesServedFromCache}');
    ctx.writeln('Downloaded:            ${stats.tilesDownloaded}');
    ctx.writeln();
    ctx.bold('Last Activity:');
    ctx.writeln('-' * 40);
    ctx.writeln('Last Connection:       ${stats.lastConnection?.toLocal() ?? 'Never'}');
    ctx.writeln('Last Message:          ${stats.lastMessage?.toLocal() ?? 'Never'}');
    ctx.writeln('Last Tile Request:     ${stats.lastTileRequest?.toLocal() ?? 'Never'}');
    ctx.writeln();
  }
}

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
