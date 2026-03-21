import 'dart:async';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/station.dart';
import '../p2p/dht_node.dart' show PeerInfo;
import '../p2p/node_capability.dart';
import '../p2p/p2p_service.dart';
import '../services/station_service.dart';
import '../services/log_service.dart';
import '../services/station_discovery_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../services/websocket_service.dart';

class StationsPage extends StatefulWidget {
  const StationsPage({super.key});

  @override
  State<StationsPage> createState() => _StationsPageState();
}

class _StationsPageState extends State<StationsPage> {
  final StationService _stationService = StationService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  List<Station> _allStations = [];
  bool _isLoading = true;
  StreamSubscription<List<PeerInfo>>? _p2pSub;

  @override
  void initState() {
    super.initState();
    _loadStations();
    _ensureUserLocation();
    _p2pSub = P2PService().onDiscoveredPeersChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _p2pSub?.cancel();
    super.dispose();
  }

  /// Ensure user location is set, auto-detect if not
  Future<void> _ensureUserLocation() async {
    try {
      final profile = _profileService.getProfile();

      // If location is already set, we're done
      if (profile.latitude != null && profile.longitude != null) {
        LogService().log('User location already set: ${profile.latitude}, ${profile.longitude}');
        return;
      }

      // Auto-detect location from IP
      LogService().log('User location not set, detecting from IP...');
      final location = await _detectLocationFromIP();

      if (location != null) {
        await _profileService.updateProfile(
          latitude: location['lat'],
          longitude: location['lon'],
          locationName: location['locationName'],
        );
        LogService().log('User location auto-detected and saved: ${location['lat']}, ${location['lon']}');

        // Reload stations to show distances
        _loadStations();
      } else {
        LogService().log('Unable to auto-detect user location (offline?)');
      }
    } catch (e) {
      LogService().log('Error ensuring user location: $e');
    }
  }

  /// Detect location from IP address using the connected station's GeoIP service
  /// This provides privacy-preserving IP geolocation without external API calls
  Future<Map<String, dynamic>?> _detectLocationFromIP() async {
    try {
      // Get the connected station URL
      final stationUrl = WebSocketService().connectedUrl;
      if (stationUrl == null) {
        LogService().log('StationsPage: Not connected to station, cannot detect IP location');
        return null;
      }

      // Convert WebSocket URL to HTTP URL
      final httpUrl = stationUrl
          .replaceFirst('wss://', 'https://')
          .replaceFirst('ws://', 'http://');

      final response = await http.get(
        Uri.parse('$httpUrl/api/geoip'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final lat = (data['latitude'] as num?)?.toDouble();
        final lon = (data['longitude'] as num?)?.toDouble();
        final city = data['city'] as String?;
        final country = data['country'] as String?;

        if (lat != null && lon != null) {
          return {
            'lat': lat,
            'lon': lon,
            'locationName': (city != null && country != null) ? '$city, $country' : null,
          };
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<void> _loadStations() async {
    setState(() => _isLoading = true);

    try {
      final stations = _stationService.getAllStations();
      setState(() {
        _allStations = stations;
        _isLoading = false;
      });
      LogService().log('Loaded ${stations.length} stations');
    } catch (e) {
      LogService().log('Error loading stations: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addCustomStation() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => const _AddStationDialog(),
    );

    if (result != null) {
      try {
        // Auto-set as preferred if this is the first station
        final existingStations = _stationService.getAllStations();
        final isFirstStation = existingStations.isEmpty;

        final station = Station(
          url: result['url']!,
          name: result['name']!,
          callsign: result['callsign'],
          description: result['description'],
          status: isFirstStation ? 'preferred' : 'available',
          location: result['location'],
          latitude: result['latitude'] != null ? double.tryParse(result['latitude']!) : null,
          longitude: result['longitude'] != null ? double.tryParse(result['longitude']!) : null,
        );

        final added = await _stationService.addStation(station);

        if (mounted) {
          if (added) {
            final message = isFirstStation
                ? 'Added ${station.name} as preferred station'
                : _i18n.t('added_station', params: [station.name]);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message)),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Station already exists: ${station.name}'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }

        await _loadStations();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_i18n.t('error_adding_station', params: [e.toString()])),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _setPreferred(Station station) async {
    try {
      await _stationService.setPreferred(station.url);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('set_preferred_success', params: [station.name]))),
      );
      _loadStations();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('error', params: [e.toString()])),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _setBackup(Station station) async {
    try {
      await _stationService.setBackup(station.url);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('added_to_backup', params: [station.name]))),
      );
      _loadStations();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('error', params: [e.toString()])),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _setAvailable(Station station) async {
    try {
      await _stationService.setAvailable(station.url);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('removed_from_selection', params: [station.name]))),
      );
      _loadStations();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('error', params: [e.toString()])),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteStation(Station station) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_station')),
        content: Text(_i18n.t('delete_station_confirm', params: [station.name])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _stationService.deleteStation(station.url);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('deleted_station', params: [station.name]))),
          );
        }
        _loadStations();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_i18n.t('error_deleting_station', params: [e.toString()])),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _clearAllStations() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('clear_all_stations_title')),
        content: Text(_i18n.t('clear_all_stations_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: Text(_i18n.t('clear_all')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final stations = _stationService.getAllStations();
        for (var station in stations) {
          await _stationService.deleteStation(station.url);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('all_stations_cleared'))),
          );
        }
        _loadStations();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_i18n.t('error_clearing_stations', params: [e.toString()])),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _scanNow() async {
    final results = await showDialog<List<NetworkScanResult>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _NetworkScanDialog(
        stationService: _stationService,
        i18n: _i18n,
      ),
    );

    if (results != null && results.isNotEmpty) {
      _loadStations();
    }
  }

  Future<void> _testConnection(Station station) async {
    // Show loading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_i18n.t('connecting_to_station', params: [station.name])),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      // Use new connectStation method with hello handshake
      final success = await _stationService.connectStation(station.url);
      _loadStations();

      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_i18n.t('connected_success', params: [station.name])),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_i18n.t('connection_failed')),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('connection_error', params: [e.toString()])),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  List<Station> get _selectedStations {
    return _allStations.where((r) => r.status == 'preferred' || r.status == 'backup').toList()
      ..sort((a, b) {
        // Preferred first
        if (a.status == 'preferred') return -1;
        if (b.status == 'preferred') return 1;
        return 0;
      });
  }

  List<Station> get _availableStations {
    return _allStations.where((r) => r.status == 'available').toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('internet_stations')),
        actions: [
          IconButton(
            icon: const Icon(Icons.radar),
            onPressed: _scanNow,
            tooltip: _i18n.t('scan_local_network'),
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: _clearAllStations,
            tooltip: _i18n.t('clear_all_stations'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadStations,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Info Card
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _i18n.t('internet_station_config'),
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _i18n.t('station_instructions'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Selected Station Section
                  Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _selectedStations.length == 1 ? _i18n.t('selected_station') : _i18n.t('selected_stations'),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (_selectedStations.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            _i18n.t('no_stations_selected'),
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ),
                    )
                  else
                    ..._selectedStations.map((station) {
                      final profile = _profileService.getProfile();
                      return _StationCard(
                        station: station,
                        userLatitude: profile.latitude,
                        userLongitude: profile.longitude,
                        onSetPreferred: () => _setPreferred(station),
                        onSetBackup: () => _setBackup(station),
                        onSetAvailable: () => _setAvailable(station),
                        onDelete: () => _deleteStation(station),
                        onTest: () => _testConnection(station),
                      );
                    }),

                  const SizedBox(height: 32),

                  // Available Stations Section
                  Row(
                    children: [
                      Icon(
                        Icons.cloud_outlined,
                        color: Theme.of(context).colorScheme.secondary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _i18n.t('available_stations'),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (_availableStations.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            _i18n.t('all_stations_selected'),
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ),
                    )
                  else
                    ..._availableStations.map((station) {
                      final profile = _profileService.getProfile();
                      return _StationCard(
                        station: station,
                        userLatitude: profile.latitude,
                        userLongitude: profile.longitude,
                        onSetPreferred: () => _setPreferred(station),
                        onSetBackup: () => _setBackup(station),
                        onSetAvailable: null, // Already available
                        onDelete: () => _deleteStation(station),
                        onTest: () => _testConnection(station),
                        isAvailableStation: true,
                      );
                    }),

                  const SizedBox(height: 32),

                  // P2P Discovery Section
                  _buildP2PSection(Theme.of(context)),

                  const SizedBox(height: 80),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCustomStation,
        icon: const Icon(Icons.add),
        label: Text(_i18n.t('add_station')),
      ),
    );
  }

  Widget _buildP2PSection(ThemeData theme) {
    final p2p = P2PService();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.language,
              color: theme.colorScheme.primary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              'P2P Discovery',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Enable P2P'),
          subtitle: const Text('Find devices via BitTorrent DHT'),
          value: p2p.enabled,
          onChanged: (value) {
            setState(() {
              p2p.enabled = value;
              if (value && !p2p.isRunning) {
                p2p.start();
              }
            });
          },
        ),
        if (p2p.isRunning) ...[
          ListTile(
            leading: Icon(
              _nodeTypeIcon(p2p.nodeType),
              color: _nodeTypeColor(p2p.nodeType),
            ),
            title: Text('Node type: ${_nodeTypeLabel(p2p.nodeType)}'),
            subtitle: Text(
              p2p.publicIp != null
                  ? 'Public: ${p2p.publicIp}:${p2p.publicPort}'
                  : 'Detecting...',
            ),
          ),
          ListTile(
            leading: Icon(Icons.hub, color: theme.colorScheme.primary),
            title: Text('DHT peers: ${p2p.dhtPeerCount}'),
            subtitle: Text('Direct connections: ${p2p.directConnectionCount}'),
          ),
          if (p2p.discoveredPeers.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Devices found via internet',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            ...p2p.discoveredPeers.map((peer) => ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.teal.withValues(alpha: 0.1),
                child: const Icon(Icons.language, color: Colors.teal),
              ),
              title: Text('${peer.ip}:${peer.port}'),
              subtitle: const Text('DHT'),
            )),
          ],
        ],
      ],
    );
  }

  String _nodeTypeLabel(NodeType type) {
    switch (type) {
      case NodeType.typeA:
        return 'A (Public)';
      case NodeType.typeB:
        return 'B (NAT)';
      case NodeType.typeC:
        return 'C (Symmetric NAT)';
      case NodeType.unknown:
        return 'Detecting...';
    }
  }

  IconData _nodeTypeIcon(NodeType type) {
    switch (type) {
      case NodeType.typeA:
        return Icons.public;
      case NodeType.typeB:
        return Icons.router;
      case NodeType.typeC:
        return Icons.shield;
      case NodeType.unknown:
        return Icons.help_outline;
    }
  }

  Color _nodeTypeColor(NodeType type) {
    switch (type) {
      case NodeType.typeA:
        return Colors.green;
      case NodeType.typeB:
        return Colors.orange;
      case NodeType.typeC:
        return Colors.red;
      case NodeType.unknown:
        return Colors.grey;
    }
  }
}

// Station Card Widget
class _StationCard extends StatelessWidget {
  final Station station;
  final double? userLatitude;
  final double? userLongitude;
  final VoidCallback onSetPreferred;
  final VoidCallback onSetBackup;
  final VoidCallback? onSetAvailable;
  final VoidCallback onDelete;
  final VoidCallback onTest;
  final bool isAvailableStation;

  const _StationCard({
    required this.station,
    this.userLatitude,
    this.userLongitude,
    required this.onSetPreferred,
    required this.onSetBackup,
    required this.onSetAvailable,
    required this.onDelete,
    required this.onTest,
    this.isAvailableStation = false,
  });

  I18nService get _i18n => I18nService();

  String _getStatusDisplayText() {
    switch (station.status) {
      case 'preferred':
        return _i18n.t('preferred');
      case 'backup':
        return _i18n.t('backup');
      default:
        return _i18n.t('available');
    }
  }

  String _getConnectionStatusText() {
    if (station.isConnected) {
      return station.latency != null
        ? _i18n.translate('connected_with_latency', params: [station.latency.toString()])
        : _i18n.t('connected');
    }
    return _i18n.t('disconnected');
  }

  String? _getDistanceText(double? userLat, double? userLon) {
    final distance = station.calculateDistance(userLat, userLon);
    if (distance == null) return null;

    if (distance < 1) {
      final meters = (distance * 1000).round();
      return _i18n.translate('meters_away', params: [meters.toString()]);
    } else {
      final km = distance.round();
      return _i18n.translate('kilometers_away', params: [km.toString()]);
    }
  }

  Color _getStatusColor(BuildContext context) {
    switch (station.status) {
      case 'preferred':
        return Colors.green;
      case 'backup':
        return Colors.orange;
      default:
        // Show green if station is online/reachable (has device count data)
        return station.connectedDevices != null
            ? Colors.green
            : Theme.of(context).colorScheme.outline;
    }
  }

  IconData _getStatusIcon() {
    switch (station.status) {
      case 'preferred':
        return Icons.star;
      case 'backup':
        return Icons.check_circle;
      default:
        return Icons.cloud_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Row
            Row(
              children: [
                Icon(
                  _getStatusIcon(),
                  color: _getStatusColor(context),
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        station.name,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      if (station.description != null && station.description!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          station.description!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 2),
                      Text(
                        station.url,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.outline,
                              fontSize: 11,
                            ),
                      ),
                      if (station.location != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.location_on,
                              size: 14,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              station.location!,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.primary,
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                            if (station.latitude != null && station.longitude != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                '(${station.latitude!.toStringAsFixed(4)}, ${station.longitude!.toStringAsFixed(4)})',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                      fontSize: 11,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ],
                      // Display distance if available
                      if (_getDistanceText(userLatitude, userLongitude) != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.straighten,
                              size: 14,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _getDistanceText(userLatitude, userLongitude)!,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.secondary,
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (!isAvailableStation)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _getStatusColor(context).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _getStatusColor(context),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      _getStatusDisplayText(),
                      style: TextStyle(
                        color: _getStatusColor(context),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 12),

            // Connection Status (hide for available stations)
            if (station.lastChecked != null && !isAvailableStation)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          station.isConnected ? Icons.check_circle : Icons.error,
                          size: 16,
                          color: station.isConnected ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _getConnectionStatusText(),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const Spacer(),
                        Text(
                          _i18n.translate('last_checked', params: [_formatTime(station.lastChecked!)]),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                    // Show connected devices count if available
                    if (station.connectedDevices != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.devices,
                            size: 14,
                            color: Theme.of(context).colorScheme.tertiary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${station.connectedDevices} ${station.connectedDevices == 1 ? _i18n.t("device") : _i18n.t("devices_connected")}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.tertiary,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

            // Action Buttons
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Only show Set Preferred if NOT already preferred
                if (station.status != 'preferred')
                  OutlinedButton.icon(
                    onPressed: onSetPreferred,
                    icon: const Icon(Icons.star, size: 16),
                    label: Text(_i18n.t('set_preferred')),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                if (station.status != 'backup')
                  OutlinedButton.icon(
                    onPressed: onSetBackup,
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: Text(_i18n.t('set_as_backup')),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                if (onSetAvailable != null)
                  OutlinedButton.icon(
                    onPressed: onSetAvailable,
                    icon: const Icon(Icons.remove_circle_outline, size: 16),
                    label: Text(_i18n.t('remove')),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: onTest,
                  icon: const Icon(Icons.network_check, size: 16),
                  label: Text(_i18n.t('test')),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: onDelete,
                  tooltip: _i18n.t('delete'),
                  color: Theme.of(context).colorScheme.error,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inSeconds < 60) {
      return '${diff.inSeconds}s ago';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }
}

// Add Station Dialog - simplified to just IP:port input
class _AddStationDialog extends StatefulWidget {
  const _AddStationDialog();

  @override
  State<_AddStationDialog> createState() => _AddStationDialogState();
}

class _AddStationDialogState extends State<_AddStationDialog> {
  final _addressController = TextEditingController();
  bool _isConnecting = false;
  String? _statusMessage;
  bool _isError = false;

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final address = _addressController.text.trim();

    if (address.isEmpty) {
      setState(() {
        _statusMessage = 'Please enter an address';
        _isError = true;
      });
      return;
    }

    // Parse address - support formats: host:port, host (auto-detect protocol)
    String host;
    int? explicitPort;

    // Remove any protocol prefix if user accidentally added it
    String cleanAddress = address
        .replaceAll('wss://', '')
        .replaceAll('ws://', '')
        .replaceAll('https://', '')
        .replaceAll('http://', '');

    // Remove trailing slash
    if (cleanAddress.endsWith('/')) {
      cleanAddress = cleanAddress.substring(0, cleanAddress.length - 1);
    }

    if (cleanAddress.contains(':')) {
      final parts = cleanAddress.split(':');
      host = parts[0];
      explicitPort = int.tryParse(parts[1]);
    } else {
      host = cleanAddress;
    }

    if (host.isEmpty) {
      setState(() {
        _statusMessage = 'Invalid address format';
        _isError = true;
      });
      return;
    }

    setState(() {
      _isConnecting = true;
      _statusMessage = 'Connecting to $host...';
      _isError = false;
    });

    try {
      // Try to fetch station info from API first
      Map<String, dynamic>? stationInfo;
      String? workingProtocol;
      int? workingPort;

      // Build list of protocol+port combinations to try
      // If user specified a port, try that port with both protocols
      // Otherwise, try standard ports: HTTPS on 443, HTTP on 80
      final attempts = <({String protocol, int port})>[];
      if (explicitPort != null) {
        // User specified a port - try both protocols on that port
        attempts.add((protocol: 'https', port: explicitPort));
        attempts.add((protocol: 'http', port: explicitPort));
      } else {
        // No port specified - try standard ports
        attempts.add((protocol: 'https', port: 443));
        attempts.add((protocol: 'http', port: 80));
      }

      String? lastError;
      for (final attempt in attempts) {
        try {
          setState(() {
            _statusMessage = 'Trying ${attempt.protocol}://$host:${attempt.port}...';
          });

          final response = await http.get(
            Uri.parse('${attempt.protocol}://$host:${attempt.port}/api/status'),
          ).timeout(const Duration(seconds: 5));

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body) as Map<String, dynamic>;
            if (data['service'] == 'Geogram Station Server') {
              stationInfo = data;
              workingProtocol = attempt.protocol == 'https' ? 'wss' : 'ws';
              workingPort = attempt.port;
              break;
            } else {
              lastError = 'Not a Geogram Station (service: ${data['service']})';
            }
          } else {
            lastError = 'HTTP ${response.statusCode}';
          }
        } catch (e) {
          // Store last error for better diagnostics
          final errorStr = e.toString();
          if (errorStr.contains('SocketException')) {
            lastError = 'Connection refused';
          } else if (errorStr.contains('TimeoutException')) {
            lastError = 'Connection timeout';
          } else if (errorStr.contains('HandshakeException') || errorStr.contains('CERTIFICATE')) {
            lastError = 'SSL/Certificate error';
          } else {
            lastError = errorStr.length > 50 ? '${errorStr.substring(0, 50)}...' : errorStr;
          }
        }
      }

      if (stationInfo == null || workingPort == null) {
        final triedPorts = attempts.map((a) => '${a.protocol}:${a.port}').join(', ');
        setState(() {
          _statusMessage = lastError != null
              ? 'Could not connect to $host: $lastError (tried $triedPorts)'
              : 'Could not connect to station at $host (tried $triedPorts)';
          _isError = true;
          _isConnecting = false;
        });
        return;
      }

      // Extract station details from API response
      final name = stationInfo['name'] as String? ??
                   stationInfo['callsign'] as String? ??
                   '$host:$workingPort';
      final callsign = stationInfo['callsign'] as String?;
      final description = stationInfo['description'] as String?;

      String? locationStr;
      double? latitude;
      double? longitude;

      // Handle location - can be a string or an object
      final locationData = stationInfo['location'];
      if (locationData is String) {
        locationStr = locationData;
      } else if (locationData is Map<String, dynamic>) {
        final city = locationData['city'] as String?;
        final country = locationData['country'] as String?;
        if (city != null && country != null) {
          locationStr = '$city, $country';
        } else if (city != null) {
          locationStr = city;
        } else if (country != null) {
          locationStr = country;
        }
        latitude = (locationData['latitude'] as num?)?.toDouble();
        longitude = (locationData['longitude'] as num?)?.toDouble();
      }

      // Get lat/lon from top-level if not in location object
      latitude ??= (stationInfo['latitude'] as num?)?.toDouble();
      longitude ??= (stationInfo['longitude'] as num?)?.toDouble();

      setState(() {
        _statusMessage = 'Connected! Found station: $name';
        _isError = false;
      });

      // Wait a moment to show success message
      await Future.delayed(const Duration(milliseconds: 500));

      if (!mounted) return;

      // Build the WebSocket URL, omitting port for standard ports (443 for wss, 80 for ws)
      String wsUrl;
      if ((workingProtocol == 'wss' && workingPort == 443) ||
          (workingProtocol == 'ws' && workingPort == 80)) {
        wsUrl = '$workingProtocol://$host';
      } else {
        wsUrl = '$workingProtocol://$host:$workingPort';
      }

      // Return the station info
      Navigator.pop(context, {
        'name': name,
        'url': wsUrl,
        if (callsign != null) 'callsign': callsign,
        if (locationStr != null) 'location': locationStr,
        if (latitude != null) 'latitude': latitude.toString(),
        if (longitude != null) 'longitude': longitude.toString(),
        if (description != null) 'description': description,
      });

    } catch (e) {
      setState(() {
        _statusMessage = 'Connection failed: $e';
        _isError = true;
        _isConnecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Add Station'),
      content: SizedBox(
        width: 350,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _addressController,
              decoration: const InputDecoration(
                labelText: 'Station Address',
                hintText: 'e.g., 127.0.0.1:8080 or station.example.com',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.dns),
              ),
              autofocus: true,
              enabled: !_isConnecting,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _connect(),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter IP:port or hostname:port',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  if (_isConnecting)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      _isError ? Icons.error : Icons.check_circle,
                      size: 16,
                      color: _isError ? Colors.red : Colors.green,
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _statusMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _isError ? Colors.red : Colors.green,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isConnecting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isConnecting ? null : _connect,
          child: _isConnecting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Connect'),
        ),
      ],
    );
  }
}

// Network Scan Dialog
class _NetworkScanDialog extends StatefulWidget {
  final StationService stationService;
  final I18nService i18n;

  const _NetworkScanDialog({
    required this.stationService,
    required this.i18n,
  });

  @override
  State<_NetworkScanDialog> createState() => _NetworkScanDialogState();
}

class _NetworkScanDialogState extends State<_NetworkScanDialog> {
  final StationDiscoveryService _discoveryService = StationDiscoveryService();
  List<NetworkScanResult> _results = [];
  String _statusMessage = 'Initializing scan...';
  int _scannedHosts = 0;
  int _totalHosts = 1;
  bool _isScanning = true;
  bool _scanComplete = false;
  bool _stopRequested = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    final results = await _discoveryService.scanWithProgress(
      onProgress: (message, scanned, total, foundResults) {
        if (mounted) {
          setState(() {
            _statusMessage = message;
            _scannedHosts = scanned;
            _totalHosts = total > 0 ? total : 1;
            _results = List.from(foundResults);
          });
        }
      },
      shouldCancel: () => _stopRequested,
      timeoutMs: 400, // Fast timeout for LAN scanning
    );

    if (mounted) {
      setState(() {
        _isScanning = false;
        _scanComplete = true;
        _results = results;
      });

      // Auto-add found stations (all results are stations now)
      for (var result in results) {
        await _addStation(result);
      }
    }
  }

  void _stopScan() {
    setState(() {
      _stopRequested = true;
      _statusMessage = 'Stopping scan...';
    });
  }

  Future<void> _addStation(NetworkScanResult result) async {
    try {
      // Build a good name: prefer callsign, then name, then description
      String stationName;
      if (result.callsign != null && result.callsign!.isNotEmpty) {
        stationName = result.callsign!;
      } else if (result.name != null && result.name!.isNotEmpty) {
        stationName = result.name!;
      } else if (result.description != null && result.description!.isNotEmpty) {
        stationName = result.description!;
      } else {
        stationName = 'Station at ${result.ip}';
      }

      final station = Station(
        url: result.wsUrl,
        name: stationName,
        callsign: result.callsign,
        status: 'available',
        location: result.location,
        latitude: result.latitude,
        longitude: result.longitude,
        connectedDevices: result.connectedDevices,
      );

      final added = await widget.stationService.addStation(station);
      if (added) {
        LogService().log('Added station from scan: ${station.name}');
      }
    } catch (e) {
      LogService().log('Error adding station from scan: $e');
    }
  }

  // Station icon (all results are stations now)
  IconData get _stationIcon => Icons.cell_tower;

  // Station color
  Color get _stationColor => Colors.blue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _totalHosts > 0 ? _scannedHosts / _totalHosts : 0.0;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.radar, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          const Text('Network Scan'),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Progress section
            if (_isScanning) ...[
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              Text(
                _statusMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Scanned $_scannedHosts of $_totalHosts hosts',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Results section
            if (_results.isNotEmpty) ...[
              Text(
                'Found ${_results.length} station${_results.length == 1 ? "" : "s"}:',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 300),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final result = _results[index];
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        backgroundColor: _stationColor.withOpacity(0.2),
                        child: Icon(
                          _stationIcon,
                          color: _stationColor,
                          size: 20,
                        ),
                      ),
                      title: Text(
                        result.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (result.description != null && result.description!.isNotEmpty)
                            Text(
                              result.description!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          Text(
                            '${result.ip}:${result.port}',
                            style: TextStyle(
                              color: theme.colorScheme.outline,
                              fontSize: 11,
                            ),
                          ),
                          if (result.location != null)
                            Text(
                              result.location!,
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontSize: 11,
                              ),
                            ),
                          if (result.connectedDevices != null)
                            Text(
                              '${result.connectedDevices} connected',
                              style: TextStyle(
                                color: theme.colorScheme.tertiary,
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                      trailing: Icon(_stationIcon, color: _stationColor, size: 20),
                    );
                  },
                ),
              ),
            ] else if (_scanComplete) ...[
              Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.search_off,
                      size: 48,
                      color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'No stations found on local network',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tips:\n'
                      '  - Make sure stations are running\n'
                      '  - Check firewall settings\n'
                      '  - Ensure stations are on the same network',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (_scanComplete && _results.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'Stations have been added automatically',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.green,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_isScanning) ...[
          TextButton(
            onPressed: () => Navigator.pop(context, <NetworkScanResult>[]),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _stopRequested ? null : _stopScan,
            child: Text(_stopRequested ? 'Stopping...' : 'Stop & Use Results'),
          ),
        ] else
          FilledButton(
            onPressed: () => Navigator.pop(context, _results),
            child: const Text('Done'),
          ),
      ],
    );
  }
}
