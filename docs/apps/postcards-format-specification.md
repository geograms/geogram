# Postcards Format Specification

**Version**: 2.0
**Last Updated**: 2026-04-24
**Status**: Active

> **v2.0 key rule — SINGLE FILE.** A postcard is exactly one UTF-8 text
> file (`postcard.txt`). Header, body, stamps, receipt, return stamps,
> acknowledgment, AND attachments (base64) all live inside it. No
> sidecar JSON, no sibling image files, no `contributors/` subfolder. A
> postcard is fully self-contained so it can be copied over any
> transport (BLE frame, LoRa packet, USB drive, pasted into a chat) as
> a single blob.
>
> Every transfer appends a new NOSTR-signed block at the bottom:
> STAMP N (outbound), DELIVERY_RECEIPT, RETURN_STAMP N, or
> SENDER_ACKNOWLEDGMENT. Existing bytes are never rewritten, so the
> earlier signatures keep verifying against the content they signed.

## Table of Contents

- [Overview](#overview)
- [File Organization](#file-organization)
- [Postcard Format](#postcard-format)
- [Content Types](#content-types)
- [Attachments](#attachments)
- [Stamps System](#stamps-system)
- [Delivery Receipt](#delivery-receipt)
- [Return Journey](#return-journey)
- [Sender Acknowledgment](#sender-acknowledgment)
- [Contributor System](#contributor-system)
- [Signature Verification Chain](#signature-verification-chain)
- [Recipient Discovery](#recipient-discovery)
- [Status Tracking](#status-tracking)
- [Reactions System](#reactions-system)
- [File Management](#file-management)
- [Permissions and Roles](#permissions-and-roles)
- [Moderation System](#moderation-system)
- [NOSTR Integration](#nostr-integration)
- [Complete Examples](#complete-examples)
- [Parsing Implementation](#parsing-implementation)
- [File Operations](#file-operations)
- [Validation Rules](#validation-rules)
- [Best Practices](#best-practices)
- [Security Considerations](#security-considerations)
- [Integration with Relay System](#integration-with-relay-system)
- [Related Documentation](#related-documentation)
- [Change Log](#change-log)

## Overview

This document specifies the text-based format used for storing postcards in the Geogram system. The postcards collection type implements a sneakernet-based message delivery system where messages are physically carried from sender to recipient through one or more intermediate carriers.

Unlike traditional internet-based messaging, postcards rely on physical proximity and human mobility to deliver messages, similar to how physical mail worked before the internet age.

### Key Features

- **Sneakernet Delivery**: Messages physically carried by mobile users (carriers)
- **Cryptographic Stamps**: Each carrier stamps the postcard with signature proof
- **Chain of Custody**: Tamper-proof verification of entire journey
- **Flexible Routing**: Messages pass through multiple carriers to reach destination
- **Delivery Receipts**: Cryptographic proof of successful delivery
- **Return Journey**: Receipts can travel back to sender with acknowledgment
- **Payment Proof**: Stamps and receipts enable payment verification (external to Geogram)
- **Open or Encrypted**: Messages can be readable by carriers or encrypted
- **Geographic Routing**: Carriers select postcards based on recipient coordinates
- **Contributor System**: Carriers can add photos/notes proving transit
- **Date-Based Organization**: Organized by creation date like events
- **NOSTR Integration**: Uses npub for identities and Schnorr signatures

### Conceptual Model

Think of Geogram postcards like physical postcards sent through the postal system:

1. **Sender** writes postcard and hands it to first carrier
2. **Carriers** stamp it at each handoff (like post offices stamping mail)
3. **Recipient** receives postcard and stamps delivery receipt
4. **Receipt** travels back to sender through carriers (optionally)
5. **Sender** stamps acknowledgment confirming receipt delivery

Each stamp is cryptographically signed, creating an unbreakable chain of custody that proves:
- Who carried the message
- When and where each handoff occurred
- That the content was not tampered with
- That delivery was successful

## File Organization

### Directory Structure

```
collection_name/
└── postcards/
    ├── 2026/
    │   ├── 2026-04-24_msg-a7c5b1/
    │   │   └── postcard.txt      # Self-contained: header, body,
    │   │                         # stamps, receipt, ack, and every
    │   │                         # attachment as inline base64.
    │   ├── 2026-04-24_msg-3d8f2e/
    │   │   └── postcard.txt
    │   └── 2026-04-25_msg-9b4e6a/
    │       └── postcard.txt
    └── 2025/
        └── 2025-12-25_msg-jkl012/
            └── postcard.txt
```

Every postcard is exactly one file. The folder only exists so the
filesystem gives us a per-postcard container (for future artifacts like
thumbnails or moderation state), not so we can scatter pieces of a
single postcard across siblings.

### Postcard Folder Naming

**Pattern**: `YYYY-MM-DD_msg-{message-id}/`

**Message ID**:
- First 6 characters of SHA-256 hash of postcard content
- Lowercase hexadecimal
- Ensures uniqueness
- Human-readable identifier

**Examples**:
```
2025-11-21_msg-a7c5b1/      # Created Nov 21, 2025
2025-11-22_msg-3d8f2e/      # Created Nov 22, 2025
2024-12-25_msg-9b4e6a/      # Created Dec 25, 2024
```

### Year Organization

- **Format**: `postcards/YYYY/` (e.g., `postcards/2025/`, `postcards/2024/`)
- **Purpose**: Organize postcards by year for archival
- **Creation**: Automatically created when first postcard for that year is added
- **Benefits**: Easy year-based browsing, archival, and cleanup

### Legacy sibling folders (removed in v2.0)

Earlier drafts of this spec placed attachments in sibling files,
`contributors/` folders for each carrier, and a `.reactions/` directory
alongside `postcard.txt`. v2.0 collapses everything into the postcard
file itself:

- Attachments → inline base64 ATTACHMENT blocks (see [Attachments](#attachments)).
- Carrier narrative → the STAMP itself carries the stamper's callsign,
  coordinates, timestamp, and transmission method; richer narrative
  lives in future reactions on the postcard as a whole.
- Reactions → will be carried in reaction postcards referencing the
  parent by its message ID; not a sidecar of this file.

If you find an on-disk postcard with the old layout, read
`postcard.txt` as the authoritative source — the sidecar files are
ignored.

## Postcard Format

### Main Postcard File

Every postcard must have a `postcard.txt` file in the postcard folder root.

**Complete Structure**:
```
# POSTCARD: Message Title

CREATED: YYYY-MM-DD HH:MM_ss
SENDER_CALLSIGN: CR7BBQ
SENDER_NPUB: npub1abc123...
RECIPIENT_CALLSIGN: X135AS
RECIPIENT_NPUB: npub1xyz789...
RECIPIENT_LOCATIONS: 38.7223,-9.1393; 40.7128,-74.0060; 51.5074,-0.1278
TYPE: open|encrypted
STATUS: in-transit|delivered|acknowledged|expired
TTL: 604800
PRIORITY: normal|urgent|emergency|low

Message content goes here.
This is the actual postcard message.
Can be multiple paragraphs.

For encrypted postcards, this section contains
the NIP-04 encrypted content.

--> npub: npub1abc123...
--> signature: hex_signature

## STAMP: 1
STAMPER_CALLSIGN: BRAVO2
STAMPER_NPUB: npub1bravo...
TIMESTAMP: 2025-11-21 14:30_00
COORDINATES: 38.7223,-9.1393
LOCATION_NAME: Lisbon Central Cafe
RECEIVED_FROM: sender
RECEIVED_VIA: BLE
HOP_NUMBER: 1
--> signature: hex_sig_of_entire_postcard_so_far

## STAMP: 2
STAMPER_CALLSIGN: ALPHA1
STAMPER_NPUB: npub1alpha...
TIMESTAMP: 2025-11-22 10:15_00
COORDINATES: 40.7128,-74.0060
LOCATION_NAME: NYC Penn Station
RECEIVED_FROM: npub1bravo...
RECEIVED_VIA: Radio
HOP_NUMBER: 2
--> signature: hex_sig_including_previous_stamps

## DELIVERY_RECEIPT
RECIPIENT_NPUB: npub1xyz789...
DELIVERED_AT: 2025-11-22 18:45_00
DELIVERED_BY: npub1alpha...
COORDINATES: 41.8781,-87.6298
LOCATION_NAME: Chicago Downtown
--> signature: hex_sig_recipient_confirms

## RETURN_STAMP: 1
STAMPER_CALLSIGN: DELTA4
STAMPER_NPUB: npub1delta...
TIMESTAMP: 2025-11-23 09:00_00
COORDINATES: 40.7128,-74.0060
RECEIVED_FROM: recipient
HOP_NUMBER: 1
--> signature: hex_sig

## SENDER_ACKNOWLEDGMENT
SENDER_NPUB: npub1abc123...
ACKNOWLEDGED_AT: 2025-11-24 15:30_00
--> signature: hex_sig_sender_confirms
```

### Header Section

1. **Title Line** (required)
   - **Format**: `# POSTCARD: <title>`
   - **Example**: `# POSTCARD: Greetings from Lisbon`
   - **Constraints**: Any length, descriptive

2. **Blank Line** (required)
   - Separates title from metadata

3. **Created Timestamp** (required)
   - **Format**: `CREATED: YYYY-MM-DD HH:MM_ss`
   - **Example**: `CREATED: 2025-11-21 10:00_00`
   - **Note**: Underscore before seconds

4. **Sender Callsign** (required)
   - **Format**: `SENDER_CALLSIGN: <callsign>`
   - **Example**: `SENDER_CALLSIGN: CR7BBQ`
   - **Purpose**: Human-readable sender identifier

5. **Sender NPUB** (required)
   - **Format**: `SENDER_NPUB: <npub>`
   - **Example**: `SENDER_NPUB: npub1abc123...`
   - **Purpose**: Cryptographic sender identity
   - **Note**: Required for signature verification

6. **Recipient Callsign** (optional)
   - **Format**: `RECIPIENT_CALLSIGN: <callsign>`
   - **Example**: `RECIPIENT_CALLSIGN: X135AS`
   - **Purpose**: Human-readable recipient hint

7. **Recipient NPUB** (required)
   - **Format**: `RECIPIENT_NPUB: <npub>`
   - **Example**: `RECIPIENT_NPUB: npub1xyz789...`
   - **Purpose**: Cryptographic recipient identity
   - **Note**: Required for delivery and encryption

8. **Recipient Locations** (required)
   - **Format**: `RECIPIENT_LOCATIONS: lat1,lon1; lat2,lon2; lat3,lon3`
   - **Example**: `RECIPIENT_LOCATIONS: 38.7223,-9.1393; 40.7128,-74.0060`
   - **Purpose**: Locations where recipient might be found
   - **Note**: Carriers use this to select relevant postcards
   - **Constraints**: At least one location, semicolon-separated

9. **Type** (required)
   - **Format**: `TYPE: open|encrypted`
   - **Values**:
     - `open`: Content readable by all carriers
     - `encrypted`: Content encrypted, only sender/recipient can read
   - **Example**: `TYPE: open`

10. **Status** (required, updated during journey)
    - **Format**: `STATUS: in-transit|delivered|acknowledged|expired`
    - **Values**:
      - `in-transit`: Moving through carriers
      - `delivered`: Recipient stamped delivery receipt
      - `acknowledged`: Sender confirmed receipt delivery
      - `expired`: TTL exceeded, postcard discarded
    - **Example**: `STATUS: in-transit`

11. **TTL** (optional)
    - **Format**: `TTL: <seconds>`
    - **Example**: `TTL: 604800` (7 days)
    - **Purpose**: Expiration time, postcard deleted after
    - **Default**: No expiration if omitted

12. **Priority** (optional)
    - **Format**: `PRIORITY: emergency|urgent|normal|low`
    - **Example**: `PRIORITY: urgent`
    - **Purpose**: Helps carriers prioritize
    - **Default**: `normal`

13. **Blank Line** (required)
    - Separates header from content

### Content Section

The content section contains the actual message.

**Characteristics**:
- **Plain text** for open postcards
- **NIP-04 encrypted** for encrypted postcards
- Multiple paragraphs allowed
- Blank lines separate paragraphs
- Whitespace preserved
- Reasonable size limits (e.g., 10KB)

**Example (Open)**:
```
Greetings from Lisbon!

Having a wonderful time exploring the historic
city center. The weather is perfect and the food
is amazing.

Hope this postcard finds you well.

Best regards,
CR7BBQ
```

**Example (Encrypted)**:
```
<NIP-04 encrypted content - base64 encoded>
AAAAt2VuY3J5cHRlZCBjb250ZW50IGhlcmU...
</NIP-04>
```

### Sender Metadata

Metadata appears after content:

```
--> npub: npub1abc123...
--> signature: hex_signature_string...
```

- **npub**: Sender's NOSTR public key
- **signature**: Sender's Schnorr signature of header + content

## Content Types

### Open Postcards

**TYPE: open**

**Characteristics**:
- Content readable by all carriers
- Like physical postcards - anyone can read
- Useful for public messages, greetings
- Lower privacy but full transparency
- Carriers can verify message content

**Use Cases**:
- Greetings and postcards from travel
- Public announcements
- Community messages
- Non-sensitive information

**Example**:
```
TYPE: open

Hello from Paris! Having a great time.
The Eiffel Tower is as beautiful as they say.

-CR7BBQ
```

### Encrypted Postcards

**TYPE: encrypted**

**Characteristics**:
- Content encrypted using NIP-04 (NOSTR encrypted DM standard)
- Only sender and recipient can read content
- Header remains public (for routing)
- Stamps remain public (for verification)
- Higher privacy

**Use Cases**:
- Private messages
- Sensitive information
- Personal communications
- Confidential data

**Encryption Process**:
1. Sender encrypts content with recipient's npub (using ECDH)
2. Encrypted content base64 encoded
3. Only recipient's nsec can decrypt
4. Carriers cannot read content

**Example**:
```
TYPE: encrypted

<NIP-04 encrypted content>
AAAAt2VuY3J5cHRlZCBjb250ZW50IGhlcmU...
</NIP-04>
```

## Attachments

### Overview

Attachments (photos, audio clips, small PDFs, route-proof selfies)
travel **inline** inside `postcard.txt` as base64 blocks. This keeps
the single-file invariant: you can copy the postcard over any transport
without worrying about sibling files getting separated.

### ATTACHMENT Block Format

```
## ATTACHMENT: <filename>
CONTENT_TYPE: <mime-type>
SIZE: <byte-count-before-base64>
SHA256: <hex-sha256-of-raw-bytes>
ADDED_BY: <npub>
ADDED_AT: YYYY-MM-DD HH:MM_ss
-->
<base64-encoded-bytes, wrapped to 76 columns>
<base64-encoded-bytes, wrapped to 76 columns>
...
<-- end attachment
```

### Fields

1. **Filename** (header line) — descriptive, e.g. `transit-selfie.jpg`.
   Must not contain `/` or `\`. Readers should display it; it does
   not have to be unique across the postcard.

2. **CONTENT_TYPE** — IANA media type, e.g. `image/jpeg`, `image/png`,
   `audio/ogg`, `application/pdf`.

3. **SIZE** — byte count of the *decoded* (raw) content. Useful for
   quick sanity checks before decoding.

4. **SHA256** — lowercase hex SHA-256 of the raw bytes, used as an
   integrity check independent of the NOSTR signature chain.

5. **ADDED_BY** — npub of the participant who attached this. Usually
   the sender for the original postcard body, or a carrier's npub for
   proof-of-transit photos attached when they stamped.

6. **ADDED_AT** — timestamp when this attachment was appended.

7. **`-->`** — literal three-character separator on its own line.
   Everything after it, up to the terminator, is the base64 payload.

8. **Base64 payload** — MIME-style base64 (RFC 4648). Wrap at 76
   columns. Decoders must ignore whitespace.

9. **`<-- end attachment`** — literal terminator on its own line.

### Where attachments appear

- **Sender attachments** sit directly after the sender's
  `--> signature:` line and before `## STAMP: 1`.
- **Carrier attachments** sit directly after their own stamp's
  signature line and before the next stamp. This ties the attachment
  to a specific hop in the chain.

Each attachment is covered by every signature that comes after it:
adding an attachment between existing blocks is not allowed, because
it would invalidate the later stamp signatures (which is the point).
New attachments are always appended at the tail together with a new
signed block.

### Size guidance

- Keep any single attachment under ~1 MB when possible — base64 grows
  the encoded size by ~33%, and a postcard passes through narrow
  links (BLE, LoRa) where each kilobyte hurts.
- Prefer WebP or JPEG for photos; re-encode at ≤1600 px longest edge
  before attaching.
- If you truly need large binaries, consider whether this should be a
  different app (files / videos) rather than a postcard.

## Stamps System

### Overview

Stamps are the core mechanism for tracking postcard journey. Each carrier who handles the postcard adds a stamp with:
- Their identity (callsign + npub)
- Timestamp
- Geographic location
- Who they received it from
- Hop number
- Cryptographic signature

### Stamp Format

**Structure**:
```
## STAMP: <number>
STAMPER_CALLSIGN: <callsign>
STAMPER_NPUB: <npub>
TIMESTAMP: YYYY-MM-DD HH:MM_ss
COORDINATES: <lat>,<lon>
LOCATION_NAME: <name> (optional)
RECEIVED_FROM: sender|<npub>
RECEIVED_VIA: <transmission-method>
HOP_NUMBER: <number>
--> signature: hex_signature
```

**Fields**:

1. **Stamp Number**
   - Sequential number starting from 1
   - Format: `## STAMP: 1`, `## STAMP: 2`, etc.
   - One number per stamp

2. **Stamper Callsign** (required)
   - Carrier's human-readable identifier
   - Example: `STAMPER_CALLSIGN: BRAVO2`

3. **Stamper NPUB** (required)
   - Carrier's NOSTR public key
   - Example: `STAMPER_NPUB: npub1bravo...`
   - Used for signature verification

4. **Timestamp** (required)
   - When stamp was added
   - Format: `TIMESTAMP: YYYY-MM-DD HH:MM_ss`
   - Example: `TIMESTAMP: 2025-11-21 14:30_00`

5. **Coordinates** (required)
   - Where stamp was added
   - Format: `COORDINATES: <lat>,<lon>`
   - Example: `COORDINATES: 38.7223,-9.1393`
   - Precision: Up to 6 decimal places

6. **Location Name** (optional)
   - Human-readable location description
   - Example: `LOCATION_NAME: Lisbon Central Cafe`
   - Helps track journey narrative

7. **Received From** (required)
   - Who handed the postcard to this carrier
   - Values:
     - `sender`: Received directly from sender
     - `recipient`: Received from recipient (return journey)
     - `<npub>`: Received from another carrier (their npub)
   - Example: `RECEIVED_FROM: npub1bravo...`

8. **Received Via** (required)
   - How the postcard was transmitted to this carrier
   - Open text field, common values:
     - `BLE`: Bluetooth Low Energy
     - `LoRa`: Long Range radio
     - `Meshtastic`: Meshtastic mesh network
     - `Radio`: Amateur radio (APRS, FM, etc.)
     - `Satellite`: Satellite communication
     - `WiFi-LAN`: Local WiFi network
     - `WiFi-HaLow`: 802.11ah long-range WiFi
     - `Internet`: Generic internet connection
     - `Cellular`: Mobile network (4G, 5G)
     - `In-Person`: Physical handoff (USB, SD card, face-to-face)
     - `USB`: USB drive transfer
     - `SD-Card`: SD card physical transfer
     - `NFC`: Near Field Communication
     - `I2P`: I2P anonymity network
     - `Tor`: Tor anonymity network
     - `Ethernet`: Wired network
     - `Zigbee`: Zigbee protocol
     - `Thread`: Thread protocol
     - `MQTT`: MQTT protocol
   - Example: `RECEIVED_VIA: BLE`
   - Purpose: Documents technology used for each hop

9. **Hop Number** (required)
   - Number of hops from sender
   - Example: `HOP_NUMBER: 1` (first carrier), `HOP_NUMBER: 2` (second carrier)
   - Helps track delivery efficiency

10. **Signature** (required)
    - Schnorr signature of entire postcard up to this stamp
    - Format: `--> signature: hex_signature`
    - Signs: header + content + all previous stamps + this stamp
    - Creates tamper-proof chain

### Adding a Stamp

**Process**:
```
1. Carrier receives postcard (via BLE, LoRa, Radio, or physical handoff)
2. Carrier verifies all previous signatures
3. Carrier adds new STAMP section:
   - Fills in their callsign, npub
   - Records current timestamp
   - Records current GPS coordinates
   - Notes who they received it from
   - Notes transmission method used (RECEIVED_VIA)
   - Increments hop number
4. Carrier signs entire postcard (up to and including new stamp)
5. Carrier appends signature to stamp
6. Postcard now has one more stamp in the chain
```

### Stamp Example

```
## STAMP: 1
STAMPER_CALLSIGN: BRAVO2
STAMPER_NPUB: npub1bravo2abc123...
TIMESTAMP: 2025-11-21 14:30_00
COORDINATES: 38.7223,-9.1393
LOCATION_NAME: Lisbon Central Cafe
RECEIVED_FROM: sender
RECEIVED_VIA: BLE
HOP_NUMBER: 1
--> signature: a1b2c3d4e5f6...

## STAMP: 2
STAMPER_CALLSIGN: ALPHA1
STAMPER_NPUB: npub1alpha1xyz789...
TIMESTAMP: 2025-11-22 10:15_00
COORDINATES: 40.7128,-74.0060
LOCATION_NAME: NYC Penn Station
RECEIVED_FROM: npub1bravo2abc123...
RECEIVED_VIA: Radio
HOP_NUMBER: 2
--> signature: 7g8h9i0j1k2l...
```

### Stamp Verification

**Verification Process**:
```
1. For each stamp (in order):
   a. Extract stamper's npub
   b. Extract signature
   c. Reconstruct signable content:
      - Header + content + all stamps up to this one
   d. Verify Schnorr signature
   e. If invalid, reject postcard as tampered
2. If all stamps valid, postcard is trusted
3. Display stamps with verification badges
```

## Delivery Receipt

### Overview

When the postcard reaches the recipient, the recipient stamps a delivery receipt. This proves:
- The postcard was successfully delivered
- Who delivered it (last carrier's npub)
- When and where it was delivered
- Recipient acknowledges receipt

### Receipt Format

**Structure**:
```
## DELIVERY_RECEIPT
RECIPIENT_NPUB: <npub>
DELIVERED_AT: YYYY-MM-DD HH:MM_ss
DELIVERED_BY: <npub>
COORDINATES: <lat>,<lon>
LOCATION_NAME: <name> (optional)
--> signature: hex_signature
```

**Fields**:

1. **Recipient NPUB** (required)
   - Must match RECIPIENT_NPUB in header
   - Example: `RECIPIENT_NPUB: npub1xyz789...`
   - Proves identity of recipient

2. **Delivered At** (required)
   - Timestamp when recipient received postcard
   - Format: `DELIVERED_AT: YYYY-MM-DD HH:MM_ss`
   - Example: `DELIVERED_AT: 2025-11-22 18:45_00`

3. **Delivered By** (required)
   - NPUB of last carrier who handed postcard to recipient
   - Example: `DELIVERED_BY: npub1alpha...`
   - Links to last STAMP's npub

4. **Coordinates** (required)
   - Where delivery occurred
   - Example: `COORDINATES: 41.8781,-87.6298`
   - Verifies delivery location

5. **Location Name** (optional)
   - Human-readable delivery location
   - Example: `LOCATION_NAME: Chicago Downtown Office`

6. **Signature** (required)
   - Recipient signs entire postcard + receipt
   - Proves recipient acknowledges delivery
   - Format: `--> signature: hex_signature`

### Receipt Example

```
## DELIVERY_RECEIPT
RECIPIENT_NPUB: npub1xyz789def456...
DELIVERED_AT: 2025-11-22 18:45_00
DELIVERED_BY: npub1alpha1xyz789...
COORDINATES: 41.8781,-87.6298
LOCATION_NAME: Chicago Downtown Office
--> signature: m5n6o7p8q9r0...
```

### Status Update

After delivery receipt is added:
- Update `STATUS: delivered` in header
- Postcard now ready for return journey (optional)
- Recipient can read content (if encrypted, using their nsec)

## Return Journey

### Overview

After delivery, the postcard can optionally travel back to the sender carrying the delivery receipt. This allows the sender to verify successful delivery and serves as proof of completion (especially important for paid delivery services).

The return journey works exactly like the outbound journey, but with "RETURN_STAMP" sections.

### Return Stamp Format

**Structure**:
```
## RETURN_STAMP: <number>
STAMPER_CALLSIGN: <callsign>
STAMPER_NPUB: <npub>
TIMESTAMP: YYYY-MM-DD HH:MM_ss
COORDINATES: <lat>,<lon>
LOCATION_NAME: <name> (optional)
RECEIVED_FROM: recipient|<npub>
RECEIVED_VIA: <transmission-method>
HOP_NUMBER: <number>
--> signature: hex_signature
```

**Characteristics**:
- Identical format to outbound STAMP
- Labeled "RETURN_STAMP" instead of "STAMP"
- Sequential numbering starting from 1
- HOP_NUMBER counts hops from recipient back to sender
- RECEIVED_FROM starts with "recipient" for first return carrier
- RECEIVED_VIA documents transmission method (same options as outbound stamps)

### Return Journey Example

```
## DELIVERY_RECEIPT
RECIPIENT_NPUB: npub1xyz789...
DELIVERED_AT: 2025-11-22 18:45_00
DELIVERED_BY: npub1alpha...
COORDINATES: 41.8781,-87.6298
--> signature: m5n6o7p8q9r0...

## RETURN_STAMP: 1
STAMPER_CALLSIGN: DELTA4
STAMPER_NPUB: npub1delta...
TIMESTAMP: 2025-11-23 09:00_00
COORDINATES: 40.7128,-74.0060
LOCATION_NAME: NYC Central Station
RECEIVED_FROM: recipient
RECEIVED_VIA: Meshtastic
HOP_NUMBER: 1
--> signature: s1t2u3v4w5x6...

## RETURN_STAMP: 2
STAMPER_CALLSIGN: ECHO5
STAMPER_NPUB: npub1echo...
TIMESTAMP: 2025-11-24 12:30_00
COORDINATES: 38.7223,-9.1393
LOCATION_NAME: Lisbon Airport
RECEIVED_FROM: npub1delta...
RECEIVED_VIA: LoRa
HOP_NUMBER: 2
--> signature: y7z8a9b0c1d2...
```

### Return Journey Routing

**Finding the Sender**:
- Carriers read SENDER_NPUB and SENDER_CALLSIGN from header
- If sender's usual locations known, route toward those
- Alternatively, carriers heading toward sender's region take it
- Eventually delivered to sender or someone who can hand it to sender

## Sender Acknowledgment

### Overview

When the postcard (with delivery receipt) returns to the sender, the sender stamps a final acknowledgment. This completes the full cycle and proves:
- Sender received the delivery receipt
- Sender confirms successful delivery
- Payment can be settled (if applicable)

### Acknowledgment Format

**Structure**:
```
## SENDER_ACKNOWLEDGMENT
SENDER_NPUB: <npub>
ACKNOWLEDGED_AT: YYYY-MM-DD HH:MM_ss
--> signature: hex_signature
```

**Fields**:

1. **Sender NPUB** (required)
   - Must match SENDER_NPUB in header
   - Example: `SENDER_NPUB: npub1abc123...`
   - Proves identity of sender

2. **Acknowledged At** (required)
   - Timestamp when sender received return postcard
   - Format: `ACKNOWLEDGED_AT: YYYY-MM-DD HH:MM_ss`
   - Example: `ACKNOWLEDGED_AT: 2025-11-24 15:30_00`

3. **Signature** (required)
   - Sender signs entire postcard + acknowledgment
   - Proves sender confirms receipt delivery
   - Format: `--> signature: hex_signature`

### Acknowledgment Example

```
## SENDER_ACKNOWLEDGMENT
SENDER_NPUB: npub1abc123def456...
ACKNOWLEDGED_AT: 2025-11-24 15:30_00
--> signature: e3f4g5h6i7j8...
```

### Status Update

After sender acknowledgment:
- Update `STATUS: acknowledged` in header
- Postcard journey complete
- All parties have cryptographic proof of delivery
- Payment can be settled based on stamps

## Contributor System

> **v2.0 note.** The sibling `contributors/<CALLSIGN>/` folders
> described below are gone. A carrier who wants to prove they
> physically handled the postcard attaches their photo/note as an
> `## ATTACHMENT:` block right after their own `## STAMP:` — see
> [Attachments](#attachments). The rest of this section is kept for
> historical reference and will be removed in a future revision.

### Overview

Carriers can add photos, notes, and other content as "contributors" to prove they physically transported the postcard. This creates a rich narrative of the postcard's journey.

### Contributor Folder Structure

```
postcards/
└── 2025/
    └── 2025-11-21_msg-abc123/
        ├── postcard.txt
        └── contributors/
            ├── BRAVO2/              # First carrier
            │   ├── contributor.txt
            │   ├── cafe-photo.jpg
            │   └── transit-selfie.jpg
            └── ALPHA1/              # Second carrier
                ├── contributor.txt
                └── delivery-proof.jpg
```

### Contributor Metadata File

**Filename**: `contributor.txt` (inside contributor folder)

**Format**:
```
# CONTRIBUTOR: BRAVO2

CREATED: 2025-11-21 14:35_00

Carried this postcard from Lisbon to the airport.

Stopped at my favorite cafe for a coffee before heading
to the train station. Photo attached showing the postcard
at the cafe to prove I had it at this location.

--> npub: npub1bravo...
--> signature: hex_sig...
```

**Purpose**:
- Describe carrier's contribution
- Add narrative to journey
- Prove physical possession at specific locations
- Optional - contributor folder can exist without it

### Contributor Photos

Carriers can add photos proving transit:

**Examples**:
- Photo of postcard at specific landmark
- Selfie with postcard at location
- Receipt showing date/location
- Transit ticket showing route

**Naming**:
- Descriptive filenames (e.g., `cafe-photo.jpg`, `delivery-proof.jpg`)
- Standard image formats (JPG, PNG, WebP)

### Contributor Permissions

**Contributor Folder Owner** (Carrier):
- Add/edit/delete files in their own folder
- Edit contributor.txt
- Cannot modify other contributors' folders
- Cannot modify main postcard.txt

**Sender** (Postcard Creator):
- View all contributor folders
- Can moderate inappropriate content
- Cannot edit contributor content

**Recipient**:
- View all contributor folders
- Can react/comment on contributions

## Signature Verification Chain

### Overview

The signature chain is the core security mechanism of postcards. Each stamp signs the entire postcard history, creating an unbreakable chain of custody.

### Chain Construction

**Initial State** (Sender Creates Postcard):
```
Content to sign:
  Header + Content

Sender signs with their nsec
→ Signature stored in sender metadata
```

**After First Stamp**:
```
Content to sign:
  Header + Content + Sender Metadata + STAMP 1 (without signature)

Stamper 1 signs with their nsec
→ Signature stored in STAMP 1
```

**After Second Stamp**:
```
Content to sign:
  Header + Content + Sender Metadata + STAMP 1 (with signature) + STAMP 2 (without signature)

Stamper 2 signs with their nsec
→ Signature stored in STAMP 2
```

**Pattern**:
Each new signature covers everything before it, including all previous signatures.

### Tamper Detection

**Scenario**: Someone tries to modify the message content after stamps added.

**Result**:
1. Modification changes header or content
2. All stamp signatures become invalid (they signed the original content)
3. Verification fails
4. Postcard rejected as tampered

**Security**:
- Any modification to any part breaks all subsequent signatures
- Carriers verify before adding their stamp
- Recipients verify before accepting delivery
- Sender verifies when receiving return

### Verification Algorithm

**Process**:
```python
def verify_postcard(postcard):
    # 1. Verify sender signature
    content = postcard.header + postcard.content
    if not verify_schnorr(content, postcard.sender_signature, postcard.sender_npub):
        return False

    # 2. Verify each stamp in order
    signed_content = content + postcard.sender_metadata
    for stamp in postcard.stamps:
        signed_content += stamp.without_signature()
        if not verify_schnorr(signed_content, stamp.signature, stamp.stamper_npub):
            return False
        signed_content += stamp.signature_line()

    # 3. Verify delivery receipt (if present)
    if postcard.has_delivery_receipt():
        signed_content += postcard.delivery_receipt.without_signature()
        if not verify_schnorr(signed_content, receipt.signature, receipt.recipient_npub):
            return False

    # 4. Verify return stamps (if present)
    for return_stamp in postcard.return_stamps:
        signed_content += return_stamp.without_signature()
        if not verify_schnorr(signed_content, return_stamp.signature, return_stamp.stamper_npub):
            return False
        signed_content += return_stamp.signature_line()

    # 5. Verify sender acknowledgment (if present)
    if postcard.has_acknowledgment():
        signed_content += postcard.acknowledgment.without_signature()
        if not verify_schnorr(signed_content, ack.signature, ack.sender_npub):
            return False

    return True  # All signatures valid!
```

### Trust Model

**No Trusted Third Party**:
- No central authority needed
- Verification is purely cryptographic
- Anyone can verify the entire chain
- Trust comes from signatures, not from a server

**Payment Proof**:
- Stamps prove who carried and when
- Receipt proves delivery
- Acknowledgment proves sender got receipt
- Cryptographically unforgeable
- Payment settlement uses this proof (external to Geogram)

## Recipient Discovery

### Overview

Unlike traditional messaging where both parties must be online simultaneously, postcards use geographic hints to help carriers find the recipient.

### Recipient Locations Field

**Format**: `RECIPIENT_LOCATIONS: lat1,lon1; lat2,lon2; lat3,lon3`

**Purpose**:
- List of coordinates where recipient might be found
- Could be:
  - Home location
  - Work location
  - Frequent hangout spots
  - Places they visit regularly
  - General region they inhabit

**Carrier Selection**:
Carriers filter postcards based on:
1. Are any recipient locations near my route?
2. Am I heading toward recipient's region?
3. Do I know someone near recipient's locations?

### Example

```
RECIPIENT_LOCATIONS: 38.7223,-9.1393; 51.5074,-0.1278; 40.7128,-74.0060
```

Recipient might be found at:
- Lisbon, Portugal (38.7223,-9.1393)
- London, UK (51.5074,-0.1278)
- New York City, USA (40.7128,-74.0060)

Carriers traveling to or through any of these locations would consider carrying this postcard.

### Privacy Considerations

**Public Information**:
- Recipient locations are public (in header)
- Necessary for routing
- Should be general areas, not exact addresses
- Recipient can list multiple locations to improve delivery chances

**Recommendations**:
- Use public places (cafes, train stations, city centers)
- Use neighborhood-level precision, not house addresses
- Update locations if recipient moves
- List 2-5 locations for best results

## Status Tracking

### Status Values

**in-transit**:
- Postcard is moving through carriers
- Has at least one stamp
- No delivery receipt yet
- Default status after sender creates postcard

**delivered**:
- Recipient has stamped delivery receipt
- Postcard successfully reached destination
- May begin return journey
- Payment may be due to carriers

**acknowledged**:
- Sender has stamped acknowledgment
- Full cycle complete
- All parties have proof
- Payment can be settled

**expired**:
- TTL exceeded
- Postcard should be discarded
- Delivery failed
- No payment owed

### Status Transitions

```
in-transit → delivered  (recipient stamps delivery receipt)
delivered → acknowledged  (sender stamps acknowledgment)
in-transit → expired  (TTL exceeded)
delivered → expired  (TTL exceeded before return)
```

### Status Display

**UI Indicators**:
- 📦 in-transit: Moving through network
- ✅ delivered: Successfully delivered
- 🔁 acknowledged: Full cycle complete
- ⏰ expired: Delivery failed (TTL)

## Reactions System

### Overview

Like other collection types, postcards support likes and comments. Users can react to:
- The postcard itself
- Individual contributor folders

### Reactions Directory

**Location**: `<postcard-folder>/.reactions/`

**Files**:
- `postcard.txt`: Reactions on the postcard
- `contributors/CALLSIGN.txt`: Reactions on specific carrier's contribution

### Reaction File Format

```
LIKES: CR7BBQ, X135AS, BRAVO2

> YYYY-MM-DD HH:MM_ss -- CALLSIGN
Comment text here.
--> npub: npub1...
--> signature: hex_sig

> YYYY-MM-DD HH:MM_ss -- ANOTHER_USER
Another comment.
```

### Postcard Reactions

**Example** (`.reactions/postcard.txt`):
```
LIKES: ALPHA1, DELTA4, ECHO5

> 2025-11-25 10:00_00 -- ALPHA1
Amazing journey! Traveled through 5 carriers.
--> npub: npub1alpha...
--> signature: hex_sig

> 2025-11-25 12:30_00 -- DELTA4
The photos from carriers are great!
```

### Contributor Reactions

**Example** (`.reactions/contributors/BRAVO2.txt`):
```
LIKES: CR7BBQ, X135AS

> 2025-11-21 16:00_00 -- CR7BBQ
Thanks for carrying my postcard! Love the cafe photo.
--> npub: npub1abc...
--> signature: hex_sig
```

## File Management

### Supported File Types

**Images**:
- JPG, JPEG, PNG, GIF, WebP
- Reasonable size limits (e.g., 5MB per image)

**Documents**:
- PDF, TXT, MD
- Attachments to postcards

### File Organization

Files are stored in the postcard folder or contributor subfolders:

```
2025-11-21_msg-abc123/
├── postcard.txt          # Main postcard
├── photo.jpg             # Attached photo
├── contributors/
│   └── BRAVO2/
│       ├── contributor.txt
│       └── transit-photo.jpg
└── .reactions/
    └── postcard.txt
```

### File Naming

**Convention**: Descriptive names

**Examples**:
```
Good:
- vacation-photo.jpg
- important-document.pdf
- transit-proof.jpg

Avoid:
- IMG_0001.jpg
- Document (1).pdf
```

## Permissions and Roles

### Roles

**Sender** (Postcard Creator):
- Create postcard
- Set recipients, locations, content
- Sign initial postcard
- Stamp acknowledgment when return received
- Moderate contributor content
- Delete entire postcard

**Recipient**:
- Read postcard content (if encrypted, using their nsec)
- Stamp delivery receipt
- View all stamps and contributors
- React/comment on postcard
- Cannot modify stamps or content

**Carriers** (Contributors):
- Add stamps when handling postcard
- Create contributor folder
- Add photos/notes to their folder
- Edit/delete their own contributions
- Cannot modify postcard content or other stamps

**Viewers** (Anyone else):
- View postcard (if open type)
- View stamps
- View contributor content
- React/comment
- Cannot modify anything

### Permission Checks

Before any operation, verify user permissions:

```
1. Identify user's role
2. Check if action is allowed
3. For cryptographic operations, verify npub
4. Execute operation
```

## Moderation System

### Overview

The sender (as postcard creator) can moderate inappropriate contributor content by hiding it in the `.hidden/` directory.

### Hidden Content Directory

**Location**: `<postcard-folder>/.hidden/`

**Purpose**: Store content hidden by sender

### Moderation Actions

**Hide Contributor Photo**:
1. Sender selects inappropriate photo
2. Move to `.hidden/files/`
3. Create metadata file noting reason
4. Log moderation action

**Hide Contributor Comment**:
1. Sender selects inappropriate comment
2. Move to `.hidden/comments/`
3. Log moderation action

### Moderation Log

**File**: `.hidden/moderation-log.txt`

**Format**:
```
> 2025-11-22 10:00_00 -- CR7BBQ (sender)
ACTION: hide_file
TARGET: contributors/BRAVO2/inappropriate.jpg
REASON: Inappropriate content
```

## NOSTR Integration

### NOSTR Keys

**npub (Public Key)**:
- Bech32-encoded public key
- Format: `npub1` followed by encoded data
- Purpose: Identity verification

**nsec (Private Key)**:
- Never stored in files
- Used for signing
- Kept secure in user's keystore

### Signature Format

**Sender Signature**:
```
--> npub: npub1abc123...
--> signature: hex_signature_of_header_and_content
```

**Stamp Signature**:
```
--> signature: hex_signature_of_postcard_up_to_this_stamp
```

### Signature Verification

1. Extract npub and signature
2. Reconstruct signable content
3. Verify Schnorr signature (BIP-340)
4. Display verification badge if valid

### NIP-04 Encryption

**For Encrypted Postcards**:
1. Sender computes shared secret with recipient's npub (ECDH)
2. Encrypt content using AES-256-CBC
3. Base64 encode encrypted content
4. Store in content section
5. Recipient decrypts using their nsec

## Complete Examples

The samples below use fictional but plausible npubs and signatures.
They are meant for reading — every signature here is a hand-crafted
placeholder, not a real Schnorr signature. Copy their shape, not their
bytes.

### Stage 1 — In transit (freshly signed, one carrier)

Sender CR7BBQ has just handed the postcard to their first carrier
BRAVO2 via BLE. Two signed blocks: the sender's signature covering
header + content, and BRAVO2's stamp signature covering everything
above its `--> signature:` line.

```
# POSTCARD: Greetings from Lisbon

CREATED: 2026-04-24 10:00_00
SENDER_CALLSIGN: CR7BBQ
SENDER_NPUB: npub1cr7bbq0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q7t3ku9
RECIPIENT_CALLSIGN: X135AS
RECIPIENT_NPUB: npub1x135asd9a8s7d6f5g4h3j2k1l0z9x8c7v6b5n4m3q2w1e0r9t8y7u
RECIPIENT_LOCATIONS: 40.7128,-74.0060; 40.7589,-73.9851
TYPE: open
STATUS: in-transit
TTL: 604800
PRIORITY: normal

Hello from Lisbon!

Having a wonderful time exploring the historic city.
The weather is perfect and the pastries are amazing.

Hope this finds you well.

Best regards,
CR7BBQ

--> npub: npub1cr7bbq0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q7t3ku9
--> signature: 9f2c7b4a1e3d5f6a8b9c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c

## STAMP: 1
STAMPER_CALLSIGN: BRAVO2
STAMPER_NPUB: npub1bravo2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxkp4j2h
TIMESTAMP: 2026-04-24 14:30_00
COORDINATES: 38.7223,-9.1393
LOCATION_NAME: Lisbon Central Cafe
RECEIVED_FROM: sender
RECEIVED_VIA: BLE
HOP_NUMBER: 1
--> signature: 7a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7
```

### Stage 2 — Still in transit (two hops, attachment added)

BRAVO2 has handed the postcard on to ALPHA1 over satellite, and ALPHA1
added a proof-of-transit photo inline. Notice the attachment sits
*between* ALPHA1's stamp and any later block: ALPHA1's signature covers
it, and any future stamp will also sign over it.

```
# POSTCARD: Greetings from Lisbon

CREATED: 2026-04-24 10:00_00
SENDER_CALLSIGN: CR7BBQ
SENDER_NPUB: npub1cr7bbq0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q7t3ku9
RECIPIENT_CALLSIGN: X135AS
RECIPIENT_NPUB: npub1x135asd9a8s7d6f5g4h3j2k1l0z9x8c7v6b5n4m3q2w1e0r9t8y7u
RECIPIENT_LOCATIONS: 40.7128,-74.0060; 40.7589,-73.9851
TYPE: open
STATUS: in-transit
TTL: 604800
PRIORITY: normal

Hello from Lisbon!

Having a wonderful time exploring the historic city.
The weather is perfect and the pastries are amazing.

Hope this finds you well.

Best regards,
CR7BBQ

--> npub: npub1cr7bbq0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q7t3ku9
--> signature: 9f2c7b4a1e3d5f6a8b9c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c

## STAMP: 1
STAMPER_CALLSIGN: BRAVO2
STAMPER_NPUB: npub1bravo2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxkp4j2h
TIMESTAMP: 2026-04-24 14:30_00
COORDINATES: 38.7223,-9.1393
LOCATION_NAME: Lisbon Central Cafe
RECEIVED_FROM: sender
RECEIVED_VIA: BLE
HOP_NUMBER: 1
--> signature: 7a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7

## STAMP: 2
STAMPER_CALLSIGN: ALPHA1
STAMPER_NPUB: npub1alpha1yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyhm5x8g
TIMESTAMP: 2026-04-25 10:15_00
COORDINATES: 40.7128,-74.0060
LOCATION_NAME: NYC Penn Station
RECEIVED_FROM: npub1bravo2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxkp4j2h
RECEIVED_VIA: Satellite
HOP_NUMBER: 2
--> signature: c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9

## ATTACHMENT: transit-selfie.jpg
CONTENT_TYPE: image/jpeg
SIZE: 842
SHA256: 3b5c2e87f4a91d76e8c3a0b5d2e7f91c8a4b6d3e5f7a8b9c0d1e2f3a4b5c6d7e
ADDED_BY: npub1alpha1yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyhm5x8g
ADDED_AT: 2026-04-25 10:16_00
-->
/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkS
Ew8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJ
CQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIy
MjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEA
(truncated for brevity — real payloads wrap to 76 columns
 and continue until the terminator below)
<-- end attachment
```

### Stage 3 — Delivered (recipient signed the receipt)

Recipient X135AS met ALPHA1 in New York, read the postcard, and
stamped the delivery receipt. Status in the header is bumped to
`delivered` and the receipt block is the tail of the file. No new
outbound stamps get added after this on the outbound leg.

```
# POSTCARD: Greetings from Lisbon

CREATED: 2026-04-24 10:00_00
SENDER_CALLSIGN: CR7BBQ
SENDER_NPUB: npub1cr7bbq0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q7t3ku9
RECIPIENT_CALLSIGN: X135AS
RECIPIENT_NPUB: npub1x135asd9a8s7d6f5g4h3j2k1l0z9x8c7v6b5n4m3q2w1e0r9t8y7u
RECIPIENT_LOCATIONS: 40.7128,-74.0060; 40.7589,-73.9851
TYPE: open
STATUS: delivered
TTL: 604800
PRIORITY: normal

Hello from Lisbon!

Having a wonderful time exploring the historic city.
The weather is perfect and the pastries are amazing.

Hope this finds you well.

Best regards,
CR7BBQ

--> npub: npub1cr7bbq0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q7t3ku9
--> signature: 9f2c7b4a1e3d5f6a8b9c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c

## STAMP: 1
STAMPER_CALLSIGN: BRAVO2
STAMPER_NPUB: npub1bravo2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxkp4j2h
TIMESTAMP: 2026-04-24 14:30_00
COORDINATES: 38.7223,-9.1393
LOCATION_NAME: Lisbon Central Cafe
RECEIVED_FROM: sender
RECEIVED_VIA: BLE
HOP_NUMBER: 1
--> signature: 7a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7

## STAMP: 2
STAMPER_CALLSIGN: ALPHA1
STAMPER_NPUB: npub1alpha1yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyhm5x8g
TIMESTAMP: 2026-04-25 10:15_00
COORDINATES: 40.7128,-74.0060
LOCATION_NAME: NYC Penn Station
RECEIVED_FROM: npub1bravo2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxkp4j2h
RECEIVED_VIA: Satellite
HOP_NUMBER: 2
--> signature: c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9

## DELIVERY_RECEIPT
RECIPIENT_NPUB: npub1x135asd9a8s7d6f5g4h3j2k1l0z9x8c7v6b5n4m3q2w1e0r9t8y7u
DELIVERED_AT: 2026-04-25 18:45_00
DELIVERED_BY: npub1alpha1yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyhm5x8g
COORDINATES: 40.7589,-73.9851
LOCATION_NAME: NYC Upper East Side
--> signature: d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2
```

### Stage 4 — Acknowledged (full cycle)

The receipt made it back to the sender via DELTA4, and CR7BBQ stamped
the acknowledgment. Status is `acknowledged`; the file contains the
outbound chain, the receipt, the return stamps, and the sender
acknowledgment — every block still signed by someone who was in
physical possession of the earlier bytes.

```
# POSTCARD: Greetings from Lisbon

CREATED: 2026-04-24 10:00_00
SENDER_CALLSIGN: CR7BBQ
SENDER_NPUB: npub1cr7bbq0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q7t3ku9
RECIPIENT_CALLSIGN: X135AS
RECIPIENT_NPUB: npub1x135asd9a8s7d6f5g4h3j2k1l0z9x8c7v6b5n4m3q2w1e0r9t8y7u
RECIPIENT_LOCATIONS: 40.7128,-74.0060; 40.7589,-73.9851
TYPE: open
STATUS: acknowledged
TTL: 604800
PRIORITY: normal

Hello from Lisbon!

Having a wonderful time exploring the historic city.
The weather is perfect and the pastries are amazing.

Hope this finds you well.

Best regards,
CR7BBQ

--> npub: npub1cr7bbq0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q7t3ku9
--> signature: 9f2c7b4a1e3d5f6a8b9c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c

## STAMP: 1
STAMPER_CALLSIGN: BRAVO2
STAMPER_NPUB: npub1bravo2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxkp4j2h
TIMESTAMP: 2026-04-24 14:30_00
COORDINATES: 38.7223,-9.1393
LOCATION_NAME: Lisbon Central Cafe
RECEIVED_FROM: sender
RECEIVED_VIA: BLE
HOP_NUMBER: 1
--> signature: 7a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7

## STAMP: 2
STAMPER_CALLSIGN: ALPHA1
STAMPER_NPUB: npub1alpha1yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyhm5x8g
TIMESTAMP: 2026-04-25 10:15_00
COORDINATES: 40.7128,-74.0060
LOCATION_NAME: NYC Penn Station
RECEIVED_FROM: npub1bravo2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxkp4j2h
RECEIVED_VIA: Satellite
HOP_NUMBER: 2
--> signature: c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9

## DELIVERY_RECEIPT
RECIPIENT_NPUB: npub1x135asd9a8s7d6f5g4h3j2k1l0z9x8c7v6b5n4m3q2w1e0r9t8y7u
DELIVERED_AT: 2026-04-25 18:45_00
DELIVERED_BY: npub1alpha1yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyhm5x8g
COORDINATES: 40.7589,-73.9851
LOCATION_NAME: NYC Upper East Side
--> signature: d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2

## RETURN_STAMP: 1
STAMPER_CALLSIGN: DELTA4
STAMPER_NPUB: npub1delta4zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzqr9w2v
TIMESTAMP: 2026-04-26 09:00_00
COORDINATES: 40.7128,-74.0060
LOCATION_NAME: NYC Central Station
RECEIVED_FROM: recipient
RECEIVED_VIA: Meshtastic
HOP_NUMBER: 1
--> signature: a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6

## RETURN_STAMP: 2
STAMPER_CALLSIGN: ECHO5
STAMPER_NPUB: npub1echo5wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwcn8t1u
TIMESTAMP: 2026-04-27 12:30_00
COORDINATES: 38.7223,-9.1393
LOCATION_NAME: Lisbon Airport
RECEIVED_FROM: npub1delta4zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzqr9w2v
RECEIVED_VIA: LoRa
HOP_NUMBER: 2
--> signature: b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8

## SENDER_ACKNOWLEDGMENT
SENDER_NPUB: npub1cr7bbq0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q0q7t3ku9
ACKNOWLEDGED_AT: 2026-04-27 15:30_00
--> signature: e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4
```

## Parsing Implementation

### Postcard File Parsing

```
1. Read postcard.txt as UTF-8 text
2. Verify first line starts with "# POSTCARD: "
3. Extract title
4. Parse header fields:
   - CREATED, SENDER_CALLSIGN, SENDER_NPUB (required)
   - RECIPIENT_CALLSIGN, RECIPIENT_NPUB, RECIPIENT_LOCATIONS (required)
   - TYPE, STATUS (required)
   - TTL, PRIORITY (optional)
5. Find content section (after header blank line)
6. Parse content until metadata
7. Parse sender metadata (npub, signature)
8. Parse STAMP sections (sequential)
9. Parse DELIVERY_RECEIPT (if present)
10. Parse RETURN_STAMP sections (if present)
11. Parse SENDER_ACKNOWLEDGMENT (if present)
12. Verify signature chain
```

### Stamp Parsing

```
1. Find "## STAMP: N" marker
2. Parse stamper fields:
   - STAMPER_CALLSIGN, STAMPER_NPUB
   - TIMESTAMP, COORDINATES, LOCATION_NAME
   - RECEIVED_FROM, RECEIVED_VIA, HOP_NUMBER
3. Extract signature
4. Verify signature against postcard content up to this stamp
```

### Signature Verification

```
1. For sender signature:
   - Sign: header + content
   - Verify with sender's npub
2. For each stamp:
   - Sign: header + content + sender_metadata + all_previous_stamps + this_stamp_without_sig
   - Verify with stamper's npub
3. For delivery receipt:
   - Sign: header + content + all_stamps + receipt_without_sig
   - Verify with recipient's npub
4. For return stamps and acknowledgment:
   - Same process, accumulating signed content
```

## File Operations

### Creating a Postcard

```
1. User fills in postcard details:
   - Title, recipient info, content
   - Type (open/encrypted)
   - Priority, TTL, payment request
2. If encrypted:
   - Encrypt content with NIP-04
   - Use recipient's npub
3. Generate message ID (first 6 chars of SHA-256)
4. Create folder: postcards/YYYY/YYYY-MM-DD_msg-{id}/
5. Create postcard.txt with header and content
6. Sender signs header + content
7. Append sender metadata with signature
8. Create .reactions/ directory
9. Set STATUS: in-transit
10. Ready for first carrier
```

### Adding a Stamp

```
1. Carrier receives postcard (via BLE, LoRa, Radio, etc.)
2. Carrier verifies all existing signatures
3. If any signature invalid, reject postcard
4. Carrier adds new STAMP section:
   - Generate stamp number (next sequential)
   - Fill in carrier's callsign and npub
   - Record current timestamp and coordinates
   - Note received_from (previous stamper's npub or "sender")
   - Note received_via (transmission method used)
   - Calculate hop_number (previous + 1)
5. Sign entire postcard up to and including new stamp
6. Append signature to stamp
7. Save updated postcard.txt
```

### Stamping Delivery Receipt

```
1. Recipient receives postcard from last carrier
2. Recipient verifies all stamps
3. Recipient adds DELIVERY_RECEIPT section:
   - RECIPIENT_NPUB (must match header)
   - Current timestamp and coordinates
   - Last carrier's npub (DELIVERED_BY)
4. Sign entire postcard including receipt
5. Append signature
6. Update STATUS: delivered
7. Save postcard.txt
8. Optionally begin return journey
```

### Adding Return Stamp

```
1. Carrier receives postcard with delivery receipt
2. Verify all signatures (outbound + receipt)
3. Add RETURN_STAMP section:
   - Same format as regular stamp
   - Sequential numbering starting from 1
   - RECEIVED_FROM starts with "recipient"
4. Sign entire postcard including return stamp
5. Append signature
6. Save postcard.txt
```

### Stamping Sender Acknowledgment

```
1. Postcard (with receipt) returns to sender
2. Sender verifies all signatures (outbound + receipt + return stamps)
3. Sender adds SENDER_ACKNOWLEDGMENT:
   - SENDER_NPUB (must match header)
   - Current timestamp
4. Sign entire postcard including acknowledgment
5. Append signature
6. Update STATUS: acknowledged
7. Save postcard.txt
8. Journey complete!
```

### Creating Contributor Folder

```
1. Carrier who stamped postcard wants to add content
2. Create contributors/ folder if not exists
3. Create contributors/CALLSIGN/ folder
4. Optionally create contributor.txt with description
5. Add photos/files proving transit
6. Set permissions (755 for folder, 644 for files)
```

## Validation Rules

### Postcard Validation

- [x] First line must start with `# POSTCARD: `
- [x] Title must not be empty
- [x] CREATED must have valid timestamp
- [x] SENDER_CALLSIGN must not be empty
- [x] SENDER_NPUB must be valid npub
- [x] RECIPIENT_NPUB must be valid npub
- [x] RECIPIENT_LOCATIONS must have at least one coordinate
- [x] TYPE must be "open" or "encrypted"
- [x] STATUS must be valid status value
- [x] Header must end with blank line
- [x] Sender signature must be valid
- [x] All stamps must have valid signatures
- [x] Folder name must match `YYYY-MM-DD_msg-*` pattern

### Stamp Validation

- [x] STAMP number must be sequential (1, 2, 3, ...)
- [x] STAMPER_NPUB must be valid npub
- [x] TIMESTAMP must be valid format
- [x] COORDINATES must be valid lat,lon
- [x] RECEIVED_VIA must not be empty (open text field)
- [x] HOP_NUMBER must increment by 1
- [x] Signature must verify against postcard up to this stamp
- [x] RECEIVED_FROM must be "sender" or valid npub

### Receipt Validation

- [x] RECIPIENT_NPUB must match header RECIPIENT_NPUB
- [x] DELIVERED_BY must match last stamp's npub
- [x] Signature must verify
- [x] Must appear after at least one stamp

### Return Journey Validation

- [x] RETURN_STAMP can only appear after DELIVERY_RECEIPT
- [x] First RETURN_STAMP must have RECEIVED_FROM: recipient
- [x] Return stamp signatures must verify
- [x] SENDER_ACKNOWLEDGMENT can only appear after return stamps
- [x] SENDER_NPUB in acknowledgment must match header

## Best Practices

### For Senders

1. **Accurate recipient info**: Provide correct npub and multiple locations
2. **Choose type wisely**: Use encrypted for sensitive content
3. **Set reasonable TTL**: Give enough time for delivery (e.g., 7-30 days)
4. **Request return**: Ask carriers to return postcard if you need proof
5. **Monitor status**: Check if delivered, acknowledge receipt

### For Carriers

1. **Verify before stamping**: Always verify all previous signatures
2. **Accurate stamps**: Record correct timestamp and coordinates
3. **Add contributions**: Provide photos/notes proving you carried it
4. **Respect privacy**: Don't try to decrypt encrypted postcards
5. **Timely handoff**: Pass to next carrier or recipient promptly
6. **Geographic routing**: Select postcards heading near your route

### For Recipients

1. **Stamp receipt promptly**: Confirm delivery as soon as received
2. **Enable return**: Allow postcard to return to sender with receipt
3. **Thank carriers**: React/comment to appreciate carriers' work
4. **Verify signatures**: Check signature chain before trusting content

### For Developers

1. **Validate signatures**: Always verify entire chain before accepting
2. **Handle TTL**: Automatically expire and clean up old postcards
3. **Optimize routing**: Help carriers find relevant postcards
4. **Display journey**: Show stamps and contributors in timeline UI
5. **Support encryption**: Implement NIP-04 correctly
6. **Index efficiently**: Build indexes for status, sender, recipient

### For System Administrators

1. **Storage limits**: Set reasonable limits per user/collection
2. **Monitor TTL**: Clean up expired postcards regularly
3. **Backup postcards**: Regular backups of collections
4. **Track statistics**: Monitor delivery rates, hop counts

## Security Considerations

### Cryptographic Security

**Signature Chain**:
- Any tampering breaks signatures
- Verification is purely cryptographic
- No trusted third party needed
- Sender, recipient, and carriers all verifiable

**Encryption**:
- NIP-04 provides end-to-end encryption
- Only sender and recipient can read encrypted content
- Carriers cannot decrypt
- Header remains public for routing

### Privacy Considerations

**Public Information**:
- Sender npub/callsign (necessary for identity)
- Recipient npub/callsign (necessary for routing)
- Recipient locations (necessary for carrier selection)
- All stamps (necessary for proof of transit)
- Delivery receipt (necessary for payment proof)

**Private Information**:
- Message content (if TYPE: encrypted)
- Sender/recipient relationship (somewhat revealed by routing)

**Recommendations**:
- Use encrypted type for sensitive content
- Use general locations (neighborhoods, not exact addresses)
- Consider privacy when listing recipient locations

### Payment Security

**Proof of Work**:
- Stamps prove carriers actually handled postcard
- Timestamps show when
- Coordinates show where
- Signatures prevent forgery

**Settlement Process** (external to Geogram):
1. Sender and carriers agree on payment terms beforehand
2. Postcard travels, accumulating stamps
3. Delivery receipt proves successful delivery
4. Sender reviews stamps and receipt
5. Payment settled based on cryptographic proof
6. Stamps serve as receipts for payment

**Security**:
- Stamps cannot be forged (signature verification)
- Delivery cannot be faked (recipient must sign)
- Return journey proves sender received receipt
- Sender acknowledgment finalizes proof

### Threat Mitigation

**Stamp Forgery**:
- Impossible due to signature requirement
- Forger would need stamper's nsec (private key)
- All participants can verify independently

**Content Tampering**:
- Breaks all subsequent signatures
- Immediately detected on verification
- Postcard rejected as invalid

**Spam**:
- TTL limits lifetime
- Size limits prevent abuse
- Carriers can filter by sender reputation
- Recipients can block specific senders

**Denial of Service**:
- Carriers voluntarily choose what to carry
- No obligation to carry all postcards
- Filtering by payment, priority, sender
- TTL ensures old postcards expire

## Integration with Relay System

### Relationship to Relay Messages

Postcards are built on top of the existing relay message system:

**Relay Message System Provides**:
- BLE protocol for transmission
- Markdown file format
- Geographic routing
- Stamp mechanism
- NOSTR signature support
- TTL and expiration
- Priority handling

**Postcards Add**:
- Collection type organization (by date)
- Formal recipient discovery (RECIPIENT_LOCATIONS)
- Delivery receipt semantics
- Return journey concept
- Sender acknowledgment
- Contributor system
- UI for postcard-specific features

### Technical Integration

**Transmission**:
- Postcards transmitted as relay messages via BLE
- When carrier receives postcard, stamping adds relay stamp
- Relay system handles the physical delivery mechanism
- Collection system handles organization and display

**Storage**:
- Relay messages stored in relay/ folder (transient)
- Postcards stored in postcards/ collection (permanent)
- When postcard delivered, can be saved to collection
- Relay storage can be cleared, collection preserved

**Compatibility**:
- Postcard format compatible with relay message format
- Can convert relay message to postcard for archival
- Stamps in both systems have same format
- Signatures work the same way

### File Conversion

**Relay Message to Postcard**:
```
1. Relay message arrives via BLE
2. If destination is local user, save as postcard
3. Create postcards/YYYY/YYYY-MM-DD_msg-{id}/ folder
4. Save postcard.txt from relay message
5. Keep all stamps and signatures
6. Add to collection for permanent storage
```

**Postcard to Relay Message**:
```
1. User creates postcard in collection
2. Export postcard.txt as relay message
3. Transmit via BLE to first carrier
4. Carrier stamps and forwards
5. Eventually reaches recipient
6. Recipient saves back to their postcards collection
```

## Related Documentation

- [Events Format Specification](events-format-specification.md)
- [Places Format Specification](places-format-specification.md)
- [Chat Format Specification](chat-format-specification.md)
- [Relay Protocol](../relay/relay-protocol.md)
- [Message Integrity](../relay/message-integrity.md)
- [NOSTR Protocol](https://github.com/nostr-protocol/nostr)
- [NIP-04: Encrypted Direct Messages](https://github.com/nostr-protocol/nips/blob/master/04.md)

## Change Log

### Version 2.0 (2026-04-24)

Breaking format changes:

- **Single-file rule**: a postcard is exactly one `postcard.txt`.
  Sibling artifacts — `photo.jpg`, `contributors/`, `.reactions/` —
  are removed. A postcard you receive over BLE, LoRa, or a USB stick
  is now always one file, nothing else.
- **Inline attachments**: binaries ride inside `postcard.txt` as
  base64 blocks between `## ATTACHMENT:` and `<-- end attachment`.
  Each attachment carries its own content-type, size, SHA-256, and
  ADDED_BY npub. Later signatures cover earlier attachments.
- **Removed field**: `PAYMENT_REQUESTED` in the header. Payment intent
  was never implemented in the app; the field only added noise.
- Each transfer still appends one more NOSTR-signed block
  (STAMP / DELIVERY_RECEIPT / RETURN_STAMP / SENDER_ACKNOWLEDGMENT)
  at the bottom, covering everything above it — unchanged.
- Complete Examples rewritten around four stages: in-transit,
  in-transit-with-attachment, delivered, acknowledged, so readers
  can see how the file grows at each hop.

### Version 1.0 (2025-11-21)

**Initial Specification**:
- Sneakernet-based message delivery system
- Date-based organization (YYYY/YYYY-MM-DD_msg-{id}/)
- Cryptographic stamp chain for tamper-proof verification
- **RECEIVED_VIA field**: Documents transmission method for each hop
  - Open text field with recommended values (BLE, LoRa, Radio, Satellite, etc.)
  - Provides visibility into technology used for physical delivery
  - Helps track successful transmission methods
- Open and encrypted content types (NIP-04)
- Delivery receipt mechanism
- Return journey support
- Sender acknowledgment
- Contributor system for carriers to add proof of transit
- Geographic recipient discovery via RECIPIENT_LOCATIONS
- Status tracking (in-transit, delivered, acknowledged, expired)
- Payment proof capability (external settlement)
- Integration with existing relay message system
- NOSTR signature integration (Schnorr signatures)
- Reactions system (likes/comments)
- Moderation system (.hidden/ directory)
- Complete signature verification chain
- Priority and TTL support
