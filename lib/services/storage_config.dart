import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Centralized storage configuration for geogram-desktop
///
/// This service provides unified path management for both UI and CLI modes.
/// By default, data is stored in the directory where the binary is running.
/// This can be overridden via:
/// - Environment variable: GEOGRAM_DATA_DIR
/// - CLI argument: --data-dir=/path/to/dir
/// - Programmatic configuration before initialization
///
/// Standard folder structure:
/// {BASE_DIR}/
/// ├── config.json         # Main config (profiles, settings)
/// ├── station_config.json   # Station specific config
/// ├── devices/            # Device data per callsign
/// │   └── {CALLSIGN}/
/// │       └── {collections}
/// ├── tiles/              # Cached map tiles
/// ├── ssl/                # SSL certificates
/// └── logs/               # Log files
class StorageConfig {
  static final StorageConfig _instance = StorageConfig._internal();
  factory StorageConfig() => _instance;
  StorageConfig._internal();

  /// Whether the storage config has been initialized
  bool _initialized = false;

  /// The base directory for all geogram data
  String? _baseDir;

  /// Environment variable name for custom data directory
  static const String envVarName = 'GEOGRAM_DATA_DIR';

  /// Check if storage config is initialized
  bool get isInitialized => _initialized;

  /// Get the base directory
  String get baseDir {
    if (!_initialized || _baseDir == null) {
      throw StateError(
        'StorageConfig not initialized. Call StorageConfig().init() first.',
      );
    }
    return _baseDir!;
  }

  /// Get the devices directory path
  String get devicesDir => path.join(baseDir, 'devices');

  /// Get the chat directory path (for DM conversations as restricted chat rooms)
  String get chatDir => path.join(baseDir, 'chat');

  /// Get the tiles cache directory path
  String get tilesDir => path.join(baseDir, 'tiles');

  /// Get the SSL certificates directory path
  String get sslDir => path.join(baseDir, 'ssl');

  /// Get the logs directory path
  String get logsDir => path.join(baseDir, 'logs');

  /// Get the main config file path
  String get configPath => path.join(baseDir, 'config.json');

  /// Get the station config file path
  String get stationConfigPath => path.join(baseDir, 'station_config.json');

  /// Get the collections directory for a specific callsign
  String getCallsignDir(String callsign) {
    final sanitized = _sanitizeCallsign(callsign);
    return path.join(devicesDir, sanitized);
  }

  /// Initialize the storage configuration
  ///
  /// Priority order for base directory:
  /// 1. Explicit [customBaseDir] parameter (if provided)
  /// 2. Saved custom path from user preferences file
  /// 3. Environment variable GEOGRAM_DATA_DIR
  /// 4. Platform default location
  ///
  /// Set [createDirectories] to false to skip directory creation (useful for testing)
  Future<void> init({
    String? customBaseDir,
    bool createDirectories = true,
  }) async {
    if (_initialized) {
      // Already initialized - allow re-initialization with different path
      if (customBaseDir != null && customBaseDir != _baseDir) {
        if (!kIsWeb) {
          stderr.writeln(
            'StorageConfig: Re-initializing with new base directory: $customBaseDir',
          );
        }
      } else {
        return; // Already initialized with same or default path
      }
    }

    // On web, we don't use file-based storage
    if (kIsWeb) {
      _baseDir = '/web'; // Virtual path for web
      _initialized = true;
      return;
    }

    // Determine base directory with priority order
    if (customBaseDir != null && customBaseDir.isNotEmpty) {
      _baseDir = _normalizePath(customBaseDir);
    } else {
      // Check for saved custom path from user preferences
      final savedPath = await _readSavedDataDir();
      if (savedPath != null && savedPath.isNotEmpty) {
        _baseDir = _normalizePath(savedPath);
        stderr.writeln('StorageConfig: Using saved custom path: $_baseDir');
      } else {
        // Check environment variable
        final envDir = Platform.environment[envVarName];
        if (envDir != null && envDir.isNotEmpty) {
          _baseDir = _normalizePath(envDir);
        } else if (Platform.isAndroid || Platform.isIOS) {
          // On mobile platforms, use app documents directory
          final appDir = await getApplicationDocumentsDirectory();
          _baseDir = path.join(appDir.path, 'geogram');
        } else {
          // On desktop, use ~/.local/share/geogram-desktop for consistent location
          final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
          if (home != null) {
            _baseDir = path.join(home, '.local', 'share', 'geogram-desktop');
          } else {
            // Fallback to current working directory if HOME not set
            _baseDir = Directory.current.path;
          }
        }
      }
    }

    stderr.writeln('StorageConfig: Base directory set to: $_baseDir');

    if (createDirectories) {
      await _ensureDirectoriesExist();
    }

    _initialized = true;
  }

  /// Get the path to the user preferences file for storing custom data dir
  String _getPreferencesFilePath() {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '/tmp';
    if (Platform.isWindows) {
      return path.join(home, 'AppData', 'Local', 'geogram-desktop', 'data_dir.txt');
    } else if (Platform.isMacOS) {
      return path.join(home, 'Library', 'Application Support', 'geogram-desktop', 'data_dir.txt');
    } else {
      // Linux and others
      return path.join(home, '.config', 'geogram-desktop', 'data_dir.txt');
    }
  }

  /// Read saved data directory from preferences file
  Future<String?> _readSavedDataDir() async {
    try {
      final prefsFile = File(_getPreferencesFilePath());
      if (await prefsFile.exists()) {
        final content = await prefsFile.readAsString();
        return content.trim();
      }
    } catch (e) {
      stderr.writeln('StorageConfig: Error reading preferences file: $e');
    }
    return null;
  }

  /// Save custom data directory to preferences file
  Future<bool> saveCustomDataDir(String dirPath) async {
    try {
      final prefsFile = File(_getPreferencesFilePath());
      final parentDir = prefsFile.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      await prefsFile.writeAsString(dirPath);
      stderr.writeln('StorageConfig: Saved custom data dir: $dirPath');
      return true;
    } catch (e) {
      stderr.writeln('StorageConfig: Error saving preferences file: $e');
      return false;
    }
  }

  /// Clear saved custom data directory (revert to default)
  Future<bool> clearCustomDataDir() async {
    try {
      final prefsFile = File(_getPreferencesFilePath());
      if (await prefsFile.exists()) {
        await prefsFile.delete();
      }
      return true;
    } catch (e) {
      stderr.writeln('StorageConfig: Error clearing preferences file: $e');
      return false;
    }
  }

  /// Reset the storage config (mainly for testing)
  void reset() {
    _initialized = false;
    _baseDir = null;
  }

  /// Normalize path (expand ~ and resolve relative paths)
  String _normalizePath(String inputPath) {
    // On web, just return the input path as-is
    if (kIsWeb) {
      return inputPath;
    }

    var normalized = inputPath;

    // Expand ~ to home directory
    if (normalized.startsWith('~')) {
      final home = Platform.environment['HOME'] ??
                   Platform.environment['USERPROFILE'] ??
                   '/tmp';
      normalized = normalized.replaceFirst('~', home);
    }

    // Resolve to absolute path
    normalized = path.normalize(path.absolute(normalized));

    return normalized;
  }

  /// Ensure all required directories exist
  /// Note: Uses _baseDir directly since this is called before _initialized is set
  Future<void> _ensureDirectoriesExist() async {
    final base = _baseDir!;
    final directories = [
      base,
      path.join(base, 'devices'),
      path.join(base, 'chat'),
      path.join(base, 'tiles'),
      path.join(base, 'ssl'),
      path.join(base, 'logs'),
    ];

    for (final dir in directories) {
      final directory = Directory(dir);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
        stderr.writeln('StorageConfig: Created directory: $dir');
      }
    }
  }

  /// Sanitize callsign for use as folder name
  String _sanitizeCallsign(String callsign) {
    return callsign
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  /// Get a summary of the current configuration
  Map<String, String> getConfigSummary() {
    if (!_initialized) {
      return {'status': 'not initialized'};
    }
    return {
      'baseDir': baseDir,
      'devicesDir': devicesDir,
      'tilesDir': tilesDir,
      'sslDir': sslDir,
      'logsDir': logsDir,
      'configPath': configPath,
      'stationConfigPath': stationConfigPath,
    };
  }

  @override
  String toString() {
    if (!_initialized) {
      return 'StorageConfig(not initialized)';
    }
    return 'StorageConfig(baseDir: $baseDir)';
  }
}

/// Parse command line arguments to extract data directory
///
/// Looks for --data-dir=PATH or --data-dir PATH
String? parseDataDirFromArgs(List<String> args) {
  for (int i = 0; i < args.length; i++) {
    final arg = args[i];

    // Handle --data-dir=PATH format
    if (arg.startsWith('--data-dir=')) {
      return arg.substring('--data-dir='.length);
    }

    // Handle --data-dir PATH format
    if (arg == '--data-dir' && i + 1 < args.length) {
      return args[i + 1];
    }

    // Handle -d PATH format (short form)
    if (arg == '-d' && i + 1 < args.length) {
      return args[i + 1];
    }
  }

  return null;
}
