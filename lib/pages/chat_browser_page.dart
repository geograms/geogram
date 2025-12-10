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
import '../services/signing_service.dart';
import '../models/device_source.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import '../widgets/device_chat_sidebar.dart';
import '../widgets/message_list_widget.dart';
import '../widgets/message_input_widget.dart';
import '../widgets/new_channel_dialog.dart';
import 'chat_settings_page.dart';

/// Page for browsing and interacting with a chat collection
class ChatBrowserPage extends StatefulWidget {
  final Collection? collection;

  /// For browsing a remote device's chat
  final String? remoteDeviceUrl;
  final String? remoteDeviceCallsign;
  final String? remoteDeviceName;

  const ChatBrowserPage({
    Key? key,
    this.collection,
    this.remoteDeviceUrl,
    this.remoteDeviceCallsign,
    this.remoteDeviceName,
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
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;

  // Station chat rooms (for the primary/connected station)
  List<StationChatRoom> _stationRooms = [];
  StationChatRoom? _selectedStationRoom;
  List<StationChatMessage> _stationMessages = [];
  bool _loadingRelayRooms = false;
  bool _stationReachable = false; // Track if station is currently reachable (default false until confirmed)
  bool _forcedOfflineMode = false; // True when viewing a device explicitly marked as offline

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

  // File change subscription for CLI/external updates
  StreamSubscription<ChatFileChange>? _fileChangeSubscription;

  @override
  void initState() {
    super.initState();
    _initializeChat();
    _setupUpdateListener();
    _subscribeToUnreadCounts();
    _subscribeToFileChanges();
    _startRelayStatusChecker();
    _startMessagePolling();
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
        limit: 100,
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
      setState(() {
        _unreadCounts = counts;
      });
    });
  }

  @override
  void dispose() {
    _updateSubscription?.cancel();
    _unreadSubscription?.cancel();
    _fileChangeSubscription?.cancel();
    _chatService.stopWatching();
    _stationStatusTimer?.cancel();
    _messagePollingTimer?.cancel();
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
        _refreshRelayMessages();
      }
    }
  }

  /// Refresh station messages without showing loading indicator
  Future<void> _refreshRelayMessages() async {
    if (_selectedStationRoom == null) return;

    try {
      // Download any new raw chat files
      final cacheKey = _lastRelayCacheKey ?? '';
      if (cacheKey.isNotEmpty) {
        await _downloadAndCacheChatFiles(
          _selectedStationRoom!.stationUrl,
          _selectedStationRoom!.id,
          cacheKey,
        );
      }

      // Load messages from cache (now contains any new files)
      final cachedMessages = await _cacheService.loadMessages(
        cacheKey,
        _selectedStationRoom!.id,
      );

      if (mounted) {
        // Check for new messages
        if (cachedMessages.length > _stationMessages.length) {
          final latestMsg = cachedMessages.last;
          print('');
          print('╔══════════════════════════════════════════════════════════════╗');
          print('║  NEW MESSAGE RECEIVED                                        ║');
          print('╠══════════════════════════════════════════════════════════════╣');
          print('║  Room: ${_selectedStationRoom!.id}');
          print('║  From: ${latestMsg.callsign}');
          print('║  Content: ${latestMsg.content}');
          print('║  Time: ${latestMsg.timestamp}');
          print('╚══════════════════════════════════════════════════════════════╝');
          print('');
        }

        setState(() {
          _stationMessages = cachedMessages;
        });
      }
    } catch (e) {
      // Silently fail - user is already viewing messages
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
      // Download any new raw chat files
      final cacheKey = _lastRelayCacheKey ?? '';
      if (cacheKey.isNotEmpty) {
        await _downloadAndCacheChatFiles(
          _selectedStationRoom!.stationUrl,
          _selectedStationRoom!.id,
          cacheKey,
        );
      }

      // Load messages from cache
      final cachedMessages = await _cacheService.loadMessages(
        cacheKey,
        _selectedStationRoom!.id,
      );

      if (!mounted) return;

      // Check if there are new messages by comparing count
      if (cachedMessages.length > _stationMessages.length) {
        setState(() {
          _stationMessages = cachedMessages;
        });
      }
    } catch (e) {
      // Silently fail - don't disrupt user experience
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
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // For remote device, skip local channel initialization
      if (widget.isRemoteDevice) {
        LogService().log('DEBUG _initializeChat: Remote device mode - loading from ${widget.remoteDeviceUrl}');
        setState(() {
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

      // Load channels
      _channels = _chatService.channels;

      // Start watching for file changes now that channels are loaded
      _chatService.startWatching();

      setState(() {
        _isInitialized = true;
      });

      // Load station chat rooms - MUST await to ensure rooms are loaded before UI renders
      await _loadRelayRooms();

      // Auto-select first station room in wide screen mode (where sidebar is visible alongside content)
      if (mounted) {
        final screenWidth = MediaQuery.of(context).size.width;
        final isWideScreen = screenWidth >= 600;

        if (isWideScreen && _stationRooms.isNotEmpty) {
          // Select first station room (station rooms are shown first in the UI)
          await _selectRelayRoom(_stationRooms.first);
        }
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to initialize chat: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Load station chat rooms from preferred station (uses HTTP API, doesn't require WebSocket)
  Future<void> _loadRelayRooms() async {
    LogService().log('DEBUG _loadRelayRooms: STARTING, isRemoteDevice=${widget.isRemoteDevice}');

    setState(() {
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

      try {
        // Fetch rooms from remote device
        final rooms = await _stationService.fetchChatRooms(widget.remoteDeviceUrl!);

        if (rooms.isNotEmpty) {
          // Always save using the consistent cache key (widget callsign)
          await _cacheService.saveChatRooms(cacheKey, rooms, stationUrl: widget.remoteDeviceUrl);
        }

        setState(() {
          _stationRooms = rooms;
          _stationReachable = true; // Successfully fetched - device is reachable
          _loadingRelayRooms = false;
        });

        // Ensure WebSocket connection for real-time updates
        await _ensureWebSocketConnection(widget.remoteDeviceUrl!);

        return;
      } catch (e) {
        LogService().log('DEBUG _loadRelayRooms: Remote device fetch failed: $e');
        setState(() {
          _stationReachable = false;
        });
        // Try loading from cache using the same consistent key
        final cachedRooms = await _cacheService.loadChatRooms(cacheKey, _lastStationUrl ?? '');
        if (cachedRooms.isNotEmpty) {
          setState(() {
            _stationRooms = cachedRooms;
            _loadingRelayRooms = false;
          });
          return;
        }
        setState(() {
          _loadingRelayRooms = false;
        });
        return;
      }
    }

    // Use preferred station for HTTP API calls - doesn't require WebSocket connection
    final station = _stationService.getPreferredStation();
    LogService().log('DEBUG _loadRelayRooms: station=${station?.name}, url=${station?.url}');

    // If station has a valid URL, try to fetch from it via HTTP API
    if (station != null && station.url.isNotEmpty) {
      // Use station's callsign as the consistent cache key
      final cacheKey = station.callsign ?? station.name;
      _lastStationUrl = station.url;
      _lastRelayCacheKey = cacheKey;

      try {
        // Fetch rooms from station
        final rooms = await _stationService.fetchChatRooms(station.url);

        if (rooms.isNotEmpty) {
          // Always save using the consistent cache key
          await _cacheService.saveChatRooms(cacheKey, rooms, stationUrl: station.url);

          setState(() {
            _stationRooms = rooms;
            _stationReachable = true; // Successfully fetched - station is reachable
            _loadingRelayRooms = false;
          });

          // Ensure WebSocket connection for real-time updates
          await _ensureWebSocketConnection(station.url);

          // Also load other cached devices to show them as offline
          await _loadAllCachedDevices();

          return;
        }
        // If rooms are empty, fall through to cache loading
        LogService().log('DEBUG _loadRelayRooms: station returned empty rooms, trying cache');
      } catch (e) {
        // Fetch failed - will try cache below
        LogService().log('DEBUG _loadRelayRooms: fetch failed with error: $e');
      }
    }

    // Station is not connected or fetch failed - try loading from cache
    LogService().log('DEBUG _loadRelayRooms: falling through to cache loading');
    setState(() {
      _stationReachable = false;
    });

    // Load ALL cached devices with their rooms
    await _loadAllCachedDevices();

    LogService().log('DEBUG _loadRelayRooms: final _stationRooms.length=${_stationRooms.length}, cachedDevices=${_cachedDeviceSources.length}');
    setState(() {
      _loadingRelayRooms = false;
    });
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

    setState(() {
      _cachedDeviceSources = allCachedSources;
    });
  }

  /// Select a channel and load its messages
  Future<void> _selectChannel(ChatChannel channel) async {
    setState(() {
      _selectedChannel = channel;
      _selectedStationRoom = null; // Deselect station room
      _isLoading = true;
    });

    try {
      // Load messages for selected channel
      final messages = await _chatService.loadMessages(
        channel.id,
        limit: 100,
      );

      setState(() {
        _messages = messages;
      });
    } catch (e) {
      _showError('Failed to load messages: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
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

  Future<void> _selectRelayRoom(StationChatRoom room) async {
    // Mark this room as current (clears unread count)
    _chatNotificationService.setCurrentRoom(room.id);

    setState(() {
      _selectedStationRoom = room;
      _selectedChannel = null; // Deselect local channel
      _isLoading = true;
    });

    // If we already know the device is offline, skip network request and load from cache directly
    if (!_stationReachable) {
      LogService().log('Device offline, loading from cache');
      await _loadMessagesFromCache(room.id);
      return;
    }

    // Try to fetch and cache raw chat files from station
    try {
      final cacheKey = _lastRelayCacheKey ?? '';
      if (cacheKey.isNotEmpty) {
        // Download and cache raw chat files (preserves all metadata including signatures)
        await _downloadAndCacheChatFiles(room.stationUrl, room.id, cacheKey);
      }

      // Load messages from cache (now contains the raw files)
      await _loadMessagesFromCache(room.id);

      // Also save the rooms to cache for offline room listing
      if (cacheKey.isNotEmpty && _stationRooms.isNotEmpty) {
        await _cacheService.saveChatRooms(cacheKey, _stationRooms, stationUrl: room.stationUrl);
      }

      // Only update reachability if not in forced offline mode
      if (!_forcedOfflineMode) {
        setState(() {
          _stationReachable = true; // Successfully fetched - station is reachable
        });
      }
    } catch (e) {
      // Station not reachable - try loading from cache
      LogService().log('Fetch failed ($e), loading from cache');
      if (!_forcedOfflineMode) {
        setState(() {
          _stationReachable = false;
        });
      }
      await _loadMessagesFromCache(room.id);
    }
  }

  /// Load messages from cache for a room
  Future<void> _loadMessagesFromCache(String roomId) async {
    if (_lastRelayCacheKey != null && _lastRelayCacheKey!.isNotEmpty) {
      final cachedMessages = await _cacheService.loadMessages(
        _lastRelayCacheKey!,
        roomId,
      );
      LogService().log('DEBUG _loadMessagesFromCache: Loaded ${cachedMessages.length} messages for room $roomId');
      setState(() {
        _stationMessages = cachedMessages;
        _isLoading = false;
      });
      if (cachedMessages.isEmpty) {
        _showError('No cached messages available');
      }
    } else {
      LogService().log('No cache key available');
      setState(() {
        _stationMessages = [];
        _isLoading = false;
      });
      _showError('No cached data available');
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
      await _sendRelayMessage(content);
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
      setState(() {
        _messages.add(message);
      });
    } catch (e) {
      _showError('Failed to send message: $e');
    }
  }

  /// Send a message to a station chat room as a signed NOSTR event
  Future<void> _sendRelayMessage(String content) async {
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
      final success = await _stationService.postRoomMessage(
        _selectedStationRoom!.stationUrl,
        _selectedStationRoom!.id,
        currentProfile.callsign,
        content,
      );

      if (success) {
        // Add optimistic update with verified status
        // Since we signed the message ourselves, it should be verified
        final now = DateTime.now();
        final timestamp = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

        final newMessage = StationChatMessage(
          timestamp: timestamp,
          callsign: currentProfile.callsign,
          content: content,
          roomId: _selectedStationRoom!.id,
          npub: currentProfile.npub,
          verified: true,      // We signed it, so it's verified
          hasSignature: true,  // Message was signed
        );

        setState(() {
          _stationMessages.add(newMessage);
        });

        // Cache the updated message list using the consistent cache key
        if (_lastRelayCacheKey != null && _lastRelayCacheKey!.isNotEmpty) {
          await _cacheService.saveMessages(
            _lastRelayCacheKey!,
            _selectedStationRoom!.id,
            _stationMessages,
          );
        }
      } else {
        // Send failed - station may be unreachable
        setState(() {
          _stationReachable = false;
        });
        _showError('Failed to send message - station offline');
      }
    } catch (e) {
      // Station became unreachable - update status
      setState(() {
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

    // Check if user is admin or moderator
    return _chatService.security.canModerate(userNpub, _selectedChannel!.id);
  }

  /// Delete a message
  Future<void> _deleteMessage(ChatMessage message) async {
    if (_selectedChannel == null) return;

    try {
      final currentProfile = _profileService.getProfile();
      final userNpub = currentProfile.npub;

      await _chatService.deleteMessage(
        _selectedChannel!.id,
        message,
        userNpub,
      );

      // Remove from local list
      setState(() {
        _messages.removeWhere((msg) =>
            msg.timestamp == message.timestamp && msg.author == message.author);
      });

      _showSuccess('Message deleted');
    } catch (e) {
      _showError('Failed to delete message: $e');
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
        setState(() {
          _isLoading = true;
        });

        // Create channel
        final channel = await _chatService.createChannel(result);

        // Refresh channels
        await _chatService.refreshChannels();

        setState(() {
          _channels = _chatService.channels;
        });

        // Select the new channel
        await _selectChannel(channel);

        _showSuccess('Channel created successfully');
      } catch (e) {
        _showError('Failed to create channel: $e');
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Refresh current channel or station room
  Future<void> _refreshChannel() async {
    if (_selectedStationRoom != null) {
      // Refresh station room messages
      await _refreshRelayMessages();
    } else if (_selectedChannel != null) {
      // Refresh local channel
      await _selectChannel(_selectedChannel!);
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
        ),
      ),
    ).then((_) {
      // Reload security settings when returning
      _chatService.refreshChannels();
      setState(() {});
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
          // Only show add channel for local chat (not remote devices)
          if (!widget.isRemoteDevice)
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: _showNewChannelDialog,
              tooltip: _i18n.t('new_channel'),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshChannel,
            tooltip: _i18n.t('refresh'),
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
                                  onFileOpen: _openAttachedFile,
                                  onMessageDelete: _deleteMessage,
                                  canDeleteMessage: _canDeleteMessage,
                                ),
                              ),
                              // Message input
                              MessageInputWidget(
                                onSend: _sendMessage,
                                maxLength: _selectedChannel!.config?.maxSizeText ?? 500,
                                allowFiles:
                                    _selectedChannel!.config?.fileUpload ?? true,
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
                    onFileOpen: _openAttachedFile,
                    onMessageDelete: _deleteMessage,
                    canDeleteMessage: _canDeleteMessage,
                  ),
                ),
                // Message input
                MessageInputWidget(
                  onSend: _sendMessage,
                  maxLength: _selectedChannel!.config?.maxSizeText ?? 500,
                  allowFiles: _selectedChannel!.config?.fileUpload ?? true,
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
        // Message list using converted messages
        Expanded(
          child: MessageListWidget(
            messages: _convertStationMessages(_stationMessages),
            isGroupChat: true,
            isLoading: _isLoading,
            onFileOpen: (_) {}, // Station messages don't support file attachments
            onMessageDelete: (_) {}, // Can't delete station messages
            canDeleteMessage: (_) => false,
          ),
        ),
        // Message input (no file upload for station) - disabled when offline
        if (_stationReachable)
          MessageInputWidget(
            onSend: _sendMessage,
            maxLength: 1000,
            allowFiles: false,
          )
        else
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
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _loadRelayRooms,
                    tooltip: _i18n.t('refresh_rooms'),
                  ),
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
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadRelayRooms,
                  tooltip: _i18n.t('refresh_rooms'),
                ),
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
            FilledButton.icon(
              onPressed: _loadRelayRooms,
              icon: const Icon(Icons.refresh),
              label: Text(_i18n.t('refresh')),
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
