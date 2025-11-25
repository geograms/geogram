/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:math';
import 'event.dart';
import 'place.dart';
import 'news_article.dart';
import 'report.dart';
import 'relay.dart';
import 'contact.dart';

/// Types of items that can be displayed on the map
enum MapItemType {
  event,
  place,
  news,
  report,
  relay,
  contact;

  /// Get display name for the type
  String get displayName {
    switch (this) {
      case MapItemType.event:
        return 'Events';
      case MapItemType.place:
        return 'Places';
      case MapItemType.news:
        return 'News';
      case MapItemType.report:
        return 'Reports';
      case MapItemType.relay:
        return 'Relays';
      case MapItemType.contact:
        return 'Contacts';
    }
  }

  /// Get singular display name for the type
  String get singularName {
    switch (this) {
      case MapItemType.event:
        return 'Event';
      case MapItemType.place:
        return 'Place';
      case MapItemType.news:
        return 'News';
      case MapItemType.report:
        return 'Report';
      case MapItemType.relay:
        return 'Relay';
      case MapItemType.contact:
        return 'Contact';
    }
  }
}

/// Unified wrapper for map-displayable items
class MapItem {
  final MapItemType type;
  final String id;
  final String title;
  final String? subtitle;
  final double latitude;
  final double longitude;
  final double? distanceKm;
  final dynamic sourceItem; // Original Event/Place/NewsArticle/Report/Relay/Contact
  final String? collectionPath; // Path to collection folder for opening details

  MapItem({
    required this.type,
    required this.id,
    required this.title,
    this.subtitle,
    required this.latitude,
    required this.longitude,
    this.distanceKm,
    this.sourceItem,
    this.collectionPath,
  });

  /// Create MapItem from an Event
  factory MapItem.fromEvent(Event event, {double? distanceKm, String? collectionPath}) {
    return MapItem(
      type: MapItemType.event,
      id: event.id,
      title: event.title,
      subtitle: event.locationName ?? event.displayDate,
      latitude: event.latitude!,
      longitude: event.longitude!,
      distanceKm: distanceKm,
      sourceItem: event,
      collectionPath: collectionPath,
    );
  }

  /// Create MapItem from a Place
  factory MapItem.fromPlace(Place place, {double? distanceKm, String? collectionPath}) {
    return MapItem(
      type: MapItemType.place,
      id: place.placeFolderName,
      title: place.name,
      subtitle: place.type ?? place.address,
      latitude: place.latitude,
      longitude: place.longitude,
      distanceKm: distanceKm,
      sourceItem: place,
      collectionPath: collectionPath,
    );
  }

  /// Create MapItem from a NewsArticle
  factory MapItem.fromNews(NewsArticle news, {double? distanceKm, String? languageCode, String? collectionPath}) {
    return MapItem(
      type: MapItemType.news,
      id: news.id,
      title: news.getHeadline(languageCode),
      subtitle: news.address ?? news.displayDate,
      latitude: news.latitude!,
      longitude: news.longitude!,
      distanceKm: distanceKm,
      sourceItem: news,
      collectionPath: collectionPath,
    );
  }

  /// Create MapItem from a Report
  factory MapItem.fromReport(Report report, {double? distanceKm, String? languageCode, String? collectionPath}) {
    return MapItem(
      type: MapItemType.report,
      id: report.folderName,
      title: report.getTitle(languageCode ?? 'EN'),
      subtitle: '${report.severity.name} - ${report.status.name}',
      latitude: report.latitude,
      longitude: report.longitude,
      distanceKm: distanceKm,
      sourceItem: report,
      collectionPath: collectionPath,
    );
  }

  /// Create MapItem from a Relay
  factory MapItem.fromRelay(Relay relay, {double? distanceKm}) {
    return MapItem(
      type: MapItemType.relay,
      id: relay.url,
      title: relay.name,
      subtitle: relay.location ?? relay.statusDisplay,
      latitude: relay.latitude!,
      longitude: relay.longitude!,
      distanceKm: distanceKm,
      sourceItem: relay,
    );
  }

  /// Create MapItem from a Contact (using first location with coordinates)
  factory MapItem.fromContact(Contact contact, ContactLocation location, {double? distanceKm, String? collectionPath}) {
    return MapItem(
      type: MapItemType.contact,
      id: '${contact.callsign}_${location.name}',
      title: contact.displayName,
      subtitle: location.name,
      latitude: location.latitude!,
      longitude: location.longitude!,
      distanceKm: distanceKm,
      sourceItem: contact,
      collectionPath: collectionPath,
    );
  }

  /// Calculate distance from given coordinates using Haversine formula
  /// Returns distance in kilometers
  static double calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadiusKm = 6371.0;

    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);

    final a = (sin(dLat / 2) * sin(dLat / 2)) +
        (sin(dLon / 2) * sin(dLon / 2)) *
            cos(_degreesToRadians(lat1)) *
            cos(_degreesToRadians(lat2));

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return earthRadiusKm * c;
  }

  static double _degreesToRadians(double degrees) {
    return degrees * pi / 180;
  }

  /// Get human-readable distance string
  String get distanceString {
    if (distanceKm == null) return '';
    if (distanceKm! < 1) {
      return '${(distanceKm! * 1000).round()} m';
    }
    return '${distanceKm!.toStringAsFixed(1)} km';
  }

  /// Create a copy with updated distance
  MapItem copyWithDistance(double newDistance) {
    return MapItem(
      type: type,
      id: id,
      title: title,
      subtitle: subtitle,
      latitude: latitude,
      longitude: longitude,
      distanceKm: newDistance,
      sourceItem: sourceItem,
      collectionPath: collectionPath,
    );
  }

  @override
  String toString() {
    return 'MapItem(type: ${type.name}, id: $id, title: $title, lat: $latitude, lon: $longitude, distance: ${distanceString})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MapItem && other.type == type && other.id == id;
  }

  @override
  int get hashCode => type.hashCode ^ id.hashCode;
}
