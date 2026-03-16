import 'package:flutter/material.dart';

import '../services/mirror_discovery_service.dart';
import '../services/mirror_sync_service.dart';
import '../models/mirror_config.dart';
import '../services/profile_service.dart';
import '../services/log_service.dart';
import '../services/app_service.dart';
import '../services/websocket_service.dart';

/// Multi-device sync page with three stages:
/// 1. Mirror list — discover and select a mirror device
/// 2. App/folder diff — see what changed between devices
/// 3. Approval & transfer — select files and sync
class DeviceSyncPage extends StatefulWidget {
  const DeviceSyncPage({super.key});

  @override
  State<DeviceSyncPage> createState() => _DeviceSyncPageState();
}

class _DeviceSyncPageState extends State<DeviceSyncPage> {
  // Stage tracking
  int _stage = 1; // 1=mirror list, 2=diff view, 3=transfer

  // Stage 1: selected mirror
  MirrorDevice? _selectedMirror;
  String? _peerUrl;

  // Stage 2: diff data per folder
  final Map<String, List<FileChange>> _diffs = {};
  final Map<String, String> _tokens = {}; // folder -> auth token
  bool _loadingDiffs = false;
  String? _diffError;

  // Stage 2: expansion state
  final Set<String> _expandedFolders = {};

  // Stage 2: direction filter — null=show all, true=pull only, false=push only
  bool? _directionFilter;

  // Stage 3: transfer state
  final Map<String, Set<String>> _selectedFiles = {}; // folder -> selected file paths
  final Map<String, bool> _fileDirections = {}; // "folder:path" -> true=pull, false=push
  bool _transferring = false;
  int _filesTransferred = 0;
  int _totalFilesToTransfer = 0;
  String? _currentTransferFile;

  // Known app folders to sync — uses shared constant from mirror_config
  static const _appFolders = kSyncableFolders;

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
        return 'Changes with ${_selectedMirror?.displayName ?? "Mirror"}';
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
          _selectedMirror = null;
          _diffs.clear();
          _tokens.clear();
          _diffError = null;
          _expandedFolders.clear();
          _directionFilter = null;
        }
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  Widget _buildStage() {
    switch (_stage) {
      case 1:
        return _buildMirrorList();
      case 2:
        return _buildDiffView();
      case 3:
        return _buildTransferView();
      default:
        return const Center(child: Text('Unknown stage'));
    }
  }

  // ════════════════════════════════════════════════════════════════
  // Stage 1: Mirror List
  // ════════════════════════════════════════════════════════════════

  Widget _buildMirrorList() {
    return ValueListenableBuilder<List<MirrorDevice>>(
      valueListenable: MirrorDiscoveryService().mirrors,
      builder: (context, mirrors, _) {
        if (mirrors.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.devices, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text('No mirror devices found',
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
          itemCount: mirrors.length,
          itemBuilder: (context, index) {
            final mirror = mirrors[index];
            return _buildMirrorCard(mirror);
          },
        );
      },
    );
  }

  Widget _buildMirrorCard(MirrorDevice mirror) {
    final icon = _platformIcon(mirror.platform);
    final connectionIcon = mirror.connectionType == 'lan'
        ? Icons.wifi
        : Icons.cloud;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, size: 40),
        title: Text(mirror.displayName),
        subtitle: Row(
          children: [
            Icon(connectionIcon, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text(mirror.connectionType),
            if (mirror.verified) ...[
              const SizedBox(width: 8),
              const Icon(Icons.verified, size: 14, color: Colors.green),
              const SizedBox(width: 2),
              const Text('Verified', style: TextStyle(color: Colors.green, fontSize: 12)),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _selectMirror(mirror),
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

  Future<void> _selectMirror(MirrorDevice mirror) async {
    setState(() {
      _selectedMirror = mirror;
      _loadingDiffs = true;
      _diffError = null;
      _stage = 2;
    });

    // Determine peer URL (LAN direct or station relay)
    _peerUrl = mirror.directAddress ?? mirror.stationRelayUrl;
    if (_peerUrl == null) {
      // If we don't have a direct address, try the station relay via the connected station
      final stationUrl = _getStationHttpUrl();
      if (stationUrl != null && mirror.deviceId.isNotEmpty) {
        // Use station device proxy to reach the mirror.
        // Pin to the specific connection ID so challenge/response
        // hit the same physical device (not ourselves behind NAT).
        _peerUrl = '$stationUrl/device/${mirror.callsign}?target=${mirror.deviceId}';
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
        // Direction filter bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SegmentedButton<bool?>(
            segments: const [
              ButtonSegment(value: null, label: Text('All')),
              ButtonSegment(value: false, label: Text('Push'), icon: Icon(Icons.arrow_forward, size: 16)),
              ButtonSegment(value: true, label: Text('Pull'), icon: Icon(Icons.arrow_back, size: 16)),
            ],
            selected: {_directionFilter},
            onSelectionChanged: (v) {
              setState(() {
                _directionFilter = v.first;
                _applyDirectionFilter();
              });
            },
          ),
        ),
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

  /// Select/deselect files based on the direction filter.
  void _applyDirectionFilter() {
    for (final entry in _diffs.entries) {
      final folder = entry.key;
      final changes = entry.value;
      if (_directionFilter == null) {
        // All — select everything
        _selectedFiles[folder] = changes.map((c) => c.path).toSet();
      } else if (_directionFilter == false) {
        // Push only — select uploads (local-only files)
        _selectedFiles[folder] = changes
            .where((c) => c.type == FileChangeType.upload)
            .map((c) => c.path)
            .toSet();
        // Set direction to push for all
        for (final c in changes) {
          _fileDirections['$folder:${c.path}'] = false;
        }
      } else {
        // Pull only — select adds and modifies (remote files)
        _selectedFiles[folder] = changes
            .where((c) => c.type == FileChangeType.add || c.type == FileChangeType.modify)
            .map((c) => c.path)
            .toSet();
        // Set direction to pull for all
        for (final c in changes) {
          _fileDirections['$folder:${c.path}'] = true;
        }
      }
    }
  }

  Widget _buildFolderDiffCard(String folder, List<FileChange> changes) {
    final adds = changes.where((c) => c.type == FileChangeType.add).length;
    final mods = changes.where((c) => c.type == FileChangeType.modify).length;
    final dels = changes.where((c) => c.type == FileChangeType.delete).length;
    final ups = changes.where((c) => c.type == FileChangeType.upload).length;
    final selected = _selectedFiles[folder] ?? {};
    final isExpanded = _expandedFolders.contains(folder);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Folder header — checkbox is separate from the expand tap area
          InkWell(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedFolders.remove(folder);
                } else {
                  _expandedFolders.add(folder);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Checkbox(
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(folder, style: const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (adds > 0) _changeChip('+$adds', Colors.green),
                            if (mods > 0) _changeChip('~$mods', Colors.amber),
                            if (dels > 0) _changeChip('-$dels', Colors.red),
                            if (ups > 0) _changeChip('^$ups', Colors.blue),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          // File list — shown when expanded
          if (isExpanded)
            ...changes.map((change) {
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
                        tooltip: isPull ? 'Pull from mirror' : 'Push to mirror',
                        onPressed: () {
                          setState(() {
                            _fileDirections[key] = !isPull;
                          });
                        },
                      )
                    : null,
              );
            }),
        ],
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
        return 'New on mirror';
      case FileChangeType.modify:
        return 'Modified';
      case FileChangeType.delete:
        return 'Deleted on mirror';
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
          'Pull $pullCount file(s) from mirror\n'
          'Push $pushCount file(s) to mirror\n\n'
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
            // Download from mirror
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
            // Upload to mirror
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
