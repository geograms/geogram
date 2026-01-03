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
import '../services/station_service.dart';
import '../services/station_alert_service.dart';
import '../services/alert_sharing_service.dart';
import '../util/alert_folder_utils.dart';
import '../util/feedback_comment_utils.dart';
import '../util/feedback_folder_utils.dart';
import 'location_picker_page.dart';
import 'photo_viewer_page.dart';

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

  Future<String?> _resolveStationAlertPath() async {
    if (_report == null || widget.collectionPath.isEmpty) return null;
    final existing = await AlertFolderUtils.findAlertPath(
      widget.collectionPath,
      _report!.folderName,
    );
    return existing ?? path.join(widget.collectionPath, _report!.folderName);
  }

  /// Save station alert to disk (for persisting likes, verifications, comments)
  Future<void> _saveStationAlert() async {
    if (_report == null || !_isFromStation || kIsWeb) return null;

    try {
      // Station alerts are stored in the collection path passed to this widget
      // which is: {devicesDir}/{callsign}/alerts
      final alertPath = await _resolveStationAlertPath();
      if (alertPath == null) return;
      final alertDir = Directory(alertPath);
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
  Future<String?> _saveStationAlertComment(String author, String content, {String? npub}) async {
    if (_report == null || !_isFromStation || kIsWeb) return null;

    try {
      final alertPath = await _resolveStationAlertPath();
      if (alertPath == null) return null;

      final signature = await _alertFeedbackService.signComment(_report!.apiId, content);
      await FeedbackCommentUtils.writeComment(
        contentPath: alertPath,
        author: author,
        content: content,
        npub: npub,
        signature: signature,
      );

      LogService().log('ReportDetailPage: Saved comment for station alert ${_report!.folderName}');
      return signature;
    } catch (e) {
      LogService().log('ReportDetailPage: Error saving station alert comment: $e');
      return null;
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
  int _selectedTtlSeconds = 604800; // TTL in seconds, default 1 week

  // TTL options (duration -> label)
  static const List<Map<String, int>> _ttlOptions = [
    {'value': 7200, 'label': 2},       // 2 hours
    {'value': 21600, 'label': 6},      // 6 hours
    {'value': 43200, 'label': 12},     // 12 hours
    {'value': 86400, 'label': 24},     // 1 day
    {'value': 259200, 'label': 72},    // 3 days
    {'value': 604800, 'label': 168},   // 1 week
    {'value': 1209600, 'label': 336},  // 2 weeks
    {'value': 2592000, 'label': 720},  // 1 month
    {'value': 7776000, 'label': 2160}, // 3 months
    {'value': 15552000, 'label': 4320},// 6 months
  ];

  // Helper to get human-readable TTL label
  static String _getTtlLabel(int seconds) {
    if (seconds < 86400) {
      final hours = seconds ~/ 3600;
      return '$hours hours';
    } else if (seconds < 604800) {
      final days = seconds ~/ 86400;
      return days == 1 ? '1 day' : '$days days';
    } else if (seconds < 2592000) {
      final weeks = seconds ~/ 604800;
      return weeks == 1 ? '1 week' : '$weeks weeks';
    } else {
      final months = seconds ~/ 2592000;
      return months == 1 ? '1 month' : '$months months';
    }
  }

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

      // For station alerts, fetch latest data (including new comments) from station
      if (_isFromStation && !kIsWeb) {
        _refreshFromStation();
      }
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

  /// Refresh alert data from station (downloads new comments, points, etc.)
  Future<void> _refreshFromStation() async {
    if (_report == null || !_isFromStation || kIsWeb) return;

    final stationCallsign = _report!.metadata['station_callsign'] ?? '';
    if (stationCallsign.isEmpty) return;

    try {
      LogService().log('ReportDetailPage: Refreshing alert from station...');

      // Fetch latest data from station (this downloads new comments)
      await StationAlertService().refreshAlert(_report!.folderName, stationCallsign);

      // Reload comments from local disk (now includes any new ones downloaded)
      await _loadComments();

      // Also reload points for the report
      final alertPath = await _resolveStationAlertPath();
      if (alertPath != null) {
        final points = await AlertFolderUtils.readPointsFile(alertPath);
        if (mounted) {
          setState(() {
            _report = _report!.copyWith(
              pointedBy: points,
              pointCount: points.length,
            );
          });
        }
      }

      LogService().log('ReportDetailPage: Alert refreshed from station');
    } catch (e) {
      LogService().log('ReportDetailPage: Error refreshing from station: $e');
    }
  }

  /// Load comments for a station alert from local disk
  Future<List<ReportComment>> _loadStationAlertComments() async {
    final comments = <ReportComment>[];

    try {
      final alertPath = await _resolveStationAlertPath();
      if (alertPath == null) return comments;

      final feedbackComments = await FeedbackCommentUtils.loadComments(alertPath);
      comments.addAll(feedbackComments.map((comment) {
        return ReportComment(
          id: comment.id,
          author: comment.author,
          content: comment.content,
          created: comment.created,
          npub: comment.npub,
        );
      }));

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
        final signature = await _saveStationAlertComment(
          profile.callsign,
          commentContent,
          npub: _currentUserNpub,
        );
        _commentController.clear();
        await _loadComments();
        _showSuccess(_i18n.t('comment_added'));

        // Sync to station and refresh on success (fetch any new comments from other users)
        _alertFeedbackService.commentOnStation(
          alertId,
          profile.callsign,
          commentContent,
          npub: _currentUserNpub,
          signature: signature,
        ).then((_) async {
          await StationAlertService().refreshAlert(_report!.folderName, _report!.metadata['station_callsign'] ?? '');
          if (mounted) {
            await _loadComments();
          }
        }).catchError((_) {});
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
        ).ignore();
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
        // For station alerts: update feedback locally, save to disk, then sync to station
        bool nextPointed = !wasPointed;
        final alertPath = await _resolveStationAlertPath();
        if (alertPath == null) {
          throw Exception('Unable to resolve alert path');
        }

        final event = await _alertFeedbackService.buildReactionEvent(
          alertId,
          wasPointed ? 'unpoint' : 'point',
          FeedbackFolderUtils.feedbackTypePoints,
        );
        if (event == null) {
          throw Exception('Unable to sign point feedback');
        }
        final isNowActive = await FeedbackFolderUtils.toggleFeedbackEvent(
          alertPath,
          FeedbackFolderUtils.feedbackTypePoints,
          event,
        );
        if (isNowActive == null) {
          throw Exception('Failed to apply point feedback');
        }
        nextPointed = isNowActive;

        final updatedPointedBy = List<String>.from(_report!.pointedBy);
        if (nextPointed) {
          if (!updatedPointedBy.contains(_currentUserNpub!)) {
            updatedPointedBy.add(_currentUserNpub!);
          }
        } else {
          updatedPointedBy.remove(_currentUserNpub!);
        }
        _report = _report!.copyWith(
          pointedBy: updatedPointedBy,
          pointCount: updatedPointedBy.length,
          lastModified: DateTime.now().toUtc().toIso8601String(),
        );

        await _saveStationAlert();

        setState(() {});
        _showSuccess(nextPointed ? _i18n.t('pointed') : _i18n.t('unpointed'));

        // Sync to station and refresh on success
        final stationCall = nextPointed
            ? _alertFeedbackService.pointAlertOnStation(alertId)
            : _alertFeedbackService.unpointAlertOnStation(alertId);

        stationCall.then((_) {
          StationAlertService().refreshAlert(_report!.folderName, _report!.metadata['station_callsign'] ?? '');
        }).catchError((_) {});
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

        // Sync to station (best-effort, fire-and-forget)
        if (_report != null) {
          if (wasPointed) {
            _alertFeedbackService.unpointAlertOnStation(alertId).ignore();
          } else {
            _alertFeedbackService.pointAlertOnStation(alertId).ignore();
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
          'User-Agent': 'geogram/1.0',
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
    } finally {
      setState(() => _isGeocodingAddress = false);
    }
  }

  Future<void> _pickReportType() async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('select_report_type')),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _reportTypes.length,
            itemBuilder: (context, index) {
              final type = _reportTypes[index];
              return ListTile(
                title: Text(type['label']!),
                onTap: () => Navigator.pop(context, type['value']!),
              );
            },
          ),
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _selectedType = result;
      });
    }
  }

  void _showTypeInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('report_type_info_title')),
        content: Text(_i18n.t('report_type_info_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('ok')),
          ),
        ],
      ),
    );
  }

  void _showSeverityInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('severity_levels')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSeverityInfo('emergency', _i18n.t('severity_emergency_desc')),
            _buildSeverityInfo('urgent', _i18n.t('severity_urgent_desc')),
            _buildSeverityInfo('attention', _i18n.t('severity_attention_desc')),
            _buildSeverityInfo('info', _i18n.t('severity_info_desc')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('ok')),
          ),
        ],
      ),
    );
  }

  Widget _buildSeverityInfo(String level, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 1,
            child: Text(
              level.toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(description),
          ),
        ],
      ),
    );
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
      // Build correct path: collectionPath/active/{regionFolder}/{folderName}/images
      final alertPath = path.join(
        widget.collectionPath,
        'active',
        _report!.regionFolder,
        _report!.folderName,
      );
      final imagesDir = Directory(AlertFolderUtils.buildImagesPath(alertPath));

      // For station alerts, download photos if they don't exist locally
      if (_isFromStation && !kIsWeb) {
        await _downloadStationPhotos(imagesDir);
      }

      if (await imagesDir.exists()) {
        final entities = await imagesDir.list().toList();
        setState(() {
          _existingImages = entities
              .where((e) => e is File && _isMediaFile(e.path))
              .map((e) => e.path)
              .toList();
        });
      }
    } catch (e) {
      LogService().log('Error loading images: $e');
    }
  }

  /// Download photos from station for station alerts
  Future<void> _downloadStationPhotos(Directory imagesDir) async {
    if (_report == null || !_isFromStation) return;

    try {
      final stationCallsign = _report!.metadata['station_callsign'];
      if (stationCallsign == null || stationCallsign.isEmpty) {
        LogService().log('ReportDetailPage: No station callsign for photo download');
        return;
      }

      // Get station URL
      final stationService = StationService();
      final station = stationService.getPreferredStation();
      if (station == null || station.url.isEmpty) {
        LogService().log('ReportDetailPage: No station URL for photo download');
        return;
      }

      // Build base URL
      var baseUrl = station.url;
      if (baseUrl.startsWith('wss://')) {
        baseUrl = baseUrl.replaceFirst('wss://', 'https://');
      } else if (baseUrl.startsWith('ws://')) {
        baseUrl = baseUrl.replaceFirst('ws://', 'http://');
      }

      // Fetch alert details to get photos list
      final alertId = _report!.apiId;
      final detailsUrl = '$baseUrl/$stationCallsign/api/alerts/$alertId';
      LogService().log('ReportDetailPage: Fetching alert details from $detailsUrl');

      final response = await http.get(
        Uri.parse(detailsUrl),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        LogService().log('ReportDetailPage: Failed to fetch alert details: ${response.statusCode}');
        return;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final photos = (json['photos'] as List<dynamic>?)?.cast<String>() ?? [];

      if (photos.isEmpty) {
        LogService().log('ReportDetailPage: No photos in alert');
        return;
      }

      // Create images directory if it doesn't exist
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }

      // Download each photo
      for (final photoName in photos) {
        final localFile = File(path.join(imagesDir.path, photoName));

        // Skip if already downloaded
        if (await localFile.exists()) {
          LogService().log('ReportDetailPage: Photo $photoName already exists');
          continue;
        }

        final photoUrl = '$baseUrl/$stationCallsign/api/alerts/$alertId/files/$photoName';
        LogService().log('ReportDetailPage: Downloading photo from $photoUrl');

        try {
          final photoResponse = await http.get(
            Uri.parse(photoUrl),
          ).timeout(const Duration(seconds: 60));

          if (photoResponse.statusCode == 200) {
            await localFile.writeAsBytes(photoResponse.bodyBytes);
            LogService().log('ReportDetailPage: Downloaded photo $photoName');
          } else {
            LogService().log('ReportDetailPage: Failed to download photo $photoName: ${photoResponse.statusCode}');
          }
        } catch (e) {
          LogService().log('ReportDetailPage: Error downloading photo $photoName: $e');
        }
      }
    } catch (e) {
      LogService().log('ReportDetailPage: Error downloading station photos: $e');
    }
  }

  bool _isImageFile(String filePath) {
    final ext = path.extension(filePath).toLowerCase();
    return ['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext);
  }

  bool _isVideoFile(String filePath) {
    final ext = path.extension(filePath).toLowerCase();
    return ['.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm'].contains(ext);
  }

  bool _isMediaFile(String filePath) {
    return _isImageFile(filePath) || _isVideoFile(filePath);
  }

  /// Get translated severity label
  String _getSeverityLabel(ReportSeverity severity) {
    switch (severity) {
      case ReportSeverity.emergency:
        return _i18n.t('severity_emergency');
      case ReportSeverity.urgent:
        return _i18n.t('severity_urgent');
      case ReportSeverity.attention:
        return _i18n.t('severity_attention');
      case ReportSeverity.info:
        return _i18n.t('severity_info');
    }
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

  /// Open the photo viewer at the specified index
  void _openPhotoViewer(int index, {bool isExisting = true}) {
    // Combine existing and new images for the viewer
    final allImages = [..._existingImages, ..._imageFilePaths];
    final actualIndex = isExisting ? index : _existingImages.length + index;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PhotoViewerPage(
          imagePaths: allImages,
          initialIndex: actualIndex,
        ),
      ),
    );
  }

  Future<void> _saveImages() async {
    if (kIsWeb) return;  // File operations not supported on web
    if (_report == null || _imageFilePaths.isEmpty) return;

    try {
      // Build correct path: collectionPath/active/{regionFolder}/{folderName}/images
      final alertPath = path.join(
        widget.collectionPath,
        'active',
        _report!.regionFolder,
        _report!.folderName,
      );
      final imagesDir = Directory(AlertFolderUtils.buildImagesPath(alertPath));

      // Create images directory if it doesn't exist
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }

      // Copy new images with sequential naming (photo1.ext, photo2.ext, etc.)
      for (final imagePath in _imageFilePaths) {
        final imageFile = File(imagePath);
        final ext = path.extension(imagePath).toLowerCase();
        final sequentialName = await AlertFolderUtils.getNextPhotoFilename(alertPath, ext);
        final destPath = path.join(imagesDir.path, sequentialName);
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
          ttl: _selectedTtlSeconds,
        );

        // Save images
        await _saveImages();

        // Upload photos to station after they're saved locally
        if (_report != null && !kIsWeb) {
          final alertService = AlertSharingService();
          final stationUrls = alertService.getRelayUrls();
          for (final stationUrl in stationUrls) {
            final uploaded = await alertService.uploadPhotosToStation(_report!, stationUrl);
            if (uploaded > 0) {
              LogService().log('ReportDetailPage: Uploaded $uploaded photos to $stationUrl');
            }
          }
        }

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

        // Upload any new photos to station
        if (_report != null && !kIsWeb && _report!.nostrEventId != null) {
          final alertService = AlertSharingService();
          final stationUrls = alertService.getRelayUrls();
          for (final stationUrl in stationUrls) {
            final uploaded = await alertService.uploadPhotosToStation(_report!, stationUrl);
            if (uploaded > 0) {
              LogService().log('ReportDetailPage: Uploaded $uploaded photos to $stationUrl');
            }
          }
        }

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

  /// Save and close the panel (for new alerts)
  Future<void> _saveAndClose() async {
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
        ttl: _selectedTtlSeconds,
      );

      // Save images
      await _saveImages();

      // Upload photos to station after they're saved locally
      if (_report != null && !kIsWeb) {
        final alertService = AlertSharingService();
        final stationUrls = alertService.getRelayUrls();
        for (final stationUrl in stationUrls) {
          final uploaded = await alertService.uploadPhotosToStation(_report!, stationUrl);
          if (uploaded > 0) {
            LogService().log('ReportDetailPage: Uploaded $uploaded photos to $stationUrl');
          }
        }
      }

      _showSuccess('Report created');

      // Close the panel after successful save
      if (mounted) {
        Navigator.of(context).pop(_report);
      }
    } catch (e) {
      _showError('Failed to save: $e');
      LogService().log('ReportDetailPage: Error saving: $e');
      setState(() => _isLoading = false);
    }
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
          // Refresh button for station alerts
          if (!_isNew && _isFromStation && !kIsWeb)
            IconButton(
              icon: Icon(Icons.refresh),
              tooltip: 'Refresh from station',
              onPressed: _isLoading ? null : () async {
                setState(() => _isLoading = true);
                await _refreshFromStation();
                setState(() => _isLoading = false);
              },
            ),
          if (!_isNew && !_isEditing && canEdit)
            IconButton(
              icon: Icon(Icons.edit),
              onPressed: () {
                setState(() {
                  _isEditing = true;
                });
              },
            ),
          if (_isEditing && !_isNew)
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
                        // Points chip (clickable)
                        if (!_isNew && _currentUserNpub != null && _currentUserNpub!.isNotEmpty)
                          ActionChip(
                            avatar: Icon(
                              _report!.hasPointFrom(_currentUserNpub!) ? Icons.star : Icons.star_border,
                              color: Colors.amber,
                              size: 16,
                            ),
                            label: Text(
                              _report!.pointCount > 0
                                  ? '${_report!.pointCount} ${_i18n.t('points').toLowerCase()}'
                                  : _i18n.t('point'),
                            ),
                            backgroundColor: _report!.hasPointFrom(_currentUserNpub!)
                                ? Colors.amber.withOpacity(0.2)
                                : null,
                            onPressed: _isLoading ? null : _togglePoint,
                          ),
                      ],
                    ),
                    SizedBox(height: 16),
                  ],

                  // Title
                  if (_isEditing)
                    TextField(
                      controller: _titleController,
                      textCapitalization: TextCapitalization.sentences,
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
                                child: Text(_getSeverityLabel(severity)),
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
                            value: _getSeverityLabel(_selectedSeverity),
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
                      textCapitalization: TextCapitalization.sentences,
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

                  // Map Picker Button
                  if (_isEditing)
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
                    )
                  else
                    _buildCoordinatesField(theme),
                  SizedBox(height: 16),

                  // Address (read-only when viewing)
                  if (!_isEditing && _addressController.text.isNotEmpty)
                    _buildReadOnlyField(
                      label: _i18n.t('address'),
                      value: _addressController.text,
                      theme: theme,
                    ),
                  if (!_isEditing && _addressController.text.isNotEmpty) SizedBox(height: 16),

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

                  // Images and Expires Section (two columns for new alerts)
                  if (_isNew && _isEditing)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Photos column
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _i18n.t('photos'),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: _pickImages,
                                icon: Icon(Icons.add_photo_alternate),
                                label: Text(_i18n.t('add_photos')),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 16),
                        // Expires column
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _i18n.t('expires'),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SizedBox(height: 8),
                              DropdownButtonFormField<int>(
                                value: _selectedTtlSeconds,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                ),
                                items: _ttlOptions.map((option) {
                                  final value = option['value']!;
                                  return DropdownMenuItem<int>(
                                    value: value,
                                    child: Text(_getTtlLabel(value)),
                                  );
                                }).toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() {
                                      _selectedTtlSeconds = value;
                                    });
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  else if (_isEditing) ...[
                    // Just Photos section for editing existing alerts
                    Text(
                      _i18n.t('photos'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _pickImages,
                      icon: Icon(Icons.add_photo_alternate),
                      label: Text(_i18n.t('add_photos')),
                    ),
                  ] else ...[
                    // Just Photos title when viewing
                    Text(
                      _i18n.t('photos'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                  SizedBox(height: 16),

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
                          return GestureDetector(
                            onTap: _isEditing ? null : () => _openPhotoViewer(entry.key, isExisting: true),
                            child: Stack(
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
                            ),
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
                          return GestureDetector(
                            onTap: _isEditing ? null : () => _openPhotoViewer(entry.key, isExisting: false),
                            child: Stack(
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
                            ),
                          );
                        }),
                      ],
                    ),
                  if (_existingImages.isEmpty && _imageFilePaths.isEmpty && !_isEditing)
                    Text(kIsWeb ? _i18n.t('photos_not_available_on_web') : _i18n.t('no_photos_attached')),
                  SizedBox(height: 24),

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
                            textCapitalization: TextCapitalization.sentences,
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

                  // Save button for new alerts (at bottom-right)
                  if (_isNew && _isEditing) ...[
                    SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        FloatingActionButton.extended(
                          onPressed: _isLoading ? null : _saveAndClose,
                          icon: Icon(Icons.save),
                          label: Text(_i18n.t('save')),
                        ),
                      ],
                    ),
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
      label: Text(label),
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
      label: Text(label),
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
