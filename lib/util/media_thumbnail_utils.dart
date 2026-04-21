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
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../services/file_browser_cache_service.dart';
import '../services/log_service.dart';
import 'video_metadata_extractor.dart';

class MediaThumbnail {
  final Uint8List bytes;
  final String contentType;
  const MediaThumbnail({required this.bytes, required this.contentType});
}

class MediaThumbnailUtils {
  MediaThumbnailUtils._();

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
  static Future<MediaThumbnail?> generateForPath(
      String sourcePath, String ext) async {
    if (!isGalleryMedia(ext)) return null;
    final source = File(sourcePath);
    try {
      final stat = await source.stat();
      final cache = FileBrowserCacheService();
      await cache.initialize();

      // Cache hit?
      if (await cache.hasThumbnail(sourcePath, stat.modified)) {
        final cachedPath = await cache.getThumbnailTempPath(sourcePath);
        if (cachedPath != null) {
          final cachedFile = File(cachedPath);
          if (await cachedFile.exists()) {
            final bytes = await cachedFile.readAsBytes();
            final ct = cachedPath.toLowerCase().endsWith('.png')
                ? 'image/png'
                : 'image/jpeg';
            return MediaThumbnail(bytes: bytes, contentType: ct);
          }
        }
      }

      Uint8List? bytes;
      String cacheExt = 'jpg';
      String contentType = 'image/jpeg';

      if (galleryImageExts.contains(ext)) {
        // Decode + downscale + re-encode as JPEG so the grid loads
        // quickly even on mobile data.
        final original = await source.readAsBytes();
        final decoded = img.decodeImage(original);
        if (decoded == null) return null;
        final resized = decoded.width > 480
            ? img.copyResize(
                decoded,
                width: 480,
                interpolation: img.Interpolation.average,
              )
            : decoded;
        bytes = Uint8List.fromList(img.encodeJpg(resized, quality: 75));
      } else {
        // Video — single-frame PNG at ~1 s.
        final tempDir = Directory.systemTemp;
        final outPath =
            '${tempDir.path}/media_thumb_${sourcePath.hashCode}.png';
        final thumbPath = await VideoMetadataExtractor.generateThumbnail(
          sourcePath,
          outPath,
          atSeconds: 1,
        );
        if (thumbPath == null) return null;
        bytes = await File(thumbPath).readAsBytes();
        cacheExt = 'png';
        contentType = 'image/png';
        try {
          await File(thumbPath).delete();
        } catch (_) {}
      }

      if (bytes == null) return null;

      // Persist for reuse across endpoints.
      try {
        await cache.saveThumbnail(
          sourcePath,
          bytes,
          stat.modified,
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
}
