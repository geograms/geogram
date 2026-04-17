import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

import '../platform/platform.dart' as platform;

import '../geoui/geoui_ast.dart';
import '../geoui/geoui_parser.dart';
import '../geoui/geoui_renderer.dart';
import '../geoui/widgets/code_editor_field.dart';
import '../models/iwi_profile.dart';
import '../models/monitored_task.dart';
import '../services/event_bus.dart';
import '../services/notification_service.dart';
import '../services/preferences_service.dart';
import '../services/profile_service.dart';
import '../services/profile_storage.dart';
import '../services/storage_paths.dart';
import '../services/i18n_context.dart';
import '../services/task_monitor_service.dart';
import '../services/wapp_compiler_service.dart';
import '../services/wapp_installer_service.dart';
import '../services/wapp_signing_service.dart';
import '../services/wapp_social_store.dart';
import '../main.dart' show WappManifest;
import '../services/functionality_broker.dart';
import '../services/functionality_registry.dart';
import '../util/wapp_icons.dart';
import 'wapp_engine.dart';

/// Generic wapp page — loads .ui.json screens from a wapp directory,
/// instantiates the WASM module, and renders screens as tabs.
/// Handles terminal output, settings forms, and map viewports.
class WappPage extends StatefulWidget {
  final String wappDir;
  final String title;

  const WappPage({super.key, required this.wappDir, required this.title});

  @override
  State<WappPage> createState() => _WappPageState();
}

class _WappPageState extends State<WappPage> with TickerProviderStateMixin {
  final _engine = WappEngine();
  Timer? _tickTimer;
  String _status = 'Loading...';

  /// Wapp folder name — used as a stable id for storage, task monitor,
  /// and lifecycle events. The basePath is a filesystem directory on
  /// desktop (`…/wapps/archive/app-creator`) and an HTTP URL on web
  /// (`/wapps/app-creator.wapp`). Both splits go through forward
  /// slashes because URLs use `/` regardless of the host platform's
  /// native separator; after the split we strip any trailing `.wapp`
  /// extension so `_isAppCreator` / matches by wapp name stay
  /// identical on desktop and in the browser.
  late final String _wappName = _deriveWappName(_pkg.basePath);

  static String _deriveWappName(String basePath) {
    final normalized = basePath.replaceAll('\\', '/');
    var last = normalized.split('/').last;
    if (last.toLowerCase().endsWith('.wapp')) {
      last = last.substring(0, last.length - 5);
    }
    return last;
  }

  /// Compound id for the per-wapp tick task in [TaskMonitorService].
  late final String _tickTaskId = 'wapp.$_wappName.${_engine.engineId}';

  /// Storage rooted at the wapp package dir (read-only source of manifest,
  /// app.wasm, screens, media).
  late final ProfileStorage _pkg = wappPackageStorage(widget.wappDir);

  /// Storage for installed wapps (extracted .wapp packages) — used by the
  /// install/uninstall flow.
  final ProfileStorage _installed = installedAppsStorage();

  /// Per-wapp work folder storage, set up by `_loadWapp`. Holds the
  /// wapp's KV, its draft projects, and any host-service scratch data
  /// (e.g. App Creator's compile-tmp/ and last_compiled.wasm).
  ProfileStorage? _wappData;

  // Screens parsed from .ui.json
  final _screens = <GeoUiBlock>[];
  final _screenNames = <String>[];
  TabController? _tabController;

  /// True when this wapp is the App Creator. Drives a navigation split
  /// where the initial view is just the Projects panel (no tabs) and
  /// the Code / UI / Settings tabs are only revealed after the user
  /// picks or creates a project.
  bool get _isAppCreator => _wappName == 'app-creator';

  /// Editor-mode flag for App Creator. False = show Projects panel
  /// only; true = show Code/UI/Settings tabs with a back arrow.
  bool _editorMode = false;

  /// TabController for the App Creator editor (Code/UI/Settings).
  /// Created lazily the first time the user enters editor mode so we
  /// don't allocate a controller for the Projects-only view.
  TabController? _editorTabController;

  // Terminal output
  final _outputLines = <_OutputLine>[];
  final _cmdController = TextEditingController();
  final _tickIntervalController = TextEditingController(text: '5000');
  final _scrollController = ScrollController();

  // Wapp Store (install wapp) — search query for filtering cards.
  // Empty string means "show everything".
  String _storeSearch = '';

  // ── App Creator UI editor state ────────────────────────────────
  //
  // The UI tab can either render the raw JSON in a code field
  // ([_uiEditorMode = code]) or walk the parsed block tree and
  // let the user click-to-edit each node in a side panel
  // ([_uiEditorMode = visual]). The visual path operates on a
  // mutable `dynamic` copy of the JSON that is re-serialised back
  // into `_fieldValues['source_ui']` on every mutation so Install
  // always picks up the latest edit.
  _UiEditorMode _uiEditorMode = _UiEditorMode.visual;

  /// Which top-level screen the visual editor is currently showing.
  /// Matches index into the top-level JSON array when `source_ui` is
  /// a list of screens; clamped to a safe value every render.
  int _uiActiveScreenIndex = 0;

  /// Path to the currently-selected block, expressed as a list of
  /// child indices. `[]` means "the screen itself is selected";
  /// `[2]` means "children[2]"; `[2, 0]` means "children[2].children[0]".
  /// Null means nothing is selected.
  List<int>? _uiSelectedPath;

  /// Currently-editing locale on App Creator's Translations tab. The
  /// key-value map for this locale is what the form actually edits;
  /// the inspector pulls straight from
  /// `_fieldValues['translations'][locale]`. Null when no locale is
  /// selected (also when the wapp doesn't have any lang/*.json yet).
  String? _translationsLocale;

  // Structured mirror of the install wapp's sources list, pushed by
  // the wapp on init / after save via {"type":"store.sources"}.
  // Drives the sources manager UI on the Settings tab. Starts as an
  // empty list until the wapp has confirmed its state — _sourcesLoaded
  // flips true the first time a store.sources message arrives so the
  // UI can distinguish "no sources yet" from "still booting".
  List<String> _storeSources = const [];
  bool _sourcesLoaded = false;

  // New-source input state for the sources manager. _sourcesInput
  // is the live text in the URL field; _sourcesError holds the most
  // recent validation failure (cleared on successful Add or edit);
  // _sourcesBusy gates the UI during the async HTTP probe.
  final _sourcesInputController = TextEditingController();
  String _sourcesError = '';
  bool _sourcesBusy = false;

  // Settings bindings
  final _fieldValues = <String, dynamic>{};

  /// Per-wapp translation context. Loaded from `lang/<locale>.json`
  /// inside the wapp package on mount and refreshed whenever the
  /// user switches language via [LocaleChangedEvent]. Passed to
  /// every [GeoUiScreenRenderer] so `@key` sentinels resolve to the
  /// user's preferred locale. Empty until `_loadWapp` populates it.
  I18nContext _i18n = I18nContext.empty();

  /// Subscription to [LocaleChangedEvent] so the open wapp rebuilds
  /// its translations live on locale change. Cancelled in [dispose].
  EventSubscription<LocaleChangedEvent>? _localeSub;

  // Map state
  double _mapLat = 0, _mapLon = 0;
  int _mapZoom = 2;
  String _tileUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
  bool _hasMap = false;

  // Cached MonitoredTask snapshot (refreshed when the wapp polls
  // system.tasks.list — see _refreshTaskSnapshot).
  List<MonitoredTask> _taskSnapshot = const [];

  void _refreshTaskSnapshot() {
    _taskSnapshot = TaskMonitorService.instance.tasks;
  }

  /// Return the `List<String>` backing a `$type:"log"` field, creating
  /// it if it does not yet exist. Used by host-side handlers (compile
  /// stub, install stub, ui.log.append) that need to push lines into
  /// a log field without caring whether the renderer has seeded it.
  List<String> _resolveLogBuffer(String fieldName) {
    final existing = _fieldValues[fieldName];
    if (existing is List<String>) return existing;
    final fresh = <String>[];
    _fieldValues[fieldName] = fresh;
    return fresh;
  }

  /// Push a log line into the `output` log field and mark the UI
  /// dirty. Used by the compile/install handlers so their progress
  /// shows up in the App Creator log view without round-tripping
  /// through the wapp.
  void _logLine(String line) {
    _resolveLogBuffer('output').add(line);
    if (mounted) setState(() {});
  }

  /// Append every non-empty line of [blob] individually so multi-line
  /// compiler output renders as separate log entries (easier to read,
  /// works with auto-scroll).
  void _logMultiline(String blob) {
    if (blob.isEmpty) return;
    final buf = _resolveLogBuffer('output');
    for (final line in const LineSplitter().convert(blob)) {
      if (line.isEmpty) continue;
      buf.add(line);
    }
    if (mounted) setState(() {});
  }

  /// App Creator compile pipeline. Called from `_drainOutbox` when
  /// the wapp emits a `{"type":"compile","source":"..."}` message.
  /// Runs the current compiler backend and caches the result in the
  /// wapp's work folder under `last_compiled.wasm`.
  Future<void> _handleCompile(Map<String, dynamic> data) async {
    final wappData = _wappData;
    if (wappData == null) {
      _logLine('(compile) internal error: wapp data storage not ready');
      return;
    }
    final source = data['source'] as String? ?? '';
    if (source.isEmpty) {
      _logLine('(compile) empty source — nothing to build');
      return;
    }

    _logLine('── compile started (${source.length} chars) ──');
    final result = await WappCompilerService.instance.compile(
      source: source,
      pkg: _pkg,
      workStorage: wappData,
    );

    if (result.stdout.isNotEmpty) _logMultiline(result.stdout);
    if (result.stderr.isNotEmpty) _logMultiline(result.stderr);

    if (!result.ok) {
      _logLine('compile failed: ${result.error}');
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Compile failed',
        body: result.error ?? 'see log view for details',
        source: 'host:app-creator',
      ));
      return;
    }

    final bytes = result.wasmBytes!;
    await wappData.writeBytes('last_compiled.wasm', bytes);
    // A fresh compile supersedes any bytes loaded from disk.
    _loadedWasmBytes = null;
    _logLine(
        'compile ok: ${bytes.length} bytes in ${result.durationMs}ms');
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.success,
      title: 'Compile succeeded',
      body:
          '${bytes.length} bytes, ${result.durationMs}ms via ${WappCompilerService.instance.backend.name}',
      source: 'host:app-creator',
    ));
  }

  /// App Creator install pipeline. Called from `_drainOutbox` when
  /// the wapp emits a `{"type":"install","id":...,"title":...,
  /// "name":...,"description":...,"source_ui":...}` message.
  ///
  /// Two modes:
  ///
  /// 1. **Fresh compile**: `last_compiled.wasm` exists in the wapp
  ///    work folder. The installer writes a new wapp with those
  ///    bytes, then the cache is deleted so the next install reverts
  ///    to edit-in-place unless the user recompiles.
  /// 2. **Edit in place**: no `last_compiled.wasm`. The installer
  ///    reuses whatever `app.wasm` is already at `apps/<folderName>/`
  ///    — this is the "change title, change UI, keep the wasm" path.
  ///    Fails cleanly if neither a fresh compile nor an existing
  ///    install is available.
  Future<void> _handleInstall(Map<String, dynamic> data) async {
    final wappData = _wappData;
    if (wappData == null) {
      _logLine('(install) internal error: wapp data storage not ready');
      return;
    }
    final id = data['id'] as String? ?? '';
    final title = data['title'] as String? ?? '';
    final folderName = data['name'] as String? ?? '';
    final description = data['description'] as String? ?? '';
    final sourceUi = data['source_ui'] as String? ?? '';
    if (id.isEmpty) {
      _logLine('(install) empty id — fill the Settings tab first');
      return;
    }
    if (folderName.isEmpty) {
      _logLine('(install) empty name — fill the Settings tab first');
      return;
    }

    // Pick the wasm bytes to install. Priority order:
    //  1. A fresh compile (last_compiled.wasm written by _handleCompile)
    //  2. Bytes loaded by _loadProject when the user picked a project
    //     from the Projects tab (this is the "fork a built-in" path)
    //  3. Existing installed-apps app.wasm (pure metadata / UI edit
    //     on an already-installed user wapp)
    //  4. Nothing — installer returns a clean error.
    Uint8List? freshBytes = await wappData.readBytes('last_compiled.wasm');
    String mode;
    if (freshBytes != null && freshBytes.isNotEmpty) {
      mode = 'fresh compile';
    } else if (_loadedWasmBytes != null && _loadedWasmBytes!.isNotEmpty) {
      freshBytes = _loadedWasmBytes;
      mode = 'loaded wasm (forking into user install)';
    } else {
      mode = 'edit in place';
    }
    _logLine('── install started: $id ($mode) ──');

    // Preserve the C source alongside the binary so a subsequent
    // Edit → load can populate the Code tab with the original text.
    // For edit-in-place installs that never touched the source, the
    // installer carries the existing main.c forward automatically.
    final sourceC = (_fieldValues['source'] as String?) ?? '';
    final icon = (_fieldValues['wapp_icon'] as String?) ?? '';
    // Translations come from the App Creator Translations tab as a
    // `Map<String, Map<String, String>>` (locale → key → value).
    // Pass null when empty so the installer's edit-in-place path
    // doesn't strip a previously-written lang/ dir.
    final translationsRaw = _fieldValues['translations'];
    final translations = _coerceTranslations(translationsRaw);

    final version =
        (_fieldValues['wapp_version'] as String?) ?? '1.0.0';
    final tickInterval =
        int.tryParse((_fieldValues['wapp_tick_interval'] as String?) ?? '') ??
            5000;
    final halRaw = _fieldValues['wapp_hal_requires'];
    final halRequires = halRaw is List<String>
        ? halRaw
        : _splitCsv(halRaw is String ? halRaw : 'log');
    final provRaw = _fieldValues['wapp_provides_functionalities'];
    final providesWidgets = provRaw is List<String>
        ? provRaw
        : _splitCsv(provRaw is String ? provRaw : '');

    final result = await WappInstallerService.instance.installFromCompiled(
      id: id,
      title: title,
      folderName: folderName,
      description: description,
      version: version,
      kind: (_fieldValues['wapp_kind'] as String?) ?? 'app',
      tickIntervalMs: tickInterval,
      halRequires: halRequires,
      providesWidgets: providesWidgets,
      wasmBytes: freshBytes,
      homeScreenJson: sourceUi.isEmpty ? null : sourceUi,
      sourceC: sourceC.isEmpty ? null : sourceC,
      icon: icon.isEmpty ? null : icon,
      translations: translations,
      overwrite: true,
    );
    if (!result.ok) {
      _logLine('install failed: ${result.error}');
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Install failed',
        body: result.error ?? 'see log view',
        source: 'host:app-creator',
      ));
      return;
    }

    // Consume the fresh compile cache so a subsequent install
    // without a recompile takes the edit-in-place path.
    try {
      await wappData.delete('last_compiled.wasm');
    } catch (_) {}
    // And drop any bytes loaded from a Projects-tab pick — the
    // installer has written them out; further installs should read
    // from the (now-existing) installedAppsStorage copy.
    _loadedWasmBytes = null;

    _logLine('install ok: $id');
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.success,
      title: 'Installed',
      body: (title.isNotEmpty ? title : folderName) +
          ' — back to the launcher to see it on the grid.',
      source: 'host:app-creator',
    ));
    // Refresh the Projects tab so a freshly installed wapp shows up
    // immediately if the user switches back to it.
    unawaited(_refreshProjects());
  }

  /// Load a wapp into the App Creator editor — called from the
  /// Projects tab Edit button with a `_ProjectEntry` that tells us
  /// the dir path to read from (works for both user installs under
  /// `installedAppsStorage()` and built-ins under `wapps/archive/`).
  ///
  /// Reads manifest + home.ui.json + app.wasm + main.c from the
  /// entry's dirPath. The wasm bytes land in [_loadedWasmBytes] so
  /// the subsequent install — even without a fresh compile — has
  /// bytes to write. For built-ins this effectively forks the
  /// source-tree wapp into `installedAppsStorage()` on the next
  /// install.
  ///
  /// Original C source is loaded when the wapp ships it. Built-in
  /// wapps always have `main.c` next to `app.wasm` in
  /// `wapps/archive/<name>/`. User installs only have it when they
  /// were created by App Creator after the source-preservation
  /// change landed — older installs have no `main.c` and the Code
  /// tab stays empty with a log-line hint.
  Future<void> _loadProject(_ProjectEntry entry) async {
    final pkg = wappPackageStorage(entry.dirPath);
    final manifest = await pkg.readJson('manifest.json');
    if (manifest == null) {
      _logLine('(load) missing or invalid manifest.json at ${entry.dirPath}');
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Load failed',
        body: 'manifest.json not found at ${entry.dirPath}',
        source: 'host:app-creator',
      ));
      return;
    }
    final id = manifest['id'] as String? ?? '';
    final title = manifest['description'] as String? ?? '';
    final description = manifest['summary'] as String? ?? '';
    // Normalise manifest.icon into the shape the IconField binding
    // expects (see widgets/icon_field.dart):
    //   - empty                → empty binding
    //   - short text / emoji   → binding verbatim
    //   - path to a .svg file  → read the file and prefix with
    //                            `svg:` so the editor shows a
    //                            preview and a subsequent Install
    //                            round-trips the bytes cleanly
    //   - any other path       → skip (we can't render non-svg
    //                            image formats yet)
    final rawIcon = manifest['icon'] as String? ?? '';
    String iconForField = '';
    if (rawIcon.isNotEmpty) {
      if (rawIcon.endsWith('.svg') &&
          (rawIcon.contains('/') || rawIcon.contains('\\'))) {
        final svgContent = await pkg.readString(rawIcon) ?? '';
        if (svgContent.isNotEmpty) {
          iconForField = 'svg:$svgContent';
        }
      } else if (!rawIcon.contains('/') && !rawIcon.contains('\\')) {
        iconForField = rawIcon;
      }
    }
    final uiJson =
        await pkg.readString('screens/home.ui.json') ?? '';
    final wasm = await pkg.readBytes('app.wasm');
    final sourceC = await pkg.readString('main.c') ?? '';

    // Load every lang/*.json sidecar so the Translations tab opens
    // pre-populated. Keys are locale codes (without extension),
    // values are flat string→string maps.
    final translations = <String, Map<String, String>>{};
    if (await pkg.directoryExists('lang')) {
      final langEntries = await pkg.listDirectory('lang');
      for (final langEntry in langEntries) {
        if (langEntry.isDirectory) continue;
        final path = langEntry.path;
        if (!path.endsWith('.json')) continue;
        final base = path.split('/').last;
        final code = base.substring(0, base.length - 5);
        final asJson = await pkg.readJson('lang/$base');
        if (asJson == null) continue;
        final inner = <String, String>{};
        for (final e in asJson.entries) {
          if (e.value is String) inner[e.key] = e.value as String;
        }
        translations[code] = inner;
      }
    }

    // Mutate the bindings map in place. A subsequent setState lets
    // CodeEditorField / TextField widgets pick up the new values
    // via their didUpdateWidget paths.
    _fieldValues['wapp_title'] = title;
    _fieldValues['wapp_id'] = id;
    _fieldValues['wapp_description'] = description;
    _fieldValues['wapp_name'] = entry.folder;
    _fieldValues['wapp_icon'] = iconForField;
    _fieldValues['wapp_version'] =
        (manifest['version'] as String?) ?? '1.0.0';
    _fieldValues['wapp_kind'] =
        (manifest['kind'] as String?) ?? 'app';
    final tickVal = '${manifest['tick_interval_ms'] ?? 5000}';
    _fieldValues['wapp_tick_interval'] = tickVal;
    _tickIntervalController.text = tickVal;
    // HAL requires — stored as List<String> for the chip picker.
    final halList = manifest['requires']?['hal'];
    _fieldValues['wapp_hal_requires'] = halList is List
        ? halList.cast<String>().toList()
        : <String>['log'];
    // Provides functionalities — stored as List<String> for the chip editor.
    final providesFns = manifest['provides']?['functionalities']
        ?? manifest['provides']?['widgets']
        ?? manifest['provides']?['functions'];
    _fieldValues['wapp_provides_functionalities'] = providesFns is List
        ? providesFns.cast<String>().toList()
        : <String>[];
    _fieldValues['source_ui'] = uiJson;
    _fieldValues['source'] = sourceC;
    _fieldValues['translations'] = translations;
    // Lock the Code tab when the loaded wapp didn't ship main.c.
    // User can still start fresh via the "Create new wapp" button.
    _fieldValues['source__readonly'] = sourceC.isEmpty;
    _loadedWasmBytes = wasm;

    _logLine('loaded ${entry.folder}: id=$id, '
        'title=${title.isEmpty ? '(empty)' : title}, '
        'ui=${uiJson.length} chars, '
        'source=${sourceC.isEmpty ? '(missing)' : '${sourceC.length} chars'}, '
        'wasm=${wasm?.length ?? 0} bytes'
        '${entry.isBuiltIn ? ' (built-in)' : ''}');
    if (sourceC.isEmpty) {
      _logLine('(no main.c shipped with this wapp — Code tab will be '
          'empty; Compile will rebuild from whatever you type in)');
    }
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.success,
      title: 'Loaded ${entry.folder}',
      body: entry.isBuiltIn
          ? 'Built-in wapp — installing will create a user fork at apps/${entry.folder}.'
          : (title.isNotEmpty ? title : '(no title in manifest)'),
      source: 'host:app-creator',
    ));
    if (mounted) setState(() {});
  }

  /// Clear the identity / source / source_ui fields from the
  /// bindings and re-run `_seedFieldDefaults` on every screen so the
  /// editor snaps back to its default new-wapp state. Called from
  /// `_showProjectPicker` when the user picks "Create new wapp".
  /// Log buffers (`output`) are intentionally preserved.
  void _resetToNewProject() {
    const keysToReset = {
      'wapp_title',
      'wapp_name',
      'wapp_id',
      'wapp_description',
      'wapp_icon',
      'wapp_version',
      'wapp_kind',
      'wapp_tick_interval',
      'wapp_hal_requires',
      'wapp_provides_functionalities',
      'source',
      'source_ui',
      'source__readonly',
      'translations',
    };
    for (final key in keysToReset) {
      _fieldValues.remove(key);
    }
    for (final screen in _screens) {
      _seedFieldDefaults(screen);
    }
    // Any `*__readonly` flag the previously-loaded project might
    // have set is gone; the Code tab is editable again.
    _fieldValues['source__readonly'] = false;
    _tickIntervalController.text = '5000';
    _logLine('── new project — fields reset to defaults ──');
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.info,
      title: 'New wapp',
      body: 'Fields reset. Edit Settings, then Compile + Install.',
      source: 'host:app-creator',
    ));
    if (mounted) setState(() {});
  }

  /// Project-picker state for the App Creator Projects tab. `null`
  /// means "haven't scanned yet" — the screen renderer kicks off a
  /// refresh on first build. Subsequent edits to installedAppsStorage
  /// (install, delete) call `_refreshProjects` to pick up changes.
  List<_ProjectEntry>? _projects;
  bool _projectsLoading = false;

  /// Bytes of the currently-loaded wapp's `app.wasm`. Populated by
  /// `_loadProject` so that installing an edited-in-place wapp can
  /// reuse the original compiled binary without round-tripping
  /// through the compiler. Cleared after a successful install (so
  /// subsequent installs fall back to reading from
  /// installedAppsStorage) and after a fresh compile (so the new
  /// bytes take precedence).
  Uint8List? _loadedWasmBytes;

  /// Scan both `installedAppsStorage()` and the source-tree
  /// `wapps/archive/` path for installed wapps. Dedup by
  /// `manifest.id` — user installs take precedence over built-ins
  /// with the same id so that an edited fork hides the original.
  /// Sort: user installs first, then built-ins, alphabetical by
  /// folder within each group.
  Future<void> _refreshProjects() async {
    if (_projectsLoading) return;
    if (mounted) setState(() => _projectsLoading = true);

    final userEntries = <_ProjectEntry>[];
    final builtInEntries = <_ProjectEntry>[];
    final seenIds = <String>{};

    // --- User installs first (they win dedup) ---
    final installed = installedAppsStorage();
    if (await installed.directoryExists('')) {
      final entries = await installed.listDirectory('');
      for (final entry in entries) {
        if (!entry.isDirectory) continue;
        final manifest =
            await installed.readJson('${entry.name}/manifest.json');
        if (manifest == null) continue;
        final id = manifest['id'] as String? ?? '';
        if (id.isNotEmpty) seenIds.add(id);
        userEntries.add(_ProjectEntry(
          folder: entry.name,
          id: id,
          title: (manifest['description'] as String?) ?? '',
          description: (manifest['summary'] as String?) ?? '',
          dirPath: installed.getAbsolutePath(entry.name),
          isBuiltIn: false,
        ));
      }
    }

    // --- Then built-ins, skipping ids already in user installs ---
    // Same candidate paths as main.dart _scanArchiveBody. On web
    // `platform.currentDirectory()` returns an empty string, so
    // neither candidate resolves and the archive scan is a no-op
    // (web built-ins come from the fetch-based loader instead).
    final cwd = platform.currentDirectory();
    final archiveCandidates = [
      '$cwd/../wapps/archive',
      '$cwd/../../wapps/archive',
    ];
    for (final archivePath in archiveCandidates) {
      final archive = wappPackageStorage(archivePath);
      if (!await archive.directoryExists('')) continue;
      final entries = await archive.listDirectory('');
      for (final entry in entries) {
        if (!entry.isDirectory) continue;
        final pkgDir = archive.getAbsolutePath(entry.name);
        final pkg = wappPackageStorage(pkgDir);
        final manifest = await pkg.readJson('manifest.json');
        if (manifest == null) continue;
        final id = manifest['id'] as String? ?? '';
        if (id.isNotEmpty && seenIds.contains(id)) continue;
        if (id.isNotEmpty) seenIds.add(id);
        builtInEntries.add(_ProjectEntry(
          folder: entry.name,
          id: id,
          title: (manifest['description'] as String?) ?? '',
          description: (manifest['summary'] as String?) ?? '',
          dirPath: pkgDir,
          isBuiltIn: true,
        ));
      }
      break; // first archive dir that exists wins
    }

    userEntries.sort((a, b) => a.folder.compareTo(b.folder));
    builtInEntries.sort((a, b) => a.folder.compareTo(b.folder));
    final list = <_ProjectEntry>[...userEntries, ...builtInEntries];

    if (!mounted) return;
    setState(() {
      _projects = list;
      _projectsLoading = false;
    });
  }

  /// Confirm-and-delete a project. Pops a dialog; on confirm,
  /// nukes the installed-apps folder and refreshes the list. Also
  /// fires `WappLoadedEvent` so the launcher rescan drops the tile.
  Future<void> _deleteProject(_ProjectEntry entry) async {
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${entry.folder}?'),
        content: Text(
          'This will permanently delete apps/${entry.folder}/ and '
          'everything inside it (manifest, wasm, screens). This '
          'cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await installedAppsStorage()
          .deleteDirectory(entry.folder, recursive: true);
    } catch (e) {
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Delete failed',
        body: e.toString(),
        source: 'host:app-creator',
      ));
      return;
    }
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.info,
      title: 'Deleted ${entry.folder}',
      source: 'host:app-creator',
    ));
    // WappLoadedEvent doubles as "launcher, please rescan" — reuse it.
    EventBus().fire(WappLoadedEvent(wappId: entry.id, wappName: entry.folder));
    await _refreshProjects();
  }

  /// Enter App Creator editor mode — reveals the Code/UI/Settings
  /// tabs. Called after the user picks a project or hits "Create new
  /// wapp" on the Projects panel. Lazily builds the editor tab
  /// controller so repeat entries keep the same instance (and its
  /// animation state) across a single wapp session.
  void _enterEditorMode() {
    _editorTabController ??= TabController(
      length: _editorTabCount,
      vsync: this,
      initialIndex: 0,
    );
    // Always land on the Code tab on (re-)entry.
    _editorTabController!.index = 0;
    if (mounted) setState(() => _editorMode = true);
  }

  /// Exit App Creator editor mode — returns to the Projects panel.
  /// The back arrow on the editor scaffold calls this.
  void _exitEditorMode() {
    if (mounted) setState(() => _editorMode = false);
  }

  /// The subset of [_screens] shown inside the App Creator editor
  /// view (i.e. everything except Projects). Order is preserved from
  /// home.ui.json so the author controls the tab layout — which must
  /// be Code, UI, Translations, Settings.
  ///
  /// Filtering by the child group's `$type == "projects"` instead of
  /// the screen name is deliberate: after the i18n rework the name
  /// became an `@key` sentinel (e.g. `@screen.projects`) so a plain
  /// string compare against "projects" stopped matching, which is
  /// why the Projects tab used to leak into the editor scaffold.
  List<GeoUiBlock> get _editorScreens => _screens
      .where((s) => !s.children.any((c) =>
          c.keyword == 'group' && c.type == 'projects'))
      .toList();

  /// The tab labels shown for the editor, matched 1:1 to
  /// [_editorScreens]. Used only for the App Creator scaffold.
  List<String> get _editorScreenNames =>
      _editorScreens.map((s) => s.name ?? '').toList();

  /// Number of editor tabs surfaced for App Creator. Matches the
  /// length of [_editorScreens].
  int get _editorTabCount => _editorScreens.length;

  /// Build the App Creator Projects tab. First call kicks off the
  /// async scan; subsequent calls render the cached list.
  Widget _buildProjectsScreen() {
    if (_projects == null && !_projectsLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshProjects();
      });
    }

    final cs = Theme.of(context).colorScheme;
    final projects = _projects ?? const <_ProjectEntry>[];

    return Column(
      children: [
        // Header: Create new + refresh.
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant.withAlpha(80)),
            ),
          ),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: () {
                  _resetToNewProject();
                  _enterEditorMode();
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create new wapp'),
              ),
              const Spacer(),
              IconButton(
                onPressed: _projectsLoading ? null : _refreshProjects,
                icon: _projectsLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                tooltip: 'Refresh',
              ),
            ],
          ),
        ),
        Expanded(
          child: projects.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _projectsLoading
                          ? 'Scanning installed wapps…'
                          : 'No user-installed wapps yet.\n'
                              'Click "Create new wapp" to start one, or use '
                              'the Install wapp from the launcher to pull '
                              'one from a repository.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  itemCount: projects.length,
                  itemBuilder: (context, i) =>
                      _buildProjectCard(projects[i], cs),
                ),
        ),
      ],
    );
  }

  /// Resolve the actual icon for a project card — reads the wapp's
  /// manifest.icon, loads the SVG if present, falls back to Material.
  Widget _projectIcon(_ProjectEntry entry, ColorScheme cs) {
    final pkg = wappPackageStorage(entry.dirPath);
    final manifestBytes = pkg.readBytesSync('manifest.json');
    if (manifestBytes != null) {
      try {
        final manifest =
            jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
        final icon = manifest['icon'] as String?;
        if (icon != null &&
            icon.isNotEmpty &&
            icon.toLowerCase().endsWith('.svg') &&
            icon.contains('/')) {
          final svgBytes = pkg.readBytesSync(icon);
          if (svgBytes != null && svgBytes.isNotEmpty) {
            return SizedBox(
              width: 26,
              height: 26,
              child: SvgPicture.memory(
                svgBytes,
                fit: BoxFit.contain,
                theme: const SvgTheme(currentColor: Color(0xFF666666)),
              ),
            );
          }
        }
        // Text icon (emoji / char)
        if (icon != null &&
            icon.isNotEmpty &&
            !icon.contains('/') &&
            !icon.contains('\\')) {
          return SizedBox(
            width: 26,
            height: 26,
            child: FittedBox(
              child: Text(icon.characters.take(2).toString(),
                  style: const TextStyle(fontSize: 22)),
            ),
          );
        }
      } catch (_) {}
    }
    return Icon(
      wappIconFor(entry.id.isNotEmpty ? entry.id : entry.folder),
      color: cs.primary,
      size: 26,
    );
  }

  Widget _buildProjectCard(_ProjectEntry entry, ColorScheme cs) {
    final pathPrefix = entry.isBuiltIn ? 'wapps/archive/' : 'apps/';
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
      ),
      color: cs.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () async {
          await _loadProject(entry);
          _enterEditorMode();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _projectIcon(entry, cs),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            entry.title.isNotEmpty
                                ? entry.title
                                : entry.folder,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14),
                          ),
                        ),
                        if (entry.isBuiltIn) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: cs.secondaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'built-in',
                              style: TextStyle(
                                fontSize: 10,
                                color: cs.onSecondaryContainer,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$pathPrefix${entry.folder}',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (entry.id.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.id,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (entry.description.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        entry.description,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await _loadProject(entry);
                      _enterEditorMode();
                    },
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Edit'),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                  ),
                  if (!entry.isBuiltIn)
                    TextButton.icon(
                      onPressed: () => _deleteProject(entry),
                      icon: Icon(Icons.delete_outline,
                          size: 16, color: cs.error),
                      label: Text('Delete',
                          style: TextStyle(color: cs.error)),
                      style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Recursively walk a GeoUI block tree and seed [_fieldValues] with
  /// the right initial value for every `field` descendant. This runs
  /// during `_loadWapp`, BEFORE the widget tree builds, so the
  /// renderers can stay pure reads — they never call `setValue` from
  /// inside a build method.
  ///
  /// - `log` fields get an empty `List<String>` (shared mutable
  ///   buffer between host-side appenders and the LogViewField).
  /// - `int` / `float` fields get their numeric default.
  /// - `bool` fields get their boolean default.
  /// - Every other field (including `code`, `string`, `enum`) gets
  ///   its string default if declared.
  void _seedFieldDefaults(GeoUiBlock block) {
    if (block.keyword == 'field') {
      final name = block.name;
      if (name != null && !_fieldValues.containsKey(name)) {
        final type = block.type ?? 'string';
        if (type == 'log') {
          _fieldValues[name] = <String>[];
        } else {
          final def = block.decls['default'];
          if (def is GeoUiNumber) {
            _fieldValues[name] = def.value;
          } else if (def is GeoUiBool) {
            _fieldValues[name] = def.value;
          } else if (def is GeoUiString) {
            _fieldValues[name] = def.value;
          }
        }
      }
    }
    for (final child in block.children) {
      _seedFieldDefaults(child);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadWapp();
  }

  /// Refresh [_i18n] from the wapp package using the currently-
  /// preferred locale. Called once on wapp load and again every
  /// time the user switches language so the change takes effect
  /// without reloading the whole wapp.
  Future<void> _reloadI18n() async {
    final prefs = await PreferencesService.instance();
    final locale = prefs.activeLocale();
    final lang = prefs.activeLanguageCode();
    _i18n = await I18nContext.loadFromPackage(
      _pkg,
      locale: locale,
      languageOnly: lang,
    );
    // Also hand the fresh table to the engine so hal_i18n_get()
    // calls from the wapp code see the same translations as the
    // GeoUI renderer.
    _engine.setI18n(_i18n);
  }

  Future<void> _loadWapp() async {
    // Load the wapp's translation tables first so the screens we're
    // about to parse can resolve their `@key` references right away.
    // On first run this reads `lang/<locale>.json` from the wapp
    // package (e.g. wapps/archive/install/lang/pt_PT.json) and
    // merges the English fallback. Wapps without a `lang/` dir
    // produce an empty context and every string passes through as-
    // authored.
    await _reloadI18n();
    // Live reload on language switch: the Settings row fires
    // LocaleChangedEvent, we rebuild the context and setState so
    // every GeoUiScreenRenderer picks up the new i18n on its next
    // build pass.
    _localeSub = EventBus().on<LocaleChangedEvent>((_) async {
      await _reloadI18n();
      if (mounted) setState(() {});
    });

    // Parse .ui.json screens from the package's screens/ directory.
    if (await _pkg.directoryExists('screens')) {
      final entries = await _pkg.listDirectory('screens');
      for (final entry in entries) {
        if (entry.isDirectory || !entry.path.endsWith('.ui.json')) continue;
        final content = await _pkg.readString(entry.path);
        if (content == null) continue;
        try {
          final parsed = GeoUiParser(content).parse();
          for (final block in parsed.blocks) {
            if (block.keyword == 'screen') {
              _addScreen(block);
            } else if (block.keyword == 'app') {
              for (final child in block.children) {
                if (child.keyword == 'screen') _addScreen(child);
              }
            }
          }
        } catch (_) {}
      }
    }

    // Load field defaults from screens (recursive — fields can live
    // either inside a group card or directly under the screen).
    for (final screen in _screens) {
      // Map screens still carry their viewport knobs on the group block.
      for (final group in screen.childrenOf('group')) {
        if (group.type == 'map') {
          _hasMap = true;
          _mapLat = group.getNumber('default-lat') ?? 0;
          _mapLon = group.getNumber('default-lon') ?? 0;
          _mapZoom = group.getNumber('default-zoom')?.toInt() ?? 12;
          _tileUrl = group.getString('tile-url') ?? _tileUrl;
        }
      }
      _seedFieldDefaults(screen);
    }

    // Build tab controller
    _tabController = TabController(length: _screenNames.length, vsync: this);

    // Set up persistent KV storage under the per-wapp data dir.
    final prefs = await PreferencesService.instance();
    final wappData = wappDataStorageFor(prefs, _wappName);
    await wappData.createDirectory('');
    _wappData = wappData;
    _engine.setStorage(wappData);

    // Auto-configure the install wapp's `source` KV to point at the
    // in-repo wapps/binaries/ dir when running from a source checkout.
    if (_wappName == 'install' && !_engine.hasKvKey('source')) {
      final binStorage = wappPackageStorage('${widget.wappDir}/../../binaries');
      if (await binStorage.directoryExists('')) {
        _engine.kvSet('source', binStorage.basePath);
      }
    }

    // Load the WASM binary from the package.
    final wasmBytes = await _pkg.readBytes('app.wasm');
    if (wasmBytes == null) {
      setState(() => _status = 'app.wasm not found');
      EventBus().fire(WappCrashedEvent(
        wappId: _wappName, phase: 'load',
        error: 'app.wasm not found at ${_pkg.basePath}/app.wasm',
      ));
      return;
    }

    try {
      await _engine.load(wasmBytes);
      _engine.init();
      _drainOutbox();

      final interval = _engine.tickIntervalMs;

      // Register this wapp's tick loop with the task monitor.
      TaskMonitorService.instance.register(MonitoredTask(
        id: _tickTaskId,
        name: _wappName,
        description: 'Tick loop for $_wappName',
        serviceName: 'wapps',
        priority: TaskPriority.normal,
        type: TaskType.periodic,
        interval: Duration(milliseconds: interval),
      ));

      _tickTimer = Timer.periodic(Duration(milliseconds: interval), (_) {
        // Honour pause-from-task-monitor: skip the tick body but keep
        // the timer alive so resume just works.
        final task = TaskMonitorService.instance.getTask(_tickTaskId);
        if (task?.status == TaskStatus.paused) return;
        TaskMonitorService.instance.reportStart(_tickTaskId);
        try {
          _engine.tick();
          _drainOutbox();
          TaskMonitorService.instance.reportSuccess(_tickTaskId);
        } catch (e) {
          TaskMonitorService.instance.reportFailure(_tickTaskId, e);
          EventBus().fire(WappCrashedEvent(
            wappId: _wappName, phase: 'tick', error: e,
          ));
        }
      });

      EventBus().fire(WappLoadedEvent(wappId: _wappName, wappName: _wappName));
      setState(() => _status = 'Running');
    } catch (e) {
      EventBus().fire(WappCrashedEvent(
        wappId: _wappName, phase: 'load', error: e,
      ));
      setState(() => _status = 'Error: $e');
    }
  }

  void _addScreen(GeoUiBlock screen) {
    final name = screen.name ?? 'Screen ${_screens.length}';
    // Deduplicate
    if (_screenNames.any((n) => n.toLowerCase() == name.toLowerCase())) return;
    _screens.add(screen);
    _screenNames.add(name);
  }

  void _drainOutbox() {
    final messages = _engine.drainOutbox();
    if (messages.isEmpty) return;
    var changed = false;
    for (final raw in messages) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final type = data['type'] as String? ?? '';
        if (type == 'ui.append') {
          final item = data['item'] as Map<String, dynamic>? ?? {};
          _outputLines.add(_OutputLine(
            item['text'] as String? ?? '',
            item['level'] as String? ?? 'out',
          ));
          changed = true;
        } else if (type == 'store.sources') {
          // Install wapp push: the current source list straight out
          // of its KV store. Mirror it to _fieldValues['source'] as
          // a newline-joined string so the sources group renderer
          // (and any other reader) sees the same shape the wapp has
          // on disk.
          final list = data['sources'] as List?;
          final asStrings =
              list == null ? <String>[] : list.whereType<String>().toList();
          _fieldValues['source'] = asStrings.join('\n');
          _storeSources = asStrings;
          _sourcesLoaded = true;
          changed = true;
        } else if (type == 'ui.log.append') {
          // Append a single line to a $type:"log" field's buffer.
          // The wapp addresses the target field by name. If the
          // field's backing list doesn't exist yet (first line
          // before the renderer ran) we create it lazily.
          final fieldName = data['field'] as String? ?? 'output';
          final line = data['line'] as String? ?? '';
          final existing = _fieldValues[fieldName];
          final List<String> buf;
          if (existing is List<String>) {
            buf = existing;
          } else {
            buf = <String>[];
            _fieldValues[fieldName] = buf;
          }
          buf.add(line);
          changed = true;
        } else if (type == 'ui.map.viewport') {
          _mapLat = (data['lat'] as num?)?.toDouble() ?? _mapLat;
          _mapLon = (data['lon'] as num?)?.toDouble() ?? _mapLon;
          _mapZoom = (data['zoom'] as num?)?.toInt() ?? _mapZoom;
          changed = true;
        } else if (type == 'ui.toast') {
          // Legacy message shape — route through the unified service
          // so old wapps inherit system-tray delivery + history.
          NotificationService.instance.show(GeogramNotification(
            level: NotificationLevel.info,
            title: _wappName,
            body: data['message'] as String? ?? '',
            source: 'wapp:$_wappName',
          ));
        } else if (type == 'notify') {
          // New unified notification protocol.
          final levelStr = (data['level'] as String? ?? 'info').toLowerCase();
          final level = switch (levelStr) {
            'success' => NotificationLevel.success,
            'warning' || 'warn' => NotificationLevel.warning,
            'error' || 'err' => NotificationLevel.error,
            _ => NotificationLevel.info,
          };
          final scopeStr = (data['scope'] as String? ?? 'app').toLowerCase();
          final scope = switch (scopeStr) {
            'system' => NotificationScope.system,
            'both' => NotificationScope.both,
            _ => NotificationScope.app,
          };
          NotificationService.instance.show(GeogramNotification(
            level: level,
            title: data['title'] as String? ?? _wappName,
            body: data['body'] as String?,
            source: 'wapp:$_wappName',
            tag: data['tag'] as String?,
            scope: scope,
          ));
        } else if (type == 'wapp.fetch_index') {
          unawaited(_handleFetchIndex(data));
        } else if (type == 'wapp.install') {
          unawaited(_handleWappInstall(data));
        } else if (type == 'system.tasks.list') {
          _refreshTaskSnapshot();
          changed = true;
        } else if (type == 'system.tasks.pause') {
          TaskMonitorService.instance.pause(data['id'] as String? ?? '');
          _refreshTaskSnapshot();
          changed = true;
        } else if (type == 'system.tasks.resume') {
          TaskMonitorService.instance.resume(data['id'] as String? ?? '');
          _refreshTaskSnapshot();
          changed = true;
        } else if (type == 'system.tasks.pause_all') {
          TaskMonitorService.instance.pauseAllNonCritical();
          _refreshTaskSnapshot();
          changed = true;
        } else if (type == 'system.tasks.resume_all') {
          TaskMonitorService.instance.resumeAll();
          _refreshTaskSnapshot();
          changed = true;
        } else if (type == 'widget.request') {
          // Caller wapp is requesting a widget. Delegate to the
          // host-side broker which spins up a headless provider
          // engine and delivers the response back to this engine's
          // inbox on the next tick.
          unawaited(FunctionalityBroker.instance.handleRequest(
            callerEngineId: _engine.engineId,
            functionalityId: data['widget'] as String? ?? '',
            reqId: data['req_id'] as String? ?? '',
            args: (data['args'] as Map<String, dynamic>?) ?? const {},
          ));
        } else if (type == 'compile') {
          unawaited(_handleCompile(data));
        } else if (type == 'install') {
          unawaited(_handleInstall(data));
        }
      } catch (_) {}
    }
    if (changed && mounted) {
      setState(() {});
      // Terminal-style wapps tail their log — auto-scroll to the
      // newest line. The Wapp Store (install wapp) reuses the same
      // controller but wants the user to land at the TOP with the
      // featured banner + first cards visible, so we skip the jump
      // there. Any wapp that doesn't want auto-tail can be added
      // to this exclusion list.
      if (_wappName != 'install') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController
                .jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      }
    }
  }

  Future<void> _handleFetchIndex(Map<String, dynamic> data) async {
    final source = data['source'] as String? ?? '';
    if (source.isEmpty) return;

    // Resolve the source into (dir, file) and wrap the dir in a transient
    // ProfileStorage. The source may be either a directory (implicit
    // index.json) or an explicit path to a .json file.
    String absPath = source;
    if (!absPath.endsWith('.json')) {
      if (!absPath.endsWith('/')) absPath += '/';
      absPath += 'index.json';
    }
    final sep = platform.pathSeparator;
    final slashIdx = absPath.replaceAll(sep, '/').lastIndexOf('/');
    if (slashIdx <= 0) {
      _outputLines.add(_OutputLine('Invalid index path: $absPath', 'err'));
      if (mounted) setState(() {});
      return;
    }
    final dir = absPath.substring(0, slashIdx);
    final file = absPath.substring(slashIdx + 1);
    final dirStorage = wappPackageStorage(dir);

    final content = await dirStorage.readString(file);
    if (content == null) {
      _outputLines.add(_OutputLine('Index not found: $absPath', 'err'));
      if (mounted) setState(() {});
      return;
    }

    try {
      final contents = jsonDecode(content);
      // Enrich every catalog entry with the real publisher_npub
      // from the matching wapp's signature.json. The sibling
      // `wapps/archive/<name>/` layout is the canonical location —
      // that's where the launcher scans built-ins and writes their
      // signatures. We also fall back to `<dir>/<name>/` in case a
      // binaries-style layout placed signature.json alongside the
      // .wapp file. If neither has a signature the entry stays
      // unsigned (empty publisher_npub) and the store card shows
      // the "unknown publisher" state.
      final enriched = _enrichCatalogWithSignatures(contents, dir);
      final msg = jsonEncode({'type': 'wapp.index', 'data': enriched});
      _engine.sendMessage(msg);
      _engine.handleEvent();
      _drainOutbox();
      if (mounted) setState(() {});
    } catch (e) {
      _outputLines.add(_OutputLine('Failed to read index: $e', 'err'));
      if (mounted) setState(() {});
    }
  }

  /// Walk [catalog] (the parsed index.json) and fill in each entry's
  /// `publisher_npub` from the actual wapp's `signature.json` sidecar.
  /// The canonical source tree for built-ins is `wapps/archive/<name>/`;
  /// [indexDir] is the directory of the index.json (e.g. `wapps/binaries/`)
  /// and we look up the signing side at `../archive/<name>/` relative
  /// to it. The fallback path checks `<indexDir>/<name>/` in case the
  /// consumer put signatures next to the binaries.
  dynamic _enrichCatalogWithSignatures(dynamic catalog, String indexDir) {
    if (catalog is! List) return catalog;
    // Compute the two candidate lookup roots once.
    final normalized = indexDir.replaceAll(platform.pathSeparator, '/');
    final parent = normalized.contains('/')
        ? normalized.substring(0, normalized.lastIndexOf('/'))
        : normalized;
    final archiveRoot = '$parent/archive';
    final result = <dynamic>[];
    for (final rawEntry in catalog) {
      if (rawEntry is! Map<String, dynamic>) {
        result.add(rawEntry);
        continue;
      }
      final entry = Map<String, dynamic>.of(rawEntry);
      final fileField = entry['file'] as String? ?? '';
      // Derive folder name from the "file" path, e.g.
      // "maps/maps-1.0.0.wapp" → "maps".
      final slashIdx = fileField.indexOf('/');
      if (slashIdx > 0) {
        final name = fileField.substring(0, slashIdx);
        final candidates = <String>[
          '$archiveRoot/$name',
          '$indexDir/$name',
        ];
        for (final candidate in candidates) {
          final pkg = wappPackageStorage(candidate);
          if (pkg.existsSync('signature.json')) {
            final npub =
                WappSigningService.instance.readPublisherNpubSync(pkg);
            if (npub.isNotEmpty) {
              entry['publisher_npub'] = npub;
              break;
            }
          }
        }
      }
      result.add(entry);
    }
    return result;
  }

  Future<void> _handleWappInstall(Map<String, dynamic> data) async {
    final source = data['source'] as String? ?? '';
    final filePath = data['file'] as String? ?? '';
    final name = data['name'] as String? ?? '';
    final version = data['version'] as String? ?? '';
    if (source.isEmpty || filePath.isEmpty || name.isEmpty) return;

    // Resolve the source dir (may be a .json path or a plain directory).
    var baseDir = source;
    if (baseDir.endsWith('.json')) {
      final slashIdx = baseDir.replaceAll(platform.pathSeparator, '/').lastIndexOf('/');
      if (slashIdx <= 0) return;
      baseDir = baseDir.substring(0, slashIdx);
    }
    final srcStorage = wappPackageStorage(baseDir);
    if (!await srcStorage.exists(filePath)) {
      _outputLines.add(_OutputLine('File not found: $baseDir/$filePath', 'err'));
      if (mounted) setState(() {});
      return;
    }

    try {
      // Wipe any previous install, then re-create the target directory.
      await _installed.deleteDirectory(name, recursive: true);
      await _installed.createDirectory(name);

      // Extract the .wapp (ZIP) via package:archive so the same code
      // path works on desktop (FilesystemProfileStorage) and web
      // (MemoryProfileStorage). No Process spawn, no dart:io.
      final archiveBytes = await srcStorage.readBytes(filePath);
      if (archiveBytes == null || archiveBytes.isEmpty) {
        _outputLines.add(
            _OutputLine('Empty or missing .wapp: $filePath', 'err'));
        if (mounted) setState(() {});
        return;
      }
      try {
        final decoded = ZipDecoder().decodeBytes(archiveBytes);
        for (final entry in decoded) {
          if (!entry.isFile) continue;
          final rel = entry.name.replaceAll('\\', '/');
          if (rel.isEmpty) continue;
          final content = entry.content as List<int>;
          await _installed.writeBytes(
              '$name/$rel', Uint8List.fromList(content));
        }
      } catch (e) {
        _outputLines.add(_OutputLine('Extract failed: $e', 'err'));
        if (mounted) setState(() {});
        return;
      }

      // Verify app.wasm landed.
      if (!await _installed.exists('$name/app.wasm')) {
        _outputLines.add(_OutputLine('Invalid wapp: no app.wasm', 'err'));
        await _installed.deleteDirectory(name, recursive: true);
        if (mounted) setState(() {});
        return;
      }

      // Confirm installation to the module so it updates its KV.
      final confirmMsg = jsonEncode({
        'type': 'wapp.installed',
        'name': name,
        'version': version,
      });
      _engine.sendMessage(confirmMsg);
      _engine.handleEvent();
      _drainOutbox();

      _outputLines.add(_OutputLine('$name v$version installed', 'info'));
      if (mounted) setState(() {});
    } catch (e) {
      _outputLines.add(_OutputLine('Install failed: $e', 'err'));
      if (mounted) setState(() {});
    }
  }

  Future<void> _uninstallWapp(String name) async {
    await _installed.deleteDirectory(name, recursive: true);
    _sendCommand('remove $name');
    _engine.handleEvent();
    _drainOutbox();
    if (mounted) setState(() {});
  }

  void _sendCommand(String cmd) {
    // Bundle a scalar projection of the current field values so the
    // wapp's module_handle_event can read (source, wapp_id, ...) from
    // a single message without round-tripping through a separate save
    // step. Non-scalar entries — primarily the List<String> log
    // buffers — are dropped so we don't ship log history with every
    // action click. Wapps that only read data['command'] ignore the
    // extra "fields" key harmlessly.
    final scalarFields = <String, dynamic>{};
    for (final entry in _fieldValues.entries) {
      final v = entry.value;
      if (v is String || v is num || v is bool) {
        scalarFields[entry.key] = v;
      }
    }
    _engine.sendMessage(jsonEncode({
      'command': cmd,
      'fields': scalarFields,
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    TaskMonitorService.instance.unregister(_tickTaskId);
    EventBus().fire(WappUnloadedEvent(wappId: _wappName, wappName: _wappName));
    _localeSub?.cancel();
    _engine.dispose();
    _cmdController.dispose();
    _scrollController.dispose();
    _sourcesInputController.dispose();
    _tabController?.dispose();
    _editorTabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_tabController == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(child: Text(_status)),
      );
    }

    if (_isAppCreator) {
      return _editorMode
          ? _buildAppCreatorEditor()
          : _buildAppCreatorProjects();
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: _screenNames.length > 1
            ? TabBar(
                controller: _tabController,
                tabs: _screenNames
                    .map((n) => Tab(text: _i18n.resolve(n)))
                    .toList(),
                isScrollable: true,
              )
            : null,
      ),
      body: TabBarView(
        controller: _tabController,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < _screens.length; i++)
            _buildScreen(_screens[i]),
        ],
      ),
    );
  }

  /// Initial App Creator view — just the Projects panel. No tab
  /// bar, no "Projects" label; the AppBar title is the wapp title
  /// so the user knows they're in App Creator, and the body is the
  /// projects list directly.
  Widget _buildAppCreatorProjects() {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _buildProjectsScreen(),
    );
  }

  /// App Creator editor view — shown after the user picks a project
  /// or clicks "Create new wapp". Back arrow returns to the Projects
  /// panel; tabs are Code / UI / Settings, matching the order in
  /// home.ui.json (with Projects filtered out).
  Widget _buildAppCreatorEditor() {
    final editorScreens = _editorScreens;
    final editorNames = _editorScreenNames;
    // Guard: if home.ui.json has fewer editor screens than the
    // previously-built controller expects, rebuild it. Keeps the
    // navigation coherent even while developing.
    if (_editorTabController == null ||
        _editorTabController!.length != editorScreens.length) {
      _editorTabController?.dispose();
      _editorTabController = TabController(
        length: editorScreens.length,
        vsync: this,
      );
    }
    final currentName = _fieldValues['wapp_title'] as String? ?? '';
    final titleSuffix = currentName.isEmpty ? '' : ' — $currentName';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to projects',
          onPressed: _exitEditorMode,
        ),
        title: Text('${widget.title}$titleSuffix'),
        bottom: TabBar(
          controller: _editorTabController,
          tabs: editorNames
              .map((n) => Tab(text: _i18n.resolve(n)))
              .toList(),
          isScrollable: true,
        ),
      ),
      body: TabBarView(
        controller: _editorTabController,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final screen in editorScreens) _buildScreen(screen),
        ],
      ),
    );
  }

  Widget _buildScreen(GeoUiBlock screen) {
    // Check if this screen has a map group
    final mapGroup = screen.children
        .where((c) => c.keyword == 'group' && c.type == 'map')
        .firstOrNull;
    if (mapGroup != null) return _buildMapScreen(screen, mapGroup);

    // Tasks viewer — host renders cards from the cached MonitoredTask
    // snapshot kept in _taskSnapshot, refreshed each time the wapp polls.
    final hasTasksGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'tasks');
    if (hasTasksGroup) {
      return _buildTasksScreen();
    }

    // Projects picker (App Creator) — host renders a list of installed
    // wapps so the user can pick one to edit or start a new one.
    final hasProjectsGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'projects');
    if (hasProjectsGroup) {
      return _buildProjectsScreen();
    }

    // Output-only screen (e.g. Shop catalog) — no command input
    final hasOutputGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'output');
    if (hasOutputGroup) {
      return _buildOutputScreen();
    }

    // Functionalities browser — system wapp that lists all registered
    // functionalities, their providers, and lets the user pick defaults.
    final hasFunctionalitiesGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'functionalities');
    if (hasFunctionalitiesGroup) {
      return _buildFunctionalitiesScreen();
    }

    // Sources manager — install wapp's Settings tab. Shows the
    // current repository list (pushed by the wapp via store.sources)
    // with add+remove affordances and URL validation.
    final hasSourcesGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'sources');
    if (hasSourcesGroup) {
      return _buildSourcesScreen();
    }

    // UI editor — App Creator's UI tab. A split Code/Visual editor
    // that lets the author click-to-edit GeoUI blocks or drop into
    // raw JSON. Bound to `_fieldValues['source_ui']`.
    final hasUiEditorGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'ui-editor');
    if (hasUiEditorGroup) {
      return _buildUiEditorScreen();
    }

    // Translations editor — App Creator's Translations tab. Edits
    // the wapp's `lang/<locale>.json` sidecars as a flat key-value
    // table per locale; the install pipeline ships whichever locales
    // the author filled in.
    final hasTranslationsGroup = screen.children.any((c) =>
        c.keyword == 'group' && c.type == 'translations');
    if (hasTranslationsGroup) {
      return _buildTranslationsScreen();
    }

    // Terminal screen — has output + command input
    final hasTerminal = screen.children.any((c) =>
        c.keyword == 'group' &&
        c.children.any((gc) => gc.keyword == 'watch'));
    if (hasTerminal) {
      return _buildTerminalScreen();
    }

    // Settings-like screen — use GeoUI renderer
    return _buildSettingsScreen(screen);
  }

  // ── Tasks viewer ──────────────────────────────────────────────────

  Widget _buildTasksScreen() {
    final cs = Theme.of(context).colorScheme;
    final tasks = _taskSnapshot;

    final running =
        tasks.where((t) => t.status == TaskStatus.running).length;
    final idle = tasks.where((t) => t.status == TaskStatus.idle).length;
    final paused = tasks.where((t) => t.status == TaskStatus.paused).length;
    final errored = tasks.where((t) => t.status == TaskStatus.error).length;

    return Column(
      children: [
        // Header summary + bulk actions
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant.withAlpha(80)),
            ),
          ),
          child: Row(
            children: [
              _StatusPill(
                  label: 'running', count: running, color: Colors.green),
              const SizedBox(width: 6),
              _StatusPill(label: 'idle', count: idle, color: cs.primary),
              const SizedBox(width: 6),
              _StatusPill(
                  label: 'paused', count: paused, color: Colors.amber),
              const SizedBox(width: 6),
              _StatusPill(label: 'error', count: errored, color: cs.error),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _sendCommand('pause-all'),
                icon: const Icon(Icons.pause_circle, size: 18),
                label: const Text('Pause all'),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact),
              ),
              TextButton.icon(
                onPressed: () => _sendCommand('resume-all'),
                icon: const Icon(Icons.play_circle, size: 18),
                label: const Text('Resume all'),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact),
              ),
            ],
          ),
        ),
        Expanded(
          child: tasks.isEmpty
              ? const Center(
                  child: Text('No tasks registered yet.',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  itemCount: tasks.length,
                  itemBuilder: (context, i) => _buildTaskCard(tasks[i], cs),
                ),
        ),
      ],
    );
  }

  Widget _buildTaskCard(MonitoredTask task, ColorScheme cs) {
    final statusColor = switch (task.status) {
      TaskStatus.running => Colors.green,
      TaskStatus.idle => cs.primary,
      TaskStatus.paused => Colors.amber,
      TaskStatus.error => cs.error,
    };
    final priorityColor = switch (task.priority) {
      TaskPriority.critical => cs.error,
      TaskPriority.normal => cs.primary,
      TaskPriority.low => cs.onSurfaceVariant,
    };
    final bootColor = switch (task.bootStart) {
      BootStart.sequential => Colors.deepOrange,
      BootStart.parallel => Colors.cyan,
      BootStart.none => cs.onSurfaceVariant,
    };
    final isCritical = task.priority == TaskPriority.critical;
    final isPaused = task.status == TaskStatus.paused;
    final lastMs = task.lastDuration?.inMilliseconds;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
      ),
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row: name + pills
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(task.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(task.id,
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                _MiniPill(label: task.status.name, color: statusColor),
                const SizedBox(width: 4),
                _MiniPill(label: task.priority.name, color: priorityColor),
                const SizedBox(width: 4),
                _MiniPill(
                    label: task.type.name, color: cs.onSurfaceVariant),
                if (task.bootStart != BootStart.none) ...[
                  const SizedBox(width: 4),
                  _MiniPill(
                      label: 'boot:${task.bootStart.name}',
                      color: bootColor),
                ],
              ],
            ),
            const SizedBox(height: 8),
            // Stats
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _Stat(label: 'service', value: task.serviceName),
                _Stat(label: 'runs', value: '${task.runCount}'),
                _Stat(label: 'ok', value: '${task.successCount}'),
                _Stat(label: 'fail', value: '${task.failCount}'),
                if (lastMs != null)
                  _Stat(label: 'last', value: '${lastMs}ms'),
                _Stat(label: 'cpu', value: '${task.totalCpuMs}ms'),
                if (task.interval != null)
                  _Stat(
                      label: 'every',
                      value: '${task.interval!.inMilliseconds}ms'),
              ],
            ),
            if (task.lastError != null) ...[
              const SizedBox(height: 6),
              Text(task.lastError!,
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: cs.error)),
            ],
            const SizedBox(height: 8),
            // Actions
            Row(
              children: [
                if (!isCritical && !isPaused)
                  TextButton.icon(
                    onPressed: () => _sendCommand('pause ${task.id}'),
                    icon: const Icon(Icons.pause, size: 16),
                    label: const Text('Pause'),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                  ),
                if (isPaused)
                  TextButton.icon(
                    onPressed: () => _sendCommand('resume ${task.id}'),
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Resume'),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                  ),
                const Spacer(),
                if (isCritical)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('critical — cannot pause',
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Output-only screen (Shop catalog) ──────────────────────────────

  /// Install wapp Settings tab — a list of configured repositories
  /// with a single input + Add button and per-row remove affordances.
  /// Pulls its initial state from the {"type":"store.sources"} message
  /// the wapp pushes on init. Every mutation re-sends the whole list
  /// back to the wapp via a `set_sources` action — the wapp persists
  /// to its KV under "source" and echoes store.sources back so the
  /// two sides stay in sync.
  /// App Creator UI editor — the `UI` tab. Switches between a raw
  /// JSON code view (reuses [CodeEditorField]) and a click-to-edit
  /// block tree. Both sides operate on the same `_fieldValues['source_ui']`
  /// string, so the install pipeline doesn't need to know which mode
  /// the author was using.
  ///
  /// Visual-mode data model:
  /// - Parses `source_ui` as dynamic JSON. Top-level may be a list
  ///   of screens (the convention) or a single screen object.
  /// - Screens are addressed by [_uiActiveScreenIndex].
  /// - Any block inside the active screen is addressed by a path
  ///   (list of indices into the chain of `children` arrays) stored
  ///   in [_uiSelectedPath]. An empty list means "the screen itself";
  ///   `null` means "nothing selected".
  /// - Mutations walk the live `dynamic` copy, apply the change,
  ///   then re-encode the whole thing back into `_fieldValues['source_ui']`.
  Widget _buildUiEditorScreen() {
    final cs = Theme.of(context).colorScheme;
    final raw = (_fieldValues['source_ui'] as String?) ?? '';

    // Header row: Code | Visual toggle + context-dependent actions.
    Widget header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          SegmentedButton<_UiEditorMode>(
            segments: const [
              ButtonSegment(
                value: _UiEditorMode.visual,
                icon: Icon(Icons.account_tree, size: 18),
                label: Text('Visual'),
              ),
              ButtonSegment(
                value: _UiEditorMode.code,
                icon: Icon(Icons.code, size: 18),
                label: Text('Code'),
              ),
            ],
            selected: {_uiEditorMode},
            onSelectionChanged: (s) =>
                setState(() => _uiEditorMode = s.first),
            showSelectedIcon: false,
          ),
          const Spacer(),
          if (_uiEditorMode == _UiEditorMode.visual)
            FilledButton.tonalIcon(
              onPressed: _uiNewScreen,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New screen'),
            ),
        ],
      ),
    );

    Widget body;
    if (_uiEditorMode == _UiEditorMode.code) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: CodeEditorField(
          fieldName: 'source_ui',
          label: 'home.ui.json',
          languageId: 'json',
          initialValue: raw,
          onChanged: (v) {
            _fieldValues['source_ui'] = v;
            // Reset the visual selection so switching back to the
            // tree view doesn't point at a stale path.
            if (mounted) setState(() => _uiSelectedPath = null);
          },
          tip: 'GeoUI screens, raw JSON. Changes round-trip to the '
              'visual editor on save.',
        ),
      );
    } else {
      // Visual mode — parse, show screen tabs + tree + inspector.
      dynamic parsed;
      try {
        parsed = raw.trim().isEmpty
            ? <dynamic>[]
            : jsonDecode(raw);
      } catch (e) {
        body = _buildUiEditorError('This UI has a JSON syntax error — '
            'switch to Code mode to fix it.\n\n$e');
        return Column(children: [header, Expanded(child: body)]);
      }
      final screens = _uiScreensOf(parsed);
      if (screens.isEmpty) {
        body = _buildUiEditorEmpty();
      } else {
        if (_uiActiveScreenIndex >= screens.length) {
          _uiActiveScreenIndex = 0;
        }
        body = _buildUiEditorVisual(screens, cs);
      }
    }

    return Column(children: [header, Expanded(child: body)]);
  }

  /// Extract the top-level screen list from a parsed `source_ui`.
  /// Handles both shapes: a List of blocks (convention) and a single
  /// block object. Non-screen top-level blocks are passed through
  /// too so the user can see + delete them.
  List<Map<String, dynamic>> _uiScreensOf(dynamic parsed) {
    if (parsed is List) {
      return parsed.whereType<Map<String, dynamic>>().toList();
    }
    if (parsed is Map<String, dynamic>) return [parsed];
    return [];
  }

  /// Write [screens] back to `_fieldValues['source_ui']` as pretty
  /// printed JSON so the Code view (and the Install pipeline) see
  /// the mutation immediately.
  void _uiPersist(List<Map<String, dynamic>> screens) {
    const encoder = JsonEncoder.withIndent('  ');
    _fieldValues['source_ui'] = encoder.convert(screens);
  }

  Widget _buildUiEditorError(String message) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: cs.error),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildUiEditorEmpty() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dashboard_customize_outlined,
                size: 56, color: cs.primary),
            const SizedBox(height: 12),
            Text(
              'No screens yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              'Click "New screen" above to add a blank screen and '
              'start building the UI.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUiEditorVisual(
      List<Map<String, dynamic>> screens, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Screen tabs — one chip per top-level screen.
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: screens.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final screen = screens[i];
              final label = (screen['name'] as String?) ?? 'Screen ${i + 1}';
              final selected = i == _uiActiveScreenIndex;
              return ChoiceChip(
                label: Text(label),
                selected: selected,
                onSelected: (_) => setState(() {
                  _uiActiveScreenIndex = i;
                  _uiSelectedPath = null;
                }),
              );
            },
          ),
        ),
        Divider(height: 1, color: cs.outlineVariant.withAlpha(80)),

        // Three-pane editor: palette | canvas | inspector. The
        // palette holds draggable block templates, the canvas
        // renders the active screen as clickable mock widgets with
        // drop zones between children, and the inspector edits the
        // attributes of whatever is selected on the canvas.
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 200,
                child: _buildUiPalette(cs),
              ),
              VerticalDivider(
                  width: 1, color: cs.outlineVariant.withAlpha(80)),
              Expanded(
                flex: 3,
                child: _buildUiCanvas(screens, cs),
              ),
              VerticalDivider(
                  width: 1, color: cs.outlineVariant.withAlpha(80)),
              SizedBox(
                width: 300,
                child: _buildUiInspector(screens, cs),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Palette ─────────────────────────────────────────────────────

  /// Left-side panel — a scrollable list of draggable block
  /// templates. Each tile is a [Draggable] carrying a
  /// `Map<String, dynamic>` payload; the canvas drop targets read
  /// the payload and insert a deep-copy at the drop position.
  Widget _buildUiPalette(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        children: [
          Text(
            'Palette',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Drag onto the canvas',
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          for (final entry in _uiPaletteEntries())
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildPaletteTile(entry, cs),
            ),
        ],
      ),
    );
  }

  Widget _buildPaletteTile(_UiPaletteEntry entry, ColorScheme cs) {
    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withAlpha(100)),
      ),
      child: Row(
        children: [
          Icon(entry.icon, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (entry.subLabel != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    entry.subLabel!,
                    style: TextStyle(
                      fontSize: 10,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Icon(Icons.drag_indicator, size: 16, color: cs.onSurfaceVariant),
        ],
      ),
    );
    return Draggable<_UiDragPayload>(
      data: _UiDragPayload.fromPalette(entry.template),
      feedback: Material(
        elevation: 6,
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Opacity(opacity: 0.88, child: tile),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tile,
    );
  }

  /// Static catalogue of block types the user can drag from the
  /// palette. Each entry bundles the icon, the label, an optional
  /// subtitle, and a template JSON to deep-copy at drop time.
  List<_UiPaletteEntry> _uiPaletteEntries() {
    return [
      const _UiPaletteEntry(
        label: 'Screen',
        subLabel: 'Top-level tab',
        icon: Icons.web,
        template: {
          r'$': 'screen',
          'name': 'Screen',
          'tip': '',
          'children': <dynamic>[],
        },
      ),
      const _UiPaletteEntry(
        label: 'Group',
        subLabel: 'Card container',
        icon: Icons.folder_special,
        template: {
          r'$': 'group',
          'name': 'Group',
          'tip': '',
          'children': <dynamic>[],
        },
      ),
      const _UiPaletteEntry(
        label: 'Label',
        subLabel: 'Plain text',
        icon: Icons.label,
        template: {r'$': 'label', 'text': 'Hello world'},
      ),
      const _UiPaletteEntry(
        label: 'Action button',
        subLabel: 'Sends action to wapp',
        icon: Icons.smart_button,
        template: {
          r'$': 'action',
          'name': 'save',
          'label': 'Save',
          'style': 'primary',
        },
      ),
      const _UiPaletteEntry(
        label: 'Text field',
        subLabel: 'Single-line input',
        icon: Icons.text_fields,
        template: {
          r'$': 'field',
          r'$type': 'string',
          'name': 'field1',
          'label': 'Field',
          'default': '',
        },
      ),
      const _UiPaletteEntry(
        label: 'Multi-line field',
        subLabel: 'Text area',
        icon: Icons.subject,
        template: {
          r'$': 'field',
          r'$type': 'string',
          'name': 'field1',
          'label': 'Field',
          'multiline': true,
          'lines': 5,
          'default': '',
        },
      ),
      const _UiPaletteEntry(
        label: 'Toggle',
        subLabel: 'On / off switch',
        icon: Icons.toggle_on,
        template: {
          r'$': 'field',
          r'$type': 'bool',
          'name': 'enabled',
          'label': 'Enabled',
          'default': false,
        },
      ),
      const _UiPaletteEntry(
        label: 'Number',
        subLabel: 'Integer input',
        icon: Icons.numbers,
        template: {
          r'$': 'field',
          r'$type': 'int',
          'name': 'count',
          'label': 'Count',
          'default': 0,
        },
      ),
      const _UiPaletteEntry(
        label: 'Code editor',
        subLabel: 'Syntax highlighted',
        icon: Icons.code,
        template: {
          r'$': 'field',
          r'$type': 'code',
          'name': 'source',
          'label': 'Source',
          'language': 'c',
          'default': '',
        },
      ),
      const _UiPaletteEntry(
        label: 'Log view',
        subLabel: 'Append-only list',
        icon: Icons.description,
        template: {
          r'$': 'field',
          r'$type': 'log',
          'name': 'output',
          'label': 'Output',
        },
      ),
      const _UiPaletteEntry(
        label: 'Icon picker',
        subLabel: 'Emoji or SVG',
        icon: Icons.image,
        template: {
          r'$': 'field',
          r'$type': 'icon',
          'name': 'icon',
          'label': 'Icon',
          'default': '',
        },
      ),
    ];
  }

  // ── Canvas ──────────────────────────────────────────────────────

  /// Center pane — a scrollable, click-to-select preview of the
  /// current screen. Each block renders as a mock widget that looks
  /// roughly like the real thing (text field, button, log viewer,
  /// etc.), wrapped in a [GestureDetector] that flips the selection
  /// and an outline decoration when selected. Drop zones sit between
  /// children so palette items and reordered blocks can be inserted
  /// at exact positions.
  Widget _buildUiCanvas(
      List<Map<String, dynamic>> screens, ColorScheme cs) {
    final active = screens[_uiActiveScreenIndex];
    return Container(
      color: cs.surface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
        children: [
          _buildCanvasHeader(active, cs),
          const SizedBox(height: 12),
          _buildCanvasBlock(active, const [], cs, asRoot: true),
        ],
      ),
    );
  }

  /// Thin bar above the canvas body that shows which screen we're
  /// editing plus its tip.
  Widget _buildCanvasHeader(Map<String, dynamic> screen, ColorScheme cs) {
    final name = (screen['name'] as String?) ?? 'Screen';
    final tip = (screen['tip'] as String?) ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.phone_android, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Text(
              name,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
        if (tip.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            tip,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ],
    );
  }

  /// Recursive canvas renderer. A block is drawn as:
  /// - container blocks (screen, group) → outlined card containing
  ///   its children interleaved with drop zones
  /// - leaf blocks (field, action, label) → a mock widget that
  ///   resembles the live rendering
  ///
  /// [path] is the chain of child indices that reaches this block
  /// from the active screen. The outermost call passes `const []`
  /// which addresses the screen itself. `asRoot` disables the outer
  /// outline + drag handle because the screen isn't draggable — it
  /// lives in the top-level `screens` array, not a `children` list.
  Widget _buildCanvasBlock(
    Map<String, dynamic> block,
    List<int> path,
    ColorScheme cs, {
    bool asRoot = false,
  }) {
    final kw = (block[r'$'] as String?) ?? 'block';
    final isContainer = kw == 'screen' || kw == 'group';
    final selected = _uiSelectedPath != null &&
        _listEquals(_uiSelectedPath!, path);

    final inner = isContainer
        ? _buildCanvasContainer(block, path, cs)
        : _buildCanvasLeaf(block, cs);

    // Selection outline. Also used to highlight containers so the
    // user sees the boundary of each group / screen even when not
    // selected.
    final outlineColor = selected
        ? cs.primary
        : isContainer
            ? cs.outlineVariant.withAlpha(140)
            : Colors.transparent;
    final outlineWidth = selected ? 2.0 : (isContainer ? 1.0 : 0.0);

    Widget wrapped = Container(
      margin: asRoot
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: selected
            ? cs.primaryContainer.withAlpha(60)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: outlineColor, width: outlineWidth),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _uiSelectedPath = path),
        child: Padding(
          padding: isContainer
              ? const EdgeInsets.fromLTRB(10, 10, 10, 10)
              : const EdgeInsets.fromLTRB(4, 4, 4, 4),
          child: inner,
        ),
      ),
    );

    // Non-root blocks are draggable so the user can grab them and
    // drop them into another container / position.
    if (!asRoot) {
      wrapped = LongPressDraggable<_UiDragPayload>(
        data: _UiDragPayload.fromMove(path),
        feedback: Material(
          elevation: 6,
          color: Colors.transparent,
          child: Opacity(
            opacity: 0.85,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: wrapped,
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: wrapped),
        delay: const Duration(milliseconds: 250),
        child: wrapped,
      );
    }

    return wrapped;
  }

  /// Build the interior of a container block: a header line with
  /// the keyword + name, then every child interleaved with drop
  /// zones so users can drop into exact positions.
  Widget _buildCanvasContainer(
      Map<String, dynamic> block, List<int> path, ColorScheme cs) {
    final kw = (block[r'$'] as String?) ?? 'block';
    final type = (block[r'$type'] as String?) ?? '';
    final name = (block['name'] as String?) ?? '';
    final children = (block['children'] as List?) ?? const [];

    // Special group renderings: show a chip stand-in so the user
    // understands these groups are rendered natively by the host
    // and don't have editable children in the WYSIWYG sense.
    final isSpecialGroup =
        kw == 'group' && const {
              'projects',
              'tasks',
              'map',
              'output',
              'sources',
              'ui-editor'
            }.contains(type);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(_uiIconForBlock(kw, type), size: 14, color: cs.primary),
            const SizedBox(width: 6),
            Text(
              kw.toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
                color: cs.primary,
              ),
            ),
            if (type.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(
                ':$type',
                style: TextStyle(
                  fontSize: 10,
                  color: cs.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (isSpecialGroup)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.secondaryContainer.withAlpha(120),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: cs.outlineVariant.withAlpha(120)),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_awesome,
                    size: 16, color: cs.onSecondaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This group is rendered natively by the host '
                    '(type: $type). It has no drag-and-drop children.',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          )
        else ...[
          _buildCanvasDropZone(path, 0, cs),
          for (var i = 0; i < children.length; i++)
            if (children[i] is Map<String, dynamic>) ...[
              _buildCanvasBlock(
                children[i] as Map<String, dynamic>,
                [...path, i],
                cs,
              ),
              _buildCanvasDropZone(path, i + 1, cs),
            ],
          if (children.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Drop blocks from the palette here',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// Drop-target thin bar placed between (or around) children of a
  /// container. When a drag hovers over it, it expands and highlights
  /// so the user sees exactly where the block will land.
  Widget _buildCanvasDropZone(
      List<int> parentPath, int insertIndex, ColorScheme cs) {
    return DragTarget<_UiDragPayload>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) =>
          _uiHandleDrop(details.data, parentPath, insertIndex),
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: active ? 26 : 8,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: active
                ? cs.primary.withAlpha(60)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active
                  ? cs.primary
                  : cs.outlineVariant.withAlpha(60),
              width: active ? 2 : 1,
              style: BorderStyle.solid,
            ),
          ),
          alignment: Alignment.center,
          child: active
              ? Text(
                  'Drop here',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                )
              : null,
        );
      },
    );
  }

  /// Render a leaf block (field / action / label) as a mock widget
  /// that resembles the live rendering: text fields show a placeholder
  /// TextField, actions show a real button styled the same way, etc.
  /// Everything is non-interactive so the user can click to select
  /// without accidentally editing the preview.
  Widget _buildCanvasLeaf(Map<String, dynamic> block, ColorScheme cs) {
    final kw = (block[r'$'] as String?) ?? '';
    if (kw == 'action') {
      final label = (block['label'] as String?) ?? 'Action';
      final style = (block['style'] as String?) ?? 'secondary';
      return IgnorePointer(
        child: switch (style) {
          'primary' => FilledButton(
              onPressed: () {},
              child: Text(label),
            ),
          'danger' => FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: cs.error,
                foregroundColor: cs.onError,
              ),
              onPressed: () {},
              child: Text(label),
            ),
          _ => OutlinedButton(
              onPressed: () {},
              child: Text(label),
            ),
        },
      );
    }
    if (kw == 'label') {
      final text = (block['text'] as String?) ?? '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text, style: const TextStyle(fontSize: 13)),
      );
    }
    if (kw == 'field') {
      final type = (block[r'$type'] as String?) ?? 'string';
      final label = (block['label'] as String?) ?? (block['name'] as String? ?? '');
      final tip = (block['tip'] as String?) ?? '';
      return _buildCanvasFieldMock(type, label, tip, block, cs);
    }
    // Unknown leaf — show generic pill.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        (block['name'] as String?) ?? kw,
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  /// Mock rendering for a `$type:"..."` field. Keeps the real
  /// Flutter widget shapes (TextField, Switch, …) so the preview
  /// matches what the user will see at runtime.
  Widget _buildCanvasFieldMock(
    String type,
    String label,
    String tip,
    Map<String, dynamic> block,
    ColorScheme cs,
  ) {
    final base = InputDecoration(
      labelText: label,
      helperText: tip.isEmpty ? null : tip,
      filled: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      isDense: true,
    );
    switch (type) {
      case 'bool':
        return SwitchListTile(
          value: (block['default'] as bool?) ?? false,
          title: Text(label),
          subtitle: tip.isEmpty ? null : Text(tip),
          onChanged: null,
          contentPadding: EdgeInsets.zero,
        );
      case 'int':
      case 'float':
        return IgnorePointer(
          child: TextField(
            controller: TextEditingController(
                text: '${block['default'] ?? ''}'),
            decoration: base,
          ),
        );
      case 'enum':
        return IgnorePointer(
          child: DropdownButtonFormField<String>(
            initialValue: null,
            decoration: base,
            items: const [],
            onChanged: (_) {},
          ),
        );
      case 'code':
        final lang = (block['language'] as String?) ?? 'text';
        return Container(
          height: 120,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(10),
            border:
                Border.all(color: cs.outlineVariant.withAlpha(100)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.isEmpty ? '$lang source' : label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Text(
                  '// $lang code editor\n// syntax highlighted at runtime',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.white54,
                  ),
                ),
              ),
            ],
          ),
        );
      case 'log':
        return Container(
          height: 120,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1020),
            borderRadius: BorderRadius.circular(10),
            border:
                Border.all(color: cs.outlineVariant.withAlpha(100)),
          ),
          child: Text(
            label.isEmpty ? 'Log output' : label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white70,
            ),
          ),
        );
      case 'icon':
        return Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.extension,
                  color: Colors.white, size: 26),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        );
      case 'string':
      default:
        final multiline = (block['multiline'] as bool?) ?? false;
        return IgnorePointer(
          child: TextField(
            controller: TextEditingController(
                text: '${block['default'] ?? ''}'),
            maxLines: multiline ? ((block['lines'] as num?)?.toInt() ?? 3) : 1,
            decoration: base,
          ),
        );
    }
  }

  // ── Drop handling ──────────────────────────────────────────────

  /// Insert or move a block based on a drag payload. Called from
  /// every drop zone.
  void _uiHandleDrop(
      _UiDragPayload data, List<int> parentPath, int insertIndex) {
    final raw = (_fieldValues['source_ui'] as String?) ?? '[]';
    final dynamic parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      return;
    }
    final screens = _uiScreensOf(parsed);
    if (_uiActiveScreenIndex >= screens.length) return;
    final activeScreen = screens[_uiActiveScreenIndex];

    if (data.kind == _UiDragKind.palette) {
      // Fresh insert from the palette — deep-copy the template.
      final block = _deepClone(data.payload!);
      _uiInsertBlockAt(activeScreen, parentPath, insertIndex, block);
      _uiPersist(screens);
      setState(() => _uiSelectedPath = [...parentPath, insertIndex]);
      return;
    }

    // Move existing block.
    final sourcePath = data.movePath!;
    if (sourcePath.isEmpty) return; // can't move the screen itself
    // Avoid dropping a block into its own subtree.
    if (_isDescendant(parentPath, sourcePath)) return;
    final sourceParentPath = sourcePath.sublist(0, sourcePath.length - 1);
    final sourceParent = _uiLookup(activeScreen, sourceParentPath);
    if (sourceParent == null) return;
    final sourceKidsRaw = sourceParent['children'];
    if (sourceKidsRaw is! List) return;
    final sourceKids = sourceKidsRaw;
    final sourceIndex = sourcePath.last;
    if (sourceIndex < 0 || sourceIndex >= sourceKids.length) return;
    final movingBlock = sourceKids.removeAt(sourceIndex);

    // Adjust the insert index if the source was a sibling earlier
    // in the same parent (removing it shifts everyone up by one).
    var adjustedInsert = insertIndex;
    final sameParent = _listEquals(sourceParentPath, parentPath);
    if (sameParent && sourceIndex < adjustedInsert) {
      adjustedInsert--;
    }
    _uiInsertBlockAt(
        activeScreen, parentPath, adjustedInsert, movingBlock as Map<String, dynamic>);
    _uiPersist(screens);
    setState(() => _uiSelectedPath = [...parentPath, adjustedInsert]);
  }

  void _uiInsertBlockAt(
    Map<String, dynamic> activeScreen,
    List<int> parentPath,
    int insertIndex,
    Map<String, dynamic> block,
  ) {
    final parent = _uiLookup(activeScreen, parentPath);
    if (parent == null) return;
    var kidsRaw = parent['children'];
    List<dynamic> kids;
    if (kidsRaw is List) {
      kids = kidsRaw;
    } else {
      kids = <dynamic>[];
      parent['children'] = kids;
    }
    final clamped = insertIndex < 0
        ? 0
        : (insertIndex > kids.length ? kids.length : insertIndex);
    kids.insert(clamped, block);
  }

  /// True when [path] is inside the subtree rooted at [ancestor].
  bool _isDescendant(List<int> path, List<int> ancestor) {
    if (ancestor.isEmpty) return false;
    if (path.length < ancestor.length) return false;
    for (var i = 0; i < ancestor.length; i++) {
      if (path[i] != ancestor[i]) return false;
    }
    return true;
  }

  /// Deep clone a JSON-shaped map so palette templates are inserted
  /// as independent instances. `jsonDecode(jsonEncode(x))` is the
  /// canonical way to deep-copy a JSON value in Dart.
  Map<String, dynamic> _deepClone(Map<String, dynamic> source) {
    return jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  }

  // ── Inspector (right pane) ─────────────────────────────────────

  /// Right-side pane — edits the scalar attributes of the currently
  /// selected block. Fields are typed (Switch for bool, number
  /// keyboard for num, text area for `multiline` strings) so the
  /// user isn't just typing into a JSON string.
  Widget _buildUiInspector(
      List<Map<String, dynamic>> screens, ColorScheme cs) {
    final selected = _uiSelectedPath;
    if (selected == null) {
      return Container(
        color: cs.surfaceContainerLow,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Click a block on the canvas to edit its properties.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
        ),
      );
    }
    final active = screens[_uiActiveScreenIndex];
    final block = _uiLookup(active, selected);
    if (block == null) {
      return Container(
        color: cs.surfaceContainerLow,
        child: Center(
          child: Text(
            'Selection is stale — pick another block.',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }
    final kw = (block[r'$'] as String?) ?? 'block';
    final type = (block[r'$type'] as String?) ?? '';
    final isRoot = selected.isEmpty;

    return Container(
      color: cs.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        children: [
          Row(
            children: [
              Icon(_uiIconForBlock(kw, type),
                  size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  kw.toUpperCase() + (type.isNotEmpty ? ' : $type' : ''),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              if (!isRoot)
                IconButton(
                  onPressed: _uiDeleteSelected,
                  icon: Icon(Icons.delete_outline, color: cs.error),
                  tooltip: 'Delete',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 12),
          for (final field in _uiInspectorFields(block))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: field,
            ),
          if (!isRoot) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => _uiMoveSelected(-1),
                  icon: const Icon(Icons.arrow_upward, size: 14),
                  label: const Text('Up'),
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  onPressed: () => _uiMoveSelected(1),
                  icon: const Icon(Icons.arrow_downward, size: 14),
                  label: const Text('Down'),
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Produce per-attribute editor widgets for [block]. Skips
  /// `children` (edited via drag-drop) and uses typed widgets for
  /// known attribute shapes.
  List<Widget> _uiInspectorFields(Map<String, dynamic> block) {
    final widgets = <Widget>[];
    final keys = [
      for (final k in block.keys)
        if (k != 'children') k
    ];
    for (final key in keys) {
      final v = block[key];
      widgets.add(_uiInspectorField(key, v));
    }
    return widgets;
  }

  /// Single attribute editor. Picks the right widget based on the
  /// current value's type.
  Widget _uiInspectorField(String key, dynamic value) {
    if (value is bool) {
      return SwitchListTile(
        title: Text(key, style: const TextStyle(fontSize: 12)),
        value: value,
        contentPadding: EdgeInsets.zero,
        dense: true,
        onChanged: (v) => _uiUpdateAttributeTyped(key, v),
      );
    }
    if (value is num) {
      return TextField(
        controller: TextEditingController(text: value.toString()),
        decoration: InputDecoration(
          labelText: key,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
        keyboardType: const TextInputType.numberWithOptions(
            signed: true, decimal: true),
        onChanged: (v) {
          final parsed = num.tryParse(v);
          if (parsed != null) _uiUpdateAttributeTyped(key, parsed);
        },
      );
    }
    // String (or missing) fallback. Use multiline for `default` when
    // the block is marked multiline, and for `tip` which is often
    // long.
    final s = value?.toString() ?? '';
    final wantsMulti = key == 'tip' || (key == 'default' && s.contains('\n'));
    return TextField(
      controller: TextEditingController(text: s),
      decoration: InputDecoration(
        labelText: key,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      maxLines: wantsMulti ? 4 : 1,
      minLines: wantsMulti ? 2 : 1,
      onChanged: (v) => _uiUpdateAttributeTyped(key, v),
    );
  }

  /// Updater that preserves the value's JSON type. Used from the
  /// inspector widgets that already know whether they're editing a
  /// bool / num / string.
  void _uiUpdateAttributeTyped(String key, dynamic value) {
    final path = _uiSelectedPath;
    if (path == null) return;
    final raw = (_fieldValues['source_ui'] as String?) ?? '[]';
    try {
      final parsed = jsonDecode(raw);
      final screens = _uiScreensOf(parsed);
      if (_uiActiveScreenIndex >= screens.length) return;
      final block = _uiLookup(screens[_uiActiveScreenIndex], path);
      if (block == null) return;
      block[key] = value;
      _uiPersist(screens);
    } catch (_) {}
  }

  // ── Translations editor ───────────────────────────────────────

  /// App Creator Translations tab — per-locale key/value table
  /// editor for the wapp's `lang/<locale>.json` sidecars. The
  /// authoritative state lives in
  /// `_fieldValues['translations']` as
  /// `Map<String /*locale*/, Map<String, String>>`, seeded by
  /// [_loadProject] and shipped through [WappInstallerService] on
  /// install. Empty string values are kept so the extract-keys
  /// button can surface untranslated stubs.
  Widget _buildTranslationsScreen() {
    final cs = Theme.of(context).colorScheme;
    final translations = _translationsMap();

    // Sorted locale list for the dropdown. Always includes `en`
    // as the de-facto fallback so authors can start there even
    // when no lang/*.json files exist yet.
    final locales = translations.keys.toList()..sort();
    if (locales.isEmpty) locales.add('en');
    // Clamp the active selection to something valid.
    if (_translationsLocale == null ||
        !locales.contains(_translationsLocale)) {
      _translationsLocale = locales.first;
    }
    final activeLocale = _translationsLocale!;
    final currentMap = translations.putIfAbsent(
        activeLocale, () => <String, String>{});

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Text(
          'Translations',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'Each locale becomes a lang/<code>.json sidecar inside '
          'the wapp package. Strings in the UI prefixed with @key '
          'resolve to the value below at runtime — the fallback '
          'chain is exact tag → language-only → en → the literal '
          'key.',
          style: TextStyle(color: cs.onSurfaceVariant, height: 1.35),
        ),
        const SizedBox(height: 12),

        // Persistence banner + save button. Typing into the rows
        // below only mutates the in-memory bindings — the actual
        // lang/*.json sidecars are written by the installer, which
        // also writes everything else (source, UI, icon, …). The
        // Save button is a convenience that triggers the same code
        // path Install on the Code tab does, so the author can
        // commit translations without tab-hopping.
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withAlpha(80),
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: cs.outlineVariant.withAlpha(100)),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Edits are kept in memory while you type. '
                  'Click Save to write every lang/<locale>.json '
                  'sidecar to disk (same as clicking Install '
                  'on the Code tab).',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onPrimaryContainer,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _translationsSaveToDisk,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('Save'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Locale picker + add / remove buttons.
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: activeLocale,
                decoration: InputDecoration(
                  labelText: 'Locale',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                items: [
                  for (final code in locales)
                    DropdownMenuItem(
                      value: code,
                      child: Text(
                        '$code  (${currentMap.length} key'
                        '${currentMap.length == 1 ? '' : 's'})'
                        .replaceAll(
                            '${currentMap.length}', '${translations[code]?.length ?? 0}'),
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _translationsLocale = v);
                },
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _translationsAddLocale,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add locale'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: activeLocale == 'en'
                  ? null
                  : () => _translationsRemoveLocale(activeLocale),
              icon: Icon(Icons.delete_outline,
                  size: 16, color: cs.error),
              label: Text('Remove',
                  style: TextStyle(color: cs.error)),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Toolbar: extract @keys from UI + add a blank key.
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: () => _translationsExtractKeys(activeLocale),
              icon: const Icon(Icons.auto_fix_high, size: 16),
              label: const Text('Extract @keys from UI'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _translationsAddKey(activeLocale),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add key'),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Key/value rows.
        if (currentMap.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.outlineVariant.withAlpha(80)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: cs.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'No keys yet. Click "Extract @keys from UI" to '
                    'scan the UI tab for references, or "Add key" '
                    'to create one manually.',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          )
        else
          for (final key in (currentMap.keys.toList()..sort()))
            _buildTranslationsRow(activeLocale, key, currentMap[key] ?? '', cs),
      ],
    );
  }

  Widget _buildTranslationsRow(
      String locale, String key, String value, ColorScheme cs) {
    // Use a keyed TextEditingController so the row survives locale
    // switches without dropping the user's in-flight edit.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant.withAlpha(80)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.key_outlined,
                    size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    key,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _translationsRemoveKey(locale, key),
                  icon: Icon(Icons.close, size: 16, color: cs.error),
                  tooltip: 'Remove key',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            TextField(
              controller: TextEditingController(text: value),
              decoration: InputDecoration(
                hintText: value.isEmpty ? '(untranslated)' : null,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              maxLines: 3,
              minLines: 1,
              onChanged: (v) => _translationsSetValue(locale, key, v),
            ),
          ],
        ),
      ),
    );
  }

  /// Shortcut used by the Translations tab's Save button. Fires the
  /// same `_handleInstall` path the Code tab's Install action uses,
  /// so every `lang/<locale>.json` sidecar lands on disk without the
  /// author having to switch tabs. The payload fields are drawn
  /// directly from the current bindings (title, id, name,
  /// description, source_ui) so the installer's downstream logic
  /// sees exactly the same inputs.
  Future<void> _translationsSaveToDisk() async {
    final id = (_fieldValues['wapp_id'] as String?) ?? '';
    if (id.isEmpty) {
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Cannot save translations',
        body: 'Open or create a project first (ID is empty).',
        source: 'host:app-creator',
      ));
      return;
    }
    await _handleInstall(<String, dynamic>{
      'id': id,
      'title': (_fieldValues['wapp_title'] as String?) ?? '',
      'name': (_fieldValues['wapp_name'] as String?) ?? '',
      'description':
          (_fieldValues['wapp_description'] as String?) ?? '',
      'source_ui': (_fieldValues['source_ui'] as String?) ?? '',
    });
  }

  /// Convert whatever's sitting in `_fieldValues['translations']`
  /// into the strongly-typed shape the installer expects. Returns
  /// null when there's nothing usable so the installer can skip
  /// the lang/ write path entirely.
  Map<String, Map<String, String>>? _coerceTranslations(dynamic raw) {
    if (raw is Map<String, Map<String, String>>) {
      return raw.isEmpty ? null : raw;
    }
    if (raw is Map) {
      final out = <String, Map<String, String>>{};
      for (final e in raw.entries) {
        final loc = e.key.toString();
        final inner = e.value;
        if (inner is Map) {
          final map = <String, String>{};
          for (final kv in inner.entries) {
            map[kv.key.toString()] = kv.value?.toString() ?? '';
          }
          if (map.isNotEmpty) out[loc] = map;
        }
      }
      return out.isEmpty ? null : out;
    }
    return null;
  }

  /// Access (or lazily create) the nested translations map inside
  /// `_fieldValues`. Returns a live reference so mutations persist
  /// without a manual writeback.
  Map<String, Map<String, String>> _translationsMap() {
    var existing = _fieldValues['translations'];
    if (existing is Map<String, Map<String, String>>) return existing;
    // Be tolerant of stale shapes: rebuild from scratch with a
    // proper typed map if the binding was seeded as plain dynamic
    // (e.g. by JSON deserialisation of a loaded project).
    final next = <String, Map<String, String>>{};
    if (existing is Map) {
      for (final e in existing.entries) {
        final loc = e.key.toString();
        final raw = e.value;
        if (raw is Map) {
          final inner = <String, String>{};
          for (final kv in raw.entries) {
            inner[kv.key.toString()] = kv.value?.toString() ?? '';
          }
          next[loc] = inner;
        }
      }
    }
    _fieldValues['translations'] = next;
    return next;
  }

  void _translationsSetValue(String locale, String key, String value) {
    final map = _translationsMap();
    final inner = map.putIfAbsent(locale, () => <String, String>{});
    inner[key] = value;
    // No setState — the text field is controlled by its own
    // controller; we only need the mutation to land in the
    // bindings so Install picks it up.
  }

  Future<void> _translationsAddLocale() async {
    final controller = TextEditingController();
    final locale = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add locale'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Short tag, e.g. en, pt, de, fr, pt_BR.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Locale code',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (locale == null || locale.isEmpty) return;
    final map = _translationsMap();
    if (map.containsKey(locale)) {
      setState(() => _translationsLocale = locale);
      return;
    }
    // Seed the new locale with every key that already exists in
    // `en` (or in the first existing locale) so the author has a
    // sensible starting point instead of an empty table.
    final seed = map['en'] ?? (map.isNotEmpty ? map.values.first : null);
    final fresh = <String, String>{};
    if (seed != null) {
      for (final k in seed.keys) {
        fresh[k] = '';
      }
    }
    map[locale] = fresh;
    setState(() => _translationsLocale = locale);
  }

  void _translationsRemoveLocale(String locale) {
    final map = _translationsMap();
    map.remove(locale);
    setState(() {
      if (_translationsLocale == locale) {
        _translationsLocale =
            map.keys.isEmpty ? null : map.keys.first;
      }
    });
  }

  Future<void> _translationsAddKey(String locale) async {
    final controller = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add translation key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Dot-separated name like `settings.title_label`. '
              'The UI refers to it as `@settings.title_label`.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Key',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (key == null || key.isEmpty) return;
    final map = _translationsMap();
    // Add the key to EVERY locale so the row shows up everywhere.
    // Empty value for locales that don't have it yet.
    for (final loc in map.keys) {
      map[loc]!.putIfAbsent(key, () => '');
    }
    // Seed into the active locale too if the map was empty.
    map.putIfAbsent(locale, () => <String, String>{})[key] ??= '';
    setState(() {});
  }

  void _translationsRemoveKey(String locale, String key) {
    final map = _translationsMap();
    // Removing a key from one locale removes it from all of them
    // so the author's locale tables stay in sync.
    for (final loc in map.keys) {
      map[loc]?.remove(key);
    }
    setState(() {});
  }

  /// Walk the current UI JSON looking for every `@key` reference in
  /// any string field and add the missing keys to every locale with
  /// an empty value. Never overwrites an existing translation.
  void _translationsExtractKeys(String locale) {
    final rawUi = (_fieldValues['source_ui'] as String?) ?? '';
    if (rawUi.trim().isEmpty) return;
    final discovered = <String>{};
    try {
      final parsed = jsonDecode(rawUi);
      _translationsWalk(parsed, discovered);
    } catch (_) {
      return;
    }
    if (discovered.isEmpty) return;
    final map = _translationsMap();
    // Create the active locale if it doesn't exist yet.
    final target = map.putIfAbsent(locale, () => <String, String>{});
    for (final key in discovered) {
      target.putIfAbsent(key, () => '');
      // Mirror the empty stub into every other locale so the row
      // renders across the dropdown consistently.
      for (final loc in map.keys) {
        if (loc != locale) map[loc]!.putIfAbsent(key, () => '');
      }
    }
    setState(() {});
  }

  /// Recursive walker for [_translationsExtractKeys]. Collects any
  /// string value (at any depth) that starts with `@` and looks
  /// like a valid key (no whitespace).
  void _translationsWalk(dynamic node, Set<String> out) {
    if (node is Map) {
      for (final v in node.values) {
        _translationsWalk(v, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _translationsWalk(v, out);
      }
    } else if (node is String) {
      if (node.startsWith('@') && node.length > 1 &&
          !node.contains(' ') && !node.contains('\n')) {
        out.add(node.substring(1));
      }
    }
  }

  /// Walk [screen] along [path] and return the leaf block (mutable
  /// reference into the dynamic tree). Returns null when any index
  /// runs off the end of its parent's `children` array.
  Map<String, dynamic>? _uiLookup(
      Map<String, dynamic> screen, List<int> path) {
    dynamic current = screen;
    for (final i in path) {
      if (current is! Map) return null;
      final kids = current['children'];
      if (kids is! List || i < 0 || i >= kids.length) return null;
      current = kids[i];
    }
    return current is Map<String, dynamic> ? current : null;
  }

  /// Delete the currently-selected block from its parent's children
  /// array. Cannot delete the screen itself — the inspector hides
  /// the button in that case.
  void _uiDeleteSelected() {
    final path = _uiSelectedPath;
    if (path == null || path.isEmpty) return;
    final raw = (_fieldValues['source_ui'] as String?) ?? '[]';
    try {
      final parsed = jsonDecode(raw);
      final screens = _uiScreensOf(parsed);
      if (_uiActiveScreenIndex >= screens.length) return;
      final parentPath = path.sublist(0, path.length - 1);
      final parent =
          _uiLookup(screens[_uiActiveScreenIndex], parentPath);
      if (parent == null) return;
      final kids = parent['children'];
      if (kids is! List) return;
      final idx = path.last;
      if (idx < 0 || idx >= kids.length) return;
      kids.removeAt(idx);
      _uiPersist(screens);
      setState(() => _uiSelectedPath = null);
    } catch (_) {}
  }

  /// Shift the selected block up (delta = -1) or down (delta = +1)
  /// within its siblings. Clamped to the children array bounds.
  void _uiMoveSelected(int delta) {
    final path = _uiSelectedPath;
    if (path == null || path.isEmpty) return;
    final raw = (_fieldValues['source_ui'] as String?) ?? '[]';
    try {
      final parsed = jsonDecode(raw);
      final screens = _uiScreensOf(parsed);
      if (_uiActiveScreenIndex >= screens.length) return;
      final parentPath = path.sublist(0, path.length - 1);
      final parent =
          _uiLookup(screens[_uiActiveScreenIndex], parentPath);
      if (parent == null) return;
      final kids = parent['children'];
      if (kids is! List) return;
      final idx = path.last;
      final target = idx + delta;
      if (target < 0 || target >= kids.length) return;
      final block = kids.removeAt(idx);
      kids.insert(target, block);
      _uiPersist(screens);
      setState(() => _uiSelectedPath = [...parentPath, target]);
    } catch (_) {}
  }

  /// Append a new blank screen to the top-level list and select it.
  void _uiNewScreen() {
    final raw = (_fieldValues['source_ui'] as String?) ?? '';
    List<Map<String, dynamic>> screens;
    try {
      final parsed =
          raw.trim().isEmpty ? <dynamic>[] : jsonDecode(raw);
      screens = _uiScreensOf(parsed);
    } catch (_) {
      screens = <Map<String, dynamic>>[];
    }
    final next = <String, dynamic>{
      r'$': 'screen',
      'name': 'Screen ${screens.length + 1}',
      'children': <dynamic>[],
    };
    screens.add(next);
    _uiPersist(screens);
    setState(() {
      _uiActiveScreenIndex = screens.length - 1;
      _uiSelectedPath = const [];
    });
  }

  /// Pick a representative Material icon for a block keyword+type so
  /// the tree rows have a quick visual anchor. Keyword wins when
  /// there is no specific type override.
  IconData _uiIconForBlock(String keyword, String type) {
    final kwLower = keyword.toLowerCase();
    final typeLower = type.toLowerCase();
    if (kwLower == 'screen') return Icons.web;
    if (kwLower == 'group') {
      if (typeLower == 'projects') return Icons.folder_open;
      if (typeLower == 'tasks') return Icons.task_alt;
      if (typeLower == 'map') return Icons.map;
      if (typeLower == 'output') return Icons.receipt_long;
      if (typeLower == 'sources') return Icons.cloud;
      if (typeLower == 'ui-editor') return Icons.account_tree;
      return Icons.folder_special;
    }
    if (kwLower == 'field') {
      if (typeLower == 'code') return Icons.code;
      if (typeLower == 'log') return Icons.description;
      if (typeLower == 'icon') return Icons.image;
      if (typeLower == 'bool') return Icons.toggle_on;
      if (typeLower == 'int' || typeLower == 'float') return Icons.numbers;
      if (typeLower == 'enum') return Icons.list;
      return Icons.text_fields;
    }
    if (kwLower == 'action') return Icons.smart_button;
    if (kwLower == 'label') return Icons.label;
    return Icons.widgets;
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Widget _buildSourcesScreen() {
    final cs = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Header.
        Text(
          'Repositories',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'The wapp store downloads its catalog from every repository '
          'listed here. New entries are validated — only URLs that '
          'reply with a valid /wapps/index.json are accepted.',
          style: TextStyle(color: cs.onSurfaceVariant, height: 1.35),
        ),
        const SizedBox(height: 20),

        // Existing repositories list.
        if (!_sourcesLoaded)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_storeSources.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.outlineVariant.withAlpha(80)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No repositories yet. Add one below to see wapps '
                    'in the Store tab.',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          )
        else
          for (var i = 0; i < _storeSources.length; i++)
            _buildSourceRow(_storeSources[i], i, cs),

        const SizedBox(height: 24),

        // Add new.
        Text(
          'Add a repository',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.outlineVariant.withAlpha(80)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _sourcesInputController,
                      enabled: !_sourcesBusy,
                      decoration: InputDecoration(
                        hintText: 'https://example.com',
                        prefixIcon: const Icon(Icons.link, size: 20),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _addSource(),
                      onChanged: (_) {
                        if (_sourcesError.isNotEmpty) {
                          setState(() => _sourcesError = '');
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: _sourcesBusy ? null : _addSource,
                    icon: _sourcesBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14),
                    ),
                  ),
                ],
              ),
              if (_sourcesError.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.error_outline, size: 16, color: cs.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _sourcesError,
                        style: TextStyle(fontSize: 12, color: cs.error),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'The store will try <url>/wapps/index.json first, then '
                '<url>/index.json. For local paths, pass the directory '
                'that contains the index.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// One row inside the repositories list — shows the host chip,
  /// the raw URL in monospace, and a red remove button.
  Widget _buildSourceRow(String url, int index, ColorScheme cs) {
    final host = _extractHostForDisplay(url);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withAlpha(80)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.cloud_outlined,
                size: 20, color: cs.onPrimaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  host,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  url,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _sourcesBusy ? null : () => _removeSource(index),
            icon: Icon(Icons.delete_outline, color: cs.error),
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }

  /// Human-readable host extracted from a URL / path. Mirrors the
  /// wapp's own `extract_host` behaviour so chips look the same on
  /// both sides.
  String _extractHostForDisplay(String url) {
    var p = url;
    if (p.startsWith('https://')) {
      p = p.substring(8);
    } else if (p.startsWith('http://')) {
      p = p.substring(7);
    } else {
      return 'local';
    }
    final end = p.indexOf(RegExp(r'[/:?]'));
    return end < 0 ? p : p.substring(0, end);
  }

  /// Kick off the Add flow: validate the URL, and if it passes,
  /// append it to [_storeSources] and push the new list to the wapp.
  Future<void> _addSource() async {
    final raw = _sourcesInputController.text.trim();
    if (raw.isEmpty) return;
    if (_storeSources.contains(raw)) {
      setState(() => _sourcesError = 'This repository is already in the list.');
      return;
    }
    setState(() {
      _sourcesBusy = true;
      _sourcesError = '';
    });
    try {
      final resolved = await _validateSource(raw);
      if (resolved == null) {
        if (mounted) {
          setState(() {
            _sourcesBusy = false;
            _sourcesError =
                'Could not find a valid index.json at this URL. '
                'Check the address and try again.';
          });
        }
        return;
      }
      if (_storeSources.contains(resolved)) {
        if (mounted) {
          setState(() {
            _sourcesBusy = false;
            _sourcesError =
                'This repository is already in the list (as $resolved).';
          });
        }
        return;
      }
      final next = [..._storeSources, resolved];
      _pushSources(next);
      if (mounted) {
        _sourcesInputController.clear();
        setState(() {
          _sourcesBusy = false;
          _sourcesError = '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _sourcesBusy = false;
          _sourcesError = 'Validation failed: $e';
        });
      }
    }
  }

  /// Drop the entry at [index] from [_storeSources] and push the
  /// shorter list back to the wapp. The wapp will echo the new
  /// store.sources and trigger a catalog refresh.
  void _removeSource(int index) {
    if (index < 0 || index >= _storeSources.length) return;
    final next = [..._storeSources];
    next.removeAt(index);
    _pushSources(next);
  }

  /// Send the authoritative sources list back to the wapp as a
  /// `set_sources` action. The wapp persists, re-parses, re-fetches,
  /// and echoes store.sources so this widget rebuilds with the
  /// confirmed state.
  void _pushSources(List<String> next) {
    _fieldValues['source'] = next.join('\n');
    setState(() => _storeSources = next);
    _engine.sendMessage(jsonEncode({
      'type': 'action',
      'action': 'set_sources',
      'fields': {'source': next.join('\n')},
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  /// Probe [raw] for a valid wapp index. Tries `<raw>/wapps/index.json`
  /// first, falls back to `<raw>/index.json`, and finally accepts the
  /// bare URL if it already points at a `.json` file. Returns the
  /// normalised URL that will be stored on success, or null on
  /// failure. Local paths are checked via filesystem I/O.
  Future<String?> _validateSource(String raw) async {
    final lowered = raw.toLowerCase();
    final isUrl = lowered.startsWith('http://') || lowered.startsWith('https://');
    if (isUrl) {
      // Build candidate URLs to try in priority order.
      final trimmed = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
      final candidates = <String>[];
      if (lowered.endsWith('.json')) {
        candidates.add(raw);
      } else {
        candidates.add('$trimmed/wapps/index.json');
        candidates.add('$trimmed/index.json');
      }
      for (final candidate in candidates) {
        if (await _probeJsonUrl(candidate)) {
          // Store the candidate that worked — the wapp uses it as-is
          // because it ends with .json.
          return candidate;
        }
      }
      return null;
    }
    // Local filesystem candidates. Skipped entirely on web — the
    // browser has no filesystem so a local path here is nonsense.
    if (kIsWeb) return null;
    final candidates = <String>[];
    if (lowered.endsWith('.json')) {
      candidates.add(raw);
    } else {
      final base =
          raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
      candidates.add('$base/wapps/index.json');
      candidates.add('$base/index.json');
    }
    for (final candidate in candidates) {
      try {
        final bytes = platform.readArbitraryFileBytesSync(candidate);
        if (bytes == null) continue;
        final contents = utf8.decode(bytes);
        try {
          final parsed = jsonDecode(contents);
          if (parsed is List) return candidate;
        } catch (_) {}
      } catch (_) {}
    }
    return null;
  }

  /// Fetch [url] and return true if it responds 200 with a JSON array
  /// body. Uses package:http so the same code runs on desktop (via
  /// dart:io sockets) and web (via browser fetch). Six-second
  /// deadline matches the previous HttpClient implementation.
  Future<bool> _probeJsonUrl(String url) async {
    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return false;
      final parsed = jsonDecode(resp.body);
      return parsed is List;
    } catch (_) {
      return false;
    }
  }

  Widget _buildOutputScreen() {
    // Parse output lines into wapp entries for card display. The wapp's
    // main.c still speaks a text-log protocol, so we regex-lift the
    // structured catalog rows out of it on the host side. Format:
    //   [info] N wapp(s) available:
    //   [out]   name            vX.Y.Z  (NKB)  [installed] or [update: ...]
    //   [out]     Description text
    //   [out]     @host.example.com       <- optional source chip
    //   [out]     by:npub1…              <- optional publisher chip
    //
    // The description / host / publisher lines all use a 4-space
    // indent and are attached to the most recently emitted wapp
    // entry. That lets the wapp emit them in any order without
    // needing a strict grammar on the host side.
    final wapps = <_CatalogWapp>[];
    final errors = <String>[];

    for (var i = 0; i < _outputLines.length; i++) {
      final line = _outputLines[i];
      final text = line.text;

      final match = RegExp(r'^\s{2}(\S+)\s+v(\S+)(?:\s+\(([^)]+)\))?(.*)$')
          .firstMatch(text);
      if (match != null && line.level == 'out') {
        final name = match.group(1)!;
        final version = match.group(2)!;
        final size = match.group(3) ?? '';
        final status = match.group(4)?.trim() ?? '';

        final actuallyInstalled = _installed.existsSync('$name/app.wasm');

        wapps.add(_CatalogWapp(
          name: name,
          version: version,
          size: size,
          installed: actuallyInstalled,
          updateAvailable: status.contains('[update:'),
        ));
        continue;
      }

      // Metadata line attached to the previously-added wapp. The
      // four-space indent is the wapp's way of saying "this belongs
      // to the entry above me".
      if (line.level == 'out' &&
          text.startsWith('    ') &&
          wapps.isNotEmpty) {
        final meta = text.trimLeft();
        final last = wapps.last;
        if (meta.startsWith('@')) {
          last.sourceHost = meta.substring(1);
        } else if (meta.startsWith('by:')) {
          last.publisherNpub = meta.substring(3);
        } else if (last.description.isEmpty) {
          last.description = meta;
        }
        continue;
      }

      if (line.level == 'err') {
        errors.add(text);
      }
    }

    // Enrich catalog entries with NDF store metadata.
    for (final wapp in wapps) {
      _enrichCatalogWapp(wapp);
    }

    final cs = Theme.of(context).colorScheme;
    final source = (_fieldValues['source'] as String?) ?? '';
    final query = _storeSearch.toLowerCase();
    final visibleWapps = query.isEmpty
        ? wapps
        : wapps
            .where((w) =>
                w.name.toLowerCase().contains(query) ||
                w.description.toLowerCase().contains(query))
            .toList();

    final hasCatalog = wapps.isNotEmpty;

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        // Store header — search + refresh + source chip. Pinned so it
        // stays visible while the catalog scrolls.
        // Plain adapter rather than a pinned persistent header — the
        // latter requires a fixed extent that Flutter's layout engine
        // clamps against the child's paintExtent, and any mismatch
        // throws "layoutExtent exceeds paintExtent" which tears down
        // the whole CustomScrollView before any card can render.
        // Losing the pin-on-scroll behaviour is a fair trade for a
        // store view that actually shows content.
        SliverToBoxAdapter(
          child: _buildStoreHeader(cs, total: wapps.length),
        ),

        // Featured banner for the first catalog entry — a little
        // Play-Store-flavoured spotlight on what's "new" in the repo.
        if (hasCatalog)
          SliverToBoxAdapter(
            child: _buildFeaturedCard(wapps.first, cs),
          ),

        // Error strip — only shown when the wapp emitted [err] lines.
        if (errors.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.errorContainer.withAlpha(120),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.error.withAlpha(120)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.error_outline, size: 18, color: cs.error),
                      const SizedBox(width: 8),
                      Text('Something went wrong',
                          style: TextStyle(
                              color: cs.onErrorContainer,
                              fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 6),
                    for (final err in errors)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(err,
                            style: TextStyle(
                                color: cs.onErrorContainer, fontSize: 12)),
                      ),
                  ],
                ),
              ),
            ),
          ),

        // Section heading above the list.
        if (hasCatalog)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Row(
                children: [
                  Text(
                    query.isEmpty ? 'All apps' : 'Results',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${visibleWapps.length}',
                      style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Empty / error states.
        if (!hasCatalog)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildStoreEmptyState(cs, source: source),
          )
        else if (visibleWapps.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'No wapps match "$_storeSearch"',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverGrid(
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.45,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) => _buildWappCard(visibleWapps[i], cs),
                childCount: visibleWapps.length,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStoreHeader(
    ColorScheme cs, {
    required int total,
  }) {
    return Container(
      color: cs.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: cs.outlineVariant.withAlpha(80)),
              ),
              child: TextField(
                textInputAction: TextInputAction.search,
                onChanged: (v) => setState(() => _storeSearch = v),
                decoration: InputDecoration(
                  hintText: 'Search wapps',
                  prefixIcon:
                      Icon(Icons.search, color: cs.onSurfaceVariant),
                  suffixIcon: _storeSearch.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _storeSearch = ''),
                        ),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: cs.surfaceContainerHigh,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                _sendCommand('list');
                _engine.handleEvent();
                _drainOutbox();
              },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(Icons.refresh, color: cs.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStoreEmptyState(ColorScheme cs, {required String source}) {
    final hasSource = source.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(28),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.storefront, size: 56, color: cs.primary),
          ),
          const SizedBox(height: 20),
          Text(
            hasSource ? 'Loading catalog…' : 'No repository configured',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            hasSource
                ? 'Fetching index.json from your repository. Use '
                    'Refresh above if the list stays empty.'
                : 'Set a repository URL or local path in the Settings tab, '
                    'then pull to refresh to see the wapps available for '
                    'install.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
          ),
          if (!hasSource) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                if (_tabController != null) _tabController!.animateTo(1);
              },
              icon: const Icon(Icons.settings, size: 18),
              label: const Text('Open settings'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFeaturedCard(_CatalogWapp wapp, ColorScheme cs) {
    final color = _storeCardColor(wapp.name);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withAlpha(180),
              color.withAlpha(90),
            ],
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(40),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withAlpha(90)),
              ),
              alignment: Alignment.center,
              child: _storeIconWidget(wapp.name, size: 40),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Featured',
                    style: TextStyle(
                      color: Colors.white.withAlpha(200),
                      fontSize: 11,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    wapp.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (wapp.description.isNotEmpty)
                    Text(
                      wapp.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withAlpha(230),
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                  const SizedBox(height: 10),
                  _storeActionButton(wapp, cs, dark: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Enrich a catalog wapp with NDF store metadata — reads
  /// `store/description.json` and `social.sqlite3` from the wapp
  /// package (installed copy or built-in archive).
  void _enrichCatalogWapp(_CatalogWapp wapp) {
    // Resolve the wapp's own package storage — installed copy first,
    // then built-in archive. Never fall back to the current wapp's
    // storage (_pkg) since that's the install wapp itself.
    Uint8List? _readFromWapp(String relativePath) {
      // 1. Installed copy
      if (_installed.existsSync('${wapp.name}/manifest.json')) {
        final bytes = ScopedProfileStorage(_installed, wapp.name)
            .readBytesSync(relativePath);
        if (bytes != null) return bytes;
      }
      // 2. Built-in archive
      final archivePkg = wappPackageStorage(
          '${platform.currentDirectory()}/../wapps/archive/${wapp.name}');
      return archivePkg.readBytesSync(relativePath);
    }

    final effectiveBytes = _readFromWapp('store/description.json');

    if (effectiveBytes != null) {
      try {
        final desc = jsonDecode(utf8.decode(effectiveBytes))
            as Map<String, dynamic>;
        final descriptions =
            desc['descriptions'] as Map<String, dynamic>? ?? {};
        // Resolve by active locale, fallback to en.
        final prefs = PreferencesService.instanceSync;
        final locale = prefs?.activeLocale() ?? 'en';
        final langCode = locale.split('_').first;
        final localeDesc = (descriptions[locale] ??
                descriptions[langCode] ??
                descriptions['en']) as Map<String, dynamic>?;
        if (localeDesc != null) {
          wapp.storeTitle =
              (localeDesc['title'] as String?) ?? '';
          wapp.storeSummary =
              (localeDesc['summary'] as String?) ?? '';
          wapp.storeBody =
              (localeDesc['body'] as String?) ?? '';
        }
        wapp.changelog = (desc['changelog'] as String?) ?? '';
        final shots = desc['screenshots'];
        if (shots is List) {
          wapp.screenshotPaths = shots.cast<String>();
        }
      } catch (_) {}
    }

    // Read permissions.json for interaction settings.
    final permBytes = _readFromWapp('permissions.json');
    if (permBytes != null) {
      try {
        final perm = jsonDecode(utf8.decode(permBytes))
            as Map<String, dynamic>;
        final access = perm['access'] as Map<String, dynamic>? ?? {};
        final commentAccess = access['comment'] as Map<String, dynamic>?;
        final reactAccess = access['react'] as Map<String, dynamic>?;
        wapp.permitComments =
            commentAccess?['type'] != 'none';
        wapp.permitLikes =
            reactAccess?['type'] != 'none';
      } catch (_) {}
    }

    // If no store description was found, try reading the manifest's
    // description field as a title fallback.
    if (wapp.storeTitle.isEmpty) {
      final manifestBytes = _readFromWapp('manifest.json');
      if (manifestBytes != null) {
        try {
          final m = jsonDecode(utf8.decode(manifestBytes))
              as Map<String, dynamic>;
          wapp.storeTitle = (m['description'] as String?) ?? '';
        } catch (_) {}
      }
    }

    // Read social.sqlite3 counts.
    if (!kIsWeb) {
      // Find the wapp directory path for the SQLite database.
      String? wappDir;
      if (_installed.existsSync('${wapp.name}/manifest.json')) {
        wappDir = _installed.getAbsolutePath(wapp.name);
      } else {
        final archiveDir =
            '${platform.currentDirectory()}/../wapps/archive/${wapp.name}';
        wappDir = archiveDir;
      }
      wapp.likeCount =
          WappSocialStore.instance.reactionCount(wappDir);
      wapp.commentCount =
          WappSocialStore.instance.commentCount(wappDir);
    }
  }

  Widget _buildWappCard(_CatalogWapp wapp, ColorScheme cs) {
    final tileColor = _storeCardColor(wapp.name);
    final profile = ProfileService.instance.activeProfile;
    final myNpub = profile?.npub ?? '';
    final liked = myNpub.isNotEmpty && wapp.permitLikes
        ? _isLiked(wapp)
        : false;
    // Title: store description > manifest description > name slug.
    // Avoid showing the name slug ("install") as title when we have
    // a proper human-readable name from the store description or
    // the manifest's description field.
    final displayTitle = wapp.storeTitle.isNotEmpty
        ? wapp.storeTitle
        : (wapp.description.isNotEmpty ? wapp.description : wapp.name);
    final displayDesc = wapp.storeSummary.isNotEmpty
        ? wapp.storeSummary
        : '';

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Icon + title row ──
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: tileColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: _storeIconWidget(wapp.name, size: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'v${wapp.version}',
                        style: TextStyle(
                            fontSize: 10, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Description ──
          if (displayDesc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: Text(
                displayDesc,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                  height: 1.3,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),

          const Spacer(),

          // ── Bottom bar: social + install ──
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 6, 6),
            child: Row(
              children: [
                // Like
                if (wapp.permitLikes)
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: myNpub.isNotEmpty
                        ? () => _toggleLike(wapp, myNpub)
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                            size: 14,
                            color: liked ? cs.primary : cs.onSurfaceVariant,
                          ),
                          if (wapp.likeCount > 0) ...[
                            const SizedBox(width: 3),
                            Text(
                              '${wapp.likeCount}',
                              style: TextStyle(
                                fontSize: 11,
                                color: liked
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                // Comment
                if (wapp.permitComments)
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _showComments(wapp),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.comment_outlined,
                              size: 14, color: cs.onSurfaceVariant),
                          if (wapp.commentCount > 0) ...[
                            const SizedBox(width: 3),
                            Text(
                              '${wapp.commentCount}',
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                const Spacer(),
                // Install / Update
                SizedBox(
                  height: 28,
                  child: _storeActionButton(wapp, cs),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Social actions ──────────────────────────────────────────────

  String _wappDirFor(_CatalogWapp wapp) {
    if (_installed.existsSync('${wapp.name}/manifest.json')) {
      return _installed.getAbsolutePath(wapp.name);
    }
    return '${platform.currentDirectory()}/../wapps/archive/${wapp.name}';
  }

  bool _isLiked(_CatalogWapp wapp) {
    final npub = ProfileService.instance.activeProfile?.npub ?? '';
    if (npub.isEmpty) return false;
    return WappSocialStore.instance.hasReacted(_wappDirFor(wapp), npub);
  }

  void _toggleLike(_CatalogWapp wapp, String npub) {
    final dir = _wappDirFor(wapp);
    final store = WappSocialStore.instance;
    if (store.hasReacted(dir, npub)) {
      // Find and remove the reaction.
      final reactions = store.reactions(dir);
      for (final r in reactions) {
        if (r['npub'] == npub) {
          store.removeReaction(dir, r['id'] as String);
          break;
        }
      }
      wapp.likeCount = (wapp.likeCount - 1).clamp(0, 999999);
    } else {
      final id =
          '${npub.hashCode.abs()}_${DateTime.now().millisecondsSinceEpoch}';
      store.addReaction(dir, id: id, npub: npub);
      wapp.likeCount++;
    }
    setState(() {});
  }

  void _showComments(_CatalogWapp wapp) {
    final dir = _wappDirFor(wapp);
    final store = WappSocialStore.instance;
    final comments = store.topLevelComments(dir);
    final profile = ProfileService.instance.activeProfile;
    final myNpub = profile?.npub ?? '';
    final commentController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final currentComments = store.topLevelComments(dir);
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (ctx, scrollController) {
                final cs = Theme.of(ctx).colorScheme;
                return Column(
                  children: [
                    // Handle
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: cs.onSurfaceVariant.withAlpha(80),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(
                        children: [
                          Text(
                            'Comments',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${currentComments.length}',
                            style: TextStyle(
                              fontSize: 14,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Comment list
                    Expanded(
                      child: currentComments.isEmpty
                          ? Center(
                              child: Text(
                                'No comments yet',
                                style: TextStyle(
                                    color: cs.onSurfaceVariant),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16),
                              itemCount: currentComments.length,
                              itemBuilder: (ctx, i) {
                                final c = currentComments[i];
                                final author = c['npub'] as String? ?? '';
                                final short = author.length > 16
                                    ? '${author.substring(0, 10)}...'
                                    : author;
                                final ts = c['created_at'] as int? ?? 0;
                                final date = DateTime
                                    .fromMillisecondsSinceEpoch(
                                        ts * 1000);
                                return Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.person_outline,
                                              size: 14,
                                              color:
                                                  cs.onSurfaceVariant),
                                          const SizedBox(width: 4),
                                          Text(
                                            short,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: cs.primary,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                          const Spacer(),
                                          Text(
                                            '${date.day}/${date.month}/${date.year}',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color:
                                                  cs.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        c['content'] as String? ?? '',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: cs.onSurface,
                                          height: 1.4,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    // Add comment input
                    if (myNpub.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                                color: cs.outlineVariant.withAlpha(80)),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: commentController,
                                style: const TextStyle(fontSize: 13),
                                decoration: InputDecoration(
                                  hintText: 'Add a comment...',
                                  isDense: true,
                                  contentPadding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 10),
                                  border: OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(20),
                                  ),
                                ),
                                onSubmitted: (text) {
                                  if (text.trim().isEmpty) return;
                                  final id =
                                      '${myNpub.hashCode.abs()}_${DateTime.now().millisecondsSinceEpoch}';
                                  store.addComment(dir,
                                      id: id,
                                      content: text.trim(),
                                      npub: myNpub);
                                  commentController.clear();
                                  wapp.commentCount++;
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.send,
                                  color: cs.primary, size: 20),
                              onPressed: () {
                                final text =
                                    commentController.text.trim();
                                if (text.isEmpty) return;
                                final id =
                                    '${myNpub.hashCode.abs()}_${DateTime.now().millisecondsSinceEpoch}';
                                store.addComment(dir,
                                    id: id,
                                    content: text,
                                    npub: myNpub);
                                commentController.clear();
                                wapp.commentCount++;
                                setSheetState(() {});
                                setState(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// Render the right-side action button for a store card. Same widget
  /// used by both the featured banner and the list cards — the `dark`
  /// flag flips it to a white-on-transparent variant for the banner's
  /// coloured background.
  Widget _storeActionButton(_CatalogWapp wapp, ColorScheme cs,
      {bool dark = false}) {
    // The store wapp itself (`install`) is what we're currently
    // running — there's no meaningful "install" action on its own
    // card, so show a muted "Running" chip.
    if (wapp.name == 'install') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: (dark ? Colors.white : cs.onSurfaceVariant).withAlpha(40),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          'Running',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: dark ? Colors.white : cs.onSurfaceVariant,
          ),
        ),
      );
    }

    if (wapp.installed && !wapp.updateAvailable) {
      return OutlinedButton.icon(
        onPressed: () => _uninstallWapp(wapp.name),
        icon: const Icon(Icons.check, size: 16),
        label: const Text('Installed'),
        style: OutlinedButton.styleFrom(
          foregroundColor: dark ? Colors.white : cs.primary,
          side: BorderSide(
              color: dark
                  ? Colors.white.withAlpha(160)
                  : cs.primary.withAlpha(120)),
          visualDensity: VisualDensity.compact,
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
      );
    }

    final label = wapp.updateAvailable ? 'Update' : 'Install';
    void onPressed() {
      _sendCommand('install ${wapp.name}');
      _engine.handleEvent();
      _drainOutbox();
    }

    if (dark) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(
            wapp.updateAvailable ? Icons.upgrade : Icons.download_rounded,
            size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          visualDensity: VisualDensity.compact,
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(
          wapp.updateAvailable ? Icons.upgrade : Icons.download_rounded,
          size: 16),
      label: Text(label),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  /// Resolve a wapp's `manifest.icon` sidecar SVG to its raw bytes
  /// for store-card rendering. Matches the priority the launcher
  /// grid uses for [WappManifest.svgIconPath]:
  ///
  ///   1. If the named wapp is the currently-running one, read its
  ///      package storage (works for the Install/Store wapp itself).
  ///   2. Otherwise, read from the active profile's installed-apps
  ///      folder. Catalog entries that haven't been installed yet
  ///      return null — the caller falls back to [wappIconFor].
  ///
  /// Returns null when no `.svg` path is declared or the sidecar
  /// doesn't exist in the storage. Using `readBytesSync` instead of
  /// a `File(path).existsSync()` lookup means the web fetch-based
  /// [MemoryProfileStorage] resolves identically to the desktop
  /// [FilesystemProfileStorage].
  Uint8List? _storeSvgBytesFor(String name) {
    // Try multiple sources for the wapp's manifest + icon:
    // 1. Current running wapp (if name matches)
    // 2. Installed copy under the profile
    // 3. Built-in archive
    final candidates = <ProfileStorage>[
      if (name == _wappName) _pkg,
      if (_installed.existsSync('$name/manifest.json'))
        ScopedProfileStorage(_installed, name),
      wappPackageStorage(
          '${platform.currentDirectory()}/../wapps/archive/$name'),
    ];

    for (final pkg in candidates) {
      final manifestBytes = pkg.readBytesSync('manifest.json');
      if (manifestBytes == null) continue;
      try {
        final manifest =
            jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
        final icon = manifest['icon'] as String?;
        if (icon == null || icon.isEmpty) continue;
        if (!icon.toLowerCase().endsWith('.svg')) continue;
        if (!icon.contains('/') && !icon.contains('\\')) continue;
        final svgBytes = pkg.readBytesSync(icon);
        if (svgBytes != null && svgBytes.isNotEmpty) return svgBytes;
      } catch (_) {}
    }
    return null;
  }

  /// Build the icon widget that goes inside a store card's coloured
  /// tile. Prefers the wapp's own SVG (matches the launcher grid),
  /// falls back to the shared Material heuristic. [size] matches the
  /// enclosing tile so a white-on-colour Material icon fills cleanly.
  /// SVGs pass through a srcIn white colour filter so wapps whose
  /// icons are authored in dark strokes still read cleanly on the
  /// coloured tile.
  Widget _storeIconWidget(String name, {required double size}) {
    const whiteFilter = ColorFilter.mode(Colors.white, BlendMode.srcIn);
    final svgBytes = _storeSvgBytesFor(name);
    if (svgBytes != null) {
      return Padding(
        padding: EdgeInsets.all(size * 0.12),
        child: SvgPicture.memory(
          svgBytes,
          fit: BoxFit.contain,
          theme: const SvgTheme(currentColor: Colors.white),
          placeholderBuilder: (_) => Icon(
            wappIconFor(name),
            size: size,
            color: Colors.white,
          ),
        ),
      );
    }
    return Icon(wappIconFor(name), size: size, color: Colors.white);
  }

  /// Small pill-shaped chip used on store cards to show origin and
  /// publisher metadata. Tooltipable so the user can hover-reveal a
  /// truncated npub. Keeps the visual weight light so it doesn't
  /// compete with the primary action button.
  Widget _storeMetaChip({
    required IconData icon,
    required String label,
    required ColorScheme cs,
    String? tooltip,
  }) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withAlpha(110)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurfaceVariant,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }

  /// Format a publisher identity for display on a store card. Given
  /// a bech32 npub (or any string), produces `X1ABCD (npub1abcd…wxyz)`
  /// — the X1-prefixed callsign derived from the key, followed by a
  /// shortened form of the key in parentheses. The full npub goes
  /// into the tooltip so the user can read or copy-paste it.
  /// Non-npub strings are shown as-is (truncated if long).
  String _formatPublisher(String raw) {
    if (raw.isEmpty) return '';
    String shortNpub;
    if (raw.length <= 16) {
      shortNpub = raw;
    } else {
      final head = raw.substring(0, 9);
      final tail = raw.substring(raw.length - 4);
      shortNpub = '$head…$tail';
    }
    if (!raw.toLowerCase().startsWith('npub1') || raw.length < 10) {
      return shortNpub;
    }
    // Callsign: X1 + first 4 chars after 'npub1', uppercased.
    final callsign = 'X1${raw.substring(5, 9).toUpperCase()}';
    return '$callsign ($shortNpub)';
  }

  /// Deterministic card-tile colour based on the wapp name so every
  /// entry has a stable, recognisable swatch.
  Color _storeCardColor(String name) {
    const palette = <Color>[
      Color(0xFF6750A4),
      Color(0xFF3F6CFF),
      Color(0xFF0A8754),
      Color(0xFFCC4A1B),
      Color(0xFF1E6091),
      Color(0xFF7B3F98),
      Color(0xFFCF8D2E),
      Color(0xFF2E7D32),
    ];
    return palette[name.hashCode.abs() % palette.length];
  }

  // ── Terminal screen ────────────────────────────────────────────────

  Widget _buildTerminalScreen() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: _outputLines.length,
            itemBuilder: (context, i) {
              final line = _outputLines[i];
              return Text(
                line.text,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: _outputColor(line.level),
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Colors.grey.shade800)),
          ),
          child: Row(
            children: [
              const Text('\$ ',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      color: Color(0xFF7EE787),
                      fontSize: 13)),
              Expanded(
                child: TextField(
                  controller: _cmdController,
                  autofocus: true,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: 'Type a command...',
                  ),
                  onSubmitted: (v) {
                    if (v.trim().isNotEmpty) _sendCommand(v.trim());
                    _cmdController.clear();
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Color _outputColor(String level) => switch (level) {
        'cmd' => const Color(0xFF7EE787),
        'err' || 'error' => const Color(0xFFF85149),
        'info' => const Color(0xFF58A6FF),
        'warn' || 'warning' => const Color(0xFFE3B341),
        _ => const Color(0xFFE6EDF3),
      };

  // ── Functionalities screen ─────────────────────────────────────────

  /// State for the "Try it" results, keyed by endpoint name.
  final Map<String, String> _tryResults = {};
  /// Input controllers for endpoint params, keyed by "endpoint.param".
  final Map<String, TextEditingController> _tryInputs = {};

  Widget _buildFunctionalitiesScreen() {
    final cs = Theme.of(context).colorScheme;
    final registry = FunctionalityRegistry.instance;
    final allIds = registry.allFunctionalityIds.toList()..sort();

    if (allIds.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No functionalities registered.\n\n'
            'Wapps declare functionalities in their manifest under '
            '"provides.functionalities". Install a wapp that provides '
            'one (e.g. Functionality Demo) to see it listed here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: allIds.length,
      itemBuilder: (context, index) {
        final funcId = allIds[index];
        final providers = registry.providersFor(funcId);
        return _buildFunctionalityCard(funcId, providers, cs);
      },
    );
  }

  Widget _buildFunctionalityCard(
      String funcId, List<WappManifest> providers, ColorScheme cs) {
    final def = FunctionalityRegistry.instance.defFor(funcId);
    final isCore = funcId.startsWith('hal.');
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant.withAlpha(60)),
      ),
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header bar ──
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            decoration: BoxDecoration(
              color: isCore
                  ? cs.primaryContainer.withAlpha(50)
                  : cs.tertiaryContainer.withAlpha(50),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: isCore ? cs.primary : cs.tertiary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isCore ? 'CORE' : 'WAPP',
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    funcId,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── Description ──
          if (def != null && def.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                def.description,
                style: TextStyle(
                    fontSize: 13, color: cs.onSurface, height: 1.3),
              ),
            ),
          // ── Providers ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Text('Providers',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                    letterSpacing: 0.3)),
          ),
          for (final provider in providers)
            _buildProviderRow(funcId, provider, providers, cs),
          // ── Endpoints ──
          if (def != null && def.endpoints.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text('Endpoints',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                      letterSpacing: 0.3)),
            ),
            for (final ep in def.endpoints)
              _buildEndpointRow(ep, cs),
            // Per-functionality JSON spec button
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: OutlinedButton.icon(
                onPressed: () =>
                    _showFunctionalitySpec(funcId, def, providers),
                icon: const Icon(Icons.data_object, size: 14),
                label: const Text('View JSON spec'),
                style: OutlinedButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 11),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _buildEndpointRow(EndpointDef ep, ColorScheme cs) {
    final result = _tryResults[ep.name];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(80),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withAlpha(50)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Method signature line
          Row(
            children: [
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: cs.onSurface,
                    ),
                    children: [
                      TextSpan(
                        text: ep.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: '(',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                      if (ep.params.isNotEmpty)
                        TextSpan(
                          text: ep.params
                              .map((p) => '${p.type} ${p.name}')
                              .join(', '),
                          style: TextStyle(
                            color: cs.primary,
                            fontSize: 12,
                          ),
                        ),
                      TextSpan(
                        text: ')',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer.withAlpha(120),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '→ ${ep.returns.type}',
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: cs.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ),
          // Description
          if (ep.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                ep.description,
                style: TextStyle(
                    fontSize: 11, color: cs.onSurfaceVariant, height: 1.3),
              ),
            ),
          // Parameters — input fields for each
          if (ep.params.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final p in ep.params)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 90,
                            child: RichText(
                              text: TextSpan(
                                style: TextStyle(
                                    fontSize: 11, fontFamily: 'monospace'),
                                children: [
                                  TextSpan(
                                    text: p.name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: cs.onSurface,
                                    ),
                                  ),
                                  TextSpan(
                                    text: ' ${p.type}',
                                    style: TextStyle(color: cs.primary),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SizedBox(
                              height: 32,
                              child: TextField(
                                controller: _tryInputs.putIfAbsent(
                                  '${ep.name}.${p.name}',
                                  () => TextEditingController(),
                                ),
                                style: const TextStyle(
                                    fontSize: 12, fontFamily: 'monospace'),
                                decoration: InputDecoration(
                                  hintText: p.description.isNotEmpty
                                      ? p.description
                                      : p.type,
                                  hintStyle: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurfaceVariant
                                          .withAlpha(120)),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 6),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                                keyboardType:
                                    p.type == 'int' || p.type == 'uint32' || p.type == 'uint64'
                                        ? TextInputType.number
                                        : TextInputType.text,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          // Returns
          if (ep.returns.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: RichText(
                text: TextSpan(
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  children: [
                    const TextSpan(
                        text: 'Returns: ',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(text: ep.returns.description),
                  ],
                ),
              ),
            ),
          // Try it button + result
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: FilledButton.icon(
              onPressed: () => _tryEndpoint(ep),
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Run'),
              style: FilledButton.styleFrom(
                textStyle: const TextStyle(fontSize: 12),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
            ),
          ),
          if (result != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(6),
                  border:
                      Border.all(color: cs.outlineVariant.withAlpha(80)),
                ),
                child: SelectableText(
                  result,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: cs.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showFunctionalitySpec(String funcId, FunctionalityDef def,
      List<WappManifest> providers) {
    final spec = <String, dynamic>{
      'functionality': funcId,
      'description': def.description,
      'providers': [
        for (final p in providers)
          {'id': p.id, 'name': p.title.isNotEmpty ? p.title : p.name},
      ],
      'endpoints': [
        for (final ep in def.endpoints)
          <String, dynamic>{
            'name': ep.name,
            'description': ep.description,
            'params': [
              for (final p in ep.params)
                <String, dynamic>{
                  'name': p.name,
                  'type': p.type,
                  if (p.description.isNotEmpty) 'description': p.description,
                },
            ],
            'returns': <String, dynamic>{
              'type': ep.returns.type,
              if (ep.returns.description.isNotEmpty)
                'description': ep.returns.description,
              if (ep.returns.fields.isNotEmpty) 'fields': ep.returns.fields,
            },
          },
      ],
    };
    final jsonText = const JsonEncoder.withIndent('  ').convert(spec);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ApiJsonExportPage(
          title: funcId,
          json: jsonText,
        ),
      ),
    );
  }

  void _tryEndpoint(EndpointDef ep) {
    // Collect input values from controllers.
    final args = <String, String>{};
    for (final p in ep.params) {
      final ctrl = _tryInputs['${ep.name}.${p.name}'];
      args[p.name] = ctrl?.text ?? '';
    }
    String result;
    try {
      result = _executeHalTest(ep.name, args);
    } catch (e) {
      result = 'Error: $e';
    }
    setState(() => _tryResults[ep.name] = result);
  }

  String _executeHalTest(String name, Map<String, String> args) {
    final now = DateTime.now();
    switch (name) {
      // ── Time ──
      case 'hal_time_ms':
        return '${now.millisecondsSinceEpoch} ms';
      case 'hal_time_epoch':
        return '${now.millisecondsSinceEpoch ~/ 1000} s\n${now.toIso8601String()}';

      // ── Platform / Heap ──
      case 'hal_platform':
        return platform.currentDirectory().isNotEmpty
            ? 'linux-desktop'
            : 'web';
      case 'hal_heap_free':
        return 'N/A on desktop (no heap limit)';

      // ── Log ──
      case 'hal_log':
        final level = int.tryParse(args['level'] ?? '') ?? 1;
        final msg = args['msg'] ?? '(empty)';
        final labels = ['DEBUG', 'INFO', 'WARN', 'ERROR'];
        final label = level >= 0 && level < 4 ? labels[level] : 'L$level';
        return '[$label] $msg\nLogged at ${now.toIso8601String()}';

      // ── Yield ──
      case 'hal_yield':
        return 'OK — no-op on desktop';

      // ── Sensors ──
      case 'hal_sensor_temperature':
        return 'INT32_MIN\nNo sensor hardware on this platform.\nOn ESP32: returns centidegrees C (e.g. 2500 = 25.00°C)';
      case 'hal_sensor_humidity':
        return 'INT32_MIN\nNo sensor hardware on this platform.\nOn ESP32: returns centipercent (e.g. 6500 = 65.00%)';
      case 'hal_sensor_battery':
        return 'INT32_MIN\nNo sensor hardware on this platform.\nOn ESP32: returns millivolts (e.g. 3700 = 3.7V)';
      case 'hal_sensor_gps_lat':
        return 'INT32_MIN\nNo GPS on this platform.\nOn device: returns latitude × 1e7';
      case 'hal_sensor_gps_lon':
        return 'INT32_MIN\nNo GPS on this platform.\nOn device: returns longitude × 1e7';

      // ── Display ──
      case 'hal_display_width':
        return '${MediaQuery.of(context).size.width.toInt()} px';
      case 'hal_display_height':
        return '${MediaQuery.of(context).size.height.toInt()} px';
      case 'hal_display_clear':
        return 'OK — display cleared (no-op on desktop)';
      case 'hal_display_text':
        final x = args['x'] ?? '0';
        final y = args['y'] ?? '0';
        final color = args['color'] ?? '1';
        final text = args['text'] ?? '';
        return 'Drew "$text" at ($x, $y) color=$color\n(No-op on desktop — renders on ESP32/embedded display)';
      case 'hal_display_pixel':
        return 'Drew pixel at (${args['x'] ?? 0}, ${args['y'] ?? 0}) color=${args['color'] ?? 0}\n(No-op on desktop)';
      case 'hal_display_rect':
        return 'Drew rect at (${args['x']}, ${args['y']}) ${args['w']}×${args['h']} color=${args['color']}\n(No-op on desktop)';
      case 'hal_display_flush':
        return 'OK — buffer flushed (no-op on desktop)';

      // ── GPIO ──
      case 'hal_gpio_mode':
        final modes = {0: 'INPUT', 1: 'OUTPUT', 2: 'INPUT_PULLUP'};
        final mode = int.tryParse(args['mode'] ?? '') ?? 0;
        return 'Pin ${args['pin'] ?? '?'} set to ${modes[mode] ?? 'UNKNOWN'}\n(No-op on desktop — ESP32 only)';
      case 'hal_gpio_read':
        return '0\nPin ${args['pin'] ?? '?'} (stub on desktop — always 0)';
      case 'hal_gpio_write':
        return 'OK — pin ${args['pin'] ?? '?'} = ${args['value'] ?? '?'}\n(No-op on desktop)';

      // ── LoRa ──
      case 'hal_lora_available_hw':
        return '0\nNo LoRa hardware detected on this platform.';
      case 'hal_lora_send':
        final data = args['data'] ?? '';
        return data.isEmpty
            ? 'Error: no data provided'
            : '-1\nNo LoRa hardware. Would send ${data.length} bytes.';
      case 'hal_lora_available':
        return '0\nNo LoRa hardware — no data available.';
      case 'hal_lora_recv':
        return '0 bytes\nNo LoRa hardware.';

      // ── BLE ──
      case 'hal_ble_scan_start':
        return '-1\nBLE not available on desktop.';
      case 'hal_ble_scan_stop':
        return 'OK (no-op on desktop)';
      case 'hal_ble_scan_read':
        return '[]\nNo BLE scan results.';
      case 'hal_ble_advertise':
        return '-1\nBLE not available on desktop.';
      case 'hal_ble_advertise_stop':
        return 'OK (no-op on desktop)';

      // ── Messaging ──
      case 'hal_msg_send':
        final json = args['json'] ?? '';
        return json.isEmpty
            ? 'Error: empty message'
            : 'Sent ${json.length} bytes to host';
      case 'hal_msg_available':
        return '0\nNo pending messages.';
      case 'hal_msg_recv':
        return '(empty)\nNo pending messages to receive.';

      // ── KV ──
      case 'hal_kv_get':
        final key = args['key'] ?? '';
        return key.isEmpty
            ? 'Error: key is empty'
            : 'Requires wapp context.\nWould look up key "$key" in the module\'s scoped store.';
      case 'hal_kv_set':
        final key = args['key'] ?? '';
        final value = args['value'] ?? '';
        return key.isEmpty
            ? 'Error: key is empty'
            : 'Requires wapp context.\nWould set "$key" = "$value" (${value.length} bytes).';
      case 'hal_kv_delete':
        return 'Requires wapp context.\nWould delete key "${args['key'] ?? ''}"';
      case 'hal_kv_list':
        return 'Requires wapp context.\nWould list keys matching prefix "${args['prefix'] ?? ''}"';
      case 'hal_kv_exists':
        return 'Requires wapp context.\nWould check if key "${args['key'] ?? ''}" exists.';
      case 'hal_kv_size':
        return 'Requires wapp context.\nWould return size of key "${args['key'] ?? ''}".';

      // ── i18n ──
      case 'hal_i18n_get':
        final key = args['key'] ?? '';
        if (key.isEmpty) return 'Error: key is empty';
        final resolved = _i18n.resolve('@$key');
        return resolved.startsWith('@')
            ? 'Not found: "$key"\nNo translation in current locale.'
            : 'Resolved: "$resolved"';

      // ── File ──
      case 'hal_file_open':
        return 'Requires wapp context.\nWould open "${args['path'] ?? ''}" mode=${args['mode'] ?? 0}';
      case 'hal_file_read':
        return 'Requires wapp context + open handle.';
      case 'hal_file_write':
        return 'Requires wapp context + open handle.';
      case 'hal_file_close':
        return 'Requires wapp context + open handle.';

      // ── HTTP ──
      case 'hal_http_request':
        final methods = {0: 'GET', 1: 'POST', 2: 'PUT', 3: 'DELETE'};
        final method = int.tryParse(args['method'] ?? '') ?? 0;
        final url = args['url'] ?? '';
        return url.isEmpty
            ? 'Error: URL is empty'
            : 'Would send ${methods[method] ?? 'GET'} $url\n(Async — poll with hal_http_poll)';
      case 'hal_http_poll':
        return 'Requires active request_id from hal_http_request.';
      case 'hal_http_read_response':
        return 'Requires completed request_id.';
      case 'hal_http_status':
        return 'Requires active request_id.';
      case 'hal_http_free':
        return 'Requires active request_id.';

      // ── Events ──
      case 'hal_event_subscribe':
        return 'Requires wapp context.\nWould subscribe to topic "${args['topic'] ?? ''}"';
      case 'hal_event_unsubscribe':
        return 'Requires wapp context.\nWould unsubscribe from "${args['topic'] ?? ''}"';
      case 'hal_event_publish':
        return 'Requires wapp context.\nWould publish to "${args['topic'] ?? ''}" (${(args['data'] ?? '').length} bytes)';
      case 'hal_event_available':
        return '0\nNo pending events.';
      case 'hal_event_recv':
        return '(empty)\nNo pending events.';

      // ── Lib ──
      case 'hal_lib_call':
        return 'Requires wapp context.\nWould call ${args['fn_name'] ?? '?'} on lib ${args['lib_id'] ?? '?'}\nArgs: ${args['args'] ?? '{}'}';

      default:
        return 'No test handler for $name';
    }
  }

  Widget _buildProviderRow(String funcId, WappManifest provider,
      List<WappManifest> allProviders, ColorScheme cs) {
    final prefs = PreferencesService.instanceSync;
    final preferredId = prefs?.getPreferredProvider(funcId);
    final isDefault = allProviders.length == 1 ||
        provider.id == preferredId ||
        (preferredId == null && provider == allProviders.first);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: allProviders.length > 1
          ? () async {
              final p = await PreferencesService.instance();
              p.setPreferredProvider(funcId, provider.id);
              if (mounted) setState(() {});
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(
          children: [
            if (allProviders.length > 1)
              Icon(
                isDefault
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 16,
                color: isDefault ? cs.primary : cs.onSurfaceVariant,
              )
            else
              Icon(Icons.check_circle_outline, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                provider.title.isNotEmpty ? provider.title : provider.name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isDefault ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            Text(
              provider.id,
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: cs.onSurfaceVariant,
              ),
            ),
            if (isDefault) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'DEFAULT',
                  style: TextStyle(
                    fontSize: 9,
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Settings screen ────────────────────────────────────────────────

  Widget _buildSettingsScreen(GeoUiBlock screen) {
    final renderer = GeoUiScreenRenderer(
      screen: screen,
      bindings: _WappFieldBindings(_fieldValues, () => setState(() {})),
      i18n: _i18n,
      onAction: (action) {
        if (action == 'save') {
          _engine.sendMessage(jsonEncode({
            'type': 'action',
            'action': 'save',
            'fields': _fieldValues,
          }));
          _engine.handleEvent();
          _drainOutbox();

          // Switch to first tab (Shop) to show results
          if (_tabController != null && _tabController!.index != 0) {
            _tabController!.animateTo(0);
          }
        } else {
          // Any other action name is forwarded to the wapp as a plain
          // command string. Lets debug/test wapps use standard GeoUI
          // action buttons without needing custom Flutter code.
          _sendCommand(action);
        }
      },
    );

    // App Creator: full custom settings screen with proper dependency
    // pickers instead of the generic GeoUI renderer.
    if (!_isAppCreator) return renderer;
    return _buildAppCreatorSettings(renderer);
  }

  // Available HAL capability groups — derived from geogram_wasm_hal.h.
  // Each entry maps a manifest requires.hal tag to a human description.
  static const _halCapabilities = <String, String>{
    'log': 'Logging',
    'time': 'Time functions',
    'kv': 'Key-value storage',
    'i18n': 'Translations',
    'file': 'File I/O',
    'http': 'HTTP requests',
    'msg': 'Inter-wapp messaging',
    'event': 'Event pub/sub',
    'lib': 'Library calls',
    'lora': 'LoRa radio',
    'ble': 'Bluetooth LE',
    'sensor': 'Sensors',
    'display': 'Display/screen',
    'gpio': 'GPIO pins',
  };

  /// Full App Creator Settings screen — identity fields via GeoUI
  /// renderer, plus custom chip pickers for HAL requires and provides.
  Widget _buildAppCreatorSettings(Widget identityRenderer) {
    final cs = Theme.of(context).colorScheme;
    final profile = ProfileService.instance.activeProfile;
    final npub = profile?.npub ?? '';

    // Ensure list-typed fields exist.
    _fieldValues.putIfAbsent('wapp_hal_requires', () => <String>['log']);
    _fieldValues.putIfAbsent('wapp_provides_functionalities', () => <String>[]);
    _fieldValues.putIfAbsent('wapp_kind', () => 'app');
    _fieldValues.putIfAbsent('wapp_tick_interval', () => '5000');

    final halRequires = _fieldValues['wapp_hal_requires'];
    final halList = halRequires is List<String>
        ? halRequires
        : <String>['log'];
    final providesList = _fieldValues['wapp_provides_functionalities'];
    final provides = providesList is List<String>
        ? providesList
        : <String>[];

    return Column(
      children: [
        // ── Save banner ──
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withAlpha(80),
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant.withAlpha(100)),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: cs.primary, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Changes are kept in memory while you edit. '
                  'Click Save to write them to disk.',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onPrimaryContainer,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _settingsSaveToDisk,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('Save'),
              ),
            ],
          ),
        ),

        // ── Signing identity ──
        _buildSigningIdentitySection(cs, profile, npub),

        // ── Scrollable body: GeoUI identity + runtime + deps ──
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
            children: [
              // Identity fields via GeoUI renderer (title, name, id,
              // version, description, icon). SizedBox must be tall
              // enough to fit all fields without internal scrolling,
              // otherwise the renderer's SingleChildScrollView
              // swallows scroll events and prevents the outer
              // ListView from reaching Category / HAL / Provides.
              SizedBox(
                height: 700,
                child: identityRenderer,
              ),

              // ── Category ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Category',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  'Where this wapp appears on the launcher.',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: {
                    'app': 'App (main grid)',
                    'system': 'System',
                    'addon': 'Addon',
                  }.entries.map((e) {
                    final selected =
                        (_fieldValues['wapp_kind'] ?? 'app') == e.key;
                    return ChoiceChip(
                      label: Text(e.value),
                      selected: selected,
                      onSelected: (on) {
                        if (on) {
                          setState(() => _fieldValues['wapp_kind'] = e.key);
                        }
                      },
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 12),

              // ── Tick interval ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextField(
                  controller: _tickIntervalController,
                  decoration: InputDecoration(
                    labelText: 'Tick interval (ms)',
                    helperText:
                        'How often module_tick() runs. 0 to disable.',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      _fieldValues['wapp_tick_interval'] = v,
                ),
              ),
              const SizedBox(height: 20),

              // ── HAL requires — chip picker ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Text(
                  'HAL dependencies',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  'Select which HAL capabilities this wapp needs. '
                  'The launcher checks these at load time.',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: _halCapabilities.entries.map((e) {
                    final selected = halList.contains(e.key);
                    return FilterChip(
                      label: Text(e.key),
                      tooltip: e.value,
                      selected: selected,
                      onSelected: (on) {
                        setState(() {
                          if (on) {
                            if (!halList.contains(e.key)) {
                              halList.add(e.key);
                            }
                          } else {
                            halList.remove(e.key);
                          }
                          _fieldValues['wapp_hal_requires'] = halList;
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 20),

              // ── Provides functionalities — tag editor ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Text(
                  'Provides functionalities',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  'Functionalities this wapp provides for other wapps to use.',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final w in provides)
                      InputChip(
                        label: Text(w),
                        onDeleted: () {
                          setState(() {
                            provides.remove(w);
                            _fieldValues['wapp_provides_functionalities'] = provides;
                          });
                        },
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 16),
                      label: const Text('Add'),
                      onPressed: () => _addProvidesFunctionality(provides),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _addProvidesFunctionality(List<String> provides) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add functionality'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. weather_card',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && !provides.contains(name)) {
      setState(() {
        provides.add(name);
        _fieldValues['wapp_provides_functionalities'] = provides;
      });
    }
  }

  Widget _buildSigningIdentitySection(
      ColorScheme cs, IwiProfile? profile, String npub) {
    final allProfiles = ProfileService.instance.profiles;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_user, color: cs.primary, size: 18),
              const SizedBox(width: 8),
              Text(
                'Signing identity',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              // Copy npub
              if (npub.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: 'Copy npub',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: npub));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('npub copied'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 6),
          // Profile picker dropdown
          if (allProfiles.length > 1)
            DropdownButtonFormField<String>(
              initialValue: profile?.id,
              isDense: true,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Active profile',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              items: allProfiles.map((p) {
                final label = p.displayName;
                final short = p.npub.length > 20
                    ? '${p.npub.substring(0, 12)}…${p.npub.substring(p.npub.length - 6)}'
                    : p.npub;
                return DropdownMenuItem(
                  value: p.id,
                  child: Text('$label  ($short)',
                      overflow: TextOverflow.ellipsis),
                );
              }).toList(),
              onChanged: (id) async {
                if (id == null) return;
                await ProfileService.instance.switchTo(id);
                if (mounted) setState(() {});
              },
            )
          else if (npub.isNotEmpty)
            Text(
              npub,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: cs.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            )
          else
            Text(
              'No profile — wapps will not be signed',
              style: TextStyle(fontSize: 12, color: cs.error),
            ),
          const SizedBox(height: 6),
          // Action row: generate new / import nsec
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New identity'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: () async {
                  final preview = ProfileService.instance.generatePreview();
                  await ProfileService.instance.saveAndActivate(preview);
                  if (!mounted) return;
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(
                        'New identity created: ${preview.callsign}'),
                    duration: const Duration(seconds: 3),
                  ));
                },
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                icon: const Icon(Icons.key, size: 16),
                label: const Text('Import nsec'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: () => _importNsec(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _importNsec() async {
    final controller = TextEditingController();
    final nsec = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import signing key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste your nsec1… private key. This will create a new '
              'profile and set it as the active signing identity.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'nsec1…',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (nsec == null || nsec.isEmpty) return;
    try {
      final profile = ProfileService.instance.buildFromNsec(nsec);
      await ProfileService.instance.saveAndActivate(profile);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Imported: ${profile.callsign}'),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Invalid nsec: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    }
  }

  /// Persist App Creator settings (title, name, id, description, icon,
  /// UI, translations) to the installed-apps folder. Follows the same
  /// pattern as [_translationsSaveToDisk] — delegates to
  /// [_handleInstall] which writes the full wapp package.
  Future<void> _settingsSaveToDisk() async {
    final id = (_fieldValues['wapp_id'] as String?) ?? '';
    if (id.isEmpty) {
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Cannot save',
        body: 'Open or create a project first (ID is empty).',
        source: 'host:app-creator',
      ));
      return;
    }
    await _handleInstall(<String, dynamic>{
      'id': id,
      'title': (_fieldValues['wapp_title'] as String?) ?? '',
      'name': (_fieldValues['wapp_name'] as String?) ?? '',
      'description':
          (_fieldValues['wapp_description'] as String?) ?? '',
      'source_ui': (_fieldValues['source_ui'] as String?) ?? '',
    });
  }

  /// Split a comma-separated string into a trimmed, non-empty list.
  static List<String> _splitCsv(String csv) => csv
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  // ── Map screen ─────────────────────────────────────────────────────

  Widget _buildMapScreen(GeoUiBlock screen, GeoUiBlock mapGroup) {
    return _SlippyMap(
      lat: _mapLat,
      lon: _mapLon,
      zoom: _mapZoom,
      tileUrl: _tileUrl,
      minZoom: mapGroup.getNumber('min-zoom')?.toInt() ?? 2,
      maxZoom: mapGroup.getNumber('max-zoom')?.toInt() ?? 18,
      onViewportChanged: (lat, lon, zoom) {
        _mapLat = lat;
        _mapLon = lon;
        _mapZoom = zoom;
        _engine.sendMessage(jsonEncode({
          'type': 'setViewport',
          'lat': lat,
          'lon': lon,
          'zoom': zoom,
        }));
        _engine.handleEvent();
        _drainOutbox();
      },
    );
  }
}

/// Full-screen page showing the complete API definition as copyable
/// JSON. Opened from the Functionalities screen's "Export API as JSON"
/// button.
class _ApiJsonExportPage extends StatelessWidget {
  final String title;
  final String json;
  const _ApiJsonExportPage({required this.title, required this.json});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy to clipboard',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: json));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('API JSON copied to clipboard'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          json,
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: cs.onSurface,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

class _OutputLine {
  final String text;
  final String level;
  _OutputLine(this.text, this.level);
}

/// Mode flag for App Creator's UI editor screen — either the raw
/// JSON in a code field, or a click-to-edit block tree. See
/// [_WappPageState._buildUiEditorScreen] for the consumer.
enum _UiEditorMode { visual, code }

/// Palette entry describing one draggable block type shown on the
/// left side of the WYSIWYG editor. The template map is deep-cloned
/// at drop time so every insertion gets its own copy.
class _UiPaletteEntry {
  final String label;
  final String? subLabel;
  final IconData icon;
  final Map<String, dynamic> template;

  const _UiPaletteEntry({
    required this.label,
    this.subLabel,
    required this.icon,
    required this.template,
  });
}

/// Discriminates between a palette insert and a canvas-to-canvas
/// move when a drop lands on a drop zone.
enum _UiDragKind { palette, move }

/// Payload carried by a [Draggable] inside the WYSIWYG editor.
/// `kind == palette` means "insert this template"; `kind == move`
/// means "relocate the block currently at movePath".
class _UiDragPayload {
  final _UiDragKind kind;
  final Map<String, dynamic>? payload;
  final List<int>? movePath;

  const _UiDragPayload._(this.kind, this.payload, this.movePath);

  factory _UiDragPayload.fromPalette(Map<String, dynamic> template) =>
      _UiDragPayload._(_UiDragKind.palette, template, null);

  factory _UiDragPayload.fromMove(List<int> path) =>
      _UiDragPayload._(_UiDragKind.move, null, List<int>.from(path));
}

/// One row rendered by the App Creator Projects tab. Immutable —
/// refresh replaces the list rather than mutating entries.
class _ProjectEntry {
  /// Folder slug (on-disk directory name under apps/ or
  /// wapps/archive/). Used as the install target.
  final String folder;

  /// `manifest.id` — used for dedup between user installs and
  /// built-in source-tree copies.
  final String id;

  /// Short human-readable title pulled from `manifest.description`.
  final String title;

  /// Long form from `manifest.summary`.
  final String description;

  /// Absolute path to the wapp's package directory. For user
  /// installs that's `~/.local/share/geogram/apps/<folder>/`; for
  /// built-ins it's `<cwd>/wapps/archive/<folder>/` (or an ancestor).
  /// `_loadProject` reads manifest + home.ui.json + app.wasm from
  /// here.
  final String dirPath;

  /// True when the wapp lives in the source tree under
  /// `wapps/archive/` rather than in `installedAppsStorage()`. The
  /// Projects tab hides the Delete button on pristine built-ins and
  /// flags them with a visual badge.
  final bool isBuiltIn;

  const _ProjectEntry({
    required this.folder,
    required this.id,
    required this.title,
    required this.description,
    required this.dirPath,
    required this.isBuiltIn,
  });
}

// ── Tasks screen helper widgets ──────────────────────────────────────

class _StatusPill extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  const _StatusPill({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$count $label',
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  final String label;
  final Color color;
  const _MiniPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(35),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: cs.onSurface,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _CatalogWapp {
  final String name;
  final String version;
  final String size;
  final bool installed;
  final bool updateAvailable;
  // Mutable metadata — attached by [_WappPageState._buildOutputScreen]
  // after the entry has been pushed, in order to keep the line-by-line
  // text-log parser simple (one walk, no lookahead).
  String description = '';
  String sourceHost = '';
  String publisherNpub = '';
  // NDF store enrichment — populated by _enrichCatalogWapp after parse.
  String storeTitle = '';
  String storeSummary = '';
  String storeBody = '';
  String changelog = '';
  List<String> screenshotPaths = const [];
  int likeCount = 0;
  int commentCount = 0;
  bool permitLikes = true;
  bool permitComments = true;

  _CatalogWapp({
    required this.name,
    required this.version,
    this.size = '',
    this.installed = false,
    this.updateAvailable = false,
  });
}

class _WappFieldBindings implements GeoUiBindings {
  final Map<String, dynamic> _values;
  final VoidCallback _onChange;
  _WappFieldBindings(this._values, this._onChange);

  @override
  dynamic getValue(String fieldName) => _values[fieldName];

  @override
  void setValue(String fieldName, dynamic value) {
    _values[fieldName] = value;
    _onChange();
  }
}

// ── Slippy tile map widget ───────────────────────────────────────────

class _SlippyMap extends StatefulWidget {
  final double lat, lon;
  final int zoom, minZoom, maxZoom;
  final String tileUrl;
  final void Function(double lat, double lon, int zoom) onViewportChanged;

  const _SlippyMap({
    required this.lat,
    required this.lon,
    required this.zoom,
    required this.tileUrl,
    required this.minZoom,
    required this.maxZoom,
    required this.onViewportChanged,
  });

  @override
  State<_SlippyMap> createState() => _SlippyMapState();
}

class _SlippyMapState extends State<_SlippyMap> {
  static const _tileSize = 256.0;

  late double _pxX, _pxY; // top-left in world pixels
  late int _zoom;
  Offset? _dragStart;
  double? _dragPxX, _dragPxY;

  // Search
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  List<_SearchResult>? _searchResults;
  bool _searching = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _zoom = widget.zoom;
    _centerOn(widget.lat, widget.lon);
  }

  @override
  void didUpdateWidget(_SlippyMap old) {
    super.didUpdateWidget(old);
    if ((old.lat - widget.lat).abs() > 0.0001 ||
        (old.lon - widget.lon).abs() > 0.0001 ||
        old.zoom != widget.zoom) {
      _zoom = widget.zoom;
      _centerOn(widget.lat, widget.lon);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _doSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    setState(() => _searching = true);

    // Check if it's raw coordinates (lat, lon)
    final coordMatch = RegExp(r'^(-?\d+\.?\d*)\s*[,\s]\s*(-?\d+\.?\d*)$')
        .firstMatch(query.trim());
    if (coordMatch != null) {
      final lat = double.tryParse(coordMatch.group(1)!);
      final lon = double.tryParse(coordMatch.group(2)!);
      if (lat != null && lon != null) {
        setState(() {
          _searchResults = [_SearchResult('$lat, $lon', 'Coordinates', lat, lon)];
          _searching = false;
        });
        return;
      }
    }

    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'json',
        'limit': '8',
        'addressdetails': '1',
      });
      final resp = await http.get(uri, headers: const {
        'User-Agent': 'Geogram/1.0',
      }).timeout(const Duration(seconds: 10));
      final body = resp.body;

      final results = (jsonDecode(body) as List).map((r) {
        final lat = double.tryParse(r['lat']?.toString() ?? '') ?? 0;
        final lon = double.tryParse(r['lon']?.toString() ?? '') ?? 0;
        final name = r['display_name'] as String? ?? '';
        final type = r['type'] as String? ?? '';
        return _SearchResult(name, type, lat, lon);
      }).toList();

      // Sort by distance from current center
      final size = _viewSize;
      final cLat = _px2lat(_pxY + size.height / 2, _zoom);
      final cLon = _px2lon(_pxX + size.width / 2, _zoom);
      results.sort((a, b) {
        final da = _distDeg(a.lat, a.lon, cLat, cLon);
        final db = _distDeg(b.lat, b.lon, cLat, cLon);
        return da.compareTo(db);
      });

      setState(() { _searchResults = results; _searching = false; });
    } catch (_) {
      setState(() { _searchResults = []; _searching = false; });
    }
  }

  double _distDeg(double lat1, double lon1, double lat2, double lon2) {
    final dlat = lat1 - lat2, dlon = lon1 - lon2;
    return sqrt(dlat * dlat + dlon * dlon);
  }

  void _goToResult(_SearchResult r) {
    setState(() {
      _searchResults = null;
      _searchController.clear();
      _zoom = 15;
      _centerOn(r.lat, r.lon);
    });
    _syncViewport();
  }

  void _centerOn(double lat, double lon) {
    final size = _viewSize;
    _pxX = _lon2px(lon, _zoom) - size.width / 2;
    _pxY = _lat2px(lat, _zoom) - size.height / 2;
  }

  Size get _viewSize {
    final ctx = context;
    final rb = ctx.findRenderObject() as RenderBox?;
    return rb?.size ?? const Size(800, 600);
  }

  double _lon2px(double lon, int z) =>
      ((lon + 180) / 360) * _tileSize * pow(2, z);
  double _lat2px(double lat, int z) {
    final r = pi / 180 * lat;
    return (1 - log(tan(r) + 1 / cos(r)) / pi) / 2 * _tileSize * pow(2, z);
  }
  double _px2lon(double px, int z) =>
      px / (_tileSize * pow(2, z)) * 360 - 180;
  double _px2lat(double py, int z) {
    final n = pi - 2 * pi * py / (_tileSize * pow(2, z));
    return 180 / pi * atan(0.5 * (exp(n) - exp(-n)));
  }

  void _syncViewport() {
    final size = _viewSize;
    final lat = _px2lat(_pxY + size.height / 2, _zoom);
    final lon = _px2lon(_pxX + size.width / 2, _zoom);
    widget.onViewportChanged(lat, lon, _zoom);
  }

  void _zoomBy(int delta, [Offset? focus]) {
    final newZoom = (_zoom + delta).clamp(widget.minZoom, widget.maxZoom);
    if (newZoom == _zoom) return;
    final size = _viewSize;
    final fx = focus?.dx ?? size.width / 2;
    final fy = focus?.dy ?? size.height / 2;
    final worldX = _pxX + fx, worldY = _pxY + fy;
    final scale = pow(2, newZoom - _zoom).toDouble();
    setState(() {
      _zoom = newZoom;
      _pxX = worldX * scale - fx;
      _pxY = worldY * scale - fy;
    });
    _syncViewport();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth, h = constraints.maxHeight;
      final tileXMin = (_pxX / _tileSize).floor();
      final tileYMin = (_pxY / _tileSize).floor();
      final tileXMax = ((_pxX + w) / _tileSize).floor();
      final tileYMax = ((_pxY + h) / _tileSize).floor();
      final maxTile = pow(2, _zoom).toInt() - 1;

      final tiles = <Widget>[];
      for (var ty = tileYMin; ty <= tileYMax; ty++) {
        for (var tx = tileXMin; tx <= tileXMax; tx++) {
          final wrappedX = ((tx % (maxTile + 1)) + (maxTile + 1)) % (maxTile + 1);
          if (ty < 0 || ty > maxTile) continue;
          final url = widget.tileUrl
              .replaceAll('{z}', '$_zoom')
              .replaceAll('{x}', '$wrappedX')
              .replaceAll('{y}', '$ty');
          tiles.add(Positioned(
            left: tx * _tileSize - _pxX,
            top: ty * _tileSize - _pxY,
            width: _tileSize,
            height: _tileSize,
            child: Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Container(color: const Color(0xFF0a0e14)),
            ),
          ));
        }
      }

      final centerLat = _px2lat(_pxY + h / 2, _zoom);
      final centerLon = _px2lon(_pxX + w / 2, _zoom);

      return GestureDetector(
        onPanStart: (d) {
          _dragStart = d.localPosition;
          _dragPxX = _pxX;
          _dragPxY = _pxY;
        },
        onPanUpdate: (d) {
          setState(() {
            _pxX = _dragPxX! - (d.localPosition.dx - _dragStart!.dx);
            _pxY = _dragPxY! - (d.localPosition.dy - _dragStart!.dy);
          });
        },
        onPanEnd: (_) => _syncViewport(),
        child: Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              final delta = event.scrollDelta.dy < 0 ? 1 : -1;
              _zoomBy(delta, event.localPosition);
            }
          },
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Container(color: const Color(0xFF0a0e14)),
              ...tiles,
              // Search bar
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: Column(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xF0161b22),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF30363d)),
                      ),
                      child: Row(
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Icon(Icons.search, size: 18, color: Color(0xFF8b949e)),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocus,
                              style: const TextStyle(fontSize: 13, color: Color(0xFFe6edf3)),
                              decoration: const InputDecoration(
                                hintText: 'Search address or coordinates...',
                                hintStyle: TextStyle(color: Color(0xFF8b949e), fontSize: 13),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                isDense: true,
                              ),
                              onChanged: (v) {
                                _debounce?.cancel();
                                _debounce = Timer(const Duration(milliseconds: 400), () => _doSearch(v));
                              },
                              onSubmitted: _doSearch,
                            ),
                          ),
                          if (_searching)
                            const Padding(
                              padding: EdgeInsets.only(right: 10),
                              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          else if (_searchController.text.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.close, size: 16, color: Color(0xFF8b949e)),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchResults = null);
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            ),
                        ],
                      ),
                    ),
                    if (_searchResults != null && _searchResults!.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        constraints: const BoxConstraints(maxHeight: 240),
                        decoration: BoxDecoration(
                          color: const Color(0xF0161b22),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF30363d)),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _searchResults!.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF30363d)),
                          itemBuilder: (context, i) {
                            final r = _searchResults![i];
                            return InkWell(
                              onTap: () => _goToResult(r),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      r.name.length > 80 ? '${r.name.substring(0, 80)}...' : r.name,
                                      style: const TextStyle(fontSize: 12, color: Color(0xFFe6edf3)),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${r.lat.toStringAsFixed(5)}, ${r.lon.toStringAsFixed(5)}',
                                      style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Color(0xFF8b949e)),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    if (_searchResults != null && _searchResults!.isEmpty && !_searching)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xF0161b22),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF30363d)),
                        ),
                        child: const Text('No results found', style: TextStyle(fontSize: 12, color: Color(0xFF8b949e))),
                      ),
                  ],
                ),
              ),
              // Zoom controls
              Positioned(
                bottom: 12,
                left: 12,
                child: Column(
                  children: [
                    _mapButton('+', () => _zoomBy(1)),
                    const SizedBox(height: 4),
                    _mapButton('\u2212', () => _zoomBy(-1)),
                  ],
                ),
              ),
              // Coordinates
              Positioned(
                bottom: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${centerLat.toStringAsFixed(5)}, ${centerLon.toStringAsFixed(5)} z$_zoom',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Color(0xFF8b949e),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _mapButton(String label, VoidCallback onTap) {
    return Material(
      color: const Color(0xFF161b22),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF30363d)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: const TextStyle(fontSize: 18, color: Color(0xFFe6edf3))),
        ),
      ),
    );
  }
}

class _SearchResult {
  final String name;
  final String type;
  final double lat, lon;
  _SearchResult(this.name, this.type, this.lat, this.lon);
}
