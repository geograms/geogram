/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/station_node.dart';
import 'package:http/http.dart' as http;
import '../services/station_node_service.dart';
import '../services/wifi_direct_service.dart';
import '../station.dart' show SslCertificateManager, ServerStats;
import '../services/i18n_service.dart';
import '../services/hotspot_portal_service.dart';
import '../services/log_service.dart';
import 'station_setup_root_page.dart';
import 'station_setup_remote_page.dart';
import 'station_metrics_page.dart';
import 'station_authorities_page.dart';

/// Dashboard for managing station node
class StationDashboardPage extends StatefulWidget {
  const StationDashboardPage({super.key});

  @override
  State<StationDashboardPage> createState() => _StationDashboardPageState();
}

class _StationDashboardPageState extends State<StationDashboardPage> {
  final StationNodeService _stationNodeService = StationNodeService();
  final I18nService _i18n = I18nService();
  final WifiDirectService _wifiDirectService = WifiDirectService();

  StreamSubscription<StationNode?>? _subscription;
  StationNode? _stationNode;
  List<StationNode> _remoteStations = [];
  bool _isLoading = true;
  bool _showSettings = false;

  // Wi-Fi Direct hotspot state
  bool _hotspotEnabled = false;
  String? _hotspotSsid;
  String? _hotspotPassword;
  int _hotspotClients = 0;
  bool _hotspotLoading = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _stationNodeService.initialize();

    _subscription = _stationNodeService.stateStream.listen((node) {
      if (mounted) {
        setState(() => _stationNode = node);
      }
    });

    // Check Wi-Fi Direct hotspot status on Android
    if (!kIsWeb && Platform.isAndroid) {
      _checkHotspotStatus();
    }

    setState(() {
      _stationNode = _stationNodeService.stationNode;
      _remoteStations = _stationNodeService.remoteStations;
      _isLoading = false;
    });
  }

  Future<void> _checkHotspotStatus() async {
    final enabled = await _wifiDirectService.isHotspotEnabled();
    if (enabled && _stationNode != null) {
      // Call enableHotspot to ensure the SSID matches the current station name
      // This will recreate the group if the name is wrong
      final stationName = _stationNode?.name ?? _stationNode?.callsign ?? 'Station';
      final info = await _wifiDirectService.enableHotspot(stationName);
      if (mounted && info != null) {
        setState(() {
          _hotspotEnabled = true;
          _hotspotSsid = info['ssid'] as String?;
          _hotspotPassword = info['passphrase'] as String?;
          _hotspotClients = (info['clientCount'] as int?) ?? 0;
        });

        // Auto-start portal DNS if hotspot already running
        final portal = HotspotPortalService();
        if (!portal.isActive) {
          try {
            await portal.start(stationName: stationName);
          } catch (e) {
            LogService().log('Portal auto-start failed: $e');
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text('Station')),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Show setup view only if no local station AND no remote stations
    if (_stationNode == null && _remoteStations.isEmpty) {
      return _buildSetupView();
    }

    return _buildDashboardView();
  }

  Widget _buildSetupView() {
    return Scaffold(
      appBar: AppBar(title: Text('Station')),
      body: Center(
        child: Container(
          constraints: BoxConstraints(maxWidth: 400),
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cell_tower, size: 80, color: Colors.grey),
              SizedBox(height: 24),
              Text(
                'Station Management',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              SizedBox(height: 8),
              Text(
                'Create a local station on this device or connect to a remote station server.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _createRootStation,
                icon: Icon(Icons.hub),
                label: Text('Create Local Station'),
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                ),
              ),
              SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _connectToRemoteStation,
                icon: Icon(Icons.cloud),
                label: Text('Connect to Remote Station'),
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDashboardView() {
    return Scaffold(
      appBar: AppBar(
        title: Text('Station'),
        actions: [
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: _toggleSettings,
            tooltip: 'Settings',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Main content
          SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Local station section (if exists)
                if (_stationNode != null && !_stationNode!.isRemote) ...[
                  _buildStatusCard(),
                  SizedBox(height: 16),
                  // Show URLs card only when server is actually running
                  if (_stationNodeService.stationServer?.isRunning == true) ...[
                    _buildUrlsCard(),
                    SizedBox(height: 16),
                  ],
                  // Wi-Fi Direct Hotspot card (Android only)
                  if (!kIsWeb && Platform.isAndroid) ...[
                    _buildWifiDirectCard(),
                    SizedBox(height: 16),
                  ],
                  // Connected Devices and Storage on same line
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _buildConnectedDevicesCard()),
                      SizedBox(width: 16),
                      Expanded(child: _buildStorageCard()),
                    ],
                  ),
                  SizedBox(height: 16),
                  _buildMetricsPreviewCard(),
                  SizedBox(height: 16),
                  _buildActionsCard(),
                ],
                // Remote stations section
                if (_remoteStations.isNotEmpty) ...[
                  if (_stationNode != null && !_stationNode!.isRemote)
                    SizedBox(height: 24),
                  _buildRemoteStationsSection(),
                ],
                // Add station button when no local station
                if (_stationNode == null && _remoteStations.isNotEmpty) ...[
                  SizedBox(height: 16),
                  _buildAddStationCard(),
                ],
              ],
            ),
          ),
          // Settings panel overlay
          if (_showSettings) ...[
            // Backdrop
            GestureDetector(
              onTap: () => setState(() => _showSettings = false),
              child: Container(
                color: Colors.black54,
              ),
            ),
            // Slide-in settings panel
            _buildSettingsPanel(),
          ],
        ],
      ),
    );
  }

  void _toggleSettings() {
    setState(() => _showSettings = !_showSettings);
  }

  Widget _buildSettingsPanel() {
    final screenHeight = MediaQuery.of(context).size.height;
    final panelHeight = screenHeight * 0.75;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: panelHeight,
      child: Material(
        elevation: 16,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              // Drag handle
              Container(
                margin: EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Panel header
              Container(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Text(
                      'Station Settings',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Spacer(),
                    IconButton(
                      icon: Icon(Icons.close),
                      onPressed: () => setState(() => _showSettings = false),
                    ),
                  ],
                ),
              ),
              Divider(height: 1),
              // Settings content
              Expanded(
                child: StationSettingsPanel(
                  stationNodeService: _stationNodeService,
                  onClose: () => setState(() => _showSettings = false),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRemoteStationsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'REMOTE STATIONS',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        SizedBox(height: 12),
        ..._remoteStations.map((remote) => _buildRemoteStationCard(remote)),
      ],
    );
  }

  Widget _buildRemoteStationCard(StationNode remote) {
    return Card(
      margin: EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud, color: Colors.blue, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    remote.name,
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'remove') {
                      _confirmRemoveRemoteStation(remote);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'remove',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline, color: Colors.red, size: 20),
                          SizedBox(width: 8),
                          Text('Remove', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SizedBox(height: 8),
            Text(
              remote.remoteUrl ?? 'No URL',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            SizedBox(height: 4),
            Text(
              'Callsign: ${remote.callsign}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddStationCard() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ADD LOCAL STATION', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text(
              'Create a station on this device to relay messages locally.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _createRootStation,
              icon: Icon(Icons.hub),
              label: Text('Create Local Station'),
            ),
          ],
        ),
      ),
    );
  }


  void _confirmRemoveRemoteStation(StationNode remote) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove Remote Station?'),
        content: Text(
          'This will remove "${remote.name}" from your list. '
          'The remote station server will continue running.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _stationNodeService.removeRemoteStation(remote.id);
              setState(() {
                _remoteStations = _stationNodeService.remoteStations;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Remote station removed')),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Remove'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    // Check actual server state, not just node status
    final server = _stationNodeService.stationServer;
    final isActuallyRunning = server != null && server.isRunning;
    final nodeThinkRunning = _stationNode!.isRunning;

    // Use actual server state for display
    final isRunning = isActuallyRunning;
    final statusColor = isRunning ? Colors.green : Colors.grey;

    // If there's a mismatch, update the node status
    if (nodeThinkRunning && !isActuallyRunning) {
      // Node thinks it's running but server isn't - this is the bug
      LogService().log('Station status mismatch: node thinks running but server is not');
    }

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'STATUS: ${isRunning ? "RUNNING" : "STOPPED"}',
                    style: TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Switch(
                  value: isRunning,
                  onChanged: _toggleStation,
                ),
              ],
            ),
            if (isRunning && server != null) ...[
              SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _buildInfoItem(
                      Icons.settings_ethernet,
                      'Port ${server.settings.httpPort}',
                    ),
                  ),
                  Expanded(
                    child: _buildInfoItem(
                      Icons.timer_outlined,
                      _formatUptime(_stationNode!.stats.uptime),
                    ),
                  ),
                ],
              ),
            ],
            if (_stationNode!.errorMessage != null)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Error: ${_stationNode!.errorMessage}',
                  style: TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoItem(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Colors.grey[600]),
        SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, color: Colors.grey[700]),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildUrlsCard() {
    final server = _stationNodeService.stationServer;
    if (server == null) return SizedBox.shrink();

    final httpPort = server.settings.httpPort;
    final httpsPort = server.settings.httpsPort;
    final enableSsl = server.settings.enableSsl;
    final sslDomain = server.settings.sslDomain;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.link, size: 20),
                SizedBox(width: 8),
                Text('Station URLs', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            SizedBox(height: 12),
            // Show LAN IPs only
            FutureBuilder<List<String>>(
              future: _getLocalIpAddresses(),
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return Text(
                    'No LAN address available',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  );
                }
                return Column(
                  children: snapshot.data!.map((ip) => _buildUrlRow(
                    'LAN ($ip)',
                    'http://$ip:$httpPort',
                    Icons.wifi,
                  )).toList(),
                );
              },
            ),
            // If SSL is enabled and domain is configured
            if (enableSsl && sslDomain != null && sslDomain.isNotEmpty)
              _buildUrlRow(
                'Public (HTTPS)',
                'https://$sslDomain:$httpsPort',
                Icons.lock,
              ),
            SizedBox(height: 8),
            Text(
              'Click to open in browser, or copy to share',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUrlRow(String label, String url, IconData icon) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: Colors.grey[600]),
              SizedBox(width: 8),
              Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ],
          ),
          SizedBox(height: 4),
          InkWell(
            onTap: () => _openUrl(url),
            child: Text(
              url,
              style: TextStyle(
                color: Colors.blue,
              ),
            ),
          ),
          SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: () => _showUrlQrCode(url),
                icon: Icon(Icons.qr_code, size: 16),
                label: Text('QR'),
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  minimumSize: Size(0, 32),
                ),
              ),
              SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _copyToClipboard(url),
                icon: Icon(Icons.copy, size: 16),
                label: Text('Copy'),
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  minimumSize: Size(0, 32),
                ),
              ),
              SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _openUrl(url),
                icon: Icon(Icons.open_in_new, size: 16),
                label: Text('Open'),
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  minimumSize: Size(0, 32),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<List<String>> _getLocalIpAddresses() async {
    final ips = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && (addr.address.startsWith('192.') ||
              addr.address.startsWith('10.') ||
              addr.address.startsWith('172.'))) {
            ips.add(addr.address);
          }
        }
      }
    } catch (e) {
      LogService().log('Error getting local IPs: $e');
    }
    return ips;
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      // Don't use canLaunchUrl - it's unreliable on Android
      // Just try to launch directly
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        // Fallback: try with platformDefault mode
        final fallbackLaunched = await launchUrl(
          uri,
          mode: LaunchMode.platformDefault,
        );
        if (!fallbackLaunched && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open URL: $url')),
          );
        }
      }
    } catch (e) {
      LogService().log('Error opening URL: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening URL: $e')),
        );
      }
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 32, color: Colors.white),
            SizedBox(height: 8),
            Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectedDevicesCard() {
    final count = _stationNode!.stats.connectedDevices;
    return GestureDetector(
      onTap: _showConnectedDevices,
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(Icons.devices, size: 32, color: Colors.white),
              SizedBox(height: 8),
              Text('$count', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              Text('Connected Devices', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  void _showConnectedDevices() {
    final server = _stationNodeService.stationServer;
    if (server == null || !server.isRunning) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Station not running')),
      );
      return;
    }

    final clients = server.clients.values.toList();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Connected Devices (${clients.length})', style: TextStyle(fontSize: 16)),
        content: clients.isEmpty
            ? Text('No devices connected', style: TextStyle(color: Colors.grey[600]))
            : SizedBox(
                width: double.maxFinite,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: clients.length,
                  separatorBuilder: (_, __) => Divider(height: 1),
                  itemBuilder: (_, i) {
                    final c = clients[i];
                    final uptime = DateTime.now().difference(c.connectedAt);
                    final uptimeStr = uptime.inHours > 0
                        ? '${uptime.inHours}h ${uptime.inMinutes % 60}m'
                        : '${uptime.inMinutes}m';
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 4),
                      leading: Icon(
                        c.verified ? Icons.verified_user : Icons.person_outline,
                        color: c.verified ? Colors.green : Colors.grey,
                        size: 20,
                      ),
                      title: Text(
                        c.callsign ?? c.id,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        [
                          if (c.nickname != null) c.nickname!,
                          if (c.platform != null) c.platform!,
                          if (c.remoteAddress != null) c.remoteAddress!,
                          'up $uptimeStr',
                        ].join(' · '),
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsPreviewCard() {
    final server = _stationNodeService.stationServer;
    final stats = server?.stats;
    final requestsToday = stats?.requestsToday ?? 0;
    final bytesToday = stats?.bytesServedToday ?? 0;

    return GestureDetector(
      onTap: () {
        Navigator.push(context,
          MaterialPageRoute(builder: (_) => const StationMetricsPage()),
        );
      },
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.bar_chart, size: 16, color: Colors.grey[600]),
                  SizedBox(width: 6),
                  Text('TODAY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  Spacer(),
                  Icon(Icons.chevron_right, size: 16, color: Colors.grey[400]),
                ],
              ),
              SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$requestsToday', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        Text('Requests', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_formatBandwidth(bytesToday), style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        Text('Bandwidth', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatBandwidth(int bytes) {
    if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  Widget _buildStorageCard() {
    final used = _stationNode!.stats.storageUsedMb;
    final allocated = _stationNode!.config.storage.allocatedMb;
    final percent = allocated > 0 ? (used / allocated).clamp(0.0, 1.0) : 0.0;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('STORAGE', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: percent,
                    backgroundColor: Colors.grey[200],
                  ),
                ),
                SizedBox(width: 16),
                Text('${(percent * 100).toStringAsFixed(0)}%'),
              ],
            ),
            SizedBox(height: 8),
            Text(
              'Used: ${_formatStorage(used)} / ${_formatStorage(allocated)}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWifiDirectCard() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_tethering, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Wi-Fi Hotspot',
                    style: TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_hotspotLoading)
                  SizedBox(
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
              SizedBox(height: 12),
              _buildHotspotInfoRow('SSID', _hotspotSsid ?? 'Loading...'),
              SizedBox(height: 4),
              _buildHotspotInfoRow('Password', _hotspotPassword ?? '...'),
              SizedBox(height: 4),
              _buildHotspotInfoRow('Clients', '$_hotspotClients connected'),
              SizedBox(height: 12),
              Center(
                child: OutlinedButton.icon(
                  onPressed: _showHotspotQrCode,
                  icon: Icon(Icons.qr_code, size: 18),
                  label: Text('Show QR Code'),
                ),
              ),
            ] else ...[
              SizedBox(height: 8),
              Text(
                'Enable to create a hotspot that other devices can connect to directly.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHotspotInfoRow(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Text(value, style: TextStyle(fontSize: 13)),
              ),
              if (label == 'SSID' || label == 'Password')
                IconButton(
                  icon: Icon(Icons.copy, size: 16),
                  onPressed: () => _copyToClipboard(value),
                  tooltip: 'Copy',
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: 28, minHeight: 28),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _toggleHotspot(bool enabled) async {
    setState(() => _hotspotLoading = true);

    try {
      if (enabled) {
        // Request required permissions first
        final locationStatus = await Permission.location.request();
        if (!locationStatus.isGranted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Location permission required for Wi-Fi Direct')),
            );
          }
          return;
        }

        // Android 13+ requires NEARBY_WIFI_DEVICES permission
        await Permission.nearbyWifiDevices.request();

        // Use station nickname or callsign for the hotspot SSID
        final stationName = _stationNode?.name ?? _stationNode?.callsign ?? 'Station';
        final info = await _wifiDirectService.enableHotspot(stationName);
        if (info != null && mounted) {
          setState(() {
            _hotspotEnabled = true;
            _hotspotSsid = info['ssid'] as String?;
            _hotspotPassword = info['passphrase'] as String?;
            _hotspotClients = (info['clientCount'] as int?) ?? 0;
          });

          // Auto-start portal DNS for captive portal detection
          try {
            await HotspotPortalService().start(stationName: stationName);
          } catch (e) {
            LogService().log('Portal auto-start failed: $e');
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to enable hotspot')),
          );
        }
      } else {
        // Stop portal DNS before disabling hotspot
        final portal = HotspotPortalService();
        if (portal.isActive) {
          await portal.stop();
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
              SnackBar(content: Text('Failed to disable hotspot')),
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
      if (mounted) {
        setState(() => _hotspotLoading = false);
      }
    }
  }

  void _showUrlQrCode(String url) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Scan to open'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: QrImageView(
                data: url,
                version: QrVersions.auto,
                size: 200,
              ),
            ),
            SizedBox(height: 16),
            Text(
              url,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showHotspotQrCode() {
    if (_hotspotSsid == null || _hotspotPassword == null) return;

    // Wi-Fi QR code format: WIFI:T:WPA;S:<SSID>;P:<password>;;
    final wifiQrData = 'WIFI:T:WPA;S:${_hotspotSsid};P:${_hotspotPassword};;';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Scan to connect'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: QrImageView(
                data: wifiQrData,
                version: QrVersions.auto,
                size: 200,
              ),
            ),
            SizedBox(height: 16),
            Text(
              _hotspotSsid!,
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 4),
            Text(
              'Open Wi-Fi settings on another device and use the QR scan option to connect automatically.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelsCard() {
    final channels = _stationNode!.config.channels;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('CHANNELS', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 12),
            if (channels.isEmpty)
              Text('No channels configured', style: TextStyle(color: Colors.grey))
            else
              ...channels.map((ch) => Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      _getChannelIcon(ch.type),
                      size: 20,
                      color: ch.enabled ? Colors.green : Colors.grey,
                    ),
                    SizedBox(width: 8),
                    Text(ch.type),
                    Spacer(),
                    Text(
                      ch.enabled ? 'Active' : 'Off',
                      style: TextStyle(
                        color: ch.enabled ? Colors.green : Colors.grey,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              )),
            // Show default channels if none configured
            if (channels.isEmpty) ...[
              _buildDefaultChannelRow('Internet', true),
              _buildDefaultChannelRow('WiFi LAN', true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDefaultChannelRow(String name, bool active) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.wifi,
            size: 20,
            color: active ? Colors.green : Colors.grey,
          ),
          SizedBox(width: 8),
          Text(name),
          Spacer(),
          Text(
            active ? 'Active' : 'Off',
            style: TextStyle(
              color: active ? Colors.green : Colors.grey,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  IconData _getChannelIcon(String type) {
    switch (type) {
      case 'internet':
        return Icons.public;
      case 'wifi_lan':
        return Icons.wifi;
      case 'bluetooth':
        return Icons.bluetooth;
      case 'lora':
        return Icons.settings_input_antenna;
      default:
        return Icons.device_hub;
    }
  }

  Widget _buildActionsCard() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ACTIONS', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_stationNode!.isRoot)
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => StationAuthoritiesPage()),
                      );
                    },
                    icon: Icon(Icons.admin_panel_settings),
                    label: Text('Moderators'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _createRootStation() async {
    final result = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StationSetupRootPage()),
    );
    if (result == true) {
      setState(() => _stationNode = _stationNodeService.stationNode);
    }
  }

  void _connectToRemoteStation() async {
    final result = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StationSetupRemotePage()),
    );
    if (result == true) {
      setState(() {
        _remoteStations = _stationNodeService.remoteStations;
      });
    }
  }

  void _toggleStation(bool enabled) async {
    // Show loading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text(enabled ? 'Starting station...' : 'Stopping station...'),
          ],
        ),
        duration: Duration(seconds: 10),
      ),
    );

    try {
      if (enabled) {
        await _stationNodeService.start();

        // Verify it actually started
        final server = _stationNodeService.stationServer;
        if (server == null || !server.isRunning) {
          final networkSettings = await _stationNodeService.loadNetworkSettings();
          final port = networkSettings['httpPort'] ?? 'unknown';
          throw Exception('Server failed to start. Check if port $port is already in use.');
        }

        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Station started on port ${server.settings.httpPort}'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        await _stationNodeService.stop();

        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Station stopped'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }

      // Force UI refresh
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      LogService().log('Error toggling station: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 5),
          ),
        );
      }
    }
  }



  String _formatUptime(Duration duration) {
    if (duration.inDays > 0) {
      return '${duration.inDays}d ${duration.inHours % 24}h';
    } else if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes % 60}m';
    } else {
      return '${duration.inMinutes}m';
    }
  }

  String _formatStorage(int mb) {
    if (mb >= 1000) {
      return '${(mb / 1000).toStringAsFixed(1)} GB';
    }
    return '$mb MB';
  }
}

/// Settings panel widget that displays inside the slide-in panel
class StationSettingsPanel extends StatefulWidget {
  final StationNodeService stationNodeService;
  final VoidCallback onClose;

  const StationSettingsPanel({
    super.key,
    required this.stationNodeService,
    required this.onClose,
  });

  @override
  State<StationSettingsPanel> createState() => _StationSettingsPanelState();
}

class _StationSettingsPanelState extends State<StationSettingsPanel> {
  late StationNodeConfig _config;
  bool _isSaving = false;
  bool _hasChanges = false;

  // Storage settings — logarithmic steps in GB: 1, 2, 4, 8, 16, 32, 64, 128
  static const _storageStepsGb = [1, 2, 4, 8, 16, 32, 64, 128];
  late int _allocatedMb;
  late int _thumbnailMaxKb;
  late bool _foreverRetention;
  late int _retentionDays;
  late bool _foreverChatRetention;
  late int _chatRetentionDays;

  // Connection settings
  late bool _acceptConnections;
  late int _maxConnections;

  // Network settings
  late int _httpPort;
  late int _httpsPort;
  late bool _enableSsl;
  String _sslDomain = '';
  String _sslEmail = '';
  late bool _sslAutoRenew;

  // SSL certificate state
  bool _requestingCert = false;
  String? _certStatus;

  // Text controllers
  late TextEditingController _httpPortController;
  late TextEditingController _httpsPortController;
  late TextEditingController _maxConnectionsController;
  late TextEditingController _sslDomainController;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _httpPortController.dispose();
    _httpsPortController.dispose();
    _maxConnectionsController.dispose();
    _sslDomainController.dispose();
    super.dispose();
  }

  void _loadConfig() {
    final node = widget.stationNodeService.stationNode;
    if (node == null) return;

    _config = node.config;

    // Storage
    _allocatedMb = _config.storage.allocatedMb;
    // Snap to nearest valid step
    if (!_storageStepsGb.contains((_allocatedMb / 1024).round())) {
      _allocatedMb = 16 * 1024; // default 16 GB
    }
    _thumbnailMaxKb = _config.storage.thumbnailMaxKb;
    _retentionDays = _config.storage.retentionDays;
    _foreverRetention = _retentionDays == 0;
    if (_retentionDays == 0) _retentionDays = 365;
    _chatRetentionDays = _config.storage.chatRetentionDays;
    _foreverChatRetention = _chatRetentionDays == 0;
    if (_chatRetentionDays == 0) _chatRetentionDays = 90;

    // Connections
    _acceptConnections = _config.acceptConnections;
    _maxConnections = _config.maxConnections;

    // Default network settings
    _httpPort = 3456;
    _httpsPort = 3457;
    _enableSsl = true;
    _sslAutoRenew = true;

    // Initialize controllers
    _httpPortController = TextEditingController(text: _httpPort.toString());
    _httpsPortController = TextEditingController(text: _httpsPort.toString());
    _maxConnectionsController = TextEditingController(text: _maxConnections.toString());
    _sslDomainController = TextEditingController(text: _sslDomain);

    // Load network settings async
    _loadNetworkSettings();
  }

  Future<void> _loadNetworkSettings() async {
    final settings = await widget.stationNodeService.loadNetworkSettings();
    if (mounted) {
      setState(() {
        _httpPort = settings['httpPort'] as int;
        _httpsPort = settings['httpsPort'] as int;
        _enableSsl = settings['enableSsl'] as bool;
        _sslDomain = (settings['sslDomain'] as String?) ?? '';
        _sslEmail = (settings['sslEmail'] as String?) ?? '';
        _sslAutoRenew = settings['sslAutoRenew'] as bool;
        _maxConnections = settings['maxConnectedDevices'] as int;

        _httpPortController.text = _httpPort.toString();
        _httpsPortController.text = _httpsPort.toString();
        _maxConnectionsController.text = _maxConnections.toString();
        _sslDomainController.text = _sslDomain;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.stationNodeService.stationNode;
    if (node == null) {
      return Center(child: Text('No station configured'));
    }

    return Column(
      children: [
        // Save button bar
        if (_hasChanges)
          Container(
            padding: EdgeInsets.all(8),
            color: Theme.of(context).primaryColor.withOpacity(0.1),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16),
                SizedBox(width: 8),
                Expanded(child: Text('You have unsaved changes')),
                ElevatedButton(
                  onPressed: _isSaving ? null : _saveChanges,
                  child: _isSaving
                      ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text('Save'),
                ),
              ],
            ),
          ),
        // Settings content
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildNetworkSection(),
                SizedBox(height: 16),
                _buildStorageSection(),
                SizedBox(height: 16),
                _buildConnectionsSection(),
                SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNetworkSection() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('NETWORK', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            SizedBox(height: 12),
            // Domain — always visible, used for NIP-05, email, HTTPS, etc.
            TextField(
              decoration: InputDecoration(
                labelText: 'Domain',
                hintText: 'mystation.example.com',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                isDense: true,
              ),
              style: TextStyle(fontSize: 13),
              controller: _sslDomainController,
              onChanged: (v) {
                _sslDomain = v.trim();
                _hasChanges = true;
                setState(() {});
              },
            ),
            SizedBox(height: 12),
            // Ports — stacked vertically to avoid overflow on narrow screens
            Row(
              children: [
                Text('HTTP Port:', style: TextStyle(fontSize: 13)),
                SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      isDense: true,
                    ),
                    style: TextStyle(fontSize: 13),
                    controller: _httpPortController,
                    onChanged: (v) {
                      _httpPort = int.tryParse(v) ?? 3456;
                      _hasChanges = true;
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            Row(
              children: [
                Text('HTTPS Port:', style: TextStyle(fontSize: 13)),
                SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      isDense: true,
                    ),
                    style: TextStyle(fontSize: 13),
                    controller: _httpsPortController,
                    onChanged: (v) {
                      _httpsPort = int.tryParse(v) ?? 3457;
                      _hasChanges = true;
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
            // SSL / Let's Encrypt section
            SizedBox(height: 12),
            Divider(height: 1),
            SizedBox(height: 8),
            Text('SSL / LET\'S ENCRYPT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            SizedBox(height: 8),
            SwitchListTile(
              title: Text('Enable HTTPS', style: TextStyle(fontSize: 13)),
              dense: true,
              value: _enableSsl,
              onChanged: (value) {
                setState(() {
                  _enableSsl = value;
                  _hasChanges = true;
                });
              },
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              title: Text('Auto-renew certificate', style: TextStyle(fontSize: 13)),
              dense: true,
              value: _sslAutoRenew,
              onChanged: (value) {
                setState(() {
                  _sslAutoRenew = value;
                  _hasChanges = true;
                });
              },
              contentPadding: EdgeInsets.zero,
            ),
            SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _requestingCert ? null : _requestCertificate,
                    icon: _requestingCert
                        ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.lock, size: 16),
                    label: Text(_requestingCert ? 'Requesting...' : 'Request Certificate', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
            if (_sslDomain.isEmpty)
              Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Set a domain above before requesting',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _requestCertificate() async {
    if (_sslDomain.isEmpty) {
      _showCertResult(false, 'Set a domain name first.');
      return;
    }

    final server = widget.stationNodeService.stationServer;
    if (server == null || !server.isRunning) {
      _showCertResult(false, 'Station server must be running.\nStart the station first.');
      return;
    }

    // Auto-derive email from domain
    _sslEmail = 'admin@$_sslDomain';
    _hasChanges = true;
    await _saveChanges();

    // Show progress dialog
    if (!mounted) return;
    final progressNotifier = ValueNotifier<String>('Checking domain reachability...');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ValueListenableBuilder<String>(
        valueListenable: progressNotifier,
        builder: (_, msg, __) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.lock, size: 20),
              SizedBox(width: 8),
              Text("Let's Encrypt", style: TextStyle(fontSize: 16)),
            ],
          ),
          content: Row(
            children: [
              SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 16),
              Expanded(child: Text(msg, style: TextStyle(fontSize: 13))),
            ],
          ),
        ),
      ),
    );

    try {
      progressNotifier.value = 'Requesting certificate for $_sslDomain...\nThis may take up to 2 minutes.';

      final sslManager = SslCertificateManager(server.settings, server.dataDir ?? '.');
      await sslManager.initialize();
      sslManager.setStationServer(server);
      final success = await sslManager.requestCertificate(staging: false);

      if (mounted) Navigator.of(context).pop();

      if (success) {
        _showCertResult(true, 'SSL certificate obtained for $_sslDomain.\n\nRestart the station to use the new certificate.');
      } else {
        _showCertResult(false, 'Certificate request failed.\nCheck the station logs for details.');
      }
    } catch (e) {
      LogService().log('Certificate request error: $e');
      if (mounted) Navigator.of(context).pop();
      _showCertResult(false, 'Certificate request failed:\n$e');
    }
  }

  void _showCertResult(bool success, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              success ? Icons.check_circle : Icons.error,
              color: success ? Colors.green : Colors.red,
              size: 20,
            ),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                success ? 'Certificate Ready' : 'Certificate Error',
                style: TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
        content: Text(message, style: TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildStorageSection() {
    final currentGb = _allocatedMb / 1024;
    final stepIndex = _storageStepsGb.indexWhere((g) => g * 1024 == _allocatedMb);
    final sliderIndex = stepIndex >= 0 ? stepIndex : _storageStepsGb.indexOf(16);

    return Card(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('STORAGE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            SizedBox(height: 12),
            Text('Allocated: ${currentGb.round()} GB', style: TextStyle(fontSize: 13)),
            Slider(
              value: sliderIndex.toDouble(),
              min: 0,
              max: (_storageStepsGb.length - 1).toDouble(),
              divisions: _storageStepsGb.length - 1,
              label: '${_storageStepsGb[sliderIndex]} GB',
              onChanged: (value) {
                setState(() {
                  _allocatedMb = _storageStepsGb[value.round()] * 1024;
                  _hasChanges = true;
                });
              },
            ),
            Wrap(
              spacing: 4,
              children: _storageStepsGb.map((gb) => _buildPresetChip('$gb GB', gb * 1024)).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetChip(String label, int valueMb) {
    final isSelected = _allocatedMb == valueMb;
    return ActionChip(
      label: Text(label, style: TextStyle(fontSize: 11)),
      backgroundColor: isSelected ? Theme.of(context).primaryColor.withValues(alpha: 0.2) : null,
      onPressed: () {
        setState(() {
          _allocatedMb = valueMb;
          _hasChanges = true;
        });
      },
    );
  }

  Widget _buildConnectionsSection() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('CONNECTIONS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            SizedBox(height: 8),
            SwitchListTile(
              title: Text('Accept connections', style: TextStyle(fontSize: 13)),
              dense: true,
              value: _acceptConnections,
              onChanged: (value) {
                setState(() {
                  _acceptConnections = value;
                  _hasChanges = true;
                });
              },
              contentPadding: EdgeInsets.zero,
            ),
            Row(
              children: [
                Text('Max connections:', style: TextStyle(fontSize: 13)),
                SizedBox(width: 8),
                SizedBox(
                  width: 60,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      isDense: true,
                    ),
                    style: TextStyle(fontSize: 13),
                    controller: _maxConnectionsController,
                    onChanged: (v) {
                      _maxConnections = int.tryParse(v) ?? 50;
                      _hasChanges = true;
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveChanges() async {
    setState(() => _isSaving = true);

    try {
      final newStorage = StationStorageConfig(
        allocatedMb: _allocatedMb,
        binaryPolicy: _config.storage.binaryPolicy,
        thumbnailMaxKb: _thumbnailMaxKb,
        retentionDays: _foreverRetention ? 0 : _retentionDays,
        chatRetentionDays: _foreverChatRetention ? 0 : _chatRetentionDays,
      );

      final newConfig = _config.copyWith(
        storage: newStorage,
        acceptConnections: _acceptConnections,
        maxConnections: _maxConnections,
      );

      await widget.stationNodeService.updateConfig(newConfig);

      await widget.stationNodeService.updateNetworkSettings(
        httpPort: _httpPort,
        httpsPort: _httpsPort,
        enableSsl: _enableSsl,
        sslDomain: _sslDomain.isNotEmpty ? _sslDomain : null,
        sslEmail: _sslEmail.isNotEmpty ? _sslEmail : null,
        sslAutoRenew: _sslAutoRenew,
        maxConnections: _maxConnections,
      );

      setState(() {
        _config = newConfig;
        _hasChanges = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Settings saved')),
        );
        widget.onClose();
      }
    } catch (e) {
      LogService().log('Error saving station settings: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }
}
