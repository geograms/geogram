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
  String? _completedDownloadPath; // Track completed download ready to install
  VoidCallback? _completedDownloadListener;

  @override
  void initState() {
    super.initState();
    // Mark that UpdatePage is visible to suppress the update banner
    _updateService.isUpdatePageVisible = true;
    _completedDownloadListener = () {
      _setStateIfMounted(() {
        _completedDownloadPath = _updateService.completedDownloadPathNotifier.value;
      });
    };
    _updateService.completedDownloadPathNotifier.addListener(_completedDownloadListener!);
    _loadData();
  }

  @override
  void dispose() {
    // Mark that UpdatePage is no longer visible
    _updateService.isUpdatePageVisible = false;
    if (_completedDownloadListener != null) {
      _updateService.completedDownloadPathNotifier.removeListener(_completedDownloadListener!);
    }
    super.dispose();
  }

  void _setStateIfMounted(VoidCallback callback) {
    if (!mounted) return;
    setState(callback);
  }

  Future<void> _loadData() async {
    _setStateIfMounted(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Load cached release info first for immediate display
      _latestRelease = _updateService.getLatestRelease();
      _backups = await _updateService.listBackups();

      // Check if there's already a completed download ready to install (in-memory state)
      // Note: Filesystem check moved to after background update check to use latest version
      if (_updateService.hasCompletedDownload) {
        _completedDownloadPath = _updateService.completedDownloadPath;
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _setStateIfMounted(() {
        _isLoading = false;
      });
    }

    if (!mounted) return;

    // Auto-install flow (only installs if already downloaded; otherwise pre-download)
    if (widget.autoInstall && _latestRelease != null && _updateService.isLatestUpdateReady) {
      if (_completedDownloadPath != null) {
        _installCompletedDownload();
      } else {
        _downloadUpdate();
      }
      return; // Don't check for updates if auto-installing
    }

    // Automatically check for updates in background when visiting this page
    // This provides immediate feedback to the user without requiring a manual click
    _checkForUpdatesInBackground();
  }

  /// Check for updates in the background without blocking the UI
  Future<void> _checkForUpdatesInBackground() async {
    // Don't check if already checking or downloading
    if (_updateService.isChecking || _updateService.isDownloading) return;

    _setStateIfMounted(() {
      _statusMessage = _i18n.t('checking_for_updates');
    });

    try {
      final release = await _updateService.checkForUpdates();
      if (!mounted) return;

      if (release != null) {
        _latestRelease = release;
        final updateReady = _updateService.isLatestUpdateReady;

        // Check filesystem for completed download matching the NEW version
        // This handles the case where app was restarted after a download completed
        if (!_updateService.hasCompletedDownload) {
          final foundPath = await _updateService.findCompletedDownload(release);
          if (foundPath != null) {
            _updateService.restoreCompletedDownload(foundPath, release.version);
            _setStateIfMounted(() {
              _completedDownloadPath = foundPath;
            });
          }
        } else {
          // Update completed download path from service (in case auto-download completed)
          _setStateIfMounted(() {
            _completedDownloadPath = _updateService.completedDownloadPath;
          });
        }

        _setStateIfMounted(() {
          _statusMessage = updateReady
              ? _i18n.t('update_available_msg', params: [release.version])
              : _i18n.t('running_latest_version');
        });
      } else {
        _setStateIfMounted(() {
          _statusMessage = _i18n.t('could_not_check_updates');
        });
      }
    } catch (e) {
      // Don't show error for background check - just clear status
      _setStateIfMounted(() {
        _statusMessage = null;
      });
    }
  }

  Future<void> _checkForUpdates() async {
    _setStateIfMounted(() {
      _isLoading = true;
      _error = null;
      _statusMessage = _i18n.t('checking_for_updates');
    });

    try {
      _latestRelease = await _updateService.checkForUpdates();
      if (_latestRelease != null) {
        final updateReady = _updateService.isLatestUpdateReady;
        _statusMessage = updateReady
            ? _i18n.t('update_available_msg', params: [_latestRelease!.version])
            : _i18n.t('running_latest_version');
      } else {
        _statusMessage = _i18n.t('could_not_check_updates');
      }
    } catch (e) {
      _error = e.toString();
      _statusMessage = null;
    } finally {
      _setStateIfMounted(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _downloadUpdate() async {
    if (_latestRelease == null) return;
    if (_completedDownloadPath != null) return;

    _setStateIfMounted(() {
      _isLoading = true;
      _error = null;
      _statusMessage = _i18n.t('downloading_update');
    });

    try {
      final downloadPath = await _updateService.downloadUpdate(
        _latestRelease!,
        onProgress: (progress) {
          // Progress is handled by ValueListenableBuilder, no need to setState here
        },
      );

      if (!mounted) return;

      if (downloadPath != null) {
        _setStateIfMounted(() {
          _completedDownloadPath = downloadPath;
          _statusMessage = _i18n.t('ready_to_install');
        });
      } else {
        _setStateIfMounted(() {
          _error = _i18n.t('download_failed');
          _statusMessage = null;
        });
      }
    } catch (e) {
      _setStateIfMounted(() {
        _error = e.toString();
        _statusMessage = null;
      });
    } finally {
      _setStateIfMounted(() {
        _isLoading = false;
      });
    }
  }

  /// Install a completed download (skip download, go straight to install)
  Future<void> _installCompletedDownload() async {
    if (_completedDownloadPath == null || !mounted) return;

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

    _setStateIfMounted(() {
      _isLoading = true;
      _statusMessage = _i18n.t('applying_update');
    });

    try {
      // Pass the expected version to validate we're not installing same/older version
      final success = await _updateService.applyUpdate(
        _completedDownloadPath!,
        expectedVersion: _latestRelease?.version,
      );
      if (success) {
        // Clear the completed download state after successful install
        _updateService.clearCompletedDownload();
        _completedDownloadPath = null;

        final platform = _updateService.detectPlatform();
        if (platform == UpdatePlatform.android) {
          _setStateIfMounted(() {
            _statusMessage = _i18n.t('apk_installer_launched');
          });
        } else {
          final backups = await _updateService.listBackups();
          _setStateIfMounted(() {
            _statusMessage = _i18n.t('update_installed_restart');
            _backups = backups;
          });
        }
      } else {
        // On Android, this might mean the permission was revoked
        if (!kIsWeb && Platform.isAndroid) {
          _setStateIfMounted(() {
            _error = _i18n.t('install_update_failed');
            _statusMessage = null;
          });
        } else {
          _setStateIfMounted(() {
            _error = _i18n.t('apply_update_failed');
            _statusMessage = null;
          });
        }
      }
    } catch (e) {
      _setStateIfMounted(() {
        _error = e.toString();
        _statusMessage = null;
      });
    } finally {
      _setStateIfMounted(() {
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

    _setStateIfMounted(() {
      _isLoading = true;
      _statusMessage = _i18n.t('rolling_back');
    });

    try {
      final success = await _updateService.rollback(backup);
      if (success) {
        _setStateIfMounted(() {
          _statusMessage = _i18n.t('rollback_complete');
        });
      } else {
        _setStateIfMounted(() {
          _error = _i18n.t('rollback_failed');
          _statusMessage = null;
        });
      }
    } catch (e) {
      _setStateIfMounted(() {
        _error = e.toString();
        _statusMessage = null;
      });
    } finally {
      _setStateIfMounted(() {
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
      _setStateIfMounted(() {
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
      final backups = await _updateService.listBackups();
      _setStateIfMounted(() {
        _backups = backups;
      });
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

  /// Handle tap on update card - either check for updates, install completed download, or download+install
  void _handleUpdateCardTap() {
    if (_isLoading) return;

    final hasUpdate = _updateService.isLatestUpdateReady;

    if (hasUpdate && !kIsWeb) {
      // If download already completed, just install
      if (_completedDownloadPath != null) {
        _installCompletedDownload();
      } else {
        _downloadUpdate();
      }
    } else {
      _checkForUpdates();
    }
  }

  /// Clear download cache and retry the download
  Future<void> _clearAndRetry() async {
    _setStateIfMounted(() {
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
        await _downloadUpdate();
      }
    } catch (e) {
      _setStateIfMounted(() {
        _error = e.toString();
        _statusMessage = null;
      });
    } finally {
      _setStateIfMounted(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final platform = _updateService.detectPlatform();
    final settings = _updateService.getSettings();
    final currentVersion = _updateService.getCurrentVersion();
    final hasUpdate = _updateService.isLatestUpdateReady;

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
                    const SizedBox(height: 16),
                  ],
                ),

              // Changelog - show when update is available (so users can read while downloading)
              if (_latestRelease != null && hasUpdate && _latestRelease!.body != null && _latestRelease!.body!.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.article_outlined,
                              size: 20,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _i18n.t('whats_new_in_version', params: [_latestRelease!.version]),
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _latestRelease!.body!,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        if (_latestRelease!.htmlUrl != null) ...[
                          const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: () => _launchURL(_latestRelease!.htmlUrl!),
                            icon: const Icon(Icons.open_in_new, size: 16),
                            label: Text(_i18n.t('view_on_github')),
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

              if (_latestRelease != null && hasUpdate && _latestRelease!.body != null && _latestRelease!.body!.isNotEmpty)
                const SizedBox(height: 16),

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
                        _setStateIfMounted(() {});
                      },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      title: Text(_i18n.t('auto_download_updates')),
                      subtitle: Text(_i18n.t('auto_download_updates_desc')),
                      value: settings.autoDownloadUpdates,
                      onChanged: (value) async {
                        await _updateService.updateSettings(
                          settings.copyWith(autoDownloadUpdates: value),
                        );
                        _setStateIfMounted(() {});
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
                        _setStateIfMounted(() {});
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
                        _setStateIfMounted(() {});
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
                            _setStateIfMounted(() {});
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
    final isChecking = _updateService.isChecking;

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
    } else if (_isLoading || isChecking) {
      cardColor = Theme.of(context).colorScheme.surfaceContainerHighest;
      icon = Icons.sync;
      title = _i18n.t('checking');
      subtitle = _statusMessage ?? _i18n.t('please_wait');
    } else if (_completedDownloadPath != null && hasUpdate && !kIsWeb) {
      // Download completed, ready to install
      cardColor = Theme.of(context).colorScheme.primaryContainer;
      icon = Icons.install_mobile;
      title = _i18n.t('ready_to_install');
      subtitle = _i18n.t('tap_to_install_version', params: [_latestRelease!.version]);
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
      // Determine source - station URL or GitHub
      String source = 'GitHub';
      if (_latestRelease!.stationBaseUrl != null) {
        // Extract hostname from station URL (e.g., "https://p2p.radio" -> "p2p.radio")
        try {
          final uri = Uri.parse(_latestRelease!.stationBaseUrl!);
          source = uri.host;
        } catch (e) {
          source = _latestRelease!.stationBaseUrl!;
        }
      }
      subtitle = _i18n.t('install_version_from_source', params: [_latestRelease!.version, source, releaseDateStr]);
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
        onTap: (isDownloading || _isLoading || isChecking) ? null : _handleUpdateCardTap,
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
                child: (_isLoading || isChecking) && !isDownloading
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
              if (!isDownloading && !_isLoading && !isChecking)
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
