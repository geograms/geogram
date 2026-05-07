# Live test: serverless P2P (BT-DHT-v2) — Desktop ↔ Android

End-to-end runbook for verifying the BT-DHT-v2 serverless stack lands the
Phase-1 and Phase-2 acceptance criteria from the spec
(docs/bridges/BT-DHT-v2.md §15) on a real laptop and a real Android.

The test pins routing to WebRTC + DHT so we exercise the new path
even though LAN (priority 10) and USB-AOA (priority 5) would normally
win on a connected phone.

This implementation does NOT use NOSTR for serverless P2P. Per user
direction, the only serverless rendezvous is the BitTorrent Mainline
DHT — the geogram_query message routes carry SDP and ICE candidates
peer-to-peer with no third-party servers.

---

## Prereqs

- Geogram desktop builds, launches via ./launch-desktop.sh.
- Geogram Android builds, deploys via ./launch-android.sh. The Android
  debug API listens on 127.0.0.1:3458 over adb forward (per
  feedback_phone_port_3456.md).
- Both instances on the latest main commit including the NOSTR removal.
- Both devices know each other's npub. The simplest way: pair them
  once via the existing Mirror flow, or just paste each npub into the
  other's contact list before the test. The DHT path is npub-keyed.

Open three terminal panes — one for each device's debug API, one for
running curl. The user runs both deploys (per
feedback_user_runs_deploy.md); Claude does not invoke the launch
scripts.

---

## Endpoints used (cheat sheet)

```
GET  /api/status                               → {callsign, npub, ...}
GET  /api/p2p/serverless/status                → reachability, DHT, blocked flag
POST /api/p2p/serverless/reachability/recheck  → re-run IPv6+UPnP
POST /api/p2p/serverless/dht/topic             → derive PEER_TOPIC(npub)
GET  /api/p2p/serverless/transports            → priority list + disabled flags
POST /api/p2p/serverless/transports/force-only → keep only listed transport ids
POST /api/p2p/serverless/transports/enable     → restore transports ({"all":true})
POST /api/p2p/serverless/signal                → send one WebRTC signal via DHT (default), relay, or ws
GET  /api/p2p/serverless/sessions              → active WebRTC sessions
```

Desktop and Android both bind their debug API to port 3456 by default.
When both run on the same laptop you cannot point adb forward at local
3456 because the desktop already owns it. Pick a different local port
(this runbook uses 3458) for the Android forward:

```bash
adb forward tcp:3458 tcp:3456    # local 3458 → Android 3456
```

So in the rest of this document:
- Desktop API: http://localhost:3456
- Android API: http://127.0.0.1:3458

---

## Step 0 — Capture identities

```bash
# Desktop
DESKTOP=$(curl -s http://localhost:3456/api/status | jq -r '{callsign, npub}')
echo "$DESKTOP"

# Android
ANDROID=$(curl -s http://127.0.0.1:3458/api/status | jq -r '{callsign, npub}')
echo "$ANDROID"
```

Save the four values (call them DESKTOP_CALL, DESKTOP_NPUB,
ANDROID_CALL, ANDROID_NPUB). The remaining steps use them.

---

## Step 1 — Phase-1 acceptance: discovery + reachability

Both devices should bootstrap the DHT and report a non-zero routing
table within 60s of launch.

```bash
# Desktop
curl -s http://localhost:3456/api/p2p/serverless/status | jq

# Android
curl -s http://127.0.0.1:3458/api/p2p/serverless/status | jq
```

Pass conditions:

- dht_running: true
- dht_routing_size > 0
- reachability.status is one of reachableIPv6, reachableUPnP, or
  (acceptably) notReachable if the network blocks UPnP — that's still a
  pass for Phase 1, the device just becomes a relay-consumer-only node.
- dht_blocked: false. If true, the DHT bootstrap got no responses in
  30s and serverless P2P is non-functional on that network. There is
  no NOSTR fallback by design; the user must be on a DHT-reachable
  network (essentially any consumer ISP).

Both devices should agree on the spec-derived peer topic:

```bash
# Compute PEER_TOPIC(android_npub) on the desktop.
curl -s -X POST http://localhost:3456/api/p2p/serverless/dht/topic \
  -H 'Content-Type: application/json' \
  -d "{\"kind\":\"peer\",\"input\":\"$ANDROID_NPUB\"}" | jq

# Compute PEER_TOPIC(android_npub) on the Android — same input.
curl -s -X POST http://127.0.0.1:3458/api/p2p/serverless/dht/topic \
  -H 'Content-Type: application/json' \
  -d "{\"kind\":\"peer\",\"input\":\"$ANDROID_NPUB\"}" | jq
```

spec_info_hash MUST match across both devices. (legacy_info_hash may
also appear during the 4-week dual-announce window — fine to ignore.)

Log signals to grep for in each device's log:

- "Reachability: state IPv6/UPnP at <ip>:<port>"
- "DHT bootstrap complete: N nodes"
- "P2P: announced on DHT (topics=2 ...)"

---

## Step 2 — Pin routing to the serverless path

When the Android is plugged in over USB to the laptop and both are on
the same Wi-Fi, usb_aoa (priority 5) and lan (priority 10) will
satisfy canReach in milliseconds and the routing strategy will pick
them every time. We need to take both out of the running so the test
actually exercises WebRTC + DHT.

```bash
# Inspect current transports on both ends.
curl -s http://localhost:3456/api/p2p/serverless/transports | jq
curl -s http://127.0.0.1:3458/api/p2p/serverless/transports | jq

# Force-only WebRTC + DHT on BOTH devices.
for HOST in localhost:3456 127.0.0.1:3458; do
  curl -s -X POST http://$HOST/api/p2p/serverless/transports/force-only \
    -H 'Content-Type: application/json' \
    -d '{"keep": ["webrtc", "dht"]}' | jq
done
```

Expected: each call returns currently_disabled containing
["usb_aoa","lan","peer_relay","station","bluetooth_classic","ble"]
(order may differ). The serverless WebRTC path is now the only one
routing will pick.

Don't forget step 5 — restoring transports — at the end.

---

## Step 3 — Phase-2 acceptance: DHT signaling round trip

Send a synthetic offer from the desktop directly via the DHT signaling
channel and confirm the Android receives it. This exercises the
geogram_query rendezvous and the receiver's _handleGeogramQuery without
driving the full WebRTC stack.

```bash
SESSION_ID=$(printf '%016x' $RANDOM$RANDOM)

# Desktop → Android: send a synthetic offer via DHT.
curl -s -X POST http://localhost:3456/api/p2p/serverless/signal \
  -H 'Content-Type: application/json' \
  -d "{
    \"toCallsign\": \"$ANDROID_CALL\",
    \"type\": \"offer\",
    \"sessionId\": \"$SESSION_ID\",
    \"sdp\": {\"type\": \"offer\", \"sdp\": \"v=0\\r\\no=- 1 1 IN IP4 0.0.0.0\\r\\ns=-\\r\\nt=0 0\\r\\n\"},
    \"route\": \"dht\"
  }" | jq
```

Pass conditions:

- Response: success: true, route: "dht".
- Desktop log: "P2P: sent geogram signal offer to <ANDROID_CALL> at <ip>:<port>"
- Android log within ~2s: "WebRTCSignaling: Received offer from <DESKTOP_CALL> via DHT (session: <SESSION_ID>)"

If the Android log doesn't show the receive line, common causes:

1. The Android hasn't announced its UDP endpoint to the DHT yet — check
   that /api/p2p/serverless/status on the Android shows reachability of
   reachableIPv6 or reachableUPnP.
2. The desktop doesn't yet know the Android's UDP endpoint. The DHT
   peer-discovery loop populates this on first run; wait ~30-60s after
   both ends are up, then retry.
3. The Android's npub on the desktop's contact list is wrong — re-run
   /api/p2p/serverless/dht/topic from step 1 to confirm both ends see
   the same hash.

---

## Step 4 — Trigger a real WebRTC session

Send a chat from desktop to Android via the existing chat UI. With LAN
and USB disabled, ConnectionManager will pick webrtc (priority 15)
and try to establish a session. The signaling will fall through to
DHT (WebSocket fails with target_not_connected, peer relay times out,
DHT delivers).

After ~15s:

```bash
curl -s http://localhost:3456/api/p2p/serverless/sessions | jq
curl -s http://127.0.0.1:3458/api/p2p/serverless/sessions | jq
```

Pass conditions (one or both sides):

- count >= 1
- sessions[0].callsign matches the other device's callsign
- sessions[0].state is ready or connecting
- sessions[0].connected: true (after ICE completes; if the home
  network has IPv6 or successful UPnP this should happen within ~5-15s)

Log signals to grep on both sides:

- "WebRTCSignaling: Sent offer to <peer> via DHT rendezvous" — sender
- "WebRTCSignaling: Received answer from <peer> via DHT (session: ...)" — sender
- "WebRTCPeerManager: ICE state for <peer>: RTCIceConnectionStateConnected"
- "WebRTCPeerManager: Connection ready for <peer>" (or equivalent)

If ICE stays at checking for 20s on one side, you'll see
"WebRTCPeerManager: ICE failed for <peer>, switching to relay" —
that's Phase-3 territory and indicates this network pair can't go direct
(e.g. carrier-grade NAT on the Android side over cellular).

---

## Step 5 — Restore transports (do not skip)

Both devices come back to normal routing.

```bash
for HOST in localhost:3456 127.0.0.1:3458; do
  curl -s -X POST http://$HOST/api/p2p/serverless/transports/enable \
    -H 'Content-Type: application/json' -d '{"all": true}' | jq
done
```

currently_disabled should be empty on both responses.

---

## Optional: stress the relay tier (Phase-3 + Phase-4)

These steps are opt-in — the relay tier requires either:

- A second laptop on a known-public Wi-Fi (so it auto-promotes via
  RelayPromotionController), OR
- A manualRelayHostPort setting pointing at a reachable Geogram station.

Walk-through, if you have a third device acting as a relay:

```bash
# On the relay device — force-promote (bypasses §10.1 criteria).
curl -X POST http://relay-host:8080/api/p2p/serverless/relay/promote \
  -H 'Content-Type: application/json' -d '{"enable": true}'
curl http://relay-host:8080/api/p2p/serverless/relay/sessions | jq
```

Then on the Android, set manualRelayHostPort in the serverless
settings (currently editable only by writing the JSON file directly:
{callsign}/p2p/serverless_settings.json via the existing storage
debug API). Trigger an ICE failure (e.g. by switching the Android to
cellular while the desktop stays on the home network) and watch
/api/p2p/serverless/relay/sessions populate.

PR3-PR4 ship the detection + relay-session machinery. Full data-path
bridging (substituting the relay byte stream for the WebRTC data
channel) is the remaining piece — it's beyond what flutter_webrtc
exposes natively and is being tracked separately.

---

## Tear-down

The transport-disable state is in-memory only; restarting either
process clears it. There's no persisted state to clean up.
