#!/usr/bin/env dart
/// P2P File Transfer Test Suite (Standalone)
///
/// Tests the complete P2P file transfer workflow without Flutter dependencies:
/// - Offer model creation and serialization
/// - Message protocol validation
/// - File transfer simulation with SHA1 verification
/// - HTTP API simulation
/// - Complete workflow from offer to verified files
///
/// Run with: dart tests/server/p2p_transfer_test.dart
///
/// This test creates temporary files, simulates the transfer workflow,
/// and verifies files are correctly transferred to the destination.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

// Test configuration
const int TEST_PORT = 45800;
const String BASE_URL = 'http://localhost:$TEST_PORT';

// Test results tracking
int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

// Temp directories
late Directory _tempDir;
late Directory _sourceDir;
late Directory _destDir;

// Test files content
final Map<String, String> _testFiles = {
  'file1.txt': 'Hello, this is test file 1 content.',
  'file2.txt': 'Second file with different content here.',
  'subdir/nested.txt': 'This file is in a subdirectory.',
  'subdir/deep/file.txt': 'Deeply nested file content.',
};

// Simulated P2P state
final Map<String, _TestOffer> _activeOffers = {};
final Map<String, String> _serveTokens = {};

// ============================================================
// Simplified Models (mirror the actual implementation)
// ============================================================

enum TransferOfferStatus {
  pending,
  accepted,
  rejected,
  expired,
  cancelled,
  transferring,
  completed,
  failed,
}

class TransferOfferFile {
  final String path;
  final String name;
  final int size;
  final String? sha1;

  TransferOfferFile({
    required this.path,
    required this.name,
    required this.size,
    this.sha1,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'size': size,
    if (sha1 != null) 'sha1': sha1,
  };

  factory TransferOfferFile.fromJson(Map<String, dynamic> json) {
    return TransferOfferFile(
      path: json['path'] as String,
      name: json['name'] as String,
      size: json['size'] as int,
      sha1: json['sha1'] as String?,
    );
  }
}

class _TestOffer {
  final String offerId;
  final String senderCallsign;
  String? receiverCallsign;
  final DateTime createdAt;
  final DateTime expiresAt;
  final List<TransferOfferFile> files;
  final int totalBytes;
  TransferOfferStatus status;
  String? serveToken;
  Map<String, String> filePaths = {};

  _TestOffer({
    required this.offerId,
    required this.senderCallsign,
    this.receiverCallsign,
    required this.createdAt,
    required this.expiresAt,
    required this.files,
    required this.totalBytes,
    this.status = TransferOfferStatus.pending,
    this.serveToken,
  });

  int get totalFiles => files.length;
  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get isActionable => status == TransferOfferStatus.pending && !isExpired;

  static String generateOfferId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random.secure().nextInt(10000);
    return 'tr_${timestamp.toRadixString(36)}$random';
  }

  Map<String, dynamic> toManifest() => {
    'offerId': offerId,
    'totalFiles': totalFiles,
    'totalBytes': totalBytes,
    'files': files.map((f) => f.toJson()).toList(),
  };

  Map<String, dynamic> toOfferMessage() => {
    'type': 'transfer_offer',
    'offerId': offerId,
    'senderCallsign': senderCallsign,
    'timestamp': createdAt.millisecondsSinceEpoch ~/ 1000,
    'expiresAt': expiresAt.millisecondsSinceEpoch ~/ 1000,
    'manifest': toManifest(),
  };

  factory _TestOffer.fromOfferMessage(Map<String, dynamic> json) {
    final manifest = json['manifest'] as Map<String, dynamic>;
    final files = (manifest['files'] as List)
        .map((f) => TransferOfferFile.fromJson(f as Map<String, dynamic>))
        .toList();

    return _TestOffer(
      offerId: json['offerId'] as String,
      senderCallsign: json['senderCallsign'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['timestamp'] as int) * 1000,
      ),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (json['expiresAt'] as int) * 1000,
      ),
      files: files,
      totalBytes: manifest['totalBytes'] as int,
    );
  }

  static Map<String, dynamic> createResponse({
    required String offerId,
    required bool accepted,
    required String receiverCallsign,
  }) => {
    'type': 'transfer_response',
    'offerId': offerId,
    'accepted': accepted,
    'receiverCallsign': receiverCallsign,
  };

  static Map<String, dynamic> createProgressMessage({
    required String offerId,
    required int bytesReceived,
    required int totalBytes,
    required int filesCompleted,
    String? currentFile,
  }) => {
    'type': 'transfer_progress',
    'offerId': offerId,
    'bytesReceived': bytesReceived,
    'totalBytes': totalBytes,
    'filesCompleted': filesCompleted,
    if (currentFile != null) 'currentFile': currentFile,
  };

  static Map<String, dynamic> createCompleteMessage({
    required String offerId,
    required bool success,
    required int bytesReceived,
    required int filesReceived,
    String? error,
  }) => {
    'type': 'transfer_complete',
    'offerId': offerId,
    'success': success,
    'bytesReceived': bytesReceived,
    'filesReceived': filesReceived,
    if (error != null) 'error': error,
  };
}

// ============================================================
// Test Utilities
// ============================================================

void pass(String test) {
  _passed++;
  print('  [PASS] $test');
}

void fail(String test, String reason) {
  _failed++;
  _failures.add('$test: $reason');
  print('  [FAIL] $test - $reason');
}

String generateToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

String getContentType(String path) {
  final ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'txt': return 'text/plain';
    case 'json': return 'application/json';
    case 'bin': return 'application/octet-stream';
    default: return 'application/octet-stream';
  }
}

// ============================================================
// Test Server
// ============================================================

HttpServer? _testServer;

Future<void> startTestServer() async {
  final handler = const shelf.Pipeline()
      .addHandler(_handleRequest);

  _testServer = await shelf_io.serve(handler, 'localhost', TEST_PORT);
  print('  Test server running on port $TEST_PORT');
}

Future<void> stopTestServer() async {
  await _testServer?.close(force: true);
  _testServer = null;
}

Future<shelf.Response> _handleRequest(shelf.Request request) async {
  final path = request.url.path;

  // GET /api/p2p/offer/{offerId}/manifest
  final manifestMatch = RegExp(r'^api/p2p/offer/([^/]+)/manifest$').firstMatch(path);
  if (manifestMatch != null && request.method == 'GET') {
    final offerId = manifestMatch.group(1)!;
    final offer = _activeOffers[offerId];

    if (offer == null) {
      return shelf.Response.notFound(
        jsonEncode({
          'success': false,
          'error': 'Offer not found or expired',
          'code': 'OFFER_NOT_FOUND',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    return shelf.Response.ok(
      jsonEncode({
        ...offer.toManifest(),
        'token': offer.serveToken,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  // GET /api/p2p/offer/{offerId}/file
  final fileMatch = RegExp(r'^api/p2p/offer/([^/]+)/file$').firstMatch(path);
  if (fileMatch != null && request.method == 'GET') {
    final offerId = fileMatch.group(1)!;
    final filePath = request.url.queryParameters['path'];
    final token = request.url.queryParameters['token'];

    if (token == null || token.isEmpty) {
      return shelf.Response(401,
        body: jsonEncode({
          'success': false,
          'error': 'Missing token',
          'code': 'INVALID_TOKEN',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    if (filePath == null || filePath.isEmpty) {
      return shelf.Response.badRequest(
        body: jsonEncode({
          'success': false,
          'error': 'Missing path parameter',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    // Validate token
    final tokenOfferId = _serveTokens[token];
    if (tokenOfferId == null || tokenOfferId != offerId) {
      return shelf.Response(401,
        body: jsonEncode({
          'success': false,
          'error': 'Invalid or expired token',
          'code': 'INVALID_TOKEN',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final offer = _activeOffers[offerId];
    if (offer == null) {
      return shelf.Response.notFound(
        jsonEncode({
          'success': false,
          'error': 'Offer not found',
          'code': 'OFFER_NOT_FOUND',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final actualPath = offer.filePaths[filePath];
    if (actualPath == null) {
      return shelf.Response.notFound(
        jsonEncode({
          'success': false,
          'error': 'File not found in offer',
          'code': 'FILE_NOT_FOUND',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final file = File(actualPath);
    if (!await file.exists()) {
      return shelf.Response.notFound(
        jsonEncode({
          'success': false,
          'error': 'File not found on disk',
          'code': 'FILE_NOT_FOUND',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final bytes = await file.readAsBytes();
    final sha1Hash = sha1.convert(bytes).toString();
    final contentType = getContentType(filePath);

    // Handle Range requests
    final rangeHeader = request.headers['range'];
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final rangeSpec = rangeHeader.substring(6);
      final parts = rangeSpec.split('-');
      final start = int.tryParse(parts[0]) ?? 0;
      final end = parts.length > 1 && parts[1].isNotEmpty
          ? int.tryParse(parts[1]) ?? bytes.length - 1
          : bytes.length - 1;

      if (start >= bytes.length || start > end) {
        return shelf.Response(416,
          body: jsonEncode({
            'success': false,
            'error': 'Range not satisfiable',
            'code': 'RANGE_NOT_SATISFIABLE',
          }),
          headers: {'Content-Range': 'bytes */${bytes.length}'},
        );
      }

      final rangeBytes = bytes.sublist(start, end + 1);
      return shelf.Response(206,
        body: rangeBytes,
        headers: {
          'Content-Type': contentType,
          'Content-Length': rangeBytes.length.toString(),
          'Content-Range': 'bytes $start-$end/${bytes.length}',
          'X-SHA1': sha1Hash,
        },
      );
    }

    return shelf.Response.ok(
      bytes,
      headers: {
        'Content-Type': contentType,
        'Content-Length': bytes.length.toString(),
        'X-SHA1': sha1Hash,
      },
    );
  }

  return shelf.Response.notFound('Not found');
}

// ============================================================
// Main
// ============================================================

Future<void> main() async {
  print('');
  print('=' * 70);
  print('P2P File Transfer Test Suite');
  print('=' * 70);
  print('');

  try {
    await setup();

    // Run test suites
    print('\n${'=' * 70}');
    print('MODEL TESTS');
    print('${'=' * 70}\n');

    await testTransferOfferModel();
    await testTransferOfferFileModel();
    await testOfferIdGeneration();
    await testOfferExpiry();
    await testMessageSerialization();

    print('\n${'=' * 70}');
    print('API ENDPOINT TESTS');
    print('${'=' * 70}\n');

    await testManifestEndpoint();
    await testManifestNotFound();
    await testFileEndpointNoToken();
    await testFileEndpointInvalidToken();
    await testFileEndpointMissingPath();
    await testFileDownload();
    await testFileDownloadWithRange();

    print('\n${'=' * 70}');
    print('FULL WORKFLOW TEST');
    print('${'=' * 70}\n');

    await testFullTransferWorkflow();

  } catch (e, stack) {
    print('\n[ERROR] Test suite failed: $e');
    print(stack);
    _failed++;
  } finally {
    await cleanup();
  }

  // Print summary
  print('\n');
  print('=' * 70);
  print('TEST SUMMARY');
  print('=' * 70);
  print('');
  print('  Passed: $_passed');
  print('  Failed: $_failed');
  print('');

  if (_failures.isNotEmpty) {
    print('Failed tests:');
    for (final failure in _failures) {
      print('  - $failure');
    }
  }

  print('');
  exit(_failed > 0 ? 1 : 0);
}

Future<void> setup() async {
  print('Setting up test environment...');

  // Create temp directories
  _tempDir = await Directory.systemTemp.createTemp('p2p_transfer_test_');
  _sourceDir = Directory('${_tempDir.path}/source');
  _destDir = Directory('${_tempDir.path}/dest');

  await _sourceDir.create(recursive: true);
  await _destDir.create(recursive: true);

  print('  Temp directory: ${_tempDir.path}');
  print('  Source: ${_sourceDir.path}');
  print('  Destination: ${_destDir.path}');

  // Create test files
  for (final entry in _testFiles.entries) {
    final file = File('${_sourceDir.path}/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
  }
  print('  Created ${_testFiles.length} test files');

  // Start test server
  await startTestServer();

  print('Setup complete.\n');
}

Future<void> cleanup() async {
  print('\nCleaning up...');

  await stopTestServer();
  print('  Test server stopped');

  try {
    if (await _tempDir.exists()) {
      await _tempDir.delete(recursive: true);
      print('  Temp directory deleted');
    }
  } catch (e) {
    print('  Warning: Could not delete temp dir: $e');
  }

  _activeOffers.clear();
  _serveTokens.clear();
}

// ============================================================
// Model Tests
// ============================================================

Future<void> testTransferOfferModel() async {
  final offer = _TestOffer(
    offerId: 'tr_test123',
    senderCallsign: 'X1ALICE',
    receiverCallsign: 'X1BOB',
    createdAt: DateTime.now(),
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    files: [
      TransferOfferFile(path: 'test.txt', name: 'test.txt', size: 100, sha1: 'abc'),
    ],
    totalBytes: 100,
  );

  if (offer.offerId != 'tr_test123') {
    fail('TransferOffer model', 'offerId mismatch');
    return;
  }

  if (offer.totalFiles != 1) {
    fail('TransferOffer model', 'totalFiles should be 1');
    return;
  }

  if (offer.isExpired) {
    fail('TransferOffer model', 'should not be expired');
    return;
  }

  if (!offer.isActionable) {
    fail('TransferOffer model', 'should be actionable');
    return;
  }

  pass('TransferOffer model creation and properties');
}

Future<void> testTransferOfferFileModel() async {
  final file = TransferOfferFile(
    path: 'subdir/file.txt',
    name: 'file.txt',
    size: 1024,
    sha1: 'abcdef123456',
  );

  final json = file.toJson();

  if (json['path'] != 'subdir/file.txt') {
    fail('TransferOfferFile model', 'path mismatch in JSON');
    return;
  }

  if (json['size'] != 1024) {
    fail('TransferOfferFile model', 'size mismatch in JSON');
    return;
  }

  final restored = TransferOfferFile.fromJson(json);

  if (restored.path != file.path || restored.size != file.size) {
    fail('TransferOfferFile model', 'JSON round-trip failed');
    return;
  }

  pass('TransferOfferFile model and JSON serialization');
}

Future<void> testOfferIdGeneration() async {
  final id1 = _TestOffer.generateOfferId();
  await Future.delayed(const Duration(milliseconds: 5));
  final id2 = _TestOffer.generateOfferId();

  if (!id1.startsWith('tr_')) {
    fail('Offer ID generation', 'ID should start with tr_');
    return;
  }

  if (id1 == id2) {
    fail('Offer ID generation', 'IDs should be unique');
    return;
  }

  pass('Offer ID generation produces unique IDs');
}

Future<void> testOfferExpiry() async {
  // Create expired offer
  final expiredOffer = _TestOffer(
    offerId: 'tr_expired',
    senderCallsign: 'X1TEST',
    createdAt: DateTime.now().subtract(const Duration(hours: 2)),
    expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
    files: [],
    totalBytes: 0,
  );

  if (!expiredOffer.isExpired) {
    fail('Offer expiry', 'should be expired');
    return;
  }

  if (expiredOffer.isActionable) {
    fail('Offer expiry', 'expired offer should not be actionable');
    return;
  }

  // Create valid offer
  final validOffer = _TestOffer(
    offerId: 'tr_valid',
    senderCallsign: 'X1TEST',
    createdAt: DateTime.now(),
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    files: [],
    totalBytes: 0,
  );

  if (validOffer.isExpired) {
    fail('Offer expiry', 'should not be expired');
    return;
  }

  pass('Offer expiry detection works correctly');
}

Future<void> testMessageSerialization() async {
  // Test offer message
  final offer = _TestOffer(
    offerId: 'tr_msg_test',
    senderCallsign: 'X1ALICE',
    createdAt: DateTime.now(),
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    files: [
      TransferOfferFile(path: 'test.txt', name: 'test.txt', size: 100, sha1: 'abc'),
    ],
    totalBytes: 100,
  );

  final offerMsg = offer.toOfferMessage();
  if (offerMsg['type'] != 'transfer_offer') {
    fail('Message serialization', 'offer type mismatch');
    return;
  }

  // Test response message
  final response = _TestOffer.createResponse(
    offerId: 'tr_msg_test',
    accepted: true,
    receiverCallsign: 'X1BOB',
  );
  if (response['type'] != 'transfer_response') {
    fail('Message serialization', 'response type mismatch');
    return;
  }

  // Test progress message
  final progress = _TestOffer.createProgressMessage(
    offerId: 'tr_msg_test',
    bytesReceived: 50,
    totalBytes: 100,
    filesCompleted: 0,
    currentFile: 'test.txt',
  );
  if (progress['type'] != 'transfer_progress') {
    fail('Message serialization', 'progress type mismatch');
    return;
  }

  // Test complete message
  final complete = _TestOffer.createCompleteMessage(
    offerId: 'tr_msg_test',
    success: true,
    bytesReceived: 100,
    filesReceived: 1,
  );
  if (complete['type'] != 'transfer_complete') {
    fail('Message serialization', 'complete type mismatch');
    return;
  }

  pass('All message types serialize correctly');
}

// ============================================================
// API Endpoint Tests
// ============================================================

Future<void> testManifestEndpoint() async {
  // Create and register an offer
  final offerId = 'tr_manifest_${DateTime.now().millisecondsSinceEpoch}';
  final token = generateToken();

  final files = <TransferOfferFile>[];
  int totalBytes = 0;

  for (final entry in _testFiles.entries) {
    final file = File('${_sourceDir.path}/${entry.key}');
    final bytes = await file.readAsBytes();
    final sha1Hash = sha1.convert(bytes).toString();
    files.add(TransferOfferFile(
      path: entry.key,
      name: entry.key.split('/').last,
      size: bytes.length,
      sha1: sha1Hash,
    ));
    totalBytes += bytes.length;
  }

  final offer = _TestOffer(
    offerId: offerId,
    senderCallsign: 'X1TEST',
    createdAt: DateTime.now(),
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    files: files,
    totalBytes: totalBytes,
    serveToken: token,
  );

  // Register file paths
  for (final entry in _testFiles.entries) {
    offer.filePaths[entry.key] = '${_sourceDir.path}/${entry.key}';
  }

  _activeOffers[offerId] = offer;
  _serveTokens[token] = offerId;

  // Test manifest endpoint
  final response = await http.get(
    Uri.parse('$BASE_URL/api/p2p/offer/$offerId/manifest'),
  );

  if (response.statusCode != 200) {
    fail('Manifest endpoint', 'expected 200, got ${response.statusCode}');
    return;
  }

  final body = jsonDecode(response.body) as Map<String, dynamic>;

  if (body['offerId'] != offerId) {
    fail('Manifest endpoint', 'offerId mismatch');
    return;
  }

  if (body['token'] != token) {
    fail('Manifest endpoint', 'token not included');
    return;
  }

  if (body['totalFiles'] != files.length) {
    fail('Manifest endpoint', 'totalFiles mismatch');
    return;
  }

  pass('Manifest endpoint returns correct data');
}

Future<void> testManifestNotFound() async {
  final response = await http.get(
    Uri.parse('$BASE_URL/api/p2p/offer/nonexistent_offer/manifest'),
  );

  if (response.statusCode != 404) {
    fail('Manifest not found', 'expected 404, got ${response.statusCode}');
    return;
  }

  final body = jsonDecode(response.body);
  if (body['code'] != 'OFFER_NOT_FOUND') {
    fail('Manifest not found', 'expected OFFER_NOT_FOUND code');
    return;
  }

  pass('Manifest endpoint returns 404 for unknown offer');
}

Future<void> testFileEndpointNoToken() async {
  final response = await http.get(
    Uri.parse('$BASE_URL/api/p2p/offer/test/file?path=test.txt'),
  );

  if (response.statusCode != 401) {
    fail('File endpoint no token', 'expected 401, got ${response.statusCode}');
    return;
  }

  pass('File endpoint requires token');
}

Future<void> testFileEndpointInvalidToken() async {
  final response = await http.get(
    Uri.parse('$BASE_URL/api/p2p/offer/test/file?path=test.txt&token=invalid'),
  );

  if (response.statusCode != 401) {
    fail('File endpoint invalid token', 'expected 401, got ${response.statusCode}');
    return;
  }

  pass('File endpoint rejects invalid token');
}

Future<void> testFileEndpointMissingPath() async {
  final response = await http.get(
    Uri.parse('$BASE_URL/api/p2p/offer/test/file?token=test'),
  );

  if (response.statusCode != 400) {
    fail('File endpoint missing path', 'expected 400, got ${response.statusCode}');
    return;
  }

  pass('File endpoint requires path parameter');
}

Future<void> testFileDownload() async {
  // Use the offer created in testManifestEndpoint
  final offer = _activeOffers.values.first;
  final token = offer.serveToken!;
  final offerId = offer.offerId;

  // Download first file
  final filePath = _testFiles.keys.first;
  final response = await http.get(
    Uri.parse('$BASE_URL/api/p2p/offer/$offerId/file?path=$filePath&token=$token'),
  );

  if (response.statusCode != 200) {
    fail('File download', 'expected 200, got ${response.statusCode}');
    return;
  }

  // Verify SHA1 header
  final sha1Header = response.headers['x-sha1'];
  if (sha1Header == null) {
    fail('File download', 'missing X-SHA1 header');
    return;
  }

  // Verify content
  final expectedContent = _testFiles[filePath]!;
  if (response.body != expectedContent) {
    fail('File download', 'content mismatch');
    return;
  }

  // Verify SHA1
  final actualSha1 = sha1.convert(response.bodyBytes).toString();
  if (actualSha1 != sha1Header) {
    fail('File download', 'SHA1 verification failed');
    return;
  }

  pass('File download works with SHA1 verification');
}

Future<void> testFileDownloadWithRange() async {
  final offer = _activeOffers.values.first;
  final token = offer.serveToken!;
  final offerId = offer.offerId;
  final filePath = _testFiles.keys.first;

  // Request first 10 bytes
  final response = await http.get(
    Uri.parse('$BASE_URL/api/p2p/offer/$offerId/file?path=$filePath&token=$token'),
    headers: {'Range': 'bytes=0-9'},
  );

  if (response.statusCode != 206) {
    fail('File download with Range', 'expected 206, got ${response.statusCode}');
    return;
  }

  if (response.bodyBytes.length != 10) {
    fail('File download with Range', 'expected 10 bytes, got ${response.bodyBytes.length}');
    return;
  }

  final contentRange = response.headers['content-range'];
  if (contentRange == null || !contentRange.startsWith('bytes 0-9/')) {
    fail('File download with Range', 'invalid Content-Range header: $contentRange');
    return;
  }

  pass('File download with Range header works');
}

// ============================================================
// Full Workflow Test
// ============================================================

Future<void> testFullTransferWorkflow() async {
  print('  Testing complete transfer workflow...');

  // Clear previous offers
  _activeOffers.clear();
  _serveTokens.clear();

  // Step 1: Sender creates offer
  print('    Step 1: Creating offer...');
  final files = <TransferOfferFile>[];
  int totalBytes = 0;

  for (final entry in _testFiles.entries) {
    final file = File('${_sourceDir.path}/${entry.key}');
    final bytes = await file.readAsBytes();
    final sha1Hash = sha1.convert(bytes).toString();
    files.add(TransferOfferFile(
      path: entry.key,
      name: entry.key.split('/').last,
      size: bytes.length,
      sha1: sha1Hash,
    ));
    totalBytes += bytes.length;
  }

  final offerId = _TestOffer.generateOfferId();
  final serveToken = generateToken();

  final offer = _TestOffer(
    offerId: offerId,
    senderCallsign: 'X1SENDER',
    receiverCallsign: 'X1RECEIVER',
    createdAt: DateTime.now(),
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    files: files,
    totalBytes: totalBytes,
    serveToken: serveToken,
  );

  for (final entry in _testFiles.entries) {
    offer.filePaths[entry.key] = '${_sourceDir.path}/${entry.key}';
  }

  _activeOffers[offerId] = offer;
  _serveTokens[serveToken] = offerId;

  print('      Offer ID: $offerId');
  print('      Files: ${files.length}');
  print('      Total bytes: $totalBytes');

  // Step 2: Sender creates offer message
  print('    Step 2: Serializing offer message...');
  final offerMessage = offer.toOfferMessage();

  if (offerMessage['type'] != 'transfer_offer') {
    fail('Workflow', 'invalid offer message type');
    return;
  }

  // Step 3: Receiver parses offer
  print('    Step 3: Receiver parsing offer...');
  final receivedOffer = _TestOffer.fromOfferMessage(offerMessage);

  if (receivedOffer.offerId != offerId) {
    fail('Workflow', 'offer ID mismatch after parsing');
    return;
  }

  // Step 4: Receiver accepts
  print('    Step 4: Receiver accepting...');
  final response = _TestOffer.createResponse(
    offerId: offerId,
    accepted: true,
    receiverCallsign: 'X1RECEIVER',
  );

  if (!response['accepted']) {
    fail('Workflow', 'response should be accepted');
    return;
  }

  offer.status = TransferOfferStatus.accepted;

  // Step 5: Receiver fetches manifest
  print('    Step 5: Fetching manifest...');
  final manifestResponse = await http.get(
    Uri.parse('$BASE_URL/api/p2p/offer/$offerId/manifest'),
  );

  if (manifestResponse.statusCode != 200) {
    fail('Workflow', 'failed to fetch manifest');
    return;
  }

  final manifestData = jsonDecode(manifestResponse.body);
  final downloadToken = manifestData['token'] as String;

  // Step 6: Receiver downloads files
  print('    Step 6: Downloading files...');
  int bytesReceived = 0;
  int filesReceived = 0;

  for (final fileInfo in files) {
    // Download file
    final fileResponse = await http.get(
      Uri.parse(
        '$BASE_URL/api/p2p/offer/$offerId/file'
        '?path=${Uri.encodeComponent(fileInfo.path)}&token=$downloadToken',
      ),
    );

    if (fileResponse.statusCode != 200) {
      fail('Workflow', 'failed to download ${fileInfo.path}');
      return;
    }

    // Verify SHA1
    final sha1Header = fileResponse.headers['x-sha1'];
    if (sha1Header != fileInfo.sha1) {
      fail('Workflow', 'SHA1 mismatch for ${fileInfo.path}');
      return;
    }

    // Save to destination
    final destFile = File('${_destDir.path}/${fileInfo.path}');
    await destFile.parent.create(recursive: true);
    await destFile.writeAsBytes(fileResponse.bodyBytes);

    bytesReceived += fileResponse.bodyBytes.length;
    filesReceived++;

    // Simulate progress update
    final progress = _TestOffer.createProgressMessage(
      offerId: offerId,
      bytesReceived: bytesReceived,
      totalBytes: totalBytes,
      filesCompleted: filesReceived,
      currentFile: fileInfo.path,
    );

    if (progress['bytesReceived'] != bytesReceived) {
      fail('Workflow', 'progress message bytesReceived mismatch');
      return;
    }
  }

  print('      Downloaded: $filesReceived files, $bytesReceived bytes');

  // Step 7: Verify all files
  print('    Step 7: Verifying transferred files...');
  for (final fileInfo in files) {
    final destFile = File('${_destDir.path}/${fileInfo.path}');

    if (!await destFile.exists()) {
      fail('Workflow', 'file not found at destination: ${fileInfo.path}');
      return;
    }

    final destBytes = await destFile.readAsBytes();
    final destSha1 = sha1.convert(destBytes).toString();

    if (destSha1 != fileInfo.sha1) {
      fail('Workflow', 'SHA1 verification failed for ${fileInfo.path}');
      return;
    }

    if (destBytes.length != fileInfo.size) {
      fail('Workflow', 'size mismatch for ${fileInfo.path}');
      return;
    }
  }

  print('      All ${files.length} files verified');

  // Step 8: Completion
  print('    Step 8: Sending completion...');
  final complete = _TestOffer.createCompleteMessage(
    offerId: offerId,
    success: true,
    bytesReceived: bytesReceived,
    filesReceived: filesReceived,
  );

  if (!complete['success']) {
    fail('Workflow', 'completion should indicate success');
    return;
  }

  offer.status = TransferOfferStatus.completed;

  pass('Complete P2P transfer workflow with file verification');
}
