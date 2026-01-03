/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:latlong2/latlong.dart';
import '../dialogs/place_picker_dialog.dart';
import '../models/event.dart';
import '../models/event_link.dart';
import '../models/group.dart';
import '../models/place.dart';
import '../services/collection_service.dart';
import '../services/groups_service.dart';
import '../services/place_service.dart';
import '../services/profile_service.dart';
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
  String _locationType = 'coordinates'; // 'coordinates', 'place', 'online'
  Place? _selectedPlace;
  String? _selectedPlacePath;
  late DateTime _eventDate;
  TimeOfDay? _eventTime;
  bool _isMultiDay = false;
  late TextEditingController _startDateController;
  late TextEditingController _endDateController;
  late DateTime? _startDate;
  late DateTime? _endDate;

  // Access Control
  late TextEditingController _adminsController;
  late TextEditingController _moderatorsController;
  late String _visibility;
  final List<_GroupOption> _availableGroups = [];
  final Set<String> _selectedGroups = {};
  bool _isLoadingGroups = true;

  // Media
  List<File> _mediaFiles = [];
  bool _isLoadingMedia = true;
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
    _selectedPlacePath = widget.event.placePath;

    // Determine location type
    if (widget.event.isOnline && (_selectedPlacePath == null || _selectedPlacePath!.isEmpty)) {
      _locationType = 'online';
    } else if (_selectedPlacePath != null && _selectedPlacePath!.isNotEmpty) {
      _locationType = 'place';
    } else {
      _locationType = 'coordinates';
    }

    _locationController = TextEditingController(
      text: _locationType == 'online'
          ? ''
          : widget.event.hasCoordinates
              ? widget.event.location
              : '',
    );
    _locationNameController = TextEditingController(
      text: widget.event.locationName ?? '',
    );

    // Initialize dates
    _isMultiDay = widget.event.isMultiDay;
    if (_isMultiDay) {
      _startDate = _parseDate(widget.event.startDate ?? '');
      _endDate = _parseDate(widget.event.endDate ?? '');
      _startDateController = TextEditingController(text: widget.event.startDate ?? '');
      _endDateController = TextEditingController(text: widget.event.endDate ?? '');
      _eventDate = DateTime.now();
      _eventTime = null;
    } else {
      _eventDate = DateTime(
        widget.event.dateTime.year,
        widget.event.dateTime.month,
        widget.event.dateTime.day,
      );
      _eventTime = TimeOfDay.fromDateTime(widget.event.dateTime);
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
    _selectedGroups.addAll(widget.event.groupAccess);
    _loadGroups();

    // Initialize media
    _trailerFileName = widget.event.trailer;
    _flyersList = List.from(widget.event.flyers);
    _loadMediaFiles();

    // Initialize links
    _links = List.from(widget.event.links);

    // Initialize registration
    _registrationEnabled = widget.event.hasRegistration;

    _loadLinkedPlace();
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
        _startDateController.text = _formatDate(picked);
        if (_endDate != null && _endDate!.isBefore(_startDate!)) {
          _endDate = null;
          _endDateController.clear();
        }
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
        _endDateController.text = _formatDate(picked);
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
      final eventPath = '${widget.collectionPath}/$year/${widget.event.id}';
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

  Future<void> _loadMediaFiles() async {
    setState(() => _isLoadingMedia = true);

    try {
      final year = widget.event.id.substring(0, 4);
      final eventDir = Directory(
        '${widget.collectionPath}/$year/${widget.event.id}',
      );

      if (await eventDir.exists()) {
        final entities = await eventDir.list().toList();
        _mediaFiles = entities.whereType<File>().where((file) {
          final name = path.basename(file.path);
          return !_isMediaFileExcluded(name);
        }).toList()
          ..sort((a, b) => path.basename(a.path).compareTo(path.basename(b.path)));
      } else {
        _mediaFiles = [];
      }
    } catch (e) {
      _mediaFiles = [];
    }

    if (!mounted) return;
    setState(() => _isLoadingMedia = false);
  }

  bool _isMediaFileExcluded(String fileName) {
    if (fileName.startsWith('.')) return true;
    if (fileName == 'event.txt') return true;
    if (fileName == 'links.txt') return true;
    if (fileName == 'registration.txt') return true;
    if (_trailerFileName != null && fileName == _trailerFileName) return true;
    if (_flyersList.contains(fileName)) return true;
    return false;
  }

  IconData _mediaFileIcon(String fileName) {
    final ext = path.extension(fileName).toLowerCase();
    if (['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'].contains(ext)) {
      return Icons.image;
    }
    if (['.pdf'].contains(ext)) return Icons.picture_as_pdf;
    if (['.doc', '.docx', '.txt', '.md'].contains(ext)) return Icons.description;
    if (['.mp4', '.avi', '.mov', '.mkv'].contains(ext)) return Icons.video_file;
    if (['.mp3', '.wav', '.ogg', '.m4a'].contains(ext)) return Icons.audio_file;
    if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) return Icons.folder_zip;
    return Icons.insert_drive_file;
  }

  Future<String> _ensureUniqueFileName(String eventPath, String fileName) async {
    final ext = path.extension(fileName);
    final base = path.basenameWithoutExtension(fileName);
    var candidate = fileName;
    var counter = 2;

    while (await File('$eventPath/$candidate').exists()) {
      candidate = ext.isEmpty ? '$base-$counter' : '$base-$counter$ext';
      counter++;
    }

    return candidate;
  }

  Future<void> _selectMediaFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
      dialogTitle: _i18n.t('select_files_to_add'),
    );

    if (result == null || result.files.isEmpty) return;

    final year = widget.event.id.substring(0, 4);
    final eventPath = '${widget.collectionPath}/$year/${widget.event.id}';

    int copied = 0;
    for (final file in result.files) {
      if (file.path == null) continue;
      final sourceFile = File(file.path!);
      final targetName = await _ensureUniqueFileName(eventPath, file.name);
      try {
        await sourceFile.copy('$eventPath/$targetName');
        copied++;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${_i18n.t('error')}: $e')),
          );
        }
      }
    }

    if (copied > 0 && mounted) {
      await _loadMediaFiles();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('files_uploaded', params: [copied.toString()])),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _removeMediaFile(File file) async {
    try {
      await file.delete();
      await _loadMediaFiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('file_deleted'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_i18n.t('error')}: $e')),
        );
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
      final eventPath = '${widget.collectionPath}/$year/${widget.event.id}';
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
    final eventPath = '${widget.collectionPath}/$year/${widget.event.id}';
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
          _availableGroups.add(_GroupOption(
            group: group,
            collectionTitle: collection.title,
          ));
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
        _selectedPlacePath = place.folderPath;
        _locationType = 'place';
        _locationController.clear();
        _locationNameController.text = placeName;
      });
    }
  }

  void _clearSelectedPlace() {
    setState(() {
      _selectedPlace = null;
      _selectedPlacePath = null;
    });
  }

  Future<void> _loadLinkedPlace() async {
    final placePath = _selectedPlacePath;
    if (placePath == null || placePath.isEmpty) return;
    final resolvedPath = _resolvePlacePath(placePath);
    if (resolvedPath == null) return;

    try {
      final placeFile = File(path.join(resolvedPath, 'place.txt'));
      if (!await placeFile.exists()) return;
      final content = await placeFile.readAsString();
      final place = PlaceService().parsePlaceContent(
        content: content,
        filePath: placeFile.path,
        folderPath: resolvedPath,
      );
      if (place == null || !mounted) return;
      setState(() {
        _selectedPlace = place;
        if (_locationNameController.text.trim().isEmpty) {
          final langCode = _i18n.currentLanguage.split('_').first.toUpperCase();
          _locationNameController.text = place.getName(langCode);
        }
      });
    } catch (e) {
      // Ignore load errors
    }
  }

  String? _resolvePlacePath(String placePath) {
    if (placePath.isEmpty) return null;
    if (path.isAbsolute(placePath)) return placePath;
    if (widget.collectionPath.isEmpty) return null;
    final basePath = path.dirname(widget.collectionPath);
    return path.normalize(path.join(basePath, placePath));
  }

  void _save() {
    final location = _locationType == 'online'
        ? 'online'
        : _locationType == 'place' && (_selectedPlacePath != null || _selectedPlace != null)
            ? 'place'
            : _locationController.text.trim();

    if (_locationType == 'coordinates' && location.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('location_required')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

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

    final placePath = _buildPlacePathReference();
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
      'groupAccess': _selectedGroups.toList(),
      'trailer': _trailerFileName,
      'flyers': _flyersList,
      'links': _links,
      'registrationEnabled': _registrationEnabled,
      'placePath': placePath,
      'isMultiDay': _isMultiDay,
    };

    // Add date information
    if (_isMultiDay) {
      result['startDate'] = _formatDate(_startDate!);
      result['endDate'] = _formatDate(_endDate!);
    } else {
      result['eventDateTime'] = eventDateTime;
    }

    Navigator.pop(context, result);
  }

  String _buildPlacePathReference() {
    final rawPath = _selectedPlacePath ?? _selectedPlace?.folderPath;
    if (rawPath == null || rawPath.isEmpty) return '';
    if (path.isAbsolute(rawPath)) {
      if (widget.collectionPath.isNotEmpty) {
        final basePath = path.dirname(widget.collectionPath);
        final relative = path.relative(rawPath, from: basePath);
        if (!relative.startsWith('..')) {
          return relative;
        }
      }
    }
    return rawPath;
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
            Tab(text: _i18n.t('links')),
            Tab(text: _i18n.t('updates_agenda')),
            Tab(text: _i18n.t('access_control')),
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
          _buildLinksTab(theme),
          _buildUpdatesTab(theme),
          _buildAccessControlTab(theme),
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
            hintText: _i18n.t('enter_event_title'),
            border: const OutlineInputBorder(),
          ),
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
                _startDateController.clear();
                _endDateController.clear();
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
                  _selectedPlacePath = null;
                } else if (value == 'coordinates') {
                  _selectedPlace = null;
                  _selectedPlacePath = null;
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
        ),
        const SizedBox(height: 24),

        // Description
        TextFormField(
          controller: _contentController,
          decoration: InputDecoration(
            labelText: _i18n.t('event_description'),
            border: const OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
          maxLines: 8,
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
              onPressed: _selectFlyer,
              icon: const Icon(Icons.add_photo_alternate, size: 18),
              label: Text(_i18n.t('add_photos')),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_flyersList.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
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
            itemCount: _flyersList.length,
            itemBuilder: (context, index) {
              final flyer = _flyersList[index];
              final isPrimary = index == 0;
              return _buildPhotoTile(theme, flyer, isPrimary, index);
            },
          ),
      ],
    );
  }

  String _getEventFolderPath() {
    final year = widget.event.id.substring(0, 4);
    return '${widget.collectionPath}/$year/${widget.event.id}';
  }

  Widget _buildPhotoTile(ThemeData theme, String flyerFileName, bool isPrimary, int index) {
    final eventPath = _getEventFolderPath();
    final flyerPath = '$eventPath/$flyerFileName';

    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: kIsWeb
              ? Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.image),
                )
              : Image.file(
                  File(flyerPath),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: theme.colorScheme.surfaceContainerHighest,
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
                () => _removeFlyer(flyerFileName),
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

  Future<void> _setAsPrimaryPhoto(int index) async {
    if (index == 0 || index >= _flyersList.length) return;

    final eventPath = _getEventFolderPath();
    final flyerToPromote = _flyersList[index];
    final currentPrimary = _flyersList[0];

    try {
      // Get file extensions
      final promoteExt = path.extension(flyerToPromote);
      final primaryExt = path.extension(currentPrimary);

      // Rename files
      final tempName = 'flyer-temp$promoteExt';
      final newPrimaryName = 'flyer$promoteExt';
      final newAltName = 'flyer-1$primaryExt';

      // Move promoted file to temp
      final promoteFile = File('$eventPath/$flyerToPromote');
      if (await promoteFile.exists()) {
        await promoteFile.rename('$eventPath/$tempName');
      }

      // Rename current primary to alt
      final primaryFile = File('$eventPath/$currentPrimary');
      if (await primaryFile.exists()) {
        await primaryFile.rename('$eventPath/$newAltName');
      }

      // Rename temp to primary
      final tempFile = File('$eventPath/$tempName');
      if (await tempFile.exists()) {
        await tempFile.rename('$eventPath/$newPrimaryName');
      }

      setState(() {
        _flyersList[0] = newPrimaryName;
        _flyersList[index] = newAltName;
        _flyersList.sort();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_i18n.t('error')}: $e')),
        );
      }
    }
  }

  Widget _buildMediaTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
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
        if (_isLoadingMedia)
          const LinearProgressIndicator()
        else if (_mediaFiles.isEmpty)
          Text(
            _i18n.t('no_files_yet'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else ...[
          ..._mediaFiles.map((file) {
            final name = path.basename(file.path);
            return Card(
              child: ListTile(
                leading: Icon(_mediaFileIcon(name)),
                title: Text(name),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  tooltip: _i18n.t('remove'),
                  onPressed: () => _removeMediaFile(file),
                ),
              ),
            );
          }),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _selectMediaFiles,
          icon: const Icon(Icons.add),
          label: Text(_i18n.t('add_files')),
        ),
        const SizedBox(height: 32),
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
        TextFormField(
          controller: _agendaController,
          decoration: InputDecoration(
            hintText: _i18n.t('event_schedule_agenda'),
            border: const OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
          maxLines: 6,
        ),
        const SizedBox(height: 32),

        // Updates section (info only for edit mode)
        Text(
          _i18n.t('updates'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _i18n.t('updates_managed_event_detail'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GroupOption {
  final Group group;
  final String? collectionTitle;

  const _GroupOption({
    required this.group,
    this.collectionTitle,
  });
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
