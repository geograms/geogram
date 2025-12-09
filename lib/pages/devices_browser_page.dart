/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:math' show pow;
import 'package:flutter/material.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/station_cache_service.dart';
import '../services/chat_notification_service.dart';
import '../services/callsign_generator.dart';
import '../services/direct_message_service.dart';
import 'chat_browser_page.dart';
import 'dm_chat_page.dart';

/// Page for browsing remote devices and their collections
class DevicesBrowserPage extends StatefulWidget {
  const DevicesBrowserPage({super.key});

  @override
  State<DevicesBrowserPage> createState() => _DevicesBrowserPageState();
}

class _DevicesBrowserPageState extends State<DevicesBrowserPage> {
  final DevicesService _devicesService = DevicesService();
  final RelayCacheService _cacheService = RelayCacheService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final ChatNotificationService _chatNotificationService = ChatNotificationService();
  final DirectMessageService _dmService = DirectMessageService();

  List<RemoteDevice> _devices = [];
  String _myCallsign = '';
  RemoteDevice? _selectedDevice;
  List<RemoteCollection> _collections = [];
  bool _isLoading = true;
  bool _isLoadingCollections = false;
  String? _error;
  int _totalUnreadMessages = 0;
  Map<String, int> _dmUnreadCounts = {};
  StreamSubscription<Map<String, int>>? _unreadSubscription;
  StreamSubscription<Map<String, int>>? _dmUnreadSubscription;
  Timer? _refreshTimer;

  static const Duration _refreshInterval = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _initialize();
    _subscribeToUnreadCounts();
    _startAutoRefresh();
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (mounted && !_isLoading) {
        _refreshDevices();
      }
    });
  }

  void _subscribeToUnreadCounts() {
    _totalUnreadMessages = _chatNotificationService.totalUnreadCount;
    _unreadSubscription = _chatNotificationService.unreadCountsStream.listen((counts) {
      if (mounted) {
        setState(() {
          _totalUnreadMessages = counts.values.fold(0, (sum, count) => sum + count);
        });
      }
    });

    // Subscribe to DM unread counts
    _dmUnreadCounts = _dmService.unreadCounts;
    _dmUnreadSubscription = _dmService.unreadCountsStream.listen((counts) {
      if (mounted) {
        setState(() {
          _dmUnreadCounts = counts;
        });
      }
    });
  }

  Future<void> _initialize() async {
    setState(() => _isLoading = true);

    try {
      // Get current device's callsign to filter it out
      _myCallsign = _profileService.getProfile().callsign;

      await _devicesService.initialize();
      await _cacheService.initialize();

      // Listen to device updates - UI will update automatically as devices are discovered
      _devicesService.devicesStream.listen((devices) {
        if (mounted) {
          setState(() => _devices = _filterRemoteDevices(devices));
        }
      });

      // Initial load from cache (instant)
      _devices = _filterRemoteDevices(_devicesService.getAllDevices());

      // Start discovery in background - don't await, UI updates via stream
      // This allows the UI to show immediately with cached data
      _devicesService.refreshAllDevices();
    } catch (e) {
      LogService().log('DevicesBrowserPage: Error initializing: $e');
      _error = e.toString();
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _unreadSubscription?.cancel();
    _dmUnreadSubscription?.cancel();
    super.dispose();
  }

  /// Filter out the current device from the list
  List<RemoteDevice> _filterRemoteDevices(List<RemoteDevice> devices) {
    return devices.where((d) => d.callsign != _myCallsign).toList();
  }

  /// Refresh devices - force=true for user-initiated refresh (pull-to-refresh, button)
  Future<void> _refreshDevices({bool force = false}) async {
    // Don't show loading indicator for background refresh
    // Only update UI if there are actual changes
    final oldDevices = List<RemoteDevice>.from(_devices);

    await _devicesService.refreshAllDevices(force: force);
    final newDevices = _filterRemoteDevices(_devicesService.getAllDevices());

    // Only update state if devices changed
    if (_devicesChanged(oldDevices, newDevices)) {
      if (mounted) {
        setState(() {
          _devices = newDevices;
        });
      }
    }
  }

  /// Check if devices list has changed
  bool _devicesChanged(List<RemoteDevice> oldDevices, List<RemoteDevice> newDevices) {
    if (oldDevices.length != newDevices.length) return true;

    for (int i = 0; i < oldDevices.length; i++) {
      final oldDevice = oldDevices[i];
      final newDevice = newDevices.firstWhere(
        (d) => d.callsign == oldDevice.callsign,
        orElse: () => oldDevice,
      );

      // Check if key properties changed
      if (oldDevice.callsign != newDevice.callsign ||
          oldDevice.isOnline != newDevice.isOnline ||
          oldDevice.displayName != newDevice.displayName ||
          oldDevice.latitude != newDevice.latitude ||
          oldDevice.longitude != newDevice.longitude) {
        return true;
      }
    }

    // Check for new devices
    for (final newDevice in newDevices) {
      if (!oldDevices.any((d) => d.callsign == newDevice.callsign)) {
        return true;
      }
    }

    return false;
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
    // If the device has a direct URL, use it; otherwise construct via station proxy
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

  /// Handle system back button - return to device list if viewing detail
  void _handleBackButton() {
    if (_selectedDevice != null) {
      setState(() => _selectedDevice = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNarrow = MediaQuery.of(context).size.width < 600;

    // Handle system back button on mobile when viewing device detail
    final shouldInterceptBack = isNarrow && _selectedDevice != null;

    return PopScope(
      canPop: !shouldInterceptBack,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && shouldInterceptBack) {
          _handleBackButton();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_selectedDevice != null && isNarrow
              ? _selectedDevice!.displayName
              : _i18n.t('devices')),
          leading: _selectedDevice != null && isNarrow
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _selectedDevice = null),
                )
              : null,
          actions: [
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => _refreshDevices(force: true),
                tooltip: _i18n.t('refresh'),
              ),
          ],
        ),
        body: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
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
    // Device list with pull-to-refresh (header moved to AppBar)
    if (_devices.isEmpty) {
      return _buildNoDevices(theme);
    }

    return RefreshIndicator(
      onRefresh: () => _refreshDevices(force: true),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _devices.length,
        itemBuilder: (context, index) {
          final device = _devices[index];
          return _buildDeviceListTile(theme, device);
        },
      ),
    );
  }

  Widget _buildDeviceListTile(ThemeData theme, RemoteDevice device) {
    final isSelected = _selectedDevice?.callsign == device.callsign;
    final profile = _profileService.getProfile();
    final distanceKm = device.calculateDistance(profile.latitude, profile.longitude);
    final distanceStr = _formatDistance(device, distanceKm);
    final isStation = CallsignGenerator.isStationCallsign(device.callsign);

    return ListTile(
      selected: isSelected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: isStation
                ? theme.colorScheme.tertiaryContainer
                : theme.colorScheme.primaryContainer,
            child: Icon(
              isStation ? Icons.cell_tower : Icons.smartphone,
              color: isStation
                  ? theme.colorScheme.tertiary
                  : theme.colorScheme.primary,
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
        device.displayName,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Callsign and distance
          Row(
            children: [
              Text(
                device.callsign,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
              if (distanceStr != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    distanceStr,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // Connection methods tags and status
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              // Connection method tags
              ...device.connectionMethods.map((method) => _buildConnectionTag(
                theme,
                RemoteDevice.getConnectionMethodLabel(method),
                _getConnectionMethodColor(method),
              )),
              // Unreachable tag if offline
              if (!device.isOnline)
                _buildConnectionTag(
                  theme,
                  _i18n.t('unreachable'),
                  Colors.grey,
                ),
              // Cached indicator
              if (device.hasCachedData && !device.isOnline)
                _buildConnectionTag(
                  theme,
                  _i18n.t('cached'),
                  theme.colorScheme.primary,
                ),
            ],
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Direct message button with unread badge
          Badge(
            isLabelVisible: (_dmUnreadCounts[device.callsign] ?? 0) > 0,
            label: Text(
              (_dmUnreadCounts[device.callsign] ?? 0) > 99
                  ? '99+'
                  : '${_dmUnreadCounts[device.callsign] ?? 0}',
            ),
            child: IconButton(
              icon: Icon(
                Icons.message_outlined,
                color: theme.colorScheme.primary,
                size: 20,
              ),
              onPressed: () => _openDirectMessage(device),
              tooltip: _i18n.t('send_message'),
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

  /// Build online/offline status indicator
  Widget _buildOnlineStatus(ThemeData theme, RemoteDevice device) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
    );
  }

  /// Build a small tag widget for connection methods
  Widget _buildConnectionTag(ThemeData theme, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  /// Format distance with translations
  /// Shows distance when available, with BLE proximity as additional info
  String? _formatDistance(RemoteDevice device, double? distanceKm) {
    // Build distance string if coordinates are available
    String? distanceText;
    if (distanceKm != null) {
      if (distanceKm < 1) {
        final meters = (distanceKm * 1000).round();
        distanceText = _i18n.t('meters_away', params: [meters.toString()]);
      } else {
        distanceText = _i18n.t('kilometers_away', params: [distanceKm.toStringAsFixed(1)]);
      }
    }

    // If BLE RSSI is available, estimate distance from signal strength
    if (device.bleRssi != null) {
      final bleDistanceMeters = _estimateBleDistance(device.bleRssi!);
      final bleDistanceText = '~${bleDistanceMeters}m (BLE)';

      if (distanceText != null) {
        // If we have GPS distance, show BLE estimate as additional info
        return '$distanceText · $bleDistanceText';
      }
      return bleDistanceText;
    }

    // If BLE proximity is available but no RSSI, use it as fallback
    if (device.bleProximity != null) {
      if (distanceText != null) {
        return '$distanceText (${device.bleProximity})';
      }
      return device.bleProximity;
    }

    // If on same LAN but no coordinates, show "Same network"
    if (distanceText == null &&
        device.connectionMethods.any((m) => m.toLowerCase() == 'wifi_local' || m.toLowerCase() == 'wifi-local')) {
      return _i18n.t('same_location');
    }

    return distanceText;
  }

  /// Estimate distance in meters from BLE RSSI value
  /// Uses log-distance path loss model: distance = 10^((TxPower - RSSI) / (10 * n))
  /// TxPower: measured RSSI at 1 meter (typically -59 to -65 dBm for BLE)
  /// n: path loss exponent (2-4, using 2.5 for indoor environments)
  int _estimateBleDistance(int rssi) {
    const int txPower = -59; // Typical BLE transmit power at 1 meter
    const double pathLossExponent = 2.5; // Indoor environment

    if (rssi >= txPower) {
      return 1; // Very close, less than 1 meter
    }

    // Calculate distance using log-distance path loss model
    final ratio = (txPower - rssi) / (10 * pathLossExponent);
    final distance = pow(10, ratio).toDouble();

    // Clamp to reasonable BLE range (1-100 meters)
    return distance.clamp(1, 100).round();
  }

  /// Get color for connection method
  Color _getConnectionMethodColor(String method) {
    switch (method.toLowerCase()) {
      case 'wifi':
      case 'wifi_local':
      case 'wifi-local':
        return Colors.blue;
      case 'internet':
        return Colors.green;
      case 'bluetooth':
        return Colors.lightBlue;
      case 'lora':
        return Colors.orange;
      case 'radio':
        return Colors.purple;
      case 'esp32mesh':
      case 'esp32_mesh':
        return Colors.teal;
      case 'wifi_halow':
      case 'wifi-halow':
      case 'halow':
        return Colors.cyan;
      case 'lan':
        return Colors.blueGrey;
      default:
        return Colors.grey;
    }
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
      _devices = _filterRemoteDevices(_devicesService.getAllDevices());
      setState(() {});
    }
  }

  /// Open direct message chat with a device
  void _openDirectMessage(RemoteDevice device) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DMChatPage(
          otherCallsign: device.callsign,
        ),
      ),
    );
  }

  Widget _buildDeviceDetail(ThemeData theme) {
    final device = _selectedDevice!;
    final isStation = CallsignGenerator.isStationCallsign(device.callsign);
    final isNarrow = MediaQuery.of(context).size.width < 600;

    return Column(
      children: [
        // Device header - only show in desktop mode (AppBar handles narrow mode)
        if (!isNarrow)
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
                CircleAvatar(
                  radius: 24,
                  backgroundColor: isStation
                      ? theme.colorScheme.tertiaryContainer
                      : theme.colorScheme.primaryContainer,
                  child: Icon(
                    isStation ? Icons.cell_tower : Icons.smartphone,
                    color: isStation
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.displayName,
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
                          _buildOnlineStatus(theme, device),
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

        // Device info bar for narrow mode (since AppBar only shows name)
        if (isNarrow)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: isStation
                      ? theme.colorScheme.tertiaryContainer
                      : theme.colorScheme.primaryContainer,
                  child: Icon(
                    isStation ? Icons.cell_tower : Icons.smartphone,
                    color: isStation
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.primary,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  device.callsign,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                _buildOnlineStatus(theme, device),
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
                    isLabelVisible: collection.type == 'chat'
                        ? _totalUnreadMessages > 0
                        : collection.fileCount != null && collection.fileCount! > 0,
                    label: Text(collection.type == 'chat'
                        ? '$_totalUnreadMessages'
                        : '${collection.fileCount ?? 0}'),
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
                            _getCollectionTypeLabel(collection.type),
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
    // Check if name matches a known collection type and translate it
    final knownTypes = ['chat', 'blog', 'forum', 'contacts', 'events', 'places',
                        'news', 'www', 'postcards', 'market', 'alerts', 'groups',
                        'station', 'documents', 'photos', 'files'];
    if (knownTypes.contains(name.toLowerCase())) {
      return _getCollectionTypeLabel(name.toLowerCase());
    }
    // Fallback: capitalize first letter
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
      case 'alerts': return Icons.campaign;
      case 'market': return Icons.store;
      case 'groups': return Icons.group;
      case 'postcards': return Icons.mail;
      default: return Icons.folder;
    }
  }

  String _getCollectionTypeLabel(String type) {
    final key = 'collection_type_$type';
    final translated = _i18n.t(key);
    // If translation exists (not returning the key itself), use it
    if (translated != key) {
      return translated;
    }
    // Fallback: capitalize first letter
    if (type.isNotEmpty) {
      return type[0].toUpperCase() + type.substring(1);
    }
    return type;
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
            _i18n.t('no_apps_found'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _selectedDevice!.isOnline
                ? _i18n.t('device_has_no_public_apps')
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
