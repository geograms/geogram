/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Event Bus - Simple event-driven communication for CLI and GUI
 */

import 'dart:async';

import '../models/chat_message.dart' show MessageStatus;

/// Base class for all events
abstract class AppEvent {
  final DateTime timestamp;

  AppEvent() : timestamp = DateTime.now();
}

/// Event subscription handle for unsubscribing
class EventSubscription<T extends AppEvent> {
  final StreamSubscription<T> _subscription;

  EventSubscription(this._subscription);

  void cancel() => _subscription.cancel();
}

/// Global event bus for app-wide event communication
class EventBus {
  static final EventBus _instance = EventBus._internal();

  factory EventBus() => _instance;

  EventBus._internal();

  /// Stream controllers for each event type
  final Map<Type, StreamController<dynamic>> _controllers = {};

  /// Get or create a stream controller for an event type
  StreamController<T> _getController<T extends AppEvent>() {
    return _controllers.putIfAbsent(T, () => StreamController<T>.broadcast())
        as StreamController<T>;
  }

  /// Subscribe to events of type T
  /// Returns a subscription handle that can be used to unsubscribe
  EventSubscription<T> on<T extends AppEvent>(void Function(T event) handler) {
    final controller = _getController<T>();
    final subscription = controller.stream.listen(handler);
    return EventSubscription<T>(subscription);
  }

  /// Fire an event to all subscribers
  void fire<T extends AppEvent>(T event) {
    final controller = _controllers[T];
    if (controller != null && !controller.isClosed) {
      controller.add(event);
    }
  }

  /// Check if there are any subscribers for an event type
  bool hasSubscribers<T extends AppEvent>() {
    final controller = _controllers[T];
    return controller != null && controller.hasListener;
  }

  /// Clear all subscriptions (useful for testing or cleanup)
  void reset() {
    for (final controller in _controllers.values) {
      controller.close();
    }
    _controllers.clear();
  }
}

// ============================================================
// Common Application Events
// ============================================================

/// Wapp module event bridged from WASM event bus
class WappEventBridgeEvent extends AppEvent {
  final String moduleId;
  final String topic;
  final String data;

  WappEventBridgeEvent({
    required this.moduleId,
    required this.topic,
    required this.data,
  });

  @override
  String toString() =>
      'WappEventBridgeEvent(module: $moduleId, topic: $topic)';
}

/// Chat message received
class ChatMessageEvent extends AppEvent {
  final String roomId;
  final String callsign;
  final String content;
  final String? npub;
  final String? signature;
  final bool verified;

  ChatMessageEvent({
    required this.roomId,
    required this.callsign,
    required this.content,
    this.npub,
    this.signature,
    this.verified = false,
  });
}

/// Chat room created
class ChatRoomCreatedEvent extends AppEvent {
  final String roomId;
  final String name;
  final String creatorCallsign;

  ChatRoomCreatedEvent({
    required this.roomId,
    required this.name,
    required this.creatorCallsign,
  });
}

/// Chat room deleted
class ChatRoomDeletedEvent extends AppEvent {
  final String roomId;

  ChatRoomDeletedEvent({required this.roomId});
}

/// Client connected to station
class ClientConnectedEvent extends AppEvent {
  final String clientId;
  final String? callsign;
  final String? npub;

  ClientConnectedEvent({required this.clientId, this.callsign, this.npub});
}

/// Client disconnected from station
class ClientDisconnectedEvent extends AppEvent {
  final String clientId;
  final String? callsign;

  ClientDisconnectedEvent({required this.clientId, this.callsign});
}

/// Station server started
class StationStartedEvent extends AppEvent {
  final int httpPort;
  final int? httpsPort;
  final String callsign;

  StationStartedEvent({
    required this.httpPort,
    this.httpsPort,
    required this.callsign,
  });
}

/// Station server stopped
class StationStoppedEvent extends AppEvent {}

/// Profile changed
class ProfileChangedEvent extends AppEvent {
  final String callsign;
  final String npub;

  ProfileChangedEvent({required this.callsign, required this.npub});
}

/// App updated (tiles, files, etc.)
class AppUpdatedEvent extends AppEvent {
  final String appType; // 'tiles', 'files', 'audio', etc.
  final String? path;

  AppUpdatedEvent({required this.appType, this.path});
}

/// Error event for global error handling
class ErrorEvent extends AppEvent {
  final String message;
  final String? source;
  final Object? error;
  final StackTrace? stackTrace;

  ErrorEvent({required this.message, this.source, this.error, this.stackTrace});
}

/// Status update event for UI feedback
class StatusUpdateEvent extends AppEvent {
  final String message;
  final StatusType type;

  StatusUpdateEvent({required this.message, this.type = StatusType.info});
}

enum StatusType { info, success, warning, error }

/// Alert received from a device
class AlertReceivedEvent extends AppEvent {
  final String eventId;
  final String senderCallsign;
  final String senderNpub;
  final String folderName;
  final double latitude;
  final double longitude;
  final String severity;
  final String status;
  final String type;
  final String content;
  final bool verified;

  AlertReceivedEvent({
    required this.eventId,
    required this.senderCallsign,
    required this.senderNpub,
    required this.folderName,
    required this.latitude,
    required this.longitude,
    required this.severity,
    required this.status,
    required this.type,
    required this.content,
    this.verified = false,
  });
}

/// Direct message received (1:1 private chat)
class DirectMessageReceivedEvent extends AppEvent {
  final String fromCallsign; // Sender's callsign
  final String toCallsign; // Recipient's callsign (local user)
  final String content; // Message content
  final String messageTimestamp; // Message timestamp (YYYY-MM-DD HH:MM_ss)
  final String? npub; // Sender's NOSTR public key
  final String? signature; // NOSTR signature
  final bool verified; // Signature verification status
  final bool fromSync; // True if received via sync, false if local

  DirectMessageReceivedEvent({
    required this.fromCallsign,
    required this.toCallsign,
    required this.content,
    required this.messageTimestamp,
    this.npub,
    this.signature,
    this.verified = false,
    this.fromSync = false,
  });
}

/// DM notification tapped (user tapped on notification)
class DMNotificationTappedEvent extends AppEvent {
  final String targetCallsign; // The callsign to open DM conversation with

  DMNotificationTappedEvent({required this.targetCallsign});
}

/// Email notification tapped (user tapped on an email notification)
class EmailNotificationTappedEvent extends AppEvent {
  final String threadId;

  EmailNotificationTappedEvent({required this.threadId});
}

/// Chat room notification tapped (user tapped on a chat room notification)
class ChatNotificationTappedEvent extends AppEvent {
  final String roomId;

  ChatNotificationTappedEvent({required this.roomId});
}

/// Direct message sync completed
class DirectMessageSyncEvent extends AppEvent {
  final String otherCallsign; // The callsign we synced with
  final int newMessages; // Number of new messages received
  final int sentMessages; // Number of messages sent to other device
  final bool success; // Whether sync completed successfully
  final String? error; // Error message if failed

  DirectMessageSyncEvent({
    required this.otherCallsign,
    required this.newMessages,
    required this.sentMessages,
    required this.success,
    this.error,
  });
}

/// Queued DM message was successfully delivered
/// Fired when a message from the offline queue has been sent
class DMMessageDeliveredEvent extends AppEvent {
  final String callsign; // The recipient's callsign
  final String messageTimestamp; // The message timestamp (unique identifier)

  DMMessageDeliveredEvent({
    required this.callsign,
    required this.messageTimestamp,
  });
}

/// DM message status changed (pending -> delivered/failed)
/// Fired by DMQueueService during background delivery attempts
class DMMessageStatusChangedEvent extends AppEvent {
  final String callsign; // The recipient's callsign
  final String messageId; // timestamp|author for identification
  final MessageStatus newStatus; // New status (pending, delivered, failed)
  final String?
  transportUsed; // Transport used for delivery (webrtc, station, etc.)
  final String? error; // Error message if failed

  DMMessageStatusChangedEvent({
    required this.callsign,
    required this.messageId,
    required this.newStatus,
    this.transportUsed,
    this.error,
  });

  @override
  String toString() =>
      'DMMessageStatusChangedEvent(callsign: $callsign, messageId: $messageId, status: ${newStatus.name})';
}

/// Connection type for ConnectionStateChangedEvent
enum ConnectionType {
  @Deprecated('No longer fired - services check their own endpoints instead')
  internet, // Was: general internet connectivity (no longer used)
  station, // Station relay connection (WebSocket to p2p.radio)
  lan, // Local network connection (WiFi/Ethernet with private IP)
  bluetooth, // Bluetooth Low Energy connection
}

/// Connection state changed event
/// Fired when a connection type becomes available or unavailable
class ConnectionStateChangedEvent extends AppEvent {
  final ConnectionType connectionType;
  final bool isConnected;
  final String? stationUrl; // For station: the URL connected to
  final String? stationCallsign; // For station: the station's callsign

  ConnectionStateChangedEvent({
    required this.connectionType,
    required this.isConnected,
    this.stationUrl,
    this.stationCallsign,
  });

  @override
  String toString() =>
      'ConnectionStateChangedEvent(type: $connectionType, connected: $isConnected)';
}

/// BLE status types for UI notifications
enum BLEStatusType {
  scanning, // BLE scan started
  scanComplete, // BLE scan completed
  deviceFound, // New BLE device discovered
  advertising, // BLE advertising started
  connecting, // Connecting to a BLE device
  connected, // Connected to a BLE device
  disconnected, // Disconnected from a BLE device
  sending, // Sending data via BLE
  received, // Received data via BLE
  error, // BLE error occurred
}

/// BLE status event for UI notifications
/// Use this to show snackbars/toasts when BLE events occur
class BLEStatusEvent extends AppEvent {
  final BLEStatusType status;
  final String? message;
  final String? deviceCallsign;
  final String? errorDetail;

  BLEStatusEvent({
    required this.status,
    this.message,
    this.deviceCallsign,
    this.errorDetail,
  });

  @override
  String toString() => 'BLEStatusEvent(status: $status, message: $message)';
}

/// Chat messages loaded event
/// Fired when messages are loaded from cache or server, used to trigger scroll to bottom
class ChatMessagesLoadedEvent extends AppEvent {
  final String? roomId;
  final int messageCount;

  ChatMessagesLoadedEvent({this.roomId, required this.messageCount});
}

// ============================================================
// Backup Events
// ============================================================

enum BackupEventType {
  backupStarted,
  backupCompleted,
  backupFailed,
  restoreStarted,
  restoreCompleted,
  restoreFailed,
  inviteReceived,
  inviteAccepted,
  inviteDeclined,
  snapshotNoteUpdated,
}

/// Backup lifecycle and relationship events
class BackupEvent extends AppEvent {
  final BackupEventType type;
  final String role; // 'client' or 'provider'
  final String? counterpartCallsign;
  final String? snapshotId;
  final String? message;
  final int? totalFiles;
  final int? totalBytes;

  BackupEvent({
    required this.type,
    required this.role,
    this.counterpartCallsign,
    this.snapshotId,
    this.message,
    this.totalFiles,
    this.totalBytes,
  });
}

// ============================================================
// Transfer Events
// ============================================================

/// Transfer direction for events
enum TransferEventDirection { upload, download, stream }

/// Transfer requested event - fired when a new transfer is queued
class TransferRequestedEvent extends AppEvent {
  final String transferId;
  final TransferEventDirection direction;
  final String callsign;
  final String path;
  final String? requestingApp;

  TransferRequestedEvent({
    required this.transferId,
    required this.direction,
    required this.callsign,
    required this.path,
    this.requestingApp,
  });

  @override
  String toString() =>
      'TransferRequestedEvent(id: $transferId, direction: $direction, callsign: $callsign)';
}

/// Transfer progress update event
class TransferProgressEvent extends AppEvent {
  final String transferId;
  final String status;
  final int bytesTransferred;
  final int totalBytes;
  final double? speedBytesPerSecond;
  final Duration? eta;

  TransferProgressEvent({
    required this.transferId,
    required this.status,
    required this.bytesTransferred,
    required this.totalBytes,
    this.speedBytesPerSecond,
    this.eta,
  });

  double get progressPercent =>
      totalBytes > 0 ? (bytesTransferred / totalBytes * 100) : 0;

  @override
  String toString() =>
      'TransferProgressEvent(id: $transferId, progress: ${progressPercent.toStringAsFixed(1)}%)';
}

/// Transfer completed successfully
class TransferCompletedEvent extends AppEvent {
  final String transferId;
  final TransferEventDirection direction;
  final String callsign;
  final String localPath;
  final int totalBytes;
  final Duration duration;
  final String transportUsed;
  final String? requestingApp;
  final Map<String, dynamic>? metadata;

  TransferCompletedEvent({
    required this.transferId,
    required this.direction,
    required this.callsign,
    required this.localPath,
    required this.totalBytes,
    required this.duration,
    required this.transportUsed,
    this.requestingApp,
    this.metadata,
  });

  @override
  String toString() =>
      'TransferCompletedEvent(id: $transferId, callsign: $callsign, bytes: $totalBytes)';
}

/// Transfer failed
class TransferFailedEvent extends AppEvent {
  final String transferId;
  final TransferEventDirection direction;
  final String callsign;
  final String path;
  final String error;
  final bool willRetry;
  final DateTime? nextRetryAt;
  final String? requestingApp;

  TransferFailedEvent({
    required this.transferId,
    required this.direction,
    required this.callsign,
    required this.path,
    required this.error,
    required this.willRetry,
    this.nextRetryAt,
    this.requestingApp,
  });

  @override
  String toString() =>
      'TransferFailedEvent(id: $transferId, error: $error, willRetry: $willRetry)';
}

/// Transfer cancelled by user
class TransferCancelledEvent extends AppEvent {
  final String transferId;
  final String? requestingApp;

  TransferCancelledEvent({required this.transferId, this.requestingApp});

  @override
  String toString() => 'TransferCancelledEvent(id: $transferId)';
}

/// Transfer paused by user
class TransferPausedEvent extends AppEvent {
  final String transferId;

  TransferPausedEvent({required this.transferId});

  @override
  String toString() => 'TransferPausedEvent(id: $transferId)';
}

/// Transfer resumed by user
class TransferResumedEvent extends AppEvent {
  final String transferId;

  TransferResumedEvent({required this.transferId});

  @override
  String toString() => 'TransferResumedEvent(id: $transferId)';
}

/// Navigate to home/apps tab
class NavigateToHomeEvent extends AppEvent {}

/// Navigate to devices panel (e.g., from summary notification tap)
class NavigateToDevicesEvent extends AppEvent {}

/// Mirror pairing completed on device B (receiver side)
class MirrorPairCompletedEvent extends AppEvent {
  final String peerCallsign;
  MirrorPairCompletedEvent({required this.peerCallsign});
}

// ============================================================
// Email Events
// ============================================================

/// Email notification event for delivery status updates
/// Fired by EmailService when DSN (Delivery Status Notification) is received
class EmailNotificationEvent extends AppEvent {
  final String message;
  final String action; // 'delivered', 'failed', 'pending_approval', 'delayed'
  final String? threadId;
  final String? recipient;

  EmailNotificationEvent({
    required this.message,
    required this.action,
    this.threadId,
    this.recipient,
  });

  @override
  String toString() =>
      'EmailNotificationEvent(action: $action, message: $message)';
}

// ============================================================
// Location Events
// ============================================================

/// Chat file download progress event
/// Fired by ChatFileDownloadManager when download state changes
class ChatDownloadProgressEvent extends AppEvent {
  final String downloadId;
  final int bytesTransferred;
  final int totalBytes;
  final double? speedBytesPerSecond;
  final String status; // 'idle', 'downloading', 'paused', 'completed', 'failed'

  ChatDownloadProgressEvent({
    required this.downloadId,
    required this.bytesTransferred,
    required this.totalBytes,
    this.speedBytesPerSecond,
    required dynamic status,
  }) : status = status.toString().split('.').last;

  double get progressPercent =>
      totalBytes > 0 ? (bytesTransferred / totalBytes * 100) : 0;

  @override
  String toString() =>
      'ChatDownloadProgressEvent(id: $downloadId, progress: ${progressPercent.toStringAsFixed(1)}%, status: $status)';
}

/// Chat file upload progress event
/// Fired by ChatFileUploadManager when upload (serving file to receiver) state changes
class ChatUploadProgressEvent extends AppEvent {
  final String uploadId;
  final String messageId;
  final String receiverCallsign;
  final String filename;
  final int bytesTransferred;
  final int totalBytes;
  final double? speedBytesPerSecond;
  final String status; // 'pending', 'uploading', 'completed', 'failed'
  final String? error;

  ChatUploadProgressEvent({
    required this.uploadId,
    required this.messageId,
    required this.receiverCallsign,
    required this.filename,
    required this.bytesTransferred,
    required this.totalBytes,
    this.speedBytesPerSecond,
    required dynamic status,
    this.error,
  }) : status = status.toString().split('.').last;

  double get progressPercent =>
      totalBytes > 0 ? (bytesTransferred / totalBytes * 100) : 0;

  String get bytesTransferredFormatted => _formatBytes(bytesTransferred);
  String get totalBytesFormatted => _formatBytes(totalBytes);
  String? get speedFormatted => speedBytesPerSecond != null
      ? '${_formatBytes(speedBytesPerSecond!.toInt())}/s'
      : null;

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  String toString() =>
      'ChatUploadProgressEvent(id: $uploadId, receiver: $receiverCallsign, progress: ${progressPercent.toStringAsFixed(1)}%, status: $status)';
}

/// Device scanning/discovery state changed
/// Fired by DevicesService when reachability checks start/complete
class DeviceScanEvent extends AppEvent {
  final bool isScanning;
  final int totalDevices;
  final int? completedDevices;

  DeviceScanEvent({
    required this.isScanning,
    required this.totalDevices,
    this.completedDevices,
  });

  @override
  String toString() =>
      'DeviceScanEvent(isScanning: $isScanning, total: $totalDevices, completed: $completedDevices)';
}

/// Device status changed event (reachable/unreachable)
/// Fired by DevicesService when a device's reachability changes
class DeviceStatusChangedEvent extends AppEvent {
  final String callsign;
  final bool isReachable;
  final String? connectionMethod; // 'bluetooth', 'lan', 'internet', etc.

  DeviceStatusChangedEvent({
    required this.callsign,
    required this.isReachable,
    this.connectionMethod,
  });

  @override
  String toString() =>
      'DeviceStatusChangedEvent(callsign: $callsign, reachable: $isReachable, method: $connectionMethod)';
}

/// GPS position updated event
/// Fired by LocationProviderService when a new position is acquired.
/// Subscribe to this event instead of using timers for location-based features.
class PositionUpdatedEvent extends AppEvent {
  final double latitude;
  final double longitude;
  final double altitude;
  final double accuracy;
  final double speed;
  final double heading;
  final String source; // 'gps', 'network', 'ip'

  PositionUpdatedEvent({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.accuracy,
    required this.speed,
    required this.heading,
    required this.source,
  });

  @override
  String toString() =>
      'PositionUpdatedEvent(lat: $latitude, lon: $longitude, accuracy: ${accuracy.toStringAsFixed(1)}m, source: $source)';
}

// ============================================================
// P2P Transfer Events
// ============================================================

/// P2P transfer offer received from another device
/// Fired when an incoming transfer offer arrives
class TransferOfferReceivedEvent extends AppEvent {
  final String offerId;
  final String senderCallsign;
  final String? senderNpub;
  final int totalFiles;
  final int totalBytes;
  final DateTime expiresAt;
  final List<Map<String, dynamic>> files;

  TransferOfferReceivedEvent({
    required this.offerId,
    required this.senderCallsign,
    this.senderNpub,
    required this.totalFiles,
    required this.totalBytes,
    required this.expiresAt,
    required this.files,
  });

  @override
  String toString() =>
      'TransferOfferReceivedEvent(id: $offerId, from: $senderCallsign, files: $totalFiles)';
}

/// P2P transfer offer response received (sender receives this)
/// Fired when the receiver accepts or rejects an offer
class TransferOfferResponseEvent extends AppEvent {
  final String offerId;
  final bool accepted;
  final String receiverCallsign;

  TransferOfferResponseEvent({
    required this.offerId,
    required this.accepted,
    required this.receiverCallsign,
  });

  @override
  String toString() =>
      'TransferOfferResponseEvent(id: $offerId, accepted: $accepted, by: $receiverCallsign)';
}

/// P2P upload progress event (sender receives this from receiver)
/// Fired as the receiver downloads files
class P2PUploadProgressEvent extends AppEvent {
  final String offerId;
  final int bytesTransferred;
  final int totalBytes;
  final int filesCompleted;
  final int totalFiles;
  final String? currentFile;

  P2PUploadProgressEvent({
    required this.offerId,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.filesCompleted,
    required this.totalFiles,
    this.currentFile,
  });

  double get progressPercent =>
      totalBytes > 0 ? (bytesTransferred / totalBytes * 100) : 0;

  @override
  String toString() =>
      'P2PUploadProgressEvent(id: $offerId, progress: ${progressPercent.toStringAsFixed(1)}%)';
}

/// P2P transfer complete event (sender receives this from receiver)
/// Fired when the receiver finishes downloading all files
class P2PTransferCompleteEvent extends AppEvent {
  final String offerId;
  final bool success;
  final int bytesReceived;
  final int filesReceived;
  final String? error;

  P2PTransferCompleteEvent({
    required this.offerId,
    required this.success,
    required this.bytesReceived,
    required this.filesReceived,
    this.error,
  });

  @override
  String toString() =>
      'P2PTransferCompleteEvent(id: $offerId, success: $success, files: $filesReceived)';
}

/// P2P offer status changed event
/// Fired when an offer's status changes (pending -> accepted, etc.)
class TransferOfferStatusChangedEvent extends AppEvent {
  final String offerId;
  final String status;
  final String? error;

  TransferOfferStatusChangedEvent({
    required this.offerId,
    required this.status,
    this.error,
  });

  @override
  String toString() =>
      'TransferOfferStatusChangedEvent(id: $offerId, status: $status)';
}

/// Fired when a DM conversation's message retention period changes
/// (locally or received from remote)
class DMRetentionChangedEvent extends AppEvent {
  final String callsign;
  final String periodKey; // '1d', '1w', '1m', '1y', or 'forever'

  DMRetentionChangedEvent({
    required this.callsign,
    required this.periodKey,
  });

  @override
  String toString() =>
      'DMRetentionChangedEvent(callsign: $callsign, period: $periodKey)';
}

// ============================================================
// Now Activity Feed Events
// ============================================================

/// Priority constants for NowItemEvent
class NowPriority {
  static const int alertUrgent = 1;
  static const int alertAttention = 2;
  static const int directMessage = 3;
  static const int email = 4;
  static const int chat = 5;
  static const int forum = 6;
  static const int blog = 7;
  static const int event = 8;
  static const int sharedFile = 9;
  static const int routine = 10;
}

/// Activity feed item event — fired by any service that wants to appear in the Now panel
class NowItemEvent extends AppEvent {
  final String id; // unique ID (e.g., "chat:main:2026-03-04T10:30:00")
  final String appType; // "chat", "dm", "alert", "email", "forum", "blog", "event", "irc", etc.
  final String sourceId; // room ID, thread ID, alert ID, etc.
  final String sourceName; // human-readable: "General Chat", "CR7BBQ", etc.
  final String callsign; // who caused the activity
  final String summary; // short preview text
  final int priority; // 1 (highest) to 10 (lowest)

  NowItemEvent({
    required this.id,
    required this.appType,
    required this.sourceId,
    required this.sourceName,
    required this.callsign,
    required this.summary,
    required this.priority,
  });

  @override
  String toString() =>
      'NowItemEvent(appType: $appType, source: $sourceName, from: $callsign, priority: $priority)';
}

/// Fired when a source should be removed from the Now feed (e.g. leaving an IRC channel)
class NowGroupRemoveEvent extends AppEvent {
  final String appType;
  final String sourceId;

  NowGroupRemoveEvent({required this.appType, required this.sourceId});
}

/// Fired when a blog post is published locally
class BlogPostPublishedEvent extends AppEvent {
  final String postId;
  final String author;
  final String title;

  BlogPostPublishedEvent({
    required this.postId,
    required this.author,
    required this.title,
  });

  @override
  String toString() =>
      'BlogPostPublishedEvent(postId: $postId, author: $author, title: $title)';
}

/// Fired when an event is created locally
class EventCreatedEvent extends AppEvent {
  final String eventId;
  final String author;
  final String title;

  /// Optional full event object for activity publishing.
  final dynamic eventRecord;

  EventCreatedEvent({
    required this.eventId,
    required this.author,
    required this.title,
    this.eventRecord,
  });

  @override
  String toString() =>
      'EventCreatedEvent(eventId: $eventId, author: $author, title: $title)';
}

/// Fired when a place is created/saved locally
class PlaceCreatedEvent extends AppEvent {
  final String placeId;
  final String author;
  final String name;

  PlaceCreatedEvent({
    required this.placeId,
    required this.author,
    required this.name,
  });

  @override
  String toString() =>
      'PlaceCreatedEvent(placeId: $placeId, author: $author, name: $name)';
}

/// Fired when karma points are recorded locally
class KarmaUpdatedEvent extends AppEvent {
  final String callsign;
  final String action;
  final int points;
  final int totalPoints;

  KarmaUpdatedEvent({
    required this.callsign,
    required this.action,
    required this.points,
    required this.totalPoints,
  });

  @override
  String toString() =>
      'KarmaUpdatedEvent(callsign: $callsign, action: $action, points: $points, total: $totalPoints)';
}

/// Fired when an alert is created locally
class AlertCreatedEvent extends AppEvent {
  final String alertId;
  final String author;
  final String title;

  AlertCreatedEvent({
    required this.alertId,
    required this.author,
    required this.title,
  });

  @override
  String toString() =>
      'AlertCreatedEvent(alertId: $alertId, author: $author, title: $title)';
}

/// Notification tapped for a Now item (generic handler for types without dedicated events)
class NowNotificationTappedEvent extends AppEvent {
  final String appType;
  final String sourceId;
  final String sourceName;
  NowNotificationTappedEvent({required this.appType, required this.sourceId, required this.sourceName});
}

/// App fully initialized (fired once at end of Phase 2 deferred init)
/// Services can subscribe to this to start background work after all
/// services are ready.
class AppStartedEvent extends AppEvent {}

/// P2P download progress event (receiver tracks locally)
/// Fired as the receiver downloads files from sender
class P2PDownloadProgressEvent extends AppEvent {
  final String offerId;
  final int bytesTransferred;
  final int totalBytes;

  P2PDownloadProgressEvent({
    required this.offerId,
    required this.bytesTransferred,
    required this.totalBytes,
  });

  double get progressPercent =>
      totalBytes > 0 ? (bytesTransferred / totalBytes * 100) : 0;

  @override
  String toString() =>
      'P2PDownloadProgressEvent(id: $offerId, progress: ${progressPercent.toStringAsFixed(1)}%)';
}
