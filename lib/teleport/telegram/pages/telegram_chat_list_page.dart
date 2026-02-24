/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Chat list page — shows all Telegram chats/groups/channels.
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../services/app_service.dart';
import '../../../services/log_service.dart';
import '../../../services/profile_service.dart';
import '../models/telegram_auth_state.dart';
import '../models/telegram_chat.dart';
import '../telegram_service.dart';
import '../widgets/telegram_chat_tile.dart';
import 'telegram_auth_page.dart';
import 'telegram_chat_page.dart';
import 'telegram_settings_page.dart';

class TelegramChatListPage extends StatefulWidget {
  final String appPath;

  const TelegramChatListPage({super.key, required this.appPath});

  @override
  State<TelegramChatListPage> createState() => _TelegramChatListPageState();
}

class _TelegramChatListPageState extends State<TelegramChatListPage> {
  StreamSubscription<TelegramEvent>? _eventSub;
  List<TelegramChat> _chats = [];
  List<TelegramChat> _filteredChats = [];
  final _searchController = TextEditingController();
  bool _searching = false;
  bool _loading = true;
  Timer? _refreshDebounce;
  String? _diskSizeLabel;
  int _favoritesCount = 0;
  Map<int, Uint8List> _cachedPhotos = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterChats);
    _ensureConnectedAndLoad();
  }

  /// Ensure TelegramService is initialized and connected, then load chats.
  Future<void> _ensureConnectedAndLoad() async {
    final service = TelegramService();

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
        LogService().error('TelegramChatListPage: reconnect failed: $e');
        setState(() => _loading = false);
        return;
      }
    }

    // Listen for auth state — if TDLib needs re-auth, redirect
    _eventSub = service.events.listen((event) {
      if (event.type == TelegramEventType.chatListUpdated ||
          event.type == TelegramEventType.newMessage) {
        _refreshDebounce?.cancel();
        _refreshDebounce = Timer(const Duration(milliseconds: 500), _refreshChats);
      }
      if (event.type == TelegramEventType.authStateChanged) {
        final data = event.data as TelegramAuthStateData;
        if (data.state == TelegramAuthState.waitingPhone ||
            data.state == TelegramAuthState.waitingCode ||
            data.state == TelegramAuthState.waitingPassword ||
            data.state == TelegramAuthState.waitingQrScan) {
          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => TelegramAuthPage(appPath: widget.appPath),
              ),
            );
          }
        }
      }
    });

    await _loadChats();
    _resolveChatPhotos();
    _computeDiskSize();
  }

  Future<void> _loadChats() async {
    final chatService = TelegramService().chatService;
    if (chatService == null) {
      setState(() => _loading = false);
      return;
    }

    try {
      await chatService.loadChats();
      // Give TDLib a moment to send chat updates
      await Future.delayed(const Duration(milliseconds: 500));
      _refreshChats();
    } catch (e) {
      LogService().error('TelegramChatListPage: loadChats failed: $e');
    }

    setState(() => _loading = false);
  }

  void _refreshChats() {
    final chatService = TelegramService().chatService;
    if (chatService == null) return;
    final cache = TelegramService().cacheService;

    // Build set of chat IDs that have a local cache DB on disk.
    Set<int>? cachedChatIds;
    if (cache != null) {
      final cacheDir = Directory(cache.cacheDirAbsolutePath);
      if (cacheDir.existsSync()) {
        cachedChatIds = {};
        for (final f in cacheDir.listSync().whereType<File>()) {
          final match = RegExp(r'chat_(-?\d+)\.db')
              .firstMatch(f.uri.pathSegments.last);
          if (match != null) cachedChatIds.add(int.parse(match.group(1)!));
        }
      }
    }

    // Get top-30 most-visited chats for ranking
    final topVisited = cache?.getTopVisitedChats() ?? {};

    setState(() {
      final allChats = chatService.chats.map((chat) {
        // Override TDLib's unread count with the local cache count when a
        // local DB exists — the cache is marked-as-read when the user
        // opens the chat, so it's always up to date.
        if (cache != null &&
            cachedChatIds != null &&
            cachedChatIds.contains(chat.id)) {
          final localUnread = cache.getUnreadCount(chat.id);
          if (localUnread != chat.unreadCount) {
            return chat.copyWith(unreadCount: localUnread);
          }
        }
        return chat;
      }).toList();

      // Partition into favorites (in top-30) and rest
      if (topVisited.isNotEmpty) {
        final favorites = <TelegramChat>[];
        final rest = <TelegramChat>[];
        for (final chat in allChats) {
          if (topVisited.containsKey(chat.id)) {
            favorites.add(chat);
          } else {
            rest.add(chat);
          }
        }
        // Sort favorites by visit count DESC, ties broken by lastMessageDate
        favorites.sort((a, b) {
          final ca = topVisited[a.id] ?? 0;
          final cb = topVisited[b.id] ?? 0;
          if (ca != cb) return cb.compareTo(ca);
          final da = a.lastMessageDate ?? DateTime(1970);
          final db = b.lastMessageDate ?? DateTime(1970);
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

  /// Download chat photos progressively in batches of 5.
  /// Phase 1: instantly load cached photo blobs from SQLite (works offline).
  /// Phase 2: download missing photos from TDLib (online).
  Future<void> _resolveChatPhotos() async {
    final chatService = TelegramService().chatService;
    if (chatService == null) return;

    // Phase 1: Load cached photo blobs from SQLite (instant, works offline)
    final cache = TelegramService().cacheService;
    if (cache != null) {
      final photos = cache.getAllCachedChatPhotos();
      if (photos.isNotEmpty && mounted) {
        setState(() { _cachedPhotos = photos; });
      }
    }

    // Phase 2: Download missing photos from TDLib (online)
    final needsPhoto = _chats
        .where((c) => c.photoSmallFileId != null && c.photoSmallFileId != 0 && c.photoPath == null)
        .toList();

    for (int i = 0; i < needsPhoto.length; i += 5) {
      if (!mounted) break;
      final batch = needsPhoto.skip(i).take(5);
      final futures = batch.map((c) => chatService.downloadChatPhoto(c.id));
      await Future.wait(futures);
      if (mounted) _refreshChats();
      if (i + 5 < needsPhoto.length) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  /// Compute total disk usage of the Telegram folder (async, non-blocking).
  Future<void> _computeDiskSize() async {
    // Defer so chat list rendering is not delayed
    await Future.delayed(Duration.zero);
    if (!mounted) return;
    final storage = AppService().profileStorage;
    final pfx = TelegramService().storageService?.prefix ?? '';
    if (storage == null) return;
    final absPath = storage.getAbsolutePath(
        '${pfx.isEmpty ? "" : "$pfx/"}telegram');
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
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
            : const Text('Telegram'),
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
                      TelegramSettingsPage(appPath: widget.appPath),
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
                    final cachedBytes = chat.photoPath == null ? _cachedPhotos[chat.id] : null;
                    return TelegramChatTile(
                      chat: cachedBytes != null ? chat.copyWith(photoBytes: cachedBytes) : chat,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TelegramChatPage(
                              chatId: chat.id,
                              chatTitle: chat.title,
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
