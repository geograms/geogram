/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../models/manga_extension.dart';
import '../services/manga_extension_service.dart';
import '../utils/reader_path_utils.dart';
import 'manga_online_detail_page.dart';
import '../../services/i18n_service.dart';

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

class _MangaExtensionBrowsePageState extends State<MangaExtensionBrowsePage> {
  final _extensionService = MangaExtensionService();
  final _searchController = TextEditingController();
  List<MangaExtension> _extensions = [];
  List<ExtensionSearchResult> _results = [];
  bool _loading = true;
  bool _searching = false;
  String? _selectedExtensionId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedExtensionId = widget.initialExtensionId;
    _init();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (!_extensionService.isInitialized) {
      final extensionsDir =
          ReaderPathUtils.extensionsDir(widget.appPath);
      await _extensionService.initialize(extensionsDir);
    }

    if (mounted) {
      setState(() {
        _extensions = _extensionService.extensions;
        _loading = false;
      });
    }
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;

    setState(() {
      _searching = true;
      _error = null;
      _results = [];
    });

    try {
      List<ExtensionSearchResult> results;
      if (_selectedExtensionId != null) {
        final searchResults = await _extensionService.search(
            _selectedExtensionId!, query.trim());
        results = searchResults
            .map((r) => ExtensionSearchResult(
                  extensionId: _selectedExtensionId!,
                  result: r,
                ))
            .toList();
      } else {
        results =
            await _extensionService.searchAllExtensions(query.trim());
      }

      if (mounted) {
        setState(() {
          _results = results;
          _searching = false;
          if (results.isEmpty) {
            _error = 'No results found for "$query"';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _searching = false;
          _error = 'Search error: $e';
        });
      }
    }
  }

  void _openResult(ExtensionSearchResult result) {
    final ext = _extensionService.getExtension(result.extensionId);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MangaOnlineDetailPage(
          appPath: widget.appPath,
          extensionId: result.extensionId,
          extensionName: ext?.name ?? result.extensionId,
          mangaId: result.result.id,
          mangaTitle: result.result.title,
          thumbnailUrl: result.result.thumbnail,
          i18n: widget.i18n,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Browse Online'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _extensions.isEmpty
              ? _buildNoExtensions(theme)
              : Column(
                  children: [
                    // Extension filter chips
                    SizedBox(
                      height: 48,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              label: const Text('All'),
                              selected: _selectedExtensionId == null,
                              onSelected: (_) =>
                                  setState(() => _selectedExtensionId = null),
                            ),
                          ),
                          ..._extensions.map((ext) => Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: FilterChip(
                                  label: Text(ext.name),
                                  selected:
                                      _selectedExtensionId == ext.id,
                                  onSelected: (_) => setState(() =>
                                      _selectedExtensionId =
                                          _selectedExtensionId == ext.id
                                              ? null
                                              : ext.id),
                                ),
                              )),
                        ],
                      ),
                    ),

                    // Search bar
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: 'Search manga...',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _results = [];
                                      _error = null;
                                    });
                                  },
                                )
                              : null,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: _search,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),

                    // Results
                    Expanded(
                      child: _searching
                          ? const Center(child: CircularProgressIndicator())
                          : _error != null && _results.isEmpty
                              ? _buildMessage(theme, _error!)
                              : _results.isEmpty
                                  ? _buildPrompt(theme)
                                  : _buildResults(theme),
                    ),
                  ],
                ),
    );
  }

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
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
          const SizedBox(height: 8),
          Text('Go to Settings to add extensions',
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
        ],
      ),
    );
  }

  Widget _buildPrompt(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search, size: 64,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text('Search for manga titles',
              style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
          const SizedBox(height: 8),
          Text(
              'Results from ${_selectedExtensionId != null ? _extensionService.getExtension(_selectedExtensionId!)?.name ?? _selectedExtensionId : "${_extensions.length} extensions"}',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4))),
        ],
      ),
    );
  }

  Widget _buildMessage(ThemeData theme, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(message,
            style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final result = _results[index];
        final ext = _extensionService.getExtension(result.extensionId);

        return ListTile(
          leading: SizedBox(
            width: 50,
            height: 70,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: result.result.thumbnail != null
                  ? Image.network(
                      result.result.thumbnail!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _placeholder(),
                    )
                  : _placeholder(),
            ),
          ),
          title: Text(
            result.result.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (result.result.description != null &&
                  result.result.description!.isNotEmpty)
                Text(
                  result.result.description!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              Text(
                ext?.name ?? result.extensionId,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openResult(result),
        );
      },
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
