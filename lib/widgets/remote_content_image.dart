/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Image widget that fetches bytes from a remote device through the
 * generic /api/content/{appType}/{itemId}/files/{path} endpoint.
 * Routed through DevicesService.makeDeviceApiRequest so every
 * transport ConnectionManager supports (LAN / USB / BLE / WebRTC /
 * Peer Relay / Station / DHT) works the same way — NetworkImage
 * would only work for callsigns with a direct HTTP URL.
 */

import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/devices_service.dart';
import '../services/remote_content_client.dart';
import '../services/remote_event_cache.dart';

/// Tiny in-memory LRU of image bytes keyed by the full request URL
/// (callsign + app + item + path + thumb flag). Lets the lightbox
/// prefetch the next/previous photo so flipping through the gallery
/// feels instant instead of waiting on a full round-trip every time.
/// Capped by total bytes — images get evicted oldest-first once the
/// cache grows past the budget.
class _RemoteImageCache {
  static const int _maxBytes = 48 * 1024 * 1024; // 48 MB
  static final LinkedHashMap<String, Uint8List> _store =
      LinkedHashMap<String, Uint8List>();
  static final Map<String, Future<Uint8List?>> _inFlight = {};
  static int _currentBytes = 0;

  static Uint8List? get(String key) {
    final v = _store.remove(key);
    if (v != null) _store[key] = v; // mark as most-recent
    return v;
  }

  static void put(String key, Uint8List bytes) {
    final existing = _store.remove(key);
    if (existing != null) _currentBytes -= existing.length;
    _store[key] = bytes;
    _currentBytes += bytes.length;
    while (_currentBytes > _maxBytes && _store.isNotEmpty) {
      final oldest = _store.keys.first;
      final evicted = _store.remove(oldest);
      if (evicted != null) _currentBytes -= evicted.length;
    }
  }

  static Future<Uint8List?>? inFlight(String key) => _inFlight[key];
  static void setInFlight(String key, Future<Uint8List?> f) {
    _inFlight[key] = f;
  }
  static void clearInFlight(String key) => _inFlight.remove(key);
}

class RemoteContentImage extends StatefulWidget {
  final String remoteCallsign;
  final String appType;
  final String itemId;
  final String relativePath;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final Widget Function(BuildContext, Object error)? errorBuilder;

  /// When true (default) the widget asks the remote device for a
  /// ~480 px preview instead of the full-res original. Gallery
  /// grids / list tiles should keep this on; a lightbox that wants
  /// the full image should set it false.
  final bool thumbnail;

  const RemoteContentImage({
    super.key,
    required this.remoteCallsign,
    required this.appType,
    required this.itemId,
    required this.relativePath,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.errorBuilder,
    this.thumbnail = true,
  });

  /// Kick off a fetch for an image the user is likely to view next
  /// (e.g. the slide after the one they're currently on in a
  /// lightbox). Results land in the shared in-memory cache so the
  /// next matching [RemoteContentImage] renders instantly. Safe to
  /// call repeatedly — duplicate requests are coalesced.
  static void prefetch({
    required String remoteCallsign,
    required String appType,
    required String itemId,
    required String relativePath,
    bool thumbnail = false,
  }) {
    final key = _cacheKey(
      remoteCallsign: remoteCallsign,
      appType: appType,
      itemId: itemId,
      relativePath: relativePath,
      thumbnail: thumbnail,
    );
    if (_RemoteImageCache.get(key) != null) return;
    if (_RemoteImageCache.inFlight(key) != null) return;
    final future = _fetchBytes(
      remoteCallsign: remoteCallsign,
      appType: appType,
      itemId: itemId,
      relativePath: relativePath,
      thumbnail: thumbnail,
    );
    _RemoteImageCache.setInFlight(key, future);
    future.whenComplete(() => _RemoteImageCache.clearInFlight(key));
  }

  static String _cacheKey({
    required String remoteCallsign,
    required String appType,
    required String itemId,
    required String relativePath,
    required bool thumbnail,
  }) =>
      '$remoteCallsign|$appType|$itemId|$relativePath|${thumbnail ? "t" : "f"}';

  static Future<Uint8List?> _fetchBytes({
    required String remoteCallsign,
    required String appType,
    required String itemId,
    required String relativePath,
    required bool thumbnail,
  }) async {
    final key = _cacheKey(
      remoteCallsign: remoteCallsign,
      appType: appType,
      itemId: itemId,
      relativePath: relativePath,
      thumbnail: thumbnail,
    );
    final cached = _RemoteImageCache.get(key);
    if (cached != null) return cached;
    final existing = _RemoteImageCache.inFlight(key);
    if (existing != null) return existing;

    // Disk cache for events: thumbnails and full-res photos belong
    // to the author's events folder under {baseDir}/devices/.
    // Thumbnails get a `.thumb` suffix so they coexist with the
    // full-res original of the same filename in the cache.
    final cacheable = appType == 'events';
    final cachePath =
        thumbnail ? '$relativePath.thumb' : relativePath;
    if (cacheable) {
      final disk = await RemoteEventCache.readFile(
        authorCallsign: remoteCallsign,
        eventId: itemId,
        relativePath: cachePath,
      );
      if (disk != null) {
        _RemoteImageCache.put(key, disk);
        return disk;
      }
    }
    try {
      var path = RemoteContent.filePath(
        appType: appType,
        itemId: itemId,
        relativePath: relativePath,
      );
      if (thumbnail) path = '$path?thumb=1';
      final resp = await DevicesService().makeDeviceApiRequestBytes(
        callsign: remoteCallsign,
        method: 'GET',
        path: path,
      );
      if (resp == null || resp.statusCode != 200) return null;
      _RemoteImageCache.put(key, resp.bytes);
      if (cacheable) {
        // Best-effort disk write, fire-and-forget — never blocks
        // the image from rendering.
        // ignore: discarded_futures
        RemoteEventCache.writeFile(
          authorCallsign: remoteCallsign,
          eventId: itemId,
          relativePath: cachePath,
          bytes: resp.bytes,
        );
      }
      return resp.bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  State<RemoteContentImage> createState() => _RemoteContentImageState();
}

class _RemoteContentImageState extends State<RemoteContentImage> {
  Future<Uint8List?>? _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  @override
  void didUpdateWidget(covariant RemoteContentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.remoteCallsign != widget.remoteCallsign ||
        oldWidget.appType != widget.appType ||
        oldWidget.itemId != widget.itemId ||
        oldWidget.relativePath != widget.relativePath ||
        oldWidget.thumbnail != widget.thumbnail) {
      _future = _fetch();
    }
  }

  Future<Uint8List?> _fetch() => RemoteContentImage._fetchBytes(
        remoteCallsign: widget.remoteCallsign,
        appType: widget.appType,
        itemId: widget.itemId,
        relativePath: widget.relativePath,
        thumbnail: widget.thumbnail,
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        Widget child;
        if (snapshot.connectionState != ConnectionState.done) {
          child = SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(
                child: CircularProgressIndicator(strokeWidth: 2)),
          );
        } else if (snapshot.hasError || snapshot.data == null) {
          child = widget.errorBuilder != null
              ? widget.errorBuilder!(
                  context, snapshot.error ?? 'Image unavailable')
              : _defaultError(context);
        } else {
          child = Image.memory(
            snapshot.data!,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            errorBuilder: (ctx, err, stack) =>
                widget.errorBuilder != null
                    ? widget.errorBuilder!(ctx, err)
                    : _defaultError(ctx),
          );
        }
        return widget.borderRadius != null
            ? ClipRRect(borderRadius: widget.borderRadius!, child: child)
            : child;
      },
    );
  }

  Widget _defaultError(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: widget.width,
      height: widget.height,
      color: theme.colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
