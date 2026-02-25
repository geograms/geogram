/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart' as shelf;

import '../../atproto/atproto_storage.dart';
import '../../atproto/did_service.dart';
import '../../atproto/jwt_service.dart';
import '../../atproto/repo.dart';
import '../../atproto/signing.dart';
import '../../models/station.dart';
import '../../services/app_service.dart';
import '../../services/log_service.dart';
import '../../services/profile_service.dart';
import '../../services/profile_storage.dart';
import '../../services/station_service.dart';
import 'models/atproto_bridge_config.dart';

class AtprotoLocalPdsService {
  static final AtprotoLocalPdsService _instance =
      AtprotoLocalPdsService._internal();
  factory AtprotoLocalPdsService() => _instance;
  AtprotoLocalPdsService._internal();

  ProfileStorage? _profileStorage;

  AtprotoStorage? _repoStorage;
  AtprotoRepo? _repo;
  JwtService? _jwt;
  DidService? _did;

  String _identifier = '';
  String _adminPassword = '';
  String? _dbPath;
  Directory? _tempDir;
  bool _started = false;

  bool get isRunning =>
      _started && _repo != null && _jwt != null && _did != null;

  Future<void> start({
    required ProfileStorage storage,
    required AtprotoBridgeConfig config,
  }) async {
    _profileStorage = storage;
    _identifier = _deriveIdentifier();
    _adminPassword = config.password.trim();
    if (_adminPassword.isEmpty) return;

    if (_started &&
        _adminPassword == config.password.trim() &&
        _identifier == _deriveIdentifier()) {
      return;
    }
    if (_started) {
      await stop();
    }

    try {
      _dbPath = await _prepareDbPath(storage);
      if (_dbPath == null) return;

      _repoStorage = AtprotoStorage.open(_dbPath!);

      final signingKey = _deriveSigningKey();
      final bridgeHost = _resolveBridgeHost();
      final handle = '${_normalizeHandle(_identifier)}.$bridgeHost';

      _did = DidService(
        domain: bridgeHost,
        publicKey: AtprotoSigning.derivePublicKey(signingKey),
        handle: handle,
      );
      _jwt = JwtService(
        secret: _generateJwtSecret(),
        did: _did!.did,
        handle: _did!.handle,
      );

      _repo = AtprotoRepo.open(did: _did!.did, storage: _repoStorage!);
      if (_repo == null) {
        _repo = AtprotoRepo.create(
          did: _did!.did,
          storage: _repoStorage!,
          signingKey: signingKey,
        );
        _repo!.commit();
        await _flushEncryptedDb();
      }

      _started = true;
      LogService().log('AT Proto local PDS started: did=${_did!.did}');
    } catch (e) {
      LogService().log('AT Proto local PDS start failed: $e');
      await stop();
    }
  }

  Future<void> stop() async {
    _repo = null;
    _jwt = null;
    _did = null;
    _started = false;

    _repoStorage?.close();
    _repoStorage = null;

    if (_tempDir != null) {
      try {
        await _tempDir!.delete(recursive: true);
      } catch (_) {}
    }
    _tempDir = null;
    _dbPath = null;
  }

  Future<shelf.Response?> handleRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> baseHeaders,
  ) async {
    if (!urlPath.startsWith('xrpc/') &&
        !urlPath.startsWith('api/atproto/') &&
        urlPath != 'did.json' &&
        urlPath != '.well-known/did.json') {
      return null;
    }

    if (!isRunning) {
      return shelf.Response(
        503,
        body: jsonEncode({'error': 'AT Proto PDS not ready'}),
        headers: baseHeaders,
      );
    }

    if (urlPath == 'did.json' || urlPath == '.well-known/did.json') {
      return _jsonResponse(200, _did!.buildDidDocument(), baseHeaders);
    }

    if (urlPath == 'api/atproto/status') {
      return _jsonResponse(200, _status(), baseHeaders);
    }

    if (urlPath == 'api/atproto/admin-password' && request.method == 'GET') {
      return _jsonResponse(200, {
        'password': _adminPassword,
        'identifier': _identifier,
        'did': _did!.did,
        'handle': _did!.handle,
      }, baseHeaders);
    }

    if (!urlPath.startsWith('xrpc/')) {
      return _jsonResponse(404, {'error': 'Not found'}, baseHeaders);
    }

    final nsid = urlPath.substring('xrpc/'.length);
    if (nsid == 'com.atproto.server.describeServer' &&
        request.method == 'GET') {
      return _jsonResponse(200, {
        'did': _did!.did,
        'availableUserDomains': <String>[],
        'inviteCodeRequired': false,
        'links': <String, dynamic>{},
      }, baseHeaders);
    }

    if (nsid == 'com.atproto.server.createSession' &&
        request.method == 'POST') {
      final body = await _readJsonBody(request);
      final identifier = body['identifier']?.toString().trim() ?? '';
      final password = body['password']?.toString() ?? '';
      if (identifier.isEmpty || password.isEmpty) {
        return _xrpcError(
          400,
          'InvalidRequest',
          'identifier and password are required',
          baseHeaders,
        );
      }
      if (!_isAcceptedIdentifier(identifier)) {
        return _xrpcError(
          401,
          'AuthenticationRequired',
          'Invalid identifier',
          baseHeaders,
        );
      }
      if (password != _adminPassword) {
        return _xrpcError(
          401,
          'AuthenticationRequired',
          'Invalid password',
          baseHeaders,
        );
      }
      return _jsonResponse(200, _jwt!.createSession().toJson(), baseHeaders);
    }

    if (nsid == 'com.atproto.server.refreshSession' &&
        request.method == 'POST') {
      final token = _extractBearer(request);
      if (token == null) {
        return _xrpcError(
          401,
          'AuthenticationRequired',
          'Missing refresh token',
          baseHeaders,
        );
      }
      final refreshed = _jwt!.refreshSession(token);
      if (refreshed == null) {
        return _xrpcError(
          401,
          'AuthenticationRequired',
          'Invalid or expired refresh token',
          baseHeaders,
        );
      }
      return _jsonResponse(200, refreshed.toJson(), baseHeaders);
    }

    if (nsid == 'com.atproto.server.getSession' && request.method == 'GET') {
      final token = _extractBearer(request);
      if (token == null) {
        return _xrpcError(
          401,
          'AuthenticationRequired',
          'Missing access token',
          baseHeaders,
        );
      }
      final did = _jwt!.verifyAccessToken(token);
      if (did == null) {
        return _xrpcError(
          401,
          'AuthenticationRequired',
          'Invalid or expired access token',
          baseHeaders,
        );
      }
      return _jsonResponse(200, {
        'did': did,
        'handle': _did!.handle,
      }, baseHeaders);
    }

    if (nsid == 'com.atproto.identity.resolveHandle' &&
        request.method == 'GET') {
      final handle = request.url.queryParameters['handle']?.trim() ?? '';
      if (handle.isEmpty) {
        return _xrpcError(
          400,
          'InvalidRequest',
          'handle parameter is required',
          baseHeaders,
        );
      }
      if (handle == _did!.handle || handle == _identifier) {
        return _jsonResponse(200, {'did': _did!.did}, baseHeaders);
      }
      return _xrpcError(
        400,
        'InvalidRequest',
        'Unable to resolve handle',
        baseHeaders,
      );
    }

    if (nsid == 'com.atproto.repo.describeRepo' && request.method == 'GET') {
      final repoRef = request.url.queryParameters['repo']?.trim() ?? '';
      if (repoRef.isEmpty) {
        return _xrpcError(
          400,
          'InvalidRequest',
          'repo parameter is required',
          baseHeaders,
        );
      }
      if (!_isAcceptedRepo(repoRef)) {
        return _xrpcError(400, 'InvalidRequest', 'Repo not found', baseHeaders);
      }
      return _jsonResponse(200, {
        'handle': _did!.handle,
        'did': _did!.did,
        'didDoc': _did!.buildDidDocument(),
        'collections': _repo!.listCollections(),
        'handleIsCorrect': true,
      }, baseHeaders);
    }

    if (nsid == 'com.atproto.repo.listRecords' && request.method == 'GET') {
      final repoRef = request.url.queryParameters['repo']?.trim() ?? '';
      final collection =
          request.url.queryParameters['collection']?.trim() ?? '';
      if (repoRef.isEmpty || collection.isEmpty) {
        return _xrpcError(
          400,
          'InvalidRequest',
          'repo and collection are required',
          baseHeaders,
        );
      }
      if (!_isAcceptedRepo(repoRef)) {
        return _xrpcError(400, 'InvalidRequest', 'Repo not found', baseHeaders);
      }
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '50') ?? 50;
      final cursor = request.url.queryParameters['cursor'];
      final reverse = request.url.queryParameters['reverse'] == 'true';
      final records = _repo!.listRecords(
        collection,
        limit: limit.clamp(1, 100),
        cursor: cursor,
        reverse: reverse,
      );
      return _jsonResponse(200, {
        'records': records
            .map(
              (r) => {'uri': r.uri, 'cid': r.cid.toBase32(), 'value': r.value},
            )
            .toList(),
      }, baseHeaders);
    }

    if (nsid == 'com.atproto.repo.createRecord' && request.method == 'POST') {
      final did = _requireAccessDid(request);
      if (did == null) {
        return _xrpcError(
          401,
          'AuthenticationRequired',
          'Invalid or missing access token',
          baseHeaders,
        );
      }
      final body = await _readJsonBody(request);
      final repoRef = body['repo']?.toString().trim() ?? '';
      final collection = body['collection']?.toString().trim() ?? '';
      final rkey = body['rkey']?.toString();
      final record = body['record'];
      if (repoRef.isEmpty ||
          collection.isEmpty ||
          record is! Map<String, dynamic>) {
        return _xrpcError(
          400,
          'InvalidRequest',
          'repo, collection, and record are required',
          baseHeaders,
        );
      }
      if (!_isAcceptedRepo(repoRef) || did != _did!.did) {
        return _xrpcError(400, 'InvalidRequest', 'Repo not found', baseHeaders);
      }
      final result = _repo!.createRecord(collection, record, rkey: rkey);
      _repo!.commit();
      await _flushEncryptedDb();
      return _jsonResponse(200, {
        'uri': result.uri,
        'cid': result.cid.toBase32(),
      }, baseHeaders);
    }

    return _xrpcError(
      404,
      'MethodNotImplemented',
      'Unsupported AT Proto endpoint',
      baseHeaders,
    );
  }

  Map<String, dynamic> _status() {
    return {
      'running': isRunning,
      'did': _did?.did,
      'handle': _did?.handle,
      'identifier': _identifier,
      'repoPath': _dbPath,
      'collections': _repo?.listCollections() ?? <String>[],
      'storageEncrypted': _profileStorage?.isEncrypted ?? false,
    };
  }

  Future<Map<String, dynamic>> _readJsonBody(shelf.Request request) async {
    try {
      final text = await request.readAsString();
      if (text.trim().isEmpty) return {};
      final parsed = jsonDecode(text);
      if (parsed is Map<String, dynamic>) return parsed;
      return {};
    } catch (_) {
      return {};
    }
  }

  String? _extractBearer(shelf.Request request) {
    final auth = request.headers['authorization'];
    if (auth == null) return null;
    if (!auth.toLowerCase().startsWith('bearer ')) return null;
    return auth.substring(7).trim();
  }

  String? _requireAccessDid(shelf.Request request) {
    final token = _extractBearer(request);
    if (token == null) return null;
    return _jwt?.verifyAccessToken(token);
  }

  bool _isAcceptedRepo(String value) {
    return value == _did!.did || value == _did!.handle || value == _identifier;
  }

  bool _isAcceptedIdentifier(String value) {
    return value == _identifier || value == _did!.handle || value == _did!.did;
  }

  shelf.Response _jsonResponse(
    int status,
    Map<String, dynamic> payload,
    Map<String, String> baseHeaders,
  ) {
    return shelf.Response(
      status,
      body: jsonEncode(payload),
      headers: baseHeaders,
    );
  }

  shelf.Response _xrpcError(
    int status,
    String error,
    String message,
    Map<String, String> baseHeaders,
  ) {
    return shelf.Response(
      status,
      body: jsonEncode({'error': error, 'message': message}),
      headers: baseHeaders,
    );
  }

  String _deriveIdentifier() {
    try {
      final profile = ProfileService().getProfile();
      final nick = profile.nickname.trim();
      if (nick.isNotEmpty) return nick;
      final callsign = profile.callsign.trim();
      if (callsign.isNotEmpty) return callsign;
    } catch (_) {}

    final callsign = AppService().currentCallsign;
    if (callsign != null && callsign.trim().isNotEmpty) {
      return callsign.trim();
    }
    return 'geogram-user';
  }

  String _normalizeHandle(String value) {
    final normalized = value.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9._-]'),
      '-',
    );
    return normalized.isEmpty ? 'geogram-user' : normalized;
  }

  String _resolveBridgeHost() {
    try {
      final stationService = StationService();
      if (stationService.isInitialized) {
        final Station? preferred = stationService.getPreferredStation();
        if (preferred != null) {
          final uri = Uri.tryParse(preferred.url);
          final host = uri?.host ?? preferred.url;
          final normalized = host.trim().toLowerCase();
          if (normalized.isNotEmpty) return normalized;
        }
      }
    } catch (_) {}
    return 'localhost';
  }

  Uint8List _deriveSigningKey() {
    String nsec = '';
    try {
      nsec = ProfileService().getProfile().nsec;
    } catch (_) {}
    if (nsec.isEmpty) {
      nsec = _identifier;
    }
    final hmac = Hmac(sha256, utf8.encode(nsec));
    final derived = hmac.convert(utf8.encode('atproto-signing-key'));
    return Uint8List.fromList(derived.bytes);
  }

  String _generateJwtSecret() {
    String nsec = '';
    try {
      nsec = ProfileService().getProfile().nsec;
    } catch (_) {}
    if (nsec.isEmpty) nsec = _identifier;
    final hmac = Hmac(sha256, utf8.encode(nsec));
    final derived = hmac.convert(utf8.encode('atproto-jwt-secret'));
    return derived.toString();
  }

  Future<String?> _prepareDbPath(ProfileStorage storage) async {
    const relPath = 'teleport/atproto/repo/repo.db';
    const legacyRelPath = 'atproto/repo/repo.db';
    await storage.createDirectory('teleport');
    await storage.createDirectory('teleport/atproto');
    await storage.createDirectory('teleport/atproto/repo');

    if (!storage.isEncrypted) {
      final currentPath = storage.getAbsolutePath(relPath);
      final legacyPath = storage.getAbsolutePath(legacyRelPath);
      try {
        final currentFile = File(currentPath);
        final legacyFile = File(legacyPath);
        if (!await currentFile.exists() && await legacyFile.exists()) {
          await legacyFile.copy(currentPath);
        }
      } catch (_) {}
      return currentPath;
    }

    _tempDir = await Directory.systemTemp.createTemp('geogram-atproto-');
    final file = File('${_tempDir!.path}/repo.db');
    var bytes = await storage.readBytes(relPath);
    bytes ??= await storage.readBytes(legacyRelPath);
    if (bytes != null && bytes.isNotEmpty) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return file.path;
  }

  Future<void> _flushEncryptedDb() async {
    if (_profileStorage == null ||
        !_profileStorage!.isEncrypted ||
        _dbPath == null) {
      return;
    }
    try {
      final bytes = await File(_dbPath!).readAsBytes();
      await _profileStorage!.writeBytes(
        'teleport/atproto/repo/repo.db',
        Uint8List.fromList(bytes),
      );
    } catch (e) {
      LogService().log('AT Proto encrypted DB checkpoint failed: $e');
    }
  }
}
