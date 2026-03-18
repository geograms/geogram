/// Mirror Settings Page.
///
/// Configure device mirroring and manage paired devices.
library;

import 'package:flutter/material.dart';

import '../models/mirror_config.dart';
import '../services/mirror_auto_sync_service.dart';
import '../services/mirror_config_service.dart';
import '../services/mirror_sync_service.dart';
import '../widgets/transfer/transfer_progress_widget.dart';
import 'mirror_wizard_page.dart';
import 'sync_exclude_rules_page.dart';

/// Opens a non-dismissible modal dialog that displays real-time sync progress.
///
/// Returns a record with:
/// - `onProgress`: callback to feed [SyncStatus] updates into the dialog
/// - `close`: callback to dismiss the dialog when sync is done
({void Function(SyncStatus) onProgress, VoidCallback close})
    _showSyncProgressDialog(BuildContext context, {String? peerName}) {
  SyncStatus status = SyncStatus.idle();
  late StateSetter dialogSetState;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          dialogSetState = setState;

          String phaseLabel;
          switch (status.state) {
            case 'requesting':
              phaseLabel = 'Requesting permission...';
              break;
            case 'fetching_manifest':
              phaseLabel = 'Fetching file list...';
              break;
            case 'syncing':
              phaseLabel = 'Syncing files';
              break;
            case 'done':
              phaseLabel = 'Complete';
              break;
            case 'error':
              phaseLabel = 'Error';
              break;
            default:
              phaseLabel = 'Preparing...';
          }

          return AlertDialog(
            title: Text(peerName != null
                ? 'Syncing with $peerName...'
                : 'Syncing...'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(phaseLabel,
                    style: Theme.of(context).textTheme.bodyMedium),
                if (status.state == 'syncing' &&
                    status.currentFile != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    status.currentFile!.length > 40
                        ? '...${status.currentFile!.substring(status.currentFile!.length - 37)}'
                        : status.currentFile!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                          fontFamily: 'monospace',
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (status.totalFiles > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${status.filesProcessed} / ${status.totalFiles} files',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                if (status.totalBytes > 0)
                  TransferProgressWidget(
                    bytesTransferred: status.bytesTransferred,
                    totalBytes: status.totalBytes,
                    showSpeed: false,
                    showEta: false,
                  )
                else
                  const LinearProgressIndicator(),
              ],
            ),
          );
        },
      );
    },
  );

  return (
    onProgress: (SyncStatus s) {
      // Guard: dialogSetState may not be initialized yet on very fast first
      // callback; the StatefulBuilder builder will pick up the latest status.
      status = s;
      try {
        dialogSetState(() {});
      } catch (_) {
        // Dialog already dismissed or not yet built — ignore.
      }
    },
    close: () {
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    },
  );
}

/// Settings page for mirror sync configuration
class MirrorSettingsPage extends StatefulWidget {
  const MirrorSettingsPage({super.key});

  @override
  State<MirrorSettingsPage> createState() => _MirrorSettingsPageState();
}

class _MirrorSettingsPageState extends State<MirrorSettingsPage> {
  final MirrorConfigService _configService = MirrorConfigService.instance;

  MirrorConfig? _config;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await _configService.loadConfig();
    // Restore in-memory allowed peers from persisted config
    MirrorSyncService.instance.loadAllowedPeersFromConfig();
    if (mounted) {
      setState(() {
        _config = config;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mirror'),
        actions: [
          if (_config?.enabled == true && _config!.peers.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: 'Sync now',
              onPressed: _syncAll,
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'excluded_files') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const SyncExcludeRulesPage(),
                  ),
                ).then((_) => _loadConfig());
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'excluded_files',
                child: ListTile(
                  leading: Icon(Icons.filter_alt),
                  title: Text('Excluded files'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // Enable mirror switch
                _buildEnableSection(theme),

                if (_config?.enabled == true) ...[
                  const Divider(),

                  // This device section
                  _buildThisDeviceSection(theme),

                  const Divider(),

                  // Paired devices section
                  _buildPeersSection(theme),

                  const Divider(),

                  // Connection preferences section
                  _buildPreferencesSection(theme),
                ],
              ],
            ),
      floatingActionButton: _config?.enabled == true
          ? FloatingActionButton.extended(
              onPressed: _openWizard,
              icon: const Icon(Icons.add),
              label: const Text('Add Device'),
            )
          : null,
    );
  }

  Widget _buildEnableSection(ThemeData theme) {
    return SwitchListTile(
      secondary: Icon(
        Icons.sync_alt,
        color: _config?.enabled == true
            ? theme.colorScheme.primary
            : theme.colorScheme.outline,
      ),
      title: const Text('Enable Mirror'),
      subtitle: const Text(
        'Keep apps synchronized between your devices',
      ),
      value: _config?.enabled ?? false,
      onChanged: (value) async {
        await _configService.setEnabled(value);
        setState(() {
          _config = _config?.copyWith(enabled: value);
        });
      },
    );
  }

  Widget _buildThisDeviceSection(ThemeData theme) {
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
        ListTile(
          leading: _buildPlatformIcon(null),
          title: Text(_config?.deviceName ?? 'My Device'),
          subtitle: Text(
            'ID: ${_config?.deviceId.substring(0, 8)}...',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.edit),
            onPressed: _editDeviceName,
          ),
        ),
        _buildConnectionQualityIndicator(theme),
      ],
    );
  }

  Widget _buildConnectionQualityIndicator(ThemeData theme) {
    // TODO: Get actual connection quality from network monitor
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.wifi,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            'WiFi Connected',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'Excellent',
              style: TextStyle(
                fontSize: 11,
                color: Colors.green,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeersSection(ThemeData theme) {
    final peers = _config?.peers ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                'Paired Devices',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                '${peers.length} device${peers.length != 1 ? 's' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        if (peers.isEmpty)
          _buildEmptyPeersCard(theme)
        else
          ...peers.map((peer) => _buildPeerTile(theme, peer)),
      ],
    );
  }

  Widget _buildEmptyPeersCard(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              Icons.devices,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No paired devices',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Add a device to start syncing your apps',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _openWizard,
              icon: const Icon(Icons.add),
              label: const Text('Add Device'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeerTile(ThemeData theme, MirrorPeer peer) {
    final syncState = peer.overallSyncState;

    return Dismissible(
      key: Key(peer.peerId),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remove Device'),
            content: Text('Remove "${peer.name}" from paired devices?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        );
      },
      onDismissed: (direction) async {
        await _configService.removePeer(peer.peerId);
        await _loadConfig();
      },
      child: ListTile(
        leading: Stack(
          children: [
            _buildPlatformIcon(peer.platform),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: peer.isOnline ? Colors.green : Colors.grey,
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
        subtitle: Row(
          children: [
            _buildSyncStateChip(theme, syncState),
            if (peer.lastSyncAt != null) ...[
              const SizedBox(width: 8),
              Text(
                _formatLastSync(peer.lastSyncAt!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openPeerSettings(peer),
      ),
    );
  }

  Widget _buildSyncStateChip(ThemeData theme, SyncState state) {
    Color color;
    String label;
    IconData icon;

    switch (state) {
      case SyncState.idle:
        color = Colors.green;
        label = 'Synced';
        icon = Icons.check;
        break;
      case SyncState.scanning:
        color = Colors.blue;
        label = 'Scanning';
        icon = Icons.search;
        break;
      case SyncState.syncing:
        color = Colors.blue;
        label = 'Syncing';
        icon = Icons.sync;
        break;
      case SyncState.outOfSync:
        color = Colors.orange;
        label = 'Pending';
        icon = Icons.schedule;
        break;
      case SyncState.error:
        color = Colors.red;
        label = 'Error';
        icon = Icons.error_outline;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreferencesSection(ThemeData theme) {
    final prefs = _config?.preferences ?? ConnectionPreferences();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Sync Preferences',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.signal_cellular_alt),
          title: const Text('Sync over cellular'),
          subtitle: const Text('Use mobile data for syncing'),
          value: prefs.allowMetered,
          onChanged: (value) async {
            final updated = ConnectionPreferences(
              allowMetered: value,
              meteredBandwidthLimit: prefs.meteredBandwidthLimit,
              allowOnBattery: prefs.allowOnBattery,
              minBatteryLevel: prefs.minBatteryLevel,
              lanDiscovery: prefs.lanDiscovery,
              bleDiscovery: prefs.bleDiscovery,
              autoSync: prefs.autoSync,
              syncIntervalMinutes: prefs.syncIntervalMinutes,
            );
            await _configService.updatePreferences(updated);
            await _loadConfig();
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.wifi_find),
          title: const Text('LAN discovery'),
          subtitle: const Text('Find devices on local network'),
          value: prefs.lanDiscovery,
          onChanged: (value) async {
            final updated = ConnectionPreferences(
              allowMetered: prefs.allowMetered,
              meteredBandwidthLimit: prefs.meteredBandwidthLimit,
              allowOnBattery: prefs.allowOnBattery,
              minBatteryLevel: prefs.minBatteryLevel,
              lanDiscovery: value,
              bleDiscovery: prefs.bleDiscovery,
              autoSync: prefs.autoSync,
              syncIntervalMinutes: prefs.syncIntervalMinutes,
            );
            await _configService.updatePreferences(updated);
            await _loadConfig();
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.bluetooth_searching),
          title: const Text('Bluetooth discovery'),
          subtitle: const Text('Find nearby devices via Bluetooth'),
          value: prefs.bleDiscovery,
          onChanged: (value) async {
            final updated = ConnectionPreferences(
              allowMetered: prefs.allowMetered,
              meteredBandwidthLimit: prefs.meteredBandwidthLimit,
              allowOnBattery: prefs.allowOnBattery,
              minBatteryLevel: prefs.minBatteryLevel,
              lanDiscovery: prefs.lanDiscovery,
              bleDiscovery: value,
              autoSync: prefs.autoSync,
              syncIntervalMinutes: prefs.syncIntervalMinutes,
            );
            await _configService.updatePreferences(updated);
            await _loadConfig();
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.autorenew),
          title: const Text('Auto-sync'),
          subtitle: const Text('Automatically sync when peers connect'),
          value: prefs.autoSync,
          onChanged: (value) async {
            final updated = ConnectionPreferences(
              allowMetered: prefs.allowMetered,
              meteredBandwidthLimit: prefs.meteredBandwidthLimit,
              allowOnBattery: prefs.allowOnBattery,
              minBatteryLevel: prefs.minBatteryLevel,
              lanDiscovery: prefs.lanDiscovery,
              bleDiscovery: prefs.bleDiscovery,
              autoSync: value,
              syncIntervalMinutes: prefs.syncIntervalMinutes,
            );
            await _configService.updatePreferences(updated);
            await _loadConfig();
          },
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildPlatformIcon(String? platform) {
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

  String _formatLastSync(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dateTime.day}/${dateTime.month}';
  }

  void _editDeviceName() async {
    final controller = TextEditingController(text: _config?.deviceName);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Device Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'Enter a friendly name',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await _configService.setDeviceName(result);
      await _loadConfig();
    }
  }

  void _openWizard() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => const MirrorWizardPage(),
      ),
    );
    await _loadConfig();
  }

  void _openPeerSettings(MirrorPeer peer) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PeerSettingsPage(peer: peer),
      ),
    );
    await _loadConfig();
  }

  void _syncAll() async {
    final peers = _config?.peers ?? [];
    if (peers.isEmpty) return;

    final dialog = _showSyncProgressDialog(context);

    final result = await MirrorAutoSyncService.instance.syncAllPeers(
      onProgress: dialog.onProgress,
    );

    dialog.close();

    if (mounted) {
      final parts = <String>[];
      if (result.filesAdded > 0) parts.add('+${result.filesAdded} new');
      if (result.filesModified > 0) parts.add('~${result.filesModified} updated');
      if (result.filesUploaded > 0) parts.add('↑${result.filesUploaded} uploaded');
      if (result.peersSkipped > 0) parts.add('${result.peersSkipped} peer(s) skipped — no address');
      final summary = parts.isEmpty ? 'No changes.' : parts.join(', ');
      final msg = result.errors > 0
          ? 'Sync done with ${result.errors} error(s). $summary'
          : 'Sync complete. $summary';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
  }
}

/// Settings page for a specific peer
class PeerSettingsPage extends StatefulWidget {
  final MirrorPeer peer;

  const PeerSettingsPage({super.key, required this.peer});

  @override
  State<PeerSettingsPage> createState() => _PeerSettingsPageState();
}

class _PeerSettingsPageState extends State<PeerSettingsPage> {
  final MirrorConfigService _configService = MirrorConfigService.instance;
  late MirrorPeer _peer;

  @override
  void initState() {
    super.initState();
    _peer = widget.peer;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_peer.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Sync now',
            onPressed: _syncNow,
          ),
        ],
      ),
      body: ListView(
        children: [
          // Peer info section
          _buildPeerInfoSection(theme),

          const Divider(),

          // Sync mode section
          _buildSyncModeSection(theme),

          const Divider(),

          // Apps section
          _buildAppsSection(theme),

          const Divider(),

          // Addresses section
          _buildAddressesSection(theme),

          const SizedBox(height: 16),

          // Remove button
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: _removePeer,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove Device'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeerInfoSection(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  _getPlatformIcon(_peer.platform),
                  size: 32,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _peer.name,
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _peer.isOnline ? Colors.green : Colors.grey,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _peer.isOnline ? 'Online' : 'Offline',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _peer.isOnline ? Colors.green : Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: _editPeerName,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildInfoRow(
            theme,
            'Device ID',
            _peer.peerId.substring(0, 8) + '...',
            Icons.fingerprint,
          ),
          if (_peer.lastSyncAt != null)
            _buildInfoRow(
              theme,
              'Last sync',
              _formatDateTime(_peer.lastSyncAt!),
              Icons.sync,
            ),
          if (_peer.lastSeenAt != null)
            _buildInfoRow(
              theme,
              'Last seen',
              _formatDateTime(_peer.lastSeenAt!),
              Icons.visibility,
            ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(
    ThemeData theme,
    String label,
    String value,
    IconData icon,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildSyncModeSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Sync Mode',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<AutoSyncMode>(
            segments: const [
              ButtonSegment(
                value: AutoSyncMode.manual,
                label: Text('Manual'),
                icon: Icon(Icons.touch_app, size: 18),
              ),
              ButtonSegment(
                value: AutoSyncMode.automatic,
                label: Text('Automatic'),
                icon: Icon(Icons.autorenew, size: 18),
              ),
            ],
            selected: {_peer.autoSyncMode},
            onSelectionChanged: (value) async {
              final mode = value.first;
              final updated = _peer.copyWith(
                autoSyncMode: mode,
                syncIntervalMinutes: mode == AutoSyncMode.automatic
                    ? (_peer.syncIntervalMinutes ?? 60)
                    : _peer.syncIntervalMinutes,
              );
              await _configService.updatePeer(updated);
              setState(() {
                _peer = updated;
              });
            },
          ),
        ),
        if (_peer.autoSyncMode == AutoSyncMode.automatic)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Text('Every ', style: theme.textTheme.bodyMedium),
                DropdownButton<int>(
                  value: _peer.syncIntervalMinutes ?? 60,
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(value: 15, child: Text('15 min')),
                    DropdownMenuItem(value: 60, child: Text('1 hour')),
                    DropdownMenuItem(value: 1440, child: Text('1 day')),
                    DropdownMenuItem(value: 10080, child: Text('1 week')),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    final updated = _peer.copyWith(syncIntervalMinutes: value);
                    await _configService.updatePeer(updated);
                    setState(() {
                      _peer = updated;
                    });
                  },
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildAppsSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Apps to Sync',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...kSyncableFolders.map((id) {
          final labels = kFolderLabels[id];
          return _buildAppTile(
            theme,
            id,
            labels?.$1 ?? id,
            labels?.$2 ?? '',
          );
        }),
      ],
    );
  }

  Widget _buildAppTile(
    ThemeData theme,
    String appId,
    String name,
    String description,
  ) {
    final appConfig = _peer.apps[appId];
    final enabled = appConfig?.enabled ?? false;
    final style = appConfig?.style ?? SyncStyle.sendReceive;

    return ListTile(
      leading: Switch(
        value: enabled,
        onChanged: (value) => _toggleApp(appId, value),
      ),
      title: Text(name),
      subtitle: Text(description),
      trailing: enabled
          ? DropdownButton<SyncStyle>(
              value: style,
              underline: const SizedBox(),
              items: SyncStyle.values.map((s) {
                return DropdownMenuItem(
                  value: s,
                  child: Text(_syncStyleLabel(s)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  _updateAppStyle(appId, value);
                }
              },
            )
          : null,
    );
  }

  Widget _buildAddressesSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Known Addresses',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (_peer.addresses.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No addresses known',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          )
        else
          ..._peer.addresses.map((addr) => ListTile(
                leading: Icon(
                  addr.startsWith('http')
                      ? Icons.language
                      : addr.contains(':')
                          ? Icons.lan
                          : Icons.bluetooth,
                  size: 20,
                ),
                title: Text(
                  addr,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    // TODO: Copy to clipboard
                  },
                ),
              )),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(
            onPressed: _addAddress,
            icon: const Icon(Icons.add),
            label: const Text('Add Address'),
          ),
        ),
      ],
    );
  }

  IconData _getPlatformIcon(String? platform) {
    switch (platform?.toLowerCase()) {
      case 'android':
        return Icons.android;
      case 'ios':
      case 'iphone':
        return Icons.phone_iphone;
      case 'linux':
        return Icons.computer;
      case 'macos':
      case 'mac':
        return Icons.laptop_mac;
      case 'windows':
        return Icons.desktop_windows;
      default:
        return Icons.devices;
    }
  }

  String _syncStyleLabel(SyncStyle style) {
    switch (style) {
      case SyncStyle.sendReceive:
        return '\u2194 Both ways';
      case SyncStyle.receiveOnly:
        return 'Other \u2192 This';
      case SyncStyle.sendOnly:
        return 'This \u2192 Other';
      case SyncStyle.paused:
        return 'Paused';
    }
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _editPeerName() async {
    final controller = TextEditingController(text: _peer.name);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Device Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Name',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      final updated = _peer.copyWith(name: result);
      await _configService.updatePeer(updated);
      setState(() {
        _peer = updated;
      });
    }
  }

  void _toggleApp(String appId, bool enabled) async {
    final currentConfig = _peer.apps[appId] ??
        AppSyncConfig(appId: appId, style: SyncStyle.sendReceive);
    final updated = currentConfig.copyWith(enabled: enabled);

    await _configService.updatePeerAppConfig(_peer.peerId, appId, updated);

    setState(() {
      _peer.apps[appId] = updated;
    });
  }

  void _updateAppStyle(String appId, SyncStyle style) async {
    final currentConfig = _peer.apps[appId];
    if (currentConfig == null) return;

    final updated = currentConfig.copyWith(style: style);
    await _configService.updatePeerAppConfig(_peer.peerId, appId, updated);

    setState(() {
      _peer.apps[appId] = updated;
    });
  }

  void _addAddress() async {
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Address'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Address',
            hintText: 'e.g., 192.168.1.100 or http://...',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      final addresses = List<String>.from(_peer.addresses);
      if (!addresses.contains(result)) {
        addresses.add(result);
        final updated = _peer.copyWith(addresses: addresses);
        await _configService.updatePeer(updated);
        setState(() {
          _peer = updated;
        });
      }
    }
  }

  void _removePeer() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Device'),
        content: Text('Remove "${_peer.name}" from paired devices?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _configService.removePeer(_peer.peerId);
      if (mounted) Navigator.pop(context);
    }
  }

  void _syncNow() async {
    if (_peer.addresses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No address known for this peer')),
      );
      return;
    }

    final dialog =
        _showSyncProgressDialog(context, peerName: _peer.name);

    final peerUrl = 'http://${_peer.addresses.first}';
    final syncService = MirrorSyncService.instance;
    final enabledApps = _configService.getEnabledAppsForPeer(_peer.peerId);
    var totalAdded = 0;
    var totalModified = 0;
    var totalUploaded = 0;
    var errors = 0;

    for (final appId in enabledApps) {
      final appConfig = _peer.apps[appId];
      if (appConfig == null) continue;
      final style = appConfig.style;
      if (style == SyncStyle.paused) continue;
      try {
        final result = await syncService.syncFolder(
          peerUrl,
          appId,
          peerCallsign: _peer.callsign,
          syncStyle: style,
          ignorePatterns: appConfig.ignorePatterns,
          excludeRules: _configService.config?.excludeRules ?? const [],
          onProgress: dialog.onProgress,
        );
        if (result.success) {
          totalAdded += result.filesAdded;
          totalModified += result.filesModified;
          totalUploaded += result.filesUploaded;
        } else {
          errors++;
        }
      } catch (_) {
        errors++;
      }
    }

    dialog.close();

    await _configService.markPeerSynced(_peer.peerId);

    if (mounted) {
      final parts = <String>[];
      if (totalAdded > 0) parts.add('+$totalAdded new');
      if (totalModified > 0) parts.add('~$totalModified updated');
      if (totalUploaded > 0) parts.add('↑$totalUploaded uploaded');
      final summary = parts.isEmpty ? 'No changes.' : parts.join(', ');
      final msg = errors > 0
          ? 'Sync done with $errors error(s). $summary'
          : 'Sync complete. $summary';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
  }
}
