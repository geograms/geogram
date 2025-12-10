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
import '../services/station_discovery_service.dart';
import '../services/station_service.dart';
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
  final StationDiscoveryService _discoveryService = StationDiscoveryService();
  final StationService _stationService = StationService();

  List<RemoteDevice> _devices = [];
  String _myCallsign = '';
  RemoteDevice? _selectedDevice;
  List<RemoteCollection> _collections = [];
  bool _isLoading = true;
  bool _isLoadingCollections = false;
  bool _isScanning = false;
  String? _error;
  int _totalUnreadMessages = 0;
  Map<String, int> _dmUnreadCounts = {};
  StreamSubscription<Map<String, int>>? _unreadSubscription;
  StreamSubscription<Map<String, int>>? _dmUnreadSubscription;
  Timer? _refreshTimer;

  // Multi-select mode
  bool _isMultiSelectMode = false;
  final Set<String> _selectedCallsigns = {};

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

  /// Full scan: localhost ports, LAN, and connect to preferred station
  /// This is triggered by the Refresh button
  Future<void> _scanAndRefresh() async {
    if (_isScanning) return;

    setState(() => _isScanning = true);
    LogService().log('DevicesBrowserPage: Starting full scan (localhost, LAN, station)');

    try {
      // Step 1: Run network discovery scan (includes localhost and LAN)
      // This scans localhost ports, and LAN for devices
      LogService().log('DevicesBrowserPage: Step 1 - Running network discovery scan');
      await _discoveryService.discover();

      // Step 2: Try to connect to preferred station if not already connected
      LogService().log('DevicesBrowserPage: Step 2 - Checking station connection');
      final connectedStation = _stationService.getConnectedRelay();
      if (connectedStation == null || !connectedStation.isConnected) {
        // Find preferred station
        final allStations = _stationService.getAllStations();
        final preferredStation = allStations.where((s) => s.status == 'preferred').firstOrNull;

        if (preferredStation != null) {
          LogService().log('DevicesBrowserPage: Connecting to preferred station: ${preferredStation.name}');
          await _stationService.connectRelay(preferredStation.url);
        } else if (allStations.isNotEmpty) {
          // Connect to first available station if no preferred
          LogService().log('DevicesBrowserPage: Connecting to first available station: ${allStations.first.name}');
          await _stationService.connectRelay(allStations.first.url);
        }
      }

      // Step 3: Refresh device list (fetches from station and checks reachability)
      LogService().log('DevicesBrowserPage: Step 3 - Refreshing device list');
      await _devicesService.refreshAllDevices(force: true);

      // Update local device list
      _devices = _filterRemoteDevices(_devicesService.getAllDevices());
      LogService().log('DevicesBrowserPage: Full scan complete, found ${_devices.length} devices');
    } catch (e) {
      LogService().log('DevicesBrowserPage: Error during scan: $e');
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
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
          title: Text(_isMultiSelectMode
              ? _i18n.t('selected_count', params: [_selectedCallsigns.length.toString()])
              : (_selectedDevice != null && isNarrow
                  ? _selectedDevice!.displayName
                  : _i18n.t('devices'))),
          leading: _isMultiSelectMode
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _exitMultiSelectMode,
                  tooltip: _i18n.t('cancel'),
                )
              : (_selectedDevice != null && isNarrow
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => setState(() => _selectedDevice = null),
                    )
                  : null),
          actions: [
            if (_isLoading || _isScanning)
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
                onPressed: _scanAndRefresh,
                tooltip: _i18n.t('refresh'),
              ),
            // Hamburger menu for bulk actions
            PopupMenuButton<String>(
              icon: const Icon(Icons.menu),
              tooltip: _i18n.t('menu'),
              onSelected: _handleMenuAction,
              itemBuilder: (context) => [
                PopupMenuItem<String>(
                  value: 'new_folder',
                  child: Row(
                    children: [
                      Icon(
                        Icons.create_new_folder_outlined,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Text(_i18n.t('new_folder')),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem<String>(
                  value: 'select_multiple',
                  child: Row(
                    children: [
                      Icon(
                        _isMultiSelectMode ? Icons.check_box : Icons.check_box_outline_blank,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Text(_isMultiSelectMode
                          ? _i18n.t('exit_selection')
                          : _i18n.t('select_multiple')),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'move_to_folder',
                  enabled: _isMultiSelectMode && _selectedCallsigns.isNotEmpty,
                  child: Row(
                    children: [
                      Icon(
                        Icons.drive_file_move_outlined,
                        size: 20,
                        color: _isMultiSelectMode && _selectedCallsigns.isNotEmpty
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withValues(alpha: 0.38),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _i18n.t('move_to_folder'),
                        style: TextStyle(
                          color: _isMultiSelectMode && _selectedCallsigns.isNotEmpty
                              ? null
                              : theme.colorScheme.onSurface.withValues(alpha: 0.38),
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'delete_selected',
                  enabled: _isMultiSelectMode && _selectedCallsigns.isNotEmpty,
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: _isMultiSelectMode && _selectedCallsigns.isNotEmpty
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface.withValues(alpha: 0.38),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _i18n.t('delete_selected'),
                        style: TextStyle(
                          color: _isMultiSelectMode && _selectedCallsigns.isNotEmpty
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurface.withValues(alpha: 0.38),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
    final folders = _devicesService.getFolders();

    // If no devices at all, show empty state
    if (_devices.isEmpty && folders.length <= 1) {
      return _buildNoDevices(theme);
    }

    return RefreshIndicator(
      onRefresh: () => _refreshDevices(force: true),
      child: ReorderableListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: folders.length,
        buildDefaultDragHandles: false,
        onReorder: (oldIndex, newIndex) {
          if (newIndex > oldIndex) newIndex--;
          _devicesService.reorderFolders(oldIndex, newIndex);
          setState(() {});
        },
        itemBuilder: (context, index) {
          final folder = folders[index];
          return _buildFolderSection(theme, folder, index);
        },
      ),
    );
  }

  /// Build a folder section with its devices
  Widget _buildFolderSection(ThemeData theme, DeviceFolder folder, int index) {
    final devicesInFolder = _devicesService.getDevicesInFolder(
      folder.id == DevicesService.defaultFolderId ? null : folder.id,
    );
    final isExpanded = folder.isExpanded;
    final deviceCount = devicesInFolder.length;

    return Column(
      key: ValueKey(folder.id),
      children: [
        // Folder header
        InkWell(
          onTap: () {
            _devicesService.setFolderExpanded(folder.id, !isExpanded);
            setState(() {});
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Row(
              children: [
                // Drag handle for reordering
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(
                      Icons.drag_handle,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                Icon(
                  isExpanded ? Icons.expand_more : Icons.chevron_right,
                  size: 24,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Icon(
                  folder.isDefault ? Icons.inbox : Icons.folder,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    folder.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                // Device count badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '$deviceCount',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                // Folder options menu (not for default folder on some actions)
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  tooltip: _i18n.t('folder_options'),
                  onSelected: (action) => _handleFolderAction(folder, action),
                  itemBuilder: (context) => [
                    if (!folder.isDefault)
                      PopupMenuItem<String>(
                        value: 'rename',
                        child: Row(
                          children: [
                            Icon(Icons.edit_outlined, size: 20, color: theme.colorScheme.primary),
                            const SizedBox(width: 12),
                            Text(_i18n.t('rename')),
                          ],
                        ),
                      ),
                    if (!folder.isDefault)
                      PopupMenuItem<String>(
                        value: 'empty',
                        enabled: deviceCount > 0,
                        child: Row(
                          children: [
                            Icon(
                              Icons.cleaning_services_outlined,
                              size: 20,
                              color: deviceCount > 0 ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.38),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _i18n.t('empty_folder'),
                              style: TextStyle(
                                color: deviceCount > 0 ? null : theme.colorScheme.onSurface.withValues(alpha: 0.38),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (!folder.isDefault)
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline, size: 20, color: theme.colorScheme.error),
                            const SizedBox(width: 12),
                            Text(_i18n.t('delete_folder'), style: TextStyle(color: theme.colorScheme.error)),
                          ],
                        ),
                      ),
                    if (folder.isDefault && deviceCount > 0)
                      PopupMenuItem<String>(
                        value: 'select_all',
                        child: Row(
                          children: [
                            Icon(Icons.select_all, size: 20, color: theme.colorScheme.primary),
                            const SizedBox(width: 12),
                            Text(_i18n.t('select_all')),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        // Devices in folder (when expanded)
        if (isExpanded)
          ...devicesInFolder.map((device) => DragTarget<String>(
            onWillAcceptWithDetails: (details) => true,
            onAcceptWithDetails: (details) {
              _devicesService.moveDeviceToFolder(
                details.data,
                folder.id == DevicesService.defaultFolderId ? null : folder.id,
              );
              setState(() {});
            },
            builder: (context, candidateData, rejectedData) {
              return Draggable<String>(
                data: device.callsign,
                feedback: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.smartphone, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(device.displayName),
                      ],
                    ),
                  ),
                ),
                childWhenDragging: Opacity(
                  opacity: 0.5,
                  child: _buildDeviceListTile(theme, device),
                ),
                child: _buildDeviceListTile(theme, device),
              );
            },
          )),
        // Drop zone at folder level
        if (isExpanded && devicesInFolder.isEmpty)
          DragTarget<String>(
            onWillAcceptWithDetails: (details) => true,
            onAcceptWithDetails: (details) {
              _devicesService.moveDeviceToFolder(
                details.data,
                folder.id == DevicesService.defaultFolderId ? null : folder.id,
              );
              setState(() {});
            },
            builder: (context, candidateData, rejectedData) {
              return Container(
                height: 60,
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: candidateData.isNotEmpty
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline.withValues(alpha: 0.3),
                    style: BorderStyle.solid,
                    width: candidateData.isNotEmpty ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  color: candidateData.isNotEmpty
                      ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                      : null,
                ),
                child: Center(
                  child: Text(
                    _i18n.t('drop_devices_here'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  /// Handle folder menu actions
  Future<void> _handleFolderAction(DeviceFolder folder, String action) async {
    switch (action) {
      case 'rename':
        await _showRenameFolderDialog(folder);
        break;
      case 'empty':
        await _confirmEmptyFolder(folder);
        break;
      case 'delete':
        await _confirmDeleteFolder(folder);
        break;
      case 'select_all':
        final devices = _devicesService.getDevicesInFolder(
          folder.id == DevicesService.defaultFolderId ? null : folder.id,
        );
        setState(() {
          _isMultiSelectMode = true;
          for (final device in devices) {
            _selectedCallsigns.add(device.callsign);
          }
        });
        break;
    }
  }

  /// Show dialog to rename a folder
  Future<void> _showRenameFolderDialog(DeviceFolder folder) async {
    final controller = TextEditingController(text: folder.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('rename_folder')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _i18n.t('folder_name'),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(_i18n.t('save')),
          ),
        ],
      ),
    );

    if (result != null && result.trim().isNotEmpty && result.trim() != folder.name) {
      _devicesService.renameFolder(folder.id, result.trim());
      setState(() {});
    }
  }

  /// Confirm emptying a folder
  Future<void> _confirmEmptyFolder(DeviceFolder folder) async {
    final deviceCount = _devicesService.getDevicesInFolder(folder.id).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('empty_folder')),
        content: Text(_i18n.t('empty_folder_confirm', params: [folder.name, deviceCount.toString()])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('empty')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _devicesService.emptyFolder(folder.id);
      setState(() {});
    }
  }

  /// Confirm deleting a folder
  Future<void> _confirmDeleteFolder(DeviceFolder folder) async {
    final deviceCount = _devicesService.getDevicesInFolder(folder.id).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_folder')),
        content: Text(_i18n.t('delete_folder_confirm', params: [folder.name, deviceCount.toString()])),
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
      await _devicesService.deleteFolder(folder.id);
      setState(() {});
    }
  }

  Widget _buildDeviceListTile(ThemeData theme, RemoteDevice device) {
    final isSelected = _selectedDevice?.callsign == device.callsign;
    final isChecked = _selectedCallsigns.contains(device.callsign);
    final profile = _profileService.getProfile();
    final distanceKm = device.calculateDistance(profile.latitude, profile.longitude);
    final distanceStr = _formatDistance(device, distanceKm);
    final isStation = CallsignGenerator.isStationCallsign(device.callsign);

    return ListTile(
      selected: isSelected && !_isMultiSelectMode,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      leading: _isMultiSelectMode
          ? Checkbox(
              value: isChecked,
              onChanged: (_) => _toggleDeviceSelection(device.callsign),
            )
          : Stack(
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
          // Pin indicator
          if (device.isPinned)
            Positioned(
              left: 0,
              top: 0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary,
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 1.5,
                  ),
                ),
                child: Icon(
                  Icons.push_pin,
                  size: 8,
                  color: theme.colorScheme.onPrimary,
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
          // Menu button with pin and delete options
          PopupMenuButton<String>(
            icon: Icon(
              Icons.more_vert,
              color: theme.colorScheme.onSurfaceVariant,
              size: 20,
            ),
            tooltip: _i18n.t('more_options'),
            onSelected: (value) {
              switch (value) {
                case 'pin':
                  _devicesService.pinDevice(device.callsign);
                  break;
                case 'unpin':
                  _devicesService.unpinDevice(device.callsign);
                  break;
                case 'delete':
                  _confirmDeleteDevice(device);
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: device.isPinned ? 'unpin' : 'pin',
                child: Row(
                  children: [
                    Icon(
                      device.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Text(device.isPinned ? _i18n.t('unpin') : _i18n.t('pin')),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _i18n.t('delete'),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: () {
        if (_isMultiSelectMode) {
          _toggleDeviceSelection(device.callsign);
        } else {
          _selectDevice(device);
        }
      },
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

  /// Handle hamburger menu actions
  void _handleMenuAction(String action) {
    switch (action) {
      case 'new_folder':
        _showNewFolderDialog();
        break;
      case 'select_multiple':
        setState(() {
          if (_isMultiSelectMode) {
            _exitMultiSelectMode();
          } else {
            _isMultiSelectMode = true;
            _selectedCallsigns.clear();
          }
        });
        break;
      case 'delete_selected':
        if (_selectedCallsigns.isNotEmpty) {
          _confirmDeleteSelected();
        }
        break;
      case 'move_to_folder':
        if (_selectedCallsigns.isNotEmpty) {
          _showMoveToFolderDialog(_selectedCallsigns.toList());
        }
        break;
    }
  }

  /// Show dialog to create a new folder
  Future<void> _showNewFolderDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('new_folder')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _i18n.t('folder_name'),
            hintText: _i18n.t('enter_folder_name'),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(_i18n.t('create')),
          ),
        ],
      ),
    );

    if (result != null && result.trim().isNotEmpty) {
      _devicesService.createFolder(result.trim());
      setState(() {});
    }
  }

  /// Show dialog to select folder for moving devices
  Future<void> _showMoveToFolderDialog(List<String> callsigns) async {
    final folders = _devicesService.getFolders();
    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('move_to_folder')),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_i18n.t('select_destination_folder')),
              const SizedBox(height: 16),
              ...folders.map((folder) => ListTile(
                leading: Icon(
                  folder.isDefault ? Icons.inbox : Icons.folder,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(folder.name),
                onTap: () => Navigator.pop(context, folder.id == DevicesService.defaultFolderId ? null : folder.id),
              )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text(_i18n.t('cancel')),
          ),
        ],
      ),
    );

    if (result != null && result != 'cancel') {
      _devicesService.moveDevicesToFolder(callsigns, result);
      if (_isMultiSelectMode) {
        _exitMultiSelectMode();
      }
      setState(() {});
    }
  }

  /// Exit multi-select mode
  void _exitMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = false;
      _selectedCallsigns.clear();
    });
  }

  /// Toggle device selection in multi-select mode
  void _toggleDeviceSelection(String callsign) {
    setState(() {
      if (_selectedCallsigns.contains(callsign)) {
        _selectedCallsigns.remove(callsign);
      } else {
        _selectedCallsigns.add(callsign);
      }
    });
  }

  /// Confirm and delete selected devices
  Future<void> _confirmDeleteSelected() async {
    final count = _selectedCallsigns.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_devices')),
        content: Text(_i18n.t('delete_devices_confirm', params: [count.toString()])),
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
      for (final callsign in _selectedCallsigns.toList()) {
        await _devicesService.removeDevice(callsign);
        if (_selectedDevice?.callsign == callsign) {
          _selectedDevice = null;
        }
      }
      _devices = _filterRemoteDevices(_devicesService.getAllDevices());
      _exitMultiSelectMode();
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
