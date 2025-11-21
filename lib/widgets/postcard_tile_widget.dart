/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/postcard.dart';
import '../services/i18n_service.dart';

/// Widget for displaying a postcard in the list
class PostcardTileWidget extends StatelessWidget {
  final Postcard postcard;
  final bool isSelected;
  final VoidCallback onTap;

  const PostcardTileWidget({
    Key? key,
    required this.postcard,
    required this.isSelected,
    required this.onTap,
  }) : super(key: key);

  Color _getStatusColor(String status, ThemeData theme) {
    switch (status) {
      case 'in-transit':
        return Colors.blue;
      case 'delivered':
        return Colors.green;
      case 'acknowledged':
        return Colors.purple;
      case 'expired':
        return Colors.red;
      default:
        return theme.colorScheme.onSurfaceVariant;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'in-transit':
        return Icons.local_shipping_outlined;
      case 'delivered':
        return Icons.done;
      case 'acknowledged':
        return Icons.done_all;
      case 'expired':
        return Icons.error_outline;
      default:
        return Icons.mail_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();

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
              // Title and status badge
              Row(
                children: [
                  Expanded(
                    child: Text(
                      postcard.title,
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
                  const SizedBox(width: 8),
                  // Status badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: _getStatusColor(postcard.status, theme).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _getStatusIcon(postcard.status),
                          size: 12,
                          color: _getStatusColor(postcard.status, theme),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          i18n.t(postcard.status.replaceAll('-', '_')),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: _getStatusColor(postcard.status, theme),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Sender and recipient
              Row(
                children: [
                  Icon(
                    Icons.send,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    postcard.senderCallsign,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.arrow_forward,
                    size: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.person_outline,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      postcard.recipientCallsign ?? postcard.recipientNpub.substring(0, 12),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Date and type
              Row(
                children: [
                  Icon(
                    Icons.calendar_today,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    postcard.displayDate,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    postcard.isEncrypted ? Icons.lock : Icons.lock_open,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    i18n.t(postcard.type),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              // Journey info (stamps count)
              if (postcard.stamps.isNotEmpty || postcard.returnStamps.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    // Forward journey stamps
                    if (postcard.stamps.isNotEmpty) ...[
                      Icon(
                        Icons.route,
                        size: 14,
                        color: Colors.blue,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${postcard.stamps.length} ${postcard.stamps.length == 1 ? i18n.t('hop') : i18n.t('hops')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    // Return journey stamps
                    if (postcard.returnStamps.isNotEmpty) ...[
                      Icon(
                        Icons.keyboard_return,
                        size: 14,
                        color: Colors.orange,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${postcard.returnStamps.length} ${i18n.t('return')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
              // Priority and TTL badges
              if (postcard.priority != 'normal' || postcard.ttl != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    // Priority badge
                    if (postcard.priority != 'normal') ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: postcard.priority == 'urgent'
                              ? Colors.red.withOpacity(0.2)
                              : Colors.amber.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              postcard.priority == 'urgent'
                                  ? Icons.priority_high
                                  : Icons.flag,
                              size: 10,
                              color: postcard.priority == 'urgent'
                                  ? Colors.red
                                  : Colors.amber,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              i18n.t(postcard.priority),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: postcard.priority == 'urgent'
                                    ? Colors.red
                                    : Colors.amber,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    // TTL badge
                    if (postcard.ttl != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.hourglass_bottom,
                              size: 10,
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${postcard.ttl}${i18n.t('days_short')}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSecondaryContainer,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
