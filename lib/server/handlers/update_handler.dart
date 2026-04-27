// Update mirror HTTP handler for station server
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';

import '../station_settings.dart';
import '../../models/update_settings.dart' show UpdateAssetType;
import '../../util/managed_http_client.dart' show streamDownloadToFile;

/// MMDB database download URLs
class GeoIpUrls {
  static const String jsdelivrUrl = 'https://cdn.jsdelivr.net/npm/dbip-city-lite/dbip-city-lite.mmdb.gz';
  static const String dbipDirectUrl = 'https://download.db-ip.com resolving...';
  static const String dbipCityLiteUrl = 'https://download.db-ip.com/db-ip-city-lite.mmdb.gz';
}

/// Handler for update mirror endpoints
class UpdateHandler {
  final StationSettings Function() getSettings;
  final String updatesDirectory;
  final void Function(String, String) log;

  Map<String, dynamic>? _cachedRelease;
  bool _isDownloadingUpdates = false;
  bool _isDownloadingGeoip = false;
  Timer? _pollTimer;
  final Map<String, String> _downloadedAssets = {};
  final Map<String, String> _assetFilenames = {};

  UpdateHandler({
    required this.getSettings,
    required this.updatesDirectory,
    required this.log,
  });

  Map<String, dynamic>? get cachedRelease => _cachedRelease;
  bool get isDownloading => _isDownloadingUpdates;

  /// Handle GET /api/updates/latest
  Future<void> handleUpdatesLatest(HttpRequest request) async {
    final settings = getSettings();

    if (!settings.updateMirrorEnabled) {
      request.response.statusCode = 503;
      request.response.write(jsonEncode({'error': 'Update mirror disabled'}));
      return;
    }

    if (_cachedRelease == null) {
      request.response.statusCode = 503;
      request.response.write(jsonEncode({'error': 'No release info cached'}));
      return;
    }

    // Build response with local download URLs
    final release = Map<String, dynamic>.from(_cachedRelease!);
    final assets = release['assets'] as List<dynamic>?;

    if (assets != null) {
      final updatedAssets = <Map<String, dynamic>>[];
      for (final asset in assets) {
        final assetMap = Map<String, dynamic>.from(asset as Map<String, dynamic>);
        final name = assetMap['name'] as String?;

        // Check if we have this asset downloaded locally
        if (name != null && _downloadedAssets.containsKey(name)) {
          assetMap['local_url'] = '/updates/$name';
          assetMap['mirrored'] = true;
        }
        updatedAssets.add(assetMap);
      }
      release['assets'] = updatedAssets;
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(release));
  }

  /// Handle GET /updates/{filename}
  Future<void> handleUpdateDownload(HttpRequest request) async {
    final path = request.uri.path;
    final filename = path.substring('/updates/'.length);

    // Sanitize filename to prevent path traversal
    if (filename.contains('..') || filename.contains('/')) {
      request.response.statusCode = 400;
      request.response.write('Invalid filename');
      return;
    }

    final filePath = '$updatesDirectory/$filename';
    final file = File(filePath);

    if (!await file.exists()) {
      request.response.statusCode = 404;
      request.response.write('File not found');
      return;
    }

    try {
      final bytes = await file.readAsBytes();
      final mime = lookupMimeType(filename) ?? 'application/octet-stream';
      request.response.headers.contentType = ContentType.parse(mime);
      request.response.headers.add('Content-Disposition', 'attachment; filename="$filename"');
      request.response.headers.add('Content-Length', bytes.length.toString());
      request.response.add(bytes);
    } catch (e) {
      log('ERROR', 'Failed to serve update file: $e');
      request.response.statusCode = 500;
      request.response.write('Internal error');
    }
  }

  /// Start update polling
  void startPolling() {
    final settings = getSettings();
    if (!settings.updateMirrorEnabled) return;

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      Duration(seconds: settings.updateCheckIntervalSeconds),
      (_) => pollForUpdates(),
    );

    // Initial poll
    pollForUpdates();
  }

  /// Stop update polling
  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Poll for new updates
  Future<void> pollForUpdates() async {
    final settings = getSettings();
    if (!settings.updateMirrorEnabled || _isDownloadingUpdates) return;

    try {
      final response = await http.get(
        Uri.parse(settings.updateMirrorUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final release = jsonDecode(response.body) as Map<String, dynamic>;
        final newVersion = release['tag_name'] as String?;

        // Check if this is a new version
        if (newVersion != null && newVersion != settings.lastMirroredVersion) {
          log('INFO', 'New version available: $newVersion');
          _cachedRelease = release;
          await _saveCachedRelease();

          // Start downloading assets
          await _downloadReleaseAssets(release);
        } else if (_cachedRelease == null) {
          // No cached release, save this one
          _cachedRelease = release;
          await _saveCachedRelease();
        }
      }
    } catch (e) {
      log('WARN', 'Update poll failed: $e');
    }
  }

  /// Download release assets
  Future<void> _downloadReleaseAssets(Map<String, dynamic> release) async {
    if (_isDownloadingUpdates) return;
    _isDownloadingUpdates = true;

    try {
      _downloadedAssets.clear();
      _assetFilenames.clear();

      final assets = release['assets'] as List<dynamic>?;
      if (assets == null) return;

      // Download important assets (APK, Linux, Windows, macOS)
      for (final asset in assets) {
        final assetMap = asset as Map<String, dynamic>;
        final name = assetMap['name'] as String?;
        final downloadUrl = assetMap['browser_download_url'] as String?;

        if (name == null || downloadUrl == null) continue;

        // Determine asset type
        final assetType = _determineAssetType(name);
        if (assetType == null) continue; // Skip unknown types

        try {
          log('INFO', 'Downloading: $name');
          final filePath = '$updatesDirectory/$name';
          final result = await streamDownloadToFile(
            Uri.parse(downloadUrl),
            filePath,
            headers: {'User-Agent': 'Geogram-Station-Updater'},
            timeout: const Duration(minutes: 10),
          );

          if (result.success) {
            _downloadedAssets[name] = filePath;
            _assetFilenames[assetType.name] = name;
            log('INFO', 'Downloaded: $name (${result.bytesWritten} bytes)');
          }
        } catch (e) {
          log('WARN', 'Failed to download $name: $e');
        }
      }

      log('INFO', 'Update mirror complete: ${_downloadedAssets.length} assets');
    } finally {
      _isDownloadingUpdates = false;
    }
  }

  /// Determine asset type from filename
  UpdateAssetType? _determineAssetType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.apk')) return UpdateAssetType.androidApk;
    if (lower.contains('linux') && lower.endsWith('.tar.gz')) return UpdateAssetType.linuxDesktop;
    if (lower.contains('windows') && lower.endsWith('.zip')) return UpdateAssetType.windowsDesktop;
    if (lower.contains('macos') && lower.endsWith('.zip')) return UpdateAssetType.macosDesktop;
    if (lower.contains('ios') && lower.endsWith('.ipa')) return UpdateAssetType.iosUnsigned;
    return null;
  }

  /// Load cached release from disk
  Future<void> loadCachedRelease() async {
    try {
      final file = File('$updatesDirectory/release.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        _cachedRelease = jsonDecode(content) as Map<String, dynamic>?;
        log('INFO', 'Loaded cached release info');

        // Scan for existing downloaded assets
        await _scanDownloadedAssets();
      }
    } catch (e) {
      log('WARN', 'Failed to load cached release: $e');
    }
  }

  /// Scan for already downloaded assets
  Future<void> _scanDownloadedAssets() async {
    try {
      final dir = Directory(updatesDirectory);
      if (!await dir.exists()) return;

      await for (final entity in dir.list()) {
        if (entity is File) {
          final name = entity.path.split('/').last;
          if (!name.endsWith('.json')) {
            _downloadedAssets[name] = entity.path;
          }
        }
      }

      log('INFO', 'Found ${_downloadedAssets.length} cached update files');
    } catch (e) {
      log('WARN', 'Failed to scan downloaded assets: $e');
    }
  }

  /// Save cached release to disk
  Future<void> _saveCachedRelease() async {
    if (_cachedRelease == null) return;
    try {
      final file = File('$updatesDirectory/release.json');
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(_cachedRelease));
    } catch (e) {
      log('WARN', 'Failed to save cached release: $e');
    }
  }

  /// Get list of downloaded asset filenames
  List<String> getDownloadedAssets() {
    return _downloadedAssets.keys.toList();
  }

  /// Check if a specific asset is downloaded
  bool hasAsset(String filename) {
    return _downloadedAssets.containsKey(filename);
  }

  /// Get the geoip directory path
  String get _geoipDirectory => '$updatesDirectory/geoip';

  /// Get the geoip MMDB file path
  String get _geoipMmdbPath => '$_geoipDirectory/dbip-city-lite.mmdb';

  /// Handle GET /geoip/dbip-city-lite.mmdb
  Future<void> handleGeoipDownload(HttpRequest request) async {
    final file = File(_geoipMmdbPath);

    if (!await file.exists()) {
      request.response.statusCode = 404;
      request.response.write('GeoIP database not found. Station is downloading it...');
      return;
    }

    try {
      final bytes = await file.readAsBytes();
      request.response.headers.contentType = ContentType.parse('application/octet-stream');
      request.response.headers.add('Content-Disposition', 'attachment; filename="dbip-city-lite.mmdb"');
      request.response.headers.add('Content-Length', bytes.length.toString());
      request.response.add(bytes);
    } catch (e) {
      log('ERROR', 'Failed to serve GeoIP file: $e');
      request.response.statusCode = 500;
      request.response.write('Internal error');
    }
  }

  /// Download GeoIP MMDB database (runs in background)
  Future<void> downloadGeoipDatabase() async {
    if (_isDownloadingGeoip) return;

    // Check if already exists
    final file = File(_geoipMmdbPath);
    if (await file.exists()) {
      log('INFO', 'GeoIP database already exists');
      return;
    }

    _isDownloadingGeoip = true;
    try {
      // Create geoip directory
      await Directory(_geoipDirectory).create(recursive: true);

      // Try jsdelivr first (compressed, ~19MB)
      log('INFO', 'Downloading GeoIP database from jsdelivr...');
      final compressedPath = '$_geoipDirectory/dbip-city-lite.mmdb.gz';

      final result = await streamDownloadToFile(
        Uri.parse(GeoIpUrls.jsdelivrUrl),
        compressedPath,
        headers: {'User-Agent': 'Geogram-Station-GeoIP'},
        timeout: const Duration(minutes: 5),
      );

      if (result.success) {
        log('INFO', 'GeoIP database downloaded (${result.bytesWritten} bytes), decompressing...');

        // Decompress .gz file
        final compressedData = await File(compressedPath).readAsBytes();
        final decompressed = GZipDecoder().decodeBytes(compressedData);
        await File(_geoipMmdbPath).writeAsBytes(decompressed);

        // Remove compressed file
        await File(compressedPath).delete();

        log('INFO', 'GeoIP database ready: $_geoipMmdbPath (${decompressed.length} bytes)');
      } else {
        log('WARN', 'Failed to download GeoIP database from jsdelivr');
      }
    } catch (e) {
      log('ERROR', 'GeoIP database download failed: $e');
    } finally {
      _isDownloadingGeoip = false;
    }
  }

  /// Start geoip download on station startup
  void startGeoipDownload() {
    downloadGeoipDatabase();
  }
}
