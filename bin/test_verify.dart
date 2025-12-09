// Test signature verification for chat messages
import 'dart:convert';
import '../lib/util/nostr_crypto.dart';
import '../lib/util/nostr_event.dart';

void main() {
  print('=== Testing fresh sign & verify ===\n');

  // Generate a fresh keypair
  final keyPair = NostrCrypto.generateKeyPair();
  final nsec = keyPair.nsec;
  final npub = keyPair.npub;
  final pubkey = NostrCrypto.decodeNpub(npub);

  print('Generated keys:');
  print('  npub: ${npub.substring(0, 30)}...');
  print('  pubkey: ${pubkey.substring(0, 20)}...');
  print('');

  // Create message parameters
  final content = 'Test message for verification';
  final roomId = 'TESTDEV'; // For DMs, this is the other device's callsign
  final callsign = 'MYDEVICE';
  final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  print('Message parameters:');
  print('  content: "$content"');
  print('  roomId: $roomId');
  print('  callsign: $callsign');
  print('  createdAt: $createdAt');
  print('');

  // Create and sign event
  final tags = [['t', 'chat'], ['room', roomId], ['callsign', callsign]];
  final event = NostrEvent(
    pubkey: pubkey,
    createdAt: createdAt,
    kind: 1,
    tags: tags,
    content: content,
  );
  event.calculateId();
  event.signWithNsec(nsec);

  print('Signed event:');
  print('  id: ${event.id}');
  print('  sig: ${event.sig?.substring(0, 32)}...');
  print('');

  // Verify the signed event
  final verified1 = event.verify();
  print('Original event verified: $verified1');
  print('');

  // Now simulate reconstruction during message load
  print('=== Simulating message load reconstruction ===\n');

  final reconstructed = NostrEvent(
    pubkey: pubkey,
    createdAt: createdAt, // Same timestamp
    kind: 1,
    tags: [['t', 'chat'], ['room', roomId], ['callsign', callsign]],
    content: content,
    sig: event.sig, // Use the signature from original
  );
  reconstructed.calculateId();

  print('Reconstructed event:');
  print('  id: ${reconstructed.id}');
  print('  IDs match: ${event.id == reconstructed.id}');
  print('');

  final verified2 = reconstructed.verify();
  print('Reconstructed event verified: $verified2');
  print('');

  // Summary
  print('=== Summary ===');
  print('Original verified: $verified1');
  print('Reconstructed verified: $verified2');
  if (verified1 && verified2) {
    print('\nSUCCESS: Signature verification works correctly!');
  } else {
    print('\nFAILURE: Signature verification failed!');
  }
}
