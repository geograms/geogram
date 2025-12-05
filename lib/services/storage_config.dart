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
/// ├── relay_config.json   # Relay specific config
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

  /// Get the tiles cache directory path
  String get tilesDir => path.join(baseDir, 'tiles');

  /// Get the SSL certificates directory path
  String get sslDir => path.join(baseDir, 'ssl');

  /// Get the logs directory path
  String get logsDir => path.join(baseDir, 'logs');

  /// Get the main config file path
  String get configPath => path.join(baseDir, 'config.json');

  /// Get the relay config file path
  String get relayConfigPath => path.join(baseDir, 'relay_config.json');

  /// Get the collections directory for a specific callsign
  String getCallsignDir(String callsign) {
    final sanitized = _sanitizeCallsign(callsign);
    return path.join(devicesDir, sanitized);
  }

  /// Initialize the storage configuration
  ///
  /// Priority order for base directory:
  /// 1. Explicit [customBaseDir] parameter (if provided)
  /// 2. Environment variable GEOGRAM_DATA_DIR
  /// 3. Current working directory (where binary is running)
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
      // Check environment variable
      final envDir = Platform.environment[envVarName];
      if (envDir != null && envDir.isNotEmpty) {
        _baseDir = _normalizePath(envDir);
      } else if (Platform.isAndroid || Platform.isIOS) {
        // On mobile platforms, use app documents directory
        final appDir = await getApplicationDocumentsDirectory();
        _baseDir = path.join(appDir.path, 'geogram');
      } else {
        // Default to current working directory (desktop)
        _baseDir = Directory.current.path;
      }
    }

    stderr.writeln('StorageConfig: Base directory set to: $_baseDir');

    if (createDirectories) {
      await _ensureDirectoriesExist();
    }

    _initialized = true;
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
      'relayConfigPath': relayConfigPath,
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
