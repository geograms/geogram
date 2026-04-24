/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:math' show pow;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/device_source.dart';
import '../services/config_service.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/user_location_service.dart';
import '../services/station_cache_service.dart';
import '../services/chat_notification_service.dart';
import '../services/callsign_generator.dart';
import '../services/direct_message_service.dart';
import '../services/station_discovery_service.dart';
import '../services/station_service.dart';
import '../services/websocket_service.dart';
import '../services/network_monitor_service.dart';
import '../services/ble_discovery_service.dart';
import '../services/bluetooth_classic_pairing_service.dart';
import '../services/ble_message_service.dart';
import '../services/group_sync_service.dart';
import '../services/app_service.dart';
import '../services/debug_controller.dart';
import '../util/event_bus.dart';
import '../util/app_type_theme.dart';
import 'chat_browser_page.dart';
import 'device_detail_page.dart';
import 'remote_chat_browser_page.dart';
import 'remote_chat_room_page.dart';
import 'dm_chat_page.dart';
import 'events_browser_page.dart';
import 'report_browser_page.dart';

/// Page for browsing remote devices and their collections
class DevicesBrowserPage extends StatefulWidget {
  const DevicesBrowserPage({super.key});

  /// Static callback for handling back gesture from HomePage
  /// Returns true if back was handled (device detail was cleared)
  static bool Function()? onBackPressed;

  @override
  State<DevicesBrowserPage> createState() => _DevicesBrowserPageState();
}

class _DevicesBrowserPageState extends State<DevicesBrowserPage>
    with SingleTickerProviderStateMixin {
  final DevicesService _devicesService = DevicesService();
  final RelayCacheService _cacheService = RelayCacheService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final ChatNotificationService _chatNotificationService =
      ChatNotificationService();
  final DirectMessageService _dmService = DirectMessageService();
  final StationDiscoveryService _discoveryService = StationDiscoveryService();
  final StationService _stationService = StationService();
  final WebSocketService _wsService = WebSocketService();
  final NetworkMonitorService _networkMonitor = NetworkMonitorService();

  List<RemoteDevice> _devices = [];
  String _myCallsign = '';
  String _myDeviceId = '';
  RemoteDevice? _selectedDevice;
  List<RemoteApp> _remoteApps = [];
  bool _isLoading = true;
  bool _isLoadingApps = false;
  bool _isScanning = false;
  String? _error;
  int _totalUnreadMessages = 0;
  Map<String, int> _dmUnreadCounts = {};
  Set<String> _conversationCallsigns = {}; // Devices with chat history
  StreamSubscription<Map<String, int>>? _unreadSubscription;
  StreamSubscription<Map<String, int>>? _dmUnreadSubscription;
  StreamSubscription<dynamic>? _dmConversationsSubscription;
  Timer? _refreshTimer;

  // Multi-select mode
  bool _isMultiSelectMode = false;
  final Set<String> _selectedDeviceKeys = {};

  // Connection state subscription
  EventSubscription<ConnectionStateChangedEvent>? _connectionStateSubscription;
  EventSubscription<BLEStatusEvent>? _bleStatusSubscription;
  StreamSubscription<DebugActionEvent>? _debugActionSubscription;

  // Scan animation
  late AnimationController _refreshAnimationController;
  EventSubscription<DeviceScanEvent>? _scanEventSubscription;

  static const Duration _refreshInterval = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _refreshAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _initialize();
    _subscribeToUnreadCounts();
    _subscribeToConnectionStateChanges();
    _subscribeToBLEStatus();
    _subscribeToDebugActions();
    _subscribeToScanEvents();
    _startAutoRefresh();

    // Register back button handler for HomePage to call
    DevicesBrowserPage.onBackPressed = _handleBackFromHomePage;
  }

  void _subscribeToScanEvents() {
    _scanEventSubscription = EventBus().on<DeviceScanEvent>((event) {
      if (!mounted) return;
      if (event.isScanning) {
        _refreshAnimationController.repeat();
      } else {
        _refreshAnimationController.stop();
        _refreshAnimationController.reset();
      }
      setState(() {
        _isScanning = event.isScanning;
      });
    });
  }

  void _subscribeToDebugActions() {
    final debugController = DebugController();
    _debugActionSubscription = debugController.actionStream.listen((event) {
      if (event.action == DebugAction.openDeviceDetail ||
          event.action == DebugAction.openRemoteChatApp ||
          event.action == DebugAction.openRemoteChatRoom ||
          event.action == DebugAction.sendRemoteChatMessage) {
        final callsign = event.params['callsign'] as String?;
        final device = event.params['device'] as RemoteDevice?;

        if (callsign != null && device != null) {
          LogService().log(
            'DevicesBrowserPage: Opening device detail for $callsign via debug action ${event.action}',
          );

          // Navigate to device detail page showing available apps
          // This is the same as clicking on a device in the UI
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => DeviceDetailPage(device: device),
            ),
          );
        }
      } else if (event.action == DebugAction.openStationChat) {
        _handleOpenStationChat();
      } else if (event.action == DebugAction.openDM) {
        final callsign = event.params['callsign'] as String?;
        if (callsign != null) {
          LogService().log(
            'DevicesBrowserPage: Opening DM with $callsign via debug action',
          );
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  DMChatPage(otherCallsign: callsign.toUpperCase()),
            ),
          );
        }
      }
    });
  }

  /// Handle opening the station chat app and first chat room
  Future<void> _handleOpenStationChat() async {
    LogService().log(
      'DevicesBrowserPage: Opening station chat via debug action',
    );

    // Get the connected station
    final stationService = StationService();
    final preferred = stationService.getPreferredStation();

    if (preferred == null) {
      LogService().log('DevicesBrowserPage: No preferred station configured');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No station connected')));
      }
      return;
    }

    // Create a RemoteDevice for the station
    final stationDevice = RemoteDevice(
      callsign: preferred.callsign ?? 'STATION',
      name: preferred.name,
      url: preferred.url
          .replaceFirst('wss://', 'https://')
          .replaceFirst('ws://', 'http://'),
      description: preferred.description,
      apps: [],
      source: DeviceSourceType.station,
    );

    try {
      // Fetch chat rooms from the station using DevicesService API
      LogService().log(
        'DevicesBrowserPage: Fetching chat rooms from ${stationDevice.callsign}',
      );
      final devicesService = DevicesService();
      final response = await devicesService.makeDeviceApiRequest(
        callsign: stationDevice.callsign,
        method: 'GET',
        path: '/api/chat/rooms',
      );

      if (response == null || response.statusCode != 200) {
        throw Exception('Failed to fetch chat rooms: ${response?.statusCode}');
      }

      final data = json.decode(response.body);
      final List<dynamic> roomsData = data is Map
          ? (data['rooms'] ?? data)
          : data;

      if (roomsData.isEmpty) {
        LogService().log('DevicesBrowserPage: No chat rooms available');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No chat rooms available')),
          );
        }
        return;
      }

      // Navigate to the first chat room
      final firstRoomData = roomsData.first as Map<String, dynamic>;
      final firstRoom = ChatRoom.fromJson(firstRoomData);
      LogService().log('DevicesBrowserPage: Opening chat room ${firstRoom.id}');

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                RemoteChatRoomPage(device: stationDevice, room: firstRoom),
          ),
        );
      }
    } catch (e) {
      LogService().log('DevicesBrowserPage: Error opening station chat: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  /// Handle back button press from HomePage
  /// Returns true if we handled it (device detail was cleared)
  bool _handleBackFromHomePage() {
    if (_selectedDevice != null && MediaQuery.of(context).size.width < 600) {
      setState(() => _selectedDevice = null);
      return true;
    }
    return false;
  }

  /// Subscribe to connection state changes to refresh UI when connectivity changes
  void _subscribeToConnectionStateChanges() {
    _connectionStateSubscription = EventBus().on<ConnectionStateChangedEvent>((
      event,
    ) {
      LogService().log(
        'DevicesBrowserPage: Connection state changed - ${event.connectionType} ${event.isConnected ? "connected" : "disconnected"}',
      );
      if (mounted) {
        setState(() {
          // Trigger rebuild to update connection method tags
        });
      }
    });
  }

  /// Subscribe to BLE status events (only show errors, not routine scan messages)
  void _subscribeToBLEStatus() {
    _bleStatusSubscription = EventBus().on<BLEStatusEvent>((event) {
      if (!mounted) return;

      // Only show snackbar for errors - routine scan messages are too noisy
      if (event.status == BLEStatusType.error) {
        final message = event.message ?? _getBLEStatusMessage(event.status);
        final icon = _getBLEStatusIcon(event.status);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(icon, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(message)),
              ],
            ),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }

  String _getBLEStatusMessage(BLEStatusType status) {
    switch (status) {
      case BLEStatusType.scanning:
        return 'Scanning for nearby devices...';
      case BLEStatusType.scanComplete:
        return 'Scan complete';
      case BLEStatusType.deviceFound:
        return 'Found new device';
      case BLEStatusType.advertising:
        return 'Broadcasting...';
      case BLEStatusType.connecting:
        return 'Connecting...';
      case BLEStatusType.connected:
        return 'Connected';
      case BLEStatusType.disconnected:
        return 'Disconnected';
      case BLEStatusType.sending:
        return 'Sending data...';
      case BLEStatusType.received:
        return 'Data received';
      case BLEStatusType.error:
        return 'BLE error';
    }
  }

  IconData _getBLEStatusIcon(BLEStatusType status) {
    switch (status) {
      case BLEStatusType.scanning:
        return Icons.bluetooth_searching;
      case BLEStatusType.scanComplete:
        return Icons.bluetooth_connected;
      case BLEStatusType.deviceFound:
        return Icons.devices;
      case BLEStatusType.advertising:
        return Icons.broadcast_on_personal;
      case BLEStatusType.connecting:
        return Icons.bluetooth;
      case BLEStatusType.connected:
        return Icons.bluetooth_connected;
      case BLEStatusType.disconnected:
        return Icons.bluetooth_disabled;
      case BLEStatusType.sending:
        return Icons.upload;
      case BLEStatusType.received:
        return Icons.download;
      case BLEStatusType.error:
        return Icons.error_outline;
    }
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
    _unreadSubscription = _chatNotificationService.unreadCountsStream.listen((
      counts,
    ) {
      if (mounted) {
        setState(() {
          _totalUnreadMessages = counts.values.fold(
            0,
            (sum, count) => sum + count,
          );
        });
      }
    });

    // Subscribe to DM unread counts and track conversation callsigns
    _dmUnreadCounts = _dmService.unreadCounts;
    _conversationCallsigns = _dmService.conversationCallsigns;
    _dmUnreadSubscription = _dmService.unreadCountsStream.listen((counts) {
      if (mounted) {
        setState(() {
          _dmUnreadCounts = counts;
          _conversationCallsigns = _dmService.conversationCallsigns;
        });
      }
    });

    // Subscribe to conversations stream to update when conversations are loaded
    _dmConversationsSubscription = _dmService.conversationsStream.listen((_) {
      if (mounted) {
        setState(() {
          _conversationCallsigns = _dmService.conversationCallsigns;
        });
      }
    });
  }

  Future<void> _initialize() async {
    setState(() => _isLoading = true);

    try {
      // Get current device's callsign and per-install device id so we can
      // filter out only this physical device — peers running the same
      // callsign on other installs must remain visible in the list.
      _myCallsign = _profileService.getProfile().callsign;
      _myDeviceId = ConfigService().deviceId;

      await _devicesService.initialize();
      await _cacheService.initialize();
      await _dmService.initialize();

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
    _refreshAnimationController.dispose();
    _refreshTimer?.cancel();
    _unreadSubscription?.cancel();
    _dmUnreadSubscription?.cancel();
    _dmConversationsSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _bleStatusSubscription?.cancel();
    _debugActionSubscription?.cancel();
    _scanEventSubscription?.cancel();
    // Clear back button handler
    DevicesBrowserPage.onBackPressed = null;
    super.dispose();
  }

  /// Filter out only this physical device from the list. Other installs that
  /// share the active callsign (e.g. the same profile running on a phone on
  /// the LAN) must remain visible — they are distinguished by deviceId.
  List<RemoteDevice> _filterRemoteDevices(List<RemoteDevice> devices) {
    final myCallsign = _myCallsign.toUpperCase();
    final filtered = devices.where((d) {
      if (d.callsign.toUpperCase() != myCallsign) return true;
      // Same callsign as us: keep only when it's clearly a different install.
      return d.deviceId != null &&
          d.deviceId!.isNotEmpty &&
          d.deviceId != _myDeviceId;
    }).toList();

    // Augment with synthetic offline rows for any callsign we have chat
    // history with but that is no longer in the discovered list (e.g. it
    // was pruned by an older build before the cleanup exemption landed).
    // Without this, the DM entry point disappears for offline contacts.
    final present = filtered.map((d) => d.callsign.toUpperCase()).toSet();
    for (final callsign in _dmService.conversationCallsigns) {
      final upper = callsign.toUpperCase();
      if (upper == myCallsign) continue;
      if (present.contains(upper)) continue;
      filtered.add(
        RemoteDevice(
          callsign: callsign,
          name: callsign,
          isOnline: false,
          apps: const [],
        ),
      );
    }

    return _normalizeDevicesForDisplay(filtered);
  }

  List<RemoteDevice> _getDisplayDevicesInFolder(String? folderId) {
    final targetFolderId = folderId ?? DevicesService.defaultFolderId;
    return _devices.where((device) {
      final deviceFolderId = device.folderId ?? DevicesService.defaultFolderId;
      return deviceFolderId == targetFolderId;
    }).toList();
  }

  List<RemoteDevice> _normalizeDevicesForDisplay(List<RemoteDevice> devices) {
    final devicesByCallsign = <String, List<RemoteDevice>>{};

    for (final device in devices) {
      final callsign = device.callsign.toUpperCase();
      devicesByCallsign.putIfAbsent(callsign, () => []).add(device);
    }

    final normalized = <RemoteDevice>[];
    for (final callsignDevices in devicesByCallsign.values) {
      normalized.addAll(_normalizeSameCallsignDevices(callsignDevices));
    }
    return normalized;
  }

  List<RemoteDevice> _normalizeSameCallsignDevices(List<RemoteDevice> devices) {
    final specificBuckets = <String, List<RemoteDevice>>{};
    final legacyBuckets = <String, List<RemoteDevice>>{};

    for (final device in devices) {
      final specificKey = _specificDisplayIdentityKey(device);
      if (specificKey != null) {
        specificBuckets.putIfAbsent(specificKey, () => []).add(device);
      } else {
        legacyBuckets.putIfAbsent(
          _legacyDisplayIdentityKey(device),
          () => [],
        ).add(device);
      }
    }

    final normalizedSpecific = specificBuckets.values
        .map(_mergeDevicesForDisplay)
        .toList();

    if (normalizedSpecific.isEmpty) {
      return legacyBuckets.values.map(_mergeDevicesForDisplay).toList();
    }

    for (final legacyDevices in legacyBuckets.values) {
      final legacyDevice = _mergeDevicesForDisplay(legacyDevices);
      final targetIndex = _findLegacyMergeTarget(
        normalizedSpecific,
        legacyDevice,
      );
      normalizedSpecific[targetIndex] = _mergeDevicesForDisplay([
        normalizedSpecific[targetIndex],
        legacyDevice,
      ]);
    }

    return normalizedSpecific;
  }

  String? _specificDisplayIdentityKey(RemoteDevice device) {
    final callsign = device.callsign.toUpperCase();
    final deviceId = device.deviceId?.trim();
    if (deviceId != null && deviceId.isNotEmpty) {
      return '$callsign:device:$deviceId';
    }

    final nickname = _normalizedNicknameIdentity(device);
    if (nickname != null) {
      final platform = (device.platform ?? '').trim().toLowerCase();
      return '$callsign:nickname:$nickname:$platform';
    }

    return null;
  }

  String _legacyDisplayIdentityKey(RemoteDevice device) {
    final callsign = device.callsign.toUpperCase();
    final platform = (device.platform ?? '').trim().toLowerCase();
    return '$callsign:legacy:$platform';
  }

  String? _normalizedNicknameIdentity(RemoteDevice device) {
    final nickname = device.nickname?.trim();
    if (nickname == null || nickname.isEmpty) {
      return null;
    }
    if (nickname.toUpperCase() == device.callsign.toUpperCase()) {
      return null;
    }
    return nickname.toLowerCase();
  }

  int _findLegacyMergeTarget(
    List<RemoteDevice> specificDevices,
    RemoteDevice legacyDevice,
  ) {
    var bestIndex = 0;
    var bestScore = -1;

    for (var i = 0; i < specificDevices.length; i++) {
      final candidate = specificDevices[i];
      var score = 0;

      if (candidate.isOnline) score += 100;
      if (candidate.hasLocalConnection) score += 50;
      if (_samePlatform(candidate, legacyDevice)) score += 25;
      if (_sameNickname(candidate, legacyDevice)) score += 20;
      if (candidate.deviceId != null && candidate.deviceId!.isNotEmpty) {
        score += 10;
      }

      if (score > bestScore) {
        bestScore = score;
        bestIndex = i;
      }
    }

    return bestIndex;
  }

  bool _samePlatform(RemoteDevice a, RemoteDevice b) {
    final aPlatform = a.platform?.trim().toLowerCase();
    final bPlatform = b.platform?.trim().toLowerCase();
    return aPlatform != null &&
        bPlatform != null &&
        aPlatform.isNotEmpty &&
        aPlatform == bPlatform;
  }

  bool _sameNickname(RemoteDevice a, RemoteDevice b) {
    final aNickname = _normalizedNicknameIdentity(a);
    final bNickname = _normalizedNicknameIdentity(b);
    return aNickname != null && bNickname != null && aNickname == bNickname;
  }

  String _displayDeviceKey(RemoteDevice device) {
    return _specificDisplayIdentityKey(device) ??
        _legacyDisplayIdentityKey(device);
  }

  List<String> _selectedCallsigns() {
    final selected = <String>[];
    final seen = <String>{};

    for (final device in _devices) {
      if (_selectedDeviceKeys.contains(_displayDeviceKey(device)) &&
          seen.add(device.callsign)) {
        selected.add(device.callsign);
      }
    }

    return selected;
  }

  bool _hasMultipleDevicesForCallsign(String callsign) {
    return _devices.where((device) => device.callsign == callsign).length > 1;
  }

  String? _formatPlatformLabel(String? platform) {
    switch (platform?.trim().toLowerCase()) {
      case 'android':
        return 'Android';
      case 'linux':
        return 'Linux';
      case 'ios':
        return 'iOS';
      case 'macos':
        return 'macOS';
      case 'windows':
        return 'Windows';
      default:
        return null;
    }
  }

  RemoteDevice _mergeDevicesForDisplay(List<RemoteDevice> candidates) {
    if (candidates.length == 1) {
      final candidate = candidates.first;
      return RemoteDevice(
        callsign: candidate.callsign,
        name: candidate.name,
        nickname: candidate.nickname,
        url: candidate.url,
        npub: candidate.npub,
        isOnline: candidate.isOnline,
        latency: candidate.latency,
        lastChecked: candidate.lastChecked,
        lastSeen: candidate.lastSeen,
        lastFetched: candidate.lastFetched,
        hasCachedData: candidate.hasCachedData,
        apps: List<RemoteApp>.from(candidate.apps),
        latitude: candidate.latitude,
        longitude: candidate.longitude,
        connectionMethods: List<String>.from(candidate.connectionMethods),
        source: candidate.source,
        bleProximity: candidate.bleProximity,
        bleRssi: candidate.bleRssi,
        preferredColor: candidate.preferredColor,
        description: candidate.description,
        platform: candidate.platform,
        isPinned: candidate.isPinned,
        folderId: candidate.folderId,
        deviceId: candidate.deviceId,
        udpIp: candidate.udpIp,
        udpPort: candidate.udpPort,
        canRelay: candidate.canRelay,
        relayUrl: candidate.relayUrl,
        relayHttpPort: candidate.relayHttpPort,
      );
    }

    final preferred = _selectPreferredDisplayDevice(candidates);
    final orderedCandidates = [
      preferred,
      ...candidates.where((device) => !identical(device, preferred)),
    ];

    final mergedMethods = <String>[];
    final seenMethods = <String>{};
    for (final candidate in orderedCandidates) {
      for (final method in candidate.connectionMethods) {
        final normalized = method.toLowerCase();
        if (seenMethods.add(normalized)) {
          mergedMethods.add(method);
        }
      }
    }

    final mergedApps = preferred.apps.isNotEmpty
        ? preferred.apps
        : orderedCandidates.expand((device) => device.apps).toList();

    return RemoteDevice(
      callsign: preferred.callsign,
      name:
          _firstNonEmptyString(
            orderedCandidates.map((device) => device.name),
          ) ??
          preferred.callsign,
      nickname: _firstNonEmptyString(
        orderedCandidates.map((device) => device.nickname),
      ),
      url: _firstNonEmptyString(orderedCandidates.map((device) => device.url)),
      npub: _firstNonEmptyString(
        orderedCandidates.map((device) => device.npub),
      ),
      isOnline: candidates.any((device) => device.isOnline),
      latency: _lowestInt(orderedCandidates.map((device) => device.latency)),
      lastChecked: _latestDateTime(
        orderedCandidates.map((device) => device.lastChecked),
      ),
      lastSeen: _latestDateTime(
        orderedCandidates.map((device) => device.lastSeen),
      ),
      lastFetched: _latestDateTime(
        orderedCandidates.map((device) => device.lastFetched),
      ),
      hasCachedData: candidates.any((device) => device.hasCachedData),
      apps: mergedApps,
      latitude: _firstNonNull(
        orderedCandidates.map((device) => device.latitude),
      ),
      longitude: _firstNonNull(
        orderedCandidates.map((device) => device.longitude),
      ),
      connectionMethods: mergedMethods,
      source: preferred.source,
      bleProximity: _firstNonEmptyString(
        orderedCandidates.map((device) => device.bleProximity),
      ),
      bleRssi: _firstNonNull(orderedCandidates.map((device) => device.bleRssi)),
      preferredColor: _firstNonEmptyString(
        orderedCandidates.map((device) => device.preferredColor),
      ),
      description: _firstNonEmptyString(
        orderedCandidates.map((device) => device.description),
      ),
      platform: _firstNonEmptyString(
        orderedCandidates.map((device) => device.platform),
      ),
      isPinned: candidates.any((device) => device.isPinned),
      folderId: _firstNonEmptyString(
        orderedCandidates.map((device) => device.folderId),
      ),
      deviceId: preferred.deviceId,
      udpIp: _firstNonEmptyString(
        orderedCandidates.map((device) => device.udpIp),
      ),
      udpPort: _firstNonNull(orderedCandidates.map((device) => device.udpPort)),
      canRelay: candidates.any((device) => device.canRelay),
      relayUrl: _firstNonEmptyString(
        orderedCandidates.map((device) => device.relayUrl),
      ),
      relayHttpPort: _firstNonNull(
        orderedCandidates.map((device) => device.relayHttpPort),
      ),
    );
  }

  RemoteDevice _selectPreferredDisplayDevice(List<RemoteDevice> candidates) {
    var best = candidates.first;
    var bestScore = _displayPreferenceScore(best);

    for (final candidate in candidates.skip(1)) {
      final score = _displayPreferenceScore(candidate);
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }

    return best;
  }

  int _displayPreferenceScore(RemoteDevice device) {
    var score = 0;

    if (device.isOnline) score += 100;
    if (device.nickname?.isNotEmpty ?? false) score += 30;
    if (device.name.isNotEmpty &&
        device.name.toUpperCase() != device.callsign.toUpperCase()) {
      score += 20;
    }
    if (device.hasLocalConnection) score += 15;
    if (device.connectionMethods.any((m) => m.toLowerCase() == 'internet')) {
      score += 10;
    }
    if (device.url?.isNotEmpty ?? false) score += 8;
    if (device.apps.isNotEmpty) score += 6;
    if (device.platform?.isNotEmpty ?? false) score += 4;
    if (device.preferredColor?.isNotEmpty ?? false) score += 2;
    if (device.description?.isNotEmpty ?? false) score += 2;
    if (device.hasCachedData) score += 1;

    return score;
  }

  String? _firstNonEmptyString(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  T? _firstNonNull<T>(Iterable<T?> values) {
    for (final value in values) {
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  int? _lowestInt(Iterable<int?> values) {
    int? result;
    for (final value in values) {
      if (value == null) continue;
      if (result == null || value < result) {
        result = value;
      }
    }
    return result;
  }

  DateTime? _latestDateTime(Iterable<DateTime?> values) {
    DateTime? latest;
    for (final value in values) {
      if (value == null) continue;
      if (latest == null || value.isAfter(latest)) {
        latest = value;
      }
    }
    return latest;
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
  bool _devicesChanged(
    List<RemoteDevice> oldDevices,
    List<RemoteDevice> newDevices,
  ) {
    if (oldDevices.length != newDevices.length) return true;

    final oldByKey = {
      for (final device in oldDevices) _displayDeviceKey(device): device,
    };
    final newByKey = {
      for (final device in newDevices) _displayDeviceKey(device): device,
    };

    if (oldByKey.length != newByKey.length) return true;

    for (final entry in oldByKey.entries) {
      final oldDevice = entry.value;
      final newDevice = newByKey[entry.key];
      if (newDevice == null) {
        return true;
      }

      // Check if key properties changed
      if (oldDevice.callsign != newDevice.callsign ||
          oldDevice.isOnline != newDevice.isOnline ||
          oldDevice.displayName != newDevice.displayName ||
          oldDevice.folderId != newDevice.folderId ||
          oldDevice.latitude != newDevice.latitude ||
          oldDevice.longitude != newDevice.longitude ||
          !_sameConnectionMethods(
            oldDevice.connectionMethods,
            newDevice.connectionMethods,
          )) {
        return true;
      }
    }

    return false;
  }

  bool _sameConnectionMethods(List<String> a, List<String> b) {
    final aMethods = a.map((method) => method.toLowerCase()).toSet();
    final bMethods = b.map((method) => method.toLowerCase()).toSet();
    if (aMethods.length != bMethods.length) return false;
    return aMethods.containsAll(bMethods);
  }

  /// Full scan: localhost ports, LAN, and connect to preferred station
  /// This is triggered by the Refresh button
  Future<void> _scanAndRefresh() async {
    if (_isScanning) return;

    setState(() => _isScanning = true);
    LogService().log(
      'DevicesBrowserPage: Starting full scan (localhost, LAN, station)',
    );

    try {
      // Step 1: Run network discovery scan (includes localhost and LAN)
      // This scans localhost ports, and LAN for devices
      LogService().log(
        'DevicesBrowserPage: Step 1 - Running network discovery scan',
      );
      await _discoveryService.discover();

      // Step 2: Try to connect to preferred station if not already connected
      LogService().log(
        'DevicesBrowserPage: Step 2 - Checking station connection',
      );
      final connectedStation = _stationService.getConnectedStation();
      if (connectedStation == null || !connectedStation.isConnected) {
        // Find preferred station
        final allStations = _stationService.getAllStations();
        final preferredStation = allStations
            .where((s) => s.status == 'preferred')
            .firstOrNull;

        if (preferredStation != null) {
          LogService().log(
            'DevicesBrowserPage: Connecting to preferred station: ${preferredStation.name}',
          );
          await _stationService.connectStation(preferredStation.url);
        } else if (allStations.isNotEmpty) {
          // Connect to first available station if no preferred
          LogService().log(
            'DevicesBrowserPage: Connecting to first available station: ${allStations.first.name}',
          );
          await _stationService.connectStation(allStations.first.url);
        }
      }

      // Step 3: Refresh device list (fetches from station and checks reachability)
      LogService().log('DevicesBrowserPage: Step 3 - Refreshing device list');
      await _devicesService.refreshAllDevices(force: true);

      // Update local device list
      _devices = _filterRemoteDevices(_devicesService.getAllDevices());
      LogService().log(
        'DevicesBrowserPage: Full scan complete, found ${_devices.length} devices',
      );
    } catch (e) {
      LogService().log('DevicesBrowserPage: Error during scan: $e');
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  Future<void> _selectDevice(RemoteDevice device) async {
    // Navigate to device detail page showing available apps
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => DeviceDetailPage(device: device)),
    );
  }

  void _openCollection(RemoteApp collection) {
    // Handle different collection types
    switch (collection.type) {
      case 'chat':
        _openChatCollection(collection);
        break;
      case 'events':
        _openEventsCollection(collection);
        break;
      case 'alerts':
        _openAlertsCollection(collection);
        break;
      default:
        _showCollectionInfo(collection);
    }
  }

  void _openChatCollection(RemoteApp collection) {
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

    LogService().log(
      'DevicesBrowserPage: Opening chat for ${_selectedDevice!.callsign} at $remoteUrl',
    );

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

  void _openEventsCollection(RemoteApp collection) {
    if (_selectedDevice == null) return;

    // Build the remote device URL
    String remoteUrl = _selectedDevice!.url ?? '';

    // Convert WebSocket URL to HTTP URL for API calls
    if (remoteUrl.startsWith('ws://')) {
      remoteUrl = remoteUrl.replaceFirst('ws://', 'http://');
    } else if (remoteUrl.startsWith('wss://')) {
      remoteUrl = remoteUrl.replaceFirst('wss://', 'https://');
    }

    LogService().log(
      'DevicesBrowserPage: Opening events for ${_selectedDevice!.callsign} at $remoteUrl',
    );

    // Navigate to the EventsBrowserPage with remote device parameters
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => EventsBrowserPage(
          remoteDeviceUrl: remoteUrl,
          remoteDeviceCallsign: _selectedDevice!.callsign,
          remoteDeviceName: _selectedDevice!.name,
        ),
      ),
    );
  }

  void _openAlertsCollection(RemoteApp collection) {
    if (_selectedDevice == null) return;

    // Build the remote device URL
    String remoteUrl = _selectedDevice!.url ?? '';

    // Convert WebSocket URL to HTTP URL for API calls
    if (remoteUrl.startsWith('ws://')) {
      remoteUrl = remoteUrl.replaceFirst('ws://', 'http://');
    } else if (remoteUrl.startsWith('wss://')) {
      remoteUrl = remoteUrl.replaceFirst('wss://', 'https://');
    }

    LogService().log(
      'DevicesBrowserPage: Opening alerts for ${_selectedDevice!.callsign} at $remoteUrl',
    );

    // Navigate to the ReportBrowserPage with remote device parameters
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReportBrowserPage(
          remoteDeviceUrl: remoteUrl,
          remoteDeviceCallsign: _selectedDevice!.callsign,
          remoteDeviceName: _selectedDevice!.name,
        ),
      ),
    );
  }

  void _showCollectionInfo(RemoteApp collection) {
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

    // Calculate total device counts for title
    final allDevices = _devices;
    final totalDeviceCount = allDevices.length;
    final activeDeviceCount = allDevices.where((d) => d.isOnline).length;

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
          title: _isMultiSelectMode
              ? Text(
                  _i18n.t(
                    'selected_count',
                    params: [_selectedDeviceKeys.length.toString()],
                  ),
                )
              : (_selectedDevice != null && isNarrow
                    ? Text(_selectedDevice!.displayName)
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_i18n.t('devices')),
                          const SizedBox(width: 8),
                          Text(
                            '(',
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            '$activeDeviceCount',
                            style: TextStyle(
                              color: activeDeviceCount > 0
                                  ? Colors.green
                                  : theme.colorScheme.onSurfaceVariant,
                              fontWeight: activeDeviceCount > 0
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          Text(
                            '/$totalDeviceCount)',
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      )),
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
              RotationTransition(
                turns: _refreshAnimationController,
                child: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _isScanning ? null : _scanAndRefresh,
                  tooltip: _i18n.t('refresh'),
                ),
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
                        _isMultiSelectMode
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _isMultiSelectMode
                            ? _i18n.t('exit_selection')
                            : _i18n.t('select_multiple'),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'move_to_folder',
                  enabled: _isMultiSelectMode && _selectedDeviceKeys.isNotEmpty,
                  child: Row(
                    children: [
                      Icon(
                        Icons.drive_file_move_outlined,
                        size: 20,
                        color:
                            _isMultiSelectMode &&
                                _selectedDeviceKeys.isNotEmpty
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.38,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _i18n.t('move_to_folder'),
                        style: TextStyle(
                          color:
                              _isMultiSelectMode &&
                                  _selectedDeviceKeys.isNotEmpty
                              ? null
                              : theme.colorScheme.onSurface.withValues(
                                  alpha: 0.38,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'delete_selected',
                  enabled: _isMultiSelectMode && _selectedDeviceKeys.isNotEmpty,
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline,
                        size: 20,
                        color:
                            _isMultiSelectMode &&
                                _selectedDeviceKeys.isNotEmpty
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.38,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _i18n.t('delete_selected'),
                        style: TextStyle(
                          color:
                              _isMultiSelectMode &&
                                  _selectedDeviceKeys.isNotEmpty
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurface.withValues(
                                  alpha: 0.38,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_devicesService.getRemovedDevices().isNotEmpty) ...[
                  const PopupMenuDivider(),
                  PopupMenuItem<String>(
                    value: 'restore_removed',
                    child: Row(
                      children: [
                        Icon(
                          Icons.restore,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Text(_i18n.t('restore_removed')),
                      ],
                    ),
                  ),
                ],
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
            FilledButton(onPressed: _initialize, child: Text(_i18n.t('retry'))),
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
            SizedBox(width: 300, child: _buildDeviceList(theme)),
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
    final devicesInFolder = _getDisplayDevicesInFolder(
      folder.id == DevicesService.defaultFolderId ? null : folder.id,
    );
    final isExpanded = folder.isExpanded;
    final deviceCount = devicesInFolder.length;
    final activeCount = devicesInFolder.where((d) => d.isOnline).length;

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
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.5,
            ),
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
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.5,
                      ),
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
                    folder.isDefault
                        ? _i18n.t('discovered_folder')
                        : folder.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                // Device count badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$activeCount',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: activeCount > 0
                              ? Colors.green
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight: activeCount > 0
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      Text(
                        '/$deviceCount',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // Chat icon for non-default folders with chat enabled
                if (!folder.isDefault && folder.chatEnabled)
                  IconButton(
                    icon: Icon(
                      Icons.message_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    onPressed: () => _openFolderChat(folder),
                    tooltip: _i18n.t('open_group_chat'),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
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
                            Icon(
                              Icons.edit_outlined,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
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
                              color: deviceCount > 0
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface.withValues(
                                      alpha: 0.38,
                                    ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _i18n.t('empty_folder'),
                              style: TextStyle(
                                color: deviceCount > 0
                                    ? null
                                    : theme.colorScheme.onSurface.withValues(
                                        alpha: 0.38,
                                      ),
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
                            Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: theme.colorScheme.error,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _i18n.t('delete_folder'),
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ],
                        ),
                      ),
                    // Toggle chat for non-default folders
                    if (!folder.isDefault)
                      PopupMenuItem<String>(
                        value: folder.chatEnabled
                            ? 'disable_chat'
                            : 'enable_chat',
                        child: Row(
                          children: [
                            Icon(
                              folder.chatEnabled
                                  ? Icons.chat_bubble
                                  : Icons.chat_bubble_outline,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              folder.chatEnabled
                                  ? _i18n.t('disable_chat')
                                  : _i18n.t('enable_chat'),
                            ),
                          ],
                        ),
                      ),
                    if (deviceCount > 0)
                      PopupMenuItem<String>(
                        value: 'select_all',
                        child: Row(
                          children: [
                            Icon(
                              Icons.select_all,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Text(_i18n.t('select_all')),
                          ],
                        ),
                      ),
                    // Remove disconnected option - available when there are offline devices
                    if (devicesInFolder.any((d) => !d.isOnline))
                      PopupMenuItem<String>(
                        value: 'remove_disconnected',
                        child: Row(
                          children: [
                            Icon(
                              Icons.delete_sweep_outlined,
                              size: 20,
                              color: theme.colorScheme.error,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _i18n.t('remove_disconnected'),
                              style: TextStyle(color: theme.colorScheme.error),
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
        // Devices in folder (when expanded)
        if (isExpanded)
          ...devicesInFolder.map(
            (device) => DragTarget<String>(
              onWillAcceptWithDetails: (details) => true,
              onAcceptWithDetails: (details) {
                _devicesService.moveDeviceToFolder(
                  details.data,
                  folder.id == DevicesService.defaultFolderId
                      ? null
                      : folder.id,
                );
                setState(() {});
              },
              builder: (context, candidateData, rejectedData) {
                return LongPressDraggable<String>(
                  data: device.callsign,
                  delay: const Duration(milliseconds: 300),
                  onDragStarted: () {
                    // Haptic feedback when drag starts (works on Android/iOS)
                    HapticFeedback.mediumImpact();
                  },
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
                          Icon(
                            _getDeviceIcon(device),
                            color: theme.colorScheme.primary,
                          ),
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
            ),
          ),
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
                      ? theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.3,
                        )
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
        final devices = _getDisplayDevicesInFolder(
          folder.id == DevicesService.defaultFolderId ? null : folder.id,
        );
        setState(() {
          _isMultiSelectMode = true;
          for (final device in devices) {
            _selectedDeviceKeys.add(_displayDeviceKey(device));
          }
        });
        break;
      case 'remove_disconnected':
        await _confirmRemoveDisconnected(folder);
        break;
      case 'enable_chat':
        _devicesService.setFolderChatEnabled(folder.id, true);
        // Trigger chat room creation
        GroupSyncService().ensureFolderChatRooms();
        setState(() {});
        break;
      case 'disable_chat':
        _devicesService.setFolderChatEnabled(folder.id, false);
        setState(() {});
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
          decoration: InputDecoration(labelText: _i18n.t('folder_name')),
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

    if (result != null &&
        result.trim().isNotEmpty &&
        result.trim() != folder.name) {
      _devicesService.renameFolder(folder.id, result.trim());
      setState(() {});
    }
  }

  /// Confirm emptying a folder
  Future<void> _confirmEmptyFolder(DeviceFolder folder) async {
    final deviceCount = _getDisplayDevicesInFolder(folder.id).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('empty_folder')),
        content: Text(
          _i18n.t(
            'empty_folder_confirm',
            params: [folder.name, deviceCount.toString()],
          ),
        ),
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
    final deviceCount = _getDisplayDevicesInFolder(folder.id).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_folder')),
        content: Text(
          _i18n.t(
            'delete_folder_confirm',
            params: [folder.name, deviceCount.toString()],
          ),
        ),
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

  /// Confirm removing all disconnected devices from a folder
  Future<void> _confirmRemoveDisconnected(DeviceFolder folder) async {
    final devices = _getDisplayDevicesInFolder(
      folder.id == DevicesService.defaultFolderId ? null : folder.id,
    );
    final offlineDevices = devices.where((d) => !d.isOnline).toList();
    final offlineCount = offlineDevices.length;

    if (offlineCount == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('remove_disconnected')),
        content: Text(
          _i18n.t(
            'remove_disconnected_confirm',
            params: [offlineCount.toString()],
          ),
        ),
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
      for (final device in offlineDevices) {
        await _devicesService.removeDevice(device.callsign, permanent: true);
        if (_selectedDevice?.callsign == device.callsign) {
          _selectedDevice = null;
        }
      }
      _devices = _filterRemoteDevices(_devicesService.getAllDevices());
      setState(() {});
    }
  }

  Widget _buildDeviceListTile(ThemeData theme, RemoteDevice device) {
    final isSelected = _selectedDevice?.callsign == device.callsign;
    final isChecked = _selectedDeviceKeys.contains(_displayDeviceKey(device));
    final profile = _profileService.getProfile();

    // Get user location with UserLocationService fallback
    double? userLat = profile.latitude;
    double? userLon = profile.longitude;
    if (userLat == null || userLon == null) {
      final userLocation = UserLocationService().currentLocation;
      if (userLocation != null && userLocation.isValid) {
        userLat = userLocation.latitude;
        userLon = userLocation.longitude;
      }
    }

    final distanceKm = device.calculateDistance(userLat, userLon);
    final distanceStr = _formatDistance(device, distanceKm);
    final isStation = CallsignGenerator.isStationCallsign(device.callsign);
    final accountHasMultipleDevices = _hasMultipleDevicesForCallsign(
      device.callsign,
    );
    final platformLabel = accountHasMultipleDevices
        ? _formatPlatformLabel(device.platform)
        : null;
    final connectionTags = <Widget>[
      if (device.isOnline)
        ..._getDeduplicatedConnectionTags(device.connectionMethods).map(
          (method) => _buildConnectionTag(
            theme,
            RemoteDevice.getConnectionMethodLabel(method),
            _getConnectionMethodColor(method),
          ),
        ),
      if (device.hasCachedData && !device.isOnline)
        _buildConnectionTag(
          theme,
          _i18n.t('cached'),
          theme.colorScheme.primary,
        ),
    ];

    void handleTap() {
      if (_isMultiSelectMode) {
        _toggleDeviceSelection(device);
      } else {
        _selectDevice(device);
      }
    }

    final tile = Material(
      color: isSelected && !_isMultiSelectMode
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
          : Colors.transparent,
      child: InkWell(
        onTap: handleTap,
        child: Padding(
          padding: const EdgeInsets.only(
            left: 16,
            right: 4,
            top: 10,
            bottom: 10,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _isMultiSelectMode
                  ? Checkbox(
                      value: isChecked,
                      onChanged: (_) => _toggleDeviceSelection(device),
                    )
                  : Stack(
                      children: [
                        CircleAvatar(
                          backgroundColor:
                              _getDeviceIconBackgroundColor(
                                device.preferredColor,
                              ) ??
                              (isStation
                                  ? theme.colorScheme.tertiaryContainer
                                  : theme.colorScheme.primaryContainer),
                          child: Icon(
                            _getDeviceIcon(device),
                            color:
                                _getDeviceIconColor(device.preferredColor) ??
                                (isStation
                                    ? theme.colorScheme.tertiary
                                    : theme.colorScheme.primary),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color:
                                  (device.isOnline &&
                                      device.connectionMethods.isNotEmpty)
                                  ? Colors.green
                                  : Colors.grey,
                              border: Border.all(
                                color: theme.colorScheme.surface,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
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
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color:
                            (device.isOnline &&
                                device.connectionMethods.isNotEmpty)
                            ? null
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            [
                              device.callsign,
                              if (platformLabel != null) platformLabel,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              color: device.isOnline
                                  ? null
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (distanceStr != null) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              distanceStr,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (connectionTags.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(spacing: 4, runSpacing: 4, children: connectionTags),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isStation &&
                      (device.isOnline ||
                          _conversationCallsigns.contains(device.callsign)))
                    Badge(
                      isLabelVisible:
                          (_dmUnreadCounts[device.callsign] ?? 0) > 0,
                      label: Text(
                        (_dmUnreadCounts[device.callsign] ?? 0) > 99
                            ? '99+'
                            : '${_dmUnreadCounts[device.callsign] ?? 0}',
                      ),
                      child: IconButton(
                        icon: Icon(
                          Icons.message_outlined,
                          color: device.isOnline
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                          size: 20,
                        ),
                        onPressed: () => _openDirectMessage(device),
                        tooltip: device.isOnline
                            ? _i18n.t('send_message')
                            : _i18n.t('view_messages'),
                      ),
                    ),
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
                        case 'move':
                          _showMoveToFolderDialog([device.callsign]);
                          break;
                        case 'delete':
                          _confirmDeleteDevice(device);
                          break;
                        case 'upgrade_ble_plus':
                          _initiateBlePlusUpgrade(device);
                          break;
                      }
                    },
                    itemBuilder: (context) {
                      return [
                        PopupMenuItem<String>(
                          value: device.isPinned ? 'unpin' : 'pin',
                          child: Row(
                            children: [
                              Icon(
                                device.isPinned
                                    ? Icons.push_pin
                                    : Icons.push_pin_outlined,
                                size: 20,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                device.isPinned
                                    ? _i18n.t('unpin')
                                    : _i18n.t('pin'),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'move',
                          child: Row(
                            children: [
                              Icon(
                                Icons.drive_file_move_outlined,
                                size: 20,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 12),
                              Text(_i18n.t('move_to_folder')),
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
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ];
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    // On desktop (non-narrow mode), wrap with GestureDetector for double-click to move
    final isDesktop = MediaQuery.of(context).size.width >= 600;
    if (isDesktop) {
      return GestureDetector(
        onDoubleTap: () => _showMoveToFolderDialog([device.callsign]),
        child: tile,
      );
    }

    return tile;
  }

  /// Build online/offline status indicator
  Widget _buildOnlineStatus(ThemeData theme, RemoteDevice device) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: (device.isOnline && device.connectionMethods.isNotEmpty)
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
              color: (device.isOnline && device.connectionMethods.isNotEmpty)
                  ? Colors.green
                  : Colors.grey,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            (device.isOnline && device.connectionMethods.isNotEmpty)
                ? _i18n.t('online')
                : _i18n.t('offline'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: (device.isOnline && device.connectionMethods.isNotEmpty)
                  ? Colors.green
                  : Colors.grey,
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
  /// BLE distance takes priority over IP-based distance (more accurate for nearby devices)
  String? _formatDistance(RemoteDevice device, double? distanceKm) {
    // If BLE RSSI is available, use it exclusively (most accurate for nearby devices)
    if (device.bleRssi != null) {
      final bleDistanceMeters = _estimateBleDistance(device.bleRssi!);
      return '(~$bleDistanceMeters m away)';
    }

    // If BLE proximity is available but no RSSI, use it
    if (device.bleProximity != null) {
      return '(${device.bleProximity})';
    }

    // Fall back to GPS/IP-based distance if no BLE info
    if (distanceKm != null) {
      if (distanceKm < 1) {
        final meters = (distanceKm * 1000).round();
        return _i18n.t('meters_away', params: [meters.toString()]);
      } else {
        return _i18n.t(
          'kilometers_away',
          params: [distanceKm.toStringAsFixed(1)],
        );
      }
    }

    // If on same LAN but no coordinates, show "Same network"
    if (device.connectionMethods.any(
      (m) => m.toLowerCase() == 'wifi_local' || m.toLowerCase() == 'wifi-local',
    )) {
      return _i18n.t('same_location');
    }

    return null;
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

  /// Filter connection methods to only show those currently available
  /// Uses NetworkMonitorService for LAN, WebSocketService for station
  /// - 'internet' requires station connection (implies internet works)
  /// - 'lan'/'wifi' requires local network interface
  /// - 'bluetooth' is always shown if present
  List<String> _filterAvailableConnectionMethods(List<String> methods) {
    final hasLan = _networkMonitor.hasLan;
    final hasStation = _wsService.isConnected;

    return methods.where((method) {
      final m = method.toLowerCase();
      // Internet-dependent methods - station connection implies internet works
      if (m == 'internet') {
        return hasStation;
      }
      // LAN/WiFi methods - need local network interface
      if (m == 'lan' || m == 'wifi' || m == 'wifi_local' || m == 'wifi-local') {
        return hasLan;
      }
      // BLE and other methods are always shown if present
      return true;
    }).toList();
  }

  /// Get connection tags filtered by availability and deduplicated by display label.
  /// Multiple internal method names (e.g., 'wifi_local', 'lan') may map to the same
  /// display label ('LAN'), so we keep only the first occurrence of each label.
  /// Prefers 'wifi_local' over 'lan' when both exist as wifi_local indicates direct
  /// local discovery while 'lan' is from station discovery.
  List<String> _getDeduplicatedConnectionTags(List<String> methods) {
    final filtered = _filterAvailableConnectionMethods(methods);
    final seenLabels = <String>{};
    final result = <String>[];

    for (final method in filtered) {
      final label = RemoteDevice.getConnectionMethodLabel(method);
      if (!seenLabels.contains(label)) {
        seenLabels.add(label);
        result.add(method);
      }
    }

    return result;
  }

  /// Get background color for device icon based on preferred color
  /// Returns null if no preferred color, so caller can use default theme colors
  Color? _getDeviceIconBackgroundColor(String? colorName) {
    if (colorName == null || colorName.isEmpty) {
      return null; // Use default theme colors
    }

    switch (colorName.toLowerCase()) {
      case 'red':
        return Colors.red.shade100;
      case 'green':
        return Colors.green.shade100;
      case 'yellow':
        return Colors.amber.shade100;
      case 'purple':
        return Colors.purple.shade100;
      case 'orange':
        return Colors.orange.shade100;
      case 'pink':
        return Colors.pink.shade100;
      case 'cyan':
        return Colors.cyan.shade100;
      case 'blue':
        return Colors.blue.shade100;
      default:
        return null; // Use default theme colors
    }
  }

  /// Get icon color for device based on preferred color
  /// Returns null if no preferred color, so caller can use default theme colors
  Color? _getDeviceIconColor(String? colorName) {
    if (colorName == null || colorName.isEmpty) {
      return null; // Use default theme colors
    }

    switch (colorName.toLowerCase()) {
      case 'red':
        return Colors.red.shade700;
      case 'green':
        return Colors.green.shade700;
      case 'yellow':
        return Colors.amber.shade700;
      case 'purple':
        return Colors.purple.shade700;
      case 'orange':
        return Colors.orange.shade700;
      case 'pink':
        return Colors.pink.shade700;
      case 'cyan':
        return Colors.cyan.shade700;
      case 'blue':
        return Colors.blue.shade700;
      default:
        return null; // Use default theme colors
    }
  }

  /// Get device icon based on platform
  /// - Station: cell_tower
  /// - Embedded (ESP32/ESP8266/Arduino): settings_input_antenna
  /// - Desktop (Linux/macOS/Windows): laptop
  /// - Mobile (Android/iOS) or unknown: smartphone
  IconData _getDeviceIcon(RemoteDevice device) {
    if (CallsignGenerator.isStationCallsign(device.callsign)) {
      return Icons.cell_tower;
    }

    final platform = device.platform?.toLowerCase() ?? '';

    // Embedded devices (ESP32, Arduino, etc.)
    if (platform == 'esp32' ||
        platform == 'esp8266' ||
        platform == 'arduino' ||
        platform == 'embedded') {
      return Icons.settings_input_antenna;
    }

    // Desktop platforms
    if (platform == 'linux' || platform == 'macos' || platform == 'windows') {
      return Icons.laptop;
    }

    return Icons.smartphone; // Default for mobile/unknown
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
      case 'bluetooth_plus':
      case 'ble_plus':
      case 'ble+':
        return Colors.blue; // Darker blue for BLE+ (premium feel)
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
      case 'usb':
      case 'usb_aoa':
        return Colors.orange;
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
      await _devicesService.removeDevice(device.callsign, permanent: true);
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
            _selectedDeviceKeys.clear();
          }
        });
        break;
      case 'delete_selected':
        if (_selectedDeviceKeys.isNotEmpty) {
          _confirmDeleteSelected();
        }
        break;
      case 'move_to_folder':
        if (_selectedDeviceKeys.isNotEmpty) {
          _showMoveToFolderDialog(_selectedCallsigns());
        }
        break;
      case 'restore_removed':
        _showRestoreRemovedDialog();
        break;
    }
  }

  /// Show dialog to restore previously removed devices
  Future<void> _showRestoreRemovedDialog() async {
    final removed = _devicesService.getRemovedDevices().toList()..sort();
    if (removed.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final currentRemoved = _devicesService.getRemovedDevices().toList()
            ..sort();
          return AlertDialog(
            title: Text(_i18n.t('restore_removed')),
            content: SizedBox(
              width: 300,
              child: currentRemoved.isEmpty
                  ? Text(_i18n.t('no_removed_devices'))
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_i18n.t('restore_removed_description')),
                        const SizedBox(height: 16),
                        ...currentRemoved.map(
                          (callsign) => ListTile(
                            dense: true,
                            title: Text(callsign),
                            trailing: IconButton(
                              icon: const Icon(Icons.restore),
                              tooltip: _i18n.t('restore'),
                              onPressed: () {
                                _devicesService.restoreDevice(callsign);
                                setDialogState(() {});
                                // If no more removed devices, close dialog
                                if (_devicesService
                                    .getRemovedDevices()
                                    .isEmpty) {
                                  Navigator.pop(context);
                                }
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_i18n.t('close')),
              ),
              if (currentRemoved.isNotEmpty)
                FilledButton(
                  onPressed: () {
                    _devicesService.restoreAllDevices();
                    Navigator.pop(context);
                  },
                  child: Text(_i18n.t('restore_all')),
                ),
            ],
          );
        },
      ),
    );
    setState(() {});
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
              ...folders.map(
                (folder) => ListTile(
                  leading: Icon(
                    folder.isDefault ? Icons.inbox : Icons.folder,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(folder.name),
                  onTap: () => Navigator.pop(
                    context,
                    folder.id == DevicesService.defaultFolderId
                        ? null
                        : folder.id,
                  ),
                ),
              ),
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
      _selectedDeviceKeys.clear();
    });
  }

  /// Toggle device selection in multi-select mode
  void _toggleDeviceSelection(RemoteDevice device) {
    final key = _displayDeviceKey(device);
    setState(() {
      if (_selectedDeviceKeys.contains(key)) {
        _selectedDeviceKeys.remove(key);
      } else {
        _selectedDeviceKeys.add(key);
      }
    });
  }

  /// Confirm and delete selected devices
  Future<void> _confirmDeleteSelected() async {
    final selectedCallsigns = _selectedCallsigns();
    final count = _selectedDeviceKeys.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_devices')),
        content: Text(
          _i18n.t('delete_devices_confirm', params: [count.toString()]),
        ),
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
      for (final callsign in selectedCallsigns) {
        await _devicesService.removeDevice(callsign, permanent: true);
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
        builder: (context) => DMChatPage(otherCallsign: device.callsign),
      ),
    );
  }

  /// Open the chat room for a device folder
  Future<void> _openFolderChat(DeviceFolder folder) async {
    // Get chat collection
    final chatCollection = AppService().getAppByType('chat');

    if (chatCollection == null || chatCollection.storagePath == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_i18n.t('chat_room_not_found'))));
      }
      return;
    }

    // Ensure chat room exists
    await GroupSyncService().ensureFolderChatRooms();

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              ChatBrowserPage(app: chatCollection, initialRoomId: folder.id),
        ),
      );
    }
  }

  /// Initiate BLE+ upgrade for a device
  ///
  /// Shows a dialog explaining the benefits and triggers the pairing process.
  void _initiateBlePlusUpgrade(RemoteDevice device) async {
    final theme = Theme.of(context);

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.bluetooth, color: Colors.blue),
            const SizedBox(width: 8),
            Text(_i18n.t('upgrade_to_ble_plus')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _i18n.t(
                'upgrade_ble_plus_description',
                params: [device.displayName],
              ),
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('benefits_of_ble_plus'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('• ${_i18n.t('ble_plus_faster_transfers')}'),
            Text('• ${_i18n.t('ble_plus_better_large_files')}'),
            Text('• ${_i18n.t('ble_plus_discovery_note')}'),
            const SizedBox(height: 16),
            Text(
              _i18n.t('ble_plus_pairing_info'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
            child: Text(_i18n.t('upgrade')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final bleDevices = BLEDiscoveryService().getAllDevices();
    final targetCallsign = device.callsign.toUpperCase();
    final bleDevice = bleDevices
        .where((d) => d.callsign?.toUpperCase() == targetCallsign)
        .firstOrNull;

    if (bleDevice == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _i18n.t('ble_plus_device_not_found', params: [device.callsign]),
            ),
            backgroundColor: theme.colorScheme.error,
          ),
        );
      }
      return;
    }

    if (bleDevice.classicMac == null) {
      final helloSuccess = await _devicesService.sendBLEHello(bleDevice);
      if (!helloSuccess) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _i18n.t('ble_plus_handshake_failed', params: [device.callsign]),
              ),
              backgroundColor: theme.colorScheme.error,
            ),
          );
        }
        return;
      }
    }

    final classicMac = bleDevice.classicMac;
    if (classicMac == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _i18n.t('ble_plus_handshake_failed', params: [device.callsign]),
            ),
            backgroundColor: theme.colorScheme.error,
          ),
        );
      }
      return;
    }

    final localClassicMac = BLEMessageService().localClassicMac;
    if (localClassicMac != null) {
      await BLEMessageService().sendBlePlusPairRequest(
        device: bleDevice,
        classicMac: localClassicMac,
      );
      LogService().log(
        'DevicesBrowserPage: Sent BLE+ pairing request to ${bleDevice.callsign ?? bleDevice.deviceId}',
      );
    } else {
      LogService().log(
        'DevicesBrowserPage: Local Classic MAC unavailable, skipping remote BLE+ prompt',
      );
    }

    final pairingService = BluetoothClassicPairingService();
    await pairingService.initialize();
    final success = await pairingService.initiatePairingFromBLE(
      callsign: targetCallsign,
      classicMac: classicMac,
      bleMac: bleDevice.deviceId,
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _i18n.t(
            success ? 'ble_plus_upgrade_initiated' : 'ble_plus_pairing_failed',
            params: [device.callsign],
          ),
        ),
        backgroundColor: success ? Colors.blue : theme.colorScheme.error,
      ),
    );

    LogService().log(
      'DevicesBrowserPage: BLE+ upgrade ${success ? "completed" : "failed"} for ${device.callsign}',
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
                    _getDeviceIcon(device),
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
                    _getDeviceIcon(device),
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
          child: _isLoadingApps
              ? const Center(child: CircularProgressIndicator())
              : _remoteApps.isEmpty
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
                      itemCount: _remoteApps.length,
                      itemBuilder: (context, index) {
                        final collection = _remoteApps[index];
                        return _buildCollectionCard(theme, collection);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildCollectionCard(ThemeData theme, RemoteApp collection) {
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
                        : collection.fileCount != null &&
                              collection.fileCount! > 0,
                    label: Text(
                      collection.type == 'chat'
                          ? '$_totalUnreadMessages'
                          : '${collection.fileCount ?? 0}',
                    ),
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

  String _getDisplayTitle(RemoteApp collection) {
    final name = collection.name;
    // Check if name matches a known collection type and translate it
    if (AppService.knownAppTypes.contains(name.toLowerCase())) {
      return _getCollectionTypeLabel(name.toLowerCase());
    }
    // Fallback: capitalize first letter
    if (name.isNotEmpty) {
      return name[0].toUpperCase() + name.substring(1);
    }
    return name;
  }

  IconData _getCollectionIcon(String type) => getAppTypeIcon(type);

  String _getCollectionTypeLabel(String type) {
    final key = 'app_type_$type';
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
          Text(_i18n.t('no_devices_found'), style: theme.textTheme.titleMedium),
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
          Text(_i18n.t('no_apps_found'), style: theme.textTheme.titleMedium),
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
