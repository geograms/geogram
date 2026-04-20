/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' show Platform;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_storage/shared_storage.dart' as saf;
import '../models/local_backup_models.dart';
import '../services/backup_service.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/backup_store.dart';
import '../services/local_backup_service.dart';
import '../models/backup_models.dart';

/// Backup management page with wizard-style role selection.
/// Users can choose to be a Backup User (client) or Backup Provider (host).
class BackupBrowserPage extends StatefulWidget {
  const BackupBrowserPage({super.key});

  @override
  State<BackupBrowserPage> createState() => _BackupBrowserPageState();
}

class _BackupBrowserPageState extends State<BackupBrowserPage> {
  final BackupService _backupService = BackupService();
  final DevicesService _devicesService = DevicesService();
  final LocalBackupService _localBackupService = LocalBackupService();
  final I18nService _i18n = I18nService();

  // Current view state
  _BackupViewState _viewState = _BackupViewState.roleSelection;

  // Provider state
  BackupProviderSettings? _providerSettings;
  List<BackupClientRelationship> _clients = [];

  // Client state
  List<BackupProviderRelationship> _providers = [];
  BackupStatus? _backupStatus;
  BackupStatus? _restoreStatus;

  // Loading state
  bool _isLoading = true;
  bool _isProviderDiscoveryLoading = false;

  // Available providers
  List<AvailableBackupProvider> _lanProviders = [];
  List<AvailableBackupProvider> _stationProviders = [];

  // Local backup state
  List<LocalBackupSnapshot> _localSnapshots = [];
  LocalBackupStatus _localBackupStatus = LocalBackupStatus.idle();

  // Stream subscriptions
  StreamSubscription<BackupStatus>? _statusSubscription;
  StreamSubscription<List<BackupProviderRelationship>>? _providersSubscription;
  StreamSubscription<List<BackupClientRelationship>>? _clientsSubscription;

  @override
  void initState() {
    super.initState();
    _loadData();
    _setupSubscriptions();
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _providersSubscription?.cancel();
    _clientsSubscription?.cancel();
    super.dispose();
  }

  void _setupSubscriptions() {
    _statusSubscription = _backupService.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _backupStatus = _backupService.backupStatus;
          _restoreStatus = _backupService.restoreStatus;
        });
      }
    });

    _providersSubscription = _backupService.providersStream.listen((providers) {
      if (mounted) {
        setState(() => _providers = _dedupeProviderRelationships(providers));
      }
    });

    _clientsSubscription = _backupService.clientsStream.listen((clients) {
      if (mounted) {
        setState(() => _clients = _dedupeClients(clients));
      }
    });
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      // Ensure service is initialized
      await _backupService.initialize();

      // Load provider settings (sync getters)
      _providerSettings = _backupService.providerSettings;
      _clients = _dedupeClients(_backupService.getClients());

      // Load client state (sync getters)
      _providers = _dedupeProviderRelationships(_backupService.getProviders());
      _backupStatus = _backupService.backupStatus;
      _restoreStatus = _backupService.restoreStatus;

      // Determine initial view state based on existing configuration
      _determineViewState();
    } catch (e) {
      // Handle error
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _enterProviderSelection() {
    setState(() => _viewState = _BackupViewState.selectProvider);
    _refreshAvailableProviders();
  }

  Future<void> _refreshAvailableProviders() async {
    setState(() => _isProviderDiscoveryLoading = true);
    try {
      final result = await _backupService.getAvailableProviders();
      if (!mounted) return;
      setState(() {
        _lanProviders = _dedupeAvailableProviders(result.lanProviders);
        _stationProviders = _dedupeAvailableProviders(result.stationProviders);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _lanProviders = [];
          _stationProviders = [];
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isProviderDiscoveryLoading = false);
      }
    }
  }

  void _determineViewState() {
    // If provider mode is enabled, show provider view
    if (_providerSettings?.enabled == true) {
      _viewState = _BackupViewState.providerDashboard;
    }
    // If has providers configured, show client view
    else if (_providers.isNotEmpty) {
      _viewState = _BackupViewState.clientDashboard;
    }
    // Otherwise show role selection wizard
    else {
      _viewState = _BackupViewState.roleSelection;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: true,
        title: Text(_i18n.t('backup_app')),
        actions: [
          if (_viewState != _BackupViewState.roleSelection)
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _showSettingsMenu,
              tooltip: _i18n.t('settings'),
            ),
        ],
      ),
      body: SafeArea(
        child: _isLoading ? const Center(child: CircularProgressIndicator()) : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    switch (_viewState) {
      case _BackupViewState.roleSelection:
        return _buildRoleSelectionWizard();
      case _BackupViewState.clientDashboard:
        return _buildClientDashboard();
      case _BackupViewState.providerDashboard:
        return _buildProviderDashboard();
      case _BackupViewState.selectProvider:
        return _buildProviderSelectionPage();
      case _BackupViewState.localBackupDashboard:
        return _buildLocalBackupDashboard();
    }
  }

  // ============================================================
  // ROLE SELECTION WIZARD
  // ============================================================

  Widget _buildRoleSelectionWizard() {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.backup,
                size: 80,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                _i18n.t('backup_setup_title'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                _i18n.t('backup_setup_description'),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),

              // Backup User option
              _buildRoleCard(
                icon: Icons.cloud_upload,
                title: _i18n.t('backup_role_user'),
                description: _i18n.t('backup_role_user_description'),
                onTap: _enterProviderSelection,
              ),

              const SizedBox(height: 16),

              // Backup Provider option
              _buildRoleCard(
                icon: Icons.cloud_download,
                title: _i18n.t('backup_role_provider'),
                description: _i18n.t('backup_role_provider_description'),
                onTap: _enableProviderMode,
              ),

              const SizedBox(height: 16),

              // Local Backup option
              _buildRoleCard(
                icon: Icons.phone_android,
                title: _i18n.t('backup_local'),
                description: _i18n.t('backup_local_description'),
                onTap: _enterLocalBackup,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoleCard({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: 32,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // PROVIDER SELECTION
  // ============================================================

  Widget _buildProviderSelectionPage() {
    final theme = Theme.of(context);
    final hasResults = _lanProviders.isNotEmpty || _stationProviders.isNotEmpty;
    final children = <Widget>[];

    if (!hasResults) {
      children.add(_buildNoProvidersState(theme));
    } else {
      if (_lanProviders.isNotEmpty) {
        children.add(_buildProviderSection(
          theme,
          _i18n.t('backup_nearby_lan'),
          _lanProviders,
        ));
      }
      if (_stationProviders.isNotEmpty) {
        children.add(_buildProviderSection(
          theme,
          _i18n.t('backup_station_directory'),
          _stationProviders,
        ));
      }
    }
    if (_isProviderDiscoveryLoading && hasResults) {
      children.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      ));
    }

    return Column(
      children: [
        // Header with back button
        Container(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _viewState = _BackupViewState.roleSelection),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _i18n.t('backup_select_provider'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _i18n.t('backup_select_provider_hint'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _isProviderDiscoveryLoading ? null : _refreshAvailableProviders,
                tooltip: _i18n.t('refresh'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Provider list
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refreshAvailableProviders,
            child: _isProviderDiscoveryLoading && !hasResults
                ? ListView(
                    children: const [
                      SizedBox(height: 160),
                      Center(child: CircularProgressIndicator()),
                    ],
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: children,
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildNoProvidersState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('backup_no_providers'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _i18n.t('backup_no_providers_hint'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProviderSection(
    ThemeData theme,
    String title,
    List<AvailableBackupProvider> providers,
  ) {
    final uniqueProviders = _dedupeAvailableProviders(providers);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
          child: Row(
            children: [
              Icon(
                Icons.storage,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        ...uniqueProviders.map((provider) => _buildAvailableProviderTile(theme, provider)),
      ],
    );
  }

  Widget _buildAvailableProviderTile(
    ThemeData theme,
    AvailableBackupProvider provider,
  ) {
    final existingProvider = _providers.firstWhere(
      (p) => p.providerCallsign.toUpperCase() == provider.callsign.toUpperCase(),
      orElse: () => BackupProviderRelationship(
        providerNpub: provider.npub,
        providerCallsign: provider.callsign,
        backupIntervalDays: 1,
        status: BackupRelationshipStatus.pending,
        createdAt: DateTime.now(),
      ),
    );
    final isExisting = _providers.any(
      (p) => p.providerCallsign.toUpperCase() == provider.callsign.toUpperCase(),
    );
    final connectionLabel = provider.connectionMethod == 'lan' ? 'LAN' : 'Station';
    final displayName = _getProviderDisplayName(provider);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: Icon(
          _getProviderIcon(provider),
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      title: Row(
        children: [
          Expanded(child: Text(displayName)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              connectionLabel,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
        ],
      ),
      subtitle: Text(
        provider.callsign,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: isExisting
          ? _buildStatusChip(theme, existingProvider.status)
          : FilledButton.tonal(
              onPressed: () => _requestBackupProviderCallsign(provider.callsign),
              child: Text(_i18n.t('backup_request')),
            ),
      onTap: isExisting ? null : () => _requestBackupProviderCallsign(provider.callsign),
    );
  }

  IconData _getProviderIcon(AvailableBackupProvider provider) {
    if (provider.connectionMethod == 'lan') {
      return Icons.wifi;
    }
    return Icons.cloud;
  }

  String _getProviderDisplayName(AvailableBackupProvider provider) {
    final device = _devicesService.getDevice(provider.callsign);
    return device?.displayName ?? provider.callsign;
  }

  Future<void> _requestBackupProviderCallsign(String callsign) async {
    try {
      await _backupService.sendInvite(callsign, 1); // Default 1 day interval
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('backup_request_sent'))),
        );
        setState(() => _viewState = _BackupViewState.clientDashboard);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  // ============================================================
  // CLIENT DASHBOARD
  // ============================================================

  Widget _buildClientDashboard() {
    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Backup status card
          if (_backupStatus != null && _backupStatus!.status != 'idle')
            _buildBackupProgressCard(theme),
          if (_restoreStatus != null && _restoreStatus!.status != 'idle')
            _buildRestoreProgressCard(theme),

          // Providers section
          Text(
            _i18n.t('backup_providers'),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          if (_providers.isEmpty)
            _buildEmptyProvidersCard(theme)
          else
            ..._providers.map((provider) => _buildProviderCard(theme, provider)),

          const SizedBox(height: 24),

          // Add provider button
          OutlinedButton.icon(
            onPressed: _enterProviderSelection,
            icon: const Icon(Icons.add),
            label: Text(_i18n.t('backup_add_provider')),
          ),
        ],
      ),
    );
  }

  Widget _buildBackupProgressCard(ThemeData theme) {
    final status = _backupStatus!;
    final isBackingUp = status.status == 'in_progress';

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isBackingUp ? Icons.cloud_upload : Icons.cloud_done,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isBackingUp
                        ? _i18n.t('backup_in_progress')
                        : _i18n.t('backup_complete'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (isBackingUp) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: status.progressPercent / 100),
              const SizedBox(height: 8),
              Text(
                '${status.filesTransferred}/${status.filesTotal} ${_i18n.t('files')} - ${status.progressPercent}%',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRestoreProgressCard(ThemeData theme) {
    final status = _restoreStatus!;
    final isRestoring = status.status == 'in_progress';

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.restore,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isRestoring
                        ? _i18n.t('backup_restoring')
                        : _i18n.t('backup_restore_complete'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (isRestoring) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: status.progressPercent / 100),
              const SizedBox(height: 8),
              Text(
                '${status.filesTransferred}/${status.filesTotal} ${_i18n.t('files')} - ${status.progressPercent}%',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyProvidersCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('backup_no_providers'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _i18n.t('backup_no_providers_hint'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProviderCard(ThemeData theme, BackupProviderRelationship provider) {
    final isActive = provider.status == BackupRelationshipStatus.active;
    final storageQuota = provider.maxStorageBytes;
    final usedBytes = provider.currentStorageBytes;
    final hasQuota = storageQuota > 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: isActive ? Colors.green.withOpacity(0.1) : theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.cloud,
                    color: isActive ? Colors.green : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        provider.providerCallsign,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        _i18n.t('backup_status_${provider.status.name}'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _getStatusColor(provider.status),
                        ),
                      ),
                      if (hasQuota) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${_formatBytes(usedBytes)} / ${_formatBytes(storageQuota)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Text(
                          '${_i18n.t('backup_storage_remaining')}: ${_formatBytes((storageQuota - usedBytes).clamp(0, storageQuota))}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (provider.maxSnapshots > 0)
                          Text(
                            '${_i18n.t('backup_max_snapshots')}: ${provider.maxSnapshots}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                _buildStatusChip(theme, provider.status),
              ],
            ),
            if (isActive && provider.lastSuccessfulBackup != null) ...[
              const SizedBox(height: 12),
              Text(
                '${_i18n.t('backup_last_backup')}: ${_formatDate(provider.lastSuccessfulBackup!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (isActive)
                  OutlinedButton.icon(
                    onPressed: () => _showSnapshotHistory(provider, allowRestore: true, allowBackup: false),
                    icon: const Icon(Icons.restore, size: 18),
                    label: Text(_i18n.t('backup_restore')),
                  ),
                if (isActive)
                  OutlinedButton.icon(
                    onPressed: () => _showSnapshotHistory(provider, allowRestore: true),
                    icon: const Icon(Icons.history, size: 18),
                    label: Text(_i18n.t('backup_view_snapshots')),
                  ),
                if (isActive)
                  FilledButton.icon(
                    onPressed: () => _showSnapshotHistory(provider, allowRestore: false),
                    icon: const Icon(Icons.backup, size: 18),
                    label: Text(_i18n.t('backup_now')),
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _removeProvider(provider),
                  color: theme.colorScheme.error,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // PROVIDER DASHBOARD
  // ============================================================

  Widget _buildProviderDashboard() {
    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Provider status card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.cloud_done, color: Colors.green, size: 32),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _i18n.t('backup_provider_enabled'),
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          _i18n.t('backup_provider_accepting'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _providerSettings?.enabled ?? false,
                    onChanged: (value) => _toggleProviderMode(value),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Clients section
          Text(
            _i18n.t('backup_clients'),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          if (_clients.isEmpty)
            _buildNoClientsCard(theme)
          else
            ..._clients.map((client) => _buildClientCard(theme, client)),
        ],
      ),
    );
  }

  Widget _buildNoClientsCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              Icons.people_outline,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('backup_no_clients'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _i18n.t('backup_no_clients_hint'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClientCard(ThemeData theme, BackupClientRelationship client) {
    final isPending = client.status == BackupRelationshipStatus.pending;
    final isActive = client.status == BackupRelationshipStatus.active;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: isActive ? Colors.green.withOpacity(0.1) : theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.person,
                    color: isActive ? Colors.green : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        client.clientCallsign,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        isPending
                            ? _i18n.t('backup_pending_request')
                            : '${_formatBytes(client.currentStorageBytes)} / ${_formatBytes(client.maxStorageBytes)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isPending ? Colors.orange : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildStatusChip(theme, client.status),
              ],
            ),
            if (isPending) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => _declineClient(client),
                    child: Text(_i18n.t('decline')),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () => _acceptClient(client),
                    child: Text(_i18n.t('accept')),
                  ),
                ],
              ),
            ] else ...[
              if (client.lastBackupAt != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${_i18n.t('backup_last_backup')}: ${_formatDate(client.lastBackupAt!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _removeClient(client),
                    color: theme.colorScheme.error,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ============================================================
  // ACTIONS
  // ============================================================

  Future<void> _enableProviderMode() async {
    try {
      await _backupService.enableProviderMode(
        maxTotalStorageBytes: 10 * 1024 * 1024 * 1024, // 10 GB default
        defaultMaxClientStorageBytes: 1024 * 1024 * 1024, // 1 GB per client
        defaultMaxSnapshots: 10,
      );
      await _loadData();
      if (mounted) {
        setState(() => _viewState = _BackupViewState.providerDashboard);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _toggleProviderMode(bool enabled) async {
    try {
      if (enabled) {
        await _backupService.enableProviderMode(
          maxTotalStorageBytes: 10 * 1024 * 1024 * 1024,
          defaultMaxClientStorageBytes: 1024 * 1024 * 1024,
          defaultMaxSnapshots: 10,
        );
      } else {
        await _backupService.disableProviderMode();
      }
      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _startBackup(BackupProviderRelationship provider) async {
    try {
      await _backupService.startBackup(provider.providerCallsign);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('backup_started'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _showRestoreDialog(BackupProviderRelationship provider) async {
    await _showSnapshotHistory(provider, allowRestore: true, allowBackup: false);
  }

  Future<void> _showSnapshotHistory(
    BackupProviderRelationship provider, {
    bool allowRestore = false,
    bool allowBackup = true,
  }) async {
    final theme = Theme.of(context);
    var snapshotsFuture = _backupService.fetchProviderSnapshots(provider.providerCallsign);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (context, setModalState) {
              Future<void> refreshSnapshots() async {
                setModalState(() {
                  snapshotsFuture = _backupService.fetchProviderSnapshots(provider.providerCallsign);
                });
              }

              return SizedBox(
                height: MediaQuery.of(context).size.height * 0.7,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _i18n.t('backup_snapshots_for').replaceFirst('{0}', provider.providerCallsign),
                                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  _i18n.t('backup_history_hint'),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.of(sheetContext).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (allowBackup)
                            FilledButton.icon(
                              onPressed: () async {
                                await _startBackup(provider);
                                if (mounted) Navigator.of(sheetContext).pop();
                              },
                              icon: const Icon(Icons.backup, size: 18),
                              label: Text(_i18n.t('backup_now')),
                            ),
                          OutlinedButton.icon(
                            onPressed: refreshSnapshots,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: Text(_i18n.t('refresh')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: FutureBuilder<List<BackupSnapshot>>(
                          future: snapshotsFuture,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState != ConnectionState.done) {
                              return const Center(child: CircularProgressIndicator());
                            }
                            final snapshots = snapshot.data ?? [];
                            if (snapshots.isEmpty) {
                              return Center(child: Text(_i18n.t('backup_no_snapshots')));
                            }

                            final totalBytes = snapshots.fold<int>(0, (sum, s) => sum + s.totalBytes);
                            final quota = provider.maxStorageBytes;
                            final quotaInfo = quota > 0
                                ? '${_formatBytes(totalBytes)} / ${_formatBytes(quota)}'
                                : _formatBytes(totalBytes);
                            final maxSnap = provider.maxSnapshots > 0 ? provider.maxSnapshots : null;

                            return ListView.separated(
                                padding: const EdgeInsets.only(top: 8),
                                itemCount: snapshots.length + 1,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  if (index == 0) {
                                    return ListTile(
                                      title: Text(_i18n.t('backup_usage')),
                                      subtitle: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(quotaInfo),
                                          if (maxSnap != null)
                                            Text(
                                              _i18n
                                                  .t('backup_snapshots_used')
                                                  .replaceFirst('{0}', snapshots.length.toString())
                                                  .replaceFirst('{1}', maxSnap.toString()),
                                              style: theme.textTheme.bodySmall,
                                            ),
                                        ],
                                      ),
                                    );
                                  }
                                  final entry = snapshots[index - 1];
                                  final note = entry.note?.trim() ?? '';
                                  final details = '${entry.totalFiles} ${_i18n.t('files')}'
                                      ' • ${_formatBytes(entry.totalBytes)}';
                                  final dateLabel = entry.completedAt ?? entry.startedAt;
                                  return ListTile(
                                    title: Text(entry.snapshotId),
                                    subtitle: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        if (note.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(bottom: 4),
                                            child: Text(
                                              note,
                                              style: theme.textTheme.bodyMedium,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        Text(details, style: theme.textTheme.bodySmall),
                                        Text(
                                          _formatDate(dateLabel),
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: theme.colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                    trailing: Wrap(
                                      spacing: 6,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.edit_note_outlined),
                                          tooltip: _i18n.t('backup_edit_note'),
                                          onPressed: () => _editSnapshotNote(
                                            provider,
                                            entry,
                                            refreshSnapshots,
                                          ),
                                        ),
                                        if (allowRestore)
                                          IconButton(
                                            icon: const Icon(Icons.restore),
                                            tooltip: _i18n.t('backup_restore'),
                                            onPressed: () {
                                              Navigator.of(sheetContext).pop();
                                              _confirmRestore(provider, entry);
                                            },
                                          ),
                                      ],
                                    ),
                                    onTap: allowRestore
                                        ? () {
                                            Navigator.of(sheetContext).pop();
                                            _confirmRestore(provider, entry);
                                          }
                                        : null,
                                  );
                                },
                              );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _confirmRestore(BackupProviderRelationship provider, BackupSnapshot snapshot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('backup_confirm_restore')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_i18n.t('backup_restore_warning')),
            const SizedBox(height: 12),
            Text(
              _i18n.t('backup_restore_overwrites'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('backup_restore')),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      await _backupService.startRestore(provider.providerCallsign, snapshot.snapshotId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('backup_restore_started'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _editSnapshotNote(
    BackupProviderRelationship provider,
    BackupSnapshot snapshot,
    Future<void> Function() onUpdated,
  ) async {
    final controller = TextEditingController(text: snapshot.note ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('backup_edit_note')),
        content: TextField(
          controller: controller,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: _i18n.t('backup_snapshot_note'),
            hintText: _i18n.t('backup_note_placeholder'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('save')),
          ),
        ],
      ),
    );

    if (saved != true) {
      controller.dispose();
      return;
    }

    final note = controller.text.trim();
    controller.dispose();

    final success = await _backupService.updateSnapshotNote(
      provider.providerCallsign,
      snapshot.snapshotId,
      note,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? _i18n.t('backup_note_saved') : _i18n.t('backup_note_update_failed'),
          ),
          backgroundColor: success ? null : Theme.of(context).colorScheme.error,
        ),
      );
    }

    if (success) {
      await onUpdated();
    }
  }

  Future<void> _removeProvider(BackupProviderRelationship provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('backup_remove_provider_title')),
        content: Text(_i18n.t('backup_remove_provider_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(_i18n.t('remove')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _backupService.removeProvider(provider.providerCallsign);
        await _loadData();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.toString()),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    }
  }

  Future<void> _acceptClient(BackupClientRelationship client) async {
    try {
      await _backupService.acceptInvite(
        client.clientNpub,
        client.clientCallsign,
        _providerSettings?.defaultMaxClientStorageBytes ?? 1024 * 1024 * 1024,
        _providerSettings?.defaultMaxSnapshots ?? 10,
      );
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('backup_client_accepted'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _declineClient(BackupClientRelationship client) async {
    try {
      await _backupService.declineInvite(client.clientNpub, client.clientCallsign);
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('backup_client_declined'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _removeClient(BackupClientRelationship client) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('backup_remove_client_title')),
        content: Text(_i18n.t('backup_remove_client_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(_i18n.t('remove')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _backupService.removeClient(client.clientCallsign);
        await _loadData();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.toString()),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    }
  }

  void _showSettingsMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: Text(_i18n.t('backup_switch_role')),
              onTap: () {
                Navigator.pop(context);
                setState(() => _viewState = _BackupViewState.roleSelection);
              },
            ),
            if (_viewState == _BackupViewState.providerDashboard)
              ListTile(
                leading: const Icon(Icons.settings),
                title: Text(_i18n.t('backup_provider_settings')),
                onTap: () {
                  Navigator.pop(context);
                  _showProviderSettingsDialog();
                },
              ),
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: Text(_i18n.t('backup_local')),
              onTap: () {
                Navigator.pop(context);
                _enterLocalBackup();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showProviderSettingsDialog() {
    final maxStorageController = TextEditingController(
      text: ((_providerSettings?.maxTotalStorageBytes ?? 10737418240) / (1024 * 1024 * 1024)).toStringAsFixed(0),
    );
    final maxClientStorageController = TextEditingController(
      text: ((_providerSettings?.defaultMaxClientStorageBytes ?? 1073741824) / (1024 * 1024 * 1024)).toStringAsFixed(0),
    );
    final maxSnapshotsController = TextEditingController(
      text: (_providerSettings?.defaultMaxSnapshots ?? 10).toString(),
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('backup_provider_settings')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: maxStorageController,
              decoration: InputDecoration(
                labelText: _i18n.t('backup_max_storage_gb'),
                suffixText: 'GB',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: maxClientStorageController,
              decoration: InputDecoration(
                labelText: _i18n.t('backup_max_client_storage_gb'),
                suffixText: 'GB',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: maxSnapshotsController,
              decoration: InputDecoration(
                labelText: _i18n.t('backup_max_snapshots'),
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () async {
              final maxStorage = (double.tryParse(maxStorageController.text) ?? 10) * 1024 * 1024 * 1024;
              final maxClientStorage = (double.tryParse(maxClientStorageController.text) ?? 1) * 1024 * 1024 * 1024;
              final maxSnapshots = int.tryParse(maxSnapshotsController.text) ?? 10;

              await _backupService.updateProviderSettings(
                maxTotalStorageBytes: maxStorage.toInt(),
                defaultMaxClientStorageBytes: maxClientStorage.toInt(),
                defaultMaxSnapshots: maxSnapshots,
              );
              await _loadData();
              if (mounted) {
                Navigator.pop(context);
              }
            },
            child: Text(_i18n.t('save')),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // HELPERS
  // ============================================================

  List<AvailableBackupProvider> _dedupeAvailableProviders(List<AvailableBackupProvider> providers) {
    final seen = <String>{};
    final filtered = <AvailableBackupProvider>[];
    for (final provider in providers) {
      final key = provider.callsign.toUpperCase();
      if (seen.add(key)) {
        filtered.add(provider);
      }
    }
    return filtered;
  }

  List<BackupProviderRelationship> _dedupeProviderRelationships(
    List<BackupProviderRelationship> providers,
  ) {
    final seen = <String>{};
    final filtered = <BackupProviderRelationship>[];
    for (final provider in providers) {
      final key = provider.providerCallsign.toUpperCase();
      if (seen.add(key)) {
        filtered.add(provider);
      }
    }
    return filtered;
  }

  List<BackupClientRelationship> _dedupeClients(List<BackupClientRelationship> clients) {
    final seen = <String>{};
    final filtered = <BackupClientRelationship>[];
    for (final client in clients) {
      final key = client.clientCallsign.toUpperCase();
      if (seen.add(key)) {
        filtered.add(client);
      }
    }
    return filtered;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildStatusChip(ThemeData theme, BackupRelationshipStatus? status) {
    Color color;
    IconData icon;

    switch (status) {
      case BackupRelationshipStatus.pending:
        color = Colors.orange;
        icon = Icons.hourglass_empty;
        break;
      case BackupRelationshipStatus.active:
        color = Colors.green;
        icon = Icons.check_circle;
        break;
      case BackupRelationshipStatus.declined:
        color = Colors.red;
        icon = Icons.cancel;
        break;
      default:
        color = theme.colorScheme.onSurfaceVariant;
        icon = Icons.help_outline;
    }

    return Chip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(
        _i18n.t('backup_status_${status?.name ?? 'unknown'}'),
        style: TextStyle(color: color, fontSize: 12),
      ),
      backgroundColor: color.withOpacity(0.1),
      side: BorderSide.none,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }

  // ============================================================
  // LOCAL BACKUP
  // ============================================================

  void _enterLocalBackup() {
    _localBackupService.initialize();
    setState(() => _viewState = _BackupViewState.localBackupDashboard);
    _refreshLocalSnapshots();
  }

  Future<void> _refreshLocalSnapshots() async {
    final snapshots = await _localBackupService.listSnapshots();
    if (mounted) {
      setState(() => _localSnapshots = snapshots);
    }
  }

  Future<void> _pickLocalBackupFolder() async {
    String? result;
    if (Platform.isAndroid) {
      // SAF: lets the user pick any folder (including SD card / USB) without
      // needing the broad MANAGE_EXTERNAL_STORAGE permission. The returned
      // tree URI is persisted by the plugin and used as the backup destination.
      final treeUri = await saf.openDocumentTree(
        grantWritePermission: true,
        persistablePermission: true,
      );
      if (treeUri != null) result = treeUri.toString();
    } else {
      result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: _i18n.t('backup_local_select_folder'),
      );
    }
    if (result != null && mounted) {
      _localBackupService.setBackupFolder(result);
      setState(() {});
    }
  }

  Future<void> _createLocalBackup() async {
    setState(() {
      _localBackupStatus = LocalBackupStatus(isInProgress: true);
    });

    final snapshot = await _localBackupService.createBackup();

    if (mounted) {
      setState(() {
        _localBackupStatus = _localBackupService.status;
      });
      await _refreshLocalSnapshots();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(snapshot != null
              ? _i18n.t('backup_local_complete')
              : _i18n.t('backup_local_failed', params: [_localBackupService.status.error ?? 'Unknown error'])),
        ),
      );
    }
  }

  Future<void> _restoreLocalBackup(LocalBackupSnapshot snapshot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_i18n.t('backup_confirm_restore')),
        content: Text(_i18n.t('backup_local_restore_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_i18n.t('backup_restore')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _localBackupStatus = LocalBackupStatus(isInProgress: true);
    });

    final success = await _localBackupService.restoreSnapshot(snapshot.filePath);

    if (mounted) {
      setState(() {
        _localBackupStatus = _localBackupService.status;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? _i18n.t('backup_local_restore_success')
              : _i18n.t('backup_local_failed', params: [_localBackupService.status.error ?? 'Unknown error'])),
        ),
      );
    }
  }

  Future<void> _deleteLocalBackup(LocalBackupSnapshot snapshot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_i18n.t('backup_local_delete_confirm')),
        content: Text(snapshot.fileName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await _localBackupService.deleteSnapshot(snapshot.filePath);
    await _refreshLocalSnapshots();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('backup_deleted'))),
      );
    }
  }

  Widget _buildLocalBackupDashboard() {
    final theme = Theme.of(context);
    final settings = _localBackupService.settings;
    final folderPath = settings.backupFolderPath;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Back button
          TextButton.icon(
            onPressed: () => setState(() => _viewState = _BackupViewState.roleSelection),
            icon: const Icon(Icons.arrow_back),
            label: Text(_i18n.t('backup_switch_role')),
          ),
          const SizedBox(height: 8),

          // Backup folder section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _i18n.t('backup_local_folder'),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          folderPath != null
                              ? BackupStore.openFor(folderPath).displayLabel()
                              : _i18n.t('backup_local_select_folder'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: folderPath != null
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: _pickLocalBackupFolder,
                        child: Text(_i18n.t('backup_local_change_folder')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Backup Now button + progress
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: folderPath != null && !_localBackupStatus.isInProgress
                  ? _createLocalBackup
                  : null,
              icon: const Icon(Icons.backup),
              label: Text(_i18n.t('backup_local_now')),
            ),
          ),

          if (_localBackupStatus.isInProgress) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _localBackupStatus.progress > 0 ? _localBackupStatus.progress : null),
            const SizedBox(height: 4),
            Text(
              _localBackupStatus.currentFile != null
                  ? '${_i18n.t('backup_local_in_progress')} ${_localBackupStatus.currentFile}'
                  : _i18n.t('backup_local_in_progress'),
              style: theme.textTheme.bodySmall,
            ),
          ],

          const SizedBox(height: 24),

          // Backup History
          Text(
            _i18n.t('backup_local_snapshots'),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          if (_localSnapshots.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    _i18n.t('backup_local_no_snapshots'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            )
          else
            ...List.generate(_localSnapshots.length, (i) {
              final snap = _localSnapshots[i];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _formatDate(snap.createdAt),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${snap.totalFiles} files \u2022 ${_formatLocalBytes(snap.totalBytes)} (ZIP ${_formatLocalBytes(snap.archiveSizeBytes)})',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => _restoreLocalBackup(snap),
                            child: Text(_i18n.t('backup_restore')),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () => _deleteLocalBackup(snap),
                            style: TextButton.styleFrom(
                              foregroundColor: theme.colorScheme.error,
                            ),
                            child: Text(_i18n.t('delete')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),

          const SizedBox(height: 24),

          // Auto Backup settings
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SwitchListTile(
                    title: Text(_i18n.t('backup_local_auto_backup')),
                    value: settings.autoBackupEnabled,
                    onChanged: folderPath != null
                        ? (v) {
                            _localBackupService.updateSettings(autoBackupEnabled: v);
                            setState(() {});
                          }
                        : null,
                    contentPadding: EdgeInsets.zero,
                  ),
                  ListTile(
                    title: Text(_i18n.t('backup_local_auto_interval')),
                    subtitle: Text('${(settings.autoBackupIntervalMinutes / 60).round()} hours'),
                    contentPadding: EdgeInsets.zero,
                    trailing: DropdownButton<int>(
                      value: settings.autoBackupIntervalMinutes,
                      items: const [
                        DropdownMenuItem(value: 60, child: Text('1h')),
                        DropdownMenuItem(value: 360, child: Text('6h')),
                        DropdownMenuItem(value: 720, child: Text('12h')),
                        DropdownMenuItem(value: 1440, child: Text('24h')),
                        DropdownMenuItem(value: 4320, child: Text('3d')),
                        DropdownMenuItem(value: 10080, child: Text('7d')),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          _localBackupService.updateSettings(autoBackupIntervalMinutes: v);
                          setState(() {});
                        }
                      },
                    ),
                  ),
                  ListTile(
                    title: Text(_i18n.t('backup_local_max_snapshots')),
                    subtitle: Text('${settings.maxSnapshots}'),
                    contentPadding: EdgeInsets.zero,
                    trailing: DropdownButton<int>(
                      value: settings.maxSnapshots,
                      items: const [
                        DropdownMenuItem(value: 3, child: Text('3')),
                        DropdownMenuItem(value: 5, child: Text('5')),
                        DropdownMenuItem(value: 10, child: Text('10')),
                        DropdownMenuItem(value: 20, child: Text('20')),
                        DropdownMenuItem(value: 50, child: Text('50')),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          _localBackupService.updateSettings(maxSnapshots: v);
                          setState(() {});
                        }
                      },
                    ),
                  ),
                  if (settings.lastBackupAt != null)
                    ListTile(
                      title: Text(_i18n.t('backup_last')),
                      subtitle: Text(_formatDate(settings.lastBackupAt!)),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatLocalBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Color _getStatusColor(BackupRelationshipStatus? status) {
    switch (status) {
      case BackupRelationshipStatus.pending:
        return Colors.orange;
      case BackupRelationshipStatus.active:
        return Colors.green;
      case BackupRelationshipStatus.declined:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}

enum _BackupViewState {
  roleSelection,
  clientDashboard,
  providerDashboard,
  selectProvider,
  localBackupDashboard,
}
