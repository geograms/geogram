/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/signing_service.dart';
import '../services/station_cache_service.dart';
import '../services/storage_config.dart';
import '../services/chat_file_download_manager.dart';
import '../api/endpoints/chat_api.dart' show ChatApi;
import '../services/contact_service.dart';
import '../util/event_bus.dart';
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
  final ChatFileDownloadManager _downloadManager = ChatFileDownloadManager();

  List<ChatMessage> _messages = [];
  bool _isLoading = true;
  bool _isSending = false;
  bool _isRecording = false;
  String? _error;
  ChatMessage? _quotedMessage;

  /// Contact nickname map for display in chat bubbles
  Map<String, String> _nicknameMap = {};

  /// Track pending file downloads to avoid duplicate requests
  final Set<String> _pendingDownloads = {};

  /// Download progress event subscription
  EventSubscription<ChatDownloadProgressEvent>? _downloadSubscription;

  @override
  void initState() {
    super.initState();
    _initServices();
    _loadMessages();
    _subscribeToDownloadEvents();
    _loadNicknameMap();
  }

  Future<void> _initServices() async {
    await _cacheService.initialize();
  }

  Future<void> _loadNicknameMap() async {
    final map = await ContactService().buildNicknameMap();
    if (mounted) {
      setState(() {
        _nicknameMap = map;
      });
    }
  }

  void _subscribeToDownloadEvents() {
    final sourceId = '${widget.device.callsign}_${widget.room.id}'.toUpperCase();
    _downloadSubscription = EventBus().on<ChatDownloadProgressEvent>((event) {
      // Check if this download belongs to this room
      if (event.downloadId.startsWith(sourceId)) {
        // Refresh UI to show progress
        if (mounted) setState(() {});
        // Reload messages when download completes to show the image
        if (event.status == 'completed') {
          _loadMessages();
        }
      }
    });
  }

  @override
  void dispose() {
    _downloadSubscription?.cancel();
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
        path: '${ChatApi.messagesPath(widget.room.id)}?limit=100',
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

      // Send message in format expected by server API
      final payload = {
        'callsign': profile.callsign,
        'content': '', // Empty content for voice messages
        'npub': profile.npub,
        'pubkey': signedEvent.pubkey,
        'event_id': signedEvent.id,
        'signature': signedEvent.sig,
        'created_at': signedEvent.createdAt,
        'metadata': metadata,
      };

      final response = await _devicesService.makeDeviceApiRequest(
        callsign: widget.device.callsign,
        method: 'POST',
        path: ChatApi.messagesPath(widget.room.id),
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
    final (path, _) = await _getAttachmentData(ChatMessage(
      author: message.author,
      content: message.content,
      timestamp: message.timestamp,
      metadata: {'file': message.voiceFile!},
    ));
    return path;
  }

  /// Get attachment data for a message
  /// Checks cache first, downloads if needed (respecting bandwidth limits)
  /// Remote rooms use filesystem cache, so returns (path, null)
  Future<(String?, Uint8List?)> _getAttachmentData(ChatMessage message) async {
    if (!message.hasFile) return (null, null);

    final filename = message.attachedFile;
    if (filename == null) return (null, null);

    // Check if already cached
    final cachedPath = await _cacheService.getChatFilePath(
      widget.device.callsign,
      widget.room.id,
      filename,
    );

    if (cachedPath != null) {
      return (cachedPath, null);
    }

    // Check bandwidth-conscious download policy:
    // Auto-download only if file is <= 3 MB and message is <= 7 days old
    final fileSize = int.tryParse(message.getMeta('file_size') ?? '0') ?? 0;
    final messageAge = DateTime.now().difference(message.dateTime);
    final shouldAutoDownload = fileSize <= 3 * 1024 * 1024 && messageAge.inDays <= 7;

    if (!shouldAutoDownload) {
      // Don't auto-download, user must click download button
      return (null, null);
    }

    // Check if download already in progress
    final downloadKey = '${widget.device.callsign}/${widget.room.id}/$filename';
    if (_pendingDownloads.contains(downloadKey)) return (null, null);
    _pendingDownloads.add(downloadKey);

    try {
      // Download file
      final localPath = await _devicesService.downloadChatFile(
        callsign: widget.device.callsign,
        roomId: widget.room.id,
        filename: filename,
      );

      return (localPath, null);
    } finally {
      _pendingDownloads.remove(downloadKey);
    }
  }

  /// Open image in full-screen viewer
  Future<void> _openImage(ChatMessage message) async {
    final (filePath, _) = await _getAttachmentData(message);
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
      final (path, _) = await _getAttachmentData(msg);
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

  /// Get source ID for download manager (device + room)
  String get _sourceId => '${widget.device.callsign}_${widget.room.id}'.toUpperCase();

  /// Check if download button should be shown for a message
  bool _shouldShowDownloadButton(ChatMessage message) {
    if (!message.hasFile) return false;

    final filename = message.attachedFile;
    if (filename == null) return false;

    // Check if file already downloaded locally
    final downloadId = _downloadManager.generateDownloadId(_sourceId, filename);
    final downloadState = _downloadManager.getDownload(downloadId);
    if (downloadState?.status == ChatDownloadStatus.completed) return false;

    // Check file size against threshold
    final fileSize = int.tryParse(message.getMeta('file_size') ?? '0') ?? 0;
    if (fileSize <= 0) return false;

    final bandwidth = _downloadManager.getDeviceBandwidth(widget.device.callsign);
    return !_downloadManager.shouldAutoDownload(bandwidth, fileSize);
  }

  /// Get file size for a message
  int? _getFileSize(ChatMessage message) {
    if (!message.hasFile) return null;
    return int.tryParse(message.getMeta('file_size') ?? '0');
  }

  /// Get download state for a message
  ChatDownload? _getDownloadState(ChatMessage message) {
    if (!message.hasFile || message.attachedFile == null) return null;
    final downloadId = _downloadManager.generateDownloadId(_sourceId, message.attachedFile!);
    return _downloadManager.getDownload(downloadId);
  }

  /// Handle download button pressed
  Future<void> _onDownloadPressed(ChatMessage message) async {
    if (!message.hasFile || message.attachedFile == null) return;

    final filename = message.attachedFile!;
    final fileSize = int.tryParse(message.getMeta('file_size') ?? '0') ?? 0;
    final downloadId = _downloadManager.generateDownloadId(_sourceId, filename);

    await _downloadManager.downloadFile(
      id: downloadId,
      sourceId: _sourceId,
      filename: filename,
      expectedBytes: fileSize,
      downloadFn: (resumeFrom, onProgress) async {
        // Download via device service
        final localPath = await _devicesService.downloadChatFile(
          callsign: widget.device.callsign,
          roomId: widget.room.id,
          filename: filename,
        );

        // Simulate progress for non-streaming download
        if (localPath != null) {
          onProgress(fileSize);
        }

        return localPath;
      },
    );
  }

  /// Handle download cancel pressed
  Future<void> _onCancelDownload(ChatMessage message) async {
    if (!message.hasFile || message.attachedFile == null) return;

    final downloadId = _downloadManager.generateDownloadId(_sourceId, message.attachedFile!);
    await _downloadManager.cancelDownload(downloadId);
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
        path: '${ChatApi.messagesPath(widget.room.id)}/${Uri.encodeComponent(message.timestamp)}',
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
        path: ChatApi.reactionsPath(widget.room.id, Uri.encodeComponent(message.timestamp)),
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

      // Send message in format expected by server API
      // Server expects flattened fields, not nested event object
      final payload = {
        'callsign': profile.callsign,
        'content': content,
        'npub': profile.npub,
        'pubkey': signedEvent.pubkey,
        'event_id': signedEvent.id,
        'signature': signedEvent.sig,
        'created_at': signedEvent.createdAt,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

      final response = await _devicesService.makeDeviceApiRequest(
        callsign: widget.device.callsign,
        method: 'POST',
        path: ChatApi.messagesPath(widget.room.id),
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
                        getAttachmentData: _getAttachmentData,
                        getVoiceFilePath: _getVoiceFilePath,
                        onImageOpen: _openImage,
                        // Download manager integration
                        shouldShowDownloadButton: _shouldShowDownloadButton,
                        getFileSize: _getFileSize,
                        getDownloadState: _getDownloadState,
                        onDownloadPressed: _onDownloadPressed,
                        onCancelDownload: _onCancelDownload,
                        nicknameMap: _nicknameMap,
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
