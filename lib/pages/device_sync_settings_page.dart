/// Device Sync Settings Page.
///
/// Shows known mirror devices, online status, and this device's nickname.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/mirror_config.dart';
import '../p2p/dht_node.dart' show PeerInfo;
import '../p2p/node_capability.dart';
import '../p2p/p2p_service.dart';
import '../services/mirror_config_service.dart';
import '../services/mirror_discovery_service.dart';
import '../services/websocket_service.dart';
import 'mirror_settings_page.dart';

/// Settings page for managing device sync configuration.
class DeviceSyncSettingsPage extends StatefulWidget {
  const DeviceSyncSettingsPage({super.key});

  @override
  State<DeviceSyncSettingsPage> createState() => _DeviceSyncSettingsPageState();
}

class _DeviceSyncSettingsPageState extends State<DeviceSyncSettingsPage> {
  final _configService = MirrorConfigService.instance;
  final _discovery = MirrorDiscoveryService();

  MirrorConfig? _config;
  StreamSubscription<MirrorConfig>? _configSub;
  late TextEditingController _nicknameController;

  @override
  void initState() {
    super.initState();
    // Show cached config immediately — no spinner needed
    _config = _configService.config;
    _nicknameController = TextEditingController(
      text: _config?.deviceName ?? '',
    );
    _configSub = _configService.configStream.listen((config) {
      if (mounted) {
        setState(() {
          _config = config;
        });
      }
    });
  }

  @override
  void dispose() {
    _configSub?.cancel();
    _nicknameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mirror config'),
      ),
      body: ValueListenableBuilder<List<MirrorDevice>>(
              valueListenable: _discovery.mirrors,
              builder: (context, discoveredMirrors, _) {
                return ListView(
                  children: [
                    // This device section
                    _buildThisDeviceSection(theme),

                    const Divider(),

                    // P2P Discovery section
                    _buildP2PSection(theme),

                    const Divider(),

                    // Known mirror devices section
                    _buildKnownDevicesSection(theme, discoveredMirrors),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildKnownDevicesSection(
    ThemeData theme,
    List<MirrorDevice> discoveredMirrors,
  ) {
    final peers = _config?.peers ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Known Mirror Devices',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (peers.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.devices, size: 48, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text(
                    'No mirror devices discovered yet',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          ...peers.map((peer) => _buildPeerTile(theme, peer, discoveredMirrors)),
      ],
    );
  }

  Widget _buildPeerTile(
    ThemeData theme,
    MirrorPeer peer,
    List<MirrorDevice> discoveredMirrors,
  ) {
    // Check if this peer is currently online via discovery
    final isOnline = discoveredMirrors.any(
      (m) => m.installId == peer.peerId,
    );

    return ListTile(
      leading: Stack(
        children: [
          _buildPlatformIcon(theme, peer.platform),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: isOnline ? Colors.green : Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.cardColor,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Text(peer.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            peer.lastSeenAt != null
                ? 'Last seen ${_formatTimeAgo(peer.lastSeenAt!)}'
                : 'Never seen',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          Text(
            peer.lastSyncAt != null
                ? 'Last sync ${_formatTimeAgo(peer.lastSyncAt!)}'
                : 'Never synced',
            style: theme.textTheme.bodySmall?.copyWith(
              color: peer.lastSyncAt != null
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
            tooltip: 'Remove device',
            onPressed: () => _confirmRemovePeer(peer),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PeerSettingsPage(peer: peer),
          ),
        );
        // Config updates arrive via stream subscription automatically
        if (mounted) setState(() => _config = _configService.config);
      },
    );
  }

  Widget _buildThisDeviceSection(ThemeData theme) {
    final currentPriority = _config?.priority ?? 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'This Device',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _nicknameController,
            decoration: const InputDecoration(
              labelText: 'Device nickname',
              hintText: 'Enter a name for this device',
              border: OutlineInputBorder(),
            ),
            onSubmitted: _saveNickname,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _saveNickname(_nicknameController.text),
              child: const Text('Save'),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonFormField<int>(
            value: currentPriority,
            decoration: const InputDecoration(
              labelText: 'Station routing priority',
              helperText: 'Which device serves content when visitors open your page',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 1, child: Text('High — serve content first')),
              DropdownMenuItem(value: 2, child: Text('Medium')),
              DropdownMenuItem(value: 3, child: Text('Low (default)')),
            ],
            onChanged: (value) {
              if (value != null && value != currentPriority) {
                _savePriority(value);
              }
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildP2PSection(ThemeData theme) {
    final p2p = P2PService();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'P2P Discovery',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SwitchListTile(
          title: const Text('Enable P2P'),
          subtitle: const Text('Find devices via DHT without station'),
          value: p2p.enabled,
          onChanged: (value) {
            setState(() {
              p2p.enabled = value;
              if (value && !p2p.isRunning) {
                p2p.start();
              }
            });
          },
        ),
        if (p2p.isRunning) ...[
          ListTile(
            leading: Icon(
              _nodeTypeIcon(p2p.nodeType),
              color: _nodeTypeColor(p2p.nodeType),
            ),
            title: Text('Node type: ${_nodeTypeLabel(p2p.nodeType)}'),
            subtitle: Text(
              p2p.publicIp != null
                  ? 'Public: ${p2p.publicIp}:${p2p.publicPort}'
                  : 'Detecting...',
            ),
          ),
          ListTile(
            leading: Icon(Icons.hub, color: theme.colorScheme.primary),
            title: Text('DHT peers: ${p2p.dhtPeerCount}'),
            subtitle: Text('Direct connections: ${p2p.directConnectionCount}'),
          ),
          if (p2p.discoveredPeers.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Devices found via internet',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            ...p2p.discoveredPeers.map((peer) => ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.teal.withValues(alpha: 0.1),
                child: const Icon(Icons.language, color: Colors.teal),
              ),
              title: Text('${peer.ip}:${peer.port}'),
              subtitle: const Text('DHT'),
            )),
          ],
        ],
      ],
    );
  }

  String _nodeTypeLabel(NodeType type) {
    switch (type) {
      case NodeType.typeA:
        return 'A (Public)';
      case NodeType.typeB:
        return 'B (NAT)';
      case NodeType.typeC:
        return 'C (Symmetric NAT)';
      case NodeType.unknown:
        return 'Detecting...';
    }
  }

  IconData _nodeTypeIcon(NodeType type) {
    switch (type) {
      case NodeType.typeA:
        return Icons.public;
      case NodeType.typeB:
        return Icons.router;
      case NodeType.typeC:
        return Icons.shield;
      case NodeType.unknown:
        return Icons.help_outline;
    }
  }

  Color _nodeTypeColor(NodeType type) {
    switch (type) {
      case NodeType.typeA:
        return Colors.green;
      case NodeType.typeB:
        return Colors.orange;
      case NodeType.typeC:
        return Colors.red;
      case NodeType.unknown:
        return Colors.grey;
    }
  }

  Future<void> _confirmRemovePeer(MirrorPeer peer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Device'),
        content: Text(
          'Remove "${peer.name}" from known devices?\n\n'
          'It will reappear automatically if it connects again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _configService.removePeer(peer.peerId);
      if (mounted) {
        setState(() => _config = _configService.config);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${peer.name} removed')),
        );
      }
    }
  }

  Future<void> _savePriority(int priority) async {
    await _configService.setPriority(priority);
    // Re-send hello so station gets the updated priority immediately
    WebSocketService().reconnect();
    if (mounted) {
      final label = priority == 1 ? 'High' : priority == 2 ? 'Medium' : 'Low';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Priority set to $label')),
      );
    }
  }

  Future<void> _saveNickname(String value) async {
    if (value.trim().isEmpty) return;
    await _configService.setDeviceName(value.trim());
    // Re-send hello so station gets the updated device name immediately
    WebSocketService().reconnect();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device nickname saved')),
      );
    }
  }

  Widget _buildPlatformIcon(ThemeData theme, String? platform) {
    IconData icon;
    Color color;

    switch (platform?.toLowerCase()) {
      case 'android':
        icon = Icons.android;
        color = Colors.green;
        break;
      case 'ios':
      case 'iphone':
        icon = Icons.phone_iphone;
        color = Colors.grey;
        break;
      case 'linux':
        icon = Icons.computer;
        color = Colors.orange;
        break;
      case 'macos':
      case 'mac':
        icon = Icons.laptop_mac;
        color = Colors.grey;
        break;
      case 'windows':
        icon = Icons.desktop_windows;
        color = Colors.blue;
        break;
      case 'internet':
        icon = Icons.language;
        color = Colors.teal;
        break;
      default:
        icon = Icons.devices;
        color = Colors.grey;
    }

    return CircleAvatar(
      backgroundColor: color.withOpacity(0.1),
      child: Icon(icon, color: color),
    );
  }

  String _formatTimeAgo(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dateTime.day}/${dateTime.month}';
  }
}
