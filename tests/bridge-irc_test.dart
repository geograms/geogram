#!/usr/bin/env dart
/// IRC Bridge tests for Geogram Desktop
///
/// This test suite tests the IRC bridge functionality.
/// It automatically launches a Geogram instance with IRC server enabled.
///
/// Usage:
///   dart tests/bridge-irc_test.dart
///   # or via test launcher:
///   ./tests/launch_app_tests.sh
///
/// Prerequisites:
///   - Run from the geogram-desktop directory
///   - Build CLI: ./launch-cli.sh --build-only
///   - Build desktop: flutter build linux --release

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Test configuration
const String testDataDir = '/tmp/geogram-irc-test';
const int stationPort = 17000;
const int ircPort = 17001;
String _testHost = 'localhost';

// Test results tracking
int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

// Process handles
Process? _stationProcess;

void pass(String test) {
  _passed++;
  print('  ✓ $test');
}

void fail(String test, String reason) {
  _failed++;
  _failures.add('$test: $reason');
  print('  ✗ $test - $reason');
}

void info(String message) {
  print('  ℹ $message');
}

void warn(String message) {
  print('  ⚠ $message');
}

// ============================================================
// Instance Management
// ============================================================

/// Launch the geogram-cli for station mode with IRC enabled
Future<Process?> launchStationWithIrc() async {
  // Find the CLI executable
  final executable = File('build/geogram-cli');
  if (!await executable.exists()) {
    print('ERROR: CLI build not found at ${executable.path}');
    print('Please run: ./launch-cli.sh --build-only');
    return null;
  }

  // Clean up old test data
  final testDir = Directory(testDataDir);
  if (await testDir.exists()) {
    info('Cleaning up old test data...');
    await testDir.delete(recursive: true);
  }

  final args = [
    '--port=$stationPort',
    '--data-dir=$testDataDir',
    '--new-identity',
    '--identity-type=station',
    '--skip-intro',
    '--http-api',
    '--debug-api',
    '--irc-server',
    '--irc-port=$ircPort',
    '--nickname=IRCTestStation',
  ];

  info('Starting Station CLI with IRC server...');
  info('API Port: $stationPort');
  info('IRC Port: $ircPort');
  info('Data Dir: $testDataDir');

  final process = await Process.start(
    executable.path,
    args,
    mode: ProcessStartMode.normal,
  );

  // Log output for debugging
  process.stdout.transform(utf8.decoder).listen((data) {
    if (data.trim().isNotEmpty) {
      for (final line in data.trim().split('\n')) {
        print('  [Station] $line');
      }
    }
  });

  process.stderr.transform(utf8.decoder).listen((data) {
    if (data.trim().isNotEmpty) {
      print('  [Station STDERR] ${data.trim()}');
    }
  });

  return process;
}

/// Wait for services to be ready
Future<bool> waitForServices({Duration timeout = const Duration(seconds: 15)}) async {
  info('Waiting for services to be ready...');
  final deadline = DateTime.now().add(timeout);

  // Wait for API server
  while (DateTime.now().isBefore(deadline)) {
    try {
      final client = HttpClient();
      final request = await client
          .getUrl(Uri.parse('http://$_testHost:$stationPort/api/'))
          .timeout(const Duration(seconds: 2));
      final response = await request.close();

      if (response.statusCode == 200) {
        info('✓ API server ready');
        break;
      }
    } catch (e) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  // Wait for IRC server
  while (DateTime.now().isBefore(deadline)) {
    try {
      final socket = await Socket.connect(_testHost, ircPort)
          .timeout(const Duration(seconds: 2));
      await socket.close();
      info('✓ IRC server ready');
      return true;
    } catch (e) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  return false;
}

/// Cleanup test instances
Future<void> cleanup() async {
  info('Cleaning up...');

  if (_stationProcess != null) {
    _stationProcess!.kill(ProcessSignal.sigterm);
    await _stationProcess!.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        _stationProcess!.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }

  // Clean up test data directory
  final testDir = Directory(testDataDir);
  if (await testDir.exists()) {
    await testDir.delete(recursive: true);
  }
}

// ============================================================
// IRC Protocol Helpers
// ============================================================

class IrcClient {
  Socket? _socket;
  final StreamController<String> _messages = StreamController<String>.broadcast();
  String _buffer = '';
  bool _connected = false;

  Stream<String> get messages => _messages.stream;
  bool get isConnected => _connected;

  Future<bool> connect(String host, int port, {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      _socket = await Socket.connect(host, port).timeout(timeout);
      _connected = true;

      _socket!.listen(
        (data) {
          _buffer += String.fromCharCodes(data);
          _processBuffer();
        },
        onDone: () {
          _connected = false;
          _messages.close();
        },
        onError: (error) {
          _connected = false;
          _messages.addError(error);
        },
      );

      return true;
    } catch (e) {
      _connected = false;
      return false;
    }
  }

  void _processBuffer() {
    while (_buffer.contains('\r\n')) {
      final lineEnd = _buffer.indexOf('\r\n');
      final line = _buffer.substring(0, lineEnd);
      _buffer = _buffer.substring(lineEnd + 2);

      if (line.isNotEmpty) {
        _messages.add(line);
      }
    }
  }

  void send(String message) {
    if (_socket != null && _connected) {
      _socket!.write('$message\r\n');
    }
  }

  Future<void> disconnect() async {
    if (_socket != null) {
      await _socket!.close();
      _connected = false;
    }
  }

  Future<String?> waitForMessage({
    required bool Function(String) matcher,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      return await messages
          .firstWhere(matcher)
          .timeout(timeout);
    } on TimeoutException {
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<List<String>> collectMessages({
    required bool Function(String) matcher,
    required bool Function(String) stopMatcher,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final collected = <String>[];
    final completer = Completer<List<String>>();
    StreamSubscription? sub;

    sub = messages.listen((msg) {
      if (stopMatcher(msg)) {
        sub?.cancel();
        completer.complete(collected);
      } else if (matcher(msg)) {
        collected.add(msg);
      }
    });

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      sub.cancel();
      return collected;
    } catch (e) {
      sub.cancel();
      return collected;
    }
  }
}

// ============================================================
// IRC Tests
// ============================================================

Future<void> testIrcServerAvailable() async {
  print('');
  print('Test: IRC Server Available');

  final client = IrcClient();
  final connected = await client.connect(_testHost, ircPort);

  if (!connected) {
    fail('IRC server connection', 'Could not connect to IRC server at $_testHost:$ircPort');
    return;
  }

  pass('IRC server connection');
  await client.disconnect();
}

Future<void> testNickUserRegistration() async {
  print('');
  print('Test: NICK and USER Registration');

  final client = IrcClient();
  if (!await client.connect(_testHost, ircPort)) {
    fail('Connect for registration', 'Connection failed');
    return;
  }

  // Send NICK command
  client.send('NICK TestUser');

  // Send USER command
  client.send('USER testuser 0 * :Test User');

  // Wait for welcome message (001)
  final welcome = await client.waitForMessage(
    matcher: (msg) => msg.contains(' 001 '),
    timeout: const Duration(seconds: 5),
  );

  if (welcome != null) {
    pass('NICK/USER registration');
  } else {
    fail('NICK/USER registration', 'No welcome message received');
  }

  await client.disconnect();
}

Future<void> testPingPong() async {
  print('');
  print('Test: PING/PONG Keep-Alive');

  final client = IrcClient();
  if (!await client.connect(_testHost, ircPort)) {
    fail('Connect for PING', 'Connection failed');
    return;
  }

  // Register first
  client.send('NICK PingTest');
  client.send('USER pingtest 0 * :Ping Test');

  // Wait for welcome
  await client.waitForMessage(matcher: (msg) => msg.contains(' 001 '));

  // Send PING
  client.send('PING :test');

  // Wait for PONG
  final pong = await client.waitForMessage(
    matcher: (msg) => msg.contains('PONG'),
    timeout: const Duration(seconds: 3),
  );

  if (pong != null && pong.contains(':test')) {
    pass('PING/PONG');
  } else {
    fail('PING/PONG', 'No valid PONG response');
  }

  await client.disconnect();
}

Future<void> testListChannels() async {
  print('');
  print('Test: LIST Channels');

  final client = IrcClient();
  if (!await client.connect(_testHost, ircPort)) {
    fail('Connect for LIST', 'Connection failed');
    return;
  }

  // Register
  client.send('NICK ListTest');
  client.send('USER listtest 0 * :List Test');
  await client.waitForMessage(matcher: (msg) => msg.contains(' 001 '));

  // Send LIST command
  client.send('LIST');

  // Collect channel list (322) until end of list (323)
  final channels = await client.collectMessages(
    matcher: (msg) => msg.contains(' 322 '),
    stopMatcher: (msg) => msg.contains(' 323 '),
    timeout: const Duration(seconds: 5),
  );

  if (channels.isNotEmpty) {
    pass('LIST channels (${channels.length} channels)');
    info('Sample: ${channels.first}');
  } else {
    fail('LIST channels', 'No channels received');
  }

  await client.disconnect();
}

Future<void> testJoinChannel() async {
  print('');
  print('Test: JOIN Channel');

  final client = IrcClient();
  if (!await client.connect(_testHost, ircPort)) {
    fail('Connect for JOIN', 'Connection failed');
    return;
  }

  // Register
  client.send('NICK JoinTest');
  client.send('USER jointest 0 * :Join Test');
  await client.waitForMessage(matcher: (msg) => msg.contains(' 001 '));

  // Join #main channel
  client.send('JOIN #main');

  // Wait for JOIN confirmation (either our own JOIN message or NAMES list)
  final joinMsg = await client.waitForMessage(
    matcher: (msg) =>
        msg.contains('JOIN #main') ||
        msg.contains(' 353 ') ||  // NAMES list
        msg.contains(' 366 '),    // End of NAMES
    timeout: const Duration(seconds: 5),
  );

  if (joinMsg != null) {
    pass('JOIN #main');
  } else {
    fail('JOIN #main', 'No JOIN confirmation');
  }

  await client.disconnect();
}

Future<void> testSendMessage() async {
  print('');
  print('Test: Send Message (IRC → Geogram)');

  final client = IrcClient();
  if (!await client.connect(_testHost, ircPort)) {
    fail('Connect for PRIVMSG', 'Connection failed');
    return;
  }

  // Register
  final nick = 'MsgTest${DateTime.now().millisecondsSinceEpoch % 1000}';
  client.send('NICK $nick');
  client.send('USER msgtest 0 * :Message Test');
  await client.waitForMessage(matcher: (msg) => msg.contains(' 001 '));

  // Join channel
  client.send('JOIN #main');
  await client.waitForMessage(
    matcher: (msg) => msg.contains('JOIN #main') || msg.contains(' 353 '),
  );

  // Send message
  final testMessage = 'Test message from IRC ${DateTime.now().millisecondsSinceEpoch}';
  client.send('PRIVMSG #main :$testMessage');

  // Wait a bit for the message to be processed
  await Future.delayed(const Duration(milliseconds: 500));

  // Check if message was stored via API
  try {
    final response = await HttpClient()
        .getUrl(Uri.parse('http://$_testHost:$stationPort/api/chat/main/messages?limit=10'))
        .then((request) => request.close())
        .then((response) => response.transform(utf8.decoder).join());

    final data = jsonDecode(response);
    final messages = data['messages'] as List;

    final found = messages.any((m) =>
        m['content'] != null &&
        m['content'].toString().contains(testMessage));

    if (found) {
      pass('Send message (IRC → Geogram)');
    } else {
      fail('Send message (IRC → Geogram)', 'Message not found in Geogram chat');
    }
  } catch (e) {
    fail('Send message (IRC → Geogram)', 'API check failed: $e');
  }

  await client.disconnect();
}

Future<void> testReceiveMessage() async {
  print('');
  print('Test: Receive Message (Geogram → IRC)');

  final client = IrcClient();
  if (!await client.connect(_testHost, ircPort)) {
    fail('Connect for receive', 'Connection failed');
    return;
  }

  // Register
  client.send('NICK RecvTest');
  client.send('USER recvtest 0 * :Receive Test');
  await client.waitForMessage(matcher: (msg) => msg.contains(' 001 '));

  // Join channel
  client.send('JOIN #main');
  await client.waitForMessage(
    matcher: (msg) => msg.contains('JOIN #main') || msg.contains(' 353 '),
  );

  // Post message via Geogram API
  final testMessage = 'Test from Geogram ${DateTime.now().millisecondsSinceEpoch}';

  try {
    final httpClient = HttpClient();
    final request = await httpClient.postUrl(
      Uri.parse('http://$_testHost:$stationPort/api/chat/main/messages'),
    );
    request.headers.set('Content-Type', 'application/json');
    request.write(jsonEncode({'content': testMessage}));
    await request.close();

    // Wait for IRC message
    final ircMsg = await client.waitForMessage(
      matcher: (msg) => msg.contains('PRIVMSG #main') && msg.contains(testMessage),
      timeout: const Duration(seconds: 10),
    );

    if (ircMsg != null) {
      pass('Receive message (Geogram → IRC)');
      info('Received: $ircMsg');
    } else {
      fail('Receive message (Geogram → IRC)', 'Message not received in IRC');
    }
  } catch (e) {
    fail('Receive message (Geogram → IRC)', 'API post failed: $e');
  }

  await client.disconnect();
}

Future<void> testChannelNaming() async {
  print('');
  print('Test: Channel Naming Convention');

  final client = IrcClient();
  if (!await client.connect(_testHost, ircPort)) {
    fail('Connect for naming', 'Connection failed');
    return;
  }

  // Register
  client.send('NICK NamingTest');
  client.send('USER namingtest 0 * :Naming Test');
  await client.waitForMessage(matcher: (msg) => msg.contains(' 001 '));

  // Get channel list
  client.send('LIST');

  final channels = await client.collectMessages(
    matcher: (msg) => msg.contains(' 322 '),
    stopMatcher: (msg) => msg.contains(' 323 '),
  );

  // Check for station rooms (format: #roomId)
  final stationRooms = channels.where((ch) =>
      ch.contains(' #main ') ||
      ch.contains(' #announcements ') ||
      ch.contains(' #general ')
  ).toList();

  // Check for device rooms (format: #CALLSIGN-roomId)
  final deviceRooms = channels.where((ch) =>
      RegExp(r' #X[13][A-Z0-9]+-\w+ ').hasMatch(ch)
  ).toList();

  if (stationRooms.isNotEmpty) {
    pass('Channel naming (station rooms)');
    info('Found ${stationRooms.length} station rooms');
  } else {
    info('No station rooms found (may not be configured)');
  }

  if (deviceRooms.isNotEmpty) {
    pass('Channel naming (device rooms)');
    info('Found ${deviceRooms.length} device rooms');
  } else {
    info('No device rooms found (no connected devices)');
  }

  await client.disconnect();
}

Future<void> testNickCollision() async {
  print('');
  print('Test: Nick Collision Detection');

  final client1 = IrcClient();
  final client2 = IrcClient();

  if (!await client1.connect(_testHost, ircPort)) {
    fail('Connect client 1', 'Connection failed');
    return;
  }

  if (!await client2.connect(_testHost, ircPort)) {
    fail('Connect client 2', 'Connection failed');
    await client1.disconnect();
    return;
  }

  // Register first client
  client1.send('NICK SameNick');
  client1.send('USER user1 0 * :User 1');
  await client1.waitForMessage(matcher: (msg) => msg.contains(' 001 '));

  // Try to register second client with same nick
  client2.send('NICK SameNick');
  client2.send('USER user2 0 * :User 2');

  // Wait for nick collision error (433)
  final collision = await client2.waitForMessage(
    matcher: (msg) => msg.contains(' 433 '),
    timeout: const Duration(seconds: 3),
  );

  if (collision != null) {
    pass('Nick collision detection');
  } else {
    fail('Nick collision detection', 'No 433 error received');
  }

  await client1.disconnect();
  await client2.disconnect();
}

// ============================================================
// Main
// ============================================================

Future<void> main(List<String> args) async {
  print('');
  print('=' * 60);
  print('IRC Bridge Test Suite');
  print('=' * 60);
  print('');

  print('Configuration:');
  print('  API Port: $stationPort');
  print('  IRC Port: $ircPort');
  print('  Data Dir: $testDataDir');
  print('');

  // Register cleanup handler
  ProcessSignal.sigint.watch().listen((_) async {
    print('\nReceived interrupt signal, cleaning up...');
    await cleanup();
    exit(1);
  });

  // Launch station with IRC server
  print('Launching Geogram Station with IRC server...');
  _stationProcess = await launchStationWithIrc();

  if (_stationProcess == null) {
    print('');
    print('❌ Failed to launch station');
    print('   Make sure the CLI is built: ./launch-cli.sh --build-only');
    exit(1);
  }

  // Wait for services to be ready
  final servicesReady = await waitForServices();
  if (!servicesReady) {
    print('');
    print('❌ Services did not start within timeout');
    print('   Check the station logs above for errors');
    await cleanup();
    exit(1);
  }

  print('');
  info('All services ready, starting tests...');
  print('');

  try {
    // Run tests
    await testIrcServerAvailable();
    await testNickUserRegistration();
    await testPingPong();
    await testListChannels();
    await testJoinChannel();
    await testSendMessage();
    await testReceiveMessage();
    await testChannelNaming();
    await testNickCollision();
  } catch (e) {
    print('');
    print('❌ Test execution error: $e');
    _failed++;
  } finally {
    // Cleanup
    await cleanup();
  }

  // Summary
  print('');
  print('=' * 60);
  print('Test Results');
  print('=' * 60);
  print('Passed: $_passed');
  print('Failed: $_failed');

  if (_failures.isNotEmpty) {
    print('');
    print('Failures:');
    for (final failure in _failures) {
      print('  - $failure');
    }
  }

  print('');
  print('Test data cleaned up: $testDataDir');
  print('');

  exit(_failed > 0 ? 1 : 0);
}
