/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:latlong2/latlong.dart';

import '../dialogs/new_update_dialog.dart';
import '../models/app.dart';
import '../models/contact.dart';
import '../models/event.dart';
import '../models/event_link.dart';
import '../models/group.dart';
import '../models/place.dart';
import '../services/app_service.dart';
import '../services/event_service.dart';
import '../services/groups_service.dart';
import '../services/profile_service.dart';
import '../services/profile_storage.dart';
import '../services/i18n_service.dart';
import '../services/log_api_service.dart';
import '../util/event_activity_notifier.dart';
import '../services/location_service.dart';
import '../widgets/file_folder_picker.dart';
import '../widgets/transcribe_button_widget.dart';
import 'contact_picker_page.dart';
import 'location_picker_page.dart';
import 'place_picker_page.dart';

/// Full-screen page for creating or editing an event
class NewEventPage extends StatefulWidget {
  /// If provided, the page is in edit mode for this event
  final Event? event;

  /// Required when editing an event
  final String? appPath;

  /// Initial tab index to show. Defaults to 0 (Basic info). Used by deep
  /// links (e.g. tapping an access-request notification in the Now panel
  /// jumps straight to the Access control tab).
  final int initialTab;

  const NewEventPage({
    Key? key,
    this.event,
    this.appPath,
    this.initialTab = 0,
  }) : super(key: key);

  /// Whether this page is in edit mode
  bool get isEditMode => event != null;

  @override
  State<NewEventPage> createState() => _NewEventPageState();
}

class _PendingFile {
  final String path;
  final String name;
  final String targetName;

  const _PendingFile({
    required this.path,
    required this.name,
    required this.targetName,
  });

  Map<String, String> toMap() => {
        'sourcePath': path,
        'targetName': targetName,
      };
}

class _PendingUpdate {
  final String title;
  final String content;

  const _PendingUpdate({
    required this.title,
    required this.content,
  });

  Map<String, String> toMap() => {
        'title': title,
        'content': content,
      };
}

class _GroupOption {
  final Group group;
  final String? appTitle;

  const _GroupOption(this.group, this.appTitle);
}

class _NewEventPageState extends State<NewEventPage>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _i18n = I18nService();
  final ImagePicker _imagePicker = ImagePicker();

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  late TabController _tabController;

  final _titleController = TextEditingController();
  final _slugController = TextEditingController();
  final _locationController = TextEditingController();
  final _locationNameController = TextEditingController();
  final _contentController = TextEditingController();
  final _agendaController = TextEditingController();

  bool _isMultiDay = false;
  DateTime _eventDate = DateTime.now();
  TimeOfDay? _eventTime;
  DateTime? _startDate;
  DateTime? _endDate;
  String _locationType = 'coordinates'; // 'coordinates', 'place', 'online'
  Place? _selectedPlace;

  String _visibility = 'private';
  String? _unlistedKey;
  // Per-callsign access grants — applies to private / group / request_access
  // events alongside the existing group selector. Picker-driven (no manual
  // text input) so the author selects entries from their existing contacts;
  // persisted as the ACCESS_CALLSIGNS: comma-list in event.txt.
  final Map<String, ContactPickerResult> _accessCallsigns = {};
  // Optional prompt the author writes for `request_access` events. Shown
  // to blocked viewers above the request form so they know what kind of
  // note to send. Persisted as ACCESS_REQUEST_PROMPT: in event.txt.
  final TextEditingController _accessRequestPromptController =
      TextEditingController();
  // Pending / decided access requests (request_access events only). Each
  // entry: {npub, callsign, message, requested_at, status, decided_at?}.
  // Loaded from {event}/feedback/access_requests.json on init.
  final List<Map<String, dynamic>> _accessRequests = [];
  // NOSTR-signed comments persisted in {event}/feedback/comments/*.txt.
  // Each entry: {id, author, timestamp, content, npub?}. Loaded on init
  // when in edit mode so the author can review and delete inline.
  final List<Map<String, dynamic>> _comments = [];
  // Whether visitors can post NOSTR-signed comments on the public event
  // page. Default true so the toggle starts in the "permissive" position.
  bool _commentsEnabled = true;
  bool _registrationEnabled = false;

  final Map<String, TextEditingController> _agendaByDate = {};
  final List<EventLink> _links = [];
  final List<_PendingUpdate> _updates = [];
  final List<_PendingFile> _flyers = [];
  _PendingFile? _trailer;
  final List<_PendingFile> _mediaFiles = [];
  final List<_GroupOption> _availableGroups = [];
  final Set<String> _selectedGroups = {};
  bool _isLoadingGroups = true;

  // Contacts - stored as map of callsign -> ContactPickerResult for display names
  final Map<String, ContactPickerResult> _selectedContacts = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 6,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 5),
    );
    _loadGroups();

    // Populate fields from event when in edit mode
    if (widget.isEditMode) {
      _populateFromEvent(widget.event!);
      _loadAccessRequests();
      _loadComments();
      // Once the owner has the editor open they're aware of any new
      // comments + likes — flush the unseen markers so the tile + apps
      // grid badge reflect that. Access requests are unaffected
      // (they're acknowledged by approve/deny, not by mere viewing).
      _markEventActivitySeen();
    }
  }

  /// Read NOSTR-signed comments from disk so the Access tab can list
  /// them with delete buttons. Mirrors [_loadAccessRequests] in shape.
  Future<void> _loadComments() async {
    final event = widget.event;
    final appPath = widget.appPath;
    if (event == null || appPath == null || appPath.isEmpty) return;
    if (event.id.length < 4) return;
    try {
      final year = event.id.substring(0, 4);
      final dir = Directory('$appPath/$year/${event.id}/feedback/comments');
      if (!await dir.exists()) return;
      final entries = <Map<String, dynamic>>[];
      await for (final f in dir.list()) {
        if (f is! File || !f.path.endsWith('.txt')) continue;
        final id = f.path.split(Platform.pathSeparator).last
            .replaceAll('.txt', '');
        try {
          final raw = await f.readAsString();
          String author = '';
          String created = '';
          String? npub;
          final bodyLines = <String>[];
          var inMeta = true;
          for (final line in raw.split('\n')) {
            if (inMeta && line.startsWith('AUTHOR: ')) {
              author = line.substring(8).trim();
            } else if (inMeta && line.startsWith('CREATED: ')) {
              created = line.substring(9).trim();
            } else if (line.startsWith('--> npub: ')) {
              npub = line.substring(10).trim();
            } else if (line.startsWith('--> signature: ')) {
              // skip
            } else if (line.trim().isEmpty && inMeta) {
              inMeta = false;
            } else if (!inMeta) {
              bodyLines.add(line);
            }
          }
          entries.add({
            'id': id,
            'author': author,
            'timestamp': created,
            'content': bodyLines.join('\n').trim(),
            if (npub != null) 'npub': npub,
          });
        } catch (_) {}
      }
      // Newest first so the latest activity is on top.
      entries.sort((a, b) =>
          (b['timestamp'] as String).compareTo(a['timestamp'] as String));
      if (!mounted) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(entries);
      });
    } catch (_) {}
  }

  /// Delete a comment via the shared DELETE endpoint. Authorisation is
  /// "comment author or event owner" — the editor only ever runs in the
  /// author's seat, so the owner's npub is what we send.
  Future<void> _deleteComment(String commentId) async {
    final event = widget.event;
    if (event == null) return;
    final ownerNpub = ProfileService().getProfile().npub;
    if (ownerNpub.isEmpty) return;
    try {
      final port = LogApiService().port;
      final uri = Uri.parse(
        'http://127.0.0.1:$port/api/feedback/event/'
        '${Uri.encodeComponent(event.id)}'
        '/comment/${Uri.encodeComponent(commentId)}',
      );
      final req = await HttpClient().deleteUrl(uri);
      req.headers.set('X-Npub', ownerNpub);
      final resp = await req.close();
      if (resp.statusCode >= 200 && resp.statusCode < 300 && mounted) {
        setState(() {
          _comments.removeWhere((c) => c['id'] == commentId);
        });
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n
                .t('delete_failed_http')
                .replaceAll('{0}', '${resp.statusCode}')),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('delete_comment_failed'))),
      );
    }
  }

  /// Mark every unseen comment + like on this event as seen so the
  /// tile/app-grid badges clear. Best-effort.
  Future<void> _markEventActivitySeen() async {
    final event = widget.event;
    final appPath = widget.appPath;
    if (event == null || appPath == null || appPath.isEmpty) return;
    if (event.id.length < 4) return;
    try {
      final year = event.id.substring(0, 4);
      await EventActivityNotifier.markAllSeen(
        eventPath: '$appPath/$year/${event.id}',
      );
    } catch (_) {}
  }

  /// Loads pending / decided access requests from the event's feedback
  /// folder. Only meaningful for `request_access` events but reading is
  /// cheap so we always try — non-existent file just leaves the list empty.
  Future<void> _loadAccessRequests() async {
    final event = widget.event;
    final appPath = widget.appPath;
    if (event == null || appPath == null || appPath.isEmpty) return;
    if (event.id.length < 4) return;
    try {
      final year = event.id.substring(0, 4);
      final file = File('$appPath/$year/${event.id}/feedback/access_requests.json');
      if (!await file.exists()) return;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return;
      final list = jsonDecode(content) as List<dynamic>;
      if (!mounted) return;
      setState(() {
        _accessRequests
          ..clear()
          ..addAll(list.whereType<Map<String, dynamic>>());
      });
    } catch (e) {
      // Corrupted or unreadable file — leave the list empty so the UI
      // simply doesn't show the inbox section.
    }
  }

  /// Approve or deny an access request. Hits the same /api/events endpoint
  /// the desktop server exposes so the side effects (writing the decision
  /// + appending the callsign to ACCESS_CALLSIGNS on approve) live in one
  /// place. After the response, refreshes the local list and adds the
  /// approved callsign to the chip set so the editor reflects the change.
  Future<void> _decideAccessRequest(
      Map<String, dynamic> entry, String action) async {
    final event = widget.event;
    if (event == null) return;
    final npub = (entry['npub'] as String?)?.trim() ?? '';
    if (npub.isEmpty) return;
    try {
      final port = LogApiService().port;
      final uri = Uri.parse(
        'http://127.0.0.1:$port/api/events/'
        '${Uri.encodeComponent(event.id)}'
        '/access-requests/${Uri.encodeComponent(npub)}/$action',
      );
      final resp = await HttpClient().postUrl(uri).then((req) async {
        req.headers.set('Content-Type', 'application/json');
        req.write('{}');
        return req.close();
      });
      if (resp.statusCode >= 200 && resp.statusCode < 300 && mounted) {
        setState(() {
          entry['status'] = action == 'approve' ? 'approved' : 'denied';
          entry['decided_at'] = DateTime.now().toUtc().toIso8601String();
          if (action == 'approve') {
            final cs = ((entry['callsign'] as String?) ?? '').trim().toUpperCase();
            if (cs.isNotEmpty && !_accessCallsigns.containsKey(cs)) {
              _accessCallsigns[cs] = ContactPickerResult(
                contact: Contact(
                  callsign: cs,
                  displayName: cs,
                  created: '',
                  firstSeen: '',
                ),
              );
            }
          }
        });
      }
    } catch (_) {
      // Surface failure with a snackbar — but keep the existing entry as
      // pending so the owner can retry.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('access_request_update_failed'))),
      );
    }
  }

  /// Number of access requests still waiting on the owner's decision.
  int get _pendingAccessRequestCount => _accessRequests
      .where((e) => ((e['status'] as String?) ?? 'pending') == 'pending')
      .length;

  /// Builds the "Access control" tab label. When there are pending
  /// requests on the event, a red badge with the count is anchored next
  /// to the label so the owner sees that this tab needs their attention
  /// without having to open it. Wrapping the whole label in a Tooltip
  /// surfaces a one-line hint pointing them straight at the action.
  Widget _buildAccessControlTabLabel() {
    final pending = _pendingAccessRequestCount;
    final theme = Theme.of(context);
    final label = Text(_i18n.t('access_control'));
    if (pending == 0) return label;
    return Tooltip(
      message: pending == 1
          ? _i18n.t('access_request_count_one')
          : _i18n
              .t('access_request_count_many')
              .replaceAll('{0}', '$pending'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          label,
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.error,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$pending',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onError,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _populateFromEvent(Event event) {
    _titleController.text = event.title;
    _contentController.text = event.content;
    _agendaController.text = event.agenda ?? '';
    _locationNameController.text = event.locationName ?? '';

    // Populate slug from event
    if (event.slug != null && event.slug!.isNotEmpty) {
      _slugController.text = event.slug!;
    }

    // Location type
    if (event.isOnline) {
      _locationType = 'online';
    } else if (event.location == 'other') {
      _locationType = 'other';
    } else if (event.placePath != null && event.placePath!.isNotEmpty) {
      _locationType = 'place';
      // Note: Place object would need to be loaded separately if needed
    } else {
      _locationType = 'coordinates';
      _locationController.text = event.location;
    }

    // Dates
    _isMultiDay = event.isMultiDay;
    if (event.isMultiDay) {
      _startDate = _parseDate(event.startDate ?? '');
      _endDate = _parseDate(event.endDate ?? '');
    } else {
      _eventDate = event.dateTime;
      _eventTime = TimeOfDay.fromDateTime(event.dateTime);
    }

    // Visibility and access
    _visibility = event.visibility;
    _unlistedKey = event.unlistedKey;
    _selectedGroups.addAll(event.groupAccess);
    // Seed the access-callsign chip set with placeholder ContactPickerResult
    // entries for each persisted callsign — same trick the contacts loader
    // uses below so the chips render even when the contact isn't in the
    // local address book yet (e.g. someone who'd previously requested access).
    for (final callsign in event.accessCallsigns) {
      _accessCallsigns[callsign] = ContactPickerResult(
        contact: Contact(
          callsign: callsign,
          displayName: callsign,
          created: '',
          firstSeen: '',
        ),
      );
    }
    if (event.accessRequestPrompt != null) {
      _accessRequestPromptController.text = event.accessRequestPrompt!;
    }
    _commentsEnabled = event.commentsEnabled;
    // Note: registrationEnabled not yet stored in Event model

    // Links
    _links.addAll(event.links);

    // Contacts - create placeholder ContactPickerResult for each callsign
    for (final callsign in event.contacts) {
      _selectedContacts[callsign] = ContactPickerResult(
        contact: Contact(
          callsign: callsign,
          displayName: callsign, // Will show callsign as display name
          created: '',
          firstSeen: '',
        ),
      );
    }

    // Load existing flyers/photos
    if (widget.appPath != null && event.flyers.isNotEmpty) {
      final year = event.id.substring(0, 4);
      final eventFolderPath = '${widget.appPath}/$year/${event.id}';
      for (final flyerName in event.flyers) {
        final flyerPath = '$eventFolderPath/$flyerName';
        if (File(flyerPath).existsSync()) {
          _flyers.add(_PendingFile(
            path: flyerPath,
            name: flyerName,
            targetName: flyerName,
          ));
        }
      }
    }

    // Load existing trailer
    if (widget.appPath != null && event.trailer != null) {
      final year = event.id.substring(0, 4);
      final eventFolderPath = '${widget.appPath}/$year/${event.id}';
      final trailerPath = '$eventFolderPath/${event.trailer}';
      if (File(trailerPath).existsSync()) {
        _trailer = _PendingFile(
          path: trailerPath,
          name: event.trailer!,
          targetName: event.trailer!,
        );
      }
    }
  }

  DateTime? _parseDate(String dateStr) {
    try {
      if (dateStr.isEmpty) return null;
      return DateTime.parse(dateStr);
    } catch (e) {
      return null;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleController.dispose();
    _slugController.dispose();
    _locationController.dispose();
    _locationNameController.dispose();
    _contentController.dispose();
    _agendaController.dispose();
    _accessRequestPromptController.dispose();
    for (final controller in _agendaByDate.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _selectEventDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _eventDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        _eventDate = picked;
      });
    }
  }

  Future<void> _selectEventTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _eventTime ?? TimeOfDay.now(),
    );

    if (picked != null) {
      setState(() {
        _eventTime = picked;
      });
    }
  }

  Future<void> _selectStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        _startDate = picked;
        if (_endDate != null && _endDate!.isBefore(_startDate!)) {
          _endDate = null;
        }
        _syncAgendaControllers();
      });
    }
  }

  Future<void> _selectEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? _startDate ?? DateTime.now(),
      firstDate: _startDate ?? DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        _endDate = picked;
        _syncAgendaControllers();
      });
    }
  }

  void _syncAgendaControllers() {
    final dates = _getAgendaDates();
    final dateKeys = dates.map(_formatDate).toSet();

    for (final key in _agendaByDate.keys.toList()) {
      if (!dateKeys.contains(key)) {
        _agendaByDate[key]?.dispose();
        _agendaByDate.remove(key);
      }
    }

    for (final key in dateKeys) {
      if (!_agendaByDate.containsKey(key)) {
        _agendaByDate[key] = TextEditingController();
      }
    }
  }

  List<DateTime> _getAgendaDates() {
    if (!_isMultiDay || _startDate == null || _endDate == null) return [];

    final start = DateTime(_startDate!.year, _startDate!.month, _startDate!.day);
    final end = DateTime(_endDate!.year, _endDate!.month, _endDate!.day);
    if (end.isBefore(start)) return [];

    final days = end.difference(start).inDays;
    return List.generate(days + 1, (index) => start.add(Duration(days: index)));
  }

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  String _formatTime(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _openMapPicker() async {
    LatLng? initialPosition;
    if (_locationController.text.isNotEmpty) {
      final parts = _locationController.text.split(',');
      if (parts.length == 2) {
        final lat = double.tryParse(parts[0].trim());
        final lon = double.tryParse(parts[1].trim());
        if (lat != null && lon != null) {
          initialPosition = LatLng(lat, lon);
        }
      }
    }

    final result = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (context) => LocationPickerPage(
          initialPosition: initialPosition,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _locationController.text =
            '${result.latitude.toStringAsFixed(6)},${result.longitude.toStringAsFixed(6)}';
        _selectedPlace = null;
      });

      // Find nearest city and set location name
      final nearestCity = await LocationService().findNearestCity(
        result.latitude,
        result.longitude,
      );
      if (nearestCity != null && mounted) {
        setState(() {
          _locationNameController.text = '${nearestCity.city}, ${nearestCity.country}';
        });
      }
    }
  }

  Future<void> _openPlacePicker() async {
    final result = await Navigator.push<PlacePickerResult>(
      context,
      MaterialPageRoute(
        builder: (context) => PlacePickerPage(i18n: _i18n),
      ),
    );

    if (result != null) {
      final place = result.place;
      final langCode = _i18n.currentLanguage.split('_').first.toUpperCase();
      final placeName = place.getName(langCode);
      setState(() {
        _selectedPlace = place;
        _locationType = 'place';
        _locationController.clear();
        _locationNameController.text = placeName;
      });
    }
  }

  void _clearSelectedPlace() {
    setState(() {
      _selectedPlace = null;
    });
  }

  Future<void> _selectTrailer() async {
    String? filePath;

    if (_isMobile) {
      final video = await _imagePicker.pickVideo(source: ImageSource.gallery);
      filePath = video?.path;
    } else {
      final paths = await FileFolderPicker.show(
        context,
        title: _i18n.t('select_trailer_video'),
        allowMultiSelect: false,
        allowedExtensions: FileFolderPicker.videoExtensions,
        profileStorage: AppService().profileStorage,
      );
      filePath = (paths != null && paths.isNotEmpty) ? paths.first : null;
    }

    if (filePath != null) {
      final originalFileName = path.basename(filePath);
      final extension = path.extension(originalFileName).replaceFirst('.', '').toLowerCase();
      final trailerFileName = extension.isNotEmpty
          ? 'trailer.$extension'
          : 'trailer.mp4';

      setState(() {
        _trailer = _PendingFile(
          path: filePath!,
          name: originalFileName,
          targetName: trailerFileName,
        );
      });
    }
  }

  void _removeTrailer() {
    setState(() {
      _trailer = null;
    });
  }

  Future<void> _selectFlyer() async {
    String? filePath;

    if (_isMobile) {
      final image = await _imagePicker.pickImage(source: ImageSource.gallery);
      filePath = image?.path;
    } else {
      final paths = await FileFolderPicker.show(
        context,
        title: _i18n.t('select_flyer_image'),
        allowMultiSelect: false,
        allowedExtensions: FileFolderPicker.imageExtensions,
        profileStorage: AppService().profileStorage,
      );
      filePath = (paths != null && paths.isNotEmpty) ? paths.first : null;
    }

    if (filePath != null) {
      final originalFileName = path.basename(filePath);
      final ext = path.extension(originalFileName).replaceFirst('.', '').toLowerCase();
      final effectiveExt = ext.isNotEmpty ? ext : 'jpg';

      String targetName;
      if (_flyers.isEmpty) {
        targetName = 'flyer.$effectiveExt';
      } else {
        final existingNames = _flyers.map((f) => f.targetName).toSet();
        int num = _flyers.length;
        targetName = 'photo-$num.$effectiveExt';
        while (existingNames.contains(targetName)) {
          num++;
          targetName = 'photo-$num.$effectiveExt';
        }
      }

      setState(() {
        _flyers.add(
          _PendingFile(
            path: filePath!,
            name: originalFileName,
            targetName: targetName,
          ),
        );
      });
    }
  }

  void _removeFlyer(_PendingFile flyer) {
    setState(() {
      _flyers.remove(flyer);
    });
  }

  Future<void> _selectMediaFiles() async {
    final paths = await FileFolderPicker.show(
      context,
      title: _i18n.t('add_files'),
      allowMultiSelect: true,
      profileStorage: AppService().profileStorage,
    );

    if (paths == null || paths.isEmpty) return;

    final pending = <_PendingFile>[];
    for (final filePath in paths) {
      final fileName = path.basename(filePath);
      pending.add(
        _PendingFile(
          path: filePath,
          name: fileName,
          targetName: fileName,
        ),
      );
    }

    if (pending.isNotEmpty) {
      setState(() {
        _mediaFiles.addAll(pending);
      });
    }
  }

  void _removeMediaFile(_PendingFile file) {
    setState(() {
      _mediaFiles.remove(file);
    });
  }

  void _addLink() {
    showDialog(
      context: context,
      builder: (context) => _LinkEditDialog(
        i18n: _i18n,
        onSave: (link) {
          setState(() {
            _links.add(link);
          });
        },
      ),
    );
  }

  void _editLink(int index) {
    showDialog(
      context: context,
      builder: (context) => _LinkEditDialog(
        i18n: _i18n,
        link: _links[index],
        onSave: (link) {
          setState(() {
            _links[index] = link;
          });
        },
      ),
    );
  }

  void _deleteLink(int index) {
    setState(() {
      _links.removeAt(index);
    });
  }

  Future<void> _addUpdate() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const NewUpdateDialog(),
    );

    if (result != null) {
      final title = result['title'] as String?;
      final content = result['content'] as String?;
      if (title == null || content == null) return;
      setState(() {
        _updates.add(_PendingUpdate(title: title, content: content));
      });
    }
  }

  void _removeUpdate(_PendingUpdate update) {
    setState(() {
      _updates.remove(update);
    });
  }

  Future<void> _loadGroups() async {
    try {
      final app = AppService().getAppByType('groups');
      final groupCollections = app != null ? [app] : <App>[];

      _availableGroups.clear();
      final groupsService = GroupsService();
      final profile = ProfileService().getProfile();

      for (final collection in groupCollections) {
        // Set profile storage for encrypted storage support
        final profileStorage = AppService().profileStorage;
        if (profileStorage != null) {
          final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
            profileStorage,
            collection.storagePath!,
          );
          groupsService.setStorage(scopedStorage);
        } else {
          groupsService.setStorage(FilesystemProfileStorage(collection.storagePath!));
        }
        await groupsService.initializeApp(
          collection.storagePath!,
          creatorNpub: profile.npub,
        );
        final groups = await groupsService.loadGroups();
        for (final group in groups) {
          if (!group.isActive) continue;
          _availableGroups.add(_GroupOption(group, collection.title));
        }
      }

      _availableGroups.sort((a, b) {
        final titleA = _groupLabel(a).toLowerCase();
        final titleB = _groupLabel(b).toLowerCase();
        return titleA.compareTo(titleB);
      });
    } catch (e) {
      _availableGroups.clear();
    }

    if (!mounted) return;
    setState(() {
      _isLoadingGroups = false;
    });
  }

  Future<void> _openContactPicker() async {
    final results = await Navigator.push<List<ContactPickerResult>>(
      context,
      MaterialPageRoute(
        builder: (context) => ContactPickerPage(
          i18n: _i18n,
          multiSelect: true,
          initialSelection: _selectedContacts.keys.toSet(),
          sortByEvents: true,
        ),
      ),
    );

    if (results != null && mounted) {
      setState(() {
        _selectedContacts.clear();
        for (final result in results) {
          _selectedContacts[result.contact.callsign] = result;
        }
      });
    }
  }

  /// Opens the same multi-select contact picker used for event contacts so
  /// the author chooses access-grant callsigns from their address book
  /// instead of typing them. Returned set replaces the current selection.
  Future<void> _openAccessCallsignPicker() async {
    final results = await Navigator.push<List<ContactPickerResult>>(
      context,
      MaterialPageRoute(
        builder: (context) => ContactPickerPage(
          i18n: _i18n,
          multiSelect: true,
          initialSelection: _accessCallsigns.keys.toSet(),
          sortByEvents: true,
        ),
      ),
    );
    if (results != null && mounted) {
      setState(() {
        _accessCallsigns.clear();
        for (final r in results) {
          _accessCallsigns[r.contact.callsign] = r;
        }
      });
    }
  }

  String _groupLabel(_GroupOption option) {
    if (option.group.title.isNotEmpty) {
      return option.group.title;
    }
    return option.group.name;
  }

  String? _buildAgendaText() {
    if (_isMultiDay) {
      final dates = _getAgendaDates();
      if (dates.isEmpty) return null;

      final entries = <String>[];
      for (int i = 0; i < dates.length; i++) {
        final dateStr = _formatDate(dates[i]);
        final controller = _agendaByDate[dateStr];
        if (controller == null) continue;
        final text = controller.text.trim();
        if (text.isEmpty) continue;
        entries.add('${_i18n.t('day')} ${i + 1} ($dateStr):\n$text');
      }

      if (entries.isEmpty) return null;
      return entries.join('\n\n');
    }

    final text = _agendaController.text.trim();
    if (text.isEmpty) return null;
    return text;
  }

  void _create() {
    if (!_formKey.currentState!.validate()) return;

    if (_isMultiDay && (_startDate == null || _endDate == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('select_both_dates')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_visibility == 'group' && _selectedGroups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('select_groups_for_event')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final location = _locationType == 'online'
        ? 'online'
        : _locationType == 'other'
            ? 'other'
            : _locationType == 'place' && _selectedPlace != null
                ? 'place'
                : _locationController.text.trim();

    final agenda = _buildAgendaText();
    final eventDateTime = _isMultiDay
        ? null
        : DateTime(
            _eventDate.year,
            _eventDate.month,
            _eventDate.day,
            _eventTime != null ? _eventTime!.hour : 0,
            _eventTime != null ? _eventTime!.minute : 0,
          );

    final result = <String, dynamic>{
      'title': _titleController.text.trim(),
      'eventDate': eventDateTime,
      'eventDateTime': eventDateTime, // Alias for edit mode compatibility
      'startDate': _isMultiDay ? _formatDate(_startDate!) : null,
      'endDate': _isMultiDay ? _formatDate(_endDate!) : null,
      'location': location,
      'locationName': _locationNameController.text.trim().isNotEmpty
          ? _locationNameController.text.trim()
          : null,
      'content': _contentController.text.trim(),
      'agenda': agenda,
      'visibility': _visibility,
      'groupAccess': _selectedGroups.toList(),
      'unlistedKey': _visibility == 'unlisted' ? _unlistedKey : null,
      'accessCallsigns': _accessCallsigns.keys.toList(),
      'accessRequestPrompt': _accessRequestPromptController.text.trim().isEmpty
          ? null
          : _accessRequestPromptController.text.trim(),
      'commentsEnabled': _commentsEnabled,
      'links': _links,
      'updates': _updates.map((update) => update.toMap()).toList(),
      'flyers': _flyers.map((file) => file.toMap()).toList(),
      'trailer': _trailer?.toMap(),
      'mediaFiles': _mediaFiles.map((file) => file.toMap()).toList(),
      'registrationEnabled': _registrationEnabled,
      'contacts': _selectedContacts.keys.toList(),
      if (_slugController.text.trim().isNotEmpty)
        'customSlug': _slugController.text.trim(),
    };
    final placePath = _selectedPlace?.folderPath;
    if (placePath != null && placePath.isNotEmpty) {
      result['placePath'] = placePath;
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t(widget.isEditMode ? 'edit_event' : 'create_event')),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: [
            Tab(text: _i18n.t('basic_info')),
            Tab(text: _i18n.t('media')),
            Tab(text: _i18n.t('links')),
            Tab(text: _i18n.t('updates_agenda')),
            Tab(child: _buildAccessControlTabLabel()),
            Tab(child: _buildInteractionsTabLabel()),
          ],
        ),
      ),
      body: Form(
        key: _formKey,
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildBasicTab(theme),
            _buildMediaTab(theme),
            _buildLinksTab(theme),
            _buildUpdatesTab(theme),
            _buildAccessTab(theme),
            _buildInteractionsTab(theme),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: Icon(widget.isEditMode ? Icons.save : Icons.check),
        label: Text(_i18n.t(widget.isEditMode ? 'save' : 'create')),
      ),
    );
  }

  Widget _buildBasicTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // Title
        TextFormField(
          controller: _titleController,
          decoration: InputDecoration(
            labelText: _i18n.t('event_title'),
            hintText: _i18n.t('enter_event_title'),
            border: const OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return _i18n.t('title_is_required');
            }
            if (value.trim().length < 3) {
              return _i18n.t('title_min_3_chars');
            }
            return null;
          },
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 16),

        // URL slug (optional)
        TextFormField(
          controller: _slugController,
          decoration: InputDecoration(
            labelText: _i18n.t('url_slug'),
            hintText: _i18n.t('url_slug_hint'),
            border: const OutlineInputBorder(),
            helperText: _i18n.t('url_slug_helper'),
            prefixText: '/events/ ',
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 24),

        // Date section
        if (_isMultiDay) ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selectStartDate,
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text(
                    _startDate != null
                        ? _formatDate(_startDate!)
                        : _i18n.t('start_date'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selectEndDate,
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text(
                    _endDate != null
                        ? _formatDate(_endDate!)
                        : _i18n.t('end_date'),
                  ),
                ),
              ),
            ],
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selectEventDate,
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text(_formatDate(_eventDate)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selectEventTime,
                  icon: const Icon(Icons.schedule, size: 18),
                  label: Text(
                    _eventTime != null
                        ? _formatTime(_eventTime!)
                        : _i18n.t('select_time'),
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(_i18n.t('multi_day_event')),
          value: _isMultiDay,
          onChanged: (value) {
            setState(() {
              _isMultiDay = value;
              if (!value) {
                _startDate = null;
                _endDate = null;
                for (final controller in _agendaByDate.values) {
                  controller.dispose();
                }
                _agendaByDate.clear();
              }
            });
          },
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 16),

        // Location type dropdown
        DropdownButtonFormField<String>(
          value: _locationType,
          decoration: InputDecoration(
            labelText: _i18n.t('location_type'),
            border: const OutlineInputBorder(),
          ),
          items: [
            DropdownMenuItem(
              value: 'coordinates',
              child: Row(
                children: [
                  const Icon(Icons.my_location, size: 20),
                  const SizedBox(width: 8),
                  Text(_i18n.t('coordinates')),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'place',
              child: Row(
                children: [
                  const Icon(Icons.place, size: 20),
                  const SizedBox(width: 8),
                  Text(_i18n.t('place')),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'online',
              child: Row(
                children: [
                  const Icon(Icons.videocam, size: 20),
                  const SizedBox(width: 8),
                  Text(_i18n.t('online')),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'other',
              child: Row(
                children: [
                  const Icon(Icons.more_horiz, size: 20),
                  const SizedBox(width: 8),
                  Text(_i18n.t('other')),
                ],
              ),
            ),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() {
                _locationType = value;
                if (value == 'online' || value == 'other') {
                  _locationController.clear();
                  _selectedPlace = null;
                } else if (value == 'coordinates') {
                  _selectedPlace = null;
                } else if (value == 'place') {
                  _locationController.clear();
                }
              });
            }
          },
        ),
        const SizedBox(height: 16),

        // Location input based on type
        if (_locationType == 'coordinates') ...[
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _locationController,
                  decoration: InputDecoration(
                    labelText: _i18n.t('location_coords'),
                    hintText: '40.7128,-74.0060',
                    border: const OutlineInputBorder(),
                    helperText: _i18n.t('enter_latitude_longitude'),
                  ),
                  validator: (value) {
                    if (_locationType == 'coordinates' &&
                        (value == null || value.trim().isEmpty)) {
                      return _i18n.t('location_required');
                    }
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                onPressed: _openMapPicker,
                icon: const Icon(Icons.map),
                tooltip: _i18n.t('select_on_map'),
                iconSize: 24,
                padding: const EdgeInsets.all(16),
              ),
            ],
          ),
        ] else if (_locationType == 'place') ...[
          OutlinedButton.icon(
            onPressed: _openPlacePicker,
            icon: const Icon(Icons.place_outlined, size: 18),
            label: Text(_i18n.t('choose_place')),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          if (_selectedPlace != null) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.place),
                title: Text(
                  _selectedPlace!.getName(
                    _i18n.currentLanguage.split('_').first.toUpperCase(),
                  ),
                ),
                subtitle: Text(_selectedPlace!.coordinatesString),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _clearSelectedPlace,
                  tooltip: _i18n.t('remove'),
                ),
              ),
            ),
          ],
        ],
        // Online type shows nothing extra

        const SizedBox(height: 16),
        TextFormField(
          controller: _locationNameController,
          decoration: InputDecoration(
            labelText: _i18n.t('location_name'),
            hintText: _i18n.t('enter_location_name'),
            border: const OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
        ),

        // Contacts section
        const SizedBox(height: 24),
        Row(
          children: [
            Text(
              _i18n.t('contacts'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            if (_selectedContacts.isNotEmpty)
              TextButton(
                onPressed: () {
                  setState(() {
                    _selectedContacts.clear();
                  });
                },
                child: Text(_i18n.t('clear_all')),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _i18n.t('contacts_with_event_hint'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        // Selected contacts (pinned at top)
        if (_selectedContacts.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _selectedContacts.values.map((result) {
              return Chip(
                avatar: CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    result.contact.displayName.isNotEmpty
                        ? result.contact.displayName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                label: Text(result.contact.displayName),
                deleteIcon: const Icon(Icons.close, size: 18),
                onDeleted: () {
                  setState(() {
                    _selectedContacts.remove(result.contact.callsign);
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
        ],
        // Button to add contacts
        OutlinedButton.icon(
          onPressed: _openContactPicker,
          icon: const Icon(Icons.person_add_outlined, size: 18),
          label: Text(_selectedContacts.isEmpty
              ? _i18n.t('select_contacts')
              : _i18n.t('add_more_contacts')),
        ),

        // Photos section
        const SizedBox(height: 24),
        Row(
          children: [
            Text(
              _i18n.t('photos'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _selectPhotos,
              icon: const Icon(Icons.add_photo_alternate, size: 18),
              label: Text(_i18n.t('add_photos')),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_flyers.isEmpty)
          InkWell(
            onTap: _selectPhotos,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.photo_library_outlined,
                    size: 48,
                    color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _i18n.t('no_photos_yet'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _flyers.length,
            itemBuilder: (context, index) {
              final photo = _flyers[index];
              final isPrimary = index == 0;
              return _buildPhotoTile(theme, photo, isPrimary, index);
            },
          ),

        // Event Description
        const SizedBox(height: 24),
        TextFormField(
          controller: _contentController,
          decoration: InputDecoration(
            labelText: _i18n.t('event_description'),
            border: const OutlineInputBorder(),
            alignLabelWithHint: true,
            suffixIcon: TranscribeButtonWidget(
              i18n: _i18n,
              onTranscribed: (text) {
                if (_contentController.text.isEmpty) {
                  _contentController.text = text;
                } else {
                  _contentController.text += ' $text';
                }
              },
            ),
          ),
          textCapitalization: TextCapitalization.sentences,
          maxLines: 8,
        ),
      ],
    );
  }

  Widget _buildPhotoTile(ThemeData theme, _PendingFile photo, bool isPrimary, int index) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(photo.path),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              color: theme.colorScheme.surfaceVariant,
              child: const Icon(Icons.broken_image),
            ),
          ),
        ),
        // Primary badge
        if (isPrimary)
          Positioned(
            top: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _i18n.t('cover'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        // Action buttons
        Positioned(
          top: 4,
          right: 4,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isPrimary)
                _buildPhotoAction(
                  theme,
                  Icons.star_outline,
                  _i18n.t('set_as_cover'),
                  () => _setAsPrimaryPhoto(index),
                ),
              _buildPhotoAction(
                theme,
                Icons.delete,
                _i18n.t('remove'),
                () => _removeFlyer(photo),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoAction(ThemeData theme, IconData icon, String tooltip, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Material(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 16, color: Colors.white),
          ),
        ),
      ),
    );
  }

  Future<void> _selectPhotos() async {
    // Use FileFolderPicker on every platform so encrypted profile folders are
    // browsable — the native image_picker can't see inside ProfileStorage.
    // The combined extensions set lets the user pick photos and short video
    // clips from the same picker. Default to grid view and start at the
    // platform's user-facing media folder so thumbnails are immediately
    // visible without the user having to navigate to Pictures / Recent.
    final paths = await FileFolderPicker.show(
      context,
      title: _i18n.t('select_photos'),
      allowMultiSelect: true,
      allowedExtensions: {
        ...FileFolderPicker.imageExtensions,
        ...FileFolderPicker.videoExtensions,
      },
      profileStorage: AppService().profileStorage,
      initialGridView: true,
      initialDirectory: FileFolderPicker.defaultMediaDirectory(),
    );
    final filePaths = paths ?? [];

    if (filePaths.isEmpty) return;

    setState(() {
      for (final filePath in filePaths) {
        final originalFileName = path.basename(filePath);
        final ext = path.extension(originalFileName).replaceFirst('.', '').toLowerCase();
        final effectiveExt = ext.isNotEmpty ? ext : 'jpg';

        String targetName;
        if (_flyers.isEmpty) {
          // First photo becomes the cover/flyer
          targetName = 'flyer.$effectiveExt';
        } else {
          // Subsequent photos are named photo-1, photo-2, ...
          final existingNames = _flyers.map((f) => f.targetName).toSet();
          int num = _flyers.length;
          targetName = 'photo-$num.$effectiveExt';
          while (existingNames.contains(targetName)) {
            num++;
            targetName = 'photo-$num.$effectiveExt';
          }
        }

        _flyers.add(
          _PendingFile(
            path: filePath,
            name: originalFileName,
            targetName: targetName,
          ),
        );
      }
    });
  }

  void _setAsPrimaryPhoto(int index) {
    if (index == 0 || index >= _flyers.length) return;
    setState(() {
      final photo = _flyers.removeAt(index);
      final ext = path.extension(photo.targetName);
      final primaryName = 'flyer$ext';
      // Demote old cover to photo-*
      if (_flyers.isNotEmpty) {
        final oldPrimary = _flyers.first;
        final oldExt = path.extension(oldPrimary.targetName);
        final existingNames = _flyers.map((f) => f.targetName).toSet();
        int num = 1;
        var demotedName = 'photo-$num$oldExt';
        while (existingNames.contains(demotedName)) {
          num++;
          demotedName = 'photo-$num$oldExt';
        }
        _flyers[0] = _PendingFile(
          path: oldPrimary.path,
          name: oldPrimary.name,
          targetName: demotedName,
        );
      }
      _flyers.insert(0, _PendingFile(
        path: photo.path,
        name: photo.name,
        targetName: primaryName,
      ));
    });
  }

  Widget _buildMediaTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // Files & Photos section (first)
        Text(
          _i18n.t('event_files'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _i18n.t('event_files_info'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        if (_mediaFiles.isNotEmpty) ...[
          ..._mediaFiles.map((file) => Card(
                child: ListTile(
                  leading: const Icon(Icons.insert_drive_file),
                  title: Text(file.targetName),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _removeMediaFile(file),
                  ),
                ),
              )),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          onPressed: _selectMediaFiles,
          icon: const Icon(Icons.add),
          label: Text(_i18n.t('add_files')),
        ),

        // Flyers section
        const SizedBox(height: 32),
        Text(
          _i18n.t('flyers'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        if (_flyers.isNotEmpty) ...[
          ..._flyers.map((flyer) => Card(
                child: ListTile(
                  leading: const Icon(Icons.image),
                  title: Text(flyer.targetName),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _removeFlyer(flyer),
                  ),
                ),
              )),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          onPressed: _selectFlyer,
          icon: const Icon(Icons.add_photo_alternate),
          label: Text(_flyers.isEmpty
              ? _i18n.t('add_flyer')
              : _i18n.t('add_another_flyer')),
        ),
        const SizedBox(height: 8),
        Text(
          _i18n.t('flyers_stored_event_folder'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),

        // Trailer section
        const SizedBox(height: 32),
        Text(
          _i18n.t('trailer'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        if (_trailer != null) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.movie),
              title: Text(_trailer!.targetName),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: _removeTrailer,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          onPressed: _selectTrailer,
          icon: const Icon(Icons.upload_file),
          label: Text(_trailer == null
              ? _i18n.t('select_trailer_video')
              : _i18n.t('change_trailer_video')),
        ),
      ],
    );
  }

  Widget _buildLinksTab(ThemeData theme) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant,
              ),
            ),
          ),
          child: Row(
            children: [
              Text(
                _i18n.t('links'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _addLink,
                icon: const Icon(Icons.add, size: 18),
                label: Text(_i18n.t('add_link')),
              ),
            ],
          ),
        ),
        Expanded(
          child: _links.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.link,
                        size: 64,
                        color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _i18n.t('no_links_yet'),
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _links.length,
                  itemBuilder: (context, index) {
                    final link = _links[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(_getLinkTypeIcon(link.linkType)),
                        title: Text(link.description),
                        subtitle: Text(link.url),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit),
                              onPressed: () => _editLink(index),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () => _deleteLink(index),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  IconData _getLinkTypeIcon(LinkType type) {
    switch (type) {
      case LinkType.zoom:
      case LinkType.googleMeet:
      case LinkType.teams:
        return Icons.video_call;
      case LinkType.youtube:
        return Icons.play_circle_outline;
      case LinkType.instagram:
      case LinkType.twitter:
      case LinkType.facebook:
        return Icons.share;
      case LinkType.github:
        return Icons.code;
      default:
        return Icons.link;
    }
  }

  Widget _buildUpdatesTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // Agenda section
        Text(
          _i18n.t('agenda_optional'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        if (_isMultiDay) ...[
          if (_getAgendaDates().isEmpty)
            Text(
              _i18n.t('select_dates_for_agenda'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ..._getAgendaDates().asMap().entries.map((entry) {
              final index = entry.key;
              final date = entry.value;
              final dateStr = _formatDate(date);
              final controller = _agendaByDate.putIfAbsent(
                dateStr,
                () => TextEditingController(),
              );
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextFormField(
                  controller: controller,
                  decoration: InputDecoration(
                    labelText: '${_i18n.t('day')} ${index + 1} - $dateStr',
                    border: const OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 4,
                ),
              );
            }),
        ] else
          TextFormField(
            controller: _agendaController,
            decoration: InputDecoration(
              hintText: _i18n.t('event_schedule_agenda'),
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            textCapitalization: TextCapitalization.sentences,
            maxLines: 6,
          ),

        const SizedBox(height: 32),

        // Updates section
        Row(
          children: [
            Text(
              _i18n.t('updates'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _addUpdate,
              icon: const Icon(Icons.add, size: 18),
              label: Text(_i18n.t('new_update')),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_updates.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.auto_stories,
                  size: 48,
                  color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
                ),
                const SizedBox(height: 12),
                Text(
                  _i18n.t('no_updates_yet'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          )
        else
          ..._updates.map((update) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const Icon(Icons.edit_note),
                  title: Text(update.title),
                  subtitle: Text(
                    update.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _removeUpdate(update),
                  ),
                ),
              )),
      ],
    );
  }

  Widget _buildAccessTab(ThemeData theme) {
    final pending = _pendingAccessRequestCount;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (pending > 0) ...[
          // Top-of-tab banner so the owner doesn't have to scroll to find
          // why the tab title was glowing red. Tapped once they're here
          // anyway, so this is the natural place to point them at the
          // pending list further down the page.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.error, width: 1),
            ),
            child: Row(
              children: [
                Icon(Icons.notifications_active,
                    color: theme.colorScheme.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    pending == 1
                        ? '1 pending access request — scroll down to approve or deny.'
                        : '$pending pending access requests — scroll down to approve or deny.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text(
          _i18n.t('access_control'),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _i18n.t('access_control_help'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          _i18n.t('visibility'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _visibility,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            helperText: _i18n.t('visibility_help'),
          ),
          items: [
            DropdownMenuItem(
              value: 'public',
              child: Row(
                children: [
                  const Icon(Icons.public, size: 20),
                  const SizedBox(width: 8),
                  Text(_i18n.t('public')),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'unlisted',
              child: Row(
                children: const [
                  Icon(Icons.link, size: 20),
                  SizedBox(width: 8),
                  Text('Unlisted'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'request_access',
              child: Row(
                children: const [
                  Icon(Icons.how_to_reg, size: 20),
                  SizedBox(width: 8),
                  Text('Request access'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'group',
              child: Row(
                children: [
                  const Icon(Icons.group, size: 20),
                  const SizedBox(width: 8),
                  Text(_i18n.t('group')),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'private',
              child: Row(
                children: [
                  const Icon(Icons.lock, size: 20),
                  const SizedBox(width: 8),
                  Text(_i18n.t('private')),
                ],
              ),
            ),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() {
                _visibility = value;
                if (value == 'unlisted' &&
                    (_unlistedKey == null || _unlistedKey!.isEmpty)) {
                  // Generate a 32-char hex token (16 random bytes) the same
                  // way the tracker / document widget does.
                  final rand = Random.secure();
                  final bytes =
                      List.generate(16, (_) => rand.nextInt(256));
                  _unlistedKey = bytes
                      .map((b) => b.toRadixString(16).padLeft(2, '0'))
                      .join();
                }
              });
            }
          },
        ),
        if (_visibility == 'unlisted') ...[
          const SizedBox(height: 12),
          // Show the share key so the owner knows what to send in the URL.
          // Read-only — anyone with this key can open the event.
          TextFormField(
            initialValue: _unlistedKey ?? '',
            readOnly: true,
            decoration: const InputDecoration(
              labelText: 'Unlisted access key',
              helperText:
                  'Share the URL with ?key=<this> to grant access. Anyone with the URL can open the event.',
              prefixIcon: Icon(Icons.vpn_key, size: 18),
              border: OutlineInputBorder(),
            ),
          ),
        ],
        if (_visibility == 'private' ||
            _visibility == 'group' ||
            _visibility == 'request_access') ...[
          const SizedBox(height: 16),
          Text(
            'Allowed callsigns',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            'These callsigns can access the event in addition to any selected groups.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (_accessCallsigns.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _accessCallsigns.values.map((result) {
                final label = result.contact.displayName.isNotEmpty &&
                        result.contact.displayName !=
                            result.contact.callsign
                    ? '${result.contact.displayName} (${result.contact.callsign})'
                    : result.contact.callsign;
                return Chip(
                  avatar: CircleAvatar(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      result.contact.callsign.isNotEmpty
                          ? result.contact.callsign[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  label: Text(label),
                  deleteIcon: const Icon(Icons.close, size: 18),
                  onDeleted: () {
                    setState(() {
                      _accessCallsigns.remove(result.contact.callsign);
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
          ],
          OutlinedButton.icon(
            onPressed: _openAccessCallsignPicker,
            icon: const Icon(Icons.person_add_outlined, size: 18),
            label: Text(_accessCallsigns.isEmpty
                ? _i18n.t('add_callsigns')
                : _i18n.t('add_more_callsigns')),
          ),
          if (_visibility == 'request_access') ...[
            const SizedBox(height: 16),
            // Optional question / instruction to show requesters above the
            // request-note field. NOSTR identities are random by default
            // so this is the author's chance to ask for "who are you?",
            // "how do we know each other?", etc.
            TextFormField(
              controller: _accessRequestPromptController,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: _i18n.t('request_prompt_label'),
                helperText: _i18n.t('request_prompt_help'),
                prefixIcon: const Icon(Icons.help_outline, size: 18),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          if (_visibility == 'request_access' &&
              widget.isEditMode &&
              _accessRequests.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              _i18n.t('access_requests_title'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              _i18n.t('access_requests_help'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            ..._accessRequests.map((entry) {
              final status = (entry['status'] as String?) ?? 'pending';
              final cs = ((entry['callsign'] as String?) ?? '').trim();
              final npub = ((entry['npub'] as String?) ?? '').trim();
              final nick = ((entry['nickname'] as String?) ?? '').trim();
              final msg = ((entry['message'] as String?) ?? '').trim();
              final personLabel = nick.isNotEmpty && cs.isNotEmpty
                  ? '$nick ($cs)'
                  : cs;
              final color = status == 'approved'
                  ? Colors.green
                  : status == 'denied'
                      ? Colors.red
                      : theme.colorScheme.onSurfaceVariant;
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.person_outline,
                              size: 18, color: color),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              personLabel.isNotEmpty
                                  ? '$personLabel  ·  ${npub.length > 20 ? '${npub.substring(0, 16)}…' : npub}'
                                  : npub,
                              style: theme.textTheme.bodyMedium,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              status,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: color),
                            ),
                          ),
                        ],
                      ),
                      if (msg.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(msg, style: theme.textTheme.bodySmall),
                      ],
                      if (status == 'pending') ...[
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton.icon(
                              onPressed: () =>
                                  _decideAccessRequest(entry, 'deny'),
                              icon: const Icon(Icons.close, size: 18),
                              label: Text(_i18n.t('deny')),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              onPressed: () =>
                                  _decideAccessRequest(entry, 'approve'),
                              icon: const Icon(Icons.check, size: 18),
                              label: Text(_i18n.t('approve')),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }),
          ],
        ],
        if (_visibility == 'group') ...[
          const SizedBox(height: 16),
          Text(
            _i18n.t('event_groups_access'),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (_isLoadingGroups)
            const LinearProgressIndicator()
          else if (_availableGroups.isEmpty)
            Text(
              _i18n.t('no_groups_available'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ..._availableGroups.map((option) {
              final label = _groupLabel(option);
              final subtitleParts = <String>[];
              if (option.group.title.isNotEmpty && option.group.name != option.group.title) {
                subtitleParts.add(option.group.name);
              }
              if (option.appTitle != null && option.appTitle!.isNotEmpty) {
                subtitleParts.add(option.appTitle!);
              }
              return CheckboxListTile(
                value: _selectedGroups.contains(option.group.name),
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedGroups.add(option.group.name);
                    } else {
                      _selectedGroups.remove(option.group.name);
                    }
                  });
                },
                title: Text(label),
                subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(' - ')),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              );
            }),
        ],
        const SizedBox(height: 24),
        SwitchListTile(
          title: Text(_i18n.t('enable_registration')),
          subtitle: Text(_i18n.t('allow_attendees_register')),
          value: _registrationEnabled,
          onChanged: (value) {
            setState(() {
              _registrationEnabled = value;
            });
          },
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }

  /// Tab label for the Interactions tab — mirrors [_buildAccessControlTabLabel]
  /// so a count badge is anchored next to the label whenever the event has
  /// at least one comment the owner can review/delete.
  Widget _buildInteractionsTabLabel() {
    final count = _comments.length;
    final theme = Theme.of(context);
    final label = Text(_i18n.t('interactions'));
    if (count == 0) return label;
    return Tooltip(
      message: _i18n.t('interactions_count_tooltip').replaceAll(
            '{0}',
            '$count',
          ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          label,
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimary,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Visitor-facing interactions: the "Allow comments" toggle and the
  /// list of NOSTR-signed comments with delete buttons. Likes don't
  /// surface here yet because they have nothing the author can act on
  /// (they're an opaque tally), but the tab is the natural home for
  /// any future visitor-action moderation (reactions, RSVPs…).
  Widget _buildInteractionsTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: SwitchListTile(
            value: _commentsEnabled,
            onChanged: (v) => setState(() => _commentsEnabled = v),
            title: Text(_i18n.t('allow_comments')),
            subtitle: Text(_i18n.t('allow_comments_help')),
            secondary: const Icon(Icons.chat_bubble_outline),
          ),
        ),
        if (widget.isEditMode) ...[
          const SizedBox(height: 24),
          Text(
            _i18n
                .t('comments_section_title')
                .replaceAll('{0}', '${_comments.length}'),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _i18n.t('comments_section_help'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (_comments.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _i18n.t('comments_empty'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
            )
          else
            ..._comments.map((c) {
              final id = (c['id'] as String?) ?? '';
              final author = ((c['author'] as String?) ?? '').trim();
              final ts = ((c['timestamp'] as String?) ?? '').trim();
              final body = ((c['content'] as String?) ?? '').trim();
              final npub = ((c['npub'] as String?) ?? '').trim();
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.chat_bubble_outline,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              author.isNotEmpty
                                  ? (npub.isNotEmpty
                                      ? '$author  ·  ${npub.length > 16 ? '${npub.substring(0, 16)}…' : npub}'
                                      : author)
                                  : (npub.isNotEmpty ? npub : _i18n.t('unknown')),
                              style: theme.textTheme.bodyMedium,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (ts.isNotEmpty)
                            Text(
                              ts,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          IconButton(
                            tooltip: _i18n.t('delete_comment'),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            color: theme.colorScheme.error,
                            onPressed: id.isEmpty
                                ? null
                                : () async {
                                    final ok = await showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: Text(
                                                _i18n.t('delete_comment_q')),
                                            content: Text(
                                              body.length > 200
                                                  ? '${body.substring(0, 200)}…'
                                                  : body,
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, false),
                                                child:
                                                    Text(_i18n.t('cancel')),
                                              ),
                                              FilledButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, true),
                                                child:
                                                    Text(_i18n.t('delete')),
                                              ),
                                            ],
                                          ),
                                        ) ??
                                        false;
                                    if (ok) await _deleteComment(id);
                                  },
                          ),
                        ],
                      ),
                      if (body.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(body, style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
              );
            }),
        ],
      ],
    );
  }
}

class _LinkEditDialog extends StatefulWidget {
  final I18nService i18n;
  final EventLink? link;
  final Function(EventLink) onSave;

  const _LinkEditDialog({
    required this.i18n,
    this.link,
    required this.onSave,
  });

  @override
  State<_LinkEditDialog> createState() => _LinkEditDialogState();
}

class _LinkEditDialogState extends State<_LinkEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _urlController;
  late TextEditingController _descriptionController;
  late TextEditingController _passwordController;
  late TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.link?.url ?? '');
    _descriptionController = TextEditingController(text: widget.link?.description ?? '');
    _passwordController = TextEditingController(text: widget.link?.password ?? '');
    _noteController = TextEditingController(text: widget.link?.note ?? '');
  }

  @override
  void dispose() {
    _urlController.dispose();
    _descriptionController.dispose();
    _passwordController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final link = EventLink(
      url: _urlController.text.trim(),
      description: _descriptionController.text.trim(),
      password: _passwordController.text.trim().isEmpty
          ? null
          : _passwordController.text.trim(),
      note: _noteController.text.trim().isEmpty
          ? null
          : _noteController.text.trim(),
    );

    widget.onSave(link);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 600),
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.link == null
                    ? widget.i18n.t('add_link')
                    : widget.i18n.t('edit_link'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: _urlController,
                        decoration: InputDecoration(
                          labelText: widget.i18n.t('url'),
                          hintText: 'https://example.com',
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return widget.i18n.t('url_required');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _descriptionController,
                        decoration: InputDecoration(
                          labelText: widget.i18n.t('description'),
                          border: const OutlineInputBorder(),
                        ),
                        textCapitalization: TextCapitalization.sentences,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return widget.i18n.t('description_required');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordController,
                        decoration: InputDecoration(
                          labelText: widget.i18n.t('password_optional'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _noteController,
                        decoration: InputDecoration(
                          labelText: widget.i18n.t('note_optional'),
                          border: const OutlineInputBorder(),
                        ),
                        textCapitalization: TextCapitalization.sentences,
                        maxLines: 3,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(widget.i18n.t('cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save, size: 18),
                    label: Text(widget.i18n.t('save')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
