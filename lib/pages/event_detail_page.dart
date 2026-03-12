/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../dialogs/new_update_dialog.dart';
import '../models/event.dart';
import '../services/app_service.dart';
import '../models/event_link.dart';
import '../services/contact_service.dart';
import '../services/event_service.dart';
import '../services/i18n_service.dart';
import '../util/place_parser.dart';
import '../services/profile_service.dart';
import '../widgets/event_detail_widget.dart';
import '../widgets/file_folder_picker.dart';
import 'conference_host_page.dart';
import 'contacts_browser_page.dart';
import 'new_event_page.dart';
import 'place_detail_page.dart';

/// Full-screen event detail page (shared by events browser and map).
class EventDetailPage extends StatefulWidget {
  final Event event;
  final String appPath;
  final EventService eventService;
  final ProfileService profileService;
  final I18nService i18n;
  final String? currentUserNpub;
  final String? currentCallsign;
  final bool readOnly;

  const EventDetailPage({
    Key? key,
    required this.event,
    required this.appPath,
    required this.eventService,
    required this.profileService,
    required this.i18n,
    required this.currentUserNpub,
    required this.currentCallsign,
    this.readOnly = false,
  }) : super(key: key);

  @override
  State<EventDetailPage> createState() => _EventDetailPageState();
}

class _EventDetailPageState extends State<EventDetailPage> {
  late Event _event;
  bool _hasChanges = false;
  int _filesRefreshKey = 0;

  @override
  void initState() {
    super.initState();
    _event = widget.event;
  }

  Future<void> _refreshEvent({bool markChanged = false}) async {
    if (widget.appPath.isEmpty) return;
    final updatedEvent = await widget.eventService.loadEvent(_event.id);
    if (updatedEvent != null && mounted) {
      setState(() {
        _event = updatedEvent;
      });
    }
    if (markChanged) {
      _hasChanges = true;
    }
  }

  Future<void> _editEvent() async {
    if (widget.readOnly || widget.appPath.isEmpty) return;
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => NewEventPage(
          event: _event,
          appPath: widget.appPath,
        ),
      ),
    );

    if (result != null && mounted) {
      final metadata = _buildEventMetadata(result);
      final newEventId = await widget.eventService.updateEvent(
        eventId: _event.id,
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
        trailerFileName: result.containsKey('trailer')
            ? (result['trailer'] as String? ?? '')
            : null,
        links: result['links'] as List<EventLink>?,
        registrationEnabled: result['registrationEnabled'] as bool?,
        contacts: result['contacts'] as List<String>?,
        metadata: metadata,
      );

      if (newEventId != null && mounted) {
        _hasChanges = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.i18n.t('event_updated')),
            backgroundColor: Colors.green,
          ),
        );
        // Reload event using the new ID
        final updatedEvent = await widget.eventService.loadEvent(newEventId);
        if (updatedEvent != null) {
          final event = updatedEvent; // Capture non-null value
          setState(() {
            _event = event;
          });
        }
      }
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
    if (widget.appPath.isEmpty) return placePath;
    if (path.isAbsolute(placePath)) {
      final basePath = path.dirname(widget.appPath);
      final relative = path.relative(placePath, from: basePath);
      if (!relative.startsWith('..')) {
        return relative;
      }
    }
    return placePath;
  }

  Future<void> _uploadFiles() async {
    if (widget.readOnly || widget.appPath.isEmpty) return;
    try {
      final paths = await FileFolderPicker.show(
        context,
        title: widget.i18n.t('select_files_to_add'),
        allowMultiSelect: true,
        profileStorage: AppService().profileStorage,
      );

      if (paths != null && paths.isNotEmpty && mounted) {
        final year = _event.id.substring(0, 4);
        final eventPath = '${widget.appPath}/$year/${_event.id}';

        // Collect existing flyer names for renaming
        final existingFlyers = List<String>.from(_event.flyers);

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
          _hasChanges = true;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(widget.i18n.t('files_uploaded', params: [copiedCount.toString()])),
              backgroundColor: Colors.green,
            ),
          );
          // Refresh event and files section to show uploaded files immediately
          setState(() {
            _filesRefreshKey++;
          });
          await _refreshEvent();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.i18n.t('error')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _createUpdate() async {
    if (widget.readOnly || widget.appPath.isEmpty) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const NewUpdateDialog(),
    );

    if (result != null && mounted) {
      final profile = widget.profileService.getProfile();
      final update = await widget.eventService.createUpdate(
        eventId: _event.id,
        title: result['title'] as String,
        author: profile.callsign,
        content: result['content'] as String,
        npub: profile.npub,
      );

      if (update != null && mounted) {
        _hasChanges = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.i18n.t('update_created')),
            backgroundColor: Colors.green,
          ),
        );
        // Reload event to show the new update
        final updatedEvent = await widget.eventService.loadEvent(_event.id);
        if (updatedEvent != null) {
          final event = updatedEvent; // Capture non-null value
          setState(() {
            _event = event;
          });
        }
      }
    }
  }

  /// Update contacts for the event
  Future<void> _updateEventContacts(List<String> contacts) async {
    if (widget.readOnly || widget.appPath.isEmpty) return;

    final newEventId = await widget.eventService.updateEvent(
      eventId: _event.id,
      title: _event.title,
      location: _event.location,
      locationName: _event.locationName,
      content: _event.content,
      agenda: _event.agenda,
      visibility: _event.visibility,
      contacts: contacts,
    );

    if (newEventId != null && mounted) {
      _hasChanges = true;
      // Reload event to show updated contacts
      final updatedEvent = await widget.eventService.loadEvent(newEventId);
      if (updatedEvent != null) {
        setState(() {
          _event = updatedEvent;
        });
      }
    }
  }

  Future<void> _openContact(String callsign) async {
    if (widget.appPath.isEmpty) return;

    // Events appPath is like: devices/X1DPDX/events
    // Contacts are at: devices/X1DPDX/contacts/
    final devicePath = path.dirname(widget.appPath);
    final contactsCollectionPath = '$devicePath/contacts';
    final fastJsonPath = '$contactsCollectionPath/fast.json';

    // First try to find the contact's file path from fast.json
    String? contactFilePath;
    try {
      final fastFile = File(fastJsonPath);
      if (await fastFile.exists()) {
        final content = await fastFile.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        for (final item in jsonList) {
          if (item['callsign'] == callsign) {
            contactFilePath = item['filePath'] as String?;
            break;
          }
        }
      }
    } catch (e) {
      // Fall through to error handling
    }

    if (contactFilePath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.i18n.t('contact_not_found')),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // Parse the contact file
    final contactService = ContactService();
    final contact = await contactService.loadContactFromFile(contactFilePath);

    if (contact != null && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ContactDetailPage(
            contact: contact,
            contactService: ContactService(),
            profileService: widget.profileService,
            i18n: widget.i18n,
            appPath: contactsCollectionPath,
          ),
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.i18n.t('contact_not_found')),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _openPlace(String placePath) async {
    if (widget.appPath.isEmpty) return;

    // Resolve the place path relative to the collection
    final basePath = path.dirname(widget.appPath);
    final fullPlacePath = path.isAbsolute(placePath)
        ? placePath
        : path.normalize(path.join(basePath, placePath));

    try {
      final placeFile = File('$fullPlacePath/place.txt');
      if (!await placeFile.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(widget.i18n.t('place_not_found')),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      final content = await placeFile.readAsString();
      final place = PlaceParser.parsePlaceContent(
        content: content,
        filePath: placeFile.path,
        folderPath: fullPlacePath,
        regionName: '',
      );

      if (place != null && mounted) {
        // Derive places collection path from place folder
        final placesCollectionPath = _derivePlacesCollectionPath(fullPlacePath);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PlaceDetailPage(
              appPath: placesCollectionPath,
              place: place,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.i18n.t('error')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Derive the places collection path from a place folder path.
  /// Assumes structure: .../places/region/place-name or .../places/place-name
  String _derivePlacesCollectionPath(String placeFolderPath) {
    final parts = path.split(placeFolderPath);
    final placesIndex = parts.lastIndexOf('places');
    if (placesIndex >= 0) {
      return path.joinAll(parts.sublist(0, placesIndex + 1));
    }
    // Fallback: go up two levels from the place folder
    return path.dirname(path.dirname(placeFolderPath));
  }

  void _openConference() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ConferenceHostPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = !widget.readOnly &&
        widget.appPath.isNotEmpty &&
        _event.canEdit(widget.currentCallsign ?? '', widget.currentUserNpub);
    final canManage = !widget.readOnly && widget.appPath.isNotEmpty;

    final detail = EventDetailWidget(
      event: _event,
      appPath: widget.appPath,
      currentCallsign: widget.currentCallsign,
      currentUserNpub: widget.currentUserNpub,
      canEdit: canEdit,
      onEdit: canEdit ? _editEvent : null,
      onUploadFiles: canManage ? _uploadFiles : null,
      onCreateUpdate: canManage ? _createUpdate : null,
      onFeedbackUpdated: widget.appPath.isNotEmpty
          ? () => _refreshEvent(markChanged: true)
          : null,
      onPlaceOpen: _openPlace,
      onContactsUpdated: canEdit ? _updateEventContacts : null,
      onContactOpen: _openContact,
      filesRefreshKey: _filesRefreshKey,
    );

    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        if (didPop && _hasChanges) {
          Navigator.of(context).pop(true);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_event.title),
          actions: [
            if (_event.isOnline)
              IconButton(
                icon: const Icon(Icons.mic),
                onPressed: _openConference,
                tooltip: 'Conference',
              ),
            if (canEdit)
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: _editEvent,
                tooltip: widget.i18n.t('edit'),
              ),
          ],
        ),
        body: widget.appPath.isEmpty
            ? detail
            : RefreshIndicator(
                onRefresh: () => _refreshEvent(markChanged: true),
                child: detail,
              ),
      ),
    );
  }
}
