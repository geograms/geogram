import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/monitored_task.dart';
import '../util/managed_http_client.dart';
import '../util/task_monitor_helpers.dart';
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
  bool _latestReleaseReady = false;
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

  /// Notifier for completed download path (null when not ready)
  final ValueNotifier<String?> completedDownloadPathNotifier = ValueNotifier(null);

  /// Flag to indicate if the UpdatePage is currently visible
  /// When true, the update banner should not be shown
  bool isUpdatePageVisible = false;

  /// Progress update throttling - only update UI every 100ms or 1% change
  DateTime _lastProgressUpdate = DateTime.now();
  double _lastProgressValue = 0.0;
  static const _progressUpdateInterval = Duration(milliseconds: 100);
  static const _progressMinChange = 0.01; // 1%

  /// Periodic update checking timer
  MonitoredAsyncPeriodicTimer? _periodicCheckTimer;
  static const _periodicCheckInterval = Duration(minutes: 30);

  /// Track pending desktop update (staged but not yet applied — Linux or Windows)
  ({String scriptPath, String version, String appDir})? _pendingDesktopUpdate;

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
        // Start periodic checking in the background
        _startPeriodicChecking();
      } else {
        // If auto-check is disabled, still restore last known state for display
        final lastCheckedVersion = _settings?.lastCheckedVersion;
        if (lastCheckedVersion != null && lastCheckedVersion.isNotEmpty) {
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

          _latestReleaseReady = _settings?.lastCheckedAssetAvailable ?? false;

          final wasUpdateAvailable = isNewerVersion(getCurrentVersion(), lastCheckedVersion);
          updateAvailable.value = wasUpdateAvailable && _latestReleaseReady;
          if (updateAvailable.value) {
            LogService().log('Restored update available state: $lastCheckedVersion > ${getCurrentVersion()}');
          }
        }
      }

      // Whether or not auto-check is enabled, an APK from a prior session
      // may already be on disk waiting to install. Recover that state now
      // so the install button is blue immediately on app open — without
      // this, the user sees a grey button until a fresh GitHub round-trip
      // succeeds, which never happens offline.
      unawaited(recoverCompletedDownloadFromDisk());
    } catch (e) {
      LogService().log('Error initializing UpdateService: $e');
    }
  }

  /// Start periodic background checking for updates
  void _startPeriodicChecking() {
    _periodicCheckTimer?.cancel();
    _periodicCheckTimer = MonitoredAsyncPeriodicTimer(
      id: 'update.periodic_check',
      name: 'Update Check',
      description: 'Periodic check for app updates',
      serviceName: 'UpdateService',
      interval: _periodicCheckInterval,
      priority: TaskPriority.low,
      callback: (_) async {
        if (!_isChecking && !_isDownloading) {
          LogService().log('UpdateService: Periodic update check triggered');
          await checkForUpdates();
        }
      },
    );
    LogService().log('UpdateService: Started periodic checking (every ${_periodicCheckInterval.inMinutes} minutes)');
  }

  /// Stop periodic checking (call when disposing if needed)
  void stopPeriodicChecking() {
    _periodicCheckTimer?.cancel();
    _periodicCheckTimer = null;
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

  /// Persist a dismissed update version so we don't notify again until newer
  Future<void> dismissUpdateNotification(String version) async {
    if (version.isEmpty) return;
    if (_settings?.dismissedUpdateVersion == version) return;
    _settings = _settings?.copyWith(dismissedUpdateVersion: version);
    _saveSettings();
  }

  /// Whether we should notify for this release (respects dismissal)
  bool shouldNotifyForRelease(ReleaseInfo release) {
    final dismissed = _settings?.dismissedUpdateVersion;
    if (dismissed == null || dismissed.isEmpty) return true;
    return isNewerVersion(dismissed, release.version);
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
      ReleaseInfo? release;

      // Try station first if enabled (offgrid-first)
      if (_settings?.useStationForUpdates == true) {
        release = await _checkStationForUpdates();
        if (release == null) {
          LogService().log('Station update check failed or unavailable, falling back to GitHub');
        }
      }

      // Fall back to GitHub (or use directly if station disabled)
      release ??= await _checkGitHubForUpdates();

      if (release != null) {
        _latestRelease = release;
        await _updateCheckResult(release);

        // Mirror all platform binaries in the background for the download page
        _mirrorAllPlatformBinaries(release);
      }

      return release;
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
      final channel = (_settings?.betaUpdatesEnabled ?? false) ? 'beta' : 'stable';
      final updateUrl = '$httpUrl/api/updates/latest?channel=$channel';

      LogService().log('Checking station for updates: $updateUrl');

      final response = await http.get(
        Uri.parse(updateUrl),
        headers: {'User-Agent': 'Geogram-Updater'},
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
      final betaEnabled = _settings?.betaUpdatesEnabled ?? false;

      // Beta: fetch newest release (may be prerelease) via /releases?per_page=1
      // Stable: fetch latest stable via /releases/latest (GitHub filters out prereleases)
      final url = betaEnabled
          ? 'https://api.github.com/repos/geograms/geogram/releases?per_page=1'
          : (_settings?.updateUrl ??
              'https://api.github.com/repos/geograms/geogram/releases/latest');

      LogService().log('Checking GitHub for updates: $url (channel: ${betaEnabled ? "beta" : "stable"})');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'Geogram-Updater',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch release info: HTTP ${response.statusCode}');
      }

      if (betaEnabled) {
        // /releases?per_page=1 returns an array
        final list = jsonDecode(response.body) as List<dynamic>;
        if (list.isEmpty) return null;
        return ReleaseInfo.fromGitHubJson(list[0] as Map<String, dynamic>);
      } else {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return ReleaseInfo.fromGitHubJson(json);
      }
    } catch (e) {
      LogService().log('Error checking GitHub for updates: $e');
      return null;
    }
  }

  /// Ensure platform binaries are mirrored locally for the download page.
  /// If release info is already cached, mirrors directly; otherwise triggers
  /// checkForUpdates() which will mirror as a side-effect.
  void ensureBinariesMirrored() {
    if (_latestRelease != null) {
      _mirrorAllPlatformBinaries(_latestRelease!);
    } else {
      checkForUpdates();
    }
  }

  /// Mirror all platform binaries (Android, Linux, Windows) to the local
  /// updates directory so the download page can serve them to other devices.
  /// Runs in the background — does not block the update check flow.
  void _mirrorAllPlatformBinaries(ReleaseInfo release) {
    // Fire-and-forget — log errors but don't block
    _mirrorAllPlatformBinariesAsync(release).catchError((e) {
      LogService().log('Error mirroring platform binaries: $e');
    });
  }

  bool _isMirroring = false;

  Future<void> _mirrorAllPlatformBinariesAsync(ReleaseInfo release) async {
    if (_isMirroring || kIsWeb) return;
    _isMirroring = true;

    try {
      final updatesDir = await getUpdatesDirectory();
      final versionDir = Directory('$updatesDir/${release.version}');
      if (!await versionDir.exists()) {
        await versionDir.create(recursive: true);
      }

      // Save release.json locally so the download page can read it
      final releaseJson = {
        'status': 'available',
        'version': release.version,
        'tagName': release.tagName,
        'name': release.name,
        'body': release.body,
        'publishedAt': release.publishedAt,
        'htmlUrl': release.htmlUrl,
        'assets': release.assets,
        'assetFilenames': release.assetFilenames,
      };
      await File('$updatesDir/release.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(releaseJson));

      // Download each platform binary that we don't already have
      // Only mirror the main platforms: Android, Linux Desktop, Windows Desktop
      const targetTypes = [
        UpdateAssetType.androidApk,
        UpdateAssetType.linuxDesktop,
        UpdateAssetType.windowsDesktop,
      ];

      int downloaded = 0;
      int skipped = 0;

      for (final assetType in targetTypes) {
        final url = release.getAssetUrl(assetType);
        final filename = release.assetFilenames[assetType.name];
        if (url == null || filename == null) continue;

        final targetFile = File('${versionDir.path}/$filename');
        if (await targetFile.exists() && await targetFile.length() > 1000) {
          skipped++;
          continue;
        }

        try {
          LogService().log('Mirroring ${assetType.name}: $filename');
          final result = await streamDownloadToFile(
            Uri.parse(url),
            targetFile.path,
            headers: {'User-Agent': 'Geogram-Updater'},
            timeout: const Duration(minutes: 10),
          );

          if (result.success) {
            downloaded++;
            LogService().log('Mirrored $filename (${(result.bytesWritten / (1024 * 1024)).toStringAsFixed(1)}MB)');
          }
        } catch (e) {
          LogService().log('Failed to mirror $filename: $e');
        }
      }

      if (downloaded > 0 || skipped > 0) {
        LogService().log('Binary mirror: $downloaded new, $skipped existing');
      }

      // Clean up old version directories, keep only the latest
      await _cleanupOldMirroredVersions(updatesDir, release.version);
    } finally {
      _isMirroring = false;
    }
  }

  /// Remove old version directories, keeping only the latest mirrored version
  /// and the current running version.
  Future<void> _cleanupOldMirroredVersions(String updatesDir, String keepVersion) async {
    try {
      final dir = Directory(updatesDir);
      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final name = entity.path.split('/').last;
          // Skip if it's the version we want to keep or the current app version
          if (name == keepVersion || name == appVersion) continue;
          // Only delete version-looking directories
          if (RegExp(r'^\d+\.\d+').hasMatch(name)) {
            // Check if pinned
            final pinnedMarker = File('$updatesDir/$name.pinned');
            if (await pinnedMarker.exists()) continue;

            LogService().log('Removing old mirrored version: $name');
            await entity.delete(recursive: true);
          }
        }
      }
    } catch (e) {
      LogService().log('Error cleaning up old mirrored versions: $e');
    }
  }

  /// Update settings and notify after successful check
  Future<void> _updateCheckResult(ReleaseInfo release) async {
    final hasAsset = await _isReleaseAvailableForPlatform(release);
    _latestReleaseReady = hasAsset;

    _settings = _settings?.copyWith(
      lastCheckTime: DateTime.now(),
      lastCheckedVersion: release.version,
      lastCheckedReleaseBody: release.body,
      lastCheckedHtmlUrl: release.htmlUrl,
      lastCheckedStationUrl: release.stationBaseUrl,
      lastCheckedPublishedAt: release.publishedAt,
      lastCheckedAssetAvailable: hasAsset,
    );
    _saveSettings();

    final currentVersion = getCurrentVersion();
    final isNewer = isNewerVersion(currentVersion, release.version);
    final updateReady = isNewer && hasAsset;
    updateAvailable.value = updateReady;

    // If current version matches the latest release, save its release date
    if (!isNewer && release.publishedAt != null) {
      _settings = _settings?.copyWith(
        currentVersionPublishedAt: release.publishedAt,
      );
      _saveSettings();
    }

    LogService().log(
        'Update check complete: current=$appVersion, latest=${release.version}, assetReady=$hasAsset, updateAvailable=$updateReady');

    // After every successful check, sync `_completedDownloadPath` with what's
    // on disk for this release. Covers the periodic-check cycle so the
    // install button lights up as soon as the new release is observed and
    // the matching APK is found, without waiting for the user to navigate
    // to the Updates page.
    unawaited(recoverCompletedDownloadFromDisk());

    if (updateReady) {
      unawaited(_maybeAutoDownload(release));

      // Auto-install for debug builds with auto-install enabled
      if (_settings?.autoInstallEnabled == true && !kIsWeb && Platform.isAndroid) {
        unawaited(_autoInstallDebugApk(release));
      }
    }
  }

  /// Auto-install debug APK for unattended station devices.
  /// Downloads the debug APK and runs `pm install -r` to install silently.
  Future<void> _autoInstallDebugApk(ReleaseInfo release) async {
    try {
      // Get the debug APK URL
      final debugUrl = release.getAssetUrl(UpdateAssetType.androidDebug);
      if (debugUrl == null || debugUrl.isEmpty) {
        LogService().log('Auto-install: no debug APK available for ${release.version}');
        return;
      }

      LogService().log('Auto-install: downloading debug APK for ${release.version}...');

      // Download to a temp location
      final dir = await getApplicationDocumentsDirectory();
      final apkPath = '${dir.path}/geogram-debug-${release.version}.apk';

      final result = await streamDownloadToFile(
        Uri.parse(debugUrl),
        apkPath,
        headers: {'User-Agent': 'Geogram-Updater'},
        timeout: const Duration(minutes: 15),
      );

      if (!result.success) {
        LogService().log('Auto-install: download failed');
        return;
      }

      LogService().log('Auto-install: installing ${release.version} via pm install...');
      final installResult = await Process.run('pm', ['install', '-r', apkPath]);

      if (installResult.exitCode == 0) {
        LogService().log('Auto-install: success! App will restart.');
      } else {
        LogService().log('Auto-install: pm install failed (exit ${installResult.exitCode}): ${installResult.stderr}');
      }

      // Clean up APK file
      try { await File(apkPath).delete(); } catch (_) {}
    } catch (e) {
      LogService().log('Auto-install error: $e');
    }
  }

  Future<void> _maybeAutoDownload(ReleaseInfo release) async {
    if (_settings?.autoDownloadUpdates != true) return;
    if (_isDownloading) return;

    // If we have a completed download for a DIFFERENT (older) version, clean it up
    if (_completedDownloadVersion != null &&
        _completedDownloadVersion != release.version &&
        _completedDownloadPath != null) {
      LogService().log('Cleaning up old download for v$_completedDownloadVersion (new version: ${release.version})');
      await _cleanupOldDownload(_completedDownloadPath!);
      _setCompletedDownload(null, null);
    }

    // Clean up any other old version files in temp directory
    await _cleanupOldDownloads(release.version);

    if (_completedDownloadVersion == release.version &&
        _completedDownloadPath != null &&
        await File(_completedDownloadPath!).exists()) {
      return;
    }

    final existing = await findCompletedDownload(release);
    if (existing != null) {
      _setCompletedDownload(existing, release.version);
      return;
    }

    final downloadPath = await downloadUpdate(release);
    if (downloadPath != null) {
      _setCompletedDownload(downloadPath, release.version);
    }
  }

  /// Clean up a single old download file
  Future<void> _cleanupOldDownload(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        LogService().log('Cleaned up old download: $path');
      }
    } catch (e) {
      LogService().log('Error cleaning up old download: $e');
    }
  }

  /// Clean up all old version download files, keeping only the specified version
  Future<void> _cleanupOldDownloads(String keepVersion) async {
    if (kIsWeb) return;

    try {
      final tempDir = await getTemporaryDirectory();
      await _cleanupDownloadsInDir(tempDir as dynamic, keepVersion);

      // Also clean external cache on Android
      if (Platform.isAndroid) {
        final externalCacheDirs = await getExternalCacheDirectories();
        if (externalCacheDirs != null) {
          for (final dir in externalCacheDirs) {
            await _cleanupDownloadsInDir(dir as dynamic, keepVersion);
          }
        }
      }
    } catch (e) {
      LogService().log('Error cleaning up old downloads: $e');
    }
  }

  /// Clean up old update files in a specific directory
  Future<void> _cleanupDownloadsInDir(dynamic dir, String keepVersion) async {
    try {
      final files = dir.listSync();
      for (final entity in files) {
        if (entity is File) {
          final name = entity.path.split(Platform.pathSeparator).last;
          // Match geogram-update-{version}.{ext} or geogram-update-{version}.{ext}.partial
          if (name.startsWith('geogram-update-') && !name.contains(keepVersion)) {
            await entity.delete();
            LogService().log('Deleted old update file: $name');
          }
        }
      }
    } catch (e) {
      // Ignore errors during cleanup (file might be in use, etc.)
    }
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
      // Strip leading 'v' and split off pre-release suffix (e.g. "1.37.0-beta.3" -> "1.37.0" + "beta.3")
      final currentClean = currentVersion.replaceFirst(RegExp(r'^v'), '');
      final newClean = newVersion.replaceFirst(RegExp(r'^v'), '');

      final currentBase = currentClean.split('-')[0];
      final newBase = newClean.split('-')[0];

      final currentHasPreRelease = currentClean.contains('-');
      final newHasPreRelease = newClean.contains('-');

      final current = currentBase.split('.');
      final newVer = newBase.split('.');

      final maxLen = current.length > newVer.length ? current.length : newVer.length;

      for (var i = 0; i < maxLen; i++) {
        final c = i < current.length ? int.tryParse(current[i]) ?? 0 : 0;
        final n = i < newVer.length ? int.tryParse(newVer[i]) ?? 0 : 0;

        if (n > c) return true;
        if (n < c) return false;
      }

      // Same base version. Apply semver §11 prerelease ordering:
      //   1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-beta < 1.0.0-beta.2 < 1.0.0
      if (!currentHasPreRelease && !newHasPreRelease) return false;
      if (currentHasPreRelease && !newHasPreRelease) return true;
      if (!currentHasPreRelease && newHasPreRelease) return false;
      final currentPre = currentClean.substring(currentBase.length + 1);
      final newPre = newClean.substring(newBase.length + 1);
      return _isPrereleaseNewer(currentPre, newPre);
    } catch (e) {
      LogService().log('Version comparison failed: $currentVersion vs $newVersion');
    }

    return false;
  }

  /// Compare two semver prerelease suffixes (the part after "-"). Returns
  /// true if [newPre] is ordered higher than [currentPre].
  ///
  /// Semver §11.4: identifiers compared left-to-right — numeric compared
  /// numerically, alphanumeric compared lexically in ASCII order, numeric
  /// identifiers always have lower precedence than alphanumeric ones, and
  /// a longer set of identifiers is higher than a shorter prefix-matching
  /// set (e.g. "beta" < "beta.1").
  bool _isPrereleaseNewer(String currentPre, String newPre) {
    if (currentPre == newPre) return false;
    final cur = currentPre.split('.');
    final nw = newPre.split('.');
    final shared = cur.length < nw.length ? cur.length : nw.length;
    for (var i = 0; i < shared; i++) {
      final c = cur[i];
      final n = nw[i];
      if (c == n) continue;
      final cNum = int.tryParse(c);
      final nNum = int.tryParse(n);
      if (cNum != null && nNum != null) return nNum > cNum;
      if (cNum != null) return true; // numeric < alphanumeric
      if (nNum != null) return false;
      return n.compareTo(c) > 0;
    }
    return nw.length > cur.length;
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

    // On Windows, prefer the setup.exe installer over the ZIP
    if (!kIsWeb && Platform.isWindows) {
      final setupUrl = release.getAssetUrl(UpdateAssetType.windowsSetup);
      if (setupUrl != null) return setupUrl;
    }

    // Use asset URL (works for both station and GitHub releases)
    return release.getAssetUrl(assetType);
  }

  /// Check if a release has a downloadable asset for the current platform
  Future<bool> _isReleaseAvailableForPlatform(ReleaseInfo release) async {
    if (kIsWeb) return false;

    final downloadUrl = getDownloadUrl(release);
    if (downloadUrl == null || downloadUrl.isEmpty) {
      return false;
    }

    // If a custom download pattern is used, verify the URL exists.
    if (_settings?.downloadUrlPattern.isNotEmpty == true) {
      return await _checkAssetUrlExists(downloadUrl);
    }

    return true;
  }

  Future<bool> _checkAssetUrlExists(String url) async {
    try {
      final response = await http.head(
        Uri.parse(url),
        headers: {'User-Agent': 'Geogram-Updater'},
      ).timeout(const Duration(seconds: 15));
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (e) {
      LogService().log('Update asset check failed: $e');
      return false;
    }
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
    if (!kIsWeb && Platform.isWindows) return 'geogram.exe';
    return 'geogram'; // Linux, macOS
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
            name == 'geogram' || name.startsWith('geogram')) {
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

    if (_completedDownloadVersion == release.version &&
        _completedDownloadPath != null) {
      final existingFile = File(_completedDownloadPath!);
      if (await existingFile.exists()) {
        return _completedDownloadPath;
      }
      clearCompletedDownload();
    }

    final existingDownload = await findCompletedDownload(release);
    if (existingDownload != null) {
      _setCompletedDownload(existingDownload, release.version);
      return existingDownload;
    }

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
      // On Windows, if we're downloading the setup.exe, use .exe extension
      final bool isWindowsSetup = !kIsWeb && Platform.isWindows &&
          release.getAssetUrl(UpdateAssetType.windowsSetup) != null;
      final extension = platform == UpdatePlatform.android
          ? '.apk'
          : isWindowsSetup
              ? '.exe'
              : platform == UpdatePlatform.windows || platform == UpdatePlatform.macos
                  ? '.zip'
                  : platform == UpdatePlatform.linux
                      ? '.tar.gz'
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
        headers: {'User-Agent': 'Geogram-Updater'},
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
        // Same in-memory state update as the normal completion path below —
        // without this, the `completedDownloadPathNotifier` never fires and
        // any UI listening for it (the update banner, the install button)
        // misses the transition.
        _setCompletedDownload(tempFilePath, release.version);
        return tempFilePath;
      }

      // Create HTTP client for better connection management
      return await withHttpClient((client) async {
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
        _setCompletedDownload(tempFilePath, release.version);

        LogService().log('Downloaded $downloaded bytes to $tempFilePath');
        return tempFilePath;
      });
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
             path.endsWith('.exe') || path.endsWith('.zip') ||
             path.endsWith('.tar.gz'))) {
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

  /// Check if the latest release is a newer version with an available asset
  bool get isLatestUpdateReady {
    if (_latestRelease == null) return false;
    if (!_latestReleaseReady) return false;
    return isNewerVersion(getCurrentVersion(), _latestRelease!.version);
  }

  /// Get current download progress (0.0 to 1.0)
  double get currentDownloadProgress => _downloadProgress;

  /// Check if a download is completed and ready to install
  bool get hasCompletedDownload => _completedDownloadPath != null;

  /// Get the completed download path (if any)
  String? get completedDownloadPath => _completedDownloadPath;

  /// Get the version of the completed download (if any)
  String? get completedDownloadVersion => _completedDownloadVersion;

  void _setCompletedDownload(String? path, String? version) {
    _completedDownloadPath = path;
    _completedDownloadVersion = version;
    completedDownloadPathNotifier.value = path;
  }

  void restoreCompletedDownload(String path, String version) {
    _setCompletedDownload(path, version);
    LogService().log('Restored completed download: v$version at $path');
  }

  /// Clear the completed download state (call after successful install or when user cancels)
  void clearCompletedDownload() {
    _setCompletedDownload(null, null);
    LogService().log('Cleared completed download state');
  }

  /// If we don't have an in-memory `_completedDownloadPath` but a matching
  /// APK is already on disk for the known latest release, recover the state.
  ///
  /// Without this, on Android the install button stays grey across app
  /// restarts — the in-memory `_completedDownloadPath` is process-local and
  /// the previous-only path that recovered it (`UpdatePage._checkForUpdatesInBackground`)
  /// runs the disk scan only after a successful GitHub round-trip.
  /// Offline / slow network / dismissed page = APK on disk, button never blue.
  Future<void> recoverCompletedDownloadFromDisk() async {
    if (_completedDownloadPath != null) return;
    final release = _latestRelease;
    if (release == null) return;
    try {
      final foundPath = await findCompletedDownload(release);
      if (foundPath != null) {
        _setCompletedDownload(foundPath, release.version);
        LogService().log(
            'Recovered completed download from disk: v${release.version} at $foundPath');
      }
    } catch (e) {
      LogService().log('Error recovering completed download: $e');
    }
  }

  /// Check if a completed download file exists for a given release version
  /// Returns the file path if found, null otherwise
  Future<String?> findCompletedDownload(ReleaseInfo release) async {
    if (kIsWeb) return null;

    try {
      final platform = detectPlatform();
      // On Windows, check for setup.exe first, then fall back to .zip
      final bool isWindowsSetup = !kIsWeb && Platform.isWindows &&
          release.getAssetUrl(UpdateAssetType.windowsSetup) != null;
      final extension = platform == UpdatePlatform.android
          ? '.apk'
          : isWindowsSetup
              ? '.exe'
              : platform == UpdatePlatform.windows || platform == UpdatePlatform.macos
                  ? '.zip'
                  : platform == UpdatePlatform.linux
                      ? '.tar.gz'
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
  /// If [expectedVersion] is provided, validates that it's newer than the current version
  Future<bool> applyUpdate(String updateFilePath, {String? expectedVersion}) async {
    if (kIsWeb) return false;

    // Validate version if provided - prevent installing same/older version
    if (expectedVersion != null) {
      if (!isNewerVersion(getCurrentVersion(), expectedVersion)) {
        LogService().log('Skipping install: version $expectedVersion is not newer than ${getCurrentVersion()}');
        return false;
      }
    }

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

      // Linux requires staged update (can't replace running binary)
      if (Platform.isLinux) {
        return await _stageLinuxUpdate(updateFilePath, expectedVersion);
      }

      // Windows: use Inno Setup installer if we downloaded setup.exe,
      // fall back to old staged update for ZIP files
      if (Platform.isWindows) {
        if (updateFilePath.endsWith('.exe')) {
          return await _runWindowsInstaller(updateFilePath);
        }
        return await _stageWindowsUpdate(updateFilePath, expectedVersion);
      }

      final currentBinary = await _getCurrentBinaryPath();
      if (currentBinary == null) {
        LogService().log('Current binary not found');
        return false;
      }

      // For macOS, replace the binary directly (Unix inode semantics allow this)
      LogService().log('Applying update: $updateFilePath -> $currentBinary');
      await File(updateFilePath).copy(currentBinary);

      // Make executable on Unix systems
      if (Platform.isMacOS) {
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

  // ============================================================
  // Linux-specific update methods
  // ============================================================

  /// Check if there's a pending desktop update ready to apply
  bool get hasPendingDesktopUpdate => _pendingDesktopUpdate != null;

  /// Get the pending desktop update info
  ({String scriptPath, String version, String appDir})? get pendingDesktopUpdate =>
      _pendingDesktopUpdate;

  /// Check if we can write next to the current binary
  Future<bool> _canWriteNextToBinary() async {
    try {
      final binaryPath = Platform.resolvedExecutable;
      final binaryDir = File(binaryPath).parent.path;

      // Try to create a test file
      final testFile = File(
          '$binaryDir/.geogram-write-test-${DateTime.now().millisecondsSinceEpoch}');
      await testFile.writeAsString('test');
      await testFile.delete();
      return true;
    } catch (e) {
      LogService().log('Cannot write to binary directory: $e');
      return false;
    }
  }

  /// Stage update for Linux - extracts tar.gz and prepares full bundle replacement
  Future<bool> _stageLinuxUpdate(String updateFilePath, String? version) async {
    try {
      // Get the actual running binary path - works from ANY location
      final currentBinary = Platform.resolvedExecutable;
      if (!await File(currentBinary).exists()) {
        LogService().log('Current binary not found: $currentBinary');
        return false;
      }

      // Check write permission first
      if (!await _canWriteNextToBinary()) {
        LogService().log('No write permission to app directory');
        return false;
      }

      // App directory is where the binary lives (contains binary, data/, lib/)
      final appDir = File(currentBinary).parent.path;
      final stagingDir = Directory('$appDir/.geogram-update');

      // Clean up any previous failed update
      if (await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }
      await stagingDir.create(recursive: true);

      // Extract tar.gz to staging directory
      LogService().log('Extracting update archive to: ${stagingDir.path}');
      final extractResult = await Process.run(
        'tar',
        ['-xzf', updateFilePath, '-C', stagingDir.path],
      );

      if (extractResult.exitCode != 0) {
        LogService().log('Failed to extract: ${extractResult.stderr}');
        await stagingDir.delete(recursive: true);
        return false;
      }

      // Find the extracted bundle (might be in bundle/ subfolder or directly)
      String extractedPath = stagingDir.path;
      final bundleDir = Directory('${stagingDir.path}/bundle');
      if (await bundleDir.exists()) {
        extractedPath = bundleDir.path;
      }

      // Verify extracted files exist
      final extractedBinary = File('$extractedPath/geogram');
      final extractedData = Directory('$extractedPath/data');
      final extractedLib = Directory('$extractedPath/lib');

      if (!await extractedBinary.exists()) {
        LogService().log('Extracted binary not found at: $extractedPath/geogram');
        await stagingDir.delete(recursive: true);
        return false;
      }

      final hasData = await extractedData.exists();
      final hasLib = await extractedLib.exists();
      LogService().log(
          'Extracted: binary=true, data=$hasData, lib=$hasLib');

      // Get current process PID to pass to the script
      // (can't use $PPID in detached mode - it becomes PID 1)
      final currentPid = pid;

      // Create updater script with absolute paths and explicit PID
      final script = '''#!/bin/bash
# Geogram Update Script - Auto-generated
# Wait for app to exit, replace entire app bundle, restart

APP_DIR="$appDir"
EXTRACTED_DIR="$extractedPath"
STAGING_DIR="${stagingDir.path}"

# App PID passed from Dart (can't use \$PPID in detached mode)
APP_PID=$currentPid

# Wait for the app to exit (max 30 seconds)
for i in {1..30}; do
  if ! kill -0 \$APP_PID 2>/dev/null; then
    break
  fi
  sleep 1
done

# Extra wait to ensure file handles released
sleep 2

# Replace entire bundle
cd "\$APP_DIR"

# Remove old data and lib directories
rm -rf data lib

# Copy new files
cp "\$EXTRACTED_DIR/geogram" ./geogram
if [ -d "\$EXTRACTED_DIR/data" ]; then
  cp -r "\$EXTRACTED_DIR/data" ./data
fi
if [ -d "\$EXTRACTED_DIR/lib" ]; then
  cp -r "\$EXTRACTED_DIR/lib" ./lib
fi

# Make binary executable
chmod +x ./geogram

# Clean up staging
rm -rf "\$STAGING_DIR"

# Restart app (use absolute path)
nohup "\$APP_DIR/geogram" > /dev/null 2>&1 &
''';

      final scriptPath = '${stagingDir.path}/apply-update.sh';
      await File(scriptPath).writeAsString(script);
      await Process.run('chmod', ['+x', scriptPath]);

      // Save pending update info
      _pendingDesktopUpdate = (
        scriptPath: scriptPath,
        version: version ?? 'unknown',
        appDir: appDir,
      );

      // Clean up the downloaded tar.gz
      try {
        await File(updateFilePath).delete();
      } catch (_) {}

      LogService().log('Linux update staged in: ${stagingDir.path}');
      LogService().log('Will replace app at: $appDir');
      return true;
    } catch (e) {
      LogService().log('Error staging Linux update: $e');
      return false;
    }
  }

  // ============================================================
  // Windows-specific update methods
  // ============================================================

  /// Run the Inno Setup installer silently for Windows updates.
  /// The installer handles closing the old app, replacing files, and restarting.
  Future<bool> _runWindowsInstaller(String installerPath) async {
    try {
      final file = File(installerPath);
      if (!await file.exists()) {
        LogService().log('Windows installer not found: $installerPath');
        return false;
      }

      LogService().log('Launching Windows installer: $installerPath');
      await Process.start(
        installerPath,
        ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );

      // Exit so the installer can replace files
      LogService().log('Exiting app to let installer take over');
      exit(0);
    } catch (e) {
      LogService().log('Error running Windows installer: $e');
      return false;
    }
  }

  /// Stage update for Windows - extracts ZIP and prepares full bundle replacement
  /// (Legacy fallback for ZIP-based updates when no setup.exe is available)
  Future<bool> _stageWindowsUpdate(String updateFilePath, String? version) async {
    try {
      // Get the actual running binary path
      final currentBinary = Platform.resolvedExecutable;
      if (!await File(currentBinary).exists()) {
        LogService().log('Current binary not found: $currentBinary');
        return false;
      }

      // Check write permission first
      if (!await _canWriteNextToBinary()) {
        LogService().log('No write permission to app directory. '
            'If installed to Program Files, self-update is not supported.');
        return false;
      }

      // App directory is where the binary lives (contains geogram.exe, data/, lib/, DLLs)
      final appDir = File(currentBinary).parent.path;
      final stagingDir = Directory('$appDir\\.geogram-update');

      // Clean up any previous failed update
      if (await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }
      await stagingDir.create(recursive: true);

      // Extract ZIP to staging directory using the archive package
      LogService().log('Extracting update ZIP to: ${stagingDir.path}');
      final bytes = await File(updateFilePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      for (final file in archive) {
        final filePath = '${stagingDir.path}\\${file.name.replaceAll('/', '\\')}';
        if (file.isFile) {
          await File(filePath).create(recursive: true);
          await File(filePath).writeAsBytes(file.content as List<int>);
        } else {
          await Directory(filePath).create(recursive: true);
        }
      }

      // Find the extracted bundle (might be in bundle/ subfolder or directly)
      String extractedPath = stagingDir.path;
      final bundleDir = Directory('${stagingDir.path}\\bundle');
      if (await bundleDir.exists()) {
        extractedPath = bundleDir.path;
      }

      // Verify extracted files exist
      final extractedBinary = File('$extractedPath\\geogram.exe');
      if (!await extractedBinary.exists()) {
        LogService().log('Extracted binary not found at: $extractedPath\\geogram.exe');
        await stagingDir.delete(recursive: true);
        return false;
      }

      final extractedData = Directory('$extractedPath\\data');
      final extractedLib = Directory('$extractedPath\\lib');
      final hasData = await extractedData.exists();
      final hasLib = await extractedLib.exists();
      LogService().log(
          'Extracted: binary=true, data=$hasData, lib=$hasLib');

      // Get current process PID
      final currentPid = pid;

      // Create updater batch script
      final script = '''@echo off
REM Geogram Update Script - Auto-generated
REM Wait for app to exit, replace entire app bundle, restart

set "APP_DIR=$appDir"
set "EXTRACTED_DIR=$extractedPath"
set "STAGING_DIR=${stagingDir.path}"
set "APP_PID=$currentPid"

REM Wait for app to exit (max 30 seconds)
for /L %%i in (1,1,30) do (
  tasklist /FI "PID eq %APP_PID%" 2>NUL | find /I "%APP_PID%" >NUL
  if errorlevel 1 goto :done_waiting
  timeout /t 1 /nobreak >NUL
)
:done_waiting

REM Extra wait for file handle release
timeout /t 2 /nobreak >NUL

REM Replace bundle (preserves uninstaller, portable.marker, user data)
cd /d "%APP_DIR%"
xcopy "%EXTRACTED_DIR%\\*" "%APP_DIR%\\" /E /Y /Q

REM Clean up staging
rmdir /S /Q "%STAGING_DIR%"

REM Restart app
start "" "%APP_DIR%\\geogram.exe"
''';

      final scriptPath = '${stagingDir.path}\\apply-update.bat';
      await File(scriptPath).writeAsString(script);

      // Save pending update info
      _pendingDesktopUpdate = (
        scriptPath: scriptPath,
        version: version ?? 'unknown',
        appDir: appDir,
      );

      // Clean up the downloaded ZIP
      try {
        await File(updateFilePath).delete();
      } catch (_) {}

      LogService().log('Windows update staged in: ${stagingDir.path}');
      LogService().log('Will replace app at: $appDir');
      return true;
    } catch (e) {
      LogService().log('Error staging Windows update: $e');
      return false;
    }
  }

  /// Apply pending desktop update (launches script and exits app)
  Future<void> applyPendingDesktopUpdate() async {
    if (_pendingDesktopUpdate == null) return;

    final scriptPath = _pendingDesktopUpdate!.scriptPath;
    LogService().log('Launching update script: $scriptPath');

    // Launch script in background (detached from this process)
    if (Platform.isWindows) {
      await Process.start(
        'cmd',
        ['/c', scriptPath],
        mode: ProcessStartMode.detached,
      );
    } else {
      await Process.start(
        'bash',
        [scriptPath],
        mode: ProcessStartMode.detached,
      );
    }

    // Exit app - script will wait, replace binary, and restart
    exit(0);
  }

  /// Clear pending desktop update (if user cancels)
  Future<void> clearPendingDesktopUpdate() async {
    if (_pendingDesktopUpdate == null) return;

    try {
      final stagingDir = Directory(
          File(_pendingDesktopUpdate!.scriptPath).parent.path);
      if (await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }
    } catch (e) {
      LogService().log('Error cleaning up staged update: $e');
    }

    _pendingDesktopUpdate = null;
  }
}
