/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/news_article.dart';
import '../models/collection.dart';
import '../services/news_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../dialogs/new_news_dialog.dart';

/// News browser page with list and detail view
class NewsBrowserPage extends StatefulWidget {
  final Collection collection;

  const NewsBrowserPage({
    Key? key,
    required this.collection,
  }) : super(key: key);

  @override
  State<NewsBrowserPage> createState() => _NewsBrowserPageState();
}

class _NewsBrowserPageState extends State<NewsBrowserPage> {
  final NewsService _newsService = NewsService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final TextEditingController _searchController = TextEditingController();

  List<NewsArticle> _allArticles = [];
  List<NewsArticle> _filteredArticles = [];
  NewsArticle? _selectedArticle;
  bool _isLoading = true;
  bool _showExpired = false;
  String? _currentUserNpub;
  Set<int> _expandedYears = {};
  String _currentLanguage = 'en';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterArticles);
    _initialize();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final profile = _profileService.getProfile();
    _currentUserNpub = profile.npub;

    // Get current language from i18n service
    // Convert en_US to en, pt_PT to pt
    final appLang = _i18n.currentLanguage;
    _currentLanguage = appLang.split('_').first;

    await _newsService.initializeCollection(
      widget.collection.storagePath ?? '',
      creatorNpub: _currentUserNpub,
    );

    await _loadArticles();

    // Expand most recent year by default
    if (_allArticles.isNotEmpty) {
      _expandedYears.add(_allArticles.first.year);
    }
  }

  Future<void> _loadArticles() async {
    setState(() => _isLoading = true);

    final articles = await _newsService.loadArticles(
      includeExpired: _showExpired,
    );

    setState(() {
      _allArticles = articles;
      _filteredArticles = articles;
      _isLoading = false;
    });

    _filterArticles();
  }

  void _filterArticles() {
    final query = _searchController.text.toLowerCase();

    setState(() {
      if (query.isEmpty) {
        _filteredArticles = _allArticles;
      } else {
        _filteredArticles = _allArticles.where((article) {
          final headline = article.getHeadline(_currentLanguage).toLowerCase();
          final content = article.getContent(_currentLanguage).toLowerCase();
          return headline.contains(query) ||
                 article.tags.any((tag) => tag.toLowerCase().contains(query)) ||
                 content.contains(query);
        }).toList();
      }
    });
  }

  Future<void> _selectArticle(NewsArticle article) async {
    final fullArticle = await _newsService.loadFullArticle(article.id);
    setState(() {
      _selectedArticle = fullArticle;
    });
  }

  Future<void> _createNewArticle() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => NewNewsDialog(defaultLanguage: _currentLanguage),
    );

    if (result != null && mounted) {
      final profile = _profileService.getProfile();
      final article = await _newsService.createArticle(
        author: profile.callsign,
        headlines: result['headlines'] as Map<String, String>,
        contents: result['contents'] as Map<String, String>,
        classification: result['classification'] as NewsClassification? ?? NewsClassification.normal,
        latitude: result['latitude'] as double?,
        longitude: result['longitude'] as double?,
        address: result['address'] as String?,
        radiusKm: result['radiusKm'] as double?,
        expiryDateTime: result['expiryDateTime'] as DateTime?,
        source: result['source'] as String?,
        tags: result['tags'] as List<String>?,
        npub: profile.npub,
      );

      if (article != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('article_published'))),
        );
        await _loadArticles();
      }
    }
  }

  Future<void> _deleteArticle(NewsArticle article) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_article')),
        content: Text(_i18n.t('delete_article_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('delete'), style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final success = await _newsService.deleteArticle(article.id, _currentUserNpub);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('article_deleted'))),
        );
        setState(() {
          _selectedArticle = null;
        });
        await _loadArticles();
      }
    }
  }

  Future<void> _toggleLike(NewsArticle article) async {
    final profile = _profileService.getProfile();
    final success = await _newsService.toggleLike(article.id, profile.callsign);
    if (success && mounted) {
      await _selectArticle(article);
      await _loadArticles();
    }
  }

  Color _getClassificationColor(NewsClassification classification) {
    switch (classification) {
      case NewsClassification.danger:
        return Colors.red;
      case NewsClassification.urgent:
        return Colors.orange;
      case NewsClassification.normal:
      default:
        return Colors.blue;
    }
  }

  void _toggleYear(int year) {
    setState(() {
      if (_expandedYears.contains(year)) {
        _expandedYears.remove(year);
      } else {
        _expandedYears.add(year);
      }
    });
  }

  Widget _buildArticleListByYear() {
    // Group articles by year
    final Map<int, List<NewsArticle>> articlesByYear = {};
    for (var article in _filteredArticles) {
      final year = article.year;
      if (!articlesByYear.containsKey(year)) {
        articlesByYear[year] = [];
      }
      articlesByYear[year]!.add(article);
    }

    // Sort years descending (most recent first)
    final years = articlesByYear.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      itemCount: years.length,
      itemBuilder: (context, index) {
        final year = years[index];
        final articles = articlesByYear[year]!;
        final isExpanded = _expandedYears.contains(year);

        return Column(
          children: [
            // Year header
            InkWell(
              onTap: () => _toggleYear(year),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: Theme.of(context).colorScheme.surfaceVariant,
                child: Row(
                  children: [
                    Icon(
                      isExpanded ? Icons.expand_more : Icons.chevron_right,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      year.toString(),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const Spacer(),
                    Text(
                      '${articles.length} ${articles.length == 1 ? _i18n.t('article') : _i18n.t('articles')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            // Articles for this year
            if (isExpanded)
              ...articles.map((article) {
                final isSelected = _selectedArticle?.id == article.id;
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  color: isSelected
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  child: ListTile(
                    leading: Container(
                      width: 4,
                      height: double.infinity,
                      color: _getClassificationColor(article.classification),
                    ),
                    title: Text(
                      article.getHeadline(_currentLanguage),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        decoration: article.isExpired
                            ? TextDecoration.lineThrough
                            : null,
                        color: article.isExpired
                            ? Colors.grey
                            : null,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${article.author} • ${article.displayDate} ${article.displayTime}'),
                        if (article.isExpired)
                          Text(
                            _i18n.t('expired'),
                            style: const TextStyle(color: Colors.red, fontSize: 12),
                          ),
                        if (article.hasRadius)
                          Text(
                            _i18n.t('within_radius', params: [article.radiusKm.toString()]),
                            style: const TextStyle(fontSize: 12),
                          ),
                        if (article.availableLanguages.length > 1)
                          Text(
                            'Languages: ${article.availableLanguages.join(', ').toUpperCase()}',
                            style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
                          ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (article.likeCount > 0)
                          Chip(
                            label: Text('❤️ ${article.likeCount}'),
                            padding: EdgeInsets.zero,
                          ),
                        const SizedBox(width: 8),
                        Chip(
                          label: Text(_i18n.t('classification_${article.classification.name}')),
                          backgroundColor: _getClassificationColor(article.classification),
                          labelStyle: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                    onTap: () => _selectArticle(article),
                  ),
                );
              }).toList(),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.collection.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _createNewArticle,
            tooltip: _i18n.t('new_news_article'),
          ),
          IconButton(
            icon: Icon(_showExpired ? Icons.visibility_off : Icons.visibility),
            onPressed: () {
              setState(() {
                _showExpired = !_showExpired;
              });
              _loadArticles();
            },
            tooltip: _showExpired ? _i18n.t('hide_expired') : _i18n.t('show_expired'),
          ),
        ],
      ),
      body: Row(
        children: [
          // Left panel - Article list
          Expanded(
            flex: 2,
            child: Column(
              children: [
                // Search bar
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: _i18n.t('search_articles'),
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ),
                // Articles list
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _filteredArticles.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.article, size: 64, color: Colors.grey[400]),
                                  const SizedBox(height: 16),
                                  Text(
                                    _searchController.text.isEmpty
                                        ? _i18n.t('no_news_articles_yet')
                                        : _i18n.t('no_matching_articles'),
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          color: Colors.grey[600],
                                        ),
                                  ),
                                  if (_searchController.text.isEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      _i18n.t('create_first_article'),
                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                            color: Colors.grey[500],
                                          ),
                                    ),
                                  ],
                                ],
                              ),
                            )
                          : _buildArticleListByYear(),
                ),
              ],
            ),
          ),
          // Right panel - Article detail
          Expanded(
            flex: 3,
            child: _selectedArticle == null
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.article_outlined, size: 64, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text(
                          _i18n.t('select_article_to_view'),
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: Colors.grey[600],
                              ),
                        ),
                      ],
                    ),
                  )
                : _buildArticleDetail(_selectedArticle!),
          ),
        ],
      ),
    );
  }

  Widget _buildArticleDetail(NewsArticle article) {
    final profile = _profileService.getProfile();
    final isOwnArticle = article.isOwnArticle(_currentUserNpub);
    final isLiked = article.isLikedBy(profile.callsign);

    return Column(
      children: [
        // Article header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _getClassificationColor(article.classification).withOpacity(0.1),
            border: Border(
              bottom: BorderSide(
                color: _getClassificationColor(article.classification),
                width: 3,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      article.getHeadline(_currentLanguage),
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  if (isOwnArticle)
                    IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () => _deleteArticle(article),
                      tooltip: _i18n.t('delete_article'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text(article.author)),
                  Chip(label: Text('${article.displayDate} ${article.displayTime}')),
                  Chip(
                    label: Text(_i18n.t('classification_${article.classification.name}')),
                    backgroundColor: _getClassificationColor(article.classification),
                    labelStyle: const TextStyle(color: Colors.white),
                  ),
                  if (article.isExpired)
                    Chip(
                      label: Text(_i18n.t('expired')),
                      backgroundColor: Colors.red,
                      labelStyle: const TextStyle(color: Colors.white),
                    ),
                ],
              ),
            ],
          ),
        ),
        // Article content
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(article.getContent(_currentLanguage), style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 16),
                // Language indicator
                if (article.availableLanguages.length > 1) ...[
                  Chip(
                    label: Text('Available in: ${article.availableLanguages.join(', ').toUpperCase()}'),
                    avatar: const Icon(Icons.language, size: 16),
                  ),
                  const SizedBox(height: 16),
                ],
                if (article.hasLocation) ...[
                  const Divider(),
                  Text('📍 ${article.address ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('Coordinates: ${article.latitude}, ${article.longitude}'),
                  if (article.hasRadius)
                    Text(_i18n.t('within_radius', params: [article.radiusKm.toString()])),
                ],
                if (article.hasSource) ...[
                  const Divider(),
                  Text('Source: ${article.source}'),
                ],
                if (article.hasExpiry) ...[
                  const Divider(),
                  Text('${_i18n.t('expires')}: ${article.expiry}'),
                ],
                if (article.tags.isNotEmpty) ...[
                  const Divider(),
                  Wrap(
                    spacing: 4,
                    children: article.tags.map((tag) => Chip(label: Text('#$tag'))).toList(),
                  ),
                ],
                const Divider(),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(isLiked ? Icons.favorite : Icons.favorite_border),
                      color: isLiked ? Colors.red : null,
                      onPressed: () => _toggleLike(article),
                    ),
                    Text('${article.likeCount} ${article.likeCount == 1 ? _i18n.t('like') : _i18n.t('likes')}'),
                    const Spacer(),
                    Text('${article.commentCount} ${article.commentCount == 1 ? _i18n.t('comment') : _i18n.t('comments_plural')}'),
                  ],
                ),
                if (article.comments.isNotEmpty) ...[
                  const Divider(),
                  const SizedBox(height: 8),
                  ...article.comments.map((comment) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(comment.author, style: const TextStyle(fontWeight: FontWeight.bold)),
                                  const SizedBox(width: 8),
                                  Text(comment.timestamp, style: const TextStyle(fontSize: 12)),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(comment.content),
                            ],
                          ),
                        ),
                      )),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
