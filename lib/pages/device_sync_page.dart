import 'package:flutter/material.dart';

import '../services/sibling_discovery_service.dart';
import '../services/mirror_sync_service.dart';
import '../models/mirror_config.dart';
import '../services/profile_service.dart';
import '../services/log_service.dart';
import '../services/app_service.dart';
import '../services/websocket_service.dart';

/// Multi-device sync page with three stages:
/// 1. Sibling list — discover and select a sibling device
/// 2. App/folder diff — see what changed between devices
/// 3. Approval & transfer — select files and sync
class DeviceSyncPage extends StatefulWidget {
  const DeviceSyncPage({super.key});

  @override
  State<DeviceSyncPage> createState() => _DeviceSyncPageState();
}

class _DeviceSyncPageState extends State<DeviceSyncPage> {
  // Stage tracking
  int _stage = 1; // 1=sibling list, 2=diff view, 3=transfer

  // Stage 1: selected sibling
  SiblingDevice? _selectedSibling;
  String? _peerUrl;

  // Stage 2: diff data per folder
  final Map<String, List<FileChange>> _diffs = {};
  final Map<String, String> _tokens = {}; // folder -> auth token
  bool _loadingDiffs = false;
  String? _diffError;

  // Stage 3: transfer state
  final Map<String, Set<String>> _selectedFiles = {}; // folder -> selected file paths
  final Map<String, bool> _fileDirections = {}; // "folder:path" -> true=pull, false=push
  bool _transferring = false;
  int _filesTransferred = 0;
  int _totalFilesToTransfer = 0;
  String? _currentTransferFile;

  // Known app folders to sync
  static const _appFolders = [
    'blog',
    'places',
    'events',
    'alerts',
    'contacts',
    'groups',
    'inventory',
    'market',
    'postcards',
    'news',
    'files',
    'qr',
    'reports',
    'stories',
    'wallet',
    'tracker',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_stageTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _handleBack,
        ),
      ),
      body: _buildStage(),
    );
  }

  String get _stageTitle {
    switch (_stage) {
      case 1:
        return 'Device Sync';
      case 2:
        return 'Changes with ${_selectedSibling?.platform ?? "Sibling"}';
      case 3:
        return 'Syncing...';
      default:
        return 'Device Sync';
    }
  }

  void _handleBack() {
    if (_transferring) return; // Don't go back during transfer
    if (_stage > 1) {
      setState(() {
        _stage--;
        if (_stage == 1) {
          _selectedSibling = null;
          _diffs.clear();
          _tokens.clear();
          _diffError = null;
        }
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  Widget _buildStage() {
    switch (_stage) {
      case 1:
        return _buildSiblingList();
      case 2:
        return _buildDiffView();
      case 3:
        return _buildTransferView();
      default:
        return const Center(child: Text('Unknown stage'));
    }
  }

  // ════════════════════════════════════════════════════════════════
  // Stage 1: Sibling List
  // ════════════════════════════════════════════════════════════════

  Widget _buildSiblingList() {
    return ValueListenableBuilder<List<SiblingDevice>>(
      valueListenable: SiblingDiscoveryService().siblings,
      builder: (context, siblings, _) {
        if (siblings.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.devices, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text('No sibling devices found',
                    style: TextStyle(fontSize: 18, color: Colors.grey)),
                SizedBox(height: 8),
                Text(
                  'Connect another device with the same identity\nto the same station to sync.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: siblings.length,
          itemBuilder: (context, index) {
            final sibling = siblings[index];
            return _buildSiblingCard(sibling);
          },
        );
      },
    );
  }

  Widget _buildSiblingCard(SiblingDevice sibling) {
    final icon = _platformIcon(sibling.platform);
    final connectionIcon = sibling.connectionType == 'lan'
        ? Icons.wifi
        : Icons.cloud;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, size: 40),
        title: Text(sibling.platform),
        subtitle: Row(
          children: [
            Icon(connectionIcon, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text(sibling.connectionType),
            if (sibling.verified) ...[
              const SizedBox(width: 8),
              const Icon(Icons.verified, size: 14, color: Colors.green),
              const SizedBox(width: 2),
              const Text('Verified', style: TextStyle(color: Colors.green, fontSize: 12)),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _selectSibling(sibling),
      ),
    );
  }

  IconData _platformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'linux':
      case 'macos':
      case 'windows':
        return Icons.computer;
      case 'web':
        return Icons.language;
      default:
        return Icons.devices;
    }
  }

  Future<void> _selectSibling(SiblingDevice sibling) async {
    setState(() {
      _selectedSibling = sibling;
      _loadingDiffs = true;
      _diffError = null;
      _stage = 2;
    });

    // Determine peer URL (LAN direct or station relay)
    _peerUrl = sibling.directAddress ?? sibling.stationRelayUrl;
    if (_peerUrl == null) {
      // If we don't have a direct address, try the station relay via the connected station
      final stationUrl = _getStationHttpUrl();
      if (stationUrl != null && sibling.deviceId.isNotEmpty) {
        // Use station device proxy to reach the sibling.
        // Pin to the specific connection ID so challenge/response
        // hit the same physical device (not ourselves behind NAT).
        _peerUrl = '$stationUrl/device/${sibling.callsign}?target=${sibling.deviceId}';
      }
    }

    if (_peerUrl == null) {
      setState(() {
        _loadingDiffs = false;
        _diffError = 'Cannot determine peer address';
      });
      return;
    }

    await _loadDiffs();
  }

  String? _getStationHttpUrl() {
    final url = WebSocketService().connectedUrl;
    if (url == null) return null;
    // Convert ws:// to http://
    return url.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
  }

  // ════════════════════════════════════════════════════════════════
  // Stage 2: App/Folder Diff View
  // ════════════════════════════════════════════════════════════════

  Future<void> _loadDiffs() async {
    final mirror = MirrorSyncService.instance;
    final storage = AppService().profileStorage;
    _diffs.clear();
    _tokens.clear();

    for (final folder in _appFolders) {
      try {
        // Authenticate for this folder
        final syncResult = await mirror.requestSync(_peerUrl!, folder);
        if (!syncResult.allowed || syncResult.token == null) {
          LogService().log('DeviceSync: Auth failed for $folder: ${syncResult.error}');
          continue;
        }
        _tokens[folder] = syncResult.token!;

        // Fetch remote manifest
        final manifest = await mirror.fetchManifest(
          _peerUrl!,
          folder,
          syncResult.token!,
        );
        if (manifest == null) continue;

        // Compute diff
        final profile = ProfileService().getProfile();
        final localPath = '${profile.callsign}/$folder';
        final changes = await mirror.diffManifest(
          manifest,
          localPath,
          syncStyle: SyncStyle.sendReceive,
          storage: storage,
        );

        if (changes.isNotEmpty) {
          _diffs[folder] = changes;
          // Pre-select all files and default directions
          _selectedFiles[folder] = changes.map((c) => c.path).toSet();
          for (final change in changes) {
            final key = '$folder:${change.path}';
            // Default: pull adds/modifies, push uploads
            _fileDirections[key] = change.type != FileChangeType.upload;
          }
        }
      } catch (e) {
        LogService().log('DeviceSync: Error loading diff for $folder: $e');
      }
    }

    if (mounted) {
      setState(() {
        _loadingDiffs = false;
        if (_diffs.isEmpty) {
          _diffError = 'Devices are in sync — no differences found.';
        }
      });
    }
  }

  Widget _buildDiffView() {
    if (_loadingDiffs) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Comparing files...'),
          ],
        ),
      );
    }

    if (_diffError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _diffs.isEmpty && _diffError!.contains('in sync')
                  ? Icons.check_circle
                  : Icons.info_outline,
              size: 64,
              color: _diffs.isEmpty ? Colors.green : Colors.orange,
            ),
            const SizedBox(height: 16),
            Text(_diffError!, textAlign: TextAlign.center),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: _diffs.entries.map((entry) {
              return _buildFolderDiffCard(entry.key, entry.value);
            }).toList(),
          ),
        ),
        _buildApplyBar(),
      ],
    );
  }

  Widget _buildFolderDiffCard(String folder, List<FileChange> changes) {
    final adds = changes.where((c) => c.type == FileChangeType.add).length;
    final mods = changes.where((c) => c.type == FileChangeType.modify).length;
    final dels = changes.where((c) => c.type == FileChangeType.delete).length;
    final ups = changes.where((c) => c.type == FileChangeType.upload).length;
    final selected = _selectedFiles[folder] ?? {};

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: Checkbox(
          value: selected.length == changes.length
              ? true
              : selected.isEmpty
                  ? false
                  : null,
          tristate: true,
          onChanged: (value) {
            setState(() {
              if (value == true || value == null) {
                _selectedFiles[folder] = changes.map((c) => c.path).toSet();
              } else {
                _selectedFiles[folder] = {};
              }
            });
          },
        ),
        title: Text(folder, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Row(
          children: [
            if (adds > 0)
              _changeChip('+$adds', Colors.green),
            if (mods > 0)
              _changeChip('~$mods', Colors.amber),
            if (dels > 0)
              _changeChip('-$dels', Colors.red),
            if (ups > 0)
              _changeChip('^$ups', Colors.blue),
          ],
        ),
        children: changes.map((change) {
          final key = '$folder:${change.path}';
          final isSelected = selected.contains(change.path);
          final isPull = _fileDirections[key] ?? true;

          return ListTile(
            dense: true,
            leading: Checkbox(
              value: isSelected,
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selectedFiles.putIfAbsent(folder, () => {}).add(change.path);
                  } else {
                    _selectedFiles[folder]?.remove(change.path);
                  }
                });
              },
            ),
            title: Text(
              change.path,
              style: TextStyle(
                fontSize: 13,
                color: _changeColor(change.type),
              ),
            ),
            subtitle: Text(
              _changeLabel(change.type),
              style: TextStyle(fontSize: 11, color: _changeColor(change.type)),
            ),
            trailing: isSelected
                ? IconButton(
                    icon: Icon(
                      isPull ? Icons.arrow_back : Icons.arrow_forward,
                      color: isPull ? Colors.green : Colors.blue,
                    ),
                    tooltip: isPull ? 'Pull from sibling' : 'Push to sibling',
                    onPressed: () {
                      setState(() {
                        _fileDirections[key] = !isPull;
                      });
                    },
                  )
                : null,
          );
        }).toList(),
      ),
    );
  }

  Widget _changeChip(String label, Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Chip(
        label: Text(label, style: TextStyle(color: color, fontSize: 11)),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: BorderSide(color: color.withAlpha(80)),
      ),
    );
  }

  Color _changeColor(FileChangeType type) {
    switch (type) {
      case FileChangeType.add:
        return Colors.green;
      case FileChangeType.modify:
        return Colors.amber.shade700;
      case FileChangeType.delete:
        return Colors.red;
      case FileChangeType.upload:
        return Colors.blue;
    }
  }

  String _changeLabel(FileChangeType type) {
    switch (type) {
      case FileChangeType.add:
        return 'New on sibling';
      case FileChangeType.modify:
        return 'Modified';
      case FileChangeType.delete:
        return 'Deleted on sibling';
      case FileChangeType.upload:
        return 'New locally';
    }
  }

  Widget _buildApplyBar() {
    final totalSelected = _selectedFiles.values.fold<int>(0, (sum, s) => sum + s.length);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Row(
        children: [
          Text('$totalSelected file(s) selected'),
          const Spacer(),
          FilledButton.icon(
            onPressed: totalSelected > 0 ? _confirmAndApply : null,
            icon: const Icon(Icons.sync),
            label: const Text('Apply Selected'),
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════
  // Stage 3: Approval & Transfer
  // ════════════════════════════════════════════════════════════════

  Future<void> _confirmAndApply() async {
    final totalSelected = _selectedFiles.values.fold<int>(0, (sum, s) => sum + s.length);
    final pullCount = _selectedFiles.entries.expand((e) {
      return e.value.where((path) => _fileDirections['${e.key}:$path'] == true);
    }).length;
    final pushCount = totalSelected - pullCount;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Sync'),
        content: Text(
          'Pull $pullCount file(s) from sibling\n'
          'Push $pushCount file(s) to sibling\n\n'
          'Proceed?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sync')),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _stage = 3;
      _transferring = true;
      _filesTransferred = 0;
      _totalFilesToTransfer = totalSelected;
    });

    await _executeTransfer();
  }

  Future<void> _executeTransfer() async {
    final mirror = MirrorSyncService.instance;
    final storage = AppService().profileStorage;
    final profile = ProfileService().getProfile();

    for (final entry in _selectedFiles.entries) {
      final folder = entry.key;
      final files = entry.value;
      final token = _tokens[folder];
      if (token == null) continue;

      for (final filePath in files) {
        final key = '$folder:$filePath';
        final isPull = _fileDirections[key] ?? true;
        final localPath = '${profile.callsign}/$folder';

        setState(() {
          _currentTransferFile = '$folder/$filePath';
        });

        try {
          if (isPull) {
            // Download from sibling
            final change = _diffs[folder]?.firstWhere((c) => c.path == filePath);
            await mirror.downloadFile(
              _peerUrl!,
              folder,
              filePath,
              localPath,
              token,
              expectedSha1: change?.remoteEntry?.sha1,
              storage: storage,
            );
          } else {
            // Upload to sibling
            final change = _diffs[folder]?.firstWhere((c) => c.path == filePath);
            await mirror.uploadFile(
              _peerUrl!,
              folder,
              filePath,
              localPath,
              token,
              sha1Hash: change?.localEntry?.sha1,
              storage: storage,
            );
          }
        } catch (e) {
          LogService().log('DeviceSync: Transfer failed for $filePath: $e');
        }

        setState(() {
          _filesTransferred++;
        });
      }
    }

    setState(() {
      _transferring = false;
      _currentTransferFile = null;
    });
  }

  Widget _buildTransferView() {
    final progress = _totalFilesToTransfer > 0
        ? _filesTransferred / _totalFilesToTransfer
        : 0.0;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_transferring) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                'Syncing $_filesTransferred / $_totalFilesToTransfer files',
                style: const TextStyle(fontSize: 18),
              ),
              if (_currentTransferFile != null) ...[
                const SizedBox(height: 8),
                Text(
                  _currentTransferFile!,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 24),
              LinearProgressIndicator(value: progress),
            ] else ...[
              const Icon(Icons.check_circle, size: 64, color: Colors.green),
              const SizedBox(height: 16),
              Text(
                'Sync complete — $_filesTransferred file(s) transferred',
                style: const TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
