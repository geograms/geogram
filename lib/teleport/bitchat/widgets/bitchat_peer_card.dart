/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BitChat peer card — peer identity display with verification status.
 */

import 'package:flutter/material.dart';

import '../models/bitchat_peer.dart';

class BitchatPeerCard extends StatelessWidget {
  final BitchatPeer peer;
  final VoidCallback? onTap;

  const BitchatPeerCard({super.key, required this.peer, this.onTap});

  static const _brandColor = Color(0xFFFF9100);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: peer.verified
            ? Colors.green.withValues(alpha: 0.15)
            : _brandColor.withValues(alpha: 0.15),
        child: Icon(
          peer.verified ? Icons.verified_user : Icons.person,
          color: peer.verified ? Colors.green : _brandColor,
          size: 20,
        ),
      ),
      title: Text(
        peer.displayName,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            peer.fingerprint,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (peer.lastSeen != null)
            Text(
              _formatLastSeen(peer.lastSeen!),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      trailing: peer.geohash.isNotEmpty
          ? Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _brandColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '#${peer.geohash}',
                style: const TextStyle(
                  fontSize: 10,
                  color: _brandColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            )
          : null,
      onTap: onTap,
    );
  }

  static String _formatLastSeen(DateTime dt) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(dt);

    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}';
  }
}
