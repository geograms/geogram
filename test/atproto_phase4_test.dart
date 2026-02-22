/*
 * Phase 4 tests for AT Protocol sync and firehose.
 *
 * Tests: FirehoseManager encoding/decoding, sequence tracking, CAR export,
 *        getLatestCommit data, event replay.
 * Run: flutter test test/atproto_phase4_test.dart
 */

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:geogram/atproto/at_uri.dart';
import 'package:geogram/atproto/atproto_storage.dart';
import 'package:geogram/atproto/car.dart';
import 'package:geogram/atproto/cid.dart';
import 'package:geogram/atproto/dag_cbor.dart';
import 'package:geogram/atproto/firehose.dart';
import 'package:geogram/atproto/repo.dart';
import 'package:geogram/atproto/signing.dart';

void main() {
  group('Firehose frame encoding', () {
    test('encode and decode commit frame', () {
      final cid = Cid.fromContent(DagCbor.encode({'test': true}));
      final frame = FirehoseManager.encodeCommitFrame(
        did: 'did:web:test.com',
        commitCid: cid,
        rev: '3kqfbu2hs4a7o',
        ops: [
          FirehoseRecordOp(
            action: FirehoseOp.create,
            path: 'radio.geogram.blog.post/abc123',
            cid: cid,
          ),
        ],
      );

      expect(frame, isNotEmpty);

      final decoded = FirehoseManager.decodeFrame(frame);
      expect(decoded, isNotNull);
      expect(decoded!.header['op'], equals(1));
      expect(decoded.header['t'], equals('#commit'));
      expect(decoded.body['repo'], equals('did:web:test.com'));
      expect(decoded.body['rev'], equals('3kqfbu2hs4a7o'));

      final ops = decoded.body['ops'] as List;
      expect(ops.length, equals(1));
      final op = ops[0] as Map<String, dynamic>;
      expect(op['action'], equals('create'));
      expect(op['path'], equals('radio.geogram.blog.post/abc123'));
    });

    test('encode and decode identity frame', () {
      final frame = FirehoseManager.encodeIdentityFrame(
        did: 'did:web:test.com',
        handle: 'user.test.com',
      );

      final decoded = FirehoseManager.decodeFrame(frame);
      expect(decoded, isNotNull);
      expect(decoded!.header['t'], equals('#identity'));
      expect(decoded.body['did'], equals('did:web:test.com'));
      expect(decoded.body['handle'], equals('user.test.com'));
    });

    test('encode and decode info frame', () {
      final frame = FirehoseManager.encodeInfoFrame(
        name: 'OutdatedCursor',
        message: 'Cursor too old',
      );

      final decoded = FirehoseManager.decodeFrame(frame);
      expect(decoded, isNotNull);
      expect(decoded!.header['t'], equals('#info'));
      expect(decoded.body['name'], equals('OutdatedCursor'));
      expect(decoded.body['message'], equals('Cursor too old'));
    });

    test('commit frame with prev CID', () {
      final cid1 = Cid.fromContent(DagCbor.encode({'a': 1}));
      final cid2 = Cid.fromContent(DagCbor.encode({'b': 2}));

      final frame = FirehoseManager.encodeCommitFrame(
        did: 'did:web:test.com',
        commitCid: cid2,
        rev: '3kqfbu2hs4a7o',
        ops: [],
        prev: cid1,
      );

      final decoded = FirehoseManager.decodeFrame(frame);
      expect(decoded!.body['prev'], isA<CidLink>());
    });

    test('commit frame with multiple ops', () {
      final cid1 = Cid.fromContent(DagCbor.encode({'x': 1}));
      final cid2 = Cid.fromContent(DagCbor.encode({'y': 2}));

      final frame = FirehoseManager.encodeCommitFrame(
        did: 'did:web:test.com',
        commitCid: cid1,
        rev: 'rev1',
        ops: [
          FirehoseRecordOp(action: FirehoseOp.create, path: 'col/a', cid: cid1),
          FirehoseRecordOp(action: FirehoseOp.update, path: 'col/b', cid: cid2),
          FirehoseRecordOp(action: FirehoseOp.delete, path: 'col/c'),
        ],
      );

      final decoded = FirehoseManager.decodeFrame(frame);
      final ops = decoded!.body['ops'] as List;
      expect(ops.length, equals(3));
      expect((ops[0] as Map)['action'], equals('create'));
      expect((ops[1] as Map)['action'], equals('update'));
      expect((ops[2] as Map)['action'], equals('delete'));
    });

    test('decodeFrame returns null for invalid data', () {
      expect(FirehoseManager.decodeFrame(Uint8List(0)), isNull);
      expect(FirehoseManager.decodeFrame(Uint8List.fromList([0, 1, 2])), isNull);
    });
  });

  group('FirehoseManager with storage', () {
    late AtprotoStorage storage;
    late FirehoseManager firehose;

    setUp(() {
      storage = AtprotoStorage.openInMemory();
      firehose = FirehoseManager(
        storage: storage,
        did: 'did:web:test.com',
      );
    });

    tearDown(() {
      storage.close();
    });

    test('emitCommit stores event and returns seq', () {
      final cid = Cid.fromContent(DagCbor.encode({'test': true}));
      final seq = firehose.emitCommit(
        commitCid: cid,
        rev: 'rev1',
        ops: [
          FirehoseRecordOp(action: FirehoseOp.create, path: 'col/key1', cid: cid),
        ],
      );

      expect(seq, greaterThan(0));
      expect(firehose.latestSeq, equals(seq));
    });

    test('emitCommit assigns increasing sequence numbers', () {
      final cid = Cid.fromContent(DagCbor.encode({'a': 1}));

      final seq1 = firehose.emitCommit(
        commitCid: cid, rev: 'rev1',
        ops: [FirehoseRecordOp(action: FirehoseOp.create, path: 'col/a', cid: cid)],
      );
      final seq2 = firehose.emitCommit(
        commitCid: cid, rev: 'rev2',
        ops: [FirehoseRecordOp(action: FirehoseOp.create, path: 'col/b', cid: cid)],
      );
      final seq3 = firehose.emitCommit(
        commitCid: cid, rev: 'rev3',
        ops: [FirehoseRecordOp(action: FirehoseOp.create, path: 'col/c', cid: cid)],
      );

      expect(seq2, greaterThan(seq1));
      expect(seq3, greaterThan(seq2));
    });

    test('emitInfo stores info event', () {
      final seq = firehose.emitInfo('ServerStart', 'PDS started');
      expect(seq, greaterThan(0));

      final events = firehose.getEventsSince(0);
      expect(events.length, equals(1));

      final decoded = FirehoseManager.decodeFrame(events.first.event);
      expect(decoded!.header['t'], equals('#info'));
      expect(decoded.body['name'], equals('ServerStart'));
    });

    test('getEventsSince replays events after cursor', () {
      final cid = Cid.fromContent(DagCbor.encode({'x': 1}));

      final seq1 = firehose.emitCommit(
        commitCid: cid, rev: 'r1',
        ops: [FirehoseRecordOp(action: FirehoseOp.create, path: 'col/1', cid: cid)],
      );
      final seq2 = firehose.emitCommit(
        commitCid: cid, rev: 'r2',
        ops: [FirehoseRecordOp(action: FirehoseOp.create, path: 'col/2', cid: cid)],
      );
      final seq3 = firehose.emitCommit(
        commitCid: cid, rev: 'r3',
        ops: [FirehoseRecordOp(action: FirehoseOp.create, path: 'col/3', cid: cid)],
      );

      // Get events since seq1 (should return seq2 and seq3)
      final events = firehose.getEventsSince(seq1);
      expect(events.length, equals(2));
      expect(events[0].seq, equals(seq2));
      expect(events[1].seq, equals(seq3));
    });

    test('getEventsSince with limit', () {
      final cid = Cid.fromContent(DagCbor.encode({'y': 1}));

      for (var i = 0; i < 5; i++) {
        firehose.emitCommit(
          commitCid: cid, rev: 'r$i',
          ops: [FirehoseRecordOp(action: FirehoseOp.create, path: 'col/$i', cid: cid)],
        );
      }

      final events = firehose.getEventsSince(0, limit: 2);
      expect(events.length, equals(2));
    });

    test('latestSeq is null when no events', () {
      expect(firehose.latestSeq, isNull);
    });

    test('subscriberCount starts at zero', () {
      expect(firehose.subscriberCount, equals(0));
    });
  });

  group('Repo CAR export for sync', () {
    late AtprotoStorage storage;
    late AtprotoRepo repo;
    final did = 'did:web:test.geogram.radio';

    setUp(() {
      storage = AtprotoStorage.openInMemory();
      final kp = AtprotoSigning.generateKeyPair();
      repo = AtprotoRepo.create(
        did: did,
        storage: storage,
        signingKey: kp.privateKey,
      );
    });

    tearDown(() {
      storage.close();
    });

    test('exportCar produces valid CAR with root', () {
      repo.createRecord('radio.geogram.blog.post', {'text': 'hello'});
      repo.commit();

      final carBytes = repo.exportCar();
      final car = CarReader.read(carBytes);

      // Should have one root (the commit CID)
      expect(car.roots.length, equals(1));
      expect(car.roots[0].toBase32(), equals(repo.headCid!.toBase32()));

      // Should have multiple blocks (commit + MST nodes + record)
      expect(car.blocks.length, greaterThanOrEqualTo(2));
    });

    test('exportCar includes all record blocks', () {
      for (var i = 0; i < 5; i++) {
        repo.createRecord('radio.geogram.blog.post', {'text': 'post $i', 'index': i});
      }
      repo.commit();

      final carBytes = repo.exportCar();
      final car = CarReader.read(carBytes);

      // Commit block should be present
      expect(car.blocks.containsKey(repo.headCid!), isTrue);

      // Blocks count: 1 commit + MST nodes + 5 records
      expect(car.blocks.length, greaterThanOrEqualTo(7));
    });

    test('exported CAR commit block is valid', () {
      repo.createRecord('radio.geogram.blog.post', {'text': 'test'});
      final commitCid = repo.commit();

      final carBytes = repo.exportCar();
      final car = CarReader.read(carBytes);

      // Decode the commit block
      final commitBytes = car.blocks[commitCid];
      expect(commitBytes, isNotNull);

      final commit = DagCbor.decode(commitBytes!);
      expect(commit, isA<Map>());
      expect((commit as Map)['did'], equals(did));
      expect(commit['version'], equals(3));
      expect(commit['rev'], isNotNull);
      expect(commit['data'], isA<CidLink>()); // MST root
      expect(commit['sig'], isA<Uint8List>()); // Signature
    });
  });

  group('getLatestCommit data', () {
    late AtprotoStorage storage;
    late AtprotoRepo repo;
    final did = 'did:web:test.geogram.radio';

    setUp(() {
      storage = AtprotoStorage.openInMemory();
      final kp = AtprotoSigning.generateKeyPair();
      repo = AtprotoRepo.create(
        did: did,
        storage: storage,
        signingKey: kp.privateKey,
      );
    });

    tearDown(() {
      storage.close();
    });

    test('head CID and rev from commit', () {
      repo.createRecord('radio.geogram.blog.post', {'text': 'test'});
      final commitCid = repo.commit();

      expect(repo.headCid, isNotNull);
      expect(repo.headCid!.toBase32(), equals(commitCid.toBase32()));

      // Extract rev from commit block
      final commitBytes = storage.getBlock(commitCid);
      expect(commitBytes, isNotNull);
      final commit = DagCbor.decode(commitBytes!) as Map;
      expect(commit['rev'], isA<String>());
      expect((commit['rev'] as String).length, equals(13)); // TID length
    });

    test('multiple commits update head', () {
      repo.createRecord('radio.geogram.blog.post', {'text': 'first'});
      final cid1 = repo.commit();

      repo.createRecord('radio.geogram.blog.post', {'text': 'second'});
      final cid2 = repo.commit();

      expect(cid2.toBase32(), isNot(equals(cid1.toBase32())));
      expect(repo.headCid!.toBase32(), equals(cid2.toBase32()));

      // Second commit should reference first as prev
      final commitBytes = storage.getBlock(cid2);
      final commit = DagCbor.decode(commitBytes!) as Map;
      expect(commit['prev'], isA<CidLink>());
      expect((commit['prev'] as CidLink).cid.toBase32(), equals(cid1.toBase32()));
    });
  });

  group('Integration: firehose with repo', () {
    late AtprotoStorage storage;
    late AtprotoRepo repo;
    late FirehoseManager firehose;
    final did = 'did:web:test.geogram.radio';

    setUp(() {
      storage = AtprotoStorage.openInMemory();
      final kp = AtprotoSigning.generateKeyPair();
      repo = AtprotoRepo.create(
        did: did,
        storage: storage,
        signingKey: kp.privateKey,
      );
      repo.commit();
      firehose = FirehoseManager(storage: storage, did: did);
    });

    tearDown(() {
      storage.close();
    });

    test('full create-commit-emit lifecycle', () {
      // Create record
      final result = repo.createRecord(
        'radio.geogram.blog.post',
        {'text': 'firehose test'},
      );
      final prevHead = repo.headCid;
      final commitCid = repo.commit();

      // Emit firehose event
      final rkey = AtUri.parse(result.uri).rkey!;
      final seq = firehose.emitCommit(
        commitCid: commitCid,
        rev: 'test-rev',
        ops: [
          FirehoseRecordOp(
            action: FirehoseOp.create,
            path: 'radio.geogram.blog.post/$rkey',
            cid: result.cid,
          ),
        ],
        prev: prevHead,
      );

      expect(seq, greaterThan(0));

      // Verify event is stored and decodable
      final events = firehose.getEventsSince(0);
      expect(events.length, equals(1));

      final decoded = FirehoseManager.decodeFrame(events.first.event);
      expect(decoded!.header['t'], equals('#commit'));
      expect(decoded.body['repo'], equals(did));

      final ops = decoded.body['ops'] as List;
      expect(ops.length, equals(1));
      expect((ops[0] as Map)['path'], contains(rkey));
    });

    test('multiple operations tracked by cursor', () {
      // Create 3 records with events
      final seqs = <int>[];
      for (var i = 0; i < 3; i++) {
        final result = repo.createRecord(
          'radio.geogram.blog.post',
          {'text': 'post $i'},
        );
        final prevHead = repo.headCid;
        final commitCid = repo.commit();
        final rkey = AtUri.parse(result.uri).rkey!;

        seqs.add(firehose.emitCommit(
          commitCid: commitCid,
          rev: 'rev$i',
          ops: [FirehoseRecordOp(action: FirehoseOp.create, path: 'col/$rkey', cid: result.cid)],
          prev: prevHead,
        ));
      }

      // Client reconnects with cursor at seq[0] — should get events [1] and [2]
      final missed = firehose.getEventsSince(seqs[0]);
      expect(missed.length, equals(2));
      expect(missed[0].seq, equals(seqs[1]));
      expect(missed[1].seq, equals(seqs[2]));

      // Client reconnects with cursor at seq[1] — should get event [2]
      final missed2 = firehose.getEventsSince(seqs[1]);
      expect(missed2.length, equals(1));
      expect(missed2[0].seq, equals(seqs[2]));

      // Client reconnects with latest — nothing missed
      final missed3 = firehose.getEventsSince(seqs[2]);
      expect(missed3, isEmpty);
    });
  });
}
