/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;
import '../models/app.dart';
import '../models/place.dart';
import '../services/place_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../platform/file_image_helper.dart' as file_helper;
import '../services/location_provider_service.dart';
import '../services/app_service.dart';
import '../services/groups_service.dart';
import '../services/profile_storage.dart';
import '../models/group.dart';
import 'location_picker_page.dart';
import 'photo_viewer_page.dart';
import '../widgets/file_folder_picker.dart';
import '../widgets/transcribe_button_widget.dart';

/// Helper class for group options in visibility selector
class _GroupOption {
  final Group group;
  final String? appTitle;

  const _GroupOption(this.group, this.appTitle);
}

/// Full-page form for adding or editing a place
class AddEditPlacePage extends StatefulWidget {
  final String appPath;
  final Place? place; // null for new place, non-null for edit

  const AddEditPlacePage({
    Key? key,
    required this.appPath,
    this.place,
  }) : super(key: key);

  @override
  State<AddEditPlacePage> createState() => _AddEditPlacePageState();
}

class _AddEditPlacePageState extends State<AddEditPlacePage> {
  final PlaceService _placeService = PlaceService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final _formKey = GlobalKey<FormState>();

  // Controllers for fields
  late TextEditingController _nameController;
  late TextEditingController _latitudeController;
  late TextEditingController _longitudeController;
  late TextEditingController _radiusController;
  late TextEditingController _addressController;
  late TextEditingController _typeController;
  late TextEditingController _foundedController;
  late TextEditingController _hoursController;
  late TextEditingController _descriptionController;
  late TextEditingController _historyController;

  // Photo state
  List<String> _imageFilePaths = [];  // New photos to add
  List<String> _existingImages = [];  // Already saved photos
  String? _profileImageSelection;
  bool _profileImageCleared = false;

  bool _isSaving = false;
  bool _advancedOptionsExpanded = false;

  // Visibility controls
  String _visibility = 'private';
  final Set<String> _selectedGroups = {};
  final List<_GroupOption> _availableGroups = [];
  bool _isLoadingGroups = true;

  // GPS preload state - uses shared LocationProviderService for efficient GPS sharing
  LockedPosition? _preloadedGPSLocation;
  VoidCallback? _disposeLocationConsumer;

  // Supported languages for multilingual content
  static const List<String> _supportedLanguages = ['EN', 'PT', 'ES', 'FR', 'DE', 'IT'];

  // Language selection for description and history
  String _descriptionLanguage = 'EN';
  String _historyLanguage = 'EN';

  // Store translations for description and history
  Map<String, String> _descriptions = {};
  Map<String, String> _histories = {};

  // Common place types for quick selection (sorted alphabetically, 'other' last)
  final List<String> _commonTypes = [
    'airport',
    'bar',
    'beach',
    'bus-station',
    'cafe',
    'campsite',
    'caravan-park',
    'church',
    'cinema',
    'firefighters',
    'fountain',
    'fruit-tree',
    'gallery',
    'geocaching',
    'grocery',
    'harbour',
    'hospital',
    'hotel',
    'house',
    'landmark',
    'library',
    'market',
    'meeting-point',
    'monument',
    'museum',
    'office',
    'overnight-parking',
    'park',
    'pharmacy',
    'police',
    'restaurant',
    'school',
    'shop',
    'store',
    'theater',
    'train-station',
    'veterinary',
    'viewpoint',
    'wild-camping',
    'other',
  ];

  @override
  void initState() {
    super.initState();
    _initializeControllers();
    _loadExistingImages();
    _startGPSPreload();
    _loadGroups();
  }

  /// Start GPS acquisition early so it's ready when user opens map picker
  /// Uses shared LocationProviderService for efficient GPS sharing across the app
  /// Only runs for new places on mobile devices
  Future<void> _startGPSPreload() async {
    // Only preload for new places (editing existing has coordinates)
    if (widget.place != null) return;
    // Only on mobile
    if (kIsWeb) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;

    final locationService = LocationProviderService();

    // Check if we already have a valid, high-accuracy position from another feature
    if (locationService.hasValidPosition) {
      final pos = locationService.currentPosition!;
      // Only use if it's high accuracy (< 100m, not cell tower)
      if (pos.accuracy < 100) {
        if (mounted) {
          setState(() => _preloadedGPSLocation = pos);
        }
        LogService().log(
            'GPS preload: Using existing position from LocationProviderService: ${pos.latitude}, ${pos.longitude} (accuracy: ${pos.accuracy.toStringAsFixed(0)}m)');
        return;
      }
    }

    // Register as a consumer to get GPS updates
    try {
      _disposeLocationConsumer = await locationService.registerConsumer(
        intervalSeconds: 30,
        onPosition: (pos) {
          // Only accept high-accuracy positions (< 100m)
          if (pos.accuracy < 100 && mounted) {
            setState(() => _preloadedGPSLocation = pos);
            LogService().log(
                'GPS preload complete: ${pos.latitude}, ${pos.longitude} (accuracy: ${pos.accuracy.toStringAsFixed(0)}m)');
          }
        },
      );
    } catch (e) {
      LogService().log('GPS preload failed: $e');
    }
  }

  void _initializeControllers() {
    final place = widget.place;

    // Determine user's current language (default to EN)
    final currentLang = _i18n.currentLanguage.toUpperCase().split('_').first;
    _descriptionLanguage = _supportedLanguages.contains(currentLang) ? currentLang : 'EN';
    _historyLanguage = _descriptionLanguage;

    _nameController = TextEditingController(text: place?.name ?? '');
    _latitudeController = TextEditingController(text: place?.latitude.toString() ?? '');
    _longitudeController = TextEditingController(text: place?.longitude.toString() ?? '');
    _radiusController = TextEditingController(text: place?.radius.toString() ?? '5');
    _addressController = TextEditingController(text: place?.address ?? '');
    _typeController = TextEditingController(text: place?.type ?? '');
    _foundedController = TextEditingController(text: place?.founded ?? '');
    _hoursController = TextEditingController(text: place?.hours ?? '');

    // Load existing translations and visibility when editing
    if (place != null) {
      _descriptions = Map<String, String>.from(place.descriptions);
      _histories = Map<String, String>.from(place.histories);
      _visibility = place.visibility;
      _selectedGroups.addAll(place.allowedGroups);

      // If no translations exist, use primary description/history
      if (_descriptions.isNotEmpty) {
        if (!_descriptions.containsKey(_descriptionLanguage)) {
          _descriptionLanguage = _descriptions.containsKey('EN')
              ? 'EN'
              : _descriptions.keys.first;
        }
      } else if (place.description.isNotEmpty) {
        _descriptions[_descriptionLanguage] = place.description;
      }
      if (_histories.isNotEmpty) {
        if (!_histories.containsKey(_historyLanguage)) {
          _historyLanguage = _histories.containsKey('EN')
              ? 'EN'
              : _histories.keys.first;
        }
      } else if (place.history != null && place.history!.isNotEmpty) {
        _histories[_historyLanguage] = place.history!;
      }
    }

    // Set controllers to current language content
    _descriptionController = TextEditingController(
      text: _descriptions[_descriptionLanguage] ?? place?.description ?? '',
    );
    _historyController = TextEditingController(
      text: _histories[_historyLanguage] ?? place?.history ?? '',
    );
  }

  /// Switch description language - save current content and load new language
  void _switchDescriptionLanguage(String newLang) {
    // Save current content before switching
    final currentContent = _descriptionController.text.trim();
    if (currentContent.isNotEmpty) {
      _descriptions[_descriptionLanguage] = currentContent;
    }

    // Switch to new language
    setState(() {
      _descriptionLanguage = newLang;
      _descriptionController.text = _descriptions[newLang] ?? '';
    });
  }

  /// Switch history language - save current content and load new language
  void _switchHistoryLanguage(String newLang) {
    // Save current content before switching
    final currentContent = _historyController.text.trim();
    if (currentContent.isNotEmpty) {
      _histories[_historyLanguage] = currentContent;
    }

    // Switch to new language
    setState(() {
      _historyLanguage = newLang;
      _historyController.text = _histories[newLang] ?? '';
    });
  }

  /// Get list of languages with existing translations
  List<String> _getDescriptionLanguagesWithContent() {
    final current = _descriptionController.text.trim();
    if (current.isNotEmpty) {
      _descriptions[_descriptionLanguage] = current;
    }
    return _descriptions.keys.where((k) => _descriptions[k]?.isNotEmpty ?? false).toList();
  }

  List<String> _getHistoryLanguagesWithContent() {
    final current = _historyController.text.trim();
    if (current.isNotEmpty) {
      _histories[_historyLanguage] = current;
    }
    return _histories.keys.where((k) => _histories[k]?.isNotEmpty ?? false).toList();
  }

  /// Load available groups for restricted visibility
  Future<void> _loadGroups() async {
    try {
      final app = AppService().getAppByType('groups');
      final groupCollections = app != null ? [app] : <App>[];

      _availableGroups.clear();
      final groupsService = GroupsService();
      final profile = _profileService.getProfile();

      for (final collection in groupCollections) {
        // Set profile storage for encrypted storage support
        final profileStorage = AppService().profileStorage;
        if (profileStorage != null) {
          final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
            profileStorage,
            collection.storagePath!,
          );
          groupsService.setStorage(scopedStorage);
        } else {
          groupsService.setStorage(FilesystemProfileStorage(collection.storagePath!));
        }
        await groupsService.initializeApp(
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
      LogService().log('Error loading groups: $e');
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

  /// Load existing images from the place folder
  Future<void> _loadExistingImages() async {
    if (kIsWeb || widget.place?.folderPath == null) return;

    try {
      final folderPath = widget.place!.folderPath!;
      final images = <String>[];

      final imagesDir = Directory('$folderPath/images');
      if (await imagesDir.exists()) {
        final entities = await imagesDir.list().toList();
        images.addAll(
          entities
              .where((e) => e is File && _isImageFile(e.path))
              .map((e) => e.path),
        );
      }

      final rootDir = Directory(folderPath);
      if (await rootDir.exists()) {
        final entities = await rootDir.list().toList();
        images.addAll(
          entities
              .where((e) => e is File && _isImageFile(e.path))
              .where((e) => path.basename(e.path).toLowerCase() != 'place.txt')
              .map((e) => e.path),
        );
      }

      images.sort();

      setState(() {
        _existingImages = images;
      });

      final profileImage = widget.place?.profileImage;
      if (profileImage != null && profileImage.isNotEmpty) {
        final resolved = path.isAbsolute(profileImage)
            ? profileImage
            : path.join(folderPath, profileImage);
        if (_existingImages.contains(resolved)) {
          setState(() {
            _profileImageSelection = resolved;
            _profileImageCleared = false;
          });
        }
      }
    } catch (e) {
      LogService().log('Error loading place images: $e');
    }
  }

  bool _isImageFile(String path) {
    final ext = path.toLowerCase();
    return ext.endsWith('.jpg') || ext.endsWith('.jpeg') ||
           ext.endsWith('.png') || ext.endsWith('.gif') ||
           ext.endsWith('.webp');
  }

  Map<String, String> _buildImageDestinations(String placeFolderPath) {
    if (_imageFilePaths.isEmpty) {
      return {};
    }

    final destinations = <String, String>{};
    final imagesDir = Directory('$placeFolderPath/images');

    var photoNumber = 1;
    if (imagesDir.existsSync()) {
      final entities = imagesDir.listSync();
      final existingPhotos = entities.where((e) =>
          e is File && e.path.contains('photo') && _isImageFile(e.path));
      photoNumber = existingPhotos.length + 1;
    }

    for (final imagePath in _imageFilePaths) {
      final ext = path.extension(imagePath).toLowerCase();
      final destPath = '${imagesDir.path}/photo$photoNumber$ext';
      destinations[imagePath] = destPath;
      photoNumber++;
    }

    return destinations;
  }

  String? _resolveProfileImageRelativePath(
    String placeFolderPath,
    Map<String, String> imageDestinations,
  ) {
    final selection = _profileImageSelection;
    if (selection == null || selection.isEmpty) {
      return null;
    }

    final pendingDestination = imageDestinations[selection];
    if (pendingDestination != null) {
      return path.relative(pendingDestination, from: placeFolderPath);
    }

    if (path.isAbsolute(selection) && selection.startsWith(placeFolderPath)) {
      return path.relative(selection, from: placeFolderPath);
    }

    return null;
  }

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Pick images from file system
  Future<void> _pickImages() async {
    if (kIsWeb) return;

    try {
      final paths = await FileFolderPicker.show(
        context,
        title: I18nService().t('select_photos'),
        allowMultiSelect: true,
        allowedExtensions: FileFolderPicker.imageExtensions,
        profileStorage: AppService().profileStorage,
        initialDirectory: _isMobile ? 'virtual://recent' : null,
        initialGridView: _isMobile,
      );

      if (paths != null && paths.isNotEmpty) {
        setState(() {
          _imageFilePaths.addAll(paths);

          // Auto-select first image as profile picture if none selected yet
          if (_profileImageSelection == null && !_profileImageCleared) {
            if (_existingImages.isNotEmpty) {
              _profileImageSelection = _existingImages.first;
            } else if (_imageFilePaths.isNotEmpty) {
              _profileImageSelection = _imageFilePaths.first;
            }
          }
        });
      }
    } catch (e) {
      LogService().log('Error picking images: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking images: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Take photo with camera (mobile only)
  Future<void> _takePhoto() async {
    if (kIsWeb) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;

    try {
      final picker = ImagePicker();
      final photo = await picker.pickImage(source: ImageSource.camera);

      if (photo != null) {
        setState(() {
          _imageFilePaths.add(photo.path);

          // Auto-select first image as profile picture if none selected yet
          if (_profileImageSelection == null && !_profileImageCleared) {
            if (_existingImages.isNotEmpty) {
              _profileImageSelection = _existingImages.first;
            } else if (_imageFilePaths.isNotEmpty) {
              _profileImageSelection = _imageFilePaths.first;
            }
          }
        });
      }
    } catch (e) {
      LogService().log('Error taking photo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error taking photo: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _removeImage(int index, {bool isExisting = false}) {
    setState(() {
      if (isExisting) {
        final removedPath = _existingImages[index];
        if (_profileImageSelection == removedPath) {
          _profileImageSelection = null;
          _profileImageCleared = true;
        }
        _existingImages.removeAt(index);
      } else {
        final removedPath = _imageFilePaths[index];
        if (_profileImageSelection == removedPath) {
          _profileImageSelection = null;
          _profileImageCleared = true;
        }
        _imageFilePaths.removeAt(index);
      }
    });
  }

  /// Open the photo viewer at the specified index
  void _openPhotoViewer(int index, {bool isExisting = true}) {
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

  void _toggleProfileImage(String imagePath) {
    setState(() {
      if (_profileImageSelection == imagePath) {
        _profileImageSelection = null;
        _profileImageCleared = true;
      } else {
        _profileImageSelection = imagePath;
        _profileImageCleared = false;
      }
    });
  }

  @override
  void dispose() {
    // Unregister from LocationProviderService
    _disposeLocationConsumer?.call();
    _nameController.dispose();
    _latitudeController.dispose();
    _longitudeController.dispose();
    _radiusController.dispose();
    _addressController.dispose();
    _typeController.dispose();
    _foundedController.dispose();
    _hoursController.dispose();
    _descriptionController.dispose();
    _historyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Validate location is selected
    final latText = _latitudeController.text.trim();
    final lonText = _longitudeController.text.trim();
    final latitude = double.tryParse(latText);
    final longitude = double.tryParse(lonText);

    if (latitude == null || longitude == null ||
        latitude < -90 || latitude > 90 ||
        longitude < -180 || longitude > 180) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('location_required_hint')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Validate restricted visibility has groups selected
    if (_visibility == 'restricted' && _selectedGroups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('select_groups_for_restricted')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      // Collect values
      final name = _nameController.text.trim();
      final radius = int.parse(_radiusController.text.trim());
      final address = _addressController.text.trim();
      final type = _typeController.text.trim();
      final founded = _foundedController.text.trim();
      final hours = _hoursController.text.trim();
      final description = _descriptionController.text.trim();
      final history = _historyController.text.trim();

      // Save current content to translations map
      if (description.isNotEmpty) {
        _descriptions[_descriptionLanguage] = description;
      }
      if (history.isNotEmpty) {
        _histories[_historyLanguage] = history;
      }

      // Get primary description (first available)
      final primaryDescription = _descriptions.values.firstWhere(
        (v) => v.isNotEmpty,
        orElse: () => description,
      );

      // Get primary history (first available or null)
      String? primaryHistory;
      if (_histories.isNotEmpty) {
        primaryHistory = _histories.values.firstWhere(
          (v) => v.isNotEmpty,
          orElse: () => '',
        );
        if (primaryHistory.isEmpty) primaryHistory = null;
      } else if (history.isNotEmpty) {
        primaryHistory = history;
      }

      // Create timestamp
      final now = DateTime.now();
      final timestamp = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

      // Get current user as author
      final profile = _profileService.getProfile();
      final author = profile.callsign.isNotEmpty ? profile.callsign : 'ANONYMOUS';

      // Create place object with translations
      final draftPlace = Place(
        name: name,
        created: widget.place?.created ?? timestamp,
        author: widget.place?.author ?? author,
        latitude: latitude,
        longitude: longitude,
        radius: radius,
        address: address.isNotEmpty ? address : null,
        type: type, // Now required
        founded: founded.isNotEmpty ? founded : null,
        hours: hours.isNotEmpty ? hours : null,
        description: primaryDescription, // Primary description
        descriptions: Map<String, String>.from(_descriptions), // All translations
        history: primaryHistory,
        histories: Map<String, String>.from(_histories), // All translations
        visibility: _visibility,
        allowedGroups: _selectedGroups.toList(),
      );

      final placeFolderPath = kIsWeb ? null : await _placeService.getPlaceFolderPath(draftPlace);
      final imageDestinations = placeFolderPath != null
          ? _buildImageDestinations(placeFolderPath)
          : <String, String>{};
      var profileImage = placeFolderPath != null
          ? _resolveProfileImageRelativePath(placeFolderPath, imageDestinations)
          : null;
      if (profileImage == null &&
          !_profileImageCleared &&
          widget.place?.profileImage != null) {
        profileImage = widget.place!.profileImage;
      }

      final place = draftPlace.copyWith(profileImage: profileImage);

      // Save place
      final error = await _placeService.savePlace(place);

      if (error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: Colors.red),
          );
        }
      } else {
        // Save images after place is saved
        await _saveImages(
          place,
          imageDestinations: imageDestinations,
          placeFolderPath: placeFolderPath,
        );

        // Don't upload automatically - user can publish later via "Publish" button
        // This allows saving places offline and publishing when back on wifi

        if (mounted) {
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  /// Save photos to the place folder
  Future<void> _saveImages(
    Place place, {
    required Map<String, String> imageDestinations,
    String? placeFolderPath,
  }) async {
    if (kIsWeb || imageDestinations.isEmpty) return;

    try {
      final resolvedFolderPath = placeFolderPath ?? await _placeService.getPlaceFolderPath(place);
      if (resolvedFolderPath == null) return;

      final imagesDir = Directory('$resolvedFolderPath/images');

      // Create images directory if it doesn't exist
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }

      for (final entry in imageDestinations.entries) {
        final imagePath = entry.key;
        final destPath = entry.value;
        final imageFile = File(imagePath);
        await imageFile.copy(destPath);
      }

      _imageFilePaths.clear();
      LogService().log('Saved ${imageDestinations.length} photos for place ${place.name}');
    } catch (e) {
      LogService().log('Error saving place images: $e');
    }
  }

  Future<void> _openMapPicker() async {
    // Priority: 1) existing coordinates from form, 2) preloaded GPS location
    LatLng? initialPosition;
    final lat = double.tryParse(_latitudeController.text.trim());
    final lon = double.tryParse(_longitudeController.text.trim());
    if (lat != null && lon != null && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
      initialPosition = LatLng(lat, lon);
    } else if (_preloadedGPSLocation != null) {
      // Use preloaded GPS position from LocationProviderService
      initialPosition = LatLng(
        _preloadedGPSLocation!.latitude,
        _preloadedGPSLocation!.longitude,
      );
      LogService().log('Using preloaded GPS for map picker: ${initialPosition.latitude}, ${initialPosition.longitude}');
    }

    // Open location picker
    final result = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (context) => LocationPickerPage(
          initialPosition: initialPosition,
        ),
      ),
    );

    // Update coordinates if location was selected
    if (result != null) {
      setState(() {
        _latitudeController.text = result.latitude.toStringAsFixed(6);
        _longitudeController.text = result.longitude.toStringAsFixed(6);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.place != null;
    final currentType = _typeController.text.trim();
    final typeOptions = List<String>.from(_commonTypes);
    if (currentType.isNotEmpty && !typeOptions.contains(currentType)) {
      typeOptions.insert(0, currentType);
    }

    String formatTypeLabel(String type) {
      final key = 'place_type_$type';
      final translation = _i18n.t(key);
      return translation == key ? type : translation;
    }
    final placeNameSection = <Widget>[
      TextFormField(
        controller: _nameController,
        decoration: InputDecoration(
          labelText: '${_i18n.t('place_name')} *',
          border: const OutlineInputBorder(),
          hintText: 'Historic Café Landmark',
        ),
        textCapitalization: TextCapitalization.words,
        validator: (value) {
          if (value == null || value.trim().isEmpty) {
            return _i18n.t('field_required');
          }
          return null;
        },
      ),
      const SizedBox(height: 16),
    ];
    final locationSection = <Widget>[
      Text(
        '${_i18n.t('location')} *',
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _openMapPicker,
          icon: const Icon(Icons.map),
          label: Text(_i18n.t('pick_location_on_map')),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ),
      const SizedBox(height: 12),
      if (_latitudeController.text.isNotEmpty && _longitudeController.text.isNotEmpty)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.location_on,
                color: Theme.of(context).colorScheme.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${_latitudeController.text}, ${_longitudeController.text}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () {
                  setState(() {
                    _latitudeController.clear();
                    _longitudeController.clear();
                  });
                },
                tooltip: _i18n.t('clear'),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        )
      else
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer.withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).colorScheme.error.withOpacity(0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber,
                color: Theme.of(context).colorScheme.error,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _i18n.t('location_required_hint'),
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 16),
    ];
    // Name always first - gives GPS time to acquire while user types
    final requiredFields = <Widget>[
      ...placeNameSection,
      ...locationSection,
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? _i18n.t('edit_place') : _i18n.t('new_place')),
        actions: [
          if (!_isSaving)
            TextButton(
              onPressed: _save,
              child: Text(
                _i18n.t('save'),
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Required Fields Section
            Text(
              _i18n.t('required_fields'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),

            ...requiredFields,

            // Type and Language selector on same row
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Type (with suggestions)
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: currentType.isNotEmpty ? currentType : null,
                    decoration: InputDecoration(
                      labelText: '${_i18n.t('place_type')} *',
                      border: const OutlineInputBorder(),
                      hintText: _i18n.t('select_type'),
                    ),
                    items: typeOptions.map((type) {
                      return DropdownMenuItem<String>(
                        value: type,
                        child: Text(formatTypeLabel(type)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _typeController.text = value ?? '';
                      });
                    },
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return _i18n.t('field_required');
                      }
                      return null;
                    },
                    isExpanded: true,
                  ),
                ),
                const SizedBox(width: 12),
                // Language selector for description
                Column(
                  children: [
                    PopupMenuButton<String>(
                      initialValue: _descriptionLanguage,
                      onSelected: _switchDescriptionLanguage,
                      tooltip: _i18n.t('select_language'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                        decoration: BoxDecoration(
                          border: Border.all(color: Theme.of(context).colorScheme.outline),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _descriptionLanguage,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.arrow_drop_down, size: 20),
                          ],
                        ),
                      ),
                      itemBuilder: (context) => _supportedLanguages.map((lang) {
                        final hasContent = _descriptions[lang]?.isNotEmpty ?? false;
                        return PopupMenuItem<String>(
                          value: lang,
                          child: Row(
                            children: [
                              Text(lang),
                              if (hasContent) ...[
                                const SizedBox(width: 8),
                                Icon(Icons.check_circle, size: 16, color: Colors.green.shade600),
                              ],
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                    // Show languages with content
                    if (widget.place != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${_getDescriptionLanguagesWithContent().length}/${_supportedLanguages.length}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Description (optional)
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: _i18n.t('description'),
                border: const OutlineInputBorder(),
                helperText: _i18n.t('place_description_help'),
                helperMaxLines: 2,
                suffixIcon: TranscribeButtonWidget(
                  i18n: _i18n,
                  onTranscribed: (text) {
                    // Append transcribed text to description
                    if (_descriptionController.text.isEmpty) {
                      _descriptionController.text = text;
                    } else {
                      _descriptionController.text += ' $text';
                    }
                  },
                ),
              ),
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 24),

            // Photos Section
            if (!kIsWeb) ...[
              Text(
                _i18n.t('photos'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickImages,
                    icon: const Icon(Icons.add_photo_alternate),
                    label: Text(_i18n.t('add_photos')),
                  ),
                  if (Platform.isAndroid || Platform.isIOS) ...[
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      onPressed: _takePhoto,
                      icon: const Icon(Icons.camera_alt),
                      tooltip: _i18n.t('take_photo'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              // Only show profile picture hint when there are photos
              if (_existingImages.isNotEmpty || _imageFilePaths.isNotEmpty) ...[
                Text(
                  _i18n.t('select_profile_picture'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
              ],
              if (_existingImages.isNotEmpty || _imageFilePaths.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // Existing images
                    ..._existingImages.asMap().entries.map((entry) {
                      final imagePath = entry.value;
                      final isProfile = _profileImageSelection == imagePath;
                      final imageWidget = file_helper.buildFileImage(
                        imagePath,
                        width: 100,
                        height: 100,
                        fit: BoxFit.cover,
                      );
                      if (imageWidget == null) return const SizedBox.shrink();
                      return GestureDetector(
                        onTap: () => _openPhotoViewer(entry.key, isExisting: true),
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: imageWidget,
                            ),
                            Positioned(
                              top: 4,
                              left: 4,
                              child: Tooltip(
                                message: _i18n.t('select_profile_picture'),
                                child: GestureDetector(
                                  onTap: () => _toggleProfileImage(imagePath),
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: isProfile ? Colors.amber : Colors.black54,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      isProfile ? Icons.star : Icons.star_border,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: GestureDetector(
                                onTap: () => _removeImage(entry.key, isExisting: true),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    // New images
                    ..._imageFilePaths.asMap().entries.map((entry) {
                      final imagePath = entry.value;
                      final isProfile = _profileImageSelection == imagePath;
                      final imageWidget = file_helper.buildFileImage(
                        imagePath,
                        width: 100,
                        height: 100,
                        fit: BoxFit.cover,
                      );
                      if (imageWidget == null) return const SizedBox.shrink();
                      return GestureDetector(
                        onTap: () => _openPhotoViewer(entry.key, isExisting: false),
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: imageWidget,
                            ),
                            Positioned(
                              top: 4,
                              left: 4,
                              child: Tooltip(
                                message: _i18n.t('select_profile_picture'),
                                child: GestureDetector(
                                  onTap: () => _toggleProfileImage(imagePath),
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: isProfile ? Colors.amber : Colors.black54,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      isProfile ? Icons.star : Icons.star_border,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: GestureDetector(
                                onTap: () => _removeImage(entry.key, isExisting: false),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              const SizedBox(height: 24),
            ],

            // Visibility Section
            Text(
              _i18n.t('visibility'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
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
                      Text(_i18n.t('visibility_public')),
                    ],
                  ),
                ),
                DropdownMenuItem(
                  value: 'private',
                  child: Row(
                    children: [
                      const Icon(Icons.lock, size: 20),
                      const SizedBox(width: 8),
                      Text(_i18n.t('visibility_private')),
                    ],
                  ),
                ),
                DropdownMenuItem(
                  value: 'restricted',
                  child: Row(
                    children: [
                      const Icon(Icons.group, size: 20),
                      const SizedBox(width: 8),
                      Text(_i18n.t('visibility_restricted')),
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
            if (_visibility == 'restricted') ...[
              const SizedBox(height: 16),
              Text(
                _i18n.t('place_groups_access'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (_isLoadingGroups)
                const LinearProgressIndicator()
              else if (_availableGroups.isEmpty)
                Text(
                  _i18n.t('no_groups_available'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                )
              else
                ..._availableGroups.map((option) {
                  final label = _groupLabel(option);
                  final subtitleParts = <String>[];
                  if (option.group.title.isNotEmpty && option.group.name != option.group.title) {
                    subtitleParts.add(option.group.name);
                  }
                  if (option.appTitle != null && option.appTitle!.isNotEmpty) {
                    subtitleParts.add(option.appTitle!);
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

            // Advanced Options Section (expandable, closed by default)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: _advancedOptionsExpanded,
                onExpansionChanged: (expanded) {
                  setState(() => _advancedOptionsExpanded = expanded);
                },
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(top: 8),
                title: Text(
                  _i18n.t('advanced_options'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                children: [
                  // Radius
                  TextFormField(
                    controller: _radiusController,
                    decoration: InputDecoration(
                      labelText: '${_i18n.t('radius_meters')} *',
                      border: const OutlineInputBorder(),
                      hintText: '5',
                    ),
                    keyboardType: TextInputType.number,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return _i18n.t('field_required');
                      }
                      final radius = int.tryParse(value.trim());
                      if (radius == null || radius < 1 || radius > 1000) {
                        return _i18n.t('radius_range_error');
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Address
                  TextFormField(
                    controller: _addressController,
                    decoration: InputDecoration(
                      labelText: _i18n.t('address'),
                      border: const OutlineInputBorder(),
                      hintText: '123 Main Street, Lisbon, Portugal',
                    ),
                    maxLines: 2,
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 16),

                  // Founded
                  TextFormField(
                    controller: _foundedController,
                    decoration: InputDecoration(
                      labelText: _i18n.t('founded'),
                      border: const OutlineInputBorder(),
                      hintText: '1782, 12th century, circa 1500, Roman era',
                    ),
                    textCapitalization: TextCapitalization.sentences,
                  ),
                  const SizedBox(height: 16),

                  // Hours
                  TextFormField(
                    controller: _hoursController,
                    decoration: InputDecoration(
                      labelText: _i18n.t('hours'),
                      border: const OutlineInputBorder(),
                      hintText: 'Mon-Fri 9:00-17:00, Sat-Sun 10:00-16:00',
                    ),
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                  ),
                  const SizedBox(height: 16),

                  // History with language selector
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _historyController,
                          decoration: InputDecoration(
                            labelText: _i18n.t('history'),
                            border: const OutlineInputBorder(),
                            helperText: _i18n.t('place_history_help'),
                            helperMaxLines: 2,
                            suffixIcon: TranscribeButtonWidget(
                              i18n: _i18n,
                              onTranscribed: (text) {
                                if (_historyController.text.isEmpty) {
                                  _historyController.text = text;
                                } else {
                                  _historyController.text += ' $text';
                                }
                              },
                            ),
                          ),
                          maxLines: 6,
                          textCapitalization: TextCapitalization.sentences,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        children: [
                          PopupMenuButton<String>(
                            initialValue: _historyLanguage,
                            onSelected: _switchHistoryLanguage,
                            tooltip: _i18n.t('select_language'),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                border: Border.all(color: Theme.of(context).colorScheme.outline),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _historyLanguage,
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.arrow_drop_down, size: 20),
                                ],
                              ),
                            ),
                            itemBuilder: (context) => _supportedLanguages.map((lang) {
                              final hasContent = _histories[lang]?.isNotEmpty ?? false;
                              return PopupMenuItem<String>(
                                value: lang,
                                child: Row(
                                  children: [
                                    Text(lang),
                                    if (hasContent) ...[
                                      const SizedBox(width: 8),
                                      Icon(Icons.check_circle, size: 16, color: Colors.green.shade600),
                                    ],
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                          // Show languages with content
                          if (widget.place != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${_getHistoryLanguagesWithContent().length}/${_supportedLanguages.length}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Save Button
            FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_i18n.t('save')),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
