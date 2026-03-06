/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Meshtastic node card — long name, short name, hw model, last heard,
 * battery, position info.
 */

import 'package:flutter/material.dart';

import '../models/meshtastic_node.dart';

class MeshtasticNodeCard extends StatelessWidget {
  final MeshtasticNode node;
  final bool isMyNode;

  const MeshtasticNodeCard({
    super.key,
    required this.node,
    this.isMyNode = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Node icon
              CircleAvatar(
                backgroundColor: isMyNode
                    ? const Color(0xFF67EA94).withValues(alpha: 0.15)
                    : theme.colorScheme.primaryContainer,
                child: Text(
                  node.shortName.isNotEmpty
                      ? node.shortName
                      : '?',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isMyNode
                        ? const Color(0xFF67EA94)
                        : theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Node info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            node.displayName,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isMyNode) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFF67EA94)
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'You',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xFF67EA94),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // Battery / last heard
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (node.batteryLevel > 0)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _batteryIcon,
                          size: 16,
                          color: _batteryColor,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${node.batteryLevel}%',
                          style: TextStyle(
                            fontSize: 11,
                            color: _batteryColor,
                          ),
                        ),
                      ],
                    ),
                  if (node.lastHeard > 0)
                    Text(
                      _lastHeardText,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
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

  String get _subtitle {
    final parts = <String>[];
    if (node.userId.isNotEmpty) parts.add(node.userId);
    if (node.hasPosition) {
      parts.add(
          '${node.latitude!.toStringAsFixed(4)}, ${node.longitude!.toStringAsFixed(4)}');
    }
    if (node.snr != 0) parts.add('SNR: ${node.snr.toStringAsFixed(1)}');
    return parts.isEmpty ? '!${node.nodeNumHex}' : parts.join(' | ');
  }

  String get _lastHeardText {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      node.lastHeard * 1000,
      isUtc: true,
    ).toLocal();
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  IconData get _batteryIcon {
    if (node.batteryLevel > 80) return Icons.battery_full;
    if (node.batteryLevel > 50) return Icons.battery_5_bar;
    if (node.batteryLevel > 20) return Icons.battery_3_bar;
    return Icons.battery_1_bar;
  }

  Color get _batteryColor {
    if (node.batteryLevel > 50) return Colors.green;
    if (node.batteryLevel > 20) return Colors.orange;
    return Colors.red;
  }
}
