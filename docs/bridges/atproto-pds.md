# AT Protocol PDS for Geogram

> Implementation plan for embedding a single-user AT Protocol Personal Data Server
> into Geogram clients and stations.

## Design Principles

1. **Client-side PDS** — Each Geogram device (desktop/mobile) runs its own PDS.
   User data lives on the user's own device, not on stations. This preserves
   Geogram's sovereignty model: users own their data and can switch stations freely.
2. **Station as relay** — Stations act as relays/proxies for federation (firehose,
   `requestCrawl`), NOT as data stores for user repos. Stations may cache or relay
   firehose events, but repos live on client devices.
3. **NSID namespace** — All Geogram lexicons use `radio.geogram.*`.
4. **Minimal new deps** — Only `cbor` package added. Everything else reuses existing
   Geogram infrastructure.

---

## Reuse Map

| AT Proto Need | Reuses | Existing File |
|---|---|---|
| Blob storage (SHA-256 addressed) | `NostrBlossomService` | `lib/services/nostr_blossom_service.dart` |
| secp256k1 EC operations | `NostrCrypto` + PointyCastle | `lib/util/nostr_crypto.dart` |
| SHA-256 hashing | `package:crypto` | Already in pubspec |
| HTTP server + routing | `StationServerBase` | `lib/server/station_server_base.dart` |
| WebSocket handling | Station WebSocket infra | `lib/server/station_server_base.dart` |
| SQLite patterns | `NostrRelayStorage` | `lib/services/nostr_relay_storage.dart` |
| Rate limiting | `RateLimitMixin` | `lib/server/mixins/rate_limit_mixin.dart` |
| SSL/TLS termination | `SslMixin` | `lib/server/mixins/ssl_mixin.dart` |
| `.well-known/` serving | Existing `nostr.json` pattern | `lib/server/station_server_base.dart` |

---

## File Map

### New Files

```
lib/atproto/
  dag_cbor.dart              # Deterministic CBOR (sorted keys, no floats, CID tag 42)
  cid.dart                   # CID v1: SHA-256 -> multihash -> DAG-CBOR codec 0x71
  mst.dart                   # Merkle Search Tree (fanout=4, prefix compression)
  car.dart                   # CAR v1 file reader/writer
  tid.dart                   # Timestamp ID generator (13-char base32-sortable)
  signing.dart               # ECDSA-secp256k1 with low-S normalization
  repo.dart                  # Repository manager (MST + signing + storage)
  atproto_storage.dart       # SQLite block store
  xrpc_router.dart           # Route /xrpc/{nsid} to handlers
  jwt_service.dart           # HS256 JWT (sub=did)
  did_service.dart           # did:web document + Multikey encoding
  at_uri.dart                # Parse at://did/collection/rkey URIs
  firehose.dart              # WebSocket event stream (subscribeRepos)
  xrpc/
    server_endpoints.dart    # describeServer, createSession, refreshSession, deleteSession
    identity_endpoints.dart  # resolveHandle, updateHandle
    repo_endpoints.dart      # createRecord, putRecord, deleteRecord, getRecord, listRecords, etc.
    sync_endpoints.dart      # getRepo, getRecord, listRepos, getBlob, getLatestCommit, etc.
  collections/
    blog_collection.dart     # radio.geogram.blog.post
    places_collection.dart   # radio.geogram.places.entry
    alerts_collection.dart   # radio.geogram.alerts.report

lib/server/mixins/
  atproto_pds_mixin.dart     # Shared mixin for both station types
```

### Modified Files

| File | Change |
|---|---|
| `lib/server/station_server_base.dart` | XRPC routing, firehose WebSocket, DID document |
| `lib/server/station_settings.dart` | AT Proto toggle + settings |
| `lib/server/app_station_server.dart` | Add `AtprotoPdsMixin` |
| `lib/cli/pure_station.dart` | Add `AtprotoPdsMixin` |
| `pubspec.yaml` | Add `cbor` dependency |

---

## Phase 1 — Core Data Structures

> Build the encoding layer that everything else sits on top of.

### 1.1 `dag_cbor.dart` — Deterministic CBOR

Implements the [DAG-CBOR](https://ipld.io/specs/codecs/dag-cbor/spec/) subset:

- **Sorted map keys** — lexicographic byte ordering (required for deterministic hashing)
- **No floats** — AT Proto forbids them in repo data
- **CID links** — CBOR tag 42 wrapping raw CID bytes
- **Byte strings** — for blobs and CID references

Uses `package:cbor` for low-level encoding; wraps it to enforce determinism.

```dart
// lib/atproto/dag_cbor.dart
class DagCbor {
  /// Encode a Dart map/list/value to deterministic DAG-CBOR bytes.
  static Uint8List encode(dynamic value);

  /// Decode DAG-CBOR bytes back to Dart objects.
  /// CID links are returned as CidLink instances.
  static dynamic decode(Uint8List bytes);
}

class CidLink {
  final Cid cid;
  CidLink(this.cid);
}
```

### 1.2 `cid.dart` — Content Identifiers

CID v1 with:
- Multicodec: `dag-cbor` (0x71)
- Multihash: SHA-256 (0x12), 32-byte digest
- Multibase: base32lower for string representation

```dart
class Cid {
  final Uint8List hash;  // raw SHA-256 digest

  /// Create CID from raw content bytes.
  factory Cid.fromBytes(Uint8List dagCborBytes);

  /// Parse CID from multibase string.
  factory Cid.fromString(String multibase);

  /// Encode as raw CID bytes (no multibase prefix).
  Uint8List toBytes();

  /// Encode as multibase string (base32lower).
  String toBase32();
}
```

### 1.3 `mst.dart` — Merkle Search Tree

The core data structure of AT Proto repos. Each collection is an MST mapping
`rkey` -> record CID.

- **Fanout**: 4 (2-bit prefix from leading zeros of `SHA-256(key)`)
- **Key format**: `collection/rkey` (e.g., `radio.geogram.blog.post/3jui7p2blaz2c`)
- **Prefix compression**: keys share common prefixes within tree nodes
- **Deterministic**: same keys always produce the same tree shape

```dart
class MerkleSearchTree {
  /// Insert a key-value pair (key = "collection/rkey", value = record CID).
  Future<Cid> insert(String key, Cid valueCid);

  /// Delete a key.
  Future<Cid> delete(String key);

  /// Get the CID for a key.
  Future<Cid?> get(String key);

  /// List keys matching a collection prefix.
  Future<List<MstEntry>> list({String? prefix, int? limit, String? cursor});

  /// Get the root CID (for signing).
  Cid get rootCid;
}

class MstEntry {
  final String key;     // "collection/rkey"
  final Cid valueCid;   // CID of the record
}
```

Implementation note: ~200-300 lines. Reference: picopds `mst.py`.

### 1.4 `car.dart` — Content-Addressable aRchive

CAR v1 format for repo export/import:

```dart
class CarWriter {
  /// Create a CAR file with the given root CID and blocks.
  static Uint8List write(Cid root, Map<Cid, Uint8List> blocks);
}

class CarReader {
  /// Parse a CAR file into root CID + block map.
  static (Cid root, Map<Cid, Uint8List> blocks) read(Uint8List carBytes);
}
```

### 1.5 `tid.dart` — Timestamp IDs

Record keys (rkeys) use TIDs: 13-character base32-sortable identifiers encoding
microsecond timestamp + 10-bit clock ID.

```dart
class Tid {
  /// Generate a new TID for the current microsecond.
  static String next();

  /// Parse a TID string back to its timestamp.
  static DateTime parse(String tid);
}
```

### 1.6 `signing.dart` — ECDSA Wrapper

AT Proto uses ECDSA-secp256k1 (NOT Schnorr). Reuses `NostrCrypto` for the EC
math, wraps it to produce/verify ECDSA signatures with **low-S normalization**
(required by AT Proto).

```dart
class AtprotoSigning {
  /// Sign DAG-CBOR bytes with the repo signing key.
  /// Returns DER-encoded ECDSA signature with low-S.
  static Uint8List sign(Uint8List data, Uint8List privateKey);

  /// Verify an ECDSA signature against a public key.
  static bool verify(Uint8List data, Uint8List signature, Uint8List publicKey);

  /// Encode a secp256k1 public key as Multikey (0xe7 prefix + compressed point).
  static String publicKeyToMultikey(Uint8List compressedPubkey);
}
```

### 1.7 `atproto_storage.dart` — SQLite Block Store

Persists MST nodes, records, and commit objects. Follows `NostrRelayStorage`
patterns for SQLite access.

```sql
-- blocks: content-addressed DAG-CBOR blobs
CREATE TABLE blocks (
  cid       TEXT PRIMARY KEY,
  content   BLOB NOT NULL
);

-- repos: one row per hosted repo (single-user, so just one row)
CREATE TABLE repos (
  did       TEXT PRIMARY KEY,
  head      TEXT NOT NULL,        -- CID of latest signed commit
  signing_key BLOB NOT NULL       -- encrypted private key
);

-- records: index for fast record lookups without MST traversal
CREATE TABLE records (
  uri       TEXT PRIMARY KEY,     -- at://did/collection/rkey
  cid       TEXT NOT NULL,
  collection TEXT NOT NULL,
  rkey      TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_records_collection ON records(collection, rkey);

-- sequence: monotonic counter for firehose events
CREATE TABLE sequence (
  seq       INTEGER PRIMARY KEY AUTOINCREMENT,
  event     BLOB NOT NULL,        -- DAG-CBOR encoded event
  created_at INTEGER NOT NULL
);
```

### 1.8 `repo.dart` — Repository Manager

Orchestrates MST + signing + storage into a complete AT Proto repository.

```dart
class AtprotoRepo {
  final AtprotoStorage storage;
  final MerkleSearchTree mst;

  /// Create a new record in a collection. Returns (AT-URI, CID).
  Future<(String uri, Cid cid)> createRecord(String collection, Map<String, dynamic> record);

  /// Get a record by AT-URI.
  Future<Map<String, dynamic>?> getRecord(String collection, String rkey);

  /// Delete a record.
  Future<void> deleteRecord(String collection, String rkey);

  /// List records in a collection.
  Future<List<RepoRecord>> listRecords(String collection, {int? limit, String? cursor});

  /// Create a signed commit for the current repo state.
  /// Returns the commit CID.
  Future<Cid> commit();

  /// Export the entire repo as a CAR file.
  Future<Uint8List> exportCar();
}
```

### Phase 1 Testing

- Unit tests for DAG-CBOR round-trip with known test vectors
- Unit tests for CID computation against reference values
- Unit tests for MST insert/delete/get with known tree shapes
- Unit tests for TID generation (monotonic, correct length)
- Unit tests for ECDSA signing + verification round-trip
- Integration test: create repo, add records, export CAR, reimport, verify root CID matches

---

## Phase 2 — XRPC Routing + Auth + DID

> Make the PDS reachable over HTTP and authenticate users.

### 2.1 `xrpc_router.dart` — XRPC Routing

Maps `/xrpc/{nsid}` to handler functions. Integrates into `StationServerBase`
routing.

```dart
class XrpcRouter {
  /// Register a query (GET) handler.
  void query(String nsid, XrpcHandler handler);

  /// Register a procedure (POST) handler.
  void procedure(String nsid, XrpcHandler handler);

  /// Route an incoming request. Returns null if not an XRPC request.
  Future<Response?> handle(Request request);
}

typedef XrpcHandler = Future<Response> Function(Request request, Map<String, String> params);
```

### 2.2 `jwt_service.dart` — Session Tokens

Simple HS256 JWT for single-user authentication:

- `createSession` → returns `accessJwt` (5 min) + `refreshJwt` (90 days)
- `refreshSession` → rotates tokens
- Auth middleware: `Authorization: Bearer <accessJwt>` → extracts DID from `sub` claim

Since this is a single-user PDS, the "password" is the station admin credential.

### 2.3 `did_service.dart` — DID:web

Serves `/.well-known/did.json` with the PDS's DID document:

```json
{
  "@context": ["https://www.w3.org/ns/did/v1", "https://w3id.org/security/multikey/v1"],
  "id": "did:web:example.geogram.radio",
  "alsoKnownAs": ["at://handle.example.com"],
  "verificationMethod": [{
    "id": "did:web:example.geogram.radio#atproto",
    "type": "Multikey",
    "controller": "did:web:example.geogram.radio",
    "publicKeyMultibase": "zQ3sh..."
  }],
  "service": [{
    "id": "#atproto_pds",
    "type": "AtprotoPersonalDataServer",
    "serviceEndpoint": "https://example.geogram.radio"
  }]
}
```

The `publicKeyMultibase` uses the `0xe7` prefix for secp256k1, followed by
the 33-byte compressed public key, base58btc-encoded with `z` multibase prefix.

### 2.4 Server Endpoints (`xrpc/server_endpoints.dart`)

| Endpoint | Method | Auth | Notes |
|---|---|---|---|
| `com.atproto.server.describeServer` | GET | No | Returns `did`, `availableUserDomains` |
| `com.atproto.server.createSession` | POST | No | Identifier + password → JWT pair |
| `com.atproto.server.refreshSession` | POST | Yes | Rotate JWT tokens |
| `com.atproto.server.deleteSession` | POST | Yes | Invalidate refresh token |

### 2.5 Identity Endpoints (`xrpc/identity_endpoints.dart`)

| Endpoint | Method | Auth | Notes |
|---|---|---|---|
| `com.atproto.identity.resolveHandle` | GET | No | Handle → DID |
| `com.atproto.identity.updateHandle` | POST | Yes | Change handle (single-user, rarely used) |

### 2.6 `atproto_pds_mixin.dart` — Shared Mixin

Applied to both `StationServer` (Desktop) and `PureStationServer` (CLI):

```dart
mixin AtprotoPdsMixin {
  late final XrpcRouter _xrpcRouter;
  late final AtprotoRepo _atprotoRepo;
  late final JwtService _jwtService;
  late final DidService _didService;

  Future<void> initAtproto();
  Future<Response?> handleAtprotoRequest(Request request);
  void disposeAtproto();
}
```

### Phase 2 Testing

- Debug API endpoint: `GET /api/atproto/status` — returns PDS status (DID, handle, repo head, record count)
- Test `createSession` / `refreshSession` flow via debug API
- Verify `/.well-known/did.json` serves valid DID document
- Test XRPC routing with `describeServer`

---

## Phase 3 — Repository Operations

> CRUD operations on the AT Proto repo.

### 3.1 `at_uri.dart` — AT-URI Parser

```dart
class AtUri {
  final String authority;   // DID or handle
  final String collection;  // NSID
  final String rkey;        // record key

  factory AtUri.parse(String uri);  // "at://did:web:example/radio.geogram.blog.post/3jui7p2blaz2c"
  String toString();
}
```

### 3.2 Repo Endpoints (`xrpc/repo_endpoints.dart`)

| Endpoint | Method | Auth | Notes |
|---|---|---|---|
| `com.atproto.repo.createRecord` | POST | Yes | Insert record, return URI + CID |
| `com.atproto.repo.putRecord` | POST | Yes | Upsert with explicit rkey |
| `com.atproto.repo.deleteRecord` | POST | Yes | Remove record from MST |
| `com.atproto.repo.getRecord` | GET | No | Fetch record by AT-URI |
| `com.atproto.repo.listRecords` | GET | No | Paginated list by collection |
| `com.atproto.repo.describeRepo` | GET | No | DID, handle, collections list |
| `com.atproto.repo.applyWrites` | POST | Yes | Batch create/update/delete |
| `com.atproto.repo.uploadBlob` | POST | Yes | Delegates to `NostrBlossomService` |

### 3.3 Blob Handling

`uploadBlob` delegates to the existing `NostrBlossomService`:

1. Receive blob via multipart upload
2. Store via Blossom (SHA-256 addressed — same model as AT Proto)
3. Return `{ "$type": "blob", "ref": { "$link": "<CID>" }, "mimeType": "...", "size": N }`
4. Records reference blobs by CID; the repo doesn't store blob bytes in the MST

### Phase 3 Testing

- Debug API: `POST /api/atproto/test-record` — creates a test record and reads it back
- Verify `createRecord` → `getRecord` round-trip
- Verify `listRecords` pagination
- Verify `deleteRecord` removes from MST and `getRecord` returns 404
- Verify `uploadBlob` stores via Blossom and returns valid blob ref
- Verify `applyWrites` batch operations

---

## Phase 4 — Sync + Firehose (Federation)

> Enable other AT Proto services to discover and replicate data.

### 4.1 Sync Endpoints (`xrpc/sync_endpoints.dart`)

| Endpoint | Method | Auth | Notes |
|---|---|---|---|
| `com.atproto.sync.getRepo` | GET | No | Full repo as CAR file |
| `com.atproto.sync.getRecord` | GET | No | Single record as CAR proof |
| `com.atproto.sync.listRepos` | GET | No | Single-user → one entry |
| `com.atproto.sync.listBlobs` | GET | No | Blob CIDs for a DID |
| `com.atproto.sync.getBlob` | GET | No | Fetch blob by CID |
| `com.atproto.sync.getLatestCommit` | GET | No | Current repo head CID + rev |
| `com.atproto.sync.requestCrawl` | POST | No | Notify relay to index this PDS |

### 4.2 `firehose.dart` — Event Stream

WebSocket at `/xrpc/com.atproto.sync.subscribeRepos`:

- Binary DAG-CBOR frames (header + body)
- Header: `{ "op": 1, "t": "#commit" }` for commits
- Body: commit details including `ops` array (create/update/delete per record)
- `seq` numbers are monotonic integers from the `sequence` table
- Cursor support: client can reconnect with `?cursor=<seq>` to resume

Frame types:
- `#commit` — repo mutation (the primary event)
- `#identity` — handle change
- `#info` — server status messages

Station relay behavior:
- Stations **do not** store repos, but may subscribe to their clients' firehoses
- Stations can relay firehose events to external consumers (BGS/relays)
- `requestCrawl` tells an external relay to start consuming this PDS's firehose

### 4.3 DID:plc Support

Add `did:plc` as an alternative to `did:web`:

- `did:plc` provides portability — the DID is not tied to a domain name
- Operation log published to `plc.directory`
- Signed rotation keys allow DID recovery
- Migration path: start with `did:web`, add `did:plc` as `alsoKnownAs`

### Phase 4 Testing

- Debug API: `GET /api/atproto/test-firehose` — creates a record and returns the firehose event
- Test `getRepo` returns valid CAR with correct root
- Test `subscribeRepos` WebSocket delivers events in real-time
- Test cursor-based reconnection (disconnect, reconnect with cursor, get missed events)
- Test `requestCrawl` sends notification to a configured relay URL

---

## Phase 5 — Geogram Content Collections

> Map existing Geogram content to AT Proto lexicon collections.

### 5.1 Collection Mapping

| Geogram Feature | AT Collection NSID | Source Data | rkey Strategy |
|---|---|---|---|
| Blog posts | `radio.geogram.blog.post` | `blog/{year}/{postId}/post.md` | TID from post timestamp |
| Places | `radio.geogram.places.entry` | `places/{folder}/place.txt` | TID from creation time |
| Alerts | `radio.geogram.alerts.report` | `alerts/active/{region}/{folder}/report.txt` | TID from report time |
| Events | `radio.geogram.events.entry` | `events/{eventId}/` | TID from event creation |

### 5.2 Lexicon Definitions

#### `radio.geogram.blog.post`

```json
{
  "lexicon": 1,
  "id": "radio.geogram.blog.post",
  "defs": {
    "main": {
      "type": "record",
      "key": "tid",
      "record": {
        "type": "object",
        "required": ["title", "content", "createdAt"],
        "properties": {
          "title":     { "type": "string", "maxLength": 300 },
          "content":   { "type": "string", "maxLength": 100000, "description": "Markdown body" },
          "summary":   { "type": "string", "maxLength": 1000 },
          "tags":      { "type": "array", "items": { "type": "string" }, "maxLength": 20 },
          "image":     { "type": "blob", "accept": ["image/*"], "maxSize": 5000000 },
          "createdAt": { "type": "string", "format": "datetime" }
        }
      }
    }
  }
}
```

#### `radio.geogram.places.entry`

```json
{
  "lexicon": 1,
  "id": "radio.geogram.places.entry",
  "defs": {
    "main": {
      "type": "record",
      "key": "tid",
      "record": {
        "type": "object",
        "required": ["name", "latitude", "longitude", "createdAt"],
        "properties": {
          "name":        { "type": "string", "maxLength": 300 },
          "description": { "type": "string", "maxLength": 5000 },
          "latitude":    { "type": "number" },
          "longitude":   { "type": "number" },
          "altitude":    { "type": "number" },
          "category":    { "type": "string", "maxLength": 100 },
          "image":       { "type": "blob", "accept": ["image/*"], "maxSize": 5000000 },
          "createdAt":   { "type": "string", "format": "datetime" }
        }
      }
    }
  }
}
```

#### `radio.geogram.alerts.report`

```json
{
  "lexicon": 1,
  "id": "radio.geogram.alerts.report",
  "defs": {
    "main": {
      "type": "record",
      "key": "tid",
      "record": {
        "type": "object",
        "required": ["type", "region", "severity", "createdAt"],
        "properties": {
          "type":        { "type": "string", "maxLength": 100, "description": "Alert type (weather, safety, etc.)" },
          "region":      { "type": "string", "maxLength": 200 },
          "severity":    { "type": "string", "enum": ["info", "warning", "critical"] },
          "title":       { "type": "string", "maxLength": 300 },
          "description": { "type": "string", "maxLength": 10000 },
          "latitude":    { "type": "number" },
          "longitude":   { "type": "number" },
          "expiresAt":   { "type": "string", "format": "datetime" },
          "createdAt":   { "type": "string", "format": "datetime" }
        }
      }
    }
  }
}
```

### 5.3 Collection Adapters (`lib/atproto/collections/`)

Each adapter reads Geogram's existing file-based content and maps it to/from
AT Proto records:

```dart
// Example: blog_collection.dart
class BlogCollection {
  static const nsid = 'radio.geogram.blog.post';

  /// Convert a Geogram blog post to an AT Proto record map.
  static Map<String, dynamic> toRecord(BlogPost post);

  /// Convert an AT Proto record back to a BlogPost.
  static BlogPost fromRecord(Map<String, dynamic> record);

  /// Sync all existing blog posts into the AT Proto repo.
  Future<void> syncAll(AtprotoRepo repo, ProfileStorage storage);

  /// Watch for new blog posts and auto-publish to AT repo.
  StreamSubscription watchAndPublish(AtprotoRepo repo, ProfileStorage storage);
}
```

### 5.4 Auto-Sync Behavior

When AT Proto is enabled:
1. On startup, sync existing content to the AT repo (idempotent — skip if rkey exists)
2. Watch for new content creation and auto-create AT records
3. Watch for content deletion and auto-delete AT records
4. Edits create new commits with updated records

### Phase 5 Testing

- Debug API: `GET /api/atproto/collections` — list all collections with record counts
- Debug API: `POST /api/atproto/sync-collection?nsid=radio.geogram.blog.post` — trigger sync
- Verify blog posts appear as `radio.geogram.blog.post` records
- Verify places appear as `radio.geogram.places.entry` records
- Verify new content auto-publishes to AT repo
- End-to-end: create a blog post via Geogram → verify it appears via `com.atproto.repo.getRecord`

---

## Settings

Add to station settings (both CLI and Desktop):

```yaml
atproto:
  enabled: false            # Master toggle
  handle: "user.geogram.radio"
  did_method: "web"         # "web" or "plc"
  relay_url: ""             # External BGS/relay to notify via requestCrawl
  auto_sync: true           # Auto-sync Geogram content to AT repo
  collections:              # Which collections to expose
    - radio.geogram.blog.post
    - radio.geogram.places.entry
    - radio.geogram.alerts.report
    - radio.geogram.events.entry
```

---

## Implementation Order

```
Phase 1  ──►  Phase 2  ──►  Phase 3  ──►  Phase 4  ──►  Phase 5
 (core)       (XRPC+     (repo CRUD)    (federation)   (Geogram
               auth+DID)                                 content)
```

Each phase is independently testable. Phase 1 has no HTTP dependency.
Phases 2-3 make the PDS functional for local use. Phase 4 enables federation.
Phase 5 bridges Geogram's existing content into the AT network.

---

## Reference Implementations

- **picopds** (Python) — Minimal single-user PDS, ~1000 lines. Components: `mst.py`, `carfile.py`, `repo.py`, `signing.py`, `pds.py`. Good reference for MST and signing logic.
- **atproto.dart** — Community Dart package. Partial coverage. May be useful for XRPC types but doesn't provide PDS server-side functionality.
- **indigo** (Go) — Bluesky's reference PDS. Comprehensive but complex. Good for understanding sync protocol edge cases.
