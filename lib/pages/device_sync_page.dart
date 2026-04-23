import 'dart:async';

import 'package:flutter/material.dart';

import '../services/file_index_service.dart';
import '../services/mirror_config_service.dart';
import '../services/mirror_discovery_service.dart';
import '../services/mirror_sync_service.dart';
import '../models/mirror_config.dart';
import '../services/profile_service.dart';
import '../services/log_service.dart';
import '../services/app_service.dart';
import '../services/storage_config.dart';
import '../services/sync_transfer_service.dart';
import '../services/websocket_service.dart';
import 'device_sync_settings_page.dart';
import 'sync_exclude_rules_page.dart';

/// Multi-device sync page with three stages:
/// 1. Mirror list — discover and select a mirror device (or multi-select for push)
/// 2. App/folder diff — see what changed between devices
/// 3. Approval & transfer — select files and sync
class DeviceSyncPage extends StatefulWidget {
  const DeviceSyncPage({super.key});

  @override
  State<DeviceSyncPage> createState() => _DeviceSyncPageState();
}

class _DeviceSyncPageState extends State<DeviceSyncPage> {
  static const _excludeSnackBarDuration = Duration(seconds: 4);
  static const _excludeSnackBarBottomOffset = 96.0;

  // Stage tracking
  int _stage = 1; // 1=mirror list, 2=diff view, 3=transfer

  // Stage 1: selected mirror (single-device mode)
  MirrorDevice? _selectedMirror;
  String? _peerUrl;

  // Stage 1: multi-device push mode
  bool _multiSelectMode = false;
  final Set<String> _selectedMirrorIds = {};
  List<MirrorDevice> _multiMirrors = []; // resolved mirrors for push
  final Map<String, String> _multiPeerUrls = {}; // deviceId -> url
  final Map<String, Map<String, String>> _multiTokens =
      {}; // deviceId -> {folder -> token}
  // Which files each device needs: deviceId -> {folder -> set of paths}
  final Map<String, Map<String, Set<String>>> _multiDeviceNeeds = {};

  bool get _isMultiMode => _multiMirrors.isNotEmpty;

  // Stage 2: diff data per folder
  final Map<String, List<FileChange>> _diffs = {};
  final Map<String, String> _tokens = {}; // folder -> auth token (single mode)
  bool _loadingDiffs = false;
  String? _diffError;

  // Stage 2: expansion state
  final Set<String> _expandedFolders = {};
  // Stage 2: subfolder expansion state — key is "$appFolder|$subPath"
  final Set<String> _expandedSubtree = {};
  // Stage 2: cached diff tree per app folder; invalidated on _diffs mutation
  final Map<String, _DiffNode> _treeCache = {};

  // Stage 2: direction filter — null=show all, true=pull only, false=push only
  bool? _directionFilter;

  Timer? _excludeSnackBarTimer;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
  _excludeSnackBarController;

  // Stage 3: transfer state
  final Map<String, Set<String>> _selectedFiles =
      {}; // folder -> selected file paths
  final Map<String, bool> _fileDirections =
      {}; // "folder:path" -> true=pull, false=push
  StreamSubscription<SyncTransferProgress>? _transferSub;
  SyncTransferProgress? _transferProgress;

  // Stage 2: diff progress
  int _diffFoldersDone = 0;
  int _diffFoldersTotal = 0;
  String? _currentDiffFolder;

  // Known app folders to sync — uses shared constant from mirror_config
  static const _appFolders = kSyncableFolders;

  @override
  void initState() {
    super.initState();
    _subscribeToTransfer();
    // If a transfer is already running (or just completed), jump to stage 3
    final service = SyncTransferService.instance;
    if (service.isBusy || service.lastProgress.isComplete) {
      _stage = 3;
      _transferProgress = service.lastProgress;
    }
  }

  void _subscribeToTransfer() {
    _transferSub = SyncTransferService.instance.progressStream.listen((p) {
      if (mounted) setState(() => _transferProgress = p);
    });
  }

  @override
  void dispose() {
    _excludeSnackBarTimer?.cancel();
    _transferSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_stageTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _handleBack,
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            onSelected: (value) {
              if (value == 'excluded_files') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const SyncExcludeRulesPage(),
                  ),
                );
              } else if (value == 'mirror_config') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DeviceSyncSettingsPage(),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'mirror_config',
                child: ListTile(
                  leading: Icon(Icons.sync_alt),
                  title: Text('Mirror config'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
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
      body: _buildStage(),
    );
  }

  String get _stageTitle {
    switch (_stage) {
      case 1:
        return 'Device Sync';
      case 2:
        if (_isMultiMode) {
          return 'Push to ${_multiMirrors.length} device(s)';
        }
        return 'Changes with ${_selectedMirror?.displayName ?? "Mirror"}';
      case 3:
        return (_transferProgress?.isComplete ?? false)
            ? 'Sync complete'
            : 'Syncing...';
      default:
        return 'Device Sync';
    }
  }

  void _handleBack() {
    if (_stage == 3) {
      final p = _transferProgress;
      if (p != null && !p.isComplete) {
        // Transfer still running — let the user leave, it continues in background
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Transfer continues in background')),
        );
      }
      if (p != null && p.isComplete) {
        SyncTransferService.instance.clearLastProgress();
      }
      Navigator.of(context).pop();
      return;
    }
    if (_stage > 1) {
      setState(() {
        _stage--;
        if (_stage == 1) {
          _selectedMirror = null;
          _multiMirrors = [];
          _multiPeerUrls.clear();
          _multiTokens.clear();
          _multiDeviceNeeds.clear();
          _diffs.clear();
          _treeCache.clear();
          _expandedSubtree.clear();
          _tokens.clear();
          _diffError = null;
          _expandedFolders.clear();
          _directionFilter = null;
          _diffFoldersDone = 0;
          _diffFoldersTotal = 0;
          _currentDiffFolder = null;
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
                Text(
                  'No mirror devices found',
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                ),
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

        return Column(
          children: [
            // Mode toggle bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _multiSelectMode
                          ? 'Select devices to push to:'
                          : 'Tap a device to sync:',
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                  ),
                  TextButton.icon(
                    icon: Icon(
                      _multiSelectMode ? Icons.close : Icons.send,
                      size: 18,
                    ),
                    label: Text(_multiSelectMode ? 'Cancel' : 'Multi Push'),
                    onPressed: () {
                      setState(() {
                        _multiSelectMode = !_multiSelectMode;
                        _selectedMirrorIds.clear();
                      });
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: mirrors.length,
                itemBuilder: (context, index) {
                  final mirror = mirrors[index];
                  if (_multiSelectMode) {
                    return _buildMultiSelectMirrorCard(mirror);
                  }
                  return _buildMirrorCard(mirror);
                },
              ),
            ),
            if (_multiSelectMode && _selectedMirrorIds.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  boxShadow: const [
                    BoxShadow(color: Colors.black12, blurRadius: 4),
                  ],
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.send),
                    label: Text(
                      'Push to ${_selectedMirrorIds.length} device(s)',
                    ),
                    onPressed: () => _startMultiPush(mirrors),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Resolve the best display name for a mirror device.
  ///
  /// Checks persisted [MirrorPeer.name] when the live [MirrorDevice.displayName]
  /// falls back to the raw platform/installId string.
  String _resolveDisplayName(MirrorDevice mirror) {
    final hasLiveName =
        (mirror.nickname != null && mirror.nickname!.isNotEmpty) ||
        (mirror.deviceName != null &&
            mirror.deviceName!.isNotEmpty &&
            mirror.deviceName != mirror.callsign);
    if (hasLiveName) return mirror.displayName;

    // Fall back to the persisted peer name from a prior session.
    final peers = MirrorConfigService.instance.config?.peers ?? [];
    final peer = peers.where((p) => p.peerId == mirror.installId).firstOrNull;
    if (peer != null && peer.name.isNotEmpty && peer.name != mirror.callsign) {
      final suffix = mirror.installId != null && mirror.installId!.length >= 4
          ? ' (${mirror.installId!.substring(0, 4)})'
          : '';
      return '${peer.name}$suffix';
    }
    return mirror.displayName;
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
        title: Text(_resolveDisplayName(mirror)),
        subtitle: Row(
          children: [
            Icon(connectionIcon, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text(mirror.connectionType),
            if (mirror.verified) ...[
              const SizedBox(width: 8),
              const Icon(Icons.verified, size: 14, color: Colors.green),
              const SizedBox(width: 2),
              const Text(
                'Verified',
                style: TextStyle(color: Colors.green, fontSize: 12),
              ),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _selectMirror(mirror),
      ),
    );
  }

  Widget _buildMultiSelectMirrorCard(MirrorDevice mirror) {
    final icon = _platformIcon(mirror.platform);
    final isSelected = _selectedMirrorIds.contains(mirror.deviceId);
    final connectionIcon = mirror.connectionType == 'lan'
        ? Icons.wifi
        : Icons.cloud;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, size: 40),
        title: Text(_resolveDisplayName(mirror)),
        subtitle: Row(
          children: [
            Icon(connectionIcon, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text(mirror.connectionType),
            if (mirror.verified) ...[
              const SizedBox(width: 8),
              const Icon(Icons.verified, size: 14, color: Colors.green),
              const SizedBox(width: 2),
              const Text(
                'Verified',
                style: TextStyle(color: Colors.green, fontSize: 12),
              ),
            ],
          ],
        ),
        trailing: Checkbox(
          value: isSelected,
          onChanged: (_) {
            setState(() {
              if (isSelected) {
                _selectedMirrorIds.remove(mirror.deviceId);
              } else {
                _selectedMirrorIds.add(mirror.deviceId);
              }
            });
          },
        ),
        onTap: () {
          setState(() {
            if (isSelected) {
              _selectedMirrorIds.remove(mirror.deviceId);
            } else {
              _selectedMirrorIds.add(mirror.deviceId);
            }
          });
        },
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

  /// Resolve the HTTP URL to reach a mirror device.
  String? _resolvePeerUrl(MirrorDevice mirror) {
    var url = mirror.directAddress ?? mirror.stationRelayUrl;
    if (url == null) {
      final stationUrl = _getStationHttpUrl();
      if (stationUrl != null && mirror.deviceId.isNotEmpty) {
        url = '$stationUrl/device/${mirror.callsign}?target=${mirror.deviceId}';
      }
    }
    return url;
  }

  Future<void> _selectMirror(MirrorDevice mirror) async {
    setState(() {
      _selectedMirror = mirror;
      _loadingDiffs = true;
      _diffError = null;
      _stage = 2;
    });

    _peerUrl = _resolvePeerUrl(mirror);

    if (_peerUrl == null) {
      setState(() {
        _loadingDiffs = false;
        _diffError = 'Cannot determine peer address';
      });
      return;
    }

    await _loadDiffs();
  }

  Future<void> _startMultiPush(List<MirrorDevice> allMirrors) async {
    _multiMirrors = allMirrors
        .where((m) => _selectedMirrorIds.contains(m.deviceId))
        .toList();
    _multiPeerUrls.clear();
    _multiTokens.clear();
    _multiDeviceNeeds.clear();

    for (final mirror in _multiMirrors) {
      final url = _resolvePeerUrl(mirror);
      if (url != null) {
        _multiPeerUrls[mirror.deviceId] = url;
      }
    }

    if (_multiPeerUrls.isEmpty) {
      setState(() {
        _diffError = 'Cannot determine address for any selected device';
      });
      return;
    }

    setState(() {
      _stage = 2;
      _loadingDiffs = true;
      _diffError = null;
      _multiSelectMode = false;
    });

    await _loadMultiDiffs();
  }

  String? _getStationHttpUrl() {
    final url = WebSocketService().connectedUrl;
    if (url == null) return null;
    // Convert ws:// to http://
    return url
        .replaceFirst('ws://', 'http://')
        .replaceFirst('wss://', 'https://');
  }

  // ════════════════════════════════════════════════════════════════
  // Stage 2: App/Folder Diff View
  // ════════════════════════════════════════════════════════════════

  Future<void> _loadDiffs() async {
    final mirror = MirrorSyncService.instance;
    final storage = AppService().profileStorage;
    _diffs.clear();
    _tokens.clear();
    _treeCache.clear();
    _expandedSubtree.clear();

    final profile = ProfileService().getProfile();
    final indexPath = StorageConfig().getFileIndexPath(profile.callsign);
    final fileIndex = FileIndexService(indexPath);

    _diffFoldersTotal = _appFolders.length;
    int foldersCompared = 0;
    int foldersAuthFailed = 0;
    int foldersFetchFailed = 0;
    int foldersErrored = 0;

    for (final folder in _appFolders) {
      if (mounted) {
        setState(() {
          _currentDiffFolder = kFolderLabels[folder]?.$1 ?? folder;
          _diffFoldersDone = _appFolders.indexOf(folder) + 1;
        });
      }

      try {
        // Authenticate for this folder
        final syncResult = await mirror.requestSync(_peerUrl!, folder);
        if (!syncResult.allowed || syncResult.token == null) {
          LogService().log(
            'DeviceSync: Auth failed for $folder: ${syncResult.error}',
          );
          foldersAuthFailed++;
          continue;
        }
        _tokens[folder] = syncResult.token!;

        // Fetch remote manifest
        final manifest = await mirror.fetchManifest(
          _peerUrl!,
          folder,
          syncResult.token!,
        );
        if (manifest == null) {
          foldersFetchFailed++;
          continue;
        }

        foldersCompared++;

        // Compute diff
        final localPath = '${profile.callsign}/$folder';
        final changes = await mirror.diffManifest(
          manifest,
          localPath,
          syncStyle: SyncStyle.sendReceive,
          excludeRules:
              MirrorConfigService.instance.config?.excludeRules ?? const [],
          storage: storage,
          fileIndex: fileIndex,
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
        foldersErrored++;
      }
    }

    fileIndex.close();

    if (mounted) {
      setState(() {
        _loadingDiffs = false;
        _diffFoldersDone = _diffFoldersTotal;
        _currentDiffFolder = null;
        if (_diffs.isEmpty) {
          if (foldersCompared == 0) {
            // No folders were actually compared — report the real problem
            final issues = <String>[];
            if (foldersAuthFailed > 0) {
              issues.add('$foldersAuthFailed auth failed');
            }
            if (foldersFetchFailed > 0) {
              issues.add('$foldersFetchFailed manifest fetch failed');
            }
            if (foldersErrored > 0) issues.add('$foldersErrored errored');
            _diffError =
                'Could not compare any apps (${issues.join(', ')}). '
                'Check that the peer device is online and mirror sync is enabled on both devices.';
          } else {
            _diffError = 'Devices are in sync — no differences found.';
          }
        }
      });
    }
  }

  /// Load push-only diffs across all selected devices.
  Future<void> _loadMultiDiffs() async {
    final mirrorService = MirrorSyncService.instance;
    final storage = AppService().profileStorage;
    final profile = ProfileService().getProfile();
    final indexPath = StorageConfig().getFileIndexPath(profile.callsign);
    final fileIndex = FileIndexService(indexPath);

    _diffs.clear();
    _tokens.clear();
    _treeCache.clear();
    _expandedSubtree.clear();
    _selectedFiles.clear();
    _fileDirections.clear();
    _multiDeviceNeeds.clear();

    _diffFoldersTotal = _appFolders.length;
    int foldersCompared = 0;

    for (final folder in _appFolders) {
      if (mounted) {
        setState(() {
          _currentDiffFolder = kFolderLabels[folder]?.$1 ?? folder;
          _diffFoldersDone = _appFolders.indexOf(folder) + 1;
        });
      }

      // Collect push-able paths across all devices for this folder
      final pushEntries = <String, MirrorFileEntry>{}; // path -> local entry

      for (final entry in _multiPeerUrls.entries) {
        final deviceId = entry.key;
        final peerUrl = entry.value;

        try {
          final syncResult = await mirrorService.requestSync(peerUrl, folder);
          if (!syncResult.allowed || syncResult.token == null) continue;

          _multiTokens.putIfAbsent(deviceId, () => {})[folder] =
              syncResult.token!;

          final manifest = await mirrorService.fetchManifest(
            peerUrl,
            folder,
            syncResult.token!,
          );
          if (manifest == null) continue;

          foldersCompared++;

          final localPath = '${profile.callsign}/$folder';
          final changes = await mirrorService.diffManifest(
            manifest,
            localPath,
            syncStyle: SyncStyle.sendReceive,
            excludeRules:
                MirrorConfigService.instance.config?.excludeRules ?? const [],
            storage: storage,
            fileIndex: fileIndex,
          );

          // Only keep push-direction changes (uploads = local-only or local-newer)
          for (final change in changes) {
            if (change.type == FileChangeType.upload) {
              pushEntries.putIfAbsent(
                change.path,
                () =>
                    change.localEntry ??
                    MirrorFileEntry(
                      path: change.path,
                      sha1: '',
                      mtime: 0,
                      size: 0,
                    ),
              );
              _multiDeviceNeeds
                  .putIfAbsent(deviceId, () => {})
                  .putIfAbsent(folder, () => {})
                  .add(change.path);
            }
          }
        } catch (e) {
          LogService().log(
            'DeviceSync: Multi-diff error for $folder on $deviceId: $e',
          );
        }
      }

      // Build unified diff for this folder (push-only)
      if (pushEntries.isNotEmpty) {
        _diffs[folder] = pushEntries.entries.map((e) {
          return FileChange.upload(
            MirrorFileEntry(
              path: e.key,
              sha1: e.value.sha1,
              mtime: e.value.mtime,
              size: e.value.size,
            ),
          );
        }).toList();

        _selectedFiles[folder] = pushEntries.keys.toSet();
        for (final path in pushEntries.keys) {
          _fileDirections['$folder:$path'] = false; // push
        }
      }
    }

    fileIndex.close();

    if (mounted) {
      setState(() {
        _loadingDiffs = false;
        _diffFoldersDone = _diffFoldersTotal;
        _currentDiffFolder = null;
        if (_diffs.isEmpty) {
          _diffError = foldersCompared == 0
              ? 'Could not compare any apps. Check device connectivity.'
              : 'All devices are up to date — nothing to push.';
        }
      });
    }
  }

  Widget _buildDiffView() {
    if (_loadingDiffs) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              value: _diffFoldersTotal > 0
                  ? _diffFoldersDone / _diffFoldersTotal
                  : null,
            ),
            const SizedBox(height: 16),
            const Text('Comparing apps...'),
            if (_currentDiffFolder != null) Text(_currentDiffFolder!),
            Text('$_diffFoldersDone / $_diffFoldersTotal apps'),
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
              _diffs.isEmpty && _diffError!.contains('in sync') ||
                      _diffError!.contains('up to date')
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
        // Direction filter bar — only in single-device mode
        if (!_isMultiMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SegmentedButton<bool?>(
              segments: const [
                ButtonSegment(value: null, label: Text('All')),
                ButtonSegment(
                  value: false,
                  label: Text('Push'),
                  icon: Icon(Icons.arrow_forward, size: 16),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Pull'),
                  icon: Icon(Icons.arrow_back, size: 16),
                ),
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
        if (_isMultiMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.arrow_forward, size: 16, color: Colors.blue),
                const SizedBox(width: 8),
                Text(
                  'Push files to ${_multiMirrors.length} device(s)',
                  style: const TextStyle(
                    color: Colors.blue,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        // Select / Deselect all checkbox
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: InkWell(
            onTap: () {
              setState(() {
                if (_isAllSelected()) {
                  for (final folder in _diffs.keys) {
                    _selectedFiles[folder] = {};
                  }
                } else {
                  for (final entry in _diffs.entries) {
                    _selectedFiles[entry.key] = entry.value
                        .map((c) => c.path)
                        .toSet();
                  }
                }
              });
            },
            child: Row(
              children: [
                IgnorePointer(
                  child: Checkbox(
                    value: _isAllSelected()
                        ? true
                        : _isNoneSelected()
                        ? false
                        : null,
                    tristate: true,
                    onChanged: (_) {},
                  ),
                ),
                Text(
                  _isAllSelected()
                      ? 'Deselect all (${_totalFileCount()} files)'
                      : 'Select all (${_selectedFileCount()}/${_totalFileCount()} files)',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
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

  /// Whether every file across all folders is selected.
  bool _isAllSelected() {
    for (final entry in _diffs.entries) {
      final selected = _selectedFiles[entry.key] ?? {};
      if (selected.length != entry.value.length) return false;
    }
    return _diffs.isNotEmpty;
  }

  /// Whether no files are selected in any folder.
  bool _isNoneSelected() {
    for (final selected in _selectedFiles.values) {
      if (selected.isNotEmpty) return false;
    }
    return true;
  }

  /// Total number of selected files across all folders.
  int _selectedFileCount() {
    int count = 0;
    for (final selected in _selectedFiles.values) {
      count += selected.length;
    }
    return count;
  }

  /// Total number of files across all folders.
  int _totalFileCount() {
    int count = 0;
    for (final changes in _diffs.values) {
      count += changes.length;
    }
    return count;
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
            .where(
              (c) =>
                  c.type == FileChangeType.add ||
                  c.type == FileChangeType.modify,
            )
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() {
                      if (selected.length == changes.length) {
                        _selectedFiles[folder] = {};
                      } else {
                        _selectedFiles[folder] = changes
                            .map((c) => c.path)
                            .toSet();
                      }
                    });
                  },
                  child: IgnorePointer(
                    child: Checkbox(
                      value: selected.length == changes.length
                          ? true
                          : selected.isEmpty
                          ? false
                          : null,
                      tristate: true,
                      onChanged: (_) {},
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        if (isExpanded) {
                          _expandedFolders.remove(folder);
                        } else {
                          _expandedFolders.add(folder);
                        }
                      });
                    },
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                kFolderLabels[folder]?.$1 ?? folder,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
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
                            ],
                          ),
                        ),
                        Icon(
                          isExpanded ? Icons.expand_less : Icons.expand_more,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // File list — shown when expanded, as a folder-based tree
          if (isExpanded)
            ..._buildTreeRows(
              folder,
              (_treeCache[folder] ??= _buildDiffTree(changes)).children,
              0,
            ),
        ],
      ),
    );
  }

  /// Recursively render tree rows for the given sibling nodes at `depth`.
  List<Widget> _buildTreeRows(
    String appFolder,
    List<_DiffNode> nodes,
    int depth,
  ) {
    final rows = <Widget>[];
    for (final node in nodes) {
      if (node.isFolder) {
        rows.add(_buildFolderRow(appFolder, node, depth));
        final key = '$appFolder|${node.fullPath}';
        if (_expandedSubtree.contains(key)) {
          rows.addAll(_buildTreeRows(appFolder, node.children, depth + 1));
        }
      } else {
        rows.add(_buildFileRow(appFolder, node, depth));
      }
    }
    return rows;
  }

  Widget _buildFolderRow(String appFolder, _DiffNode node, int depth) {
    final key = '$appFolder|${node.fullPath}';
    final expanded = _expandedSubtree.contains(key);
    final tri = _subtreeSelection(appFolder, node);
    final leftPad = 8.0 + 16.0 * depth;

    return InkWell(
      onTap: () {
        setState(() {
          if (expanded) {
            _expandedSubtree.remove(key);
          } else {
            _expandedSubtree.add(key);
          }
        });
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(leftPad, 2, 8, 2),
        child: Row(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() {
                  _toggleSubtreeSelection(appFolder, node);
                });
              },
              child: IgnorePointer(
                child: Checkbox(
                  value: tri == true
                      ? true
                      : tri == false
                      ? false
                      : null,
                  tristate: true,
                  onChanged: (_) {},
                ),
              ),
            ),
            Icon(
              expanded ? Icons.folder_open : Icons.folder,
              size: 18,
              color: Colors.amber.shade700,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                node.name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (node.adds > 0) _changeChip('+${node.adds}', Colors.green),
            if (node.mods > 0) _changeChip('~${node.mods}', Colors.amber),
            if (node.dels > 0) _changeChip('-${node.dels}', Colors.red),
            if (node.ups > 0) _changeChip('^${node.ups}', Colors.blue),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileRow(String appFolder, _DiffNode node, int depth) {
    final change = node.change!;
    final selected = _selectedFiles[appFolder] ?? const <String>{};
    final isSelected = selected.contains(change.path);
    final key = '$appFolder:${change.path}';
    final isPull = _fileDirections[key] ?? true;
    final leftPad = 8.0 + 16.0 * depth;

    return InkWell(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedFiles[appFolder]?.remove(change.path);
          } else {
            _selectedFiles
                .putIfAbsent(appFolder, () => <String>{})
                .add(change.path);
          }
        });
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(leftPad, 2, 8, 2),
        child: Row(
          children: [
            IgnorePointer(
              child: Checkbox(value: isSelected, onChanged: (_) {}),
            ),
            Icon(
              Icons.insert_drive_file_outlined,
              size: 16,
              color: _changeColor(change.type),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    node.name,
                    style: TextStyle(
                      fontSize: 13,
                      color: _changeColor(change.type),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _isMultiMode
                        ? _multiPushLabel(appFolder, change.path)
                        : _changeLabel(change.type),
                    style: TextStyle(
                      fontSize: 11,
                      color: _changeColor(change.type),
                    ),
                  ),
                ],
              ),
            ),
            if (!_isMultiMode && isSelected)
              IconButton(
                icon: Icon(
                  isPull ? Icons.arrow_back : Icons.arrow_forward,
                  color: isPull ? Colors.green : Colors.blue,
                  size: 18,
                ),
                tooltip: isPull
                    ? 'Copy from remote to local'
                    : 'Copy from local to remote',
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
                onPressed: () {
                  setState(() {
                    _fileDirections[key] = !isPull;
                  });
                },
              ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 18),
              padding: EdgeInsets.zero,
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'exclude',
                  child: Text('Exclude from sync'),
                ),
              ],
              onSelected: (value) {
                if (value == 'exclude') {
                  _excludeFile(appFolder, change);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Tristate selection for the given subtree. true = all selected,
  /// false = none selected, null = partial.
  bool? _subtreeSelection(String appFolder, _DiffNode node) {
    final selected = _selectedFiles[appFolder] ?? const <String>{};
    int total = 0;
    int count = 0;
    node.collectFilePaths((path) {
      total++;
      if (selected.contains(path)) count++;
    });
    if (total == 0 || count == 0) return false;
    if (count == total) return true;
    return null;
  }

  void _toggleSubtreeSelection(String appFolder, _DiffNode node) {
    final current = _subtreeSelection(appFolder, node);
    final paths = <String>[];
    node.collectFilePaths(paths.add);
    final selSet = _selectedFiles.putIfAbsent(appFolder, () => <String>{});
    if (current == true) {
      selSet.removeAll(paths);
    } else {
      selSet.addAll(paths);
    }
  }

  /// Exclude a file from future syncs and remove it from the current diff.
  void _excludeFile(String folder, FileChange change) {
    final pattern = '$folder/${change.path}';
    final rule = SyncExcludeRule(pattern: pattern, mode: ExcludeMode.always);
    final configService = MirrorConfigService.instance;
    final rules = List<SyncExcludeRule>.from(
      configService.config?.excludeRules ?? [],
    )..add(rule);
    configService.saveExcludeRules(rules);

    // Capture for undo
    final removedChange = change;
    final wasSelected = _selectedFiles[folder]?.contains(change.path) == true;

    setState(() {
      _diffs[folder]?.removeWhere((c) => c.path == change.path);
      _selectedFiles[folder]?.remove(change.path);
      _treeCache.remove(folder);
    });

    final messenger = ScaffoldMessenger.of(context);
    _excludeSnackBarTimer?.cancel();
    messenger.removeCurrentSnackBar();
    final controller = messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          MediaQuery.paddingOf(context).bottom + _excludeSnackBarBottomOffset,
        ),
        duration: _excludeSnackBarDuration,
        content: Text('Excluded "$pattern" from sync'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            _excludeSnackBarTimer?.cancel();
            final current = List<SyncExcludeRule>.from(
              configService.config?.excludeRules ?? [],
            )..removeWhere((r) => r.pattern == pattern);
            configService.saveExcludeRules(current);
            setState(() {
              _diffs[folder] ??= [];
              _diffs[folder]!.add(removedChange);
              _treeCache.remove(folder);
              if (wasSelected) {
                _selectedFiles.putIfAbsent(folder, () => {}).add(change.path);
              }
            });
          },
        ),
      ),
    );
    _excludeSnackBarController = controller;
    controller.closed.whenComplete(() {
      if (identical(_excludeSnackBarController, controller)) {
        _excludeSnackBarController = null;
        _excludeSnackBarTimer?.cancel();
        _excludeSnackBarTimer = null;
      }
    });
    _excludeSnackBarTimer = Timer(_excludeSnackBarDuration, () {
      if (!mounted || !identical(_excludeSnackBarController, controller)) {
        return;
      }
      controller.close();
    });
  }

  /// Label showing how many devices need this file.
  String _multiPushLabel(String folder, String path) {
    int count = 0;
    for (final needs in _multiDeviceNeeds.values) {
      if (needs[folder]?.contains(path) == true) count++;
    }
    return 'Push to $count device(s)';
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
        return 'Only on remote';
      case FileChangeType.modify:
        return 'Differs between local and remote';
      case FileChangeType.delete:
        return 'Deleted on remote, still on local';
      case FileChangeType.upload:
        return 'Only on local';
    }
  }

  Widget _buildApplyBar() {
    final totalSelected = _selectedFiles.values.fold<int>(
      0,
      (sum, s) => sum + s.length,
    );
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
            icon: Icon(_isMultiMode ? Icons.send : Icons.sync),
            label: Text(_isMultiMode ? 'Push Selected' : 'Apply Selected'),
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════
  // Stage 3: Approval & Transfer
  // ════════════════════════════════════════════════════════════════

  Future<void> _confirmAndApply() async {
    final totalSelected = _selectedFiles.values.fold<int>(
      0,
      (sum, s) => sum + s.length,
    );

    if (_isMultiMode) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm Multi-Push'),
          content: Text(
            'Push $totalSelected file(s) to ${_multiMirrors.length} device(s)?\n\n'
            'Each device will receive only the files it needs.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Push'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      final request = SyncTransferRequest.multi(
        mirrors: _multiMirrors,
        peerUrls: _multiPeerUrls,
        tokens: _multiTokens,
        deviceNeeds: _multiDeviceNeeds,
        selectedFiles: _selectedFiles,
        diffs: _diffs,
      );

      final started = SyncTransferService.instance.startTransfer(request);
      if (!started) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('A sync transfer is already in progress'),
            ),
          );
        }
        return;
      }
      setState(() => _stage = 3);
    } else {
      final pullCount = _selectedFiles.entries.expand((e) {
        return e.value.where(
          (path) => _fileDirections['${e.key}:$path'] == true,
        );
      }).length;
      final pushCount = totalSelected - pullCount;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm Sync'),
          content: Text(
            'Remote → Local: $pullCount file(s)\n'
            'Local → Remote: $pushCount file(s)\n\n'
            'Proceed?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sync'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      final request = SyncTransferRequest.single(
        peerUrl: _peerUrl!,
        tokens: _tokens,
        selectedFiles: _selectedFiles,
        fileDirections: _fileDirections,
        diffs: _diffs,
      );

      final started = SyncTransferService.instance.startTransfer(request);
      if (!started) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('A sync transfer is already in progress'),
            ),
          );
        }
        return;
      }
      setState(() => _stage = 3);
    }
  }

  Widget _buildTransferView() {
    final p = _transferProgress;
    if (p == null) return const Center(child: CircularProgressIndicator());

    final progress = p.totalFiles > 0 ? p.filesTransferred / p.totalFiles : 0.0;
    final transferring = !p.isComplete;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (transferring) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                _isMultiMode
                    ? 'Pushing ${p.filesTransferred} / ${p.totalFiles}'
                    : 'Syncing ${p.filesTransferred} / ${p.totalFiles} files',
                style: const TextStyle(fontSize: 18),
              ),
              if (p.currentDevice != null) ...[
                const SizedBox(height: 8),
                Text(
                  p.currentDevice!,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              if (p.currentFile != null) ...[
                const SizedBox(height: 4),
                Text(
                  p.currentFile!,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (p.failCount > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '${p.failCount} failed',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ],
              const SizedBox(height: 24),
              LinearProgressIndicator(value: progress),
            ] else ...[
              Icon(
                p.failCount > 0 ? Icons.warning : Icons.check_circle,
                size: 64,
                color: p.failCount > 0 ? Colors.orange : Colors.green,
              ),
              const SizedBox(height: 16),
              Text(
                _isMultiMode
                    ? 'Push complete \u2014 ${p.filesTransferred} transfer(s)'
                    : 'Sync complete \u2014 ${p.filesTransferred} file(s) transferred',
                style: const TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
              if (p.failCount > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '${p.failCount} file(s) failed',
                  style: const TextStyle(fontSize: 14, color: Colors.orange),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  SyncTransferService.instance.clearLastProgress();
                  Navigator.of(context).pop();
                },
                child: const Text('Done'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Node in the per-app diff tree used by the comparison panel.
/// Folder nodes have children and aggregate change counts from descendants;
/// file nodes carry a single FileChange.
class _DiffNode {
  final String name;
  final String fullPath; // relative path within the app folder; '' for root
  final bool isFolder;
  final List<_DiffNode> children;
  final FileChange? change;
  int adds = 0;
  int mods = 0;
  int dels = 0;
  int ups = 0;

  _DiffNode._({
    required this.name,
    required this.fullPath,
    required this.isFolder,
    required this.children,
    required this.change,
  });

  factory _DiffNode.folder(String name, String fullPath) => _DiffNode._(
    name: name,
    fullPath: fullPath,
    isFolder: true,
    children: <_DiffNode>[],
    change: null,
  );

  factory _DiffNode.file(FileChange change) => _DiffNode._(
    name: change.path.split('/').last,
    fullPath: change.path,
    isFolder: false,
    children: const [],
    change: change,
  );

  void aggregate() {
    if (!isFolder) {
      switch (change!.type) {
        case FileChangeType.add:
          adds = 1;
          break;
        case FileChangeType.modify:
          mods = 1;
          break;
        case FileChangeType.delete:
          dels = 1;
          break;
        case FileChangeType.upload:
          ups = 1;
          break;
      }
      return;
    }
    for (final c in children) {
      c.aggregate();
      adds += c.adds;
      mods += c.mods;
      dels += c.dels;
      ups += c.ups;
    }
  }

  void sortRecursive() {
    if (!isFolder) return;
    children.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    for (final c in children) {
      c.sortRecursive();
    }
  }

  void collectFilePaths(void Function(String path) visit) {
    if (!isFolder) {
      visit(change!.path);
      return;
    }
    for (final c in children) {
      c.collectFilePaths(visit);
    }
  }
}

_DiffNode _buildDiffTree(List<FileChange> changes) {
  final root = _DiffNode.folder('', '');
  for (final change in changes) {
    final parts = change.path.split('/');
    _DiffNode node = root;
    final acc = <String>[];
    for (var i = 0; i < parts.length - 1; i++) {
      acc.add(parts[i]);
      final subPath = acc.join('/');
      _DiffNode? existing;
      for (final c in node.children) {
        if (c.isFolder && c.name == parts[i]) {
          existing = c;
          break;
        }
      }
      if (existing == null) {
        existing = _DiffNode.folder(parts[i], subPath);
        node.children.add(existing);
      }
      node = existing;
    }
    node.children.add(_DiffNode.file(change));
  }
  root.aggregate();
  root.sortRecursive();
  return root;
}
