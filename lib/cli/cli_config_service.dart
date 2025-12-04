// Pure Dart Config Service for CLI mode (no Flutter dependencies)
// Reads/writes the same config.json format as the Flutter ConfigService
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'pure_storage_config.dart';

/// Pure Dart config service for CLI mode
/// Shares the same config.json format with the Flutter ConfigService
class CliConfigService {
  static final CliConfigService _instance = CliConfigService._internal();
  factory CliConfigService() => _instance;
  CliConfigService._internal();

  File? _configFile;
  Map<String, dynamic> _config = {};
  bool _initialized = false;

  /// Debounce timer for save operations
  Timer? _saveDebounceTimer;
  bool _pendingSave = false;
  static const Duration _saveDebounceDuration = Duration(milliseconds: 500);

  /// Initialize the config service and load existing configuration
  Future<void> init() async {
    if (_initialized) return;

    final storageConfig = PureStorageConfig();
    if (!storageConfig.isInitialized) {
      throw StateError(
        'PureStorageConfig must be initialized before CliConfigService. '
        'Call PureStorageConfig().init() first.',
      );
    }

    _configFile = File(storageConfig.configPath);

    if (await _configFile!.exists()) {
      await _load();
    } else {
      _createDefaultConfig();
      await _saveImmediate();
    }
    _initialized = true;
  }

  /// Create default configuration
  void _createDefaultConfig() {
    _config = {
      'version': '1.0.0',
      'created': DateTime.now().toIso8601String(),
      'collections': {
        'favorites': <String>[],
      },
      'settings': {
        'theme': 'system',
        'language': 'en',
      },
    };
  }

  /// Load configuration from disk
  Future<void> _load() async {
    try {
      final contents = await _configFile!.readAsString();
      _config = json.decode(contents) as Map<String, dynamic>;
    } catch (e) {
      stderr.writeln('CliConfigService: Error loading config: $e');
      _config = {};
    }
  }

  /// Save configuration to storage (debounced to prevent too many file operations)
  void _save() {
    // Cancel any pending save and schedule a new one
    _saveDebounceTimer?.cancel();
    _pendingSave = true;
    _saveDebounceTimer = Timer(_saveDebounceDuration, () {
      _saveImmediate();
    });
  }

  /// Save configuration immediately (used for initial save and when needed)
  Future<void> _saveImmediate() async {
    _pendingSave = false;
    if (_configFile == null) {
      stderr.writeln('CliConfigService: Error saving config: not initialized');
      return;
    }
    try {
      final contents = JsonEncoder.withIndent('  ').convert(_config);
      await _configFile!.writeAsString(contents);
    } catch (e) {
      stderr.writeln('CliConfigService: Error saving config: $e');
    }
  }

  /// Flush any pending saves immediately (call this before exiting or when immediate persistence is required)
  Future<void> flush() async {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    if (_pendingSave) {
      await _saveImmediate();
    }
  }

  /// Get a configuration value
  dynamic get(String key, [dynamic defaultValue]) {
    return _config[key] ?? defaultValue;
  }

  /// Set a configuration value
  void set(String key, dynamic value) {
    _config[key] = value;
    _save();
  }

  /// Remove a configuration value
  void remove(String key) {
    _config.remove(key);
    _save();
  }

  /// Get nested configuration value using dot notation
  dynamic getNestedValue(String path, [dynamic defaultValue]) {
    final keys = path.split('.');
    dynamic current = _config;

    for (var key in keys) {
      if (current is Map<String, dynamic> && current.containsKey(key)) {
        current = current[key];
      } else {
        return defaultValue;
      }
    }

    return current;
  }

  /// Set nested configuration value using dot notation
  void setNestedValue(String path, dynamic value) {
    final keys = path.split('.');
    Map<String, dynamic> current = _config;

    for (int i = 0; i < keys.length - 1; i++) {
      final key = keys[i];
      if (!current.containsKey(key) || current[key] is! Map<String, dynamic>) {
        current[key] = <String, dynamic>{};
      }
      current = current[key] as Map<String, dynamic>;
    }

    current[keys.last] = value;
    _save();
  }

  /// Get the full configuration map
  Map<String, dynamic> getAll() {
    return Map<String, dynamic>.from(_config);
  }
}
