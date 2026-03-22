# BitTorrent DHT Bridge for P2P Discovery

**Version**: 1.2
**Status**: Cross-network discovery working. Android memory optimization pending.
**Last Updated**: 2026-03-22

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [DHT Topics](#dht-topics)
- [Node Types](#node-types)
- [Connection Flow](#connection-flow)
- [Iterative Lookup](#iterative-lookup)
- [Implementation](#implementation)
- [Devices UI Integration](#devices-ui-integration)
- [Same-Household Devices](#same-household-devices)
- [Privacy](#privacy)
- [Debug API](#debug-api)
- [Testing](#testing)
- [Current Status](#current-status)
- [Known Issues](#known-issues)

## Overview

Geogram uses the BitTorrent Mainline DHT (BEP 5) to discover devices without depending on the central station server. When the station is down or unreachable, devices find each other by announcing and querying the global DHT network — a distributed hash table with millions of active nodes maintained by BitTorrent clients worldwide.

**Key capabilities:**
- Discover Geogram nodes on the internet across different networks
- Find all devices belonging to a specific NOSTR identity (npub)
- Detect public IP via BEP 42 DHT responses (no STUN needed)
- Show discovered peers in the Devices UI with "internet" tag

## Architecture

```
                       +--------------------------+
                       |   BitTorrent Mainline    |
                       |        DHT Network       |
                       | (millions of BT clients) |
                       +-----------+--------------+
                                   |
                      get_peers / announce_peer
                                   |
              +--------------------+--------------------+
              |                                         |
    +---------v---------+                     +---------v---------+
    |   Geogram Node A  |                     |   Geogram Node B  |
    |   (laptop/WiFi)   |                     |   (phone/mobile)  |
    |                   |                     |                   |
    |   DHT UDP socket  |                     |   DHT UDP socket  |
    |   (random port)   |                     |   (random port)   |
    |                   |                     |                   |
    |   Shelf HTTP 3456 |                     |   Shelf HTTP 3456 |
    |   Flutter UI      |                     |   Flutter UI      |
    +-------------------+                     +-------------------+
```

### Transport Priority

| Priority | Transport | Scope |
|----------|-----------|-------|
| 5 | USB AOA | Physical cable |
| 10 | LAN | Local network |
| 15 | WebRTC | Browser/data channels |
| **25** | **DHT** | **Internet P2P** |
| 30 | Station | Internet relay |
| 35 | Bluetooth Classic | Short range |
| 40 | BLE | Short range |

## DHT Topics

Each device announces under two info_hashes:

### 1. Global Topic: `SHA1("geogram")`

Every Geogram node announces here. Used to find other Geogram peers and learn public IP via BEP 42.

### 2. Per-User Topic: `SHA1(npub)`

Each device announces on the SHA1 of its NOSTR public key. Querying `SHA1(npub)` returns all online devices for that identity. This is how the Devices UI discovers specific peers.

### Announce Details

- **Re-announce interval**: every 25 minutes
- **Announced port**: the device's HTTP API port (default 3456)
- **Token validation**: BEP 5 token exchange prevents spoofing
- **Announce target**: the K-closest nodes found by the iterative lookup (not routing table nodes)

## Node Types

Public IP learned from BEP 42 `ip` field in DHT responses.

| Type | Detection | Capabilities |
|------|-----------|-------------|
| **A** | Public IP matches a local interface | Full peer |
| **B** | BEP 42 reports a different public IP | Behind NAT |
| **unknown** | No BEP 42 data received yet | Deferred |

## Connection Flow

```
1. App starts → P2PService.start()
2. Timer(2s) → _runDht()
3. Load persisted node ID + cached routing table
4. Bootstrap DHT (cached nodes, then public BT routers)
5. Iterative announce on SHA1("geogram") and SHA1(npub)
6. Learn public IP from BEP 42 responses
7. Scan geogram topic for peers → register in DevicesService
8. For each known device with npub: fire lightweight get_peers
9. Periodic: re-announce every 25 min, refresh table every 2 min
10. Discovered peers appear in Devices UI with "internet" tag (green)
```

### Persistence

- **Node ID** (`p2p/node_id.bin`): 20-byte random ID, reused across sessions
- **Routing table cache** (`p2p/dht_cache.json`): best 30 nodes
- **Discovered peers** (`p2p/peer_cache.json`): known peer IPs

## Iterative Lookup

The core of BEP 5. Both `find_node` and `get_peers` use the same pattern:

```
candidates = SortedSet<Node>(by XOR distance to target)
queried = Set<NodeId>()

seed candidates from routing table (8 closest)

loop (up to 10 rounds):
  pick alpha=3 unqueried candidates closest to target
  if none left → converged, stop

  query all 3 in parallel (await Future.wait, 3s timeout each)

  for each response:
    if peers returned → collect them
    if nodes returned → add to candidates (if new)

  if peers found and no new candidates → stop
```

**Critical implementation details:**
- The candidate set is **per-lookup**, NOT the global routing table. This is the most common BEP 5 implementation bug — using only routing table nodes means the lookup never reaches the K-closest nodes.
- `announce_peer` must go to the nodes found at the END of the lookup (the K-closest that gave us tokens), not to routing table nodes.
- Responses from `find_node` must be processed too — not just `get_peers`. Otherwise the routing table can't grow.
- The lookup must NOT exit early just because no new candidates were added in one round — there may still be unqueried candidates closer than those already queried.

### Cross-Network Discovery

Two devices on different networks (e.g., home WiFi and mobile data) find each other because:
1. Both do iterative `announce_peer` on `SHA1("geogram")` → both converge on the same K-closest nodes in the 160-bit keyspace
2. Both do iterative `get_peers` on the same hash → they traverse to the same K-closest nodes and find the other's announce

This works regardless of routing table size — even with 9 nodes, a correct iterative lookup traverses through the DHT hop by hop until it converges. Verified in testing with laptop (178.202.105.29) finding Android on mobile data (47.64.113.206).

## Implementation

### Core DHT Library (pure Dart, no Flutter dependency)

| File | Purpose |
|------|---------|
| `lib/p2p/bencode.dart` | Bencode encoder/decoder |
| `lib/p2p/k_bucket.dart` | Kademlia routing table (160 buckets × 8 nodes) |
| `lib/p2p/dht_node.dart` | BEP 5 DHT node (UDP, RPCs, iterative lookups) |
| `lib/p2p/node_capability.dart` | BEP 42 IP detection, NAT type |

### Geogram Integration

| File | Purpose |
|------|---------|
| `lib/p2p/p2p_service.dart` | Singleton orchestrator, manages DHT lifecycle |
| `lib/p2p/ice_punch.dart` | UDP hole punching (scaffolding) |
| `lib/connection/transports/dht_transport.dart` | ConnectionManager transport |

### Bootstrap Nodes

```
router.bittorrent.com:6881
dht.transmissionbt.com:6881
router.utorrent.com:6881
dht.libtorrent.org:25401
dht.aelitis.com:6881
```

Port 25401 included for mobile carriers that block 6881.

## Devices UI Integration

When a peer is found via DHT, it appears in the Devices panel:

### Discovery via npub lookup

For each known device with an npub, `P2PService` fires lightweight `get_peers(SHA1(npub))` queries. When a response contains peers, the device is marked online with `['internet']` connection method.

### Preserving the internet tag

`DevicesService.checkReachability()` checks direct HTTP and station proxy. Both can fail for NAT'd peers. The `internet` tag set by DHT is preserved if `lastSeen` is within 30 minutes — station checks don't override DHT-confirmed connectivity.

### Display

Devices found via DHT show:
- **Green** online indicator
- **`['internet']`** connection method tag
- Identity from the device's profile (callsign, nickname)

## Same-Household Devices

Multiple devices behind the same NAT share the same public IP. DHT returns entries with same IP, different ports. The self-filter only excludes `127.0.0.1` — same-public-IP peers are NOT filtered. The callsign comparison in the HTTP probe filters out self.

## Privacy

- **No external STUN**: public IP from BEP 42 `ip` field in DHT responses
- **No Google/Mozilla infrastructure**
- **No IP logging**
- **Identity not in DHT**: announces only contain IP:port

## Debug API

`POST /api/debug`:

| Action | Parameters | Description |
|--------|-----------|-------------|
| `dht_status` | — | Full P2P status |
| `dht_start` | — | Start DHT |
| `dht_stop` | — | Stop DHT |
| `dht_find_user` | `npub` | Find devices for npub |
| `dht_add_node` | `ip`, `port` | Add a DHT peer |

## Testing

### Standalone Test

```bash
dart run tests/dht/dht_discovery_test.dart
```

Spawns two `DhtNode` instances, bootstraps both into the real BT mainline DHT, announces on a test topic, and verifies both find each other via iterative `get_peers`.

**Test results (2026-03-22):**
```
Node A: 9 nodes after bootstrap (6.5s)
Node B: 14 nodes after bootstrap (12.9s)
Node A announced (24s), Node B announced (31.6s)
Node A found 2 peers (7s): 178.202.105.29:41331, 178.202.105.29:59920
Node B found 2 peers (10.4s): 178.202.105.29:41331, 178.202.105.29:59920
*** PASS: Both nodes found each other ***
Memory: 174MB → 180MB peak → 152MB final (6MB DHT overhead)
```

Key findings:
- **6MB memory overhead** — the DHT library itself is lightweight
- Both nodes converge on the same K-closest nodes despite having only 9-14 routing table nodes
- The iterative lookup correctly traverses ~15-18 nodes across ~82-94 candidates

### Cross-Network Test (laptop + Android on different internet connections)

```
Laptop (178.202.105.29) → DHT → found Android (47.64.113.206:3456)
Android on mobile data found laptop's announce on SHA1("geogram")
```

Verified via `dht_find_user` debug API. Both devices' iterative lookups converged on the same K-closest nodes in the global DHT.

## Current Status

### Working (tested 2026-03-22)

- **Iterative lookup**: proper BEP 5 convergence with own candidate set, parallel alpha=3 queries, converges in ~7-10s
- **Cross-network discovery**: laptop on WiFi finds Android on mobile data via DHT
- **Devices UI**: discovered peers show as ONLINE with `['internet']` tag
- **BEP 42 IP detection**: public IP learned from DHT responses
- **DHT announce**: announces reach the K-closest nodes (not just routing table nodes)
- **Routing table growth**: nodes from ALL response types processed (find_node + get_peers)
- **Persistence**: node ID, routing table, discovered peers cached across sessions
- **Standalone test**: two nodes find each other — PASS

### Pending

- **Android OOM**: the DHT iterative lookups combined with other Geogram services (BLE, Whisper, DM queue) exceed available memory on low-RAM Android devices. The DHT library itself uses only 6MB — the issue is total app memory pressure. Needs: either reduce other services' memory during DHT operations, or run DHT in a lighter mode on Android (fewer candidates, shorter lookups).
- **Direct data transport**: UDP hole punching (`ice_punch.dart`) is scaffolded but not active.

## Known Issues

### Android Memory

The OBLUE TANK2 (Android 14, limited RAM) OOMs when DHT runs alongside all other services. The OOM stack trace shows `new Uint8List` in HTTP stream buffering — the immediate trigger is station HTTP probes (TLS decompression), not DHT itself. The fix `_fetchStationClients` to only run when the station WebSocket is connected reduced the frequency, but the app still hits OOM during DHT announce phase (iterative lookup creates ~85 candidate objects).

The standalone test proves the DHT library uses only 6MB. The Android issue is total app memory budget, not DHT efficiency.

### Token Errors

`DHT error 203: invalid token` and `Announce_peer with forbidden port number` are common during announces. Some DHT nodes reject announces with non-standard ports (3456 instead of typical BT ports). Tokens expire after 5-10 minutes, so re-announces may use stale tokens. These are non-fatal — the announce reaches enough nodes for discovery to work.

## What Does NOT Change

- Station servers — no modifications
- Station connections — still work, higher priority when available
- LAN/BLE discovery — unchanged
- Mirror sync protocol — unchanged
- Identity — same npub/callsign/NOSTR keys
- Content serving — same Shelf HTTP server
