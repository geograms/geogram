/*
 * Phase 5 tests for AT Protocol Geogram content collections.
 *
 * Tests: Collection adapters (blog, places, events, alerts),
 *        toRecord/fromRecord round-trips, CollectionSyncManager,
 *        idempotent sync behavior.
 * Run: LD_LIBRARY_PATH=build/libs flutter test test/atproto_phase5_test.dart
 */

import 'package:flutter_test/flutter_test.dart';

import 'package:geogram/atproto/atproto_storage.dart';
import 'package:geogram/atproto/collection_sync.dart';
import 'package:geogram/atproto/collections/alerts_collection.dart';
import 'package:geogram/atproto/collections/blog_collection.dart';
import 'package:geogram/atproto/collections/collection_adapter.dart';
import 'package:geogram/atproto/collections/events_collection.dart';
import 'package:geogram/atproto/collections/places_collection.dart';
import 'package:geogram/atproto/repo.dart';
import 'package:geogram/atproto/signing.dart';
import 'package:geogram/atproto/tid.dart';
import 'package:geogram/models/blog_post.dart';
import 'package:geogram/models/event.dart';
import 'package:geogram/models/place.dart';
import 'package:geogram/models/report.dart';

void main() {
  group('BlogCollection adapter', () {
    test('toRecord produces valid record with required fields', () {
      final post = BlogPost(
        id: 'test-post',
        author: 'KB1ABC',
        timestamp: '2026-01-15 10:30_00',
        title: 'Hello World',
        content: 'This is a test blog post.',
        status: BlogStatus.published,
        tags: ['test', 'hello'],
        description: 'A test post',
      );

      final record = BlogCollection.toRecord(post);

      expect(record['\$type'], equals('radio.geogram.blog.post'));
      expect(record['title'], equals('Hello World'));
      expect(record['content'], equals('This is a test blog post.'));
      expect(record['createdAt'], isNotNull);
      expect(record['summary'], equals('A test post'));
      expect(record['tags'], equals(['test', 'hello']));
      expect(record['status'], equals('published'));
      expect(record['author'], equals('KB1ABC'));
    });

    test('toRecord with location', () {
      final post = BlogPost(
        id: 'loc-post',
        author: 'KB1ABC',
        timestamp: '2026-01-15 10:30_00',
        title: 'Located Post',
        content: 'Post with location.',
        location: '38.736946, -9.142685',
      );

      final record = BlogCollection.toRecord(post);

      expect(record['latitude'], closeTo(38.736946, 0.0001));
      expect(record['longitude'], closeTo(-9.142685, 0.0001));
    });

    test('toRecord omits empty optional fields', () {
      final post = BlogPost(
        id: 'minimal',
        author: '',
        timestamp: '2026-01-15 10:30_00',
        title: 'Minimal',
        content: 'Content only.',
      );

      final record = BlogCollection.toRecord(post);

      expect(record.containsKey('summary'), isFalse);
      expect(record.containsKey('tags'), isFalse);
      expect(record.containsKey('latitude'), isFalse);
      expect(record.containsKey('longitude'), isFalse);
      expect(record.containsKey('imageName'), isFalse);
      expect(record.containsKey('status'), isFalse); // draft is default, not published
    });

    test('fromRecord reconstructs BlogPost', () {
      final record = {
        '\$type': 'radio.geogram.blog.post',
        'title': 'Test Post',
        'content': 'Hello from AT Proto.',
        'createdAt': '2026-01-15T10:30:00.000Z',
        'summary': 'A summary',
        'tags': ['atproto', 'test'],
        'status': 'published',
        'author': 'KB1ABC',
      };

      final post = BlogCollection.fromRecord('abc123', record);

      expect(post.id, equals('abc123'));
      expect(post.title, equals('Test Post'));
      expect(post.content, equals('Hello from AT Proto.'));
      expect(post.description, equals('A summary'));
      expect(post.tags, equals(['atproto', 'test']));
      expect(post.isPublished, isTrue);
      expect(post.author, equals('KB1ABC'));
    });

    test('fromRecord with location', () {
      final record = {
        'title': 'Located',
        'content': 'With coords.',
        'createdAt': '2026-01-15T10:30:00.000Z',
        'latitude': 38.736946,
        'longitude': -9.142685,
      };

      final post = BlogCollection.fromRecord('loc1', record);

      expect(post.hasLocation, isTrue);
      expect(post.latitude, closeTo(38.736946, 0.0001));
      expect(post.longitude, closeTo(-9.142685, 0.0001));
    });

    test('round-trip preserves core data', () {
      final original = BlogPost(
        id: 'rt-post',
        author: 'KB1ABC',
        timestamp: '2026-06-15 14:30_00',
        title: 'Round Trip',
        content: 'Testing round-trip conversion.',
        description: 'Round trip test',
        tags: ['round', 'trip'],
        status: BlogStatus.published,
        location: '40.0, -8.0',
      );

      final record = BlogCollection.toRecord(original);
      final restored = BlogCollection.fromRecord('rt-post', record);

      expect(restored.title, equals(original.title));
      expect(restored.content, equals(original.content));
      expect(restored.description, equals(original.description));
      expect(restored.tags, equals(original.tags));
      expect(restored.isPublished, equals(original.isPublished));
      expect(restored.author, equals(original.author));
    });
  });

  group('PlacesCollection adapter', () {
    test('toRecord produces valid record', () {
      final place = Place(
        name: 'Test Monument',
        created: '2026-02-01 09:00_00',
        author: 'KB1ABC',
        latitude: 38.736946,
        longitude: -9.142685,
        radius: 50,
        type: 'monument',
        description: 'A historic monument.',
        address: 'Lisbon, Portugal',
        visibility: 'public',
      );

      final record = PlacesCollection.toRecord(place);

      expect(record['\$type'], equals('radio.geogram.places.entry'));
      expect(record['name'], equals('Test Monument'));
      expect(record['latitude'], closeTo(38.736946, 0.0001));
      expect(record['longitude'], closeTo(-9.142685, 0.0001));
      expect(record['createdAt'], isNotNull);
      expect(record['category'], equals('monument'));
      expect(record['description'], equals('A historic monument.'));
      expect(record['address'], equals('Lisbon, Portugal'));
      expect(record['radius'], equals(50));
      expect(record['visibility'], equals('public'));
    });

    test('toRecord with multilingual names', () {
      final place = Place(
        name: 'Monument',
        names: {'EN': 'Monument', 'PT': 'Monumento'},
        created: '2026-02-01 09:00_00',
        author: 'KB1ABC',
        latitude: 38.0,
        longitude: -9.0,
        radius: 100,
      );

      final record = PlacesCollection.toRecord(place);
      expect(record['names'], equals({'EN': 'Monument', 'PT': 'Monumento'}));
    });

    test('fromRecord reconstructs Place', () {
      final record = {
        'name': 'Test Park',
        'latitude': 40.0,
        'longitude': -8.5,
        'createdAt': '2026-02-01T09:00:00.000Z',
        'category': 'park',
        'description': 'A nice park.',
        'radius': 200,
        'visibility': 'public',
        'author': 'KB2DEF',
      };

      final place = PlacesCollection.fromRecord('park1', record);

      expect(place.name, equals('Test Park'));
      expect(place.latitude, closeTo(40.0, 0.01));
      expect(place.longitude, closeTo(-8.5, 0.01));
      expect(place.type, equals('park'));
      expect(place.description, equals('A nice park.'));
      expect(place.radius, equals(200));
      expect(place.visibility, equals('public'));
    });

    test('round-trip preserves core data', () {
      final original = Place(
        name: 'Round Trip Place',
        created: '2026-03-10 12:00_00',
        author: 'KB1ABC',
        latitude: 41.15,
        longitude: -8.61,
        radius: 75,
        type: 'restaurant',
        description: 'A test restaurant.',
        address: 'Porto, Portugal',
        visibility: 'public',
      );

      final record = PlacesCollection.toRecord(original);
      final restored = PlacesCollection.fromRecord('rtp1', record);

      expect(restored.name, equals(original.name));
      expect(restored.latitude, closeTo(original.latitude, 0.01));
      expect(restored.longitude, closeTo(original.longitude, 0.01));
      expect(restored.type, equals(original.type));
      expect(restored.description, equals(original.description));
      expect(restored.visibility, equals(original.visibility));
    });
  });

  group('EventsCollection adapter', () {
    test('toRecord produces valid record', () {
      final event = Event(
        id: 'evt1',
        author: 'KB1ABC',
        timestamp: '2026-03-15 18:00_00',
        title: 'Ham Radio Meetup',
        location: '38.736946,-9.142685',
        content: 'Monthly ham radio meetup.',
        locationName: 'Lisbon Hackerspace',
        startDate: '2026-03-15',
        endDate: '2026-03-15',
        visibility: 'public',
        contacts: ['KB2DEF', 'KB3GHI'],
      );

      final record = EventsCollection.toRecord(event);

      expect(record['\$type'], equals('radio.geogram.events.entry'));
      expect(record['title'], equals('Ham Radio Meetup'));
      expect(record['location'], equals('38.736946,-9.142685'));
      expect(record['createdAt'], isNotNull);
      expect(record['content'], equals('Monthly ham radio meetup.'));
      expect(record['locationName'], equals('Lisbon Hackerspace'));
      expect(record['startDate'], equals('2026-03-15'));
      expect(record['endDate'], equals('2026-03-15'));
      expect(record['contacts'], equals(['KB2DEF', 'KB3GHI']));
    });

    test('toRecord with online location', () {
      final event = Event(
        id: 'evt2',
        author: 'KB1ABC',
        timestamp: '2026-03-15 18:00_00',
        title: 'Online Event',
        location: 'online',
        content: 'Virtual meetup.',
      );

      final record = EventsCollection.toRecord(event);

      expect(record['location'], equals('online'));
      expect(record.containsKey('latitude'), isFalse);
      expect(record.containsKey('longitude'), isFalse);
    });

    test('fromRecord reconstructs Event', () {
      final record = {
        'title': 'Restored Event',
        'location': '40.0,-8.5',
        'createdAt': '2026-03-15T18:00:00.000Z',
        'content': 'Restored content.',
        'locationName': 'Porto Center',
        'startDate': '2026-03-15',
        'visibility': 'group',
        'author': 'KB1ABC',
      };

      final event = EventsCollection.fromRecord('rev1', record);

      expect(event.id, equals('rev1'));
      expect(event.title, equals('Restored Event'));
      expect(event.location, equals('40.0,-8.5'));
      expect(event.content, equals('Restored content.'));
      expect(event.locationName, equals('Porto Center'));
      expect(event.startDate, equals('2026-03-15'));
      expect(event.visibility, equals('group'));
    });

    test('round-trip preserves core data', () {
      final original = Event(
        id: 'rte1',
        author: 'KB1ABC',
        timestamp: '2026-04-01 10:00_00',
        title: 'Round Trip Event',
        location: '38.7,-9.1',
        content: 'Testing round trip.',
        agenda: 'Intro, Talk, Q&A',
      );

      final record = EventsCollection.toRecord(original);
      final restored = EventsCollection.fromRecord('rte1', record);

      expect(restored.title, equals(original.title));
      expect(restored.location, equals(original.location));
      expect(restored.content, equals(original.content));
      expect(restored.agenda, equals(original.agenda));
    });
  });

  group('AlertsCollection adapter', () {
    test('toRecord produces valid record', () {
      final report = Report(
        folderName: 'alert1',
        created: '2026-02-20 14:00_00',
        author: 'KB1ABC',
        latitude: 38.736946,
        longitude: -9.142685,
        severity: ReportSeverity.urgent,
        type: 'weather',
        status: ReportStatus.open,
        titles: {'EN': 'Storm Warning'},
        descriptions: {'EN': 'Heavy rain expected.'},
        address: 'Lisbon',
      );

      final record = AlertsCollection.toRecord(report);

      expect(record['\$type'], equals('radio.geogram.alerts.report'));
      expect(record['type'], equals('weather'));
      expect(record['severity'], equals('warning')); // urgent maps to warning
      expect(record['region'], isNotNull);
      expect(record['createdAt'], isNotNull);
      expect(record['title'], equals('Storm Warning'));
      expect(record['description'], equals('Heavy rain expected.'));
      expect(record['latitude'], closeTo(38.736946, 0.0001));
      expect(record['longitude'], closeTo(-9.142685, 0.0001));
      expect(record['address'], equals('Lisbon'));
    });

    test('severity mapping', () {
      for (final (severity, expected) in [
        (ReportSeverity.emergency, 'critical'),
        (ReportSeverity.urgent, 'warning'),
        (ReportSeverity.attention, 'warning'),
        (ReportSeverity.info, 'info'),
      ]) {
        final report = Report(
          folderName: 'sev-test',
          created: '2026-02-20 14:00_00',
          author: '',
          latitude: 0,
          longitude: 0,
          severity: severity,
          type: 'test',
          status: ReportStatus.open,
        );
        expect(AlertsCollection.toRecord(report)['severity'], equals(expected));
      }
    });

    test('fromRecord reconstructs Report', () {
      final record = {
        'type': 'safety',
        'region': '38.7_-9.1',
        'severity': 'critical',
        'createdAt': '2026-02-20T14:00:00.000Z',
        'title': 'Safety Alert',
        'description': 'Take precautions.',
        'latitude': 38.7,
        'longitude': -9.1,
        'author': 'KB1ABC',
      };

      final report = AlertsCollection.fromRecord('alert1', record);

      expect(report.folderName, equals('alert1'));
      expect(report.type, equals('safety'));
      expect(report.severity, equals(ReportSeverity.emergency)); // critical maps to emergency
      expect(report.titles['EN'], equals('Safety Alert'));
      expect(report.descriptions['EN'], equals('Take precautions.'));
      expect(report.latitude, closeTo(38.7, 0.01));
    });

    test('toRecord with expiration', () {
      final report = Report(
        folderName: 'exp1',
        created: '2026-02-20 14:00_00',
        author: '',
        latitude: 38.0,
        longitude: -9.0,
        severity: ReportSeverity.info,
        type: 'test',
        status: ReportStatus.open,
        expires: '2026-02-21 14:00_00',
      );

      final record = AlertsCollection.toRecord(report);

      expect(record['expiresAt'], isNotNull);
      expect(record['expiresAt'], contains('2026-02-21'));
    });
  });

  group('CollectionAdapter helpers', () {
    test('rkeyFromTimestamp generates valid TID', () {
      final rkey = CollectionAdapter.rkeyFromTimestamp('2026-01-15 10:30_00');

      expect(rkey.length, equals(13));
      expect(Tid.isValid(rkey), isTrue);
    });

    test('rkeyFromTimestamp preserves temporal ordering', () {
      final rkey1 = CollectionAdapter.rkeyFromTimestamp('2026-01-15 10:00_00');
      final rkey2 = CollectionAdapter.rkeyFromTimestamp('2026-01-15 11:00_00');
      final rkey3 = CollectionAdapter.rkeyFromTimestamp('2026-01-16 10:00_00');

      // TIDs should be lexicographically ordered
      expect(rkey1.compareTo(rkey2), lessThan(0));
      expect(rkey2.compareTo(rkey3), lessThan(0));
    });

    test('rkeyFromTimestamp handles invalid timestamp gracefully', () {
      final rkey = CollectionAdapter.rkeyFromTimestamp('invalid-timestamp');

      expect(rkey.length, equals(13));
      expect(Tid.isValid(rkey), isTrue);
    });
  });

  group('CollectionSyncManager', () {
    late AtprotoStorage storage;
    late AtprotoRepo repo;

    setUp(() {
      storage = AtprotoStorage.openInMemory();
      final kp = AtprotoSigning.generateKeyPair();
      repo = AtprotoRepo.create(
        did: 'did:web:test.geogram.radio',
        storage: storage,
        signingKey: kp.privateKey,
      );
      repo.commit();
    });

    tearDown(() {
      storage.close();
    });

    test('syncAll syncs blog posts', () async {
      final posts = [
        BlogPost(
          id: 'post1',
          author: 'KB1ABC',
          timestamp: '2026-01-15 10:00_00',
          title: 'Post 1',
          content: 'Content 1',
          status: BlogStatus.published,
        ),
        BlogPost(
          id: 'post2',
          author: 'KB1ABC',
          timestamp: '2026-01-16 10:00_00',
          title: 'Post 2',
          content: 'Content 2',
          status: BlogStatus.published,
        ),
      ];

      final logs = <String>[];
      final sync = CollectionSyncManager(
        repo: repo,
        log: (level, msg) => logs.add('$level: $msg'),
      );
      sync.register(BlogCollection(listPosts: () async => posts));

      final results = await sync.syncAll();

      expect(results['radio.geogram.blog.post'], equals(2));

      // Verify records exist in repo
      final records = repo.listRecords('radio.geogram.blog.post');
      expect(records.length, equals(2));
    });

    test('syncAll is idempotent', () async {
      final posts = [
        BlogPost(
          id: 'post1',
          author: 'KB1ABC',
          timestamp: '2026-01-15 10:00_00',
          title: 'Post 1',
          content: 'Content 1',
          status: BlogStatus.published,
        ),
      ];

      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );
      sync.register(BlogCollection(listPosts: () async => posts));

      // First sync creates records
      final results1 = await sync.syncAll();
      expect(results1['radio.geogram.blog.post'], equals(1));

      // Second sync skips existing
      final results2 = await sync.syncAll();
      expect(results2['radio.geogram.blog.post'], equals(0));

      // Still only one record
      final records = repo.listRecords('radio.geogram.blog.post');
      expect(records.length, equals(1));
    });

    test('syncAll skips draft blog posts', () async {
      final posts = [
        BlogPost(
          id: 'draft1',
          author: 'KB1ABC',
          timestamp: '2026-01-15 10:00_00',
          title: 'Draft Post',
          content: 'Not published yet.',
          status: BlogStatus.draft,
        ),
      ];

      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );
      sync.register(BlogCollection(listPosts: () async => posts));

      final results = await sync.syncAll();
      expect(results['radio.geogram.blog.post'], equals(0));
    });

    test('syncAll syncs places (skips private)', () async {
      final places = [
        Place(
          name: 'Public Park',
          created: '2026-02-01 09:00_00',
          author: 'KB1ABC',
          latitude: 38.7,
          longitude: -9.1,
          radius: 100,
          visibility: 'public',
        ),
        Place(
          name: 'Private Spot',
          created: '2026-02-02 09:00_00',
          author: 'KB1ABC',
          latitude: 39.0,
          longitude: -9.0,
          radius: 50,
          visibility: 'private',
        ),
      ];

      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );
      sync.register(PlacesCollection(listPlaces: () async => places));

      final results = await sync.syncAll();
      expect(results['radio.geogram.places.entry'], equals(1));
    });

    test('syncAll syncs events (skips private)', () async {
      final events = [
        Event(
          id: 'evt1',
          author: 'KB1ABC',
          timestamp: '2026-03-15 18:00_00',
          title: 'Public Event',
          location: '38.7,-9.1',
          content: 'Public event.',
          visibility: 'public',
        ),
        Event(
          id: 'evt2',
          author: 'KB1ABC',
          timestamp: '2026-03-16 18:00_00',
          title: 'Private Event',
          location: 'online',
          content: 'Private event.',
          visibility: 'private',
        ),
      ];

      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );
      sync.register(EventsCollection(listEvents: () async => events));

      final results = await sync.syncAll();
      expect(results['radio.geogram.events.entry'], equals(1));
    });

    test('syncAll syncs alerts (skips closed)', () async {
      final reports = [
        Report(
          folderName: 'alert1',
          created: '2026-02-20 14:00_00',
          author: 'KB1ABC',
          latitude: 38.7,
          longitude: -9.1,
          severity: ReportSeverity.urgent,
          type: 'weather',
          status: ReportStatus.open,
          titles: {'EN': 'Storm'},
        ),
        Report(
          folderName: 'alert2',
          created: '2026-02-19 14:00_00',
          author: 'KB1ABC',
          latitude: 38.7,
          longitude: -9.1,
          severity: ReportSeverity.info,
          type: 'test',
          status: ReportStatus.closed,
          titles: {'EN': 'Old'},
        ),
      ];

      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );
      sync.register(AlertsCollection(listReports: () async => reports));

      final results = await sync.syncAll();
      expect(results['radio.geogram.alerts.report'], equals(1));
    });

    test('syncCollection syncs a single collection', () async {
      final posts = [
        BlogPost(
          id: 'post1',
          author: 'KB1ABC',
          timestamp: '2026-01-15 10:00_00',
          title: 'Post 1',
          content: 'Content 1',
          status: BlogStatus.published,
        ),
      ];

      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );
      sync.register(BlogCollection(listPosts: () async => posts));
      sync.register(PlacesCollection(listPlaces: () async => []));

      final created = await sync.syncCollection('radio.geogram.blog.post');
      expect(created, equals(1));

      // Places should not have been synced
      final placeRecords = repo.listRecords('radio.geogram.places.entry');
      expect(placeRecords, isEmpty);
    });

    test('syncCollection returns -1 for unknown NSID', () async {
      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );

      final result = await sync.syncCollection('radio.geogram.unknown.type');
      expect(result, equals(-1));
    });

    test('getCollectionStatus returns info for all adapters', () {
      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );
      sync.register(BlogCollection(listPosts: () async => []));
      sync.register(PlacesCollection(listPlaces: () async => []));

      final status = sync.getCollectionStatus();

      expect(status.length, equals(2));
      expect(status[0]['nsid'], equals('radio.geogram.blog.post'));
      expect(status[0]['displayName'], equals('Blog Posts'));
      expect(status[0]['recordCount'], equals(0));
      expect(status[1]['nsid'], equals('radio.geogram.places.entry'));
    });

    test('syncAll with multiple collections creates single commit', () async {
      final posts = [
        BlogPost(
          id: 'p1',
          author: 'KB1ABC',
          timestamp: '2026-01-15 10:00_00',
          title: 'Post',
          content: 'Content',
          status: BlogStatus.published,
        ),
      ];
      final places = [
        Place(
          name: 'Place',
          created: '2026-02-01 09:00_00',
          author: 'KB1ABC',
          latitude: 38.0,
          longitude: -9.0,
          radius: 100,
          visibility: 'public',
        ),
      ];

      final headBefore = repo.headCid;

      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );
      sync.register(BlogCollection(listPosts: () async => posts));
      sync.register(PlacesCollection(listPlaces: () async => places));

      final results = await sync.syncAll();

      expect(results['radio.geogram.blog.post'], equals(1));
      expect(results['radio.geogram.places.entry'], equals(1));

      // Head should have changed (new commit)
      expect(repo.headCid!.toBase32(), isNot(equals(headBefore!.toBase32())));

      // Both collections should have records
      expect(repo.listRecords('radio.geogram.blog.post').length, equals(1));
      expect(repo.listRecords('radio.geogram.places.entry').length, equals(1));
    });
  });

  group('Records stored via sync are retrievable via repo API', () {
    late AtprotoStorage storage;
    late AtprotoRepo repo;

    setUp(() {
      storage = AtprotoStorage.openInMemory();
      final kp = AtprotoSigning.generateKeyPair();
      repo = AtprotoRepo.create(
        did: 'did:web:test.geogram.radio',
        storage: storage,
        signingKey: kp.privateKey,
      );
      repo.commit();
    });

    tearDown(() {
      storage.close();
    });

    test('synced blog post retrievable via getRecord', () async {
      final posts = [
        BlogPost(
          id: 'get-post',
          author: 'KB1ABC',
          timestamp: '2026-06-15 14:30_00',
          title: 'Retrievable Post',
          content: 'Should be fetchable.',
          status: BlogStatus.published,
          tags: ['fetch', 'test'],
        ),
      ];

      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );
      sync.register(BlogCollection(listPosts: () async => posts));
      await sync.syncAll();

      // Find the rkey
      final records = repo.listRecords('radio.geogram.blog.post');
      expect(records.length, equals(1));

      final record = records.first;
      expect(record.value['\$type'], equals('radio.geogram.blog.post'));
      expect(record.value['title'], equals('Retrievable Post'));
      expect(record.value['content'], equals('Should be fetchable.'));
      expect(record.value['tags'], equals(['fetch', 'test']));

      // Should also be retrievable by rkey
      final fetched = repo.getRecord('radio.geogram.blog.post', record.rkey);
      expect(fetched, isNotNull);
      expect(fetched!.cid.toBase32(), equals(record.cid.toBase32()));
    });

    test('synced place retrievable via listRecords', () async {
      final places = [
        Place(
          name: 'Belem Tower',
          created: '2026-02-15 09:00_00',
          author: 'KB1ABC',
          latitude: 38.6916,
          longitude: -9.2159,
          radius: 50,
          type: 'monument',
          description: 'Historic tower in Lisbon.',
          visibility: 'public',
        ),
      ];

      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );
      sync.register(PlacesCollection(listPlaces: () async => places));
      await sync.syncAll();

      final records = repo.listRecords('radio.geogram.places.entry');
      expect(records.length, equals(1));
      expect(records.first.value['name'], equals('Belem Tower'));
      expect(records.first.value['latitude'], closeTo(38.6916, 0.001));
      expect(records.first.value['category'], equals('monument'));
    });

    test('listCollections includes synced collections', () async {
      final sync = CollectionSyncManager(
        repo: repo,
        log: (_, __) {},
      );
      sync.register(BlogCollection(listPosts: () async => [
        BlogPost(
          id: 'p1',
          author: '',
          timestamp: '2026-01-01 00:00_00',
          title: 'T',
          content: 'C',
          status: BlogStatus.published,
        ),
      ]));
      sync.register(EventsCollection(listEvents: () async => [
        Event(
          id: 'e1',
          author: '',
          timestamp: '2026-01-01 00:00_00',
          title: 'E',
          location: 'online',
          content: 'C',
          visibility: 'public',
        ),
      ]));
      await sync.syncAll();

      final collections = repo.listCollections();
      expect(collections, contains('radio.geogram.blog.post'));
      expect(collections, contains('radio.geogram.events.entry'));
    });
  });
}
