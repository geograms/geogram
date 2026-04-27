/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Cross-device sync engine for the Shared app.
 *
 * Star topology: the host of each shared folder is the source of truth, and
 * every joined participant pulls from / pushes to the host. Transport is
 * delegated to [ConnectionManager] — we don't care which transport carries
 * the bytes (LAN, station relay, etc.). HTTP endpoints under
 * `/api/shared/...` on the host's debug API server handle the actual
 * manifest/file/delete operations.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../connection/connection_manager.dart';
import '../models/monitored_task.dart';
import '../models/shared_folder.dart';
import '../util/task_monitor_helpers.dart';
import 'app_service.dart';
import 'log_service.dart';
import 'profile_storage.dart';
import 'shared_folder_service.dart';

class SharedSyncResult {
  final bool success;
  final String? error;
  final int filesPulled;
  final int filesPushed;
  final int filesDeletedLocally;
  final int filesDeletedRemotely;

  const SharedSyncResult({
    required this.success,
    this.error,
    this.filesPulled = 0,
    this.filesPushed = 0,
    this.filesDeletedLocally = 0,
    this.filesDeletedRemotely = 0,
  });

  Map<String, dynamic> toJson() => {
    'success': success,
    if (error != null) 'error': error,
    'files_pulled': filesPulled,
    'files_pushed': filesPushed,
    'files_deleted_locally': filesDeletedLocally,
    'files_deleted_remotely': filesDeletedRemotely,
  };
}

class SharedSyncService {
  static final SharedSyncService _instance = SharedSyncService._();
  static SharedSyncService get instance => _instance;
  SharedSyncService._();

  static const _taskId = 'shared.sync';
  static const _stateRoot = 'shared-state';
  static const _defaultInterval = Duration(seconds: 30);

  MonitoredAsyncPeriodicTimer? _timer;
  Timer? _debounceTimer;
  bool _running = false;
  DateTime? _lastRunAt;
  final Map<String, SharedSyncResult> _lastResults = {};

  bool get isRunning => _timer != null;
  DateTime? get lastRunAt => _lastRunAt;
  Map<String, SharedSyncResult> get lastResults =>
      Map.unmodifiable(_lastResults);

  Future<void> start({Duration interval = _defaultInterval}) async {
    if (_timer != null) return;
    _timer = MonitoredAsyncPeriodicTimer(
      id: _taskId,
      name: 'Shared sync',
      description: 'Pulls/pushes joined shared folders against their host',
      serviceName: 'SharedSyncService',
      interval: interval,
      priority: TaskPriority.normal,
      callback: (_) => syncAllJoinedFolders(),
    );
    LogService().log('SharedSyncService: started (interval=${interval.inSeconds}s)');
  }

  Future<void> stop() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _timer?.cancel();
    _timer = null;
    LogService().log('SharedSyncService: stopped');
  }

  /// Schedule an immediate run after [debounce]. If a run is already scheduled
  /// or in progress, this is a no-op (the next run will pick up the new state).
  void requestSyncSoon({
    required String reason,
    Duration debounce = const Duration(seconds: 1),
  }) {
    LogService().log('SharedSyncService: requestSyncSoon ($reason)');
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => syncAllJoinedFolders());
  }

  Future<void> syncAllJoinedFolders() async {
    if (_running) return;
    _running = true;
    try {
      final service = await SharedFolderService.forCurrentProfile();
      if (service == null) return;
      await _ensureAccessTokensLoaded(service);
      final folders = await service.loadAll();
      final joined = folders.where((f) =>
          f.syncEnabled &&
          f.hostCallsign != null &&
          !service.isOwnedLocally(f));
      for (final folder in joined) {
        try {
          final result = await _syncFolder(service, folder);
          _lastResults[folder.id] = result;
        } catch (e, stack) {
          LogService().log('SharedSyncService: ${folder.title} failed: $e');
          LogService().log('Stack: $stack');
          _lastResults[folder.id] =
              SharedSyncResult(success: false, error: e.toString());
        }
      }
      _lastRunAt = DateTime.now();
    } finally {
      _running = false;
    }
  }

  Future<SharedSyncResult> syncFolder(String folderId) async {
    final service = await SharedFolderService.forCurrentProfile();
    if (service == null) {
      return const SharedSyncResult(
        success: false,
        error: 'Shared service unavailable',
      );
    }
    final folders = await service.loadAll();
    final folder = folders.cast<SharedFolder?>().firstWhere(
      (f) => f?.id == folderId,
      orElse: () => null,
    );
    if (folder == null) {
      return const SharedSyncResult(
        success: false,
        error: 'Folder not found',
      );
    }
    if (service.isOwnedLocally(folder)) {
      // Owners are the source of truth; nothing to sync against ourselves.
      return const SharedSyncResult(success: true);
    }
    await _ensureAccessTokensLoaded(service);
    final result = await _syncFolder(service, folder);
    _lastResults[folder.id] = result;
    _lastRunAt = DateTime.now();
    return result;
  }

  Future<SharedSyncResult> _syncFolder(
    SharedFolderService service,
    SharedFolder folder,
  ) async {
    final hostCallsign = folder.hostCallsign;
    if (hostCallsign == null || hostCallsign.isEmpty) {
      return const SharedSyncResult(
        success: false,
        error: 'Folder has no hostCallsign',
      );
    }
    // The access token was stored on the local folder JSON when the user
    // joined; debug API and join flow will set it via copyWith. Without one,
    // the host won't accept our requests.
    final accessToken = _accessTokenForFolder(folder);
    if (accessToken == null) {
      return const SharedSyncResult(
        success: false,
        error: 'Folder has no accessToken — re-join via invite code',
      );
    }

    final headers = {
      'X-Shared-Token': accessToken,
      'Content-Type': 'application/json',
    };

    // 1. Fetch host manifest
    final manifestResp = await ConnectionManager().apiRequest(
      callsign: hostCallsign,
      method: 'GET',
      path: '/api/shared/folders/${folder.id}/manifest',
      headers: headers,
    );
    if (!manifestResp.success || manifestResp.statusCode == null ||
        manifestResp.statusCode! >= 400) {
      return SharedSyncResult(
        success: false,
        error:
            'Manifest failed: ${manifestResp.error ?? 'HTTP ${manifestResp.statusCode}'}',
      );
    }
    final manifestPayload = _decodeJson(manifestResp.responseData);
    if (manifestPayload is! Map<String, dynamic>) {
      return const SharedSyncResult(
        success: false,
        error: 'Manifest payload not JSON',
      );
    }
    final remoteFiles = <String, _RemoteFile>{};
    for (final raw in (manifestPayload['files'] as List<dynamic>? ?? [])) {
      if (raw is! Map<String, dynamic>) continue;
      final p = raw['path'] as String?;
      if (p == null) continue;
      remoteFiles[p] = _RemoteFile(
        path: p,
        size: raw['size'] as int? ?? 0,
        sha1: raw['sha1'] as String?,
      );
    }
    final remoteTombstones = <String>{};
    for (final raw in (manifestPayload['tombstones'] as List<dynamic>? ?? [])) {
      if (raw is! Map<String, dynamic>) continue;
      final p = raw['path'] as String?;
      if (p != null) remoteTombstones.add(p);
    }

    // 2. Snapshot local + previous-sync state
    final localFiles = await service.snapshotFiles(folder, hash: true);
    final priorState = await _readState(folder.id);

    var pulled = 0;
    var pushed = 0;
    var deletedLocally = 0;
    var deletedRemotely = 0;

    // 3. Pull remote files that differ from local
    for (final remote in remoteFiles.values) {
      final local = localFiles[remote.path];
      if (local != null && local.sha1Hash == remote.sha1) continue;
      final fetched = await _fetchFile(folder, hostCallsign, headers, remote.path);
      if (fetched == null) continue;
      await service.writeFile(
        folder: folder,
        relativePath: remote.path,
        bytes: fetched,
      );
      pulled++;
    }

    // 4. Push local files that are new (not in remote and not in prior state).
    //    If a file exists locally but not in the manifest AND was in prior
    //    state, it means the host doesn't have it — the host is canon, so
    //    we *don't* push (it might have been deleted on the host since our
    //    last sync). Step 5 handles that case via tombstones.
    for (final local in localFiles.values) {
      if (remoteTombstones.contains(local.path)) continue;
      if (remoteFiles.containsKey(local.path)) continue;
      if (priorState.containsKey(local.path)) continue;
      final bytes = await service.readFile(
        folder: folder,
        relativePath: local.path,
      );
      if (bytes == null) continue;
      final ok = await _pushFile(
        folder,
        hostCallsign,
        headers,
        local.path,
        bytes,
      );
      if (ok) pushed++;
    }

    // 5. Apply remote tombstones: delete local files the host says are gone.
    for (final tombPath in remoteTombstones) {
      if (localFiles.containsKey(tombPath)) {
        await service.deleteFile(folder: folder, relativePath: tombPath);
        deletedLocally++;
      }
    }

    // 6. Push local deletions: files that were in prior state but neither
    //    in local now nor as remote tombstones — we deleted them locally.
    for (final priorPath in priorState.keys) {
      if (localFiles.containsKey(priorPath)) continue;
      if (remoteTombstones.contains(priorPath)) continue;
      if (remoteFiles.containsKey(priorPath)) {
        // Remote still has it — we deleted it; tell the host.
        final ok = await _deleteFileRemote(
          folder,
          hostCallsign,
          headers,
          priorPath,
        );
        if (ok) deletedRemotely++;
      }
    }

    // 7. Persist new state for next delta detection
    final newSnapshot = await service.snapshotFiles(folder, hash: true);
    await _writeState(folder.id, newSnapshot);

    return SharedSyncResult(
      success: true,
      filesPulled: pulled,
      filesPushed: pushed,
      filesDeletedLocally: deletedLocally,
      filesDeletedRemotely: deletedRemotely,
    );
  }

  // -----------------------------
  // HTTP helpers
  // -----------------------------

  Future<Uint8List?> _fetchFile(
    SharedFolder folder,
    String hostCallsign,
    Map<String, String> headers,
    String filePath,
  ) async {
    final result = await ConnectionManager().apiRequest(
      callsign: hostCallsign,
      method: 'GET',
      path:
          '/api/shared/folders/${folder.id}/file?path=${Uri.encodeQueryComponent(filePath)}',
      headers: headers,
    );
    if (!result.success || result.statusCode == null ||
        result.statusCode! >= 400) {
      return null;
    }
    final payload = _decodeJson(result.responseData);
    if (payload is! Map<String, dynamic>) return null;
    if (payload['exists'] != true) return null;
    final b64 = payload['content_b64'] as String?;
    if (b64 == null) return null;
    return Uint8List.fromList(base64Decode(b64));
  }

  Future<bool> _pushFile(
    SharedFolder folder,
    String hostCallsign,
    Map<String, String> headers,
    String filePath,
    Uint8List bytes,
  ) async {
    final result = await ConnectionManager().apiRequest(
      callsign: hostCallsign,
      method: 'POST',
      path: '/api/shared/folders/${folder.id}/file',
      headers: headers,
      body: jsonEncode({
        'path': filePath,
        'content_b64': base64Encode(bytes),
      }),
    );
    return result.success &&
        result.statusCode != null &&
        result.statusCode! < 400;
  }

  Future<bool> _deleteFileRemote(
    SharedFolder folder,
    String hostCallsign,
    Map<String, String> headers,
    String filePath,
  ) async {
    final result = await ConnectionManager().apiRequest(
      callsign: hostCallsign,
      method: 'POST',
      path: '/api/shared/folders/${folder.id}/delete',
      headers: headers,
      body: jsonEncode({'path': filePath}),
    );
    return result.success &&
        result.statusCode != null &&
        result.statusCode! < 400;
  }

  // -----------------------------
  // Local state cache
  // -----------------------------

  String _statePath(String folderId) => '$_stateRoot/$folderId.json';

  Future<Map<String, _StateEntry>> _readState(String folderId) async {
    final storage = AppService().profileStorage;
    if (storage == null) return {};
    final json = await storage.readJson(_statePath(folderId));
    if (json == null) return {};
    final files = json['files'] as Map<String, dynamic>? ?? {};
    return files.map((p, v) {
      final m = v as Map<String, dynamic>;
      return MapEntry(
        p,
        _StateEntry(
          path: p,
          size: m['size'] as int? ?? 0,
          sha1: m['sha1'] as String?,
        ),
      );
    });
  }

  Future<void> _writeState(
    String folderId,
    Map<String, SharedFileSnapshot> snapshots,
  ) async {
    final storage = AppService().profileStorage;
    if (storage == null) return;
    await storage.writeJson(_statePath(folderId), {
      'version': 1,
      'folder_id': folderId,
      'updated': DateTime.now().toUtc().toIso8601String(),
      'files': snapshots.map(
        (p, snap) => MapEntry(p, {
          'size': snap.size,
          if (snap.sha1Hash != null) 'sha1': snap.sha1Hash,
        }),
      ),
    });
  }

  // -----------------------------
  // Owner-side: apply a guest's pushed file/delete locally and archive.
  // Used by the HTTP endpoints when a joined participant pushes a change.
  // -----------------------------

  /// Apply a file payload from a remote participant (host-side handler).
  /// Returns the resulting [SharedFolder] (with updated metadata) or null
  /// if the folder couldn't be resolved.
  Future<SharedFolder?> hostApplyWrite({
    required String folderId,
    required String relativePath,
    required Uint8List bytes,
  }) async {
    final service = await SharedFolderService.forCurrentProfile();
    if (service == null) return null;
    final folders = await service.loadAll();
    final folder = folders.cast<SharedFolder?>().firstWhere(
      (f) => f?.id == folderId,
      orElse: () => null,
    );
    if (folder == null) return null;
    final updated = await service.writeFile(
      folder: folder,
      relativePath: relativePath,
      bytes: bytes,
    );
    requestSyncSoon(reason: 'host received file from participant');
    return updated;
  }

  Future<SharedFolder?> hostApplyDelete({
    required String folderId,
    required String relativePath,
  }) async {
    final service = await SharedFolderService.forCurrentProfile();
    if (service == null) return null;
    final folders = await service.loadAll();
    final folder = folders.cast<SharedFolder?>().firstWhere(
      (f) => f?.id == folderId,
      orElse: () => null,
    );
    if (folder == null) return null;
    final updated = await service.deleteFile(
      folder: folder,
      relativePath: relativePath,
    );
    requestSyncSoon(reason: 'host received delete from participant');
    return updated;
  }

  // -----------------------------
  // Helpers
  // -----------------------------

  dynamic _decodeJson(dynamic data) {
    if (data == null) return null;
    if (data is Map || data is List) return data;
    if (data is String) {
      if (data.isEmpty) return null;
      try {
        return jsonDecode(data);
      } catch (_) {
        return null;
      }
    }
    if (data is List<int>) {
      try {
        return jsonDecode(utf8.decode(data, allowMalformed: true));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Per-device access tokens. Stored at
  /// `<profileBase>/<sharedAppPath>/access-tokens.json` so they never leak
  /// to other devices via folder JSON exchange.
  static const _accessTokensPath = 'access-tokens.json';

  String? _accessTokenForFolder(SharedFolder folder) {
    return _cachedAccessTokens[folder.id];
  }

  Map<String, String> _cachedAccessTokens = const {};
  bool _accessTokensLoaded = false;

  Future<void> _ensureAccessTokensLoaded(SharedFolderService service) async {
    if (_accessTokensLoaded) return;
    final storage = _scopedStorage(service);
    if (storage == null) {
      _cachedAccessTokens = const {};
      _accessTokensLoaded = true;
      return;
    }
    final json = await storage.readJson(_accessTokensPath);
    final raw = json?['tokens'] as Map<String, dynamic>? ?? {};
    _cachedAccessTokens = {
      for (final entry in raw.entries) entry.key: entry.value as String,
    };
    _accessTokensLoaded = true;
  }

  Future<void> setAccessToken({
    required String folderId,
    required String token,
  }) async {
    final service = await SharedFolderService.forCurrentProfile();
    if (service == null) return;
    await _ensureAccessTokensLoaded(service);
    final updated = Map<String, String>.from(_cachedAccessTokens);
    updated[folderId] = token;
    _cachedAccessTokens = updated;
    final storage = _scopedStorage(service);
    if (storage == null) return;
    await storage.writeJson(_accessTokensPath, {
      'version': 1,
      'tokens': _cachedAccessTokens,
    });
  }

  Future<void> clearAccessToken(String folderId) async {
    final service = await SharedFolderService.forCurrentProfile();
    if (service == null) return;
    await _ensureAccessTokensLoaded(service);
    final updated = Map<String, String>.from(_cachedAccessTokens);
    updated.remove(folderId);
    _cachedAccessTokens = updated;
    final storage = _scopedStorage(service);
    if (storage == null) return;
    await storage.writeJson(_accessTokensPath, {
      'version': 1,
      'tokens': _cachedAccessTokens,
    });
  }

  ProfileStorage? _scopedStorage(SharedFolderService service) {
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null || service.appPath == null) return null;
    return ScopedProfileStorage.fromAbsolutePath(
      profileStorage,
      service.appPath!,
    );
  }
}

class _RemoteFile {
  final String path;
  final int size;
  final String? sha1;

  const _RemoteFile({required this.path, required this.size, this.sha1});
}

class _StateEntry {
  final String path;
  final int size;
  final String? sha1;

  const _StateEntry({required this.path, required this.size, this.sha1});
}
