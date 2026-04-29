# Wapp Engine Interfaces

This document defines the abstractions a **wapp engine** must
provide to host wapps and the contract a wapp module must respect to
run inside one.

A wapp is a self-contained WASM module shipped as a `.wapp` ZIP
package. The engine is the host-side runtime that loads the module,
exposes the abstractions below as imported functions (the HAL),
delivers messages and events, and surfaces the wapp's UI to the
user. The engine is the only side of the contract that talks to the
real OS — the wapp itself runs in a sandbox and only ever sees the
HAL.

There are two reference implementations of the engine in this
repository:

- `iwi/lib/wapp/wapp_engine.dart` — the prototype host
- `lib/wapp/wapp_engine.dart` — the integrated geogram host

Both implement the same abstractions. The C-level ABI for the
abstractions lives in `wapps/hal/geogram_wasm_hal.h`.

---

## 1. Module lifecycle

The engine drives the WASM module through four lifecycle hooks the
module must export:

| Export | Called when | Notes |
|---|---|---|
| `module_init()` | Once after WASM instantiation | Wire up state, subscribe to topics, register provider responders |
| `module_tick()` | Every `tick_interval_ms` | Periodic work: poll, refresh, prune |
| `module_handle_event()` | When a message lands in the inbox | Drain `hal_msg_recv` and `hal_event_recv` here |
| `module_destroy()` | On wapp unload | Flush any pending writes; the engine releases everything else |
| `module_tick_interval_ms()` | Once during init | Module-declared default; the manifest's `tick_interval_ms` overrides |

Lifecycle events the engine must publish on the host event bus:
`WappLoadedEvent`, `WappUnloadedEvent`, `WappCrashedEvent` (with a
phase tag: `load`, `init`, `tick`, `handle_event`).

---

## 2. Storage

**Direct disk access is forbidden.** The wapp runs in a WASM sandbox
and has no way to call `open(2)`, mmap, or any host filesystem
primitive. Every byte the wapp reads or writes — KV, files,
package contents, screens, translations — must flow through the
HAL. The engine is the only side that talks to the real
filesystem, and it must do so through a uniform abstraction so the
same wapp works identically when the active profile is:

- a plain folder on disk (filesystem profile)
- an encrypted SQLite archive (encrypted profile)
- an in-memory stub (web / tests)

The reference engines route every storage call through
`ProfileStorage` (see `lib/services/profile_storage.dart`) which
hides the backend behind a single abstract interface. New backends
plug in by implementing that interface — no wapp ever needs to
change.

### 2.1 Key-value store (`hal.kv`)

Every wapp gets a private KV namespace scoped to its wapp ID. Keys
and values are arbitrary byte strings; the engine persists them
across runs.

```c
uint32_t hal_kv_get   (key, key_len, val_buf, val_buf_len);
int32_t  hal_kv_set   (key, key_len, val, val_len);
int32_t  hal_kv_delete(key, key_len);
uint32_t hal_kv_list  (prefix, prefix_len, buf, buf_len);
int32_t  hal_kv_exists(key, key_len);
uint32_t hal_kv_size  (key, key_len);
```

The engine must:
- Hold the KV in memory while the wapp runs (HAL calls are
  synchronous — no `await` allowed inside an import)
- Persist changes to the active profile's storage
  (`<profile>/<wappId>/kv.json` in the integrated host)
- Work transparently on top of an encrypted backend (the parent's
  `EncryptedProfileStorage`) when the active profile is encrypted

### 2.2 Per-wapp file I/O (`hal.file`)

Bulk binary I/O scoped to the wapp's data folder. Handles are
opaque integers; out-of-range reads return zero, writes fail with
`-1`.

```c
int32_t hal_file_open (path, path_len, mode);   // mode: 0=R 1=W 2=A
int32_t hal_file_read (handle, buf, buf_len);
int32_t hal_file_write(handle, buf, buf_len);
void    hal_file_close(handle);
```

### 2.3 Package read access

The engine exposes the wapp's own package directory (manifest,
screens, media, lang) read-only via the same path conventions the
host uses (`screens/home.ui.json`, `media/icons/icon.svg`,
`lang/en.json`). Wapps don't read these directly — the engine
parses screens, surfaces translations via `hal_i18n_get`, and
renders icons on the host side.

---

## 3. Messaging (host ↔ wapp)

A duplex JSON channel between the wapp's WASM module and the host.
Used for everything the GeoUI renderer can't express on its own.

```c
void     hal_msg_send    (json, json_len);   // wapp → host
uint32_t hal_msg_available(void);            // bytes in next msg
uint32_t hal_msg_recv    (buf, buf_len);     // host → wapp
```

Reserved message types the engine **must** handle:

| Direction | `type` | Purpose |
|---|---|---|
| wapp → host | `notify` | Show a notification (level, title, body, scope) |
| wapp → host | `ui.append` | Append a structured line to a host-rendered output group |
| wapp → host | `ui.log.append` | Append text to a `$type="log"` field |
| wapp → host | `widget.request` | Call a functionality on another wapp |
| wapp → host | `widget.response` | Reply to a `widget.request` |
| wapp → host | `wapp.fetch_index` | Ask the host to fetch a remote wapp index |
| wapp → host | `wapp.install` | Ask the host to download + extract a `.wapp` |
| wapp → host | `store.sources` | Push the current wapp-store source list |
| host → wapp | `command` | Generic command + scalar fields bag |
| host → wapp | `action` | GeoUI action button fired |
| host → wapp | `wapp.index` | Reply to `wapp.fetch_index` |
| host → wapp | `wapp.installed` | Confirmation for `wapp.install` |

Anything else is wapp-specific and routed unchanged.

---

## 4. Event bus (cross-wapp pub/sub)

A topic-based broadcast channel separate from the host ↔ wapp
message channel. Lets wapps publish to and subscribe from each
other without knowing names.

```c
int32_t  hal_event_subscribe  (topic, topic_len);
int32_t  hal_event_unsubscribe(topic, topic_len);
int32_t  hal_event_publish    (topic, topic_len, data, data_len);
uint32_t hal_event_available  (void);
uint32_t hal_event_recv       (topic_buf, topic_buf_len,
                                data_buf, data_buf_len);
```

Engine duties:
- One private inbox per loaded wapp; deliver each event to every
  subscriber of an exact-match topic
- Mirror every publish on the host event bus as a
  `WappEventBridgeEvent` so Dart-side observers can debug or bridge
- Drop events for unloaded wapps cleanly

---

## 5. Functionalities (provider/consumer)

Wapps may declare functionalities they provide (in
`provides.functionalities` in `manifest.json`) and call
functionalities provided by other wapps via `widget.request`.

Lookup is by exact ID (e.g. `text.greet`, `tile_provider.osm`).
When multiple wapps provide the same ID, the user picks one default
through a host-managed preference.

The engine's broker must:
- Maintain a registry: `functionalityId → [providerWapp]`
- Resolve the request to one provider (preference > first
  registered)
- Spin up a **headless** instance of the provider (its own engine
  with no UI) when needed
- Inject the request as `widget.request` into the provider, run
  `module_handle_event`
- Scrape the outbox for a matching `widget.response` and deliver
  it back to the caller's inbox
- Surface errors (no provider, response timeout, exception) as
  `widget.response` with an `error` field

---

## 6. Identity-addressed messaging (transport-agnostic)

Wapps must never pick the transport. They address peers by
**callsign** or **npub** and let the engine route the message
through whichever physical channel is available — LAN, mesh
(LoRa, BLE), station relay, or NOSTR relay. If multiple paths
exist the engine picks the cheapest reachable one and falls back
silently when one drops.

Reserved host ↔ wapp message types:

| Direction | `type` | Purpose |
|---|---|---|
| wapp → host | `peer.send` | Send opaque bytes/JSON to a peer by identity |
| wapp → host | `peer.subscribe` | Subscribe to inbound messages from a peer or topic |
| wapp → host | `peer.unsubscribe` | Drop a previous subscription |
| wapp → host | `peer.who` | Ask the engine to resolve a callsign → npub |
| host → wapp | `peer.recv` | Inbound message from a peer (after subscribe) |
| host → wapp | `peer.status` | Peer reachability changed (online, offline, channel) |
| host → wapp | `peer.who.result` | Reply to `peer.who` |

Outbound shape (`peer.send`):

```json
{
  "type": "peer.send",
  "to":   "npub1…"                        | "X1ABCD",
  "tag":  "<wapp-defined channel name>",
  "data": "<opaque string or JSON object>",
  "qos":  "best-effort" | "reliable",      // optional
  "ttl_ms": 30000                          // optional
}
```

Inbound shape (`peer.recv`):

```json
{
  "type": "peer.recv",
  "from": "npub1…",
  "tag":  "...",
  "data": "...",
  "via":  "lan" | "lora" | "ble" | "relay" | "nostr"
}
```

Engine duties:
- Maintain a routing table mapping `npub` (canonical) and the
  short `callsign` form to the set of active transports
- Pick the cheapest viable transport per message, retry on
  failure if `qos == "reliable"`, drop silently otherwise
- Sign outbound messages with the active profile's `nsec` so
  the receiver can authenticate the `from` field
- Expose the chosen transport in `via` for debugging only — the
  wapp must not branch on it
- Buffer inbound messages until the wapp `peer.subscribe`s; drop
  messages for unloaded wapps cleanly

Wapps that need **broadcast to anyone listening** use the
cross-wapp event bus (Section 4) instead — that channel is
local-only by design.

---

## 7. Triggers and timers

There is no general scheduling primitive in the HAL. The engine
provides:

- A periodic **tick timer** at `tick_interval_ms` (per manifest)
  that calls `module_tick()`
- An **event-driven trigger** that calls `module_handle_event()`
  whenever a host→wapp message lands in the inbox

If a wapp needs delayed work it must self-schedule using
`hal_time_ms()` and check inside `module_tick()`.

---

## 8. Background processes and the task monitor

Wapps cannot spawn OS processes, threads, or isolates from inside
the WASM sandbox. When a wapp needs work that runs **outside the
foreground UI thread** — long-running pollers, sync loops, batch
fetches, sensor watchers — it asks the engine to register a
**managed task**. The engine spins it off, schedules it, and
exposes it through the host's task monitor so the user (or the
host itself) can pause, resume, throttle, or kill it.

Reserved host ↔ wapp message types:

| Direction | `type` | Purpose |
|---|---|---|
| wapp → host | `task.register` | Declare a background task and have the engine start scheduling it |
| wapp → host | `task.unregister` | Drop a previously-registered task |
| wapp → host | `task.update` | Mutate task description / priority / interval at runtime |
| wapp → host | `task.heartbeat` | Report progress + a CPU intensity hint |
| wapp → host | `task.list` | Ask the host for the current snapshot |
| host → wapp | `task.tick` | Fire of a periodic task — the wapp does its work and replies via outbox messages |
| host → wapp | `task.paused` | The user (or host) paused this task — stop emitting work |
| host → wapp | `task.resumed` | Resume normal scheduling |
| host → wapp | `task.throttled` | The host is rate-limiting this task; tighten the next tick |
| host → wapp | `task.killed` | The host gave up on this task; do final cleanup |

Registration shape (`task.register`):

```json
{
  "type": "task.register",
  "id":          "<wapp-scoped slug>",
  "name":        "Tile prefetch",
  "description": "Fetching tiles for visible viewport",
  "priority":    "critical" | "normal" | "low",
  "type":        "periodic" | "isolate" | "oneshot",
  "interval_ms": 5000,
  "boot":        "always" | "on-demand" | "lazy",
  "boot_order":  10,
  "max_cpu_pct": 25,
  "max_runtime_ms": 30000
}
```

The reference engine maps these onto `MonitoredTask` registered
with `TaskMonitorService` (see
`lib/services/task_monitor_service.dart` and
`lib/models/monitored_task.dart`). The host UI lists every task
with status (`idle`, `running`, `paused`, `error`), last duration,
run count, success/fail counters, and last error message.

### 8.1 Lifecycle

A managed task progresses through:

```
idle ── tick ──▶ running ──▶ idle (success)
                              │
                              └──▶ error  ── fixed ──▶ idle
                                          │
                                          └─ exhausted ──▶ killed
   ▲                                                        │
   │                                                        │
   pause/resume ◀──── any state ────────────────────────────┘
```

Engine duties:
- Drive periodic tasks at their declared `interval_ms` by sending
  `task.tick` to the wapp's inbox
- Time each tick; record `lastDuration` and update `runCount`
- Stop firing ticks for paused tasks; resume cleanly on resume
- Mirror status changes on the host event bus
  (`TaskStatusChangedEvent`) so the UI updates without polling
- Catch and record exceptions as `task.error` then transition the
  task to `error` state

### 8.2 Startup tasks (boot orchestration)

A wapp can mark a task as **startup-critical**. The engine runs
those during host boot before the launcher grid renders.

| `boot` | Behaviour |
|---|---|
| `always` | Run on every host start; failures are surfaced but don't block boot |
| `on-demand` | Run only when the wapp's UI is opened |
| `lazy` | Run after the launcher is interactive (idle queue) |

`boot_order` is a small integer; lower = earlier. Tasks at the
same order start in parallel (see iwi's `BootOrchestrator` with
`BootStart.sequential | BootStart.parallel`).

Engine duties:
- Sort startup tasks by `(priority desc, boot_order asc)` and run
  them in that order during host init
- Block the launcher's first paint only on `priority: critical`
  startup tasks; everything else runs after first paint
- Surface startup failures as `WappCrashedEvent` with
  `phase: "startup"` so the launcher can show a recovery banner
- Persist the result of the last boot (success/failed/skipped)
  so the user can inspect why a wapp didn't come up

### 8.3 Resource tracking and throttling

The task monitor records, per task:

- **Last duration** — wall time of the most recent tick
- **CPU intensity** — declared `max_cpu_pct` capped against
  observed `lastDuration / interval_ms` ratio
- **Memory growth** — delta in `hal_heap_free()` between ticks
  (engine-side approximation, not perfect)
- **Outbox volume** — messages emitted per tick, throttled when
  excessive

The engine **throttles a misbehaving wapp** when any of:

- `lastDuration > interval_ms` for N consecutive ticks (the wapp
  can't keep up — back off)
- Cumulative CPU% over a sliding window exceeds `max_cpu_pct`
- Outbox flood (> 500 messages/sec sustained)
- Memory growth > 64 KB/tick for N ticks

Throttling actions, in escalation order:
1. Increase the effective tick interval (additive backoff)
2. Send `task.throttled` so the wapp can shed work voluntarily
3. Pause the task entirely (`task.paused`)
4. Kill the task (`task.killed`) — only `priority: low` tasks
   reach this step automatically; `normal` and `critical` need
   user confirmation

The user can also **manually pause non-critical work** through the
task monitor UI. `pauseAllNonCritical()` is the canonical hook —
it skips tasks with `priority: critical` and pauses everything
else, useful when battery is low or a user is recording video on
mobile.

### 8.4 Task monitor surface

The host exposes the task list as a `$type="tasks"` GeoUI group
that any wapp can render (typically a system-level "Tasks" wapp).
Engine duties for that group:

- List every task (across all loaded wapps + host services)
  grouped by `serviceName`
- Show status pill, last run, last duration, success/fail counts
- Per-row actions: Pause, Resume, Stop, Restart, View errors
- Bulk actions: Pause all non-critical, Resume all
- Cross-wapp event on every status change so the rendering UI
  updates live

Reference: iwi's tasks wapp + `_buildTasksScreen` in the
prototype renderer; the integrated host stubs the group for now
and will land the same renderer in a follow-up stage.

---

## 9. Connections

External transports are exposed as polling APIs because the WASM
side cannot block. The engine handles the real I/O and queues
results.

### 7.1 HTTP (`hal.http`)

```c
int32_t hal_http_request      (method, url, url_len, body, body_len);
int32_t hal_http_poll         (request_id);   // 0=pending 1=done -1=err
int32_t hal_http_read_response(request_id, buf, buf_len);
int32_t hal_http_status       (request_id);
void    hal_http_free         (request_id);
```

### 7.2 LoRa (`hal.lora`)

```c
int32_t  hal_lora_available_hw(void);
int32_t  hal_lora_send        (data, data_len);
uint32_t hal_lora_available   (void);
uint32_t hal_lora_recv        (buf, buf_len);
```

Stub on platforms without hardware — `hal_lora_available_hw`
returns `0`, all other calls return zero or `-1`.

### 7.3 Bluetooth LE (`hal.ble`)

```c
int32_t  hal_ble_scan_start    (void);
void     hal_ble_scan_stop     (void);
uint32_t hal_ble_scan_read     (buf, buf_len);
int32_t  hal_ble_advertise     (data, data_len);
void     hal_ble_advertise_stop(void);
```

### 7.4 Cross-module RPC (`hal.lib`)

```c
int32_t hal_lib_call(lib_id, lib_id_len, fn_name, fn_name_len,
                     args, args_len, result, result_len);
```

A synchronous, return-value-by-value variant of the functionality
broker. Used when a caller wants a strict request/response with
named arguments, not a fire-and-forget event.

---

## 10. Notifications

Wapps surface user-visible notifications by sending a `notify`
message to the host:

```json
{
  "type": "notify",
  "level": "info|success|warning|error",
  "title": "...",
  "body":  "...",
  "scope": "app|system|both",
  "tag":   "<optional dedup key>"
}
```

The engine must:
- Route to the host's notification service (in-app banner, system
  tray, OS toast — depending on `scope`)
- Tag every notification with the source wapp's name so the user
  can identify it
- De-duplicate by `tag` when present

---

## 11. Sensors and hardware

Read-only access to platform sensors. All return `INT32_MIN` when
the sensor isn't available so wapps can degrade gracefully.

```c
int32_t hal_sensor_temperature(void);   // centidegrees C
int32_t hal_sensor_humidity   (void);   // centipercent
int32_t hal_sensor_battery    (void);   // millivolts
int32_t hal_sensor_gps_lat    (void);   // latitude × 1e7
int32_t hal_sensor_gps_lon    (void);   // longitude × 1e7
```

GPIO and display APIs follow the same pattern (no-op stubs on
desktop, real on ESP32).

---

## 12. Time and platform

```c
uint64_t hal_time_ms   (void);   // monotonic ms since host start
uint64_t hal_time_epoch(void);   // unix seconds (0 if no RTC)
void     hal_yield     (void);   // cooperative multitasking
uint32_t hal_platform  (buf, buf_len);   // "esp32"|"linux-desktop"|...
uint32_t hal_heap_free (void);   // free heap bytes available to module
uint32_t hal_i18n_get  (key, key_len, out, out_cap);  // lang/<locale>.json
```

The engine must clamp `hal_time_ms` to the wapp's lifetime (not
absolute) so wapps that persist KV across runs see monotonic
behavior.

---

## 13. UI surface

GeoUI is the wapp's UI dialect — JSON files under `screens/` that
describe screens, fields, actions, and groups. The engine parses
them through a renderer (see `lib/geoui/`) that produces native
widgets. Wapps don't paint pixels; they declare structure and
react to messages.

Group `$type` values reserved for host-side rendering:

| `$type` | Host renderer |
|---|---|
| `map` | Tiled map (FlutterMap or equivalent) |
| `output` | Wapp store catalog list |
| `sources` | Wapp store repository manager |
| `projects` | App Creator project picker |
| `tasks` | Task monitor |
| `ui-editor` | App Creator visual UI editor |
| `translations` | App Creator translations editor |
| `functionalities` | Functionality registry browser |
| `log` | Append-only log view (also as a field type) |
| `code` | Code editor field |
| `icon` | Icon picker field |

The engine treats unknown types as opaque containers and renders
their children as standard fields/actions.

---

## 14. Identity and signing

The engine reads the active profile's NOSTR identity (`npub`,
`nsec`) from the host's profile service and uses it to:
- Sign every wapp the user installs (write a NIP-78 `kind:30078`
  event into `signature.json` next to the package)
- Authenticate `widget.request` calls when the target functionality
  requires it
- Stamp social entries (reactions, comments) inside the wapp's
  `social.sqlite3`

A wapp never sees the `nsec` directly. It can ask the host to sign
on its behalf via a future `sign.request` message (Stage 3).

---

## 15. Manifest contract

Every `.wapp` must contain a top-level `manifest.json`:

```json
{
  "id":              "tools.geogram.maps",
  "version":         "1.0.0",
  "kind":            "app|system|addon",
  "description":     "Short title",
  "summary":         "Long description",
  "icon":            "media/icons/<name>.svg",
  "entry_ui":        "screens/home.ui.json",
  "tick_interval_ms": 5000,
  "permissions":     ["network", "storage"],
  "provides": {
    "functionalities": [
      "text.greet",
      { "id": "tile_provider.osm",
        "endpoints": [{ "name": "..." }] }
    ]
  },
  "requires": {
    "hal":    ["log", "kv", "msg", "i18n_get"],
    "events": ["geo.position"],
    "libraries": []
  }
}
```

The engine must:
- Reject a wapp whose `requires.hal` contains capabilities the
  current platform can't satisfy
- Surface `requires.events` so the host knows what topics to
  pre-subscribe the wapp to
- Carry `permissions` through to the user-facing install dialog
  (Stage 3)

---

## 16. Package layout

```
my-wapp.wapp (zip)
├── manifest.json
├── app.wasm                   ← compiled WASM module
├── signature.json             ← optional NIP-78 NostrEvent
├── permissions.json           ← optional NDF access control
├── social.sqlite3             ← optional reactions+comments DB
├── screens/
│   └── home.ui.json
├── media/
│   └── icons/<name>.svg
├── lang/
│   ├── en.json
│   └── <locale>.json
└── store/
    ├── description.json       ← multi-lingual store metadata
    └── screenshots/           ← bundled images
```

`app.wasm` is mandatory; everything else is optional. The engine
must extract the package atomically — partial extracts must leave
no `manifest.json` so the launcher's idempotent install flow
treats the wapp as not yet installed.

---

## 17. Engine implementation checklist

A minimum-viable engine implementation must:

- [ ] Load and instantiate `app.wasm` with all HAL imports wired
- [ ] Run `module_init` and surface failures as `WappCrashedEvent`
- [ ] Maintain a per-wapp KV scoped to the active profile
- [ ] Drain `hal_msg_send` after every tick + handle_event call
- [ ] Dispatch reserved message types (notify, widget.request,
      wapp.fetch_index, wapp.install)
- [ ] Run a tick timer at `manifest.tick_interval_ms`
- [ ] Render screens via the GeoUI renderer
- [ ] Honour `requires.hal` at load time
- [ ] Fire `WappLoadedEvent` / `WappUnloadedEvent` on the host
      event bus

A full engine additionally provides the functionality broker, the
cross-wapp event bus, signing/verification, and the social store.
