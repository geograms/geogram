/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:typed_data';
import '../models/chat_message.dart';
import '../models/dm_conversation.dart';
import '../services/direct_message_service.dart';
import '../services/dm_queue_service.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/profile_service.dart';
import '../services/chat_file_download_manager.dart';
import '../services/chat_file_upload_manager.dart';
import '../util/event_bus.dart';
import '../services/message_retention_service.dart';
import '../widgets/message_list_widget.dart';
import '../widgets/message_input_widget.dart';
import '../widgets/retention_picker_widget.dart';
import '../widgets/voice_recorder_widget.dart';
import '../services/audio_service.dart';
import '../services/audio_platform_stub.dart'
    if (dart.library.io) '../services/audio_platform_io.dart';
import 'photo_viewer_page.dart';

/// Page for 1:1 direct message conversation
class DMChatPage extends StatefulWidget {
  final String otherCallsign;

  const DMChatPage({Key? key, required this.otherCallsign}) : super(key: key);

  @override
  State<DMChatPage> createState() => _DMChatPageState();
}

class _DMChatPageState extends State<DMChatPage> {
  final DirectMessageService _dmService = DirectMessageService();
  final DevicesService _devicesService = DevicesService();
  final I18nService _i18n = I18nService();
  final ChatFileDownloadManager _downloadManager = ChatFileDownloadManager();
  final ChatFileUploadManager _uploadManager = ChatFileUploadManager();

  List<ChatMessage> _messages = [];
  DMConversation? _conversation;
  bool _isLoading = true;
  bool _isSending = false;
  bool _isRecording = false;
  bool _isSyncing = false;
  String? _error;
  ChatMessage? _quotedMessage;

  // Event subscriptions
  EventSubscription<DirectMessageReceivedEvent>? _messageSubscription;
  EventSubscription<DirectMessageSyncEvent>? _syncSubscription;
  EventSubscription<DMMessageDeliveredEvent>? _deliverySubscription;
  EventSubscription<DMMessageStatusChangedEvent>? _statusSubscription;
  EventSubscription<ChatDownloadProgressEvent>? _downloadSubscription;
  EventSubscription<ChatUploadProgressEvent>? _uploadSubscription;
  EventSubscription<DMRetentionChangedEvent>? _retentionSubscription;

  @override
  void initState() {
    super.initState();
    _initializeChat();
    _subscribeToEvents();
  }

  @override
  void dispose() {
    // Clear current conversation to resume tracking unread
    _dmService.setCurrentConversation(null);
    _messageSubscription?.cancel();
    _syncSubscription?.cancel();
    _deliverySubscription?.cancel();
    _statusSubscription?.cancel();
    _downloadSubscription?.cancel();
    _uploadSubscription?.cancel();
    _retentionSubscription?.cancel();
    super.dispose();
  }

  void _subscribeToEvents() {
    // Initialize upload manager for device reconnection tracking
    _uploadManager.initialize();
    final otherUpper = widget.otherCallsign.toUpperCase();

    // Listen for new messages
    _messageSubscription = EventBus().on<DirectMessageReceivedEvent>((event) {
      if (event.fromCallsign.toUpperCase() == otherUpper ||
          event.toCallsign.toUpperCase() == otherUpper) {
        // Reload messages when a relevant message is received
        _loadMessages();
      }
    });

    // Listen for sync completion
    _syncSubscription = EventBus().on<DirectMessageSyncEvent>((event) {
      if (event.otherCallsign.toUpperCase() == otherUpper) {
        if (event.success && event.newMessages > 0) {
          _loadMessages();
        }
      }
    });

    // Listen for queued message delivery
    _deliverySubscription = EventBus().on<DMMessageDeliveredEvent>((event) {
      if (event.callsign.toUpperCase() == otherUpper) {
        // Reload messages to update status from pending to delivered
        _loadMessages();
      }
    });

    // Listen for message status changes (pending -> delivered/failed)
    _statusSubscription = EventBus().on<DMMessageStatusChangedEvent>((event) {
      if (event.callsign.toUpperCase() == otherUpper) {
        // Reload messages to update status indicator
        _loadMessages();
      }
    });

    // Subscribe to download progress events for UI updates
    _downloadSubscription = EventBus().on<ChatDownloadProgressEvent>((event) {
      // Check if this download belongs to this conversation
      if (event.downloadId.startsWith(otherUpper)) {
        // Refresh UI to show progress
        if (mounted) setState(() {});
        // Reload messages when download completes to show the image
        if (event.status == 'completed') {
          _loadMessages();
        }
      }
    });

    // Subscribe to upload progress events for UI updates (sender side)
    _uploadSubscription = EventBus().on<ChatUploadProgressEvent>((event) {
      // Check if this upload belongs to this conversation
      if (event.receiverCallsign == otherUpper) {
        // Refresh UI to show upload progress
        if (mounted) setState(() {});
      }
    });

    // Listen for retention period changes
    _retentionSubscription = EventBus().on<DMRetentionChangedEvent>((event) {
      if (event.callsign == otherUpper) {
        // Reload conversation to get updated retention + reload messages (may have been purged)
        _initializeChat();
      }
    });
  }

  Future<void> _initializeChat() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await _dmService.initialize();
      _conversation = await _dmService.getOrCreateConversation(
        widget.otherCallsign,
      );

      // Mark this as the current conversation (prevents incrementing unread while viewing)
      _dmService.setCurrentConversation(widget.otherCallsign);

      await _loadMessages();

      // If device is online, try to flush any queued messages
      _tryFlushQueue();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to initialize chat: $e';
        });
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Try to flush queued messages if device is online
  void _tryFlushQueue() {
    final device = _devicesService.getDevice(widget.otherCallsign);
    final isOnline = device?.isOnline ?? false;

    if (isOnline) {
      // Trigger DMQueueService to process all queued messages (single delivery path)
      DMQueueService().processQueue().catchError((e) {
        // Ignore errors - queue will be retried later
      });
    }
  }

  Future<void> _loadMessages() async {
    try {
      final messages = await _dmService.loadMessages(
        widget.otherCallsign,
        limit: 200,
      );
      if (mounted) {
        setState(() {
          _messages = messages;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load messages: $e';
        });
      }
    }
  }

  Future<void> _sendMessage(String content) async {
    if (_isSending) return;
    if (content.trim().isEmpty) return;

    setState(() {
      _isSending = true;
    });

    try {
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

      // With optimistic UI, sendMessage always queues for background delivery
      // Message appears immediately with 'pending' status
      await _dmService.sendMessage(
        widget.otherCallsign,
        content.trim(),
        metadata: metadata.isNotEmpty ? metadata : null,
      );
      // Message will appear via DirectMessageReceivedEvent
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to send message: $e')));
      }
    }

    if (mounted) {
      setState(() {
        _isSending = false;
        _quotedMessage = null;
      });
    }
  }

  Future<void> _sendVoiceMessage(String filePath, int durationSeconds) async {
    setState(() {
      _isSending = true;
      _isRecording = false;
    });

    try {
      await _dmService.sendVoiceMessage(
        widget.otherCallsign,
        filePath,
        durationSeconds,
      );
      await _loadMessages();
    } on DMMustBeReachableException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('device_not_reachable')),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send voice message: $e')),
        );
      }
    }

    if (mounted) {
      setState(() {
        _isSending = false;
        _quotedMessage = null;
      });
    }
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

  Future<void> _toggleReaction(ChatMessage message, String reaction) async {
    try {
      final profile = ProfileService().getProfile();
      final updated = await _dmService.toggleReaction(
        widget.otherCallsign,
        message.timestamp,
        profile.callsign,
        reaction,
      );

      if (updated == null) {
        return;
      }

      if (mounted) {
        setState(() {
          final index = _messages.indexWhere(
            (msg) =>
                msg.timestamp == updated.timestamp &&
                msg.author == updated.author,
          );
          if (index != -1) {
            _messages[index] = updated;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to react: $e')));
      }
    }
  }

  void _startRecording() async {
    // Check permission first
    if (!await AudioService().hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required')),
        );
      }
      return;
    }
    if (mounted) {
      setState(() {
        _isRecording = true;
      });
    }
  }

  void _cancelRecording() {
    setState(() {
      _isRecording = false;
    });
  }

  Future<String?> _getVoiceFilePath(ChatMessage message) async {
    if (!message.hasVoice || message.voiceFile == null) return null;

    // First check if file exists locally
    final localPath = await _dmService.getVoiceFilePath(
      widget.otherCallsign,
      message.voiceFile!,
    );
    if (localPath != null) {
      return localPath;
    }

    // If not local and device is online, try to download
    final device = _devicesService.getDevice(widget.otherCallsign);
    if (device?.isOnline ?? false) {
      return await _dmService.downloadVoiceFile(
        widget.otherCallsign,
        message.voiceFile!,
      );
    }

    return null;
  }

  /// Get attachment data for a message file
  /// DM uses filesystem storage, so returns (path, null)
  Future<(String?, Uint8List?)> _getAttachmentData(ChatMessage message) async {
    if (!message.hasFile || message.attachedFile == null) return (null, null);

    final filename = message.attachedFile!;

    // First check if file exists locally
    final localPath = await _dmService.getFilePath(
      widget.otherCallsign,
      filename,
    );
    if (localPath != null) {
      return (localPath, null);
    }

    // If not local and device is online, try to download
    // Respecting bandwidth policy: auto-download only if <= 3 MB and <= 7 days old
    final fileSize = int.tryParse(message.getMeta('file_size') ?? '0') ?? 0;
    final messageAge = DateTime.now().difference(message.dateTime);
    final shouldAutoDownload =
        fileSize <= 3 * 1024 * 1024 && messageAge.inDays <= 7;

    if (!shouldAutoDownload) return (null, null);

    final device = _devicesService.getDevice(widget.otherCallsign);
    if (device?.isOnline ?? false) {
      // Download via DM file sync
      final path = await _dmService.downloadFile(
        widget.otherCallsign,
        filename,
      );
      return (path, null);
    }

    return (null, null);
  }

  /// Send a file message
  Future<void> _sendFileMessage(String filePath, String? caption) async {
    setState(() {
      _isSending = true;
    });

    try {
      await _dmService.sendFileMessage(widget.otherCallsign, filePath, caption);
      _clearQuotedMessage();
      await _loadMessages();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send file: $e'),
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

  /// Open image in full-screen viewer
  Future<void> _openImage(ChatMessage message) async {
    final (filePath, _) = await _getAttachmentData(message);
    if (filePath == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Image not available')));
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
        builder: (context) =>
            PhotoViewerPage(imagePaths: imagePaths, initialIndex: initialIndex),
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

  /// Check if download button should be shown for a message
  bool _shouldShowDownloadButton(ChatMessage message) {
    if (!message.hasFile) return false;

    final filename = message.attachedFile;
    if (filename == null) return false;

    // Check if file already downloaded locally
    // Note: We can't use async here, so we check download manager state
    final downloadId = _downloadManager.generateDownloadId(
      widget.otherCallsign.toUpperCase(),
      filename,
    );
    final downloadState = _downloadManager.getDownload(downloadId);
    if (downloadState?.status == ChatDownloadStatus.completed) return false;

    // Check file size against threshold
    final fileSize = int.tryParse(message.getMeta('file_size') ?? '0') ?? 0;
    if (fileSize <= 0) return false;

    final bandwidth = _downloadManager.getDeviceBandwidth(widget.otherCallsign);
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
    final downloadId = _downloadManager.generateDownloadId(
      widget.otherCallsign.toUpperCase(),
      message.attachedFile!,
    );
    return _downloadManager.getDownload(downloadId);
  }

  /// Handle download button pressed
  Future<void> _onDownloadPressed(ChatMessage message) async {
    if (!message.hasFile || message.attachedFile == null) return;

    final filename = message.attachedFile!;
    final fileSize = int.tryParse(message.getMeta('file_size') ?? '0') ?? 0;
    final downloadId = _downloadManager.generateDownloadId(
      widget.otherCallsign.toUpperCase(),
      filename,
    );

    await _downloadManager.downloadFile(
      id: downloadId,
      sourceId: widget.otherCallsign.toUpperCase(),
      filename: filename,
      expectedBytes: fileSize,
      downloadFn: (resumeFrom, onProgress) async {
        // Use the DM service to download with progress
        return await _dmService.downloadFileWithProgress(
          widget.otherCallsign,
          filename,
          resumeFrom: resumeFrom,
          onProgress: onProgress,
        );
      },
    );
  }

  /// Handle download cancel pressed
  Future<void> _onCancelDownload(ChatMessage message) async {
    if (!message.hasFile || message.attachedFile == null) return;

    final downloadId = _downloadManager.generateDownloadId(
      widget.otherCallsign.toUpperCase(),
      message.attachedFile!,
    );
    await _downloadManager.cancelDownload(downloadId);
  }

  /// Get upload state for a message (sender side progress tracking)
  ChatUpload? _getUploadState(ChatMessage message) {
    if (!message.hasFile || message.attachedFile == null) return null;

    // Only show upload state for messages sent by current user
    final currentCallsign = ProfileService()
        .getProfile()
        .callsign
        .toUpperCase();
    if (message.author.toUpperCase() != currentCallsign) return null;

    return _uploadManager.getUploadForFile(
      widget.otherCallsign.toUpperCase(),
      message.attachedFile!,
    );
  }

  /// Handle retry upload button pressed
  Future<void> _onRetryUpload(ChatMessage message) async {
    if (!message.hasFile || message.attachedFile == null) return;

    final filename = message.attachedFile!;
    final success = await _uploadManager.requestRetry(
      widget.otherCallsign,
      filename,
    );

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Retry notification sent to receiver')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot retry - device not reachable')),
        );
      }
    }
  }

  Future<void> _syncMessages() async {
    final device = _devicesService.getDevice(widget.otherCallsign);
    final isOnline = device?.isOnline ?? false;

    if (!isOnline) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_i18n.t('device_not_reachable'))));
      return;
    }

    setState(() {
      _isSyncing = true;
    });

    try {
      // First, flush any queued messages via DMQueueService (single delivery path)
      await DMQueueService().processQueue();

      // Then sync to get messages from them
      final result = await _dmService.syncWithDevice(
        widget.otherCallsign,
        deviceUrl: device!.url,
      );

      if (mounted) {
        if (result.success) {
          await _loadMessages();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Sync complete: ${result.messagesReceived} received, ${result.messagesSent} sent',
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Sync failed: ${result.error}')),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = _devicesService.getDevice(widget.otherCallsign);
    final isOnline = device?.isOnline ?? false;
    final nickname = device?.displayName;
    final hasNickname =
        nickname != null && nickname != device?.callsign && nickname.isNotEmpty;
    final title = hasNickname
        ? '$nickname (${widget.otherCallsign})'
        : widget.otherCallsign;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            // Online indicator
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOnline ? Colors.green : Colors.grey,
              ),
            ),
            Expanded(
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        actions: [
          // Sync button with spinner when syncing
          if (_isSyncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: _i18n.t('sync'),
              onPressed: _syncMessages,
            ),
          // Disappearing messages timer icon
          IconButton(
            icon: Icon(
              _conversation?.retentionPeriod != null &&
                      _conversation!.retentionPeriod != RetentionPeriod.forever
                  ? Icons.timer
                  : Icons.timer_outlined,
              color:
                  _conversation?.retentionPeriod != null &&
                      _conversation!.retentionPeriod != RetentionPeriod.forever
                  ? Colors.amber
                  : null,
            ),
            tooltip: 'Disappearing messages',
            onPressed: _showRetentionPicker,
          ),
          // Info button
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: _i18n.t('info'),
            onPressed: () => _showConversationInfo(),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _initializeChat,
              child: Text(_i18n.t('retry')),
            ),
          ],
        ),
      );
    }

    final device = _devicesService.getDevice(widget.otherCallsign);
    final isOnline = device?.isOnline ?? false;

    return Column(
      children: [
        // Syncing banner
        if (_isSyncing)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.blue.shade100,
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.blue.shade900,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _i18n.t('syncing'),
                  style: TextStyle(color: Colors.blue.shade900, fontSize: 13),
                ),
              ],
            ),
          ),
        // Offline banner - messages will be queued
        if (!isOnline && !_isSyncing)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.orange.shade100,
            child: Row(
              children: [
                Icon(Icons.schedule, size: 16, color: Colors.orange.shade900),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _i18n.t('device_offline_messages_queued'),
                    style: TextStyle(
                      color: Colors.orange.shade900,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        // Messages list
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Text(
                    _i18n.t('no_messages_yet'),
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                )
              : MessageListWidget(
                  messages: _messages,
                  isGroupChat: false, // 1:1 DM conversation
                  getVoiceFilePath: _getVoiceFilePath,
                  getAttachmentData: _getAttachmentData,
                  onMessageQuote: _setQuotedMessage,
                  onMessageReact: _toggleReaction,
                  onImageOpen: _openImage,
                  // Download manager integration
                  shouldShowDownloadButton: _shouldShowDownloadButton,
                  getFileSize: _getFileSize,
                  getDownloadState: _getDownloadState,
                  onDownloadPressed: _onDownloadPressed,
                  onCancelDownload: _onCancelDownload,
                  // Upload manager integration (sender side)
                  getUploadState: _getUploadState,
                  onRetryUpload: _onRetryUpload,
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
          // Message input - always enabled (queues when offline)
          MessageInputWidget(
            onSend: (content, filePath) async {
              if (filePath != null) {
                await _sendFileMessage(filePath, content);
              } else {
                await _sendMessage(content);
              }
            },
            allowFiles: isOnline, // Only allow files when device is online
            // Only show mic button on supported platforms (Linux, Android) and when online
            onMicPressed: isOnline && isVoiceSupported ? _startRecording : null,
            quotedMessage: _quotedMessage,
            onClearQuote: _clearQuotedMessage,
          ),
      ],
    );
  }

  Future<void> _showRetentionPicker() async {
    final current = _conversation?.retentionPeriod ?? RetentionPeriod.forever;
    final picked = await showRetentionPicker(context, current);
    if (picked == null || picked == current) return;

    await _dmService.setRetention(widget.otherCallsign, picked);
    // UI updates via DMRetentionChangedEvent subscription
  }

  void _showConversationInfo() {
    final device = _devicesService.getDevice(widget.otherCallsign);
    final nickname = device?.displayName;
    final hasNickname =
        nickname != null && nickname != device?.callsign && nickname.isNotEmpty;
    final infoTitle = hasNickname
        ? '$nickname (${widget.otherCallsign})'
        : widget.otherCallsign;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Chat with $infoTitle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow(
              'Status',
              device?.isOnline ?? false ? 'Online' : 'Offline',
            ),
            if (_conversation != null) ...[
              const SizedBox(height: 8),
              _infoRow('Messages', '${_messages.length}'),
              _infoRow('Last activity', _conversation!.lastActivityText),
              _infoRow('Sync status', _conversation!.syncStatusText),
              _infoRow(
                'Auto-delete',
                retentionLabel(
                  _conversation!.retentionPeriod ?? RetentionPeriod.forever,
                ),
              ),
            ],
            if (device?.url != null) ...[
              const SizedBox(height: 8),
              _infoRow('URL', device!.url!),
            ],
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

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
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
}
