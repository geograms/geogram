/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/reader_models.dart';
import '../services/reader_service.dart';
import '../utils/reader_path_utils.dart';
import 'rss_sources_page.dart';
import 'manga_sources_page.dart';
import 'book_browser_page.dart';
import '../../services/i18n_service.dart';

/// Reader category type
enum ReaderCategory {
  rss,
  manga,
  books,
}

/// Main Reader home page with category icons
class ReaderHomePage extends StatefulWidget {
  final String appPath;
  final String appTitle;
  final I18nService i18n;
  final String? ownerCallsign;

  const ReaderHomePage({
    super.key,
    required this.appPath,
    required this.appTitle,
    required this.i18n,
    this.ownerCallsign,
  });

  @override
  State<ReaderHomePage> createState() => _ReaderHomePageState();
}

class _ReaderHomePageState extends State<ReaderHomePage> {
  final ReaderService _service = ReaderService();
  bool _loading = true;

  // Category stats
  int _rssSourceCount = 0;
  int _rssUnreadCount = 0;
  int _mangaSourceCount = 0;
  int _mangaSeriesCount = 0;
  int _bookFolderCount = 0;
  int _bookCount = 0;

  @override
  void initState() {
    super.initState();
    _initializeService();
  }

  Future<void> _initializeService() async {
    await _service.initializeApp(widget.appPath);
    await _loadStats();
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadStats() async {
    // Load RSS stats
    final rssSources = await _service.getRssSources();
    _rssSourceCount = rssSources.length;
    _rssUnreadCount = rssSources.fold(0, (sum, s) => sum + s.unreadCount);

    // Load manga stats
    final mangaSources = await _service.getMangaSources();
    _mangaSourceCount = mangaSources.length;
    int seriesCount = 0;
    for (final source in mangaSources) {
      if (source.isLocal && source.url != null) {
        // Count subdirectories and CBZ files in the local folder
        seriesCount += await _countLocalEntries(source.url!);
      } else {
        final series = await _service.getMangaSeries(source.id);
        seriesCount += series.length;
      }
    }
    _mangaSeriesCount = seriesCount;

    // Load books stats
    final bookFolders = await _service.getBookFolders([]);
    _bookFolderCount = bookFolders.length;
    final books = await _service.getBooks([]);
    _bookCount = books.length;

    // Add books from subfolders
    for (final folder in bookFolders) {
      final subBooks = await _service.getBooks([folder.id]);
      _bookCount += subBooks.length;
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

  void _openCategory(ReaderCategory category) {
    Widget page;

    switch (category) {
      case ReaderCategory.rss:
        page = RssSourcesPage(
          appPath: widget.appPath,
          i18n: widget.i18n,
        );
        break;
      case ReaderCategory.manga:
        page = MangaSourcesPage(
          appPath: widget.appPath,
          i18n: widget.i18n,
        );
        break;
      case ReaderCategory.books:
        page = BookBrowserPage(
          appPath: widget.appPath,
          i18n: widget.i18n,
        );
        break;
    }

    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => page),
    ).then((_) {
      // Refresh stats when returning
      _loadStats().then((_) {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _showSettings,
            tooltip: 'Settings',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await _loadStats();
                setState(() {});
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // RSS Category
                  _buildCategoryCard(
                    context: context,
                    category: ReaderCategory.rss,
                    icon: Icons.rss_feed,
                    title: 'RSS Feeds',
                    subtitle: _rssUnreadCount > 0
                        ? '$_rssSourceCount sources, $_rssUnreadCount unread'
                        : '$_rssSourceCount sources',
                    color: Colors.orange,
                    hasUnread: _rssUnreadCount > 0,
                  ),

                  const SizedBox(height: 16),

                  // Manga Category
                  _buildCategoryCard(
                    context: context,
                    category: ReaderCategory.manga,
                    icon: Icons.auto_stories,
                    title: 'Manga',
                    subtitle: '$_mangaSourceCount sources, $_mangaSeriesCount series',
                    color: Colors.purple,
                  ),

                  const SizedBox(height: 16),

                  // Books Category
                  _buildCategoryCard(
                    context: context,
                    category: ReaderCategory.books,
                    icon: Icons.book,
                    title: 'Books',
                    subtitle: _bookFolderCount > 0
                        ? '$_bookCount books in $_bookFolderCount folders'
                        : '$_bookCount books',
                    color: Colors.teal,
                  ),

                  const SizedBox(height: 32),

                  // Recently read section
                  _buildRecentlyReadSection(theme),
                ],
              ),
            ),
    );
  }

  Widget _buildCategoryCard({
    required BuildContext context,
    required ReaderCategory category,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    bool hasUnread = false,
  }) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openCategory(category),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                color.withValues(alpha: 0.15),
                color.withValues(alpha: 0.05),
              ],
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Stack(
                  children: [
                    Icon(icon, size: 40, color: color),
                    if (hasUnread)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _rssUnreadCount > 99 ? '99+' : '$_rssUnreadCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentlyReadSection(ThemeData theme) {
    final progress = _service.progress;
    final recent = <_RecentItem>[];

    // Collect recent RSS
    for (final entry in progress.rss.entries) {
      if (entry.value.readAt != null) {
        recent.add(_RecentItem(
          type: 'rss',
          path: entry.key,
          timestamp: entry.value.readAt!,
        ));
      }
    }

    // Collect recent manga
    for (final entry in progress.manga.entries) {
      recent.add(_RecentItem(
        type: 'manga',
        path: entry.key,
        timestamp: entry.value.lastReadAt,
      ));
    }

    // Collect recent books
    for (final entry in progress.books.entries) {
      recent.add(_RecentItem(
        type: 'book',
        path: entry.key,
        timestamp: entry.value.lastReadAt,
      ));
    }

    // Sort by timestamp, newest first
    recent.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    // Take top 5
    final topRecent = recent.take(5).toList();

    if (topRecent.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recently Read',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        ...topRecent.map((item) => _buildRecentItemTile(item, theme)),
      ],
    );
  }

  Widget _buildRecentItemTile(_RecentItem item, ThemeData theme) {
    IconData icon;
    Color color;
    String title;

    switch (item.type) {
      case 'rss':
        icon = Icons.article_outlined;
        color = Colors.orange;
        title = item.path.split('/').last;
        break;
      case 'manga':
        icon = Icons.auto_stories_outlined;
        color = Colors.purple;
        title = item.path.split('/').last;
        break;
      case 'book':
        icon = Icons.book_outlined;
        color = Colors.teal;
        title = item.path.split('/').last;
        break;
      default:
        icon = Icons.article_outlined;
        color = Colors.grey;
        title = item.path;
    }

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_formatTimeAgo(item.timestamp)),
      dense: true,
    );
  }

  String _formatTimeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${diff.inDays ~/ 7}w ago';
  }

  void _showSettings() {
    // TODO: Implement settings dialog
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings not implemented yet')),
    );
  }
}

class _RecentItem {
  final String type;
  final String path;
  final DateTime timestamp;

  _RecentItem({
    required this.type,
    required this.path,
    required this.timestamp,
  });
}
