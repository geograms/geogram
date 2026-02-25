/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

class AtprotoBridgeConfig {
  final String pdsUrl;
  final String appViewUrl;
  final String identifier;
  final String password;
  final bool enabled;

  const AtprotoBridgeConfig({
    required this.pdsUrl,
    required this.appViewUrl,
    required this.identifier,
    required this.password,
    this.enabled = false,
  });

  factory AtprotoBridgeConfig.defaults() {
    return const AtprotoBridgeConfig(
      pdsUrl: 'http://127.0.0.1:8080',
      appViewUrl: 'https://public.api.bsky.app',
      identifier: '',
      password: '',
      enabled: false,
    );
  }

  factory AtprotoBridgeConfig.fromJson(Map<String, dynamic> json) {
    return AtprotoBridgeConfig(
      pdsUrl: json['pdsUrl'] as String? ?? 'http://127.0.0.1:8080',
      appViewUrl:
          json['appViewUrl'] as String? ?? 'https://public.api.bsky.app',
      identifier: json['identifier'] as String? ?? '',
      password: json['password'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'pdsUrl': pdsUrl,
    'appViewUrl': appViewUrl,
    'identifier': identifier,
    'password': password,
    'enabled': enabled,
  };

  AtprotoBridgeConfig copyWith({
    String? pdsUrl,
    String? appViewUrl,
    String? identifier,
    String? password,
    bool? enabled,
  }) {
    return AtprotoBridgeConfig(
      pdsUrl: pdsUrl ?? this.pdsUrl,
      appViewUrl: appViewUrl ?? this.appViewUrl,
      identifier: identifier ?? this.identifier,
      password: password ?? this.password,
      enabled: enabled ?? this.enabled,
    );
  }
}
