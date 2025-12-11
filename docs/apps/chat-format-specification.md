# Chat Format Specification

**Version**: 1.2
**Last Updated**: 2025-12-11
**Status**: Active

## Table of Contents

- [Overview](#overview)
- [File Organization](#file-organization)
- [Message Format](#message-format)
- [Metadata Field Types](#metadata-field-types)
- [NOSTR Integration](#nostr-integration)
- [NOSTR Event Reconstruction](#nostr-event-reconstruction)
- [Complete Message Examples](#complete-message-examples)
- [Full File Example](#full-file-example)
- [Parsing Implementation](#parsing-implementation)
- [File Operations](#file-operations)
- [Validation Rules](#validation-rules)
- [Best Practices](#best-practices)
- [Extensions and Future Considerations](#extensions-and-future-considerations)
- [Error Handling](#error-handling)
- [Security Considerations](#security-considerations)
- [Related Documentation](#related-documentation)
- [Change Log](#change-log)

## Overview

This document specifies the text-based markdown format used for storing chat conversations in the Geogram system. Chat files use a human-readable plain text format with structured metadata support.

Messages can optionally be cryptographically signed using NOSTR-compatible signatures (Schnorr signatures on secp256k1 curve) to provide authenticity verification and message integrity.

## File Organization

### Directory Structure

```
{module_root}/
├── config.json          # Chat configuration
├── 2025/               # Year directory
│   ├── 2025-01-15_chat.txt
│   ├── 2025-01-16_chat.txt
│   └── files/          # Attached files
└── 2024/
    └── 2024-12-31_chat.txt
```

### File Naming Convention

- **Pattern**: `YYYY-MM-DD_chat.txt`
- **Examples**:
  - `2025-09-07_chat.txt`
  - `2025-11-20_chat.txt`
- **Location**: Files are organized in year subdirectories

### Configuration File

The `config.json` file defines chat properties:

```json
{
  "id": "chat",
  "name": "Public chat",
  "description": "Leave your comments here",
  "visibility": "PUBLIC",
  "readonly": false,
  "file_upload": true,
  "files_per_post": 3,
  "max_file_size": 1,
  "max_size_text": 126,
  "moderators": []
}
```

## Message Format

### Basic Structure

```
# CALLSIGN: Title

> YYYY-MM-DD HH:MM_ss -- AUTHOR_CALLSIGN
Message content goes here.
This can span multiple lines.
--> metadata_key: metadata_value
--> another_key: another_value

> YYYY-MM-DD HH:MM_ss -- ANOTHER_AUTHOR
Another message content.
```

### Header Section

**Format**: `# ROOM_ID: Title`

- **ROOM_ID**: The chat room identifier (e.g., `general`, `announcements`)
- **Title**: Descriptive title for this chat day (typically `Chat from YYYY-MM-DD`)
- **Required**: Yes (first line of file)
- **Occurrence**: Once per file

**Important**: The header uses the **room ID**, not the owner's callsign. This is critical because the room ID is included in NOSTR event tags when signing messages. Using the room ID in the header ensures that signatures remain valid even if room metadata changes.

**Examples**:
```
# general: Chat from 2025-09-07
# announcements: Chat from 2025-11-20
# team-alpha: Chat from 2025-12-01
```

**Validation Rules**:
- Room ID should match the directory name containing the chat file
- Title is free-form text (conventionally `Chat from YYYY-MM-DD`)
- Line must start with `# ` (hash followed by space)

### Message Block

Each message consists of:
1. Message header (timestamp and author)
2. Content (one or more lines)
3. Metadata (optional, zero or more lines)

#### Message Header

**Format**: `> YYYY-MM-DD HH:MM_ss -- CALLSIGN`

**Components**:
- `>` - Message start indicator
- `YYYY-MM-DD` - Date (zero-padded)
- ` ` (space)
- `HH:MM_ss` - Time with underscore separator (zero-padded)
- ` -- ` - Separator (space-dash-dash-space)
- `CALLSIGN` - Author's callsign

**Examples**:
```
> 2025-09-07 19:10_12 -- X135AS
> 2025-11-20 08:03_45 -- CR7BBQ
> 2025-12-31 23:59_59 -- ALPHA1
```

**Parsing Rules**:
- Timestamp occupies exactly 19 characters: `YYYY-MM-DD HH:MM_ss`
- Separator ` -- ` starts at character 20
- Callsign starts at character 24
- No index numbers (e.g., `[001]`) are used

#### Message Content

- **Location**: Lines immediately following the message header
- **Format**: Plain text, multi-line supported
- **Termination**: Content ends when a metadata line or next message starts
- **Empty Content**: Allowed (for metadata-only messages)

**Examples**:
```
> 2025-09-07 19:10_16 -- CR7BBQ
Hey, what's up! :-)

> 2025-09-07 19:23_43 -- X135AS
That's nice to hear.
Thanks for the update.
Looking forward to meeting you!
```

#### Metadata Lines

**Format**: `--> key: value`

**Components**:
- `--> ` - Metadata indicator (dash-dash-gt-space)
- `key` - Metadata field name (no colons)
- `: ` - Separator (colon-space)
- `value` - Metadata value (free-form text)

**Location**: After message content, before next message

**Multiple Metadata**: Multiple metadata lines are allowed per message

**Examples**:
```
> 2025-09-07 19:10_16 -- CR7BBQ
Come on! Please vote!
--> file: please_please.png
--> lat: 38.7223
--> lon: -9.1393
```

## Metadata Field Types

### Standard Metadata Fields

#### Location Metadata

**Purpose**: GPS coordinates for geo-tagged messages

**Fields**:
- `lat`: Latitude in decimal degrees (-90 to 90)
- `lon`: Longitude in decimal degrees (-180 to 180)

**Example**:
```
> 2025-09-07 15:30_00 -- CR7BBQ
Meeting at the park entrance.
--> lat: 38.7223
--> lon: -9.1393
```

#### File Attachments

**Purpose**: Reference to attached files

**Field**: `file: filename`

**Storage**: Files stored in `files/` subdirectory

**Example**:
```
> 2025-09-07 19:10_16 -- CR7BBQ
Check out this photo!
--> file: sunset_beach.jpg
```

#### Voice Messages

**Purpose**: Audio voice message recordings

**Fields**:
- `voice`: Filename of voice recording in `files/` subdirectory
- `duration`: Duration in seconds (for display without decoding)

**Storage**: Voice files stored in `files/` subdirectory

**File Format**:
- Preferred: Opus codec in WebM container (`.webm`)
- Fallback: AAC in M4A container (`.m4a`)
- Encoding: 16 kHz mono, 12 kbps bitrate
- Maximum duration: 30 seconds (~45 KB)

**Filename Convention**: `voice_{YYYYMMDD}_{HHMMSS}.webm`

**Example**:
```
> 2025-12-11 14:30_25 -- X1ABCD
--> voice: voice_20251211_143025.webm
--> duration: 12
```

**Notes**:
- Voice messages typically have empty content
- Duration is stored to display playback controls without decoding
- Files must be fully downloaded before playback (no streaming)
- No autoplay - user must tap to play

#### Reactions

**Purpose**: Like/emoji reactions from other users

**Format**: `icon_like: CALLSIGN1, CALLSIGN2`

**Example**:
```
> 2025-09-07 19:10_12 -- X135AS
That's nice to hear.
--> icon_like: CR7BBQ, ALPHA1
```

#### Message References

**Purpose**: Quote or reply to another message

**Format**: `quote: TIMESTAMP` or `reply: TIMESTAMP`

**Example**:
```
> 2025-09-07 19:23_43 -- X135AS
Maybe later
--> quote: 2025-09-07 19:10_16
```

#### Polls

**Purpose**: Create a poll with options and track votes

**Fields**:
- `Poll: Question text`
- `votes: CALLSIGN1=option; CALLSIGN2=option`
- `deadline: HH:MM_ss`

**Example**:
```
> 2025-09-07 19:10_16 -- CR7BBQ
--> Poll: When do we have lunch?
[1] 12:00
[2] 12:15
[3] 13:00
--> votes: X1343=1; X143E1S=3
--> deadline: 20:00_00
```

**Notes**:
- Poll options are listed in message content
- Votes format: `CALLSIGN=OPTION_NUMBER` separated by semicolons
- Deadline uses time format `HH:MM_ss`

#### Message Signatures (Optional)

**Purpose**: Cryptographic verification of message authenticity using NOSTR-style signing

**Stored Fields** (minimal format):
- `npub: bech32_public_key` - Author's NOSTR public key
- `signature: hex_signature` - BIP-340 Schnorr signature
- `created_at: unix_timestamp` - Unix timestamp in seconds (optional but recommended)

**Calculated Fields** (not stored, reconstructed at runtime):
- `event_id` - SHA256 hash of serialized NOSTR event (deterministic)
- `verified` - Boolean result of signature verification

**Note on created_at**: While the message timestamp in the header (`YYYY-MM-DD HH:MM_ss`) can be converted to Unix seconds, storing the exact `created_at` value used during signing ensures signature verification works correctly. This is especially important when messages are synced between devices, as the `created_at` must match exactly for the event ID calculation to produce the same result.

**Optional**: Yes - messages may be signed or unsigned

**Position**: When present, `npub` should be placed immediately before `signature`, and `signature` **MUST be the last metadata field**

**Storage Philosophy**:

The storage format is intentionally minimal. Only two fields are persisted:
1. **npub**: The author's public key (bech32 encoded, human-readable)
2. **signature**: The BIP-340 Schnorr signature (hex encoded)

All other NOSTR-related fields can be reconstructed from the stored data:
- **event_id**: Calculated from SHA256 of `[0, pubkey, created_at, kind, tags, content]`
- **verified**: Result of signature verification against reconstructed event
- **pubkey**: Derived from npub using bech32 decoding

This approach ensures:
- Smaller file sizes
- No redundant data storage
- Ability to produce valid NOSTR events on demand
- Signature validity is always fresh (verified at read time)

**Signing Process**:

1. Create a NOSTR event structure with:
   - `pubkey`: hex-encoded public key (from npub)
   - `created_at`: Unix timestamp
   - `kind`: 1 (text note)
   - `tags`: `[['t', 'chat'], ['room', roomId], ['callsign', callsign]]`
   - `content`: message text
2. Calculate event ID: SHA256 of serialized `[0, pubkey, created_at, kind, tags, content]`
3. Sign the event ID with the author's private key (nsec)
4. Store only `npub` and `signature` in the chat file

**Verification Process**:

1. Extract `npub` and `signature` from metadata
2. Reconstruct the NOSTR event using stored data:
   - Derive `pubkey` from `npub`
   - Use message timestamp for `created_at`
   - Use room ID from file header for tags
   - Use sender callsign from message header
3. Calculate event ID from reconstructed event
4. Verify signature using BIP-340 Schnorr verification
5. Cache verification result for display

**Important Notes**:
- The signature MUST always be the last metadata field
- When both `npub` and `signature` are present, `npub` should be placed immediately before `signature`
- Room ID from the file header is used in NOSTR event tags - changing it would invalidate signatures
- Authors need both `npub` (public key) and `nsec` (private key) for signing
- Verifiers only need the author's `npub` (public key)

**Example (Unsigned)**:
```
> 2025-09-07 19:10_16 -- CR7BBQ
Hey, what's up! :-)
--> lat: 38.7223
--> lon: -9.1393
```

**Example (Signed)**:
```
> 2025-09-07 19:10_16 -- CR7BBQ
Hey, what's up! :-)
--> lat: 38.7223
--> lon: -9.1393
--> signature: 3a4f8c92e1b5d6a7f2e9c4b8d1a6e3f9c2b5e8a1d4f7c0b3e6a9d2f5c8e1b4a7
```

**Signed Content** (what gets hashed when npub is included):
```
> 2025-09-07 19:10_16 -- CR7BBQ
Hey, what's up! :-)
--> lat: 38.7223
--> lon: -9.1393
--> npub: npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq3z0qwe
```

**Note**: The `npub` line is included in the signed content. Only the `signature` line itself is excluded from signing.

**Author Identity**:
- The author's `npub` may be included in a separate `npub` metadata field
- Or derived from the callsign if there's a callsign-to-npub mapping
- The `npub` is required for signature verification
- **When both `npub` and `signature` are present, `npub` should be placed immediately before `signature`**

**Example with npub**:
```
> 2025-09-07 19:10_16 -- CR7BBQ
Hey, what's up! :-)
--> lat: 38.7223
--> lon: -9.1393
--> created_at: 1725735016
--> npub: npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq3z0qwe
--> signature: 3a4f8c92e1b5d6a7f2e9c4b8d1a6e3f9c2b5e8a1d4f7c0b3e6a9d2f5c8e1b4a7
```

**Security Considerations**:
- Never share or transmit the `nsec` (private key)
- The `npub` (public key) is safe to share publicly
- Unsigned messages should be treated as unverified
- Modified signed messages will fail verification
- Signature verification confirms authenticity and integrity

**Implementation Requirements**:
- Use NOSTR-compatible signature algorithms (Schnorr signatures on secp256k1)
- Hex-encode the signature for text representation
- Preserve exact message formatting for verification
- Support both signed and unsigned messages
- Display verification status to users

#### Custom Metadata

**Purpose**: Application-specific or experimental fields

**Format**: Any key-value pair not in standard fields

**Example**:
```
--> priority: high
--> category: announcement
--> visibility: members_only
```

**Metadata Ordering**:
- Regular metadata fields first
- `npub` field (if present) should be placed just before `signature`
- `signature` field (if present) MUST be the last metadata field

## NOSTR Integration

### Overview

Geogram chat messages can be cryptographically signed using the same algorithms as NOSTR (Notes and Other Stuff Transmitted by Relays). This provides:

- **Authenticity**: Verify that a message was created by the claimed author
- **Integrity**: Confirm that the message hasn't been tampered with
- **Non-repudiation**: Authors cannot deny sending a signed message

### Key Management

#### NOSTR Keys

- **nsec** (Private Key): Used for signing messages, must be kept secret
- **npub** (Public Key): Used for verifying signatures, safe to share publicly

**Format**:
- `nsec1...` - Bech32-encoded private key (51 characters)
- `npub1...` - Bech32-encoded public key (63 characters)

#### Key Storage

- Authors store their `nsec` locally in secure storage
- The `npub` can be included in message metadata or mapped from callsign
- Never transmit or store `nsec` in chat files

#### Callsign-to-NOSTR Mapping

Applications may maintain a mapping between APRS callsigns and NOSTR public keys:

```json
{
  "CR7BBQ": "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq3z0qwe",
  "X135AS": "npub1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa5z9xyz",
  "ALPHA1": "npub1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb6a8abc"
}
```

### Signature Algorithm

**Algorithm**: Schnorr signatures on secp256k1 curve (same as Bitcoin and NOSTR)

**Process**:

1. **Prepare Content**:
   - Extract all text from `>` (message start) through the last metadata field before signature
   - Include all newlines exactly as they appear
   - Do NOT include the `--> signature:` line

2. **Create Hash**:
   - Use SHA-256 to hash the content
   - Result is a 32-byte digest

3. **Sign**:
   - Use the author's `nsec` (private key) to create Schnorr signature
   - Result is a 64-byte signature

4. **Encode**:
   - Convert signature to lowercase hexadecimal string (128 characters)
   - Append as `--> signature: <hex_string>`

### Verification Algorithm

**Process**:

1. **Extract Signature**:
   - Read the `signature` metadata value
   - Decode from hexadecimal to bytes

2. **Reconstruct Content**:
   - Extract all message text before the signature line
   - Must match exactly (including newlines, spaces, etc.)

3. **Verify**:
   - Obtain author's `npub` (from metadata or mapping)
   - Use Schnorr signature verification algorithm
   - Verify the signature against the content hash

4. **Result**:
   - **Valid**: Signature is correct, message is authentic
   - **Invalid**: Signature doesn't match, message may be tampered
   - **Missing**: Message is unsigned (not necessarily suspicious)
   - **Error**: Cannot verify (missing npub, malformed signature, etc.)

### Implementation Example

**Signing a Message** (Pseudocode):

```
content = "> 2025-09-07 19:10_16 -- CR7BBQ\n"
content += "Hey, what's up! :-)\n"
content += "--> lat: 38.7223\n"
content += "--> lon: -9.1393\n"
content += "--> npub: npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq3z0qwe"

hash = SHA256(content)
signature = schnorr_sign(hash, nsec)
hex_sig = bytes_to_hex(signature)

message = content + "\n--> signature: " + hex_sig
```

**Note**: The `npub` is included in the signed content before adding the signature.

**Verifying a Message** (Pseudocode):

```
lines = message.split("\n")
sig_line = find_line_starting_with("--> signature:")
sig_hex = extract_value_after_colon(sig_line)

content = reconstruct_content_before(sig_line)
hash = SHA256(content)
signature = hex_to_bytes(sig_hex)

npub = get_author_npub(author_callsign)
is_valid = schnorr_verify(hash, signature, npub)
```

### Libraries and Tools

**Recommended Libraries**:
- **Java**: `fr.acinq.secp256k1` or `java-nostr` libraries
- **JavaScript**: `nostr-tools` or `@noble/secp256k1`
- **Python**: `secp256k1` or `nostr` packages
- **Go**: `github.com/nbd-wtf/go-nostr`

**NOSTR Specification**: NIP-01 (NOSTR Implementation Possibilities - Event Signing)

### User Experience

#### For Message Authors

1. **Enable Signing**: User opts-in to sign their messages
2. **Key Setup**: Generate or import `nsec`/`npub` pair
3. **Automatic Signing**: All messages automatically signed when posting
4. **Verification Indicator**: See which of your messages are verified

#### For Message Readers

1. **Verification Badge**: Visual indicator for verified messages (✓, checkmark, badge)
2. **Unsigned Messages**: No indicator or neutral icon
3. **Invalid Signatures**: Warning indicator (⚠, alert icon)
4. **Trust Building**: Learn which authors consistently sign their messages

### Security Best Practices

1. **Never Share nsec**: Private keys must remain private
2. **Verify Important Messages**: Always check signature on critical announcements
3. **Multiple Devices**: Sync `nsec` securely or use different keys per device
4. **Key Backup**: Backup `nsec` securely (encrypted, offline storage)
5. **Treat Unsigned as Unverified**: Don't assume authenticity without signature
6. **Check First Message**: Verify author's first signed message carefully
7. **Man-in-the-Middle**: Be aware someone could intercept and strip signatures

## NOSTR Event Reconstruction

### Overview

The chat storage format stores only the minimal data needed to reconstruct valid NOSTR events. This section describes how to produce NOSTR-compatible JSON from the markdown storage format.

### Storage Format Example

A signed message is stored as:

```
# general: Chat from 2025-12-04

> 2025-12-04 15:12:23 -- TESTCALL
Hello from the markdown format!
--> npub: npub1zv3k2dhzaffqe9xycu0lt0cmfcs3knlr3n2gaevpnq0pwj3dmd9sxzh6w0
--> signature: f6f6c590b4811056fe8bab66100c4082a6ce5123bba704357354107c9f9a042c56d4d3227d370cab243ecb5936def5250f3f6c535f53e01c5ae380975d284641
```

### Reconstruction Algorithm

To reconstruct a valid NOSTR event from stored data:

```
1. Parse the file header to extract roomId: "general"
2. Parse the message header to extract:
   - timestamp: 2025-12-04 15:12:23
   - callsign: "TESTCALL"
3. Parse metadata to extract:
   - npub: "npub1zv3k2dhzaffqe9xycu0lt0cmfcs3knlr3n2gaevpnq0pwj3dmd9sxzh6w0"
   - created_at: 1733325143 (if present, use this; otherwise convert timestamp)
   - signature: "f6f6c590..."
4. Derive pubkey from npub using bech32 decoding:
   - pubkey: "13236536e2ea520c94c4c71ff5bf1b4e211b4fe38cd48ee581981e174a2ddb4b"
5. Determine created_at value:
   - If `created_at` metadata exists: use that exact value
   - Otherwise: convert message timestamp to Unix seconds
6. Construct the NOSTR event:
   - pubkey: derived hex pubkey
   - created_at: Unix timestamp (from step 5)
   - kind: 1 (text note)
   - tags: [['t', 'chat'], ['room', 'general'], ['callsign', 'TESTCALL']]
   - content: "Hello from the markdown format!"
   - sig: stored signature
7. Calculate event ID:
   - Serialize: [0, pubkey, created_at, kind, tags, content]
   - Hash: SHA256 of JSON-serialized array
   - Result: "ca24e74d687916ebe65275125119af9a6cdf3e96cd53cd4cba881d80c951084c"
8. Verify signature using BIP-340 Schnorr verification
```

**Important**: The `created_at` value MUST match exactly what was used during signing. Storing the `created_at` metadata ensures this, especially when syncing messages between devices.

### Reconstructed NOSTR Event (JSON)

The resulting valid NOSTR event:

```json
{
  "id": "ca24e74d687916ebe65275125119af9a6cdf3e96cd53cd4cba881d80c951084c",
  "pubkey": "13236536e2ea520c94c4c71ff5bf1b4e211b4fe38cd48ee581981e174a2ddb4b",
  "created_at": 1733325143,
  "kind": 1,
  "tags": [
    ["t", "chat"],
    ["room", "general"],
    ["callsign", "TESTCALL"]
  ],
  "content": "Hello from the markdown format!",
  "sig": "f6f6c590b4811056fe8bab66100c4082a6ce5123bba704357354107c9f9a042c56d4d3227d370cab243ecb5936def5250f3f6c535f53e01c5ae380975d284641"
}
```

### Implementation Reference

```dart
NostrEvent? reconstructNostrEvent({
  required String? npub,
  required String content,
  required String? signature,
  required String roomId,
  required String callsign,
  required DateTime timestamp,
}) {
  if (npub == null || npub.isEmpty) return null;
  if (signature == null || signature.isEmpty) return null;

  // Derive hex pubkey from bech32 npub
  final pubkey = NostrCrypto.decodeNpub(npub);
  final createdAt = timestamp.millisecondsSinceEpoch ~/ 1000;

  final event = NostrEvent(
    pubkey: pubkey,
    createdAt: createdAt,
    kind: 1,
    tags: [['t', 'chat'], ['room', roomId], ['callsign', callsign]],
    content: content,
    sig: signature,
  );

  // Calculate the deterministic event ID
  event.calculateId();

  return event;
}
```

### Key Points

1. **Room ID is Critical**: The room ID from the file header is used in NOSTR event tags. Changing the room ID would produce a different event ID and invalidate all signatures.

2. **Timestamp Precision**: The timestamp is converted to Unix seconds (not milliseconds) for NOSTR compatibility.

3. **Deterministic ID**: The event ID is always the same for the same input data - it's a SHA256 hash of the serialized event structure.

4. **Verification at Read Time**: Signatures are verified when messages are loaded, not stored as a boolean. This ensures verification is always fresh.

5. **NOSTR Compatibility**: The reconstructed events are fully compatible with NOSTR relays and clients that support NIP-01.

## Complete Message Examples

### Simple Message

```
# general: Chat from 2025-09-07

> 2025-09-07 19:10_12 -- X135AS
Hello there!

> 2025-09-07 19:10_16 -- CR7BBQ
Hey, what's up! :-)
```

### Message with Reaction

```
> 2025-09-07 19:10_12 -- X135AS
That's nice to hear.
--> icon_like: CR7BBQ
```

### Message with File Attachment

```
> 2025-09-07 19:10_16 -- CR7BBQ
Check out this image!
--> file: please_please.png
```

### Message with Location

```
> 2025-09-07 15:30_00 -- CR7BBQ
I'm here at the coordinates below.
--> lat: 38.7223
--> lon: -9.1393
```

### Poll Message

```
> 2025-09-07 19:10_16 -- CR7BBQ
--> Poll: When do we have lunch?
[1] 12:00
[2] 12:15
[3] 13:00
--> votes: X1343=1; X143E1S=3
--> deadline: 20:00_00
```

### Message with Quote

```
> 2025-09-07 19:23_43 -- X135AS
Maybe later
--> quote: 2025-09-07 19:10_16
```

### Complex Message (Multiple Metadata)

```
> 2025-09-07 20:45_30 -- CR7BBQ
Thanks everyone for attending today's meeting!
Here's the summary document.
--> file: meeting_summary.pdf
--> lat: 38.7223
--> lon: -9.1393
--> priority: high
--> icon_like: X135AS, ALPHA1, BRAVO2
```

### Signed Message (Simple)

```
> 2025-09-07 21:15_00 -- CR7BBQ
This message is cryptographically signed.
--> signature: 3a4f8c92e1b5d6a7f2e9c4b8d1a6e3f9c2b5e8a1d4f7c0b3e6a9d2f5c8e1b4a7
```

### Signed Message (With Metadata)

```
> 2025-09-07 21:20_30 -- CR7BBQ
Important announcement regarding tomorrow's event.
--> priority: high
--> lat: 38.7223
--> lon: -9.1393
--> npub: npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq3z0qwe
--> signature: 2b8e7a5c4f1d9e6b3a8c7f2e5d1a4b9c8e7a6d3f0c5b2e9a7d4f1c8e5b2a9d6
```

### Mixed Signed and Unsigned Messages

```
> 2025-09-07 21:00_00 -- X135AS
This is an unsigned message.

> 2025-09-07 21:01_15 -- CR7BBQ
This is a signed message from CR7BBQ.
--> signature: 5e1a9c6f2b8d4a7e3c9f6b2e8a5d1c7f4b9e6a3d0c8e5b2f9a6d3c0e7b4a1d8

> 2025-09-07 21:02_30 -- ALPHA1
Another unsigned message.
--> file: document.pdf

> 2025-09-07 21:03_45 -- CR7BBQ
Another signed message with location.
--> lat: 38.7223
--> lon: -9.1393
--> signature: 9d6c3f0b8e5a2d9f6c3e0b7a4d1c8e5b2f9a6d3c0e7b4a1d8e5c2f9b6a3d0c7
```

## Full File Example

```
# general: Chat from 2025-09-07

> 2025-09-07 19:10_12 -- X135AS
Hello there!

> 2025-09-07 19:10_16 -- CR7BBQ
Hey, what's up! :-)
--> npub: npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq3z0qwe
--> signature: 3a4f8c92e1b5d6a7f2e9c4b8d1a6e3f9c2b5e8a1d4f7c0b3e6a9d2f5c8e1b4a7

> 2025-09-07 19:10_12 -- X135AS
That's nice to hear.
--> icon_like: CR7BBQ

> 2025-09-07 19:10_16 -- CR7BBQ
--> Poll: When do we have lunch?
[1] 12:00
[2] 12:15
[3] 13:00
--> votes: X1343=1; X143E1S=3
--> deadline: 20:00_00

> 2025-09-07 19:23_43 -- X135AS
Maybe later
--> quote: 2025-09-07 19:10_16

> 2025-09-07 19:10_16 -- CR7BBQ
Come on! Please, please, please vote!
--> file: please_please.png
--> npub: npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq3z0qwe
--> signature: 5e1a9c6f2b8d4a7e3c9f6b2e8a5d1c7f4b9e6a3d0c8e5b2f9a6d3c0e7b4a1d8
```

## Parsing Implementation

### Parser Requirements

1. **Header Parsing**:
   - Extract callsign and title from first line
   - Validate callsign format
   - Handle missing or malformed headers gracefully

2. **Message Parsing**:
   - Split file by `> 2` pattern (messages start with year 2xxx)
   - Extract timestamp (characters 0-19)
   - Extract author (after ` -- ` separator)
   - Collect content lines until metadata or next message
   - Parse metadata lines starting with `--> `

3. **Timestamp Handling**:
   - Zero-padded format: `YYYY-MM-DD HH:MM_ss`
   - Underscore separates minutes from seconds
   - Used for sorting and chronological ordering

4. **Metadata Parsing**:
   - Split on first `: ` occurrence
   - Key is everything before `: `
   - Value is everything after `: `
   - Store in key-value map
   - Detect `signature` field and ensure it's the last metadata field

5. **Signature Verification** (Optional):
   - Extract `signature` metadata value
   - Reconstruct signed content (message header + content + metadata before signature)
   - Obtain author's `npub` (from metadata or callsign mapping)
   - Verify signature using NOSTR signature verification
   - Flag verification status (verified, failed, unsigned)

### Reference Implementation

See:
- `geogram-server/src/main/java/geogram/apps/modules/chat/ChatFile.java`
- `geogram-server/src/main/java/geogram/apps/modules/chat/ChatMessage.java`

## File Operations

### Reading Messages

1. List all chat files in year directories
2. Sort by filename (chronological order)
3. Parse each file into message objects
4. Sort messages by timestamp
5. Apply filters (location radius, date range, etc.)

### Writing Messages

1. Determine year from timestamp
2. Create year directory if needed
3. Determine daily file from date
4. Parse existing file (if exists)
5. Add new message to collection
6. Sort messages by timestamp
7. Export as text format
8. Write to disk

### Appending Messages

Messages should be inserted in chronological order, not necessarily appended to the end of the file. The `ChatMessage` class implements `Comparable` for proper sorting.

## Validation Rules

### File Level

- File must start with header line
- Header must match pattern `# CALLSIGN: Title`
- Callsign must be valid APRS format
- File encoding: UTF-8

### Message Level

- Each message must have valid timestamp
- Timestamp must match format `YYYY-MM-DD HH:MM_ss`
- Author callsign must be present
- Content may be empty (for metadata-only messages)

### Metadata Level

- Each metadata line must start with `--> `
- Must contain `: ` separator
- Key cannot be empty
- Value may be empty

### Signature Validation (Optional)

- `signature` field, when present, MUST be the last metadata field
- Signature value must be valid hex string
- Signed content includes everything from `>` up to (but not including) `--> signature:`
- Verification requires author's `npub` (NOSTR public key)
- Invalid signatures should be flagged but message should still be readable

### Location Metadata

- `lat` must be valid decimal degrees (-90 to 90)
- `lon` must be valid decimal degrees (-180 to 180)
- Both required for location filtering

### File References

- Referenced files should exist in `files/` subdirectory
- Filenames should not contain path separators
- Recommended: sanitize filenames to prevent directory traversal

## Best Practices

### For Implementers

1. **Graceful Degradation**: Handle malformed messages without failing entire file
2. **Timestamp Validation**: Reject messages with invalid timestamps
3. **Sort on Read**: Always sort messages chronologically after parsing
4. **Atomic Writes**: Use temp files and atomic rename for file updates
5. **UTF-8 Encoding**: Always use UTF-8 for reading and writing
6. **Newline Consistency**: Use `\n` (LF) line endings

### For Users

1. **Unique Callsigns**: Use unique, valid APRS callsigns
2. **Accurate Timestamps**: Ensure system time is synchronized
3. **File Size**: Keep attached files reasonably sized
4. **Metadata Keys**: Use lowercase keys with underscores for consistency
5. **Content**: Keep messages concise and relevant

## Extensions and Future Considerations

### Potential Additions

1. **Encryption Metadata**: Support for encrypted messages
2. **Edit History**: Track message edits with timestamps
3. **Delete Markers**: Soft-delete with metadata marker
4. **Thread Support**: Conversation threading metadata
5. **Rich Media**: Image/video inline metadata
6. **Signatures**: Cryptographic signatures for messages

### Version Compatibility

- Current version: 1.0
- Future versions should maintain backward compatibility
- New metadata fields should be optional
- Parsers should ignore unknown metadata gracefully

## Error Handling

### Common Errors

1. **Missing Header**: Treat as empty chat or skip file
2. **Invalid Timestamp**: Skip message or use file date
3. **Malformed Metadata**: Ignore line, continue parsing
4. **Missing Author**: Skip message
5. **Invalid Location**: Ignore location metadata, keep message

### Recovery Strategies

- Log warnings for malformed content
- Continue parsing after errors
- Return partial results rather than failing completely
- Validate data on write to prevent malformed files

## Security Considerations

### Input Validation

- Sanitize callsigns (alphanumeric only)
- Validate timestamp ranges (reasonable dates)
- Check file references for path traversal attempts
- Limit message content length
- Limit metadata value lengths

### File System Safety

- Never trust user-provided filenames
- Validate year directory names
- Check file sizes before reading
- Limit total files per directory
- Implement access controls on chat directories

### Privacy

- Location metadata is sensitive
- Consider encryption for private chats
- Implement proper access controls
- Allow users to delete their messages
- Respect visibility settings in config.json

### Cryptographic Signatures

- Protect `nsec` (private keys) at all costs
- Store keys in secure, encrypted storage
- Never log or transmit private keys
- Verify signatures before trusting message content
- Display signature verification status to users
- Allow users to opt-out of signing (unsigned messages are valid)
- Implement key rotation mechanisms for compromised keys

## Related Documentation

- [Collections System](collections/README.md) - How chats integrate with collections
- [APRS Utilities](../geogram-server/src/main/java/geogram/aprs/) - Callsign validation
- [Module System](../geogram-server/src/main/java/geogram/apps/Module.java) - Chat module architecture

## Change Log

### Version 1.2 (2025-12-11)
- **Added voice message metadata fields**:
  - `voice`: Filename of voice recording in `files/` subdirectory
  - `duration`: Duration in seconds (for playback UI without decoding)
  - Preferred format: Opus/WebM (~90 KB/min, optimal for speech)
  - Fallback format: AAC/M4A (for iOS compatibility)
  - Maximum duration: 30 seconds (~45 KB max file size)
  - Filename convention: `voice_{YYYYMMDD}_{HHMMSS}.webm`

### Version 1.1 (2025-12-04)
- **Header format changed**: Now uses room ID instead of callsign
  - Format: `# {roomId}: Chat from {date}` instead of `# {callsign}: ...`
  - This ensures signatures remain valid since room ID is part of NOSTR event tags
- **Minimal storage format**: Only `npub` and `signature` are stored
  - Removed: `event_id`, `verified`, `pubkey` (all redundant, can be recalculated)
  - `event_id` is now calculated at runtime via SHA256 hash
  - `verified` is now determined at runtime via signature verification
  - `pubkey` is derived from `npub` using bech32 decoding
- **Added NOSTR Event Reconstruction section**:
  - Documents how to reconstruct valid NOSTR events from minimal storage
  - Includes algorithm, JSON example, and implementation reference
  - Explains why room ID is critical for signature validity

### Version 1.0 (2025-11-20)
- Initial specification
- Removed deprecated index numbers
- Standardized timestamp format
- Documented metadata fields
- Added validation rules and examples
- **Added NOSTR-style cryptographic signatures**:
  - Optional message signing using Schnorr signatures on secp256k1
  - Signature metadata field (must be last)
  - `npub`/`nsec` key management
  - Verification algorithm specification
  - Security best practices
  - Implementation examples and library recommendations

---

*This specification is part of the Geogram project.*
*License: Apache-2.0*
