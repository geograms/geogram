/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import '../models/event.dart';
import '../models/event_link.dart';
import '../models/event_registration.dart';
import '../services/app_service.dart';
import '../services/config_service.dart';
import '../services/devices_service.dart';
import '../services/event_pin_service.dart';
import '../services/event_service.dart';
import '../services/profile_service.dart';
import '../services/profile_storage.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/remote_content_client.dart';
import '../services/remote_event_cache.dart';
import '../util/event_activity_notifier.dart';
import '../widgets/event_tile_widget.dart';
import '../widgets/event_detail_widget.dart';
import '../widgets/file_folder_picker.dart';
import 'event_detail_page.dart';
import 'new_event_page.dart';
import 'remote_events_browser_page.dart' show RemoteEventDetailPage;
import '../dialogs/new_update_dialog.dart';

/// Events browser page with 2-panel layout
/// Supports both local collection viewing and remote device viewing via API
class EventsBrowserPage extends StatefulWidget {
  final String? appPath;
  final String? appTitle;

  // Remote device viewing parameters (like ChatBrowserPage)
  final String? remoteDeviceUrl;
  final String? remoteDeviceCallsign;
  final String? remoteDeviceName;

  const EventsBrowserPage({
    Key? key,
    this.appPath,
    this.appTitle,
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

  // Default: showing my own events (the ones I authored). The toggle
  // icon next to the search bar shows the OPPOSITE mode so the user
  // sees what they\'re about to switch to — globe to switch to
  // "events from everyone else", person to switch back to "mine".
  // Last choice persists in ConfigService under the key below so a
  // visitor who left the page on the global view returns to it.
  bool _showMineOnly = true;
  static const String _scopePrefKey = 'eventsBrowser.showMineOnly';

  // Events fetched from every reachable device when the user
  // switches to the global scope. Lazy-loaded on first toggle and
  // refreshed on demand. Kept separate from _allEvents so flipping
  // back to "mine" is instant — no need to re-scan local storage.
  List<Event> _remoteEvents = const [];
  bool _isLoadingRemote = false;
  bool _remoteLoadedOnce = false;

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

    // Restore the user\'s last scope choice (mine vs global). New
    // installs default to "mine" — same as the previous behaviour.
    final savedScope =
        ConfigService().get(_scopePrefKey, true) as bool? ?? true;
    _showMineOnly = savedScope;

    if (widget.isRemoteDevice) {
      // Remote device mode - load from API
      LogService().log('EventsBrowserPage: Remote device mode - loading from ${widget.remoteDeviceUrl}');
      await _loadRemoteEvents();
    } else {
      // Local mode - initialize event service with collection path
      if (widget.appPath != null) {
        // Set profile storage for encrypted storage support
        final profileStorage = AppService().profileStorage;
        if (profileStorage != null) {
          final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
            profileStorage,
            widget.appPath!,
          );
          _eventService.setStorage(scopedStorage);
        } else {
          _eventService.setStorage(FilesystemProfileStorage(widget.appPath!));
        }
        await _eventService.initializeApp(widget.appPath!);
      }
      await _loadEvents();
      // If the user left the page on the global scope last time,
      // fetch remote events now so the UI lands populated rather
      // than empty + needing a manual toggle.
      if (!_showMineOnly && !widget.isRemoteDevice) {
        // Fire-and-forget; the load updates state when it lands.
        // ignore: discarded_futures
        _loadGlobalEvents();
        _filterEvents();
      }
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

    final accumulated = <Event>[];
    bool firstBatch = true;

    await for (final batch in _eventService.loadEventSummariesStream(
      currentCallsign: _currentCallsign,
      currentUserNpub: _currentUserNpub,
    )) {
      accumulated.addAll(batch);
      // Keep sorted by date (most recent first)
      accumulated.sort((a, b) => b.dateTime.compareTo(a.dateTime));

      setState(() {
        _allEvents = List.of(accumulated);
        _isLoading = false;

        // Expand most recent year on first batch
        if (firstBatch && _allEvents.isNotEmpty && _expandedYears.isEmpty) {
          _expandedYears.add(_allEvents.first.year);
        }
      });

      _filterEvents();

      // Auto-select the most recent event on first batch
      if (firstBatch && _allEvents.isNotEmpty && _selectedEvent == null) {
        _selectEvent(_allEvents.first);
      }
      firstBatch = false;
    }

    // Handle empty collection
    if (accumulated.isEmpty) {
      setState(() {
        _allEvents = [];
        _filteredEvents = [];
        _isLoading = false;
      });
    }

    // Re-emit NowItemEvents for any unseen event activity (access
    // requests, comments, likes…) still on disk. NowService is in-
    // memory, so a desktop restart loses the entries. Loading the
    // events browser is a natural moment to repopulate them even
    // though the apps-page also kicks the same scan at startup.
    if (!widget.isRemoteDevice && widget.appPath != null) {
      EventActivityNotifier.scanAll(widget.appPath!);
    }
  }

  void _filterEvents() {
    final query = _searchController.text.toLowerCase();
    final myNpub = _currentUserNpub;
    final myCallsign = _currentCallsign?.toUpperCase();

    bool isMine(Event event) {
      if (myNpub != null && myNpub.isNotEmpty && event.npub == myNpub) {
        return true;
      }
      if (myCallsign != null && myCallsign.isNotEmpty &&
          event.author.toUpperCase() == myCallsign) {
        return true;
      }
      return false;
    }

    setState(() {
      // Scope picks which source list to draw from:
      // - mine   → local events filtered to "authored by me"
      // - global → events fetched from every reachable device,
      //            already filtered to "not me" at fetch time
      Iterable<Event> scoped = _showMineOnly
          ? _allEvents.where(isMine)
          : _remoteEvents;
      List<Event> result;
      if (query.isEmpty) {
        result = scoped.toList();
      } else {
        result = scoped.where((event) {
          return event.title.toLowerCase().contains(query) ||
                 event.location.toLowerCase().contains(query) ||
                 (event.locationName?.toLowerCase().contains(query) ?? false) ||
                 event.content.toLowerCase().contains(query);
        }).toList();
      }
      // Pinned events float to the top regardless of date / scope.
      // Inside each group (pinned, not pinned) the original order is
      // preserved — _allEvents / _remoteEvents are already sorted
      // by date so the date sort survives.
      final pinnedKeys = EventPinService.all();
      result.sort((a, b) {
        final aPinned = pinnedKeys.contains(EventPinService.keyFor(a));
        final bPinned = pinnedKeys.contains(EventPinService.keyFor(b));
        if (aPinned != bPinned) return aPinned ? -1 : 1;
        return b.dateTime.compareTo(a.dateTime);
      });
      _filteredEvents = result;
    });
  }

  /// Fan out an /api/content/events query to every device the local
  /// app knows about (via DevicesService), drop anything authored by
  /// the local user, then dedupe by author npub + event id so a
  /// callsign mirrored across two devices doesn\'t show twice.
  ///
  /// Uses the shared RemoteContent.listAcrossDevices helper — same
  /// universal surface that drives the remote-device browse pages,
  /// so a new app type just needs its own list call.
  Future<void> _loadGlobalEvents() async {
    if (_isLoadingRemote) return;
    setState(() => _isLoadingRemote = true);
    try {
      final myCallsign = _currentCallsign?.toUpperCase();
      final myNpub = _currentUserNpub;
      final callsigns = DevicesService()
          .getAllDevices()
          .map((d) => d.callsign.toUpperCase())
          .where((cs) => cs.isNotEmpty && cs != myCallsign)
          .toSet();
      if (callsigns.isEmpty) {
        if (!mounted) return;
        setState(() {
          _remoteEvents = const [];
          _remoteLoadedOnce = true;
          _isLoadingRemote = false;
        });
        _filterEvents();
        return;
      }
      final items = await RemoteContent.listAcrossDevices(
        callsigns: callsigns,
        appType: 'events',
      );
      final out = <Event>[];
      final dedup = <String>{};
      for (final entry in items) {
        try {
          final raw = Event.fromApiJson(entry.item);
          // Skip events authored by us (a mirror of our own data
          // sitting on someone else\'s device).
          if (myNpub != null && myNpub.isNotEmpty && raw.npub == myNpub) {
            continue;
          }
          if (myCallsign != null &&
              myCallsign.isNotEmpty &&
              raw.author.toUpperCase() == myCallsign) {
            continue;
          }
          // Tag the event with the device callsign that served it so
          // the tap handler can open the remote detail page.
          final ev = raw.copyWith(metadata: {
            ...raw.metadata,
            'source_callsign': entry.sourceCallsign,
          });
          // Author npub + event id is the strongest dedupe key —
          // catches the same event served by multiple mirrors of
          // the same user.
          final key = '${ev.npub ?? ev.author}|${ev.id}';
          if (!dedup.add(key)) continue;
          out.add(ev);
        } catch (_) {}
      }
      out.sort((a, b) => b.dateTime.compareTo(a.dateTime));
      if (!mounted) return;
      setState(() {
        _remoteEvents = out;
        _remoteLoadedOnce = true;
        _isLoadingRemote = false;
      });
      _filterEvents();
      // Fire-and-forget cache warmup so re-opening the same events
      // is fast next time (and works at all when the device drops
      // off the network). Doesn\'t block the UI.
      _warmupRemoteEventCache(out);
    } catch (e) {
      LogService().log('EventsBrowserPage: remote load failed: $e');
      if (!mounted) return;
      setState(() => _isLoadingRemote = false);
    }
  }

  /// Persist event.txt + primary thumbnail + likes + comments for
  /// each remote event under {baseDir}/devices/{author}/events/.
  /// This is an offgrid app — we want as much of the event
  /// reachable offline as we can, then lazy-update on the next
  /// online window. The gallery photos still cache lazily (only
  /// what the user actually opens) since they\'re too big to fetch
  /// upfront for events with hundreds of pictures.
  Future<void> _warmupRemoteEventCache(List<Event> events) async {
    for (final ev in events) {
      final source = ev.metadata['source_callsign'];
      if (source == null || source.isEmpty) continue;
      try {
        // 1. Pull the full detail so we get the canonical likes +
        //    comments arrays (the list-summary endpoint only carries
        //    counts). Skip the rest of this iteration if the device
        //    is unreachable — the next visit retries.
        final detail = await RemoteContent.get(
          remoteCallsign: source,
          appType: 'events',
          itemId: ev.id,
        );
        if (!detail.success || detail.data == null) {
          // Even when the detail fails, persist whatever we already
          // have from the list (event.txt) so the cache isn\'t empty.
          await RemoteEventCache.writeEvent(
            authorCallsign: source,
            event: ev,
          );
          continue;
        }
        Event fullEvent;
        try {
          fullEvent = Event.fromApiJson(detail.data!);
        } catch (_) {
          fullEvent = ev;
        }
        // 2. event.txt with the full payload (uses Event.exportAsText
        //    so the on-disk format matches what the local
        //    EventService writes).
        await RemoteEventCache.writeEvent(
          authorCallsign: source,
          event: fullEvent,
        );
        // 3. Likes (one npub per line in feedback/likes.txt).
        final likes = (detail.data!['likes'] as List?)
                ?.whereType<String>()
                .toList() ??
            const <String>[];
        await RemoteEventCache.writeLikes(
          authorCallsign: source,
          eventId: ev.id,
          npubs: likes,
        );
        // 4. Comments (one signed file per id under
        //    feedback/comments/) — same format the local
        //    FeedbackCommentUtils writes.
        final comments = (detail.data!['comments'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            const <Map<String, dynamic>>[];
        if (comments.isNotEmpty) {
          await RemoteEventCache.writeComments(
            authorCallsign: source,
            eventId: ev.id,
            comments: comments,
          );
        }
        // 5. Primary flyer thumbnail (~50 KB), only when the author
        //    has chosen one. Other photos cache lazily as the user
        //    opens them via the lightbox.
        final flyer = fullEvent.flyer;
        if (flyer != null && flyer.isNotEmpty) {
          final existing = await RemoteEventCache.readFile(
            authorCallsign: source,
            eventId: ev.id,
            relativePath: flyer,
          );
          if (existing == null) {
            final resp =
                await DevicesService().makeDeviceApiRequestBytes(
              callsign: source,
              method: 'GET',
              path: '${RemoteContent.filePath(
                appType: 'events',
                itemId: ev.id,
                relativePath: flyer,
              )}?thumb=1',
            );
            if (resp != null && resp.statusCode == 200) {
              await RemoteEventCache.writeFile(
                authorCallsign: source,
                eventId: ev.id,
                relativePath: flyer,
                bytes: resp.bytes,
              );
            }
          }
        }
      } catch (_) {
        // Cache warmup is best-effort; never poison the live load.
      }
    }
  }

  Future<void> _selectEvent(Event event) async {
    // Remote events (fetched from another device's /api/content)
    // carry the source callsign in metadata. Open them in the
    // already-existing remote detail page rather than trying to
    // load them from local storage.
    final sourceCallsign = event.metadata['source_callsign'];
    if (sourceCallsign != null && sourceCallsign.isNotEmpty) {
      final device = DevicesService().getDevice(sourceCallsign);
      if (device != null && mounted) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => RemoteEventDetailPage(
            device: device,
            eventId: event.id,
          ),
        ));
      }
      return;
    }
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
        unlistedKey: result['unlistedKey'] as String?,
        accessCallsigns:
            (result['accessCallsigns'] as List<dynamic>?)?.cast<String>(),
        accessRequestPrompt: result['accessRequestPrompt'] as String?,
        commentsEnabled: (result['commentsEnabled'] as bool?) ?? true,
        contributionsEnabled:
            (result['contributionsEnabled'] as bool?) ?? false,
        contacts: (result['contacts'] as List<dynamic>?)?.cast<String>(),
        npub: profile.npub,
        metadata: metadata,
        customSlug: result['customSlug'] as String?,
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
    if (widget.appPath == null) return;

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

    final photoFiles = (result['photos'] as List<dynamic>?)
            ?.map((entry) => Map<String, String>.from(entry as Map))
            .toList() ??
        [];
    if (photoFiles.isNotEmpty) {
      await _copyPendingFiles(eventId, photoFiles, ensureUnique: false);
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
    if (widget.appPath == null || widget.appPath!.isEmpty) {
      return placePath;
    }
    if (path.isAbsolute(placePath)) {
      final basePath = path.dirname(widget.appPath!);
      final relative = path.relative(placePath, from: basePath);
      if (!relative.startsWith('..')) {
        return relative;
      }
    }
    return placePath;
  }

  Future<void> _writeLinksFile(String eventId, List<EventLink> links) async {
    if (widget.appPath == null || links.isEmpty) return;
    final eventPath = _eventFolderPath(eventId);
    final linksFile = File('$eventPath/links.txt');
    await linksFile.writeAsString(
      EventLinksParser.toText(links),
      flush: true,
    );
  }

  Future<void> _ensureRegistrationFile(String eventId) async {
    if (widget.appPath == null) return;
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
    if (widget.appPath == null) return;
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
    return '${widget.appPath}/$year/$eventId';
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
        builder: (context) => NewEventPage(
          event: _selectedEvent!,
          appPath: widget.appPath ?? '',
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
        unlistedKey: result['unlistedKey'] as String?,
        accessCallsigns:
            (result['accessCallsigns'] as List<dynamic>?)?.cast<String>(),
        accessRequestPrompt: result['accessRequestPrompt'] as String?,
        commentsEnabled: result['commentsEnabled'] as bool?,
        contributionsEnabled: result['contributionsEnabled'] as bool?,
        eventDateTime: result['eventDateTime'] as DateTime?,
        startDate: result['startDate'] as String?,
        endDate: result['endDate'] as String?,
        // Use empty string to signal "remove trailer", vs null meaning "don't update"
        trailerFileName: result.containsKey('trailer')
            ? (result['trailer'] as String? ?? '')  // null becomes empty string
            : null,  // key not present means don't update trailer
        links: result['links'] as List<EventLink>?,
        registrationEnabled: result['registrationEnabled'] as bool?,
        contacts: (result['contacts'] as List<dynamic>?)?.cast<String>(),
        metadata: metadata,
        customSlug: result['customSlug'] as String?,
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

  /// Edit event from the tile's three-dot menu
  Future<void> _editEventFromTile(Event event) async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => NewEventPage(
          event: event,
          appPath: widget.appPath ?? '',
        ),
      ),
    );

    if (result != null && mounted) {
      final metadata = _buildEventMetadata(result);
      final newEventId = await _eventService.updateEvent(
        eventId: event.id,
        title: result['title'] as String,
        location: result['location'] as String,
        locationName: result['locationName'] as String?,
        content: result['content'] as String,
        agenda: result['agenda'] as String?,
        visibility: result['visibility'] as String?,
        admins: result['admins'] as List<String>?,
        moderators: result['moderators'] as List<String>?,
        groupAccess: result['groupAccess'] as List<String>?,
        unlistedKey: result['unlistedKey'] as String?,
        accessCallsigns:
            (result['accessCallsigns'] as List<dynamic>?)?.cast<String>(),
        accessRequestPrompt: result['accessRequestPrompt'] as String?,
        commentsEnabled: result['commentsEnabled'] as bool?,
        contributionsEnabled: result['contributionsEnabled'] as bool?,
        eventDateTime: result['eventDateTime'] as DateTime?,
        startDate: result['startDate'] as String?,
        endDate: result['endDate'] as String?,
        trailerFileName: result.containsKey('trailer')
            ? (result['trailer'] as String? ?? '')
            : null,
        links: result['links'] as List<EventLink>?,
        registrationEnabled: result['registrationEnabled'] as bool?,
        contacts: (result['contacts'] as List<dynamic>?)?.cast<String>(),
        metadata: metadata,
        customSlug: result['customSlug'] as String?,
      );

      if (newEventId != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('event_updated')),
            backgroundColor: Colors.green,
          ),
        );
        // Reload events list
        await _loadEvents();
        // Update selected event if it was the one edited
        if (_selectedEvent?.id == event.id) {
          final updatedEvent = await _eventService.loadEvent(newEventId);
          setState(() {
            _selectedEvent = updatedEvent;
          });
        }
      }
    }
  }

  /// Delete event from the tile's three-dot menu
  Future<void> _deleteEventFromTile(Event event) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_event')),
        content: Text(_i18n.t('delete_event_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final success = await _eventService.deleteEvent(event.id);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('event_deleted')),
            backgroundColor: Colors.green,
          ),
        );
        // Clear selection if this was the selected event
        if (_selectedEvent?.id == event.id) {
          setState(() {
            _selectedEvent = null;
          });
        }
        // Reload events list
        await _loadEvents();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('delete_failed')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _uploadFiles() async {
    if (_selectedEvent == null) return;

    try {
      final paths = await FileFolderPicker.show(
        context,
        title: _i18n.t('select_files_to_add'),
        allowMultiSelect: true,
        profileStorage: AppService().profileStorage,
      );

      if (paths != null && paths.isNotEmpty && mounted) {
        final year = _selectedEvent!.id.substring(0, 4);
        final eventPath = '${widget.appPath}/$year/${_selectedEvent!.id}';

        // Collect existing photo names for renaming
        final existingFlyers = List<String>.from(_selectedEvent!.photos);

        int copiedCount = 0;
        for (var filePath in paths) {
          final fileName = path.basename(filePath);
          final sourceFile = File(filePath);
          final ext = path.extension(fileName).replaceFirst('.', '').toLowerCase();
          final isImage = const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg']
              .contains(ext);

          String targetName;
          if (isImage) {
            targetName = EventService.nextFlyerName(existingFlyers, ext);
            existingFlyers.add(targetName);
          } else {
            targetName = fileName;
          }

          final targetPath = '$eventPath/$targetName';

          try {
            await sourceFile.copy(targetPath);
            copiedCount++;
          } catch (e) {
            print('Error copying file $fileName: $e');
          }
        }

        if (copiedCount > 0 && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_i18n.t('files_uploaded', params: [copiedCount.toString()])),
              backgroundColor: Colors.green,
            ),
          );
          await _refreshSelectedEvent();
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
              label: Text(_i18n.t('create')),
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
          // Search bar + scope toggle. The icon to the right of the
          // search field flips the visible scope between the user\'s
          // own events and everyone else\'s. We show the icon for the
          // OTHER scope (globe when viewing mine, person when viewing
          // everyone\'s) so it telegraphs what tapping does next.
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
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
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: _showMineOnly
                      ? (_i18n.t('events_show_global') ??
                          'Show events from everyone')
                      : (_i18n.t('events_show_mine') ?? 'Show my events'),
                  icon: _isLoadingRemote
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_showMineOnly ? Icons.public : Icons.person),
                  onPressed: () {
                    setState(() => _showMineOnly = !_showMineOnly);
                    // Persist so the next session opens on the same
                    // scope. Fire-and-forget — write failures here
                    // would only mean the next session opens on the
                    // default, which is acceptable.
                    ConfigService().set(_scopePrefKey, _showMineOnly);
                    if (!_showMineOnly && !_remoteLoadedOnce) {
                      _loadGlobalEvents();
                    }
                    _filterEvents();
                  },
                ),
              ],
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
    final hasQuery = _searchController.text.isNotEmpty;
    // Three flavours of empty state:
    // 1. user is searching → "no match / try different search"
    // 2. global scope (no events from others discovered yet) →
    //    explain that remote-event discovery isn\'t hooked up yet
    //    so they don\'t mistake an empty list for a bug.
    // 3. mine scope → the existing "no events yet / create one"
    final String titleKey;
    final String subtitleKey;
    final IconData icon;
    if (hasQuery) {
      titleKey = 'no_matching_events';
      subtitleKey = 'try_different_search';
      icon = Icons.event_outlined;
    } else if (!_showMineOnly) {
      titleKey = 'no_global_events_yet';
      subtitleKey = 'no_global_events_help';
      icon = Icons.public;
    } else {
      titleKey = 'no_events_yet';
      subtitleKey = 'create_first_event';
      icon = Icons.event_outlined;
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          icon,
          size: 64,
          color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
        ),
        const SizedBox(height: 16),
        Text(
          _i18n.t(titleKey),
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _i18n.t(subtitleKey),
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

    // Build flat item list: year headers + event entries for expanded years
    // This avoids eagerly building all tiles for expanded years.
    final flatItems = <_ListItem>[];
    for (final year in years) {
      final events = eventsByYear[year]!;
      flatItems.add(_ListItem.header(year, events.length));
      if (_expandedYears.contains(year)) {
        for (final event in events) {
          flatItems.add(_ListItem.event(event));
        }
      }
    }

    return ListView.builder(
      physics: isMobileView ? const AlwaysScrollableScrollPhysics() : null,
      itemCount: flatItems.length,
      itemBuilder: (context, index) {
        final item = flatItems[index];

        if (item.isHeader) {
          final isExpanded = _expandedYears.contains(item.year);
          return Material(
            color: theme.colorScheme.surfaceVariant,
            child: InkWell(
              onTap: () => _toggleYear(item.year!),
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
                      item.year.toString(),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${item.eventCount} ${item.eventCount == 1 ? _i18n.t('event') : _i18n.t('events')}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // Event tile
        final event = item.event!;
        final canModify = !widget.isRemoteDevice;
        return EventTileWidget(
          event: event,
          isSelected: _selectedEvent?.id == event.id,
          appPath: widget.appPath,
          isPinned: EventPinService.isPinned(event),
          onTogglePin: () {
            EventPinService.toggle(event);
            _filterEvents();
          },
          onTap: () {
            if (widget.isRemoteDevice) {
              _selectRemoteEvent(event);
            } else if (isMobileView) {
              _selectEventMobile(event);
            } else {
              _selectEvent(event);
            }
          },
          onEdit: canModify ? () => _editEventFromTile(event) : null,
          onDelete: canModify ? () => _deleteEventFromTile(event) : null,
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
          appPath: widget.appPath ?? '',
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
      appPath: widget.appPath ?? '',
      currentCallsign: _currentCallsign,
      currentUserNpub: _currentUserNpub,
      canEdit: canEdit,
      // Disable edit/upload for remote events
      onEdit: widget.isRemoteDevice ? null : _editEvent,
      onUploadFiles: widget.isRemoteDevice ? null : _uploadFiles,
      onCreateUpdate: widget.isRemoteDevice ? null : _createUpdate,
      onFeedbackUpdated: widget.isRemoteDevice ? null : _refreshSelectedEvent,
      onContactsUpdated: widget.isRemoteDevice ? null : _updateEventContacts,
    );
  }

  /// Update contacts for the selected event
  Future<void> _updateEventContacts(List<String> contacts) async {
    if (_selectedEvent == null) return;

    final newEventId = await _eventService.updateEvent(
      eventId: _selectedEvent!.id,
      title: _selectedEvent!.title,
      location: _selectedEvent!.location,
      locationName: _selectedEvent!.locationName,
      content: _selectedEvent!.content,
      agenda: _selectedEvent!.agenda,
      visibility: _selectedEvent!.visibility,
      contacts: contacts,
    );

    if (newEventId != null && mounted) {
      // Reload event to show updated contacts
      final updatedEvent = await _eventService.loadEvent(newEventId);
      setState(() {
        _selectedEvent = updatedEvent;
      });
    }
  }
}

/// Flat list item for year-grouped ListView.builder
class _ListItem {
  final int? year;
  final int eventCount;
  final Event? event;

  bool get isHeader => year != null && event == null;

  _ListItem.header(this.year, this.eventCount) : event = null;
  _ListItem.event(this.event) : year = null, eventCount = 0;
}
