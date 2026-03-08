#!/usr/bin/env dart
/// Update API Test
///
/// Tests that clients can detect and download updates from a station.
/// Simulates the p2p.radio update mirror functionality.
///
/// Run with: dart tests/server/update_api_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../lib/station.dart';
import '../../lib/cli/pure_storage_config.dart';

const int TEST_PORT = 45703;
const String BASE_URL = 'http://localhost:$TEST_PORT';

// Test version info
const String MOCK_VERSION = '2.0.0';
const String MOCK_TAG_NAME = 'v2.0.0';
const String CURRENT_VERSION = '1.10.7';

// Test results tracking
int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

void pass(String test) {
  _passed++;
  print('  [PASS] $test');
}

void fail(String test, String reason) {
  _failed++;
  _failures.add('$test: $reason');
  print('  [FAIL] $test - $reason');
}

Future<void> main() async {
  print('');
  print('=' * 60);
  print('Update API Test (p2p.radio simulation)');
  print('=' * 60);
  print('');

  // Create temp directory
  final tempDir = await Directory.systemTemp.createTemp('geogram_update_test_');
  print('Using temp directory: ${tempDir.path}');
  print('Server port: $TEST_PORT');
  print('');

  late StationServer station;
  late String updatesDir;

  try {
    // Initialize storage config
    PureStorageConfig().reset();
    await PureStorageConfig().init(customBaseDir: tempDir.path);

    // Determine updates directory and create mock data BEFORE server starts
    // This ensures the server loads our mock release.json on startup
    // The server uses: _updatesDirectory = '$_dataDir/updates' where _dataDir = baseDir
    updatesDir = '${tempDir.path}/updates';
    await Directory(updatesDir).create(recursive: true);

    // Set up mock update data before server initialization
    await setupMockUpdates(updatesDir);

    // Create and configure server
    station = StationServer();
    station.quietMode = true;
    await station.initialize();
    station.setSetting('httpPort', TEST_PORT);

    print('Station callsign: ${station.settings.callsign}');
    print('Updates directory: $updatesDir');

    // Start server (will load cached release.json we created)
    print('Starting server...');
    final started = await station.start();
    if (!started) {
      print('ERROR: Failed to start station server');
      exit(1);
    }
    await Future.delayed(const Duration(milliseconds: 500));
    print('Server started successfully');
    print('');

    // Run tests
    await testUpdatesLatestEndpoint();
    await testUpdatesLatestNoCache();
    await testUpdateDownload(updatesDir);
    await testUpdateDownloadNotFound();
    await testUpdateDownloadInvalidPath();
    await testVersionComparison();
    await testUpdateHeaders();
    await testLargeFileDownload(updatesDir);

    // Cleanup
    print('');
    print('Stopping server...');
    await station.stop();
  } catch (e, stackTrace) {
    print('ERROR: $e');
    print(stackTrace);
    exit(1);
  } finally {
    // Cleanup temp directory
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }

  // Print summary
  print('');
  print('=' * 60);
  print('Test Summary');
  print('=' * 60);
  print('');
  print('Passed: $_passed');
  print('Failed: $_failed');
  print('Total:  ${_passed + _failed}');
  print('');

  if (_failures.isNotEmpty) {
    print('Failures:');
    for (final f in _failures) {
      print('  - $f');
    }
    print('');
  }

  exit(_failed > 0 ? 1 : 0);
}

/// Set up mock update data in the updates directory
Future<void> setupMockUpdates(String updatesDir) async {
  print('Setting up mock update data...');

  // Create version subdirectory
  final versionDir = Directory('$updatesDir/$MOCK_VERSION');
  await versionDir.create(recursive: true);

  // Create mock release.json
  final releaseJson = {
    'status': 'available',
    'version': MOCK_VERSION,
    'tagName': MOCK_TAG_NAME,
    'name': 'Geogram $MOCK_VERSION',
    'body': 'Test release with new features:\n- Feature A\n- Bug fix B',
    'publishedAt': '2025-01-20T12:00:00Z',
    'htmlUrl': 'https://github.com/geograms/geogram/releases/tag/$MOCK_TAG_NAME',
    'assets': {
      'androidApk': '/updates/$MOCK_VERSION/geogram-$MOCK_VERSION.apk',
      'linuxDesktop': '/updates/$MOCK_VERSION/geogram-$MOCK_VERSION-linux.tar.gz',
      'windowsDesktop': '/updates/$MOCK_VERSION/geogram-$MOCK_VERSION-windows.zip',
    },
    'assetFilenames': {
      'androidApk': 'geogram-$MOCK_VERSION.apk',
      'linuxDesktop': 'geogram-$MOCK_VERSION-linux.tar.gz',
      'windowsDesktop': 'geogram-$MOCK_VERSION-windows.zip',
    },
  };

  await File('$updatesDir/release.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert(releaseJson),
  );

  // Create mock APK file (small test file)
  final apkContent = List<int>.generate(1024, (i) => i % 256);
  await File('${versionDir.path}/geogram-$MOCK_VERSION.apk').writeAsBytes(apkContent);

  // Create mock Linux tarball
  final linuxContent = List<int>.generate(2048, (i) => (i * 2) % 256);
  await File('${versionDir.path}/geogram-$MOCK_VERSION-linux.tar.gz').writeAsBytes(linuxContent);

  // Create mock Windows zip
  final windowsContent = List<int>.generate(1536, (i) => (i * 3) % 256);
  await File('${versionDir.path}/geogram-$MOCK_VERSION-windows.zip').writeAsBytes(windowsContent);

  print('Mock update data created');
  print('');
}

// ============================================================================
// Test: /api/updates/latest endpoint
// ============================================================================

Future<void> testUpdatesLatestEndpoint() async {
  print('Testing GET /api/updates/latest...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/api/updates/latest'));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // Check for required fields
      final hasVersion = data['version'] == MOCK_VERSION;
      final hasTagName = data['tagName'] == MOCK_TAG_NAME;
      final hasStatus = data['status'] == 'available';
      final hasAssets = data['assets'] is Map;
      final hasBody = data['body'] != null;

      if (hasVersion && hasTagName && hasStatus && hasAssets && hasBody) {
        pass('Updates endpoint returns correct release info');

        // Check assets
        final assets = data['assets'] as Map<String, dynamic>;
        if (assets.containsKey('androidApk') && assets.containsKey('linuxDesktop')) {
          pass('Release info contains platform assets');
        } else {
          fail('Release assets', 'Missing expected platform assets');
        }
      } else {
        fail('Updates endpoint', 'Missing fields: '
            'version=$hasVersion, tagName=$hasTagName, status=$hasStatus, '
            'assets=$hasAssets, body=$hasBody');
      }
    } else {
      fail('Updates endpoint', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Updates endpoint', 'Error: $e');
  }
}

// ============================================================================
// Test: /api/updates/latest with no cached release
// ============================================================================

Future<void> testUpdatesLatestNoCache() async {
  print('Testing updates endpoint response structure...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/api/updates/latest'));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // Verify publishedAt is present and parseable
      final publishedAt = data['publishedAt'] as String?;
      if (publishedAt != null) {
        final date = DateTime.tryParse(publishedAt);
        if (date != null) {
          pass('publishedAt is valid ISO 8601 date');
        } else {
          fail('publishedAt', 'Not a valid date format');
        }
      } else {
        fail('publishedAt', 'Field is missing');
      }

      // Verify htmlUrl points to GitHub
      final htmlUrl = data['htmlUrl'] as String?;
      if (htmlUrl != null && htmlUrl.contains('github.com')) {
        pass('htmlUrl points to GitHub release');
      } else {
        fail('htmlUrl', 'Missing or invalid URL');
      }
    } else {
      fail('Updates response structure', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Updates response structure', 'Error: $e');
  }
}

// ============================================================================
// Test: Download update file
// ============================================================================

Future<void> testUpdateDownload(String updatesDir) async {
  print('Testing GET /updates/{version}/{filename}...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/updates/$MOCK_VERSION/geogram-$MOCK_VERSION.apk'),
    );

    if (response.statusCode == 200) {
      // Verify content length matches what we created
      if (response.bodyBytes.length == 1024) {
        pass('APK download returns correct file size');
      } else {
        fail('APK download', 'Wrong size: ${response.bodyBytes.length} (expected 1024)');
      }

      // Verify content type
      final contentType = response.headers['content-type'];
      if (contentType?.contains('android') == true ||
          contentType?.contains('octet-stream') == true) {
        pass('APK download has correct content type');
      } else {
        fail('APK content type', 'Got: $contentType');
      }
    } else {
      fail('APK download', 'HTTP ${response.statusCode}');
    }

    // Also test Linux tarball
    final linuxResponse = await http.get(
      Uri.parse('$BASE_URL/updates/$MOCK_VERSION/geogram-$MOCK_VERSION-linux.tar.gz'),
    );

    if (linuxResponse.statusCode == 200 && linuxResponse.bodyBytes.length == 2048) {
      pass('Linux tarball download works');
    } else {
      fail('Linux download', 'HTTP ${linuxResponse.statusCode} or wrong size');
    }
  } catch (e) {
    fail('Update download', 'Error: $e');
  }
}

// ============================================================================
// Test: Download non-existent file (404)
// ============================================================================

Future<void> testUpdateDownloadNotFound() async {
  print('Testing 404 for non-existent update file...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/updates/$MOCK_VERSION/nonexistent.apk'),
    );

    if (response.statusCode == 404) {
      pass('Non-existent file returns 404');
    } else {
      fail('404 handling', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('404 handling', 'Error: $e');
  }
}

// ============================================================================
// Test: Invalid path format
// ============================================================================

Future<void> testUpdateDownloadInvalidPath() async {
  print('Testing invalid update path handling...');
  try {
    // Test path without version
    final response = await http.get(Uri.parse('$BASE_URL/updates/'));

    if (response.statusCode == 400 || response.statusCode == 404) {
      pass('Invalid path returns error status');
    } else {
      fail('Invalid path', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Invalid path', 'Error: $e');
  }
}

// ============================================================================
// Test: Version comparison logic
// ============================================================================

Future<void> testVersionComparison() async {
  print('Testing version comparison...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/api/updates/latest'));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final latestVersion = data['version'] as String?;

      if (latestVersion != null) {
        // Compare versions
        final isNewer = _compareVersions(latestVersion, CURRENT_VERSION) > 0;
        if (isNewer) {
          pass('Version $latestVersion is newer than $CURRENT_VERSION');
        } else {
          fail('Version comparison', '$latestVersion should be newer than $CURRENT_VERSION');
        }

        // Test edge cases
        if (_compareVersions('1.10.7', '1.10.7') == 0) {
          pass('Same versions compare as equal');
        } else {
          fail('Same version comparison', 'Should be equal');
        }

        if (_compareVersions('1.9.0', '1.10.0') < 0) {
          pass('Minor version comparison works (1.9 < 1.10)');
        } else {
          fail('Minor version comparison', '1.9 should be less than 1.10');
        }

        if (_compareVersions('2.0.0', '1.99.99') > 0) {
          pass('Major version comparison works (2.0 > 1.99)');
        } else {
          fail('Major version comparison', '2.0 should be greater than 1.99');
        }
      } else {
        fail('Version comparison', 'No version in response');
      }
    } else {
      fail('Version comparison', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Version comparison', 'Error: $e');
  }
}

/// Compare two version strings (e.g., "1.10.7" vs "2.0.0")
/// Returns: positive if a > b, negative if a < b, 0 if equal
int _compareVersions(String a, String b) {
  final aParts = a.replaceAll(RegExp(r'[^0-9.]'), '').split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final bParts = b.replaceAll(RegExp(r'[^0-9.]'), '').split('.').map((p) => int.tryParse(p) ?? 0).toList();

  for (int i = 0; i < 3; i++) {
    final aVal = i < aParts.length ? aParts[i] : 0;
    final bVal = i < bParts.length ? bParts[i] : 0;
    if (aVal > bVal) return 1;
    if (aVal < bVal) return -1;
  }
  return 0;
}

// ============================================================================
// Test: HTTP headers for update downloads
// ============================================================================

Future<void> testUpdateHeaders() async {
  print('Testing update download HTTP headers...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/updates/$MOCK_VERSION/geogram-$MOCK_VERSION.apk'),
    );

    if (response.statusCode == 200) {
      // Check Content-Length header
      final contentLength = response.headers['content-length'];
      if (contentLength == '1024') {
        pass('Content-Length header is correct');
      } else {
        fail('Content-Length', 'Got: $contentLength (expected 1024)');
      }

      // Check Content-Disposition header for filename
      final contentDisposition = response.headers['content-disposition'];
      if (contentDisposition != null && contentDisposition.contains('geogram-$MOCK_VERSION.apk')) {
        pass('Content-Disposition header includes filename');
      } else {
        fail('Content-Disposition', 'Got: $contentDisposition');
      }
    } else {
      fail('Update headers', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Update headers', 'Error: $e');
  }
}

// ============================================================================
// Test: Large file download (simulates real APK)
// ============================================================================

Future<void> testLargeFileDownload(String updatesDir) async {
  print('Testing large file download (1MB simulation)...');
  try {
    // Create a larger test file (1MB)
    final versionDir = '$updatesDir/$MOCK_VERSION';
    final largeContent = List<int>.generate(1024 * 1024, (i) => i % 256);
    final largeFile = File('$versionDir/large-test.bin');
    await largeFile.writeAsBytes(largeContent);

    final response = await http.get(
      Uri.parse('$BASE_URL/updates/$MOCK_VERSION/large-test.bin'),
    );

    if (response.statusCode == 200) {
      if (response.bodyBytes.length == 1024 * 1024) {
        pass('Large file download (1MB) works correctly');
      } else {
        fail('Large file', 'Wrong size: ${response.bodyBytes.length}');
      }
    } else {
      fail('Large file download', 'HTTP ${response.statusCode}');
    }

    // Clean up
    await largeFile.delete();
  } catch (e) {
    fail('Large file download', 'Error: $e');
  }
}
