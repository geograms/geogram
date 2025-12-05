/*
 * NIP-07 NOSTR Extension Stub for non-web platforms
 *
 * This is a stub implementation that returns unavailable for all operations.
 * On web, the real implementation in nostr_extension_web.dart is used instead.
 */

/// NIP-07 Extension service stub for non-web platforms
class NostrExtensionService {
  static final NostrExtensionService _instance = NostrExtensionService._internal();
  factory NostrExtensionService() => _instance;
  NostrExtensionService._internal();

  /// Always returns false on non-web platforms
  bool get isAvailable => false;

  /// Always returns null on non-web platforms
  String? get cachedPubkey => null;

  /// No-op on non-web platforms
  Future<void> initialize() async {}

  /// Always returns false on non-web platforms
  bool recheckAvailability() => false;

  /// Always returns null on non-web platforms
  Future<String?> getPublicKey() async => null;

  /// Always returns null on non-web platforms
  Future<Map<String, dynamic>?> signEvent(Map<String, dynamic> event) async => null;

  /// Always returns null on non-web platforms
  Future<Map<String, dynamic>?> getRelays() async => null;

  /// Always returns null on non-web platforms
  Future<String?> nip04Encrypt(String pubkey, String plaintext) async => null;

  /// Always returns null on non-web platforms
  Future<String?> nip04Decrypt(String pubkey, String ciphertext) async => null;
}

/// Factory function for conditional import
NostrExtensionService createNostrExtensionService() => NostrExtensionService();
