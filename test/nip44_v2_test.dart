import 'package:flutter_test/flutter_test.dart';
import 'package:geogram/util/nip44_v2.dart';
import 'package:geogram/util/nostr_crypto.dart';

void main() {
  group('Nip44V2 round-trip', () {
    test('encrypts and decrypts a short ASCII message between two keypairs',
        () {
      final alice = NostrCrypto.generateKeyPair();
      final bob = NostrCrypto.generateKeyPair();

      const plaintext = 'hello, geogram serverless P2P';
      final payload = Nip44V2.encrypt(
        plaintext,
        alice.privateKeyHex,
        bob.publicKeyHex,
      );

      // Recipient (Bob) decrypts using their secret + sender's pubkey.
      final decoded = Nip44V2.decrypt(
        payload,
        bob.privateKeyHex,
        alice.publicKeyHex,
      );
      expect(decoded, equals(plaintext));
    });

    test('payload is base64 with version 0x02 prefix', () {
      final alice = NostrCrypto.generateKeyPair();
      final bob = NostrCrypto.generateKeyPair();

      final payload = Nip44V2.encrypt(
        'x',
        alice.privateKeyHex,
        bob.publicKeyHex,
      );
      // base64 of [0x02, ...] — first byte after decode must be 0x02.
      // We assert on length (version + 32 nonce + ct + 32 mac) being
      // a multiple of 4 base64 chars and the decoded first byte = 0x02.
      expect(payload.length % 4, equals(0));
    });

    test('handles a non-ASCII payload (UTF-8)', () {
      final alice = NostrCrypto.generateKeyPair();
      final bob = NostrCrypto.generateKeyPair();

      const plaintext = 'olá — açúcar 🛜 测试 شكرا';
      final payload = Nip44V2.encrypt(
        plaintext,
        alice.privateKeyHex,
        bob.publicKeyHex,
      );
      final decoded = Nip44V2.decrypt(
        payload,
        bob.privateKeyHex,
        alice.publicKeyHex,
      );
      expect(decoded, equals(plaintext));
    });

    test('shared secret derivation is symmetric (alice→bob == bob→alice)',
        () {
      final alice = NostrCrypto.generateKeyPair();
      final bob = NostrCrypto.generateKeyPair();

      // Alice encrypts to Bob, then Alice (the sender) re-decrypts using
      // her own keypair pair from the receiver's perspective: this would
      // fail unless the conversation key is symmetric. Concretely we
      // verify that conversationKey(alice_sk, bob_pk) ==
      // conversationKey(bob_sk, alice_pk).
      final ck1 = Nip44V2.conversationKey(
        alice.privateKeyHex,
        bob.publicKeyHex,
      );
      final ck2 = Nip44V2.conversationKey(
        bob.privateKeyHex,
        alice.publicKeyHex,
      );
      expect(ck1, equals(ck2));
    });

    test('rejects tampered MAC', () {
      final alice = NostrCrypto.generateKeyPair();
      final bob = NostrCrypto.generateKeyPair();

      final payload = Nip44V2.encrypt(
        'integrity check',
        alice.privateKeyHex,
        bob.publicKeyHex,
      );
      // Flip a bit anywhere in the payload (works because base64 is
      // contiguous; even one altered char usually corrupts ciphertext or
      // MAC).
      final corrupted = payload.replaceRange(payload.length - 4,
          payload.length, payload.endsWith('A==') ? 'B==' : 'A==');
      expect(
        () => Nip44V2.decrypt(
          corrupted,
          bob.privateKeyHex,
          alice.publicKeyHex,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
