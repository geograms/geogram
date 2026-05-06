/// NIP-44 v2 native Dart implementation.
///
/// Spec: https://github.com/nostr-protocol/nips/blob/master/44.md
///
/// Pipeline:
///   shared_x  = ECDH(ourSec, theirPub)             // x-only secp256k1
///   conv_key  = HKDF-extract(salt="nip44-v2", IKM=shared_x)
///   nonce     = 32 random bytes
///   keys      = HKDF-expand(PRK=conv_key, info=nonce, L=76)
///                    → chacha_key(32) || chacha_nonce(12) || hmac_key(32)
///   padded    = u16_be(plaintext_len) || plaintext || zero-pad to power-of-2
///   ct        = ChaCha20(chacha_key, chacha_nonce, padded)
///   mac       = HMAC-SHA256(hmac_key, nonce || ct)
///   payload   = base64(0x02 || nonce || ct || mac)
///
/// PR2 (BT-DHT-v2 §8) only uses this for WebRTC signaling. Other NOSTR
/// callers continue to go through `lib/util/nostr_bundle.dart` until a
/// follow-up cleanup migration.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hex/hex.dart';
import 'package:pointycastle/export.dart';

class Nip44V2 {
  static const int _minPlaintextLen = 1;
  static const int _maxPlaintextLen = 65535;
  static const int _version = 0x02;

  /// Encrypt [plaintext] for the holder of [theirPubKeyHex] (32-byte x-only)
  /// using our secret key [ourSecretKeyHex] (32 bytes hex). Returns the
  /// base64-encoded NIP-44 v2 payload.
  static String encrypt(
    String plaintext,
    String ourSecretKeyHex,
    String theirPubKeyHex, {
    Uint8List? nonce,
  }) {
    final ptBytes = utf8.encode(plaintext);
    if (ptBytes.length < _minPlaintextLen ||
        ptBytes.length > _maxPlaintextLen) {
      throw ArgumentError(
        'NIP-44: plaintext length must be 1..65535 (got ${ptBytes.length})',
      );
    }
    final n = nonce ?? _randomBytes(32);
    if (n.length != 32) {
      throw ArgumentError('NIP-44: nonce must be 32 bytes');
    }
    final convKey = conversationKey(ourSecretKeyHex, theirPubKeyHex);
    final mk = _messageKeys(convKey, n);
    final padded = _pad(Uint8List.fromList(ptBytes));
    final ct = _chacha20(mk.chachaKey, mk.chachaNonce, padded);
    final mac = _hmacSha256(mk.hmacKey, _concat([n, ct]));

    final out = BytesBuilder()
      ..addByte(_version)
      ..add(n)
      ..add(ct)
      ..add(mac);
    return base64.encode(out.toBytes());
  }

  /// Decrypt a base64-encoded NIP-44 v2 [payload] sent by the holder of
  /// [theirPubKeyHex]. Throws [FormatException] on tampered payloads.
  static String decrypt(
    String payload,
    String ourSecretKeyHex,
    String theirPubKeyHex,
  ) {
    final raw = base64.decode(payload);
    if (raw.length < 1 + 32 + 32 + 32) {
      throw const FormatException('NIP-44: payload too short');
    }
    if (raw[0] != _version) {
      throw FormatException('NIP-44: unsupported version 0x${raw[0].toRadixString(16)}');
    }
    final n = raw.sublist(1, 33);
    final ct = raw.sublist(33, raw.length - 32);
    final mac = raw.sublist(raw.length - 32);

    final convKey = conversationKey(ourSecretKeyHex, theirPubKeyHex);
    final mk = _messageKeys(convKey, Uint8List.fromList(n));

    final expectedMac =
        _hmacSha256(mk.hmacKey, _concat([Uint8List.fromList(n), Uint8List.fromList(ct)]));
    if (!_constTimeEq(expectedMac, Uint8List.fromList(mac))) {
      throw const FormatException('NIP-44: MAC mismatch');
    }

    final padded =
        _chacha20(mk.chachaKey, mk.chachaNonce, Uint8List.fromList(ct));
    if (padded.length < 2) {
      throw const FormatException('NIP-44: padded plaintext too short');
    }
    final ptLen = (padded[0] << 8) | padded[1];
    if (ptLen < _minPlaintextLen ||
        ptLen > _maxPlaintextLen ||
        ptLen + 2 > padded.length) {
      throw const FormatException('NIP-44: invalid plaintext length');
    }
    return utf8.decode(padded.sublist(2, 2 + ptLen));
  }

  /// Derive the 32-byte conversation key (PRK) for two NIP-44 peers.
  ///
  /// `HKDF-extract(salt="nip44-v2", IKM=shared_x)` where shared_x is the
  /// x-coordinate of the secp256k1 ECDH shared point.
  static Uint8List conversationKey(
    String ourSecretKeyHex,
    String theirPubKeyHex,
  ) {
    final shared = _ecdhSharedX(ourSecretKeyHex, theirPubKeyHex);
    final salt = Uint8List.fromList(utf8.encode('nip44-v2'));
    return _hkdfExtract(salt, shared);
  }

  // ─── internals ────────────────────────────────────────────────────

  static Uint8List _ecdhSharedX(
      String ourSecretKeyHex, String theirPubKeyHex) {
    final curve = ECCurve_secp256k1();
    final d = _bytesToBigInt(Uint8List.fromList(HEX.decode(ourSecretKeyHex)));
    final theirX =
        _bytesToBigInt(Uint8List.fromList(HEX.decode(theirPubKeyHex)));
    final theirPub = _liftX(theirX, curve);
    if (theirPub == null) {
      throw ArgumentError('NIP-44: invalid x-only public key');
    }
    final shared = theirPub * d;
    if (shared == null || shared.isInfinity) {
      throw StateError('NIP-44: ECDH yielded point at infinity');
    }
    return _bigIntToBytes(shared.x!.toBigInteger()!, 32);
  }

  static _MessageKeys _messageKeys(Uint8List convKey, Uint8List nonce) {
    final okm = _hkdfExpand(convKey, nonce, 76);
    return _MessageKeys(
      chachaKey: Uint8List.sublistView(okm, 0, 32),
      chachaNonce: Uint8List.sublistView(okm, 32, 44),
      hmacKey: Uint8List.sublistView(okm, 44, 76),
    );
  }

  /// Pad plaintext per NIP-44 v2: prepend 2-byte BE length, then zero-pad
  /// total length to the spec-defined chunk boundary.
  static Uint8List _pad(Uint8List plaintext) {
    final unpaddedLen = plaintext.length;
    final paddedLen = _calcPaddedLen(unpaddedLen);
    final out = Uint8List(2 + paddedLen);
    out[0] = (unpaddedLen >> 8) & 0xff;
    out[1] = unpaddedLen & 0xff;
    out.setRange(2, 2 + unpaddedLen, plaintext);
    return out;
  }

  static int _calcPaddedLen(int unpaddedLen) {
    if (unpaddedLen <= 32) return 32;
    final nextPower = 1 << ((unpaddedLen - 1).bitLength);
    final chunk = nextPower <= 256 ? 32 : (nextPower ~/ 8);
    return chunk * (((unpaddedLen - 1) ~/ chunk) + 1);
  }

  static Uint8List _chacha20(
      Uint8List key, Uint8List nonce, Uint8List input) {
    final cipher = ChaCha7539Engine()
      ..init(true, ParametersWithIV(KeyParameter(key), nonce));
    final out = Uint8List(input.length);
    cipher.processBytes(input, 0, input.length, out, 0);
    return out;
  }

  static Uint8List _hmacSha256(Uint8List key, Uint8List data) {
    return Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);
  }

  static Uint8List _hkdfExtract(Uint8List salt, Uint8List ikm) {
    return _hmacSha256(salt, ikm);
  }

  static Uint8List _hkdfExpand(Uint8List prk, Uint8List info, int length) {
    final out = BytesBuilder();
    Uint8List prev = Uint8List(0);
    int counter = 1;
    while (out.length < length) {
      prev = _hmacSha256(prk, _concat([prev, info, Uint8List.fromList([counter])]));
      out.add(prev);
      counter++;
    }
    return Uint8List.fromList(out.toBytes().sublist(0, length));
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = rng.nextInt(256);
    }
    return b;
  }

  static Uint8List _concat(List<Uint8List> parts) {
    final total = parts.fold<int>(0, (s, p) => s + p.length);
    final out = Uint8List(total);
    var off = 0;
    for (final p in parts) {
      out.setRange(off, off + p.length, p);
      off += p.length;
    }
    return out;
  }

  static bool _constTimeEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static ECPoint? _liftX(BigInt x, ECDomainParameters curve) {
    final p = BigInt.parse(
      'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
      radix: 16,
    );
    if (x <= BigInt.zero || x >= p) return null;

    final ySq = (x.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
    final y = ySq.modPow((p + BigInt.one) ~/ BigInt.from(4), p);
    if ((y * y) % p != ySq) return null;

    final yFinal = y.isEven ? y : p - y;
    return curve.curve.createPoint(x, yFinal);
  }

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
    var r = BigInt.zero;
    for (final b in bytes) {
      r = (r << 8) | BigInt.from(b);
    }
    return r;
  }
}

class _MessageKeys {
  final Uint8List chachaKey;
  final Uint8List chachaNonce;
  final Uint8List hmacKey;
  const _MessageKeys({
    required this.chachaKey,
    required this.chachaNonce,
    required this.hmacKey,
  });
}
