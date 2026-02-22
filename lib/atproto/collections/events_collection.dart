/*
 * Events collection adapter for AT Protocol.
 *
 * Maps Geogram Event model to radio.geogram.events.entry records.
 *
 * Lexicon: radio.geogram.events.entry
 * Required: title, location, createdAt
 * Optional: content, startDate, endDate, locationName, agenda, visibility
 */

import '../../models/event.dart';
import '../repo.dart';
import 'collection_adapter.dart';

/// Adapter mapping Event <-> radio.geogram.events.entry AT Proto records.
class EventsCollection extends CollectionAdapter {
  @override
  String get nsid => 'radio.geogram.events.entry';

  @override
  String get displayName => 'Events';

  /// Provider function to list all events from Geogram storage.
  final Future<List<Event>> Function() listEvents;

  EventsCollection({required this.listEvents});

  /// Convert a Geogram Event to an AT Proto record map.
  static Map<String, dynamic> toRecord(Event event) {
    final record = <String, dynamic>{
      '\$type': 'radio.geogram.events.entry',
      'title': event.title,
      'location': event.location,
      'createdAt': event.dateTime.toUtc().toIso8601String(),
    };

    if (event.content.isNotEmpty) {
      record['content'] = event.content;
    }
    if (event.startDate != null) {
      record['startDate'] = event.startDate;
    }
    if (event.endDate != null) {
      record['endDate'] = event.endDate;
    }
    if (event.locationName != null && event.locationName!.isNotEmpty) {
      record['locationName'] = event.locationName;
    }
    if (event.agenda != null && event.agenda!.isNotEmpty) {
      record['agenda'] = event.agenda;
    }
    if (event.visibility != 'public') {
      record['visibility'] = event.visibility;
    }
    if (event.hasCoordinates) {
      record['latitude'] = event.latitude;
      record['longitude'] = event.longitude;
    }
    if (event.contacts.isNotEmpty) {
      record['contacts'] = event.contacts;
    }
    if (event.author.isNotEmpty) {
      record['author'] = event.author;
    }

    return record;
  }

  /// Convert an AT Proto record map back to an Event.
  static Event fromRecord(String rkey, Map<String, dynamic> record) {
    final createdAt = record['createdAt'] as String? ?? DateTime.now().toIso8601String();
    final dt = DateTime.tryParse(createdAt) ?? DateTime.now();

    // Reconstruct location string
    String location;
    if (record['location'] != null) {
      location = record['location'] as String;
    } else if (record['latitude'] != null && record['longitude'] != null) {
      location = '${record['latitude']},${record['longitude']}';
    } else {
      location = 'online';
    }

    return Event(
      id: rkey,
      author: record['author'] as String? ?? '',
      timestamp: '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}_${dt.second.toString().padLeft(2, '0')}',
      title: record['title'] as String? ?? '',
      startDate: record['startDate'] as String?,
      endDate: record['endDate'] as String?,
      location: location,
      locationName: record['locationName'] as String?,
      content: record['content'] as String? ?? '',
      agenda: record['agenda'] as String?,
      visibility: record['visibility'] as String? ?? 'public',
      contacts: (record['contacts'] as List?)?.cast<String>() ?? [],
    );
  }

  @override
  Future<int> syncAll(AtprotoRepo repo) async {
    final events = await listEvents();
    var created = 0;

    for (final event in events) {
      if (event.visibility == 'private') continue; // Only sync public/group events

      final rkey = CollectionAdapter.rkeyFromTimestamp(event.timestamp);
      final record = toRecord(event);

      if (createIfAbsent(repo, rkey, record)) {
        created++;
      }
    }

    return created;
  }
}
