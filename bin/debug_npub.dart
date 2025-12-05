import '../lib/util/nostr_crypto.dart';

void main() {
  final npub = 'npub1qvm3ta3gjx8jxn8u67a6anvd2g2dah60srs0ftvravlcuy986nvs4p24xu';
  final pubkey = NostrCrypto.decodeNpub(npub);
  print('npub: $npub');
  print('pubkey hex: $pubkey');
  print('pubkey length: ${pubkey.length} chars = ${pubkey.length ~/ 2} bytes');

  // Verify round-trip
  final npubBack = NostrCrypto.encodeNpub(pubkey);
  print('npub round-trip: $npubBack');
  print('Match: ${npub == npubBack}');
}
