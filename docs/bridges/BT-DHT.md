# Current Connection Mechanism

**Status**: Current implementation as of `2026-03-25`
**Scope**: How Geogram currently chooses between LAN, public HTTP, DHT, peer relay, station, WebRTC, USB, and Bluetooth

## Overview

The file name says `BT-DHT`, but the current mechanism is no longer "DHT transport only".

Today Geogram uses a layered connection stack:

1. Prefer direct local transports first.
2. Prefer direct public HTTP when a peer is reachable on the internet.
3. Use BitTorrent DHT to discover or refresh that public endpoint.
4. Use peer relay when the target is not directly reachable.
5. Use station or WebRTC where those paths are available.

The practical consequence is:

- DHT is now mainly a discovery, reachability, and signaling layer.
- Cross-network message delivery often completes through `peer_relay`, not raw DHT payload transport.
- Same-LAN traffic should stay on `lan`.

## Transport Priority

The transports are registered in this order in `lib/main.dart`:

| Priority | Transport | Intended scope |
|---------|-----------|----------------|
| 5 | `usb_aoa` | Physical USB cable |
| 10 | `lan` | Same local network |
| 15 | `webrtc` | Direct data channel once signaling succeeds |
| 25 | `dht` | Public internet discovery and direct HTTP reachability |
| 27 | `peer_relay` | Cross-network relay when direct reachability is not available |
| 30 | `station` | Station-mediated internet path |
| 35 | `bluetooth_classic` | Short-range fallback |
| 40 | `ble` | Short-range fallback |

`ConnectionManager` uses priority plus `canReach()` checks, with short reachability caching, to pick the first usable path.

## What DHT Does Now

Current DHT behavior lives mainly in `lib/p2p/p2p_service.dart` and `lib/connection/transports/dht_transport.dart`.

### DHT responsibilities

- Bootstrap onto the BitTorrent Mainline DHT.
- Announce and query the global `geogram` topic.
- Announce and query per-user `npub` topics.
- Announce pair-specific rendezvous topics for active peer discovery.
- Learn the device's public IP and observed UDP port from DHT responses.
- Check whether the device's own public HTTP endpoint is actually reachable.
- Register discovered peers into `DevicesService` with `internet` capability.
- Provide a fallback signaling path for WebRTC.

### Important limitation

DHT is not currently the general payload carrier.

For normal API requests and direct messages, `DhtTransport` tries to talk to the peer's HTTP endpoint. If that endpoint is stale or missing, DHT is used to refresh the endpoint information. The payload itself is still sent over HTTP once a usable public URL is known.

So, in current code, "send over DHT" effectively means:

1. find or refresh the peer's public endpoint via DHT
2. send the real request to that endpoint over HTTP

It does not mean "deliver the full message body over UDP through the DHT".

## What Peer Relay Does Now

Current peer relay behavior lives in `lib/services/peer_relay_service.dart` and `lib/connection/transports/peer_relay_transport.dart`.

Peer relay exists for the cases where DHT can identify the peer but direct public HTTP delivery is not possible.

### Relay model

- Devices that can act as relays advertise `canRelay` plus a relay base URL.
- That base URL is taken from `relayUrl` when present, otherwise from the device's public `url`.
- The preferred case is the target device itself exposing a relay endpoint.
- If the sender is publicly reachable, the sender's own relay can be used as a fallback queue for the other side to poll.

### Relay flow

1. Sender chooses `peer_relay`.
2. Sender posts an envelope to `/api/p2p/relay/send`.
3. Recipient long-polls `/api/p2p/relay/poll?callsign=...`.
4. Recipient receives the queued envelope and processes it locally.

This is used both for cross-network transport envelopes and for WebRTC signaling when needed.

### Important limitation

Peer relay currently handles JSON-style transport and signaling envelopes. It is not the generic path for arbitrary binary streaming.

## What WebRTC Does Now

WebRTC is a direct transport only after signaling succeeds.

The signaling order in `lib/services/webrtc_signaling_service.dart` is:

1. station WebSocket
2. peer relay
3. DHT signaling

So WebRTC is not independent of the rest of the stack. It depends on at least one working signaling path.

## How Devices Become Reachable

`DevicesService.syncDeviceToConnectionManager()` is where discovered device metadata gets translated into transport registrations.

Current mapping:

- A local `http://192.168.x.x:3456` style URL is registered into `LanTransport`.
- A public internet URL is registered into `DhtTransport`.
- A relay-capable public endpoint is registered into `PeerRelayTransport`.

This matters because the UI may show one device, but internally multiple connection methods can be attached to that same peer.

## Identity Validation And Stale LAN Protection

LAN is no longer accepted just because a callsign matches.

`LanTransport` verifies `/api/status` against the expected peer identity before treating a LAN candidate as reachable:

- `device_id` is preferred
- `npub` is the fallback identity check

This avoids stale LAN entries hijacking cross-network traffic, which was a real failure mode during Android-to-laptop testing.

## Typical Paths

### Same LAN

- `lan` should win.
- Device talks directly to the peer's local HTTP endpoint.

### Different networks, target has reachable public HTTP

- `dht` can win.
- DHT discovery refreshes the peer endpoint if needed.
- The actual request goes to the peer's public HTTP endpoint.

### Different networks, target is not directly reachable

- `peer_relay` usually wins.
- Sender queues the message on the target relay or on a fallback sender-side relay queue.
- Recipient polls and receives it asynchronously.

### Browser or NAT-friendly direct path after signaling

- `webrtc` can win after the session is established.

## Security Settings That Affect This

Relevant settings live in `lib/services/security_service.dart`.

### BLE Only Mode

When enabled, the system should avoid the internet-style transports and stay on short-range methods.

### USB Access

`USB access` controls whether Geogram itself is allowed to use USB as a communication path. This was added so the USB cable can stay connected for ADB while Geogram ignores USB transport.

If `USB access` is off:

- ADB can still use the cable.
- Geogram should not use USB AOA for discovery or messaging.

## Current Debug API Hooks

Useful verification endpoints are documented in `docs/API.md`.

### DHT and routing

- `POST /api/debug` with `{"action":"dht_status"}`
- `POST /api/debug` with `{"action":"dht_find_user_light","npub":"..."}`
- `POST /api/debug` with `{"action":"dht_known_targets"}`
- `POST /api/debug` with `{"action":"dht_probe_once"}`
- `POST /api/debug` with `{"action":"device_ping","callsign":"X1ABC"}`

### Force a specific transport

- `POST /api/debug` with `{"action":"device_api_request","callsign":"X1ABC","transport":"peer_relay","method":"GET","path":"/api/status"}`
- `POST /api/debug` with `{"action":"device_api_request","callsign":"X1ABC","transport":"dht","method":"GET","path":"/api/status"}`
- `POST /api/debug` with `{"action":"device_send_dm","callsign":"X1ABC","transport":"peer_relay","content":"hello"}`

Valid transport names currently include:

- `lan`
- `dht`
- `peer_relay`
- `station`
- `webrtc`
- `usb_aoa`
- `bluetooth_classic`
- `ble`

### Relay inspection

- `GET /api/debug/peer-relay`
- `POST /api/p2p/relay/send`
- `GET /api/p2p/relay/poll?callsign=X1ABC&timeout=20`

## Known Limits

- DHT does not currently carry arbitrary message payloads by itself.
- Direct `dht` delivery still depends on the peer exposing a working public HTTP endpoint.
- Peer relay currently focuses on queued envelopes, not general binary transport.
- WebRTC still needs some other signaling path to bootstrap.
- The device list may aggregate multiple connection methods for one peer, but routing still happens per transport registration underneath.

## Relevant Files

Core files for the current mechanism:

- `lib/main.dart`
- `lib/connection/connection_manager.dart`
- `lib/connection/routing_strategy.dart`
- `lib/connection/transports/lan_transport.dart`
- `lib/connection/transports/dht_transport.dart`
- `lib/connection/transports/peer_relay_transport.dart`
- `lib/services/devices_service.dart`
- `lib/services/peer_relay_service.dart`
- `lib/services/webrtc_signaling_service.dart`
- `lib/p2p/p2p_service.dart`
- `lib/services/security_service.dart`

## Bottom Line

The current cross-network design is:

- DHT finds peers and refreshes public endpoint information.
- Direct HTTP is preferred when that public endpoint is reachable.
- Peer relay handles the NATed cases that direct public HTTP cannot.
- WebRTC can become the direct data path, but only after being signaled through station, relay, or DHT.

That is the mechanism that is currently implemented in code. Any document that describes Geogram as "DHT transport only" is outdated.
