// Test signature verification for chat messages
import 'dart:convert';
import '../lib/util/nostr_crypto.dart';
import '../lib/util/nostr_event.dart';

void main() {
  // Test message data from the chat file - X1QVM3 (desktop) message
  final npub = 'npub1qvm3ta3gjx8jxn8u67a6anvd2g2dah60srs0ftvravlcuy986nvs4p24xu';
  final nsec = ''; // Don't have the private key
  final signature = '1fda1438fbacea38f7883f00ae671b1af26e0368ec74cdfeaec3ea4d1dd7a08360e2cf8dd4d6736f1b47dad76ee3015a596110ef60b45ca30f087f9a5d1c0bbc';
  final content = 'is this green?';
  final timestampStr = '2025-12-05 14:22_31';
  final callsign = 'X1QVM3';
  final roomId = 'general';

  print('=== Testing NOSTR signature verification ===\n');

  // Parse timestamp like _parseTimestamp does
  final parts = timestampStr.split(' ');
  final dateParts = parts[0].split('-');
  final timeParts = parts[1].replaceAll('_', ':').split(':');
  final timestamp = DateTime.utc(
    int.parse(dateParts[0]),
    int.parse(dateParts[1]),
    int.parse(dateParts[2]),
    int.parse(timeParts[0]),
    int.parse(timeParts[1]),
    int.parse(timeParts[2]),
  );

  final createdAt = timestamp.millisecondsSinceEpoch ~/ 1000;
  final pubkey = NostrCrypto.decodeNpub(npub);

  print('Input data:');
  print('  npub: $npub');
  print('  pubkey (hex): $pubkey');
  print('  timestamp string: $timestampStr');
  print('  DateTime: $timestamp');
  print('  createdAt (unix): $createdAt');
  print('  content: "$content"');
  print('  roomId: $roomId');
  print('  callsign: $callsign');
  print('  signature: $signature');
  print('');

  // Reconstruct event like _reconstructNostrEvent does
  final tags = [['t', 'chat'], ['room', roomId], ['callsign', callsign]];

  final event = NostrEvent(
    pubkey: pubkey,
    createdAt: createdAt,
    kind: 1,
    tags: tags,
    content: content,
    sig: signature,
  );

  // Calculate ID
  event.calculateId();

  print('Reconstructed event:');
  print('  id: ${event.id}');
  print('  Serialization: ${jsonEncode([0, pubkey, createdAt, 1, tags, content])}');
  print('');

  // Verify
  final verified = event.verify();
  print('Verification result: $verified');
  print('');

  // Now let's create a NEW signature and compare
  print('=== Creating new signature for comparison ===\n');

  final newEvent = NostrEvent(
    pubkey: pubkey,
    createdAt: createdAt,
    kind: 1,
    tags: tags,
    content: content,
  );
  newEvent.calculateId();
  newEvent.signWithNsec(nsec);

  print('New event:');
  print('  id: ${newEvent.id}');
  print('  sig: ${newEvent.sig}');
  print('  verified: ${newEvent.verify()}');
  print('');

  // Compare IDs - if they match, signature should verify
  print('IDs match: ${event.id == newEvent.id}');
  print('');

  // Try verifying the stored signature against the new event ID
  if (event.id != newEvent.id) {
    print('ERROR: Event IDs don\'t match!');
    print('  Stored event ID: ${event.id}');
    print('  Recalculated ID: ${newEvent.id}');
    print('');
    print('This means the parameters used for signing differ from verification.');
  }
}
