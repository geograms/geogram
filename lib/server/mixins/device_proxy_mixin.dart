/// Device Proxy Mixin — shared device-to-HTTP proxy routing.
///
/// Shared by both `StationServer` (Desktop) and `PureStationServer` (CLI).
/// The station proxies HTTP requests to connected devices via WebSocket.
///
/// Architecture: The station is a pure proxy. ANY request to /{identifier}/*
/// is forwarded to the connected device as-is. The device handles all its own
/// routing (blog, meet, API, static files, downloads, themes).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  set priority(int value);
  DateTime get connectedAt;
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

  /// Reserved station paths that must NOT be proxied to devices.
  static const _reservedPaths = {
    'api', 'ws', 'tiles', 'cli', 'ssl', 'acme', '.well-known',
    'blossom', 'bot', 'console', 'device', 'search', 'updates',
    'download', 'chat', 'web', 'station', 'status', 'alerts',
  };

  /// Check if path targets a device (callsign or nickname as first segment).
  /// This is the single catch-all check — replaces isCallsignApiPath,
  /// isCallsignMeetPath, isCallsignDownloadPath, and isCallsignOrNicknamePath.
  bool isDevicePath(String path) {
    if (path.length < 2) return false;
    final firstPart = path.substring(1).split('/').first;
    if (firstPart.isEmpty) return false;

    // Check if it's a callsign (X followed by digit then alphanumeric)
    final isCallsign =
        RegExp(r'^X[0-9][A-Z0-9]{3,}$', caseSensitive: false).hasMatch(firstPart);
    if (isCallsign) return true;

    // Check if it's a valid nickname (alphanumeric with - and _, 2+ chars)
    // Must not conflict with reserved station paths
    if (_reservedPaths.contains(firstPart.toLowerCase())) return false;

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
  /// Sorted by priority first (lower = higher priority), then by longest connected.
  List<DeviceProxyClient> findAllClientsByIdentifier(String identifier) {
    final lower = identifier.toLowerCase();
    final matches = proxyClients.values
        .where((c) =>
            c.callsign?.toLowerCase() == lower ||
            (c.nickname != null && c.nickname!.toLowerCase() == lower))
        .toList();
    matches.sort((a, b) {
      // Lower priority number = tried first (1=highest, 3=default)
      if (a.priority != b.priority) return a.priority.compareTo(b.priority);
      // Same priority → prefer longest-connected device (oldest connectedAt first)
      return a.connectedAt.compareTo(b.connectedAt);
    });
    return matches;
  }

  /// Find a connected client by its connection ID.
  DeviceProxyClient? findClientById(String id) => proxyClients[id];

  // ── Single device proxy ──────────────────────────────────────────

  /// Proxy a request to a single device. Returns the response map.
  /// Updates successCount/failCount on the client.
  ///
  /// Set [bodyIsBase64] when [body] is a base64-encoded binary
  /// payload (image/video upload) — the device side will decode it
  /// back to raw bytes before handing to its local API.
  Future<Map<String, dynamic>?> proxySingleDevice(
    DeviceProxyClient client,
    String method,
    String path,
    String headers,
    String body, {
    bool bodyIsBase64 = false,
  }) async {
    final requestId = '${DateTime.now().millisecondsSinceEpoch}_${client.id}';
    final proxyRequest = {
      'type': 'HTTP_REQUEST',
      'requestId': requestId,
      'method': method,
      'path': path,
      'headers': headers,
      'body': body,
      if (bodyIsBase64) 'bodyIsBase64': true,
    };

    final completer = Completer<Map<String, dynamic>>();
    proxyPendingRequests[requestId] = completer;

    try {
      client.socket.add(jsonEncode(proxyRequest));
      final response = await completer.future.timeout(const Duration(seconds: 30));
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
    bool bodyIsBase64 = false,
  }) async {
    final clients = findAllClientsByIdentifier(identifier);
    if (clients.isEmpty) return null;

    Map<String, dynamic>? lastResponse;
    for (final client in clients) {
      final response = await proxySingleDevice(
        client,
        method,
        path,
        headers,
        body,
        bodyIsBase64: bodyIsBase64,
      );
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

  // ── Targeted device proxy ───────────────────────────────────────

  /// Proxy an HTTP request to a specific device's API path.
  /// Used by station-local routes (chat, etc.) that know which device to target.
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
        const skipHeaders = {'transfer-encoding', 'content-length', 'connection'};
        headers.forEach((key, value) {
          final lk = key.toLowerCase();
          if (skipHeaders.contains(lk)) return;
          if (lk == 'content-type') {
            final ct = value.toString();
            final ctParts = ct.split(';');
            final mimeType = ctParts.first.trim();
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

  // ── /device/{callsign} proxy ────────────────────────────────────

  /// Handle /device/{callsign} and /device/{callsign}/* requests.
  /// Bare path returns device info JSON; subpath is proxied to the device.
  ///
  /// Query param `target` pins all requests to a specific connection ID —
  /// required for same-callsign multi-device scenarios where challenge and
  /// response must reach the same physical device.
  Future<void> handleDevicePathProxy(HttpRequest request) async {
    final path = request.uri.path;
    final parts = path.substring('/device/'.length).split('/');
    final callsign = parts.first;
    final subPathBase = parts.length > 1 ? '/${parts.sublist(1).join('/')}' : '';

    final client = findConnectedClientByIdentifier(callsign);
    if (client == null) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'callsign': callsign,
        'connected': false,
        'error': 'Device not connected',
      }));
      return;
    }

    // Bare /device/{callsign} → device info
    if (subPathBase.isEmpty) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'callsign': client.callsign,
        'connected': true,
      }));
      return;
    }

    // Build query string for the device, stripping `target` (station-only param)
    final queryParams = Map<String, String>.from(request.uri.queryParameters);
    final targetId = queryParams.remove('target');
    final cleanQuery = queryParams.entries
        .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final devicePath = cleanQuery.isNotEmpty ? '$subPathBase?$cleanQuery' : subPathBase;

    // Forward auth-relevant headers
    final forwardedHeaders = <String, String>{};
    final cookie = request.headers.value('cookie');
    if (cookie != null) forwardedHeaders['cookie'] = cookie;
    final authorization = request.headers.value('authorization');
    if (authorization != null) forwardedHeaders['authorization'] = authorization;
    final contentType = request.headers.value('content-type');
    if (contentType != null) forwardedHeaders['content-type'] = contentType;

    String requestBody = '';
    if (request.contentLength > 0) {
      requestBody = await utf8.decodeStream(request);
    }

    Map<String, dynamic>? response;

    // If a specific target connection ID is given, route only to that device
    if (targetId != null) {
      final targeted = findClientById(targetId);
      if (targeted != null) {
        response = await proxySingleDevice(
          targeted,
          request.method,
          devicePath,
          jsonEncode(forwardedHeaders),
          requestBody,
        );
      }
    } else {
      response = await proxyToAnyDevice(
        callsign,
        request.method,
        devicePath,
        headers: jsonEncode(forwardedHeaders),
        body: requestBody,
      );
    }

    if (response == null) {
      request.response.statusCode = 504;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Gateway Timeout',
        'message': 'No device responded for $callsign',
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
            final ctParts = ct.split(';');
            final mimeType = ctParts.first.trim();
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
  }

  // ── Generic device proxy (pure bridge) ─────────────────────────

  /// Handle ANY /{identifier}/* request — pure proxy to device.
  /// The device handles all routing (blog, meet, API, static, downloads).
  /// Forwards actual HTTP method, auth headers, query strings, and body.
  Future<void> handleGenericDeviceProxy(HttpRequest request) async {
    final path = request.uri.path;
    final parts = path.substring(1).split('/');
    final identifier = parts.first;

    // Redirect /{identifier} to /{identifier}/ for proper relative path resolution
    if (parts.length == 1 && !path.endsWith('/')) {
      request.response.statusCode = 301;
      request.response.headers.add('Location', '$path/');
      return;
    }

    // Check if any device is connected for this identifier
    final clients = findAllClientsByIdentifier(identifier);
    if (clients.isEmpty) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Device not connected',
        'identifier': identifier,
        'message': 'The device $identifier is not currently connected to this station',
      }));
      return;
    }

    // Strip identifier prefix, keep everything after as the sub-path
    final subPath = parts.length > 1 ? '/${parts.sublist(1).join('/')}' : '/';
    final query = request.uri.query;
    final devicePath = query.isEmpty ? subPath : '$subPath?$query';

    proxyLog('INFO',
        'Device proxy: ${request.method} $path -> $identifier $devicePath (${clients.length} device(s))');

    // Forward auth-relevant and content-negotiation headers to the device
    final forwardedHeaders = <String, String>{};
    final cookie = request.headers.value('cookie');
    if (cookie != null) forwardedHeaders['cookie'] = cookie;
    final authorization = request.headers.value('authorization');
    if (authorization != null) forwardedHeaders['authorization'] = authorization;
    final range = request.headers.value('range');
    if (range != null) forwardedHeaders['range'] = range;
    final contentType = request.headers.value('content-type');
    if (contentType != null) forwardedHeaders['content-type'] = contentType;

    // Read request body for POST/PUT/PATCH. Binary uploads (image /
    // video / octet-stream) are base64-encoded so the WebSocket
    // proxy chain (JSON-only) preserves bytes; the device side
    // decodes back to raw before handing to its local API.
    String requestBody = '';
    bool bodyIsBase64 = false;
    if (request.contentLength > 0) {
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
      }
      final ct = (contentType ?? '').toLowerCase();
      final binaryByContentType = ct.startsWith('image/') ||
          ct.startsWith('video/') ||
          ct.startsWith('audio/') ||
          ct.startsWith('application/octet-stream');
      if (binaryByContentType) {
        requestBody = base64Encode(bytes);
        bodyIsBase64 = true;
      } else {
        try {
          requestBody = utf8.decode(bytes);
        } on FormatException {
          // Content-Type lied (or wasn't set) — fall back to base64
          // so a misdeclared upload still goes through.
          requestBody = base64Encode(bytes);
          bodyIsBase64 = true;
        }
      }
    }

    // Multi-device failover (5s per device, sorted by priority+successRate)
    final response = await proxyToAnyDevice(
      identifier,
      request.method,
      devicePath,
      headers: jsonEncode(forwardedHeaders),
      body: requestBody,
      bodyIsBase64: bodyIsBase64,
    );

    if (response == null) {
      request.response.statusCode = 504;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Gateway Timeout',
        'message': 'No device responded for $identifier',
      }));
      return;
    }

    // Write response status and headers
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
            final ctParts = ct.split(';');
            final mimeType = ctParts.first.trim();
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
        'Device proxy response: ${response['statusCode']} for $identifier $devicePath');
  }

  // ── Helpers ──────────────────────────────────────────────────────

  /// Write response body using UTF-8 encoding (avoids Latin-1 errors).
  void _writeResponseBody(HttpRequest request, Map<String, dynamic> response) {
    final body = response['responseBody'] ?? '';
    final isBase64 = response['isBase64'] == true;
    if (isBase64) {
      request.response.add(base64Decode(body));
    } else {
      // Use utf8.encode instead of write() to avoid Latin-1 encoding errors
      // with characters like → (U+2192)
      request.response.add(utf8.encode(body));
    }
  }
}
