/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_client;

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
      print(
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

/// Stream an HTTP GET response directly to a file, computing SHA1 incrementally.
///
/// Downloads [url] to [targetPath] via a `.tmp` intermediate file.
/// Returns `(success, sha1, bytesWritten)`.
/// Aborts if the download exceeds [maxBytes] (default 500 MB).
///
/// ```dart
/// final result = await streamDownloadToFile(
///   Uri.parse('https://example.com/large.bin'),
///   '/tmp/large.bin',
///   headers: {'Authorization': 'Bearer token'},
/// );
/// if (result.success) print('SHA1: ${result.sha1}');
/// ```
Future<({bool success, String? sha1, int bytesWritten})> streamDownloadToFile(
  Uri url,
  String targetPath, {
  Map<String, String>? headers,
  int maxBytes = 500 * 1024 * 1024,
  Duration timeout = const Duration(minutes: 10),
}) async {
  final tmpPath = '$targetPath.tmp';
  final tmpFile = File(tmpPath);
  return withHttpClient((client) async {
    try {
      final request = http.Request('GET', url);
      if (headers != null) request.headers.addAll(headers);
      final response = await client.send(request).timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (success: false, sha1: null, bytesWritten: 0);
      }

      // Check Content-Length up front if available
      if (response.contentLength != null && response.contentLength! > maxBytes) {
        // Drain the stream to avoid socket leaks, then abort
        await response.stream.drain<void>();
        return (success: false, sha1: null, bytesWritten: 0);
      }

      await tmpFile.parent.create(recursive: true);
      final sink = tmpFile.openWrite();
      final digestOutput = _SingleDigestSink();
      final sha1Input = sha1.startChunkedConversion(digestOutput);
      var totalBytes = 0;

      try {
        await for (final chunk in response.stream) {
          totalBytes += chunk.length;
          if (totalBytes > maxBytes) {
            await sink.close();
            if (await tmpFile.exists()) await tmpFile.delete();
            return (success: false, sha1: null, bytesWritten: totalBytes);
          }
          sink.add(chunk);
          sha1Input.add(chunk);
        }
        sha1Input.close();
        await sink.close();
      } catch (e) {
        await sink.close();
        if (await tmpFile.exists()) await tmpFile.delete();
        rethrow;
      }

      // Atomic rename
      await tmpFile.rename(targetPath);
      return (success: true, sha1: digestOutput.value.toString(), bytesWritten: totalBytes);
    } catch (e) {
      if (await tmpFile.exists()) {
        try { await tmpFile.delete(); } catch (_) {}
      }
      rethrow;
    }
  });
}

/// Minimal [Sink] that captures the single [Digest] produced by a chunked hash.
class _SingleDigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
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
  // Use IOClient with a raw HttpClient so we can force-close connections
  final rawClient = HttpClient();
  rawClient.connectionTimeout = const Duration(seconds: 3);
  rawClient.idleTimeout = const Duration(seconds: 2);
  final client = io_client.IOClient(rawClient);
  try {
    return await operation(client);
  } finally {
    rawClient.close(force: true); // Kill pending connections immediately
  }
}
