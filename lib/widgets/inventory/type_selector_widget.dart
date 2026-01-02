/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../../inventory/models/item_type_catalog.dart';
import '../../services/i18n_service.dart';

/// Widget for selecting item type from the catalog
class TypeSelectorWidget extends StatefulWidget {
  final I18nService i18n;
  final String selectedType;
  final ScrollController? scrollController;

  const TypeSelectorWidget({
    super.key,
    required this.i18n,
    required this.selectedType,
    this.scrollController,
  });

  @override
  State<TypeSelectorWidget> createState() => _TypeSelectorWidgetState();
}

class _TypeSelectorWidgetState extends State<TypeSelectorWidget> {
  final TextEditingController _searchController = TextEditingController();
  late ScrollController _listScrollController;
  String _searchQuery = '';
  late String _langCode;
  int _selectedCategoryIndex = 0;
  bool _isScrollingToCategory = false;

  final List<ItemCategory> _categories = [
    ItemCategory.food,
    ItemCategory.beverages,
    ItemCategory.household,
    ItemCategory.cleaning,
    ItemCategory.kitchen,
    ItemCategory.furniture,
    ItemCategory.storage,
    ItemCategory.medical,
    ItemCategory.tools,
    ItemCategory.automotive,
    ItemCategory.garden,
    ItemCategory.outdoor,
    ItemCategory.electronics,
    ItemCategory.office,
    ItemCategory.safety,
    ItemCategory.other,
  ];

  // Cached list items and category indices
  late List<dynamic> _items;
  late List<int> _categoryIndices;

  @override
  void initState() {
    super.initState();
    _langCode = widget.i18n.currentLanguage.split('_').first.toUpperCase();
    _listScrollController = widget.scrollController ?? ScrollController();
    _listScrollController.addListener(_onScroll);
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
    _buildItemsList();
  }

  void _buildItemsList() {
    _items = [];
    _categoryIndices = [];

    for (final category in _categories) {
      final types = ItemTypeCatalog.byCategory(category);
      if (types.isNotEmpty) {
        _categoryIndices.add(_items.length);
        _items.add(category);
        _items.addAll(types);
      }
    }
  }

  void _onScroll() {
    if (_isScrollingToCategory || _searchQuery.isNotEmpty) return;

    // Estimate which category is currently visible based on scroll position
    // Each item is approximately 56 pixels (ListTile height)
    // Category headers are slightly smaller
    const itemHeight = 56.0;
    final scrollOffset = _listScrollController.offset;

    // Find which category header we're past
    int currentCategoryIndex = 0;
    double accumulatedHeight = 0;

    for (int i = 0; i < _categoryIndices.length; i++) {
      final categoryStartIndex = _categoryIndices[i];
      // Calculate approximate position of this category header
      accumulatedHeight = categoryStartIndex * itemHeight;

      if (scrollOffset < accumulatedHeight) {
        break;
      }
      currentCategoryIndex = i;
    }

    if (currentCategoryIndex != _selectedCategoryIndex) {
      setState(() {
        _selectedCategoryIndex = currentCategoryIndex;
      });
    }
  }

  void _scrollToCategory(int categoryIndex) {
    if (categoryIndex < 0 || categoryIndex >= _categoryIndices.length) return;

    _isScrollingToCategory = true;
    setState(() {
      _selectedCategoryIndex = categoryIndex;
    });

    // Calculate scroll position
    const itemHeight = 56.0;
    final targetIndex = _categoryIndices[categoryIndex];
    final targetOffset = targetIndex * itemHeight;

    _listScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    ).then((_) {
      _isScrollingToCategory = false;
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    if (widget.scrollController == null) {
      _listScrollController.dispose();
    } else {
      _listScrollController.removeListener(_onScroll);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Handle
        Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        // Title
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                widget.i18n.t('inventory_select_type'),
                style: theme.textTheme.titleLarge,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: widget.i18n.t('inventory_search_types'),
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => _searchController.clear(),
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Category tabs (only when not searching)
        if (_searchQuery.isEmpty) _buildCategoryTabs(theme),
        // Results - continuous scrollable list
        Expanded(
          child: _searchQuery.isNotEmpty
              ? _buildSearchResults(theme)
              : _buildContinuousList(theme),
        ),
      ],
    );
  }

  Widget _buildCategoryTabs(ThemeData theme) {
    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final category = _categories[index];
          final isSelected = index == _selectedCategoryIndex;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilterChip(
              selected: isSelected,
              showCheckmark: false,
              avatar: Icon(
                _getCategoryIcon(category),
                size: 18,
                color: isSelected
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              label: Text(
                ItemTypeCatalog.getCategoryName(category, _langCode),
                style: TextStyle(
                  color: isSelected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              selectedColor: theme.colorScheme.primary,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              onSelected: (_) => _scrollToCategory(index),
            ),
          );
        },
      ),
    );
  }

  Widget _buildContinuousList(ThemeData theme) {
    return ListView.builder(
      controller: _listScrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        if (item is ItemCategory) {
          return _buildCategoryHeader(theme, item);
        } else if (item is ItemType) {
          return _buildTypeTile(theme, item);
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildCategoryHeader(ThemeData theme, ItemCategory category) {
    return MouseRegion(
      onEnter: (_) => _onItemHover(category),
      child: Container(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Row(
          children: [
            Icon(
              _getCategoryIcon(category),
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              ItemTypeCatalog.getCategoryName(category, _langCode),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults(ThemeData theme) {
    final results = ItemTypeCatalog.search(_searchQuery, langCode: _langCode);

    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              widget.i18n.t('inventory_no_results'),
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context, 'other'),
              child: Text(widget.i18n.t('inventory_use_other')),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _listScrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final type = results[index];
        return _buildTypeTile(theme, type);
      },
    );
  }

  Widget _buildTypeTile(ThemeData theme, ItemType type) {
    final isSelected = type.id == widget.selectedType;
    final categoryName = ItemTypeCatalog.getCategoryName(type.category, _langCode);

    return MouseRegion(
      onEnter: (_) => _onItemHover(type.category),
      child: ListTile(
        // Only show leading icon when searching (category context is lost)
        leading: _searchQuery.isNotEmpty
            ? Icon(
                _getCategoryIcon(type.category),
                color: isSelected ? theme.colorScheme.primary : null,
              )
            : null,
        title: Text(
          type.getName(_langCode),
          style: isSelected
              ? TextStyle(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                )
              : null,
        ),
        subtitle: _searchQuery.isNotEmpty ? Text(categoryName) : null,
        trailing: isSelected
            ? Icon(Icons.check, color: theme.colorScheme.primary)
            : null,
        selected: isSelected,
        onTap: () => Navigator.pop(context, type.id),
      ),
    );
  }

  void _onItemHover(ItemCategory category) {
    if (_searchQuery.isNotEmpty) return;

    final categoryIndex = _categories.indexOf(category);
    if (categoryIndex != -1 && categoryIndex != _selectedCategoryIndex) {
      setState(() {
        _selectedCategoryIndex = categoryIndex;
      });
    }
  }

  IconData _getCategoryIcon(ItemCategory category) {
    switch (category) {
      case ItemCategory.food:
        return Icons.restaurant;
      case ItemCategory.beverages:
        return Icons.local_drink;
      case ItemCategory.household:
        return Icons.home;
      case ItemCategory.electronics:
        return Icons.devices;
      case ItemCategory.tools:
        return Icons.build;
      case ItemCategory.outdoor:
      case ItemCategory.camping:
        return Icons.terrain;
      case ItemCategory.automotive:
        return Icons.directions_car;
      case ItemCategory.office:
        return Icons.work;
      case ItemCategory.medical:
        return Icons.medical_services;
      case ItemCategory.clothing:
        return Icons.checkroom;
      case ItemCategory.sports:
        return Icons.sports;
      case ItemCategory.garden:
        return Icons.grass;
      case ItemCategory.pets:
        return Icons.pets;
      case ItemCategory.crafts:
        return Icons.palette;
      case ItemCategory.music:
        return Icons.music_note;
      case ItemCategory.photography:
        return Icons.camera_alt;
      case ItemCategory.fishing:
        return Icons.phishing;
      case ItemCategory.hunting:
        return Icons.forest;
      case ItemCategory.safety:
        return Icons.security;
      case ItemCategory.cleaning:
        return Icons.cleaning_services;
      case ItemCategory.storage:
        return Icons.storage;
      case ItemCategory.kitchen:
        return Icons.kitchen;
      case ItemCategory.bathroom:
        return Icons.bathtub;
      case ItemCategory.furniture:
        return Icons.chair;
      case ItemCategory.lighting:
        return Icons.light;
      case ItemCategory.other:
        return Icons.inventory_2;
    }
  }
}
