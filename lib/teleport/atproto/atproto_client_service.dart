/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../services/app_service.dart';
import '../../services/app_args.dart';
import '../../models/monitored_task.dart';
import '../../services/log_service.dart';
import '../../services/profile_service.dart';
import '../../services/profile_storage.dart';
import '../../util/task_monitor_helpers.dart';
import 'atproto_local_pds_service.dart';
import 'atproto_storage_service.dart';
import 'models/atproto_bridge_config.dart';
import 'models/atproto_feed_item.dart';
import 'models/atproto_profile.dart';
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

    await _ensureAutoCredentials();
    await AtprotoLocalPdsService().start(storage: storage, config: _config);
    _startRecurringTasks();
    if (_config.enabled) {
      if (!isAuthenticated) {
        await login(
          identifier: _config.identifier,
          password: _config.password,
          allowAutoPasswordDiscovery: true,
        );
      }
      if (isAuthenticated) {
        await syncFeed();
      }
    }
    _emit(const AtprotoClientEvent(AtprotoClientEventType.configChanged));
  }

  Future<void> saveConfig(AtprotoBridgeConfig newConfig) async {
    var normalized = newConfig.copyWith(pdsUrl: _localPdsBaseUrl());
    if (normalized.identifier.trim().isEmpty) {
      normalized = normalized.copyWith(
        identifier: _deriveIdentifierFromProfile(),
      );
    }
    if (normalized.password.trim().isEmpty) {
      normalized = normalized.copyWith(password: _generatePassword());
    }
    if (!normalized.enabled) {
      normalized = normalized.copyWith(enabled: true);
    }

    _config = normalized;
    await _storage?.saveConfig(normalized);
    final profileStorage = AppService().profileStorage;
    if (profileStorage != null) {
      await AtprotoLocalPdsService().start(
        storage: profileStorage,
        config: normalized,
      );
    }
    await _storage?.registerBridge(enabled: normalized.enabled);
    await _storage?.saveStatus({
      'platform': 'bluesky',
      'state': normalized.enabled ? 'connected' : 'disconnected',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'did': _session?.did,
      'handle': _session?.handle,
    });
    _emit(const AtprotoClientEvent(AtprotoClientEventType.configChanged));
  }

  Future<bool> login({
    required String identifier,
    required String password,
    bool allowAutoPasswordDiscovery = false,
  }) async {
    if (identifier.trim().isEmpty || password.trim().isEmpty) {
      await _ensureAutoCredentials();
      identifier = _config.identifier;
      password = _config.password;
    }

    final profileStorage = AppService().profileStorage;
    if (profileStorage != null) {
      await AtprotoLocalPdsService().start(
        storage: profileStorage,
        config: _config,
      );
    }

    final pds = _normalizeBaseUrl(_config.pdsUrl);
    final uri = Uri.parse('$pds/xrpc/com.atproto.server.createSession');

    try {
      final response = await http.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'identifier': identifier, 'password': password}),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (allowAutoPasswordDiscovery) {
          final discovered = await _discoverServerPassword();
          if (discovered != null &&
              discovered.isNotEmpty &&
              discovered != password) {
            await saveConfig(_config.copyWith(password: discovered));
            return login(
              identifier: identifier,
              password: discovered,
              allowAutoPasswordDiscovery: false,
            );
          }
        }
        _emit(
          AtprotoClientEvent(
            AtprotoClientEventType.error,
            data: 'Login failed (${response.statusCode}): ${response.body}',
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
    if (!await _ensureAuthenticated()) return false;
    final did = _session!.did;

    final record = <String, dynamic>{
      '\$type': 'app.bsky.feed.post',
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
    if (!await _ensureAuthenticated()) return false;
    return _createRecord(
      repo: _session!.did,
      collection: 'app.bsky.feed.like',
      record: {
        '\$type': 'app.bsky.feed.like',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'subject': {'uri': item.uri, 'cid': item.cid},
      },
    );
  }

  Future<bool> repost(AtprotoFeedItem item) async {
    if (!await _ensureAuthenticated()) return false;
    return _createRecord(
      repo: _session!.did,
      collection: 'app.bsky.feed.repost',
      record: {
        '\$type': 'app.bsky.feed.repost',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'subject': {'uri': item.uri, 'cid': item.cid},
      },
    );
  }

  Future<void> _ensureAutoCredentials() async {
    final autoIdentifier = _deriveIdentifierFromProfile();
    final autoPdsUrl = _localPdsBaseUrl();
    var next = _config;
    var changed = false;

    if (next.pdsUrl.trim() != autoPdsUrl) {
      next = next.copyWith(pdsUrl: autoPdsUrl);
      changed = true;
    }
    if (next.identifier.trim().isEmpty) {
      next = next.copyWith(identifier: autoIdentifier);
      changed = true;
    }
    if (next.password.trim().isEmpty) {
      next = next.copyWith(password: _generatePassword());
      changed = true;
    }
    if (!next.enabled) {
      next = next.copyWith(enabled: true);
      changed = true;
    }

    if (changed) {
      await saveConfig(next);
    }
  }

  String _localPdsBaseUrl() {
    final apiPort = AppArgs().port;
    return 'http://127.0.0.1:$apiPort';
  }

  String _deriveIdentifierFromProfile() {
    try {
      final profile = ProfileService().getProfile();
      if (profile.nickname.trim().isNotEmpty) {
        return profile.nickname.trim();
      }
      if (profile.callsign.trim().isNotEmpty) {
        return profile.callsign.trim();
      }
    } catch (_) {}

    final callsign = AppService().currentCallsign;
    if (callsign != null && callsign.trim().isNotEmpty) {
      return callsign.trim();
    }
    return 'geogram-user';
  }

  String _generatePassword() {
    final random = Random.secure();
    final bytes = List.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<String?> _discoverServerPassword() async {
    final pds = _normalizeBaseUrl(_config.pdsUrl);
    final uri = Uri.parse('$pds/api/atproto/admin-password');
    try {
      final response = await http.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return (json['password'] as String?)?.trim();
    } catch (_) {
      return null;
    }
  }

  Future<void> syncFeed() async {
    if (!_config.enabled) return;
    final actor = _resolveReadActor();
    try {
      _feed = await fetchAuthorFeed(actor, limit: 50);
      await _storage?.saveCachedFeed(_feed);
      _emit(const AtprotoClientEvent(AtprotoClientEventType.feedUpdated));
    } catch (e) {
      _emit(AtprotoClientEvent(AtprotoClientEventType.error, data: '$e'));
    }
  }

  Future<List<AtprotoFeedItem>> fetchAuthorFeed(
    String actor, {
    int limit = 50,
  }) async {
    final appView = _normalizeBaseUrl(_config.appViewUrl);
    final uri = Uri.parse(
      '$appView/xrpc/app.bsky.feed.getAuthorFeed'
      '?actor=${Uri.encodeQueryComponent(actor)}'
      '&limit=${limit.clamp(1, 100)}',
    );
    final response = await http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Feed read failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return _parseFeed(body);
  }

  Future<AtprotoProfile?> fetchProfile(String actor) async {
    final appView = _normalizeBaseUrl(_config.appViewUrl);
    final uri = Uri.parse(
      '$appView/xrpc/app.bsky.actor.getProfile'
      '?actor=${Uri.encodeQueryComponent(actor)}',
    );
    final response = await http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return AtprotoProfile.fromJson(json);
  }

  String _resolveReadActor() {
    if (_session?.did.isNotEmpty == true) {
      return _session!.did;
    }
    final configured = _config.identifier.trim();
    if (configured.startsWith('did:') || configured.contains('.')) {
      return configured;
    }
    // Fallback so users always see posts even before login succeeds.
    return 'bsky.app';
  }

  List<AtprotoFeedItem> _parseFeed(Map<String, dynamic> body) {
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
      final viewer = postWrap['viewer'] as Map<String, dynamic>?;
      final embedData = _extractEmbedData(
        postWrap['embed'] as Map<String, dynamic>?,
      );

      final links = _extractLinks(record);

      parsed.add(
        AtprotoFeedItem(
          uri: postWrap['uri'] as String? ?? '',
          cid: postWrap['cid'] as String? ?? '',
          authorDid: author['did'] as String? ?? '',
          authorHandle: author['handle'] as String? ?? '',
          displayName:
              author['displayName'] as String? ??
              (author['handle'] as String? ?? ''),
          avatarUrl: author['avatar'] as String?,
          text: record['text'] as String? ?? '',
          createdAt:
              DateTime.tryParse(record['createdAt'] as String? ?? '') ??
              DateTime.now().toUtc(),
          replyCount: postWrap['replyCount'] as int? ?? 0,
          repostCount: postWrap['repostCount'] as int? ?? 0,
          likeCount: postWrap['likeCount'] as int? ?? 0,
          indexedAt: postWrap['indexedAt'] as String?,
          parentUri: parent?['uri'] as String?,
          rootUri: root?['uri'] as String?,
          externalUrl: embedData.externalUrl,
          externalTitle: embedData.externalTitle,
          externalDescription: embedData.externalDescription,
          externalThumbUrl: embedData.externalThumbUrl,
          imageThumbUrls: embedData.imageThumbUrls,
          imageFullUrls: embedData.imageFullUrls,
          imageAlts: embedData.imageAlts,
          links: links,
          isLikedByMe: viewer?['like'] != null,
          isRepostedByMe: viewer?['repost'] != null,
        ),
      );
    }
    return parsed;
  }

  List<String> _extractLinks(Map<String, dynamic> record) {
    final links = <String>[];
    final facets = record['facets'] as List<dynamic>? ?? const [];
    for (final facet in facets) {
      if (facet is! Map<String, dynamic>) continue;
      final features = facet['features'] as List<dynamic>? ?? const [];
      for (final feature in features) {
        if (feature is! Map<String, dynamic>) continue;
        final uri = feature['uri'] as String?;
        if (uri != null && uri.isNotEmpty) links.add(uri);
      }
    }

    final text = record['text'] as String? ?? '';
    final regex = RegExp(
      r'(https?://[^\s]+|www\.[^\s]+)',
      caseSensitive: false,
    );
    for (final m in regex.allMatches(text)) {
      final value = m.group(0);
      if (value == null || value.isEmpty) continue;
      links.add(value.startsWith('http') ? value : 'https://$value');
    }
    return links.toSet().toList();
  }

  _ParsedEmbedData _extractEmbedData(Map<String, dynamic>? embed) {
    if (embed == null) return const _ParsedEmbedData();

    String? externalUrl;
    String? externalTitle;
    String? externalDescription;
    String? externalThumbUrl;
    final imageThumbUrls = <String>[];
    final imageFullUrls = <String>[];
    final imageAlts = <String>[];

    void parseNode(Map<String, dynamic>? node) {
      if (node == null) return;

      final external = node['external'] as Map<String, dynamic>?;
      if (external != null && externalUrl == null) {
        externalUrl = external['uri'] as String?;
        externalTitle = external['title'] as String?;
        externalDescription = external['description'] as String?;
        externalThumbUrl = external['thumb'] as String?;
      }

      final images = node['images'] as List<dynamic>?;
      if (images != null) {
        for (final image in images) {
          if (image is! Map<String, dynamic>) continue;
          final thumb = image['thumb'] as String?;
          final full = image['fullsize'] as String?;
          final alt = image['alt'] as String?;
          if (thumb != null && thumb.isNotEmpty) imageThumbUrls.add(thumb);
          if (full != null && full.isNotEmpty) imageFullUrls.add(full);
          if (alt != null && alt.isNotEmpty) imageAlts.add(alt);
        }
      }

      parseNode(node['media'] as Map<String, dynamic>?);
      parseNode(node['view'] as Map<String, dynamic>?);
      parseNode(node['record'] as Map<String, dynamic>?);
    }

    parseNode(embed);

    return _ParsedEmbedData(
      externalUrl: externalUrl,
      externalTitle: externalTitle,
      externalDescription: externalDescription,
      externalThumbUrl: externalThumbUrl,
      imageThumbUrls: imageThumbUrls.toSet().toList(),
      imageFullUrls: imageFullUrls.toSet().toList(),
      imageAlts: imageAlts,
    );
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
    if (!await _ensureAuthenticated()) return false;

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
        if (_session != null) {
          final retry = await http.post(
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
          if (retry.statusCode >= 200 && retry.statusCode < 300) {
            await syncFeed();
            return true;
          }
        }
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

  Future<bool> _ensureAuthenticated() async {
    if (_session?.isValid == true) return true;
    await _ensureAutoCredentials();
    return login(
      identifier: _config.identifier,
      password: _config.password,
      allowAutoPasswordDiscovery: true,
    );
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

class _ParsedEmbedData {
  final String? externalUrl;
  final String? externalTitle;
  final String? externalDescription;
  final String? externalThumbUrl;
  final List<String> imageThumbUrls;
  final List<String> imageFullUrls;
  final List<String> imageAlts;

  const _ParsedEmbedData({
    this.externalUrl,
    this.externalTitle,
    this.externalDescription,
    this.externalThumbUrl,
    this.imageThumbUrls = const [],
    this.imageFullUrls = const [],
    this.imageAlts = const [],
  });
}
