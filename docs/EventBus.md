# EventBus Architecture

The EventBus provides a simple publish/subscribe mechanism for event-driven communication across the application. It enables decoupled components to react to events without direct dependencies.

## Overview

The EventBus is implemented as a singleton using Dart's `StreamController` for broadcast streams. It supports typed events, allowing subscribers to listen for specific event types.

**Location:** `lib/util/event_bus.dart`

## Core Components

### EventBus Class

```dart
class EventBus {
  static final EventBus _instance = EventBus._internal();
  factory EventBus() => _instance;

  // Subscribe to events of type T
  EventSubscription<T> on<T extends AppEvent>(void Function(T event) handler);

  // Fire an event to all subscribers
  void fire<T extends AppEvent>(T event);

  // Check if there are subscribers for an event type
  bool hasSubscribers<T extends AppEvent>();

  // Clear all subscriptions (for testing/cleanup)
  void reset();
}
```

### AppEvent Base Class

All events extend `AppEvent`, which provides a timestamp:

```dart
abstract class AppEvent {
  final DateTime timestamp;
  AppEvent() : timestamp = DateTime.now();
}
```

### EventSubscription

Handle returned when subscribing, used to cancel the subscription:

```dart
class EventSubscription<T extends AppEvent> {
  void cancel();
}
```

## Available Events

### ChatMessageEvent

Fired when a chat message is received or posted.

```dart
class ChatMessageEvent extends AppEvent {
  final String roomId;      // Chat room ID
  final String callsign;    // Sender's callsign
  final String content;     // Message content
  final String? npub;       // Sender's NOSTR public key (optional)
  final String? signature;  // NOSTR signature (optional)
  final bool verified;      // Signature verification status
}
```

### ChatRoomCreatedEvent

Fired when a new chat room is created.

```dart
class ChatRoomCreatedEvent extends AppEvent {
  final String roomId;
  final String name;
  final String creatorCallsign;
}
```

### ChatRoomDeletedEvent

Fired when a chat room is deleted.

```dart
class ChatRoomDeletedEvent extends AppEvent {
  final String roomId;
}
```

### ClientConnectedEvent

Fired when a client connects to the station.

```dart
class ClientConnectedEvent extends AppEvent {
  final String clientId;
  final String? callsign;
  final String? npub;
}
```

### ClientDisconnectedEvent

Fired when a client disconnects from the station.

```dart
class ClientDisconnectedEvent extends AppEvent {
  final String clientId;
  final String? callsign;
}
```

### StationStartedEvent

Fired when the station server starts.

```dart
class StationStartedEvent extends AppEvent {
  final int httpPort;
  final int? httpsPort;
  final String callsign;
}
```

### StationStoppedEvent

Fired when the station server stops.

```dart
class StationStoppedEvent extends AppEvent {}
```

### ProfileChangedEvent

Fired when the user's profile changes.

```dart
class ProfileChangedEvent extends AppEvent {
  final String callsign;
  final String npub;
}
```

### CollectionUpdatedEvent

Fired when a collection (tiles, files, etc.) is updated.

```dart
class CollectionUpdatedEvent extends AppEvent {
  final String collectionType;  // 'tiles', 'files', 'audio', etc.
  final String? path;
}
```

### ErrorEvent

Fired for global error handling.

```dart
class ErrorEvent extends AppEvent {
  final String message;
  final String? source;
  final Object? error;
  final StackTrace? stackTrace;
}
```

### StatusUpdateEvent

Fired for UI status feedback.

```dart
class StatusUpdateEvent extends AppEvent {
  final String message;
  final StatusType type;  // info, success, warning, error
}
```

## Current Integration Points

### Publishers (Fire Events)

#### PureStationServer (`lib/cli/pure_station.dart`)

The station server fires `ChatMessageEvent` when messages are added:

| Location | Trigger |
|----------|---------|
| `postMessage()` | CLI user posts a message |
| WebSocket handler | Client sends message via WebSocket |
| `_handleNostrEvent()` | Client sends NOSTR-signed message |
| HTTP POST endpoint | Message received via HTTP API |

```dart
void _fireChatMessageEvent(ChatMessage msg) {
  _eventBus.fire(ChatMessageEvent(
    roomId: msg.roomId,
    callsign: msg.senderCallsign,
    content: msg.content,
    npub: msg.senderNpub,
    signature: msg.signature,
    verified: msg.verified,
  ));
}
```

### Subscribers (Listen to Events)

#### PureConsole (`lib/cli/pure_console.dart`)

The CLI console subscribes to `ChatMessageEvent` for real-time chat display:

```dart
// In _initializeServices()
_chatMessageSubscription = _station.eventBus.on<ChatMessageEvent>((event) {
  _handleIncomingChatMessage(event);
});

// Handler displays message if user is in the same chat room
void _handleIncomingChatMessage(ChatMessageEvent event) {
  if (_currentChatRoom != event.roomId) return;
  if (event.callsign == myCallsign) return;  // Skip own messages

  // Display message with timestamp, verification indicator, and content
}
```

## Usage Examples

### Subscribing to Events

```dart
final eventBus = EventBus();

// Subscribe to chat messages
final subscription = eventBus.on<ChatMessageEvent>((event) {
  print('New message in ${event.roomId}: ${event.content}');
});

// Later, cancel the subscription
subscription.cancel();
```

### Firing Events

```dart
final eventBus = EventBus();

// Fire a chat message event
eventBus.fire(ChatMessageEvent(
  roomId: 'general',
  callsign: 'X3GFCK',
  content: 'Hello, world!',
  verified: true,
));
```

### Checking for Subscribers

```dart
if (eventBus.hasSubscribers<ChatMessageEvent>()) {
  // Only fire if someone is listening
  eventBus.fire(chatEvent);
}
```

## WebSocket UPDATE Notifications

In addition to the EventBus (used internally), the station broadcasts UPDATE notifications to WebSocket clients for GUI real-time updates:

**Format:** `UPDATE:{callsign}/chat/{roomId}`

**Example:** `UPDATE:X3GFCK/chat/general`

These are sent alongside `chat_message` JSON payloads to all connected WebSocket clients when a message is posted from any source.

### DirectMessageReceivedEvent

Fired when a direct message is received (either locally or via sync).

```dart
class DirectMessageReceivedEvent extends AppEvent {
  final String fromCallsign;    // Sender's callsign
  final String toCallsign;      // Recipient's callsign (local user)
  final String content;         // Message content
  final String messageTimestamp; // Message timestamp (YYYY-MM-DD HH:MM_ss)
  final String? npub;           // Sender's NOSTR public key
  final String? signature;      // NOSTR signature
  final bool verified;          // Signature verification status
  final bool fromSync;          // True if received via sync, false if local
}
```

### DirectMessageSyncEvent

Fired when a DM sync operation completes with another device.

```dart
class DirectMessageSyncEvent extends AppEvent {
  final String otherCallsign;   // The callsign we synced with
  final int newMessages;        // Number of new messages received
  final int sentMessages;       // Number of messages sent to other device
  final bool success;           // Whether sync completed successfully
  final String? error;          // Error message if failed
}
```

**Usage Example:**

```dart
// Listen for incoming DMs
EventBus().on<DirectMessageReceivedEvent>((event) {
  if (!event.fromSync) {
    // New message arrived locally
    showNotification('Message from ${event.fromCallsign}');
  }
});

// Listen for sync completion
EventBus().on<DirectMessageSyncEvent>((event) {
  if (event.success && event.newMessages > 0) {
    showToast('${event.newMessages} new messages synced');
  }
});
```

### ConnectionStateChangedEvent

Fired when a connection type becomes available or unavailable. This enables apps to react to connectivity changes and update UI accordingly.

```dart
enum ConnectionType {
  station,    // Station relay (internet) connection
  lan,        // Local network connection
  bluetooth,  // Bluetooth Low Energy connection
}

class ConnectionStateChangedEvent extends AppEvent {
  final ConnectionType connectionType;
  final bool isConnected;
  final String? stationUrl;      // For station: the URL connected to
  final String? stationCallsign; // For station: the station's callsign
}
```

**Publishers:**

| Service | Event | Trigger |
|---------|-------|---------|
| `WebSocketService` | station connected | Receives `hello_ack` with `success: true` |
| `WebSocketService` | station disconnected | Connection loss or explicit disconnect |
| `BLEDiscoveryService` | bluetooth available | Bluetooth adapter turns on |
| `BLEDiscoveryService` | bluetooth unavailable | Bluetooth adapter turns off |

**Usage Example:**

```dart
// Subscribe to connection changes
EventBus().on<ConnectionStateChangedEvent>((event) {
  if (event.connectionType == ConnectionType.station) {
    if (event.isConnected) {
      print('Connected to station: ${event.stationCallsign}');
    } else {
      print('Disconnected from station');
    }
  } else if (event.connectionType == ConnectionType.bluetooth) {
    print('Bluetooth is now ${event.isConnected ? "available" : "unavailable"}');
  }
});

// Use for UI updates (e.g., filtering connection method tags)
if (mounted) {
  setState(() {
    // Rebuild UI to reflect new connection state
  });
}
```

**Integrated Subscribers:**

- `DevicesBrowserPage` - Refreshes connection method tags when connectivity changes

---

## Future Extensions

Events defined but not yet integrated:

- `ChatRoomCreatedEvent` / `ChatRoomDeletedEvent` - For room management notifications
- `ClientConnectedEvent` / `ClientDisconnectedEvent` - For presence awareness
- `StationStartedEvent` / `StationStoppedEvent` - For station lifecycle management
- `ProfileChangedEvent` - For profile synchronization
- `CollectionUpdatedEvent` - For file/tile collection updates
- `ErrorEvent` / `StatusUpdateEvent` - For global error handling and status display

These can be integrated as needed by adding publishers where the events occur and subscribers where the reactions are needed.
