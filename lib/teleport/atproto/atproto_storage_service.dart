/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import 'models/atproto_bridge_config.dart';
import 'models/atproto_feed_item.dart';
import 'models/atproto_session.dart';

/// Storage manager for the Teleport AT Proto bridge.
///
/// All data lives under {callsign}/teleport/atproto via ProfileStorage.
class AtprotoStorageService {
  final ProfileStorage _storage;

  AtprotoStorageService(this._storage);

  static const String root = 'teleport/atproto';
  static const String cacheDir = '$root/cache';
  static const String queueDir = '$root/queue';
  static const String repoDir = '$root/repo';
  static const String _legacyRoot = 'atproto';

  String _path(String relativePath) => '$root/$relativePath';

  Future<void> ensureDirectories() async {
    await _storage.createDirectory(root);
    await _storage.createDirectory(cacheDir);
    await _storage.createDirectory(queueDir);
    await _storage.createDirectory(repoDir);
  }

  Future<AtprotoBridgeConfig> loadConfig() async {
    try {
      final str = await _readStringWithLegacyFallback('config.json');
      if (str == null) return AtprotoBridgeConfig.defaults();
      final json = jsonDecode(str) as Map<String, dynamic>;
      return AtprotoBridgeConfig.fromJson(json);
    } catch (e) {
      LogService().log('AtprotoStorageService: loadConfig failed: $e');
      return AtprotoBridgeConfig.defaults();
    }
  }

  Future<void> saveConfig(AtprotoBridgeConfig config) async {
    await ensureDirectories();
    await _storage.writeString(
      _path('config.json'),
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
    );
  }

  Future<AtprotoSession?> loadSession() async {
    try {
      final str = await _readStringWithLegacyFallback('session.json');
      if (str == null) return null;
      return AtprotoSession.fromJson(jsonDecode(str) as Map<String, dynamic>);
    } catch (e) {
      LogService().log('AtprotoStorageService: loadSession failed: $e');
      return null;
    }
  }

  Future<void> saveSession(AtprotoSession session) async {
    await ensureDirectories();
    await _storage.writeString(
      _path('session.json'),
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
    );
  }

  Future<void> clearSession() async {
    await _storage.delete(_path('session.json'));
  }

  Future<List<AtprotoFeedItem>> loadCachedFeed() async {
    try {
      final str = await _readStringWithLegacyFallback('cache/feed.json');
      if (str == null) return const [];
      final list = jsonDecode(str) as List<dynamic>;
      return list
          .whereType<Map>()
          .map((e) => AtprotoFeedItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      LogService().log('AtprotoStorageService: loadCachedFeed failed: $e');
      return const [];
    }
  }

  Future<void> saveCachedFeed(List<AtprotoFeedItem> feed) async {
    await ensureDirectories();
    await _storage.writeString(
      _path('cache/feed.json'),
      const JsonEncoder.withIndent(
        '  ',
      ).convert(feed.map((e) => e.toJson()).toList()),
    );
  }

  Future<Map<String, dynamic>?> loadStatus() {
    return _readJsonWithLegacyFallback('status.json');
  }

  Future<void> saveStatus(Map<String, dynamic> status) async {
    await ensureDirectories();
    await _storage.writeJson(_path('status.json'), status);
  }

  Future<void> registerBridge({required bool enabled}) async {
    await ensureDirectories();
    final cfgStr = await _storage.readString('config.json');
    Map<String, dynamic> config;
    if (cfgStr != null) {
      config = jsonDecode(cfgStr) as Map<String, dynamic>;
    } else {
      config = {'version': '1.0', 'bridges': <dynamic>[]};
    }

    final bridges = (config['bridges'] as List<dynamic>? ?? <dynamic>[])
        .toList();
    final idx = bridges.indexWhere(
      (b) => b is Map<String, dynamic> && b['platform'] == 'bluesky',
    );

    final entry = {
      'platform': 'bluesky',
      'enabled': enabled,
      'updated': DateTime.now().toUtc().toIso8601String(),
    };

    if (idx >= 0) {
      bridges[idx] = entry;
    } else {
      bridges.add(entry);
    }

    config['bridges'] = bridges;
    config['updated_at'] = DateTime.now().toUtc().toIso8601String();

    await _storage.writeJson('config.json', config);
  }

  Future<String?> _readStringWithLegacyFallback(String relativePath) async {
    final current = await _storage.readString(_path(relativePath));
    if (current != null) return current;
    final legacy = await _storage.readString('$_legacyRoot/$relativePath');
    if (legacy != null) {
      await ensureDirectories();
      await _storage.writeString(_path(relativePath), legacy);
    }
    return legacy;
  }

  Future<Map<String, dynamic>?> _readJsonWithLegacyFallback(
    String relativePath,
  ) async {
    final current = await _storage.readJson(_path(relativePath));
    if (current != null) return current;
    final legacy = await _storage.readJson('$_legacyRoot/$relativePath');
    if (legacy != null) {
      await ensureDirectories();
      await _storage.writeJson(_path(relativePath), legacy);
    }
    return legacy;
  }
}
