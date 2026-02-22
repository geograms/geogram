/*
 * DID:web service for AT Protocol PDS.
 *
 * Generates and serves DID documents at /.well-known/did.json.
 *
 * DID:web format: did:web:<domain>
 * The DID document includes:
 * - Verification method with secp256k1 Multikey
 * - AT Proto PDS service endpoint
 * - alsoKnownAs with the AT handle
 *
 * Reference: https://atproto.com/specs/did
 *            https://w3c-ccg.github.io/did-method-web/
 */

import 'dart:typed_data';

import 'signing.dart';

/// DID:web document service.
class DidService {
  final String _domain;
  final Uint8List _publicKey;
  String _handle;

  /// Create a DID service for a domain.
  ///
  /// [domain] is the station's domain (e.g., "example.geogram.radio").
  /// [publicKey] is the 33-byte compressed secp256k1 public key.
  /// [handle] is the AT Proto handle (e.g., "user.geogram.radio").
  DidService({
    required String domain,
    required Uint8List publicKey,
    required String handle,
  }) : _domain = domain,
       _publicKey = publicKey,
       _handle = handle;

  /// The DID string for this service.
  String get did => 'did:web:$_domain';

  /// The current handle.
  String get handle => _handle;

  /// Update the handle.
  set handle(String value) => _handle = value;

  /// The service endpoint URL.
  String get serviceEndpoint {
    return 'https://$_domain';
  }

  /// Generate the DID document as a JSON map.
  ///
  /// This is the document served at /.well-known/did.json.
  Map<String, dynamic> buildDidDocument() {
    final multikey = AtprotoSigning.publicKeyToMultikey(_publicKey);

    return {
      '@context': [
        'https://www.w3.org/ns/did/v1',
        'https://w3id.org/security/multikey/v1',
        'https://w3id.org/security/suites/secp256k1-2019/v1',
      ],
      'id': did,
      'alsoKnownAs': [
        'at://$_handle',
      ],
      'verificationMethod': [
        {
          'id': '$did#atproto',
          'type': 'Multikey',
          'controller': did,
          'publicKeyMultibase': multikey,
        },
      ],
      'service': [
        {
          'id': '#atproto_pds',
          'type': 'AtprotoPersonalDataServer',
          'serviceEndpoint': serviceEndpoint,
        },
      ],
    };
  }

  /// Resolve a DID string to its domain.
  ///
  /// Returns null if the DID is not a valid did:web.
  static String? resolveDomain(String did) {
    if (!did.startsWith('did:web:')) return null;
    final domain = did.substring('did:web:'.length);
    // did:web encodes path separators as colons
    return domain.replaceAll(':', '/');
  }

  /// Check if a DID matches this service.
  bool isDid(String did) => did == this.did;
}
