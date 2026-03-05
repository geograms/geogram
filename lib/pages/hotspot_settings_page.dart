import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/hotspot_portal_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/station_node_service.dart';
import '../services/update_service.dart';
import '../services/wifi_direct_service.dart';

/// Settings page for Wi-Fi Direct hotspot + captive portal.
///
/// Single page — hotspot toggle, Wi-Fi QR code, portal status/QR.
/// Portal auto-enables when hotspot is turned on and auto-disables when off.
class HotspotSettingsPage extends StatefulWidget {
  const HotspotSettingsPage({super.key});

  @override
  State<HotspotSettingsPage> createState() => _HotspotSettingsPageState();
}

class _HotspotSettingsPageState extends State<HotspotSettingsPage> {
  final I18nService _i18n = I18nService();
  final WifiDirectService _wifiDirectService = WifiDirectService();
  final HotspotPortalService _portalService = HotspotPortalService();
  final StationNodeService _stationNodeService = StationNodeService();

  // Hotspot state
  bool _hotspotEnabled = false;
  String? _hotspotSsid;
  String? _hotspotPassword;
  int _hotspotClients = 0;
  bool _hotspotLoading = false;

  @override
  void initState() {
    super.initState();
    _checkHotspotStatus();
  }

  Future<void> _checkHotspotStatus() async {
    if (!WifiDirectService.isSupported) return;

    final enabled = await _wifiDirectService.isHotspotEnabled();
    if (enabled) {
      final info = await _wifiDirectService.getHotspotInfo();
      if (mounted && info != null) {
        setState(() {
          _hotspotEnabled = true;
          _hotspotSsid = info['ssid'] as String?;
          _hotspotPassword = info['passphrase'] as String?;
          _hotspotClients = (info['clientCount'] as int?) ?? 0;
        });

        // Auto-start portal DNS if hotspot is already running
        if (!_portalService.isActive) {
          try {
            await _portalService.start(
                stationName: _hotspotSsid ?? 'Geogram');
            if (mounted) setState(() {});
          } catch (e) {
            LogService().log('Portal auto-start failed: $e');
          }
        }
      }
    }
  }

  Future<void> _toggleHotspot(bool enabled) async {
    setState(() => _hotspotLoading = true);

    try {
      if (enabled) {
        final locationStatus = await Permission.location.request();
        if (!locationStatus.isGranted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Location permission required for Wi-Fi Direct'),
              ),
            );
          }
          return;
        }

        // Android 13+ requires NEARBY_WIFI_DEVICES
        await Permission.nearbyWifiDevices.request();

        final node = _stationNodeService.stationNode;
        final stationName = node?.name ?? node?.callsign ?? 'Geogram';
        final info = await _wifiDirectService.enableHotspot(stationName);
        if (info != null && mounted) {
          setState(() {
            _hotspotEnabled = true;
            _hotspotSsid = info['ssid'] as String?;
            _hotspotPassword = info['passphrase'] as String?;
            _hotspotClients = (info['clientCount'] as int?) ?? 0;
          });

          // Auto-start portal (DNS only — HTTP routes via LogApiService)
          try {
            await _portalService.start(stationName: stationName);
          } catch (e) {
            LogService().log('Portal auto-start failed: $e');
          }

          // Ensure platform binaries are downloaded for the download page
          UpdateService().ensureBinariesMirrored();

          if (mounted) setState(() {});
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to enable hotspot')),
          );
        }
      } else {
        // Stop portal first, then hotspot
        if (_portalService.isActive) {
          await _portalService.stop();
        }
        final success = await _wifiDirectService.disableHotspot();
        if (mounted) {
          if (success) {
            setState(() {
              _hotspotEnabled = false;
              _hotspotSsid = null;
              _hotspotPassword = null;
              _hotspotClients = 0;
            });
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to disable hotspot')),
            );
          }
        }
      }
    } catch (e) {
      LogService().log('Error toggling hotspot: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _hotspotLoading = false);
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final portalUrl =
        'http://${HotspotPortalService.defaultGatewayIp}:${HotspotPortalService.portalPort}/';

    return Scaffold(
      appBar: AppBar(title: Text(_i18n.t('hotspot'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Hotspot toggle card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.wifi_tethering,
                        color: _hotspotEnabled ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Wi-Fi Hotspot',
                          style: TextStyle(fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_hotspotLoading)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Switch(
                          value: _hotspotEnabled,
                          onChanged: _toggleHotspot,
                        ),
                    ],
                  ),
                  if (_hotspotEnabled) ...[
                    const SizedBox(height: 12),
                    _buildInfoRow('SSID', _hotspotSsid ?? 'Loading...'),
                    const SizedBox(height: 4),
                    _buildInfoRow('Password', _hotspotPassword ?? '...'),
                    const SizedBox(height: 4),
                    _buildInfoRow('Clients', '$_hotspotClients connected'),
                  ] else ...[
                    const SizedBox(height: 8),
                    Text(
                      'Enable to create a hotspot that other devices can '
                      'connect to directly.',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Wi-Fi QR code card (visible when hotspot is on)
          if (_hotspotEnabled &&
              _hotspotSsid != null &&
              _hotspotPassword != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text(
                      'Scan to connect',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: QrImageView(
                        data:
                            'WIFI:T:WPA;S:$_hotspotSsid;P:$_hotspotPassword;;',
                        version: QrVersions.auto,
                        size: 200,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _copyToClipboard(
                            'SSID: $_hotspotSsid\nPassword: $_hotspotPassword',
                          ),
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy credentials'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          // Portal status + QR (visible when hotspot is on)
          if (_hotspotEnabled) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.language,
                          color: _portalService.isActive
                              ? Colors.green
                              : Colors.grey,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Captive Portal',
                            style: TextStyle(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildStatusRow(
                      'Portal Routes',
                      _portalService.isActive ? 'Active' : 'Inactive',
                      _portalService.isActive ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(height: 4),
                    _buildStatusRow(
                      'DNS Responder',
                      _portalService.isDnsRunning ? 'Running' : 'Unavailable',
                      _portalService.isDnsRunning
                          ? Colors.green
                          : Colors.orange,
                    ),
                  ],
                ),
              ),
            ),

            // Portal QR code card
            if (_portalService.isActive)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Text(
                        'Portal URL',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: QrImageView(
                          data: portalUrl,
                          version: QrVersions.auto,
                          size: 200,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        portalUrl,
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey[600]),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => _copyToClipboard(portalUrl),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy URL'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────

  Widget _buildInfoRow(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                  child: Text(value, style: const TextStyle(fontSize: 13))),
              if (label == 'SSID' || label == 'Password')
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: () => _copyToClipboard(value),
                  tooltip: 'Copy',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatusRow(String label, String value, Color statusColor) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: statusColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ),
        Text(value, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}
