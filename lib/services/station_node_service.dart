/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:isolate';
import 'package:path/path.dart' as path;
import '../models/monitored_task.dart';
import '../models/station_node.dart';
import '../models/station_network.dart';
import '../util/nostr_key_generator.dart';
import '../util/nostr_crypto.dart';
import '../station.dart';
import '../cli/pure_storage_config.dart';
import 'config_service.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'storage_config.dart';
import 'log_api_service.dart';
import '../util/task_monitor_helpers.dart';

/// Service for managing this device as a station node
class StationNodeService {
  static final StationNodeService _instance = StationNodeService._internal();
  factory StationNodeService() => _instance;
  StationNodeService._internal();

  final ConfigService _configService = ConfigService();
  final ProfileService _profileService = ProfileService();

  /// The actual station server (shared with CLI)
  PureStationServer? _stationServer;

  StationNode? _stationNode;
  StationNetwork? _network;
  bool _initialized = false;
  DateTime? _startedAt;
  MonitoredPeriodicTimer? _statsTimer;

  // Storage measurement cache
  int _cachedStorageUsedMb = 0;
  DateTime? _lastStorageMeasurement;
  static const _storageMeasurementInterval = Duration(days: 1);

  // Remote stations management
  List<StationNode> _remoteStations = [];

  /// Get the underlying station server
  PureStationServer? get stationServer => _stationServer;

  // Stream controllers for state changes
  final _stateController = StreamController<StationNode?>.broadcast();
  Stream<StationNode?> get stateStream => _stateController.stream;

  /// Get current station node (if configured)
  StationNode? get stationNode => _stationNode;

  /// Get current network (if joined/created)
  StationNetwork? get network => _network;

  /// Check if station mode is enabled
  bool get isStationEnabled => _stationNode != null;

  /// Check if station is running
  bool get isRunning => _stationNode?.isRunning ?? false;

  /// Get local station (if exists)
  StationNode? get localStation => _stationNode?.isRemote == false ? _stationNode : null;

  /// Get list of remote stations
  List<StationNode> get remoteStations => List.unmodifiable(_remoteStations);

  /// Get all stations (local + remote)
  List<StationNode> get allStations {
    final stations = <StationNode>[];
    if (_stationNode != null && !_stationNode!.isRemote) {
      stations.add(_stationNode!);
    }
    stations.addAll(_remoteStations);
    return stations;
  }

  /// Initialize the station node service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _loadStationConfig();
      _initialized = true;
      LogService().log('StationNodeService initialized');

      // Load cached storage stats
      await _loadStorageStats();

      // Trigger storage measurement in background (will skip if measured recently)
      measureStorageUsage();  // Don't await - runs in background

      // Auto-start if was enabled before (user had explicitly started the station)
      if (_stationNode != null) {
        final networkSettings = await loadNetworkSettings();
        final wasEnabled = networkSettings['enabled'] as bool? ?? false;
        if (wasEnabled) {
          LogService().log('Station auto-start: was enabled, starting automatically...');
          await start();
        }
      }
    } catch (e) {
      LogService().log('Error initializing StationNodeService: $e');
    }
  }

  /// Load station configuration from storage
  Future<void> _loadStationConfig() async {
    // First try to load from GUI's config
    final stationData = _configService.get('stationNode');
    if (stationData != null) {
      _stationNode = StationNode.fromJson(stationData as Map<String, dynamic>);

      // Always reset status to stopped on load - server can't persist across restarts
      if (_stationNode!.status == StationNodeStatus.running ||
          _stationNode!.status == StationNodeStatus.starting) {
        _stationNode = _stationNode!.copyWith(
          status: StationNodeStatus.stopped,
          errorMessage: null,
        );
        _saveStationConfig();
        LogService().log('Reset station status to stopped (server cannot persist across restarts)');
      }

      LogService().log('Loaded station node: ${_stationNode!.name} (${_stationNode!.typeDisplay})');
    }

    final networkData = _configService.get('stationNetwork');
    if (networkData != null) {
      _network = StationNetwork.fromJson(networkData as Map<String, dynamic>);
      LogService().log('Loaded network: ${_network!.name}');
    }

    // Load remote stations
    final remoteStationsData = _configService.get('remoteStations');
    if (remoteStationsData != null) {
      _remoteStations = (remoteStationsData as List<dynamic>)
          .map((s) => StationNode.fromJson(s as Map<String, dynamic>))
          .toList();
      LogService().log('Loaded ${_remoteStations.length} remote station(s)');
    }

    // If no station config found, check CLI's station_config.json
    if (_stationNode == null) {
      await _loadFromCliConfig();
    }
  }

  /// Load station configuration from CLI's station_config.json
  Future<void> _loadFromCliConfig() async {
    try {
      final storageConfig = StorageConfig();
      if (!storageConfig.isInitialized) return;

      final configFile = File(storageConfig.stationConfigPath);
      if (!await configFile.exists()) return;

      final content = await configFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;

      // Check if this has station settings (CLI format)
      if (json.containsKey('port') || json.containsKey('callsign')) {
        final profile = _profileService.getProfile();
        final now = DateTime.now();

        // Determine station type from stationRole
        final stationRole = json['stationRole'] as String? ?? 'root';
        final stationType = stationRole == 'node' ? StationType.node : StationType.root;

        // Create a StationNode from CLI settings
        _stationNode = StationNode(
          id: json['networkId'] as String? ?? _generateId(),
          name: json['description'] as String? ?? 'Station',
          stationCallsign: json['callsign'] as String? ?? profile.callsign,
          stationNpub: profile.npub,
          stationNsec: profile.nsec,
          operatorCallsign: profile.callsign,
          operatorNpub: profile.npub,
          type: stationType,
          networkId: json['networkId'] as String?,
          networkName: json['description'] as String? ?? 'Network',
          config: StationNodeConfig(
            storage: StationStorageConfig(
              allocatedMb: json['maxCacheSize'] as int? ?? 1000,
            ),
          ),
          status: (json['enabled'] as bool? ?? false)
              ? StationNodeStatus.running
              : StationNodeStatus.stopped,
          created: now,
          updated: now,
        );

        LogService().log('Loaded station from CLI config: ${_stationNode!.name}');

        // Save to GUI config format for future loads
        _saveStationConfig();
      }
    } catch (e) {
      LogService().log('Error loading CLI station config: $e');
    }
  }

  /// Save station configuration to storage
  void _saveStationConfig() {
    if (_stationNode != null) {
      _configService.set('stationNode', _stationNode!.toJson());
    } else {
      _configService.remove('stationNode');
    }

    if (_network != null) {
      _configService.set('stationNetwork', _network!.toJson());
    } else {
      _configService.remove('stationNetwork');
    }

    // Save remote stations
    if (_remoteStations.isNotEmpty) {
      _configService.set('remoteStations', _remoteStations.map((s) => s.toJson()).toList());
    } else {
      _configService.remove('remoteStations');
    }
  }

  /// Create a new root station network
  Future<StationNode> createRootStation({
    required String networkName,
    required String networkDescription,
    required String operatorCallsign,
    required StationNodeConfig config,
    NetworkPolicy policy = const NetworkPolicy(),
    NetworkApps apps = const NetworkApps(),
  }) async {
    final profile = _profileService.getProfile();
    if (profile.npub == null || profile.npub!.isEmpty) {
      throw Exception('Profile npub is required to create a station');
    }

    final now = DateTime.now();
    final id = _generateId();
    final networkId = _generateId();

    // Generate station identity (X3 callsign)
    final stationKeys = NostrKeys.forRelay();
    LogService().log('Generated station identity: ${stationKeys.callsign} (${stationKeys.npub.substring(0, 20)}...)');

    // Create the network with station as root
    _network = StationNetwork(
      id: networkId,
      name: networkName,
      description: networkDescription,
      rootNpub: stationKeys.npub,  // Root is the station's npub
      rootCallsign: stationKeys.callsign,  // Root callsign is X3
      policy: policy,
      apps: apps,
      founded: now,
      updated: now,
    );

    // Create the station node with separate identities
    _stationNode = StationNode(
      id: id,
      name: networkName,
      stationCallsign: stationKeys.callsign,  // X3 callsign
      stationNpub: stationKeys.npub,
      stationNsec: stationKeys.nsec,
      operatorCallsign: operatorCallsign,  // X1 callsign from profile
      operatorNpub: profile.npub!,
      type: StationType.root,
      networkId: networkId,
      networkName: networkName,
      config: config,
      status: StationNodeStatus.stopped,
      created: now,
      updated: now,
    );

    _saveStationConfig();
    await _createStationDirectories();

    LogService().log('Created root station: $networkName (station: ${stationKeys.callsign}, operator: $operatorCallsign)');
    _stateController.add(_stationNode);

    return _stationNode!;
  }

  /// Join an existing network as a node station
  Future<StationNode> joinAsNode({
    required String nodeName,
    required String operatorCallsign,
    required StationNetwork network,
    required StationNodeConfig config,
  }) async {
    final profile = _profileService.getProfile();
    if (profile.npub == null || profile.npub!.isEmpty) {
      throw Exception('Profile npub is required to join a network');
    }

    final now = DateTime.now();
    final id = _generateId();

    // Generate station identity (X3 callsign)
    final stationKeys = NostrKeys.forRelay();
    LogService().log('Generated station identity: ${stationKeys.callsign} (${stationKeys.npub.substring(0, 20)}...)');

    _network = network;

    _stationNode = StationNode(
      id: id,
      name: nodeName,
      stationCallsign: stationKeys.callsign,  // X3 callsign
      stationNpub: stationKeys.npub,
      stationNsec: stationKeys.nsec,
      operatorCallsign: operatorCallsign,  // X1 callsign from profile
      operatorNpub: profile.npub!,
      type: StationType.node,
      networkId: network.id,
      networkName: network.name,
      rootNpub: network.rootNpub,
      rootCallsign: network.rootCallsign,
      config: config,
      status: StationNodeStatus.stopped,
      created: now,
      updated: now,
    );

    _saveStationConfig();
    await _createStationDirectories();

    LogService().log('Joined network as node: $nodeName (station: ${stationKeys.callsign}, operator: $operatorCallsign)');
    _stateController.add(_stationNode);

    return _stationNode!;
  }

  /// Start the station
  Future<void> start() async {
    if (_stationNode == null) {
      throw Exception('No station configured');
    }

    if (_stationNode!.isRunning) {
      LogService().log('Station already running');
      return;
    }

    LogService().log('Starting station: ${_stationNode!.name}');

    _stationNode = _stationNode!.copyWith(
      status: StationNodeStatus.starting,
      updated: DateTime.now(),
    );
    _stateController.add(_stationNode);

    try {
      // Initialize PureStorageConfig if not already done
      final pureStorageConfig = PureStorageConfig();
      final guiStorageConfig = StorageConfig();

      LogService().log('GUI StorageConfig path: ${guiStorageConfig.stationConfigPath}');

      if (!pureStorageConfig.isInitialized) {
        // Use same base directory as GUI StorageConfig
        await pureStorageConfig.init(customBaseDir: guiStorageConfig.baseDir);
        LogService().log('PureStorageConfig initialized with GUI baseDir');
      }

      LogService().log('PureStorageConfig path: ${pureStorageConfig.stationConfigPath}');

      // Stop LogApiService to release the HTTP port — the station server
      // handles a superset of its routes while running.
      await LogApiService().stop();
      LogService().log('LogApiService stopped to free port for station server');

      // Load network settings from the file to get the correct port
      final networkSettings = await loadNetworkSettings();
      final savedHttpPort = networkSettings['httpPort'] as int;
      LogService().log('Loaded httpPort from file: $savedHttpPort');

      // Create and initialize the station server
      _stationServer = PureStationServer();
      await _stationServer!.initialize();

      LogService().log('After initialize, server httpPort: ${_stationServer!.settings.httpPort}');

      // IMPORTANT: Apply the saved network settings to ensure correct port is used
      _stationServer!.settings.httpPort = savedHttpPort;
      _stationServer!.settings.httpsPort = networkSettings['httpsPort'] as int;
      _stationServer!.settings.enableSsl = networkSettings['enableSsl'] as bool;
      _stationServer!.settings.maxConnectedDevices = networkSettings['maxConnectedDevices'] as int;
      final sslDomain = networkSettings['sslDomain'];
      if (sslDomain != null && sslDomain.toString().isNotEmpty) {
        _stationServer!.settings.sslDomain = sslDomain.toString();
      }
      final sslEmail = networkSettings['sslEmail'];
      if (sslEmail != null && sslEmail.toString().isNotEmpty) {
        _stationServer!.settings.sslEmail = sslEmail.toString();
      }
      _stationServer!.settings.sslAutoRenew = networkSettings['sslAutoRenew'] as bool;

      // Configure server settings from station node config
      _stationServer!.settings.npub = _stationNode!.stationNpub;
      _stationServer!.settings.nsec = _stationNode!.stationNsec ?? '';
      _stationServer!.settings.name = _stationNode!.name;
      _stationServer!.settings.description = _stationNode!.networkName;
      _stationServer!.settings.stationRole = _stationNode!.isRoot ? 'root' : 'node';
      _stationServer!.settings.networkId = _stationNode!.networkId;
      if (_stationNode!.config.coverage != null) {
        _stationServer!.settings.latitude = _stationNode!.config.coverage!.latitude;
        _stationServer!.settings.longitude = _stationNode!.config.coverage!.longitude;
      }
      _stationServer!.settings.maxCacheSizeMB = _stationNode!.config.storage?.allocatedMb ?? 10000;

      // Save settings and start server
      await _stationServer!.saveSettings();

      // Final verification before starting
      final portToUse = _stationServer!.settings.httpPort;
      LogService().log('FINAL PORT CHECK: Server will start on port $portToUse');

      final success = await _stationServer!.start();

      LogService().log('Server start result: $success, port was: $portToUse');

      if (!success) {
        final port = _stationServer!.settings.httpPort;
        throw Exception('Failed to start station server on port $port. The port may already be in use.');
      }

      // Double-check server is actually running
      if (!_stationServer!.isRunning) {
        throw Exception('Server started but is not running. Check logs for details.');
      }

      _startedAt = DateTime.now();
      _stationNode = _stationNode!.copyWith(
        status: StationNodeStatus.running,
        updated: DateTime.now(),
      );

      // Start stats update timer
      _statsTimer?.cancel();
      _statsTimer = MonitoredPeriodicTimer(
        id: 'station_node.stats',
        name: 'Node Stats',
        description: 'Refreshes station node statistics',
        serviceName: 'StationNodeService',
        interval: const Duration(seconds: 30),
        priority: TaskPriority.low,
        callback: (_) => _updateStats(),
      );

      _saveStationConfig();
      _stateController.add(_stationNode);

      // Persist that the station should auto-start on next app launch
      await updateNetworkSettings(enabled: true);

      LogService().log('Station started successfully on port ${_stationServer!.settings.httpPort}');
    } catch (e) {
      _stationServer = null;
      _stationNode = _stationNode!.copyWith(
        status: StationNodeStatus.error,
        errorMessage: e.toString(),
        updated: DateTime.now(),
      );
      _stateController.add(_stationNode);
      LogService().log('Failed to start station: $e');
      rethrow;
    }
  }

  /// Stop the station
  Future<void> stop() async {
    if (_stationNode == null || !_stationNode!.isRunning) {
      return;
    }

    LogService().log('Stopping station: ${_stationNode!.name}');

    _stationNode = _stationNode!.copyWith(
      status: StationNodeStatus.stopping,
      updated: DateTime.now(),
    );
    _stateController.add(_stationNode);

    try {
      // Stop the actual station server
      if (_stationServer != null) {
        await _stationServer!.stop();
        _stationServer = null;
      }

      _statsTimer?.cancel();
      _statsTimer = null;

      _stationNode = _stationNode!.copyWith(
        status: StationNodeStatus.stopped,
        updated: DateTime.now(),
      );
      _startedAt = null;

      _saveStationConfig();
      _stateController.add(_stationNode);

      // Persist that the station should NOT auto-start on next app launch
      await updateNetworkSettings(enabled: false);

      LogService().log('Station stopped');

      // Restart LogApiService now that the station has released the port
      try {
        await LogApiService().start();
        LogService().log('LogApiService restarted after station stop');
      } catch (e) {
        LogService().log('Failed to restart LogApiService: $e');
      }
    } catch (e) {
      _stationNode = _stationNode!.copyWith(
        status: StationNodeStatus.error,
        errorMessage: e.toString(),
        updated: DateTime.now(),
      );
      _stateController.add(_stationNode);
      LogService().log('Error stopping station: $e');
    }
  }

  /// Update station configuration
  Future<void> updateConfig(StationNodeConfig config) async {
    if (_stationNode == null) {
      throw Exception('No station configured');
    }

    _stationNode = _stationNode!.copyWith(
      config: config,
      updated: DateTime.now(),
    );

    _saveStationConfig();
    _stateController.add(_stationNode);

    LogService().log('Station config updated');
  }

  /// Update network settings (port, SSL, etc.) and save directly to file
  /// This works even when the server is not running
  Future<void> updateNetworkSettings({
    int? httpPort,
    int? httpsPort,
    bool? enableSsl,
    String? sslDomain,
    String? sslEmail,
    bool? sslAutoRenew,
    int? maxConnections,
    bool? enabled,
    bool? nostrRequireAuthForWrites,
    int? blossomMaxStorageMb,
    int? blossomMaxFileMb,
  }) async {
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      throw Exception('Storage not initialized');
    }

    final configFile = File(storageConfig.stationConfigPath);
    Map<String, dynamic> settings = {};

    // Load existing settings if file exists
    if (await configFile.exists()) {
      try {
        final content = await configFile.readAsString();
        settings = jsonDecode(content) as Map<String, dynamic>;
      } catch (e) {
        LogService().log('Error loading existing settings: $e');
      }
    }

    // Update only the provided values
    if (httpPort != null) settings['httpPort'] = httpPort;
    if (httpsPort != null) settings['httpsPort'] = httpsPort;
    if (enableSsl != null) settings['enableSsl'] = enableSsl;
    if (sslDomain != null) settings['sslDomain'] = sslDomain;
    if (sslEmail != null) settings['sslEmail'] = sslEmail;
    if (sslAutoRenew != null) settings['sslAutoRenew'] = sslAutoRenew;
    if (maxConnections != null) settings['maxConnectedDevices'] = maxConnections;
    if (enabled != null) settings['enabled'] = enabled;
    if (nostrRequireAuthForWrites != null) {
      settings['nostrRequireAuthForWrites'] = nostrRequireAuthForWrites;
    }
    if (blossomMaxStorageMb != null) settings['blossomMaxStorageMb'] = blossomMaxStorageMb;
    if (blossomMaxFileMb != null) settings['blossomMaxFileMb'] = blossomMaxFileMb;

    // Save to file
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings),
    );

    LogService().log('Network settings saved to file (httpPort: ${settings['httpPort']}, enabled: ${settings['enabled']})');

    // Also update server settings if server is running
    if (_stationServer != null) {
      if (httpPort != null) _stationServer!.settings.httpPort = httpPort;
      if (httpsPort != null) _stationServer!.settings.httpsPort = httpsPort;
      if (enableSsl != null) _stationServer!.settings.enableSsl = enableSsl;
      if (sslDomain != null) _stationServer!.settings.sslDomain = sslDomain;
      if (sslEmail != null) _stationServer!.settings.sslEmail = sslEmail;
      if (sslAutoRenew != null) _stationServer!.settings.sslAutoRenew = sslAutoRenew;
      if (maxConnections != null) _stationServer!.settings.maxConnectedDevices = maxConnections;
      if (enabled != null) _stationServer!.settings.enabled = enabled;
    }
  }

  /// Load network settings from file (for displaying in UI)
  Future<Map<String, dynamic>> loadNetworkSettings() async {
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      return _defaultNetworkSettings();
    }

    final configFile = File(storageConfig.stationConfigPath);
    if (!await configFile.exists()) {
      return _defaultNetworkSettings();
    }

    try {
      final content = await configFile.readAsString();
      final settings = jsonDecode(content) as Map<String, dynamic>;
      return {
        'httpPort': settings['httpPort'] ?? 3456,
        'httpsPort': settings['httpsPort'] ?? 3457,
        'enableSsl': settings['enableSsl'] ?? true,
        'sslDomain': settings['sslDomain'] ?? '',
        'sslEmail': settings['sslEmail'] ?? '',
        'sslAutoRenew': settings['sslAutoRenew'] ?? true,
        'maxConnectedDevices': settings['maxConnectedDevices'] ?? 100,
        'enabled': settings['enabled'] ?? false,
      };
    } catch (e) {
      LogService().log('Error loading network settings: $e');
      return _defaultNetworkSettings();
    }
  }

  Map<String, dynamic> _defaultNetworkSettings() {
    return {
      'httpPort': 3456,
      'httpsPort': 3457,
      'enableSsl': true,
      'sslDomain': '',
      'sslEmail': '',
      'sslAutoRenew': true,
      'maxConnectedDevices': 100,
      'enabled': false,
    };
  }

  /// Delete station configuration and leave network
  Future<void> deleteStation() async {
    if (_stationNode == null) return;

    // Stop if running
    if (_stationNode!.isRunning) {
      await stop();
    }

    LogService().log('Deleting station: ${_stationNode!.name}');

    // Clean up directories
    await _deleteStationDirectories();

    _stationNode = null;
    _network = null;

    _saveStationConfig();
    _stateController.add(null);

    LogService().log('Station deleted');
  }

  /// Connect to a remote station for management
  Future<StationNode> connectToRemoteStation({
    required String url,
    required String nsec,
    required String name,
    required Map<String, dynamic> remoteStatus,
  }) async {
    final profile = _profileService.getProfile();
    final now = DateTime.now();

    // Get station info from remote status
    final stationCallsign = remoteStatus['callsign'] as String? ?? 'REMOTE';
    final privateKeyHex = NostrCrypto.decodeNsec(nsec);
    final publicKeyHex = NostrCrypto.derivePublicKey(privateKeyHex);
    final stationNpub = NostrCrypto.encodeNpub(publicKeyHex);

    final remoteNode = StationNode(
      id: 'remote_${now.millisecondsSinceEpoch}',
      name: name,
      stationCallsign: stationCallsign,
      stationNpub: stationNpub,
      stationNsec: nsec,
      operatorCallsign: profile.callsign ?? 'OPERATOR',
      operatorNpub: profile.npub ?? '',
      type: StationType.root,
      status: StationNodeStatus.running, // Remote is running since we connected
      created: now,
      updated: now,
      isRemote: true,
      remoteUrl: url,
    );

    _remoteStations.add(remoteNode);
    _saveStationConfig();

    LogService().log('Connected to remote station: $name at $url');

    return remoteNode;
  }

  /// Remove a remote station
  Future<void> removeRemoteStation(String stationId) async {
    _remoteStations.removeWhere((s) => s.id == stationId);
    _saveStationConfig();
    LogService().log('Removed remote station: $stationId');
  }

  /// Get station data directory
  Future<Directory> getStationDirectory() async {
    return Directory(path.join(StorageConfig().baseDir, 'station'));
  }

  /// Create station directories
  Future<void> _createStationDirectories() async {
    final stationDir = await getStationDirectory();

    final directories = [
      '',
      'authorities',
      'authorities/admins',
      'authorities/group-admins',
      'authorities/moderators',
      'apps',
      'apps/approved',
      'apps/pending',
      'apps/suspended',
      'apps/banned',
      'public',
      'public/forum',
      'public/chat',
      'public/announcements',
      'peers',
      'peers/nodes',
      'banned',
      'banned/users',
      'reputation',
      'points',
      'points/current',
      'points/historical',
      'sync',
      'sync/nodes',
      'logs',
    ];

    for (final dir in directories) {
      final dirPath = path.join(stationDir.path, dir);
      await Directory(dirPath).create(recursive: true);
    }

    // Create initial config files
    await _createInitialFiles(stationDir);

    LogService().log('Created station directories at: ${stationDir.path}');
  }

  /// Create initial station configuration files
  Future<void> _createInitialFiles(Directory stationDir) async {
    if (_stationNode == null || _network == null) return;

    // station.json
    final stationFile = File(path.join(stationDir.path, 'station.json'));
    await stationFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_stationNode!.toJson()),
    );

    // network.json
    final networkFile = File(path.join(stationDir.path, 'network.json'));
    await networkFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_network!.toJson()),
    );

    // authorities/root.txt (if root)
    if (_stationNode!.isRoot) {
      final rootFile = File(path.join(stationDir.path, 'authorities', 'root.txt'));
      await rootFile.writeAsString('''
# ROOT: ${_network!.name}

## Station Identity (X3)
STATION_CALLSIGN: ${_stationNode!.stationCallsign}
STATION_NPUB: ${_stationNode!.stationNpub}

## Operator Identity (X1)
OPERATOR_CALLSIGN: ${_stationNode!.operatorCallsign}
OPERATOR_NPUB: ${_stationNode!.operatorNpub}

CREATED: ${_stationNode!.created.toIso8601String()}

Network founder and ultimate authority.

The station (${_stationNode!.stationCallsign}) is managed by operator ${_stationNode!.operatorCallsign}.
''');
    }
  }

  /// Delete station directories
  Future<void> _deleteStationDirectories() async {
    final stationDir = await getStationDirectory();
    if (await stationDir.exists()) {
      await stationDir.delete(recursive: true);
      LogService().log('Deleted station directories');
    }
  }

  /// Get the storage stats cache file path
  Future<File> _getStorageStatsFile() async {
    final storageConfig = StorageConfig();
    final statsPath = path.join(storageConfig.baseDir, 'storage_stats.json');
    return File(statsPath);
  }

  /// Load cached storage measurement from file
  Future<void> _loadStorageStats() async {
    try {
      final file = await _getStorageStatsFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _cachedStorageUsedMb = json['usedMb'] as int? ?? 0;
        final lastMeasured = json['lastMeasured'] as String?;
        if (lastMeasured != null) {
          _lastStorageMeasurement = DateTime.tryParse(lastMeasured);
        }
        LogService().log('Loaded cached storage stats: ${_cachedStorageUsedMb}MB');
      }
    } catch (e) {
      LogService().log('Error loading storage stats: $e');
    }
  }

  /// Save storage measurement to file
  Future<void> _saveStorageStats() async {
    try {
      final file = await _getStorageStatsFile();
      final json = {
        'usedMb': _cachedStorageUsedMb,
        'lastMeasured': _lastStorageMeasurement?.toIso8601String(),
      };
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
      LogService().log('Saved storage stats: ${_cachedStorageUsedMb}MB');
    } catch (e) {
      LogService().log('Error saving storage stats: $e');
    }
  }

  /// Calculate folder size in an isolate (background thread)
  static Future<int> _calculateFolderSizeInIsolate(String folderPath) async {
    return await Isolate.run(() {
      int totalBytes = 0;
      try {
        final dir = Directory(folderPath);
        if (dir.existsSync()) {
          for (final entity in dir.listSync(recursive: true, followLinks: false)) {
            if (entity is File) {
              try {
                totalBytes += entity.lengthSync();
              } catch (_) {
                // Skip files we can't access
              }
            }
          }
        }
      } catch (e) {
        // Return 0 on error
      }
      return totalBytes;
    });
  }

  /// Measure actual storage used by the profile folder
  Future<void> measureStorageUsage({bool force = false}) async {
    // Check if we need to measure (once a day unless forced)
    if (!force && _lastStorageMeasurement != null) {
      final timeSinceLast = DateTime.now().difference(_lastStorageMeasurement!);
      if (timeSinceLast < _storageMeasurementInterval) {
        LogService().log('Skipping storage measurement - last measured ${timeSinceLast.inHours}h ago');
        return;
      }
    }

    LogService().log('Starting storage measurement in background...');

    try {
      final storageConfig = StorageConfig();
      final profileDir = storageConfig.baseDir;

      // Run in isolate to not block UI
      final totalBytes = await _calculateFolderSizeInIsolate(profileDir);

      // Convert to MB
      _cachedStorageUsedMb = (totalBytes / (1024 * 1024)).round();
      _lastStorageMeasurement = DateTime.now();

      // Save to file
      await _saveStorageStats();

      LogService().log('Storage measurement complete: ${_cachedStorageUsedMb}MB used');
    } catch (e) {
      LogService().log('Error measuring storage: $e');
    }
  }

  /// Get current storage used in MB (from cache)
  int get storageUsedMb => _cachedStorageUsedMb;

  /// Update station statistics
  void _updateStats() {
    if (_stationNode == null || !_stationNode!.isRunning) return;

    final uptime = _startedAt != null
        ? DateTime.now().difference(_startedAt!)
        : Duration.zero;

    // Get actual stats from the station server
    final serverStats = _stationServer?.stats;
    final stats = StationNodeStats(
      connectedDevices: _stationServer?.connectedDevices ?? 0,
      messagesRelayed: serverStats?.totalMessages ?? 0,
      appsServed: serverStats?.totalApiRequests ?? 0,
      storageUsedMb: _cachedStorageUsedMb,  // Use cached measurement
      lastActivity: DateTime.now(),
      uptime: uptime,
    );

    _stationNode = _stationNode!.copyWith(
      stats: stats,
      updated: DateTime.now(),
    );
    _stateController.add(_stationNode);
  }

  /// Generate a unique ID
  String _generateId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final random = (DateTime.now().microsecond * 1000).toRadixString(16);
    return '$timestamp$random'.substring(0, 16);
  }

  /// Dispose resources
  Future<void> dispose() async {
    _statsTimer?.cancel();
    // Stop the station server if running
    if (_stationServer != null && _stationServer!.isRunning) {
      await _stationServer!.stop();
      _stationServer = null;
    }
    _stateController.close();
  }
}
