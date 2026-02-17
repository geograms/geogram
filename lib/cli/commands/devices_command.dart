/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Devices command: list, scan, ping
 */

import '../../station.dart';
import '../cli_profile_service.dart';
import 'command.dart';
import 'command_context.dart';

/// devices — manage and discover devices
class DevicesCommand extends Command {
  @override String get name => 'devices';
  @override String get description => 'Manage devices (list|scan|ping)';
  @override String get usage => 'devices <subcommand>';
  @override CommandCategory get category => CommandCategory.devices;
  @override bool get requiresStation => true;
  @override List<String> get contextPaths => const ['/devices'];

  @override
  List<SubCommand> get subcommands => [
    SubCommand(
      name: 'list',
      description: 'List all known and connected devices',
      execute: _list,
    ),
    SubCommand(
      name: 'scan',
      description: 'Scan network for Geogram devices',
      execute: _scan,
    ),
    SubCommand(
      name: 'ping',
      description: 'Ping a device at ip[:port]',
      execute: _ping,
    ),
  ];

  @override
  Future<void> execute(CommandContext ctx) async {
    // No sub-command — show device list
    await _list(ctx);
  }

  static Future<void> _list(CommandContext ctx) async {
    final station = ctx.station as StationServer;
    final profileService = ctx.profileService as CliProfileService?;

    ctx.writeln();

    if (profileService != null) {
      // Get all devices sorted (owned first, then cached)
      final allDevices = profileService.getAllDevicesSorted();

      // Section 1: My Devices (owned profiles)
      final ownedDevices =
          allDevices.where((d) => d['owned'] == true).toList();
      ctx.bold('My Devices (${ownedDevices.length})');
      ctx.writeln('-' * 60);

      if (ownedDevices.isEmpty) {
        ctx.writeln('  No profiles configured. Run "setup" to create one.');
      } else {
        for (final device in ownedDevices) {
          final isActive = device['active'] == true;
          final activeMarker = isActive ? '\x1B[32m*\x1B[0m' : ' ';
          final typeStr = device['type'] == 'station'
              ? '\x1B[33mstation\x1B[0m'
              : '\x1B[36mclient\x1B[0m';
          final callsign = device['callsign'] as String;
          final nickname = device['nickname'] as String;
          final displayName =
              nickname.isNotEmpty ? '$callsign ($nickname)' : callsign;
          ctx.writeln(
              '$activeMarker \x1B[1m$displayName\x1B[0m - $typeStr');
        }
      }
      ctx.writeln();

      // Section 2: Cached/Known Devices
      final cachedDevices =
          allDevices.where((d) => d['owned'] != true).toList();
      if (cachedDevices.isNotEmpty) {
        ctx.bold('Known Devices (${cachedDevices.length})');
        ctx.writeln('-' * 60);
        for (final device in cachedDevices) {
          final callsign = device['callsign'] as String;
          final typeStr = device['type'] ?? 'unknown';
          ctx.writeln('  $callsign - $typeStr');
        }
        ctx.writeln();
      }
    }

    // Section 3: Currently Connected (station clients)
    final clients = station.clients;
    ctx.bold('Connected Now (${clients.length})');
    ctx.writeln('-' * 60);

    if (clients.isEmpty) {
      ctx.writeln('  No devices connected to this station');
    } else {
      for (final client in clients.values) {
        final connectedAgo = DateTime.now().difference(client.connectedAt);
        final isOwned = profileService?.isOwnedCallsign(
                client.callsign ?? '') ??
            false;
        final ownedMarker = isOwned ? '\x1B[32m*\x1B[0m' : ' ';
        ctx.writeln(
          '$ownedMarker ${(client.callsign ?? 'Unknown').padRight(12)} '
          '${(client.deviceType ?? '-').padRight(10)} '
          '${_formatDuration(connectedAgo)} ago',
        );
      }
    }
    ctx.writeln();
  }

  static Future<void> _scan(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    int timeout = 2000;
    final args = ctx.args;
    for (int i = 0; i < args.length - 1; i++) {
      if (args[i] == '-t') {
        timeout = int.tryParse(args[i + 1]) ?? 2000;
      }
    }

    ctx.writeln(
        'Scanning network for Geogram devices (timeout: ${timeout}ms)...');
    final devices = await station.scanNetwork(timeout: timeout);

    ctx.writeln();
    ctx.bold('Discovered Devices (${devices.length})');
    ctx.writeln('-' * 60);

    if (devices.isEmpty) {
      ctx.writeln('No devices found');
    } else {
      for (final device in devices) {
        ctx.writeln(
          '${device['callsign'].toString().padRight(12)} '
          '${device['type'].toString().padRight(8)} '
          '${device['ip']}:${device['port']} '
          'v${device['version']}',
        );
      }
    }
    ctx.writeln();
  }

  static Future<void> _ping(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    if (ctx.args.isEmpty) {
      ctx.error('Usage: devices ping <ip[:port]>');
      return;
    }

    final address = ctx.args[0];
    ctx.writeln('Pinging $address...');
    final result = await station.pingDevice(address);

    if (result != null) {
      ctx.writeln();
      ctx.success('Device found:');
      ctx.writeln('  Callsign: ${result['callsign']}');
      ctx.writeln('  Type:     ${result['type']}');
      ctx.writeln('  Name:     ${result['name']}');
      ctx.writeln('  Version:  ${result['version']}');
      ctx.writeln('  Address:  ${result['ip']}:${result['port']}');
    } else {
      ctx.error('Device not responding at $address');
    }
  }
}

String _formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}
