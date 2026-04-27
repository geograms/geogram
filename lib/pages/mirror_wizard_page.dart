/// Mirror Wizard Page.
///
/// Step-by-step wizard for adding a mirror peer device.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../connection/connection_manager.dart';
import '../models/mirror_config.dart';
import '../services/devices_service.dart';
import '../services/mirror_config_service.dart';
import '../services/app_service.dart';
import '../services/mirror_sync_service.dart';
import '../services/profile_service.dart';
import '../services/log_service.dart';

/// Wizard for pairing a new mirror device
class MirrorWizardPage extends StatefulWidget {
  const MirrorWizardPage({super.key});

  @override
  State<MirrorWizardPage> createState() => _MirrorWizardPageState();
}

class _MirrorWizardPageState extends State<MirrorWizardPage> {
  final MirrorConfigService _configService = MirrorConfigService.instance;
  final PageController _pageController = PageController();
  final TextEditingController _inviteCodeController = TextEditingController();

  int _currentStep = 0;
  _DiscoveredDevice? _selectedDevice;
  bool _inviteValidating = false;
  bool _inviteValidated = false;
  String? _inviteError;
  String? _hostCallsign;
  String? _peerUrl;
  final Map<String, bool> _selectedApps = {};
  final Map<String, SyncStyle> _appStyles = {};
  final Map<String, int> _appSizes = {};

  // Available apps to sync
  final List<_AppInfo> _availableApps = [
    _AppInfo('www', 'Website', 'Personal website', Icons.language),
    _AppInfo('blog', 'Blog', 'Articles and posts', Icons.article),
    _AppInfo('chat', 'Chat', 'Messages and conversations', Icons.chat),
    _AppInfo('email', 'Email', 'Decentralized email', Icons.email),
    _AppInfo('forum', 'Forum', 'Threaded discussions', Icons.forum),
    _AppInfo('events', 'Events', 'Calendar events', Icons.event),
    _AppInfo('alerts', 'Alerts', 'Notifications and alerts', Icons.campaign),
    _AppInfo('places', 'Places', 'Saved locations', Icons.place),
    _AppInfo('contacts', 'Contacts', 'Contact list', Icons.contacts),
    _AppInfo('groups', 'Groups', 'People groups', Icons.groups),
    _AppInfo('news', 'News', 'News and announcements', Icons.newspaper),
    _AppInfo('postcards', 'Postcards', 'Digital postcards', Icons.mail),
    _AppInfo('market', 'Market', 'Marketplace listings', Icons.store),
    _AppInfo('documents', 'Documents', 'Document files', Icons.description),
    _AppInfo('photos', 'Photos', 'Photo library', Icons.photo_library),
    _AppInfo('inventory', 'Inventory', 'Item tracking', Icons.inventory_2),
    _AppInfo(
      'wallet',
      'Wallet',
      'Debts and payments',
      Icons.account_balance_wallet,
    ),
    _AppInfo('backup', 'Backup', 'Encrypted backups', Icons.backup),
    _AppInfo(
      'tracker',
      'Tracker',
      'Health, fitness, and GPS tracks',
      Icons.track_changes,
    ),
    _AppInfo('videos', 'Videos', 'Video library', Icons.video_library),
    _AppInfo('reader', 'Reader', 'RSS feeds and e-books', Icons.menu_book),
    _AppInfo('work', 'Work', 'Workspaces and documents', Icons.work),
    _AppInfo('usenet', 'Usenet', 'Newsgroup discussions', Icons.forum),
    _AppInfo('music', 'Music', 'Music library', Icons.library_music),
    _AppInfo('stories', 'Stories', 'Visual stories', Icons.auto_stories),
    _AppInfo('qr', 'QR Codes', 'QR codes and barcodes', Icons.qr_code_2),
    _AppInfo('shared', 'Shared', 'Shared folders', Icons.folder_shared),
  ];

  @override
  void initState() {
    super.initState();
    // Select all apps by default
    for (final app in _availableApps) {
      _selectedApps[app.id] = true;
      _appStyles[app.id] = SyncStyle.sendReceive;
    }
    _computeAppSizes();
  }

  Future<void> _computeAppSizes() async {
    final storage = AppService().profileStorage;
    if (storage == null) return;

    for (final app in _availableApps) {
      if (!await storage.directoryExists(app.id)) continue;
      int size = 0;
      try {
        final entries = await storage.listDirectory(app.id, recursive: true);
        for (final entry in entries) {
          if (!entry.isDirectory && entry.size != null) {
            size += entry.size!;
          }
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _appSizes[app.id] = size;
        });
      }
    }
  }

  @override
  void dispose() {
    _inviteCodeController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Join Mirror Device'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          // Step indicator
          _buildStepIndicator(),

          // Page content
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildIntroStep(),
                _buildDiscoveryStep(),
                _buildAppsStep(),
                _buildCompleteStep(),
              ],
            ),
          ),

          // Navigation buttons
          _buildNavigationButtons(),
        ],
      ),
    );
  }

  Widget _buildStepIndicator() {
    final steps = ['Intro', 'Invite', 'Apps', 'Done'];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(steps.length, (index) {
          final isActive = index == _currentStep;
          final isCompleted = index < _currentStep;

          return Row(
            children: [
              if (index > 0)
                Container(
                  width: 24,
                  height: 2,
                  color: isCompleted
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline.withOpacity(0.3),
                ),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive || isCompleted
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline.withOpacity(0.3),
                ),
                child: Center(
                  child: isCompleted
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : Text(
                          '${index + 1}',
                          style: TextStyle(
                            color: isActive ? Colors.white : Colors.grey,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildIntroStep() {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Icon(
              Icons.sync_alt,
              size: 80,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'Mirror Your Apps',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Mirror keeps your apps synchronized between devices. One device creates a one-time invite code, and the other joins with that code.',
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          _buildFeatureRow(
            Icons.devices,
            'Multi-device sync',
            'Keep the same data on multiple devices',
          ),
          _buildFeatureRow(
            Icons.wifi,
            'Uses available transports',
            'ConnectionManager picks the reachable route',
          ),
          _buildFeatureRow(
            Icons.tune,
            'Per-app control',
            'Choose which apps to sync and how',
          ),
          _buildFeatureRow(
            Icons.offline_bolt,
            'Offline support',
            'Changes sync when devices reconnect',
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureRow(IconData icon, String title, String subtitle) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiscoveryStep() {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter Invite Code',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Use the code from the host device. The prefix is the host callsign.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _inviteCodeController,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'Invite code',
              hintText: 'X1SU86-ABCD',
              errorText: _inviteError,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_inviteValidated || _inviteError != null) {
                setState(() {
                  _inviteValidated = false;
                  _inviteError = null;
                });
              }
            },
          ),
          const SizedBox(height: 16),
          if (_inviteValidating) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
          ],
          if (_inviteValidated && _selectedDevice != null) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.verified),
                title: Text(_selectedDevice!.name),
                subtitle: Text(
                  'Callsign ${_selectedDevice!.callsign}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: _inviteValidating ? null : _validateInviteCode,
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Check invite'),
          ),
          const SizedBox(height: 16),
          Text(
            'You will be able to pick which apps sync after the code is accepted.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppsStep() {
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select Apps',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Choose which apps to synchronize and how.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            children: _availableApps
                .map((app) => _buildAppSelectTile(app))
                .toList(),
          ),
        ),
      ],
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildAppSelectTile(_AppInfo app) {
    final theme = Theme.of(context);
    final isSelected = _selectedApps[app.id] ?? false;
    final style = _appStyles[app.id] ?? SyncStyle.sendReceive;
    final sizeBytes = _appSizes[app.id];

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Checkbox(
              value: isSelected,
              onChanged: (value) {
                setState(() {
                  _selectedApps[app.id] = value ?? false;
                });
              },
            ),
            Icon(app.icon, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        app.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (sizeBytes != null && sizeBytes > 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          _formatSize(sizeBytes),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    app.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  if (isSelected)
                    DropdownButton<SyncStyle>(
                      value: style,
                      underline: const SizedBox(),
                      isDense: true,
                      items: [
                        DropdownMenuItem(
                          value: SyncStyle.sendReceive,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.sync, size: 16),
                              SizedBox(width: 4),
                              Text('Send & Receive'),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: SyncStyle.receiveOnly,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.download, size: 16),
                              SizedBox(width: 4),
                              Text('Receive Only'),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: SyncStyle.sendOnly,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.upload, size: 16),
                              SizedBox(width: 4),
                              Text('Send Only'),
                            ],
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            _appStyles[app.id] = value;
                          });
                        }
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompleteStep() {
    final theme = Theme.of(context);
    final selectedAppCount = _selectedApps.values.where((v) => v).length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Icon(Icons.check_circle, size: 80, color: Colors.green),
          const SizedBox(height: 24),
          Text(
            'Ready to Sync!',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Your device is ready to sync with:',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        child: Icon(
                          Icons.devices,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selectedDevice?.name ?? 'Device',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              _selectedDevice?.address ?? '',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Column(
                        children: [
                          Text(
                            '$selectedAppCount',
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Apps to sync',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationButtons() {
    final isFirstStep = _currentStep == 0;
    final isLastStep = _currentStep == 3;
    final canProceed = _canProceed();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          if (!isFirstStep && !isLastStep)
            TextButton(onPressed: _previousStep, child: const Text('Back')),
          const Spacer(),
          if (isLastStep)
            ElevatedButton.icon(
              onPressed: _finishWizard,
              icon: const Icon(Icons.check),
              label: const Text('Start Sync'),
            )
          else
            ElevatedButton(
              onPressed: canProceed ? _nextStep : null,
              child: const Text('Next'),
            ),
        ],
      ),
    );
  }

  bool _canProceed() {
    switch (_currentStep) {
      case 0: // Intro
        return true;
      case 1: // Invite
        return _inviteValidated;
      case 2: // Apps
        return _selectedApps.values.any((v) => v);
      default:
        return true;
    }
  }

  void _nextStep() {
    if (_currentStep < 3) {
      setState(() {
        _currentStep++;
      });
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _previousStep() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep--;
      });
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _validateInviteCode() async {
    final rawCode = _inviteCodeController.text.trim().toUpperCase();
    final parts = rawCode.split('-');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].length != 4) {
      setState(() {
        _inviteError = 'Enter a code like X1SU86-ABCD';
        _inviteValidated = false;
      });
      return;
    }

    final hostCallsign = parts[0];
    setState(() {
      _inviteValidating = true;
      _inviteError = null;
      _inviteValidated = false;
      _hostCallsign = null;
      _selectedDevice = null;
      _peerUrl = null;
    });

    try {
      DevicesService().syncDeviceToConnectionManager(hostCallsign);
      final connectionManager = ConnectionManager();
      if (!await connectionManager.isReachable(hostCallsign)) {
        throw StateError('Host device is not reachable right now');
      }

      final result = await connectionManager.apiRequest(
        callsign: hostCallsign,
        method: 'GET',
        path:
            '/api/mirror/invitations/validate?code=${Uri.encodeComponent(rawCode)}',
      );

      if (!result.success ||
          result.statusCode == null ||
          result.statusCode! >= 400) {
        throw StateError(result.error ?? 'Invite validation failed');
      }

      final payload = _decodeResponsePayload(result.responseData);
      if (payload is! Map<String, dynamic>) {
        throw StateError('Invalid validation response');
      }

      if (payload['success'] != true || payload['status'] != 'pending') {
        throw StateError(
          (payload['error'] ?? 'Invitation is unavailable').toString(),
        );
      }

      final hostName = (payload['device_name'] as String?)?.trim();
      final platform = (payload['platform'] as String?)?.trim();
      final guestUrl = DevicesService().getDevice(hostCallsign)?.url;

      setState(() {
        _inviteValidated = true;
        _inviteValidating = false;
        _hostCallsign = hostCallsign;
        _inviteError = null;
        _selectedDevice = _DiscoveredDevice(
          id: rawCode,
          name: hostName == null || hostName.isEmpty ? hostCallsign : hostName,
          address: guestUrl ?? hostCallsign,
          platform: platform == null || platform.isEmpty
              ? defaultTargetPlatform.name
              : platform,
          method: 'invite',
          npub: (payload['npub'] as String?)?.trim() ?? '',
          callsign: hostCallsign,
        );
        _peerUrl = guestUrl;
      });
    } catch (e) {
      setState(() {
        _inviteValidating = false;
        _inviteValidated = false;
        _inviteError = e.toString().replaceFirst('StateError: ', '');
      });
    }
  }

  dynamic _decodeResponsePayload(dynamic data) {
    if (data == null) return null;
    if (data is Map<String, dynamic> || data is List<dynamic>) return data;
    if (data is List<int>) {
      final body = utf8.decode(data, allowMalformed: true);
      if (body.isEmpty) return null;
      return jsonDecode(body);
    }
    if (data is String) {
      if (data.isEmpty) return null;
      return jsonDecode(data);
    }
    return data;
  }

  void _finishWizard() async {
    if (_selectedDevice == null || !_inviteValidated || _hostCallsign == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Check the invite code first')),
        );
      }
      return;
    }

    final profile = ProfileService().getProfile();
    final syncService = MirrorSyncService.instance;
    final hostCallsign = _hostCallsign!;
    final device = DevicesService().getDevice(hostCallsign);
    final peerUrl = _peerUrl ?? device?.url ?? '';

    // Build selected app list
    final selectedAppIds = _selectedApps.entries
        .where((e) => e.value)
        .map((e) => e.key)
        .toList();

    final apps = <String, AppSyncConfig>{};
    for (final appId in selectedAppIds) {
      apps[appId] = AppSyncConfig(
        appId: appId,
        style: _appStyles[appId] ?? SyncStyle.sendReceive,
        enabled: true,
      );
    }

    String remoteNpub = _selectedDevice?.npub ?? '';
    String remoteCallsign = hostCallsign;
    String remoteName = _selectedDevice?.name ?? hostCallsign;
    String? remotePlatform = _selectedDevice?.platform;

    // 1. Redeem the invite on the host device.
    try {
      final redeem = await ConnectionManager().apiRequest(
        callsign: hostCallsign,
        method: 'POST',
        path: '/api/mirror/invitations/redeem',
        body: jsonEncode({
          'code': _inviteCodeController.text.trim().toUpperCase(),
          'guest_npub': profile.npub,
          'guest_callsign': profile.callsign,
          'guest_name': _configService.config?.deviceName ?? 'My Device',
          'guest_platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
          'guest_address': null,
          'apps': selectedAppIds,
        }),
      );

      final payload = _decodeResponsePayload(redeem.responseData);
      if (payload is! Map<String, dynamic> ||
          payload['success'] != true ||
          redeem.statusCode == null ||
          redeem.statusCode! >= 400) {
        throw StateError(
          (payload is Map<String, dynamic> ? payload['error'] : null)
                  ?.toString() ??
              redeem.error ??
              'Invite redemption failed',
        );
      }

      remoteNpub = (payload['npub'] as String?)?.trim() ?? remoteNpub;
      remoteCallsign =
          (payload['host_callsign'] as String?)?.trim() ?? remoteCallsign;
      remoteName = (payload['device_name'] as String?)?.trim() ?? remoteName;
      remotePlatform =
          (payload['platform'] as String?)?.trim() ?? remotePlatform;
    } catch (e) {
      LogService().log('MirrorWizard: Invite redemption failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Invite failed: $e')));
      }
      return;
    }

    // 2. Register the remote as an allowed peer locally
    if (remoteNpub.isNotEmpty) {
      syncService.addAllowedPeer(remoteNpub, remoteCallsign);
    }

    // 3. Save MirrorPeer with remote's npub as peerId
    final peerId = remoteNpub.isNotEmpty ? remoteNpub : (const Uuid().v4());
    final peer = MirrorPeer(
      peerId: peerId,
      npub: remoteNpub,
      name: remoteName,
      callsign: remoteCallsign,
      addresses: peerUrl.isNotEmpty ? [peerUrl] : const [],
      apps: apps,
      platform: remotePlatform,
    );

    await _configService.addPeer(peer);

    if (!_configService.isEnabled) {
      await _configService.setEnabled(true);
    }

    // 4. Initial sync — push local data to the new peer when we know a route.
    var didInitialSync = false;
    if (peerUrl.isNotEmpty) {
      for (final appId in selectedAppIds) {
        final style = _appStyles[appId] ?? SyncStyle.sendReceive;
        if (style != SyncStyle.paused) {
          try {
            final appConfig = apps[appId];
            await syncService.syncFolder(
              peerUrl,
              appId,
              peerCallsign: remoteCallsign,
              syncStyle: style,
              ignorePatterns: appConfig?.ignorePatterns ?? const [],
            );
            didInitialSync = true;
          } catch (e) {
            LogService().log(
              'MirrorWizard: Initial sync failed for $appId: $e',
            );
          }
        }
      }
    }
    if (didInitialSync) {
      await _configService.markPeerSynced(peerId);
    }

    if (mounted) {
      Navigator.pop(context);
    }
  }
}

/// Internal class for discovered devices during wizard
class _DiscoveredDevice {
  final String id;
  final String name;
  final String address;
  final String platform;
  final String method; // lan, ble, manual
  final int? latencyMs;
  final String npub;
  final String callsign;
  final bool mirrorSetupOpen;

  _DiscoveredDevice({
    required this.id,
    required this.name,
    required this.address,
    required this.platform,
    required this.method,
    this.latencyMs,
    this.npub = '',
    this.callsign = '',
    this.mirrorSetupOpen = false,
  });
}

/// Internal class for app info
class _AppInfo {
  final String id;
  final String name;
  final String description;
  final IconData icon;

  _AppInfo(this.id, this.name, this.description, this.icon);
}
