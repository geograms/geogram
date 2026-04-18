// Homepage mixin for station servers
// Provides shared homepage content generation (e.g. recent blog posts).
//
// Cache strategy: when a device finishes its WebSocket handshake, the station
// asks it for /api/blog?limit=N via the existing proxy and caches the result
// keyed by callsign. The homepage merges this in-memory cache with anything
// already on disk (mirrored devices), so blog posts appear even when no
// mirror is configured. Cache evicts when the last connection for a callsign
// goes away.

import 'dart:async';
import 'dart:convert';

import 'blog_handler_mixin.dart';
import 'device_proxy_mixin.dart';
import '../../util/station_html_templates.dart';

mixin HomepageMixin {
  /// Devices directory path, used by the disk scanner.
  String get homepageDevicesDir;

  /// Per-callsign cache of recent blog posts. Stations expose their own field
  /// via this getter so the mixin can manage entries without owning state.
  Map<String, List<RecentBlogEntry>> get homepageBlogCache;

  /// Send an HTTP_REQUEST to a connected device. Stations forward to
  /// DeviceProxyMixin.proxySingleDevice() (already mixed into both stations).
  Future<Map<String, dynamic>?> homepageProxyToClient(
      DeviceProxyClient client, String method, String path);

  /// Log helper.
  void homepageLog(String level, String message);

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
    );
  }
}
