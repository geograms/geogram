/*
 * WappPage — runs a single wapp from <profile>/apps/<wappId>/.
 *
 * Stage 1 slim port:
 *   - Load manifest.json
 *   - Discover screens (the .ui.json files)
 *   - Boot WappEngine on app.wasm
 *   - Render each screen via GeoUiScreenRenderer inside a TabBar
 *   - Periodic tick (manifest.tick_interval_ms)
 *   - Drain outbox; log unhandled messages (compile/install/widget.request
 *     come in later stages)
 *
 * Out of scope (Stage 2+): App Creator UI, store cards, comments,
 * functionality broker, signing verification, install flow.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileSystemEntity;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../geoui/geoui_ast.dart';
import '../geoui/geoui_parser.dart';
import '../geoui/geoui_renderer.dart';
import '../models/wapp_manifest.dart';
import '../services/i18n_context.dart';
import '../services/log_service.dart';
import '../services/profile_storage.dart';
import '../services/wapp_installer_service.dart';
import '../services/wapp_storage.dart';
import '../util/app_type_theme.dart';
import '../util/event_bus.dart';
import 'wapp_engine.dart';

class WappPage extends StatefulWidget {
  /// Wapp folder slug (under <profile>/apps/<wappId>/). The whole
  /// package — manifest, app.wasm, screens, media, lang — is read
  /// through ProfileStorage so the call site doesn't care whether
  /// the active profile is a plain folder or an encrypted archive.
  final String wappId;

  /// Human-readable title for the AppBar (typically the manifest's
  /// description field).
  final String title;

  const WappPage({super.key, required this.wappId, required this.title});

  @override
  State<WappPage> createState() => _WappPageState();
}

class _WappPageState extends State<WappPage>
    with TickerProviderStateMixin {
  WappManifest? _manifest;
  final _engine = WappEngine();
  final List<GeoUiBlock> _screens = [];
  final List<String> _screenNames = [];
  TabController? _tabController;
  Timer? _tickTimer;
  String _status = 'Loading…';
  bool _crashed = false;

  // ── Wapp store state (used when a screen has a `$type="output"` or
  //    `$type="sources"` group). The install wapp pushes ui.append +
  //    store.sources messages and the host drives fetch_index +
  //    wapp.install on its behalf.
  final List<_OutputLine> _outputLines = [];
  List<String> _storeSources = const [];
  final _sourcesInputController = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_loadWapp());
  }

  Future<void> _loadWapp() async {
    try {
      // Wapp package — shared archive, read-only.
      final pkg = wappPackageStorage(widget.wappId);
      if (pkg == null) {
        setState(() => _status = 'Wapp archive unavailable.');
        return;
      }

      // 1. Manifest
      final manifestJson = await pkg.readJson('manifest.json');
      if (manifestJson == null) {
        setState(() => _status =
            'manifest.json not found in shared wapps/${widget.wappId}/.');
        return;
      }
      final manifest = WappManifest.fromJson(
        manifestJson,
        pkg.basePath,
      );
      _manifest = manifest;

      // 2. WASM bytes
      final wasmBytes = await pkg.readBytes('app.wasm');
      if (wasmBytes == null || wasmBytes.isEmpty) {
        setState(() => _status =
            'app.wasm missing in shared wapps/${widget.wappId}/.');
        return;
      }

      // 3. Per-profile runtime data folder (sits at the root of the
      //    active profile, e.g. <profile>/<wappId>/). Holds kv.json
      //    and any user-specific state the wapp accumulates.
      final wappData = wappDataStorageFor(widget.wappId);
      if (wappData != null) {
        await wappData.createDirectory('');
        await _engine.setStorage(wappData);
      }

      // 4. i18n context (optional lang/<locale>.json)
      final i18n = await I18nContext.loadFromPackage(
        pkg,
        locale: 'en',
        languageOnly: 'en',
      );
      _engine.setI18n(i18n);

      // 5a. Wapp store debug seed: when running from a source
      //     checkout, point the install wapp at the in-repo
      //     wapps/binaries/ directory so the user has a working
      //     catalog out of the box. Mirrors iwi's behaviour.
      if (widget.wappId == 'install' && !_engine.hasKvKey('source')) {
        final cwd = Directory.current.path;
        final candidates = [
          '$cwd/wapps/binaries',
          '$cwd/../wapps/binaries',
          '$cwd/../../wapps/binaries',
        ];
        for (final candidate in candidates) {
          if (File('$candidate/index.json').existsSync()) {
            _engine.kvSet('source', candidate);
            break;
          }
        }
      }

      // 5. Boot engine
      try {
        await _engine.load(wasmBytes);
        _engine.init();
        EventBus().fire(WappLoadedEvent(
          wappId: manifest.id,
          wappName: manifest.name,
        ));
      } catch (e, st) {
        _crashed = true;
        EventBus().fire(WappCrashedEvent(
          wappId: manifest.id,
          phase: 'load',
          error: e,
        ));
        LogService().log('WappPage: load failed for ${manifest.id}: $e\n$st');
        setState(() => _status = 'Load failed: $e');
        return;
      }

      // 6. Discover screens
      await _loadScreens(pkg);

      // 7. Drain initial outbox produced by module_init
      _drainOutbox();

      // 8. Schedule tick loop
      final tickMs = manifest.tickIntervalMs;
      if (tickMs > 0) {
        _tickTimer = Timer.periodic(
          Duration(milliseconds: tickMs),
          (_) => _onTick(),
        );
      }

      if (mounted) setState(() {});
    } catch (e, st) {
      LogService().log('WappPage: unexpected load error: $e\n$st');
      if (mounted) setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _loadScreens(ProfileStorage pkg) async {
    if (!await pkg.directoryExists('screens')) {
      setState(() => _status = 'No screens/ folder.');
      return;
    }
    final entries = await pkg.listDirectory('screens');
    final files = entries
        .where((e) => !e.isDirectory && e.path.endsWith('.ui.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final raw = await pkg.readString(f.path);
      if (raw == null) continue;
      try {
        final parsed = GeoUiParser(raw).parse();
        for (final block in parsed.blocks) {
          if (block.keyword == 'screen') {
            _screens.add(block);
            _screenNames.add(block.name ?? f.path.split('/').last);
          }
        }
      } catch (e) {
        LogService().log('WappPage: failed to parse ${f.path}: $e');
      }
    }
    if (_screens.isEmpty) {
      setState(() => _status = 'No screens found.');
      return;
    }
    _tabController = TabController(length: _screens.length, vsync: this);
    if (mounted) setState(() {});
  }

  void _onTick() {
    if (_crashed) return;
    try {
      _engine.tick();
      _drainOutbox();
    } catch (e) {
      _crashed = true;
      EventBus().fire(WappCrashedEvent(
        wappId: _manifest?.id ?? widget.wappId,
        phase: 'tick',
        error: e,
      ));
      LogService().log('WappPage: tick crashed: $e');
    }
  }

  void _drainOutbox() {
    final messages = _engine.drainOutbox();
    var changed = false;
    for (final raw in messages) {
      try {
        final data = jsonDecode(raw);
        if (data is! Map<String, dynamic>) continue;
        final type = data['type']?.toString() ?? '';

        switch (type) {
          case 'ui.append':
            // Wapp store catalog log: append a single line targeting
            // the output-list group.
            final item = data['item'] as Map<String, dynamic>? ?? {};
            _outputLines.add(_OutputLine(
              item['text'] as String? ?? '',
              item['level'] as String? ?? 'out',
            ));
            changed = true;
            break;

          case 'store.sources':
            // Wapp store push: current source list straight from its
            // KV. Stash it for the sources renderer.
            final list = data['sources'] as List?;
            _storeSources =
                list == null ? const [] : list.whereType<String>().toList();
            changed = true;
            break;

          case 'wapp.fetch_index':
            // Wapp store asks the host to fetch a remote index.json.
            unawaited(_handleFetchIndex(data));
            break;

          case 'wapp.install':
            // Wapp store asks the host to download + extract a .wapp
            // ZIP from a remote URL.
            unawaited(_handleWappInstall(data));
            break;

          default:
            LogService().log(
                'WappPage[${_manifest?.id ?? widget.wappId}] outbox: $type');
        }
      } catch (_) {}
    }
    if (changed && mounted) setState(() {});
  }

  Future<void> _handleFetchIndex(Map<String, dynamic> data) async {
    final source = (data['source'] as String? ?? '').trim();
    if (source.isEmpty) return;

    String resolved = source;
    if (!resolved.toLowerCase().endsWith('.json')) {
      if (!resolved.endsWith('/')) resolved += '/';
      resolved += 'index.json';
    }

    try {
      final body = await _readSourceContents(resolved);
      if (body == null) {
        _appendOutput('Index not found: $resolved', 'err');
        return;
      }
      final parsed = jsonDecode(body);
      _engine.sendMessage(jsonEncode({'type': 'wapp.index', 'data': parsed}));
      _engine.handleEvent();
      _drainOutbox();
    } catch (e) {
      _appendOutput('Index fetch error: $e', 'err');
    }
  }

  /// Read a wapp store resource as a UTF-8 string. Accepts both http
  /// URLs and filesystem paths (for the debug source-checkout seed).
  Future<String?> _readSourceContents(String pathOrUrl) async {
    final lower = pathOrUrl.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      final resp = await http.get(Uri.parse(pathOrUrl));
      if (resp.statusCode != 200) return null;
      return resp.body;
    }
    final f = File(pathOrUrl);
    if (!f.existsSync()) return null;
    try {
      return f.readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  /// Read raw bytes from either an http URL or a filesystem path.
  Future<Uint8List?> _readSourceBytes(String pathOrUrl) async {
    final lower = pathOrUrl.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      final resp = await http.get(Uri.parse(pathOrUrl));
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes;
    }
    final f = File(pathOrUrl);
    if (!f.existsSync()) return null;
    try {
      return Uint8List.fromList(f.readAsBytesSync());
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleWappInstall(Map<String, dynamic> data) async {
    final source = (data['source'] as String? ?? '').trim();
    final filePath = (data['file'] as String? ?? '').trim();
    final name = (data['name'] as String? ?? '').trim();
    final version = (data['version'] as String? ?? '').trim();
    if (source.isEmpty || filePath.isEmpty || name.isEmpty) return;

    // Resolve <source>/<file> into a full URL or filesystem path
    // (source may itself be a path to index.json).
    var baseDir = source;
    if (baseDir.toLowerCase().endsWith('.json')) {
      final i = baseDir.lastIndexOf('/');
      if (i <= 0) return;
      baseDir = baseDir.substring(0, i);
    }
    if (!baseDir.endsWith('/')) baseDir += '/';
    final full = '$baseDir$filePath';

    try {
      final bytes = await _readSourceBytes(full);
      if (bytes == null) {
        _appendOutput('Download failed: $full', 'err');
        return;
      }
      final ok = await WappInstallerService.instance.installFromBytes(
        wappId: name,
        zipBytes: bytes,
      );
      if (!ok) {
        _appendOutput('Install failed for $name', 'err');
        return;
      }
      // Confirm to the wapp so it updates its installed-list KV.
      _engine.sendMessage(jsonEncode({
        'type': 'wapp.installed',
        'name': name,
        'version': version,
      }));
      _engine.handleEvent();
      _appendOutput('$name v$version installed', 'info');
      // Notify the launcher to rescan the grid.
      EventBus().fire(WappLoadedEvent(wappId: name, wappName: name));
    } catch (e) {
      _appendOutput('Install error: $e', 'err');
    }
  }

  void _appendOutput(String text, String level) {
    _outputLines.add(_OutputLine(text, level));
    if (mounted) setState(() {});
  }

  void _pushSources(List<String> next) {
    _engine.sendMessage(jsonEncode({
      'type': 'action',
      'action': 'set_sources',
      'fields': {'source': next.join('\n')},
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _tabController?.dispose();
    final id = _manifest?.id ?? widget.wappId;
    final name = _manifest?.name ?? widget.wappId;
    try {
      _engine.dispose();
    } catch (_) {}
    EventBus().fire(WappUnloadedEvent(wappId: id, wappName: name));
    super.dispose();
  }

  /// Per-screen builder. Detects special group `$type` values that
  /// the GeoUI renderer can't render on its own and substitutes a
  /// host widget. Falls back to GeoUiScreenRenderer for everything
  /// else (standard fields, actions, labels).
  Widget _buildScreen(
    GeoUiBlock screen,
    GeoUiBindings bindings,
    I18nContext? i18n,
  ) {
    // Detect first host-rendered group child, if any.
    GeoUiBlock? mapGroup;
    for (final c in screen.children) {
      if (c.keyword == 'group' && c.type == 'map') {
        mapGroup = c;
        break;
      }
    }
    if (mapGroup != null) {
      return _buildMapScreen(screen, mapGroup);
    }

    // Output catalog (wapp store): scrollable list of lines pushed
    // by the wapp via {"type":"ui.append","item":{...}}.
    final outputGroup = screen.children.firstWhere(
      (c) => c.keyword == 'group' && c.type == 'output',
      orElse: () => GeoUiBlock(
          keyword: '', name: null, type: null, decls: {}, children: []),
    );
    if (outputGroup.keyword == 'group') return _buildOutputScreen();

    // Sources manager (wapp store Settings): repository list editor.
    final sourcesGroup = screen.children.firstWhere(
      (c) => c.keyword == 'group' && c.type == 'sources',
      orElse: () => GeoUiBlock(
          keyword: '', name: null, type: null, decls: {}, children: []),
    );
    if (sourcesGroup.keyword == 'group') return _buildSourcesScreen();

    // Stub for groups whose `$type` requires host support that
    // hasn't been ported yet (projects, tasks, ui-editor,
    // translations, functionalities, ...). Show a friendly note
    // instead of an empty card.
    final stubGroup = screen.children.firstWhere(
      (c) =>
          c.keyword == 'group' &&
          c.type != null &&
          const {
            'projects',
            'tasks',
            'ui-editor',
            'translations',
            'functionalities',
            'identity',
          }.contains(c.type),
      orElse: () => GeoUiBlock(
          keyword: '', name: null, type: null, decls: {}, children: []),
    );
    if (stubGroup.keyword == 'group') {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'This screen uses a "${stubGroup.type}" widget that is\n'
            'not yet supported in the main launcher. The wapp engine\n'
            'is running, but the host-side renderer for this group\n'
            'will arrive in a future stage.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return GeoUiScreenRenderer(
      screen: screen,
      bindings: bindings,
      i18n: i18n,
      onAction: (action) {
        _engine.sendMessage(jsonEncode({
          'type': 'action',
          'action': action,
        }));
        _engine.handleEvent();
        _drainOutbox();
      },
    );
  }

  /// Render a `<group $type="map">` screen using flutter_map. The
  /// map's tile URL, default centre and zoom come from the GeoUI
  /// block attributes. Action buttons (zoom in/out etc.) defined in
  /// sibling groups still come through GeoUiScreenRenderer below
  /// the map.
  Widget _buildMapScreen(GeoUiBlock screen, GeoUiBlock mapGroup) {
    final tileUrl = mapGroup.getString('tile-url') ??
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
    final lat = mapGroup.getNumber('default-lat')?.toDouble() ?? 0;
    final lon = mapGroup.getNumber('default-lon')?.toDouble() ?? 0;
    final zoom = mapGroup.getNumber('default-zoom')?.toDouble() ?? 12;
    final minZoom =
        mapGroup.getNumber('min-zoom')?.toDouble() ?? 2;
    final maxZoom =
        mapGroup.getNumber('max-zoom')?.toDouble() ?? 18;

    return FlutterMap(
      options: MapOptions(
        initialCenter: LatLng(lat, lon),
        initialZoom: zoom,
        minZoom: minZoom,
        maxZoom: maxZoom,
      ),
      children: [
        TileLayer(
          urlTemplate: tileUrl,
          userAgentPackageName: 'geogram',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabController = _tabController;
    if (tabController == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(child: Text(_status)),
      );
    }

    final i18n = _engine.i18n;
    final bindings = _WappFieldBindings(
      _engine,
      onChange: () {
        if (mounted) setState(() {});
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: _screens.length > 1
            ? TabBar(
                controller: tabController,
                isScrollable: true,
                tabs: _screenNames
                    .map((n) => Tab(text: i18n?.resolve(n) ?? n))
                    .toList(),
              )
            : null,
      ),
      body: TabBarView(
        controller: tabController,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final s in _screens) _buildScreen(s, bindings, i18n),
        ],
      ),
    );
  }

  /// Render the wapp store catalog as proper cards. The install
  /// wapp emits structured text via `ui.append`:
  ///   "  name  vX.Y.Z  (NKB)  [optional status]"   ← entry
  ///   "    description text"                        ← description
  ///   "    @sourceHost"                             ← source chip
  ///   "    by:npub1…"                               ← publisher chip
  /// We regex-lift those into [_CatalogWapp] entries and render a
  /// list of cards with an Install/Installed/Update button.
  Widget _buildOutputScreen() {
    final cs = Theme.of(context).colorScheme;
    final wapps = <_CatalogWapp>[];

    for (final line in _outputLines) {
      if (line.level == 'out') {
        final match =
            RegExp(r'^\s{2}(\S+)\s+v(\S+)(?:\s+\(([^)]+)\))?(.*)$')
                .firstMatch(line.text);
        if (match != null) {
          final name = match.group(1)!;
          final version = match.group(2)!;
          final size = match.group(3) ?? '';
          final status = match.group(4)?.trim() ?? '';
          // Override the wapp's `[installed]` claim with the actual
          // filesystem state: only true when the package is in the
          // shared archive AND has an app.wasm. This avoids stale
          // KV in the install wapp's own state from leaking false
          // "installed" badges.
          final base = wappArchiveBasePath();
          final actuallyInstalled = base != null &&
              File('$base/$name/app.wasm').existsSync();
          wapps.add(_CatalogWapp(
            name: name,
            version: version,
            size: size,
            updateAvailable: status.contains('[update:'),
            installed: actuallyInstalled,
            installer: WappInstallerService.instance,
          ));
          continue;
        }
        if (line.text.startsWith('    ') && wapps.isNotEmpty) {
          final meta = line.text.trimLeft();
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
      }
    }

    if (wapps.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No catalog entries yet.\n\n'
            'Open the Settings tab and add a repository URL — '
            'this wapp will fetch the index and list available '
            'wapps here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: wapps.length,
      itemBuilder: (_, i) => _buildWappCatalogCard(wapps[i], cs),
    );
  }

  Widget _buildWappCatalogCard(_CatalogWapp wapp, ColorScheme cs) {
    final isInstalled = wapp.installed;
    final actionLabel = wapp.updateAvailable
        ? 'Update'
        : (isInstalled ? 'Installed' : 'Install');
    final actionIcon = wapp.updateAvailable
        ? Icons.upgrade
        : (isInstalled ? Icons.check : Icons.download);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: getAppTypeGradient(
                    'wapp', Theme.of(context).brightness == Brightness.dark),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _catalogIconFor(wapp.name, 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    wapp.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text('v${wapp.version}',
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant)),
                      if (wapp.size.isNotEmpty) ...[
                        Text(' · ',
                            style: TextStyle(
                                fontSize: 11, color: cs.onSurfaceVariant)),
                        Text(wapp.size,
                            style: TextStyle(
                                fontSize: 11, color: cs.onSurfaceVariant)),
                      ],
                    ],
                  ),
                  if (wapp.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      wapp.description,
                      style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                          height: 1.3),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (wapp.sourceHost.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 6,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest
                                  .withAlpha(120),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  wapp.sourceHost == 'local'
                                      ? Icons.folder_outlined
                                      : Icons.cloud_outlined,
                                  size: 11,
                                  color: cs.onSurfaceVariant,
                                ),
                                const SizedBox(width: 3),
                                Text(wapp.sourceHost,
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: cs.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: isInstalled && !wapp.updateAvailable
                  ? null
                  : () => _sendCommand('install ${wapp.name}'),
              icon: Icon(actionIcon, size: 16),
              label: Text(actionLabel),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Resolve a catalog wapp's icon. Try multiple roots in order:
  ///   1. Shared archive: <baseDir>/wapps/<name>/        (post-install)
  ///   2. Source-tree archive: <cwd>/wapps/archive/<name>/ (pre-install
  ///      when running from a source checkout — same trick iwi uses)
  /// Falls back to `Icons.extension` when no manifest+SVG is found.
  Widget _catalogIconFor(String name, double size) {
    final roots = <String>[
      if (wappArchiveBasePath() != null) '${wappArchiveBasePath()}/$name',
      '${Directory.current.path}/wapps/archive/$name',
      '${Directory.current.path}/../wapps/archive/$name',
    ];
    for (final root in roots) {
      final manifestFile = File('$root/manifest.json');
      if (!manifestFile.existsSync()) continue;
      try {
        final manifest = jsonDecode(manifestFile.readAsStringSync())
            as Map<String, dynamic>;
        final icon = manifest['icon'];
        if (icon is! String) continue;
        if (!icon.toLowerCase().endsWith('.svg')) continue;
        if (!icon.contains('/') && !icon.contains('\\')) continue;
        final svgFile = File('$root/$icon');
        if (!svgFile.existsSync()) continue;
        return Padding(
          padding: EdgeInsets.all(size * 0.18),
          child: SvgPicture.memory(
            Uint8List.fromList(svgFile.readAsBytesSync()),
            fit: BoxFit.contain,
            theme: const SvgTheme(currentColor: Colors.white),
            placeholderBuilder: (_) =>
                Icon(Icons.extension, size: size, color: Colors.white),
          ),
        );
      } catch (_) {}
    }
    return Icon(Icons.extension, size: size, color: Colors.white);
  }

  /// Send a command to the running wapp. The protocol matches iwi:
  /// `{"command":"<cmd>","fields":{...}}` — the wapp reads
  /// `data['command']` in `module_handle_event` and acts.
  void _sendCommand(String cmd) {
    final scalarFields = <String, dynamic>{};
    // Mirror the source URL into the message so wapps can read it
    // back without round-tripping through KV.
    final source = _engine.kvKeys.contains('source')
        ? _storeSources.join('\n')
        : '';
    if (source.isNotEmpty) scalarFields['source'] = source;

    _engine.sendMessage(jsonEncode({
      'command': cmd,
      'fields': scalarFields,
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  /// Render the wapp store sources manager. The install wapp pushes
  /// the current source list as `store.sources` and listens for a
  /// `set_sources` action to update its KV.
  Widget _buildSourcesScreen() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Repositories',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add a URL pointing to a wapp index.json (or its parent '
            'directory). The store will fetch the index and list '
            'available wapps under the Store tab.',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _sourcesInputController,
                  decoration: const InputDecoration(
                    hintText: 'https://example.com/wapps/',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _onAddSource(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _onAddSource,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _storeSources.isEmpty
                ? Center(
                    child: Text(
                      'No repositories configured.',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    itemCount: _storeSources.length,
                    itemBuilder: (_, i) {
                      final url = _storeSources[i];
                      return Card(
                        elevation: 0,
                        margin: const EdgeInsets.only(bottom: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                              color: cs.outlineVariant.withAlpha(80)),
                        ),
                        child: ListTile(
                          leading: const Icon(Icons.cloud_outlined),
                          title: Text(
                            url,
                            style:
                                const TextStyle(fontFamily: 'monospace'),
                          ),
                          trailing: IconButton(
                            icon: Icon(Icons.delete_outline,
                                color: cs.error),
                            tooltip: 'Remove',
                            onPressed: () => _onRemoveSource(i),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _onAddSource() {
    final raw = _sourcesInputController.text.trim();
    if (raw.isEmpty) return;
    if (_storeSources.contains(raw)) {
      _appendOutput('Already in the list: $raw', 'err');
      return;
    }
    final next = [..._storeSources, raw];
    _sourcesInputController.clear();
    _pushSources(next);
  }

  void _onRemoveSource(int index) {
    if (index < 0 || index >= _storeSources.length) return;
    final next = [..._storeSources];
    next.removeAt(index);
    _pushSources(next);
  }
}

class _OutputLine {
  final String text;
  final String level;
  _OutputLine(this.text, this.level);
}

/// One row in the wapp store catalog, parsed from the install
/// wapp's structured `ui.append` log lines.
class _CatalogWapp {
  final String name;
  final String version;
  final String size;
  final bool installed;
  final bool updateAvailable;
  // Mutable: filled in by follow-up indented log lines.
  String description = '';
  String sourceHost = '';
  String publisherNpub = '';
  // Reference kept for future enrichment (signature reads, etc.).
  // ignore: unused_field
  final WappInstallerService installer;

  _CatalogWapp({
    required this.name,
    required this.version,
    required this.size,
    required this.installed,
    required this.updateAvailable,
    required this.installer,
  });
}

/// Minimal GeoUI binding: in-memory map. Stage 2 will round-trip
/// values through the WappEngine KV so WASM can observe them.
class _WappFieldBindings implements GeoUiBindings {
  final WappEngine engine;
  final VoidCallback onChange;
  final Map<String, dynamic> _values = {};

  _WappFieldBindings(this.engine, {required this.onChange});

  @override
  dynamic getValue(String name) => _values[name];

  @override
  void setValue(String name, dynamic value) {
    _values[name] = value;
    if (value is String) engine.kvSet(name, value);
    onChange();
  }
}
