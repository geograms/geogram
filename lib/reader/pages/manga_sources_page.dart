/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/reader_models.dart';
import '../services/manga_download_service.dart';
import '../services/manga_extension_service.dart';
import '../services/reader_service.dart';
import '../services/reader_storage_service.dart';
import '../utils/reader_path_utils.dart';
import 'manga_extension_browse_page.dart';
import 'manga_folder_browser_page.dart';
import 'manga_series_page.dart';
import 'manga_settings_page.dart';
import '../../services/i18n_service.dart';

/// Page showing list of manga sources
class MangaSourcesPage extends StatefulWidget {
  final String appPath;
  final I18nService i18n;

  const MangaSourcesPage({
    super.key,
    required this.appPath,
    required this.i18n,
  });

  @override
  State<MangaSourcesPage> createState() => _MangaSourcesPageState();
}

class _MangaSourcesPageState extends State<MangaSourcesPage> {
  final ReaderService _service = ReaderService();
  List<Source> _sources = [];
  Map<String, int> _seriesCounts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    final sources = await _service.getMangaSources();

    // Load series counts for each source
    final counts = <String, int>{};
    for (final source in sources) {
      if (source.isLocal && source.url != null) {
        // Count CBZ files and subdirectories in local folder
        counts[source.id] = await _countLocalEntries(source.url!);
      } else {
        final series = await _service.getMangaSeries(source.id);
        counts[source.id] = series.length;
      }
    }

    if (mounted) {
      setState(() {
        _sources = sources;
        _seriesCounts = counts;
        _loading = false;
      });
    }
  }

  Future<int> _countLocalEntries(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return 0;
      int count = 0;
      await for (final entity in dir.list()) {
        final name = entity.path.split('/').last;
        if (name.startsWith('.')) continue;
        if (entity is Directory ||
            (entity is File && ReaderPathUtils.isCbzFile(name))) {
          count++;
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  void _openSource(Source source) {
    if (source.isLocal && source.url != null) {
      Navigator.of(context)
          .push(
        MaterialPageRoute(
          builder: (_) => MangaFolderBrowserPage(
            appPath: widget.appPath,
            sourceId: source.id,
            rootPath: source.url!,
            i18n: widget.i18n,
          ),
        ),
      )
          .then((_) => _loadSources());
    } else {
      Navigator.of(context)
          .push(
        MaterialPageRoute(
          builder: (_) => MangaSeriesPage(
            appPath: widget.appPath,
            source: source,
            i18n: widget.i18n,
          ),
        ),
      )
          .then((_) => _loadSources());
    }
  }

  void _browseOnline() {
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => MangaExtensionBrowsePage(
          appPath: widget.appPath,
          i18n: widget.i18n,
        ),
      ),
    )
        .then((_) => _loadSources());
  }

  void _searchForUpdates() async {
    final extService = MangaExtensionService();
    if (!extService.isInitialized) {
      final extensionsDir =
          ReaderPathUtils.extensionsDir(widget.appPath);
      await extService.initialize(extensionsDir);
    }

    if (extService.extensions.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('No extensions installed. Add one in Settings.')),
        );
      }
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _UpdateCheckDialog(
        sources: _sources,
        extensionService: extService,
      ),
    );
  }

  void _addSource() {
    showDialog(
      context: context,
      builder: (context) => _AddLocalSourceDialog(
        onCreated: (path) async {
          final dirName = path.split('/').last;
          final sourceId = ReaderPathUtils.slugify(dirName);
          final source = Source(
            id: sourceId,
            name: dirName,
            type: SourceType.manga,
            isLocal: true,
            url: path,
            path: ReaderPathUtils.sourceDir(
                _service.currentPath!, 'manga', sourceId),
          );
          final storage = ReaderStorageService(_service.currentPath!);
          await storage.writeSource('manga', source);
          await _loadSources();
        },
      ),
    );
  }

  void _confirmDeleteSource(Source source) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete source'),
        content: Text('Remove "${source.name}" from your manga sources?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _deleteSource(source);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteSource(Source source) async {
    try {
      final sourceDir = Directory(
        ReaderPathUtils.sourceDir(
            _service.currentPath!, 'manga', source.id),
      );
      if (await sourceDir.exists()) {
        await sourceDir.delete(recursive: true);
      }
      await _loadSources();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting source: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manga'),
        actions: [
          IconButton(
            icon: const Icon(Icons.update),
            tooltip: 'Search for updates',
            onPressed: _searchForUpdates,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Manga settings',
            onPressed: () {
              Navigator.of(context)
                  .push(
                MaterialPageRoute(
                  builder: (_) => MangaSettingsPage(
                    appPath: widget.appPath,
                    i18n: widget.i18n,
                  ),
                ),
              )
                  .then((_) => _loadSources());
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadSources,
              child: ListView(
                children: [
                  // Browse online - always visible
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          Colors.deepPurple.withValues(alpha: 0.2),
                      child: const Icon(Icons.public,
                          color: Colors.deepPurple),
                    ),
                    title: const Text('Browse online'),
                    subtitle: const Text(
                        'Search and download manga from extensions'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _browseOnline,
                  ),
                  if (_sources.isNotEmpty) const Divider(height: 1),
                  // Local sources
                  ..._sources.map(_buildSourceTile),
                  if (_sources.isEmpty) ...[
                    const SizedBox(height: 32),
                    _buildEmptyHint(theme),
                  ],
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addSource,
        tooltip: 'Add source',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmptyHint(ThemeData theme) {
    return Center(
      child: Column(
        children: [
          Icon(
            Icons.auto_stories_outlined,
            size: 48,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 8),
          Text(
            'No local manga sources yet',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Browse online or tap + to add a local folder',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceTile(Source source) {
    final count = _seriesCounts[source.id] ?? 0;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.purple.withValues(alpha: 0.2),
        child: Icon(
          source.isLocal ? Icons.folder : Icons.auto_stories,
          color: Colors.purple,
        ),
      ),
      title: Text(source.name),
      subtitle: Text(
        source.isLocal
            ? '$count items (local folder)'
            : '$count series from ${source.url ?? 'unknown'}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openSource(source),
      onLongPress: () => _confirmDeleteSource(source),
    );
  }
}

/// Dialog for adding a local manga source directory
class _AddLocalSourceDialog extends StatefulWidget {
  final Future<void> Function(String path) onCreated;

  const _AddLocalSourceDialog({required this.onCreated});

  @override
  State<_AddLocalSourceDialog> createState() => _AddLocalSourceDialogState();
}

class _AddLocalSourceDialogState extends State<_AddLocalSourceDialog> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() async {
    final path = _controller.text.trim();
    if (path.isEmpty) {
      setState(() => _error = 'Please enter a directory path');
      return;
    }

    if (!Directory(path).existsSync()) {
      setState(() => _error = 'Directory does not exist');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await widget.onCreated(path);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error: $e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add local manga folder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Directory path',
              hintText: '/path/to/manga/folder',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}

/// Dialog that scans all series for updates
class _UpdateCheckDialog extends StatefulWidget {
  final List<Source> sources;
  final MangaExtensionService extensionService;

  const _UpdateCheckDialog({
    required this.sources,
    required this.extensionService,
  });

  @override
  State<_UpdateCheckDialog> createState() => _UpdateCheckDialogState();
}

class _UpdateCheckDialogState extends State<_UpdateCheckDialog> {
  String _status = 'Scanning series folders...';
  final _results = <_UpdateResult>[];
  bool _scanning = true;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final downloadService = MangaDownloadService();

    for (final source in widget.sources) {
      if (!source.isLocal || source.url == null) continue;

      final dir = Directory(source.url!);
      if (!await dir.exists()) continue;

      // Scan series subdirectories
      await for (final entity in dir.list()) {
        if (entity is! Directory) continue;
        final seriesDir = entity.path;
        final folderName = seriesDir.split('/').last;
        if (folderName.startsWith('.')) continue;

        // Check if this series has a cached extension match
        final metaFile = File('$seriesDir/manga_meta.json');
        String? extensionId;
        String? sourceMangaId;

        if (await metaFile.exists()) {
          try {
            final json = await metaFile.readAsString();
            final meta =
                Map<String, dynamic>.from(
                    await Future.value(_parseJson(json)));
            extensionId = meta['extension_id'] as String?;
            sourceMangaId = meta['source_manga_id'] as String?;
          } catch (_) {}
        }

        if (extensionId == null || sourceMangaId == null) {
          // Try auto-matching
          if (mounted) {
            setState(() => _status = 'Searching: $folderName...');
          }
          final match = await downloadService.autoMatch(seriesDir);
          if (match != null) {
            extensionId = match.extensionId;
            sourceMangaId = match.result.id;
          }
        }

        if (extensionId == null || sourceMangaId == null) continue;

        // Check for missing chapters
        if (mounted) {
          setState(() => _status = 'Checking: $folderName...');
        }

        try {
          final result = await downloadService.findMissingChapters(
            seriesDir: seriesDir,
            extensionId: extensionId,
            sourceMangaId: sourceMangaId,
          );

          if (result.missing.isNotEmpty) {
            _results.add(_UpdateResult(
              seriesDir: seriesDir,
              folderName: folderName,
              extensionId: extensionId,
              sourceMangaId: sourceMangaId,
              missingCount: result.missing.length,
              chapters: result.missing,
            ));
            if (mounted) setState(() {});
          }
        } catch (e) {
          // Skip series that fail
        }
      }
    }

    if (mounted) {
      setState(() {
        _scanning = false;
        _status = _results.isEmpty
            ? 'All series are up to date'
            : '${_results.length} series have new chapters';
      });
    }
  }

  Map<String, dynamic> _parseJson(String json) {
    return Map<String, dynamic>.from(
      const JsonDecoder().convert(json) as Map,
    );
  }

  void _downloadAll() async {
    setState(() => _downloading = true);
    final downloadService = MangaDownloadService();

    for (final result in _results) {
      setState(() =>
          _status = 'Downloading: ${result.folderName}...');
      try {
        for (final chapter in result.chapters) {
          await downloadService.downloadChapter(
            seriesDir: result.seriesDir,
            extensionId: result.extensionId,
            chapter: chapter,
          );
        }
      } catch (e) {
        // Continue with next series
      }
    }

    if (mounted) {
      setState(() {
        _downloading = false;
        _status = 'Downloads complete';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Update Check'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_scanning)
              const LinearProgressIndicator()
            else if (_downloading)
              const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(_status),
            if (_results.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...(_results.length > 10 ? _results.take(10) : _results)
                  .map((r) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${r.folderName}: ${r.missingCount} new chapters',
                          style: const TextStyle(fontSize: 13),
                        ),
                      )),
              if (_results.length > 10)
                Text('...and ${_results.length - 10} more',
                    style: const TextStyle(
                        fontSize: 13, fontStyle: FontStyle.italic)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: (_scanning || _downloading)
              ? null
              : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (_results.isNotEmpty && !_scanning && !_downloading)
          ElevatedButton(
            onPressed: _downloadAll,
            child: Text('Download all (${_results.fold<int>(0, (sum, r) => sum + r.missingCount)} chapters)'),
          ),
      ],
    );
  }
}

class _UpdateResult {
  final String seriesDir;
  final String folderName;
  final String extensionId;
  final String sourceMangaId;
  final int missingCount;
  final List<ChapterInfo> chapters;

  _UpdateResult({
    required this.seriesDir,
    required this.folderName,
    required this.extensionId,
    required this.sourceMangaId,
    required this.missingCount,
    required this.chapters,
  });
}
