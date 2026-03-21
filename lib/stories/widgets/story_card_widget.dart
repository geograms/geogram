/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/i18n_service.dart';
import '../models/story.dart';
import '../services/quiz_state_store.dart';
import '../services/stories_storage_service.dart';

/// Card widget for displaying a story in the grid
class StoryCardWidget extends StatefulWidget {
  final Story story;
  final StoriesStorageService storage;
  final I18nService i18n;
  final QuizStateStore? quizStore;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;

  const StoryCardWidget({
    super.key,
    required this.story,
    required this.storage,
    required this.i18n,
    this.quizStore,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onRename,
    required this.onDuplicate,
  });

  @override
  State<StoryCardWidget> createState() => _StoryCardWidgetState();
}

class _StoryCardWidgetState extends State<StoryCardWidget> {
  String? _thumbnailPath;
  String? _blurredPath;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    // Load both clear and blurred thumbnails in parallel
    final results = await Future.wait([
      widget.storage.extractThumbnail(widget.story),
      widget.storage.extractBlurredThumbnail(widget.story),
    ]);
    if (mounted) {
      setState(() {
        _thumbnailPath = results[0];
        _blurredPath = results[1];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail area
            Expanded(
              flex: 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Background/thumbnail — show blurred if quiz unsolved
                  if (_thumbnailPath != null)
                    Image.file(
                      File(_pickThumbnail()),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildPlaceholder(colorScheme),
                    )
                  else
                    _buildPlaceholder(colorScheme),

                  // Play button overlay
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.surface.withValues(alpha: 0.8),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.play_arrow,
                        color: colorScheme.primary,
                        size: 32,
                      ),
                    ),
                  ),

                  // Restart quiz button (shown on solved quiz stories)
                  if (_isQuizSolved)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: GestureDetector(
                        onTap: _resetQuiz,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: colorScheme.surface.withValues(alpha: 0.8),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.refresh,
                            size: 18,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),

                  // Menu button
                  Positioned(
                    top: 4,
                    right: 4,
                    child: PopupMenuButton<String>(
                      icon: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: colorScheme.surface.withValues(alpha: 0.8),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.more_vert,
                          size: 20,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      onSelected: (value) {
                        switch (value) {
                          case 'edit':
                            widget.onEdit();
                            break;
                          case 'rename':
                            widget.onRename();
                            break;
                          case 'duplicate':
                            widget.onDuplicate();
                            break;
                          case 'delete':
                            widget.onDelete();
                            break;
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'edit',
                          child: ListTile(
                            leading: Icon(Icons.edit),
                            title: Text('Edit'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'rename',
                          child: ListTile(
                            leading: Icon(Icons.drive_file_rename_outline),
                            title: Text('Rename'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'duplicate',
                          child: ListTile(
                            leading: Icon(Icons.copy),
                            title: Text('Duplicate'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            leading: Icon(Icons.delete, color: colorScheme.error),
                            title: Text('Delete', style: TextStyle(color: colorScheme.error)),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Info area
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.story.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // Flexible middle section that can shrink
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.story.description != null) ...[
                            const SizedBox(height: 4),
                            Flexible(
                              child: Text(
                                widget.story.description!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurface.withValues(alpha: 0.7),
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          if (widget.story.tags.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 4,
                              runSpacing: 2,
                              children: widget.story.tags.take(3).map((tag) {
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    widget.i18n.get('category_$tag', 'stories'),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: colorScheme.onPrimaryContainer,
                                      fontSize: 10,
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.access_time,
                          size: 14,
                          color: colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatDate(widget.story.modified),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Whether this story has a quiz and it's been solved.
  bool get _isQuizSolved =>
      _blurredPath != null &&
      (widget.quizStore?.isStorySolved(widget.story.id) ?? false);

  /// Reset quiz state and switch back to blurred thumbnail.
  void _resetQuiz() {
    widget.quizStore?.clearStory(widget.story.id);
    setState(() {});
  }

  /// Pick the right thumbnail: blurred if quiz unsolved, clear otherwise.
  /// The presence of a blur asset in the NDF is the signal that the story has a quiz.
  String _pickThumbnail() {
    if (_blurredPath != null) {
      final solved = widget.quizStore?.isStorySolved(widget.story.id) ?? false;
      if (!solved) return _blurredPath!;
    }
    return _thumbnailPath!;
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary.withValues(alpha: 0.3),
            colorScheme.secondary.withValues(alpha: 0.3),
          ],
        ),
      ),
      child: Icon(
        Icons.auto_stories,
        size: 48,
        color: colorScheme.onSurface.withValues(alpha: 0.3),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      return 'Today';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return '${diff.inDays} days ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
