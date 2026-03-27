# Distributed Chat Rooms (`dchat`)

**Status:** storage foundation implemented in `lib/services/profile_sqlite_database.dart` and `lib/services/dchat_room_store.dart`  
**Last updated:** 2026-03-27

## Overview

`dchat` is the distributed restricted-group-chat layer for Geogram. It does not
replace the existing direct-message or legacy room storage. It adds a new
room-local storage model for distributed rooms only:

- one SQLite database for replicated room state
- one SQLite database for local-only device state
- one media tree per room
- NOSTR-signed control and message envelopes stored as SQLite rows instead of
  plain-text chat files

The storage lives inside the active profile folder, under `/{callsign}/dchat/`,
so the data stays compatible with both filesystem profiles and
`EncryptedProfileStorage`.

## Goals

- Keep `dchat` data durable on participant devices.
- Keep all profile-generated `dchat` data under `/{callsign}/dchat/...`.
- Avoid mixing media between rooms so deleting a room is deleting one folder.
- Deduplicate attachments only inside the same room.
- Keep NOSTR identities and signatures as the authorship layer.
- Support future epoch-key rotation and partial offline sync without relying on
  text file ordering.

## Non-Goals

- No changes to existing DM or legacy room storage.
- No shared cross-room media pool.
- No original filenames in stored media paths.
- No full `DistributedChatService` migration in this document; this document
  describes the new storage target and the implemented storage library.

## Implemented Reusable Pieces

- `ProfileSQLiteDatabase`
  Mirrors a SQLite database between `ProfileStorage` and a temporary native
  file, so SQLite can work with both filesystem and encrypted profiles.
- `DChatRoomStore`
  Owns one room folder, initializes the schema, stores room/control/message
  rows, stores room-local device state, and writes media files into room-local
  folders.
- `DChatStorage` models
  Typed records for room metadata, members, epochs, encrypted epoch envelopes,
  messages, media references, and sync cursors.

## Storage Layout

Each distributed room is fully self-contained:

```text
/{callsign}/dchat/
└── {room_id}/
    ├── room.sqlite3
    ├── device.sqlite3
    └── media/
        ├── images/
        │   └── {sha1}.{extension}
        ├── video/
        │   └── {sha1}.{extension}
        ├── audio/
        │   └── {sha1}.{extension}
        ├── files/
        │   └── {sha1}.{extension}
        └── thumbs/
            └── {sha1}.jpg
```

Important rules:

- `room.sqlite3` is the replicated room state.
- `device.sqlite3` is local-only device state.
- media is never shared across rooms
- dedup happens only inside one room, by SHA-1
- deleting a room means deleting `/{callsign}/dchat/{room_id}/`

## `room.sqlite3`

Current schema groups:

- `room_meta`
  Canonical room metadata projection.
- `members`
  Role/status projection for admins, moderators, members, kicked, and banned
  users.
- `control_events`
  Raw signed NOSTR control events plus lamport ordering fields.
- `epochs`
  Epoch metadata for forward-access control.
- `epoch_key_boxes`
  Per-recipient encrypted epoch-key envelopes.
- `messages`
  Message envelopes, ciphertext blobs, nonce, algorithm tag, and raw signed
  NOSTR event JSON.
- `media_refs`
  Metadata for attachments stored in the room-local media folders.
- `message_media`
  Attachment links per message.
- `sync_cursors`
  Replicated cursors that are safe to share between peers.

## `device.sqlite3`

Current schema groups:

- `device_values`
  Local secrets and device-only values such as room signer secrets or decrypted
  epoch keys.
- `pending_outbox`
  Placeholder queue for locally pending outbound payloads.
- `local_sync_state`
  Per-peer local sync attempts and local-only diagnostics.

`device.sqlite3` is intentionally separate from `room.sqlite3` so secret material
and device-only cursors do not get mixed into replicated room state.

## Media Rules

Media files stay as files, not SQLite blobs.

- Images go in `media/images/`
- Video goes in `media/video/`
- Audio goes in `media/audio/`
- Generic documents go in `media/files/`
- Generated thumbnails go in `media/thumbs/`

The stored filename format is always:

```text
{sha1}.{extension}
```

The original filename, MIME type, size, and room-local logical path live in
`room.sqlite3`, not in the filesystem name.

## Control And Message Model

`dchat` still uses NOSTR for identity and signatures.

- Control rows store signed `DistributedChatControlEvent` JSON.
- Message rows store the raw signed NOSTR event JSON plus ciphertext and
  ordering fields.
- This keeps the transport/authentication layer reusable while removing the
  need to append and merge human-readable text files.

## Next Integration Steps

The implemented storage library is the target backend for the higher-level
distributed-room orchestration:

1. migrate `DistributedChatService` from text files to `DChatRoomStore`
2. add epoch-rotation writes on membership changes
3. sync `room.sqlite3` and room-local media trees between peers
4. exclude `device.sqlite3` from peer-replicated room sync
5. wire the chat UI to the new room store

## Verification

Implemented verification currently lives in:

- `test/dchat_room_store_test.dart`

The test covers:

- `ProfileSQLiteDatabase` with `FilesystemProfileStorage`
- `ProfileSQLiteDatabase` with `EncryptedProfileStorage`
- room schema creation for `room.sqlite3` and `device.sqlite3`
- room-local media layout creation
- same-room media dedup by SHA-1
- cross-room media isolation
- persistence of room metadata, control events, epochs, epoch envelopes,
  messages, media links, sync cursors, and local-only device values
- whole-room deletion by removing one room folder

## Related Files

- `lib/services/profile_sqlite_database.dart`
- `lib/services/dchat_room_store.dart`
- `lib/models/dchat_storage.dart`
- `test/dchat_room_store_test.dart`
- `docs/reusable.md`
