/*
 * APRS-IS live connection test.
 *
 * Usage:
 *   dart run tests/aprs_is_test.dart CR7BBQ
 *   dart run tests/aprs_is_test.dart CR7BBQ-5 --seconds 60
 *
 * 1. Computes passcode for the given callsign
 * 2. Connects to rotate.aprs2.net:10152
 * 3. Sends login with real passcode
 * 4. Prints received packets for N seconds (default 30)
 * 5. Disconnects and exits
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:geogram/teleport/aprs/aprs_is_client.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart run tests/aprs_is_test.dart CALLSIGN [--seconds N]');
    print('');
    print('Example: dart run tests/aprs_is_test.dart CR7BBQ-5');
    exit(64);
  }

  final callsign = args[0].toUpperCase();
  int seconds = 30;

  for (int i = 1; i < args.length; i++) {
    if (args[i] == '--seconds' && i + 1 < args.length) {
      seconds = int.tryParse(args[i + 1]) ?? 30;
    }
  }

  final passcode = AprsIsClient.aprsPasscode(callsign);
  print('Callsign: $callsign');
  print('Passcode: $passcode');
  print('Server:   rotate.aprs2.net:10152');
  print('Duration: ${seconds}s');
  print('---');

  Socket? socket;
  StreamSubscription<List<int>>? sub;
  int packetCount = 0;
  bool verified = false;
  final buffer = StringBuffer();

  try {
    socket = await Socket.connect(
      'rotate.aprs2.net',
      10152,
      timeout: const Duration(seconds: 15),
    );
    print('[+] Connected');

    sub = socket.listen(
      (data) {
        buffer.write(utf8.decode(data, allowMalformed: true));
        final text = buffer.toString();
        final lines = text.split('\n');

        buffer.clear();
        if (!text.endsWith('\n')) {
          buffer.write(lines.removeLast());
        } else if (lines.isNotEmpty && lines.last.isEmpty) {
          lines.removeLast();
        }

        for (final raw in lines) {
          final line = raw.replaceAll('\r', '').trim();
          if (line.isEmpty) continue;

          if (line.startsWith('#')) {
            print('[server] $line');
            if (line.contains('logresp') && line.contains('verified')) {
              verified = true;
              print('[+] Login VERIFIED');
            }
          } else {
            packetCount++;
            // Show first 20 packets in full, then just count
            if (packetCount <= 20) {
              print('[pkt $packetCount] $line');
            } else if (packetCount % 50 == 0) {
              print('[...] $packetCount packets received so far');
            }
          }
        }
      },
      onError: (e) => print('[!] Socket error: $e'),
      onDone: () => print('[!] Socket closed by server'),
    );

    // Send login
    final loginLine =
        'user $callsign pass $passcode vers Geogram 1.0 filter r/0/0/500';
    print('[>] $loginLine');
    socket.write('$loginLine\r\n');
    await socket.flush();

    // Wait for duration
    await Future.delayed(Duration(seconds: seconds));

    print('---');
    print('Total packets received: $packetCount');
    print('Login verified: $verified');
  } catch (e) {
    print('[!] Error: $e');
  } finally {
    await sub?.cancel();
    socket?.destroy();
    print('[+] Disconnected');
  }
}
