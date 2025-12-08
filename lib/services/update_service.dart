import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/update_settings.dart';
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
            // Create a minimal ReleaseInfo so the banner can show the version
            _latestRelease = ReleaseInfo(
              version: lastCheckedVersion,
              tagName: 'v$lastCheckedVersion',
              name: 'Version $lastCheckedVersion',
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

  /// Get backup directory path
  Future<String> getBackupDirectory() async {
    if (kIsWeb) {
      throw UnsupportedError('Backups not supported on web');
    }

    final appDir = await getApplicationSupportDirectory();
    final backupDir = Directory('${appDir.path}/rollback');

    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }

    return backupDir.path;
  }

  /// List available backups
  Future<List<BackupInfo>> listBackups() async {
    if (kIsWeb) return [];

    try {
      final backupPath = await getBackupDirectory();
      final backupDir = Directory(backupPath);

      if (!await backupDir.exists()) {
        return [];
      }

      final backups = <BackupInfo>[];
      await for (final entity in backupDir.list()) {
        // Accept both .backup (desktop) and .apk (Android) files
        if (entity is File &&
            (entity.path.endsWith('.backup') || entity.path.endsWith('.apk'))) {
          final stat = await entity.stat();
          final filename = entity.path.split(Platform.pathSeparator).last;

          // Parse version from filename: geogram-desktop.1.4.0.2024-12-02_10-30-00.backup
          String? version;
          final parts = filename.split('.');
          if (parts.length >= 4) {
            // Try to extract version
            for (var i = 1; i < parts.length - 1; i++) {
              if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(parts[i])) {
                // This is the timestamp, version is before it
                version = parts.sublist(1, i).join('.');
                break;
              }
            }
          }

          // Check if backup is pinned (via .pinned marker file)
          final pinnedMarker = File('${entity.path}.pinned');
          final isPinned = await pinnedMarker.exists();

          backups.add(BackupInfo(
            filename: filename,
            version: version,
            timestamp: stat.modified,
            sizeBytes: stat.size,
            path: entity.path,
            isPinned: isPinned,
          ));
        }
      }

      // Sort by timestamp, newest first
      backups.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      return backups;
    } catch (e) {
      LogService().log('Error listing backups: $e');
      return [];
    }
  }

  /// Create backup of current binary or APK
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

      final backupPath = await getBackupDirectory();
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')[0];

      // Use .apk extension for Android, .backup for desktop
      final extension = Platform.isAndroid ? '.apk' : '.backup';
      final backupName = 'geogram-desktop.$appVersion.$timestamp$extension';
      final backupFile = File('$backupPath${Platform.pathSeparator}$backupName');

      LogService().log('Creating backup: $sourceFile -> ${backupFile.path}');
      await File(sourceFile).copy(backupFile.path);

      // Cleanup old backups
      await _cleanupOldBackups();

      final stat = await backupFile.stat();
      return BackupInfo(
        filename: backupName,
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
  Future<void> _cleanupOldBackups() async {
    try {
      final backups = await listBackups();
      final maxBackups = _settings?.maxBackups ?? 5;

      // Separate pinned and unpinned backups
      final unpinnedBackups = backups.where((b) => !b.isPinned).toList();

      if (unpinnedBackups.length > maxBackups) {
        final toRemove = unpinnedBackups.sublist(maxBackups);
        for (final backup in toRemove) {
          LogService().log('Removing old backup: ${backup.filename}');
          await File(backup.path).delete();
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

  /// Delete a specific backup
  Future<bool> deleteBackup(BackupInfo backup) async {
    if (kIsWeb) return false;

    try {
      final file = File(backup.path);
      if (await file.exists()) {
        await file.delete();
        // Also delete pinned marker if it exists
        final pinnedMarker = File('${backup.path}.pinned');
        if (await pinnedMarker.exists()) {
          await pinnedMarker.delete();
        }
        LogService().log('Deleted backup: ${backup.filename}');
        return true;
      }
      return false;
    } catch (e) {
      LogService().log('Error deleting backup: $e');
      return false;
    }
  }

  /// Pin a backup to prevent auto-deletion during cleanup
  Future<bool> pinBackup(BackupInfo backup) async {
    if (kIsWeb) return false;

    try {
      final pinnedMarker = File('${backup.path}.pinned');
      await pinnedMarker.writeAsString(DateTime.now().toIso8601String());
      LogService().log('Pinned backup: ${backup.filename}');
      return true;
    } catch (e) {
      LogService().log('Error pinning backup: $e');
      return false;
    }
  }

  /// Unpin a backup to allow auto-deletion during cleanup
  Future<bool> unpinBackup(BackupInfo backup) async {
    if (kIsWeb) return false;

    try {
      final pinnedMarker = File('${backup.path}.pinned');
      if (await pinnedMarker.exists()) {
        await pinnedMarker.delete();
        LogService().log('Unpinned backup: ${backup.filename}');
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
