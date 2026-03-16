/// Device Sync Settings Page.
///
/// Shows known mirror devices, online status, and this device's nickname.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/mirror_config.dart';
import '../services/mirror_config_service.dart';
import '../services/mirror_discovery_service.dart';
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
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController();
    _loadConfig();
    _configSub = _configService.configStream.listen((config) {
      if (mounted) {
        setState(() {
          _config = config;
        });
      }
    });
  }

  Future<void> _loadConfig() async {
    final config = await _configService.loadConfig();
    if (mounted) {
      setState(() {
        _config = config;
        _nicknameController.text = config.deviceName;
        _isLoading = false;
      });
    }
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
        title: const Text('Device Sync'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<List<MirrorDevice>>(
              valueListenable: _discovery.mirrors,
              builder: (context, discoveredMirrors, _) {
                return ListView(
                  children: [
                    // Known mirror devices section
                    _buildKnownDevicesSection(theme, discoveredMirrors),

                    const Divider(),

                    // This device section
                    _buildThisDeviceSection(theme),
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
      subtitle: Text(
        peer.lastSeenAt != null
            ? 'Last seen ${_formatTimeAgo(peer.lastSeenAt!)}'
            : 'Never seen',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PeerSettingsPage(peer: peer),
          ),
        );
        await _loadConfig();
      },
    );
  }

  Widget _buildThisDeviceSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _nicknameController,
            decoration: const InputDecoration(
              labelText: 'This device nickname',
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
        const SizedBox(height: 16),
      ],
    );
  }

  Future<void> _saveNickname(String value) async {
    if (value.trim().isEmpty) return;
    await _configService.setDeviceName(value.trim());
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
