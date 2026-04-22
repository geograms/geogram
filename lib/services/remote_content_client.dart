/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Typed wrapper over the generic /api/content/{appType}/… surface.
 * Everything routes through DevicesService.makeDeviceApiRequest so
 * ConnectionManager picks the transport (LAN / USB / BLE / WebRTC /
 * DHT / Peer Relay / Station) automatically. Every per-app remote
 * page uses this instead of hand-rolling URL strings — new app
 * types plug in for free.
 */

import 'dart:convert';

import 'devices_service.dart';

/// Result of a list / detail call. [data] is the parsed map when
/// the server replied with JSON; [error] / [statusCode] describe
/// the failure otherwise.
class RemoteContentResponse {
  final bool success;
  final int? statusCode;
  final String? error;
  final Map<String, dynamic>? data;

  const RemoteContentResponse({
    required this.success,
    this.statusCode,
    this.error,
    this.data,
  });

  Map<String, dynamic> toJson() => {
        'success': success,
        if (statusCode != null) 'status_code': statusCode,
        if (error != null) 'error': error,
        if (data != null) 'data': data,
      };
}

/// One item returned by [RemoteContent.listAcrossDevices], tagged
/// with the device callsign that served it. Lets the UI dedupe
/// (same item id served by mirrored devices) and attribute.
class RemoteContentItem {
  final String sourceCallsign;
  final Map<String, dynamic> item;
  const RemoteContentItem({
    required this.sourceCallsign,
    required this.item,
  });
}

class RemoteContent {
  RemoteContent._();

  /// Enumerate the app types the remote device exposes.
  /// `GET /api/content` → `{apps: [{appType,title,count}, …]}`.
  static Future<RemoteContentResponse> listApps(
      String remoteCallsign) async {
    return _get(remoteCallsign, '/api/content');
  }

  /// List items in an app.
  /// `GET /api/content/{appType}` with optional query (year, limit,
  /// offset, tag, …). Returns `{items: [...], count}`.
  static Future<RemoteContentResponse> list({
    required String remoteCallsign,
    required String appType,
    Map<String, String>? query,
  }) async {
    var path = '/api/content/${Uri.encodeComponent(appType)}';
    if (query != null && query.isNotEmpty) {
      path = '$path?${Uri(queryParameters: query).query}';
    }
    return _get(remoteCallsign, path);
  }

  /// Detail for one item.
  /// `GET /api/content/{appType}/{itemId}` — provider-shaped payload.
  static Future<RemoteContentResponse> get({
    required String remoteCallsign,
    required String appType,
    required String itemId,
  }) async {
    final path = '/api/content/${Uri.encodeComponent(appType)}/'
        '${Uri.encodeComponent(itemId)}';
    return _get(remoteCallsign, path);
  }

  /// Request path (relative) the UI can hand to an Image/Video
  /// network loader — kept here so every app builds the same URL.
  static String filePath({
    required String appType,
    required String itemId,
    required String relativePath,
  }) =>
      '/api/content/${Uri.encodeComponent(appType)}/'
      '${Uri.encodeComponent(itemId)}/files/$relativePath';

  /// Fan-out helper: ask every callsign in [callsigns] for its
  /// `appType` items in parallel, return the merged + de-duplicated
  /// list with each item tagged by the source callsign.
  ///
  /// Dedupe is by (callsign, item id) — a callsign mirroring its
  /// own data across multiple physical devices still produces one
  /// row per item per callsign. Items without an `id` field skip
  /// dedupe and keep all copies (so non-keyed payloads aren\'t
  /// silently dropped).
  ///
  /// Failures from individual devices are silently ignored — they
  /// just contribute zero items. The caller can\'t distinguish "no
  /// items" from "device offline" here; that\'s by design for the
  /// aggregated view (a separate per-device call surfaces errors).
  static Future<List<RemoteContentItem>> listAcrossDevices({
    required Iterable<String> callsigns,
    required String appType,
    Map<String, String>? query,
  }) async {
    final results = await Future.wait(
      callsigns.map((cs) async {
        try {
          final r = await list(
            remoteCallsign: cs,
            appType: appType,
            query: query,
          );
          if (!r.success || r.data == null) return <RemoteContentItem>[];
          final items = r.data!['items'];
          if (items is! List) return <RemoteContentItem>[];
          return items
              .whereType<Map<String, dynamic>>()
              .map((m) => RemoteContentItem(sourceCallsign: cs, item: m))
              .toList();
        } catch (_) {
          return <RemoteContentItem>[];
        }
      }),
      eagerError: false,
    );
    final out = <RemoteContentItem>[];
    final seen = <String>{};
    for (final batch in results) {
      for (final r in batch) {
        final id = r.item['id'];
        if (id is String && id.isNotEmpty) {
          final dedupKey = '${r.sourceCallsign}|$id';
          if (!seen.add(dedupKey)) continue;
        }
        out.add(r);
      }
    }
    return out;
  }

  // ──────────────────────────────────────────────────────────────

  static Future<RemoteContentResponse> _get(
      String remoteCallsign, String path) async {
    try {
      final resp = await DevicesService().makeDeviceApiRequest(
        callsign: remoteCallsign,
        method: 'GET',
        path: path,
      );
      if (resp == null) {
        return const RemoteContentResponse(
          success: false, error: 'No response from device');
      }
      Map<String, dynamic>? data;
      try {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {}
      final ok = resp.statusCode >= 200 && resp.statusCode < 300;
      return RemoteContentResponse(
        success: ok,
        statusCode: resp.statusCode,
        data: data,
        error: ok
            ? null
            : (data?['error'] as String?) ??
                'HTTP ${resp.statusCode}',
      );
    } catch (e) {
      return RemoteContentResponse(success: false, error: e.toString());
    }
  }
}
