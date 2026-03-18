/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Simple Mirror Sync Service
 *
 * Provides one-way folder synchronization from source (Instance A)
 * to destination (Instance B) using NOSTR-signed authentication.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../util/managed_http_client.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
import '../util/tlsh.dart';
import 'file_index_service.dart';
import 'log_service.dart';
import 'mirror_config_service.dart';
import 'profile_service.dart';
import 'profile_storage.dart';
import 'storage_config.dart';
import '../models/mirror_config.dart';

/// Check if a relative path matches a single ignore pattern.
/// Supports `*` (any non-slash chars), `**` (recursive/any path), `?` (single char).
bool matchesIgnorePattern(String path, String pattern) {
  // Convert glob pattern to regex
  final buf = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final ch = pattern[i];
    if (ch == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        // ** matches anything including path separators
        buf.write('.*');
        // Skip optional trailing slash after **
        i++;
        if (i + 1 < pattern.length && pattern[i + 1] == '/') i++;
      } else {
        // * matches anything except /
        buf.write('[^/]*');
      }
    } else if (ch == '?') {
      buf.write('[^/]');
    } else if (ch == '.') {
      buf.write(r'\.');
    } else {
      buf.write(ch);
    }
  }
  buf.write(r'$');
  return RegExp(buf.toString()).hasMatch(path);
}

/// Check if a relative path should be ignored given a list of patterns.
bool isIgnored(String relativePath, List<String> patterns) {
  for (final pattern in patterns) {
    if (matchesIgnorePattern(relativePath, pattern)) return true;
  }
  return false;
}

/// File entry in a mirror manifest
class MirrorFileEntry {
  /// Relative path within the folder
  final String path;

  /// SHA1 hash of file content
  final String sha1;

  /// Last modification time (Unix timestamp in seconds)
  final int mtime;

  /// File size in bytes
  final int size;

  /// TLSH locality-sensitive hash (null if file < 50 bytes)
  final String? tlsh;

  const MirrorFileEntry({
    required this.path,
    required this.sha1,
    required this.mtime,
    required this.size,
    this.tlsh,
  });

  factory MirrorFileEntry.fromJson(Map<String, dynamic> json) {
    return MirrorFileEntry(
      path: json['path'] as String,
      sha1: json['sha1'] as String,
      mtime: json['mtime'] as int,
      size: json['size'] as int,
      tlsh: json['tlsh'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'sha1': sha1,
        'mtime': mtime,
        'size': size,
        if (tlsh != null) 'tlsh': tlsh,
      };
}

/// Manifest of a folder for mirror sync
class MirrorManifest {
  /// Folder path that was scanned
  final String folder;

  /// Total number of files
  final int totalFiles;

  /// Total size in bytes
  final int totalBytes;

  /// List of files with metadata
  final List<MirrorFileEntry> files;

  /// When the manifest was generated (Unix timestamp)
  final int generatedAt;

  const MirrorManifest({
    required this.folder,
    required this.totalFiles,
    required this.totalBytes,
    required this.files,
    required this.generatedAt,
  });

  factory MirrorManifest.fromJson(Map<String, dynamic> json) {
    return MirrorManifest(
      folder: json['folder'] as String,
      totalFiles: json['total_files'] as int,
      totalBytes: json['total_bytes'] as int,
      files: (json['files'] as List)
          .map((e) => MirrorFileEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      generatedAt: json['generated_at'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
        'folder': folder,
        'total_files': totalFiles,
        'total_bytes': totalBytes,
        'files': files.map((f) => f.toJson()).toList(),
        'generated_at': generatedAt,
      };
}

/// Type of file change detected during diff
enum FileChangeType {
  /// File needs to be added (doesn't exist locally)
  add,

  /// File needs to be modified (SHA1 differs)
  modify,

  /// File should be deleted (exists locally but not in manifest)
  delete,

  /// File needs to be uploaded to remote (local newer or local-only)
  upload,
}

/// A detected change between local and remote folders
class FileChange {
  final FileChangeType type;
  final String path;
  final MirrorFileEntry? remoteEntry;
  final MirrorFileEntry? localEntry;
  final int? localSize;

  const FileChange({
    required this.type,
    required this.path,
    this.remoteEntry,
    this.localEntry,
    this.localSize,
  });

  factory FileChange.add(MirrorFileEntry entry) => FileChange(
        type: FileChangeType.add,
        path: entry.path,
        remoteEntry: entry,
      );

  factory FileChange.modify(MirrorFileEntry entry, int localSize) => FileChange(
        type: FileChangeType.modify,
        path: entry.path,
        remoteEntry: entry,
        localSize: localSize,
      );

  factory FileChange.delete(String path, int localSize) => FileChange(
        type: FileChangeType.delete,
        path: path,
        localSize: localSize,
      );

  factory FileChange.upload(MirrorFileEntry localEntry) => FileChange(
        type: FileChangeType.upload,
        path: localEntry.path,
        localEntry: localEntry,
      );
}

/// Access token for a sync session
class MirrorAccessToken {
  final String token;
  final String peerCallsign;
  final String folder;
  final DateTime expiresAt;

  const MirrorAccessToken({
    required this.token,
    required this.peerCallsign,
    required this.folder,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  factory MirrorAccessToken.fromJson(Map<String, dynamic> json) {
    return MirrorAccessToken(
      token: json['token'] as String,
      peerCallsign: json['peer_callsign'] as String,
      folder: json['folder'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (json['expires_at'] as int) * 1000),
    );
  }

  Map<String, dynamic> toJson() => {
        'token': token,
        'peer_callsign': peerCallsign,
        'folder': folder,
        'expires_at': expiresAt.millisecondsSinceEpoch ~/ 1000,
      };
}

/// Result of a sync operation
class SyncResult {
  final bool success;
  final String? error;
  final int filesAdded;
  final int filesModified;
  final int filesDeleted;
  final int filesUploaded;
  final int bytesTransferred;
  final int bytesUploaded;
  final Duration duration;

  const SyncResult({
    required this.success,
    this.error,
    this.filesAdded = 0,
    this.filesModified = 0,
    this.filesDeleted = 0,
    this.filesUploaded = 0,
    this.bytesTransferred = 0,
    this.bytesUploaded = 0,
    this.duration = Duration.zero,
  });

  factory SyncResult.failure(String error) => SyncResult(
        success: false,
        error: error,
      );

  int get totalChanges => filesAdded + filesModified + filesDeleted + filesUploaded;
}

/// Sync status for tracking progress
class SyncStatus {
  final String state; // 'idle', 'requesting', 'fetching_manifest', 'syncing', 'done', 'error'
  final String? currentFile;
  final int filesProcessed;
  final int totalFiles;
  final int bytesTransferred;
  final int totalBytes;
  final String? error;

  const SyncStatus({
    required this.state,
    this.currentFile,
    this.filesProcessed = 0,
    this.totalFiles = 0,
    this.bytesTransferred = 0,
    this.totalBytes = 0,
    this.error,
  });

  double get progress =>
      totalFiles > 0 ? filesProcessed / totalFiles : 0.0;

  factory SyncStatus.idle() => const SyncStatus(state: 'idle');

  Map<String, dynamic> toJson() => {
        'state': state,
        if (currentFile != null) 'current_file': currentFile,
        'files_processed': filesProcessed,
        'total_files': totalFiles,
        'bytes_transferred': bytesTransferred,
        'total_bytes': totalBytes,
        if (error != null) 'error': error,
        'progress': progress,
      };
}

/// A challenge for challenge-response authentication
class MirrorChallenge {
  final String nonce;
  final String folder;
  final DateTime expiresAt;
  final DateTime createdAt;

  MirrorChallenge({
    required this.nonce,
    required this.folder,
    required this.expiresAt,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
        'nonce': nonce,
        'folder': folder,
        'expires_at': expiresAt.millisecondsSinceEpoch ~/ 1000,
        'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
      };
}

/// Service for Simple Mirror synchronization
class MirrorSyncService {
  static final MirrorSyncService _instance = MirrorSyncService._();
  static MirrorSyncService get instance => _instance;

  MirrorSyncService._();

  /// Active sync tokens (issued by us as source)
  final Map<String, MirrorAccessToken> _activeTokens = {};

  /// Allowed peers for incoming sync requests (npub -> callsign)
  final Map<String, String> _allowedPeers = {};

  /// Active challenges awaiting response (nonce -> challenge)
  final Map<String, MirrorChallenge> _activeChallenges = {};

  /// Current sync status (when we're syncing as destination)
  SyncStatus _syncStatus = SyncStatus.idle();
  final _statusController = StreamController<SyncStatus>.broadcast();

  /// Stream of sync status updates
  Stream<SyncStatus> get statusStream => _statusController.stream;

  /// Current sync status
  SyncStatus get status => _syncStatus;

  /// Clear all per-profile runtime state during a profile switch.
  ///
  /// Must be called **before** [MirrorConfigService.setStorage] so that
  /// stale peers/tokens from the old profile are gone before the new
  /// config is loaded.
  void resetForProfileSwitch() {
    _allowedPeers.clear();
    _activeTokens.clear();
    _activeChallenges.clear();
    _syncStatus = SyncStatus.idle();
    _statusController.add(_syncStatus);
  }

  /// Token validity duration (1 hour)
  static const _tokenDuration = Duration(hours: 1);

  /// Challenge validity duration (2 minutes)
  static const _challengeDuration = Duration(minutes: 2);

  /// Request freshness window (5 minutes)
  static const _requestMaxAge = Duration(minutes: 5);

  // ============================================================
  // Source Side (Instance A) - Serve sync requests
  // ============================================================

  /// Add a peer that is allowed to sync from us
  void addAllowedPeer(String npub, String callsign) {
    _allowedPeers[npub] = callsign;
    LogService().log('MirrorSync: Added allowed peer $callsign ($npub)');
  }

  /// Remove an allowed peer
  void removeAllowedPeer(String npub) {
    final callsign = _allowedPeers.remove(npub);
    if (callsign != null) {
      LogService().log('MirrorSync: Removed allowed peer $callsign');
    }
  }

  /// Get list of allowed peers
  Map<String, String> get allowedPeers => Map.unmodifiable(_allowedPeers);

  /// Load allowed peers from persisted MirrorConfig.
  /// Called on startup and after pairing to restore _allowedPeers from disk.
  void loadAllowedPeersFromConfig() {
    final config = MirrorConfigService.instance.config;
    if (config != null) {
      for (final peer in config.peers) {
        if (peer.npub.isNotEmpty) {
          _allowedPeers[peer.npub] = peer.callsign;
        }
      }
    }
    // Always auto-add own npub — even without a config file (fresh device)
    // so that mirror devices with the same identity can authenticate.
    _addOwnNpubAsAllowedPeer();
    LogService().log('MirrorSync: Loaded ${_allowedPeers.length} allowed peers from config');
  }

  /// Auto-add own npub as allowed peer so mirror devices with the same
  /// identity can authenticate via challenge-response.
  void _addOwnNpubAsAllowedPeer() {
    try {
      final profile = ProfileService().getProfile();
      if (profile.npub.isNotEmpty && profile.callsign.isNotEmpty) {
        if (!_allowedPeers.containsKey(profile.npub)) {
          _allowedPeers[profile.npub] = profile.callsign;
          LogService().log('MirrorSync: Auto-added own npub as allowed peer for mirror sync');
        }
      }
    } catch (_) {
      // ProfileService may not be initialized yet
    }
  }

  /// Generate a challenge for a folder sync request
  /// The requester must sign this challenge to prove identity
  MirrorChallenge generateChallenge(String folder) {
    // Clean up expired challenges
    _activeChallenges.removeWhere((_, c) => c.isExpired);

    // Generate random nonce (32 bytes hex = 64 chars)
    final random = List<int>.generate(32, (_) => DateTime.now().microsecondsSinceEpoch % 256);
    final nonce = sha256.convert(random).toString();

    final challenge = MirrorChallenge(
      nonce: nonce,
      folder: folder,
      expiresAt: DateTime.now().add(_challengeDuration),
    );

    _activeChallenges[nonce] = challenge;
    LogService().log('MirrorSync: Generated challenge for folder $folder: ${nonce.substring(0, 16)}...');

    return challenge;
  }

  /// Verify an incoming sync request with challenge-response
  /// The event content must be: "mirror_response:<nonce>:<folder>"
  /// Returns access token if valid, null otherwise
  Future<({bool allowed, String? token, String? error, int? expiresAt})>
      verifyRequest(NostrEvent event, String folder) async {
    // 1. Verify NOSTR signature
    if (!event.verify()) {
      return (
        allowed: false,
        token: null,
        error: 'INVALID_SIGNATURE',
        expiresAt: null
      );
    }

    // 2. Check request freshness
    final requestTime =
        DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000);
    if (DateTime.now().difference(requestTime) > _requestMaxAge) {
      return (
        allowed: false,
        token: null,
        error: 'EXPIRED_REQUEST',
        expiresAt: null
      );
    }

    // 3. Check if peer is allowed
    final peerNpub = NostrCrypto.encodeNpub(event.pubkey);
    final peerCallsign = _allowedPeers[peerNpub];
    if (peerCallsign == null) {
      return (
        allowed: false,
        token: null,
        error: 'PEER_NOT_ALLOWED',
        expiresAt: null
      );
    }

    // 4. Verify challenge-response
    // Content format: "mirror_response:<nonce>:<folder>"
    final content = event.content;
    if (!content.startsWith('mirror_response:')) {
      return (
        allowed: false,
        token: null,
        error: 'INVALID_CHALLENGE_FORMAT',
        expiresAt: null
      );
    }

    final parts = content.split(':');
    if (parts.length != 3) {
      return (
        allowed: false,
        token: null,
        error: 'INVALID_CHALLENGE_FORMAT',
        expiresAt: null
      );
    }

    final nonce = parts[1];
    final requestedFolder = parts[2];

    // Verify the nonce exists and hasn't expired
    final challenge = _activeChallenges[nonce];
    if (challenge == null) {
      return (
        allowed: false,
        token: null,
        error: 'INVALID_CHALLENGE',
        expiresAt: null
      );
    }

    if (challenge.isExpired) {
      _activeChallenges.remove(nonce);
      return (
        allowed: false,
        token: null,
        error: 'CHALLENGE_EXPIRED',
        expiresAt: null
      );
    }

    // Verify the folder matches
    if (requestedFolder != folder || challenge.folder != folder) {
      return (
        allowed: false,
        token: null,
        error: 'FOLDER_MISMATCH',
        expiresAt: null
      );
    }

    // Challenge verified - remove it (single use)
    _activeChallenges.remove(nonce);
    LogService().log('MirrorSync: Challenge verified for $peerCallsign');

    // 5. Folder existence is NOT required — the peer may want to push
    // files into a folder that doesn't exist here yet. The upload handler
    // creates directories on the fly, and the manifest handler returns an
    // empty manifest for missing folders.

    // 6. Generate access token
    final token = const Uuid().v4();
    final expiresAt = DateTime.now().add(_tokenDuration);

    final accessToken = MirrorAccessToken(
      token: token,
      peerCallsign: peerCallsign,
      folder: folder,
      expiresAt: expiresAt,
    );

    _activeTokens[token] = accessToken;
    LogService().log(
        'MirrorSync: Issued token for $peerCallsign to sync $folder');

    return (
      allowed: true,
      token: token,
      error: null,
      expiresAt: expiresAt.millisecondsSinceEpoch ~/ 1000
    );
  }

  /// Validate a token and return the associated folder and peer callsign.
  ///
  /// The [peerCallsign] is the shared callsign for mirror sync — it tells
  /// server handlers which callsign directory to read from / write to,
  /// instead of blindly using the active profile's callsign.
  ({String folder, String peerCallsign})? validateToken(String? token) {
    if (token == null) return null;
    final accessToken = _activeTokens[token];
    if (accessToken == null) return null;
    if (accessToken.isExpired) {
      _activeTokens.remove(token);
      return null;
    }
    return (folder: accessToken.folder, peerCallsign: accessToken.peerCallsign);
  }

  /// Generate manifest for a folder
  Future<MirrorManifest> generateManifest(
    String folderPath, {
    ProfileStorage? storage,
    FileIndexService? fileIndex,
  }) async {
    final files = <MirrorFileEntry>[];
    var totalBytes = 0;
    final folder = path.basename(folderPath);

    if (storage != null) {
      // Use ProfileStorage (works with both encrypted and filesystem)
      final exists = await storage.directoryExists(folder);
      if (!exists) {
        throw StateError('Folder does not exist: $folder');
      }

      final entries = await storage.listDirectory(folder, recursive: true);
      final currentPaths = <String>{};
      final cachedIndex = fileIndex?.getFolderIndex(folder) ?? {};
      final cacheMisses =
          <({String path, int size, int mtime, String sha1, String? tlsh})>[];

      for (final entry in entries) {
        if (entry.isDirectory) continue;
        // entry.path is relative to storage base, e.g. "blog-xxx/2024/post.md"
        // We need path relative to the folder
        final fullRelPath = entry.path;
        final relativePath = fullRelPath.startsWith('$folder/')
            ? fullRelPath.substring(folder.length + 1)
            : fullRelPath;

        if (relativePath.startsWith('.')) continue;
        if (relativePath == 'log' || relativePath.startsWith('log/')) continue;

        currentPaths.add(relativePath);

        try {
          final entryMtime =
              (entry.modified?.millisecondsSinceEpoch ?? 0) ~/ 1000;
          final entrySize = entry.size ?? 0;

          // Try bulk-loaded cache first
          final cached = cachedIndex[relativePath];
          final cachedHash =
              (cached != null && cached.size == entrySize && cached.mtime == entryMtime)
                  ? cached.sha1
                  : null;
          String sha1Hash;
          String? tlshHash;

          if (cachedHash != null) {
            sha1Hash = cachedHash;
          } else {
            final bytes = await storage.readBytes(fullRelPath);
            if (bytes == null) continue;
            sha1Hash = sha1.convert(bytes).toString();
            tlshHash = TLSH.hash(Uint8List.fromList(bytes));
            cacheMisses.add((
              path: relativePath,
              size: entrySize,
              mtime: entryMtime,
              sha1: sha1Hash,
              tlsh: tlshHash,
            ));
          }

          files.add(MirrorFileEntry(
            path: relativePath,
            sha1: sha1Hash,
            mtime: entryMtime,
            size: entrySize,
            tlsh: tlshHash,
          ));

          totalBytes += entrySize;
        } catch (e) {
          LogService().log('MirrorSync: Error reading file $relativePath: $e');
        }
      }

      fileIndex?.batchPutHashes(folder, cacheMisses);
      fileIndex?.pruneFolder(folder, currentPaths);
    } else {
      // Fallback: raw filesystem
      final dir = Directory(folderPath);
      if (!await dir.exists()) {
        throw StateError('Folder does not exist: $folderPath');
      }

      final currentPaths = <String>{};
      final cachedIndex = fileIndex?.getFolderIndex(folder) ?? {};
      final cacheMisses =
          <({String path, int size, int mtime, String sha1, String? tlsh})>[];

      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final relativePath = path.relative(entity.path, from: folderPath);

          if (relativePath.startsWith('.')) continue;
          if (relativePath == 'log' || relativePath.startsWith('log/')) continue;

          currentPaths.add(relativePath);

          try {
            final stat = await entity.stat();
            final entryMtime = stat.modified.millisecondsSinceEpoch ~/ 1000;
            final entrySize = stat.size;

            // Try bulk-loaded cache first
            final cached = cachedIndex[relativePath];
            final cachedHash =
                (cached != null && cached.size == entrySize && cached.mtime == entryMtime)
                    ? cached.sha1
                    : null;
            String sha1Hash;
            String? tlshHash;

            if (cachedHash != null) {
              sha1Hash = cachedHash;
            } else {
              final bytes = await entity.readAsBytes();
              sha1Hash = sha1.convert(bytes).toString();
              tlshHash = TLSH.hash(Uint8List.fromList(bytes));
              cacheMisses.add((
                path: relativePath,
                size: entrySize,
                mtime: entryMtime,
                sha1: sha1Hash,
                tlsh: tlshHash,
              ));
            }

            files.add(MirrorFileEntry(
              path: relativePath,
              sha1: sha1Hash,
              mtime: entryMtime,
              size: entrySize,
              tlsh: tlshHash,
            ));

            totalBytes += entrySize;
          } catch (e) {
            LogService().log('MirrorSync: Error reading file $relativePath: $e');
          }
        }
      }

      fileIndex?.batchPutHashes(folder, cacheMisses);
      fileIndex?.pruneFolder(folder, currentPaths);
    }

    // Sort files by path for consistent ordering
    files.sort((a, b) => a.path.compareTo(b.path));

    return MirrorManifest(
      folder: folder,
      totalFiles: files.length,
      totalBytes: totalBytes,
      files: files,
      generatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// Read a file for sync (returns bytes and SHA1)
  Future<({Uint8List bytes, String sha1})> readFile(
    String folderPath,
    String relativePath, {
    ProfileStorage? storage,
  }) async {
    if (storage != null) {
      final folder = path.basename(folderPath);
      final bytes = await storage.readBytes('$folder/$relativePath');
      if (bytes == null) {
        throw StateError('File not found: $relativePath');
      }
      final sha1Hash = sha1.convert(bytes).toString();
      return (bytes: bytes, sha1: sha1Hash);
    }

    final filePath = '$folderPath/$relativePath';
    final file = File(filePath);

    if (!await file.exists()) {
      throw StateError('File not found: $relativePath');
    }

    final bytes = await file.readAsBytes();
    final sha1Hash = sha1.convert(bytes).toString();

    return (bytes: bytes, sha1: sha1Hash);
  }

  // ============================================================
  // Destination Side (Instance B) - Perform sync
  // ============================================================

  /// Build a URI from a peer base URL, an API path, and optional query params.
  /// Preserves any query params already on [peerUrl] (e.g. `?target=ID`).
  static Uri _buildPeerUri(String peerUrl, String apiPath, [Map<String, String>? params]) {
    final base = Uri.parse(peerUrl);
    final merged = <String, String>{
      ...base.queryParameters,
      if (params != null) ...params,
    };
    return base.replace(
      path: '${base.path}$apiPath',
      queryParameters: merged.isNotEmpty ? merged : null,
    );
  }

  /// Fetch a challenge from the peer for the given folder
  Future<({String? nonce, String? error})> fetchChallenge(
    String peerUrl,
    String folder,
  ) async {
    try {
      final url = _buildPeerUri(peerUrl, '/api/mirror/challenge', {'folder': folder});
      final response = await http.get(url);

      if (response.statusCode != 200) {
        final body = jsonDecode(response.body);
        return (nonce: null, error: (body['error'] ?? 'Challenge failed') as String?);
      }

      final body = jsonDecode(response.body);
      if (body['success'] != true) {
        return (nonce: null, error: (body['error'] ?? 'Challenge failed') as String?);
      }

      return (nonce: body['nonce'] as String, error: null);
    } catch (e) {
      LogService().log('MirrorSync: Challenge fetch failed: $e');
      return (nonce: null, error: e.toString());
    }
  }

  /// Create a signed challenge response event
  /// Content format: "mirror_response:<nonce>:<folder>"
  Future<NostrEvent?> createChallengeResponse(String nonce, String folder) async {
    final profile = ProfileService().getProfile();
    if (profile.nsec.isEmpty) {
      LogService().log('MirrorSync: Cannot create response without nsec');
      return null;
    }

    final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);

    final event = NostrEvent(
      pubkey: pubkeyHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.textNote,
      tags: [
        ['t', 'mirror_response'],
        ['folder', folder],
        ['nonce', nonce],
      ],
      content: 'mirror_response:$nonce:$folder',
    );

    event.signWithNsec(profile.nsec);
    return event;
  }

  /// Request sync permission from a peer using challenge-response
  Future<({bool allowed, String? token, String? error})> requestSync(
    String peerUrl,
    String folder,
  ) async {
    _updateStatus(const SyncStatus(state: 'requesting'));

    try {
      // 1. Fetch challenge from peer
      final challengeResult = await fetchChallenge(peerUrl, folder);
      if (challengeResult.nonce == null) {
        return (
          allowed: false,
          token: null,
          error: challengeResult.error ?? 'Failed to get challenge'
        );
      }

      LogService().log('MirrorSync: Got challenge: ${challengeResult.nonce!.substring(0, 16)}...');

      // 2. Sign the challenge
      final event = await createChallengeResponse(challengeResult.nonce!, folder);
      if (event == null) {
        return (allowed: false, token: null, error: 'Failed to sign challenge');
      }

      // 3. Send signed challenge response to peer
      final url = _buildPeerUri(peerUrl, '/api/mirror/request');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'event': event.toJson(),
          'folder': folder,
        }),
      );

      if (response.statusCode != 200) {
        final body = jsonDecode(response.body);
        return (
          allowed: false,
          token: null,
          error: (body['error'] ?? 'Request failed') as String?
        );
      }

      final body = jsonDecode(response.body);
      if (body['success'] != true || body['allowed'] != true) {
        return (
          allowed: false,
          token: null,
          error: (body['error'] ?? 'Not allowed') as String?
        );
      }

      return (
        allowed: true,
        token: body['token'] as String,
        error: null,
      );
    } catch (e) {
      LogService().log('MirrorSync: Request failed: $e');
      return (allowed: false, token: null, error: e.toString());
    }
  }

  /// Fetch manifest from peer
  Future<MirrorManifest?> fetchManifest(
    String peerUrl,
    String folder,
    String token,
  ) async {
    _updateStatus(const SyncStatus(state: 'fetching_manifest'));

    try {
      final url = _buildPeerUri(peerUrl, '/api/mirror/manifest', {'folder': folder, 'token': token});

      final response = await http.get(url);

      if (response.statusCode != 200) {
        LogService()
            .log('MirrorSync: Manifest request failed: ${response.statusCode}');
        return null;
      }

      final body = jsonDecode(response.body);
      if (body['success'] != true) {
        LogService()
            .log('MirrorSync: Manifest request failed: ${body['error']}');
        return null;
      }

      return MirrorManifest.fromJson(body);
    } catch (e) {
      LogService().log('MirrorSync: Manifest fetch failed: $e');
      return null;
    }
  }

  /// Compare remote manifest against local folder
  Future<List<FileChange>> diffManifest(
    MirrorManifest remote,
    String localPath, {
    bool deleteLocalOnly = false,
    SyncStyle syncStyle = SyncStyle.receiveOnly,
    List<String> ignorePatterns = const [],
    List<SyncExcludeRule> excludeRules = const [],
    ProfileStorage? storage,
    FileIndexService? fileIndex,
    void Function(int done, int total)? onProgress,
  }) async {
    final changes = <FileChange>[];
    final localFiles = <String, ({int size, int mtime, String sha1})>{};
    final folder = path.basename(localPath);

    // Merge per-app ignorePatterns with global "always" exclude rules
    final alwaysExclude = <String>[
      ...ignorePatterns,
      ...excludeRules
          .where((r) => r.mode == ExcludeMode.always)
          .map((r) => r.pattern),
    ];
    final modifiedOnlyExclude = excludeRules
        .where((r) => r.mode == ExcludeMode.modifiedOnly)
        .map((r) => r.pattern)
        .toList();

    int filesProcessed = 0;
    int totalEntries = 0;

    if (storage != null) {
      // Scan via ProfileStorage
      final exists = await storage.directoryExists(folder);
      if (exists) {
        final entries = await storage.listDirectory(folder, recursive: true);
        final fileEntries =
            entries.where((e) => !e.isDirectory).toList();
        totalEntries = fileEntries.length;
        final currentPaths = <String>{};
        final cachedIndex = fileIndex?.getFolderIndex(folder) ?? {};
        final cacheMisses =
            <({String path, int size, int mtime, String sha1, String? tlsh})>[];

        for (final entry in fileEntries) {
          final fullRelPath = entry.path;
          final relativePath = fullRelPath.startsWith('$folder/')
              ? fullRelPath.substring(folder.length + 1)
              : fullRelPath;
          if (relativePath.startsWith('.')) {
            filesProcessed++;
            onProgress?.call(filesProcessed, totalEntries);
            continue;
          }
          if (relativePath == 'log' || relativePath.startsWith('log/')) {
            filesProcessed++;
            onProgress?.call(filesProcessed, totalEntries);
            continue;
          }
          if (isIgnored(relativePath, alwaysExclude)) {
            filesProcessed++;
            onProgress?.call(filesProcessed, totalEntries);
            continue;
          }

          currentPaths.add(relativePath);

          final entryMtime =
              (entry.modified?.millisecondsSinceEpoch ?? 0) ~/ 1000;
          final entrySize = entry.size ?? 0;

          // Try bulk-loaded cache first
          final cached = cachedIndex[relativePath];
          final cachedHash =
              (cached != null && cached.size == entrySize && cached.mtime == entryMtime)
                  ? cached.sha1
                  : null;
          String hash;

          if (cachedHash != null) {
            hash = cachedHash;
          } else {
            final bytes = await storage.readBytes(fullRelPath);
            if (bytes == null) {
              filesProcessed++;
              onProgress?.call(filesProcessed, totalEntries);
              continue;
            }
            hash = sha1.convert(bytes).toString();
            final tlshHash = TLSH.hash(Uint8List.fromList(bytes));
            cacheMisses.add((
              path: relativePath,
              size: entrySize,
              mtime: entryMtime,
              sha1: hash,
              tlsh: tlshHash,
            ));
          }

          localFiles[relativePath] = (
            size: entrySize,
            mtime: entryMtime,
            sha1: hash,
          );

          filesProcessed++;
          onProgress?.call(filesProcessed, totalEntries);
        }

        fileIndex?.batchPutHashes(folder, cacheMisses);
        fileIndex?.pruneFolder(folder, currentPaths);
      }
    } else {
      // Scan local folder via filesystem
      final localDir = Directory(localPath);
      if (await localDir.exists()) {
        final fileEntries = <FileSystemEntity>[];
        await for (final entity in localDir.list(recursive: true)) {
          if (entity is File) fileEntries.add(entity);
        }
        totalEntries = fileEntries.length;
        final currentPaths = <String>{};
        final cachedIndex = fileIndex?.getFolderIndex(folder) ?? {};
        final cacheMisses =
            <({String path, int size, int mtime, String sha1, String? tlsh})>[];

        for (final entity in fileEntries) {
          final relativePath = path.relative(entity.path, from: localPath);
          if (relativePath.startsWith('.')) {
            filesProcessed++;
            onProgress?.call(filesProcessed, totalEntries);
            continue;
          }
          if (relativePath == 'log' || relativePath.startsWith('log/')) {
            filesProcessed++;
            onProgress?.call(filesProcessed, totalEntries);
            continue;
          }
          if (isIgnored(relativePath, alwaysExclude)) {
            filesProcessed++;
            onProgress?.call(filesProcessed, totalEntries);
            continue;
          }

          currentPaths.add(relativePath);

          final stat = await (entity as File).stat();
          final entryMtime = stat.modified.millisecondsSinceEpoch ~/ 1000;
          final entrySize = stat.size;

          // Try bulk-loaded cache first
          final cached = cachedIndex[relativePath];
          final cachedHash =
              (cached != null && cached.size == entrySize && cached.mtime == entryMtime)
                  ? cached.sha1
                  : null;
          String hash;

          if (cachedHash != null) {
            hash = cachedHash;
          } else {
            final bytes = await (entity as File).readAsBytes();
            hash = sha1.convert(bytes).toString();
            final tlshHash = TLSH.hash(Uint8List.fromList(bytes));
            cacheMisses.add((
              path: relativePath,
              size: entrySize,
              mtime: entryMtime,
              sha1: hash,
              tlsh: tlshHash,
            ));
          }

          localFiles[relativePath] = (
            size: entrySize,
            mtime: entryMtime,
            sha1: hash,
          );

          filesProcessed++;
          onProgress?.call(filesProcessed, totalEntries);
        }

        fileIndex?.batchPutHashes(folder, cacheMisses);
        fileIndex?.pruneFolder(folder, currentPaths);
      }
    }

    // Check remote files against local
    for (final remoteFile in remote.files) {
      if (remoteFile.path == 'log' || remoteFile.path.startsWith('log/')) continue;
      if (isIgnored(remoteFile.path, alwaysExclude)) continue;

      final local = localFiles.remove(remoteFile.path);

      if (local == null) {
        // File doesn't exist locally - add (download from remote)
        changes.add(FileChange.add(remoteFile));
      } else if (local.sha1 != remoteFile.sha1) {
        // Skip if the file matches a "modified only" exclude rule
        if (isIgnored(remoteFile.path, modifiedOnlyExclude)) continue;

        // SHA1 differs
        if (syncStyle == SyncStyle.sendReceive) {
          // Bidirectional: most recent mtime wins
          if (remoteFile.mtime > local.mtime) {
            // Remote is newer — download
            changes.add(FileChange.modify(remoteFile, local.size));
          } else if (local.mtime > remoteFile.mtime) {
            // Local is newer — upload
            changes.add(FileChange.upload(MirrorFileEntry(
              path: remoteFile.path,
              sha1: local.sha1,
              mtime: local.mtime,
              size: local.size,
            )));
          }
          // Equal mtime + different SHA1 = true conflict, skip
        } else {
          // receiveOnly / sendOnly: source (remote) always wins
          changes.add(FileChange.modify(remoteFile, local.size));
        }
      }
    }

    // Remaining local files don't exist in remote
    if (deleteLocalOnly) {
      for (final entry in localFiles.entries) {
        changes.add(FileChange.delete(entry.key, entry.value.size));
      }
    } else if (syncStyle == SyncStyle.sendReceive) {
      // Local-only files should be uploaded to remote
      for (final entry in localFiles.entries) {
        changes.add(FileChange.upload(MirrorFileEntry(
          path: entry.key,
          sha1: entry.value.sha1,
          mtime: entry.value.mtime,
          size: entry.value.size,
        )));
      }
    }

    return changes;
  }

  /// Max file size for buffered downloads into ProfileStorage (100 MB).
  static const _maxStorageFileBytes = 100 * 1024 * 1024;

  /// Max file size for streamed filesystem downloads (500 MB).
  static const _maxStreamFileBytes = 500 * 1024 * 1024;

  /// Download a single file from peer.
  ///
  /// When [storage] is null (filesystem path), the response is streamed
  /// directly to disk — no full-body buffering — to avoid OOM on large files.
  /// When [storage] is provided, chunks are collected into a [BytesBuilder]
  /// with a size guard ([_maxStorageFileBytes]).
  Future<bool> downloadFile(
    String peerUrl,
    String folder,
    String filePath,
    String localPath,
    String token, {
    String? expectedSha1,
    ProfileStorage? storage,
  }) async {
    try {
      final url = _buildPeerUri(peerUrl, '/api/mirror/file', {'path': filePath, 'token': token});

      if (storage != null) {
        // ProfileStorage requires Uint8List — stream into BytesBuilder with size cap
        return await _downloadFileBuffered(
          url, folder, filePath, expectedSha1, storage);
      }

      // Filesystem path: stream directly to file (no full-body buffer)
      final targetPath = '$localPath/$filePath';
      final result = await streamDownloadToFile(
        url,
        targetPath,
        maxBytes: _maxStreamFileBytes,
      );

      if (!result.success) {
        LogService().log(
            'MirrorSync: File download failed: $filePath (stream error or too large)');
        return false;
      }

      // Verify SHA1 if provided
      if (expectedSha1 != null && result.sha1 != expectedSha1) {
        LogService().log(
            'MirrorSync: SHA1 mismatch for $filePath: expected $expectedSha1, got ${result.sha1}');
        // Remove the bad file
        final f = File(targetPath);
        if (await f.exists()) await f.delete();
        return false;
      }

      return true;
    } catch (e) {
      LogService().log('MirrorSync: File download failed: $filePath: $e');
      return false;
    }
  }

  /// Buffered download for ProfileStorage (writeBytes needs Uint8List).
  /// Collects streamed chunks into a BytesBuilder with a size guard.
  Future<bool> _downloadFileBuffered(
    Uri url,
    String folder,
    String filePath,
    String? expectedSha1,
    ProfileStorage storage,
  ) async {
    return withHttpClient((client) async {
      final request = http.Request('GET', url);
      final response = await client.send(request).timeout(
          const Duration(minutes: 5));

      if (response.statusCode != 200) {
        LogService().log(
            'MirrorSync: File download failed: $filePath (${response.statusCode})');
        return false;
      }

      // Reject if Content-Length exceeds cap
      if (response.contentLength != null &&
          response.contentLength! > _maxStorageFileBytes) {
        LogService().log(
            'MirrorSync: Skipping $filePath — too large for storage '
            '(${response.contentLength} bytes)');
        await response.stream.drain<void>();
        return false;
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        builder.add(chunk);
        if (builder.length > _maxStorageFileBytes) {
          LogService().log(
              'MirrorSync: Skipping $filePath — exceeded ${_maxStorageFileBytes ~/ (1024 * 1024)} MB during download');
          return false;
        }
      }

      final bytes = builder.takeBytes();

      // Verify SHA1 if provided
      if (expectedSha1 != null) {
        final actualSha1 = sha1.convert(bytes).toString();
        if (actualSha1 != expectedSha1) {
          LogService().log(
              'MirrorSync: SHA1 mismatch for $filePath: expected $expectedSha1, got $actualSha1');
          return false;
        }
      }

      await storage.writeBytes('$folder/$filePath', Uint8List.fromList(bytes));
      return true;
    });
  }

  /// Upload a single file to peer
  Future<bool> uploadFile(
    String peerUrl,
    String folder,
    String filePath,
    String localPath,
    String token, {
    String? sha1Hash,
    ProfileStorage? storage,
  }) async {
    try {
      Uint8List bytes;
      if (storage != null) {
        final data = await storage.readBytes('$folder/$filePath');
        if (data == null) {
          LogService().log('MirrorSync: Upload failed, file not found: $filePath');
          return false;
        }
        bytes = data;
      } else {
        final localFile = File('$localPath/$filePath');
        if (!await localFile.exists()) {
          LogService().log('MirrorSync: Upload failed, file not found: $filePath');
          return false;
        }
        bytes = await localFile.readAsBytes();
      }

      final hash = sha1Hash ?? sha1.convert(bytes).toString();

      final url = _buildPeerUri(peerUrl, '/api/mirror/upload', {'path': filePath, 'token': token, 'sha1': hash});

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/octet-stream'},
        body: bytes,
      );

      if (response.statusCode != 200) {
        LogService().log(
            'MirrorSync: File upload failed: $filePath (${response.statusCode})');
        return false;
      }

      final body = jsonDecode(response.body);
      return body['success'] == true;
    } catch (e) {
      LogService().log('MirrorSync: File upload failed: $filePath: $e');
      return false;
    }
  }

  /// Sync a folder from a peer (complete workflow)
  Future<SyncResult> syncFolder(
    String peerUrl,
    String folder, {
    required String peerCallsign,
    bool deleteLocalOnly = false,
    SyncStyle syncStyle = SyncStyle.receiveOnly,
    List<String> ignorePatterns = const [],
    List<SyncExcludeRule> excludeRules = const [],
    void Function(SyncStatus)? onProgress,
    ProfileStorage? storage,
  }) async {
    final stopwatch = Stopwatch()..start();
    var filesAdded = 0;
    var filesModified = 0;
    var filesDeleted = 0;
    var filesUploaded = 0;
    var bytesTransferred = 0;
    var bytesUploaded = 0;

    try {
      // 1. Request sync permission
      final requestResult = await requestSync(peerUrl, folder);
      if (!requestResult.allowed || requestResult.token == null) {
        return SyncResult.failure(requestResult.error ?? 'Permission denied');
      }

      final token = requestResult.token!;

      // 2. Fetch manifest
      final manifest = await fetchManifest(peerUrl, folder, token);
      if (manifest == null) {
        return SyncResult.failure('Failed to fetch manifest');
      }

      // 3. Determine local path (under the peer's callsign directory)
      final callsignDir = StorageConfig().getCallsignDir(peerCallsign);
      final localPath = '$callsignDir/$folder';

      // Ensure callsign and local directories exist
      if (storage != null) {
        await storage.createDirectory(folder);
      } else {
        await Directory(callsignDir).create(recursive: true);
        await Directory(localPath).create(recursive: true);
      }

      // 4. Diff manifest
      final changes = await diffManifest(
        manifest,
        localPath,
        deleteLocalOnly: deleteLocalOnly,
        syncStyle: syncStyle,
        ignorePatterns: ignorePatterns,
        excludeRules: excludeRules,
        storage: storage,
      );

      if (changes.isEmpty) {
        stopwatch.stop();
        _updateStatus(SyncStatus.idle());
        return SyncResult(
          success: true,
          duration: stopwatch.elapsed,
        );
      }

      // 5. Apply changes
      _updateStatus(SyncStatus(
        state: 'syncing',
        totalFiles: changes.length,
        totalBytes: manifest.totalBytes,
      ));

      var processed = 0;
      for (final change in changes) {
        _updateStatus(SyncStatus(
          state: 'syncing',
          currentFile: change.path,
          filesProcessed: processed,
          totalFiles: changes.length,
          bytesTransferred: bytesTransferred,
          totalBytes: manifest.totalBytes,
        ));

        onProgress?.call(_syncStatus);

        switch (change.type) {
          case FileChangeType.add:
          case FileChangeType.modify:
            final success = await downloadFile(
              peerUrl,
              folder,
              change.path,
              localPath,
              token,
              expectedSha1: change.remoteEntry?.sha1,
              storage: storage,
            );

            if (success) {
              if (change.type == FileChangeType.add) {
                filesAdded++;
              } else {
                filesModified++;
              }
              bytesTransferred += change.remoteEntry?.size ?? 0;
            }
            break;

          case FileChangeType.delete:
            if (storage != null) {
              final exists = await storage.exists('$folder/${change.path}');
              if (exists) {
                await storage.delete('$folder/${change.path}');
                filesDeleted++;
              }
            } else {
              final file = File('$localPath/${change.path}');
              if (await file.exists()) {
                await file.delete();
                filesDeleted++;
              }
            }
            break;

          case FileChangeType.upload:
            final success = await uploadFile(
              peerUrl,
              folder,
              change.path,
              localPath,
              token,
              sha1Hash: change.localEntry?.sha1,
              storage: storage,
            );

            if (success) {
              filesUploaded++;
              bytesUploaded += change.localEntry?.size ?? 0;
            }
            break;
        }

        processed++;
      }

      stopwatch.stop();
      _updateStatus(SyncStatus.idle());

      return SyncResult(
        success: true,
        filesAdded: filesAdded,
        filesModified: filesModified,
        filesDeleted: filesDeleted,
        filesUploaded: filesUploaded,
        bytesTransferred: bytesTransferred,
        bytesUploaded: bytesUploaded,
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      _updateStatus(SyncStatus(state: 'error', error: e.toString()));
      return SyncResult.failure(e.toString());
    }
  }

  void _updateStatus(SyncStatus status) {
    _syncStatus = status;
    _statusController.add(status);
  }

  /// Dispose resources
  void dispose() {
    _statusController.close();
  }
}
