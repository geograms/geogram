/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Meshtastic connection configuration.
 * Persisted as JSON via ProfileStorage at teleport/meshtastic/config.json.
 */

/// Active transport type.
enum MeshtasticTransport { ble, mqtt, http }

class MeshtasticConfig {
  /// BLE device ID of the connected radio.
  final String bleDeviceId;

  /// MQTT broker settings (Phase 2).
  final String mqttBroker;
  final int mqttPort;
  final String mqttUser;
  final String mqttPass;

  /// HTTP host (Phase 3).
  final String httpHost;
  final int httpPort;

  /// Meshtastic region code (e.g. 'US', 'EU_868').
  final String region;

  /// Which transport is active.
  final MeshtasticTransport activeTransport;

  /// Our node number (set after config dump from radio).
  final int myNodeNum;

  /// Auto-start on app launch.
  final bool autoStart;

  const MeshtasticConfig({
    this.bleDeviceId = '',
    this.mqttBroker = 'mqtt.meshtastic.org',
    this.mqttPort = 1883,
    this.mqttUser = 'meshdev',
    this.mqttPass = 'large4cats',
    this.httpHost = '',
    this.httpPort = 80,
    this.region = 'US',
    this.activeTransport = MeshtasticTransport.ble,
    this.myNodeNum = 0,
    this.autoStart = false,
  });

  Map<String, dynamic> toJson() => {
        'bleDeviceId': bleDeviceId,
        'mqttBroker': mqttBroker,
        'mqttPort': mqttPort,
        'mqttUser': mqttUser,
        'mqttPass': mqttPass,
        'httpHost': httpHost,
        'httpPort': httpPort,
        'region': region,
        'activeTransport': activeTransport.name,
        'myNodeNum': myNodeNum,
        'autoStart': autoStart,
      };

  factory MeshtasticConfig.fromJson(Map<String, dynamic> json) {
    return MeshtasticConfig(
      bleDeviceId: json['bleDeviceId'] as String? ?? '',
      mqttBroker: json['mqttBroker'] as String? ?? 'mqtt.meshtastic.org',
      mqttPort: json['mqttPort'] as int? ?? 1883,
      mqttUser: json['mqttUser'] as String? ?? 'meshdev',
      mqttPass: json['mqttPass'] as String? ?? 'large4cats',
      httpHost: json['httpHost'] as String? ?? '',
      httpPort: json['httpPort'] as int? ?? 80,
      region: json['region'] as String? ?? 'US',
      activeTransport: MeshtasticTransport.values.firstWhere(
        (t) => t.name == json['activeTransport'],
        orElse: () => MeshtasticTransport.ble,
      ),
      myNodeNum: json['myNodeNum'] as int? ?? 0,
      autoStart: json['autoStart'] as bool? ?? false,
    );
  }

  MeshtasticConfig copyWith({
    String? bleDeviceId,
    String? mqttBroker,
    int? mqttPort,
    String? mqttUser,
    String? mqttPass,
    String? httpHost,
    int? httpPort,
    String? region,
    MeshtasticTransport? activeTransport,
    int? myNodeNum,
    bool? autoStart,
  }) {
    return MeshtasticConfig(
      bleDeviceId: bleDeviceId ?? this.bleDeviceId,
      mqttBroker: mqttBroker ?? this.mqttBroker,
      mqttPort: mqttPort ?? this.mqttPort,
      mqttUser: mqttUser ?? this.mqttUser,
      mqttPass: mqttPass ?? this.mqttPass,
      httpHost: httpHost ?? this.httpHost,
      httpPort: httpPort ?? this.httpPort,
      region: region ?? this.region,
      activeTransport: activeTransport ?? this.activeTransport,
      myNodeNum: myNodeNum ?? this.myNodeNum,
      autoStart: autoStart ?? this.autoStart,
    );
  }
}
