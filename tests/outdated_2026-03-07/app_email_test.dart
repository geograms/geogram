#!/usr/bin/env dart
/// Geogram Desktop Email App Test Suite
///
/// This test file verifies Email functionality via the Debug API.
/// It launches:
///   - A station instance (CLI) at /tmp/geogram-email-station (port 17000)
///   - A client instance (GUI) at /tmp/geogram-email-clientA (port 17100)
///
/// The test verifies:
///   - Email compose (draft creation)
///   - Email send (with WebSocket delivery)
///   - Email list (viewing folders)
///   - Email status
///
/// Usage:
///   dart run tests/app_email_test.dart
///
/// Prerequisites:
///   - Build CLI: ./launch-cli.sh --build-only
///   - Build desktop: flutter build linux --release
///   - Run from the geogram-desktop directory

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

// ============================================================
// Configuration
// ============================================================

/// Fixed temp directories for easy debugging and inspection
const String stationDataDir = '/tmp/geogram-email-station';
const String clientADataDir = '/tmp/geogram-email-clientA';

/// Ports for the instances
const int stationPort = 17000;
const int clientAPort = 17100;

/// Timing configuration
const Duration startupWait = Duration(seconds: 12);
const Duration connectionWait = Duration(seconds: 3);
const Duration apiWait = Duration(seconds: 2);

// ============================================================
// Test State
// ============================================================

/// Test results tracking
int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

/// Process handles for cleanup
Process? _stationProcess;
Process? _clientAProcess;

/// Instance information
String? _stationCallsign;
String? _clientACallsign;

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

/// Launch the geogram-cli for station mode
Future<Process?> launchStationCli({
  required int port,
  required String dataDir,
  String? nickname,
}) async {
  const executableCandidates = [
    'build/geogram-cli',
    'geogram-cli',
  ];
  File? executable;
  for (final candidate in executableCandidates) {
    final file = File(candidate);
    if (await file.exists()) {
      executable = file;
      break;
    }
  }

  if (executable == null) {
    print('ERROR: CLI build not found at ${executableCandidates.join(' or ')}');
    print('Please run: ./launch-cli.sh --build-only');
    return null;
  }

  final args = [
    '--port=$port',
    '--data-dir=$dataDir',
    '--new-identity',
    '--identity-type=station',
    '--skip-intro',
    if (nickname != null) '--nickname=$nickname',
  ];

  info('Starting Station CLI on port $port...');
  info('Data directory: $dataDir');
  info('Args: ${args.join(' ')}');

  final process = await Process.start(
    executable.absolute.path,
    args,
    mode: ProcessStartMode.normal,
  );

  // Log output for debugging
  process.stdout.transform(utf8.decoder).listen((data) {
    for (final line in data.split('\n')) {
      if (line.isNotEmpty) {
        print('  [STATION] $line');
      }
    }
  });

  process.stderr.transform(utf8.decoder).listen((data) {
    for (final line in data.split('\n')) {
      if (line.isNotEmpty) {
        print('  [STATION ERR] $line');
      }
    }
  });

  return process;
}

/// Launch the geogram-desktop client
Future<Process?> launchDesktopClient({
  required int port,
  required String dataDir,
  required String name,
}) async {
  const executableCandidates = [
    'build/linux/x64/release/bundle/geogram',
    'build/linux/arm64/release/bundle/geogram',
    'geogram',
  ];
  File? executable;
  for (final candidate in executableCandidates) {
    final file = File(candidate);
    if (await file.exists()) {
      executable = file;
      break;
    }
  }

  if (executable == null) {
    print('ERROR: Desktop build not found at ${executableCandidates.join(' or ')}');
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
    '--nickname=$name',
  ];

  info('Starting Desktop Client "$name" on port $port...');
  info('Data directory: $dataDir');
  info('Args: ${args.join(' ')}');

  final process = await Process.start(
    executable.absolute.path,
    args,
    mode: ProcessStartMode.normal,
    environment: {'DISPLAY': Platform.environment['DISPLAY'] ?? ':0'},
  );

  // Log output for debugging
  process.stdout.transform(utf8.decoder).listen((data) {
    for (final line in data.split('\n')) {
      if (line.isNotEmpty && !line.contains('flutter:')) {
        print('  [$name] $line');
      }
    }
  });

  process.stderr.transform(utf8.decoder).listen((data) {
    for (final line in data.split('\n')) {
      if (line.isNotEmpty) {
        print('  [$name ERR] $line');
      }
    }
  });

  return process;
}

/// Wait for an instance to be ready
Future<bool> waitForReady(String name, int port,
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
          info('$name ready (${data['callsign']})');
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

/// Get callsign from instance
Future<String?> getCallsign(int port) async {
  for (final path in ['/api/status', '/api/']) {
    try {
      final response = await http.get(Uri.parse('http://localhost:$port$path'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['callsign'] as String?;
      }
    } catch (e) {
      // Try next
    }
  }
  return null;
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

/// Connect a client to the station
Future<bool> connectToStation(int clientPort) async {
  final result = await debugAction(clientPort, {
    'action': 'station_connect',
    'url': 'ws://localhost:$stationPort',
  });
  info('Connection result: ${result?['message'] ?? 'unknown'}');
  return result?['success'] == true || result?['connected'] == true;
}

// ============================================================
// Setup and Cleanup
// ============================================================

/// Prepare temp directories
Future<void> prepareDirectories() async {
  for (final path in [stationDataDir, clientADataDir]) {
    final rmResult = await Process.run('rm', ['-rf', path]);
    if (rmResult.exitCode != 0) {
      warn('Failed to remove $path: ${rmResult.stderr}');
    } else {
      info('Removed existing directory: $path');
    }

    final dir = Directory(path);
    await dir.create(recursive: true);
    info('Created directory: $path');
  }
}

/// Cleanup all processes
Future<void> cleanup() async {
  section('Cleanup');

  if (_clientAProcess != null) {
    info('Stopping Client A...');
    _clientAProcess!.kill(ProcessSignal.sigterm);
    try {
      await _clientAProcess!.exitCode.timeout(const Duration(seconds: 5));
    } catch (e) {
      _clientAProcess!.kill(ProcessSignal.sigkill);
    }
  }

  if (_stationProcess != null) {
    info('Stopping Station...');
    _stationProcess!.kill(ProcessSignal.sigterm);
    try {
      await _stationProcess!.exitCode.timeout(const Duration(seconds: 5));
    } catch (e) {
      _stationProcess!.kill(ProcessSignal.sigkill);
    }
  }

  info('Cleanup complete');
}

// ============================================================
// Tests
// ============================================================

/// Test email_status action
Future<void> testEmailStatus() async {
  section('Test: email_status');

  final result = await debugAction(clientAPort, {'action': 'email_status'});

  if (result == null) {
    fail('email_status', 'No response received');
    return;
  }

  if (result['success'] == true) {
    pass('email_status returned success');
    info('Service initialized: ${result['service_initialized']}');
    info('WebSocket connected: ${result['websocket_connected']}');
    info('Preferred station: ${result['preferred_station']}');
  } else {
    fail('email_status', 'Failed: ${result['error']}');
  }
}

/// Test email_compose action
Future<void> testEmailCompose() async {
  section('Test: email_compose');

  final result = await debugAction(clientAPort, {
    'action': 'email_compose',
    'to': 'test@example.com',
    'subject': 'Test Draft Email',
    'content': 'This is a test draft created via debug API.',
  });

  if (result == null) {
    fail('email_compose', 'No response received');
    return;
  }

  if (result['success'] == true) {
    pass('email_compose created draft successfully');
    info('Thread ID: ${result['thread_id']}');
    info('From: ${result['from']}');
    info('To: ${result['to']}');
    info('Subject: ${result['subject']}');
    info('Station: ${result['station']}');
  } else {
    fail('email_compose', 'Failed: ${result['error']}');
  }
}

/// Test email_send action
Future<void> testEmailSend() async {
  section('Test: email_send');

  final result = await debugAction(clientAPort, {
    'action': 'email_send',
    'to': 'bogus@test-external.example.com',
    'subject': 'Test Email from Debug API',
    'content': 'This is a test email sent via the email_send debug action.\n\nIt should be queued for delivery to the station.',
  });

  if (result == null) {
    fail('email_send', 'No response received');
    return;
  }

  if (result['success'] == true) {
    pass('email_send queued email successfully');
    info('Thread ID: ${result['thread_id']}');
    info('From: ${result['from']}');
    info('To: ${result['to']}');
    info('Subject: ${result['subject']}');
    info('Station: ${result['station']}');
    info('Delivery Status: ${result['delivery_status']}');
    info('WebSocket Connected: ${result['websocket_connected']}');
  } else {
    fail('email_send', 'Failed: ${result['error']}');
  }
}

/// Test email_list action
Future<void> testEmailList() async {
  section('Test: email_list');

  // Test listing outbox
  final outboxResult = await debugAction(clientAPort, {
    'action': 'email_list',
    'folder': 'outbox',
  });

  if (outboxResult == null) {
    fail('email_list outbox', 'No response received');
  } else if (outboxResult['success'] == true) {
    pass('email_list outbox returned successfully');
    info('Folder: ${outboxResult['folder']}');
    info('Count: ${outboxResult['count']}');
    final threads = outboxResult['threads'] as List? ?? [];
    for (final thread in threads) {
      info('  - ${thread['subject']} (${thread['status']})');
    }
  } else {
    fail('email_list outbox', 'Failed: ${outboxResult['error']}');
  }

  // Test listing drafts
  final draftsResult = await debugAction(clientAPort, {
    'action': 'email_list',
    'folder': 'drafts',
  });

  if (draftsResult == null) {
    fail('email_list drafts', 'No response received');
  } else if (draftsResult['success'] == true) {
    pass('email_list drafts returned successfully');
    info('Folder: ${draftsResult['folder']}');
    info('Count: ${draftsResult['count']}');
  } else {
    fail('email_list drafts', 'Failed: ${draftsResult['error']}');
  }
}

/// Test email with CC recipients
Future<void> testEmailWithCC() async {
  section('Test: email_send with CC');

  final result = await debugAction(clientAPort, {
    'action': 'email_send',
    'to': 'primary@example.com',
    'cc': 'cc1@example.com, cc2@example.com',
    'subject': 'Test Email with CC',
    'content': 'This email has CC recipients.',
  });

  if (result == null) {
    fail('email_send with CC', 'No response received');
    return;
  }

  if (result['success'] == true) {
    pass('email_send with CC queued successfully');
    info('To: ${result['to']}');
  } else {
    fail('email_send with CC', 'Failed: ${result['error']}');
  }
}

// ============================================================
// Main
// ============================================================

Future<void> main() async {
  print('\n\x1B[1;34m╔════════════════════════════════════════════════════════════╗\x1B[0m');
  print('\x1B[1;34m║          Geogram Email Debug API Test Suite                 ║\x1B[0m');
  print('\x1B[1;34m╚════════════════════════════════════════════════════════════╝\x1B[0m\n');

  try {
    // Setup
    section('Setup');
    await prepareDirectories();

    // Launch station
    _stationProcess = await launchStationCli(
      port: stationPort,
      dataDir: stationDataDir,
      nickname: 'email-station',
    );
    if (_stationProcess == null) {
      print('ERROR: Failed to launch station');
      exit(1);
    }

    info('Waiting for station to start...');
    await Future.delayed(startupWait);

    if (!await waitForReady('Station', stationPort)) {
      print('ERROR: Station failed to start');
      await cleanup();
      exit(1);
    }

    _stationCallsign = await getCallsign(stationPort);
    info('Station callsign: $_stationCallsign');

    // Launch client
    _clientAProcess = await launchDesktopClient(
      port: clientAPort,
      dataDir: clientADataDir,
      name: 'email-client',
    );
    if (_clientAProcess == null) {
      print('ERROR: Failed to launch client');
      await cleanup();
      exit(1);
    }

    info('Waiting for client to start...');
    await Future.delayed(startupWait);

    if (!await waitForReady('Client', clientAPort)) {
      print('ERROR: Client failed to start');
      await cleanup();
      exit(1);
    }

    _clientACallsign = await getCallsign(clientAPort);
    info('Client callsign: $_clientACallsign');

    // Connect client to station
    section('Connect to Station');
    info('Connecting client to station...');
    await connectToStation(clientAPort);
    await Future.delayed(connectionWait);

    // Run tests
    await testEmailStatus();
    await Future.delayed(apiWait);

    await testEmailCompose();
    await Future.delayed(apiWait);

    await testEmailSend();
    await Future.delayed(apiWait);

    await testEmailList();
    await Future.delayed(apiWait);

    await testEmailWithCC();

    // Summary
    section('Test Summary');
    print('\n  \x1B[32mPassed: $_passed\x1B[0m');
    print('  \x1B[31mFailed: $_failed\x1B[0m');

    if (_failures.isNotEmpty) {
      print('\n  \x1B[31mFailures:\x1B[0m');
      for (final failure in _failures) {
        print('    - $failure');
      }
    }

    // Cleanup
    await cleanup();

    // Exit with appropriate code
    exit(_failed > 0 ? 1 : 0);
  } catch (e, stack) {
    print('\n\x1B[31mFATAL ERROR: $e\x1B[0m');
    print(stack);
    await cleanup();
    exit(1);
  }
}
