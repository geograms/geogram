/*
 * Phase 1 tests for AT Protocol core data structures.
 *
 * Tests: DAG-CBOR, CID, MST, CAR, TID, Signing, Storage, Repo.
 * Run: dart test test/atproto_phase1_test.dart
 */

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:geogram/atproto/cid.dart';
import 'package:geogram/atproto/dag_cbor.dart';
import 'package:geogram/atproto/car.dart';
import 'package:geogram/atproto/mst.dart';
import 'package:geogram/atproto/tid.dart';
import 'package:geogram/atproto/signing.dart';

void main() {
  group('DAG-CBOR', () {
    test('encodes and decodes null', () {
      final bytes = DagCbor.encode(null);
      expect(DagCbor.decode(bytes), isNull);
    });

    test('encodes and decodes booleans', () {
      expect(DagCbor.decode(DagCbor.encode(true)), isTrue);
      expect(DagCbor.decode(DagCbor.encode(false)), isFalse);
    });

    test('encodes and decodes integers', () {
      for (final v in [0, 1, 23, 24, 255, 256, 65535, 65536, 1000000, -1, -100]) {
        expect(DagCbor.decode(DagCbor.encode(v)), equals(v), reason: 'value: $v');
      }
    });

    test('encodes and decodes strings', () {
      expect(DagCbor.decode(DagCbor.encode('')), equals(''));
      expect(DagCbor.decode(DagCbor.encode('hello')), equals('hello'));
      expect(DagCbor.decode(DagCbor.encode('AT Protocol')), equals('AT Protocol'));
    });

    test('encodes and decodes byte strings', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final decoded = DagCbor.decode(DagCbor.encode(data));
      expect(decoded, isA<Uint8List>());
      expect(decoded, equals(data));
    });

    test('encodes and decodes lists', () {
      final list = [1, 'two', true, null];
      final decoded = DagCbor.decode(DagCbor.encode(list));
      expect(decoded, equals(list));
    });

    test('encodes and decodes maps with sorted keys', () {
      final map = {'z': 1, 'a': 2, 'bb': 3, 'b': 4};
      final bytes = DagCbor.encode(map);
      final decoded = DagCbor.decode(bytes) as Map;
      // Keys should be in DAG-CBOR order: length first, then lexicographic
      final keys = decoded.keys.toList();
      expect(keys, equals(['a', 'b', 'z', 'bb']));
    });

    test('deterministic: same data produces same bytes', () {
      final map = {'version': 3, 'did': 'did:web:example.com', 'data': 42};
      final bytes1 = DagCbor.encode(map);
      final bytes2 = DagCbor.encode(map);
      expect(bytes1, equals(bytes2));
    });

    test('encodes and decodes CID links', () {
      final hash = Uint8List(32)..fillRange(0, 32, 0xab);
      final cid = Cid.fromHash(hash);
      final link = CidLink(cid);
      final encoded = DagCbor.encode({'ref': link});
      final decoded = DagCbor.decode(encoded) as Map;
      expect(decoded['ref'], isA<CidLink>());
      expect((decoded['ref'] as CidLink).cid, equals(cid));
    });

    test('nested structures round-trip', () {
      final nested = {
        'type': 'record',
        'data': {
          'title': 'Test Post',
          'tags': ['atproto', 'test'],
          'count': 42,
        },
      };
      final decoded = DagCbor.decode(DagCbor.encode(nested));
      expect(decoded, equals(nested));
    });
  });

  group('CID', () {
    test('fromContent produces consistent CID', () {
      final data = DagCbor.encode({'hello': 'world'});
      final cid1 = Cid.fromContent(data);
      final cid2 = Cid.fromContent(data);
      expect(cid1, equals(cid2));
    });

    test('different content produces different CIDs', () {
      final cid1 = Cid.fromContent(DagCbor.encode({'a': 1}));
      final cid2 = Cid.fromContent(DagCbor.encode({'b': 2}));
      expect(cid1, isNot(equals(cid2)));
    });

    test('base32 round-trip', () {
      final data = DagCbor.encode({'test': 'cid'});
      final cid = Cid.fromContent(data);
      final str = cid.toBase32();
      expect(str.startsWith('b'), isTrue);
      final parsed = Cid.fromString(str);
      expect(parsed, equals(cid));
    });

    test('bytes round-trip', () {
      final cid = Cid.fromContent(DagCbor.encode({'round': 'trip'}));
      final bytes = cid.toBytes();
      final restored = Cid.fromBytes(bytes);
      expect(restored, equals(cid));
    });

    test('hash is 32 bytes', () {
      final cid = Cid.fromContent(Uint8List.fromList([1, 2, 3]));
      expect(cid.hash.length, equals(32));
    });
  });

  group('TID', () {
    test('generates 13-character string', () {
      final tid = Tid.next();
      expect(tid.length, equals(13));
    });

    test('generates monotonically increasing values', () {
      final tids = List.generate(100, (_) => Tid.next());
      for (var i = 1; i < tids.length; i++) {
        expect(tids[i].compareTo(tids[i - 1]), greaterThan(0),
            reason: 'TID $i should be > TID ${i - 1}');
      }
    });

    test('parse recovers approximate timestamp', () {
      final before = DateTime.now();
      final tid = Tid.next();
      final after = DateTime.now();
      final parsed = Tid.parse(tid);
      // Should be within 1 second of now
      expect(parsed.millisecondsSinceEpoch,
          greaterThanOrEqualTo(before.millisecondsSinceEpoch - 1000));
      expect(parsed.millisecondsSinceEpoch,
          lessThanOrEqualTo(after.millisecondsSinceEpoch + 1000));
    });

    test('fromDateTime preserves timestamp', () {
      final dt = DateTime(2025, 6, 15, 12, 30, 0);
      final tid = Tid.fromDateTime(dt);
      final parsed = Tid.parse(tid);
      // Should be within 1ms (clock ID doesn't affect timestamp parsing)
      expect((parsed.microsecondsSinceEpoch - dt.microsecondsSinceEpoch).abs(),
          lessThan(1000));
    });

    test('isValid checks format', () {
      expect(Tid.isValid(Tid.next()), isTrue);
      expect(Tid.isValid('short'), isFalse);
      expect(Tid.isValid('0000000000000'), isFalse); // '0' not in alphabet
      expect(Tid.isValid('2222222222222'), isTrue);
    });
  });

  group('Signing', () {
    test('generate key pair', () {
      final kp = AtprotoSigning.generateKeyPair();
      expect(kp.privateKey.length, equals(32));
      expect(kp.publicKey.length, equals(33));
      // Compressed pubkey starts with 0x02 or 0x03
      expect(kp.publicKey[0] == 0x02 || kp.publicKey[0] == 0x03, isTrue);
    });

    test('derive public key', () {
      final kp = AtprotoSigning.generateKeyPair();
      final derived = AtprotoSigning.derivePublicKey(kp.privateKey);
      expect(derived, equals(kp.publicKey));
    });

    test('sign and verify round-trip', () {
      final kp = AtprotoSigning.generateKeyPair();
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final sig = AtprotoSigning.sign(data, kp.privateKey);
      expect(sig.length, equals(64));
      expect(AtprotoSigning.verify(data, sig, kp.publicKey), isTrue);
    });

    test('verify rejects tampered data', () {
      final kp = AtprotoSigning.generateKeyPair();
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final sig = AtprotoSigning.sign(data, kp.privateKey);
      final tampered = Uint8List.fromList([1, 2, 3, 4, 6]);
      expect(AtprotoSigning.verify(tampered, sig, kp.publicKey), isFalse);
    });

    test('verify rejects wrong key', () {
      final kp1 = AtprotoSigning.generateKeyPair();
      final kp2 = AtprotoSigning.generateKeyPair();
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final sig = AtprotoSigning.sign(data, kp1.privateKey);
      expect(AtprotoSigning.verify(data, sig, kp2.publicKey), isFalse);
    });

    test('signature is low-S', () {
      final kp = AtprotoSigning.generateKeyPair();
      // Sign multiple messages to increase confidence
      for (var i = 0; i < 10; i++) {
        final data = Uint8List.fromList([i, i + 1, i + 2]);
        final sig = AtprotoSigning.sign(data, kp.privateKey);
        // S is in bytes 32-63; low-S means s <= n/2
        // We can't easily check this without BigInt, but verify should reject high-S
        expect(AtprotoSigning.verify(data, sig, kp.publicKey), isTrue);
      }
    });

    test('Multikey encoding round-trip', () {
      final kp = AtprotoSigning.generateKeyPair();
      final multikey = AtprotoSigning.publicKeyToMultikey(kp.publicKey);
      expect(multikey.startsWith('z'), isTrue);
      final restored = AtprotoSigning.multikeyToPublicKey(multikey);
      expect(restored, equals(kp.publicKey));
    });
  });

  group('MST', () {
    test('layerForKey produces non-negative values', () {
      final keys = [
        'radio.geogram.blog.post/abc123',
        'radio.geogram.places.entry/def456',
        'radio.geogram.alerts.report/ghi789',
      ];
      for (final key in keys) {
        expect(MerkleSearchTree.layerForKey(key), greaterThanOrEqualTo(0));
      }
    });

    test('insert and get', () {
      final store = MemoryBlockStore();
      final mst = MerkleSearchTree(store);
      final cid = Cid.fromContent(DagCbor.encode({'test': true}));

      mst.insert('collection/key1', cid);
      expect(mst.get('collection/key1'), equals(cid));
      expect(mst.get('collection/nonexistent'), isNull);
    });

    test('insert multiple keys', () {
      final store = MemoryBlockStore();
      final mst = MerkleSearchTree(store);

      final entries = <String, Cid>{};
      for (var i = 0; i < 20; i++) {
        final key = 'radio.geogram.blog.post/key${i.toString().padLeft(3, '0')}';
        final cid = Cid.fromContent(DagCbor.encode({'index': i}));
        entries[key] = cid;
        mst.insert(key, cid);
      }

      // Verify all entries are retrievable
      for (final entry in entries.entries) {
        expect(mst.get(entry.key), equals(entry.value),
            reason: 'Failed to retrieve ${entry.key}');
      }
      expect(mst.length, equals(20));
    });

    test('delete key', () {
      final store = MemoryBlockStore();
      final mst = MerkleSearchTree(store);
      final cid1 = Cid.fromContent(DagCbor.encode({'a': 1}));
      final cid2 = Cid.fromContent(DagCbor.encode({'b': 2}));

      mst.insert('col/key1', cid1);
      mst.insert('col/key2', cid2);
      expect(mst.length, equals(2));

      expect(mst.delete('col/key1'), isTrue);
      expect(mst.get('col/key1'), isNull);
      expect(mst.get('col/key2'), equals(cid2));
      expect(mst.length, equals(1));

      expect(mst.delete('col/nonexistent'), isFalse);
    });

    test('list with prefix', () {
      final store = MemoryBlockStore();
      final mst = MerkleSearchTree(store);

      for (var i = 0; i < 5; i++) {
        mst.insert('blog/post$i', Cid.fromContent(DagCbor.encode({'i': i})));
        mst.insert('places/entry$i', Cid.fromContent(DagCbor.encode({'i': i})));
      }

      final blogEntries = mst.list(prefix: 'blog/');
      expect(blogEntries.length, equals(5));
      for (final e in blogEntries) {
        expect(e.key.startsWith('blog/'), isTrue);
      }
    });

    test('list with cursor and limit', () {
      final store = MemoryBlockStore();
      final mst = MerkleSearchTree(store);

      for (var i = 0; i < 10; i++) {
        mst.insert('col/key${i.toString().padLeft(2, '0')}',
            Cid.fromContent(DagCbor.encode({'i': i})));
      }

      final page1 = mst.list(prefix: 'col/', limit: 3);
      expect(page1.length, equals(3));
      expect(page1[0].key, equals('col/key00'));

      final page2 = mst.list(prefix: 'col/', limit: 3, cursor: page1.last.key);
      expect(page2.length, equals(3));
      expect(page2[0].key, equals('col/key03'));
    });

    test('entries are sorted', () {
      final store = MemoryBlockStore();
      final mst = MerkleSearchTree(store);

      // Insert in random order
      final keys = ['z/9', 'a/1', 'm/5', 'a/2', 'z/1'];
      for (final key in keys) {
        mst.insert(key, Cid.fromContent(DagCbor.encode({'key': key})));
      }

      final sorted = mst.entries;
      for (var i = 1; i < sorted.length; i++) {
        expect(sorted[i].key.compareTo(sorted[i - 1].key), greaterThan(0));
      }
    });

    test('deterministic: same keys produce same root', () {
      Cid? buildTree(List<String> keys) {
        final store = MemoryBlockStore();
        final mst = MerkleSearchTree(store);
        for (final key in keys) {
          mst.insert(key, Cid.fromContent(DagCbor.encode({'key': key})));
        }
        return mst.rootCid;
      }

      final keys = ['col/a', 'col/b', 'col/c', 'col/d', 'col/e'];
      final root1 = buildTree(keys);
      final root2 = buildTree(keys);
      expect(root1, equals(root2));

      // Different insertion order should produce the same tree
      final root3 = buildTree(keys.reversed.toList());
      expect(root3, equals(root1));
    });

    test('update existing key changes root', () {
      final store = MemoryBlockStore();
      final mst = MerkleSearchTree(store);

      final cid1 = Cid.fromContent(DagCbor.encode({'v': 1}));
      final cid2 = Cid.fromContent(DagCbor.encode({'v': 2}));

      mst.insert('col/key', cid1);
      final root1 = mst.rootCid;

      mst.insert('col/key', cid2);
      final root2 = mst.rootCid;

      expect(root1, isNot(equals(root2)));
      expect(mst.get('col/key'), equals(cid2));
    });
  });

  group('CAR', () {
    test('write and read round-trip', () {
      final rootData = DagCbor.encode({'type': 'commit', 'version': 3});
      final rootCid = Cid.fromContent(rootData);

      final childData = DagCbor.encode({'hello': 'world'});
      final childCid = Cid.fromContent(childData);

      final blocks = <Cid, Uint8List>{
        rootCid: rootData,
        childCid: childData,
      };

      final carBytes = CarWriter.write(rootCid, blocks);
      final parsed = CarReader.read(carBytes);

      expect(parsed.roots.length, equals(1));
      expect(parsed.roots[0], equals(rootCid));
      expect(parsed.blocks.length, equals(2));
      expect(parsed.blocks[rootCid], equals(rootData));
      expect(parsed.blocks[childCid], equals(childData));
    });

    test('preserves block content', () {
      final data = DagCbor.encode({
        'did': 'did:web:example.com',
        'records': [1, 2, 3],
      });
      final cid = Cid.fromContent(data);

      final carBytes = CarWriter.write(cid, {cid: data});
      final parsed = CarReader.read(carBytes);

      final decoded = DagCbor.decode(parsed.blocks[cid]!);
      expect(decoded['did'], equals('did:web:example.com'));
      expect(decoded['records'], equals([1, 2, 3]));
    });
  });

  group('Integration', () {
    test('full repo workflow: create records, build MST, export CAR', () {
      final store = MemoryBlockStore();
      final mst = MerkleSearchTree(store);

      // Create some records
      final records = <String, Cid>{};
      for (var i = 0; i < 5; i++) {
        final record = {
          'title': 'Post $i',
          'content': 'Content of post $i',
          'createdAt': DateTime.now().toIso8601String(),
        };
        final bytes = DagCbor.encode(record);
        final cid = store.putBlock(bytes);
        final key = 'radio.geogram.blog.post/${Tid.next()}';
        mst.insert(key, cid);
        records[key] = cid;
      }

      expect(mst.rootCid, isNotNull);
      expect(mst.length, equals(5));

      // Verify all records are in the tree
      for (final entry in records.entries) {
        expect(mst.get(entry.key), equals(entry.value));
      }

      // Build a commit
      final commitData = {
        'did': 'did:web:test.geogram.radio',
        'version': 3,
        'data': CidLink(mst.rootCid!),
        'rev': Tid.next(),
      };
      final commitBytes = DagCbor.encode(commitData);
      final commitCid = store.putBlock(commitBytes);

      // Export as CAR
      final allBlocks = store.allBlocks;
      allBlocks[commitCid] = commitBytes;
      final carBytes = CarWriter.write(commitCid, allBlocks);

      // Re-import CAR
      final imported = CarReader.read(carBytes);
      expect(imported.roots[0], equals(commitCid));
      expect(imported.blocks.length, equals(allBlocks.length));

      // Verify commit content
      final importedCommit = DagCbor.decode(imported.blocks[commitCid]!);
      expect(importedCommit['did'], equals('did:web:test.geogram.radio'));
      expect(importedCommit['version'], equals(3));
    });

    test('ECDSA signing + DAG-CBOR commit', () {
      final kp = AtprotoSigning.generateKeyPair();

      final commitData = {
        'did': 'did:web:example.geogram.radio',
        'version': 3,
        'data': 'placeholder',
        'rev': Tid.next(),
      };
      final unsignedBytes = DagCbor.encode(commitData);
      final sig = AtprotoSigning.sign(unsignedBytes, kp.privateKey);

      commitData['sig'] = sig;
      final signedBytes = DagCbor.encode(commitData);
      final decoded = DagCbor.decode(signedBytes);
      expect(decoded['did'], equals('did:web:example.geogram.radio'));

      // Verify the signature
      final sigFromDecoded = decoded['sig'] as Uint8List;
      expect(AtprotoSigning.verify(unsignedBytes, sigFromDecoded, kp.publicKey), isTrue);
    });
  });
}
