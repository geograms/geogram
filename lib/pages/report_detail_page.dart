/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
// dart:io operations only work on native platforms
// Image handling is disabled on web
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import '../platform/file_image_helper.dart' as file_helper;
import 'package:path/path.dart' as path;
import '../models/report.dart';
import '../models/report_update.dart';
import '../models/report_comment.dart';
import '../services/report_service.dart';
import '../services/profile_service.dart';
import '../services/log_service.dart';
import '../services/i18n_service.dart';
import '../services/alert_feedback_service.dart';
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
  final AlertFeedbackService _alertFeedbackService = AlertFeedbackService();

  late bool _isNew;
  late bool _isEditing;
  Report? _report;
  List<ReportUpdate> _updates = [];
  List<ReportComment> _comments = [];
  bool _isLoading = false;
  String? _currentUserNpub;

  /// Check if this report is from a remote station (not local)
  bool get _isFromStation => _report?.metadata['from_station'] == 'true';

  /// Save station alert to disk (for persisting likes, verifications, comments)
  Future<void> _saveStationAlert() async {
    if (_report == null || !_isFromStation || kIsWeb) return;

    try {
      // Station alerts are stored in the collection path passed to this widget
      // which is: {devicesDir}/{callsign}/alerts
      final alertDir = Directory(path.join(widget.collectionPath, _report!.folderName));
      final reportFilePath = path.join(alertDir.path, 'report.txt');

      LogService().log('ReportDetailPage: _saveStationAlert() - collectionPath: ${widget.collectionPath}');
      LogService().log('ReportDetailPage: _saveStationAlert() - folderName: ${_report!.folderName}');
      LogService().log('ReportDetailPage: _saveStationAlert() - alertDir: ${alertDir.path}');
      LogService().log('ReportDetailPage: _saveStationAlert() - reportFilePath: $reportFilePath');
      LogService().log('ReportDetailPage: _saveStationAlert() - pointedBy: ${_report!.pointedBy}');
      LogService().log('ReportDetailPage: _saveStationAlert() - pointCount: ${_report!.pointCount}');

      if (!await alertDir.exists()) {
        await alertDir.create(recursive: true);
        LogService().log('ReportDetailPage: _saveStationAlert() - created alertDir');
      }

      final reportFile = File(reportFilePath);
      final exportedContent = _report!.exportAsText();
      await reportFile.writeAsString(exportedContent);

      // Verify the file was written correctly
      final verifyContent = await reportFile.readAsString();
      final hasPointedBy = verifyContent.contains('POINTED_BY:');
      LogService().log('ReportDetailPage: _saveStationAlert() - file written, size: ${verifyContent.length}, hasPointedBy: $hasPointedBy');

      LogService().log('ReportDetailPage: Saved station alert ${_report!.folderName}');
    } catch (e, stack) {
      LogService().log('ReportDetailPage: Error saving station alert: $e\n$stack');
    }
  }

  /// Save a comment for a station alert
  Future<void> _saveStationAlertComment(String author, String content, {String? npub}) async {
    if (_report == null || !_isFromStation || kIsWeb) return;

    try {
      final commentsDir = Directory(path.join(widget.collectionPath, _report!.folderName, 'comments'));

      if (!await commentsDir.exists()) {
        await commentsDir.create(recursive: true);
      }

      // Generate comment filename
      final now = DateTime.now();
      final timestamp = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}';
      final fileName = '${timestamp}_$author.txt';

      final commentFile = File(path.join(commentsDir.path, fileName));

      // Build comment content - format must match ReportComment.fromText() expectations
      // Format: AUTHOR, CREATED (YYYY-MM-DD HH:MM_ss), empty line, content, empty line, --> npub
      final createdStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

      final buffer = StringBuffer();
      buffer.writeln('AUTHOR: $author');
      buffer.writeln('CREATED: $createdStr');
      buffer.writeln();
      buffer.writeln(content);

      if (npub != null && npub.isNotEmpty) {
        buffer.writeln();
        buffer.writeln('--> npub: $npub');
      }

      await commentFile.writeAsString(buffer.toString());

      LogService().log('ReportDetailPage: Saved comment for station alert ${_report!.folderName}');
    } catch (e) {
      LogService().log('ReportDetailPage: Error saving station alert comment: $e');
    }
  }

  List<String> _imageFilePaths = [];  // Store paths instead of File objects for web compatibility
  List<String> _existingImages = [];

  // Form controllers
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _latitudeController = TextEditingController();
  final _longitudeController = TextEditingController();
  final _addressController = TextEditingController();
  final _commentController = TextEditingController();

  ReportSeverity _selectedSeverity = ReportSeverity.attention;
  ReportStatus _selectedStatus = ReportStatus.open;
  String _selectedType = 'other';
  String _locationInputMode = 'map'; // 'map', 'manual', or 'address'
  bool _isGeocodingAddress = false;

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
      if (_isFromStation && !kIsWeb) {
        // Load comments from station alert directory
        _comments = await _loadStationAlertComments();
      } else {
        // Load comments from local collection
        _comments = await _reportService.loadComments(_report!.folderName);
      }
      setState(() {});
    } catch (e) {
      LogService().log('ReportDetailPage: Error loading comments: $e');
    }
  }

  /// Load comments for a station alert from local disk
  Future<List<ReportComment>> _loadStationAlertComments() async {
    final comments = <ReportComment>[];

    try {
      final commentsDir = Directory(path.join(widget.collectionPath, _report!.folderName, 'comments'));

      if (!await commentsDir.exists()) return comments;

      await for (final entity in commentsDir.list()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.txt')) continue;

        try {
          final content = await entity.readAsString();
          final fileName = entity.path.split('/').last;
          final comment = ReportComment.fromText(content, fileName.replaceAll('.txt', ''));
          comments.add(comment);
        } catch (e) {
          LogService().log('ReportDetailPage: Error loading comment: $e');
        }
      }

      // Sort by date (newest first)
      comments.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    } catch (e) {
      LogService().log('ReportDetailPage: Error loading station alert comments: $e');
    }

    return comments;
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
      final commentContent = _commentController.text.trim();
      final alertId = _report!.apiId;

      if (_isFromStation) {
        // For station alerts: save comment to local disk, then sync to station
        await _saveStationAlertComment(profile.callsign, commentContent, npub: _currentUserNpub);
        _commentController.clear();
        await _loadComments();
        _showSuccess(_i18n.t('comment_added'));

        // Sync to station (best-effort)
        _alertFeedbackService.commentOnStation(
          alertId,
          profile.callsign,
          commentContent,
          npub: _currentUserNpub,
        ).catchError((e) {
          LogService().log('Failed to sync comment to station: $e');
        });
      } else {
        // For local alerts: use ReportService
        await _reportService.addComment(
          _report!.folderName,
          profile.callsign,
          commentContent,
          npub: _currentUserNpub,
        );
        _commentController.clear();
        await _loadComments();
        _showSuccess(_i18n.t('comment_added'));

        // Sync to station (best-effort)
        _alertFeedbackService.commentOnStation(
          alertId,
          profile.callsign,
          commentContent,
          npub: _currentUserNpub,
        ).catchError((e) {
          LogService().log('Failed to sync comment to station: $e');
        });
      }
    } catch (e) {
      _showError('Failed to add comment: $e');
    }

    setState(() => _isLoading = false);
  }

  Future<void> _togglePoint() async {
    if (_report == null || _currentUserNpub == null || _currentUserNpub!.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final wasPointed = _report!.hasPointFrom(_currentUserNpub!);
      final alertId = _report!.apiId;

      if (_isFromStation) {
        // For station alerts: update in-memory immediately, save to disk, then sync to station
        final updatedPointedBy = List<String>.from(_report!.pointedBy);
        if (wasPointed) {
          updatedPointedBy.remove(_currentUserNpub!);
        } else {
          updatedPointedBy.add(_currentUserNpub!);
        }
        _report = _report!.copyWith(
          pointedBy: updatedPointedBy,
          pointCount: updatedPointedBy.length,
          lastModified: DateTime.now().toUtc().toIso8601String(),
        );

        // Save to disk for persistence
        await _saveStationAlert();

        setState(() {});
        _showSuccess(wasPointed ? _i18n.t('unpointed') : _i18n.t('pointed'));

        // Sync to station (best-effort)
        if (wasPointed) {
          _alertFeedbackService.unpointAlertOnStation(alertId, _currentUserNpub!).catchError((e) {
            LogService().log('Failed to sync unpoint to station: $e');
          });
        } else {
          _alertFeedbackService.pointAlertOnStation(alertId, _currentUserNpub!).catchError((e) {
            LogService().log('Failed to sync point to station: $e');
          });
        }
      } else {
        // For local alerts: save locally first, then sync
        if (wasPointed) {
          await _reportService.unpointReport(_report!.folderName, _currentUserNpub!);
        } else {
          await _reportService.pointReport(_report!.folderName, _currentUserNpub!);
        }

        // Reload report from local storage
        _report = await _reportService.loadReport(_report!.folderName);
        setState(() {});
        _showSuccess(wasPointed ? _i18n.t('unpointed') : _i18n.t('pointed'));

        // Sync to station (best-effort)
        if (_report != null) {
          if (wasPointed) {
            _alertFeedbackService.unpointAlertOnStation(alertId, _currentUserNpub!).catchError((e) {
              LogService().log('Failed to sync unpoint to station: $e');
            });
          } else {
            _alertFeedbackService.pointAlertOnStation(alertId, _currentUserNpub!).catchError((e) {
              LogService().log('Failed to sync point to station: $e');
            });
          }
        }
      }
    } catch (e) {
      _showError('Failed to toggle point: $e');
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

  Future<void> _geocodeAddress() async {
    if (_addressController.text.trim().isEmpty) {
      _showError(_i18n.t('enter_address_first'));
      return;
    }

    setState(() => _isGeocodingAddress = true);

    try {
      final address = Uri.encodeComponent(_addressController.text.trim());
      final response = await http.get(
        Uri.parse('https://nominatim.openstreetmap.org/search?q=$address&format=json&limit=1'),
        headers: {
          'User-Agent': 'geogram-desktop/1.0',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as List;
        if (data.isNotEmpty) {
          final lat = double.tryParse(data[0]['lat'].toString());
          final lon = double.tryParse(data[0]['lon'].toString());
          final displayName = data[0]['display_name'] as String?;

          if (lat != null && lon != null) {
            setState(() {
              _latitudeController.text = lat.toStringAsFixed(6);
              _longitudeController.text = lon.toStringAsFixed(6);
              // Update address with the full display name from geocoder
              if (displayName != null && displayName.isNotEmpty) {
                _addressController.text = displayName;
              }
            });
            _showSuccess(_i18n.t('location_found'));
          } else {
            _showError(_i18n.t('address_not_found'));
          }
        } else {
          _showError(_i18n.t('address_not_found'));
        }
      } else {
        _showError(_i18n.t('geocoding_failed'));
      }
    } catch (e) {
      LogService().log('ReportDetailPage: Geocoding error: $e');
      _showError(_i18n.t('geocoding_failed'));
    }

    setState(() => _isGeocodingAddress = false);
  }

  Future<void> _pickImages() async {
    if (kIsWeb) {
      _showError('Image picking is not supported on web');
      return;
    }
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _imageFilePaths.addAll(
            result.files.where((f) => f.path != null).map((file) => file.path!).toList(),
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
        _imageFilePaths.removeAt(index);
      }
    });
  }

  Future<void> _saveImages() async {
    if (kIsWeb) return;  // File operations not supported on web
    if (_report == null || _imageFilePaths.isEmpty) return;

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
      for (final imagePath in _imageFilePaths) {
        final imageFile = File(imagePath);
        final fileName = path.basename(imagePath);
        final destPath = path.join(imagesDir.path, fileName);
        await imageFile.copy(destPath);
      }

      // Clear the list and reload existing images
      _imageFilePaths.clear();
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
      if (_locationInputMode == 'address') {
        _showError(_i18n.t('find_location_first'));
      } else {
        _showError(_i18n.t('coordinates_required'));
      }
      return;
    }

    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      _showError(_i18n.t('coordinates_out_of_range'));
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

    // Already verified by this user
    if (_report!.verifiedBy.contains(_currentUserNpub!)) return;

    setState(() => _isLoading = true);

    try {
      final alertId = _report!.apiId;

      if (_isFromStation) {
        // For station alerts: update in-memory immediately, save to disk, then sync to station
        final updatedVerifiedBy = List<String>.from(_report!.verifiedBy)..add(_currentUserNpub!);
        _report = _report!.copyWith(
          verifiedBy: updatedVerifiedBy,
          verificationCount: updatedVerifiedBy.length,
          lastModified: DateTime.now().toUtc().toIso8601String(),
        );

        // Save to disk for persistence
        await _saveStationAlert();

        setState(() {});
        _showSuccess(_i18n.t('verified'));

        // Sync to station (best-effort)
        _alertFeedbackService.verifyAlertOnStation(alertId, _currentUserNpub!).catchError((e) {
          LogService().log('Failed to sync verification to station: $e');
        });
      } else {
        // For local alerts: save locally first, then sync
        await _reportService.verify(_report!.folderName, _currentUserNpub!);
        _showSuccess(_i18n.t('verified'));

        // Reload report from local storage
        _report = await _reportService.loadReport(_report!.folderName);
        setState(() {});

        // Sync to station (best-effort)
        if (_report != null) {
          _alertFeedbackService.verifyAlertOnStation(alertId, _currentUserNpub!).catchError((e) {
            LogService().log('Failed to sync verification to station: $e');
          });
        }
      }
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
    // Can't edit station alerts (remote) - only local reports
    final canEdit = !_isFromStation && (
                     _report == null ||
                     isAuthor ||
                     (_currentUserNpub != null && _report!.isAdmin(_currentUserNpub!)));

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

                  // Type and Severity (underneath title)
                  if (_isEditing)
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: _selectedType,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: _i18n.t('type') + ' *',
                              border: OutlineInputBorder(),
                            ),
                            items: _reportTypes.map((type) {
                              return DropdownMenuItem(
                                value: type['value'],
                                child: Text(type['label']!, overflow: TextOverflow.ellipsis),
                              );
                            }).toList(),
                            onChanged: (value) {
                              if (value != null) {
                                setState(() {
                                  _selectedType = value;
                                });
                              }
                            },
                          ),
                        ),
                        SizedBox(width: 16),
                        Expanded(
                          child: DropdownButtonFormField<ReportSeverity>(
                            value: _selectedSeverity,
                            isExpanded: true,
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
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: _buildReadOnlyField(
                            label: _i18n.t('type'),
                            value: _reportTypes.firstWhere(
                              (t) => t['value'] == _selectedType,
                              orElse: () => {'label': _selectedType},
                            )['label'] ?? _selectedType,
                            theme: theme,
                          ),
                        ),
                        SizedBox(width: 16),
                        Expanded(
                          child: _buildReadOnlyField(
                            label: _i18n.t('severity'),
                            value: _selectedSeverity.name,
                            theme: theme,
                          ),
                        ),
                      ],
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
                        alignLabelWithHint: true,
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
                          value: 'address',
                          child: Row(
                            children: [
                              Icon(Icons.location_on, size: 20),
                              SizedBox(width: 8),
                              Text(_i18n.t('enter_address')),
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

                  // Address Input
                  if (_isEditing && _locationInputMode == 'address')
                    Column(
                      children: [
                        TextField(
                          controller: _addressController,
                          decoration: InputDecoration(
                            labelText: _i18n.t('address') + ' *',
                            hintText: _i18n.t('address_hint'),
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _geocodeAddress(),
                        ),
                        SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _isGeocodingAddress ? null : _geocodeAddress,
                            icon: _isGeocodingAddress
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: theme.colorScheme.onPrimary,
                                    ),
                                  )
                                : Icon(Icons.search),
                            label: Text(_i18n.t('find_location')),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                        SizedBox(height: 16),
                      ],
                    ),

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

                  // Address (only show for manual mode when editing, address mode has it built-in, map mode doesn't need it)
                  if (_isEditing && _locationInputMode == 'manual')
                    TextField(
                      controller: _addressController,
                      decoration: InputDecoration(
                        labelText: _i18n.t('address'),
                        hintText: _i18n.t('address_hint'),
                        border: OutlineInputBorder(),
                      ),
                    )
                  else if (!_isEditing && _addressController.text.isNotEmpty)
                    _buildReadOnlyField(
                      label: _i18n.t('address'),
                      value: _addressController.text,
                      theme: theme,
                    ),
                  if ((_isEditing && _locationInputMode == 'manual') || (!_isEditing && _addressController.text.isNotEmpty)) SizedBox(height: 16),

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
                  SizedBox(height: 8),

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

                  // Display Images (only on native platforms)
                  if (!kIsWeb && (_existingImages.isNotEmpty || _imageFilePaths.isNotEmpty))
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        // Existing images
                        ..._existingImages.asMap().entries.map((entry) {
                          final imageWidget = file_helper.buildFileImage(
                            entry.value,
                            width: 120,
                            height: 120,
                            fit: BoxFit.cover,
                          );
                          if (imageWidget == null) return const SizedBox.shrink();
                          return Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: imageWidget,
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
                        ..._imageFilePaths.asMap().entries.map((entry) {
                          final imageWidget = file_helper.buildFileImage(
                            entry.value,
                            width: 120,
                            height: 120,
                            fit: BoxFit.cover,
                          );
                          if (imageWidget == null) return const SizedBox.shrink();
                          return Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: imageWidget,
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
                  if (_existingImages.isEmpty && _imageFilePaths.isEmpty && !_isEditing)
                    Text(kIsWeb ? _i18n.t('photos_not_available_on_web') : _i18n.t('no_photos_attached')),
                  SizedBox(height: 24),

                  // Likes section (for existing reports)
                  if (!_isNew && _report != null) ...[
                    const Divider(),
                    SizedBox(height: 16),
                    Row(
                      children: [
                        if (_currentUserNpub != null && _currentUserNpub!.isNotEmpty)
                          ElevatedButton.icon(
                            onPressed: _isLoading ? null : _togglePoint,
                            icon: Icon(
                              _report!.hasPointFrom(_currentUserNpub!) ? Icons.star : Icons.star_border,
                              color: _report!.hasPointFrom(_currentUserNpub!) ? Colors.amber : null,
                            ),
                            label: Text(_report!.hasPointFrom(_currentUserNpub!)
                                ? _i18n.t('pointed')
                                : _i18n.t('point')),
                          ),
                        if (_report!.pointCount > 0) ...[
                          SizedBox(width: 16),
                          Text(
                            '${_report!.pointCount} ${_i18n.t('points').toLowerCase()}',
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
