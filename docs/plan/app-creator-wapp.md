# App Creator wapp — implementation plan

## Context

Today, authoring a geogram wapp requires an external toolchain
(`wasi-sdk`), a terminal, a text editor, and manual ZIP packaging. Users
who just want to write a tiny app must leave geogram entirely and learn
the build system.

The **App Creator** is a wapp whose purpose is to let a user write code,
hit compile, and have a new runnable wapp appear on the launcher grid —
without ever leaving geogram. It is the first step toward a full in-app
development experience; a visual/GUI editor will be layered on later.

### Decisions already taken

- **Default bundled compiler:** AssemblyScript (TypeScript subset,
  ~5 MB, genuinely runs-as-WASM and emits-WASM). Plain TCC compiled to
  WASM does *not* emit WASM bytecode — it still targets x86/ARM — so it
  was rejected as the default.
- **Optional downloadable compiler:** `wasm-clang` (full C/C++ via
  wasi-sdk), fetched on demand, verified by SHA256, stored under the
  profile.
- **Compiler runtime location:** host-side. The App Creator wapp itself
  stays a thin UI that talks to the host over `hal_msg_send` /
  `hal_msg_recv`. A fresh `wasm_run_flutter` instance (separate from
  `WappEngine`) is what actually runs the compiler.
- **Code editor delivery:** a new GeoUI field type (`$type: "code"`)
  rendered by the host. The wapp stays pure WASM.

### Out of scope (follow-ups)

- GUI (drag-and-drop) editor — explicitly deferred.
- C/wasm-clang as default — remains an optional download until someone
  ships a sub-20 MB clang-for-wasm build.
- Multi-file projects, library wapps, build-time asset inclusion.
- Running a compiled wapp inside App Creator without installing first
  ("Run" / preview mode).
- Remote publish / share of user-created wapps.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│ App Creator wapp  (pure wasm, ~small)                        │
│   main.c:                                                     │
│     - reads code-field edits from host messages              │
│     - on "compile"  action → hal_msg_send {command:"compile"}│
│     - on "install"  action → hal_msg_send {command:"install"}│
│     - on "download" action → {command:"compiler.fetch"}      │
│   screens/home.ui.json:                                       │
│     - compiler selector (enum)                                │
│     - $type:"code" editor field (NEW)                         │
│     - Compile / Install / Download extension actions          │
│     - error/output group ($type:"log", NEW)                   │
└──────────────────────────────────────────────────────────────┘
                          ▲            │ hal_msg_send
                          │            ▼
┌──────────────────────────────────────────────────────────────┐
│ Host (Flutter, iwi/)                                          │
│                                                               │
│  GeoUI renderer (extended):                                   │
│    - new $type: "code" → CodeEditorField (syntax highlight)   │
│    - new $type: "log"  → scrollable monospace log view        │
│                                                               │
│  WappPage._drainOutbox (extended) intercepts:                 │
│    command:"compile"         → WappCompilerService.compile()  │
│    command:"install"         → WappInstallerService.install() │
│    command:"compiler.fetch"  → CompilerRegistry.download()    │
│                                                               │
│  Services (NEW):                                              │
│    WappCompilerService                                        │
│      - loads compiler.wasm in its OWN wasm_run_flutter        │
│        instance (separate from WappEngine)                    │
│      - feeds source via stdin/args, captures stdout+result    │
│      - returns Uint8List of compiled app.wasm                 │
│    CompilerRegistry                                            │
│      - known compilers: default AssemblyScript (bundled       │
│        asset), optional wasm-clang (downloaded)               │
│      - tracks installed compilers in ProfileStorage           │
│        (compilers/<id>/compiler.wasm + meta.json)             │
│      - download via streamDownloadToFile (SHA256 verified)    │
│    WappInstallerService                                       │
│      - given (id, version, manifest fields, wasmBytes)        │
│        writes a full wapp tree under installedAppsStorage()   │
│      - fires WappLoadedEvent so launcher rescan picks it up   │
└──────────────────────────────────────────────────────────────┘
```

**Key design point.** App Creator stays a regular wapp. All new
capability is added at the host layer (GeoUI widgets + three services)
and as new command messages. No HAL changes. No WASM-in-WASM.

---

## Files to Create / Modify

### Wapp package (new)

- `wapps/archive/app-creator/manifest.json` — id
  `tools.geogram.app-creator`, kind `app`, tick 500 ms, entry
  `screens/home.ui.json`, requires HAL `msg`, `kv`, `log`.
- `wapps/archive/app-creator/Makefile` — includes `sdk/Makefile.common`.
- `wapps/archive/app-creator/main.c` — tiny C stub that:
  - reads code-field changes from host messages,
  - on action `compile` forwards
    `{command:"compile","source":"...","compiler":"..."}`,
  - on action `install` forwards
    `{command:"install","name":"...",...}`,
  - on action `download` forwards
    `{command:"compiler.fetch","id":"wasm-clang"}`,
  - surfaces host responses into the `$type:"log"` group via
    `{type:"ui.log.append","line":"..."}`.
- `wapps/archive/app-creator/screens/home.ui.json` — GeoUI screen with:
  - `field` `compiler` (`$type:"enum"`, options populated from host via
    `{type:"compiler.list"}` at `module_init`),
  - `field` `wapp_id`, `field` `wapp_name`, `field` `wapp_description`,
  - `field` `source` with new `$type:"code"`,
    `language:"assemblyscript"`,
  - `action compile`, `action install` (disabled until compile
    succeeds), `action download_clang`,
  - `group $type:"log"` named `output`.
- `wapps/archive/app-creator/media/icons/app-creator.svg` — simple icon.

### Host-side services (new, in `iwi/lib/services/`)

- `wapp_compiler_service.dart` — `WappCompilerService`:
  - `Future<CompileResult> compile({required CompilerSpec compiler,
    required String source, required String sourceFilename})`,
  - loads `compiler.wasm` via `wasm_run_flutter` in a standalone module
    (not `WappEngine`; keeps the HAL import surface clean),
  - wires minimal WASI imports (`fd_write` → buffer, `fd_read` → fed
    source, `args_get` → compiler CLI flags, `proc_exit` → terminates),
  - returns `(Uint8List? wasmBytes, String stdout, String stderr,
    int exitCode)` wrapped in `CompileResult`,
  - registers the compile run as a `MonitoredTask` via
    `TaskMonitorService`, so it shows up in the tasks wapp.
- `compiler_registry.dart` — `CompilerRegistry` (singleton):
  - `List<CompilerSpec> listInstalled()`,
    `List<CompilerSpec> listAvailable()`,
    `Future<void> downloadAndInstall(String id,
    {void Function(double)? onProgress})`,
    `Future<Uint8List> loadCompilerBytes(String id)`,
  - stores compilers under a `compilers/<id>/` folder inside
    `geogramRootStorage()` (via `ScopedProfileStorage`),
  - meta.json per compiler:
    `{id, name, version, sizeBytes, sha256, sourceUrl, language,
    installed}`,
  - default AssemblyScript shipped as a Flutter asset
    (`iwi/assets/compilers/assemblyscript.wasm`); on first launch, if
    the entry under `compilers/assemblyscript/` is missing, extract from
    `rootBundle` into ProfileStorage,
  - downloads use `streamDownloadToFile`
    (`geogram/lib/util/managed_http_client.dart`) with SHA256
    verification and the `ManagedHttpClient` circuit breaker.
- `wapp_installer_service.dart` — `WappInstallerService`:
  - `Future<String> installFromCompiled({required String id,
    required String version, required String name,
    required String description, required Uint8List wasmBytes,
    Map<String,dynamic>? manifestExtras, String? homeScreenJson})`,
  - writes a directory under `installedAppsStorage()` (`apps/<id>/`)
    containing `manifest.json`, `app.wasm`, and a default
    `screens/home.ui.json` if none supplied,
  - publishes a rescan trigger via `EventBus` (`WappLoadedEvent`, or a
    new `WappInstalledEvent`), so `main.dart` `_scanArchiveBody` picks
    it up on next frame,
  - rejects collisions with existing wapps unless an `overwrite` flag
    is passed.

### GeoUI renderer extensions (new + modify)

- `iwi/lib/geoui/widgets/code_editor_field.dart` — `CodeEditorField`:
  - wraps a `TextField` whose controller is a port of
    `SyntaxHighlightController` from
    `geogram/lib/widgets/syntax_highlight_controller.dart` into
    `iwi/lib/widgets/syntax_highlight_controller.dart`,
  - accepts a `language` string
    (`"assemblyscript"`, `"c"`, `"dart"`, …),
  - left-side gutter with line numbers (simple custom painter, no new
    dependency).
- `iwi/lib/geoui/widgets/log_view_field.dart` — `LogViewField`:
  - scrollable, monospace, append-only; consumes lines pushed in via
    `{type:"ui.log.append"}` messages, stored as a `List<String>` in
    bindings.
- `iwi/lib/geoui/geoui_renderer.dart` — extend the switch at
  `_renderFieldWidget` (around line 201) to recognise `code` and `log`
  field types and dispatch to the new widgets.

### Wapp engine / page hookups (modify)

- `iwi/lib/wapp/wapp_page.dart` — `_drainOutbox` (or equivalent) gains
  three new branches:
  - `command == "compile"` → `WappCompilerService.compile(...)`; on
    success, store the result bytes in wapp KV under
    `last_compiled.wasm` and echo `{type:"compile.result", ok:true,
    size:N}` to the wapp inbox; on failure echo the error.
  - `command == "install"` → read `last_compiled.wasm`, call
    `WappInstallerService.installFromCompiled(...)`, echo
    `{type:"install.result", ok:true, id:"..."}`.
  - `command == "compiler.fetch"` →
    `CompilerRegistry.downloadAndInstall` with progress streamed as
    periodic `{type:"ui.log.append"}` messages.

### Assets / packaging (modify)

- `iwi/assets/compilers/assemblyscript.wasm` — the bundled default
  compiler binary (real binary committed, matching the existing
  convention of committing `app.wasm` files for archive wapps).
- `iwi/pubspec.yaml` — add:
  - `highlighting` and `flutter_highlighting` (match versions already
    used in the parent `geogram/pubspec.yaml`),
  - `assets:` entry for `assets/compilers/`.

---

## Reused Components (do not re-implement)

- **`wasm_run_flutter`** — already in `iwi/pubspec.yaml`; reuse for the
  compiler runtime inside `WappCompilerService`. Do *not* reuse
  `WappEngine` for compilation — its HAL surface is specific to wapps,
  not to compilers.
- **`ProfileStorage` / `storage_paths.dart`** — use
  `geogramRootStorage()` + `ScopedProfileStorage('compilers/')` for
  compiler binaries and `installedAppsStorage()` for installed wapps.
  Never touch `dart:io` directly.
- **`streamDownloadToFile` / `ManagedHttpClient`** —
  `geogram/lib/util/managed_http_client.dart`. If `iwi/` does not yet
  depend on the parent, port the minimal pieces into
  `iwi/lib/util/managed_http_client.dart` and document the reuse target
  in `iwi/docs/reusable.md`.
- **`TaskMonitorService`** — compile runs and downloads register as
  monitored tasks, so they pause with the rest of the system and show
  up in the existing tasks wapp.
- **`NotificationService`** — surface compile-success / install-success
  as `{type:"notify"}` messages from the wapp (already wired through
  `WappPage`).
- **`EventBus` + `WappLoadedEvent`** — reuse for the launcher rescan
  signal on install.
- **`SyntaxHighlightController`** — port from
  `geogram/lib/widgets/syntax_highlight_controller.dart` into
  `iwi/lib/widgets/`. The `highlighting` package already supports both
  C and TypeScript/AssemblyScript, so the port is a straight copy.
- **GeoUI field-type switch** at
  `iwi/lib/geoui/geoui_renderer.dart:201` — extend, do not replace.
- **Existing wapp skeleton** — copy `wapps/archive/tester/` or
  `wapps/archive/tasks/` as a starting template for `app-creator/`;
  they already show the `hal_msg_send` / `hal_msg_recv` pattern.

---

## Implementation Steps (ordered)

1. **Port `SyntaxHighlightController` into `iwi/`** and add
   `highlighting` + `flutter_highlighting` to `iwi/pubspec.yaml`.
   Smoke-test by rendering a code snippet in a scratch page.
2. **Add `CodeEditorField` and `LogViewField`** under
   `iwi/lib/geoui/widgets/`.
3. **Extend `geoui_renderer.dart` `_renderFieldWidget`** to dispatch
   `code` → `CodeEditorField`, `log` → `LogViewField`.
4. **Create `CompilerRegistry`** with AssemblyScript as the only
   bundled compiler. Implement first-run extraction from Flutter assets
   into `compilers/assemblyscript/`.
5. **Create `WappCompilerService`** with a tiny standalone WASI host.
   Test in isolation by feeding a known-good source string and
   asserting a non-empty WASM byte output.
6. **Create `WappInstallerService`** and wire the `WappLoadedEvent`
   rescan.
7. **Hook `WappPage._drainOutbox`** to dispatch `compile`, `install`,
   `compiler.fetch` commands to the three services.
8. **Build the `app-creator` wapp** (manifest, main.c, home.ui.json,
   icon). Keep `main.c` minimal — it is just message plumbing plus a
   compiler dropdown.
9. **Add the wapp to `build-archive.sh`** (if the build script
   enumerates archives) and compile it with the existing `wasi-sdk`
   toolchain; commit the resulting `app.wasm` alongside the source.
10. **Document new reusables** in `iwi/docs/reusable.md`:
    `WappCompilerService`, `CompilerRegistry`, `WappInstallerService`,
    `CodeEditorField`, `LogViewField`, the new GeoUI `code` / `log`
    field types, and the compiler-registry storage layout.
11. **Manual end-to-end test** (see Verification).
12. **Record follow-ups**: wasm-clang download source URL + SHA256,
    GUI editor, test/debug console, template picker.

---

## Verification

End-to-end manual test (run from the project root, per `CLAUDE.md`):

1. `./launch-desktop.sh` — launches desktop client.
2. On the launcher grid, confirm **App Creator** icon appears.
3. Open App Creator. Confirm:
   - compiler dropdown shows `assemblyscript (bundled)`,
   - the source field renders a syntax-highlighted code editor with
     line numbers,
   - a default "hello world" snippet is pre-loaded.
4. Click **Compile**. Confirm:
   - log view shows compiler stdout,
   - a green "compiled N bytes" toast fires via
     `NotificationService`,
   - the tasks wapp lists a transient `wapp.compile` monitored task.
5. Fill in `id`, `name`, `description`. Click **Install**. Confirm:
   - success notification fires,
   - return to launcher → the new wapp appears on the grid,
   - opening it runs the compiled code (log lines from `hal_log` show
     up in the host logs).
6. Click **Download wasm-clang**. Once a URL is wired, confirm:
   - progress streams into the log view,
   - SHA256 mismatch is handled cleanly (simulate by pointing to a
     wrong URL),
   - after install, the compiler dropdown now shows `wasm-clang`
     without restart.
7. Re-launch the client. Confirm the installed compiler and the
   installed user wapp both persist.
8. Sanity: uninstall the created wapp via the existing install-wapp
   UI; confirm App Creator itself is untouched.

If a "trigger a compile run" debug endpoint would speed up future
regression testing, add one under `docs/API.md` following the existing
conventions.
