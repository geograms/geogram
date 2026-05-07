# P2P direct UDP (BitTorrent-coordinated hole punching)

A serverless transport for small messages between two geogram peers,
across any pair of NATs. The connection is direct UDP between the
peers' STUN-discovered endpoints; only the rendezvous (the
exchange of those endpoints) happens through the public BitTorrent
infrastructure. No private servers anywhere in the path, no router
configuration, no UPnP, no TURN.

In the Devices browser this transport surfaces as the P2P chip
(orange). When that chip is on, the peer is reachable via
hole-punched UDP. Bandwidth is intentionally limited to roughly
1.2 KB per frame — the chip is the user-facing signal that this
path is for small messages, not file transfer.

## How it works

The mechanism stitches together pieces that already existed in
the project:

1. Endpoint discovery. Each peer learns its own public IPv4 and
   UDP port via the BEP 42 `ip` field BitTorrent DHT peers report
   in their replies. No external STUN server.
2. Endpoint exchange. The two peers use the WebTorrent WSS
   tracker signaling channel as a public mailbox: each side
   announces a small JSON envelope (`geoconnect_offer` /
   `geoconnect_answer`) containing its public endpoint plus four
   predicted next-port numbers, on a deterministic info_hash
   derived from the unordered npub pair (`sha1("geogram-signaling-v1:" +
   sorted(npubA, npubB))`). The trackers forward each envelope to
   peers announcing on the same info_hash. Round-trip latency is
   typically 200–400 ms across two ISPs.
3. Hole punch. Both peers fire UDP packets at each other's
   endpoint plus the four predicted next ports. Whichever NAT
   sees the outbound first creates an inbound mapping; the other
   peer's incoming packet finds the matching entry. With both
   sides firing simultaneously the connection lands in well under
   a second on cone NATs, and the predicted-port fan-out covers
   one-side cellular symmetric NAT. Reuses the DHT's UDP socket
   so the NAT mapping is kept warm by DHT keepalives — no second
   port through the firewall.
4. Reliable layer on top. A 25-byte fixed header
   `[GP01][type][8B sessionId][seq][ack][len][payload]` carries
   HELLO/HELLO_ACK/DATA/DATA_ACK/KEEPALIVE/BYE. Retransmit
   unacked DATA every 500ms up to 5 times. Keepalive every 25s.
   Session is dead after 60 seconds of no inbound.

End-to-end the first message takes roughly 1–2 seconds (the
WebTorrent endpoint exchange dominates). Subsequent messages
within the same conversation reuse the existing UDP path and
deliver in 10–100 ms — the chat connection is persistent, not
re-established per message.

## Constraints (why "small messages")

- Single-frame payload only in the current implementation. After
  the GP01 header and IP/UDP overhead, the practical limit is
  about 1255 bytes per frame, which fits one UDP datagram on a
  typical cellular path (1280-byte IPv6 minimum MTU).
- One logical stream per peer. There's no multiplexing in the
  current frame; concurrent file transfer plus chat would
  serialize on the same sequence-number space.
- No congestion control. Stop-and-wait reliability is fine for
  low-rate chat or sensor traffic. A 100MB file at one chunk
  per round-trip would take hours; that's a deliberate design
  bound, not a bug.
- Unencrypted on the wire today. The WebTorrent-routed
  rendezvous and the hole-punched UDP path are both plaintext.
  Trackers see only the per-pair info_hash and the endpoint
  blob, never message content; once direct UDP is established
  the path is between two specific IPs and exposed on the
  public internet. Either rely on application-layer encryption
  in the upper protocol, or wait for the planned ChaCha20-
  Poly1305 layer keyed by the npub-derived X25519 secret.

## Where it fits in the transport stack

ConnectionManager priority slot 18 — between WebRTC (15) and DHT
(25). When both peers have a public endpoint from BEP 42 and a
WebTorrent tracker connection, this transport beats WebRTC,
because it doesn't depend on ICE converging across symmetric
NATs. When the preconditions aren't met, the message falls
through to the next path (DHT geogram-signal, peer relay,
station relay) without user-visible failure.

## Public API for app code

External consumers should use `HolePunchService` directly rather
than going through the Transport interface:

```dart
import 'package:geogram/p2p/hole_punch_service.dart';

final session = await HolePunchService().connect('X3TEGE');
if (session != null && session.isReady) {
  // Send small payload (≤ 1255 bytes).
  await session.send(Uint8List.fromList(myBytes));

  // Receive payloads from the same peer.
  session.onData.listen((bytes) {
    print('peer sent ${bytes.length} bytes');
  });

  // Be notified when the session closes.
  session.onClose.listen((reason) {
    print('closed: $reason');
  });
}

// Listen for inbound sessions started by remote peers:
HolePunchService().incomingSessions.listen((session) {
  // Wire your app's protocol on top of session.onData / session.send
});
```

See `lib/p2p/hole_punch_service.dart` for the full surface and
`lib/p2p/hole_punch_protocol.dart` for the wire format. Pure-Dart,
no Flutter imports — runs from CLI tooling.

## Debug API

- `GET /api/p2p/serverless/hole_punch/status` — list active
  sessions, their effective remote endpoints, ready/closed
  state, last-activity timestamps.
- `GET /api/p2p/serverless/webtorrent/status` — tracker
  connection state, recent inbound payloads, active rendezvous
  hashes (compare to confirm both peers landed on the same
  one).

## Future work (not in scope today)

The path is genuinely fine for small messages, but two natural
extensions are tracked here so the design intent is on record.
Neither is built yet — both would layer on top of the existing
session API without changing it.

### Larger transfers (e.g. 100 MB files)

Achievable on the same hole-punched UDP path by adding a
fragmentation/window layer above the existing GP01 frames:

- Split the file into fixed chunks (~1200 bytes each) carrying a
  4-byte chunk index and 4-byte total-count header alongside the
  payload.
- Send a sliding window of N unacked chunks at once instead of
  the current stop-and-wait. With a 64-chunk window and 100 ms
  RTT the throughput is roughly 768 KB/s; a 256-chunk window at
  50 ms RTT pushes it to ~6 MB/s.
- Use a selective-ACK shape — replace the cumulative `ack`
  number with a small bitmap so the receiver can say "got
  100..127 except 110 and 115" and the sender retransmits only
  the holes.
- Add a congestion controller (AIMD or BBR) that adapts the
  window to observed loss and RTT. Without one a fixed window
  either underuses the link or melts a cellular uplink.
- Persist already-acked chunk indices to disk for pause/resume
  across session drops.

The natural API would be a `HolePunchStream` class wrapping a
`HolePunchSession`, exposing a sink and a stream of arbitrary-
length data. Existing chat use wouldn't notice — the new layer is
opt-in.

A swarm extension is also on the table: once two-peer hole punch
works, a third peer can learn the endpoints of A and B and fetch
chunks from either, in parallel. That's the BitTorrent piece-
exchange topology riding our hole-punched UDP transport instead
of the classic TCP per-peer connections.

### One-way streaming (live audio / video / sensor feeds)

The reliable layer is the wrong fit — retransmits arrive too
late to help live media. The simpler design adds a STREAM frame
type alongside DATA: sender stamps each frame with a sequence
number and timestamp and fires it without expecting ACKs;
receiver drops late frames and tolerates loss. RTP solved this
in the 90s; we'd be a thinner version of RTP-over-our-protocol.
A 30 KB/s voice or 500 KB/s SD video both fit comfortably on
the existing path, and the framing change is small.

### Caveats common to both extensions

- UDP MTU on cellular often drops to 1280 bytes total; our
  1255-byte payload limit accounts for it, but VPNs sometimes
  tighten the path further. A "ping with size N" probe at
  session start would let the protocol auto-detect the safe
  size.
- Long-running idle sessions can have their NAT mapping
  rebound by the carrier. The existing 25-second keepalive
  prevents that for chat; large transfers don't need it (the
  data flow itself keeps the mapping warm).
- Neither end controls the actual link bandwidth. A 100 MB
  transfer over a 1–5 Mbps cellular uplink takes 3–15 minutes
  no matter how clever the protocol is.
