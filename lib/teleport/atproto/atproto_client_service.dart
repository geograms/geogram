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

class AtprotoThreadData {
  final AtprotoFeedItem rootPost;
  final List<AtprotoFeedItem> replies;

  const AtprotoThreadData({required this.rootPost, required this.replies});
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
  Set<String> _followedActors = <String>{};

  MonitoredAsyncPeriodicTimer? _sessionRefreshTimer;
  MonitoredAsyncPeriodicTimer? _feedSyncTimer;
  MonitoredAsyncPeriodicTimer? _notifyRelaysTimer;
  MonitoredAsyncPeriodicTimer? _queueFlushTimer;
  MonitoredAsyncPeriodicTimer? _cachePruneTimer;
  MonitoredAsyncPeriodicTimer? _repoCheckpointTimer;

  AtprotoBridgeConfig get config => _config;
  AtprotoSession? get session => _session;
  List<AtprotoFeedItem> get feed => List.unmodifiable(_feed);
  List<String> get followedActors =>
      List.unmodifiable(_followedActors.toList());
  bool get isAuthenticated => _session?.isValid == true;

  Future<void> autoStart(ProfileStorage storage) async {
    _storage = AtprotoStorageService(storage);
    await _storage!.ensureDirectories();
    _config = await _storage!.loadConfig();
    _session = await _storage!.loadSession();
    _feed = await _storage!.loadCachedFeed();
    _followedActors = (await _storage!.loadFollowedActors()).toSet();

    await _ensureAutoCredentials();
    await AtprotoLocalPdsService().start(storage: storage, config: _config);
    _startRecurringTasks();
    if (_config.enabled) {
      final validSession = await _hasUsableSession();
      if (!validSession) {
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
    final ok = await _createRecord(
      repo: _session!.did,
      collection: 'app.bsky.feed.like',
      record: {
        '\$type': 'app.bsky.feed.like',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'subject': {'uri': item.uri, 'cid': item.cid},
      },
    );
    if (ok) {
      _applyFeedPatch(
        item.uri,
        (current) => current.copyWith(
          isLikedByMe: true,
          likeCount: current.likeCount + 1,
        ),
      );
    }
    return ok;
  }

  Future<bool> repost(AtprotoFeedItem item) async {
    if (!await _ensureAuthenticated()) return false;
    final ok = await _createRecord(
      repo: _session!.did,
      collection: 'app.bsky.feed.repost',
      record: {
        '\$type': 'app.bsky.feed.repost',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'subject': {'uri': item.uri, 'cid': item.cid},
      },
    );
    if (ok) {
      _applyFeedPatch(
        item.uri,
        (current) => current.copyWith(
          isRepostedByMe: true,
          repostCount: current.repostCount + 1,
        ),
      );
    }
    return ok;
  }

  Future<bool> followActor(String actorOrDid) async {
    if (!await _ensureAuthenticated()) return false;
    final trimmed = actorOrDid.trim();
    if (trimmed.isEmpty) return false;

    String did = trimmed;
    String? handle;
    if (!did.startsWith('did:')) {
      final profile = await fetchProfile(trimmed);
      did = profile?.did ?? '';
      handle = profile?.handle;
    }
    if (did.isEmpty) return false;
    if (did == _session?.did) return false;

    final ok = await _createRecord(
      repo: _session!.did,
      collection: 'app.bsky.graph.follow',
      record: {
        '\$type': 'app.bsky.graph.follow',
        'subject': did,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      },
    );
    if (ok) {
      _followedActors.add(did);
      if (handle != null && handle.isNotEmpty) {
        _followedActors.add(handle);
      }
      await _storage?.saveFollowedActors(_followedActors.toList());
      _emit(const AtprotoClientEvent(AtprotoClientEventType.configChanged));
    }
    return ok;
  }

  bool isFollowingActor({String? did, String? handle, String? actor}) {
    final candidates = <String>[
      if (did != null) did,
      if (handle != null) handle,
      if (actor != null) actor,
    ].map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty);

    final normalized = _followedActors
        .map((e) => e.trim().toLowerCase())
        .toSet();
    for (final candidate in candidates) {
      if (normalized.contains(candidate)) return true;
    }
    return false;
  }

  Future<List<AtprotoFeedItem>> fetchFollowingActivity({
    int perActorLimit = 20,
    int maxActors = 30,
  }) async {
    final actors = _followedActors.where((e) => e.trim().isNotEmpty).toList()
      ..sort();
    if (actors.isEmpty) return const [];

    final merged = <AtprotoFeedItem>[];
    final seen = <String>{};
    for (final actor in actors.take(maxActors)) {
      try {
        final feed = await fetchAuthorFeed(
          actor,
          limit: perActorLimit.clamp(1, 100),
        );
        for (final item in feed) {
          if (item.uri.isEmpty || seen.contains(item.uri)) continue;
          seen.add(item.uri);
          merged.add(item);
        }
      } catch (_) {
        // Ignore per-actor failures to keep timeline resilient.
      }
    }
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return merged;
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
    final candidates = <String>[
      _resolveReadActor(),
      'bsky.app',
    ].where((e) => e.trim().isNotEmpty).toSet().toList();

    Object? lastError;
    for (final actor in candidates) {
      try {
        _feed = await fetchAuthorFeed(actor, limit: 50);
        await _storage?.saveCachedFeed(_feed);
        _emit(const AtprotoClientEvent(AtprotoClientEventType.feedUpdated));
        return;
      } catch (e) {
        lastError = e;
      }
    }

    if (lastError != null) {
      _emit(
        AtprotoClientEvent(AtprotoClientEventType.error, data: '$lastError'),
      );
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
      final details = response.body.length > 180
          ? '${response.body.substring(0, 180)}...'
          : response.body;
      throw Exception('Feed read failed (${response.statusCode}) $details');
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

  Future<List<AtprotoProfile>> searchPeople(
    String query, {
    int limit = 25,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final bases = _searchBaseCandidates();
    Object? lastError;
    for (final base in bases) {
      final uri = Uri.parse(
        '$base/xrpc/app.bsky.actor.searchActors'
        '?q=${Uri.encodeQueryComponent(q)}'
        '&limit=${limit.clamp(1, 100)}',
      );
      final response = await http.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        lastError = Exception('People search failed (${response.statusCode})');
        continue;
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final actors = body['actors'] as List<dynamic>? ?? const [];
      return actors
          .whereType<Map>()
          .map((e) => AtprotoProfile.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    throw lastError ?? Exception('People search failed');
  }

  Future<List<AtprotoFeedItem>> searchPosts(
    String query, {
    int limit = 25,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final bases = _searchBaseCandidates();
    Object? lastError;
    for (final base in bases) {
      final uri = Uri.parse(
        '$base/xrpc/app.bsky.feed.searchPosts'
        '?q=${Uri.encodeQueryComponent(q)}'
        '&limit=${limit.clamp(1, 100)}',
      );
      final response = await http.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        lastError = Exception('Post search failed (${response.statusCode})');
        continue;
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final posts = body['posts'] as List<dynamic>? ?? const [];
      return posts
          .whereType<Map>()
          .map((e) => _parsePostWrap(Map<String, dynamic>.from(e)))
          .toList();
    }
    throw lastError ?? Exception('Post search failed');
  }

  List<String> _searchBaseCandidates() {
    final configured = _normalizeBaseUrl(_config.appViewUrl);
    return <String>[
      configured,
      'https://api.bsky.app',
    ].where((e) => e.trim().isNotEmpty).toSet().toList();
  }

  Future<List<AtprotoFeedItem>> fetchReplies(
    String postUri, {
    int depth = 6,
  }) async {
    final thread = await fetchThread(postUri, depth: depth);
    return thread.replies;
  }

  Future<AtprotoThreadData> fetchThread(String postUri, {int depth = 6}) async {
    final appView = _normalizeBaseUrl(_config.appViewUrl);
    final uri = Uri.parse(
      '$appView/xrpc/app.bsky.feed.getPostThread'
      '?uri=${Uri.encodeQueryComponent(postUri)}'
      '&depth=${depth.clamp(1, 20)}',
    );
    final response = await http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final details = response.body.length > 180
          ? '${response.body.substring(0, 180)}...'
          : response.body;
      throw Exception('Replies read failed (${response.statusCode}) $details');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final thread = body['thread'];
    if (thread is! Map<String, dynamic>) {
      throw Exception('Thread payload not found for post');
    }
    final rootWrap = thread['post'];
    if (rootWrap is! Map<String, dynamic>) {
      throw Exception('Root post not found in thread');
    }
    final root = _parsePostWrap(rootWrap);
    final replies = <AtprotoFeedItem>[];
    final seen = <String>{};
    seen.add(root.uri);
    _collectReplies(thread, replies, seen, includeSelf: false);
    replies.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return AtprotoThreadData(rootPost: root, replies: replies);
  }

  String _resolveReadActor() {
    if (_session?.did.isNotEmpty == true) {
      final did = _session!.did;
      if (did.startsWith('did:plc:') || did.startsWith('did:')) {
        // AppView can reliably read PLC DIDs; local did:web may not resolve.
        if (!did.startsWith('did:web:')) return did;
      }
    }
    if (_session?.handle.isNotEmpty == true && _session!.handle.contains('.')) {
      return _session!.handle;
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

      parsed.add(_parsePostWrap(postWrap));
    }
    return parsed;
  }

  void _collectReplies(
    Map<String, dynamic> node,
    List<AtprotoFeedItem> out,
    Set<String> seen, {
    required bool includeSelf,
  }) {
    final postWrap = node['post'];
    if (postWrap is Map<String, dynamic>) {
      final parsed = _parsePostWrap(postWrap);
      if (parsed.uri.isNotEmpty && !seen.contains(parsed.uri)) {
        if (includeSelf) {
          out.add(parsed);
        }
        seen.add(parsed.uri);
      }
    }

    final replies = node['replies'] as List<dynamic>? ?? const [];
    for (final replyNode in replies) {
      if (replyNode is! Map<String, dynamic>) continue;
      final childPost = replyNode['post'];
      if (childPost is Map<String, dynamic>) {
        final parsed = _parsePostWrap(childPost);
        if (parsed.uri.isNotEmpty && !seen.contains(parsed.uri)) {
          out.add(parsed);
          seen.add(parsed.uri);
        }
      }
      _collectReplies(replyNode, out, seen, includeSelf: false);
    }
  }

  AtprotoFeedItem _parsePostWrap(Map<String, dynamic> postWrap) {
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

    return AtprotoFeedItem(
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
    );
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
        final reloginOk = await login(
          identifier: _config.identifier,
          password: _config.password,
          allowAutoPasswordDiscovery: true,
        );
        if (reloginOk && _session != null) {
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
    if (await _hasUsableSession()) return true;
    await _ensureAutoCredentials();
    return login(
      identifier: _config.identifier,
      password: _config.password,
      allowAutoPasswordDiscovery: true,
    );
  }

  Future<bool> _hasUsableSession() async {
    if (_session?.isValid != true) return false;
    final pds = _normalizeBaseUrl(_config.pdsUrl);
    final uri = Uri.parse('$pds/xrpc/com.atproto.server.getSession');
    try {
      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer ${_session!.accessJwt}'},
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  void _applyFeedPatch(
    String uri,
    AtprotoFeedItem Function(AtprotoFeedItem current) mapper,
  ) {
    var changed = false;
    final updated = _feed.map((item) {
      if (item.uri != uri) return item;
      changed = true;
      return mapper(item);
    }).toList();
    if (!changed) return;
    _feed = updated;
    _emit(const AtprotoClientEvent(AtprotoClientEventType.feedUpdated));
    _storage?.saveCachedFeed(_feed);
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
