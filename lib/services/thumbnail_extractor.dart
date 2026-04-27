/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Cross-platform abstraction for video thumbnail extraction.
 *
 * Implementations dispatch by platform:
 *   native (desktop): ffmpeg subprocess via Process.run when ffmpeg is on
 *     PATH; falls back to media_kit. Both run off the UI thread — ffmpeg
 *     in a separate OS process, media_kit serialized through one player.
 *   native (Android): MethodChannel to android.media.MediaMetadataRetriever
 *     so frame extraction runs on a Java background thread.
 *   web: HTMLVideoElement + Canvas. Loads the source URL into a hidden
 *     <video>, seeks to the requested second, draws a frame to canvas, and
 *     returns the encoded PNG bytes.
 *
 * The interface only covers video — images are served as-is by the caller
 * since browsers and Flutter both downscale source bitmaps natively.
 */

import 'dart:typed_data';

import 'thumbnail_extractor_native.dart'
    if (dart.library.html) 'thumbnail_extractor_web.dart' as platform;

abstract class ThumbnailExtractor {
  /// Extract a single video frame at [atSeconds] and return the encoded
  /// bytes (PNG or JPEG, whichever the implementation produces). Returns
  /// null on failure — caller renders a generic icon.
  Future<Uint8List?> extractVideoFrame(
    String sourcePath, {
    int atSeconds = 1,
  });

  /// Whether the extractor can produce video thumbnails on this platform
  /// at all. False on web with no MediaSource support, etc.
  Future<bool> get isAvailable;
}

ThumbnailExtractor createThumbnailExtractor() => platform.create();
