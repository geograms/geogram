/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/forum_thread.dart';

/// Widget for displaying the list of forum threads in a section
class ThreadListWidget extends StatelessWidget {
  final List<ForumThread> threads;
  final String? selectedThreadId;
  final Function(ForumThread) onThreadSelect;
  final VoidCallback onNewThread;
  final bool canCreateThread;
  final Function(ForumThread)? onThreadMenu;
  final bool Function(ForumThread)? canModerateThread;

  const ThreadListWidget({
    Key? key,
    required this.threads,
    this.selectedThreadId,
    required this.onThreadSelect,
    required this.onNewThread,
    this.canCreateThread = true,
    this.onThreadMenu,
    this.canModerateThread,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Threads are already sorted by compareTo (pinned first, then newest)
    final sortedThreads = List<ForumThread>.from(threads);
    sortedThreads.sort();

    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          right: BorderSide(
            color: theme.colorScheme.outlineVariant,
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          // Header with new thread button
          _buildHeader(theme),
          const Divider(height: 1),
          // Thread list
          Expanded(
            child: sortedThreads.isEmpty
                ? _buildEmptyState(theme)
                : ListView.builder(
                    itemCount: sortedThreads.length,
                    itemBuilder: (context, index) {
                      final thread = sortedThreads[index];
                      final isSelected = thread.id == selectedThreadId;

                      final showMenu = canModerateThread != null &&
                                       canModerateThread!(thread) &&
                                       onThreadMenu != null;

                      return _ThreadTile(
                        thread: thread,
                        isSelected: isSelected,
                        onTap: () => onThreadSelect(thread),
                        onMenu: showMenu ? () => onThreadMenu!(thread) : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// Build header with title and new thread button
  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(
            Icons.topic,
            color: theme.colorScheme.primary,
            size: 24,
          ),
          const SizedBox(width: 12),
          Text(
            'Threads',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          if (canCreateThread)
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: onNewThread,
              tooltip: 'New thread',
              iconSize: 24,
            ),
        ],
      ),
    );
  }

  /// Build empty state
  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.topic_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No threads yet',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (canCreateThread) ...[
              const SizedBox(height: 8),
              Text(
                'Start a new discussion',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Individual thread tile widget
class _ThreadTile extends StatelessWidget {
  final ForumThread thread;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onMenu;

  const _ThreadTile({
    required this.thread,
    required this.isSelected,
    required this.onTap,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withOpacity(0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Thread title with badges
              Row(
                children: [
                  Expanded(
                    child: Text(
                      thread.title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.w500,
                        color: isSelected
                            ? theme.colorScheme.onPrimaryContainer
                            : null,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Pinned badge
                  if (thread.isPinned)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(
                        Icons.push_pin,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  // Locked badge
                  if (thread.isLocked)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(
                        Icons.lock,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  // Settings menu button (admin/moderator only)
                  if (onMenu != null)
                    IconButton(
                      icon: Icon(
                        Icons.more_vert,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onPressed: onMenu,
                      tooltip: 'Thread options',
                      padding: const EdgeInsets.all(4),
                      constraints: const BoxConstraints(),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              // Thread metadata
              Text(
                thread.subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color:
                      theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
