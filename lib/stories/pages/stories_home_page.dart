/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../../services/app_service.dart';
import '../../services/i18n_service.dart';
import '../../util/app_constants.dart';
import '../models/story.dart';
import '../services/stories_storage_service.dart';
import '../widgets/story_card_widget.dart';
import 'story_viewer_page.dart';
import 'story_studio_page.dart';

/// Const map of category icons for tree-shaking support
const Map<String, IconData> _storyCategoryIcons = {
  'news': Icons.newspaper,
  'fun': Icons.celebration,
  'tech': Icons.computer,
  'adult': Icons.no_adult_content,
  'diary': Icons.menu_book,
  'geocache': Icons.explore,
  'travel': Icons.flight,
  'tutorial': Icons.school,
  'gaming': Icons.sports_esports,
  'food': Icons.restaurant,
  'fitness': Icons.fitness_center,
  'art': Icons.palette,
  'music': Icons.music_note,
  'nature': Icons.park,
  'history': Icons.history_edu,
  'science': Icons.science,
  'business': Icons.business,
  'family': Icons.family_restroom,
  'pets': Icons.pets,
  'diy': Icons.build,
  'mystery': Icons.quiz,
  'romance': Icons.favorite,
  'horror': Icons.mood_bad,
  'fantasy': Icons.auto_fix_high,
};

/// Main Stories app home page - browser for story documents
class StoriesHomePage extends StatefulWidget {
  final String appPath;
  final String appTitle;
  final I18nService i18n;

  const StoriesHomePage({
    super.key,
    required this.appPath,
    required this.appTitle,
    required this.i18n,
  });

  @override
  State<StoriesHomePage> createState() => _StoriesHomePageState();
}

class _StoriesHomePageState extends State<StoriesHomePage> {
  late StoriesStorageService _storage;
  List<Story> _stories = [];
  List<Story> _filteredStories = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  Set<String> _selectedCategories = {};

  @override
  void initState() {
    super.initState();
    _storage = StoriesStorageService(
      basePath: widget.appPath,
      storage: AppService().profileStorage,
    );
    _searchController.addListener(_filterStories);
    _loadStories();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterStories() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredStories = _stories.where((story) {
        // Text search
        final matchesSearch = query.isEmpty ||
            story.title.toLowerCase().contains(query) ||
            (story.description?.toLowerCase().contains(query) ?? false);

        // Category filter
        final matchesCategory = _selectedCategories.isEmpty ||
            story.tags.any((tag) => _selectedCategories.contains(tag));

        return matchesSearch && matchesCategory;
      }).toList();
    });
  }

  void _toggleCategory(String category) {
    setState(() {
      if (_selectedCategories.contains(category)) {
        _selectedCategories.remove(category);
      } else {
        _selectedCategories.add(category);
      }
    });
    _filterStories();
  }

  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _selectedCategories.clear();
    });
    _filterStories();
  }

  Future<void> _loadStories() async {
    setState(() => _isLoading = true);
    try {
      await _storage.initialize();
      _stories = await _storage.loadStories();
      _filterStories();
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _createStory() async {
    final titleController = TextEditingController();
    final descController = TextEditingController();
    final selectedCategories = <String>{};

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(widget.i18n.get('story_create', 'stories')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(
                    labelText: widget.i18n.get('story_title', 'stories'),
                    hintText: widget.i18n.get('story_title_hint', 'stories'),
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descController,
                  decoration: InputDecoration(
                    labelText: widget.i18n.get('story_description', 'stories'),
                    hintText: widget.i18n.get('story_description_hint', 'stories'),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                Text(
                  widget.i18n.get('story_categories', 'stories'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: storyCategoriesConst.map((category) {
                    final isSelected = selectedCategories.contains(category);
                    return FilterChip(
                      label: Text(widget.i18n.get('category_$category', 'stories')),
                      selected: isSelected,
                      onSelected: (selected) {
                        setDialogState(() {
                          if (selected) {
                            selectedCategories.add(category);
                          } else {
                            selectedCategories.remove(category);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        ),
      ),
    );

    if (result == true && titleController.text.isNotEmpty && mounted) {
      final story = await _storage.createStory(
        title: titleController.text,
        description: descController.text.isNotEmpty ? descController.text : null,
        categories: selectedCategories.isNotEmpty ? selectedCategories.toList() : null,
        ownerNpub: '', // TODO: Get from profile
        ownerName: null,
      );

      await _loadStories();

      // Open Studio for the new story
      if (mounted) {
        _openStudio(story);
      }
    }
  }

  void _openViewer(Story story) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StoryViewerPage(
          story: story,
          storage: _storage,
          i18n: widget.i18n,
        ),
      ),
    ).then((_) => _loadStories());
  }

  void _openStudio(Story story) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StoryStudioPage(
          story: story,
          storage: _storage,
          i18n: widget.i18n,
        ),
      ),
    ).then((_) => _loadStories());
  }

  Future<void> _deleteStory(Story story) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.get('story_delete', 'stories')),
        content: Text(widget.i18n.get('story_delete_confirm', 'stories')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.i18n.get('story_delete', 'stories')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _storage.deleteStory(story);
      await _loadStories();
    }
  }

  Future<void> _renameStory(Story story) async {
    final controller = TextEditingController(text: story.title);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.get('story_rename', 'stories')),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: widget.i18n.get('story_title', 'stories'),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );

    if (result == true && controller.text.isNotEmpty && controller.text != story.title) {
      await _storage.renameStory(story, controller.text);
      await _loadStories();
    }
  }

  Future<void> _duplicateStory(Story story) async {
    final newTitle = '${story.title} (copy)';
    await _storage.duplicateStory(story, newTitle);
    await _loadStories();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.appTitle),
        actions: const [],
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          _buildCategoryFilter(),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createStory,
        icon: const Icon(Icons.add),
        label: Text(widget.i18n.get('story_create', 'stories')),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: widget.i18n.get('search_stories', 'stories'),
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                  },
                )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          filled: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildCategoryFilter() {
    // Only show categories that have at least one story
    final usedCategories = <String>{};
    for (final story in _stories) {
      usedCategories.addAll(story.tags);
    }
    final availableCategories = storyCategoriesConst
        .where((cat) => usedCategories.contains(cat))
        .toList();

    // Don't show filter row if no categories are used
    if (availableCategories.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilterChip(
              label: Text(widget.i18n.get('filter_all', 'stories')),
              selected: _selectedCategories.isEmpty,
              onSelected: (_) => _clearFilters(),
            ),
          ),
          ...availableCategories.map((category) {
            final isSelected = _selectedCategories.contains(category);
            final icon = _storyCategoryIcons[category];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilterChip(
                avatar: icon != null
                    ? Icon(icon, size: 18)
                    : null,
                label: Text(widget.i18n.get('category_$category', 'stories')),
                selected: isSelected,
                onSelected: (_) => _toggleCategory(category),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_stories.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.auto_stories,
              size: 64,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              widget.i18n.get('stories_empty', 'stories'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              widget.i18n.get('stories_empty_hint', 'stories'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
            ),
          ],
        ),
      );
    }

    // Show "no results" when filters are active but nothing matches
    if (_filteredStories.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 64,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              widget.i18n.get('no_results', 'stories'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              widget.i18n.get('no_results_hint', 'stories'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _clearFilters,
              child: Text(widget.i18n.get('filter_all', 'stories')),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 300,
        childAspectRatio: 0.8,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _filteredStories.length,
      itemBuilder: (context, index) {
        final story = _filteredStories[index];
        return StoryCardWidget(
          story: story,
          storage: _storage,
          i18n: widget.i18n,
          onTap: () => _openViewer(story),
          onEdit: () => _openStudio(story),
          onDelete: () => _deleteStory(story),
          onRename: () => _renameStory(story),
          onDuplicate: () => _duplicateStory(story),
        );
      },
    );
  }
}
