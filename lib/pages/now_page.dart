/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'package:flutter/material.dart';
import '../models/now_item.dart';
import '../services/now_service.dart';
import '../services/i18n_service.dart';
import '../teleport/irc/pages/irc_chat_page.dart';
import '../util/app_type_theme.dart';

/// Activity feed page showing recent events across all apps
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
  final Set<String> _collapsedAppTypes = {};
  final Set<String> _collapsedSources = {};

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

    // Sort appType groups by best (lowest) priority
    final sortedTypes = grouped.keys.toList()
      ..sort((a, b) {
        int bestPriority(String appType) {
          int best = 999;
          for (final sources in grouped[appType]!.values) {
            for (final item in sources) {
              if (item.priority < best) best = item.priority;
            }
          }
          return best;
        }
        return bestPriority(a).compareTo(bestPriority(b));
      });

    final widgets = <Widget>[];
    for (var i = 0; i < sortedTypes.length; i++) {
      final appType = sortedTypes[i];
      final sources = grouped[appType]!;
      final isCollapsed = _collapsedAppTypes.contains(appType);

      // Total item count for this appType
      final totalCount =
          sources.values.fold<int>(0, (sum, list) => sum + list.length);

      // AppType header
      widgets.add(
        InkWell(
          onTap: () => setState(() {
            if (isCollapsed) {
              _collapsedAppTypes.remove(appType);
            } else {
              _collapsedAppTypes.add(appType);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(
                  isCollapsed
                      ? Icons.chevron_right
                      : Icons.expand_more,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Icon(
                  _getAppTypeIcon(appType),
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  _getAppTypeLabel(appType),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '($totalCount)',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withAlpha(120),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      if (!isCollapsed) {
        // Sort sources by newest item timestamp
        final sortedSourceIds = sources.keys.toList()
          ..sort((a, b) {
            final aTime = sources[a]!.first.timestamp;
            final bTime = sources[b]!.first.timestamp;
            return bTime.compareTo(aTime);
          });

        for (final sourceId in sortedSourceIds) {
          final sourceItems = sources[sourceId]!;
          final sourceName = sourceItems.first.sourceName;
          final sourceKey = '$appType:$sourceId';
          final isSourceCollapsed = _collapsedSources.contains(sourceKey);
          final settings =
              _nowService.getGroupSettings(appType, sourceId);
          final hasMore = sourceItems.length >= settings.maxItems;

          // Source sub-header
          widgets.add(
            InkWell(
              onTap: () => setState(() {
                if (isSourceCollapsed) {
                  _collapsedSources.remove(sourceKey);
                } else {
                  _collapsedSources.add(sourceKey);
                }
              }),
              onLongPress: () =>
                  _showGroupSettingsSheet(appType, sourceId, sourceName),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(40, 6, 16, 2),
                child: Row(
                  children: [
                    Icon(
                      isSourceCollapsed
                          ? Icons.chevron_right
                          : Icons.expand_more,
                      size: 16,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withAlpha(180),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        sourceName.isNotEmpty ? sourceName : sourceId,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withAlpha(200),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '(${sourceItems.length})',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withAlpha(120),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );

          if (!isSourceCollapsed) {
            for (final item in sourceItems) {
              widgets.add(_buildItemTile(item));
            }
            if (hasMore) {
              widgets.add(
                Padding(
                  padding: const EdgeInsets.only(left: 56, bottom: 4),
                  child: Text(
                    _i18n.t('now_show_more'),
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.primary,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              );
            }
          }
        }
      }

      if (i < sortedTypes.length - 1) {
        widgets.add(const Divider(height: 1));
      }
    }

    return ListView(children: widgets);
  }

  Widget _buildItemTile(NowItem item) {
    final age = _formatAge(item.timestamp);
    final settings =
        _nowService.getGroupSettings(item.appType, item.sourceId);

    // Dim items close to expiring (within 10% of TTL remaining)
    final isNearExpiry = settings.expiryMinutes > 0 &&
        DateTime.now().difference(item.timestamp).inMinutes >
            settings.expiryMinutes * 0.9;

    return ListTile(
      dense: true,
      leading: _buildPriorityDot(item.priority),
      title: Text(
        item.callsign,
        style: TextStyle(
          fontWeight: item.isRead ? FontWeight.normal : FontWeight.bold,
          fontSize: 14,
          color: isNearExpiry
              ? Theme.of(context).colorScheme.onSurface.withAlpha(100)
              : null,
        ),
      ),
      subtitle: Text(
        item.summary,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: item.isRead ? FontWeight.normal : FontWeight.w500,
          fontSize: 13,
          color: isNearExpiry
              ? Theme.of(context).colorScheme.onSurface.withAlpha(80)
              : null,
        ),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            age,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurface.withAlpha(150),
            ),
          ),
          if (!item.isRead)
            Container(
              margin: const EdgeInsets.only(top: 4),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
      onTap: () {
        _nowService.markAsRead(item.id);
        _navigateToSource(item);
      },
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
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  void _navigateToSource(NowItem item) {
    switch (item.appType) {
      case 'chat':
        Navigator.pushNamed(context, '/chat', arguments: item.sourceId);
        break;
      case 'irc':
        // sourceId is "serverId:channel"
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
                // Mute toggle
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
                // Max items slider
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
                // Expiry slider
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
                  max: 168, // 7 days
                  divisions: 168,
                  onChanged: (v) =>
                      setSheetState(() => expiryHours = v),
                ),
                const SizedBox(height: 16),
                // Save button
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
      case 'dm':
        return Icons.message;
      case 'alert':
        return Icons.campaign;
      case 'irc':
        return Icons.tag;
      default:
        return getAppTypeIcon(appType);
    }
  }

  String _getAppTypeLabel(String appType) {
    final key = 'app_type_$appType';
    final translated = _i18n.t(key);
    if (translated != key) return translated;

    switch (appType) {
      case 'dm':
        return 'Direct Messages';
      case 'alert':
        return 'Alerts';
      case 'irc':
        return 'IRC';
      default:
        return appType[0].toUpperCase() + appType.substring(1);
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
