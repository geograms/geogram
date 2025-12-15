#!/usr/bin/env dart
/// Geogram Desktop Blog App Test Suite
///
/// This test file verifies Blog app functionality including:
///   - Blog creation via debug API
///   - URL generation for p2p.radio access
///   - Fetching blog content from p2p.radio
///
/// The test connects to the real p2p.radio server, so internet is required.
///
/// Usage:
///   ./tests/app_blog_test.sh
///   # or directly:
///   dart run tests/app_blog_test.dart
///
/// Prerequisites:
///   - Build desktop: flutter build linux --release
///   - Internet connection (to access p2p.radio)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

// ============================================================
// Configuration
// ============================================================

/// Fixed temp directory for easy debugging and inspection
const String clientDataDir = '/tmp/geogram-blog-client';

/// Port for the client instance
const int clientPort = 17100;

/// Station URL (real p2p.radio)
const String stationUrl = 'wss://p2p.radio/ws';

/// Timing configuration
const Duration startupWait = Duration(seconds: 15);
const Duration connectionWait = Duration(seconds: 10);
const Duration apiWait = Duration(seconds: 5);

/// Unique marker for test content verification
final String uniqueMarker = 'BLOG_TEST_MARKER_${DateTime.now().millisecondsSinceEpoch}';

// ============================================================
// Test State
// ============================================================

/// Test results tracking
int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

/// Process handles for cleanup
Process? _clientProcess;

/// Instance information
String? _clientCallsign;
String? _clientNickname;
String? _createdBlogId;
String? _createdBlogUrl;

// ============================================================
// Output Helpers
// ============================================================

void pass(String test) {
  _passed++;
  print('  \x1B[32m✓\x1B[0m $test');
}

void fail(String test, String reason) {
  _failed++;
  _failures.add('$test: $reason');
  print('  \x1B[31m✗\x1B[0m $test - $reason');
}

void info(String message) {
  print('  \x1B[36mℹ\x1B[0m $message');
}

void warn(String message) {
  print('  \x1B[33m⚠\x1B[0m $message');
}

void section(String title) {
  print('\n\x1B[1m=== $title ===\x1B[0m');
}

// ============================================================
// Instance Management
// ============================================================

/// Launch a geogram-desktop client instance
Future<Process?> launchClientInstance({
  required int port,
  required String dataDir,
  required String stationUrl,
}) async {
  // Find the executable
  final executable = File('build/linux/x64/release/bundle/geogram_desktop');
  if (!await executable.exists()) {
    print('ERROR: Build not found at ${executable.path}');
    print('Please run: flutter build linux --release');
    return null;
  }

  final args = [
    '--port=$port',
    '--data-dir=$dataDir',
    '--new-identity',
    '--skip-intro',
    '--http-api',
    '--debug-api',
    '--no-update',
    '--identity-type=client',
    '--nickname=BlogTestClient',
    '--station=$stationUrl',
  ];

  info('Starting client on port $port...');
  info('Data directory: $dataDir');
  info('Station: $stationUrl');

  final process = await Process.start(
    executable.path,
    args,
    mode: ProcessStartMode.detachedWithStdio,
  );

  // Log errors for debugging
  process.stderr.transform(utf8.decoder).listen((data) {
    if (data.trim().isNotEmpty) {
      print('  [Client STDERR] ${data.trim()}');
    }
  });

  return process;
}

/// Wait for an instance to be ready (API responding)
Future<bool> waitForReady(int port,
    {Duration timeout = const Duration(seconds: 60)}) async {
  final stopwatch = Stopwatch()..start();
  final urls = [
    'http://localhost:$port/api/status',
    'http://localhost:$port/api/',
  ];

  while (stopwatch.elapsed < timeout) {
    for (final url in urls) {
      try {
        final response =
            await http.get(Uri.parse(url)).timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          info('Client ready (${data['callsign']})');
          return true;
        }
      } catch (e) {
        // Not ready yet
      }
    }
    await Future.delayed(const Duration(milliseconds: 500));
  }

  return false;
}

/// Get client info from instance
Future<Map<String, String?>> getClientInfo(int port) async {
  for (final path in ['/api/status', '/api/']) {
    try {
      final response = await http.get(Uri.parse('http://localhost:$port$path'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'callsign': data['callsign'] as String?,
          'nickname': data['nickname'] as String?,
        };
      }
    } catch (e) {
      // Try next
    }
  }
  return {'callsign': null, 'nickname': null};
}

/// Send debug API action
Future<Map<String, dynamic>?> debugAction(
    int port, Map<String, dynamic> action) async {
  try {
    final response = await http
        .post(
          Uri.parse('http://localhost:$port/api/debug'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(action),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      try {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } catch (e) {
        info('DEBUG API JSON parse error: $e');
        return null;
      }
    } else {
      info('DEBUG API Error (${response.statusCode}): ${response.body}');
      try {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } catch (e) {
        return {'success': false, 'error': 'HTTP ${response.statusCode}'};
      }
    }
  } catch (e) {
    info('DEBUG API Exception: $e');
    return {'success': false, 'error': 'Exception: $e'};
  }
}

/// Wait for station connection using debug API
Future<bool> waitForStationConnection(int port,
    {Duration timeout = const Duration(seconds: 60)}) async {
  final stopwatch = Stopwatch()..start();

  while (stopwatch.elapsed < timeout) {
    try {
      // Use station_status debug action to check connection
      final result = await debugAction(port, {'action': 'station_status'});
      if (result != null && result['connected'] == true) {
        info('Connected to station: ${result['preferred_url']}');
        return true;
      }

      // If not connected after 10 seconds, try to connect explicitly
      if (stopwatch.elapsed.inSeconds > 10 && stopwatch.elapsed.inSeconds % 10 == 0) {
        info('Attempting to connect to station...');
        await debugAction(port, {'action': 'station_connect'});
      }
    } catch (e) {
      // Not ready yet
    }
    await Future.delayed(const Duration(seconds: 2));
  }

  warn('Could not establish station connection');
  return false;
}

// ============================================================
// Setup and Cleanup
// ============================================================

/// Prepare temp directories (clean and create)
Future<void> prepareDirectories() async {
  // Use shell rm -rf for reliable cleanup
  final rmResult = await Process.run('rm', ['-rf', clientDataDir]);
  if (rmResult.exitCode != 0) {
    warn('Failed to remove $clientDataDir: ${rmResult.stderr}');
  } else {
    info('Removed existing directory: $clientDataDir');
  }

  // Create fresh directory
  final dir = Directory(clientDataDir);
  await dir.create(recursive: true);
  info('Created directory: $clientDataDir');
}

/// Cleanup all processes
Future<void> cleanup() async {
  section('Cleanup');

  // Delete the blog post if created
  if (_createdBlogId != null) {
    info('Deleting test blog post: $_createdBlogId');
    final result = await debugAction(clientPort, {
      'action': 'blog_delete',
      'blog_id': _createdBlogId,
    });
    if (result?['success'] == true) {
      info('Blog post deleted');
    } else {
      warn('Failed to delete blog post: ${result?['error']}');
    }
  }

  // Stop client
  if (_clientProcess != null) {
    info('Stopping Client...');
    _clientProcess!.kill(ProcessSignal.sigterm);
  }

  // Wait a moment for process to exit
  await Future.delayed(const Duration(seconds: 2));

  // Force kill if needed
  _clientProcess?.kill(ProcessSignal.sigkill);

  // Keep directory for inspection
  info('Keeping directory for inspection: $clientDataDir');
}

// ============================================================
// Test Functions
// ============================================================

Future<void> testSetup() async {
  section('Setup');

  // Check if build exists
  final executable = File('build/linux/x64/release/bundle/geogram_desktop');
  if (!await executable.exists()) {
    fail('Build check', 'Desktop build not found');
    throw Exception('Build not found. Run: flutter build linux --release');
  }
  pass('Desktop build exists');

  // Prepare directories
  await prepareDirectories();
  pass('Directories prepared');
}

Future<void> testLaunchClient() async {
  section('Launch Client');

  // Start client
  _clientProcess = await launchClientInstance(
    port: clientPort,
    dataDir: clientDataDir,
    stationUrl: stationUrl,
  );

  if (_clientProcess == null) {
    fail('Launch client', 'Failed to start process');
    throw Exception('Failed to launch client');
  }
  pass('Client process started');

  // Wait for startup
  info('Waiting for client to start...');
  await Future.delayed(startupWait);

  // Check if ready
  if (await waitForReady(clientPort)) {
    pass('Client API ready');
  } else {
    fail('Client API ready', 'Timeout waiting for client');
    throw Exception('Client did not become ready');
  }

  // Get callsign and nickname
  final clientInfo = await getClientInfo(clientPort);
  _clientCallsign = clientInfo['callsign'];
  _clientNickname = clientInfo['nickname'] ?? _clientCallsign;

  if (_clientCallsign != null) {
    pass('Got client callsign: $_clientCallsign');
    info('Client nickname: $_clientNickname');
  } else {
    fail('Get callsign', 'Could not get client callsign');
    throw Exception('Failed to get client callsign');
  }
}

Future<void> testStationConnection() async {
  section('Station Connection');

  info('Waiting for connection to p2p.radio...');

  // Try to verify station connection
  if (await waitForStationConnection(clientPort)) {
    pass('Station connection established');
  } else {
    fail('Station connection', 'Could not connect to p2p.radio');
    throw Exception('Failed to connect to station - cannot proceed with test');
  }

  // Give p2p.radio a moment to register our client
  info('Waiting for p2p.radio to register client...');
  await Future.delayed(const Duration(seconds: 5));
}

Future<void> testCreateBlog() async {
  section('Create Blog Post');

  final title = 'Test Blog Post';
  final content = '''
This is a test blog post created via the debug API.

The unique marker for this test is: $uniqueMarker

This content should be visible when fetching the blog from p2p.radio.
''';

  info('Creating blog post with marker: $uniqueMarker');

  final result = await debugAction(clientPort, {
    'action': 'blog_create',
    'title': title,
    'content': content,
    'status': 'published',
  });

  if (result == null) {
    fail('Create blog', 'No response from debug API');
    throw Exception('Failed to create blog post');
  }

  if (result['success'] != true) {
    fail('Create blog', 'Error: ${result['error']}');
    throw Exception('Failed to create blog post: ${result['error']}');
  }

  _createdBlogId = result['blog_id'] as String?;
  _createdBlogUrl = result['url'] as String?;

  if (_createdBlogId == null || _createdBlogUrl == null) {
    fail('Create blog', 'Missing blog_id or url in response');
    throw Exception('Invalid response from blog_create');
  }

  pass('Blog post created: $_createdBlogId');
  info('Blog URL: $_createdBlogUrl');
}

Future<void> testListBlogs() async {
  section('List Blog Posts');

  final result = await debugAction(clientPort, {
    'action': 'blog_list',
  });

  if (result == null || result['success'] != true) {
    fail('List blogs', 'Error: ${result?['error']}');
    return;
  }

  final blogs = result['blogs'] as List?;
  if (blogs == null || blogs.isEmpty) {
    fail('List blogs', 'No blogs found');
    return;
  }

  // Check if our blog is in the list
  final ourBlog = blogs.firstWhere(
    (b) => b['id'] == _createdBlogId,
    orElse: () => null,
  );

  if (ourBlog != null) {
    pass('Created blog appears in list');
    info('Blog status: ${ourBlog['status']}');
  } else {
    fail('List blogs', 'Created blog not found in list');
  }
}

Future<void> testFetchFromP2PRadio() async {
  section('Fetch Blog from p2p.radio');

  if (_createdBlogUrl == null || _clientCallsign == null) {
    fail('Fetch blog', 'No URL or callsign available');
    return;
  }

  // Try both nickname URL and callsign URL
  final nicknameUrl = _createdBlogUrl!;
  final blogId = nicknameUrl.split('/').last.replaceAll('.html', '');
  final callsignUrl = 'https://p2p.radio/$_clientCallsign/blog/$blogId.html';

  info('Nickname URL: $nicknameUrl');
  info('Callsign URL: $callsignUrl');

  // Give the station more time to recognize our connection
  await Future.delayed(const Duration(seconds: 3));

  // Try callsign URL first (more reliable)
  for (final url in [callsignUrl, nicknameUrl]) {
    info('Fetching: $url');

    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));

      info('HTTP Status: ${response.statusCode}');

      if (response.statusCode == 200) {
        pass('Successfully fetched blog from p2p.radio');
        info('URL that worked: $url');

        // Check if the unique marker is in the content
        final body = response.body;
        if (body.contains(uniqueMarker)) {
          pass('Blog content contains unique marker');
        } else {
          fail('Verify content', 'Unique marker not found in response');
          info('Response length: ${body.length} characters');
          // Print first 500 chars for debugging
          info('Response preview: ${body.substring(0, body.length > 500 ? 500 : body.length)}...');
        }

        // Verify it's HTML
        if (body.contains('<html') || body.contains('<!DOCTYPE')) {
          pass('Response is HTML');
        } else {
          warn('Response may not be HTML');
        }
        return; // Success - exit the function
      } else if (response.statusCode == 404) {
        info('404 for $url - trying next...');
      } else {
        info('HTTP ${response.statusCode} for $url: ${response.body}');
      }
    } catch (e) {
      info('Exception for $url: $e');
    }
  }

  // Both URLs failed
  fail('Fetch blog', 'Blog not found on p2p.radio (404)');
  info('This might mean the device is not properly registered with p2p.radio');
  info('Try running the test again or checking station connectivity');
}

Future<void> testGetBlogUrl() async {
  section('Get Blog URL');

  if (_createdBlogId == null) {
    fail('Get URL', 'No blog ID available');
    return;
  }

  final result = await debugAction(clientPort, {
    'action': 'blog_get_url',
    'blog_id': _createdBlogId,
  });

  if (result == null || result['success'] != true) {
    fail('Get URL', 'Error: ${result?['error']}');
    return;
  }

  final url = result['url'] as String?;
  if (url == null) {
    fail('Get URL', 'No URL in response');
    return;
  }

  if (url == _createdBlogUrl) {
    pass('URL matches created blog URL');
  } else {
    warn('URL differs: $url vs $_createdBlogUrl');
    pass('Got URL from blog_get_url');
  }
}

// ============================================================
// Main
// ============================================================

Future<void> main() async {
  print('\x1B[1m');
  print('================================================');
  print('  Geogram Blog App Test Suite');
  print('================================================');
  print('\x1B[0m');
  print('');
  print('This test connects to the REAL p2p.radio server.');
  print('Internet connection is required.');
  print('');

  try {
    await testSetup();
    await testLaunchClient();
    await testStationConnection();
    await testCreateBlog();
    await testListBlogs();
    await testGetBlogUrl();
    await testFetchFromP2PRadio();
  } catch (e) {
    print('\n\x1B[31mTest aborted: $e\x1B[0m');
  } finally {
    await cleanup();
  }

  // Print summary
  section('Test Summary');
  print('');
  print('  Passed: \x1B[32m$_passed\x1B[0m');
  print('  Failed: \x1B[31m$_failed\x1B[0m');

  if (_failures.isNotEmpty) {
    print('');
    print('  Failures:');
    for (final failure in _failures) {
      print('    - $failure');
    }
  }

  print('');
  print('  Data directory: $clientDataDir');

  // Exit with appropriate code
  exit(_failed > 0 ? 1 : 0);
}
