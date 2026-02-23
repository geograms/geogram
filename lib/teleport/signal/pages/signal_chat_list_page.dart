/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Signal chat list page — shows all conversations (direct + group).
 * Mirrors TelegramChatListPage pattern: load conversations, search/filter,
 * listen to events, favorites partitioning.
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../services/app_service.dart';
import '../../../services/log_service.dart';
import '../../../services/profile_service.dart';
import '../models/signal_auth_state.dart';
import '../models/signal_chat.dart';
import '../signal_service.dart';
import '../widgets/signal_chat_tile.dart';
import 'signal_auth_page.dart';
import 'signal_chat_page.dart';
import 'signal_settings_page.dart';

class SignalChatListPage extends StatefulWidget {
  final String appPath;

  const SignalChatListPage({super.key, required this.appPath});

  @override
  State<SignalChatListPage> createState() => _SignalChatListPageState();
}

class _SignalChatListPageState extends State<SignalChatListPage> {
  StreamSubscription<SignalEvent>? _eventSub;
  List<SignalChat> _chats = [];
  List<SignalChat> _filteredChats = [];
  final _searchController = TextEditingController();
  bool _searching = false;
  bool _loading = true;
  Timer? _refreshDebounce;
  String? _diskSizeLabel;
  int _favoritesCount = 0;
  Map<String, Uint8List> _cachedPhotos = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterChats);
    _ensureConnectedAndLoad();
  }

  /// Ensure SignalService is initialized and connected, then load conversations.
  Future<void> _ensureConnectedAndLoad() async {
    final service = SignalService();

    if (!service.isRunning) {
      try {
        final profileStorage = AppService().profileStorage;
        if (profileStorage == null) {
          setState(() => _loading = false);
          return;
        }

        service.setStorage(profileStorage);

        final basePath = profileStorage.basePath;
        String teleportPath;
        if (widget.appPath.startsWith(basePath)) {
          teleportPath = widget.appPath.substring(basePath.length);
          while (teleportPath.startsWith('/') ||
              teleportPath.startsWith('\\')) {
            teleportPath = teleportPath.substring(1);
          }
        } else {
          teleportPath = widget.appPath.split('/').last;
        }

        final callsign = ProfileService().getProfile().callsign;
        await service.initialize(teleportPath, callsign);
        await service.connect();
      } catch (e) {
        LogService().error('SignalChatListPage: reconnect failed: $e');
        setState(() => _loading = false);
        return;
      }
    }

    // Listen for auth state — if Signal needs re-auth, redirect
    _eventSub = service.events.listen((event) {
      if (event.type == SignalEventType.chatListUpdated ||
          event.type == SignalEventType.newMessage) {
        _refreshDebounce?.cancel();
        _refreshDebounce =
            Timer(const Duration(milliseconds: 500), _refreshChats);
      }
      if (event.type == SignalEventType.authStateChanged) {
        final data = event.data as SignalAuthStateData;
        if (data.state == SignalAuthState.waitingLink ||
            data.state == SignalAuthState.waitingQrScan ||
            data.state == SignalAuthState.error) {
          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => SignalAuthPage(appPath: widget.appPath),
              ),
            );
          }
        }
      }
    });

    await _loadConversations();
    _loadCachedPhotos();
    _computeDiskSize();
  }

  Future<void> _loadConversations() async {
    final chatService = SignalService().chatService;
    if (chatService == null) {
      setState(() => _loading = false);
      return;
    }

    try {
      await chatService.loadConversations();
      // Give the bridge a moment to send updates
      await Future.delayed(const Duration(milliseconds: 500));
      _refreshChats();
    } catch (e) {
      LogService().error('SignalChatListPage: loadConversations failed: $e');
    }

    setState(() => _loading = false);
  }

  void _refreshChats() {
    final chatService = SignalService().chatService;
    if (chatService == null) return;
    final cache = SignalService().cacheService;

    // Get top-30 most-visited conversations for ranking
    final topVisited = cache?.getTopVisitedConversations() ?? {};

    setState(() {
      final allChats = chatService.conversations.map((chat) {
        // Override unread count with local cache count when available
        if (cache != null) {
          final localUnread = cache.getUnreadCount(chat.id);
          if (localUnread != chat.unreadCount) {
            return chat.copyWith(unreadCount: localUnread);
          }
        }
        return chat;
      }).toList();

      // Partition into favorites (in top-30) and rest
      if (topVisited.isNotEmpty) {
        final favorites = <SignalChat>[];
        final rest = <SignalChat>[];
        for (final chat in allChats) {
          if (topVisited.containsKey(chat.id)) {
            favorites.add(chat);
          } else {
            rest.add(chat);
          }
        }
        // Sort favorites by visit count DESC, ties broken by last message timestamp
        favorites.sort((a, b) {
          final ca = topVisited[a.id] ?? 0;
          final cb = topVisited[b.id] ?? 0;
          if (ca != cb) return cb.compareTo(ca);
          final da = a.lastMessage?.timestamp ?? 0;
          final db = b.lastMessage?.timestamp ?? 0;
          return db.compareTo(da);
        });
        _favoritesCount = favorites.length;
        _chats = [...favorites, ...rest];
      } else {
        _favoritesCount = 0;
        _chats = allChats;
      }

      _filterChats();
    });
  }

  void _filterChats() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredChats = _chats;
      } else {
        _filteredChats = _chats
            .where((c) => c.title.toLowerCase().contains(query))
            .toList();
      }
    });
  }

  /// Load cached conversation photos from SQLite (instant, works offline).
  void _loadCachedPhotos() {
    final cache = SignalService().cacheService;
    if (cache != null) {
      final photos = cache.getAllCachedConversationPhotos();
      if (photos.isNotEmpty && mounted) {
        setState(() {
          _cachedPhotos = photos;
        });
      }
    }
  }

  /// Compute total disk usage of the Signal folder (async, non-blocking).
  Future<void> _computeDiskSize() async {
    await Future.delayed(Duration.zero);
    if (!mounted) return;
    final storage = AppService().profileStorage;
    final pfx = SignalService().storageService?.prefix ?? '';
    if (storage == null) return;
    final absPath = storage.getAbsolutePath(
        '${pfx.isEmpty ? "" : "$pfx/"}signal');
    final dir = Directory(absPath);
    if (!await dir.exists()) return;
    int totalBytes = 0;
    try {
      await for (final f in dir.list(recursive: true)) {
        if (f is File) totalBytes += await f.length();
      }
    } catch (_) {}
    if (mounted) setState(() => _diskSizeLabel = _formatSize(totalBytes));
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

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _eventSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search chats...',
                  border: InputBorder.none,
                ),
              )
            : const Text('Signal'),
        actions: [
          if (_diskSizeLabel != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Text(
                  _diskSizeLabel!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _searchController.clear();
                }
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      SignalSettingsPage(appPath: widget.appPath),
                ),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _filteredChats.isEmpty
              ? Center(
                  child: Text(
                    _searchController.text.isNotEmpty
                        ? 'No chats match your search'
                        : 'No chats yet',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _filteredChats.length +
                      (_favoritesCount > 0 &&
                              _favoritesCount < _filteredChats.length &&
                              !_searching
                          ? 1
                          : 0),
                  itemBuilder: (context, index) {
                    // Insert "All chats" separator after favorites
                    final showSeparator = _favoritesCount > 0 &&
                        _favoritesCount < _filteredChats.length &&
                        !_searching;
                    if (showSeparator && index == _favoritesCount) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Divider(
                                color: theme.colorScheme.outlineVariant,
                                thickness: 0.5,
                              ),
                            ),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                'All chats',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(
                                color: theme.colorScheme.outlineVariant,
                                thickness: 0.5,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    final chatIndex =
                        showSeparator && index > _favoritesCount
                            ? index - 1
                            : index;
                    final chat = _filteredChats[chatIndex];
                    final cachedBytes = _cachedPhotos[chat.id];
                    return SignalChatTile(
                      chat: chat,
                      photoBytes: cachedBytes,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SignalChatPage(
                              conversationId: chat.id,
                              chatTitle: chat.title,
                              chatType: chat.type,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
    );
  }
}
