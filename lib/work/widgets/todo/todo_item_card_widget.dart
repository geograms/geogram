/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../pages/photo_viewer_page.dart';
import '../../../services/i18n_service.dart';
import '../../models/todo_content.dart';
import '../../services/ndf_service.dart';

/// Widget for displaying a TODO item as an expandable card
class TodoItemCardWidget extends StatelessWidget {
  final TodoItem item;
  final bool isExpanded;
  final String ndfFilePath;
  final VoidCallback onToggleCompleted;
  final VoidCallback onToggleExpanded;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onAddPicture;
  final void Function(String) onRemovePicture;
  final VoidCallback onAddLink;
  final void Function(String) onRemoveLink;
  final void Function(TodoLink) onOpenLink;
  final VoidCallback onAddUpdate;
  final void Function(String) onRemoveUpdate;

  const TodoItemCardWidget({
    super.key,
    required this.item,
    required this.isExpanded,
    required this.ndfFilePath,
    required this.onToggleCompleted,
    required this.onToggleExpanded,
    required this.onEdit,
    required this.onDelete,
    required this.onAddPicture,
    required this.onRemovePicture,
    required this.onAddLink,
    required this.onRemoveLink,
    required this.onOpenLink,
    required this.onAddUpdate,
    required this.onRemoveUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          InkWell(
            onTap: onToggleExpanded,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Checkbox
                  Checkbox(
                    value: item.isCompleted,
                    onChanged: (_) => onToggleCompleted(),
                  ),
                  // Title and info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            decoration: item.isCompleted
                                ? TextDecoration.lineThrough
                                : null,
                            color: item.isCompleted
                                ? theme.colorScheme.onSurfaceVariant
                                : null,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            // Priority badge (only for non-normal)
                            if (item.priority != TodoPriority.normal)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: _getPriorityColor(item.priority).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _getPriorityIcon(item.priority),
                                      size: 12,
                                      color: _getPriorityColor(item.priority),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _getPriorityLabel(item.priority),
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: _getPriorityColor(item.priority),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            // Duration badge when completed
                            if (item.isCompleted && item.durationSummary != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.timer_outlined,
                                      size: 12,
                                      color: Colors.green.shade700,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      item.durationSummary!,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: Colors.green.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            // Pictures count
                            if (item.pictures.isNotEmpty) ...[
                              if (item.isCompleted && item.durationSummary != null)
                                const SizedBox(width: 8),
                              _buildBadge(
                                theme,
                                Icons.image_outlined,
                                '${item.pictures.length}',
                                Colors.blue,
                              ),
                            ],
                            // Updates count
                            if (item.updates.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              _buildBadge(
                                theme,
                                Icons.notes_outlined,
                                '${item.updates.length}',
                                Colors.orange,
                              ),
                            ],
                            // Links count
                            if (item.links.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              _buildBadge(
                                theme,
                                Icons.link,
                                '${item.links.length}',
                                Colors.purple,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Expand/collapse button
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          // Expanded content
          if (isExpanded) ...[
            const Divider(height: 1),
            _buildExpandedContent(context, theme, i18n),
          ],
        ],
      ),
    );
  }

  Widget _buildBadge(ThemeData theme, IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedContent(BuildContext context, ThemeData theme, I18nService i18n) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Description
          if (item.description != null && item.description!.isNotEmpty) ...[
            Text(
              item.description!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Pictures section
          _buildSectionHeader(
            context,
            theme,
            i18n.t('work_todo_pictures'),
            Icons.image_outlined,
            onAddPicture,
          ),
          if (item.pictures.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildPictureGrid(context, theme),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              i18n.t('work_todo_no_pictures'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Updates section
          _buildSectionHeader(
            context,
            theme,
            i18n.t('work_todo_updates'),
            Icons.notes_outlined,
            onAddUpdate,
          ),
          if (item.updates.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildUpdatesList(context, theme, i18n),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              i18n.t('work_todo_no_updates'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Links section
          _buildSectionHeader(
            context,
            theme,
            i18n.t('work_todo_links'),
            Icons.link,
            onAddLink,
          ),
          if (item.links.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildLinksList(context, theme),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              i18n.t('work_todo_no_links'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Action buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(i18n.t('edit')),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: onDelete,
                icon: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                label: Text(
                  i18n.t('delete'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    ThemeData theme,
    String title,
    IconData icon,
    VoidCallback onAdd,
  ) {
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.add, size: 20),
          onPressed: onAdd,
          visualDensity: VisualDensity.compact,
          tooltip: 'Add',
        ),
      ],
    );
  }

  Widget _buildPictureGrid(BuildContext context, ThemeData theme) {
    final ndfService = NdfService();

    return SizedBox(
      height: 80,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: item.pictures.length,
        itemBuilder: (context, index) {
          final path = item.pictures[index];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FutureBuilder<Uint8List?>(
              future: ndfService.readAsset(ndfFilePath, path),
              builder: (context, snapshot) {
                return Stack(
                  children: [
                    GestureDetector(
                      onTap: () => _openImageViewer(context, index),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: snapshot.hasData && snapshot.data != null
                            ? Image.memory(
                                snapshot.data!,
                                width: 80,
                                height: 80,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    width: 80,
                                    height: 80,
                                    color: theme.colorScheme.surfaceContainerHighest,
                                    child: const Icon(Icons.broken_image, color: Colors.grey),
                                  );
                                },
                              )
                            : Container(
                                width: 80,
                                height: 80,
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: const Center(
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface.withValues(alpha: 0.8),
                          shape: BoxShape.circle,
                        ),
                        child: InkWell(
                          onTap: () => onRemovePicture(path),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              size: 14,
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _openImageViewer(BuildContext context, int tappedIndex) async {
    final ndfService = NdfService();
    final tempPaths = <String>[];

    for (final picPath in item.pictures) {
      final tempPath = await ndfService.extractAssetToTemp(ndfFilePath, picPath);
      if (tempPath != null) {
        tempPaths.add(tempPath);
      }
    }

    if (tempPaths.isEmpty || !context.mounted) return;

    // Clamp index in case some extractions failed
    final safeIndex = tappedIndex.clamp(0, tempPaths.length - 1);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoViewerPage(
          imagePaths: tempPaths,
          initialIndex: safeIndex,
        ),
      ),
    );
  }

  Widget _buildUpdatesList(BuildContext context, ThemeData theme, I18nService i18n) {
    return Column(
      children: item.updates.map((update) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _formatDate(update.createdAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: () => onRemoveUpdate(update.id),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  update.content,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildLinksList(BuildContext context, ThemeData theme) {
    return Column(
      children: item.links.map((link) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.link,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: () => onOpenLink(link),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          link.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          link.url,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => onRemoveLink(link.id),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      size: 14,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        if (diff.inMinutes == 0) {
          return 'Just now';
        }
        return '${diff.inMinutes}m ago';
      }
      return '${diff.inHours}h ago';
    }
    if (diff.inDays == 1) {
      return 'Yesterday';
    }
    if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    }

    return '${date.day}/${date.month}/${date.year}';
  }

  String _getPriorityLabel(TodoPriority priority) {
    final i18n = I18nService();
    switch (priority) {
      case TodoPriority.high:
        return i18n.t('work_todo_priority_high');
      case TodoPriority.normal:
        return i18n.t('work_todo_priority_normal');
      case TodoPriority.low:
        return i18n.t('work_todo_priority_low');
    }
  }

  IconData _getPriorityIcon(TodoPriority priority) {
    switch (priority) {
      case TodoPriority.high:
        return Icons.keyboard_double_arrow_up;
      case TodoPriority.normal:
        return Icons.remove;
      case TodoPriority.low:
        return Icons.keyboard_double_arrow_down;
    }
  }

  Color _getPriorityColor(TodoPriority priority) {
    switch (priority) {
      case TodoPriority.high:
        return Colors.red;
      case TodoPriority.normal:
        return Colors.grey;
      case TodoPriority.low:
        return Colors.blue;
    }
  }
}
