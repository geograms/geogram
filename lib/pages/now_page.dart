/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'package:flutter/material.dart';
import '../models/now_item.dart';
import '../services/now_service.dart';
import '../services/i18n_service.dart';
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

    // Group items by appType
    final grouped = <String, List<NowItem>>{};
    for (final item in _items) {
      grouped.putIfAbsent(item.appType, () => []).add(item);
    }

    // Sort groups by best (lowest) priority in each group
    final sortedTypes = grouped.keys.toList()
      ..sort((a, b) {
        final aPriority = grouped[a]!.map((i) => i.priority).reduce((a, b) => a < b ? a : b);
        final bPriority = grouped[b]!.map((i) => i.priority).reduce((a, b) => a < b ? a : b);
        return aPriority.compareTo(bPriority);
      });

    return ListView.builder(
      itemCount: sortedTypes.length,
      itemBuilder: (context, sectionIndex) {
        final appType = sortedTypes[sectionIndex];
        final sectionItems = grouped[appType]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section header
            InkWell(
              onLongPress: () => _showMuteDialog(appType, sectionItems),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
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
                  ],
                ),
              ),
            ),
            // Items in section
            ...sectionItems.map((item) => _buildItemTile(item)),
            if (sectionIndex < sortedTypes.length - 1) const Divider(height: 1),
          ],
        );
      },
    );
  }

  Widget _buildItemTile(NowItem item) {
    final age = _formatAge(item.timestamp);

    return ListTile(
      dense: true,
      leading: _buildPriorityDot(item.priority),
      title: Text(
        item.callsign,
        style: TextStyle(
          fontWeight: item.isRead ? FontWeight.normal : FontWeight.bold,
          fontSize: 14,
        ),
      ),
      subtitle: Text(
        item.summary,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: item.isRead ? FontWeight.normal : FontWeight.w500,
          fontSize: 13,
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
    // Navigation is handled by appType + sourceId
    // For now, we navigate to the appropriate browser page
    switch (item.appType) {
      case 'chat':
      case 'irc':
        Navigator.pushNamed(context, '/chat', arguments: item.sourceId);
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
        // For unhandled types, just mark as read
        break;
    }
  }

  void _showMuteDialog(String appType, List<NowItem> items) {
    // Get unique sources in this section
    final sources = <String, String>{};
    for (final item in items) {
      sources[item.sourceId] = item.sourceName;
    }

    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: sources.entries.map((entry) {
            final isMuted = _nowService.isSourceMuted(appType, entry.key);
            return ListTile(
              leading: Icon(isMuted ? Icons.volume_off : Icons.volume_up),
              title: Text(entry.value.isNotEmpty ? entry.value : entry.key),
              subtitle: Text(
                isMuted ? _i18n.t('now_unmute_source') : _i18n.t('now_mute_source'),
              ),
              onTap: () {
                _nowService.toggleSourceMute(appType, entry.key);
                Navigator.pop(context);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  IconData _getAppTypeIcon(String appType) {
    // Map activity feed app types to icons, falling back to app_type_theme
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
    // Try i18n key first, then capitalize
    final key = 'app_type_$appType';
    final translated = _i18n.t(key);
    if (translated != key) return translated;

    // Fallback: capitalize
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
