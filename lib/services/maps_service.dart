/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import '../models/map_item.dart';
import '../models/collection.dart';
import 'collection_service.dart';
import 'event_service.dart';
import 'place_service.dart';
import 'news_service.dart';
import 'report_service.dart';
import 'relay_service.dart';
import 'contact_service.dart';
import 'profile_service.dart';
import 'log_service.dart';

/// Service for aggregating and filtering map items from all sources
class MapsService {
  static final MapsService _instance = MapsService._internal();
  factory MapsService() => _instance;
  MapsService._internal();

  // Cache for collections
  List<Collection>? _cachedCollections;
  DateTime? _cacheTimestamp;
  static const Duration _cacheDuration = Duration(minutes: 5);

  /// Get collections with caching
  Future<List<Collection>> _getCollections({bool forceRefresh = false}) async {
    final now = DateTime.now();

    // Return cached collections if valid
    if (!forceRefresh &&
        _cachedCollections != null &&
        _cacheTimestamp != null &&
        now.difference(_cacheTimestamp!) < _cacheDuration) {
      LogService().log('MapsService: Using cached collections (${_cachedCollections!.length} items)');
      return _cachedCollections!;
    }

    // Load fresh collections
    LogService().log('MapsService: Loading fresh collections...');
    _cachedCollections = await CollectionService().loadCollections();
    _cacheTimestamp = now;
    LogService().log('MapsService: Cached ${_cachedCollections!.length} collections');

    return _cachedCollections!;
  }

  /// Clear the collections cache
  void clearCache() {
    _cachedCollections = null;
    _cacheTimestamp = null;
    LogService().log('MapsService: Cache cleared');
  }

  /// Load all map items within a radius from the center point
  /// Returns items sorted by distance
  Future<List<MapItem>> loadAllMapItems({
    required double centerLat,
    required double centerLon,
    double? radiusKm,
    Set<MapItemType>? visibleTypes,
    String? languageCode,
    bool forceRefresh = false,
  }) async {
    final items = <MapItem>[];
    final types = visibleTypes ?? MapItemType.values.toSet();

    LogService().log('MapsService: Loading map items within ${radiusKm ?? "unlimited"} km of ($centerLat, $centerLon)');

    // Load items from each service in parallel
    final futures = <Future<List<MapItem>>>[];

    if (types.contains(MapItemType.event)) {
      futures.add(_loadEvents(centerLat, centerLon, radiusKm, forceRefresh: forceRefresh));
    }
    if (types.contains(MapItemType.place)) {
      futures.add(_loadPlaces(centerLat, centerLon, radiusKm, forceRefresh: forceRefresh));
    }
    if (types.contains(MapItemType.news)) {
      futures.add(_loadNews(centerLat, centerLon, radiusKm, languageCode, forceRefresh: forceRefresh));
    }
    if (types.contains(MapItemType.report)) {
      futures.add(_loadReports(centerLat, centerLon, radiusKm, languageCode, forceRefresh: forceRefresh));
    }
    if (types.contains(MapItemType.relay)) {
      futures.add(_loadRelays(centerLat, centerLon, radiusKm));
    }
    if (types.contains(MapItemType.contact)) {
      futures.add(_loadContacts(centerLat, centerLon, radiusKm, forceRefresh: forceRefresh));
    }

    final results = await Future.wait(futures);
    for (var result in results) {
      items.addAll(result);
    }

    // Sort by distance
    items.sort((a, b) {
      final distA = a.distanceKm ?? double.infinity;
      final distB = b.distanceKm ?? double.infinity;
      return distA.compareTo(distB);
    });

    LogService().log('MapsService: Loaded ${items.length} total map items');
    return items;
  }

  /// Load events with coordinates from all event collections
  Future<List<MapItem>> _loadEvents(
    double centerLat,
    double centerLon,
    double? radiusKm, {
    bool forceRefresh = false,
  }) async {
    final items = <MapItem>[];

    try {
      // Get all collections and filter for events type
      final collections = await _getCollections(forceRefresh: forceRefresh);
      final eventCollections = collections.where((c) => c.type == 'events').toList();

      LogService().log('MapsService: Found ${eventCollections.length} event collections');

      for (var collection in eventCollections) {
        if (collection.storagePath == null) continue;

        try {
          final eventService = EventService();
          await eventService.initializeCollection(collection.storagePath!);

          final events = await eventService.loadEvents();

          for (var event in events) {
            if (!event.hasCoordinates) continue;

            final distance = MapItem.calculateDistance(
              centerLat,
              centerLon,
              event.latitude!,
              event.longitude!,
            );

            if (radiusKm != null && distance > radiusKm) continue;

            items.add(MapItem.fromEvent(event, distanceKm: distance, collectionPath: collection.storagePath));
          }

          LogService().log('MapsService: Loaded ${events.length} events from ${collection.title}');
        } catch (e) {
          LogService().log('MapsService: Error loading events from ${collection.title}: $e');
        }
      }

      LogService().log('MapsService: Found ${items.length} total events with coordinates');
    } catch (e) {
      LogService().log('MapsService: Error loading events: $e');
    }

    return items;
  }

  /// Load places from all places collections
  Future<List<MapItem>> _loadPlaces(
    double centerLat,
    double centerLon,
    double? radiusKm, {
    bool forceRefresh = false,
  }) async {
    final items = <MapItem>[];

    try {
      // Get all collections and filter for places type
      final collections = await _getCollections(forceRefresh: forceRefresh);
      final placeCollections = collections.where((c) => c.type == 'places').toList();

      LogService().log('MapsService: Found ${placeCollections.length} place collections');

      for (var collection in placeCollections) {
        if (collection.storagePath == null) continue;

        try {
          final placeService = PlaceService();
          await placeService.initializeCollection(collection.storagePath!);

          final places = await placeService.loadAllPlaces();

          for (var place in places) {
            final distance = MapItem.calculateDistance(
              centerLat,
              centerLon,
              place.latitude,
              place.longitude,
            );

            if (radiusKm != null && distance > radiusKm) continue;

            items.add(MapItem.fromPlace(place, distanceKm: distance, collectionPath: collection.storagePath));
          }

          LogService().log('MapsService: Loaded ${places.length} places from ${collection.title}');
        } catch (e) {
          LogService().log('MapsService: Error loading places from ${collection.title}: $e');
        }
      }

      LogService().log('MapsService: Found ${items.length} total places');
    } catch (e) {
      LogService().log('MapsService: Error loading places: $e');
    }

    return items;
  }

  /// Load news articles with location from all news collections
  Future<List<MapItem>> _loadNews(
    double centerLat,
    double centerLon,
    double? radiusKm,
    String? languageCode, {
    bool forceRefresh = false,
  }) async {
    final items = <MapItem>[];

    try {
      // Get all collections and filter for news type
      final collections = await _getCollections(forceRefresh: forceRefresh);
      final newsCollections = collections.where((c) => c.type == 'news').toList();

      LogService().log('MapsService: Found ${newsCollections.length} news collections');

      for (var collection in newsCollections) {
        if (collection.storagePath == null) continue;

        try {
          final newsService = NewsService();
          await newsService.initializeCollection(collection.storagePath!);

          final articles = await newsService.loadArticles(includeExpired: false);

          for (var article in articles) {
            if (!article.hasLocation) continue;

            final distance = MapItem.calculateDistance(
              centerLat,
              centerLon,
              article.latitude!,
              article.longitude!,
            );

            if (radiusKm != null && distance > radiusKm) continue;

            items.add(MapItem.fromNews(article, distanceKm: distance, languageCode: languageCode, collectionPath: collection.storagePath));
          }

          LogService().log('MapsService: Loaded ${articles.length} news from ${collection.title}');
        } catch (e) {
          LogService().log('MapsService: Error loading news from ${collection.title}: $e');
        }
      }

      LogService().log('MapsService: Found ${items.length} total news with location');
    } catch (e) {
      LogService().log('MapsService: Error loading news: $e');
    }

    return items;
  }

  /// Load reports from all report collections
  Future<List<MapItem>> _loadReports(
    double centerLat,
    double centerLon,
    double? radiusKm,
    String? languageCode, {
    bool forceRefresh = false,
  }) async {
    final items = <MapItem>[];

    try {
      // Get all collections and filter for report type
      final collections = await _getCollections(forceRefresh: forceRefresh);
      final reportCollections = collections.where((c) => c.type == 'report').toList();

      LogService().log('MapsService: Found ${reportCollections.length} report collections');

      for (var collection in reportCollections) {
        if (collection.storagePath == null) continue;

        try {
          // Initialize ReportService for this collection
          final reportService = ReportService();
          await reportService.initializeCollection(collection.storagePath!);

          final reports = await reportService.loadReports(includeExpired: false);

          for (var report in reports) {
            final distance = MapItem.calculateDistance(
              centerLat,
              centerLon,
              report.latitude,
              report.longitude,
            );

            if (radiusKm != null && distance > radiusKm) continue;

            items.add(MapItem.fromReport(report, distanceKm: distance, languageCode: languageCode, collectionPath: collection.storagePath));
          }

          LogService().log('MapsService: Loaded ${reports.length} reports from ${collection.title}');
        } catch (e) {
          LogService().log('MapsService: Error loading reports from ${collection.title}: $e');
        }
      }

      LogService().log('MapsService: Found ${items.length} total reports');
    } catch (e) {
      LogService().log('MapsService: Error loading reports: $e');
    }

    return items;
  }

  /// Load relays with location
  Future<List<MapItem>> _loadRelays(
    double centerLat,
    double centerLon,
    double? radiusKm,
  ) async {
    final items = <MapItem>[];

    try {
      final relays = RelayService().getAllRelays();

      for (var relay in relays) {
        if (relay.latitude == null || relay.longitude == null) continue;

        final distance = MapItem.calculateDistance(
          centerLat,
          centerLon,
          relay.latitude!,
          relay.longitude!,
        );

        if (radiusKm != null && distance > radiusKm) continue;

        items.add(MapItem.fromRelay(relay, distanceKm: distance));
      }

      LogService().log('MapsService: Found ${items.length} relays with location');
    } catch (e) {
      LogService().log('MapsService: Error loading relays: $e');
    }

    return items;
  }

  /// Load contacts with location from all contacts collections
  Future<List<MapItem>> _loadContacts(
    double centerLat,
    double centerLon,
    double? radiusKm, {
    bool forceRefresh = false,
  }) async {
    final items = <MapItem>[];

    try {
      // Get all collections and filter for contacts type
      final collections = await _getCollections(forceRefresh: forceRefresh);
      final contactCollections = collections.where((c) => c.type == 'contacts').toList();

      LogService().log('MapsService: Found ${contactCollections.length} contact collections');

      for (var collection in contactCollections) {
        if (collection.storagePath == null) continue;

        try {
          final contactService = ContactService();
          await contactService.initializeCollection(collection.storagePath!);

          final contacts = await contactService.loadAllContactsRecursively();

          for (var contact in contacts) {
            // Each contact can have multiple locations
            for (var location in contact.locations) {
              if (location.latitude == null || location.longitude == null) continue;

              final distance = MapItem.calculateDistance(
                centerLat,
                centerLon,
                location.latitude!,
                location.longitude!,
              );

              if (radiusKm != null && distance > radiusKm) continue;

              items.add(MapItem.fromContact(contact, location, distanceKm: distance, collectionPath: collection.storagePath));
            }
          }

          LogService().log('MapsService: Loaded ${contacts.length} contacts from ${collection.title}');
        } catch (e) {
          LogService().log('MapsService: Error loading contacts from ${collection.title}: $e');
        }
      }

      LogService().log('MapsService: Found ${items.length} total contact locations');
    } catch (e) {
      LogService().log('MapsService: Error loading contacts: $e');
    }

    return items;
  }

  /// Get user's saved location from profile
  /// Returns (latitude, longitude) or null if not set
  (double, double)? getUserLocation() {
    try {
      final profile = ProfileService().getProfile();
      if (profile.latitude != null && profile.longitude != null) {
        return (profile.latitude!, profile.longitude!);
      }
    } catch (e) {
      LogService().log('MapsService: Error getting user location: $e');
    }
    return null;
  }

  /// Group items by type, sorted by count (non-empty first)
  Map<MapItemType, List<MapItem>> groupByType(List<MapItem> items) {
    final grouped = <MapItemType, List<MapItem>>{};

    for (var type in MapItemType.values) {
      grouped[type] = items.where((item) => item.type == type).toList();
    }

    return grouped;
  }

  /// Get types sorted by item count (non-empty first, then by count descending)
  List<MapItemType> getTypesSortedByCount(Map<MapItemType, List<MapItem>> grouped) {
    final types = MapItemType.values.toList();
    types.sort((a, b) {
      final countA = grouped[a]?.length ?? 0;
      final countB = grouped[b]?.length ?? 0;
      // Sort by count descending (non-empty first)
      return countB.compareTo(countA);
    });
    return types;
  }

  /// Filter items by radius
  List<MapItem> filterByRadius(
    List<MapItem> items,
    double centerLat,
    double centerLon,
    double radiusKm,
  ) {
    return items.where((item) {
      final distance = MapItem.calculateDistance(
        centerLat,
        centerLon,
        item.latitude,
        item.longitude,
      );
      return distance <= radiusKm;
    }).map((item) {
      // Update distance if needed
      final distance = MapItem.calculateDistance(
        centerLat,
        centerLon,
        item.latitude,
        item.longitude,
      );
      return item.copyWithDistance(distance);
    }).toList();
  }
}
