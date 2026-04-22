/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * On-disk cache for events fetched from other devices. Mirrors the
 * canonical layout the local user uses for their own events:
 *
 *   {baseDir}/devices/{AUTHOR_CALLSIGN}/events/{YEAR}/{eventId}/
 *     ├── event.txt
 *     ├── feedback/
 *     │   ├── likes.txt
 *     │   └── comments/{id}.txt
 *     └── <media files>          ← populated lazily as the user
 *                                   opens thumbnails / full photos
 *
 * All I/O goes through the [ProfileStorage] abstraction so an
 * encrypted-archive future doesn\'t bypass the cipher. External
 * cache folders (`devices/{otherCallsign}/`) are non-profile data,
 * so a [FilesystemProfileStorage] rooted at that path is the right
 * fit — same pattern EventService.getAllEventsGlobal already uses
 * when it walks other-device subtrees.
 *
 * The cache is best-effort: failures are silently ignored so a
 * read-only filesystem or a quota error never breaks the live UI.
 */

import 'dart:typed_data';

import '../models/event.dart';
import 'log_service.dart';
import 'profile_storage.dart';
import 'storage_config.dart';

class RemoteEventCache {
  RemoteEventCache._();

  /// Base path on disk for `{baseDir}/devices/{CALLSIGN}`. The
  /// per-event ProfileStorage is rooted here so relative paths
  /// like `events/{year}/{id}/event.txt` resolve correctly.
  static String _devicePath(String callsign) {
    final base = StorageConfig().baseDir;
    return '$base/devices/${callsign.toUpperCase()}';
  }

  /// Storage instance for one cached author. External cache folders
  /// are plain filesystem (they\'re not profiles) — same as how
  /// EventService.getAllEventsGlobal builds storages for other
  /// devices when it walks them.
  static ProfileStorage _storageFor(String authorCallsign) {
    return FilesystemProfileStorage(_devicePath(authorCallsign));
  }

  /// Year derived from the canonical YYYY-MM-DD_… event id; falls
  /// back to "0000" so a malformed id still maps somewhere
  /// deterministic.
  static String _yearFor(String eventId) {
    if (eventId.length >= 4 &&
        int.tryParse(eventId.substring(0, 4)) != null) {
      return eventId.substring(0, 4);
    }
    return '0000';
  }

  /// Folder path relative to the storage root for this event.
  static String _eventFolder(String eventId) =>
      'events/${_yearFor(eventId)}/$eventId';

  // ── Reads ─────────────────────────────────────────────────────────

  /// True when an `event.txt` for this (callsign, eventId) exists.
  static Future<bool> hasEvent(String authorCallsign, String eventId) async {
    try {
      return await _storageFor(authorCallsign)
          .exists('${_eventFolder(eventId)}/event.txt');
    } catch (_) {
      return false;
    }
  }

  /// Read previously-cached file bytes. Returns null when the file
  /// is missing or unreadable — caller falls back to a network
  /// fetch.
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
      return await _storageFor(authorCallsign)
          .readBytes('${_eventFolder(eventId)}/$relativePath');
    } catch (_) {
      return null;
    }
  }

  // ── Writes ────────────────────────────────────────────────────────

  /// Persist the event.txt for [event] under [authorCallsign]\'s
  /// folder via [Event.exportAsText].
  static Future<void> writeEvent({
    required String authorCallsign,
    required Event event,
  }) async {
    try {
      await _storageFor(authorCallsign).writeString(
        '${_eventFolder(event.id)}/event.txt',
        event.exportAsText(),
      );
    } catch (e) {
      LogService().log(
          'RemoteEventCache.writeEvent($authorCallsign/${event.id}) failed: $e');
    }
  }

  /// Persist file bytes the user just downloaded so a future view
  /// hits storage instead of the network. Used both for thumbnails
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
      await _storageFor(authorCallsign).writeBytes(
        '${_eventFolder(eventId)}/$relativePath',
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      );
    } catch (e) {
      LogService().log(
          'RemoteEventCache.writeFile($authorCallsign/$eventId/$relativePath) failed: $e');
    }
  }

  /// Persist the full likers list to feedback/likes.txt (one npub
  /// per line, sorted, deduped). Replaces any existing file so the
  /// cache mirrors the authoritative state on the source device.
  /// Empty list writes an empty file so a removed-all-likes state
  /// still round-trips.
  static Future<void> writeLikes({
    required String authorCallsign,
    required String eventId,
    required Iterable<String> npubs,
  }) async {
    try {
      final cleaned = npubs
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      await _storageFor(authorCallsign).writeString(
        '${_eventFolder(eventId)}/feedback/likes.txt',
        cleaned.isEmpty ? '' : '${cleaned.join('\n')}\n',
      );
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
      final storage = _storageFor(authorCallsign);
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
        await storage.writeString(
          '${_eventFolder(eventId)}/feedback/comments/$id.txt',
          body.toString(),
        );
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
