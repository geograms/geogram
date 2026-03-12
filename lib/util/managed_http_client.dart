/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Exception thrown when the circuit breaker is open (too many consecutive errors).
class HttpCircuitOpenException implements Exception {
  final int consecutiveErrors;
  const HttpCircuitOpenException(this.consecutiveErrors);

  @override
  String toString() =>
      'HttpCircuitOpenException: circuit open after $consecutiveErrors errors';
}

/// HTTP client with built-in circuit breaker for resilient repeated requests.
///
/// Extends [http.BaseClient] so it's a drop-in replacement for [http.Client].
/// All requests flow through [send], which tracks consecutive errors and
/// short-circuits when the failure threshold is reached.
///
/// Usage (persistent, for services that make repeated requests):
/// ```dart
/// final _client = ManagedHttpClient();
/// // ... use like http.Client: _client.get(url), _client.post(url, body: ...)
/// // ... in dispose: _client.close();
/// ```
///
/// The caller is still responsible for adding `.timeout()` per request.
class ManagedHttpClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  int _consecutiveErrors = 0;
  final int circuitBreakerThreshold;
  bool _closed = false;

  ManagedHttpClient({this.circuitBreakerThreshold = 5});

  /// Number of consecutive failed requests.
  int get consecutiveErrors => _consecutiveErrors;

  /// Whether the circuit breaker is open (requests will be rejected).
  bool get isCircuitOpen => _consecutiveErrors >= circuitBreakerThreshold;

  /// Manually reset the circuit breaker.
  void resetCircuit() => _consecutiveErrors = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw StateError('ManagedHttpClient: client is closed');
    }
    if (isCircuitOpen) {
      // Gradually recover: decrement error count each rejected call
      _consecutiveErrors--;
      debugPrint(
        'ManagedHttpClient: circuit open, skipping ${request.url} '
        '(errors=$_consecutiveErrors)',
      );
      throw HttpCircuitOpenException(_consecutiveErrors + 1);
    }
    try {
      final response = await _inner.send(request);
      _consecutiveErrors = 0;
      return response;
    } catch (e) {
      _consecutiveErrors++;
      rethrow;
    }
  }

  @override
  void close() {
    if (!_closed) {
      _closed = true;
      _inner.close();
    }
  }
}

/// Execute a one-shot HTTP operation with a temporary client.
///
/// The client is always closed after [operation] completes or fails.
/// Use this for infrequent/one-off requests where a persistent client
/// is unnecessary.
///
/// ```dart
/// final bytes = await withHttpClient((client) async {
///   final resp = await client.get(url).timeout(Duration(seconds: 10));
///   return resp.bodyBytes;
/// });
/// ```
Future<T> withHttpClient<T>(
  Future<T> Function(http.Client client) operation,
) async {
  final client = http.Client();
  try {
    return await operation(client);
  } finally {
    client.close();
  }
}
