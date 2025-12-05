/*
 * NIP-07 NOSTR Extension Service
 *
 * Conditional import wrapper that uses the web implementation on browsers
 * and a stub implementation on native platforms.
 */

export 'nostr_extension_stub.dart'
    if (dart.library.html) 'nostr_extension_web.dart';
