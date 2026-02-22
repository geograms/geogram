/*
 * AT-URI parser for AT Protocol.
 *
 * Parses AT-URIs of the form: at://{authority}/{collection}/{rkey}
 * Authority is a DID (did:web:..., did:plc:...) or a handle.
 *
 * Reference: https://atproto.com/specs/at-uri-scheme
 */

/// Parsed AT-URI with authority (DID or handle), collection (NSID), and rkey.
class AtUri {
  final String authority;
  final String? collection;
  final String? rkey;

  AtUri({required this.authority, this.collection, this.rkey});

  /// Parse an AT-URI string.
  ///
  /// Valid forms:
  /// - `at://did:web:example.com`
  /// - `at://did:web:example.com/app.bsky.feed.post`
  /// - `at://did:web:example.com/app.bsky.feed.post/3jui7p2blaz2c`
  factory AtUri.parse(String uri) {
    if (!uri.startsWith('at://')) {
      throw FormatException('AT-URI must start with "at://": $uri');
    }

    final rest = uri.substring('at://'.length);
    if (rest.isEmpty) {
      throw FormatException('AT-URI missing authority: $uri');
    }

    final parts = rest.split('/');
    final authority = parts[0];
    if (authority.isEmpty) {
      throw FormatException('AT-URI has empty authority: $uri');
    }

    final collection = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
    final rkey = parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null;

    return AtUri(authority: authority, collection: collection, rkey: rkey);
  }

  /// Try to parse an AT-URI, returning null on failure.
  static AtUri? tryParse(String uri) {
    try {
      return AtUri.parse(uri);
    } catch (_) {
      return null;
    }
  }

  /// Whether this is a valid AT-URI with all three components.
  bool get isRecord => collection != null && rkey != null;

  /// Whether the authority is a DID (starts with "did:").
  bool get isDid => authority.startsWith('did:');

  @override
  String toString() {
    final sb = StringBuffer('at://$authority');
    if (collection != null) {
      sb.write('/$collection');
      if (rkey != null) {
        sb.write('/$rkey');
      }
    }
    return sb.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is AtUri &&
      authority == other.authority &&
      collection == other.collection &&
      rkey == other.rkey;

  @override
  int get hashCode => Object.hash(authority, collection, rkey);
}
