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

Fired when a client connects to the relay.

```dart
class ClientConnectedEvent extends AppEvent {
  final String clientId;
  final String? callsign;
  final String? npub;
}
```

### ClientDisconnectedEvent

Fired when a client disconnects from the relay.

```dart
class ClientDisconnectedEvent extends AppEvent {
  final String clientId;
  final String? callsign;
}
```

### RelayStartedEvent

Fired when the relay server starts.

```dart
class RelayStartedEvent extends AppEvent {
  final int httpPort;
  final int? httpsPort;
  final String callsign;
}
```

### RelayStoppedEvent

Fired when the relay server stops.

```dart
class RelayStoppedEvent extends AppEvent {}
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

#### PureRelayServer (`lib/cli/pure_relay.dart`)

The relay server fires `ChatMessageEvent` when messages are added:

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
_chatMessageSubscription = _relay.eventBus.on<ChatMessageEvent>((event) {
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

In addition to the EventBus (used internally), the relay broadcasts UPDATE notifications to WebSocket clients for GUI real-time updates:

**Format:** `UPDATE:{callsign}/chat/{roomId}`

**Example:** `UPDATE:X3GFCK/chat/general`

These are sent alongside `chat_message` JSON payloads to all connected WebSocket clients when a message is posted from any source.

## Future Extensions

Events defined but not yet integrated:

- `ChatRoomCreatedEvent` / `ChatRoomDeletedEvent` - For room management notifications
- `ClientConnectedEvent` / `ClientDisconnectedEvent` - For presence awareness
- `RelayStartedEvent` / `RelayStoppedEvent` - For relay lifecycle management
- `ProfileChangedEvent` - For profile synchronization
- `CollectionUpdatedEvent` - For file/tile collection updates
- `ErrorEvent` / `StatusUpdateEvent` - For global error handling and status display

These can be integrated as needed by adding publishers where the events occur and subscribers where the reactions are needed.
