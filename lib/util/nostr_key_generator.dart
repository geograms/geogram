/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NOSTR Key Generator - Uses proper secp256k1 cryptography
 */

import 'nostr_crypto.dart';

/// Generates NOSTR key pairs (npub/nsec) using secp256k1
class NostrKeyGenerator {
  /// Generate a new key pair with proper secp256k1 keys
  static NostrKeys generateKeyPair() {
    final keyPair = NostrCrypto.generateKeyPair();
    return NostrKeys(
      npub: keyPair.npub,
      nsec: keyPair.nsec,
      callsign: keyPair.callsign,
    );
  }

  /// Derive user/operator callsign from npub
  /// Format: X1 + first 4 characters after 'npub1'
  static String deriveCallsign(String npub) {
    return _deriveCallsignFromNpub(npub, 'X1');
  }

  /// Derive relay callsign from npub
  /// Format: X3 + first 4 characters after 'npub1'
  static String deriveRelayCallsign(String npub) {
    return _deriveCallsignFromNpub(npub, 'X3');
  }

  /// Derive callsign from npub with given prefix
  /// Takes the first 4 characters after 'npub1' and uppercases them
  static String _deriveCallsignFromNpub(String npub, String prefix) {
    if (npub.length < 9 || !npub.toLowerCase().startsWith('npub1')) {
      throw ArgumentError('Invalid npub format');
    }

    // Extract first 4 characters after 'npub1' and uppercase
    final suffix = npub.substring(5, 9).toUpperCase();

    return '$prefix$suffix';
  }

  /// Validate npub format (must be proper bech32-encoded public key)
  static bool isValidNpub(String npub) {
    try {
      if (!npub.startsWith('npub1')) return false;
      NostrCrypto.decodeNpub(npub);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Validate nsec format (must be proper bech32-encoded private key)
  static bool isValidNsec(String nsec) {
    try {
      if (!nsec.startsWith('nsec1')) return false;
      NostrCrypto.decodeNsec(nsec);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Get public key hex from npub (returns null if invalid)
  static String? getPublicKeyHex(String npub) {
    try {
      return NostrCrypto.decodeNpub(npub);
    } catch (e) {
      return null;
    }
  }

  /// Get private key hex from nsec (returns null if invalid)
  static String? getPrivateKeyHex(String nsec) {
    try {
      return NostrCrypto.decodeNsec(nsec);
    } catch (e) {
      return null;
    }
  }

  /// Derive npub from nsec
  static String? derivePublicKey(String nsec) {
    try {
      final privateKeyHex = NostrCrypto.decodeNsec(nsec);
      final publicKeyHex = NostrCrypto.derivePublicKey(privateKeyHex);
      return NostrCrypto.encodeNpub(publicKeyHex);
    } catch (e) {
      return null;
    }
  }
}

/// NOSTR key pair with callsign
class NostrKeys {
  final String npub; // Public key (bech32 encoded)
  final String nsec; // Private key (bech32 encoded, secret!)
  final String callsign; // Derived callsign

  NostrKeys({
    required this.npub,
    required this.nsec,
    String? callsign,
  }) : callsign = callsign ?? NostrKeyGenerator.deriveCallsign(npub);

  /// Create a relay key pair with X3 callsign prefix
  factory NostrKeys.forRelay() {
    final keys = NostrKeyGenerator.generateKeyPair();
    return NostrKeys(
      npub: keys.npub,
      nsec: keys.nsec,
      callsign: NostrKeyGenerator.deriveRelayCallsign(keys.npub),
    );
  }

  /// Get the hex-encoded public key
  String? get publicKeyHex => NostrKeyGenerator.getPublicKeyHex(npub);

  /// Get the hex-encoded private key (use with caution!)
  String? get privateKeyHex => NostrKeyGenerator.getPrivateKeyHex(nsec);

  Map<String, dynamic> toJson() {
    return {
      'npub': npub,
      'nsec': nsec,
      'callsign': callsign,
      'created': DateTime.now().millisecondsSinceEpoch,
    };
  }

  factory NostrKeys.fromJson(Map<String, dynamic> json) {
    return NostrKeys(
      npub: json['npub'] as String,
      nsec: json['nsec'] as String,
      callsign: json['callsign'] as String?,
    );
  }
}
