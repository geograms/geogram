# Chat API

This document describes the Chat API endpoints available in Geogram Desktop.

## Overview

The Chat API allows external applications to:
- List available chat rooms
- Read messages from chat rooms
- Post messages (as device owner or as authenticated users via NOSTR-signed events)
- Edit messages (author only, with NOSTR authentication)
- Delete messages (author can delete own, moderators can delete any)
- List files attached to chat rooms

All endpoints are available under `/api/chat/` and require the HTTP API to be enabled in Security settings.

## Authentication

### Public Access
Public chat rooms (`visibility: PUBLIC`) can be accessed without authentication.

### NOSTR Authentication
For private or restricted rooms, authentication is required using NOSTR-signed events.

**Header format:**
```
Authorization: Nostr <base64_encoded_signed_event>
```

**Creating an auth event:**
```javascript
// Create a text note event for authentication
const event = {
  pubkey: "<your_pubkey_hex>",
  created_at: Math.floor(Date.now() / 1000),
  kind: 1,
  tags: [["t", "auth"]],
  content: "Authentication request",
  // ... calculate id and sign
};

// Base64 encode the JSON
const authHeader = "Nostr " + btoa(JSON.stringify(event));
```

**Requirements:**
- Event must be signed with a valid BIP-340 Schnorr signature
- Event `created_at` must be within 5 minutes of current time (prevents replay attacks)
- The `npub` derived from the event's `pubkey` is used for access control

## Endpoints

### GET /api/chat/

List available chat rooms based on authorization level.

**Query Parameters:**
- None required

**Headers:**
- `Authorization: Nostr <signed_event>` (optional): For accessing private rooms

**Response:**
```json
{
  "rooms": [
    {
      "id": "main",
      "name": "Public Chat",
      "description": "Main chat room",
      "type": "main",
      "visibility": "PUBLIC",
      "participants": ["*"],
      "lastMessage": "2025-12-09T10:30:00Z",
      "folder": "main"
    }
  ],
  "total": 1,
  "authenticated": false
}
```

**Room Types:**
- `main`: Primary chat room (daily message files)
- `direct`: Direct message channel
- `group`: Custom group channel

**Visibility Levels:**
- `PUBLIC`: Anyone can access
- `PRIVATE`: Only device owner (admin) can access
- `RESTRICTED`: Only listed participants can access

---

### GET /api/chat/{roomId}/messages

Get messages from a chat room.

**Path Parameters:**
- `roomId`: The channel ID (e.g., "main", "direct-CR7BBQ")

**Query Parameters:**
- `limit` (optional, default 50, max 500): Number of messages to return
- `before` (optional): ISO timestamp - get messages before this time
- `after` (optional): ISO timestamp - get messages after this time

**Headers:**
- `Authorization: Nostr <signed_event>` (required for non-public rooms)

**Response:**
```json
{
  "roomId": "main",
  "messages": [
    {
      "author": "CR7BBQ",
      "timestamp": "2025-12-09 10:30_15",
      "content": "Hello everyone!",
      "npub": "npub1abc...",
      "signature": "abc123...",
      "verified": true,
      "hasFile": false,
      "file": null,
      "hasLocation": true,
      "latitude": 38.7223,
      "longitude": -9.1393,
      "metadata": {},
      "reactions": {
        "thumbs-up": ["X1AAA", "X1BBB"],
        "heart": ["X1CCC"]
      }
    }
  ],
  "count": 1,
  "hasMore": false,
  "limit": 50
}
```

**Error Responses:**
- `403 Forbidden`: Access denied (includes hint for authentication)
- `404 Not Found`: Room doesn't exist or chat service not initialized

---

### POST /api/chat/{roomId}/messages

Post a new message to a chat room.

**Path Parameters:**
- `roomId`: The channel ID

#### Option A: As Device Owner (Simple)

Post a message as the device's own identity:

```json
{
  "content": "Hello from the API!"
}
```

This uses the device's callsign and npub automatically.

#### Option B: As External User (NOSTR-signed)

Post a message with a NOSTR-signed event:

```json
{
  "event": {
    "id": "abc123...",
    "pubkey": "def456...",
    "created_at": 1733745015,
    "kind": 1,
    "tags": [
      ["t", "chat"],
      ["room", "main"],
      ["callsign", "X1ABCD"]
    ],
    "content": "Hello from NOSTR!",
    "sig": "789xyz..."
  }
}
```

**Event Requirements:**
- `kind` must be `1` (text note)
- `sig` must be a valid BIP-340 Schnorr signature
- Optional `room` tag should match the roomId
- Optional `callsign` tag sets the author name (otherwise derived from npub)

**Response:**
```json
{
  "success": true,
  "timestamp": "2025-12-09 10:30_15",
  "author": "X1ABCD",
  "eventId": "abc123..."
}
```

**Error Responses:**
- `400 Bad Request`: Missing content/event, content too long, invalid event kind
- `403 Forbidden`: Invalid signature, author not authorized, room is read-only
- `404 Not Found`: Room doesn't exist

---

### DELETE /api/chat/{roomId}/messages/{timestamp}

Delete a message by its timestamp. Only the original author can delete their own messages. Moderators can also delete any message.

**Path Parameters:**
- `roomId`: The channel ID
- `timestamp`: Message timestamp (URL-encoded format: `YYYY-MM-DD%20HH%3AMM_ss`)

**Headers:**
- `Authorization: Nostr <signed_event>` (required): NOSTR event with action tags

**Authorization Event Requirements:**
The NOSTR event must include specific tags:
- `["action", "delete"]` - Indicates delete action
- `["room", "{roomId}"]` - Must match the roomId in the URL
- `["timestamp", "{timestamp}"]` - Must match the timestamp in the URL (optional but recommended)

**Example Event:**
```json
{
  "pubkey": "author_hex_pubkey",
  "created_at": 1733923456,
  "kind": 1,
  "tags": [
    ["t", "chat"],
    ["action", "delete"],
    ["room", "main"],
    ["timestamp", "2025-12-11 14:30_25"]
  ],
  "content": "Deleting message",
  "sig": "hex_signature"
}
```

**Response:**
```json
{
  "success": true,
  "action": "delete",
  "roomId": "main",
  "deleted": {
    "timestamp": "2025-12-11 14:30_25",
    "author": "CR7BBQ"
  }
}
```

**Error Responses:**
- `403 Forbidden`: Invalid NOSTR signature, not authorized (not author or moderator)
- `404 Not Found`: Message not found

---

### POST /api/chat/{roomId}/messages/{timestamp}/reactions

Toggle a reaction on a message. The same callsign cannot appear twice for the same reaction type.

**Path Parameters:**
- `roomId`: The channel ID
- `timestamp`: Message timestamp (URL-encoded format: `YYYY-MM-DD%20HH%3AMM_ss`)

**Headers:**
- `Authorization: Nostr <signed_event>` (required): NOSTR event with reaction tags

**Authorization Event Requirements:**
The NOSTR event must include specific tags:
- `["action", "react"]`
- `["room", "{roomId}"]`
- `["timestamp", "{timestamp}"]`
- `["reaction", "{reactionName}"]` (e.g., `thumbs-up`, `heart`)
- `["callsign", "{yourCallsign}"]`

**Example Event:**
```json
{
  "pubkey": "author_hex_pubkey",
  "created_at": 1733923456,
  "kind": 1,
  "tags": [
    ["t", "chat"],
    ["action", "react"],
    ["room", "main"],
    ["timestamp", "2025-12-11 14:30_25"],
    ["reaction", "thumbs-up"],
    ["callsign", "X1AAA"]
  ],
  "content": "react",
  "sig": "hex_signature"
}
```

**Response:**
```json
{
  "success": true,
  "roomId": "main",
  "timestamp": "2025-12-11 14:30_25",
  "reaction": "thumbs-up",
  "reactions": {
    "thumbs-up": ["X1AAA", "X1BBB"],
    "heart": ["X1CCC"]
  }
}
```

**Notes:**
- Reactions are stored as unsigned lines in the message file (outside the signed block).
- The endpoint toggles the user's callsign for the requested reaction.

**Error Responses:**
- `403 Forbidden`: Invalid NOSTR signature or not authorized
- `404 Not Found`: Message not found

---

### PUT /api/chat/{roomId}/messages/{timestamp}

Edit a message by its timestamp. Only the original author can edit their own messages. Moderators cannot edit other users' messages.

**Path Parameters:**
- `roomId`: The channel ID
- `timestamp`: Message timestamp (URL-encoded format: `YYYY-MM-DD%20HH%3AMM_ss`)

**Headers:**
- `Authorization: Nostr <signed_event>` (required): NOSTR event with action tags

**Authorization Event Requirements:**
The NOSTR event must include specific tags and the new content:
- `["action", "edit"]` - Indicates edit action
- `["room", "{roomId}"]` - Must match the roomId in the URL
- `["timestamp", "{timestamp}"]` - Must match the timestamp in the URL (optional but recommended)
- `["callsign", "{callsign}"]` - Author's callsign (optional, verified against message author)
- `content`: The new message content

**Important:** The event `sig` (signature) becomes the new signature for the edited message, and is stored in the message metadata.

**Example Event:**
```json
{
  "pubkey": "author_hex_pubkey",
  "created_at": 1733923500,
  "kind": 1,
  "tags": [
    ["t", "chat"],
    ["action", "edit"],
    ["room", "main"],
    ["timestamp", "2025-12-11 14:30_25"],
    ["callsign", "CR7BBQ"]
  ],
  "content": "Updated message content here",
  "sig": "new_hex_signature"
}
```

**Response:**
```json
{
  "success": true,
  "action": "edit",
  "roomId": "main",
  "edited": {
    "timestamp": "2025-12-11 14:30_25",
    "author": "CR7BBQ",
    "edited_at": "2025-12-11 15:00_10"
  }
}
```

**Storage Format After Edit:**
```
> 2025-12-11 14:30_25 -- CR7BBQ
Updated message content here
--> edited_at: 2025-12-11 15:00_10
--> npub: npub1qqq...
--> signature: new_hex_signature_for_updated_content
```

**Error Responses:**
- `400 Bad Request`: Empty content
- `403 Forbidden`: Invalid NOSTR signature, not authorized (not the author)
- `404 Not Found`: Message not found

---

### GET /api/chat/{roomId}/files

List files attached to messages in a chat room.

**Path Parameters:**
- `roomId`: The channel ID

**Headers:**
- `Authorization: Nostr <signed_event>` (required for non-public rooms)

**Response:**
```json
{
  "roomId": "main",
  "files": [
    {
      "name": "abc123def456_photo.jpg",
      "size": 12345,
      "year": "2025",
      "modified": "2025-12-09T10:30:00Z"
    }
  ],
  "total": 1
}
```

**Note:** Files are stored with a SHA1 prefix for deduplication: `{sha1}_{originalname}`

---

## Access Control

### Room Visibility

| Visibility | Who Can Access |
|------------|----------------|
| PUBLIC | Anyone |
| PRIVATE | Admin (device owner) only |
| RESTRICTED | Admin + listed participants |

### Participants

The `participants` field in channel config determines who can access restricted rooms:
- `["*"]` - Open to all authenticated users
- `["CR7BBQ", "X1ABCD"]` - Only listed callsigns

Participant callsigns are mapped to npubs via the `extra/participants.json` file.

### Admin Access

The admin npub (stored in `extra/security.json`) has full access to all rooms.

---

## Examples

### curl: List Public Rooms
```bash
curl http://localhost:3456/api/chat/
```

### curl: Get Messages with Limit
```bash
curl "http://localhost:3456/api/chat/main/messages?limit=100"
```

### curl: Post Message as Device
```bash
curl -X POST http://localhost:3456/api/chat/main/messages \
  -H "Content-Type: application/json" \
  -d '{"content": "Hello from curl!"}'
```

### JavaScript: Authenticated Request
```javascript
// Create and sign a NOSTR event for authentication
const event = createNostrEvent({
  kind: 1,
  content: "auth",
  tags: [["t", "auth"]],
  createdAt: Math.floor(Date.now() / 1000)
});
signEvent(event, privateKey);

// Make authenticated request
fetch("http://localhost:3456/api/chat/", {
  headers: {
    "Authorization": "Nostr " + btoa(JSON.stringify(event))
  }
});
```

### JavaScript: Post NOSTR-signed Message
```javascript
const messageEvent = createNostrEvent({
  kind: 1,
  content: "Hello from JavaScript!",
  tags: [
    ["t", "chat"],
    ["room", "main"],
    ["callsign", "X1ABCD"]
  ],
  createdAt: Math.floor(Date.now() / 1000)
});
signEvent(messageEvent, privateKey);

fetch("http://localhost:3456/api/chat/main/messages", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ event: messageEvent })
});
```

---

## Message Format

Messages are stored in the Geogram chat format:

```
> 2025-12-09 10:30_15 -- CR7BBQ
Hello everyone!
--> npub: npub1abc...
--> signature: abc123...
```

**Common metadata fields:**

- `file`: Attached filename stored under the room `files/` folder
- `quote`: Timestamp of the quoted message (`YYYY-MM-DD HH:MM_ss`)
- `quote_author`: Callsign of the quoted message author
- `quote_excerpt`: Short excerpt for display
- `edited_at`: Timestamp of last edit

**Example with attachment + quote:**
```
> 2025-12-09 10:30_15 -- CR7BBQ
Photo from the event
--> file: abc123def456_photo.jpg
--> quote: 2025-12-08 18:10_02
--> quote_author: X1ABCD
--> quote_excerpt: See you there?
--> npub: npub1abc...
--> signature: abc123...
```

**Images:** Image files are attached as normal files. Clients can render them inline when the extension is an image type (`.jpg`, `.png`, `.gif`, `.webp`, etc.).

**Hidden messages (client-only):** Hidden messages are stored locally per collection in `extra/hidden_messages.json` using `{timestamp}|{author}` keys. This is not synchronized via the API.

See [Chat Format Specification](../../central/docs/collections/types/chat-format-specification.md) for details.

---

## Moderation & Roles

### GET /api/chat/{roomId}/roles

Returns the role map for a room (requires NOSTR auth).

**Response:**
```json
{
  "roomId": "main",
  "role": "moderator",
  "owner": "npub1...",
  "admins": ["npub1..."],
  "moderators": ["npub1..."],
  "members": ["npub1..."]
}
```

### POST /api/chat/{roomId}/promote

Promote a member to moderator/admin. Requires a NOSTR event with:
- `["action","promote"]`
- `["target","npub1..."]`
- `["role","moderator|admin"]`

### POST /api/chat/{roomId}/demote

Demote a member. Requires:
- `["action","demote"]`
- `["target","npub1..."]`

### POST /api/chat/{roomId}/ban/{npub}

Ban a member. Requires:
- `["action","ban"]`
- `["target","npub1..."]` (optional if provided in URL)

### DELETE /api/chat/{roomId}/ban/{npub}

Unban a member. Requires:
- `["action","unban"]`
- `["target","npub1..."]` (optional if provided in URL)

## Security Considerations

1. **Signature Verification**: All NOSTR events are verified before trusting the identity
2. **Replay Prevention**: Auth events must be within 5 minutes of current time
3. **Path Traversal**: Room IDs are validated to prevent directory traversal attacks
4. **Content Limits**: Message content length is limited by channel config (`maxSizeText`)
5. **Read-Only Rooms**: Some rooms may be configured as read-only

---

## Related Documentation

- [Security Settings](security-settings.md) - HTTP API and Debug API configuration
- [API Documentation](api/API.md) - General API overview
