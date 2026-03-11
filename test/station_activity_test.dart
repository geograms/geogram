import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geogram/api/handlers/activity_handler.dart';
import 'package:geogram/models/station_activity_event.dart';
import 'package:geogram/services/profile_storage.dart';
import 'package:geogram/services/station_activity_store.dart';
import 'package:geogram/services/station_group_access_service.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _configureSqliteForTests();

  group('StationActivityStore', () {
    late Directory tempDir;
    late StationActivityStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'station-activity-store-',
      );
      store = StationActivityStore(baseDir: tempDir.path, maxEvents: 3);
      await store.initialize();
    });

    tearDown(() async {
      store.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('prunes oldest events when the store reaches capacity', () async {
      for (var i = 1; i <= 4; i++) {
        await store.insertEvent(
          StationActivityEvent.create(
            appType: 'blog',
            action: 'published',
            sourceId: 'post-$i',
            sourceName: 'Post $i',
            authorCallsign: 'KB1ABC',
            authorNpub: 'npub1author',
            summary: 'Summary $i',
            date: '2026-03-11 10:0${i}_00',
            visibility: 'public',
          ),
        );
      }

      final events = await store.listEvents(limit: 10);

      expect(events, hasLength(3));
      expect(events.map((event) => event.sourceId), [
        'post-4',
        'post-3',
        'post-2',
      ]);
      expect(await store.latestIndex(), 4);
    });
  });

  group('ActivityHandler', () {
    late Directory tempDir;
    late StationActivityStore store;
    late ActivityHandler handler;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'station-activity-handler-',
      );
      store = StationActivityStore(baseDir: tempDir.path);
      await store.initialize();

      final rootStorage = FilesystemProfileStorage(tempDir.path);
      await rootStorage.writeString(
        'groups-app/app.js',
        jsonEncode({'type': 'groups'}),
      );
      await rootStorage.writeString(
        'groups-app/team-alpha/group.json',
        jsonEncode({
          'group': {
            'title': 'Team Alpha',
            'description': 'Shared station group',
            'type': 'association',
            'created': '2026-03-11 09:00_00',
            'updated': '2026-03-11 09:00_00',
            'status': 'active',
          },
        }),
      );
      await rootStorage.writeString(
        'groups-app/team-alpha/members.txt',
        [
          'ADMIN: KB1ABC',
          '--> npub: npub1member',
          '--> joined: 2026-03-11 09:00_00',
          '',
        ].join('\n'),
      );

      handler = ActivityHandler(
        store: store,
        groupAccess: StationGroupAccessService(rootStorage: rootStorage),
      );
    });

    tearDown(() async {
      store.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'filters public, direct, and group activity by requester access',
      () async {
        await handler.postActivity(
          StationActivityEvent.create(
            appType: 'blog',
            action: 'published',
            sourceId: 'public-post',
            sourceName: 'Public Post',
            authorCallsign: 'KB1ABC',
            authorNpub: 'npub1author',
            summary: 'Public update',
            date: '2026-03-11 10:00_00',
            visibility: 'public',
          ),
        );
        await handler.postActivity(
          StationActivityEvent.create(
            appType: 'chat',
            action: 'message',
            sourceId: 'direct-room',
            sourceName: 'Direct Room',
            authorCallsign: 'KB1ABC',
            authorNpub: 'npub1author',
            summary: 'Restricted update',
            date: '2026-03-11 10:05_00',
            visibility: 'restricted',
            allowedNpubs: ['npub1viewer'],
          ),
        );
        await handler.postActivity(
          StationActivityEvent.create(
            appType: 'chat',
            action: 'message',
            sourceId: 'group-room',
            sourceName: 'Team Alpha',
            authorCallsign: 'KB1ABC',
            authorNpub: 'npub1author',
            summary: 'Group update',
            date: '2026-03-11 10:10_00',
            visibility: 'group',
            allowedGroups: ['team-alpha'],
          ),
        );

        final anonymousFeed = await handler.getFeed();
        final directViewerFeed = await handler.getFeed(
          requesterNpub: 'npub1viewer',
        );
        final groupMemberFeed = await handler.getFeed(
          requesterNpub: 'npub1member',
        );
        final unrelatedFeed = await handler.getFeed(
          requesterNpub: 'npub1other',
        );

        expect(anonymousFeed['count'], 1);
        expect(
          (anonymousFeed['activities'] as List<dynamic>).map(
            (item) => (item as Map<String, dynamic>)['source_id'],
          ),
          ['public-post'],
        );

        expect(directViewerFeed['count'], 2);
        expect(
          (directViewerFeed['activities'] as List<dynamic>).map(
            (item) => (item as Map<String, dynamic>)['source_id'],
          ),
          ['direct-room', 'public-post'],
        );

        expect(groupMemberFeed['count'], 2);
        expect(
          (groupMemberFeed['activities'] as List<dynamic>).map(
            (item) => (item as Map<String, dynamic>)['source_id'],
          ),
          ['group-room', 'public-post'],
        );

        expect(unrelatedFeed['count'], 1);
        expect(
          (unrelatedFeed['activities'] as List<dynamic>).map(
            (item) => (item as Map<String, dynamic>)['source_id'],
          ),
          ['public-post'],
        );
      },
    );
  });
}

void _configureSqliteForTests() {
  final cwd = Directory.current.path;

  if (Platform.isLinux) {
    final libPath = '$cwd/third_party/sqlite/linux-x64/libsqlite3.so.0';
    if (File(libPath).existsSync()) {
      sqlite_open.open.overrideFor(
        sqlite_open.OperatingSystem.linux,
        () => DynamicLibrary.open(libPath),
      );
    }
    return;
  }

  if (Platform.isMacOS) {
    final libPath = '$cwd/third_party/sqlite/macos-x64/libsqlite3.dylib';
    if (File(libPath).existsSync()) {
      sqlite_open.open.overrideFor(
        sqlite_open.OperatingSystem.macOS,
        () => DynamicLibrary.open(libPath),
      );
    }
    return;
  }

  if (Platform.isWindows) {
    final libPath = '$cwd/third_party/sqlite/windows-x64/sqlite3.dll';
    if (File(libPath).existsSync()) {
      sqlite_open.open.overrideFor(
        sqlite_open.OperatingSystem.windows,
        () => DynamicLibrary.open(libPath),
      );
    }
  }
}
