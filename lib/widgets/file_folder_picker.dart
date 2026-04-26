import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../models/file_browser_cache_models.dart';
import '../models/mirror_config.dart';
import '../models/sync_file_version.dart';
import '../pages/transfer_send_page.dart';
import '../services/file_browser_cache_service.dart';
import '../services/mirror_auto_sync_service.dart';
import '../services/profile_storage.dart';
import '../services/recent_files_service.dart';
import '../services/sync_version_service.dart';
import '../util/video_metadata_extractor.dart';

/// Sort mode for file/folder listing
enum FileSortMode {
  name,
  size,
  modified,
}

/// A storage location (root directory, USB drive, etc.)
class StorageLocation {
  final String name;
  final String path;
  final IconData icon;
  final bool isRemovable;
  final bool isVirtual;

  const StorageLocation({
    required this.name,
    required this.path,
    required this.icon,
    this.isRemovable = false,
    this.isVirtual = false,
  });
}

/// Information about a file or folder
class FileSystemItem {
  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime modified;
  final FileSystemEntityType type;

  const FileSystemItem({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modified,
    required this.type,
  });
}

/// A full-featured file and folder picker widget
///
/// Features:
/// - Browse files and folders with rich icons
/// - Show file sizes and folder total sizes
/// - Sort by name, size, or modification date
/// - Access storage media (USB, removable storage)
/// - Multi-select support
/// - Works on Linux and Android
///
/// Usage:
/// ```dart
/// final selected = await FileFolderPicker.show(
///   context: context,
///   title: 'Select files or folders',
///   allowMultiSelect: true,
/// );
/// if (selected != null && selected.isNotEmpty) {
///   // Use selected paths
/// }
/// ```
class FileFolderPicker extends StatefulWidget {
  /// Common image file extensions.
  static const imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg'};

  /// Common video file extensions.
  static const videoExtensions = {'mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv', 'webm'};

  /// Best-effort starting directory for picking photos / video clips.
  ///
  /// Resolves to the platform's user-facing media folder so the picker
  /// lands where the user expects:
  ///   - Android   → `virtual://recent` (the Recent virtual folder backed by
  ///                 MediaStore — same as the storage shortcut).
  ///   - Linux     → `$HOME/Pictures` if it exists, else $HOME.
  ///   - Windows   → `%USERPROFILE%\\Pictures` if it exists, else %USERPROFILE%.
  ///   - macOS     → `$HOME/Pictures` if it exists, else $HOME.
  ///   - elsewhere → null (the picker falls back to its own default).
  ///
  /// Synchronous so it can be passed straight into [FileFolderPicker.show];
  /// it only checks `Directory.existsSync()` on a single path which is cheap.
  static String? defaultMediaDirectory() {
    if (Platform.isAndroid) {
      return 'virtual://recent';
    }
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    final pictures = '$home${Platform.pathSeparator}Pictures';
    if (Directory(pictures).existsSync()) return pictures;
    return home;
  }

  final String? initialDirectory;
  final String title;
  final bool allowMultiSelect;
  final bool showHiddenFiles;

  /// When set, only files with these extensions (lowercase, no dot) can be selected.
  /// Directories are always navigable regardless of this filter.
  final Set<String>? allowedExtensions;

  /// When provided, tapping a file calls this instead of toggling selection.
  /// Used for explorer mode where files are opened directly.
  final ValueChanged<String>? onFileOpen;

  /// When true, hides the selection toolbar and confirm button.
  /// Files are opened via [onFileOpen] instead of selected.
  final bool explorerMode;

  /// Additional storage location shortcuts (e.g. Geogram profile folder).
  final List<StorageLocation>? extraLocations;

  /// Called when internal toolbar state changes (view mode, sort, etc.)
  /// so the parent can rebuild its AppBar actions.
  final VoidCallback? onStateChanged;

  /// Optional profile storage for reading files inside the callsign folder.
  /// When provided, directories inside the storage base path will be listed
  /// via ProfileStorage instead of raw filesystem access.
  final ProfileStorage? profileStorage;

  /// Whether to show the storage location bar (Home, Downloads, etc.).
  /// Defaults to true.
  final bool showStorageBar;

  /// When set, breadcrumbs only show segments at or below this path,
  /// and upward navigation is clamped to this root.
  final String? rootPath;

  /// When true, the picker starts in grid/gallery view instead of list view.
  final bool initialGridView;

  const FileFolderPicker({
    super.key,
    this.initialDirectory,
    this.title = 'Select files or folders',
    this.allowMultiSelect = true,
    this.showHiddenFiles = false,
    this.allowedExtensions,
    this.onFileOpen,
    this.explorerMode = false,
    this.extraLocations,
    this.onStateChanged,
    this.profileStorage,
    this.showStorageBar = true,
    this.rootPath,
    this.initialGridView = false,
  });

  /// Show the picker as a full-screen dialog
  static Future<List<String>?> show(
    BuildContext context, {
    String? initialDirectory,
    String title = 'Select files or folders',
    bool allowMultiSelect = true,
    bool showHiddenFiles = false,
    Set<String>? allowedExtensions,
    ProfileStorage? profileStorage,
    bool initialGridView = false,
  }) {
    return Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (context) => FileFolderPicker(
          initialDirectory: initialDirectory,
          title: title,
          allowMultiSelect: allowMultiSelect,
          showHiddenFiles: showHiddenFiles,
          allowedExtensions: allowedExtensions,
          profileStorage: profileStorage,
          initialGridView: initialGridView,
        ),
      ),
    );
  }

  @override
  State<FileFolderPicker> createState() => FileFolderPickerState();
}

class FileFolderPickerState extends State<FileFolderPicker> {
  late Directory _currentDirectory;
  List<FileSystemItem> _items = [];
  final Set<String> _selectedPaths = {};
  bool _isLoading = true;
  bool _showHidden = false;
  FileSortMode _sortMode = FileSortMode.name;
  bool _sortAscending = true;
  List<StorageLocation> _storageLocations = [];
  late String _baseDirectory;

  int get _bestStorageMatch {
    // If in a virtual folder, find the matching virtual location
    if (_isVirtualFolder && _virtualFolderType != null) {
      for (int i = 0; i < _storageLocations.length; i++) {
        final loc = _storageLocations[i];
        if (loc.isVirtual && loc.path == 'virtual://$_virtualFolderType') {
          return i;
        }
      }
    }

    int bestIndex = -1;
    int bestLength = -1;
    for (int i = 0; i < _storageLocations.length; i++) {
      final loc = _storageLocations[i];
      if (loc.isVirtual) continue;  // Skip virtual locations for path matching
      if (_currentDirectory.path.startsWith(loc.path) &&
          loc.path.length > bestLength) {
        bestLength = loc.path.length;
        bestIndex = i;
      }
    }
    return bestIndex;
  }
  final Map<String, int> _folderSizeCache = {};  // In-memory cache for current session
  final Set<String> _calculatingFolders = {};
  final Map<String, String?> _thumbnailCache = {};  // path -> thumbnail path
  final Set<String> _loadingThumbnails = {};
  final List<FileSystemItem> _clipboardItems = [];
  String? _error;
  bool _isGridView = false;
  final FileBrowserCacheService _cacheService = FileBrowserCacheService();
  bool _cacheInitialized = false;
  final FocusNode _keyboardFocusNode = FocusNode();
  final ScrollController _breadcrumbScrollController = ScrollController();
  bool _isVirtualFolder = false;
  String? _virtualFolderType;
  bool _isDragOver = false;
  String? _dragTargetPath;  // path of folder currently hovered during internal drag
  bool _isImporting = false;
  int _importTotal = 0;
  int _importProgress = 0;
  String? _importCurrentFile;

  @override
  void initState() {
    super.initState();
    _showHidden = widget.showHiddenFiles;
    _isGridView = widget.initialGridView;
    // Initialize directory paths immediately to avoid late init errors
    final initial = widget.initialDirectory ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        (Platform.isAndroid ? '/storage/emulated/0' : '/');

    final isVirtual = initial.startsWith('virtual://');
    _baseDirectory = isVirtual
        ? (Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            (Platform.isAndroid ? '/storage/emulated/0' : '/'))
        : initial;
    _currentDirectory = Directory(_baseDirectory);

    // Wait for cache service before loading directory contents
    _initializeCacheService().then((_) {
      if (mounted) {
        if (isVirtual) {
          _loadVirtualFolder(initial);
        } else {
          _loadDirectory();
        }
      }
    });
    _detectStorageLocations();
  }

  @override
  void dispose() {
    // Flush any pending cache writes before disposing
    _cacheService.flush();
    _keyboardFocusNode.dispose();
    _breadcrumbScrollController.dispose();
    super.dispose();
  }

  Future<void> _initializeCacheService() async {
    await _cacheService.initialize();
    _cacheInitialized = true;
  }

  /// Whether the current directory is inside the profile storage base path.
  bool _isInsideProfileStorage() {
    final storage = widget.profileStorage;
    if (storage == null) return false;
    final basePath = storage.basePath;
    final dirPath = _currentDirectory.path;
    return dirPath == basePath || p.isWithin(basePath, dirPath);
  }

  String? _profileRelativePath(String fullPath) {
    final storage = widget.profileStorage;
    if (storage == null) return null;
    final basePath = storage.basePath;
    if (fullPath == basePath) return '';
    if (!p.isWithin(basePath, fullPath)) return null;
    return p.relative(fullPath, from: basePath).replaceAll('\\', '/');
  }

  bool _isSyncableProfilePath(String relativePath) {
    final firstSegment = relativePath.split('/').first;
    return kSyncableFolders.contains(firstSegment);
  }

  void _scheduleSyncForProfilePath(String? relativePath, String reason) {
    if (relativePath == null || relativePath.isEmpty) return;
    if (!_isSyncableProfilePath(relativePath)) return;
    MirrorAutoSyncService.instance.requestSyncSoon(reason: reason);
  }

  Future<void> _archiveAndTombstoneStorageFile(String relativePath) async {
    if (!_isSyncableProfilePath(relativePath)) return;
    final slash = relativePath.indexOf('/');
    if (slash <= 0 || slash == relativePath.length - 1) return;
    final folder = relativePath.substring(0, slash);
    final filePath = relativePath.substring(slash + 1);
    final storage = widget.profileStorage!;
    final version = await SyncVersionService.instance.archiveProfileFile(
      folder: folder,
      filePath: filePath,
      reason: SyncVersionReason.deleted,
      storage: storage,
    );
    await SyncVersionService.instance.recordTombstone(
      folder: folder,
      filePath: filePath,
      size: version?.size,
      sha1Hash: version?.sha1,
      storage: storage,
    );
  }

  Future<void> _archiveAndTombstoneStorageTree(String relativePath) async {
    final storage = widget.profileStorage!;
    if (await storage.exists(relativePath)) {
      await _archiveAndTombstoneStorageFile(relativePath);
      return;
    }
    final entries = await storage.listDirectory(relativePath, recursive: true);
    for (final entry in entries) {
      if (!entry.isDirectory) {
        await _archiveAndTombstoneStorageFile(entry.path);
      }
    }
  }

  /// Load directory contents from ProfileStorage instead of raw filesystem.
  Future<void> _loadDirectoryFromStorage() async {
    final storage = widget.profileStorage!;
    final basePath = storage.basePath;
    final dirPath = _currentDirectory.path;

    // Compute relative path within the storage
    final relativePath = dirPath == basePath
        ? ''
        : p.relative(dirPath, from: basePath);

    try {
      final entries = await storage.listDirectory(relativePath);
      final items = <FileSystemItem>[];

      for (final entry in entries) {
        final name = entry.name;
        if (!_showHidden && name.startsWith('.')) continue;

        items.add(FileSystemItem(
          path: storage.getAbsolutePath(entry.path),
          name: name,
          isDirectory: entry.isDirectory,
          size: entry.size ?? 0,
          modified: entry.modified ?? DateTime.now(),
          type: entry.isDirectory
              ? FileSystemEntityType.directory
              : FileSystemEntityType.file,
        ));
      }

      _sortItems(items);

      if (mounted) {
        setState(() {
          _items = items;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _items = [];
          _isLoading = false;
          _error = 'Cannot access this folder';
        });
      }
    }
  }

  Future<void> _detectStorageLocations() async {
    final locations = <StorageLocation>[];

    // Home directory
    final home = Platform.environment['HOME'];
    if (home != null) {
      locations.add(StorageLocation(
        name: 'Home',
        path: home,
        icon: Icons.home_rounded,
      ));

      // Common directories
      final downloads = Directory('$home/Downloads');
      if (await downloads.exists()) {
        locations.add(StorageLocation(
          name: 'Downloads',
          path: downloads.path,
          icon: Icons.download_rounded,
        ));
      }

      final documents = Directory('$home/Documents');
      if (await documents.exists()) {
        locations.add(StorageLocation(
          name: 'Documents',
          path: documents.path,
          icon: Icons.folder_rounded,
        ));
      }

      final pictures = Directory('$home/Pictures');
      if (await pictures.exists()) {
        locations.add(StorageLocation(
          name: 'Pictures',
          path: pictures.path,
          icon: Icons.image_rounded,
        ));
      }
    }

    if (Platform.isLinux) {
      // Root
      locations.add(const StorageLocation(
        name: 'Computer',
        path: '/',
        icon: Icons.computer_rounded,
      ));

      // Media mount points (USB drives, etc.)
      await _addLinuxMountPoints(locations, '/media');
      await _addLinuxMountPoints(locations, '/mnt');
      await _addLinuxMountPoints(locations, '/run/media');
    } else if (Platform.isAndroid) {
      // Add "Recent" virtual folder first (Android only, uses MediaStore)
      locations.add(const StorageLocation(
        name: 'Recent',
        path: 'virtual://recent',
        icon: Icons.history_rounded,
        isVirtual: true,
      ));

      locations.add(const StorageLocation(
        name: 'Internal',
        path: '/storage/emulated/0',
        icon: Icons.phone_android_rounded,
      ));

      // Check for SD card
      final storageDir = Directory('/storage');
      if (await storageDir.exists()) {
        try {
          await for (final entity in storageDir.list()) {
            if (entity is Directory) {
              final name = p.basename(entity.path);
              if (name != 'emulated' && name != 'self') {
                locations.add(StorageLocation(
                  name: 'SD Card',
                  path: entity.path,
                  icon: Icons.sd_card_rounded,
                  isRemovable: true,
                ));
              }
            }
          }
        } catch (_) {}
      }
    } else if (Platform.isWindows) {
      // Home directory (USERPROFILE on Windows)
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) {
        locations.add(StorageLocation(
          name: 'Home',
          path: userProfile,
          icon: Icons.home_rounded,
        ));

        // Common user folders
        for (final entry in [
          ('Desktop', Icons.desktop_windows_rounded),
          ('Documents', Icons.description_rounded),
          ('Downloads', Icons.download_rounded),
          ('Pictures', Icons.image_rounded),
          ('Music', Icons.music_note_rounded),
          ('Videos', Icons.movie_rounded),
        ]) {
          final dir = Directory(p.join(userProfile, entry.$1));
          if (await dir.exists()) {
            locations.add(StorageLocation(
              name: entry.$1,
              path: dir.path,
              icon: entry.$2,
            ));
          }
        }
      }

      // Detect all available drives (A:\ through Z:\)
      for (int i = 65; i <= 90; i++) {
        final letter = String.fromCharCode(i);
        final drivePath = '$letter:\\';
        final driveDir = Directory(drivePath);
        try {
          if (await driveDir.exists()) {
            locations.add(StorageLocation(
              name: '$letter:',
              path: drivePath,
              icon: letter == 'C'
                  ? Icons.computer_rounded
                  : Icons.storage_rounded,
              isRemovable: letter != 'C',
            ));
          }
        } catch (_) {
          // Drive not accessible — skip
        }
      }
    }

    // Add extra locations (e.g. Geogram profile folder)
    if (widget.extraLocations != null) {
      locations.insertAll(0, widget.extraLocations!);
    }

    if (mounted) {
      setState(() => _storageLocations = locations);
    }
  }

  Future<void> _addLinuxMountPoints(
    List<StorageLocation> locations,
    String basePath,
  ) async {
    final baseDir = Directory(basePath);
    if (!await baseDir.exists()) return;

    try {
      final user = Platform.environment['USER'] ?? '';
      Directory searchDir = baseDir;

      // Check for user-specific subdirectory
      final userDir = Directory('$basePath/$user');
      if (await userDir.exists()) {
        searchDir = userDir;
      }

      await for (final entity in searchDir.list()) {
        if (entity is Directory) {
          final name = p.basename(entity.path);
          // Skip if it looks like a system directory
          if (name.startsWith('.')) continue;

          locations.add(StorageLocation(
            name: name,
            path: entity.path,
            icon: Icons.usb_rounded,
            isRemovable: true,
          ));
        }
      }
    } catch (_) {}
  }

  /// Check if a path is on Android external storage (not app-private folders)
  /// Returns true for paths like /storage/emulated/0/DCIM, /storage/emulated/0/Pictures
  /// Returns false for app-private paths like /storage/emulated/0/Android/data/dev.geogram
  bool _isAndroidExternalStorage(String path) {
    if (!Platform.isAndroid) return false;

    // Check if it's on external storage
    if (!path.startsWith('/storage/')) return false;

    // App's private data folder doesn't need special permissions
    if (path.contains('/Android/data/')) return false;
    if (path.contains('/Android/obb/')) return false;

    return true;
  }

  /// Request media permissions on Android
  /// On Android 13+ (API 33), requests photos, videos, and audio permissions.
  /// On older Android versions, requests storage permission.
  Future<void> _requestAndroidMediaPermissions() async {
    if (!Platform.isAndroid) return;

    // Request all media permissions (Android 13+ uses granular permissions)
    // On older Android, Permission.storage will be used as fallback
    final permissions = [
      Permission.photos,
      Permission.videos,
      Permission.audio,
      Permission.storage, // Fallback for Android 12 and below
    ];

    // Request all permissions that aren't already granted
    for (final permission in permissions) {
      final status = await permission.status;
      if (!status.isGranted && !status.isPermanentlyDenied) {
        await permission.request();
      }
    }
  }

  Future<void> _loadDirectory() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    // Use ProfileStorage when inside the profile folder
    if (_isInsideProfileStorage()) {
      await _loadDirectoryFromStorage();
      return;
    }

    try {
      final dirPath = _currentDirectory.path;

      // Request permissions when accessing Android external storage
      // (not needed for app's private folders)
      if (Platform.isAndroid && _isAndroidExternalStorage(dirPath)) {
        await _requestAndroidMediaPermissions();
      }

      // Try to load from persistent cache first
      if (_cacheInitialized) {
        final cachedDir = await _cacheService.getDirectoryCache(dirPath);
        if (cachedDir != null) {
          // Check if cache is still valid
          final dirStat = await _currentDirectory.stat();
          if (!cachedDir.isStale(dirStat.modified)) {
            // Use cached entries - instant load!
            final items = cachedDir.entries
                .where((e) => _showHidden || !e.name.startsWith('.'))
                .map((e) => e.toFileSystemItem())
                .toList();

            // Populate in-memory folder size cache from persistent cache
            // and trigger background calculation for folders with unknown size
            for (final entry in cachedDir.entries) {
              if (entry.isDirectory && entry.size > 0) {
                _folderSizeCache[entry.path] = entry.size;
              } else if (entry.isDirectory && (_folderSizeCache[entry.path] ?? 0) == 0) {
                _calculateFolderSize(entry.path);
              }
            }

            _sortItems(items);

            if (mounted) {
              setState(() {
                _items = items;
                _isLoading = false;
              });
            }
            return;
          }
        }
      }

      // No valid cache - scan directory
      final items = <FileSystemItem>[];
      final cachedEntries = <CachedFileEntry>[];
      DateTime? dirModified;

      try {
        dirModified = (await _currentDirectory.stat()).modified;
      } catch (_) {}

      await for (final entity in _currentDirectory.list()) {
        final name = p.basename(entity.path);
        final stat = await entity.stat();
        final isDir = entity is Directory;

        int size = stat.size;
        if (isDir) {
          // Check in-memory cache first, then persistent cache
          size = _folderSizeCache[entity.path] ?? 0;
          if (size == 0 && _cacheInitialized) {
            final cachedSize = await _cacheService.getCachedFolderSize(entity.path);
            if (cachedSize != null && cachedSize > 0) {
              size = cachedSize;
              _folderSizeCache[entity.path] = size;
            }
          }
          if (size == 0) {
            // Calculate in background
            _calculateFolderSize(entity.path);
          }
        }

        // Add to cache entries (always, even hidden files)
        cachedEntries.add(CachedFileEntry(
          name: name,
          path: entity.path,
          isDirectory: isDir,
          size: size,
          modified: stat.modified,
        ));

        // Skip hidden files if not showing them (for display only)
        if (!_showHidden && name.startsWith('.')) continue;

        items.add(FileSystemItem(
          path: entity.path,
          name: name,
          isDirectory: isDir,
          size: size,
          modified: stat.modified,
          type: stat.type,
        ));
      }

      // Save to persistent cache in background
      if (_cacheInitialized && dirModified != null) {
        _cacheService.saveDirectoryCache(dirPath, cachedEntries, dirModified);
      }

      _sortItems(items);

      if (mounted) {
        setState(() {
          _items = items;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _items = [];
          _isLoading = false;
          _error = 'Cannot access this folder';
        });
      }
    }
  }

  Future<void> _calculateFolderSize(String folderPath) async {
    // Skip folder size calculation for paths inside profile storage
    if (widget.profileStorage != null) {
      final basePath = widget.profileStorage!.basePath;
      if (folderPath == basePath || p.isWithin(basePath, folderPath)) return;
    }
    if (_calculatingFolders.contains(folderPath)) return;
    _calculatingFolders.add(folderPath);
    if (mounted) setState(() {});

    int totalSize = 0;
    try {
      final dir = Directory(folderPath);
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            totalSize += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}

    _folderSizeCache[folderPath] = totalSize;
    _calculatingFolders.remove(folderPath);

    // Save to persistent cache
    if (_cacheInitialized && totalSize > 0) {
      _cacheService.saveFolderSize(folderPath, totalSize);
    }

    // Update UI if still viewing this directory
    if (mounted && _currentDirectory.path == p.dirname(folderPath)) {
      setState(() {
        final index = _items.indexWhere((item) => item.path == folderPath);
        if (index >= 0) {
          final oldItem = _items[index];
          _items[index] = FileSystemItem(
            path: oldItem.path,
            name: oldItem.name,
            isDirectory: oldItem.isDirectory,
            size: totalSize,
            modified: oldItem.modified,
            type: oldItem.type,
          );
        }
      });
    }
  }

  void _sortItems(List<FileSystemItem> items) {
    items.sort((a, b) {
      // Directories always first
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;

      int result;
      switch (_sortMode) {
        case FileSortMode.name:
          result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case FileSortMode.size:
          result = a.size.compareTo(b.size);
          break;
        case FileSortMode.modified:
          result = a.modified.compareTo(b.modified);
          break;
      }

      return _sortAscending ? result : -result;
    });
  }

  Future<void> _loadVirtualFolder(String virtualPath) async {
    final type = virtualPath.replaceFirst('virtual://', '');

    setState(() {
      _isVirtualFolder = true;
      _virtualFolderType = type;
      _isLoading = true;
      _items = [];
      _selectedPaths.clear();
      _error = null;
    });

    if (type == 'recent') {
      final files = await RecentFilesService().getRecentFiles();
      if (mounted) {
        setState(() {
          _items = files;
          _isLoading = false;
        });
      }
    }
  }

  void _navigateTo(Directory dir) {
    // Exiting virtual folder when navigating to a real directory
    _isVirtualFolder = false;
    _virtualFolderType = null;

    setState(() {
      _currentDirectory = dir;
      _selectedPaths.clear();
    });
    _loadDirectory();
  }

  void _navigateUp() {
    // Exiting virtual folder - go to home directory
    if (_isVirtualFolder) {
      _isVirtualFolder = false;
      _virtualFolderType = null;
      _navigateTo(Directory(_baseDirectory));
      return;
    }

    // Don't navigate above rootPath
    if (widget.rootPath != null &&
        _currentDirectory.path == widget.rootPath) {
      return;
    }

    final parent = _currentDirectory.parent;
    if (parent.path != _currentDirectory.path) {
      _navigateTo(parent);
    }
  }

  bool _isFileAllowed(FileSystemItem item) {
    if (item.isDirectory) return true;
    if (widget.allowedExtensions == null) return true;
    final ext = p.extension(item.name).replaceFirst('.', '').toLowerCase();
    return widget.allowedExtensions!.contains(ext);
  }

  void _toggleSelection(FileSystemItem item) {
    if (!_isFileAllowed(item)) return;
    setState(() {
      if (_selectedPaths.contains(item.path)) {
        _selectedPaths.remove(item.path);
      } else {
        if (!widget.allowMultiSelect) {
          _selectedPaths.clear();
        }
        _selectedPaths.add(item.path);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedPaths.addAll(
        _items.where(_isFileAllowed).map((e) => e.path),
      );
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedPaths.clear();
    });
  }

  /// Reload the current directory listing.
  void refresh() => _loadDirectory();

  /// Programmatically select a single file by its absolute path,
  /// highlighting it in the tree view.
  void selectFile(String path) {
    setState(() {
      _selectedPaths
        ..clear()
        ..add(path);
    });
  }

  void _confirm() {
    Navigator.of(context).pop(_selectedPaths.toList());
  }

  void _cancel() {
    Navigator.of(context).pop(null);
  }

  void _changeSortMode(FileSortMode mode) {
    setState(() {
      if (_sortMode == mode) {
        _sortAscending = !_sortAscending;
      } else {
        _sortMode = mode;
        _sortAscending = mode == FileSortMode.name;
      }
      _sortItems(_items);
    });
  }

  bool _isImageFile(String name) {
    final ext = name.split('.').last.toLowerCase();
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext);
  }

  bool _isVideoFile(String name) {
    final ext = name.split('.').last.toLowerCase();
    return ext == 'mp4';  // Only mp4 for now, as it's most reliable
  }

  Future<void> _loadThumbnail(FileSystemItem item) async {
    if (_thumbnailCache.containsKey(item.path)) return;
    if (_loadingThumbnails.contains(item.path)) return;

    _loadingThumbnails.add(item.path);

    if (_isImageFile(item.name)) {
      // Images use the file directly as thumbnail
      _thumbnailCache[item.path] = item.path;
      // Defer setState to avoid calling it during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else if (_isVideoFile(item.name)) {
      // Check persistent cache first
      if (_cacheInitialized) {
        final hasCached = await _cacheService.hasThumbnail(item.path, item.modified);
        if (hasCached) {
          final cachedPath = await _cacheService.getThumbnailTempPath(item.path);
          if (cachedPath != null) {
            _thumbnailCache[item.path] = cachedPath;
            _loadingThumbnails.remove(item.path);
            if (mounted) setState(() {});
            return;
          }
        }
      }

      // Generate video thumbnail
      final tempDir = Directory.systemTemp;
      final outputPath = '${tempDir.path}/thumb_${item.name.hashCode}.png';

      final thumbPath = await VideoMetadataExtractor.generateThumbnail(
        item.path,
        outputPath,
        atSeconds: 1,
      );

      _thumbnailCache[item.path] = thumbPath;

      // Save to persistent cache
      if (_cacheInitialized && thumbPath != null) {
        try {
          final thumbFile = File(thumbPath);
          if (await thumbFile.exists()) {
            final bytes = await thumbFile.readAsBytes();
            await _cacheService.saveThumbnail(
              item.path,
              Uint8List.fromList(bytes),
              item.modified,
              extension: 'png',
            );
          }
        } catch (_) {
          // Ignore thumbnail cache errors
        }
      }

      if (mounted) setState(() {});
    }

    _loadingThumbnails.remove(item.path);
  }

  Widget _buildItemThumbnail(FileSystemItem item, ThemeData theme, {double size = 44}) {
    final iconColor = _getIconColor(item);
    final iconData = _getItemIcon(item);

    // Check if we have a thumbnail
    if (_isImageFile(item.name) || _isVideoFile(item.name)) {
      _loadThumbnail(item);  // Trigger load if needed

      final thumbPath = _thumbnailCache[item.path];
      if (thumbPath != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(thumbPath),
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildIconBox(iconData, iconColor, size),
          ),
        );
      }

      // Loading state
      if (_loadingThumbnails.contains(item.path)) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      }
    }

    return _buildIconBox(iconData, iconColor, size);
  }

  Widget _buildIconBox(IconData icon, Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(child: Icon(icon, color: color, size: size * 0.55)),
    );
  }

  Widget _buildSizeDisplay(ThemeData theme, FileSystemItem item) {
    if (item.isDirectory && _calculatingFolders.contains(item.path)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'calculating...',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
    }

    return Text(
      _formatBytes(item.size),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// Show a dialog to create a new folder in the current directory.
  Future<void> _createNewFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Folder name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (name == null || name.trim().isEmpty) return;
    final trimmed = name.trim();

    // Validate name
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Folder name cannot contain / or \\')),
        );
      }
      return;
    }
    if (trimmed == '.' || trimmed == '..') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid folder name')),
        );
      }
      return;
    }

    try {
      if (_isInsideProfileStorage()) {
        final storage = widget.profileStorage!;
        final basePath = storage.basePath;
        final parentRelative = _currentDirectory.path == basePath
            ? ''
            : p.relative(_currentDirectory.path, from: basePath);
        final newDirRelative = parentRelative.isEmpty
            ? trimmed
            : '$parentRelative/$trimmed';

        if (await storage.directoryExists(newDirRelative)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Folder already exists')),
            );
          }
          return;
        }
        await storage.createDirectory(newDirRelative);
        _scheduleSyncForProfilePath(newDirRelative, 'folder created');
      } else {
        final newDir = Directory(p.join(_currentDirectory.path, trimmed));
        if (await newDir.exists()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Folder already exists')),
            );
          }
          return;
        }
        await newDir.create();
      }
      _loadDirectory();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create folder: $e')),
        );
      }
    }
  }

  /// Returns the action widgets (view toggle, hidden files, sort) so a parent
  /// AppBar can include them directly. Used in explorer mode.
  List<Widget> buildActions() {
    final colorScheme = Theme.of(context).colorScheme;
    return [
      IconButton(
        icon: const Icon(Icons.create_new_folder_outlined),
        tooltip: 'New folder',
        onPressed: _isVirtualFolder ? null : _createNewFolder,
      ),
      IconButton(
        icon: Icon(_isGridView ? Icons.view_list_rounded : Icons.grid_view_rounded),
        tooltip: _isGridView ? 'List view' : 'Grid view',
        onPressed: () {
          setState(() => _isGridView = !_isGridView);
          widget.onStateChanged?.call();
        },
      ),
      IconButton(
        icon: Icon(
          _showHidden ? Icons.visibility_rounded : Icons.visibility_off_rounded,
          color: _showHidden ? colorScheme.primary : null,
        ),
        tooltip: _showHidden ? 'Hide hidden files' : 'Show hidden files',
        onPressed: () {
          setState(() => _showHidden = !_showHidden);
          _loadDirectory();
          widget.onStateChanged?.call();
        },
      ),
      PopupMenuButton<FileSortMode>(
        icon: const Icon(Icons.sort_rounded),
        tooltip: 'Sort',
        position: PopupMenuPosition.under,
        onSelected: (mode) {
          _changeSortMode(mode);
          widget.onStateChanged?.call();
        },
        itemBuilder: (context) => [
          _buildSortMenuItem(FileSortMode.name, 'Name', Icons.sort_by_alpha_rounded),
          _buildSortMenuItem(FileSortMode.size, 'Size', Icons.data_usage_rounded),
          _buildSortMenuItem(FileSortMode.modified, 'Date modified', Icons.schedule_rounded),
        ],
      ),
      const SizedBox(width: 4),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: !_isVirtualFolder && _currentDirectory.path == _baseDirectory,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _canNavigateUp) {
          _navigateUp();
        }
      },
      child: Focus(
        focusNode: _keyboardFocusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.backspace) {
              _navigateUp();
              return KeyEventResult.handled;
            }
            final isCtrl = HardwareKeyboard.instance.isControlPressed;
            if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyV) {
              _pasteFromSystemClipboard();
              return KeyEventResult.handled;
            }
            if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyC &&
                _selectedPaths.isNotEmpty) {
              final selected = _items
                  .where((i) => _selectedPaths.contains(i.path))
                  .toList();
              if (selected.isNotEmpty) {
                setState(() {
                  _clipboardItems
                    ..clear()
                    ..addAll(selected);
                });
                _copyToSystemClipboard(selected);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(selected.length == 1
                        ? '${selected.first.name} copied'
                        : '${selected.length} items copied'),
                  ),
                );
              }
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: widget.explorerMode ? null : AppBar(
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _cancel,
          tooltip: 'Cancel',
        ),
        title: Text(
          widget.title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: buildActions(),
      ),
      body: Column(
        children: [
          // Storage locations
          if (widget.showStorageBar && _storageLocations.isNotEmpty) _buildStorageBar(theme),

          // Navigation bar
          _buildNavigationBar(theme),

          // Divider
          Divider(height: 1, color: colorScheme.outlineVariant),

          // File list
          Expanded(
            child: DropTarget(
              onDragDone: _onDropDone,
              onDragEntered: (_) => setState(() => _isDragOver = true),
              onDragExited: (_) => setState(() => _isDragOver = false),
              enable: !_isImporting,
              child: Stack(
                children: [
                  _isLoading
                      ? _buildLoadingState(theme)
                      : _error != null
                          ? _buildErrorState(theme)
                          : _items.isEmpty
                              ? _buildEmptyState(theme)
                              : _isGridView
                                  ? _buildGridView(theme)
                                  : _buildListView(theme),
                  if (_isDragOver) _buildDropOverlay(theme),
                  if (_isImporting) _buildImportProgressOverlay(theme),
                ],
              ),
            ),
          ),

          // Status bar
          if (!_isLoading && _error == null) _buildStatusBar(theme),

          // Selection bar (hidden in explorer mode)
          if (!widget.explorerMode) _buildSelectionBar(theme),
        ],
      ),
      ),
    ),
    );
  }

  PopupMenuItem<FileSortMode> _buildSortMenuItem(
    FileSortMode mode,
    String label,
    IconData icon,
  ) {
    final isSelected = _sortMode == mode;
    final theme = Theme.of(context);

    return PopupMenuItem(
      value: mode,
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: isSelected ? theme.colorScheme.primary : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.w600 : null,
                color: isSelected ? theme.colorScheme.primary : null,
              ),
            ),
          ),
          if (isSelected)
            Icon(
              _sortAscending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              size: 18,
              color: theme.colorScheme.primary,
            ),
        ],
      ),
    );
  }

  Widget _buildStorageBar(ThemeData theme) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _storageLocations.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final location = _storageLocations[index];
          final isCurrentRoot = index == _bestStorageMatch;

          return Material(
            color: isCurrentRoot
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              onTap: () {
                if (location.isVirtual) {
                  _loadVirtualFolder(location.path);
                } else {
                  _isVirtualFolder = false;
                  _virtualFolderType = null;
                  _baseDirectory = location.path;
                  _navigateTo(Directory(location.path));
                }
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      location.icon,
                      size: 20,
                      color: location.isRemovable
                          ? Colors.orange
                          : isCurrentRoot
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      location.name,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: isCurrentRoot
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: isCurrentRoot ? FontWeight.w600 : null,
                      ),
                    ),
                    if (widget.profileStorage?.isEncrypted == true &&
                        location.path == widget.profileStorage!.basePath) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.lock_rounded,
                        size: 14,
                        color: isCurrentRoot
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildNavigationBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // Breadcrumb path
          Expanded(
            child: _buildBreadcrumb(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumb(ThemeData theme) {
    // Special breadcrumb for virtual folders
    if (_isVirtualFolder) {
      final name = _virtualFolderType == 'recent' ? 'Recent' : _virtualFolderType ?? 'Virtual';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          name,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.primary,
          ),
        ),
      );
    }

    var parts = _currentDirectory.path.split(Platform.pathSeparator);
    if (parts.first.isEmpty) parts[0] = '/';

    // When rootPath is set, only show segments at or below the root.
    int startIndex = 0;
    if (widget.rootPath != null) {
      final rootParts = widget.rootPath!.split(Platform.pathSeparator);
      if (rootParts.first.isEmpty) rootParts[0] = '/';
      startIndex = rootParts.length.clamp(0, parts.length);
    }

    // Auto-scroll to show the last (deepest) folder
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_breadcrumbScrollController.hasClients) {
        _breadcrumbScrollController.jumpTo(
          _breadcrumbScrollController.position.maxScrollExtent,
        );
      }
    });

    return SingleChildScrollView(
      controller: _breadcrumbScrollController,
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = startIndex; i < parts.length; i++) ...[
            if (i > startIndex)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                onTap: () {
                  String path;
                  if (i == 0 && parts[0] == '/') {
                    path = '/';
                  } else {
                    final subParts = parts.sublist(0, i + 1);
                    if (subParts.first == '/') {
                      path = '/${subParts.skip(1).join(Platform.pathSeparator)}';
                    } else {
                      path = subParts.join(Platform.pathSeparator);
                    }
                  }
                  // On Windows, bare drive letter 'C:' must become 'C:\'
                  if (Platform.isWindows && path.length == 2 && path.endsWith(':')) {
                    path = '$path\\';
                  }
                  _navigateTo(Directory(path));
                },
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    parts[i],
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: i == parts.length - 1
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: i == parts.length - 1 ? FontWeight.w600 : null,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLoadingState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Loading...',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  bool get _canNavigateUp {
    // Virtual folders can navigate "up" to exit back to home
    if (_isVirtualFolder) {
      return true;
    }
    // At filesystem root
    if (_currentDirectory.parent.path == _currentDirectory.path) {
      return false;
    }
    // At rootPath boundary - don't navigate above it
    if (widget.rootPath != null &&
        _currentDirectory.path == widget.rootPath) {
      return false;
    }
    // At starting folder - don't navigate above it
    if (_currentDirectory.path == _baseDirectory) {
      return false;
    }
    return true;
  }

  Widget _buildParentDirListItem(ThemeData theme, {bool isDropTarget = false}) {
    return Material(
      color: isDropTarget
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: _navigateUp,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _buildIconBox(Icons.folder_rounded, Colors.amber.shade700, 44),
              const SizedBox(width: 12),
              Text(
                '..',
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildParentDirGridItem(ThemeData theme, {bool isDropTarget = false}) {
    return Container(
      decoration: isDropTarget
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary,
                width: 2,
              ),
            )
          : null,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: _navigateUp,
          borderRadius: BorderRadius.circular(12),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildIconBox(Icons.folder_rounded, Colors.amber.shade700, 48),
                  const SizedBox(height: 6),
                  Text(
                    '..',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDragFeedback(FileSystemItem item, ThemeData theme) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_getItemIcon(item), size: 20, color: _getIconColor(item)),
            const SizedBox(width: 8),
            Text(item.name, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  bool get _canDragItems =>
      !_isVirtualFolder && !_isImporting;

  Widget _wrapWithDrag(Widget child, FileSystemItem item, ThemeData theme) {
    if (!_canDragItems) return child;
    // In non-explorer mode, disable dragging so long-press selection works
    if (!widget.explorerMode) return child;
    final feedback = _buildDragFeedback(item, theme);
    if (Platform.isAndroid) {
      return LongPressDraggable<FileSystemItem>(
        data: item,
        feedback: feedback,
        childWhenDragging: Opacity(opacity: 0.5, child: child),
        child: child,
      );
    }
    return Draggable<FileSystemItem>(
      data: item,
      feedback: feedback,
      childWhenDragging: Opacity(opacity: 0.5, child: child),
      child: child,
    );
  }

  Widget _wrapWithDropTarget(Widget child, String targetPath) {
    if (!_canDragItems) return child;
    return DragTarget<FileSystemItem>(
      onWillAcceptWithDetails: (details) {
        final item = details.data;
        // Don't accept drop on self
        if (item.path == targetPath) return false;
        // Don't accept drop into own subtree
        if (item.isDirectory && p.isWithin(item.path, targetPath)) return false;
        return true;
      },
      onAcceptWithDetails: (details) {
        setState(() => _dragTargetPath = null);
        _moveItemToFolder(details.data, targetPath);
      },
      onMove: (_) {
        if (_dragTargetPath != targetPath) {
          setState(() => _dragTargetPath = targetPath);
        }
      },
      onLeave: (_) {
        if (_dragTargetPath == targetPath) {
          setState(() => _dragTargetPath = null);
        }
      },
      builder: (context, candidateData, rejectedData) => child,
    );
  }

  Widget _buildListView(ThemeData theme) {
    final hasParent = _canNavigateUp;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _items.length + (hasParent ? 1 : 0),
      itemBuilder: (context, index) {
        if (hasParent && index == 0) {
          final parentWidget = _buildParentDirListItem(theme,
            isDropTarget: _dragTargetPath == _currentDirectory.parent.path,
          );
          return _wrapWithDropTarget(parentWidget, _currentDirectory.parent.path);
        }
        final item = _items[hasParent ? index - 1 : index];
        Widget itemWidget = _buildListItem(item, theme,
          isDropTarget: item.isDirectory && _dragTargetPath == item.path,
        );
        if (!_isFileAllowed(item)) {
          itemWidget = Opacity(opacity: 0.4, child: itemWidget);
        }
        itemWidget = _wrapWithDrag(itemWidget, item, theme);
        if (item.isDirectory) {
          itemWidget = _wrapWithDropTarget(itemWidget, item.path);
        }
        return itemWidget;
      },
    );
  }

  Widget _buildGridView(ThemeData theme) {
    final hasParent = _canNavigateUp;
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 120,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.85,
      ),
      itemCount: _items.length + (hasParent ? 1 : 0),
      itemBuilder: (context, index) {
        if (hasParent && index == 0) {
          final parentWidget = _buildParentDirGridItem(theme,
            isDropTarget: _dragTargetPath == _currentDirectory.parent.path,
          );
          return _wrapWithDropTarget(parentWidget, _currentDirectory.parent.path);
        }
        final item = _items[hasParent ? index - 1 : index];
        Widget itemWidget = _buildGridItem(item, theme,
          isDropTarget: item.isDirectory && _dragTargetPath == item.path,
        );
        if (!_isFileAllowed(item)) {
          itemWidget = Opacity(opacity: 0.4, child: itemWidget);
        }
        itemWidget = _wrapWithDrag(itemWidget, item, theme);
        if (item.isDirectory) {
          itemWidget = _wrapWithDropTarget(itemWidget, item.path);
        }
        return itemWidget;
      },
    );
  }

  Widget _buildListItem(FileSystemItem item, ThemeData theme, {bool isDropTarget = false}) {
    final isSelected = _selectedPaths.contains(item.path);
    final isExplorer = widget.explorerMode;

    return Material(
      color: isDropTarget
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : isSelected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
              : Colors.transparent,
      child: InkWell(
        onTap: () {
          if (item.isDirectory) {
            _navigateTo(Directory(item.path));
          } else if (isExplorer && widget.onFileOpen != null) {
            widget.onFileOpen!(item.path);
          } else {
            _toggleSelection(item);
          }
        },
        onLongPress: isExplorer ? null : () => _toggleSelection(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              // Checkbox/Radio (hidden in explorer mode)
              if (!isExplorer && widget.allowMultiSelect)
                Checkbox(
                  value: isSelected,
                  onChanged: (_) => _toggleSelection(item),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                )
              else if (!isExplorer)
                Radio<bool>(
                  value: true,
                  groupValue: isSelected,
                  onChanged: (_) => _toggleSelection(item),
                ),
              if (!isExplorer) const SizedBox(width: 8),
              // Icon - use thumbnail method
              _buildItemThumbnail(item, theme, size: 44),
              const SizedBox(width: 12),
              // Name and details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        _buildSizeDisplay(theme, item),
                        const SizedBox(width: 8),
                        Flexible(
                          child: _buildDetailChip(
                            theme,
                            _formatDate(item.modified),
                            true,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Actions menu
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 20,
                  icon: Icon(
                    Icons.more_vert_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () => _showItemActions(context, item),
                  tooltip: 'Actions',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailChip(ThemeData theme, String text, bool show) {
    if (!show) return const SizedBox();
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildGridItem(FileSystemItem item, ThemeData theme, {bool isDropTarget = false}) {
    final isSelected = _selectedPaths.contains(item.path);
    final hasThumbnail = _isImageFile(item.name) || _isVideoFile(item.name);
    final isExplorer = widget.explorerMode;

    void onItemTap() {
      if (item.isDirectory) {
        _navigateTo(Directory(item.path));
      } else if (isExplorer && widget.onFileOpen != null) {
        widget.onFileOpen!(item.path);
      } else {
        _toggleSelection(item);
      }
    }

    // For images/videos: full-bleed thumbnail with overlay filename
    if (hasThumbnail) {
      _loadThumbnail(item);  // Trigger load if needed
      final thumbPath = _thumbnailCache[item.path];

      return Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onItemTap,
          onLongPress: isExplorer ? null : () => _toggleSelection(item),
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Full-bleed thumbnail
              if (thumbPath != null)
                Image.file(
                  File(thumbPath),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildGridIconFallback(item, theme),
                )
              else if (_loadingThumbnails.contains(item.path))
                Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else
                _buildGridIconFallback(item, theme),

              // Selection overlay
              if (isSelected)
                Container(
                  color: theme.colorScheme.primary.withValues(alpha: 0.3),
                ),

              // Filename overlay at bottom
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.7),
                      ],
                    ),
                  ),
                  child: Text(
                    item.name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      shadows: [
                        const Shadow(
                          color: Colors.black54,
                          blurRadius: 2,
                        ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),

              // Selection indicator
              if (isSelected)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                ),

              // Actions menu
              if (!isSelected)
                Positioned(
                  top: 2,
                  right: 2,
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      icon: Icon(
                        Icons.more_vert_rounded,
                        color: Colors.white,
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 4),
                        ],
                      ),
                      onPressed: () => _showItemActions(context, item),
                      tooltip: 'Actions',
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // For folders and other files: keep the centered icon layout
    return Container(
      decoration: isDropTarget
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary,
                width: 2,
              ),
            )
          : null,
      child: Material(
        color: isSelected
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onItemTap,
          onLongPress: isExplorer ? null : () => _toggleSelection(item),
          borderRadius: BorderRadius.circular(12),
          child: Stack(
          children: [
            // Content centered
            Center(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Icon
                    _buildIconBox(_getItemIcon(item), _getIconColor(item), 48),
                    const SizedBox(height: 6),
                    // Name
                    Text(
                      item.name,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            // Selection indicator
            if (isSelected)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: theme.colorScheme.onPrimary,
                  ),
                ),
              ),

            // Actions menu
            if (!isSelected)
              Positioned(
                top: 2,
                right: 2,
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    icon: Icon(
                      Icons.more_vert_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onPressed: () => _showItemActions(context, item),
                    tooltip: 'Actions',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGridIconFallback(FileSystemItem item, ThemeData theme) {
    return Container(
      color: _getIconColor(item).withValues(alpha: 0.15),
      child: Center(
        child: Icon(
          _getItemIcon(item),
          color: _getIconColor(item),
          size: 40,
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    final isRecent = _isVirtualFolder && _virtualFolderType == 'recent';
    return Column(
      children: [
        if (_canNavigateUp) _buildParentDirListItem(theme),
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    isRecent ? Icons.history_rounded : Icons.folder_open_rounded,
                    size: 40,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  isRecent ? 'No recent files' : 'This folder is empty',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.lock_rounded,
                size: 40,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _error ?? 'Unknown error',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _navigateUp,
              icon: const Icon(Icons.arrow_upward_rounded),
              label: const Text('Go back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar(ThemeData theme) {
    if (_clipboardItems.isNotEmpty) {
      final label = _clipboardItems.length == 1
          ? _clipboardItems.first.name
          : '${_clipboardItems.length} items copied';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer,
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: Row(
          children: [
            Icon(Icons.content_paste_rounded, size: 18, color: theme.colorScheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _clipboardItems.clear()),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: _pasteItems,
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              label: const Text('Paste here'),
            ),
          ],
        ),
      );
    }

    final files = _items.where((item) => !item.isDirectory);
    final fileCount = files.length;
    final totalSize = files.fold<int>(0, (sum, item) => sum + item.size);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Text(
            '$fileCount ${fileCount == 1 ? 'file' : 'files'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (totalSize > 0) ...[
            const SizedBox(width: 16),
            Text(
              _formatBytes(totalSize),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSelectionBar(ThemeData theme) {
    final hasSelection = _selectedPaths.isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            // Selection count and actions
            Expanded(
              child: Row(
                children: [
                  if (hasSelection) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_selectedPaths.length} selected',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _deselectAll,
                      child: const Text('Clear'),
                    ),
                  ] else ...[
                    if (widget.allowMultiSelect && _items.isNotEmpty)
                      TextButton(
                        onPressed: _selectAll,
                        child: const Text('Select all'),
                      ),
                  ],
                ],
              ),
            ),
            // Cancel button
            OutlinedButton(
              onPressed: _cancel,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 12),
            // Confirm button
            FilledButton.icon(
              onPressed: hasSelection ? _confirm : null,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _showItemActions(BuildContext context, FileSystemItem item) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  _buildIconBox(_getItemIcon(item), _getIconColor(item), 36),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(ctx);
                _renameItem(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_copy_rounded),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(ctx);
                _copyItem(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy path'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: item.path));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Path copied to clipboard')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_rounded),
              title: const Text('Share...'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TransferSendPage(
                      initialPaths: [item.path],
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_rounded, color: theme.colorScheme.error),
              title: Text('Delete', style: TextStyle(color: theme.colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteItem(item);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _renameItem(FileSystemItem item) {
    final controller = TextEditingController(text: item.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'New name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) {
            Navigator.pop(ctx);
            _performRename(item, controller.text.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _performRename(item, controller.text.trim());
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  Future<void> _performRename(FileSystemItem item, String newName) async {
    if (newName.isEmpty || newName == item.name) return;
    final dir = p.dirname(item.path);
    final newPath = p.join(dir, newName);
    try {
      if (_isInsideProfileStorage()) {
        final storage = widget.profileStorage!;
        final oldRelative = _profileRelativePath(item.path);
        final parentRelative = _profileRelativePath(dir) ?? '';
        final newRelative = parentRelative.isEmpty
            ? newName
            : '$parentRelative/$newName';
        if (oldRelative == null) return;
        final exists = item.isDirectory
            ? await storage.directoryExists(newRelative)
            : await storage.exists(newRelative);
        if (exists) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('A file with this name already exists')),
            );
          }
          return;
        }
        if (item.isDirectory) {
          await _moveDirectoryInStorage(storage, oldRelative, newRelative);
        } else {
          final bytes = await storage.readBytes(oldRelative);
          if (bytes != null) {
            await storage.writeBytes(newRelative, bytes);
          }
          await _archiveAndTombstoneStorageFile(oldRelative);
          await storage.delete(oldRelative);
        }
        _scheduleSyncForProfilePath(newRelative, 'item renamed');
      } else if (item.isDirectory) {
        await Directory(item.path).rename(newPath);
      } else {
        await File(item.path).rename(newPath);
      }
      _loadDirectory();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rename failed: $e')),
        );
      }
    }
  }

  void _copyItem(FileSystemItem item) {
    setState(() {
      _clipboardItems
        ..clear()
        ..add(item);
    });
    _copyToSystemClipboard([item]);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${item.name} ready to paste')),
    );
  }

  static const _fileLauncherChannel = MethodChannel('dev.geogram/file_launcher');

  /// Copy file paths to the system clipboard so they can be pasted in
  /// external apps (Telegram, file managers, etc.).
  Future<void> _copyToSystemClipboard(List<FileSystemItem> items) async {
    if (Platform.isAndroid) {
      try {
        await _fileLauncherChannel.invokeMethod('copyToClipboard', {
          'paths': items.map((i) => i.path).toList(),
        });
      } catch (_) {
        // Method channel not available — ignore silently
      }
    } else if (Platform.isLinux) {
      final uris = items.map((i) => Uri.file(i.path).toString()).join('\n');
      final payload = 'copy\n$uris';
      try {
        final process = await Process.start(
          'xclip',
          ['-selection', 'clipboard', '-t', 'x-special/gnome-copied-files'],
        );
        process.stdin.write(payload);
        await process.stdin.close();
        await process.exitCode;
      } catch (_) {
        // xclip not available — ignore silently
      }
    } else if (Platform.isWindows) {
      final paths = items.map((i) => i.path).toList();
      final script = StringBuffer()
        ..writeln('Add-Type -AssemblyName System.Windows.Forms')
        ..writeln('\$col = New-Object System.Collections.Specialized.StringCollection');
      for (final path in paths) {
        script.writeln('\$col.Add("${path.replaceAll('"', '`"')}")');
      }
      script.writeln('[System.Windows.Forms.Clipboard]::SetFileDropList(\$col)');
      try {
        await Process.run('powershell', ['-NoProfile', '-Command', script.toString()]);
      } catch (_) {
        // PowerShell not available — ignore silently
      }
    }
  }

  Future<String> _resolveDestPath(String dir, String name, bool isDirectory) async {
    var destPath = p.join(dir, name);
    if (isDirectory ? !await Directory(destPath).exists() : !await File(destPath).exists()) {
      return destPath;
    }
    final ext = isDirectory ? '' : p.extension(name);
    final base = isDirectory ? name : p.basenameWithoutExtension(name);
    var counter = 1;
    do {
      final suffix = counter == 1 ? ' (copy)' : ' (copy $counter)';
      destPath = p.join(dir, '$base$suffix$ext');
      counter++;
    } while (isDirectory ? await Directory(destPath).exists() : await File(destPath).exists());
    return destPath;
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final entity in source.list()) {
      final newPath = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
  }

  Future<void> _pasteItems() async {
    if (_isInsideProfileStorage()) {
      // Use ProfileStorage-aware import for items pasted into encrypted storage
      final paths = _clipboardItems.map((i) => i.path).toList();
      setState(() => _clipboardItems.clear());
      await _importExternalPaths(paths);
      return;
    }
    for (final item in _clipboardItems) {
      final destPath = await _resolveDestPath(
        _currentDirectory.path,
        item.name,
        item.isDirectory,
      );
      try {
        if (item.isDirectory) {
          await _copyDirectory(Directory(item.path), Directory(destPath));
        } else {
          await File(item.path).copy(destPath);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Paste failed: $e')),
          );
        }
        return;
      }
    }
    setState(() => _clipboardItems.clear());
    _scheduleSyncForProfilePath(
      _profileRelativePath(_currentDirectory.path),
      'items pasted',
    );
    _loadDirectory();
  }

  // ============ Internal Drag & Drop Move ============

  Future<void> _moveItemToFolder(FileSystemItem item, String targetDir) async {
    // Reject if already in that folder
    if (p.dirname(item.path) == targetDir) return;

    // Reject moving a directory into its own subtree
    if (item.isDirectory && p.isWithin(item.path, targetDir)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot move a folder into itself')),
        );
      }
      return;
    }

    final name = item.name;
    final destPath = p.join(targetDir, name);

    try {
      if (_isInsideProfileStorage()) {
        await _moveItemInStorage(item, targetDir);
      } else {
        // Check for name conflict
        final exists = item.isDirectory
            ? await Directory(destPath).exists()
            : await File(destPath).exists();
        if (exists) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('A file with this name already exists')),
            );
          }
          return;
        }
        // Atomic rename (move) on same filesystem
        if (item.isDirectory) {
          await Directory(item.path).rename(destPath);
        } else {
          await File(item.path).rename(destPath);
        }
      }
      _selectedPaths.remove(item.path);
      _loadDirectory();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Move failed: $e')),
        );
      }
    }
  }

  Future<void> _moveItemInStorage(FileSystemItem item, String targetDir) async {
    final storage = widget.profileStorage!;
    final basePath = storage.basePath;

    final srcRelative = p.relative(item.path, from: basePath);
    final targetRelativeDir = targetDir == basePath
        ? ''
        : p.relative(targetDir, from: basePath);
    final destRelative = targetRelativeDir.isEmpty
        ? item.name
        : '$targetRelativeDir/${item.name}';

    // Check for name conflict
    final exists = item.isDirectory
        ? await storage.directoryExists(destRelative)
        : await storage.exists(destRelative);
    if (exists) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A file with this name already exists')),
        );
      }
      return;
    }

    if (item.isDirectory) {
      await _moveDirectoryInStorage(storage, srcRelative, destRelative);
    } else {
      final bytes = await storage.readBytes(srcRelative);
      if (bytes != null) {
        await storage.writeBytes(destRelative, bytes);
      }
      await _archiveAndTombstoneStorageFile(srcRelative);
      await storage.delete(srcRelative);
    }
    _scheduleSyncForProfilePath(destRelative, 'item moved');
  }

  Future<void> _moveDirectoryInStorage(
    ProfileStorage storage,
    String srcRelative,
    String destRelative,
  ) async {
    await storage.createDirectory(destRelative);
    final entries = await storage.listDirectory(srcRelative);
    for (final entry in entries) {
      final childName = p.basename(entry.path);
      final childSrc = srcRelative.isEmpty
          ? childName
          : '$srcRelative/$childName';
      final childDest = destRelative.isEmpty
          ? childName
          : '$destRelative/$childName';
      if (entry.isDirectory) {
        await _moveDirectoryInStorage(storage, childSrc, childDest);
      } else {
        final bytes = await storage.readBytes(childSrc);
        if (bytes != null) {
          await storage.writeBytes(childDest, bytes);
        }
        await _archiveAndTombstoneStorageFile(childSrc);
        await storage.delete(childSrc);
      }
    }
    await storage.deleteDirectory(srcRelative);
  }

  // ============ OS Drag & Drop ============

  void _onDropDone(DropDoneDetails details) {
    if (_isVirtualFolder) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot import files to a virtual folder')),
      );
      return;
    }
    final paths = details.files
        .map((f) => f.path)
        .where((path) => path.isNotEmpty)
        .toList();
    if (paths.isEmpty) return;
    _importExternalPaths(paths);
  }

  Future<void> _importExternalPaths(List<String> externalPaths) async {
    if (externalPaths.isEmpty) return;

    setState(() {
      _isImporting = true;
      _importTotal = externalPaths.length;
      _importProgress = 0;
      _importCurrentFile = null;
    });

    int successes = 0;
    int failures = 0;

    for (final externalPath in externalPaths) {
      final name = p.basename(externalPath);
      setState(() {
        _importProgress++;
        _importCurrentFile = name;
      });

      try {
        if (_isInsideProfileStorage()) {
          await _importToProfileStorage(externalPath, name);
        } else {
          await _importToFilesystem(externalPath, name);
        }
        successes++;
      } catch (e) {
        failures++;
      }
    }

    setState(() {
      _isImporting = false;
      _importCurrentFile = null;
    });

    if (mounted) {
      final msg = failures == 0
          ? 'Imported $successes ${successes == 1 ? 'item' : 'items'}'
          : 'Imported $successes, failed $failures';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }

    _scheduleSyncForProfilePath(
      _profileRelativePath(_currentDirectory.path),
      'items imported',
    );
    _loadDirectory();
  }

  Future<void> _importToProfileStorage(String externalPath, String name) async {
    final storage = widget.profileStorage!;
    final basePath = storage.basePath;
    final dirPath = _currentDirectory.path;
    final parentRelative = dirPath == basePath
        ? ''
        : p.relative(dirPath, from: basePath);

    final entityType = await FileSystemEntity.type(externalPath);
    final isDirectory = entityType == FileSystemEntityType.directory;
    final destRelative = await _resolveDestPathInStorage(
      storage, parentRelative, name, isDirectory,
    );

    if (isDirectory) {
      await _importDirectoryToStorage(storage, externalPath, destRelative);
    } else {
      await storage.copyFromExternal(externalPath, destRelative);
    }
  }

  Future<void> _importDirectoryToStorage(
    ProfileStorage storage,
    String externalDirPath,
    String storageRelative,
  ) async {
    await storage.createDirectory(storageRelative);
    final dir = Directory(externalDirPath);
    await for (final entity in dir.list()) {
      final childName = p.basename(entity.path);
      final childRelative = storageRelative.isEmpty
          ? childName
          : '$storageRelative/$childName';
      if (entity is Directory) {
        await _importDirectoryToStorage(storage, entity.path, childRelative);
      } else if (entity is File) {
        await storage.copyFromExternal(entity.path, childRelative);
      }
    }
  }

  Future<void> _importToFilesystem(String externalPath, String name) async {
    final entityType = await FileSystemEntity.type(externalPath);
    final isDirectory = entityType == FileSystemEntityType.directory;
    final destPath = await _resolveDestPath(
      _currentDirectory.path, name, isDirectory,
    );
    if (isDirectory) {
      await _copyDirectory(Directory(externalPath), Directory(destPath));
    } else {
      await File(externalPath).copy(destPath);
    }
  }

  Future<String> _resolveDestPathInStorage(
    ProfileStorage storage,
    String parentRelative,
    String name,
    bool isDirectory,
  ) async {
    var destRelative = parentRelative.isEmpty ? name : '$parentRelative/$name';
    final existsCheck = isDirectory
        ? await storage.directoryExists(destRelative)
        : await storage.exists(destRelative);
    if (!existsCheck) return destRelative;

    final ext = isDirectory ? '' : p.extension(name);
    final base = isDirectory ? name : p.basenameWithoutExtension(name);
    var counter = 1;
    do {
      final suffix = counter == 1 ? ' (copy)' : ' (copy $counter)';
      destRelative = parentRelative.isEmpty
          ? '$base$suffix$ext'
          : '$parentRelative/$base$suffix$ext';
      counter++;
    } while (isDirectory
        ? await storage.directoryExists(destRelative)
        : await storage.exists(destRelative));
    return destRelative;
  }

  // ============ System Clipboard File Read ============

  Future<void> _pasteFromSystemClipboard() async {
    if (_isVirtualFolder) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot import files to a virtual folder')),
      );
      return;
    }

    List<String>? paths;
    if (Platform.isLinux) {
      paths = await _readLinuxClipboardFiles();
    } else if (Platform.isWindows) {
      paths = await _readWindowsClipboardFiles();
    }

    if (paths != null && paths.isNotEmpty) {
      await _importExternalPaths(paths);
    } else if (_clipboardItems.isNotEmpty) {
      // Fall back to internal paste
      await _pasteItems();
    }
  }

  Future<List<String>?> _readLinuxClipboardFiles() async {
    // Try GNOME/Nemo format first: x-special/gnome-copied-files
    try {
      final result = await Process.run(
        'xclip',
        ['-selection', 'clipboard', '-t', 'x-special/gnome-copied-files', '-o'],
      );
      if (result.exitCode == 0) {
        final content = (result.stdout as String).trim();
        if (content.startsWith('copy\n') || content.startsWith('cut\n')) {
          final lines = content.split('\n').skip(1);
          final paths = <String>[];
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty) continue;
            try {
              paths.add(Uri.parse(trimmed).toFilePath());
            } catch (_) {}
          }
          if (paths.isNotEmpty) return paths;
        }
      }
    } catch (_) {}

    // Fallback: text/uri-list (KDE/Dolphin)
    try {
      final result = await Process.run(
        'xclip',
        ['-selection', 'clipboard', '-t', 'text/uri-list', '-o'],
      );
      if (result.exitCode == 0) {
        final content = (result.stdout as String).trim();
        final paths = <String>[];
        for (final line in content.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
          try {
            paths.add(Uri.parse(trimmed).toFilePath());
          } catch (_) {}
        }
        if (paths.isNotEmpty) return paths;
      }
    } catch (_) {}

    return null;
  }

  Future<List<String>?> _readWindowsClipboardFiles() async {
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        r"Get-Clipboard -Format FileDropList | ForEach-Object { $_.FullName }",
      ]);
      if (result.exitCode == 0) {
        final content = (result.stdout as String).trim();
        if (content.isNotEmpty) {
          return content.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
        }
      }
    } catch (_) {}
    return null;
  }

  // ============ Visual Overlays ============

  Widget _buildDropOverlay(ThemeData theme) {
    return IgnorePointer(
      child: Container(
        color: theme.colorScheme.primary.withValues(alpha: 0.15),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.download_rounded,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'Drop files here to import',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_isInsideProfileStorage() &&
                  widget.profileStorage?.isEncrypted == true) ...[
                const SizedBox(height: 4),
                Text(
                  'Files will be encrypted',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImportProgressOverlay(ThemeData theme) {
    final progress = _importTotal > 0 ? _importProgress / _importTotal : 0.0;
    return IgnorePointer(
      child: Container(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        child: Center(
          child: Card(
            elevation: 8,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(value: progress),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Importing $_importProgress of $_importTotal',
                    style: theme.textTheme.titleSmall,
                  ),
                  if (_importCurrentFile != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _importCurrentFile!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _deleteItem(FileSystemItem item) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete'),
        content: Text('Delete "${item.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _performDelete(item);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _performDelete(FileSystemItem item) async {
    try {
      final relativePath = _profileRelativePath(item.path);
      if (_isInsideProfileStorage() && relativePath != null) {
        final storage = widget.profileStorage!;
        await _archiveAndTombstoneStorageTree(relativePath);
        if (item.isDirectory) {
          await storage.deleteDirectory(relativePath, recursive: true);
        } else {
          await storage.delete(relativePath);
        }
        _scheduleSyncForProfilePath(relativePath, 'item deleted');
      } else if (item.isDirectory) {
        await Directory(item.path).delete(recursive: true);
      } else {
        await File(item.path).delete();
      }
      _selectedPaths.remove(item.path);
      _loadDirectory();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  IconData _getItemIcon(FileSystemItem item) {
    if (item.isDirectory) return Icons.folder_rounded;

    final ext = item.name.split('.').last.toLowerCase();
    switch (ext) {
      // Images
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'bmp':
      case 'svg':
      case 'ico':
      case 'heic':
      case 'heif':
        return Icons.image_rounded;

      // Videos
      case 'mp4':
      case 'avi':
      case 'mov':
      case 'mkv':
      case 'webm':
      case 'flv':
      case 'wmv':
      case 'm4v':
      case '3gp':
        return Icons.movie_rounded;

      // Audio/Music
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'ogg':
      case 'aac':
      case 'm4a':
      case 'wma':
      case 'opus':
      case 'mid':
      case 'midi':
        return Icons.music_note_rounded;

      // Documents
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'doc':
      case 'docx':
      case 'odt':
      case 'rtf':
        return Icons.description_rounded;
      case 'xls':
      case 'xlsx':
      case 'ods':
      case 'csv':
        return Icons.table_chart_rounded;
      case 'ppt':
      case 'pptx':
      case 'odp':
        return Icons.slideshow_rounded;
      case 'txt':
      case 'md':
      case 'log':
        return Icons.article_rounded;

      // Data files
      case 'json':
      case 'xml':
      case 'yaml':
      case 'yml':
      case 'toml':
      case 'ini':
      case 'cfg':
      case 'conf':
        return Icons.data_object_rounded;

      // Code
      case 'dart':
      case 'py':
      case 'js':
      case 'ts':
      case 'java':
      case 'kt':
      case 'swift':
      case 'c':
      case 'cpp':
      case 'h':
      case 'cs':
      case 'go':
      case 'rs':
      case 'rb':
      case 'php':
      case 'html':
      case 'css':
      case 'scss':
      case 'sql':
      case 'vue':
      case 'jsx':
      case 'tsx':
        return Icons.code_rounded;

      // Executables
      case 'exe':
      case 'msi':
      case 'app':
      case 'dmg':
      case 'deb':
      case 'rpm':
      case 'appimage':
      case 'flatpak':
      case 'snap':
        return Icons.apps_rounded;

      // Scripts
      case 'sh':
      case 'bash':
      case 'zsh':
      case 'bat':
      case 'cmd':
      case 'ps1':
        return Icons.terminal_rounded;

      // Archives
      case 'zip':
      case 'rar':
      case 'tar':
      case 'gz':
      case '7z':
      case 'bz2':
      case 'xz':
      case 'zst':
        return Icons.folder_zip_rounded;

      // Disk images
      case 'iso':
      case 'img':
      case 'dmg':
        return Icons.album_rounded;

      // Fonts
      case 'ttf':
      case 'otf':
      case 'woff':
      case 'woff2':
        return Icons.font_download_rounded;

      // Android
      case 'apk':
      case 'aab':
        return Icons.android_rounded;

      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  Color _getIconColor(FileSystemItem item) {
    if (item.isDirectory) return Colors.amber.shade700;

    final ext = item.name.split('.').last.toLowerCase();
    switch (ext) {
      // Images - Green
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'bmp':
      case 'svg':
      case 'heic':
        return Colors.green.shade600;

      // Videos - Red
      case 'mp4':
      case 'avi':
      case 'mov':
      case 'mkv':
      case 'webm':
        return Colors.red.shade600;

      // Audio - Purple
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'ogg':
      case 'aac':
      case 'm4a':
        return Colors.purple.shade600;

      // PDF - Red
      case 'pdf':
        return Colors.red.shade700;

      // Word docs - Blue
      case 'doc':
      case 'docx':
      case 'odt':
        return Colors.blue.shade700;

      // Spreadsheets - Green
      case 'xls':
      case 'xlsx':
      case 'ods':
      case 'csv':
        return Colors.green.shade700;

      // Presentations - Orange
      case 'ppt':
      case 'pptx':
      case 'odp':
        return Colors.orange.shade700;

      // Code - Teal
      case 'dart':
      case 'py':
      case 'js':
      case 'ts':
      case 'java':
      case 'kt':
      case 'swift':
      case 'html':
      case 'css':
        return Colors.teal.shade600;

      // Executables/Scripts - Deep Orange
      case 'exe':
      case 'sh':
      case 'bin':
      case 'appimage':
      case 'deb':
      case 'rpm':
        return Colors.deepOrange.shade600;

      // Archives - Brown
      case 'zip':
      case 'rar':
      case 'tar':
      case 'gz':
      case '7z':
        return Colors.brown.shade600;

      // Android - Green
      case 'apk':
      case 'aab':
        return Colors.green.shade600;

      default:
        return Colors.blueGrey.shade600;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        if (diff.inMinutes < 1) return 'Just now';
        return '${diff.inMinutes}m ago';
      }
      return '${diff.inHours}h ago';
    }
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';

    return '${date.day}/${date.month}/${date.year}';
  }
}
