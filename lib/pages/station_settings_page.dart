/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../models/station_node.dart';
import '../services/station_node_service.dart';
import '../services/log_service.dart';
import '../station.dart';
import '../server/ssl_certificate_manager.dart';

/// Settings page for station configuration
class StationSettingsPage extends StatefulWidget {
  const StationSettingsPage({super.key});

  @override
  State<StationSettingsPage> createState() => _StationSettingsPageState();
}

class _StationSettingsPageState extends State<StationSettingsPage> {
  final StationNodeService _stationNodeService = StationNodeService();

  late StationNodeConfig _config;
  bool _isSaving = false;
  bool _hasChanges = false;

  // Storage settings
  late int _allocatedMb;
  late BinaryPolicy _binaryPolicy;
  late int _thumbnailMaxKb;
  late bool _foreverRetention;
  late int _retentionDays;
  late bool _foreverChatRetention;
  late int _chatRetentionDays;
  late bool _nostrRequireAuthForWrites;
  late int _blossomMaxStorageMb;
  late int _blossomMaxFileMb;

  // Connection settings
  late bool _acceptConnections;
  late int _maxConnections;

  // Coverage settings
  double? _latitude;
  double? _longitude;
  late double _radiusKm;

  // Network settings (from PureStationServer)
  late int _httpPort;
  late int _httpsPort;
  late bool _enableSsl;
  String _sslDomain = '';
  String _sslEmail = '';
  late bool _sslAutoRenew;
  bool _isRequestingCert = false;
  String? _sslStatus;

  // Text controllers for proper input handling
  late TextEditingController _httpPortController;
  late TextEditingController _httpsPortController;
  late TextEditingController _sslDomainController;
  late TextEditingController _sslEmailController;
  late TextEditingController _maxConnectionsController;
  late TextEditingController _thumbnailMaxKbController;
  late TextEditingController _retentionDaysController;
  late TextEditingController _chatRetentionDaysController;
  late TextEditingController _blossomMaxStorageMbController;
  late TextEditingController _blossomMaxFileMbController;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _initControllers();
  }

  void _initControllers() {
    // Initialize controllers after _loadConfig has set the values
    _httpPortController = TextEditingController(text: _httpPort.toString());
    _httpsPortController = TextEditingController(text: _httpsPort.toString());
    _sslDomainController = TextEditingController(text: _sslDomain);
    _sslEmailController = TextEditingController(text: _sslEmail);
    _maxConnectionsController = TextEditingController(text: _maxConnections.toString());
    _thumbnailMaxKbController = TextEditingController(text: _thumbnailMaxKb.toString());
    _retentionDaysController = TextEditingController(text: _retentionDays.toString());
    _chatRetentionDaysController = TextEditingController(text: _chatRetentionDays.toString());
    _blossomMaxStorageMbController = TextEditingController(text: _blossomMaxStorageMb.toString());
    _blossomMaxFileMbController = TextEditingController(text: _blossomMaxFileMb.toString());
  }

  void _updateControllersFromConfig() {
    // Update controller text without recreating controllers
    _httpPortController.text = _httpPort.toString();
    _httpsPortController.text = _httpsPort.toString();
    _sslDomainController.text = _sslDomain;
    _sslEmailController.text = _sslEmail;
    _maxConnectionsController.text = _maxConnections.toString();
    _thumbnailMaxKbController.text = _thumbnailMaxKb.toString();
    _retentionDaysController.text = _retentionDays.toString();
    _chatRetentionDaysController.text = _chatRetentionDays.toString();
    _blossomMaxStorageMbController.text = _blossomMaxStorageMb.toString();
    _blossomMaxFileMbController.text = _blossomMaxFileMb.toString();
  }

  @override
  void dispose() {
    _httpPortController.dispose();
    _httpsPortController.dispose();
    _sslDomainController.dispose();
    _sslEmailController.dispose();
    _maxConnectionsController.dispose();
    _thumbnailMaxKbController.dispose();
    _retentionDaysController.dispose();
    _chatRetentionDaysController.dispose();
    _blossomMaxStorageMbController.dispose();
    _blossomMaxFileMbController.dispose();
    super.dispose();
  }

  void _loadConfig() {
    final node = _stationNodeService.stationNode;
    if (node == null) return;

    _config = node.config;

    // Storage
    _allocatedMb = _config.storage.allocatedMb;
    _binaryPolicy = _config.storage.binaryPolicy;
    _thumbnailMaxKb = _config.storage.thumbnailMaxKb;
    _retentionDays = _config.storage.retentionDays;
    _foreverRetention = _retentionDays == 0;
    if (_retentionDays == 0) _retentionDays = 365; // Default for display
    _chatRetentionDays = _config.storage.chatRetentionDays;
    _foreverChatRetention = _chatRetentionDays == 0;
    if (_chatRetentionDays == 0) _chatRetentionDays = 90; // Default for display
    _nostrRequireAuthForWrites = _config.storage.nostrRequireAuthForWrites;
    _blossomMaxStorageMb = _config.storage.blossomMaxStorageMb;
    _blossomMaxFileMb = _config.storage.blossomMaxFileMb;

    // Connections
    _acceptConnections = _config.acceptConnections;
    _maxConnections = _config.maxConnections;

    // Coverage
    _latitude = _config.coverage?.latitude;
    _longitude = _config.coverage?.longitude;
    _radiusKm = _config.coverage?.radiusKm ?? 50.0;

    // Default network settings (will be overridden by async load)
    _httpPort = 3456;  // Standard Geogram port
    _httpsPort = 3457;
    _enableSsl = true;
    _sslAutoRenew = true;

    // Load network settings from file (async)
    _loadNetworkSettings();
  }

  Future<void> _loadNetworkSettings() async {
    final settings = await _stationNodeService.loadNetworkSettings();
    if (mounted) {
      setState(() {
        _httpPort = settings['httpPort'] as int;
        _httpsPort = settings['httpsPort'] as int;
        _enableSsl = settings['enableSsl'] as bool;
        _sslDomain = (settings['sslDomain'] as String?) ?? '';
        _sslEmail = (settings['sslEmail'] as String?) ?? '';
        _sslAutoRenew = settings['sslAutoRenew'] as bool;
        _maxConnections = settings['maxConnectedDevices'] as int;

        // Update controllers with loaded values
        _httpPortController.text = _httpPort.toString();
        _httpsPortController.text = _httpsPort.toString();
        _sslDomainController.text = _sslDomain;
        _sslEmailController.text = _sslEmail;
        _maxConnectionsController.text = _maxConnections.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final node = _stationNodeService.stationNode;
    if (node == null) {
      return Scaffold(
        appBar: AppBar(title: Text('Station')),
        body: Center(child: Text('No station configured')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Station'),
        actions: [
          if (_hasChanges)
            TextButton(
              onPressed: _isSaving ? null : _saveChanges,
              child: _isSaving
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('Save', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoCard(node),
            SizedBox(height: 16),
            _buildNetworkSection(),
            SizedBox(height: 16),
            _buildStorageSection(),
            SizedBox(height: 16),
            _buildConnectionsSection(),
            SizedBox(height: 16),
            _buildCoverageSection(),
            SizedBox(height: 16),
            _buildChannelsSection(node),
            SizedBox(height: 16),
            _buildCollectionsSection(node),
            SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(StationNode node) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('STATION IDENTITY', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 12),
            _buildInfoRow('Name', node.name),
            _buildInfoRow('Type', node.typeDisplay),
            _buildInfoRow('Station (X3)', node.stationCallsign),
            _buildInfoRow('Station NPUB', _truncateNpub(node.stationNpub)),
            SizedBox(height: 8),
            Divider(),
            SizedBox(height: 8),
            Text('OPERATOR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey[600])),
            SizedBox(height: 8),
            _buildInfoRow('Operator (X1)', node.operatorCallsign),
            _buildInfoRow('Operator NPUB', _truncateNpub(node.operatorNpub)),
            SizedBox(height: 8),
            Divider(),
            SizedBox(height: 8),
            _buildInfoRow('Network', node.networkName ?? 'N/A'),
            _buildInfoRow('ID', node.id),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 100, child: Text(label, style: TextStyle(color: Colors.grey[600]))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  String _truncateNpub(String npub) {
    if (npub.length > 20) {
      return '${npub.substring(0, 10)}...${npub.substring(npub.length - 8)}';
    }
    return npub;
  }

  Widget _buildNetworkSection() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('NETWORK', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 16),

            // Domain — always visible
            TextField(
              decoration: InputDecoration(
                labelText: 'Domain',
                hintText: 'mystation.example.com',
                border: OutlineInputBorder(),
              ),
              controller: _sslDomainController,
              onChanged: (v) {
                _sslDomain = v;
                _hasChanges = true;
                setState(() {});
              },
            ),
            SizedBox(height: 16),

            // Ports — stacked vertically
            Row(
              children: [
                Text('HTTP Port:'),
                SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
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
                Text('HTTPS Port:'),
                SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
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
            SizedBox(height: 16),

            // SSL / Let's Encrypt section
            Divider(),
            SizedBox(height: 8),
            Text('SSL / LET\'S ENCRYPT', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            SwitchListTile(
              title: Text('Enable HTTPS'),
              subtitle: Text('Serve content over secure connection'),
              value: _enableSsl,
              onChanged: (value) {
                setState(() {
                  _enableSsl = value;
                  _hasChanges = true;
                });
              },
              contentPadding: EdgeInsets.zero,
            ),

            // Auto-renew
            SwitchListTile(
              title: Text('Auto-renew certificate'),
              subtitle: Text('Automatically renew before expiry'),
              value: _sslAutoRenew,
              onChanged: (value) {
                setState(() {
                  _sslAutoRenew = value;
                  _hasChanges = true;
                });
              },
              contentPadding: EdgeInsets.zero,
            ),
            SizedBox(height: 12),

            // Certificate status and request button
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _isRequestingCert ? null : _requestCertificate,
                  icon: _isRequestingCert
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.security),
                  label: Text('Request Certificate'),
                ),
                SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _checkCertificateStatus,
                  child: Text('Check Status'),
                ),
              ],
            ),
            if (_sslDomain.isEmpty)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Set a domain above before requesting',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
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

    final server = _stationNodeService.stationServer;
    if (server == null) {
      _showCertResult(false, 'Station server must be running.\nStart the station first.');
      return;
    }

    // Auto-derive email from domain
    _sslEmail = 'admin@$_sslDomain';

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

      server.settings.sslDomain = _sslDomain;
      server.settings.sslEmail = _sslEmail;
      server.settings.sslAutoRenew = _sslAutoRenew;
      await server.saveSettings();

      final sslManager = SslCertificateManager(server.settings, server.dataDir ?? '.');
      sslManager.setStationServer(server);
      await sslManager.initialize();
      final success = await sslManager.requestCertificate(staging: false);

      if (mounted) Navigator.of(context).pop();

      if (success) {
        _showCertResult(true, 'SSL certificate obtained for $_sslDomain.\n\nRestart the station to use the new certificate.');
      } else {
        _showCertResult(false, 'Certificate request failed.\nCheck the station logs for details.');
      }
    } catch (e) {
      LogService().log('Error requesting certificate: $e');
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

  Future<void> _checkCertificateStatus() async {
    try {
      final server = _stationNodeService.stationServer;
      if (server == null) {
        setState(() {
          _sslStatus = 'Station server not running';
        });
        return;
      }

      final sslManager = SslCertificateManager(server.settings, server.dataDir ?? '.');
      final status = await sslManager.getStatus();

      String statusText = 'SSL Status:\n';
      statusText += '  Domain: ${status['domain']}\n';
      statusText += '  Email: ${status['email']}\n';
      statusText += '  Has Certificate: ${status['hasCertificate']}\n';
      if (status['daysUntilExpiry'] != null) {
        statusText += '  Days until expiry: ${status['daysUntilExpiry']}';
      }

      setState(() {
        _sslStatus = statusText;
      });
    } catch (e) {
      setState(() {
        _sslStatus = 'Error checking status: $e';
      });
    }
  }

  Widget _buildStorageSection() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('STORAGE', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 16),
            Text('Allocated Storage'),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _allocatedMb.toDouble(),
                    min: 50,
                    max: 10000,
                    divisions: 199,
                    label: _formatStorage(_allocatedMb),
                    onChanged: (value) {
                      setState(() {
                        _allocatedMb = value.round();
                        _hasChanges = true;
                      });
                    },
                  ),
                ),
                SizedBox(width: 16),
                Text(_formatStorage(_allocatedMb), style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                _buildPresetButton('50 MB', 50),
                _buildPresetButton('500 MB', 500),
                _buildPresetButton('1 GB', 1000),
                _buildPresetButton('5 GB', 5000),
                _buildPresetButton('10 GB', 10000),
              ],
            ),
            SizedBox(height: 24),
            Text('Binary Data Policy'),
            SizedBox(height: 8),
            SegmentedButton<BinaryPolicy>(
              segments: [
                ButtonSegment(value: BinaryPolicy.textOnly, label: Text('Text')),
                ButtonSegment(value: BinaryPolicy.thumbnailsOnly, label: Text('Thumbs')),
                ButtonSegment(value: BinaryPolicy.onDemand, label: Text('On-demand')),
                ButtonSegment(value: BinaryPolicy.fullCache, label: Text('Full')),
              ],
              selected: {_binaryPolicy},
              onSelectionChanged: (value) {
                setState(() {
                  _binaryPolicy = value.first;
                  _hasChanges = true;
                });
              },
            ),
            if (_binaryPolicy == BinaryPolicy.thumbnailsOnly) ...[
              SizedBox(height: 16),
              Row(
                children: [
                  Text('Max thumbnail size: '),
                  SizedBox(
                    width: 80,
                    child: TextField(
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        suffixText: 'KB',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      ),
                      controller: _thumbnailMaxKbController,
                      onChanged: (v) {
                        _thumbnailMaxKb = int.tryParse(v) ?? 10;
                        _hasChanges = true;
                        setState(() {});
                      },
                    ),
                  ),
                ],
              ),
            ],
            SizedBox(height: 24),
            Text('Data Retention'),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text('Forum/Reports:')),
                Row(
                  children: [
                    ChoiceChip(
                      label: Text('Forever'),
                      selected: _foreverRetention,
                      onSelected: (v) {
                        setState(() {
                          _foreverRetention = true;
                          _hasChanges = true;
                        });
                      },
                    ),
                    SizedBox(width: 8),
                    ChoiceChip(
                      label: Text('Limit'),
                      selected: !_foreverRetention,
                      onSelected: (v) {
                        setState(() {
                          _foreverRetention = false;
                          _hasChanges = true;
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
            if (!_foreverRetention)
              Padding(
                padding: EdgeInsets.only(top: 8, left: 16),
                child: Row(
                  children: [
                    Text('Remove after: '),
                    SizedBox(
                      width: 80,
                      child: TextField(
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          suffixText: 'd',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        ),
                        controller: _retentionDaysController,
                        onChanged: (v) {
                          _retentionDays = int.tryParse(v) ?? 365;
                          _hasChanges = true;
                          setState(() {});
                        },
                      ),
                    ),
                  ],
                ),
              ),
            SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Text('Chat messages:')),
                Row(
                  children: [
                    ChoiceChip(
                      label: Text('Forever'),
                      selected: _foreverChatRetention,
                      onSelected: (v) {
                        setState(() {
                          _foreverChatRetention = true;
                          _hasChanges = true;
                        });
                      },
                    ),
                    SizedBox(width: 8),
                    ChoiceChip(
                      label: Text('Limit'),
                      selected: !_foreverChatRetention,
                      onSelected: (v) {
                        setState(() {
                          _foreverChatRetention = false;
                          _hasChanges = true;
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
            if (!_foreverChatRetention)
              Padding(
                padding: EdgeInsets.only(top: 8, left: 16),
                child: Row(
                  children: [
                    Text('Remove after: '),
                    SizedBox(
                      width: 80,
                      child: TextField(
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          suffixText: 'd',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        ),
                        controller: _chatRetentionDaysController,
                        onChanged: (v) {
                          _chatRetentionDays = int.tryParse(v) ?? 90;
                          _hasChanges = true;
                          setState(() {});
                        },
                      ),
                    ),
                  ],
                ),
              ),
            SizedBox(height: 24),
            Text('NOSTR Relay'),
            SizedBox(height: 8),
            SwitchListTile(
              title: Text('Require AUTH for writes'),
              value: _nostrRequireAuthForWrites,
              onChanged: (value) {
                setState(() {
                  _nostrRequireAuthForWrites = value;
                  _hasChanges = true;
                });
              },
              contentPadding: EdgeInsets.zero,
            ),
            SizedBox(height: 16),
            Text('Blossom Storage'),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text('Max disk usage:')),
                SizedBox(
                  width: 100,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      suffixText: 'MB',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                    controller: _blossomMaxStorageMbController,
                    onChanged: (v) {
                      _blossomMaxStorageMb = int.tryParse(v) ?? 1024;
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
                Expanded(child: Text('Max file size:')),
                SizedBox(
                  width: 100,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      suffixText: 'MB',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                    controller: _blossomMaxFileMbController,
                    onChanged: (v) {
                      _blossomMaxFileMb = int.tryParse(v) ?? 10;
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

  Widget _buildPresetButton(String label, int value) {
    final isSelected = _allocatedMb == value;
    return OutlinedButton(
      onPressed: () {
        setState(() {
          _allocatedMb = value;
          _hasChanges = true;
        });
      },
      style: OutlinedButton.styleFrom(
        backgroundColor: isSelected ? Theme.of(context).primaryColor.withOpacity(0.1) : null,
      ),
      child: Text(label),
    );
  }

  Widget _buildConnectionsSection() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('CONNECTIONS', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 12),
            SwitchListTile(
              title: Text('Accept incoming connections'),
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
                Expanded(child: Text('Max connections:')),
                SizedBox(
                  width: 80,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
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

  Widget _buildCoverageSection() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('GEOGRAPHIC COVERAGE', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 12),
            Container(
              height: 120,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(8),
                color: Colors.grey[100],
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.map, size: 32, color: Colors.grey),
                    SizedBox(height: 8),
                    Text(
                      _latitude != null
                          ? 'Center: ${_latitude!.toStringAsFixed(4)}, ${_longitude!.toStringAsFixed(4)}'
                          : 'Location not set',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 16),
            Row(
              children: [
                Text('Coverage Radius: '),
                Expanded(
                  child: Slider(
                    value: _radiusKm,
                    min: 5,
                    max: 500,
                    divisions: 99,
                    label: '${_radiusKm.round()} km',
                    onChanged: (v) {
                      setState(() {
                        _radiusKm = v;
                        _hasChanges = true;
                      });
                    },
                  ),
                ),
                Text('${_radiusKm.round()} km'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelsSection(StationNode node) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('COMMUNICATION CHANNELS', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 12),
            if (node.config.channels.isEmpty)
              Text('Default channels active (Internet, WiFi LAN)', style: TextStyle(color: Colors.grey))
            else
              ...node.config.channels.map((ch) => _buildChannelRow(ch)),
            SizedBox(height: 8),
            Text(
              'Channel configuration requires app restart',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelRow(ChannelConfig channel) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            _getChannelIcon(channel.type),
            size: 20,
            color: channel.enabled ? Colors.green : Colors.grey,
          ),
          SizedBox(width: 8),
          Expanded(child: Text(channel.type)),
          Text(
            channel.enabled ? 'Enabled' : 'Disabled',
            style: TextStyle(
              color: channel.enabled ? Colors.green : Colors.grey,
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

  Widget _buildCollectionsSection(StationNode node) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SUPPORTED COLLECTIONS', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: node.config.supportedApps.map((c) => Chip(
                label: Text(c),
                backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
              )).toList(),
            ),
            SizedBox(height: 8),
            Text(
              'Collection support is defined by the network',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
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
        binaryPolicy: _binaryPolicy,
        thumbnailMaxKb: _thumbnailMaxKb,
        retentionDays: _foreverRetention ? 0 : _retentionDays,
        chatRetentionDays: _foreverChatRetention ? 0 : _chatRetentionDays,
        nostrRequireAuthForWrites: _nostrRequireAuthForWrites,
        blossomMaxStorageMb: _blossomMaxStorageMb,
        blossomMaxFileMb: _blossomMaxFileMb,
      );

      GeographicCoverage? newCoverage;
      if (_latitude != null && _longitude != null) {
        newCoverage = GeographicCoverage(
          latitude: _latitude!,
          longitude: _longitude!,
          radiusKm: _radiusKm,
        );
      }

      final newConfig = _config.copyWith(
        storage: newStorage,
        coverage: newCoverage,
        acceptConnections: _acceptConnections,
        maxConnections: _maxConnections,
      );

      await _stationNodeService.updateConfig(newConfig);

      // Save network settings directly to file (works even when server is not running)
      await _stationNodeService.updateNetworkSettings(
        httpPort: _httpPort,
        httpsPort: _httpsPort,
        enableSsl: _enableSsl,
        sslDomain: _sslDomain.isNotEmpty ? _sslDomain : null,
        sslEmail: _sslEmail.isNotEmpty ? _sslEmail : null,
        sslAutoRenew: _sslAutoRenew,
        maxConnections: _maxConnections,
        nostrRequireAuthForWrites: _nostrRequireAuthForWrites,
        blossomMaxStorageMb: _blossomMaxStorageMb,
        blossomMaxFileMb: _blossomMaxFileMb,
      );

      setState(() {
        _config = newConfig;
        _hasChanges = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Settings saved')),
        );
        // Close the settings page after successful save
        Navigator.of(context).pop();
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

  String _formatStorage(int mb) {
    if (mb >= 1000) {
      return '${(mb / 1000).toStringAsFixed(1)} GB';
    }
    return '$mb MB';
  }
}
