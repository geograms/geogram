/*
 * ECDSA-secp256k1 signing for AT Protocol.
 *
 * AT Proto uses ECDSA (not Schnorr) over secp256k1 with low-S normalization.
 * This reuses the secp256k1 curve from NostrCrypto/PointyCastle.
 *
 * Key differences from NOSTR signing:
 * - NOSTR: BIP-340 Schnorr (64-byte sig, x-only pubkey)
 * - AT Proto: ECDSA (DER-encoded sig, compressed pubkey, low-S)
 *
 * Multikey encoding uses the 0xe7 varint prefix for secp256k1 keys,
 * followed by the 33-byte compressed public key.
 */

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// AT Protocol ECDSA-secp256k1 signing operations.
class AtprotoSigning {
  static final _curve = ECCurve_secp256k1();
  static final _n = _curve.n;
  static final _halfN = _n >> 1;

  /// Generate a new secp256k1 key pair for AT Proto signing.
  ///
  /// Returns (privateKey: 32 bytes, compressedPublicKey: 33 bytes).
  static ({Uint8List privateKey, Uint8List publicKey}) generateKeyPair() {
    final secureRandom = SecureRandom('Fortuna')
      ..seed(KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256))),
      ));

    final keyParams = ECKeyGeneratorParameters(_curve);
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(keyParams, secureRandom));

    final pair = generator.generateKeyPair();
    final priv = pair.privateKey as ECPrivateKey;
    final pub = pair.publicKey as ECPublicKey;

    return (
      privateKey: _bigIntToBytes(priv.d!, 32),
      publicKey: pub.Q!.getEncoded(true), // 33-byte compressed
    );
  }

  /// Derive the compressed public key (33 bytes) from a private key.
  static Uint8List derivePublicKey(Uint8List privateKey) {
    final d = _bytesToBigInt(privateKey);
    final Q = _curve.G * d;
    return Q!.getEncoded(true);
  }

  /// Sign data with ECDSA-secp256k1, returning a low-S normalized signature.
  ///
  /// [data] is the raw bytes to sign (will be SHA-256 hashed).
  /// Returns the signature as raw bytes: r (32 bytes) || s (32 bytes).
  static Uint8List sign(Uint8List data, Uint8List privateKey) {
    final hash = sha256.convert(data);
    final z = _bytesToBigInt(Uint8List.fromList(hash.bytes));
    final d = _bytesToBigInt(privateKey);

    // RFC 6979 deterministic k
    final k = _rfc6979k(z, d);

    final R = _curve.G * k;
    final r = R!.x!.toBigInteger()!;
    var s = ((z + r * d) * k.modInverse(_n)) % _n;

    // Low-S normalization: if s > n/2, use n - s
    if (s > _halfN) {
      s = _n - s;
    }

    final sig = Uint8List(64);
    final rBytes = _bigIntToBytes(r, 32);
    final sBytes = _bigIntToBytes(s, 32);
    sig.setRange(0, 32, rBytes);
    sig.setRange(32, 64, sBytes);
    return sig;
  }

  /// Verify an ECDSA signature against a compressed public key.
  ///
  /// [data] is the raw bytes that were signed.
  /// [signature] is r (32 bytes) || s (32 bytes).
  /// [publicKey] is the 33-byte compressed public key.
  static bool verify(Uint8List data, Uint8List signature, Uint8List publicKey) {
    try {
      if (signature.length != 64) return false;

      final hash = sha256.convert(data);
      final z = _bytesToBigInt(Uint8List.fromList(hash.bytes));
      final r = _bytesToBigInt(signature.sublist(0, 32));
      final s = _bytesToBigInt(signature.sublist(32, 64));

      if (r <= BigInt.zero || r >= _n) return false;
      if (s <= BigInt.zero || s >= _n) return false;

      // Reject high-S
      if (s > _halfN) return false;

      final Q = _curve.curve.decodePoint(publicKey);
      if (Q == null) return false;

      final sInv = s.modInverse(_n);
      final u1 = (z * sInv) % _n;
      final u2 = (r * sInv) % _n;

      final point = (_curve.G * u1)! + (Q * u2)!;
      if (point == null || point.isInfinity) return false;

      return point.x!.toBigInteger()! % _n == r;
    } catch (_) {
      return false;
    }
  }

  /// Encode a compressed secp256k1 public key as a Multikey string.
  ///
  /// Format: 'z' multibase prefix + base58btc(0xe7 0x01 + 33-byte compressed pubkey)
  /// The 0xe7 0x01 is the two-byte varint for multicodec secp256k1-pub (0xe7).
  static String publicKeyToMultikey(Uint8List compressedPubkey) {
    if (compressedPubkey.length != 33) {
      throw ArgumentError('Expected 33-byte compressed public key');
    }
    // Multicodec prefix for secp256k1-pub: 0xe7 as unsigned varint = [0xe7, 0x01]
    final prefixed = Uint8List(2 + 33);
    prefixed[0] = 0xe7;
    prefixed[1] = 0x01;
    prefixed.setRange(2, 35, compressedPubkey);
    return 'z${_base58Encode(prefixed)}';
  }

  /// Decode a Multikey string back to a compressed public key.
  static Uint8List multikeyToPublicKey(String multikey) {
    if (!multikey.startsWith('z')) {
      throw FormatException('Expected z-prefixed multibase');
    }
    final bytes = _base58Decode(multikey.substring(1));
    if (bytes.length != 35 || bytes[0] != 0xe7 || bytes[1] != 0x01) {
      throw FormatException('Invalid secp256k1 Multikey prefix');
    }
    return bytes.sublist(2);
  }

  // -- RFC 6979 deterministic nonce generation --

  static BigInt _rfc6979k(BigInt z, BigInt d) {
    final dBytes = _bigIntToBytes(d, 32);
    final zBytes = _bigIntToBytes(z, 32);

    // Initial V and K
    var v = Uint8List(32)..fillRange(0, 32, 0x01);
    var kk = Uint8List(32); // all zeros

    // Step D: K = HMAC(K, V || 0x00 || privkey || hash)
    kk = _hmacSha256(kk, Uint8List.fromList([...v, 0x00, ...dBytes, ...zBytes]));
    // Step E: V = HMAC(K, V)
    v = _hmacSha256(kk, v);
    // Step F: K = HMAC(K, V || 0x01 || privkey || hash)
    kk = _hmacSha256(kk, Uint8List.fromList([...v, 0x01, ...dBytes, ...zBytes]));
    // Step G: V = HMAC(K, V)
    v = _hmacSha256(kk, v);

    // Step H: generate until valid
    while (true) {
      v = _hmacSha256(kk, v);
      final candidate = _bytesToBigInt(v);
      if (candidate > BigInt.zero && candidate < _n) {
        return candidate;
      }
      kk = _hmacSha256(kk, Uint8List.fromList([...v, 0x00]));
      v = _hmacSha256(kk, v);
    }
  }

  static Uint8List _hmacSha256(Uint8List key, Uint8List data) {
    final hmac = Hmac(sha256, key);
    return Uint8List.fromList(hmac.convert(data).bytes);
  }

  // -- BigInt <-> bytes --

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final bytes = Uint8List(length);
    var temp = value;
    for (var i = length - 1; i >= 0; i--) {
      bytes[i] = (temp & BigInt.from(0xff)).toInt();
      temp = temp >> 8;
    }
    return bytes;
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  // -- Base58 (Bitcoin alphabet) --

  static const _base58Alphabet =
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  static String _base58Encode(Uint8List data) {
    var value = BigInt.zero;
    for (final byte in data) {
      value = value * BigInt.from(256) + BigInt.from(byte);
    }

    final chars = <String>[];
    final base = BigInt.from(58);
    while (value > BigInt.zero) {
      final (quotient, remainder) = (value ~/ base, value % base);
      chars.add(_base58Alphabet[remainder.toInt()]);
      value = quotient;
    }

    // Preserve leading zeros
    for (final byte in data) {
      if (byte != 0) break;
      chars.add('1');
    }

    return chars.reversed.join();
  }

  static Uint8List _base58Decode(String encoded) {
    var value = BigInt.zero;
    final base = BigInt.from(58);
    for (final char in encoded.codeUnits) {
      final idx = _base58Alphabet.indexOf(String.fromCharCode(char));
      if (idx < 0) throw FormatException('Invalid base58 character');
      value = value * base + BigInt.from(idx);
    }

    // Count leading '1's (representing leading zero bytes)
    var leadingZeros = 0;
    for (final char in encoded.codeUnits) {
      if (String.fromCharCode(char) != '1') break;
      leadingZeros++;
    }

    // Convert BigInt to bytes
    final bytes = <int>[];
    while (value > BigInt.zero) {
      bytes.add((value % BigInt.from(256)).toInt());
      value ~/= BigInt.from(256);
    }

    return Uint8List.fromList([
      ...List.filled(leadingZeros, 0),
      ...bytes.reversed,
    ]);
  }
}
