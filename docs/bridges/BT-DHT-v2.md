# Geogram Serverless P2P Architecture

**Version:** 0.1 (draft)
**Status:** Specification for implementation and prototyping
**Scope:** Replaces the central `p2p.radio` station server with a fully decentralized peer discovery, signaling, and transport stack. File distribution (APKs, `.wapp`, ZIM, NDF) is included as a second-phase extension that reuses the same primitives.

---

> **Implementation deviation (2026-05-07).** The shipped implementation does NOT use NOSTR for serverless P2P. §3 item 3, §8 (NOSTR-DM signaling), and §6.7 (NOSTR-presence DHT-blocked fallback) are spec-only and have no implementation in the codebase. All serverless signaling routes through the DHT geogram_query rendezvous (§6) per user direction — NOSTR relays are third-party servers and the user did not authorize their use for this feature. Existing NOSTR features in the geogram codebase (gift-wrap DMs, NIP-05 registry, blossom) remain functional and are unrelated to this stack.

> **Implementation deviation (2026-05-07, second course correction).** §8 (WebRTC transport with ICE) is now augmented by a direct UDP transport coordinated via public WebTorrent WSS trackers and BEP 42 endpoint discovery. Trackers carry a small per-peer-pair JSON envelope (`geoconnect_offer` / `geoconnect_answer`) containing each side's STUN-discovered endpoint; both peers then perform simultaneous UDP hole punching on the DHT's shared socket, with port prediction for one-side cellular symmetric NAT. A reliable framing layer (sequence/ACK/retransmit) on top of the hole-punched UDP path delivers small messages (≤1255 bytes per frame). This transport ships as `hole_punch` at priority 18 (ahead of WebRTC at 15) and surfaces in the Devices browser as an orange "P2P" chip. Cross-network test confirmed ~1.4s for the first message and 10–100 ms for subsequent reuse. Larger transfers and unidirectional streaming layer on the same session API and are documented in [`docs/connections/p2p-hole-punch.md`](../connections/p2p-hole-punch.md).

---

## 1. Summary

Geogram instances find and talk to each other without central infrastructure by composing four existing systems:

1. **BitTorrent Mainline DHT** for peer discovery — Geogram joins the public Kademlia network alongside ordinary file-sharing clients and uses topic infohashes as rendezvous points.
2. **IPv6 + UPnP / NAT-PMP / PCP** for reachability — every instance attempts to expose a public socket on startup; any that succeed organically become the relay tier.
3. **NOSTR (NIP-44)** for signaling — encrypted DM exchange between npubs carries WebRTC SDP and ICE candidates.
4. **WebRTC** for transport — direct P2P data channel where NAT permits, Geogram peer relay otherwise.

The same primitives extend to file distribution by treating APKs, `.wapp` packages, ZIM archives, and NDF documents as ordinary BitTorrent swarms once the discovery and reachability foundations are in place.

---

## 2. Goals

- No central servers for peer discovery, signaling, or relay. Replaces `p2p.radio`.
- Works on Android over carrier-grade / symmetric NAT.
- Self-bootstrapping: the relay tier emerges from the user population without operator deployment.
- Privacy-respecting: identity bound to npub, signaling encrypted, no DNS-based seeds, no Cloudflare or Google dependencies.
- Re-uses existing Geogram subsystems (NOSTR stack, npub identity) wherever possible.
- Forward-compatible with file distribution.

## 3. Non-Goals

- Running a private DHT.
- Solving symmetric-NAT-to-symmetric-NAT direct WebRTC connectivity (handled via relay fallback).
- Operating TURN servers.
- App-store-style curation. Distribution is content-addressed.

## 4. Explicit Rejections

| Option | Reason |
|---|---|
| Matrix | Security and privacy concerns (already rejected). |
| Custom Geogram-only DHT | Won't reach Kademlia robustness scale. Bootstrap unsolvable without acceptable infrastructure. |
| DNS-based seed mechanisms | Insufficiently permanent. |
| Cloudflare / Google bootstrap | Privacy-incompatible. |
| Hardcoded IP bootstrap | Goes stale within months. |
| Public TURN servers | Operator burden; relay tier supersedes. |

---

## 5. Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                          Application                           │
│             (chat, packet radio bridge, .wapp host)            │
├────────────────────────────────────────────────────────────────┤
│ Transport       WebRTC data channel (preferred)                │
│                 Type A peer relay (symmetric-NAT fallback)     │
├────────────────────────────────────────────────────────────────┤
│ Signaling       NOSTR NIP-44 encrypted DMs                     │
│                 (offer / answer / trickle ICE / bye)           │
├────────────────────────────────────────────────────────────────┤
│ Discovery       Mainline DHT (BEP 5 announce_peer / get_peers) │
│                 BEP 44 mutable items for small signed blobs    │
│                 Bootstrap: router.bittorrent.com et al.        │
├────────────────────────────────────────────────────────────────┤
│ Reachability    IPv6 first → UPnP-IGD → NAT-PMP → PCP          │
│                 State machine drives relay-tier eligibility    │
└────────────────────────────────────────────────────────────────┘
```

Each layer can fail independently and is paired with a fallback so the stack as a whole degrades rather than breaking.

---

## 6. Discovery Layer (Mainline DHT)

### 6.1 Network choice

Geogram joins the **public BitTorrent Mainline DHT** rather than running a private network. Rationale:

- Inherits routing, replication, and adversarial robustness from millions of nodes.
- Bootstrap nodes are stable protocol constants (operating ~20 years).
- Cover traffic: Geogram queries are indistinguishable from ordinary file-sharing queries at the DHT layer.
- Foundation for future BitTorrent-based file distribution without changing networks.

### 6.2 Bootstrap

Initial routing-table population:

```
router.bittorrent.com:6881
router.utorrent.com:6881
dht.transmissionbt.com:6881
dht.libtorrent.org:25401
```

Resolve A and AAAA records; attempt all returned addresses. Cache successful peers from prior sessions and prefer them on next startup; the canonical bootstrap list becomes a fallback rather than the primary path once a node has a working peer cache.

### 6.3 Port

Bind to a **randomized high UDP port** (range 49152–65535). Do not use 6881 — it is one of the most-blocked ports on hostile networks. The chosen port is published via the reachability layer (UPnP/IPv6) and then announced.

### 6.4 Topic hashes

All Geogram topic hashes are derived deterministically and version-tagged. Implementations MUST NOT pre-compute or hardcode the resulting bytes; always derive at runtime from the protocol-constant strings, so future versions can coexist.

```
RELAY_TOPIC      = SHA1("geogram/v1/relay")
PEER_TOPIC(npub) = SHA1(npub_bytes || "geogram/v1/peer")
GROUP_TOPIC(gid) = SHA1(group_id_bytes || "geogram/v1/group")
```

- **`RELAY_TOPIC`** — global. Every reachable Geogram instance announces here. Consumers query it to discover candidate relays.
- **`PEER_TOPIC(npub)`** — per-recipient. Used to find the endpoint(s) where a specific user is currently announcing. The 32-byte npub key is the input to SHA1; only parties who already know the npub can compute the lookup hash.
- **`GROUP_TOPIC(gid)`** — per-group. Allows discovery of all members of a known group identifier.

### 6.5 BEP 5 operations

Standard Mainline DHT semantics:

- **`announce_peer`** with `implied_port=0` and the explicit reachable port from the reachability layer. Re-announce every 5 minutes (DHT entries time out around 30 minutes; re-announce well inside that window).
- **`get_peers`** to discover other nodes against any of the above topic hashes.
- **`find_node`** for routing-table maintenance.

### 6.6 BEP 44 mutable items

For small signed payloads that benefit from being available without a follow-up connection:

- 1000-byte ceiling per item. Hard limit.
- Signed by an Ed25519 key. Geogram uses a key derived deterministically from the npub for this purpose so the BEP 44 publisher key is bound to the Geogram identity.
- Suitable for: presence beacons, trickle ICE candidates (one candidate per item), magnet link references (forward to file distribution).
- NOT suitable for: full SDP, anything that would require chunking, anything that needs low latency. Use NOSTR signaling instead.

### 6.7 DHT-blocked fallback

A non-trivial fraction of corporate, school, and authoritarian-regime networks block UDP packets to/from DHT-style ports. The implementation MUST detect this and fall back gracefully:

1. After bootstrap, attempt `find_node` against the bootstrap nodes. If no responses arrive within 30 seconds across all bootstrap targets, treat the DHT as unreachable.
2. Switch to **NOSTR-backed discovery**: publish presence as a NOSTR replaceable event under a Geogram-specific kind, look up other users' presence the same way.
3. Continue retrying DHT periodically (~5 minutes) in case the network situation changes.

---

## 7. Reachability Layer

### 7.1 Detection priority

On startup and on every network-change event, the implementation determines its current reachability state through this fallback chain, in order:

1. **IPv6 with global address.** Bind a UDP socket to the chosen port on the IPv6 interface; verify the address is in the global unicast range (not ULA, not link-local). If the OS reports a global address and the socket binds, treat as reachable. This is the cleanest path; many European home networks (including Portugal) deploy IPv6 by default with no NAT in front.
2. **UPnP-IGD (Internet Gateway Device).** Discover via SSDP, request `AddPortMapping` (or `AddAnyPortMapping` for protocol 2). Lease duration: 3600 seconds, renewed at 50% expiry.
3. **NAT-PMP** (RFC 6886). For routers that don't speak UPnP but do speak NAT-PMP (Apple AirPort, some others).
4. **PCP** (RFC 6887). The modern successor; honored by some carrier CPE and most newer routers, particularly in IPv6 deployments.

If all four fail, the node is **relay-consumer-only**.

### 7.2 Reachability state

The implementation MUST track and expose:

```
ReachabilityState {
  status: NOT_REACHABLE | REACHABLE_IPV6 | REACHABLE_UPNP
        | REACHABLE_NATPMP | REACHABLE_PCP
  external_address: IP address (string)
  external_port: u16
  protocol_used: enum
  detected_at: timestamp
  expires_at: timestamp  // for UPnP/NAT-PMP/PCP leases
}
```

Re-evaluation triggers:
- Network connectivity change (Android `CONNECTIVITY_ACTION` / equivalent).
- Lease approaching expiry (renew at 50%, force re-detection at 90%).
- User-initiated refresh.
- Relay-tier-eligibility loss (any DHT failure on the announced port).

### 7.3 Library choices (Dart/Flutter)

Primary: [`upnp2`](https://pub.dev/packages/upnp2) for UPnP-IGD discovery and port mapping in pure Dart.

Coverage gap: Dart does not have first-class NAT-PMP or PCP libraries. Two options:
- Use Flutter platform channels to call the Java [`portmapper`](https://github.com/offbynull/portmapper) library on Android, which supports UPnP-IGD, NAT-PMP, and PCP through one API.
- Implement NAT-PMP and PCP as small Dart packages — both are minimal binary protocols (NAT-PMP fits in ~150 lines, PCP in ~300).

Either is acceptable. Recommendation: ship Phase 1 with `upnp2` only, add NAT-PMP/PCP coverage in a later phase if usage data shows it's worth it.

### 7.4 IPv6 detection

Don't rely on `Platform.localHostname` or DNS. Enumerate `NetworkInterface.list()` and look for any IPv6 address that is:
- Not loopback (`::1`).
- Not link-local (`fe80::/10`).
- Not Unique Local (`fc00::/7`).

If at least one such address exists and a UDP socket binds to it on the chosen port, treat as `REACHABLE_IPV6`. Skip UPnP entirely — IPv6 home networks generally don't NAT.

---

## 8. Signaling Layer (NOSTR)

### 8.1 Why NOSTR

Geogram already has the full NOSTR stack (npub keypairs, NIP-07, NIP-44, relay management). NIP-44 v2 encrypted DMs match the exact shape needed for signaling: small bidirectional encrypted messages keyed to peer identity, with retry semantics and existing relay infrastructure.

### 8.2 Event format

Use a Geogram-specific event kind (suggested: `30078` placeholder until reserved, or a new app-specific kind in the parameterized-replaceable range).

```
{
  "kind":     <geogram-signaling-kind>,
  "pubkey":   <sender npub bytes (hex)>,
  "tags":     [["p", <recipient npub hex>]],
  "content":  <NIP-44 v2 encrypted payload>,
  ...
}
```

Encrypted payload (JSON):

```
{
  "type":    "offer" | "answer" | "candidate" | "bye",
  "session": <random 16-byte session id, hex>,
  "data":    <SDP string | candidate object>,
  "ts":      <unix ms>
}
```

### 8.3 Trickle ICE

Each ICE candidate is sent as a separate event with `type: "candidate"` so candidates can be exchanged incrementally as they're discovered. Matches WebRTC's native trickle-ICE flow.

### 8.4 Relay set

Use the user's existing configured NOSTR relay set. Publish each event to **at least 3 relays** for redundancy. Subscribe on all configured relays so the recipient receives the event via whichever path is available first.

### 8.5 Replay and ordering

The `session` field disambiguates concurrent attempts. The receiving side MUST de-duplicate by event id and MUST tolerate out-of-order delivery (NOSTR relays do not guarantee order).

---

## 9. Transport Layer (WebRTC)

### 9.1 ICE configuration

```
RTCConfiguration {
  iceServers: [
    // STUN: use a privacy-respecting public server.
    // Avoid Google STUN. Mozilla's stun.services.mozilla.com is acceptable.
    // Alternative: derive own STUN reply from a peer-relay node.
    { urls: "stun:stun.services.mozilla.com" }
  ],
  iceTransportPolicy: "all",
  bundlePolicy:       "max-bundle"
}
```

No TURN servers configured here. The relay role is filled by the Geogram peer relay tier (Section 10), which is reached via a separate code path rather than via WebRTC's TURN client.

### 9.2 Connection establishment

1. Peer A creates RTCPeerConnection, generates SDP offer, starts gathering ICE candidates.
2. A publishes offer via NOSTR signaling to B.
3. B accepts offer, generates answer, starts gathering ICE.
4. B publishes answer to A.
5. As candidates are gathered on each side, they are trickled through NOSTR.
6. When a candidate pair succeeds, the data channel opens.

### 9.3 Fallback to peer relay

If ICE fails to produce a working candidate pair within **20 seconds** of `iceGatheringState === 'complete'` on both sides, the connection is considered NAT-blocked. Fall back:

1. Both sides query the DHT against `RELAY_TOPIC` for candidate Geogram relays.
2. Each side opens a connection to one or more relays.
3. The relay establishes a session keyed by both npubs and forwards traffic between the two sockets.
4. Application-level traffic is end-to-end encrypted regardless of relay (the relay is dumb pipe).

Relay protocol details: Section 10.

---

## 10. Self-Bootstrapping Relay Tier (Type A)

### 10.1 Promotion criteria

A Geogram instance becomes a candidate relay when ALL of the following hold:

- `ReachabilityState.status` is `REACHABLE_IPV6 | REACHABLE_UPNP | REACHABLE_NATPMP | REACHABLE_PCP`.
- User has enabled relay mode (settings toggle).
- Device is on Wi-Fi (not cellular) — checked via Android `NetworkCapabilities.TRANSPORT_*`.
- Device is plugged in OR battery is above a threshold (default: 50%).
- Connection is not metered (`NET_CAPABILITY_NOT_METERED`).

### 10.2 Default settings

- Relay mode: **opt-in by default**, with a clear toggle and explanation in settings.
- Battery threshold: 50%, configurable.
- Bandwidth cap: default 500 MB / 24 hours, configurable.
- Relay session count: max 10 concurrent.

### 10.3 Announcement

When a node satisfies the promotion criteria:

1. `announce_peer` on `RELAY_TOPIC` with the externally-reachable port from the reachability layer.
2. Re-announce every 5 minutes.
3. Stop announcing immediately when any criterion ceases to hold (battery drops below threshold, network changes to cellular, etc.).
4. Optionally publish a BEP 44 mutable item at the npub-derived key containing capability flags (relay version, max sessions, bandwidth status) so consumers can choose intelligently.

### 10.4 Relay protocol

The relay accepts incoming connections from Geogram peers on its announced port. The wire protocol is a small framed message format over TCP (with TLS via Noise or DTLS):

```
RelayMessage {
  type: HELLO | OPEN_SESSION | DATA | CLOSE_SESSION | PONG
  session_id: 16 bytes  // relay-internal, ephemeral
  payload: bytes
}
```

Session lifecycle:

1. Peer A and Peer B both connect to the same relay R.
2. A sends `OPEN_SESSION` with target = npub(B) and a session-id.
3. R awaits a matching `OPEN_SESSION` from B (within 30 seconds; otherwise reject).
4. R bridges the two sockets: any `DATA` message from A is forwarded to B and vice versa.
5. Either side can `CLOSE_SESSION`. R also closes on socket disconnect or idle timeout (5 minutes no data).

The relay never inspects payload bytes. All application data is end-to-end encrypted at higher layers (NIP-44 for signaling, DTLS for WebRTC media).

### 10.5 Trust model

The relay sees:
- Source and destination npubs (necessary to match sessions).
- Traffic volume and timing.
- The fact that two npubs are communicating.

The relay does NOT see:
- SDP contents (NIP-44 encrypted between the two npubs).
- WebRTC media (DTLS encrypted).
- Application messages (encrypted at the data-channel level).

A malicious relay can drop, delay, or refuse traffic; it cannot read or impersonate.

### 10.6 Relay selection (consumer side)

When a consumer needs a relay:

1. `get_peers` on `RELAY_TOPIC`.
2. Sort candidates by latency (probe with a small `HELLO` round-trip).
3. Pick the lowest-latency relay; keep 1-2 backups warm for failover.
4. Re-evaluate every few minutes; relays churn frequently.

---

## 11. Identity Binding

Geogram identity is the **NOSTR npub** keypair. No separate identity system.

- DHT discovery hashes are derived from npub bytes (Section 6.4) so lookup requires prior knowledge of the npub.
- BEP 44 mutable items are signed by an Ed25519 key derived deterministically from the npub.
- NOSTR signaling events are sent and received between npubs using NIP-44.
- Relay sessions match by npub at the relay protocol level.

Privacy implications:
- Anyone who knows your npub can derive `PEER_TOPIC(npub)` and learn whether you're currently announcing, and to which IP address.
- The IP exposure is by design — it's how peers find you. Mitigation for users requiring stronger privacy is to route through the relay tier always (announcing only the relay's address).
- Group membership is similarly visible to anyone who knows the group ID.

---

## 12. Operational Considerations

### 12.1 Battery

- Relay mode auto-disables when battery drops below threshold or device unplugs (configurable).
- DHT keepalive is light (~1 KB / minute when idle). Acceptable for always-on operation.
- WebRTC and active relay sessions are the heavy cost; cap concurrent sessions and timeout aggressively.

### 12.2 Bandwidth

- Per-session bandwidth cap (default 500 MB/day for relay mode).
- Refuse new relay sessions when cap is reached.
- Detect metered connections via Android `NetworkCapabilities.NET_CAPABILITY_NOT_METERED` and disable relay mode entirely on metered networks.

### 12.3 Churn

- DHT entries TTL is approximately 30 minutes. Re-announce every 5 minutes.
- Relay candidates churn frequently (home users coming and going). Consumers must expect their selected relay to drop and have a backup ready.
- WebRTC sessions through a relay should reconnect automatically via a different relay on relay failure.

### 12.4 Network change handling

On every network change event:
1. Cancel pending DHT operations.
2. Re-run reachability detection (Section 7.2).
3. Re-bootstrap the DHT routing table (likely some peers from the previous network are now unreachable).
4. Re-announce on all relevant topic hashes.
5. Re-establish NOSTR relay connections (existing event subscriptions will resume).
6. Active WebRTC sessions: attempt ICE restart; fall back to relay-mediated reconnect if that fails.

### 12.5 Logging

Log enough to diagnose connectivity issues, scrubbed of personal identifiers:
- Reachability state transitions and reasons.
- DHT bootstrap success / failure per node.
- Per-session connection establishment timing (offer sent → answer received → ICE complete → data channel open).
- Relay session events.

Do NOT log: NIP-44 ciphertext, SDP contents, WebRTC media, peer npubs in production builds.

---

## 13. Future Extension: File Distribution

This section is forward-looking. Implement only after Sections 6-10 are working.

### 13.1 Reuse of primitives

Once a Geogram instance is a Mainline DHT participant with reachable port, BitTorrent file distribution requires only:
- A BT peer wire protocol implementation (BEP 3 + extensions).
- A choking / piece-selection algorithm.
- Local storage management.

The discovery and reachability layers are already in place from Sections 6-7.

### 13.2 Use cases

- **APK distribution.** Each Geogram release is a torrent. Magnet link is published as a NOSTR event signed by the developer's npub. Existing instances seed the latest version automatically.
- **`.wapp` packages.** Apps are content-addressed zips; the hash is the torrent infohash. Users running an app help host it for everyone.
- **Kiwix ZIM archives.** The ~20 GB offline Wikipedia distribution becomes a torrent on Mainline. Geogram nodes that have downloaded it become seeders. Pairs naturally with the existing WiFi Direct + Kiwix-serve story for in-radio distribution.
- **NDF / GDF documents.** Large signed JSON documents distributed via swarm; reference published via NOSTR.

### 13.3 NOSTR event format for magnet references

```
{
  "kind":    <geogram-magnet-kind>,
  "tags":    [
    ["d", <content-id>],            // for replaceable events
    ["magnet", <magnet uri>],
    ["size", <bytes>],
    ["mime", <mime type>],
    ["title", <human readable>]
  ],
  "content": <description>,
  ...
}
```

### 13.4 Library

[`dtorrent_task_v2`](https://pub.dev/packages/dtorrent_task_v2) on pub.dev is a pure-Dart BitTorrent client implementation. It already integrates `bittorrent_dht` and supports BEP 52 (BT v2), uTP, and PEX. Same Dart codebase covers Phase 1 discovery and Phase 5 file distribution without bringing in a second networking stack.

For ESP32 nodes: full BT swarm participation is not realistic (too memory-hungry, too bandwidth-hungry for SA818 anyway). ESP32s use the DHT for discovery only and stay out of the swarm protocol — the right division of labor.

---

## 14. Implementation Stack

### 14.1 Dart / Flutter (primary client)

| Concern | Library | Notes |
|---|---|---|
| DHT (BEP 5) | `bittorrent_dht` | Pure Dart, BEP 5. |
| BT swarm (Phase 5) | `dtorrent_task_v2` | Includes BEP 52, uTP, PEX. |
| UPnP-IGD | `upnp2` | Pure Dart, maintained fork. |
| NAT-PMP / PCP | Platform channel to `portmapper` (Java) | Or implement directly in Dart. |
| WebRTC | `flutter_webrtc` | Existing in Geogram stack. |
| NOSTR | (existing Geogram libraries) | Reuse current NIP-44 implementation. |
| Network change events | `connectivity_plus` | For Android/iOS network state. |
| Battery state | `battery_plus` | For relay-promotion gating. |

### 14.2 ESP32 (mesh nodes)

- DHT-only participation via the lwIP stack.
- Announce on `RELAY_TOPIC` if and only if the node has a public address (rare on ESP32; optional).
- No BT swarm participation.
- NOSTR signaling is feasible (small messages) and reuses existing Geogram NOSTR code where ported.

### 14.3 Cross-platform considerations

The DHT client and reachability detection should run identically on Android, Linux desktop, Windows desktop, and (eventually) iOS. WebRTC and NOSTR are already cross-platform in the existing stack.

---

## 15. Phased Implementation Plan

### Phase 1: DHT participation + reachability detection

**Acceptance criteria:**
- Geogram instance bootstraps the Mainline DHT and reports a populated routing table within 60 seconds on a working network.
- Reachability state correctly identifies as one of `{IPV6, UPNP, NATPMP, PCP, NOT_REACHABLE}` on at least three test networks (home Wi-Fi, mobile carrier, locked-down Wi-Fi).
- Instance announces against `PEER_TOPIC(self_npub)` and is discoverable from another instance on a different network within 60 seconds.

### Phase 2: NOSTR signaling + WebRTC handshake

**Acceptance criteria:**
- Two instances on different networks discover each other via DHT, exchange SDP via NIP-44 NOSTR DMs, and establish a WebRTC data channel.
- ICE trickle works correctly through the NOSTR signaling channel.
- Connection establishment latency (initial peer discovery → data channel open) under 15 seconds on typical home networks.

### Phase 3: Symmetric NAT detection + relay fallback

**Acceptance criteria:**
- When ICE fails (forced by running both peers on carrier networks), the implementation correctly identifies failure within 20 seconds.
- Falls back to a manually-configured Geogram relay node and establishes a relay-mediated session.
- Application-level traffic flows through the relay end-to-end-encrypted.

### Phase 4: Self-bootstrapping relay tier

**Acceptance criteria:**
- A Geogram instance running on home Wi-Fi with successful UPnP correctly auto-promotes to relay status.
- Relay announcement appears on `RELAY_TOPIC` within 30 seconds of promotion.
- Two carrier-network peers discover the relay via DHT and successfully establish a session through it without manual configuration.
- Relay correctly demotes (stops announcing) when any criterion fails (battery drops, network changes, user disables).

### Phase 5: File distribution

**Acceptance criteria:**
- A test APK published as a magnet link via NOSTR is discovered and downloaded by another Geogram instance via the BT swarm.
- WiFi Direct + Kiwix-serve and BT swarm both work as distribution paths for the same ZIM archive.

---

## 16. Protocol Constants

Implementations MUST derive these at runtime from the protocol-constant strings rather than hardcoding the resulting bytes, so future versions can coexist.

```
PROTOCOL_VERSION         = "v1"

RELAY_TOPIC_INPUT        = "geogram/v1/relay"
PEER_TOPIC_SUFFIX        = "geogram/v1/peer"
GROUP_TOPIC_SUFFIX       = "geogram/v1/group"

DHT_BOOTSTRAP_NODES      = [
  "router.bittorrent.com:6881",
  "router.utorrent.com:6881",
  "dht.transmissionbt.com:6881",
  "dht.libtorrent.org:25401",
]

DHT_REANNOUNCE_INTERVAL  = 300     // seconds
DHT_BLOCKED_TIMEOUT      = 30      // seconds before fallback
ICE_FAILURE_TIMEOUT      = 20      // seconds
RELAY_SESSION_IDLE       = 300     // seconds

UPNP_LEASE_DURATION      = 3600    // seconds
UPNP_RENEW_AT_PERCENT    = 50

DEFAULT_BATTERY_THRESHOLD = 50     // percent
DEFAULT_BANDWIDTH_CAP     = 500    // MB per 24h
DEFAULT_MAX_RELAY_SESSIONS = 10
```

---

## 17. Open Questions

To revisit during or after Phase 1-2 implementation:

- **Capability advertisement.** Should the DHT announcement payload include capability flags (relay-capable, BT-swarm-capable, version), or is BEP 44 mutable items the right channel for this?
- **Presence: BEP 44 vs NOSTR.** Both can carry presence. NOSTR replaceable events are simpler and reuse existing infrastructure; BEP 44 is more decentralized but rate-limited. Defer until usage data clarifies which arrives faster in practice.
- **STUN choice.** Mozilla's STUN server is privacy-acceptable; running our own via the relay tier is cleaner. Defer until the relay tier is in place — relay nodes can serve STUN replies trivially.
- **Group hash collisions.** With many groups, two `GROUP_TOPIC(gid)` values could collide on the DHT. Mitigation: include a length prefix or version byte in the input. Decide before group support ships.
- **Mobile network regional differences.** Symmetric NAT prevalence varies by carrier and country. Phase 1 testing should cover at least Portugal (MEO/Vodafone/NOS) plus one non-EU carrier.
- **Detecting DHT blocking vs slow network.** Distinguishing "DHT is blocked here" from "the network is slow" is heuristic. Phase 1 should log timing data to inform a robust threshold.
- **Relay session concurrency limits.** Default 10 concurrent sessions is a guess. Tune based on observed memory and bandwidth on representative hardware (mid-range Android).

---

## 18. References

- BEP 5: DHT Protocol — http://www.bittorrent.org/beps/bep_0005.html
- BEP 9: Magnet URI — http://www.bittorrent.org/beps/bep_0009.html
- BEP 44: Storing Arbitrary Data in the DHT — http://www.bittorrent.org/beps/bep_0044.html
- BEP 52: BitTorrent v2 — http://www.bittorrent.org/beps/bep_0052.html
- BEP 55: Holepunch Extension — http://www.bittorrent.org/beps/bep_0055.html
- NIP-44: Encrypted Payloads (v2) — https://github.com/nostr-protocol/nips/blob/master/44.md
- RFC 6886: NAT-PMP
- RFC 6887: PCP
- RFC 8445: ICE
- WebRTC 1.0 — https://www.w3.org/TR/webrtc/
