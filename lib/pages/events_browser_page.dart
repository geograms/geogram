/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../models/event.dart';
import '../models/event_link.dart';
import '../services/event_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../widgets/event_tile_widget.dart';
import '../widgets/event_detail_widget.dart';
import '../dialogs/new_event_dialog.dart';
import '../dialogs/new_update_dialog.dart';
import 'event_settings_page.dart';

/// Events browser page with 2-panel layout
class EventsBrowserPage extends StatefulWidget {
  final String collectionPath;
  final String collectionTitle;

  const EventsBrowserPage({
    Key? key,
    required this.collectionPath,
    required this.collectionTitle,
  }) : super(key: key);

  @override
  State<EventsBrowserPage> createState() => _EventsBrowserPageState();
}

class _EventsBrowserPageState extends State<EventsBrowserPage> {
  final EventService _eventService = EventService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final TextEditingController _searchController = TextEditingController();

  List<Event> _allEvents = [];
  List<Event> _filteredEvents = [];
  Event? _selectedEvent;
  bool _isLoading = true;
  Set<int> _expandedYears = {};
  String? _currentUserNpub;
  String? _currentCallsign;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterEvents);
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

    // Initialize event service
    await _eventService.initializeCollection(widget.collectionPath);

    await _loadEvents();

    // Expand most recent year by default
    if (_allEvents.isNotEmpty) {
      _expandedYears.add(_allEvents.first.year);
    }
  }

  Future<void> _loadEvents() async {
    setState(() => _isLoading = true);

    final events = await _eventService.loadEvents(
      currentCallsign: _currentCallsign,
      currentUserNpub: _currentUserNpub,
    );

    setState(() {
      _allEvents = events;
      _filteredEvents = events;
      _isLoading = false;

      // Expand most recent year by default
      if (_allEvents.isNotEmpty && _expandedYears.isEmpty) {
        _expandedYears.add(_allEvents.first.year);
      }
    });

    _filterEvents();

    // Auto-select the most recent event (first in the list)
    if (_allEvents.isNotEmpty && _selectedEvent == null) {
      await _selectEvent(_allEvents.first);
    }
  }

  void _filterEvents() {
    final query = _searchController.text.toLowerCase();

    setState(() {
      if (query.isEmpty) {
        _filteredEvents = _allEvents;
      } else {
        _filteredEvents = _allEvents.where((event) {
          return event.title.toLowerCase().contains(query) ||
                 event.location.toLowerCase().contains(query) ||
                 (event.locationName?.toLowerCase().contains(query) ?? false) ||
                 event.content.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  Future<void> _selectEvent(Event event) async {
    // Load full event with all features
    final fullEvent = await _eventService.loadEvent(event.id);
    setState(() {
      _selectedEvent = fullEvent;
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

  Future<void> _createNewEvent() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const NewEventDialog(),
    );

    if (result != null && mounted) {
      final profile = _profileService.getProfile();
      final event = await _eventService.createEvent(
        author: profile.callsign,
        title: result['title'] as String,
        eventDate: result['eventDate'] as DateTime?,
        startDate: result['startDate'] as String?,
        endDate: result['endDate'] as String?,
        location: result['location'] as String,
        locationName: result['locationName'] as String?,
        content: result['content'] as String,
        npub: profile.npub,
      );

      if (event != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('event_created')),
            backgroundColor: Colors.green,
          ),
        );
        await _loadEvents();
        await _selectEvent(event);
      }
    }
  }

  Future<void> _likeEvent() async {
    if (_selectedEvent == null || _currentCallsign == null) return;

    final success = await _eventService.addLike(
      eventId: _selectedEvent!.id,
      callsign: _currentCallsign!,
    );

    if (success && mounted) {
      // Reload event
      final updatedEvent = await _eventService.loadEvent(_selectedEvent!.id);
      setState(() {
        _selectedEvent = updatedEvent;
      });
    }
  }

  Future<void> _unlikeEvent() async {
    if (_selectedEvent == null || _currentCallsign == null) return;

    final success = await _eventService.removeLike(
      eventId: _selectedEvent!.id,
      callsign: _currentCallsign!,
    );

    if (success && mounted) {
      // Reload event
      final updatedEvent = await _eventService.loadEvent(_selectedEvent!.id);
      setState(() {
        _selectedEvent = updatedEvent;
      });
    }
  }

  Future<void> _editEvent() async {
    if (_selectedEvent == null) return;

    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => EventSettingsPage(
          event: _selectedEvent!,
          collectionPath: widget.collectionPath,
        ),
      ),
    );

    if (result != null && mounted) {
      print('EventsBrowserPage: Received result from settings page: $result');
      final newEventId = await _eventService.updateEvent(
        eventId: _selectedEvent!.id,
        title: result['title'] as String,
        location: result['location'] as String,
        locationName: result['locationName'] as String?,
        content: result['content'] as String,
        agenda: result['agenda'] as String?,
        visibility: result['visibility'] as String?,
        admins: result['admins'] as List<String>?,
        moderators: result['moderators'] as List<String>?,
        eventDateTime: result['eventDateTime'] as DateTime?,
        startDate: result['startDate'] as String?,
        endDate: result['endDate'] as String?,
        // Use empty string to signal "remove trailer", vs null meaning "don't update"
        trailerFileName: result.containsKey('trailer')
            ? (result['trailer'] as String? ?? '')  // null becomes empty string
            : null,  // key not present means don't update trailer
        links: result['links'] as List<EventLink>?,
        registrationEnabled: result['registrationEnabled'] as bool?,
      );

      if (newEventId != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('event_updated')),
            backgroundColor: Colors.green,
          ),
        );
        // Reload event using the new ID (in case folder was renamed)
        final updatedEvent = await _eventService.loadEvent(newEventId);
        setState(() {
          _selectedEvent = updatedEvent;
        });
        await _loadEvents();
      }
    }
  }

  Future<void> _uploadFiles() async {
    if (_selectedEvent == null) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        dialogTitle: _i18n.t('select_files_to_add'),
      );

      if (result != null && result.files.isNotEmpty && mounted) {
        final year = _selectedEvent!.id.substring(0, 4);
        final eventPath = '${widget.collectionPath}/events/$year/${_selectedEvent!.id}';

        int copiedCount = 0;
        for (var file in result.files) {
          if (file.path != null) {
            final sourceFile = File(file.path!);
            final targetPath = '$eventPath/${file.name}';

            try {
              await sourceFile.copy(targetPath);
              copiedCount++;
            } catch (e) {
              print('Error copying file ${file.name}: $e');
            }
          }
        }

        if (copiedCount > 0 && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_i18n.t('files_uploaded', params: [copiedCount.toString()])),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_i18n.t('error')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _createUpdate() async {
    if (_selectedEvent == null) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const NewUpdateDialog(),
    );

    if (result != null && mounted) {
      final profile = _profileService.getProfile();
      final update = await _eventService.createUpdate(
        eventId: _selectedEvent!.id,
        title: result['title'] as String,
        author: profile.callsign,
        content: result['content'] as String,
        npub: profile.npub,
      );

      if (update != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('update_created')),
            backgroundColor: Colors.green,
          ),
        );
        // Reload event to show the new update
        final updatedEvent = await _eventService.loadEvent(_selectedEvent!.id);
        setState(() {
          _selectedEvent = updatedEvent;
        });
        await _loadEvents();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('events')),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                // Left panel: Event list
                _buildEventList(theme),
                const VerticalDivider(width: 1),
                // Right panel: Event detail
                Expanded(child: _buildEventDetail(theme)),
              ],
            ),
    );
  }

  Widget _buildEventList(ThemeData theme) {
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
                  onPressed: _loadEvents,
                  tooltip: _i18n.t('refresh'),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _createNewEvent,
                  tooltip: _i18n.t('new_event'),
                ),
              ],
            ),
          ),
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: _i18n.t('search_events'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _filterEvents();
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
          // Event list
          Expanded(
            child: _filteredEvents.isEmpty
                ? _buildEmptyState(theme)
                : _buildYearGroupedList(theme),
          ),
        ],
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
              Icons.event_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _searchController.text.isNotEmpty
                  ? _i18n.t('no_matching_events')
                  : _i18n.t('no_events_yet'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchController.text.isNotEmpty
                  ? _i18n.t('try_different_search')
                  : _i18n.t('create_first_event'),
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
    // Group events by year
    final Map<int, List<Event>> eventsByYear = {};
    for (var event in _filteredEvents) {
      eventsByYear.putIfAbsent(event.year, () => []).add(event);
    }

    final years = eventsByYear.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      itemCount: years.length,
      itemBuilder: (context, index) {
        final year = years[index];
        final events = eventsByYear[year]!;
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
                        '${events.length} ${events.length == 1 ? _i18n.t('event') : _i18n.t('events')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Events for this year
            if (isExpanded)
              ...events.map((event) => EventTileWidget(
                    event: event,
                    isSelected: _selectedEvent?.id == event.id,
                    onTap: () => _selectEvent(event),
                  )),
          ],
        );
      },
    );
  }

  Widget _buildEventDetail(ThemeData theme) {
    if (_selectedEvent == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.event_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('select_event_to_view'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    final canEdit = _selectedEvent!.canEdit(_currentCallsign ?? '', _currentUserNpub);
    final hasLiked = _selectedEvent!.hasUserLiked(_currentCallsign ?? '');

    return EventDetailWidget(
      event: _selectedEvent!,
      collectionPath: widget.collectionPath,
      currentCallsign: _currentCallsign,
      currentUserNpub: _currentUserNpub,
      canEdit: canEdit,
      hasLiked: hasLiked,
      onLike: hasLiked ? _unlikeEvent : _likeEvent,
      onEdit: _editEvent,
      onUploadFiles: _uploadFiles,
      onCreateUpdate: _createUpdate,
      onRefresh: () async {
        final updated = await _eventService.loadEvent(_selectedEvent!.id);
        setState(() {
          _selectedEvent = updated;
        });
      },
    );
  }
}
