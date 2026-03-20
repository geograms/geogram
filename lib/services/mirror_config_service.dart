/// Service for managing mirror configuration persistence.
///
/// Handles loading, saving, and streaming mirror config changes.
/// Config is stored per-profile inside `mirror/config.json` via ProfileStorage.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../models/mirror_config.dart';
import 'log_service.dart';
import 'profile_storage.dart';
import 'storage_config.dart';

/// Relative path for mirror config inside a profile's storage.
const _mirrorConfigPath = 'mirror/config.json';

/// Service for managing mirror sync configuration
class MirrorConfigService {
  static final MirrorConfigService _instance = MirrorConfigService._();
  static MirrorConfigService get instance => _instance;

  MirrorConfigService._();

  MirrorConfig? _config;
  ProfileStorage? _storage;
  final _configController = StreamController<MirrorConfig>.broadcast();

  /// Stream of config changes
  Stream<MirrorConfig> get configStream => _configController.stream;

  /// Current config (may be null if not loaded)
  MirrorConfig? get config => _config;

  /// Check if mirror is enabled
  bool get isEnabled => _config?.enabled ?? false;

  /// Set the ProfileStorage instance for the current profile.
  ///
  /// Clears the cached config and immediately loads the new profile's
  /// config so that [isEnabled], [config], and stream listeners all
  /// reflect the correct state right after a profile switch.
  Future<void> setStorage(ProfileStorage? storage) async {
    _storage = storage;
    _config = null; // force reload for new profile
    await loadConfig(); // loads from new storage, emits to stream
    await loadExcludeRules(); // load shared exclude rules
  }

  /// Initialize the service
  Future<void> initialize() async {
    await loadConfig();
    await loadExcludeRules();
  }

  /// Load config from ProfileStorage.
  ///
  /// Falls back to migrating the legacy global `mirror_config.json` when
  /// the per-profile config does not exist yet.
  Future<MirrorConfig> loadConfig() async {
    if (_storage != null) {
      try {
        final json = await _storage!.readJson(_mirrorConfigPath);
        if (json != null) {
          _config = MirrorConfig.fromJson(json);
          _configController.add(_config!);
          return _config!;
        }
      } catch (e) {
        print('Error loading mirror config from storage: $e');
      }

      // Try migrating legacy global config
      try {
        final legacyPath = '${StorageConfig().baseDir}/mirror_config.json';
        final legacyFile = File(legacyPath);
        if (await legacyFile.exists()) {
          final content = await legacyFile.readAsString();
          final legacyJson = jsonDecode(content) as Map<String, dynamic>;
          _config = MirrorConfig.fromJson(legacyJson);
          // Save into per-profile storage
          await _storage!.writeJson(_mirrorConfigPath, _config!.toJson());
          // Remove legacy file so it won't be picked up again
          await legacyFile.delete();
          _configController.add(_config!);
          return _config!;
        }
      } catch (e) {
        print('Error migrating legacy mirror config: $e');
      }
    }

    _config = _createDefaultConfig();
    _configController.add(_config!);
    return _config!;
  }

  /// Create default config with new device ID
  MirrorConfig _createDefaultConfig() {
    final deviceId = const Uuid().v4();
    final deviceName = _getDefaultDeviceName();

    return MirrorConfig(
      enabled: false,
      deviceId: deviceId,
      deviceName: deviceName,
    );
  }

  /// Get default device name based on platform
  String _getDefaultDeviceName() {
    if (Platform.isAndroid) return 'Android Device';
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isLinux) return 'Linux Desktop';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows PC';
    return 'My Device';
  }

  /// Save config to ProfileStorage
  Future<void> saveConfig(MirrorConfig config) async {
    _config = config;

    if (_storage != null) {
      await _storage!.writeJson(_mirrorConfigPath, config.toJson());
    } else {
      LogService().log(
        'MirrorConfigService: WARNING — saveConfig called but _storage is null. '
        'Config NOT persisted to disk (will be lost on restart).',
      );
    }

    _configController.add(config);
  }

  /// Update config and save
  Future<void> updateConfig(MirrorConfig Function(MirrorConfig) updater) async {
    if (_config == null) await loadConfig();
    final updated = updater(_config!);
    await saveConfig(updated);
  }

  /// Enable or disable mirror
  Future<void> setEnabled(bool enabled) async {
    await updateConfig((c) => c.copyWith(enabled: enabled));
  }

  /// Update device name
  Future<void> setDeviceName(String name) async {
    await updateConfig((c) => c.copyWith(deviceName: name));
  }

  /// Update device priority (1=high, 2=medium, 3=low/default)
  Future<void> setPriority(int priority) async {
    await updateConfig((c) => c.copyWith(priority: priority));
  }

  /// Add a new peer
  Future<void> addPeer(MirrorPeer peer) async {
    await updateConfig((c) {
      final peers = List<MirrorPeer>.from(c.peers);
      // Remove existing peer with same ID if any
      peers.removeWhere((p) => p.peerId == peer.peerId);
      peers.add(peer);
      return c.copyWith(peers: peers);
    });
  }

  /// Remove a peer
  Future<void> removePeer(String peerId) async {
    await updateConfig((c) {
      final peers = List<MirrorPeer>.from(c.peers);
      peers.removeWhere((p) => p.peerId == peerId);
      return c.copyWith(peers: peers);
    });
  }

  /// Update a peer
  Future<void> updatePeer(MirrorPeer peer) async {
    await updateConfig((c) {
      final peers = List<MirrorPeer>.from(c.peers);
      final index = peers.indexWhere((p) => p.peerId == peer.peerId);
      if (index >= 0) {
        peers[index] = peer;
      }
      return c.copyWith(peers: peers);
    });
  }

  /// Update app sync config for a peer
  Future<void> updatePeerAppConfig(
    String peerId,
    String appId,
    AppSyncConfig appConfig,
  ) async {
    await updateConfig((c) {
      final peers = List<MirrorPeer>.from(c.peers);
      final index = peers.indexWhere((p) => p.peerId == peerId);
      if (index >= 0) {
        final peer = peers[index];
        final apps = Map<String, AppSyncConfig>.from(peer.apps);
        apps[appId] = appConfig;
        peers[index] = peer.copyWith(apps: apps);
      }
      return c.copyWith(peers: peers);
    });
  }

  /// Update connection preferences
  Future<void> updatePreferences(ConnectionPreferences preferences) async {
    await updateConfig((c) => c.copyWith(preferences: preferences));
  }

  /// Update peer connection state (runtime only, not persisted)
  void updatePeerConnectionState(String peerId, PeerConnectionState state) {
    if (_config == null) return;

    final index = _config!.peers.indexWhere((p) => p.peerId == peerId);
    if (index >= 0) {
      _config!.peers[index].connectionState = state;
      if (state == PeerConnectionState.connected ||
          state == PeerConnectionState.syncing) {
        _config!.peers[index].lastSeenAt = DateTime.now();
      }
      _configController.add(_config!);
    }
  }

  /// Update peer sync state for an app (runtime only)
  void updatePeerAppSyncState(String peerId, String appId, SyncState state) {
    if (_config == null) return;

    final peerIndex = _config!.peers.indexWhere((p) => p.peerId == peerId);
    if (peerIndex >= 0) {
      final peer = _config!.peers[peerIndex];
      if (peer.apps.containsKey(appId)) {
        peer.apps[appId]!.state = state;
        _configController.add(_config!);
      }
    }
  }

  /// Mark peer as synced
  Future<void> markPeerSynced(String peerId) async {
    await updateConfig((c) {
      final peers = List<MirrorPeer>.from(c.peers);
      final index = peers.indexWhere((p) => p.peerId == peerId);
      if (index >= 0) {
        peers[index] = peers[index].copyWith(lastSyncAt: DateTime.now());
      }
      return c.copyWith(peers: peers);
    });
  }

  /// Auto-register or update a peer from a discovered mirror device.
  ///
  /// Accepts plain fields instead of MirrorDevice to avoid circular imports.
  /// Rate-limited: skips if the peer's lastSeenAt is < 5 minutes ago
  /// and no field changes are needed.
  Future<void> ensurePeerFromDiscovery({
    required String installId,
    required String callsign,
    String? nickname,
    String? deviceName,
    String? npub,
    String platform = 'unknown',
    String displayName = '',
    String? directAddress,
  }) async {
    if (_config == null) await loadConfig();

    final existing = _config!.getPeer(installId);
    final now = DateTime.now();
    // Prefer deviceName (device-chosen) over nickname (profile nickname)
    final effectiveName = deviceName ?? nickname;

    if (existing != null) {
      // Rate-limit: skip if recently seen and no changes
      final timeSinceLastSeen = existing.lastSeenAt != null
          ? now.difference(existing.lastSeenAt!).inMinutes
          : 999;
      final nameChanged = effectiveName != null &&
          effectiveName.isNotEmpty &&
          effectiveName != existing.name;
      final platformChanged = platform != existing.platform;
      // Check if we have a new direct address not yet in the peer's addresses
      final addressChanged = directAddress != null &&
          directAddress.isNotEmpty &&
          !existing.addresses.contains(directAddress);

      if (timeSinceLastSeen < 5 && !nameChanged && !platformChanged && !addressChanged) return;

      // Update existing peer — add direct address if new
      final updatedAddresses = addressChanged
          ? [directAddress!, ...existing.addresses.where((a) => !a.startsWith('http://'))]
          : null;
      await updatePeer(existing.copyWith(
        lastSeenAt: now,
        name: nameChanged ? effectiveName : null,
        platform: platformChanged ? platform : null,
        addresses: updatedAddresses,
      ));
    } else {
      // Create new peer with defaults (manual mode, no folders enabled)
      await addPeer(MirrorPeer(
        peerId: installId,
        name: effectiveName ?? displayName,
        callsign: callsign,
        npub: npub ?? '',
        platform: platform,
        lastSeenAt: now,
        autoSyncMode: AutoSyncMode.manual,
        addresses: directAddress != null ? [directAddress] : [],
      ));
    }
  }

  /// Get list of enabled apps for a peer
  List<String> getEnabledAppsForPeer(String peerId) {
    final peer = _config?.getPeer(peerId);
    if (peer == null) return [];

    return peer.apps.entries
        .where((e) => e.value.enabled)
        .map((e) => e.key)
        .toList();
  }

  // ========== Exclude Rules (synced between devices) ==========

  static const _excludeRulesPath = 'shared/sync_exclude_rules.json';

  /// Load exclude rules from the shared syncable file.
  /// Merges into the in-memory config if the shared file is newer.
  Future<void> loadExcludeRules() async {
    if (_storage == null || _config == null) return;
    try {
      final json = await _storage!.readJson(_excludeRulesPath);
      if (json == null) return;

      final rules = (json['rules'] as List<dynamic>?)
              ?.map((e) => SyncExcludeRule.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      _config = _config!.copyWith(excludeRules: rules);
      _configController.add(_config!);
    } catch (e) {
      LogService().log('Error loading exclude rules: $e');
    }
  }

  /// Save exclude rules to the shared syncable file.
  /// This file syncs between mirrors via the `shared` folder.
  Future<void> saveExcludeRules(List<SyncExcludeRule> rules) async {
    if (_config == null) await loadConfig();
    _config = _config!.copyWith(excludeRules: rules);
    await saveConfig(_config!);

    if (_storage != null) {
      await _storage!.writeJson(_excludeRulesPath, {
        'rules': rules.map((r) => r.toJson()).toList(),
        'lastModified': DateTime.now().toUtc().toIso8601String(),
      });
    }
  }

  /// Dispose resources
  void dispose() {
    _configController.close();
  }
}
