/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../atproto_client_service.dart';

class AtprotoSettingsPage extends StatefulWidget {
  final String appPath;

  const AtprotoSettingsPage({super.key, required this.appPath});

  @override
  State<AtprotoSettingsPage> createState() => _AtprotoSettingsPageState();
}

class _AtprotoSettingsPageState extends State<AtprotoSettingsPage> {
  late final TextEditingController _appViewCtl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final cfg = AtprotoClientService().config;
    _appViewCtl = TextEditingController(text: cfg.appViewUrl);
  }

  @override
  void dispose() {
    _appViewCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = AtprotoClientService();

    return Scaffold(
      appBar: AppBar(title: const Text('AT Proto Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            value: true,
            title: const Text('Enable bridge'),
            subtitle: const Text(
              'Use teleport/atproto storage and background sync',
            ),
            onChanged: null,
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('PDS URL'),
            subtitle: Text(service.config.pdsUrl),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _appViewCtl,
            decoration: const InputDecoration(
              labelText: 'AppView URL',
              hintText: 'https://public.api.bsky.app',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Identifier and password are automatic.\n'
                'Identifier uses nickname (or callsign fallback).\n'
                'Password is generated and stored automatically.',
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save),
            label: const Text('Save Settings'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    await service.logout();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('Logged out')));
                    setState(() {});
                  },
            icon: const Icon(Icons.logout),
            label: const Text('Logout'),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                service.isAuthenticated
                    ? 'Authenticated as ${service.session?.handle} (${service.session?.did})'
                    : 'Not authenticated',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final service = AtprotoClientService();
    await service.saveConfig(
      service.config.copyWith(
        appViewUrl: _appViewCtl.text.trim(),
        enabled: true,
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('AT Proto settings saved')));
      setState(() => _busy = false);
    }
  }
}
