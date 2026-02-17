/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Config command: set, show, location
 */

import '../../models/profile.dart';
import '../cli_location_service.dart';
import 'command.dart';
import 'command_context.dart';
import 'service_interfaces.dart';

/// Config key types for validation.
/// Types: 'string', 'bool', 'int', 'double'
const Map<String, String> configKeyTypes = {
  'nickname': 'string',
  'description': 'string',
  'preferredColor': 'string',
  'latitude': 'double',
  'longitude': 'double',
  'locationName': 'string',
  'enableAprs': 'bool',
  // Station-only settings
  'httpPort': 'int',
  'httpsPort': 'int',
  'tileServerEnabled': 'bool',
  'osmFallbackEnabled': 'bool',
  'maxZoomLevel': 'int',
  'maxCacheSizeMB': 'int',
  'enableCors': 'bool',
  'maxConnectedDevices': 'int',
};

/// Config keys that are station-only
const List<String> _stationOnlyConfigKeys = [
  'httpPort',
  'httpsPort',
  'tileServerEnabled',
  'osmFallbackEnabled',
  'maxZoomLevel',
  'maxCacheSizeMB',
  'enableCors',
  'maxConnectedDevices',
];

/// Get config keys based on profile type
List<String> _getConfigKeys(ProfileCommandInterface? profileService) {
  final profile = profileService?.activeProfileReadable;
  if (profile?.isRelay == true) {
    return configKeyTypes.keys.toList();
  }
  return configKeyTypes.keys
      .where((k) => !_stationOnlyConfigKeys.contains(k))
      .toList();
}

/// config — view and modify station/profile configuration
class ConfigCommand extends Command {
  @override
  String get name => 'config';

  @override
  String get description => 'View/modify configuration (set|show|location)';

  @override
  String get usage => 'config <subcommand>';

  @override
  CommandCategory get category => CommandCategory.config;

  @override
  List<String> get contextPaths => const ['/config'];

  @override
  List<SubCommand> get subcommands => [
        SubCommand(
          name: 'set',
          description: 'Set a config value: set <key> <value>',
          execute: _set,
          completer: (ctx) {
            final profileService = ctx.profileService as ProfileCommandInterface?;
            return _getConfigKeys(profileService);
          },
        ),
        SubCommand(
          name: 'show',
          description: 'Show all config keys and values',
          execute: _show,
        ),
        SubCommand(
          name: 'location',
          description: 'Auto-detect location via IP address',
          execute: _location,
        ),
      ];

  @override
  Future<void> execute(CommandContext ctx) async {
    // No sub-command — show config list
    await _show(ctx);
  }

  /// Get the current value of a config key from the profile/station
  static dynamic _getConfigValue(
      String key, ProfileCommandInterface? profileService, StationCommandInterface? station) {
    final profile = profileService?.activeProfileReadable;
    if (profile == null) return null;

    switch (key) {
      case 'nickname':
        return profile.nickname;
      case 'description':
        return profile.description;
      case 'preferredColor':
        return profile.preferredColor;
      case 'latitude':
        return profile.latitude;
      case 'longitude':
        return profile.longitude;
      case 'locationName':
        return profile.locationName;
      case 'enableAprs':
        return profile.enableAprs;
      // Station settings
      case 'httpPort':
        return station?.settings.httpPort;
      case 'httpsPort':
        return station?.settings.httpsPort;
      case 'tileServerEnabled':
        return profile.tileServerEnabled;
      case 'osmFallbackEnabled':
        return profile.osmFallbackEnabled;
      case 'maxZoomLevel':
        return station?.settings.maxZoomLevel;
      case 'maxCacheSizeMB':
        return station?.settings.maxCacheSizeMB;
      case 'enableCors':
        return station?.settings.enableCors;
      case 'maxConnectedDevices':
        return station?.settings.maxConnectedDevices;
      default:
        return null;
    }
  }

  /// Validate a value against the expected type
  static String? _validateConfigValue(String key, String value) {
    final type = configKeyTypes[key];
    if (type == null) {
      return 'Unknown config key: $key';
    }

    switch (type) {
      case 'bool':
        if (value.toLowerCase() != 'true' &&
            value.toLowerCase() != 'false') {
          return '$key must be true or false';
        }
        break;
      case 'int':
        if (int.tryParse(value) == null) {
          return '$key must be an integer';
        }
        break;
      case 'double':
        if (double.tryParse(value) == null) {
          return '$key must be a number';
        }
        break;
      case 'string':
        // Any string is valid
        break;
    }
    return null;
  }

  static Future<void> _show(CommandContext ctx) async {
    final profileService = ctx.profileService as ProfileCommandInterface?;
    final station = ctx.station as StationCommandInterface?;
    final keys = _getConfigKeys(profileService);

    if (keys.isEmpty) {
      ctx.writeln('No config keys available.');
      return;
    }

    final maxKeyLen =
        keys.map((k) => k.length).reduce((a, b) => a > b ? a : b);

    for (final key in keys) {
      final value = _getConfigValue(key, profileService, station);
      final type = configKeyTypes[key] ?? 'string';
      final valueStr = value?.toString() ?? '\x1B[90m(not set)\x1B[0m';
      final typeStr = '\x1B[90m[$type]\x1B[0m';

      ctx.writeln('${key.padRight(maxKeyLen)}  $valueStr  $typeStr');
    }
  }

  static Future<void> _set(CommandContext ctx) async {
    final profileService = ctx.profileService as ProfileCommandInterface?;
    final station = ctx.station as StationCommandInterface?;

    if (ctx.args.length < 2) {
      ctx.error('Usage: set <key> <value>');
      return;
    }

    final key = ctx.args[0];
    final value = ctx.args.sublist(1).join(' ');
    final keys = _getConfigKeys(profileService);

    // Check if key is valid for this profile type
    if (!keys.contains(key)) {
      ctx.error('Unknown config key: $key');
      ctx.error('Available keys: ${keys.join(', ')}');
      return;
    }

    // Validate value
    final validationError = _validateConfigValue(key, value);
    if (validationError != null) {
      ctx.error(validationError);
      return;
    }

    try {
      // Parse value based on type
      final type = configKeyTypes[key]!;
      dynamic parsedValue;
      switch (type) {
        case 'bool':
          parsedValue = value.toLowerCase() == 'true';
          break;
        case 'int':
          parsedValue = int.parse(value);
          break;
        case 'double':
          parsedValue = double.parse(value);
          break;
        default:
          parsedValue = value;
      }

      // Update the profile (cast to Profile for copyWith — both platforms use Profile model)
      final profile = profileService?.activeProfileReadable as Profile?;
      if (profile != null) {
        Profile updatedProfile;
        switch (key) {
          case 'nickname':
            updatedProfile = profile.copyWith(nickname: parsedValue);
            break;
          case 'description':
            updatedProfile = profile.copyWith(description: parsedValue);
            break;
          case 'preferredColor':
            updatedProfile = profile.copyWith(preferredColor: parsedValue);
            break;
          case 'latitude':
            updatedProfile = profile.copyWith(latitude: parsedValue);
            break;
          case 'longitude':
            updatedProfile = profile.copyWith(longitude: parsedValue);
            break;
          case 'locationName':
            updatedProfile = profile.copyWith(locationName: parsedValue);
            break;
          case 'enableAprs':
            updatedProfile = profile.copyWith(enableAprs: parsedValue);
            break;
          case 'port':
            updatedProfile = profile.copyWith(port: parsedValue);
            station?.setSetting(key, parsedValue);
            break;
          case 'tileServerEnabled':
            updatedProfile =
                profile.copyWith(tileServerEnabled: parsedValue);
            break;
          case 'osmFallbackEnabled':
            updatedProfile =
                profile.copyWith(osmFallbackEnabled: parsedValue);
            break;
          default:
            // Station-only settings stored in station settings
            station?.setSetting(key, parsedValue);
            ctx.success('$key set to $value');
            return;
        }

        await profileService!.updateProfile(updatedProfile);
        ctx.success('$key set to $value');
      } else {
        ctx.error('No active profile');
      }
    } catch (e) {
      ctx.error('Failed to set $key: $e');
    }
  }

  static Future<void> _location(CommandContext ctx) async {
    final profileService = ctx.profileService as ProfileCommandInterface?;
    final station = ctx.station as StationCommandInterface?;

    ctx.writeln('Detecting location via IP address...');

    final locationService = CliLocationService();
    final result = await locationService.detectLocationViaIP();

    if (result == null) {
      ctx.error(
          'Failed to detect location. Please check your internet connection.');
      return;
    }

    // Update profile with detected location
    final profile = profileService?.activeProfileReadable as Profile?;
    if (profile == null) {
      ctx.error('No active profile');
      return;
    }

    final updatedProfile = profile.copyWith(
      latitude: result.latitude,
      longitude: result.longitude,
      locationName: result.locationName,
    );

    await profileService!.updateProfile(updatedProfile);

    // Also update station settings so /status endpoint returns coordinates
    if (station != null) {
      station.setSetting('latitude', result.latitude);
      station.setSetting('longitude', result.longitude);
      station.setSetting('location', result.locationName);
    }

    ctx.success('Location detected successfully:');
    ctx.writeln('  Location:  ${result.locationName}');
    ctx.writeln('  Latitude:  ${result.latitude}');
    ctx.writeln('  Longitude: ${result.longitude}');
  }
}
