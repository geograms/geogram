/*
 * AT Protocol repository XRPC endpoints.
 *
 * Implements:
 * - com.atproto.repo.createRecord (POST)
 * - com.atproto.repo.putRecord (POST)
 * - com.atproto.repo.deleteRecord (POST)
 * - com.atproto.repo.getRecord (GET)
 * - com.atproto.repo.listRecords (GET)
 * - com.atproto.repo.describeRepo (GET)
 * - com.atproto.repo.applyWrites (POST)
 * - com.atproto.repo.uploadBlob (POST)
 *
 * Reference: https://docs.bsky.app/docs/api/com-atproto-repo
 */

import 'dart:io';
import 'dart:typed_data';

import '../at_uri.dart';
import '../did_service.dart';
import '../jwt_service.dart';
import '../repo.dart';
import '../xrpc_router.dart';
import '../../services/nostr_blossom_service.dart';

/// Register repo XRPC endpoints on the router.
void registerRepoEndpoints(
  XrpcRouter router, {
  required AtprotoRepo Function() getRepo,
  required DidService didService,
  required JwtService jwtService,
  required NostrBlossomService? Function() getBlossom,
}) {
  /// Helper: verify access token and return DID, or write error and return null.
  Future<String?> requireAuth(HttpRequest request) async {
    final token = XrpcRouter.extractBearerToken(request);
    if (token == null) {
      XrpcRouter.writeError(request, XrpcError(401, 'AuthenticationRequired',
          'Bearer token required'));
      return null;
    }
    final did = jwtService.verifyAccessToken(token);
    if (did == null) {
      XrpcRouter.writeError(request, XrpcError(401, 'AuthenticationRequired',
          'Invalid or expired access token'));
      return null;
    }
    return did;
  }

  // GET com.atproto.repo.describeRepo
  router.query('com.atproto.repo.describeRepo', (request, params) async {
    final repo = params['repo'];
    if (repo == null || repo.isEmpty) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'repo parameter is required'));
      return;
    }

    // Single-user PDS: only describe our own repo
    if (repo != didService.did && repo != didService.handle) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Repo not found'));
      return;
    }

    final repoInstance = getRepo();
    XrpcRouter.writeJson(request, {
      'handle': didService.handle,
      'did': didService.did,
      'didDoc': didService.buildDidDocument(),
      'collections': repoInstance.listCollections(),
      'handleIsCorrect': true,
    });
  });

  // GET com.atproto.repo.getRecord
  router.query('com.atproto.repo.getRecord', (request, params) async {
    final repo = params['repo'];
    final collection = params['collection'];
    final rkey = params['rkey'];

    if (repo == null || collection == null || rkey == null) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'repo, collection, and rkey are required'));
      return;
    }

    // Single-user PDS check
    if (repo != didService.did && repo != didService.handle) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Repo not found'));
      return;
    }

    final record = getRepo().getRecord(collection, rkey);
    if (record == null) {
      XrpcRouter.writeError(request, XrpcError(400, 'RecordNotFound',
          'Record not found'));
      return;
    }

    XrpcRouter.writeJson(request, {
      'uri': record.uri,
      'cid': record.cid.toBase32(),
      'value': record.value,
    });
  });

  // GET com.atproto.repo.listRecords
  router.query('com.atproto.repo.listRecords', (request, params) async {
    final repo = params['repo'];
    final collection = params['collection'];

    if (repo == null || collection == null) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'repo and collection are required'));
      return;
    }

    if (repo != didService.did && repo != didService.handle) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Repo not found'));
      return;
    }

    final limit = int.tryParse(params['limit'] ?? '50') ?? 50;
    final cursor = params['cursor'];
    final reverse = params['reverse'] == 'true';

    final records = getRepo().listRecords(
      collection,
      limit: limit.clamp(1, 100),
      cursor: cursor,
      reverse: reverse,
    );

    final recordList = records.map((r) => {
      'uri': r.uri,
      'cid': r.cid.toBase32(),
      'value': r.value,
    }).toList();

    XrpcRouter.writeJson(request, {
      'records': recordList,
      if (records.length == limit && records.isNotEmpty)
        'cursor': records.last.rkey,
    });
  });

  // POST com.atproto.repo.createRecord
  router.procedure('com.atproto.repo.createRecord', (request, params) async {
    final did = await requireAuth(request);
    if (did == null) return;

    final body = await XrpcRouter.readJsonBody(request);
    final repo = body['repo'] as String?;
    final collection = body['collection'] as String?;
    final record = body['record'] as Map<String, dynamic>?;
    final rkey = body['rkey'] as String?;

    if (repo == null || collection == null || record == null) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'repo, collection, and record are required'));
      return;
    }

    if (repo != didService.did && repo != didService.handle) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Repo not found'));
      return;
    }

    final repoInstance = getRepo();
    final result = repoInstance.createRecord(collection, record, rkey: rkey);
    repoInstance.commit();

    XrpcRouter.writeJson(request, {
      'uri': result.uri,
      'cid': result.cid.toBase32(),
    });
  });

  // POST com.atproto.repo.putRecord
  router.procedure('com.atproto.repo.putRecord', (request, params) async {
    final did = await requireAuth(request);
    if (did == null) return;

    final body = await XrpcRouter.readJsonBody(request);
    final repo = body['repo'] as String?;
    final collection = body['collection'] as String?;
    final rkey = body['rkey'] as String?;
    final record = body['record'] as Map<String, dynamic>?;

    if (repo == null || collection == null || rkey == null || record == null) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'repo, collection, rkey, and record are required'));
      return;
    }

    if (repo != didService.did && repo != didService.handle) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Repo not found'));
      return;
    }

    final repoInstance = getRepo();
    final result = repoInstance.putRecord(collection, rkey, record);
    repoInstance.commit();

    XrpcRouter.writeJson(request, {
      'uri': result.uri,
      'cid': result.cid.toBase32(),
    });
  });

  // POST com.atproto.repo.deleteRecord
  router.procedure('com.atproto.repo.deleteRecord', (request, params) async {
    final did = await requireAuth(request);
    if (did == null) return;

    final body = await XrpcRouter.readJsonBody(request);
    final repo = body['repo'] as String?;
    final collection = body['collection'] as String?;
    final rkey = body['rkey'] as String?;

    if (repo == null || collection == null || rkey == null) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'repo, collection, and rkey are required'));
      return;
    }

    if (repo != didService.did && repo != didService.handle) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Repo not found'));
      return;
    }

    final repoInstance = getRepo();
    repoInstance.deleteRecord(collection, rkey);
    repoInstance.commit();

    request.response.statusCode = 200;
  });

  // POST com.atproto.repo.applyWrites
  router.procedure('com.atproto.repo.applyWrites', (request, params) async {
    final did = await requireAuth(request);
    if (did == null) return;

    final body = await XrpcRouter.readJsonBody(request);
    final repo = body['repo'] as String?;
    final writes = body['writes'] as List?;

    if (repo == null || writes == null) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'repo and writes are required'));
      return;
    }

    if (repo != didService.did && repo != didService.handle) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Repo not found'));
      return;
    }

    final repoInstance = getRepo();
    final results = <Map<String, dynamic>>[];

    for (final write in writes) {
      if (write is! Map<String, dynamic>) continue;

      final type = write['\$type'] as String?;
      final collection = write['collection'] as String?;
      final rkey = write['rkey'] as String?;
      final value = write['value'] as Map<String, dynamic>?;

      if (collection == null) continue;

      switch (type) {
        case 'com.atproto.repo.applyWrites#create':
          if (value == null) continue;
          final result = repoInstance.createRecord(collection, value, rkey: rkey);
          results.add({
            'uri': result.uri,
            'cid': result.cid.toBase32(),
          });
          break;

        case 'com.atproto.repo.applyWrites#update':
          if (rkey == null || value == null) continue;
          final result = repoInstance.putRecord(collection, rkey, value);
          results.add({
            'uri': result.uri,
            'cid': result.cid.toBase32(),
          });
          break;

        case 'com.atproto.repo.applyWrites#delete':
          if (rkey == null) continue;
          repoInstance.deleteRecord(collection, rkey);
          results.add({});
          break;
      }
    }

    repoInstance.commit();

    XrpcRouter.writeJson(request, {
      'results': results,
    });
  });

  // POST com.atproto.repo.uploadBlob
  router.procedure('com.atproto.repo.uploadBlob', (request, params) async {
    final did = await requireAuth(request);
    if (did == null) return;

    final blossom = getBlossom();
    if (blossom == null) {
      XrpcRouter.writeError(request, XrpcError(500, 'InternalServerError',
          'Blob storage not available'));
      return;
    }

    // Read raw bytes from request body
    final chunks = <List<int>>[];
    await for (final chunk in request) {
      chunks.add(chunk);
    }
    final bytes = Uint8List.fromList(chunks.expand((c) => c).toList());

    if (bytes.isEmpty) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Empty blob'));
      return;
    }

    final mimeType = request.headers.contentType?.mimeType ?? 'application/octet-stream';

    try {
      final result = await blossom.ingestBytes(
        bytes: bytes,
        mime: mimeType,
        ownerPubkey: did,
      );

      XrpcRouter.writeJson(request, {
        'blob': {
          '\$type': 'blob',
          'ref': {'\$link': result.hash},
          'mimeType': result.mime ?? mimeType,
          'size': result.size,
        },
      });
    } catch (e) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Failed to store blob: $e'));
    }
  });
}
