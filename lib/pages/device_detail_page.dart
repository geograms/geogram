/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/debug_controller.dart';
import '../services/device_apps_service.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import 'remote_blog_browser_page.dart';
import 'remote_chat_browser_page.dart';
import 'remote_events_browser_page.dart';
import 'report_browser_page.dart';

/// Page showing available apps on a remote device
class DeviceDetailPage extends StatefulWidget {
  final RemoteDevice device;

  const DeviceDetailPage({
    super.key,
    required this.device,
  });

  @override
  State<DeviceDetailPage> createState() => _DeviceDetailPageState();
}

class _DeviceDetailPageState extends State<DeviceDetailPage> {
  final DeviceAppsService _appsService = DeviceAppsService();
  final I18nService _i18n = I18nService();

  Map<String, DeviceAppInfo> _apps = {};
  bool _isLoading = true;
  String? _error;
  StreamSubscription<DebugActionEvent>? _debugActionSubscription;

  @override
  void initState() {
    super.initState();
    _loadApps();
    _subscribeToDebugActions();
  }

  @override
  void dispose() {
    _debugActionSubscription?.cancel();
    super.dispose();
  }

  void _subscribeToDebugActions() {
    final debugController = DebugController();
    _debugActionSubscription = debugController.actionStream.listen((event) {
      if (event.action == DebugAction.openRemoteChatApp ||
          event.action == DebugAction.openRemoteChatRoom ||
          event.action == DebugAction.sendRemoteChatMessage) {
        final callsign = event.params['callsign'] as String?;

        if (callsign == widget.device.callsign) {
          LogService().log('DeviceDetailPage: Received debug action ${event.action} for ${widget.device.callsign}');

          // Open chat app
          _openRemoteChat();
        }
      }
    });
  }

  void _openRemoteChat() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RemoteChatBrowserPage(device: widget.device),
      ),
    );
  }

  Future<void> _loadApps() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      LogService().log('DeviceDetailPage._loadApps: START for ${widget.device.callsign}');

      // Use cache first for instant display, then refresh in background
      final apps = await _appsService.discoverApps(
        widget.device.callsign,
        useCache: true,
        refreshInBackground: true,
      );

      // Log detailed app info
      LogService().log('DeviceDetailPage: Received ${apps.length} app entries for ${widget.device.callsign}');
      for (var entry in apps.entries) {
        LogService().log('DeviceDetailPage:   - ${entry.key}: isAvailable=${entry.value.isAvailable}, itemCount=${entry.value.itemCount}');
      }

      final availableCount = apps.values.where((a) => a.isAvailable).length;
      LogService().log('DeviceDetailPage: ${availableCount} available apps for ${widget.device.callsign}');

      if (!mounted) return;
      setState(() {
        _apps = apps;
        _isLoading = false;
      });
    } catch (e) {
      LogService().log('DeviceDetailPage: Error loading apps: $e');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _openApp(DeviceAppInfo app) {
    switch (app.type) {
      case 'blog':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => RemoteBlogBrowserPage(
              device: widget.device,
            ),
          ),
        );
        break;
      case 'chat':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => RemoteChatBrowserPage(
              device: widget.device,
            ),
          ),
        );
        break;
      case 'events':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => RemoteEventsBrowserPage(
              device: widget.device,
            ),
          ),
        );
        break;
      case 'alerts':
        // Use existing ReportBrowserPage but filtered to this device
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const ReportBrowserPage(),
          ),
        );
        break;
      case 'shared':
        // Open shared folders in system browser via device URL
        final deviceUrl = widget.device.url;
        if (deviceUrl != null) {
          launchUrl(Uri.parse('$deviceUrl/shared/'));
        }
        break;
    }
  }

  IconData _getAppIcon(String appType) {
    switch (appType) {
      case 'blog':
        return Icons.article;
      case 'chat':
        return Icons.chat_bubble;
      case 'events':
        return Icons.event;
      case 'alerts':
        return Icons.warning;
      case 'shared':
        return Icons.folder_shared;
      default:
        return Icons.apps;
    }
  }

  Color _getAppColor(BuildContext context, String appType) {
    final theme = Theme.of(context);
    switch (appType) {
      case 'blog':
        return Colors.blue;
      case 'chat':
        return Colors.green;
      case 'events':
        return Colors.purple;
      case 'alerts':
        return Colors.orange;
      case 'shared':
        return Colors.teal;
      default:
        return theme.colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    LogService().log('DeviceDetailPage.build: _isLoading=$_isLoading, _error=$_error, _apps.length=${_apps.length}');

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.displayName),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadApps,
            tooltip: _i18n.t('refresh'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 64,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _i18n.t('error_loading_data'),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadApps,
                        child: Text(_i18n.t('retry')),
                      ),
                    ],
                  ),
                )
              : _buildAppsList(theme),
    );
  }

  Widget _buildAppsList(ThemeData theme) {
    final availableApps = _apps.values.where((app) => app.isAvailable).toList();

    LogService().log('DeviceDetailPage._buildAppsList: _apps has ${_apps.length} entries, availableApps has ${availableApps.length} entries');
    for (var app in availableApps) {
      LogService().log('DeviceDetailPage._buildAppsList: Available app: ${app.type} (${app.itemCount} items)');
    }

    if (availableApps.isEmpty) {
      LogService().log('DeviceDetailPage._buildAppsList: Showing empty state');
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.apps_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No apps available',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'This device has no public data to browse',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    LogService().log('DeviceDetailPage._buildAppsList: Building grid with ${availableApps.length} apps');

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: MediaQuery.of(context).size.width < 600 ? 2 : 3,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 0.95,
      ),
      itemCount: availableApps.length,
      itemBuilder: (context, index) {
        final app = availableApps[index];
        return _buildAppCard(theme, app);
      },
    );
  }

  Widget _buildAppCard(ThemeData theme, DeviceAppInfo app) {
    final appColor = _getAppColor(context, app.type);

    return InkWell(
      onTap: () => _openApp(app),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: appColor.withValues(alpha: 0.2),
              child: Icon(
                _getAppIcon(app.type),
                size: 32,
                color: appColor,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              app.displayName,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              '${app.itemCount} items',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
