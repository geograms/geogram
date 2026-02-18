/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Console command API endpoint.
 */

import '../api.dart';

/// Result of a console command execution.
class ConsoleResult {
  final String output;
  final String path;

  const ConsoleResult({required this.output, required this.path});

  factory ConsoleResult.fromJson(Map<String, dynamic> json) {
    return ConsoleResult(
      output: json['output'] as String? ?? '',
      path: json['path'] as String? ?? '/',
    );
  }

  @override
  String toString() => 'ConsoleResult(path: $path, output: ${output.length} chars)';
}

/// Console API — execute CLI commands on a station via /api/cli.
class ConsoleApi {
  final GeogramApi _api;

  ConsoleApi(this._api);

  /// Execute a console command on the target station.
  ///
  /// Navigation state (cd) is preserved across calls on the server side.
  /// Returns the command output and current path.
  Future<ApiResponse<ConsoleResult>> execute(String callsign, String command) {
    return _api.post<ConsoleResult>(
      callsign,
      '/api/cli',
      body: {'command': command},
      fromJson: (json) => ConsoleResult.fromJson(json as Map<String, dynamic>),
    );
  }
}
