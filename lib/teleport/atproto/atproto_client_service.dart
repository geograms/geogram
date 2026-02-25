/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/monitored_task.dart';
import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../util/task_monitor_helpers.dart';
import 'atproto_storage_service.dart';
import 'models/atproto_bridge_config.dart';
import 'models/atproto_feed_item.dart';
import 'models/atproto_session.dart';

enum AtprotoClientEventType {
  connected,
  disconnected,
  feedUpdated,
  configChanged,
  error,
}

class AtprotoClientEvent {
  final AtprotoClientEventType type;
  final dynamic data;

  const AtprotoClientEvent(this.type, {this.data});
}

class AtprotoClientService {
  static final AtprotoClientService _instance =
      AtprotoClientService._internal();
  factory AtprotoClientService() => _instance;
  AtprotoClientService._internal();

  final StreamController<AtprotoClientEvent> _events =
      StreamController<AtprotoClientEvent>.broadcast();

  Stream<AtprotoClientEvent> get events => _events.stream;

  AtprotoStorageService? _storage;
  AtprotoBridgeConfig _config = AtprotoBridgeConfig.defaults();
  AtprotoSession? _session;
  List<AtprotoFeedItem> _feed = const [];

  MonitoredAsyncPeriodicTimer? _sessionRefreshTimer;
  MonitoredAsyncPeriodicTimer? _feedSyncTimer;
  MonitoredAsyncPeriodicTimer? _notifyRelaysTimer;
  MonitoredAsyncPeriodicTimer? _queueFlushTimer;
  MonitoredAsyncPeriodicTimer? _cachePruneTimer;
  MonitoredAsyncPeriodicTimer? _repoCheckpointTimer;

  AtprotoBridgeConfig get config => _config;
  AtprotoSession? get session => _session;
  List<AtprotoFeedItem> get feed => List.unmodifiable(_feed);
  bool get isAuthenticated => _session?.isValid == true;

  Future<void> autoStart(ProfileStorage storage) async {
    _storage = AtprotoStorageService(storage);
    await _storage!.ensureDirectories();
    _config = await _storage!.loadConfig();
    _session = await _storage!.loadSession();
    _feed = await _storage!.loadCachedFeed();

    _startRecurringTasks();
    if (_config.enabled && isAuthenticated) {
      await syncFeed();
    }
    _emit(const AtprotoClientEvent(AtprotoClientEventType.configChanged));
  }

  Future<void> saveConfig(AtprotoBridgeConfig newConfig) async {
    _config = newConfig;
    await _storage?.saveConfig(newConfig);
    await _storage?.registerBridge(enabled: newConfig.enabled);
    await _storage?.saveStatus({
      'platform': 'bluesky',
      'state': newConfig.enabled ? 'connected' : 'disconnected',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'did': _session?.did,
      'handle': _session?.handle,
    });
    _emit(const AtprotoClientEvent(AtprotoClientEventType.configChanged));
  }

  Future<bool> login({
    required String identifier,
    required String password,
  }) async {
    final pds = _normalizeBaseUrl(_config.pdsUrl);
    final uri = Uri.parse('$pds/xrpc/com.atproto.server.createSession');

    try {
      final response = await http.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'identifier': identifier, 'password': password}),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _emit(
          AtprotoClientEvent(
            AtprotoClientEventType.error,
            data: 'Login failed (${response.statusCode})',
          ),
        );
        return false;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final session = AtprotoSession.fromJson(json);
      if (!session.isValid) {
        _emit(
          const AtprotoClientEvent(
            AtprotoClientEventType.error,
            data: 'Invalid session payload',
          ),
        );
        return false;
      }

      _session = session;
      await _storage?.saveSession(session);
      await saveConfig(
        _config.copyWith(
          identifier: identifier,
          password: password,
          enabled: true,
        ),
      );
      _emit(const AtprotoClientEvent(AtprotoClientEventType.connected));
      await syncFeed();
      return true;
    } catch (e) {
      _emit(AtprotoClientEvent(AtprotoClientEventType.error, data: '$e'));
      return false;
    }
  }

  Future<void> logout() async {
    _session = null;
    await _storage?.clearSession();
    await saveConfig(_config.copyWith(enabled: false));
    _emit(const AtprotoClientEvent(AtprotoClientEventType.disconnected));
  }

  Future<bool> publishPost(String text, {AtprotoFeedItem? replyTo}) async {
    if (_session == null) return false;
    final did = _session!.did;

    final record = <String, dynamic>{
      '4type': 'app.bsky.feed.post',
      'text': text,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };

    if (replyTo != null) {
      final parentUri = replyTo.uri;
      final rootUri = replyTo.rootUri ?? replyTo.uri;
      record['reply'] = {
        'root': {'uri': rootUri, 'cid': replyTo.cid},
        'parent': {'uri': parentUri, 'cid': replyTo.cid},
      };
    }

    return _createRecord(
      repo: did,
      collection: 'app.bsky.feed.post',
      record: record,
    );
  }

  Future<bool> likePost(AtprotoFeedItem item) async {
    if (_session == null) return false;
    return _createRecord(
      repo: _session!.did,
      collection: 'app.bsky.feed.like',
      record: {
        '4type': 'app.bsky.feed.like',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'subject': {'uri': item.uri, 'cid': item.cid},
      },
    );
  }

  Future<bool> repost(AtprotoFeedItem item) async {
    if (_session == null) return false;
    return _createRecord(
      repo: _session!.did,
      collection: 'app.bsky.feed.repost',
      record: {
        '4type': 'app.bsky.feed.repost',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'subject': {'uri': item.uri, 'cid': item.cid},
      },
    );
  }

  Future<void> syncFeed() async {
    if (!isAuthenticated || !_config.enabled) return;
    final appView = _normalizeBaseUrl(_config.appViewUrl);

    final uri = Uri.parse(
      '$appView/xrpc/app.bsky.feed.getAuthorFeed?actor=${Uri.encodeQueryComponent(_session!.did)}&limit=50',
    );

    try {
      final response = await http.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _emit(
          AtprotoClientEvent(
            AtprotoClientEventType.error,
            data: 'Feed sync failed (${response.statusCode})',
          ),
        );
        return;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final rawFeed = body['feed'] as List<dynamic>? ?? const [];
      final parsed = <AtprotoFeedItem>[];
      for (final entry in rawFeed) {
        if (entry is! Map<String, dynamic>) continue;
        final postWrap = entry['post'];
        if (postWrap is! Map<String, dynamic>) continue;

        final author = postWrap['author'] as Map<String, dynamic>? ?? const {};
        final record = postWrap['record'] as Map<String, dynamic>? ?? const {};
        final reply = record['reply'] as Map<String, dynamic>?;
        final root = reply?['root'] as Map<String, dynamic>?;
        final parent = reply?['parent'] as Map<String, dynamic>?;

        parsed.add(
          AtprotoFeedItem(
            uri: postWrap['uri'] as String? ?? '',
            cid: postWrap['cid'] as String? ?? '',
            authorDid: author['did'] as String? ?? '',
            authorHandle: author['handle'] as String? ?? '',
            displayName:
                author['displayName'] as String? ??
                (author['handle'] as String? ?? ''),
            text: record['text'] as String? ?? '',
            createdAt:
                DateTime.tryParse(record['createdAt'] as String? ?? '') ??
                DateTime.now().toUtc(),
            replyCount: postWrap['replyCount'] as int? ?? 0,
            repostCount: postWrap['repostCount'] as int? ?? 0,
            likeCount: postWrap['likeCount'] as int? ?? 0,
            parentUri: parent?['uri'] as String?,
            rootUri: root?['uri'] as String?,
          ),
        );
      }

      _feed = parsed;
      await _storage?.saveCachedFeed(parsed);
      _emit(const AtprotoClientEvent(AtprotoClientEventType.feedUpdated));
    } catch (e) {
      _emit(AtprotoClientEvent(AtprotoClientEventType.error, data: '$e'));
    }
  }

  void dispose() {
    _sessionRefreshTimer?.cancel();
    _feedSyncTimer?.cancel();
    _notifyRelaysTimer?.cancel();
    _queueFlushTimer?.cancel();
    _cachePruneTimer?.cancel();
    _repoCheckpointTimer?.cancel();
  }

  Future<void> _refreshSession() async {
    if (_session == null || _session!.refreshJwt.isEmpty || !_config.enabled) {
      return;
    }
    final pds = _normalizeBaseUrl(_config.pdsUrl);
    final uri = Uri.parse('$pds/xrpc/com.atproto.server.refreshSession');

    try {
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${_session!.refreshJwt}',
          'Content-Type': 'application/json',
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final refreshed = AtprotoSession.fromJson(json);
      if (!refreshed.isValid) return;

      _session = refreshed;
      await _storage?.saveSession(refreshed);
    } catch (_) {}
  }

  Future<bool> _createRecord({
    required String repo,
    required String collection,
    required Map<String, dynamic> record,
  }) async {
    if (_session == null) return false;

    final pds = _normalizeBaseUrl(_config.pdsUrl);
    final uri = Uri.parse('$pds/xrpc/com.atproto.repo.createRecord');

    try {
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${_session!.accessJwt}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'repo': repo,
          'collection': collection,
          'record': record,
        }),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await syncFeed();
        return true;
      }

      if (response.statusCode == 401) {
        await _refreshSession();
      }

      _emit(
        AtprotoClientEvent(
          AtprotoClientEventType.error,
          data: 'Publish failed (${response.statusCode})',
        ),
      );
      return false;
    } catch (e) {
      _emit(AtprotoClientEvent(AtprotoClientEventType.error, data: '$e'));
      return false;
    }
  }

  void _startRecurringTasks() {
    _sessionRefreshTimer ??= MonitoredAsyncPeriodicTimer(
      id: 'atproto.client.session_refresh',
      name: 'AT Proto Session Refresh',
      description: 'Refreshes access token using refresh JWT',
      serviceName: 'AtprotoClientService',
      interval: const Duration(minutes: 5),
      callback: (_) => _refreshSession(),
      priority: TaskPriority.normal,
    );

    _feedSyncTimer ??= MonitoredAsyncPeriodicTimer(
      id: 'atproto.client.feed_sync',
      name: 'AT Proto Feed Sync',
      description: 'Fetches latest author feed from appview',
      serviceName: 'AtprotoClientService',
      interval: const Duration(seconds: 20),
      callback: (_) => syncFeed(),
      priority: TaskPriority.normal,
    );

    _notifyRelaysTimer ??= MonitoredAsyncPeriodicTimer(
      id: 'atproto.client.notify_relays',
      name: 'AT Proto Relay Notify',
      description: 'Processes relay notification retries',
      serviceName: 'AtprotoClientService',
      interval: const Duration(seconds: 60),
      callback: (_) async {},
      priority: TaskPriority.low,
    );

    _queueFlushTimer ??= MonitoredAsyncPeriodicTimer(
      id: 'atproto.client.queue_flush',
      name: 'AT Proto Queue Flush',
      description: 'Flushes pending publish queue',
      serviceName: 'AtprotoClientService',
      interval: const Duration(seconds: 10),
      callback: (_) async {},
      priority: TaskPriority.normal,
    );

    _cachePruneTimer ??= MonitoredAsyncPeriodicTimer(
      id: 'atproto.client.cache_prune',
      name: 'AT Proto Cache Prune',
      description: 'Prunes old feed cache entries',
      serviceName: 'AtprotoClientService',
      interval: const Duration(minutes: 15),
      callback: (_) async {
        if (_feed.length > 200) {
          _feed = _feed.take(200).toList();
          await _storage?.saveCachedFeed(_feed);
        }
      },
      priority: TaskPriority.low,
    );

    _repoCheckpointTimer ??= MonitoredAsyncPeriodicTimer(
      id: 'atproto.client.repo_checkpoint',
      name: 'AT Proto Repo Checkpoint',
      description: 'Writes bridge status checkpoints',
      serviceName: 'AtprotoClientService',
      interval: const Duration(minutes: 2),
      callback: (_) async {
        await _storage?.saveStatus({
          'platform': 'bluesky',
          'state': _config.enabled ? 'connected' : 'disconnected',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'feed_count': _feed.length,
          'did': _session?.did,
          'handle': _session?.handle,
        });
      },
      priority: TaskPriority.low,
    );
  }

  String _normalizeBaseUrl(String base) {
    final trimmed = base.trim();
    if (trimmed.endsWith('/')) {
      return trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  void _emit(AtprotoClientEvent event) {
    try {
      _events.add(event);
    } catch (e) {
      LogService().log('AtprotoClientService: failed to emit event: $e');
    }
  }
}
