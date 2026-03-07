/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/manga.dart';
import 'manga_extension_service.dart';
import 'manga_scraper.dart';
import 'manga_service.dart';
import '../../services/log_service.dart';

/// Progress info for chapter downloads
class DownloadProgress {
  final String chapterTitle;
  final int currentPage;
  final int totalPages;
  final int currentChapter;
  final int totalChapters;
  final bool isComplete;
  final String? error;

  DownloadProgress({
    required this.chapterTitle,
    this.currentPage = 0,
    this.totalPages = 0,
    this.currentChapter = 0,
    this.totalChapters = 0,
    this.isComplete = false,
    this.error,
  });
}

/// Service for downloading manga chapters into existing series folders
class MangaDownloadService {
  static final MangaDownloadService _instance =
      MangaDownloadService._internal();
  factory MangaDownloadService() => _instance;
  MangaDownloadService._internal();

  final _extensionService = MangaExtensionService();
  final _scraper = MangaScraper();

  /// Find chapters available remotely but missing locally
  Future<MissingChaptersResult> findMissingChapters({
    required String seriesDir,
    required String extensionId,
    required String sourceMangaId,
    bool forceRefresh = false,
  }) async {
    // Load local chapters from CBZ files
    final localChapterNumbers = await _getLocalChapterNumbers(seriesDir);

    // Check cache
    if (!forceRefresh) {
      final meta = await _loadMeta(seriesDir);
      if (meta != null &&
          meta.extensionId == extensionId &&
          meta.sourceMangaId == sourceMangaId &&
          meta.lastChecked != null &&
          DateTime.now().difference(meta.lastChecked!).inMinutes < 60 &&
          meta.cachedMissingChapterIds != null) {
        // Return cached result
        final remoteChapters =
            await _extensionService.listChapters(extensionId, sourceMangaId);
        final missing = remoteChapters
            .where((c) => meta.cachedMissingChapterIds!.contains(c.id))
            .toList();
        return MissingChaptersResult(
          missing: missing,
          localCount: localChapterNumbers.length,
          remoteCount: meta.cachedRemoteChapters ?? remoteChapters.length,
          fromCache: true,
        );
      }
    }

    // Fetch remote chapter list
    final remoteChapters =
        await _extensionService.listChapters(extensionId, sourceMangaId);

    // Compare: find chapters not in local set
    final missing = remoteChapters
        .where((c) => !localChapterNumbers.contains(c.number))
        .toList();

    // Update cache
    await _updateMetaCache(
      seriesDir: seriesDir,
      extensionId: extensionId,
      sourceMangaId: sourceMangaId,
      remoteCount: remoteChapters.length,
      missingIds: missing.map((c) => c.id).toList(),
    );

    return MissingChaptersResult(
      missing: missing,
      localCount: localChapterNumbers.length,
      remoteCount: remoteChapters.length,
      fromCache: false,
    );
  }

  /// Download a single chapter into the series folder as chapter-N.cbz
  Future<void> downloadChapter({
    required String seriesDir,
    required String extensionId,
    required ChapterInfo chapter,
    StreamController<DownloadProgress>? progressController,
    int currentChapter = 1,
    int totalChapters = 1,
  }) async {
    final chapterName = _formatChapterNumber(chapter.number);
    final cbzFilename = 'chapter-$chapterName.cbz';
    final cbzPath = '$seriesDir/$cbzFilename';

    // Skip if already exists
    if (await File(cbzPath).exists()) {
      LogService().log(
          'MangaDownloadService: Skipping existing $cbzFilename');
      return;
    }

    progressController?.add(DownloadProgress(
      chapterTitle: chapter.title ?? 'Chapter $chapterName',
      currentPage: 0,
      totalPages: 0,
      currentChapter: currentChapter,
      totalChapters: totalChapters,
    ));

    // Get page image URLs
    final pageUrls =
        await _extensionService.getPageUrls(extensionId, chapter.id);

    if (pageUrls.isEmpty) {
      throw Exception('No pages found for chapter ${chapter.number}');
    }

    // Download each image
    final images = <Uint8List>[];
    final filenames = <String>[];
    final headers = _extensionService.getImageHeaders(extensionId);
    final cookies = _extensionService.getCookies(extensionId);
    final rateLimitMs = _extensionService.getRateLimitMs(extensionId);

    for (int i = 0; i < pageUrls.length; i++) {
      progressController?.add(DownloadProgress(
        chapterTitle: chapter.title ?? 'Chapter $chapterName',
        currentPage: i + 1,
        totalPages: pageUrls.length,
        currentChapter: currentChapter,
        totalChapters: totalChapters,
      ));

      final response = await _scraper.downloadImage(
        pageUrls[i],
        headers: headers,
        cookies: cookies,
        extensionId: extensionId,
        rateLimitMs: rateLimitMs ~/ 2, // Faster for images
      );

      images.add(Uint8List.fromList(response.bodyBytes));
      // Determine extension from content type or URL
      final ext = _imageExtension(response.headers['content-type'], pageUrls[i]);
      filenames.add('${(i + 1).toString().padLeft(3, '0')}.$ext');
    }

    // Create CBZ
    final success =
        await MangaService().addImagesToCbz(cbzPath, images, filenames);
    if (!success) {
      throw Exception('Failed to create CBZ for chapter ${chapter.number}');
    }

    // Invalidate cache after download
    await _invalidateCache(seriesDir);

    progressController?.add(DownloadProgress(
      chapterTitle: chapter.title ?? 'Chapter $chapterName',
      currentPage: pageUrls.length,
      totalPages: pageUrls.length,
      currentChapter: currentChapter,
      totalChapters: totalChapters,
      isComplete: true,
    ));

    LogService().log(
        'MangaDownloadService: Downloaded $cbzFilename (${pageUrls.length} pages)');
  }

  /// Download multiple chapters sequentially
  Stream<DownloadProgress> downloadChapters({
    required String seriesDir,
    required String extensionId,
    required List<ChapterInfo> chapters,
  }) async* {
    final controller = StreamController<DownloadProgress>();

    for (int i = 0; i < chapters.length; i++) {
      try {
        await downloadChapter(
          seriesDir: seriesDir,
          extensionId: extensionId,
          chapter: chapters[i],
          progressController: controller,
          currentChapter: i + 1,
          totalChapters: chapters.length,
        );

        // Yield the latest progress
        await for (final progress in controller.stream) {
          yield progress;
          if (progress.isComplete) break;
        }
      } catch (e) {
        yield DownloadProgress(
          chapterTitle:
              chapters[i].title ?? 'Chapter ${chapters[i].number}',
          currentChapter: i + 1,
          totalChapters: chapters.length,
          error: e.toString(),
        );
      }
    }

    controller.close();
  }

  /// Auto-match a series folder against all installed extensions
  Future<ExtensionSearchResult?> autoMatch(String seriesDir) async {
    final folderName = seriesDir.split('/').last;
    final results =
        await _extensionService.searchAllExtensions(folderName);

    if (results.isEmpty) return null;

    // Find best match by title similarity
    final normalizedFolder = _normalize(folderName);
    ExtensionSearchResult? best;
    double bestScore = 0;

    for (final result in results) {
      final score = _similarity(normalizedFolder, _normalize(result.result.title));
      if (score > bestScore) {
        bestScore = score;
        best = result;
      }
    }

    // Require at least 50% similarity
    if (bestScore < 0.5) return null;

    return best;
  }

  // ============ Helpers ============

  /// Get chapter numbers from local CBZ files
  Future<Set<double>> _getLocalChapterNumbers(String seriesDir) async {
    final numbers = <double>{};
    final dir = Directory(seriesDir);
    if (!await dir.exists()) return numbers;

    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = entity.path.split('/').last;
        if (name.toLowerCase().endsWith('.cbz')) {
          final chapter = MangaChapter.fromFilename(name);
          if (chapter.number != null) {
            numbers.add(chapter.number!);
          }
        }
      }
    }

    return numbers;
  }

  /// Format chapter number for filename
  String _formatChapterNumber(double number) {
    if (number == number.truncateToDouble()) {
      return number.toInt().toString();
    }
    return number.toString();
  }

  /// Determine image file extension
  String _imageExtension(String? contentType, String url) {
    if (contentType != null) {
      if (contentType.contains('png')) return 'png';
      if (contentType.contains('webp')) return 'webp';
      if (contentType.contains('gif')) return 'gif';
    }
    final urlExt = url.split('.').last.split('?').first.toLowerCase();
    if (['png', 'webp', 'gif', 'bmp'].contains(urlExt)) return urlExt;
    return 'jpg';
  }

  /// Normalize string for comparison
  String _normalize(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '')
        .trim();
  }

  /// Simple similarity score (0-1) based on longest common subsequence ratio
  double _similarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;

    // Check if one contains the other
    if (a.contains(b) || b.contains(a)) {
      return b.length / a.length.clamp(1, double.maxFinite.toInt());
    }

    // Simple character overlap ratio
    int matches = 0;
    int j = 0;
    for (int i = 0; i < a.length && j < b.length; i++) {
      if (a[i] == b[j]) {
        matches++;
        j++;
      }
    }
    final maxLen = a.length > b.length ? a.length : b.length;
    return matches / maxLen;
  }

  // ============ Meta Cache I/O ============

  Future<_CachedMeta?> _loadMeta(String seriesDir) async {
    try {
      final file = File('$seriesDir/${SeriesMeta.filename}');
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return _CachedMeta.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> _updateMetaCache({
    required String seriesDir,
    required String extensionId,
    required String sourceMangaId,
    required int remoteCount,
    required List<String> missingIds,
  }) async {
    try {
      final file = File('$seriesDir/${SeriesMeta.filename}');
      Map<String, dynamic> json = {};
      if (await file.exists()) {
        json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }

      json['extension_id'] = extensionId;
      json['source_manga_id'] = sourceMangaId;
      json['last_checked'] = DateTime.now().toIso8601String();
      json['cached_remote_chapters'] = remoteCount;
      json['cached_missing_chapter_ids'] = missingIds;

      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
      );
    } catch (e) {
      LogService()
          .log('MangaDownloadService: Error updating meta cache: $e');
    }
  }

  Future<void> _invalidateCache(String seriesDir) async {
    try {
      final file = File('$seriesDir/${SeriesMeta.filename}');
      if (!await file.exists()) return;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      json.remove('last_checked');
      json.remove('cached_missing_chapter_ids');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
      );
    } catch (_) {}
  }
}

/// Result of missing chapters check
class MissingChaptersResult {
  final List<ChapterInfo> missing;
  final int localCount;
  final int remoteCount;
  final bool fromCache;

  MissingChaptersResult({
    required this.missing,
    required this.localCount,
    required this.remoteCount,
    this.fromCache = false,
  });
}

/// Internal cached meta fields from manga_meta.json
class _CachedMeta {
  final String? extensionId;
  final String? sourceMangaId;
  final DateTime? lastChecked;
  final int? cachedRemoteChapters;
  final List<String>? cachedMissingChapterIds;

  _CachedMeta({
    this.extensionId,
    this.sourceMangaId,
    this.lastChecked,
    this.cachedRemoteChapters,
    this.cachedMissingChapterIds,
  });

  factory _CachedMeta.fromJson(Map<String, dynamic> json) {
    return _CachedMeta(
      extensionId: json['extension_id'] as String?,
      sourceMangaId: json['source_manga_id'] as String?,
      lastChecked: json['last_checked'] != null
          ? DateTime.tryParse(json['last_checked'] as String)
          : null,
      cachedRemoteChapters: json['cached_remote_chapters'] as int?,
      cachedMissingChapterIds:
          (json['cached_missing_chapter_ids'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList(),
    );
  }
}
