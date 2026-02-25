/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Chat view page — message list + text input for a single conversation.
 * Detects forum supergroups and shows topic list instead.
 *
 * Features:
 *   - Cache-first loading (instant from SQLite, then TDLib refresh)
 *   - Day separators between message groups
 *   - Sender name + profile photo avatar resolution
 *   - Inline media display with background download
 *   - Tap-to-open gallery for photos/videos/GIFs, document viewer for files
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../pages/document_viewer_editor_page.dart';
import '../../../pages/photo_viewer_page.dart';
import '../../../services/file_launcher_service.dart';
import '../../../services/log_service.dart';
import '../models/telegram_forum_topic.dart';
import '../models/telegram_message.dart';
import '../models/telegram_user.dart';
import '../telegram_service.dart';
import '../telegram_log.dart';
import '../widgets/telegram_message_bubble.dart';

class TelegramChatPage extends StatefulWidget {
  final int chatId;
  final String chatTitle;
  /// If set, load messages for this forum topic thread only.
  final int? messageThreadId;
  final String? topicName;

  const TelegramChatPage({
    super.key,
    required this.chatId,
    required this.chatTitle,
    this.messageThreadId,
    this.topicName,
  });

  @override
  State<TelegramChatPage> createState() => _TelegramChatPageState();
}

class _TelegramChatPageState extends State<TelegramChatPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();
  StreamSubscription<TelegramEvent>? _eventSub;
  List<TelegramMessage> _messages = [];
  List<TelegramForumTopic> _topics = [];
  Map<int, Uint8List> _topicPhotos = {};
  bool _loading = true;
  bool _sending = false;
  bool _isForum = false;
  bool _loadingOlder = false;
  bool _hasMoreMessages = true;

  /// Message being replied to (shown in reply compose bar).
  TelegramMessage? _replyTarget;

  /// Message ID to briefly highlight after scrolling to it.
  int? _highlightMessageId;
  Timer? _highlightTimer;

  /// GlobalKeys per message ID for ensureVisible scrolling.
  final Map<int, GlobalKey> _messageKeys = {};

  /// Whether this chat page is the active (visible) route.
  bool _isActive = true;

  /// Per-chat DB file size label.
  String? _chatDbSize;

  /// Currently typing users: userId → display name.
  final Map<int, String> _typingUsers = {};
  Timer? _typingClearTimer;

  /// Cached user info keyed by userId, resolved progressively.
  final Map<int, TelegramUser> _userCache = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _init();
  }

  Future<void> _init() async {
    _isActive = true;
    _computeChatDbSize();
    final chatService = TelegramService().chatService;
    if (chatService == null) {
      setState(() => _loading = false);
      return;
    }

    _listenForNewMessages();

    // If we already have a messageThreadId, we're viewing a specific topic
    if (widget.messageThreadId != null) {
      await _loadTopicHistory();
      return;
    }

    // Check if this chat is a forum supergroup
    try {
      final isForum = await chatService.isChatForum(widget.chatId);
      if (isForum) {
        setState(() => _isForum = true);
        await _loadForumTopics();
        return;
      }
    } catch (e) {
      LogService().debug('TelegramChatPage: forum check failed: $e');
    }

    // Regular chat — load message history
    await _loadHistory();
  }

  Future<void> _computeChatDbSize() async {
    final cache = TelegramService().cacheService;
    if (cache == null) return;
    // Defer to avoid blocking init
    await Future.delayed(Duration.zero);
    if (!mounted) return;
    try {
      final dbFile = File('${cache.cacheDirAbsolutePath}/chat_${widget.chatId}.db');
      final len = await dbFile.length();
      if (mounted) setState(() => _chatDbSize = _formatSize(len));
    } catch (_) {}
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _loadHistory() async {
    final chatService = TelegramService().chatService;
    if (chatService == null) {
      telegramDebug('TelegramChatPage: chatService is null');
      setState(() => _loading = false);
      return;
    }

    // Step 1: Show cached messages instantly
    final cache = TelegramService().cacheService;
    final int cachedCount;
    if (cache != null) {
      final cached = cache.getCachedMessages(widget.chatId);
      cachedCount = cached.length;
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _messages = cached;
          _loading = false;
        });
        _resolveUsers(cached);
        _generateLocationThumbnails(cached);
      }
    } else {
      cachedCount = 0;
    }

    // Step 2: Fetch from TDLib
    try {
      await chatService.openChat(widget.chatId);
      TelegramService().cacheService?.recordVisit(widget.chatId);
      final messages = await chatService.getChatHistory(widget.chatId);
      telegramDebug('TelegramChatPage: got ${messages.length} messages');

      // Stop the spinner immediately — don't block on retries
      if (mounted) {
        setState(() {
          if (messages.isNotEmpty &&
              (cachedCount == 0 || messages.length >= cachedCount)) {
            _messages = messages;
          }
          _loading = false;
        });
        if (messages.isNotEmpty) {
          _markMessagesAsRead(messages);
          _resolveUsers(messages);
          _resolveReplyPreviews(messages);
          _downloadMedia(messages);
          _generateLocationThumbnails(messages);
        }
      }

      // Step 3: If empty, check forum status and/or retry in background
      if (messages.isEmpty) {
        try {
          final isForum = await chatService.isChatForum(widget.chatId);
          if (isForum && mounted) {
            setState(() => _isForum = true);
            await _loadForumTopics();
            return;
          }
        } catch (e) {
          telegramDebug('TelegramChatPage: forum recheck failed: $e');
        }
        _retryLoadHistory();
      }
    } catch (e) {
      telegramError('TelegramChatPage: load history EXCEPTION: $e');
      if (mounted) setState(() => _loading = false);
      // Still attempt background retries after an exception
      _retryLoadHistory();
    }
  }

  /// Background retry loop for when initial getChatHistory returns empty.
  /// Uses longer delays to give TDLib time to sync from the server.
  Future<void> _retryLoadHistory() async {
    final chatService = TelegramService().chatService;
    if (chatService == null) return;

    for (int attempt = 1; attempt <= 5; attempt++) {
      final delay = attempt * 2; // 2s, 4s, 6s, 8s, 10s
      await Future.delayed(Duration(seconds: delay));
      if (!_isActive || !mounted) return;
      // Skip if messages already arrived via events
      if (_messages.isNotEmpty) return;

      telegramDebug('TelegramChatPage: background retry $attempt...');
      final messages = await chatService.getChatHistory(widget.chatId);
      telegramDebug('TelegramChatPage: background retry $attempt got ${messages.length} messages');

      if (messages.isNotEmpty && mounted) {
        setState(() => _messages = messages);
        _resolveUsers(messages);
        _resolveReplyPreviews(messages);
        _downloadMedia(messages);
        _generateLocationThumbnails(messages);
        return;
      }
    }
  }

  Future<void> _loadTopicHistory() async {
    final chatService = TelegramService().chatService;
    if (chatService == null) {
      telegramDebug('TelegramChatPage: chatService is null (topic)');
      setState(() => _loading = false);
      return;
    }

    // Step 1: Show cached messages instantly
    final cache = TelegramService().cacheService;
    final int cachedCount;
    if (cache != null) {
      final cached = cache.getCachedMessages(
        widget.chatId,
        messageThreadId: widget.messageThreadId,
      );
      cachedCount = cached.length;
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _messages = cached;
          _loading = false;
        });
        _resolveUsers(cached);
        _generateLocationThumbnails(cached);
      }
    } else {
      cachedCount = 0;
    }

    // Step 2: Fetch from TDLib
    try {
      await chatService.openChat(widget.chatId);
      TelegramService().cacheService?.recordVisit(widget.chatId);
      final messages = await chatService.getTopicHistory(
        widget.chatId,
        widget.messageThreadId!,
      );
      telegramDebug('TelegramChatPage: topic got ${messages.length} messages');

      // Stop the spinner immediately
      if (mounted) {
        setState(() {
          if (messages.isNotEmpty &&
              (cachedCount == 0 || messages.length >= cachedCount)) {
            _messages = messages;
          }
          _loading = false;
        });
        if (messages.isNotEmpty) {
          _markMessagesAsRead(messages);
          _resolveUsers(messages);
          _resolveReplyPreviews(messages);
          _downloadMedia(messages);
          _generateLocationThumbnails(messages);
        }
      }

      // If empty, retry in the background
      if (messages.isEmpty) {
        _retryLoadTopicHistory();
      }
    } catch (e) {
      telegramError('TelegramChatPage: load topic history EXCEPTION: $e');
      if (mounted) setState(() => _loading = false);
      _retryLoadTopicHistory();
    }
  }

  /// Background retry loop for topic history.
  Future<void> _retryLoadTopicHistory() async {
    final chatService = TelegramService().chatService;
    if (chatService == null || widget.messageThreadId == null) return;

    for (int attempt = 1; attempt <= 5; attempt++) {
      final delay = attempt * 2;
      await Future.delayed(Duration(seconds: delay));
      if (!_isActive || !mounted) return;
      if (_messages.isNotEmpty) return;

      telegramDebug('TelegramChatPage: topic background retry $attempt...');
      final messages = await chatService.getTopicHistory(
        widget.chatId,
        widget.messageThreadId!,
      );
      telegramDebug('TelegramChatPage: topic background retry $attempt got ${messages.length} messages');

      if (messages.isNotEmpty && mounted) {
        setState(() => _messages = messages);
        _resolveUsers(messages);
        _resolveReplyPreviews(messages);
        _downloadMedia(messages);
        _generateLocationThumbnails(messages);
        return;
      }
    }
  }

  /// Mark messages as read in both TDLib and the local SQLite cache.
  void _markMessagesAsRead(List<TelegramMessage> messages) {
    if (messages.isEmpty) return;

    // Mark all messages as read in the local cache
    TelegramService().cacheService?.markAllAsRead(widget.chatId);

    // Tell TDLib the user has seen these messages — clears the server-side
    // unread count and triggers updateChatReadInbox for the in-memory model.
    final chatService = TelegramService().chatService;
    if (chatService == null) return;
    final ids = messages.map((m) => m.id).toList();
    chatService.viewMessages(
      widget.chatId,
      ids,
      messageThreadId: widget.messageThreadId,
    );
  }

  /// Resolve sender user info for messages (throttled to avoid rate limits).
  Future<void> _resolveUsers(List<TelegramMessage> messages) async {
    final chatService = TelegramService().chatService;
    if (chatService == null) return;

    // Collect unique sender IDs we haven't resolved yet
    final ids = <int>{};
    for (final msg in messages) {
      if (msg.senderUserId != 0 && !_userCache.containsKey(msg.senderUserId)) {
        ids.add(msg.senderUserId);
      }
    }
    if (ids.isEmpty) return;

    // Throttle: resolve in batches of 5 with small delays between batches
    final idList = ids.toList();
    for (int i = 0; i < idList.length; i += 5) {
      if (!_isActive || !mounted) break;
      final batch = idList.skip(i).take(5);
      final futures = batch.map((id) async {
        final user = await chatService.getUser(id);
        if (user != null && mounted) {
          setState(() => _userCache[id] = user);
        }
      });
      await Future.wait(futures);
      // Small delay between batches to avoid rate limiting
      if (i + 5 < idList.length) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  /// Resolve reply previews for messages that have replyToMessageId but no sender name.
  Future<void> _resolveReplyPreviews(List<TelegramMessage> messages) async {
    final chatService = TelegramService().chatService;
    if (chatService == null) return;

    for (final msg in messages) {
      if (msg.replyToMessageId == null || msg.replyToSenderName != null) continue;

      // First try to find the target in our current message list
      final target = _messages
          .where((m) => m.id == msg.replyToMessageId)
          .firstOrNull;

      String? senderName;
      String? previewText;

      if (target != null) {
        final user = _userCache[target.senderUserId];
        senderName = user?.displayName ?? target.senderName ?? 'Unknown';
        previewText = target.text;
      } else {
        // Fetch from TDLib
        final fetched = await chatService.getMessage(
            widget.chatId, msg.replyToMessageId!);
        if (fetched != null) {
          // Try to resolve the sender name
          if (fetched.senderUserId != 0) {
            final user = await chatService.getUser(fetched.senderUserId);
            senderName = user?.displayName ?? 'Unknown';
          } else {
            senderName = fetched.senderName ?? 'Unknown';
          }
          previewText = fetched.text;
        }
      }

      if (senderName != null && mounted) {
        final truncated = previewText != null && previewText.length > 100
            ? '${previewText.substring(0, 100)}...'
            : previewText;

        setState(() {
          final idx = _messages.indexWhere((m) => m.id == msg.id);
          if (idx >= 0) {
            _messages[idx] = _messages[idx].copyWith(
              replyToSenderName: senderName,
              replyToText: truncated ?? '',
            );
            // Persist back to cache
            TelegramService().cacheService?.cacheMessage(
                widget.chatId, _messages[idx]);
          }
        });
      }
    }
  }

  /// Download media for messages that have media metadata but no local path
  /// and no in-memory bytes. Throttled: downloads 3 at a time.
  Future<void> _downloadMedia(List<TelegramMessage> messages) async {
    final chatService = TelegramService().chatService;
    if (chatService == null) return;

    final pending = messages
        .where((m) =>
            m.media != null &&
            m.media!.localPath == null &&
            m.media!.mediaBytes == null)
        .toList();

    for (int i = 0; i < pending.length; i += 3) {
      if (!_isActive || !mounted) break;
      final batch = pending.skip(i).take(3);
      final futures = batch.map((msg) async {
        final path = await chatService.downloadFile(msg.media!.fileId);
        if (path != null && mounted) {
          final cache = TelegramService().cacheService;
          final ingested = cache?.ingestMediaBlob(
              msg.chatId, msg.id, path) ?? false;

          setState(() {
            final idx = _messages.indexWhere((m) => m.id == msg.id);
            if (idx >= 0) {
              if (ingested && cache != null) {
                // Re-read from cache — gets mediaBytes for images or
                // localPath for file-path types
                final match = cache.getCachedMessage(msg.chatId, msg.id);
                if (match != null) {
                  _messages[idx] = match;
                  return;
                }
              }
              final updated = _messages[idx].withMediaPath(path);
              _messages[idx] = updated;
              cache?.cacheMessage(msg.chatId, updated);
            }
          });

          // Generate thumbnail in background if missing
          if (ingested) {
            _generateThumbnailInBackground(msg.chatId, msg.id);
          }
        }
      });
      await Future.wait(futures);
      if (i + 3 < pending.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  /// Generate map thumbnails for location/venue messages that have no thumbnail.
  Future<void> _generateLocationThumbnails(List<TelegramMessage> messages) async {
    final cache = TelegramService().cacheService;
    if (cache == null) return;

    final pending = messages.where((m) =>
        (m.contentType == TelegramMessageContentType.location ||
         m.contentType == TelegramMessageContentType.venue) &&
        m.media?.thumbnail == null).toList();

    for (final msg in pending) {
      if (!_isActive || !mounted) break;
      _generateThumbnailInBackground(msg.chatId, msg.id);
    }
  }

  /// Generate thumbnail in background and update the message in the list.
  Future<void> _generateThumbnailInBackground(
      int chatId, int messageId) async {
    try {
      final cache = TelegramService().cacheService;
      if (cache == null) return;
      final thumb = await cache.generateThumbnailIfMissing(chatId, messageId);
      if (thumb != null && mounted) {
        // Re-read the message to pick up the new thumbnail
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == messageId);
          if (idx >= 0) {
            final match = cache.getCachedMessage(chatId, messageId);
            if (match != null) {
              _messages[idx] = match;
            }
          }
        });
      }
    } catch (e) {
      telegramError('TelegramChatPage: _generateThumbnailInBackground error: $e');
    }
  }

  /// Get a file path for a media message, extracting blob on-demand if needed.
  String? _resolveMediaPath(TelegramMessage m) {
    if (m.media?.localPath != null) return m.media!.localPath;
    if (m.media?.mediaBytes != null) {
      // On-demand extraction for gallery/document viewers that need a path
      final cache = TelegramService().cacheService;
      return cache?.extractBlobToFile(m.chatId, m.id);
    }
    return null;
  }

  /// Open full-screen viewer for a media message.
  void _openMedia(TelegramMessage msg) {
    // Documents → DocumentViewerWidget in a Scaffold
    if (msg.contentType == TelegramMessageContentType.document) {
      final path = _resolveMediaPath(msg);
      if (path == null) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(
              title: Text(
                msg.media?.fileName ?? 'Document',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            body: DocumentViewerWidget(filePath: path),
          ),
        ),
      );
      return;
    }

    // Audio → open with system audio player
    if (msg.contentType == TelegramMessageContentType.audio) {
      final path = _resolveMediaPath(msg);
      if (path == null) return;
      FileLauncherService().openFile(path);
      return;
    }

    // Photos, videos, animations, video notes → PhotoViewerPage with gallery swipe
    if (msg.contentType == TelegramMessageContentType.photo ||
        msg.contentType == TelegramMessageContentType.video ||
        msg.contentType == TelegramMessageContentType.animation ||
        msg.contentType == TelegramMessageContentType.videoNote) {
      // Collect all visual media from current messages (has localPath or mediaBytes)
      final visualMedia = _messages
          .where((m) =>
              (m.contentType == TelegramMessageContentType.photo ||
                  m.contentType == TelegramMessageContentType.video ||
                  m.contentType == TelegramMessageContentType.animation ||
                  m.contentType == TelegramMessageContentType.videoNote) &&
              (m.media?.localPath != null || m.media?.mediaBytes != null))
          .toList()
          .reversed // messages are newest-first, gallery should be chronological
          .toList();

      // Resolve paths on-demand (extract blobs only when gallery opens)
      final paths = <String>[];
      int? tappedIdx;
      for (int i = 0; i < visualMedia.length; i++) {
        final m = visualMedia[i];
        final path = _resolveMediaPath(m);
        if (path != null) {
          if (m.id == msg.id) tappedIdx = paths.length;
          paths.add(path);
        }
      }

      if (paths.isEmpty) return;

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PhotoViewerPage(
            imagePaths: paths,
            initialIndex: tappedIdx ?? 0,
          ),
        ),
      );
    }
  }

  Future<void> _loadForumTopics() async {
    final chatService = TelegramService().chatService;
    if (chatService == null) {
      setState(() => _loading = false);
      return;
    }

    try {
      await chatService.openChat(widget.chatId);
      final topics = await chatService.getForumTopics(widget.chatId);
      telegramDebug(
          'TelegramChatPage: forum topics initial count=${topics.length}');

      // Phase 1: Load cached topic photos instantly (offline)
      final cache = TelegramService().cacheService;
      if (cache != null) {
        _topicPhotos = cache.getAllTopicPhotos(widget.chatId);
      }

      if (mounted) {
        setState(() {
          _topics = topics;
          _loading = false;
        });
      }

      // Phase 2: Download missing custom emoji icons (async, online)
      final needsDownload = topics
          .where((t) => t.iconCustomEmojiId != 0 &&
              !_topicPhotos.containsKey(t.messageThreadId))
          .toList();
      if (needsDownload.isNotEmpty) {
        final downloaded = await chatService.downloadTopicIcons(
            widget.chatId, needsDownload);
        if (downloaded.isNotEmpty && mounted) {
          setState(() { _topicPhotos.addAll(downloaded); });
        }
      }

      if (topics.isEmpty) {
        _retryLoadForumTopics();
      }
    } catch (e) {
      LogService().error('TelegramChatPage: failed to load forum topics: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _retryLoadForumTopics() async {
    final chatService = TelegramService().chatService;
    if (chatService == null) return;

    for (int attempt = 1; attempt <= 4; attempt++) {
      final delay = attempt * 2;
      await Future.delayed(Duration(seconds: delay));
      if (!_isActive || !mounted) return;
      if (_topics.isNotEmpty) return;

      telegramDebug('TelegramChatPage: forum retry $attempt...');
      final topics = await chatService.getForumTopics(widget.chatId);
      telegramDebug(
          'TelegramChatPage: forum retry $attempt count=${topics.length}');

      if (topics.isNotEmpty && mounted) {
        setState(() {
          _topics = topics;
        });

        // Download missing custom emoji icons on retry
        final needsDownload = topics
            .where((t) => t.iconCustomEmojiId != 0 &&
                !_topicPhotos.containsKey(t.messageThreadId))
            .toList();
        if (needsDownload.isNotEmpty) {
          final downloaded = await chatService.downloadTopicIcons(
              widget.chatId, needsDownload);
          if (downloaded.isNotEmpty && mounted) {
            setState(() { _topicPhotos.addAll(downloaded); });
          }
        }
        return;
      }
    }
  }

  void _listenForNewMessages() {
    _eventSub = TelegramService().events.listen((event) {
      switch (event.type) {
        case TelegramEventType.newMessage:
          final msg = event.data as TelegramMessage;
          if (msg.chatId == widget.chatId) {
            setState(() {
              _messages.insert(0, msg);
            });
            // Only resolve users / download media when this chat is active
            if (_isActive) {
              // Mark the incoming message as read immediately since the
              // user is actively viewing this chat
              _markMessagesAsRead([msg]);
              if (msg.senderUserId != 0 &&
                  !_userCache.containsKey(msg.senderUserId)) {
                _resolveUsers([msg]);
              }
              if (msg.replyToMessageId != null && msg.replyToSenderName == null) {
                _resolveReplyPreviews([msg]);
              }
              if (msg.media != null && msg.media!.localPath == null) {
                _downloadMedia([msg]);
              }
              if (msg.contentType == TelegramMessageContentType.location ||
                  msg.contentType == TelegramMessageContentType.venue) {
                _generateLocationThumbnails([msg]);
              }
            }
          }
          break;

        case TelegramEventType.messageEdited:
          final data = event.data as Map<String, dynamic>;
          final chatId = data['chat_id'] as int;
          final messageId = data['message_id'] as int;
          final editDate = data['edit_date'] as int;
          if (chatId == widget.chatId && mounted) {
            setState(() {
              final idx = _messages.indexWhere((m) => m.id == messageId);
              if (idx >= 0) {
                _messages[idx] = _messages[idx].copyWith(editDate: editDate);
              }
            });
          }
          break;

        case TelegramEventType.messagesDeleted:
          final data = event.data as Map<String, dynamic>;
          final chatId = data['chat_id'] as int;
          final messageIds = (data['message_ids'] as List<int>).toSet();
          if (chatId == widget.chatId && mounted) {
            setState(() {
              _messages.removeWhere((m) => messageIds.contains(m.id));
            });
          }
          break;

        case TelegramEventType.reactionsUpdated:
          final data = event.data as Map<String, dynamic>;
          final chatId = data['chat_id'] as int;
          final messageId = data['message_id'] as int;
          final reactions = data['reactions'] as List<TelegramReaction>;
          if (chatId == widget.chatId && mounted) {
            setState(() {
              final idx = _messages.indexWhere((m) => m.id == messageId);
              if (idx >= 0) {
                _messages[idx] = _messages[idx].copyWith(reactions: reactions);
                // Persist updated reactions to cache
                TelegramService().cacheService?.cacheMessage(
                    widget.chatId, _messages[idx]);
              }
            });
          }
          break;

        case TelegramEventType.typingUpdate:
          final data = event.data as Map<String, dynamic>;
          final chatId = data['chat_id'] as int;
          final userId = data['user_id'] as int;
          final action = data['action'] as String;
          if (chatId == widget.chatId && mounted) {
            if (action == 'chatActionCancel' || action.isEmpty) {
              setState(() => _typingUsers.remove(userId));
            } else {
              final user = _userCache[userId];
              final name = user?.displayName ?? 'Someone';
              setState(() => _typingUsers[userId] = name);
              // Auto-clear after 5 seconds
              _typingClearTimer?.cancel();
              _typingClearTimer = Timer(const Duration(seconds: 5), () {
                if (mounted) {
                  setState(() => _typingUsers.remove(userId));
                }
              });
            }
          }
          break;

        default:
          break;
      }
    });
  }

  /// Trigger older message loading when scrolled near the top (maxScrollExtent
  /// in a reverse list).
  void _onScroll() {
    if (_loadingOlder || !_hasMoreMessages || _messages.isEmpty) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      _loadOlderMessages();
    }
  }

  /// Load older messages using a cache-first strategy.
  Future<void> _loadOlderMessages() async {
    if (_loadingOlder || !_hasMoreMessages || _messages.isEmpty) return;
    setState(() => _loadingOlder = true);

    try {
      final oldestMsg = _messages.last;
      final oldestDateMs = oldestMsg.date.millisecondsSinceEpoch;
      final cache = TelegramService().cacheService;

      // Step 1: Try cache first
      List<TelegramMessage> older = [];
      if (cache != null) {
        older = cache.getOlderCachedMessages(
          widget.chatId,
          beforeDateMs: oldestDateMs,
          messageThreadId: widget.messageThreadId,
        );
      }

      if (older.isNotEmpty) {
        // Cache hit — append and resolve
        if (mounted) {
          setState(() => _messages.addAll(older));
          _resolveUsers(older);
          _resolveReplyPreviews(older);
          _downloadMedia(older);
          _generateLocationThumbnails(older);
        }
      } else {
        // Step 2: Cache exhausted — fetch from TDLib
        final chatService = TelegramService().chatService;
        if (chatService != null) {
          final List<TelegramMessage> fetched;
          if (widget.messageThreadId != null) {
            fetched = await chatService.getTopicHistory(
              widget.chatId,
              widget.messageThreadId!,
              fromMessageId: oldestMsg.id,
            );
          } else {
            fetched = await chatService.getChatHistory(
              widget.chatId,
              fromMessageId: oldestMsg.id,
            );
          }

          if (fetched.isEmpty) {
            if (mounted) setState(() => _hasMoreMessages = false);
          } else if (mounted) {
            setState(() => _messages.addAll(fetched));
            _resolveUsers(fetched);
            _resolveReplyPreviews(fetched);
            _downloadMedia(fetched);
            _generateLocationThumbnails(fetched);
          }
        }
      }
    } catch (e) {
      telegramError('TelegramChatPage: _loadOlderMessages error: $e');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    final chatService = TelegramService().chatService;
    if (chatService == null) return;

    final replyId = _replyTarget?.id;

    setState(() {
      _sending = true;
      _replyTarget = null;
    });
    _inputController.clear();

    try {
      await chatService.sendMessage(
        widget.chatId,
        text,
        messageThreadId: widget.messageThreadId,
        replyToMessageId: replyId,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _inputFocusNode.requestFocus();
      }
    }
  }

  /// Delete a message after user confirmation.
  Future<void> _deleteMessage(TelegramMessage msg) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete message'),
        content: const Text('Are you sure you want to delete this message?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final chatService = TelegramService().chatService;
    if (chatService == null) return;

    final ok = await chatService.deleteMessages(widget.chatId, [msg.id]);
    if (ok && mounted) {
      setState(() {
        _messages.removeWhere((m) => m.id == msg.id);
      });
    }
  }

  @override
  void deactivate() {
    _isActive = false;
    super.deactivate();
  }

  @override
  void dispose() {
    _isActive = false;
    _scrollController.removeListener(_onScroll);
    _eventSub?.cancel();
    _typingClearTimer?.cancel();
    _highlightTimer?.cancel();
    _messageKeys.clear();
    TelegramService().chatService?.closeChat(widget.chatId);
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.topicName ?? widget.chatTitle;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            if (_chatDbSize != null)
              Text(
                _chatDbSize!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _isForum && widget.messageThreadId == null
              ? _buildForumTopicList()
              : _buildMessageView(),
    );
  }

  Widget _buildForumTopicList() {
    final theme = Theme.of(context);

    if (_topics.isEmpty) {
      return Center(
        child: Text(
          'No topics yet',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: _topics.length,
      itemBuilder: (context, index) {
        final topic = _topics[index];
        return _buildTopicTile(topic, theme);
      },
    );
  }

  Widget _buildTopicTile(TelegramForumTopic topic, ThemeData theme) {
    final cachedPhoto = topic.photoBytes ?? _topicPhotos[topic.messageThreadId];
    final iconColorValue = topic.iconColor != 0
        ? Color(topic.iconColor | 0xFF000000)
        : const Color(0xFF0088CC);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: ListTile(
      leading: cachedPhoto != null
          ? CircleAvatar(backgroundImage: MemoryImage(cachedPhoto))
          : CircleAvatar(
              backgroundColor: iconColorValue.withValues(alpha: 0.15),
              child: Icon(
                topic.isGeneral ? Icons.forum : Icons.tag,
                color: iconColorValue,
                size: 20,
              ),
            ),
      title: Text(
        topic.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight:
              topic.unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: topic.lastMessageText != null
          ? Text(
              topic.lastMessageText!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      trailing: topic.unreadCount > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF0088CC),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                topic.unreadCount > 99 ? '99+' : '${topic.unreadCount}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : null,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TelegramChatPage(
              chatId: widget.chatId,
              chatTitle: widget.chatTitle,
              messageThreadId: topic.messageThreadId,
              topicName: topic.name,
            ),
          ),
        );
      },
    ),
    );
  }

  // ---------- Message list with day separators ----------

  /// Check if two dates (UTC) fall on different local calendar days.
  bool _isDifferentDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year != lb.year || la.month != lb.month || la.day != lb.day;
  }

  /// Whether to show the avatar for a message at [index].
  ///
  /// The list is reversed (newest first), so the "next" message visually
  /// (below the current one) is at index - 1.
  bool _shouldShowAvatar(int index) {
    final msg = _messages[index];
    if (msg.isOutgoing) return false;
    // Show avatar if this is the last message in a visual group from this sender
    if (index == 0) return true; // bottom of the list
    final prev = _messages[index - 1]; // message displayed below
    return prev.senderUserId != msg.senderUserId || prev.isOutgoing;
  }

  /// Build the typing indicator bar.
  Widget _buildTypingIndicator(ThemeData theme) {
    if (_typingUsers.isEmpty) return const SizedBox.shrink();

    final names = _typingUsers.values.toList();
    final String label;
    if (names.length == 1) {
      label = '${names[0]} is typing...';
    } else {
      label = '${names.join(", ")} are typing...';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// Build the reply compose bar shown above the input.
  Widget _buildReplyBar(ThemeData theme) {
    if (_replyTarget == null) return const SizedBox.shrink();

    final target = _replyTarget!;
    final user = _userCache[target.senderUserId];
    final senderName = target.isOutgoing
        ? 'You'
        : (user?.displayName ?? target.senderName ?? 'Unknown');
    final previewText = target.text ?? '';

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(
          left: BorderSide(
            color: const Color(0xFF0088CC),
            width: 3,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  senderName,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: const Color(0xFF0088CC),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (previewText.isNotEmpty)
                  Text(
                    previewText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _replyTarget = null),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageView() {
    final theme = Theme.of(context);

    return Column(
      children: [
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Text(
                    'No messages yet',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _messages.length + (_hasMoreMessages ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _messages.length) {
                      // Loading indicator at the top (oldest end)
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    return _buildMessageItem(index);
                  },
                ),
        ),
        // Typing indicator
        _buildTypingIndicator(theme),
        // Reply compose bar
        _buildReplyBar(theme),
        // Input bar
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputController,
                  focusNode: _inputFocusNode,
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(24)),
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _sending ? null : _sendMessage,
                icon: _sending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                color: const Color(0xFF0088CC),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// React to a message with an emoji.
  Future<void> _reactToMessage(TelegramMessage msg, String emoji) async {
    final chatService = TelegramService().chatService;
    if (chatService == null) return;

    // Optimistic local update — show the reaction immediately
    setState(() {
      final idx = _messages.indexWhere((m) => m.id == msg.id);
      if (idx >= 0) {
        final existing = _messages[idx].reactions;
        final reactionIdx = existing.indexWhere((r) => r.emoji == emoji);
        List<TelegramReaction> updated;
        if (reactionIdx >= 0) {
          // Toggle: if already chosen, remove our count; otherwise mark chosen
          final r = existing[reactionIdx];
          if (r.isChosen) {
            updated = List.of(existing);
            if (r.count <= 1) {
              updated.removeAt(reactionIdx);
            } else {
              updated[reactionIdx] = TelegramReaction(
                  emoji: emoji, count: r.count - 1, isChosen: false);
            }
          } else {
            updated = List.of(existing);
            updated[reactionIdx] = TelegramReaction(
                emoji: emoji, count: r.count + 1, isChosen: true);
          }
        } else {
          updated = [
            ...existing,
            TelegramReaction(emoji: emoji, count: 1, isChosen: true),
          ];
        }
        _messages[idx] = _messages[idx].copyWith(reactions: updated);
      }
    });

    final ok = await chatService.addMessageReaction(widget.chatId, msg.id, emoji);
    telegramDebug('TelegramChat: addMessageReaction($emoji) -> $ok');
  }

  /// Scroll to and highlight a message by its ID (used when tapping reply previews).
  void _scrollToMessage(int messageId) {
    // Find the target index in the loaded message list
    var targetIndex = _messages.indexWhere((m) => m.id == messageId);

    if (targetIndex < 0) {
      // Message not in the loaded list — try loading from cache
      final cache = TelegramService().cacheService;
      if (cache != null) {
        final cached = cache.getCachedMessage(widget.chatId, messageId);
        if (cached != null) {
          // Insert at the correct chronological position (list is newest-first)
          int insertAt = _messages.length;
          for (int i = 0; i < _messages.length; i++) {
            if (_messages[i].date.isBefore(cached.date) ||
                (_messages[i].date == cached.date && _messages[i].id < cached.id)) {
              insertAt = i;
              break;
            }
          }
          setState(() => _messages.insert(insertAt, cached));
          targetIndex = insertAt;
          _resolveUsers([cached]);
          _resolveReplyPreviews([cached]);
        }
      }
    }

    if (targetIndex < 0) return; // Could not find the message

    // Set highlight
    _highlightTimer?.cancel();
    setState(() => _highlightMessageId = messageId);
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightMessageId = null);
    });

    // Try ensureVisible with GlobalKey first
    final key = _messageKeys[messageId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        alignment: 0.5,
        duration: const Duration(milliseconds: 300),
      );
      return;
    }

    // Fallback: estimate scroll offset based on index (reverse list)
    final estimatedOffset = targetIndex * 72.0;
    _scrollController.animateTo(
      estimatedOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    ).then((_) {
      // After scrolling, try ensureVisible once the widget is built
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final k = _messageKeys[messageId];
        if (k?.currentContext != null) {
          Scrollable.ensureVisible(
            k!.currentContext!,
            alignment: 0.5,
            duration: const Duration(milliseconds: 200),
          );
        }
      });
    });
  }

  /// Build a single message row, possibly preceded by a day separator.
  Widget _buildMessageItem(int index) {
    final msg = _messages[index];
    final user = _userCache[msg.senderUserId];

    // Service messages (call, pinMessage) → centered pill, not a bubble
    if (msg.contentType == TelegramMessageContentType.call ||
        msg.contentType == TelegramMessageContentType.pinMessage) {
      final serviceWidget = TelegramServiceMessage(
        message: msg,
        senderName: user?.displayName,
      );

      final bool showSeparator;
      if (index == _messages.length - 1) {
        showSeparator = true;
      } else {
        final older = _messages[index + 1];
        showSeparator = _isDifferentDay(msg.date, older.date);
      }

      if (showSeparator) {
        return Column(
          children: [
            TelegramDateSeparator(date: msg.date),
            serviceWidget,
          ],
        );
      }
      return serviceWidget;
    }

    // Assign a GlobalKey for scroll-to-message
    _messageKeys[msg.id] ??= GlobalKey();
    final msgKey = _messageKeys[msg.id]!;
    final isHighlighted = msg.id == _highlightMessageId;

    final bubble = TelegramMessageBubble(
      message: msg,
      senderName: msg.isOutgoing ? null : user?.displayName,
      senderPhotoPath: user?.profilePhotoPath,
      showAvatar: _shouldShowAvatar(index),
      onMediaTap: (msg.media?.localPath != null || msg.media?.mediaBytes != null)
          ? () => _openMedia(msg)
          : null,
      onReply: (m) => setState(() => _replyTarget = m),
      onDelete: _deleteMessage,
      onReact: _reactToMessage,
      onReplyPreviewTap: _scrollToMessage,
      onDownloadVoice: (m) async {
        final chatService = TelegramService().chatService;
        if (chatService == null || m.media == null) return null;
        final path = await chatService.downloadFile(m.media!.fileId);
        if (path != null && mounted) {
          final cache = TelegramService().cacheService;
          final ingested = cache?.ingestMediaBlob(
              m.chatId, m.id, path) ?? false;

          String? effectivePath = path;
          if (ingested && cache != null) {
            // Re-read from cache — voice notes are file-path types,
            // so _rowToMessage extracts to extracted/ dir
            final match = cache.getCachedMessage(m.chatId, m.id);
            if (match?.media?.localPath != null) {
              effectivePath = match!.media!.localPath;
            }
          }

          setState(() {
            final idx = _messages.indexWhere((x) => x.id == m.id);
            if (idx >= 0) {
              final updated = _messages[idx].withMediaPath(effectivePath!);
              _messages[idx] = updated;
              if (!ingested) {
                cache?.cacheMessage(m.chatId, updated);
              }
            }
          });
          return effectivePath;
        }
        return path;
      },
    );

    // Wrap bubble with key and highlight effect
    final wrappedBubble = AnimatedContainer(
      key: msgKey,
      duration: const Duration(milliseconds: 500),
      color: isHighlighted ? const Color(0x302B5278) : Colors.transparent,
      child: bubble,
    );

    // Day separator: show above a message when the message above it
    // (next index, since list is reversed) is on a different day, or
    // this is the oldest message (top of the visual list).
    final bool showSeparator;
    if (index == _messages.length - 1) {
      showSeparator = true; // oldest message always gets a separator
    } else {
      final older = _messages[index + 1];
      showSeparator = _isDifferentDay(msg.date, older.date);
    }

    if (showSeparator) {
      return Column(
        children: [
          TelegramDateSeparator(date: msg.date),
          wrappedBubble,
        ],
      );
    }

    return wrappedBubble;
  }
}
