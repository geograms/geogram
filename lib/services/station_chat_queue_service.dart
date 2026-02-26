import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/station_chat_room.dart';
import '../services/log_service.dart';
import '../services/station_cache_service.dart';
import '../services/station_service.dart';
import '../services/storage_config.dart';
import '../services/signing_service.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
import '../util/chat_format.dart';

class QueuedStationChatMessage {
  final String stationUrl;
  final String stationCallsign;
  final String roomId;
  final String callsign;
  final String content;
  final Map<String, String> metadata;
  final Map<String, dynamic> eventJson;
  final int retryCount;
  final DateTime queuedAt;
  final DateTime? nextAttemptAt;

  QueuedStationChatMessage({
    required this.stationUrl,
    required this.stationCallsign,
    required this.roomId,
    required this.callsign,
    required this.content,
    required this.metadata,
    required this.eventJson,
    required this.retryCount,
    required this.queuedAt,
    required this.nextAttemptAt,
  });

  factory QueuedStationChatMessage.fromJson(Map<String, dynamic> json) {
    return QueuedStationChatMessage(
      stationUrl: json['stationUrl'] as String? ?? '',
      stationCallsign: json['stationCallsign'] as String? ?? '',
      roomId: json['roomId'] as String? ?? '',
      callsign: json['callsign'] as String? ?? '',
      content: json['content'] as String? ?? '',
      metadata: (json['metadata'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          <String, String>{},
      eventJson: (json['eventJson'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
      retryCount: json['retryCount'] as int? ?? 0,
      queuedAt: DateTime.tryParse(json['queuedAt'] as String? ?? '') ?? DateTime.now().toUtc(),
      nextAttemptAt: json['nextAttemptAt'] != null
          ? DateTime.tryParse(json['nextAttemptAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'stationUrl': stationUrl,
        'stationCallsign': stationCallsign,
        'roomId': roomId,
        'callsign': callsign,
        'content': content,
        'metadata': metadata,
        'eventJson': eventJson,
        'retryCount': retryCount,
        'queuedAt': queuedAt.toUtc().toIso8601String(),
        if (nextAttemptAt != null) 'nextAttemptAt': nextAttemptAt!.toUtc().toIso8601String(),
      };
}

class StationChatQueueService {
  static final StationChatQueueService _instance = StationChatQueueService._internal();
  factory StationChatQueueService() => _instance;
  StationChatQueueService._internal();

  final StationService _stationService = StationService();
  final RelayCacheService _cacheService = RelayCacheService();

  Timer? _processingTimer;
  bool _initialized = false;
  bool _isProcessing = false;

  static const _processInterval = Duration(seconds: 15);
  static const _maxRetries = 10;
  static const _baseBackoffSeconds = 5;

  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      await storageConfig.init();
    }
    await _cacheService.initialize();
    _processingTimer = Timer.periodic(_processInterval, (_) => processQueue());
    _initialized = true;
    LogService().log('StationChatQueueService: Initialized');
  }

  Future<void> dispose() async {
    _processingTimer?.cancel();
    _processingTimer = null;
    _initialized = false;
  }

  Future<void> enqueue(QueuedStationChatMessage msg) async {
    if (kIsWeb) return;
    await initialize();
    final list = await _loadQueue(msg.stationCallsign);
    list.add(msg);
    await _saveQueue(msg.stationCallsign, list);
    // Try immediately instead of waiting for the next timer tick.
    unawaited(processQueue(stationCallsign: msg.stationCallsign));
  }

  Future<void> processQueue({String? stationCallsign}) async {
    if (kIsWeb) return;
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final callsigns = stationCallsign != null && stationCallsign.isNotEmpty
          ? <String>[stationCallsign]
          : await _getQueuedCallsigns();

      for (final callsign in callsigns) {
        final list = await _loadQueue(callsign);
        if (list.isEmpty) continue;

        final now = DateTime.now().toUtc();
        final updated = <QueuedStationChatMessage>[];
        for (final msg in list) {
          if (msg.nextAttemptAt != null && msg.nextAttemptAt!.isAfter(now)) {
            updated.add(msg);
            continue;
          }

          final sent = await _trySendQueuedMessage(msg);
          if (!sent) {
            final retries = msg.retryCount + 1;
            if (retries <= _maxRetries) {
              final backoffSeconds = _baseBackoffSeconds * (1 << (retries - 1));
              updated.add(QueuedStationChatMessage(
                stationUrl: msg.stationUrl,
                stationCallsign: msg.stationCallsign,
                roomId: msg.roomId,
                callsign: msg.callsign,
                content: msg.content,
                metadata: msg.metadata,
                eventJson: msg.eventJson,
                retryCount: retries,
                queuedAt: msg.queuedAt,
                nextAttemptAt: now.add(Duration(seconds: backoffSeconds)),
              ));
            } else {
              await _markQueuedMessageFailed(msg);
            }
          }
        }

        await _saveQueue(callsign, updated);
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<bool> _trySendQueuedMessage(QueuedStationChatMessage msg) async {
    try {
      final event = NostrEvent.fromJson(msg.eventJson);
      final metadata = _stripUnsignedStatusMetadata(msg.metadata);
      final sent = await _stationService.sendSignedChatEvent(
        msg.stationUrl,
        msg.roomId,
        msg.callsign,
        event,
        metadata: metadata,
      );

      if (sent) {
        // Update cache to remove pending status
        final timestamp = ChatFormat.epochToTimestamp(event.createdAt);
        final updatedMetadata = Map<String, String>.from(metadata);
        updatedMetadata['created_at'] = event.createdAt.toString();
        updatedMetadata['npub'] = NostrCrypto.encodeNpub(event.pubkey);
        updatedMetadata['signature'] = event.sig ?? updatedMetadata['signature'] ?? '';
        if (event.id != null) {
          updatedMetadata['event_id'] = event.id!;
        }

        final updated = StationChatMessage(
          roomId: msg.roomId,
          callsign: msg.callsign,
          content: msg.content,
          timestamp: timestamp,
          metadata: updatedMetadata,
          npub: updatedMetadata['npub'],
          signature: updatedMetadata['signature'],
          eventId: updatedMetadata['event_id'],
          createdAt: event.createdAt,
          hasSignature: true,
          verified: SigningService().verifyStationMessage(
            roomId: msg.roomId,
            callsign: msg.callsign,
            content: msg.content,
            timestamp: timestamp,
            metadata: updatedMetadata,
          ),
        );

        await _cacheService.mergeMessages(msg.stationCallsign, msg.roomId, [updated]);
      }

      return sent;
    } catch (e) {
      LogService().log('StationChatQueueService: Failed to send queued message: $e');
      return false;
    }
  }

  Future<void> _markQueuedMessageFailed(QueuedStationChatMessage msg) async {
    try {
      final event = NostrEvent.fromJson(msg.eventJson);
      final metadata = Map<String, String>.from(msg.metadata);
      metadata['status'] = 'failed';
      metadata['retry_count'] = (msg.retryCount + 1).toString();
      metadata['queued_at'] = msg.queuedAt.toUtc().toIso8601String();
      metadata['created_at'] = event.createdAt.toString();
      metadata['npub'] = NostrCrypto.encodeNpub(event.pubkey);
      if (event.sig != null) {
        metadata['signature'] = event.sig!;
      }
      if (event.id != null) {
        metadata['event_id'] = event.id!;
      }

      final timestamp = ChatFormat.epochToTimestamp(event.createdAt);
      final failed = StationChatMessage(
        roomId: msg.roomId,
        callsign: msg.callsign,
        content: msg.content,
        timestamp: timestamp,
        metadata: metadata,
        npub: metadata['npub'],
        signature: metadata['signature'],
        eventId: metadata['event_id'],
        createdAt: event.createdAt,
        hasSignature: true,
        verified: SigningService().verifyStationMessage(
          roomId: msg.roomId,
          callsign: msg.callsign,
          content: msg.content,
          timestamp: timestamp,
          metadata: metadata,
        ),
      );
      await _cacheService.mergeMessages(msg.stationCallsign, msg.roomId, [failed]);
    } catch (e) {
      LogService().log('StationChatQueueService: Failed to mark message failed: $e');
    }
  }

  Map<String, String> _stripUnsignedStatusMetadata(Map<String, String> metadata) {
    final cleaned = Map<String, String>.from(metadata);
    cleaned.remove('status');
    cleaned.remove('delivery_state');
    cleaned.remove('retry_count');
    cleaned.remove('queued_at');
    return cleaned;
  }

  Future<List<String>> _getQueuedCallsigns() async {
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) return [];
    final base = storageConfig.devicesDir;
    final dir = Directory(base);
    if (!await dir.exists()) return [];

    final entities = await dir.list().toList();
    final callsigns = <String>[];
    for (final entity in entities) {
      if (entity is Directory) {
        final name = entity.path.split('/').last;
        callsigns.add(name);
      }
    }
    return callsigns;
  }

  Future<File> _queueFile(String callsign) async {
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      await storageConfig.init();
    }
    final base = storageConfig.devicesDir;
    final dir = Directory('$base/$callsign/chat');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/_pending.json');
  }

  Future<List<QueuedStationChatMessage>> _loadQueue(String callsign) async {
    try {
      final file = await _queueFile(callsign);
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      if (content.trim().isEmpty) return [];
      final data = jsonDecode(content) as List<dynamic>;
      return data.map((e) => QueuedStationChatMessage.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      LogService().log('StationChatQueueService: Failed to load queue: $e');
      return [];
    }
  }

  Future<void> _saveQueue(String callsign, List<QueuedStationChatMessage> list) async {
    try {
      final file = await _queueFile(callsign);
      final content = const JsonEncoder.withIndent('  ').convert(
        list.map((e) => e.toJson()).toList(),
      );
      await file.writeAsString(content);
    } catch (e) {
      LogService().log('StationChatQueueService: Failed to save queue: $e');
    }
  }
}
