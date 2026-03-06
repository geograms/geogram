/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Noise Protocol Framework — XX handshake pattern.
 * Pure Dart using the `cryptography` package.
 *
 * Pattern: XX (mutual authentication)
 *   -> e
 *   <- e, ee, s, es
 *   -> s, se
 *
 * Crypto primitives:
 *   - X25519 for DH key exchange
 *   - ChaCha20-Poly1305 for AEAD
 *   - SHA-256 for hashing
 *
 * Reference: https://noiseprotocol.org/noise.html
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:cryptography/cryptography.dart';

/// A Noise XX handshake session that produces two CipherState objects
/// for bidirectional encrypted communication.
class NoiseXXHandshake {
  final SimpleKeyPair _staticKeyPair;
  final SimpleKeyPair? _ephemeralKeyPair;

  // Handshake state
  Uint8List _h = Uint8List(0); // handshake hash
  Uint8List _ck = Uint8List(0); // chaining key
  Uint8List? _remoteStaticPublicKey;
  Uint8List? _remoteEphemeralPublicKey;

  // Algorithms
  static final _x25519 = X25519();
  static final _chacha = Chacha20.poly1305Aead();
  static final _sha256 = Sha256();

  // Protocol name for Noise_XX_25519_ChaChaPoly_SHA256
  static final Uint8List _protocolName =
      Uint8List.fromList(utf8.encode('Noise_XX_25519_ChaChaPoly_SHA256'));

  NoiseXXHandshake({
    required SimpleKeyPair staticKeyPair,
    SimpleKeyPair? ephemeralKeyPair,
  })  : _staticKeyPair = staticKeyPair,
        _ephemeralKeyPair = ephemeralKeyPair;

  /// Generate a new X25519 key pair.
  static Future<SimpleKeyPair> generateKeyPair() async {
    return await _x25519.newKeyPair();
  }

  /// Get the remote peer's static public key after handshake completes.
  Uint8List? get remoteStaticPublicKey => _remoteStaticPublicKey;

  // ---------------------------------------------------------------------------
  // Initiator side
  // ---------------------------------------------------------------------------

  /// Initiator message 1: -> e
  Future<Uint8List> initiatorHello() async {
    _initSymmetricState();

    final ephKp = _ephemeralKeyPair ?? await _x25519.newKeyPair();
    final ephPub = await ephKp.extractPublicKey();
    final ephPubBytes = Uint8List.fromList(ephPub.bytes);

    _mixHash(ephPubBytes);

    // Payload is empty for msg1
    return ephPubBytes;
  }

  /// Initiator processes message 2: <- e, ee, s, es
  /// Returns decrypted payload from responder.
  Future<Uint8List> initiatorProcessResponse(
      Uint8List message, SimpleKeyPair ephKeyPair) async {
    // Read remote ephemeral (32 bytes)
    final re = message.sublist(0, 32);
    _remoteEphemeralPublicKey = re;
    _mixHash(re);

    // DH: ee
    final ephPriv = await ephKeyPair.extractPrivateKeyBytes();
    await _mixKey(await _dh(ephPriv, re));

    // Decrypt remote static public key (32 + 16 tag)
    final encS = message.sublist(32, 80);
    final rs = await _decryptAndHash(encS);
    _remoteStaticPublicKey = rs;

    // DH: es
    await _mixKey(await _dh(ephPriv, rs));

    // Decrypt payload
    final encPayload = message.sublist(80);
    return await _decryptAndHash(encPayload);
  }

  /// Initiator message 3: -> s, se
  Future<Uint8List> initiatorFinish(
      Uint8List payload, SimpleKeyPair ephKeyPair) async {
    // Encrypt our static public key
    final staticPub = await _staticKeyPair.extractPublicKey();
    final encS = await _encryptAndHash(Uint8List.fromList(staticPub.bytes));

    // DH: se
    final staticPriv = await _staticKeyPair.extractPrivateKeyBytes();
    await _mixKey(await _dh(staticPriv, _remoteEphemeralPublicKey!));

    // Encrypt payload
    final encPayload = await _encryptAndHash(payload);

    return Uint8List.fromList([...encS, ...encPayload]);
  }

  // ---------------------------------------------------------------------------
  // Responder side
  // ---------------------------------------------------------------------------

  /// Responder processes message 1: -> e
  Future<void> responderProcessHello(Uint8List message) async {
    _initSymmetricState();

    _remoteEphemeralPublicKey = message.sublist(0, 32);
    _mixHash(_remoteEphemeralPublicKey!);
  }

  /// Responder message 2: <- e, ee, s, es
  Future<Uint8List> responderResponse(Uint8List payload) async {
    final ephKp = _ephemeralKeyPair ?? await _x25519.newKeyPair();
    final ephPub = await ephKp.extractPublicKey();
    final ephPubBytes = Uint8List.fromList(ephPub.bytes);
    _mixHash(ephPubBytes);

    // DH: ee
    final ephPriv = await ephKp.extractPrivateKeyBytes();
    await _mixKey(await _dh(ephPriv, _remoteEphemeralPublicKey!));

    // Encrypt our static public key
    final staticPub = await _staticKeyPair.extractPublicKey();
    final encS = await _encryptAndHash(Uint8List.fromList(staticPub.bytes));

    // DH: es
    final staticPriv = await _staticKeyPair.extractPrivateKeyBytes();
    await _mixKey(await _dh(staticPriv, _remoteEphemeralPublicKey!));

    // Encrypt payload
    final encPayload = await _encryptAndHash(payload);

    return Uint8List.fromList([...ephPubBytes, ...encS, ...encPayload]);
  }

  /// Responder processes message 3: -> s, se
  Future<Uint8List> responderFinish(
      Uint8List message, SimpleKeyPair ephKeyPair) async {
    // Decrypt remote static public key
    final encS = message.sublist(0, 48);
    final rs = await _decryptAndHash(encS);
    _remoteStaticPublicKey = rs;

    // DH: se
    final ephPriv = await ephKeyPair.extractPrivateKeyBytes();
    await _mixKey(await _dh(ephPriv, rs));

    // Decrypt payload
    final encPayload = message.sublist(48);
    return await _decryptAndHash(encPayload);
  }

  /// Split the symmetric state into two CipherState objects after handshake.
  Future<NoiseTransport> split() async {
    final temp = await _hkdf(_ck, Uint8List(0));
    return NoiseTransport(
      sendKey: temp.sublist(0, 32),
      recvKey: temp.sublist(32, 64),
    );
  }

  // ---------------------------------------------------------------------------
  // Symmetric state internals
  // ---------------------------------------------------------------------------

  void _initSymmetricState() {
    if (_protocolName.length <= 32) {
      _h = Uint8List(32);
      _h.setRange(0, _protocolName.length, _protocolName);
    } else {
      // Should not happen for our protocol name
      _h = Uint8List(32);
    }
    _ck = Uint8List.fromList(_h);
  }

  void _mixHash(Uint8List data) {
    final combined = Uint8List.fromList([..._h, ...data]);
    final hash = _sha256Hash(combined);
    _h = hash;
  }

  Future<void> _mixKey(Uint8List inputKeyMaterial) async {
    final temp = await _hkdf(_ck, inputKeyMaterial);
    _ck = temp.sublist(0, 32);
    // The cipher key is temp[32:64], used implicitly via _h
    _mixHash(temp.sublist(32, 64));
  }

  Future<Uint8List> _encryptAndHash(Uint8List plaintext) async {
    // Derive key from current hash state
    final key = _h.sublist(0, 32);
    final nonce = Uint8List(12); // zero nonce, key is unique per encryption

    final secretKey = SecretKey(key);
    final secretBox = await _chacha.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    final ciphertext = Uint8List.fromList([
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
    _mixHash(ciphertext);
    return ciphertext;
  }

  Future<Uint8List> _decryptAndHash(Uint8List ciphertext) async {
    final key = _h.sublist(0, 32);
    final nonce = Uint8List(12);

    final ct = ciphertext.sublist(0, ciphertext.length - 16);
    final tag = ciphertext.sublist(ciphertext.length - 16);

    final secretKey = SecretKey(key);
    final secretBox = SecretBox(
      ct,
      nonce: nonce,
      mac: Mac(tag),
    );

    final plaintext = await _chacha.decrypt(secretBox, secretKey: secretKey);
    _mixHash(ciphertext);
    return Uint8List.fromList(plaintext);
  }

  Future<Uint8List> _dh(List<int> privateKey, Uint8List publicKey) async {
    final keyPair = SimpleKeyPairData(
      privateKey,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
    final remoteKey = SimplePublicKey(publicKey, type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remoteKey,
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  Future<Uint8List> _hkdf(Uint8List salt, Uint8List ikm) async {
    // HKDF-SHA256: extract then expand to 64 bytes
    final hmac1 = await _hmacSha256(salt, ikm);
    final t1 = await _hmacSha256(hmac1, Uint8List.fromList([1]));
    final t2 = await _hmacSha256(hmac1, Uint8List.fromList([...t1, 2]));
    return Uint8List.fromList([...t1, ...t2]);
  }

  Future<Uint8List> _hmacSha256(Uint8List key, Uint8List data) async {
    final hmac = Hmac(_sha256);
    final mac = await hmac.calculateMac(data, secretKey: SecretKey(key));
    return Uint8List.fromList(mac.bytes);
  }

  Uint8List _sha256Hash(Uint8List data) {
    final digest = crypto_pkg.sha256.convert(data);
    return Uint8List.fromList(digest.bytes);
  }
}

/// Post-handshake transport keys for bidirectional encryption.
class NoiseTransport {
  final Uint8List sendKey;
  final Uint8List recvKey;
  int _sendNonce = 0;
  int _recvNonce = 0;

  static final _chacha = Chacha20.poly1305Aead();

  NoiseTransport({required this.sendKey, required this.recvKey});

  /// Encrypt a message for sending.
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final nonce = _buildNonce(_sendNonce++);
    final secretBox = await _chacha.encrypt(
      plaintext,
      secretKey: SecretKey(sendKey),
      nonce: nonce,
    );
    return Uint8List.fromList([
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
  }

  /// Decrypt a received message.
  Future<Uint8List> decrypt(Uint8List ciphertext) async {
    final nonce = _buildNonce(_recvNonce++);
    final ct = ciphertext.sublist(0, ciphertext.length - 16);
    final tag = ciphertext.sublist(ciphertext.length - 16);
    final secretBox = SecretBox(ct, nonce: nonce, mac: Mac(tag));
    final plaintext =
        await _chacha.decrypt(secretBox, secretKey: SecretKey(recvKey));
    return Uint8List.fromList(plaintext);
  }

  Uint8List _buildNonce(int counter) {
    final nonce = ByteData(12);
    nonce.setUint64(4, counter, Endian.little);
    return nonce.buffer.asUint8List();
  }
}
