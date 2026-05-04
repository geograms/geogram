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
import 'package:shared_preferences/shared_preferences.dart';

import '../geoui/geoui_ast.dart';
import '../geoui/geoui_parser.dart';
import '../geoui/geoui_renderer.dart';
import '../models/wapp_manifest.dart';
import '../services/app_service.dart';
import '../services/i18n_context.dart';
import '../services/location_provider_service.dart';
import '../services/config_service.dart';
import '../services/log_service.dart';
import '../services/profile_storage.dart';
import '../services/wapp_installer_service.dart';
import '../services/wapp_storage.dart';
import '../widgets/file_folder_picker.dart';
import '../util/app_type_theme.dart';
import '../util/event_bus.dart';
import '../util/geolocation_utils.dart';
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

  @override
  State<WappPage> createState() => _WappPageState();
}

class _WappPageState extends State<WappPage>
    with TickerProviderStateMixin {
  WappManifest? _manifest;
  WappEngine _engine = WappEngine();
  final List<GeoUiBlock> _screens = [];
  final List<String> _screenNames = [];
  TabController? _tabController;
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

  // ── Catalog view mode (Wapp Store). Toggled by the user with the
  //    list/grid buttons above the catalog cards. Persisted via
  //    SharedPreferences so it survives reloads across sessions. The
  //    key is namespaced to the wappId so other wapps that may grow
  //    a similar toggle in the future don't share state.
  bool _catalogViewIsGrid = false;
  static const String _kCatalogViewPrefPrefix = 'wapp_catalog_view_grid:';

  @override
  void initState() {
    super.initState();
    _loadCatalogViewPref();
    unawaited(_loadWapp());
  }

  Future<void> _loadCatalogViewPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v =
          prefs.getBool('$_kCatalogViewPrefPrefix${widget.wappId}') ?? false;
      if (mounted && v != _catalogViewIsGrid) {
        setState(() => _catalogViewIsGrid = v);
      }
    } catch (_) {
      // Best-effort — if prefs fail, fall back to list view.
    }
  }

  Future<void> _setCatalogViewIsGrid(bool grid) async {
    if (_catalogViewIsGrid == grid) return;
    setState(() => _catalogViewIsGrid = grid);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(
          '$_kCatalogViewPrefPrefix${widget.wappId}', grid);
    } catch (_) {}
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
    await _loadWapp();
  }

  @override
  void dispose() {
    _teardownEngineState();
    _tabController?.dispose();
    final id = _manifest?.id ?? widget.wappId;
    final name = _manifest?.name ?? widget.wappId;
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
    final bindings = _WappFieldBindings(
      _engine,
      onChange: () {
        if (mounted) setState(() {});
      },
    );

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

  /// Render the wapp store catalog as proper cards. The install
  /// wapp emits structured text via `ui.append`:
  ///   "  name  vX.Y.Z  (NKB)  [optional status]"   ← entry
  ///   "    title:Display Name"                      ← title (optional)
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
          if (meta.startsWith('title:')) {
            last.title = meta.substring(6);
          } else if (meta.startsWith('@')) {
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

    return Column(
      children: [
        _buildCatalogViewToggle(cs),
        Expanded(
          child: _catalogViewIsGrid
              ? _buildWappCatalogGrid(wapps, cs)
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: wapps.length,
                  itemBuilder: (_, i) =>
                      _buildWappCatalogCard(wapps[i], cs),
                ),
        ),
      ],
    );
  }

  /// Tiny right-aligned toolbar above the catalog with two icon
  /// buttons that switch the rendering between a vertical list of
  /// wide cards and a Play-Store-style grid of square tiles.
  Widget _buildCatalogViewToggle(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'List view',
            isSelected: !_catalogViewIsGrid,
            onPressed: _catalogViewIsGrid
                ? () => _setCatalogViewIsGrid(false)
                : null,
            icon: const Icon(Icons.view_list),
          ),
          IconButton(
            tooltip: 'Grid view',
            isSelected: _catalogViewIsGrid,
            onPressed: _catalogViewIsGrid
                ? null
                : () => _setCatalogViewIsGrid(true),
            icon: const Icon(Icons.grid_view),
          ),
        ],
      ),
    );
  }

  /// Responsive grid: 2 columns on narrow, 3 on tablet, 4 on wide.
  Widget _buildWappCatalogGrid(List<_CatalogWapp> wapps, ColorScheme cs) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final cols = w < 480 ? 2 : (w < 760 ? 3 : 4);
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: wapps.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            // Cards used to be ~282 px tall (aspect 0.78). Trimmed
            // to ~200 px (aspect 1.12) by shrinking the icon, the
            // description max-lines, and the surrounding padding —
            // ~30% shorter so more wapps fit on screen at once.
            childAspectRatio: 1.12,
          ),
          itemBuilder: (_, i) => _buildWappCatalogGridCard(wapps[i], cs),
        );
      },
    );
  }

  Widget _buildWappCatalogGridCard(_CatalogWapp wapp, ColorScheme cs) {
    final isInstalled = wapp.installed;
    final actionLabel = wapp.updateAvailable
        ? 'Update'
        : (isInstalled ? 'Installed' : 'Install');
    final actionIcon = wapp.updateAvailable
        ? Icons.upgrade
        : (isInstalled ? Icons.check : Icons.download);

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
            Container(
              width: 48,
              height: 48,
              decoration: appTypeIconDecoration(context, 'wapp', radius: 12),
              child: _catalogIconFor(wapp.name, 24),
            ),
            const SizedBox(height: 6),
            Text(
              wapp.title.isNotEmpty ? wapp.title : wapp.name,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              'v${wapp.version}',
              style:
                  TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: wapp.description.isNotEmpty
                  ? Text(
                      wapp.description,
                      style: TextStyle(
                          fontSize: 10.5,
                          color: cs.onSurfaceVariant,
                          height: 1.25),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              height: 28,
              child: FilledButton.icon(
                onPressed: isInstalled && !wapp.updateAvailable
                    ? null
                    : () => _sendCommand('install ${wapp.name}'),
                icon: Icon(actionIcon, size: 13),
                label: Text(actionLabel,
                    style: const TextStyle(fontSize: 11)),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
            ),
          ],
        ),
      ),
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
              decoration: appTypeIconDecoration(context, 'wapp', radius: 12),
              child: _catalogIconFor(wapp.name, 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    wapp.title.isNotEmpty ? wapp.title : wapp.name,
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
  ///   2. Sibling source repo: <cwd>/../wapps/<name>/    (pre-install
  ///      when running from a source checkout where the wapp repo
  ///      lives next to geogram — see README in the wapps repo)
  /// Falls back to `Icons.extension` when no manifest+SVG is found.
  Widget _catalogIconFor(String name, double size) {
    final roots = <String>[
      if (wappArchiveBasePath() != null) '${wappArchiveBasePath()}/$name',
      '${Directory.current.path}/../wapps/$name',
      '${Directory.current.path}/../../wapps/$name',
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

/// One row in the wapp store catalog, parsed from the install
/// wapp's structured `ui.append` log lines.
class _CatalogWapp {
  final String name;        // folder slug, e.g. "movies"
  final String version;
  final String size;
  final bool installed;
  final bool updateAvailable;
  // Mutable: filled in by follow-up indented log lines.
  String title = '';        // human display name; falls back to [name]
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
