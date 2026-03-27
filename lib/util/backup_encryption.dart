/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Backup Encryption Implementation
 * Implements ECIES (Elliptic Curve Integrated Encryption Scheme) for E2E backup encryption
 * Uses secp256k1 + HKDF-SHA256 + ChaCha20-Poly1305
 */

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'nostr_crypto.dart';

/// ECIES encryption for backup files
/// Uses secp256k1 for key agreement, HKDF-SHA256 for key derivation,
/// and ChaCha20-Poly1305 for authenticated encryption
class BackupEncryption {
  static final _secureRandom = SecureRandom('Fortuna')
    ..seed(
      KeyParameter(
        Uint8List.fromList(
          List.generate(32, (_) => Random.secure().nextInt(256)),
        ),
      ),
    );

  /// Encrypt file bytes for a recipient NPUB
  /// Returns: [ephemeral_pubkey (33)] + [nonce (12)] + [ciphertext] + [tag (16)]
  static Uint8List encryptFile(Uint8List plaintext, String recipientNpub) {
    // Decode recipient public key from npub
    final recipientPubKeyHex = NostrCrypto.decodeNpub(recipientNpub);

    // Generate ephemeral keypair
    final ephemeralKeyPair = _generateEphemeralKeyPair();
    final ephemeralPrivKey = ephemeralKeyPair.privateKey;
    final ephemeralPubKey = ephemeralKeyPair.publicKey;

    // Derive shared secret via ECDH
    final sharedSecret = _deriveSharedSecret(
      ephemeralPrivKey,
      recipientPubKeyHex,
    );

    // Derive encryption key using HKDF
    final encryptionKey = _hkdfExpand(sharedSecret, 'geogram-backup-file', 32);

    // Generate random nonce
    final nonce = _generateNonce();

    // Encrypt using ChaCha20-Poly1305
    final ciphertext = _chacha20Poly1305Encrypt(
      encryptionKey,
      nonce,
      plaintext,
    );

    // Output: ephemeral_pubkey (33 compressed) || nonce (12) || ciphertext+tag
    final result = Uint8List(33 + 12 + ciphertext.length);
    result.setRange(0, 33, ephemeralPubKey);
    result.setRange(33, 45, nonce);
    result.setRange(45, 45 + ciphertext.length, ciphertext);

    return result;
  }

  /// Decrypt file using own NSEC
  static Uint8List decryptFile(Uint8List ciphertext, String myNsec) {
    if (ciphertext.length < 61) {
      // 33 + 12 + 16 (minimum: pubkey + nonce + tag with empty plaintext)
      throw ArgumentError('Invalid ciphertext: too short');
    }

    // Decode private key from nsec
    final myPrivKeyHex = NostrCrypto.decodeNsec(myNsec);

    // Extract components
    final ephemeralPubKey = ciphertext.sublist(0, 33);
    final nonce = ciphertext.sublist(33, 45);
    final encryptedData = ciphertext.sublist(45);

    // Derive shared secret via ECDH
    final sharedSecret = _deriveSharedSecretFromCompressed(
      myPrivKeyHex,
      ephemeralPubKey,
    );

    // Derive encryption key using HKDF
    final encryptionKey = _hkdfExpand(sharedSecret, 'geogram-backup-file', 32);

    // Decrypt using ChaCha20-Poly1305
    return _chacha20Poly1305Decrypt(encryptionKey, nonce, encryptedData);
  }

  /// Encrypt manifest using deterministic key from client's own keypair
  /// This allows the client to decrypt their own manifest without storing additional keys
  static Uint8List encryptManifest(String manifestJson, String clientNsec) {
    // Decode private key
    final privKeyHex = NostrCrypto.decodeNsec(clientNsec);
    final pubKeyHex = NostrCrypto.derivePublicKey(privKeyHex);

    // Derive deterministic key by hashing private key with context
    final manifestKey = _deriveManifestKey(privKeyHex, pubKeyHex);

    // Generate random nonce (manifest gets new nonce each time)
    final nonce = _generateNonce();

    // Encrypt
    final plaintext = utf8.encode(manifestJson);
    final ciphertext = _chacha20Poly1305Encrypt(
      manifestKey,
      nonce,
      Uint8List.fromList(plaintext),
    );

    // Output: nonce (12) || ciphertext+tag
    final result = Uint8List(12 + ciphertext.length);
    result.setRange(0, 12, nonce);
    result.setRange(12, 12 + ciphertext.length, ciphertext);

    return result;
  }

  /// Decrypt manifest using own NSEC
  static String decryptManifest(Uint8List encrypted, String clientNsec) {
    if (encrypted.length < 28) {
      // 12 + 16 (minimum: nonce + tag with empty plaintext)
      throw ArgumentError('Invalid encrypted manifest: too short');
    }

    // Decode private key
    final privKeyHex = NostrCrypto.decodeNsec(clientNsec);
    final pubKeyHex = NostrCrypto.derivePublicKey(privKeyHex);

    // Derive the same deterministic key
    final manifestKey = _deriveManifestKey(privKeyHex, pubKeyHex);

    // Extract components
    final nonce = encrypted.sublist(0, 12);
    final ciphertext = encrypted.sublist(12);

    // Decrypt
    final plaintext = _chacha20Poly1305Decrypt(manifestKey, nonce, ciphertext);
    return utf8.decode(plaintext);
  }

  /// Generate cryptographically secure random bytes.
  static Uint8List randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = Random.secure().nextInt(256);
    }
    return bytes;
  }

  /// Encrypt bytes with a shared symmetric secret and detached nonce.
  static ({Uint8List nonce, Uint8List ciphertext}) encryptBytesWithSharedKey(
    Uint8List plaintext,
    Uint8List sharedSecret, {
    String info = 'geogram-dchat-epoch-message',
  }) {
    final nonce = _generateNonce();
    final encryptionKey = _hkdfExpand(sharedSecret, info, 32);
    final ciphertext = _chacha20Poly1305Encrypt(
      encryptionKey,
      nonce,
      plaintext,
    );
    return (nonce: nonce, ciphertext: ciphertext);
  }

  /// Decrypt bytes encrypted with [encryptBytesWithSharedKey].
  static Uint8List decryptBytesWithSharedKey({
    required Uint8List ciphertext,
    required Uint8List nonce,
    required Uint8List sharedSecret,
    String info = 'geogram-dchat-epoch-message',
  }) {
    final encryptionKey = _hkdfExpand(sharedSecret, info, 32);
    return _chacha20Poly1305Decrypt(encryptionKey, nonce, ciphertext);
  }

  // === ECDH Key Agreement ===

  /// Generate ephemeral keypair for ECIES
  static _EphemeralKeyPair _generateEphemeralKeyPair() {
    final curve = ECCurve_secp256k1();
    final keyParams = ECKeyGeneratorParameters(curve);
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(keyParams, _secureRandom));

    final keyPair = generator.generateKeyPair();
    final privateKey = keyPair.privateKey as ECPrivateKey;
    final publicKey = keyPair.publicKey as ECPublicKey;

    // Private key as 32 bytes
    final privKeyBytes = _bigIntToBytes(privateKey.d!, 32);

    // Public key as 33 bytes (compressed)
    final pubKeyCompressed = _compressPublicKey(publicKey.Q!);

    return _EphemeralKeyPair(privKeyBytes, pubKeyCompressed);
  }

  /// Derive shared secret using ECDH: shared = myPrivKey * theirPubKey
  static Uint8List _deriveSharedSecret(
    Uint8List myPrivateKey,
    String theirPublicKeyHex,
  ) {
    final curve = ECCurve_secp256k1();
    final myD = _bytesToBigInt(myPrivateKey);

    // Their public key is x-only (32 bytes), need to lift to full point
    final theirPubKeyBytes = _hexDecode(theirPublicKeyHex);
    final theirPubKey = _liftX(_bytesToBigInt(theirPubKeyBytes), curve);

    if (theirPubKey == null) {
      throw ArgumentError('Invalid public key');
    }

    // ECDH: shared_point = myPrivKey * theirPubKey
    final sharedPoint = theirPubKey * myD;
    if (sharedPoint == null || sharedPoint.isInfinity) {
      throw StateError('Invalid ECDH result');
    }

    // Shared secret is x-coordinate of shared point
    return _bigIntToBytes(sharedPoint.x!.toBigInteger()!, 32);
  }

  /// Derive shared secret from compressed public key
  static Uint8List _deriveSharedSecretFromCompressed(
    String myPrivKeyHex,
    Uint8List theirCompressedPubKey,
  ) {
    final curve = ECCurve_secp256k1();
    final myD = _bytesToBigInt(_hexDecode(myPrivKeyHex));

    // Decompress public key
    final theirPubKey = _decompressPublicKey(theirCompressedPubKey, curve);
    if (theirPubKey == null) {
      throw ArgumentError('Invalid compressed public key');
    }

    // ECDH: shared_point = myPrivKey * theirPubKey
    final sharedPoint = theirPubKey * myD;
    if (sharedPoint == null || sharedPoint.isInfinity) {
      throw StateError('Invalid ECDH result');
    }

    // Shared secret is x-coordinate of shared point
    return _bigIntToBytes(sharedPoint.x!.toBigInteger()!, 32);
  }

  // === Key Derivation ===

  /// HKDF-Expand using SHA256
  static Uint8List _hkdfExpand(Uint8List secret, String info, int length) {
    // HKDF-Extract: PRK = HMAC-SHA256(salt, IKM)
    // Using empty salt as per HKDF spec
    final salt = Uint8List(32); // 32 zero bytes
    final prk = Hmac(sha256, salt).convert(secret).bytes;

    // HKDF-Expand: OKM = HMAC-SHA256(PRK, info || 0x01)
    final infoBytes = utf8.encode(info);
    final expandInput = Uint8List.fromList([...infoBytes, 0x01]);
    final okm = Hmac(sha256, prk).convert(expandInput).bytes;

    return Uint8List.fromList(okm.sublist(0, length));
  }

  /// Derive manifest key (deterministic from keypair)
  static Uint8List _deriveManifestKey(String privKeyHex, String pubKeyHex) {
    // Hash private key with context to derive manifest encryption key
    final contextBytes = utf8.encode('geogram-backup-manifest');
    final privKeyBytes = _hexDecode(privKeyHex);
    final combined = Uint8List.fromList([...contextBytes, ...privKeyBytes]);
    final keyHash = sha256.convert(combined).bytes;
    return Uint8List.fromList(keyHash);
  }

  // === ChaCha20-Poly1305 ===

  /// Encrypt using ChaCha20-Poly1305 AEAD
  static Uint8List _chacha20Poly1305Encrypt(
    Uint8List key,
    Uint8List nonce,
    Uint8List plaintext,
  ) {
    // Use pointycastle's ChaCha20-Poly1305
    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
    final params = AEADParameters(
      KeyParameter(key),
      128, // tag length in bits
      nonce,
      Uint8List(0), // no additional authenticated data
    );

    cipher.init(true, params);

    // Output: ciphertext + tag (16 bytes)
    final output = Uint8List(plaintext.length + 16);
    var len = cipher.processBytes(plaintext, 0, plaintext.length, output, 0);
    len += cipher.doFinal(output, len);

    return output.sublist(0, len);
  }

  /// Decrypt using ChaCha20-Poly1305 AEAD
  static Uint8List _chacha20Poly1305Decrypt(
    Uint8List key,
    Uint8List nonce,
    Uint8List ciphertext,
  ) {
    if (ciphertext.length < 16) {
      throw ArgumentError('Ciphertext too short (missing auth tag)');
    }

    // Use pointycastle's ChaCha20-Poly1305
    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
    final params = AEADParameters(
      KeyParameter(key),
      128, // tag length in bits
      nonce,
      Uint8List(0), // no additional authenticated data
    );

    cipher.init(false, params);

    // Output: plaintext (ciphertext.length - 16)
    final output = Uint8List(ciphertext.length - 16);
    var len = cipher.processBytes(ciphertext, 0, ciphertext.length, output, 0);
    try {
      len += cipher.doFinal(output, len);
    } catch (e) {
      throw StateError('Decryption failed: invalid auth tag');
    }

    return output.sublist(0, len);
  }

  // === Helper Functions ===

  /// Generate random 12-byte nonce
  static Uint8List _generateNonce() {
    return randomBytes(12);
  }

  /// Compress EC public key to 33 bytes (02/03 prefix + x-coordinate)
  static Uint8List _compressPublicKey(ECPoint point) {
    final x = point.x!.toBigInteger()!;
    final y = point.y!.toBigInteger()!;
    final prefix = y.isEven ? 0x02 : 0x03;
    final xBytes = _bigIntToBytes(x, 32);
    final compressed = Uint8List(33);
    compressed[0] = prefix;
    compressed.setRange(1, 33, xBytes);
    return compressed;
  }

  /// Decompress EC public key from 33 bytes
  static ECPoint? _decompressPublicKey(
    Uint8List compressed,
    ECDomainParameters curve,
  ) {
    if (compressed.length != 33) {
      return null;
    }

    final prefix = compressed[0];
    if (prefix != 0x02 && prefix != 0x03) {
      return null;
    }

    final x = _bytesToBigInt(compressed.sublist(1));
    final p = BigInt.parse(
      'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
      radix: 16,
    );

    // y² = x³ + 7 (mod p) for secp256k1
    final ySq = (x.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
    var y = ySq.modPow((p + BigInt.one) ~/ BigInt.from(4), p);

    // Verify y² = ySq
    if ((y * y) % p != ySq) {
      return null;
    }

    // Choose correct y based on prefix
    final yIsEven = y.isEven;
    final prefixWantsEven = prefix == 0x02;
    if (yIsEven != prefixWantsEven) {
      y = p - y;
    }

    return curve.curve.createPoint(x, y);
  }

  /// Lift x-coordinate to curve point (BIP-340 style)
  static ECPoint? _liftX(BigInt x, ECDomainParameters curve) {
    final p = BigInt.parse(
      'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
      radix: 16,
    );
    if (x >= p) return null;

    // y² = x³ + 7 (mod p) for secp256k1
    final ySq = (x.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
    final y = ySq.modPow((p + BigInt.one) ~/ BigInt.from(4), p);

    // Verify y² = ySq
    if ((y * y) % p != ySq) return null;

    // Return point with even y
    final yFinal = y.isEven ? y : p - y;
    return curve.curve.createPoint(x, yFinal);
  }

  /// Convert BigInt to fixed-size bytes
  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final bytes = Uint8List(length);
    var temp = value;
    for (var i = length - 1; i >= 0; i--) {
      bytes[i] = (temp & BigInt.from(0xff)).toInt();
      temp = temp >> 8;
    }
    return bytes;
  }

  /// Convert bytes to BigInt
  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  /// Hex decode helper
  static Uint8List _hexDecode(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}

/// Ephemeral keypair for ECIES
class _EphemeralKeyPair {
  final Uint8List privateKey; // 32 bytes
  final Uint8List publicKey; // 33 bytes compressed

  _EphemeralKeyPair(this.privateKey, this.publicKey);
}
