/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared chat UI utilities used by both Telegram and Signal teleport views.
 * Avoids duplicating the sender-color palette and date-separator widget.
 */

import 'package:flutter/material.dart';

/// Deterministic color for a sender name (consistent across messages).
/// Uses a 7-color palette shared by all teleport chat bubbles.
Color teleportSenderColor(String name) {
  const colors = [
    Color(0xFFE53935), // red
    Color(0xFF8E24AA), // purple
    Color(0xFF3949AB), // indigo
    Color(0xFF039BE5), // light blue
    Color(0xFF00897B), // teal
    Color(0xFF7CB342), // light green
    Color(0xFFFB8C00), // orange
  ];
  final hash = name.hashCode.abs();
  return colors[hash % colors.length];
}

/// Day separator widget shown between messages from different dates.
/// Pill-shaped centered label with natural date formatting.
class TeleportDateSeparator extends StatelessWidget {
  final DateTime date;

  const TeleportDateSeparator({super.key, required this.date});

  String _formatDate(DateTime utcDate) {
    final local = utcDate.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(local.year, local.month, local.day);

    final diff = today.difference(msgDay).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';

    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    if (local.year == now.year) {
      return '${months[local.month - 1]} ${local.day}';
    }
    return '${months[local.month - 1]} ${local.day}, ${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _formatDate(date),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
