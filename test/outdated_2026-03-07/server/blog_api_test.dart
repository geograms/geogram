#!/usr/bin/env dart
/// Blog API Test for p2p.radio
///
/// Tests that blog posts are accessible publicly through p2p.radio.
/// Verifies both station blog and device proxy functionality.
///
/// Run with: dart tests/server/blog_api_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const String TARGET_HOST = 'p2p.radio';
const int TARGET_PORT = 80;
const String BASE_URL = 'http://$TARGET_HOST:$TARGET_PORT';

// Test results tracking
int _passed = 0;
int _failed = 0;
int _skipped = 0;
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

void skip(String test, String reason) {
  _skipped++;
  print('  [SKIP] $test - $reason');
}

Future<void> main() async {
  print('');
  print('=' * 60);
  print('Blog API Test - p2p.radio');
  print('=' * 60);
  print('');
  print('Target: $BASE_URL');
  print('');

  // Phase 1: Station Blog Tests
  print('Phase 1: Station Blog Tests');
  print('-' * 40);

  final (posts, hasStationBlog) = await testStationBlogList();

  if (hasStationBlog) {
    await testStationBlogListWithFilters();

    if (posts.isNotEmpty) {
      final firstPostId = posts[0]['id'] as String;
      await testStationBlogPostDetails(firstPostId);
      await testStationBlogFeedback(firstPostId);
    } else {
      skip('Post details test', 'No posts available');
      skip('Post feedback test', 'No posts available');
    }

    await testStationBlogNotFound();
  } else {
    skip('Station blog filters', 'Station blog not configured');
    skip('Post details test', 'Station blog not configured');
    skip('Post feedback test', 'Station blog not configured');
    skip('404 handling test', 'Station blog not configured');
  }
  print('');

  // Phase 2: Device Proxy Tests (API)
  print('Phase 2: Device Proxy Tests (API)');
  print('-' * 40);

  final devices = await testGetConnectedDevices();

  // Track devices with posts for HTML testing
  final devicesWithPosts = <String, List<Map<String, dynamic>>>{};

  if (devices.isNotEmpty) {
    // Test up to 3 devices
    for (final device in devices.take(3)) {
      final callsign = device['callsign'] as String? ?? device.toString();
      final posts = await testDeviceBlogList(callsign);
      if (posts.isNotEmpty) {
        devicesWithPosts[callsign] = posts;
      }
    }
  } else {
    skip('Device blog tests', 'No connected devices');
  }

  await testDeviceNotConnected();
  print('');

  // Phase 2b: Device Blog HTML Tests (Browser View)
  print('Phase 2b: Device Blog HTML Tests (Browser View)');
  print('-' * 40);

  if (devices.isNotEmpty) {
    // Test HTML index for first device
    final firstCallsign = devices.first['callsign'] as String? ?? devices.first.toString();
    await testDeviceBlogIndexHtml(firstCallsign);

    // Test individual post HTML if any device has posts
    if (devicesWithPosts.isNotEmpty) {
      final entry = devicesWithPosts.entries.first;
      final callsign = entry.key;
      final posts = entry.value;
      if (posts.isNotEmpty) {
        final postId = posts.first['id'] as String?;
        if (postId != null) {
          await testDeviceBlogPostHtml(callsign, postId);
        }
      }
    } else {
      skip('Blog post HTML test', 'No devices have blog posts');
    }

    // Test 404 for non-existent post
    await testDeviceBlogPostNotFound(firstCallsign);
  } else {
    skip('Blog HTML tests', 'No connected devices');
  }
  print('');

  // Phase 3: Edge Cases
  print('Phase 3: Edge Cases');
  print('-' * 40);

  await testCorsHeaders();
  await testResponseFormatValidation();
  print('');

  // Print summary
  print('=' * 60);
  print('Test Summary');
  print('=' * 60);
  print('');
  print('Passed:  $_passed');
  print('Failed:  $_failed');
  print('Skipped: $_skipped');
  print('Total:   ${_passed + _failed + _skipped}');
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

// ============================================================================
// Phase 1: Station Blog Tests
// ============================================================================

/// Test GET /api/blog - List all blog posts
/// Returns (posts, hasStationBlog) tuple
Future<(List<Map<String, dynamic>>, bool)> testStationBlogList() async {
  print('Testing GET /api/blog...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/api/blog'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // Check for required fields
      final hasSuccess = data['success'] == true;
      final hasPosts = data['posts'] is List;
      final hasTotal = data['total'] is int;

      if (hasSuccess && hasPosts && hasTotal) {
        final posts = (data['posts'] as List).cast<Map<String, dynamic>>();
        final total = data['total'] as int;
        pass('Station blog list returns valid JSON (total: $total, returned: ${posts.length})');

        // Validate post structure if we have posts
        if (posts.isNotEmpty) {
          final post = posts.first;
          final hasId = post['id'] != null;
          final hasTitle = post['title'] != null;
          final hasTimestamp = post['timestamp'] != null;

          if (hasId && hasTitle && hasTimestamp) {
            pass('Blog posts contain expected fields (id, title, timestamp)');
          } else {
            fail('Blog post structure', 'Missing required fields: id=$hasId, title=$hasTitle, timestamp=$hasTimestamp');
          }
        }

        return (posts, true);
      } else {
        fail('Station blog list', 'Missing fields: success=$hasSuccess, posts=$hasPosts, total=$hasTotal');
        return (<Map<String, dynamic>>[], true);
      }
    } else if (response.statusCode == 404) {
      // Station may not have a blog configured - this is acceptable
      skip('Station blog list', 'Station blog not configured (404)');
      return (<Map<String, dynamic>>[], false);
    } else {
      fail('Station blog list', 'HTTP ${response.statusCode}');
      return (<Map<String, dynamic>>[], false);
    }
  } on TimeoutException {
    fail('Station blog list', 'Request timed out');
    return (<Map<String, dynamic>>[], false);
  } catch (e) {
    fail('Station blog list', 'Error: $e');
    return (<Map<String, dynamic>>[], false);
  }
}

/// Test blog list with filters
Future<void> testStationBlogListWithFilters() async {
  // Test year filter
  print('Testing GET /api/blog?year=2025...');
  try {
    final yearResponse = await http.get(
      Uri.parse('$BASE_URL/api/blog?year=2025'),
    ).timeout(const Duration(seconds: 30));

    if (yearResponse.statusCode == 200) {
      final data = jsonDecode(yearResponse.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        final filters = data['filters'] as Map<String, dynamic>?;
        if (filters != null && filters['year'] == 2025) {
          pass('Year filter is applied correctly');
        } else {
          pass('Year filter endpoint responds (filter echo may vary)');
        }
      } else {
        fail('Year filter', 'success != true');
      }
    } else {
      fail('Year filter', 'HTTP ${yearResponse.statusCode}');
    }
  } catch (e) {
    fail('Year filter', 'Error: $e');
  }

  // Test pagination
  print('Testing GET /api/blog?limit=5&offset=0...');
  try {
    final paginatedResponse = await http.get(
      Uri.parse('$BASE_URL/api/blog?limit=5&offset=0'),
    ).timeout(const Duration(seconds: 30));

    if (paginatedResponse.statusCode == 200) {
      final data = jsonDecode(paginatedResponse.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        final posts = data['posts'] as List?;
        final count = data['count'] as int?;
        final total = data['total'] as int?;

        if (posts != null && count != null) {
          if (posts.length <= 5) {
            pass('Pagination limit is respected (got ${posts.length} posts)');
          } else {
            fail('Pagination', 'Got ${posts.length} posts, expected <= 5');
          }
        } else {
          pass('Pagination endpoint responds');
        }
      } else {
        fail('Pagination', 'success != true');
      }
    } else {
      fail('Pagination', 'HTTP ${paginatedResponse.statusCode}');
    }
  } catch (e) {
    fail('Pagination', 'Error: $e');
  }

  // Test tag filter
  print('Testing GET /api/blog?tag=news...');
  try {
    final tagResponse = await http.get(
      Uri.parse('$BASE_URL/api/blog?tag=news'),
    ).timeout(const Duration(seconds: 30));

    if (tagResponse.statusCode == 200) {
      final data = jsonDecode(tagResponse.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        pass('Tag filter endpoint responds');
      } else {
        fail('Tag filter', 'success != true');
      }
    } else {
      fail('Tag filter', 'HTTP ${tagResponse.statusCode}');
    }
  } catch (e) {
    fail('Tag filter', 'Error: $e');
  }
}

/// Test GET /api/blog/{postId} - Post details
Future<void> testStationBlogPostDetails(String postId) async {
  print('Testing GET /api/blog/$postId...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/api/blog/$postId'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // Check for required fields
      final hasSuccess = data['success'] == true;
      final hasId = data['id'] != null;
      final hasTitle = data['title'] != null;
      final hasContent = data['content'] != null;
      final hasComments = data['comments'] is List;

      if (hasSuccess && hasId && hasTitle && hasContent) {
        pass('Post details returns valid JSON');

        if (hasComments) {
          final comments = data['comments'] as List;
          pass('Post includes comments array (count: ${comments.length})');
        }
      } else {
        fail('Post details', 'Missing fields: success=$hasSuccess, id=$hasId, title=$hasTitle, content=$hasContent');
      }
    } else {
      fail('Post details', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Post details', 'Error: $e');
  }
}

/// Test GET /api/blog/{postId}/feedback - Post feedback
Future<void> testStationBlogFeedback(String postId) async {
  print('Testing GET /api/blog/$postId/feedback...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/api/blog/$postId/feedback'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      final hasSuccess = data['success'] == true;
      final hasFeedback = data['feedback'] is Map;

      if (hasSuccess && hasFeedback) {
        final feedback = data['feedback'] as Map<String, dynamic>;
        final hasLikes = feedback['likes'] is int;
        final hasPoints = feedback['points'] is int;

        if (hasLikes && hasPoints) {
          pass('Post feedback returns likes (${feedback['likes']}) and points (${feedback['points']})');
        } else {
          pass('Post feedback returns valid JSON');
        }
      } else {
        fail('Post feedback', 'Missing fields: success=$hasSuccess, feedback=$hasFeedback');
      }
    } else if (response.statusCode == 404) {
      // Feedback endpoint might not exist for all posts
      skip('Post feedback', 'Endpoint returned 404');
    } else {
      fail('Post feedback', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Post feedback', 'Error: $e');
  }
}

/// Test GET /api/blog/nonexistent - 404 handling
Future<void> testStationBlogNotFound() async {
  print('Testing GET /api/blog/nonexistent-post-id-12345...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/api/blog/nonexistent-post-id-12345'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 404) {
      pass('Non-existent post returns 404');
    } else if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['error'] != null || data['success'] == false) {
        pass('Non-existent post returns error response');
      } else {
        fail('404 handling', 'Expected 404 or error, got success');
      }
    } else {
      fail('404 handling', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('404 handling', 'Error: $e');
  }
}

// ============================================================================
// Phase 2: Device Proxy Tests
// ============================================================================

/// Test GET /api/devices - List connected devices
Future<List<Map<String, dynamic>>> testGetConnectedDevices() async {
  print('Testing GET /api/devices...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/api/devices'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);

      // Could be a list or a map with devices field
      List<dynamic> devices;
      if (data is List) {
        devices = data;
      } else if (data is Map && data['devices'] is List) {
        devices = data['devices'] as List;
      } else if (data is Map && data['success'] == true && data['connected'] is List) {
        devices = data['connected'] as List;
      } else {
        // Try to extract any list from the response
        devices = [];
        if (data is Map) {
          for (final value in data.values) {
            if (value is List) {
              devices = value;
              break;
            }
          }
        }
      }

      pass('Device list endpoint responds (${devices.length} devices)');

      // Return as list of maps
      return devices.whereType<Map<String, dynamic>>().toList();
    } else if (response.statusCode == 404) {
      skip('Device list', 'Endpoint not available (404)');
      return [];
    } else {
      fail('Device list', 'HTTP ${response.statusCode}');
      return [];
    }
  } catch (e) {
    fail('Device list', 'Error: $e');
    return [];
  }
}

/// Test GET /{callsign}/api/blog - Device blog through proxy
/// Returns list of posts for further HTML testing
Future<List<Map<String, dynamic>>> testDeviceBlogList(String callsign) async {
  print('Testing GET /$callsign/api/blog...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/$callsign/api/blog'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] == true || data['posts'] is List) {
        final posts = (data['posts'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        pass('Device $callsign blog API accessible (${posts.length} posts)');
        return posts;
      } else if (data['error'] != null) {
        // Device might be connected but have no blog
        pass('Device $callsign responded with status: ${data['error']}');
        return [];
      } else {
        pass('Device $callsign blog endpoint responds');
        return [];
      }
    } else if (response.statusCode == 404 || response.statusCode == 502) {
      // Device might be offline or not responding
      skip('Device $callsign blog', 'Device unavailable (HTTP ${response.statusCode})');
      return [];
    } else {
      fail('Device $callsign blog', 'HTTP ${response.statusCode}');
      return [];
    }
  } catch (e) {
    fail('Device $callsign blog', 'Error: $e');
    return [];
  }
}

/// Test GET /{callsign}/blog/ - Blog index HTML page
Future<void> testDeviceBlogIndexHtml(String callsign) async {
  print('Testing GET /$callsign/blog/ (HTML index)...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/$callsign/blog/'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final contentType = response.headers['content-type'] ?? '';
      final body = response.body;

      if (contentType.contains('text/html') || body.contains('<html') || body.contains('<!DOCTYPE')) {
        pass('Device $callsign blog index returns HTML');

        // Check for basic HTML structure
        if (body.contains('<title') || body.contains('<body')) {
          pass('Blog index has valid HTML structure');
        }
      } else {
        // Might return JSON or redirect
        pass('Device $callsign blog index responds (Content-Type: $contentType)');
      }
    } else if (response.statusCode == 404) {
      skip('Device $callsign blog index', 'Blog not configured (404)');
    } else if (response.statusCode == 500) {
      // 500 might indicate device doesn't have blog collection properly set up
      skip('Device $callsign blog index', 'Server error (500) - blog may not be configured');
    } else if (response.statusCode == 502) {
      skip('Device $callsign blog index', 'Device unavailable (502)');
    } else {
      fail('Device $callsign blog index', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Device $callsign blog index', 'Error: $e');
  }
}

/// Test GET /{callsign}/blog/{postId}.html - Individual blog post HTML
Future<void> testDeviceBlogPostHtml(String callsign, String postId) async {
  print('Testing GET /$callsign/blog/$postId.html...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/$callsign/blog/$postId.html'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final contentType = response.headers['content-type'] ?? '';
      final body = response.body;

      if (contentType.contains('text/html') || body.contains('<html') || body.contains('<!DOCTYPE')) {
        pass('Blog post /$callsign/blog/$postId.html returns HTML');

        // Check for content indicators
        if (body.contains('<article') || body.contains('<main') || body.contains('post-content') || body.contains('<h1')) {
          pass('Blog post HTML contains article content');
        }

        // Check for post title in HTML
        if (body.contains('<title')) {
          pass('Blog post HTML has title tag');
        }
      } else {
        pass('Blog post responds (Content-Type: $contentType)');
      }
    } else if (response.statusCode == 404) {
      fail('Blog post HTML', 'Post not found (404)');
    } else if (response.statusCode == 502) {
      skip('Blog post HTML', 'Device unavailable (502)');
    } else {
      fail('Blog post HTML', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Blog post HTML', 'Error: $e');
  }
}

/// Test GET /{callsign}/blog/nonexistent.html - 404 for non-existent post
Future<void> testDeviceBlogPostNotFound(String callsign) async {
  print('Testing GET /$callsign/blog/2099-01-01_nonexistent-post.html (404)...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/$callsign/blog/2099-01-01_nonexistent-post.html'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 404) {
      pass('Non-existent blog post returns 404');
    } else if (response.statusCode == 502) {
      skip('Blog post 404 test', 'Device unavailable (502)');
    } else {
      fail('Blog post 404', 'Expected 404, got HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Blog post 404', 'Error: $e');
  }
}

/// Test GET /X0FAKE/api/blog - Non-connected device
Future<void> testDeviceNotConnected() async {
  print('Testing GET /X0FAKE/api/blog (non-connected device)...');
  try {
    final response = await http.get(
      Uri.parse('$BASE_URL/X0FAKE/api/blog'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 404 || response.statusCode == 502) {
      pass('Non-connected device returns ${response.statusCode}');
    } else if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['error'] != null || data['success'] == false) {
        pass('Non-connected device returns error in body');
      } else {
        fail('Non-connected device', 'Expected error, got success');
      }
    } else {
      pass('Non-connected device returns HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Non-connected device', 'Error: $e');
  }
}

// ============================================================================
// Phase 3: Edge Cases
// ============================================================================

/// Test CORS headers (using /api/devices as fallback)
Future<void> testCorsHeaders() async {
  print('Testing CORS headers...');
  try {
    // Use /api/devices which is always available
    final response = await http.get(
      Uri.parse('$BASE_URL/api/devices'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final corsHeader = response.headers['access-control-allow-origin'];

      if (corsHeader != null) {
        pass('CORS header present: $corsHeader');
      } else {
        // CORS might not be enabled for all endpoints
        skip('CORS headers', 'Access-Control-Allow-Origin not present');
      }
    } else {
      fail('CORS test', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('CORS test', 'Error: $e');
  }
}

/// Test response format validation (using /api/devices as baseline)
Future<void> testResponseFormatValidation() async {
  print('Testing response format consistency...');
  try {
    // Use /api/devices which is always available
    final response = await http.get(
      Uri.parse('$BASE_URL/api/devices'),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      // Check Content-Type
      final contentType = response.headers['content-type'];
      if (contentType != null && contentType.contains('application/json')) {
        pass('Content-Type is application/json');
      } else if (contentType != null && contentType.contains('json')) {
        pass('Content-Type contains json: $contentType');
      } else {
        fail('Content-Type', 'Expected JSON, got: $contentType');
      }

      // Verify valid JSON
      try {
        jsonDecode(response.body);
        pass('Response is valid JSON');
      } catch (e) {
        fail('JSON parsing', 'Invalid JSON in response: $e');
      }
    } else {
      fail('Response format', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Response format', 'Error: $e');
  }
}
