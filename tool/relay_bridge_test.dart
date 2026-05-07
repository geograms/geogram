// Standalone validation of the BT-DHT-v2 §10 relay byte-bridge.
//
// Spawns two RelayClient instances against the same relay (the Android
// station, reached via `adb forward tcp:39999 -> android:relay_port`).
// One side calls openSession(local=A, remote=B, sid=X), the other
// openSession(local=B, remote=A, sid=X). The relay should pair them
// and forward DATA bytes A->B and B->A.
//
// Note: RelayClient.openSession's completer only fires when DATA
// arrives (the spec uses the first DATA frame to confirm the bridge).
// The test starts both openSessions in parallel without awaiting them,
// gives the relay 800ms to pair the halves, sends a DATA frame each
// way, then asserts both sides received the payload.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:geogram/p2p/relay/relay_client.dart';

const _host = '127.0.0.1';
const _port = 39999;

const _npubA = 'npub1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaq';
const _npubB = 'npub1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbq';

void main() async {
  print('PHASE-4 RELAY BRIDGE TEST');
  print('relay endpoint: $_host:$_port');

  final sessionId = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  print('session id: ${_hex(sessionId)}');

  final clientA = RelayClient(host: _host, port: _port);
  final clientB = RelayClient(host: _host, port: _port);

  final aRecv = <Uint8List>[];
  final bRecv = <Uint8List>[];
  clientA.incoming.listen((bytes) {
    aRecv.add(bytes);
    print('A <- relay: ${bytes.length} bytes "${String.fromCharCodes(bytes)}"');
  });
  clientB.incoming.listen((bytes) {
    bRecv.add(bytes);
    print('B <- relay: ${bytes.length} bytes "${String.fromCharCodes(bytes)}"');
  });

  print('\n[1] connect A and B');
  await Future.wait<void>([clientA.connect(), clientB.connect()]);
  print('A=${clientA.state.name}, B=${clientB.state.name}');

  print('\n[2] both call openSession (fire-and-forget; completer fires on first DATA)');
  unawaited(clientA
      .openSession(
        localNpubHex: _npubA,
        remoteNpubHex: _npubB,
        sessionId: sessionId,
      )
      .catchError((Object e) => print('A.openSession completer: $e')));

  // Stagger so the half-session matching is exercised in both orders.
  await Future<void>.delayed(const Duration(milliseconds: 200));

  unawaited(clientB
      .openSession(
        localNpubHex: _npubB,
        remoteNpubHex: _npubA,
        sessionId: sessionId,
      )
      .catchError((Object e) => print('B.openSession completer: $e')));

  // Let the relay pair the two halves.
  await Future<void>.delayed(const Duration(milliseconds: 800));
  print('after pair window: A=${clientA.state.name}, B=${clientB.state.name}');

  print('\n[3] A -> B "hello from A"');
  clientA.send(Uint8List.fromList('hello from A'.codeUnits));
  await Future<void>.delayed(const Duration(milliseconds: 500));

  print('\n[4] B -> A "ack from B"');
  clientB.send(Uint8List.fromList('ack from B'.codeUnits));
  await Future<void>.delayed(const Duration(milliseconds: 500));

  print('\n[5] results');
  print('A received: ${aRecv.length} frame(s)');
  print('B received: ${bRecv.length} frame(s)');

  bool pass = true;
  if (bRecv.isEmpty || String.fromCharCodes(bRecv.first) != 'hello from A') {
    print('FAIL: B did not receive A->B payload');
    pass = false;
  }
  if (aRecv.isEmpty || String.fromCharCodes(aRecv.first) != 'ack from B') {
    print('FAIL: A did not receive B->A payload');
    pass = false;
  }

  print('\n[6] cleanup');
  await clientA.disconnect();
  await clientB.disconnect();

  print(pass
      ? '\nRESULT: PASS - relay bridged bytes both directions'
      : '\nRESULT: FAIL');
  exit(pass ? 0 : 1);
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
