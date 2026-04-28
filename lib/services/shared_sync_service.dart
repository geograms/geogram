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
import 'profile_service.dart';
import 'profile_storage.dart';
import 'shared_folder_service.dart';

class SharedJoinResult {
  final bool success;
  final String? error;
  final SharedFolder? folder;

  const SharedJoinResult({
    required this.success,
    this.error,
    this.folder,
  });
}

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

  /// Max file transfers (pulls + pushes combined) per sync cycle for a
  /// single folder. This bounds wallclock and heap pressure on initial
  /// join / large-folder catch-up. The remaining files are picked up
  /// on subsequent ticks (an immediate follow-up tick is requested via
  /// [requestSyncSoon] when this cap is hit).
  static const _maxTransfersPerCycle = 20;

  MonitoredAsyncPeriodicTimer? _timer;
  bool _running = false;
  bool _pending = false;
  DateTime? _lastRunAt;
  final Map<String, SharedSyncResult> _lastResults = {};

  bool get isRunning => _running;
  bool get isStarted => _timer != null;
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
    _timer?.cancel();
    _timer = null;
    _pending = false;
    LogService().log('SharedSyncService: stopped');
  }

  /// Mark that a sync is needed soon. Coalesces multiple requests into one
  /// run; if a sync is in flight, a trailing run fires when it finishes.
  /// No timer — relies on the existing tracked periodic task and the
  /// post-sync kick. The optional [debounce] arg is ignored, kept only for
  /// backwards compatibility with older callers.
  void requestSyncSoon({
    required String reason,
    Duration debounce = Duration.zero,
  }) {
    LogService().log('SharedSyncService: requestSyncSoon ($reason)');
    _pending = true;
    if (!_running) {
      scheduleMicrotask(_drainPending);
    }
  }

  Future<void> _drainPending() async {
    while (_pending && !_running) {
      _pending = false;
      await syncAllJoinedFolders();
    }
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

    // Shared file traffic only flows over LAN — only that transport can
    // stream binaries off the wire. Falling back to WebRTC / station
    // relay puts every file (and even the manifest) through a JSON-ish
    // bridge that buffers the body in heap and chokes Android's Dart
    // isolate after a handful of cycles. If LAN can't reach the host,
    // we just skip this tick and try again next time.
    final cm = ConnectionManager();
    final lan = cm.getTransport('lan');
    if (lan == null || !lan.isAvailable) {
      return const SharedSyncResult(
        success: false,
        error: 'LAN transport unavailable',
      );
    }
    if (!await lan.canReach(hostCallsign)) {
      return SharedSyncResult(
        success: false,
        error: 'Host $hostCallsign not reachable on LAN — skipping tick',
      );
    }

    print('SHAREDSYNC: syncing ${folder.title} (${folder.id}) with $hostCallsign');
    LogService().log(
      'SharedSyncService: syncing ${folder.title} (${folder.id}) with $hostCallsign',
    );

    // 1. Fetch host manifest (LAN-only — never via WebRTC/relay).
    final manifestResp = await cm.apiRequest(
      callsign: hostCallsign,
      method: 'GET',
      path: '/api/shared/folders/${folder.id}/manifest',
      headers: headers,
      excludeTransports: const {
        'webrtc', 'station', 'peer_relay', 'dht', 'bluetooth_classic',
        'ble', 'usb_aoa',
      },
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

    print('SHAREDSYNC: ${folder.title} manifest=${remoteFiles.length} files, ${remoteTombstones.length} tombstones');
    LogService().log(
      'SharedSyncService: ${folder.title} manifest has ${remoteFiles.length} files, ${remoteTombstones.length} tombstones',
    );

    // 2. Read prior state first so the snapshot can reuse cached SHA1s
    //    for files whose size+mtime are unchanged. Without this, the
    //    Screenshots folder (197 PNGs / 100 MB) gets fully re-hashed
    //    every 30 s and OOMs the Dart heap on Android.
    final priorState = await _readState(folder.id);
    final priorHashes = <String, ({int size, DateTime? modified, String sha1})>{};
    for (final entry in priorState.values) {
      if (entry.sha1 != null) {
        priorHashes[entry.path] = (
          size: entry.size,
          modified: entry.modified,
          sha1: entry.sha1!,
        );
      }
    }
    print(
      'SHAREDSYNC: ${folder.title} starting local snapshot (cached=${priorHashes.length})',
    );
    final localFiles = await service.snapshotFiles(
      folder,
      hash: true,
      priorHashes: priorHashes,
    );
    print('SHAREDSYNC: ${folder.title} snapshot done, local=${localFiles.length} prior=${priorState.length}');
    LogService().log(
      'SharedSyncService: ${folder.title} local snapshot=${localFiles.length}, prior=${priorState.length}',
    );

    var pulled = 0;
    var pushed = 0;
    var deletedLocally = 0;
    var deletedRemotely = 0;

    // Cap the number of file transfers per sync cycle so that on
    // initial-join / large-folder catch-up, each tick is bounded in
    // wallclock and heap pressure. Subsequent ticks drain the rest —
    // the manifest diff naturally re-discovers the still-pending
    // files. After hitting the cap we ask for an immediate follow-up
    // tick instead of waiting the full periodic interval.
    var transfers = 0;
    var morePending = false;

    // 3. Pull remote files that differ from local. Streaming path is
    //    preferred — files go straight from the host's HTTP response
    //    onto local disk without the bytes ever sitting in heap. The
    //    bulk fallback is only used when LAN streaming is unavailable
    //    (relay / Nostr DM / encrypted profile storage).
    for (final remote in remoteFiles.values) {
      final local = localFiles[remote.path];
      if (local != null && local.sha1Hash == remote.sha1) continue;
      if (transfers >= _maxTransfersPerCycle) {
        morePending = true;
        break;
      }
      final ok = await _pullFile(
        service,
        folder,
        hostCallsign,
        headers,
        remote.path,
      );
      if (ok) {
        pulled++;
        transfers++;
      }
      // Yield between files so the event loop can service UI / API
      // requests during a large catch-up sync.
      await Future<void>.delayed(Duration.zero);
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
      if (transfers >= _maxTransfersPerCycle) {
        morePending = true;
        break;
      }
      final ok = await _pushFile(
        service,
        folder,
        hostCallsign,
        headers,
        local.path,
      );
      if (ok) {
        pushed++;
        transfers++;
      }
      await Future<void>.delayed(Duration.zero);
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

    // 7. Persist new state for next delta detection. Reuse the same
    //    priorHashes cache — only files we actually pulled / pushed
    //    will miss the cache (their mtime changed), so we re-hash just
    //    those, not the whole folder.
    final newSnapshot = await service.snapshotFiles(
      folder,
      hash: true,
      priorHashes: priorHashes,
    );
    await _writeState(folder.id, newSnapshot);

    if (morePending) {
      print('SHAREDSYNC: ${folder.title} hit cycle cap (transfers=$transfers), more pending');
      LogService().log(
        'SharedSyncService: ${folder.title} hit cycle cap '
        '(${_maxTransfersPerCycle} transfers), more files pending — '
        'will continue next tick',
      );
      // Schedule a follow-up sync soon instead of waiting the full
      // periodic interval. requestSyncSoon coalesces.
      requestSyncSoon(reason: 'partial sync — more files pending');
    } else {
      print('SHAREDSYNC: ${folder.title} sync complete (pulled=$pulled pushed=$pushed)');
    }

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

  /// Pull one remote file from the host. Streams the HTTP response body
  /// directly to disk via [SharedFolderService.writeFileStream], so the
  /// full payload never materializes in heap. Falls back to bulk
  /// fetch+write when LAN streaming isn't available (relay / DM
  /// transport, or profile-backed storage).
  Future<bool> _pullFile(
    SharedFolderService service,
    SharedFolder folder,
    String hostCallsign,
    Map<String, String> headers,
    String filePath,
  ) async {
    final cm = ConnectionManager();
    final encodedPath = Uri.encodeQueryComponent(filePath);
    final apiPath =
        '/api/shared/folders/${folder.id}/file?path=$encodedPath';

    print('SHAREDSYNC: pull req $filePath');
    final streamed = await cm.streamingApiRequest(
      callsign: hostCallsign,
      method: 'GET',
      path: apiPath,
      headers: {
        ...headers,
        'Accept': 'application/octet-stream',
      },
      timeout: const Duration(minutes: 30),
    );
    print('SHAREDSYNC: pull req returned ${streamed == null ? "null" : "${streamed.statusCode}"} for $filePath');
    if (streamed != null) {
      if (streamed.statusCode >= 400) {
        // Drain the body so the connection can be returned to the pool.
        await streamed.bodyStream.drain<void>();
        return false;
      }
      print('SHAREDSYNC: pull start $filePath cl=${streamed.headers['content-length'] ?? '?'}');
      LogService().log(
        'SharedSyncService: pull start $filePath '
        '(content-length=${streamed.headers['content-length'] ?? '?'})',
      );
      try {
        await service.writeFileStream(
          folder: folder,
          relativePath: filePath,
          bytes: streamed.bodyStream,
        );
        print('SHAREDSYNC: pull done $filePath');
        LogService().log('SharedSyncService: pull done $filePath');
        return true;
      } catch (e) {
        print('SHAREDSYNC: pull failed $filePath: $e');
        LogService().log('SharedSyncService: pull stream failed for $filePath: $e');
        return false;
      }
    }

    // Bulk fallback (only used when openReadStream returned null, e.g.
    // profile-backed encrypted storage). Still pinned to LAN — we never
    // want big binary blobs going over WebRTC / relay.
    print('SHAREDSYNC: pull bulk fallback $filePath');
    final result = await cm.apiRequest(
      callsign: hostCallsign,
      method: 'GET',
      path: apiPath,
      headers: {
        ...headers,
        'Accept': 'application/octet-stream',
      },
      excludeTransports: const {
        'webrtc', 'station', 'peer_relay', 'dht', 'bluetooth_classic',
        'ble', 'usb_aoa',
      },
    );
    final code = result.statusCode;
    if (!result.success || code == null || code >= 400) return false;
    final data = result.responseData;
    Uint8List? bytes;
    if (data is Uint8List) {
      bytes = data;
    } else if (data is List<int>) {
      bytes = Uint8List.fromList(data);
    } else if (data is String) {
      bytes = Uint8List.fromList(utf8.encode(data));
    }
    if (bytes == null) return false;
    await service.writeFile(
      folder: folder,
      relativePath: filePath,
      bytes: bytes,
    );
    return true;
  }

  /// Push one local file to the host. Streams off disk via
  /// [SharedFolderService.openReadStream] so the bytes never land in
  /// heap. Falls back to bulk read+post when LAN streaming isn't
  /// available.
  Future<bool> _pushFile(
    SharedFolderService service,
    SharedFolder folder,
    String hostCallsign,
    Map<String, String> headers,
    String filePath,
  ) async {
    final cm = ConnectionManager();
    final encodedPath = Uri.encodeQueryComponent(filePath);
    final apiPath =
        '/api/shared/folders/${folder.id}/file?path=$encodedPath';

    final readStream = await service.openReadStream(
      folder: folder,
      relativePath: filePath,
    );

    if (readStream != null) {
      final streamed = await cm.streamingApiRequest(
        callsign: hostCallsign,
        method: 'POST',
        path: apiPath,
        headers: {
          ...headers,
          'Content-Type': 'application/octet-stream',
        },
        bodyStream: readStream.stream,
        bodyStreamLength: readStream.size,
        timeout: const Duration(minutes: 30),
      );
      if (streamed != null) {
        await streamed.bodyStream.drain<void>();
        return streamed.statusCode < 400;
      }
      // LAN streaming wasn't available — fall through to bulk path
      // below. The earlier openReadStream returned a fresh stream that
      // we never consumed; drop it on the floor (File.openRead leaves
      // no resource leak — the stream just gets garbage collected).
    }

    // Bulk fallback (LAN-pinned, same reasoning as the pull path).
    final bytes = await service.readFile(
      folder: folder,
      relativePath: filePath,
    );
    if (bytes == null) return false;
    final result = await cm.apiRequest(
      callsign: hostCallsign,
      method: 'POST',
      path: apiPath,
      headers: {
        ...headers,
        'Content-Type': 'application/octet-stream',
      },
      body: bytes,
      excludeTransports: const {
        'webrtc', 'station', 'peer_relay', 'dht', 'bluetooth_classic',
        'ble', 'usb_aoa',
      },
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
      final mtimeMs = m['mtime_ms'] as int?;
      return MapEntry(
        p,
        _StateEntry(
          path: p,
          size: m['size'] as int? ?? 0,
          sha1: m['sha1'] as String?,
          modified: mtimeMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(mtimeMs, isUtc: true),
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
          if (snap.modified != null)
            'mtime_ms': snap.modified!.toUtc().millisecondsSinceEpoch,
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

  /// Streaming variant: pipe an incoming HTTP request body straight to
  /// disk via [SharedFolderService.writeFileStream], so a participant
  /// pushing a large file never makes the host buffer it in heap.
  /// Returns true on success, false if the folder isn't known locally.
  Future<bool> hostApplyWriteStream({
    required String folderId,
    required String relativePath,
    required Stream<List<int>> bytes,
  }) async {
    final service = await SharedFolderService.forCurrentProfile();
    if (service == null) return false;
    final folders = await service.loadAll();
    final folder = folders.cast<SharedFolder?>().firstWhere(
      (f) => f?.id == folderId,
      orElse: () => null,
    );
    if (folder == null) return false;
    await service.writeFileStream(
      folder: folder,
      relativePath: relativePath,
      bytes: bytes,
    );
    requestSyncSoon(reason: 'host received streamed file from participant');
    return true;
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

  /// Validate + redeem an invitation code with the host, persist the
  /// resulting folder locally, store the access token, and trigger an
  /// immediate sync. Used by both the UI ("Join with code") and the
  /// `shared_join` debug action — they MUST share this code path so
  /// that automated tests exercise exactly what the UI does.
  Future<SharedJoinResult> joinByCode({
    required String code,
    String? guestPlatform,
  }) async {
    final normalized = code.trim().toUpperCase();
    final parts = normalized.split('-');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].length != 4) {
      return const SharedJoinResult(
        success: false,
        error: 'Invalid code format (expected CALLSIGN-XXXX)',
      );
    }
    final hostCallsign = parts[0];
    final profile = ProfileService().getProfile();
    if (profile.callsign.isEmpty) {
      return const SharedJoinResult(
        success: false,
        error: 'No active profile callsign',
      );
    }
    if (profile.callsign.toUpperCase() == hostCallsign) {
      return const SharedJoinResult(
        success: false,
        error: 'You are the host of this invitation',
      );
    }

    final service = await SharedFolderService.forCurrentProfile(
      createIfMissing: true,
    );
    if (service == null) {
      return const SharedJoinResult(
        success: false,
        error: 'No Shared app available on this profile',
      );
    }

    final cm = ConnectionManager();

    final validateResp = await cm.apiRequest(
      callsign: hostCallsign,
      method: 'GET',
      path:
          '/api/shared/invitations/validate?code=${Uri.encodeQueryComponent(normalized)}',
    );
    if (!validateResp.success ||
        validateResp.statusCode == null ||
        validateResp.statusCode! >= 400) {
      return SharedJoinResult(
        success: false,
        error:
            'Validate failed: ${validateResp.error ?? 'HTTP ${validateResp.statusCode}'}',
      );
    }
    final validatePayload = _decodeJsonPayload(validateResp.responseData);
    if (validatePayload is! Map<String, dynamic>) {
      return const SharedJoinResult(
        success: false,
        error: 'Invalid validate response',
      );
    }
    if (validatePayload['success'] != true) {
      return SharedJoinResult(
        success: false,
        error: validatePayload['error']?.toString() ?? 'Invalid invite',
      );
    }

    final redeemResp = await cm.apiRequest(
      callsign: hostCallsign,
      method: 'POST',
      path: '/api/shared/invitations/redeem',
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'code': normalized,
        'guest_npub': profile.npub,
        'guest_callsign': profile.callsign.toUpperCase(),
        'guest_name': profile.callsign.toUpperCase(),
        if (guestPlatform != null) 'guest_platform': guestPlatform,
      }),
    );
    if (!redeemResp.success ||
        redeemResp.statusCode == null ||
        redeemResp.statusCode! >= 400) {
      return SharedJoinResult(
        success: false,
        error:
            'Redeem failed: ${redeemResp.error ?? 'HTTP ${redeemResp.statusCode}'}',
      );
    }
    final redeemPayload = _decodeJsonPayload(redeemResp.responseData);
    if (redeemPayload is! Map<String, dynamic>) {
      LogService().log(
        'SharedSyncService.joinByCode: redeem returned non-map: '
        '${redeemResp.responseData.runtimeType}',
      );
      return const SharedJoinResult(
        success: false,
        error: 'Invalid redeem response',
      );
    }
    if (redeemPayload['success'] != true) {
      return SharedJoinResult(
        success: false,
        error: redeemPayload['error']?.toString() ?? 'Redeem failed',
      );
    }
    final remoteFolder = redeemPayload['folder'] as Map<String, dynamic>?;
    final accessToken = redeemPayload['access_token'] as String?;
    if (remoteFolder == null || accessToken == null) {
      LogService().log(
        'SharedSyncService.joinByCode: redeem payload missing fields '
        '(folder=${remoteFolder != null}, '
        'access_token=${accessToken != null})',
      );
      return const SharedJoinResult(
        success: false,
        error: 'Redeem response missing folder or access_token',
      );
    }

    try {
      // Force the joined-side copy to record who the host is and that
      // sync is on. Without these the sync filter on the joiner side
      // skips the folder forever — legacy folders saved by the host
      // before the sync metadata was added would otherwise come over
      // with hostCallsign:null + syncEnabled:false and never sync.
      final parsedHost = hostCallsign;
      final fromHost = SharedFolder.fromJson(remoteFolder);
      final desired = fromHost.copyWith(
        location: '',
        hostCallsign: fromHost.hostCallsign ?? parsedHost,
        syncEnabled: true,
      );

      // If we already have a folder with this id locally (e.g. a stale
      // legacy copy from a previous join), update it in place instead of
      // letting save() pick a deduped filename like screenshots_1.json.
      final existing = await service.findFolder(desired.id);
      final SharedFolder saved;
      if (existing != null && existing.filePath != null) {
        saved = await service.update(desired.copyWith(
          filePath: existing.filePath,
          location: existing.location.isNotEmpty ? existing.location : '',
        ));
      } else {
        saved = await service.save(desired);
      }
      await setAccessToken(folderId: saved.id, token: accessToken);
      requestSyncSoon(reason: 'joined folder');
      return SharedJoinResult(success: true, folder: saved);
    } catch (e, stack) {
      LogService().log('SharedSyncService.joinByCode: save failed: $e');
      LogService().log('Stack: $stack');
      return SharedJoinResult(
        success: false,
        error: 'Local save failed: $e',
      );
    }
  }

  Object? _decodeJsonPayload(Object? data) {
    if (data == null) return null;
    if (data is Map<String, dynamic>) return data;
    if (data is List<int>) {
      try {
        return jsonDecode(utf8.decode(data, allowMalformed: true));
      } catch (_) {
        return null;
      }
    }
    if (data is String) {
      try {
        return jsonDecode(data);
      } catch (_) {
        return null;
      }
    }
    return null;
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
  final DateTime? modified;

  const _StateEntry({
    required this.path,
    required this.size,
    this.sha1,
    this.modified,
  });
}
