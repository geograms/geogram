/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Signal chat view page — message list + text input for a single conversation.
 *
 * Features:
 *   - Cache-first loading (instant from SQLite, then bridge refresh)
 *   - Day separators between message groups
 *   - Sender name resolution via contacts
 *   - Telegram dark-mode bubble styling (outgoing #2B5278, incoming #1E2D3D)
 *   - Inline reply/quote preview
 *   - Reactions
 *   - Infinite scroll for older messages
 *
 * No forum/topic support (Signal does not have this concept).
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/signal_chat.dart';
import '../models/signal_message.dart';
import '../models/signal_user.dart';
import '../signal_cache_service.dart';
import '../signal_service.dart';
import '../widgets/signal_message_bubble.dart';

class SignalChatPage extends StatefulWidget {
  final String conversationId;
  final String chatTitle;
  final SignalChatType chatType;

  const SignalChatPage({
    super.key,
    required this.conversationId,
    required this.chatTitle,
    this.chatType = SignalChatType.direct,
  });

  @override
  State<SignalChatPage> createState() => _SignalChatPageState();
}

class _SignalChatPageState extends State<SignalChatPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();
  StreamSubscription<SignalEvent>? _eventSub;
  List<SignalMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  bool _loadingOlder = false;
  bool _hasMoreMessages = true;

  /// Message being replied to (shown in reply compose bar).
  SignalMessage? _replyTarget;

  /// Message timestamp to briefly highlight after scrolling to it.
  int? _highlightTimestamp;
  Timer? _highlightTimer;

  /// GlobalKeys per message primaryKey for ensureVisible scrolling.
  final Map<String, GlobalKey> _messageKeys = {};

  /// Whether this chat page is the active (visible) route.
  bool _isActive = true;

  /// Per-conversation DB file size label.
  String? _chatDbSize;

  /// Currently typing users: senderUuid -> display name.
  final Map<String, String> _typingUsers = {};
  Timer? _typingClearTimer;

  /// Cached user info keyed by UUID, resolved progressively.
  final Map<String, SignalUser> _userCache = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _init();
  }

  Future<void> _init() async {
    _isActive = true;
    _computeChatDbSize();
    final chatService = SignalService().chatService;
    if (chatService == null) {
      setState(() => _loading = false);
      return;
    }

    _listenForNewMessages();
    await _loadHistory();
  }

  Future<void> _computeChatDbSize() async {
    final cache = SignalService().cacheService;
    if (cache == null) return;
    await Future.delayed(Duration.zero);
    if (!mounted) return;
    try {
      final dbFile = File(
          '${cache.cacheDirAbsolutePath}/${SignalCacheService.dbFilename(widget.conversationId)}');
      final len = await dbFile.length();
      if (mounted) setState(() => _chatDbSize = _formatSize(len));
    } catch (_) {}
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _loadHistory() async {
    final chatService = SignalService().chatService;
    if (chatService == null) {
      stderr.writeln('SignalChatPage: chatService is null');
      setState(() => _loading = false);
      return;
    }

    // Step 1: Show cached messages instantly
    final cache = SignalService().cacheService;
    if (cache != null) {
      final cached = cache.getCachedMessages(widget.conversationId);
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _messages = cached;
          _loading = false;
        });
        _resolveUsers(cached);
      }
    }

    // Step 2: Fetch from Signal bridge
    try {
      SignalService().cacheService?.recordVisit(widget.conversationId);
      final messages =
          await chatService.getMessages(widget.conversationId);
      stderr.writeln(
          'SignalChatPage: got ${messages.length} messages');

      if (mounted) {
        setState(() {
          if (messages.isNotEmpty) _messages = messages;
          _loading = false;
        });
        if (messages.isNotEmpty) {
          _markMessagesAsRead();
          _resolveUsers(messages);
        }
      }

      // Step 3: If empty, retry in background
      if (messages.isEmpty) {
        _retryLoadHistory();
      }
    } catch (e) {
      stderr.writeln('SignalChatPage: load history EXCEPTION: $e');
      if (mounted) setState(() => _loading = false);
      _retryLoadHistory();
    }
  }

  /// Background retry loop when initial getMessages returns empty.
  Future<void> _retryLoadHistory() async {
    final chatService = SignalService().chatService;
    if (chatService == null) return;

    for (int attempt = 1; attempt <= 5; attempt++) {
      final delay = attempt * 2;
      await Future.delayed(Duration(seconds: delay));
      if (!_isActive || !mounted) return;
      if (_messages.isNotEmpty) return;

      stderr.writeln('SignalChatPage: background retry $attempt...');
      final messages =
          await chatService.getMessages(widget.conversationId);
      stderr
          .writeln('SignalChatPage: retry $attempt got ${messages.length} messages');

      if (messages.isNotEmpty && mounted) {
        setState(() => _messages = messages);
        _resolveUsers(messages);
        return;
      }
    }
  }

  /// Mark messages as read in the local cache.
  void _markMessagesAsRead() {
    SignalService().cacheService?.markAllAsRead(widget.conversationId);
  }

  /// Resolve sender user info for messages.
  Future<void> _resolveUsers(List<SignalMessage> messages) async {
    final chatService = SignalService().chatService;
    if (chatService == null) return;

    final uuids = <String>{};
    for (final msg in messages) {
      if (msg.senderUuid.isNotEmpty &&
          !_userCache.containsKey(msg.senderUuid)) {
        uuids.add(msg.senderUuid);
      }
    }
    if (uuids.isEmpty) return;

    final uuidList = uuids.toList();
    for (int i = 0; i < uuidList.length; i += 5) {
      if (!_isActive || !mounted) break;
      final batch = uuidList.skip(i).take(5);
      final futures = batch.map((uuid) async {
        final user = await chatService.getContact(uuid);
        if (user != null && mounted) {
          setState(() => _userCache[uuid] = user);
        }
      });
      await Future.wait(futures);
      if (i + 5 < uuidList.length) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  void _listenForNewMessages() {
    _eventSub = SignalService().events.listen((event) {
      switch (event.type) {
        case SignalEventType.newMessage:
          final msg = event.data as SignalMessage;
          // Determine which conversation this message belongs to
          final convId = msg.groupKey ?? msg.senderUuid;
          if (convId == widget.conversationId) {
            setState(() {
              _messages.insert(0, msg);
            });
            if (_isActive) {
              _markMessagesAsRead();
              if (msg.senderUuid.isNotEmpty &&
                  !_userCache.containsKey(msg.senderUuid)) {
                _resolveUsers([msg]);
              }
            }
          }
          break;

        case SignalEventType.typingUpdate:
          final data = event.data as Map<String, dynamic>;
          final convId = data['conversation_id'] as String;
          final senderUuid = data['sender_uuid'] as String;
          final isTyping = data['is_typing'] as bool;
          if (convId == widget.conversationId && mounted) {
            if (!isTyping) {
              setState(() => _typingUsers.remove(senderUuid));
            } else {
              final user = _userCache[senderUuid];
              final name = user?.name ?? 'Someone';
              setState(() => _typingUsers[senderUuid] = name);
              _typingClearTimer?.cancel();
              _typingClearTimer = Timer(const Duration(seconds: 5), () {
                if (mounted) {
                  setState(() => _typingUsers.remove(senderUuid));
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

  /// Trigger older message loading when scrolled near the top.
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
      final cache = SignalService().cacheService;

      // Step 1: Try cache first
      List<SignalMessage> older = [];
      if (cache != null) {
        older = cache.getOlderCachedMessages(
          widget.conversationId,
          beforeTimestamp: oldestMsg.timestamp,
        );
      }

      if (older.isNotEmpty) {
        if (mounted) {
          setState(() => _messages.addAll(older));
          _resolveUsers(older);
        }
      } else {
        // Step 2: Cache exhausted — fetch from Signal bridge
        final chatService = SignalService().chatService;
        if (chatService != null) {
          final fetched = await chatService.getMessages(
            widget.conversationId,
            beforeTimestamp: oldestMsg.timestamp,
          );

          if (fetched.isEmpty) {
            if (mounted) setState(() => _hasMoreMessages = false);
          } else if (mounted) {
            setState(() => _messages.addAll(fetched));
            _resolveUsers(fetched);
          }
        }
      }
    } catch (e) {
      stderr.writeln('SignalChatPage: _loadOlderMessages error: $e');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    final chatService = SignalService().chatService;
    if (chatService == null) return;

    final quoteTimestamp = _replyTarget?.timestamp;

    setState(() {
      _sending = true;
      _replyTarget = null;
    });
    _inputController.clear();

    try {
      final sent = await chatService.sendMessage(
        widget.conversationId,
        text,
        quoteTimestamp: quoteTimestamp,
      );
      // Local echo: insert the sent message at the top of the list
      if (sent != null && mounted) {
        final isDuplicate =
            _messages.any((m) => m.primaryKey == sent.primaryKey);
        if (!isDuplicate) {
          setState(() => _messages.insert(0, sent));
        }
      }
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

  /// React to a message with an emoji.
  Future<void> _reactToMessage(SignalMessage msg, String emoji) async {
    final chatService = SignalService().chatService;
    if (chatService == null) return;

    // Optimistic local update
    setState(() {
      final idx = _messages.indexWhere((m) => m.primaryKey == msg.primaryKey);
      if (idx >= 0) {
        final existing = _messages[idx].reactions;
        final updated = [
          ...existing,
          SignalReaction(
            emoji: emoji,
            senderUuid: '', // local user
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ),
        ];
        _messages[idx] = _messages[idx].copyWith(reactions: updated);
      }
    });

    await chatService.sendReaction(
      widget.conversationId,
      msg.timestamp,
      msg.senderUuid,
      emoji,
    );
  }

  /// Scroll to and highlight a message by its timestamp.
  void _scrollToQuotedMessage(int quoteTimestamp) {
    final targetIndex = _messages
        .indexWhere((m) => m.timestamp == quoteTimestamp);

    if (targetIndex < 0) return;

    _highlightTimer?.cancel();
    setState(() => _highlightTimestamp = quoteTimestamp);
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightTimestamp = null);
    });

    final key = _messageKeys[_messages[targetIndex].primaryKey];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        alignment: 0.5,
        duration: const Duration(milliseconds: 300),
      );
      return;
    }

    final estimatedOffset = targetIndex * 72.0;
    _scrollController.animateTo(
      estimatedOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    ).then((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final k = _messageKeys[_messages[targetIndex].primaryKey];
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
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ---------- Day separator helpers ----------

  bool _isDifferentDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year != lb.year || la.month != lb.month || la.day != lb.day;
  }

  bool _shouldShowAvatar(int index) {
    final msg = _messages[index];
    if (msg.isOutgoing) return false;
    if (index == 0) return true;
    final prev = _messages[index - 1];
    return prev.senderUuid != msg.senderUuid || prev.isOutgoing;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.chatTitle),
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
          : _buildMessageView(),
    );
  }

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

  Widget _buildReplyBar(ThemeData theme) {
    if (_replyTarget == null) return const SizedBox.shrink();

    final target = _replyTarget!;
    final user = _userCache[target.senderUuid];
    final senderName = target.isOutgoing
        ? 'You'
        : (user?.name ?? target.senderName ?? 'Unknown');
    final previewText = target.text ?? '';

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: const Border(
          left: BorderSide(color: Color(0xFF3A76F0), width: 3),
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
                    color: const Color(0xFF3A76F0),
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
                color: const Color(0xFF3A76F0),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessageItem(int index) {
    final msg = _messages[index];
    final user = _userCache[msg.senderUuid];

    // Skip reaction-type messages (handled as annotations on target messages)
    if (msg.contentType == 'reaction') return const SizedBox.shrink();

    _messageKeys[msg.primaryKey] ??= GlobalKey();
    final msgKey = _messageKeys[msg.primaryKey]!;
    final isHighlighted = msg.timestamp == _highlightTimestamp;

    // Determine sender name for incoming messages
    final senderName = msg.isOutgoing
        ? null
        : (user?.name ?? msg.senderName);

    final bubble = SignalMessageBubble(
      message: msg,
      senderName: senderName,
      senderPhotoPath: user?.avatarPath,
      showAvatar: _shouldShowAvatar(index),
      onReply: (m) => setState(() => _replyTarget = m),
      onDelete: null, // Signal does not support remote deletion from linked devices
      onReact: _reactToMessage,
      onQuotePreviewTap: _scrollToQuotedMessage,
    );

    final wrappedBubble = AnimatedContainer(
      key: msgKey,
      duration: const Duration(milliseconds: 500),
      color: isHighlighted ? const Color(0x302B5278) : Colors.transparent,
      child: bubble,
    );

    // Day separator
    final bool showSeparator;
    if (index == _messages.length - 1) {
      showSeparator = true;
    } else {
      final older = _messages[index + 1];
      showSeparator = _isDifferentDay(msg.dateTime, older.dateTime);
    }

    if (showSeparator) {
      return Column(
        children: [
          SignalDateSeparator(date: msg.dateTime),
          wrappedBubble,
        ],
      );
    }

    return wrappedBubble;
  }
}
