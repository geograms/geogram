# Distributed Chat Rooms (`dchat`)

**Status:** implemented core storage/orchestration in `lib/services/distributed_chat_service.dart`  
**Last updated:** 2026-03-27

## Overview

`dchat` is the distributed-room layer for Geogram group chat. It does not replace
the existing chat system. Instead, it reuses the current chat file format, room
config model, moderation rules, and NOSTR signing flow, then adds:

- an append-only control log for room governance
- invite/apply/approve flows for restricted groups
- a room signer key for admissions
- encrypted room-key sharing for admins and moderators
- peer-to-peer room repair/bootstrap sync

This solves the current server-room problem where the conversation disappears
when the original server goes offline. In `dchat`, every participant keeps a
local copy of room metadata and messages. Any active member can help bootstrap a
newly approved member or repair a stale room copy.

## Goals

- Keep group history durable on participant devices.
- Reuse the existing chat message format and per-day room files.
- Reuse existing role and moderation logic from `ChatService`.
- Keep actor identity tied to the user’s NOSTR identity.
- Allow admins/moderators with room signing access to approve queued applicants.
- Preserve old messages for kicked users while blocking new ones.
- Fit into the current transport stack: LAN, WebRTC, DHT discovery, peer relay,
  and sync.

## Non-Goals

- No new message file format.
- No duplicate chat storage implementation beside `ChatService`.
- No v1 end-to-end room-content encryption scheme.
- No raw DHT payload transport rewrite. DHT remains discovery/signaling oriented
  as documented in `docs/bridges/BT-DHT.md`.

## Reuse Map

`dchat` is built on top of existing components:

- `ChatService`
  Reuses room creation, membership application storage, approval, moderation,
  delete/edit rules, and message persistence.
- `ChatChannelConfig`
  Holds the projected room state used by UI and authorization checks.
- `docs/apps/chat-format-specification.md`
  Message bodies still use the existing plain-text chat format.
- `SigningService` / `NostrEvent`
  Regular chat messages and control/admission events remain NOSTR-authenticated.
- `BackupEncryption`
  Reused to share the room `nsec` to admins/moderators encrypted to their
  `npub`.
- `MirrorSyncService`
  Still the right bulk-transfer primitive for room subtree bootstrap/repair.
- `ConnectionManager` + BT-DHT + peer relay
  Still the right live-discovery and routing layer for future remote delivery of
  control/message envelopes.

## Room Model

Distributed rooms extend the existing room config instead of replacing it.

Additional fields in `ChatChannelConfig`:

- `dailyFiles`
- `distributionMode`
- `roomNpub`
- `roomState`
- `joinPolicy`
- `seedPeerHints`

Current `dchat` values:

- `distributionMode = "distributed"`
- `dailyFiles = true`
- `joinPolicy = "approval_required"`
- `roomState ∈ {active, paused, closed}`

The projected role state is still kept in the existing fields:

- `owner`
- `admins`
- `moderatorNpubs`
- `members`
- `banned`
- `pendingApplicants`

## Storage Layout

`dchat` keeps the existing room folder shape and adds one governance log:

```text
{chat_app}/
└── {roomId}/
    ├── config.json
    ├── 2026/
    │   ├── 2026-03-27_chat.txt
    │   └── files/
    └── extra/
        ├── chat/
        │   └── {roomId}/
        │       └── modifications.jsonl
        └── dchat/
            └── control.jsonl
```

Important points:

- Messages stay in the normal daily chat files.
- Message edits/deletes still reuse the existing modification log path.
- Governance and membership changes live in `control.jsonl`.
- The room signer secret (`nsec`) is not stored in the room folder.
- Room signer secrets are stored locally via `ConfigService` or injected secret
  storage callbacks.

## Authority Model

`dchat` uses two layers of keys:

### 1. Personal NOSTR identity

Every participant keeps acting as themselves for:

- chat messages
- moderation actions
- role changes
- membership decisions

That preserves auditability and keeps room history attributable to a real user
key, not a shared secret.

### 2. Room signer key

Every distributed room has a dedicated room signer keypair:

- `roomNpub` goes in room metadata and invite payloads
- `roomNsec` stays local
- admins/moderators receive `roomNsec` encrypted to their `npub`

The room signer is currently used for:

- admission capabilities attached to `join_approved`
- room-key sharing to new admins/moderators

It is not used for ordinary messages.

## Control Log

The control log is append-only JSONL. Each line is a signed NOSTR event tagged
with:

- `room`
- `control`
- `callsign`
- optional `target`
- optional `role`
- optional `state`
- optional message deletion references

Implemented control types:

- `room_created`
- `join_requested`
- `join_approved`
- `join_rejected`
- `room_key_shared`
- `member_removed`
- `member_banned`
- `member_unbanned`
- `moderator_granted`
- `moderator_revoked`
- `admin_granted`
- `admin_revoked`
- `room_paused`
- `room_resumed`
- `room_closed`
- `message_deleted`

The control log is authoritative for distributed-room state replay. `config.json`
remains the local projected state used by the UI and by existing `ChatService`
permission checks.

## Invite And Join Flow

### Invite generation

Invite links are encoded as:

```text
geogram://dchat?payload=...
```

The payload contains:

- `room_id`
- `room_name`
- `room_description`
- `owner_npub`
- `room_npub`
- `join_policy`
- `distribution_mode`
- optional `host_callsign`
- optional `seed_peer_hints`

### Applicant flow

1. User opens the invite link.
2. A local stub room is created with distributed metadata.
3. The applicant emits `join_requested`, signed with their own NOSTR identity.
4. Current members sync or relay that control event to admins/moderators.
5. Applicant remains pending and must not receive room history yet.

### Approval flow

1. Admin/mod reviews `pendingApplicants`.
2. Approver emits `join_approved`.
3. The approval contains an admission capability signed by the room `nsec`.
4. Once the applicant syncs that control event, they become a member.
5. After approval, room bootstrap/repair may copy prior history to the member.

## Moderator/Admin Key Distribution

When a member is promoted to moderator or admin:

1. the role change is written to the control log
2. the promoting admin emits `room_key_shared`
3. the room `nsec` is encrypted with `BackupEncryption.encryptFile(...)`
   to the promoted user’s `npub`
4. the target user decrypts it locally with their own `nsec`
5. the decrypted `roomNsec` must derive back to the room’s `roomNpub`

This is the current answer to:

> admins and mods have access to generate the required permissions and challenges

Regular members do not receive the room signing key.

## Messaging

Regular messages still use the existing chat text format and the standard NOSTR
message tags:

- `['t', 'chat']`
- `['room', roomId]`
- `['callsign', authorCallsign]`

Storage remains:

- one file per room for 1:1 chat
- one file per day for distributed/high-activity rooms

`dchat` intentionally keeps the message format compatible with the current chat
reader/parser.

## Sync And Replication

Current implementation provides a room-level sync primitive:

- `DistributedChatService.syncRoomFromPeer(peer, roomId)`

It does two things:

1. imports missing control-log events
2. copies missing room messages that the local user is allowed to retain

This is the current durable/repair mechanism used by the temp-instance tests.

### Intended transport layering

For live deployment, the same control/message payloads should travel over the
existing routing stack:

- LAN when available
- WebRTC when a direct session is active
- DHT for discovery/reachability refresh
- peer relay when direct reachability is not available

That transport layer is complementary to `dchat`; it should wrap these room
events, not create a second room protocol.

### Attachments

Attachments should continue using the room subtree and existing sync/download
mechanisms. `dchat` does not introduce a separate attachment protocol.

## Kick/Ban Semantics

The rule is:

- kicked/banned members keep old cached messages
- they must not receive new messages or future governance updates that grant
  access back implicitly

Current enforcement:

- `member_removed` / `member_banned` establishes an access cutoff timestamp
- `syncRoomFromPeer()` only copies messages older than that cutoff
- if the user is only pending and never approved, message sync is skipped
- local send attempts after removal fail because `ChatChannelConfig.canWrite()`
  becomes false

This gives the intended behavior:

- old history remains readable
- no new history arrives after removal

## Room State

`roomState` is projected into `ChatChannelConfig`:

- `active`
  members can read/write
- `paused`
  reads remain allowed, new writes are blocked
- `closed`
  room is archived locally and no new writes should happen

Current implementation allows admins and above to emit:

- `room_paused`
- `room_resumed`
- `room_closed`

## Implemented API Surface

Current reusable entry point:

- `lib/services/distributed_chat_service.dart`

Main methods:

- `createDistributedRoom(...)`
- `createInvite(...)`
- `acceptInviteAndRequestJoin(...)`
- `approveApplicant(...)`
- `rejectApplicant(...)`
- `promoteToModerator(...)`
- `promoteToAdmin(...)`
- `shareRoomSecret(...)`
- `removeMember(...)`
- `banMember(...)`
- `unbanMember(...)`
- `pauseRoom(...)`
- `resumeRoom(...)`
- `closeRoom(...)`
- `deleteMessage(...)`
- `sendMessage(...)`
- `syncRoomFromPeer(...)`

Data models:

- `DistributedChatInvite`
- `DistributedChatAdmission`
- `DistributedChatControlEvent`
- `DistributedChatControlType`

## Verification

Implemented verification currently lives in:

- `test/distributed_chat_service_test.dart`

The test exercises three temp profiles and validates:

- room creation and invite generation
- queued join requests
- approval and history bootstrap
- moderator promotion plus encrypted room-key handoff
- moderator approval of another member
- daily-file room storage
- kick behavior that preserves old history and blocks new messages

## Follow-Up Work

Still expected after this core implementation:

- UI integration in the chat browser/room management pages
- live envelope delivery over `ConnectionManager`
- optional subtree bootstrap through `MirrorSyncService`
- attachment/room-subtree repair UX
- possible room-key rotation events if a moderator device is compromised

## Related Files

- `lib/services/distributed_chat_service.dart`
- `lib/models/distributed_chat.dart`
- `lib/services/chat_service.dart`
- `lib/models/chat_channel.dart`
- `docs/apps/chat-format-specification.md`
- `docs/bridges/BT-DHT.md`
- `docs/reusable.md`
