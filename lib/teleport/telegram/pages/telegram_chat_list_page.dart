/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Chat list page — shows all Telegram chats/groups/channels.
 */

import 'dart:async';

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
        _refreshChats();
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
    setState(() {
      _chats = chatService.chats;
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

  @override
  void dispose() {
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
                  itemCount: _filteredChats.length,
                  itemBuilder: (context, index) {
                    final chat = _filteredChats[index];
                    return TelegramChatTile(
                      chat: chat,
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
