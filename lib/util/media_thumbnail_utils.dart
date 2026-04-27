/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared thumbnail generator used by every HTTP endpoint that serves
 * gallery media (events, blogs, shared folder, …). Produces ~480 px
 * JPEGs for images and a single-frame PNG for short video clips,
 * caching bytes through [FileBrowserCacheService] so the desktop
 * file browser and the remote-browse endpoints share a single cache.
 *
 * Kept storage-agnostic at the input: callers give an absolute
 * on-disk path + the source extension. The helper handles
 * decode / resize / encode / cache and returns bytes + MIME.
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../services/file_browser_cache_service.dart';
import '../services/log_service.dart';
import '../services/thumbnail_extractor.dart';

class MediaThumbnail {
  final Uint8List bytes;
  final String contentType;
  const MediaThumbnail({required this.bytes, required this.contentType});
}

class MediaThumbnailUtils {
  MediaThumbnailUtils._();

  // In-flight deduplication: when N parallel requests arrive for the
  // same file (e.g. N gallery tiles loaded at once on first view),
  // only one generation runs — the rest await the same future. Keyed
  // by `path|mtime` so an edited file re-generates.
  static final Map<String, Future<MediaThumbnail?>> _inFlight = {};

  static final ThumbnailExtractor _videoExtractor = createThumbnailExtractor();

  static const galleryImageExts = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
  };
  static const galleryVideoExts = {
    '.mp4',
    '.mov',
    '.webm',
    '.mkv',
    '.avi',
    '.wmv',
    '.flv',
  };

  static bool isGalleryMedia(String ext) =>
      galleryImageExts.contains(ext) || galleryVideoExts.contains(ext);

  /// Generate a thumbnail for the file at [sourcePath]. [ext] is the
  /// lowercase file extension including the leading dot (e.g. `.jpg`).
  /// Returns `null` when the extension isn't a supported gallery type
  /// or when decoding / encoding fails — the caller can fall back to
  /// the raw file.
  ///
  /// Image decode/resize/encode runs in a background isolate so the
  /// HTTP event loop keeps serving other requests while a gallery
  /// warms its cache. Concurrent requests for the same file share one
  /// generation via an in-flight map.
  static Future<MediaThumbnail?> generateForPath(
      String sourcePath, String ext) async {
    if (!isGalleryMedia(ext)) return null;
    final source = File(sourcePath);
    final DateTime mtime;
    try {
      mtime = (await source.stat()).modified;
    } catch (_) {
      return null;
    }
    final key = '$sourcePath|${mtime.microsecondsSinceEpoch}';
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = _generate(source, sourcePath, ext, mtime);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  static Future<MediaThumbnail?> _generate(
      File source, String sourcePath, String ext, DateTime mtime) async {
    try {
      final cache = FileBrowserCacheService();
      await cache.initialize();

      // Cache hit?
      if (await cache.hasThumbnail(sourcePath, mtime)) {
        final bytes = await cache.getThumbnailBytes(sourcePath);
        if (bytes != null) {
          // We pre-encode video thumbnails as PNG and image thumbnails
          // as JPEG, so the cached extension tells us the content type.
          final cachedPath = await cache.getThumbnailTempPath(sourcePath);
          final ct = (cachedPath != null && cachedPath.toLowerCase().endsWith('.png'))
              ? 'image/png'
              : 'image/jpeg';
          return MediaThumbnail(bytes: bytes, contentType: ct);
        }
      }

      Uint8List? bytes;
      String cacheExt = 'jpg';
      String contentType = 'image/jpeg';

      if (galleryImageExts.contains(ext)) {
        // Decode+resize+re-encode on a background isolate — the
        // `image` package is pure Dart and each of these steps can
        // block the main isolate for hundreds of ms per photo, which
        // would otherwise serialise every HTTP request through the
        // thumbnail generator when a gallery loads.
        final original = await source.readAsBytes();
        bytes = await Isolate.run(() => _resizeToJpeg(original));
      } else {
        // Video — let the platform extractor pick the off-thread path
        // (ffmpeg subprocess on desktop, MediaMetadataRetriever on
        // Android). Returns PNG bytes.
        bytes = await _videoExtractor.extractVideoFrame(sourcePath);
        if (bytes == null) return null;
        cacheExt = 'png';
        contentType = 'image/png';
      }

      if (bytes == null) return null;

      try {
        await cache.saveThumbnail(
          sourcePath,
          bytes,
          mtime,
          extension: cacheExt,
        );
      } catch (_) {
        // Cache failures are non-fatal.
      }

      return MediaThumbnail(bytes: bytes, contentType: contentType);
    } catch (e) {
      LogService().log('MediaThumbnailUtils: thumbnail failed ($sourcePath): $e');
      return null;
    }
  }

  static Uint8List? _resizeToJpeg(Uint8List original) {
    final decoded = img.decodeImage(original);
    if (decoded == null) return null;
    final resized = decoded.width > 480
        ? img.copyResize(
            decoded,
            width: 480,
            interpolation: img.Interpolation.average,
          )
        : decoded;
    return Uint8List.fromList(img.encodeJpg(resized, quality: 75));
  }
}
