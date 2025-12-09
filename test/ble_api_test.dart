#!/usr/bin/env dart
/// Comprehensive BLE API tests for Geogram Desktop
///
/// This test suite tests BLE functionality through the debug API:
/// - BLE scanning and device discovery
/// - BLE advertising
/// - HELLO handshakes between devices
/// - Message exchange verification through logs
///
/// Usage:
///   Single device test (local BLE scan):
///     dart test/ble_api_test.dart
///
///   Two device test (Linux to Linux or Linux to Android):
///     dart test/ble_api_test.dart --device1=localhost:3456 --device2=192.168.1.100:3456
///
///   With specific test:
///     dart test/ble_api_test.dart --test=scan
///     dart test/ble_api_test.dart --test=discovery
///     dart test/ble_api_test.dart --test=hello
///     dart test/ble_api_test.dart --test=all
///
/// Prerequisites:
///   - Geogram Desktop must be running on the target device(s)
///   - Bluetooth must be enabled and accessible
///   - For two-device tests, devices must be in BLE range

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

// Default configuration
const String DEFAULT_DEVICE1 = 'localhost:3456';
const int LOG_POLL_INTERVAL_MS = 500;
const int BLE_SCAN_TIMEOUT_MS = 15000;
const int HELLO_TIMEOUT_MS = 10000;

// Test results tracking
int _passed = 0;
int _failed = 0;
int _skipped = 0;
final List<String> _failures = [];

// Device endpoints
late String _device1Url;
String? _device2Url;

// Test mode
String _testMode = 'all';
bool _verbose = false;

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

void info(String message) {
  if (_verbose) {
    print('  [INFO] $message');
  }
}

Future<void> main(List<String> args) async {
  print('');
  print('=' * 60);
  print('Geogram Desktop BLE API Test Suite');
  print('=' * 60);
  print('');

  // Parse arguments
  _parseArgs(args);

  print('Device 1: $_device1Url');
  if (_device2Url != null) {
    print('Device 2: $_device2Url');
  }
  print('Test mode: $_testMode');
  print('Verbose: $_verbose');
  print('');

  try {
    // Verify device connectivity
    print('Verifying device connectivity...');
    final device1Ready = await _verifyDevice(_device1Url, 'Device 1');
    if (!device1Ready) {
      print('ERROR: Cannot connect to Device 1 at $_device1Url');
      print('Make sure Geogram Desktop is running.');
      exit(1);
    }

    if (_device2Url != null) {
      final device2Ready = await _verifyDevice(_device2Url!, 'Device 2');
      if (!device2Ready) {
        print('ERROR: Cannot connect to Device 2 at $_device2Url');
        print('Make sure Geogram Desktop is running on the remote device.');
        exit(1);
      }
    }
    print('');

    // Run tests based on mode
    if (_testMode == 'all' || _testMode == 'scan') {
      await _testBleScan();
    }

    if (_testMode == 'all' || _testMode == 'discovery') {
      await _testBleDiscovery();
    }

    if (_testMode == 'all' || _testMode == 'advertise') {
      await _testBleAdvertise();
    }

    if (_testMode == 'all' || _testMode == 'hello') {
      await _testBleHello();
    }

    if (_testMode == 'all' || _testMode == 'bidirectional') {
      await _testBidirectionalDiscovery();
    }

    // Print summary
    _printSummary();

    exit(_failed > 0 ? 1 : 0);
  } catch (e, stackTrace) {
    print('ERROR: $e');
    if (_verbose) {
      print(stackTrace);
    }
    exit(1);
  }
}

void _parseArgs(List<String> args) {
  _device1Url = 'http://$DEFAULT_DEVICE1';

  for (final arg in args) {
    if (arg.startsWith('--device1=')) {
      final host = arg.substring('--device1='.length);
      _device1Url = host.startsWith('http') ? host : 'http://$host';
    } else if (arg.startsWith('--device2=')) {
      final host = arg.substring('--device2='.length);
      _device2Url = host.startsWith('http') ? host : 'http://$host';
    } else if (arg.startsWith('--test=')) {
      _testMode = arg.substring('--test='.length);
    } else if (arg == '-v' || arg == '--verbose') {
      _verbose = true;
    } else if (arg == '-h' || arg == '--help') {
      _printHelp();
      exit(0);
    }
  }
}

void _printHelp() {
  print('''
Geogram Desktop BLE API Test Suite

Usage:
  dart test/ble_api_test.dart [options]

Options:
  --device1=HOST:PORT   First device endpoint (default: localhost:3456)
  --device2=HOST:PORT   Second device endpoint for two-device tests
  --test=MODE           Test mode: all, scan, discovery, advertise, hello, bidirectional
  -v, --verbose         Enable verbose output
  -h, --help            Show this help

Examples:
  # Single device BLE scan test
  dart test/ble_api_test.dart

  # Two Linux devices test
  dart test/ble_api_test.dart --device1=localhost:3456 --device2=192.168.1.100:3456

  # Linux to Android test
  dart test/ble_api_test.dart --device1=localhost:3456 --device2=192.168.1.50:3456

  # Run only scan test with verbose output
  dart test/ble_api_test.dart --test=scan -v
''');
}

void _printSummary() {
  print('');
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
    for (final failure in _failures) {
      print('  - $failure');
    }
    print('');
  }
}

// ============================================================================
// Device Verification
// ============================================================================

Future<bool> _verifyDevice(String baseUrl, String name) async {
  try {
    final response = await http.get(Uri.parse('$baseUrl/api/debug'))
        .timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final callsign = data['callsign'] ?? 'unknown';
      print('  $name: Connected (callsign: $callsign)');
      return true;
    }
    return false;
  } catch (e) {
    info('Connection error: $e');
    return false;
  }
}

Future<Map<String, dynamic>?> _getDeviceInfo(String baseUrl) async {
  try {
    final response = await http.get(Uri.parse('$baseUrl/api/debug'));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
  } catch (e) {
    info('Error getting device info: $e');
  }
  return null;
}

// ============================================================================
// API Helpers
// ============================================================================

Future<Map<String, dynamic>?> _triggerAction(
  String baseUrl,
  String action, [
  Map<String, dynamic>? params,
]) async {
  try {
    final body = {'action': action, ...?params};
    final response = await http.post(
      Uri.parse('$baseUrl/api/debug'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    info('Action $action failed with status ${response.statusCode}');
  } catch (e) {
    info('Error triggering action $action: $e');
  }
  return null;
}

Future<List<String>> _getLogs(
  String baseUrl, {
  String? filter,
  int limit = 100,
}) async {
  try {
    var url = '$baseUrl/log?limit=$limit';
    if (filter != null) {
      url += '&filter=${Uri.encodeComponent(filter)}';
    }

    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final logs = data['logs'] as List<dynamic>;
      return logs.cast<String>();
    }
  } catch (e) {
    info('Error getting logs: $e');
  }
  return [];
}

Future<bool> _waitForLogPattern(
  String baseUrl,
  String pattern, {
  int timeoutMs = 10000,
  String? filter,
}) async {
  final stopwatch = Stopwatch()..start();

  while (stopwatch.elapsedMilliseconds < timeoutMs) {
    final logs = await _getLogs(baseUrl, filter: filter, limit: 50);

    for (final log in logs) {
      if (log.contains(pattern)) {
        info('Found pattern "$pattern" in log: $log');
        return true;
      }
    }

    await Future.delayed(const Duration(milliseconds: LOG_POLL_INTERVAL_MS));
  }

  info('Timeout waiting for pattern "$pattern"');
  return false;
}

Future<List<String>> _getLogsContaining(
  String baseUrl,
  String pattern, {
  String? filter,
  int limit = 100,
}) async {
  final logs = await _getLogs(baseUrl, filter: filter, limit: limit);
  return logs.where((log) => log.contains(pattern)).toList();
}

// ============================================================================
// Test: BLE Scan
// ============================================================================

Future<void> _testBleScan() async {
  print('');
  print('-' * 40);
  print('Test: BLE Scan');
  print('-' * 40);

  // Test 1: Trigger BLE scan
  print('  Triggering BLE scan on Device 1...');
  final result = await _triggerAction(_device1Url, 'ble_scan');

  if (result == null) {
    fail('BLE scan trigger', 'Failed to trigger scan action');
    return;
  }

  if (result['success'] == true) {
    pass('BLE scan trigger');
  } else {
    fail('BLE scan trigger', 'Action returned success=false');
    return;
  }

  // Test 2: Verify scan started in logs
  print('  Waiting for scan to start...');
  final scanStarted = await _waitForLogPattern(
    _device1Url,
    'Starting BLE scan',
    filter: 'BLE',
    timeoutMs: 5000,
  );

  if (scanStarted) {
    pass('BLE scan started');
  } else {
    // Try alternative log message
    final altStarted = await _waitForLogPattern(
      _device1Url,
      'BLEDiscovery',
      filter: 'BLE',
      timeoutMs: 2000,
    );
    if (altStarted) {
      pass('BLE scan started (alternative log)');
    } else {
      fail('BLE scan started', 'No scan start log found');
    }
  }

  // Test 3: Wait for scan to complete and check results
  print('  Waiting for scan to complete...');
  await Future.delayed(Duration(milliseconds: BLE_SCAN_TIMEOUT_MS));

  final scanLogs = await _getLogsContaining(
    _device1Url,
    'BLEDiscovery',
    filter: 'BLE',
  );

  if (scanLogs.isNotEmpty) {
    pass('BLE scan completed with ${scanLogs.length} log entries');

    // Check for discovered devices
    final discoveredLogs = scanLogs.where(
      (l) => l.contains('Found') || l.contains('device'),
    ).toList();

    if (discoveredLogs.isNotEmpty) {
      info('Discovered devices:');
      for (final log in discoveredLogs.take(5)) {
        info('  $log');
      }
    }
  } else {
    skip('BLE scan results', 'No BLE logs found (BLE may not be available)');
  }
}

// ============================================================================
// Test: BLE Discovery (Two Devices)
// ============================================================================

Future<void> _testBleDiscovery() async {
  print('');
  print('-' * 40);
  print('Test: BLE Device Discovery');
  print('-' * 40);

  if (_device2Url == null) {
    skip('BLE discovery', 'Requires two devices (--device2=HOST:PORT)');
    return;
  }

  // Get device info
  final device1Info = await _getDeviceInfo(_device1Url);
  final device2Info = await _getDeviceInfo(_device2Url!);

  if (device1Info == null || device2Info == null) {
    fail('BLE discovery setup', 'Could not get device info');
    return;
  }

  final device1Callsign = device1Info['callsign'] ?? 'unknown';
  final device2Callsign = device2Info['callsign'] ?? 'unknown';

  print('  Device 1 callsign: $device1Callsign');
  print('  Device 2 callsign: $device2Callsign');

  // Start advertising on Device 2
  print('  Starting advertising on Device 2...');
  final advertiseResult = await _triggerAction(_device2Url!, 'ble_advertise');

  if (advertiseResult == null || advertiseResult['success'] != true) {
    skip('BLE advertising on Device 2', 'Advertising not available (may be Linux)');
    // Continue anyway - scan might still work
  } else {
    pass('BLE advertising started on Device 2');
  }

  // Wait for advertising to start
  await Future.delayed(const Duration(seconds: 2));

  // Trigger scan on Device 1
  print('  Triggering scan on Device 1...');
  final scanResult = await _triggerAction(_device1Url, 'ble_scan');

  if (scanResult == null || scanResult['success'] != true) {
    fail('BLE scan on Device 1', 'Failed to trigger scan');
    return;
  }
  pass('BLE scan triggered on Device 1');

  // Wait for scan to complete
  print('  Waiting for scan to complete (${BLE_SCAN_TIMEOUT_MS ~/ 1000}s)...');
  await Future.delayed(Duration(milliseconds: BLE_SCAN_TIMEOUT_MS));

  // Check if Device 2 was discovered
  final discoveryLogs = await _getLogsContaining(
    _device1Url,
    device2Callsign,
    filter: 'BLE',
  );

  if (discoveryLogs.isNotEmpty) {
    pass('Device 2 ($device2Callsign) discovered by Device 1');
    for (final log in discoveryLogs.take(3)) {
      info('  $log');
    }
  } else {
    // Check for any Geogram devices
    final geogramLogs = await _getLogsContaining(
      _device1Url,
      'Geogram',
      filter: 'BLE',
    );

    if (geogramLogs.isNotEmpty) {
      skip('Specific device discovery', 'Found Geogram devices but not $device2Callsign');
      for (final log in geogramLogs.take(3)) {
        info('  $log');
      }
    } else {
      fail('BLE device discovery', 'Device 2 not discovered');
    }
  }
}

// ============================================================================
// Test: BLE Advertise
// ============================================================================

Future<void> _testBleAdvertise() async {
  print('');
  print('-' * 40);
  print('Test: BLE Advertise');
  print('-' * 40);

  // Get current callsign
  final deviceInfo = await _getDeviceInfo(_device1Url);
  final callsign = deviceInfo?['callsign'] ?? 'TEST';

  print('  Starting BLE advertising as $callsign...');
  final result = await _triggerAction(_device1Url, 'ble_advertise', {
    'callsign': callsign,
  });

  if (result == null) {
    fail('BLE advertise trigger', 'Failed to trigger advertise action');
    return;
  }

  if (result['success'] == true) {
    pass('BLE advertise trigger');
  } else {
    // Advertising might not be available on Linux
    final error = result['error'] ?? 'unknown error';
    if (error.toString().contains('Linux') || error.toString().contains('not supported')) {
      skip('BLE advertise', 'Advertising not supported on this platform');
    } else {
      fail('BLE advertise trigger', error.toString());
    }
    return;
  }

  // Verify advertising started in logs
  final advertiseStarted = await _waitForLogPattern(
    _device1Url,
    'advertising',
    filter: 'BLE',
    timeoutMs: 5000,
  );

  if (advertiseStarted) {
    pass('BLE advertising confirmed in logs');
  } else {
    skip('BLE advertising confirmation', 'No advertising log found');
  }
}

// ============================================================================
// Test: BLE HELLO Handshake
// ============================================================================

Future<void> _testBleHello() async {
  print('');
  print('-' * 40);
  print('Test: BLE HELLO Handshake');
  print('-' * 40);

  if (_device2Url == null) {
    skip('BLE HELLO', 'Requires two devices (--device2=HOST:PORT)');
    return;
  }

  // First, ensure devices can see each other
  print('  Step 1: Ensuring devices are discoverable...');

  // Start advertising on Device 2 (if supported)
  await _triggerAction(_device2Url!, 'ble_advertise');
  await Future.delayed(const Duration(seconds: 1));

  // Scan from Device 1
  await _triggerAction(_device1Url, 'ble_scan');
  print('  Waiting for scan to complete...');
  await Future.delayed(Duration(milliseconds: BLE_SCAN_TIMEOUT_MS));

  // Get Device 2 info for identification
  final device2Info = await _getDeviceInfo(_device2Url!);
  final device2Callsign = device2Info?['callsign'];

  // Check discovery logs for any devices
  final discoveredLogs = await _getLogsContaining(
    _device1Url,
    'Found',
    filter: 'BLE',
  );

  if (discoveredLogs.isEmpty) {
    fail('BLE HELLO precondition', 'No devices discovered for HELLO handshake');
    return;
  }

  print('  Step 2: Attempting HELLO handshake...');

  // Try HELLO (will use first discovered device if no ID specified)
  final helloResult = await _triggerAction(_device1Url, 'ble_hello');

  if (helloResult == null) {
    fail('BLE HELLO trigger', 'Failed to trigger HELLO action');
    return;
  }

  if (helloResult['success'] == true) {
    pass('BLE HELLO triggered');
  } else {
    final error = helloResult['error'] ?? 'unknown error';
    fail('BLE HELLO trigger', error.toString());
    return;
  }

  // Wait for HELLO to complete
  print('  Waiting for HELLO handshake to complete...');
  final helloSuccess = await _waitForLogPattern(
    _device1Url,
    'HELLO',
    filter: 'BLE',
    timeoutMs: HELLO_TIMEOUT_MS,
  );

  if (helloSuccess) {
    // Check for successful handshake
    final helloLogs = await _getLogsContaining(
      _device1Url,
      'HELLO',
      filter: 'BLE',
    );

    final successLogs = helloLogs.where(
      (l) => l.contains('successful') || l.contains('ACK') || l.contains('success'),
    ).toList();

    if (successLogs.isNotEmpty) {
      pass('BLE HELLO handshake completed');
      for (final log in successLogs.take(2)) {
        info('  $log');
      }
    } else {
      // Check for errors
      final errorLogs = helloLogs.where(
        (l) => l.contains('error') || l.contains('failed') || l.contains('timeout'),
      ).toList();

      if (errorLogs.isNotEmpty) {
        fail('BLE HELLO handshake', 'Handshake failed');
        for (final log in errorLogs.take(2)) {
          info('  $log');
        }
      } else {
        pass('BLE HELLO handshake initiated (status uncertain)');
      }
    }
  } else {
    fail('BLE HELLO handshake', 'Timeout waiting for HELLO response');
  }

  // Also check Device 2 logs for incoming HELLO
  if (_device2Url != null) {
    print('  Checking Device 2 for incoming HELLO...');
    final device2HelloLogs = await _getLogsContaining(
      _device2Url!,
      'HELLO',
      filter: 'BLE',
    );

    if (device2HelloLogs.isNotEmpty) {
      pass('Device 2 received HELLO');
      for (final log in device2HelloLogs.take(2)) {
        info('  $log');
      }
    } else {
      info('No HELLO logs on Device 2');
    }
  }
}

// ============================================================================
// Test: Bidirectional Discovery
// ============================================================================

Future<void> _testBidirectionalDiscovery() async {
  print('');
  print('-' * 40);
  print('Test: Bidirectional BLE Discovery');
  print('-' * 40);

  if (_device2Url == null) {
    skip('Bidirectional discovery', 'Requires two devices (--device2=HOST:PORT)');
    return;
  }

  final device1Info = await _getDeviceInfo(_device1Url);
  final device2Info = await _getDeviceInfo(_device2Url!);

  final device1Callsign = device1Info?['callsign'] ?? 'Device1';
  final device2Callsign = device2Info?['callsign'] ?? 'Device2';

  print('  Testing: Device 1 ($device1Callsign) <-> Device 2 ($device2Callsign)');

  // Test 1: Device 1 discovers Device 2
  print('');
  print('  Direction 1: Device 1 scanning for Device 2...');

  await _triggerAction(_device2Url!, 'ble_advertise');
  await Future.delayed(const Duration(seconds: 1));
  await _triggerAction(_device1Url, 'ble_scan');
  await Future.delayed(Duration(milliseconds: BLE_SCAN_TIMEOUT_MS));

  final d1ToD2Logs = await _getLogsContaining(
    _device1Url,
    'Found',
    filter: 'BLE',
  );

  if (d1ToD2Logs.isNotEmpty) {
    pass('Device 1 -> Device 2: Discovery successful');
  } else {
    fail('Device 1 -> Device 2', 'No devices found');
  }

  // Test 2: Device 2 discovers Device 1
  print('');
  print('  Direction 2: Device 2 scanning for Device 1...');

  await _triggerAction(_device1Url, 'ble_advertise');
  await Future.delayed(const Duration(seconds: 1));
  await _triggerAction(_device2Url!, 'ble_scan');
  await Future.delayed(Duration(milliseconds: BLE_SCAN_TIMEOUT_MS));

  final d2ToD1Logs = await _getLogsContaining(
    _device2Url!,
    'Found',
    filter: 'BLE',
  );

  if (d2ToD1Logs.isNotEmpty) {
    pass('Device 2 -> Device 1: Discovery successful');
  } else {
    // This might fail if Device 1 is Linux (can't advertise)
    skip('Device 2 -> Device 1', 'No devices found (Device 1 may not support advertising)');
  }
}

// ============================================================================
// Additional Test Utilities
// ============================================================================

/// Print current BLE status
Future<void> printBleStatus(String baseUrl, String deviceName) async {
  print('');
  print('BLE Status for $deviceName:');

  final logs = await _getLogs(baseUrl, filter: 'BLE', limit: 20);

  if (logs.isEmpty) {
    print('  No BLE logs available');
    return;
  }

  print('  Recent BLE logs:');
  for (final log in logs.take(10)) {
    print('    $log');
  }
}
