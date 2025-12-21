# IRC Bridge for Geogram Chat

**Version**: 1.0
**Status**: Active
**Last Updated**: 2025-12-14

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Connecting with IRC Clients](#connecting-with-irc-clients)
- [Channel Naming](#channel-naming)
- [Message Translation](#message-translation)
- [Authentication](#authentication)
- [Supported Features](#supported-features)
- [Limitations](#limitations)
- [Security Considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)

## Overview

The Geogram IRC bridge allows standard IRC clients to connect to a Geogram station server and interact with chat rooms. This enables users without the Geogram app to participate in conversations using familiar IRC clients like irssi, WeeChat, or HexChat.

**Key Features:**
- Bidirectional messaging between IRC and Geogram
- Access to station-hosted and device-hosted chat rooms
- Automatic NOSTR identity generation for IRC guests
- Cryptographically signed messages
- Support for room permissions (public/restricted)

## Architecture

### Server Location

The IRC server runs exclusively on **station servers**, not on individual devices. This allows:
- Centralized access to all connected device chat rooms
- Single connection point for IRC clients
- Efficient message relay between IRC and Geogram

### Protocol Support

The IRC bridge implements a minimal subset of RFC 1459 (Internet Relay Chat Protocol):

**Supported Commands:**
- `NICK` - Set nickname
- `USER` - Set username
- `JOIN` - Join a channel
- `PART` - Leave a channel
- `PRIVMSG` - Send a message
- `LIST` - List available channels
- `NAMES` - List users in a channel
- `PING/PONG` - Keep-alive
- `QUIT` - Disconnect

**Not Supported:**
- Channel creation (`/create`)
- Operator modes (`/op`, `/kick`, `/ban`)
- DCC file transfers
- CTCP protocol

## Connecting with IRC Clients

### Default Port

**Default**: 6667 (standard IRC port)
**Alternative**: Station port + 2 (e.g., if API is 3456, IRC is 3458)

### Connection Examples

#### irssi
```bash
irssi -c p2p.radio -p 6667
/nick YourNick
/join #main
```

#### WeeChat
```bash
weechat
/server add geogram p2p.radio/6667
/connect geogram
/nick YourNick
/join #main
```

#### HexChat
1. Network List → Add
2. Server: p2p.radio/6667
3. Nickname: YourNick
4. Connect and `/join #main`

### Secure Connections (Recommended)

IRC connections are **unencrypted by default**. For security, use SSH tunneling:

```bash
# Forward local port 6667 to station IRC server
ssh -L 6667:localhost:6667 user@p2p.radio

# Then connect IRC client to localhost
irssi -c localhost -p 6667
```

## Channel Naming

IRC channels are flat (no hierarchy), so Geogram uses a naming convention to distinguish between station and device rooms.

### Station Rooms

**Format**: `#roomId`

**Examples:**
- `#main` - Main station chat
- `#announcements` - Station announcements
- `#general` - General discussion

### Device Rooms

**Format**: `#CALLSIGN-roomId`

**Examples:**
- `#X1ABCD-main` - Main room on device X1ABCD
- `#X3QCMH-chat` - Chat room on station X3QCMH
- `#X1TEST-private` - Private room on device X1TEST

### Channel Discovery

Use `/list` to see all available channels:

```
/list
```

**Sample Output:**
```
#main                5 users   Public station chat
#announcements       2 users   Station announcements
#X1ABCD-main        3 users   Device X1ABCD main room
#X3QCMH-chat        8 users   Station X3QCMH chat
```

## Message Translation

### IRC → Geogram

Messages sent via IRC are automatically:
1. Signed with your auto-generated NOSTR identity
2. Posted to the Geogram chat API
3. Stored in chat files as valid NOSTR events
4. Visible to Geogram app users

**Example:**
```
IRC:      PRIVMSG #main :Hello everyone!
Geogram:  > 2025-12-14 15:30_25 -- YourNick
          Hello everyone!
          --> npub: npub1abc...
          --> signature: hex...
```

### Geogram → IRC

Messages from Geogram appear in IRC with the author's callsign:

```
:CR7BBQ!~guest@station PRIVMSG #main :Hello from Geogram!
```

### Special Features

#### Location
```
IRC:  :CR7BBQ!~guest@station PRIVMSG #main :Check this [📍 38.7223,-9.1393]
```

#### File Attachments
```
IRC:  :CR7BBQ!~guest@station PRIVMSG #main :Photo: https://p2p.radio/files/photo.jpg
```

#### Polls
```
IRC:  :CR7BBQ!~guest@station PRIVMSG #main :📊 Poll: When lunch?
      :CR7BBQ!~guest@station PRIVMSG #main :[1] 12:00
      :CR7BBQ!~guest@station PRIVMSG #main :[2] 12:15
      :Station!~bot@station PRIVMSG #main :[2 votes, deadline: 20:00]
```

#### Voice Messages
```
IRC:  :CR7BBQ!~guest@station PRIVMSG #main :🎤 Voice (12s): https://p2p.radio/files/voice.ogg
```

#### Reactions
```
IRC:  :Station!~bot@station PRIVMSG #main :[👍 X135AS, ALPHA1]
```

#### Edited Messages
```
IRC:  :CR7BBQ!~guest@station PRIVMSG #main :Updated content [edited 15:30]
```

## Authentication

### Guest Identity

When you connect via IRC, you are **automatically assigned a NOSTR identity**:
- A cryptographic keypair is generated
- Your messages are signed with this identity
- This identity is **ephemeral** (session-based)

### Public Rooms

No authentication required. Simply `/join #main` and start chatting.

### Restricted Rooms

Restricted rooms require your NOSTR public key (npub) to be listed as a participant.

**Error when denied:**
```
:server 473 YourNick #private-room :Cannot join channel (+i)
```

**To get access:**
1. Ask the room owner to add your npub to the participant list
2. Your npub is shown when you connect (future feature)
3. Or use the Geogram app to request access

### Persistent Identity (Future)

Future versions will support password-protected persistent identities:
```
/msg NickServ REGISTER password email
```

This will allow you to:
- Keep the same npub across sessions
- Build reputation with signed messages
- Access restricted rooms consistently

## Supported Features

| Feature | IRC Support | Notes |
|---------|-------------|-------|
| Send messages | ✅ Yes | Auto-signed with NOSTR |
| Receive messages | ✅ Yes | Real-time delivery |
| Public rooms | ✅ Yes | No auth required |
| Restricted rooms | ✅ Yes | Requires npub permission |
| Private messages | ❌ No | Use Geogram app for DMs |
| File upload | ❌ No | Files shared via links only |
| Create rooms | ❌ No | Geogram app only |
| Location sharing | 🔶 Read-only | See coordinates, can't post |
| Polls | 🔶 Read-only | View polls, voting via Geogram |
| Voice messages | 🔶 Read-only | Download link provided |

## Limitations

### No Room Creation
Users cannot create new chat rooms via IRC. Room creation is only possible through the Geogram app.

### No DMs via IRC
Direct messages (DMs) are not accessible via IRC. Use the Geogram app for private 1-on-1 messaging.

### Read-Only Metadata
Special features like location, files, polls, and voice messages can be **viewed** but not **created** via IRC.

### No Encryption
IRC connections are **unencrypted by default**. Use SSH tunneling for secure connections.

### Polling Latency
Messages from device rooms have a 5-second delay (HTTP polling interval). Station room messages are delivered in real-time (<500ms).

## Security Considerations

### Message Signing
All messages sent via IRC are cryptographically signed with your NOSTR identity. This provides:
- **Authenticity**: Messages can be verified as coming from you
- **Integrity**: Tampered messages will fail verification
- **Non-repudiation**: You cannot deny sending a signed message

### Guest Identity Security
Your guest NOSTR keypair is:
- Generated on the server (not the client)
- Ephemeral (lost on disconnect)
- Used only for signing your messages

**Important**: Anyone with access to the station server can see your private key. For sensitive communications:
- Use the Geogram app (keys stored locally)
- Or wait for persistent identity support (encrypted storage)

### Network Security
- Use SSH tunneling for encrypted connections
- Avoid public/untrusted stations for sensitive chats
- Rate limiting: 60 messages per minute

### Input Validation
- Nicknames: 1-30 characters, alphanumeric + `_-[]{}\\|`
- Channels: Max 200 characters, no whitespace
- Messages: Max 512 bytes (IRC limit)

## Troubleshooting

### Cannot Connect
```
Error: Connection refused
```
**Solution**: Check that IRC server is enabled on the station:
- Station settings → IRC Server → Enabled
- Verify port is correct (default 6667 or port + 2)

### Cannot Join Channel
```
:server 473 YourNick #private :Cannot join channel (+i)
```
**Solution**: This is a restricted room. Contact the room owner to add your npub to the participant list.

### Messages Not Appearing
**Symptom**: Your messages don't show in IRC or Geogram

**Solutions:**
1. Check you're joined to the channel: `/names #main`
2. Verify station connection: `/whois YourNick`
3. Check for rate limit: Wait 1 minute and try again

### Nick Already in Use
```
:server 433 * YourNick :Nickname is already in use
```
**Solution**: Choose a different nick: `/nick YourNick2`

### Lag or Delays
**Symptom**: Messages appear 5-10 seconds late

**Cause**: Device rooms use HTTP polling (5s interval)

**Solution**: This is expected for device rooms. Station rooms have real-time delivery.

## Related Documentation

- [Chat API](../chat-api.md) - HTTP API for chat rooms
- [Chat Format Specification](../apps/chat-format-specification.md) - Message storage format
- [Station API](../API.md) - Station server API overview
- [NOSTR Integration](../apps/chat-format-specification.md#nostr-integration) - Cryptographic signatures

## Change Log

### Version 1.0 (2025-12-14)
- Initial IRC bridge implementation
- Support for station and device rooms
- Auto-generated NOSTR identities for guests
- Bidirectional message relay
- Room permission enforcement

---

*This bridge is part of the Geogram project.*
*License: Apache-2.0*
