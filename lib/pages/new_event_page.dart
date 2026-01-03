/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:latlong2/latlong.dart';

import '../dialogs/new_update_dialog.dart';
import '../dialogs/place_picker_dialog.dart';
import '../models/event_link.dart';
import '../models/group.dart';
import '../models/place.dart';
import '../services/collection_service.dart';
import '../services/groups_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../services/location_service.dart';
import 'location_picker_page.dart';

/// Full-screen page for creating a new event
class NewEventPage extends StatefulWidget {
  const NewEventPage({Key? key}) : super(key: key);

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
  final String? collectionTitle;

  const _GroupOption(this.group, this.collectionTitle);
}

class _NewEventPageState extends State<NewEventPage>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _i18n = I18nService();
  late TabController _tabController;

  final _titleController = TextEditingController();
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _loadGroups();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleController.dispose();
    _locationController.dispose();
    _locationNameController.dispose();
    _contentController.dispose();
    _agendaController.dispose();
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
    final selection = await showDialog<PlaceSelection>(
      context: context,
      builder: (context) => PlacePickerDialog(i18n: _i18n),
    );

    if (selection != null) {
      final place = selection.place;
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
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      dialogTitle: _i18n.t('select_trailer_video'),
    );

    if (result != null && result.files.single.path != null) {
      final originalFileName = result.files.single.name;
      final extension = path.extension(originalFileName).replaceFirst('.', '').toLowerCase();
      final trailerFileName = extension.isNotEmpty
          ? 'trailer.$extension'
          : 'trailer.mp4';

      setState(() {
        _trailer = _PendingFile(
          path: result.files.single.path!,
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
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      dialogTitle: _i18n.t('select_flyer_image'),
    );

    if (result != null && result.files.single.path != null) {
      final originalFileName = result.files.single.name;
      final extension = path.extension(originalFileName).replaceFirst('.', '').toLowerCase();

      String flyerFileName;
      if (_flyers.isEmpty) {
        flyerFileName = extension.isNotEmpty ? 'flyer.$extension' : 'flyer.jpg';
      } else {
        int altNum = 1;
        flyerFileName = extension.isNotEmpty
            ? 'flyer-alt.$extension'
            : 'flyer-alt.jpg';
        while (_flyers.any((flyer) => flyer.targetName == flyerFileName)) {
          altNum++;
          flyerFileName = extension.isNotEmpty
              ? 'flyer-alt$altNum.$extension'
              : 'flyer-alt$altNum.jpg';
        }
      }

      setState(() {
        _flyers.add(
          _PendingFile(
            path: result.files.single.path!,
            name: originalFileName,
            targetName: flyerFileName,
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
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      dialogTitle: _i18n.t('add_files'),
    );

    if (result == null) return;

    final pending = <_PendingFile>[];
    for (final file in result.files) {
      if (file.path == null) continue;
      pending.add(
        _PendingFile(
          path: file.path!,
          name: file.name,
          targetName: file.name,
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
      final collections = await CollectionService().loadCollections();
      final groupCollections = collections
          .where((c) => c.type == 'groups' && c.storagePath != null)
          .toList();

      _availableGroups.clear();
      final groupsService = GroupsService();
      final profile = ProfileService().getProfile();

      for (final collection in groupCollections) {
        await groupsService.initializeCollection(
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
      'links': _links,
      'updates': _updates.map((update) => update.toMap()).toList(),
      'flyers': _flyers.map((file) => file.toMap()).toList(),
      'trailer': _trailer?.toMap(),
      'mediaFiles': _mediaFiles.map((file) => file.toMap()).toList(),
      'registrationEnabled': _registrationEnabled,
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
        title: Text(_i18n.t('create_event')),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: [
            Tab(text: _i18n.t('basic_info')),
            Tab(text: _i18n.t('media')),
            Tab(text: _i18n.t('links')),
            Tab(text: _i18n.t('updates_agenda')),
            Tab(text: _i18n.t('access_control')),
          ],
        ),
        actions: [
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.check, size: 18),
            label: Text(_i18n.t('create')),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.onPrimary,
              foregroundColor: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 16),
        ],
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
          ],
        ),
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
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() {
                _locationType = value;
                if (value == 'online') {
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
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      dialogTitle: _i18n.t('select_photos'),
    );

    if (result == null || result.files.isEmpty) return;

    setState(() {
      for (final file in result.files) {
        if (file.path == null) continue;
        final originalFileName = file.name;
        final extension = path.extension(originalFileName).replaceFirst('.', '').toLowerCase();

        String flyerFileName;
        if (_flyers.isEmpty) {
          flyerFileName = extension.isNotEmpty ? 'flyer.$extension' : 'flyer.jpg';
        } else {
          int altNum = _flyers.length;
          flyerFileName = extension.isNotEmpty
              ? 'flyer-$altNum.$extension'
              : 'flyer-$altNum.jpg';
          while (_flyers.any((flyer) => flyer.targetName == flyerFileName)) {
            altNum++;
            flyerFileName = extension.isNotEmpty
                ? 'flyer-$altNum.$extension'
                : 'flyer-$altNum.jpg';
          }
        }

        _flyers.add(
          _PendingFile(
            path: file.path!,
            name: originalFileName,
            targetName: flyerFileName,
          ),
        );
      }
    });
  }

  void _setAsPrimaryPhoto(int index) {
    if (index == 0 || index >= _flyers.length) return;
    setState(() {
      final photo = _flyers.removeAt(index);
      // Rename to be primary (flyer.ext)
      final extension = path.extension(photo.targetName);
      final primaryName = 'flyer$extension';
      // Rename old primary
      if (_flyers.isNotEmpty) {
        final oldPrimary = _flyers.first;
        final oldExt = path.extension(oldPrimary.targetName);
        _flyers[0] = _PendingFile(
          path: oldPrimary.path,
          name: oldPrimary.name,
          targetName: 'flyer-1$oldExt',
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
        const SizedBox(height: 32),
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
              if (option.collectionTitle != null && option.collectionTitle!.isNotEmpty) {
                subtitleParts.add(option.collectionTitle!);
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
