/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/material.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/signing_service.dart';
import '../services/storage_config.dart';
import 'remote_chat_room_page.dart';

/// Page for browsing chat rooms from a remote device
class RemoteChatBrowserPage extends StatefulWidget {
  final RemoteDevice device;

  const RemoteChatBrowserPage({
    super.key,
    required this.device,
  });

  @override
  State<RemoteChatBrowserPage> createState() => _RemoteChatBrowserPageState();
}

class _RemoteChatBrowserPageState extends State<RemoteChatBrowserPage> {
  final DevicesService _devicesService = DevicesService();
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();
  final SigningService _signingService = SigningService();

  List<ChatRoom> _rooms = [];
  bool _isLoading = true;
  String? _error;
  String? _myNpub;

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    await _signingService.initialize();
    final profile = _profileService.getProfile();
    _myNpub = profile.npub.isNotEmpty ? profile.npub : null;
    _loadRooms();
  }

  Future<void> _loadRooms() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Try to load from cache first for instant response
      final cachedRooms = await _loadFromCache();
      if (cachedRooms.isNotEmpty) {
        setState(() {
          _rooms = cachedRooms;
          _isLoading = false;
        });

        // Silently refresh from API in background
        _refreshFromApi();
        return;
      }

      // No cache - fetch from API
      await _fetchFromApi();
    } catch (e) {
      LogService().log('RemoteChatBrowserPage: Error loading rooms: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Load rooms from cached data on disk
  Future<List<ChatRoom>> _loadFromCache() async {
    try {
      final dataDir = StorageConfig().baseDir;
      final chatPath = '$dataDir/devices/${widget.device.callsign}/chat';
      final chatDir = Directory(chatPath);

      if (!await chatDir.exists()) {
        return [];
      }

      final rooms = <ChatRoom>[];
      await for (final entity in chatDir.list()) {
        if (entity is Directory) {
          final roomName = entity.uri.pathSegments[entity.uri.pathSegments.length - 2];

          // Read room config if it exists
          final configFile = File('${entity.path}/config.json');
          if (await configFile.exists()) {
            try {
              final configContent = await configFile.readAsString();
              final config = json.decode(configContent) as Map<String, dynamic>;

              final visibility = config['visibility'] as String? ?? 'PUBLIC';

              // Include PUBLIC rooms always
              // Include RESTRICTED rooms only if visitor's npub is a member
              bool shouldInclude = visibility == 'PUBLIC';

              if (visibility == 'RESTRICTED' && _myNpub != null) {
                // Check if visitor is owner, admin, moderator, or member
                final owner = config['owner'] as String?;
                final members = (config['members'] as List?)?.cast<String>() ?? [];
                final admins = (config['admins'] as List?)?.cast<String>() ?? [];
                final moderators = (config['moderators'] as List?)?.cast<String>() ?? [];

                shouldInclude = owner == _myNpub ||
                    members.contains(_myNpub) ||
                    admins.contains(_myNpub) ||
                    moderators.contains(_myNpub);
              }

              if (shouldInclude) {
                rooms.add(ChatRoom(
                  id: roomName,
                  name: config['name'] as String? ?? roomName,
                  description: config['description'] as String?,
                  memberCount: (config['members'] as List?)?.length ?? 0,
                  visibility: visibility,
                ));
              }
            } catch (e) {
              LogService().log('Error reading room config for $roomName: $e');
            }
          } else {
            // No config file - treat as public room
            rooms.add(ChatRoom(
              id: roomName,
              name: roomName,
              memberCount: 0,
              visibility: 'PUBLIC',
            ));
          }
        }
      }

      LogService().log('RemoteChatBrowserPage: Loaded ${rooms.length} cached rooms (myNpub=${_myNpub != null})');
      return rooms;
    } catch (e) {
      LogService().log('RemoteChatBrowserPage: Error loading cache: $e');
      return [];
    }
  }

  /// Fetch fresh rooms from API
  Future<void> _fetchFromApi() async {
    try {
      LogService().log('RemoteChatBrowserPage: Fetching rooms from ${widget.device.callsign}');

      // Generate signed auth header for NOSTR authentication
      final profile = _profileService.getProfile();
      final authHeader = await _signingService.generateAuthHeader(
        profile,
        action: 'list-rooms',
        tags: [['resource', 'chat']],
      );

      final headers = <String, String>{};
      if (authHeader != null) {
        headers['Authorization'] = 'Nostr $authHeader';
        LogService().log('RemoteChatBrowserPage: Using signed NOSTR auth');
      }

      final response = await _devicesService.makeDeviceApiRequest(
        callsign: widget.device.callsign,
        method: 'GET',
        path: '/api/chat/rooms',
        headers: headers.isNotEmpty ? headers : null,
      );

      LogService().log('RemoteChatBrowserPage: Response status=${response?.statusCode}, body length=${response?.body.length}');

      if (response != null && response.statusCode == 200) {
        final data = json.decode(response.body);
        LogService().log('RemoteChatBrowserPage: Decoded data type=${data.runtimeType}');

        final List<dynamic> roomsData = data is Map ? (data['rooms'] ?? data) : data;
        LogService().log('RemoteChatBrowserPage: roomsData has ${roomsData.length} items');

        setState(() {
          _rooms = roomsData.map((json) => ChatRoom.fromJson(json)).toList();
          _isLoading = false;
        });
        LogService().log('RemoteChatBrowserPage: Fetched ${_rooms.length} rooms from API');
      } else {
        throw Exception('HTTP ${response?.statusCode ?? "null"}: ${response?.body ?? "no response"}');
      }
    } catch (e) {
      LogService().log('RemoteChatBrowserPage: ERROR fetching rooms: $e');
      throw e;
    }
  }

  /// Silently refresh from API in background
  void _refreshFromApi() {
    _fetchFromApi().catchError((e) {
      LogService().log('RemoteChatBrowserPage: Background refresh failed: $e');
      // Don't update UI with error, keep showing cached data
    });
  }

  void _openRoom(ChatRoom room) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RemoteChatRoomPage(
          device: widget.device,
          room: room,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.device.displayName} - Chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadRooms,
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
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          _error!,
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadRooms,
                        child: Text(_i18n.t('retry')),
                      ),
                    ],
                  ),
                )
              : _rooms.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 64,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No chat rooms',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'This device has no accessible chat rooms',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _rooms.length,
                      itemBuilder: (context, index) {
                        final room = _rooms[index];
                        return _buildRoomCard(theme, room);
                      },
                    ),
    );
  }

  Widget _buildRoomCard(ThemeData theme, ChatRoom room) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _openRoom(room),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Room name
              Row(
                children: [
                  Icon(
                    room.visibility == 'PUBLIC'
                        ? Icons.public
                        : Icons.lock_outline,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      room.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),

              // Description
              if (room.description != null && room.description!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  room.description!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],

              // Member count
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.people,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${room.memberCount} ${room.memberCount == 1 ? 'member' : 'members'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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
}

/// Chat room data model
class ChatRoom {
  final String id;
  final String name;
  final String? description;
  final int memberCount;
  final String visibility;

  ChatRoom({
    required this.id,
    required this.name,
    this.description,
    required this.memberCount,
    required this.visibility,
  });

  factory ChatRoom.fromJson(Map<String, dynamic> json) {
    // Handle both memberCount (direct) and participants (array) formats
    int memberCount = 0;
    if (json.containsKey('memberCount')) {
      memberCount = json['memberCount'] as int? ?? 0;
    } else if (json.containsKey('participants')) {
      final participants = json['participants'];
      if (participants is List) {
        memberCount = participants.length;
      }
    }

    return ChatRoom(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Unnamed Room',
      description: json['description'] as String?,
      memberCount: memberCount,
      visibility: json['visibility'] as String? ?? 'PUBLIC',
    );
  }
}
