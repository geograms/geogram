/// Device Proxy Mixin — shared device-to-HTTP proxy routing.
///
/// Shared by both `StationServer` (Desktop) and `PureStationServer` (CLI).
/// The station proxies HTTP requests to connected devices via WebSocket.
///
/// Fixes applied:
///   1. UTF-8 encoding for response bodies (fixes Latin-1 500 errors)
///   2. Multi-device failover for API/meet routes
///   3. Priority-based device ordering
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../util/app_constants.dart';

/// Interface that PureConnectedClient must satisfy for the proxy mixin.
/// Both station implementations already have these fields on their
/// PureConnectedClient class.
abstract class DeviceProxyClient {
  String get id;
  String? get callsign;
  String? get nickname;
  WebSocket get socket;
  int get successCount;
  set successCount(int value);
  int get failCount;
  set failCount(int value);
  double get successRate;
  int get priority;
}

/// Abstract contract that the station must fulfil for device proxying.
mixin DeviceProxyMixin {
  // ── Abstract contract ────────────────────────────────────────────

  /// Return all connected clients.
  Map<String, DeviceProxyClient> get proxyClients;

  /// Pending proxy requests waiting for device response.
  Map<String, Completer<Map<String, dynamic>>> get proxyPendingRequests;

  /// Log a message at the given level.
  void proxyLog(String level, String message);

  // ── Path detection ───────────────────────────────────────────────

  /// Check if path is a callsign API path: /{callsign}/api/*
  bool isCallsignApiPath(String path) {
    return RegExp(r'^/([A-Za-z0-9]+)/api/').hasMatch(path);
  }

  /// Check if path is a callsign meet path: /{callsign}/meet/*
  bool isCallsignMeetPath(String path) {
    return RegExp(r'^/([A-Za-z0-9]+)/meet/').hasMatch(path);
  }

  /// Check if path is a callsign download path: /{identifier}/download/
  bool isCallsignDownloadPath(String path) {
    return RegExp(r'^/([A-Za-z0-9_-]+)/download/?$').hasMatch(path);
  }

  /// Check if path looks like a callsign or nickname for WWW serving.
  bool isCallsignOrNicknamePath(String path) {
    if (path.length < 2) return false;
    final firstPart = path.substring(1).split('/').first;
    if (firstPart.isEmpty) return false;

    // Check if it's a callsign (X followed by alphanumeric)
    final isCallsign =
        RegExp(r'^X[0-9][A-Z0-9]{3,}$', caseSensitive: false).hasMatch(firstPart);
    if (isCallsign) return true;

    // Check if it's a valid nickname (alphanumeric with - and _, 2+ chars)
    // Must not conflict with reserved paths
    const reservedPaths = {'api', 'ws', 'tiles', 'cli', 'ssl', 'acme', '.well-known'};
    if (reservedPaths.contains(firstPart.toLowerCase())) return false;

    return RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]+$').hasMatch(firstPart);
  }

  // ── Client lookup ────────────────────────────────────────────────

  /// Find a connected client by nickname or callsign (first match).
  DeviceProxyClient? findConnectedClientByIdentifier(String identifier) {
    final lowerIdentifier = identifier.toLowerCase();
    for (final client in proxyClients.values) {
      if (client.callsign?.toLowerCase() == lowerIdentifier) return client;
    }
    for (final client in proxyClients.values) {
      if (client.nickname?.toLowerCase() == lowerIdentifier) return client;
    }
    return null;
  }

  /// Find ALL connected clients matching a callsign or nickname.
  /// Sorted by priority first (lower = higher priority), then by success rate.
  List<DeviceProxyClient> findAllClientsByIdentifier(String identifier) {
    final lower = identifier.toLowerCase();
    final matches = proxyClients.values
        .where((c) =>
            c.callsign?.toLowerCase() == lower ||
            (c.nickname != null && c.nickname!.toLowerCase() == lower))
        .toList();
    matches.sort((a, b) {
      // Priority: lower number = higher priority, 0 means "no priority set" → sort last
      final aPri = a.priority > 0 ? a.priority : 999;
      final bPri = b.priority > 0 ? b.priority : 999;
      if (aPri != bPri) return aPri.compareTo(bPri);
      return b.successRate.compareTo(a.successRate);
    });
    return matches;
  }

  // ── Single device proxy ──────────────────────────────────────────

  /// Proxy a request to a single device. Returns the response map.
  /// Updates successCount/failCount on the client.
  Future<Map<String, dynamic>?> proxySingleDevice(
    DeviceProxyClient client,
    String method,
    String path,
    String headers,
    String body,
  ) async {
    final requestId = '${DateTime.now().millisecondsSinceEpoch}_${client.id}';
    final proxyRequest = {
      'type': 'HTTP_REQUEST',
      'requestId': requestId,
      'method': method,
      'path': path,
      'headers': headers,
      'body': body,
    };

    final completer = Completer<Map<String, dynamic>>();
    proxyPendingRequests[requestId] = completer;

    try {
      client.socket.add(jsonEncode(proxyRequest));
      final response = await completer.future.timeout(const Duration(seconds: 5));
      final statusCode = response['statusCode'] as int? ?? 500;
      if (statusCode >= 200 && statusCode < 400) {
        client.successCount++;
      } else if (statusCode == 404) {
        // 404 is not the device's fault, don't penalize
      } else {
        client.failCount++;
      }
      return response;
    } on TimeoutException {
      client.failCount++;
      return null;
    } catch (e) {
      client.failCount++;
      return null;
    } finally {
      proxyPendingRequests.remove(requestId);
    }
  }

  // ── Multi-device failover ────────────────────────────────────────

  /// Try all devices for a callsign/nickname sequentially (priority + responsiveness).
  /// Returns the first 2xx/3xx response, or last non-null response, or null.
  Future<Map<String, dynamic>?> proxyToAnyDevice(
    String identifier,
    String method,
    String path, {
    String headers = '',
    String body = '',
  }) async {
    final clients = findAllClientsByIdentifier(identifier);
    if (clients.isEmpty) return null;

    Map<String, dynamic>? lastResponse;
    for (final client in clients) {
      final response = await proxySingleDevice(client, method, path, headers, body);
      if (response != null) {
        lastResponse = response;
        final statusCode = response['statusCode'] as int? ?? 500;
        if (statusCode >= 200 && statusCode < 400) {
          return response;
        }
      }
    }
    return lastResponse;
  }

  // ── API/Meet proxy handler ───────────────────────────────────────

  /// Handle /{callsign}/api/* or /{callsign}/meet/* requests.
  /// Uses multi-device failover (Fix 2) and forwards auth headers.
  Future<void> handleCallsignApiProxy(HttpRequest request) async {
    final path = request.uri.path;

    // Parse path: /{callsign}/api/{endpoint} or /{callsign}/meet/{endpoint}
    final regex = RegExp(r'^/([A-Za-z0-9]+)(/(?:api|meet)/.*)$');
    final match = regex.firstMatch(path);

    if (match == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid path format'}));
      return;
    }

    final callsign = match.group(1)!;
    final query = request.uri.query;
    final apiPath = query.isEmpty
        ? match.group(2)!
        : '${match.group(2)!}?$query';

    // Check if any device is connected for this callsign
    final clients = findAllClientsByIdentifier(callsign);
    if (clients.isEmpty) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Device not connected',
        'callsign': callsign,
        'message': 'The device $callsign is not currently connected to this station',
      }));
      return;
    }

    proxyLog('INFO',
        'Device proxy: ${request.method} $path -> $callsign $apiPath (${clients.length} device(s))');

    // Forward auth-relevant headers to the device
    final forwardedHeaders = <String, String>{};
    final cookie = request.headers.value('cookie');
    if (cookie != null) forwardedHeaders['cookie'] = cookie;
    final authorization = request.headers.value('authorization');
    if (authorization != null) forwardedHeaders['authorization'] = authorization;

    // Read request body once
    String requestBody = '';
    if (request.contentLength > 0) {
      requestBody = await utf8.decodeStream(request);
    }

    // Multi-device failover (5s per device, sorted by priority+successRate)
    final response = await proxyToAnyDevice(
      callsign,
      request.method,
      apiPath,
      headers: jsonEncode(forwardedHeaders),
      body: requestBody,
    );

    if (response == null) {
      request.response.statusCode = 504;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Gateway Timeout',
        'message': 'No device responded for ${callsign.toUpperCase()}',
      }));
      return;
    }

    request.response.statusCode = response['statusCode'] ?? 500;
    if (response['responseHeaders'] != null) {
      try {
        final headers =
            jsonDecode(response['responseHeaders'] as String) as Map<String, dynamic>;
        const skipHeaders = {'transfer-encoding', 'content-length', 'connection'};
        headers.forEach((key, value) {
          final lk = key.toLowerCase();
          if (skipHeaders.contains(lk)) return;
          if (lk == 'content-type') {
            final ct = value.toString();
            final parts = ct.split(';');
            final mimeType = parts.first.trim();
            final mimeParts = mimeType.split('/');
            if (mimeParts.length == 2) {
              final charset = ct.contains('charset=')
                  ? ct.split('charset=').last.split(';').first.trim()
                  : null;
              request.response.headers.contentType =
                  ContentType(mimeParts[0], mimeParts[1], charset: charset);
            }
          } else {
            try {
              request.response.headers.set(key, value.toString());
            } catch (_) {}
          }
        });
      } catch (_) {}
    }

    _writeResponseBody(request, response);

    proxyLog('INFO',
        'Device proxy response: ${response['statusCode']} for $callsign $apiPath');
  }

  // ── WWW proxy handler ────────────────────────────────────────────

  /// Handle /{identifier}/* — serve WWW/app collection from device.
  /// Uses UTF-8 encoding (Fix 1) and multi-device failover.
  Future<void> handleCallsignOrNicknameWww(HttpRequest request) async {
    final path = request.uri.path;
    final parts = path.substring(1).split('/');
    final identifier = parts.first.toLowerCase();

    // Redirect /{identifier} to /{identifier}/ for proper relative path resolution
    if (parts.length == 1 && !path.endsWith('/')) {
      request.response.statusCode = 301;
      request.response.headers.add('Location', '$path/');
      return;
    }

    // Get file path - filter out empty parts from trailing slashes
    final subParts = parts.sublist(1).where((p) => p.isNotEmpty).toList();
    final filePath = subParts.isNotEmpty ? subParts.join('/') : 'index.html';

    // Check if any client matches this identifier
    final clients = findAllClientsByIdentifier(identifier);
    if (clients.isEmpty) {
      request.response.statusCode = 404;
      request.response.write('Device not connected');
      return;
    }

    // Route to the appropriate collection based on the first path segment
    String appPath;
    if (subParts.isNotEmpty && knownAppTypesConst.contains(subParts.first.toLowerCase())) {
      final app = subParts.first.toLowerCase();
      final rest = subParts.length > 1 ? subParts.sublist(1).join('/') : '';
      appPath = '/$app/${rest.isEmpty ? "index.html" : rest}';
    } else {
      appPath = '/www/$filePath';
    }

    // Try all devices sequentially (priority + most responsive first)
    final response = await proxyToAnyDevice(identifier, 'GET', appPath);

    if (response == null) {
      request.response.statusCode = 504;
      request.response.write('Gateway Timeout: No device responded');
      return;
    }

    request.response.statusCode = response['statusCode'] ?? 500;

    // Use Content-Type from device response headers if available
    String? contentType;
    if (response['responseHeaders'] != null) {
      try {
        final headers =
            jsonDecode(response['responseHeaders'] as String) as Map<String, dynamic>;
        headers.forEach((key, value) {
          if (key.toLowerCase() == 'content-type') {
            contentType = value.toString();
          }
        });
      } catch (_) {}
    }
    if (contentType == null) {
      final ext = appPath.split('.').last.toLowerCase();
      const contentTypes = {
        'html': 'text/html',
        'htm': 'text/html',
        'css': 'text/css',
        'js': 'application/javascript',
        'json': 'application/json',
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'gif': 'image/gif',
        'svg': 'image/svg+xml',
        'ico': 'image/x-icon',
        'txt': 'text/plain',
      };
      contentType = contentTypes[ext] ?? 'application/octet-stream';
    }

    // Fix 1: Ensure charset=utf-8 for text content types
    if (contentType!.startsWith('text/') && !contentType!.contains('charset')) {
      contentType = '$contentType; charset=utf-8';
    }
    request.response.headers.set('Content-Type', contentType!);

    _writeResponseBody(request, response);
  }

  // ── Generic request-to-device proxy ──────────────────────────────

  /// Proxy an HTTP request to a connected device via WebSocket (multi-device aware).
  Future<void> proxyRequestToDevice(
      HttpRequest request, String callsign, String apiPath) async {
    final clients = findAllClientsByIdentifier(callsign);
    if (clients.isEmpty) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Device not connected',
        'callsign': callsign,
        'message': 'The device $callsign is not currently connected to this station',
      }));
      return;
    }

    proxyLog('INFO',
        'Device proxy: ${request.method} -> $callsign $apiPath (${clients.length} device(s))');

    // Read request body first (can only be read once)
    String requestBody = '';
    if (request.contentLength > 0) {
      requestBody = await utf8.decodeStream(request);
    }

    // Try all devices sequentially
    final response = await proxyToAnyDevice(
      callsign,
      request.method,
      apiPath,
      headers: jsonEncode({}),
      body: requestBody,
    );

    if (response == null) {
      request.response.statusCode = 504;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Gateway Timeout',
        'message': 'No device responded for ${callsign.toUpperCase()}',
      }));
      return;
    }

    request.response.statusCode = response['statusCode'] ?? 500;
    if (response['responseHeaders'] != null) {
      try {
        final headers =
            jsonDecode(response['responseHeaders'] as String) as Map<String, dynamic>;
        headers.forEach((key, value) {
          if (key.toLowerCase() == 'content-type') {
            final ct = value.toString();
            if (ct.contains('json')) {
              request.response.headers.contentType = ContentType.json;
            } else if (ct.contains('html')) {
              request.response.headers.contentType = ContentType.html;
            } else if (ct.contains('text')) {
              request.response.headers.contentType = ContentType.text;
            }
          }
        });
      } catch (_) {}
    }

    _writeResponseBody(request, response);

    proxyLog('INFO',
        'Device proxy response: ${response['statusCode']} for $callsign $apiPath');
  }

  // ── Helpers ──────────────────────────────────────────────────────

  /// Write response body using UTF-8 encoding (Fix 1: avoids Latin-1 errors).
  void _writeResponseBody(HttpRequest request, Map<String, dynamic> response) {
    final body = response['responseBody'] ?? '';
    final isBase64 = response['isBase64'] == true;
    if (isBase64) {
      request.response.add(base64Decode(body));
    } else {
      // Fix 1: Use utf8.encode instead of write() to avoid Latin-1 encoding errors
      // with characters like → (U+2192)
      request.response.add(utf8.encode(body));
    }
  }
}
