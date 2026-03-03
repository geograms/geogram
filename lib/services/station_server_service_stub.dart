/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Stub for station_server_service.dart — used on web where the local
 * station HTTP server (which depends on sqlite3/FFI) is unavailable.
 */

/// Stub StationServerService that compiles on web but does nothing.
class StationServerService {
  static final StationServerService _instance = StationServerService._internal();
  factory StationServerService() => _instance;
  StationServerService._internal();

  int? get runningPort => null;
  bool get isRunning => false;

  Future<void> initialize() async {}
  Future<bool> start() async => false;
  Future<void> stop() async {}
  Map<String, dynamic> getStatus() => {'running': false};
}
