import '../models/notification_settings.dart';
import '../services/config_service.dart';
import '../services/log_service.dart';

/// Service for managing notification settings
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  NotificationSettings? _settings;
  bool _initialized = false;

  /// Initialize notification service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _loadSettings();
      _initialized = true;
      LogService().log('NotificationService initialized');
    } catch (e) {
      LogService().log('Error initializing NotificationService: $e');
    }
  }

  /// Load settings from config
  Future<void> _loadSettings() async {
    final config = ConfigService().getAll();

    if (config.containsKey('notifications')) {
      final settingsData = config['notifications'] as Map<String, dynamic>;
      _settings = NotificationSettings.fromJson(settingsData);
      LogService().log('Loaded notification settings from config');
    } else {
      // Create default settings
      _settings = NotificationSettings();
      await _saveSettings();
      LogService().log('Created default notification settings');
    }
  }

  /// Save settings to config.json
  Future<void> _saveSettings() async {
    if (_settings != null) {
      await ConfigService().set('notifications', _settings!.toJson());
      LogService().log('Saved notification settings to config');
    }
  }

  /// Get current settings
  NotificationSettings getSettings() {
    if (!_initialized) {
      throw Exception('NotificationService not initialized');
    }
    return _settings ?? NotificationSettings();
  }

  /// Update settings
  Future<void> updateSettings(NotificationSettings settings) async {
    _settings = settings;
    await _saveSettings();
  }

  /// Update master enable/disable
  Future<void> setEnabled(bool enabled) async {
    if (_settings != null) {
      _settings = _settings!.copyWith(enableNotifications: enabled);
      await _saveSettings();
    }
  }

  /// Update individual notification type
  Future<void> updateNotificationType({
    bool? newMessages,
    bool? nearbyDevices,
    bool? collectionUpdates,
    bool? relayStatus,
    bool? systemAlerts,
  }) async {
    if (_settings != null) {
      _settings = _settings!.copyWith(
        notifyNewMessages: newMessages,
        notifyNearbyDevices: nearbyDevices,
        notifyCollectionUpdates: collectionUpdates,
        notifyRelayStatus: relayStatus,
        notifySystemAlerts: systemAlerts,
      );
      await _saveSettings();
    }
  }

  /// Update sound settings
  Future<void> updateSound({bool? sound, bool? vibration}) async {
    if (_settings != null) {
      _settings = _settings!.copyWith(
        soundEnabled: sound,
        vibrationEnabled: vibration,
      );
      await _saveSettings();
    }
  }
}
