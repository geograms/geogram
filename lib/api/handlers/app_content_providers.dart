/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Concrete [AppContentProvider] implementations for the apps this
 * codebase ships today. Each provider knows its app's on-disk layout
 * and reuses the existing storage utilities where possible.
 *
 * Adding a new app type: implement [AppContentProvider], then add one
 * line to [defaultAppContentProviders].
 */

import 'dart:convert';

import '../../models/event.dart';
import '../../services/profile_storage.dart';
import '../../util/blog_folder_utils.dart';
import 'app_content_provider.dart';

/// Canonical list of providers every device ships with.
List<AppContentProvider> defaultAppContentProviders() => [
      BlogContentProvider(),
      EventContentProvider(),
      ChatContentProvider(),
      AlertContentProvider(),
      SharedContentProvider(),
    ];

class BlogContentProvider implements AppContentProvider {
  @override
  String get appType => 'blog';

  @override
  String get title => 'Blog';

  @override
  Future<int> countPublic({required ProfileStorage storage}) async {
    try {
      // `blog/{year}/{postId}/post.md` is the canonical layout —
      // BlogFolderUtils already knows how to walk it.
      final paths = await BlogFolderUtils.findAllPostPaths(
        'blog',
        storage: storage,
      );
      return paths.length;
    } catch (_) {
      return 0;
    }
  }
}

class EventContentProvider implements AppContentProvider {
  @override
  String get appType => 'events';

  @override
  String get title => 'Events';

  @override
  Future<int> countPublic({required ProfileStorage storage}) async {
    try {
      final entries = await storage.listDirectory('events', recursive: true);
      var count = 0;
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        if (!entry.name.endsWith('event.txt')) continue;
        try {
          final content = await storage.readString(entry.path);
          if (content == null) continue;
          // Extract the event id from the path for the parser so it
          // doesn't throw; only the visibility field is read.
          final parts = entry.path.split('/');
          final idIndex = parts.lastIndexOf('event.txt') - 1;
          final eventId = idIndex >= 0 ? parts[idIndex] : entry.path;
          final ev = Event.fromText(content, eventId);
          if (ev.visibility == 'public' ||
              ev.visibility == 'request_access') {
            count++;
          }
        } catch (_) {
          // Skip unreadable / malformed events — they shouldn't break
          // the whole discovery response.
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }
}

class ChatContentProvider implements AppContentProvider {
  @override
  String get appType => 'chat';

  @override
  String get title => 'Chat';

  @override
  Future<int> countPublic({required ProfileStorage storage}) async {
    try {
      final entries = await storage.listDirectory('chat');
      var count = 0;
      for (final entry in entries) {
        if (entry.isDirectory) count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }
}

class AlertContentProvider implements AppContentProvider {
  @override
  String get appType => 'alerts';

  @override
  String get title => 'Reports';

  @override
  Future<int> countPublic({required ProfileStorage storage}) async {
    try {
      final topLevel = await storage.listDirectory('alerts');
      var count = 0;
      for (final callsignEntry in topLevel) {
        if (!callsignEntry.isDirectory) continue;
        try {
          final alerts = await storage.listDirectory(callsignEntry.path);
          for (final alertEntry in alerts) {
            if (alertEntry.isDirectory) count++;
          }
        } catch (_) {
          // Unreadable callsign dir — skip.
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }
}

class SharedContentProvider implements AppContentProvider {
  @override
  String get appType => 'shared';

  @override
  String get title => 'Shared';

  @override
  Future<int> countPublic({required ProfileStorage storage}) async {
    // `shared/tree.json` is the authoritative index maintained by the
    // shared-folder app. Count its `files` list rather than scanning
    // the directory (which contains static site assets).
    try {
      final content = await storage.readString('shared/tree.json');
      if (content == null || content.trim().isEmpty) return 0;
      final json = jsonDecode(content);
      if (json is! Map<String, dynamic>) return 0;
      final files = json['files'];
      if (files is List) return files.length;
      return 0;
    } catch (_) {
      return 0;
    }
  }
}
