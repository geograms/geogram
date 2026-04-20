// Homepage mixin for station servers
// Provides shared homepage content generation (e.g. recent blog posts and
// recent events).
//
// Cache strategy: when a device finishes its WebSocket handshake, the station
// asks it for /api/blog?limit=N AND /api/events?limit=N via the existing proxy
// and caches the result keyed by callsign. The homepage merges this in-memory
// cache with anything already on disk (mirrored devices), so posts appear
// even when no mirror is configured. Cache evicts when the last connection
// for a callsign goes away. A periodic refresh re-primes every connected
// device hourly so counts (likes, etc.) don't get frozen for long-lived
// connections.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/event.dart';
import 'blog_handler_mixin.dart';
import 'device_proxy_mixin.dart';
import '../../util/station_html_templates.dart';

/// Lightweight event summary for the station homepage feed.
///
/// Mirrors [RecentBlogEntry] in shape so the template renders both with
/// the same look. `slug` is preferred for the URL; falls back to the
/// folder id.
class RecentEventEntry {
  final String callsign;
  final String eventId;
  final String? slug;
  final String title;
  final String author;
  final String? location;
  final String displayDate;
  final DateTime dateTime;
  final String visibility;

  RecentEventEntry({
    required this.callsign,
    required this.eventId,
    this.slug,
    required this.title,
    required this.author,
    this.location,
    required this.displayDate,
    required this.dateTime,
    required this.visibility,
  });
}

mixin HomepageMixin {
  /// Devices directory path, used by the disk scanner.
  String get homepageDevicesDir;

  /// Per-callsign cache of recent blog posts. Stations expose their own field
  /// via this getter so the mixin can manage entries without owning state.
  Map<String, List<RecentBlogEntry>> get homepageBlogCache;

  /// Per-callsign cache of recent events (parallel to homepageBlogCache).
  Map<String, List<RecentEventEntry>> get homepageEventCache;

  /// Send an HTTP_REQUEST to a connected device. Stations forward to
  /// DeviceProxyMixin.proxySingleDevice() (already mixed into both stations).
  Future<Map<String, dynamic>?> homepageProxyToClient(
      DeviceProxyClient client, String method, String path);

  /// Log helper.
  void homepageLog(String level, String message);

  /// All currently-connected proxy clients. Used by the periodic refresh to
  /// iterate every device. Stations expose their own clients map.
  Iterable<DeviceProxyClient> get homepageConnectedClients;

  // Periodic re-prime so cached likes/counters don't go stale on long
  // connections. One hour is the agreed cadence — fast enough that user-
  // visible counts stay reasonable, slow enough to be a non-event load-wise.
  Timer? _blogCacheRefreshTimer;
  static const Duration _blogCacheRefreshInterval = Duration(hours: 1);

  /// Start the periodic blog cache refresh. Idempotent — safe to call again.
  void startHomepageRefresh() {
    _blogCacheRefreshTimer?.cancel();
    _blogCacheRefreshTimer =
        Timer.periodic(_blogCacheRefreshInterval, (_) => _refreshAllCaches());
  }

  /// Stop the periodic refresh. Call from station shutdown.
  void stopHomepageRefresh() {
    _blogCacheRefreshTimer?.cancel();
    _blogCacheRefreshTimer = null;
  }

  Future<void> _refreshAllCaches() async {
    final clients = homepageConnectedClients
        .where((c) => c.callsign != null)
        .toList(growable: false);
    if (clients.isEmpty) return;
    homepageLog('INFO',
        'Refreshing blog + event cache for ${clients.length} device(s)');
    for (final client in clients) {
      // Sequential — avoids hammering devices and our own proxy queue all
      // at once. Per-device proxy already has a 30s timeout.
      await primeBlogCacheForDevice(client);
      await primeEventCacheForDevice(client);
    }
  }

  /// Fire-and-forget: ask a freshly-connected device for its recent posts and
  /// cache them. Called from the station after hello_ack succeeds.
  Future<void> primeBlogCacheForDevice(DeviceProxyClient client) async {
    final callsign = client.callsign;
    if (callsign == null) return;
    try {
      final resp = await homepageProxyToClient(
          client, 'GET', '/api/blog?limit=10');
      if (resp == null) return;
      final status = resp['statusCode'] as int? ?? 0;
      if (status < 200 || status >= 300) return;
      final body = resp['responseBody'] as String? ?? '';
      if (body.isEmpty) return;
      final json = jsonDecode(body) as Map<String, dynamic>;
      final posts = (json['posts'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((p) => _entryFromApiPost(callsign, p))
          .whereType<RecentBlogEntry>()
          .toList();
      homepageBlogCache[callsign] = posts;
      homepageLog('INFO',
          'Cached ${posts.length} recent blog posts for $callsign');
    } catch (e) {
      homepageLog('WARN', 'Blog cache prime failed for $callsign: $e');
    }
  }

  /// Drop cache for a callsign. Stations call this from _removeClient when
  /// the LAST connection for that callsign disconnects (multi-device aware).
  void evictBlogCacheForCallsign(String callsign) {
    homepageBlogCache.remove(callsign);
  }

  /// Fire-and-forget: ask a freshly-connected device for its recent events
  /// and cache them. Mirrors the blog flow.
  Future<void> primeEventCacheForDevice(DeviceProxyClient client) async {
    final callsign = client.callsign;
    if (callsign == null) return;
    try {
      final resp = await homepageProxyToClient(
          client, 'GET', '/api/events?limit=10');
      if (resp == null) return;
      final status = resp['statusCode'] as int? ?? 0;
      if (status < 200 || status >= 300) return;
      final body = resp['responseBody'] as String? ?? '';
      if (body.isEmpty) return;
      final json = jsonDecode(body) as Map<String, dynamic>;
      final events = (json['events'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((e) => _eventEntryFromApi(callsign, e))
          .whereType<RecentEventEntry>()
          .where(_isPublishableVisibility)
          .toList();
      homepageEventCache[callsign] = events;
      homepageLog(
          'INFO', 'Cached ${events.length} recent events for $callsign');
    } catch (e) {
      homepageLog('WARN', 'Event cache prime failed for $callsign: $e');
    }
  }

  void evictEventCacheForCallsign(String callsign) {
    homepageEventCache.remove(callsign);
  }

  /// Build the recent events HTML section for the station homepage.
  /// Merges the live cache with disk-scanned mirrored content. Only
  /// `public` and `request_access` events are surfaced (the in-memory
  /// cache and the disk scanner both pre-filter, but enforce here too
  /// in case downstream callers add more fields).
  Future<String> buildRecentEventsSection({int limit = 10}) async {
    final cached = homepageEventCache.values.expand((e) => e).toList();
    final fromDisk = await scanRecentEvents(homepageDevicesDir, limit: limit);
    final seen = <String>{};
    final merged = <RecentEventEntry>[];
    for (final e in [...cached, ...fromDisk]) {
      if (!_isPublishableVisibility(e)) continue;
      final key = '${e.callsign}/${e.eventId}';
      if (seen.add(key)) merged.add(e);
    }
    merged.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    final top = merged.length > limit ? merged.sublist(0, limit) : merged;
    return StationHtmlTemplates.buildRecentEventsHtml(top);
  }

  bool _isPublishableVisibility(RecentEventEntry e) =>
      e.visibility == 'public' || e.visibility == 'request_access';

  /// Build the recent blog posts HTML section for the station homepage.
  /// Merges the live cache with disk-scanned mirrored content.
  Future<String> buildRecentBlogsSection({int limit = 10}) async {
    final cached = homepageBlogCache.values.expand((e) => e).toList();
    final fromDisk = await BlogHandlerMixin.scanRecentBlogPosts(
        homepageDevicesDir, limit: limit);
    final seen = <String>{};
    final merged = <RecentBlogEntry>[];
    for (final e in [...cached, ...fromDisk]) {
      final key = '${e.callsign}/${e.postId}';
      if (seen.add(key)) merged.add(e);
    }
    merged.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    final top = merged.length > limit ? merged.sublist(0, limit) : merged;
    return StationHtmlTemplates.buildRecentBlogPostsHtml(top);
  }

  /// Convert a /api/events list JSON object into a RecentEventEntry.
  /// Returns null when the timestamp is missing or unparseable.
  RecentEventEntry? _eventEntryFromApi(
      String callsign, Map<String, dynamic> e) {
    final id = e['id'] as String?;
    final title = e['title'] as String?;
    final timestamp = e['timestamp'] as String?;
    if (id == null || title == null || timestamp == null) return null;
    DateTime dt;
    try {
      dt = DateTime.parse(timestamp.replaceAll('_', ':'));
    } catch (_) {
      return null;
    }
    final author = (e['author'] as String?)?.trim();
    final locationName = e['location_name'] as String?;
    final location = (e['location'] as String?)?.trim();
    final visibility = (e['visibility'] as String?) ?? 'public';
    final slug = e['slug'] as String?;
    final displayDate =
        '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    return RecentEventEntry(
      callsign: callsign,
      eventId: id,
      slug: slug,
      title: title,
      author: (author != null && author.isNotEmpty) ? author : callsign,
      location: locationName != null && locationName.isNotEmpty
          ? locationName
          : (location != null && location.isNotEmpty ? location : null),
      displayDate: displayDate,
      dateTime: dt,
      visibility: visibility,
    );
  }

  /// Walk the on-disk devices/{callsign}/{events_app}/{year}/{eventId}/
  /// tree and build a list of recent publishable events. Used as a
  /// fallback for callsigns that aren't currently connected — covers
  /// the mirrored-events case the same way scanRecentBlogPosts does.
  static Future<List<RecentEventEntry>> scanRecentEvents(
    String devicesDir, {
    int limit = 10,
  }) async {
    final dir = Directory(devicesDir);
    if (!await dir.exists()) return [];

    final all = <RecentEventEntry>[];
    await for (final callsignEntity in dir.list()) {
      if (callsignEntity is! Directory) continue;
      final callsign =
          callsignEntity.path.split(Platform.pathSeparator).last;

      try {
        await for (final collectionEntity in callsignEntity.list()) {
          if (collectionEntity is! Directory) continue;
          // The events app's storage dir is conventionally named
          // "events"; fall back to scanning every directory that has
          // year subfolders so non-default install layouts still work.
          final collectionName =
              collectionEntity.path.split(Platform.pathSeparator).last;
          if (collectionName != 'events') continue;

          await for (final yearEntity in collectionEntity.list()) {
            if (yearEntity is! Directory) continue;
            final yearName =
                yearEntity.path.split(Platform.pathSeparator).last;
            if (!RegExp(r'^\d{4}$').hasMatch(yearName)) continue;

            await for (final eventEntity in yearEntity.list()) {
              if (eventEntity is! Directory) continue;
              final eventId =
                  eventEntity.path.split(Platform.pathSeparator).last;
              final eventFile = File('${eventEntity.path}/event.txt');
              if (!await eventFile.exists()) continue;
              try {
                final content = await eventFile.readAsString();
                final ev = Event.fromText(content, eventId);
                if (ev.visibility != 'public' &&
                    ev.visibility != 'request_access') {
                  continue;
                }
                all.add(RecentEventEntry(
                  callsign: callsign,
                  eventId: eventId,
                  slug: ev.slug,
                  title: ev.title,
                  author: ev.author.isNotEmpty ? ev.author : callsign,
                  location: ev.locationName != null && ev.locationName!.isNotEmpty
                      ? ev.locationName
                      : ev.location,
                  displayDate: ev.displayDate,
                  dateTime: ev.dateTime,
                  visibility: ev.visibility,
                ));
              } catch (_) {
                // Skip malformed event.txt
              }
            }
          }
        }
      } catch (_) {}
    }

    all.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    return all.length > limit ? all.sublist(0, limit) : all;
  }

  /// Convert a /api/blog post JSON object into a RecentBlogEntry.
  /// Returns null when the timestamp is missing or unparseable.
  RecentBlogEntry? _entryFromApiPost(
      String callsign, Map<String, dynamic> p) {
    final id = p['id'] as String?;
    final title = p['title'] as String?;
    final timestamp = p['timestamp'] as String?;
    if (id == null || title == null || timestamp == null) return null;
    DateTime dt;
    try {
      dt = DateTime.parse(timestamp.replaceAll('_', ':'));
    } catch (_) {
      return null;
    }
    final author = (p['author'] as String?)?.trim();
    final description = p['description'] as String?;
    final likes = (p['likes_count'] as num?)?.toInt() ?? 0;
    final displayDate =
        '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    return RecentBlogEntry(
      callsign: callsign,
      postId: id,
      title: title,
      author: (author != null && author.isNotEmpty) ? author : callsign,
      description: (description != null && description.isNotEmpty) ? description : null,
      displayDate: displayDate,
      dateTime: dt,
      likesCount: likes,
    );
  }
}
