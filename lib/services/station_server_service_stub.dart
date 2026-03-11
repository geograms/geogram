/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Stub for station_server_service.dart — used on web where the local
 * station HTTP server (which depends on sqlite3/FFI) is unavailable.
 */

import '../server/karma/karma_store.dart';
import '../server/karma/karma_leaderboard.dart';

class StationServerSettings {
  int port;
  bool enabled;

  StationServerSettings({
    this.port = 3456,
    this.enabled = false,
  });

  factory StationServerSettings.fromJson(Map<String, dynamic> json) {
    return StationServerSettings(
      port: json['port'] as int? ?? 3456,
      enabled: json['enabled'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'port': port,
    'enabled': enabled,
  };
}

/// Stub StationServerService that compiles on web but does nothing.
class StationServerService {
  static final StationServerService _instance = StationServerService._internal();
  factory StationServerService() => _instance;
  StationServerService._internal();

  StationServerSettings _settings = StationServerSettings();

  int? get runningPort => null;
  bool get isRunning => false;
  String? get dataDir => null;
  StationServerSettings get settings => _settings;

  Future<void> initialize() async {}
  Future<bool> start() async => false;
  Future<void> stop() async {}
  Future<void> updateSettings(StationServerSettings settings) async {
    _settings = settings;
  }
  Map<String, dynamic> getStatus() => {'running': false};

  // Karma stubs
  KarmaStore get karmaStore => throw UnsupportedError('Karma not available on web');
  KarmaLeaderboard get karmaLeaderboard => throw UnsupportedError('Karma not available on web');
  Future<int> karmaRecord({
    required String callsign,
    required String action,
    Map<String, dynamic> meta = const {},
  }) async => 0;
}
