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

  /// Followed pubkeys.
  Set<String> get follows => Set.unmodifiable(_follows);

  /// Get cached profile for a pubkey.
  Map<String, String?>? getProfile(String pubkey) => _profileCache[pubkey];

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

    // Subscribe to kind:1 (text notes) — recent notes
    client.subscribe({
      'kinds': [NostrEventKind.textNote],
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

    _uiDirty = true;
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

  // ---------------------------------------------------------------------------
  // Publishing
  // ---------------------------------------------------------------------------

  /// Publish a kind:1 text note to all write-enabled relays.
  Future<bool> publish(String content) async {
    final profile = _getProfile();
    if (profile == null || profile.npub.isEmpty) return false;

    try {
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: content,
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
