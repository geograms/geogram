/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Station command: start, stop, status, restart, port, callsign, cache
 */

import '../../station.dart';
import '../cli_profile_service.dart';
import 'command.dart';
import 'command_context.dart';

/// station — manage the relay server
class StationCommand extends Command {
  @override String get name => 'station';
  @override String get description => 'Manage station (start|stop|status|restart|port|callsign|cache)';
  @override String get usage => 'station <subcommand>';
  @override CommandCategory get category => CommandCategory.station;
  @override bool get requiresStation => true;
  @override List<String> get contextPaths => const ['/station'];

  @override
  List<SubCommand> get subcommands => [
    SubCommand(
      name: 'start',
      description: 'Start the station server',
      execute: _start,
    ),
    SubCommand(
      name: 'stop',
      description: 'Stop the station server',
      execute: _stop,
    ),
    SubCommand(
      name: 'status',
      description: 'Show station status',
      execute: _status,
    ),
    SubCommand(
      name: 'restart',
      description: 'Restart the station',
      execute: _restart,
    ),
    SubCommand(
      name: 'port',
      description: 'Get/set port',
      execute: _port,
    ),
    SubCommand(
      name: 'callsign',
      description: 'Show station callsign',
      execute: _callsign,
    ),
    SubCommand(
      name: 'cache',
      description: 'Manage cache',
      execute: _cache,
      completer: (_) => ['clear', 'stats'],
    ),
  ];

  @override
  Future<void> execute(CommandContext ctx) async {
    // No sub-command — show status
    await _status(ctx);
  }

  static Future<void> _start(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    if (station.isRunning) {
      ctx.writeln('\x1B[33mRelay server is already running on port ${station.settings.httpPort}\x1B[0m');
      return;
    }

    ctx.writeln('Starting station server on port ${station.settings.httpPort}...');
    final success = await station.start();

    if (success) {
      ctx.success('Relay server started successfully');
      ctx.writeln('  HTTP Port:  ${station.settings.httpPort}');
      ctx.writeln('  HTTPS Port: ${station.settings.httpsPort}');
      ctx.writeln('  Callsign: ${station.settings.callsign}');
      ctx.writeln('  Status: http://localhost:${station.settings.httpPort}/api/status');
      ctx.writeln('  Tiles:  http://localhost:${station.settings.httpPort}/tiles/{callsign}/{z}/{x}/{y}.png');
    } else {
      ctx.error('Failed to start station server');
    }
  }

  static Future<void> _stop(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    if (!station.isRunning) {
      ctx.writeln('\x1B[33mRelay server is not running\x1B[0m');
      return;
    }

    ctx.writeln('Stopping station server...');
    await station.stop();
    ctx.success('Relay server stopped');
  }

  static Future<void> _status(CommandContext ctx) async {
    final station = ctx.station as StationServer;
    final status = station.getStatus();
    final settings = station.settings;

    ctx.writeln();
    ctx.bold('Relay Server Status');
    ctx.writeln('-' * 40);

    if (status['running'] == true) {
      ctx.success('Status:        Running');
      ctx.writeln('Port:          ${status['port']}');
      ctx.writeln('Callsign:      ${status['callsign']}');
      ctx.writeln('Devices:       ${status['connected_devices']}');
      ctx.writeln('Uptime:        ${_formatUptime(status['uptime'] as int)}');
      ctx.writeln('Cache:         ${status['cache_size']} tiles (${status['cache_size_mb']} MB)');
    } else {
      ctx.writeln('Status:        \x1B[33mStopped\x1B[0m');
    }

    ctx.writeln();
    ctx.bold('Settings:');
    ctx.writeln('-' * 40);
    ctx.writeln('HTTP Port:     ${settings.httpPort}');
    ctx.writeln('HTTPS Port:    ${settings.httpsPort}');
    ctx.writeln('Callsign:      ${settings.callsign}');
    ctx.writeln('Description:   ${settings.description ?? '(not set)'}');
    ctx.writeln('Location:      ${settings.location ?? '(not set)'}');
    ctx.writeln('Tile Server:   ${settings.tileServerEnabled ? 'Enabled' : 'Disabled'}');
    ctx.writeln('OSM Fallback:  ${settings.osmFallbackEnabled ? 'Enabled' : 'Disabled'}');
    ctx.writeln('Max Zoom:      ${settings.maxZoomLevel}');
    ctx.writeln('Max Cache:     ${settings.maxCacheSizeMB} MB');
    ctx.writeln('APRS:          ${settings.enableAprs ? 'Enabled' : 'Disabled'}');
    ctx.writeln('CORS:          ${settings.enableCors ? 'Enabled' : 'Disabled'}');
    ctx.writeln();
  }

  static Future<void> _restart(CommandContext ctx) async {
    final station = ctx.station as StationServer;
    await station.restart();
  }

  static Future<void> _port(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    if (ctx.args.isEmpty) {
      ctx.writeln('Current HTTP port: ${station.settings.httpPort}');
      ctx.writeln('Current HTTPS port: ${station.settings.httpsPort}');
      return;
    }

    final port = int.tryParse(ctx.args[0]);
    if (port == null || port < 1 || port > 65535) {
      ctx.error('Invalid port number: ${ctx.args[0]} (must be 1-65535)');
      return;
    }

    final settings = station.settings.copyWith(httpPort: port);
    await station.updateSettings(settings);
    ctx.success('Port set to $port');
  }

  static Future<void> _callsign(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    ctx.writeln('Station callsign: ${station.settings.callsign}');
    ctx.writeln('  (derived from npub: ${station.settings.npub.substring(0, 20)}...)');
    if (ctx.args.isNotEmpty) {
      ctx.error('Callsign cannot be set manually - it is derived from the station key pair');
    }
  }

  static Future<void> _cache(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    if (ctx.args.isEmpty) {
      final status = station.getStatus();
      ctx.writeln('Cache: ${status['cache_size']} tiles (${status['cache_size_mb']} MB)');
      return;
    }

    switch (ctx.args[0].toLowerCase()) {
      case 'clear':
        station.clearCache();
        ctx.success('Cache cleared');
        break;
      case 'stats':
        final stats = station.stats;
        ctx.writeln();
        ctx.bold('Cache Statistics');
        ctx.writeln('-' * 30);
        ctx.writeln('Tiles Cached:       ${stats.tilesCached}');
        ctx.writeln('Served from Cache:  ${stats.tilesServedFromCache}');
        ctx.writeln('Downloaded:         ${stats.tilesDownloaded}');
        ctx.writeln('Max Size:           ${station.settings.maxCacheSizeMB} MB');
        ctx.writeln();
        break;
      default:
        ctx.error('Unknown cache command. Available: clear, stats');
    }
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
