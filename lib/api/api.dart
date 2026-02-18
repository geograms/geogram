/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Unified API facade for transport-agnostic device communication.
 *
 * All operations require a target callsign and are routed through
 * ConnectionManager to the best available transport (LAN, BLE, Station).
 *
 * Usage:
 * ```dart
 * final api = GeogramApi();
 *
 * // Get status from a device
 * final status = await api.status.get('X3STATION');
 *
 * // List alerts from a device
 * final alerts = await api.alerts.list('X3STATION');
 *
 * // Send feedback
 * await api.feedback.point('X3STATION', 'alert', alertId);
 * ```
 */

import '../connection/connection_manager.dart';
import 'api_response.dart';

// Endpoint modules
import 'endpoints/status_api.dart';
import 'endpoints/chat_api.dart';
import 'endpoints/alerts_api.dart';
import 'endpoints/places_api.dart';
import 'endpoints/events_api.dart';
import 'endpoints/blog_api.dart';
import 'endpoints/videos_api.dart';
import 'endpoints/feedback_api.dart';
import 'endpoints/backup_api.dart';
import 'endpoints/dm_api.dart';
import 'endpoints/updates_api.dart';
import 'endpoints/console_api.dart';

export 'api_response.dart';
export 'api_error.dart';
export 'endpoints/status_api.dart';
export 'endpoints/chat_api.dart';
export 'endpoints/alerts_api.dart';
export 'endpoints/places_api.dart';
export 'endpoints/events_api.dart';
export 'endpoints/blog_api.dart';
export 'endpoints/videos_api.dart';
export 'endpoints/feedback_api.dart';
export 'endpoints/backup_api.dart';
export 'endpoints/dm_api.dart';
export 'endpoints/updates_api.dart';
export 'endpoints/console_api.dart';

/// Main API facade for device-to-device communication
///
/// Provides a unified interface for all API operations, routing
/// requests through ConnectionManager to the best available transport.
class GeogramApi {
  static final GeogramApi _instance = GeogramApi._internal();
  factory GeogramApi() => _instance;
  GeogramApi._internal();

  final ConnectionManager _connection = ConnectionManager();

  // ============================================================
  // Endpoint Modules
  // ============================================================

  /// Status and device info API
  late final StatusApi status = StatusApi(this);

  /// Chat rooms and messages API
  late final ChatApi chat = ChatApi(this);

  /// Alerts API
  late final AlertsApi alerts = AlertsApi(this);

  /// Places API
  late final PlacesApi places = PlacesApi(this);

  /// Events API
  late final EventsApi events = EventsApi(this);

  /// Blog posts API
  late final BlogApi blog = BlogApi(this);

  /// Videos API
  late final VideosApi videos = VideosApi(this);

  /// Feedback API (points, likes, comments)
  late final FeedbackApi feedback = FeedbackApi(this);

  /// Backup API
  late final BackupApi backup = BackupApi(this);

  /// Direct messages API
  late final DmApi dm = DmApi(this);

  /// Updates API
  late final UpdatesApi updates = UpdatesApi(this);

  /// Console command API
  late final ConsoleApi console = ConsoleApi(this);

  // ============================================================
  // Core Request Methods
  // ============================================================

  /// Make a GET request to a device
  Future<ApiResponse<T>> get<T>(
    String callsign,
    String path, {
    Map<String, dynamic>? queryParams,
    Map<String, String>? headers,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
  }) async {
    final fullPath = _buildPath(path, queryParams);
    final result = await _connection.apiRequest(
      callsign: callsign,
      method: 'GET',
      path: fullPath,
      headers: headers,
      queueIfOffline: queueIfOffline,
    );
    return ApiResponse.fromTransportResult(result, fromJson: fromJson);
  }

  /// Make a POST request to a device
  Future<ApiResponse<T>> post<T>(
    String callsign,
    String path, {
    Object? body,
    Map<String, dynamic>? queryParams,
    Map<String, String>? headers,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
  }) async {
    final fullPath = _buildPath(path, queryParams);
    final result = await _connection.apiRequest(
      callsign: callsign,
      method: 'POST',
      path: fullPath,
      headers: headers,
      body: body,
      queueIfOffline: queueIfOffline,
    );
    return ApiResponse.fromTransportResult(result, fromJson: fromJson);
  }

  /// Make a PUT request to a device
  Future<ApiResponse<T>> put<T>(
    String callsign,
    String path, {
    Object? body,
    Map<String, dynamic>? queryParams,
    Map<String, String>? headers,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
  }) async {
    final fullPath = _buildPath(path, queryParams);
    final result = await _connection.apiRequest(
      callsign: callsign,
      method: 'PUT',
      path: fullPath,
      headers: headers,
      body: body,
      queueIfOffline: queueIfOffline,
    );
    return ApiResponse.fromTransportResult(result, fromJson: fromJson);
  }

  /// Make a DELETE request to a device
  Future<ApiResponse<T>> delete<T>(
    String callsign,
    String path, {
    Map<String, dynamic>? queryParams,
    Map<String, String>? headers,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
  }) async {
    final fullPath = _buildPath(path, queryParams);
    final result = await _connection.apiRequest(
      callsign: callsign,
      method: 'DELETE',
      path: fullPath,
      headers: headers,
      queueIfOffline: queueIfOffline,
    );
    return ApiResponse.fromTransportResult(result, fromJson: fromJson);
  }

  /// Make a PATCH request to a device
  Future<ApiResponse<T>> patch<T>(
    String callsign,
    String path, {
    Object? body,
    Map<String, dynamic>? queryParams,
    Map<String, String>? headers,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
  }) async {
    final fullPath = _buildPath(path, queryParams);
    final result = await _connection.apiRequest(
      callsign: callsign,
      method: 'PATCH',
      path: fullPath,
      headers: headers,
      body: body,
      queueIfOffline: queueIfOffline,
    );
    return ApiResponse.fromTransportResult(result, fromJson: fromJson);
  }

  /// Make a list request with pagination support
  Future<ApiListResponse<T>> list<T>(
    String callsign,
    String path, {
    Map<String, dynamic>? queryParams,
    Map<String, String>? headers,
    required T Function(dynamic json) itemFromJson,
    String listKey = 'items',
    bool queueIfOffline = false,
  }) async {
    final fullPath = _buildPath(path, queryParams);
    final result = await _connection.apiRequest(
      callsign: callsign,
      method: 'GET',
      path: fullPath,
      headers: headers,
      queueIfOffline: queueIfOffline,
    );
    return ApiListResponse.fromTransportResult(
      result,
      itemFromJson: itemFromJson,
      listKey: listKey,
    );
  }

  // ============================================================
  // Direct Message Helpers
  // ============================================================

  /// Send a direct message using NOSTR-signed event
  Future<ApiResponse<void>> sendDirectMessage(
    String callsign,
    Map<String, dynamic> signedEvent, {
    bool queueIfOffline = true,
    Duration? ttl,
  }) async {
    final result = await _connection.sendDM(
      callsign: callsign,
      signedEvent: signedEvent,
      queueIfOffline: queueIfOffline,
      ttl: ttl,
    );
    return ApiResponse.fromTransportResult(result);
  }

  /// Send a chat room message using NOSTR-signed event
  Future<ApiResponse<void>> sendChatMessage(
    String callsign,
    String roomId,
    Map<String, dynamic> signedEvent, {
    bool queueIfOffline = true,
  }) async {
    final result = await _connection.sendChat(
      callsign: callsign,
      roomId: roomId,
      signedEvent: signedEvent,
      queueIfOffline: queueIfOffline,
    );
    return ApiResponse.fromTransportResult(result);
  }

  // ============================================================
  // Reachability
  // ============================================================

  /// Check if a device is reachable via any transport
  Future<bool> isReachable(String callsign) {
    return _connection.isReachable(callsign);
  }

  /// Get list of transports that can reach a device
  Future<List<String>> getAvailableTransports(String callsign) {
    return _connection.getAvailableTransports(callsign);
  }

  // ============================================================
  // Helpers
  // ============================================================

  String _buildPath(String path, Map<String, dynamic>? queryParams) {
    if (queryParams == null || queryParams.isEmpty) {
      return path;
    }

    final uri = Uri.parse(path);
    final allParams = Map<String, dynamic>.from(uri.queryParameters);

    // Add new params, converting values to strings
    for (final entry in queryParams.entries) {
      if (entry.value != null) {
        allParams[entry.key] = entry.value.toString();
      }
    }

    if (allParams.isEmpty) {
      return uri.path;
    }

    final queryString = allParams.entries
        .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');

    return '${uri.path}?$queryString';
  }

  /// Get the underlying ConnectionManager (for advanced use)
  ConnectionManager get connection => _connection;
}
