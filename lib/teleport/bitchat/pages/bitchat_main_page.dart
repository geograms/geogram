/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BitChat main page — status banner, channel list, peer list, DMs.
 * Two states: not enabled (setup prompt) and enabled (conversations).
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/app_service.dart';
import '../../../services/i18n_service.dart';
import '../bitchat_service.dart';
import 'bitchat_chat_page.dart';
import 'bitchat_settings_page.dart';

class BitchatMainPage extends StatefulWidget {
  final String appPath;

  const BitchatMainPage({super.key, required this.appPath});

  @override
  State<BitchatMainPage> createState() => _BitchatMainPageState();
}

class _BitchatMainPageState extends State<BitchatMainPage> {
  final _service = BitchatService();
  StreamSubscription<BitchatEvent>? _eventSub;
  bool _loading = true;

  static const _brandColor = Color(0xFFFF9100);

  @override
  void initState() {
    super.initState();
    _initService();
    _eventSub = _service.events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _initService() async {
    if (!_service.isEnabled) {
      final storage = AppService().profileStorage;
      if (storage != null) _service.setStorage(storage);
      await _service.ensureIdentity();
      await _service.enableAsync();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BitchatSettingsPage(appPath: widget.appPath),
      ),
    );
  }

  void _openConversation(BitchatConversation conv) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BitchatChatPage(
          conversationId: conv.id,
          displayName: conv.displayName,
          isChannel: conv.isChannel,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(I18nService().t('bitchat_title')),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final isConnected = _service.isConnected;
    final config = _service.config;
    final conversations = _service.getConversations();
    final geohash = _service.currentGeohash;

    return Scaffold(
      appBar: AppBar(
        title: Text(I18nService().t('bitchat_title')),
        actions: [
          // Connection indicator
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(
              isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: isConnected
                  ? _brandColor
                  : theme.colorScheme.onSurfaceVariant,
              size: 20,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: I18nService().t('bitchat_settings_title'),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // Status banner
          if (config != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _brandColor.withValues(alpha: 0.08),
                border: Border(
                  bottom: BorderSide(
                    color: _brandColor.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.bluetooth_connected,
                      size: 18, color: _brandColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          config.nickname,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${_service.connectedPeerCount} ${I18nService().t('bitchat_peers')}'
                          '${geohash.isNotEmpty ? ' | #$geohash' : ''}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isConnected)
                    Text(
                      I18nService().t('bitchat_mesh_active'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: _brandColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),

          // No conversations state
          if (conversations.isEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.bluetooth_connected,
                        size: 64,
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        I18nService().t('bitchat_no_conversations_title'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        I18nService().t('bitchat_no_conversations_desc'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.bluetooth_searching),
                        label:
                            Text(I18nService().t('bitchat_find_peers_btn')),
                        style: FilledButton.styleFrom(
                          backgroundColor: _brandColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Conversation list
          if (conversations.isNotEmpty)
            Expanded(
              child: ListView.builder(
                itemCount: conversations.length,
                itemBuilder: (context, index) =>
                    _buildConversationTile(conversations[index], theme),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildConversationTile(
    BitchatConversation conv,
    ThemeData theme,
  ) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: conv.isChannel
            ? _brandColor.withValues(alpha: 0.15)
            : Colors.blue.withValues(alpha: 0.15),
        child: Icon(
          conv.isChannel ? Icons.tag : Icons.person,
          color: conv.isChannel ? _brandColor : Colors.blue,
          size: 20,
        ),
      ),
      title: Text(
        conv.displayName,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: conv.lastMessage != null
          ? Text(
              conv.lastMessage!.content,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            )
          : Text(
              I18nService().t('bitchat_no_messages'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (conv.lastMessageTime != null)
            Text(
              _formatConvTime(conv.lastMessageTime!),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (conv.messageCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${conv.messageCount}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
      onTap: () => _openConversation(conv),
    );
  }

  static String _formatConvTime(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(local.year, local.month, local.day);

    if (msgDay == today) {
      final h = local.hour.toString().padLeft(2, '0');
      final m = local.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }

    final diff = today.difference(msgDay).inDays;
    if (diff == 1) return 'Yesterday';
    if (diff < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[local.weekday - 1];
    }
    return '${local.day}/${local.month}';
  }
}
