/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' show Directory, File, Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path/path.dart' as path;
import '../models/place.dart';
import '../services/place_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../platform/file_image_helper.dart' as file_helper;
import 'add_edit_place_page.dart';
import 'location_picker_page.dart';
import 'photo_viewer_page.dart';
import '../widgets/place_feedback_section.dart';

/// Full-screen place detail page
/// Can be used from the map, places browser, or anywhere else
class PlaceDetailPage extends StatefulWidget {
  final String collectionPath;
  final Place place;

  const PlaceDetailPage({
    super.key,
    required this.collectionPath,
    required this.place,
  });

  @override
  State<PlaceDetailPage> createState() => _PlaceDetailPageState();
}

class _PlaceDetailPageState extends State<PlaceDetailPage> {
  final PlaceService _placeService = PlaceService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();

  late Place _place;
  List<String> _photos = [];
  bool _hasChanges = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _place = widget.place;
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      // Initialize place service with collection path
      await _placeService.initializeCollection(widget.collectionPath);

      // Load photos from place folder
      await _loadPhotos();
    } catch (e) {
      LogService().log('PlaceDetailPage: Error loading data: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadPhotos() async {
    if (kIsWeb || _place.folderPath == null) return;

    try {
      final imagesDir = Directory('${_place.folderPath}/images');
      if (await imagesDir.exists()) {
        final entities = await imagesDir.list().toList();
        setState(() {
          _photos = entities
              .where((e) => e is File && _isMediaFile(e.path))
              .map((e) => e.path)
              .toList();
        });
      }
    } catch (e) {
      LogService().log('PlaceDetailPage: Error loading photos: $e');
    }
  }

  bool _isImageFile(String path) {
    final ext = path.toLowerCase();
    return ext.endsWith('.jpg') || ext.endsWith('.jpeg') ||
           ext.endsWith('.png') || ext.endsWith('.gif') ||
           ext.endsWith('.webp');
  }

  bool _isVideoFile(String path) {
    final ext = path.toLowerCase();
    return ext.endsWith('.mp4') || ext.endsWith('.avi') ||
           ext.endsWith('.mkv') || ext.endsWith('.mov') ||
           ext.endsWith('.wmv') || ext.endsWith('.flv') ||
           ext.endsWith('.webm');
  }

  bool _isMediaFile(String path) {
    return _isImageFile(path) || _isVideoFile(path);
  }

  IconData _getTypeIcon(String? type) {
    switch (type?.toLowerCase()) {
      case 'restaurant':
        return Icons.restaurant;
      case 'cafe':
      case 'coffee':
        return Icons.local_cafe;
      case 'monument':
      case 'landmark':
        return Icons.account_balance;
      case 'park':
        return Icons.park;
      case 'museum':
        return Icons.museum;
      case 'shop':
      case 'store':
        return Icons.store;
      case 'hotel':
        return Icons.hotel;
      case 'hospital':
        return Icons.local_hospital;
      case 'school':
        return Icons.school;
      case 'church':
        return Icons.church;
      case 'pharmacy':
        return Icons.local_pharmacy;
      case 'police':
        return Icons.local_police;
      case 'firefighters':
        return Icons.local_fire_department;
      case 'grocery':
        return Icons.shopping_cart;
      case 'veterinary':
        return Icons.pets;
      case 'fruit-tree':
        return Icons.nature;
      case 'library':
        return Icons.local_library;
      case 'theater':
      case 'cinema':
        return Icons.theaters;
      case 'gallery':
        return Icons.palette;
      case 'beach':
        return Icons.beach_access;
      case 'viewpoint':
        return Icons.panorama;
      case 'market':
        return Icons.storefront;
      default:
        return Icons.place;
    }
  }

  String? _resolveProfileImagePath(Place place) {
    final profileImage = place.profileImage;
    final folderPath = place.folderPath;
    if (profileImage == null || profileImage.isEmpty || folderPath == null) {
      return null;
    }
    final resolved = path.isAbsolute(profileImage)
        ? profileImage
        : path.join(folderPath, profileImage);
    return file_helper.fileExists(resolved) ? resolved : null;
  }

  Widget _buildPlaceAvatar(Place place, {double radius = 30}) {
    final imagePath = _resolveProfileImagePath(place);
    final imageProvider = imagePath != null
        ? file_helper.getFileImageProvider(imagePath)
        : null;
    if (imageProvider != null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.green.shade100,
        backgroundImage: imageProvider,
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.green.shade100,
      child: Icon(_getTypeIcon(place.type), size: radius, color: Colors.green.shade700),
    );
  }

  Future<void> _editPlace() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => AddEditPlacePage(
          collectionPath: widget.collectionPath,
          place: _place,
        ),
      ),
    );

    if (result == true && mounted) {
      _hasChanges = true;
      // Reload the place data
      await _loadData();
    }
  }

  Future<void> _deletePlace() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_place')),
        content: Text(_i18n.t('delete_place_confirm', params: [_place.name])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await _placeService.deletePlace(_place);

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('place_deleted', params: [_place.name]))),
        );
        Navigator.pop(context, true);
      }
    }
  }

  void _viewOnMap() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LocationPickerPage(
          initialPosition: LatLng(_place.latitude, _place.longitude),
          viewOnly: true,
        ),
      ),
    );
  }

  void _copyCoordinates() {
    Clipboard.setData(ClipboardData(text: _place.coordinatesString));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_i18n.t('coordinates_copied'))),
    );
  }

  Future<void> _openInNavigator() async {
    try {
      Uri mapUri;

      if (!kIsWeb && Platform.isAndroid) {
        mapUri = Uri.parse('geo:${_place.latitude},${_place.longitude}?q=${_place.latitude},${_place.longitude}');
        await launchUrl(mapUri);
      } else if (!kIsWeb && Platform.isIOS) {
        mapUri = Uri.parse('https://maps.apple.com/?q=${_place.latitude},${_place.longitude}');
        await launchUrl(mapUri);
      } else {
        mapUri = Uri.parse('https://www.openstreetmap.org/?mlat=${_place.latitude}&mlon=${_place.longitude}&zoom=15');
        if (await canLaunchUrl(mapUri)) {
          await launchUrl(mapUri, mode: LaunchMode.externalApplication);
        }
      }
    } catch (e) {
      LogService().log('PlaceDetailPage: Error opening navigator: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open navigator: $e')),
        );
      }
    }
  }

  void _openPhotoViewer(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PhotoViewerPage(
          imagePaths: _photos,
          initialIndex: index,
        ),
      ),
    );
  }

  void _openProfileImageViewer() {
    final imagePath = _resolveProfileImagePath(_place);
    if (imagePath == null) return;

    final index = _photos.indexOf(imagePath);
    final imagePaths = index >= 0 ? _photos : [imagePath];
    final initialIndex = index >= 0 ? index : 0;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PhotoViewerPage(
          imagePaths: imagePaths,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  /// Get the display language based on user's current language
  String get _currentLangCode {
    final lang = _i18n.currentLanguage.toUpperCase().split('_').first;
    return lang;
  }

  @override
  Widget build(BuildContext context) {
    // Get description and history in user's language
    final description = _place.getDescription(_currentLangCode);
    final history = _place.getHistory(_currentLangCode);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && _hasChanges) {
          // Already popping, no need to call pop again
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_place.name),
          actions: [
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: _editPlace,
              tooltip: _i18n.t('edit'),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'delete':
                    _deletePlace();
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      const Icon(Icons.delete, color: Colors.red),
                      const SizedBox(width: 8),
                      Text(_i18n.t('delete'), style: const TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
              // Header
              Row(
                children: [
                  (() {
                    final imagePath = _resolveProfileImagePath(_place);
                    final avatar = _buildPlaceAvatar(_place, radius: 30);
                    if (imagePath == null) return avatar;
                    return GestureDetector(
                      onTap: _openProfileImageViewer,
                      child: avatar,
                    );
                  })(),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                description.isNotEmpty ? description : _place.name,
                                style: description.isNotEmpty
                                    ? Theme.of(context).textTheme.bodyLarge
                                    : Theme.of(context).textTheme.headlineSmall,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (_place.type != null)
                                Container(
                                  margin: const EdgeInsets.only(top: 4),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade100,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    _i18n.t('place_type_${_place.type}'),
                                    style: TextStyle(
                                      color: Colors.green.shade800,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        PlaceLikeButton(
                          place: _place,
                          compact: true,
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Photos section
                    if (_photos.isNotEmpty) ...[
                      Text(
                        _i18n.t('photos'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 120,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: _photos.length,
                          itemBuilder: (context, index) {
                            final imageWidget = file_helper.buildFileImage(
                              _photos[index],
                              width: 120,
                              height: 120,
                              fit: BoxFit.cover,
                            );
                            if (imageWidget == null) return const SizedBox.shrink();
                            return GestureDetector(
                              onTap: () => _openPhotoViewer(index),
                              child: Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: imageWidget,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Basic info
                    _buildInfoSection(_i18n.t('basic_information'), [
                      _buildLocationRow(),
                      _buildInfoRow(_i18n.t('radius'), '${_place.radius} ${_i18n.t('meters')}'),
                      if (_place.address != null)
                        _buildInfoRow(_i18n.t('address'), _place.address!),
                      if (_place.founded != null)
                        _buildInfoRow(_i18n.t('founded'), _place.founded!),
                      if (_place.hours != null)
                        _buildInfoRow(_i18n.t('hours'), _place.hours!),
                      _buildInfoRow(_i18n.t('author'), _place.author),
                      _buildInfoRow(_i18n.t('created'), _place.displayCreated),
                    ]),

                    // History
                    if (history != null && history.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Text(
                            _i18n.t('history'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (_place.histories.length > 1) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${_place.histories.length} ${_i18n.t('languages')}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(history),
                        ),
                      ),
                    ],

                    PlaceFeedbackSection(
                      key: ValueKey(_place.folderPath ?? _place.placeFolderName),
                      place: _place,
                    ),

                    const SizedBox(height: 24),

                    // Action buttons
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          icon: const Icon(Icons.map),
                          label: Text(_i18n.t('view_on_map')),
                          onPressed: _viewOnMap,
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.navigation),
                          label: Text(_i18n.t('navigate')),
                          onPressed: _openInNavigator,
                        ),
                      ],
                    ),

                    const SizedBox(height: 32),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildInfoSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, {bool monospace = false}) {
    if (value.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              _i18n.t('coordinates'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              _place.coordinatesString,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: _copyCoordinates,
            tooltip: _i18n.t('copy_coordinates'),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.map, size: 18),
            onPressed: _viewOnMap,
            tooltip: _i18n.t('view_on_map'),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
