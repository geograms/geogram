/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Meshtastic settings page — transport selector (BLE/MQTT/HTTP),
 * BLE scan/connect, channel list with PSK, region selection.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/i18n_service.dart';
import '../meshtastic_ble_client.dart';
import '../meshtastic_service.dart';
import '../models/meshtastic_config.dart';

class MeshtasticSettingsPage extends StatefulWidget {
  final String appPath;

  const MeshtasticSettingsPage({super.key, required this.appPath});

  @override
  State<MeshtasticSettingsPage> createState() => _MeshtasticSettingsPageState();
}

class _MeshtasticSettingsPageState extends State<MeshtasticSettingsPage> {
  final _service = MeshtasticService();
  StreamSubscription<MeshtasticEvent>? _eventSub;
  bool _isScanning = false;
  List<MeshtasticScanResult> _scanResults = [];

  static const _brandColor = Color(0xFF67EA94);

  static const _regions = [
    'US', 'EU_868', 'EU_433', 'CN', 'JP', 'ANZ', 'KR', 'TW', 'RU',
    'IN', 'NZ_865', 'TH', 'LORA_24', 'UA_433', 'UA_868', 'MY_433',
    'MY_919', 'SG_923',
  ];

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
      _scanResults = await _service.scanForDevices();
    } catch (_) {}
    if (mounted) setState(() => _isScanning = false);
  }

  Future<void> _connectToDevice(MeshtasticScanResult result) async {
    await _service.connectBle(result.device);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = _service.config;
    final isConnected = _service.isConnected;

    return Scaffold(
      appBar: AppBar(
        title: Text(I18nService().t('meshtastic_settings_title')),
      ),
      body: ListView(
        children: [
          // Transport selector
          _sectionHeader(
              I18nService().t('meshtastic_transport_section'), theme),
          _buildTransportSelector(config, theme),

          const Divider(),

          // BLE section
          _sectionHeader(I18nService().t('meshtastic_ble_section'), theme),
          ListTile(
            leading: const Icon(Icons.bluetooth_searching),
            title: Text(I18nService().t('meshtastic_scan_devices')),
            subtitle: Text(isConnected
                ? I18nService().t('meshtastic_connected_status')
                : I18nService().t('meshtastic_not_connected')),
            trailing: _isScanning
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.search),
            onTap: _isScanning ? null : _scan,
          ),

          if (isConnected)
            ListTile(
              leading: const Icon(Icons.bluetooth_disabled),
              title: Text(I18nService().t('meshtastic_disconnect_btn')),
              onTap: () async {
                await _service.disconnectBle();
                if (mounted) setState(() {});
              },
            ),

          // Scan results
          if (_scanResults.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                I18nService().t('meshtastic_discovered_devices'),
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
                  onPressed: () => _connectToDevice(result),
                  style: FilledButton.styleFrom(
                    backgroundColor: _brandColor,
                    foregroundColor: Colors.black,
                  ),
                  child: Text(I18nService().t('connect')),
                ),
              ),
          ],

          const Divider(),

          // Channels section
          _sectionHeader(
              I18nService().t('meshtastic_channels_section'), theme),
          if (_service.channels.isEmpty)
            ListTile(
              leading: const Icon(Icons.tag),
              title: Text(I18nService().t('meshtastic_no_channels')),
              subtitle: Text(
                  I18nService().t('meshtastic_connect_for_channels')),
            )
          else
            for (final ch in _service.channels)
              ListTile(
                leading: Icon(
                  Icons.tag,
                  color: ch.role.name == 'primary' ? _brandColor : null,
                ),
                title: Text(ch.displayName),
                subtitle: Text(
                  '${ch.role.name} | PSK: ${ch.psk.isEmpty ? "none" : "${ch.psk.length} bytes"}',
                ),
              ),

          const Divider(),

          // Region
          _sectionHeader(I18nService().t('meshtastic_region_section'), theme),
          ListTile(
            leading: const Icon(Icons.public),
            title: Text(I18nService().t('meshtastic_region_label')),
            subtitle: Text(config?.region ?? 'US'),
            trailing: DropdownButton<String>(
              value: config?.region ?? 'US',
              underline: const SizedBox.shrink(),
              onChanged: (val) {
                if (val != null && config != null) {
                  _service.updateConfig(config.copyWith(region: val));
                }
              },
              items: _regions
                  .map((r) =>
                      DropdownMenuItem(value: r, child: Text(r)))
                  .toList(),
            ),
          ),

          const Divider(),

          // MQTT section (Phase 2 — shown but disabled)
          _sectionHeader('MQTT (Coming Soon)', theme),
          ListTile(
            enabled: false,
            leading: const Icon(Icons.cloud),
            title: const Text('mqtt.meshtastic.org'),
            subtitle: const Text('Phase 2 — Internet mesh access'),
          ),

          const Divider(),

          // HTTP section (Phase 3 — shown but disabled)
          _sectionHeader('WiFi/HTTP (Coming Soon)', theme),
          ListTile(
            enabled: false,
            leading: const Icon(Icons.wifi),
            title: const Text('WiFi-connected radio'),
            subtitle: const Text('Phase 3 — Same-network radio access'),
          ),

          const Divider(),

          // Auto-start
          SwitchListTile(
            secondary: const Icon(Icons.play_circle_outline),
            title: Text(I18nService().t('meshtastic_auto_start')),
            subtitle: Text(I18nService().t('meshtastic_auto_start_desc')),
            value: config?.autoStart ?? false,
            onChanged: (val) {
              if (config != null) {
                _service.updateConfig(config.copyWith(autoStart: val));
              }
            },
          ),

          const Divider(),

          // Log level
          _sectionHeader(
              I18nService().t('meshtastic_log_level_section'), theme),
          ListTile(
            leading: const Icon(Icons.bug_report),
            title: Text(I18nService().t('meshtastic_log_level_label')),
            subtitle: Text(I18nService().t('meshtastic_log_level_desc')),
            trailing: DropdownButton<MeshtasticLogLevel>(
              value: _service.logLevel,
              underline: const SizedBox.shrink(),
              onChanged: (val) {
                if (val != null) {
                  _service.setLogLevel(val);
                  setState(() {});
                }
              },
              items: MeshtasticLogLevel.values
                  .map((l) => DropdownMenuItem(
                        value: l,
                        child: Text(l.name.toUpperCase()),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransportSelector(
      MeshtasticConfig? config, ThemeData theme) {
    final active = config?.activeTransport ?? MeshtasticTransport.ble;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SegmentedButton<MeshtasticTransport>(
        segments: [
          ButtonSegment(
            value: MeshtasticTransport.ble,
            label: const Text('BLE'),
            icon: const Icon(Icons.bluetooth, size: 18),
          ),
          ButtonSegment(
            value: MeshtasticTransport.mqtt,
            label: const Text('MQTT'),
            icon: const Icon(Icons.cloud, size: 18),
            enabled: false, // Phase 2
          ),
          ButtonSegment(
            value: MeshtasticTransport.http,
            label: const Text('HTTP'),
            icon: const Icon(Icons.wifi, size: 18),
            enabled: false, // Phase 3
          ),
        ],
        selected: {active},
        onSelectionChanged: (selected) {
          if (config != null && selected.first == MeshtasticTransport.ble) {
            _service.updateConfig(
              config.copyWith(activeTransport: selected.first),
            );
          }
        },
        style: ButtonStyle(
          side: WidgetStateProperty.all(
            BorderSide(color: _brandColor.withValues(alpha: 0.3)),
          ),
        ),
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
