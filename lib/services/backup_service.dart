/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Backup Service Implementation
 * Manages backup operations for both client (backing up to remote) and provider (storing backups for others)
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../connection/connection_manager.dart';
import '../connection/transports/lan_transport.dart';
import '../models/backup_models.dart';
import '../util/backup_encryption.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import '../util/event_bus.dart';
import 'app_args.dart';
import 'devices_service.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'station_discovery_service.dart';
import 'storage_config.dart';
import 'websocket_service.dart';

/// Backup service singleton managing both client and provider operations
class BackupService {
  static final BackupService _instance = BackupService._internal();
  factory BackupService() => _instance;
  BackupService._internal();

  // === State ===
  bool _initialized = false;
  String? _basePath;
  String get _backupsDirPath => p.join(_basePath ?? '', 'backups');
  String get _configDirPath => p.join(_backupsDirPath, 'config');
  String get _providersConfigDirPath => p.join(_configDirPath, 'providers');
  String get _legacyConfigDirPath => p.join(_basePath ?? '', 'backup-config');

  // Provider state
  BackupProviderSettings? _providerSettings;
  final Map<String, BackupClientRelationship> _clients = {};

  // Client state
  final Map<String, BackupProviderRelationship> _providers = {};
  BackupStatus _backupStatus = BackupStatus.idle();
  BackupStatus _restoreStatus = BackupStatus.idle();

  // Discovery state
  final Map<String, DiscoveryStatus> _activeDiscoveries = {};
  final Map<String, String> _resolvedUrls = {};

  // Pending invitations (client waiting for provider response)
  final Map<String, Completer<BackupProviderRelationship>> _pendingInvites = {};

  // Station availability announcements
  EventSubscription<ConnectionStateChangedEvent>? _stationConnectionSubscription;
  Timer? _providerAnnounceTimer;
  static const Duration _providerAnnounceInterval = Duration(seconds: 60);

  // === Stream controllers ===
  final _statusController = StreamController<BackupStatus>.broadcast();
  final _providersController = StreamController<List<BackupProviderRelationship>>.broadcast();
  final _clientsController = StreamController<List<BackupClientRelationship>>.broadcast();

  /// Stream of backup/restore status updates
  Stream<BackupStatus> get statusStream => _statusController.stream;

  /// Stream of provider relationship changes (for client)
  Stream<List<BackupProviderRelationship>> get providersStream => _providersController.stream;

  /// Stream of client relationship changes (for provider)
  Stream<List<BackupClientRelationship>> get clientsStream => _clientsController.stream;

  // === Initialization ===

  /// Initialize the backup service
  Future<void> initialize() async {
    if (_initialized) return;
    if (kIsWeb) {
      _log('BackupService: Web platform not supported');
      return;
    }

    try {
      final storageConfig = StorageConfig();
      if (!storageConfig.isInitialized) {
        await storageConfig.init();
      }

      _basePath = storageConfig.baseDir;

      // Ensure directories exist
      await _ensureDirectories();

      // Load settings
      await _loadProviderSettings();
      await _loadClients();
      await _loadProviders();
      _setupStationConnectionListener();

      if (_providerSettings?.enabled == true && WebSocketService().isConnected) {
        await _announceProviderAvailability();
        _startProviderAnnounceTimer();
      }

      _initialized = true;
      _log('BackupService initialized');
    } catch (e) {
      _log('BackupService initialization error: $e');
    }
  }

  /// Ensure required directories exist
  Future<void> _ensureDirectories() async {
    final backupsDir = Directory(_backupsDirPath);
    if (!await backupsDir.exists()) {
      await backupsDir.create(recursive: true);
    }

    final configDir = Directory(_configDirPath);
    if (!await configDir.exists()) {
      final legacyDir = Directory(_legacyConfigDirPath);
      if (await legacyDir.exists()) {
        try {
          await legacyDir.rename(configDir.path);
        } catch (_) {
          await configDir.create(recursive: true);
          await for (final entity in legacyDir.list()) {
            final newPath = p.join(configDir.path, p.basename(entity.path));
            try {
              await entity.rename(newPath);
            } catch (_) {}
          }
        }
      } else {
        await configDir.create(recursive: true);
      }
    }

    final providersDir = Directory(_providersConfigDirPath);
    if (!await providersDir.exists()) {
      await providersDir.create(recursive: true);
    }
  }

  // ============================================================
  // PROVIDER METHODS
  // ============================================================

  /// Get provider settings
  BackupProviderSettings? get providerSettings => _providerSettings;

  /// Enable provider mode with default settings
  Future<void> enableProviderMode({
    required int maxTotalStorageBytes,
    required int defaultMaxClientStorageBytes,
    required int defaultMaxSnapshots,
  }) async {
    final settings = BackupProviderSettings(
      enabled: true,
      maxTotalStorageBytes: maxTotalStorageBytes,
      defaultMaxClientStorageBytes: defaultMaxClientStorageBytes,
      defaultMaxSnapshots: defaultMaxSnapshots,
    );
    await saveProviderSettings(settings);
    _log('Provider mode enabled');
  }

  /// Disable provider mode
  Future<void> disableProviderMode() async {
    if (_providerSettings != null) {
      _providerSettings!.enabled = false;
      await saveProviderSettings(_providerSettings!);
      _log('Provider mode disabled');
    }
  }

  /// Update provider settings with named parameters
  Future<void> updateProviderSettings({
    int? maxTotalStorageBytes,
    int? defaultMaxClientStorageBytes,
    int? defaultMaxSnapshots,
    bool? autoAcceptFromContacts,
  }) async {
    final settings = _providerSettings ?? BackupProviderSettings();
    if (maxTotalStorageBytes != null) {
      settings.maxTotalStorageBytes = maxTotalStorageBytes;
    }
    if (defaultMaxClientStorageBytes != null) {
      settings.defaultMaxClientStorageBytes = defaultMaxClientStorageBytes;
    }
    if (defaultMaxSnapshots != null) {
      settings.defaultMaxSnapshots = defaultMaxSnapshots;
    }
    if (autoAcceptFromContacts != null) {
      settings.autoAcceptFromContacts = autoAcceptFromContacts;
    }
    await saveProviderSettings(settings);
    _log('Provider settings updated');
  }

  /// Load provider settings from disk
  Future<void> _loadProviderSettings() async {
    final settingsFile = File(p.join(_basePath!, 'backups', 'settings.json'));
    if (await settingsFile.exists()) {
      try {
        final json = jsonDecode(await settingsFile.readAsString());
        _providerSettings = BackupProviderSettings.fromJson(json);
      } catch (e) {
        _log('Error loading provider settings: $e');
        _providerSettings = BackupProviderSettings();
      }
    } else {
      _providerSettings = BackupProviderSettings();
    }
  }

  /// Save provider settings to disk
  Future<void> saveProviderSettings(BackupProviderSettings settings) async {
    settings.updatedAt = DateTime.now();
    _providerSettings = settings;
    final settingsFile = File(p.join(_basePath!, 'backups', 'settings.json'));
    await settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );

    if (WebSocketService().isConnected) {
      await _announceProviderAvailability(force: true);
      if (settings.enabled) {
        _startProviderAnnounceTimer();
      } else {
        _stopProviderAnnounceTimer();
      }
    } else {
      _stopProviderAnnounceTimer();
    }
  }

  /// Load all client relationships from disk
  Future<void> _loadClients() async {
    final backupsDir = Directory(p.join(_basePath!, 'backups'));
    if (!await backupsDir.exists()) return;

    await for (final entity in backupsDir.list()) {
      if (entity is Directory) {
        final configFile = File(p.join(entity.path, 'config.json'));
        if (await configFile.exists()) {
          try {
            final json = jsonDecode(await configFile.readAsString());
            final relationship = BackupClientRelationship.fromJson(json);
            _clients[relationship.clientCallsign] = relationship;
          } catch (e) {
            _log('Error loading client config from ${entity.path}: $e');
          }
        }
      }
    }
  }

  /// Get all backup clients
  List<BackupClientRelationship> getClients() {
    return _clients.values.toList();
  }

  /// Get a specific client by callsign
  BackupClientRelationship? getClient(String callsign) {
    return _clients[callsign.toUpperCase()];
  }

  /// Accept a backup invitation from a client
  Future<void> acceptInvite(String clientNpub, String clientCallsign, int maxStorageBytes, int maxSnapshots) async {
    final relationship = BackupClientRelationship(
      clientNpub: clientNpub,
      clientCallsign: clientCallsign.toUpperCase(),
      maxStorageBytes: maxStorageBytes,
      maxSnapshots: maxSnapshots,
      status: BackupRelationshipStatus.active,
    );

    await _saveClientRelationship(relationship);
    _clients[clientCallsign.toUpperCase()] = relationship;
    _clientsController.add(getClients());

    // Send response to client
    _sendInviteResponse(clientNpub, clientCallsign, true, maxStorageBytes, maxSnapshots);
  }

  /// Decline a backup invitation from a client
  Future<void> declineInvite(String clientNpub, String clientCallsign) async {
    _sendInviteResponse(clientNpub, clientCallsign, false, 0, 0);
  }

  /// Remove a client (optionally delete their data)
  Future<void> removeClient(String callsign, {bool deleteData = false}) async {
    final normalized = callsign.toUpperCase();
    final client = _clients[normalized];
    if (client == null) return;

    if (deleteData) {
      final clientDir = Directory(p.join(_basePath!, 'backups', normalized));
      if (await clientDir.exists()) {
        await clientDir.delete(recursive: true);
      }
    } else {
      // Just mark as terminated
      final updated = client.copyWith(status: BackupRelationshipStatus.terminated);
      await _saveClientRelationship(updated);
      _clients[normalized] = updated;
    }

    _clientsController.add(getClients());
  }

  /// Save client relationship to disk
  Future<void> _saveClientRelationship(BackupClientRelationship relationship) async {
    final clientDir = Directory(p.join(_basePath!, 'backups', relationship.clientCallsign));
    if (!await clientDir.exists()) {
      await clientDir.create(recursive: true);
    }

    final configFile = File(p.join(clientDir.path, 'config.json'));
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(relationship.toJson()),
    );
  }

  /// Get snapshots for a client
  Future<List<BackupSnapshot>> getSnapshots(String clientCallsign) async {
    final snapshots = <BackupSnapshot>[];
    final clientDir = Directory(p.join(_basePath!, 'backups', clientCallsign.toUpperCase()));

    if (!await clientDir.exists()) return snapshots;

    await for (final entity in clientDir.list()) {
      if (entity is Directory) {
        final dirName = p.basename(entity.path);
        // Check if it's a date folder (YYYY-MM-DD)
        if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dirName)) {
          final statusFile = File(p.join(entity.path, 'status.json'));
          if (await statusFile.exists()) {
            try {
              final json = jsonDecode(await statusFile.readAsString());
              snapshots.add(BackupSnapshot.fromJson(json));
            } catch (e) {
              _log('Error loading snapshot status from ${entity.path}: $e');
            }
          }
        }
      }
    }

    // Sort by date descending
    snapshots.sort((a, b) => b.snapshotId.compareTo(a.snapshotId));
    return snapshots;
  }

  /// Get a specific snapshot for a client
  Future<BackupSnapshot?> getSnapshot(String clientCallsign, String snapshotId) async {
    final snapshots = await getSnapshots(clientCallsign);
    try {
      return snapshots.firstWhere((s) => s.snapshotId == snapshotId);
    } catch (_) {
      return null;
    }
  }

  /// Get manifest for a snapshot
  Future<Uint8List?> getManifest(String clientCallsign, String snapshotId) async {
    final manifestFile = File(p.join(
      _basePath!,
      'backups',
      clientCallsign.toUpperCase(),
      snapshotId,
      'manifest.json',
    ));

    if (await manifestFile.exists()) {
      return await manifestFile.readAsBytes();
    }
    return null;
  }

  /// Get encrypted file from a snapshot
  Future<Uint8List?> getEncryptedFile(String clientCallsign, String snapshotId, String fileName) async {
    final archiveFile = await _getSnapshotArchiveFile(clientCallsign, snapshotId, createIfMissing: false);
    if (archiveFile != null && await archiveFile.exists()) {
      try {
        final archiveBytes = await archiveFile.readAsBytes();
        final archive = ZipDecoder().decodeBytes(archiveBytes, verify: false);
        final entry = archive.files.firstWhere(
          (f) => f.name == fileName,
          orElse: () => ArchiveFile('missing', 0, null),
        );
        if (entry.size != 0 && entry.content != null) {
          final content = entry.content;
          if (content is Uint8List) return content;
          if (content is List<int>) return Uint8List.fromList(content);
        }
      } catch (e) {
        _log('Error reading $fileName from archive: $e');
      }
    }

    final filePath = p.join(
      _basePath!,
      'backups',
      clientCallsign.toUpperCase(),
      snapshotId,
      'files',
      fileName,
    );
    final file = File(filePath);

    if (await file.exists()) {
      return await file.readAsBytes();
    }
    return null;
  }

  /// Save encrypted file to a snapshot
  Future<void> saveEncryptedFile(
    String clientCallsign,
    String snapshotId,
    String fileName,
    Uint8List data,
  ) async {
    final filesDir = Directory(p.join(
      _basePath!,
      'backups',
      clientCallsign.toUpperCase(),
      snapshotId,
      'files',
    ));

    if (!await filesDir.exists()) {
      await filesDir.create(recursive: true);
    }

    final file = File(p.join(filesDir.path, fileName));
    await file.writeAsBytes(data);

    // Update client storage stats
    final client = _clients[clientCallsign.toUpperCase()];
    if (client != null) {
      final newSize = client.currentStorageBytes + data.length;
      final updated = client.copyWith(currentStorageBytes: newSize);
      _clients[clientCallsign.toUpperCase()] = updated;
      await _saveClientRelationship(updated);
    }
  }

  /// Save manifest for a snapshot
  Future<void> saveManifest(String clientCallsign, String snapshotId, Uint8List data) async {
    final snapshotDir = Directory(p.join(
      _basePath!,
      'backups',
      clientCallsign.toUpperCase(),
      snapshotId,
    ));

    if (!await snapshotDir.exists()) {
      await snapshotDir.create(recursive: true);
    }

    final file = File(p.join(snapshotDir.path, 'manifest.json'));
    await file.writeAsBytes(data);
  }

  /// Update snapshot status
  Future<void> updateSnapshotStatus(String clientCallsign, BackupSnapshot snapshot) async {
    final snapshotDir = Directory(p.join(
      _basePath!,
      'backups',
      clientCallsign.toUpperCase(),
      snapshot.snapshotId,
    ));

    if (!await snapshotDir.exists()) {
      await snapshotDir.create(recursive: true);
    }

    // Preserve existing note if caller didn't provide one
    final statusFile = File(p.join(snapshotDir.path, 'status.json'));
    if (snapshot.note == null && await statusFile.exists()) {
      try {
        final existingJson = jsonDecode(await statusFile.readAsString()) as Map<String, dynamic>;
        snapshot = snapshot.copyWith(note: existingJson['note'] as String?);
      } catch (_) {
        // Ignore parse errors; continue with provided snapshot
      }
    }

    await statusFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(snapshot.toJson()),
    );

    // Update client relationship stats
    final client = _clients[clientCallsign.toUpperCase()];
    if (client != null) {
      final snapshots = await getSnapshots(clientCallsign);
      final updated = client.copyWith(
        snapshotCount: snapshots.length,
        lastBackupAt: snapshot.completedAt ?? snapshot.startedAt,
        lastBackupStatus: snapshot.status,
      );
      _clients[clientCallsign.toUpperCase()] = updated;
      await _saveClientRelationship(updated);
    }
  }

  /// Update snapshot note for a client (provider-side)
  Future<void> setSnapshotNote(String clientCallsign, String snapshotId, String note) async {
    final existing = await getSnapshot(clientCallsign, snapshotId);
    if (existing == null) {
      _log('Snapshot note update skipped: snapshot not found for $clientCallsign/$snapshotId');
      return;
    }
    final updated = existing.copyWith(note: note);
    await updateSnapshotStatus(clientCallsign, updated);
    _fireBackupEvent(
      type: BackupEventType.snapshotNoteUpdated,
      role: 'provider',
      counterpartCallsign: clientCallsign,
      snapshotId: snapshotId,
      message: note,
    );
  }

  /// Check if client has quota available
  bool hasQuotaAvailable(String clientCallsign, int additionalBytes) {
    final client = _clients[clientCallsign.toUpperCase()];
    if (client == null) return false;
    return (client.currentStorageBytes + additionalBytes) <= client.maxStorageBytes;
  }

  // ============================================================
  // CLIENT METHODS
  // ============================================================

  /// Load provider relationships from disk
  Future<void> _loadProviders() async {
    final providersDir = Directory(_providersConfigDirPath);
    if (!await providersDir.exists()) return;

    await for (final entity in providersDir.list()) {
      if (entity is Directory) {
        final configFile = File(p.join(entity.path, 'config.json'));
        if (await configFile.exists()) {
          try {
            final json = jsonDecode(await configFile.readAsString());
            final relationship = BackupProviderRelationship.fromJson(json);
            _providers[relationship.providerCallsign] = relationship;
          } catch (e) {
            _log('Error loading provider config from ${entity.path}: $e');
          }
        }
      }
    }
  }

  /// Get all backup providers (as client)
  List<BackupProviderRelationship> getProviders() {
    return _providers.values.toList();
  }

  /// Get a specific provider by callsign
  BackupProviderRelationship? getProvider(String callsign) {
    return _providers[callsign.toUpperCase()];
  }

  /// Fetch snapshot list from a provider (client-side)
  Future<List<BackupSnapshot>> fetchProviderSnapshots(String providerCallsign) async {
    try {
      final profile = ProfileService().getProfile();
      final myCallsign = profile.callsign;
      if (myCallsign.isEmpty) {
        _log('Fetch snapshots error: identity not available');
        return [];
      }

      final connectionManager = ConnectionManager();
      if (!connectionManager.isInitialized) {
        _log('Fetch snapshots error: ConnectionManager not initialized');
        return [];
      }

      final authHeaders = _buildBackupAuthHeaders(
        'snapshot_list',
        targetCallsign: providerCallsign,
      );
      if (authHeaders == null) {
        _log('Fetch snapshots error: failed to sign auth header');
        return [];
      }

      final requestPath = '/api/backup/clients/$myCallsign/snapshots';
      final requestHeaders = {
        'Accept': 'application/json',
        ...authHeaders,
      };

      _syncDeviceForTransfer(providerCallsign);
      final result = await connectionManager.apiRequest(
        callsign: providerCallsign,
        method: 'GET',
        path: requestPath,
        headers: requestHeaders,
        excludeTransports: _backupApiExcludeTransports(),
      );

      Map<String, dynamic>? payload;
      if (result.success && result.responseData != null) {
        payload = _decodeJsonPayload(result.responseData);
      }
      payload ??= await _httpGetJson(providerCallsign, requestPath, requestHeaders);
      if (payload == null) {
        return [];
      }

      final rawSnapshots = payload['snapshots'];
      final totalSnapshotBytes = payload['total_snapshot_bytes'];
      final maxStorageBytes = payload['max_storage_bytes'];
      final currentStorageBytes = payload['current_storage_bytes'];
      final maxSnapshots = payload['max_snapshots'];

      // Update provider quota info if available
      final provider = _providers[providerCallsign.toUpperCase()];
      if (provider != null &&
          (maxStorageBytes != null || currentStorageBytes != null || maxSnapshots != null)) {
        final updated = provider.copyWith(
          maxStorageBytes: maxStorageBytes is int ? maxStorageBytes : provider.maxStorageBytes,
          currentStorageBytes: currentStorageBytes is int ? currentStorageBytes : provider.currentStorageBytes,
          maxSnapshots: maxSnapshots is int ? maxSnapshots : provider.maxSnapshots,
        );
        _providers[providerCallsign.toUpperCase()] = updated;
        _providersController.add(getProviders());
      }

      if (rawSnapshots is! List) {
        return [];
      }

      final snapshots = <BackupSnapshot>[];
      for (final entry in rawSnapshots) {
        if (entry is Map<String, dynamic>) {
          snapshots.add(BackupSnapshot.fromJson(entry));
        } else if (entry is Map) {
          snapshots.add(BackupSnapshot.fromJson(Map<String, dynamic>.from(entry)));
        }
      }

      snapshots.sort((a, b) => b.snapshotId.compareTo(a.snapshotId));
      return snapshots;
    } catch (e) {
      _log('Fetch snapshots error: $e');
      return [];
    }
  }

  /// Update snapshot note on provider (client-side)
  Future<bool> updateSnapshotNote(String providerCallsign, String snapshotId, String note) async {
    try {
      final profile = ProfileService().getProfile();
      final myCallsign = profile.callsign;
      if (myCallsign.isEmpty) {
        _log('Update snapshot note error: identity not available');
        return false;
      }

      final authHeaders = _buildBackupAuthHeaders(
        'snapshot_note',
        targetCallsign: providerCallsign,
        snapshotId: snapshotId,
      );
      if (authHeaders == null) {
        _log('Update snapshot note error: failed to sign auth header');
        return false;
      }

      final requestPath = '/api/backup/clients/$myCallsign/snapshots/$snapshotId/note';
      final requestHeaders = {
        'Accept': 'application/json',
        ...authHeaders,
      };

      final connectionManager = ConnectionManager();
      bool success = false;
      if (connectionManager.isInitialized) {
        _syncDeviceForTransfer(providerCallsign);
        final result = await connectionManager.apiRequest(
          callsign: providerCallsign,
          method: 'PUT',
          path: requestPath,
          headers: {
            ...requestHeaders,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'note': note}),
          excludeTransports: _backupApiExcludeTransports(),
        );
        if (result.success) {
          success = true;
        }
      }

      if (!success) {
        success = await _httpPutJson(providerCallsign, requestPath, requestHeaders, {'note': note});
      }

      if (success) {
        _fireBackupEvent(
          type: BackupEventType.snapshotNoteUpdated,
          role: 'client',
          counterpartCallsign: providerCallsign,
          snapshotId: snapshotId,
          message: note,
        );
      }
      return success;
    } catch (e) {
      _log('Update snapshot note error: $e');
      return false;
    }
  }

  /// Send backup invitation to a provider
  Future<BackupProviderRelationship?> sendInvite(String providerCallsign, int intervalDays) async {
    final profile = ProfileService().getProfile();
    final myNpub = profile.npub;
    final myCallsign = profile.callsign;

    if (myNpub.isEmpty || myCallsign.isEmpty) {
      _log('Cannot send invite: identity not available');
      return null;
    }

    // Create pending relationship
    final relationship = BackupProviderRelationship(
      providerNpub: '', // Will be filled when provider responds
      providerCallsign: providerCallsign.toUpperCase(),
      backupIntervalDays: intervalDays,
      status: BackupRelationshipStatus.pending,
    );

    // Save locally
    await _saveProviderRelationship(relationship);
    _providers[providerCallsign.toUpperCase()] = relationship;
    _providersController.add(getProviders());

    // Create signed invite event
    final event = _createInviteEvent(providerCallsign, intervalDays);
    if (event == null) {
      _log('Cannot send invite: failed to sign event');
      return null;
    }

    final sent = await _sendBackupMessage(
      providerCallsign,
      {
        'type': 'backup_invite',
        'event': event.toJson(),
      },
    );

    if (!sent) {
      _log('Backup invite failed: no route to $providerCallsign');
      return null;
    }

    // Wait for response (with timeout)
    final completer = Completer<BackupProviderRelationship>();
    _pendingInvites[providerCallsign.toUpperCase()] = completer;

    try {
      return await completer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          _pendingInvites.remove(providerCallsign.toUpperCase());
          throw TimeoutException('Invite timed out');
        },
      );
    } catch (e) {
      _log('Invite failed: $e');
      return null;
    }
  }

  /// Save provider relationship to disk
  Future<void> _saveProviderRelationship(BackupProviderRelationship relationship) async {
    final providerDir = Directory(p.join(
      _configDirPath,
      'providers',
      relationship.providerCallsign,
    ));

    if (!await providerDir.exists()) {
      await providerDir.create(recursive: true);
    }

    final configFile = File(p.join(providerDir.path, 'config.json'));
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(relationship.toJson()),
    );
  }

  /// Remove a provider relationship
  Future<void> removeProvider(String providerCallsign) async {
    final normalized = providerCallsign.toUpperCase();
    final provider = _providers[normalized];
    if (provider == null) return;

    // Mark as terminated
    final updated = provider.copyWith(status: BackupRelationshipStatus.terminated);
    await _saveProviderRelationship(updated);
    _providers[normalized] = updated;
    _providersController.add(getProviders());

    // Notify provider
    await _sendBackupMessage(
      providerCallsign,
      {
        'type': 'backup_status_change',
        'status': 'terminated',
      },
    );
  }

  /// Update a provider relationship
  Future<void> updateProvider(BackupProviderRelationship provider) async {
    final normalized = provider.providerCallsign.toUpperCase();
    _providers[normalized] = provider;
    await _saveProviderRelationship(provider);
    _providersController.add(getProviders());
  }

  /// Get current backup status
  BackupStatus get backupStatus => _backupStatus;

  /// Get current restore status
  BackupStatus get restoreStatus => _restoreStatus;

  /// Start a backup to a provider
  Future<BackupStatus> startBackup(String providerCallsign) async {
    if (_backupStatus.isInProgress) {
      return _backupStatus.copyWith(error: 'Backup already in progress');
    }

    final provider = _providers[providerCallsign.toUpperCase()];
    if (provider == null || provider.status != BackupRelationshipStatus.active) {
      return BackupStatus(status: 'failed', error: 'Provider not active');
    }

    final snapshotId = _generateSnapshotId();
    _backupStatus = BackupStatus(
      providerCallsign: providerCallsign,
      snapshotId: snapshotId,
      status: 'in_progress',
      startedAt: DateTime.now(),
    );
    _statusController.add(_backupStatus);
    _fireBackupEvent(
      type: BackupEventType.backupStarted,
      role: 'client',
      counterpartCallsign: providerCallsign,
      snapshotId: snapshotId,
    );

    // Run backup in background
    _runBackup(providerCallsign, snapshotId);

    return _backupStatus;
  }

  /// Run the backup process
  Future<void> _runBackup(String providerCallsign, String snapshotId) async {
    try {
      final profile = ProfileService().getProfile();
      final myNsec = profile.nsec;
      final myNpub = profile.npub;
      final myCallsign = profile.callsign;

      if (myNsec.isEmpty || myNpub.isEmpty || myCallsign.isEmpty) {
        throw Exception('Identity not available');
      }

      await _sendBackupMessage(
        providerCallsign,
        {
          'type': 'backup_start',
          'snapshot_id': snapshotId,
        },
      );

      // Get list of files to backup (entire working folder)
      final workingDir = Directory(_basePath!);
      final files = await _enumerateFilesForBackup(workingDir);

      _backupStatus = _backupStatus.copyWith(
        filesTotal: files.length,
        bytesTotal: files.fold<int>(0, (sum, f) => sum + f.lengthSync()),
      );
      _statusController.add(_backupStatus);

      // Create manifest
      final manifest = BackupManifest(
        snapshotId: snapshotId,
        clientNpub: myNpub,
        clientCallsign: myCallsign,
        startedAt: DateTime.now(),
      );

      // Process each file
      int filesTransferred = 0;
      int bytesTransferred = 0;

      for (final file in files) {
        final relativePath = p.relative(file.path, from: _basePath!);

        // Skip backup-related directories
        if (relativePath.startsWith('backups')) {
          continue;
        }

        final content = await file.readAsBytes();
        final sha1Hash = sha1.convert(content).toString();

        // Encrypt file
        final encrypted = BackupEncryption.encryptFile(Uint8List.fromList(content), myNpub);
        final encryptedName = _generateEncryptedFileName();

        // Upload to provider
        final uploaded = await _uploadEncryptedFile(
          providerCallsign,
          snapshotId,
          encryptedName,
          encrypted,
        );

        if (!uploaded) {
          throw Exception('Failed to upload file: $relativePath');
        }

        // Add to manifest
        manifest.files.add(BackupFileEntry(
          path: relativePath,
          sha1: sha1Hash,
          size: content.length,
          encryptedSize: encrypted.length,
          encryptedName: encryptedName,
          modifiedAt: await file.lastModified(),
        ));

        filesTransferred++;
        bytesTransferred += content.length;

        _backupStatus = _backupStatus.copyWith(
          filesTransferred: filesTransferred,
          bytesTransferred: bytesTransferred,
          progressPercent: (filesTransferred * 100 ~/ files.length).clamp(0, 100),
        );
        _statusController.add(_backupStatus);
      }

      // Finalize manifest
      manifest.totalFiles = manifest.files.length;
      manifest.totalBytes = manifest.files.fold(0, (sum, f) => sum + f.size);
      manifest.completedAt = DateTime.now();

      // Encrypt and upload manifest
      final manifestJson = const JsonEncoder.withIndent('  ').convert(manifest.toJson());
      final encryptedManifest = BackupEncryption.encryptManifest(manifestJson, myNsec);

      await _uploadManifest(providerCallsign, snapshotId, encryptedManifest);

      // Mark complete
      _backupStatus = _backupStatus.copyWith(
        status: 'complete',
        progressPercent: 100,
      );
      _statusController.add(_backupStatus);

      // Update provider relationship
      final provider = _providers[providerCallsign.toUpperCase()];
      if (provider != null) {
        final updated = provider.copyWith(
          lastSuccessfulBackup: DateTime.now(),
          nextScheduledBackup: DateTime.now().add(Duration(days: provider.backupIntervalDays)),
        );
        await _saveProviderRelationship(updated);
        _providers[providerCallsign.toUpperCase()] = updated;
        _providersController.add(getProviders());
      }

      // Notify provider
      await _sendBackupMessage(
        providerCallsign,
        {
          'type': 'backup_complete',
          'snapshot_id': snapshotId,
          'total_files': manifest.totalFiles,
          'total_bytes': manifest.totalBytes,
        },
      );

      _fireBackupEvent(
        type: BackupEventType.backupCompleted,
        role: 'client',
        counterpartCallsign: providerCallsign,
        snapshotId: snapshotId,
        totalFiles: manifest.totalFiles,
        totalBytes: manifest.totalBytes,
      );
      _log('Backup completed: $snapshotId, ${manifest.totalFiles} files, ${manifest.totalBytes} bytes');
    } catch (e) {
      _backupStatus = _backupStatus.copyWith(
        status: 'failed',
        error: e.toString(),
      );
      _statusController.add(_backupStatus);
      _log('Backup failed: $e');
      _fireBackupEvent(
        type: BackupEventType.backupFailed,
        role: 'client',
        counterpartCallsign: providerCallsign,
        snapshotId: snapshotId,
        message: e.toString(),
      );
    }
  }

  /// Enumerate files for backup (excluding certain directories)
  Future<List<File>> _enumerateFilesForBackup(Directory dir) async {
    final files = <File>[];
    final excludeDirs = {'backups', 'updates', '.dart_tool', 'build'};

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final relativePath = p.relative(entity.path, from: dir.path);
        final parts = p.split(relativePath);

        // Skip excluded directories
        if (parts.any((part) => excludeDirs.contains(part))) {
          continue;
        }

        files.add(entity);
      }
    }

    return files;
  }

  /// Start restore from a provider
  Future<void> startRestore(String providerCallsign, String snapshotId) async {
    if (_restoreStatus.isInProgress) {
      return;
    }

    final provider = _providers[providerCallsign.toUpperCase()];
    if (provider == null) {
      _restoreStatus = BackupStatus(status: 'failed', error: 'Provider not found');
      _statusController.add(_restoreStatus);
      return;
    }

    _restoreStatus = BackupStatus(
      providerCallsign: providerCallsign,
      snapshotId: snapshotId,
      status: 'in_progress',
      startedAt: DateTime.now(),
    );
    _statusController.add(_restoreStatus);
    _fireBackupEvent(
      type: BackupEventType.restoreStarted,
      role: 'client',
      counterpartCallsign: providerCallsign,
      snapshotId: snapshotId,
    );

    // Run restore in background
    _runRestore(providerCallsign, snapshotId);
  }

  /// Run the restore process
  Future<void> _runRestore(String providerCallsign, String snapshotId) async {
    try {
      final profile = ProfileService().getProfile();
      final myNsec = profile.nsec;

      if (myNsec.isEmpty) {
        throw Exception('Identity not available');
      }

      try {
        await DevicesService().refreshAllDevices(force: true);
      } catch (e) {
        _log('Restore: Device refresh failed: $e');
      }

      final providerBaseUrl = await _resolveDeviceUrl(providerCallsign);

      // Download encrypted manifest
      final encryptedManifest = await _downloadManifest(
        providerCallsign,
        snapshotId,
        baseUrlOverride: providerBaseUrl,
      );
      if (encryptedManifest == null) {
        throw Exception('Failed to download manifest');
      }

      // Decrypt manifest
      final manifestJson = BackupEncryption.decryptManifest(encryptedManifest, myNsec);
      final manifest = BackupManifest.fromJson(jsonDecode(manifestJson));

      _restoreStatus = _restoreStatus.copyWith(
        filesTotal: manifest.totalFiles,
        bytesTotal: manifest.totalBytes,
      );
      _statusController.add(_restoreStatus);

      int filesTransferred = 0;
      int bytesTransferred = 0;

      // Restore each file
      for (final entry in manifest.files) {
        // Download encrypted file
        final encrypted = await _downloadEncryptedFile(
          providerCallsign,
          snapshotId,
          entry.encryptedName,
          baseUrlOverride: providerBaseUrl,
        );

        if (encrypted == null) {
          throw Exception('Failed to download file: ${entry.path}');
        }

        // Decrypt file
        final decrypted = BackupEncryption.decryptFile(encrypted, myNsec);

        // Verify SHA1
        final actualSha1 = sha1.convert(decrypted).toString();
        if (actualSha1 != entry.sha1) {
          throw Exception('SHA1 mismatch for file: ${entry.path}');
        }

        // Write to disk
        final targetPath = p.join(_basePath!, entry.path);
        final targetDir = Directory(p.dirname(targetPath));
        if (!await targetDir.exists()) {
          await targetDir.create(recursive: true);
        }

        final file = File(targetPath);
        await file.writeAsBytes(decrypted);

        filesTransferred++;
        bytesTransferred += decrypted.length;

        _restoreStatus = _restoreStatus.copyWith(
          filesTransferred: filesTransferred,
          bytesTransferred: bytesTransferred,
          progressPercent: (filesTransferred * 100 ~/ manifest.totalFiles).clamp(0, 100),
        );
        _statusController.add(_restoreStatus);
      }

      // Mark complete
      _restoreStatus = _restoreStatus.copyWith(
        status: 'complete',
        progressPercent: 100,
      );
      _statusController.add(_restoreStatus);

      _fireBackupEvent(
        type: BackupEventType.restoreCompleted,
        role: 'client',
        counterpartCallsign: providerCallsign,
        snapshotId: snapshotId,
        totalFiles: manifest.totalFiles,
        totalBytes: manifest.totalBytes,
      );
      _log('Restore completed: $snapshotId, ${manifest.totalFiles} files');
    } catch (e) {
      _restoreStatus = _restoreStatus.copyWith(
        status: 'failed',
        error: e.toString(),
      );
      _statusController.add(_restoreStatus);
      _log('Restore failed: $e');
      _fireBackupEvent(
        type: BackupEventType.restoreFailed,
        role: 'client',
        counterpartCallsign: providerCallsign,
        snapshotId: snapshotId,
        message: e.toString(),
      );
    }
  }

  // ============================================================
  // DISCOVERY (Account Restoration)
  // ============================================================

  /// Start discovery to find backup providers for account restoration
  Future<String> startDiscovery(int timeoutSeconds) async {
    final discoveryId = _generateDiscoveryId();
    final discovery = DiscoveryStatus(
      discoveryId: discoveryId,
      status: 'in_progress',
    );
    _activeDiscoveries[discoveryId] = discovery;

    // Run discovery in background
    _runDiscovery(discoveryId, timeoutSeconds);

    return discoveryId;
  }

  /// Get discovery status
  DiscoveryStatus? getDiscoveryStatus(String discoveryId) {
    return _activeDiscoveries[discoveryId];
  }

  /// Run the discovery process
  Future<void> _runDiscovery(String discoveryId, int timeoutSeconds) async {
    try {
      final profile = ProfileService().getProfile();
      final myNsec = profile.nsec;
      final myNpub = profile.npub;

      if (myNsec.isEmpty || myNpub.isEmpty) {
        throw Exception('Identity not available');
      }

      // Get list of connected devices from station
      final devices = DevicesService().getAllDevices();
      final onlineDevices = devices.where((d) => d.isOnline).toList();

      var discovery = _activeDiscoveries[discoveryId]!;
      discovery = DiscoveryStatus(
        discoveryId: discoveryId,
        status: 'in_progress',
        devicesToQuery: onlineDevices.length,
      );
      _activeDiscoveries[discoveryId] = discovery;

      // Generate random challenge
      final challenge = _generateChallenge();

      // Query each device
      for (final device in onlineDevices) {
        // Create signed discovery query
        final event = _createDiscoveryQueryEvent(myNpub, challenge, device.callsign);
        if (event == null) {
          _log('Discovery query: failed to sign event for ${device.callsign}');
          continue;
        }

        // Send query
        await _sendBackupMessage(
          device.callsign,
          {
            'type': 'backup_discovery_challenge',
            'event': event.toJson(),
            'discovery_id': discoveryId,
          },
        );

        discovery = discovery.copyWith(devicesQueried: discovery.devicesQueried + 1);
        _activeDiscoveries[discoveryId] = discovery;
      }

      // Wait for responses (with timeout)
      await Future.delayed(Duration(seconds: timeoutSeconds));

      // Mark complete
      discovery = _activeDiscoveries[discoveryId]!;
      discovery = DiscoveryStatus(
        discoveryId: discoveryId,
        status: 'complete',
        devicesToQuery: discovery.devicesToQuery,
        devicesQueried: discovery.devicesQueried,
        devicesResponded: discovery.devicesResponded,
        providersFound: discovery.providersFound,
      );
      _activeDiscoveries[discoveryId] = discovery;
    } catch (e) {
      _log('Discovery failed: $e');
      final discovery = _activeDiscoveries[discoveryId];
      if (discovery != null) {
        _activeDiscoveries[discoveryId] = DiscoveryStatus(
          discoveryId: discoveryId,
          status: 'complete',
          devicesToQuery: discovery.devicesToQuery,
          devicesQueried: discovery.devicesQueried,
          devicesResponded: discovery.devicesResponded,
          providersFound: discovery.providersFound,
        );
      }
    }
  }

  // ============================================================
  // AVAILABILITY (LAN + Station)
  // ============================================================

  Future<BackupProviderAvailabilityResult> getAvailableProviders({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final lanFuture = _queryLanProviders(timeout: timeout);
    final stationFuture = _queryStationProviders(timeout: timeout);
    final lanProviders = _dedupeAvailableProviders(await lanFuture);
    final stationProviders = _dedupeAvailableProviders(await stationFuture);

    final lanCallsigns = lanProviders.map((p) => p.callsign.toUpperCase()).toSet();
    final filteredStation = stationProviders
        .where((p) => !lanCallsigns.contains(p.callsign.toUpperCase()))
        .toList()
      ..sort((a, b) => a.callsign.compareTo(b.callsign));

    return BackupProviderAvailabilityResult(
      lanProviders: [...lanProviders]..sort((a, b) => a.callsign.compareTo(b.callsign)),
      stationProviders: filteredStation,
    );
  }

  Future<List<AvailableBackupProvider>> _queryLanProviders({Duration timeout = const Duration(seconds: 4)}) async {
    final connectionManager = ConnectionManager();
    if (!connectionManager.isInitialized) {
      _log('BackupService: ConnectionManager not initialized for LAN availability');
      return [];
    }

    try {
      await DevicesService()
          .refreshAllDevices(force: false)
          .timeout(const Duration(seconds: 1), onTimeout: () => false);
    } catch (e) {
      _log('BackupService: Failed to refresh devices: $e');
    }

    final devices = DevicesService().getAllDevices();
    final seenCandidates = <String>{};
    final candidates = devices.where(_isLanCandidate).where((device) {
      final key = device.callsign.toUpperCase();
      return seenCandidates.add(key);
    }).toList();
    if (candidates.isEmpty) return [];

    final excludeTransports = _excludeTransportsExcept({'lan'});
    final futures = candidates.map((device) => _fetchAvailabilityFromDevice(
      device.callsign,
      connectionMethod: 'lan',
      timeout: timeout,
      excludeTransports: excludeTransports,
    ));

    final results = await Future.wait(futures);
    final deduped = _dedupeAvailableProviders(results.whereType<AvailableBackupProvider>().toList());
    deduped.sort((a, b) => a.callsign.compareTo(b.callsign));
    return deduped;
  }

  Future<List<AvailableBackupProvider>> _queryStationProviders({Duration timeout = const Duration(seconds: 4)}) async {
    if (!WebSocketService().isConnected) return [];
    final stationHttpUrl = _getConnectedStationHttpUrl();
    if (stationHttpUrl == null) return [];

    try {
      final headers = _buildBackupAuthHeaders('provider_directory_query');
      if (headers == null) return [];

      final uri = Uri.parse('$stationHttpUrl/api/backup/providers/available');
      final response = await http.get(uri, headers: headers).timeout(timeout);
      if (response.statusCode != 200) {
        _log('BackupService: Station provider query failed (${response.statusCode})');
        return [];
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return [];
      final providers = decoded['providers'];
      if (providers is! List) return [];

      return providers
          .whereType<Map>()
          .map((entry) => AvailableBackupProvider.fromJson(
                Map<String, dynamic>.from(entry),
                connectionMethodOverride: 'station',
              ))
          .where((provider) => provider.callsign.isNotEmpty)
          .toList();
    } catch (e) {
      _log('BackupService: Station provider query error: $e');
      return [];
    }
  }

  List<AvailableBackupProvider> _dedupeAvailableProviders(List<AvailableBackupProvider> providers) {
    final seen = <String>{};
    final filtered = <AvailableBackupProvider>[];
    for (final provider in providers) {
      final key = provider.callsign.toUpperCase();
      if (seen.add(key)) {
        filtered.add(provider);
      }
    }
    return filtered;
  }

  bool _isLanCandidate(RemoteDevice device) {
    if (!device.isOnline) return false;
    if (device.url == null || device.url!.isEmpty) return false;
    final methods = device.connectionMethods.map((m) => m.toLowerCase()).toList();
    return methods.any((m) => m.contains('wifi') || m.contains('lan'));
  }

  Future<AvailableBackupProvider?> _fetchAvailabilityFromDevice(
    String callsign, {
    required String connectionMethod,
    required Duration timeout,
    required Set<String> excludeTransports,
  }) async {
    final connectionManager = ConnectionManager();
    final headers = _buildBackupAuthHeaders(
      'availability_query',
      targetCallsign: callsign,
    );
    if (headers == null) return null;

    try {
      _syncDeviceForTransfer(callsign);
      final result = await connectionManager.apiRequest(
        callsign: callsign,
        method: 'GET',
        path: '/api/backup/availability',
        headers: headers,
        excludeTransports: excludeTransports,
        timeout: timeout,
      );
      if (!result.success || result.responseData == null) return null;

      final payload = _decodeJsonPayload(result.responseData);
      if (payload == null) return null;
      final enabled = _readBool(payload['enabled']);
      if (enabled != true) return null;

      payload['callsign'] ??= callsign.toUpperCase();
      return AvailableBackupProvider.fromJson(
        payload,
        connectionMethodOverride: connectionMethod,
      );
    } catch (e) {
      _log('BackupService: Availability query failed for $callsign: $e');
      return null;
    }
  }

  // ============================================================
  // PROTOCOL MESSAGE HANDLERS
  // ============================================================

  /// Handle incoming backup invite (provider side)
  void handleBackupInvite(Map<String, dynamic> message) {
    try {
      final eventData = message['event'] as Map<String, dynamic>;
      final event = NostrEvent.fromJson(eventData);

      // Verify signature
      if (!event.verify()) {
        _log('Backup invite: invalid signature');
        return;
      }

      // Check timestamp (5 min freshness)
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if ((now - event.createdAt).abs() > 300) {
        _log('Backup invite: event too old');
        return;
      }

      final clientNpub = event.npub;
      final clientCallsign = event.getTagValue('callsign') ?? '';
      final intervalDays = int.tryParse(event.getTagValue('interval_days') ?? '3') ?? 3;

      _log('Received backup invite from $clientCallsign ($clientNpub)');

      // Check if provider is enabled
      if (_providerSettings?.enabled != true) {
        declineInvite(clientNpub, clientCallsign);
        return;
      }

      // Check if auto-accept is enabled for contacts
      // For now, always require manual acceptance
      // Store as pending
      final relationship = BackupClientRelationship(
        clientNpub: clientNpub,
        clientCallsign: clientCallsign,
        maxStorageBytes: _providerSettings?.defaultMaxClientStorageBytes ?? 1073741824,
        maxSnapshots: _providerSettings?.defaultMaxSnapshots ?? 10,
        status: BackupRelationshipStatus.pending,
      );

      _clients[clientCallsign.toUpperCase()] = relationship;
      _saveClientRelationship(relationship);
      _clientsController.add(getClients());

      _fireBackupEvent(
        type: BackupEventType.inviteReceived,
        role: 'provider',
        counterpartCallsign: clientCallsign,
      );
    } catch (e) {
      _log('Error handling backup invite: $e');
    }
  }

  /// Handle backup invite response (client side)
  void handleBackupInviteResponse(Map<String, dynamic> message) {
    try {
      final accepted = message['accepted'] as bool? ?? false;
      final providerNpub = message['provider_npub'] as String? ?? '';
      final providerCallsign = message['from'] as String? ?? '';
      final maxStorageBytes = message['max_storage_bytes'] as int? ?? 0;
      final maxSnapshots = message['max_snapshots'] as int? ?? 0;

      _log('Received backup invite response from $providerCallsign: ${accepted ? 'accepted' : 'declined'}');

      final completer = _pendingInvites.remove(providerCallsign.toUpperCase());
      final provider = _providers[providerCallsign.toUpperCase()];

      if (provider != null) {
        final updated = provider.copyWith(
          providerNpub: providerNpub,
          status: accepted ? BackupRelationshipStatus.active : BackupRelationshipStatus.declined,
          maxStorageBytes: maxStorageBytes,
          maxSnapshots: maxSnapshots,
        );

        _providers[providerCallsign.toUpperCase()] = updated;
        _saveProviderRelationship(updated);
        _providersController.add(getProviders());

        completer?.complete(updated);

        _fireBackupEvent(
          type: accepted ? BackupEventType.inviteAccepted : BackupEventType.inviteDeclined,
          role: 'client',
          counterpartCallsign: providerCallsign,
        );
      }
    } catch (e) {
      _log('Error handling invite response: $e');
    }
  }

  /// Handle backup start notification (provider side)
  void handleBackupStart(Map<String, dynamic> message) {
    final clientCallsign = message['from'] as String? ?? '';
    final snapshotId = message['snapshot_id'] as String? ?? '';

    _log('Backup started by $clientCallsign: $snapshotId');

    // Create snapshot status
    final snapshot = BackupSnapshot(
      snapshotId: snapshotId,
      status: 'in_progress',
      startedAt: DateTime.now(),
    );

    updateSnapshotStatus(clientCallsign, snapshot);
    _fireBackupEvent(
      type: BackupEventType.backupStarted,
      role: 'provider',
      counterpartCallsign: clientCallsign,
      snapshotId: snapshotId,
    );
  }

  /// Handle backup complete notification (provider side)
  Future<void> handleBackupComplete(Map<String, dynamic> message) async {
    final clientCallsign = message['from'] as String? ?? '';
    final snapshotId = message['snapshot_id'] as String? ?? '';
    final totalFiles = message['total_files'] as int? ?? 0;
    final totalBytes = message['total_bytes'] as int? ?? 0;

    _log('Backup completed by $clientCallsign: $snapshotId ($totalFiles files, $totalBytes bytes)');

    // Update snapshot status
    final snapshot = BackupSnapshot(
      snapshotId: snapshotId,
      status: 'complete',
      totalFiles: totalFiles,
      totalBytes: totalBytes,
      completedAt: DateTime.now(),
    );

    updateSnapshotStatus(clientCallsign, snapshot);

    await _waitForSnapshotFiles(
      clientCallsign,
      snapshotId,
      expectedFiles: totalFiles,
      timeout: const Duration(seconds: 20),
    );
    await _finalizeSnapshotArchive(clientCallsign, snapshotId);
    _fireBackupEvent(
      type: BackupEventType.backupCompleted,
      role: 'provider',
      counterpartCallsign: clientCallsign,
      snapshotId: snapshotId,
      totalFiles: totalFiles,
      totalBytes: totalBytes,
    );
  }

  /// Handle discovery challenge (provider side - checking if we have backups for this npub)
  void handleDiscoveryChallenge(Map<String, dynamic> message) {
    try {
      final eventData = message['event'] as Map<String, dynamic>;
      final event = NostrEvent.fromJson(eventData);
      final discoveryId = message['discovery_id'] as String? ?? '';

      // Verify signature
      if (!event.verify()) {
        _log('Discovery challenge: invalid signature');
        return;
      }

      // Check timestamp (5 min freshness)
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if ((now - event.createdAt).abs() > 300) {
        _log('Discovery challenge: event too old');
        return;
      }

      final targetNpub = event.getTagValue('target');
      final challenge = event.getTagValue('challenge');
      final fromCallsign = event.getTagValue('callsign') ?? '';

      if (targetNpub == null || challenge == null) {
        return;
      }

      // Check if we have backups for this npub
      bool hasBackups = false;
      BackupClientRelationship? foundClient;
      List<BackupSnapshot>? snapshots;

      for (final client in _clients.values) {
        if (client.clientNpub == targetNpub && client.status == BackupRelationshipStatus.active) {
          hasBackups = true;
          foundClient = client;
          break;
        }
      }

      if (hasBackups && foundClient != null) {
        // Get snapshots
        getSnapshots(foundClient.clientCallsign).then((snapshotList) {
          // Send response
          _sendDiscoveryResponse(
            fromCallsign,
            discoveryId,
            challenge,
            true,
            foundClient!,
            snapshotList,
          );
        });
      } else {
        // Send negative response (all devices respond to prevent identification)
        _sendDiscoveryResponse(fromCallsign, discoveryId, challenge, false, null, null);
      }
    } catch (e) {
      _log('Error handling discovery challenge: $e');
    }
  }

  /// Handle discovery response (client side)
  void handleDiscoveryResponse(Map<String, dynamic> message) {
    try {
      final eventData = message['event'] as Map<String, dynamic>;
      final event = NostrEvent.fromJson(eventData);
      final discoveryId = message['discovery_id'] as String? ?? '';
      final hasBackups = message['has_backups'] as bool? ?? false;

      // Verify signature
      if (!event.verify()) {
        _log('Discovery response: invalid signature');
        return;
      }

      var discovery = _activeDiscoveries[discoveryId];
      if (discovery == null) return;

      discovery = discovery.copyWith(devicesResponded: discovery.devicesResponded + 1);

      if (hasBackups) {
        final providerCallsign = message['from'] as String? ?? '';
        final providerNpub = event.npub;
        final maxStorageBytes = message['max_storage_bytes'] as int? ?? 0;
        final snapshotCount = message['snapshot_count'] as int? ?? 0;
        final latestSnapshot = message['latest_snapshot'] as String?;

        final provider = DiscoveredProvider(
          callsign: providerCallsign,
          npub: providerNpub,
          maxStorageBytes: maxStorageBytes,
          snapshotCount: snapshotCount,
          latestSnapshot: latestSnapshot,
        );

        discovery = DiscoveryStatus(
          discoveryId: discovery.discoveryId,
          status: discovery.status,
          devicesToQuery: discovery.devicesToQuery,
          devicesQueried: discovery.devicesQueried,
          devicesResponded: discovery.devicesResponded,
          providersFound: [...discovery.providersFound, provider],
        );

        _log('Discovered backup provider: $providerCallsign with $snapshotCount snapshots');
      }

      _activeDiscoveries[discoveryId] = discovery;
    } catch (e) {
      _log('Error handling discovery response: $e');
    }
  }

  /// Handle status change notification
  void handleStatusChange(Map<String, dynamic> message) {
    final fromCallsign = message['from'] as String? ?? '';
    final status = message['status'] as String? ?? '';

    _log('Status change from $fromCallsign: $status');

    // Update client relationship if we're provider
    final client = _clients[fromCallsign.toUpperCase()];
    if (client != null) {
      final newStatus = parseBackupRelationshipStatus(status);
      final updated = client.copyWith(status: newStatus);
      _clients[fromCallsign.toUpperCase()] = updated;
      _saveClientRelationship(updated);
      _clientsController.add(getClients());
    }

    // Update provider relationship if we're client
    final provider = _providers[fromCallsign.toUpperCase()];
    if (provider != null) {
      final newStatus = parseBackupRelationshipStatus(status);
      final updated = provider.copyWith(status: newStatus);
      _providers[fromCallsign.toUpperCase()] = updated;
      _saveProviderRelationship(updated);
      _providersController.add(getProviders());
    }
  }

  // ============================================================
  // HELPERS
  // ============================================================

  void _setupStationConnectionListener() {
    _stationConnectionSubscription?.cancel();
    _stationConnectionSubscription = EventBus().on<ConnectionStateChangedEvent>((event) {
      if (event.connectionType != ConnectionType.station) return;
      if (event.isConnected) {
        if (_providerSettings?.enabled == true) {
          unawaited(_announceProviderAvailability());
          _startProviderAnnounceTimer();
        }
      } else {
        _stopProviderAnnounceTimer();
      }
    });
  }

  void _startProviderAnnounceTimer() {
    _providerAnnounceTimer?.cancel();
    _providerAnnounceTimer = Timer.periodic(_providerAnnounceInterval, (_) {
      unawaited(_announceProviderAvailability());
    });
  }

  void _stopProviderAnnounceTimer() {
    _providerAnnounceTimer?.cancel();
    _providerAnnounceTimer = null;
  }

  Future<void> _announceProviderAvailability({bool force = false}) async {
    if (!WebSocketService().isConnected) return;
    final settings = _providerSettings;
    if (settings == null) return;
    if (!settings.enabled && !force) return;

    final event = _createSignedBackupEvent(
      action: 'provider_announce',
      content: '',
      extraTags: [
        ['enabled', settings.enabled.toString()],
        ['max_total_storage_bytes', settings.maxTotalStorageBytes.toString()],
        ['default_max_client_storage_bytes', settings.defaultMaxClientStorageBytes.toString()],
        ['default_max_snapshots', settings.defaultMaxSnapshots.toString()],
      ],
    );
    if (event == null) return;

    WebSocketService().send({
      'type': 'backup_provider_announce',
      'event': event.toJson(),
    });
  }

  String? _getConnectedStationHttpUrl() {
    final wsUrl = WebSocketService().connectedUrl;
    if (wsUrl == null || wsUrl.isEmpty) return null;
    return wsUrl
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');
  }

  Set<String> _excludeTransportsExcept(Set<String> allowed) {
    final connectionManager = ConnectionManager();
    final all = connectionManager.transports.map((t) => t.id).toSet();
    return all.difference(allowed);
  }

  Set<String> _backupApiExcludeTransports() {
    return _excludeTransportsExcept({'lan', 'station'});
  }

  Future<String?> _resolveDeviceUrl(String callsign) async {
    final normalized = callsign.toUpperCase();
    final cached = _resolvedUrls[normalized];
    if (cached != null && cached.isNotEmpty) return cached;

    final device = DevicesService().getDevice(normalized);
    final deviceUrl = device?.url;
    if (deviceUrl != null && deviceUrl.isNotEmpty) {
      _resolvedUrls[normalized] = deviceUrl;
      return deviceUrl;
    }

    final localhostPorts = AppArgs().scanLocalhostPorts;
    if (localhostPorts != null) {
      final (startPort, endPort) = localhostPorts;
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      for (int port = startPort; port <= endPort; port++) {
        if (DateTime.now().isAfter(deadline)) break;
        final url = 'http://127.0.0.1:$port';
        try {
          final response = await http
              .get(Uri.parse('$url/api/status'))
              .timeout(const Duration(milliseconds: 200));
          if (response.statusCode != 200) continue;
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic>) {
            final found = data['callsign']?.toString().toUpperCase();
            if (found == normalized) {
              _resolvedUrls[normalized] = url;
              return url;
            }
          }
        } catch (_) {
          continue;
        }
      }
    }

    try {
      final results = await StationDiscoveryService()
          .scanWithProgress(timeoutMs: 500)
          .timeout(const Duration(seconds: 4), onTimeout: () => <NetworkScanResult>[]);
      for (final result in results) {
        final resultCallsign = result.callsign?.toUpperCase();
        if (resultCallsign == normalized) {
          final url = 'http://${result.ip}:${result.port}';
          _resolvedUrls[normalized] = url;
          return url;
        }
      }
    } catch (e) {
      _log('BackupService: Failed to resolve device URL for $callsign ($e)');
    }

    return null;
  }

  Map<String, dynamic>? _decodeJsonPayload(dynamic responseData) {
    if (responseData == null) return null;
    if (responseData is Map<String, dynamic>) return responseData;
    if (responseData is String) {
      try {
        final decoded = jsonDecode(responseData);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _httpGetJson(
    String callsign,
    String path,
    Map<String, String> headers, {
    String? baseUrlOverride,
  }) async {
    final baseUrl = baseUrlOverride ?? await _resolveDeviceUrl(callsign);
    if (baseUrl == null || baseUrl.isEmpty) return null;
    try {
      final uri = Uri.parse('$baseUrl$path');
      final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      _log('BackupService: HTTP JSON fallback failed for $callsign $path ($e)');
    }
    return null;
  }

  Future<bool> _httpPutJson(
    String callsign,
    String path,
    Map<String, String> headers,
    Map<String, dynamic> body, {
    String? baseUrlOverride,
  }) async {
    final baseUrl = baseUrlOverride ?? await _resolveDeviceUrl(callsign);
    if (baseUrl == null || baseUrl.isEmpty) return false;
    try {
      final uri = Uri.parse('$baseUrl$path');
      final mergedHeaders = {
        ...headers,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };
      final response = await http
          .put(uri, headers: mergedHeaders, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      _log('BackupService: HTTP JSON PUT failed for $callsign $path ($e)');
      return false;
    }
  }

  /// Max size for binary HTTP responses (50 MB) to prevent OOM.
  static const _maxBinaryResponseBytes = 50 * 1024 * 1024;

  Future<Uint8List?> _httpGetBinary(
    String callsign,
    String path,
    Map<String, String> headers, {
    String? baseUrlOverride,
    int maxBytes = _maxBinaryResponseBytes,
  }) async {
    final baseUrl = baseUrlOverride ?? await _resolveDeviceUrl(callsign);
    if (baseUrl == null || baseUrl.isEmpty) return null;
    try {
      final uri = Uri.parse('$baseUrl$path');
      final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      // Guard against OOM: reject responses larger than maxBytes
      final bodyLen = response.bodyBytes.length;
      if (bodyLen > maxBytes) {
        _log('BackupService: Response too large for $callsign $path '
            '($bodyLen bytes > $maxBytes limit)');
        return null;
      }
      return response.bodyBytes;
    } catch (e) {
      _log('BackupService: HTTP binary fallback failed for $callsign $path ($e)');
      return null;
    }
  }

  bool? _readBool(dynamic value) {
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    return null;
  }

  Future<bool> _httpPutBinary(
    String callsign,
    String path,
    Map<String, String> headers,
    Uint8List body, {
    String? baseUrlOverride,
  }) async {
    final baseUrl = baseUrlOverride ?? await _resolveDeviceUrl(callsign);
    if (baseUrl == null || baseUrl.isEmpty) return false;
    try {
      final uri = Uri.parse('$baseUrl$path');
      final response = await http.put(uri, headers: headers, body: body).timeout(const Duration(seconds: 30));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      _log('BackupService: HTTP binary upload failed for $callsign $path ($e)');
      return false;
    }
  }

  NostrEvent? _createSignedBackupEvent({
    required String action,
    String content = '',
    List<List<String>> extraTags = const [],
  }) {
    try {
      final profile = ProfileService().getProfile();
      if (profile.npub.isEmpty || profile.nsec.isEmpty || profile.callsign.isEmpty) {
        _log('BackupService: Missing NOSTR keys for signing');
        return null;
      }

      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final tags = <List<String>>[
        ['t', 'backup'],
        ['action', action],
        ['callsign', profile.callsign],
        ...extraTags,
      ];

      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: content,
        tags: tags,
      );
      event.sign(NostrCrypto.decodeNsec(profile.nsec));
      return event;
    } catch (e) {
      _log('BackupService: Failed to sign backup event: $e');
      return null;
    }
  }

  Map<String, String>? _buildBackupAuthHeaders(
    String action, {
    String? targetCallsign,
    String? snapshotId,
    String? fileName,
  }) {
    final tags = <List<String>>[];
    if (targetCallsign != null && targetCallsign.isNotEmpty) {
      tags.add(['target', targetCallsign]);
    }
    if (snapshotId != null && snapshotId.isNotEmpty) {
      tags.add(['snapshot_id', snapshotId]);
    }
    if (fileName != null && fileName.isNotEmpty) {
      tags.add(['file', fileName]);
    }

    final event = _createSignedBackupEvent(
      action: action,
      content: '',
      extraTags: tags,
    );
    if (event == null) return null;

    final eventJson = jsonEncode(event.toJson());
    final base64Event = base64Encode(utf8.encode(eventJson));
    return {'Authorization': 'Nostr $base64Event'};
  }

  NostrEvent? _createBackupMessageEvent(Map<String, dynamic> payload) {
    final type = payload['type'] as String?;
    if (type == null || type.isEmpty) return null;
    final action = _actionForBackupMessageType(type);
    if (action == null) return null;

    final extraTags = <List<String>>[];
    final target = payload['target'];
    if (target is String && target.isNotEmpty) {
      extraTags.add(['target', target]);
    }
    final snapshotId = payload['snapshot_id'];
    if (snapshotId != null && snapshotId.toString().isNotEmpty) {
      extraTags.add(['snapshot_id', snapshotId.toString()]);
    }
    final status = payload['status'];
    if (status != null && status.toString().isNotEmpty) {
      extraTags.add(['status', status.toString()]);
    }
    final totalFiles = payload['total_files'];
    if (totalFiles != null) {
      extraTags.add(['total_files', totalFiles.toString()]);
    }
    final totalBytes = payload['total_bytes'];
    if (totalBytes != null) {
      extraTags.add(['total_bytes', totalBytes.toString()]);
    }

    return _createSignedBackupEvent(
      action: action,
      content: payload['content']?.toString() ?? '',
      extraTags: extraTags,
    );
  }

  String? _actionForBackupMessageType(String type) {
    switch (type) {
      case 'backup_invite':
        return 'backup_invite';
      case 'backup_invite_response':
        return 'backup_invite_response';
      case 'backup_start':
        return 'backup_start';
      case 'backup_complete':
        return 'backup_complete';
      case 'backup_status_change':
        return 'backup_status_change';
      case 'backup_discovery_challenge':
        return 'discovery_query';
      case 'backup_discovery_response':
        return 'discovery_response';
      default:
        return null;
    }
  }

  /// Create signed invite event
  NostrEvent? _createInviteEvent(String targetCallsign, int intervalDays) {
    return _createSignedBackupEvent(
      action: 'backup_invite',
      content: 'Backup provider invitation',
      extraTags: [
        ['target', targetCallsign],
        ['interval_days', intervalDays.toString()],
      ],
    );
  }

  /// Create signed discovery query event
  NostrEvent? _createDiscoveryQueryEvent(String targetNpub, String challenge, String targetCallsign) {
    return _createSignedBackupEvent(
      action: 'discovery_query',
      content: 'Backup discovery query',
      extraTags: [
        ['target', targetNpub],
        ['challenge', challenge],
        ['target_callsign', targetCallsign],
      ],
    );
  }

  /// Send invite response
  void _sendInviteResponse(
    String clientNpub,
    String clientCallsign,
    bool accepted,
    int maxStorageBytes,
    int maxSnapshots,
  ) {
    final profile = ProfileService().getProfile();
    unawaited(_sendBackupMessage(
      clientCallsign,
      {
        'type': 'backup_invite_response',
        'accepted': accepted,
        'provider_npub': profile.npub,
        'max_storage_bytes': maxStorageBytes,
        'max_snapshots': maxSnapshots,
        'target': clientCallsign,
      },
    ));
  }

  /// Send discovery response
  void _sendDiscoveryResponse(
    String targetCallsign,
    String discoveryId,
    String challenge,
    bool hasBackups,
    BackupClientRelationship? client,
    List<BackupSnapshot>? snapshots,
  ) {
    final event = _createSignedBackupEvent(
      action: 'discovery_response',
      content: 'Backup discovery response',
      extraTags: [
        ['challenge', challenge],
        ['has_backups', hasBackups.toString()],
      ],
    );
    if (event == null) return;

    final message = <String, dynamic>{
      'type': 'backup_discovery_response',
      'target': targetCallsign,
      'discovery_id': discoveryId,
      'event': event.toJson(),
      'has_backups': hasBackups,
    };

    if (hasBackups && client != null && snapshots != null) {
      message['max_storage_bytes'] = client.maxStorageBytes;
      message['snapshot_count'] = snapshots.length;
      if (snapshots.isNotEmpty) {
        message['latest_snapshot'] = snapshots.first.snapshotId;
      }
    }

    unawaited(_sendBackupMessage(targetCallsign, message));
  }

  /// Upload encrypted file to provider via ConnectionManager
  Future<bool> _uploadEncryptedFile(
    String providerCallsign,
    String snapshotId,
    String fileName,
    Uint8List data,
  ) async {
    try {
      final myCallsign = ProfileService().getProfile().callsign;
      final authHeaders = _buildBackupAuthHeaders(
        'file_upload',
        targetCallsign: providerCallsign,
        snapshotId: snapshotId,
        fileName: fileName,
      );
      if (authHeaders == null) {
        _log('Upload file error: failed to sign auth header');
        return false;
      }
      final requestPath = '/api/backup/clients/$myCallsign/snapshots/$snapshotId/files/$fileName';
      final requestHeaders = {
        'Content-Type': 'application/octet-stream',
        ...authHeaders,
      };

      final baseUrl = await _resolveDeviceUrl(providerCallsign);
      if (baseUrl != null && baseUrl.isNotEmpty) {
        final direct = await _httpPutBinary(
          providerCallsign,
          requestPath,
          requestHeaders,
          data,
          baseUrlOverride: baseUrl,
        );
        if (direct) return true;
      }

      final connectionManager = ConnectionManager();
      if (!connectionManager.isInitialized) {
        _log('Upload file error: ConnectionManager not initialized');
        return false;
      }
      _syncDeviceForTransfer(providerCallsign);
      final result = await connectionManager.apiRequest(
        callsign: providerCallsign,
        method: 'PUT',
        path: requestPath,
        headers: requestHeaders,
        body: data,
        excludeTransports: _backupApiExcludeTransports(),
      );
      return result.success;
    } catch (e) {
      _log('Upload file error: $e');
      return false;
    }
  }

  /// Upload manifest to provider via ConnectionManager
  Future<bool> _uploadManifest(
    String providerCallsign,
    String snapshotId,
    Uint8List data,
  ) async {
    try {
      final myCallsign = ProfileService().getProfile().callsign;
      final authHeaders = _buildBackupAuthHeaders(
        'manifest_upload',
        targetCallsign: providerCallsign,
        snapshotId: snapshotId,
      );
      if (authHeaders == null) {
        _log('Upload manifest error: failed to sign auth header');
        return false;
      }
      final requestPath = '/api/backup/clients/$myCallsign/snapshots/$snapshotId';
      final requestHeaders = {
        'Content-Type': 'application/octet-stream',
        ...authHeaders,
      };

      final baseUrl = await _resolveDeviceUrl(providerCallsign);
      if (baseUrl != null && baseUrl.isNotEmpty) {
        final direct = await _httpPutBinary(
          providerCallsign,
          requestPath,
          requestHeaders,
          data,
          baseUrlOverride: baseUrl,
        );
        if (direct) return true;
      }

      final connectionManager = ConnectionManager();
      if (!connectionManager.isInitialized) {
        _log('Upload manifest error: ConnectionManager not initialized');
        return false;
      }
      _syncDeviceForTransfer(providerCallsign);
      final result = await connectionManager.apiRequest(
        callsign: providerCallsign,
        method: 'PUT',
        path: requestPath,
        headers: requestHeaders,
        body: data,
        excludeTransports: _backupApiExcludeTransports(),
      );
      return result.success;
    } catch (e) {
      _log('Upload manifest error: $e');
      return false;
    }
  }

  /// Download manifest from provider via ConnectionManager
  Future<Uint8List?> _downloadManifest(
    String providerCallsign,
    String snapshotId, {
    String? baseUrlOverride,
  }) async {
    try {
      final myCallsign = ProfileService().getProfile().callsign;
      final connectionManager = ConnectionManager();
      if (!connectionManager.isInitialized) {
        _log('Download manifest error: ConnectionManager not initialized');
        return null;
      }
      final authHeaders = _buildBackupAuthHeaders(
        'manifest_download',
        targetCallsign: providerCallsign,
        snapshotId: snapshotId,
      );
      if (authHeaders == null) {
        _log('Download manifest error: failed to sign auth header');
        return null;
      }
      final requestPath = '/api/backup/clients/$myCallsign/snapshots/$snapshotId';
      final requestHeaders = {
        'Accept': 'application/octet-stream',
        ...authHeaders,
      };

      if (baseUrlOverride != null && baseUrlOverride.isNotEmpty) {
        final direct = await _httpGetBinary(
          providerCallsign,
          requestPath,
          requestHeaders,
          baseUrlOverride: baseUrlOverride,
        );
        if (direct != null) return direct;
      }

      _syncDeviceForTransfer(providerCallsign);
      final result = await ConnectionManager().apiRequest(
        callsign: providerCallsign,
        method: 'GET',
        path: requestPath,
        headers: requestHeaders,
        excludeTransports: _backupApiExcludeTransports(),
      );

      Uint8List? decoded;
      if (result.success && result.responseData != null) {
        decoded = _decodeBinaryPayload(result.responseData, preferredKey: 'manifest');
      }
      decoded ??= await _httpGetBinary(providerCallsign, requestPath, requestHeaders);
      return decoded;
    } catch (e) {
      _log('Download manifest error: $e');
      return null;
    }
  }

  /// Download encrypted file from provider via ConnectionManager
  Future<Uint8List?> _downloadEncryptedFile(
    String providerCallsign,
    String snapshotId,
    String fileName, {
    String? baseUrlOverride,
  }) async {
    try {
      final myCallsign = ProfileService().getProfile().callsign;
      final connectionManager = ConnectionManager();
      if (!connectionManager.isInitialized) {
        _log('Download file error: ConnectionManager not initialized');
        return null;
      }
      final authHeaders = _buildBackupAuthHeaders(
        'file_download',
        targetCallsign: providerCallsign,
        snapshotId: snapshotId,
        fileName: fileName,
      );
      if (authHeaders == null) {
        _log('Download file error: failed to sign auth header');
        return null;
      }
      final requestPath = '/api/backup/clients/$myCallsign/snapshots/$snapshotId/files/$fileName';
      final requestHeaders = {
        'Accept': 'application/octet-stream',
        ...authHeaders,
      };

      if (baseUrlOverride != null && baseUrlOverride.isNotEmpty) {
        final direct = await _httpGetBinary(
          providerCallsign,
          requestPath,
          requestHeaders,
          baseUrlOverride: baseUrlOverride,
        );
        if (direct != null) return direct;
      }

      _syncDeviceForTransfer(providerCallsign);
      final result = await ConnectionManager().apiRequest(
        callsign: providerCallsign,
        method: 'GET',
        path: requestPath,
        headers: requestHeaders,
        excludeTransports: _backupApiExcludeTransports(),
      );

      Uint8List? decoded;
      if (result.success && result.responseData != null) {
        decoded = _decodeBinaryPayload(result.responseData);
      }
      decoded ??= await _httpGetBinary(
        providerCallsign,
        requestPath,
        requestHeaders,
        baseUrlOverride: baseUrlOverride,
      );
      return decoded;
    } catch (e) {
      _log('Download file error: $e');
      return null;
    }
  }

  /// Generate snapshot ID (YYYY-MM-DD format)
  String _generateSnapshotId() {
    final now = DateTime.now();
    final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final time = '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final random = Random.secure();
    final suffix = random.nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    return '${date}_$time-$suffix';
  }

  /// Generate encrypted file name
  String _generateEncryptedFileName() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    return '${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}.enc';
  }

  /// Generate discovery ID
  String _generateDiscoveryId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Generate random challenge for discovery
  String _generateChallenge() {
    final random = Random.secure();
    final bytes = List.generate(32, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _syncDeviceForTransfer(String callsign) {
    final device = DevicesService().getDevice(callsign.toUpperCase());
    final connectionManager = ConnectionManager();
    if (device?.url == null || !connectionManager.isInitialized) return;
    final transport = connectionManager.getTransport('lan');
    if (transport is LanTransport) {
      transport.registerLocalDevice(callsign.toUpperCase(), device!.url!);
    }
  }

  Future<bool> _sendBackupMessage(String targetCallsign, Map<String, dynamic> message) async {
    final normalizedTarget = targetCallsign.toUpperCase();
    final profile = ProfileService().getProfile();
    final payload = Map<String, dynamic>.from(message);
    payload['from'] ??= profile.callsign;
    payload['target'] ??= normalizedTarget;
    if (!payload.containsKey('event')) {
      final event = _createBackupMessageEvent(payload);
      if (event == null) {
        _log('BackupService: Cannot send ${payload['type']} without signed event');
        return false;
      }
      payload['event'] = event.toJson();
    }

    final connectionManager = ConnectionManager();
    if (connectionManager.isInitialized) {
      _syncDeviceForTransfer(normalizedTarget);
      final result = await connectionManager.apiRequest(
        callsign: normalizedTarget,
        method: 'POST',
        path: '/api/backup/message',
        headers: {'Content-Type': 'application/json'},
        body: payload,
      );
      if (result.success) {
        return true;
      }
    }

    if (WebSocketService().isConnected) {
      WebSocketService().send(payload);
      return true;
    }

    return false;
  }

  Uint8List? _decodeBinaryPayload(dynamic responseData, {String? preferredKey}) {
    if (responseData == null) return null;
    if (responseData is Uint8List) return responseData;
    if (responseData is List<int>) return Uint8List.fromList(responseData);
    if (responseData is List) {
      final bytes = responseData
          .map((e) => e is int ? e : int.tryParse(e.toString()))
          .whereType<int>()
          .toList();
      if (bytes.isNotEmpty) {
        return Uint8List.fromList(bytes);
      }
    }
    if (responseData is Map) {
      final dynamic value = preferredKey != null ? responseData[preferredKey] : null;
      final dynamic candidate = value ??
          responseData['data'] ??
          responseData['manifest'] ??
          responseData['file'];
      if (candidate != null) {
        return _decodeBinaryPayload(candidate);
      }
    }
    if (responseData is String) {
      final trimmed = responseData.trim();
      if (trimmed.isEmpty) return null;
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          final decoded = jsonDecode(trimmed);
          return _decodeBinaryPayload(decoded, preferredKey: preferredKey);
        } catch (_) {
          // Fall through to base64 decode.
        }
      }
      try {
        return base64Decode(trimmed);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  void _fireBackupEvent({
    required BackupEventType type,
    required String role,
    String? counterpartCallsign,
    String? snapshotId,
    String? message,
    int? totalFiles,
    int? totalBytes,
  }) {
    try {
      EventBus().fire(
        BackupEvent(
          type: type,
          role: role,
          counterpartCallsign: counterpartCallsign,
          snapshotId: snapshotId,
          message: message,
          totalFiles: totalFiles,
          totalBytes: totalBytes,
        ),
      );
    } catch (e) {
      _log('BackupService: Failed to fire backup event: $e');
    }
  }

  Future<File?> _getSnapshotArchiveFile(
    String clientCallsign,
    String snapshotId, {
    required bool createIfMissing,
  }) async {
    final snapshotDir = Directory(p.join(
      _basePath ?? '',
      'backups',
      clientCallsign.toUpperCase(),
      snapshotId,
    ));
    if (!await snapshotDir.exists()) {
      if (!createIfMissing) return null;
      await snapshotDir.create(recursive: true);
    }
    return File(p.join(snapshotDir.path, 'files.zip'));
  }

  Future<void> _finalizeSnapshotArchive(String clientCallsign, String snapshotId) async {
    final snapshotDir = Directory(p.join(
      _basePath ?? '',
      'backups',
      clientCallsign.toUpperCase(),
      snapshotId,
    ));
    final filesDir = Directory(p.join(snapshotDir.path, 'files'));
    if (!await filesDir.exists()) {
      return;
    }
    final archiveFile = File(p.join(snapshotDir.path, 'files.zip'));
    final files = <File>[];
    await for (final entity in filesDir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        files.add(entity);
      }
    }

    if (files.isEmpty) {
      _log('Finalizing archive for $clientCallsign/$snapshotId skipped: no files found');
      return;
    }

    _log('Finalizing archive for $clientCallsign/$snapshotId with ${files.length} files');

    if (!await archiveFile.parent.exists()) {
      await archiveFile.parent.create(recursive: true);
    }
    if (await archiveFile.exists()) {
      await archiveFile.delete();
    }

    final encoder = ZipFileEncoder();
    encoder.create(archiveFile.path);
    for (final entity in files) {
      try {
        encoder.addFile(entity);
        await entity.delete();
      } catch (e) {
        _log('Failed to add ${p.basename(entity.path)} to archive: $e');
      }
    }
    encoder.close();

    try {
      await filesDir.delete(recursive: true);
    } catch (e) {
      _log('Failed to clean up plaintext backup files after archiving: $e');
    }
  }

  Future<void> _waitForSnapshotFiles(
    String clientCallsign,
    String snapshotId, {
    required int expectedFiles,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (expectedFiles <= 0) return;
    final filesDir = Directory(p.join(
      _basePath ?? '',
      'backups',
      clientCallsign.toUpperCase(),
      snapshotId,
      'files',
    ));

    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (await filesDir.exists()) {
        final count = await filesDir
            .list(recursive: false, followLinks: false)
            .where((e) => e is File)
            .length;
        if (count >= expectedFiles) {
          _log('Snapshot $snapshotId reached $count/$expectedFiles encrypted files before archiving');
          return;
        }
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    _log('Snapshot $snapshotId archiving with fewer files than expected ($expectedFiles)');
  }

  void _log(String message) {
    LogService().log(message);
  }

  /// Dispose resources
  void dispose() {
    _statusController.close();
    _providersController.close();
    _clientsController.close();
    _stationConnectionSubscription?.cancel();
    _providerAnnounceTimer?.cancel();
  }
}
