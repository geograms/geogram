/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Meshtastic main page — connection status banner, TabBar with
 * Messages (conversations) and Nodes (mesh nodes) tabs.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/app_service.dart';
import '../../../services/i18n_service.dart';
import '../meshtastic_service.dart';
import '../models/meshtastic_node.dart';
import '../widgets/meshtastic_node_card.dart';
import 'meshtastic_chat_page.dart';
import 'meshtastic_settings_page.dart';

class MeshtasticMainPage extends StatefulWidget {
  final String appPath;

  const MeshtasticMainPage({super.key, required this.appPath});

  @override
  State<MeshtasticMainPage> createState() => _MeshtasticMainPageState();
}

class _MeshtasticMainPageState extends State<MeshtasticMainPage>
    with SingleTickerProviderStateMixin {
  final _service = MeshtasticService();
  StreamSubscription<MeshtasticEvent>? _eventSub;
  bool _loading = true;
  late TabController _tabController;

  static const _brandColor = Color(0xFF67EA94);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initService();
    _eventSub = _service.events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _initService() async {
    if (!_service.isEnabled) {
      final storage = AppService().profileStorage;
      if (storage != null) _service.setStorage(storage);
      await _service.enableAsync();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MeshtasticSettingsPage(appPath: widget.appPath),
      ),
    );
  }

  void _openConversation(MeshtasticConversation conv) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MeshtasticChatPage(
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
          title: Text(I18nService().t('meshtastic_title')),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final isConnected = _service.isConnected;

    return Scaffold(
      appBar: AppBar(
        title: Text(I18nService().t('meshtastic_title')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(
              isConnected ? Icons.landscape : Icons.landscape_outlined,
              color: isConnected
                  ? _brandColor
                  : theme.colorScheme.onSurfaceVariant,
              size: 20,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: I18nService().t('meshtastic_settings_title'),
            onPressed: _openSettings,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: _brandColor,
          labelColor: _brandColor,
          tabs: [
            Tab(text: I18nService().t('meshtastic_tab_messages')),
            Tab(text: I18nService().t('meshtastic_tab_nodes')),
          ],
        ),
      ),
      body: Column(
        children: [
          // Status banner
          _buildStatusBanner(theme, isConnected),

          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildMessagesTab(theme),
                _buildNodesTab(theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner(ThemeData theme, bool isConnected) {
    return Container(
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
          Icon(
            Icons.landscape,
            size: 18,
            color: isConnected ? _brandColor : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Meshtastic',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${_service.nodes.length} ${I18nService().t('meshtastic_nodes_count')}'
                  ' | ${_service.channels.length} ${I18nService().t('meshtastic_channels_count')}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (isConnected)
            Text(
              I18nService().t('meshtastic_connected_status'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: _brandColor,
                fontWeight: FontWeight.w500,
              ),
            )
          else
            Text(
              I18nService().t('meshtastic_offline_status'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessagesTab(ThemeData theme) {
    final conversations = _service.getConversations();

    if (conversations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.landscape,
                size: 64,
                color: theme.colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.3),
              ),
              const SizedBox(height: 16),
              Text(
                I18nService().t('meshtastic_no_conversations_title'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                I18nService().t('meshtastic_no_conversations_desc'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _openSettings,
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(I18nService().t('meshtastic_find_device_btn')),
                style: FilledButton.styleFrom(
                  backgroundColor: _brandColor,
                  foregroundColor: Colors.black,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: conversations.length,
      itemBuilder: (context, index) =>
          _buildConversationTile(conversations[index], theme),
    );
  }

  Widget _buildConversationTile(
    MeshtasticConversation conv,
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
              conv.lastMessage!.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            )
          : Text(
              I18nService().t('meshtastic_no_messages'),
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

  Widget _buildNodesTab(ThemeData theme) {
    final nodes = _service.nodes;
    final myNum = _service.myNodeNum;

    if (nodes.isEmpty) {
      return Center(
        child: Text(
          I18nService().t('meshtastic_no_nodes'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // Sort: own node first, then by lastHeard descending
    final sorted = List<MeshtasticNode>.from(nodes);
    sorted.sort((a, b) {
      if (a.nodeNum == myNum) return -1;
      if (b.nodeNum == myNum) return 1;
      return b.lastHeard.compareTo(a.lastHeard);
    });

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sorted.length,
      itemBuilder: (context, index) => MeshtasticNodeCard(
        node: sorted[index],
        isMyNode: sorted[index].nodeNum == myNum,
      ),
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
