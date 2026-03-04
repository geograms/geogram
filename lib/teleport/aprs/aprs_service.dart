/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Core APRS bridge service — singleton with event stream.
 * Unlike Telegram/Signal, APRS has no authentication flow.
 * Wires AprsIsClient for live APRS-IS connectivity.
 * Integrates GPS via LocationProviderService and persists packets via AprsCacheService.
 *
 * UI events are throttled (500ms) so high-volume packet streams don't freeze
 * the Flutter UI with per-packet setState rebuilds.
 */

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../services/ble_message_service.dart';
import '../../services/location_provider_service.dart';
import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../util/event_bus.dart';
import 'aprs_cache_service.dart';
import 'aprs_is_client.dart';
import 'blue_aprs_service.dart';
import 'models/aprs_conversation.dart';
import 'aprs_message_utils.dart';
import 'models/aprs_packet.dart';

/// Event types emitted by the APRS bridge.
enum AprsEventType {
  packetReceived,
  messageReceived,
  connected,
  disconnected,
  error,
}

/// An event from the APRS bridge.
class AprsEvent {
  final AprsEventType type;
  final dynamic data;

  const AprsEvent(this.type, [this.data]);

  @override
  String toString() => 'AprsEvent($type)';
}

/// Core APRS bridge singleton.
///
/// Follows the Signal/Telegram singleton pattern but much simpler —
/// no FFI client, no auth flow. Uses AprsIsClient for APRS-IS TCP connection.
class AprsService {
  static final AprsService _instance = AprsService._internal();
  factory AprsService() => _instance;
  AprsService._internal();

  bool _enabled = false;
  double _radiusKm = 100;
  String? _callsign;
  AprsIsClient? _client;

  // BlueAPRS settings
  bool _blueAprsEnabled = false;
  bool _blueAprsBeaconEnabled = false;
  int _blueAprsBeaconIntervalSec = 300;

  // User-chosen position (persisted in config)
  double? _savedLat;
  double? _savedLon;

  // GPS tracking via LocationProviderService
  VoidCallback? _locationDispose;
  double? _lastFilterLat;
  double? _lastFilterLon;
  DateTime? _lastFilterTime;

  // Persistence
  AprsCacheService? _cacheService;

  /// Expose cache service for debug API inspection.
  AprsCacheService? get cacheService => _cacheService;

  // Tag subscriptions for hashtag group channels
  Set<String> _subscribedTags = {'#cq'};

  // Message sending sequence number
  int _nextSeqNo = 1;

  // Dedup — keeps recent rawTnc2 hashes to skip duplicates
  final Set<String> _recentPacketHashes = {};
  static const int _maxRecentHashes = 5000;

  // Geochat comment dedup — suppresses repeated identical comments from same
  // callsign within a 1-hour window (GPS drift causes slightly different coords
  // but the same comment text).
  final Map<String, DateTime> _geoChatDedup = {};
  static const Duration _geoChatDedupWindow = Duration(hours: 1);

  /// Last known position per callsign — updated from position packets.
  /// Used to show distance for message packets (which don't carry coordinates).
  final Map<String, (double, double)> lastKnownPositions = {};

  static const int _maxStreamPackets = 10000;
  static const int _maxMessages = 5000;

  // GPS filter thresholds
  static const Duration _filterTimeThreshold = Duration(minutes: 10);
  static const double _filterDistanceThresholdKm = 5.0;

  // UI throttle — accumulate packets, emit events periodically
  static const Duration _uiUpdateInterval = Duration(milliseconds: 500);
  Timer? _uiUpdateTimer;
  bool _uiDirtyStream = false;
  bool _uiDirtyMessages = false;

  // Batch SQLite writes — queue packets and flush periodically
  static const Duration _writeFlushInterval = Duration(seconds: 2);
  static const int _writeFlushThreshold = 100;
  final List<AprsPacket> _writeQueue = [];
  Timer? _writeTimer;

  final StreamController<AprsEvent> _eventController =
      StreamController<AprsEvent>.broadcast();

  /// All received broadcast packets (stream tab).
  final List<AprsPacket> streamPackets = [];

  /// Directed messages addressed to this station (messages tab).
  final List<AprsPacket> messages = [];

  /// Position packets with non-empty comments (geo-chat on map).
  final List<AprsPacket> geoChatMessages = [];

  /// Stream of APRS bridge events.
  Stream<AprsEvent> get events => _eventController.stream;

  /// Whether the user has enabled APRS operations.
  bool get isEnabled => _enabled;

  /// Receive radius in km (1–1000, default 100).
  double get radiusKm => _radiusKm;
  set radiusKm(double value) {
    _radiusKm = value.clamp(1, 1000);
    LogService().log('AprsService: radiusKm set to $_radiusKm, client=${_client != null}');
    _client?.updateFilter(radiusKm: _radiusKm);
    _clearPackets();
  }

  /// Whether the APRS-IS client is connected.
  bool get isRunning => _client?.isConnected ?? false;

  /// Whether the user has set a location (required before enabling).
  bool get hasLocation => _savedLat != null && _savedLon != null;

  /// Saved user-chosen position (null if not set).
  double? get savedLatitude => _savedLat;
  double? get savedLongitude => _savedLon;

  /// Current callsign (set when enabled).
  String? get callsign => _callsign;

  /// Currently subscribed hashtag channels.
  Set<String> get subscribedTags => Set.unmodifiable(_subscribedTags);

  /// Whether BlueAPRS (APRS over BLE) is enabled.
  bool get blueAprsEnabled => _blueAprsEnabled;
  set blueAprsEnabled(bool value) {
    if (_blueAprsEnabled == value) return;
    _blueAprsEnabled = value;
    _saveConfig();
    if (_enabled) {
      if (value) {
        try {
          final ble = BLEMessageService();
          if (ble.isInitialized) {
            BlueAprsService().activate();
          }
        } catch (_) {}
      } else {
        BlueAprsService().deactivate();
      }
    }
  }

  /// Whether BlueAPRS beacon broadcasting is enabled.
  bool get blueAprsBeaconEnabled => _blueAprsBeaconEnabled;
  set blueAprsBeaconEnabled(bool value) {
    if (_blueAprsBeaconEnabled == value) return;
    _blueAprsBeaconEnabled = value;
    _saveConfig();
    final blueAprs = BlueAprsService();
    if (value && blueAprs.isActive) {
      blueAprs.startBeacon(_blueAprsBeaconIntervalSec);
    } else {
      blueAprs.stopBeacon();
    }
  }

  /// BlueAPRS beacon interval in seconds.
  int get blueAprsBeaconIntervalSec => _blueAprsBeaconIntervalSec;
  set blueAprsBeaconIntervalSec(int value) {
    if (_blueAprsBeaconIntervalSec == value) return;
    _blueAprsBeaconIntervalSec = value;
    _saveConfig();
    final blueAprs = BlueAprsService();
    if (_blueAprsBeaconEnabled && blueAprs.isActive) {
      blueAprs.startBeacon(value);
    }
  }

  /// Subscribe to a hashtag channel.
  void addTag(String tag) {
    final normalized = tag.toLowerCase().startsWith('#') ? tag.toLowerCase() : '#${tag.toLowerCase()}';
    if (_subscribedTags.add(normalized)) {
      _saveConfig();
      _uiDirtyMessages = true;
    }
  }

  /// Unsubscribe from a hashtag channel.
  void removeTag(String tag) {
    final normalized = tag.toLowerCase().startsWith('#') ? tag.toLowerCase() : '#${tag.toLowerCase()}';
    if (_subscribedTags.remove(normalized)) {
      _saveConfig();
      _uiDirtyMessages = true;
    }
  }

  /// Emit an event into the service stream (used by AprsIsClient).
  void emitEvent(AprsEvent event) {
    _eventController.add(event);
  }

  /// Wire up persistence via ProfileStorage (call before enable).
  void setStorage(ProfileStorage storage) {
    _cacheService = AprsCacheService(storage, '');
  }

  /// Restore saved config (position, radius) and optionally auto-start.
  /// Call from main.dart post-frame callback.
  Future<void> autoStart(ProfileStorage storage, {required String callsign}) async {
    if (_enabled) return;
    setStorage(storage);
    final config = await _cacheService!.loadConfig();
    if (config == null) return;
    final radius = (config['radiusKm'] as num?)?.toDouble();
    if (radius != null) _radiusKm = radius;
    _savedLat = (config['latitude'] as num?)?.toDouble();
    _savedLon = (config['longitude'] as num?)?.toDouble();
    // Restore tag subscriptions
    final savedTags = config['subscribedTags'] as List?;
    if (savedTags != null && savedTags.isNotEmpty) {
      _subscribedTags = savedTags.map((t) => t.toString().toLowerCase()).toSet();
    }
    // Restore BlueAPRS settings
    _blueAprsEnabled = config['blueAprsEnabled'] == true;
    _blueAprsBeaconEnabled = config['blueAprsBeaconEnabled'] == true;
    final savedBeaconInterval = config['blueAprsBeaconIntervalSec'] as int?;
    if (savedBeaconInterval != null && savedBeaconInterval > 0) {
      _blueAprsBeaconIntervalSec = savedBeaconInterval;
    }
    // Only auto-start if previously enabled AND location is set
    if (config['enabled'] != true || !hasLocation) {
      if (config['enabled'] == true && !hasLocation) {
        LogService().log('AprsService: auto-start skipped — no saved location');
      }
      return;
    }
    LogService().log('AprsService: auto-starting for $callsign at $_savedLat, $_savedLon');
    enable(callsign: callsign);
  }

  /// Send a raw TNC2 line to APRS-IS (used by BlueAprsService).
  void sendRaw(String tnc2Line) {
    _client?.sendRaw(tnc2Line);
  }

  /// Enable APRS operations — connects to APRS-IS using GPS position.
  /// Fire-and-forget safe: loads cached packets, connects, and emits events
  /// without blocking the caller.
  void enable({required String callsign}) {
    if (_enabled) return;
    _enabled = true;
    _callsign = callsign;

    _startUiTimer();
    // Persist enabled state, then load cache + connect in background
    _saveConfig();
    _initAsync(callsign);

    // Activate BlueAPRS bridge if enabled and BLE is available
    if (_blueAprsEnabled) {
      try {
        final ble = BLEMessageService();
        if (ble.isInitialized) {
          final blueAprs = BlueAprsService();
          blueAprs.activate();
          if (_blueAprsBeaconEnabled) {
            blueAprs.startBeacon(_blueAprsBeaconIntervalSec);
          }
        }
      } catch (_) {
        // BLE not available — ignore
      }
    }
  }

  /// Async initialization — runs after enable() returns.
  /// Uses the saved user-chosen position (guaranteed non-null by enable gate).
  Future<void> _initAsync(String callsign) async {
    final lat = _savedLat!;
    final lon = _savedLon!;

    // 1. Load cached packets FIRST so the UI has data immediately,
    //    filtered by saved position + radius.
    if (_cacheService != null) {
      try {
        final cached = await _cacheService!.loadPackets();
        // First pass: build position map from all cached position packets
        for (final pkt in cached) {
          if (pkt.hasPosition) {
            lastKnownPositions[pkt.fromCallsign] = (pkt.latitude!, pkt.longitude!);
          }
        }
        // Second pass: only load packets with known coordinates within radius
        for (final pkt in cached) {
          final double? pLat;
          final double? pLon;
          if (pkt.hasPosition) {
            pLat = pkt.latitude;
            pLon = pkt.longitude;
          } else {
            final known = lastKnownPositions[pkt.fromCallsign];
            pLat = known?.$1;
            pLon = known?.$2;
          }
          if (pLat == null || pLon == null) continue;
          final dist = _haversineKm(lat, lon, pLat, pLon);
          if (dist > _radiusKm) continue;
          if (pkt.type == AprsPacketType.message && pkt.messageText != null) {
            messages.add(pkt);
            _uiDirtyMessages = true;
          } else {
            streamPackets.add(pkt);
            _uiDirtyStream = true;
          }
          // Restore human geo-chat messages from cache (skip beacons)
          if (pkt.isHumanGeoChat) {
            geoChatMessages.add(pkt);
          }
        }
        LogService().log('AprsService: loaded ${streamPackets.length} stream + ${messages.length} messages from cache');
      } catch (e) {
        LogService().log('AprsService: cache load error: $e');
      }
    }

    // 2. Register GPS consumer for ongoing position updates.
    final locProvider = LocationProviderService();
    try {
      final dispose = await locProvider.registerConsumer(
        intervalSeconds: 120,
        onPosition: (pos) => _onPositionUpdate(pos),
      );
      _locationDispose = dispose;
    } catch (e) {
      LogService().log('AprsService: LocationProvider registration failed: $e');
    }

    // 3. Connect to APRS-IS with saved position.
    _client = AprsIsClient(
      callsign: callsign,
      latitude: lat,
      longitude: lon,
      radiusKm: _radiusKm,
    );
    _client!.connect();

    _lastFilterLat = lat;
    _lastFilterLon = lon;
    _lastFilterTime = DateTime.now();
  }

  /// Manually set location — persists to config and updates APRS-IS filter
  /// if connected. Can be called before enable() to set initial position.
  void setLocation(double lat, double lon) {
    _savedLat = lat;
    _savedLon = lon;
    _lastFilterLat = lat;
    _lastFilterLon = lon;
    _lastFilterTime = DateTime.now();
    _saveConfig();
    if (_client != null) {
      _client!.latitude = lat;
      _client!.longitude = lon;
      _client!.updateFilter(latitude: lat, longitude: lon);
      _clearPackets();
    }
    LogService().log('AprsService: location set to $lat, $lon');
  }

  /// Handle position update from LocationProviderService.
  void _onPositionUpdate(LockedPosition pos) {
    if (_client == null) return;

    final lat = pos.latitude;
    final lon = pos.longitude;

    // Always keep client coordinates fresh (used on reconnect)
    _client!.latitude = lat;
    _client!.longitude = lon;

    // Decide whether to send a filter update to APRS-IS
    final now = DateTime.now();
    bool shouldUpdate = false;

    if (_lastFilterTime == null) {
      shouldUpdate = true;
    } else {
      final elapsed = now.difference(_lastFilterTime!);
      if (elapsed >= _filterTimeThreshold) {
        shouldUpdate = true;
      } else if (_lastFilterLat != null && _lastFilterLon != null) {
        final dist = _haversineKm(
          _lastFilterLat!, _lastFilterLon!, lat, lon,
        );
        if (dist >= _filterDistanceThresholdKm) {
          shouldUpdate = true;
        }
      }
    }

    if (shouldUpdate) {
      _client!.updateFilter(latitude: lat, longitude: lon);
      _lastFilterLat = lat;
      _lastFilterLon = lon;
      _lastFilterTime = now;
    }
  }

  /// Disable APRS operations — disconnects from APRS-IS and unregisters GPS.
  void disable() {
    if (!_enabled) return;
    _enabled = false;
    BlueAprsService().deactivate();
    _stopUiTimer();
    _locationDispose?.call();
    _locationDispose = null;
    _client?.disconnect();
    _client = null;
    _recentPacketHashes.clear();
    _saveConfig();
    _eventController.add(const AprsEvent(AprsEventType.disconnected));
  }

  /// Clear in-memory packet lists and position cache.
  /// Called when location or radius changes so stale data doesn't linger.
  /// SQLite cache is preserved — only the display lists are wiped.
  void _clearPackets() {
    streamPackets.clear();
    messages.clear();
    geoChatMessages.clear();
    lastKnownPositions.clear();
    _recentPacketHashes.clear();
    _geoChatDedup.clear();
    _uiDirtyStream = true;
    _uiDirtyMessages = true;
  }

  /// Clear display lists only — dedup set is preserved so new packets
  /// aren't re-added, but the UI gets a fresh start.
  void clearDisplay() {
    streamPackets.clear();
    messages.clear();
    geoChatMessages.clear();
    lastKnownPositions.clear();
    _geoChatDedup.clear();
    _eventController.add(const AprsEvent(AprsEventType.packetReceived));
    _eventController.add(const AprsEvent(AprsEventType.messageReceived));
  }

  /// Clear geo-chat messages from the display list.
  void clearGeoChat() {
    geoChatMessages.clear();
    _geoChatDedup.clear();
    _eventController.add(const AprsEvent(AprsEventType.packetReceived));
  }

  /// Remove all messages (in-memory + cache). Stream/position packets are kept.
  Future<void> clearAllMessages() async {
    messages.clear();
    await _cacheService?.deleteAllMessages();
    _eventController.add(const AprsEvent(AprsEventType.messageReceived));
  }

  /// Remove messages for a specific conversation (in-memory + cache).
  Future<void> clearConversation(String conversationId) async {
    final isTag = conversationId.startsWith('#');
    final upper = conversationId.toUpperCase();
    final myCall = _callsign?.toUpperCase();

    if (isTag) {
      // Remove tag messages whose text starts with the tag
      messages.removeWhere((m) {
        final tag = m.messageTag;
        return tag != null && tag == conversationId.toLowerCase();
      });
    } else {
      // Remove direct messages involving this callsign
      messages.removeWhere((m) {
        final from = m.fromCallsign.toUpperCase();
        final addr = m.messageAddressee?.toUpperCase();
        final isToUs = addr == myCall && from == upper;
        final isFromUs = (from == myCall || m.isOutgoing) && addr == upper;
        return isToUs || isFromUs;
      });
      await _cacheService?.deleteByCallsign(conversationId);
    }

    _eventController.add(const AprsEvent(AprsEventType.messageReceived));
  }

  // ---------------------------------------------------------------------------
  // Conversation grouping
  // ---------------------------------------------------------------------------

  /// Build grouped conversation list from the messages list.
  /// Groups by: direct (messages where addressee == our callsign) keyed by
  /// other callsign, and tag (messages whose text starts with a subscribed #tag).
  List<AprsConversation> getConversations() {
    final myCall = _callsign?.toUpperCase();
    final directMap = <String, List<AprsPacket>>{};
    final tagMap = <String, List<AprsPacket>>{};

    for (final msg in messages) {
      final addressee = msg.messageAddressee?.toUpperCase();

      // Check if this is a message addressed to us (incoming) or sent by us (outgoing)
      final isToUs = addressee == myCall;
      final isFromUs = msg.fromCallsign.toUpperCase() == myCall || msg.isOutgoing;

      if (isToUs || isFromUs) {
        // Direct 1:1 conversation — key by the other party
        final otherParty = isFromUs
            ? (msg.messageAddressee ?? msg.toCallsign).toUpperCase()
            : msg.fromCallsign.toUpperCase();
        directMap.putIfAbsent(otherParty, () => []).add(msg);
        continue;
      }

      // Check for tag messages matching subscribed tags
      final tag = msg.messageTag;
      if (tag != null && _subscribedTags.contains(tag)) {
        tagMap.putIfAbsent(tag, () => []).add(msg);
      }
    }

    final conversations = <AprsConversation>[];

    // Build direct conversations
    for (final entry in directMap.entries) {
      final sorted = entry.value..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      conversations.add(AprsConversation(
        id: entry.key,
        type: AprsConversationType.direct,
        lastMessage: sorted.last,
        messageCount: sorted.length,
        partnerPosition: lastKnownPositions[entry.key],
      ));
    }

    // Build tag conversations (include subscribed tags even if empty)
    for (final tag in _subscribedTags) {
      final msgs = tagMap[tag] ?? [];
      final sorted = msgs..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      conversations.add(AprsConversation(
        id: tag,
        type: AprsConversationType.tag,
        lastMessage: sorted.isNotEmpty ? sorted.last : null,
        messageCount: sorted.length,
      ));
    }

    // Sort by most recent message timestamp (conversations with messages first)
    conversations.sort((a, b) {
      final aTime = a.lastMessageTime;
      final bTime = b.lastMessageTime;
      if (aTime == null && bTime == null) return a.id.compareTo(b.id);
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });

    return conversations;
  }

  /// Get messages for a specific conversation.
  List<AprsPacket> getConversationMessages(String conversationId) {
    final myCall = _callsign?.toUpperCase();
    final isTag = conversationId.startsWith('#');

    final result = <AprsPacket>[];
    for (final msg in messages) {
      if (isTag) {
        // Tag room: match messages with this tag
        if (msg.messageTag == conversationId) {
          result.add(msg);
        }
      } else {
        // Direct: messages between us and the other callsign
        final addressee = msg.messageAddressee?.toUpperCase();
        final from = msg.fromCallsign.toUpperCase();
        final otherUpper = conversationId.toUpperCase();

        final isToUs = addressee == myCall && from == otherUpper;
        final isFromUs = (from == myCall || msg.isOutgoing) && addressee == otherUpper;

        if (isToUs || isFromUs) {
          result.add(msg);
        }
      }
    }

    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return result;
  }

  // ---------------------------------------------------------------------------
  // Sending messages
  // ---------------------------------------------------------------------------

  /// Send an APRS message. Returns the first local echo packet, or null on
  /// failure. Long messages are automatically split into multiple packets.
  /// For tag rooms, [text] should NOT include the tag prefix — it's auto-prepended.
  AprsPacket? sendMessage(String destination, String text) {
    if (_client == null || _callsign == null) return null;

    final isTag = destination.startsWith('#');
    final maxChunkLen = aprsAvailableChars(isTag ? destination : null);
    final chunks = splitAprsText(text, maxChunkLen);

    final destPadded = isTag
        ? 'BLN9'.padRight(9) // Bulletin for tag messages
        : destination.toUpperCase().padRight(9);

    AprsPacket? firstEcho;

    for (final chunk in chunks) {
      final fullText = isTag ? '$destination $chunk' : chunk;
      final seqNo = '${_nextSeqNo++}';

      // Build TNC2 line: MYCALL>APRS::DEST_CALL :text{seqno
      final line = '${_callsign!}>APRS::$destPadded:$fullText{$seqNo';

      _client!.sendRaw(line);

      // Create local echo packet
      final echo = AprsPacket(
        fromCallsign: _callsign!,
        toCallsign: 'APRS',
        infoField: ':$destPadded:$fullText{$seqNo',
        rawTnc2: line,
        timestamp: DateTime.now().toUtc(),
        type: AprsPacketType.message,
        messageAddressee: destination.toUpperCase(),
        messageText: fullText,
        messageId: seqNo,
        isOutgoing: true,
      );

      messages.add(echo);
      _writeQueue.add(echo);
      firstEcho ??= echo;

      LogService().log('AprsService: sent message to $destination: $fullText');
    }

    if (_writeQueue.length >= _writeFlushThreshold) {
      _flushWrites();
    }

    // Emit event once for the whole batch
    _eventController.add(const AprsEvent(AprsEventType.messageReceived));

    return firstEcho;
  }

  // ---------------------------------------------------------------------------
  // Geo-chat (position report with comment)
  // ---------------------------------------------------------------------------

  /// Send a geo-chat message — a position report with comment text.
  /// Returns the local echo packet, or null on failure.
  AprsPacket? sendGeoChat(String text) {
    if (_client == null || _callsign == null) return null;
    final lat = _savedLat;
    final lon = _savedLon;
    if (lat == null || lon == null) return null;

    // Enforce max comment length after position block
    final trimmed = text.length > aprsMaxCommentLen
        ? text.substring(0, aprsMaxCommentLen)
        : text;

    // Build uncompressed APRS position: !DDMM.MMN/DDDMM.MMW$comment
    final latStr = _toAprsLat(lat);
    final lonStr = _toAprsLon(lon);
    final line = '${_callsign!}>APRS,TCPIP*:!$latStr/$lonStr\$$trimmed';

    _client!.sendRaw(line);

    // Create local echo
    final echo = AprsPacket(
      fromCallsign: _callsign!,
      toCallsign: 'APRS',
      infoField: '!$latStr/$lonStr\$$trimmed',
      rawTnc2: line,
      timestamp: DateTime.now().toUtc(),
      type: AprsPacketType.position,
      latitude: lat,
      longitude: lon,
      comment: trimmed,
      isOutgoing: true,
    );

    geoChatMessages.add(echo);
    if (geoChatMessages.length > _maxMessages) {
      geoChatMessages.removeRange(0, geoChatMessages.length - _maxMessages);
    }
    _writeQueue.add(echo);
    if (_writeQueue.length >= _writeFlushThreshold) {
      _flushWrites();
    }
    _uiDirtyMessages = true;

    LogService().log('AprsService: sent geo-chat: $trimmed');
    return echo;
  }

  /// Convert decimal latitude to APRS uncompressed format: DDMM.MMN
  static String _toAprsLat(double lat) {
    final hemi = lat >= 0 ? 'N' : 'S';
    final absLat = lat.abs();
    final deg = absLat.floor();
    final min = (absLat - deg) * 60;
    return '${deg.toString().padLeft(2, '0')}${min.toStringAsFixed(2).padLeft(5, '0')}$hemi';
  }

  /// Convert decimal longitude to APRS uncompressed format: DDDMM.MMW
  static String _toAprsLon(double lon) {
    final hemi = lon >= 0 ? 'E' : 'W';
    final absLon = lon.abs();
    final deg = absLon.floor();
    final min = (absLon - deg) * 60;
    return '${deg.toString().padLeft(3, '0')}${min.toStringAsFixed(2).padLeft(5, '0')}$hemi';
  }

  // ---------------------------------------------------------------------------
  // Packet ingestion with ACK handling
  // ---------------------------------------------------------------------------

  /// Add a packet — dedup, queue for persistence, classify, and append to
  /// the appropriate list. Sets dirty flags; the UI timer emits batched events.
  ///
  /// Packets without coordinates are dropped entirely — they bypass the
  /// radius filter and produce noise from distant stations.
  /// Exception: messages addressed to our callsign skip the position requirement.
  void addPacket(AprsPacket packet) {
    // Track last known position per callsign (before any filtering)
    if (packet.hasPosition) {
      lastKnownPositions[packet.fromCallsign] = (packet.latitude!, packet.longitude!);
    }

    final isMessage = packet.type == AprsPacketType.message && packet.messageText != null;
    final myCall = _callsign?.toUpperCase();
    final isAddressedToUs = isMessage &&
        packet.messageAddressee?.toUpperCase() == myCall;

    // Handle incoming ACKs — update matching sent message, don't display
    if (isMessage && packet.messageText != null &&
        packet.messageText!.startsWith('ack') && isAddressedToUs) {
      final ackedId = packet.messageText!.substring(3).trim();
      _handleIncomingAck(ackedId);
      return;
    }

    // Handle incoming rejection — same as ACK for display purposes
    if (isMessage && packet.messageText != null &&
        packet.messageText!.startsWith('rej') && isAddressedToUs) {
      return; // Just suppress from display
    }

    // Auto-ACK: when receiving a message addressed to us with a messageId
    if (isAddressedToUs && packet.messageId != null && _client != null) {
      final ackDest = packet.fromCallsign.toUpperCase().padRight(9);
      final ackLine = '${_callsign!}>APRS::$ackDest:ack${packet.messageId}';
      _client!.sendRaw(ackLine);
    }

    // Resolve coordinates: direct from packet, or last known for messages
    final double? lat;
    final double? lon;
    if (packet.hasPosition) {
      lat = packet.latitude;
      lon = packet.longitude;
    } else if (isMessage) {
      final known = lastKnownPositions[packet.fromCallsign];
      lat = known?.$1;
      lon = known?.$2;
    } else {
      lat = null;
      lon = null;
    }

    // Messages addressed to us skip the coordinate requirement
    if (!isAddressedToUs && (lat == null || lon == null)) return;

    // Dedup by callsign + info field — catches the same packet relayed
    // via different digipeater paths (different rawTnc2, same content).
    final dedupKey = '${packet.fromCallsign}\x00${packet.infoField}';
    if (_recentPacketHashes.contains(dedupKey)) return;
    _recentPacketHashes.add(dedupKey);
    if (_recentPacketHashes.length > _maxRecentHashes) {
      _recentPacketHashes.remove(_recentPacketHashes.first);
    }

    // Queue for batched SQLite write
    _writeQueue.add(packet);
    if (_writeQueue.length >= _writeFlushThreshold) {
      _flushWrites();
    }

    if (isMessage) {
      messages.add(packet);
      if (messages.length > _maxMessages) {
        messages.removeRange(0, messages.length - _maxMessages);
      }
      _uiDirtyMessages = true;

      // Fire NowItemEvent for incoming APRS messages (not outgoing, not ACK/REJ)
      if (!packet.isOutgoing) {
        final sourceId = packet.isTagMessage
            ? packet.messageTag!
            : packet.fromCallsign;
        final sourceName = packet.isTagMessage
            ? 'APRS ${packet.messageTag}'
            : 'APRS ${packet.fromCallsign}';
        final summary = packet.isTagMessage
            ? packet.messageBody ?? ''
            : packet.messageText ?? '';
        EventBus().fire(NowItemEvent(
          id: 'aprs:msg:${packet.fromCallsign}:${packet.timestamp.millisecondsSinceEpoch}',
          appType: 'aprs',
          sourceId: sourceId,
          sourceName: sourceName,
          callsign: packet.fromCallsign,
          summary: summary,
          priority: NowPriority.chat,
        ));
      }
    } else {
      streamPackets.add(packet);
      if (streamPackets.length > _maxStreamPackets) {
        streamPackets.removeRange(0, streamPackets.length - _maxStreamPackets);
      }
      _uiDirtyStream = true;
    }

    // Collect human-authored position comments for geo-chat (skip beacons)
    if (packet.isHumanGeoChat) {
      // Comment-based dedup: suppress identical comments from the same callsign
      // within a 1-hour window (GPS drift causes different coords but same text).
      final dedupKey = '${packet.fromCallsign}\x00${packet.comment ?? ''}';
      final now = DateTime.now();
      final prev = _geoChatDedup[dedupKey];
      if (prev != null && now.difference(prev) < _geoChatDedupWindow) {
        // Duplicate within window — skip
      } else {
        _geoChatDedup[dedupKey] = now;
        // Prune stale entries when map gets large
        if (_geoChatDedup.length > 500) {
          _geoChatDedup.removeWhere(
            (_, ts) => now.difference(ts) >= _geoChatDedupWindow,
          );
        }

        geoChatMessages.add(packet);
        if (geoChatMessages.length > _maxMessages) {
          geoChatMessages.removeRange(0, geoChatMessages.length - _maxMessages);
        }
        _uiDirtyMessages = true;

        // Fire NowItemEvent for incoming geo-chat
        if (!packet.isOutgoing) {
          EventBus().fire(NowItemEvent(
            id: 'aprs:geo:${packet.fromCallsign}:${packet.timestamp.millisecondsSinceEpoch}',
            appType: 'aprs',
            sourceId: 'geochat',
            sourceName: 'APRS Geo Chat',
            callsign: packet.fromCallsign,
            summary: packet.comment ?? '',
            priority: NowPriority.chat,
          ));
        }
      }
    }
  }

  /// Mark a sent message as acknowledged.
  void _handleIncomingAck(String messageId) {
    for (int i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      if (msg.isOutgoing && msg.messageId == messageId && !msg.isAcked) {
        messages[i] = msg.copyWith(isAcked: true);
        _uiDirtyMessages = true;
        LogService().log('AprsService: ACK received for message $messageId');
        return;
      }
    }
  }

  /// Flush the write queue to SQLite in a single transaction.
  Future<void> _flushWrites() async {
    if (_writeQueue.isEmpty || _cacheService == null) return;
    final batch = List<AprsPacket>.from(_writeQueue);
    _writeQueue.clear();
    await _cacheService!.cachePackets(batch);
  }

  // ---------------------------------------------------------------------------
  // UI throttle timer
  // ---------------------------------------------------------------------------

  void _startUiTimer() {
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = Timer.periodic(_uiUpdateInterval, _onUiTick);
    _writeTimer?.cancel();
    _writeTimer = Timer.periodic(_writeFlushInterval, (_) => _flushWrites());
  }

  void _stopUiTimer() {
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;
    _writeTimer?.cancel();
    _writeTimer = null;
    _flushWrites(); // flush remaining packets on disable
  }

  void _onUiTick(Timer _) {
    if (_uiDirtyStream) {
      _uiDirtyStream = false;
      _eventController.add(const AprsEvent(AprsEventType.packetReceived));
    }
    if (_uiDirtyMessages) {
      _uiDirtyMessages = false;
      _eventController.add(const AprsEvent(AprsEventType.messageReceived));
    }
  }

  // ---------------------------------------------------------------------------
  // Config persistence
  // ---------------------------------------------------------------------------

  Future<void> _saveConfig() async {
    await _cacheService?.saveConfig({
      'enabled': _enabled,
      'callsign': _callsign,
      'radiusKm': _radiusKm,
      'latitude': _savedLat,
      'longitude': _savedLon,
      'subscribedTags': _subscribedTags.toList(),
      'blueAprsEnabled': _blueAprsEnabled,
      'blueAprsBeaconEnabled': _blueAprsBeaconEnabled,
      'blueAprsBeaconIntervalSec': _blueAprsBeaconIntervalSec,
    });
  }

  // ---------------------------------------------------------------------------
  // Haversine
  // ---------------------------------------------------------------------------

  static double _haversineKm(
    double lat1, double lon1, double lat2, double lon2,
  ) {
    const earthRadius = 6371.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) * cos(_deg2rad(lat2)) *
        sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  static double _deg2rad(double deg) => deg * pi / 180;

  /// Dispose resources.
  void dispose() {
    _stopUiTimer();
    _locationDispose?.call();
    _locationDispose = null;
    _client?.disconnect();
    _client = null;
    _cacheService?.dispose();
    _cacheService = null;
    _eventController.close();
  }
}

/// Typedef for dispose callbacks (private to avoid conflict with Flutter's VoidCallback).
