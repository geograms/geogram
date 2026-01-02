/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:convert';
import 'package:path/path.dart' as path;
import '../models/collection.dart';
import '../models/chat_channel.dart';
import '../models/chat_message.dart';
import '../models/chat_settings.dart';
import '../models/station_chat_room.dart';
import '../models/update_notification.dart';
import '../services/chat_service.dart';
import '../services/profile_service.dart';
import '../services/station_service.dart';
import '../services/station_cache_service.dart';
import '../services/chat_notification_service.dart';
import '../services/log_service.dart';
import '../services/i18n_service.dart';
import '../services/debug_controller.dart';
import '../services/group_sync_service.dart';
import '../services/signing_service.dart';
import '../models/device_source.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import '../util/event_bus.dart';
import '../widgets/device_chat_sidebar.dart';
import '../widgets/message_list_widget.dart';
import '../widgets/message_input_widget.dart';
import '../widgets/new_channel_dialog.dart';
import '../widgets/voice_recorder_widget.dart';
import '../services/audio_service.dart';
import '../services/audio_platform_stub.dart'
    if (dart.library.io) '../services/audio_platform_io.dart';
import 'chat_settings_page.dart';
import 'room_management_page.dart';
import 'photo_viewer_page.dart';
import '../platform/file_image_helper.dart' as file_helper;

/// Page for browsing and interacting with a chat collection
class ChatBrowserPage extends StatefulWidget {
  final Collection? collection;

  /// For browsing a remote device's chat
  final String? remoteDeviceUrl;
  final String? remoteDeviceCallsign;
  final String? remoteDeviceName;

  /// Optional room ID to auto-select on load
  final String? initialRoomId;

  const ChatBrowserPage({
    Key? key,
    this.collection,
    this.remoteDeviceUrl,
    this.remoteDeviceCallsign,
    this.remoteDeviceName,
    this.initialRoomId,
  }) : super(key: key);

  /// Whether this is browsing a remote device
  bool get isRemoteDevice => remoteDeviceUrl != null;

  @override
  State<ChatBrowserPage> createState() => _ChatBrowserPageState();
}

class _ChatBrowserPageState extends State<ChatBrowserPage> {
  final ChatService _chatService = ChatService();
  final ProfileService _profileService = ProfileService();
  final StationService _stationService = StationService();
  final RelayCacheService _cacheService = RelayCacheService();
  final ChatNotificationService _chatNotificationService = ChatNotificationService();
  final I18nService _i18n = I18nService();

  List<ChatChannel> _channels = [];
  ChatChannel? _selectedChannel;
  List<ChatMessage> _messages = [];
  static const int _pageSize = 100;
  static const int _stationIncrementalLimit = 200;
  int _localMessageLimit = _pageSize;
  int _stationMessageLimit = _pageSize;
  ChatMessage? _quotedMessage;
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;

  // Station chat rooms (for the primary/connected station)
  List<StationChatRoom> _stationRooms = [];
  StationChatRoom? _selectedStationRoom;
  List<StationChatMessage> _stationMessages = [];
  final Map<String, List<StationChatMessage>> _stationMessageCache = {};
  bool _loadingRelayRooms = false;
  bool _stationReachable = false; // Track if station is currently reachable (default false until confirmed)
  bool _forcedOfflineMode = false; // True when viewing a device explicitly marked as offline
  bool _isStationSending = false; // Sending message to station room
  bool _isStationRecording = false; // Recording voice for station room
  final Set<String> _recentlyUploadedFiles = {}; // Track files we just uploaded to skip re-downloading

  // All cached devices with their rooms (for offline viewing)
  List<CachedDeviceRooms> _cachedDeviceSources = [];

  // Remember last station info for cache loading when disconnected
  String? _lastStationUrl;
  String? _lastRelayCacheKey;

  // Update notification subscription
  StreamSubscription<UpdateNotification>? _updateSubscription;

  // Unread counts subscription
  StreamSubscription<Map<String, int>>? _unreadSubscription;
  Map<String, int> _unreadCounts = {};

  // Station status check timer
  Timer? _stationStatusTimer;

  // Station message polling timer (fallback for when WebSocket updates don't work)
  Timer? _messagePollingTimer;

  // Debounce timer for update notifications (prevents duplicate refreshes)
  Timer? _updateDebounceTimer;
  bool _isRefreshingMessages = false;

  // File change subscription for CLI/external updates
  StreamSubscription<ChatFileChange>? _fileChangeSubscription;

  // Debug action subscription for select_chat_room
  StreamSubscription<DebugActionEvent>? _debugActionSubscription;

  // Local collection paths for group synchronization
  String? _localChatCollectionPath;
  String? _groupsCollectionPath;

  @override
  void initState() {
    super.initState();
    _initializeChat();
    _setupUpdateListener();
    _subscribeToUnreadCounts();
    _subscribeToFileChanges();
    _subscribeToDebugActions();
    _startRelayStatusChecker();
    _startMessagePolling();
  }

  /// Listen for debug API actions to select a chat room or send messages
  void _subscribeToDebugActions() {
    _debugActionSubscription = DebugController().actionStream.listen((event) {
      if (event.action == DebugAction.selectChatRoom) {
        final roomId = event.params?['room_id'] as String?;
        if (roomId != null) {
          print('DEBUG ChatBrowserPage: received selectChatRoom for $roomId');
          _autoSelectRoom(roomId);
        }
      } else if (event.action == DebugAction.sendChatMessage) {
        final content = event.params?['content'] as String? ?? '';
        final imagePath = event.params?['image_path'] as String?;
        print('DEBUG ChatBrowserPage: received sendChatMessage content="$content" image=$imagePath');
        _handleDebugSendMessage(content, imagePath);
      }
    });
  }

  /// Handle sending a message from debug API
  Future<void> _handleDebugSendMessage(String content, String? imagePath) async {
    if (_selectedStationRoom == null) {
      print('DEBUG ChatBrowserPage: no room selected, cannot send message');
      return;
    }

    // Resolve relative image path to absolute
    String? resolvedImagePath = imagePath;
    if (imagePath != null && !imagePath.startsWith('/')) {
      // Resolve relative to project's tests/images folder
      resolvedImagePath = '/home/brito/code/geograms/geogram/$imagePath';
      print('DEBUG ChatBrowserPage: resolved image path to $resolvedImagePath');
    }

    // Verify the image exists
    if (resolvedImagePath != null) {
      final file = File(resolvedImagePath);
      if (!await file.exists()) {
        print('DEBUG ChatBrowserPage: image file not found at $resolvedImagePath');
        return;
      }
    }

    print('DEBUG ChatBrowserPage: sending message to room ${_selectedStationRoom!.id}');
    await _sendMessage(content, resolvedImagePath);
    print('DEBUG ChatBrowserPage: message sent');
  }

  void _setStateIfMounted(VoidCallback callback) {
    if (!mounted) return;
    setState(callback);
  }

  /// Subscribe to file changes for real-time updates from CLI
  void _subscribeToFileChanges() {
    _fileChangeSubscription = _chatService.onFileChange.listen((change) {
      // Reload messages if the changed channel is currently selected
      if (_selectedChannel != null && _selectedChannel!.id == change.channelId) {
        _refreshLocalMessages();
      }
    });
    // Note: startWatching() is called after channels are loaded in _initializeChat
  }

  /// Refresh local channel messages without showing loading indicator
  Future<void> _refreshLocalMessages() async {
    if (_selectedChannel == null) return;

    try {
      final messages = await _chatService.loadMessages(
        _selectedChannel!.id,
        limit: _localMessageLimit,
      );

      if (mounted) {
        setState(() {
          _messages = messages;
        });
      }
    } catch (e) {
      // Silently fail on refresh errors
    }
  }

  void _subscribeToUnreadCounts() {
    _unreadCounts = _chatNotificationService.unreadCounts;
    _unreadSubscription = _chatNotificationService.unreadCountsStream.listen((counts) {
      _setStateIfMounted(() {
        _unreadCounts = counts;
      });
    });
  }

  @override
  void dispose() {
    _updateSubscription?.cancel();
    _unreadSubscription?.cancel();
    _fileChangeSubscription?.cancel();
    _debugActionSubscription?.cancel();
    _chatService.stopWatching();
    _stationStatusTimer?.cancel();
    _messagePollingTimer?.cancel();
    _updateDebounceTimer?.cancel();
    super.dispose();
  }

  /// Set up listener for real-time update notifications
  void _setupUpdateListener() {
    final updates = _stationService.updates;
    if (updates == null) return;

    // Cancel existing subscription - the stream might have changed after reconnection
    _updateSubscription?.cancel();
    _updateSubscription = updates.listen(_handleUpdateNotification);
    LogService().log('Setting up real-time update listener');
  }

  /// Handle incoming update notification
  void _handleUpdateNotification(UpdateNotification update) {
    // Only handle chat updates
    if (update.collectionType == 'chat') {
      // Refresh if we're viewing the room that got updated
      if (_selectedStationRoom != null && _selectedStationRoom!.id == update.path) {
        // Debounce to prevent duplicate refreshes (server sends multiple WebSocket messages)
        _updateDebounceTimer?.cancel();
        _updateDebounceTimer = Timer(const Duration(milliseconds: 300), () {
          _refreshRelayMessages();
        });
      }
    }
  }

  /// Refresh station messages without showing loading indicator
  Future<void> _refreshRelayMessages() async {
    // Prevent overlapping refreshes
    if (_isRefreshingMessages) return;
    _isRefreshingMessages = true;
    try {
      await _syncStationMessages();
    } finally {
      _isRefreshingMessages = false;
    }
  }

  /// Ensure WebSocket is connected for real-time updates
  Future<void> _ensureWebSocketConnection(String stationUrl) async {
    // Check if already connected
    if (_stationService.updates != null) {
      _setupUpdateListener();
      return;
    }

    // Connect to station via WebSocket
    final success = await _stationService.connectRelay(stationUrl);

    if (success) {
      // Small delay to ensure WebSocket is ready
      await Future.delayed(const Duration(milliseconds: 500));
      // Set up update listener now that WebSocket is connected
      _setupUpdateListener();
    }
  }

  /// Start periodic station status checker
  void _startRelayStatusChecker() {
    // Check every 10 seconds - not too frequent to avoid flashing online/offline indicator
    _stationStatusTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkRelayStatus(),
    );
  }

  /// Start periodic message polling (fallback since WebSocket updates don't work reliably)
  void _startMessagePolling() {
    _messagePollingTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _pollForNewMessages(),
    );
  }

  /// Poll for new messages in the currently selected station room
  Future<void> _pollForNewMessages() async {
    // Only poll if viewing a station room and station is reachable
    if (_selectedStationRoom == null || !_stationReachable) return;

    try {
      await _syncStationMessages();
    } catch (e) {
      // Silently fail - don't disrupt user experience
    }
  }

  Future<void> _syncStationMessages() async {
    if (_selectedStationRoom == null) return;
    final cacheKey = _lastRelayCacheKey ?? '';
    if (cacheKey.isEmpty) return;

    try {
      final roomId = _selectedStationRoom!.id;
      final cached = _stationMessageCache[roomId];
      final latestCached = cached != null && cached.isNotEmpty
          ? cached.last
          : (_stationMessages.isNotEmpty ? _stationMessages.last : null);
      DateTime? after;
      final latestDateTime = latestCached?.dateTime;
      if (latestDateTime != null) {
        after = DateTime(latestDateTime.year, latestDateTime.month, latestDateTime.day);
      }
      final limit = after == null ? _stationMessageLimit : _stationIncrementalLimit;

      final newMessages = await _stationService.fetchRoomMessages(
        _selectedStationRoom!.stationUrl,
        roomId,
        limit: limit,
        after: after,
      );

      if (newMessages.isEmpty) return;

      final previousLatest = _stationMessages.isNotEmpty ? _stationMessages.last.timestamp : null;

      await _cacheService.mergeMessages(cacheKey, roomId, newMessages);
      final cachedMessages = await _cacheService.loadMessages(
        cacheKey,
        roomId,
        limit: _stationMessageLimit,
      );

      if (!mounted) return;

      _stationMessageCache[roomId] = cachedMessages;
      final latestMsg = cachedMessages.isNotEmpty ? cachedMessages.last : null;
      if (latestMsg != null && latestMsg.timestamp != previousLatest) {
        print('');
        print('╔══════════════════════════════════════════════════════════════╗');
        print('║  NEW MESSAGE RECEIVED                                        ║');
        print('╠══════════════════════════════════════════════════════════════╣');
        print('║  Room: $roomId');
        print('║  From: ${latestMsg.callsign}');
        print('║  Content: ${latestMsg.content}');
        print('║  Time: ${latestMsg.timestamp}');
        print('╚══════════════════════════════════════════════════════════════╝');
        print('');
      }
      _applyStationMessageLimit(cachedMessages);
    } catch (e) {
      // Silently fail - user is already viewing messages
    }
  }

  /// Check if station is reachable and update UI if status changed
  Future<void> _checkRelayStatus() async {
    if (_lastStationUrl == null || _lastStationUrl!.isEmpty) return;

    // Don't auto-reconnect if user is viewing in forced offline mode
    if (_forcedOfflineMode) return;

    // Try to set up update listener if not already done (WebSocket might be ready now)
    _setupUpdateListener();

    final wasReachable = _stationReachable;

    try {
      // Try to fetch rooms - if it succeeds, station is reachable
      final rooms = await _stationService.fetchChatRooms(_lastStationUrl!);

      if (!mounted) return;

      // Station is now reachable
      if (!wasReachable) {
        LogService().log('Station status changed: offline -> online');
        setState(() {
          _stationReachable = true;
          _stationRooms = rooms;
        });
      }

      // Poll for new messages if viewing a room (fallback when WebSocket not connected)
      if (_selectedStationRoom != null && _updateSubscription == null) {
        // WebSocket not connected - poll for updates
        _refreshRelayMessages();
      }
    } catch (e) {
      // Station is not reachable
      if (mounted && wasReachable) {
        LogService().log('Station status changed: online -> offline');
        setState(() {
          _stationReachable = false;
        });
      }
    }
  }

  /// Initialize chat service and load data
  Future<void> _initializeChat() async {
    LogService().log('DEBUG _initializeChat: STARTING, isRemoteDevice=${widget.isRemoteDevice}');
    _setStateIfMounted(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // For remote device, skip local channel initialization
      if (widget.isRemoteDevice) {
        LogService().log('DEBUG _initializeChat: Remote device mode - loading from ${widget.remoteDeviceUrl}');
        _setStateIfMounted(() {
          _isInitialized = true;
        });
        // Load station chat rooms from the remote device
        await _loadRelayRooms();
        return;
      }

      // Initialize chat service with collection path (local mode)
      final storagePath = widget.collection?.storagePath;
      if (storagePath == null) {
        throw Exception('Collection storage path is null');
      }

      // Pass current user's npub to initialize admin if needed
      final currentProfile = _profileService.getProfile();
      await _chatService.initializeCollection(
        storagePath,
        creatorNpub: currentProfile.npub,
      );

      _localChatCollectionPath = storagePath;
      _groupsCollectionPath =
          await GroupSyncService().findCollectionPathByType('groups');
      if (_groupsCollectionPath != null) {
        await GroupSyncService().syncGroupsCollection(
          groupsCollectionPath: _groupsCollectionPath!,
          chatCollectionPath: storagePath,
        );
      }

      await _chatService.refreshChannels();
      _channels = _chatService.channels;

      // Start watching for file changes now that channels are loaded
      _chatService.startWatching();

      _setStateIfMounted(() {
        _isInitialized = true;
      });

      // Load station chat rooms - MUST await to ensure rooms are loaded before UI renders
      await _loadRelayRooms();

      // Auto-select room after UI is ready
      if (widget.initialRoomId != null && mounted) {
        // Schedule selection after frame to ensure UI is ready
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _autoSelectRoom(widget.initialRoomId!);
        });
      } else if (mounted && _stationRooms.isNotEmpty) {
        // Wide screen auto-select first room
        final screenWidth = MediaQuery.of(context).size.width;
        if (screenWidth >= 600) {
          await _selectRelayRoom(_stationRooms.first);
        }
      }
    } catch (e) {
      _setStateIfMounted(() {
        _error = 'Failed to initialize chat: $e';
      });
    } finally {
      _setStateIfMounted(() {
        _isLoading = false;
      });
    }
  }

  /// Load station chat rooms from preferred station (uses HTTP API, doesn't require WebSocket)
  Future<void> _loadRelayRooms() async {
    LogService().log('DEBUG _loadRelayRooms: STARTING, isRemoteDevice=${widget.isRemoteDevice}');

    _setStateIfMounted(() {
      _loadingRelayRooms = true;
    });

    // Initialize cache service
    await _cacheService.initialize();
    LogService().log('DEBUG _loadRelayRooms: cache initialized, will check for cached devices');

    // If browsing a remote device, use its URL directly
    if (widget.isRemoteDevice && widget.remoteDeviceUrl != null) {
      LogService().log('DEBUG _loadRelayRooms: Remote device mode - using URL ${widget.remoteDeviceUrl}');

      // Use widget-provided callsign as the canonical cache key (consistent for save and load)
      final cacheKey = widget.remoteDeviceCallsign ?? widget.remoteDeviceName ?? 'remote';
      _lastStationUrl = widget.remoteDeviceUrl;
      _lastRelayCacheKey = cacheKey;

      final cachedRooms = await _cacheService.loadChatRooms(cacheKey, _lastStationUrl ?? '');
      if (cachedRooms.isNotEmpty) {
        _setStateIfMounted(() {
          _stationRooms = cachedRooms;
          _stationReachable = false;
        });
      }

      // If initialRoomId is set, await the fetch so we can select the room
      // Otherwise use unawaited for faster UI response
      if (widget.initialRoomId != null) {
        await _fetchRelayRoomsFromRemote(cacheKey, widget.remoteDeviceUrl!);
      } else {
        unawaited(_fetchRelayRoomsFromRemote(cacheKey, widget.remoteDeviceUrl!));
      }
      return;
    }

    // Use preferred station for HTTP API calls - doesn't require WebSocket connection
    final station = _stationService.getPreferredStation();
    LogService().log('DEBUG _loadRelayRooms: station=${station?.name}, url=${station?.url}');

    // If station has a valid URL, try to fetch from it via HTTP API
    String? cacheKey;
    if (station != null && station.url.isNotEmpty) {
      cacheKey = station.callsign ?? station.name;
      _lastStationUrl = station.url;
      _lastRelayCacheKey = cacheKey;

      final cachedRooms = await _cacheService.loadChatRooms(cacheKey, station.url);
      if (cachedRooms.isNotEmpty) {
        _setStateIfMounted(() {
          _stationRooms = cachedRooms;
          _stationReachable = false;
        });
      }
    }

    // Load ALL cached devices with their rooms
    await _loadAllCachedDevices();

    LogService().log('DEBUG _loadRelayRooms: final _stationRooms.length=${_stationRooms.length}, cachedDevices=${_cachedDeviceSources.length}');

    if (station != null && station.url.isNotEmpty && cacheKey != null) {
      unawaited(_fetchRelayRoomsFromStation(cacheKey, station.url));
      return;
    }

    _setStateIfMounted(() {
      _stationReachable = false;
      _loadingRelayRooms = false;
    });
  }

  Future<void> _fetchRelayRoomsFromRemote(String cacheKey, String url) async {
    try {
      final rooms = await _stationService.fetchChatRooms(url);

      if (rooms.isNotEmpty) {
        await _cacheService.saveChatRooms(cacheKey, rooms, stationUrl: url);
      }

      _setStateIfMounted(() {
        _stationRooms = rooms;
        _stationReachable = true; // Successfully fetched - device is reachable
        _loadingRelayRooms = false;
      });

      await _ensureWebSocketConnection(url);
    } catch (e) {
      LogService().log('DEBUG _fetchRelayRoomsFromRemote: fetch failed: $e');
      _setStateIfMounted(() {
        _stationReachable = false;
        _loadingRelayRooms = false;
      });
    }
  }

  Future<void> _fetchRelayRoomsFromStation(String cacheKey, String url) async {
    try {
      final rooms = await _stationService.fetchChatRooms(url);

      if (rooms.isNotEmpty) {
        await _cacheService.saveChatRooms(cacheKey, rooms, stationUrl: url);
      }

      _setStateIfMounted(() {
        _stationRooms = rooms;
        _stationReachable = rooms.isNotEmpty;
        _loadingRelayRooms = false;
      });

      if (rooms.isNotEmpty) {
        await _ensureWebSocketConnection(url);
      }
    } catch (e) {
      LogService().log('DEBUG _fetchRelayRoomsFromStation: fetch failed: $e');
      _setStateIfMounted(() {
        _stationReachable = false;
        _loadingRelayRooms = false;
      });
    }
  }

  /// Load all cached devices and their chat rooms for offline viewing
  Future<void> _loadAllCachedDevices() async {
    final cachedDevices = await _cacheService.getCachedDevices();
    LogService().log('DEBUG _loadAllCachedDevices: found ${cachedDevices.length} cached devices');

    final List<CachedDeviceRooms> allCachedSources = [];

    for (final deviceCallsign in cachedDevices) {
      final cachedRooms = await _cacheService.loadChatRooms(deviceCallsign, '');
      final cachedUrl = await _cacheService.getCachedRelayUrl(deviceCallsign);
      final cacheTime = await _cacheService.getCacheTime(deviceCallsign);

      LogService().log('DEBUG _loadAllCachedDevices: device=$deviceCallsign, rooms=${cachedRooms.length}, url=$cachedUrl, cacheTime=$cacheTime');

      if (cachedRooms.isNotEmpty) {
        allCachedSources.add(CachedDeviceRooms(
          callsign: deviceCallsign,
          name: cachedRooms.first.stationName.isNotEmpty ? cachedRooms.first.stationName : deviceCallsign,
          url: cachedUrl,
          rooms: cachedRooms,
          isOnline: false, // Offline since we're loading from cache
          lastActivity: cacheTime,
        ));
      }
    }

    // Sort cached devices: online first, then by most recent activity
    allCachedSources.sort((a, b) {
      // Online devices first
      if (a.isOnline && !b.isOnline) return -1;
      if (!a.isOnline && b.isOnline) return 1;
      // Then by most recent activity (newest first)
      if (a.lastActivity == null && b.lastActivity == null) return 0;
      if (a.lastActivity == null) return 1;
      if (b.lastActivity == null) return -1;
      return b.lastActivity!.compareTo(a.lastActivity!);
    });

    // Set the most recent cached device as primary station rooms (AFTER sorting)
    if (_stationRooms.isEmpty && allCachedSources.isNotEmpty) {
      final mostRecent = allCachedSources.first;
      _lastRelayCacheKey = mostRecent.callsign;
      _lastStationUrl = mostRecent.url ?? (mostRecent.rooms.isNotEmpty ? mostRecent.rooms.first.stationUrl : null);
      _stationRooms = mostRecent.rooms;
    }

    _setStateIfMounted(() {
      _cachedDeviceSources = allCachedSources;
    });
  }

  /// Select a channel and load its messages
  Future<void> _selectChannel(ChatChannel channel) async {
    _setStateIfMounted(() {
      _selectedChannel = channel;
      _selectedStationRoom = null; // Deselect station room
      _isLoading = true;
      _localMessageLimit = _pageSize;
      _quotedMessage = null;
    });

    try {
      // Load messages for selected channel
      final messages = await _chatService.loadMessages(
        channel.id,
        limit: _localMessageLimit,
      );

      _setStateIfMounted(() {
        _messages = messages;
      });
    } catch (e) {
      _showError('Failed to load messages: $e');
    } finally {
      _setStateIfMounted(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMoreLocalMessages() async {
    if (_selectedChannel == null) return;

    _setStateIfMounted(() {
      _isLoading = true;
      _localMessageLimit += _pageSize;
    });

    try {
      final messages = await _chatService.loadMessages(
        _selectedChannel!.id,
        limit: _localMessageLimit,
      );

      _setStateIfMounted(() {
        _messages = messages;
      });
    } catch (e) {
      _showError('Failed to load more messages: $e');
    } finally {
      _setStateIfMounted(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMoreStationMessages() async {
    if (_selectedStationRoom == null) return;

    _setStateIfMounted(() {
      _isLoading = true;
      _stationMessageLimit += _pageSize;
    });

    final cached = _stationMessageCache[_selectedStationRoom!.id];
    if (cached != null) {
      _applyStationMessageLimit(cached, limit: _stationMessageLimit);
      return;
    }

    await _loadMessagesFromCache(_selectedStationRoom!.id, limit: _stationMessageLimit);
  }

  /// Select a channel for mobile view (just sets it, layout handles display)
  Future<void> _selectChannelMobile(ChatChannel channel) async {
    await _selectChannel(channel);
  }

  /// Select a station room from a specific device (handles cached devices)
  Future<void> _selectRelayRoomFromDevice(DeviceSource device, StationChatRoom room) async {
    // Update cache key to match the device we're selecting from
    if (device.callsign != null && device.callsign!.isNotEmpty) {
      _lastRelayCacheKey = device.callsign;
    }
    if (device.url != null && device.url!.isNotEmpty) {
      _lastStationUrl = device.url;
    }

    // Set reachability based on device status - this determines if we try online or cache first
    _stationReachable = device.isOnline;

    await _selectRelayRoom(room);
  }

  /// Auto-select a room by ID (used for debug API and initialRoomId)
  void _autoSelectRoom(String roomId) {
    // First check local channels (for folder group chats)
    final localChannels = _chatService.channels;
    final localChannel = localChannels.cast<ChatChannel?>().firstWhere(
      (c) => c?.id == roomId,
      orElse: () => null,
    );

    if (localChannel != null) {
      _selectChannel(localChannel);
      return;
    }

    // Then check station rooms
    if (_stationRooms.isEmpty) {
      return;
    }

    final room = _stationRooms.cast<StationChatRoom?>().firstWhere(
      (r) => r?.id == roomId,
      orElse: () => null,
    );

    if (room != null) {
      _selectRelayRoom(room);
    } else {
      // Fall back to first room if specified room not found
      _selectRelayRoom(_stationRooms.first);
    }
  }

  Future<void> _selectRelayRoom(StationChatRoom room) async {
    // Mark this room as current (clears unread count)
    _chatNotificationService.setCurrentRoom(room.id);

    _setStateIfMounted(() {
      _selectedStationRoom = room;
      _selectedChannel = null; // Deselect local channel
      _isLoading = true;
      _stationMessageLimit = _pageSize;
      _quotedMessage = null;
    });

    if (_stationMessageCache.containsKey(room.id)) {
      _applyStationMessageLimit(_stationMessageCache[room.id] ?? []);
      _setStateIfMounted(() {
        _isLoading = false;
      });
    } else {
      // Load cached messages first to avoid blocking on network
      await _loadMessagesFromCache(room.id, limit: _stationMessageLimit);
    }

    // If we already know the device is offline, skip network request
    if (!_stationReachable) {
      LogService().log('Device offline, using cached messages');
      return;
    }

    // Refresh in the background to fetch any new files
    unawaited(_refreshRelayMessages());
  }

  /// Load messages from cache for a room
  Future<void> _loadMessagesFromCache(String roomId, {int? limit}) async {
    if (_lastRelayCacheKey != null && _lastRelayCacheKey!.isNotEmpty) {
      final cachedMessages = await _cacheService.loadMessages(
        _lastRelayCacheKey!,
        roomId,
        limit: limit ?? _stationMessageLimit,
      );
      LogService().log('DEBUG _loadMessagesFromCache: Loaded ${cachedMessages.length} messages for room $roomId');
      _stationMessageCache[roomId] = cachedMessages;
      _applyStationMessageLimit(cachedMessages, limit: limit);
    } else {
      LogService().log('No cache key available');
      _setStateIfMounted(() {
        _stationMessages = [];
        _isLoading = false;
      });
      if (!_stationReachable) {
        _showError('No cached data available');
      }
    }
  }

  void _applyStationMessageLimit(List<StationChatMessage> messages, {int? limit}) {
    final effectiveLimit = limit ?? _stationMessageLimit;
    final trimmed = messages.length > effectiveLimit
        ? messages.sublist(messages.length - effectiveLimit)
        : messages;
    _setStateIfMounted(() {
      _stationMessages = trimmed;
      _isLoading = false;
    });

    // Fire event to notify MessageListWidget to scroll to bottom
    if (trimmed.isNotEmpty) {
      EventBus().fire(ChatMessagesLoadedEvent(
        roomId: _selectedStationRoom?.id,
        messageCount: trimmed.length,
      ));
    }
  }

  /// Download and cache raw chat files from the station
  /// Returns true if files were downloaded successfully
  Future<bool> _downloadAndCacheChatFiles(String stationUrl, String roomId, String cacheKey) async {
    try {
      // Fetch list of available chat files from station
      final files = await _stationService.fetchRoomChatFiles(stationUrl, roomId);
      LogService().log('Found ${files.length} chat files for room $roomId');

      if (files.isEmpty) {
        return false;
      }

      int downloadedCount = 0;

      // Download each file that isn't already cached
      for (final fileInfo in files) {
        final year = fileInfo['year'] as String;
        final filename = fileInfo['filename'] as String;
        final expectedSize = fileInfo['size'] as int?;

        // Check if file is already cached (with matching size)
        final isCached = await _cacheService.hasCachedChatFile(
          cacheKey,
          roomId,
          year,
          filename,
          expectedSize: expectedSize,
        );

        if (!isCached) {
          // Download the raw file content
          final content = await _stationService.fetchRoomChatFile(
            stationUrl,
            roomId,
            year,
            filename,
          );

          if (content != null && content.isNotEmpty) {
            // Save raw file to cache
            await _cacheService.saveRawChatFile(
              cacheKey,
              roomId,
              year,
              filename,
              content,
            );
            downloadedCount++;
            LogService().log('Cached $year/$filename');
          }
        }
      }

      if (downloadedCount > 0) {
        LogService().log('Downloaded $downloadedCount new chat files');
      }
      return true;
    } catch (e) {
      LogService().log('Error downloading chat files: $e');
      return false;
    }
  }

  /// Convert station messages to ChatMessage format for display
  List<ChatMessage> _convertStationMessages(List<StationChatMessage> stationMessages) {
    return stationMessages.map((rm) {
      // Build metadata map with verification info
      final metadata = <String, String>{};

      if (rm.metadata.isNotEmpty) {
        metadata.addAll(rm.metadata);
      }

      // Track if message has signature (from server response)
      if (rm.hasSignature) {
        metadata['has_signature'] = 'true';
        if (rm.signature != null && rm.signature!.isNotEmpty) {
          metadata['signature'] = rm.signature!;
        }
      }

      // Track verification status
      if (rm.verified) {
        metadata['verified'] = 'true';
      }

      if (rm.npub != null) {
        metadata['npub'] = rm.npub!;
      }

      return ChatMessage(
        author: rm.callsign,
        timestamp: rm.timestamp,
        content: rm.content,
        metadata: metadata.isNotEmpty ? metadata : null,
        reactions: rm.reactions,
      );
    }).toList();
  }

  /// Send a message
  Future<void> _sendMessage(String content, String? filePath) async {
    final currentProfile = _profileService.getProfile();
    if (currentProfile.callsign.isEmpty) {
      _showError('No active callsign. Please set up your profile first.');
      return;
    }

    // Handle station room message
    if (_selectedStationRoom != null) {
      setState(() {
        _isStationSending = true;
      });

      try {
        final metadata = <String, String>{};

        // Handle file attachment - upload to station first
        if (filePath != null) {
          final file = File(filePath);
          final fileSize = await file.length();
          if (fileSize > 10 * 1024 * 1024) {
            throw Exception(_i18n.t('file_too_large', params: ['10 MB']));
          }

          final uploadedFilename = await _stationService.uploadRoomFile(
            _selectedStationRoom!.stationUrl,
            _selectedStationRoom!.id,
            filePath,
          );

          if (uploadedFilename != null) {
            metadata['file'] = uploadedFilename;
            metadata['file_size'] = fileSize.toString();

            // Cache the file locally so we don't need to re-download it
            // and can show thumbnail immediately
            if (_lastRelayCacheKey != null && _selectedStationRoom != null) {
              final bytes = await file.readAsBytes();
              await _cacheService.saveChatFile(
                _lastRelayCacheKey!,
                _selectedStationRoom!.id,
                uploadedFilename,
                bytes,
              );
              LogService().log('Cached uploaded file locally: $uploadedFilename');
            }
          } else {
            throw Exception(_i18n.t('file_upload_failed'));
          }
        }

        if (_quotedMessage != null) {
          metadata['quote'] = _quotedMessage!.timestamp;
          metadata['quote_author'] = _quotedMessage!.author;
          if (_quotedMessage!.content.isNotEmpty) {
            final excerpt = _quotedMessage!.content.length > 120
                ? _quotedMessage!.content.substring(0, 120)
                : _quotedMessage!.content;
            metadata['quote_excerpt'] = excerpt;
          }
        }

        await _sendRelayMessage(
          content,
          metadata: metadata.isNotEmpty ? metadata : null,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$e'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      } finally {
        if (mounted) {
          setState(() {
            _isStationSending = false;
          });
        }
      }
      return;
    }

    if (_selectedChannel == null) return;

    try {
      // Load chat settings
      final settings = await _loadChatSettings();

      // Create message
      Map<String, String> metadata = {};

      // Handle file attachment
      String? attachedFileName;
      if (filePath != null) {
        attachedFileName = await _copyFileToChannel(filePath);
        if (attachedFileName != null) {
          metadata['file'] = attachedFileName;
        }
      }

      if (_quotedMessage != null) {
        metadata['quote'] = _quotedMessage!.timestamp;
        metadata['quote_author'] = _quotedMessage!.author;
        if (_quotedMessage!.content.isNotEmpty) {
          final excerpt = _quotedMessage!.content.length > 120
              ? _quotedMessage!.content.substring(0, 120)
              : _quotedMessage!.content;
          metadata['quote_excerpt'] = excerpt;
        }
      }

      // Add signing if enabled - uses BIP-340 Schnorr signature
      final signingService = SigningService();
      await signingService.initialize();
      if (settings.signMessages &&
          currentProfile.npub.isNotEmpty &&
          signingService.canSign(currentProfile)) {
        // Add npub for verification
        metadata['npub'] = currentProfile.npub;
        metadata['channel'] = _selectedChannel!.id;

        // Generate BIP-340 Schnorr signature (handles both extension and nsec)
        final signature = await signingService.generateSignature(
          content,
          metadata,
          currentProfile,
        );
        if (signature != null && signature.isNotEmpty) {
          metadata['signature'] = signature;
          metadata['verified'] = 'true'; // Self-signed messages are verified
        }
      }

      // Create message object
      final message = ChatMessage.now(
        author: currentProfile.callsign,
        content: content,
        metadata: metadata.isNotEmpty ? metadata : null,
      );

      // Save message
      await _chatService.saveMessage(_selectedChannel!.id, message);

      // Add to local list (optimistic update)
      _setStateIfMounted(() {
        _messages.add(message);
        _quotedMessage = null;
      });
    } catch (e) {
      _showError('Failed to send message: $e');
    }
  }

  /// Send a message to a station chat room as a signed NOSTR event
  Future<void> _sendRelayMessage(String content, {Map<String, String>? metadata}) async {
    if (_selectedStationRoom == null) return;

    // Check if station is reachable before trying to send
    if (!_stationReachable) {
      _showError('Cannot send message - station is offline');
      return;
    }

    final currentProfile = _profileService.getProfile();

    try {
      // Send as a properly signed NOSTR event (kind 1 text note)
      // StationService handles creating the event, signing with BIP-340 Schnorr,
      // and sending via WebSocket or HTTP
      // Returns the created_at timestamp (Unix seconds) on success, null on failure
      final createdAt = await _stationService.postRoomMessage(
        _selectedStationRoom!.stationUrl,
        _selectedStationRoom!.id,
        currentProfile.callsign,
        content,
        metadata: metadata,
      );

      if (createdAt != null) {
        // Optimistic update - use the SAME timestamp that was sent to the server
        // This ensures deduplication works when the server broadcasts the message back
        // IMPORTANT: Keep in UTC to match how server stores and cache normalizes timestamps
        final dt = DateTime.fromMillisecondsSinceEpoch(createdAt * 1000, isUtc: true);
        // Use normalized chat timestamp format: YYYY-MM-DD HH:MM_ss
        final timestamp = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}_${dt.second.toString().padLeft(2, '0')}';

        final newMessage = StationChatMessage(
          timestamp: timestamp,
          callsign: currentProfile.callsign,
          content: content,
          roomId: _selectedStationRoom!.id,
          metadata: metadata,
          npub: currentProfile.npub,
          verified: true,
          hasSignature: true,
        );

        // Track uploaded file to avoid re-downloading
        if (metadata != null && metadata.containsKey('file')) {
          _recentlyUploadedFiles.add(metadata['file']!);
        }

        _setStateIfMounted(() {
          _stationMessages.add(newMessage);
          final cached = List<StationChatMessage>.from(
            _stationMessageCache[_selectedStationRoom!.id] ?? [],
          );
          cached.add(newMessage);
          _stationMessageCache[_selectedStationRoom!.id] = cached;
          _quotedMessage = null;
        });

        // Cache the message locally (normalized timestamp will deduplicate with server response)
        if (_lastRelayCacheKey != null && _lastRelayCacheKey!.isNotEmpty) {
          await _cacheService.mergeMessages(
            _lastRelayCacheKey!,
            _selectedStationRoom!.id,
            [newMessage],
          );
        }
      } else {
        // Send failed - station may be unreachable
        _setStateIfMounted(() {
          _stationReachable = false;
        });
        _showError('Failed to send message - station offline');
      }
    } catch (e) {
      // Station became unreachable - update status
      _setStateIfMounted(() {
        _stationReachable = false;
      });
      _showError('Station offline - message not sent');
    }
  }

  /// Load chat settings
  Future<ChatSettings> _loadChatSettings() async {
    // Remote devices don't have local settings
    if (widget.isRemoteDevice || widget.collection == null) {
      return ChatSettings();
    }

    try {
      final storagePath = widget.collection!.storagePath;
      if (storagePath == null) return ChatSettings();

      final settingsFile =
          File(path.join(storagePath, 'extra', 'settings.json'));
      if (!await settingsFile.exists()) {
        return ChatSettings();
      }

      final content = await settingsFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return ChatSettings.fromJson(json);
    } catch (e) {
      return ChatSettings();
    }
  }

  /// Copy file to channel's files folder
  Future<String?> _copyFileToChannel(String sourceFilePath) async {
    // Not supported for remote devices
    if (widget.isRemoteDevice || widget.collection == null) {
      _showError('File attachments not supported for remote devices');
      return null;
    }

    try {
      final sourceFile = File(sourceFilePath);
      if (!await sourceFile.exists()) {
        _showError('File not found');
        return null;
      }

      // Determine destination folder
      final storagePath = widget.collection!.storagePath;
      if (storagePath == null) {
        _showError('Collection storage path is null');
        return null;
      }

      // For main channel, use year subfolder; for others, use channel folder directly
      String filesPath;
      if (_selectedChannel!.id == 'main') {
        final year = DateTime.now().year.toString();
        filesPath = path.join(storagePath, _selectedChannel!.folder, year, 'files');
      } else {
        filesPath = path.join(storagePath, _selectedChannel!.folder, 'files');
      }

      final filesDir = Directory(filesPath);

      // Create files directory if it doesn't exist
      if (!await filesDir.exists()) {
        await filesDir.create(recursive: true);
      }

      // Truncate filename if longer than 100 chars
      String fileName = path.basename(sourceFilePath);
      if (fileName.length > 100) {
        final ext = path.extension(fileName);
        final nameWithoutExt = path.basenameWithoutExtension(fileName);
        final maxNameLength = 100 - ext.length;
        fileName = nameWithoutExt.substring(0, maxNameLength) + ext;
      }

      final destPath = path.join(filesDir.path, fileName);
      var destFile = File(destPath);

      // Handle duplicate filenames
      int counter = 1;
      while (await destFile.exists()) {
        final nameWithoutExt = path.basenameWithoutExtension(fileName);
        final ext = path.extension(fileName);
        final newName = '${nameWithoutExt}_$counter$ext';
        destFile = File(path.join(filesDir.path, newName));
        counter++;
      }

      // Copy file
      await sourceFile.copy(destFile.path);

      return path.basename(destFile.path);
    } catch (e) {
      _showError('Failed to copy file: $e');
      return null;
    }
  }

  /// Check if user can delete a message
  bool _canDeleteMessage(ChatMessage message) {
    if (_selectedChannel == null) return false;

    final currentProfile = _profileService.getProfile();
    final userNpub = currentProfile.npub;

    final isOwnMessage = message.author.toUpperCase() == currentProfile.callsign.toUpperCase() ||
        (message.npub != null &&
         message.npub!.isNotEmpty &&
         userNpub.isNotEmpty &&
         message.npub == userNpub);

    if (isOwnMessage) return true;

    // Check if user is admin or moderator
    return _chatService.security.canModerate(userNpub, _selectedChannel!.id);
  }

  bool _canDeleteStationMessage(ChatMessage message) {
    final currentProfile = _profileService.getProfile();
    final isOwnMessage = message.author.toUpperCase() == currentProfile.callsign.toUpperCase() ||
        (message.npub != null &&
         message.npub!.isNotEmpty &&
         currentProfile.npub.isNotEmpty &&
         message.npub == currentProfile.npub);
    return isOwnMessage;
  }

  Future<void> _deleteStationMessage(ChatMessage message) async {
    if (_selectedStationRoom == null) return;
    if (!_canDeleteStationMessage(message)) return;

    try {
      final success = await _stationService.deleteRoomMessage(
        _selectedStationRoom!.stationUrl,
        _selectedStationRoom!.id,
        message.timestamp,
      );

      if (!success) {
        _showError('Failed to delete message');
        return;
      }

      final roomId = _selectedStationRoom!.id;
      final updated = List<StationChatMessage>.from(
        _stationMessageCache[roomId] ?? _stationMessages,
      );
      updated.removeWhere((msg) =>
          msg.timestamp == message.timestamp &&
          msg.callsign.toUpperCase() == message.author.toUpperCase());

      _stationMessageCache[roomId] = updated;
      _applyStationMessageLimit(updated);

      final cacheKey = _lastRelayCacheKey ?? '';
      if (cacheKey.isNotEmpty) {
        await _cacheService.removeMessage(
          cacheKey,
          roomId,
          message.timestamp,
          message.author,
        );
      }
    } catch (e) {
      _showError('Failed to delete message: $e');
    }
  }

  /// Delete a message
  Future<void> _deleteMessage(ChatMessage message) async {
    if (_selectedChannel == null) return;

    try {
      final currentProfile = _profileService.getProfile();
      final userNpub = currentProfile.npub;

      await _chatService.deleteMessageByTimestamp(
        channelId: _selectedChannel!.id,
        timestamp: message.timestamp,
        authorCallsign: message.author,
        actorNpub: userNpub,
      );

      // Remove from local list
      _setStateIfMounted(() {
        _messages.removeWhere((msg) =>
            msg.timestamp == message.timestamp && msg.author == message.author);
      });

      _showSuccess('Message deleted');
    } catch (e) {
      _showError('Failed to delete message: $e');
    }
  }

  Future<void> _toggleLocalReaction(ChatMessage message, String reaction) async {
    if (_selectedChannel == null) return;

    try {
      final currentProfile = _profileService.getProfile();
      final updated = await _chatService.toggleReaction(
        channelId: _selectedChannel!.id,
        timestamp: message.timestamp,
        actorCallsign: currentProfile.callsign,
        reaction: reaction,
      );

      if (updated == null) {
        _showError('Message not found');
        return;
      }

      _setStateIfMounted(() {
        final index = _messages.indexWhere((msg) =>
            msg.timestamp == updated.timestamp && msg.author == updated.author);
        if (index != -1) {
          _messages[index] = updated;
        }
      });
    } catch (e) {
      _showError('Failed to react: $e');
    }
  }

  Future<void> _toggleStationReaction(ChatMessage message, String reaction) async {
    if (_selectedStationRoom == null) return;

    final roomId = _selectedStationRoom!.id;
    final currentProfile = _profileService.getProfile();
    final myCallsign = currentProfile.callsign.toUpperCase();

    // Find the message in the list
    final messageList = List<StationChatMessage>.from(
      _stationMessageCache[roomId] ?? _stationMessages,
    );
    final index = messageList.indexWhere((msg) =>
        msg.timestamp == message.timestamp &&
        msg.callsign.toUpperCase() == message.author.toUpperCase());

    if (index == -1) return;

    final existing = messageList[index];
    final originalReactions = Map<String, List<String>>.from(
      existing.reactions.map((k, v) => MapEntry(k, List<String>.from(v))),
    );

    // Compute optimistic reactions (one reaction per user per message)
    final optimisticReactions = Map<String, List<String>>.from(
      existing.reactions.map((k, v) => MapEntry(k, List<String>.from(v))),
    );

    // Check if user already has this specific reaction (for toggle-off)
    final reactionList = optimisticReactions[reaction] ?? <String>[];
    final alreadyHasThisReaction = reactionList.any((c) => c.toUpperCase() == myCallsign);

    // Remove user from ALL reaction types first (enforce one reaction per user)
    for (final key in optimisticReactions.keys.toList()) {
      optimisticReactions[key]?.removeWhere((c) => c.toUpperCase() == myCallsign);
      if (optimisticReactions[key]?.isEmpty ?? true) {
        optimisticReactions.remove(key);
      }
    }

    // If clicking the same reaction they had, just remove it (toggle off)
    // Otherwise, add the new reaction
    if (!alreadyHasThisReaction) {
      final newList = optimisticReactions[reaction] ?? <String>[];
      newList.add(currentProfile.callsign);
      optimisticReactions[reaction] = newList;
    }

    // Apply optimistic update immediately (preserving all other fields including metadata)
    final optimisticMessage = StationChatMessage(
      timestamp: existing.timestamp,
      callsign: existing.callsign,
      content: existing.content,
      roomId: existing.roomId,
      metadata: existing.metadata,
      reactions: optimisticReactions,
      npub: existing.npub,
      pubkey: existing.pubkey,
      signature: existing.signature,
      eventId: existing.eventId,
      createdAt: existing.createdAt,
      verified: existing.verified,
      hasSignature: existing.hasSignature,
    );
    messageList[index] = optimisticMessage;
    _stationMessageCache[roomId] = messageList;
    _applyStationMessageLimit(messageList);

    // If station is offline, just keep the optimistic update (will sync later)
    if (!_stationReachable) {
      return;
    }

    // Now call server in background
    try {
      final serverReactions = await _stationService.toggleRoomReaction(
        _selectedStationRoom!.stationUrl,
        roomId,
        message.timestamp,
        reaction,
      );

      if (serverReactions == null) {
        // Server failed, revert to original
        _revertReaction(roomId, index, existing, originalReactions);
        _showError('Failed to react');
        return;
      }

      // Update with server's authoritative reactions (in case of race conditions)
      final serverMessage = StationChatMessage(
        timestamp: existing.timestamp,
        callsign: existing.callsign,
        content: existing.content,
        roomId: existing.roomId,
        metadata: existing.metadata,
        reactions: serverReactions,
        npub: existing.npub,
        pubkey: existing.pubkey,
        signature: existing.signature,
        eventId: existing.eventId,
        createdAt: existing.createdAt,
        verified: existing.verified,
        hasSignature: existing.hasSignature,
      );

      // Re-fetch the current list (might have changed during async operation)
      final currentList = List<StationChatMessage>.from(
        _stationMessageCache[roomId] ?? _stationMessages,
      );
      final currentIndex = currentList.indexWhere((msg) =>
          msg.timestamp == message.timestamp &&
          msg.callsign.toUpperCase() == message.author.toUpperCase());
      if (currentIndex != -1) {
        currentList[currentIndex] = serverMessage;
        _stationMessageCache[roomId] = currentList;
        _applyStationMessageLimit(currentList);

        // Persist to cache
        final cacheKey = _lastRelayCacheKey ?? '';
        if (cacheKey.isNotEmpty) {
          await _cacheService.mergeMessages(cacheKey, roomId, [serverMessage]);
        }
      }
    } catch (e) {
      // Server call failed, revert to original
      _revertReaction(roomId, index, existing, originalReactions);
      _showError('Failed to react: $e');
    }
  }

  /// Revert a reaction to original state after server failure
  void _revertReaction(
    String roomId,
    int originalIndex,
    StationChatMessage existing,
    Map<String, List<String>> originalReactions,
  ) {
    final currentList = List<StationChatMessage>.from(
      _stationMessageCache[roomId] ?? _stationMessages,
    );
    final currentIndex = currentList.indexWhere((msg) =>
        msg.timestamp == existing.timestamp &&
        msg.callsign.toUpperCase() == existing.callsign.toUpperCase());
    if (currentIndex != -1) {
      final revertedMessage = StationChatMessage(
        timestamp: existing.timestamp,
        callsign: existing.callsign,
        content: existing.content,
        roomId: existing.roomId,
        metadata: existing.metadata,
        reactions: originalReactions,
        npub: existing.npub,
        pubkey: existing.pubkey,
        signature: existing.signature,
        eventId: existing.eventId,
        createdAt: existing.createdAt,
        verified: existing.verified,
        hasSignature: existing.hasSignature,
      );
      currentList[currentIndex] = revertedMessage;
      _stationMessageCache[roomId] = currentList;
      _applyStationMessageLimit(currentList);
    }
  }

  void _setQuotedMessage(ChatMessage message) {
    _setStateIfMounted(() {
      _quotedMessage = message;
    });
  }

  void _clearQuotedMessage() {
    _setStateIfMounted(() {
      _quotedMessage = null;
    });
  }

  // ========== Station Room Voice Recording ==========

  /// Start voice recording for station room
  void _startStationRecording() async {
    if (!await AudioService().hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('microphone_permission_required'))),
        );
      }
      return;
    }
    setState(() {
      _isStationRecording = true;
    });
  }

  /// Cancel voice recording for station room
  void _cancelStationRecording() {
    setState(() {
      _isStationRecording = false;
    });
  }

  /// Send voice message to station room
  Future<void> _sendStationVoiceMessage(String filePath, int durationSeconds) async {
    if (_selectedStationRoom == null || !_stationReachable) return;

    setState(() {
      _isStationSending = true;
      _isStationRecording = false;
    });

    try {
      final currentProfile = _profileService.getProfile();

      // Validate file size (10 MB limit)
      final file = File(filePath);
      final fileSize = await file.length();
      if (fileSize > 10 * 1024 * 1024) {
        throw Exception(_i18n.t('file_too_large', params: ['10 MB']));
      }

      // Upload voice file to station
      final uploadedFilename = await _stationService.uploadRoomFile(
        _selectedStationRoom!.stationUrl,
        _selectedStationRoom!.id,
        filePath,
      );

      if (uploadedFilename == null) {
        throw Exception(_i18n.t('file_upload_failed'));
      }

      // Send message with voice metadata
      final metadata = <String, String>{
        'voice': uploadedFilename,
        'voice_duration': durationSeconds.toString(),
        'file_size': fileSize.toString(),
      };

      final createdAt = await _stationService.postRoomMessage(
        _selectedStationRoom!.stationUrl,
        _selectedStationRoom!.id,
        currentProfile.callsign,
        '', // Empty content for voice messages
        metadata: metadata,
      );

      if (createdAt != null) {
        // Refresh to show the new message
        await _refreshRelayMessages();
      } else {
        throw Exception(_i18n.t('failed_to_send_voice'));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_i18n.t('failed_to_send_voice')}: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isStationSending = false;
        });
      }
    }
  }

  /// Get voice file path for playback in station room messages
  Future<String?> _getStationVoiceFilePath(ChatMessage message) async {
    if (!message.hasVoice || message.voiceFile == null) return null;

    // Voice files use the same storage as regular file attachments
    return _getStationAttachmentPath(ChatMessage(
      author: message.author,
      content: message.content,
      timestamp: message.timestamp,
      metadata: {'file': message.voiceFile!},
    ));
  }

  /// Get attachment path for station room messages
  Future<String?> _getStationAttachmentPath(ChatMessage message) async {
    if (!message.hasFile) return null;

    final filename = message.attachedFile;
    if (filename == null) return null;
    if (_lastRelayCacheKey == null || _selectedStationRoom == null) return null;

    // Check if already cached
    final cachedPath = await _cacheService.getChatFilePath(
      _lastRelayCacheKey!,
      _selectedStationRoom!.id,
      filename,
    );

    if (cachedPath != null) {
      return cachedPath;
    }

    // Skip downloading files we just uploaded (bandwidth optimization)
    if (_recentlyUploadedFiles.contains(filename)) {
      LogService().log('Skipping download of recently uploaded file: $filename');
      return null;
    }

    // Check bandwidth-conscious download policy:
    // Auto-download only if file is <= 3 MB and message is <= 7 days old
    final fileSize = int.tryParse(message.getMeta('file_size') ?? '0') ?? 0;
    final messageAge = DateTime.now().difference(message.dateTime);
    final shouldAutoDownload = fileSize <= 3 * 1024 * 1024 && messageAge.inDays <= 7;

    if (!shouldAutoDownload || !_stationReachable) {
      return null;
    }

    try {
      // Download file from station
      final localPath = await _stationService.downloadRoomFile(
        _selectedStationRoom!.stationUrl,
        _selectedStationRoom!.id,
        filename,
        cacheKey: _lastRelayCacheKey,
      );

      return localPath;
    } catch (e) {
      LogService().log('Error downloading station attachment: $e');
      return null;
    }
  }

  /// Open image from station room message
  Future<void> _openStationImage(ChatMessage message) async {
    final filePath = await _getStationAttachmentPath(message);
    if (filePath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('image_not_available'))),
        );
      }
      return;
    }

    // Collect all image paths from station messages
    final imagePaths = <String>[];
    final convertedMessages = _convertStationMessages(_stationMessages);
    for (final msg in convertedMessages) {
      if (!msg.hasFile) continue;
      final imgPath = await _getStationAttachmentPath(msg);
      if (imgPath == null) continue;
      if (!_isImageFile(imgPath)) continue;
      imagePaths.add(imgPath);
    }

    if (imagePaths.isEmpty) {
      imagePaths.add(filePath);
    }

    var initialIndex = imagePaths.indexOf(filePath);
    if (initialIndex < 0) {
      imagePaths.add(filePath);
      initialIndex = imagePaths.length - 1;
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PhotoViewerPage(
          imagePaths: imagePaths,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  bool _isMessageHidden(ChatMessage message) {
    if (_selectedChannel == null) return false;
    return _chatService.isMessageHidden(_selectedChannel!.id, message);
  }

  Future<void> _hideMessage(ChatMessage message) async {
    if (_selectedChannel == null) return;

    try {
      await _chatService.hideMessage(_selectedChannel!.id, message);
      _setStateIfMounted(() {});
    } catch (e) {
      _showError('Failed to hide message: $e');
    }
  }

  Future<void> _unhideMessage(ChatMessage message) async {
    if (_selectedChannel == null) return;

    try {
      await _chatService.unhideMessage(_selectedChannel!.id, message);
      _setStateIfMounted(() {});
    } catch (e) {
      _showError('Failed to unhide message: $e');
    }
  }

  /// Open attached file
  Future<void> _openAttachedFile(ChatMessage message) async {
    if (!message.hasFile) return;

    // Not supported for remote devices
    if (widget.isRemoteDevice || widget.collection == null) {
      _showError('File attachments not supported for remote devices');
      return;
    }

    try {
      final storagePath = widget.collection!.storagePath;
      if (storagePath == null) {
        _showError('Collection storage path is null');
        return;
      }

      // Construct file path based on channel type
      String filePath;
      if (_selectedChannel!.id == 'main') {
        // For main channel, files are in year folders
        final year = message.dateTime.year.toString();
        filePath = path.join(
          storagePath,
          _selectedChannel!.folder,
          year,
          'files',
          message.attachedFile!,
        );
      } else {
        // For DM and group channels, files are in channel folder
        filePath = path.join(
          storagePath,
          _selectedChannel!.folder,
          'files',
          message.attachedFile!,
        );
      }

      if (_isImageFile(filePath)) {
        await _openAttachedImage(message);
        return;
      }

      final file = File(filePath);
      if (!await file.exists()) {
        _showError('File not found: ${message.attachedFile}');
        return;
      }

      // Open file with default application (using xdg-open on Linux)
      if (Platform.isLinux) {
        await Process.run('xdg-open', [filePath]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [filePath]);
      } else if (Platform.isWindows) {
        await Process.run('start', [filePath], runInShell: true);
      }
    } catch (e) {
      _showError('Failed to open file: $e');
    }
  }

  Future<String?> _resolveAttachedFilePath(ChatMessage message) async {
    if (!message.hasFile) return null;
    if (widget.isRemoteDevice || widget.collection == null) return null;

    final storagePath = widget.collection!.storagePath;
    if (storagePath == null) return null;
    if (_selectedChannel == null) return null;

    if (_selectedChannel!.id == 'main') {
      final year = message.dateTime.year.toString();
      return path.join(
        storagePath,
        _selectedChannel!.folder,
        year,
        'files',
        message.attachedFile!,
      );
    }

    return path.join(
      storagePath,
      _selectedChannel!.folder,
      'files',
      message.attachedFile!,
    );
  }

  bool _isImageFile(String pathOrName) {
    final lower = pathOrName.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  Future<void> _openAttachedImage(ChatMessage message) async {
    final filePath = await _resolveAttachedFilePath(message);
    if (filePath == null) {
      _showError('Image not available');
      return;
    }

    if (!file_helper.fileExists(filePath)) {
      _showError('File not found: ${message.attachedFile}');
      return;
    }

    final imagePaths = <String>[];
    for (final msg in _messages) {
      if (!msg.hasFile) continue;
      final path = await _resolveAttachedFilePath(msg);
      if (path == null) continue;
      if (!_isImageFile(path)) continue;
      if (!file_helper.fileExists(path)) continue;
      imagePaths.add(path);
    }

    if (imagePaths.isEmpty) {
      _showError('No images available');
      return;
    }

    var initialIndex = imagePaths.indexOf(filePath);
    if (initialIndex < 0) {
      imagePaths.add(filePath);
      initialIndex = imagePaths.length - 1;
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PhotoViewerPage(
          imagePaths: imagePaths,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  /// Show new channel dialog
  Future<void> _showNewChannelDialog() async {
    final result = await showDialog<ChatChannel>(
      context: context,
      builder: (context) => NewChannelDialog(
        existingChannelIds: _channels.map((ch) => ch.id).toList(),
        knownCallsigns: _chatService.participants.keys.toList(),
      ),
    );

    if (result != null) {
      try {
        _setStateIfMounted(() {
          _isLoading = true;
        });

        // Create channel
        final channel = await _chatService.createChannel(result);

        if (channel.isGroup &&
            !channel.isMain &&
            _groupsCollectionPath != null &&
            _localChatCollectionPath != null) {
          await GroupSyncService().syncGroupsCollection(
            groupsCollectionPath: _groupsCollectionPath!,
            chatCollectionPath: _localChatCollectionPath!,
          );
        }

        // Refresh channels
        await _chatService.refreshChannels();

        _setStateIfMounted(() {
          _channels = _chatService.channels;
        });

        // Select the new channel
        final updatedChannel = _chatService.getChannel(channel.id) ?? channel;
        await _selectChannel(updatedChannel);

        _showSuccess('Channel created successfully');
      } catch (e) {
        _showError('Failed to create channel: $e');
      } finally {
        _setStateIfMounted(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Open settings page
  void _openSettings() {
    // Not available for remote devices
    if (widget.isRemoteDevice || widget.collection == null) {
      return;
    }

    final storagePath = widget.collection!.storagePath;
    if (storagePath == null) {
      _showError('Collection storage path is null');
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatSettingsPage(
          collectionPath: storagePath,
          channelId: _selectedChannel?.id,
        ),
      ),
    ).then((_) {
      // Reload security settings when returning
      _chatService.refreshChannels();
      // Re-fetch the selected channel to get updated config (e.g., visibility change)
      if (_selectedChannel != null) {
        _selectedChannel = _chatService.getChannel(_selectedChannel!.id);
      }
      _setStateIfMounted(() {});
    });
  }

  /// Open room management page for member and role management
  void _openRoomManagement() {
    // Not available for remote devices or DMs
    if (widget.isRemoteDevice || _selectedChannel == null) {
      return;
    }

    // Only for group channels
    if (!_selectedChannel!.isGroup) {
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RoomManagementPage(
          channel: _selectedChannel!,
        ),
      ),
    ).then((_) {
      // Reload channel data when returning
      _chatService.refreshChannels();
      _setStateIfMounted(() {
        _channels = _chatService.channels;
        // Update selected channel with refreshed data
        final updated = _chatService.channels.firstWhere(
          (c) => c.id == _selectedChannel!.id,
          orElse: () => _selectedChannel!,
        );
        _selectedChannel = updated;
      });
    });
  }

  /// Show error message
  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  /// Show success message
  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  /// Handle system back button - return to channel list if viewing a channel in portrait mode
  void _handleBackButton() {
    if (_selectedChannel != null || _selectedStationRoom != null) {
      setState(() {
        _selectedChannel = null;
        _selectedStationRoom = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final screenWidth = MediaQuery.of(context).size.width;
    final isWideScreen = screenWidth >= 600;

    // In portrait mode, intercept back button when viewing a channel
    final shouldInterceptBack = !isWideScreen && (_selectedChannel != null || _selectedStationRoom != null);

    return PopScope(
      canPop: !shouldInterceptBack,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && shouldInterceptBack) {
          _handleBackButton();
        }
      },
      child: Scaffold(
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: !isWideScreen && (_selectedChannel != null || _selectedStationRoom != null)
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  setState(() {
                    _selectedChannel = null;
                    _selectedStationRoom = null;
                  });
                },
              )
            : null,
        title: LayoutBuilder(
          builder: (context, constraints) {
            // Get the title based on context (remote device or local collection)
            final baseTitle = widget.isRemoteDevice
                ? (widget.remoteDeviceName ?? widget.remoteDeviceCallsign ?? _i18n.t('chat'))
                : widget.collection?.title ?? _i18n.t('chat');

            // In narrow screen, show collection title when on channel list
            if (!isWideScreen && _selectedChannel == null && _selectedStationRoom == null) {
              return Text(baseTitle);
            }

            // Show station room name if selected
            if (_selectedStationRoom != null) {
              return Text(_selectedStationRoom!.name);
            }

            return Text(
              _selectedChannel?.name ?? baseTitle,
            );
          },
        ),
        actions: [
          // Show room info/management for group channels
          if (!widget.isRemoteDevice &&
              _selectedChannel != null &&
              _selectedChannel!.isGroup &&
              _selectedChannel!.config != null)
            IconButton(
              icon: const Icon(Icons.group),
              onPressed: _openRoomManagement,
              tooltip: _i18n.t('room_management'),
            ),
          // Add channel button: always in landscape, only on channel list in portrait
          if (!widget.isRemoteDevice && (isWideScreen || _selectedChannel == null))
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: _showNewChannelDialog,
              tooltip: _i18n.t('new_channel'),
            ),
          // Only show settings for local chat (not remote devices)
          if (!widget.isRemoteDevice)
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _openSettings,
              tooltip: _i18n.t('settings'),
            ),
        ],
      ),
      body: _buildBody(theme),
      ),
    );
  }

  /// Build main body
  Widget _buildBody(ThemeData theme) {
    if (!_isInitialized && _isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return Center(
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
              _error!,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _initializeChat,
              child: Text(_i18n.t('retry')),
            ),
          ],
        ),
      );
    }

    if (_channels.isEmpty && _stationRooms.isEmpty && _cachedDeviceSources.isEmpty) {
      return _buildEmptyState(theme);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Use two-panel layout for wide screens, single panel for narrow
        final isWideScreen = constraints.maxWidth >= 600;

        if (isWideScreen) {
          // Desktop/landscape: Two-panel layout
          return Row(
            children: [
              // Left sidebar - Channel list with station rooms
              _buildChannelSidebar(theme),
              // Right panel - Messages and input
              Expanded(
                child: _selectedChannel == null && _selectedStationRoom == null
                    ? _buildNoChannelSelected(theme)
                    : _selectedStationRoom != null
                        ? _buildRelayRoomChat(theme)
                        : Column(
                            children: [
                              // Message list
                              Expanded(
                                child: MessageListWidget(
                                  messages: _messages,
                                  isGroupChat: _selectedChannel!.isGroup,
                                  isLoading: _isLoading,
                                  onLoadMore: _loadMoreLocalMessages,
                                  onFileOpen: _openAttachedFile,
                                  onMessageDelete: _deleteMessage,
                                  canDeleteMessage: _canDeleteMessage,
                                  onMessageQuote: _setQuotedMessage,
                                  onMessageHide: _hideMessage,
                                  isMessageHidden: _isMessageHidden,
                                  onMessageUnhide: _unhideMessage,
                                  getAttachmentPath: _resolveAttachedFilePath,
                                  onImageOpen: _openAttachedImage,
                                  onMessageReact: _toggleLocalReaction,
                                ),
                              ),
                              // Message input
                              MessageInputWidget(
                                onSend: _sendMessage,
                                maxLength: _selectedChannel!.config?.maxSizeText ?? 500,
                                allowFiles:
                                    _selectedChannel!.config?.fileUpload ?? true,
                                quotedMessage: _quotedMessage,
                                onClearQuote: _clearQuotedMessage,
                              ),
                            ],
                          ),
              ),
            ],
          );
        } else {
          // Mobile/portrait: Single panel
          if (_selectedChannel == null && _selectedStationRoom == null) {
            // Show full-width channel list
            return _buildFullWidthChannelList(theme);
          } else if (_selectedStationRoom != null) {
            // Show station room messages
            return _buildRelayRoomChat(theme);
          } else {
            // Show chat messages (no duplicate header, using AppBar)
            return Column(
              children: [
                // Message list
                Expanded(
                  child: MessageListWidget(
                    messages: _messages,
                    isGroupChat: _selectedChannel!.isGroup,
                    isLoading: _isLoading,
                    onLoadMore: _loadMoreLocalMessages,
                    onFileOpen: _openAttachedFile,
                    onMessageDelete: _deleteMessage,
                    canDeleteMessage: _canDeleteMessage,
                    onMessageQuote: _setQuotedMessage,
                    onMessageHide: _hideMessage,
                    isMessageHidden: _isMessageHidden,
                    onMessageUnhide: _unhideMessage,
                    getAttachmentPath: _resolveAttachedFilePath,
                    onImageOpen: _openAttachedImage,
                    onMessageReact: _toggleLocalReaction,
                  ),
                ),
                // Message input
                MessageInputWidget(
                  onSend: _sendMessage,
                  maxLength: _selectedChannel!.config?.maxSizeText ?? 500,
                  allowFiles: _selectedChannel!.config?.fileUpload ?? true,
                  quotedMessage: _quotedMessage,
                  onClearQuote: _clearQuotedMessage,
                ),
              ],
            );
          }
        }
      },
    );
  }

  /// Build channel sidebar with local channels and station rooms
  Widget _buildChannelSidebar(ThemeData theme) {
    // Build remote device sources from station rooms
    final remoteSources = <DeviceSourceWithRooms>[];
    final addedCallsigns = <String>{}; // Track added devices to avoid duplicates

    // Add the primary/connected station first (if online or has rooms)
    if (_stationRooms.isNotEmpty) {
      // For remote device mode, use the remote device info
      // For local mode, use the connected station info
      String deviceName;
      String? deviceCallsign;

      if (widget.isRemoteDevice) {
        deviceName = widget.remoteDeviceName ?? widget.remoteDeviceCallsign ?? 'Remote Device';
        deviceCallsign = widget.remoteDeviceCallsign;
      } else {
        final stationName = _stationRooms.first.stationName;
        final connectedStation = _stationService.getConnectedRelay();
        deviceName = stationName.isNotEmpty ? stationName : (connectedStation?.name ?? 'Station');
        deviceCallsign = connectedStation?.callsign;
      }

      remoteSources.add(DeviceSourceWithRooms(
        device: DeviceSource.station(
          id: 'station_${_lastStationUrl ?? 'default'}',
          name: deviceName,
          callsign: deviceCallsign,
          url: _lastStationUrl ?? '',
          isOnline: _stationReachable,
          latency: null,
        ),
        rooms: _stationRooms,
        isLoading: _loadingRelayRooms,
      ));

      // Mark this device as added
      if (deviceCallsign != null) {
        addedCallsigns.add(deviceCallsign.toUpperCase());
      }
      if (_lastRelayCacheKey != null) {
        addedCallsigns.add(_lastRelayCacheKey!.toUpperCase());
      }
    }

    // Add cached offline devices (that aren't already shown as online)
    for (final cachedDevice in _cachedDeviceSources) {
      // Skip if already added (e.g., the primary station is also in cache)
      if (addedCallsigns.contains(cachedDevice.callsign.toUpperCase())) {
        continue;
      }

      remoteSources.add(DeviceSourceWithRooms(
        device: DeviceSource.station(
          id: 'cached_${cachedDevice.callsign}',
          name: cachedDevice.name ?? cachedDevice.callsign,
          callsign: cachedDevice.callsign,
          url: cachedDevice.url ?? '',
          isOnline: false, // Cached devices are offline
          latency: null,
        ),
        rooms: cachedDevice.rooms,
        isLoading: false,
      ));
      addedCallsigns.add(cachedDevice.callsign.toUpperCase());
    }

    // Get current profile callsign
    final currentProfile = _profileService.getProfile();

    // For remote device mode, don't show local channels
    final localChannels = widget.isRemoteDevice ? <ChatChannel>[] : _channels;

    return DeviceChatSidebar(
      localChannels: localChannels,
      remoteSources: remoteSources,
      selectedLocalChannelId: _selectedChannel?.id,
      selectedRemoteRoom: _selectedStationRoom != null
          ? SelectedRemoteRoom(
              deviceId: 'station_${_lastStationUrl ?? 'default'}',
              roomId: _selectedStationRoom!.id,
            )
          : null,
      onLocalChannelSelect: _selectChannel,
      onRemoteRoomSelect: (device, room) => _selectRelayRoomFromDevice(device, room),
      onNewLocalChannel: widget.isRemoteDevice ? null : _showNewChannelDialog,
      onRefreshDevice: (device) => _loadRelayRooms(),
      localCallsign: currentProfile.callsign,
      unreadCounts: _unreadCounts,
    );
  }

  /// Build station room chat widget
  Widget _buildRelayRoomChat(ThemeData theme) {
    return Column(
      children: [
        // Message list using converted messages - same as other chat UIs
        Expanded(
          child: MessageListWidget(
            messages: _convertStationMessages(_stationMessages),
            isGroupChat: true,
            isLoading: _isLoading,
            onLoadMore: _loadMoreStationMessages,
            onMessageDelete: _deleteStationMessage,
            canDeleteMessage: _canDeleteStationMessage,
            onMessageQuote: _setQuotedMessage,
            onMessageReact: _toggleStationReaction,
            getAttachmentPath: _getStationAttachmentPath,
            getVoiceFilePath: _getStationVoiceFilePath,
            onImageOpen: _openStationImage,
          ),
        ),
        // Message input with voice recording and file attachments - same as other chat UIs
        if (!_stationReachable)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.signal_cellular_off,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  _i18n.t('read_only_station_offline'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          )
        else if (_isStationSending)
          Container(
            padding: const EdgeInsets.all(16),
            child: const Center(child: CircularProgressIndicator()),
          )
        else if (_isStationRecording)
          Padding(
            padding: const EdgeInsets.all(8),
            child: VoiceRecorderWidget(
              onSend: _sendStationVoiceMessage,
              onCancel: _cancelStationRecording,
            ),
          )
        else
          MessageInputWidget(
            onSend: _sendMessage,
            maxLength: 1000,
            allowFiles: true,
            onMicPressed: isVoiceSupported ? _startStationRecording : null,
            quotedMessage: _quotedMessage,
            onClearQuote: _clearQuotedMessage,
          ),
      ],
    );
  }

  /// Build full-width channel list for mobile view
  Widget _buildFullWidthChannelList(ThemeData theme) {
    // For remote device mode, only show station rooms
    if (widget.isRemoteDevice) {
      return _buildRemoteDeviceRoomList(theme);
    }

    // Sort channels: favorites first, then by last message time
    final sortedChannels = List<ChatChannel>.from(_channels);
    sortedChannels.sort((a, b) {
      // Favorites first
      if (a.isFavorite && !b.isFavorite) return -1;
      if (!a.isFavorite && b.isFavorite) return 1;

      // Main channel always at top (after favorites)
      if (a.isMain && !b.isMain) return -1;
      if (!a.isMain && b.isMain) return 1;

      // Then by last message time (newest first)
      if (a.lastMessageTime == null && b.lastMessageTime == null) return 0;
      if (a.lastMessageTime == null) return 1;
      if (b.lastMessageTime == null) return -1;
      return b.lastMessageTime!.compareTo(a.lastMessageTime!);
    });

    // Check if any external device is reachable
    final anyDeviceOnline = _stationReachable || _cachedDeviceSources.any((d) => d.isOnline);

    // Build section widgets
    final stationSection = _buildStationSection(theme);
    final cachedDevicesSection = _buildCachedDevicesSection(theme);
    final localChannelsSection = _buildLocalChannelsSection(theme, sortedChannels);

    return Container(
      color: theme.colorScheme.surface,
      child: ListView(
        children: [
          // If no device is online, show local channels first
          if (!anyDeviceOnline && sortedChannels.isNotEmpty) ...localChannelsSection,
          // Then external devices
          ...stationSection,
          if (_loadingRelayRooms)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(
                child: SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ...cachedDevicesSection,
          // If devices are online, show local channels last
          if (anyDeviceOnline && sortedChannels.isNotEmpty) ...localChannelsSection,
        ],
      ),
    );
  }

  /// Build station rooms section widgets
  List<Widget> _buildStationSection(ThemeData theme) {
    if (_stationRooms.isEmpty) return [];

    return [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceVariant,
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outlineVariant,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  // Status indicator dot
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _stationReachable ? Colors.green : Colors.red.shade400,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.cell_tower, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _stationRooms.first.stationName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _stationReachable ? _i18n.t('online') : _i18n.t('offline_cached'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _stationReachable
                                ? Colors.green.shade700
                                : theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            ..._stationRooms.map((room) {
              final unreadCount = _unreadCounts[room.id] ?? 0;
              return ListTile(
                leading: Badge(
                  isLabelVisible: unreadCount > 0,
                  label: Text('$unreadCount'),
                  child: CircleAvatar(
                    backgroundColor: theme.colorScheme.tertiaryContainer,
                    child: Icon(
                      Icons.forum,
                      color: theme.colorScheme.onTertiaryContainer,
                      size: 20,
                    ),
                  ),
                ),
                title: Text(room.name),
                subtitle: room.description.isNotEmpty
                    ? Text(
                        room.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : Text('${room.messageCount} messages'),
                onTap: () {
                  _forcedOfflineMode = false; // Main station is online
                  _selectRelayRoom(room);
                },
              );
            }),
    ];
  }

  /// Build cached devices section widgets
  List<Widget> _buildCachedDevicesSection(ThemeData theme) {
    // Filter out the device already shown in station section (by callsign, not index)
    final devicesToShow = _cachedDeviceSources
        .where((d) => _lastRelayCacheKey == null || d.callsign != _lastRelayCacheKey)
        .toList();
    if (devicesToShow.isEmpty) return [];

    final List<Widget> widgets = [];
    for (final cachedDevice in devicesToShow) {
      widgets.add(
        Container(
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 1,
              ),
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cachedDevice.isOnline ? Colors.green : Colors.grey,
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.cell_tower, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cachedDevice.name ?? cachedDevice.callsign,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      cachedDevice.isOnline ? _i18n.t('online') : _i18n.t('offline_cached'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cachedDevice.isOnline
                            ? Colors.green.shade700
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

      for (final room in cachedDevice.rooms) {
        final unreadCount = _unreadCounts[room.id] ?? 0;
        widgets.add(
          ListTile(
            leading: Badge(
              isLabelVisible: unreadCount > 0,
              label: Text('$unreadCount'),
              child: CircleAvatar(
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.forum,
                  color: theme.colorScheme.onSurfaceVariant,
                  size: 20,
                ),
              ),
            ),
            title: Text(room.name),
            subtitle: room.description.isNotEmpty
                ? Text(
                    room.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : Text('${room.messageCount} messages'),
            onTap: () {
              _lastRelayCacheKey = cachedDevice.callsign;
              _lastStationUrl = cachedDevice.url;
              _stationReachable = cachedDevice.isOnline;
              _forcedOfflineMode = !cachedDevice.isOnline;
              _selectRelayRoom(room);
            },
          ),
        );
      }
    }
    return widgets;
  }

  /// Build local channels section widgets
  List<Widget> _buildLocalChannelsSection(ThemeData theme, List<ChatChannel> sortedChannels) {
    if (sortedChannels.isEmpty) return [];

    return [
      Container(
        padding: const EdgeInsets.all(16),
        margin: EdgeInsets.only(top: _stationRooms.isNotEmpty || _cachedDeviceSources.isNotEmpty ? 8 : 0),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceVariant,
          border: Border(
            top: (_stationRooms.isNotEmpty || _cachedDeviceSources.isNotEmpty) ? BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 1,
            ) : BorderSide.none,
            bottom: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 1,
            ),
          ),
        ),
        child: Row(
          children: [
            // Status indicator - always green for local device
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.green,
              ),
            ),
            const SizedBox(width: 10),
            Icon(Icons.smartphone, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _i18n.t('this_device'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    _i18n.t('online'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.green.shade700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ...sortedChannels.map((channel) => ListTile(
        leading: CircleAvatar(
          backgroundColor: channel.isGroup
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.secondaryContainer,
          child: Icon(
            channel.isGroup ? Icons.group : Icons.person,
            color: channel.isGroup
                ? theme.colorScheme.onPrimaryContainer
                : theme.colorScheme.onSecondaryContainer,
            size: 20,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                channel.name,
                style: TextStyle(
                  fontWeight: channel.isFavorite
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
            if (channel.isFavorite)
              Icon(
                Icons.star,
                size: 16,
                color: theme.colorScheme.primary,
              ),
          ],
        ),
        subtitle: channel.description != null && channel.description!.isNotEmpty
            ? Text(
                channel.description!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : (channel.isGroup
                ? Text(_i18n.t('group_chat'))
                : null),
        onTap: () => _selectChannelMobile(channel),
      )),
    ];
  }

  /// Build room list for remote device mode (only shows station rooms)
  Widget _buildRemoteDeviceRoomList(ThemeData theme) {
    final deviceName = widget.remoteDeviceName ?? widget.remoteDeviceCallsign ?? 'Remote Device';

    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Device header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant,
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                // Status indicator dot
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _stationReachable ? Colors.green : Colors.red.shade400,
                  ),
                ),
                const SizedBox(width: 10),
                Icon(Icons.devices, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        deviceName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (widget.remoteDeviceCallsign != null)
                        Text(
                          widget.remoteDeviceCallsign!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                // Status badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _stationReachable
                        ? Colors.green.withOpacity(0.1)
                        : Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _stationReachable ? _i18n.t('online') : _i18n.t('offline_cached'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _stationReachable ? Colors.green.shade700 : Colors.red.shade700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
          // Room list
          Expanded(
            child: _loadingRelayRooms
                ? const Center(child: CircularProgressIndicator())
                : _stationRooms.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.forum_outlined,
                              size: 64,
                              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _i18n.t('no_rooms_found'),
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: _stationRooms.length,
                        itemBuilder: (context, index) {
                          final room = _stationRooms[index];
                          final unreadCount = _unreadCounts[room.id] ?? 0;
                          return ListTile(
                            leading: Badge(
                              isLabelVisible: unreadCount > 0,
                              label: Text('$unreadCount'),
                              child: CircleAvatar(
                                backgroundColor: theme.colorScheme.primaryContainer,
                                child: Icon(
                                  Icons.forum,
                                  color: theme.colorScheme.onPrimaryContainer,
                                  size: 20,
                                ),
                              ),
                            ),
                            title: Text(room.name),
                            subtitle: room.description.isNotEmpty
                                ? Text(
                                    room.description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : Text('${room.messageCount} ${_i18n.t("messages")}'),
                            onTap: () => _selectRelayRoom(room),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  /// Build empty state
  Widget _buildEmptyState(ThemeData theme) {
    // For remote device mode, show different empty state
    if (widget.isRemoteDevice) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 80,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 24),
            Text(
              _i18n.t('no_rooms_found'),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              _stationReachable
                  ? _i18n.t('device_has_no_chat_rooms')
                  : _i18n.t('device_offline_no_cache'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _loadRelayRooms,
              child: Text(_i18n.t('refresh')),
            ),
          ],
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 80,
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
          ),
          const SizedBox(height: 24),
          Text(
            _i18n.t('no_channels_found'),
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            _i18n.t('create_channel_to_start'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _showNewChannelDialog,
            icon: const Icon(Icons.add),
            label: Text(_i18n.t('create_channel')),
          ),
        ],
      ),
    );
  }

  /// Build no channel selected state
  Widget _buildNoChannelSelected(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            _i18n.t('select_channel_to_chat'),
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Show channel information dialog
  void _showChannelInfo() {
    if (_selectedChannel == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_selectedChannel!.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildInfoRow(_i18n.t('type'), _selectedChannel!.type.name),
              _buildInfoRow('ID', _selectedChannel!.id),
              if (_selectedChannel!.description != null)
                _buildInfoRow(_i18n.t('description'), _selectedChannel!.description!),
              _buildInfoRow(_i18n.t('participants'),
                  _selectedChannel!.participants.join(', ')),
              _buildInfoRow(_i18n.t('created'),
                  _selectedChannel!.created.toString().substring(0, 16)),
            ],
          ),
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

  /// Build info row
  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: const TextStyle(fontSize: 12),
          ),
          const Divider(),
        ],
      ),
    );
  }
}

/// Holds cached device information with its chat rooms
class CachedDeviceRooms {
  final String callsign;
  final String? name;
  final String? url;
  final List<StationChatRoom> rooms;
  final bool isOnline;
  final DateTime? lastActivity; // Last cache update time for sorting

  CachedDeviceRooms({
    required this.callsign,
    this.name,
    this.url,
    required this.rooms,
    this.isOnline = false,
    this.lastActivity,
  });
}
