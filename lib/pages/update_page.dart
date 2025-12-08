import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/update_settings.dart';
import '../services/update_service.dart';
import '../services/i18n_service.dart';

class UpdatePage extends StatefulWidget {
  final bool autoInstall;

  const UpdatePage({super.key, this.autoInstall = false});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  final UpdateService _updateService = UpdateService();
  final I18nService _i18n = I18nService();
  ReleaseInfo? _latestRelease;
  List<BackupInfo> _backups = [];
  bool _isLoading = false;
  String? _error;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    // Mark that UpdatePage is visible to suppress the update banner
    _updateService.isUpdatePageVisible = true;
    _loadData();
  }

  @override
  void dispose() {
    // Mark that UpdatePage is no longer visible
    _updateService.isUpdatePageVisible = false;
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      _latestRelease = _updateService.getLatestRelease();
      _backups = await _updateService.listBackups();
    } catch (e) {
      _error = e.toString();
    } finally {
      setState(() {
        _isLoading = false;
      });
    }

    // Auto-install if requested and update is available
    if (widget.autoInstall && _latestRelease != null) {
      final isNewer = _updateService.isNewerVersion(
        _updateService.getCurrentVersion(),
        _latestRelease!.version,
      );
      if (isNewer) {
        _downloadAndInstall();
      }
    }
  }

  Future<void> _checkForUpdates() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _statusMessage = _i18n.t('checking_for_updates');
    });

    try {
      _latestRelease = await _updateService.checkForUpdates();
      if (_latestRelease != null) {
        final isNewer = _updateService.isNewerVersion(
          _updateService.getCurrentVersion(),
          _latestRelease!.version,
        );
        if (isNewer) {
          _statusMessage = _i18n.t('update_available_msg', params: [_latestRelease!.version]);
        } else {
          _statusMessage = _i18n.t('running_latest_version');
        }
      } else {
        _statusMessage = _i18n.t('could_not_check_updates');
      }
    } catch (e) {
      _error = e.toString();
      _statusMessage = null;
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _downloadAndInstall() async {
    if (_latestRelease == null) return;

    // On Android, check install permission first
    if (!kIsWeb && Platform.isAndroid) {
      final canInstall = await _updateService.canInstallPackages();
      if (!canInstall) {
        // Show dialog explaining the permission is needed
        if (mounted) {
          final shouldOpenSettings = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(_i18n.t('permission_required')),
              content: Text(_i18n.t('permission_required_msg')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(_i18n.t('cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(_i18n.t('open_settings')),
                ),
              ],
            ),
          );

          if (shouldOpenSettings == true) {
            await _updateService.openInstallPermissionSettings();
          }
        }
        return;
      }
    }

    setState(() {
      _isLoading = true;
      _statusMessage = _i18n.t('downloading_update');
    });

    try {
      final downloadPath = await _updateService.downloadUpdate(
        _latestRelease!,
        onProgress: (progress) {
          // Progress is handled by ValueListenableBuilder, no need to setState here
        },
      );

      if (downloadPath != null) {
        setState(() {
          _statusMessage = _i18n.t('applying_update');
        });

        final success = await _updateService.applyUpdate(downloadPath);
        if (success) {
          final platform = _updateService.detectPlatform();
          if (platform == UpdatePlatform.android) {
            _statusMessage = _i18n.t('apk_installer_launched');
          } else {
            _statusMessage = _i18n.t('update_installed_restart');
            _backups = await _updateService.listBackups();
          }
        } else {
          // On Android, this might mean the permission was revoked during download
          if (!kIsWeb && Platform.isAndroid) {
            _error = _i18n.t('install_update_failed');
          } else {
            _error = _i18n.t('apply_update_failed');
          }
          _statusMessage = null;
        }
      } else {
        _error = _i18n.t('download_failed');
        _statusMessage = null;
      }
    } catch (e) {
      _error = e.toString();
      _statusMessage = null;
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _rollback(BackupInfo backup) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('confirm_rollback')),
        content: Text(_i18n.t('confirm_rollback_msg', params: [backup.version ?? 'unknown'])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('rollback')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isLoading = true;
      _statusMessage = _i18n.t('rolling_back');
    });

    try {
      final success = await _updateService.rollback(backup);
      if (success) {
        _statusMessage = _i18n.t('rollback_complete');
      } else {
        _error = _i18n.t('rollback_failed');
        _statusMessage = null;
      }
    } catch (e) {
      _error = e.toString();
      _statusMessage = null;
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteBackup(BackupInfo backup) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_backup_title')),
        content: Text(_i18n.t('delete_backup_confirm', params: [backup.filename])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final success = await _updateService.deleteBackup(backup);
    if (success) {
      setState(() {
        _backups.remove(backup);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('backup_deleted'))),
        );
      }
    }
  }

  Future<void> _togglePinBackup(BackupInfo backup) async {
    final success = await _updateService.togglePinBackup(backup);
    if (success) {
      // Reload backups to reflect the new pin status
      _backups = await _updateService.listBackups();
      setState(() {});
      if (mounted) {
        final message = backup.isPinned
            ? _i18n.t('backup_unpinned')
            : _i18n.t('backup_pinned');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    }
  }

  void _launchURL(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Handle tap on update card - either check for updates or install
  void _handleUpdateCardTap() {
    if (_isLoading) return;

    final hasUpdate = _latestRelease != null &&
        _updateService.isNewerVersion(
          _updateService.getCurrentVersion(),
          _latestRelease!.version,
        );

    if (hasUpdate && !kIsWeb) {
      _downloadAndInstall();
    } else {
      _checkForUpdates();
    }
  }

  /// Clear download cache and retry the download
  Future<void> _clearAndRetry() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _statusMessage = _i18n.t('clearing_download_cache');
    });

    try {
      await _updateService.clearAllDownloads();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('download_cache_cleared'))),
        );
      }

      // Now retry the download
      if (_latestRelease != null) {
        await _downloadAndInstall();
      }
    } catch (e) {
      _error = e.toString();
      _statusMessage = null;
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final platform = _updateService.detectPlatform();
    final settings = _updateService.getSettings();
    final currentVersion = _updateService.getCurrentVersion();
    final hasUpdate = _latestRelease != null &&
        _updateService.isNewerVersion(currentVersion, _latestRelease!.version);

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('software_updates')),
      ),
      body: RefreshIndicator(
        onRefresh: _checkForUpdates,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Current Version Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _i18n.t('current_version'),
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildInfoRow(_i18n.t('version'), 'v$currentVersion'),
                      _buildInfoRow(_i18n.t('platform'), platform.name.toUpperCase()),
                      _buildInfoRow(_i18n.t('binary_type'), platform.binaryPattern),
                      if (settings.lastCheckTime != null)
                        _buildInfoRow(
                          _i18n.t('last_check'),
                          _formatDateTime(settings.lastCheckTime!),
                        ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Clickable Update Status Card - Main action area
              _buildUpdateStatusCard(hasUpdate),

              const SizedBox(height: 16),

              // Download Progress
              if (_updateService.isDownloading)
                Column(
                  children: [
                    ValueListenableBuilder<double>(
                      valueListenable: _updateService.downloadProgress,
                      builder: (context, progress, child) {
                        final downloadStatus = _updateService.getDownloadStatus();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  downloadStatus.isNotEmpty ? downloadStatus : _i18n.t('downloading'),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                Text(
                                  '${(progress * 100).toStringAsFixed(0)}%',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: progress,
                              minHeight: 8,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 24),
                  ],
                ),

              // Error display
              if (_error != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.error_outline,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton.icon(
                              onPressed: _isLoading ? null : _clearAndRetry,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: Text(_i18n.t('clear_cache_retry')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

              if (_error != null) const SizedBox(height: 16),

              // Latest Release Card (details) - only show when up to date, hide when update available
              // to let user focus on the action button
              if (_latestRelease != null && !_updateService.isDownloading && !hasUpdate)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.new_releases_outlined,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _i18n.t('release_details'),
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _buildInfoRow(_i18n.t('version'), 'v${_latestRelease!.version}'),
                        if (_latestRelease!.name != null)
                          _buildInfoRow(_i18n.t('name'), _latestRelease!.name!),
                        if (_latestRelease!.publishedAt != null)
                          _buildInfoRow(
                            _i18n.t('released'),
                            _formatDateString(_latestRelease!.publishedAt!),
                          ),
                        _buildInfoRow(
                          _i18n.t('available_for'),
                          _latestRelease!.assets.keys.map((k) => k.toUpperCase()).join(', '),
                        ),
                        if (_latestRelease!.body != null &&
                            _latestRelease!.body!.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          const Divider(),
                          const SizedBox(height: 12),
                          Text(
                            _i18n.t('release_notes'),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _latestRelease!.body!,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                        if (_latestRelease!.htmlUrl != null) ...[
                          const SizedBox(height: 16),
                          TextButton.icon(
                            onPressed: () => _launchURL(_latestRelease!.htmlUrl!),
                            icon: const Icon(Icons.open_in_new, size: 18),
                            label: Text(_i18n.t('view_on_github')),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 32),

              // Backups Section (Android only)
              if (!kIsWeb && Platform.isAndroid) ...[
                Text(
                  _i18n.t('rollback_backups'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  _i18n.t('rollback_backups_desc'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 16),
                if (_backups.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              Icons.history,
                              size: 48,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _i18n.t('no_backups_available'),
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  ...List.generate(_backups.length, (index) {
                    final backup = _backups[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Stack(
                          children: [
                            CircleAvatar(
                              backgroundColor: backup.isPinned
                                  ? Theme.of(context).colorScheme.primaryContainer
                                  : null,
                              child: Text('${index + 1}'),
                            ),
                            if (backup.isPinned)
                              Positioned(
                                right: -2,
                                bottom: -2,
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.push_pin,
                                    size: 12,
                                    color: Theme.of(context).colorScheme.onPrimary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        title: Row(
                          children: [
                            Text('v${backup.version ?? "unknown"}'),
                            if (backup.isPinned) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  _i18n.t('pinned'),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '${backup.formattedSize} • ${_formatDateTime(backup.timestamp)}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                backup.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                                color: backup.isPinned
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              tooltip: backup.isPinned
                                  ? _i18n.t('unpin_backup')
                                  : _i18n.t('pin_backup'),
                              onPressed: _isLoading ? null : () => _togglePinBackup(backup),
                            ),
                            IconButton(
                              icon: const Icon(Icons.restore),
                              tooltip: _i18n.t('rollback_to_version'),
                              onPressed: _isLoading ? null : () => _rollback(backup),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.delete_outline,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              tooltip: _i18n.t('delete_backup'),
                              onPressed: _isLoading ? null : () => _deleteBackup(backup),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
              ],

              const SizedBox(height: 32),

              // Settings Section
              Text(
                _i18n.t('update_settings'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      title: Text(_i18n.t('auto_check_updates')),
                      subtitle: Text(_i18n.t('auto_check_updates_desc')),
                      value: settings.autoCheckUpdates,
                      onChanged: (value) async {
                        await _updateService.updateSettings(
                          settings.copyWith(autoCheckUpdates: value),
                        );
                        setState(() {});
                      },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      title: Text(_i18n.t('update_from_station')),
                      subtitle: Text(settings.useStationForUpdates
                          ? _i18n.t('update_from_station_enabled')
                          : _i18n.t('update_from_station_disabled')),
                      value: settings.useStationForUpdates,
                      onChanged: (value) async {
                        await _updateService.updateSettings(
                          settings.copyWith(useStationForUpdates: value),
                        );
                        setState(() {});
                      },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      title: Text(_i18n.t('update_notifications')),
                      subtitle: Text(_i18n.t('update_notifications_desc')),
                      value: settings.notifyOnUpdate,
                      onChanged: (value) async {
                        await _updateService.updateSettings(
                          settings.copyWith(notifyOnUpdate: value),
                        );
                        setState(() {});
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      title: Text(_i18n.t('maximum_backups')),
                      subtitle: Text(_i18n.t('keep_previous_versions', params: [settings.maxBackups.toString()])),
                      trailing: DropdownButton<int>(
                        value: settings.maxBackups,
                        items: [3, 5, 10, 15, 20]
                            .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                            .toList(),
                        onChanged: (value) async {
                          if (value != null) {
                            await _updateService.updateSettings(
                              settings.copyWith(maxBackups: value),
                            );
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  /// Build the main clickable update status card
  Widget _buildUpdateStatusCard(bool hasUpdate) {
    final isDownloading = _updateService.isDownloading;

    // Determine card appearance based on state
    Color cardColor;
    IconData icon;
    String title;
    String subtitle;

    if (isDownloading) {
      cardColor = Theme.of(context).colorScheme.primaryContainer;
      icon = Icons.downloading;
      title = _i18n.t('downloading_update');
      subtitle = _i18n.t('downloading_update_wait');
    } else if (_isLoading) {
      cardColor = Theme.of(context).colorScheme.surfaceContainerHighest;
      icon = Icons.sync;
      title = _i18n.t('checking');
      subtitle = _statusMessage ?? _i18n.t('please_wait');
    } else if (hasUpdate && !kIsWeb) {
      cardColor = Theme.of(context).colorScheme.primaryContainer;
      icon = Icons.system_update;
      title = _i18n.t('update_available_title');
      // Format release date from ISO 8601 to "YYYY-MM-DD HH:MM"
      String releaseDateStr = '';
      if (_latestRelease!.publishedAt != null) {
        try {
          final releaseDate = DateTime.parse(_latestRelease!.publishedAt!).toLocal();
          releaseDateStr = '${releaseDate.year}-${releaseDate.month.toString().padLeft(2, '0')}-${releaseDate.day.toString().padLeft(2, '0')} ${releaseDate.hour.toString().padLeft(2, '0')}:${releaseDate.minute.toString().padLeft(2, '0')}';
        } catch (e) {
          releaseDateStr = _latestRelease!.publishedAt!;
        }
      }
      subtitle = _i18n.t('tap_to_download_install', params: [_latestRelease!.version, releaseDateStr]);
    } else if (_latestRelease != null) {
      cardColor = Theme.of(context).colorScheme.secondaryContainer;
      icon = Icons.check_circle_outline;
      title = _i18n.t('up_to_date');
      subtitle = _i18n.t('tap_to_check_updates');
    } else {
      cardColor = Theme.of(context).colorScheme.surfaceContainerHighest;
      icon = Icons.refresh;
      title = _i18n.t('check_for_updates');
      subtitle = _i18n.t('tap_to_check_new_versions');
    }

    return Card(
      color: cardColor,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: (isDownloading || _isLoading) ? null : _handleUpdateCardTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _isLoading && !isDownloading
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      )
                    : Icon(
                        icon,
                        size: 24,
                        color: hasUpdate
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              if (!isDownloading && !_isLoading)
                Icon(
                  Icons.chevron_right,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatDateString(String isoDate) {
    try {
      final dt = DateTime.parse(isoDate);
      return _formatDateTime(dt);
    } catch (e) {
      return isoDate;
    }
  }
}
