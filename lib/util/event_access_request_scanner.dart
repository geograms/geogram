/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';

import '../models/event.dart';
import '../services/log_service.dart';
import 'event_bus.dart';

/// Re-emits NowItemEvents for every pending access request still on disk.
///
/// NowService is in-memory only, so a desktop restart loses any
/// notifications that were posted in the previous session. The events
/// browser already calls this on its own load, but the apps grid (and
/// the Now drawer badge) ought to know about pending requests *before*
/// the user opens the events tab. This util walks the on-disk events
/// folder directly so it can run from app startup without needing
/// EventService to be initialised yet.
class EventAccessRequestScanner {
  EventAccessRequestScanner._();

  /// Walks `{eventsAppPath}/{year}/{eventId}/feedback/access_requests.json`
  /// and fires a [NowItemEvent] for every entry whose status is
  /// "pending" (or unset). NowService dedupes by id so repeated calls
  /// are safe.
  static Future<int> republishPending(String eventsAppPath) async {
    if (eventsAppPath.isEmpty) return 0;
    final root = Directory(eventsAppPath);
    if (!await root.exists()) return 0;

    var emitted = 0;
    try {
      await for (final yearEntry in root.list()) {
        if (yearEntry is! Directory) continue;
        // Year folders are always 4-digit numbers; skip anything else
        // (e.g. accidental dotfiles) so we don't try to read them.
        final yearName = yearEntry.path.split(Platform.pathSeparator).last;
        if (yearName.length != 4 || int.tryParse(yearName) == null) continue;

        await for (final eventEntry in yearEntry.list()) {
          if (eventEntry is! Directory) continue;
          final eventId = eventEntry.path.split(Platform.pathSeparator).last;
          final requestsFile =
              File('${eventEntry.path}/feedback/access_requests.json');
          if (!await requestsFile.exists()) continue;

          // Load the event's title so the Now card has something
          // human-readable.
          String title = eventId;
          try {
            final eventTxt = File('${eventEntry.path}/event.txt');
            if (await eventTxt.exists()) {
              final parsed =
                  Event.fromText(await eventTxt.readAsString(), eventId);
              if (parsed.title.isNotEmpty) title = parsed.title;
            }
          } catch (_) {}

          try {
            final content = await requestsFile.readAsString();
            if (content.trim().isEmpty) continue;
            final list = jsonDecode(content) as List<dynamic>;
            for (final raw in list.whereType<Map<String, dynamic>>()) {
              final status = (raw['status'] as String?) ?? 'pending';
              if (status != 'pending') continue;
              final npub = (raw['npub'] as String?) ?? '';
              if (npub.isEmpty) continue;
              final callsign = (raw['callsign'] as String?) ?? '';
              final message = (raw['message'] as String?) ?? '';
              EventBus().fire(NowItemEvent(
                id: 'access-request:$eventId:$npub',
                appType: 'event_access_request',
                sourceId: eventId,
                sourceName: title,
                callsign: callsign.isNotEmpty
                    ? callsign
                    : npub.substring(0, 12),
                summary: message.isNotEmpty
                    ? '"$message"'
                    : 'Wants access to "$title"',
                priority: NowPriority.directMessage,
              ));
              emitted++;
            }
          } catch (e) {
            // Corrupted request file — skip but log so it's discoverable.
            LogService().log(
              'EventAccessRequestScanner: failed to parse $requestsFile: $e',
            );
          }
        }
      }
    } catch (e) {
      LogService().log('EventAccessRequestScanner: walk failed: $e');
    }
    return emitted;
  }
}
