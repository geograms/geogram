/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import '../models/device_source.dart';
import '../models/station.dart';
import 'station_cache_service.dart';
import 'station_service.dart';
import 'station_discovery_service.dart';
import 'direct_message_service.dart';
import 'log_service.dart';
import 'ble_discovery_service.dart';
import 'ble_foreground_service.dart';
import 'ble_message_service.dart';
import 'profile_service.dart';
import 'signing_service.dart';
import 'debug_controller.dart';
import 'config_service.dart';
import 'app_args.dart';
import 'bluetooth_classic_pairing_service.dart';
import '../util/nostr_event.dart';
import '../util/event_bus.dart';
import '../models/profile.dart';
import '../connection/connection_manager.dart';
import '../connection/transports/lan_transport.dart';

/// Service for managing remote devices we've contacted
class DevicesService {
  static final DevicesService _instance = DevicesService._internal();
  factory DevicesService() => _instance;
  DevicesService._internal();

  final RelayCacheService _cacheService = RelayCacheService();
  final StationService _stationService = StationService();
  final StationDiscoveryService _discoveryService = StationDiscoveryService();

  /// BLE discovery service (null on web)
  BLEDiscoveryService? _bleService;
  StreamSubscription<List<BLEDevice>>? _bleSubscription;

  /// BLE messaging service for chat/data exchange
  BLEMessageService? _bleMessageService;
  StreamSubscription<BLEChatMessage>? _bleChatSubscription;

  /// Debug controller subscription
  StreamSubscription<DebugActionEvent>? _debugSubscription;

  /// Station connection event subscription
  EventSubscription<ConnectionStateChangedEvent>? _stationConnectionSubscription;
  EventSubscription<ProfileChangedEvent>? _profileChangedSubscription;

  /// Cache of known devices with their status
  final Map<String, RemoteDevice> _devices = {};

  /// Stream controller for device updates
  final _devicesController = StreamController<List<RemoteDevice>>.broadcast();
  Stream<List<RemoteDevice>> get devicesStream => _devicesController.stream;

  /// Stream controller for incoming BLE chat messages
  final _bleChatController = StreamController<BLEChatMessage>.broadcast();
  Stream<BLEChatMessage> get bleChatStream => _bleChatController.stream;

  /// Track when last local network scan was performed
  DateTime? _lastLocalScanTime;
  static const _localScanInterval = Duration(minutes: 5);

  /// Track when last full refresh was performed (for UI caching)
  DateTime? _lastFullRefreshTime;
  static const _fullRefreshCooldown = Duration(minutes: 1);

  /// Track initialization state to avoid re-initializing and losing online status
  bool _isInitialized = false;

  /// Initialize the service
  /// [skipBLE] - If true, skip BLE initialization (used for first-time Android users
  /// who need to see onboarding screen before permission dialogs)
  Future<void> initialize({bool skipBLE = false}) async {
    // Skip if already initialized - this preserves current device online states
    if (_isInitialized) {
      return;
    }

    await _cacheService.initialize();
    await _loadCachedDevices();

    // Skip BLE in internet-only mode
    final internetOnly = AppArgs().internetOnly;
    if (internetOnly) {
      LogService().log('DevicesService: Internet-only mode - skipping BLE initialization');
    } else if (!skipBLE) {
      await _initializeBLE();
    } else {
      LogService().log('DevicesService: BLE initialization skipped');
    }
    _subscribeToDebugActions();
    _subscribeToStationConnection();
    _subscribeToProfileChanges();

    _isInitialized = true;
  }

  /// Subscribe to station connection events to auto-update station device
  void _subscribeToStationConnection() {
    _stationConnectionSubscription?.cancel();
    _stationConnectionSubscription = EventBus().on<ConnectionStateChangedEvent>((event) {
      if (event.connectionType == ConnectionType.station && event.isConnected) {
        _updateConnectedStation(
          eventCallsign: event.stationCallsign,
          eventUrl: event.stationUrl,
        );
      }
    });
  }

  /// Subscribe to profile identity changes so BLE uses the latest callsign/keys
  void _subscribeToProfileChanges() {
    _profileChangedSubscription?.cancel();
    _profileChangedSubscription = EventBus().on<ProfileChangedEvent>(_handleProfileChanged);
  }

  Future<void> _handleProfileChanged(ProfileChangedEvent event) async {
    LogService().log('DevicesService: Profile changed to ${event.callsign}, refreshing BLE identity');

    if (AppArgs().internetOnly) {
      LogService().log('DevicesService: Internet-only mode - skipping BLE refresh');
      return;
    }

    // Only refresh if BLE was initialized (skip when permissions were denied or BLE is off)
    if (_bleService == null) {
      return;
    }

    try {
      if (_bleMessageService != null) {
        _bleChatSubscription?.cancel();
        _bleMessageService!.dispose();
        _bleMessageService = null;
      }

      await _initializeBLEMessaging();

      // For non-server platforms, restart advertising with the new callsign
      if (!BLEMessageService.canBeServer) {
        await _bleService!.stopAdvertising();
        await _startBLEAdvertisingWithCallsign(event.callsign);
      }
    } catch (e) {
      LogService().log('DevicesService: Failed to refresh BLE identity: $e');
    }
  }

  /// Initialize BLE after onboarding (for first-time Android users)
  Future<void> initializeBLEAfterOnboarding() async {
    // Don't initialize BLE in internet-only mode
    if (AppArgs().internetOnly) {
      LogService().log('DevicesService: Internet-only mode - BLE not available');
      return;
    }

    if (_bleService == null) {
      LogService().log('DevicesService: Initializing BLE after onboarding');
      await _initializeBLE();
    }
  }

  /// Subscribe to debug action events
  void _subscribeToDebugActions() {
    _debugSubscription?.cancel();
    _debugSubscription = DebugController().actionStream.listen((event) {
      _handleDebugAction(event);
    });
    LogService().log('DevicesService: Subscribed to debug actions');
  }

  /// Handle debug action events
  Future<void> _handleDebugAction(DebugActionEvent event) async {
    LogService().log('DevicesService: Handling debug action: ${event.action}');

    switch (event.action) {
      case DebugAction.bleScan:
        await _discoverBLEDevices();
        break;

      case DebugAction.bleAdvertise:
        final callsign = event.params['callsign'] as String?;
        await _startBLEAdvertisingWithCallsign(callsign);
        break;

      case DebugAction.bleHello:
        final deviceId = event.params['device_id'] as String?;
        await _sendBLEHelloToDevice(deviceId);
        break;

      case DebugAction.refreshDevices:
        await refreshAllDevices();
        break;

      case DebugAction.localNetworkScan:
        await forceLocalScan();
        break;

      case DebugAction.connectStation:
        // Station connection is handled by StationService
        LogService().log('DevicesService: Station connection handled by StationService');
        break;

      case DebugAction.disconnectStation:
        // Station disconnection is handled by StationService
        LogService().log('DevicesService: Station disconnection handled by StationService');
        break;

      case DebugAction.navigateToPanel:
        // Navigation is handled by the UI (main.dart)
        break;

      case DebugAction.showToast:
        // Toast display is handled by the UI (main.dart)
        break;

      case DebugAction.bleSend:
        final deviceId = event.params['device_id'] as String?;
        final data = event.params['data'] as String?;
        final size = event.params['size'] as int?;
        await _sendBLEDataToDevice(deviceId, data, size);
        break;

      case DebugAction.sendDM:
        final callsign = event.params['callsign'] as String?;
        final content = event.params['content'] as String?;
        if (callsign != null && content != null) {
          await _sendDirectMessage(callsign, content);
        }
        break;

      case DebugAction.syncDM:
        final callsign = event.params['callsign'] as String?;
        final url = event.params['url'] as String?;
        if (callsign != null) {
          await _syncDirectMessages(callsign, url);
        }
        break;

      case DebugAction.addDevice:
        // Handled directly by DebugController.executeAction()
        // which calls DevicesService().addDevice() directly
        break;

      case DebugAction.voiceRecord:
      case DebugAction.voiceStop:
      case DebugAction.voiceStatus:
        // Voice actions are handled directly by LogApiService
        break;

      case DebugAction.backupProviderEnable:
      case DebugAction.backupCreateTestData:
      case DebugAction.backupSendInvite:
      case DebugAction.backupAcceptInvite:
      case DebugAction.backupStart:
      case DebugAction.backupGetStatus:
      case DebugAction.backupRestore:
      case DebugAction.backupListSnapshots:
        // Backup actions are handled directly by LogApiService
        break;

      case DebugAction.openDeviceDetail:
        // Device detail page navigation is handled by DevicesBrowserPage
        break;

      case DebugAction.openRemoteChatApp:
      case DebugAction.openRemoteChatRoom:
      case DebugAction.sendRemoteChatMessage:
        // Remote chat navigation is handled by DeviceDetailPage and RemoteChatBrowserPage
        break;
    }
  }

  /// Send data to a specific BLE device for testing
  /// Uses the parcel protocol for reliable transmission of larger payloads
  Future<bool> _sendBLEDataToDevice(String? deviceId, String? data, int? size) async {
    if (_bleService == null || _bleMessageService == null) {
      LogService().log('DevicesService: BLE not available for data send');
      return false;
    }

    final devices = _bleService!.getAllDevices();
    if (devices.isEmpty) {
      LogService().log('DevicesService: No BLE devices for data send');
      return false;
    }

    // Find target device
    BLEDevice? targetDevice;
    if (deviceId != null) {
      targetDevice = devices.firstWhere(
        (d) => d.deviceId == deviceId || d.callsign == deviceId,
        orElse: () => devices.first,
      );
    } else {
      targetDevice = devices.first;
    }

    // Generate test data
    Uint8List testData;
    if (data != null) {
      testData = Uint8List.fromList(utf8.encode(data));
    } else if (size != null && size > 0) {
      // Generate random data of specified size
      final random = Random();
      testData = Uint8List.fromList(
        List.generate(size, (i) => 65 + random.nextInt(26)), // A-Z
      );
    } else {
      testData = Uint8List.fromList(utf8.encode('TEST_DATA_${DateTime.now().millisecondsSinceEpoch}'));
    }

    LogService().log('DevicesService: Sending ${testData.length} bytes to ${targetDevice.callsign ?? targetDevice.deviceId} via parcel protocol');

    try {
      // Use parcel-based transfer for reliable delivery
      final success = await _bleMessageService!.sendData(
        device: targetDevice,
        data: testData,
        timeout: const Duration(seconds: 60),
      );

      if (success) {
        LogService().log('DevicesService: Data sent successfully (${testData.length} bytes)');
      } else {
        LogService().log('DevicesService: Data send failed');
      }
      return success;
    } catch (e) {
      LogService().log('DevicesService: Data send failed: $e');
      return false;
    }
  }

  /// Send HELLO handshake to a specific BLE device or the first discovered device
  Future<void> _sendBLEHelloToDevice(String? deviceId) async {
    if (_bleService == null) {
      LogService().log('DevicesService: BLE not available for HELLO');
      return;
    }

    final devices = _bleService!.getAllDevices();
    if (devices.isEmpty) {
      LogService().log('DevicesService: No BLE devices discovered for HELLO');
      return;
    }

    // Find device by ID, callsign, or use first discovered
    BLEDevice? targetDevice;
    if (deviceId != null) {
      // First try exact match on deviceId (MAC address)
      targetDevice = devices.cast<BLEDevice?>().firstWhere(
        (d) => d?.deviceId == deviceId,
        orElse: () => null,
      );
      // Then try matching by callsign
      if (targetDevice == null) {
        targetDevice = devices.cast<BLEDevice?>().firstWhere(
          (d) => d?.callsign == deviceId,
          orElse: () => null,
        );
      }
      // Fallback to first device if no match
      if (targetDevice == null) {
        LogService().log('DevicesService: No device found matching "$deviceId", using first discovered');
        targetDevice = devices.first;
      }
    } else {
      targetDevice = devices.first;
    }

    LogService().log('DevicesService: Sending HELLO to ${targetDevice.deviceId} (${targetDevice.callsign ?? "unknown"})');

    try {
      final success = await sendBLEHello(targetDevice);
      if (success) {
        LogService().log('DevicesService: HELLO handshake successful with ${targetDevice.deviceId}');
      } else {
        LogService().log('DevicesService: HELLO handshake failed with ${targetDevice.deviceId}');
      }
    } catch (e) {
      LogService().log('DevicesService: Error during HELLO handshake: $e');
    }
  }

  /// Start BLE advertising with optional callsign override
  Future<void> _startBLEAdvertisingWithCallsign(String? callsign) async {
    if (_bleService == null) return;

    final profile = ProfileService().getProfile();
    final effectiveCallsign = callsign ?? profile.callsign;

    if (effectiveCallsign.isEmpty) {
      LogService().log('DevicesService: Cannot advertise - no callsign');
      return;
    }

    try {
      await _bleService!.startAdvertising(effectiveCallsign);
      if (_bleService!.isAdvertising) {
        LogService().log('DevicesService: BLE advertising started as $effectiveCallsign');
      } else {
        LogService().log('DevicesService: BLE advertising not started (permission denied or unavailable)');
      }
    } catch (e) {
      LogService().log('DevicesService: BLE advertising failed: $e');
    }
  }

  /// Initialize BLE discovery (not available on web)
  Future<void> _initializeBLE() async {
    if (kIsWeb) {
      LogService().log('DevicesService: BLE not available on web platform');
      return;
    }

    try {
      _bleService = BLEDiscoveryService();

      // Initialize BLE service (starts monitoring Bluetooth adapter state)
      await _bleService!.initialize();

      // Subscribe to BLE device discoveries
      _bleSubscription = _bleService!.devicesStream.listen((bleDevices) {
        _handleBLEDevices(bleDevices);
      });

      LogService().log('DevicesService: BLE discovery initialized');

      // Start advertising in background (don't block initialization)
      _startBLEAdvertising();

      // Initialize BLE messaging service
      await _initializeBLEMessaging();
    } catch (e, stackTrace) {
      LogService().log('DevicesService: Failed to initialize BLE: $e\n$stackTrace');
      _bleService = null;
    }
  }

  /// Initialize BLE messaging service for chat/data exchange
  Future<void> _initializeBLEMessaging() async {
    try {
      LogService().log('DevicesService: Starting BLE messaging initialization (canBeServer: ${BLEMessageService.canBeServer})');

      final profile = ProfileService().getProfile();
      if (profile.callsign.isEmpty) {
        LogService().log('DevicesService: No callsign set, skipping BLE messaging init');
        return;
      }

      LogService().log('DevicesService: Profile callsign: ${profile.callsign}');

      // Build NOSTR-signed event for HELLO handshakes
      final helloEvent = await _buildHelloEvent(profile);
      LogService().log('DevicesService: Built HELLO event for BLE handshakes');

      _bleMessageService = BLEMessageService();
      await _bleMessageService!.initialize(
        event: helloEvent,
        callsign: profile.callsign,
      );

      // Subscribe to incoming BLE chat messages
      _bleChatSubscription = _bleMessageService!.incomingChats.listen((message) {
        LogService().log('DevicesService: BLE chat from ${message.author}: ${message.content}');
        _bleChatController.add(message);
      });

      LogService().log('DevicesService: BLE messaging initialized successfully (isInitialized: ${_bleMessageService!.isInitialized})');

      // Start BLE foreground service on Android to keep BLE alive in background
      await BLEForegroundService().start();
    } catch (e, stackTrace) {
      LogService().log('DevicesService: Failed to initialize BLE messaging: $e');
      LogService().log('DevicesService: Stack trace: $stackTrace');
    }
  }

  /// Build HELLO event for BLE handshakes
  Future<Map<String, dynamic>> _buildHelloEvent(Profile profile) async {
    final pubkey = profile.npub.isNotEmpty ? profile.npub : '';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final tags = <List<String>>[
      ['callsign', profile.callsign],
      if (profile.nickname.isNotEmpty) ['nickname', profile.nickname],
    ];

    // Add location if available
    if (profile.latitude != null && profile.longitude != null) {
      tags.add(['latitude', profile.latitude.toString()]);
      tags.add(['longitude', profile.longitude.toString()]);
    }

    // Create event
    final nostrEvent = NostrEvent(
      pubkey: pubkey,
      createdAt: now,
      kind: 30078, // Application-specific data
      tags: tags,
      content: '',
    );

    // Sign event if possible
    try {
      final signingService = SigningService();
      final signedEvent = await signingService.signEvent(nostrEvent, profile);
      if (signedEvent != null) {
        return signedEvent.toJson();
      }
    } catch (e) {
      LogService().log('DevicesService: Could not sign HELLO event: $e');
    }

    return nostrEvent.toJson();
  }

  /// Start BLE advertising (separate from initialization to avoid crashes)
  /// Note: On Android/iOS, advertising is handled by BLEGattServerService instead
  Future<void> _startBLEAdvertising() async {
    if (_bleService == null) return;

    // On Android/iOS, the GATT server handles advertising (BLEMessageService)
    // Don't start basic advertising here as it would conflict
    if (BLEMessageService.canBeServer) {
      LogService().log('DevicesService: Skipping basic advertising - GATT server will handle it');
      return;
    }

    // Delay advertising start to allow permission dialogs to complete
    await Future.delayed(const Duration(seconds: 2));

    try {
      final profile = ProfileService().getProfile();
      if (profile.callsign != null) {
        await _bleService!.startAdvertising(profile.callsign!);
      }
    } catch (e) {
      LogService().log('DevicesService: Failed to start BLE advertising: $e');
      // Don't crash - advertising is optional
    }
  }

  /// Handle BLE discovered devices
  void _handleBLEDevices(List<BLEDevice> bleDevices) {
    final pairingService = BluetoothClassicPairingService();

    // Track which callsigns are currently visible via BLE
    final bleCallsigns = <String>{};

    // First pass: Update devices that ARE in the BLE scan
    for (final bleDevice in bleDevices) {
      // Use callsign if available, otherwise use BLE device ID
      final callsign = bleDevice.callsign?.toUpperCase() ?? 'BLE-${bleDevice.deviceId}';

      // Track this device as visible via BLE
      bleCallsigns.add(callsign);

      // Check if this device is BLE+ paired
      final isBLEPlus = pairingService.isBLEPlus(callsign);

      if (_devices.containsKey(callsign)) {
        // Update existing device
        final device = _devices[callsign]!;
        if (!device.connectionMethods.contains('bluetooth')) {
          device.connectionMethods = [...device.connectionMethods, 'bluetooth'];
        }
        // Add bluetooth_plus if device is BLE+ paired
        if (isBLEPlus && !device.connectionMethods.contains('bluetooth_plus')) {
          device.connectionMethods = [...device.connectionMethods, 'bluetooth_plus'];
        }
        // Remove bluetooth_plus if no longer paired
        if (!isBLEPlus && device.connectionMethods.contains('bluetooth_plus')) {
          device.connectionMethods = device.connectionMethods
              .where((m) => m != 'bluetooth_plus')
              .toList();
        }
        device.isOnline = true;
        device.lastSeen = bleDevice.lastSeen;
        device.bleProximity = bleDevice.proximity;
        device.bleRssi = bleDevice.rssi;
        // Update location if available from BLE HELLO
        if (bleDevice.latitude != null) device.latitude = bleDevice.latitude;
        if (bleDevice.longitude != null) device.longitude = bleDevice.longitude;
        if (bleDevice.nickname != null) device.nickname = bleDevice.nickname;
      } else {
        // Add new device discovered via BLE
        final connectionMethods = isBLEPlus
            ? ['bluetooth', 'bluetooth_plus']
            : ['bluetooth'];

        _devices[callsign] = RemoteDevice(
          callsign: callsign,
          name: bleDevice.displayName,
          nickname: bleDevice.nickname,
          npub: bleDevice.npub,
          isOnline: true,
          hasCachedData: false,
          collections: [],
          latitude: bleDevice.latitude,
          longitude: bleDevice.longitude,
          connectionMethods: connectionMethods,
          source: DeviceSourceType.ble,
          lastSeen: bleDevice.lastSeen,
          bleProximity: bleDevice.proximity,
          bleRssi: bleDevice.rssi,
        );
        final plusLabel = isBLEPlus ? ' [BLE+]' : '';
        LogService().log('DevicesService: Added BLE device: $callsign (${bleDevice.proximity})$plusLabel');
      }
    }

    // Second pass: Remove BLE tags from devices NOT in current scan
    for (final device in _devices.values) {
      // Skip if device IS in current BLE scan
      if (bleCallsigns.contains(device.callsign)) {
        continue;
      }

      // Skip if device doesn't have BLE tags
      if (!device.connectionMethods.contains('bluetooth') &&
          !device.connectionMethods.contains('bluetooth_plus')) {
        continue;
      }

      // Remove BLE tags (device no longer visible via BLE)
      final hadBLE = device.connectionMethods.contains('bluetooth');
      final hadBLEPlus = device.connectionMethods.contains('bluetooth_plus');

      device.connectionMethods = device.connectionMethods
          .where((m) => m != 'bluetooth' && m != 'bluetooth_plus')
          .toList();

      // Clear BLE-specific fields
      device.bleProximity = null;
      device.bleRssi = null;

      if (hadBLE || hadBLEPlus) {
        LogService().log('DevicesService: Removed BLE tags from ${device.callsign} (not in current scan)');
      }
    }

    _notifyListeners();
  }

  /// Load devices from cache
  Future<void> _loadCachedDevices() async {
    try {
      final cachedCallsigns = await _cacheService.getCachedDevices();

      for (final callsign in cachedCallsigns) {
        final cacheTime = await _cacheService.getCacheTime(callsign);
        final cachedRelayUrl = await _cacheService.getCachedRelayUrl(callsign);

        // Try to find matching station
        Station? matchingRelay;
        try {
          for (final station in _stationService.getAllStations()) {
            if (station.callsign?.toUpperCase() == callsign.toUpperCase()) {
              matchingRelay = station;
              break;
            }
          }
        } catch (e) {
          // StationService might not be initialized
        }

        // Use station URL if available, otherwise use cached station URL
        final deviceUrl = matchingRelay?.url ?? cachedRelayUrl;

        // Load cached status from disk
        final statusCache = await _loadDeviceStatusCache(callsign);

        _devices[callsign] = RemoteDevice(
          callsign: callsign,
          name: statusCache?['nickname'] as String? ?? matchingRelay?.name ?? callsign,
          nickname: statusCache?['nickname'] as String?,
          description: statusCache?['description'] as String?,
          url: statusCache?['url'] as String? ?? deviceUrl,
          npub: statusCache?['npub'] as String?,
          isOnline: false,
          lastSeen: cacheTime,
          lastFetched: statusCache?['lastFetched'] != null
              ? DateTime.tryParse(statusCache!['lastFetched'] as String)
              : null,
          hasCachedData: true,
          collections: [],
          latitude: statusCache?['latitude'] as double? ?? matchingRelay?.latitude,
          longitude: statusCache?['longitude'] as double? ?? matchingRelay?.longitude,
          preferredColor: statusCache?['color'] as String?,
          platform: statusCache?['platform'] as String?,
          // When loading from cache, device is offline - exclude 'internet' and BLE tags
          // BLE tags are session-based and should only come from active discovery
          connectionMethods: statusCache?['connectionMethods'] != null
              ? List<String>.from(statusCache!['connectionMethods'] as List)
                  .where((m) => m != 'internet' && m != 'bluetooth' && m != 'bluetooth_plus')
                  .toList()
              : [],
          bleProximity: statusCache?['bleProximity'] as String?,
          bleRssi: statusCache?['bleRssi'] as int?,
        );
      }

      // Also add known stations that might not have cache
      try {
        for (final station in _stationService.getAllStations()) {
          if (station.callsign != null && !_devices.containsKey(station.callsign!.toUpperCase())) {
            _devices[station.callsign!.toUpperCase()] = RemoteDevice(
              callsign: station.callsign!,
              name: station.name,
              url: station.url,
              isOnline: station.isConnected,
              lastSeen: station.lastChecked,
              hasCachedData: false,
              collections: [],
              latitude: station.latitude,
              longitude: station.longitude,
              connectionMethods: station.isConnected ? ['internet'] : [],
              source: DeviceSourceType.station,
            );
          }
        }
      } catch (e) {
        // StationService might not be initialized
      }

      _notifyListeners();
    } catch (e) {
      LogService().log('DevicesService: Error loading cached devices: $e');
    }
  }

  /// Get all known devices
  /// Sorted: Pinned first, then online, then by name
  /// Excludes the current user's own device
  List<RemoteDevice> getAllDevices() {
    final pinnedCallsigns = _getPinnedDevices();
    final folderAssignments = _getDeviceFolderAssignments();
    final ownCallsign = ProfileService().getProfile().callsign.toUpperCase();

    // Update isPinned and folderId flags for each device
    for (final device in _devices.values) {
      device.isPinned = pinnedCallsigns.contains(device.callsign);
      device.folderId = folderAssignments[device.callsign];
    }

    return _devices.values
      .where((d) => d.callsign.toUpperCase() != ownCallsign) // Exclude own device
      .toList()
      ..sort((a, b) {
        // Pinned devices first
        if (a.isPinned != b.isPinned) {
          return a.isPinned ? -1 : 1;
        }
        // Then online devices
        if (a.isOnline != b.isOnline) {
          return a.isOnline ? -1 : 1;
        }
        // Then sort by display name
        return a.displayName.compareTo(b.displayName);
      });
  }

  /// Get a specific device by callsign
  RemoteDevice? getDevice(String callsign) {
    final device = _devices[callsign.toUpperCase()];
    if (device != null) {
      device.isPinned = _getPinnedDevices().contains(device.callsign);
    }
    return device;
  }

  /// Get list of pinned device callsigns from config
  Set<String> _getPinnedDevices() {
    final config = ConfigService();
    final pinned = config.get('pinnedDevices', <dynamic>[]) as List<dynamic>;
    return pinned.map((e) => e.toString()).toSet();
  }

  /// Pin a device (appears at top of list)
  void pinDevice(String callsign) {
    final normalized = callsign.toUpperCase();
    final pinned = _getPinnedDevices();
    pinned.add(normalized);
    ConfigService().set('pinnedDevices', pinned.toList());

    // Update the device's isPinned flag
    final device = _devices[normalized];
    if (device != null) {
      device.isPinned = true;
    }

    _devicesController.add(getAllDevices());
    LogService().log('DevicesService: Pinned device $normalized');
  }

  /// Unpin a device
  void unpinDevice(String callsign) {
    final normalized = callsign.toUpperCase();
    final pinned = _getPinnedDevices();
    pinned.remove(normalized);
    ConfigService().set('pinnedDevices', pinned.toList());

    // Update the device's isPinned flag
    final device = _devices[normalized];
    if (device != null) {
      device.isPinned = false;
    }

    _devicesController.add(getAllDevices());
    LogService().log('DevicesService: Unpinned device $normalized');
  }

  /// Check if a device is pinned
  bool isDevicePinned(String callsign) {
    return _getPinnedDevices().contains(callsign.toUpperCase());
  }

  // ============ Folder Management ============

  /// Default folder ID for devices without an assigned folder
  static const String defaultFolderId = 'discovered';

  /// Get all folders
  List<DeviceFolder> getFolders() {
    final config = ConfigService();
    final foldersJson = config.get('deviceFolders', <dynamic>[]) as List<dynamic>;
    final folders = foldersJson.map((json) => DeviceFolder.fromJson(json as Map<String, dynamic>)).toList();
    final expandedStates = _getFolderExpandedStates();

    // Ensure default folder exists
    if (!folders.any((f) => f.id == defaultFolderId)) {
      folders.insert(0, DeviceFolder(id: defaultFolderId, name: 'Discovered', isDefault: true, order: -1000));
    }

    // Apply saved expanded states
    for (final folder in folders) {
      if (expandedStates.containsKey(folder.id)) {
        folder.isExpanded = expandedStates[folder.id]!;
      }
    }

    // Sort by order (default folder has order -1000 to stay first unless moved)
    folders.sort((a, b) => a.order.compareTo(b.order));

    return folders;
  }

  /// Save folders to config
  void _saveFolders(List<DeviceFolder> folders) {
    final config = ConfigService();
    // Save all folders including default folder (for order persistence)
    config.set('deviceFolders', folders.map((f) => f.toJson()).toList());
    _devicesController.add(getAllDevices());
  }

  /// Get folder expanded states from config
  Map<String, bool> _getFolderExpandedStates() {
    final config = ConfigService();
    final states = config.get('folderExpandedStates', <String, dynamic>{}) as Map<String, dynamic>;
    return states.map((k, v) => MapEntry(k, v as bool));
  }

  /// Save folder expanded state
  void setFolderExpanded(String folderId, bool isExpanded) {
    final states = _getFolderExpandedStates();
    states[folderId] = isExpanded;
    ConfigService().set('folderExpandedStates', states);
  }

  /// Get folder expanded state
  bool isFolderExpanded(String folderId) {
    final states = _getFolderExpandedStates();
    return states[folderId] ?? true; // Default to expanded
  }

  /// Reorder folders - move folder to new position
  void reorderFolders(int oldIndex, int newIndex) {
    final folders = getFolders();
    if (oldIndex < 0 || oldIndex >= folders.length) return;
    if (newIndex < 0 || newIndex >= folders.length) return;

    final folder = folders.removeAt(oldIndex);
    folders.insert(newIndex, folder);

    // Update order values
    for (int i = 0; i < folders.length; i++) {
      folders[i].order = i;
    }

    _saveFolders(folders);
    LogService().log('DevicesService: Reordered folders, moved ${folder.name} from $oldIndex to $newIndex');
  }

  /// Create a new folder
  DeviceFolder createFolder(String name) {
    final folders = getFolders();
    final id = 'folder_${DateTime.now().millisecondsSinceEpoch}';
    // New folders get order at the end
    final maxOrder = folders.isEmpty ? 0 : folders.map((f) => f.order).reduce((a, b) => a > b ? a : b);
    final folder = DeviceFolder(id: id, name: name, order: maxOrder + 1);
    folders.add(folder);
    _saveFolders(folders);
    LogService().log('DevicesService: Created folder "$name" with id $id');
    return folder;
  }

  /// Ensure a folder exists with a specific id (used for group synchronization)
  DeviceFolder ensureFolder(String id, String name) {
    final folders = getFolders();

    final existing = folders.firstWhere(
      (f) => f.id == id,
      orElse: () => DeviceFolder(id: '', name: ''),
    );

    if (existing.id.isNotEmpty) {
      return existing;
    }

    final maxOrder = folders.isEmpty
        ? 0
        : folders.map((f) => f.order).reduce((a, b) => a > b ? a : b);
    final folder = DeviceFolder(id: id, name: name, order: maxOrder + 1);
    folders.add(folder);
    _saveFolders(folders);
    LogService().log('DevicesService: Ensured folder "$name" with id $id');
    return folder;
  }

  /// Rename a folder
  void renameFolder(String folderId, String newName) {
    if (folderId == defaultFolderId) return; // Can't rename default folder
    final folders = getFolders();
    final folder = folders.firstWhere((f) => f.id == folderId, orElse: () => DeviceFolder(id: '', name: ''));
    if (folder.id.isNotEmpty) {
      folder.name = newName;
      _saveFolders(folders);
      LogService().log('DevicesService: Renamed folder $folderId to "$newName"');
    }
  }

  /// Delete a folder and all devices in it
  Future<void> deleteFolder(String folderId) async {
    if (folderId == defaultFolderId) return; // Can't delete default folder

    // Remove all devices in this folder
    final devicesToRemove = _devices.values.where((d) => d.folderId == folderId).toList();
    for (final device in devicesToRemove) {
      await removeDevice(device.callsign);
    }

    // Remove the folder
    final folders = getFolders();
    folders.removeWhere((f) => f.id == folderId);
    _saveFolders(folders);
    LogService().log('DevicesService: Deleted folder $folderId with ${devicesToRemove.length} devices');
  }

  /// Empty a folder (move all devices to default folder)
  void emptyFolder(String folderId) {
    if (folderId == defaultFolderId) return; // Can't empty default folder

    final devicesInFolder = _devices.values.where((d) => d.folderId == folderId).toList();
    for (final device in devicesInFolder) {
      moveDeviceToFolder(device.callsign, null); // null = default folder
    }
    LogService().log('DevicesService: Emptied folder $folderId, moved ${devicesInFolder.length} devices to Discovered');
  }

  /// Move a device to a folder
  void moveDeviceToFolder(String callsign, String? folderId) {
    final normalized = callsign.toUpperCase();
    final device = _devices[normalized];
    if (device != null) {
      device.folderId = folderId;
      _saveDeviceFolderAssignment(normalized, folderId);
      _devicesController.add(getAllDevices());
      LogService().log('DevicesService: Moved device $normalized to folder ${folderId ?? defaultFolderId}');
    }
  }

  /// Move multiple devices to a folder
  void moveDevicesToFolder(List<String> callsigns, String? folderId) {
    for (final callsign in callsigns) {
      moveDeviceToFolder(callsign, folderId);
    }
  }

  /// Get folder assignment map from config
  Map<String, String?> _getDeviceFolderAssignments() {
    final config = ConfigService();
    final assignments = config.get('deviceFolderAssignments', <String, dynamic>{}) as Map<String, dynamic>;
    return assignments.map((k, v) => MapEntry(k, v as String?));
  }

  /// Save a single device's folder assignment
  void _saveDeviceFolderAssignment(String callsign, String? folderId) {
    final assignments = _getDeviceFolderAssignments();
    if (folderId == null) {
      assignments.remove(callsign);
    } else {
      assignments[callsign] = folderId;
    }
    ConfigService().set('deviceFolderAssignments', assignments);
  }

  /// Get the folder ID for a device
  String? getDeviceFolderId(String callsign) {
    return _getDeviceFolderAssignments()[callsign.toUpperCase()];
  }

  /// Get devices in a specific folder
  List<RemoteDevice> getDevicesInFolder(String? folderId) {
    final targetFolderId = folderId ?? defaultFolderId;
    return getAllDevices().where((d) {
      final deviceFolder = d.folderId ?? defaultFolderId;
      return deviceFolder == targetFolderId || (targetFolderId == defaultFolderId && d.folderId == null);
    }).toList();
  }

  // ============ End Folder Management ============

  /// Make an API request to a remote device, using ConnectionManager for routing
  /// This enables device-to-device communication using the best available transport
  /// Returns null if no route is available
  Future<http.Response?> makeDeviceApiRequest({
    required String callsign,
    required String method,
    required String path,
    Map<String, String>? headers,
    String? body,
  }) async {
    final normalizedCallsign = callsign.toUpperCase();

    // Sync device info to ConnectionManager before request
    _syncDeviceToConnectionManager(normalizedCallsign);

    // Use ConnectionManager for routing
    final connectionManager = ConnectionManager();
    if (!connectionManager.isInitialized) {
      // Fallback to legacy routing if ConnectionManager not ready
      return _makeDeviceApiRequestLegacy(
        callsign: normalizedCallsign,
        method: method,
        path: path,
        headers: headers,
        body: body,
      );
    }

    final result = await connectionManager.apiRequest(
      callsign: normalizedCallsign,
      method: method,
      path: path,
      headers: headers,
      body: body,
    );

    if (result.success) {
      LogService().log('DevicesService: Request to $normalizedCallsign succeeded via ${result.transportUsed} '
          '(${result.latency?.inMilliseconds ?? "?"}ms)');
      // Convert TransportResult to http.Response for backward compatibility
      return http.Response(
        result.responseData?.toString() ?? '',
        result.statusCode ?? 200,
      );
    } else {
      LogService().log('DevicesService: Request to $normalizedCallsign failed: ${result.error}');
      return null;
    }
  }

  /// Legacy API request method (fallback when ConnectionManager not initialized)
  Future<http.Response?> _makeDeviceApiRequestLegacy({
    required String callsign,
    required String method,
    required String path,
    Map<String, String>? headers,
    String? body,
  }) async {
    final normalizedCallsign = callsign.toUpperCase();
    final device = getDevice(normalizedCallsign);
    final internetOnly = AppArgs().internetOnly;

    // Try direct connection first if device has a URL and appears online
    // Skip direct connection in internet-only mode (force station proxy)
    if (!internetOnly && device?.url != null && device!.isOnline) {
      try {
        final uri = Uri.parse('${device.url}$path');
        LogService().log('DevicesService: Direct request to $normalizedCallsign: $method $path');
        final response = await _makeHttpRequest(method, uri, headers, body);
        if (response.statusCode < 500) {
          return response; // Success or client error - don't retry via station
        }
      } catch (e) {
        LogService().log('DevicesService: Direct request to $normalizedCallsign failed: $e');
      }
    }

    // Fall back to station proxy (or go directly to station proxy in internet-only mode)
    final station = _stationService.getConnectedRelay();
    if (station == null) {
      LogService().log('DevicesService: No station connected for proxy to $normalizedCallsign');
      return null;
    }

    try {
      // Use station proxy: {stationHttpUrl}/device/{callsign}/{path}
      final stationHttpUrl = station.url.replaceFirst('wss://', 'https://').replaceFirst('ws://', 'http://');
      final proxyUri = Uri.parse('$stationHttpUrl/device/$normalizedCallsign$path');

      LogService().log('DevicesService: Proxying via station to $normalizedCallsign: $method $path');
      return await _makeHttpRequest(method, proxyUri, headers, body);
    } catch (e) {
      LogService().log('DevicesService: Station proxy request failed: $e');
      return null;
    }
  }

  /// Sync device info to ConnectionManager transports
  void _syncDeviceToConnectionManager(String callsign) {
    final device = getDevice(callsign);
    if (device == null) return;

    final connectionManager = ConnectionManager();
    if (!connectionManager.isInitialized) return;

    // Register device URL with LAN transport if available
    if (device.url != null) {
      final lanTransport = connectionManager.getTransport('lan') as LanTransport?;
      if (lanTransport != null) {
        lanTransport.registerLocalDevice(callsign, device.url!);
      }
    }

    // Station transport doesn't need device registration - it uses station proxy
  }

  /// Internal HTTP request helper
  Future<http.Response> _makeHttpRequest(
    String method,
    Uri uri,
    Map<String, String>? headers,
    String? body,
  ) async {
    final h = headers ?? {'Content-Type': 'application/json'};
    switch (method.toUpperCase()) {
      case 'GET':
        return await http.get(uri, headers: h).timeout(const Duration(seconds: 30));
      case 'POST':
        return await http.post(uri, headers: h, body: body).timeout(const Duration(seconds: 30));
      case 'PUT':
        return await http.put(uri, headers: h, body: body).timeout(const Duration(seconds: 30));
      case 'DELETE':
        return await http.delete(uri, headers: h).timeout(const Duration(seconds: 30));
      default:
        return await http.get(uri, headers: h).timeout(const Duration(seconds: 30));
    }
  }

  /// Check reachability of a device
  Future<bool> checkReachability(String callsign) async {
    final device = _devices[callsign.toUpperCase()];
    if (device == null) return false;

    // Store previous online state to detect transitions
    final wasOnline = device.isOnline;
    final internetOnly = AppArgs().internetOnly;

    bool directOk = false;
    bool proxyOk = false;

    // Check if this device IS the connected station
    // For the connected station, WebSocket state is the source of truth
    final connectedStation = _stationService.getConnectedRelay();
    final isConnectedStation = connectedStation != null &&
        connectedStation.callsign != null &&
        connectedStation.callsign!.toUpperCase() == callsign.toUpperCase();

    // Try direct connection first (local WiFi) if device has a URL
    // Skip direct connection check in internet-only mode
    if (!internetOnly && device.url != null) {
      directOk = await _checkDirectConnection(device);
    }

    // For connected station, use WebSocket state instead of proxy check
    // (you can't meaningfully check a station's connectivity through itself)
    if (isConnectedStation) {
      proxyOk = connectedStation!.isConnected;
      if (proxyOk && !device.connectionMethods.contains('internet')) {
        device.connectionMethods = [...device.connectionMethods, 'internet'];
      }
    } else {
      // For other devices, check via station proxy
      proxyOk = await _checkViaRelayProxy(device);
    }

    // Device is online if ANY connection method works (including BLE)
    // BLE connection is indicated by 'bluetooth' or 'bluetooth_plus' in connectionMethods
    final hasBLEConnection = device.connectionMethods.contains('bluetooth') ||
                             device.connectionMethods.contains('bluetooth_plus');
    final isNowOnline = directOk || proxyOk || hasBLEConnection;
    device.isOnline = isNowOnline;
    _notifyListeners();

    // Trigger DM sync when device becomes reachable
    // In internet-only mode, sync happens via station proxy
    if (!wasOnline && isNowOnline) {
      _triggerDMSync(device.callsign, device.url);
    }

    return isNowOnline;
  }

  /// Trigger DM sync with a device that just came online
  /// deviceUrl can be null if using station proxy exclusively
  void _triggerDMSync(String callsign, String? deviceUrl) {
    LogService().log('DevicesService: Device $callsign came online, triggering DM sync');

    // Run sync in background (don't await)
    DirectMessageService().syncWithDevice(callsign, deviceUrl: deviceUrl).then((result) {
      if (result.success) {
        LogService().log('DevicesService: DM sync with $callsign completed - received: ${result.messagesReceived}, sent: ${result.messagesSent}');
      } else {
        LogService().log('DevicesService: DM sync with $callsign failed: ${result.error}');
      }
    }).catchError((e) {
      LogService().log('DevicesService: DM sync with $callsign error: $e');
    });
  }

  /// Check device via station proxy
  Future<bool> _checkViaRelayProxy(RemoteDevice device) async {
    // Get connected station
    final station = _stationService.getConnectedRelay();
    if (station == null || !station.isConnected) {
      // No active station WebSocket connection - remove 'internet' from connectionMethods
      device.connectionMethods = device.connectionMethods
          .where((m) => m != 'internet')
          .toList();
      return false;
    }

    try {
      final baseUrl = station.url.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
      final response = await http.get(
        Uri.parse('$baseUrl/device/${device.callsign}'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final isConnected = data['connected'] == true;

        device.isOnline = isConnected;
        device.lastChecked = DateTime.now();

        // Update connectionMethods based on result
        if (isConnected) {
          if (!device.connectionMethods.contains('internet')) {
            device.connectionMethods = [...device.connectionMethods, 'internet'];
          }
        } else {
          // Device not connected via station - remove 'internet' tag
          device.connectionMethods = device.connectionMethods
              .where((m) => m != 'internet')
              .toList();
        }

        _notifyListeners();
        return isConnected;
      }
    } catch (e) {
      LogService().log('DevicesService: Error checking device ${device.callsign}: $e');
    }

    // On HTTP failure/timeout, don't remove 'internet' tag
    // The tag will only be removed when:
    // - Station WebSocket disconnects (checked at method start)
    // - A successful check returns connected: false (handled above)
    device.lastChecked = DateTime.now();
    _notifyListeners();
    return false;
  }

  /// Check if an IP address is a private/local network address
  bool _isPrivateIP(String host) {
    // Handle localhost
    if (host == 'localhost' || host == '127.0.0.1') return true;

    // Try to parse as IP address
    final parts = host.split('.');
    if (parts.length != 4) return false;

    try {
      final octets = parts.map(int.parse).toList();

      // 10.0.0.0 - 10.255.255.255
      if (octets[0] == 10) return true;

      // 172.16.0.0 - 172.31.255.255
      if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;

      // 192.168.0.0 - 192.168.255.255
      if (octets[0] == 192 && octets[1] == 168) return true;

      // 127.0.0.0 - 127.255.255.255 (loopback)
      if (octets[0] == 127) return true;

      return false;
    } catch (e) {
      return false;
    }
  }

  /// Check device via direct connection (local WiFi or direct internet)
  Future<bool> _checkDirectConnection(RemoteDevice device) async {
    if (device.url == null) return false;

    try {
      final baseUrl = device.url!.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
      final uri = Uri.parse(baseUrl);
      final isLocalIP = _isPrivateIP(uri.host);

      final stopwatch = Stopwatch()..start();

      final response = await http.get(
        Uri.parse('$baseUrl/api/status'),
      ).timeout(const Duration(seconds: 5));

      stopwatch.stop();

      if (response.statusCode == 200) {
        device.isOnline = true;
        device.latency = stopwatch.elapsedMilliseconds;
        device.lastChecked = DateTime.now();

        // Parse status response to extract location and other info
        try {
          final data = json.decode(response.body) as Map<String, dynamic>;

          // Extract location from response
          final location = data['location'] as Map<String, dynamic>?;
          if (location != null) {
            final lat = location['latitude'];
            final lon = location['longitude'];
            if (lat != null) device.latitude = (lat is int) ? lat.toDouble() : lat as double?;
            if (lon != null) device.longitude = (lon is int) ? lon.toDouble() : lon as double?;
          }

          // Also check top-level latitude/longitude (some APIs return it this way)
          if (device.latitude == null && data['latitude'] != null) {
            final lat = data['latitude'];
            device.latitude = (lat is int) ? lat.toDouble() : lat as double?;
          }
          if (device.longitude == null && data['longitude'] != null) {
            final lon = data['longitude'];
            device.longitude = (lon is int) ? lon.toDouble() : lon as double?;
          }

          // Extract nickname if available
          if (data['nickname'] != null) {
            device.nickname = data['nickname'] as String?;
          }

          // Extract preferred color if available
          if (data['color'] != null) {
            device.preferredColor = data['color'] as String?;
          }

          // Extract description if available
          if (data['description'] != null) {
            device.description = data['description'] as String?;
          }

          // Extract platform if available
          if (data['platform'] != null) {
            device.platform = data['platform'] as String?;
          }

          // Extract npub (NOSTR public key) if available
          if (data['npub'] != null) {
            device.npub = data['npub'] as String?;
          }

          // Update fetch timestamp
          device.lastFetched = DateTime.now();
        } catch (e) {
          // Ignore JSON parsing errors - location is optional
        }

        // Add appropriate connection method based on IP type
        if (isLocalIP) {
          if (!device.connectionMethods.contains('wifi_local') &&
              !device.connectionMethods.contains('lan')) {
            device.connectionMethods = [...device.connectionMethods, 'wifi_local'];
          }
        } else {
          // Public IP - this is an internet connection
          if (!device.connectionMethods.contains('internet')) {
            device.connectionMethods = [...device.connectionMethods, 'internet'];
          }
        }

        // Cache device status to disk
        await _saveDeviceStatusCache(device);

        _notifyListeners();
        return true;
      }
    } catch (e) {
      LogService().log('DevicesService: Direct connection to ${device.callsign} failed: $e');
    }

    // Direct connection failed - remove local connection methods
    device.connectionMethods = device.connectionMethods
        .where((m) => m != 'wifi_local' && m != 'lan')
        .toList();
    // Don't set isOnline = false here - let the caller try other methods
    device.lastChecked = DateTime.now();
    _notifyListeners();
    return false;
  }

  /// Check all devices reachability
  /// Refresh all devices, optionally forcing a full refresh even if within cooldown
  /// Returns true if a full refresh was performed, false if cached data was used
  Future<bool> refreshAllDevices({bool force = false}) async {
    // Check if we're within the cooldown period
    if (!force && _lastFullRefreshTime != null) {
      final elapsed = DateTime.now().difference(_lastFullRefreshTime!);
      if (elapsed < _fullRefreshCooldown) {
        LogService().log('DevicesService: Using cached devices (${elapsed.inSeconds}s since last refresh)');
        // Still notify listeners with current data so UI updates
        _notifyListeners();
        return false;
      }
    }

    final internetOnly = AppArgs().internetOnly;
    if (internetOnly) {
      LogService().log('DevicesService: Performing internet-only device refresh (no LAN/BLE)');
    } else {
      LogService().log('DevicesService: Performing full device refresh');
    }

    // First, ensure connected station is in device list with 'internet' tag
    await _updateConnectedStation();

    // Then, fetch connected clients from connected station (internet)
    await _fetchStationClients();

    // Skip local network and BLE discovery in internet-only mode
    if (!internetOnly) {
      // Discover devices on local WiFi network
      await _discoverLocalDevices();

      // Discover devices via BLE (in parallel with other checks)
      _discoverBLEDevices();
    }

    // Check reachability for all known devices
    // Create a copy of callsigns to avoid concurrent modification
    final callsigns = _devices.keys.toList();
    for (final callsign in callsigns) {
      await checkReachability(callsign);
    }

    // Update last refresh time
    _lastFullRefreshTime = DateTime.now();
    return true;
  }

  /// Discover devices via BLE
  Future<void> _discoverBLEDevices() async {
    if (_bleService == null) return;

    try {
      if (await _bleService!.isAvailable()) {
        LogService().log('DevicesService: Starting BLE discovery...');
        // Start BLE scan (non-blocking, updates come via stream)
        _bleService!.startScanning(timeout: const Duration(seconds: 10));
      }
    } catch (e) {
      LogService().log('DevicesService: BLE discovery error: $e');
    }
  }

  /// Check if BLE discovery is available
  bool get isBLEAvailable => _bleService != null;

  /// Check if BLE is currently scanning
  bool get isBLEScanning => _bleService?.isScanning ?? false;

  /// Check if BLE messaging is available
  bool get isBLEMessagingAvailable => _bleMessageService?.isInitialized ?? false;

  /// Send chat message to a device via BLE
  /// Returns true if message was delivered successfully
  Future<bool> sendChatViaBLE({
    required String targetCallsign,
    required String content,
    String channel = 'main',
  }) async {
    if (_bleMessageService == null) {
      LogService().log('DevicesService: BLE messaging not available');
      return false;
    }

    return await _bleMessageService!.sendChatToCallsign(
      targetCallsign: targetCallsign,
      content: content,
      channel: channel,
    );
  }

  /// Send chat to a specific BLE device
  Future<bool> sendChatToBLEDevice({
    required BLEDevice device,
    required String content,
    String channel = 'main',
  }) async {
    if (_bleMessageService == null) {
      LogService().log('DevicesService: BLE messaging not available');
      return false;
    }

    return await _bleMessageService!.sendChat(
      device: device,
      content: content,
      channel: channel,
    );
  }

  /// Broadcast chat to all connected BLE clients (server mode only)
  Future<void> broadcastChatViaBLE({
    required String content,
    String channel = 'main',
  }) async {
    if (_bleMessageService == null) {
      LogService().log('DevicesService: BLE messaging not available');
      return;
    }

    await _bleMessageService!.broadcastChat(
      content: content,
      channel: channel,
    );
  }

  /// Send HELLO handshake to a BLE device
  Future<bool> sendBLEHello(BLEDevice device) async {
    if (_bleMessageService == null) {
      LogService().log('DevicesService: BLE messaging not available');
      return false;
    }

    return await _bleMessageService!.sendHello(device);
  }

  /// Get list of connected BLE clients (server mode)
  List<String> get connectedBLEClients {
    return _bleMessageService?.connectedClients ?? [];
  }

  /// Update the connected station as a device with 'internet' connection
  /// [eventCallsign] and [eventUrl] come from the ConnectionStateChangedEvent
  /// and allow us to fetch station info even before station object is fully populated
  Future<void> _updateConnectedStation({String? eventCallsign, String? eventUrl}) async {
    try {
      final station = _stationService.getConnectedRelay();

      // Use event data if station isn't ready yet
      final callsign = station?.callsign ?? eventCallsign;
      final url = station?.url ?? eventUrl;

      if (callsign == null || url == null) {
        LogService().log('DevicesService: _updateConnectedStation - no callsign or url available');
        return;
      }

      final normalizedCallsign = callsign.toUpperCase();

      // Get lat/lon from station, or fetch directly if not available
      double? latitude = station?.latitude;
      double? longitude = station?.longitude;

      // If station doesn't have lat/lon yet, fetch from API directly
      if (latitude == null || longitude == null) {
        try {
          final httpUrl = url.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
          final statusUrl = httpUrl.endsWith('/') ? '${httpUrl}api/status' : '$httpUrl/api/status';
          final response = await http.get(Uri.parse(statusUrl)).timeout(const Duration(seconds: 10));
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            latitude = (data['latitude'] as num?)?.toDouble();
            longitude = (data['longitude'] as num?)?.toDouble();
          }
        } catch (e) {
          LogService().log('DevicesService: Error fetching station status: $e');
        }
      }

      final stationName = station?.name ?? normalizedCallsign;

      if (_devices.containsKey(normalizedCallsign)) {
        // Update existing device
        final device = _devices[normalizedCallsign]!;
        device.isOnline = true;
        device.url = url;
        device.latitude = latitude;
        device.longitude = longitude;
        device.lastSeen = DateTime.now();
        // Ensure 'internet' tag is present
        if (!device.connectionMethods.contains('internet')) {
          device.connectionMethods = [...device.connectionMethods, 'internet'];
        }
        device.source = DeviceSourceType.station;
        LogService().log('DevicesService: Updated station device: $normalizedCallsign');
      } else {
        // Add new device for the station
        _devices[normalizedCallsign] = RemoteDevice(
          callsign: normalizedCallsign,
          name: stationName,
          url: url,
          isOnline: true,
          hasCachedData: false,
          collections: [],
          latitude: latitude,
          longitude: longitude,
          connectionMethods: ['internet'],
          source: DeviceSourceType.station,
          lastSeen: DateTime.now(),
        );
        LogService().log('DevicesService: Added station as device: $normalizedCallsign');
      }

      _notifyListeners();
    } catch (e) {
      LogService().log('DevicesService: Error updating connected station: $e');
    }
  }

  /// Discover devices on local WiFi network (both clients and stations)
  Future<void> _discoverLocalDevices({bool force = false}) async {
    try {
      final now = DateTime.now();
      final shouldFullScan = force ||
          _lastLocalScanTime == null ||
          now.difference(_lastLocalScanTime!) > _localScanInterval;

      if (shouldFullScan) {
        // Full network scan
        LogService().log('DevicesService: Full local network scan (last: $_lastLocalScanTime)');
        _lastLocalScanTime = now;
        await _performFullLocalScan();
      } else {
        // Just check reachability of known local devices (fast)
        LogService().log('DevicesService: Quick reachability check for known local devices');
        await _checkLocalDevicesReachability();
      }
    } catch (e) {
      LogService().log('DevicesService: Error discovering local devices: $e');
    }
  }

  /// Force a full local network scan (resets the scan timer)
  Future<void> forceLocalScan() async {
    await _discoverLocalDevices(force: true);
  }

  /// Perform a full network scan for local devices
  Future<void> _performFullLocalScan() async {
    LogService().log('DevicesService: Scanning local network for devices...');

    // Use quick scan (500ms timeout) for faster discovery
    final results = await _discoveryService.scanWithProgress(
      timeoutMs: 500,
    );

    LogService().log('DevicesService: Found ${results.length} devices on local network');

    for (final result in results) {
      // Skip if no callsign
      if (result.callsign == null || result.callsign!.isEmpty) continue;

      final normalizedCallsign = result.callsign!.toUpperCase();

      // Build local URL for direct connection
      final localUrl = 'http://${result.ip}:${result.port}';

      // Determine connection type based on discovery type
      final connectionType = result.type == 'station' ? 'lan' : 'wifi_local';

      // Update existing device or create new one
      if (_devices.containsKey(normalizedCallsign)) {
        final device = _devices[normalizedCallsign]!;

        // Add connection type if not already present
        if (!device.connectionMethods.contains(connectionType)) {
          device.connectionMethods = [...device.connectionMethods, connectionType];
        }

        // Store local URL for direct connection (prefer local over internet)
        device.url = localUrl;
        device.isOnline = true;
        device.lastSeen = DateTime.now();

        LogService().log('DevicesService: Updated ${result.type} $normalizedCallsign with local network ($localUrl)');
      } else {
        // Create new device discovered on local network
        _devices[normalizedCallsign] = RemoteDevice(
          callsign: normalizedCallsign,
          name: result.name ?? normalizedCallsign,
          nickname: result.name,
          url: localUrl,
          isOnline: true,
          hasCachedData: false,
          collections: [],
          latitude: result.latitude,
          longitude: result.longitude,
          connectionMethods: [connectionType],
          source: DeviceSourceType.local,
          lastSeen: DateTime.now(),
        );
        LogService().log('DevicesService: Added new ${result.type} from local network: $normalizedCallsign at $localUrl');
      }
    }

    _notifyListeners();
  }

  /// Check reachability of previously discovered local devices (fast)
  Future<void> _checkLocalDevicesReachability() async {
    final localDevices = _devices.values.where((d) =>
        d.connectionMethods.contains('wifi_local') ||
        d.connectionMethods.contains('lan')).toList();

    LogService().log('DevicesService: Checking ${localDevices.length} known local devices');

    for (final device in localDevices) {
      if (device.url != null) {
        await _checkDirectConnection(device);
      }
    }

    _notifyListeners();
  }

  /// Fetch connected devices from the connected station
  Future<void> _fetchStationClients() async {
    try {
      // Try connected station first, fall back to preferred station
      var station = _stationService.getConnectedRelay();
      if (station == null) {
        // No connected station - try preferred station for device list
        // This allows showing station devices even before WebSocket connects
        station = _stationService.getPreferredStation();
        if (station == null) {
          LogService().log('DevicesService: No station available to fetch devices from');
          return;
        }
        LogService().log('DevicesService: Using preferred station for device list (not yet connected)');
      }

      // Convert WebSocket URL to HTTP and extract base (remove path like /ws)
      var baseUrl = station.url
          .replaceFirst('ws://', 'http://')
          .replaceFirst('wss://', 'https://');

      // Remove any path component (e.g., /ws) to get the base URL
      final uri = Uri.parse(baseUrl);
      baseUrl = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';

      final url = '$baseUrl/api/devices';
      LogService().log('DevicesService: Fetching devices from: $url');

      List<dynamic>? devices;

      try {
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          devices = data['devices'] as List<dynamic>?;
        }
      } catch (e) {
        LogService().log('DevicesService: Failed to fetch devices: $e');
      }

      if (devices == null) {
        LogService().log('DevicesService: No devices endpoint available on station');
        return;
      }

      LogService().log('DevicesService: Received ${devices.length} devices from /api/devices');

      for (final deviceData in devices) {
        final callsign = deviceData['callsign'] as String?;
        if (callsign == null || callsign.isEmpty || callsign == 'Unknown') {
          LogService().log('DevicesService: Skipping device with no callsign');
          continue;
        }

        final normalizedCallsign = callsign.toUpperCase();

        // Check if device is currently online via station
        final isOnlineViaStation = deviceData['is_online'] == true;

        // Parse connection types - only add 'internet' if actually online via station
        final connectionTypes = <String>[];
        final rawTypes = deviceData['connection_types'] as List<dynamic>?;
        if (rawTypes != null && rawTypes.isNotEmpty) {
          for (final t in rawTypes) {
            connectionTypes.add(t.toString());
          }
        } else if (isOnlineViaStation) {
          // Default to internet only if device is currently online via station
          connectionTypes.add('internet');
        }

        // Update existing device or create new one
        if (_devices.containsKey(normalizedCallsign)) {
          final device = _devices[normalizedCallsign]!;
          device.isOnline = isOnlineViaStation;
          device.nickname = deviceData['nickname'] as String?;
          device.npub = deviceData['npub'] as String?;
          device.latitude = deviceData['latitude'] as double?;
          device.longitude = deviceData['longitude'] as double?;
          device.preferredColor = deviceData['color'] as String?;
          device.platform = deviceData['platform'] as String?;
          device.lastFetched = DateTime.now();
          // Merge connection methods only if device is online via station
          if (isOnlineViaStation) {
            for (final method in connectionTypes) {
              if (!device.connectionMethods.contains(method)) {
                device.connectionMethods = [...device.connectionMethods, method];
              }
            }
          } else {
            // Device is offline - remove 'internet' tag if present
            device.connectionMethods = device.connectionMethods
                .where((m) => m != 'internet')
                .toList();
          }
          device.source = DeviceSourceType.station;
          device.lastSeen = DateTime.now();
          // Cache device status to disk
          await _saveDeviceStatusCache(device);
          LogService().log('DevicesService: Updated device: $normalizedCallsign (online: $isOnlineViaStation)');
        } else {
          // Create new device from station
          final device = RemoteDevice(
            callsign: normalizedCallsign,
            name: deviceData['nickname'] as String? ?? normalizedCallsign,
            nickname: deviceData['nickname'] as String?,
            npub: deviceData['npub'] as String?,
            isOnline: isOnlineViaStation,
            hasCachedData: false,
            collections: [],
            latitude: deviceData['latitude'] as double?,
            longitude: deviceData['longitude'] as double?,
            preferredColor: deviceData['color'] as String?,
            platform: deviceData['platform'] as String?,
            connectionMethods: connectionTypes,
            source: DeviceSourceType.station,
            lastSeen: DateTime.now(),
            lastFetched: DateTime.now(),
          );
          _devices[normalizedCallsign] = device;
          // Cache device status to disk
          await _saveDeviceStatusCache(device);
          LogService().log('DevicesService: Added new device from station: $normalizedCallsign (online: $isOnlineViaStation)');
        }
      }

      _notifyListeners();
      LogService().log('DevicesService: Fetched ${devices.length} devices from station ${station.name}');
    } catch (e) {
      LogService().log('DevicesService: Error fetching station clients: $e');
    }
  }

  /// Fetch collections from a remote device
  Future<List<RemoteCollection>> fetchCollections(String callsign) async {
    final device = _devices[callsign.toUpperCase()];
    if (device == null) return [];

    // First check if device is reachable
    final isOnline = await checkReachability(callsign);

    if (isOnline) {
      return await _fetchCollectionsOnline(device);
    } else {
      return await _loadCachedCollections(callsign);
    }
  }

  /// Fetch collections from online device using ConnectionManager
  Future<List<RemoteCollection>> _fetchCollectionsOnline(RemoteDevice device) async {
    final collections = <RemoteCollection>[];

    // Sync device to ConnectionManager first
    _syncDeviceToConnectionManager(device.callsign);

    // Fetch collection folders from /files endpoint via ConnectionManager
    try {
      final filesResponse = await makeDeviceApiRequest(
        callsign: device.callsign,
        method: 'GET',
        path: '/files',
      );

      if (filesResponse != null && filesResponse.statusCode == 200) {
        final data = json.decode(filesResponse.body);
        LogService().log('DevicesService: Files data: $data');

        if (data['entries'] is List) {
          for (final entry in data['entries']) {
            if (entry['isDirectory'] == true || entry['type'] == 'directory') {
              final name = entry['name'] as String;
              final lowerName = name.toLowerCase();

              // Only include known collection types (same as local collections)
              if (_isKnownCollectionType(lowerName)) {
                collections.add(RemoteCollection(
                  name: name,
                  deviceCallsign: device.callsign,
                  type: lowerName,
                  fileCount: entry['size'] is int ? entry['size'] : null,
                ));
              }
            }
          }
        }
      }
    } catch (e) {
      LogService().log('DevicesService: Error fetching files: $e');
    }

    // If no collections found via /files, check if it's a station with chat
    if (collections.isEmpty) {
      try {
        final chatResponse = await makeDeviceApiRequest(
          callsign: device.callsign,
          method: 'GET',
          path: '/api/chat/rooms',
        );

        if (chatResponse != null && chatResponse.statusCode == 200) {
          final data = json.decode(chatResponse.body);
          if (data['rooms'] is List && (data['rooms'] as List).isNotEmpty) {
            // This station has chat rooms, add a chat collection
            collections.add(RemoteCollection(
              name: 'Chat',
              deviceCallsign: device.callsign,
              type: 'chat',
              description: '${(data['rooms'] as List).length} rooms',
              fileCount: (data['rooms'] as List).length,
            ));
          }
        }
      } catch (e) {
        LogService().log('DevicesService: Error fetching chat rooms: $e');
      }
    }

    // Update device and cache if we got collections
    if (collections.isNotEmpty) {
      await _updateDeviceCollections(device, collections);
      return collections;
    }

    // Fall back to cached collections
    return await _loadCachedCollections(device.callsign);
  }

  /// Update device with fetched collections and cache them
  Future<void> _updateDeviceCollections(RemoteDevice device, List<RemoteCollection> collections) async {
    device.collections = collections;
    device.lastFetched = DateTime.now();

    // Cache the collections if we got any
    if (collections.isNotEmpty) {
      await _cacheCollections(device.callsign, collections);
    }

    _notifyListeners();
  }

  /// Check if folder name is a known collection type
  bool _isKnownCollectionType(String name) {
    const knownTypes = {
      'chat', 'forum', 'blog', 'events', 'news',
      'www', 'postcards', 'contacts', 'places',
      'market', 'alerts', 'groups',
    };
    return knownTypes.contains(name.toLowerCase());
  }

  /// Load cached collections for offline browsing
  Future<List<RemoteCollection>> _loadCachedCollections(String callsign) async {
    try {
      final cacheDir = await _cacheService.getDeviceCacheDir(callsign);
      if (cacheDir == null) return [];

      final collectionsFile = File('${cacheDir.path}/collections.json');

      if (await collectionsFile.exists()) {
        final content = await collectionsFile.readAsString();
        final data = json.decode(content) as List;

        return data.map((item) => RemoteCollection.fromJson(item, callsign)).toList();
      }
    } catch (e) {
      LogService().log('DevicesService: Error loading cached collections: $e');
    }

    return [];
  }

  /// Cache collections for offline access
  Future<void> _cacheCollections(String callsign, List<RemoteCollection> collections) async {
    try {
      final cacheDir = await _cacheService.getDeviceCacheDir(callsign);
      if (cacheDir == null) return;

      final collectionsFile = File('${cacheDir.path}/collections.json');

      final data = collections.map((c) => c.toJson()).toList();
      await collectionsFile.writeAsString(json.encode(data));
    } catch (e) {
      LogService().log('DevicesService: Error caching collections: $e');
    }
  }

  /// Save device status to disk cache for offline access
  Future<void> _saveDeviceStatusCache(RemoteDevice device) async {
    try {
      final cacheDir = await _cacheService.getDeviceCacheDir(device.callsign);
      if (cacheDir == null) return;

      final statusFile = File('${cacheDir.path}/status.json');
      final data = {
        'callsign': device.callsign,
        'nickname': device.nickname,
        'description': device.description,
        'color': device.preferredColor,
        'platform': device.platform,
        'latitude': device.latitude,
        'longitude': device.longitude,
        'npub': device.npub,
        'url': device.url,
        'lastSeen': device.lastSeen?.toIso8601String(),
        'lastFetched': device.lastFetched?.toIso8601String(),
        'connectionMethods': device.connectionMethods,
        'bleProximity': device.bleProximity,
        'bleRssi': device.bleRssi,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      await statusFile.writeAsString(json.encode(data));
    } catch (e) {
      LogService().log('DevicesService: Error saving status cache: $e');
    }
  }

  /// Load device status from disk cache
  Future<Map<String, dynamic>?> _loadDeviceStatusCache(String callsign) async {
    try {
      final cacheDir = await _cacheService.getDeviceCacheDir(callsign);
      if (cacheDir == null) return null;

      final statusFile = File('${cacheDir.path}/status.json');
      if (await statusFile.exists()) {
        final content = await statusFile.readAsString();
        return json.decode(content) as Map<String, dynamic>;
      }
    } catch (e) {
      LogService().log('DevicesService: Error loading status cache: $e');
    }
    return null;
  }

  /// Add a device from discovery or manual entry
  Future<void> addDevice(String callsign, {String? name, String? url, bool isOnline = false}) async {
    final normalizedCallsign = callsign.toUpperCase();

    if (!_devices.containsKey(normalizedCallsign)) {
      _devices[normalizedCallsign] = RemoteDevice(
        callsign: normalizedCallsign,
        name: name ?? normalizedCallsign,
        url: url,
        isOnline: isOnline,
        hasCachedData: false,
        collections: [],
      );
      _notifyListeners();
    } else {
      // Device exists, update it
      final device = _devices[normalizedCallsign]!;
      if (url != null) device.url = url;
      if (name != null) device.name = name;
      if (isOnline) {
        device.isOnline = true;
        device.lastSeen = DateTime.now();
      }
      _notifyListeners();
    }
  }

  /// Remove a device
  Future<void> removeDevice(String callsign) async {
    final normalizedCallsign = callsign.toUpperCase();
    _devices.remove(normalizedCallsign);
    await _cacheService.clearCache(normalizedCallsign);
    _notifyListeners();
  }

  /// Notify listeners of changes
  void _notifyListeners() {
    _devicesController.add(getAllDevices());
  }

  /// Send a direct message to another device
  Future<void> _sendDirectMessage(String callsign, String content) async {
    try {
      final dmService = DirectMessageService();
      await dmService.initialize();
      await dmService.sendMessage(callsign, content);
      LogService().log('DevicesService: DM sent to $callsign');
    } catch (e) {
      LogService().log('DevicesService: Error sending DM to $callsign: $e');
    }
  }

  /// Sync DM messages with a remote device
  Future<void> _syncDirectMessages(String callsign, String? deviceUrl) async {
    try {
      // Try to find device URL if not provided
      String? url = deviceUrl;
      if (url == null) {
        final device = getDevice(callsign);
        url = device?.url;
      }

      if (url == null) {
        LogService().log('DevicesService: No URL for DM sync with $callsign');
        return;
      }

      final dmService = DirectMessageService();
      await dmService.initialize();
      final result = await dmService.syncWithDevice(callsign, deviceUrl: url);

      if (result.success) {
        LogService().log('DevicesService: DM sync with $callsign - received: ${result.messagesReceived}, sent: ${result.messagesSent}');
      } else {
        LogService().log('DevicesService: DM sync with $callsign failed: ${result.error}');
      }
    } catch (e) {
      LogService().log('DevicesService: Error syncing DMs with $callsign: $e');
    }
  }

  /// Dispose resources
  void dispose() {
    _bleSubscription?.cancel();
    _bleChatSubscription?.cancel();
    _debugSubscription?.cancel();
    _stationConnectionSubscription?.cancel();
    _profileChangedSubscription?.cancel();
    _bleService?.dispose();
    _bleMessageService?.dispose();
    _devicesController.close();
    _bleChatController.close();
  }
}

/// Represents a remote device
class RemoteDevice {
  final String callsign;
  String name;
  String? nickname;
  String? url;
  String? npub;
  bool isOnline;
  int? latency;
  DateTime? lastChecked;
  DateTime? lastSeen;
  DateTime? lastFetched;
  bool hasCachedData;
  List<RemoteCollection> collections;
  double? latitude;
  double? longitude;
  List<String> connectionMethods;
  DeviceSourceType source;
  bool isPinned;
  String? folderId;  // Folder this device belongs to (null = default "Discovered" folder)

  /// BLE-specific fields
  String? bleProximity;  // "Very close", "Nearby", "In range", "Far"
  int? bleRssi;          // Signal strength in dBm

  /// User's preferred color from profile
  String? preferredColor;

  /// User's profile description
  String? description;

  /// Operating system: "linux", "macos", "windows", "android", "ios"
  String? platform;

  RemoteDevice({
    required this.callsign,
    required this.name,
    this.nickname,
    this.url,
    this.npub,
    this.isOnline = false,
    this.latency,
    this.lastChecked,
    this.lastSeen,
    this.lastFetched,
    this.hasCachedData = false,
    required this.collections,
    this.latitude,
    this.longitude,
    this.connectionMethods = const [],
    this.source = DeviceSourceType.local,
    this.bleProximity,
    this.bleRssi,
    this.preferredColor,
    this.description,
    this.platform,
    this.isPinned = false,
    this.folderId,
  });

  /// Get display name (nickname or callsign)
  String get displayName => nickname ?? name;

  /// Get connection method display label
  static String getConnectionMethodLabel(String method) {
    switch (method.toLowerCase()) {
      case 'wifi':
      case 'wifi_local':
      case 'wifi-local':
        return 'LAN';
      case 'internet':
        return 'Internet';
      case 'bluetooth':
        return 'BLE';
      case 'bluetooth_plus':
      case 'ble_plus':
      case 'ble+':
        return 'BLE+';
      case 'lora':
        return 'LoRa';
      case 'radio':
        return 'Radio';
      case 'esp32mesh':
      case 'esp32_mesh':
        return 'ESP32 Mesh';
      case 'wifi_halow':
      case 'wifi-halow':
      case 'halow':
        return 'Wi-Fi HaLow';
      case 'lan':
        return 'LAN';
      default:
        return method;
    }
  }

  /// Get status string
  String get statusText {
    if (isOnline) {
      if (latency != null) {
        return 'Online (${latency}ms)';
      }
      return 'Online';
    }
    return 'Offline';
  }

  /// Get last activity time
  String get lastActivityText {
    final time = lastSeen ?? lastFetched ?? lastChecked;
    if (time == null) return 'Never';

    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.day}/${time.month}/${time.year}';
  }

  /// Calculate distance from given coordinates using Haversine formula
  /// Returns distance in kilometers, or null if location is unavailable
  double? calculateDistance(double? userLat, double? userLon) {
    if (latitude == null || longitude == null || userLat == null || userLon == null) {
      return null;
    }

    const double earthRadiusKm = 6371.0;

    final dLat = _degreesToRadians(userLat - latitude!);
    final dLon = _degreesToRadians(userLon - longitude!);

    final lat1 = _degreesToRadians(latitude!);
    final lat2 = _degreesToRadians(userLat);

    final a = (sin(dLat / 2) * sin(dLat / 2)) +
              (sin(dLon / 2) * sin(dLon / 2)) * cos(lat1) * cos(lat2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return earthRadiusKm * c;
  }

  static double _degreesToRadians(double degrees) {
    return degrees * pi / 180;
  }

  /// Get human-readable distance string
  String? getDistanceString(double? userLat, double? userLon) {
    final distance = calculateDistance(userLat, userLon);
    if (distance == null) return null;

    if (distance < 1) {
      return '${(distance * 1000).round()} m away';
    } else {
      return '${distance.round()} km away';
    }
  }
}

/// Represents a collection on a remote device
class RemoteCollection {
  final String name;
  final String deviceCallsign;
  final String type;
  final String? description;
  final int? fileCount;
  final String? visibility;

  RemoteCollection({
    required this.name,
    required this.deviceCallsign,
    required this.type,
    this.description,
    this.fileCount,
    this.visibility,
  });

  factory RemoteCollection.fromJson(Map<String, dynamic> json, String deviceCallsign) {
    return RemoteCollection(
      name: json['name'] ?? json['id'] ?? 'Unknown',
      deviceCallsign: deviceCallsign,
      type: json['type'] ?? 'files',
      description: json['description'],
      fileCount: json['fileCount'] ?? json['file_count'],
      visibility: json['visibility'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type,
      'description': description,
      'fileCount': fileCount,
      'visibility': visibility,
    };
  }

  /// Get icon for collection type
  String get iconName {
    switch (type) {
      case 'chat': return 'chat';
      case 'blog': return 'article';
      case 'forum': return 'forum';
      case 'contacts': return 'contacts';
      case 'events': return 'event';
      case 'places': return 'place';
      case 'news': return 'newspaper';
      case 'www': return 'language';
      case 'documents': return 'description';
      case 'photos': return 'photo_library';
      default: return 'folder';
    }
  }
}

/// Represents a folder for organizing devices
class DeviceFolder {
  String id;
  String name;
  final bool isDefault;
  bool isExpanded;
  int order;  // Lower number = higher in list

  DeviceFolder({
    required this.id,
    required this.name,
    this.isDefault = false,
    this.isExpanded = true,
    this.order = 0,
  });

  factory DeviceFolder.fromJson(Map<String, dynamic> json) {
    return DeviceFolder(
      id: json['id'] as String,
      name: json['name'] as String,
      isDefault: json['isDefault'] as bool? ?? false,
      isExpanded: json['isExpanded'] as bool? ?? true,
      order: json['order'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'isDefault': isDefault,
      'isExpanded': isExpanded,
      'order': order,
    };
  }
}
