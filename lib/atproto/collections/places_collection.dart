/*
 * Places collection adapter for AT Protocol.
 *
 * Maps Geogram Place model to radio.geogram.places.entry records.
 *
 * Lexicon: radio.geogram.places.entry
 * Required: name, latitude, longitude, createdAt
 * Optional: description, altitude, category, image (blob ref)
 */

import '../../models/place.dart';
import '../repo.dart';
import 'collection_adapter.dart';

/// Adapter mapping Place <-> radio.geogram.places.entry AT Proto records.
class PlacesCollection extends CollectionAdapter {
  @override
  String get nsid => 'radio.geogram.places.entry';

  @override
  String get displayName => 'Places';

  /// Provider function to list all places from Geogram storage.
  final Future<List<Place>> Function() listPlaces;

  PlacesCollection({required this.listPlaces});

  /// Convert a Geogram Place to an AT Proto record map.
  static Map<String, dynamic> toRecord(Place place) {
    final record = <String, dynamic>{
      '\$type': 'radio.geogram.places.entry',
      'name': place.name,
      'latitude': place.latitude,
      'longitude': place.longitude,
      'createdAt': place.createdDateTime.toUtc().toIso8601String(),
    };

    if (place.description.isNotEmpty) {
      record['description'] = place.description;
    }
    if (place.type != null && place.type!.isNotEmpty) {
      record['category'] = place.type;
    }
    if (place.radius > 0) {
      record['radius'] = place.radius;
    }
    if (place.address != null && place.address!.isNotEmpty) {
      record['address'] = place.address;
    }
    if (place.names.isNotEmpty) {
      record['names'] = place.names;
    }
    if (place.descriptions.isNotEmpty) {
      record['descriptions'] = place.descriptions;
    }
    if (place.history != null && place.history!.isNotEmpty) {
      record['history'] = place.history;
    }
    if (place.founded != null && place.founded!.isNotEmpty) {
      record['founded'] = place.founded;
    }
    if (place.hours != null && place.hours!.isNotEmpty) {
      record['hours'] = place.hours;
    }
    if (place.visibility != 'private') {
      record['visibility'] = place.visibility;
    }
    if (place.author.isNotEmpty) {
      record['author'] = place.author;
    }

    return record;
  }

  /// Convert an AT Proto record map back to a Place.
  static Place fromRecord(String rkey, Map<String, dynamic> record) {
    final createdAt = record['createdAt'] as String? ?? DateTime.now().toIso8601String();
    final dt = DateTime.tryParse(createdAt) ?? DateTime.now();

    return Place(
      name: record['name'] as String? ?? '',
      names: record['names'] != null
          ? Map<String, String>.from(record['names'] as Map)
          : const {},
      created: '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}_${dt.second.toString().padLeft(2, '0')}',
      author: record['author'] as String? ?? '',
      latitude: (record['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (record['longitude'] as num?)?.toDouble() ?? 0,
      radius: record['radius'] as int? ?? 100,
      address: record['address'] as String?,
      type: record['category'] as String?,
      founded: record['founded'] as String?,
      hours: record['hours'] as String?,
      description: record['description'] as String? ?? '',
      descriptions: record['descriptions'] != null
          ? Map<String, String>.from(record['descriptions'] as Map)
          : const {},
      history: record['history'] as String?,
      visibility: record['visibility'] as String? ?? 'private',
    );
  }

  @override
  Future<int> syncAll(AtprotoRepo repo) async {
    final places = await listPlaces();
    var created = 0;

    for (final place in places) {
      if (place.visibility == 'private') continue; // Only sync public/restricted places

      final rkey = CollectionAdapter.rkeyFromTimestamp(place.created);
      final record = toRecord(place);

      if (createIfAbsent(repo, rkey, record)) {
        created++;
      }
    }

    return created;
  }
}
