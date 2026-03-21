# BitTorrent DHT Bridge for P2P Discovery

**Version**: 1.0
**Status**: Active
**Last Updated**: 2026-03-22

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [DHT Topics](#dht-topics)
- [Node Types](#node-types)
- [Connection Flow](#connection-flow)
- [Implementation](#implementation)
- [Same-Household Devices](#same-household-devices)
- [Privacy](#privacy)
- [Debug API](#debug-api)
- [Limitations](#limitations)

## Overview

Geogram uses the BitTorrent Mainline DHT (BEP 5) to discover devices without depending on the central station server (p2p.radio). When the station is down or unreachable, devices can still find each other by announcing and querying the global DHT network — a distributed hash table with millions of active nodes maintained by BitTorrent clients worldwide.

This is purely a **client-side enhancement**. Station servers are not modified. The existing station connection, LAN discovery, and BLE discovery continue to work as before. DHT adds a third internet-based discovery path.

**Key capabilities:**
- Discover all Geogram nodes on the internet
- Find all devices belonging to a specific NOSTR identity (npub)
- Detect NAT type for hole punching viability
- Establish direct UDP connections between devices
- No external infrastructure beyond the public DHT network itself

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
    | DHT UDP socket    |   hole punch UDP    | DHT UDP socket    |
    | (random port)     |<------------------->| (random port)     |
    |                   |                     |                   |
    | Shelf HTTP server |   direct data link  | Shelf HTTP server |
    | (port from args)  |<------------------->| (port from args)  |
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

The ConnectionManager tries transports in priority order. If a device is reachable via LAN, that's used. If not, DHT direct is tried before falling back to the station relay.

## DHT Topics

Each Geogram device announces itself under two info_hashes in the DHT:

### 1. Global Topic: `SHA1("geogram")`

Every Geogram node announces on this topic. Querying it returns all online Geogram devices visible to the DHT. Used to:
- Bootstrap the Geogram P2P network
- Discover Type A nodes (public IP, STUN reflectors)
- Find relay candidates

The info_hash is `a8a1245e...` (first bytes of SHA1 of the string "geogram").

### 2. Per-User Topic: `SHA1(npub)`

Each device announces on the SHA1 hash of its NOSTR public key (npub). Since the same npub can have multiple devices (phone, laptop, tablet), querying `SHA1(npub)` returns **all online devices for that identity**.

Example: querying `SHA1("npub1su86...")` might return:
```
5.6.7.8:4001    <- phone (NAT-mapped port)
5.6.7.8:4002    <- laptop (different NAT-mapped port)
9.10.11.12:3456 <- tablet on mobile data
```

Same IP with different ports means multiple devices behind the same router (same household).

### Announce Details

- **Re-announce interval**: every 25 minutes (DHT peer entries expire after ~30 min)
- **Announced port**: the device's HTTP API port (from `--port` flag or default 3456)
- **Token validation**: BEP 5 token exchange prevents announce spoofing

## Node Types

After joining the DHT, each device detects its NAT type by querying STUN reflectors (other Geogram Type A nodes found on the global topic):

| Type | Detection | Capabilities |
|------|-----------|-------------|
| **A** | Public IP matches local interface | STUN reflector, signaling relay, DHT peer |
| **B** | Same mapped port from two STUN queries | DHT peer, UDP hole punching works |
| **C** | Different mapped ports | DHT peer, needs relay via Type A |
| **unknown** | No STUN reflectors available yet | DHT peer, detection deferred |

**Type A nodes** automatically start the built-in STUN server (`StunServerService` on port 3478) so other nodes can use them as reflectors.

**No external STUN infrastructure is used.** Only Geogram nodes serve as STUN reflectors. If no Type A nodes have been discovered yet, NAT detection is deferred until they appear.

## Connection Flow

```
1. App starts
2. Load persisted DHT node ID + cached routing table nodes
3. Bootstrap DHT (cached nodes first, then public BT routers)
4. announce(SHA1("geogram"), apiPort)
5. announce(SHA1(myNpub), apiPort)
6. get_peers(SHA1("geogram")) -> find Type A nodes
7. STUN query to Type A nodes -> learn own public IP:port -> detect NAT type
8. Start periodic re-announce (every 25 min)
9. Scan for own devices: get_peers(SHA1(myNpub))
10. Discovered peers appear in P2P settings section
```

### To Find a Specific User's Devices

```
get_peers(SHA1(theirNpub))
  -> list of IP:port entries (one per online device)
  -> for each: attempt hole punch or relay via Type A
  -> identity handshake (deviceId, deviceName, callsign)
```

### Persistence Across Sessions

The DHT node persists two things via `ProfileStorage`:
- **Node ID** (`p2p/node_id.bin`): 20-byte random ID, generated once, reused across sessions
- **Routing table cache** (`p2p/dht_cache.json`): best 30 nodes from the routing table, saved on shutdown

On restart, cached nodes are loaded first, making bootstrap near-instant (100+ nodes from cache vs. 6 from public routers).

## Implementation

All P2P code lives in `lib/p2p/`:

| File | Lines | Purpose |
|------|-------|---------|
| `bencode.dart` | 226 | Bencode encoder/decoder for DHT wire protocol |
| `k_bucket.dart` | 273 | Kademlia routing table (160 buckets, 8 nodes each, XOR distance) |
| `dht_node.dart` | 834 | BEP 5 DHT node (UDP transport, RPCs, iterative lookups, token validation) |
| `node_capability.dart` | 262 | STUN-based NAT type detection (A/B/C) |
| `ice_punch.dart` | 323 | UDP hole punching with keepalive and identity handshake |
| `p2p_service.dart` | 389 | Singleton orchestrator tying it all together |

Transport integration: `lib/connection/transports/dht_transport.dart` (286 lines)

### BEP 5 RPCs Implemented

| RPC | Direction | Purpose |
|-----|-----------|---------|
| `ping` | Both | Liveness check, routing table maintenance |
| `find_node` | Both | Iterative node lookup (Kademlia) |
| `get_peers` | Both | Look up peers for an info_hash |
| `announce_peer` | Both | Announce as a peer for an info_hash |

### Kademlia Routing Table

- 160 buckets indexed by XOR distance bit position
- Each bucket holds up to 8 contacts (k=8, BEP 5 standard)
- LRU eviction: new nodes replace failed nodes, good old nodes are kept
- Refresh: stale nodes (not seen in 15 min) are pinged, random IDs are queried

### Bootstrap Nodes

Hardcoded public BitTorrent DHT routers used for initial bootstrap only:
- `router.bittorrent.com:6881`
- `dht.transmissionbt.com:6881`
- `router.utorrent.com:6881`

After the first session, cached peers make these unnecessary.

## Same-Household Devices

Multiple devices behind the same NAT (e.g., phone + laptop at home) share the same public IP. The DHT returns entries like:

```
get_peers(SHA1("npub1su86...")) ->
  178.202.105.29:4001   <- device A (NAT-mapped port)
  178.202.105.29:4002   <- device B (different NAT-mapped port)
  9.10.11.12:3456       <- device C on mobile data
```

Same IP, different ports — each is a distinct device. After connecting, devices identify themselves via the identity handshake (`deviceId`, `deviceName` from `ConfigService`).

## Privacy

- **No Google infrastructure**: STUN detection uses only Geogram peers as reflectors
- **No IP logging**: the DHT node does not log remote IPs
- **No tracking**: the DHT announces only contain IP:port, no identity information. The info_hash is a SHA1 hash — knowing `SHA1(npub)` requires already knowing the npub
- **End-to-end encryption**: direct connections use NIP-44 for signaling, all data is encrypted between devices
- **Public DHT**: the BitTorrent DHT is a public network. Any participant can see that *some* IP announced on *some* info_hash. They cannot determine it's a Geogram device unless they know to look for `SHA1("geogram")`

### What Is Visible to DHT Observers

An observer on the DHT can see:
- That an IP:port announced on a specific 20-byte info_hash
- The info_hash `SHA1("geogram")` is derivable if they know to hash "geogram"
- Per-npub hashes require knowing the actual npub first

An observer **cannot** see:
- Device names, callsigns, or any identity information
- Message content
- What the device is running

## Debug API

The following debug actions are available via `POST /api/debug`:

| Action | Parameters | Description |
|--------|-----------|-------------|
| `dht_status` | — | Full P2P status (node type, peers, connections, ports) |
| `dht_start` | — | Start the P2P DHT service |
| `dht_stop` | — | Stop the P2P DHT service |
| `dht_find_user` | `npub` | Find all devices for a specific npub via DHT |
| `dht_add_node` | `ip`, `port` | Manually add a DHT node (for testing/direct peering) |

### Examples

```bash
# Check P2P status
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"dht_status"}'

# Find devices for an npub
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"dht_find_user","npub":"npub1su86..."}'

# Manually introduce a DHT peer
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"dht_add_node","ip":"192.168.1.50","port":6881}'
```

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
  "dht_nodes": 101,
  "stored_peers": 3,
  "direct_connections": 0,
  "capability": {
    "node_type": "typeB",
    "public_ip": "178.202.105.29",
    "public_port": 47254,
    "can_hole_punch": true,
    "is_stun_reflector": false
  }
}
```

## Limitations

- **IPv4 only**: the current implementation binds IPv4 sockets. IPv6 DHT is not supported yet.
- **NAT detection requires peers**: if no other Geogram Type A nodes exist on the DHT, NAT type remains "unknown" until they appear.
- **Symmetric NAT (Type C)**: devices behind CGNAT or symmetric NAT cannot hole-punch directly. They need a Type A relay node.
- **DHT propagation delay**: announces take a few seconds to propagate through the DHT. A device that just joined may not be immediately findable.
- **Same-NAT discovery**: two devices behind the same NAT see each other's public IP on the DHT, but the NAT-mapped ports may differ from the actual local ports. The identity handshake after connection resolves this.
- **Web platform**: not available on web (requires raw UDP sockets via `dart:io`).

## What Does NOT Change

- Station servers — no modifications
- Station connections — still work, higher priority when available
- LAN/BLE discovery — unchanged
- Mirror sync protocol — unchanged, runs over any transport
- Identity — same npub/callsign/NOSTR keys
- Content serving — same Shelf HTTP server
