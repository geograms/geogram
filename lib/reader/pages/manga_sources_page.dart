/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/reader_models.dart';
import '../services/reader_service.dart';
import '../services/reader_storage_service.dart';
import '../utils/reader_path_utils.dart';
import 'manga_folder_browser_page.dart';
import 'manga_series_page.dart';
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
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sources.isEmpty
              ? _buildEmptyState(theme)
              : RefreshIndicator(
                  onRefresh: _loadSources,
                  child: ListView.builder(
                    itemCount: _sources.length,
                    itemBuilder: (context, index) {
                      return _buildSourceTile(_sources[index]);
                    },
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addSource,
        tooltip: 'Add source',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.auto_stories_outlined,
            size: 80,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'No manga sources',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap + to add your first manga source',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
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
