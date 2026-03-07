/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/manga.dart';
import '../services/manga_download_service.dart';
import '../services/manga_extension_service.dart';
import '../services/manga_scraper.dart';
import '../utils/reader_path_utils.dart';
import 'manga_reader_page.dart';
import '../../services/i18n_service.dart';

/// Page showing online manga details with chapter list and download controls
class MangaOnlineDetailPage extends StatefulWidget {
  final String appPath;
  final String extensionId;
  final String extensionName;
  final String mangaId;
  final String mangaTitle;
  final String? thumbnailUrl;
  final I18nService i18n;

  const MangaOnlineDetailPage({
    super.key,
    required this.appPath,
    required this.extensionId,
    required this.extensionName,
    required this.mangaId,
    required this.mangaTitle,
    this.thumbnailUrl,
    required this.i18n,
  });

  @override
  State<MangaOnlineDetailPage> createState() => _MangaOnlineDetailPageState();
}

class _MangaOnlineDetailPageState extends State<MangaOnlineDetailPage> {
  final _extensionService = MangaExtensionService();
  final _downloadService = MangaDownloadService();

  List<ChapterInfo> _chapters = [];
  Set<double> _localChapterNumbers = {};
  bool _loading = true;
  bool _inLibrary = false;
  String? _seriesDir;
  String? _error;

  // Series info
  String? _description;
  String? _author;
  String? _status;
  List<String> _genres = [];
  String? _coverUrl;

  // Download state
  bool _downloading = false;
  String _downloadStatus = '';
  int _downloadCurrent = 0;
  int _downloadTotal = 0;
  final Set<String> _downloadingChapterIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _mangaSlug => ReaderPathUtils.slugify(widget.mangaTitle);

  /// Manga folder inside the reader's manga directory
  String get _libraryDir =>
      '${widget.appPath}/manga/library/series/$_mangaSlug';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Check if already in library
      _seriesDir = _libraryDir;
      final dir = Directory(_seriesDir!);
      _inLibrary = await dir.exists();

      // Load local chapters if in library
      if (_inLibrary) {
        _localChapterNumbers = await _getLocalChapterNumbers(_seriesDir!);
      }

      // Fetch series info and chapters in parallel
      final futures = await Future.wait([
        _extensionService.getSeriesInfo(widget.extensionId, widget.mangaId),
        _extensionService.listChapters(widget.extensionId, widget.mangaId),
      ]);

      final seriesInfo = futures[0] as Map<String, dynamic>;
      _chapters = futures[1] as List<ChapterInfo>;

      _description = seriesInfo['description'] as String?;
      _author = seriesInfo['author'] as String?;
      _status = seriesInfo['status'] as String?;
      _coverUrl = seriesInfo['thumbnail'] as String? ?? widget.thumbnailUrl;
      final genres = seriesInfo['genres'];
      if (genres is List) {
        _genres = genres.map((g) => g.toString()).toList();
      }

      if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<Set<double>> _getLocalChapterNumbers(String seriesDir) async {
    final numbers = <double>{};
    final dir = Directory(seriesDir);
    if (!await dir.exists()) return numbers;
    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = entity.path.split('/').last;
        if (name.toLowerCase().endsWith('.cbz')) {
          final chapter = MangaChapter.fromFilename(name);
          if (chapter.number != null) numbers.add(chapter.number!);
        }
      }
    }
    return numbers;
  }

  /// Add manga to local library (create folder + metadata)
  Future<void> _addToLibrary() async {
    try {
      final dir = Directory(_seriesDir!);
      await dir.create(recursive: true);

      // Create manga_meta.json with extension link
      final meta = SeriesMeta(
        title: widget.mangaTitle,
        extensionId: widget.extensionId,
        sourceMangaId: widget.mangaId,
      );
      final metaFile = File('${_seriesDir!}/${SeriesMeta.filename}');
      await metaFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(meta.toJson()),
      );

      // Download thumbnail if available
      final thumbUrl = _coverUrl ?? widget.thumbnailUrl;
      if (thumbUrl != null) {
        try {
          final headers =
              _extensionService.getImageHeaders(widget.extensionId);
          final cookies =
              _extensionService.getCookies(widget.extensionId);
          final response = await MangaScraper().downloadImage(
            thumbUrl,
            headers: headers,
            cookies: cookies,
            extensionId: widget.extensionId,
          );
          final thumbFile = File('${_seriesDir!}/cover.jpg');
          await thumbFile.writeAsBytes(response.bodyBytes);

          // Update meta with thumbnail
          meta.thumbnail = 'cover.jpg';
          await metaFile.writeAsString(
            const JsonEncoder.withIndent('  ').convert(meta.toJson()),
          );
        } catch (_) {
          // Thumbnail download is best-effort
        }
      }

      // Ensure the "library" source exists in reader storage
      await _ensureLibrarySource();

      if (mounted) {
        setState(() => _inLibrary = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Added to library')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  /// Ensure the "library" manga source exists
  Future<void> _ensureLibrarySource() async {
    final sourceDataPath = '${widget.appPath}/manga/library/data.json';
    final file = File(sourceDataPath);
    if (await file.exists()) return;

    await file.parent.create(recursive: true);
    final sourceData = {
      'id': 'library',
      'name': 'Library',
      'type': 'manga',
      'is_local': true,
      'url': '${widget.appPath}/manga/library/series',
      'created_at': DateTime.now().toIso8601String(),
      'modified_at': DateTime.now().toIso8601String(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(sourceData),
    );

    // Create series directory
    await Directory('${widget.appPath}/manga/library/series')
        .create(recursive: true);
  }

  /// Download a single chapter
  Future<void> _downloadSingleChapter(ChapterInfo chapter) async {
    if (_downloadingChapterIds.contains(chapter.id)) return;

    if (!_inLibrary) await _addToLibrary();

    setState(() {
      _downloadingChapterIds.add(chapter.id);
    });

    try {
      await _downloadService.downloadChapter(
        seriesDir: _seriesDir!,
        extensionId: widget.extensionId,
        chapter: chapter,
      );

      _localChapterNumbers.add(chapter.number);
      if (mounted) {
        setState(() {
          _downloadingChapterIds.remove(chapter.id);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _downloadingChapterIds.remove(chapter.id));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download error: $e')),
        );
      }
    }
  }

  /// Download all missing chapters
  Future<void> _downloadAll() async {
    if (_downloading) return;

    if (!_inLibrary) await _addToLibrary();

    final missing = _chapters
        .where((c) => !_localChapterNumbers.contains(c.number))
        .toList();

    if (missing.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All chapters already downloaded')),
        );
      }
      return;
    }

    setState(() {
      _downloading = true;
      _downloadTotal = missing.length;
      _downloadCurrent = 0;
    });

    for (final chapter in missing) {
      if (!_downloading) break; // cancelled

      final chapterName = chapter.title ?? 'Chapter ${chapter.number}';
      setState(() {
        _downloadCurrent++;
        _downloadStatus =
            'Downloading $_downloadCurrent/$_downloadTotal: $chapterName';
        _downloadingChapterIds.add(chapter.id);
      });

      try {
        await _downloadService.downloadChapter(
          seriesDir: _seriesDir!,
          extensionId: widget.extensionId,
          chapter: chapter,
        );
        _localChapterNumbers.add(chapter.number);
      } catch (e) {
        // Continue with next
      }

      if (mounted) {
        setState(() => _downloadingChapterIds.remove(chapter.id));
      }
    }

    if (mounted) {
      setState(() {
        _downloading = false;
        _downloadStatus = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Downloads complete')),
      );
    }
  }

  /// Read a chapter — download first if needed, then open reader
  Future<void> _readChapter(ChapterInfo chapter) async {
    if (!_inLibrary) await _addToLibrary();

    final chapterName = _formatChapterNumber(chapter.number);
    final cbzPath = '$_seriesDir/chapter-$chapterName.cbz';

    // Download if not available locally
    if (!await File(cbzPath).exists()) {
      setState(() => _downloadingChapterIds.add(chapter.id));
      try {
        await _downloadService.downloadChapter(
          seriesDir: _seriesDir!,
          extensionId: widget.extensionId,
          chapter: chapter,
        );
        _localChapterNumbers.add(chapter.number);
      } catch (e) {
        if (mounted) {
          setState(() => _downloadingChapterIds.remove(chapter.id));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Download error: $e')),
          );
        }
        return;
      }
      if (mounted) {
        setState(() => _downloadingChapterIds.remove(chapter.id));
      }
    }

    if (!mounted) return;

    // Open reader
    final mangaChapter = MangaChapter(
      filename: 'chapter-$chapterName.cbz',
      number: chapter.number,
      title: chapter.title,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MangaReaderPage(
          appPath: widget.appPath,
          sourceId: 'library',
          mangaSlug: _mangaSlug,
          chapter: mangaChapter,
          chapterPath: cbzPath,
          seriesDir: _seriesDir,
          i18n: widget.i18n,
        ),
      ),
    ).then((_) {
      // Refresh local chapters after reading
      if (_seriesDir != null) {
        _getLocalChapterNumbers(_seriesDir!).then((nums) {
          if (mounted) setState(() => _localChapterNumbers = nums);
        });
      }
    });
  }

  String _formatChapterNumber(double number) {
    if (number == number.truncateToDouble()) {
      return number.toInt().toString();
    }
    return number.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missingCount =
        _chapters.where((c) => !_localChapterNumbers.contains(c.number)).length;
    final displayThumb = _coverUrl ?? widget.thumbnailUrl;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Header with cover image
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            actions: [
              if (!_inLibrary)
                IconButton(
                  icon: const Icon(Icons.library_add),
                  tooltip: 'Add to library',
                  onPressed: _addToLibrary,
                ),
              if (_inLibrary && missingCount > 0)
                IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: 'Download all ($missingCount)',
                  onPressed: _downloading ? null : _downloadAll,
                ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                widget.mangaTitle,
                style: const TextStyle(
                  shadows: [Shadow(blurRadius: 10, color: Colors.black)],
                ),
              ),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (displayThumb != null)
                    Image.network(
                      displayThumb,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.purple.withValues(alpha: 0.3),
                      ),
                    )
                  else
                    Container(color: Colors.purple.withValues(alpha: 0.3)),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.7),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Series info section
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Cover + metadata row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Small cover thumbnail
                      if (displayThumb != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 100,
                            height: 140,
                            child: Image.network(
                              displayThumb,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: Colors.purple.withValues(alpha: 0.2),
                                child: const Icon(Icons.auto_stories,
                                    color: Colors.purple),
                              ),
                            ),
                          ),
                        ),
                      if (displayThumb != null) const SizedBox(width: 16),

                      // Metadata
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Source
                            Chip(
                              avatar: const Icon(Icons.extension, size: 16),
                              label: Text(widget.extensionName),
                              visualDensity: VisualDensity.compact,
                            ),
                            if (_author != null && _author!.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(Icons.person, size: 16,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.6)),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      _author!,
                                      style: theme.textTheme.bodyMedium,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (_status != null && _status!.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(
                                    _status!.toLowerCase().contains('ongoing')
                                        ? Icons.autorenew
                                        : Icons.check_circle_outline,
                                    size: 16,
                                    color: _status!.toLowerCase().contains('ongoing')
                                        ? Colors.blue
                                        : Colors.green,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _status!,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: _status!.toLowerCase().contains('ongoing')
                                          ? Colors.blue
                                          : Colors.green,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (!_loading) ...[
                              const SizedBox(height: 4),
                              Text(
                                '${_chapters.length} chapters',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),

                  // Genres
                  if (_genres.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: _genres.map((g) => Chip(
                        label: Text(g, style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                      )).toList(),
                    ),
                  ],

                  // Description
                  if (_description != null && _description!.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      _description!.trim(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],

                  const SizedBox(height: 8),

                  // Library status
                  if (_inLibrary)
                    Row(
                      children: [
                        const Icon(Icons.check_circle,
                            color: Colors.green, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'In library — ${_localChapterNumbers.length}/${_chapters.length} chapters downloaded',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.green,
                          ),
                        ),
                      ],
                    )
                  else if (!_loading)
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _addToLibrary,
                          icon: const Icon(Icons.library_add, size: 18),
                          label: const Text('Add to library'),
                        ),
                      ],
                    ),

                  // Download progress
                  if (_downloading) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: _downloadTotal > 0
                          ? _downloadCurrent / _downloadTotal
                          : null,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(_downloadStatus,
                              style: theme.textTheme.bodySmall),
                        ),
                        TextButton(
                          onPressed: () =>
                              setState(() => _downloading = false),
                          child: const Text('Stop'),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 8),
                  const Divider(),

                  // Chapters header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Chapters (${_chapters.length})',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (missingCount > 0 && !_downloading)
                        TextButton.icon(
                          onPressed: _downloadAll,
                          icon: const Icon(Icons.download, size: 18),
                          label: Text('Download $missingCount'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Loading / error
          if (_loading)
            const SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              ),
            )
          else if (_error != null)
            SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      Text(_error!,
                          style: TextStyle(color: theme.colorScheme.error)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _load,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            // Chapter list
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final chapter = _chapters[index];
                  final isLocal =
                      _localChapterNumbers.contains(chapter.number);
                  final isDownloading =
                      _downloadingChapterIds.contains(chapter.id);
                  final chapterName =
                      chapter.title ?? 'Chapter ${chapter.number}';

                  return ListTile(
                    leading: isDownloading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            isLocal
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            color: isLocal ? Colors.green : null,
                          ),
                    title: Text(
                      chapterName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      'Chapter ${chapter.number}',
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: isLocal
                        ? const Icon(Icons.chevron_right)
                        : IconButton(
                            icon: const Icon(Icons.download_outlined),
                            tooltip: 'Download',
                            onPressed: isDownloading
                                ? null
                                : () => _downloadSingleChapter(chapter),
                          ),
                    onTap: () => _readChapter(chapter),
                  );
                },
                childCount: _chapters.length,
              ),
            ),
        ],
      ),
    );
  }
}
