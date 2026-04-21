/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Concrete [AppContentProvider] implementations for the apps this
 * codebase ships today. Each provider knows its app's on-disk layout
 * and reuses the existing storage utilities where possible.
 *
 * Adding a new app type: implement [AppContentProvider], then add one
 * line to [defaultAppContentProviders]. The /api/content/{appType}/…
 * endpoint surfaces it without further wiring.
 */

import 'dart:convert';

import '../../models/event.dart';
import '../../services/profile_storage.dart';
import '../../util/blog_folder_utils.dart';
import '../../util/feedback_folder_utils.dart';
import '../../util/media_thumbnail_utils.dart';
import 'app_content_provider.dart';
import 'blog_handler.dart';

/// Canonical list of providers every device ships with.
List<AppContentProvider> defaultAppContentProviders() => [
      BlogContentProvider(),
      EventContentProvider(),
      ChatContentProvider(),
      AlertContentProvider(),
      SharedContentProvider(),
    ];

// ─────────────────────────── Blog ───────────────────────────────

class BlogContentProvider extends AppContentProvider {
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

  @override
  Future<List<Map<String, dynamic>>> listPublic({
    required ProfileStorage storage,
    Map<String, String> query = const {},
  }) async {
    final api = BlogHandler(storage: storage);
    final result = await api.getBlogPosts(
      year: int.tryParse(query['year'] ?? ''),
      tag: query['tag'],
      limit: int.tryParse(query['limit'] ?? ''),
      offset: int.tryParse(query['offset'] ?? ''),
    );
    if (result['success'] != true) return const [];
    final posts = result['posts'];
    if (posts is List) {
      return posts.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>?> getPublicItem(
    String itemId, {
    required ProfileStorage storage,
  }) async {
    final api = BlogHandler(storage: storage);
    final result = await api.getPostDetails(itemId);
    if (result['success'] == true) {
      return result;
    }
    return null;
  }

  @override
  Future<RemoteFile?> getPublicFile(
    String itemId,
    String relativePath, {
    required ProfileStorage storage,
    bool thumbnail = false,
  }) async {
    if (_unsafePath(relativePath)) return null;
    final api = BlogHandler(storage: storage);
    // Existing helper accepts a single filename — for now reuse it.
    final filePath = await api.getFilePath(itemId, relativePath);
    if (filePath == null) return null;
    return _readFile(storage, filePath, relativePath, thumbnail: thumbnail);
  }
}

// ─────────────────────────── Events ─────────────────────────────

class EventContentProvider extends AppContentProvider {
  @override
  String get appType => 'events';

  @override
  String get title => 'Events';

  @override
  Future<int> countPublic({required ProfileStorage storage}) async {
    final entries = await _listPublicEventEntries(storage);
    return entries.length;
  }

  @override
  Future<List<Map<String, dynamic>>> listPublic({
    required ProfileStorage storage,
    Map<String, String> query = const {},
  }) async {
    final entries = await _listPublicEventEntries(storage);
    final yearFilter = int.tryParse(query['year'] ?? '');
    final limit = int.tryParse(query['limit'] ?? '');

    final out = <Map<String, dynamic>>[];
    for (final entry in entries) {
      if (yearFilter != null && entry.event.year != yearFilter) continue;
      final json = entry.event.toApiJson(summary: true);
      // Flyer / trailer presence from disk (public events only — a
      // request_access event keeps its media hidden). The list uses
      // this to know whether to show a thumbnail.
      if (entry.event.visibility == 'public') {
        final media = await _scanEventMedia(storage, entry.eventPath);
        json['photos'] = media.photos;
        if (media.flyer != null) json['flyer'] = media.flyer;
        json['has_photos'] = media.photos.isNotEmpty;
        json['has_flyer'] = media.flyer != null;
        if (media.trailer != null) {
          json['trailer'] = media.trailer;
          json['has_trailer'] = true;
        }
      } else {
        json['has_photos'] = false;
        json['has_flyer'] = false;
        json['has_trailer'] = false;
      }
      // Engagement counts straight from the canonical feedback
      // folder so the list view can show "N likes · N views" without
      // a second round-trip per event.
      final counts = await _engagementCounts(storage, entry.eventPath);
      json['like_count'] = counts.likes;
      json['comment_count'] = counts.comments;
      json['view_count'] = counts.views;
      out.add(json);
    }
    out.sort((a, b) => (b['timestamp'] as String? ?? '')
        .compareTo(a['timestamp'] as String? ?? ''));
    if (limit != null && limit > 0 && out.length > limit) {
      return out.sublist(0, limit);
    }
    return out;
  }

  @override
  Future<Map<String, dynamic>?> getPublicItem(
    String itemId, {
    required ProfileStorage storage,
  }) async {
    final entry = await _findEvent(storage, itemId);
    if (entry == null) return null;
    final vis = entry.event.visibility;
    if (vis != 'public' && vis != 'request_access') return null;

    final data = entry.event.toApiJson(summary: false);

    // Event.fromText never populates `photos` / `trailer` — those
    // are disk-scanned. For public events we surface every image /
    // short-clip the event folder contains (minus `trailer.*` which
    // gets its own slot). For request_access events we hide media
    // until access is granted.
    if (vis == 'request_access') {
      data['content'] = '';
      data['agenda'] = null;
      data['photos'] = const [];
      data.remove('flyer');
      data['trailer'] = null;
      data['updates'] = const [];
      data['links'] = const [];
      data['contacts'] = const [];
      data['access_request_required'] = true;
    } else {
      final media = await _scanEventMedia(storage, entry.eventPath);
      data['photos'] = media.photos;
      if (media.flyer != null) data['flyer'] = media.flyer;
      if (media.trailer != null) data['trailer'] = media.trailer;
      data['access_request_required'] = false;
    }

    final counts = await _engagementCounts(storage, entry.eventPath);
    data['like_count'] = counts.likes;
    data['comment_count'] = counts.comments;
    data['view_count'] = counts.views;
    return data;
  }

  @override
  Future<RemoteFile?> getPublicFile(
    String itemId,
    String relativePath, {
    required ProfileStorage storage,
    bool thumbnail = false,
  }) async {
    if (_unsafePath(relativePath)) return null;
    final entry = await _findEvent(storage, itemId);
    if (entry == null) return null;
    final vis = entry.event.visibility;
    // Files inside request_access events stay private until granted.
    if (vis != 'public') return null;
    final filePath = '${entry.eventPath}/$relativePath';
    return _readFile(storage, filePath, relativePath, thumbnail: thumbnail);
  }

  // ── helpers ────────────────────────────────────────────────────

  Future<List<_EventEntry>> _listPublicEventEntries(
      ProfileStorage storage) async {
    final out = <_EventEntry>[];
    try {
      final entries = await storage.listDirectory('events', recursive: true);
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        if (!entry.name.endsWith('event.txt')) continue;
        try {
          final content = await storage.readString(entry.path);
          if (content == null) continue;
          final parts = entry.path.split('/');
          final idIndex = parts.lastIndexOf('event.txt') - 1;
          final eventId = idIndex >= 0 ? parts[idIndex] : entry.path;
          final ev = Event.fromText(content, eventId);
          if (ev.visibility != 'public' &&
              ev.visibility != 'request_access') {
            continue;
          }
          // event.txt path → the parent directory is the event folder.
          final eventPath = entry.path.replaceAll(RegExp(r'/event\.txt$'), '');
          out.add(_EventEntry(event: ev, eventPath: eventPath));
        } catch (_) {
          // Skip unreadable / malformed events.
        }
      }
    } catch (_) {}
    return out;
  }

  Future<_EventEntry?> _findEvent(
      ProfileStorage storage, String eventId) async {
    final entries = await _listPublicEventEntries(storage);
    for (final e in entries) {
      if (e.event.id == eventId) return e;
    }
    return null;
  }

  /// Scan the event folder for gallery media (images + short clips).
  /// `trailer.*` is surfaced separately. Matches the same pattern
  /// the local EventService uses so on-device and remote browse
  /// stay consistent.
  static final RegExp _mediaPattern = RegExp(
    r'\.(jpg|jpeg|png|gif|webp|mp4|mov|webm|mkv|avi|wmv|flv)$',
    caseSensitive: false,
  );
  static final RegExp _trailerPattern =
      RegExp(r'^trailer\.', caseSensitive: false);

  Future<_EventMedia> _scanEventMedia(
      ProfileStorage storage, String eventPath) async {
    final photos = <String>[];
    String? trailer;
    String? flyer;
    try {
      final entries = await storage.listDirectory(eventPath);
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        final name = entry.name;
        if (_trailerPattern.hasMatch(name) &&
            _mediaPattern.hasMatch(name)) {
          trailer ??= name;
          continue;
        }
        if (_mediaPattern.hasMatch(name)) {
          photos.add(name);
          // A file literally named `flyer.<ext>` is the author's
          // designated cover. Anything else is just a photo.
          if (flyer == null && name.toLowerCase().startsWith('flyer.')) {
            flyer = name;
          }
        }
      }
    } catch (_) {}
    // Same ordering the local list widget uses: flyer.* first, then
    // photo-N.* in numeric order, then the rest alphabetically.
    photos.sort((a, b) {
      final aLower = a.toLowerCase();
      final bLower = b.toLowerCase();
      final aIsFlyer = aLower.startsWith('flyer.');
      final bIsFlyer = bLower.startsWith('flyer.');
      if (aIsFlyer && !bIsFlyer) return -1;
      if (!aIsFlyer && bIsFlyer) return 1;
      final photoNum = RegExp(r'^photo-(\d+)\.');
      final aMatch = photoNum.firstMatch(aLower);
      final bMatch = photoNum.firstMatch(bLower);
      if (aMatch != null && bMatch != null) {
        return int.parse(aMatch.group(1)!)
            .compareTo(int.parse(bMatch.group(1)!));
      }
      if (aMatch != null) return -1;
      if (bMatch != null) return 1;
      return aLower.compareTo(bLower);
    });
    return _EventMedia(photos: photos, flyer: flyer, trailer: trailer);
  }
}

class _EventMedia {
  final List<String> photos;
  final String? flyer;
  final String? trailer;
  const _EventMedia({required this.photos, this.flyer, this.trailer});
}

class _EventEntry {
  final Event event;
  final String eventPath;
  _EventEntry({required this.event, required this.eventPath});
}

// ─────────────────────────── Chat ───────────────────────────────

class ChatContentProvider extends AppContentProvider {
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

// ─────────────────────────── Alerts ─────────────────────────────

class AlertContentProvider extends AppContentProvider {
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
        } catch (_) {}
      }
      return count;
    } catch (_) {
      return 0;
    }
  }
}

// ─────────────────────────── Shared ─────────────────────────────

class SharedContentProvider extends AppContentProvider {
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

// ─────────────────────────── Helpers ────────────────────────────

class _Counts {
  final int likes;
  final int comments;
  final int views;
  const _Counts(
      {this.likes = 0, this.comments = 0, this.views = 0});
}

Future<_Counts> _engagementCounts(
    ProfileStorage storage, String contentPath) async {
  int likes = 0;
  int comments = 0;
  int views = 0;
  try {
    likes = await FeedbackFolderUtils.getFeedbackCount(
      contentPath,
      FeedbackFolderUtils.feedbackTypeLikes,
      storage: storage,
    );
  } catch (_) {}
  try {
    views = await FeedbackFolderUtils.getViewCount(
      contentPath,
      storage: storage,
    );
  } catch (_) {}
  try {
    final commentsDir = '$contentPath/feedback/comments';
    final entries = await storage.listDirectory(commentsDir);
    for (final e in entries) {
      if (!e.isDirectory && e.name.endsWith('.txt')) comments++;
    }
  } catch (_) {}
  return _Counts(likes: likes, comments: comments, views: views);
}

/// Read the bytes at [storagePath] and, when [thumbnail] is set
/// and the file is a supported gallery type, return the downscaled
/// preview instead. Falls back to raw bytes when thumbnail
/// generation isn't possible (unknown format, decode failure, non-
/// filesystem storage backend).
Future<RemoteFile?> _readFile(
  ProfileStorage storage,
  String storagePath,
  String relativePath, {
  required bool thumbnail,
}) async {
  final ext = _extensionOf(relativePath);
  if (thumbnail && MediaThumbnailUtils.isGalleryMedia(ext)) {
    try {
      final abs = storage.getAbsolutePath(storagePath);
      final thumb =
          await MediaThumbnailUtils.generateForPath(abs, ext);
      if (thumb != null) {
        return RemoteFile(
          bytes: thumb.bytes,
          contentType: thumb.contentType,
        );
      }
    } catch (_) {
      // Thumbnail path doesn't work for every storage backend — fall
      // through to raw bytes.
    }
  }
  final bytes = await storage.readBytes(storagePath);
  if (bytes == null) return null;
  return RemoteFile(
    bytes: bytes,
    contentType: _guessContentType(relativePath),
  );
}

String _extensionOf(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return '';
  return path.substring(dot).toLowerCase();
}

bool _unsafePath(String path) {
  if (path.isEmpty) return true;
  if (path.startsWith('/') || path.startsWith('\\')) return true;
  for (final segment in path.split(RegExp(r'[\\/]'))) {
    if (segment == '..' || segment.isEmpty) return true;
  }
  return false;
}

String _guessContentType(String path) {
  final ext = path.toLowerCase().split('.').last;
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'svg':
      return 'image/svg+xml';
    case 'mp4':
      return 'video/mp4';
    case 'webm':
      return 'video/webm';
    case 'pdf':
      return 'application/pdf';
    case 'json':
      return 'application/json';
    case 'txt':
    case 'md':
      return 'text/plain; charset=utf-8';
    case 'html':
    case 'htm':
      return 'text/html; charset=utf-8';
    default:
      return 'application/octet-stream';
  }
}
