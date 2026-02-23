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

import 'package:flutter/material.dart';

import '../../../pages/document_viewer_editor_page.dart';
import '../../../pages/photo_viewer_page.dart';
import '../../../services/log_service.dart';
import '../models/telegram_forum_topic.dart';
import '../models/telegram_message.dart';
import '../models/telegram_user.dart';
import '../telegram_service.dart';
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
  StreamSubscription<TelegramEvent>? _eventSub;
  List<TelegramMessage> _messages = [];
  List<TelegramForumTopic> _topics = [];
  bool _loading = true;
  bool _sending = false;
  bool _isForum = false;

  /// Cached user info keyed by userId, resolved progressively.
  final Map<int, TelegramUser> _userCache = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
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

  Future<void> _loadHistory() async {
    final chatService = TelegramService().chatService;
    if (chatService == null) {
      stderr.writeln('TelegramChatPage: chatService is null');
      setState(() => _loading = false);
      return;
    }

    // Step 1: Show cached messages instantly
    final cache = TelegramService().cacheService;
    if (cache != null) {
      final cached = cache.getCachedMessages(widget.chatId);
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _messages = cached;
          _loading = false;
        });
        _resolveUsers(cached);
      }
    }

    // Step 2: Fetch from TDLib in background
    try {
      await chatService.openChat(widget.chatId);
      var messages = await chatService.getChatHistory(widget.chatId);
      stderr.writeln('TelegramChatPage: got ${messages.length} messages');

      // Retry once if empty — TDLib may still be syncing
      if (messages.isEmpty) {
        stderr.writeln('TelegramChatPage: retrying after 1s...');
        await Future.delayed(const Duration(seconds: 1));
        messages = await chatService.getChatHistory(widget.chatId);
        stderr.writeln('TelegramChatPage: retry got ${messages.length} messages');
      }

      // Step 3: Update UI with fresh data
      if (mounted && messages.isNotEmpty) {
        setState(() {
          _messages = messages;
          _loading = false;
        });
        _resolveUsers(messages);
        _downloadMedia(messages);
      }
    } catch (e) {
      stderr.writeln('TelegramChatPage: load history EXCEPTION: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadTopicHistory() async {
    final chatService = TelegramService().chatService;
    if (chatService == null) {
      stderr.writeln('TelegramChatPage: chatService is null (topic)');
      setState(() => _loading = false);
      return;
    }

    // Step 1: Show cached messages instantly
    final cache = TelegramService().cacheService;
    if (cache != null) {
      final cached = cache.getCachedMessages(
        widget.chatId,
        messageThreadId: widget.messageThreadId,
      );
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _messages = cached;
          _loading = false;
        });
        _resolveUsers(cached);
      }
    }

    // Step 2: Fetch from TDLib in background
    try {
      await chatService.openChat(widget.chatId);
      var messages = await chatService.getTopicHistory(
        widget.chatId,
        widget.messageThreadId!,
      );
      stderr.writeln('TelegramChatPage: topic got ${messages.length} messages');

      // Retry once if empty
      if (messages.isEmpty) {
        stderr.writeln('TelegramChatPage: topic retrying after 1s...');
        await Future.delayed(const Duration(seconds: 1));
        messages = await chatService.getTopicHistory(
          widget.chatId,
          widget.messageThreadId!,
        );
        stderr.writeln('TelegramChatPage: topic retry got ${messages.length} messages');
      }

      // Step 3: Update UI with fresh data
      if (mounted && messages.isNotEmpty) {
        setState(() {
          _messages = messages;
          _loading = false;
        });
        _resolveUsers(messages);
        _downloadMedia(messages);
      }
    } catch (e) {
      stderr.writeln('TelegramChatPage: load topic history EXCEPTION: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Resolve sender user info for messages.
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

    for (final id in ids) {
      final user = await chatService.getUser(id);
      if (user != null && mounted) {
        setState(() => _userCache[id] = user);
      }
    }
  }

  /// Download media for messages that have media metadata but no local path.
  Future<void> _downloadMedia(List<TelegramMessage> messages) async {
    final chatService = TelegramService().chatService;
    if (chatService == null) return;

    for (final msg in messages) {
      if (msg.media == null || msg.media!.localPath != null) continue;

      final path = await chatService.downloadFile(msg.media!.fileId);
      if (path != null && mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == msg.id);
          if (idx >= 0) {
            final updated = _messages[idx].withMediaPath(path);
            _messages[idx] = updated;
            // Persist media path back to SQLite cache
            TelegramService().cacheService?.cacheMessage(msg.chatId, updated);
          }
        });
      }
    }
  }

  /// Open full-screen viewer for a media message.
  void _openMedia(TelegramMessage msg) {
    final path = msg.media?.localPath;
    if (path == null) return;

    // Documents → DocumentViewerWidget in a Scaffold
    if (msg.contentType == TelegramMessageContentType.document) {
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

    // Photos, videos, animations → PhotoViewerPage with gallery swipe
    if (msg.contentType == TelegramMessageContentType.photo ||
        msg.contentType == TelegramMessageContentType.video ||
        msg.contentType == TelegramMessageContentType.animation) {
      // Collect all visual media paths from current messages
      final visualMedia = _messages
          .where((m) =>
              (m.contentType == TelegramMessageContentType.photo ||
                  m.contentType == TelegramMessageContentType.video ||
                  m.contentType == TelegramMessageContentType.animation) &&
              m.media?.localPath != null)
          .toList()
          .reversed // messages are newest-first, gallery should be chronological
          .toList();

      final paths = visualMedia.map((m) => m.media!.localPath!).toList();
      final idx = visualMedia.indexWhere((m) => m.id == msg.id);

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PhotoViewerPage(
            imagePaths: paths,
            initialIndex: idx >= 0 ? idx : 0,
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
      final topics = await chatService.getForumTopics(widget.chatId);
      setState(() {
        _topics = topics;
        _loading = false;
      });
    } catch (e) {
      LogService().error('TelegramChatPage: failed to load forum topics: $e');
      setState(() => _loading = false);
    }
  }

  void _listenForNewMessages() {
    _eventSub = TelegramService().events.listen((event) {
      if (event.type == TelegramEventType.newMessage) {
        final msg = event.data as TelegramMessage;
        if (msg.chatId == widget.chatId) {
          setState(() {
            _messages.insert(0, msg);
          });
          // Resolve user for new message
          if (msg.senderUserId != 0 &&
              !_userCache.containsKey(msg.senderUserId)) {
            _resolveUsers([msg]);
          }
          // Download media if needed
          if (msg.media != null && msg.media!.localPath == null) {
            _downloadMedia([msg]);
          }
        }
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    final chatService = TelegramService().chatService;
    if (chatService == null) return;

    setState(() => _sending = true);
    _inputController.clear();

    try {
      await chatService.sendMessage(
        widget.chatId,
        text,
        messageThreadId: widget.messageThreadId,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    TelegramService().chatService?.closeChat(widget.chatId);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.topicName ?? widget.chatTitle;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
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
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF0088CC).withValues(alpha: 0.15),
        child: Icon(
          topic.isGeneral ? Icons.forum : Icons.tag,
          color: const Color(0xFF0088CC),
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
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    return _buildMessageItem(index);
                  },
                ),
        ),
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

  /// Build a single message row, possibly preceded by a day separator.
  Widget _buildMessageItem(int index) {
    final msg = _messages[index];
    final user = _userCache[msg.senderUserId];

    final bubble = TelegramMessageBubble(
      message: msg,
      senderName: msg.isOutgoing ? null : user?.displayName,
      senderPhotoPath: user?.profilePhotoPath,
      showAvatar: _shouldShowAvatar(index),
      onMediaTap: msg.media?.localPath != null ? () => _openMedia(msg) : null,
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
          bubble,
        ],
      );
    }

    return bubble;
  }
}
