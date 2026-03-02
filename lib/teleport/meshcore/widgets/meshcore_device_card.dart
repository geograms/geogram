/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Scan result card showing BLE device name, RSSI, and connect button.
 */

import 'package:flutter/material.dart';

import '../meshcore_ble_client.dart';

class MeshCoreDeviceCard extends StatelessWidget {
  final MeshCoreScanResult device;
  final bool isConnecting;
  final VoidCallback onConnect;

  const MeshCoreDeviceCard({
    super.key,
    required this.device,
    this.isConnecting = false,
    required this.onConnect,
  });

  String _rssiLabel(int rssi) {
    if (rssi > -50) return 'Excellent';
    if (rssi > -70) return 'Good';
    if (rssi > -85) return 'Fair';
    return 'Weak';
  }

  IconData _rssiIcon(int rssi) {
    if (rssi > -50) return Icons.signal_cellular_4_bar;
    if (rssi > -70) return Icons.signal_cellular_alt;
    if (rssi > -85) return Icons.signal_cellular_alt_2_bar;
    return Icons.signal_cellular_alt_1_bar;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF00BCD4).withValues(alpha: 0.15),
          child: const Icon(Icons.radio, color: Color(0xFF00BCD4)),
        ),
        title: Text(
          device.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Row(
          children: [
            Icon(
              _rssiIcon(device.rssi),
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              '${device.rssi} dBm (${_rssiLabel(device.rssi)})',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        trailing: isConnecting
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : FilledButton(
                onPressed: onConnect,
                child: const Text('Connect'),
              ),
      ),
    );
  }
}
