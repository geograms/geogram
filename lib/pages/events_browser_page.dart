/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import '../models/event.dart';
import '../models/event_link.dart';
import '../models/event_registration.dart';
import '../services/event_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../widgets/event_tile_widget.dart';
import '../widgets/event_detail_widget.dart';
import 'event_detail_page.dart';
import 'new_event_page.dart';
import '../dialogs/new_update_dialog.dart';
import 'event_settings_page.dart';

/// Events browser page with 2-panel layout
/// Supports both local collection viewing and remote device viewing via API
class EventsBrowserPage extends StatefulWidget {
  final String? collectionPath;
  final String? collectionTitle;

  // Remote device viewing parameters (like ChatBrowserPage)
  final String? remoteDeviceUrl;
  final String? remoteDeviceCallsign;
  final String? remoteDeviceName;

  const EventsBrowserPage({
    Key? key,
    this.collectionPath,
    this.collectionTitle,
    this.remoteDeviceUrl,
    this.remoteDeviceCallsign,
    this.remoteDeviceName,
  }) : super(key: key);

  /// Whether viewing events from a remote device
  bool get isRemoteDevice => remoteDeviceUrl != null;

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

    if (widget.isRemoteDevice) {
      // Remote device mode - load from API
      LogService().log('EventsBrowserPage: Remote device mode - loading from ${widget.remoteDeviceUrl}');
      await _loadRemoteEvents();
    } else {
      // Local mode - initialize event service with collection path
      if (widget.collectionPath != null) {
        await _eventService.initializeCollection(widget.collectionPath!);
      }
      await _loadEvents();
    }

    // Expand most recent year by default
    if (_allEvents.isNotEmpty) {
      _expandedYears.add(_allEvents.first.year);
    }
  }

  /// Load events from remote device via API
  Future<void> _loadRemoteEvents({bool showLoading = true}) async {
    if (widget.remoteDeviceUrl == null) return;

    if (showLoading) {
      setState(() => _isLoading = true);
    }

    try {
      final url = '${widget.remoteDeviceUrl}/api/events';
      LogService().log('EventsBrowserPage: Fetching remote events from $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final eventsList = data['events'] as List<dynamic>? ?? [];

        final events = <Event>[];
        for (var eventJson in eventsList) {
          try {
            final event = Event.fromApiJson(eventJson as Map<String, dynamic>);
            events.add(event);
          } catch (e) {
            LogService().log('EventsBrowserPage: Error parsing event: $e');
          }
        }

        // Sort by date (newest first)
        events.sort((a, b) => b.timestamp.compareTo(a.timestamp));

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

        // Auto-select the most recent event
        if (_allEvents.isNotEmpty && _selectedEvent == null) {
          await _selectRemoteEvent(_allEvents.first);
        }

        LogService().log('EventsBrowserPage: Loaded ${events.length} remote events');
      } else {
        LogService().log('EventsBrowserPage: Failed to fetch events: ${response.statusCode}');
        setState(() => _isLoading = false);
      }
    } catch (e) {
      LogService().log('EventsBrowserPage: Error fetching remote events: $e');
      setState(() => _isLoading = false);
    }
  }

  /// Select and load full details for a remote event
  Future<void> _selectRemoteEvent(Event event) async {
    if (widget.remoteDeviceUrl == null) return;

    try {
      final baseUri = Uri.parse(widget.remoteDeviceUrl!);
      final url = baseUri.replace(
        pathSegments: [...baseUri.pathSegments, 'api', 'events', event.id],
      );
      LogService().log('EventsBrowserPage: Fetching remote event details from $url');

      final response = await http.get(
        url,
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final fullEvent = Event.fromApiJson(data);
        setState(() {
          _selectedEvent = fullEvent;
        });
      } else {
        // Fall back to summary event
        setState(() {
          _selectedEvent = event;
        });
      }
    } catch (e) {
      LogService().log('EventsBrowserPage: Error fetching remote event details: $e');
      setState(() {
        _selectedEvent = event;
      });
    }
  }

  Future<void> _loadEvents({bool showLoading = true}) async {
    if (showLoading) {
      setState(() => _isLoading = true);
    }

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

  Future<void> _refreshSelectedEvent() async {
    if (_selectedEvent == null) return;
    final updatedEvent = await _eventService.loadEvent(_selectedEvent!.id);
    if (updatedEvent == null || !mounted) return;
    setState(() {
      _selectedEvent = updatedEvent;
      final allIndex = _allEvents.indexWhere((e) => e.id == updatedEvent.id);
      if (allIndex != -1) {
        _allEvents[allIndex] = updatedEvent;
      }
      final filteredIndex = _filteredEvents.indexWhere((e) => e.id == updatedEvent.id);
      if (filteredIndex != -1) {
        _filteredEvents[filteredIndex] = updatedEvent;
      }
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
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => const NewEventPage(),
        fullscreenDialog: true,
      ),
    );

    if (result != null && mounted) {
      final profile = _profileService.getProfile();
      final metadata = _buildEventMetadata(result);
      final event = await _eventService.createEvent(
        author: profile.callsign,
        title: result['title'] as String,
        eventDate: result['eventDate'] as DateTime?,
        startDate: result['startDate'] as String?,
        endDate: result['endDate'] as String?,
        location: result['location'] as String,
        locationName: result['locationName'] as String?,
        content: result['content'] as String,
        agenda: result['agenda'] as String?,
        visibility: result['visibility'] as String?,
        admins: result['admins'] as List<String>?,
        moderators: result['moderators'] as List<String>?,
        groupAccess: result['groupAccess'] as List<String>?,
        npub: profile.npub,
        metadata: metadata,
      );

      if (event != null && mounted) {
        await _applyEventExtras(event.id, result, profile.callsign, profile.npub);
        final refreshedEvent = await _eventService.loadEvent(event.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('event_created')),
            backgroundColor: Colors.green,
          ),
        );
        await _loadEvents();
        await _selectEvent(refreshedEvent ?? event);
      }
    }
  }

  Future<void> _applyEventExtras(
    String eventId,
    Map<String, dynamic> result,
    String callsign,
    String? npub,
  ) async {
    if (widget.collectionPath == null) return;

    final links = (result['links'] as List<dynamic>?)
            ?.map((link) => link as EventLink)
            .toList() ??
        [];
    if (links.isNotEmpty) {
      await _writeLinksFile(eventId, links);
    }

    final registrationEnabled = result['registrationEnabled'] as bool?;
    if (registrationEnabled == true) {
      await _ensureRegistrationFile(eventId);
    }

    final updates = (result['updates'] as List<dynamic>?)
            ?.map((entry) => Map<String, String>.from(entry as Map))
            .toList() ??
        [];
    for (final update in updates) {
      final title = update['title'];
      final content = update['content'];
      if (title == null || content == null) continue;
      await _eventService.createUpdate(
        eventId: eventId,
        title: title,
        author: callsign,
        content: content,
        npub: npub,
      );
    }

    final flyerFiles = (result['flyers'] as List<dynamic>?)
            ?.map((entry) => Map<String, String>.from(entry as Map))
            .toList() ??
        [];
    if (flyerFiles.isNotEmpty) {
      await _copyPendingFiles(eventId, flyerFiles, ensureUnique: false);
    }

    final trailer = result['trailer'] as Map<String, String>?;
    if (trailer != null && trailer.isNotEmpty) {
      await _copyPendingFiles(eventId, [trailer], ensureUnique: false);
    }

    final mediaFiles = (result['mediaFiles'] as List<dynamic>?)
            ?.map((entry) => Map<String, String>.from(entry as Map))
            .toList() ??
        [];
    if (mediaFiles.isNotEmpty) {
      await _copyPendingFiles(eventId, mediaFiles, ensureUnique: true);
    }
  }

  Map<String, String>? _buildEventMetadata(Map<String, dynamic> result) {
    if (!result.containsKey('placePath')) return null;
    final placePath = (result['placePath'] as String?)?.trim() ?? '';
    final normalized = _normalizePlacePath(placePath);
    return {'place_path': normalized ?? placePath};
  }

  String? _normalizePlacePath(String placePath) {
    if (placePath.isEmpty) return '';
    if (widget.collectionPath == null || widget.collectionPath!.isEmpty) {
      return placePath;
    }
    if (path.isAbsolute(placePath)) {
      final basePath = path.dirname(widget.collectionPath!);
      final relative = path.relative(placePath, from: basePath);
      if (!relative.startsWith('..')) {
        return relative;
      }
    }
    return placePath;
  }

  Future<void> _writeLinksFile(String eventId, List<EventLink> links) async {
    if (widget.collectionPath == null || links.isEmpty) return;
    final eventPath = _eventFolderPath(eventId);
    final linksFile = File('$eventPath/links.txt');
    await linksFile.writeAsString(
      EventLinksParser.toText(links),
      flush: true,
    );
  }

  Future<void> _ensureRegistrationFile(String eventId) async {
    if (widget.collectionPath == null) return;
    final eventPath = _eventFolderPath(eventId);
    final registrationFile = File('$eventPath/registration.txt');
    if (await registrationFile.exists()) return;
    final empty = EventRegistration();
    await registrationFile.writeAsString(
      empty.exportAsText(),
      flush: true,
    );
  }

  Future<void> _copyPendingFiles(
    String eventId,
    List<Map<String, String>> files, {
    required bool ensureUnique,
  }) async {
    if (widget.collectionPath == null) return;
    final eventPath = _eventFolderPath(eventId);

    for (final file in files) {
      final sourcePath = file['sourcePath'];
      final targetName = file['targetName'];
      if (sourcePath == null || sourcePath.isEmpty) continue;
      if (targetName == null || targetName.isEmpty) continue;

      String finalName = targetName;
      if (ensureUnique) {
        finalName = await _ensureUniqueFileName(eventPath, targetName);
      }

      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) continue;
      await sourceFile.copy('$eventPath/$finalName');
    }
  }

  String _eventFolderPath(String eventId) {
    final year = eventId.substring(0, 4);
    return '${widget.collectionPath}/events/$year/$eventId';
  }

  Future<String> _ensureUniqueFileName(String dirPath, String fileName) async {
    final ext = path.extension(fileName);
    final base = path.basenameWithoutExtension(fileName);
    var candidate = fileName;
    var suffix = 1;
    while (await File('$dirPath/$candidate').exists()) {
      candidate = '${base}_$suffix$ext';
      suffix++;
    }
    return candidate;
  }

  Future<void> _editEvent() async {
    if (_selectedEvent == null) return;

    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => EventSettingsPage(
          event: _selectedEvent!,
          collectionPath: widget.collectionPath ?? '',
        ),
      ),
    );

    if (result != null && mounted) {
      print('EventsBrowserPage: Received result from settings page: $result');
      final metadata = _buildEventMetadata(result);
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
        groupAccess: result['groupAccess'] as List<String>?,
        eventDateTime: result['eventDateTime'] as DateTime?,
        startDate: result['startDate'] as String?,
        endDate: result['endDate'] as String?,
        // Use empty string to signal "remove trailer", vs null meaning "don't update"
        trailerFileName: result.containsKey('trailer')
            ? (result['trailer'] as String? ?? '')  // null becomes empty string
            : null,  // key not present means don't update trailer
        links: result['links'] as List<EventLink>?,
        registrationEnabled: result['registrationEnabled'] as bool?,
        metadata: metadata,
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

    // Build title - show device name for remote viewing
    final title = widget.isRemoteDevice
        ? '${_i18n.t('events')} - ${widget.remoteDeviceName ?? widget.remoteDeviceCallsign ?? ''}'
        : _i18n.t('events');

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      floatingActionButton: widget.isRemoteDevice
          ? null
          : FloatingActionButton.extended(
              onPressed: _createNewEvent,
              icon: const Icon(Icons.add),
              label: Text(_i18n.t('add')),
            ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                // Use two-panel layout for wide screens, single panel for narrow
                final isWideScreen = constraints.maxWidth >= 600;

                if (isWideScreen) {
                  // Desktop/landscape: Two-panel layout
                  return Row(
                    children: [
                      // Left panel: Event list
                      _buildEventList(theme),
                      const VerticalDivider(width: 1),
                      // Right panel: Event detail
                      Expanded(child: _buildEventDetail(theme)),
                    ],
                  );
                } else {
                  // Mobile/portrait: Single panel
                  // Show event list, detail opens in full screen
                  return _buildEventList(theme, isMobileView: true);
                }
              },
            ),
    );
  }

  Widget _buildEventList(ThemeData theme, {bool isMobileView = false}) {
    final refreshHandler = widget.isRemoteDevice
        ? () => _loadRemoteEvents(showLoading: false)
        : () => _loadEvents(showLoading: false);
    final listContent = _filteredEvents.isEmpty
        ? (isMobileView ? _buildEmptyStateScrollable(theme) : _buildEmptyState(theme))
        : _buildYearGroupedList(theme, isMobileView: isMobileView);
    final listBody = isMobileView
        ? RefreshIndicator(onRefresh: refreshHandler, child: listContent)
        : listContent;

    return Container(
      width: isMobileView ? null : 350,
      color: theme.colorScheme.surface,
      child: Column(
        children: [
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
            child: listBody,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: _buildEmptyStateContent(theme),
      ),
    );
  }

  Widget _buildEmptyStateScrollable(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _buildEmptyStateContent(theme),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyStateContent(ThemeData theme) {
    return Column(
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
    );
  }

  Widget _buildYearGroupedList(ThemeData theme, {bool isMobileView = false}) {
    // Group events by year
    final Map<int, List<Event>> eventsByYear = {};
    for (var event in _filteredEvents) {
      eventsByYear.putIfAbsent(event.year, () => []).add(event);
    }

    final years = eventsByYear.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      physics: isMobileView ? const AlwaysScrollableScrollPhysics() : null,
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
                    collectionPath: widget.collectionPath,
                    onTap: () {
                      if (widget.isRemoteDevice) {
                        _selectRemoteEvent(event);
                      } else if (isMobileView) {
                        _selectEventMobile(event);
                      } else {
                        _selectEvent(event);
                      }
                    },
                  )),
          ],
        );
      },
    );
  }

  Future<void> _selectEventMobile(Event event) async {
    // Load full event with all features
    final fullEvent = await _eventService.loadEvent(event.id);

    if (!mounted || fullEvent == null) return;

    // Navigate to full-screen detail view
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => EventDetailPage(
          event: fullEvent,
          collectionPath: widget.collectionPath ?? '',
          eventService: _eventService,
          profileService: _profileService,
          i18n: _i18n,
          currentUserNpub: _currentUserNpub,
          currentCallsign: _currentCallsign,
        ),
      ),
    );

    // Reload events if changes were made
    if (result == true && mounted) {
      await _loadEvents();
    }
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

    // Disable editing for remote events
    final canEdit = widget.isRemoteDevice
        ? false
        : _selectedEvent!.canEdit(_currentCallsign ?? '', _currentUserNpub);

    return EventDetailWidget(
      event: _selectedEvent!,
      collectionPath: widget.collectionPath ?? '',
      currentCallsign: _currentCallsign,
      currentUserNpub: _currentUserNpub,
      canEdit: canEdit,
      // Disable edit/upload for remote events
      onEdit: widget.isRemoteDevice ? null : _editEvent,
      onUploadFiles: widget.isRemoteDevice ? null : _uploadFiles,
      onCreateUpdate: widget.isRemoteDevice ? null : _createUpdate,
      onFeedbackUpdated: widget.isRemoteDevice ? null : _refreshSelectedEvent,
    );
  }
}
