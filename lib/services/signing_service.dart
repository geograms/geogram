/*
 * Signing Service
 *
 * Provides a unified interface for signing NOSTR events.
 * On web with extension mode enabled, uses NIP-07 browser extension.
 * Otherwise, uses the local nsec for signing.
 */

import 'package:flutter/foundation.dart' show kIsWeb;
import '../models/profile.dart';
import '../platform/nostr_extension.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
import 'log_service.dart';

/// Signing service singleton - handles NOSTR event signing
class SigningService {
  static final SigningService _instance = SigningService._internal();
  factory SigningService() => _instance;
  SigningService._internal();

  NostrExtensionService? _extensionService;
  bool _initialized = false;

  /// Initialize the signing service
  Future<void> initialize() async {
    if (_initialized) return;

    _extensionService = NostrExtensionService();
    await _extensionService!.initialize();
    _initialized = true;
  }

  /// Check if NIP-07 extension is available (web only)
  bool get isExtensionAvailable => kIsWeb && (_extensionService?.isAvailable ?? false);

  /// Re-check extension availability
  bool recheckExtension() {
    if (!kIsWeb) return false;
    return _extensionService?.recheckAvailability() ?? false;
  }

  /// Get public key from extension (web only)
  Future<String?> getExtensionPublicKey() async {
    if (!kIsWeb) return null;
    return await _extensionService?.getPublicKey();
  }

  /// Check if a profile should use extension signing
  bool shouldUseExtension(Profile profile) {
    return kIsWeb && profile.useExtension && isExtensionAvailable;
  }

  /// Check if a profile can sign events
  bool canSign(Profile profile) {
    if (shouldUseExtension(profile)) {
      return true;
    }
    return profile.nsec.isNotEmpty;
  }

  /// Sign a NOSTR event
  /// Returns the signed event, or null if signing failed
  Future<NostrEvent?> signEvent(NostrEvent event, Profile profile) async {
    // Ensure event has an ID
    if (event.id == null) {
      event.calculateId();
    }

    if (shouldUseExtension(profile)) {
      return await _signWithExtension(event);
    } else if (profile.nsec.isNotEmpty) {
      return _signWithNsec(event, profile.nsec);
    }

    LogService().log('Cannot sign event: no nsec and extension not available');
    return null;
  }

  /// Sign event using local nsec
  NostrEvent _signWithNsec(NostrEvent event, String nsec) {
    try {
      event.signWithNsec(nsec);
      return event;
    } catch (e) {
      LogService().log('Error signing with nsec: $e');
      return event;
    }
  }

  /// Sign event using NIP-07 extension
  Future<NostrEvent?> _signWithExtension(NostrEvent event) async {
    try {
      // Prepare unsigned event for extension
      final unsignedEvent = {
        'pubkey': event.pubkey,
        'created_at': event.createdAt,
        'kind': event.kind,
        'tags': event.tags,
        'content': event.content,
      };

      // Request signature from extension
      final signedEvent = await _extensionService?.signEvent(unsignedEvent);
      if (signedEvent == null) {
        LogService().log('Extension signing returned null (user declined?)');
        return null;
      }

      // Return the signed event
      return NostrEvent.fromJson(signedEvent);
    } catch (e) {
      LogService().log('Error signing with extension: $e');
      return null;
    }
  }

  /// Generate a BIP-340 Schnorr signature for arbitrary data
  /// Used for chat message signatures
  Future<String?> generateSignature(
    String content,
    Map<String, String> metadata,
    Profile profile,
  ) async {
    try {
      if (!canSign(profile)) {
        return null;
      }

      // Get pubkey hex
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);

      // Create a NOSTR event for signing
      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: content,
        tags: [
          ['t', 'chat'],
          ['channel', metadata['channel'] ?? 'main'],
        ],
      );

      // Sign the event
      final signedEvent = await signEvent(event, profile);
      return signedEvent?.sig;
    } catch (e) {
      LogService().log('Error generating signature: $e');
      return null;
    }
  }

  /// Get relays from extension (if available)
  Future<Map<String, dynamic>?> getExtensionRelays() async {
    if (!kIsWeb) return null;
    return await _extensionService?.getRelays();
  }

  /// Encrypt content using NIP-04 (extension only)
  Future<String?> nip04Encrypt(String pubkey, String plaintext) async {
    if (!kIsWeb) return null;
    return await _extensionService?.nip04Encrypt(pubkey, plaintext);
  }

  /// Decrypt content using NIP-04 (extension only)
  Future<String?> nip04Decrypt(String pubkey, String ciphertext) async {
    if (!kIsWeb) return null;
    return await _extensionService?.nip04Decrypt(pubkey, ciphertext);
  }
}
