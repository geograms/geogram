/*
 * NIP-07 NOSTR Extension Support for Web
 *
 * This provides integration with browser extensions that implement NIP-07
 * (e.g., Alby, nos2x, Flamingo) for secure key management.
 *
 * The extension handles private key storage and signing, so the app
 * never needs to access or store the nsec on web.
 */

// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;
import 'dart:async';
import 'dart:convert';

/// NIP-07 Extension service for web browsers
class NostrExtensionService {
  static final NostrExtensionService _instance = NostrExtensionService._internal();
  factory NostrExtensionService() => _instance;
  NostrExtensionService._internal();

  bool _initialized = false;
  bool _extensionAvailable = false;
  String? _cachedPubkey;

  /// Check if a NIP-07 extension is available
  bool get isAvailable => _extensionAvailable;

  /// Get cached public key (after successful getPublicKey call)
  String? get cachedPubkey => _cachedPubkey;

  /// Initialize and detect extension availability
  Future<void> initialize() async {
    if (_initialized) return;

    _extensionAvailable = _checkExtensionAvailable();
    _initialized = true;

    if (_extensionAvailable) {
      print('NIP-07 extension detected');
    } else {
      print('No NIP-07 extension found');
    }
  }

  /// Check if window.nostr exists
  bool _checkExtensionAvailable() {
    try {
      final nostr = js.context['nostr'];
      return nostr != null && nostr != js.context['undefined'];
    } catch (e) {
      return false;
    }
  }

  /// Re-check extension availability (useful after page load)
  bool recheckAvailability() {
    _extensionAvailable = _checkExtensionAvailable();
    return _extensionAvailable;
  }

  /// Get public key from extension (NIP-07: window.nostr.getPublicKey())
  /// Returns the public key in hex format
  Future<String?> getPublicKey() async {
    if (!_extensionAvailable) {
      recheckAvailability();
      if (!_extensionAvailable) return null;
    }

    try {
      final completer = Completer<String?>();

      final nostr = js.context['nostr'];
      final promise = nostr.callMethod('getPublicKey', []);

      // Convert JS Promise to Dart Future
      js.context['Promise'].callMethod('resolve', [promise]).callMethod('then', [
        js.allowInterop((result) {
          final pubkey = result?.toString();
          _cachedPubkey = pubkey;
          completer.complete(pubkey);
        }),
        js.allowInterop((error) {
          print('NIP-07 getPublicKey error: $error');
          completer.complete(null);
        }),
      ]);

      return await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          print('NIP-07 getPublicKey timeout');
          return null;
        },
      );
    } catch (e) {
      print('Error calling NIP-07 getPublicKey: $e');
      return null;
    }
  }

  /// Sign an event using the extension (NIP-07: window.nostr.signEvent())
  /// Takes a NOSTR event object and returns the signed event with sig field
  Future<Map<String, dynamic>?> signEvent(Map<String, dynamic> event) async {
    if (!_extensionAvailable) {
      recheckAvailability();
      if (!_extensionAvailable) return null;
    }

    try {
      final completer = Completer<Map<String, dynamic>?>();

      // Convert Dart map to JS object
      final jsEvent = js.JsObject.jsify(event);

      final nostr = js.context['nostr'];
      final promise = nostr.callMethod('signEvent', [jsEvent]);

      // Convert JS Promise to Dart Future
      js.context['Promise'].callMethod('resolve', [promise]).callMethod('then', [
        js.allowInterop((result) {
          if (result == null) {
            completer.complete(null);
            return;
          }

          // Convert JS object back to Dart map
          try {
            final jsonStr = js.context['JSON'].callMethod('stringify', [result]);
            final signedEvent = jsonDecode(jsonStr.toString()) as Map<String, dynamic>;
            completer.complete(signedEvent);
          } catch (e) {
            print('Error parsing signed event: $e');
            completer.complete(null);
          }
        }),
        js.allowInterop((error) {
          print('NIP-07 signEvent error: $error');
          completer.complete(null);
        }),
      ]);

      return await completer.future.timeout(
        const Duration(seconds: 60), // Longer timeout for user interaction
        onTimeout: () {
          print('NIP-07 signEvent timeout - user may have declined');
          return null;
        },
      );
    } catch (e) {
      print('Error calling NIP-07 signEvent: $e');
      return null;
    }
  }

  /// Get relays from extension (NIP-07: window.nostr.getRelays())
  /// Returns a map of relay URLs to read/write permissions
  Future<Map<String, dynamic>?> getRelays() async {
    if (!_extensionAvailable) return null;

    try {
      final completer = Completer<Map<String, dynamic>?>();

      final nostr = js.context['nostr'];

      // Check if getRelays method exists
      if (nostr['getRelays'] == null) {
        return null;
      }

      final promise = nostr.callMethod('getRelays', []);

      js.context['Promise'].callMethod('resolve', [promise]).callMethod('then', [
        js.allowInterop((result) {
          if (result == null) {
            completer.complete(null);
            return;
          }

          try {
            final jsonStr = js.context['JSON'].callMethod('stringify', [result]);
            final relays = jsonDecode(jsonStr.toString()) as Map<String, dynamic>;
            completer.complete(relays);
          } catch (e) {
            completer.complete(null);
          }
        }),
        js.allowInterop((error) {
          completer.complete(null);
        }),
      ]);

      return await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );
    } catch (e) {
      return null;
    }
  }

  /// Encrypt content using NIP-04 (if supported by extension)
  Future<String?> nip04Encrypt(String pubkey, String plaintext) async {
    if (!_extensionAvailable) return null;

    try {
      final completer = Completer<String?>();

      final nostr = js.context['nostr'];
      final nip04 = nostr['nip04'];

      if (nip04 == null) return null;

      final promise = nip04.callMethod('encrypt', [pubkey, plaintext]);

      js.context['Promise'].callMethod('resolve', [promise]).callMethod('then', [
        js.allowInterop((result) {
          completer.complete(result?.toString());
        }),
        js.allowInterop((error) {
          completer.complete(null);
        }),
      ]);

      return await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => null,
      );
    } catch (e) {
      return null;
    }
  }

  /// Decrypt content using NIP-04 (if supported by extension)
  Future<String?> nip04Decrypt(String pubkey, String ciphertext) async {
    if (!_extensionAvailable) return null;

    try {
      final completer = Completer<String?>();

      final nostr = js.context['nostr'];
      final nip04 = nostr['nip04'];

      if (nip04 == null) return null;

      final promise = nip04.callMethod('decrypt', [pubkey, ciphertext]);

      js.context['Promise'].callMethod('resolve', [promise]).callMethod('then', [
        js.allowInterop((result) {
          completer.complete(result?.toString());
        }),
        js.allowInterop((error) {
          completer.complete(null);
        }),
      ]);

      return await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => null,
      );
    } catch (e) {
      return null;
    }
  }
}

/// Factory function for conditional import
NostrExtensionService createNostrExtensionService() => NostrExtensionService();
