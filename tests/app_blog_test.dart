#!/usr/bin/env dart
/// Geogram Desktop Blog App Test Suite
///
/// This test file verifies Blog app functionality including:
///   - Blog creation via debug API
///   - URL generation for p2p.radio access
///   - Fetching blog content from p2p.radio
///   - Blog API endpoints (GET /api/blog, GET /api/blog/{postId})
///   - Comment API endpoints (POST, DELETE)
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
String? _createdCommentId;

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
// Blog API Endpoint Tests
// ============================================================

/// Test GET /api/blog - List all published blog posts
Future<void> testBlogApiList() async {
  section('Blog API - List Posts (GET /api/blog)');

  try {
    final response = await http
        .get(Uri.parse('http://localhost:$clientPort/api/blog'))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      fail('GET /api/blog', 'HTTP ${response.statusCode}: ${response.body}');
      return;
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (data['success'] != true) {
      fail('GET /api/blog', 'Response success != true');
      return;
    }

    pass('GET /api/blog returns success');

    final posts = data['posts'] as List?;
    if (posts == null) {
      fail('GET /api/blog', 'No posts array in response');
      return;
    }

    info('Total posts: ${data['total']}');
    info('Returned posts: ${posts.length}');

    // Check if our created blog is in the list
    if (_createdBlogId != null) {
      final ourPost = posts.firstWhere(
        (p) => p['id'] == _createdBlogId,
        orElse: () => null,
      );

      if (ourPost != null) {
        pass('Created blog found in /api/blog list');
        info('Post title: ${ourPost['title']}');
        info('Post author: ${ourPost['author']}');
        info('Comment count: ${ourPost['comment_count']}');
      } else {
        fail('GET /api/blog', 'Created blog not found in list');
      }
    }

    // Test filtering by year
    final year = DateTime.now().year;
    final filteredResponse = await http
        .get(Uri.parse('http://localhost:$clientPort/api/blog?year=$year'))
        .timeout(const Duration(seconds: 10));

    if (filteredResponse.statusCode == 200) {
      final filteredData = jsonDecode(filteredResponse.body) as Map<String, dynamic>;
      if (filteredData['success'] == true) {
        pass('GET /api/blog?year=$year works');
        info('Posts for $year: ${filteredData['count']}');
      }
    }
  } catch (e) {
    fail('GET /api/blog', 'Exception: $e');
  }
}

/// Test GET /api/blog/{postId} - Get single post with comments
Future<void> testBlogApiGetPost() async {
  section('Blog API - Get Post (GET /api/blog/{postId})');

  if (_createdBlogId == null) {
    fail('GET /api/blog/{postId}', 'No blog ID available');
    return;
  }

  try {
    final response = await http
        .get(Uri.parse('http://localhost:$clientPort/api/blog/$_createdBlogId'))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      fail('GET /api/blog/$_createdBlogId', 'HTTP ${response.statusCode}: ${response.body}');
      return;
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (data['success'] != true) {
      fail('GET /api/blog/{postId}', 'Response success != true');
      return;
    }

    pass('GET /api/blog/{postId} returns success');

    // Verify required fields
    final requiredFields = ['id', 'title', 'author', 'timestamp', 'content', 'comments'];
    for (final field in requiredFields) {
      if (!data.containsKey(field)) {
        fail('GET /api/blog/{postId}', 'Missing field: $field');
        return;
      }
    }
    pass('Response contains all required fields');

    info('Post ID: ${data['id']}');
    info('Post title: ${data['title']}');
    info('Post author: ${data['author']}');
    info('Comments: ${(data['comments'] as List).length}');

    // Verify content contains our unique marker
    final content = data['content'] as String?;
    if (content != null && content.contains(uniqueMarker)) {
      pass('Post content contains unique marker');
    } else {
      warn('Post content does not contain unique marker');
    }
  } catch (e) {
    fail('GET /api/blog/{postId}', 'Exception: $e');
  }
}

/// Test POST /api/blog/{postId}/comment - Add comment
Future<void> testBlogApiAddComment() async {
  section('Blog API - Add Comment (POST /api/blog/{postId}/comment)');

  if (_createdBlogId == null) {
    fail('POST comment', 'No blog ID available');
    return;
  }

  final commentContent = 'Test comment from app_blog_test.dart - $uniqueMarker';

  try {
    // Test adding a comment
    final response = await http
        .post(
          Uri.parse('http://localhost:$clientPort/api/blog/$_createdBlogId/comment'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'author': _clientCallsign ?? 'TESTCALL',
            'content': commentContent,
            'npub': 'npub1testpubkey123456789',
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      fail('POST comment', 'HTTP ${response.statusCode}: ${response.body}');
      return;
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (data['success'] != true) {
      fail('POST comment', 'Response success != true: ${data['error']}');
      return;
    }

    pass('POST /api/blog/{postId}/comment returns success');

    _createdCommentId = data['comment_id'] as String?;
    if (_createdCommentId != null) {
      pass('Got comment ID: $_createdCommentId');
    } else {
      fail('POST comment', 'No comment_id in response');
      return;
    }

    // Verify comment appears in post
    await Future.delayed(const Duration(milliseconds: 500));

    final getResponse = await http
        .get(Uri.parse('http://localhost:$clientPort/api/blog/$_createdBlogId'))
        .timeout(const Duration(seconds: 10));

    if (getResponse.statusCode == 200) {
      final postData = jsonDecode(getResponse.body) as Map<String, dynamic>;
      final comments = postData['comments'] as List? ?? [];

      final ourComment = comments.firstWhere(
        (c) => c['id'] == _createdCommentId,
        orElse: () => null,
      );

      if (ourComment != null) {
        pass('Comment appears in post comments list');
        info('Comment author: ${ourComment['author']}');
        info('Comment content: ${ourComment['content']}');
      } else {
        fail('Verify comment', 'Comment not found in post');
        info('Comments in post: ${comments.length}');
        for (final c in comments) {
          info('  - ${c['id']}: ${c['author']}');
        }
      }
    }
  } catch (e) {
    fail('POST comment', 'Exception: $e');
  }
}

/// Test error cases for comment API
Future<void> testBlogApiCommentErrors() async {
  section('Blog API - Comment Error Cases');

  if (_createdBlogId == null) {
    fail('Comment errors', 'No blog ID available');
    return;
  }

  // Test missing author
  try {
    final response = await http
        .post(
          Uri.parse('http://localhost:$clientPort/api/blog/$_createdBlogId/comment'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'content': 'Test comment without author',
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 400) {
      pass('Missing author returns 400');
    } else {
      warn('Missing author returned ${response.statusCode} instead of 400');
    }
  } catch (e) {
    fail('Missing author test', 'Exception: $e');
  }

  // Test missing content
  try {
    final response = await http
        .post(
          Uri.parse('http://localhost:$clientPort/api/blog/$_createdBlogId/comment'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'author': 'TESTCALL',
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 400) {
      pass('Missing content returns 400');
    } else {
      warn('Missing content returned ${response.statusCode} instead of 400');
    }
  } catch (e) {
    fail('Missing content test', 'Exception: $e');
  }

  // Test non-existent post
  try {
    final response = await http
        .post(
          Uri.parse('http://localhost:$clientPort/api/blog/9999-99-99_nonexistent-post/comment'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'author': 'TESTCALL',
            'content': 'Test comment',
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 404) {
      pass('Non-existent post returns 404');
    } else {
      warn('Non-existent post returned ${response.statusCode} instead of 404');
    }
  } catch (e) {
    fail('Non-existent post test', 'Exception: $e');
  }
}

/// Test DELETE /api/blog/{postId}/comment/{commentId} - Delete comment
Future<void> testBlogApiDeleteComment() async {
  section('Blog API - Delete Comment (DELETE /api/blog/{postId}/comment/{commentId})');

  if (_createdBlogId == null || _createdCommentId == null) {
    fail('DELETE comment', 'No blog ID or comment ID available');
    return;
  }

  // Test delete without X-Npub header
  try {
    final noAuthResponse = await http
        .delete(
          Uri.parse('http://localhost:$clientPort/api/blog/$_createdBlogId/comment/$_createdCommentId'),
        )
        .timeout(const Duration(seconds: 10));

    if (noAuthResponse.statusCode == 401) {
      pass('DELETE without X-Npub returns 401');
    } else {
      warn('DELETE without X-Npub returned ${noAuthResponse.statusCode} instead of 401');
    }
  } catch (e) {
    fail('DELETE without auth', 'Exception: $e');
  }

  // Test delete with wrong npub (should fail with 403)
  try {
    final wrongNpubResponse = await http
        .delete(
          Uri.parse('http://localhost:$clientPort/api/blog/$_createdBlogId/comment/$_createdCommentId'),
          headers: {'X-Npub': 'npub1wrongkey999999'},
        )
        .timeout(const Duration(seconds: 10));

    if (wrongNpubResponse.statusCode == 403) {
      pass('DELETE with wrong npub returns 403');
    } else {
      // Could be 200 if the user is the post author
      info('DELETE with wrong npub returned ${wrongNpubResponse.statusCode}');
    }
  } catch (e) {
    fail('DELETE with wrong npub', 'Exception: $e');
  }

  // Test delete with correct npub (same as the one used when creating comment)
  try {
    final response = await http
        .delete(
          Uri.parse('http://localhost:$clientPort/api/blog/$_createdBlogId/comment/$_createdCommentId'),
          headers: {'X-Npub': 'npub1testpubkey123456789'},
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      fail('DELETE comment', 'HTTP ${response.statusCode}: ${response.body}');
      return;
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (data['success'] == true && data['deleted'] == true) {
      pass('DELETE /api/blog/{postId}/comment/{commentId} returns success');
    } else {
      fail('DELETE comment', 'Response: $data');
      return;
    }

    // Verify comment no longer appears in post
    await Future.delayed(const Duration(milliseconds: 500));

    final getResponse = await http
        .get(Uri.parse('http://localhost:$clientPort/api/blog/$_createdBlogId'))
        .timeout(const Duration(seconds: 10));

    if (getResponse.statusCode == 200) {
      final postData = jsonDecode(getResponse.body) as Map<String, dynamic>;
      final comments = postData['comments'] as List? ?? [];

      final ourComment = comments.firstWhere(
        (c) => c['id'] == _createdCommentId,
        orElse: () => null,
      );

      if (ourComment == null) {
        pass('Comment no longer appears in post');
      } else {
        fail('Verify deletion', 'Comment still exists in post');
      }
    }

    // Clear the comment ID since it's deleted
    _createdCommentId = null;
  } catch (e) {
    fail('DELETE comment', 'Exception: $e');
  }
}

/// Test non-existent endpoints return proper errors
Future<void> testBlogApiNotFound() async {
  section('Blog API - Not Found Cases');

  // Test non-existent post
  try {
    final response = await http
        .get(Uri.parse('http://localhost:$clientPort/api/blog/9999-99-99_nonexistent-post'))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 404) {
      pass('Non-existent post returns 404');
    } else {
      warn('Non-existent post returned ${response.statusCode} instead of 404');
    }
  } catch (e) {
    fail('Non-existent post', 'Exception: $e');
  }

  // Test delete non-existent comment
  if (_createdBlogId != null) {
    try {
      final response = await http
          .delete(
            Uri.parse('http://localhost:$clientPort/api/blog/$_createdBlogId/comment/9999-99-99_99-99-99_NOUSER'),
            headers: {'X-Npub': 'npub1testkey'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 404) {
        pass('Non-existent comment returns 404');
      } else {
        warn('Non-existent comment returned ${response.statusCode} instead of 404');
      }
    } catch (e) {
      fail('Non-existent comment', 'Exception: $e');
    }
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

    // Blog API endpoint tests
    await testBlogApiList();
    await testBlogApiGetPost();
    await testBlogApiAddComment();
    await testBlogApiCommentErrors();
    await testBlogApiDeleteComment();
    await testBlogApiNotFound();

    // p2p.radio tests (last, as they require external connectivity)
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
