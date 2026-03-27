import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../geoui/geoui_ast.dart';
import '../geoui/geoui_parser.dart';
import '../geoui/geoui_renderer.dart';
import '../services/preferences_service.dart';
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

  // Screens parsed from .ui.json
  final _screens = <GeoUiBlock>[];
  final _screenNames = <String>[];
  TabController? _tabController;

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

  @override
  void initState() {
    super.initState();
    _loadWapp();
  }

  Future<void> _loadWapp() async {
    // Parse .ui.json screens
    final screensDir = Directory('${widget.wappDir}/screens');
    if (screensDir.existsSync()) {
      for (final file in screensDir.listSync()) {
        if (file is! File || !file.path.endsWith('.ui.json')) continue;
        try {
          final parsed = GeoUiParser(await file.readAsString()).parse();
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

    // Load field defaults from screens
    for (final screen in _screens) {
      for (final group in screen.childrenOf('group')) {
        // Detect map group
        if (group.type == 'map') {
          _hasMap = true;
          _mapLat = group.getNumber('default-lat') ?? 0;
          _mapLon = group.getNumber('default-lon') ?? 0;
          _mapZoom = group.getNumber('default-zoom')?.toInt() ?? 12;
          _tileUrl = group.getString('tile-url') ?? _tileUrl;
        }
        for (final field in group.childrenOf('field')) {
          final name = field.name;
          if (name == null) continue;
          final def = field.decls['default'];
          if (def is GeoUiNumber) _fieldValues[name] = def.value;
          else if (def is GeoUiBool) _fieldValues[name] = def.value;
          else if (def is GeoUiString) _fieldValues[name] = def.value;
        }
      }
    }

    // Build tab controller
    _tabController = TabController(length: _screenNames.length, vsync: this);

    // Set up persistent KV storage
    try {
      final prefs = await PreferencesService.instance();
      final baseDir = prefs.wappDataDir ?? _defaultDataDir();
      // Use wapp folder name as the storage subdirectory
      final wappName = widget.wappDir.split(Platform.pathSeparator).last;
      _engine.setStorageDir('$baseDir/$wappName');
    } catch (_) {}

    // Load WASM
    final wasmFile = File('${widget.wappDir}/app.wasm');
    if (!wasmFile.existsSync()) {
      setState(() => _status = 'app.wasm not found');
      return;
    }

    try {
      await _engine.load(await wasmFile.readAsBytes());
      _engine.init();
      _drainOutbox();

      final interval = _engine.tickIntervalMs;
      _tickTimer = Timer.periodic(Duration(milliseconds: interval), (_) {
        _engine.tick();
        _drainOutbox();
      });

      setState(() => _status = 'Running');
    } catch (e) {
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
        } else if (type == 'ui.map.viewport') {
          _mapLat = (data['lat'] as num?)?.toDouble() ?? _mapLat;
          _mapLon = (data['lon'] as num?)?.toDouble() ?? _mapLon;
          _mapZoom = (data['zoom'] as num?)?.toInt() ?? _mapZoom;
          changed = true;
        } else if (type == 'ui.toast') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(data['message'] as String? ?? '')),
            );
          }
        } else if (type == 'wapp.fetch_index') {
          _handleFetchIndex(data);
        } else if (type == 'wapp.install') {
          _handleWappInstall(data);
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

  void _handleFetchIndex(Map<String, dynamic> data) {
    final source = data['source'] as String? ?? '';
    if (source.isEmpty) return;

    var path = source;
    if (!path.endsWith('.json')) {
      if (!path.endsWith('/')) path += '/';
      path += 'index.json';
    }

    final file = File(path);
    if (!file.existsSync()) {
      _outputLines.add(_OutputLine('Index not found: $path', 'err'));
      return;
    }

    try {
      final contents = jsonDecode(file.readAsStringSync());
      _engine.sendMessage(jsonEncode({
        'type': 'wapp.index',
        'data': contents,
      }));
      _engine.handleEvent();
      _drainOutbox();
    } catch (e) {
      _outputLines.add(_OutputLine('Failed to read index: $e', 'err'));
    }
  }

  void _handleWappInstall(Map<String, dynamic> data) {
    final source = data['source'] as String? ?? '';
    final filePath = data['file'] as String? ?? '';
    final name = data['name'] as String? ?? '';
    final version = data['version'] as String? ?? '';
    if (source.isEmpty || filePath.isEmpty) return;

    var basePath = source;
    if (basePath.endsWith('.json')) {
      basePath = basePath.substring(0, basePath.lastIndexOf('/'));
    }
    if (!basePath.endsWith('/')) basePath += '/';
    final srcPath = '$basePath$filePath';

    final srcFile = File(srcPath);
    if (!srcFile.existsSync()) {
      _outputLines.add(_OutputLine('File not found: $srcPath', 'err'));
      return;
    }

    try {
      final baseDir = _defaultDataDir();
      final installDir = '$baseDir/_installed/$name';
      Directory(installDir).createSync(recursive: true);
      final destPath = '$installDir/$name-$version.wapp';
      srcFile.copySync(destPath);
      _outputLines.add(_OutputLine('$name v$version installed', 'info'));
    } catch (e) {
      _outputLines.add(_OutputLine('Install failed: $e', 'err'));
    }
  }

  static String _defaultDataDir() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '/tmp';
    return '$home/.local/share/iwi/wapps';
  }

  void _sendCommand(String cmd) {
    _engine.sendMessage(jsonEncode({'command': cmd}));
    _engine.handleEvent();
    _drainOutbox();
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _engine.dispose();
    _cmdController.dispose();
    _scrollController.dispose();
    _tabController?.dispose();
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

  Widget _buildScreen(GeoUiBlock screen) {
    // Check if this screen has a map group
    final mapGroup = screen.children
        .where((c) => c.keyword == 'group' && c.type == 'map')
        .firstOrNull;
    if (mapGroup != null) return _buildMapScreen(screen, mapGroup);

    // Check if it's a terminal-like screen (has watch/output)
    final hasOutput = _outputLines.isNotEmpty ||
        screen.children.any((c) =>
            c.keyword == 'group' &&
            c.children.any((gc) => gc.keyword == 'watch'));
    if (hasOutput && screen.childrenOf('group').any((g) =>
        g.children.any((c) => c.keyword == 'field' && c.type == 'string'))) {
      return _buildTerminalScreen(screen);
    }

    // Settings-like screen — use GeoUI renderer
    return _buildSettingsScreen(screen);
  }

  // ── Terminal screen ────────────────────────────────────────────────

  Widget _buildTerminalScreen(GeoUiBlock screen) {
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
                  color: switch (line.level) {
                    'cmd' => const Color(0xFF7EE787),
                    'err' || 'error' => const Color(0xFFF85149),
                    'info' => const Color(0xFF58A6FF),
                    'warn' || 'warning' => const Color(0xFFE3B341),
                    _ => const Color(0xFFE6EDF3),
                  },
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
