/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:latlong2/latlong.dart';
import '../models/event.dart';
import '../models/event_link.dart';
import '../services/i18n_service.dart';
import 'location_picker_page.dart';

/// Full-screen event settings page with tabbed interface
class EventSettingsPage extends StatefulWidget {
  final Event event;
  final String collectionPath;

  const EventSettingsPage({
    Key? key,
    required this.event,
    required this.collectionPath,
  }) : super(key: key);

  @override
  State<EventSettingsPage> createState() => _EventSettingsPageState();
}

class _EventSettingsPageState extends State<EventSettingsPage>
    with SingleTickerProviderStateMixin {
  final _i18n = I18nService();
  late TabController _tabController;

  // Basic Info
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  late TextEditingController _agendaController;
  late TextEditingController _locationController;
  late TextEditingController _locationNameController;
  late bool _isOnline;
  late DateTime _eventDateTime;
  late TextEditingController _startDateController;
  late TextEditingController _endDateController;
  late DateTime? _startDate;
  late DateTime? _endDate;

  // Access Control
  late TextEditingController _adminsController;
  late TextEditingController _moderatorsController;
  late String _visibility;

  // Media
  String? _trailerFileName;
  List<String> _flyersList = [];

  // Links
  List<EventLink> _links = [];

  // Registration
  bool _registrationEnabled = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);

    // Initialize basic info
    _titleController = TextEditingController(text: widget.event.title);
    _contentController = TextEditingController(text: widget.event.content);
    _agendaController = TextEditingController(text: widget.event.agenda ?? '');
    _locationController = TextEditingController(
      text: widget.event.isOnline ? '' : widget.event.location,
    );
    _locationNameController = TextEditingController(
      text: widget.event.locationName ?? '',
    );
    _isOnline = widget.event.isOnline;

    // Initialize dates
    if (widget.event.isMultiDay) {
      _startDate = _parseDate(widget.event.startDate ?? '');
      _endDate = _parseDate(widget.event.endDate ?? '');
      _startDateController = TextEditingController(text: widget.event.startDate ?? '');
      _endDateController = TextEditingController(text: widget.event.endDate ?? '');
      _eventDateTime = DateTime.now();
    } else {
      _eventDateTime = widget.event.dateTime;
      _startDateController = TextEditingController();
      _endDateController = TextEditingController();
    }

    // Initialize access control
    _adminsController = TextEditingController(
      text: widget.event.admins.join(', '),
    );
    _moderatorsController = TextEditingController(
      text: widget.event.moderators.join(', '),
    );
    _visibility = widget.event.visibility;

    // Initialize media
    _trailerFileName = widget.event.trailer;
    _flyersList = List.from(widget.event.flyers);

    // Initialize links
    _links = List.from(widget.event.links);

    // Initialize registration
    _registrationEnabled = widget.event.hasRegistration;
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleController.dispose();
    _contentController.dispose();
    _agendaController.dispose();
    _locationController.dispose();
    _locationNameController.dispose();
    _adminsController.dispose();
    _moderatorsController.dispose();
    _startDateController.dispose();
    _endDateController.dispose();
    super.dispose();
  }

  DateTime? _parseDate(String dateStr) {
    try {
      if (dateStr.isEmpty) return null;
      return DateTime.parse(dateStr);
    } catch (e) {
      return null;
    }
  }

  Future<void> _selectEventDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _eventDateTime,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (pickedDate != null && mounted) {
      final pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_eventDateTime),
      );

      if (pickedTime != null && mounted) {
        setState(() {
          _eventDateTime = DateTime(
            pickedDate.year,
            pickedDate.month,
            pickedDate.day,
            pickedTime.hour,
            pickedTime.minute,
          );
        });
      }
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
        final dateStr = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
        _startDateController.text = dateStr;
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
        final dateStr = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
        _endDateController.text = dateStr;
      });
    }
  }

  Future<void> _selectTrailer() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      dialogTitle: _i18n.t('select_trailer_video'),
    );

    if (result != null && result.files.single.path != null) {
      final originalFileName = result.files.single.name;

      // Extract file extension
      final extension = originalFileName.split('.').last.toLowerCase();

      // Rename to trailer.<ext>
      final trailerFileName = 'trailer.$extension';

      // Copy to event folder
      final year = widget.event.id.substring(0, 4);
      final eventPath = '${widget.collectionPath}/events/$year/${widget.event.id}';
      final sourceFile = File(result.files.single.path!);
      final targetPath = '$eventPath/$trailerFileName';

      try {
        // Delete old trailer file if it exists and is different
        if (_trailerFileName != null && _trailerFileName != trailerFileName) {
          final oldTrailerFile = File('$eventPath/$_trailerFileName');
          if (await oldTrailerFile.exists()) {
            await oldTrailerFile.delete();
          }
        }

        // Copy new trailer
        await sourceFile.copy(targetPath);

        setState(() {
          _trailerFileName = trailerFileName;
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${_i18n.t('error')}: $e')),
          );
        }
      }
    }
  }

  void _removeTrailer() {
    setState(() {
      _trailerFileName = null;
    });
  }

  Future<void> _selectFlyer() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      dialogTitle: _i18n.t('select_flyer_image'),
    );

    if (result != null && result.files.single.path != null) {
      final originalFileName = result.files.single.name;
      final extension = originalFileName.split('.').last.toLowerCase();

      // Determine flyer filename
      String flyerFileName;
      if (_flyersList.isEmpty) {
        flyerFileName = 'flyer.$extension';  // Primary flyer
      } else {
        // Alt flyer (flyer-alt.jpg, flyer-alt2.jpg, etc.)
        int altNum = 1;
        flyerFileName = 'flyer-alt.$extension';
        while (_flyersList.contains(flyerFileName)) {
          altNum++;
          flyerFileName = 'flyer-alt$altNum.$extension';
        }
      }

      // Copy to event folder
      final year = widget.event.id.substring(0, 4);
      final eventPath = '${widget.collectionPath}/events/$year/${widget.event.id}';
      final sourceFile = File(result.files.single.path!);
      final targetPath = '$eventPath/$flyerFileName';

      try {
        await sourceFile.copy(targetPath);

        setState(() {
          _flyersList.add(flyerFileName);
          _flyersList.sort();  // Sort so primary flyer is first
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${_i18n.t('error')}: $e')),
          );
        }
      }
    }
  }

  Future<void> _removeFlyer(String flyerFileName) async {
    // Delete file from event folder
    final year = widget.event.id.substring(0, 4);
    final eventPath = '${widget.collectionPath}/events/$year/${widget.event.id}';
    final flyerFile = File('$eventPath/$flyerFileName');

    try {
      if (await flyerFile.exists()) {
        await flyerFile.delete();
      }

      setState(() {
        _flyersList.remove(flyerFileName);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_i18n.t('error')}: $e')),
        );
      }
    }
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

  List<String> _parseNpubs(String text) {
    if (text.trim().isEmpty) return [];
    return text
        .split(',')
        .map((npub) => npub.trim())
        .where((npub) => npub.isNotEmpty)
        .toList();
  }

  Future<void> _openMapPicker() async {
    // Parse current location if exists
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
        _locationController.text = '${result.latitude.toStringAsFixed(6)},${result.longitude.toStringAsFixed(6)}';
      });
    }
  }

  void _save() {
    final location = _isOnline ? 'online' : _locationController.text.trim();

    final result = <String, dynamic>{
      'title': _titleController.text.trim(),
      'location': location,
      'locationName': _locationNameController.text.trim().isNotEmpty
          ? _locationNameController.text.trim()
          : null,
      'content': _contentController.text.trim(),
      'agenda': _agendaController.text.trim().isNotEmpty
          ? _agendaController.text.trim()
          : null,
      'admins': _parseNpubs(_adminsController.text),
      'moderators': _parseNpubs(_moderatorsController.text),
      'visibility': _visibility,
      'trailer': _trailerFileName,
      'flyers': _flyersList,
      'links': _links,
      'registrationEnabled': _registrationEnabled,
    };

    // Add date information
    if (widget.event.isMultiDay) {
      result['startDate'] = _startDateController.text.trim();
      result['endDate'] = _endDateController.text.trim();
    } else {
      result['eventDateTime'] = _eventDateTime;
    }

    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('event_settings')),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: [
            Tab(text: _i18n.t('basic_info')),
            Tab(text: _i18n.t('media')),
            Tab(text: _i18n.t('access_control')),
            Tab(text: _i18n.t('links')),
            Tab(text: _i18n.t('registration')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              _i18n.t('cancel'),
              style: TextStyle(color: theme.colorScheme.onPrimary),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save, size: 18),
            label: Text(_i18n.t('save')),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.onPrimary,
              foregroundColor: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildBasicInfoTab(theme),
          _buildMediaTab(theme),
          _buildAccessControlTab(theme),
          _buildLinksTab(theme),
          _buildRegistrationTab(theme),
        ],
      ),
    );
  }

  Widget _buildBasicInfoTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // Title
        TextFormField(
          controller: _titleController,
          decoration: InputDecoration(
            labelText: _i18n.t('event_title'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),

        // Date section
        Text(
          _i18n.t('event_dates'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        if (widget.event.isMultiDay) ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selectStartDate,
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text(
                    _startDateController.text.isNotEmpty
                        ? _startDateController.text
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
                    _endDateController.text.isNotEmpty
                        ? _endDateController.text
                        : _i18n.t('end_date'),
                  ),
                ),
              ),
            ],
          ),
        ] else ...[
          OutlinedButton.icon(
            onPressed: _selectEventDateTime,
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text(
              '${_eventDateTime.year}-${_eventDateTime.month.toString().padLeft(2, '0')}-${_eventDateTime.day.toString().padLeft(2, '0')} '
              '${_eventDateTime.hour.toString().padLeft(2, '0')}:${_eventDateTime.minute.toString().padLeft(2, '0')}',
            ),
          ),
        ],
        const SizedBox(height: 24),

        // Location
        Text(
          _i18n.t('location'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          title: Text(_i18n.t('online_event')),
          value: _isOnline,
          onChanged: (value) {
            setState(() {
              _isOnline = value;
              if (value) {
                _locationController.clear();
              }
            });
          },
          contentPadding: EdgeInsets.zero,
        ),
        if (!_isOnline) ...[
          const SizedBox(height: 12),
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
        ],
        const SizedBox(height: 16),
        TextFormField(
          controller: _locationNameController,
          decoration: InputDecoration(
            labelText: _i18n.t('location_name'),
            hintText: _i18n.t('enter_location_name'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),

        // Description
        Text(
          _i18n.t('description'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _contentController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
          maxLines: 10,
        ),
        const SizedBox(height: 24),

        // Agenda
        Text(
          _i18n.t('agenda'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _agendaController,
          decoration: InputDecoration(
            hintText: _i18n.t('event_schedule_agenda'),
            border: const OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
          maxLines: 8,
        ),
      ],
    );
  }

  Widget _buildMediaTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          _i18n.t('trailer'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        if (_trailerFileName != null) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.movie),
              title: Text(_trailerFileName!),
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
          label: Text(_trailerFileName == null
              ? _i18n.t('select_trailer_video')
              : _i18n.t('change_trailer_video')),
        ),
        const SizedBox(height: 8),
        Text(
          _i18n.t('trailer_stored_event_folder'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 32),

        Text(
          _i18n.t('flyers'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        if (_flyersList.isNotEmpty) ...[
          ..._flyersList.map((flyer) => Card(
            child: ListTile(
              leading: const Icon(Icons.image),
              title: Text(flyer),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => _removeFlyer(flyer),
              ),
            ),
          )).toList(),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          onPressed: _selectFlyer,
          icon: const Icon(Icons.add_photo_alternate),
          label: Text(_flyersList.isEmpty
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
      ],
    );
  }

  Widget _buildAccessControlTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
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
              value: 'private',
              child: Row(
                children: [
                  const Icon(Icons.lock, size: 20),
                  const SizedBox(width: 8),
                  Text(_i18n.t('private')),
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
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() {
                _visibility = value;
              });
            }
          },
        ),
        const SizedBox(height: 32),

        Text(
          _i18n.t('permissions'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),

        TextFormField(
          controller: _adminsController,
          decoration: InputDecoration(
            labelText: _i18n.t('admins_optional'),
            hintText: _i18n.t('npubs_comma_separated'),
            border: const OutlineInputBorder(),
            helperText: _i18n.t('admins_help'),
          ),
          maxLines: 3,
        ),
        const SizedBox(height: 24),

        TextFormField(
          controller: _moderatorsController,
          decoration: InputDecoration(
            labelText: _i18n.t('moderators_optional'),
            hintText: _i18n.t('npubs_comma_separated'),
            border: const OutlineInputBorder(),
            helperText: _i18n.t('moderators_help'),
          ),
          maxLines: 3,
        ),
      ],
    );
  }

  Widget _buildLinksTab(ThemeData theme) {
    return Column(
      children: [
        // Toolbar
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
        // Links list
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

  Widget _buildRegistrationTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          _i18n.t('registration'),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _i18n.t('registration_help'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
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
}

/// Dialog for adding/editing a link
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
  late TextEditingController _descriptionController;
  late TextEditingController _urlController;
  late TextEditingController _passwordController;
  late TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    _descriptionController = TextEditingController(text: widget.link?.description ?? '');
    _urlController = TextEditingController(text: widget.link?.url ?? '');
    _passwordController = TextEditingController(text: widget.link?.password ?? '');
    _noteController = TextEditingController(text: widget.link?.note ?? '');
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _urlController.dispose();
    _passwordController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      child: Container(
        width: 500,
        constraints: const BoxConstraints(maxHeight: 600),
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.link == null ? widget.i18n.t('add_link') : widget.i18n.t('edit_link'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Description
                      TextFormField(
                        controller: _descriptionController,
                        decoration: InputDecoration(
                          labelText: widget.i18n.t('link_description'),
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return widget.i18n.t('description_required');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // URL
                      TextFormField(
                        controller: _urlController,
                        decoration: InputDecoration(
                          labelText: widget.i18n.t('url'),
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

                      // Password (optional)
                      TextFormField(
                        controller: _passwordController,
                        decoration: InputDecoration(
                          labelText: widget.i18n.t('password_optional'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Note (optional)
                      TextFormField(
                        controller: _noteController,
                        decoration: InputDecoration(
                          labelText: widget.i18n.t('note_optional'),
                          border: const OutlineInputBorder(),
                        ),
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
                  FilledButton(
                    onPressed: () {
                      if (_formKey.currentState!.validate()) {
                        final link = EventLink(
                          url: _urlController.text.trim(),
                          description: _descriptionController.text.trim(),
                          password: _passwordController.text.trim().isNotEmpty
                              ? _passwordController.text.trim()
                              : null,
                          note: _noteController.text.trim().isNotEmpty
                              ? _noteController.text.trim()
                              : null,
                        );
                        widget.onSave(link);
                        Navigator.pop(context);
                      }
                    },
                    child: Text(widget.i18n.t('save')),
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
