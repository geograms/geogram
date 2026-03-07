/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/reader_models.dart';
import '../services/reader_service.dart';
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
  final ReaderService _service = ReaderService();
  List<Directory> _folders = [];
  List<_CbzEntry> _cbzFiles = [];
  bool _loading = true;
  bool _gridView = false;

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
        if (name.startsWith('.')) continue; // Skip hidden files

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

      if (mounted) {
        setState(() {
          _folders = folders;
          _cbzFiles = cbzFiles;
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
    // Build mangaSlug from relative path
    final mangaSlug = widget.initialPath.isEmpty
        ? widget.sourceId
        : ReaderPathUtils.slugify(widget.initialPath.join('/'));

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MangaReaderPage(
          appPath: widget.appPath,
          sourceId: widget.sourceId,
          mangaSlug: mangaSlug,
          chapter: entry.chapter,
          chapterPath: entry.fullPath,
          i18n: widget.i18n,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEmpty = _folders.isEmpty && _cbzFiles.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
            icon: Icon(_gridView ? Icons.list : Icons.grid_view),
            onPressed: () => setState(() => _gridView = !_gridView),
            tooltip: _gridView ? 'List view' : 'Grid view',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : isEmpty
              ? _buildEmptyState(theme)
              : RefreshIndicator(
                  onRefresh: _loadContent,
                  child: _gridView ? _buildGridView() : _buildListView(),
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
            child:
                const Icon(Icons.folder, color: Colors.purple, size: 40),
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
    final mangaSlug = widget.initialPath.isEmpty
        ? widget.sourceId
        : ReaderPathUtils.slugify(widget.initialPath.join('/'));
    final progress = _service.getMangaProgress(widget.sourceId, mangaSlug);
    final isRead =
        progress != null && progress.isChapterRead(entry.filename);

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
      subtitle: entry.chapter.volume != null
          ? Text('Vol. ${entry.chapter.volume}')
          : null,
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openCbz(entry),
    );
  }

  Widget _buildCbzCard(_CbzEntry entry) {
    final mangaSlug = widget.initialPath.isEmpty
        ? widget.sourceId
        : ReaderPathUtils.slugify(widget.initialPath.join('/'));
    final progress = _service.getMangaProgress(widget.sourceId, mangaSlug);
    final isRead =
        progress != null && progress.isChapterRead(entry.filename);

    return GestureDetector(
      onTap: () => _openCbz(entry),
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
