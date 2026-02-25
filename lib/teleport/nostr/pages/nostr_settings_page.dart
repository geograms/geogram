/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NOSTR settings page — add/edit/remove relay configs, connect/disconnect.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../nostr_client_service.dart';
import '../models/nostr_relay_config.dart';
import '../widgets/nostr_relay_list.dart';

class NostrSettingsPage extends StatefulWidget {
  final String appPath;

  const NostrSettingsPage({super.key, required this.appPath});

  @override
  State<NostrSettingsPage> createState() => _NostrSettingsPageState();
}

class _NostrSettingsPageState extends State<NostrSettingsPage> {
  StreamSubscription<NostrClientEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _ensureDefaults();
    _eventSub = NostrClientService().events.listen((event) {
      if (mounted) setState(() {});
    });
  }

  /// Populate default relays if none are configured.
  void _ensureDefaults() {
    final service = NostrClientService();
    if (service.relays.isEmpty) {
      for (final relay in NostrRelayConfig.defaults) {
        service.addRelay(relay);
      }
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NOSTR Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Relay',
            onPressed: () => _showAddRelayDialog(context),
          ),
        ],
      ),
      body: NostrRelayList(
        onAddRelay: () => _showAddRelayDialog(context),
      ),
    );
  }

  void _showAddRelayDialog(BuildContext context) {
    final urlCtl = TextEditingController();
    String? urlError;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add Relay',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: urlCtl,
                  decoration: InputDecoration(
                    labelText: 'Relay URL',
                    hintText: 'wss://relay.example.com',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: urlError,
                  ),
                  autofocus: true,
                  onChanged: (_) {
                    if (urlError != null) setSheetState(() => urlError = null);
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        var url = urlCtl.text.trim();
                        if (url.isEmpty) {
                          setSheetState(() => urlError = 'URL is required');
                          return;
                        }
                        // Auto-prefix wss:// if missing
                        if (!url.startsWith('wss://') && !url.startsWith('ws://')) {
                          url = 'wss://$url';
                        }
                        // Validate URL format
                        final uri = Uri.tryParse(url);
                        if (uri == null || uri.host.isEmpty) {
                          setSheetState(() => urlError = 'Invalid URL');
                          return;
                        }
                        // Check for duplicates
                        final existing = NostrClientService().relays;
                        if (existing.any((r) => r.url == url)) {
                          setSheetState(() => urlError = 'Relay already added');
                          return;
                        }

                        final config = NostrRelayConfig(
                          id: NostrRelayConfig.idFromUrl(url),
                          url: url,
                          name: NostrRelayConfig.nameFromUrl(url),
                        );
                        NostrClientService().addRelay(config);
                        Navigator.pop(ctx);
                      },
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    ).then((_) {
      urlCtl.dispose();
    });
  }
}
