/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/i18n_service.dart';
import '../util/event_activity_notifier.dart';
import '../util/event_bus.dart';

/// Widget for displaying an event in the list
class EventTileWidget extends StatefulWidget {
  final Event event;
  final bool isSelected;
  final VoidCallback onTap;
  final String? appPath;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  /// Whether this event is currently pinned to the top. The tile
  /// just renders the icon — the parent owns the storage so it can
  /// re-sort the list after a toggle.
  final bool isPinned;
  /// Fired when the user taps the pin icon. Null hides the icon.
  final VoidCallback? onTogglePin;
  /// Parent-supplied attention flag, normally derived from the
  /// browser-level NowService scan ([events_browser_page]'s
  /// `_attentionEventIds`). The tile shows the red dot when this is
  /// true even if its own on-disk scan returns zero — the on-disk
  /// scan can lag the live NowService set when a status file lands
  /// in a different tier of storage than the tile's reader sees.
  final bool hasParentAttention;

  const EventTileWidget({
    Key? key,
    required this.event,
    required this.isSelected,
    required this.onTap,
    this.appPath,
    this.onEdit,
    this.onDelete,
    this.isPinned = false,
    this.onTogglePin,
    this.hasParentAttention = false,
  }) : super(key: key);

  @override
  State<EventTileWidget> createState() => _EventTileWidgetState();
}

class _EventTileWidgetState extends State<EventTileWidget> {
  // Total unseen activity items on this event — pending access
  // requests + new comments + new likes — surfaced via the shared
  // [EventActivityNotifier]. The tile renders a small attention badge
  // whenever > 0 so the owner knows at a glance which events need
  // their attention.
  int _unseenActivity = 0;
  EventSubscription<NowItemEvent>? _itemSub;
  EventSubscription<NowGroupRemoveEvent>? _removeSub;

  @override
  void initState() {
    super.initState();
    _loadUnseenActivity();
    // Re-scan when this event's NowItems are added or cleared so the
    // badge appears the moment a new comment / like / contribution
    // lands and disappears the moment the owner clears them.
    _itemSub = EventBus().on<NowItemEvent>((e) {
      if (!EventActivityNotifier.ownedAppTypes.contains(e.appType)) return;
      if (e.sourceId != widget.event.id) return;
      _loadUnseenActivity();
    });
    _removeSub = EventBus().on<NowGroupRemoveEvent>((e) {
      if (!EventActivityNotifier.ownedAppTypes.contains(e.appType)) return;
      if (e.sourceId != widget.event.id) return;
      _loadUnseenActivity();
    });
  }

  @override
  void dispose() {
    _itemSub?.cancel();
    _removeSub?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant EventTileWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.id != widget.event.id ||
        oldWidget.event.visibility != widget.event.visibility ||
        oldWidget.appPath != widget.appPath) {
      _loadUnseenActivity();
    }
  }

  Future<void> _loadUnseenActivity() async {
    if (kIsWeb) return;
    final appPath = widget.appPath;
    if (appPath == null || appPath.isEmpty) return;
    if (widget.event.id.length < 4) return;
    try {
      final year = widget.event.id.substring(0, 4);
      final eventPath = '$appPath/$year/${widget.event.id}';
      final count =
          await EventActivityNotifier.countUnseenForEvent(eventPath);
      if (!mounted) return;
      if (count != _unseenActivity) {
        setState(() => _unseenActivity = count);
      }
    } catch (_) {
      // Corrupted / unreadable file — silently leave the badge off.
    }
  }

  String? _getThumbnailPath() {
    if (kIsWeb || widget.appPath == null) return null;
    if (!widget.event.hasFlyer) return null;
    final year = widget.event.id.substring(0, 4);
    return '${widget.appPath}/$year/${widget.event.id}/${widget.event.primaryFlyer}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();
    final thumbnailPath = _getThumbnailPath();
    final event = widget.event;
    final isSelected = widget.isSelected;
    final onTap = widget.onTap;
    final onEdit = widget.onEdit;
    final onDelete = widget.onDelete;

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withOpacity(0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Thumbnail
              if (thumbnailPath != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Image.file(
                      File(thumbnailPath),
                      fit: BoxFit.cover,
                      cacheWidth: 168,
                      cacheHeight: 168,
                      errorBuilder: (_, __, ___) => Container(
                        color: theme.colorScheme.surfaceVariant,
                        child: Icon(
                          Icons.event,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title and badges
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            event.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.w600,
                              color: isSelected
                                  ? theme.colorScheme.onPrimaryContainer
                                  : null,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        // Pin / unpin toggle — pinned events float
                        // to the top of the list. Tap is captured
                        // here so the parent ListTile.onTap doesn\'t
                        // also fire and open the event.
                        if (widget.onTogglePin != null)
                          SizedBox(
                            width: 32,
                            height: 32,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              iconSize: 18,
                              tooltip: widget.isPinned
                                  ? i18n.t('unpin')
                                  : i18n.t('pin'),
                              icon: Icon(
                                widget.isPinned
                                    ? Icons.push_pin
                                    : Icons.push_pin_outlined,
                                color: widget.isPinned
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                              onPressed: widget.onTogglePin,
                            ),
                          ),
                        const SizedBox(width: 4),
                        // Attention badge — shown whenever either the
                        // local on-disk scan finds unseen activity OR
                        // the browser page's NowService-driven set
                        // flags this event. Two sources because the
                        // on-disk scan can return 0 while NowService
                        // already has the live item (different storage
                        // tiers, different timing).
                        if (_unseenActivity > 0) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.error,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.notifications_active,
                                  size: 12,
                                  color: theme.colorScheme.onError,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '$_unseenActivity',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onError,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                        ] else if (widget.hasParentAttention) ...[
                          // Plain dot — no count, since the on-disk
                          // scan didn't surface a number. The event is
                          // known to need attention via NowService.
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.error,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        // Multi-day badge
                        if (event.isMultiDay)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '${event.numberOfDays}${i18n.t('days_short')}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSecondaryContainer,
                                fontSize: 10,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Author and date (only show author if not empty)
                    Row(
                      children: [
                        if (event.author.trim().isNotEmpty) ...[
                          Icon(
                            Icons.person_outline,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            event.author,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Icon(
                          Icons.calendar_today,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          event.displayDate,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Location
                    Row(
                      children: [
                        Icon(
                          event.isOnline ? Icons.language : Icons.place,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            event.locationName ?? event.location,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    // Engagement (likes, comments, registration)
                    if (event.likeCount > 0 || event.commentCount > 0 || event.goingCount > 0) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          // Likes
                          if (event.likeCount > 0) ...[
                            Icon(
                              Icons.favorite,
                              size: 14,
                              color: theme.colorScheme.error,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${event.likeCount}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          // Comments
                          if (event.commentCount > 0) ...[
                            Icon(
                              Icons.comment_outlined,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${event.commentCount}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          // Going
                          if (event.goingCount > 0) ...[
                            Icon(
                              Icons.check_circle,
                              size: 14,
                              color: Colors.green,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${event.goingCount} ${i18n.t('going')}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              // Three-dot menu for edit/delete
              if (onEdit != null || onDelete != null)
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  padding: EdgeInsets.zero,
                  onSelected: (value) {
                    if (value == 'edit' && onEdit != null) {
                      onEdit!();
                    } else if (value == 'delete' && onDelete != null) {
                      onDelete!();
                    }
                  },
                  itemBuilder: (context) => [
                    if (onEdit != null)
                      PopupMenuItem<String>(
                        value: 'edit',
                        child: Row(
                          children: [
                            const Icon(Icons.edit, size: 20),
                            const SizedBox(width: 12),
                            Text(i18n.t('edit')),
                          ],
                        ),
                      ),
                    if (onDelete != null)
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, size: 20, color: theme.colorScheme.error),
                            const SizedBox(width: 12),
                            Text(i18n.t('delete'), style: TextStyle(color: theme.colorScheme.error)),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
