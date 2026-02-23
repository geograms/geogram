/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Storage service for the Signal bridge.
 * Manages config.json, status.json, and parent teleport config updates.
 * Mirrors TelegramStorageService 1:1.
 */

import 'dart:convert';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';

/// Manages on-disk state for the Signal bridge.
///
/// Storage layout under {callsign}/teleport/signal/:
///   config.json   — device_name, settings
///   status.json   — connection state, last_sync, error
///   signal_db/    — Signal protocol database
///   media/        — downloaded attachments
///   cache/        — per-conversation SQLite message caches
class SignalStorageService {
  final ProfileStorage _storage;
  final String prefix;

  SignalStorageService(this._storage, this.prefix);

  /// Create from a ScopedProfileStorage already rooted at the teleport dir.
  factory SignalStorageService.fromScoped(ScopedProfileStorage scoped) {
    return SignalStorageService(scoped, '');
  }

  String _path(String relativePath) {
    if (prefix.isEmpty) return relativePath;
    return '$prefix/$relativePath';
  }

  // --- Bridge config ---

  Future<Map<String, dynamic>?> readConfig() async {
    final str = await _storage.readString(_path('signal/config.json'));
    if (str == null) return null;
    try {
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      LogService().error('SignalStorage: bad config.json: $e');
      return null;
    }
  }

  Future<void> writeConfig(Map<String, dynamic> config) async {
    await _storage.writeString(
      _path('signal/config.json'),
      const JsonEncoder.withIndent('  ').convert(config),
    );
  }

  Future<bool> hasConfig() async {
    return _storage.exists(_path('signal/config.json'));
  }

  // --- Status ---

  Future<Map<String, dynamic>?> readStatus() async {
    final str = await _storage.readString(_path('signal/status.json'));
    if (str == null) return null;
    try {
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  Future<void> writeStatus(Map<String, dynamic> status) async {
    await _storage.writeString(
      _path('signal/status.json'),
      const JsonEncoder.withIndent('  ').convert(status),
    );
  }

  // --- Parent teleport config ---

  /// Register or update the signal entry in teleport/config.json bridges array.
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
        (b) => b is Map<String, dynamic> && b['platform'] == 'signal');

    final entry = {
      'platform': 'signal',
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

  /// Remove the signal entry from teleport/config.json bridges array.
  Future<void> unregisterBridge() async {
    final configStr = await _storage.readString(_path('config.json'));
    if (configStr == null) return;

    final config = jsonDecode(configStr) as Map<String, dynamic>;
    final bridges = (config['bridges'] as List<dynamic>?) ?? [];
    bridges.removeWhere(
        (b) => b is Map<String, dynamic> && b['platform'] == 'signal');
    config['bridges'] = bridges;

    await _storage.writeString(
      _path('config.json'),
      const JsonEncoder.withIndent('  ').convert(config),
    );
  }

  /// Ensure the signal directory structure exists.
  Future<void> ensureDirectories() async {
    await _storage.createDirectory(_path('signal'));
    await _storage.createDirectory(_path('signal/signal_db'));
    await _storage.createDirectory(_path('signal/media'));
    await _storage.createDirectory(_path('signal/cache'));
  }
}
