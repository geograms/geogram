/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../models/relay_node.dart';
import '../models/relay_network.dart';
import '../util/nostr_key_generator.dart';
import 'config_service.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'storage_config.dart';

/// Service for managing this device as a relay node
class RelayNodeService {
  static final RelayNodeService _instance = RelayNodeService._internal();
  factory RelayNodeService() => _instance;
  RelayNodeService._internal();

  final ConfigService _configService = ConfigService();
  final ProfileService _profileService = ProfileService();

  RelayNode? _relayNode;
  RelayNetwork? _network;
  bool _initialized = false;
  DateTime? _startedAt;
  Timer? _statsTimer;

  // Stream controllers for state changes
  final _stateController = StreamController<RelayNode?>.broadcast();
  Stream<RelayNode?> get stateStream => _stateController.stream;

  /// Get current relay node (if configured)
  RelayNode? get relayNode => _relayNode;

  /// Get current network (if joined/created)
  RelayNetwork? get network => _network;

  /// Check if relay mode is enabled
  bool get isRelayEnabled => _relayNode != null;

  /// Check if relay is running
  bool get isRunning => _relayNode?.isRunning ?? false;

  /// Initialize the relay node service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _loadRelayConfig();
      _initialized = true;
      LogService().log('RelayNodeService initialized');

      // Auto-start if was running before
      if (_relayNode != null && _configService.get('relayAutoStart') == true) {
        await start();
      }
    } catch (e) {
      LogService().log('Error initializing RelayNodeService: $e');
    }
  }

  /// Load relay configuration from storage
  Future<void> _loadRelayConfig() async {
    // First try to load from GUI's config
    final relayData = _configService.get('relayNode');
    if (relayData != null) {
      _relayNode = RelayNode.fromJson(relayData as Map<String, dynamic>);
      LogService().log('Loaded relay node: ${_relayNode!.name} (${_relayNode!.typeDisplay})');
    }

    final networkData = _configService.get('relayNetwork');
    if (networkData != null) {
      _network = RelayNetwork.fromJson(networkData as Map<String, dynamic>);
      LogService().log('Loaded network: ${_network!.name}');
    }

    // If no relay config found, check CLI's relay_config.json
    if (_relayNode == null) {
      await _loadFromCliConfig();
    }
  }

  /// Load relay configuration from CLI's relay_config.json
  Future<void> _loadFromCliConfig() async {
    try {
      final storageConfig = StorageConfig();
      if (!storageConfig.isInitialized) return;

      final configFile = File(storageConfig.relayConfigPath);
      if (!await configFile.exists()) return;

      final content = await configFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;

      // Check if this has relay settings (CLI format)
      if (json.containsKey('port') || json.containsKey('callsign')) {
        final profile = _profileService.getProfile();
        final now = DateTime.now();

        // Determine relay type from relayRole
        final relayRole = json['relayRole'] as String? ?? 'root';
        final relayType = relayRole == 'node' ? RelayType.node : RelayType.root;

        // Create a RelayNode from CLI settings
        _relayNode = RelayNode(
          id: json['networkId'] as String? ?? _generateId(),
          name: json['description'] as String? ?? 'Relay',
          relayCallsign: json['callsign'] as String? ?? profile.callsign,
          relayNpub: profile.npub,
          relayNsec: profile.nsec,
          operatorCallsign: profile.callsign,
          operatorNpub: profile.npub,
          type: relayType,
          networkId: json['networkId'] as String?,
          networkName: json['description'] as String? ?? 'Network',
          config: RelayNodeConfig(
            storage: RelayStorageConfig(
              allocatedMb: json['maxCacheSize'] as int? ?? 1000,
            ),
          ),
          status: (json['enabled'] as bool? ?? false)
              ? RelayNodeStatus.running
              : RelayNodeStatus.stopped,
          created: now,
          updated: now,
        );

        LogService().log('Loaded relay from CLI config: ${_relayNode!.name}');

        // Save to GUI config format for future loads
        _saveRelayConfig();
      }
    } catch (e) {
      LogService().log('Error loading CLI relay config: $e');
    }
  }

  /// Save relay configuration to storage
  void _saveRelayConfig() {
    if (_relayNode != null) {
      _configService.set('relayNode', _relayNode!.toJson());
    } else {
      _configService.remove('relayNode');
    }

    if (_network != null) {
      _configService.set('relayNetwork', _network!.toJson());
    } else {
      _configService.remove('relayNetwork');
    }
  }

  /// Create a new root relay network
  Future<RelayNode> createRootRelay({
    required String networkName,
    required String networkDescription,
    required String operatorCallsign,
    required RelayNodeConfig config,
    NetworkPolicy policy = const NetworkPolicy(),
    NetworkCollections collections = const NetworkCollections(),
  }) async {
    final profile = _profileService.getProfile();
    if (profile.npub == null || profile.npub!.isEmpty) {
      throw Exception('Profile npub is required to create a relay');
    }

    final now = DateTime.now();
    final id = _generateId();
    final networkId = _generateId();

    // Generate relay identity (X3 callsign)
    final relayKeys = NostrKeys.forRelay();
    LogService().log('Generated relay identity: ${relayKeys.callsign} (${relayKeys.npub.substring(0, 20)}...)');

    // Create the network with relay as root
    _network = RelayNetwork(
      id: networkId,
      name: networkName,
      description: networkDescription,
      rootNpub: relayKeys.npub,  // Root is the relay's npub
      rootCallsign: relayKeys.callsign,  // Root callsign is X3
      policy: policy,
      collections: collections,
      founded: now,
      updated: now,
    );

    // Create the relay node with separate identities
    _relayNode = RelayNode(
      id: id,
      name: networkName,
      relayCallsign: relayKeys.callsign,  // X3 callsign
      relayNpub: relayKeys.npub,
      relayNsec: relayKeys.nsec,
      operatorCallsign: operatorCallsign,  // X1 callsign from profile
      operatorNpub: profile.npub!,
      type: RelayType.root,
      networkId: networkId,
      networkName: networkName,
      config: config,
      status: RelayNodeStatus.stopped,
      created: now,
      updated: now,
    );

    _saveRelayConfig();
    await _createRelayDirectories();

    LogService().log('Created root relay: $networkName (relay: ${relayKeys.callsign}, operator: $operatorCallsign)');
    _stateController.add(_relayNode);

    return _relayNode!;
  }

  /// Join an existing network as a node relay
  Future<RelayNode> joinAsNode({
    required String nodeName,
    required String operatorCallsign,
    required RelayNetwork network,
    required RelayNodeConfig config,
  }) async {
    final profile = _profileService.getProfile();
    if (profile.npub == null || profile.npub!.isEmpty) {
      throw Exception('Profile npub is required to join a network');
    }

    final now = DateTime.now();
    final id = _generateId();

    // Generate relay identity (X3 callsign)
    final relayKeys = NostrKeys.forRelay();
    LogService().log('Generated relay identity: ${relayKeys.callsign} (${relayKeys.npub.substring(0, 20)}...)');

    _network = network;

    _relayNode = RelayNode(
      id: id,
      name: nodeName,
      relayCallsign: relayKeys.callsign,  // X3 callsign
      relayNpub: relayKeys.npub,
      relayNsec: relayKeys.nsec,
      operatorCallsign: operatorCallsign,  // X1 callsign from profile
      operatorNpub: profile.npub!,
      type: RelayType.node,
      networkId: network.id,
      networkName: network.name,
      rootNpub: network.rootNpub,
      rootCallsign: network.rootCallsign,
      config: config,
      status: RelayNodeStatus.stopped,
      created: now,
      updated: now,
    );

    _saveRelayConfig();
    await _createRelayDirectories();

    LogService().log('Joined network as node: $nodeName (relay: ${relayKeys.callsign}, operator: $operatorCallsign)');
    _stateController.add(_relayNode);

    return _relayNode!;
  }

  /// Start the relay
  Future<void> start() async {
    if (_relayNode == null) {
      throw Exception('No relay configured');
    }

    if (_relayNode!.isRunning) {
      LogService().log('Relay already running');
      return;
    }

    LogService().log('Starting relay: ${_relayNode!.name}');

    _relayNode = _relayNode!.copyWith(
      status: RelayNodeStatus.starting,
      updated: DateTime.now(),
    );
    _stateController.add(_relayNode);

    try {
      // TODO: Implement actual relay server startup
      // - Start WebSocket server for incoming connections
      // - Start mDNS advertisement
      // - Initialize collection caching
      // - Connect to root (if node)

      await Future.delayed(const Duration(milliseconds: 500)); // Simulate startup

      _startedAt = DateTime.now();
      _relayNode = _relayNode!.copyWith(
        status: RelayNodeStatus.running,
        updated: DateTime.now(),
      );

      // Start stats update timer
      _statsTimer?.cancel();
      _statsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        _updateStats();
      });

      _saveRelayConfig();
      _stateController.add(_relayNode);

      LogService().log('Relay started successfully');
    } catch (e) {
      _relayNode = _relayNode!.copyWith(
        status: RelayNodeStatus.error,
        errorMessage: e.toString(),
        updated: DateTime.now(),
      );
      _stateController.add(_relayNode);
      LogService().log('Failed to start relay: $e');
      rethrow;
    }
  }

  /// Stop the relay
  Future<void> stop() async {
    if (_relayNode == null || !_relayNode!.isRunning) {
      return;
    }

    LogService().log('Stopping relay: ${_relayNode!.name}');

    _relayNode = _relayNode!.copyWith(
      status: RelayNodeStatus.stopping,
      updated: DateTime.now(),
    );
    _stateController.add(_relayNode);

    try {
      // TODO: Implement actual relay server shutdown
      // - Close all connections
      // - Stop WebSocket server
      // - Stop mDNS advertisement

      _statsTimer?.cancel();
      _statsTimer = null;

      await Future.delayed(const Duration(milliseconds: 300)); // Simulate shutdown

      _relayNode = _relayNode!.copyWith(
        status: RelayNodeStatus.stopped,
        updated: DateTime.now(),
      );
      _startedAt = null;

      _saveRelayConfig();
      _stateController.add(_relayNode);

      LogService().log('Relay stopped');
    } catch (e) {
      _relayNode = _relayNode!.copyWith(
        status: RelayNodeStatus.error,
        errorMessage: e.toString(),
        updated: DateTime.now(),
      );
      _stateController.add(_relayNode);
      LogService().log('Error stopping relay: $e');
    }
  }

  /// Update relay configuration
  Future<void> updateConfig(RelayNodeConfig config) async {
    if (_relayNode == null) {
      throw Exception('No relay configured');
    }

    _relayNode = _relayNode!.copyWith(
      config: config,
      updated: DateTime.now(),
    );

    _saveRelayConfig();
    _stateController.add(_relayNode);

    LogService().log('Relay config updated');
  }

  /// Delete relay configuration and leave network
  Future<void> deleteRelay() async {
    if (_relayNode == null) return;

    // Stop if running
    if (_relayNode!.isRunning) {
      await stop();
    }

    LogService().log('Deleting relay: ${_relayNode!.name}');

    // Clean up directories
    await _deleteRelayDirectories();

    _relayNode = null;
    _network = null;

    _saveRelayConfig();
    _stateController.add(null);

    LogService().log('Relay deleted');
  }

  /// Get relay data directory
  Future<Directory> getRelayDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(path.join(appDir.path, 'geogram', 'relay'));
  }

  /// Create relay directories
  Future<void> _createRelayDirectories() async {
    final relayDir = await getRelayDirectory();

    final directories = [
      '',
      'authorities',
      'authorities/admins',
      'authorities/group-admins',
      'authorities/moderators',
      'collections',
      'collections/approved',
      'collections/pending',
      'collections/suspended',
      'collections/banned',
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
      final dirPath = path.join(relayDir.path, dir);
      await Directory(dirPath).create(recursive: true);
    }

    // Create initial config files
    await _createInitialFiles(relayDir);

    LogService().log('Created relay directories at: ${relayDir.path}');
  }

  /// Create initial relay configuration files
  Future<void> _createInitialFiles(Directory relayDir) async {
    if (_relayNode == null || _network == null) return;

    // relay.json
    final relayFile = File(path.join(relayDir.path, 'relay.json'));
    await relayFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_relayNode!.toJson()),
    );

    // network.json
    final networkFile = File(path.join(relayDir.path, 'network.json'));
    await networkFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_network!.toJson()),
    );

    // authorities/root.txt (if root)
    if (_relayNode!.isRoot) {
      final rootFile = File(path.join(relayDir.path, 'authorities', 'root.txt'));
      await rootFile.writeAsString('''
# ROOT: ${_network!.name}

## Relay Identity (X3)
RELAY_CALLSIGN: ${_relayNode!.relayCallsign}
RELAY_NPUB: ${_relayNode!.relayNpub}

## Operator Identity (X1)
OPERATOR_CALLSIGN: ${_relayNode!.operatorCallsign}
OPERATOR_NPUB: ${_relayNode!.operatorNpub}

CREATED: ${_relayNode!.created.toIso8601String()}

Network founder and ultimate authority.

The relay (${_relayNode!.relayCallsign}) is managed by operator ${_relayNode!.operatorCallsign}.
''');
    }
  }

  /// Delete relay directories
  Future<void> _deleteRelayDirectories() async {
    final relayDir = await getRelayDirectory();
    if (await relayDir.exists()) {
      await relayDir.delete(recursive: true);
      LogService().log('Deleted relay directories');
    }
  }

  /// Update relay statistics
  void _updateStats() {
    if (_relayNode == null || !_relayNode!.isRunning) return;

    final uptime = _startedAt != null
        ? DateTime.now().difference(_startedAt!)
        : Duration.zero;

    // TODO: Get actual stats from relay server
    final stats = RelayNodeStats(
      connectedDevices: 0, // TODO: Get from server
      messagesRelayed: 0, // TODO: Get from server
      collectionsServed: 0, // TODO: Get from server
      storageUsedMb: 0, // TODO: Calculate from disk
      lastActivity: DateTime.now(),
      uptime: uptime,
    );

    _relayNode = _relayNode!.copyWith(
      stats: stats,
      updated: DateTime.now(),
    );
    _stateController.add(_relayNode);
  }

  /// Generate a unique ID
  String _generateId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final random = (DateTime.now().microsecond * 1000).toRadixString(16);
    return '$timestamp$random'.substring(0, 16);
  }

  /// Dispose resources
  void dispose() {
    _statsTimer?.cancel();
    _stateController.close();
  }
}
