/*
 * Phase 3 tests for AT Protocol repo operations and AT-URI parsing.
 *
 * Tests: AtUri, repo CRUD, applyWrites-style batch ops, listRecords pagination.
 * Run: flutter test test/atproto_phase3_test.dart
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:geogram/atproto/at_uri.dart';
import 'package:geogram/atproto/atproto_storage.dart';
import 'package:geogram/atproto/repo.dart';
import 'package:geogram/atproto/signing.dart';
import 'package:geogram/atproto/tid.dart';

void main() {
  group('AtUri', () {
    test('parse full AT-URI', () {
      final uri = AtUri.parse('at://did:web:example.com/app.bsky.feed.post/3jui7p2blaz2c');
      expect(uri.authority, equals('did:web:example.com'));
      expect(uri.collection, equals('app.bsky.feed.post'));
      expect(uri.rkey, equals('3jui7p2blaz2c'));
      expect(uri.isRecord, isTrue);
      expect(uri.isDid, isTrue);
    });

    test('parse AT-URI with collection only', () {
      final uri = AtUri.parse('at://did:plc:abc123/radio.geogram.blog.post');
      expect(uri.authority, equals('did:plc:abc123'));
      expect(uri.collection, equals('radio.geogram.blog.post'));
      expect(uri.rkey, isNull);
      expect(uri.isRecord, isFalse);
    });

    test('parse AT-URI with authority only', () {
      final uri = AtUri.parse('at://did:web:station.geogram.radio');
      expect(uri.authority, equals('did:web:station.geogram.radio'));
      expect(uri.collection, isNull);
      expect(uri.rkey, isNull);
    });

    test('parse AT-URI with handle authority', () {
      final uri = AtUri.parse('at://user.bsky.social/app.bsky.feed.post/abc');
      expect(uri.authority, equals('user.bsky.social'));
      expect(uri.isDid, isFalse);
    });

    test('toString round-trip', () {
      final original = 'at://did:web:example.com/radio.geogram.blog.post/3jui7p2blaz2c';
      final uri = AtUri.parse(original);
      expect(uri.toString(), equals(original));
    });

    test('toString authority only', () {
      final uri = AtUri.parse('at://did:web:example.com');
      expect(uri.toString(), equals('at://did:web:example.com'));
    });

    test('throws on invalid prefix', () {
      expect(() => AtUri.parse('http://example.com'), throwsFormatException);
    });

    test('throws on empty authority', () {
      expect(() => AtUri.parse('at://'), throwsFormatException);
    });

    test('tryParse returns null on invalid', () {
      expect(AtUri.tryParse('not-a-uri'), isNull);
      expect(AtUri.tryParse('at://did:web:x/a/b'), isNotNull);
    });

    test('equality', () {
      final a = AtUri.parse('at://did:web:x/col/key');
      final b = AtUri.parse('at://did:web:x/col/key');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('Repo CRUD', () {
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
      repo.commit();
    });

    tearDown(() {
      storage.close();
    });

    test('createRecord and getRecord round-trip', () {
      final record = {
        '\$type': 'radio.geogram.blog.post',
        'text': 'Hello AT Proto',
        'createdAt': '2026-02-22T00:00:00Z',
      };
      final result = repo.createRecord('radio.geogram.blog.post', record);
      repo.commit();

      expect(result.uri, startsWith('at://$did/radio.geogram.blog.post/'));

      // Parse URI to get rkey
      final atUri = AtUri.parse(result.uri);
      expect(atUri.collection, equals('radio.geogram.blog.post'));
      expect(atUri.rkey, isNotNull);

      final readBack = repo.getRecord('radio.geogram.blog.post', atUri.rkey!);
      expect(readBack, isNotNull);
      expect(readBack!.value['\$type'], equals('radio.geogram.blog.post'));
      expect(readBack.value['text'], equals('Hello AT Proto'));
      expect(readBack.cid.toBase32(), equals(result.cid.toBase32()));
    });

    test('createRecord with explicit rkey', () {
      final result = repo.createRecord(
        'radio.geogram.blog.post',
        {'text': 'test'},
        rkey: 'my-custom-key',
      );
      repo.commit();

      expect(result.uri, equals('at://$did/radio.geogram.blog.post/my-custom-key'));

      final readBack = repo.getRecord('radio.geogram.blog.post', 'my-custom-key');
      expect(readBack, isNotNull);
      expect(readBack!.value['text'], equals('test'));
    });

    test('putRecord updates existing record', () {
      final create = repo.createRecord(
        'radio.geogram.blog.post',
        {'text': 'original'},
        rkey: 'update-test',
      );
      repo.commit();

      final update = repo.putRecord(
        'radio.geogram.blog.post',
        'update-test',
        {'text': 'updated'},
      );
      repo.commit();

      expect(update.uri, equals(create.uri));
      // CID should change since content changed
      expect(update.cid.toBase32(), isNot(equals(create.cid.toBase32())));

      final readBack = repo.getRecord('radio.geogram.blog.post', 'update-test');
      expect(readBack!.value['text'], equals('updated'));
    });

    test('putRecord creates new record if not exists', () {
      final result = repo.putRecord(
        'radio.geogram.blog.post',
        'new-rkey',
        {'text': 'new record via put'},
      );
      repo.commit();

      final readBack = repo.getRecord('radio.geogram.blog.post', 'new-rkey');
      expect(readBack, isNotNull);
      expect(readBack!.value['text'], equals('new record via put'));
    });

    test('deleteRecord removes record', () {
      repo.createRecord(
        'radio.geogram.blog.post',
        {'text': 'to delete'},
        rkey: 'delete-me',
      );
      repo.commit();

      expect(repo.getRecord('radio.geogram.blog.post', 'delete-me'), isNotNull);

      final deleted = repo.deleteRecord('radio.geogram.blog.post', 'delete-me');
      repo.commit();
      expect(deleted, isTrue);

      expect(repo.getRecord('radio.geogram.blog.post', 'delete-me'), isNull);
    });

    test('deleteRecord returns false for non-existent', () {
      expect(repo.deleteRecord('radio.geogram.blog.post', 'no-such-key'), isFalse);
    });

    test('getRecord returns null for non-existent', () {
      expect(repo.getRecord('radio.geogram.blog.post', 'no-such-key'), isNull);
    });

    test('listCollections', () {
      repo.createRecord('radio.geogram.blog.post', {'text': 'a'});
      repo.createRecord('radio.geogram.event', {'title': 'b'});
      repo.commit();

      final collections = repo.listCollections();
      expect(collections, containsAll(['radio.geogram.blog.post', 'radio.geogram.event']));
    });
  });

  group('listRecords pagination', () {
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

      // Create 10 records with sequential TIDs
      for (var i = 0; i < 10; i++) {
        repo.createRecord(
          'radio.geogram.blog.post',
          {'text': 'Post $i', 'index': i},
        );
      }
      repo.commit();
    });

    tearDown(() {
      storage.close();
    });

    test('list all records', () {
      final records = repo.listRecords('radio.geogram.blog.post');
      expect(records.length, equals(10));
    });

    test('list with limit', () {
      final records = repo.listRecords('radio.geogram.blog.post', limit: 3);
      expect(records.length, equals(3));
    });

    test('paginate with cursor', () {
      final page1 = repo.listRecords('radio.geogram.blog.post', limit: 5);
      expect(page1.length, equals(5));

      final cursor = page1.last.rkey;
      final page2 = repo.listRecords('radio.geogram.blog.post', limit: 5, cursor: cursor);
      expect(page2.length, equals(5));

      // No overlap
      final page1Rkeys = page1.map((r) => r.rkey).toSet();
      final page2Rkeys = page2.map((r) => r.rkey).toSet();
      expect(page1Rkeys.intersection(page2Rkeys), isEmpty);
    });

    test('paginate beyond end returns empty', () {
      final all = repo.listRecords('radio.geogram.blog.post');
      final cursor = all.last.rkey;
      final beyond = repo.listRecords('radio.geogram.blog.post', cursor: cursor);
      expect(beyond, isEmpty);
    });

    test('list empty collection returns empty', () {
      final records = repo.listRecords('nonexistent.collection');
      expect(records, isEmpty);
    });

    test('list in reverse', () {
      final forward = repo.listRecords('radio.geogram.blog.post');
      final reversed = repo.listRecords('radio.geogram.blog.post', reverse: true);
      expect(reversed.length, equals(forward.length));
      expect(reversed.first.rkey, equals(forward.last.rkey));
      expect(reversed.last.rkey, equals(forward.first.rkey));
    });
  });

  group('Batch operations', () {
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
      repo.commit();
    });

    tearDown(() {
      storage.close();
    });

    test('batch create, update, and delete', () {
      // Create two records
      final r1 = repo.createRecord(
        'radio.geogram.blog.post',
        {'text': 'first'},
        rkey: 'batch-1',
      );
      final r2 = repo.createRecord(
        'radio.geogram.blog.post',
        {'text': 'second'},
        rkey: 'batch-2',
      );
      repo.commit();

      // Update first, delete second, create third (simulating applyWrites)
      repo.putRecord('radio.geogram.blog.post', 'batch-1', {'text': 'first-updated'});
      repo.deleteRecord('radio.geogram.blog.post', 'batch-2');
      repo.createRecord('radio.geogram.blog.post', {'text': 'third'}, rkey: 'batch-3');
      repo.commit();

      // Verify
      final updated = repo.getRecord('radio.geogram.blog.post', 'batch-1');
      expect(updated!.value['text'], equals('first-updated'));

      expect(repo.getRecord('radio.geogram.blog.post', 'batch-2'), isNull);

      final created = repo.getRecord('radio.geogram.blog.post', 'batch-3');
      expect(created!.value['text'], equals('third'));

      final all = repo.listRecords('radio.geogram.blog.post');
      expect(all.length, equals(2));
    });
  });

  group('Repo export', () {
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

    test('exportCar after records', () {
      repo.createRecord('radio.geogram.blog.post', {'text': 'export test'});
      repo.commit();

      final car = repo.exportCar();
      expect(car, isNotEmpty);
      // CAR v1 starts with a header
      expect(car.length, greaterThan(10));
    });

    test('exportCar throws before commit', () {
      expect(() => repo.exportCar(), throwsStateError);
    });
  });

  group('Record content types', () {
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
      repo.commit();
    });

    tearDown(() {
      storage.close();
    });

    test('record with nested objects', () {
      final record = {
        '\$type': 'radio.geogram.blog.post',
        'text': 'Hello',
        'embed': {
          '\$type': 'radio.geogram.blog.post#image',
          'alt': 'A photo',
          'image': {
            '\$type': 'blob',
            'ref': {'\$link': 'abc123'},
            'mimeType': 'image/jpeg',
            'size': 12345,
          },
        },
        'tags': ['test', 'atproto'],
        'createdAt': '2026-02-22T00:00:00Z',
      };

      final result = repo.createRecord('radio.geogram.blog.post', record);
      repo.commit();

      final readBack = repo.getRecord('radio.geogram.blog.post', AtUri.parse(result.uri).rkey!);
      expect(readBack, isNotNull);
      expect(readBack!.value['embed']['alt'], equals('A photo'));
      expect(readBack.value['tags'], equals(['test', 'atproto']));
    });

    test('record with integer and boolean values', () {
      final record = {
        '\$type': 'radio.geogram.event',
        'title': 'Test Event',
        'capacity': 100,
        'isPublic': true,
      };

      final result = repo.createRecord('radio.geogram.event', record);
      repo.commit();

      final readBack = repo.getRecord('radio.geogram.event', AtUri.parse(result.uri).rkey!);
      expect(readBack!.value['capacity'], equals(100));
      expect(readBack.value['isPublic'], equals(true));
    });

    test('multiple collections are independent', () {
      repo.createRecord('radio.geogram.blog.post', {'text': 'blog'});
      repo.createRecord('radio.geogram.event', {'title': 'event'});
      repo.createRecord('radio.geogram.place', {'name': 'place'});
      repo.commit();

      expect(repo.listRecords('radio.geogram.blog.post').length, equals(1));
      expect(repo.listRecords('radio.geogram.event').length, equals(1));
      expect(repo.listRecords('radio.geogram.place').length, equals(1));
    });
  });

  group('Repo reopen', () {
    test('repo persists across open/close', () {
      final storage = AtprotoStorage.openInMemory();
      final kp = AtprotoSigning.generateKeyPair();
      final did = 'did:web:test.geogram.radio';

      // Create and commit
      final repo1 = AtprotoRepo.create(
        did: did,
        storage: storage,
        signingKey: kp.privateKey,
      );
      repo1.createRecord('radio.geogram.blog.post', {'text': 'persist test'}, rkey: 'persist-1');
      repo1.commit();

      // Reopen
      final repo2 = AtprotoRepo.open(did: did, storage: storage);
      expect(repo2, isNotNull);

      final record = repo2!.getRecord('radio.geogram.blog.post', 'persist-1');
      expect(record, isNotNull);
      expect(record!.value['text'], equals('persist test'));

      storage.close();
    });
  });
}
