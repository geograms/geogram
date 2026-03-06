/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BitChat identity configuration.
 * Persisted as JSON via ProfileStorage at teleport/bitchat/config.json.
 *
 * Keys:
 *   - staticKeyHex: X25519 private key, hex-encoded 32 bytes
 *   - staticPublicKeyHex: X25519 public key, hex-encoded 32 bytes
 *   - signingKeyHex: Ed25519 private seed, hex-encoded 32 bytes
 *   - signingPublicKeyHex: Ed25519 public key, hex-encoded 32 bytes
 *
 * Sender ID is derived from the first 8 bytes of the static PUBLIC key
 * (not the private key). This matches the BitChat wire protocol.
 */

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class BitchatConfig {
  final String nickname;
  final String staticKeyHex;
  final String staticPublicKeyHex;
  final String signingKeyHex;
  final String signingPublicKeyHex;
  final String defaultGeohash;
  final int geohashPrecision;
  final bool bleEnabled;
  final bool autoStart;

  const BitchatConfig({
    required this.nickname,
    required this.staticKeyHex,
    required this.staticPublicKeyHex,
    required this.signingKeyHex,
    required this.signingPublicKeyHex,
    this.defaultGeohash = '',
    this.geohashPrecision = 4,
    this.bleEnabled = true,
    this.autoStart = false,
  });

  /// Sender ID: first 8 bytes (16 hex chars) of the static PUBLIC key.
  String get senderId => staticPublicKeyHex.length >= 16
      ? staticPublicKeyHex.substring(0, 16)
      : staticPublicKeyHex;

  Map<String, dynamic> toJson() => {
        'nickname': nickname,
        'staticKeyHex': staticKeyHex,
        'staticPublicKeyHex': staticPublicKeyHex,
        'signingKeyHex': signingKeyHex,
        'signingPublicKeyHex': signingPublicKeyHex,
        'defaultGeohash': defaultGeohash,
        'geohashPrecision': geohashPrecision,
        'bleEnabled': bleEnabled,
        'autoStart': autoStart,
      };

  factory BitchatConfig.fromJson(Map<String, dynamic> json) {
    return BitchatConfig(
      nickname: json['nickname'] as String? ?? 'anon',
      staticKeyHex: json['staticKeyHex'] as String? ?? '',
      staticPublicKeyHex: json['staticPublicKeyHex'] as String? ?? '',
      signingKeyHex: json['signingKeyHex'] as String? ?? '',
      signingPublicKeyHex: json['signingPublicKeyHex'] as String? ?? '',
      defaultGeohash: json['defaultGeohash'] as String? ?? '',
      geohashPrecision: json['geohashPrecision'] as int? ?? 4,
      bleEnabled: json['bleEnabled'] as bool? ?? true,
      autoStart: json['autoStart'] as bool? ?? false,
    );
  }

  BitchatConfig copyWith({
    String? nickname,
    String? staticKeyHex,
    String? staticPublicKeyHex,
    String? signingKeyHex,
    String? signingPublicKeyHex,
    String? defaultGeohash,
    int? geohashPrecision,
    bool? bleEnabled,
    bool? autoStart,
  }) {
    return BitchatConfig(
      nickname: nickname ?? this.nickname,
      staticKeyHex: staticKeyHex ?? this.staticKeyHex,
      staticPublicKeyHex: staticPublicKeyHex ?? this.staticPublicKeyHex,
      signingKeyHex: signingKeyHex ?? this.signingKeyHex,
      signingPublicKeyHex: signingPublicKeyHex ?? this.signingPublicKeyHex,
      defaultGeohash: defaultGeohash ?? this.defaultGeohash,
      geohashPrecision: geohashPrecision ?? this.geohashPrecision,
      bleEnabled: bleEnabled ?? this.bleEnabled,
      autoStart: autoStart ?? this.autoStart,
    );
  }

  /// Generate a new identity with proper X25519 and Ed25519 keypairs.
  static Future<BitchatConfig> generateNew({String nickname = 'anon'}) async {
    // X25519 keypair for Noise handshake
    final x25519 = X25519();
    final staticKp = await x25519.newKeyPair();
    final staticPrivBytes = await staticKp.extractPrivateKeyBytes();
    final staticPub = await staticKp.extractPublicKey();

    // Ed25519 keypair for packet signing
    final ed25519 = Ed25519();
    final signingKp = await ed25519.newKeyPair();
    final signingPrivBytes = await signingKp.extractPrivateKeyBytes();
    final signingPub = await signingKp.extractPublicKey();

    return BitchatConfig(
      nickname: nickname,
      staticKeyHex: _bytesToHex(Uint8List.fromList(staticPrivBytes)),
      staticPublicKeyHex: _bytesToHex(Uint8List.fromList(staticPub.bytes)),
      signingKeyHex: _bytesToHex(Uint8List.fromList(signingPrivBytes)),
      signingPublicKeyHex: _bytesToHex(Uint8List.fromList(signingPub.bytes)),
    );
  }

  /// Check if this config has valid keys (non-empty public keys).
  bool get hasValidKeys =>
      staticPublicKeyHex.length == 64 && signingPublicKeyHex.length == 64;

  /// Reconstruct the X25519 SimpleKeyPair from stored hex keys.
  Future<SimpleKeyPair> getStaticKeyPair() async {
    final privBytes = _hexToBytes(staticKeyHex);
    final pubBytes = _hexToBytes(staticPublicKeyHex);
    return SimpleKeyPairData(
      privBytes,
      publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
  }

  static String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
