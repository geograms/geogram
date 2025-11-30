/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/relay_cache_service.dart';
import 'chat_browser_page.dart';

/// Page for browsing remote devices and their collections
class DevicesBrowserPage extends StatefulWidget {
  const DevicesBrowserPage({super.key});

  @override
  State<DevicesBrowserPage> createState() => _DevicesBrowserPageState();
}

class _DevicesBrowserPageState extends State<DevicesBrowserPage> {
  final DevicesService _devicesService = DevicesService();
  final RelayCacheService _cacheService = RelayCacheService();
  final I18nService _i18n = I18nService();

  List<RemoteDevice> _devices = [];
  RemoteDevice? _selectedDevice;
  List<RemoteCollection> _collections = [];
  bool _isLoading = true;
  bool _isLoadingCollections = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() => _isLoading = true);

    try {
      await _devicesService.initialize();
      await _cacheService.initialize();

      // Listen to device updates
      _devicesService.devicesStream.listen((devices) {
        if (mounted) {
          setState(() => _devices = devices);
        }
      });

      // Initial load
      _devices = _devicesService.getAllDevices();

      // Check reachability for all devices
      await _devicesService.refreshAllDevices();
    } catch (e) {
      LogService().log('DevicesBrowserPage: Error initializing: $e');
      _error = e.toString();
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshDevices() async {
    setState(() => _isLoading = true);
    await _devicesService.refreshAllDevices();
    _devices = _devicesService.getAllDevices();
    setState(() => _isLoading = false);
  }

  Future<void> _selectDevice(RemoteDevice device) async {
    setState(() {
      _selectedDevice = device;
      _isLoadingCollections = true;
      _collections = [];
    });

    try {
      final collections = await _devicesService.fetchCollections(device.callsign);
      if (mounted) {
        setState(() {
          _collections = collections;
          _isLoadingCollections = false;
        });
      }
    } catch (e) {
      LogService().log('DevicesBrowserPage: Error fetching collections: $e');
      if (mounted) {
        setState(() => _isLoadingCollections = false);
      }
    }
  }

  void _openCollection(RemoteCollection collection) {
    // Handle different collection types
    switch (collection.type) {
      case 'chat':
        _openChatCollection(collection);
        break;
      default:
        _showCollectionInfo(collection);
    }
  }

  void _openChatCollection(RemoteCollection collection) {
    if (_selectedDevice == null) return;

    // Build the remote device URL
    // If the device has a direct URL, use it; otherwise construct via relay proxy
    String remoteUrl = _selectedDevice!.url ?? '';

    // Convert WebSocket URL to HTTP URL for API calls
    if (remoteUrl.startsWith('ws://')) {
      remoteUrl = remoteUrl.replaceFirst('ws://', 'http://');
    } else if (remoteUrl.startsWith('wss://')) {
      remoteUrl = remoteUrl.replaceFirst('wss://', 'https://');
    }

    LogService().log('DevicesBrowserPage: Opening chat for ${_selectedDevice!.callsign} at $remoteUrl');

    // Navigate to the ChatBrowserPage with remote device parameters
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatBrowserPage(
          remoteDeviceUrl: remoteUrl,
          remoteDeviceCallsign: _selectedDevice!.callsign,
          remoteDeviceName: _selectedDevice!.name,
        ),
      ),
    );
  }

  void _showCollectionInfo(RemoteCollection collection) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(collection.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow(_i18n.t('type'), collection.type),
            if (collection.description != null)
              _buildInfoRow(_i18n.t('description'), collection.description!),
            if (collection.fileCount != null)
              _buildInfoRow(_i18n.t('files'), collection.fileCount.toString()),
            if (collection.visibility != null)
              _buildInfoRow(_i18n.t('visibility'), collection.visibility!),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('close')),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _initialize,
              child: Text(_i18n.t('retry')),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 600;

        if (isNarrow) {
          // Mobile layout: full-screen list or detail
          if (_selectedDevice != null) {
            return _buildDeviceDetail(theme);
          }
          return _buildDeviceList(theme);
        }

        // Desktop layout: side-by-side
        return Row(
          children: [
            SizedBox(
              width: 300,
              child: _buildDeviceList(theme),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: _selectedDevice != null
                  ? _buildDeviceDetail(theme)
                  : _buildEmptyState(theme),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDeviceList(ThemeData theme) {
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.2),
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.devices, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _i18n.t('devices'),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _refreshDevices,
                tooltip: _i18n.t('refresh'),
              ),
            ],
          ),
        ),

        // Device list
        Expanded(
          child: _devices.isEmpty
              ? _buildNoDevices(theme)
              : ListView.builder(
                  itemCount: _devices.length,
                  itemBuilder: (context, index) {
                    final device = _devices[index];
                    return _buildDeviceListTile(theme, device);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDeviceListTile(ThemeData theme, RemoteDevice device) {
    final isSelected = _selectedDevice?.callsign == device.callsign;

    return ListTile(
      selected: isSelected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Icon(
              Icons.devices,
              color: theme.colorScheme.primary,
            ),
          ),
          // Online indicator
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: device.isOnline ? Colors.green : Colors.grey,
                border: Border.all(
                  color: theme.colorScheme.surface,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        device.name,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            device.callsign,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              Text(
                device.isOnline ? _i18n.t('online') : _i18n.t('offline'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: device.isOnline ? Colors.green : Colors.grey,
                ),
              ),
              if (device.hasCachedData)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_done,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      _i18n.t('cached'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (device.latency != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '${device.latency}ms',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          IconButton(
            icon: Icon(
              Icons.delete_outline,
              color: theme.colorScheme.error,
              size: 20,
            ),
            onPressed: () => _confirmDeleteDevice(device),
            tooltip: _i18n.t('delete'),
          ),
        ],
      ),
      onTap: () => _selectDevice(device),
    );
  }

  Future<void> _confirmDeleteDevice(RemoteDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_device')),
        content: Text(_i18n.t('delete_device_confirm', params: [device.name])),
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
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _devicesService.removeDevice(device.callsign);
      if (_selectedDevice?.callsign == device.callsign) {
        setState(() => _selectedDevice = null);
      }
      _devices = _devicesService.getAllDevices();
      setState(() {});
    }
  }

  Widget _buildDeviceDetail(ThemeData theme) {
    final device = _selectedDevice!;

    return Column(
      children: [
        // Device header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.2),
              ),
            ),
          ),
          child: Row(
            children: [
              // Back button for narrow screens
              if (MediaQuery.of(context).size.width < 600)
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _selectedDevice = null),
                ),
              CircleAvatar(
                radius: 24,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.devices,
                  color: theme.colorScheme.primary,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Row(
                      children: [
                        Text(
                          device.callsign,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: 'monospace',
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: device.isOnline
                                ? Colors.green.withValues(alpha: 0.1)
                                : Colors.grey.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: device.isOnline ? Colors.green : Colors.grey,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                device.isOnline ? _i18n.t('online') : _i18n.t('offline'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: device.isOnline ? Colors.green : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => _selectDevice(device),
                tooltip: _i18n.t('refresh'),
              ),
            ],
          ),
        ),

        // Collections grid
        Expanded(
          child: _isLoadingCollections
              ? const Center(child: CircularProgressIndicator())
              : _collections.isEmpty
                  ? _buildNoCollections(theme)
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        // Calculate number of columns based on available width
                        final availableWidth = constraints.maxWidth;
                        final crossAxisCount = availableWidth < 400
                            ? 2
                            : availableWidth < 600
                                ? 3
                                : availableWidth < 900
                                    ? 4
                                    : 5;

                        return GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 1.9,
                          ),
                          itemCount: _collections.length,
                          itemBuilder: (context, index) {
                            final collection = _collections[index];
                            return _buildCollectionCard(theme, collection);
                          },
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildCollectionCard(ThemeData theme, RemoteCollection collection) {
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: () => _openCollection(collection),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icon and title row
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Badge(
                    isLabelVisible: collection.fileCount != null && collection.fileCount! > 0,
                    label: Text('${collection.fileCount ?? 0}'),
                    child: Icon(
                      _getCollectionIcon(collection.type),
                      size: 26,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _getDisplayTitle(collection),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            height: 1.15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (collection.description != null)
                          Text(
                            collection.description!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 12,
                              height: 1.15,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        else
                          Text(
                            collection.type,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 12,
                              height: 1.15,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getDisplayTitle(RemoteCollection collection) {
    final name = collection.name;
    if (name.toLowerCase() == 'www') {
      return 'WWW';
    }
    if (name.isNotEmpty) {
      return name[0].toUpperCase() + name.substring(1);
    }
    return name;
  }

  IconData _getCollectionIcon(String type) {
    switch (type) {
      case 'chat': return Icons.chat;
      case 'blog': return Icons.article;
      case 'forum': return Icons.forum;
      case 'contacts': return Icons.contacts;
      case 'events': return Icons.event;
      case 'places': return Icons.place;
      case 'news': return Icons.newspaper;
      case 'www': return Icons.language;
      case 'documents': return Icons.description;
      case 'photos': return Icons.photo_library;
      default: return Icons.folder;
    }
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.touch_app,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            _i18n.t('select_device_to_browse'),
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoDevices(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.devices_other,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            _i18n.t('no_devices_found'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _i18n.t('no_devices_hint'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildNoCollections(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_off,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            _i18n.t('no_collections_found'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _selectedDevice!.isOnline
                ? _i18n.t('device_has_no_public_collections')
                : _i18n.t('device_offline_no_cache'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
