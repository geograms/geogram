/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../services/security_service.dart';
import '../services/log_api_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/app_args.dart';

/// Page for managing security and privacy settings
class SecuritySettingsPage extends StatefulWidget {
  const SecuritySettingsPage({super.key});

  @override
  State<SecuritySettingsPage> createState() => _SecuritySettingsPageState();
}

class _SecuritySettingsPageState extends State<SecuritySettingsPage> {
  final SecurityService _securityService = SecurityService();
  final LogApiService _logApiService = LogApiService();
  final I18nService _i18n = I18nService();

  String? _localIpAddress;
  bool _isLoadingIp = true;

  @override
  void initState() {
    super.initState();
    _loadLocalIpAddress();
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
          if (ip.startsWith('192.168.') || ip.startsWith('10.') ||
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
      appBar: AppBar(
        title: Text(_i18n.t('security')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
          _buildSectionHeader(theme, _i18n.t('location_privacy'), Icons.location_on),
          const SizedBox(height: 8),

          // Location Granularity
          _buildLocationGranularityTile(theme),
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
                    Icon(Icons.lan, size: 16, color: theme.colorScheme.secondary),
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
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                _buildPrivacyIndicator(theme, Icons.gps_fixed, _i18n.t('precise'), sliderValue < 0.2),
                _buildPrivacyIndicator(theme, Icons.location_city, _i18n.t('city'), sliderValue >= 0.2 && sliderValue < 0.6),
                _buildPrivacyIndicator(theme, Icons.public, _i18n.t('region'), sliderValue >= 0.6),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrivacyIndicator(ThemeData theme, IconData icon, String label, bool isActive) {
    return Column(
      children: [
        Icon(
          icon,
          size: 24,
          color: isActive ? theme.colorScheme.primary : theme.colorScheme.outline,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: isActive ? theme.colorScheme.primary : theme.colorScheme.outline,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}
