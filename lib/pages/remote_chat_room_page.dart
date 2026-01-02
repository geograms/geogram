/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/signing_service.dart';
import '../services/station_cache_service.dart';
import '../services/storage_config.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import '../util/reaction_utils.dart';
import '../widgets/message_input_widget.dart';
import '../widgets/message_list_widget.dart';
import '../widgets/voice_recorder_widget.dart';
import '../services/audio_service.dart';
import '../services/audio_platform_stub.dart'
    if (dart.library.io) '../services/audio_platform_io.dart';
import 'remote_chat_browser_page.dart';
import 'photo_viewer_page.dart';

/// Page for viewing messages in a chat room from a remote device
class RemoteChatRoomPage extends StatefulWidget {
  final RemoteDevice device;
  final ChatRoom room;

  const RemoteChatRoomPage({
    super.key,
    required this.device,
    required this.room,
  });

  @override
  State<RemoteChatRoomPage> createState() => _RemoteChatRoomPageState();
}

class _RemoteChatRoomPageState extends State<RemoteChatRoomPage> {
  final DevicesService _devicesService = DevicesService();
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();
  final RelayCacheService _cacheService = RelayCacheService();

  List<ChatMessage> _messages = [];
  bool _isLoading = true;
  bool _isSending = false;
  bool _isRecording = false;
  String? _error;
  ChatMessage? _quotedMessage;

  /// Track pending file downloads to avoid duplicate requests
  final Set<String> _pendingDownloads = {};

  @override
  void initState() {
    super.initState();
    _initServices();
    _loadMessages();
  }

  Future<void> _initServices() async {
    await _cacheService.initialize();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadMessages() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Try to load from cache first for instant response
      final cachedMessages = await _loadFromCache();
      if (cachedMessages.isNotEmpty) {
        setState(() {
          _messages = cachedMessages;
          _isLoading = false;
        });

        // Silently refresh from API in background
        _refreshFromApi();
        return;
      }

      // No cache - fetch from API
      await _fetchFromApi();
    } catch (e) {
      LogService().log('RemoteChatRoomPage: Error loading messages: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Load messages from cached data on disk
  Future<List<ChatMessage>> _loadFromCache() async {
    try {
      final dataDir = StorageConfig().baseDir;
      final roomPath = '$dataDir/devices/${widget.device.callsign}/chat/${widget.room.id}';
      final roomDir = Directory(roomPath);

      if (!await roomDir.exists()) {
        return [];
      }

      final messages = <ChatMessage>[];
      await for (final entity in roomDir.list()) {
        if (entity is File && entity.path.endsWith('.json') && !entity.path.endsWith('config.json')) {
          try {
            final content = await entity.readAsString();
            final data = json.decode(content) as Map<String, dynamic>;
            messages.add(ChatMessage.fromJson(data));
          } catch (e) {
            LogService().log('Error reading message ${entity.path}: $e');
          }
        }
      }

      // Sort by timestamp
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      LogService().log('RemoteChatRoomPage: Loaded ${messages.length} cached messages');
      return messages;
    } catch (e) {
      LogService().log('RemoteChatRoomPage: Error loading cache: $e');
      return [];
    }
  }

  /// Fetch fresh messages from API
  Future<void> _fetchFromApi() async {
    try {
      LogService().log('RemoteChatRoomPage: Fetching messages from ${widget.device.callsign}, room ${widget.room.id}');

      // Generate signed auth header for restricted room access
      final profile = _profileService.getProfile();
      final signingService = SigningService();
      await signingService.initialize();

      final authHeader = await signingService.generateAuthHeader(
        profile,
        action: 'read-messages',
        tags: [['room', widget.room.id]],
      );

      final headers = <String, String>{};
      if (authHeader != null) {
        headers['Authorization'] = 'Nostr $authHeader';
      }

      final response = await _devicesService.makeDeviceApiRequest(
        callsign: widget.device.callsign,
        method: 'GET',
        path: '/api/chat/${widget.room.id}/messages?limit=100',
        headers: headers.isNotEmpty ? headers : null,
      );

      LogService().log('RemoteChatRoomPage: Response status=${response?.statusCode}, body length=${response?.body.length}');

      if (response != null && response.statusCode == 200) {
        final responseBody = json.decode(response.body);
        LogService().log('RemoteChatRoomPage: Response body type=${responseBody.runtimeType}');

        // Handle both direct list and wrapped response
        final List<dynamic> data = responseBody is List ? responseBody : (responseBody['messages'] ?? []);

        LogService().log('RemoteChatRoomPage: Parsed ${data.length} messages');

        setState(() {
          _messages = data.map((json) => ChatMessage.fromJson(json as Map<String, dynamic>)).toList();
          _isLoading = false;
        });

        LogService().log('RemoteChatRoomPage: Fetched ${_messages.length} messages from API');
      } else {
        throw Exception('HTTP ${response?.statusCode ?? "null"}: ${response?.body ?? "no response"}');
      }
    } catch (e) {
      LogService().log('RemoteChatRoomPage: ERROR fetching messages: $e');
      rethrow;
    }
  }

  /// Silently refresh from API in background
  void _refreshFromApi() {
    _fetchFromApi().catchError((e) {
      LogService().log('RemoteChatRoomPage: Background refresh failed: $e');
      // Don't update UI with error, keep showing cached data
    });
  }

  void _setQuotedMessage(ChatMessage message) {
    setState(() {
      _quotedMessage = message;
    });
  }

  void _clearQuotedMessage() {
    setState(() {
      _quotedMessage = null;
    });
  }

  /// Start voice recording
  void _startRecording() async {
    // Check permission first
    if (!await AudioService().hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('microphone_permission_required'))),
        );
      }
      return;
    }
    setState(() {
      _isRecording = true;
    });
  }

  /// Cancel voice recording
  void _cancelRecording() {
    setState(() {
      _isRecording = false;
    });
  }

  /// Send voice message
  Future<void> _sendVoiceMessage(String filePath, int durationSeconds) async {
    setState(() {
      _isSending = true;
      _isRecording = false;
    });

    try {
      final profile = _profileService.getProfile();
      final signingService = SigningService();
      await signingService.initialize();

      if (!signingService.canSign(profile)) {
        throw Exception(_i18n.t('nostr_keys_not_configured'));
      }

      // Validate file size (10 MB limit)
      final file = File(filePath);
      final fileSize = await file.length();
      if (fileSize > 10 * 1024 * 1024) {
        throw Exception(_i18n.t('file_too_large', params: ['10 MB']));
      }

      // Upload voice file to remote device
      final uploadedFilename = await _devicesService.uploadChatFile(
        callsign: widget.device.callsign,
        roomId: widget.room.id,
        filePath: filePath,
      );

      if (uploadedFilename == null) {
        throw Exception(_i18n.t('file_upload_failed'));
      }

      // Create signed message with voice metadata
      final signedEvent = await signingService.generateSignedEvent(
        '', // Empty content for voice messages
        {
          'room': widget.room.id,
          'callsign': profile.callsign,
        },
        profile,
      );

      if (signedEvent == null || signedEvent.sig == null) {
        throw Exception('Failed to sign message');
      }

      final metadata = <String, String>{
        'voice': uploadedFilename,
        'voice_duration': durationSeconds.toString(),
        'file_size': fileSize.toString(),
      };

      final payload = {
        'event': signedEvent.toJson(),
        'metadata': metadata,
      };

      final response = await _devicesService.makeDeviceApiRequest(
        callsign: widget.device.callsign,
        method: 'POST',
        path: '/api/chat/${widget.room.id}/messages',
        body: jsonEncode(payload),
        headers: {'Content-Type': 'application/json'},
      );

      if (response != null && (response.statusCode == 200 || response.statusCode == 201)) {
        await _fetchFromApi();
      } else {
        throw Exception('HTTP ${response?.statusCode ?? "null"}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_i18n.t('failed_to_send_voice')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  /// Get voice file path for playback
  Future<String?> _getVoiceFilePath(ChatMessage message) async {
    if (!message.hasVoice || message.voiceFile == null) return null;

    // Voice files use the same storage as regular file attachments
    return _getAttachmentPath(ChatMessage(
      author: message.author,
      content: message.content,
      timestamp: message.timestamp,
      metadata: {'file': message.voiceFile!},
    ));
  }

  /// Get attachment path for a message
  /// Checks cache first, downloads if needed (respecting bandwidth limits)
  Future<String?> _getAttachmentPath(ChatMessage message) async {
    if (!message.hasFile) return null;

    final filename = message.attachedFile;
    if (filename == null) return null;

    // Check if already cached
    final cachedPath = await _cacheService.getChatFilePath(
      widget.device.callsign,
      widget.room.id,
      filename,
    );

    if (cachedPath != null) {
      return cachedPath;
    }

    // Check bandwidth-conscious download policy:
    // Auto-download only if file is <= 3 MB and message is <= 7 days old
    final fileSize = int.tryParse(message.getMeta('file_size') ?? '0') ?? 0;
    final messageAge = DateTime.now().difference(message.dateTime);
    final shouldAutoDownload = fileSize <= 3 * 1024 * 1024 && messageAge.inDays <= 7;

    if (!shouldAutoDownload) {
      // Don't auto-download, user must click download button
      return null;
    }

    // Check if download already in progress
    final downloadKey = '${widget.device.callsign}/${widget.room.id}/$filename';
    if (_pendingDownloads.contains(downloadKey)) return null;
    _pendingDownloads.add(downloadKey);

    try {
      // Download file
      final localPath = await _devicesService.downloadChatFile(
        callsign: widget.device.callsign,
        roomId: widget.room.id,
        filename: filename,
      );

      return localPath;
    } finally {
      _pendingDownloads.remove(downloadKey);
    }
  }

  /// Open image in full-screen viewer
  Future<void> _openImage(ChatMessage message) async {
    final filePath = await _getAttachmentPath(message);
    if (filePath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('image_not_available'))),
        );
      }
      return;
    }

    // Collect all image paths from messages
    final imagePaths = <String>[];
    for (final msg in _messages) {
      if (!msg.hasFile) continue;
      final path = await _getAttachmentPath(msg);
      if (path == null) continue;
      if (!_isImageFile(path)) continue;
      imagePaths.add(path);
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

  bool _isImageFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  bool _canDeleteMessage(ChatMessage message) {
    final profile = _profileService.getProfile();
    return message.author.toUpperCase() == profile.callsign.toUpperCase() ||
        (message.npub != null &&
         message.npub!.isNotEmpty &&
         profile.npub.isNotEmpty &&
         message.npub == profile.npub);
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    if (!_canDeleteMessage(message)) return;

    try {
      final profile = _profileService.getProfile();
      final signingService = SigningService();
      await signingService.initialize();

      if (!signingService.canSign(profile)) {
        throw Exception('NOSTR keys not configured');
      }

      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: 'delete',
        tags: [
          ['action', 'delete'],
          ['room', widget.room.id],
          ['timestamp', message.timestamp],
          ['callsign', profile.callsign],
        ],
      );
      event.calculateId();
      final signedEvent = await signingService.signEvent(event, profile);
      if (signedEvent == null) {
        throw Exception('Failed to sign delete request');
      }

      final authEvent = base64Encode(utf8.encode(jsonEncode(signedEvent.toJson())));
      final response = await _devicesService.makeDeviceApiRequest(
        callsign: widget.device.callsign,
        method: 'DELETE',
        path: '/api/chat/${widget.room.id}/messages/${Uri.encodeComponent(message.timestamp)}',
        headers: {
          'Authorization': 'Nostr $authEvent',
        },
      );

      if (response != null && response.statusCode == 200) {
        await _fetchFromApi();
      } else {
        throw Exception('HTTP ${response?.statusCode ?? "null"}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete message: $e')),
        );
      }
    }
  }

  Future<void> _toggleReaction(ChatMessage message, String reaction) async {
    try {
      final profile = _profileService.getProfile();
      final signingService = SigningService();
      await signingService.initialize();

      if (!signingService.canSign(profile)) {
        throw Exception('NOSTR keys not configured');
      }

      final reactionKey = ReactionUtils.normalizeReactionKey(reaction);
      if (reactionKey.isEmpty) {
        throw Exception('Invalid reaction');
      }

      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: 'react',
        tags: [
          ['action', 'react'],
          ['room', widget.room.id],
          ['timestamp', message.timestamp],
          ['reaction', reactionKey],
          ['callsign', profile.callsign],
        ],
      );
      event.calculateId();

      final signedEvent = await signingService.signEvent(event, profile);
      if (signedEvent == null) {
        throw Exception('Failed to sign reaction event');
      }

      final authEvent = base64Encode(utf8.encode(jsonEncode(signedEvent.toJson())));
      final response = await _devicesService.makeDeviceApiRequest(
        callsign: widget.device.callsign,
        method: 'POST',
        path: '/api/chat/${widget.room.id}/messages/${Uri.encodeComponent(message.timestamp)}/reactions',
        headers: {
          'Authorization': 'Nostr $authEvent',
        },
      );

      if (response != null && response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final rawReactions = data['reactions'] as Map?;
        final reactions = <String, List<String>>{};
        if (rawReactions != null) {
          rawReactions.forEach((key, value) {
            if (value is List) {
              reactions[key.toString()] =
                  value.map((entry) => entry.toString()).toList();
            }
          });
        }
        final normalized = ReactionUtils.normalizeReactionMap(reactions);

        if (mounted) {
          setState(() {
            final index = _messages.indexWhere((msg) =>
                msg.timestamp == message.timestamp &&
                msg.author == message.author);
            if (index != -1) {
              _messages[index] = message.copyWith(reactions: normalized);
            }
          });
        }
      } else {
        throw Exception('HTTP ${response?.statusCode ?? "null"}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to react: $e')),
        );
      }
    }
  }

  Future<void> _sendMessage(String content, String? filePath) async {
    if (content.isEmpty && filePath == null) return;

    try {
      final profile = _profileService.getProfile();

      LogService().log('RemoteChatRoomPage: Sending message to ${widget.device.callsign}, room ${widget.room.id}');

      // Use SigningService to create signed event
      final signingService = SigningService();
      await signingService.initialize();

      if (!signingService.canSign(profile)) {
        throw Exception('Cannot send to remote chat: NOSTR keys not configured. Please set up your npub/nsec in Settings.');
      }

      // Generate signed event with room and callsign tags
      // Per chat-format-specification.md: tags must include [['t', 'chat'], ['room', roomId], ['callsign', callsign]]
      final signedEvent = await signingService.generateSignedEvent(
        content,
        {
          'room': widget.room.id,
          'callsign': profile.callsign,
        },
        profile,
      );

      if (signedEvent == null || signedEvent.sig == null) {
        throw Exception('Failed to sign message');
      }

      LogService().log('RemoteChatRoomPage: Created signed event id=${signedEvent.id}');

      final metadata = <String, String>{};
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

      // Upload file if attached
      if (filePath != null) {
        // Validate 10 MB limit
        final file = File(filePath);
        final fileSize = await file.length();
        if (fileSize > 10 * 1024 * 1024) {
          throw Exception(_i18n.t('file_too_large', params: ['10 MB']));
        }

        // Upload file to remote device
        final uploadedFilename = await _devicesService.uploadChatFile(
          callsign: widget.device.callsign,
          roomId: widget.room.id,
          filePath: filePath,
        );

        if (uploadedFilename != null) {
          metadata['file'] = uploadedFilename;
          metadata['file_size'] = fileSize.toString();
        } else {
          throw Exception(_i18n.t('file_upload_failed'));
        }
      }

      // Send as NOSTR-signed event per API specification
      final payload = {
        'event': signedEvent.toJson(),
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

      final response = await _devicesService.makeDeviceApiRequest(
        callsign: widget.device.callsign,
        method: 'POST',
        path: '/api/chat/${widget.room.id}/messages',
        body: jsonEncode(payload),
        headers: {'Content-Type': 'application/json'},
      );

      LogService().log('RemoteChatRoomPage: Response status=${response?.statusCode}');

      if (response != null && (response.statusCode == 200 || response.statusCode == 201)) {
        _clearQuotedMessage();

        // Reload messages to show the new one
        await _fetchFromApi();

        LogService().log('RemoteChatRoomPage: Message sent successfully');
      } else {
        final errorBody = response?.body ?? 'no response';
        LogService().log('RemoteChatRoomPage: Send failed - status=${response?.statusCode}, body=$errorBody');
        throw Exception('Failed to send message: HTTP ${response?.statusCode}: $errorBody');
      }
    } catch (e) {
      LogService().log('RemoteChatRoomPage: Error sending message: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send message: $e')),
        );
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.room.name),
            Text(
              widget.device.displayName,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadMessages,
            tooltip: _i18n.t('refresh'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages area
          Expanded(
            child: _isLoading
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
                              onPressed: _loadMessages,
                              child: Text(_i18n.t('retry')),
                            ),
                          ],
                        ),
                      )
                    : MessageListWidget(
                        messages: _messages,
                        isGroupChat: true,
                        onMessageQuote: _setQuotedMessage,
                        onMessageDelete: _deleteMessage,
                        canDeleteMessage: _canDeleteMessage,
                        onMessageReact: _toggleReaction,
                        getAttachmentPath: _getAttachmentPath,
                        getVoiceFilePath: _getVoiceFilePath,
                        onImageOpen: _openImage,
                      ),
          ),

          // Message input / Voice recorder
          if (_isSending)
            Container(
              padding: const EdgeInsets.all(16),
              child: const Center(child: CircularProgressIndicator()),
            )
          else if (_isRecording)
            Padding(
              padding: const EdgeInsets.all(8),
              child: VoiceRecorderWidget(
                onSend: _sendVoiceMessage,
                onCancel: _cancelRecording,
              ),
            )
          else
            MessageInputWidget(
              onSend: _sendMessage,
              allowFiles: true,
              // Only show mic button on supported platforms
              onMicPressed: isVoiceSupported ? _startRecording : null,
              quotedMessage: _quotedMessage,
              onClearQuote: _clearQuotedMessage,
            ),
        ],
      ),
    );
  }
}
