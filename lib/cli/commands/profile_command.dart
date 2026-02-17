/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Profile command: list, show, add, switch, delete
 */

import '../../station.dart';
import '../cli_profile_service.dart';
import 'command.dart';
import 'command_context.dart';

/// profile — manage user profiles
class ProfileCommand extends Command {
  /// Callback that runs the setup wizard (reused for "profile add")
  final Future<void> Function()? onSetup;

  ProfileCommand({this.onSetup});

  @override String get name => 'profile';
  @override String get description => 'Manage profiles (list|show|add|switch|delete)';
  @override String get usage => 'profile <subcommand>';
  @override CommandCategory get category => CommandCategory.profile;

  @override
  List<SubCommand> get subcommands => [
    SubCommand(
      name: 'list',
      description: 'List all profiles',
      execute: _list,
    ),
    SubCommand(
      name: 'show',
      description: 'Show current profile details',
      execute: _show,
    ),
    SubCommand(
      name: 'add',
      description: 'Create a new profile (runs setup wizard)',
      execute: _add,
    ),
    SubCommand(
      name: 'switch',
      description: 'Switch to a different profile',
      execute: _switch,
      completer: _callsignCompleter,
    ),
    SubCommand(
      name: 'delete',
      description: 'Delete a profile',
      execute: _delete,
      completer: _callsignCompleter,
    ),
  ];

  @override
  Future<void> execute(CommandContext ctx) async {
    // No sub-command — show current profile
    await _show(ctx);
  }

  // --- Completers ---

  static List<String> _callsignCompleter(CommandContext ctx) {
    final profileService = ctx.profileService as CliProfileService?;
    if (profileService == null) return [];
    return profileService.profiles
        .map((p) => p.callsign)
        .toList();
  }

  // --- Sub-command implementations ---

  static Future<void> _show(CommandContext ctx) async {
    final profileService = ctx.profileService as CliProfileService?;
    if (profileService == null) {
      ctx.error('Profile service not available');
      return;
    }

    final profile = profileService.activeProfile;
    if (profile == null) {
      ctx.writeln('\x1B[33mNo profile configured. Run "setup" to create one.\x1B[0m');
      return;
    }

    final typeStr = profile.isRelay ? 'station' : 'client';
    ctx.writeln();
    ctx.bold('Active Profile:');
    ctx.writeln('  Type:        \x1B[36m$typeStr\x1B[0m');
    ctx.writeln('  Callsign:    \x1B[36m${profile.callsign}\x1B[0m');
    ctx.writeln('  Nickname:    \x1B[36m${profile.nickname.isEmpty ? '(not set)' : profile.nickname}\x1B[0m');
    ctx.writeln('  Description: \x1B[36m${profile.description.isEmpty ? '(not set)' : profile.description}\x1B[0m');
    if (profile.locationName != null) {
      ctx.writeln('  Location:    \x1B[36m${profile.locationName}\x1B[0m');
    }
    ctx.writeln('  npub:        \x1B[90m${profile.npub}\x1B[0m');
    ctx.writeln('  Created:     \x1B[90m${profile.createdAt.toIso8601String().substring(0, 10)}\x1B[0m');

    if (profile.isRelay) {
      ctx.writeln();
      ctx.bold('Relay Settings:');
      ctx.writeln('  Port:        \x1B[36m${profile.port ?? 8080}\x1B[0m');
      ctx.writeln('  Role:        \x1B[36m${profile.stationRole ?? 'not set'}\x1B[0m');
      if (profile.parentStationUrl != null) {
        ctx.writeln('  Parent URL:  \x1B[36m${profile.parentStationUrl}\x1B[0m');
      }
    }
    ctx.writeln();
  }

  Future<void> _add(CommandContext ctx) async {
    if (onSetup != null) {
      await onSetup!();
    } else {
      ctx.error('Setup wizard not available in this mode');
    }
  }

  static Future<void> _list(CommandContext ctx) async {
    final profileService = ctx.profileService as CliProfileService?;
    if (profileService == null) {
      ctx.error('Profile service not available');
      return;
    }

    final profiles = profileService.profiles;
    if (profiles.isEmpty) {
      ctx.writeln('\x1B[33mNo profiles configured. Run "setup" to create one.\x1B[0m');
      return;
    }

    ctx.writeln();
    ctx.bold('Profiles:');
    ctx.writeln();

    for (final profile in profiles) {
      final isActive = profile.id == profileService.activeProfile?.id;
      final typeStr = profile.isRelay ? 'station' : 'client';
      final activeStr = isActive ? '\x1B[32m*\x1B[0m ' : '  ';
      final displayName = profile.nickname.isNotEmpty
          ? '${profile.callsign} (${profile.nickname})'
          : profile.callsign;

      ctx.writeln('$activeStr\x1B[36m$displayName\x1B[0m - $typeStr');
    }
    ctx.writeln();
    ctx.writeln('Total: ${profiles.length} profile(s)');
    ctx.writeln('Use "profile switch <callsign>" to change active profile.');
    ctx.writeln();
  }

  static Future<void> _switch(CommandContext ctx) async {
    if (ctx.args.isEmpty) {
      ctx.error('Usage: profile switch <callsign>');
      return;
    }

    final profileService = ctx.profileService as CliProfileService?;
    if (profileService == null) {
      ctx.error('Profile service not available');
      return;
    }

    final callsign = ctx.args[0];
    final profile = profileService.getProfileByCallsign(callsign);
    if (profile == null) {
      ctx.error('Profile not found: $callsign');
      return;
    }

    await profileService.setActiveProfile(profile.id);

    // If switching to a station profile, update station server settings
    final station = ctx.station as StationServer?;
    if (profile.isRelay && station != null) {
      final newSettings = station.settings.copyWith(
        httpPort: profile.port,
        description: profile.description,
        location: profile.locationName,
        latitude: profile.latitude,
        longitude: profile.longitude,
        tileServerEnabled: profile.tileServerEnabled,
        osmFallbackEnabled: profile.osmFallbackEnabled,
        enableAprs: profile.enableAprs,
        stationRole: profile.stationRole,
        networkId: profile.networkId,
        parentStationUrl: profile.parentStationUrl,
        setupComplete: true,
      );
      await station.updateSettings(newSettings);
    }

    ctx.success('Switched to profile: ${profile.callsign}');
  }

  static Future<void> _delete(CommandContext ctx) async {
    if (ctx.args.isEmpty) {
      ctx.error('Usage: profile delete <callsign>');
      return;
    }

    final profileService = ctx.profileService as CliProfileService?;
    if (profileService == null) {
      ctx.error('Profile service not available');
      return;
    }

    final callsign = ctx.args[0];
    final profile = profileService.getProfileByCallsign(callsign);
    if (profile == null) {
      ctx.error('Profile not found: $callsign');
      return;
    }

    await profileService.deleteProfile(profile.id);
    ctx.success('Profile deleted: ${profile.callsign}');

    if (profileService.profiles.isEmpty) {
      ctx.writeln('\x1B[33mNo profiles remaining. Run "setup" to create a new one.\x1B[0m');
    }
  }
}
