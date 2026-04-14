import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, HttpClient, Platform, Process;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../geoui/geoui_ast.dart';
import '../geoui/geoui_parser.dart';
import '../geoui/geoui_renderer.dart';
import '../models/monitored_task.dart';
import '../services/event_bus.dart';
import '../services/notification_service.dart';
import '../services/preferences_service.dart';
import '../services/profile_storage.dart';
import '../services/storage_paths.dart';
import '../services/task_monitor_service.dart';
import '../services/wapp_compiler_service.dart';
import '../services/wapp_installer_service.dart';
import '../services/widget_broker.dart';
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
  /// and lifecycle events.
  late final String _wappName =
      _pkg.basePath.split(Platform.pathSeparator).last;

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
  final _scrollController = ScrollController();

  // Settings bindings
  final _fieldValues = <String, dynamic>{};

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

    final result = await WappInstallerService.instance.installFromCompiled(
      id: id,
      title: title,
      folderName: folderName,
      description: description,
      wasmBytes: freshBytes,
      homeScreenJson: sourceUi.isEmpty ? null : sourceUi,
      sourceC: sourceC.isEmpty ? null : sourceC,
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
    final uiJson =
        await pkg.readString('screens/home.ui.json') ?? '';
    final wasm = await pkg.readBytes('app.wasm');
    final sourceC = await pkg.readString('main.c') ?? '';

    // Mutate the bindings map in place. A subsequent setState lets
    // CodeEditorField / TextField widgets pick up the new values
    // via their didUpdateWidget paths.
    _fieldValues['wapp_title'] = title;
    _fieldValues['wapp_id'] = id;
    _fieldValues['wapp_description'] = description;
    _fieldValues['wapp_name'] = entry.folder;
    _fieldValues['source_ui'] = uiJson;
    _fieldValues['source'] = sourceC;
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
      'source',
      'source_ui',
      'source__readonly',
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
    // Same candidate paths as main.dart _scanArchiveBody.
    final cwd = Directory.current.path;
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
  /// be Code, UI, Settings.
  List<GeoUiBlock> get _editorScreens => _screens
      .where((s) => (s.name ?? '').toLowerCase() != 'projects')
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
              Icon(Icons.extension, color: cs.primary, size: 26),
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

  Future<void> _loadWapp() async {
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
          unawaited(WidgetBroker.instance.handleRequest(
            callerEngineId: _engine.engineId,
            widgetId: data['widget'] as String? ?? '',
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
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
    final sep = Platform.pathSeparator;
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
      final msg = jsonEncode({'type': 'wapp.index', 'data': contents});
      _engine.sendMessage(msg);
      _engine.handleEvent();
      _drainOutbox();
      if (mounted) setState(() {});
    } catch (e) {
      _outputLines.add(_OutputLine('Failed to read index: $e', 'err'));
      if (mounted) setState(() {});
    }
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
      final slashIdx = baseDir.replaceAll(Platform.pathSeparator, '/').lastIndexOf('/');
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

      // Extract .wapp (ZIP) into the installed-apps target directory. The
      // external `unzip` tool needs a real on-disk path — this works today
      // because installedAppsStorage() is a FilesystemProfileStorage. When
      // an encrypted/IndexedDB backend is added, this will need to unzip
      // into a temp dir and then copyFromExternal() each file.
      final absSrcPath = srcStorage.getAbsolutePath(filePath);
      final absAppDir = _installed.getAbsolutePath(name);
      final result =
          Process.runSync('unzip', ['-o', '-q', absSrcPath, '-d', absAppDir]);
      if (result.exitCode != 0) {
        _outputLines.add(_OutputLine('Extract failed: ${result.stderr}', 'err'));
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
    _engine.dispose();
    _cmdController.dispose();
    _scrollController.dispose();
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
                tabs: _screenNames.map((n) => Tab(text: n)).toList(),
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
          tabs: editorNames.map((n) => Tab(text: n)).toList(),
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

  Widget _buildOutputScreen() {
    if (_outputLines.isEmpty) {
      return const Center(
        child: Text('No wapps loaded yet.\nSet a repository path in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey)),
      );
    }

    // Parse output lines into wapp entries for card display.
    // Format from module:
    //   [info] N wapp(s) available:
    //   [out]   name            vX.Y.Z  (NKB)  [installed] or [update: ...]
    //   [out]     Description text
    final wapps = <_CatalogWapp>[];
    final errors = <String>[];

    for (var i = 0; i < _outputLines.length; i++) {
      final line = _outputLines[i];
      final text = line.text;

      // Wapp entry line: starts with "  " + name, has version
      final match = RegExp(r'^\s{2}(\S+)\s+v(\S+)(?:\s+\(([^)]+)\))?(.*)$')
          .firstMatch(text);
      if (match != null && line.level == 'out') {
        final name = match.group(1)!;
        final version = match.group(2)!;
        final size = match.group(3) ?? '';
        final status = match.group(4)?.trim() ?? '';

        // Next line might be the description (indented with 4 spaces)
        String desc = '';
        if (i + 1 < _outputLines.length) {
          final next = _outputLines[i + 1].text;
          if (next.startsWith('    ') && _outputLines[i + 1].level == 'out') {
            desc = next.trim();
            i++; // skip description line
          }
        }

        // Check actual install state from disk, not module KV.
        // Uses the sync variant because this runs inside build().
        final actuallyInstalled = _installed.existsSync('$name/app.wasm');

        wapps.add(_CatalogWapp(
          name: name,
          version: version,
          size: size,
          description: desc,
          installed: actuallyInstalled,
          updateAvailable: status.contains('[update:'),
        ));
        continue;
      }

      // Error lines
      if (line.level == 'err') {
        errors.add(text);
      }
    }

    if (wapps.isEmpty && errors.isEmpty) {
      // Fallback to raw output if we can't parse
      return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(12),
        itemCount: _outputLines.length,
        itemBuilder: (context, i) => Text(
          _outputLines[i].text,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: _outputColor(_outputLines[i].level),
          ),
        ),
      );
    }

    final cs = Theme.of(context).colorScheme;

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      children: [
        if (errors.isNotEmpty)
          for (final err in errors)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(err, style: TextStyle(color: cs.error, fontSize: 13)),
            ),
        Text('${wapps.length} wapp${wapps.length == 1 ? '' : 's'} available',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                )),
        const SizedBox(height: 12),
        for (final wapp in wapps) _buildWappCard(wapp, cs),
      ],
    );
  }

  Widget _buildWappCard(_CatalogWapp wapp, ColorScheme cs) {
    final isInstall = wapp.name == 'install';

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
      ),
      color: cs.surfaceContainerLow,
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(
          isInstall
              ? Icons.download
              : wapp.name == 'maps'
                  ? Icons.map
                  : wapp.name == 'terminal'
                      ? Icons.terminal
                      : Icons.extension,
          color: cs.primary,
          size: 28,
        ),
        title: Row(
          children: [
            Text(wapp.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text('v${wapp.version}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            if (wapp.size.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(wapp.size,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ],
          ],
        ),
        subtitle: wapp.description.isNotEmpty
            ? Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(wapp.description,
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant)),
              )
            : null,
        trailing: wapp.installed
            ? TextButton(
                onPressed: () => _uninstallWapp(wapp.name),
                style: TextButton.styleFrom(
                  foregroundColor: cs.error,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Uninstall', style: TextStyle(fontSize: 12)),
              )
            : wapp.updateAvailable
                ? FilledButton.tonal(
                    onPressed: () {
                      _sendCommand('install ${wapp.name}');
                      _engine.handleEvent();
                      _drainOutbox();
                    },
                    style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    child: const Text('Update', style: TextStyle(fontSize: 12)),
                  )
                : isInstall
                    ? null
                    : FilledButton(
                        onPressed: () {
                          _sendCommand('install ${wapp.name}');
                          _engine.handleEvent();
                          _drainOutbox();
                        },
                        style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact),
                        child: const Text('Install',
                            style: TextStyle(fontSize: 12)),
                      ),
      ),
    );
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

  // ── Settings screen ────────────────────────────────────────────────

  Widget _buildSettingsScreen(GeoUiBlock screen) {
    return GeoUiScreenRenderer(
      screen: screen,
      bindings: _WappFieldBindings(_fieldValues, () => setState(() {})),
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
  }

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

class _OutputLine {
  final String text;
  final String level;
  _OutputLine(this.text, this.level);
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
  final String description;
  final bool installed;
  final bool updateAvailable;

  _CatalogWapp({
    required this.name,
    required this.version,
    this.size = '',
    this.description = '',
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
      final client = HttpClient();
      client.userAgent = 'Geogram/1.0';
      final req = await client.getUrl(uri);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();

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
