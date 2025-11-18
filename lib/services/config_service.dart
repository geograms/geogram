import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../util/nostr_key_generator.dart';

/// Service for managing application configuration stored in config.json
class ConfigService {
  static final ConfigService _instance = ConfigService._internal();
  factory ConfigService() => _instance;
  ConfigService._internal();

  File? _configFile;
  Map<String, dynamic> _config = {};

  /// Initialize the config service and load existing configuration
  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    final configDir = Directory('${appDir.path}/geogram');

    if (!await configDir.exists()) {
      await configDir.create(recursive: true);
    }

    _configFile = File('${configDir.path}/config.json');

    if (await _configFile!.exists()) {
      await _load();
    } else {
      // Create default config
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
      await _save();
    }
  }

  /// Load configuration from disk
  Future<void> _load() async {
    try {
      final contents = await _configFile!.readAsString();
      _config = json.decode(contents) as Map<String, dynamic>;
    } catch (e) {
      stderr.writeln('Error loading config: $e');
      _config = {};
    }
  }

  /// Save configuration to disk
  Future<void> _save() async {
    try {
      final contents = JsonEncoder.withIndent('  ').convert(_config);
      await _configFile!.writeAsString(contents);
    } catch (e) {
      stderr.writeln('Error saving config: $e');
    }
  }

  /// Get a configuration value
  dynamic get(String key, [dynamic defaultValue]) {
    return _config[key] ?? defaultValue;
  }

  /// Set a configuration value
  Future<void> set(String key, dynamic value) async {
    _config[key] = value;
    await _save();
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
  Future<void> setNestedValue(String path, dynamic value) async {
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
    await _save();
  }

  /// Check if a collection is favorited
  bool isFavorite(String collectionId) {
    final favorites = getNestedValue('collections.favorites', <String>[]) as List;
    return favorites.contains(collectionId);
  }

  /// Toggle favorite status of a collection
  Future<void> toggleFavorite(String collectionId) async {
    final favorites = List<String>.from(
      getNestedValue('collections.favorites', <String>[]) as List
    );

    if (favorites.contains(collectionId)) {
      favorites.remove(collectionId);
    } else {
      favorites.add(collectionId);
    }

    await setNestedValue('collections.favorites', favorites);
  }

  /// Get the full configuration map
  Map<String, dynamic> getAll() {
    return Map<String, dynamic>.from(_config);
  }

  /// Store collection npub/nsec key pair
  Future<void> storeCollectionKeys(NostrKeys keys) async {
    // Ensure collectionKeys section exists
    if (!_config.containsKey('collectionKeys')) {
      _config['collectionKeys'] = <String, dynamic>{};
    }

    final collectionKeys = _config['collectionKeys'] as Map<String, dynamic>;
    collectionKeys[keys.npub] = keys.toJson();

    await _save();
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
