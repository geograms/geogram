# Testing the Hello Handshake

## Prerequisites

- Flutter installed and in your PATH
- Java (for running the relay)
- Maven (for building the relay)

If Flutter is not in your PATH, add it to `~/.bashrc` or `~/.zshrc`:
```bash
export PATH="$PATH:$HOME/flutter/bin"
```

## Quick Start

The easiest way to test the hello handshake is using the combined launch script:

```bash
cd geogram-desktop
./launch-with-local-relay.sh
```

This script will:
1. Build the relay if needed
2. Start the relay on `ws://localhost:8080` in the background
3. Launch the Geogram Desktop app
4. Clean up both processes when you close the app

## Manual Steps (if you want to run components separately)

### Option 1: Launch Relay Manually

```bash
cd geogram-relay
./launch-relay-local.sh
```

Then in another terminal:
```bash
cd geogram-desktop
flutter run -d linux
```

### Option 2: View Relay Logs

The combined script saves relay logs to `/tmp/geogram-relay.log`:

```bash
tail -f /tmp/geogram-relay.log
```

## Testing the Hello Handshake

Once the desktop app is running:

1. **Open the Relays Page**
   - Click "Internet Relays" in the navigation

2. **Add Local Relay** (if not already added)
   - Click the "+ Add Relay" button
   - Enter:
     - Name: `Local Dev Relay`
     - URL: `ws://localhost:8080`
   - Click "Add"

3. **Set as Preferred** (optional)
   - Click "Set Preferred" button on the local relay

4. **Test the Connection**
   - Click the "Test" button on the local relay
   - Watch the log window at the bottom of the screen

## What You Should See

### In the Desktop App Log Window

You should see detailed logging like:

```
══════════════════════════════════════
CONNECTING TO RELAY
══════════════════════════════════════
URL: ws://localhost:8080
✓ WebSocket connected
User callsign: YOUR_CALLSIGN
User npub: npub1abc...

SENDING HELLO MESSAGE
══════════════════════════════════════
Message type: hello
Event ID: abc123...
Callsign: YOUR_CALLSIGN
Content: Hello from Geogram Desktop

Full message:
{"type":"hello","event":{...}}
══════════════════════════════════════

RECEIVED MESSAGE FROM RELAY
══════════════════════════════════════
Raw message: {"type":"hello_ack",...}
Message type: hello_ack
✓ Hello acknowledged!
Relay ID: relay-1234567890
Message: Hello received and acknowledged
══════════════════════════════════════

✓ CONNECTION SUCCESSFUL
Relay: Local Dev Relay
Latency: 123ms
══════════════════════════════════════
```

### In the Relay Console/Log

You should see:

```
══════════════════════════════════════
HELLO MESSAGE RECEIVED
══════════════════════════════════════
From: /127.0.0.1:xxxxx
Event ID: abc123...
Pubkey: 1234abcd...
Signature: 5678efgh...
Content: Hello from Geogram Desktop
Callsign: YOUR_CALLSIGN
SIGNATURE NOT VERIFIED - Using simplified validation (to be upgraded to secp256k1)
✓ HELLO ACKNOWLEDGED
Callsign: YOUR_CALLSIGN
Relay ID: relay-1234567890
══════════════════════════════════════
```

### In the UI

- The relay status should change to "Connected"
- Latency should be displayed (typically < 100ms for localhost)
- Last checked time should update
- Green checkmark icon should appear

## Troubleshooting

### Relay Not Starting

Check if port 8080 is already in use:
```bash
lsof -i :8080
```

### Connection Failed

1. Ensure relay is running: `curl http://localhost:8080` (should return 404 but proves it's listening)
2. Check relay logs: `tail /tmp/geogram-relay.log`
3. Ensure URL is exactly `ws://localhost:8080` (not `wss://`)

### No Logs Appearing

1. Make sure the log window is visible in the desktop app
2. Check that LogService is initialized
3. Verify profile exists (npub/nsec/callsign)

## Next Steps

Once the basic hello handshake is working with simplified SHA-256 signing:

1. Implement proper secp256k1 signing in Flutter (using pointycastle)
2. Implement proper secp256k1 verification in Java (using Bouncy Castle)
3. Test the cryptographic handshake end-to-end
4. Verify signature validation catches spoofed identities

## Implementation Status

- ✅ Basic WebSocket connection
- ✅ Hello message format (Nostr NIP-01)
- ✅ Desktop sends hello with event
- ✅ Relay receives and parses hello
- ✅ Relay sends hello_ack
- ✅ Desktop receives and displays ack
- ✅ Extensive logging on both sides
- ⚠️ Signature validation (using simplified SHA-256, needs secp256k1 upgrade)
