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
import '../models/relay_chat_room.dart';
import '../models/update_notification.dart';
import '../services/chat_service.dart';
import '../services/profile_service.dart';
import '../services/relay_service.dart';
import '../services/relay_cache_service.dart';
import '../services/chat_notification_service.dart';
import '../services/log_service.dart';
import '../services/i18n_service.dart';
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
  final RelayService _relayService = RelayService();
  final RelayCacheService _cacheService = RelayCacheService();
  final ChatNotificationService _chatNotificationService = ChatNotificationService();
  final I18nService _i18n = I18nService();

  List<ChatChannel> _channels = [];
  ChatChannel? _selectedChannel;
  List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;

  // Relay chat rooms
  List<RelayChatRoom> _relayRooms = [];
  RelayChatRoom? _selectedRelayRoom;
  List<RelayChatMessage> _relayMessages = [];
  bool _loadingRelayRooms = false;
  bool _relayReachable = true; // Track if relay is currently reachable

  // Remember last relay info for cache loading when disconnected
  String? _lastRelayUrl;
  String? _lastRelayCacheKey;

  // Update notification subscription
  StreamSubscription<UpdateNotification>? _updateSubscription;

  // Unread counts subscription
  StreamSubscription<Map<String, int>>? _unreadSubscription;
  Map<String, int> _unreadCounts = {};

  // Relay status check timer
  Timer? _relayStatusTimer;

  @override
  void initState() {
    super.initState();
    _initializeChat();
    _setupUpdateListener();
    _subscribeToUnreadCounts();
    _startRelayStatusChecker();
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
    _relayStatusTimer?.cancel();
    super.dispose();
  }

  /// Set up listener for real-time update notifications
  void _setupUpdateListener() {
    // Don't set up if already subscribed
    if (_updateSubscription != null) return;

    final updates = _relayService.updates;
    if (updates != null) {
      LogService().log('Setting up real-time update listener');
      _updateSubscription = updates.listen(_handleUpdateNotification);
    }
  }

  /// Handle incoming update notification
  void _handleUpdateNotification(UpdateNotification update) {
    // Only refresh if we're viewing the room that got updated
    if (update.collectionType == 'chat') {
      if (_selectedRelayRoom != null && _selectedRelayRoom!.id == update.path) {
        print('→ Refreshing messages for room: ${update.path}');
        // Fetch latest messages for the room
        _refreshRelayMessages();
      } else {
        print('→ Update for different room (${update.path}), currently viewing: ${_selectedRelayRoom?.id ?? "none"}');
      }
    }
  }

  /// Refresh relay messages without showing loading indicator
  Future<void> _refreshRelayMessages() async {
    if (_selectedRelayRoom == null) return;

    try {
      final messages = await _relayService.fetchRoomMessages(
        _selectedRelayRoom!.relayUrl,
        _selectedRelayRoom!.id,
        limit: 100,
      );

      if (mounted) {
        // Show new messages in console
        if (messages.isNotEmpty) {
          final latestMsg = messages.last;
          print('');
          print('╔══════════════════════════════════════════════════════════════╗');
          print('║  NEW MESSAGE RECEIVED                                        ║');
          print('╠══════════════════════════════════════════════════════════════╣');
          print('║  Room: ${_selectedRelayRoom!.id}');
          print('║  From: ${latestMsg.callsign}');
          print('║  Content: ${latestMsg.content}');
          print('║  Time: ${latestMsg.timestamp}');
          print('╚══════════════════════════════════════════════════════════════╝');
          print('');
        }

        setState(() {
          _relayMessages = messages;
        });

        // Cache messages
        if (_selectedRelayRoom!.relayName.isNotEmpty) {
          await _cacheService.saveMessages(
            _selectedRelayRoom!.relayName,
            _selectedRelayRoom!.id,
            messages,
          );
        }
      }
    } catch (e) {
      // Silently fail - user is already viewing messages
    }
  }

  /// Start periodic relay status checker
  void _startRelayStatusChecker() {
    // Check every 10 seconds
    _relayStatusTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkRelayStatus(),
    );
  }

  /// Check if relay is reachable and update UI if status changed
  Future<void> _checkRelayStatus() async {
    if (_lastRelayUrl == null || _lastRelayUrl!.isEmpty) return;

    // Try to set up update listener if not already done (WebSocket might be ready now)
    _setupUpdateListener();

    final wasReachable = _relayReachable;

    try {
      // Try to fetch rooms - if it succeeds, relay is reachable
      final rooms = await _relayService.fetchChatRooms(_lastRelayUrl!);

      if (!mounted) return;

      // Relay is now reachable
      if (!wasReachable) {
        LogService().log('Relay status changed: offline -> online');
        setState(() {
          _relayReachable = true;
          _relayRooms = rooms;
        });
      }

      // Poll for new messages if viewing a room (fallback when WebSocket not connected)
      if (_selectedRelayRoom != null && _updateSubscription == null) {
        // WebSocket not connected - poll for updates
        _refreshRelayMessages();
      }
    } catch (e) {
      // Relay is not reachable
      if (mounted && wasReachable) {
        LogService().log('Relay status changed: online -> offline');
        setState(() {
          _relayReachable = false;
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
        // Load relay chat rooms from the remote device
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

      // Select main channel by default only in wide screen mode
      if (_channels.isNotEmpty && mounted) {
        final screenWidth = MediaQuery.of(context).size.width;
        final isWideScreen = screenWidth >= 600;

        if (isWideScreen) {
          await _selectChannel(_channels.first);
        }
      }

      setState(() {
        _isInitialized = true;
      });

      // Load relay chat rooms - MUST await to ensure rooms are loaded before UI renders
      await _loadRelayRooms();
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

  /// Load relay chat rooms from preferred relay (uses HTTP API, doesn't require WebSocket)
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
      try {
        // Remember relay info for cache loading when disconnected
        _lastRelayUrl = widget.remoteDeviceUrl;
        _lastRelayCacheKey = widget.remoteDeviceCallsign ?? widget.remoteDeviceName;

        // Fetch rooms from remote device
        final rooms = await _relayService.fetchChatRooms(widget.remoteDeviceUrl!);

        if (rooms.isNotEmpty) {
          // Cache the rooms using the device's callsign
          final deviceCallsign = rooms.first.relayName.isNotEmpty
              ? rooms.first.relayName
              : (widget.remoteDeviceCallsign ?? widget.remoteDeviceName ?? 'remote');
          if (deviceCallsign.isNotEmpty) {
            _lastRelayCacheKey = deviceCallsign;
            await _cacheService.saveChatRooms(deviceCallsign, rooms);
          }
        }

        setState(() {
          _relayRooms = rooms;
          _relayReachable = true; // Successfully fetched - device is reachable
          _loadingRelayRooms = false;
        });
        return;
      } catch (e) {
        LogService().log('DEBUG _loadRelayRooms: Remote device fetch failed: $e');
        setState(() {
          _relayReachable = false;
        });
        // Try loading from cache for remote device
        if (_lastRelayCacheKey != null && _lastRelayCacheKey!.isNotEmpty) {
          final cachedRooms = await _cacheService.loadChatRooms(
            _lastRelayCacheKey!,
            _lastRelayUrl ?? '',
          );
          if (cachedRooms.isNotEmpty) {
            setState(() {
              _relayRooms = cachedRooms;
              _loadingRelayRooms = false;
            });
            return;
          }
        }
        setState(() {
          _loadingRelayRooms = false;
        });
        return;
      }
    }

    // Use preferred relay for HTTP API calls - doesn't require WebSocket connection
    final relay = _relayService.getPreferredRelay();
    LogService().log('DEBUG _loadRelayRooms: relay=${relay?.name}, url=${relay?.url}');

    // If relay has a valid URL, try to fetch from it via HTTP API
    if (relay != null && relay.url.isNotEmpty) {
      try {
        // Remember relay info for cache loading when disconnected
        _lastRelayUrl = relay.url;
        _lastRelayCacheKey = relay.callsign ?? relay.name;

        // Fetch rooms from relay
        final rooms = await _relayService.fetchChatRooms(relay.url);

        if (rooms.isNotEmpty) {
          // Cache the rooms using the relay's callsign (from API response)
          final relayCallsign = rooms.first.relayName;
          if (relayCallsign.isNotEmpty) {
            _lastRelayCacheKey = relayCallsign;
            await _cacheService.saveChatRooms(relayCallsign, rooms);
          }
        }

        setState(() {
          _relayRooms = rooms;
          _relayReachable = true; // Successfully fetched - relay is reachable
          _loadingRelayRooms = false;
        });
        return;
      } catch (e) {
        // Fetch failed - will try cache below
        LogService().log('DEBUG _loadRelayRooms: fetch failed with error: $e');
      }
    }

    // Relay is not connected or fetch failed - try loading from cache
    LogService().log('DEBUG _loadRelayRooms: falling through to cache loading');
    setState(() {
      _relayReachable = false;
    });

    // Try to load from cache using remembered relay info
    LogService().log('DEBUG _loadRelayRooms: trying cache for _lastRelayCacheKey=$_lastRelayCacheKey');
    if (_lastRelayCacheKey != null && _lastRelayCacheKey!.isNotEmpty) {
      final cachedRooms = await _cacheService.loadChatRooms(
        _lastRelayCacheKey!,
        _lastRelayUrl ?? '',
      );
      LogService().log('DEBUG _loadRelayRooms: loaded ${cachedRooms.length} rooms from cache');
      if (cachedRooms.isNotEmpty) {
        // Set relay URL from cached room for status checking
        if (_lastRelayUrl == null || _lastRelayUrl!.isEmpty) {
          _lastRelayUrl = cachedRooms.first.relayUrl;
        }
        setState(() {
          _relayRooms = cachedRooms;
          _loadingRelayRooms = false;
        });
        LogService().log('DEBUG _loadRelayRooms: SUCCESS - set ${cachedRooms.length} rooms from cache, relayUrl=$_lastRelayUrl');
        return;
      }
    }

    // No remembered relay - try loading from any cached device
    final cachedDevices = await _cacheService.getCachedDevices();
    LogService().log('DEBUG _loadRelayRooms: cachedDevices=$cachedDevices');
    for (final deviceCallsign in cachedDevices) {
      final cachedRooms = await _cacheService.loadChatRooms(deviceCallsign, '');
      LogService().log('DEBUG _loadRelayRooms: device=$deviceCallsign, rooms=${cachedRooms.length}');
      if (cachedRooms.isNotEmpty) {
        _lastRelayCacheKey = deviceCallsign;
        // Set relay URL from cached room for status checking
        if (_lastRelayUrl == null || _lastRelayUrl!.isEmpty) {
          _lastRelayUrl = cachedRooms.first.relayUrl;
        }
        setState(() {
          _relayRooms = cachedRooms;
        });
        LogService().log('DEBUG _loadRelayRooms: set _relayRooms to ${cachedRooms.length} rooms, relayUrl=$_lastRelayUrl');
        break;
      }
    }

    LogService().log('DEBUG _loadRelayRooms: final _relayRooms.length=${_relayRooms.length}');
    setState(() {
      _loadingRelayRooms = false;
    });
  }

  /// Select a channel and load its messages
  Future<void> _selectChannel(ChatChannel channel) async {
    setState(() {
      _selectedChannel = channel;
      _selectedRelayRoom = null; // Deselect relay room
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

  /// Select a relay room and load its messages
  Future<void> _selectRelayRoom(RelayChatRoom room) async {
    // Mark this room as current (clears unread count)
    _chatNotificationService.setCurrentRoom(room.id);

    setState(() {
      _selectedRelayRoom = room;
      _selectedChannel = null; // Deselect local channel
      _isLoading = true;
    });

    try {
      // Fetch messages from relay
      final messages = await _relayService.fetchRoomMessages(
        room.relayUrl,
        room.id,
        limit: 100,
      );

      // Cache messages
      if (room.relayName.isNotEmpty) {
        await _cacheService.saveMessages(room.relayName, room.id, messages);
      }

      setState(() {
        _relayMessages = messages;
        _relayReachable = true; // Successfully fetched - relay is reachable
      });
    } catch (e) {
      // Relay not reachable - try loading from cache
      setState(() {
        _relayReachable = false;
      });

      if (room.relayName.isNotEmpty) {
        final cachedMessages = await _cacheService.loadMessages(
          room.relayName,
          room.id,
        );
        setState(() {
          _relayMessages = cachedMessages;
        });
      }
      _showError('Relay offline - showing cached messages');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Convert relay messages to ChatMessage format for display
  List<ChatMessage> _convertRelayMessages(List<RelayChatMessage> relayMessages) {
    return relayMessages.map((rm) {
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

    // Handle relay room message
    if (_selectedRelayRoom != null) {
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
      if (settings.signMessages &&
          currentProfile.npub.isNotEmpty &&
          currentProfile.nsec.isNotEmpty) {
        // Add npub for verification
        metadata['npub'] = currentProfile.npub;
        metadata['channel'] = _selectedChannel!.id;

        // Generate BIP-340 Schnorr signature on secp256k1 curve
        metadata['signature'] = _generateSchnorrSignature(
          content,
          metadata,
          currentProfile.nsec,
        );
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

  /// Send a message to a relay chat room as a signed NOSTR event
  Future<void> _sendRelayMessage(String content) async {
    if (_selectedRelayRoom == null) return;

    // Check if relay is reachable before trying to send
    if (!_relayReachable) {
      _showError('Cannot send message - relay is offline');
      return;
    }

    final currentProfile = _profileService.getProfile();

    try {
      // Send as a properly signed NOSTR event (kind 1 text note)
      // RelayService handles creating the event, signing with BIP-340 Schnorr,
      // and sending via WebSocket or HTTP
      final success = await _relayService.postRoomMessage(
        _selectedRelayRoom!.relayUrl,
        _selectedRelayRoom!.id,
        currentProfile.callsign,
        content,
      );

      if (success) {
        // Add optimistic update with verified status
        // Since we signed the message ourselves, it should be verified
        final now = DateTime.now();
        final timestamp = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

        final newMessage = RelayChatMessage(
          timestamp: timestamp,
          callsign: currentProfile.callsign,
          content: content,
          roomId: _selectedRelayRoom!.id,
          npub: currentProfile.npub,
          verified: true,      // We signed it, so it's verified
          hasSignature: true,  // Message was signed
        );

        setState(() {
          _relayMessages.add(newMessage);
        });
      } else {
        _showError('Failed to send message to relay');
      }
    } catch (e) {
      // Relay became unreachable - update status
      setState(() {
        _relayReachable = false;
      });
      _showError('Relay offline - message not sent');
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

  /// Generate BIP-340 Schnorr signature for a chat message
  /// Creates a NOSTR event and signs it with the user's private key
  String _generateSchnorrSignature(
    String content,
    Map<String, String> metadata,
    String nsec,
  ) {
    try {
      // Decode nsec to get private key hex
      final privateKeyHex = NostrCrypto.decodeNsec(nsec);
      final publicKeyHex = NostrCrypto.derivePublicKey(privateKeyHex);

      // Create a NOSTR event for signing
      final event = NostrEvent.textNote(
        pubkeyHex: publicKeyHex,
        content: content,
        tags: [
          ['t', 'chat'],
          ['channel', metadata['channel'] ?? 'main'],
        ],
      );

      // Calculate event ID and sign with BIP-340 Schnorr signature
      event.calculateId();
      event.sign(privateKeyHex);

      return event.sig ?? '';
    } catch (e) {
      LogService().log('Error generating Schnorr signature: $e');
      return '';
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

  /// Refresh current channel
  Future<void> _refreshChannel() async {
    if (_selectedChannel != null) {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final screenWidth = MediaQuery.of(context).size.width;
    final isWideScreen = screenWidth >= 600;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: !isWideScreen && (_selectedChannel != null || _selectedRelayRoom != null)
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  setState(() {
                    _selectedChannel = null;
                    _selectedRelayRoom = null;
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
            if (!isWideScreen && _selectedChannel == null && _selectedRelayRoom == null) {
              return Text(baseTitle);
            }

            // Show relay room name if selected
            if (_selectedRelayRoom != null) {
              return Text(_selectedRelayRoom!.name);
            }

            return Text(
              _selectedChannel?.name ?? baseTitle,
            );
          },
        ),
        actions: [
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

    if (_channels.isEmpty && _relayRooms.isEmpty) {
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
              // Left sidebar - Channel list with relay rooms
              _buildChannelSidebar(theme),
              // Right panel - Messages and input
              Expanded(
                child: _selectedChannel == null && _selectedRelayRoom == null
                    ? _buildNoChannelSelected(theme)
                    : _selectedRelayRoom != null
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
          if (_selectedChannel == null && _selectedRelayRoom == null) {
            // Show full-width channel list
            return _buildFullWidthChannelList(theme);
          } else if (_selectedRelayRoom != null) {
            // Show relay room messages
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

  /// Build channel sidebar with local channels and relay rooms
  Widget _buildChannelSidebar(ThemeData theme) {
    // Build remote device sources from relay rooms
    final remoteSources = <DeviceSourceWithRooms>[];

    if (_relayRooms.isNotEmpty) {
      // For remote device mode, use the remote device info
      // For local mode, use the connected relay info
      String deviceName;
      String? deviceCallsign;

      if (widget.isRemoteDevice) {
        deviceName = widget.remoteDeviceName ?? widget.remoteDeviceCallsign ?? 'Remote Device';
        deviceCallsign = widget.remoteDeviceCallsign;
      } else {
        final relayName = _relayRooms.first.relayName;
        final connectedRelay = _relayService.getConnectedRelay();
        deviceName = relayName.isNotEmpty ? relayName : (connectedRelay?.name ?? 'Relay');
        deviceCallsign = connectedRelay?.callsign;
      }

      remoteSources.add(DeviceSourceWithRooms(
        device: DeviceSource.relay(
          id: 'relay_${_lastRelayUrl ?? 'default'}',
          name: deviceName,
          callsign: deviceCallsign,
          url: _lastRelayUrl ?? '',
          isOnline: _relayReachable,
          latency: null,
        ),
        rooms: _relayRooms,
        isLoading: _loadingRelayRooms,
      ));
    }

    // Get current profile callsign
    final currentProfile = _profileService.getProfile();

    // For remote device mode, don't show local channels
    final localChannels = widget.isRemoteDevice ? <ChatChannel>[] : _channels;

    return DeviceChatSidebar(
      localChannels: localChannels,
      remoteSources: remoteSources,
      selectedLocalChannelId: _selectedChannel?.id,
      selectedRemoteRoom: _selectedRelayRoom != null
          ? SelectedRemoteRoom(
              deviceId: 'relay_${_lastRelayUrl ?? 'default'}',
              roomId: _selectedRelayRoom!.id,
            )
          : null,
      onLocalChannelSelect: _selectChannel,
      onRemoteRoomSelect: (device, room) => _selectRelayRoom(room),
      onNewLocalChannel: widget.isRemoteDevice ? null : _showNewChannelDialog,
      onRefreshDevice: (device) => _loadRelayRooms(),
      localCallsign: currentProfile.callsign,
      unreadCounts: _unreadCounts,
    );
  }

  /// Build relay room chat widget
  Widget _buildRelayRoomChat(ThemeData theme) {
    return Column(
      children: [
        // Message list using converted messages
        Expanded(
          child: MessageListWidget(
            messages: _convertRelayMessages(_relayMessages),
            isGroupChat: true,
            isLoading: _isLoading,
            onFileOpen: (_) {}, // Relay messages don't support file attachments
            onMessageDelete: (_) {}, // Can't delete relay messages
            canDeleteMessage: (_) => false,
          ),
        ),
        // Message input (no file upload for relay) - disabled when offline
        if (_relayReachable)
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
                  _i18n.t('read_only_relay_offline'),
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
    // For remote device mode, only show relay rooms
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

    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Header
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
                Icon(Icons.chat, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _i18n.t('channels'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _showNewChannelDialog,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(_i18n.t('new_channel')),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ],
            ),
          ),
          // Channel list
          Expanded(
            child: ListView(
              children: [
                // Local channels
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

                // Relay rooms section
                if (_relayRooms.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    margin: const EdgeInsets.only(top: 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceVariant,
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
                        // Status indicator dot
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _relayReachable ? Colors.green : Colors.red.shade400,
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
                                _relayRooms.first.relayName,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                _relayReachable ? _i18n.t('online') : _i18n.t('offline_cached'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _relayReachable
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
                  ..._relayRooms.map((room) {
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
                      onTap: () => _selectRelayRoom(room),
                    );
                  }),
                ],

                // Loading indicator for relay rooms
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build room list for remote device mode (only shows relay rooms)
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
                    color: _relayReachable ? Colors.green : Colors.red.shade400,
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
                    color: _relayReachable
                        ? Colors.green.withOpacity(0.1)
                        : Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _relayReachable ? _i18n.t('online') : _i18n.t('offline_cached'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _relayReachable ? Colors.green.shade700 : Colors.red.shade700,
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
                : _relayRooms.isEmpty
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
                        itemCount: _relayRooms.length,
                        itemBuilder: (context, index) {
                          final room = _relayRooms[index];
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
              _relayReachable
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
