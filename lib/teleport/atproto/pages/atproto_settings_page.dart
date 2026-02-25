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
  late final TextEditingController _pdsCtl;
  late final TextEditingController _appViewCtl;
  bool _enabled = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final cfg = AtprotoClientService().config;
    _pdsCtl = TextEditingController(text: cfg.pdsUrl);
    _appViewCtl = TextEditingController(text: cfg.appViewUrl);
    _enabled = cfg.enabled;
  }

  @override
  void dispose() {
    _pdsCtl.dispose();
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
            value: _enabled,
            title: const Text('Enable bridge'),
            subtitle: const Text(
              'Use teleport/atproto storage and background sync',
            ),
            onChanged: (value) => setState(() => _enabled = value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pdsCtl,
            decoration: const InputDecoration(
              labelText: 'PDS URL',
              hintText: 'http://127.0.0.1:8080',
              border: OutlineInputBorder(),
            ),
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
          FilledButton.icon(
            onPressed: _busy ? null : _login,
            icon: const Icon(Icons.login),
            label: const Text('Login'),
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
        pdsUrl: _pdsCtl.text.trim(),
        appViewUrl: _appViewCtl.text.trim(),
        enabled: _enabled,
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('AT Proto settings saved')));
      setState(() => _busy = false);
    }
  }

  Future<void> _login() async {
    setState(() => _busy = true);
    final service = AtprotoClientService();
    await _save();
    final ok = await service.login(
      identifier: service.config.identifier,
      password: service.config.password,
      allowAutoPasswordDiscovery: true,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Login successful' : 'Login failed')),
    );
    setState(() => _busy = false);
  }
}
