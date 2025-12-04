// Pure Dart storage configuration for CLI mode (no Flutter dependencies)
import 'dart:io';
import 'package:path/path.dart' as path;

/// Centralized storage configuration for CLI mode
///
/// This is a pure Dart version of StorageConfig that doesn't depend on
/// Flutter-specific packages like path_provider.
class PureStorageConfig {
  static final PureStorageConfig _instance = PureStorageConfig._internal();
  factory PureStorageConfig() => _instance;
  PureStorageConfig._internal();

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
        'PureStorageConfig not initialized. Call PureStorageConfig().init() first.',
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
        stderr.writeln(
          'PureStorageConfig: Re-initializing with new base directory: $customBaseDir',
        );
      } else {
        return; // Already initialized with same or default path
      }
    }

    // Determine base directory with priority order
    if (customBaseDir != null && customBaseDir.isNotEmpty) {
      _baseDir = _normalizePath(customBaseDir);
    } else {
      // Check environment variable
      final envDir = Platform.environment[envVarName];
      if (envDir != null && envDir.isNotEmpty) {
        _baseDir = _normalizePath(envDir);
      } else {
        // Default to current working directory (CLI is always desktop)
        _baseDir = Directory.current.path;
      }
    }

    stderr.writeln('PureStorageConfig: Base directory set to: $_baseDir');

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
        stderr.writeln('PureStorageConfig: Created directory: $dir');
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
      return 'PureStorageConfig(not initialized)';
    }
    return 'PureStorageConfig(baseDir: $baseDir)';
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
