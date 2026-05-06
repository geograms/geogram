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
import 'dart:io' show Directory, File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../geoui/geoui_ast.dart';
import '../geoui/geoui_parser.dart';
import '../geoui/geoui_renderer.dart';
import '../models/wapp_manifest.dart';
import '../services/app_service.dart';
import '../services/i18n_context.dart';
import '../services/location_provider_service.dart';
import '../services/config_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/profile_storage.dart';
import '../services/wapp_installer_service.dart';
import '../services/wapp_storage.dart';
import '../widgets/file_folder_picker.dart';
import '../util/event_bus.dart';
import '../util/geolocation_utils.dart';
import '../util/nostr_crypto.dart';
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

  /// Optional file the wapp should open immediately after init —
  /// used by the file-association launch path (see
  /// WappFileAssociations). When set, the host sends a single
  /// `file.open` message to the wapp once the engine has booted.
  final WappOpenFile? openFile;

  const WappPage({
    super.key,
    required this.wappId,
    required this.title,
    this.openFile,
  });

  // Debug API hook: the most-recently-mounted WappPage State. Lets
  // log_api_service.dart drive the active wapp from outside the
  // widget tree (send actions, snapshot UI state) without coupling
  // every caller to the internal _WappPageState type.
  static _WappPageState? activeState;

  /// Snapshot of the active wapp's UI state for debugging/testing.
  /// Returns null when no wapp is currently mounted.
  static Map<String, dynamic>? debugSnapshot() =>
      activeState?._debugSnapshot();

  /// Send an action message to the active wapp, as if the user had
  /// tapped a button with that action name. Returns true when an
  /// active wapp consumed the message.
  static bool debugSendAction(String name) {
    final s = activeState;
    if (s == null) return false;
    s._debugSendAction(name);
    return true;
  }

  /// Navigate the active wapp to a named screen. Returns false when no
  /// wapp is mounted or the screen name is not found.
  static bool debugNavigateTo(String screenName) {
    final s = activeState;
    if (s == null) return false;
    return s._debugNavigateTo(screenName);
  }

  /// Dump the raw GeoUI block tree for a named screen (or the active
  /// screen if screenName is empty). Useful for verifying declared
  /// structure without a screenshot.
  static Map<String, dynamic>? debugUiDef(String screenName) =>
      activeState?._debugUiDef(screenName);

  /// Set a field binding programmatically, as if the user had typed
  /// into an input. Returns false when no wapp is mounted.
  static bool debugSetField(String fieldName, String value) {
    final s = activeState;
    if (s == null) return false;
    s._debugSetField(fieldName, value);
    return true;
  }

  @override
  State<WappPage> createState() => _WappPageState();
}

class _WappPageState extends State<WappPage>
    with TickerProviderStateMixin {
  WappManifest? _manifest;
  WappEngine _engine = WappEngine();
  // Field bindings live on the State so the outbox `ui.set_field`
  // handler can push values into the form. Recreated on engine
  // reload (see _reload).
  late _WappFieldBindings _bindings = _WappFieldBindings(
    _engine,
    onChange: () {
      if (mounted) setState(() {});
    },
  );
  final List<GeoUiBlock> _screens = [];
  final List<String> _screenNames = [];
  TabController? _tabController;
  // When the wapp drives navigation explicitly via `ui.select_screen`,
  // hide the TabBar and render a single screen at a time with a
  // back-arrow on the AppBar. Wapps that never emit `ui.select_screen`
  // stay on the default tabbed layout for backwards compatibility.
  bool _stackNav = false;
  Timer? _tickTimer;
  String _status = 'Loading…';
  bool _crashed = false;

  // True when the user has flipped the global Wapp Store debug
  // toggle. Surfaces the AppBar Reload button + "(dev)" title
  // suffix. The button always reinstalls from the recorded source
  // (folder for type=path, ZIP for type=file/url).
  bool _devMode = false;

  // ── Wapp store state (used when a screen has a `$type="output"` or
  //    `$type="sources"` group). The install wapp pushes ui.append +
  //    store.sources messages and the host drives fetch_index +
  //    wapp.install on its behalf.
  final List<_OutputLine> _outputLines = [];
  List<String> _storeSources = const [];
  final _sourcesInputController = TextEditingController();

  // Generic card-list state. Any wapp can push a list of structured
  // items via {"type":"ui.data","target":"<group-name>","items":[…]}
  // and the host's `$type="cards"` group renders them. The wapp owns
  // the data and any visual hints (icon path, title, action labels).
  // No wapp-specific code in the host; this is a generic primitive.
  final Map<String, List<Map<String, dynamic>>> _cardsData = {};
  // Per-target attribute overrides (e.g. layout = "list"|"grid"),
  // mutated via {"type":"ui.attr","target":"…","attr":"…","value":…}.
  final Map<String, Map<String, String>> _cardsAttrs = {};
  // Icon resolution cache. Keyed by the raw `icon_path` value from the
  // wapp's ui.data item (e.g. "wapp:maps" or "/abs/path/x.svg"); value
  // is the loaded bytes (null = resolution failed, do not retry). The
  // build path reads from here only — no synchronous filesystem work
  // during paint. Refilled when ui.data arrives.
  final Map<String, Uint8List?> _cardIconBytes = {};

  // ── Location bridge (Section 12 of wapp-interfaces.md). Per-req_id
  //    subscription state + dispose callbacks for active
  //    location.subscribe streams; the passive listener keeps the
  //    engine's cached gps_lat/gps_lon in sync with whatever the
  //    rest of the host already knows.
  final Map<String, _LocationSub> _locSubs = {};
  StreamSubscription<LockedPosition>? _passiveLocSub;

  // ── Video group (`<group $type="video">`). Lazily instantiated on
  //    first `video.load` so wapps that never play video pay no
  //    media_kit cost. Disposed in [dispose].
  Player? _videoPlayer;
  VideoController? _videoController;
  String? _videoCurrentPath;

  @override
  void initState() {
    super.initState();
    WappPage.activeState = this;
    unawaited(_loadWapp());
  }

  Future<void> _loadWapp() async {
    try {
      // Show the dev affordances (title suffix + reload button) when
      // The Reload button is shown when the user flipped the global
      // "Debug mode" toggle in the Wapp Store (wapp.debugMode key in
      // ConfigService). Tapping reload re-runs the install from the
      // recorded source (URL/path/asset/file) and reboots the engine.
      _devMode =
          ConfigService().getNestedValue('wapp.debugMode', false) == true;

      // Wapp package — always read from the local archive at
      // <baseDir>/wapps/<wappId>/. Source-tree edits become visible
      // only after a reinstall (Reload button or store update).
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
      //     checkout, point the install wapp at the sibling
      //     `wapps` repo's binaries/ directory so the user has a
      //     working catalog out of the box. Layout assumed:
      //
      //       geograms/
      //       ├── geogram/   ← cwd while running launch-desktop.sh
      //       └── wapps/     ← https://github.com/.../wapps
      //           └── binaries/index.json
      if (widget.wappId == 'install' && !_engine.hasKvKey('source')) {
        final cwd = Directory.current.path;
        final candidates = [
          '$cwd/../wapps/binaries',     // sibling repo (canonical)
          '$cwd/../../wapps/binaries',  // nested workspace fallback
          '$cwd/wapps/binaries',        // legacy in-tree (before split)
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

      // 6b. Seed engine GPS cache with whatever the host already knows
      //     (e.g. the path-recording service is running) and listen
      //     passively for fresh fixes. This costs nothing when no
      //     consumer is active — the stream is silent and the cache
      //     simply reports INT32_MIN until someone spins up GPS.
      final initial = LocationProviderService().currentPosition;
      if (initial != null) {
        _engine.setLastLocation(
            lat: initial.latitude, lon: initial.longitude);
      }
      _passiveLocSub = LocationProviderService().positionStream.listen((pos) {
        _engine.setLastLocation(lat: pos.latitude, lon: pos.longitude);
      });

      // 7. Drain initial outbox produced by module_init
      _drainOutbox();

      // 7b. File-association launch: deliver the requested file to
      //     the wapp via a single `file.open` message. The wapp
      //     reads it from its inbox during the next handle_event
      //     and decides what to do (open the audio, render the
      //     text, refuse the mode, etc.). See Section 19 of
      //     wapps/wapp-interfaces.md.
      final open = widget.openFile;
      if (open != null) {
        _engine.sendMessage(jsonEncode(open.toJson()));
        _engine.handleEvent();
        _drainOutbox();
      }

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

          case 'ui.snackbar':
            // Generic transient toast. Any wapp can emit
            //   {"type":"ui.snackbar","text":"...",
            //    "level":"info|success|warn|error",
            //    "duration_ms": <optional>}
            // and the host shows a SnackBar via ScaffoldMessenger.
            final snackText = data['text']?.toString() ?? '';
            if (snackText.isNotEmpty && mounted) {
              final levelStr =
                  (data['level']?.toString() ?? 'info').toLowerCase();
              final cs = Theme.of(context).colorScheme;
              final bg = switch (levelStr) {
                'success' => Colors.green.shade700,
                'warn' || 'warning' => Colors.orange.shade800,
                'error' || 'err' => cs.error,
                _ => cs.inverseSurface,
              };
              final fg = switch (levelStr) {
                'success' || 'warn' || 'warning' || 'error' || 'err' =>
                    Colors.white,
                _ => cs.onInverseSurface,
              };
              final ms = (data['duration_ms'] as num?)?.toInt() ?? 3000;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    snackText,
                    style: TextStyle(color: fg),
                  ),
                  backgroundColor: bg,
                  duration: Duration(milliseconds: ms),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
            break;

          case 'ui.log.append':
            // Append text to a `$type:"log"` field. Generic — any
            // wapp with a log-typed form field can stream output
            // through this primitive. The wapp identifies the field
            // by name; the host owns the bindings list it backs.
            // Either `name`/`field` and either `text`/`line` is
            // accepted so wapps can match the spec literal or older
            // examples without breaking.
            final logField = (data['name'] ?? data['field']) as String?;
            final logText =
                (data['text'] ?? data['line']) as String? ?? '';
            if (logField != null &&
                logField.isNotEmpty &&
                logText.isNotEmpty) {
              final stored = _bindings.getValue(logField);
              final list = stored is List<String>
                  ? stored
                  : <String>[];
              // Split on newlines so multi-line writes become one
              // visible row per line. Drop an empty trailing element
              // when the text ended with \n.
              final parts = logText.split('\n');
              for (var i = 0; i < parts.length; i++) {
                if (i == parts.length - 1 && parts[i].isEmpty) break;
                list.add(parts[i]);
              }
              if (stored is! List<String>) {
                _bindings.setValue(logField, list);
              }
              changed = true;
            }
            break;

          case 'ui.data':
            // Generic card-list data push. Replaces (not appends) the
            // items associated with `target`. The host's `$type="cards"`
            // group renders one card per item.
            final target = data['target']?.toString();
            if (target != null && target.isNotEmpty) {
              final list = data['items'] as List?;
              final items = list == null
                  ? <Map<String, dynamic>>[]
                  : list
                      .whereType<Map>()
                      .map((m) => Map<String, dynamic>.from(m))
                      .toList();
              _cardsData[target] = items;
              // Pre-resolve and cache icon bytes off the build path.
              // Doing this in itemBuilder during paint serializes
              // hundreds of syscalls onto the UI thread and starves
              // the raster path (FL_IS_COMPOSITOR spam on Linux).
              for (final item in items) {
                final p = (item['icon_path'] as String?) ?? '';
                if (p.isEmpty || _cardIconBytes.containsKey(p)) continue;
                _cardIconBytes[p] = _loadCardIconBytes(p);
              }
              changed = true;
            }
            break;

          case 'ui.attr':
            // Generic per-group attribute override. The wapp can flip
            // a named attribute on a `cards` (or future) group at
            // runtime — e.g. layout from "list" to "grid". Only string
            // values are supported; the renderer reads the override
            // before falling back to the static UI declaration.
            final t = data['target']?.toString();
            final a = data['attr']?.toString();
            final v = data['value']?.toString();
            if (t != null && a != null && v != null &&
                t.isNotEmpty && a.isNotEmpty) {
              (_cardsAttrs[t] ??= {})[a] = v;
              changed = true;
            }
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

          case 'wapps.list_installed':
            // Generic primitive: enumerate every wapp in the shared
            // archive and return manifest snapshots. Any wapp that
            // wants to act as a launcher / admin / backup tool can
            // call this. Used by the App Creator's Projects tab.
            unawaited(_handleWappsListInstalled(data));
            break;

          case 'ui.set_field':
            // Generic primitive: push a value into a named form
            // field. Reverse of the form→KV auto-mirror — lets a
            // wapp pre-fill (or clear) the form when the user picks
            // a saved draft / project / preset.
            _handleUiSetField(data);
            break;

          case 'ui.select_screen':
            // Generic primitive: switch the active tab to the
            // screen with the given name. Lets a wapp navigate
            // between its own screens (e.g. master → detail) in
            // response to a card tap.
            _handleUiSelectScreen(data);
            break;

          case 'wapps.read_source':
            // Generic primitive: read a wapp's source files
            // (source.c, screens/home.ui.json, lang/en.json) from
            // the shared archive. Powers the App Creator's Edit
            // flow — selecting a card loads that wapp's code into
            // the editor tabs.
            unawaited(_handleWappsReadSource(data));
            break;
          case 'wapps.list_lang':
            unawaited(_handleWappsListLang(data));
            break;
          case 'wapps.read_lang':
            unawaited(_handleWappsReadLang(data));
            break;
          case 'wapps.write_lang':
            unawaited(_handleWappsWriteLang(data));
            break;

          // ── Generic primitives any wapp can use, gated by manifest
          //    permissions. The wapp emits a request with a req_id and
          //    a scope token (e.g. "collection.forum") and gets back
          //    a `<type>.response` message with the same req_id. The
          //    wapp must declare the matching permission token in its
          //    manifest.permissions array — see WappManifest.
          case 'profile.read':
            unawaited(_handleProfileRead(data));
            break;
          case 'profile.write':
            unawaited(_handleProfileWrite(data));
            break;
          case 'profile.list':
            unawaited(_handleProfileList(data));
            break;
          case 'profile.exists':
            unawaited(_handleProfileExists(data));
            break;
          case 'profile.size':
            unawaited(_handleProfileSize(data));
            break;
          case 'profile.mkdir':
            unawaited(_handleProfileMkdir(data));
            break;
          case 'profile.remove':
            unawaited(_handleProfileRemove(data));
            break;
          case 'identity.get':
            _handleIdentityGet(data);
            break;
          case 'sign.schnorr':
            _handleSignSchnorr(data);
            break;

          case 'tests.run':
            unawaited(_handleTestsRun(data));
            break;

          case 'location.request':
            unawaited(_handleLocationRequest(data));
            break;

          case 'location.subscribe':
            unawaited(_handleLocationSubscribe(data));
            break;

          case 'location.unsubscribe':
            _handleLocationUnsubscribe(data);
            break;

          case 'video.load':
            _handleVideoLoad(data);
            break;

          case 'video.subtitle':
            _handleVideoSubtitle(data);
            break;

          case 'video.play':
          case 'video.pause':
          case 'video.stop':
          case 'video.seek':
          case 'video.skip':
            _handleVideoCommand(type, data);
            break;

          case 'file.pick':
            unawaited(_handleFilePick(data));
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
      final lower = full.toLowerCase();
      final isUrl =
          lower.startsWith('http://') || lower.startsWith('https://');
      final ok = isUrl
          ? await WappInstallerService.instance.installFromUrl(
              wappId: name,
              url: full,
            )
          : await WappInstallerService.instance.installFromBytes(
              wappId: name,
              zipBytes: (await _readSourceBytes(full)) ?? Uint8List(0),
              source: WappSource.file(full),
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

  /// Walk the shared wapp archive and emit a manifest snapshot for
  /// every installed wapp. Generic — any wapp can call this.
  ///
  /// Response:
  ///   {"type":"wapps.list_installed.response","req_id":N,"status":0,
  ///    "items":[{"id":"...","name":"<slug>","title":"...",
  ///              "version":"...","kind":"app|system",
  ///              "description":"...","summary":"...","icon":"..."}, ...]}
  Future<void> _handleWappsListInstalled(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final archive = wappArchiveStorage();
    if (archive == null) {
      _engine.sendMessage(jsonEncode({
        'type': 'wapps.list_installed.response',
        'req_id': reqId,
        'status': -3,
        'error': 'archive unavailable',
        'items': const [],
      }));
      _engine.handleEvent();
      _drainOutbox();
      return;
    }
    final items = <Map<String, dynamic>>[];
    try {
      final entries = await archive.listDirectory('');
      for (final e in entries) {
        if (!e.isDirectory) continue;
        final slug = e.name;
        final mf = await archive.readJson('$slug/manifest.json');
        if (mf == null) continue;
        items.add({
          'id': (mf['id'] as String?) ?? slug,
          'name': slug,
          'title': (mf['title'] as String?) ??
              (mf['description'] as String?) ?? slug,
          'version': (mf['version'] as String?) ?? '',
          'kind': (mf['kind'] as String?) ?? 'app',
          'description': (mf['description'] as String?) ?? '',
          'summary': (mf['summary'] as String?) ?? '',
          'icon': (mf['icon'] as String?) ?? '',
        });
      }
    } catch (e) {
      _engine.sendMessage(jsonEncode({
        'type': 'wapps.list_installed.response',
        'req_id': reqId,
        'status': -3,
        'error': '$e',
        'items': const [],
      }));
      _engine.handleEvent();
      _drainOutbox();
      return;
    }
    items.sort((a, b) => (a['title'] as String)
        .toLowerCase()
        .compareTo((b['title'] as String).toLowerCase()));
    _engine.sendMessage(jsonEncode({
      'type': 'wapps.list_installed.response',
      'req_id': reqId,
      'status': 0,
      'items': items,
    }));
    /* Without this, the response sits in the wapp inbox until the
     * next tick — and a wapp with tick_interval_ms=0 (App Creator)
     * would never see it. */
    _engine.handleEvent();
    _drainOutbox();
  }

  /// Push a value into a named form field. Goes through the existing
  /// _WappFieldBindings.setValue so the form widget re-renders and
  /// the wapp KV stays in sync.
  void _handleUiSetField(Map<String, dynamic> data) {
    final name = data['name']?.toString();
    if (name == null || name.isEmpty) return;
    final value = data['value'];
    _bindings.setValue(name, value ?? '');
  }

  /// Switch the active screen to the one with the given name. Also
  /// flips the page into stack-navigation mode (no tab bar, single
  /// visible screen, back-arrow when not on the entry screen).
  void _handleUiSelectScreen(Map<String, dynamic> data) {
    final name = data['name']?.toString();
    if (name == null || name.isEmpty) return;
    final idx = _screenNames.indexOf(name);
    if (idx < 0) return;
    final c = _tabController;
    if (c == null) return;
    setState(() {
      _stackNav = true;
      if (idx != c.index) c.index = idx;
    });
  }

  /// Read a wapp's source files from the shared archive. Returns
  /// source.c, screens/home.ui.json, and lang/en.json contents.
  ///
  /// Request:
  ///   {"type":"wapps.read_source","slug":"<folder>","req_id":N}
  ///
  /// Response:
  ///   {"type":"wapps.read_source.response","req_id":N,"status":0,
  ///    "slug":"...","source":"...","source_ui":"...","source_lang":"..."}
  Future<void> _handleWappsReadSource(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final slug = data['slug']?.toString() ?? '';
    void deliver(Map<String, dynamic> body) {
      _engine.sendMessage(jsonEncode(body));
      _engine.handleEvent();
      _drainOutbox();
    }
    if (slug.isEmpty || slug.contains('..') || slug.contains('/')) {
      deliver({
        'type': 'wapps.read_source.response',
        'req_id': reqId,
        'status': -1,
        'error': 'invalid slug',
      });
      return;
    }
    final archive = wappArchiveStorage();
    if (archive == null) {
      deliver({
        'type': 'wapps.read_source.response',
        'req_id': reqId,
        'status': -3,
        'error': 'archive unavailable',
      });
      return;
    }
    String src = '';
    String srcUi = '';
    String srcLang = '';
    try {
      src = (await archive.readString('$slug/main.c')) ?? '';
      srcUi =
          (await archive.readString('$slug/screens/home.ui.json')) ?? '';
      srcLang = (await archive.readString('$slug/lang/en.json')) ?? '';
    } catch (e) {
      deliver({
        'type': 'wapps.read_source.response',
        'req_id': reqId,
        'status': -3,
        'error': '$e',
      });
      return;
    }
    deliver({
      'type': 'wapps.read_source.response',
      'req_id': reqId,
      'status': 0,
      'slug': slug,
      'source': src,
      'source_ui': srcUi,
      'source_lang': srcLang,
    });
  }

  /// List lang/*.json files for a wapp slug.
  /// Out: {"type":"wapps.list_lang","slug":"<slug>","req_id":N}
  /// In:  {"type":"wapps.list_lang.response","req_id":N,"langs":["en","fr"]}
  Future<void> _handleWappsListLang(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final slug = data['slug']?.toString() ?? '';
    final archive = wappArchiveStorage();
    if (archive == null || slug.isEmpty || slug.contains('..')) {
      _engine.sendMessage(jsonEncode({
        'type': 'wapps.list_lang.response',
        'req_id': reqId,
        'langs': <String>[],
      }));
      _engine.handleEvent();
      _drainOutbox();
      return;
    }
    final entries = await archive.listDirectory('$slug/lang');
    final langs = entries
        .where((e) => e.path.endsWith('.json'))
        .map((e) {
          final name = e.path.split('/').last;
          return name.substring(0, name.length - 5);
        })
        .toList()
      ..sort();
    _engine.sendMessage(jsonEncode({
      'type': 'wapps.list_lang.response',
      'req_id': reqId,
      'langs': langs,
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  /// Read a specific lang file from a wapp's archive.
  /// Out: {"type":"wapps.read_lang","slug":"...","lang":"fr","req_id":N}
  /// In:  {"type":"wapps.read_lang.response","req_id":N,"lang":"fr","content":"..."}
  Future<void> _handleWappsReadLang(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final slug = data['slug']?.toString() ?? '';
    final lang = data['lang']?.toString() ?? 'en';
    final archive = wappArchiveStorage();
    if (archive == null || slug.isEmpty || slug.contains('..') ||
        lang.isEmpty || lang.contains('/')) {
      _engine.sendMessage(jsonEncode({
        'type': 'wapps.read_lang.response',
        'req_id': reqId,
        'lang': lang,
        'content': '',
      }));
      _engine.handleEvent();
      _drainOutbox();
      return;
    }
    final content =
        (await archive.readString('$slug/lang/$lang.json')) ?? '';
    _engine.sendMessage(jsonEncode({
      'type': 'wapps.read_lang.response',
      'req_id': reqId,
      'lang': lang,
      'content': content,
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  /// Write a lang file into a wapp's archive.
  /// Out: {"type":"wapps.write_lang","slug":"...","lang":"fr","content":"...","req_id":N}
  /// In:  {"type":"wapps.write_lang.response","req_id":N,"ok":true}
  Future<void> _handleWappsWriteLang(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final slug = data['slug']?.toString() ?? '';
    final lang = data['lang']?.toString() ?? '';
    final content = data['content']?.toString() ?? '';
    final archive = wappArchiveStorage();
    bool ok = false;
    if (archive != null && slug.isNotEmpty && !slug.contains('..') &&
        lang.isNotEmpty && !lang.contains('/') && content.isNotEmpty) {
      try {
        await archive.createDirectory('$slug/lang');
        await archive.writeBytes(
            '$slug/lang/$lang.json',
            Uint8List.fromList(content.codeUnits));
        ok = true;
      } catch (e) {
        LogService().log('WappPage: write_lang failed: $e');
      }
    }
    _engine.sendMessage(jsonEncode({
      'type': 'wapps.write_lang.response',
      'req_id': reqId,
      'ok': ok,
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  // ── Generic outbox primitives (profile / identity / sign) ─────────
  // Each request carries a numeric req_id and (for profile.*) a scope
  // token like "collection.forum" plus a relative path. The handler
  // validates the wapp's manifest grants the matching permission
  // ("collection.forum.read" / ".write" / "identity.read" / "sign"),
  // resolves the path to a profile-relative path, performs the op via
  // AppService().profileStorage / ProfileService / NostrCrypto, and
  // emits a `<type>.response` message back to the wapp with the same
  // req_id. Status code: 0=ok, -1=denied, -2=not found, -3=other.

  /// Map a scope token to its profile-relative root path. Returns null
  /// for unknown scopes. Today only "collection.<id>" is supported;
  /// the path resolves to "collections/<id>/" inside the active
  /// profile.
  String? _resolveScopeRoot(String scope) {
    if (scope.startsWith('collection.')) {
      final id = scope.substring('collection.'.length);
      if (id.isEmpty) return null;
      return 'collections/$id';
    }
    return null;
  }

  /// Reject obviously bad relative paths — empty, absolute, contains
  /// `..` segments. The host trusts no wapp input; even with the
  /// permission grant, a wapp can only touch paths under the granted
  /// root. Returns the trimmed path or null on rejection.
  String? _safeRelPath(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return '';
    if (s.startsWith('/') || s.startsWith('\\')) return null;
    final segs = s.split(RegExp(r'[\\/]+'));
    for (final seg in segs) {
      if (seg == '..' || seg == '.') return null;
    }
    return s;
  }

  /// Returns true when the manifest grants the given permission token
  /// (e.g. "collection.forum.read"). Logs a denial when missing so
  /// developers can spot manifest typos.
  bool _wappHasPerm(String token) {
    final m = _manifest;
    if (m == null) return false;
    final ok = m.hasPermission(token);
    if (!ok) {
      LogService().log(
          'WappPage[${m.id}] denied: missing permission "$token"');
    }
    return ok;
  }

  /// Send a {type: "<base>.response", req_id, status, ...extras} reply
  /// back to the wapp. The wapp reads it via hal_msg_recv inside its
  /// next module_handle_event invocation.
  void _sendOutboxResponse(
    String baseType,
    int reqId,
    int status, {
    Map<String, Object?> extras = const {},
  }) {
    _engine.sendMessage(jsonEncode({
      'type': '$baseType.response',
      'req_id': reqId,
      'status': status,
      ...extras,
    }));
    _engine.handleEvent();
  }

  /// Resolve `scope` + `path` against the granted root, also checking
  /// the right read/write permission. Returns the profile-relative
  /// path on success. On failure, sends the denial response itself
  /// and returns null so callers can early-exit.
  String? _resolveScopedPath(
    Map<String, dynamic> data,
    String baseType,
    int reqId, {
    required bool needWrite,
  }) {
    final scope = (data['scope'] as String? ?? '').trim();
    final root = _resolveScopeRoot(scope);
    if (root == null) {
      _sendOutboxResponse(baseType, reqId, -1, extras: {
        'error': 'unknown scope',
      });
      return null;
    }
    final perm = needWrite ? '$scope.write' : '$scope.read';
    if (!_wappHasPerm(perm)) {
      _sendOutboxResponse(baseType, reqId, -1, extras: {
        'error': 'missing permission $perm',
      });
      return null;
    }
    final rel = _safeRelPath(data['path'] as String?);
    if (rel == null) {
      _sendOutboxResponse(baseType, reqId, -1, extras: {
        'error': 'invalid path',
      });
      return null;
    }
    return rel.isEmpty ? root : '$root/$rel';
  }

  /// Active ProfileStorage or null when no profile is loaded yet.
  /// When null, profile.* handlers respond with status -3 so the wapp
  /// can show a clear "profile not ready" state instead of hanging.
  ProfileStorage? _profileStorageOrNull() => AppService().profileStorage;

  Future<void> _handleProfileRead(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final full = _resolveScopedPath(data, 'profile.read', reqId,
        needWrite: false);
    if (full == null) return;
    final ps = _profileStorageOrNull();
    if (ps == null) {
      _sendOutboxResponse('profile.read', reqId, -3,
          extras: {'error': 'profile storage unavailable'});
      return;
    }
    try {
      final s = await ps.readString(full);
      if (s == null) {
        _sendOutboxResponse('profile.read', reqId, -2);
        return;
      }
      _sendOutboxResponse('profile.read', reqId, 0, extras: {'data': s});
    } catch (e) {
      _sendOutboxResponse('profile.read', reqId, -3,
          extras: {'error': '$e'});
    }
  }

  Future<void> _handleProfileWrite(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final full = _resolveScopedPath(data, 'profile.write', reqId,
        needWrite: true);
    if (full == null) return;
    final ps = _profileStorageOrNull();
    if (ps == null) {
      _sendOutboxResponse('profile.write', reqId, -3,
          extras: {'error': 'profile storage unavailable'});
      return;
    }
    final mode = (data['mode'] as String? ?? 'write').trim();
    final body = (data['data'] as String?) ?? '';
    try {
      if (mode == 'append') {
        await ps.appendString(full, body);
      } else {
        await ps.writeString(full, body);
      }
      _sendOutboxResponse('profile.write', reqId, 0);
    } catch (e) {
      _sendOutboxResponse('profile.write', reqId, -3,
          extras: {'error': '$e'});
    }
  }

  Future<void> _handleProfileList(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final full = _resolveScopedPath(data, 'profile.list', reqId,
        needWrite: false);
    if (full == null) return;
    final ps = _profileStorageOrNull();
    if (ps == null) {
      _sendOutboxResponse('profile.list', reqId, -3,
          extras: {'error': 'profile storage unavailable'});
      return;
    }
    try {
      final entries = await ps.listDirectory(full);
      _sendOutboxResponse('profile.list', reqId, 0, extras: {
        'entries': [
          for (final e in entries)
            {
              'name': e.name,
              'is_dir': e.isDirectory,
              if (e.size != null) 'size': e.size,
            }
        ],
      });
    } catch (e) {
      _sendOutboxResponse('profile.list', reqId, -3,
          extras: {'error': '$e'});
    }
  }

  Future<void> _handleProfileExists(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final full = _resolveScopedPath(data, 'profile.exists', reqId,
        needWrite: false);
    if (full == null) return;
    final ps = _profileStorageOrNull();
    if (ps == null) {
      _sendOutboxResponse('profile.exists', reqId, -3,
          extras: {'error': 'profile storage unavailable'});
      return;
    }
    try {
      final isFile = await ps.exists(full);
      final isDir = isFile ? false : await ps.directoryExists(full);
      _sendOutboxResponse('profile.exists', reqId, 0, extras: {
        'exists': isFile || isDir,
        'is_dir': isDir,
      });
    } catch (e) {
      _sendOutboxResponse('profile.exists', reqId, -3,
          extras: {'error': '$e'});
    }
  }

  Future<void> _handleProfileSize(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final full = _resolveScopedPath(data, 'profile.size', reqId,
        needWrite: false);
    if (full == null) return;
    final ps = _profileStorageOrNull();
    if (ps == null) {
      _sendOutboxResponse('profile.size', reqId, -3,
          extras: {'error': 'profile storage unavailable'});
      return;
    }
    try {
      final bytes = await ps.readBytes(full);
      _sendOutboxResponse('profile.size', reqId, 0, extras: {
        'size': bytes?.length ?? 0,
        'exists': bytes != null,
      });
    } catch (e) {
      _sendOutboxResponse('profile.size', reqId, -3,
          extras: {'error': '$e'});
    }
  }

  Future<void> _handleProfileMkdir(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final full = _resolveScopedPath(data, 'profile.mkdir', reqId,
        needWrite: true);
    if (full == null) return;
    final ps = _profileStorageOrNull();
    if (ps == null) {
      _sendOutboxResponse('profile.mkdir', reqId, -3,
          extras: {'error': 'profile storage unavailable'});
      return;
    }
    try {
      await ps.createDirectory(full);
      _sendOutboxResponse('profile.mkdir', reqId, 0);
    } catch (e) {
      _sendOutboxResponse('profile.mkdir', reqId, -3,
          extras: {'error': '$e'});
    }
  }

  Future<void> _handleProfileRemove(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final full = _resolveScopedPath(data, 'profile.remove', reqId,
        needWrite: true);
    if (full == null) return;
    final ps = _profileStorageOrNull();
    if (ps == null) {
      _sendOutboxResponse('profile.remove', reqId, -3,
          extras: {'error': 'profile storage unavailable'});
      return;
    }
    try {
      if (await ps.exists(full)) {
        await ps.delete(full);
      } else if (await ps.directoryExists(full)) {
        await ps.deleteDirectory(full, recursive: false);
      } else {
        _sendOutboxResponse('profile.remove', reqId, -2);
        return;
      }
      _sendOutboxResponse('profile.remove', reqId, 0);
    } catch (e) {
      _sendOutboxResponse('profile.remove', reqId, -3,
          extras: {'error': '$e'});
    }
  }

  void _handleIdentityGet(Map<String, dynamic> data) {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    if (!_wappHasPerm('identity.read')) {
      _sendOutboxResponse('identity.get', reqId, -1, extras: {
        'error': 'missing permission identity.read',
      });
      return;
    }
    try {
      final p = ProfileService().getProfile();
      _sendOutboxResponse('identity.get', reqId, 0, extras: {
        'callsign': p.callsign,
        'npub': p.npub,
      });
    } catch (e) {
      _sendOutboxResponse('identity.get', reqId, -3,
          extras: {'error': '$e'});
    }
  }

  void _handleSignSchnorr(Map<String, dynamic> data) {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    if (!_wappHasPerm('sign')) {
      _sendOutboxResponse('sign.schnorr', reqId, -1, extras: {
        'error': 'missing permission sign',
      });
      return;
    }
    final messageHex = (data['message_hex'] as String? ?? '').trim();
    if (messageHex.isEmpty || messageHex.length != 64) {
      _sendOutboxResponse('sign.schnorr', reqId, -3, extras: {
        'error': 'message_hex must be a 32-byte hex digest',
      });
      return;
    }
    try {
      final p = ProfileService().getProfile();
      if (p.nsec.isEmpty) {
        _sendOutboxResponse('sign.schnorr', reqId, -1, extras: {
          'error': 'no nsec on active profile',
        });
        return;
      }
      // ProfileService stores nsec as bech32 ("nsec1..."); NostrCrypto
      // wants the raw hex private key. Decode if needed.
      String hexKey = p.nsec;
      if (hexKey.startsWith('nsec1')) {
        hexKey = NostrCrypto.decodeNsec(hexKey);
      }
      final sig = NostrCrypto.schnorrSign(messageHex, hexKey);
      _sendOutboxResponse('sign.schnorr', reqId, 0, extras: {
        'signature_hex': sig,
      });
    } catch (e) {
      _sendOutboxResponse('sign.schnorr', reqId, -3,
          extras: {'error': '$e'});
    }
  }

  // ── tests.run ────────────────────────────────────────────────────
  // Boot a throw-away WappEngine on the target wapp's tests.wasm,
  // call module_run_tests, and forward every tests.case +
  // tests.complete message back to the requester. Self-tests are
  // always allowed; running tests on a different wapp requires the
  // `tests.invoke` permission. See wapps/wapp-interfaces.md §20 for
  // the wire protocol.

  Future<void> _handleTestsRun(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as num?)?.toInt() ?? 0;
    final selfId = widget.wappId;
    final rawTarget = (data['target'] as String? ?? '').trim();
    final target = rawTarget.isEmpty ? selfId : rawTarget;
    final isSelf = target == selfId;

    if (!isSelf && !_wappHasPerm('tests.invoke')) {
      _emitTestsComplete(reqId, -1, error: 'missing permission tests.invoke');
      return;
    }

    final pkg = wappPackageStorage(target);
    if (pkg == null) {
      _emitTestsComplete(reqId, -3,
          error: 'wapp archive unavailable for $target');
      return;
    }

    Uint8List? bytes;
    try {
      bytes = await pkg.readBytes('tests.wasm');
    } catch (e) {
      _emitTestsComplete(reqId, -3, error: 'read failed: $e');
      return;
    }
    if (bytes == null || bytes.isEmpty) {
      _emitTestsComplete(reqId, -2, error: 'no tests.wasm in $target');
      return;
    }

    final runner = WappEngine();
    try {
      await runner.load(bytes);
      runner.kvSet('__tests_req_id', reqId.toString());
      runner.runTests();
      for (final msg in runner.drainOutbox()) {
        _engine.sendMessage(msg);
      }
    } catch (e) {
      _emitTestsComplete(reqId, -3, error: 'runner crashed: $e');
    } finally {
      runner.dispose();
    }
    // Let the wapp's module_handle_event consume the tests.case +
    // tests.complete messages we just queued — without this they
    // sit in the inbox until the next tick.
    _engine.handleEvent();
    _drainOutbox();
  }

  /// Emit a single `tests.complete` into the requester's inbox. Used
  /// when the runner can't even start (missing tests.wasm, permission
  /// denied, load error). The wapp's normal handler treats this as
  /// the terminal message, no `tests.case` precede it.
  void _emitTestsComplete(int reqId, int status, {String? error}) {
    final m = <String, dynamic>{
      'type': 'tests.complete',
      'req_id': reqId,
      'status': status,
      'passed': 0,
      'failed': 0,
      'duration_ms': 0,
      'error': error,
    };
    _engine.sendMessage(jsonEncode(m));
    _engine.handleEvent();
    _drainOutbox();
  }

  // ── Location bridge ────────────────────────────────────────────────
  // Implements the message-channel API documented in Section 12 of
  // wapps/wapp-interfaces.md. Wapps that only want a passive readout
  // can keep using the cheap synchronous hal_sensor_gps_lat/lon pair
  // (kept warm by the passive positionStream listener). Wapps that
  // need an explicit fix or a continuous stream go through these
  // handlers so the host can control power, permissions, and
  // accuracy.

  Future<void> _handleLocationRequest(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as String? ?? '').trim();
    if (reqId.isEmpty) return;

    if (!_locationAllowed()) {
      _replyLocationError(reqId, 'permission_denied',
          isUpdate: false);
      return;
    }

    final hint = (data['accuracy'] as String? ?? 'balanced').toLowerCase();
    final maxAgeMs = (data['max_age_ms'] as num?)?.toInt() ?? 0;
    final timeoutMs = (data['timeout_ms'] as num?)?.toInt() ?? 15000;
    final allowCached = data['allow_cached'] as bool? ?? true;

    if (allowCached && maxAgeMs > 0) {
      final cached = LocationProviderService().currentPosition;
      if (cached != null &&
          DateTime.now().difference(cached.timestamp).inMilliseconds <=
              maxAgeMs) {
        _engine.setLastLocation(
            lat: cached.latitude, lon: cached.longitude);
        _replyLocation(reqId, cached, cached: true, isUpdate: false);
        return;
      }
    }

    final started = DateTime.now();
    var didTimeout = false;
    try {
      final result = await _detectLocationWithHint(
        hint: hint,
        timeout: Duration(milliseconds: timeoutMs),
      ).timeout(
        Duration(milliseconds: timeoutMs + 500),
        onTimeout: () {
          didTimeout = true;
          return null;
        },
      );
      if (result == null) {
        // Discriminate timeout vs other failure (permission denied,
        // hardware off, network fallback all returned nothing).
        final elapsed = DateTime.now().difference(started).inMilliseconds;
        final code = (didTimeout || elapsed >= timeoutMs)
            ? 'timeout'
            : 'no_provider';
        _replyLocationError(reqId, code, isUpdate: false);
        return;
      }
      final pos = LockedPosition.fromGeolocationResult(result);
      _engine.setLastLocation(lat: pos.latitude, lon: pos.longitude);
      _replyLocation(reqId, pos, cached: false, isUpdate: false);
    } catch (e) {
      LogService().log(
          'WappPage[${_manifest?.id ?? widget.wappId}] location.request error: $e');
      final code = e is TimeoutException ? 'timeout' : 'no_provider';
      _replyLocationError(reqId, code, isUpdate: false);
    }
  }

  Future<void> _handleLocationSubscribe(Map<String, dynamic> data) async {
    final reqId = (data['req_id'] as String? ?? '').trim();
    if (reqId.isEmpty) return;

    if (!_locationAllowed()) {
      _replyLocationError(reqId, 'permission_denied', isUpdate: false);
      return;
    }

    // Replace any previous subscription for this req_id.
    _locSubs.remove(reqId)?.dispose?.call();

    final hint = (data['accuracy'] as String? ?? 'balanced').toLowerCase();
    final minIntervalMs = (data['min_interval_ms'] as num?)?.toInt() ?? 5000;
    final minDistanceM = (data['min_distance_m'] as num?)?.toDouble() ?? 0.0;
    final intervalSec = (minIntervalMs / 1000).ceil().clamp(1, 3600);

    final sub = _LocationSub(
      hint: hint,
      minIntervalMs: minIntervalMs,
      minDistanceM: minDistanceM,
    );
    _locSubs[reqId] = sub;

    try {
      sub.dispose = await LocationProviderService().registerConsumer(
        intervalSeconds: intervalSec,
        // "best" requests pure GPS; LocationProviderService treats
        // highFidelity as bestForNavigation + distanceFilter=0.
        highFidelity: hint == 'best',
        onPosition: (pos) => _onSubscribedFix(reqId, pos),
      );
      // If we already have a fix, deliver it immediately so the wapp
      // doesn't have to wait for the next interval.
      final cached = LocationProviderService().currentPosition;
      if (cached != null) {
        _onSubscribedFix(reqId, cached, forceCached: true);
      }
    } catch (e) {
      _locSubs.remove(reqId);
      // registerConsumer throws on permission failure / disabled GPS.
      final msg = e.toString().toLowerCase();
      final code = msg.contains('permission')
          ? 'permission_denied'
          : (msg.contains('disabled') ? 'disabled' : 'no_provider');
      _replyLocationError(reqId, code, isUpdate: false);
    }
  }

  /// Per-subscription fan-out: applies min_interval / min_distance
  /// throttling before forwarding the fix as a `location.update`.
  void _onSubscribedFix(String reqId, LockedPosition pos,
      {bool forceCached = false}) {
    final sub = _locSubs[reqId];
    if (sub == null) return;

    _engine.setLastLocation(lat: pos.latitude, lon: pos.longitude);

    final now = DateTime.now();
    if (!forceCached) {
      // min_interval throttle.
      final last = sub.lastDeliveredAt;
      if (last != null &&
          now.difference(last).inMilliseconds < sub.minIntervalMs) {
        return;
      }
      // min_distance throttle.
      if (sub.minDistanceM > 0 && sub.lastLat != null && sub.lastLon != null) {
        final d = Geolocator.distanceBetween(
            sub.lastLat!, sub.lastLon!, pos.latitude, pos.longitude);
        if (d < sub.minDistanceM) return;
      }
    }

    sub.lastDeliveredAt = now;
    sub.lastLat = pos.latitude;
    sub.lastLon = pos.longitude;
    _replyLocation(reqId, pos, cached: forceCached, isUpdate: true);
  }

  void _handleLocationUnsubscribe(Map<String, dynamic> data) {
    final reqId = (data['req_id'] as String? ?? '').trim();
    if (reqId.isEmpty) return;
    _locSubs.remove(reqId)?.dispose?.call();
  }

  /// Map an accuracy hint to a concrete detection chain.
  ///
  /// - coarse:   skip GPS entirely (profile fallback → IP), minimal power
  /// - balanced: default chain in GeolocationUtils — GPS where available
  ///             with normal accuracy, else profile/IP
  /// - fine:     GPS forced at LocationAccuracy.high (fused)
  /// - best:     GPS forced at LocationAccuracy.bestForNavigation
  Future<GeolocationResult?> _detectLocationWithHint({
    required String hint,
    required Duration timeout,
  }) async {
    switch (hint) {
      case 'coarse':
        final profile = GeolocationUtils.getProfileLocation();
        if (profile != null) return profile;
        return await GeolocationUtils.detectViaIP();

      case 'fine':
      case 'best':
        if (kIsWeb) {
          final web = await GeolocationUtils.detectViaBrowser(
              timeout: timeout, requestPermission: true);
          if (web != null) return web;
          return await GeolocationUtils.detectViaIP();
        }
        try {
          var permission = await Geolocator.checkPermission();
          if (permission == LocationPermission.denied) {
            permission = await Geolocator.requestPermission();
          }
          if (permission == LocationPermission.denied ||
              permission == LocationPermission.deniedForever) {
            return null;
          }
          if (!await Geolocator.isLocationServiceEnabled()) return null;
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: LocationSettings(
              accuracy: hint == 'best'
                  ? LocationAccuracy.bestForNavigation
                  : LocationAccuracy.high,
              timeLimit: timeout,
            ),
          );
          return GeolocationResult(
            latitude: pos.latitude,
            longitude: pos.longitude,
            source: 'gps',
            accuracy: pos.accuracy,
          );
        } catch (_) {
          return null;
        }

      case 'balanced':
      default:
        return await GeolocationUtils.getCurrentLocation(timeout: timeout);
    }
  }

  /// Manifest gate per Section 12.4: a wapp must declare
  /// `requires.hal: ["sensor.location"]` (or `"sensor_location"` —
  /// some manifests omit dotted form) before the engine honours any
  /// location.* message. Refusing here mirrors the install dialog
  /// promise.
  bool _locationAllowed() {
    final m = _manifest;
    if (m == null) return false;
    return m.halRequires.contains('sensor.location') ||
        m.halRequires.contains('sensor_location');
  }

  void _replyLocation(
    String reqId,
    LockedPosition pos, {
    required bool cached,
    required bool isUpdate,
  }) {
    _engine.sendMessage(jsonEncode({
      'type': isUpdate ? 'location.update' : 'location.response',
      'req_id': reqId,
      'lat': pos.latitude,
      'lon': pos.longitude,
      'altitude_m': pos.altitude,
      'accuracy_m': pos.accuracy,
      'speed_mps': pos.speed,
      'heading_deg': pos.heading,
      'fix_at': pos.timestamp.millisecondsSinceEpoch ~/ 1000,
      'source': pos.source,
      'cached': cached,
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  void _replyLocationError(
    String reqId,
    String error, {
    required bool isUpdate,
  }) {
    _engine.sendMessage(jsonEncode({
      'type': isUpdate ? 'location.update' : 'location.response',
      'req_id': reqId,
      'error': error,
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  /// Open an OS file picker on behalf of a wapp and deliver the
  /// selection back as `file.open` (same protocol as the file-
  /// association launch). Wapps emit:
  ///
  /// ```json
  /// {
  ///   "type": "file.pick",
  ///   "title": "Pick a video",
  ///   "extensions": ["mp4","mkv",...],
  ///   "mode": "view"
  /// }
  /// ```
  ///
  /// The host shows the picker, then on selection sends the wapp:
  /// `{"type":"file.open","path":...,"name":...,"extension":...,"mode":...}`.
  /// On cancel the host sends nothing.
  Future<void> _handleFilePick(Map<String, dynamic> data) async {
    final extensions = (data['extensions'] as List?)
        ?.map((e) => e.toString().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    final title = (data['title'] as String?) ?? 'Pick a file';
    final mode = (data['mode'] as String?) ?? 'view';
    if (!mounted) return;
    try {
      final picked = await FileFolderPicker.show(
        context,
        title: title,
        allowMultiSelect: false,
        allowedExtensions: extensions,
        // Encrypted profiles surface their files through this
        // ProfileStorage; passing it lets the picker browse inside
        // the active profile's storage backend, not just the OS
        // filesystem.
        profileStorage: AppService().profileStorage,
      );
      if (picked == null || picked.isEmpty) return;
      final path = picked.first;
      final dot = path.lastIndexOf('.');
      final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
      final slash = path.lastIndexOf('/');
      final name = slash >= 0 ? path.substring(slash + 1) : path;
      _engine.sendMessage(jsonEncode({
        'type': 'file.open',
        'path': path,
        'name': name,
        'extension': ext,
        'mode': mode,
        // Size is optional in the file.open protocol. We deliberately
        // don't reach into dart:io File here — that breaks on web
        // and on encrypted profiles where the path is virtual. The
        // wapp can request a size via the (future) file.stat
        // round-trip if it ever needs one.
        'size': -1,
      }));
      _engine.handleEvent();
      _drainOutbox();
    } catch (e) {
      LogService().log(
          'WappPage[${_manifest?.id ?? widget.wappId}] file.pick failed: $e');
    }
  }

  // ── Video bridge (`<group $type="video">`) ────────────────────────
  // The wapp drives playback through messages; the host owns the
  // media_kit Player + VideoController. The wapp's GeoUI screen
  // declares a `<group $type="video">` element which renders as a
  // Video widget bound to [_videoController].

  void _ensureVideoStack() {
    if (_videoPlayer != null) return;
    _videoPlayer = Player();
    _videoController = VideoController(_videoPlayer!);
  }

  void _handleVideoLoad(Map<String, dynamic> data) {
    final path = (data['path'] as String? ?? '').trim();
    if (path.isEmpty) return;
    _ensureVideoStack();
    _videoCurrentPath = path;
    final autoplay = data['autoplay'] != false;
    try {
      _videoPlayer!.open(Media(path), play: autoplay);
    } catch (e) {
      LogService().log(
          'WappPage[${_manifest?.id ?? widget.wappId}] video.load failed: $e');
    }
    // Auto-attach a sidecar subtitle if one is sitting next to the
    // video. Standard convention used by VLC, mpv, ExoPlayer: same
    // basename, .srt extension (or the language-tagged variants
    // ".en.srt" / ".eng.srt"). The wapp can override later by
    // sending an explicit `video.subtitle` message.
    final sidecar = _findSidecarSubtitle(path);
    if (sidecar != null) {
      try {
        _videoPlayer!.setSubtitleTrack(SubtitleTrack.uri(sidecar));
      } catch (e) {
        LogService().log(
            'WappPage[${_manifest?.id ?? widget.wappId}] sidecar subtitle '
            'attach failed ($sidecar): $e');
      }
    }
    if (mounted) setState(() {});
  }

  /// Look next to [videoPath] for a same-basename subtitle file in
  /// the formats media_kit can attach via SubtitleTrack.uri:
  /// `.srt`, `.vtt`, `.ass`, `.ssa`, `.sub`. Also tries the common
  /// language-tagged variants `.en.srt` / `.eng.srt`. Returns the
  /// first match or null.
  String? _findSidecarSubtitle(String videoPath) {
    final dot = videoPath.lastIndexOf('.');
    if (dot <= 0) return null;
    final base = videoPath.substring(0, dot);
    const exts = ['srt', 'vtt', 'ass', 'ssa', 'sub'];
    const langs = ['', '.en', '.eng', '.und'];
    for (final lang in langs) {
      for (final ext in exts) {
        final candidate = '$base$lang.$ext';
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }

  void _handleVideoSubtitle(Map<String, dynamic> data) {
    final p = _videoPlayer;
    if (p == null) return;
    // `{"type":"video.subtitle","off":true}` clears the active
    // track. Otherwise we expect a path to an SRT/VTT/etc file.
    if (data['off'] == true) {
      try {
        p.setSubtitleTrack(SubtitleTrack.no());
      } catch (_) {}
      return;
    }
    final path = (data['path'] as String? ?? '').trim();
    if (path.isEmpty) return;
    final language = (data['language'] as String?)?.trim();
    final title = (data['title'] as String?)?.trim();
    try {
      p.setSubtitleTrack(SubtitleTrack.uri(
        path,
        title: (title?.isNotEmpty ?? false) ? title : null,
        language: (language?.isNotEmpty ?? false) ? language : null,
      ));
    } catch (e) {
      LogService().log(
          'WappPage[${_manifest?.id ?? widget.wappId}] video.subtitle '
          'attach failed: $e');
    }
  }

  void _handleVideoCommand(String type, Map<String, dynamic> data) {
    final p = _videoPlayer;
    if (p == null) return;
    switch (type) {
      case 'video.play':
        p.play();
        break;
      case 'video.pause':
        p.pause();
        break;
      case 'video.stop':
        p.stop();
        break;
      case 'video.seek':
        // Absolute seek to the given position in milliseconds.
        final pos = (data['position_ms'] as num?)?.toInt();
        if (pos != null) p.seek(Duration(milliseconds: pos));
        break;
      case 'video.skip':
        // Relative jump (positive = forward, negative = backward).
        final delta = (data['delta_ms'] as num?)?.toInt() ?? 0;
        if (delta == 0) break;
        final cur = p.state.position;
        final dur = p.state.duration;
        var target = cur + Duration(milliseconds: delta);
        if (target < Duration.zero) target = Duration.zero;
        if (dur > Duration.zero && target > dur) target = dur;
        p.seek(target);
        break;
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

  /// Tear down everything that's tied to the running engine but not
  /// to the widget itself: the tick timer, location subscriptions,
  /// the media_kit player, and the engine instance. Used by both
  /// [dispose] (terminal teardown) and [_reload] (transient teardown
  /// for the dev source-tree workflow). Callers are responsible for
  /// disposing the TabController and clearing the screen list — the
  /// reload path keeps showing the AppBar while a new engine boots,
  /// and the dispose path runs after the widget is already gone.
  void _teardownEngineState() {
    _tickTimer?.cancel();
    _tickTimer = null;
    _passiveLocSub?.cancel();
    _passiveLocSub = null;
    for (final sub in _locSubs.values) {
      try {
        sub.dispose?.call();
      } catch (_) {}
    }
    _locSubs.clear();
    try {
      _videoPlayer?.dispose();
    } catch (_) {}
    _videoPlayer = null;
    _videoController = null;
    _videoCurrentPath = null;
    try {
      _engine.dispose();
    } catch (_) {}
  }

  /// Re-execute the install from the source recorded in
  /// `source.json` (URL / file / asset / path), then reboot the
  /// engine. Wapps come from a hosted location — the wapp store
  /// repository the user configured — and Reload re-fetches that
  /// same location. Re-fetching, not local-folder probing, is what
  /// keeps the install model honest: the runtime archive is always
  /// a copy of what the hosted source last published.
  ///
  /// Concretely: a wapp installed from `geograms/wapps` with a path
  /// source `binaries/<wappId>/<wappId>-X.Y.Z.wapp` will, on Reload,
  /// re-read that .wapp file. Run `wapps/build-archive.sh <wappId>`
  /// after editing source to refresh the file.
  Future<void> _reload() async {
    _teardownEngineState();
    _tabController?.dispose();
    setState(() {
      _screens.clear();
      _screenNames.clear();
      _outputLines.clear();
      _storeSources = const [];
      _manifest = null;
      _crashed = false;
      _status = 'Reinstalling…';
      _tabController = null;
    });
    try {
      final ok = await WappInstallerService.instance.reinstall(widget.wappId);
      if (!ok && mounted) {
        setState(() => _status = 'Reinstall failed (no source on file).');
      }
    } catch (e) {
      LogService().log('WappPage: reinstall failed: $e');
      if (mounted) setState(() => _status = 'Reinstall failed: $e');
    }
    _engine = WappEngine();
    _bindings = _WappFieldBindings(
      _engine,
      onChange: () {
        if (mounted) setState(() {});
      },
    );
    await _loadWapp();
  }

  @override
  void dispose() {
    if (identical(WappPage.activeState, this)) {
      WappPage.activeState = null;
    }
    _teardownEngineState();
    _tabController?.dispose();
    final id = _manifest?.id ?? widget.wappId;
    final name = _manifest?.name ?? widget.wappId;
    EventBus().fire(WappUnloadedEvent(wappId: id, wappName: name));
    super.dispose();
  }

  // ── Debug API hooks (called from log_api_service.dart) ──────────
  // These exist to support headless verification: the test driver
  // sends action messages and reads back the rendered cards data /
  // form values without going through the UI. Same JSON shape as
  // the wapp protocol so the test layer doesn't need a separate
  // model.

  Map<String, dynamic> _debugSnapshot() {
    final c = _tabController;
    final activeIdx = c == null
        ? -1
        : c.index.clamp(0, _screenNames.isEmpty ? 0 : _screenNames.length - 1);
    return {
      'wapp_id': widget.wappId,
      'title': widget.title,
      'status': _status,
      'crashed': _crashed,
      'screens': List<String>.from(_screenNames),
      'active_screen':
          activeIdx >= 0 && activeIdx < _screenNames.length
              ? _screenNames[activeIdx]
              : null,
      'cards': _cardsData
          .map((k, v) => MapEntry(k, List<Map<String, dynamic>>.from(v))),
      'fields': _bindings._values,
    };
  }

  void _debugSendAction(String name) {
    _engine.sendMessage(jsonEncode({
      'type': 'action',
      'action': name,
    }));
    _engine.handleEvent();
    _drainOutbox();
  }

  bool _debugNavigateTo(String screenName) {
    final idx = _screenNames.indexOf(screenName);
    if (idx < 0) return false;
    setState(() => _tabController?.animateTo(idx));
    return true;
  }

  Map<String, dynamic> _debugUiDef(String screenName) {
    final target = screenName.isEmpty
        ? (_tabController != null &&
                _tabController!.index < _screens.length
            ? _screens[_tabController!.index]
            : null)
        : _screens.firstWhere(
            (s) => s.name == screenName,
            orElse: () =>
                GeoUiBlock(keyword: '', name: null, type: null, decls: {}, children: []),
          );
    if (target == null || target.keyword.isEmpty) {
      return {'error': 'screen not found: $screenName'};
    }
    // Convert a GeoUiValue to a plain JSON-encodable Dart value.
    dynamic valToJson(GeoUiValue v) => switch (v) {
          GeoUiString s => s.value,
          GeoUiNumber n => n.value,
          GeoUiBool b   => b.value,
          GeoUiList l   => l.items.map(valToJson).toList(),
          GeoUiFuncCall f => '${f.name}(${f.args.map(valToJson).join(',')})',
          _ => v.toString(),
        };
    // Serialize block tree to a JSON-safe map recursively.
    Map<String, dynamic> blockToMap(GeoUiBlock b) => {
          'keyword': b.keyword,
          'name': b.name,
          'type': b.type,
          'decls': b.decls.map((k, v) => MapEntry(k, valToJson(v))),
          'children': b.children.map(blockToMap).toList(),
        };
    return blockToMap(target);
  }

  void _debugSetField(String fieldName, String value) {
    _bindings.setValue(fieldName, value);
    if (mounted) setState(() {});
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

    // Video player (movies wapp + any wapp that opens a media file).
    GeoUiBlock? videoGroup;
    for (final c in screen.children) {
      if (c.keyword == 'group' && c.type == 'video') {
        videoGroup = c;
        break;
      }
    }
    if (videoGroup != null) {
      return _buildVideoScreen(videoGroup, bindings, i18n);
    }

    // Side-by-side split: a `<group $type="split">` with two child
    // panes. Each pane is itself a normal GeoUI block (a cards
    // group, a field, or a `<group $type="pane">` wrapping multiple
    // children). Powers IDE-style layouts: file tree on the left,
    // editor + compile output on the right.
    GeoUiBlock? splitGroup;
    for (final c in screen.children) {
      if (c.keyword == 'group' && c.type == 'split') {
        splitGroup = c;
        break;
      }
    }
    if (splitGroup != null) {
      return _buildSplitScreen(splitGroup, bindings, i18n);
    }

    // Generic card-list group. The wapp pushes structured items via
    // ui.data and the host renders them as a list or grid of cards.
    // This is a generic primitive — any wapp can use it.
    final cardsGroup = screen.children.firstWhere(
      (c) => c.keyword == 'group' && c.type == 'cards',
      orElse: () => GeoUiBlock(
          keyword: '', name: null, type: null, decls: {}, children: []),
    );
    if (cardsGroup.keyword == 'group') {
      return _buildCardsScreen(cardsGroup);
    }

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

  /// Render a `<group $type="video">` screen using media_kit. Per
  /// section 14 of wapp-interfaces.md, unknown `$type` groups are
  /// opaque containers whose non-video children render as standard
  /// widgets via [GeoUiScreenRenderer]. The host's only extra job
  /// here is positioning the rendered children as a top-right
  /// overlay on the video — the renderer (now aware of
  /// `$type="menu"` etc.) decides what each child actually looks
  /// like.
  ///
  /// The `Player` is created lazily on the first `video.load`
  /// message; before that the empty state still surfaces the
  /// declared overlay so the wapp can offer entry points (e.g.
  /// a menu group with an "Open file" action).
  Widget _buildVideoScreen(
    GeoUiBlock videoGroup,
    GeoUiBindings bindings,
    I18nContext? i18n,
  ) {
    final controller = _videoController;

    final overlayChildren = videoGroup.children
        .where((c) => c.keyword != 'group' || c.type != 'video')
        .toList();
    Widget? overlay;
    if (overlayChildren.isNotEmpty) {
      overlay = Container(
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(140),
          borderRadius: BorderRadius.circular(28),
        ),
        child: IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: GeoUiScreenRenderer(
            screen: GeoUiBlock(
              keyword: 'screen',
              children: overlayChildren,
            ),
            bindings: bindings,
            i18n: i18n,
            padding: EdgeInsets.zero,
            onAction: (action) {
              _engine.sendMessage(jsonEncode({
                'type': 'action',
                'action': action,
              }));
              _engine.handleEvent();
              _drainOutbox();
            },
          ),
        ),
      );
    }

    Widget body;
    if (controller == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_outlined, size: 64),
              const SizedBox(height: 12),
              Text(
                'No video loaded.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Use the menu in the title bar to pick a video.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      final fitName = videoGroup.getString('fit') ?? 'contain';
      final fit = _videoFitFromName(fitName);
      body = ColoredBox(
        color: Colors.black,
        child: Video(
          controller: controller,
          fit: fit,
        ),
      );
    }

    if (overlay == null) return body;

    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        Positioned(top: 8, right: 8, child: overlay),
      ],
    );
  }

  BoxFit _videoFitFromName(String name) {
    switch (name) {
      case 'cover':
        return BoxFit.cover;
      case 'fill':
        return BoxFit.fill;
      case 'fitWidth':
        return BoxFit.fitWidth;
      case 'fitHeight':
        return BoxFit.fitHeight;
      case 'none':
        return BoxFit.none;
      case 'scaleDown':
        return BoxFit.scaleDown;
      case 'contain':
      default:
        return BoxFit.contain;
    }
  }

  /// Marker actions injected into the AppBar in dev mode. A
  /// `restart_alt` icon that tears down + reboots the engine so
  /// rebuilt source picks up without leaving the page.
  List<Widget> _devAppBarActions() {
    if (!_devMode) return const [];
    return [
      IconButton(
        tooltip: 'Reload from source',
        icon: const Icon(Icons.restart_alt),
        onPressed: _reload,
      ),
    ];
  }

  /// AppBar title with a "(dev)" suffix when the wapp store debug
  /// toggle is on, so the Reload button is visible.
  String _titleWithDevMarker() =>
      _devMode ? '${widget.title} (dev)' : widget.title;

  /// Spec §14.2 — extract a screen's `<group $type="header-actions">`
  /// children and render them as host AppBar widgets, so wapps can
  /// publish multiple icon-actions next to their title.
  List<Widget> _wappHeaderActions(GeoUiBlock screen, I18nContext? i18n) {
    GeoUiBlock? group;
    for (final c in screen.children) {
      if (c.keyword == 'group' && c.type == 'header-actions') {
        group = c;
        break;
      }
    }
    if (group == null) return const [];
    return buildGeoUiAppBarActions(
      children: group.children,
      i18n: i18n,
      onAction: (name) {
        _engine.sendMessage(jsonEncode({
          'type': 'action',
          'action': name,
        }));
        _engine.handleEvent();
        _drainOutbox();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabController = _tabController;
    if (tabController == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(_titleWithDevMarker()),
          actions: _devAppBarActions(),
        ),
        body: Center(child: Text(_status)),
      );
    }

    final i18n = _engine.i18n;
    final bindings = _bindings;

    // Header actions are tied to the visible screen, so the AppBar
    // re-renders on every tab switch. AnimatedBuilder listens to the
    // tab animation; the rebuild is cheap (Material widgets only).
    return AnimatedBuilder(
      animation: tabController.animation ?? tabController,
      builder: (context, _) {
        final activeIndex =
            tabController.index.clamp(0, _screens.length - 1);
        final activeScreen = _screens[activeIndex];
        final wappActions = _wappHeaderActions(activeScreen, i18n);

        if (_stackNav) {
          // Stack-navigation: the first declared screen is the
          // entry — rendered alone with no tab bar, no back arrow.
          // Every other screen is a peer "tab" inside the editor
          // flow. When the wapp navigates from the entry to any
          // peer, we show a tab strip across the peers and a back
          // arrow that returns to the entry.
          final onEntry = tabController.index == 0;
          final peerNames = _screenNames.skip(1).toList();
          final peerActiveIdx =
              (tabController.index - 1).clamp(0, peerNames.length - 1);

          return Scaffold(
            appBar: AppBar(
              leading: onEntry
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => setState(() {
                        tabController.index = 0;
                      }),
                    ),
              title: Text(_titleWithDevMarker()),
              actions: [...wappActions, ..._devAppBarActions()],
              bottom: (!onEntry && peerNames.length > 1)
                  ? PreferredSize(
                      preferredSize: const Size.fromHeight(48),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < peerNames.length; i++)
                              _PeerTab(
                                label: i18n.resolve(peerNames[i]),
                                active: i == peerActiveIdx,
                                onTap: () => setState(() {
                                  tabController.index = i + 1;
                                }),
                              ),
                          ],
                        ),
                      ),
                    )
                  : null,
            ),
            body: _buildScreen(activeScreen, bindings, i18n),
          );
        }

        // Default tabbed layout — wapps that never call
        // ui.select_screen keep the TabBar.
        return Scaffold(
          appBar: AppBar(
            title: Text(_titleWithDevMarker()),
            actions: [
              ...wappActions,
              ..._devAppBarActions(),
            ],
            bottom: _screens.length > 1
                ? TabBar(
                    controller: tabController,
                    isScrollable: true,
                    tabs: _screenNames
                        .map((n) => Tab(text: i18n.resolve(n)))
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
      },
    );
  }

  /// Render a generic `$type="cards"` group as a list/grid of cards.
  /// The wapp pushes data via `ui.data` and (optionally) flips the
  /// layout via `ui.attr`. The host stays generic — no knowledge of
  /// what the wapp's items represent.
  ///
  /// Item schema (all fields optional):
  ///   id          — stable identifier, used as Object key
  ///   icon_path   — absolute or wapp-relative path to an SVG/PNG
  ///   title       — primary line
  ///   subtitle    — small line under the title (e.g. "v1.2.3")
  ///   description — body text, max ~2 lines
  ///   chips       — list of {label,icon} small chips
  ///   actions     — list of {name,label,icon,disabled,primary}
  Widget _buildCardsScreen(GeoUiBlock group) {
    final cs = Theme.of(context).colorScheme;
    final target = group.name ?? group.getString('target') ?? '';
    final items = _cardsData[target] ?? const <Map<String, dynamic>>[];
    // Layout: static attribute from the UI declaration, optionally
    // overridden at runtime via ui.attr.
    final staticLayout = group.getString('layout') ?? 'list';
    final layout = _cardsAttrs[target]?['layout'] ?? staticLayout;

    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            group.getString('empty') ??
                'Nothing to show yet.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    if (layout == 'grid') {
      return LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final cols = w < 480 ? 2 : (w < 760 ? 3 : 4);
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.12,
            ),
            itemBuilder: (_, i) => _buildCard(items[i], cs, grid: true),
          );
        },
      );
    }

    if (layout == 'tree') {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: items.length,
        itemBuilder: (_, i) => _buildTreeRow(items[i], cs),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      itemBuilder: (_, i) => _buildCard(items[i], cs, grid: false),
    );
  }

  /// Compact single-line tree row. Indents by the number of `/` in
  /// the item id so a wapp can ship a flat items list whose paths
  /// imply hierarchy (e.g. "main.c", "screens/home.ui.json").
  Widget _buildTreeRow(Map<String, dynamic> item, ColorScheme cs) {
    final id = (item['id'] as String?) ?? '';
    final title = (item['title'] as String?) ??
        (id.contains('/') ? id.split('/').last : id);
    final subtitle = (item['subtitle'] as String?) ?? '';
    final depth = '/'.allMatches(id).length;
    final actionsRaw = item['actions'] as List?;
    final firstAction = actionsRaw == null || actionsRaw.isEmpty
        ? null
        : Map<String, dynamic>.from(actionsRaw.first as Map);
    final isActive = subtitle == 'editing';
    final iconData = id.endsWith('/')
        ? Icons.folder_outlined
        : Icons.insert_drive_file_outlined;

    return InkWell(
      onTap: firstAction == null
          ? null
          : () {
              _engine.sendMessage(jsonEncode({
                'type': 'action',
                'action': firstAction['name']?.toString() ?? '',
              }));
              _engine.handleEvent();
              _drainOutbox();
            },
      child: Container(
        padding: EdgeInsets.fromLTRB(8.0 + depth * 16.0, 6, 8, 6),
        color: isActive ? cs.primary.withAlpha(28) : null,
        child: Row(
          children: [
            Icon(iconData,
                size: 16,
                color: isActive ? cs.primary : cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  color: isActive ? cs.primary : cs.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Render a `<group $type="split">` as two side-by-side panes.
  /// Pane content is whatever GeoUI block was declared as a child —
  /// a cards group, a single field, or a `<group $type="pane">`
  /// wrapper holding multiple fields.
  Widget _buildSplitScreen(
    GeoUiBlock group,
    GeoUiBindings bindings,
    I18nContext? i18n,
  ) {
    final ratio = group.getNumber('ratio') ?? 0.30;
    final cs = Theme.of(context).colorScheme;
    final children = group.children;
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length < 2) {
      return _buildPane(children.first, bindings, i18n);
    }
    final leftFlex = (ratio * 100).clamp(5, 95).round();
    final rightFlex = 100 - leftFlex;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: leftFlex,
          child: _buildPane(children[0], bindings, i18n),
        ),
        VerticalDivider(width: 1, color: cs.outlineVariant.withAlpha(120)),
        Expanded(
          flex: rightFlex,
          child: _buildPane(children[1], bindings, i18n),
        ),
      ],
    );
  }

  /// Render one pane of a split. The pane is a normal GeoUI block —
  /// either a single-block container (cards group, field, action) or
  /// a `<group $type="pane">` whose own children are rendered as a
  /// stacked column.
  ///
  /// When the type is `pane` and children are mixed (fields/actions
  /// above a cards/split block), the non-expandable children render
  /// as a header column via GeoUiScreenRenderer, and the first
  /// cards/split child expands to fill the remaining space below.
  Widget _buildPane(
    GeoUiBlock pane,
    GeoUiBindings bindings,
    I18nContext? i18n,
  ) {
    if (pane.type != 'pane') {
      final synthetic = GeoUiBlock(
        keyword: 'screen',
        name: pane.name,
        children: [pane],
      );
      return _buildScreen(synthetic, bindings, i18n);
    }

    // Separate plain header blocks (fields, actions, labelled groups)
    // from the first expandable block (cards, split, nested pane).
    final header = <GeoUiBlock>[];
    GeoUiBlock? expandable;
    for (final c in pane.children) {
      if (expandable == null &&
          c.keyword == 'group' &&
          (c.type == 'cards' || c.type == 'split' || c.type == 'pane')) {
        expandable = c;
      } else {
        header.add(c);
      }
    }

    if (expandable == null) {
      // All plain children — delegate to _buildScreen as before.
      final synthetic = GeoUiBlock(
        keyword: 'screen',
        name: pane.name,
        children: pane.children,
      );
      return _buildScreen(synthetic, bindings, i18n);
    }

    void dispatch(String action) {
      _engine.sendMessage(jsonEncode({'type': 'action', 'action': action}));
      _engine.handleEvent();
      _drainOutbox();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: GeoUiScreenRenderer(
              screen: GeoUiBlock(
                keyword: 'screen',
                name: null,
                children: header,
              ),
              bindings: bindings,
              i18n: i18n,
              onAction: dispatch,
            ),
          ),
        Expanded(child: _buildPane(expandable, bindings, i18n)),
      ],
    );
  }

  /// Render one card from a `ui.data` item map. Generic layout —
  /// title + optional subtitle + optional description + optional
  /// chips row + optional action buttons. Icons render from
  /// `icon_path` (absolute or wapp-relative). The icon container
  /// uses the theme's surfaceContainerHigh — no fixed colour.
  Widget _buildCard(
    Map<String, dynamic> item,
    ColorScheme cs, {
    required bool grid,
  }) {
    final title = (item['title'] as String?) ?? '';
    final subtitle = (item['subtitle'] as String?) ?? '';
    final description = (item['description'] as String?) ?? '';
    final iconPath = (item['icon_path'] as String?) ?? '';
    final chipsRaw = item['chips'] as List?;
    final actionsRaw = item['actions'] as List?;
    final actions = actionsRaw == null
        ? const <Map<String, dynamic>>[]
        : actionsRaw
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();

    Widget iconWidget(double size) {
      if (iconPath.isEmpty) {
        return Icon(Icons.extension, size: size, color: cs.onSurfaceVariant);
      }
      // Bytes are pre-resolved when ui.data arrives (see _drainOutbox)
      // so paint stays I/O-free. Anything missing from the cache means
      // resolution failed; show the fallback glyph.
      final bytes = _cardIconBytes[iconPath];
      if (bytes == null) {
        return Icon(Icons.extension, size: size, color: cs.onSurfaceVariant);
      }
      final isSvg = iconPath.toLowerCase().endsWith('.svg') ||
          iconPath.startsWith('wapp:');
      if (isSvg) {
        return Padding(
          padding: EdgeInsets.all(size * 0.15),
          child: SvgPicture.memory(
            bytes,
            fit: BoxFit.contain,
            theme: SvgTheme(currentColor: cs.onSurface),
            placeholderBuilder: (_) => Icon(Icons.extension,
                size: size, color: cs.onSurfaceVariant),
          ),
        );
      }
      return Image.memory(bytes, fit: BoxFit.contain);
    }

    final iconBox = Container(
      width: grid ? 48 : 48,
      height: grid ? 48 : 48,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: iconWidget(grid ? 48 : 48),
    );

    final titleW = Text(
      title,
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      textAlign: grid ? TextAlign.center : TextAlign.start,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    final subtitleW = subtitle.isEmpty
        ? const SizedBox.shrink()
        : Text(
            subtitle,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            textAlign: grid ? TextAlign.center : TextAlign.start,
          );

    final descriptionW = description.isEmpty
        ? const SizedBox.shrink()
        : Text(
            description,
            style: TextStyle(
                fontSize: 12, color: cs.onSurfaceVariant, height: 1.25),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: grid ? TextAlign.center : TextAlign.start,
          );

    Widget chipFor(Map<String, dynamic> chip) {
      final label = (chip['label'] as String?) ?? '';
      final iconName = (chip['icon'] as String?) ?? '';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withAlpha(120),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (iconName.isNotEmpty) ...[
              Icon(_iconForName(iconName) ?? Icons.label_outline,
                  size: 11, color: cs.onSurfaceVariant),
              const SizedBox(width: 3),
            ],
            Text(label,
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }

    final chipsW = (chipsRaw == null || chipsRaw.isEmpty)
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              alignment: grid ? WrapAlignment.center : WrapAlignment.start,
              children: [
                for (final c in chipsRaw.whereType<Map>())
                  chipFor(Map<String, dynamic>.from(c)),
              ],
            ),
          );

    Widget actionButton(Map<String, dynamic> a) {
      final name = (a['name'] as String?) ?? '';
      final label = (a['label'] as String?) ?? name;
      final iconName = (a['icon'] as String?) ?? '';
      final disabled = (a['disabled'] as bool?) ?? false;
      final ic = iconName.isNotEmpty ? _iconForName(iconName) : null;
      void fire() {
        _engine.sendMessage(jsonEncode({
          'type': 'action',
          'action': name,
        }));
        _engine.handleEvent();
        _drainOutbox();
      }

      if (grid) {
        return SizedBox(
          width: double.infinity,
          height: 28,
          child: FilledButton.icon(
            onPressed: disabled ? null : fire,
            icon: Icon(ic ?? Icons.play_arrow, size: 13),
            label: Text(label, style: const TextStyle(fontSize: 11)),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
          ),
        );
      }
      return FilledButton.icon(
        onPressed: disabled ? null : fire,
        icon: Icon(ic ?? Icons.play_arrow, size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      );
    }

    final actionsW = actions.isEmpty
        ? const SizedBox.shrink()
        : (grid
            ? actionButton(actions.first)
            : Wrap(
                spacing: 8,
                children: [for (final a in actions) actionButton(a)],
              ));

    if (grid) {
      return Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              iconBox,
              const SizedBox(height: 6),
              titleW,
              subtitleW,
              const SizedBox(height: 4),
              Expanded(child: descriptionW),
              const SizedBox(height: 4),
              actionsW,
            ],
          ),
        ),
      );
    }

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
            iconBox,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  titleW,
                  if (subtitle.isNotEmpty) const SizedBox(height: 2),
                  subtitleW,
                  if (description.isNotEmpty) const SizedBox(height: 6),
                  descriptionW,
                  chipsW,
                ],
              ),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(width: 10),
              actionsW,
            ],
          ],
        ),
      ),
    );
  }

  /// Resolve `wapp:<slug>` icon paths against the shared archive.
  /// Returns the absolute path of the wapp's manifest.icon entry, or
  /// null when the wapp is not installed or its icon is missing.
  /// Falls back to scanning the sibling source `wapps/` checkout so
  /// catalog rendering works during local development.
  /// Load icon bytes once for a card item. Called from the ui.data
  /// handler so the build path stays I/O-free. Returns null when the
  /// icon can't be resolved or read; the build path falls back to a
  /// generic glyph in that case. Supports raw absolute/relative paths
  /// and the `wapp:<slug>` scheme (resolves to that wapp's manifest
  /// icon).
  Uint8List? _loadCardIconBytes(String iconPath) {
    if (iconPath.isEmpty) return null;
    String resolved = iconPath;
    if (iconPath.startsWith('wapp:')) {
      final slug = iconPath.substring(5);
      final found = _resolveInstalledWappIcon(slug);
      if (found == null) return null;
      resolved = found;
    }
    try {
      final f = File(resolved);
      if (!f.existsSync()) return null;
      return f.readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  String? _resolveInstalledWappIcon(String slug) {
    final roots = <String>[
      if (wappArchiveBasePath() != null) '${wappArchiveBasePath()}/$slug',
      '${Directory.current.path}/../wapps/$slug',
      '${Directory.current.path}/../../wapps/$slug',
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
        if (svgFile.existsSync()) return svgFile.path;
      } catch (_) {}
    }
    return null;
  }

  /// Resolve a Material icon name to an IconData, used by the card
  /// renderer for action buttons and chips. Returns null when the
  /// name is unknown.
  IconData? _iconForName(String name) {
    switch (name) {
      case 'download':
        return Icons.download;
      case 'upgrade':
        return Icons.upgrade;
      case 'check':
        return Icons.check;
      case 'play':
      case 'play_arrow':
        return Icons.play_arrow;
      case 'install':
        return Icons.download;
      case 'delete':
        return Icons.delete_outline;
      case 'open':
        return Icons.open_in_new;
      case 'cloud':
        return Icons.cloud_outlined;
      case 'folder':
        return Icons.folder_outlined;
    }
    return null;
  }


  /// Render the wapp store sources manager. The install wapp pushes
  /// the current source list as `store.sources` and listens for a
  /// `set_sources` action to update its KV.
  Widget _buildSourcesScreen() {
    final cs = Theme.of(context).colorScheme;
    final debugOn =
        ConfigService().getNestedValue('wapp.debugMode', false) == true;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Debug-mode toggle: flips a global ConfigService flag that
          // every WappPage reads on load. When on, every wapp gets a
          // reload button in its AppBar so the user can re-read the
          // package off disk after editing or reinstalling, without
          // closing and reopening the app.
          SwitchListTile(
            value: debugOn,
            contentPadding: EdgeInsets.zero,
            title: const Text('Debug mode'),
            subtitle: const Text(
              'Show a Reload button on every wapp. Reopen any wapp '
              'for the change to take effect.',
            ),
            onChanged: (v) => _setWappDebugMode(v),
          ),
          const Divider(height: 24),
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

  /// Persist the global wapp debug-mode flag and rebuild the screen
  /// so the switch reflects the new state. Open wapps pick up the
  /// change the next time they re-run [_loadWapp] — easiest way is
  /// just to tap their Reload button (or close + reopen). The host
  /// (this Wapp Store page) updates immediately because [_devMode]
  /// is recomputed on every [_loadWapp]; the simpler path here is
  /// just to update local state and let [build] re-read the flag.
  void _setWappDebugMode(bool enabled) {
    ConfigService().setNestedValue('wapp.debugMode', enabled);
    if (mounted) {
      setState(() {
        _devMode = enabled;
      });
    }
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

/// Opaque payload for the file-association launch path. The host
/// hands one of these to [WappPage] when the user picks a wapp from
/// an "Open with…" dialog (or when an external file event names the
/// wapp directly). The wapp receives it as a `file.open` message
/// after its engine has booted — see Section 19 of
/// `wapps/wapp-interfaces.md`.
class WappOpenFile {
  /// Filesystem path or virtual URI the file lives at. The wapp
  /// uses this to read bytes via the host's file HAL or by issuing
  /// a `file.read_request` message back to the host.
  final String path;

  /// Display name (basename), used by the wapp for window titles
  /// and "now playing" UI without having to parse [path].
  final String name;

  /// Lowercase extension without the dot ("mp3", "ogg", "txt"). May
  /// be empty for files that have no extension.
  final String extension;

  /// MIME type when the host knows it (e.g. "audio/mpeg"). Empty
  /// when the host hasn't sniffed the file.
  final String mime;

  /// Open mode requested by the user — "view" (default) or "edit".
  /// The wapp may refuse edit mode if it didn't declare it in
  /// `provides.file_handlers[*].modes`.
  final String mode;

  /// Size in bytes, when known. -1 means "unknown" (e.g. streamed).
  final int size;

  const WappOpenFile({
    required this.path,
    required this.name,
    this.extension = '',
    this.mime = '',
    this.mode = 'view',
    this.size = -1,
  });

  Map<String, dynamic> toJson() => {
        'type': 'file.open',
        'path': path,
        'name': name,
        if (extension.isNotEmpty) 'extension': extension,
        if (mime.isNotEmpty) 'mime': mime,
        'mode': mode,
        'size': size,
      };
}

/// Per-req_id bookkeeping for an active `location.subscribe`. Keeps
/// the dispose handle from LocationProviderService plus the throttle
/// state needed to honour `min_interval_ms` and `min_distance_m`
/// independently from the underlying provider's cadence.
class _LocationSub {
  final String hint;
  final int minIntervalMs;
  final double minDistanceM;
  VoidCallback? dispose;
  DateTime? lastDeliveredAt;
  double? lastLat;
  double? lastLon;

  _LocationSub({
    required this.hint,
    required this.minIntervalMs,
    required this.minDistanceM,
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
    if (value is num) engine.kvSet(name, value.toString());
    onChange();
  }
}

/// One tab in the stack-nav peer strip — a flat label with a bottom
/// underline when active. Lighter-weight than Material's TabBar, and
/// works without a TabController of its own.
class _PeerTab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _PeerTab({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? cs.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
