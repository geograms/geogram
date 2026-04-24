/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'package:flutter/material.dart';

import '../services/i18n_service.dart';
import '../services/location_service.dart';

/// Full-screen picker backed by the worldcities database bundled at
/// `assets/worldcities.csv` (~44 000 cities). Returns the picked
/// [CityEntry] via Navigator.pop, or null if the user backs out.
///
/// Live search: every keystroke (debounced 150 ms) re-ranks the full
/// dataset via [LocationService.searchCitiesByName] and surfaces the
/// top matches, biased toward population.
class CityPickerPage extends StatefulWidget {
  const CityPickerPage({super.key});

  @override
  State<CityPickerPage> createState() => _CityPickerPageState();
}

class _CityPickerPageState extends State<CityPickerPage> {
  final _i18n = I18nService();
  final _locationService = LocationService();
  final _queryController = TextEditingController();
  final _focusNode = FocusNode();

  List<CityEntry> _matches = const [];
  bool _loading = true;
  Timer? _debounce;
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _queryController.addListener(_onQueryChanged);
    _runSearch('');
    // Pop the keyboard straight away so the user can type.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      _runSearch(_queryController.text);
    });
  }

  Future<void> _runSearch(String query) async {
    final seq = ++_searchSeq;
    setState(() => _loading = true);
    final results = await _locationService.searchCitiesByName(query, limit: 80);
    // Drop the result if a newer keystroke has already kicked off another
    // search — prevents out-of-order UI updates during fast typing.
    if (!mounted || seq != _searchSeq) return;
    setState(() {
      _matches = results;
      _loading = false;
    });
  }

  String _subtitleFor(CityEntry c) {
    final bits = <String>[];
    if (c.adminName.isNotEmpty) bits.add(c.adminName);
    if (c.country.isNotEmpty) bits.add(c.country);
    return bits.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _queryController.text.trim();

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('pick_a_city')),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _queryController,
              focusNode: _focusNode,
              autofocus: true,
              decoration: InputDecoration(
                hintText: _i18n.t('city_search_hint'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: _i18n.t('clear'),
                        onPressed: () => _queryController.clear(),
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              textInputAction: TextInputAction.search,
            ),
          ),
          if (_loading && _matches.isEmpty)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_matches.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  query.isEmpty
                      ? _i18n.t('city_search_hint')
                      : _i18n.t('no_cities_found'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: _matches.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final c = _matches[i];
                  return ListTile(
                    leading: const Icon(Icons.location_city),
                    title: Text(c.city),
                    subtitle: Text(_subtitleFor(c)),
                    trailing: c.iso2.isNotEmpty
                        ? Text(
                            c.iso2,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          )
                        : null,
                    onTap: () => Navigator.pop(context, c),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
