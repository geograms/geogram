# geogram (iwi/) reusable components

Catalog of reusable libraries inside the geogram Flutter launcher (`iwi/`).
Each entry should describe what the component does, where it lives, and the
non-obvious constraints a future caller needs to know.

> The wider geogram repo has its own `../docs/reusable.md` covering the
> parent app's components. This file is scoped to `iwi/lib/` only.

---

## Storage

### ProfileStorage — filesystem abstraction

**Files:**
- `lib/services/profile_storage.dart` — `ProfileStorage` (abstract),
  `StorageEntry`, `FilesystemProfileStorage`, `ScopedProfileStorage`
- `lib/services/storage_paths.dart` — helpers that hand back ready-to-use
  storages: `geogramRootStorage()`, `installedAppsStorage()`,
  `wappsDataStorage(prefs)`, `wappDataStorageFor(prefs, wappId)`,
  `wappPackageStorage(absPath)`

**What it is.** Every filesystem operation in geogram (iwi) goes through
`ProfileStorage`. No `dart:io` `File` / `Directory` calls anywhere else in
`lib/` — that rule is enforced by code review and the analyser will catch
slips because the storage call sites do not import `dart:io`. The pillar
exists so that the backing store can be swapped for an encrypted SQLite
archive (encrypted profiles), a browser IndexedDB tree (web build), or a
plain filesystem (today's desktop) without touching call sites.

**API surface** (mirrors the parent repo's
`lib/services/profile_storage.dart` so a shared package can be extracted
later with a single import change):

- Async file ops: `readString`, `readBytes`, `writeString`, `writeBytes`,
  `appendString`, `exists`, `delete`, `copyFromExternal`, `copyToExternal`
- Async directory ops: `listDirectory`, `createDirectory`,
  `directoryExists`, `deleteDirectory`
- JSON convenience: `readJson`, `writeJson`
- **Sync variants for WASM HAL callbacks**: `readBytesSync`,
  `writeStringSync`, `writeBytesSync`, `existsSync`. These exist only
  because WASM imports run synchronously and Dart `Future`s cannot be
  awaited from inside them. `FilesystemProfileStorage` implements them
  with `dart:io` sync methods. **Non-sync backends** (encrypted SQLite,
  browser IndexedDB) **must throw** `UnsupportedError` for these — and
  callers must fall back to a message-based async API in that case.

**Storage layout under the user home:**

```
~/.local/share/geogram/
  apps/<wapp-id>/    extracted .wapp packages (installed wapps)
  wapps/<wapp-id>/   per-wapp runtime data (kv.json, future hal_file_*)
```

The previous "iwi" codename left data under `~/.local/share/iwi/`. There
is no auto-migration; copy manually if needed.

**How wapps use it.**

- `WappEngine.setStorage(ProfileStorage)` — call before `load()`. The
  engine persists KV via the storage's sync variants from inside HAL
  callbacks.
- `wappPackageStorage(wappDir)` — wrap any wapp package directory
  (built-in `wapps/archive/<name>/` or installed) and use it to read
  `manifest.json`, `app.wasm`, `screens/*.ui.json`, and `media/*`.
- `wappDataStorageFor(prefs, wappName)` — per-wapp scoped storage for
  KV + future `hal_file_*` writes.

**Open question — `hal_file_*` (currently stubbed in `wapp_engine.dart`).**
The HAL declares synchronous `hal_file_open/read/write/close`. On
`FilesystemProfileStorage` this could be implemented with the sync
variants, but that locks `hal_file_*` to native filesystem backends. The
alternative is to redesign `hal_file_*` to be async with polling
(matching `hal_http_*`), which works on every backend but requires
updating `wapps/hal/geogram_wasm_hal.h` and any wapp that touches files.
This decision is deferred until a real wapp needs file I/O on encrypted
or browser backends.

**Don't forget:**
- Use `ScopedProfileStorage(inner, 'subpath')` when a subsystem only
  needs a sub-tree — it auto-prefixes every operation and keeps call
  sites unaware of the absolute layout.
- For arbitrary external absolute paths (a user-typed source directory,
  for example) wrap the directory in a transient
  `FilesystemProfileStorage(absDir)` and use the basename as the
  relative path. Don't drop back to raw `File`.
- For tools like `unzip` that need a real on-disk path, use
  `storage.getAbsolutePath(rel)` to extract one — this works today
  because `installedAppsStorage()` is filesystem-backed. When an
  encrypted/IndexedDB backend lands the install flow will need to
  unzip into a temp dir then `copyFromExternal` each entry.

---

## Events

### EventBus — host-side type-safe broadcast bus

**File:** `lib/services/event_bus.dart`

**What it is.** Singleton broadcast channel for `AppEvent` subclasses.
Type-safe — `EventBus().on<MyEvent>(handler)` only fires for that
concrete type. Dispatch uses `event.runtimeType` so subclass events
route correctly even when fired via the base type. API mirrors parent
geogram's `lib/util/event_bus.dart`.

**Built-in events:**
- `AppStartedEvent` — fired once after launcher startup completes
  (after `_scanArchive` finishes). Background services that should run
  post-init subscribe to this.
- `WappLoadedEvent { wappId, wappName }` — wapp finished
  `module_init`.
- `WappUnloadedEvent { wappId, wappName }` — wapp page disposed.
- `WappCrashedEvent { wappId, phase, error }` — `phase` is `'load'`,
  `'init'`, `'tick'`, or `'handle_event'`.
- `WappEventBridgeEvent { fromEngineId, topic, data }` — bridged from
  the cross-wapp `WappEventBroker` so host observers can watch wapp
  pub/sub traffic.
- `ErrorEvent { source, message, error }` — generic error channel.
  `NotificationService` subscribes to this and auto-surfaces each
  `ErrorEvent` as an error-level notification.
- `NotificationShownEvent { notification }` — fired by
  `NotificationService.show` after a notification has been dispatched
  to backends. Use this to build a history / debug UI.

**Usage:**
```dart
final sub = EventBus().on<WappLoadedEvent>((e) {
  print('${e.wappName} loaded');
});
// ...later
sub.cancel();
```

Add new event types as subclasses of `AppEvent` directly in
`event_bus.dart` — keep them in one place so the catalogue is easy to
scan.

### WappEventBroker — cross-wapp pub/sub on top of `hal_event_*`

**File:** `lib/services/wapp_event_broker.dart`

**What it is.** Singleton router that backs the WASM HAL event
imports (`hal_event_subscribe`, `hal_event_unsubscribe`,
`hal_event_publish`, `hal_event_available`, `hal_event_recv`). Each
`WappEngine` registers itself with a stable `engineId` on
construction and unregisters on dispose; the broker holds
`{engineId → (subscribed topics, pending event queue)}`.

**Wire-up:** `WappEngine` constructor calls
`WappEventBroker.instance.registerEngine(engineId)`; the HAL function
imports in the engine's load() call into the broker. Already wired —
nothing for callers to do.

**Delivery model:**
- `publish(fromEngineId, topic, data)` fans out to every engine
  subscribed to the exact topic string (including the publisher
  itself if it subscribed). Each delivery appends a `_PendingEvent`
  to the recipient's queue.
- Wapps drain their own queue from inside `module_tick` /
  `module_handle_event` by polling `hal_event_available()` and then
  calling `hal_event_recv(topic_buf, topic_len, data_buf, data_len)`.
- The host can observe every published event by subscribing to
  `WappEventBridgeEvent` on the host `EventBus`.

**Backpressure:** each engine queue is capped at
`maxQueuePerEngine = 1024` events. When full, the **oldest** event is
dropped. Wapps that need lossless delivery must drain on every tick.

**Topic strings are exact-match.** No wildcards or hierarchy yet —
add later only if a real wapp needs it. Convention: dot-separated
namespacing (`chat.message.received`, `transfer.completed`).

**Don't forget:**
- Multiple wapp instances of the same wapp will get unique
  `engineId`s — the broker treats them independently. There is no
  per-wapp-name routing.
- The broker is **process-local**. Cross-process or cross-host event
  routing (mesh, BLE) is out of scope.

### HostEventBridge — host events → wapp topics

**File:** `lib/services/host_event_bridge.dart`

**What it is.** Subscribes to key host `AppEvent`s on `EventBus` and
republishes each one on `WappEventBroker` under a stable `system.*`
topic name. This is what lets wapps react to host-level events
(app started, wapp loaded, task failed, error fired) through the
normal `hal_event_subscribe` / `hal_event_recv` path — without this
bridge, host and wapp event namespaces would be fully isolated.

**Installed as a boot task.** `main.dart` registers
`HostEventBridge.instance.install()` as a `BootStart.parallel` task
on `BootOrchestrator`; once `runAll()` finishes the bridge is live.
Uninstall is only for tests.

**Bridged topics and payloads** (payloads are JSON strings):

| Topic                  | Fires when                              | Payload                                                             |
|------------------------|-----------------------------------------|---------------------------------------------------------------------|
| `system.app.started`   | launcher finishes boot (AppStartedEvent)| `{}`                                                                |
| `system.wapp.loaded`   | wapp finished `module_init`             | `{"wappId":"...","wappName":"..."}`                                 |
| `system.wapp.unloaded` | wapp page disposed                      | `{"wappId":"...","wappName":"..."}`                                 |
| `system.wapp.crashed`  | wapp threw during load/init/tick/event  | `{"wappId":"...","phase":"...","error":"..."}`                      |
| `system.error`         | `ErrorEvent` fired on host bus          | `{"source":"...","message":"..."}`                                  |

A wapp that wants to react to any of these calls
`hal_event_subscribe("system.wapp.loaded")` (or similar) and drains
events from `module_handle_event` / `module_tick` via
`hal_event_recv`. The `fromEngineId` on the bridged
`WappEventBridgeEvent` is always the literal string `"host"`.

**Working end-to-end example.** The **Tester** wapp
(`wapps/archive/tester/`) has an **Events** screen with buttons that
exercise every part of the pipeline:

- *Local pub/sub* — Subscribe `test.hello`, Publish `test.hello`,
  Unsubscribe `test.hello`, Full echo (subscribe + publish in one
  click).
- *Host triggers* — Subscribe `system.wapp.loaded` /
  `system.wapp.unloaded` / `system.error`. Open another wapp from
  the launcher after subscribing and a notification card pops out
  of the Tester wapp as the event arrives.

The Tester wapp drains its event queue in both `module_tick` (every
500 ms) and `module_handle_event` (so an `event-echo` click
produces a notification within one command round-trip). Each
received event is emitted as a `{"type":"notify",...}` message and
the host routes it through `NotificationService` → `NotificationLayer`
→ the stacking overlay. This is the simplest template for any new
wapp that wants to consume events.

**HAL subtlety — `hal_event_recv` null-terminates both buffers.**
Before writing to each destination buffer the host reserves one byte
for a `\0` terminator so that C wapps can `strlen()` the topic. The
return value is bytes written to the **data** buffer, not counting
the terminator — matching the `hal_msg_recv` convention. If you
call this from a non-C wapp that tracks lengths explicitly, just
ignore the terminator byte.

**One-way.** Wapp events do **not** get republished on the host
`EventBus` by this bridge. That direction is already covered by
`WappEventBroker.publish` firing `WappEventBridgeEvent` on every
publish — host observers can subscribe to that directly.

**Don't forget:**
- Adding a new bridged event = add a `_bridge<T>(...)` call inside
  `install()` AND a row in the table above. Schema changes to the
  JSON payload are breaking — bump the topic (e.g.
  `system.wapp.loaded.v2`) if a field needs to be renamed or
  removed.

---

## Notifications

### NotificationService — unified notification surface

**File:** `lib/services/notification_service.dart`

**What it is.** Singleton that every user-visible notification must
go through — from host services AND from wapps. Wraps multiple
`NotificationBackend` implementations and fans out each
`GeogramNotification` to the backends whose `handlesScope` matches.
Also subscribes to `ErrorEvent` on `EventBus` and auto-shows each
error as an error-level in-app notification.

**Backends shipped today:**
- `InAppNotificationBackend` — Flutter `ScaffoldMessenger` snackbars
  with level-coloured background + icon, 3s / 6s durations, floating.
  Driven by a `GlobalKey<ScaffoldMessengerState>` held in
  `main.dart:rootMessengerKey` and passed to `MaterialApp`, so the
  service can post snackbars without a `BuildContext`.
- `SystemTrayNotificationBackend` — `notify-send` on Linux (with
  urgency derived from level), `osascript` on macOS. Windows is
  intentionally not implemented yet — would need BurntToast which may
  not be present.

**Wapp wire protocol** (messages the wapp sends via `hal_msg_send`):

```
{"type":"notify",
 "level":"info|success|warning|error",
 "title":"...",
 "body":"...",
 "tag":"optional dedupe key",
 "scope":"app|system|both"}
```

`wapp_page.dart`'s `_drainOutbox` translates this into
`NotificationService.instance.show(GeogramNotification(...))` with
`source="wapp:<wappName>"`. The legacy `ui.toast` message shape is
also routed through the service so old wapps inherit system-tray
delivery + history for free.

**Host-side usage:**
```dart
NotificationService.instance.show(GeogramNotification(
  level: NotificationLevel.warning,
  title: 'Low memory',
  body: 'Pausing non-critical tasks',
  source: 'host:watchdog',
  scope: NotificationScope.both,
));
```

**Scope routing.** Each backend declares which scopes it handles
(`NotificationScope.app | system | both`). The service skips
backends whose `handlesScope` returns false. Default scope is `app`.

**History.** Rolling in-memory list capped at
`NotificationService.maxHistory = 200`. Reserved for a future
history / debug UI.

**Don't forget:**
- `NotificationService.init(messengerKey:)` must be called exactly
  once, before `runApp`. It is wired as a `BootStart.parallel` task
  in `main.dart`; don't duplicate.
- Backend exceptions are **swallowed** — one broken backend cannot
  starve the others. Failures do not fire another notification to
  avoid loops.
- Never call `ScaffoldMessenger.showSnackBar` directly from wapp
  code or from services; always go through `NotificationService` so
  the behaviour stays uniform.

---

## Tasks

### TaskMonitorService + MonitoredTask — process monitor

**Files:**
- `lib/models/monitored_task.dart` — `MonitoredTask`, `TaskStatus`,
  `TaskPriority`, `TaskType` enums, `TaskStateChangedEvent`
- `lib/services/task_monitor_service.dart` — `TaskMonitorService`
  singleton + `runMonitoredStartup` helper

**What it is.** Single registry of every background task in the
host. Solves the previous-implementation pain point of "threads
spawning everywhere with no visibility, no scheduling, no CPU
budget". Mirrors parent geogram's
`lib/services/task_monitor_service.dart` for future merge.

**Lifecycle:**
1. Owner constructs a `MonitoredTask` and calls
   `TaskMonitorService.instance.register(task)`.
2. Around each execution, owner calls `reportStart(id)`, then either
   `reportSuccess(id)` or `reportFailure(id, error)`. Wall-clock
   duration is added to `totalCpuMs` automatically.
3. Owner calls `unregister(id)` on disposal.

**Pause/resume.** `pause(id)` flips a non-critical task to
`TaskStatus.paused`; the periodic timer must check
`task.status == TaskStatus.paused` and skip its body. Critical tasks
refuse to pause. `pauseAllNonCritical()` / `resumeAll()` are the bulk
operations to hit on memory/thermal pressure.

**Wired today:**
- Every wapp's tick timer in `wapp_page.dart` registers a
  `wapp.<wappName>.<engineId>` task (`type=periodic`,
  `priority=normal`, `interval` from manifest), reports start/success/
  failure on every tick, and skips ticking when paused. Failures also
  fire `WappCrashedEvent` on `EventBus`.
- The launcher's `_scanArchive` is wrapped in `runMonitoredStartup`
  as `startup.launcher.scan` — example of the "template process
  method" pattern that every startup task should use.

**`runMonitoredStartup(id, name, init)` — the template.** Use this
helper for every one-shot startup step. It registers a
`startup.<id>` task, calls `reportStart`, runs `init`, records wall
time as `initWallMs`/`initCpuMs`, and reports success or failure.
Failures rethrow so the caller still sees them. Do **not** roll your
own try/catch around init steps — go through this helper so the
monitor sees every startup phase.

**Observing.** `TaskMonitorService.instance.tasks` returns the full
list. `stateChanges` is a `Stream<TaskStateChangedEvent>` for live UI
updates. `toJson()` produces a debug-API-friendly summary. Failures
also fire `ErrorEvent` on `EventBus`.

**Don't forget:**
- Always pair `register` with `unregister` — leaked tasks accumulate
  in the registry forever.
- `reportFailure` does **not** rethrow — the caller still has to
  decide what to do with the error.
- For `type=periodic` tasks, the `interval` field is metadata for
  the UI; the actual scheduling is done by whatever `Timer.periodic`
  the owner created. The monitor doesn't drive timers.
