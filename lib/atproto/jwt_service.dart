/*
 * JWT service for AT Protocol PDS authentication.
 *
 * Simple HS256 JWT for single-user PDS authentication.
 * - Access tokens: short-lived (5 min)
 * - Refresh tokens: long-lived (90 days)
 *
 * Since this is a single-user PDS, the "password" is the station admin
 * credential and the "sub" claim is the repo DID.
 *
 * Reference: https://atproto.com/specs/xrpc#authentication
 */

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// JWT token pair returned by session creation.
class SessionTokens {
  final String accessJwt;
  final String refreshJwt;
  final String did;
  final String handle;

  SessionTokens({
    required this.accessJwt,
    required this.refreshJwt,
    required this.did,
    required this.handle,
  });

  Map<String, dynamic> toJson() => {
    'accessJwt': accessJwt,
    'refreshJwt': refreshJwt,
    'did': did,
    'handle': handle,
  };
}

/// HS256 JWT service for AT Protocol authentication.
class JwtService {
  final String _secret;
  final String _did;
  final String _handle;

  /// Access token lifetime.
  static const accessTokenDuration = Duration(minutes: 5);

  /// Refresh token lifetime.
  static const refreshTokenDuration = Duration(days: 90);

  /// Active refresh token JTIs (for revocation).
  final Set<String> _activeRefreshTokens = {};

  /// Create a JWT service for a single-user PDS.
  ///
  /// [secret] should be a high-entropy random string (e.g., 32 bytes hex).
  /// [did] is the DID of the PDS owner.
  /// [handle] is the AT Proto handle.
  JwtService({
    required String secret,
    required String did,
    required String handle,
  }) : _secret = secret,
       _did = did,
       _handle = handle;

  /// Create a new session (access + refresh tokens).
  SessionTokens createSession() {
    final now = DateTime.now();
    final accessJwt = _createToken(
      sub: _did,
      scope: 'com.atproto.access',
      exp: now.add(accessTokenDuration),
      iat: now,
    );
    final refreshJti = _generateJti();
    final refreshJwt = _createToken(
      sub: _did,
      scope: 'com.atproto.refresh',
      exp: now.add(refreshTokenDuration),
      iat: now,
      jti: refreshJti,
    );
    _activeRefreshTokens.add(refreshJti);

    return SessionTokens(
      accessJwt: accessJwt,
      refreshJwt: refreshJwt,
      did: _did,
      handle: _handle,
    );
  }

  /// Refresh a session: validate refresh token, revoke it, issue new pair.
  ///
  /// Returns null if the refresh token is invalid or expired.
  SessionTokens? refreshSession(String refreshJwt) {
    final claims = verifyToken(refreshJwt);
    if (claims == null) return null;
    if (claims['scope'] != 'com.atproto.refresh') return null;

    final jti = claims['jti'] as String?;
    if (jti == null || !_activeRefreshTokens.contains(jti)) return null;

    // Revoke the old refresh token
    _activeRefreshTokens.remove(jti);

    // Issue new tokens
    return createSession();
  }

  /// Delete a session by revoking the refresh token.
  bool deleteSession(String refreshJwt) {
    final claims = verifyToken(refreshJwt);
    if (claims == null) return false;

    final jti = claims['jti'] as String?;
    if (jti != null) {
      _activeRefreshTokens.remove(jti);
    }
    return true;
  }

  /// Verify an access token from an Authorization header.
  ///
  /// Returns the DID (sub claim) if valid, null otherwise.
  String? verifyAccessToken(String token) {
    final claims = verifyToken(token);
    if (claims == null) return null;
    if (claims['scope'] != 'com.atproto.access') return null;
    return claims['sub'] as String?;
  }

  /// Verify a JWT and return its claims, or null if invalid/expired.
  Map<String, dynamic>? verifyToken(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;

      // Verify signature
      final signingInput = '${parts[0]}.${parts[1]}';
      final expectedSig = _hmacSign(signingInput);
      if (parts[2] != expectedSig) return null;

      // Decode payload
      final payload = _base64UrlDecode(parts[1]);
      final claims = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;

      // Check expiration
      final exp = claims['exp'] as int?;
      if (exp != null) {
        final expiry = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
        if (DateTime.now().isAfter(expiry)) return null;
      }

      // Check subject matches our DID
      if (claims['sub'] != _did) return null;

      return claims;
    } catch (_) {
      return null;
    }
  }

  // -- JWT construction --

  String _createToken({
    required String sub,
    required String scope,
    required DateTime exp,
    required DateTime iat,
    String? jti,
  }) {
    final header = {'alg': 'HS256', 'typ': 'JWT'};
    final payload = <String, dynamic>{
      'sub': sub,
      'scope': scope,
      'iat': iat.millisecondsSinceEpoch ~/ 1000,
      'exp': exp.millisecondsSinceEpoch ~/ 1000,
    };
    if (jti != null) payload['jti'] = jti;

    final headerB64 = _base64UrlEncode(utf8.encode(jsonEncode(header)));
    final payloadB64 = _base64UrlEncode(utf8.encode(jsonEncode(payload)));
    final signingInput = '$headerB64.$payloadB64';
    final signature = _hmacSign(signingInput);

    return '$signingInput.$signature';
  }

  String _hmacSign(String input) {
    final hmac = Hmac(sha256, utf8.encode(_secret));
    final digest = hmac.convert(utf8.encode(input));
    return _base64UrlEncode(digest.bytes);
  }

  static String _generateJti() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // -- Base64url helpers --

  static String _base64UrlEncode(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Uint8List _base64UrlDecode(String encoded) {
    // Add padding if needed
    var padded = encoded;
    while (padded.length % 4 != 0) {
      padded += '=';
    }
    return base64Url.decode(padded);
  }
}
