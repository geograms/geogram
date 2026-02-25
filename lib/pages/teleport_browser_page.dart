/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/material.dart';
import '../services/app_service.dart';
import '../services/profile_storage.dart';
import '../teleport/telegram/telegram_service.dart';
import '../teleport/telegram/telegram_storage_service.dart';
import '../teleport/telegram/pages/telegram_auth_page.dart';
import '../teleport/telegram/pages/telegram_chat_list_page.dart';
import '../teleport/aprs/aprs_service.dart';
import '../teleport/aprs/pages/aprs_main_page.dart';
import '../teleport/signal/models/signal_auth_state.dart';
import '../teleport/signal/signal_service.dart';
import '../teleport/signal/signal_storage_service.dart';
import '../teleport/signal/pages/signal_auth_page.dart';
import '../teleport/signal/pages/signal_chat_list_page.dart';
import '../teleport/irc/irc_service.dart';
import '../teleport/irc/pages/irc_main_page.dart';
import '../teleport/xmpp/xmpp_service.dart';
import '../teleport/xmpp/pages/xmpp_main_page.dart';
import '../teleport/nostr/nostr_client_service.dart';
import '../teleport/nostr/pages/nostr_main_page.dart';

/// Browser page for the "Teleport" app — lists platform bridges
class TeleportBrowserPage extends StatefulWidget {
  final String appPath;
  final String appTitle;

  const TeleportBrowserPage({
    super.key,
    required this.appPath,
    required this.appTitle,
  });

  @override
  State<TeleportBrowserPage> createState() => _TeleportBrowserPageState();
}

class _TeleportBrowserPageState extends State<TeleportBrowserPage> {
  Map<String, dynamic>? _config;
  bool _isLoading = true;
  StreamSubscription<AprsEvent>? _aprsSub;
  StreamSubscription<IrcEvent>? _ircSub;
  StreamSubscription<XmppEvent>? _xmppSub;
  StreamSubscription<NostrClientEvent>? _nostrSub;

  /// Planned platform bridges
  static const List<_BridgeInfo> _bridges = [
    _BridgeInfo(
      id: 'telegram',
      name: 'Telegram',
      description: 'Cloud-based messaging with bot API integration',
      icon: Icons.telegram,
      color: Color(0xFF0088CC),
    ),
    _BridgeInfo(
      id: 'signal',
      name: 'Signal',
      description: 'End-to-end encrypted messaging via Signal protocol',
      icon: Icons.security,
      color: Color(0xFF3A76F0),
    ),
    _BridgeInfo(
      id: 'aprs',
      name: 'APRS',
      description: 'Amateur radio packet reporting and messaging',
      icon: Icons.cell_tower,
      color: Color(0xFFE65100),
    ),
    _BridgeInfo(
      id: 'whatsapp',
      name: 'WhatsApp',
      description: 'Cross-platform messaging via WhatsApp Web bridge',
      icon: Icons.chat,
      color: Color(0xFF25D366),
    ),
    _BridgeInfo(
      id: 'nostr',
      name: 'NOSTR',
      description: 'Decentralized relay-based messaging with NIP support',
      icon: Icons.hub,
      color: Color(0xFF8B5CF6),
    ),
    _BridgeInfo(
      id: 'bluesky',
      name: 'Bluesky',
      description: 'AT Protocol federation for decentralized social messaging',
      icon: Icons.cloud,
      color: Color(0xFF0085FF),
    ),
    _BridgeInfo(
      id: 'irc',
      name: 'IRC',
      description: 'Classic Internet Relay Chat with multi-server support',
      icon: Icons.terminal,
      color: Color(0xFF4CAF50),
    ),
    _BridgeInfo(
      id: 'matrix',
      name: 'Matrix',
      description: 'Open federated messaging with end-to-end encryption',
      icon: Icons.grid_view,
      color: Color(0xFF0DBD8B),
    ),
    _BridgeInfo(
      id: 'xmpp',
      name: 'XMPP',
      description: 'Extensible messaging with Jabber protocol support',
      icon: Icons.message,
      color: Color(0xFFFF6600),
    ),
  ];

  /// IDs of implemented bridges (not "Coming Soon").
  static const _implementedIds = {'telegram', 'signal', 'aprs', 'irc', 'xmpp', 'nostr'};

  /// Bridges sorted: implemented first, "Coming Soon" at the bottom.
  static final List<_BridgeInfo> _sortedBridges = [
    ..._bridges.where((b) => _implementedIds.contains(b.id)),
    ..._bridges.where((b) => !_implementedIds.contains(b.id)),
  ];

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _aprsSub = AprsService().events.listen((_) {
      if (mounted) setState(() {});
    });
    _ircSub = IrcService().events.listen((_) {
      if (mounted) setState(() {});
    });
    _xmppSub = XmppService().events.listen((_) {
      if (mounted) setState(() {});
    });
    _nostrSub = NostrClientService().events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _aprsSub?.cancel();
    _ircSub?.cancel();
    _xmppSub?.cancel();
    _nostrSub?.cancel();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final profileStorage = AppService().profileStorage;
      if (profileStorage != null) {
        final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
          profileStorage,
          widget.appPath,
        );
        final configStr = await scopedStorage.readString('config.json');
        if (configStr != null) {
          setState(() {
            _config = jsonDecode(configStr) as Map<String, dynamic>;
            _isLoading = false;
          });
          return;
        }
      } else {
        final configFile = File('${widget.appPath}/config.json');
        if (await configFile.exists()) {
          final configStr = await configFile.readAsString();
          setState(() {
            _config = jsonDecode(configStr) as Map<String, dynamic>;
            _isLoading = false;
          });
          return;
        }
      }
    } catch (_) {}

    setState(() => _isLoading = false);
  }

  /// Check if a bridge is active in the config
  bool _isBridgeActive(String bridgeId) {
    if (_config == null) return false;
    final bridges = _config!['bridges'] as List<dynamic>? ?? [];
    return bridges.any(
      (b) => b is Map<String, dynamic> && b['platform'] == bridgeId && b['enabled'] == true,
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.rocket_launch, size: 24),
            SizedBox(width: 12),
            Text('About Teleport'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Teleport is a modular bridge system that connects Geogram '
              'to external messaging platforms.',
            ),
            SizedBox(height: 12),
            Text(
              'Each platform bridge runs independently with its own '
              'credentials and connection state. Messages are synced '
              'through a unified interface while keeping per-bridge '
              'isolation for security.',
            ),
            SizedBox(height: 12),
            Text(
              'Platform bridges are being added incrementally. '
              'Check back for updates as new bridges become available.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About Teleport',
            onPressed: _showAboutDialog,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _sortedBridges.length,
              itemBuilder: (context, index) =>
                  _buildBridgeCard(_sortedBridges[index], theme),
            ),
    );
  }

  /// Ensure Telegram bridge config exists, creating with defaults if needed.
  Future<void> _ensureTelegramConfig() async {
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) return;
    final scoped = ScopedProfileStorage.fromAbsolutePath(
      profileStorage,
      widget.appPath,
    );
    final storage = TelegramStorageService.fromScoped(scoped);
    if (await storage.hasConfig()) return;

    await storage.ensureDirectories();
    await storage.writeConfig({
      'api_id': TelegramService.defaultApiId,
      'api_hash': TelegramService.defaultApiHash,
      'created': DateTime.now().toUtc().toIso8601String(),
    });
    await storage.registerBridge(enabled: false);
  }

  void _onTelegramTap() async {
    if (_isBridgeActive('telegram') || TelegramService().isRunning) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TelegramChatListPage(appPath: widget.appPath),
        ),
      );
      return;
    }

    try {
      await _ensureTelegramConfig();
    } catch (_) {}
    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TelegramAuthPage(appPath: widget.appPath),
      ),
    );
  }

  /// Ensure Signal bridge config exists, creating with defaults if needed.
  Future<void> _ensureSignalConfig() async {
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) return;
    final scoped = ScopedProfileStorage.fromAbsolutePath(
      profileStorage,
      widget.appPath,
    );
    final storage = SignalStorageService.fromScoped(scoped);
    if (await storage.hasConfig()) return;

    await storage.ensureDirectories();
    await storage.writeConfig({
      'created': DateTime.now().toUtc().toIso8601String(),
    });
    await storage.registerBridge(enabled: false);
  }

  void _onAprsTap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AprsMainPage(appPath: widget.appPath),
      ),
    );
  }

  void _onIrcTap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IrcMainPage(appPath: widget.appPath),
      ),
    );
  }

  void _onXmppTap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => XmppMainPage(appPath: widget.appPath),
      ),
    );
  }

  void _onNostrTap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NostrMainPage(appPath: widget.appPath),
      ),
    );
  }

  void _onSignalTap() async {
    final signalService = SignalService();
    if ((_isBridgeActive('signal') || signalService.isRunning) &&
        signalService.authState.state == SignalAuthState.ready) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SignalChatListPage(appPath: widget.appPath),
        ),
      );
      return;
    }

    try {
      await _ensureSignalConfig();
    } catch (_) {}
    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SignalAuthPage(appPath: widget.appPath),
      ),
    );
  }

  Widget _buildBridgeCard(_BridgeInfo bridge, ThemeData theme) {
    final isActive = _isBridgeActive(bridge.id);
    final isTelegramRunning =
        bridge.id == 'telegram' && TelegramService().isRunning;
    final isSignalRunning =
        bridge.id == 'signal' && SignalService().isRunning;
    final isAprsEnabled =
        bridge.id == 'aprs' && AprsService().isEnabled;
    final isIrcConnected =
        bridge.id == 'irc' && IrcService().isAnyConnected;
    final isXmppConnected =
        bridge.id == 'xmpp' && XmppService().isAnyConnected;
    final isNostrConnected =
        bridge.id == 'nostr' && NostrClientService().isAnyConnected;
    final showActive =
        isActive || isTelegramRunning || isSignalRunning || isAprsEnabled || isIrcConnected || isXmppConnected || isNostrConnected;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (bridge.id == 'telegram') {
              _onTelegramTap();
              return;
            }
            if (bridge.id == 'aprs') {
              _onAprsTap();
              return;
            }
            if (bridge.id == 'signal') {
              _onSignalTap();
              return;
            }
            if (bridge.id == 'irc') {
              _onIrcTap();
              return;
            }
            if (bridge.id == 'xmpp') {
              _onXmppTap();
              return;
            }
            if (bridge.id == 'nostr') {
              _onNostrTap();
              return;
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${bridge.name} bridge coming soon'),
                duration: const Duration(seconds: 2),
              ),
            );
          },
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Platform icon
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: bridge.color.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    bridge.icon,
                    size: 24,
                    color: bridge.color,
                  ),
                ),
                const SizedBox(width: 16),
                // Name and description
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bridge.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        bridge.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Status badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: showActive
                        ? Colors.green.withValues(alpha: 0.15)
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    showActive
                        ? 'Active'
                        : (bridge.id == 'aprs' || bridge.id == 'irc' || bridge.id == 'xmpp' || bridge.id == 'nostr')
                            ? 'Available'
                            : 'Coming Soon',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: showActive
                          ? Colors.green
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Static information about a planned platform bridge
class _BridgeInfo {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final Color color;

  const _BridgeInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.color,
  });
}
