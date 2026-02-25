/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Core NOSTR client bridge service — singleton with event stream.
 * Multi-relay: manages one NostrRelayClient per configured relay.
 * Follows the IrcService singleton + event stream pattern.
 *
 * UI events are throttled (500ms) so high-volume message streams
 * don't freeze the Flutter UI with per-message setState rebuilds.
 */

import 'dart:async';
import 'dart:convert';

import '../../models/monitored_task.dart';
import '../../models/profile.dart';
import '../../services/log_service.dart';
import '../../services/profile_service.dart';
import '../../services/profile_storage.dart';
import '../../services/signing_service.dart';
import '../../util/nostr_crypto.dart';
import '../../util/nostr_event.dart';
import '../../util/task_monitor_helpers.dart';
import 'models/nostr_feed_item.dart';
import 'models/nostr_relay_config.dart';
import 'nostr_cache_service.dart';
import 'nostr_relay_client.dart';

/// Feed filter modes.
enum NostrFeedFilter { firehose, onlyFollows }

/// Event types emitted by the NOSTR client bridge.
enum NostrClientEventType {
  connected,
  disconnected,
  feedUpdated,
  configChanged,
  error,
}

/// An event from the NOSTR client bridge.
class NostrClientEvent {
  final NostrClientEventType type;
  final String? relayId;
  final dynamic data;

  const NostrClientEvent(this.type, {this.relayId, this.data});

  @override
  String toString() => 'NostrClientEvent($type, relay=$relayId)';
}

/// Core NOSTR client bridge singleton.
class NostrClientService {
  static final NostrClientService _instance = NostrClientService._internal();
  factory NostrClientService() => _instance;
  NostrClientService._internal();

  NostrCacheService? _cacheService;

  /// Active relay clients keyed by relay config ID.
  final Map<String, NostrRelayClient> _clients = {};

  /// Relay configs keyed by ID.
  final Map<String, NostrRelayConfig> _configs = {};

  /// In-memory feed items, newest last.
  final List<NostrFeedItem> _feedItems = [];

  /// Contact list (followed pubkeys).
  final Set<String> _follows = {};

  /// Profile metadata cache: pubkey -> {name, about, picture, nip05}.
  final Map<String, Map<String, String?>> _profileCache = {};

  /// Current feed filter mode.
  NostrFeedFilter feedFilter = NostrFeedFilter.firehose;

  /// Whether the feed is paused (no new items added to _feedItems).
  bool _paused = false;

  /// Task monitor handles per relay.
  final Map<String, MonitoredIsolateHandle> _taskHandles = {};

  // Event dedup: set of seen event IDs.
  final Set<String> _seenEventIds = {};

  /// Reaction counts per event ID.
  final Map<String, int> _reactionCounts = {};

  /// Event IDs liked by the current user.
  final Set<String> _myLikes = {};

  // Pubkeys we've already requested metadata for (avoid re-requesting).
  final Set<String> _requestedProfilePubkeys = {};

  // Pending pubkeys to batch-request metadata for.
  final Set<String> _pendingProfileRequests = {};
  Timer? _profileRequestTimer;
  static const Duration _profileRequestInterval = Duration(seconds: 3);

  // UI throttle
  static const Duration _uiUpdateInterval = Duration(milliseconds: 500);
  Timer? _uiUpdateTimer;
  bool _uiDirty = false;

  // Batch SQLite writes
  static const Duration _writeFlushInterval = Duration(seconds: 2);
  static const int _writeFlushThreshold = 50;
  final Map<String, List<NostrEvent>> _writeQueues = {};
  Timer? _writeTimer;

  // Active NOSTR search subscriptions per relay
  final Map<String, String> _searchSubIds = {};

  // Max in-memory feed items
  static const int _maxFeedItems = 5000;

  final StreamController<NostrClientEvent> _eventController =
      StreamController<NostrClientEvent>.broadcast();

  /// Stream of NOSTR client bridge events.
  Stream<NostrClientEvent> get events => _eventController.stream;

  /// All configured relays.
  List<NostrRelayConfig> get relays => _configs.values.toList();

  /// Whether any relay is connected.
  bool get isAnyConnected => _clients.values.any((c) => c.isConnected);

  /// Check if a specific relay is connected.
  bool isConnected(String relayId) => _clients[relayId]?.isConnected ?? false;

  /// Check if a client exists (connecting or connected).
  bool isClientActive(String relayId) => _clients.containsKey(relayId);

  /// Get the filtered feed items for display.
  List<NostrFeedItem> get feedItems {
    if (feedFilter == NostrFeedFilter.onlyFollows) {
      return _feedItems.where((item) => item.isFollowed).toList();
    }
    return List.unmodifiable(_feedItems);
  }

  /// Search in-memory feed items by content, author, or npub.
  List<NostrFeedItem> searchFeed(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return feedItems;
    return feedItems.where((item) {
      final content = item.content.toLowerCase();
      final name = item.displayName.toLowerCase();
      final nip05 = (item.authorNip05 ?? '').toLowerCase();
      final npub = item.event.npub.toLowerCase();
      final pubkey = item.pubkey.toLowerCase();
      return content.contains(needle) ||
          name.contains(needle) ||
          nip05.contains(needle) ||
          npub.contains(needle) ||
          pubkey.contains(needle);
    }).toList();
  }

  /// Query connected relays using the NIP-50 "search" filter.
  void requestSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      _clearSearchSubscriptions();
      return;
    }

    for (final entry in _clients.entries) {
      final relayId = entry.key;
      final client = entry.value;
      final existing = _searchSubIds[relayId];
      if (existing != null) {
        client.unsubscribe(existing);
      }
      final subId = client.subscribe({
        'kinds': [NostrEventKind.textNote],
        'search': trimmed,
        'limit': 50,
      }, subscriptionId: 'search_${DateTime.now().millisecondsSinceEpoch}_$relayId');
      _searchSubIds[relayId] = subId;
    }
  }

  void _clearSearchSubscriptions() {
    for (final entry in _searchSubIds.entries) {
      _clients[entry.key]?.unsubscribe(entry.value);
    }
    _searchSubIds.clear();
  }

  /// Followed pubkeys.
  Set<String> get follows => Set.unmodifiable(_follows);

  /// Get cached profile for a pubkey.
  Map<String, String?>? getProfile(String pubkey) => _profileCache[pubkey];

  /// Find an event in the in-memory feed by event ID.
  NostrFeedItem? findFeedItemById(String eventId) {
    for (final item in _feedItems) {
      if (item.id == eventId) return item;
    }
    return null;
  }

  /// Whether the feed is paused.
  bool get isPaused => _paused;

  /// Toggle feed pause state.
  void togglePause() {
    _paused = !_paused;
    _emitEvent(const NostrClientEvent(NostrClientEventType.feedUpdated));
  }

  /// Wire up persistence via ProfileStorage.
  void setStorage(ProfileStorage storage) {
    _cacheService = NostrCacheService(storage);
  }

  /// Load saved configs and auto-connect enabled relays.
  Future<void> autoStart(ProfileStorage storage) async {
    setStorage(storage);
    final relays = await _cacheService!.loadRelays();
    for (final config in relays) {
      _configs[config.id] = config;
    }
    // Load cached profiles from first relay that has them
    for (final config in relays) {
      final profiles = await _cacheService!.loadAllProfiles(config.id);
      if (profiles.isNotEmpty) {
        _profileCache.addAll(profiles);
        _requestedProfilePubkeys.addAll(profiles.keys);
        LogService().log('NostrClientService: loaded ${profiles.length} cached profiles');
        break;
      }
    }
    // Load follows from first relay that has them
    for (final config in relays) {
      final f = await _cacheService!.loadFollows(config.id);
      if (f.isNotEmpty) {
        _follows.addAll(f);
        break;
      }
    }
    // Connect enabled relays
    for (final config in relays) {
      if (config.enabled) {
        connect(config.id);
      }
    }
    if (relays.isNotEmpty) {
      LogService().log('NostrClientService: loaded ${relays.length} relay configs');
    }
  }

  // ---------------------------------------------------------------------------
  // Relay management
  // ---------------------------------------------------------------------------

  /// Add a new relay config.
  Future<void> addRelay(NostrRelayConfig config) async {
    _configs[config.id] = config;
    await _saveConfigs();
    _emitEvent(NostrClientEvent(NostrClientEventType.configChanged, relayId: config.id));
  }

  /// Update an existing relay config.
  Future<void> updateRelay(NostrRelayConfig config) async {
    _configs[config.id] = config;
    await _saveConfigs();
    _emitEvent(NostrClientEvent(NostrClientEventType.configChanged, relayId: config.id));
  }

  /// Remove a relay config and disconnect if connected.
  Future<void> removeRelay(String relayId) async {
    disconnect(relayId);
    _configs.remove(relayId);
    await _saveConfigs();
    _emitEvent(NostrClientEvent(NostrClientEventType.configChanged, relayId: relayId));
  }

  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------

  /// Connect to a relay by config ID.
  void connect(String relayId) {
    final config = _configs[relayId];
    if (config == null) {
      LogService().log('NostrClientService: no config for relay $relayId');
      return;
    }

    if (_clients.containsKey(relayId)) {
      LogService().log('NostrClientService: already connected/connecting to $relayId');
      return;
    }

    _startTimers();

    // Register background task for visibility in task monitor
    _taskHandles[relayId]?.dispose();
    _taskHandles[relayId] = MonitoredIsolateHandle(
      id: 'nostr.client.$relayId',
      name: 'NOSTR ${config.name}',
      description: 'NOSTR relay connection to ${config.url}',
      serviceName: 'NostrClientService',
      priority: TaskPriority.normal,
    );

    final client = NostrRelayClient(config: config);
    client.onResponse = (response) => _handleRelayResponse(relayId, response);
    client.onConnectionChanged = (connected) {
      if (connected) {
        _taskHandles[relayId]?.markRunning();
        _setupSubscriptions(relayId);
        _emitEvent(NostrClientEvent(NostrClientEventType.connected, relayId: relayId));
      } else {
        _taskHandles[relayId]?.markIdle();
        _emitEvent(NostrClientEvent(NostrClientEventType.disconnected, relayId: relayId));
      }
    };
    _clients[relayId] = client;
    client.connect();
    LogService().log('NostrClientService: connecting to ${config.url}');
  }

  /// Disconnect from a relay.
  void disconnect(String relayId) {
    final client = _clients.remove(relayId);
    if (client != null) {
      client.onResponse = null;
      client.onConnectionChanged = null;
      client.disconnect();
      LogService().log('NostrClientService: disconnected from $relayId');
      _emitEvent(NostrClientEvent(NostrClientEventType.disconnected, relayId: relayId));
    }
    _taskHandles.remove(relayId)?.dispose();
    if (_clients.isEmpty) {
      _stopTimers();
    }
  }

  // ---------------------------------------------------------------------------
  // Subscriptions
  // ---------------------------------------------------------------------------

  void _setupSubscriptions(String relayId) {
    final client = _clients[relayId];
    if (client == null) return;

    // Subscribe to kind:1 (text notes) and kind:7 (reactions) — recent activity
    client.subscribe({
      'kinds': [NostrEventKind.textNote, NostrEventKind.reaction],
      'limit': 200,
    }, subscriptionId: 'feed_$relayId');

    // Subscribe to kind:0 (metadata) and kind:3 (contacts) for our pubkey
    final profile = _getProfile();
    if (profile != null && profile.npub.isNotEmpty) {
      try {
        final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
        client.subscribe({
          'kinds': [NostrEventKind.setMetadata, NostrEventKind.contacts],
          'authors': [pubkeyHex],
          'limit': 10,
        }, subscriptionId: 'meta_$relayId');
      } catch (_) {}
    }
  }

  Profile? _getProfile() {
    try {
      return ProfileService().getProfile();
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Relay response handling
  // ---------------------------------------------------------------------------

  void _handleRelayResponse(String relayId, NostrRelayResponse response) {
    switch (response.type) {
      case NostrRelayResponseType.event:
        final event = response.event;
        if (event == null) return;
        _handleEvent(relayId, event);
        break;
      case NostrRelayResponseType.ok:
        // Published event acknowledged
        break;
      case NostrRelayResponseType.eose:
        // End of stored events — initial sync done
        break;
      case NostrRelayResponseType.notice:
        LogService().log('NostrRelayNotice[$relayId]: ${response.message}');
        break;
    }
  }

  void _handleEvent(String relayId, NostrEvent event) {
    // Dedup by event ID
    if (event.id != null && _seenEventIds.contains(event.id)) return;
    if (event.id != null) {
      _seenEventIds.add(event.id!);
      // Cap dedup set size
      if (_seenEventIds.length > 100000) {
        final toRemove = _seenEventIds.take(50000).toList();
        _seenEventIds.removeAll(toRemove);
      }
    }

    switch (event.kind) {
      case NostrEventKind.textNote:
        _handleTextNote(relayId, event);
        break;
      case NostrEventKind.setMetadata:
        _handleMetadata(relayId, event);
        break;
      case NostrEventKind.contacts:
        _handleContacts(relayId, event);
        break;
      case NostrEventKind.reaction:
        _handleReaction(relayId, event);
        break;
    }

    // Queue for batch write
    _queueWrite(relayId, event);
  }

  void _handleTextNote(String relayId, NostrEvent event) {
    if (_paused) return;

    final item = NostrFeedItem(
      event: event,
      relayUrl: _configs[relayId]?.url ?? relayId,
      isFollowed: _follows.contains(event.pubkey),
    );
    if (event.id != null) {
      item.reactionCount = _reactionCounts[event.id!] ?? 0;
      item.isLikedByMe = _myLikes.contains(event.id);
    }

    // Resolve author info from cache
    final profile = _profileCache[event.pubkey];
    if (profile != null) {
      item.authorName = profile['name'];
      item.authorNip05 = profile['nip05'];
      item.authorPicture = profile['picture'];
    } else {
      // Queue metadata request for unknown author
      _queueProfileRequest(event.pubkey);
    }

    // Insert in sorted order (by created_at)
    int insertIdx = _feedItems.length;
    for (int i = _feedItems.length - 1; i >= 0; i--) {
      if (_feedItems[i].createdAt <= event.createdAt) {
        insertIdx = i + 1;
        break;
      }
      if (i == 0) insertIdx = 0;
    }
    _feedItems.insert(insertIdx, item);

    // Trim
    if (_feedItems.length > _maxFeedItems) {
      _feedItems.removeRange(0, _feedItems.length - _maxFeedItems);
    }

    _primeReactionState(relayId, item);
    _uiDirty = true;
  }

  void _primeReactionState(String relayId, NostrFeedItem item) {
    final cache = _cacheService;
    final eventId = item.id;
    if (cache == null || eventId == null) return;

    () async {
      try {
        final counts = await cache.loadReactionCounts(relayId, [eventId]);
        final cachedCount = counts[eventId] ?? 0;
        if (cachedCount > (_reactionCounts[eventId] ?? 0)) {
          _reactionCounts[eventId] = cachedCount;
          item.reactionCount = cachedCount;
        }

        final profile = _getProfile();
        if (profile != null && profile.npub.isNotEmpty) {
          final ownPubkey = NostrCrypto.decodeNpub(profile.npub);
          final liked = await cache.hasReacted(
            relayId,
            eventId: eventId,
            pubkey: ownPubkey,
          );
          if (liked) {
            _myLikes.add(eventId);
            item.isLikedByMe = true;
          }
        }
        _uiDirty = true;
      } catch (_) {}
    }();
  }

  /// Queue a pubkey for metadata request (batched to avoid spamming relays).
  void _queueProfileRequest(String pubkey) {
    if (_requestedProfilePubkeys.contains(pubkey)) return;
    _requestedProfilePubkeys.add(pubkey);
    _pendingProfileRequests.add(pubkey);
    _profileRequestTimer ??= Timer.periodic(
      _profileRequestInterval,
      (_) => _flushProfileRequests(),
    );
  }

  /// Send batched metadata request for pending pubkeys.
  void _flushProfileRequests() {
    if (_pendingProfileRequests.isEmpty) {
      _profileRequestTimer?.cancel();
      _profileRequestTimer = null;
      return;
    }

    // Take up to 50 pubkeys per batch to avoid huge filters
    final batch = _pendingProfileRequests.take(50).toList();
    _pendingProfileRequests.removeAll(batch);

    // Send to all connected relays
    final subId = 'profiles_${DateTime.now().millisecondsSinceEpoch}';
    for (final client in _clients.values) {
      if (client.isConnected) {
        client.subscribe({
          'kinds': [NostrEventKind.setMetadata],
          'authors': batch,
          'limit': batch.length,
        }, subscriptionId: subId);
      }
    }
  }

  void _handleMetadata(String relayId, NostrEvent event) {
    try {
      final meta = jsonDecode(event.content) as Map<String, dynamic>;
      final name = meta['name'] as String?;
      final about = meta['about'] as String?;
      final picture = meta['picture'] as String?;
      final nip05 = meta['nip05'] as String?;

      _profileCache[event.pubkey] = {
        'name': name,
        'about': about,
        'picture': picture,
        'nip05': nip05,
      };

      // Update display info on existing feed items
      for (final item in _feedItems) {
        if (item.pubkey == event.pubkey) {
          item.authorName = name;
          item.authorNip05 = nip05;
          item.authorPicture = picture;
        }
      }

      // Persist
      _cacheService?.saveProfile(
        relayId,
        pubkey: event.pubkey,
        name: name,
        about: about,
        picture: picture,
        nip05: nip05,
      );

      _uiDirty = true;
    } catch (_) {}
  }

  void _handleContacts(String relayId, NostrEvent event) {
    // kind:3 tags contain ['p', pubkey] entries for follows
    final newFollows = <String>{};
    for (final tag in event.tags) {
      if (tag.length >= 2 && tag[0] == 'p') {
        newFollows.add(tag[1]);
      }
    }
    _follows
      ..clear()
      ..addAll(newFollows);

    // Update isFollowed on existing feed items
    for (final item in _feedItems) {
      item.isFollowed = _follows.contains(item.pubkey);
    }

    _cacheService?.saveFollows(relayId, newFollows.toList());
    _uiDirty = true;
  }

  void _handleReaction(String relayId, NostrEvent event) {
    // Extract target event ID from 'e' tag
    final targetEventId = event.getTagValue('e');
    if (targetEventId == null) return;

    // Update in-memory count
    _reactionCounts[targetEventId] = (_reactionCounts[targetEventId] ?? 0) + 1;

    // Check if this is our own reaction
    final profile = _getProfile();
    if (profile != null && profile.npub.isNotEmpty) {
      try {
        final ownPubkey = NostrCrypto.decodeNpub(profile.npub);
        if (event.pubkey == ownPubkey) {
          _myLikes.add(targetEventId);
        }
      } catch (_) {}
    }

    // Update matching feed item
    for (final item in _feedItems) {
      if (item.id == targetEventId) {
        item.reactionCount = _reactionCounts[targetEventId] ?? 0;
        if (_myLikes.contains(targetEventId)) {
          item.isLikedByMe = true;
        }
        break;
      }
    }

    // Persist to cache
    _cacheService?.saveReaction(
      relayId,
      eventId: targetEventId,
      reactorPubkey: event.pubkey,
      content: event.content,
      createdAt: event.createdAt,
    );

    _uiDirty = true;
  }

  // ---------------------------------------------------------------------------
  // Follow / Unfollow
  // ---------------------------------------------------------------------------

  /// Follow a user by pubkey and publish kind:3 contact list.
  Future<bool> followUser(String pubkey) async {
    if (_follows.contains(pubkey)) return true;
    _follows.add(pubkey);

    // Update isFollowed on existing feed items
    for (final item in _feedItems) {
      if (item.pubkey == pubkey) item.isFollowed = true;
    }

    _uiDirty = true;
    _emitEvent(const NostrClientEvent(NostrClientEventType.feedUpdated));

    return _publishContactList();
  }

  /// Unfollow a user by pubkey and publish kind:3 contact list.
  Future<bool> unfollowUser(String pubkey) async {
    if (!_follows.contains(pubkey)) return true;
    _follows.remove(pubkey);

    // Update isFollowed on existing feed items
    for (final item in _feedItems) {
      if (item.pubkey == pubkey) item.isFollowed = false;
    }

    _uiDirty = true;
    _emitEvent(const NostrClientEvent(NostrClientEventType.feedUpdated));

    return _publishContactList();
  }

  /// Publish the current contact list as a kind:3 event.
  Future<bool> _publishContactList() async {
    final profile = _getProfile();
    if (profile == null || profile.npub.isEmpty) return false;

    try {
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent.contacts(
        pubkeyHex: pubkeyHex,
        followedPubkeys: _follows.toList(),
      );

      final signed = await SigningService().signEvent(event, profile);
      if (signed == null) return false;

      int published = 0;
      for (final entry in _clients.entries) {
        final config = _configs[entry.key];
        if (config != null && config.write && entry.value.isConnected) {
          entry.value.publish(signed);
          published++;
        }
      }

      // Persist follows locally
      for (final relayId in _configs.keys) {
        _cacheService?.saveFollows(relayId, _follows.toList());
      }

      return published > 0;
    } catch (e) {
      LogService().log('NostrClientService: publishContactList error: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Like (Reaction)
  // ---------------------------------------------------------------------------

  /// Like a post by publishing a kind:7 reaction.
  Future<bool> likeEvent(String eventId, String authorPubkey) async {
    if (_myLikes.contains(eventId)) return true; // already liked

    final profile = _getProfile();
    if (profile == null || profile.npub.isEmpty) return false;

    try {
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent.reaction(
        pubkeyHex: pubkeyHex,
        targetEventId: eventId,
        targetPubkey: authorPubkey,
      );

      final signed = await SigningService().signEvent(event, profile);
      if (signed == null) return false;

      int published = 0;
      for (final entry in _clients.entries) {
        final config = _configs[entry.key];
        if (config != null && config.write && entry.value.isConnected) {
          entry.value.publish(signed);
          published++;
          _cacheService?.saveReaction(
            entry.key,
            eventId: eventId,
            reactorPubkey: pubkeyHex,
            content: signed.content,
            createdAt: signed.createdAt,
          );
        }
      }

      if (published > 0) {
        // Optimistic update
        _myLikes.add(eventId);
        _reactionCounts[eventId] = (_reactionCounts[eventId] ?? 0) + 1;
        for (final item in _feedItems) {
          if (item.id == eventId) {
            item.isLikedByMe = true;
            item.reactionCount = _reactionCounts[eventId]!;
            break;
          }
        }
        if (signed.id != null) _seenEventIds.add(signed.id!);
        _uiDirty = true;
      }

      return published > 0;
    } catch (e) {
      LogService().log('NostrClientService: likeEvent error: $e');
      return false;
    }
  }

  /// Whether the current user has liked a given event.
  bool isLikedByMe(String eventId) => _myLikes.contains(eventId);

  /// Get the reaction count for an event.
  int getReactionCount(String eventId) => _reactionCounts[eventId] ?? 0;

  // ---------------------------------------------------------------------------
  // User posts
  // ---------------------------------------------------------------------------

  /// Get posts from a specific pubkey from the in-memory feed.
  List<NostrFeedItem> getPostsByPubkey(String pubkey) {
    return _feedItems.where((item) => item.pubkey == pubkey).toList();
  }

  /// Request posts from a specific pubkey from connected relays.
  void requestUserPosts(String pubkey) {
    final subId = 'user_${pubkey.substring(0, 8)}_${DateTime.now().millisecondsSinceEpoch}';
    for (final client in _clients.values) {
      if (client.isConnected) {
        client.subscribe({
          'kinds': [NostrEventKind.textNote],
          'authors': [pubkey],
          'limit': 50,
        }, subscriptionId: subId);
      }
    }
    // Also request their metadata if not cached
    _queueProfileRequest(pubkey);
  }

  /// Request a specific event by ID from connected relays.
  void requestEventById(String eventId) {
    final subId = 'event_${eventId}_${DateTime.now().millisecondsSinceEpoch}';
    for (final client in _clients.values) {
      if (client.isConnected) {
        client.subscribe({
          'ids': [eventId],
          'limit': 1,
        }, subscriptionId: subId);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Publishing
  // ---------------------------------------------------------------------------

  /// Publish a kind:1 text note to all write-enabled relays.
  Future<bool> publish(String content) async {
    return publishWithTags(content, tags: const []);
  }

  /// Publish a kind:1 text note with custom tags to all write-enabled relays.
  Future<bool> publishWithTags(
    String content, {
    required List<List<String>> tags,
  }) async {
    final profile = _getProfile();
    if (profile == null || profile.npub.isEmpty) return false;

    try {
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: content,
        tags: tags,
      );

      final signed = await SigningService().signEvent(event, profile);
      if (signed == null) return false;

      int published = 0;
      for (final entry in _clients.entries) {
        final config = _configs[entry.key];
        if (config != null && config.write && entry.value.isConnected) {
          entry.value.publish(signed);
          published++;
        }
      }

      // Add to local feed immediately
      if (published > 0) {
        final item = NostrFeedItem(
          event: signed,
          relayUrl: 'local',
          isFollowed: false,
        );
        final profileMeta = _profileCache[pubkeyHex];
        if (profileMeta != null) {
          item.authorName = profileMeta['name'];
          item.authorNip05 = profileMeta['nip05'];
          item.authorPicture = profileMeta['picture'];
        }
        _feedItems.add(item);
        if (signed.id != null) _seenEventIds.add(signed.id!);
        _uiDirty = true;
      }

      return published > 0;
    } catch (e) {
      LogService().log('NostrClientService: publish error: $e');
      return false;
    }
  }

  /// Build NIP-10 reply tags from a target event.
  List<List<String>> buildReplyTags(NostrEvent target) {
    final targetId = target.id;
    if (targetId == null) return const [];

    String rootId = targetId;
    for (final tag in target.tags) {
      if (tag.length >= 4 && tag[0] == 'e' && tag[3] == 'root') {
        rootId = tag[1];
        break;
      }
    }

    final tags = <List<String>>[
      ['e', rootId, '', 'root'],
      ['e', targetId, '', 'reply'],
      ['p', target.pubkey],
    ];
    return tags;
  }

  /// Publish a reply to a target event (kind:1 with NIP-10 tags).
  Future<bool> publishReply(String content, NostrEvent target) async {
    final tags = buildReplyTags(target);
    return publishWithTags(content, tags: tags);
  }

  // ---------------------------------------------------------------------------
  // Batch writes
  // ---------------------------------------------------------------------------

  void _queueWrite(String relayId, NostrEvent event) {
    final queue = _writeQueues.putIfAbsent(relayId, () => []);
    queue.add(event);
    if (queue.length >= _writeFlushThreshold) {
      _flushWrites(relayId);
    }
  }

  Future<void> _flushAllWrites() async {
    for (final relayId in _writeQueues.keys.toList()) {
      await _flushWrites(relayId);
    }
  }

  Future<void> _flushWrites(String relayId) async {
    final queue = _writeQueues[relayId];
    if (queue == null || queue.isEmpty || _cacheService == null) return;
    final batch = List<NostrEvent>.from(queue);
    queue.clear();
    await _cacheService!.cacheEvents(relayId, batch);
  }

  // ---------------------------------------------------------------------------
  // UI throttle timer
  // ---------------------------------------------------------------------------

  void _startTimers() {
    _uiUpdateTimer ??= Timer.periodic(_uiUpdateInterval, _onUiTick);
    _writeTimer ??= Timer.periodic(_writeFlushInterval, (_) => _flushAllWrites());
  }

  void _stopTimers() {
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;
    _writeTimer?.cancel();
    _writeTimer = null;
    _profileRequestTimer?.cancel();
    _profileRequestTimer = null;
    _flushAllWrites();
  }

  void _onUiTick(Timer _) {
    if (_uiDirty) {
      _uiDirty = false;
      _eventController.add(const NostrClientEvent(NostrClientEventType.feedUpdated));
    }
  }

  void _emitEvent(NostrClientEvent event) {
    _eventController.add(event);
  }

  // ---------------------------------------------------------------------------
  // Config persistence
  // ---------------------------------------------------------------------------

  Future<void> _saveConfigs() async {
    if (_cacheService == null) return;
    await _cacheService!.saveRelays(_configs.values.toList());
  }

  // ---------------------------------------------------------------------------
  // Status (for debug API)
  // ---------------------------------------------------------------------------

  Map<String, dynamic> getStatus() {
    final relayList = <Map<String, dynamic>>[];
    for (final config in _configs.values) {
      final client = _clients[config.id];
      relayList.add({
        'id': config.id,
        'url': config.url,
        'name': config.name,
        'enabled': config.enabled,
        'read': config.read,
        'write': config.write,
        'connected': client?.isConnected ?? false,
      });
    }
    return {
      'relays': relayList,
      'anyConnected': isAnyConnected,
      'feedItems': _feedItems.length,
      'follows': _follows.length,
      'filter': feedFilter.name,
      'paused': _paused,
      'seenEvents': _seenEventIds.length,
      'profilesLoaded': _profileCache.length,
      'reactionsTracked': _reactionCounts.length,
      'myLikes': _myLikes.length,
    };
  }

  /// Dispose all resources.
  void dispose() {
    _stopTimers();
    for (final client in _clients.values) {
      client.onResponse = null;
      client.onConnectionChanged = null;
      client.disconnect();
    }
    _clients.clear();
    for (final handle in _taskHandles.values) {
      handle.dispose();
    }
    _taskHandles.clear();
    _cacheService?.dispose();
    _cacheService = null;
    _eventController.close();
  }
}
