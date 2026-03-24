// ignore_for_file: avoid_print
//
// Standalone DHT signaling test.
//
// Verifies that custom geogram signaling messages can be exchanged over the
// DHT rendezvous socket and parsed back into normal JSON-like maps.
import 'dart:io';

import 'package:geogram/p2p/dht_node.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool condition) {
  if (condition) {
    _passed++;
    print('  OK  $name');
  } else {
    _failed++;
    print('  FAIL  $name');
  }
}

Future<void> main() async {
  print('=== DHT Signaling Test ===');

  final nodeA = DhtNode();
  final nodeB = DhtNode();

  await nodeA.start();
  await nodeB.start();

  nodeA.geogramCallsign = 'X1TEST';
  nodeB.geogramCallsign = 'X2TEST';

  Map<String, dynamic>? receivedByA;
  Map<String, dynamic>? receivedByB;

  nodeA.onGeogramSignal = (signal, ip, udpPort) {
    print('  Node A received ${signal['type']} from $ip:$udpPort');
    receivedByA = signal;
  };
  nodeB.onGeogramSignal = (signal, ip, udpPort) {
    print('  Node B received ${signal['type']} from $ip:$udpPort');
    receivedByB = signal;
  };

  final largeSdp = [
    'v=0',
    'o=- 1 2 IN IP4 127.0.0.1',
    for (var i = 0; i < 80; i++)
      'a=candidate:$i 1 udp 2122252543 203.0.113.${i % 10} ${5000 + i} typ srflx',
  ].join('\r\n');

  final offerSent = await nodeA.sendGeogramSignal(
    '127.0.0.1',
    nodeB.localPort,
    {
      'type': 'webrtc_offer',
      'from_callsign': 'X1TEST',
      'to_callsign': 'X2TEST',
      'session_id': 'session-1',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'sdp': {'type': 'offer', 'sdp': largeSdp},
    },
  );
  await Future.delayed(const Duration(milliseconds: 200));

  _check('Offer acknowledged', offerSent);
  _check('Node B received offer', receivedByB?['type'] == 'webrtc_offer');
  _check(
    'Offer keeps source callsign',
    receivedByB?['from_callsign'] == 'X1TEST',
  );
  _check(
    'Offer keeps nested SDP map',
    (receivedByB?['sdp'] as Map<String, dynamic>?)?['type'] == 'offer',
  );
  _check(
    'Large SDP survives DHT chunking',
    (receivedByB?['sdp'] as Map<String, dynamic>?)?['sdp'] == largeSdp,
  );

  receivedByA = null;
  final iceSent = await nodeB.sendGeogramSignal('127.0.0.1', nodeA.localPort, {
    'type': 'webrtc_ice',
    'from_callsign': 'X2TEST',
    'to_callsign': 'X1TEST',
    'session_id': 'session-1',
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'candidate': {
      'candidate': 'candidate:1 1 udp 2122252543 127.0.0.1 9999 typ host',
      'sdpMid': null,
      'sdpMLineIndex': 0,
    },
  });
  await Future.delayed(const Duration(milliseconds: 200));

  final candidate = receivedByA?['candidate'] as Map<String, dynamic>?;
  _check('ICE acknowledged', iceSent);
  _check('Node A received ICE candidate', receivedByA?['type'] == 'webrtc_ice');
  _check('ICE candidate preserved', candidate?['candidate'] != null);
  _check(
    'Null fields stripped before bencode',
    candidate != null && !candidate.containsKey('sdpMid'),
  );

  receivedByB = null;
  final ignoredSent = await nodeA
      .sendGeogramSignal('127.0.0.1', nodeB.localPort, {
        'type': 'webrtc_bye',
        'from_callsign': 'X1TEST',
        'to_callsign': 'NOT-X2TEST',
        'session_id': 'session-1',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
  await Future.delayed(const Duration(milliseconds: 200));

  _check('Wrong-target signal still acknowledged', ignoredSent);
  _check('Wrong-target signal ignored by receiver', receivedByB == null);

  await nodeA.stop();
  await nodeB.stop();
  nodeA.dispose();
  nodeB.dispose();

  print('PASSED: $_passed');
  print('FAILED: $_failed');
  exit(_failed == 0 ? 0 : 1);
}
