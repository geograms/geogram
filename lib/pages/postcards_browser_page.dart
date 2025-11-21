/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/postcard.dart';
import '../services/postcard_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../widgets/postcard_tile_widget.dart';
import '../widgets/postcard_detail_widget.dart';
import '../dialogs/new_postcard_dialog.dart';

/// Postcards browser page with 2-panel layout
class PostcardsBrowserPage extends StatefulWidget {
  final String collectionPath;
  final String collectionTitle;

  const PostcardsBrowserPage({
    Key? key,
    required this.collectionPath,
    required this.collectionTitle,
  }) : super(key: key);

  @override
  State<PostcardsBrowserPage> createState() => _PostcardsBrowserPageState();
}

class _PostcardsBrowserPageState extends State<PostcardsBrowserPage> {
  final PostcardService _postcardService = PostcardService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final TextEditingController _searchController = TextEditingController();

  List<Postcard> _allPostcards = [];
  List<Postcard> _filteredPostcards = [];
  Postcard? _selectedPostcard;
  bool _isLoading = true;
  Set<int> _expandedYears = {};
  String? _currentUserNpub;
  String? _currentCallsign;
  String _statusFilter = 'all'; // all, in-transit, delivered, acknowledged, expired

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterPostcards);
    _initialize();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    // Get current user info
    final profile = _profileService.getProfile();
    _currentUserNpub = profile.npub;
    _currentCallsign = profile.callsign;

    // Initialize postcard service
    await _postcardService.initializeCollection(widget.collectionPath);

    await _loadPostcards();

    // Expand most recent year by default
    if (_allPostcards.isNotEmpty) {
      _expandedYears.add(_allPostcards.first.year);
    }
  }

  Future<void> _loadPostcards() async {
    setState(() => _isLoading = true);

    final postcards = await _postcardService.loadPostcards();

    setState(() {
      _allPostcards = postcards;
      _filteredPostcards = postcards;
      _isLoading = false;

      // Expand most recent year by default
      if (_allPostcards.isNotEmpty && _expandedYears.isEmpty) {
        _expandedYears.add(_allPostcards.first.year);
      }
    });

    _filterPostcards();

    // Auto-select the most recent postcard (first in the list)
    if (_allPostcards.isNotEmpty && _selectedPostcard == null) {
      await _selectPostcard(_allPostcards.first);
    }
  }

  void _filterPostcards() {
    final query = _searchController.text.toLowerCase();

    setState(() {
      var filtered = _allPostcards;

      // Apply status filter
      if (_statusFilter != 'all') {
        filtered = filtered.where((p) => p.status == _statusFilter).toList();
      }

      // Apply search filter
      if (query.isNotEmpty) {
        filtered = filtered.where((postcard) {
          return postcard.title.toLowerCase().contains(query) ||
                 postcard.senderCallsign.toLowerCase().contains(query) ||
                 (postcard.recipientCallsign?.toLowerCase().contains(query) ?? false) ||
                 postcard.content.toLowerCase().contains(query);
        }).toList();
      }

      _filteredPostcards = filtered;
    });
  }

  Future<void> _selectPostcard(Postcard postcard) async {
    // Load full postcard with all stamps
    final fullPostcard = await _postcardService.loadPostcard(postcard.id);
    setState(() {
      _selectedPostcard = fullPostcard;
    });
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

  void _setStatusFilter(String status) {
    setState(() {
      _statusFilter = status;
    });
    _filterPostcards();
  }

  Future<void> _createNewPostcard() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const NewPostcardDialog(),
    );

    if (result != null && mounted) {
      final profile = _profileService.getProfile();
      final postcard = await _postcardService.createPostcard(
        title: result['title'] as String,
        senderCallsign: profile.callsign,
        senderNpub: profile.npub!,
        recipientCallsign: result['recipientCallsign'] as String?,
        recipientNpub: result['recipientNpub'] as String,
        recipientLocations: result['recipientLocations'] as List<RecipientLocation>,
        type: result['type'] as String,
        content: result['content'] as String,
        ttl: result['ttl'] as int?,
        priority: result['priority'] as String? ?? 'normal',
        paymentRequested: result['paymentRequested'] as bool? ?? false,
      );

      if (postcard != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('postcard_created')),
            backgroundColor: Colors.green,
          ),
        );
        await _loadPostcards();
        await _selectPostcard(postcard);
      }
    }
  }

  int _getStatusCount(String status) {
    if (status == 'all') return _allPostcards.length;
    return _allPostcards.where((p) => p.status == status).length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('postcards')),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                // Left panel: Postcard list
                _buildPostcardList(theme),
                const VerticalDivider(width: 1),
                // Right panel: Postcard detail
                Expanded(child: _buildPostcardDetail(theme)),
              ],
            ),
    );
  }

  Widget _buildPostcardList(ThemeData theme) {
    return Container(
      width: 350,
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadPostcards,
                  tooltip: _i18n.t('refresh'),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _createNewPostcard,
                  tooltip: _i18n.t('new_postcard'),
                ),
              ],
            ),
          ),
          // Status filter chips
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildFilterChip('all', 'all', _getStatusCount('all'), theme),
                _buildFilterChip('in_transit', 'in-transit', _getStatusCount('in-transit'), theme),
                _buildFilterChip('delivered', 'delivered', _getStatusCount('delivered'), theme),
                _buildFilterChip('acknowledged', 'acknowledged', _getStatusCount('acknowledged'), theme),
                _buildFilterChip('expired', 'expired', _getStatusCount('expired'), theme),
              ],
            ),
          ),
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: _i18n.t('search_postcards'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _filterPostcards();
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          const Divider(height: 1),
          // Postcard list
          Expanded(
            child: _filteredPostcards.isEmpty
                ? _buildEmptyState(theme)
                : _buildYearGroupedList(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String status, int count, ThemeData theme) {
    final isSelected = _statusFilter == status;
    return FilterChip(
      label: Text('${_i18n.t(label)} ($count)'),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          _setStatusFilter(status);
        }
      },
      showCheckmark: false,
      selectedColor: theme.colorScheme.primaryContainer,
      labelStyle: TextStyle(
        color: isSelected
            ? theme.colorScheme.onPrimaryContainer
            : theme.colorScheme.onSurfaceVariant,
        fontSize: 12,
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.mail_outline,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _searchController.text.isNotEmpty || _statusFilter != 'all'
                  ? _i18n.t('no_matching_postcards')
                  : _i18n.t('no_postcards_yet'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchController.text.isNotEmpty || _statusFilter != 'all'
                  ? _i18n.t('try_different_search')
                  : _i18n.t('create_first_postcard'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildYearGroupedList(ThemeData theme) {
    // Group postcards by year
    final Map<int, List<Postcard>> postcardsByYear = {};
    for (var postcard in _filteredPostcards) {
      postcardsByYear.putIfAbsent(postcard.year, () => []).add(postcard);
    }

    final years = postcardsByYear.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      itemCount: years.length,
      itemBuilder: (context, index) {
        final year = years[index];
        final postcards = postcardsByYear[year]!;
        final isExpanded = _expandedYears.contains(year);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Year header
            Material(
              color: theme.colorScheme.surfaceVariant,
              child: InkWell(
                onTap: () => _toggleYear(year),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isExpanded
                            ? Icons.expand_more
                            : Icons.chevron_right,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        year.toString(),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${postcards.length} ${postcards.length == 1 ? _i18n.t('postcard') : _i18n.t('postcards')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Postcards for this year
            if (isExpanded)
              ...postcards.map((postcard) => PostcardTileWidget(
                    postcard: postcard,
                    isSelected: _selectedPostcard?.id == postcard.id,
                    onTap: () => _selectPostcard(postcard),
                  )),
          ],
        );
      },
    );
  }

  Widget _buildPostcardDetail(ThemeData theme) {
    if (_selectedPostcard == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.mail_outline,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('select_postcard_to_view'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    final isSender = _selectedPostcard!.senderCallsign == _currentCallsign;
    final isRecipient = _selectedPostcard!.recipientCallsign == _currentCallsign;

    return PostcardDetailWidget(
      postcard: _selectedPostcard!,
      collectionPath: widget.collectionPath,
      currentCallsign: _currentCallsign,
      currentUserNpub: _currentUserNpub,
      isSender: isSender,
      isRecipient: isRecipient,
      onRefresh: () async {
        final updated = await _postcardService.loadPostcard(_selectedPostcard!.id);
        setState(() {
          _selectedPostcard = updated;
        });
        await _loadPostcards(); // Reload list to update counts
      },
    );
  }
}
