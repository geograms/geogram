/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Storage service for the Telegram bridge.
 * Manages config.json, status.json, and parent teleport config updates.
 */

import 'dart:convert';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';

/// Manages on-disk state for the Telegram bridge.
///
/// Storage layout under {callsign}/teleport/telegram/:
///   config.json   — api_id, api_hash, settings
///   status.json   — connection state, last_sync, error
class TelegramStorageService {
  final ProfileStorage _storage;
  final String prefix;

  TelegramStorageService(this._storage, this.prefix);

  /// Create from a ScopedProfileStorage already rooted at the teleport dir.
  factory TelegramStorageService.fromScoped(ScopedProfileStorage scoped) {
    return TelegramStorageService(scoped, '');
  }

  String _path(String relativePath) {
    if (prefix.isEmpty) return relativePath;
    return '$prefix/$relativePath';
  }

  // --- Bridge config ---

  Future<Map<String, dynamic>?> readConfig() async {
    final str = await _storage.readString(_path('telegram/config.json'));
    if (str == null) return null;
    try {
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      LogService().error('TelegramStorage: bad config.json: $e');
      return null;
    }
  }

  Future<void> writeConfig(Map<String, dynamic> config) async {
    await _storage.writeString(
      _path('telegram/config.json'),
      const JsonEncoder.withIndent('  ').convert(config),
    );
  }

  Future<bool> hasConfig() async {
    return _storage.exists(_path('telegram/config.json'));
  }

  // --- Status ---

  Future<Map<String, dynamic>?> readStatus() async {
    final str = await _storage.readString(_path('telegram/status.json'));
    if (str == null) return null;
    try {
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  Future<void> writeStatus(Map<String, dynamic> status) async {
    await _storage.writeString(
      _path('telegram/status.json'),
      const JsonEncoder.withIndent('  ').convert(status),
    );
  }

  // --- Parent teleport config ---

  /// Register or update the telegram entry in teleport/config.json bridges array.
  Future<void> registerBridge({required bool enabled}) async {
    final configStr = await _storage.readString(_path('config.json'));
    Map<String, dynamic> config;
    if (configStr != null) {
      config = jsonDecode(configStr) as Map<String, dynamic>;
    } else {
      config = {'bridges': []};
    }

    final bridges = (config['bridges'] as List<dynamic>?) ?? [];
    final idx = bridges.indexWhere(
        (b) => b is Map<String, dynamic> && b['platform'] == 'telegram');

    final entry = {
      'platform': 'telegram',
      'enabled': enabled,
      'updated': DateTime.now().toUtc().toIso8601String(),
    };

    if (idx >= 0) {
      bridges[idx] = entry;
    } else {
      bridges.add(entry);
    }

    config['bridges'] = bridges;
    await _storage.writeString(
      _path('config.json'),
      const JsonEncoder.withIndent('  ').convert(config),
    );
  }

  /// Remove the telegram entry from teleport/config.json bridges array.
  Future<void> unregisterBridge() async {
    final configStr = await _storage.readString(_path('config.json'));
    if (configStr == null) return;

    final config = jsonDecode(configStr) as Map<String, dynamic>;
    final bridges = (config['bridges'] as List<dynamic>?) ?? [];
    bridges.removeWhere(
        (b) => b is Map<String, dynamic> && b['platform'] == 'telegram');
    config['bridges'] = bridges;

    await _storage.writeString(
      _path('config.json'),
      const JsonEncoder.withIndent('  ').convert(config),
    );
  }

  /// Ensure the telegram directory structure exists.
  Future<void> ensureDirectories() async {
    await _storage.createDirectory(_path('telegram'));
    await _storage.createDirectory(_path('telegram/tdlib_db'));
    await _storage.createDirectory(_path('telegram/media'));
    await _storage.createDirectory(_path('telegram/cache'));
  }
}
