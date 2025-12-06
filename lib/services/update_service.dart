import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/update_settings.dart';
import '../services/config_service.dart';
import '../services/log_service.dart';
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

      // Auto-check for updates if enabled
      if (_settings?.autoCheckUpdates == true) {
        // Check if we haven't checked in the last 24 hours
        final lastCheck = _settings?.lastCheckTime;
        if (lastCheck == null ||
            DateTime.now().difference(lastCheck).inHours >= 24) {
          checkForUpdates();
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

  /// Check for updates from configured URL
  Future<ReleaseInfo?> checkForUpdates() async {
    if (_isChecking || kIsWeb) return null;

    _isChecking = true;
    try {
      final url = _settings?.updateUrl ??
          'https://api.github.com/repos/geograms/geogram-desktop/releases/latest';

      LogService().log('Checking for updates from: $url');

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

      // Update last check time
      _settings = _settings?.copyWith(
        lastCheckTime: DateTime.now(),
        lastCheckedVersion: _latestRelease?.version,
      );
      _saveSettings();

      // Check if update is available
      final isNewer = isNewerVersion(getCurrentVersion(), _latestRelease!.version);
      updateAvailable.value = isNewer;

      LogService().log(
          'Update check complete: current=$appVersion, latest=${_latestRelease?.version}, updateAvailable=$isNewer');

      return _latestRelease;
    } catch (e) {
      LogService().log('Error checking for updates: $e');
      return null;
    } finally {
      _isChecking = false;
    }
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

    // Check for custom download URL pattern
    if (_settings?.downloadUrlPattern.isNotEmpty == true) {
      return _settings!.downloadUrlPattern
          .replaceAll('{version}', release.version)
          .replaceAll('{platform}', platform.name)
          .replaceAll('{binary}', platform.binaryPattern);
    }

    // Use GitHub release asset
    return release.assets[platform.name];
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
        if (entity is File && entity.path.endsWith('.backup')) {
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

          backups.add(BackupInfo(
            filename: filename,
            version: version,
            timestamp: stat.modified,
            sizeBytes: stat.size,
            path: entity.path,
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

  /// Create backup of current binary
  Future<BackupInfo?> createBackup() async {
    if (kIsWeb) return null;

    try {
      final currentBinary = await _getCurrentBinaryPath();
      if (currentBinary == null || !await File(currentBinary).exists()) {
        LogService().log('Current binary not found for backup');
        return null;
      }

      final backupPath = await getBackupDirectory();
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')[0];
      final binaryName = currentBinary.split(Platform.pathSeparator).last;
      final backupName = '$binaryName.$appVersion.$timestamp.backup';
      final backupFile = File('$backupPath${Platform.pathSeparator}$backupName');

      LogService().log('Creating backup: $currentBinary -> ${backupFile.path}');
      await File(currentBinary).copy(backupFile.path);

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
  Future<void> _cleanupOldBackups() async {
    try {
      final backups = await listBackups();
      final maxBackups = _settings?.maxBackups ?? 5;

      if (backups.length > maxBackups) {
        final toRemove = backups.sublist(maxBackups);
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

      final tempDir = await getTemporaryDirectory();
      final platform = detectPlatform();
      final extension = platform == UpdatePlatform.windows
          ? '.exe'
          : platform == UpdatePlatform.android
              ? '.apk'
              : '';
      final tempFilePath =
          '${tempDir.path}${Platform.pathSeparator}geogram-update-${release.version}$extension';
      final partialFilePath = '$tempFilePath.partial';
      final tempFile = File(tempFilePath);
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

        // Use buffered writing for better performance
        final buffer = <int>[];
        const bufferSize = 65536; // 64KB buffer

        await for (final chunk in response.stream) {
          buffer.addAll(chunk);
          downloaded += chunk.length;

          // Write in larger chunks for better I/O performance
          if (buffer.length >= bufferSize) {
            sink.add(buffer);
            buffer.clear();
          }

          // Throttled progress update
          _bytesDownloaded = downloaded;
          if (totalSize > 0) {
            final progress = downloaded / totalSize;
            _updateProgressThrottled(progress, onProgress);
          }
        }

        // Write remaining buffer
        if (buffer.isNotEmpty) {
          sink.add(buffer);
        }

        await sink.flush();
        await sink.close();

        // Rename partial file to final name
        await partialFile.rename(tempFilePath);

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
      final currentBinary = await _getCurrentBinaryPath();
      if (currentBinary == null) {
        LogService().log('Current binary not found for rollback');
        return false;
      }

      if (!await File(backup.path).exists()) {
        LogService().log('Backup file not found: ${backup.path}');
        return false;
      }

      LogService().log('Rolling back to: ${backup.filename}');

      // Copy backup to current binary location
      await File(backup.path).copy(currentBinary);

      // Make executable on Unix systems
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', ['+x', currentBinary]);
      }

      LogService().log('Rollback complete. Restart required.');
      return true;
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
        LogService().log('Deleted backup: ${backup.filename}');
        return true;
      }
      return false;
    } catch (e) {
      LogService().log('Error deleting backup: $e');
      return false;
    }
  }

  /// Check if currently checking for updates
  bool get isChecking => _isChecking;

  /// Check if currently downloading
  bool get isDownloading => _isDownloading;

  /// Get current download progress (0.0 to 1.0)
  double get currentDownloadProgress => _downloadProgress;

  /// Apply downloaded update (platform-specific)
  Future<bool> applyUpdate(String updateFilePath) async {
    if (kIsWeb) return false;

    try {
      final platform = detectPlatform();

      if (platform == UpdatePlatform.android) {
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
