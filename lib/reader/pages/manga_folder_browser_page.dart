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
import '../utils/reader_path_utils.dart';
import 'manga_reader_page.dart';
import '../../services/i18n_service.dart';

/// Page for browsing local manga folders and CBZ files
class MangaFolderBrowserPage extends StatefulWidget {
  final String appPath;
  final String sourceId;
  final String rootPath;
  final List<String> initialPath;
  final I18nService i18n;

  const MangaFolderBrowserPage({
    super.key,
    required this.appPath,
    required this.sourceId,
    required this.rootPath,
    this.initialPath = const [],
    required this.i18n,
  });

  @override
  State<MangaFolderBrowserPage> createState() =>
      _MangaFolderBrowserPageState();
}

class _MangaFolderBrowserPageState extends State<MangaFolderBrowserPage> {
  List<Directory> _folders = [];
  List<_CbzEntry> _cbzFiles = [];
  SeriesMeta? _meta;
  bool _loading = true;
  bool _gridView = false;
  int _missingChapters = 0;
  bool _checkingUpdates = false;
  bool _downloadingChapters = false;
  String _downloadStatus = '';
  List<ChapterInfo> _missingChapterList = [];

  @override
  void initState() {
    super.initState();
    _loadContent();
  }

  String get _currentDir {
    if (widget.initialPath.isEmpty) return widget.rootPath;
    return '${widget.rootPath}/${widget.initialPath.join('/')}';
  }

  String get _title {
    if (_meta != null && _meta!.title.isNotEmpty) return _meta!.title;
    if (widget.initialPath.isEmpty) {
      return widget.rootPath.split('/').last;
    }
    return widget.initialPath.last;
  }

  Future<void> _loadContent() async {
    setState(() => _loading = true);

    try {
      final dir = Directory(_currentDir);
      if (!await dir.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Directory not found: $_currentDir')),
          );
          Navigator.pop(context);
        }
        return;
      }

      final folders = <Directory>[];
      final cbzFiles = <_CbzEntry>[];

      await for (final entity in dir.list()) {
        final name = entity.path.split('/').last;
        // Skip hidden files, temp files, and the meta file itself
        if (name.startsWith('.') ||
            name.endsWith('.tmp') ||
            name.endsWith('.part') ||
            name == SeriesMeta.filename) {
          continue;
        }

        if (entity is Directory) {
          folders.add(entity);
        } else if (entity is File && ReaderPathUtils.isCbzFile(name)) {
          final chapter = MangaChapter.fromFilename(name);
          cbzFiles.add(_CbzEntry(
            filename: name,
            chapter: chapter,
            fullPath: entity.path,
          ));
        }
      }

      // Sort directories alphabetically
      folders.sort(
          (a, b) => a.path.split('/').last.compareTo(b.path.split('/').last));

      // Sort CBZ files by chapter number
      cbzFiles.sort((a, b) => a.chapter.compareTo(b.chapter));

      // Load series meta if CBZ files exist in this directory
      SeriesMeta? meta;
      if (cbzFiles.isNotEmpty) {
        meta = await _loadMeta();
      }

      if (mounted) {
        setState(() {
          _folders = folders;
          _cbzFiles = cbzFiles;
          _meta = meta;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error scanning directory: $e')),
        );
      }
    }
  }

  // ============ Meta I/O ============

  String get _metaPath => '$_currentDir/${SeriesMeta.filename}';

  Future<SeriesMeta> _loadMeta() async {
    try {
      final file = File(_metaPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        return SeriesMeta.fromJson(json);
      }
    } catch (_) {}
    // Default: use folder name as title
    final folderName = widget.initialPath.isEmpty
        ? widget.rootPath.split('/').last
        : widget.initialPath.last;
    return SeriesMeta(title: folderName);
  }

  Future<void> _saveMeta() async {
    if (_meta == null) return;
    try {
      final file = File(_metaPath);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_meta!.toJson()),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving metadata: $e')),
        );
      }
    }
  }

  // ============ Navigation ============

  void _openFolder(Directory folder) {
    final folderName = folder.path.split('/').last;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MangaFolderBrowserPage(
          appPath: widget.appPath,
          sourceId: widget.sourceId,
          rootPath: widget.rootPath,
          initialPath: [...widget.initialPath, folderName],
          i18n: widget.i18n,
        ),
      ),
    );
  }

  void _openCbz(_CbzEntry entry) {
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => MangaReaderPage(
          appPath: widget.appPath,
          sourceId: widget.sourceId,
          mangaSlug: ReaderPathUtils.slugify(
              widget.initialPath.isEmpty
                  ? widget.sourceId
                  : widget.initialPath.join('/')),
          chapter: entry.chapter,
          chapterPath: entry.fullPath,
          seriesDir: _currentDir,
          i18n: widget.i18n,
        ),
      ),
    )
        .then((_) {
      // Reload meta to pick up progress changes from reader
      _loadMeta().then((meta) {
        if (mounted) setState(() => _meta = meta);
      });
    });
  }

  // ============ Read/Unread Actions ============

  void _markAllRead() async {
    if (_meta == null) return;
    for (final entry in _cbzFiles) {
      _meta!.getOrCreate(entry.filename).read = true;
    }
    await _saveMeta();
    setState(() {});
  }

  void _markAllUnread() async {
    if (_meta == null) return;
    for (final entry in _cbzFiles) {
      final state = _meta!.chapters[entry.filename];
      if (state != null) {
        state.read = false;
        state.currentPage = 0;
      }
    }
    await _saveMeta();
    setState(() {});
  }

  void _toggleChapterRead(_CbzEntry entry) async {
    if (_meta == null) return;
    final state = _meta!.getOrCreate(entry.filename);
    state.read = !state.read;
    if (!state.read) state.currentPage = 0;
    await _saveMeta();
    setState(() {});
  }

  // ============ Extension Updates ============

  void _searchForUpdates() async {
    if (_checkingUpdates) return;
    setState(() => _checkingUpdates = true);

    try {
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
        setState(() => _checkingUpdates = false);
        return;
      }

      final downloadService = MangaDownloadService();

      // Check if we have a cached extension match
      String? extensionId;
      String? sourceMangaId;

      final metaFile = File(_metaPath);
      if (await metaFile.exists()) {
        try {
          final content = await metaFile.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          extensionId = json['extension_id'] as String?;
          sourceMangaId = json['source_manga_id'] as String?;
        } catch (_) {}
      }

      // Auto-match if no cached match
      if (extensionId == null || sourceMangaId == null) {
        final match = await downloadService.autoMatch(_currentDir);
        if (match != null) {
          extensionId = match.extensionId;
          sourceMangaId = match.result.id;
        }
      }

      if (extensionId == null || sourceMangaId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('No matching series found online')),
          );
        }
        setState(() => _checkingUpdates = false);
        return;
      }

      final result = await downloadService.findMissingChapters(
        seriesDir: _currentDir,
        extensionId: extensionId,
        sourceMangaId: sourceMangaId,
      );

      if (mounted) {
        setState(() {
          _missingChapters = result.missing.length;
          _missingChapterList = result.missing;
          _checkingUpdates = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.missing.isEmpty
                ? 'All chapters up to date (${result.localCount}/${result.remoteCount})'
                : '${result.missing.length} new chapters available'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checkingUpdates = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error checking updates: $e')),
        );
      }
    }
  }

  void _downloadMissing() async {
    if (_downloadingChapters || _missingChapterList.isEmpty) return;
    setState(() {
      _downloadingChapters = true;
      _downloadStatus = 'Starting download...';
    });

    try {
      // Read extension info from meta
      final metaFile = File(_metaPath);
      final content = await metaFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final extensionId = json['extension_id'] as String;

      final downloadService = MangaDownloadService();

      for (int i = 0; i < _missingChapterList.length; i++) {
        final chapter = _missingChapterList[i];
        if (mounted) {
          setState(() {
            _downloadStatus =
                'Downloading ${i + 1}/${_missingChapterList.length}: '
                '${chapter.title ?? "Chapter ${chapter.number}"}';
          });
        }

        await downloadService.downloadChapter(
          seriesDir: _currentDir,
          extensionId: extensionId,
          chapter: chapter,
        );
      }

      if (mounted) {
        setState(() {
          _downloadingChapters = false;
          _missingChapters = 0;
          _missingChapterList = [];
          _downloadStatus = '';
        });
        // Reload to show new files
        await _loadContent();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Downloads complete')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloadingChapters = false;
          _downloadStatus = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download error: $e')),
        );
      }
    }
  }

  // ============ Edit Metadata ============

  void _editSeriesInfo() {
    if (_meta == null) return;
    showDialog(
      context: context,
      builder: (context) => _EditSeriesDialog(
        meta: _meta!,
        seriesDir: _currentDir,
        onSaved: (updatedMeta) async {
          setState(() => _meta = updatedMeta);
          await _saveMeta();
        },
      ),
    );
  }

  // ============ Build ============

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEmpty = _folders.isEmpty && _cbzFiles.isEmpty;
    final hasCbz = _cbzFiles.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (hasCbz)
            IconButton(
              icon: const Icon(Icons.edit_note),
              onPressed: _editSeriesInfo,
              tooltip: 'Edit series info',
            ),
          IconButton(
            icon: Icon(_gridView ? Icons.list : Icons.grid_view),
            onPressed: () => setState(() => _gridView = !_gridView),
            tooltip: _gridView ? 'List view' : 'Grid view',
          ),
          if (hasCbz)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'mark_all_read') _markAllRead();
                if (value == 'mark_all_unread') _markAllUnread();
                if (value == 'search_updates') _searchForUpdates();
                if (value == 'download_missing') _downloadMissing();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'search_updates',
                  child: ListTile(
                    leading: _checkingUpdates
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.update),
                    title: Text(_missingChapters > 0
                        ? 'Search for updates ($_missingChapters new)'
                        : 'Search for updates'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (_missingChapters > 0)
                  PopupMenuItem(
                    value: 'download_missing',
                    child: ListTile(
                      leading: _downloadingChapters
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          : const Icon(Icons.download),
                      title:
                          Text('Download $_missingChapters chapters'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'mark_all_read',
                  child: ListTile(
                    leading: Icon(Icons.done_all),
                    title: Text('Mark all read'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'mark_all_unread',
                  child: ListTile(
                    leading: Icon(Icons.remove_done),
                    title: Text('Mark all unread'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : isEmpty
              ? _buildEmptyState(theme)
              : RefreshIndicator(
                  onRefresh: _loadContent,
                  child: Column(
                    children: [
                      if (hasCbz && _meta != null) _buildSeriesHeader(theme),
                      if (_downloadingChapters)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          child: Column(
                            children: [
                              const LinearProgressIndicator(),
                              const SizedBox(height: 4),
                              Text(_downloadStatus,
                                  style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      Expanded(
                        child:
                            _gridView ? _buildGridView() : _buildListView(),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildSeriesHeader(ThemeData theme) {
    final readCount = _meta!.readCount;
    final totalCount = _cbzFiles.length;
    final progress = totalCount > 0 ? readCount / totalCount : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Thumbnail
          if (_meta!.thumbnail != null && _meta!.thumbnail!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.file(
                  File('$_currentDir/${_meta!.thumbnail}'),
                  width: 40,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                ),
              ),
            ),
          // Progress info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$readCount / $totalCount chapters read',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor:
                        theme.colorScheme.onSurface.withValues(alpha: 0.1),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_open,
            size: 80,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'No manga files found',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'This folder has no CBZ files or subfolders',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListView() {
    return ListView(
      children: [
        ..._folders.map((folder) => _buildFolderTile(folder)),
        ..._cbzFiles.map((entry) => _buildCbzTile(entry)),
      ],
    );
  }

  Widget _buildGridView() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.8,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _folders.length + _cbzFiles.length,
      itemBuilder: (context, index) {
        if (index < _folders.length) {
          return _buildFolderCard(_folders[index]);
        }
        return _buildCbzCard(_cbzFiles[index - _folders.length]);
      },
    );
  }

  Widget _buildFolderTile(Directory folder) {
    final name = folder.path.split('/').last;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.purple.withValues(alpha: 0.2),
        child: const Icon(Icons.folder, color: Colors.purple),
      ),
      title: Text(name),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openFolder(folder),
    );
  }

  Widget _buildFolderCard(Directory folder) {
    final name = folder.path.split('/').last;

    return GestureDetector(
      onTap: () => _openFolder(folder),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 60,
            height: 70,
            decoration: BoxDecoration(
              color: Colors.purple.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.folder, color: Colors.purple, size: 40),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildCbzTile(_CbzEntry entry) {
    final isRead = _meta?.isChapterRead(entry.filename) ?? false;
    final state = _meta?.chapters[entry.filename];
    final hasProgress = state != null &&
        !state.read &&
        state.currentPage > 0 &&
        state.totalPages > 0;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isRead
            ? Colors.green.withValues(alpha: 0.2)
            : Colors.deepOrange.withValues(alpha: 0.2),
        child: Icon(
          isRead ? Icons.check_circle : Icons.auto_stories,
          color: isRead ? Colors.green : Colors.deepOrange,
        ),
      ),
      title: Text(
        entry.chapter.displayName,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: hasProgress
          ? Text('Page ${state.currentPage + 1} / ${state.totalPages}')
          : (entry.chapter.volume != null
              ? Text('Vol. ${entry.chapter.volume}')
              : null),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openCbz(entry),
      onLongPress: () => _toggleChapterRead(entry),
    );
  }

  Widget _buildCbzCard(_CbzEntry entry) {
    final isRead = _meta?.isChapterRead(entry.filename) ?? false;

    return GestureDetector(
      onTap: () => _openCbz(entry),
      onLongPress: () => _toggleChapterRead(entry),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: isRead
                    ? Colors.green.withValues(alpha: 0.15)
                    : Colors.deepOrange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Icon(
                  isRead ? Icons.check_circle : Icons.auto_stories,
                  color: isRead ? Colors.green : Colors.deepOrange,
                  size: 36,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            entry.chapter.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// Internal model for a CBZ file entry
class _CbzEntry {
  final String filename;
  final MangaChapter chapter;
  final String fullPath;

  _CbzEntry({
    required this.filename,
    required this.chapter,
    required this.fullPath,
  });
}

/// Dialog for editing series metadata
class _EditSeriesDialog extends StatefulWidget {
  final SeriesMeta meta;
  final String seriesDir;
  final Future<void> Function(SeriesMeta) onSaved;

  const _EditSeriesDialog({
    required this.meta,
    required this.seriesDir,
    required this.onSaved,
  });

  @override
  State<_EditSeriesDialog> createState() => _EditSeriesDialogState();
}

class _EditSeriesDialogState extends State<_EditSeriesDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _tagsCtrl;
  late final TextEditingController _thumbCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.meta.title);
    _descCtrl = TextEditingController(text: widget.meta.description);
    _tagsCtrl = TextEditingController(text: widget.meta.tags.join(', '));
    _thumbCtrl = TextEditingController(text: widget.meta.thumbnail ?? '');
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _tagsCtrl.dispose();
    _thumbCtrl.dispose();
    super.dispose();
  }

  void _save() async {
    setState(() => _saving = true);
    widget.meta.title = _titleCtrl.text.trim();
    widget.meta.description = _descCtrl.text.trim();
    widget.meta.tags = _tagsCtrl.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    final thumb = _thumbCtrl.text.trim();
    widget.meta.thumbnail = thumb.isEmpty ? null : thumb;
    await widget.onSaved(widget.meta);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit series info'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descCtrl,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 3,
              minLines: 1,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tagsCtrl,
              decoration: const InputDecoration(
                labelText: 'Tags',
                hintText: 'action, fantasy, shonen',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _thumbCtrl,
              decoration: const InputDecoration(
                labelText: 'Thumbnail filename',
                hintText: 'cover.jpg',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
