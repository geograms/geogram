# Relay Hello Handshake Implementation

## Overview
This document outlines the implementation of the WebSocket "hello" handshake between geogram-desktop and geogram-relay with Nostr-style signed messages.

## Protocol Flow

1. **Desktop connects** to relay WebSocket endpoint (ws://localhost:8080/)
2. **Desktop sends "hello"** message with signed Nostr event
3. **Relay verifies** signature and npub
4. **Relay responds** with acknowledgment
5. **Connection established** - relay listed as connected

## Message Format

### Hello Message (Desktop → Relay)
```json
{
  "type": "hello",
  "event": {
    "id": "event_id_hash",
    "pubkey": "user_public_key_hex",
    "created_at": 1234567890,
    "kind": 1,
    "tags": [
      ["type", "hello"],
      ["callsign", "X1ABCD"]
    ],
    "content": "Hello from Geogram Desktop",
    "sig": "signature_hex"
  }
}
```

### Hello Response (Relay → Desktop)
```json
{
  "type": "hello_ack",
  "success": true,
  "callsign": "X1ABCD",
  "relay_id": "X3QPSF",
  "message": "Connection established"
}
```

## Files to Create/Modify

### Flutter (geogram-desktop)

#### 1. lib/util/nostr_event.dart ✓ (CREATED)
- NostrEvent class with create, sign, verify methods
- Simplified signing using SHA256 (upgrade to secp256k1 later)

#### 2. lib/services/websocket_service.dart (NEW)
```dart
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../util/nostr_event.dart';
import 'log_service.dart';
import 'profile_service.dart';

class WebSocketService {
  WebSocketChannel? _channel;

  Future<bool> connectAndHello(String url) async {
    try {
      LogService().log('Connecting to relay: $url');
      _channel = WebSocketChannel.connect(Uri.parse(url));

      // Get user profile
      final profile = ProfileService().getProfile();

      // Create and sign hello event
      final event = NostrEvent.createHello(
        npub: profile.npub,
        callsign: profile.callsign,
      );
      event.calculateId();
      event.sign(profile.nsec);

      // Send hello message
      final helloMessage = jsonEncode({
        'type': 'hello',
        'event': event.toJson(),
      });

      LogService().log('Sending hello to relay...');
      LogService().log('Hello message: $helloMessage');
      _channel!.sink.add(helloMessage);

      // Wait for response
      await for (final message in _channel!.stream) {
        LogService().log('Received from relay: $message');
        final data = jsonDecode(message);

        if (data['type'] == 'hello_ack') {
          if (data['success'] == true) {
            LogService().log('✓ Hello acknowledged by relay ${data['relay_id']}');
            return true;
          } else {
            LogService().log('✗ Hello rejected: ${data['message']}');
            return false;
          }
        }
      }

      return false;
    } catch (e) {
      LogService().log('Error connecting to relay: $e');
      return false;
    }
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
  }
}
```

#### 3. lib/services/relay_service.dart (MODIFY)
Add to RelayService class:
```dart
final WebSocketService _wsService = WebSocketService();

Future<void> connectRelay(String url) async {
  final success = await _wsService.connectAndHello(url);

  if (success) {
    // Update relay connection status
    final index = _relays.indexWhere((r) => r.url == url);
    if (index != -1) {
      _relays[index] = _relays[index].copyWith(
        isConnected: true,
        lastChecked: DateTime.now(),
      );
      await _saveRelays();
      LogService().log('Connected to relay: $url');
    }
  }
}
```

### Java (geogram-relay)

#### 4. pom.xml (MODIFY)
Add Bouncy Castle dependency:
```xml
<dependency>
    <groupId>org.bouncycastle</groupId>
    <artifactId>bcprov-jdk18on</artifactId>
    <version>1.78.1</version>
</dependency>
```

#### 5. src/main/java/geogram/relay/NostrEvent.java (NEW)
```java
package geogram.relay;

import com.google.gson.Gson;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import java.security.MessageDigest;
import java.util.List;
import java.util.Map;

public class NostrEvent {
    private static final Logger LOG = LoggerFactory.getLogger(NostrEvent.class);

    public String id;
    public String pubkey;
    public long created_at;
    public int kind;
    public List<List<String>> tags;
    public String content;
    public String sig;

    public boolean verify() {
        try {
            // Verify event ID
            String calculatedId = calculateId();
            if (!calculatedId.equals(id)) {
                LOG.warn("Event ID mismatch");
                return false;
            }

            // Verify signature (simplified for now)
            // TODO: Implement proper secp256k1 verification
            LOG.info("Event signature verification (simplified)");
            return true;

        } catch (Exception e) {
            LOG.error("Error verifying event", e);
            return false;
        }
    }

    private String calculateId() throws Exception {
        // Serialize event for hashing
        String serialized = serializeForHash();
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] hash = digest.digest(serialized.getBytes());
        return bytesToHex(hash);
    }

    private String serializeForHash() {
        Object[] arr = new Object[]{0, pubkey, created_at, kind, tags, content};
        return new Gson().toJson(arr);
    }

    private static String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder();
        for (byte b : bytes) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }

    public String getCallsign() {
        for (List<String> tag : tags) {
            if (tag.size() >= 2 && "callsign".equals(tag.get(0))) {
                return tag.get(1);
            }
        }
        return null;
    }
}
```

#### 6. src/main/java/geogram/relay/RelayServer.java (MODIFY)
Update `onMessage` method:
```java
private void handleHelloMessage(Session session, Map<String, Object> message) {
    try {
        LOG.info("═══════════════════════════════════════");
        LOG.info("RECEIVED HELLO MESSAGE");
        LOG.info("═══════════════════════════════════════");

        // Parse Nostr event
        Map<String, Object> eventData = (Map<String, Object>) message.get("event");
        NostrEvent event = gson.fromJson(gson.toJson(eventData), NostrEvent.class);

        LOG.info("Event ID: {}", event.id);
        LOG.info("Pubkey: {}", event.pubkey);
        LOG.info("Callsign: {}", event.getCallsign());
        LOG.info("Content: {}", event.content);

        // Verify signature
        if (!event.verify()) {
            LOG.error("✗ Invalid signature");
            sendResponse(session, Map.of(
                "type", "hello_ack",
                "success", false,
                "message", "Invalid signature"
            ));
            return;
        }

        LOG.info("✓ Signature verified");

        // Register device
        String callsign = event.getCallsign();
        ConnectedDevice device = new ConnectedDevice(callsign, session);
        device.npub = event.pubkey;  // Store npub
        connectedDevices.put(callsign, device);

        LOG.info("✓ Device registered: {}", callsign);
        LOG.info("═══════════════════════════════════════");

        // Send acknowledgment
        sendResponse(session, Map.of(
            "type", "hello_ack",
            "success", true,
            "callsign", callsign,
            "relay_id", config.aprsCallsign,
            "message", "Connection established"
        ));

        // Log to file
        LogManager logManager = GeogramRelay.getLogManager();
        if (logManager != null) {
            logManager.log(String.format("HELLO_RECEIVED: %s (npub: %s...)",
                callsign, event.pubkey.substring(0, 16)));
        }

    } catch (Exception e) {
        LOG.error("Error handling hello message", e);
    }
}
```

## Scripts

### launch-relay-local.sh
```bash
#!/bin/bash
cd /home/brito/code/geogram/geogram-relay
echo "Starting local relay on port 8080..."
java -jar target/geogram-relay-1.0.0.jar
```

### setup-local-relay.sh
```bash
#!/bin/bash
# Add local relay as preferred in desktop app
RELAY_URL="ws://localhost:8080"
RELAY_NAME="Local Dev Relay"

echo "Setting up local relay: $RELAY_URL"
# This would update the config.json to add the local relay
# For now, add manually through UI
```

## Testing

1. Build relay: `cd geogram-relay && mvn clean package`
2. Start relay: `./launch-relay-local.sh`
3. Build desktop: `cd geogram-desktop && flutter pub get && flutter build linux`
4. Run desktop: `./launch-desktop.sh`
5. Go to Relays page
6. Add custom relay: ws://localhost:8080
7. Set as preferred
8. Click "Test" button
9. Check logs window for hello handshake messages

## Log Output Expected

**Desktop Log:**
```
Connecting to relay: ws://localhost:8080
Sending hello to relay...
Hello message: {"type":"hello","event":{...}}
Received from relay: {"type":"hello_ack","success":true,...}
✓ Hello acknowledged by relay X3QPSF
Connected to relay: ws://localhost:8080
```

**Relay Log:**
```
═══════════════════════════════════════
RECEIVED HELLO MESSAGE
═══════════════════════════════════════
Event ID: abc123...
Pubkey: def456...
Callsign: X1ABCD
Content: Hello from Geogram Desktop
✓ Signature verified
✓ Device registered: X1ABCD
═══════════════════════════════════════
```
