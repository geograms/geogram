/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BitChat settings page — identity, BLE toggle, geohash precision, keys.
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/i18n_service.dart';
import '../bitchat_ble_client.dart';
import '../bitchat_service.dart';
import '../models/bitchat_config.dart';

class BitchatSettingsPage extends StatefulWidget {
  final String appPath;

  const BitchatSettingsPage({super.key, required this.appPath});

  @override
  State<BitchatSettingsPage> createState() => _BitchatSettingsPageState();
}

class _BitchatSettingsPageState extends State<BitchatSettingsPage> {
  final _service = BitchatService();
  StreamSubscription<BitchatEvent>? _eventSub;
  bool _isScanning = false;
  List<BitchatBleScanResult> _scanResults = [];

  static const _brandColor = Color(0xFFFF9100);

  @override
  void initState() {
    super.initState();
    _eventSub = _service.events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _isScanning = true);
    try {
      _scanResults = await _service.scanForPeers();
    } catch (_) {}
    if (mounted) setState(() => _isScanning = false);
  }

  Future<void> _connectToPeer(BitchatBleScanResult result) async {
    await _service.connectToPeer(result.device);
    if (mounted) setState(() {});
  }

  void _editNickname() {
    final config = _service.config;
    if (config == null) return;

    final controller = TextEditingController(text: config.nickname);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(I18nService().t('bitchat_edit_nickname')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: InputDecoration(
            hintText: I18nService().t('bitchat_nickname_hint'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(I18nService().t('cancel')),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                _service.updateConfig(config.copyWith(nickname: name));
              }
              Navigator.pop(context);
            },
            child: Text(I18nService().t('save')),
          ),
        ],
      ),
    );
  }

  void _regenerateKeys() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(I18nService().t('bitchat_regenerate_keys_title')),
        content: Text(I18nService().t('bitchat_regenerate_keys_warning')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(I18nService().t('cancel')),
          ),
          TextButton(
            onPressed: () async {
              final config = _service.config;
              final newConfig = await BitchatConfig.generateNew(
                nickname: config?.nickname ?? 'anon',
              );
              await _service.updateConfig(
                newConfig.copyWith(
                  defaultGeohash: config?.defaultGeohash ?? '',
                  geohashPrecision: config?.geohashPrecision ?? 4,
                  bleEnabled: config?.bleEnabled ?? true,
                  autoStart: config?.autoStart ?? false,
                ),
              );
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(
              I18nService().t('bitchat_regenerate'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = _service.config;
    final isConnected = _service.isConnected;

    return Scaffold(
      appBar: AppBar(
        title: Text(I18nService().t('bitchat_settings_title')),
      ),
      body: ListView(
        children: [
          // Identity section
          _sectionHeader(I18nService().t('bitchat_identity_section'), theme),
          ListTile(
            leading: const Icon(Icons.person),
            title: Text(I18nService().t('bitchat_nickname_label')),
            subtitle: Text(config?.nickname ?? 'anon'),
            trailing: const Icon(Icons.edit),
            onTap: _editNickname,
          ),
          if (config != null)
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: Text(I18nService().t('bitchat_fingerprint_label')),
              subtitle: Text(config.senderId),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: config.senderId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(I18nService().t('copied')),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ),
          ListTile(
            leading: const Icon(Icons.vpn_key),
            title: Text(I18nService().t('bitchat_regenerate_keys_title')),
            subtitle:
                Text(I18nService().t('bitchat_regenerate_keys_subtitle')),
            onTap: _regenerateKeys,
          ),

          const Divider(),

          // BLE section
          _sectionHeader(I18nService().t('bitchat_ble_section'), theme),
          SwitchListTile(
            secondary: const Icon(Icons.bluetooth),
            title: Text(I18nService().t('bitchat_ble_enabled')),
            value: config?.bleEnabled ?? true,
            onChanged: (val) {
              if (config != null) {
                _service.updateConfig(config.copyWith(bleEnabled: val));
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.bluetooth_searching),
            title: Text(I18nService().t('bitchat_scan_peers')),
            subtitle: Text(isConnected
                ? '${_service.connectedPeerCount} ${I18nService().t('bitchat_connected')}'
                : I18nService().t('bitchat_not_connected')),
            trailing: _isScanning
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.search),
            onTap: _isScanning ? null : _scan,
          ),

          // Scan results
          if (_scanResults.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                I18nService().t('bitchat_discovered_peers'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final result in _scanResults)
              ListTile(
                leading: Icon(Icons.bluetooth,
                    color: result.rssi > -70 ? _brandColor : Colors.grey),
                title: Text(result.name),
                subtitle: Text('RSSI: ${result.rssi} dBm'),
                trailing: FilledButton(
                  onPressed: () => _connectToPeer(result),
                  style: FilledButton.styleFrom(
                    backgroundColor: _brandColor,
                  ),
                  child: Text(I18nService().t('connect')),
                ),
              ),
          ],

          const Divider(),

          // Geohash section
          _sectionHeader(I18nService().t('bitchat_geohash_section'), theme),
          ListTile(
            leading: const Icon(Icons.location_on),
            title: Text(I18nService().t('bitchat_precision_label')),
            subtitle: Text(
                '${I18nService().t('bitchat_precision')}: ${config?.geohashPrecision ?? 4}'),
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: (config?.geohashPrecision ?? 4).toDouble(),
                min: 1,
                max: 8,
                divisions: 7,
                label: '${config?.geohashPrecision ?? 4}',
                activeColor: _brandColor,
                onChanged: (val) {
                  if (config != null) {
                    _service.updateConfig(
                      config.copyWith(geohashPrecision: val.round()),
                    );
                  }
                },
              ),
            ),
          ),
          if (_service.currentGeohash.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.tag),
              title: Text(I18nService().t('bitchat_current_channel')),
              subtitle: Text('#${_service.currentGeohash}'),
            ),

          const Divider(),

          // Auto-start
          SwitchListTile(
            secondary: const Icon(Icons.play_circle_outline),
            title: Text(I18nService().t('bitchat_auto_start')),
            subtitle: Text(I18nService().t('bitchat_auto_start_desc')),
            value: config?.autoStart ?? false,
            onChanged: (val) {
              if (config != null) {
                _service.updateConfig(config.copyWith(autoStart: val));
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: _brandColor,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
