/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/event.dart';
import '../services/log_service.dart';
import 'event_bus.dart';

/// Reusable notifier for any activity on an event the local user authored
/// that needs the owner's attention: pending access requests, new comments,
/// new likes — and any future kind that fits the same shape.
///
/// All event-activity NowItems share the `event_*` appType family. Callers
/// (apps grid badge, Now panel router, event tile badge) consume the
/// [ownedAppTypes] set and the [scanEvent]/[scanAll] entry points so a new
/// activity kind only needs to be added inside this file.
///
/// Persistence / dedup model:
///  * Access requests already track state via the `status` field in
///    `feedback/access_requests.json` (pending / approved / denied), so
///    the access-request scan emits only `pending` entries — no extra
///    bookkeeping needed.
///  * Comments and likes don't have a per-entry state, so this notifier
///    keeps `feedback/notifications_seen.json` per event — a flat
///    `{notificationId: timestamp}` map. The owner clears entries by
///    opening the editor (which calls [markAllSeen]); future scans then
///    skip those ids.
class EventActivityNotifier {
  EventActivityNotifier._();

  /// All NowItem appType values this notifier is responsible for. Other
  /// modules (badges, Now-panel routing) check membership instead of
  /// hard-coding individual strings so a new activity kind drops in here.
  static const Set<String> ownedAppTypes = {
    'event_access_request',
    'event_new_comment',
    'event_new_like',
  };

  static const String _seenFileName = 'notifications_seen.json';

  /// The owner's NOSTR npub. Set once at app startup so the notifier can
  /// skip self-authored comments/likes (an author hearting their own
  /// event shouldn't badge themselves). Empty string disables filtering.
  static String _ownerNpub = '';
  static set ownerNpub(String value) => _ownerNpub = value.trim();
  static String get ownerNpub => _ownerNpub;

  // ─────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────

  /// Scan one event folder and fire NowItemEvents for any unseen
  /// activity. Returns the number of NowItems emitted.
  static Future<int> scanEvent({
    required String eventPath,
    required String eventId,
    required String eventTitle,
  }) async {
    int emitted = 0;
    try {
      final seen = await _loadSeen(eventPath);
      emitted += await _scanAccessRequests(
        eventPath: eventPath,
        eventId: eventId,
        eventTitle: eventTitle,
      );
      emitted += await _scanComments(
        eventPath: eventPath,
        eventId: eventId,
        eventTitle: eventTitle,
        seen: seen,
      );
      emitted += await _scanLikes(
        eventPath: eventPath,
        eventId: eventId,
        eventTitle: eventTitle,
        seen: seen,
      );
    } catch (e) {
      LogService().log('EventActivityNotifier: scanEvent($eventId) failed: $e');
    }
    return emitted;
  }

  /// Walk every event under [eventsAppPath] and scan each. Used at app
  /// startup so badges restore from disk without waiting for the next
  /// inbound write.
  static Future<int> scanAll(String eventsAppPath) async {
    if (eventsAppPath.isEmpty) return 0;
    final root = Directory(eventsAppPath);
    if (!await root.exists()) return 0;

    int total = 0;
    try {
      await for (final yearEntry in root.list()) {
        if (yearEntry is! Directory) continue;
        final yearName = yearEntry.path.split(Platform.pathSeparator).last;
        if (yearName.length != 4 || int.tryParse(yearName) == null) continue;

        await for (final eventEntry in yearEntry.list()) {
          if (eventEntry is! Directory) continue;
          final eventId =
              eventEntry.path.split(Platform.pathSeparator).last;
          final title = await _readEventTitle(eventEntry.path, eventId);
          total += await scanEvent(
            eventPath: eventEntry.path,
            eventId: eventId,
            eventTitle: title,
          );
        }
      }
    } catch (e) {
      LogService().log('EventActivityNotifier: scanAll failed: $e');
    }
    return total;
  }

  /// Mark every comment + like activity on an event as seen. Called when
  /// the owner opens the editor's activity tab — once they've laid eyes
  /// on the items, future scans should not re-fire them.
  ///
  /// Access requests aren't touched here; they're acknowledged by the
  /// owner deciding (approve/deny) which flips their status field.
  static Future<void> markAllSeen({
    required String eventPath,
  }) async {
    try {
      final seen = await _loadSeen(eventPath);
      final now = DateTime.now().toUtc().toIso8601String();

      // Comments
      final commentsDir = Directory('$eventPath/feedback/comments');
      if (await commentsDir.exists()) {
        await for (final f in commentsDir.list()) {
          if (f is File && f.path.endsWith('.txt')) {
            final commentId = f.path.split(Platform.pathSeparator).last
                .replaceAll('.txt', '');
            seen[_commentId(eventPath, commentId)] = now;
          }
        }
      }

      // Likes
      final likesFile = File('$eventPath/feedback/likes.txt');
      if (await likesFile.exists()) {
        for (final line in await likesFile.readAsLines()) {
          final npub = line.trim();
          if (npub.isEmpty) continue;
          seen[_likeId(eventPath, npub)] = now;
        }
      }

      await _saveSeen(eventPath, seen);
    } catch (e) {
      LogService().log('EventActivityNotifier: markAllSeen failed: $e');
    }
  }

  /// Count unseen activity items on one event. Cheap; reads the seen
  /// map once, then scans the comment/like sources. Used by the event
  /// tile so the badge covers all activity, not just access requests.
  static Future<int> countUnseenForEvent(String eventPath) async {
    int count = 0;
    try {
      // Pending access requests (status-based — no seen.json involvement).
      final ar = File('$eventPath/feedback/access_requests.json');
      if (await ar.exists()) {
        try {
          final content = await ar.readAsString();
          if (content.trim().isNotEmpty) {
            final list = jsonDecode(content) as List<dynamic>;
            count += list.whereType<Map<String, dynamic>>().where((e) {
              final s = (e['status'] as String?) ?? 'pending';
              return s == 'pending';
            }).length;
          }
        } catch (_) {}
      }

      final seen = await _loadSeen(eventPath);

      // Unseen comments (skip ones authored by the event owner).
      final commentsDir = Directory('$eventPath/feedback/comments');
      if (await commentsDir.exists()) {
        await for (final f in commentsDir.list()) {
          if (f is! File || !f.path.endsWith('.txt')) continue;
          final commentId = f.path.split(Platform.pathSeparator).last
              .replaceAll('.txt', '');
          if (seen.containsKey(_commentId(eventPath, commentId))) continue;
          if (await _commentBelongsToOwner(f)) continue;
          count++;
        }
      }

      // Unseen likes (skip the owner's own like).
      final likesFile = File('$eventPath/feedback/likes.txt');
      if (await likesFile.exists()) {
        for (final line in await likesFile.readAsLines()) {
          final npub = line.trim();
          if (npub.isEmpty) continue;
          if (_isOwnerNpub(npub)) continue;
          if (seen.containsKey(_likeId(eventPath, npub))) continue;
          count++;
        }
      }
    } catch (e) {
      LogService().log(
        'EventActivityNotifier: countUnseenForEvent failed: $e',
      );
    }
    return count;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Per-type scanners
  // ─────────────────────────────────────────────────────────────────────

  static Future<int> _scanAccessRequests({
    required String eventPath,
    required String eventId,
    required String eventTitle,
  }) async {
    final file = File('$eventPath/feedback/access_requests.json');
    if (!await file.exists()) return 0;
    int emitted = 0;
    try {
      final content = await file.readAsString();
      if (content.trim().isEmpty) return 0;
      final list = jsonDecode(content) as List<dynamic>;
      for (final raw in list.whereType<Map<String, dynamic>>()) {
        final status = (raw['status'] as String?) ?? 'pending';
        if (status != 'pending') continue;
        final npub = (raw['npub'] as String?) ?? '';
        if (npub.isEmpty) continue;
        final callsign = (raw['callsign'] as String?) ?? '';
        final nickname = (raw['nickname'] as String?) ?? '';
        final message = (raw['message'] as String?) ?? '';
        final label = nickname.isNotEmpty && callsign.isNotEmpty
            ? '$nickname ($callsign)'
            : (callsign.isNotEmpty ? callsign : npub.substring(0, 12));
        EventBus().fire(NowItemEvent(
          id: 'access-request:$eventId:$npub',
          appType: 'event_access_request',
          sourceId: eventId,
          sourceName: eventTitle,
          callsign: label,
          summary: message.isNotEmpty
              ? '"$message"'
              : 'Wants access to "$eventTitle"',
          priority: NowPriority.directMessage,
        ));
        emitted++;
      }
    } catch (e) {
      LogService().log(
        'EventActivityNotifier: access-request parse failed for $eventId: $e',
      );
    }
    return emitted;
  }

  static Future<int> _scanComments({
    required String eventPath,
    required String eventId,
    required String eventTitle,
    required Map<String, String> seen,
  }) async {
    final dir = Directory('$eventPath/feedback/comments');
    if (!await dir.exists()) return 0;
    int emitted = 0;
    try {
      await for (final f in dir.list()) {
        if (f is! File || !f.path.endsWith('.txt')) continue;
        final commentId = f.path.split(Platform.pathSeparator).last
            .replaceAll('.txt', '');
        final notifId = _commentId(eventPath, commentId);
        if (seen.containsKey(notifId)) continue;
        final parsed = await _parseComment(f);
        if (parsed == null) continue;
        if (_isOwnerNpub(parsed.npub)) continue;
        final preview = parsed.content.length > 80
            ? '${parsed.content.substring(0, 80)}…'
            : parsed.content;
        EventBus().fire(NowItemEvent(
          id: 'event-comment:$eventId:$commentId',
          appType: 'event_new_comment',
          sourceId: eventId,
          sourceName: eventTitle,
          callsign:
              parsed.author.isNotEmpty ? parsed.author : 'someone',
          summary: preview.isNotEmpty
              ? preview
              : 'New comment on "$eventTitle"',
          priority: NowPriority.directMessage,
        ));
        emitted++;
      }
    } catch (e) {
      LogService().log(
        'EventActivityNotifier: comment scan failed for $eventId: $e',
      );
    }
    return emitted;
  }

  static Future<int> _scanLikes({
    required String eventPath,
    required String eventId,
    required String eventTitle,
    required Map<String, String> seen,
  }) async {
    final file = File('$eventPath/feedback/likes.txt');
    if (!await file.exists()) return 0;
    int emitted = 0;
    try {
      for (final line in await file.readAsLines()) {
        final npub = line.trim();
        if (npub.isEmpty) continue;
        if (_isOwnerNpub(npub)) continue;
        final notifId = _likeId(eventPath, npub);
        if (seen.containsKey(notifId)) continue;
        EventBus().fire(NowItemEvent(
          id: 'event-like:$eventId:$npub',
          appType: 'event_new_like',
          sourceId: eventId,
          sourceName: eventTitle,
          callsign: npub.length > 12 ? '${npub.substring(0, 12)}…' : npub,
          summary: 'Liked "$eventTitle"',
          priority: NowPriority.directMessage,
        ));
        emitted++;
      }
    } catch (e) {
      LogService().log(
        'EventActivityNotifier: like scan failed for $eventId: $e',
      );
    }
    return emitted;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────

  static String _commentId(String eventPath, String commentId) =>
      'event-comment:$eventPath:$commentId';
  static String _likeId(String eventPath, String npub) =>
      'event-like:$eventPath:$npub';

  static bool _isOwnerNpub(String? npub) {
    if (_ownerNpub.isEmpty) return false;
    if (npub == null || npub.isEmpty) return false;
    return npub == _ownerNpub;
  }

  static Future<bool> _commentBelongsToOwner(File f) async {
    if (_ownerNpub.isEmpty) return false;
    try {
      final parsed = await _parseComment(f);
      return parsed != null && parsed.npub == _ownerNpub;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _readEventTitle(
      String eventPath, String fallback) async {
    try {
      final eventTxt = File('$eventPath/event.txt');
      if (!await eventTxt.exists()) return fallback;
      final parsed =
          Event.fromText(await eventTxt.readAsString(), fallback);
      if (parsed.title.isNotEmpty) return parsed.title;
    } catch (_) {}
    return fallback;
  }

  static Future<Map<String, String>> _loadSeen(String eventPath) async {
    final file = File('$eventPath/feedback/$_seenFileName');
    if (!await file.exists()) return <String, String>{};
    try {
      final content = await file.readAsString();
      if (content.trim().isEmpty) return <String, String>{};
      final raw = jsonDecode(content) as Map<String, dynamic>;
      return raw.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return <String, String>{};
    }
  }

  static Future<void> _saveSeen(
      String eventPath, Map<String, String> seen) async {
    final dir = Directory('$eventPath/feedback');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}/$_seenFileName');
    await file.writeAsString(jsonEncode(seen));
  }

  static Future<_ParsedComment?> _parseComment(File f) async {
    try {
      final content = await f.readAsString();
      String author = '';
      String body = '';
      String? npub;
      var inMeta = true;
      final bodyLines = <String>[];
      for (final line in content.split('\n')) {
        if (inMeta && line.startsWith('AUTHOR: ')) {
          author = line.substring(8).trim();
        } else if (inMeta && line.startsWith('CREATED: ')) {
          // skip — timestamp not needed for the notification body
        } else if (line.startsWith('--> npub: ')) {
          npub = line.substring(10).trim();
        } else if (line.startsWith('--> signature: ')) {
          // skip
        } else if (line.trim().isEmpty && inMeta) {
          inMeta = false;
        } else if (!inMeta) {
          bodyLines.add(line);
        }
      }
      body = bodyLines.join('\n').trim();
      return _ParsedComment(author: author, content: body, npub: npub);
    } catch (_) {
      return null;
    }
  }
}

class _ParsedComment {
  final String author;
  final String content;
  final String? npub;
  _ParsedComment({required this.author, required this.content, this.npub});
}
