/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../dialogs/new_update_dialog.dart';
import '../models/event.dart';
import '../models/event_link.dart';
import '../services/event_service.dart';
import '../services/i18n_service.dart';
import '../services/profile_service.dart';
import '../widgets/event_detail_widget.dart';
import 'event_settings_page.dart';

/// Full-screen event detail page (shared by events browser and map).
class EventDetailPage extends StatefulWidget {
  final Event event;
  final String collectionPath;
  final EventService eventService;
  final ProfileService profileService;
  final I18nService i18n;
  final String? currentUserNpub;
  final String? currentCallsign;
  final bool readOnly;

  const EventDetailPage({
    Key? key,
    required this.event,
    required this.collectionPath,
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

  @override
  void initState() {
    super.initState();
    _event = widget.event;
  }

  Future<void> _refreshEvent({bool markChanged = false}) async {
    if (widget.collectionPath.isEmpty) return;
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
    if (widget.readOnly || widget.collectionPath.isEmpty) return;
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => EventSettingsPage(
          event: _event,
          collectionPath: widget.collectionPath,
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
    if (widget.collectionPath.isEmpty) return placePath;
    if (path.isAbsolute(placePath)) {
      final basePath = path.dirname(widget.collectionPath);
      final relative = path.relative(placePath, from: basePath);
      if (!relative.startsWith('..')) {
        return relative;
      }
    }
    return placePath;
  }

  Future<void> _uploadFiles() async {
    if (widget.readOnly || widget.collectionPath.isEmpty) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        dialogTitle: widget.i18n.t('select_files_to_add'),
      );

      if (result != null && result.files.isNotEmpty && mounted) {
        final year = _event.id.substring(0, 4);
        final eventPath = '${widget.collectionPath}/$year/${_event.id}';

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
          _hasChanges = true;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(widget.i18n.t('files_uploaded', params: [copiedCount.toString()])),
              backgroundColor: Colors.green,
            ),
          );
          // Refresh event to show uploaded files immediately
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
    if (widget.readOnly || widget.collectionPath.isEmpty) return;
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

  @override
  Widget build(BuildContext context) {
    final canEdit = !widget.readOnly &&
        widget.collectionPath.isNotEmpty &&
        _event.canEdit(widget.currentCallsign ?? '', widget.currentUserNpub);
    final canManage = !widget.readOnly && widget.collectionPath.isNotEmpty;

    final detail = EventDetailWidget(
      event: _event,
      collectionPath: widget.collectionPath,
      currentCallsign: widget.currentCallsign,
      currentUserNpub: widget.currentUserNpub,
      canEdit: canEdit,
      onEdit: canEdit ? _editEvent : null,
      onUploadFiles: canManage ? _uploadFiles : null,
      onCreateUpdate: canManage ? _createUpdate : null,
      onFeedbackUpdated: widget.collectionPath.isNotEmpty
          ? () => _refreshEvent(markChanged: true)
          : null,
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
        ),
        body: widget.collectionPath.isEmpty
            ? detail
            : RefreshIndicator(
                onRefresh: () => _refreshEvent(markChanged: true),
                child: detail,
              ),
      ),
    );
  }
}
