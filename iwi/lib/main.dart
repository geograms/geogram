import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'apps/terminal_page.dart';
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

// ── Launcher ──────────────────────────────────────────────────────────

class _AppEntry {
  final String name;
  final IconData icon;
  final Color color;
  final Widget Function() builder;

  const _AppEntry({
    required this.name,
    required this.icon,
    required this.color,
    required this.builder,
  });
}

class LauncherPage extends StatelessWidget {
  const LauncherPage({super.key});

  static final _apps = <_AppEntry>[
    _AppEntry(
      name: 'Terminal',
      icon: Icons.terminal,
      color: const Color(0xFF0F3460),
      builder: () => const TerminalPage(),
    ),
    _AppEntry(
      name: 'Wapp Runner',
      icon: Icons.memory,
      color: const Color(0xFF533483),
      builder: () => const WappRunnerPage(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Iwi'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            onSelected: (value) {},
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'settings', child: Text('Settings')),
              const PopupMenuItem(value: 'about', child: Text('About')),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 120,
            mainAxisSpacing: 20,
            crossAxisSpacing: 20,
          ),
          itemCount: _apps.length,
          itemBuilder: (context, index) {
            final app = _apps[index];
            return _AppIcon(
              name: app.name,
              icon: app.icon,
              color: app.color,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => app.builder()),
              ),
            );
          },
        ),
      ),
    );
  }
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
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, size: 28, color: Colors.white),
          ),
          const SizedBox(height: 6),
          Text(
            name,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ── Wapp Runner (moved from old HomePage) ─────────────────────────────

class WappRunnerPage extends StatefulWidget {
  const WappRunnerPage({super.key});

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
  void dispose() {
    _tickTimer?.cancel();
    _engine.dispose();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadWasm() async {
    setState(() => _status = 'Loading...');
    try {
      final bytes = await rootBundle.load('assets/hello_world.wasm');
      await _engine.load(bytes.buffer.asUint8List());
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
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
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
        title: const Text('Wapp Runner'),
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
                Text(_status, style: const TextStyle(fontSize: 13)),
                const Spacer(),
                if (!_engine.isLoaded)
                  TextButton.icon(
                    onPressed: _loadWasm,
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
