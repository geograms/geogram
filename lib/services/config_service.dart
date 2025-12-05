import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../util/nostr_key_generator.dart';
import '../platform/web_storage.dart' if (dart.library.io) '../platform/web_storage_stub.dart';
import 'storage_config.dart';
import 'log_service.dart';

/// Service for managing application configuration stored in config.json
class ConfigService {
  static final ConfigService _instance = ConfigService._internal();
  factory ConfigService() => _instance;
  ConfigService._internal();

  File? _configFile;
  Map<String, dynamic> _config = {};
  static const String _webStorageKey = 'geogram_config';

  /// Debounce timer for save operations
  Timer? _saveDebounceTimer;
  bool _pendingSave = false;
  static const Duration _saveDebounceDuration = Duration(milliseconds: 500);

  /// Initialize the config service and load existing configuration
  Future<void> init() async {
    if (kIsWeb) {
      await _initWeb();
    } else {
      await _initNative();
    }
  }

  /// Initialize for native platforms (file-based storage)
  ///
  /// Uses StorageConfig for path management. StorageConfig must be initialized
  /// before calling this method.
  Future<void> _initNative() async {
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      throw StateError(
        'StorageConfig must be initialized before ConfigService. '
        'Call StorageConfig().init() first.',
      );
    }

    _configFile = File(storageConfig.configPath);

    if (await _configFile!.exists()) {
      await _load();
    } else {
      _createDefaultConfig();
      await _saveImmediate();
    }
  }

  /// Initialize for web platform (localStorage-based storage)
  Future<void> _initWeb() async {
    final stored = WebStorage.get(_webStorageKey);
    if (stored != null) {
      try {
        _config = json.decode(stored) as Map<String, dynamic>;
      } catch (e) {
        LogService().log('Error loading web config: $e');
        _createDefaultConfig();
        await _saveImmediate();
      }
    } else {
      _createDefaultConfig();
      await _saveImmediate();
    }
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
        'language': 'en_US',
      },
    };
  }

  /// Load configuration from disk (native only)
  Future<void> _load() async {
    try {
      final contents = await _configFile!.readAsString();
      _config = json.decode(contents) as Map<String, dynamic>;
    } catch (e) {
      stderr.writeln('Error loading config: $e');
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
    if (kIsWeb) {
      try {
        final contents = JsonEncoder.withIndent('  ').convert(_config);
        WebStorage.set(_webStorageKey, contents);
      } catch (e) {
        LogService().log('Error saving web config: $e');
      }
    } else {
      if (_configFile == null) {
        stderr.writeln('Error saving config: ConfigService not initialized');
        return;
      }
      try {
        final contents = JsonEncoder.withIndent('  ').convert(_config);
        await _configFile!.writeAsString(contents);
      } catch (e) {
        stderr.writeln('Error saving config: $e');
      }
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

  /// Check if a collection is favorited
  bool isFavorite(String collectionId) {
    final favorites = getNestedValue('collections.favorites', <String>[]) as List;
    return favorites.contains(collectionId);
  }

  /// Toggle favorite status of a collection
  void toggleFavorite(String collectionId) {
    final favorites = List<String>.from(
      getNestedValue('collections.favorites', <String>[]) as List
    );

    if (favorites.contains(collectionId)) {
      favorites.remove(collectionId);
    } else {
      favorites.add(collectionId);
    }

    setNestedValue('collections.favorites', favorites);
  }

  /// Get the full configuration map
  Map<String, dynamic> getAll() {
    return Map<String, dynamic>.from(_config);
  }

  /// Store collection npub/nsec key pair
  void storeCollectionKeys(NostrKeys keys) {
    // Ensure collectionKeys section exists
    if (!_config.containsKey('collectionKeys')) {
      _config['collectionKeys'] = <String, dynamic>{};
    }

    final collectionKeys = _config['collectionKeys'] as Map<String, dynamic>;
    collectionKeys[keys.npub] = keys.toJson();

    _save();
    stderr.writeln('Stored keys for collection: ${keys.npub}');
  }

  /// Get nsec for a given npub
  String? getNsec(String npub) {
    final collectionKeys = _config['collectionKeys'] as Map<String, dynamic>?;
    if (collectionKeys == null || !collectionKeys.containsKey(npub)) {
      return null;
    }

    final keyData = collectionKeys[npub] as Map<String, dynamic>;
    return keyData['nsec'] as String?;
  }

  /// Check if we own this collection (have the nsec)
  bool isOwnedCollection(String npub) {
    return getNsec(npub) != null;
  }

  /// Get all owned collections (npubs we have nsec for)
  Map<String, String> getAllOwnedCollections() {
    final owned = <String, String>{};
    final collectionKeys = _config['collectionKeys'] as Map<String, dynamic>?;

    if (collectionKeys == null) {
      return owned;
    }

    for (var entry in collectionKeys.entries) {
      final npub = entry.key;
      final keyData = entry.value as Map<String, dynamic>;
      final nsec = keyData['nsec'] as String?;

      if (nsec != null) {
        owned[npub] = nsec;
      }
    }

    return owned;
  }
}
