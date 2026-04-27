/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Serialized thumbnail generator. The file browser previously fired
 * `VideoMetadataExtractor.generateThumbnail` synchronously per visible
 * tile during build, spawning one media_kit Player per video at once —
 * which OOM-crashed the app on folders full of HD recordings.
 *
 * This service funnels every request through one worker, applies a hard
 * size cap so 4 GB videos never reach the extractor, persists results
 * through FileBrowserCacheService (which now flushes metadata
 * synchronously, so reopens hit the cache), and registers with the Task
 * Monitor so the user can see it working.
 *
 * Off-thread story: the underlying ThumbnailExtractor uses ffmpeg in a
 * separate OS process on desktop and a JNI background thread on Android
 * via MethodChannel. Only the media_kit fallback runs on the UI isolate,
 * and even that is one-at-a-time.
 */

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;

import '../models/monitored_task.dart';
import '../platform/file_system_service.dart';
import '../util/task_monitor_helpers.dart';
import 'file_browser_cache_service.dart';
import 'log_service.dart';
import 'thumbnail_extractor.dart';

class _ThumbnailRequest {
  final String path;
  final DateTime? modified;
  final Completer<String?> completer;
  _ThumbnailRequest(this.path, this.modified)
      : completer = Completer<String?>();
}

class ThumbnailGeneratorService {
  ThumbnailGeneratorService._();
  static final ThumbnailGeneratorService _instance =
      ThumbnailGeneratorService._();
  factory ThumbnailGeneratorService() => _instance;

  // Files larger than these are skipped — the picker shows the generic
  // file icon instead. Avoids OOM on huge videos and on RAW photos that
  // would blow the image decoder.
  static const int _kMaxImageBytes = 50 * 1024 * 1024;
  static const int _kMaxVideoBytes = 500 * 1024 * 1024;

  static const Set<String> _kImageExts = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp',
  };
  static const Set<String> _kVideoExts = {
    'mp4',
  };

  static const String _kTaskId = 'thumbnail.generator';

  final FileSystemService _fs = FileSystemService.instance;
  final FileBrowserCacheService _cache = FileBrowserCacheService();
  final ThumbnailExtractor _extractor = createThumbnailExtractor();

  final Queue<_ThumbnailRequest> _queue = Queue<_ThumbnailRequest>();
  final Map<String, _ThumbnailRequest> _inflight = {};
  bool _processing = false;

  bool _cacheInitialized = false;
  Future<void>? _cacheInit;

  MonitoredIsolateHandle? _monitor;

  final StreamController<String> _readyController =
      StreamController<String>.broadcast();

  /// Fires the source path when its thumbnail finishes generating.
  /// Listeners (the file picker) refresh the matching tile.
  Stream<String> get readyStream => _readyController.stream;

  /// Number of requests waiting + the one currently in flight.
  int get pendingCount => _inflight.length;

  void _ensureMonitor() {
    _monitor ??= MonitoredIsolateHandle(
      id: _kTaskId,
      name: 'Thumbnail Generator',
      description:
          'Generates image / video thumbnails for the file browser, off the build path',
      serviceName: 'ThumbnailGeneratorService',
      priority: TaskPriority.low,
    );
  }

  Future<void> _ensureCache() {
    if (_cacheInitialized) return Future<void>.value();
    return _cacheInit ??= _cache.initialize().then((_) {
      _cacheInitialized = true;
    }).catchError((Object e) {
      LogService().log('ThumbnailGeneratorService: cache init failed: $e');
    });
  }

  bool _isImage(String path) => _kImageExts
      .contains(p.extension(path).toLowerCase().replaceFirst('.', ''));

  bool _isVideo(String path) => _kVideoExts
      .contains(p.extension(path).toLowerCase().replaceFirst('.', ''));

  /// Returns a thumbnail path (or the source path for plain images),
  /// or null if the file is unsupported, missing, or over the size cap.
  /// Repeated requests for the same path share one in-flight completer.
  ///
  /// On web the returned path is a virtual FileSystemService path, not a
  /// real OS path — callers that need bytes for rendering should use
  /// [FileBrowserCacheService.getThumbnailBytes].
  Future<String?> requestThumbnail(
    String path, {
    DateTime? modified,
  }) async {
    _ensureMonitor();

    if (!_isImage(path) && !_isVideo(path)) return null;

    final existing = _inflight[path];
    if (existing != null) return existing.completer.future;

    await _ensureCache();

    if (_cacheInitialized && modified != null) {
      try {
        final has = await _cache.hasThumbnail(path, modified);
        if (has) {
          if (kIsWeb) {
            // On web there's no real path; the picker doesn't run on web
            // so this branch is mostly defensive — return null so callers
            // fall back to bytes-based access.
            return null;
          }
          final cached = await _cache.getThumbnailTempPath(path);
          if (cached != null) return cached;
        }
      } catch (_) {}
    }

    // Pre-flight size check so we never spawn an extractor for a 4 GB
    // video. The picker will fall back to the generic icon.
    try {
      final stat = await _fs.stat(path);
      if (_isImage(path) && stat.size > _kMaxImageBytes) return null;
      if (_isVideo(path) && stat.size > _kMaxVideoBytes) return null;
    } catch (_) {
      return null;
    }

    final req = _ThumbnailRequest(path, modified);
    _inflight[path] = req;
    _queue.add(req);
    unawaited(_drainQueue());
    return req.completer.future;
  }

  Future<void> _drainQueue() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty) {
        final req = _queue.removeFirst();
        _monitor?.markRunning();
        try {
          final result = await _generate(req);
          if (!req.completer.isCompleted) req.completer.complete(result);
          if (result != null) _readyController.add(req.path);
          _monitor?.markIdle();
        } catch (e) {
          LogService().log(
            'ThumbnailGeneratorService: generate failed for ${req.path}: $e',
          );
          if (!req.completer.isCompleted) req.completer.complete(null);
          _monitor?.markError(e);
        } finally {
          _inflight.remove(req.path);
        }
        // Yield one microtask between items so the UI stays responsive
        // — without this a folder of N videos pegs one core on the
        // media_kit fallback path.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _processing = false;
    }
  }

  Future<String?> _generate(_ThumbnailRequest req) async {
    if (_isImage(req.path)) {
      // Plain images: the picker uses Image.file/Image.network on the
      // source directly — no thumbnail bytes needed. This is unchanged
      // from the previous behavior. On web the picker doesn't run.
      return req.path;
    }

    if (_isVideo(req.path)) {
      final bytes = await _extractor.extractVideoFrame(req.path);
      if (bytes == null) return null;

      // No modified time → no cache key. The picker always supplies one,
      // so this branch is only hit by future server-side callers; they
      // can ask for bytes and skip the path round-trip.
      if (!_cacheInitialized || req.modified == null) return null;

      try {
        await _cache.saveThumbnail(
          req.path,
          bytes,
          req.modified!,
          extension: 'png',
        );
      } catch (e) {
        LogService().log(
          'ThumbnailGeneratorService: cache write failed for ${req.path}: $e',
        );
        return null;
      }

      // Cached path is null on web (no real OS path); callers there
      // should pull bytes via FileBrowserCacheService.getThumbnailBytes.
      return _cache.getThumbnailTempPath(req.path);
    }

    return null;
  }
}
