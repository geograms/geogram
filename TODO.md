# Android startup OOM — investigation in progress

## Problem

On Android (TANK device), Geogram's Dart isolate climbs from ~870 MB to
~4.6 GB RSS within ~75 seconds of every fresh start, then crashes with
`Out of Memory` from `_Timer._runTimers`. Reproduces with no UI
interaction. Verified across multiple force-stop / clean-restart cycles.
Desktop is unaffected.

OOM stack:

```
[ERROR] Out of Memory
#0 _Timer._runTimers (dart:isolate-patch/timer_impl.dart:423:19)
#1 _Timer._handleMessage (dart:isolate-patch/timer_impl.dart:454:5)
#2 _RawReceivePort._handleMessage (dart:isolate-patch/isolate_patch.dart:193:12)
```

The stack tells us *some* periodic timer's callback is the final
allocator, but not which timer.

## What's been ruled out

- **Orphan Shared access token** — cleaned `access-tokens.json` to
  contain only the live SmokeTest token. OOM still happens.
- **All teleport bridges** (APRS, IRC, XMPP, NOSTR, AT Proto, MeshCore,
  BitChat, Meshtastic) — gated via `debug.skipBridgeAutoStart`. With
  the gate on, OOM still happens.
- **The "minimalStartup" group** — `debug.minimalStartup` skips
  LocalBackup, StationDiscovery (LAN scan), P2P (DHT bootstrap),
  DevicesService BLE init, ProximityDetection, BackupService,
  StationService, ConferenceService, DMQueueService,
  MessageRetention, GroupSync. Even with **both** flags on, RSS still
  goes 1.07 GB → 3.65 GB between T=15 s and T=30 s, hits 4.6 GB by T=60 s.
- **The bridges are not the cause.** Ruled out by the matrix above.
- **The Shared sync engine** is *not* the cause: with no triggers and
  with LAN unreachable, sync's LAN gate skips the tick cleanly and
  allocates nothing. Confirmed via task_status that the
  `shared.sync` timer is registered but ticks are no-ops while LAN is
  empty.

## What's still possible

These run before the bridge block AND are not gated by either flag:

- `UserLocationService.initialize()` (line 668)
- `ConnectionManager.initialize()` (line 686) — registers 8 transports
  and initializes them
- `UpdateService.initialize()` (line 692) — starts `checkForUpdates()`
  immediately on init; if `autoDownloadUpdates` is enabled, downloads
  the APK; `_verifyApkIntegrity` does `file.readAsBytes()` on the full
  APK (potential 50–100 MB Uint8List allocation per run; not 3 GB but
  still suspect)
- `LogApiService.start()` — HTTP server starts here
- `NetworkMonitorService` — 10 s periodic LAN check
- `WebSocketService.reconnect` (10 s) and `ping` (30 s) — but only
  fire when a session is active
- The HomePage/AppsPage that paints once `runApp` runs — if there are
  many app cards with thumbnails, image cache could spike
- `media_kit` native leak — `/data/data/dev.geogram/files/` had ~30
  `NativeReferenceHolder.PID` files (one per crashed PID). Suggests
  video-player handles aren't disposed across runs. Native, not Dart
  heap, but worth verifying.

## Bisect tooling currently in tree

Both flags persist via ConfigService and survive restarts:

- `debug.skipBridgeAutoStart` — toggle: `bridges_skip enabled=true|false`
- `debug.minimalStartup` — toggle: `minimal_skip enabled=true|false`
- Read both: `bridges_status`

Debug API is reached at `http://127.0.0.1:3456` on the phone (not 3457).
POST JSON to `/api/debug` with `{"action":"…", …}`.

`lib/main.dart` now has `print('[STARTUP] before X')` /
`print('[STARTUP] after X')` lines around each major awaited step in
the deferred init phase. Logcat will show whichever step was running
when the heap explodes.

## Next steps (continue here)

1. Deploy the latest commit (`9bc5e012` or later) via `./launch-android.sh`.
2. Force-stop Geogram, clear logcat, restart.
3. Filter logcat for `[STARTUP]` lines while watching RSS every 5 s.
4. Whatever step has its `before` line emitted but no matching `after`
   when RSS jumps from ~1.4 GB to ~3.5 GB is the culprit.
5. Bisect inside that step (e.g. if it's `ConnectionManager.initialize`,
   gate each transport individually).

The most-suspicious individual targets to gate next, in order:

1. `UpdateService.initialize` — `_verifyApkIntegrity` does a
   `readAsBytes` on the whole APK. Patch: stream-verify (read first 4
   bytes + last 22 bytes via random access).
2. `ConnectionManager.initialize` (per-transport) — BLE / BT Classic /
   WebRTC transport native init may pull large native libs.
3. The home page once `runApp` returns — see if rendering AppsPage with
   many user-installed apps loads big assets.

## Reference: full timing data for the both-flags-ON run

```
T=0s   RSS=1071 MB
T=15s  RSS=1368 MB
T=30s  RSS=3654 MB   ← the explosion lives in this 15 s window
T=45s  RSS=3834 MB
T=60s  RSS=4589 MB   ← effectively OOM
```

Last logcat lines from that run before silence:

```
MAIN: Starting app (deferred services will initialize in background)
NOTIFICATION_DEBUG: _checkPendingNotification called
DEBUG StationService: Resetting isConnected for P2P.radio
… GET [200] /api/status   (T≈19 s — last entry before OOM)
```

`LogService().log` writes to an in-memory ring, not logcat. The new
`print('[STARTUP] …')` lines bypass that and reach logcat directly,
which is why they were added.

## Confirmed working

The Shared sync feature itself works end to end on Android once LAN
is reachable: SmokeTest folder converged at 50 files in three batched
cycles (20+20+10), reverse-direction push from phone to desktop
succeeded, RSS held flat at ~1.5 GB across all sync cycles. The OOM
is *not* a Shared-sync bug.
