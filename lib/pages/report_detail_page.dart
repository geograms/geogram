/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import '../models/report.dart';
import '../models/report_update.dart';
import '../models/report_comment.dart';
import '../services/report_service.dart';
import '../services/profile_service.dart';
import '../services/log_service.dart';
import '../services/i18n_service.dart';
import 'location_picker_page.dart';

/// Page for viewing and editing report details
class ReportDetailPage extends StatefulWidget {
  final String collectionPath;
  final Report? report; // null for new report

  const ReportDetailPage({
    super.key,
    required this.collectionPath,
    this.report,
  });

  @override
  State<ReportDetailPage> createState() => _ReportDetailPageState();
}

class _ReportDetailPageState extends State<ReportDetailPage> {
  final ReportService _reportService = ReportService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();

  late bool _isNew;
  late bool _isEditing;
  Report? _report;
  List<ReportUpdate> _updates = [];
  List<ReportComment> _comments = [];
  bool _isLoading = false;
  String? _currentUserNpub;
  List<File> _imageFiles = [];
  List<String> _existingImages = [];

  // Form controllers
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _latitudeController = TextEditingController();
  final _longitudeController = TextEditingController();
  final _addressController = TextEditingController();
  final _contactController = TextEditingController();
  final _commentController = TextEditingController();

  ReportSeverity _selectedSeverity = ReportSeverity.attention;
  ReportStatus _selectedStatus = ReportStatus.open;
  String _selectedType = 'other';
  String _locationInputMode = 'map'; // 'map' or 'manual'

  // Common report types
  static const List<Map<String, String>> _reportTypes = [
    {'value': 'infrastructure-broken', 'label': 'Broken Infrastructure'},
    {'value': 'infrastructure-damaged', 'label': 'Damaged Infrastructure'},
    {'value': 'road-pothole', 'label': 'Road Pothole'},
    {'value': 'road-damage', 'label': 'Road Damage'},
    {'value': 'traffic-accident', 'label': 'Traffic Accident'},
    {'value': 'traffic-congestion', 'label': 'Traffic Congestion'},
    {'value': 'vandalism', 'label': 'Vandalism'},
    {'value': 'graffiti', 'label': 'Graffiti'},
    {'value': 'hazard-general', 'label': 'General Hazard'},
    {'value': 'hazard-environmental', 'label': 'Environmental Hazard'},
    {'value': 'hazard-chemical', 'label': 'Chemical Hazard'},
    {'value': 'fire', 'label': 'Fire'},
    {'value': 'flood', 'label': 'Flood'},
    {'value': 'weather-severe', 'label': 'Severe Weather'},
    {'value': 'utility-outage', 'label': 'Utility Outage'},
    {'value': 'water-leak', 'label': 'Water Leak'},
    {'value': 'gas-leak', 'label': 'Gas Leak'},
    {'value': 'power-outage', 'label': 'Power Outage'},
    {'value': 'street-light-out', 'label': 'Street Light Out'},
    {'value': 'public-health', 'label': 'Public Health Issue'},
    {'value': 'waste-illegal', 'label': 'Illegal Waste Disposal'},
    {'value': 'noise-complaint', 'label': 'Noise Complaint'},
    {'value': 'animal-issue', 'label': 'Animal Issue'},
    {'value': 'security-concern', 'label': 'Security Concern'},
    {'value': 'maintenance-needed', 'label': 'Maintenance Needed'},
    {'value': 'other', 'label': 'Other'},
  ];

  @override
  void initState() {
    super.initState();
    _isNew = widget.report == null;
    _isEditing = _isNew;
    _report = widget.report;

    final profile = _profileService.getProfile();
    _currentUserNpub = profile.npub;

    if (_report != null) {
      _titleController.text = _report!.getTitle('EN');
      _descriptionController.text = _report!.getDescription('EN');
      _latitudeController.text = _report!.latitude.toString();
      _longitudeController.text = _report!.longitude.toString();
      _addressController.text = _report!.address ?? '';
      _contactController.text = _report!.contact ?? '';
      _selectedType = _report!.type;
      _selectedSeverity = _report!.severity;
      _selectedStatus = _report!.status;

      _loadUpdates();
      _loadComments();
      _loadExistingImages();
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _latitudeController.dispose();
    _longitudeController.dispose();
    _addressController.dispose();
    _contactController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _loadUpdates() async {
    if (_report == null) return;

    setState(() => _isLoading = true);

    try {
      _updates = await _reportService.loadUpdates(_report!.folderName);
    } catch (e) {
      LogService().log('ReportDetailPage: Error loading updates: $e');
    }

    setState(() => _isLoading = false);
  }

  Future<void> _loadComments() async {
    if (_report == null) return;

    try {
      _comments = await _reportService.loadComments(_report!.folderName);
      setState(() {});
    } catch (e) {
      LogService().log('ReportDetailPage: Error loading comments: $e');
    }
  }

  Future<void> _addComment() async {
    if (_report == null || _commentController.text.trim().isEmpty) return;

    final profile = _profileService.getProfile();
    if (profile.callsign.isEmpty) {
      _showError('Please set up your profile first');
      return;
    }

    setState(() => _isLoading = true);

    try {
      await _reportService.addComment(
        _report!.folderName,
        profile.callsign,
        _commentController.text.trim(),
        npub: _currentUserNpub,
      );
      _commentController.clear();
      await _loadComments();
      _showSuccess(_i18n.t('comment_added'));
    } catch (e) {
      _showError('Failed to add comment: $e');
    }

    setState(() => _isLoading = false);
  }

  Future<void> _toggleLike() async {
    if (_report == null || _currentUserNpub == null || _currentUserNpub!.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      if (_report!.isLikedBy(_currentUserNpub!)) {
        await _reportService.unlikeReport(_report!.folderName, _currentUserNpub!);
      } else {
        await _reportService.likeReport(_report!.folderName, _currentUserNpub!);
      }

      // Reload report
      _report = await _reportService.loadReport(_report!.folderName);
      setState(() {});
    } catch (e) {
      _showError('Failed to toggle like: $e');
    }

    setState(() => _isLoading = false);
  }

  Future<void> _pickLocationOnMap() async {
    // Get current coordinates if valid
    final currentLat = double.tryParse(_latitudeController.text);
    final currentLon = double.tryParse(_longitudeController.text);
    LatLng? initialPosition;

    if (currentLat != null && currentLon != null &&
        currentLat >= -90 && currentLat <= 90 &&
        currentLon >= -180 && currentLon <= 180) {
      initialPosition = LatLng(currentLat, currentLon);
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
        _latitudeController.text = result.latitude.toStringAsFixed(6);
        _longitudeController.text = result.longitude.toStringAsFixed(6);
      });
    }
  }

  Future<void> _pickImages() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _imageFiles.addAll(
            result.files.map((file) => File(file.path!)).toList(),
          );
        });
      }
    } catch (e) {
      _showError('Error picking images: $e');
    }
  }

  Future<void> _loadExistingImages() async {
    if (_report == null) return;

    try {
      final reportDir = Directory(path.join(
        widget.collectionPath,
        _report!.folderName,
      ));
      final imagesDir = Directory(path.join(reportDir.path, 'images'));

      if (await imagesDir.exists()) {
        final entities = await imagesDir.list().toList();
        setState(() {
          _existingImages = entities
              .where((e) => e is File && _isImageFile(e.path))
              .map((e) => e.path)
              .toList();
        });
      }
    } catch (e) {
      LogService().log('Error loading images: $e');
    }
  }

  bool _isImageFile(String filePath) {
    final ext = path.extension(filePath).toLowerCase();
    return ['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext);
  }

  void _removeImage(int index, {bool isExisting = false}) {
    setState(() {
      if (isExisting) {
        _existingImages.removeAt(index);
      } else {
        _imageFiles.removeAt(index);
      }
    });
  }

  Future<void> _saveImages() async {
    if (_report == null || _imageFiles.isEmpty) return;

    try {
      final reportDir = Directory(path.join(
        widget.collectionPath,
        _report!.folderName,
      ));
      final imagesDir = Directory(path.join(reportDir.path, 'images'));

      // Create images directory if it doesn't exist
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }

      // Copy new images to the images folder
      for (final imageFile in _imageFiles) {
        final fileName = path.basename(imageFile.path);
        final destPath = path.join(imagesDir.path, fileName);
        await imageFile.copy(destPath);
      }

      // Clear the list and reload existing images
      _imageFiles.clear();
      await _loadExistingImages();
    } catch (e) {
      LogService().log('Error saving images: $e');
      rethrow;
    }
  }

  Future<void> _save() async {
    // Validate
    if (_titleController.text.trim().isEmpty) {
      _showError('Title is required');
      return;
    }

    if (_descriptionController.text.trim().isEmpty) {
      _showError('Description is required');
      return;
    }

    final lat = double.tryParse(_latitudeController.text);
    final lon = double.tryParse(_longitudeController.text);

    if (lat == null || lon == null) {
      _showError('Valid coordinates are required');
      return;
    }

    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      _showError('Coordinates out of range');
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (_isNew) {
        // Create new report
        final profile = _profileService.getProfile();
        if (profile.callsign.isEmpty) {
          _showError('Please set up your profile first');
          setState(() => _isLoading = false);
          return;
        }

        _report = await _reportService.createReport(
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          author: profile.callsign,
          latitude: lat,
          longitude: lon,
          severity: _selectedSeverity,
          type: _selectedType,
          address: _addressController.text.trim().isNotEmpty ? _addressController.text.trim() : null,
          contact: _contactController.text.trim().isNotEmpty ? _contactController.text.trim() : null,
        );

        // Save images
        await _saveImages();

        _showSuccess('Report created');
        setState(() {
          _isNew = false;
          _isEditing = false;
        });
      } else if (_report != null) {
        // Update existing report
        final updated = _report!.copyWith(
          titles: {'EN': _titleController.text.trim()},
          descriptions: {'EN': _descriptionController.text.trim()},
          latitude: lat,
          longitude: lon,
          severity: _selectedSeverity,
          status: _selectedStatus,
          type: _selectedType,
          address: _addressController.text.trim().isNotEmpty ? _addressController.text.trim() : null,
          contact: _contactController.text.trim().isNotEmpty ? _contactController.text.trim() : null,
        );

        await _reportService.saveReport(updated);
        _report = updated;

        // Save images
        await _saveImages();

        _showSuccess('Report updated');
        setState(() {
          _isEditing = false;
        });
      }
    } catch (e) {
      _showError('Failed to save: $e');
      LogService().log('ReportDetailPage: Error saving: $e');
    }

    setState(() => _isLoading = false);
  }

  Future<void> _toggleSubscription() async {
    if (_report == null || _currentUserNpub == null || _currentUserNpub!.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      if (_report!.isSubscribed(_currentUserNpub!)) {
        await _reportService.unsubscribe(_report!.folderName, _currentUserNpub!);
        _showSuccess('Unsubscribed');
      } else {
        await _reportService.subscribe(_report!.folderName, _currentUserNpub!);
        _showSuccess('Subscribed');
      }

      // Reload report
      _report = await _reportService.loadReport(_report!.folderName);
      setState(() {});
    } catch (e) {
      _showError('Failed to toggle subscription: $e');
    }

    setState(() => _isLoading = false);
  }

  Future<void> _verify() async {
    if (_report == null || _currentUserNpub == null || _currentUserNpub!.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      await _reportService.verify(_report!.folderName, _currentUserNpub!);
      _showSuccess('Verified');

      // Reload report
      _report = await _reportService.loadReport(_report!.folderName);
      setState(() {});
    } catch (e) {
      _showError('Failed to verify: $e');
    }

    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = _profileService.getProfile();
    final isAuthor = _report != null && _report!.author == profile.callsign;
    final canEdit = _report == null ||
                     isAuthor ||
                     (_currentUserNpub != null && _report!.isAdmin(_currentUserNpub!));

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? _i18n.t('new_alert') : _i18n.t('alert_details')),
        actions: [
          if (!_isNew && !_isEditing && canEdit)
            IconButton(
              icon: Icon(Icons.edit),
              onPressed: () {
                setState(() {
                  _isEditing = true;
                });
              },
            ),
          if (_isEditing)
            IconButton(
              icon: Icon(Icons.save),
              onPressed: _isLoading ? null : _save,
            ),
        ],
      ),
      body: _isLoading && _report == null
          ? Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Status badges
                  if (_report != null) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildSeverityChip(_report!.severity),
                        _buildStatusChip(_report!.status),
                        if (_report!.verificationCount > 0)
                          Chip(
                            avatar: Icon(Icons.verified, color: Colors.green, size: 16),
                            label: Text('${_report!.verificationCount} verifications'),
                          ),
                        if (_report!.isExpired)
                          Chip(
                            avatar: Icon(Icons.warning, color: Colors.orange, size: 16),
                            label: Text(_i18n.t('expired')),
                          ),
                      ],
                    ),
                    SizedBox(height: 16),
                  ],

                  // Title
                  if (_isEditing)
                    TextField(
                      controller: _titleController,
                      decoration: InputDecoration(
                        labelText: _i18n.t('title') + ' *',
                        hintText: _i18n.t('title_hint'),
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 2,
                    )
                  else
                    _buildReadOnlyField(
                      label: _i18n.t('title'),
                      value: _titleController.text,
                      theme: theme,
                    ),
                  SizedBox(height: 16),

                  // Description
                  if (_isEditing)
                    TextField(
                      controller: _descriptionController,
                      decoration: InputDecoration(
                        labelText: _i18n.t('description') + ' *',
                        hintText: _i18n.t('description_hint'),
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 8,
                    )
                  else
                    _buildReadOnlyField(
                      label: _i18n.t('description'),
                      value: _descriptionController.text,
                      theme: theme,
                      isMultiline: true,
                    ),
                  SizedBox(height: 16),

                  // Location Section
                  Text(
                    _isEditing ? _i18n.t('location') + ' *' : _i18n.t('location'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),

                  // Location Input Mode Selector
                  if (_isEditing)
                    DropdownButtonFormField<String>(
                      value: _locationInputMode,
                      decoration: InputDecoration(
                        labelText: _i18n.t('input_method'),
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'map',
                          child: Row(
                            children: [
                              Icon(Icons.map, size: 20),
                              SizedBox(width: 8),
                              Text(_i18n.t('pick_on_map')),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'manual',
                          child: Row(
                            children: [
                              Icon(Icons.edit_location, size: 20),
                              SizedBox(width: 8),
                              Text(_i18n.t('enter_manually')),
                            ],
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            _locationInputMode = value;
                          });
                        }
                      },
                    ),
                  if (_isEditing) SizedBox(height: 16),

                  // Map Picker Button
                  if (_isEditing && _locationInputMode == 'map')
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _pickLocationOnMap,
                        icon: Icon(Icons.map),
                        label: Text(_i18n.t('pick_location_on_map')),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ),
                  if (_isEditing && _locationInputMode == 'map') SizedBox(height: 16),

                  // Coordinates Display/Input
                  if (_isEditing && _locationInputMode == 'manual')
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _latitudeController,
                            decoration: InputDecoration(
                              labelText: _i18n.t('latitude') + ' *',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                          ),
                        ),
                        SizedBox(width: 16),
                        Expanded(
                          child: TextField(
                            controller: _longitudeController,
                            decoration: InputDecoration(
                              labelText: _i18n.t('longitude') + ' *',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                          ),
                        ),
                      ],
                    )
                  else if (!_isEditing)
                    _buildCoordinatesField(theme),
                  if (_isEditing && _locationInputMode == 'manual' || !_isEditing) SizedBox(height: 16),

                  // Show current coordinates when using map mode
                  if (_isEditing && _locationInputMode == 'map')
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.location_on, size: 16, color: theme.colorScheme.primary),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_i18n.t('coordinates')}: ${_latitudeController.text}, ${_longitudeController.text}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_isEditing && _locationInputMode == 'map') SizedBox(height: 16),

                  // Address
                  if (_isEditing)
                    TextField(
                      controller: _addressController,
                      decoration: InputDecoration(
                        labelText: _i18n.t('address'),
                        hintText: _i18n.t('address_hint'),
                        border: OutlineInputBorder(),
                      ),
                    )
                  else if (_addressController.text.isNotEmpty)
                    _buildReadOnlyField(
                      label: _i18n.t('address'),
                      value: _addressController.text,
                      theme: theme,
                    ),
                  if (_isEditing || _addressController.text.isNotEmpty) SizedBox(height: 16),

                  // Type
                  if (_isEditing)
                    DropdownButtonFormField<String>(
                      value: _selectedType,
                      decoration: InputDecoration(
                        labelText: _i18n.t('type') + ' *',
                        border: OutlineInputBorder(),
                      ),
                      items: _reportTypes.map((type) {
                        return DropdownMenuItem(
                          value: type['value'],
                          child: Text(type['label']!),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            _selectedType = value;
                          });
                        }
                      },
                    )
                  else
                    _buildReadOnlyField(
                      label: _i18n.t('type'),
                      value: _reportTypes.firstWhere(
                        (t) => t['value'] == _selectedType,
                        orElse: () => {'label': _selectedType},
                      )['label'] ?? _selectedType,
                      theme: theme,
                    ),
                  SizedBox(height: 16),

                  // Severity - shown in status badges when viewing, dropdown when editing
                  if (_isEditing)
                    DropdownButtonFormField<ReportSeverity>(
                      value: _selectedSeverity,
                      decoration: InputDecoration(
                        labelText: _i18n.t('severity') + ' *',
                        border: OutlineInputBorder(),
                      ),
                      items: ReportSeverity.values.map((severity) {
                        return DropdownMenuItem(
                          value: severity,
                          child: Text(severity.name),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            _selectedSeverity = value;
                          });
                        }
                      },
                    ),
                  if (_isEditing) SizedBox(height: 16),

                  // Status (only for existing reports when editing - shown in badges when viewing)
                  if (!_isNew && _isEditing && canEdit) ...[
                    DropdownButtonFormField<ReportStatus>(
                      value: _selectedStatus,
                      decoration: InputDecoration(
                        labelText: _i18n.t('status'),
                        border: OutlineInputBorder(),
                      ),
                      items: ReportStatus.values.map((status) {
                        return DropdownMenuItem(
                          value: status,
                          child: Text(status.name),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            _selectedStatus = value;
                          });
                        }
                      },
                    ),
                    SizedBox(height: 16),
                  ],

                  // Contact
                  if (_isEditing)
                    TextField(
                      controller: _contactController,
                      decoration: InputDecoration(
                        labelText: _i18n.t('contact'),
                        hintText: _i18n.t('contact_info_hint'),
                        border: OutlineInputBorder(),
                      ),
                    )
                  else if (_contactController.text.isNotEmpty)
                    _buildReadOnlyField(
                      label: _i18n.t('contact'),
                      value: _contactController.text,
                      theme: theme,
                    ),
                  SizedBox(height: 24),

                  // Images Section
                  Text(
                    _i18n.t('photos'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),

                  // Add Images Button
                  if (_isEditing)
                    OutlinedButton.icon(
                      onPressed: _pickImages,
                      icon: Icon(Icons.add_photo_alternate),
                      label: Text(_i18n.t('add_photos')),
                    ),
                  if (_isEditing) SizedBox(height: 16),

                  // Display Images
                  if (_existingImages.isNotEmpty || _imageFiles.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        // Existing images
                        ..._existingImages.asMap().entries.map((entry) {
                          return Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  File(entry.value),
                                  width: 120,
                                  height: 120,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              if (_isEditing)
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: IconButton(
                                    onPressed: () => _removeImage(entry.key, isExisting: true),
                                    icon: Icon(Icons.close),
                                    iconSize: 20,
                                    style: IconButton.styleFrom(
                                      backgroundColor: Colors.black54,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.all(4),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        }),
                        // New images
                        ..._imageFiles.asMap().entries.map((entry) {
                          return Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  entry.value,
                                  width: 120,
                                  height: 120,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              if (_isEditing)
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: IconButton(
                                    onPressed: () => _removeImage(entry.key),
                                    icon: Icon(Icons.close),
                                    iconSize: 20,
                                    style: IconButton.styleFrom(
                                      backgroundColor: Colors.black54,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.all(4),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        }),
                      ],
                    ),
                  if (_existingImages.isEmpty && _imageFiles.isEmpty && !_isEditing)
                    Text(_i18n.t('no_photos_attached')),
                  SizedBox(height: 24),

                  // Likes section (for existing reports)
                  if (!_isNew && _report != null) ...[
                    const Divider(),
                    SizedBox(height: 16),
                    Row(
                      children: [
                        if (_currentUserNpub != null && _currentUserNpub!.isNotEmpty)
                          ElevatedButton.icon(
                            onPressed: _isLoading ? null : _toggleLike,
                            icon: Icon(
                              _report!.isLikedBy(_currentUserNpub!) ? Icons.favorite : Icons.favorite_border,
                              color: _report!.isLikedBy(_currentUserNpub!) ? Colors.red : null,
                            ),
                            label: Text(_report!.isLikedBy(_currentUserNpub!)
                                ? _i18n.t('liked')
                                : _i18n.t('like')),
                          ),
                        if (_report!.likeCount > 0) ...[
                          SizedBox(width: 16),
                          Text(
                            '${_report!.likeCount} ${_i18n.t('likes').toLowerCase()}',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ],
                    ),
                    SizedBox(height: 24),
                  ],

                  // Actions (for existing reports)
                  if (!_isNew && _report != null && _currentUserNpub != null && _currentUserNpub!.isNotEmpty) ...[
                    const Divider(),
                    SizedBox(height: 16),
                    Text(
                      _i18n.t('actions'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _isLoading ? null : _toggleSubscription,
                          icon: Icon(_report!.isSubscribed(_currentUserNpub!)
                              ? Icons.notifications_off
                              : Icons.notifications),
                          label: Text(_report!.isSubscribed(_currentUserNpub!)
                              ? _i18n.t('unsubscribe')
                              : _i18n.t('subscribe')),
                        ),
                        if (!_report!.verifiedBy.contains(_currentUserNpub))
                          ElevatedButton.icon(
                            onPressed: _isLoading ? null : _verify,
                            icon: Icon(Icons.verified),
                            label: Text(_i18n.t('confirm_alert_accurate')),
                          ),
                      ],
                    ),
                    SizedBox(height: 24),
                  ],

                  // Comments section (for existing reports)
                  if (!_isNew && _report != null) ...[
                    const Divider(),
                    SizedBox(height: 16),
                    Text(
                      _comments.isEmpty
                          ? _i18n.t('comments')
                          : '${_i18n.t('comments')} (${_comments.length})',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 16),

                    // Add comment input
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _commentController,
                            decoration: InputDecoration(
                              hintText: _i18n.t('comment_hint'),
                              border: OutlineInputBorder(),
                            ),
                            maxLines: 3,
                            minLines: 1,
                          ),
                        ),
                        SizedBox(width: 8),
                        IconButton(
                          onPressed: _isLoading ? null : _addComment,
                          icon: Icon(Icons.send),
                          tooltip: _i18n.t('add_comment'),
                        ),
                      ],
                    ),
                    SizedBox(height: 16),

                    // Display comments
                    if (_comments.isEmpty)
                      Center(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            _i18n.t('no_comments_yet'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    else
                      ..._comments.map((comment) => _buildCommentCard(comment, theme)),
                    SizedBox(height: 24),
                  ],

                  // Updates section (for existing reports, only show if there are updates)
                  if (!_isNew && _report != null && _updates.isNotEmpty) ...[
                    const Divider(),
                    SizedBox(height: 16),
                    Text(
                      '${_i18n.t('updates')} (${_updates.length})',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 16),
                    ..._updates.map((update) => _buildUpdateCard(update, theme)),
                  ],
                ],
              ),
            ),
    );
  }

  /// Builds a coordinates field with copy and open in map buttons
  Widget _buildCoordinatesField(ThemeData theme) {
    final lat = _latitudeController.text;
    final lon = _longitudeController.text;
    final coordsText = '$lat, $lon';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _i18n.t('coordinates'),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  coordsText,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              IconButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: coordsText));
                  _showSuccess(_i18n.t('coordinates_copied'));
                },
                icon: Icon(Icons.copy, size: 20),
                tooltip: _i18n.t('copy_coordinates'),
                style: IconButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                ),
              ),
              IconButton(
                onPressed: () => _openInMap(lat, lon),
                icon: Icon(Icons.map, size: 20),
                tooltip: _i18n.t('open_in_map'),
                style: IconButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Opens the coordinates in the system's default map application
  Future<void> _openInMap(String lat, String lon) async {
    try {
      final latitude = double.tryParse(lat);
      final longitude = double.tryParse(lon);

      if (latitude == null || longitude == null) {
        _showError('Invalid coordinates');
        return;
      }

      Uri mapUri;

      if (!kIsWeb && Platform.isAndroid) {
        // Android: Use geo: URI scheme which opens in default map app
        // Note: canLaunchUrl often returns false for geo: URIs even when they work
        mapUri = Uri.parse('geo:$latitude,$longitude?q=$latitude,$longitude');
        await launchUrl(mapUri);
      } else if (!kIsWeb && Platform.isIOS) {
        // iOS: Use Apple Maps URL scheme
        mapUri = Uri.parse('https://maps.apple.com/?q=$latitude,$longitude');
        await launchUrl(mapUri);
      } else {
        // Desktop/Web: Use OpenStreetMap
        mapUri = Uri.parse('https://www.openstreetmap.org/?mlat=$latitude&mlon=$longitude&zoom=15');
        if (await canLaunchUrl(mapUri)) {
          await launchUrl(mapUri, mode: LaunchMode.externalApplication);
        }
      }
    } catch (e) {
      _showError('Could not open map: $e');
      LogService().log('ReportDetailPage: Error opening map: $e');
    }
  }

  /// Builds a read-only field that displays label and value as regular text
  Widget _buildReadOnlyField({
    required String label,
    required String value,
    required ThemeData theme,
    bool isMultiline = false,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value.isNotEmpty ? value : '-',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeverityChip(ReportSeverity severity) {
    Color color;
    IconData icon;
    String label;

    switch (severity) {
      case ReportSeverity.emergency:
        color = Colors.red;
        icon = Icons.emergency;
        label = _i18n.t('severity_emergency');
        break;
      case ReportSeverity.urgent:
        color = Colors.orange;
        icon = Icons.warning;
        label = _i18n.t('severity_urgent');
        break;
      case ReportSeverity.attention:
        color = Colors.yellow.shade700;
        icon = Icons.report_problem;
        label = _i18n.t('severity_attention');
        break;
      case ReportSeverity.info:
        color = Colors.blue;
        icon = Icons.info;
        label = _i18n.t('severity_info');
        break;
    }

    return Chip(
      avatar: Icon(icon, color: color, size: 16),
      label: Text(label.toUpperCase()),
      backgroundColor: color.withOpacity(0.2),
    );
  }

  Widget _buildStatusChip(ReportStatus status) {
    Color color;
    String label;

    switch (status) {
      case ReportStatus.open:
        color = Colors.grey;
        label = _i18n.t('status_open');
        break;
      case ReportStatus.inProgress:
        color = Colors.blue;
        label = _i18n.t('status_in_progress');
        break;
      case ReportStatus.resolved:
        color = Colors.green;
        label = _i18n.t('status_resolved');
        break;
      case ReportStatus.closed:
        color = Colors.grey.shade700;
        label = _i18n.t('status_closed');
        break;
    }

    return Chip(
      label: Text(label.toUpperCase()),
      backgroundColor: color.withOpacity(0.2),
    );
  }

  Widget _buildUpdateCard(ReportUpdate update, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.update, size: 16, color: theme.colorScheme.primary),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    update.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            Text(
              'By ${update.author} • ${_formatUpdateDate(update.dateTime)}',
              style: theme.textTheme.bodySmall,
            ),
            SizedBox(height: 8),
            Text(
              update.content,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommentCard(ReportComment comment, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.person, size: 16, color: theme.colorScheme.primary),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    comment.author,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  comment.displayDate,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            Text(
              comment.content,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  String _formatUpdateDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
}
