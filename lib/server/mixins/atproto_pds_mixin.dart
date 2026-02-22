/*
 * AT Protocol PDS mixin for Geogram stations.
 *
 * Provides AT Proto PDS functionality to both AppStationServer and
 * CliStationServer. Handles:
 * - XRPC routing (/xrpc/*)
 * - DID document serving (/.well-known/did.json)
 * - JWT-based session authentication
 * - Repository initialization and management
 * - Debug API endpoints (/api/atproto/*)
 *
 * Usage:
 *   class MyServer extends StationServerBase with AtprotoPdsMixin { ... }
 */

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../atproto/atproto_storage.dart';
import '../../atproto/did_service.dart';
import '../../atproto/jwt_service.dart';
import '../../atproto/repo.dart';
import '../../atproto/signing.dart';
import '../../atproto/xrpc_router.dart';
import '../../atproto/xrpc/server_endpoints.dart';
import '../../atproto/xrpc/identity_endpoints.dart';
import '../../atproto/xrpc/repo_endpoints.dart';
import '../../services/nostr_blossom_service.dart';
import '../station_settings.dart';

/// AT Protocol PDS mixin for station servers.
mixin AtprotoPdsMixin {
  // -- Abstract dependencies (provided by StationServerBase) --

  void log(String level, String message);
  StationSettings get settings;
  String? get dataDir;
  NostrBlossomService? get blossom;

  // -- AT Proto state --

  XrpcRouter? _xrpcRouter;
  AtprotoStorage? _atprotoStorage;
  AtprotoRepo? _atprotoRepo;
  JwtService? _jwtService;
  DidService? _didService;
  String? _adminPassword;

  /// Whether the AT Proto PDS is initialized and running.
  bool get isAtprotoRunning => _xrpcRouter != null;

  /// The DID of this PDS, or null if not initialized.
  String? get atprotoDid => _didService?.did;

  // -- Lifecycle --

  /// Initialize the AT Protocol PDS.
  ///
  /// Call this from onServerStart() when atprotoEnabled is true.
  Future<void> startAtprotoPds() async {
    if (!settings.atprotoEnabled) return;

    final domain = settings.sslDomain ?? settings.atprotoHandle;
    if (domain == null || domain.isEmpty) {
      log('WARN', 'AT Proto: cannot start without domain (sslDomain or atprotoHandle)');
      return;
    }

    final handle = settings.atprotoHandle ?? domain;

    try {
      // Open or create storage
      final dbPath = '$dataDir/atproto/repo.db';
      _atprotoStorage = AtprotoStorage.open(dbPath);

      // Derive or load signing key
      // Use a deterministic key from the station's NOSTR nsec for simplicity
      final signingKey = _deriveSigningKey();
      final publicKey = AtprotoSigning.derivePublicKey(signingKey);

      // Initialize DID service
      _didService = DidService(
        domain: domain,
        publicKey: publicKey,
        handle: handle,
      );

      // Generate or load admin password for session auth
      _adminPassword = _generateAdminPassword();

      // Initialize JWT service
      _jwtService = JwtService(
        secret: _generateJwtSecret(),
        did: _didService!.did,
        handle: handle,
      );

      // Open or create repo
      _atprotoRepo = AtprotoRepo.open(
        did: _didService!.did,
        storage: _atprotoStorage!,
      );
      if (_atprotoRepo == null) {
        _atprotoRepo = AtprotoRepo.create(
          did: _didService!.did,
          storage: _atprotoStorage!,
          signingKey: signingKey,
        );
        // Create initial commit
        _atprotoRepo!.commit();
        log('INFO', 'AT Proto: created new repo for ${_didService!.did}');
      } else {
        log('INFO', 'AT Proto: opened existing repo for ${_didService!.did}');
      }

      // Set up XRPC router
      _xrpcRouter = XrpcRouter();
      _registerEndpoints();

      log('INFO', 'AT Proto PDS started: ${_didService!.did} (handle: $handle)');
    } catch (e) {
      log('ERROR', 'AT Proto: failed to start PDS: $e');
      await stopAtprotoPds();
    }
  }

  /// Stop the AT Protocol PDS.
  Future<void> stopAtprotoPds() async {
    _xrpcRouter = null;
    _jwtService = null;
    _didService = null;
    _atprotoRepo = null;
    _atprotoStorage?.close();
    _atprotoStorage = null;
    _adminPassword = null;
  }

  // -- Request handling --

  /// Handle an AT Proto related HTTP request.
  ///
  /// Returns true if the request was handled, false otherwise.
  /// Call this from handlePlatformRoute().
  Future<bool> handleAtprotoRequest(HttpRequest request, String path, String method) async {
    // XRPC endpoints
    if (path.startsWith('/xrpc/') && _xrpcRouter != null) {
      return await _xrpcRouter!.handle(request, path);
    }

    // DID document
    if (path == '/.well-known/did.json' && _didService != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(_didService!.buildDidDocument()));
      return true;
    }

    // Debug API
    if (path.startsWith('/api/atproto/')) {
      return _handleDebugApi(request, path, method);
    }

    return false;
  }

  // -- Debug API --

  bool _handleDebugApi(HttpRequest request, String path, String method) {
    if (path == '/api/atproto/status') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(getAtprotoStatus()));
      return true;
    }

    if (path == '/api/atproto/did') {
      if (_didService == null) {
        request.response.statusCode = 503;
        request.response.write('AT Proto not running');
        return true;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(_didService!.buildDidDocument()));
      return true;
    }

    if (path == '/api/atproto/admin-password' && method == 'GET') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'password': _adminPassword,
        'did': _didService?.did,
        'handle': _didService?.handle,
      }));
      return true;
    }

    // Debug: create a test record and read it back
    if (path == '/api/atproto/test-record' && method == 'POST') {
      return await _handleTestRecord(request);
    }

    return false;
  }

  Future<bool> _handleTestRecord(HttpRequest request) async {
    if (_atprotoRepo == null || _didService == null) {
      request.response.statusCode = 503;
      request.response.write('AT Proto not running');
      return true;
    }

    try {
      final body = await utf8.decodeStream(request);
      Map<String, dynamic>? record;
      String collection = 'radio.geogram.test';

      if (body.isNotEmpty) {
        final json = jsonDecode(body) as Map<String, dynamic>;
        record = json['record'] as Map<String, dynamic>?;
        collection = json['collection'] as String? ?? collection;
      }

      record ??= {
        '\$type': collection,
        'text': 'Test record created at ${DateTime.now().toIso8601String()}',
        'createdAt': DateTime.now().toIso8601String(),
      };

      // Create record
      final result = _atprotoRepo!.createRecord(collection, record);
      _atprotoRepo!.commit();

      // Read it back
      final parts = result.uri.split('/');
      final rkey = parts.last;
      final readBack = _atprotoRepo!.getRecord(collection, rkey);

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'created': {
          'uri': result.uri,
          'cid': result.cid.toBase32(),
        },
        'readBack': readBack != null ? {
          'uri': readBack.uri,
          'cid': readBack.cid.toBase32(),
          'value': readBack.value,
        } : null,
        'match': readBack != null && readBack.cid.toBase32() == result.cid.toBase32(),
      }));
      return true;
    } catch (e) {
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': '$e'}));
      return true;
    }
  }

  /// Get AT Proto PDS status for debug/monitoring.
  Map<String, dynamic> getAtprotoStatus() {
    if (!settings.atprotoEnabled) {
      return {
        'enabled': false,
        'running': false,
      };
    }

    return {
      'enabled': true,
      'running': isAtprotoRunning,
      'did': _didService?.did,
      'handle': _didService?.handle,
      'headCid': _atprotoRepo?.headCid?.toBase32(),
      'collections': _atprotoStorage?.listCollections() ?? [],
      'recordCount': _atprotoStorage?.listCollections()
          .fold<int>(0, (sum, c) => sum + (_atprotoStorage?.countRecords(c) ?? 0)) ?? 0,
    };
  }

  // -- Private helpers --

  void _registerEndpoints() {
    registerServerEndpoints(
      _xrpcRouter!,
      didService: _didService!,
      jwtService: _jwtService!,
      getAdminPassword: () => _adminPassword ?? '',
    );

    registerIdentityEndpoints(
      _xrpcRouter!,
      didService: _didService!,
    );

    registerRepoEndpoints(
      _xrpcRouter!,
      getRepo: () => _atprotoRepo!,
      didService: _didService!,
      jwtService: _jwtService!,
      getBlossom: () => blossom,
    );
  }

  /// Derive a secp256k1 signing key from the station's NOSTR nsec.
  ///
  /// Uses HMAC-SHA256(nsec, "atproto-signing-key") to derive a deterministic
  /// but separate key from the NOSTR identity.
  Uint8List _deriveSigningKey() {
    final nsec = settings.nsec;
    final hmac = Hmac(sha256, utf8.encode(nsec));
    final derived = hmac.convert(utf8.encode('atproto-signing-key'));
    return Uint8List.fromList(derived.bytes);
  }

  /// Generate a random admin password (persisted in memory only per session).
  String _generateAdminPassword() {
    final random = Random.secure();
    final bytes = List.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes).substring(0, 32);
  }

  /// Generate a JWT secret deterministically from nsec.
  String _generateJwtSecret() {
    final nsec = settings.nsec;
    final hmac = Hmac(sha256, utf8.encode(nsec));
    final derived = hmac.convert(utf8.encode('atproto-jwt-secret'));
    return derived.toString();
  }
}
