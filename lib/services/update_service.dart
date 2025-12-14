import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/update_settings.dart';
import '../services/app_args.dart';
import '../services/config_service.dart';
import '../services/log_service.dart';
import '../services/station_service.dart';
import '../version.dart';

/// Service for managing application updates with rollback support
class UpdateService {
  static final UpdateService _instance = UpdateService._internal();
  factory UpdateService() => _instance;
  UpdateService._internal();

  /// Method channel for Android-specific update operations
  static const MethodChannel _updateChannel = MethodChannel('dev.geogram/updates');

  UpdateSettings? _settings;
  bool _initialized = false;
  ReleaseInfo? _latestRelease;
  bool _isChecking = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;

  /// Track completed download path (persists across page navigation)
  String? _completedDownloadPath;
  String? _completedDownloadVersion;

  /// Track bytes downloaded for current session (for resume info display)
  int _bytesDownloaded = 0;
  int _totalBytes = 0;

  /// Notifier for update availability
  final ValueNotifier<bool> updateAvailable = ValueNotifier(false);

  /// Notifier for download progress (0.0 to 1.0)
  final ValueNotifier<double> downloadProgress = ValueNotifier(0.0);

  /// Flag to indicate if the UpdatePage is currently visible
  /// When true, the update banner should not be shown
  bool isUpdatePageVisible = false;

  /// Progress update throttling - only update UI every 100ms or 1% change
  DateTime _lastProgressUpdate = DateTime.now();
  double _lastProgressValue = 0.0;
  static const _progressUpdateInterval = Duration(milliseconds: 100);
  static const _progressMinChange = 0.01; // 1%

  /// Initialize update service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _loadSettings();
      _initialized = true;
      LogService().log('UpdateService initialized');

      // Migrate from old rollback folder to new updates structure (one-time)
      await _migrateFromOldRollbackFolder();

      // Backup current version on startup if not already archived
      await _backupCurrentVersionOnStartup();

      // Skip update checks if --no-update flag is set
      if (AppArgs().noUpdate) {
        LogService().log('UpdateService: Update checks disabled via --no-update flag');
        return;
      }

      // Auto-check for updates if enabled - always check on startup
      if (_settings?.autoCheckUpdates == true) {
        // Check for updates immediately on startup
        checkForUpdates();
      } else {
        // If auto-check is disabled, still restore last known state for display
        final lastCheckedVersion = _settings?.lastCheckedVersion;
        if (lastCheckedVersion != null && lastCheckedVersion.isNotEmpty) {
          final wasUpdateAvailable = isNewerVersion(getCurrentVersion(), lastCheckedVersion);
          if (wasUpdateAvailable) {
            // Create ReleaseInfo with cached release notes so changelog is visible
            _latestRelease = ReleaseInfo(
              version: lastCheckedVersion,
              tagName: 'v$lastCheckedVersion',
              name: 'Version $lastCheckedVersion',
              body: _settings?.lastCheckedReleaseBody,
              htmlUrl: _settings?.lastCheckedHtmlUrl,
              stationBaseUrl: _settings?.lastCheckedStationUrl,
              publishedAt: _settings?.lastCheckedPublishedAt,
            );
            updateAvailable.value = true;
            LogService().log('Restored update available state: $lastCheckedVersion > ${getCurrentVersion()}');
          }
        }
      }
    } catch (e) {
      LogService().log('Error initializing UpdateService: $e');
    }
  }

  /// Load settings from config
  Future<void> _loadSettings() async {
    final config = ConfigService().getAll();

    if (config.containsKey('updateSettings')) {
      final settingsData = config['updateSettings'] as Map<String, dynamic>;
      _settings = UpdateSettings.fromJson(settingsData);
      LogService().log('Loaded update settings from config');
    } else {
      _settings = UpdateSettings();
      _saveSettings();
      LogService().log('Created default update settings');
    }
  }

  /// Save settings to config.json
  void _saveSettings() {
    if (_settings != null) {
      ConfigService().set('updateSettings', _settings!.toJson());
      LogService().log('Saved update settings to config');
    }
  }

  /// Get current settings
  UpdateSettings getSettings() {
    if (!_initialized) {
      return UpdateSettings();
    }
    return _settings ?? UpdateSettings();
  }

  /// Update settings
  Future<void> updateSettings(UpdateSettings settings) async {
    _settings = settings;
    _saveSettings();
  }

  /// Detect current platform
  UpdatePlatform detectPlatform() {
    if (kIsWeb) {
      return UpdatePlatform.unknown;
    }

    if (Platform.isLinux) {
      return UpdatePlatform.linux;
    } else if (Platform.isWindows) {
      return UpdatePlatform.windows;
    } else if (Platform.isAndroid) {
      return UpdatePlatform.android;
    } else if (Platform.isMacOS) {
      return UpdatePlatform.macos;
    }

    return UpdatePlatform.unknown;
  }

  /// Get current app version
  String getCurrentVersion() {
    return appVersion;
  }

  /// Check for updates - tries station first if enabled, then falls back to GitHub
  Future<ReleaseInfo?> checkForUpdates() async {
    if (_isChecking || kIsWeb) return null;

    _isChecking = true;
    try {
      // Try station first if enabled (offgrid-first)
      if (_settings?.useStationForUpdates == true) {
        final stationRelease = await _checkStationForUpdates();
        if (stationRelease != null) {
          _latestRelease = stationRelease;
          _updateCheckResult(stationRelease);
          return stationRelease;
        }
        LogService().log('Station update check failed or unavailable, falling back to GitHub');
      }

      // Fall back to GitHub (or use directly if station disabled)
      return await _checkGitHubForUpdates();
    } catch (e) {
      LogService().log('Error checking for updates: $e');
      return null;
    } finally {
      _isChecking = false;
    }
  }

  /// Check for updates from connected station
  Future<ReleaseInfo?> _checkStationForUpdates() async {
    try {
      final station = StationService().getPreferredStation();
      if (station == null || station.url.isEmpty) {
        LogService().log('No station connected for update check');
        return null;
      }

      // Convert WebSocket URL to HTTP
      final httpUrl = _wsToHttpUrl(station.url);
      final updateUrl = '$httpUrl/api/updates/latest';

      LogService().log('Checking station for updates: $updateUrl');

      final response = await http.get(
        Uri.parse(updateUrl),
        headers: {'User-Agent': 'Geogram-Desktop-Updater'},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        LogService().log('Station update check failed: HTTP ${response.statusCode}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;

      // Check if station has updates cached
      if (json['status'] == 'no_updates_cached') {
        LogService().log('Station has no updates cached');
        return null;
      }

      if (json['status'] != 'available') {
        LogService().log('Station update status: ${json['status']}');
        return null;
      }

      final release = ReleaseInfo.fromStationJson(json, httpUrl);
      LogService().log('Got update info from station: v${release.version} with ${release.assets.length} assets');
      return release;
    } catch (e) {
      LogService().log('Error checking station for updates: $e');
      return null;
    }
  }

  /// Check for updates from GitHub
  Future<ReleaseInfo?> _checkGitHubForUpdates() async {
    try {
      final url = _settings?.updateUrl ??
          'https://api.github.com/repos/geograms/geogram-desktop/releases/latest';

      LogService().log('Checking GitHub for updates: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'Geogram-Desktop-Updater',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch release info: HTTP ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      _latestRelease = ReleaseInfo.fromGitHubJson(json);

      _updateCheckResult(_latestRelease!);
      return _latestRelease;
    } catch (e) {
      LogService().log('Error checking GitHub for updates: $e');
      return null;
    }
  }

  /// Update settings and notify after successful check
  void _updateCheckResult(ReleaseInfo release) {
    _settings = _settings?.copyWith(
      lastCheckTime: DateTime.now(),
      lastCheckedVersion: release.version,
      lastCheckedReleaseBody: release.body,
      lastCheckedHtmlUrl: release.htmlUrl,
      lastCheckedStationUrl: release.stationBaseUrl,
      lastCheckedPublishedAt: release.publishedAt,
    );
    _saveSettings();

    final isNewer = isNewerVersion(getCurrentVersion(), release.version);
    updateAvailable.value = isNewer;

    LogService().log(
        'Update check complete: current=$appVersion, latest=${release.version}, updateAvailable=$isNewer');
  }

  /// Convert WebSocket URL to HTTP URL
  String _wsToHttpUrl(String wsUrl) {
    return wsUrl
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');
  }

  /// Get latest release info (from cache or fetch)
  ReleaseInfo? getLatestRelease() {
    return _latestRelease;
  }

  /// Compare versions (returns true if newVersion > currentVersion)
  bool isNewerVersion(String currentVersion, String newVersion) {
    try {
      final current = currentVersion.replaceFirst(RegExp(r'^v'), '').split('.');
      final newVer = newVersion.replaceFirst(RegExp(r'^v'), '').split('.');

      final maxLen = current.length > newVer.length ? current.length : newVer.length;

      for (var i = 0; i < maxLen; i++) {
        final c = i < current.length
            ? int.tryParse(current[i].replaceAll(RegExp(r'[^0-9]'), '')) ?? 0
            : 0;
        final n = i < newVer.length
            ? int.tryParse(newVer[i].replaceAll(RegExp(r'[^0-9]'), '')) ?? 0
            : 0;

        if (n > c) return true;
        if (n < c) return false;
      }
    } catch (e) {
      LogService().log('Version comparison failed: $currentVersion vs $newVersion');
    }

    return false;
  }

  /// Get download URL for current platform
  String? getDownloadUrl(ReleaseInfo release) {
    final platform = detectPlatform();
    final assetType = platform.assetType;

    // Check for custom download URL pattern
    if (_settings?.downloadUrlPattern.isNotEmpty == true) {
      return _settings!.downloadUrlPattern
          .replaceAll('{version}', release.version)
          .replaceAll('{platform}', platform.name)
          .replaceAll('{binary}', platform.binaryPattern);
    }

    // Use asset URL (works for both station and GitHub releases)
    return release.getAssetUrl(assetType);
  }

  /// Get updates directory path (unified with station structure)
  Future<String> getUpdatesDirectory() async {
    if (kIsWeb) {
      throw UnsupportedError('Updates not supported on web');
    }

    final appDir = await getApplicationSupportDirectory();
    final updatesDir = Directory('${appDir.path}/updates');

    if (!await updatesDir.exists()) {
      await updatesDir.create(recursive: true);
    }

    return updatesDir.path;
  }

  /// Get version-specific directory path
  Future<String> getVersionDirectory(String version) async {
    final updatesDir = await getUpdatesDirectory();
    final versionDir = Directory('$updatesDir/$version');

    if (!await versionDir.exists()) {
      await versionDir.create(recursive: true);
    }

    return versionDir.path;
  }

  /// Get platform-specific binary name
  String _getPlatformBinaryName() {
    if (!kIsWeb && Platform.isAndroid) return 'geogram.apk';
    if (!kIsWeb && Platform.isWindows) return 'geogram-desktop.exe';
    return 'geogram-desktop'; // Linux, macOS
  }

  /// Find binary file inside a version directory
  Future<String?> _findBinaryInVersionDir(String versionDirPath) async {
    final dir = Directory(versionDirPath);
    if (!await dir.exists()) return null;

    // Look for platform-appropriate binary
    final expectedName = _getPlatformBinaryName();
    final expectedFile = File('$versionDirPath${Platform.pathSeparator}$expectedName');
    if (await expectedFile.exists()) {
      return expectedFile.path;
    }

    // Fallback: find any executable-like file
    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.endsWith('.apk') || name.endsWith('.exe') ||
            name == 'geogram-desktop' || name.startsWith('geogram')) {
          return entity.path;
        }
      }
    }

    return null;
  }

  /// Backup current version on startup if not already archived
  Future<void> _backupCurrentVersionOnStartup() async {
    if (kIsWeb) return;

    try {
      final updatesDir = await getUpdatesDirectory();
      final versionDir = Directory('$updatesDir/$appVersion');

      // Check if this version is already archived
      if (await versionDir.exists()) {
        final binaryPath = await _findBinaryInVersionDir(versionDir.path);
        if (binaryPath != null) {
          LogService().log('Version $appVersion already archived');
          return;
        }
      }

      LogService().log('Backing up current version $appVersion on startup');
      await createBackup();
    } catch (e) {
      LogService().log('Error backing up on startup: $e');
    }
  }

  /// Migrate old rollback folder to new updates structure
  Future<void> _migrateFromOldRollbackFolder() async {
    if (kIsWeb) return;

    try {
      final appDir = await getApplicationSupportDirectory();
      final oldRollbackDir = Directory('${appDir.path}/rollback');

      if (!await oldRollbackDir.exists()) return;

      LogService().log('Migrating old rollback folder to new updates structure');

      await for (final entity in oldRollbackDir.list()) {
        if (entity is File &&
            (entity.path.endsWith('.backup') || entity.path.endsWith('.apk'))) {
          // Parse version from old filename: geogram-desktop.1.6.20.2024-12-08_10-15-00.backup
          final filename = entity.path.split(Platform.pathSeparator).last;
          final version = _parseVersionFromOldFilename(filename);

          if (version != null) {
            final versionDir = await getVersionDirectory(version);
            final binaryName = _getPlatformBinaryName();
            final newPath = '$versionDir/$binaryName';

            if (!await File(newPath).exists()) {
              await entity.copy(newPath);
              LogService().log('Migrated $version from old rollback folder');
            }

            // Migrate pinned marker
            final oldPinnedMarker = File('${entity.path}.pinned');
            if (await oldPinnedMarker.exists()) {
              final updatesDir = await getUpdatesDirectory();
              await File('$updatesDir/$version.pinned').create();
              await oldPinnedMarker.delete();
            }
          }

          await entity.delete();
        }
      }

      // Remove old rollback directory if empty
      final remaining = await oldRollbackDir.list().toList();
      if (remaining.isEmpty) {
        await oldRollbackDir.delete();
        LogService().log('Removed old rollback folder');
      }
    } catch (e) {
      LogService().log('Error migrating from old rollback folder: $e');
    }
  }

  /// Parse version from old filename format: geogram-desktop.1.6.20.2024-12-08_10-15-00.backup
  String? _parseVersionFromOldFilename(String filename) {
    // Remove extension
    String name = filename;
    if (name.endsWith('.backup')) {
      name = name.substring(0, name.length - 7);
    } else if (name.endsWith('.apk')) {
      name = name.substring(0, name.length - 4);
    }

    // Split by dots
    final parts = name.split('.');
    if (parts.length < 4) return null;

    // Find timestamp pattern (YYYY-MM-DD)
    for (var i = 1; i < parts.length - 1; i++) {
      if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(parts[i])) {
        // Version is between prefix and timestamp
        return parts.sublist(1, i).join('.');
      }
    }

    return null;
  }

  /// Get backup directory path (deprecated, use getUpdatesDirectory)
  @Deprecated('Use getUpdatesDirectory instead')
  Future<String> getBackupDirectory() async {
    return getUpdatesDirectory();
  }

  /// List available backups (scans version subdirectories)
  Future<List<BackupInfo>> listBackups() async {
    if (kIsWeb) return [];

    try {
      final updatesDir = await getUpdatesDirectory();
      final dir = Directory(updatesDir);

      if (!await dir.exists()) {
        return [];
      }

      final backups = <BackupInfo>[];

      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final version = entity.path.split(Platform.pathSeparator).last;

          // Skip non-version directories (must start with digit)
          if (!RegExp(r'^\d+\.\d+').hasMatch(version)) continue;

          // Find binary inside directory
          final binaryPath = await _findBinaryInVersionDir(entity.path);
          if (binaryPath == null) continue;

          final stat = await File(binaryPath).stat();

          // Check if version is pinned (directory-level marker)
          final pinnedMarker = File('$updatesDir/$version.pinned');
          final isPinned = await pinnedMarker.exists();

          backups.add(BackupInfo(
            filename: version, // Now just version string
            version: version,
            timestamp: stat.modified,
            sizeBytes: stat.size,
            path: binaryPath,
            isPinned: isPinned,
          ));
        }
      }

      // Sort by version (semantic versioning), newest first
      backups.sort((a, b) {
        // Try semantic version comparison
        if (a.version != null && b.version != null) {
          final aParts = a.version!.split('.').map((p) => int.tryParse(p) ?? 0).toList();
          final bParts = b.version!.split('.').map((p) => int.tryParse(p) ?? 0).toList();

          for (var i = 0; i < aParts.length && i < bParts.length; i++) {
            if (bParts[i] != aParts[i]) {
              return bParts[i].compareTo(aParts[i]); // Descending order
            }
          }
          return bParts.length.compareTo(aParts.length);
        }
        // Fallback to timestamp
        return b.timestamp.compareTo(a.timestamp);
      });

      return backups;
    } catch (e) {
      LogService().log('Error listing backups: $e');
      return [];
    }
  }

  /// Create backup of current binary or APK (uses version subdirectory)
  Future<BackupInfo?> createBackup() async {
    if (kIsWeb) return null;

    try {
      String? sourceFile;

      if (Platform.isAndroid) {
        // On Android, backup the currently installed APK
        sourceFile = await _getCurrentApkPath();
      } else {
        // On desktop, backup the current binary
        sourceFile = await _getCurrentBinaryPath();
      }

      if (sourceFile == null || !await File(sourceFile).exists()) {
        LogService().log('Source file not found for backup');
        return null;
      }

      // Create version subdirectory: updates/{version}/
      final versionDir = await getVersionDirectory(appVersion);
      final binaryName = _getPlatformBinaryName();
      final backupFile = File('$versionDir${Platform.pathSeparator}$binaryName');

      // Check if already exists
      if (await backupFile.exists()) {
        LogService().log('Backup already exists for version $appVersion');
        final stat = await backupFile.stat();
        return BackupInfo(
          filename: appVersion,
          version: appVersion,
          timestamp: stat.modified,
          sizeBytes: stat.size,
          path: backupFile.path,
        );
      }

      LogService().log('Creating backup: $sourceFile -> ${backupFile.path}');
      await File(sourceFile).copy(backupFile.path);

      // Cleanup old backups
      await _cleanupOldBackups();

      final stat = await backupFile.stat();
      return BackupInfo(
        filename: appVersion,
        version: appVersion,
        timestamp: DateTime.now(),
        sizeBytes: stat.size,
        path: backupFile.path,
      );
    } catch (e) {
      LogService().log('Error creating backup: $e');
      return null;
    }
  }

  /// Cleanup old backups beyond the maximum limit
  /// Pinned backups are never removed during cleanup
  /// Removes entire version directories
  Future<void> _cleanupOldBackups() async {
    try {
      final backups = await listBackups();
      final maxBackups = _settings?.maxBackups ?? 5;

      // Separate pinned and unpinned backups
      final unpinnedBackups = backups.where((b) => !b.isPinned).toList();

      if (unpinnedBackups.length > maxBackups) {
        final toRemove = unpinnedBackups.sublist(maxBackups);
        final updatesDir = await getUpdatesDirectory();

        for (final backup in toRemove) {
          if (backup.version == null) continue;

          final versionDir = Directory('$updatesDir/${backup.version}');
          LogService().log('Removing old version: ${backup.version}');

          if (await versionDir.exists()) {
            await versionDir.delete(recursive: true);
          }
        }
      }
    } catch (e) {
      LogService().log('Error cleaning up backups: $e');
    }
  }

  /// Get current binary path
  Future<String?> _getCurrentBinaryPath() async {
    if (kIsWeb) return null;

    final platform = detectPlatform();

    // Try to get the executable path
    try {
      final executable = Platform.resolvedExecutable;
      if (await File(executable).exists()) {
        return executable;
      }
    } catch (e) {
      LogService().log('Could not get executable path: $e');
    }

    // Fallback: look in common locations
    final appDir = await getApplicationSupportDirectory();
    final possiblePaths = [
      '${appDir.parent.path}/${platform.binaryPattern}',
      Platform.resolvedExecutable,
    ];

    for (final path in possiblePaths) {
      if (await File(path).exists()) {
        return path;
      }
    }

    return null;
  }

  /// Get the path to the currently installed APK (Android only)
  Future<String?> _getCurrentApkPath() async {
    if (kIsWeb || !Platform.isAndroid) return null;

    try {
      final result = await _updateChannel.invokeMethod<String>('getCurrentApkPath');
      LogService().log('Current APK path: $result');
      return result;
    } catch (e) {
      LogService().log('Error getting current APK path: $e');
      return null;
    }
  }

  /// Start the download foreground service (Android only)
  Future<void> _startDownloadService() async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      await _updateChannel.invokeMethod('startDownloadService');
      LogService().log('Download foreground service started');
    } catch (e) {
      LogService().log('Error starting download service: $e');
    }
  }

  /// Stop the download foreground service (Android only)
  Future<void> _stopDownloadService() async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      await _updateChannel.invokeMethod('stopDownloadService');
      LogService().log('Download foreground service stopped');
    } catch (e) {
      LogService().log('Error stopping download service: $e');
    }
  }

  /// Update the download service notification with progress (Android only)
  Future<void> _updateDownloadServiceProgress(int progress, String status) async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      await _updateChannel.invokeMethod('updateDownloadProgress', {
        'progress': progress,
        'status': status,
      });
    } catch (e) {
      // Don't log every progress update error to avoid spam
    }
  }

  /// Download update to temporary file with resume support
  Future<String?> downloadUpdate(ReleaseInfo release,
      {void Function(double progress)? onProgress}) async {
    if (_isDownloading || kIsWeb) return null;

    final downloadUrl = getDownloadUrl(release);
    if (downloadUrl == null) {
      LogService().log('No download URL available for platform: ${detectPlatform().name}');
      return null;
    }

    _isDownloading = true;
    _downloadProgress = 0.0;
    _lastProgressValue = 0.0;
    _lastProgressUpdate = DateTime.now();
    downloadProgress.value = 0.0;
    _bytesDownloaded = 0;
    _totalBytes = 0;

    // Start foreground service to keep download alive in background
    await _startDownloadService();

    try {
      LogService().log('Downloading update from: $downloadUrl');

      // On Android, use external cache directory for better FileProvider compatibility
      // Use dynamic to handle type differences between dart:io and io_stub on web
      late final dynamic tempDir;
      if (!kIsWeb && Platform.isAndroid) {
        final externalCacheDirs = await getExternalCacheDirectories();
        if (externalCacheDirs != null && externalCacheDirs.isNotEmpty) {
          tempDir = externalCacheDirs.first;
        } else {
          tempDir = await getTemporaryDirectory();
        }
      } else {
        tempDir = await getTemporaryDirectory();
      }
      LogService().log('Download directory: ${tempDir.path}');
      final platform = detectPlatform();
      final extension = platform == UpdatePlatform.windows
          ? '.exe'
          : platform == UpdatePlatform.android
              ? '.apk'
              : '';
      final tempFilePath =
          '${tempDir.path}${Platform.pathSeparator}geogram-update-${release.version}$extension';
      final partialFilePath = '$tempFilePath.partial';
      final partialFile = File(partialFilePath);

      // Check for existing partial download
      int existingBytes = 0;
      if (await partialFile.exists()) {
        existingBytes = await partialFile.length();
        LogService().log('Found partial download: $existingBytes bytes');
      }

      // First, get the total file size with a HEAD request
      final headResponse = await http.head(
        Uri.parse(downloadUrl),
        headers: {'User-Agent': 'Geogram-Desktop-Updater'},
      ).timeout(const Duration(seconds: 30));

      final contentLength = int.tryParse(
              headResponse.headers['content-length'] ?? '') ??
          0;
      _totalBytes = contentLength;

      // Check if server supports range requests
      final acceptRanges = headResponse.headers['accept-ranges'];
      final supportsResume = acceptRanges == 'bytes' && contentLength > 0;

      // If we have a complete download already, use it
      if (existingBytes > 0 && existingBytes >= contentLength && contentLength > 0) {
        LogService().log('Partial file is complete, renaming...');
        await partialFile.rename(tempFilePath);
        _downloadProgress = 1.0;
        downloadProgress.value = 1.0;
        return tempFilePath;
      }

      // Create HTTP client for better connection management
      final client = http.Client();

      try {
        // Build request with Range header for resume
        final request = http.Request('GET', Uri.parse(downloadUrl));
        request.headers['User-Agent'] = 'Geogram-Desktop-Updater';

        // Resume from existing bytes if supported
        int startByte = 0;
        if (supportsResume && existingBytes > 0) {
          startByte = existingBytes;
          request.headers['Range'] = 'bytes=$startByte-';
          LogService().log('Resuming download from byte $startByte');
        } else if (existingBytes > 0) {
          // Server doesn't support resume, delete partial and start fresh
          LogService().log('Server does not support resume, starting fresh');
          await partialFile.delete();
          existingBytes = 0;
        }

        final response = await client.send(request);

        // Check response - 200 for full, 206 for partial
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw Exception('Failed to download update: HTTP ${response.statusCode}');
        }

        // Calculate total size for progress
        final expectedLength = response.contentLength ?? (contentLength - startByte);
        final totalSize = startByte + expectedLength;

        // Open file for writing - append if resuming
        final sink = partialFile.openWrite(
            mode: startByte > 0 ? FileMode.append : FileMode.write);

        var downloaded = startByte;
        _bytesDownloaded = downloaded;

        // Write chunks directly - HTTP streams are already reasonably chunked
        // and the filesystem handles buffering internally
        await for (final chunk in response.stream) {
          // Write chunk directly to file
          sink.add(chunk);
          downloaded += chunk.length;

          // Throttled progress update
          _bytesDownloaded = downloaded;
          if (totalSize > 0) {
            final progress = downloaded / totalSize;
            _updateProgressThrottled(progress, onProgress);
          }
        }

        // Ensure all data is flushed to disk
        await sink.flush();
        await sink.close();

        // Rename partial file to final name
        await partialFile.rename(tempFilePath);

        // Verify file integrity on Android
        if (!kIsWeb && Platform.isAndroid) {
          final downloadedFile = File(tempFilePath);
          final actualSize = await downloadedFile.length();
          LogService().log('APK file size: $actualSize bytes (expected: $totalSize)');

          if (totalSize > 0 && actualSize < totalSize * 0.95) {
            // File is more than 5% smaller than expected - likely corrupted
            LogService().log('WARNING: Downloaded file appears incomplete!');
            await downloadedFile.delete();
            throw Exception('Download incomplete: got $actualSize bytes, expected $totalSize');
          }

          // Verify APK is a valid ZIP file (APKs are ZIP archives)
          final isValidApk = await _verifyApkIntegrity(tempFilePath);
          if (!isValidApk) {
            LogService().log('WARNING: APK integrity check failed - file may be corrupted');
            await downloadedFile.delete();
            throw Exception('Downloaded APK is corrupted. Please try again.');
          }
          LogService().log('APK integrity verified successfully');
        }

        // Final progress update
        _downloadProgress = 1.0;
        downloadProgress.value = 1.0;
        onProgress?.call(1.0);

        // Store completed download state for UI persistence
        _completedDownloadPath = tempFilePath;
        _completedDownloadVersion = release.version;

        LogService().log('Downloaded $downloaded bytes to $tempFilePath');
        return tempFilePath;
      } finally {
        client.close();
      }
    } catch (e) {
      LogService().log('Error downloading update: $e');
      // Don't delete partial file on error - allow resume next time
      return null;
    } finally {
      _isDownloading = false;
      _downloadProgress = 0.0;
      downloadProgress.value = 0.0;
      _bytesDownloaded = 0;
      _totalBytes = 0;

      // Stop the foreground service
      await _stopDownloadService();
    }
  }

  /// Update progress with throttling to reduce UI updates
  void _updateProgressThrottled(double progress, void Function(double)? onProgress) {
    final now = DateTime.now();
    final timeSinceLastUpdate = now.difference(_lastProgressUpdate);
    final progressChange = (progress - _lastProgressValue).abs();

    // Only update if enough time has passed OR progress changed significantly
    if (timeSinceLastUpdate >= _progressUpdateInterval ||
        progressChange >= _progressMinChange ||
        progress >= 1.0) {
      _downloadProgress = progress;
      downloadProgress.value = progress;
      onProgress?.call(progress);
      _lastProgressUpdate = now;
      _lastProgressValue = progress;

      // Update the foreground service notification with progress
      final progressPercent = (progress * 100).toInt();
      final status = getDownloadStatus();
      _updateDownloadServiceProgress(progressPercent, status.isNotEmpty ? status : 'Downloading...');
    }
  }

  /// Get formatted download status (for UI display)
  String getDownloadStatus() {
    if (!_isDownloading) return '';
    if (_totalBytes == 0) return 'Downloading...';

    final downloadedMB = _bytesDownloaded / (1024 * 1024);
    final totalMB = _totalBytes / (1024 * 1024);
    return '${downloadedMB.toStringAsFixed(1)} / ${totalMB.toStringAsFixed(1)} MB';
  }

  /// Cancel current download (if any)
  Future<void> cancelDownload() async {
    if (!_isDownloading) return;

    LogService().log('Download cancelled by user');
    _isDownloading = false;
    _downloadProgress = 0.0;
    downloadProgress.value = 0.0;

    // Stop the foreground service
    await _stopDownloadService();
  }

  /// Verify APK file integrity by checking ZIP structure
  /// APK files are ZIP archives that must contain AndroidManifest.xml
  Future<bool> _verifyApkIntegrity(String filePath) async {
    // Not supported on web
    if (kIsWeb) return true;

    try {
      final file = File(filePath);
      if (!await file.exists()) return false;

      // Read file bytes to check ZIP structure
      final bytes = await file.readAsBytes();
      if (bytes.length < 22) return false; // Minimum ZIP size

      // Check ZIP magic number at start: 0x50 0x4B 0x03 0x04 (PK..)
      if (bytes[0] != 0x50 || bytes[1] != 0x4B ||
          bytes[2] != 0x03 || bytes[3] != 0x04) {
        LogService().log('APK verification failed: Invalid ZIP header');
        return false;
      }

      // Check end of central directory signature at the end of file
      // This ensures the ZIP file is complete: 0x50 0x4B 0x05 0x06
      final eocdOffset = bytes.length - 22;
      if (bytes[eocdOffset] != 0x50 || bytes[eocdOffset + 1] != 0x4B ||
          bytes[eocdOffset + 2] != 0x05 || bytes[eocdOffset + 3] != 0x06) {
        LogService().log('APK verification failed: Missing end of central directory');
        return false;
      }

      LogService().log('APK ZIP structure verified');
      return true;
    } catch (e) {
      LogService().log('APK verification error: $e');
      return false;
    }
  }

  /// Clear all downloads (partial and complete) for a fresh retry
  Future<void> clearAllDownloads() async {
    if (kIsWeb) return;

    try {
      // Clear from temp directory
      final tempDir = await getTemporaryDirectory();
      await _clearDownloadsInDir(tempDir.path);

      // Also clear from external cache on Android
      if (Platform.isAndroid) {
        final externalCacheDirs = await getExternalCacheDirectories();
        if (externalCacheDirs != null) {
          for (final dir in externalCacheDirs) {
            await _clearDownloadsInDir(dir.path);
          }
        }
      }

      LogService().log('All downloads cleared');
    } catch (e) {
      LogService().log('Error clearing downloads: $e');
    }
  }

  Future<void> _clearDownloadsInDir(String dirPath) async {
    final dir = Directory(dirPath);
    await for (final entity in dir.list()) {
      if (entity is File) {
        final path = entity.path;
        if (path.contains('geogram-update') &&
            (path.endsWith('.apk') || path.endsWith('.partial') ||
             path.endsWith('.exe'))) {
          LogService().log('Deleting: $path');
          await entity.delete();
        }
      }
    }
  }

  /// Clear partial downloads
  Future<void> clearPartialDownloads() async {
    if (kIsWeb) return;

    try {
      final tempDir = await getTemporaryDirectory();
      final dir = Directory(tempDir.path);

      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.partial')) {
          LogService().log('Deleting partial download: ${entity.path}');
          await entity.delete();
        }
      }
    } catch (e) {
      LogService().log('Error clearing partial downloads: $e');
    }
  }

  /// Rollback to a specific backup
  Future<bool> rollback(BackupInfo backup) async {
    if (kIsWeb) return false;

    try {
      if (!await File(backup.path).exists()) {
        LogService().log('Backup file not found: ${backup.path}');
        return false;
      }

      LogService().log('Rolling back to: ${backup.filename}');

      if (Platform.isAndroid) {
        // On Android, reinstall the backup APK via system installer
        final canInstall = await canInstallPackages();
        if (!canInstall) {
          LogService().log('Install permission not granted for rollback');
          return false;
        }

        final result = await _updateChannel.invokeMethod<bool>(
          'installApk',
          {'filePath': backup.path},
        );

        if (result == true) {
          LogService().log('Rollback APK installer launched');
          return true;
        } else {
          LogService().log('Failed to launch rollback APK installer');
          return false;
        }
      }

      // Desktop platforms: rollback not supported (feature should be hidden)
      LogService().log('Rollback not supported on this platform');
      return false;
    } catch (e) {
      LogService().log('Error during rollback: $e');
      return false;
    }
  }

  /// Delete a specific backup (deletes entire version directory)
  Future<bool> deleteBackup(BackupInfo backup) async {
    if (kIsWeb) return false;

    try {
      if (backup.version == null) return false;

      final updatesDir = await getUpdatesDirectory();
      final versionDir = Directory('$updatesDir/${backup.version}');

      if (await versionDir.exists()) {
        await versionDir.delete(recursive: true);

        // Also delete pinned marker if it exists
        final pinnedMarker = File('$updatesDir/${backup.version}.pinned');
        if (await pinnedMarker.exists()) {
          await pinnedMarker.delete();
        }

        LogService().log('Deleted backup version: ${backup.version}');
        return true;
      }
      return false;
    } catch (e) {
      LogService().log('Error deleting backup: $e');
      return false;
    }
  }

  /// Pin a backup to prevent auto-deletion during cleanup
  /// Uses directory-level marker: {updatesDir}/{version}.pinned
  Future<bool> pinBackup(BackupInfo backup) async {
    if (kIsWeb) return false;

    try {
      if (backup.version == null) return false;

      final updatesDir = await getUpdatesDirectory();
      final pinnedMarker = File('$updatesDir/${backup.version}.pinned');
      await pinnedMarker.writeAsString(DateTime.now().toIso8601String());
      LogService().log('Pinned version: ${backup.version}');
      return true;
    } catch (e) {
      LogService().log('Error pinning backup: $e');
      return false;
    }
  }

  /// Unpin a backup to allow auto-deletion during cleanup
  /// Uses directory-level marker: {updatesDir}/{version}.pinned
  Future<bool> unpinBackup(BackupInfo backup) async {
    if (kIsWeb) return false;

    try {
      if (backup.version == null) return false;

      final updatesDir = await getUpdatesDirectory();
      final pinnedMarker = File('$updatesDir/${backup.version}.pinned');
      if (await pinnedMarker.exists()) {
        await pinnedMarker.delete();
        LogService().log('Unpinned version: ${backup.version}');
      }
      return true;
    } catch (e) {
      LogService().log('Error unpinning backup: $e');
      return false;
    }
  }

  /// Toggle pin status of a backup
  Future<bool> togglePinBackup(BackupInfo backup) async {
    if (backup.isPinned) {
      return await unpinBackup(backup);
    } else {
      return await pinBackup(backup);
    }
  }

  /// Check if currently checking for updates
  bool get isChecking => _isChecking;

  /// Check if currently downloading
  bool get isDownloading => _isDownloading;

  /// Get current download progress (0.0 to 1.0)
  double get currentDownloadProgress => _downloadProgress;

  /// Check if a download is completed and ready to install
  bool get hasCompletedDownload => _completedDownloadPath != null;

  /// Get the completed download path (if any)
  String? get completedDownloadPath => _completedDownloadPath;

  /// Get the version of the completed download (if any)
  String? get completedDownloadVersion => _completedDownloadVersion;

  /// Clear the completed download state (call after successful install or when user cancels)
  void clearCompletedDownload() {
    _completedDownloadPath = null;
    _completedDownloadVersion = null;
    LogService().log('Cleared completed download state');
  }

  /// Check if a completed download file exists for a given release version
  /// Returns the file path if found, null otherwise
  Future<String?> findCompletedDownload(ReleaseInfo release) async {
    if (kIsWeb) return null;

    try {
      final platform = detectPlatform();
      final extension = platform == UpdatePlatform.windows
          ? '.exe'
          : platform == UpdatePlatform.android
              ? '.apk'
              : '';

      // Check primary temp directory
      final tempDir = await getTemporaryDirectory();
      final tempFilePath = '${tempDir.path}${Platform.pathSeparator}geogram-update-${release.version}$extension';
      if (await File(tempFilePath).exists()) {
        LogService().log('Found completed download at: $tempFilePath');
        return tempFilePath;
      }

      // Also check external cache on Android
      if (Platform.isAndroid) {
        final externalCacheDirs = await getExternalCacheDirectories();
        if (externalCacheDirs != null && externalCacheDirs.isNotEmpty) {
          final externalPath = '${externalCacheDirs.first.path}${Platform.pathSeparator}geogram-update-${release.version}$extension';
          if (await File(externalPath).exists()) {
            LogService().log('Found completed download at: $externalPath');
            return externalPath;
          }
        }
      }
    } catch (e) {
      LogService().log('Error checking for completed download: $e');
    }

    return null;
  }

  /// Check if app can install packages (Android 8.0+ permission)
  Future<bool> canInstallPackages() async {
    if (kIsWeb || !Platform.isAndroid) return true;

    try {
      final result = await _updateChannel.invokeMethod<bool>('canInstallPackages');
      return result ?? false;
    } catch (e) {
      LogService().log('Error checking install permission: $e');
      return false;
    }
  }

  /// Open system settings to enable installing unknown apps (Android 8.0+)
  Future<void> openInstallPermissionSettings() async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      await _updateChannel.invokeMethod('openInstallPermissionSettings');
    } catch (e) {
      LogService().log('Error opening install permission settings: $e');
    }
  }

  /// Apply downloaded update (platform-specific)
  Future<bool> applyUpdate(String updateFilePath) async {
    if (kIsWeb) return false;

    try {
      final platform = detectPlatform();

      if (platform == UpdatePlatform.android) {
        // On Android 8.0+, check if we have permission to install packages
        final canInstall = await canInstallPackages();
        if (!canInstall) {
          LogService().log('Install permission not granted, opening settings...');
          await openInstallPermissionSettings();
          return false;
        }

        // Create backup of current APK before installing new one
        LogService().log('Creating backup before update...');
        await createBackup();

        // On Android, launch the APK installer via method channel
        LogService().log('Launching APK installer for: $updateFilePath');
        try {
          final result = await _updateChannel.invokeMethod<bool>(
            'installApk',
            {'filePath': updateFilePath},
          );
          if (result == true) {
            LogService().log('APK installer launched successfully');
            return true;
          } else {
            LogService().log('Failed to launch APK installer');
            return false;
          }
        } catch (e) {
          LogService().log('Error launching APK installer: $e');
          return false;
        }
      }

      // Create backup first (desktop only)
      await createBackup();

      final currentBinary = await _getCurrentBinaryPath();
      if (currentBinary == null) {
        LogService().log('Current binary not found');
        return false;
      }

      // For desktop platforms, replace the binary
      LogService().log('Applying update: $updateFilePath -> $currentBinary');
      await File(updateFilePath).copy(currentBinary);

      // Make executable on Unix systems
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', ['+x', currentBinary]);
      }

      // Cleanup temp file
      await File(updateFilePath).delete();

      LogService().log('Update applied successfully. Restart required.');
      return true;
    } catch (e) {
      LogService().log('Error applying update: $e');
      return false;
    }
  }
}
