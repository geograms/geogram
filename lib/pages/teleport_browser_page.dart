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
import '../teleport/atproto/atproto_client_service.dart';
import '../teleport/atproto/pages/atproto_main_page.dart';
import '../teleport/meshcore/meshcore_service.dart';
import '../teleport/meshcore/pages/meshcore_main_page.dart';
import '../teleport/bitchat/bitchat_service.dart';
import '../teleport/bitchat/pages/bitchat_main_page.dart';
import '../teleport/meshtastic/meshtastic_service.dart';
import '../teleport/meshtastic/pages/meshtastic_main_page.dart';
import '../services/i18n_service.dart';

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
  StreamSubscription<AtprotoClientEvent>? _atprotoSub;
  StreamSubscription<MeshCoreEvent>? _meshcoreSub;
  StreamSubscription<BitchatEvent>? _bitchatSub;
  StreamSubscription<MeshtasticEvent>? _meshtasticSub;

  /// Planned platform bridges
  static const List<_BridgeInfo> _bridges = [
    _BridgeInfo(
      id: 'telegram',
      name: 'Telegram',
      descriptionKey: 'teleport_telegram_desc',
      icon: Icons.telegram,
      color: Color(0xFF0088CC),
    ),
    _BridgeInfo(
      id: 'signal',
      name: 'Signal',
      descriptionKey: 'teleport_signal_desc',
      icon: Icons.security,
      color: Color(0xFF3A76F0),
    ),
    _BridgeInfo(
      id: 'aprs',
      name: 'APRS',
      descriptionKey: 'teleport_aprs_desc',
      icon: Icons.cell_tower,
      color: Color(0xFFE65100),
    ),
    _BridgeInfo(
      id: 'meshcore',
      name: 'MeshCore',
      descriptionKey: 'teleport_meshcore_desc',
      icon: Icons.radio,
      color: Color(0xFF00BCD4),
    ),
    _BridgeInfo(
      id: 'bitchat',
      name: 'BitChat',
      descriptionKey: 'teleport_bitchat_desc',
      icon: Icons.bluetooth_connected,
      color: Color(0xFFFF9100),
    ),
    _BridgeInfo(
      id: 'meshtastic',
      name: 'Meshtastic',
      descriptionKey: 'teleport_meshtastic_desc',
      icon: Icons.landscape,
      color: Color(0xFF67EA94),
    ),
    _BridgeInfo(
      id: 'whatsapp',
      name: 'WhatsApp',
      descriptionKey: 'teleport_whatsapp_desc',
      icon: Icons.chat,
      color: Color(0xFF25D366),
    ),
    _BridgeInfo(
      id: 'nostr',
      name: 'NOSTR',
      descriptionKey: 'teleport_nostr_desc',
      icon: Icons.hub,
      color: Color(0xFF8B5CF6),
    ),
    _BridgeInfo(
      id: 'bluesky',
      name: 'Bluesky',
      descriptionKey: 'teleport_atproto_desc',
      icon: Icons.cloud,
      color: Color(0xFF0085FF),
    ),
    _BridgeInfo(
      id: 'irc',
      name: 'IRC',
      descriptionKey: 'teleport_irc_desc',
      icon: Icons.terminal,
      color: Color(0xFF4CAF50),
    ),
    _BridgeInfo(
      id: 'matrix',
      name: 'Matrix',
      descriptionKey: 'teleport_matrix_desc',
      icon: Icons.grid_view,
      color: Color(0xFF0DBD8B),
    ),
    _BridgeInfo(
      id: 'xmpp',
      name: 'XMPP',
      descriptionKey: 'teleport_xmpp_desc',
      icon: Icons.message,
      color: Color(0xFFFF6600),
    ),
  ];

  /// IDs of implemented bridges (not "Coming Soon").
  static const _implementedIds = {
    'telegram',
    'signal',
    'aprs',
    'meshcore',
    'irc',
    'xmpp',
    'nostr',
    'bluesky',
    'bitchat',
    'meshtastic',
  };

  /// Dynamic sort: active first, then available, then coming soon.
  /// Called on every build so the order reflects live service state.
  List<_BridgeInfo> _getSortedBridges() {
    int tierOf(_BridgeInfo b) {
      if (_isRuntimeActive(b.id)) return 0;           // Active
      if (_isBridgeAvailable(b.id)) return 1;          // Available / installable
      return 2;                                         // Coming soon
    }
    final sorted = List<_BridgeInfo>.from(_bridges);
    sorted.sort((a, b) => tierOf(a).compareTo(tierOf(b)));
    return sorted;
  }

  /// Check if a bridge has a live runtime connection right now.
  bool _isRuntimeActive(String bridgeId) {
    switch (bridgeId) {
      case 'telegram':
        return TelegramService().isRunning;
      case 'signal':
        return SignalService().isRunning;
      case 'aprs':
        return AprsService().isEnabled;
      case 'irc':
        return IrcService().isAnyConnected;
      case 'xmpp':
        return XmppService().isAnyConnected;
      case 'nostr':
        return NostrClientService().isAnyConnected;
      case 'bluesky':
        return AtprotoClientService().config.enabled && AtprotoClientService().isAuthenticated;
      case 'meshcore':
        return MeshCoreService().isConnected;
      case 'bitchat':
        return BitchatService().isEnabled;
      case 'meshtastic':
        return MeshtasticService().isConnected;
      default:
        return _isBridgeActive(bridgeId);
    }
  }

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
    _atprotoSub = AtprotoClientService().events.listen((_) {
      if (mounted) setState(() {});
    });
    _meshcoreSub = MeshCoreService().events.listen((_) {
      if (mounted) setState(() {});
    });
    _bitchatSub = BitchatService().events.listen((_) {
      if (mounted) setState(() {});
    });
    _meshtasticSub = MeshtasticService().events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _aprsSub?.cancel();
    _ircSub?.cancel();
    _xmppSub?.cancel();
    _nostrSub?.cancel();
    _atprotoSub?.cancel();
    _meshcoreSub?.cancel();
    _bitchatSub?.cancel();
    _meshtasticSub?.cancel();
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
      (b) =>
          b is Map<String, dynamic> &&
          b['platform'] == bridgeId &&
          b['enabled'] == true,
    );
  }

  /// Whether a bridge is available on this platform (implemented + native deps present).
  bool _isBridgeAvailable(String bridgeId) {
    if (!_implementedIds.contains(bridgeId)) return false;
    // Telegram and Signal require native FFI libraries — check at runtime
    if (bridgeId == 'telegram') return TelegramService.isAvailable;
    if (bridgeId == 'signal') return SignalService.isAvailable;
    return true;
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.rocket_launch, size: 24),
            const SizedBox(width: 12),
            Text(I18nService().t('teleport_about_title')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              I18nService().t('teleport_about_desc_1'),
            ),
            const SizedBox(height: 12),
            Text(
              I18nService().t('teleport_about_desc_2'),
            ),
            const SizedBox(height: 12),
            Text(
              I18nService().t('teleport_about_desc_3'),
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(I18nService().t('ok')),
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
            tooltip: I18nService().t('teleport_about_title'),
            onPressed: _showAboutDialog,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Builder(builder: (context) {
              final sorted = _getSortedBridges();
              return ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: sorted.length,
                itemBuilder: (context, index) =>
                    _buildBridgeCard(sorted[index], theme),
              );
            }),
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

  void _onMeshCoreTap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MeshCoreMainPage(appPath: widget.appPath),
      ),
    );
  }

  void _onBitchatTap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BitchatMainPage(appPath: widget.appPath),
      ),
    );
  }

  void _onMeshtasticTap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MeshtasticMainPage(appPath: widget.appPath),
      ),
    );
  }

  void _onAprsTap() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AprsMainPage(appPath: widget.appPath)),
    );
  }

  void _onIrcTap() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => IrcMainPage(appPath: widget.appPath)),
    );
  }

  void _onXmppTap() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => XmppMainPage(appPath: widget.appPath)),
    );
  }

  void _onNostrTap() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NostrMainPage(appPath: widget.appPath)),
    );
  }

  void _onAtprotoTap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AtprotoMainPage(appPath: widget.appPath),
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
    final showActive = _isRuntimeActive(bridge.id);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            // Guard FFI-dependent bridges — show snackbar if native lib missing
            if (!_isBridgeAvailable(bridge.id) && !_isBridgeActive(bridge.id)) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(I18nService().t('teleport_bridge_coming_soon_msg', params: [bridge.name])),
                  duration: const Duration(seconds: 2),
                ),
              );
              return;
            }
            if (bridge.id == 'telegram') {
              _onTelegramTap();
              return;
            }
            if (bridge.id == 'meshcore') {
              _onMeshCoreTap();
              return;
            }
            if (bridge.id == 'bitchat') {
              _onBitchatTap();
              return;
            }
            if (bridge.id == 'meshtastic') {
              _onMeshtasticTap();
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
            if (bridge.id == 'bluesky') {
              _onAtprotoTap();
              return;
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(I18nService().t('teleport_bridge_coming_soon_msg', params: [bridge.name])),
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
                  child: Icon(bridge.icon, size: 24, color: bridge.color),
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
                        I18nService().t(bridge.descriptionKey),
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
                        ? I18nService().t('teleport_bridge_status_active')
                        : _isBridgeAvailable(bridge.id)
                        ? I18nService().t('teleport_bridge_status_available')
                        : I18nService().t('teleport_bridge_status_coming_soon'),
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
  final String descriptionKey;
  final IconData icon;
  final Color color;

  const _BridgeInfo({
    required this.id,
    required this.name,
    required this.descriptionKey,
    required this.icon,
    required this.color,
  });
}
