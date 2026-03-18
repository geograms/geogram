/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import '../connection/connection_manager.dart';
import '../models/chat_message.dart';
import '../models/monitored_task.dart';
import '../util/event_bus.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import 'direct_message_service.dart';
import 'log_service.dart';
import 'storage_config.dart';
import 'profile_storage.dart';
import '../util/task_monitor_helpers.dart';

/// Background queue processor for DM message delivery
///
/// Implements optimistic UI pattern:
/// 1. Messages are saved immediately with 'pending' status
/// 2. Background queue processes deliveries with Timer.periodic
/// 3. Tries WebRTC first (30s timeout), falls back to Station
/// 4. Fires status events for UI updates
class DMQueueService {
  static final DMQueueService _instance = DMQueueService._internal();
  factory DMQueueService() => _instance;
  DMQueueService._internal();

  MonitoredAsyncPeriodicTimer? _processingTimer;
  bool _isProcessing = false;
  bool _initialized = false;

  static const _processInterval = Duration(seconds: 10);
  static const _maxRetries = 10;
  static const _webrtcTimeout = Duration(seconds: 30);

  /// Retry tracking per message (messageId -> retry count)
  final Map<String, int> _retryCount = {};

  /// Next retry time per message (messageId -> next retry time)
  final Map<String, DateTime> _nextRetryTime = {};

  /// Backoff factor for exponential backoff (base 2)
  static const _backoffBaseSeconds = 3;

  /// Profile storage for queue file operations
  ProfileStorage? _storage;

  /// Initialize the service and start background processing
  Future<void> initialize() async {
    if (_initialized) return;

    LogService().log('DMQueueService: Initializing...');

    // Initialize storage from StorageConfig
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      await storageConfig.init();
    }
    _storage = FilesystemProfileStorage(storageConfig.chatDir);

    // Register callback with DirectMessageService to enable optimistic UI
    DirectMessageService().onTriggerBackgroundDelivery = processQueue;

    // Start periodic queue processing
    _processingTimer = MonitoredAsyncPeriodicTimer(
      id: 'dm_queue.process',
      name: 'DM Queue',
      description: 'Delivers queued direct messages',
      serviceName: 'DMQueueService',
      interval: _processInterval,
      priority: TaskPriority.normal,
      callback: (_) async => await processQueue(),
    );

    _initialized = true;
    LogService().log('DMQueueService: Initialized with ${_processInterval.inSeconds}s interval');
  }

  /// Dispose resources
  Future<void> dispose() async {
    _processingTimer?.cancel();
    _processingTimer = null;
    _initialized = false;
    LogService().log('DMQueueService: Disposed');
  }

  /// Trigger immediate queue processing (called after queueing new message)
  Future<void> processQueue() async {
    if (_isProcessing) {
      LogService().log('DMQueueService: Already processing, skipping');
      return;
    }
    if (_storage == null) {
      LogService().log('DMQueueService: Not initialized, skipping');
      return;
    }

    _isProcessing = true;

    try {
      LogService().log('DMQueueService: Processing queue...');

      // Get list of all callsigns with potential queued messages
      final callsigns = await _getCallsignsWithQueuedMessages();

      if (callsigns.isEmpty) {
        LogService().log('DMQueueService: No queued messages found');
        return;
      }

      LogService().log('DMQueueService: Found ${callsigns.length} conversations with queued messages');

      for (final callsign in callsigns) {
        await _processCallsignQueue(callsign);
      }
    } catch (e) {
      LogService().log('DMQueueService: Error processing queue: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Get list of callsigns that have queued messages
  Future<List<String>> _getCallsignsWithQueuedMessages() async {
    final callsigns = <String>[];

    try {
      if (!await _storage!.directoryExists('')) return callsigns;

      final entries = await _storage!.listDirectory('');
      for (final entry in entries) {
        if (entry.isDirectory) {
          // Check if this directory has a queue.txt file
          final queuePath = '${entry.name}/queue.txt';
          if (await _storage!.exists(queuePath)) {
            final content = await _storage!.readString(queuePath);
            if (content != null && content.trim().isNotEmpty) {
              callsigns.add(entry.name);
            }
          }
        }
      }
    } catch (e) {
      LogService().log('DMQueueService: Error listing queue directories: $e');
    }

    return callsigns;
  }

  /// Process queued messages for a specific callsign
  Future<void> _processCallsignQueue(String callsign) async {
    final dmService = DirectMessageService();
    final queuedMessages = await dmService.loadQueuedMessages(callsign);

    if (queuedMessages.isEmpty) return;

    LogService().log('DMQueueService: Processing ${queuedMessages.length} messages for $callsign');

    for (final message in queuedMessages) {
      final messageId = '${message.timestamp}|${message.author}';

      // Check if we should retry yet (exponential backoff)
      final nextRetry = _nextRetryTime[messageId];
      if (nextRetry != null && DateTime.now().isBefore(nextRetry)) {
        LogService().log('DMQueueService: Skipping $messageId - waiting for backoff');
        continue;
      }

      // Check retry limit
      final retries = _retryCount[messageId] ?? 0;
      if (retries >= _maxRetries) {
        LogService().log('DMQueueService: Message $messageId exceeded max retries, marking as failed');
        await _updateMessageStatus(callsign, message, MessageStatus.failed, error: 'Max retries exceeded');
        continue;
      }

      // Try to deliver
      final success = await _deliverMessage(callsign, message);

      if (success) {
        // Clear retry tracking
        _retryCount.remove(messageId);
        _nextRetryTime.remove(messageId);
      } else {
        // Increment retry counter and set next retry time with exponential backoff
        _retryCount[messageId] = retries + 1;
        final backoffSeconds = _backoffBaseSeconds * (1 << retries); // 2^retries
        _nextRetryTime[messageId] = DateTime.now().add(Duration(seconds: backoffSeconds));

        LogService().log('DMQueueService: Delivery failed for $messageId, '
            'retry ${retries + 1}/$_maxRetries, next attempt in ${backoffSeconds}s');
      }
    }
  }

  /// Deliver a single message using ConnectionManager
  /// Returns true on success, false to retry later
  Future<bool> _deliverMessage(String callsign, ChatMessage message) async {
    final connectionManager = ConnectionManager();

    // Fire status update: delivering
    _fireStatusEvent(callsign, message, MessageStatus.pending, info: 'Delivering...');

    try {
      // Rebuild signed event from message metadata
      final signedEvent = _rebuildSignedEventFromMessage(message, callsign);

      if (signedEvent == null) {
        LogService().log('DMQueueService: Cannot rebuild signed event for ${message.timestamp}');
        await _updateMessageStatus(callsign, message, MessageStatus.failed, error: 'Missing signature data');
        return false;
      }

      LogService().log('DMQueueService: Delivering to $callsign via ConnectionManager');

      // Try delivery via ConnectionManager (handles transport selection)
      // ConnectionManager will try WebRTC first (if available), then Station
      final result = await connectionManager.sendDM(
        callsign: callsign,
        signedEvent: signedEvent.toJson(),
        ttl: _webrtcTimeout,
      );

      if (result.success) {
        LogService().log('DMQueueService: Message delivered via ${result.transportUsed}');
        await _updateMessageStatus(callsign, message, MessageStatus.delivered,
            transportUsed: result.transportUsed);
        return true;
      } else {
        LogService().log('DMQueueService: Delivery failed: ${result.error}');
        // Don't mark as failed yet - will retry
        return false;
      }
    } catch (e) {
      LogService().log('DMQueueService: Delivery error: $e');
      return false;
    }
  }

  /// Rebuild a NostrEvent from stored message metadata
  NostrEvent? _rebuildSignedEventFromMessage(ChatMessage message, String roomId) {
    final npub = message.npub;
    final signature = message.signature;
    final eventId = message.getMeta('eventId');
    final createdAtStr = message.getMeta('created_at');

    if (npub == null || signature == null || eventId == null || createdAtStr == null) {
      LogService().log('DMQueueService: Cannot rebuild event - missing metadata '
          '(npub=${npub != null}, sig=${signature != null}, id=${eventId != null}, created_at=${createdAtStr != null})');
      return null;
    }

    final pubkeyHex = NostrCrypto.decodeNpub(npub);
    final createdAt = int.parse(createdAtStr);

    // Rebuild tags - include file metadata if present
    final tags = <List<String>>[
      ['t', 'chat'],
      ['room', roomId],
      ['callsign', message.author],
    ];

    // Add file-related tags if this is a file message
    if (message.hasFile) {
      if (message.getMeta('file') != null) {
        tags.add(['file', message.getMeta('file')!]);
      }
      if (message.getMeta('file_size') != null) {
        tags.add(['file_size', message.getMeta('file_size')!]);
      }
      if (message.getMeta('file_name') != null) {
        tags.add(['file_name', message.getMeta('file_name')!]);
      }
      if (message.getMeta('sha1') != null) {
        tags.add(['sha1', message.getMeta('sha1')!]);
      }
    }

    // Add voice-related tags if this is a voice message
    if (message.hasVoice) {
      if (message.voiceFile != null) {
        tags.add(['voice', message.voiceFile!]);
      }
      if (message.voiceDuration != null) {
        tags.add(['duration', message.voiceDuration.toString()]);
      }
      if (message.voiceSha1 != null) {
        tags.add(['sha1', message.voiceSha1!]);
      }
    }

    return NostrEvent(
      id: eventId,
      pubkey: pubkeyHex,
      createdAt: createdAt,
      kind: 1,
      tags: tags,
      content: message.content,
      sig: signature,
    );
  }

  /// Update message status and fire event
  Future<void> _updateMessageStatus(
    String callsign,
    ChatMessage message,
    MessageStatus status, {
    String? transportUsed,
    String? error,
  }) async {
    final dmService = DirectMessageService();

    // Update status in message
    message.setDeliveryStatus(status);

    if (status == MessageStatus.delivered) {
      // Save FIRST - ensures message persists even if removal fails
      await dmService.saveIncomingMessage(callsign, message);

      // Remove from queue AFTER successful save
      await _removeFromQueue(callsign, message.timestamp);

      // Invalidate cache to force reload with signature re-verification.
      // The queue-loaded message lacks 'verified' metadata (excluded from text format),
      // so incremental cache update would flash "unverified". Full reload re-verifies.
      dmService.invalidateMessageCache(callsign);

      // Fire delivered event for backward compatibility
      EventBus().fire(DMMessageDeliveredEvent(
        callsign: callsign,
        messageTimestamp: message.timestamp,
      ));
    } else if (status == MessageStatus.failed) {
      // Update the status in the queue file
      await _updateQueueMessageStatus(callsign, message.timestamp, status);
    }

    // Fire status changed event
    _fireStatusEvent(callsign, message, status,
        transportUsed: transportUsed, error: error);
  }

  /// Fire DMMessageStatusChangedEvent
  void _fireStatusEvent(
    String callsign,
    ChatMessage message,
    MessageStatus status, {
    String? transportUsed,
    String? error,
    String? info,
  }) {
    final messageId = '${message.timestamp}|${message.author}';

    EventBus().fire(DMMessageStatusChangedEvent(
      callsign: callsign,
      messageId: messageId,
      newStatus: status,
      transportUsed: transportUsed,
      error: error,
    ));
  }

  /// Remove a message from queue after successful delivery
  Future<void> _removeFromQueue(String callsign, String timestamp) async {
    final dmService = DirectMessageService();
    final queuedMessages = await dmService.loadQueuedMessages(callsign);
    final remaining = queuedMessages.where((m) => m.timestamp != timestamp).toList();

    if (remaining.isEmpty) {
      // Delete queue file if empty
      final queuePath = '${callsign.toUpperCase()}/queue.txt';
      if (await _storage!.exists(queuePath)) {
        await _storage!.delete(queuePath);
      }
    } else {
      // Rewrite queue with remaining messages
      await _rewriteQueue(callsign, remaining);
    }
  }

  /// Update status of a specific message in queue file
  Future<void> _updateQueueMessageStatus(String callsign, String timestamp, MessageStatus status) async {
    final dmService = DirectMessageService();
    final queuedMessages = await dmService.loadQueuedMessages(callsign);

    for (final msg in queuedMessages) {
      if (msg.timestamp == timestamp) {
        msg.setDeliveryStatus(status);
        break;
      }
    }

    await _rewriteQueue(callsign, queuedMessages);
  }

  /// Rewrite queue file with messages
  Future<void> _rewriteQueue(String callsign, List<ChatMessage> messages) async {
    final queuePath = '${callsign.toUpperCase()}/queue.txt';

    final buffer = StringBuffer();
    for (final message in messages) {
      buffer.write('\n');
      buffer.write(message.exportAsText());
      buffer.write('\n');
    }

    await _storage!.writeString(queuePath, buffer.toString());
  }

  /// Check if there are any messages queued for a callsign
  Future<bool> hasQueuedMessages(String callsign) async {
    if (_storage == null) return false;

    final queuePath = '${callsign.toUpperCase()}/queue.txt';
    if (!await _storage!.exists(queuePath)) return false;

    final content = await _storage!.readString(queuePath);
    return content != null && content.trim().isNotEmpty;
  }

  /// Get count of queued messages for a callsign
  Future<int> getQueuedMessageCount(String callsign) async {
    final dmService = DirectMessageService();
    final messages = await dmService.loadQueuedMessages(callsign);
    return messages.length;
  }
}
