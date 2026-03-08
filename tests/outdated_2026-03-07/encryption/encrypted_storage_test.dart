#!/usr/bin/env dart
/// Encrypted Storage Test Runner
///
/// This file provides Dart bindings for the encrypted storage tests.
/// For the full integration test, use the bash scripts:
///
///   ./tests/encryption/api_test.sh          # API tests against running instance
///   ./tests/encryption/run_test.sh          # Full integration test
///
/// Usage:
///   dart run tests/encryption/encrypted_storage_test.dart --port 3456
///
/// Prerequisites:
///   - Geogram instance running with debug API enabled
///   - Profile must have nsec configured for encryption

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

// Configuration
late String baseUrl;
late String port;

// Test counters
int testsRun = 0;
int testsPassed = 0;
int testsFailed = 0;
List<String> failedTests = [];

void main(List<String> args) async {
  port = '3456';

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = args[i + 1];
    }
  }

  baseUrl = 'http://localhost:$port';

  print('');
  print('=' * 70);
  print('         Encrypted Storage API Test (Dart)');
  print('=' * 70);
  print('');
  print('Target: $baseUrl');
  print('');

  // Check instance is running
  if (!await checkInstance()) {
    print('\n[FATAL] Cannot connect to instance at $baseUrl');
    print('Make sure Geogram is running with HTTP API enabled.');
    exit(1);
  }

  // Check debug API
  if (!await checkDebugApi()) {
    print('\n[FATAL] Debug API is disabled.');
    print('Enable it in Settings > Security > Debug API');
    exit(1);
  }

  // Run tests
  await runTests();

  // Print summary
  print('');
  print('=' * 70);
  if (testsFailed == 0) {
    print('         ALL TESTS PASSED! ($testsPassed/$testsRun)');
  } else {
    print('         TESTS: $testsPassed passed, $testsFailed failed');
  }
  print('=' * 70);

  if (failedTests.isNotEmpty) {
    print('\nFailed tests:');
    for (final test in failedTests) {
      print('  - $test');
    }
  }

  exit(testsFailed > 0 ? 1 : 0);
}

Future<bool> checkInstance() async {
  try {
    final response = await http.get(Uri.parse('$baseUrl/api/status'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      print('[OK] Instance: ${data['callsign']} (v${data['version']})');
      return true;
    }
  } catch (e) {
    print('[ERROR] Instance offline: $e');
  }
  return false;
}

Future<bool> checkDebugApi() async {
  try {
    final response = await http.get(Uri.parse('$baseUrl/api/debug'));
    if (response.statusCode == 200) {
      print('[OK] Debug API enabled');
      return true;
    } else if (response.statusCode == 403) {
      print('[ERROR] Debug API disabled');
    }
  } catch (e) {
    print('[ERROR] Debug API check failed: $e');
  }
  return false;
}

Future<Map<String, dynamic>> apiDebug(String action) async {
  final response = await http.post(
    Uri.parse('$baseUrl/api/debug'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'action': action}),
  );
  return jsonDecode(response.body) as Map<String, dynamic>;
}

void test(String name, bool passed, [String? details]) {
  testsRun++;
  if (passed) {
    testsPassed++;
    print('  [PASS] $name');
  } else {
    testsFailed++;
    failedTests.add(name);
    print('  [FAIL] $name');
    if (details != null) {
      print('         $details');
    }
  }
}

Future<void> runTests() async {
  // Get initial status
  print('\n--- INITIAL STATUS ---');
  var status = await apiDebug('encrypt_storage_status');
  final initialEnabled = status['enabled'] == true;
  final hasNsec = status['has_nsec'] == true;

  print('  enabled: ${status['enabled']}');
  print('  has_nsec: ${status['has_nsec']}');

  test('Profile has nsec', hasNsec, 'Encryption requires NOSTR secret key');

  if (!hasNsec) {
    print('\n[SKIP] Cannot run encryption tests without nsec');
    return;
  }

  // If already encrypted, disable first
  if (initialEnabled) {
    print('\n--- DISABLE (clean state) ---');
    final result = await apiDebug('encrypt_storage_disable');
    test('Disable for clean state', result['success'] == true, result['error']);
  }

  // Enable encryption
  print('\n--- ENABLE ENCRYPTION ---');
  var result = await apiDebug('encrypt_storage_enable');
  test('Enable encryption', result['success'] == true, result['error']);

  if (result['success'] == true) {
    print('  Files processed: ${result['files_processed']}');
  }

  // Verify status
  status = await apiDebug('encrypt_storage_status');
  test('Status shows enabled', status['enabled'] == true,
      'enabled: ${status['enabled']}');
  test('Archive path present', status['archive_path'] != null,
      'archive_path: ${status['archive_path']}');

  // Double enable should fail
  print('\n--- DOUBLE ENABLE (should fail) ---');
  result = await apiDebug('encrypt_storage_enable');
  test('Double enable rejected', result['success'] == false,
      'success: ${result['success']}');
  test('Error code ALREADY_ENCRYPTED', result['code'] == 'ALREADY_ENCRYPTED',
      'code: ${result['code']}');

  // Disable encryption
  print('\n--- DISABLE ENCRYPTION ---');
  result = await apiDebug('encrypt_storage_disable');
  test('Disable encryption', result['success'] == true, result['error']);

  if (result['success'] == true) {
    print('  Files processed: ${result['files_processed']}');
  }

  // Verify status
  status = await apiDebug('encrypt_storage_status');
  test('Status shows disabled', status['enabled'] == false,
      'enabled: ${status['enabled']}');
  test('Archive path null', status['archive_path'] == null,
      'archive_path: ${status['archive_path']}');

  // Double disable should fail
  print('\n--- DOUBLE DISABLE (should fail) ---');
  result = await apiDebug('encrypt_storage_disable');
  test('Double disable rejected', result['success'] == false,
      'success: ${result['success']}');
  test('Error code NOT_ENCRYPTED', result['code'] == 'NOT_ENCRYPTED',
      'code: ${result['code']}');

  // Restore original state
  if (initialEnabled) {
    print('\n--- RESTORE ORIGINAL STATE ---');
    result = await apiDebug('encrypt_storage_enable');
    test('Restored encrypted state', result['success'] == true, result['error']);
  }
}
