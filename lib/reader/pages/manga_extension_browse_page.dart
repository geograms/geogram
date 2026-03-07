/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga.dart';
import '../models/manga_extension.dart';
import '../services/manga_extension_service.dart';
import '../utils/reader_path_utils.dart';
import 'manga_online_detail_page.dart';
import '../../services/i18n_service.dart';

const _kLastExtensionKey = 'manga_browse_last_extension';

/// Page for browsing manga from installed extensions
class MangaExtensionBrowsePage extends StatefulWidget {
  final String appPath;
  final I18nService i18n;
  final String? initialExtensionId;

  const MangaExtensionBrowsePage({
    super.key,
    required this.appPath,
    required this.i18n,
    this.initialExtensionId,
  });

  @override
  State<MangaExtensionBrowsePage> createState() =>
      _MangaExtensionBrowsePageState();
}

class _MangaExtensionBrowsePageState extends State<MangaExtensionBrowsePage>
    with TickerProviderStateMixin {
  final _extensionService = MangaExtensionService();
  final _searchController = TextEditingController();
  List<MangaExtension> _extensions = [];
  bool _loading = true;
  String? _selectedExtensionId;

  // Browse state
  TabController? _browseTabController;
  final Map<String, List<MangaSearchResult>> _browseCache = {};
  bool _browsing = false;
  String? _browseError;

  // Search state
  bool _searchMode = false;
  bool _searching = false;
  List<_GroupedSearchResult> _searchResults = [];
  String? _searchError;

  // Chapter count cache for search results (mangaId -> count)
  final Map<String, int?> _chapterCounts = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _browseTabController?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (!_extensionService.isInitialized) {
      final extensionsDir = ReaderPathUtils.extensionsDir(widget.appPath);
      await _extensionService.initialize(extensionsDir);
    }

    _extensions = _extensionService.extensions;

    // Determine initial extension
    var extId = widget.initialExtensionId;
    if (extId == null) {
      final prefs = await SharedPreferences.getInstance();
      extId = prefs.getString(_kLastExtensionKey);
    }
    // Validate
    if (extId != null && !_extensions.any((e) => e.id == extId)) {
      extId = null;
    }
    // Default to first extension with browse configs
    extId ??=
        _extensions.where((e) => e.browse.isNotEmpty).firstOrNull?.id ??
            _extensions.firstOrNull?.id;

    if (mounted) {
      setState(() {
        _selectedExtensionId = extId;
        _loading = false;
      });
      if (extId != null) {
        _selectExtension(extId);
      }
    }
  }

  void _selectExtension(String extensionId) {
    _browseTabController?.dispose();
    final ext = _extensionService.getExtension(extensionId);
    if (ext == null) return;

    setState(() {
      _selectedExtensionId = extensionId;
      _browseError = null;
    });

    // Save preference
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(_kLastExtensionKey, extensionId);
    });

    // Set up browse tabs
    if (ext.browse.isNotEmpty) {
      _browseTabController = TabController(
        length: ext.browse.length,
        vsync: this,
      );
      _browseTabController!.addListener(() {
        if (!_browseTabController!.indexIsChanging) {
          _loadBrowseTab(extensionId, _browseTabController!.index);
        }
      });
      // Load first tab
      _loadBrowseTab(extensionId, 0);
    } else {
      _browseTabController = null;
      setState(() {
        _browseError = '${ext.name} has no catalog pages';
      });
    }
  }

  String _browseCacheKey(String extId, int tabIndex) => '$extId:$tabIndex';

  Future<void> _loadBrowseTab(String extensionId, int tabIndex) async {
    final key = _browseCacheKey(extensionId, tabIndex);
    if (_browseCache.containsKey(key)) {
      setState(() {}); // refresh from cache
      return;
    }

    setState(() {
      _browsing = true;
      _browseError = null;
    });

    try {
      final results =
          await _extensionService.browse(extensionId, tabIndex);
      if (mounted) {
        setState(() {
          _browseCache[key] = results;
          _browsing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _browsing = false;
          _browseError = 'Error loading catalog: $e';
        });
      }
    }
  }

  // ---- Search ----

  void _enterSearch() {
    setState(() => _searchMode = true);
  }

  void _exitSearch() {
    _searchController.clear();
    setState(() {
      _searchMode = false;
      _searching = false;
      _searchResults = [];
      _searchError = null;
      _chapterCounts.clear();
    });
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;

    setState(() {
      _searching = true;
      _searchError = null;
      _searchResults = [];
      _chapterCounts.clear();
    });

    try {
      final allResults =
          await _extensionService.searchAllExtensions(query.trim());

      // Group by extension
      final grouped = <String, List<ExtensionSearchResult>>{};
      for (final r in allResults) {
        grouped.putIfAbsent(r.extensionId, () => []).add(r);
      }

      final groups = grouped.entries.map((entry) {
        final ext = _extensionService.getExtension(entry.key);
        return _GroupedSearchResult(
          extensionId: entry.key,
          extensionName: ext?.name ?? entry.key,
          results: entry.value.map((e) => e.result).toList(),
        );
      }).toList();

      if (mounted) {
        setState(() {
          _searchResults = groups;
          _searching = false;
          if (groups.isEmpty) {
            _searchError = 'No results found for "$query"';
          }
        });
      }

      // Fetch chapter counts in background
      _fetchChapterCounts(groups);
    } catch (e) {
      if (mounted) {
        setState(() {
          _searching = false;
          _searchError = 'Search error: $e';
        });
      }
    }
  }

  Future<void> _fetchChapterCounts(List<_GroupedSearchResult> groups) async {
    for (final group in groups) {
      for (final result in group.results) {
        if (!mounted) return;
        try {
          final chapters = await _extensionService.listChapters(
              group.extensionId, result.id);
          if (mounted) {
            setState(() {
              _chapterCounts[result.id] = chapters.length;
            });
          }
        } catch (_) {
          // Ignore, leave as null
        }
      }
    }
  }

  void _openManga({
    required String extensionId,
    required MangaSearchResult result,
  }) {
    final ext = _extensionService.getExtension(extensionId);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MangaOnlineDetailPage(
          appPath: widget.appPath,
          extensionId: extensionId,
          extensionName: ext?.name ?? extensionId,
          mangaId: result.id,
          mangaTitle: result.title,
          thumbnailUrl: result.thumbnail,
          i18n: widget.i18n,
        ),
      ),
    );
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Browse Online')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_extensions.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Browse Online')),
        body: _buildNoExtensions(theme),
      );
    }

    if (_searchMode) {
      return _buildSearchView(theme);
    }

    return _buildBrowseView(theme);
  }

  Widget _buildBrowseView(ThemeData theme) {
    final ext = _selectedExtensionId != null
        ? _extensionService.getExtension(_selectedExtensionId!)
        : null;

    return Scaffold(
      appBar: AppBar(
        title: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _selectedExtensionId,
            isDense: true,
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
            items: _extensions.map((ext) {
              return DropdownMenuItem(
                value: ext.id,
                child: Text(ext.name),
              );
            }).toList(),
            onChanged: (id) {
              if (id != null) _selectExtension(id);
            },
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search all extensions',
            onPressed: _enterSearch,
          ),
        ],
        bottom: ext != null && ext.browse.length > 1
            ? TabBar(
                controller: _browseTabController,
                isScrollable: true,
                tabs: ext.browse.map((b) => Tab(text: b.name)).toList(),
              )
            : null,
      ),
      body: _buildBrowseBody(theme, ext),
    );
  }

  Widget _buildBrowseBody(ThemeData theme, MangaExtension? ext) {
    if (ext == null || ext.browse.isEmpty) {
      return Center(
        child: Text(
          _browseError ?? 'No catalog pages available',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      );
    }

    if (_browsing) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_browseError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_browseError!,
                style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _loadBrowseTab(
                _selectedExtensionId!,
                _browseTabController?.index ?? 0,
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final tabIndex = _browseTabController?.index ?? 0;
    final key = _browseCacheKey(_selectedExtensionId!, tabIndex);
    final results = _browseCache[key];

    if (results == null || results.isEmpty) {
      return Center(
        child: Text(
          'No manga found',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      );
    }

    return _buildMangaGrid(theme, results, _selectedExtensionId!);
  }

  Widget _buildMangaGrid(
    ThemeData theme,
    List<MangaSearchResult> results,
    String extensionId,
  ) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.55,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: results.length,
      itemBuilder: (context, index) {
        return _buildMangaCard(theme, results[index], extensionId);
      },
    );
  }

  Widget _buildMangaCard(
    ThemeData theme,
    MangaSearchResult result,
    String extensionId,
  ) {
    return GestureDetector(
      onTap: () => _openManga(extensionId: extensionId, result: result),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: result.thumbnail != null
                  ? Image.network(
                      result.thumbnail!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _placeholder(),
                    )
                  : _placeholder(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            result.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ---- Search view ----

  Widget _buildSearchView(ThemeData theme) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _exitSearch,
        ),
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search all extensions...',
            border: InputBorder.none,
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
        ),
        actions: [
          if (_searchController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _searchController.clear();
                setState(() {
                  _searchResults = [];
                  _searchError = null;
                });
              },
            ),
        ],
      ),
      body: _buildSearchBody(theme),
    );
  }

  Widget _buildSearchBody(ThemeData theme) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_searchError != null && _searchResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _searchError!,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text('Search across all extensions',
                style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.5))),
          ],
        ),
      );
    }

    // Grouped results
    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, groupIndex) {
        final group = _searchResults[groupIndex];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Extension header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
              child: Row(
                children: [
                  Icon(Icons.extension, size: 16,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    '${group.extensionName} (${group.results.length})',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            // Results for this extension
            ...group.results.map((result) => _buildSearchResultTile(
                  theme, result, group.extensionId)),
          ],
        );
      },
    );
  }

  Widget _buildSearchResultTile(
    ThemeData theme,
    MangaSearchResult result,
    String extensionId,
  ) {
    final chapterCount = _chapterCounts[result.id];

    return ListTile(
      leading: SizedBox(
        width: 50,
        height: 70,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: result.thumbnail != null
              ? Image.network(
                  result.thumbnail!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _placeholder(),
                )
              : _placeholder(),
        ),
      ),
      title: Text(
        result.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: chapterCount != null
          ? Text(
              '$chapterCount chapters',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            )
          : _chapterCounts.containsKey(result.id)
              ? null
              : Text(
                  'Loading chapters...',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    fontStyle: FontStyle.italic,
                  ),
                ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openManga(extensionId: extensionId, result: result),
    );
  }

  // ---- Common ----

  Widget _buildNoExtensions(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.extension_off, size: 64,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text('No extensions installed',
              style: theme.textTheme.titleMedium?.copyWith(
                  color:
                      theme.colorScheme.onSurface.withValues(alpha: 0.5))),
          const SizedBox(height: 8),
          Text('Go to Settings to add extensions',
              style: theme.textTheme.bodyMedium?.copyWith(
                  color:
                      theme.colorScheme.onSurface.withValues(alpha: 0.5))),
        ],
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: Colors.purple.withValues(alpha: 0.2),
      child: const Center(
        child: Icon(Icons.auto_stories, color: Colors.purple, size: 24),
      ),
    );
  }
}

/// Search results grouped by extension
class _GroupedSearchResult {
  final String extensionId;
  final String extensionName;
  final List<MangaSearchResult> results;

  _GroupedSearchResult({
    required this.extensionId,
    required this.extensionName,
    required this.results,
  });
}
