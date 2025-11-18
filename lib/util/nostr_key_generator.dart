import 'dart:math';
import 'dart:typed_data';

/// Generates NOSTR key pairs (npub/nsec)
class NostrKeyGenerator {
  /// Generate a new key pair
  static NostrKeys generateKeyPair() {
    try {
      final random = Random.secure();

      // Generate 32 bytes for private key (nsec)
      final privateKeyBytes = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        privateKeyBytes[i] = random.nextInt(256);
      }

      // For public key, we'd normally derive it from private key using secp256k1
      // For now, generate separate 32 bytes (simplified implementation)
      final publicKeyBytes = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        publicKeyBytes[i] = random.nextInt(256);
      }

      // Convert to hex and create bech32-like format
      // Format: npub1[59 hex chars], nsec1[59 hex chars]
      final npub = 'npub1${_bytesToHex(publicKeyBytes).substring(0, 59)}';
      final nsec = 'nsec1${_bytesToHex(privateKeyBytes).substring(0, 59)}';

      return NostrKeys(npub: npub, nsec: nsec);
    } catch (e) {
      // Fallback to timestamp-based generation
      return _generateFallbackKeys();
    }
  }

  /// Fallback key generation using timestamp
  static NostrKeys _generateFallbackKeys() {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final random = Random(timestamp);

    final publicKeyBytes = Uint8List(32);
    final privateKeyBytes = Uint8List(32);

    for (int i = 0; i < 32; i++) {
      publicKeyBytes[i] = random.nextInt(256);
      privateKeyBytes[i] = random.nextInt(256);
    }

    final npub = 'npub1${_bytesToHex(publicKeyBytes).substring(0, 59)}';
    final nsec = 'nsec1${_bytesToHex(privateKeyBytes).substring(0, 59)}';

    return NostrKeys(npub: npub, nsec: nsec);
  }

  /// Convert bytes to hex string
  static String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  /// Derive callsign from npub
  /// Format: X1 + first 4 characters after 'npub1'
  /// Example: npub1abcd... -> X1ABCD
  static String deriveCallsign(String npub) {
    if (!npub.toLowerCase().startsWith('npub1')) {
      throw ArgumentError('Invalid npub format');
    }

    // Extract data after 'npub1'
    final data = npub.substring(5);

    // Take first 4 characters and uppercase
    var suffix = data.substring(0, data.length >= 4 ? 4 : data.length).toUpperCase();

    // Ensure we have exactly 4 characters (pad with X if needed)
    while (suffix.length < 4) {
      suffix += 'X';
    }

    return 'X1$suffix';
  }
}

/// NOSTR key pair with callsign
class NostrKeys {
  final String npub; // Public key (collection ID)
  final String nsec; // Private key (secret)
  final String callsign; // Derived callsign

  NostrKeys({
    required this.npub,
    required this.nsec,
    String? callsign,
  }) : callsign = callsign ?? NostrKeyGenerator.deriveCallsign(npub);

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
