# BitTorrent DHT Bridge for P2P Discovery

**Version**: 1.1
**Status**: In Development — same-network works, cross-network convergence pending
**Last Updated**: 2026-03-22

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [DHT Topics](#dht-topics)
- [Node Types](#node-types)
- [Connection Flow](#connection-flow)
- [Implementation](#implementation)
- [Background Isolate](#background-isolate)
- [Same-Household Devices](#same-household-devices)
- [Privacy](#privacy)
- [Debug API](#debug-api)
- [Current Status](#current-status)
- [Known Issues](#known-issues)
- [Next Steps](#next-steps)

## Overview

Geogram uses the BitTorrent Mainline DHT (BEP 5) to discover devices without depending on the central station server (p2p.radio). When the station is down or unreachable, devices can still find each other by announcing and querying the global DHT network — a distributed hash table with millions of active nodes maintained by BitTorrent clients worldwide.

This is purely a **client-side enhancement**. Station servers are not modified. The existing station connection, LAN discovery, and BLE discovery continue to work as before. DHT adds an internet-based discovery path.

**Key capabilities:**
- Discover Geogram nodes on the internet
- Find all devices belonging to a specific NOSTR identity (npub)
- Detect public IP via BEP 42 DHT responses
- Detect NAT type (A/B/C) for hole punching viability
- No external infrastructure — public IP learned from DHT peers, not STUN servers

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
    |                   |                     |                   |
    | DHT Isolate       |                     | DHT Isolate       |
    | (background)      |                     | (background)      |
    |   UDP socket      |                     |   UDP socket      |
    |   (random port)   |                     |   (random port)   |
    |                   |                     |                   |
    | Main Isolate      |                     | Main Isolate      |
    |   Shelf HTTP      |                     |   Shelf HTTP      |
    |   Flutter UI      |                     |   Flutter UI      |
    +-------------------+                     +-------------------+
```

### How It Fits Into Geogram

The DHT transport sits at priority 25 in the ConnectionManager, between WebRTC (15) and Station (30):

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

Each Geogram device announces itself under two info_hashes in the DHT:

### 1. Global Topic: `SHA1("geogram")`

Every Geogram node announces on this topic. Querying it returns online Geogram devices visible to the DHT. Used to:
- Find other Geogram peers
- Learn public IP via BEP 42 responses from DHT nodes near this hash
- Find relay candidates (future)

The info_hash is `a8a1245e...` (first bytes of SHA1 of the string "geogram").

### 2. Per-User Topic: `SHA1(npub)`

Each device announces on the SHA1 hash of its NOSTR public key (npub). Since the same npub can have multiple devices (phone, laptop, tablet), querying `SHA1(npub)` returns **all online devices for that identity**.

### Announce Details

- **Re-announce interval**: every 25 minutes (DHT peer entries expire after ~30 min)
- **Announced port**: the device's HTTP API port (from `--port` flag or default 3456)
- **Token validation**: BEP 5 token exchange prevents announce spoofing

## Node Types

Public IP is learned from BEP 42 `ip` field in DHT responses — no separate STUN infrastructure needed. Each DHT response from an external node includes our public IP:port as they see it.

| Type | Detection | Capabilities |
|------|-----------|-------------|
| **A** | Public IP matches a local interface | Full peer, hole punching trivial |
| **B** | BEP 42 reports a public IP different from local | Behind NAT, hole punching likely works |
| **unknown** | No BEP 42 data received yet | Detection deferred |

## Connection Flow

```
1. App starts → P2PService.start()
2. Spawn DHT background isolate (Isolate.spawn)
3. Isolate: load persisted node ID + cached routing table
4. Isolate: bootstrap DHT (cached nodes first, then public BT routers)
5. Isolate: announce(SHA1("geogram"), apiPort) + announce(SHA1(myNpub), apiPort)
6. Isolate: learn public IP from BEP 42 responses → detect NAT type
7. Isolate: get_peers(SHA1("geogram")) → find other Geogram nodes
8. Main isolate: receive peer_found events → probe via HTTP → register in DevicesService
9. Periodic: re-announce every 25 min, refresh routing table every 2 min
10. Discovered peers appear in Devices UI with "internet" connection tag
```

### Persistence Across Sessions

The DHT node persists three things via `ProfileStorage`:
- **Node ID** (`p2p/node_id.bin`): 20-byte random ID, reused across sessions
- **Routing table cache** (`p2p/dht_cache.json`): best 30 nodes, saved on shutdown
- **Discovered peers** (`p2p/peer_cache.json`): known peer IPs, re-probed on restart

## Implementation

### Core DHT (runs in background isolate)

| File | Purpose |
|------|---------|
| `lib/p2p/bencode.dart` | Bencode encoder/decoder for DHT wire protocol |
| `lib/p2p/k_bucket.dart` | Kademlia routing table (160 buckets, 8 nodes each) |
| `lib/p2p/dht_node.dart` | BEP 5 DHT node (UDP, RPCs, iterative lookups, tokens) |
| `lib/p2p/node_capability.dart` | BEP 42 IP detection, NAT type classification |
| `lib/p2p/dht_isolate.dart` | Isolate entry point, runs DhtNode + NodeCapability |

### Orchestration (runs on main isolate)

| File | Purpose |
|------|---------|
| `lib/p2p/p2p_service.dart` | Singleton, manages isolate lifecycle, SendPort/ReceivePort |
| `lib/p2p/ice_punch.dart` | UDP hole punching (scaffolding, not yet active) |
| `lib/connection/transports/dht_transport.dart` | ConnectionManager transport (discovery only for now) |

### BEP 5 RPCs Implemented

| RPC | Direction | Purpose |
|-----|-----------|---------|
| `ping` | Both | Liveness check, routing table maintenance |
| `find_node` | Both | Iterative node lookup (Kademlia) |
| `get_peers` | Both | Look up peers for an info_hash |
| `announce_peer` | Both | Announce as a peer for an info_hash |

### Bootstrap Nodes

```
router.bittorrent.com:6881
dht.transmissionbt.com:6881
router.utorrent.com:6881
dht.libtorrent.org:25401
dht.aelitis.com:6881
```

Port 25401 included because some mobile carriers block UDP port 6881. If first bootstrap round gets 0 responses, retries with a longer wait.

## Background Isolate

All DHT work runs in a separate Dart isolate (`Isolate.spawn`) to prevent blocking the main thread's HTTP server and Flutter UI. This was critical for Android where any operation taking >5 seconds causes ANR (Application Not Responding).

### Communication Protocol

Main isolate and DHT isolate communicate via `SendPort`/`ReceivePort` with JSON messages:

**DHT → Main (events):**
| type | Fields | When |
|------|--------|------|
| `log` | `message` | Debug logging |
| `node_id` | `id` (hex) | After node ID generated/loaded |
| `started` | `dht_port`, `node_type`, `public_ip`, `dht_nodes` | After bootstrap+announce+detect complete |
| `status` | `dht_nodes`, `stored_peers`, `node_type`, `public_ip` | Periodic status update |
| `peer_found` | `info_hash`, `ip`, `port` | When a peer is discovered |
| `find_result` | `npub`, `devices[]` | Response to find_user command |
| `cache` | `nodes[]` | Routing table cache on shutdown |
| `error` | `message` | On failure |

**Main → DHT (commands):**
| action | Fields | Purpose |
|--------|--------|---------|
| `stop` | — | Shutdown, save cache, exit isolate |
| `get_status` | — | Request current status |
| `find_user` | `npub` | Search for a specific user's devices |
| `add_node` | `ip`, `port` | Manually add a DHT node |

### Station HTTP Probes

Device reachability checks (`_checkDirectConnection`, `_checkViaRelayProxy`, `_fetchStationClients`) also run in background isolates via `Isolate.run()` to prevent OOM from large TLS response buffering on the main thread. Response bodies are capped at 50KB.

## Same-Household Devices

Multiple devices behind the same NAT share the same public IP. The DHT returns entries with the same IP but different ports. The self-filter only excludes `127.0.0.1` — same-public-IP peers are NOT filtered because they may be other devices in the household.

After HTTP probe to get `/api/status`, the callsign comparison filters out self. Display format: `nickname (callsign)` if nickname is set, else just `callsign`.

## Privacy

- **No external STUN**: public IP learned from BEP 42 `ip` field in DHT responses
- **No Google/Mozilla infrastructure**: only BT DHT nodes and other Geogram peers
- **No IP logging**: the DHT node does not log remote IPs
- **Identity not in DHT**: announces only contain IP:port. The info_hash is a SHA1 hash — knowing `SHA1(npub)` requires knowing the npub first

### What Is Visible to DHT Observers

An observer on the DHT can see:
- That an IP:port announced on a specific 20-byte info_hash
- The info_hash `SHA1("geogram")` is derivable if they know to hash "geogram"

An observer **cannot** see:
- Device names, callsigns, or any identity information
- Message content
- What the device is running

## Debug API

Available via `POST /api/debug`:

| Action | Parameters | Description |
|--------|-----------|-------------|
| `dht_status` | — | Full P2P status |
| `dht_start` | — | Start the P2P DHT service |
| `dht_stop` | — | Stop the P2P DHT service |
| `dht_find_user` | `npub` | Find devices for a specific npub |
| `dht_add_node` | `ip`, `port` | Manually add a DHT peer |

### Sample `dht_status` Response

```json
{
  "success": true,
  "enabled": true,
  "running": true,
  "dht_port": 47254,
  "node_type": "typeB",
  "public_ip": "178.202.105.29",
  "public_port": 47254,
  "dht_nodes": 45,
  "stored_peers": 2,
  "direct_connections": 0,
  "capability": {
    "node_type": "typeB",
    "public_ip": "178.202.105.29",
    "public_port": 47254,
    "can_hole_punch": true
  }
}
```

## Current Status

### What Works (tested 2026-03-22)

- **DHT bootstrap**: nodes connect to BT mainline DHT and grow routing table to 30-50 nodes
- **BEP 42 IP detection**: public IP learned from DHT response `ip` field — no STUN needed
- **NAT type detection**: typeB detected correctly on both Linux and Android
- **DHT announce**: both SHA1("geogram") and SHA1(npub) announces succeed
- **Same-network discovery**: two instances on the same machine find each other via DHT (verified with `dht_find_user`)
- **Background isolate**: all DHT work runs in separate Dart isolate, main thread stays responsive
- **Station probe isolation**: HTTP probes for device reachability run in `Isolate.run()`, preventing OOM
- **Android stability**: no ANR or OOM from DHT itself (earlier crashes were from station HTTP response buffering, now isolated)
- **Peer cache persistence**: routing table and discovered peers saved/loaded across sessions
- **Devices UI integration**: discovered peers probed via `/api/status` and registered in DevicesService with `internet` connection tag

### What Does NOT Work Yet

- **Cross-network discovery**: two devices on different internet connections (different public IPs) have NOT successfully found each other via the global DHT in testing. The routing tables plateau at ~45 nodes, which is insufficient for the iterative lookups to converge on the same K-closest nodes to SHA1("geogram") in the 160-bit keyspace
- **Direct data transport**: UDP hole punching (`ice_punch.dart`) is scaffolded but not active. The DHT transport in ConnectionManager currently returns "not implemented" for `send()`

## Known Issues

### Routing Table Growth Bottleneck

The core unsolved problem. Real BitTorrent clients grow routing tables to 300-1000+ nodes because they receive thousands of incoming queries from other BT clients downloading/sharing files. Our Geogram nodes only make outgoing queries and receive very few incoming ones (nobody is looking for our node IDs). This limits table growth to ~45 nodes.

With 45 nodes and a 160-bit keyspace containing millions of BT nodes, the probability of two Geogram devices' iterative lookups reaching the same DHT nodes (the ones holding the other's announce) is very low.

**Attempted mitigations:**
- Reduced refresh interval from 15 min to 2 min
- Targeted refresh: search for nodes near SHA1("geogram") specifically, not random IDs
- Process nodes from ALL response types (was only processing get_peers responses — critical bug found and fixed)
- 5 bootstrap nodes instead of 3 (added `dht.libtorrent.org:25401` for mobile carriers blocking port 6881)

### Android Memory Pressure

The Android device (OBLUE TANK2, API 34) has limited memory. The OOM crashes observed were from:
1. Station HTTP responses buffered on the main thread (TLS decompression) — **fixed** by running probes in `Isolate.run()`
2. DHT operations on the main thread blocking the event loop — **fixed** by moving DHT to a separate isolate
3. General memory pressure from Whisper model loading + all services starting simultaneously

### Mobile Carrier UDP Filtering

Some mobile carriers block UDP on port 6881 (standard BT DHT port). Added `dht.libtorrent.org:25401` as alternative. Bootstrap retries if first round gets 0 responses.

## Next Steps

### Option A: Geogram Rendezvous Server

Add a lightweight rendezvous endpoint (not a full station) where Geogram devices register their DHT node info. Each device posts `{npub, dht_ip, dht_port}` to the rendezvous. Other devices query it to find each other's DHT endpoints, then connect directly. This bootstraps the cross-network problem without needing the two devices' DHT routing tables to overlap.

### Option B: Aggressive DHT Crawling

On startup, crawl the DHT more aggressively — do 10+ rounds of find_node with parallel queries to grow the routing table to 200+ nodes before attempting peer lookups. This is CPU/network intensive but may improve convergence.

### Option C: DHT Proxy via Existing Stations

When a device connects to a station via WebSocket, the station could announce on the DHT on behalf of the device. Since stations have public IPs (Type A), their announces are more likely to be found. The station doesn't need to run a full DHT — just forward announce/get_peers requests from connected clients.

### Option D: Multiple Info Hashes

Instead of one global `SHA1("geogram")`, use multiple hashes (e.g., `SHA1("geogram-1")` through `SHA1("geogram-16")`). Each device announces on all of them. This increases the chances of two devices' lookups converging because the K-closest nodes are different for each hash — 16x the surface area.

## What Does NOT Change

- Station servers — no modifications
- Station connections — still work, higher priority when available
- LAN/BLE discovery — unchanged
- Mirror sync protocol — unchanged, runs over any transport
- Identity — same npub/callsign/NOSTR keys
- Content serving — same Shelf HTTP server
