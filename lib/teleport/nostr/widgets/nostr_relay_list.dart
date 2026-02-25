/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Widget showing relay list for NOSTR settings page.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../nostr_client_service.dart';
import '../models/nostr_relay_config.dart';

class NostrRelayList extends StatefulWidget {
  final VoidCallback? onAddRelay;

  const NostrRelayList({super.key, this.onAddRelay});

  @override
  State<NostrRelayList> createState() => _NostrRelayListState();
}

class _NostrRelayListState extends State<NostrRelayList> {
  StreamSubscription<NostrClientEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _eventSub = NostrClientService().events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = NostrClientService();
    final relays = service.relays;
    final theme = Theme.of(context);

    if (relays.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.hub_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'No relays configured',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (widget.onAddRelay != null)
              FilledButton.icon(
                onPressed: widget.onAddRelay,
                icon: const Icon(Icons.add),
                label: const Text('Add Relay'),
              ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: relays.length,
      itemBuilder: (context, index) => _buildRelayCard(relays[index], theme),
    );
  }

  Widget _buildRelayCard(NostrRelayConfig config, ThemeData theme) {
    final service = NostrClientService();
    final connected = service.isConnected(config.id);
    final isActive = service.isClientActive(config.id);
    final isConnecting = isActive && !connected;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Status dot
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: connected
                          ? Colors.green
                          : isConnecting
                              ? Colors.orange
                              : Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          config.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          config.url,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Read/Write toggles
              Row(
                children: [
                  _buildToggle('Read', config.read, (v) {
                    service.updateRelay(config.copyWith(read: v));
                  }),
                  const SizedBox(width: 16),
                  _buildToggle('Write', config.write, (v) {
                    service.updateRelay(config.copyWith(write: v));
                  }),
                  const Spacer(),
                  // Connect/disconnect
                  OutlinedButton.icon(
                    onPressed: () {
                      if (connected || isConnecting) {
                        service.disconnect(config.id);
                      } else {
                        service.connect(config.id);
                      }
                    },
                    icon: Icon(
                      connected || isConnecting ? Icons.link_off : Icons.link,
                      size: 18,
                    ),
                    label: Text(
                      connected
                          ? 'Disconnect'
                          : isConnecting
                              ? 'Connecting...'
                              : 'Connect',
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.delete, size: 20),
                    tooltip: 'Remove',
                    onPressed: () => _confirmRemove(config),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(width: 4),
        SizedBox(
          height: 24,
          child: Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }

  void _confirmRemove(NostrRelayConfig config) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Relay'),
        content: Text('Remove ${config.name} (${config.url})?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              NostrClientService().removeRelay(config.id);
              Navigator.pop(ctx);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}
