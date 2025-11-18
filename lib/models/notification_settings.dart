/// Notification settings model
class NotificationSettings {
  bool enableNotifications;
  bool notifyNewMessages;
  bool notifyNearbyDevices;
  bool notifyCollectionUpdates;
  bool notifyRelayStatus;
  bool notifySystemAlerts;
  bool soundEnabled;
  bool vibrationEnabled;

  NotificationSettings({
    this.enableNotifications = true,
    this.notifyNewMessages = true,
    this.notifyNearbyDevices = true,
    this.notifyCollectionUpdates = false,
    this.notifyRelayStatus = false,
    this.notifySystemAlerts = true,
    this.soundEnabled = true,
    this.vibrationEnabled = true,
  });

  /// Create from JSON
  factory NotificationSettings.fromJson(Map<String, dynamic> json) {
    return NotificationSettings(
      enableNotifications: json['enableNotifications'] as bool? ?? true,
      notifyNewMessages: json['notifyNewMessages'] as bool? ?? true,
      notifyNearbyDevices: json['notifyNearbyDevices'] as bool? ?? true,
      notifyCollectionUpdates: json['notifyCollectionUpdates'] as bool? ?? false,
      notifyRelayStatus: json['notifyRelayStatus'] as bool? ?? false,
      notifySystemAlerts: json['notifySystemAlerts'] as bool? ?? true,
      soundEnabled: json['soundEnabled'] as bool? ?? true,
      vibrationEnabled: json['vibrationEnabled'] as bool? ?? true,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'enableNotifications': enableNotifications,
      'notifyNewMessages': notifyNewMessages,
      'notifyNearbyDevices': notifyNearbyDevices,
      'notifyCollectionUpdates': notifyCollectionUpdates,
      'notifyRelayStatus': notifyRelayStatus,
      'notifySystemAlerts': notifySystemAlerts,
      'soundEnabled': soundEnabled,
      'vibrationEnabled': vibrationEnabled,
    };
  }

  /// Create a copy with updated fields
  NotificationSettings copyWith({
    bool? enableNotifications,
    bool? notifyNewMessages,
    bool? notifyNearbyDevices,
    bool? notifyCollectionUpdates,
    bool? notifyRelayStatus,
    bool? notifySystemAlerts,
    bool? soundEnabled,
    bool? vibrationEnabled,
  }) {
    return NotificationSettings(
      enableNotifications: enableNotifications ?? this.enableNotifications,
      notifyNewMessages: notifyNewMessages ?? this.notifyNewMessages,
      notifyNearbyDevices: notifyNearbyDevices ?? this.notifyNearbyDevices,
      notifyCollectionUpdates: notifyCollectionUpdates ?? this.notifyCollectionUpdates,
      notifyRelayStatus: notifyRelayStatus ?? this.notifyRelayStatus,
      notifySystemAlerts: notifySystemAlerts ?? this.notifySystemAlerts,
      soundEnabled: soundEnabled ?? this.soundEnabled,
      vibrationEnabled: vibrationEnabled ?? this.vibrationEnabled,
    );
  }
}
