/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * On-disk cache for events fetched from other devices. Mirrors the
 * canonical layout the local user uses for their own events:
 *
 *   {baseDir}/devices/{AUTHOR_CALLSIGN}/events/{YEAR}/{eventId}/
 *     ├── event.txt
 *     └── <media files>          ← populated lazily as the user
 *                                   opens thumbnails / full photos
 *
 * The cache is best-effort: failures are silently ignored so a
 * read-only filesystem or a quota error never breaks the live UI.
 * Reads always check the cache first, falling back to the network;
 * writes happen in the background so the UI never blocks on them.
 *
 * Comments / likes are intentionally NOT cached here yet — they
 * change frequently enough that a cached copy would be misleading,
 * and they\'re cheap to refetch.
 */

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/event.dart';
import 'log_service.dart';
import 'storage_config.dart';

class RemoteEventCache {
  RemoteEventCache._();

  /// Absolute disk folder for one cached event:
  /// `{baseDir}/devices/{CALLSIGN}/events/{YYYY}/{eventId}`.
  /// Year is derived from the first four chars of [eventId] (the
  /// canonical YYYY-MM-DD_… format the rest of the codebase uses);
  /// falls back to "0000" for misshapen ids.
  static String folderPath(String callsign, String eventId) {
    final base = StorageConfig().baseDir;
    final year =
        (eventId.length >= 4 && int.tryParse(eventId.substring(0, 4)) != null)
            ? eventId.substring(0, 4)
            : '0000';
    return p.join(base, 'devices', callsign.toUpperCase(), 'events', year,
        eventId);
  }

  /// Persist the event.txt for [event] under [authorCallsign]\'s
  /// folder. Uses [Event.exportAsText] so the cached file matches
  /// the format the local EventService writes for the user\'s own
  /// events — opening the cache later goes through the exact same
  /// parser.
  static Future<void> writeEvent({
    required String authorCallsign,
    required Event event,
  }) async {
    try {
      final folder = io.Directory(folderPath(authorCallsign, event.id));
      await folder.create(recursive: true);
      final file = io.File(p.join(folder.path, 'event.txt'));
      await file.writeAsString(event.exportAsText());
    } catch (e) {
      LogService().log('RemoteEventCache.writeEvent($authorCallsign/${event.id}) failed: $e');
    }
  }

  /// True when an `event.txt` for this (callsign, eventId) exists
  /// on disk.
  static Future<bool> hasEvent(String authorCallsign, String eventId) async {
    try {
      return io.File(
              p.join(folderPath(authorCallsign, eventId), 'event.txt'))
          .exists();
    } catch (_) {
      return false;
    }
  }

  /// Read previously-cached file bytes (thumbnail, full photo,
  /// trailer, …). Returns null when the file is missing or unreadable
  /// — caller falls back to a network fetch.
  ///
  /// [relativePath] may include subdirectories (e.g.
  /// `contributors/X1HFG3/photo.jpg`). Path-traversal is rejected.
  static Future<Uint8List?> readFile({
    required String authorCallsign,
    required String eventId,
    required String relativePath,
  }) async {
    if (_isUnsafePath(relativePath)) return null;
    try {
      final f = io.File(
          p.join(folderPath(authorCallsign, eventId), relativePath));
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Persist file bytes the user just downloaded so a future view
  /// hits disk instead of the network. Used both for thumbnails
  /// (eagerly cached as the gallery loads) and full-res photos
  /// (lazily cached when the user opens the lightbox).
  static Future<void> writeFile({
    required String authorCallsign,
    required String eventId,
    required String relativePath,
    required List<int> bytes,
  }) async {
    if (_isUnsafePath(relativePath)) return;
    try {
      final target = io.File(
          p.join(folderPath(authorCallsign, eventId), relativePath));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes);
    } catch (e) {
      LogService().log(
          'RemoteEventCache.writeFile($authorCallsign/$eventId/$relativePath) failed: $e');
    }
  }

  /// Persist the full likers list to feedback/likes.txt (one npub
  /// per line). Replaces any existing file so the cache mirrors the
  /// authoritative state on the source device. Empty list writes an
  /// empty file rather than skipping — that\'s how "no likes after
  /// previously having some" is represented.
  static Future<void> writeLikes({
    required String authorCallsign,
    required String eventId,
    required Iterable<String> npubs,
  }) async {
    try {
      final file = io.File(p.join(
          folderPath(authorCallsign, eventId), 'feedback', 'likes.txt'));
      await file.parent.create(recursive: true);
      final cleaned = npubs
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      await file.writeAsString(
          cleaned.isEmpty ? '' : '${cleaned.join('\n')}\n');
    } catch (e) {
      LogService().log(
          'RemoteEventCache.writeLikes($authorCallsign/$eventId) failed: $e');
    }
  }

  /// Persist comments under feedback/comments/{id}.txt using the
  /// same format the local FeedbackCommentUtils writes — so the
  /// cache walks identically to the local user\'s own events.
  ///
  /// [comments] is the list shape /api/content/events/{id} returns:
  /// `[{id, author, timestamp, content, npub?, signature?}, …]`.
  /// Existing comment files in the folder are NOT removed — the
  /// caller is the source of truth, but we don\'t want to nuke a
  /// comment that hasn\'t round-tripped yet through the cache write.
  static Future<void> writeComments({
    required String authorCallsign,
    required String eventId,
    required List<Map<String, dynamic>> comments,
  }) async {
    if (comments.isEmpty) return;
    try {
      final dir = io.Directory(p.join(
          folderPath(authorCallsign, eventId), 'feedback', 'comments'));
      await dir.create(recursive: true);
      for (final c in comments) {
        final id = (c['id'] as String?)?.trim();
        if (id == null || id.isEmpty || _isUnsafePath(id)) continue;
        final author = (c['author'] as String?) ?? '';
        final timestamp = (c['timestamp'] as String?) ?? '';
        final content = (c['content'] as String?) ?? '';
        final npub = c['npub'] as String?;
        final signature = c['signature'] as String?;
        final body = StringBuffer()
          ..writeln('AUTHOR: $author')
          ..writeln('CREATED: $timestamp')
          ..writeln()
          ..writeln(content);
        if (npub != null && npub.isNotEmpty) {
          body
            ..writeln()
            ..writeln('--> npub: $npub');
        }
        if (signature != null && signature.isNotEmpty) {
          body.writeln('--> signature: $signature');
        }
        final f = io.File(p.join(dir.path, '$id.txt'));
        await f.writeAsString(body.toString());
      }
    } catch (e) {
      LogService().log(
          'RemoteEventCache.writeComments($authorCallsign/$eventId) failed: $e');
    }
  }

  static bool _isUnsafePath(String relativePath) {
    if (relativePath.isEmpty) return true;
    if (relativePath.startsWith('/') || relativePath.startsWith('\\')) {
      return true;
    }
    for (final segment in relativePath.split(RegExp(r'[\\/]'))) {
      if (segment == '..' || segment.isEmpty) return true;
    }
    return false;
  }
}
