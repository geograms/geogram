/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'package:flutter/material.dart';
import '../models/now_item.dart';
import '../models/device_source.dart';
import '../services/devices_service.dart';
import '../services/now_service.dart';
import '../services/i18n_service.dart';
import '../services/profile_service.dart';
import '../services/station_service.dart';
import '../services/direct_message_service.dart';
import '../teleport/irc/irc_service.dart';
import '../teleport/telegram/telegram_service.dart';
import 'events_browser_page.dart';
import 'remote_blog_browser_page.dart';
import 'remote_chat_browser_page.dart';
import 'remote_chat_room_page.dart';
import 'report_browser_page.dart';
import '../teleport/aprs/aprs_service.dart';
import '../teleport/aprs/models/aprs_conversation.dart';
import '../teleport/aprs/pages/aprs_conversation_page.dart';
import '../teleport/irc/pages/irc_chat_page.dart';
import '../teleport/telegram/pages/telegram_chat_page.dart';
import '../util/app_type_theme.dart';
import '../util/event_bus.dart';

/// Activity feed page showing recent events as source-grouped cards
class NowPage extends StatefulWidget {
  const NowPage({super.key});

  @override
  State<NowPage> createState() => _NowPageState();
}

class _NowPageState extends State<NowPage> {
  final NowService _nowService = NowService();
  final I18nService _i18n = I18nService();
  StreamSubscription<List<NowItem>>? _itemsSubscription;
  List<NowItem> _items = [];
  final Map<String, TextEditingController> _replyControllers = {};
  final Map<String, FocusNode> _replyFocusNodes = {};

  @override
  void initState() {
    super.initState();
    _items = _nowService.items;
    _itemsSubscription = _nowService.itemsStream.listen((items) {
      if (mounted) setState(() => _items = items);
    });
  }

  @override
  void dispose() {
    _itemsSubscription?.cancel();
    for (final c in _replyControllers.values) {
      c.dispose();
    }
    for (final f in _replyFocusNodes.values) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dynamic_feed_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.onSurface.withAlpha(80),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('now_empty'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withAlpha(150),
              ),
            ),
          ],
        ),
      );
    }

    final grouped = _nowService.groupedItems;

    // Flatten to a list of (appType, sourceId, items) sorted by newest message
    final cards = <_CardData>[];
    for (final appType in grouped.keys) {
      for (final sourceId in grouped[appType]!.keys) {
        final items = grouped[appType]![sourceId]!;
        if (items.isEmpty) continue;
        // Items are already sorted chronologically (oldest first) from service
        final newestTimestamp = items.last.timestamp;
        final unreadCount = items.where((i) => !i.isRead).length;
        cards.add(_CardData(
          appType: appType,
          sourceId: sourceId,
          sourceName: items.first.sourceName,
          items: items,
          newestTimestamp: newestTimestamp,
          unreadCount: unreadCount,
        ));
      }
    }

    // Sort cards by most recent activity first
    cards.sort((a, b) => b.newestTimestamp.compareTo(a.newestTimestamp));

    return LayoutBuilder(
      builder: (context, constraints) {
        const minCardWidth = 170.0;
        final columns = (constraints.maxWidth / minCardWidth).floor().clamp(1, 4);

        if (columns == 1) {
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: cards.length,
            itemBuilder: (context, index) => _buildCard(cards[index]),
          );
        }

        // Distribute cards into columns (shortest column first for masonry effect)
        final columnCards = List.generate(columns, (_) => <_CardData>[]);
        for (final card in cards) {
          // Pick the column with fewest items (rough height balance)
          var minCol = 0;
          for (var c = 1; c < columns; c++) {
            if (columnCards[c].length < columnCards[minCol].length) minCol = c;
          }
          columnCards[minCol].add(card);
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < columns; c++) ...[
                if (c > 0) const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    children: [
                      for (final card in columnCards[c]) _buildCard(card),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildCard(_CardData card) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: colorScheme.outlineVariant.withAlpha(80),
        ),
      ),
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Card header
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            onTap: () => _navigateToSourceFromCard(card),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 8),
              child: Row(
                children: [
                  Icon(
                    _getAppTypeIcon(card.appType),
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      card.sourceName.isNotEmpty
                          ? card.sourceName
                          : card.sourceId,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (card.unreadCount > 0) ...[
                    const SizedBox(width: 8),
                    _buildUnreadBadge(card.unreadCount),
                  ],
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      icon: Icon(
                        Icons.more_vert,
                        color: colorScheme.onSurface.withAlpha(150),
                      ),
                      onPressed: () => _showGroupSettingsSheet(
                        card.appType,
                        card.sourceId,
                        card.sourceName,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: colorScheme.outlineVariant.withAlpha(60)),
          // Card body — chronological messages
          ...card.items.map((item) => _buildMessageRow(item)),
          if (_isReplyable(card.appType)) _buildReplyRow(card),
        ],
      ),
    );
  }

  static bool _isReplyable(String appType) =>
      const {'chat', 'irc', 'dm', 'telegram', 'aprs'}.contains(appType);

  TextEditingController _getReplyController(String appType, String sourceId) {
    final key = '$appType:$sourceId';
    return _replyControllers.putIfAbsent(key, () => TextEditingController());
  }

  FocusNode _getReplyFocusNode(String appType, String sourceId) {
    final key = '$appType:$sourceId';
    return _replyFocusNodes.putIfAbsent(key, () => FocusNode());
  }

  Widget _buildReplyRow(_CardData card) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _getReplyController(card.appType, card.sourceId),
              focusNode: _getReplyFocusNode(card.appType, card.sourceId),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: _i18n.t('reply'),
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurface.withAlpha(100),
                ),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide(
                    color: colorScheme.outlineVariant.withAlpha(80),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide(
                    color: colorScheme.outlineVariant.withAlpha(80),
                  ),
                ),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendReply(card),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 18,
              icon: Icon(Icons.send, color: colorScheme.primary),
              onPressed: () => _sendReply(card),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendReply(_CardData card) async {
    final key = '${card.appType}:${card.sourceId}';
    final controller = _replyControllers[key];
    if (controller == null) return;
    final text = controller.text.trim();
    if (text.isEmpty) return;

    try {
      switch (card.appType) {
        case 'chat':
          final station = StationService().getPreferredStation();
          if (station != null) {
            final profile = ProfileService().getProfile();
            final url = station.url
                .replaceFirst('wss://', 'https://')
                .replaceFirst('ws://', 'http://');
            await StationService().postRoomMessage(
              url, card.sourceId, profile.callsign, text,
            );
          }
          break;
        case 'irc':
          final parts = card.sourceId.split(':');
          if (parts.length >= 2) {
            final serverId = parts[0];
            final channel = parts.sublist(1).join(':');
            IrcService().sendMessage(serverId, channel, text);
          }
          break;
        case 'dm':
          await DirectMessageService().sendMessage(card.sourceId, text);
          break;
        case 'telegram':
          final chatId = int.tryParse(card.sourceId);
          if (chatId != null) {
            await TelegramService().chatService?.sendMessage(chatId, text);
          }
          break;
        case 'aprs':
          AprsService().sendMessage(card.sourceId, text);
          break;
      }
      controller.clear();

      // Show the user's own message in the feed for visual confirmation
      final myCallsign = ProfileService().getProfile().callsign;
      final summary = text.length > 100 ? '${text.substring(0, 100)}...' : text;
      EventBus().fire(NowItemEvent(
        id: '${card.appType}:${card.sourceId}:reply:${DateTime.now().toIso8601String()}',
        appType: card.appType,
        sourceId: card.sourceId,
        sourceName: card.sourceName,
        callsign: myCallsign,
        summary: summary,
        priority: NowPriority.routine,
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    }
  }

  Widget _buildUnreadBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildMessageRow(NowItem item) {
    final age = _formatAge(item.timestamp);
    final settings =
        _nowService.getGroupSettings(item.appType, item.sourceId);
    final isNearExpiry = settings.expiryMinutes > 0 &&
        DateTime.now().difference(item.timestamp).inMinutes >
            settings.expiryMinutes * 0.9;
    final dimAlpha = isNearExpiry ? 100 : 255;
    final colorScheme = Theme.of(context).colorScheme;

    final truncatedSummary = item.summary.length > 60
        ? '${item.summary.substring(0, 60)}...'
        : item.summary;

    return InkWell(
      onTap: () {
        _nowService.markAsRead(item.id);
        _navigateToSource(item);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPriorityDot(item.priority),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${item.callsign}: ',
                      style: TextStyle(
                        fontWeight:
                            item.isRead ? FontWeight.w500 : FontWeight.bold,
                        fontSize: 13,
                        color: colorScheme.onSurface.withAlpha(dimAlpha),
                      ),
                    ),
                    TextSpan(
                      text: truncatedSummary,
                      style: TextStyle(
                        fontWeight:
                            item.isRead ? FontWeight.normal : FontWeight.w500,
                        fontSize: 13,
                        color: colorScheme.onSurface
                            .withAlpha(isNearExpiry ? 80 : 200),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              age,
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurface.withAlpha(120),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPriorityDot(int priority) {
    Color color;
    if (priority <= 2) {
      color = Colors.red;
    } else if (priority <= 3) {
      color = Colors.orange;
    } else if (priority <= 5) {
      color = Colors.blue;
    } else if (priority <= 7) {
      color = Colors.green;
    } else {
      color = Colors.grey;
    }

    return Container(
      margin: const EdgeInsets.only(top: 4),
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  void _navigateToSourceFromCard(_CardData card) {
    if (card.items.isNotEmpty) {
      _navigateToSource(card.items.first);
    }
  }

  void _navigateToSource(NowItem item) {
    switch (item.appType) {
      case 'chat':
        final station = StationService().getPreferredStation();
        if (station != null && station.url.isNotEmpty) {
          final device = RemoteDevice(
            callsign: station.callsign ?? 'STATION',
            name: station.name,
            url: station.url.replaceFirst('wss://', 'https://').replaceFirst('ws://', 'http://'),
            apps: [],
            source: DeviceSourceType.station,
          );
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => RemoteChatRoomPage(
              device: device,
              room: ChatRoom(
                id: item.sourceId,
                name: item.sourceName,
                memberCount: 0,
                visibility: 'public',
              ),
            ),
          ));
        }
        break;
      case 'irc':
        final parts = item.sourceId.split(':');
        if (parts.length >= 2) {
          final serverId = parts[0];
          final channel = parts.sublist(1).join(':');
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  IrcChatPage(serverId: serverId, channel: channel),
            ),
          );
        }
        break;
      case 'dm':
        Navigator.pushNamed(context, '/dm', arguments: item.sourceId);
        break;
      case 'email':
        Navigator.pushNamed(context, '/email', arguments: item.sourceId);
        break;
      case 'alert':
        Navigator.pushNamed(context, '/alerts', arguments: item.sourceId);
        break;
      case 'telegram':
        final chatId = int.tryParse(item.sourceId);
        if (chatId != null) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TelegramChatPage(
                chatId: chatId,
                chatTitle: item.sourceName,
              ),
            ),
          );
        }
        break;
      case 'aprs':
        final isTag = item.sourceId.startsWith('#');
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AprsConversationPage(
              conversationId: item.sourceId,
              conversationType: isTag
                  ? AprsConversationType.tag
                  : item.sourceId == 'geochat'
                      ? AprsConversationType.direct
                      : AprsConversationType.direct,
              partnerPosition:
                  AprsService().lastKnownPositions[item.sourceId],
            ),
          ),
        );
        break;
      case 'blog':
        final station = StationService().getPreferredStation();
        if (station != null && station.url.isNotEmpty) {
          final device = RemoteDevice(
            callsign: station.callsign ?? 'STATION',
            name: station.name,
            url: station.url
                .replaceFirst('wss://', 'https://')
                .replaceFirst('ws://', 'http://'),
            apps: [],
            source: DeviceSourceType.station,
          );
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => RemoteBlogBrowserPage(device: device),
          ));
        }
        break;
      case 'events':
        final station = StationService().getPreferredStation();
        if (station != null && station.url.isNotEmpty) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => EventsBrowserPage(
              remoteDeviceUrl: station.url
                  .replaceFirst('wss://', 'https://')
                  .replaceFirst('ws://', 'http://'),
              remoteDeviceCallsign: station.callsign,
              remoteDeviceName: station.name,
            ),
          ));
        }
        break;
      case 'places':
        final station = StationService().getPreferredStation();
        if (station != null && station.url.isNotEmpty) {
          final url = station.url
              .replaceFirst('wss://', 'https://')
              .replaceFirst('ws://', 'http://');
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ReportBrowserPage(
              remoteDeviceUrl: url,
              remoteDeviceCallsign: station.callsign,
              remoteDeviceName: station.name,
            ),
          ));
        }
        break;
      default:
        break;
    }
  }

  void _showGroupSettingsSheet(
      String appType, String sourceId, String sourceName) {
    final settings = _nowService.getGroupSettings(appType, sourceId);
    var maxItems = settings.maxItems.toDouble();
    var expiryHours = settings.expiryMinutes / 60.0;
    final isMuted = _nowService.isSourceMuted(appType, sourceId);
    final label = sourceName.isNotEmpty ? sourceName : sourceId;

    showModalBottomSheet(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_i18n.t('now_group_settings')} — $label',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading:
                      Icon(isMuted ? Icons.volume_off : Icons.volume_up),
                  title: Text(isMuted
                      ? _i18n.t('now_unmute_source')
                      : _i18n.t('now_mute_source')),
                  onTap: () {
                    _nowService.toggleSourceMute(appType, sourceId);
                    Navigator.pop(context);
                  },
                ),
                const Divider(),
                Row(
                  children: [
                    Text(_i18n.t('now_max_items')),
                    const Spacer(),
                    Text('${maxItems.round()}'),
                  ],
                ),
                Slider(
                  value: maxItems,
                  min: 1,
                  max: 50,
                  divisions: 49,
                  onChanged: (v) => setSheetState(() => maxItems = v),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(_i18n.t('now_expiry')),
                    const Spacer(),
                    Text(_i18n
                        .t('now_expiry_hours')
                        .replaceAll('{0}', expiryHours.round().toString())),
                  ],
                ),
                Slider(
                  value: expiryHours.clamp(0, 168),
                  min: 0,
                  max: 168,
                  divisions: 168,
                  onChanged: (v) =>
                      setSheetState(() => expiryHours = v),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      _nowService.setGroupSettings(
                        '$appType:$sourceId',
                        NowGroupSettings(
                          maxItems: maxItems.round(),
                          expiryMinutes: (expiryHours * 60).round(),
                        ),
                      );
                      Navigator.pop(context);
                    },
                    child: Text(_i18n.t('save')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _getAppTypeIcon(String appType) {
    switch (appType) {
      case 'chat':
        return Icons.chat;
      case 'dm':
        return Icons.message;
      case 'alert':
        return Icons.campaign;
      case 'irc':
        return Icons.tag;
      case 'aprs':
        return Icons.cell_tower;
      case 'telegram':
        return Icons.send;
      case 'blog':
        return Icons.article;
      case 'events':
        return Icons.event;
      case 'places':
        return Icons.place;
      case 'email':
        return Icons.email;
      default:
        return getAppTypeIcon(appType);
    }
  }

  String _formatAge(DateTime timestamp) {
    final diff = DateTime.now().difference(timestamp);
    if (diff.inMinutes < 1) return _i18n.t('just_now');
    if (diff.inHours < 1) {
      return _i18n.t('minutes_ago').replaceAll('{0}', '${diff.inMinutes}');
    }
    if (diff.inDays < 1) {
      return _i18n.t('hours_ago').replaceAll('{0}', '${diff.inHours}');
    }
    return _i18n.t('days_ago').replaceAll('{0}', '${diff.inDays}');
  }
}

/// Internal data class for card rendering
class _CardData {
  final String appType;
  final String sourceId;
  final String sourceName;
  final List<NowItem> items;
  final DateTime newestTimestamp;
  final int unreadCount;

  _CardData({
    required this.appType,
    required this.sourceId,
    required this.sourceName,
    required this.items,
    required this.newestTimestamp,
    required this.unreadCount,
  });
}
