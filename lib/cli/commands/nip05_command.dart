/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NIP-05 command: list, info, remove
 */

import 'command.dart';
import 'command_context.dart';
import '../../services/nip05_registry_service.dart';

/// nip05 — manage NIP-05 nickname registrations
class Nip05Command extends Command {
  @override String get name => 'nip05';
  @override String get description => 'Manage NIP-05 registrations (list|info|remove)';
  @override String get usage => 'nip05 <subcommand>';
  @override CommandCategory get category => CommandCategory.station;
  @override bool get requiresStation => true;

  @override
  List<SubCommand> get subcommands => [
    SubCommand(
      name: 'list',
      description: 'List all NIP-05 registrations',
      execute: _list,
    ),
    SubCommand(
      name: 'info',
      description: 'Show details for a specific registration',
      execute: _info,
    ),
    SubCommand(
      name: 'remove',
      description: 'Remove a registration by nickname',
      execute: _remove,
    ),
  ];

  @override
  Future<void> execute(CommandContext ctx) async {
    // No sub-command — show registration list
    await _list(ctx);
  }

  static Future<void> _list(CommandContext ctx) async {
    final registry = Nip05RegistryService();
    final registrations = registry.getAllValidRegistrations();

    ctx.writeln();
    ctx.bold('NIP-05 Registrations (${registrations.length})');
    ctx.writeln('-' * 70);

    if (registrations.isEmpty) {
      ctx.writeln('  No registrations found.');
      ctx.writeln();
      return;
    }

    // Header
    ctx.writeln(
      '  ${'Nickname'.padRight(16)} '
      '${'npub'.padRight(20)} '
      '${'Registered'.padRight(12)} '
      'Expires',
    );
    ctx.writeln('  ${'-' * 16} ${'-' * 20} ${'-' * 12} ${'-' * 12}');

    // Get full registration objects for dates
    for (final nickname in registrations.keys) {
      final reg = registry.getRegistration(nickname);
      if (reg == null) continue;

      final npubTrunc = reg.npub.length > 18
          ? '${reg.npub.substring(0, 8)}...${reg.npub.substring(reg.npub.length - 7)}'
          : reg.npub;
      final regDate = _formatDate(reg.registeredAt);
      final expDate = _formatDate(reg.expiresAt);

      ctx.writeln(
        '  ${nickname.padRight(16)} '
        '${npubTrunc.padRight(20)} '
        '${regDate.padRight(12)} '
        '$expDate',
      );
    }
    ctx.writeln();
  }

  static Future<void> _info(CommandContext ctx) async {
    if (ctx.args.isEmpty) {
      ctx.error('Usage: nip05 info <nickname>');
      return;
    }

    final nickname = ctx.args[0].toLowerCase();
    final registry = Nip05RegistryService();
    final reg = registry.getRegistration(nickname);

    if (reg == null) {
      ctx.error('No active registration found for "$nickname"');
      return;
    }

    ctx.writeln();
    ctx.bold('NIP-05 Registration: $nickname');
    ctx.writeln('-' * 50);
    ctx.writeln('  Nickname:    ${reg.nickname}');
    ctx.writeln('  npub:        ${reg.npub}');
    ctx.writeln('  Registered:  ${reg.registeredAt.toIso8601String()}');
    ctx.writeln('  Expires:     ${reg.expiresAt.toIso8601String()}');

    final daysLeft = reg.expiresAt.difference(DateTime.now()).inDays;
    if (daysLeft > 30) {
      ctx.writeln('  Status:      \x1B[32mActive ($daysLeft days remaining)\x1B[0m');
    } else if (daysLeft > 0) {
      ctx.writeln('  Status:      \x1B[33mExpiring soon ($daysLeft days remaining)\x1B[0m');
    } else {
      ctx.writeln('  Status:      \x1B[31mExpired\x1B[0m');
    }
    ctx.writeln();
  }

  static Future<void> _remove(CommandContext ctx) async {
    if (ctx.args.isEmpty) {
      ctx.error('Usage: nip05 remove <nickname>');
      return;
    }

    final nickname = ctx.args[0].toLowerCase();
    final registry = Nip05RegistryService();
    final removed = registry.removeRegistration(nickname);

    if (removed) {
      ctx.success('Registration "$nickname" removed.');
    } else {
      ctx.error('No registration found for "$nickname"');
    }
  }

  static String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
