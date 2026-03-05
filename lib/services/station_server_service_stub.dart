/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Stub for station_server_service.dart — used on web where the local
 * station HTTP server (which depends on sqlite3/FFI) is unavailable.
 */

import '../server/karma/karma_store.dart';
import '../server/karma/karma_leaderboard.dart';

/// Stub StationServerService that compiles on web but does nothing.
class StationServerService {
  static final StationServerService _instance = StationServerService._internal();
  factory StationServerService() => _instance;
  StationServerService._internal();

  int? get runningPort => null;
  bool get isRunning => false;
  String? get dataDir => null;

  Future<void> initialize() async {}
  Future<bool> start() async => false;
  Future<void> stop() async {}
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
