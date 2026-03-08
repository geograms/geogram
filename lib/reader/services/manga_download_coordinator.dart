/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/manga.dart';
import 'manga_download_service.dart';
import '../../services/log_service.dart';
import '../../transfer/models/transfer_models.dart';
import '../../transfer/services/transfer_service.dart';

/// Info about an active/queued chapter download for UI display
class MangaDownloadInfo {
  final String seriesDir;
  final String seriesTitle;
  final String extensionId;
  final ChapterInfo chapter;
  final bool isActive;
  final String? error;

  MangaDownloadInfo({
    required this.seriesDir,
    required this.seriesTitle,
    required this.extensionId,
    required this.chapter,
    this.isActive = false,
    this.error,
  });

  String get chapterName => chapter.title ?? 'Chapter ${chapter.number}';
}

/// Internal task tracking for a single chapter download
class _ChapterTask {
  final String seriesDir;
  final String extensionId;
  final String seriesTitle;
  final ChapterInfo chapter;
  bool cancelled = false;
  String? error;

  _ChapterTask({
    required this.seriesDir,
    required this.extensionId,
    required this.seriesTitle,
    required this.chapter,
  });
}

/// Singleton background download coordinator that:
/// - Survives page navigation (singleton)
/// - Processes chapter downloads sequentially
/// - Registers completed downloads with TransferService for Transfer App visibility
/// - Updates manga_meta.json and library timestamps after downloads
/// - Supports pause/cancel
class MangaDownloadCoordinator {
  static final MangaDownloadCoordinator _instance =
      MangaDownloadCoordinator._internal();
  factory MangaDownloadCoordinator() => _instance;
  MangaDownloadCoordinator._internal();

  final _downloadService = MangaDownloadService();
  final _log = LogService();

  final List<_ChapterTask> _queue = [];
  bool _processing = false;
  bool _paused = false;
  _ChapterTask? _currentTask;

  final List<VoidCallback> _listeners = [];

  /// Add a listener for state changes
  void addListener(VoidCallback listener) => _listeners.add(listener);

  /// Remove a listener
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in _listeners) {
      listener();
    }
  }

  /// Whether downloads are paused
  bool get isPaused => _paused;

  /// Whether any chapter is currently being downloaded
  bool get isActive => _processing && !_paused;

  /// Total queued chapters (including current)
  int get queueLength => _queue.length + (_currentTask != null ? 1 : 0);

  /// Info about current and queued downloads
  List<MangaDownloadInfo> get downloads {
    final result = <MangaDownloadInfo>[];
    if (_currentTask != null) {
      result.add(MangaDownloadInfo(
        seriesDir: _currentTask!.seriesDir,
        seriesTitle: _currentTask!.seriesTitle,
        extensionId: _currentTask!.extensionId,
        chapter: _currentTask!.chapter,
        isActive: true,
        error: _currentTask!.error,
      ));
    }
    for (final task in _queue) {
      result.add(MangaDownloadInfo(
        seriesDir: task.seriesDir,
        seriesTitle: task.seriesTitle,
        extensionId: task.extensionId,
        chapter: task.chapter,
      ));
    }
    return result;
  }

  /// Check if a series is currently downloading or has queued chapters
  bool isDownloading(String seriesDir) {
    return (_currentTask?.seriesDir == seriesDir) ||
        _queue.any((t) => t.seriesDir == seriesDir);
  }

  /// Get queued count for a specific series
  int queuedCountForSeries(String seriesDir) {
    int count = 0;
    if (_currentTask?.seriesDir == seriesDir) count++;
    count += _queue.where((t) => t.seriesDir == seriesDir).length;
    return count;
  }

  /// Enqueue chapters for background download
  void enqueue({
    required String seriesDir,
    required String extensionId,
    required String seriesTitle,
    required List<ChapterInfo> chapters,
  }) {
    if (chapters.isEmpty) return;

    for (final chapter in chapters) {
      // Skip if already queued or currently downloading
      final alreadyQueued = _queue.any(
          (t) => t.seriesDir == seriesDir && t.chapter.id == chapter.id);
      final isCurrent = _currentTask?.seriesDir == seriesDir &&
          _currentTask?.chapter.id == chapter.id;
      if (alreadyQueued || isCurrent) continue;

      _queue.add(_ChapterTask(
        seriesDir: seriesDir,
        extensionId: extensionId,
        seriesTitle: seriesTitle,
        chapter: chapter,
      ));
    }

    _notify();
    _processQueue();
  }

  /// Pause all downloads (current chapter finishes, then stops)
  void pause() {
    _paused = true;
    _notify();
  }

  /// Resume downloads
  void resume() {
    _paused = false;
    _notify();
    _processQueue();
  }

  /// Cancel all queued downloads for a series
  void cancelSeries(String seriesDir) {
    _queue.removeWhere((t) => t.seriesDir == seriesDir);
    if (_currentTask?.seriesDir == seriesDir) {
      _currentTask?.cancelled = true;
    }
    _notify();
  }

  /// Cancel all downloads
  void cancelAll() {
    _queue.clear();
    _currentTask?.cancelled = true;
    _notify();
  }

  /// Process the download queue sequentially
  Future<void> _processQueue() async {
    if (_processing || _paused) return;
    _processing = true;

    try {
      while (_queue.isNotEmpty && !_paused) {
        _currentTask = _queue.removeAt(0);
        final task = _currentTask!;
        _notify();

        if (task.cancelled) continue;

        try {
          await _downloadService.downloadChapter(
            seriesDir: task.seriesDir,
            extensionId: task.extensionId,
            chapter: task.chapter,
          );

          if (!task.cancelled) {
            // Register with TransferService for Transfer App visibility
            _registerCompletedTransfer(task);

            // Update library data.json timestamp
            _updateLibraryTimestamp(task.seriesDir);
          }
        } catch (e) {
          _log.log(
              'MangaDownloadCoordinator: Error downloading ${task.chapter.number}: $e');
          task.error = e.toString();
        }

        _currentTask = null;
        _notify();
      }
    } finally {
      _processing = false;
      _notify();
    }
  }

  /// Register a completed chapter download with TransferService
  void _registerCompletedTransfer(_ChapterTask task) {
    try {
      final svc = TransferService();
      if (!svc.isInitialized) return;

      final chNum = task.chapter.number;
      final chName = task.chapter.title ?? 'Chapter $chNum';
      final cbzName = 'chapter-${_formatNumber(chNum)}.cbz';
      final cbzPath = '${task.seriesDir}/$cbzName';

      final file = File(cbzPath);
      final fileSize = file.existsSync() ? file.lengthSync() : 0;

      final transfer = Transfer(
        id: 'manga_${task.seriesDir.hashCode.abs()}_${chNum.hashCode.abs()}',
        direction: TransferDirection.download,
        sourceCallsign: 'manga',
        targetCallsign: '',
        remotePath: task.chapter.id,
        localPath: cbzPath,
        filename: cbzName,
        expectedBytes: fileSize,
        status: TransferStatus.completed,
        bytesTransferred: fileSize,
        completedAt: DateTime.now(),
        requestingApp: 'manga_reader',
        metadata: {
          'series': task.seriesTitle,
          'chapter_number': chNum,
          'chapter_title': chName,
        },
      );

      svc.archiveCompletedTransfer(transfer);
    } catch (e) {
      _log.log(
          'MangaDownloadCoordinator: Error registering transfer: $e');
    }
  }

  /// Update the library source's modified_at timestamp so folder browser sees new content
  void _updateLibraryTimestamp(String seriesDir) {
    try {
      // seriesDir: .../manga/library/series/slug
      // data.json: .../manga/library/data.json
      final parts = seriesDir.split('/');
      final seriesIdx = parts.lastIndexOf('series');
      if (seriesIdx < 1) return;
      final libraryDir = parts.sublist(0, seriesIdx).join('/');
      final dataFile = File('$libraryDir/data.json');
      if (dataFile.existsSync()) {
        final json =
            jsonDecode(dataFile.readAsStringSync()) as Map<String, dynamic>;
        json['modified_at'] = DateTime.now().toIso8601String();
        dataFile.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(json),
        );
      }
    } catch (e) {
      _log.log(
          'MangaDownloadCoordinator: Error updating library timestamp: $e');
    }
  }

  String _formatNumber(double number) {
    if (number == number.truncateToDouble()) {
      return number.toInt().toString();
    }
    return number.toString();
  }
}
