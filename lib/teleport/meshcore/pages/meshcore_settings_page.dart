/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * MeshCore settings — BLE device scan/select, connection management.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/i18n_service.dart';
import '../meshcore_ble_client.dart';
import '../meshcore_service.dart';
import '../widgets/meshcore_device_card.dart';

class MeshCoreSettingsPage extends StatefulWidget {
  final String appPath;

  const MeshCoreSettingsPage({super.key, required this.appPath});

  @override
  State<MeshCoreSettingsPage> createState() => _MeshCoreSettingsPageState();
}

class _MeshCoreSettingsPageState extends State<MeshCoreSettingsPage> {
  final _service = MeshCoreService();
  List<MeshCoreScanResult>? _scanResults;
  bool _isScanning = false;
  String? _connectingDeviceId;
  StreamSubscription<MeshCoreEvent>? _eventSub;

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
    setState(() {
      _isScanning = true;
      _scanResults = null;
    });

    final results = await _service.scanForDevices();

    if (mounted) {
      setState(() {
        _isScanning = false;
        _scanResults = results;
      });
    }
  }

  Future<void> _connect(MeshCoreScanResult device) async {
    setState(() => _connectingDeviceId = device.device.remoteId.str);

    final success = await _service.connectToDevice(device.device);

    if (mounted) {
      setState(() => _connectingDeviceId = null);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connected to ${device.name}')),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect to ${device.name}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isConnected = _service.isConnected;
    final deviceInfo = _service.deviceInfo;

    return Scaffold(
      appBar: AppBar(title: Text(I18nService().t('meshcore_settings_title'))),
      body: ListView(
        children: [
          // Connection status
          if (isConnected && deviceInfo != null) ...[
            Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.bluetooth_connected,
                              color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            I18nService().t('meshcore_connected_status'),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _infoRow(I18nService().t('meshcore_device_label'), deviceInfo.name),
                      if (deviceInfo.firmwareVersion != null)
                        _infoRow(I18nService().t('meshcore_firmware_label'), deviceInfo.firmwareVersion!),
                      if (deviceInfo.boardModel != null)
                        _infoRow(I18nService().t('meshcore_board_label'), deviceInfo.boardModel!),
                      if (deviceInfo.frequencyMhz != null)
                        _infoRow(
                          I18nService().t('meshcore_frequency_label'),
                          '${deviceInfo.frequencyMhz!.toStringAsFixed(2)} MHz',
                        ),
                      if (deviceInfo.spreadingFactor != null)
                        _infoRow(I18nService().t('meshcore_sf_label'), '${deviceInfo.spreadingFactor}'),
                      if (deviceInfo.txPowerDbm != null)
                        _infoRow(I18nService().t('meshcore_tx_power_label'), '${deviceInfo.txPowerDbm} dBm'),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await _service.disconnectDevice();
                            if (mounted) setState(() {});
                          },
                          icon: const Icon(Icons.bluetooth_disabled),
                          label: Text(I18nService().t('meshcore_disconnect_btn')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ] else ...[
            // Scan section
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    I18nService().t('meshcore_find_device_title'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    I18nService().t('meshcore_scan_desc'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isScanning ? null : _scan,
                      icon: _isScanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.bluetooth_searching),
                      label: Text(_isScanning ? I18nService().t('meshcore_scanning') : I18nService().t('meshcore_scan_btn')),
                    ),
                  ),
                ],
              ),
            ),
            // Scan results
            if (_scanResults != null) ...[
              if (_scanResults!.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: Text(
                      I18nService().t('meshcore_no_devices_found'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else
                ...(_scanResults!.map(
                  (device) => MeshCoreDeviceCard(
                    device: device,
                    isConnecting:
                        _connectingDeviceId == device.device.remoteId.str,
                    onConnect: () => _connect(device),
                  ),
                )),
            ],
          ],
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(fontSize: 13)),
        ),
      ],
    ),
  );
}
