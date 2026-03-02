/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../../../services/i18n_service.dart';
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
      appBar: AppBar(title: Text(I18nService().t('atproto_settings_title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            value: true,
            title: Text(I18nService().t('atproto_enable_bridge')),
            subtitle: Text(
              I18nService().t('atproto_enable_bridge_desc'),
            ),
            onChanged: null,
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(I18nService().t('atproto_pds_url_label')),
            subtitle: Text(service.config.pdsUrl),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _appViewCtl,
            decoration: InputDecoration(
              labelText: I18nService().t('atproto_appview_url_label'),
              hintText: I18nService().t('atproto_appview_url_hint'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                I18nService().t('atproto_auth_desc'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save),
            label: Text(I18nService().t('atproto_save_settings_btn')),
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
                    ).showSnackBar(SnackBar(content: Text(I18nService().t('atproto_logged_out'))));
                    setState(() {});
                  },
            icon: const Icon(Icons.logout),
            label: Text(I18nService().t('atproto_logout_btn')),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                service.isAuthenticated
                    ? I18nService().t('atproto_authenticated_as', params: ['${service.session?.handle}', '${service.session?.did}'])
                    : I18nService().t('atproto_not_authenticated'),
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
      ).showSnackBar(SnackBar(content: Text(I18nService().t('atproto_settings_saved'))));
      setState(() => _busy = false);
    }
  }
}
