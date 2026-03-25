import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'apps/terminal_page.dart';
import 'services/preferences_service.dart';
import 'wapp/wapp_engine.dart';

void main() {
  runApp(const IwiApp());
}

class IwiApp extends StatelessWidget {
  const IwiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Iwi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const LauncherPage(),
    );
  }
}

// ── Wapp manifest model ──────────────────────────────────────────────

class WappManifest {
  final String id;
  final String name;
  final String description;
  final String kind;
  final String? icon;
  final String dirPath;

  WappManifest({
    required this.id,
    required this.name,
    required this.description,
    required this.kind,
    this.icon,
    required this.dirPath,
  });

  factory WappManifest.fromJson(Map<String, dynamic> json, String dirPath) {
    // Use description as display name, fall back to id
    final desc = json['description'] as String? ?? '';
    final id = json['id'] as String? ?? '';
    return WappManifest(
      id: id,
      name: desc.isNotEmpty ? desc : id.split('.').last,
      description: json['summary'] as String? ?? desc,
      kind: json['kind'] as String? ?? 'app',
      icon: json['icon'] as String?,
      dirPath: dirPath,
    );
  }

  /// Map common wapp IDs/tags to Material icons.
  IconData get iconData {
    final lower = id.toLowerCase();
    if (lower.contains('terminal') || lower.contains('shell')) {
      return Icons.terminal;
    }
    if (lower.contains('chat') || lower.contains('messenger')) {
      return Icons.chat;
    }
    if (lower.contains('radio') || lower.contains('aprs')) {
      return Icons.radio;
    }
    if (lower.contains('settings') || lower.contains('config')) {
      return Icons.settings;
    }
    if (lower.contains('map') || lower.contains('gps')) {
      return Icons.map;
    }
    if (lower.contains('file') || lower.contains('storage')) {
      return Icons.folder;
    }
    return Icons.extension;
  }

  /// Pick a color based on the id hash.
  Color get color {
    final colors = [
      const Color(0xFF0F3460),
      const Color(0xFF533483),
      const Color(0xFF1A5276),
      const Color(0xFF6C3483),
      const Color(0xFF1E8449),
      const Color(0xFFB9770E),
      const Color(0xFF943126),
      const Color(0xFF2E4053),
    ];
    return colors[id.hashCode.abs() % colors.length];
  }
}

// ── Launcher ──────────────────────────────────────────────────────────

class LauncherPage extends StatefulWidget {
  const LauncherPage({super.key});

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage> {
  List<WappManifest>? _wapps;

  @override
  void initState() {
    super.initState();
    _scanArchive();
  }

  Future<void> _scanArchive() async {
    final wapps = <WappManifest>[];

    // Find the wapps/archive directory relative to the project root.
    // The iwi app runs from inside the project, so walk up from the
    // executable or use the known repo path.
    final candidates = [
      // When running via flutter run, cwd is the iwi/ directory
      '${Directory.current.path}/../wapps/archive',
      // Absolute fallback
      '${Directory.current.path}/../../wapps/archive',
      // Direct repo path
      _findRepoArchive(),
    ];

    Directory? archiveDir;
    for (final path in candidates) {
      if (path == null) continue;
      final dir = Directory(path);
      if (dir.existsSync()) {
        archiveDir = dir;
        break;
      }
    }

    if (archiveDir != null) {
      for (final entry in archiveDir.listSync()) {
        if (entry is! Directory) continue;
        final manifestFile = File('${entry.path}/manifest.json');
        if (!manifestFile.existsSync()) continue;
        try {
          final json = jsonDecode(await manifestFile.readAsString());
          final manifest = WappManifest.fromJson(
            json as Map<String, dynamic>,
            entry.path,
          );
          if (manifest.kind == 'app') wapps.add(manifest);
        } catch (_) {
          // Skip malformed manifests
        }
      }
    }

    setState(() => _wapps = wapps);
  }

  /// Walk up from cwd to find the repo root containing wapps/archive.
  String? _findRepoArchive() {
    var dir = Directory.current;
    for (var i = 0; i < 5; i++) {
      final candidate = Directory('${dir.path}/wapps/archive');
      if (candidate.existsSync()) return candidate.path;
      dir = dir.parent;
    }
    return null;
  }

  void _openWapp(WappManifest manifest) {
    // For the terminal wapp, use the native Terminal page
    if (manifest.id == 'tools.geogram.terminal') {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const TerminalPage()),
      );
      return;
    }
    // For other wapps, use the generic Wapp Runner with the wasm file
    final wasmPath = '${manifest.dirPath}/app.wasm';
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WappRunnerPage(
          title: manifest.name,
          wasmPath: wasmPath,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Iwi'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const IwiSettingsPage()),
              );
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_wapps == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Combine discovered wapps + the built-in Wapp Runner tool
    final entries = <_LauncherEntry>[
      // Discovered wapps from archive
      for (final wapp in _wapps!)
        _LauncherEntry(
          name: wapp.name,
          icon: wapp.iconData,
          color: wapp.color,
          onTap: () => _openWapp(wapp),
        ),
      // Built-in Wapp Runner (dev tool)
      _LauncherEntry(
        name: 'Wapp Runner',
        icon: Icons.memory,
        color: const Color(0xFF533483),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const WappRunnerPage()),
        ),
      ),
    ];

    if (entries.isEmpty) {
      return const Center(
        child: Text('No wapps found', style: TextStyle(color: Colors.grey)),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 120,
          mainAxisSpacing: 20,
          crossAxisSpacing: 20,
        ),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final e = entries[index];
          return _AppIcon(
            name: e.name,
            icon: e.icon,
            color: e.color,
            onTap: e.onTap,
          );
        },
      ),
    );
  }
}

class _LauncherEntry {
  final String name;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _LauncherEntry({
    required this.name,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

class _AppIcon extends StatelessWidget {
  final String name;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _AppIcon({
    required this.name,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 28, color: Colors.white),
          ),
          const SizedBox(height: 6),
          Text(
            name,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Iwi Settings ─────────────────────────────────────────────────────

class IwiSettingsPage extends StatefulWidget {
  const IwiSettingsPage({super.key});

  @override
  State<IwiSettingsPage> createState() => _IwiSettingsPageState();
}

class _IwiSettingsPageState extends State<IwiSettingsPage> {
  PreferencesService? _prefs;
  String? _dataDir;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await PreferencesService.instance();
    setState(() {
      _prefs = prefs;
      _dataDir = prefs.wappDataDir ?? _defaultDataDir();
    });
  }

  static String _defaultDataDir() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '/tmp';
    return '$home/.local/share/iwi/wapps';
  }

  Future<void> _pickDirectory() async {
    // Show a dialog to type the path (no file_picker dependency needed)
    final controller = TextEditingController(text: _dataDir);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wapp Data Directory'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Each wapp stores its settings and files in a subfolder here, '
              'named after the wapp ID.',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'Directory path',
                filled: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.folder_open),
                  tooltip: 'Reset to default',
                  onPressed: () => controller.text = _defaultDataDir(),
                ),
              ),
              autofocus: true,
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
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && _prefs != null) {
      // Ensure directory exists
      final dir = Directory(result);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      _prefs!.wappDataDir = result;
      setState(() => _dataDir = result);
    }
  }

  /// List existing wapp data subdirectories.
  List<_WappDataEntry> _listWappData() {
    if (_dataDir == null) return [];
    final dir = Directory(_dataDir!);
    if (!dir.existsSync()) return [];
    final entries = <_WappDataEntry>[];
    for (final sub in dir.listSync()) {
      if (sub is! Directory) continue;
      final name = sub.path.split(Platform.pathSeparator).last;
      var size = 0;
      try {
        for (final f in sub.listSync(recursive: true)) {
          if (f is File) size += f.lengthSync();
        }
      } catch (_) {}
      entries.add(_WappDataEntry(name, sub.path, size));
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _prefs == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // ── Data Directory ──
                Text('Storage',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Where wapp settings, downloads, and user files are stored.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  color: cs.surfaceContainerLow,
                  child: ListTile(
                    leading: const Icon(Icons.folder),
                    title: const Text('Wapp Data Directory'),
                    subtitle: Text(
                      _dataDir ?? 'Not set',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    trailing: const Icon(Icons.edit),
                    onTap: _pickDirectory,
                  ),
                ),
                const SizedBox(height: 24),

                // ── Per-wapp data ──
                Text('Wapp Data',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Each subfolder contains settings and files for one wapp.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                ..._buildWappDataList(cs),
              ],
            ),
    );
  }

  List<Widget> _buildWappDataList(ColorScheme cs) {
    final entries = _listWappData();
    if (entries.isEmpty) {
      return [
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
          ),
          color: cs.surfaceContainerLow,
          child: const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('No wapp data yet'),
            subtitle: Text('Data folders are created when a wapp first runs.'),
          ),
        ),
      ];
    }

    return [
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              ListTile(
                leading: const Icon(Icons.extension),
                title: Text(entries[i].name),
                subtitle: Text(
                  _humanSize(entries[i].size),
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
                trailing: IconButton(
                  icon: Icon(Icons.delete_outline, color: cs.error),
                  tooltip: 'Delete wapp data',
                  onPressed: () => _confirmDelete(entries[i]),
                ),
              ),
              if (i < entries.length - 1)
                Divider(
                    height: 1,
                    thickness: 1,
                    color: cs.outlineVariant.withAlpha(50)),
            ],
          ],
        ),
      ),
    ];
  }

  Future<void> _confirmDelete(_WappDataEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${entry.name}?'),
        content: Text(
            'This will permanently delete all settings and files for '
            '"${entry.name}" (${_humanSize(entry.size)}).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        Directory(entry.path).deleteSync(recursive: true);
        setState(() {}); // Refresh list
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete: $e')),
          );
        }
      }
    }
  }
}

class _WappDataEntry {
  final String name;
  final String path;
  final int size;
  _WappDataEntry(this.name, this.path, this.size);
}

// ── Wapp Runner (generic WASM module runner) ─────────────────────────

class WappRunnerPage extends StatefulWidget {
  final String? title;
  final String? wasmPath;

  const WappRunnerPage({super.key, this.title, this.wasmPath});

  @override
  State<WappRunnerPage> createState() => _WappRunnerPageState();
}

class _WappRunnerPageState extends State<WappRunnerPage> {
  final _engine = WappEngine();
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _tickTimer;
  String _status = 'Not loaded';

  @override
  void initState() {
    super.initState();
    // Auto-load if a wasm path was provided
    if (widget.wasmPath != null) {
      _loadWasmFromFile(widget.wasmPath!);
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _engine.dispose();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadWasmFromFile(String path) async {
    setState(() => _status = 'Loading...');
    try {
      final bytes = await File(path).readAsBytes();
      await _startEngine(bytes);
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _loadWasmFromAsset() async {
    setState(() => _status = 'Loading...');
    try {
      final bytes = await rootBundle.load('assets/hello_world.wasm');
      await _startEngine(bytes.buffer.asUint8List());
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _startEngine(Uint8List bytes) async {
    await _engine.load(bytes);
    _engine.init();

    final interval = _engine.tickIntervalMs;
    _tickTimer = Timer.periodic(Duration(milliseconds: interval), (_) {
      _engine.tick();
      _engine.handleEvent();
      setState(() {});
      _scrollToBottom();
    });

    setState(() => _status = 'Running (tick every ${interval}ms)');
    _scrollToBottom();
  }

  void _sendMessage() {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;
    _engine.sendMessage(text);
    _engine.handleEvent();
    _msgController.clear();
    setState(() {});
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Color _levelColor(int level) {
    return switch (level) {
      0 => Colors.grey,
      1 => Colors.lightBlueAccent,
      2 => Colors.orange,
      3 => Colors.redAccent,
      _ => Colors.white,
    };
  }

  @override
  Widget build(BuildContext context) {
    final outbox = _engine.drainOutbox();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'Wapp Runner'),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: _engine.isLoaded ? Colors.green.withAlpha(30) : Colors.grey.withAlpha(30),
            child: Row(
              children: [
                Icon(
                  _engine.isLoaded ? Icons.check_circle : Icons.circle_outlined,
                  size: 14,
                  color: _engine.isLoaded ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_status, style: const TextStyle(fontSize: 13)),
                ),
                if (!_engine.isLoaded && widget.wasmPath == null)
                  TextButton.icon(
                    onPressed: _loadWasmFromAsset,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Load hello_world.wasm'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _engine.logs.length + outbox.length,
              itemBuilder: (context, index) {
                if (index < _engine.logs.length) {
                  final log = _engine.logs[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: '[${log.levelName}] ',
                          style: TextStyle(
                            color: _levelColor(log.level),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            fontFamily: 'monospace',
                          ),
                        ),
                        TextSpan(
                          text: log.message,
                          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                        ),
                      ]),
                    ),
                  );
                } else {
                  final msg = outbox[index - _engine.logs.length];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                      '<< $msg',
                      style: const TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: Colors.amber,
                      ),
                    ),
                  );
                }
              },
            ),
          ),
          if (_engine.isLoaded)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey.shade800)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgController,
                      decoration: const InputDecoration(
                        hintText: 'Send message to module...',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
