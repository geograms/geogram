/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import '../models/report.dart';
import '../models/report_update.dart';
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
    final canEdit = _report == null || (_currentUserNpub != null && _report!.isAdmin(_currentUserNpub!));

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? _i18n.t('new_report') : _i18n.t('report_details')),
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
                  TextField(
                    controller: _titleController,
                    decoration: InputDecoration(
                      labelText: _i18n.t('title') + ' *',
                      hintText: _i18n.t('title_hint'),
                      border: OutlineInputBorder(),
                    ),
                    enabled: _isEditing,
                    maxLines: 2,
                  ),
                  SizedBox(height: 16),

                  // Description
                  TextField(
                    controller: _descriptionController,
                    decoration: InputDecoration(
                      labelText: _i18n.t('description') + ' *',
                      hintText: _i18n.t('description_hint'),
                      border: OutlineInputBorder(),
                    ),
                    enabled: _isEditing,
                    maxLines: 8,
                  ),
                  SizedBox(height: 16),

                  // Location Section
                  Text(
                    _i18n.t('location') + ' *',
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
                  if (_locationInputMode == 'manual' || !_isEditing)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _latitudeController,
                            decoration: InputDecoration(
                              labelText: _i18n.t('latitude') + ' *',
                              border: OutlineInputBorder(),
                            ),
                            enabled: _isEditing && _locationInputMode == 'manual',
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
                            enabled: _isEditing && _locationInputMode == 'manual',
                            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                          ),
                        ),
                      ],
                    ),
                  if (_locationInputMode == 'manual' || !_isEditing) SizedBox(height: 16),

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
                              'Coordinates: ${_latitudeController.text}, ${_longitudeController.text}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_isEditing && _locationInputMode == 'map') SizedBox(height: 16),

                  // Address
                  TextField(
                    controller: _addressController,
                    decoration: InputDecoration(
                      labelText: _i18n.t('address'),
                      hintText: _i18n.t('address_hint'),
                      border: OutlineInputBorder(),
                    ),
                    enabled: _isEditing,
                  ),
                  SizedBox(height: 16),

                  // Type
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
                    onChanged: _isEditing
                        ? (value) {
                            if (value != null) {
                              setState(() {
                                _selectedType = value;
                              });
                            }
                          }
                        : null,
                  ),
                  SizedBox(height: 16),

                  // Severity
                  DropdownButtonFormField<ReportSeverity>(
                    initialValue: _selectedSeverity,
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
                    onChanged: _isEditing
                        ? (value) {
                            if (value != null) {
                              setState(() {
                                _selectedSeverity = value;
                              });
                            }
                          }
                        : null,
                  ),
                  SizedBox(height: 16),

                  // Status (only for existing reports)
                  if (!_isNew) ...[
                    DropdownButtonFormField<ReportStatus>(
                      initialValue: _selectedStatus,
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
                      onChanged: _isEditing && canEdit
                          ? (value) {
                              if (value != null) {
                                setState(() {
                                  _selectedStatus = value;
                                });
                              }
                            }
                          : null,
                    ),
                    SizedBox(height: 16),
                  ],

                  // Contact
                  TextField(
                    controller: _contactController,
                    decoration: InputDecoration(
                      labelText: _i18n.t('contact'),
                      hintText: _i18n.t('contact_info_hint'),
                      border: OutlineInputBorder(),
                    ),
                    enabled: _isEditing,
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

                  // Actions (for existing reports)
                  if (!_isNew && _report != null) ...[
                    const Divider(),
                    SizedBox(height: 16),
                    Text(
                      'Actions',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_currentUserNpub != null && _currentUserNpub!.isNotEmpty) ...[
                          ElevatedButton.icon(
                            onPressed: _isLoading ? null : _toggleSubscription,
                            icon: Icon(_report!.isSubscribed(_currentUserNpub!)
                                ? Icons.notifications_off
                                : Icons.notifications),
                            label: Text(_report!.isSubscribed(_currentUserNpub!)
                                ? 'Unsubscribe'
                                : 'Subscribe'),
                          ),
                          if (!_report!.verifiedBy.contains(_currentUserNpub))
                            ElevatedButton.icon(
                              onPressed: _isLoading ? null : _verify,
                              icon: Icon(Icons.verified),
                              label: Text(_i18n.t('verify')),
                            ),
                        ],
                        ElevatedButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(
                              text: '${_report!.latitude},${_report!.longitude}',
                            ));
                            _showSuccess('Coordinates copied');
                          },
                          icon: Icon(Icons.copy),
                          label: Text(_i18n.t('copy_coords')),
                        ),
                      ],
                    ),
                    SizedBox(height: 24),
                  ],

                  // Updates section (for existing reports)
                  if (!_isNew && _report != null) ...[
                    const Divider(),
                    SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Updates',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${_updates.length}',
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                    if (_updates.isEmpty)
                      Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(_i18n.t('no_updates_yet')),
                        ),
                      )
                    else
                      ..._updates.map((update) => _buildUpdateCard(update, theme)),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildSeverityChip(ReportSeverity severity) {
    Color color;
    IconData icon;

    switch (severity) {
      case ReportSeverity.emergency:
        color = Colors.red;
        icon = Icons.emergency;
        break;
      case ReportSeverity.urgent:
        color = Colors.orange;
        icon = Icons.warning;
        break;
      case ReportSeverity.attention:
        color = Colors.yellow.shade700;
        icon = Icons.report_problem;
        break;
      case ReportSeverity.info:
        color = Colors.blue;
        icon = Icons.info;
        break;
    }

    return Chip(
      avatar: Icon(icon, color: color, size: 16),
      label: Text(severity.name.toUpperCase()),
      backgroundColor: color.withOpacity(0.2),
    );
  }

  Widget _buildStatusChip(ReportStatus status) {
    Color color;

    switch (status) {
      case ReportStatus.open:
        color = Colors.grey;
        break;
      case ReportStatus.inProgress:
        color = Colors.blue;
        break;
      case ReportStatus.resolved:
        color = Colors.green;
        break;
      case ReportStatus.closed:
        color = Colors.grey.shade700;
        break;
    }

    return Chip(
      label: Text(status.name.replaceAll(RegExp(r'([A-Z])'), ' \$1').trim().toUpperCase()),
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
