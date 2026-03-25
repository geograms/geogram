/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io'
    show Directory, File, NetworkInterface, InternetAddressType, Platform, exit;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import '../services/security_service.dart';
import '../services/log_api_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/app_args.dart';
import '../services/storage_config.dart';
import '../services/config_service.dart';
import '../services/crash_service.dart';
import '../services/encrypted_storage_service.dart';
import '../services/encryption_progress_controller.dart';
import '../services/profile_service.dart';
import '../services/file_launcher_service.dart';

/// Page for managing security and privacy settings
class SecuritySettingsPage extends StatefulWidget {
  const SecuritySettingsPage({super.key});

  @override
  State<SecuritySettingsPage> createState() => _SecuritySettingsPageState();
}

class _SecuritySettingsPageState extends State<SecuritySettingsPage> {
  final SecurityService _securityService = SecurityService();
  final LogApiService _logApiService = LogApiService();
  final ConfigService _configService = ConfigService();
  final I18nService _i18n = I18nService();
  final EncryptedStorageService _encryptedService = EncryptedStorageService();
  final ProfileService _profileService = ProfileService();

  String? _localIpAddress;
  bool _isLoadingIp = true;
  bool _autoStartOnBoot = true;
  bool _isEncrypted = false;
  bool _hasNsec = false;

  @override
  void initState() {
    super.initState();
    _loadLocalIpAddress();
    _autoStartOnBoot = _configService.autoStartOnBoot;
    _loadEncryptedStatus();
  }

  Future<void> _loadEncryptedStatus() async {
    if (kIsWeb) return;
    final profile = _profileService.getProfile();
    if (profile != null) {
      final status = await _encryptedService.getStatus(profile.callsign);
      final hasNsec = profile.nsec != null && profile.nsec!.isNotEmpty;
      if (mounted) {
        setState(() {
          _isEncrypted = status.enabled;
          _hasNsec = hasNsec;
        });
      }
    }
  }

  Future<void> _loadLocalIpAddress() async {
    if (kIsWeb) {
      setState(() {
        _isLoadingIp = false;
        _localIpAddress = null;
      });
      return;
    }

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      String? ipAddress;
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          // Prefer private network addresses (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              (ip.startsWith('172.') && _isPrivateClass172(ip))) {
            ipAddress = ip;
            break;
          }
        }
        if (ipAddress != null) break;
      }

      setState(() {
        _localIpAddress = ipAddress;
        _isLoadingIp = false;
      });
    } catch (e) {
      LogService().log('SecuritySettingsPage: Error getting IP: $e');
      setState(() {
        _isLoadingIp = false;
      });
    }
  }

  bool _isPrivateClass172(String ip) {
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]) ?? 0;
    return second >= 16 && second <= 31;
  }

  void _copyApiUrl() {
    if (_localIpAddress == null) return;
    final url = 'http://$_localIpAddress:${AppArgs().port}/api/';
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_i18n.t('url_copied')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(_i18n.t('security'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Section: Connection Mode
          _buildSectionHeader(
            theme,
            _i18n.t('connection_mode'),
            Icons.bluetooth,
          ),
          const SizedBox(height: 8),
          _buildBleOnlyTile(theme),
          const SizedBox(height: 8),
          _buildUsbAccessTile(theme),
          const SizedBox(height: 24),

          // Section: API Access
          _buildSectionHeader(theme, _i18n.t('api_access'), Icons.api),
          const SizedBox(height: 8),

          // HTTP API Toggle
          _buildHttpApiTile(theme),
          const SizedBox(height: 8),

          // Debug API Toggle
          _buildDebugApiTile(theme),
          const SizedBox(height: 24),

          // Section: Location Privacy
          _buildSectionHeader(
            theme,
            _i18n.t('location_privacy'),
            Icons.location_on,
          ),
          const SizedBox(height: 8),

          // Location Granularity
          _buildLocationGranularityTile(theme),
          const SizedBox(height: 24),

          // Section: Background (Android only)
          if (!kIsWeb && Platform.isAndroid) ...[
            _buildSectionHeader(theme, _i18n.t('background'), Icons.sync),
            const SizedBox(height: 8),
            _buildAutoStartTile(theme),
            const SizedBox(height: 24),
          ],

          // Section: Storage (only on desktop/mobile, not web)
          if (!kIsWeb) ...[
            _buildSectionHeader(theme, _i18n.t('storage'), Icons.folder),
            const SizedBox(height: 8),
            _buildWorkingFolderTile(theme),
            const SizedBox(height: 8),
            _buildEncryptedStorageTile(theme),
            const SizedBox(height: 24),
          ],

          // Section: Diagnostics (only on Android, where crash recovery is available)
          if (!kIsWeb && Platform.isAndroid) ...[
            _buildSectionHeader(
              theme,
              _i18n.t('diagnostics'),
              Icons.bug_report,
            ),
            const SizedBox(height: 8),
            _buildCrashLogsTile(theme),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildHttpApiTile(ThemeData theme) {
    final isEnabled = _securityService.httpApiEnabled;
    final port = AppArgs().port;

    return Card(
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
                        _i18n.t('http_api'),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _i18n.t('http_api_description'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: isEnabled,
                  onChanged: (value) async {
                    setState(() {
                      _securityService.httpApiEnabled = value;
                    });
                    // Start/stop the HTTP server
                    if (value) {
                      await _logApiService.start();
                    } else {
                      await _logApiService.stop();
                    }
                  },
                ),
              ],
            ),
            if (isEnabled && !kIsWeb) ...[
              const Divider(height: 24),
              // Show IP and Port
              if (_isLoadingIp)
                const Center(child: CircularProgressIndicator())
              else if (_localIpAddress != null) ...[
                Row(
                  children: [
                    Icon(
                      Icons.lan,
                      size: 16,
                      color: theme.colorScheme.secondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'http://$_localIpAddress:$port/api/',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 20),
                      onPressed: _copyApiUrl,
                      tooltip: _i18n.t('copy'),
                    ),
                  ],
                ),
              ] else
                Text(
                  _i18n.t('not_connected_to_network'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDebugApiTile(ThemeData theme) {
    final isEnabled = _securityService.debugApiEnabled;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        _i18n.t('debug_api'),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _i18n.t('advanced'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.orange,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _i18n.t('debug_api_description'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: isEnabled,
              onChanged: (value) {
                setState(() {
                  _securityService.debugApiEnabled = value;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBleOnlyTile(ThemeData theme) {
    final isEnabled = _securityService.bleOnlyMode;
    final isInternetOnly = AppArgs().internetOnly;

    return Card(
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
                      Row(
                        children: [
                          Text(
                            _i18n.t('ble_only_mode'),
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _i18n.t('restrictive'),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: Colors.red,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _i18n.t('ble_only_mode_description'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: isEnabled,
                  onChanged: isInternetOnly
                      ? null
                      : (value) {
                          setState(() {
                            _securityService.bleOnlyMode = value;
                          });
                        },
                ),
              ],
            ),
            if (isEnabled) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.warning, size: 16, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _i18n.t('ble_only_mode_warning'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.orange,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildUsbAccessTile(ThemeData theme) {
    final isEnabled = _securityService.usbAccessEnabled;
    final isInternetOnly = AppArgs().internetOnly;
    final isBleOnly = _securityService.bleOnlyMode;
    final isLocked = isInternetOnly || isBleOnly;

    return Card(
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
                        _i18n.t('usb_access'),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _i18n.t('usb_access_description'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: isEnabled,
                  onChanged: isLocked
                      ? null
                      : (value) {
                          setState(() {
                            _securityService.usbAccessEnabled = value;
                          });
                        },
                ),
              ],
            ),
            if (isLocked) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: theme.colorScheme.secondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _i18n.t('usb_access_locked_description'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLocationGranularityTile(ThemeData theme) {
    final sliderValue = _securityService.locationGranularitySliderValue;
    final displayValue = _securityService.locationGranularityDisplay;
    final privacyLevel = _securityService.privacyLevelDescription;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _i18n.t('location_granularity'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              _i18n.t('location_granularity_description'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            // Current value display
            Center(
              child: Column(
                children: [
                  Text(
                    displayValue,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    privacyLevel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Slider with labels
            Row(
              children: [
                Text('5m', style: theme.textTheme.labelSmall),
                Expanded(
                  child: Slider(
                    value: sliderValue,
                    min: 0.0,
                    max: 1.0,
                    divisions: 100,
                    onChanged: (value) {
                      setState(() {
                        _securityService.locationGranularitySliderValue = value;
                      });
                    },
                  ),
                ),
                Text('100km', style: theme.textTheme.labelSmall),
              ],
            ),

            // Privacy level indicators
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildPrivacyIndicator(
                  theme,
                  Icons.gps_fixed,
                  _i18n.t('precise'),
                  sliderValue < 0.2,
                ),
                _buildPrivacyIndicator(
                  theme,
                  Icons.location_city,
                  _i18n.t('city'),
                  sliderValue >= 0.2 && sliderValue < 0.6,
                ),
                _buildPrivacyIndicator(
                  theme,
                  Icons.public,
                  _i18n.t('region'),
                  sliderValue >= 0.6,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrivacyIndicator(
    ThemeData theme,
    IconData icon,
    String label,
    bool isActive,
  ) {
    return Column(
      children: [
        Icon(
          icon,
          size: 24,
          color: isActive
              ? theme.colorScheme.primary
              : theme.colorScheme.outline,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: isActive
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildAutoStartTile(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _i18n.t('auto_start_on_boot'),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _i18n.t('auto_start_on_boot_description'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: _autoStartOnBoot,
              onChanged: (value) async {
                setState(() {
                  _autoStartOnBoot = value;
                });
                await _configService.setAutoStartOnBoot(value);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkingFolderTile(ThemeData theme) {
    final storageConfig = StorageConfig();
    final currentPath = storageConfig.isInitialized
        ? storageConfig.baseDir
        : 'Not initialized';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_i18n.t('working_folder'), style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              _i18n.t('working_folder_description'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.folder_open,
                  size: 16,
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    currentPath,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.secondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: currentPath));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(_i18n.t('url_copied')),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  tooltip: _i18n.t('copy'),
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 20),
                  onPressed: () => _openFolder(currentPath),
                  tooltip: _i18n.t('open_folder'),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.folder, size: 18),
                  label: Text(_i18n.t('change_folder')),
                  onPressed: _changeWorkingFolder,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEncryptedStorageTile(ThemeData theme) {
    final canToggle = _hasNsec;
    final progressController = EncryptionProgressController.instance;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ValueListenableBuilder<EncryptionProgress?>(
          valueListenable: progressController.progressNotifier,
          builder: (context, progress, _) {
            final isOperationRunning = progress != null;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _isEncrypted ? Icons.lock : Icons.lock_open,
                                size: 20,
                                color: _isEncrypted
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outline,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _i18n.t('encrypted_storage'),
                                style: theme.textTheme.titleSmall,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _i18n.t('encrypted_storage_description'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isOperationRunning)
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Switch(
                        value: _isEncrypted,
                        onChanged: canToggle ? _toggleEncryption : null,
                      ),
                  ],
                ),
                // Progress indicator when operation is running
                if (isOperationRunning) ...[
                  const SizedBox(height: 12),
                  _buildEncryptionProgress(theme, progress),
                ],
                if (!_hasNsec && !isOperationRunning) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.warning, size: 16, color: Colors.orange),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _i18n.t('encrypted_storage_requires_nsec'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.orange,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_isEncrypted && !isOperationRunning) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.verified_user, size: 16, color: Colors.green),
                      const SizedBox(width: 8),
                      Text(
                        _i18n.t('profile_encrypted'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildEncryptionProgress(
    ThemeData theme,
    EncryptionProgress progress,
  ) {
    final progressText = progress.isEncrypting
        ? _i18n.t(
            'encrypting_progress',
            params: [
              progress.filesProcessed.toString(),
              progress.totalFiles.toString(),
              progress.percent.toString(),
            ],
          )
        : _i18n.t(
            'decrypting_progress',
            params: [
              progress.filesProcessed.toString(),
              progress.totalFiles.toString(),
              progress.percent.toString(),
            ],
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress.totalFiles > 0
                ? progress.filesProcessed / progress.totalFiles
                : null,
            minHeight: 6,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(
              theme.colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Progress text
        Text(
          progressText,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w500,
          ),
        ),
        // Current file name (truncated)
        if (progress.currentFile != null) ...[
          const SizedBox(height: 4),
          Text(
            progress.currentFile!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  Future<void> _toggleEncryption(bool enable) async {
    final profile = _profileService.getProfile();
    if (profile == null || profile.nsec == null) return;

    final progressController = EncryptionProgressController.instance;

    // Don't start if already running
    if (progressController.isRunning) return;

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          enable ? _i18n.t('enable_encryption') : _i18n.t('disable_encryption'),
        ),
        content: Text(_i18n.t('encryption_warning')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              enable
                  ? _i18n.t('enable_encryption')
                  : _i18n.t('disable_encryption'),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      MigrationResult result;
      if (enable) {
        result = await progressController.runEncryption(
          profile.callsign,
          profile.nsec!,
        );
      } else {
        result = await progressController.runDecryption(
          profile.callsign,
          profile.nsec!,
        );
      }

      if (mounted) {
        if (result.success) {
          setState(() {
            _isEncrypted = enable;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${enable ? _i18n.t('encryption_enabled') : _i18n.t('encryption_disabled')} - ${result.filesProcessed} ${_i18n.t('files_migrated')}',
              ),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${_i18n.t('encryption_error')}: ${result.error}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_i18n.t('encryption_error')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildCrashLogsTile(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_i18n.t('crash_logs'), style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              _i18n.t('crash_logs_description'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.visibility, size: 18),
                  label: Text(_i18n.t('view_logs')),
                  onPressed: _showCrashLogs,
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(_i18n.t('clear_logs')),
                  onPressed: _clearCrashLogs,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCrashLogs() async {
    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    final crashLogs = await CrashService().readAllCrashLogs();

    if (!mounted) return;
    Navigator.pop(context); // Close loading

    if (crashLogs == null || crashLogs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('no_crash_logs')),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    // Show crash logs in a dialog
    showDialog(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.bug_report, size: 24),
              const SizedBox(width: 8),
              Text(_i18n.t('crash_logs')),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: SingleChildScrollView(
              child: SelectableText(
                crashLogs,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: Text(_i18n.t('copy')),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: crashLogs));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(_i18n.t('copied_to_clipboard')),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_i18n.t('close')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _clearCrashLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('clear_logs')),
        content: Text(_i18n.t('clear_logs_confirmation')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('clear')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await CrashService().clearAllCrashLogs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('logs_cleared')),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _openFolder(String path) async {
    final success = await FileLauncherService().openFolder(path);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('could_not_open_folder')),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _changeWorkingFolder() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: _i18n.t('working_folder'),
      );

      if (result != null) {
        final storageConfig = StorageConfig();
        final currentPath = storageConfig.baseDir;

        // Don't do anything if same folder selected
        if (result == currentPath) return;

        if (!mounted) return;

        // Show progress dialog
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 16),
                Expanded(child: Text(_i18n.t('moving_files'))),
              ],
            ),
          ),
        );

        // Move files from current location to new location
        final moveSuccess = await _moveWorkingFolder(currentPath, result);

        if (!mounted) return;

        // Close progress dialog
        Navigator.pop(context);

        if (moveSuccess) {
          // Save the new path to preferences file
          final saveSuccess = await storageConfig.saveCustomDataDir(result);

          if (!mounted) return;

          if (saveSuccess) {
            // Show dialog with option to exit app
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (context) => AlertDialog(
                title: Text(_i18n.t('restart_required')),
                content: Text(_i18n.t('folder_changed')),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(_i18n.t('later')),
                  ),
                  FilledButton(
                    onPressed: () => exit(0),
                    child: Text(_i18n.t('exit_now')),
                  ),
                ],
              ),
            );
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_i18n.t('folder_change_failed')),
              backgroundColor: Colors.red,
            ),
          );
        }

        setState(() {});
      }
    } catch (e) {
      LogService().log('SecuritySettingsPage: Error changing folder: $e');
      if (mounted) {
        // Close any open dialogs
        Navigator.of(
          context,
        ).popUntil((route) => route.isFirst || route.settings.name != null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('folder_change_failed')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Move all files and folders from source to destination
  Future<bool> _moveWorkingFolder(String sourcePath, String destPath) async {
    try {
      final sourceDir = Directory(sourcePath);
      final destDir = Directory(destPath);

      // Create destination if it doesn't exist
      if (!await destDir.exists()) {
        await destDir.create(recursive: true);
      }

      // Copy all contents recursively
      await _copyDirectory(sourceDir, destDir);

      LogService().log(
        'SecuritySettingsPage: Successfully moved folder from $sourcePath to $destPath',
      );
      return true;
    } catch (e) {
      LogService().log('SecuritySettingsPage: Error moving folder: $e');
      return false;
    }
  }

  /// Recursively copy a directory
  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await for (final entity in source.list(recursive: false)) {
      final newPath = '${destination.path}/${entity.path.split('/').last}';

      if (entity is File) {
        final destFile = File(newPath);
        // Skip if destination file already exists and is same size
        if (await destFile.exists()) {
          final sourceSize = await entity.length();
          final destSize = await destFile.length();
          if (sourceSize == destSize) {
            continue;
          }
        }
        await entity.copy(newPath);
      } else if (entity is Directory) {
        final newDir = Directory(newPath);
        if (!await newDir.exists()) {
          await newDir.create(recursive: true);
        }
        await _copyDirectory(entity, newDir);
      }
    }
  }
}
