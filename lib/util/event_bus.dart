/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Event Bus - Simple event-driven communication for CLI and GUI
 */

import 'dart:async';

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
    return _controllers.putIfAbsent(
      T,
      () => StreamController<T>.broadcast(),
    ) as StreamController<T>;
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

  ClientConnectedEvent({
    required this.clientId,
    this.callsign,
    this.npub,
  });
}

/// Client disconnected from station
class ClientDisconnectedEvent extends AppEvent {
  final String clientId;
  final String? callsign;

  ClientDisconnectedEvent({
    required this.clientId,
    this.callsign,
  });
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

  ProfileChangedEvent({
    required this.callsign,
    required this.npub,
  });
}

/// Collection updated (tiles, files, etc.)
class CollectionUpdatedEvent extends AppEvent {
  final String collectionType;  // 'tiles', 'files', 'audio', etc.
  final String? path;

  CollectionUpdatedEvent({
    required this.collectionType,
    this.path,
  });
}

/// Error event for global error handling
class ErrorEvent extends AppEvent {
  final String message;
  final String? source;
  final Object? error;
  final StackTrace? stackTrace;

  ErrorEvent({
    required this.message,
    this.source,
    this.error,
    this.stackTrace,
  });
}

/// Status update event for UI feedback
class StatusUpdateEvent extends AppEvent {
  final String message;
  final StatusType type;

  StatusUpdateEvent({
    required this.message,
    this.type = StatusType.info,
  });
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
  final String fromCallsign;    // Sender's callsign
  final String toCallsign;      // Recipient's callsign (local user)
  final String content;         // Message content
  final String messageTimestamp; // Message timestamp (YYYY-MM-DD HH:MM_ss)
  final String? npub;           // Sender's NOSTR public key
  final String? signature;      // NOSTR signature
  final bool verified;          // Signature verification status
  final bool fromSync;          // True if received via sync, false if local

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
  final String targetCallsign;  // The callsign to open DM conversation with

  DMNotificationTappedEvent({
    required this.targetCallsign,
  });
}

/// Direct message sync completed
class DirectMessageSyncEvent extends AppEvent {
  final String otherCallsign;   // The callsign we synced with
  final int newMessages;        // Number of new messages received
  final int sentMessages;       // Number of messages sent to other device
  final bool success;           // Whether sync completed successfully
  final String? error;          // Error message if failed

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
  final String callsign;         // The recipient's callsign
  final String messageTimestamp; // The message timestamp (unique identifier)

  DMMessageDeliveredEvent({
    required this.callsign,
    required this.messageTimestamp,
  });
}

/// Connection type for ConnectionStateChangedEvent
enum ConnectionType {
  internet,   // General internet connectivity (can reach external hosts)
  station,    // Station relay connection (WebSocket to p2p.radio)
  lan,        // Local network connection (WiFi/Ethernet with private IP)
  bluetooth,  // Bluetooth Low Energy connection
}

/// Connection state changed event
/// Fired when a connection type becomes available or unavailable
class ConnectionStateChangedEvent extends AppEvent {
  final ConnectionType connectionType;
  final bool isConnected;
  final String? stationUrl;     // For station: the URL connected to
  final String? stationCallsign; // For station: the station's callsign

  ConnectionStateChangedEvent({
    required this.connectionType,
    required this.isConnected,
    this.stationUrl,
    this.stationCallsign,
  });

  @override
  String toString() => 'ConnectionStateChangedEvent(type: $connectionType, connected: $isConnected)';
}

/// BLE status types for UI notifications
enum BLEStatusType {
  scanning,       // BLE scan started
  scanComplete,   // BLE scan completed
  deviceFound,    // New BLE device discovered
  advertising,    // BLE advertising started
  connecting,     // Connecting to a BLE device
  connected,      // Connected to a BLE device
  disconnected,   // Disconnected from a BLE device
  sending,        // Sending data via BLE
  received,       // Received data via BLE
  error,          // BLE error occurred
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

  ChatMessagesLoadedEvent({
    this.roomId,
    required this.messageCount,
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

  TransferCancelledEvent({
    required this.transferId,
    this.requestingApp,
  });

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
