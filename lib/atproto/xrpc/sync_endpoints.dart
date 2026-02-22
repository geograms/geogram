/*
 * AT Protocol sync XRPC endpoints.
 *
 * Implements:
 * - com.atproto.sync.getRepo (GET) — full repo as CAR
 * - com.atproto.sync.getRecord (GET) — single record as CAR proof
 * - com.atproto.sync.listRepos (GET) — single-user, one entry
 * - com.atproto.sync.listBlobs (GET) — blob CIDs for a DID
 * - com.atproto.sync.getBlob (GET) — fetch blob bytes by CID
 * - com.atproto.sync.getLatestCommit (GET) — head CID + rev
 * - com.atproto.sync.requestCrawl (POST) — notify relay
 * - com.atproto.sync.subscribeRepos (GET/WebSocket) — firehose
 *
 * Reference: https://docs.bsky.app/docs/api/com-atproto-sync
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../atproto_storage.dart';
import '../car.dart';
import '../cid.dart';
import '../dag_cbor.dart';
import '../did_service.dart';
import '../firehose.dart';
import '../repo.dart';
import '../xrpc_router.dart';
import '../../services/nostr_blossom_service.dart';

/// Register sync XRPC endpoints on the router.
void registerSyncEndpoints(
  XrpcRouter router, {
  required AtprotoRepo Function() getRepo,
  required AtprotoStorage Function() getStorage,
  required DidService didService,
  required FirehoseManager Function() getFirehose,
  required NostrBlossomService? Function() getBlossom,
  required void Function(String level, String message) log,
}) {
  // GET com.atproto.sync.getRepo
  router.query('com.atproto.sync.getRepo', (request, params) async {
    final repoDid = params['did'];
    if (repoDid == null || repoDid.isEmpty) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'did parameter is required'));
      return;
    }

    if (repoDid != didService.did) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Repo not found'));
      return;
    }

    final repo = getRepo();
    try {
      final car = repo.exportCar();
      request.response.headers.contentType = ContentType('application', 'vnd.ipld.car');
      request.response.add(car);
    } catch (e) {
      XrpcRouter.writeError(request, XrpcError(500, 'InternalServerError',
          'Failed to export repo: $e'));
    }
  });

  // GET com.atproto.sync.getRecord
  router.query('com.atproto.sync.getRecord', (request, params) async {
    final repoDid = params['did'];
    final collection = params['collection'];
    final rkey = params['rkey'];

    if (repoDid == null || collection == null || rkey == null) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'did, collection, and rkey are required'));
      return;
    }

    if (repoDid != didService.did) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Repo not found'));
      return;
    }

    final repo = getRepo();
    final record = repo.getRecord(collection, rkey);
    if (record == null) {
      XrpcRouter.writeError(request, XrpcError(400, 'RecordNotFound',
          'Record not found'));
      return;
    }

    // Build a minimal CAR with just the record block and commit
    final storage = getStorage();
    final blocks = <Cid, Uint8List>{};

    // Add record block
    final recordBytes = storage.getBlock(record.cid);
    if (recordBytes != null) {
      blocks[record.cid] = recordBytes;
    }

    // Add commit block
    final headCid = repo.headCid;
    if (headCid != null) {
      final commitBytes = storage.getBlock(headCid);
      if (commitBytes != null) {
        blocks[headCid] = commitBytes;
      }
    }

    final car = CarWriter.write(headCid ?? record.cid, blocks);
    request.response.headers.contentType = ContentType('application', 'vnd.ipld.car');
    request.response.add(car);
  });

  // GET com.atproto.sync.listRepos
  router.query('com.atproto.sync.listRepos', (request, params) async {
    final repo = getRepo();
    final headCid = repo.headCid;

    XrpcRouter.writeJson(request, {
      'repos': [
        {
          'did': didService.did,
          'head': headCid?.toBase32() ?? '',
          'rev': '', // Would need to extract from commit
          'active': true,
        },
      ],
    });
  });

  // GET com.atproto.sync.listBlobs
  router.query('com.atproto.sync.listBlobs', (request, params) async {
    final repoDid = params['did'];
    if (repoDid == null || repoDid != didService.did) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Invalid or missing did'));
      return;
    }

    // AT Proto blobs are referenced by CID in records.
    // For now, return empty list — full blob tracking requires
    // scanning records for blob references.
    XrpcRouter.writeJson(request, {
      'cids': <String>[],
    });
  });

  // GET com.atproto.sync.getBlob
  router.query('com.atproto.sync.getBlob', (request, params) async {
    final repoDid = params['did'];
    final cidStr = params['cid'];

    if (repoDid == null || cidStr == null) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'did and cid are required'));
      return;
    }

    if (repoDid != didService.did) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Repo not found'));
      return;
    }

    // Try blossom storage (blobs are stored by SHA-256 hash)
    final blossom = getBlossom();
    if (blossom != null) {
      final file = blossom.getBlobFile(cidStr);
      if (file != null) {
        request.response.headers.contentType = ContentType('application', 'octet-stream');
        await request.response.addStream(file.openRead());
        return;
      }
    }

    XrpcRouter.writeError(request, XrpcError(400, 'BlobNotFound',
        'Blob not found'));
  });

  // GET com.atproto.sync.getLatestCommit
  router.query('com.atproto.sync.getLatestCommit', (request, params) async {
    final repoDid = params['did'];
    if (repoDid == null || repoDid != didService.did) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'Invalid or missing did'));
      return;
    }

    final repo = getRepo();
    final headCid = repo.headCid;
    if (headCid == null) {
      XrpcRouter.writeError(request, XrpcError(500, 'InternalServerError',
          'No commits yet'));
      return;
    }

    // Extract rev from commit block
    final storage = getStorage();
    final commitBytes = storage.getBlock(headCid);
    String rev = '';
    if (commitBytes != null) {
      try {
        final commit = DagCbor.decode(commitBytes);
        if (commit is Map) {
          rev = commit['rev'] as String? ?? '';
        }
      } catch (_) {}
    }

    XrpcRouter.writeJson(request, {
      'cid': headCid.toBase32(),
      'rev': rev,
    });
  });

  // POST com.atproto.sync.requestCrawl
  router.procedure('com.atproto.sync.requestCrawl', (request, params) async {
    final body = await XrpcRouter.readJsonBody(request);
    final hostname = body['hostname'] as String?;

    if (hostname == null || hostname.isEmpty) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'hostname is required'));
      return;
    }

    // In a full implementation, this would POST to the relay's requestCrawl endpoint.
    // For now, log the request and return success.
    log('INFO', 'AT Proto: requestCrawl received for relay: $hostname');

    request.response.statusCode = 200;
  });

  // GET com.atproto.sync.subscribeRepos (WebSocket)
  router.query('com.atproto.sync.subscribeRepos', (request, params) async {
    // This endpoint requires WebSocket upgrade
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'subscribeRepos requires WebSocket connection'));
      return;
    }

    final cursorStr = params['cursor'];
    final cursor = cursorStr != null ? int.tryParse(cursorStr) : null;

    try {
      final ws = await WebSocketTransformer.upgrade(request);
      final firehose = getFirehose();

      log('INFO', 'AT Proto: firehose subscriber connected (cursor: $cursor)');

      firehose.addSubscriber(ws, cursor: cursor);

      // Listen for client messages (ping/pong handled by WebSocket layer)
      ws.listen(
        (_) {}, // Ignore client messages
        onDone: () {
          firehose.removeSubscriber(ws);
          log('INFO', 'AT Proto: firehose subscriber disconnected');
        },
        onError: (e) {
          firehose.removeSubscriber(ws);
          log('WARN', 'AT Proto: firehose subscriber error: $e');
        },
      );
    } catch (e) {
      log('ERROR', 'AT Proto: firehose WebSocket upgrade failed: $e');
    }
  });
}
