/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Web implementation of ThumbnailExtractor. Uses an HTMLVideoElement to
 * decode the video and a Canvas2D context to grab a single frame at the
 * requested second. The browser does the decoding off the main JS task
 * queue (HTMLVideoElement.load triggers internal decoding on a media
 * thread), and the canvas draw is the only foreground step.
 *
 * The source path is passed straight to <video src=...> — for blob URLs
 * (IndexedDB-backed FileSystemService) the caller should hand us a
 * resolvable URL; otherwise the load just fails and we return null.
 */

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'log_service.dart';
import 'thumbnail_extractor.dart';

ThumbnailExtractor create() => WebThumbnailExtractor();

class WebThumbnailExtractor implements ThumbnailExtractor {
  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<Uint8List?> extractVideoFrame(
    String sourcePath, {
    int atSeconds = 1,
  }) async {
    final video = html.VideoElement()
      ..crossOrigin = 'anonymous'
      ..muted = true
      ..preload = 'auto'
      ..src = sourcePath;

    try {
      await video.onLoadedMetadata.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('video metadata timeout'),
      );

      // Clamp the seek so we never land past EOF on a clip shorter than
      // the requested second.
      final dur = video.duration;
      final target = (dur.isFinite && dur > 0)
          ? (atSeconds < dur ? atSeconds.toDouble() : (dur * 0.5))
          : atSeconds.toDouble();

      video.currentTime = target;
      await video.onSeeked.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('video seek timeout'),
      );

      final width = video.videoWidth;
      final height = video.videoHeight;
      if (width == 0 || height == 0) return null;

      // Fit into a 480 px box keeping aspect ratio — same as the ffmpeg
      // path on native — so cached blobs stay small.
      const maxEdge = 480;
      final scale =
          width >= height ? maxEdge / width : maxEdge / height;
      final outW = scale < 1 ? (width * scale).round() : width;
      final outH = scale < 1 ? (height * scale).round() : height;

      final canvas = html.CanvasElement(width: outW, height: outH);
      final ctx = canvas.context2D;
      ctx.drawImageScaled(video, 0, 0, outW.toDouble(), outH.toDouble());

      // toBlob → ArrayBuffer → Uint8List. PNG to match the native ffmpeg
      // output path.
      final completer = Completer<html.Blob?>();
      canvas.toBlob('image/png').then(completer.complete).catchError((Object e) {
        completer.completeError(e);
      });
      final blob = await completer.future;
      if (blob == null) return null;

      final reader = html.FileReader();
      final readDone = Completer<Uint8List?>();
      reader.onLoadEnd.listen((_) {
        final result = reader.result;
        if (result is List<int>) {
          readDone.complete(Uint8List.fromList(result));
        } else if (result is ByteBuffer) {
          readDone.complete(Uint8List.view(result));
        } else {
          readDone.complete(null);
        }
      });
      reader.onError.listen((_) => readDone.complete(null));
      reader.readAsArrayBuffer(blob);
      return await readDone.future;
    } catch (e) {
      LogService()
          .log('WebThumbnailExtractor: extract failed for $sourcePath: $e');
      return null;
    } finally {
      video.removeAttribute('src');
      video.load();
    }
  }
}
