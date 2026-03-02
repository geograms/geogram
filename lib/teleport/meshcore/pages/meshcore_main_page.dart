/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * MeshCore main page — device status banner + conversation list.
 * Two states: not connected (scan prompt) and connected (conversations).
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/app_service.dart';
import '../meshcore_service.dart';
import '../models/meshcore_message.dart';
import 'meshcore_chat_page.dart';
import 'meshcore_settings_page.dart';

class MeshCoreMainPage extends StatefulWidget {
  final String appPath;

  const MeshCoreMainPage({super.key, required this.appPath});

  @override
  State<MeshCoreMainPage> createState() => _MeshCoreMainPageState();
}

class _MeshCoreMainPageState extends State<MeshCoreMainPage> {
  final _service = MeshCoreService();
  StreamSubscription<MeshCoreEvent>? _eventSub;

  @override
  void initState() {
    super.initState();

    // Ensure service has storage and is enabled
    if (!_service.isEnabled) {
      final storage = AppService().profileStorage;
      if (storage != null) _service.setStorage(storage);
      _service.enable();
    }

    _eventSub = _service.events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MeshCoreSettingsPage(appPath: widget.appPath),
      ),
    );
  }

  void _openConversation(MeshCoreConversation conv) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MeshCoreChatPage(
          conversationId: conv.id,
          displayName: conv.displayName,
          conversationType: conv.type,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isConnected = _service.isConnected;
    final deviceInfo = _service.deviceInfo;
    final conversations = _service.getConversations();

    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshCore'),
        actions: [
          // Connection indicator
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(
              isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              color: isConnected
                  ? const Color(0xFF00BCD4)
                  : theme.colorScheme.onSurfaceVariant,
              size: 20,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'MeshCore Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // Device info banner
          if (isConnected && deviceInfo != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF00BCD4).withValues(alpha: 0.08),
                border: Border(
                  bottom: BorderSide(
                    color: const Color(0xFF00BCD4).withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.radio, size: 18, color: Color(0xFF00BCD4)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          deviceInfo.name,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (deviceInfo.firmwareVersion != null)
                          Text(
                            'FW ${deviceInfo.firmwareVersion}'
                            '${deviceInfo.boardModel != null ? ' | ${deviceInfo.boardModel}' : ''}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (deviceInfo.frequencyMhz != null)
                    Text(
                      '${deviceInfo.frequencyMhz!.toStringAsFixed(2)} MHz',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: const Color(0xFF00BCD4),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),

          // Not connected state
          if (!isConnected)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.radio,
                        size: 64,
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No MeshCore Device Connected',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Connect to a MeshCore companion radio\n'
                        'to send and receive mesh messages.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.bluetooth_searching),
                        label: const Text('Find Device'),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Conversation list
          if (isConnected)
            Expanded(
              child: conversations.isEmpty
                  ? Center(
                      child: Text(
                        'No conversations yet.\n'
                        'Messages from the mesh will appear here.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
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
    MeshCoreConversation conv,
    ThemeData theme,
  ) {
    final isChannel =
        conv.type == MeshCoreConversationType.channel;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isChannel
            ? Colors.orange.withValues(alpha: 0.15)
            : const Color(0xFF00BCD4).withValues(alpha: 0.15),
        child: Icon(
          isChannel ? Icons.tag : Icons.person,
          color: isChannel ? Colors.orange : const Color(0xFF00BCD4),
          size: 20,
        ),
      ),
      title: Text(
        conv.displayName,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: conv.lastMessage != null
          ? Text(
              conv.lastMessage!.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            )
          : Text(
              'No messages',
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
