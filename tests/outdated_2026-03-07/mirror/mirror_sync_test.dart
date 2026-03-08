#!/usr/bin/env dart
/// Mirror Sync Integration Test
///
/// Self-contained test that verifies real file synchronization using the
/// mirror protocol. Starts a mock source server, then runs the full client
/// flow (challenge-response auth + file transfer) and verifies files on disk.
///
/// Tests:
///   1. Initial sync — files transfer from source to empty destination
///   2. SHA1 integrity — all file hashes match after transfer
///   3. No-op sync — re-sync with no changes reports zero changes
///   4. Update sync — modified files are detected and re-downloaded
///   5. New file sync — newly added files appear on re-sync
///   6. One-way mirror — destination changes overwritten by source
///   7. Pair endpoint — POST /api/mirror/pair reciprocal registration
///   8. Security — unauthorized peer rejected
///   9. Security — replay attack (nonce reuse) rejected
///  10. Security — invalid signature rejected
///  16. MirrorPeer address helpers — directAddress/stationRelayUrl
///  17. Station relay URL format — derivation from WebSocket URL
///
/// Usage:
///   dart run tests/mirror/mirror_sync_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../lib/util/nostr_crypto.dart';
import '../../lib/util/nostr_event.dart';

// ─── Test tracking ───────────────────────────────────────────────

int _testsRun = 0;
int _testsPassed = 0;
int _testsFailed = 0;
final List<String> _failedTests = [];

void check(String name, bool passed, [String? details]) {
  _testsRun++;
  if (passed) {
    _testsPassed++;
    print('  \u2713 $name');
  } else {
    _testsFailed++;
    _failedTests.add(name);
    print('  \u2717 $name');
    if (details != null) print('    $details');
  }
}

void section(String title) {
  print('\n${'=' * 60}');
  print(title);
  print('${'=' * 60}\n');
}

// ─── Mock source server ──────────────────────────────────────────

class MockSourceServer {
  final String sourceDir;
  final Map<String, String> allowedPeers = {}; // npub -> callsign
  final Map<String, _Challenge> _challenges = {};
  final Map<String, _Token> _tokens = {};
  late HttpServer _server;
  int _challengeCounter = 0;
  int _tokenCounter = 0;

  MockSourceServer(this.sourceDir);

  int get port => _server.port;
  String get url => 'http://localhost:$port';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }

  void _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;

    try {
      if (path == '/api/mirror/challenge' && method == 'GET') {
        await _handleChallenge(request);
      } else if (path == '/api/mirror/request' && method == 'POST') {
        await _handleSyncRequest(request);
      } else if (path == '/api/mirror/manifest' && method == 'GET') {
        await _handleManifest(request);
      } else if (path == '/api/mirror/file' && method == 'GET') {
        await _handleFile(request);
      } else if (path == '/api/mirror/upload' && method == 'POST') {
        await _handleUpload(request);
      } else if (path == '/api/mirror/pair' && method == 'POST') {
        await _handlePair(request);
      } else if (path == '/api/status' && method == 'GET') {
        _jsonResponse(request, 200, {
          'app': 'Geogram',
          'npub': 'npub1sourceserver',
          'callsign': 'X1SRC',
          'nickname': 'Source Server',
          'platform': 'test',
        });
      } else {
        _jsonResponse(request, 404, {'error': 'Not found'});
      }
    } catch (e) {
      _jsonResponse(request, 500, {'error': e.toString()});
    }
  }

  Future<void> _handleChallenge(HttpRequest request) async {
    final folder = request.uri.queryParameters['folder'];
    if (folder == null || folder.isEmpty) {
      _jsonResponse(request, 400, {
        'success': false,
        'error': 'Missing folder parameter',
        'code': 'INVALID_REQUEST',
      });
      return;
    }

    if (!Directory('$sourceDir/$folder').existsSync()) {
      _jsonResponse(request, 404, {
        'success': false,
        'error': 'Folder not found',
        'code': 'FOLDER_NOT_FOUND',
      });
      return;
    }

    _challengeCounter++;
    final nonce = sha256
        .convert(utf8.encode('ch_${DateTime.now().microsecondsSinceEpoch}_$_challengeCounter'))
        .toString();
    final expiresAt = DateTime.now().add(const Duration(minutes: 2));
    _challenges[nonce] = _Challenge(nonce: nonce, folder: folder, expiresAt: expiresAt);

    _jsonResponse(request, 200, {
      'success': true,
      'nonce': nonce,
      'folder': folder,
      'expires_at': expiresAt.millisecondsSinceEpoch ~/ 1000,
    });
  }

  Future<void> _handleSyncRequest(HttpRequest request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
    final eventJson = body['event'] as Map<String, dynamic>?;
    final folder = body['folder'] as String?;

    if (eventJson == null || folder == null) {
      _jsonResponse(request, 400, {'success': false, 'error': 'Missing fields', 'code': 'INVALID_REQUEST'});
      return;
    }

    final event = NostrEvent.fromJson(eventJson);
    if (!event.verify()) {
      _jsonResponse(request, 401, {'success': false, 'allowed': false, 'error': 'Invalid signature', 'code': 'INVALID_SIGNATURE'});
      return;
    }

    final peerNpub = NostrCrypto.encodeNpub(event.pubkey);
    if (!allowedPeers.containsKey(peerNpub)) {
      _jsonResponse(request, 403, {'success': false, 'allowed': false, 'error': 'Peer not allowed', 'code': 'PEER_NOT_ALLOWED'});
      return;
    }

    final content = event.content;
    if (!content.startsWith('mirror_response:')) {
      _jsonResponse(request, 401, {'success': false, 'error': 'Invalid format', 'code': 'INVALID_CHALLENGE_FORMAT'});
      return;
    }

    final parts = content.split(':');
    if (parts.length != 3) {
      _jsonResponse(request, 401, {'success': false, 'error': 'Invalid format', 'code': 'INVALID_CHALLENGE_FORMAT'});
      return;
    }

    final nonce = parts[1];
    final requestedFolder = parts[2];
    final challenge = _challenges[nonce];

    if (challenge == null) {
      _jsonResponse(request, 401, {'success': false, 'error': 'Invalid challenge', 'code': 'INVALID_CHALLENGE'});
      return;
    }

    if (challenge.expiresAt.isBefore(DateTime.now())) {
      _challenges.remove(nonce);
      _jsonResponse(request, 401, {'success': false, 'error': 'Expired', 'code': 'CHALLENGE_EXPIRED'});
      return;
    }

    if (requestedFolder != folder || challenge.folder != folder) {
      _jsonResponse(request, 401, {'success': false, 'error': 'Folder mismatch', 'code': 'FOLDER_MISMATCH'});
      return;
    }

    _challenges.remove(nonce); // single-use

    _tokenCounter++;
    final token = sha256
        .convert(utf8.encode('tok_${DateTime.now().microsecondsSinceEpoch}_$_tokenCounter'))
        .toString();
    final tokenExpires = DateTime.now().add(const Duration(hours: 1));
    _tokens[token] = _Token(token: token, folder: folder, expiresAt: tokenExpires);

    _jsonResponse(request, 200, {
      'success': true,
      'allowed': true,
      'token': token,
      'expires_at': tokenExpires.millisecondsSinceEpoch ~/ 1000,
    });
  }

  Future<void> _handleManifest(HttpRequest request) async {
    final folder = request.uri.queryParameters['folder'];
    final token = request.uri.queryParameters['token'];

    if (token == null) {
      _jsonResponse(request, 401, {'success': false, 'error': 'Missing token'});
      return;
    }
    final validToken = _tokens[token];
    if (validToken == null || validToken.expiresAt.isBefore(DateTime.now())) {
      _jsonResponse(request, 401, {'success': false, 'error': 'Invalid token'});
      return;
    }
    if (folder != validToken.folder) {
      _jsonResponse(request, 403, {'success': false, 'error': 'Folder mismatch'});
      return;
    }

    final folderPath = '$sourceDir/$folder';
    final dir = Directory(folderPath);
    if (!dir.existsSync()) {
      _jsonResponse(request, 404, {'success': false, 'error': 'Folder not found'});
      return;
    }

    final files = <Map<String, dynamic>>[];
    var totalBytes = 0;

    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        final relative = entity.path.substring(folderPath.length + 1);
        if (relative.startsWith('.')) continue;
        final bytes = await entity.readAsBytes();
        final hash = sha1.convert(bytes).toString();
        final stat = await entity.stat();
        files.add({
          'path': relative,
          'sha1': hash,
          'mtime': stat.modified.millisecondsSinceEpoch ~/ 1000,
          'size': bytes.length,
        });
        totalBytes += bytes.length;
      }
    }
    files.sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));

    _jsonResponse(request, 200, {
      'success': true,
      'folder': folder,
      'total_files': files.length,
      'total_bytes': totalBytes,
      'files': files,
      'generated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  Future<void> _handleFile(HttpRequest request) async {
    final filePath = request.uri.queryParameters['path'];
    final token = request.uri.queryParameters['token'];

    if (token == null) {
      _jsonResponse(request, 401, {'success': false, 'error': 'Missing token'});
      return;
    }
    final validToken = _tokens[token];
    if (validToken == null || validToken.expiresAt.isBefore(DateTime.now())) {
      _jsonResponse(request, 401, {'success': false, 'error': 'Invalid token'});
      return;
    }
    if (filePath == null || filePath.isEmpty) {
      _jsonResponse(request, 400, {'success': false, 'error': 'Missing path'});
      return;
    }

    final fullPath = '$sourceDir/${validToken.folder}/$filePath';
    final file = File(fullPath);
    if (!file.existsSync()) {
      _jsonResponse(request, 404, {'success': false, 'error': 'File not found'});
      return;
    }

    final bytes = await file.readAsBytes();
    final hash = sha1.convert(bytes).toString();

    request.response
      ..statusCode = 200
      ..headers.set('Content-Type', 'application/octet-stream')
      ..headers.set('X-SHA1', hash)
      ..headers.set('Content-Length', bytes.length.toString())
      ..add(bytes);
    await request.response.close();
  }

  Future<void> _handleUpload(HttpRequest request) async {
    final filePath = request.uri.queryParameters['path'];
    final token = request.uri.queryParameters['token'];
    final expectedSha1 = request.uri.queryParameters['sha1'];

    if (token == null) {
      _jsonResponse(request, 401, {'success': false, 'error': 'Missing token'});
      return;
    }
    final validToken = _tokens[token];
    if (validToken == null || validToken.expiresAt.isBefore(DateTime.now())) {
      _jsonResponse(request, 401, {'success': false, 'error': 'Invalid token'});
      return;
    }
    if (filePath == null || filePath.isEmpty) {
      _jsonResponse(request, 400, {'success': false, 'error': 'Missing path'});
      return;
    }

    // Read body bytes
    final chunks = <int>[];
    await for (final chunk in request) {
      chunks.addAll(chunk);
    }
    final bodyBytes = Uint8List.fromList(chunks);

    // Verify SHA1 if provided
    if (expectedSha1 != null && expectedSha1.isNotEmpty) {
      final actualSha1 = sha1.convert(bodyBytes).toString();
      if (actualSha1 != expectedSha1) {
        _jsonResponse(request, 400, {
          'success': false,
          'error': 'SHA1 mismatch',
          'code': 'SHA1_MISMATCH',
        });
        return;
      }
    }

    // Write file to source dir
    final fullPath = '$sourceDir/${validToken.folder}/$filePath';
    final file = File(fullPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bodyBytes);

    _jsonResponse(request, 200, {
      'success': true,
      'path': filePath,
      'size': bodyBytes.length,
    });
  }

  Future<void> _handlePair(HttpRequest request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
    final peerNpub = body['npub'] as String?;
    final peerCallsign = body['callsign'] as String?;

    if (peerNpub == null || peerCallsign == null) {
      _jsonResponse(request, 400, {'success': false, 'error': 'Missing fields'});
      return;
    }

    allowedPeers[peerNpub] = peerCallsign;

    _jsonResponse(request, 200, {
      'success': true,
      'npub': 'npub1sourceserver',
      'callsign': 'X1SRC',
      'device_name': 'Test Source',
      'platform': 'linux',
    });
  }

  void _jsonResponse(HttpRequest request, int status, Map<String, dynamic> body) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    request.response.close();
  }
}

class _Challenge {
  final String nonce;
  final String folder;
  final DateTime expiresAt;
  _Challenge({required this.nonce, required this.folder, required this.expiresAt});
}

class _Token {
  final String token;
  final String folder;
  final DateTime expiresAt;
  _Token({required this.token, required this.folder, required this.expiresAt});
}

// ─── Client-side sync implementation ─────────────────────────────
//
// Pure Dart implementation of the mirror sync client protocol.
// Mirrors what MirrorSyncService.syncFolder() does, without
// depending on any Flutter services.

class SyncClient {
  final String nsec;
  final String npub;
  final String destDir;

  SyncClient({required this.nsec, required this.npub, required this.destDir});

  String get _pubkeyHex => NostrCrypto.decodeNpub(npub);
  String get _privkeyHex => NostrCrypto.decodeNsec(nsec);

  /// Full sync: challenge-response auth -> manifest -> diff -> download/upload
  Future<SyncResult> syncFolder(
    String peerUrl,
    String folder, {
    required String peerCallsign,
    String syncStyle = 'receiveOnly',
    List<String> ignorePatterns = const [],
  }) async {
    final stopwatch = Stopwatch()..start();
    var filesAdded = 0;
    var filesModified = 0;
    var filesUploaded = 0;
    var bytesTransferred = 0;

    // 1. Get challenge
    final challengeResp = await http.get(
      Uri.parse('$peerUrl/api/mirror/challenge?folder=${Uri.encodeComponent(folder)}'),
    );
    if (challengeResp.statusCode != 200) {
      return SyncResult(false, error: 'Challenge failed: ${challengeResp.statusCode}');
    }
    final challengeData = jsonDecode(challengeResp.body) as Map<String, dynamic>;
    if (challengeData['success'] != true) {
      return SyncResult(false, error: 'Challenge failed: ${challengeData['error']}');
    }
    final nonce = challengeData['nonce'] as String;

    // 2. Sign challenge
    final event = NostrEvent(
      pubkey: _pubkeyHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.textNote,
      tags: [
        ['t', 'mirror_response'],
        ['folder', folder],
        ['nonce', nonce],
      ],
      content: 'mirror_response:$nonce:$folder',
    );
    event.sign(_privkeyHex);

    // 3. Send signed challenge
    final requestResp = await http.post(
      Uri.parse('$peerUrl/api/mirror/request'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'event': event.toJson(), 'folder': folder}),
    );
    if (requestResp.statusCode != 200) {
      return SyncResult(false, error: 'Request failed: ${requestResp.statusCode}');
    }
    final requestData = jsonDecode(requestResp.body) as Map<String, dynamic>;
    if (requestData['success'] != true || requestData['allowed'] != true) {
      return SyncResult(false, error: 'Not allowed: ${requestData['error']}');
    }
    final token = requestData['token'] as String;

    // 4. Get manifest
    final manifestResp = await http.get(
      Uri.parse('$peerUrl/api/mirror/manifest?folder=${Uri.encodeComponent(folder)}&token=${Uri.encodeComponent(token)}'),
    );
    if (manifestResp.statusCode != 200) {
      return SyncResult(false, error: 'Manifest failed: ${manifestResp.statusCode}');
    }
    final manifest = jsonDecode(manifestResp.body) as Map<String, dynamic>;
    if (manifest['success'] != true) {
      return SyncResult(false, error: 'Manifest failed: ${manifest['error']}');
    }

    final remoteFiles = (manifest['files'] as List)
        .map((f) => f as Map<String, dynamic>)
        .toList();

    // Build remote files map for quick lookup
    final remoteMap = <String, Map<String, dynamic>>{};
    for (final rf in remoteFiles) {
      remoteMap[rf['path'] as String] = rf;
    }

    // 5. Diff against local (under the peer's callsign directory)
    final callsignDir = '$destDir/devices/$peerCallsign';
    final localDir = '$callsignDir/$folder';
    await Directory(callsignDir).create(recursive: true);
    await Directory(localDir).create(recursive: true);

    // Track local files for detecting local-only files
    final localFileSet = <String>{};

    // Scan local files
    final localDirObj = Directory(localDir);
    if (localDirObj.existsSync()) {
      await for (final entity in localDirObj.list(recursive: true)) {
        if (entity is File) {
          final relative = entity.path.substring(localDir.length + 1);
          if (relative.startsWith('.')) continue;
          if (relative == 'log' || relative.startsWith('log/')) continue;
          if (_isIgnored(relative, ignorePatterns)) continue;
          localFileSet.add(relative);
        }
      }
    }

    // Process remote files
    for (final remote in remoteFiles) {
      final remotePath = remote['path'] as String;
      final remoteSha1 = remote['sha1'] as String;
      final remoteSize = remote['size'] as int;
      final remoteMtime = remote['mtime'] as int;

      if (remotePath == 'log' || remotePath.startsWith('log/')) continue;
      if (_isIgnored(remotePath, ignorePatterns)) continue;
      localFileSet.remove(remotePath);

      final localFile = File('$localDir/$remotePath');

      bool needsDownload = false;
      bool needsUpload = false;
      bool isNew = false;

      if (!localFile.existsSync()) {
        needsDownload = true;
        isNew = true;
      } else {
        final localBytes = localFile.readAsBytesSync();
        final localSha1 = sha1.convert(localBytes).toString();
        if (localSha1 != remoteSha1) {
          if (syncStyle == 'sendReceive') {
            // Bidirectional: compare mtime
            final localStat = localFile.statSync();
            final localMtime = localStat.modified.millisecondsSinceEpoch ~/ 1000;
            if (remoteMtime > localMtime) {
              needsDownload = true;
            } else if (localMtime > remoteMtime) {
              needsUpload = true;
            }
            // Equal mtime + different SHA1 = conflict, skip
          } else {
            needsDownload = true;
          }
        }
      }

      if (needsDownload) {
        final fileResp = await http.get(
          Uri.parse('$peerUrl/api/mirror/file?path=${Uri.encodeComponent(remotePath)}&token=${Uri.encodeComponent(token)}'),
        );
        if (fileResp.statusCode == 200) {
          final downloadedSha1 = sha1.convert(fileResp.bodyBytes).toString();
          if (downloadedSha1 != remoteSha1) {
            print('    WARNING: SHA1 mismatch for $remotePath');
            continue;
          }

          await localFile.parent.create(recursive: true);
          await localFile.writeAsBytes(fileResp.bodyBytes);
          bytesTransferred += remoteSize;

          if (isNew) {
            filesAdded++;
          } else {
            filesModified++;
          }
        }
      } else if (needsUpload) {
        final localBytes = localFile.readAsBytesSync();
        final localSha1Hash = sha1.convert(localBytes).toString();
        final uploadResp = await http.post(
          Uri.parse('$peerUrl/api/mirror/upload?path=${Uri.encodeComponent(remotePath)}&token=${Uri.encodeComponent(token)}&sha1=${Uri.encodeComponent(localSha1Hash)}'),
          headers: {'Content-Type': 'application/octet-stream'},
          body: localBytes,
        );
        if (uploadResp.statusCode == 200) {
          final uploadData = jsonDecode(uploadResp.body) as Map<String, dynamic>;
          if (uploadData['success'] == true) {
            filesUploaded++;
          }
        }
      }
    }

    // Local-only files: upload in sendReceive mode
    if (syncStyle == 'sendReceive') {
      for (final localPath in localFileSet) {
        final localFile = File('$localDir/$localPath');
        if (!localFile.existsSync()) continue;
        final localBytes = localFile.readAsBytesSync();
        final localSha1Hash = sha1.convert(localBytes).toString();
        final uploadResp = await http.post(
          Uri.parse('$peerUrl/api/mirror/upload?path=${Uri.encodeComponent(localPath)}&token=${Uri.encodeComponent(token)}&sha1=${Uri.encodeComponent(localSha1Hash)}'),
          headers: {'Content-Type': 'application/octet-stream'},
          body: localBytes,
        );
        if (uploadResp.statusCode == 200) {
          final uploadData = jsonDecode(uploadResp.body) as Map<String, dynamic>;
          if (uploadData['success'] == true) {
            filesUploaded++;
          }
        }
      }
    }

    stopwatch.stop();
    return SyncResult(
      true,
      filesAdded: filesAdded,
      filesModified: filesModified,
      filesUploaded: filesUploaded,
      bytesTransferred: bytesTransferred,
      duration: stopwatch.elapsed,
    );
  }

  bool _isIgnored(String path, List<String> patterns) {
    for (final pattern in patterns) {
      if (_matchesPattern(path, pattern)) return true;
    }
    return false;
  }

  bool _matchesPattern(String path, String pattern) {
    final buf = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final ch = pattern[i];
      if (ch == '*') {
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          buf.write('.*');
          i++;
          if (i + 1 < pattern.length && pattern[i + 1] == '/') i++;
        } else {
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
}

class SyncResult {
  final bool success;
  final String? error;
  final int filesAdded;
  final int filesModified;
  final int filesUploaded;
  final int bytesTransferred;
  final Duration duration;

  SyncResult(
    this.success, {
    this.error,
    this.filesAdded = 0,
    this.filesModified = 0,
    this.filesUploaded = 0,
    this.bytesTransferred = 0,
    this.duration = Duration.zero,
  });

  int get totalChanges => filesAdded + filesModified + filesUploaded;
}

// ─── Helpers ─────────────────────────────────────────────────────

String fileSha1(String path) {
  return sha1.convert(File(path).readAsBytesSync()).toString();
}

// ─── Main ────────────────────────────────────────────────────────

void main() async {
  print('');
  print('================================================================');
  print('  Mirror Sync Integration Test');
  print('================================================================');

  // ── Setup ──────────────────────────────────────────────────────

  final tmpDir = Directory.systemTemp.createTempSync('mirror-test-');
  final srcDir = Directory('${tmpDir.path}/source');
  final dstDir = Directory('${tmpDir.path}/dest');
  srcDir.createSync(recursive: true);
  dstDir.createSync(recursive: true);

  // Source callsign directory (simulates devices/X1SRC/ on the server)
  final srcCallsignDir = Directory('${srcDir.path}/devices/X1SRC');
  srcCallsignDir.createSync(recursive: true);

  print('\nSource dir: ${srcDir.path}');
  print('Source callsign dir: ${srcCallsignDir.path}');
  print('Dest dir:   ${dstDir.path}');

  // Create test files in source under the callsign directory
  Directory('${srcCallsignDir.path}/blog').createSync();
  File('${srcCallsignDir.path}/blog/post1.json')
      .writeAsStringSync('{"title":"First Post","body":"Hello world"}');
  File('${srcCallsignDir.path}/blog/post2.json')
      .writeAsStringSync('{"title":"Second Post","body":"Another entry"}');
  Directory('${srcCallsignDir.path}/blog/drafts').createSync();
  File('${srcCallsignDir.path}/blog/drafts/draft1.json')
      .writeAsStringSync('{"title":"Draft","body":"Work in progress"}');

  print('Created 3 test files in source/devices/X1SRC/blog/');

  // Generate a NOSTR key pair for the test client
  final keys = NostrCrypto.generateKeyPair();
  final npub = keys.npub;
  final nsec = keys.nsec;
  print('Client npub: ${npub.substring(0, 20)}...\n');

  // Create sync client
  final client = SyncClient(nsec: nsec, npub: npub, destDir: dstDir.path);

  // Start mock source server (pointing at the callsign dir, like the real server does)
  final server = MockSourceServer(srcCallsignDir.path);
  await server.start();
  server.allowedPeers[npub] = 'X1TEST';
  print('Source server on port ${server.port}, client registered as allowed peer\n');

  try {
    // ── Test 1: Initial sync ───────────────────────────────────

    section('TEST 1: Initial Sync (empty destination)');

    final result1 = await client.syncFolder(server.url, 'blog', peerCallsign: 'X1SRC');

    check('Sync succeeded', result1.success, result1.error);
    check('3 files added', result1.filesAdded == 3,
        'expected 3, got ${result1.filesAdded}');
    check('0 files modified', result1.filesModified == 0,
        'got ${result1.filesModified}');
    check('Bytes transferred > 0', result1.bytesTransferred > 0,
        'got ${result1.bytesTransferred}');
    print('  Duration: ${result1.duration.inMilliseconds}ms');

    // ── Test 2: Verify files on disk ───────────────────────────

    section('TEST 2: Verify Files on Disk (SHA1 integrity)');

    final dstBlog = '${dstDir.path}/devices/X1SRC/blog';

    check('post1.json exists', File('$dstBlog/post1.json').existsSync());
    check('post2.json exists', File('$dstBlog/post2.json').existsSync());
    check('drafts/ subdirectory exists', Directory('$dstBlog/drafts').existsSync());
    check('drafts/draft1.json exists', File('$dstBlog/drafts/draft1.json').existsSync());

    if (File('$dstBlog/post1.json').existsSync()) {
      check('post1.json SHA1 matches',
          fileSha1('${srcCallsignDir.path}/blog/post1.json') == fileSha1('$dstBlog/post1.json'));
    }
    if (File('$dstBlog/post2.json').existsSync()) {
      check('post2.json SHA1 matches',
          fileSha1('${srcCallsignDir.path}/blog/post2.json') == fileSha1('$dstBlog/post2.json'));
    }
    if (File('$dstBlog/drafts/draft1.json').existsSync()) {
      check('drafts/draft1.json SHA1 matches',
          fileSha1('${srcCallsignDir.path}/blog/drafts/draft1.json') == fileSha1('$dstBlog/drafts/draft1.json'));
    }

    // Verify actual content
    final c1 = File('$dstBlog/post1.json').readAsStringSync();
    check('post1.json content correct',
        c1.contains('First Post') && c1.contains('Hello world'), 'content: $c1');

    // ── Test 3: No-op sync ─────────────────────────────────────

    section('TEST 3: No-op Sync (no changes)');

    final result2 = await client.syncFolder(server.url, 'blog', peerCallsign: 'X1SRC');

    check('Sync succeeded', result2.success, result2.error);
    check('0 total changes', result2.totalChanges == 0,
        'got ${result2.totalChanges}');

    // ── Test 4: Update sync ────────────────────────────────────

    section('TEST 4: Update Sync (modify source file)');

    File('${srcCallsignDir.path}/blog/post1.json')
        .writeAsStringSync('{"title":"First Post UPDATED","body":"Modified content"}');

    final result3 = await client.syncFolder(server.url, 'blog', peerCallsign: 'X1SRC');

    check('Sync succeeded', result3.success, result3.error);
    check('1 file modified', result3.filesModified == 1, 'got ${result3.filesModified}');
    check('0 files added', result3.filesAdded == 0, 'got ${result3.filesAdded}');

    final updated = File('$dstBlog/post1.json').readAsStringSync();
    check('Dest has updated content', updated.contains('UPDATED'), 'content: $updated');
    check('Updated SHA1 matches',
        fileSha1('${srcCallsignDir.path}/blog/post1.json') == fileSha1('$dstBlog/post1.json'));

    // ── Test 5: New file sync ──────────────────────────────────

    section('TEST 5: New File Sync (add source file)');

    File('${srcCallsignDir.path}/blog/post3.json')
        .writeAsStringSync('{"title":"Third Post","body":"Brand new"}');

    final result4 = await client.syncFolder(server.url, 'blog', peerCallsign: 'X1SRC');

    check('Sync succeeded', result4.success, result4.error);
    check('1 file added', result4.filesAdded == 1, 'got ${result4.filesAdded}');
    check('post3.json exists on dest', File('$dstBlog/post3.json').existsSync());

    if (File('$dstBlog/post3.json').existsSync()) {
      check('post3.json content correct',
          File('$dstBlog/post3.json').readAsStringSync().contains('Third Post'));
    }

    // ── Test 6: One-way mirror ─────────────────────────────────

    section('TEST 6: One-Way Mirror (dest changes overwritten)');

    File('$dstBlog/post1.json')
        .writeAsStringSync('{"title":"LOCAL CHANGE","body":"Should be overwritten"}');

    final localHash = fileSha1('$dstBlog/post1.json');
    final sourceHash = fileSha1('${srcCallsignDir.path}/blog/post1.json');
    check('Local and source differ before sync', localHash != sourceHash);

    final result5 = await client.syncFolder(server.url, 'blog', peerCallsign: 'X1SRC');

    check('Sync succeeded', result5.success, result5.error);
    check('1 file modified (overwritten)', result5.filesModified == 1, 'got ${result5.filesModified}');
    check('Dest matches source again',
        fileSha1('$dstBlog/post1.json') == sourceHash);
    check('Local change was overwritten',
        !File('$dstBlog/post1.json').readAsStringSync().contains('LOCAL CHANGE'));

    // ── Test 7: Pair endpoint ──────────────────────────────────

    section('TEST 7: Pair Endpoint');

    final pairResp = await http.post(
      Uri.parse('${server.url}/api/mirror/pair'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'npub': npub,
        'callsign': 'X1TEST',
        'device_name': 'Test Client',
        'platform': 'linux',
        'apps': ['blog', 'chat'],
      }),
    );

    final pairBody = jsonDecode(pairResp.body) as Map<String, dynamic>;
    check('Pair returns 200', pairResp.statusCode == 200, 'got ${pairResp.statusCode}');
    check('Pair returns success', pairBody['success'] == true);
    check('Pair returns remote npub', pairBody['npub'] != null);
    check('Pair returns remote callsign', pairBody['callsign'] != null);
    check('Pair returns device_name', pairBody['device_name'] != null);
    check('Peer registered as allowed', server.allowedPeers.containsKey(npub));

    // ── Test 8: Unauthorized peer ──────────────────────────────

    section('TEST 8: Security — Unauthorized Peer');

    final rogueKeys = NostrCrypto.generateKeyPair();

    final chResp = await http.get(
      Uri.parse('${server.url}/api/mirror/challenge?folder=blog'),
    );
    final chData = jsonDecode(chResp.body) as Map<String, dynamic>;
    final rogueNonce = chData['nonce'] as String;

    final rogueEvent = NostrEvent(
      pubkey: rogueKeys.publicKeyHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.textNote,
      tags: [['t', 'mirror_response'], ['folder', 'blog'], ['nonce', rogueNonce]],
      content: 'mirror_response:$rogueNonce:blog',
    );
    rogueEvent.sign(rogueKeys.privateKeyHex);

    final rogueResp = await http.post(
      Uri.parse('${server.url}/api/mirror/request'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'event': rogueEvent.toJson(), 'folder': 'blog'}),
    );

    check('Unauthorized peer rejected (403)', rogueResp.statusCode == 403,
        'got ${rogueResp.statusCode}');
    final rogueBody = jsonDecode(rogueResp.body) as Map<String, dynamic>;
    check('Error is PEER_NOT_ALLOWED', rogueBody['code'] == 'PEER_NOT_ALLOWED',
        'got ${rogueBody['code']}');

    // ── Test 9: Replay attack ──────────────────────────────────

    section('TEST 9: Security — Replay Attack (nonce reuse)');

    final ch2Resp = await http.get(
      Uri.parse('${server.url}/api/mirror/challenge?folder=blog'),
    );
    final nonce2 = (jsonDecode(ch2Resp.body) as Map<String, dynamic>)['nonce'] as String;

    final privHex = NostrCrypto.decodeNsec(nsec);
    final pubHex = NostrCrypto.decodeNpub(npub);

    final validEvent = NostrEvent(
      pubkey: pubHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.textNote,
      tags: [['t', 'mirror_response'], ['folder', 'blog'], ['nonce', nonce2]],
      content: 'mirror_response:$nonce2:blog',
    );
    validEvent.sign(privHex);

    // First use succeeds
    final first = await http.post(
      Uri.parse('${server.url}/api/mirror/request'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'event': validEvent.toJson(), 'folder': 'blog'}),
    );
    final firstData = jsonDecode(first.body) as Map<String, dynamic>;
    check('First use succeeds', firstData['success'] == true, 'got $firstData');

    // Replay fails
    final replay = await http.post(
      Uri.parse('${server.url}/api/mirror/request'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'event': validEvent.toJson(), 'folder': 'blog'}),
    );
    check('Replay rejected (401)', replay.statusCode == 401, 'got ${replay.statusCode}');
    final replayData = jsonDecode(replay.body) as Map<String, dynamic>;
    check('Error is INVALID_CHALLENGE', replayData['code'] == 'INVALID_CHALLENGE',
        'got ${replayData['code']}');

    // ── Test 10: Invalid signature ─────────────────────────────

    section('TEST 10: Security — Invalid Signature');

    final ch3Resp = await http.get(
      Uri.parse('${server.url}/api/mirror/challenge?folder=blog'),
    );
    final nonce3 = (jsonDecode(ch3Resp.body) as Map<String, dynamic>)['nonce'] as String;

    final fakeResp = await http.post(
      Uri.parse('${server.url}/api/mirror/request'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'event': {
          'id': sha256.convert(utf8.encode('fake')).toString(),
          'kind': 1,
          'pubkey': pubHex,
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'content': 'mirror_response:$nonce3:blog',
          'tags': [['t', 'mirror_response'], ['folder', 'blog'], ['nonce', nonce3]],
          'sig': 'a' * 128,
        },
        'folder': 'blog',
      }),
    );
    check('Fake signature rejected (401)', fakeResp.statusCode == 401,
        'got ${fakeResp.statusCode}');

    // ── Test 11: Bidirectional — local newer wins ──────────────

    section('TEST 11: Bidirectional — Local Newer Wins (sendReceive)');

    // Modify dest file and set its mtime to the future
    final destPost1 = File('$dstBlog/post1.json');
    destPost1.writeAsStringSync('{"title":"DEST NEWER","body":"Local edit wins"}');
    // Touch the file to ensure it has a newer mtime than source
    final futureTime = DateTime.now().add(const Duration(seconds: 10));
    destPost1.setLastModifiedSync(futureTime);

    final result11 = await client.syncFolder(server.url, 'blog', peerCallsign: 'X1SRC', syncStyle: 'sendReceive');

    check('Sync succeeded', result11.success, result11.error);
    check('1 file uploaded (local newer)', result11.filesUploaded >= 1,
        'uploaded=${result11.filesUploaded}');
    // Source should now have dest's content
    final srcPost1Content = File('${srcCallsignDir.path}/blog/post1.json').readAsStringSync();
    check('Source received dest content', srcPost1Content.contains('DEST NEWER'),
        'source content: $srcPost1Content');

    // ── Test 12: Bidirectional — remote newer wins ─────────────

    section('TEST 12: Bidirectional — Remote Newer Wins (sendReceive)');

    // Modify source file and set its mtime to the future
    final srcPost2 = File('${srcCallsignDir.path}/blog/post2.json');
    srcPost2.writeAsStringSync('{"title":"SOURCE NEWER","body":"Remote edit wins"}');
    final futureTime2 = DateTime.now().add(const Duration(seconds: 20));
    srcPost2.setLastModifiedSync(futureTime2);
    // Ensure dest post2 has older mtime
    final destPost2 = File('$dstBlog/post2.json');
    final pastTime = DateTime.now().subtract(const Duration(seconds: 60));
    destPost2.setLastModifiedSync(pastTime);

    final result12 = await client.syncFolder(server.url, 'blog', peerCallsign: 'X1SRC', syncStyle: 'sendReceive');

    check('Sync succeeded', result12.success, result12.error);
    check('1 file modified (remote newer)', result12.filesModified >= 1,
        'modified=${result12.filesModified}');
    final destPost2Content = File('$dstBlog/post2.json').readAsStringSync();
    check('Dest received source content', destPost2Content.contains('SOURCE NEWER'),
        'dest content: $destPost2Content');

    // ── Test 13: Bidirectional — local-only file uploaded ──────

    section('TEST 13: Bidirectional — Local-Only File Uploaded');

    // Create a file only on dest
    File('$dstBlog/local_only.json')
        .writeAsStringSync('{"title":"Local Only","body":"Should appear on source"}');

    final result13 = await client.syncFolder(server.url, 'blog', peerCallsign: 'X1SRC', syncStyle: 'sendReceive');

    check('Sync succeeded', result13.success, result13.error);
    check('1 file uploaded (local-only)', result13.filesUploaded >= 1,
        'uploaded=${result13.filesUploaded}');
    check('Source has local_only.json',
        File('${srcCallsignDir.path}/blog/local_only.json').existsSync());
    if (File('${srcCallsignDir.path}/blog/local_only.json').existsSync()) {
      final srcContent = File('${srcCallsignDir.path}/blog/local_only.json').readAsStringSync();
      check('Source has correct content', srcContent.contains('Local Only'),
          'content: $srcContent');
    }

    // ── Test 14: Ignore patterns ──────────────────────────────

    section('TEST 14: Ignore Patterns');

    // Create files that should be ignored
    File('${srcCallsignDir.path}/blog/temp.tmp')
        .writeAsStringSync('temp file');
    Directory('${srcCallsignDir.path}/blog/cache').createSync();
    File('${srcCallsignDir.path}/blog/cache/data.bin')
        .writeAsStringSync('cached data');
    File('${srcCallsignDir.path}/blog/important.json')
        .writeAsStringSync('{"title":"Important","body":"Should sync"}');

    // Also create matching files on dest to test ignore on local scan
    File('$dstBlog/dest_temp.tmp')
        .writeAsStringSync('dest temp file');

    final result14 = await client.syncFolder(
      server.url,
      'blog',
      peerCallsign: 'X1SRC',
      syncStyle: 'sendReceive',
      ignorePatterns: ['*.tmp', 'cache/*'],
    );

    check('Sync succeeded', result14.success, result14.error);
    // important.json should be synced
    check('important.json synced', File('$dstBlog/important.json').existsSync());
    // temp.tmp should NOT be synced to dest
    check('temp.tmp not synced', !File('$dstBlog/temp.tmp').existsSync());
    // cache/data.bin should NOT be synced to dest
    check('cache/data.bin not synced', !File('$dstBlog/cache/data.bin').existsSync());
    // dest_temp.tmp should NOT be uploaded to source
    check('dest_temp.tmp not uploaded', !File('${srcCallsignDir.path}/blog/dest_temp.tmp').existsSync());

    // ── Test 15: Log folder always excluded ────────────────────

    section('TEST 15: Log Folder Always Excluded');

    // Create log files on both source and dest
    Directory('${srcCallsignDir.path}/blog/log').createSync();
    File('${srcCallsignDir.path}/blog/log/sync.log')
        .writeAsStringSync('source log entry');
    Directory('$dstBlog/log').createSync();
    File('$dstBlog/log/local.log')
        .writeAsStringSync('dest log entry');

    final result15 = await client.syncFolder(server.url, 'blog', peerCallsign: 'X1SRC', syncStyle: 'sendReceive');

    check('Sync succeeded', result15.success, result15.error);
    // Source log should NOT appear on dest (even though server manifest includes it)
    check('log/sync.log not synced to dest', !File('$dstBlog/log/sync.log').existsSync());
    // Dest log should NOT be uploaded to source
    check('log/local.log not uploaded to source', !File('${srcCallsignDir.path}/blog/log/local.log').existsSync());

    // ── Test 16: MirrorPeer address helpers ──────────────────

    section('TEST 16: MirrorPeer Address Helpers');

    // Simulate a peer with mixed addresses
    final testAddresses = [
      '192.168.1.50:3456',
      'station://station.example.com/device/X1SRC',
      '10.0.0.5:3456',
    ];

    // directAddress should return first non-station address
    String? directAddr;
    for (final a in testAddresses) {
      if (!a.startsWith('station://')) {
        directAddr = a;
        break;
      }
    }
    check('directAddress is first LAN IP', directAddr == '192.168.1.50:3456');

    // stationRelayUrl should return the station:// converted to https://
    String? relayUrl;
    for (final a in testAddresses) {
      if (a.startsWith('station://')) {
        relayUrl = a.replaceFirst('station://', 'https://');
        break;
      }
    }
    check('stationRelayUrl is HTTPS', relayUrl == 'https://station.example.com/device/X1SRC');

    // No station address
    final noStationAddresses = ['192.168.1.50:3456'];
    String? noRelay;
    for (final a in noStationAddresses) {
      if (a.startsWith('station://')) {
        noRelay = a.replaceFirst('station://', 'https://');
        break;
      }
    }
    check('No station → relay is null', noRelay == null);

    // Empty addresses
    final emptyAddresses = <String>[];
    String? emptyDirect;
    for (final a in emptyAddresses) {
      if (!a.startsWith('station://')) {
        emptyDirect = a;
        break;
      }
    }
    check('Empty addresses → direct is null', emptyDirect == null);

    // ── Test 17: Station relay URL format ──────────────────

    section('TEST 17: Station Relay URL Format');

    // Verify the relay URL derivation from WebSocket URL
    const wsUrl = 'wss://geo.example.com:8443';
    final wsUri = Uri.parse(wsUrl);
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    final stationBase = '$scheme://${wsUri.host}${wsUri.hasPort ? ':${wsUri.port}' : ''}';
    check('Station base from WSS', stationBase == 'https://geo.example.com:8443');

    const wsUrlPlain = 'ws://192.168.1.1:3456';
    final wsUriPlain = Uri.parse(wsUrlPlain);
    final schemePlain = wsUriPlain.scheme == 'wss' ? 'https' : 'http';
    final stationBasePlain = '$schemePlain://${wsUriPlain.host}${wsUriPlain.hasPort ? ':${wsUriPlain.port}' : ''}';
    check('Station base from WS', stationBasePlain == 'http://192.168.1.1:3456');

    final relayAddr = 'station://${wsUri.host}${wsUri.hasPort ? ':${wsUri.port}' : ''}/device/X1SRC';
    check('Relay address format', relayAddr == 'station://geo.example.com:8443/device/X1SRC');

  } finally {
    await server.stop();
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }

  // ── Summary ──────────────────────────────────────────────────

  print('\n');
  print('================================================================');
  if (_testsFailed == 0) {
    print('  ALL TESTS PASSED ($_testsPassed/$_testsRun)');
  } else {
    print('  $_testsPassed PASSED, $_testsFailed FAILED (of $_testsRun)');
    print('  Failed:');
    for (final t in _failedTests) {
      print('    - $t');
    }
  }
  print('================================================================');
  print('');

  exit(_testsFailed > 0 ? 1 : 0);
}
