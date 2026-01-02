import 'dart:async';
import 'dart:convert';
import 'dart:io' as io if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'log_service.dart';
import 'profile_service.dart';
import 'signing_service.dart';
import 'collection_service.dart';
import 'debug_controller.dart';
import 'security_service.dart';
import 'storage_config.dart';
import 'user_location_service.dart';
import 'chat_service.dart';
import 'direct_message_service.dart';
import 'devices_service.dart';
import 'device_apps_service.dart';
import 'app_args.dart';
import '../version.dart';
import '../models/chat_channel.dart';
import '../models/chat_message.dart';
import '../util/nostr_event.dart';
import '../util/reaction_utils.dart';
import 'audio_service.dart';
import 'backup_service.dart';
import '../models/backup_models.dart';
import 'event_service.dart';
import 'blog_service.dart';
import '../models/blog_post.dart';
import '../models/report.dart';
import 'alert_feedback_service.dart';
import 'alert_sharing_service.dart';
import 'place_feedback_service.dart';
import 'station_alert_service.dart';
import 'station_blog_api.dart';
import 'station_service.dart';
import 'station_server_service.dart';
import 'websocket_service.dart';
import '../bot/models/music_model_info.dart';
import '../bot/models/vision_model_info.dart';
import '../bot/services/music_model_manager.dart';
import '../bot/services/vision_model_manager.dart';
import '../models/station.dart';
import '../util/alert_folder_utils.dart';
import '../util/feedback_comment_utils.dart';
import '../util/feedback_folder_utils.dart';

class LogApiService {
  static final LogApiService _instance = LogApiService._internal();
  factory LogApiService() => _instance;
  LogApiService._internal();

  // Use dynamic to avoid type conflicts between stub and real dart:io
  dynamic _server;

  /// Track when the service started for uptime calculation
  DateTime? _startTime;

  final Map<String, StreamSubscription<double>> _botDownloadSubscriptions = {};

  /// Get the configured port from AppArgs (defaults to 3456)
  int get port => AppArgs().port;

  Future<void> start() async {
    // HTTP server not supported on web
    if (kIsWeb) {
      LogService().log('LogApiService: Not supported on web platform');
      return;
    }

    if (_server != null) {
      LogService().log('LogApiService: Server already running on port $port');
      return;
    }

    try {
      final handler = const shelf.Pipeline()
          .addMiddleware(shelf.logRequests())
          .addHandler(_handleRequest);

      _server = await shelf_io.serve(
        handler,
        io.InternetAddress.anyIPv4,
        port,
      );

      _startTime = DateTime.now();
      LogService().log('LogApiService: Started on http://0.0.0.0:$port (accessible from network)');

      // Auto-initialize ChatService if a chat collection exists
      await _initializeChatServiceIfNeeded();
    } catch (e) {
      LogService().log('LogApiService: Error starting server: $e');
    }
  }

  /// Initialize ChatService if a chat collection exists in the active profile's directory
  /// This is called lazily on each chat request to ensure it picks up collections created
  /// after the API starts (e.g., during deferred initialization)
  /// If createIfMissing is true, creates the chat directory if it doesn't exist.
  Future<bool> _initializeChatServiceIfNeeded({bool createIfMissing = false}) async {
    try {
      final chatService = ChatService();

      // Already initialized
      if (chatService.collectionPath != null) {
        return true;
      }

      // Find chat collection in active profile's directory
      final collectionsDir = CollectionService().collectionsDirectory;
      if (collectionsDir == null) {
        LogService().log('LogApiService: No collections directory available');
        return false;
      }

      final chatDir = io.Directory('$collectionsDir/chat');
      if (!await chatDir.exists()) {
        if (createIfMissing) {
          await chatDir.create(recursive: true);
          LogService().log('LogApiService: Created chat directory at ${chatDir.path}');
        } else {
          return false;
        }
      }

      // Get active profile's npub for admin
      final activeProfile = ProfileService().getProfile();
      final npub = activeProfile.npub;

      // Initialize ChatService with the chat collection
      await chatService.initializeCollection(chatDir.path, creatorNpub: npub);
      LogService().log('LogApiService: ChatService lazily initialized with ${chatService.channels.length} channels');
      return true;
    } catch (e) {
      LogService().log('LogApiService: Error initializing ChatService: $e');
      return false;
    }
  }

  Future<void> stop() async {
    if (kIsWeb) return;

    if (_server != null) {
      await (_server as io.HttpServer).close();
      _server = null;
      LogService().log('LogApiService: Stopped');
    }
  }

  /// Handle API request directly (without HTTP)
  /// Used by WebSocket relay to bypass localhost HTTP connection on Android
  /// which blocks cleartext traffic by default.
  ///
  /// Returns a tuple of (statusCode, headers, body, isBase64)
  /// For binary content types (images, etc.), body is base64 encoded and isBase64 is true
  Future<({int statusCode, Map<String, String> headers, String body, bool isBase64})> handleRequestDirect({
    required String method,
    required String path,
    Map<String, String>? headers,
    String? body,
  }) async {
    try {
      // Create a mock shelf.Request
      // shelf.Request expects URL without leading slash for the path portion
      final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
      final uri = Uri.parse('http://localhost:$port/$normalizedPath');

      // For POST/PUT requests with body, we need to include it
      final request = shelf.Request(
        method,
        uri,
        headers: headers,
        body: body,
      );

      // Call the existing handler
      final response = await _handleRequest(request);

      // Check if response is binary based on Content-Type
      final contentType = response.headers['Content-Type'] ?? response.headers['content-type'] ?? 'application/json';
      final isBinaryContent = contentType.startsWith('image/') ||
          contentType.startsWith('audio/') ||
          contentType.startsWith('video/') ||
          contentType == 'application/octet-stream';

      String responseBody;
      bool isBase64 = false;

      if (isBinaryContent) {
        // Read as bytes and base64 encode for binary content
        final bytes = await response.read().expand((chunk) => chunk).toList();
        responseBody = base64Encode(bytes);
        isBase64 = true;
      } else {
        // Read as string for text content (JSON, HTML, etc.)
        responseBody = await response.readAsString();
      }

      return (
        statusCode: response.statusCode,
        headers: Map<String, String>.from(response.headers),
        body: responseBody,
        isBase64: isBase64,
      );
    } catch (e, stack) {
      LogService().log('handleRequestDirect error: $e');
      LogService().log('Stack: $stack');
      return (
        statusCode: 500,
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode({'error': 'Internal Server Error', 'message': e.toString()}),
        isBase64: false,
      );
    }
  }

  Future<shelf.Response> _handleRequest(shelf.Request request) async {
    // Enable CORS for easier testing
    final headers = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Content-Type': 'application/json',
    };

    if (request.method == 'OPTIONS') {
      return shelf.Response.ok('', headers: headers);
    }

    final urlPath = request.url.path;

    // All API endpoints are under /api/
    // Legacy endpoints (without /api/) are also supported for backward compatibility

    // Log endpoint: /api/log or /log (legacy)
    if ((urlPath == 'api/log' || urlPath == 'log') && request.method == 'GET') {
      return _handleLogRequest(request, headers);
    }

    // Status endpoint: /api/status, /station/status (legacy for discovery)
    if ((urlPath == 'api/status' || urlPath == 'station/status') &&
        request.method == 'GET') {
      return _handleStatusRequest(headers);
    }

    // Files endpoint: /api/files or /files (legacy)
    if ((urlPath == 'api/files' || urlPath == 'files') && request.method == 'GET') {
      return _handleFilesRequest(request, headers);
    }

    // File content endpoint: /api/files/content or /files/content (legacy)
    if ((urlPath == 'api/files/content' || urlPath == 'files/content') && request.method == 'GET') {
      return _handleFileContentRequest(request, headers);
    }

    // Debug API endpoint (only if enabled in security settings)
    if (urlPath == 'api/debug') {
      if (!SecurityService().debugApiEnabled) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Debug API is disabled', 'code': 'DEBUG_API_DISABLED'}),
          headers: headers,
        );
      }
      if (request.method == 'GET') {
        return _handleDebugGetRequest(headers);
      } else if (request.method == 'POST') {
        return await _handleDebugPostRequest(request, headers);
      }
    }

    // Chat API endpoints
    if ((urlPath == 'api/chat' || urlPath == 'api/chat/' || urlPath == 'api/chat/rooms' || urlPath == 'api/chat/rooms/') && request.method == 'GET') {
      return await _handleChatRoomsRequest(request, headers);
    }

    // Chat room messages: GET or POST
    if (urlPath.startsWith('api/chat/') && urlPath.endsWith('/messages')) {
      final roomId = _extractRoomIdFromPath(urlPath);
      if (roomId != null) {
        if (request.method == 'GET') {
          return await _handleChatMessagesRequest(request, roomId, headers);
        } else if (request.method == 'POST') {
          return await _handleChatPostMessageRequest(request, roomId, headers);
        }
      }
    }

    // Chat room files
    if (urlPath.startsWith('api/chat/') && urlPath.endsWith('/files')) {
      final roomId = _extractRoomIdFromPath(urlPath);
      if (roomId != null && request.method == 'GET') {
        return await _handleChatFilesRequest(request, roomId, headers);
      }
    }

    // Chat message reactions
    if (urlPath.startsWith('api/chat/') &&
        urlPath.contains('/messages/') &&
        urlPath.endsWith('/reactions')) {
      return await _handleChatMessageReactionRequest(request, urlPath, headers);
    }

    // Chat message edit/delete endpoints
    // DELETE /api/chat/{roomId}/messages/{timestamp} - Delete own message
    // PUT /api/chat/{roomId}/messages/{timestamp} - Edit own message
    if (urlPath.startsWith('api/chat/') && urlPath.contains('/messages/')) {
      return await _handleChatMessageModificationRequest(request, urlPath, headers);
    }

    // Chat room member management endpoints (RESTRICTED rooms)
    // POST /api/chat/{roomId}/members - Add member
    // DELETE /api/chat/{roomId}/members/{npub} - Remove member
    if (urlPath.startsWith('api/chat/') && urlPath.contains('/members')) {
      return await _handleChatMemberManagementRequest(request, urlPath, headers);
    }

    // Chat room ban management endpoints
    // POST /api/chat/{roomId}/ban/{npub} - Ban user
    // DELETE /api/chat/{roomId}/ban/{npub} - Unban user
    if (urlPath.startsWith('api/chat/') && urlPath.contains('/ban/')) {
      return await _handleChatBanRequest(request, urlPath, headers);
    }

    // Chat room roles endpoint
    // GET /api/chat/{roomId}/roles - Get room roles
    // POST /api/chat/{roomId}/promote - Promote member
    // POST /api/chat/{roomId}/demote - Demote member
    if (urlPath.startsWith('api/chat/') && (urlPath.endsWith('/roles') || urlPath.endsWith('/promote') || urlPath.endsWith('/demote'))) {
      return await _handleChatRolesRequest(request, urlPath, headers);
    }

    // Chat room membership application endpoints
    // POST /api/chat/{roomId}/apply - Apply for membership
    // GET /api/chat/{roomId}/applicants - List pending applicants
    // POST /api/chat/{roomId}/approve/{npub} - Approve applicant
    // DELETE /api/chat/{roomId}/reject/{npub} - Reject applicant
    if (urlPath.startsWith('api/chat/') && (urlPath.endsWith('/apply') || urlPath.contains('/applicants') || urlPath.contains('/approve/') || urlPath.contains('/reject/'))) {
      return await _handleChatApplicationRequest(request, urlPath, headers);
    }

    // DM API endpoints (for device-to-device direct messages)
    // GET /api/dm/conversations - list DM conversations
    if ((urlPath == 'api/dm/conversations' || urlPath == 'api/dm/conversations/') && request.method == 'GET') {
      return await _handleDMConversationsRequest(request, headers);
    }

    // GET/POST /api/dm/{callsign}/messages - get or send DM messages
    if (urlPath.startsWith('api/dm/') && urlPath.endsWith('/messages')) {
      final targetCallsign = _extractCallsignFromDMPath(urlPath);
      if (targetCallsign != null) {
        if (request.method == 'GET') {
          return await _handleDMMessagesRequest(request, targetCallsign, headers);
        } else if (request.method == 'POST') {
          return await _handleDMPostMessageRequest(request, targetCallsign, headers);
        }
      }
    }

    // GET/POST /api/dm/sync/{callsign} - sync DM messages with remote device
    if (urlPath.startsWith('api/dm/sync/')) {
      final targetCallsign = urlPath.substring('api/dm/sync/'.length).toUpperCase();
      if (targetCallsign.isNotEmpty) {
        if (request.method == 'GET') {
          return await _handleDMSyncGetRequest(request, targetCallsign, headers);
        } else if (request.method == 'POST') {
          return await _handleDMSyncPostRequest(request, targetCallsign, headers);
        }
      }
    }

    // GET/POST /api/dm/{callsign}/files/{filename} - DM file uploads and downloads
    final dmFileMatch = RegExp(r'^api/dm/([^/]+)/files/(.+)$').firstMatch(urlPath);
    if (dmFileMatch != null) {
      final senderCallsign = Uri.decodeComponent(dmFileMatch.group(1)!).toUpperCase();
      final filename = Uri.decodeComponent(dmFileMatch.group(2)!);
      if (request.method == 'GET') {
        return await _handleDMFileGetRequest(request, senderCallsign, filename, headers);
      } else if (request.method == 'POST') {
        return await _handleDMFilePostRequest(request, senderCallsign, filename, headers);
      }
    }

    // Backup API endpoints
    if (urlPath.startsWith('api/backup/')) {
      return await _handleBackupRequest(request, urlPath, headers);
    }

    // Events API endpoints (public read-only access to events)
    if (urlPath == 'api/events' || urlPath == 'api/events/' || urlPath.startsWith('api/events/')) {
      return await _handleEventsRequest(request, urlPath, headers);
    }

    // Alerts API endpoints (public read-only access to alerts)
    if (urlPath == 'api/alerts' || urlPath == 'api/alerts/' || urlPath.startsWith('api/alerts/')) {
      return await _handleAlertsRequest(request, urlPath, headers);
    }

    // Blog API endpoints (public read access, authenticated comment posting)
    // Exclude .html files - those are handled by the HTML renderer below
    if ((urlPath == 'api/blog' || urlPath == 'api/blog/' || urlPath.startsWith('api/blog/'))
        && !urlPath.endsWith('.html')) {
      return await _handleBlogRequest(request, urlPath, headers);
    }

    // Blog HTML rendering endpoint: /{identifier}/blog/{filename}.html
    // This is used by p2p.radio to serve blog posts as HTML
    if (urlPath.contains('/blog/') && urlPath.endsWith('.html')) {
      return await _handleBlogHtmlRequest(request, urlPath, headers);
    }

    // Devices API endpoint (for debug - list discovered devices)
    if ((urlPath == 'api/devices' || urlPath == 'api/devices/') && request.method == 'GET') {
      if (!SecurityService().debugApiEnabled) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Debug API is disabled', 'code': 'DEBUG_API_DISABLED'}),
          headers: headers,
        );
      }
      return await _handleDevicesRequest(request, headers);
    }

    // API root: /api/ or /api
    if ((urlPath == 'api' || urlPath == 'api/') && request.method == 'GET') {
      return _handleApiRootRequest(headers);
    }

    // Legacy root endpoint (redirect hint to /api/)
    if ((urlPath == '' || urlPath == '/') && request.method == 'GET') {
      return shelf.Response.ok(
        jsonEncode({
          'message': 'Geogram API available at /api/',
          'api_url': '/api/',
        }),
        headers: headers,
      );
    }

    return shelf.Response.notFound(
      jsonEncode({'error': 'Not found', 'hint': 'API endpoints are available at /api/'}),
      headers: headers,
    );
  }

  /// Handle /api/ root endpoint - list available endpoints
  shelf.Response _handleApiRootRequest(Map<String, String> headers) {
    String callsign = '';
    try {
      final profile = ProfileService().getProfile();
      callsign = profile.callsign;
    } catch (e) {
      // Profile service not initialized
    }

    return shelf.Response.ok(
      jsonEncode({
        'service': 'Geogram Desktop',
        'version': appVersion,
        'type': 'geogram',
        'callsign': callsign,
        'hostname': io.Platform.localHostname,
        'endpoints': {
          '/api/status': 'Device status and location',
          '/api/log': 'Get log entries (supports ?filter=text&limit=100)',
          '/api/files': 'Browse collections (supports ?path=subfolder)',
          '/api/files/content': 'Get file content (supports ?path=file/path)',
          '/api/chat/': 'List chat rooms (supports NOSTR auth for private rooms)',
          '/api/chat/{roomId}/messages': 'GET messages, POST to send (supports NOSTR-signed events)',
          '/api/chat/{roomId}/files': 'List files in a chat room',
          '/api/dm/conversations': 'List direct message conversations',
          '/api/dm/{callsign}/messages': 'GET/POST direct messages with a device',
          '/api/dm/sync/{callsign}': 'Sync DM messages with remote device',
          '/api/backup/settings': 'GET/PUT backup provider settings',
          '/api/backup/clients': 'GET list of backup clients (as provider)',
          '/api/backup/clients/{callsign}': 'GET/DELETE specific backup client',
          '/api/backup/providers': 'GET list of backup providers (as client)',
          '/api/backup/providers/{callsign}': 'POST invite, PUT update, DELETE remove provider',
          '/api/backup/start': 'POST start backup to provider',
          '/api/backup/status': 'GET current backup/restore status',
          '/api/backup/restore': 'POST start restore from provider',
          '/api/backup/discover': 'POST start discovery, GET /api/backup/discover/{id} for status',
          '/api/events': 'List all events (supports ?year=YYYY)',
          '/api/events/{eventId}': 'Get event details',
          '/api/events/{eventId}/items': 'List event files and folders',
          '/api/events/{eventId}/files/{path}': 'Get event file content',
          '/api/events/{eventId}/media': 'List event community media contributors',
          '/api/events/{eventId}/media/{callsign}/files/{name}': 'GET media file or POST upload',
          '/api/events/{eventId}/media/{callsign}/{action}': 'POST approve/suspend/ban contributor',
          '/api/alerts': 'List all alerts (supports ?status=X&lat=X&lon=X&radius=X)',
          '/api/alerts/{alertId}': 'Get alert details',
          '/api/alerts/{alertId}/files/{path}': 'Get alert file (photo)',
          '/api/devices': 'List discovered devices (requires debug API enabled)',
          '/api/debug': 'Debug API - GET for status, POST to trigger actions (requires debug API enabled)',
        },
      }),
      headers: headers,
    );
  }

  /// Handle /api/status and /station/status for discovery compatibility
  shelf.Response _handleStatusRequest(Map<String, String> headers) {
    String callsign = '';
    double? latitude;
    double? longitude;
    String? nickname;
    String? color;
    String? description;

    try {
      final profile = ProfileService().getProfile();
      callsign = profile.callsign;
      nickname = profile.nickname;
      color = profile.preferredColor;
      description = profile.description;

      // Get location: prefer profile, fallback to UserLocationService (GPS/IP-based)
      double? rawLat = profile.latitude;
      double? rawLon = profile.longitude;

      // If profile has no location, try UserLocationService
      if (rawLat == null || rawLon == null) {
        final userLocation = UserLocationService().currentLocation;
        if (userLocation != null && userLocation.isValid) {
          rawLat = userLocation.latitude;
          rawLon = userLocation.longitude;
        }
      }

      // Apply location granularity from security settings
      final (roundedLat, roundedLon) = SecurityService().applyLocationGranularity(
        rawLat,
        rawLon,
      );
      latitude = roundedLat;
      longitude = roundedLon;
    } catch (e) {
      // Profile service not initialized
    }

    final response = <String, dynamic>{
      'service': 'Geogram Desktop',
      'version': appVersion,
      'type': 'desktop',
      'status': 'online',
      'callsign': callsign,
      'name': callsign.isNotEmpty ? callsign : 'Geogram Desktop',
      'hostname': io.Platform.localHostname,
      'platform': io.Platform.operatingSystem,
      'port': port,
    };

    // Add location if available (with privacy precision indicator)
    if (latitude != null && longitude != null) {
      final precisionKm = SecurityService().locationGranularityMeters / 1000;
      response['location'] = {
        'latitude': latitude,
        'longitude': longitude,
        'precision_km': precisionKm.round(),
      };
      response['latitude'] = latitude;
      response['longitude'] = longitude;
    }

    // Add nickname if available
    if (nickname != null && nickname.isNotEmpty) {
      response['nickname'] = nickname;
    }

    // Add preferred color if set
    if (color != null && color.isNotEmpty) {
      response['color'] = color;
    }

    // Add description if set
    if (description != null && description.isNotEmpty) {
      response['description'] = description;
    }

    // Add npub (NOSTR public key) for device identity
    try {
      final profile = ProfileService().getProfile();
      if (profile.npub != null && profile.npub!.isNotEmpty) {
        response['npub'] = profile.npub;
      }
    } catch (e) {
      // Profile service not initialized
    }

    // Add uptime in seconds
    if (_startTime != null) {
      response['uptime'] = DateTime.now().difference(_startTime!).inSeconds;
    }

    return shelf.Response.ok(
      jsonEncode(response),
      headers: headers,
    );
  }

  Future<shelf.Response> _handleLogRequest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final queryParams = request.url.queryParameters;
      final filterText = queryParams['filter'] ?? '';
      final limitParam = queryParams['limit'];

      int? limit;
      if (limitParam != null) {
        limit = int.tryParse(limitParam);
        if (limit == null || limit < 1) {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'Invalid limit parameter'}),
            headers: headers,
          );
        }
      }

      final logService = LogService();
      List<String> messages = logService.messages;

      // Apply filter if specified
      if (filterText.isNotEmpty) {
        messages = messages
            .where((msg) => msg.toLowerCase().contains(filterText.toLowerCase()))
            .toList();
      }

      // Apply limit if specified
      if (limit != null && messages.length > limit) {
        messages = messages.sublist(messages.length - limit);
      }

      final response = {
        'total': messages.length,
        'filter': filterText.isNotEmpty ? filterText : null,
        'limit': limit,
        'logs': messages,
      };

      return shelf.Response.ok(
        jsonEncode(response),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling log request: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  // Hidden files/folders that should never be exposed via API
  static const _hiddenNames = {
    'extra',           // Contains security.json
    'security.json',
    'security.txt',
    '.security',
    '.git',
    '.gitignore',
  };

  Future<shelf.Response> _handleFilesRequest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final queryParams = request.url.queryParameters;
      final relativePath = queryParams['path'] ?? '';

      // Get the collections base path
      final homeDir = io.Platform.environment['HOME'] ??
                      io.Platform.environment['USERPROFILE'] ?? '';
      final collectionsBase = path.join(homeDir, 'Documents', 'geogram', 'collections');

      // Resolve the requested path
      final requestedPath = relativePath.isEmpty
          ? collectionsBase
          : path.join(collectionsBase, relativePath);

      // Security: ensure path is within collections directory
      final normalizedBase = path.normalize(collectionsBase);
      final normalizedPath = path.normalize(requestedPath);
      if (!normalizedPath.startsWith(normalizedBase)) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Access denied: path outside collections directory'}),
          headers: headers,
        );
      }

      // Security: block access to hidden paths
      final pathParts = relativePath.split('/');
      for (final part in pathParts) {
        if (_hiddenNames.contains(part.toLowerCase())) {
          return shelf.Response.forbidden(
            jsonEncode({'error': 'Access denied: protected path'}),
            headers: headers,
          );
        }
      }

      final dir = io.Directory(requestedPath);
      if (!await dir.exists()) {
        // Check if it's a file (but not a hidden one)
        final fileName = path.basename(requestedPath);
        if (_hiddenNames.contains(fileName.toLowerCase())) {
          return shelf.Response.forbidden(
            jsonEncode({'error': 'Access denied: protected file'}),
            headers: headers,
          );
        }

        final file = io.File(requestedPath);
        if (await file.exists()) {
          // Check if parent collection is public
          final collectionPath = _getCollectionPath(relativePath, collectionsBase);
          if (collectionPath != null && !await _isCollectionPublic(collectionPath)) {
            return shelf.Response.forbidden(
              jsonEncode({'error': 'Access denied: collection is not public'}),
              headers: headers,
            );
          }

          final stat = await file.stat();
          return shelf.Response.ok(
            jsonEncode({
              'path': relativePath,
              'type': 'file',
              'name': fileName,
              'size': stat.size,
              'modified': stat.modified.toIso8601String(),
            }),
            headers: headers,
          );
        }
        return shelf.Response.notFound(
          jsonEncode({'error': 'Path not found'}),
          headers: headers,
        );
      }

      // Determine if we're at root level (listing collections)
      final isRootLevel = relativePath.isEmpty;

      // If browsing inside a collection, verify it's public
      if (!isRootLevel) {
        final collectionPath = _getCollectionPath(relativePath, collectionsBase);
        if (collectionPath != null && !await _isCollectionPublic(collectionPath)) {
          return shelf.Response.forbidden(
            jsonEncode({'error': 'Access denied: collection is not public'}),
            headers: headers,
          );
        }
      }

      List<Map<String, dynamic>> entries;

      if (isRootLevel) {
        // At root level, list collections from filesystem
        entries = <Map<String, dynamic>>[];
        await for (final entity in dir.list()) {
          final name = path.basename(entity.path);
          final isDirectory = entity is io.Directory;

          // Skip hidden files/folders
          if (_hiddenNames.contains(name.toLowerCase())) {
            continue;
          }

          // Filter by visibility
          if (isDirectory && !await _isCollectionPublic(entity.path)) {
            continue;
          }

          // For collections, try to get size from tree.json
          int? size;
          if (isDirectory) {
            size = await _getCollectionSize(entity.path);
          } else {
            final stat = await entity.stat();
            size = stat.size;
          }

          entries.add({
            'name': name,
            'type': isDirectory ? 'directory' : 'file',
            'isDirectory': isDirectory,
            'size': size ?? 0,
          });
        }
      } else {
        // Inside a collection - use tree.json for accurate sizes
        entries = await _getEntriesFromTreeJson(relativePath, collectionsBase);
      }

      // Sort: directories first, then by name
      entries.sort((a, b) {
        if (a['isDirectory'] != b['isDirectory']) {
          return a['isDirectory'] ? -1 : 1;
        }
        return (a['name'] as String).compareTo(b['name'] as String);
      });

      return shelf.Response.ok(
        jsonEncode({
          'path': relativePath.isEmpty ? '/' : '/$relativePath',
          'base': collectionsBase,
          'total': entries.length,
          'entries': entries,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling files request: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Get the collection root path from a relative path
  String? _getCollectionPath(String relativePath, String collectionsBase) {
    if (relativePath.isEmpty) return null;
    final parts = relativePath.split('/');
    if (parts.isEmpty) return null;
    return path.join(collectionsBase, parts.first);
  }

  /// Check if a collection is public by reading its security.json
  Future<bool> _isCollectionPublic(String collectionPath) async {
    try {
      final securityFile = io.File(path.join(collectionPath, 'extra', 'security.json'));
      if (!await securityFile.exists()) {
        // No security file = assume public (for backwards compatibility)
        return true;
      }

      final content = await securityFile.readAsString();
      final security = jsonDecode(content) as Map<String, dynamic>;
      final visibility = security['visibility'] as String? ?? 'public';

      // Only allow public collections via API
      // Future: add authentication to allow restricted access
      return visibility.toLowerCase() == 'public';
    } catch (e) {
      LogService().log('LogApiService: Error reading security.json: $e');
      // On error, deny access to be safe
      return false;
    }
  }

  /// Get total size of a collection from its tree.json
  Future<int> _getCollectionSize(String collectionPath) async {
    try {
      final treeJsonFile = io.File(path.join(collectionPath, 'extra', 'tree.json'));
      if (!await treeJsonFile.exists()) {
        return 0;
      }

      final content = await treeJsonFile.readAsString();
      final entries = jsonDecode(content) as List<dynamic>;

      int totalSize = 0;
      void sumSize(List<dynamic> items) {
        for (var item in items) {
          if (item['type'] == 'file') {
            totalSize += (item['size'] as int?) ?? 0;
          } else if (item['type'] == 'directory' && item['children'] != null) {
            sumSize(item['children'] as List<dynamic>);
          }
        }
      }
      sumSize(entries);
      return totalSize;
    } catch (e) {
      return 0;
    }
  }

  /// Get entries from tree.json for a given path inside a collection
  Future<List<Map<String, dynamic>>> _getEntriesFromTreeJson(
    String relativePath,
    String collectionsBase,
  ) async {
    final entries = <Map<String, dynamic>>[];

    try {
      // Parse the path: first part is collection name, rest is subpath
      final parts = relativePath.split('/');
      if (parts.isEmpty) return entries;

      final collectionName = parts.first;
      final collectionPath = path.join(collectionsBase, collectionName);
      final subPath = parts.length > 1 ? parts.sublist(1).join('/') : '';

      // Read tree.json
      final treeJsonFile = io.File(path.join(collectionPath, 'extra', 'tree.json'));
      if (!await treeJsonFile.exists()) {
        // Fall back to filesystem if tree.json doesn't exist
        return await _listDirectoryFallback(path.join(collectionsBase, relativePath));
      }

      final content = await treeJsonFile.readAsString();
      final treeEntries = jsonDecode(content) as List<dynamic>;

      // Navigate to the requested subpath (or root if empty)
      List<dynamic>? currentLevel = treeEntries;

      if (subPath.isNotEmpty) {
        final subParts = subPath.split('/');
        for (var i = 0; i < subParts.length; i++) {
          final targetName = subParts[i];
          Map<String, dynamic>? found;

          for (var entry in currentLevel!) {
            if (entry['name'] == targetName && entry['type'] == 'directory') {
              found = entry as Map<String, dynamic>;
              break;
            }
          }

          if (found == null) {
            // Path not found in tree.json, fall back to filesystem
            return await _listDirectoryFallback(path.join(collectionsBase, relativePath));
          }

          currentLevel = found['children'] as List<dynamic>?;
          if (currentLevel == null) {
            return entries; // Empty directory
          }
        }
      }

      // Return entries at the current level
      for (var entry in currentLevel!) {
        entries.add({
          'name': entry['name'] as String,
          'type': entry['type'] as String,
          'isDirectory': entry['type'] == 'directory',
          'size': entry['size'] as int? ?? 0,
        });
      }
    } catch (e) {
      LogService().log('LogApiService: Error reading tree.json: $e');
      // Fall back to filesystem on error
      return await _listDirectoryFallback(path.join(collectionsBase, relativePath));
    }

    return entries;
  }

  /// Fallback: list directory from filesystem when tree.json unavailable
  Future<List<Map<String, dynamic>>> _listDirectoryFallback(String dirPath) async {
    final entries = <Map<String, dynamic>>[];
    final dir = io.Directory(dirPath);

    if (!await dir.exists()) return entries;

    await for (final entity in dir.list()) {
      final name = path.basename(entity.path);
      final isDirectory = entity is io.Directory;

      // Skip hidden files/folders
      if (_hiddenNames.contains(name.toLowerCase())) {
        continue;
      }

      final stat = await entity.stat();
      entries.add({
        'name': name,
        'type': isDirectory ? 'directory' : 'file',
        'isDirectory': isDirectory,
        'size': isDirectory ? 0 : stat.size,
      });
    }

    return entries;
  }

  /// Handle request to get file content (for tail/cat/head commands)
  Future<shelf.Response> _handleFileContentRequest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final queryParams = request.url.queryParameters;
      final relativePath = queryParams['path'] ?? '';

      if (relativePath.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing path parameter'}),
          headers: headers,
        );
      }

      // Get the collections base path
      final homeDir = io.Platform.environment['HOME'] ??
                      io.Platform.environment['USERPROFILE'] ?? '';
      final collectionsBase = path.join(homeDir, 'Documents', 'geogram', 'collections');

      // Resolve the requested path
      final requestedPath = path.join(collectionsBase, relativePath);

      // Security: ensure path is within collections directory
      final normalizedBase = path.normalize(collectionsBase);
      final normalizedPath = path.normalize(requestedPath);
      if (!normalizedPath.startsWith(normalizedBase)) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Access denied: path outside collections directory'}),
          headers: headers,
        );
      }

      // Security: block access to hidden paths
      final pathParts = relativePath.split('/');
      for (final part in pathParts) {
        if (_hiddenNames.contains(part.toLowerCase())) {
          return shelf.Response.forbidden(
            jsonEncode({'error': 'Access denied: protected path'}),
            headers: headers,
          );
        }
      }

      // Check if parent collection is public
      final collectionPath = _getCollectionPath(relativePath, collectionsBase);
      if (collectionPath != null && !await _isCollectionPublic(collectionPath)) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Access denied: collection is not public'}),
          headers: headers,
        );
      }

      // Check if file exists
      final file = io.File(requestedPath);
      if (!await file.exists()) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'File not found'}),
          headers: headers,
        );
      }

      // Check if it's a directory
      final stat = await file.stat();
      if (stat.type == io.FileSystemEntityType.directory) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Path is a directory, not a file'}),
          headers: headers,
        );
      }

      // Read and return file content
      final content = await file.readAsString();
      return shelf.Response.ok(
        content,
        headers: {...headers, 'Content-Type': 'text/plain; charset=utf-8'},
      );
    } catch (e) {
      LogService().log('LogApiService: Error reading file content: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle GET /api/debug - Returns available actions and status
  shelf.Response _handleDebugGetRequest(Map<String, String> headers) {
    final debugController = DebugController();
    final recentActions = debugController.actionHistory
        .reversed
        .take(10)
        .map((e) => {
              'action': e.action.name,
              'params': e.params,
              'timestamp': e.timestamp.toIso8601String(),
            })
        .toList();

    String callsign = '';
    try {
      final profile = ProfileService().getProfile();
      callsign = profile.callsign;
    } catch (e) {
      // Profile service not initialized
    }

    return shelf.Response.ok(
      jsonEncode({
        'service': 'Geogram Debug API',
        'version': appVersion,
        'callsign': callsign,
        'available_actions': DebugController.getAvailableActions(),
        'recent_actions': recentActions,
        'panels': {
          'collections': 0,
          'maps': 1,
          'devices': 2,
          'settings': 3,
          'logs': 4,
        },
        'usage': {
          'navigate': 'POST /api/debug with {"action": "navigate", "panel": "devices"}',
          'ble_scan': 'POST /api/debug with {"action": "ble_scan"}',
          'refresh': 'POST /api/debug with {"action": "refresh_devices"}',
        },
      }),
      headers: headers,
    );
  }

  /// Handle POST /api/debug - Execute a debug action
  Future<shelf.Response> _handleDebugPostRequest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      if (body.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'error': 'Missing request body',
            'usage': 'POST with JSON body: {"action": "navigate", "panel": "devices"}',
          }),
          headers: headers,
        );
      }

      final data = jsonDecode(body) as Map<String, dynamic>;
      final action = data['action'] as String?;

      if (action == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'error': 'Missing action field',
            'available_actions':
                DebugController.getAvailableActions().map((a) => a['action']).toList(),
          }),
          headers: headers,
        );
      }

      // Remove action from params and pass the rest
      final params = Map<String, dynamic>.from(data)..remove('action');

      // Handle voice actions separately (they are async)
      if (action.toLowerCase().startsWith('voice_')) {
        return await _handleVoiceAction(action.toLowerCase(), params, headers);
      }

      // Handle chat room creation (async operation)
      if (action.toLowerCase() == 'create_restricted_room') {
        return await _handleCreateRestrictedRoom(params, headers);
      }

      // Handle backup actions separately (they are async)
      if (action.toLowerCase().startsWith('backup_')) {
        return await _handleBackupAction(action.toLowerCase(), params, headers);
      }

      // Handle event actions separately (they are async)
      if (action.toLowerCase().startsWith('event_')) {
        return await _handleEventAction(action.toLowerCase(), params, headers);
      }

      // Handle alert actions separately (they are async)
      if (action.toLowerCase().startsWith('alert_')) {
        return await _handleAlertAction(action.toLowerCase(), params, headers);
      }

      // Handle blog actions separately (they are async)
      if (action.toLowerCase().startsWith('blog_')) {
        return await _handleBlogAction(action.toLowerCase(), params, headers);
      }

      // Handle place actions separately (they are async)
      if (action.toLowerCase().startsWith('place_')) {
        return await _handlePlaceAction(action.toLowerCase(), params, headers);
      }

      // Handle station actions separately (they are async)
      if (action.toLowerCase().startsWith('station_')) {
        return await _handleStationAction(action.toLowerCase(), params, headers);
      }

      // Handle bot actions separately (they are async)
      if (action.toLowerCase().startsWith('bot_')) {
        return await _handleBotAction(action.toLowerCase(), params, headers);
      }

      // Handle device actions separately (they are async)
      if (action.toLowerCase().startsWith('device_')) {
        return await _handleDeviceAction(action.toLowerCase(), params, headers);
      }

      final debugController = DebugController();
      final result = debugController.executeAction(action, params);

      LogService().log('LogApiService: Debug action executed: $action -> $result');

      final statusCode = result['success'] == true ? 200 : 400;
      return shelf.Response(
        statusCode,
        body: jsonEncode(result),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling debug request: $e');
      return shelf.Response.badRequest(
        body: jsonEncode({
          'error': 'Invalid JSON body',
          'details': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Bot Model Debug Actions
  // ============================================================

  Future<shelf.Response> _handleBotAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    if (action != 'bot_download_model' &&
        action != 'bot_download_vision' &&
        action != 'bot_download_music') {
      return shelf.Response.badRequest(
        body: jsonEncode({
          'error': 'Unknown bot action: $action',
          'available_actions': ['bot_download_model', 'bot_download_vision', 'bot_download_music'],
        }),
        headers: headers,
      );
    }

    final modelId = (params['model_id'] ?? params['id']) as String?;
    if (modelId == null || modelId.isEmpty) {
      return shelf.Response.badRequest(
        body: jsonEncode({'error': 'Missing model_id parameter'}),
        headers: headers,
      );
    }

    String? modelType = params['model_type'] as String?;
    if (action == 'bot_download_vision') {
      modelType = 'vision';
    } else if (action == 'bot_download_music') {
      modelType = 'music';
    }

    if (modelType == null || modelType.isEmpty) {
      return shelf.Response.badRequest(
        body: jsonEncode({'error': 'Missing model_type parameter (vision|music)'}),
        headers: headers,
      );
    }

    final normalizedType = modelType.toLowerCase();
    final stationUrl = params['station_url'] as String?;
    final stationCallsign = params['station_callsign'] as String?;
    final key = '$normalizedType:$modelId';

    if (_botDownloadSubscriptions.containsKey(key)) {
      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'message': 'Download already in progress',
          'model_type': normalizedType,
          'model_id': modelId,
        }),
        headers: headers,
      );
    }

    if (normalizedType == 'vision') {
      final model = VisionModels.getById(modelId);
      if (model == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Unknown vision model: $modelId'}),
          headers: headers,
        );
      }

      final manager = VisionModelManager();
      final stream = manager.downloadModel(
        modelId,
        stationUrl: stationUrl,
        stationCallsign: stationCallsign,
      );

      _botDownloadSubscriptions[key] =
          _trackBotDownload(stream, key, normalizedType, modelId);

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'message': 'Vision model download started',
          'model_type': normalizedType,
          'model_id': modelId,
          'transfer_id': manager.getTransferId(modelId),
        }),
        headers: headers,
      );
    }

    if (normalizedType == 'music') {
      final model = MusicModels.getById(modelId);
      if (model == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Unknown music model: $modelId'}),
          headers: headers,
        );
      }

      if (model.isNative) {
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'message': 'Model is native and does not require download',
            'model_type': normalizedType,
            'model_id': modelId,
          }),
          headers: headers,
        );
      }

      final manager = MusicModelManager();
      final stream = manager.downloadModel(
        modelId,
        stationUrl: stationUrl,
        stationCallsign: stationCallsign,
      );

      _botDownloadSubscriptions[key] =
          _trackBotDownload(stream, key, normalizedType, modelId);

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'message': 'Music model download started',
          'model_type': normalizedType,
          'model_id': modelId,
          'transfer_ids': manager.getTransferIds(modelId) ?? [],
        }),
        headers: headers,
      );
    }

    return shelf.Response.badRequest(
      body: jsonEncode({'error': 'Invalid model_type: $normalizedType'}),
      headers: headers,
    );
  }

  StreamSubscription<double> _trackBotDownload(
    Stream<double> stream,
    String key,
    String modelType,
    String modelId,
  ) {
    var lastLoggedPercent = -1;
    return stream.listen(
      (progress) {
        final percent = (progress * 100).floor();
        if (percent - lastLoggedPercent >= 5 || percent == 100) {
          lastLoggedPercent = percent;
          LogService()
              .log('DebugBotDownload: $modelType/$modelId ${percent.toString()}%');
        }
      },
      onError: (error) {
        _botDownloadSubscriptions.remove(key);
        LogService()
            .log('DebugBotDownload: $modelType/$modelId failed: $error');
      },
      onDone: () {
        _botDownloadSubscriptions.remove(key);
        LogService()
            .log('DebugBotDownload: $modelType/$modelId completed');
      },
      cancelOnError: true,
    );
  }

  // ============================================================
  // Voice/Audio Debug Actions
  // ============================================================

  /// Handle voice actions asynchronously
  Future<shelf.Response> _handleVoiceAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    final audioService = AudioService();

    try {
      switch (action) {
        case 'voice_record':
          // Start recording for specified duration (default 5s)
          final durationSec = params['duration'] as int? ?? 5;

          // Initialize if needed
          await audioService.initialize();

          // Check permission
          if (!await audioService.hasPermission()) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'Microphone permission not granted',
              }),
              headers: headers,
            );
          }

          // Start recording
          final startPath = await audioService.startRecording();
          if (startPath == null) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': audioService.lastError ?? 'Failed to start recording',
                'isRecording': audioService.isRecording,
              }),
              headers: headers,
            );
          }

          // Wait for the specified duration
          LogService().log('LogApiService: Recording for $durationSec seconds...');
          await Future.delayed(Duration(seconds: durationSec));

          // Stop recording and get path
          final filePath = await audioService.stopRecording();

          if (filePath == null) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'Recording failed - no file produced',
              }),
              headers: headers,
            );
          }

          // Verify file exists and get size
          final file = io.File(filePath);
          final exists = await file.exists();
          final size = exists ? await file.length() : 0;

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Recording completed',
              'file_path': filePath,
              'file_exists': exists,
              'file_size': size,
              'duration_recorded': durationSec,
            }),
            headers: headers,
          );

        case 'voice_stop':
          if (!audioService.isRecording) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'Not currently recording',
              }),
              headers: headers,
            );
          }

          final filePath = await audioService.stopRecording();
          if (filePath == null) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'Failed to stop recording',
              }),
              headers: headers,
            );
          }

          final file = io.File(filePath);
          final exists = await file.exists();
          final size = exists ? await file.length() : 0;

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Recording stopped',
              'file_path': filePath,
              'file_exists': exists,
              'file_size': size,
            }),
            headers: headers,
          );

        case 'voice_status':
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'is_recording': audioService.isRecording,
              'is_playing': audioService.isPlaying,
              'recording_duration': audioService.recordingDuration.inMilliseconds,
              'playback_position': audioService.position.inMilliseconds,
              'playback_duration': audioService.duration?.inMilliseconds,
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown voice action: $action',
              'available': ['voice_record', 'voice_stop', 'voice_status'],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Voice action error: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Debug API - Backup Actions
  // ============================================================

  /// Handle backup debug actions asynchronously
  Future<shelf.Response> _handleBackupAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();

    try {
      // Ensure backup service is initialized
      await backupService.initialize();

      switch (action) {
        case 'backup_provider_enable':
          // Enable/configure backup provider mode
          final enabled = params['enabled'] != false;
          final maxStorageGb = (params['max_storage_gb'] as num?)?.toDouble() ?? 10.0;
          final maxClientStorageGb = (params['max_client_storage_gb'] as num?)?.toDouble() ?? 1.0;
          final maxSnapshots = (params['max_snapshots'] as num?)?.toInt() ?? 10;

          final settings = BackupProviderSettings(
            enabled: enabled,
            maxTotalStorageBytes: (maxStorageGb * 1024 * 1024 * 1024).toInt(),
            defaultMaxClientStorageBytes: (maxClientStorageGb * 1024 * 1024 * 1024).toInt(),
            defaultMaxSnapshots: maxSnapshots,
          );

          await backupService.saveProviderSettings(settings);

          LogService().log('LogApiService: Backup provider ${enabled ? "enabled" : "disabled"}');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Backup provider ${enabled ? "enabled" : "disabled"}',
              'settings': settings.toJson(),
            }),
            headers: headers,
          );

        case 'backup_create_test_data':
          // Create random test files for backup testing
          final fileCount = (params['file_count'] as num?)?.toInt() ?? 5;
          final fileSizeKb = (params['file_size_kb'] as num?)?.toInt() ?? 10;

          final testFiles = await _createBackupTestData(fileCount, fileSizeKb);

          LogService().log('LogApiService: Created $fileCount test files for backup');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Created $fileCount test files',
              'files': testFiles,
            }),
            headers: headers,
          );

        case 'backup_send_invite':
          // Send backup invite to a provider
          final providerCallsign = params['provider_callsign'] as String?;
          final intervalDays = (params['interval_days'] as num?)?.toInt() ?? 7;

          if (providerCallsign == null || providerCallsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing provider_callsign parameter',
              }),
              headers: headers,
            );
          }

          final result = await backupService.sendInvite(providerCallsign, intervalDays);

          if (result != null) {
            LogService().log('LogApiService: Sent backup invite to $providerCallsign');
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'message': 'Invite sent to $providerCallsign',
                'provider': result.toJson(),
              }),
              headers: headers,
            );
          } else {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'Failed to send invite or timed out',
              }),
              headers: headers,
            );
          }

        case 'backup_accept_invite':
          // Accept a pending backup invite (provider side)
          final clientCallsign = params['client_callsign'] as String?;
          var clientNpub = params['client_npub'] as String?;
          final maxStorageMb = (params['max_storage_mb'] as num?)?.toInt() ?? 100;
          final maxSnapshots = (params['max_snapshots'] as num?)?.toInt() ?? 5;

          if (clientCallsign == null || clientCallsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing client_callsign parameter',
              }),
              headers: headers,
            );
          }

          // Try to look up npub from devices if not provided
          if (clientNpub == null || clientNpub.isEmpty) {
            final devicesService = DevicesService();
            final devices = devicesService.getAllDevices();
            final device = devices.where((d) =>
              d.callsign.toUpperCase() == clientCallsign.toUpperCase()).firstOrNull;
            if (device != null && device.npub != null && device.npub!.isNotEmpty) {
              clientNpub = device.npub;
              LogService().log('LogApiService: Found npub for $clientCallsign: $clientNpub');
            }
          }

          if (clientNpub == null || clientNpub.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing client_npub parameter and could not find device npub for callsign',
              }),
              headers: headers,
            );
          }

          await backupService.acceptInvite(
            clientNpub,
            clientCallsign,
            maxStorageMb * 1024 * 1024,
            maxSnapshots,
          );

          LogService().log('LogApiService: Accepted backup invite from $clientCallsign');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Accepted invite from $clientCallsign',
              'client_npub': clientNpub,
            }),
            headers: headers,
          );

        case 'backup_start':
          // Start a backup to a provider
          final providerCallsign = params['provider_callsign'] as String?;

          if (providerCallsign == null || providerCallsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing provider_callsign parameter',
              }),
              headers: headers,
            );
          }

          final status = await backupService.startBackup(providerCallsign);

          LogService().log('LogApiService: Started backup to $providerCallsign');

          return shelf.Response.ok(
            jsonEncode({
              'success': status.status != 'failed',
              'message': status.status == 'failed' ? status.error : 'Backup started',
              'status': status.toJson(),
            }),
            headers: headers,
          );

        case 'backup_status':
        case 'backup_get_status':
          // Get current backup/restore status
          final backupStatus = backupService.backupStatus;
          final restoreStatus = backupService.restoreStatus;
          final providers = backupService.getProviders();
          final clients = backupService.getClients();

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'backup_status': backupStatus.toJson(),
              'restore_status': restoreStatus.toJson(),
              'providers': providers.map((p) => p.toJson()).toList(),
              'clients': clients.map((c) => c.toJson()).toList(),
            }),
            headers: headers,
          );

        case 'backup_restore':
          // Start restore from a provider
          final providerCallsign = params['provider_callsign'] as String?;
          final snapshotId = params['snapshot_id'] as String?;

          if (providerCallsign == null || providerCallsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing provider_callsign parameter',
              }),
              headers: headers,
            );
          }

          if (snapshotId == null || snapshotId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing snapshot_id parameter',
              }),
              headers: headers,
            );
          }

          await backupService.startRestore(providerCallsign, snapshotId);

          LogService().log('LogApiService: Started restore from $providerCallsign snapshot $snapshotId');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Restore started',
              'status': backupService.restoreStatus.toJson(),
            }),
            headers: headers,
          );

        case 'backup_list_snapshots':
          // List snapshots from a provider (provider-side) or for a client
          final clientCallsign = params['client_callsign'] as String?;

          if (clientCallsign == null || clientCallsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing client_callsign parameter',
              }),
              headers: headers,
            );
          }

          final snapshots = await backupService.getSnapshots(clientCallsign);

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'client_callsign': clientCallsign,
              'snapshots': snapshots.map((s) => s.toJson()).toList(),
            }),
            headers: headers,
          );

        case 'backup_add_provider':
          // Directly add a provider relationship (for LAN testing without WebSocket)
          final providerCallsign = params['provider_callsign'] as String?;
          var providerNpub = params['provider_npub'] as String?;
          final intervalDays = (params['interval_days'] as num?)?.toInt() ?? 3;
          final maxStorageMb = (params['max_storage_mb'] as num?)?.toInt() ?? 100;
          final maxSnapshots = (params['max_snapshots'] as num?)?.toInt() ?? 5;

          if (providerCallsign == null || providerCallsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing provider_callsign parameter',
              }),
              headers: headers,
            );
          }

          // Try to look up npub from devices if not provided
          if (providerNpub == null || providerNpub.isEmpty) {
            final devicesService = DevicesService();
            final devices = devicesService.getAllDevices();
            final device = devices.where((d) =>
              d.callsign.toUpperCase() == providerCallsign.toUpperCase()).firstOrNull;
            if (device != null && device.npub != null && device.npub!.isNotEmpty) {
              providerNpub = device.npub;
              LogService().log('LogApiService: Found npub for $providerCallsign: $providerNpub');
            }
          }

          if (providerNpub == null || providerNpub.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing provider_npub parameter and could not find device npub for callsign',
              }),
              headers: headers,
            );
          }

          // Create active provider relationship directly
          final relationship = BackupProviderRelationship(
            providerNpub: providerNpub,
            providerCallsign: providerCallsign.toUpperCase(),
            backupIntervalDays: intervalDays,
            status: BackupRelationshipStatus.active,
            maxStorageBytes: maxStorageMb * 1024 * 1024,
            maxSnapshots: maxSnapshots,
          );

          await backupService.updateProvider(relationship);

          LogService().log('LogApiService: Added provider $providerCallsign directly (for testing)');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Provider added directly',
              'provider': relationship.toJson(),
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown backup action: $action',
              'available': [
                'backup_provider_enable',
                'backup_create_test_data',
                'backup_send_invite',
                'backup_accept_invite',
                'backup_add_provider',
                'backup_start',
                'backup_status',
                'backup_restore',
                'backup_list_snapshots',
              ],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Backup action error: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  /// Create test data files for backup testing
  Future<List<Map<String, dynamic>>> _createBackupTestData(int fileCount, int fileSizeKb) async {
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      await storageConfig.init();
    }

    final testDir = io.Directory(path.join(storageConfig.baseDir, 'test-backup-data'));
    if (!await testDir.exists()) {
      await testDir.create(recursive: true);
    }

    final random = Random();
    final files = <Map<String, dynamic>>[];

    for (var i = 0; i < fileCount; i++) {
      final fileName = 'test_file_${i + 1}.bin';
      final filePath = path.join(testDir.path, fileName);
      final file = io.File(filePath);

      // Generate random bytes
      final bytes = Uint8List(fileSizeKb * 1024);
      for (var j = 0; j < bytes.length; j++) {
        bytes[j] = random.nextInt(256);
      }

      await file.writeAsBytes(bytes);

      // Calculate SHA1 for verification
      final sha1Hash = sha1.convert(bytes).toString();

      files.add({
        'name': fileName,
        'path': filePath,
        'size': bytes.length,
        'sha1': sha1Hash,
      });
    }

    return files;
  }

  // ============================================================
  // Debug API - Chat Room Creation
  // ============================================================

  /// Handle create_restricted_room debug action
  /// Creates a restricted chat room with the device owner as the room owner
  Future<shelf.Response> _handleCreateRestrictedRoom(
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      // Ensure ChatService is initialized (create chat directory if missing for debug API)
      final initialized = await _initializeChatServiceIfNeeded(createIfMissing: true);
      if (!initialized) {
        return shelf.Response.internalServerError(
          body: jsonEncode({
            'success': false,
            'error': 'Chat service not available',
          }),
          headers: headers,
        );
      }

      final roomId = params['room_id'] as String?;
      final name = params['name'] as String?;
      final ownerNpub = params['owner_npub'] as String?;
      final description = params['description'] as String?;

      if (roomId == null || roomId.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing room_id parameter',
          }),
          headers: headers,
        );
      }

      if (name == null || name.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing name parameter',
          }),
          headers: headers,
        );
      }

      if (ownerNpub == null || ownerNpub.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing owner_npub parameter',
          }),
          headers: headers,
        );
      }

      // Use ChatService to create the restricted room
      final chatService = ChatService();
      final room = await chatService.createRestrictedRoom(
        id: roomId,
        name: name,
        ownerNpub: ownerNpub,
        description: description,
      );

      LogService().log('LogApiService: Created restricted room: ${room.id} with owner $ownerNpub');

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'message': 'Restricted room created',
          'room': room.toJson(),
        }),
        headers: headers,
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Error creating restricted room: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Chat API endpoints
  // ============================================================

  /// Extract room ID from paths like 'api/chat/{roomId}/messages'
  String? _extractRoomIdFromPath(String urlPath) {
    // Pattern: api/chat/{roomId}/messages or api/chat/rooms/{roomId}/messages
    final regex = RegExp(r'^api/chat/(?:rooms/)?([^/]+)/(messages|files)$');
    final match = regex.firstMatch(urlPath);
    if (match != null) {
      return Uri.decodeComponent(match.group(1)!);
    }
    return null;
  }

  /// Verify NOSTR authorization header and return npub if valid
  /// Header format: Authorization: Nostr <base64_encoded_signed_event>
  String? _verifyNostrAuth(shelf.Request request) {
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Nostr ')) {
      return null;
    }

    try {
      final base64Event = authHeader.substring(6); // Remove 'Nostr ' prefix
      final eventJson = utf8.decode(base64Decode(base64Event));
      final eventData = jsonDecode(eventJson) as Map<String, dynamic>;
      final event = NostrEvent.fromJson(eventData);

      // Verify the signature
      if (!event.verify()) {
        LogService().log('LogApiService: NOSTR auth failed - invalid signature');
        return null;
      }

      // Check event is recent (within 5 minutes) to prevent replay attacks
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if ((now - event.createdAt).abs() > 300) {
        LogService().log('LogApiService: NOSTR auth failed - event too old');
        return null;
      }

      return event.npub;
    } catch (e) {
      LogService().log('LogApiService: NOSTR auth failed - parse error: $e');
      return null;
    }
  }

  /// Check if npub can access a chat room
  /// For DM channels (type: direct), also accepts a callsign parameter to allow access
  /// based on callsign matching the room participants
  Future<bool> _canAccessChatRoom(String roomId, String? npub, {String? callsign}) async {
    final chatService = ChatService();
    final channel = chatService.getChannel(roomId);
    if (channel == null) {
      return false;
    }

    // Get visibility from config (default to PUBLIC)
    final config = channel.config;
    final visibility = config?.visibility ?? 'PUBLIC';

    // PUBLIC rooms are accessible to everyone
    if (visibility == 'PUBLIC') {
      return true;
    }

    // Non-public rooms require authentication (npub or callsign for DMs)
    if (npub == null && callsign == null) {
      return false;
    }

    // Device admin can access everything
    final security = chatService.security;
    if (npub != null && security.isAdmin(npub)) {
      return true;
    }

    // RESTRICTED rooms - check role-based membership
    if (visibility == 'RESTRICTED' && config != null) {
      // Check if user is banned
      if (config.isBanned(npub)) {
        return false;
      }
      // Check if user has member access (includes moderators, admins, owner)
      if (config.canAccess(npub)) {
        return true;
      }
    }

    // Check if room is open to all ('*' in participants)
    if (channel.participants.contains('*')) {
      return true;
    }

    // For DM channels (type: direct), allow access if callsign is in participants
    // This allows the sender (roomId = their callsign) to post to the DM channel
    if (channel.isDirect && callsign != null) {
      if (channel.participants.any((p) => p.toUpperCase() == callsign.toUpperCase())) {
        return true;
      }
      // Also allow if the callsign matches the roomId (sender is writing to recipient's DM room)
      if (roomId.toUpperCase() == callsign.toUpperCase()) {
        return true;
      }
    }

    // Check if user's callsign is in participants via npub mapping
    // We need to map npub -> callsign through participants list
    if (npub != null) {
      final participants = chatService.participants;
      for (final entry in participants.entries) {
        if (entry.value == npub && channel.participants.contains(entry.key)) {
          return true;
        }
      }
    }

    return false;
  }

  /// Handle GET /api/chat/rooms - List available chat rooms
  Future<shelf.Response> _handleChatRoomsRequest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      // Check for X-Device-Callsign header (used by proxy)
      // If present, serve that device's chat rooms instead of current user's
      final deviceCallsign = request.headers['x-device-callsign'];
      if (deviceCallsign != null && deviceCallsign.isNotEmpty) {
        LogService().log('Chat API: Serving chat rooms for device $deviceCallsign (from proxy header)');
        return await _handleRemoteDeviceChatRooms(deviceCallsign, headers);
      }

      // Try to lazily initialize ChatService if not already done
      // Create chat collection if it doesn't exist
      final initialized = await _initializeChatServiceIfNeeded(createIfMissing: true);

      final chatService = ChatService();

      // Check if chat service is initialized
      if (!initialized || chatService.collectionPath == null) {
        LogService().log('LogApiService: Failed to initialize chat service');
        return shelf.Response.ok(
          jsonEncode({
            'rooms': [],
            'total': 0,
            'authenticated': false,
            'message': 'Chat service not available',
          }),
          headers: headers,
        );
      }

      // Ensure default "main" channel exists
      if (chatService.channels.isEmpty) {
        try {
          LogService().log('LogApiService: Creating default main channel');
          final mainChannel = ChatChannel.main(
            name: 'Main',
            description: 'Public group chat',
          );
          await chatService.createChannel(mainChannel);
          LogService().log('LogApiService: Default main channel created');
        } catch (e) {
          LogService().log('LogApiService: Error creating main channel: $e');
        }
      }

      // Get authenticated npub (if any)
      String? authNpub = _verifyNostrAuth(request);

      // Also check query parameter for npub (useful for testing, but less secure)
      final queryNpub = request.url.queryParameters['npub'];
      if (authNpub == null && queryNpub != null && queryNpub.startsWith('npub1')) {
        // Note: query parameter alone doesn't prove identity - only for public room listing
        authNpub = null; // Don't trust unverified npub for access control
      }

      final rooms = <Map<String, dynamic>>[];

      for (final channel in chatService.channels) {
        final visibility = channel.config?.visibility ?? 'PUBLIC';

        // RESTRICTED rooms are completely hidden from non-members
        if (visibility == 'RESTRICTED') {
          final config = channel.config;
          if (config == null) continue;
          // Only show if user is a member (includes moderators, admins, owner)
          if (authNpub == null || !config.canAccess(authNpub)) {
            continue;
          }
        }

        // For non-RESTRICTED rooms, check standard access
        final canAccess = await _canAccessChatRoom(channel.id, authNpub);
        if (!canAccess && visibility != 'PUBLIC') {
          continue;
        }

        // Build room info
        final roomInfo = <String, dynamic>{
          'id': channel.id,
          'name': channel.name,
          'description': channel.description,
          'type': channel.isMain ? 'main' : (channel.isDirect ? 'direct' : 'group'),
          'visibility': visibility,
          'participants': channel.participants,
          'lastMessage': channel.lastMessageTime?.toIso8601String(),
          'folder': channel.folder,
        };

        // For RESTRICTED rooms, include role info for members
        if (visibility == 'RESTRICTED' && channel.config != null) {
          final config = channel.config!;
          roomInfo['role'] = config.isOwner(authNpub) ? 'owner'
              : config.isAdmin(authNpub) ? 'admin'
              : config.isModerator(authNpub) ? 'moderator'
              : 'member';
          roomInfo['memberCount'] = config.members.length +
              config.moderatorNpubs.length +
              config.admins.length + 1; // +1 for owner
        }

        rooms.add(roomInfo);
      }

      return shelf.Response.ok(
        jsonEncode({
          'rooms': rooms,
          'total': rooms.length,
          'authenticated': authNpub != null,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling chat rooms request: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle chat rooms request for a remote device (via X-Device-Callsign header)
  Future<shelf.Response> _handleRemoteDeviceChatRooms(
    String deviceCallsign,
    Map<String, String> headers,
  ) async {
    try {
      late final String dataDir;
      try {
        dataDir = StorageConfig().baseDir;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Storage not initialized'}),
          headers: headers,
        );
      }

      // Path to remote device's chat directory
      final chatPath = '$dataDir/devices/$deviceCallsign/chat';
      final chatDir = io.Directory(chatPath);

      if (!await chatDir.exists()) {
        return shelf.Response.ok(
          jsonEncode({
            'rooms': [],
            'total': 0,
            'message': 'No chat collection for device $deviceCallsign',
          }),
          headers: headers,
        );
      }

      // Read chat rooms from disk
      final rooms = <Map<String, dynamic>>[];

      await for (final entity in chatDir.list()) {
        if (entity is io.Directory) {
          final roomName = entity.uri.pathSegments[entity.uri.pathSegments.length - 2];

          // Read room config if it exists
          final configFile = io.File('${entity.path}/config.json');
          if (await configFile.exists()) {
            try {
              final configContent = await configFile.readAsString();
              final config = json.decode(configContent) as Map<String, dynamic>;

              // Only include public rooms for remote browsing
              final visibility = config['visibility'] as String? ?? 'PUBLIC';
              if (visibility == 'PUBLIC') {
                rooms.add({
                  'id': roomName,
                  'name': config['name'] as String? ?? roomName,
                  'description': config['description'] as String?,
                  'visibility': visibility,
                  'memberCount': (config['members'] as List?)?.length ?? 0,
                });
              }
            } catch (e) {
              LogService().log('Error reading room config for $roomName: $e');
            }
          } else {
            // No config file - treat as public room
            rooms.add({
              'id': roomName,
              'name': roomName,
              'visibility': 'PUBLIC',
            });
          }
        }
      }

      return shelf.Response.ok(
        jsonEncode({
          'rooms': rooms,
          'total': rooms.length,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling remote device chat rooms: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle chat messages request for a remote device (via X-Device-Callsign header)
  Future<shelf.Response> _handleRemoteDeviceChatMessages(
    String deviceCallsign,
    String roomId,
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      late final String dataDir;
      try {
        dataDir = StorageConfig().baseDir;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Storage not initialized'}),
          headers: headers,
        );
      }

      // Path to remote device's chat room directory
      final roomPath = '$dataDir/devices/$deviceCallsign/chat/$roomId';
      final roomDir = io.Directory(roomPath);

      if (!await roomDir.exists()) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Room not found', 'roomId': roomId}),
          headers: headers,
        );
      }

      // Parse query parameters
      final queryParams = request.url.queryParameters;
      final limitParam = queryParams['limit'];
      int limit = 100;
      if (limitParam != null) {
        limit = int.tryParse(limitParam) ?? 100;
        limit = limit.clamp(1, 500);
      }

      // Read messages from disk
      final messages = <Map<String, dynamic>>[];
      final messageFiles = <io.File>[];

      await for (final entity in roomDir.list()) {
        if (entity is io.File && entity.path.endsWith('.json') && !entity.path.endsWith('config.json')) {
          messageFiles.add(entity);
        }
      }

      // Sort by filename (which should be timestamp-based)
      messageFiles.sort((a, b) => b.path.compareTo(a.path)); // Newest first

      // Read message files
      for (final file in messageFiles.take(limit)) {
        try {
          final content = await file.readAsString();
          final msgData = json.decode(content) as Map<String, dynamic>;
          messages.add(msgData);
        } catch (e) {
          LogService().log('Error reading message file ${file.path}: $e');
        }
      }

      return shelf.Response.ok(
        jsonEncode(messages),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling remote device chat messages: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle GET /api/chat/rooms/{roomId}/messages - Get messages from a room
  Future<shelf.Response> _handleChatMessagesRequest(
    shelf.Request request,
    String roomId,
    Map<String, String> headers,
  ) async {
    try {
      // Check for X-Device-Callsign header (used by proxy)
      // If present, serve that device's chat messages instead of current user's
      final deviceCallsign = request.headers['x-device-callsign'];
      if (deviceCallsign != null && deviceCallsign.isNotEmpty) {
        LogService().log('Chat Messages API: Serving messages for device $deviceCallsign (from proxy header)');
        return await _handleRemoteDeviceChatMessages(deviceCallsign, roomId, request, headers);
      }

      await _initializeChatServiceIfNeeded();

      final chatService = ChatService();
      final channel = chatService.getChannel(roomId);
      final isCallsignLike = RegExp(r'^[A-Z0-9]{3,}$').hasMatch(roomId.toUpperCase());

      if (channel == null && isCallsignLike) {
        final dmService = DirectMessageService();
        await dmService.initialize();

        // Parse query parameters
        final queryParams = request.url.queryParameters;
        final limitParam = queryParams['limit'];
        int limit = 50;
        if (limitParam != null) {
          limit = int.tryParse(limitParam) ?? 50;
          limit = limit.clamp(1, 500);
        }

        final messages = await dmService.loadMessages(roomId.toUpperCase(), limit: limit);

        final messageList = messages.map((msg) {
          return {
            'author': msg.author,
            'timestamp': msg.timestamp,
            'content': msg.content,
            'npub': msg.npub,
            'signature': msg.signature,
            'verified': msg.isVerified,
            'reactions': msg.reactions,
          };
        }).toList();

        return shelf.Response.ok(
          jsonEncode({
            'roomId': roomId.toUpperCase(),
            'messages': messageList,
            'count': messageList.length,
            'hasMore': false,
            'limit': limit,
          }),
          headers: headers,
        );
      }

      // Check if chat service is initialized
      if (chatService.collectionPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'No chat collection loaded'}),
          headers: headers,
        );
      }

      // Verify access
      final authNpub = _verifyNostrAuth(request);
      final canAccess = await _canAccessChatRoom(roomId, authNpub);
      if (!canAccess) {
        return shelf.Response.forbidden(
          jsonEncode({
            'error': 'Access denied',
            'code': 'ROOM_ACCESS_DENIED',
            'hint': authNpub == null
                ? 'Authentication required for this room. Use Authorization: Nostr <signed_event> header.'
                : 'Your npub is not authorized for this room.',
          }),
          headers: headers,
        );
      }

      // Parse query parameters
      final queryParams = request.url.queryParameters;
      final limitParam = queryParams['limit'];
      final beforeParam = queryParams['before'];
      final afterParam = queryParams['after'];

      int limit = 50;
      if (limitParam != null) {
        limit = int.tryParse(limitParam) ?? 50;
        limit = limit.clamp(1, 500);
      }

      DateTime? startDate;
      DateTime? endDate;
      if (afterParam != null) {
        startDate = DateTime.tryParse(afterParam);
      }
      if (beforeParam != null) {
        endDate = DateTime.tryParse(beforeParam);
      }

      // Load messages
      final messages = await chatService.loadMessages(
        roomId,
        startDate: startDate,
        endDate: endDate,
        limit: limit + 1, // Fetch one extra to determine if there are more
      );

      final hasMore = messages.length > limit;
      final returnMessages = hasMore ? messages.sublist(0, limit) : messages;

      // Convert to JSON-friendly format
      final messageList = returnMessages.map((msg) {
        return {
          'author': msg.author,
          'timestamp': msg.timestamp,
          'content': msg.content,
          'npub': msg.npub,
          'signature': msg.signature,
          'verified': msg.isVerified,
          'hasFile': msg.hasFile,
          'file': msg.attachedFile,
          'hasLocation': msg.hasLocation,
          'latitude': msg.latitude,
          'longitude': msg.longitude,
          'metadata': msg.metadata,
          'reactions': msg.reactions,
        };
      }).toList();

      return shelf.Response.ok(
        jsonEncode({
          'roomId': roomId,
          'messages': messageList,
          'count': messageList.length,
          'hasMore': hasMore,
          'limit': limit,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling chat messages request: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/chat/rooms/{roomId}/messages - Post a message
  Future<shelf.Response> _handleChatPostMessageRequest(
    shelf.Request request,
    String roomId,
    Map<String, String> headers,
  ) async {
    try {
      await _initializeChatServiceIfNeeded();

      final chatService = ChatService();
      final channel = chatService.getChannel(roomId);
      final isCallsignLike = RegExp(r'^[A-Z0-9]{3,}$').hasMatch(roomId.toUpperCase());

      if (channel == null && isCallsignLike) {
        return await _handleDMViaChatAPI(request, roomId.toUpperCase(), headers);
      }

      // Check if chat service is initialized
      if (chatService.collectionPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'No chat collection loaded'}),
          headers: headers,
        );
      }

      if (channel == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Room not found', 'roomId': roomId}),
          headers: headers,
        );
      }

      // Check if room is read-only
      if (channel.config?.readonly == true) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Room is read-only', 'code': 'ROOM_READ_ONLY'}),
          headers: headers,
        );
      }

      // Parse request body
      final bodyStr = await request.readAsString();
      if (bodyStr.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing request body'}),
          headers: headers,
        );
      }

      final body = jsonDecode(bodyStr) as Map<String, dynamic>;

      String author;
      String content;
      int? createdAt;
      String? npub;
      String? signature;
      String? eventId;
      final extraMetadata = <String, String>{};

      final rawMetadata = body['metadata'] ?? body['meta'];
      if (rawMetadata is Map) {
        rawMetadata.forEach((key, value) {
          if (value == null) return;
          extraMetadata[key.toString()] = value.toString();
        });
      }

      if (body.containsKey('event')) {
        // NOSTR-signed message from external user
        final eventData = body['event'] as Map<String, dynamic>;
        final event = NostrEvent.fromJson(eventData);

        // Verify the event signature
        if (!event.verify()) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Invalid event signature',
              'code': 'INVALID_SIGNATURE',
            }),
            headers: headers,
          );
        }

        // Validate event kind (must be kind 1 = text note)
        if (event.kind != NostrEventKind.textNote) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'error': 'Invalid event kind',
              'expected': NostrEventKind.textNote,
              'received': event.kind,
            }),
            headers: headers,
          );
        }

        // Validate room tag matches
        final roomTag = event.getTagValue('room');
        if (roomTag != null && roomTag != roomId) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'error': 'Room tag mismatch',
              'expected': roomId,
              'received': roomTag,
            }),
            headers: headers,
          );
        }

        // Use callsign from tag or derive from npub
        author = event.getTagValue('callsign') ?? event.callsign;

        // Check access for the event author
        final canAccess = await _canAccessChatRoom(roomId, event.npub, callsign: author);
        if (!canAccess) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Event author not authorized for this room',
              'code': 'AUTHOR_ACCESS_DENIED',
            }),
            headers: headers,
          );
        }
        content = event.content;
        createdAt = event.createdAt;
        npub = event.npub;
        signature = event.sig;
        eventId = event.id;

      } else if (body.containsKey('content')) {
        // Simple message from device owner (no auth required for device's own messages)
        content = body['content'] as String;

        // Use device's profile
        try {
          final profile = ProfileService().getProfile();
          author = profile.callsign;
          npub = profile.npub;
        } catch (e) {
          return shelf.Response.internalServerError(
            body: jsonEncode({'error': 'Profile not initialized'}),
            headers: headers,
          );
        }
      } else {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'error': 'Missing content or event field',
            'hint': 'Provide either "content" for device message or "event" for NOSTR-signed message',
          }),
          headers: headers,
        );
      }

      // Validate content length
      final maxLength = channel.config?.maxSizeText ?? 10000;
      if (content.length > maxLength) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'error': 'Content too long',
            'maxLength': maxLength,
            'received': content.length,
          }),
          headers: headers,
        );
      }

      // Create and save message
      // Order: created_at, npub, event_id, signature (signature last for readability)
      final metadata = <String, String>{};
      if (createdAt != null) metadata['created_at'] = createdAt.toString();
      if (npub != null) metadata['npub'] = npub;
      if (eventId != null) metadata['event_id'] = eventId;
      if (signature != null) metadata['signature'] = signature;
      if (extraMetadata.isNotEmpty) {
        const reserved = {
          'created_at',
          'npub',
          'event_id',
          'signature',
          'verified',
          'status',
        };
        extraMetadata.forEach((key, value) {
          if (reserved.contains(key)) return;
          metadata[key] = value;
        });
      }

      final message = ChatMessage.now(
        author: author,
        content: content,
        metadata: metadata,
      );

      await chatService.saveMessage(roomId, message);

      LogService().log('LogApiService: Chat message posted to $roomId by $author');

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'timestamp': message.timestamp,
          'author': author,
          'eventId': eventId,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error posting chat message: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle DM messages via /api/chat/{callsign}/messages
  /// This routes callsign-like roomIds through DirectMessageService
  /// which stores messages at chat/{callsign}/ instead of the main chat collection
  Future<shelf.Response> _handleDMViaChatAPI(
    shelf.Request request,
    String senderCallsign,
    Map<String, String> headers,
  ) async {
    try {
      LogService().log('LogApiService: Handling DM via Chat API for sender: $senderCallsign');

      // Parse request body
      final bodyStr = await request.readAsString();
      if (bodyStr.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing request body'}),
          headers: headers,
        );
      }

      final body = jsonDecode(bodyStr) as Map<String, dynamic>;

      String author;
      String content;
      int? createdAt;
      String? npub;
      String? signature;
      String? eventId;

      if (body.containsKey('event')) {
        // NOSTR-signed message from external user
        final eventData = body['event'] as Map<String, dynamic>;
        final event = NostrEvent.fromJson(eventData);

        // Verify the event signature
        if (!event.verify()) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Invalid event signature',
              'code': 'INVALID_SIGNATURE',
            }),
            headers: headers,
          );
        }

        // Validate event kind (must be kind 1 = text note)
        if (event.kind != NostrEventKind.textNote) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'error': 'Invalid event kind',
              'expected': NostrEventKind.textNote,
              'received': event.kind,
            }),
            headers: headers,
          );
        }

        // Use callsign from tag or derive from npub
        author = event.getTagValue('callsign') ?? event.callsign;

        // Verify the sender matches the roomId (the roomId IS the sender's callsign for DMs)
        if (author.toUpperCase() != senderCallsign) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Sender callsign mismatch',
              'expected': senderCallsign,
              'received': author,
              'code': 'SENDER_MISMATCH',
            }),
            headers: headers,
          );
        }

        content = event.content;
        createdAt = event.createdAt;
        npub = event.npub;
        signature = event.sig;
        eventId = event.id;

      } else if (body.containsKey('content')) {
        // Simple message - use device's profile
        content = body['content'] as String;
        try {
          final profile = ProfileService().getProfile();
          author = profile.callsign;
          npub = profile.npub;
        } catch (e) {
          return shelf.Response.internalServerError(
            body: jsonEncode({'error': 'Profile not initialized'}),
            headers: headers,
          );
        }
      } else {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'error': 'Missing content or event field',
            'hint': 'Provide either "content" for device message or "event" for NOSTR-signed message',
          }),
          headers: headers,
        );
      }

      // Create message with metadata
      // Start with any extra metadata from the request (e.g., quote info)
      final metadata = <String, String>{};
      if (body.containsKey('metadata') && body['metadata'] is Map) {
        final extraMeta = body['metadata'] as Map;
        extraMeta.forEach((key, value) {
          if (key is String && value is String) {
            metadata[key] = value;
          }
        });
      }
      // Add signature-related fields (order: created_at, npub, event_id, signature last)
      if (createdAt != null) metadata['created_at'] = createdAt.toString();
      if (npub != null) metadata['npub'] = npub;
      if (eventId != null) metadata['event_id'] = eventId;
      if (signature != null) {
        metadata['signature'] = signature;
        // Mark as verified since we verified the signature above
        metadata['verified'] = 'true';
      }

      final message = ChatMessage.now(
        author: author,
        content: content,
        metadata: metadata,
      );

      // Use DirectMessageService to save the incoming DM
      // The senderCallsign is the "other" party in the DM conversation
      final dmService = DirectMessageService();
      await dmService.initialize();
      await dmService.saveIncomingMessage(senderCallsign, message);

      LogService().log('LogApiService: DM saved from $author to chat/$senderCallsign/');

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'timestamp': message.timestamp,
          'author': author,
          'eventId': eventId,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling DM via Chat API: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle GET /api/chat/rooms/{roomId}/files - List files in a chat room
  Future<shelf.Response> _handleChatFilesRequest(
    shelf.Request request,
    String roomId,
    Map<String, String> headers,
  ) async {
    try {
      // Try to lazily initialize ChatService if not already done
      await _initializeChatServiceIfNeeded();

      final chatService = ChatService();

      // Check if chat service is initialized
      if (chatService.collectionPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'No chat collection loaded'}),
          headers: headers,
        );
      }

      // Verify access
      final authNpub = _verifyNostrAuth(request);
      final canAccess = await _canAccessChatRoom(roomId, authNpub);
      if (!canAccess) {
        return shelf.Response.forbidden(
          jsonEncode({
            'error': 'Access denied',
            'code': 'ROOM_ACCESS_DENIED',
          }),
          headers: headers,
        );
      }

      // Get channel
      final channel = chatService.getChannel(roomId);
      if (channel == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Room not found', 'roomId': roomId}),
          headers: headers,
        );
      }

      final collectionPath = chatService.collectionPath!;
      final channelPath = path.join(collectionPath, channel.folder);
      final files = <Map<String, dynamic>>[];

      // For main channel, files are in year/files/ subfolders
      if (channel.isMain) {
        final channelDir = io.Directory(channelPath);
        if (await channelDir.exists()) {
          await for (final yearEntity in channelDir.list()) {
            if (yearEntity is io.Directory) {
              final yearName = path.basename(yearEntity.path);
              // Check if it's a year folder (4 digits)
              if (RegExp(r'^\d{4}$').hasMatch(yearName)) {
                final filesDir = io.Directory(path.join(yearEntity.path, 'files'));
                if (await filesDir.exists()) {
                  await for (final file in filesDir.list()) {
                    if (file is io.File) {
                      final stat = await file.stat();
                      files.add({
                        'name': path.basename(file.path),
                        'size': stat.size,
                        'year': yearName,
                        'modified': stat.modified.toIso8601String(),
                      });
                    }
                  }
                }
              }
            }
          }
        }
      } else {
        // For other channels, files are in channel/files/
        final filesDir = io.Directory(path.join(channelPath, 'files'));
        if (await filesDir.exists()) {
          await for (final file in filesDir.list()) {
            if (file is io.File) {
              final stat = await file.stat();
              files.add({
                'name': path.basename(file.path),
                'size': stat.size,
                'modified': stat.modified.toIso8601String(),
              });
            }
          }
        }
      }

      // Sort by modification time (newest first)
      files.sort((a, b) {
        final aTime = DateTime.parse(a['modified'] as String);
        final bTime = DateTime.parse(b['modified'] as String);
        return bTime.compareTo(aTime);
      });

      return shelf.Response.ok(
        jsonEncode({
          'roomId': roomId,
          'files': files,
          'total': files.length,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error listing chat files: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Restricted Chat Room Member Management API endpoints
  // ============================================================

  /// Verify NOSTR event with action-specific tags for replay attack prevention
  /// Returns the event if valid, null otherwise
  NostrEvent? _verifyNostrEventWithTags(
    shelf.Request request,
    String expectedAction,
    String expectedRoomId,
  ) {
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Nostr ')) {
      return null;
    }

    try {
      final base64Event = authHeader.substring(6);
      final eventJson = utf8.decode(base64Decode(base64Event));
      final eventData = jsonDecode(eventJson) as Map<String, dynamic>;
      final event = NostrEvent.fromJson(eventData);

      // Verify signature
      if (!event.verify()) {
        LogService().log('LogApiService: NOSTR event verification failed - invalid signature');
        return null;
      }

      // Check event is recent (within 5 minutes)
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if ((now - event.createdAt).abs() > 300) {
        LogService().log('LogApiService: NOSTR event verification failed - expired');
        return null;
      }

      // Verify action tag
      final actionTag = event.getTagValue('action');
      if (actionTag != expectedAction) {
        LogService().log('LogApiService: NOSTR event verification failed - action mismatch: $actionTag != $expectedAction');
        return null;
      }

      // Verify room tag
      final roomTag = event.getTagValue('room');
      if (roomTag != expectedRoomId) {
        LogService().log('LogApiService: NOSTR event verification failed - room mismatch: $roomTag != $expectedRoomId');
        return null;
      }

      return event;
    } catch (e) {
      LogService().log('LogApiService: NOSTR event verification failed - parse error: $e');
      return null;
    }
  }

  /// Handle member management requests: add/remove members
  /// POST /api/chat/{roomId}/members - Add member (requires 'target' npub in event tags)
  /// DELETE /api/chat/{roomId}/members/{npub} - Remove member
  Future<shelf.Response> _handleChatMemberManagementRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      await _initializeChatServiceIfNeeded();
      final chatService = ChatService();

      // Extract roomId from path: api/chat/{roomId}/members or api/chat/{roomId}/members/{npub}
      final regex = RegExp(r'^api/chat/([^/]+)/members(?:/(.+))?$');
      final match = regex.firstMatch(urlPath);
      if (match == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Invalid path format'}),
          headers: headers,
        );
      }

      final roomId = Uri.decodeComponent(match.group(1)!);
      final targetNpubFromPath = match.group(2) != null ? Uri.decodeComponent(match.group(2)!) : null;

      if (request.method == 'POST') {
        // Add member - requires NOSTR event with 'add-member' action
        final event = _verifyNostrEventWithTags(request, 'add-member', roomId);
        if (event == null) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Invalid or missing NOSTR authentication',
              'code': 'AUTH_REQUIRED',
              'hint': 'Provide Authorization: Nostr <event> with action:add-member and room:$roomId tags',
            }),
            headers: headers,
          );
        }

        final targetNpub = event.getTagValue('target');
        if (targetNpub == null) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'error': 'Missing target tag in event',
              'hint': 'Include ["target", "npub1..."] tag for target member',
            }),
            headers: headers,
          );
        }

        await chatService.addMember(roomId, event.npub, targetNpub);

        LogService().log('LogApiService: Member $targetNpub added to $roomId by ${event.npub}');

        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'action': 'add-member',
            'roomId': roomId,
            'targetNpub': targetNpub,
          }),
          headers: headers,
        );
      } else if (request.method == 'DELETE') {
        // Remove member - requires NOSTR event with 'remove-member' action
        final event = _verifyNostrEventWithTags(request, 'remove-member', roomId);
        if (event == null) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Invalid or missing NOSTR authentication',
              'code': 'AUTH_REQUIRED',
            }),
            headers: headers,
          );
        }

        final targetNpub = event.getTagValue('target') ?? targetNpubFromPath;
        if (targetNpub == null) {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'Missing target npub'}),
            headers: headers,
          );
        }

        await chatService.removeMember(roomId, event.npub, targetNpub);

        LogService().log('LogApiService: Member $targetNpub removed from $roomId by ${event.npub}');

        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'action': 'remove-member',
            'roomId': roomId,
            'targetNpub': targetNpub,
          }),
          headers: headers,
        );
      }

      return shelf.Response(405, body: jsonEncode({'error': 'Method not allowed'}), headers: headers);
    } on PermissionDeniedException catch (e) {
      return shelf.Response.forbidden(
        jsonEncode({'error': e.message, 'code': 'PERMISSION_DENIED'}),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error in member management: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle message edit and delete requests
  /// DELETE /api/chat/{roomId}/messages/{timestamp} - Delete own message (or mod can delete any)
  /// PUT /api/chat/{roomId}/messages/{timestamp} - Edit own message (author only)
  Future<shelf.Response> _handleChatMessageModificationRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      await _initializeChatServiceIfNeeded();
      final chatService = ChatService();

      // Extract roomId and timestamp from path: api/chat/{roomId}/messages/{timestamp}
      // Timestamp format: YYYY-MM-DD HH:MM_ss (URL encoded: YYYY-MM-DD%20HH%3AMM_ss)
      final regex = RegExp(r'^api/chat/(?:rooms/)?([^/]+)/messages/(.+)$');
      final match = regex.firstMatch(urlPath);
      if (match == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Invalid path format'}),
          headers: headers,
        );
      }

      final roomId = Uri.decodeComponent(match.group(1)!);
      final timestamp = Uri.decodeComponent(match.group(2)!);

      if (request.method == 'DELETE') {
        // Delete message - requires NOSTR event with 'delete' action
        final event = _verifyNostrEventWithTags(request, 'delete', roomId);
        if (event == null) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Invalid or missing NOSTR authentication',
              'code': 'AUTH_REQUIRED',
            }),
            headers: headers,
          );
        }

        // Get timestamp from event tags (should match URL)
        final timestampTag = event.getTagValue('timestamp');
        if (timestampTag != null && timestampTag != timestamp) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Timestamp mismatch between URL and event',
              'code': 'TIMESTAMP_MISMATCH',
            }),
            headers: headers,
          );
        }

        // Find the message first to get the author
        final message = await chatService.findMessage(roomId, timestamp);
        if (message == null) {
          return shelf.Response.notFound(
            jsonEncode({'error': 'Message not found', 'code': 'NOT_FOUND'}),
            headers: headers,
          );
        }

        // Delete the message (ChatService handles authorization)
        await chatService.deleteMessageByTimestamp(
          channelId: roomId,
          timestamp: timestamp,
          authorCallsign: message.author,
          actorNpub: event.npub,
        );

        LogService().log('LogApiService: Message deleted from $roomId at $timestamp by ${event.npub}');

        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'action': 'delete',
            'roomId': roomId,
            'deleted': {
              'timestamp': timestamp,
              'author': message.author,
            },
          }),
          headers: headers,
        );
      } else if (request.method == 'PUT') {
        // Edit message - requires NOSTR event with 'edit' action
        final event = _verifyNostrEventWithTags(request, 'edit', roomId);
        if (event == null) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Invalid or missing NOSTR authentication',
              'code': 'AUTH_REQUIRED',
            }),
            headers: headers,
          );
        }

        // Get timestamp from event tags (should match URL)
        final timestampTag = event.getTagValue('timestamp');
        if (timestampTag != null && timestampTag != timestamp) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Timestamp mismatch between URL and event',
              'code': 'TIMESTAMP_MISMATCH',
            }),
            headers: headers,
          );
        }

        // Get the callsign from the event tags
        final callsignTag = event.getTagValue('callsign');

        // Find the message first to get the author
        final message = await chatService.findMessage(roomId, timestamp);
        if (message == null) {
          return shelf.Response.notFound(
            jsonEncode({'error': 'Message not found', 'code': 'NOT_FOUND'}),
            headers: headers,
          );
        }

        // Verify callsign matches if provided
        if (callsignTag != null && callsignTag != message.author) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Callsign mismatch',
              'code': 'CALLSIGN_MISMATCH',
            }),
            headers: headers,
          );
        }

        // New content is in the event content field
        final newContent = event.content;
        if (newContent.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'New content cannot be empty'}),
            headers: headers,
          );
        }

        // Edit the message (ChatService handles authorization - only author can edit)
        // event.sig is guaranteed non-null since _verifyNostrEventWithTags verified the signature
        final editedMessage = await chatService.editMessage(
          channelId: roomId,
          timestamp: timestamp,
          authorCallsign: message.author,
          newContent: newContent,
          actorNpub: event.npub,
          newSignature: event.sig!,
          newCreatedAt: event.createdAt,
        );

        if (editedMessage == null) {
          return shelf.Response.internalServerError(
            body: jsonEncode({'error': 'Failed to edit message'}),
            headers: headers,
          );
        }

        LogService().log('LogApiService: Message edited in $roomId at $timestamp by ${event.npub}');

        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'action': 'edit',
            'roomId': roomId,
            'edited': {
              'timestamp': timestamp,
              'author': editedMessage.author,
              'edited_at': editedMessage.editedAt,
            },
          }),
          headers: headers,
        );
      }

      return shelf.Response(405, body: jsonEncode({'error': 'Method not allowed'}), headers: headers);
    } on PermissionDeniedException catch (e) {
      return shelf.Response.forbidden(
        jsonEncode({'error': e.message, 'code': 'PERMISSION_DENIED'}),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error in message modification: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle reaction toggle requests
  /// POST /api/chat/{roomId}/messages/{timestamp}/reactions
  Future<shelf.Response> _handleChatMessageReactionRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      if (request.method != 'POST') {
        return shelf.Response(
          405,
          body: jsonEncode({'error': 'Method not allowed'}),
          headers: headers,
        );
      }

      final regex = RegExp(r'^api/chat/(?:rooms/)?([^/]+)/messages/(.+)/reactions$');
      final match = regex.firstMatch(urlPath);
      if (match == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Invalid path format'}),
          headers: headers,
        );
      }

      final roomId = Uri.decodeComponent(match.group(1)!);
      final timestamp = Uri.decodeComponent(match.group(2)!);

      final event = _verifyNostrEventWithTags(request, 'react', roomId);
      if (event == null) {
        return shelf.Response.forbidden(
          jsonEncode({
            'error': 'Invalid or missing NOSTR authentication',
            'code': 'AUTH_REQUIRED',
          }),
          headers: headers,
        );
      }

      final timestampTag = event.getTagValue('timestamp');
      if (timestampTag != null && timestampTag != timestamp) {
        return shelf.Response.forbidden(
          jsonEncode({
            'error': 'Timestamp mismatch between URL and event',
            'code': 'TIMESTAMP_MISMATCH',
          }),
          headers: headers,
        );
      }

      final reactionTag = event.getTagValue('reaction');
      if (reactionTag == null || reactionTag.trim().isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing reaction tag'}),
          headers: headers,
        );
      }

      final callsignTag = event.getTagValue('callsign');
      if (callsignTag == null || callsignTag.trim().isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing callsign tag'}),
          headers: headers,
        );
      }

      final reactionKey = ReactionUtils.normalizeReactionKey(reactionTag);
      final actorCallsign = callsignTag.trim();

      await _initializeChatServiceIfNeeded();
      final chatService = ChatService();
      final channel = chatService.getChannel(roomId);
      final isCallsignLike = RegExp(r'^[A-Z0-9]{3,}$').hasMatch(roomId.toUpperCase());

      if (channel == null && isCallsignLike) {
        final dmService = DirectMessageService();
        await dmService.initialize();
        final updated = await dmService.toggleReaction(
          roomId.toUpperCase(),
          timestamp,
          actorCallsign,
          reactionKey,
        );

        if (updated == null) {
          return shelf.Response.notFound(
            jsonEncode({'error': 'Message not found', 'code': 'NOT_FOUND'}),
            headers: headers,
          );
        }

        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'roomId': roomId.toUpperCase(),
            'timestamp': timestamp,
            'reaction': reactionKey,
            'reactions': updated.reactions,
          }),
          headers: headers,
        );
      }

      if (chatService.collectionPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'No chat collection loaded'}),
          headers: headers,
        );
      }

      final canAccess = await _canAccessChatRoom(roomId, event.npub);
      if (!canAccess) {
        return shelf.Response.forbidden(
          jsonEncode({
            'error': 'Access denied',
            'code': 'ROOM_ACCESS_DENIED',
          }),
          headers: headers,
        );
      }

      final updated = await chatService.toggleReaction(
        channelId: roomId,
        timestamp: timestamp,
        actorCallsign: actorCallsign,
        reaction: reactionKey,
      );

      if (updated == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Message not found', 'code': 'NOT_FOUND'}),
          headers: headers,
        );
      }

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'roomId': roomId,
          'timestamp': timestamp,
          'reaction': reactionKey,
          'reactions': updated.reactions,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling reaction toggle: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle ban management requests
  /// POST /api/chat/{roomId}/ban/{npub} - Ban user
  /// DELETE /api/chat/{roomId}/ban/{npub} - Unban user
  Future<shelf.Response> _handleChatBanRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      await _initializeChatServiceIfNeeded();
      final chatService = ChatService();

      // Extract roomId and npub from path: api/chat/{roomId}/ban/{npub}
      final regex = RegExp(r'^api/chat/([^/]+)/ban/(.+)$');
      final match = regex.firstMatch(urlPath);
      if (match == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Invalid path format'}),
          headers: headers,
        );
      }

      final roomId = Uri.decodeComponent(match.group(1)!);
      final targetNpubFromPath = Uri.decodeComponent(match.group(2)!);

      if (request.method == 'POST') {
        // Ban user - requires NOSTR event with 'ban' action
        final event = _verifyNostrEventWithTags(request, 'ban', roomId);
        if (event == null) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Invalid or missing NOSTR authentication',
              'code': 'AUTH_REQUIRED',
            }),
            headers: headers,
          );
        }

        final targetNpub = event.getTagValue('target') ?? targetNpubFromPath;
        await chatService.banMember(roomId, event.npub, targetNpub);

        LogService().log('LogApiService: User $targetNpub banned from $roomId by ${event.npub}');

        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'action': 'ban',
            'roomId': roomId,
            'targetNpub': targetNpub,
          }),
          headers: headers,
        );
      } else if (request.method == 'DELETE') {
        // Unban user - requires NOSTR event with 'unban' action
        final event = _verifyNostrEventWithTags(request, 'unban', roomId);
        if (event == null) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Invalid or missing NOSTR authentication',
              'code': 'AUTH_REQUIRED',
            }),
            headers: headers,
          );
        }

        final targetNpub = event.getTagValue('target') ?? targetNpubFromPath;
        await chatService.unbanMember(roomId, event.npub, targetNpub);

        LogService().log('LogApiService: User $targetNpub unbanned from $roomId by ${event.npub}');

        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'action': 'unban',
            'roomId': roomId,
            'targetNpub': targetNpub,
          }),
          headers: headers,
        );
      }

      return shelf.Response(405, body: jsonEncode({'error': 'Method not allowed'}), headers: headers);
    } on PermissionDeniedException catch (e) {
      return shelf.Response.forbidden(
        jsonEncode({'error': e.message, 'code': 'PERMISSION_DENIED'}),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error in ban management: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle role management requests
  /// GET /api/chat/{roomId}/roles - Get room roles
  /// POST /api/chat/{roomId}/promote - Promote member (requires 'role' tag: moderator|admin)
  /// POST /api/chat/{roomId}/demote - Demote member
  Future<shelf.Response> _handleChatRolesRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      await _initializeChatServiceIfNeeded();
      final chatService = ChatService();

      // Extract roomId from path
      final regex = RegExp(r'^api/chat/([^/]+)/(roles|promote|demote)$');
      final match = regex.firstMatch(urlPath);
      if (match == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Invalid path format'}),
          headers: headers,
        );
      }

      final roomId = Uri.decodeComponent(match.group(1)!);
      final action = match.group(2)!;

      if (action == 'roles' && request.method == 'GET') {
        // Get roles - requires NOSTR auth
        final authNpub = _verifyNostrAuth(request);
        if (authNpub == null) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Authentication required',
              'code': 'AUTH_REQUIRED',
            }),
            headers: headers,
          );
        }

        final roles = chatService.getRoomRoles(roomId, authNpub);

        return shelf.Response.ok(
          jsonEncode({
            'roomId': roomId,
            ...roles,
          }),
          headers: headers,
        );
      } else if (action == 'promote' && request.method == 'POST') {
        // Promote - requires NOSTR event with 'promote' action and 'role' tag
        final event = _verifyNostrEventWithTags(request, 'promote', roomId);
        if (event == null) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Invalid or missing NOSTR authentication',
              'code': 'AUTH_REQUIRED',
            }),
            headers: headers,
          );
        }

        final targetNpub = event.getTagValue('target');
        final role = event.getTagValue('role');
        if (targetNpub == null || role == null) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'error': 'Missing target or role tags',
              'hint': 'Include ["target", "npub1..."] and ["role", "moderator|admin"] tags',
            }),
            headers: headers,
          );
        }

        if (role == 'admin') {
          await chatService.promoteToAdmin(roomId, event.npub, targetNpub);
        } else if (role == 'moderator') {
          await chatService.promoteToModerator(roomId, event.npub, targetNpub);
        } else {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'Invalid role: $role. Use "moderator" or "admin"'}),
            headers: headers,
          );
        }

        LogService().log('LogApiService: User $targetNpub promoted to $role in $roomId by ${event.npub}');

        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'action': 'promote',
            'roomId': roomId,
            'targetNpub': targetNpub,
            'role': role,
          }),
          headers: headers,
        );
      } else if (action == 'demote' && request.method == 'POST') {
        // Demote - requires NOSTR event with 'demote' action
        final event = _verifyNostrEventWithTags(request, 'demote', roomId);
        if (event == null) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Invalid or missing NOSTR authentication',
              'code': 'AUTH_REQUIRED',
            }),
            headers: headers,
          );
        }

        final targetNpub = event.getTagValue('target');
        if (targetNpub == null) {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'Missing target tag'}),
            headers: headers,
          );
        }

        await chatService.demote(roomId, event.npub, targetNpub);

        LogService().log('LogApiService: User $targetNpub demoted in $roomId by ${event.npub}');

        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'action': 'demote',
            'roomId': roomId,
            'targetNpub': targetNpub,
          }),
          headers: headers,
        );
      }

      return shelf.Response(405, body: jsonEncode({'error': 'Method not allowed'}), headers: headers);
    } on PermissionDeniedException catch (e) {
      return shelf.Response.forbidden(
        jsonEncode({'error': e.message, 'code': 'PERMISSION_DENIED'}),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error in role management: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle membership application requests
  /// POST /api/chat/{roomId}/apply - Apply for membership
  /// GET /api/chat/{roomId}/applicants - List pending applicants
  /// POST /api/chat/{roomId}/approve/{npub} - Approve applicant
  /// DELETE /api/chat/{roomId}/reject/{npub} - Reject applicant
  Future<shelf.Response> _handleChatApplicationRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      await _initializeChatServiceIfNeeded();
      final chatService = ChatService();

      // Handle /apply endpoint
      if (urlPath.endsWith('/apply')) {
        final regex = RegExp(r'^api/chat/([^/]+)/apply$');
        final match = regex.firstMatch(urlPath);
        if (match == null) {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'Invalid path format'}),
            headers: headers,
          );
        }

        final roomId = Uri.decodeComponent(match.group(1)!);

        if (request.method == 'POST') {
          // Apply for membership - requires NOSTR event with 'apply' action
          final event = _verifyNostrEventWithTags(request, 'apply', roomId);
          if (event == null) {
            return shelf.Response.forbidden(
              jsonEncode({
                'error': 'Invalid or missing NOSTR authentication',
                'code': 'AUTH_REQUIRED',
              }),
              headers: headers,
            );
          }

          final callsign = event.getTagValue('callsign');
          final message = event.content.isNotEmpty ? event.content : null;

          await chatService.applyForMembership(roomId, event.npub, callsign, message);

          LogService().log('LogApiService: Membership application submitted for $roomId by ${event.npub}');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'action': 'apply',
              'roomId': roomId,
              'status': 'pending',
            }),
            headers: headers,
          );
        }
      }

      // Handle /applicants endpoint
      if (urlPath.contains('/applicants')) {
        final regex = RegExp(r'^api/chat/([^/]+)/applicants$');
        final match = regex.firstMatch(urlPath);
        if (match != null && request.method == 'GET') {
          final roomId = Uri.decodeComponent(match.group(1)!);

          final authNpub = _verifyNostrAuth(request);
          if (authNpub == null) {
            return shelf.Response.forbidden(
              jsonEncode({
                'error': 'Authentication required',
                'code': 'AUTH_REQUIRED',
              }),
              headers: headers,
            );
          }

          final applicants = chatService.getPendingApplications(roomId, authNpub);

          return shelf.Response.ok(
            jsonEncode({
              'roomId': roomId,
              'applicants': applicants.map((a) => {
                'npub': a.npub,
                'callsign': a.callsign,
                'appliedAt': a.appliedAt.toIso8601String(),
                'message': a.message,
              }).toList(),
              'total': applicants.length,
            }),
            headers: headers,
          );
        }
      }

      // Handle /approve/{npub} endpoint
      if (urlPath.contains('/approve/')) {
        final regex = RegExp(r'^api/chat/([^/]+)/approve/(.+)$');
        final match = regex.firstMatch(urlPath);
        if (match != null && request.method == 'POST') {
          final roomId = Uri.decodeComponent(match.group(1)!);
          final applicantNpubFromPath = Uri.decodeComponent(match.group(2)!);

          final event = _verifyNostrEventWithTags(request, 'approve', roomId);
          if (event == null) {
            return shelf.Response.forbidden(
              jsonEncode({
                'error': 'Invalid or missing NOSTR authentication',
                'code': 'AUTH_REQUIRED',
              }),
              headers: headers,
            );
          }

          final applicantNpub = event.getTagValue('target') ?? applicantNpubFromPath;
          await chatService.approveApplication(roomId, event.npub, applicantNpub);

          LogService().log('LogApiService: Application approved for $applicantNpub in $roomId by ${event.npub}');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'action': 'approve',
              'roomId': roomId,
              'applicantNpub': applicantNpub,
            }),
            headers: headers,
          );
        }
      }

      // Handle /reject/{npub} endpoint
      if (urlPath.contains('/reject/')) {
        final regex = RegExp(r'^api/chat/([^/]+)/reject/(.+)$');
        final match = regex.firstMatch(urlPath);
        if (match != null && request.method == 'DELETE') {
          final roomId = Uri.decodeComponent(match.group(1)!);
          final applicantNpubFromPath = Uri.decodeComponent(match.group(2)!);

          final event = _verifyNostrEventWithTags(request, 'reject', roomId);
          if (event == null) {
            return shelf.Response.forbidden(
              jsonEncode({
                'error': 'Invalid or missing NOSTR authentication',
                'code': 'AUTH_REQUIRED',
              }),
              headers: headers,
            );
          }

          final applicantNpub = event.getTagValue('target') ?? applicantNpubFromPath;
          await chatService.rejectApplication(roomId, event.npub, applicantNpub);

          LogService().log('LogApiService: Application rejected for $applicantNpub in $roomId by ${event.npub}');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'action': 'reject',
              'roomId': roomId,
              'applicantNpub': applicantNpub,
            }),
            headers: headers,
          );
        }
      }

      return shelf.Response(405, body: jsonEncode({'error': 'Method not allowed'}), headers: headers);
    } on PermissionDeniedException catch (e) {
      return shelf.Response.forbidden(
        jsonEncode({'error': e.message, 'code': 'PERMISSION_DENIED'}),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error in application management: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  // ============================================================
  // DM API endpoints
  // ============================================================

  /// Extract callsign from DM path like 'api/dm/{callsign}/messages'
  String? _extractCallsignFromDMPath(String urlPath) {
    final regex = RegExp(r'^api/dm/([^/]+)/messages$');
    final match = regex.firstMatch(urlPath);
    if (match != null) {
      return Uri.decodeComponent(match.group(1)!).toUpperCase();
    }
    return null;
  }

  /// Handle GET /api/dm/conversations - list DM conversations
  Future<shelf.Response> _handleDMConversationsRequest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final dmService = DirectMessageService();
      await dmService.initialize();

      final conversations = await dmService.listConversations();

      return shelf.Response.ok(
        jsonEncode({
          'conversations': conversations.map((c) => {
            'callsign': c.otherCallsign,
            'myCallsign': c.myCallsign,
            'lastMessage': c.lastMessageTime?.toIso8601String(),
            'lastMessagePreview': c.lastMessagePreview,
            'lastMessageAuthor': c.lastMessageAuthor,
            'unread': c.unreadCount,
            'isOnline': c.isOnline,
            'lastSyncTime': c.lastSyncTime?.toIso8601String(),
          }).toList(),
          'total': conversations.length,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error listing DM conversations: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle GET /api/dm/{callsign}/messages - get DM messages
  Future<shelf.Response> _handleDMMessagesRequest(
    shelf.Request request,
    String targetCallsign,
    Map<String, String> headers,
  ) async {
    try {
      final dmService = DirectMessageService();
      await dmService.initialize();

      // Parse query parameters
      final queryParams = request.url.queryParameters;
      final limitParam = queryParams['limit'];
      int limit = 100;
      if (limitParam != null) {
        limit = int.tryParse(limitParam) ?? 100;
        limit = limit.clamp(1, 500);
      }

      final messages = await dmService.loadMessages(targetCallsign, limit: limit);

      return shelf.Response.ok(
        jsonEncode({
          'targetCallsign': targetCallsign,
          'messages': messages.map((m) => {
            'author': m.author,
            'timestamp': m.timestamp,
            'content': m.content,
            'npub': m.npub,
            'signature': m.signature,
            'verified': m.isVerified,
          }).toList(),
          'count': messages.length,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error getting DM messages: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/dm/{callsign}/messages - send DM message
  Future<shelf.Response> _handleDMPostMessageRequest(
    shelf.Request request,
    String targetCallsign,
    Map<String, String> headers,
  ) async {
    try {
      final dmService = DirectMessageService();
      await dmService.initialize();

      final bodyStr = await request.readAsString();
      if (bodyStr.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing request body'}),
          headers: headers,
        );
      }

      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final content = body['content'] as String?;

      if (content == null || content.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing content field'}),
          headers: headers,
        );
      }

      // Send the message
      await dmService.sendMessage(targetCallsign, content);

      LogService().log('LogApiService: DM sent to $targetCallsign');

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'targetCallsign': targetCallsign,
          'timestamp': DateTime.now().toIso8601String(),
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error sending DM: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle GET /api/dm/sync/{callsign} - get messages for sync
  Future<shelf.Response> _handleDMSyncGetRequest(
    shelf.Request request,
    String targetCallsign,
    Map<String, String> headers,
  ) async {
    try {
      final dmService = DirectMessageService();
      await dmService.initialize();

      final queryParams = request.url.queryParameters;
      final sinceParam = queryParams['since'] ?? '';

      List<ChatMessage> messages;
      if (sinceParam.isNotEmpty) {
        messages = await dmService.loadMessagesSince(targetCallsign, sinceParam);
      } else {
        messages = await dmService.loadMessages(targetCallsign, limit: 100);
      }

      return shelf.Response.ok(
        jsonEncode({
          'messages': messages.map((m) => m.toJson()).toList(),
          'timestamp': DateTime.now().toIso8601String(),
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error getting DM sync: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/dm/sync/{callsign} - receive synced messages
  ///
  /// Security: Only accepts messages that are:
  /// 1. From targetCallsign (messages they sent to us)
  /// 2. From ourselves (our messages they're returning to us)
  /// 3. Have valid NOSTR signatures
  Future<shelf.Response> _handleDMSyncPostRequest(
    shelf.Request request,
    String targetCallsign,
    Map<String, String> headers,
  ) async {
    try {
      final dmService = DirectMessageService();
      await dmService.initialize();

      // Get our callsign for validation
      String myCallsign = '';
      try {
        myCallsign = ProfileService().getProfile().callsign.toUpperCase();
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Profile not available'}),
          headers: headers,
        );
      }

      final bodyStr = await request.readAsString();
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final incomingMessages = <ChatMessage>[];

      if (body['messages'] is List) {
        for (final msgJson in body['messages']) {
          incomingMessages.add(ChatMessage.fromJson(msgJson));
        }
      }

      // Ensure conversation exists
      await dmService.getOrCreateConversation(targetCallsign);

      // Merge messages (deduplication based on timestamp + author)
      int accepted = 0;
      int rejected = 0;
      LogService().log('DM sync: Processing ${incomingMessages.length} messages from $targetCallsign (myCallsign=$myCallsign)');
      if (incomingMessages.isNotEmpty) {
        final local = await dmService.loadMessages(targetCallsign, limit: 99999);
        final existing = <String>{};
        for (final msg in local) {
          existing.add('${msg.timestamp}|${msg.author}');
        }
        LogService().log('DM sync: Have ${existing.length} existing messages');

        for (final msg in incomingMessages) {
          LogService().log('DM sync: Processing message from ${msg.author} at ${msg.timestamp}');
          LogService().log('DM sync: isSigned=${msg.isSigned}, npub=${msg.npub}, signature=${msg.signature?.substring(0, 20) ?? "null"}...');

          // Security check: message author must be either:
          // - targetCallsign (messages FROM them)
          // - our callsign (our messages being returned)
          final authorUpper = msg.author.toUpperCase();
          if (authorUpper != targetCallsign.toUpperCase() && authorUpper != myCallsign) {
            LogService().log('DM sync rejected: invalid author ${msg.author} (expected $targetCallsign or $myCallsign)');
            rejected++;
            continue;
          }
          LogService().log('DM sync: Author check passed (author=$authorUpper, target=${targetCallsign.toUpperCase()}, my=$myCallsign)');

          // Security check: message must have valid signature if signed
          // Note: Unsigned messages are accepted (signature is optional)
          // For signed messages, verify cryptographically using NOSTR NIP-01
          if (msg.isSigned) {
            // For DM signature verification, the roomId must be the receiver's callsign (myCallsign)
            // because when the sender signed the message, they used the recipient's callsign as the room
            // (a DM conversation is identified by the "other" party's callsign)
            LogService().log('DM sync: Verifying signature for ${msg.author} with roomId=$myCallsign...');
            final verified = dmService.verifySignature(msg, roomId: myCallsign);
            LogService().log('DM sync: Signature verification result: $verified');
            if (!verified) {
              LogService().log('DM sync rejected: invalid signature from ${msg.author}');
              rejected++;
              continue;
            }
          } else {
            LogService().log('DM sync: Message is not signed, skipping verification');
          }

          final id = '${msg.timestamp}|${msg.author}';
          if (!existing.contains(id)) {
            // Save message directly preserving original author signature
            LogService().log('DM sync: Saving new message $id');
            await dmService.saveIncomingMessage(targetCallsign, msg);
            accepted++;
          } else {
            LogService().log('DM sync: Message $id already exists, skipping');
          }
        }
      }
      LogService().log('DM sync complete: accepted=$accepted, rejected=$rejected');

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'accepted': accepted,
          'rejected': rejected,
          'timestamp': DateTime.now().toIso8601String(),
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error syncing DM: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle GET /api/dm/{callsign}/files/{filename} - serve DM file
  Future<shelf.Response> _handleDMFileGetRequest(
    shelf.Request request,
    String senderCallsign,
    String filename,
    Map<String, String> headers,
  ) async {
    try {
      // Security: prevent path traversal
      if (filename.contains('..') || filename.contains('/') || filename.contains('\\')) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Invalid filename'}),
          headers: headers,
        );
      }

      final dmService = DirectMessageService();
      await dmService.initialize();

      // Try to find the file in DM storage
      var filePath = await dmService.getVoiceFilePath(senderCallsign, filename);
      filePath ??= await dmService.getFilePath(senderCallsign, filename);

      if (filePath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'File not found'}),
          headers: headers,
        );
      }

      final file = io.File(filePath);
      if (!await file.exists()) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'File not found'}),
          headers: headers,
        );
      }

      // Determine content type from file extension
      final lowerName = filename.toLowerCase();
      String contentType = 'application/octet-stream';
      if (lowerName.endsWith('.webm')) {
        contentType = 'audio/webm';
      } else if (lowerName.endsWith('.ogg')) {
        contentType = 'audio/ogg';
      } else if (lowerName.endsWith('.mp3')) {
        contentType = 'audio/mpeg';
      } else if (lowerName.endsWith('.wav')) {
        contentType = 'audio/wav';
      } else if (lowerName.endsWith('.jpg') || lowerName.endsWith('.jpeg')) {
        contentType = 'image/jpeg';
      } else if (lowerName.endsWith('.png')) {
        contentType = 'image/png';
      } else if (lowerName.endsWith('.gif')) {
        contentType = 'image/gif';
      } else if (lowerName.endsWith('.webp')) {
        contentType = 'image/webp';
      } else if (lowerName.endsWith('.pdf')) {
        contentType = 'application/pdf';
      }

      final fileBytes = await file.readAsBytes();
      return shelf.Response.ok(
        fileBytes,
        headers: {
          ...headers,
          'Content-Type': contentType,
          'Content-Length': fileBytes.length.toString(),
        },
      );
    } catch (e) {
      LogService().log('LogApiService: Error serving DM file: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/dm/{callsign}/files/{filename} - receive DM file upload
  Future<shelf.Response> _handleDMFilePostRequest(
    shelf.Request request,
    String senderCallsign,
    String filename,
    Map<String, String> headers,
  ) async {
    try {
      // Security: prevent path traversal
      if (filename.contains('..') || filename.contains('/') || filename.contains('\\')) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Invalid filename'}),
          headers: headers,
        );
      }

      // Read file bytes from request body
      var bytes = await request.read().fold<List<int>>(
        <int>[],
        (previous, element) => previous..addAll(element),
      );

      // Handle base64 encoding if specified
      final transferEncoding = request.headers['content-transfer-encoding'];
      if (transferEncoding != null && transferEncoding.toLowerCase().contains('base64')) {
        try {
          bytes = base64Decode(utf8.decode(bytes));
        } catch (e) {
          return shelf.Response(
            400,
            body: jsonEncode({'error': 'Invalid base64 payload'}),
            headers: headers,
          );
        }
      }

      if (bytes.isEmpty) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Empty file'}),
          headers: headers,
        );
      }

      // 10 MB limit
      if (bytes.length > 10 * 1024 * 1024) {
        return shelf.Response(
          413,
          body: jsonEncode({'error': 'File too large (max 10 MB)'}),
          headers: headers,
        );
      }

      // Ensure DM files directory exists
      final storagePath = StorageConfig().baseDir;
      final filesDir = io.Directory('$storagePath/chat/$senderCallsign/files');
      if (!await filesDir.exists()) {
        await filesDir.create(recursive: true);
      }

      // Save file
      final filePath = '${filesDir.path}/$filename';
      final file = io.File(filePath);
      await file.writeAsBytes(bytes);

      LogService().log('DM FILE RECEIVE SUCCESS: Received $filename from $senderCallsign (${bytes.length} bytes)');

      return shelf.Response(
        201,
        body: jsonEncode({
          'success': true,
          'filename': filename,
          'size': bytes.length,
          'path': '/api/dm/$senderCallsign/files/$filename',
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('DM FILE RECEIVE FAILED: Error from $senderCallsign: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Devices API endpoint (debug)
  // ============================================================

  /// Handle GET /api/devices - list discovered devices
  Future<shelf.Response> _handleDevicesRequest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final devicesService = DevicesService();
      final devices = devicesService.getAllDevices();

      String myCallsign = '';
      try {
        myCallsign = ProfileService().getProfile().callsign;
      } catch (e) {
        // Profile not initialized
      }

      return shelf.Response.ok(
        jsonEncode({
          'myCallsign': myCallsign,
          'devices': devices.map((d) => {
            'callsign': d.callsign,
            'name': d.name,
            'nickname': d.nickname,
            'url': d.url,
            'npub': d.npub,
            'isOnline': d.isOnline,
            'latency': d.latency,
            'lastSeen': d.lastSeen?.toIso8601String(),
            'latitude': d.latitude,
            'longitude': d.longitude,
            'connectionMethods': d.connectionMethods,
            'source': d.source.name,
            'bleProximity': d.bleProximity,
            'bleRssi': d.bleRssi,
          }).toList(),
          'total': devices.length,
          'isBLEAvailable': devicesService.isBLEAvailable,
          'isBLEScanning': devicesService.isBLEScanning,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error listing devices: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Backup API Endpoints
  // ============================================================

  /// Main handler for all /api/backup/* endpoints
  Future<shelf.Response> _handleBackupRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      final backupService = BackupService();
      final method = request.method;

      // Remove 'api/backup/' prefix for easier parsing
      final subPath = urlPath.substring('api/backup/'.length);

      // GET/PUT /api/backup/settings - Provider settings
      if (subPath == 'settings' || subPath == 'settings/') {
        if (method == 'GET') {
          return await _handleBackupSettingsGet(headers);
        } else if (method == 'PUT') {
          return await _handleBackupSettingsPut(request, headers);
        }
      }

      // GET /api/backup/clients - List clients (provider endpoint)
      if (subPath == 'clients' || subPath == 'clients/') {
        if (method == 'GET') {
          return await _handleBackupClientsGet(headers);
        }
      }

      // GET/DELETE /api/backup/clients/{callsign} - Client details or remove
      if (subPath.startsWith('clients/') && !subPath.contains('/snapshots')) {
        final callsign = _extractCallsignFromBackupPath(subPath, 'clients/');
        if (callsign != null) {
          if (method == 'GET') {
            return await _handleBackupClientGet(callsign, headers);
          } else if (method == 'DELETE') {
            return await _handleBackupClientDelete(request, callsign, headers);
          } else if (method == 'PUT') {
            return await _handleBackupClientPut(request, callsign, headers);
          }
        }
      }

      // GET /api/backup/clients/{callsign}/snapshots - List snapshots
      if (subPath.contains('/snapshots') && !subPath.contains('/files/')) {
        final match = RegExp(r'^clients/([^/]+)/snapshots/?$').firstMatch(subPath);
        if (match != null) {
          final callsign = match.group(1)!.toUpperCase();
          if (method == 'GET') {
            return await _handleBackupSnapshotsGet(callsign, headers);
          }
        }
      }

      // GET/PUT /api/backup/clients/{callsign}/snapshots/{date} - Manifest
      final snapshotMatch = RegExp(r'^clients/([^/]+)/snapshots/(\d{4}-\d{2}-\d{2})/?$').firstMatch(subPath);
      if (snapshotMatch != null) {
        final callsign = snapshotMatch.group(1)!.toUpperCase();
        final snapshotId = snapshotMatch.group(2)!;
        if (method == 'GET') {
          return await _handleBackupManifestGet(callsign, snapshotId, headers);
        } else if (method == 'PUT') {
          return await _handleBackupManifestPut(request, callsign, snapshotId, headers);
        }
      }

      // GET/PUT /api/backup/clients/{callsign}/snapshots/{date}/files/{name}
      final fileMatch = RegExp(r'^clients/([^/]+)/snapshots/(\d{4}-\d{2}-\d{2})/files/(.+)$').firstMatch(subPath);
      if (fileMatch != null) {
        final callsign = fileMatch.group(1)!.toUpperCase();
        final snapshotId = fileMatch.group(2)!;
        final fileName = fileMatch.group(3)!;
        if (method == 'GET') {
          return await _handleBackupFileGet(callsign, snapshotId, fileName, headers);
        } else if (method == 'PUT') {
          return await _handleBackupFilePut(request, callsign, snapshotId, fileName, headers);
        }
      }

      // GET /api/backup/providers - List providers (client endpoint)
      if (subPath == 'providers' || subPath == 'providers/') {
        if (method == 'GET') {
          return await _handleBackupProvidersGet(headers);
        }
      }

      // POST/PUT/DELETE /api/backup/providers/{callsign}
      if (subPath.startsWith('providers/')) {
        final callsign = _extractCallsignFromBackupPath(subPath, 'providers/');
        if (callsign != null) {
          if (method == 'POST') {
            return await _handleBackupProviderInvite(request, callsign, headers);
          } else if (method == 'PUT') {
            return await _handleBackupProviderUpdate(request, callsign, headers);
          } else if (method == 'DELETE') {
            return await _handleBackupProviderRemove(callsign, headers);
          } else if (method == 'GET') {
            return await _handleBackupProviderGet(callsign, headers);
          }
        }
      }

      // POST /api/backup/start - Start backup
      if (subPath == 'start' && method == 'POST') {
        return await _handleBackupStart(request, headers);
      }

      // GET /api/backup/status - Get backup/restore status
      if (subPath == 'status' && method == 'GET') {
        return await _handleBackupStatusGet(headers);
      }

      // POST /api/backup/restore - Start restore
      if (subPath == 'restore' && method == 'POST') {
        return await _handleBackupRestore(request, headers);
      }

      // POST /api/backup/discover - Start discovery
      // GET /api/backup/discover/{id} - Get discovery status
      if (subPath == 'discover' && method == 'POST') {
        return await _handleBackupDiscoverStart(request, headers);
      }
      if (subPath.startsWith('discover/')) {
        final discoveryId = subPath.substring('discover/'.length);
        if (discoveryId.isNotEmpty && method == 'GET') {
          return await _handleBackupDiscoverStatus(discoveryId, headers);
        }
      }

      return shelf.Response.notFound(
        jsonEncode({'error': 'Backup endpoint not found', 'path': urlPath}),
        headers: headers,
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Error handling backup request: $e\n$stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Helper to extract callsign from backup path
  String? _extractCallsignFromBackupPath(String subPath, String prefix) {
    if (!subPath.startsWith(prefix)) return null;
    final remainder = subPath.substring(prefix.length);
    final slashIndex = remainder.indexOf('/');
    final callsign = slashIndex >= 0 ? remainder.substring(0, slashIndex) : remainder;
    return callsign.isEmpty ? null : callsign.toUpperCase();
  }

  // === Provider Settings Endpoints ===

  /// GET /api/backup/settings - Get provider settings
  Future<shelf.Response> _handleBackupSettingsGet(Map<String, String> headers) async {
    final backupService = BackupService();
    final settings = backupService.providerSettings;

    return shelf.Response.ok(
      jsonEncode(settings?.toJson() ?? {
        'enabled': false,
        'maxTotalStorageBytes': 0,
        'defaultMaxClientStorageBytes': 0,
        'defaultMaxSnapshots': 0,
        'autoAcceptFromContacts': false,
      }),
      headers: headers,
    );
  }

  /// PUT /api/backup/settings - Update provider settings
  Future<shelf.Response> _handleBackupSettingsPut(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;

    final backupService = BackupService();
    final currentSettings = backupService.providerSettings ?? BackupProviderSettings(
      enabled: false,
      maxTotalStorageBytes: 0,
      defaultMaxClientStorageBytes: 0,
      defaultMaxSnapshots: 0,
      autoAcceptFromContacts: false,
      updatedAt: DateTime.now(),
    );

    // Update settings
    final newSettings = BackupProviderSettings(
      enabled: data['enabled'] as bool? ?? currentSettings.enabled,
      maxTotalStorageBytes: data['maxTotalStorageBytes'] as int? ?? currentSettings.maxTotalStorageBytes,
      defaultMaxClientStorageBytes: data['defaultMaxClientStorageBytes'] as int? ?? currentSettings.defaultMaxClientStorageBytes,
      defaultMaxSnapshots: data['defaultMaxSnapshots'] as int? ?? currentSettings.defaultMaxSnapshots,
      autoAcceptFromContacts: data['autoAcceptFromContacts'] as bool? ?? currentSettings.autoAcceptFromContacts,
      updatedAt: DateTime.now(),
    );

    await backupService.saveProviderSettings(newSettings);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'settings': newSettings.toJson()}),
      headers: headers,
    );
  }

  // === Provider Client Management Endpoints ===

  /// GET /api/backup/clients - List all clients
  Future<shelf.Response> _handleBackupClientsGet(Map<String, String> headers) async {
    final backupService = BackupService();
    final clients = await backupService.getClients();

    return shelf.Response.ok(
      jsonEncode({
        'clients': clients.map((c) => c.toJson()).toList(),
        'total': clients.length,
      }),
      headers: headers,
    );
  }

  /// GET /api/backup/clients/{callsign} - Get specific client
  Future<shelf.Response> _handleBackupClientGet(
    String callsign,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    final clients = await backupService.getClients();
    final client = clients.where((c) => c.clientCallsign == callsign).firstOrNull;

    if (client == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Client not found', 'callsign': callsign}),
        headers: headers,
      );
    }

    return shelf.Response.ok(
      jsonEncode(client.toJson()),
      headers: headers,
    );
  }

  /// PUT /api/backup/clients/{callsign} - Accept/update client (for invite acceptance)
  Future<shelf.Response> _handleBackupClientPut(
    shelf.Request request,
    String callsign,
    Map<String, String> headers,
  ) async {
    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final action = data['action'] as String?;

    final backupService = BackupService();

    if (action == 'accept') {
      final maxStorageBytes = data['maxStorageBytes'] as int? ??
          backupService.providerSettings?.defaultMaxClientStorageBytes ?? 1073741824;
      final maxSnapshots = data['maxSnapshots'] as int? ??
          backupService.providerSettings?.defaultMaxSnapshots ?? 7;

      // Find the client npub
      final clients = await backupService.getClients();
      final client = clients.where((c) => c.clientCallsign == callsign).firstOrNull;
      if (client == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Client not found', 'callsign': callsign}),
          headers: headers,
        );
      }

      await backupService.acceptInvite(client.clientNpub, client.clientCallsign, maxStorageBytes, maxSnapshots);

      return shelf.Response.ok(
        jsonEncode({'success': true, 'message': 'Client invite accepted'}),
        headers: headers,
      );
    } else if (action == 'decline') {
      final clients = await backupService.getClients();
      final client = clients.where((c) => c.clientCallsign == callsign).firstOrNull;
      if (client == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Client not found', 'callsign': callsign}),
          headers: headers,
        );
      }

      await backupService.declineInvite(client.clientNpub, client.clientCallsign);

      return shelf.Response.ok(
        jsonEncode({'success': true, 'message': 'Client invite declined'}),
        headers: headers,
      );
    }

    return shelf.Response.badRequest(
      body: jsonEncode({'error': 'Invalid action', 'validActions': ['accept', 'decline']}),
      headers: headers,
    );
  }

  /// DELETE /api/backup/clients/{callsign} - Remove client
  Future<shelf.Response> _handleBackupClientDelete(
    shelf.Request request,
    String callsign,
    Map<String, String> headers,
  ) async {
    final queryParams = request.url.queryParameters;
    final deleteData = queryParams['deleteData'] == 'true';

    final backupService = BackupService();
    await backupService.removeClient(callsign, deleteData: deleteData);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'message': 'Client removed', 'dataDeleted': deleteData}),
      headers: headers,
    );
  }

  /// GET /api/backup/clients/{callsign}/snapshots - List snapshots
  Future<shelf.Response> _handleBackupSnapshotsGet(
    String callsign,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    final snapshots = await backupService.getSnapshots(callsign);

    return shelf.Response.ok(
      jsonEncode({
        'snapshots': snapshots.map((s) => s.toJson()).toList(),
        'total': snapshots.length,
      }),
      headers: headers,
    );
  }

  /// GET /api/backup/clients/{callsign}/snapshots/{date} - Get manifest
  Future<shelf.Response> _handleBackupManifestGet(
    String callsign,
    String snapshotId,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    final manifest = await backupService.getManifest(callsign, snapshotId);

    if (manifest == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Manifest not found', 'callsign': callsign, 'snapshotId': snapshotId}),
        headers: headers,
      );
    }

    // Return raw encrypted manifest (base64 encoded)
    return shelf.Response.ok(
      jsonEncode({'manifest': manifest}),
      headers: headers,
    );
  }

  /// PUT /api/backup/clients/{callsign}/snapshots/{date} - Upload manifest
  Future<shelf.Response> _handleBackupManifestPut(
    shelf.Request request,
    String callsign,
    String snapshotId,
    Map<String, String> headers,
  ) async {
    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final manifestBase64 = data['manifest'] as String?;

    if (manifestBase64 == null) {
      return shelf.Response.badRequest(
        body: jsonEncode({'error': 'Missing manifest field'}),
        headers: headers,
      );
    }

    final backupService = BackupService();
    // Decode base64 to bytes for storage
    final manifestBytes = Uint8List.fromList(base64Decode(manifestBase64));
    await backupService.saveManifest(callsign, snapshotId, manifestBytes);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'message': 'Manifest saved'}),
      headers: headers,
    );
  }

  /// GET /api/backup/clients/{callsign}/snapshots/{date}/files/{name} - Get encrypted file
  Future<shelf.Response> _handleBackupFileGet(
    String callsign,
    String snapshotId,
    String fileName,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    final fileData = await backupService.getEncryptedFile(callsign, snapshotId, fileName);

    if (fileData == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'File not found'}),
        headers: headers,
      );
    }

    // Return raw binary data
    return shelf.Response.ok(
      fileData,
      headers: {...headers, 'Content-Type': 'application/octet-stream'},
    );
  }

  /// PUT /api/backup/clients/{callsign}/snapshots/{date}/files/{name} - Upload encrypted file
  Future<shelf.Response> _handleBackupFilePut(
    shelf.Request request,
    String callsign,
    String snapshotId,
    String fileName,
    Map<String, String> headers,
  ) async {
    final bytes = await request.read().expand((chunk) => chunk).toList();
    final fileData = Uint8List.fromList(bytes);

    final backupService = BackupService();
    await backupService.saveEncryptedFile(callsign, snapshotId, fileName, fileData);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'message': 'File saved', 'size': fileData.length}),
      headers: headers,
    );
  }

  // === Client Provider Management Endpoints ===

  /// GET /api/backup/providers - List providers
  Future<shelf.Response> _handleBackupProvidersGet(Map<String, String> headers) async {
    final backupService = BackupService();
    final providers = await backupService.getProviders();

    return shelf.Response.ok(
      jsonEncode({
        'providers': providers.map((p) => p.toJson()).toList(),
        'total': providers.length,
      }),
      headers: headers,
    );
  }

  /// GET /api/backup/providers/{callsign} - Get specific provider
  Future<shelf.Response> _handleBackupProviderGet(
    String callsign,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    final providers = await backupService.getProviders();
    final provider = providers.where((p) => p.providerCallsign == callsign).firstOrNull;

    if (provider == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Provider not found', 'callsign': callsign}),
        headers: headers,
      );
    }

    return shelf.Response.ok(
      jsonEncode(provider.toJson()),
      headers: headers,
    );
  }

  /// POST /api/backup/providers/{callsign} - Send invite to provider
  Future<shelf.Response> _handleBackupProviderInvite(
    shelf.Request request,
    String callsign,
    Map<String, String> headers,
  ) async {
    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final intervalDays = data['intervalDays'] as int? ?? 1;

    final backupService = BackupService();
    await backupService.sendInvite(callsign, intervalDays);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'message': 'Invite sent to provider', 'callsign': callsign}),
      headers: headers,
    );
  }

  /// PUT /api/backup/providers/{callsign} - Update provider settings
  Future<shelf.Response> _handleBackupProviderUpdate(
    shelf.Request request,
    String callsign,
    Map<String, String> headers,
  ) async {
    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;

    final backupService = BackupService();
    final providers = await backupService.getProviders();
    final provider = providers.where((p) => p.providerCallsign == callsign).firstOrNull;

    if (provider == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Provider not found', 'callsign': callsign}),
        headers: headers,
      );
    }

    // Update provider settings (e.g., interval)
    if (data.containsKey('intervalDays')) {
      final newInterval = data['intervalDays'] as int;
      final updatedProvider = BackupProviderRelationship(
        providerNpub: provider.providerNpub,
        providerCallsign: provider.providerCallsign,
        backupIntervalDays: newInterval,
        status: provider.status,
        maxStorageBytes: provider.maxStorageBytes,
        maxSnapshots: provider.maxSnapshots,
        lastSuccessfulBackup: provider.lastSuccessfulBackup,
        nextScheduledBackup: provider.nextScheduledBackup,
        createdAt: provider.createdAt,
      );
      await backupService.updateProvider(updatedProvider);
    }

    return shelf.Response.ok(
      jsonEncode({'success': true, 'message': 'Provider updated'}),
      headers: headers,
    );
  }

  /// DELETE /api/backup/providers/{callsign} - Remove provider
  Future<shelf.Response> _handleBackupProviderRemove(
    String callsign,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    await backupService.removeProvider(callsign);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'message': 'Provider removed', 'callsign': callsign}),
      headers: headers,
    );
  }

  // === Backup/Restore Operations ===

  /// POST /api/backup/start - Start backup
  Future<shelf.Response> _handleBackupStart(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final providerCallsign = data['providerCallsign'] as String?;

    if (providerCallsign == null) {
      return shelf.Response.badRequest(
        body: jsonEncode({'error': 'Missing providerCallsign'}),
        headers: headers,
      );
    }

    final backupService = BackupService();
    final status = await backupService.startBackup(providerCallsign);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'status': status.toJson()}),
      headers: headers,
    );
  }

  /// GET /api/backup/status - Get current backup/restore status
  Future<shelf.Response> _handleBackupStatusGet(Map<String, String> headers) async {
    final backupService = BackupService();
    final status = backupService.backupStatus;

    return shelf.Response.ok(
      jsonEncode(status?.toJson() ?? {'status': 'idle'}),
      headers: headers,
    );
  }

  /// POST /api/backup/restore - Start restore
  Future<shelf.Response> _handleBackupRestore(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final providerCallsign = data['providerCallsign'] as String?;
    final snapshotId = data['snapshotId'] as String?;

    if (providerCallsign == null || snapshotId == null) {
      return shelf.Response.badRequest(
        body: jsonEncode({'error': 'Missing providerCallsign or snapshotId'}),
        headers: headers,
      );
    }

    final backupService = BackupService();
    await backupService.startRestore(providerCallsign, snapshotId);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'message': 'Restore started'}),
      headers: headers,
    );
  }

  // === Discovery Endpoints ===

  /// POST /api/backup/discover - Start discovery
  Future<shelf.Response> _handleBackupDiscoverStart(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    final body = await request.readAsString();
    final data = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
    final timeoutSeconds = data['timeoutSeconds'] as int? ?? 30;

    final backupService = BackupService();
    final discoveryId = await backupService.startDiscovery(timeoutSeconds);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'discoveryId': discoveryId}),
      headers: headers,
    );
  }

  /// GET /api/backup/discover/{id} - Get discovery status
  Future<shelf.Response> _handleBackupDiscoverStatus(
    String discoveryId,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    final status = backupService.getDiscoveryStatus(discoveryId);

    if (status == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Discovery not found', 'discoveryId': discoveryId}),
        headers: headers,
      );
    }

    return shelf.Response.ok(
      jsonEncode(status.toJson()),
      headers: headers,
    );
  }

  // ============================================================
  // Events API Endpoints (public read-only access)
  // ============================================================

  /// Main handler for all /api/events/* endpoints
  Future<shelf.Response> _handleEventsRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      String? dataDir;
      try {
        dataDir = StorageConfig().baseDir;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Storage not initialized'}),
          headers: headers,
        );
      }

      // Remove 'api/events' prefix for easier parsing
      String subPath = '';
      if (urlPath.startsWith('api/events/')) {
        subPath = urlPath.substring('api/events/'.length);
      } else if (urlPath == 'api/events' || urlPath == 'api/events/') {
        subPath = '';
      }

      // Remove trailing slash
      if (subPath.endsWith('/')) {
        subPath = subPath.substring(0, subPath.length - 1);
      }

      // GET /api/events - List all events
      if (subPath.isEmpty) {
        if (request.method != 'GET') {
          return shelf.Response(
            405,
            body: jsonEncode({'error': 'Method not allowed. Events API is read-only.'}),
            headers: headers,
          );
        }
        return await _handleEventsListEvents(request, dataDir, headers);
      }

      // Parse the sub-path to determine the operation
      final pathParts = subPath.split('/');

      if (pathParts.length >= 2 && pathParts[1] == 'media') {
        return await _handleEventMediaRequest(
          request,
          pathParts,
          dataDir,
          headers,
        );
      }

      if (request.method != 'GET') {
        return shelf.Response(
          405,
          body: jsonEncode({'error': 'Method not allowed. Events API is read-only.'}),
          headers: headers,
        );
      }

      if (pathParts.length == 1) {
        // GET /api/events/{eventId} - Get single event
        final eventId = pathParts[0];
        return await _handleEventsGetEvent(eventId, dataDir, headers);
      }

      if (pathParts.length == 2 && pathParts[1] == 'items') {
        // GET /api/events/{eventId}/items - List event files
        final eventId = pathParts[0];
        final itemPath = request.url.queryParameters['path'] ?? '';
        return await _handleEventsGetItems(eventId, itemPath, dataDir, headers);
      }

      if (pathParts.length >= 3 && pathParts[1] == 'files') {
        // GET /api/events/{eventId}/files/{path} - Get event file
        final eventId = pathParts[0];
        final filePath = pathParts.sublist(2).join('/');
        return await _handleEventsGetFile(eventId, filePath, dataDir, headers);
      }

      return shelf.Response.notFound(
        jsonEncode({'error': 'Events endpoint not found', 'path': urlPath}),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling events request: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// GET /api/events - List all events
  Future<shelf.Response> _handleEventsListEvents(
    shelf.Request request,
    String dataDir,
    Map<String, String> headers,
  ) async {
    final eventService = EventService();

    // Parse year filter from query parameters
    int? year;
    final yearParam = request.url.queryParameters['year'];
    if (yearParam != null) {
      year = int.tryParse(yearParam);
    }

    // Get all events
    final events = await eventService.getAllEventsGlobal(dataDir, year: year);

    // Get available years
    final years = await eventService.getAvailableYearsGlobal(dataDir);

    return shelf.Response.ok(
      jsonEncode({
        'events': events.map((e) => e.toApiJson(summary: true)).toList(),
        'years': years,
        'total': events.length,
      }),
      headers: headers,
    );
  }

  /// GET /api/events/{eventId} - Get single event details
  Future<shelf.Response> _handleEventsGetEvent(
    String eventId,
    String dataDir,
    Map<String, String> headers,
  ) async {
    final eventService = EventService();

    final event = await eventService.findEventByIdGlobal(eventId, dataDir);
    if (event == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Event not found', 'eventId': eventId}),
        headers: headers,
      );
    }

    return shelf.Response.ok(
      jsonEncode(event.toApiJson(summary: false)),
      headers: headers,
    );
  }

  /// GET /api/events/{eventId}/items - List event files and folders
  Future<shelf.Response> _handleEventsGetItems(
    String eventId,
    String itemPath,
    String dataDir,
    Map<String, String> headers,
  ) async {
    final eventService = EventService();

    // Get the event directory path
    final eventDirPath = await eventService.getEventPath(eventId, dataDir);
    if (eventDirPath == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Event not found', 'eventId': eventId}),
        headers: headers,
      );
    }

    // Build the full path
    String targetPath = eventDirPath;
    if (itemPath.isNotEmpty) {
      // Sanitize path to prevent directory traversal
      if (itemPath.contains('..')) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Invalid path'}),
          headers: headers,
        );
      }
      targetPath = '$eventDirPath/$itemPath';
    }

    final targetDir = io.Directory(targetPath);
    if (!await targetDir.exists()) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Path not found', 'path': itemPath}),
        headers: headers,
      );
    }

    final items = <Map<String, dynamic>>[];
    await for (var entity in targetDir.list()) {
      final name = path.basename(entity.path);

      // Skip hidden files and special files
      if (name.startsWith('.') || name == 'event.txt') {
        continue;
      }

      if (entity is io.Directory) {
        // Check if this is a day folder (dayX format)
        final isDayFolder = RegExp(r'^day\d+$', caseSensitive: false).hasMatch(name);
        final subItems = await entity.list().length;

        items.add({
          'name': name,
          'type': isDayFolder ? 'dayFolder' : 'folder',
          'item_count': subItems,
        });
      } else if (entity is io.File) {
        final stat = await entity.stat();
        final ext = path.extension(name).toLowerCase();

        // Determine file type
        String fileType = 'file';
        if (['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext)) {
          fileType = 'image';
        } else if (['.mp4', '.mov', '.avi', '.webm'].contains(ext)) {
          fileType = 'video';
        } else if (['.mp3', '.m4a', '.wav', '.ogg'].contains(ext)) {
          fileType = 'audio';
        } else if (['.pdf'].contains(ext)) {
          fileType = 'document';
        }

        items.add({
          'name': name,
          'type': fileType,
          'size': stat.size,
        });
      }
    }

    // Sort: folders first, then files alphabetically
    items.sort((a, b) {
      final aIsFolder = a['type'] == 'folder' || a['type'] == 'dayFolder';
      final bIsFolder = b['type'] == 'folder' || b['type'] == 'dayFolder';
      if (aIsFolder && !bIsFolder) return -1;
      if (!aIsFolder && bIsFolder) return 1;
      return (a['name'] as String).compareTo(b['name'] as String);
    });

    return shelf.Response.ok(
      jsonEncode({
        'event_id': eventId,
        'path': itemPath,
        'items': items,
      }),
      headers: headers,
    );
  }

  /// GET /api/events/{eventId}/files/{path} - Get event file content
  Future<shelf.Response> _handleEventsGetFile(
    String eventId,
    String filePath,
    String dataDir,
    Map<String, String> headers,
  ) async {
    final eventService = EventService();

    // Get the event directory path
    final eventDirPath = await eventService.getEventPath(eventId, dataDir);
    if (eventDirPath == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Event not found', 'eventId': eventId}),
        headers: headers,
      );
    }

    // Sanitize path to prevent directory traversal
    if (filePath.contains('..')) {
      return shelf.Response.forbidden(
        jsonEncode({'error': 'Invalid path'}),
        headers: headers,
      );
    }

    final fullPath = '$eventDirPath/$filePath';
    final file = io.File(fullPath);

    if (!await file.exists()) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'File not found', 'path': filePath}),
        headers: headers,
      );
    }

    // Determine MIME type
    final ext = path.extension(filePath).toLowerCase();
    String contentType = 'application/octet-stream';

    final mimeTypes = {
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
      '.mp4': 'video/mp4',
      '.mov': 'video/quicktime',
      '.avi': 'video/x-msvideo',
      '.webm': 'video/webm',
      '.mp3': 'audio/mpeg',
      '.m4a': 'audio/mp4',
      '.wav': 'audio/wav',
      '.ogg': 'audio/ogg',
      '.pdf': 'application/pdf',
      '.txt': 'text/plain',
      '.json': 'application/json',
      '.html': 'text/html',
      '.css': 'text/css',
      '.js': 'application/javascript',
    };

    if (mimeTypes.containsKey(ext)) {
      contentType = mimeTypes[ext]!;
    }

    // Read file bytes
    final bytes = await file.readAsBytes();

    // Return binary content with appropriate headers
    return shelf.Response.ok(
      bytes,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, OPTIONS',
        'Content-Type': contentType,
        'Content-Length': bytes.length.toString(),
        'Cache-Control': 'public, max-age=86400', // Cache for 1 day
      },
    );
  }

  // ============================================================
  // Event Community Media Endpoints
  // ============================================================

  Future<shelf.Response> _handleEventMediaRequest(
    shelf.Request request,
    List<String> pathParts,
    String dataDir,
    Map<String, String> headers,
  ) async {
    if (pathParts.length < 2) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Event media endpoint not found'}),
        headers: headers,
      );
    }

    final eventId = pathParts[0];

    if (pathParts.length == 2) {
      if (request.method != 'GET') {
        return shelf.Response(
          405,
          body: jsonEncode({'error': 'Method not allowed'}),
          headers: headers,
        );
      }
      return await _handleEventMediaList(request, eventId, dataDir, headers);
    }

    if (pathParts.length < 4) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Event media endpoint not found'}),
        headers: headers,
      );
    }

    final callsign = pathParts[2];

    if (pathParts.length >= 5 && pathParts[3] == 'files') {
      final filename = pathParts.sublist(4).join('/');
      if (request.method == 'POST') {
        return await _handleEventMediaFileUpload(
          request,
          eventId,
          callsign,
          filename,
          dataDir,
          headers,
        );
      }
      if (request.method == 'GET') {
        return await _handleEventMediaFileServe(
          eventId,
          callsign,
          filename,
          dataDir,
          headers,
        );
      }
      return shelf.Response(
        405,
        body: jsonEncode({'error': 'Method not allowed'}),
        headers: headers,
      );
    }

    if (pathParts.length == 4) {
      if (request.method != 'POST') {
        return shelf.Response(
          405,
          body: jsonEncode({'error': 'Method not allowed'}),
          headers: headers,
        );
      }
      final action = pathParts[3];
      return await _handleEventMediaAction(
        eventId,
        callsign,
        action,
        dataDir,
        headers,
      );
    }

    return shelf.Response.notFound(
      jsonEncode({'error': 'Event media endpoint not found'}),
      headers: headers,
    );
  }

  Future<shelf.Response> _handleEventMediaList(
    shelf.Request request,
    String eventId,
    String dataDir,
    Map<String, String> headers,
  ) async {
    try {
      final eventService = EventService();
      final eventDirPath = await eventService.getEventPath(eventId, dataDir);
      if (eventDirPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found', 'eventId': eventId}),
          headers: headers,
        );
      }

      final event = await eventService.findEventByIdGlobal(eventId, dataDir);
      if (event == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found', 'eventId': eventId}),
          headers: headers,
        );
      }

      if (event.visibility.toLowerCase() != 'public') {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Event not public'}),
          headers: headers,
        );
      }

      final includePending = request.url.queryParameters['include_pending'] == 'true';
      final includeBanned = request.url.queryParameters['include_banned'] == 'true';

      final mediaRoot = io.Directory(path.join(eventDirPath, 'media'));
      final approvedFile = path.join(mediaRoot.path, 'approved.txt');
      final bannedFile = path.join(mediaRoot.path, 'banned.txt');
      final approved = await _readCallsignList(approvedFile);
      final banned = await _readCallsignList(bannedFile);

      final contributors = <Map<String, dynamic>>[];
      if (await mediaRoot.exists()) {
        await for (final entity in mediaRoot.list()) {
          if (entity is! io.Directory) continue;
          final callsign = path.basename(entity.path);
          if (callsign.isEmpty) continue;

          final files = <Map<String, dynamic>>[];
          await for (final entry in entity.list()) {
            if (entry is! io.File) continue;
            final name = path.basename(entry.path);
            if (name.startsWith('.')) continue;
            final stat = await entry.stat();
            final ext = path.extension(name).toLowerCase();
            String fileType = 'file';
            if (['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'].contains(ext)) {
              fileType = 'image';
            } else if (['.mp4', '.mov', '.avi', '.webm'].contains(ext)) {
              fileType = 'video';
            } else if (['.mp3', '.m4a', '.wav', '.ogg'].contains(ext)) {
              fileType = 'audio';
            } else if (['.pdf'].contains(ext)) {
              fileType = 'document';
            }
            files.add({
              'name': name,
              'type': fileType,
              'size': stat.size,
              'path': '/api/events/$eventId/media/$callsign/files/$name',
            });
          }

          if (files.isEmpty) continue;
          files.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

          final isApproved = approved.contains(callsign);
          final isBanned = banned.contains(callsign);

          if (!includePending) {
            if (!isApproved || isBanned) continue;
          } else if (!includeBanned && isBanned) {
            continue;
          }

          contributors.add({
            'callsign': callsign,
            'is_approved': isApproved,
            'is_banned': isBanned,
            'files': files,
          });
        }
      }

      contributors.sort((a, b) => (a['callsign'] as String).compareTo(b['callsign'] as String));

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'event_id': eventId,
          'contributors': contributors,
          'approved': approved.toList()..sort(),
          'banned': banned.toList()..sort(),
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error listing event media: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Internal server error', 'message': e.toString()}),
        headers: headers,
      );
    }
  }

  Future<shelf.Response> _handleEventMediaFileUpload(
    shelf.Request request,
    String eventId,
    String callsign,
    String filename,
    String dataDir,
    Map<String, String> headers,
  ) async {
    try {
      final eventService = EventService();
      final eventDirPath = await eventService.getEventPath(eventId, dataDir);
      if (eventDirPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found', 'eventId': eventId}),
          headers: headers,
        );
      }

      final event = await eventService.findEventByIdGlobal(eventId, dataDir);
      if (event == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found', 'eventId': eventId}),
          headers: headers,
        );
      }

      if (event.visibility.toLowerCase() != 'public') {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Event not public'}),
          headers: headers,
        );
      }

      final sanitizedCallsign = _sanitizeMediaCallsign(callsign);
      if (sanitizedCallsign.isEmpty) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Invalid callsign'}),
          headers: headers,
        );
      }

      if (_isInvalidMediaFilename(filename)) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Invalid filename'}),
          headers: headers,
        );
      }

      var bytes = await request.read().expand((chunk) => chunk).toList();
      final transferEncoding = request.headers['Content-Transfer-Encoding'] ??
          request.headers['content-transfer-encoding'];
      if (transferEncoding != null && transferEncoding.toLowerCase().contains('base64')) {
        try {
          bytes = base64Decode(utf8.decode(bytes));
        } catch (e) {
          return shelf.Response(
            400,
            body: jsonEncode({'error': 'Invalid base64 payload'}),
            headers: headers,
          );
        }
      }

      if (bytes.isEmpty) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Empty file'}),
          headers: headers,
        );
      }

      const maxSizeBytes = 25 * 1024 * 1024;
      if (bytes.length > maxSizeBytes) {
        return shelf.Response(
          413,
          body: jsonEncode({'error': 'File too large', 'max_size_mb': 25}),
          headers: headers,
        );
      }

      final mediaRoot = io.Directory(path.join(eventDirPath, 'media'));
      final bannedFile = path.join(mediaRoot.path, 'banned.txt');
      final banned = await _readCallsignList(bannedFile);
      if (banned.contains(sanitizedCallsign)) {
        return shelf.Response(
          403,
          body: jsonEncode({'error': 'Contributor banned'}),
          headers: headers,
        );
      }

      final contributorDir = io.Directory(path.join(mediaRoot.path, sanitizedCallsign));
      await contributorDir.create(recursive: true);

      final nextIndex = await _nextMediaIndex(contributorDir);
      final ext = _normalizeMediaExtension(filename);
      final targetName = 'media$nextIndex.$ext';
      final filePath = path.join(contributorDir.path, targetName);
      final file = io.File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      return shelf.Response(
        201,
        body: jsonEncode({
          'success': true,
          'callsign': sanitizedCallsign,
          'filename': targetName,
          'size': bytes.length,
          'path': '/api/events/$eventId/media/$sanitizedCallsign/files/$targetName',
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error uploading event media: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Internal server error', 'message': e.toString()}),
        headers: headers,
      );
    }
  }

  Future<shelf.Response> _handleEventMediaFileServe(
    String eventId,
    String callsign,
    String filename,
    String dataDir,
    Map<String, String> headers,
  ) async {
    try {
      final eventService = EventService();
      final eventDirPath = await eventService.getEventPath(eventId, dataDir);
      if (eventDirPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found', 'eventId': eventId}),
          headers: headers,
        );
      }

      final event = await eventService.findEventByIdGlobal(eventId, dataDir);
      if (event == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found', 'eventId': eventId}),
          headers: headers,
        );
      }

      if (event.visibility.toLowerCase() != 'public') {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Event not public'}),
          headers: headers,
        );
      }

      final sanitizedCallsign = _sanitizeMediaCallsign(callsign);
      if (sanitizedCallsign.isEmpty || _isInvalidMediaFilename(filename)) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Invalid path'}),
          headers: headers,
        );
      }

      final filePath = path.join(eventDirPath, 'media', sanitizedCallsign, filename);
      final file = io.File(filePath);
      if (!await file.exists()) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'File not found', 'filename': filename}),
          headers: headers,
        );
      }

      final ext = path.extension(filename).toLowerCase();
      String contentType = 'application/octet-stream';
      if (ext == '.jpg' || ext == '.jpeg') {
        contentType = 'image/jpeg';
      } else if (ext == '.png') {
        contentType = 'image/png';
      } else if (ext == '.gif') {
        contentType = 'image/gif';
      } else if (ext == '.webp') {
        contentType = 'image/webp';
      } else if (ext == '.bmp') {
        contentType = 'image/bmp';
      } else if (ext == '.mp4') {
        contentType = 'video/mp4';
      } else if (ext == '.mov') {
        contentType = 'video/quicktime';
      } else if (ext == '.avi') {
        contentType = 'video/x-msvideo';
      } else if (ext == '.webm') {
        contentType = 'video/webm';
      } else if (ext == '.mp3') {
        contentType = 'audio/mpeg';
      } else if (ext == '.m4a') {
        contentType = 'audio/mp4';
      } else if (ext == '.wav') {
        contentType = 'audio/wav';
      } else if (ext == '.ogg') {
        contentType = 'audio/ogg';
      }

      final bytes = await file.readAsBytes();
      return shelf.Response.ok(
        bytes,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, OPTIONS',
          'Content-Type': contentType,
          'Content-Length': bytes.length.toString(),
          'Cache-Control': 'public, max-age=86400',
        },
      );
    } catch (e) {
      LogService().log('LogApiService: Error serving event media: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Internal server error', 'message': e.toString()}),
        headers: headers,
      );
    }
  }

  Future<shelf.Response> _handleEventMediaAction(
    String eventId,
    String callsign,
    String action,
    String dataDir,
    Map<String, String> headers,
  ) async {
    try {
      final eventService = EventService();
      final eventDirPath = await eventService.getEventPath(eventId, dataDir);
      if (eventDirPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found', 'eventId': eventId}),
          headers: headers,
        );
      }

      final event = await eventService.findEventByIdGlobal(eventId, dataDir);
      if (event == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found', 'eventId': eventId}),
          headers: headers,
        );
      }

      if (event.visibility.toLowerCase() != 'public') {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Event not public'}),
          headers: headers,
        );
      }

      final sanitizedCallsign = _sanitizeMediaCallsign(callsign);
      if (sanitizedCallsign.isEmpty) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Invalid callsign'}),
          headers: headers,
        );
      }

      final mediaRoot = io.Directory(path.join(eventDirPath, 'media'));
      final approvedFile = path.join(mediaRoot.path, 'approved.txt');
      final bannedFile = path.join(mediaRoot.path, 'banned.txt');

      final approved = await _readCallsignList(approvedFile);
      final banned = await _readCallsignList(bannedFile);

      switch (action) {
        case 'approve':
          approved.add(sanitizedCallsign);
          banned.remove(sanitizedCallsign);
          await _writeCallsignList(approvedFile, approved);
          await _writeCallsignList(bannedFile, banned);
          break;
        case 'suspend':
          approved.remove(sanitizedCallsign);
          await _writeCallsignList(approvedFile, approved);
          break;
        case 'ban':
          approved.remove(sanitizedCallsign);
          banned.add(sanitizedCallsign);
          await _writeCallsignList(approvedFile, approved);
          await _writeCallsignList(bannedFile, banned);
          final contributorDir = io.Directory(path.join(mediaRoot.path, sanitizedCallsign));
          if (await contributorDir.exists()) {
            await contributorDir.delete(recursive: true);
          }
          break;
        default:
          return shelf.Response(
            400,
            body: jsonEncode({'error': 'Invalid action'}),
            headers: headers,
          );
      }

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'action': action,
          'callsign': sanitizedCallsign,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error updating event media status: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Internal server error', 'message': e.toString()}),
        headers: headers,
      );
    }
  }

  Future<Set<String>> _readCallsignList(String filePath) async {
    final file = io.File(filePath);
    if (!await file.exists()) return <String>{};
    final content = await file.readAsString();
    return content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toSet();
  }

  Future<void> _writeCallsignList(String filePath, Set<String> values) async {
    final file = io.File(filePath);
    await file.parent.create(recursive: true);
    final sorted = values.toList()..sort();
    await file.writeAsString(sorted.join('\n'), flush: true);
  }

  String _sanitizeMediaCallsign(String callsign) {
    return callsign
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  bool _isInvalidMediaFilename(String filename) {
    if (filename.isEmpty) return true;
    if (filename.contains('..')) return true;
    if (filename.contains('/') || filename.contains('\\')) return true;
    return false;
  }

  String _normalizeMediaExtension(String filename) {
    var ext = path.extension(filename).toLowerCase();
    if (ext.startsWith('.')) ext = ext.substring(1);
    if (ext.isEmpty) ext = 'bin';
    if (ext.length > 8) {
      ext = ext.substring(0, 8);
    }
    return ext;
  }

  Future<int> _nextMediaIndex(io.Directory contributorDir) async {
    int maxIndex = 0;
    if (await contributorDir.exists()) {
      await for (final entry in contributorDir.list()) {
        if (entry is! io.File) continue;
        final name = path.basename(entry.path);
        final match = RegExp(r'^media(\\d+)\\.', caseSensitive: false).firstMatch(name);
        if (match == null) continue;
        final parsed = int.tryParse(match.group(1) ?? '');
        if (parsed != null && parsed > maxIndex) {
          maxIndex = parsed;
        }
      }
    }
    return maxIndex + 1;
  }

  // ============================================================
  // Alerts API Endpoints (public read-only access)
  // ============================================================

  /// Main handler for all /api/alerts/* endpoints
  Future<shelf.Response> _handleAlertsRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      late final String dataDir;
      try {
        dataDir = StorageConfig().baseDir;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Storage not initialized'}),
          headers: headers,
        );
      }

      // Remove 'api/alerts' prefix for easier parsing
      String subPath = '';
      if (urlPath.startsWith('api/alerts/')) {
        subPath = urlPath.substring('api/alerts/'.length);
      } else if (urlPath == 'api/alerts' || urlPath == 'api/alerts/') {
        subPath = '';
      }

      // Remove trailing slash
      if (subPath.endsWith('/')) {
        subPath = subPath.substring(0, subPath.length - 1);
      }

      // Parse the sub-path to determine the operation
      final pathParts = subPath.split('/');

      // Handle POST methods for feedback
      if (request.method == 'POST') {
        if (pathParts.length == 2) {
          final alertId = pathParts[0];
          final action = pathParts[1];

          switch (action) {
            case 'point':
              return await _handleAlertsPoint(request, alertId, dataDir, headers);
            case 'unpoint':
              return await _handleAlertsUnpoint(request, alertId, dataDir, headers);
            case 'verify':
              return await _handleAlertsVerify(request, alertId, dataDir, headers);
            case 'comment':
              return await _handleAlertsComment(request, alertId, dataDir, headers);
          }
        }
        return shelf.Response(
          405,
          body: jsonEncode({'error': 'Method not allowed for this endpoint'}),
          headers: headers,
        );
      }

      // Handle GET methods
      if (request.method != 'GET') {
        return shelf.Response(
          405,
          body: jsonEncode({'error': 'Method not allowed'}),
          headers: headers,
        );
      }

      // GET /api/alerts - List all alerts
      if (subPath.isEmpty) {
        return await _handleAlertsListAlerts(request, dataDir, headers);
      }

      if (pathParts.length == 1) {
        // GET /api/alerts/{alertId} - Get single alert
        final alertId = pathParts[0];
        return await _handleAlertsGetAlert(alertId, dataDir, headers);
      }

      if (pathParts.length >= 3 && pathParts[1] == 'files') {
        // GET /api/alerts/{alertId}/files/{path} - Get alert file
        final alertId = pathParts[0];
        final filePath = pathParts.sublist(2).join('/');
        return await _handleAlertsGetFile(alertId, filePath, dataDir, headers);
      }

      return shelf.Response.notFound(
        jsonEncode({'error': 'Alerts endpoint not found', 'path': urlPath}),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling alerts request: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// GET /api/alerts - List all alerts
  Future<shelf.Response> _handleAlertsListAlerts(
    shelf.Request request,
    String dataDir,
    Map<String, String> headers,
  ) async {
    // Parse query parameters
    final statusParam = request.url.queryParameters['status'];
    final latParam = request.url.queryParameters['lat'];
    final lonParam = request.url.queryParameters['lon'];
    final radiusParam = request.url.queryParameters['radius'];

    double? lat = latParam != null ? double.tryParse(latParam) : null;
    double? lon = lonParam != null ? double.tryParse(lonParam) : null;
    double? radius = radiusParam != null ? double.tryParse(radiusParam) : null;

    // Get all alerts with filters
    final alertsWithPaths = await _getAllAlertsGlobal(
      dataDir,
      status: statusParam,
      lat: lat,
      lon: lon,
      radius: radius,
    );

    // Build response
    final alertsJson = <Map<String, dynamic>>[];
    for (final tuple in alertsWithPaths) {
      final alert = tuple.$1;
      final alertPath = tuple.$2;

      // Check if alert has photos
      final hasPhotos = await _alertHasPhotos(alertPath);

      alertsJson.add(alert.toApiJson(summary: true, hasPhotos: hasPhotos));
    }

    return shelf.Response.ok(
      jsonEncode({
        'alerts': alertsJson,
        'total': alertsJson.length,
        'filters': {
          if (statusParam != null) 'status': statusParam,
          if (lat != null) 'lat': lat,
          if (lon != null) 'lon': lon,
          if (radius != null) 'radius_km': radius,
        },
      }),
      headers: headers,
    );
  }

  /// GET /api/alerts/{alertId} - Get single alert details
  Future<shelf.Response> _handleAlertsGetAlert(
    String alertId,
    String dataDir,
    Map<String, String> headers,
  ) async {
    final result = await _getAlertByApiId(alertId, dataDir);
    if (result == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Alert not found', 'alertId': alertId}),
        headers: headers,
      );
    }

    final alert = result.$1;
    final alertPath = result.$2;

    // Get list of photos
    final photos = await _getAlertPhotos(alertPath);

    // Build full response with photos list
    final json = alert.toApiJson(summary: false, hasPhotos: photos.isNotEmpty);
    json['photos'] = photos;

    return shelf.Response.ok(
      jsonEncode(json),
      headers: headers,
    );
  }

  /// GET /api/alerts/{alertId}/files/{path} - Get alert file content
  Future<shelf.Response> _handleAlertsGetFile(
    String alertId,
    String filePath,
    String dataDir,
    Map<String, String> headers,
  ) async {
    final result = await _getAlertByApiId(alertId, dataDir);
    if (result == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Alert not found', 'alertId': alertId}),
        headers: headers,
      );
    }

    final alertPath = result.$2;

    // Sanitize path to prevent directory traversal
    if (filePath.contains('..')) {
      return shelf.Response.forbidden(
        jsonEncode({'error': 'Invalid path'}),
        headers: headers,
      );
    }

    final fullPath = '$alertPath/$filePath';
    final file = io.File(fullPath);

    if (!await file.exists()) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'File not found', 'path': filePath}),
        headers: headers,
      );
    }

    // Determine MIME type
    final ext = path.extension(filePath).toLowerCase();
    String contentType = 'application/octet-stream';

    final mimeTypes = {
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
      '.mp4': 'video/mp4',
      '.mov': 'video/quicktime',
      '.mp3': 'audio/mpeg',
      '.m4a': 'audio/mp4',
      '.wav': 'audio/wav',
    };

    if (mimeTypes.containsKey(ext)) {
      contentType = mimeTypes[ext]!;
    }

    // Read file bytes
    final bytes = await file.readAsBytes();

    // Return binary content with appropriate headers
    return shelf.Response.ok(
      bytes,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, OPTIONS',
        'Content-Type': contentType,
        'Content-Length': bytes.length.toString(),
        'Cache-Control': 'public, max-age=86400', // Cache for 1 day
      },
    );
  }

  /// POST /api/alerts/{alertId}/point - Point an alert (call attention to it)
  Future<shelf.Response> _handleAlertsPoint(
    shelf.Request request,
    String alertId,
    String dataDir,
    Map<String, String> headers,
  ) async {
    return shelf.Response(
      410,
      body: jsonEncode({
        'error': 'Legacy alert feedback endpoint is deprecated',
        'message': 'Use /api/feedback/alert/{alertId}/point',
      }),
      headers: headers,
    );
  }

  /// POST /api/alerts/{alertId}/unpoint - Unpoint an alert (remove attention call)
  Future<shelf.Response> _handleAlertsUnpoint(
    shelf.Request request,
    String alertId,
    String dataDir,
    Map<String, String> headers,
  ) async {
    return shelf.Response(
      410,
      body: jsonEncode({
        'error': 'Legacy alert feedback endpoint is deprecated',
        'message': 'Use /api/feedback/alert/{alertId}/point',
      }),
      headers: headers,
    );
  }

  /// POST /api/alerts/{alertId}/verify - Verify an alert
  Future<shelf.Response> _handleAlertsVerify(
    shelf.Request request,
    String alertId,
    String dataDir,
    Map<String, String> headers,
  ) async {
    return shelf.Response(
      410,
      body: jsonEncode({
        'error': 'Legacy alert feedback endpoint is deprecated',
        'message': 'Use /api/feedback/alert/{alertId}/verify',
      }),
      headers: headers,
    );
  }

  /// POST /api/alerts/{alertId}/comment - Add a comment to an alert
  Future<shelf.Response> _handleAlertsComment(
    shelf.Request request,
    String alertId,
    String dataDir,
    Map<String, String> headers,
  ) async {
    return shelf.Response(
      410,
      body: jsonEncode({
        'error': 'Legacy alert feedback endpoint is deprecated',
        'message': 'Use /api/feedback/alert/{alertId}/comment',
      }),
      headers: headers,
    );
  }

  /// Get all alerts from devices directory
  /// Returns list of (alert, folderPath) tuples for mapping API ID to folder
  Future<List<(Report, String)>> _getAllAlertsGlobal(
    String dataDir, {
    String? status,
    double? lat,
    double? lon,
    double? radius,
  }) async {
    final alerts = <(Report, String)>[];
    final devicesDir = io.Directory('$dataDir/devices');

    io.stderr.writeln('DEBUG _getAllAlertsGlobal: dataDir=$dataDir, devicesDir=${devicesDir.path}');

    if (!await devicesDir.exists()) {
      io.stderr.writeln('DEBUG _getAllAlertsGlobal: devicesDir does not exist!');
      return alerts;
    }

    // Scan all devices/{callsign}/alerts/
    await for (final deviceEntity in devicesDir.list()) {
      if (deviceEntity is! io.Directory) continue;

      io.stderr.writeln('DEBUG _getAllAlertsGlobal: Checking device ${deviceEntity.path}');

      final alertsDir = io.Directory('${deviceEntity.path}/alerts');
      if (!await alertsDir.exists()) {
        io.stderr.writeln('DEBUG _getAllAlertsGlobal: No alerts dir at ${alertsDir.path}');
        continue;
      }

      io.stderr.writeln('DEBUG _getAllAlertsGlobal: Scanning alerts at ${alertsDir.path}');

      // Search recursively through alerts directory (handles both flat and nested structures)
      await _collectAlertsRecursively(alertsDir, alerts, status: status, lat: lat, lon: lon, radius: radius);
    }

    io.stderr.writeln('DEBUG _getAllAlertsGlobal: Found ${alerts.length} total alerts');

    // Sort by date (newest first)
    alerts.sort((a, b) => b.$1.dateTime.compareTo(a.$1.dateTime));
    return alerts;
  }

  /// Helper to recursively collect all alerts from a directory
  Future<void> _collectAlertsRecursively(
    io.Directory dir,
    List<(Report, String)> alerts, {
    String? status,
    double? lat,
    double? lon,
    double? radius,
  }) async {
    io.stderr.writeln('DEBUG _collectAlertsRecursively: Scanning ${dir.path}');

    await for (final entity in dir.list()) {
      if (entity is! io.Directory) continue;

      io.stderr.writeln('DEBUG _collectAlertsRecursively: Found dir ${entity.path}');

      // Check if this directory contains a report.txt
      final alertFile = io.File('${entity.path}/report.txt');
      if (await alertFile.exists()) {
        io.stderr.writeln('DEBUG _collectAlertsRecursively: Found report.txt at ${alertFile.path}');
        try {
          final content = await alertFile.readAsString();
          io.stderr.writeln('DEBUG _collectAlertsRecursively: Content length=${content.length}, first 200 chars: ${content.substring(0, content.length > 200 ? 200 : content.length).replaceAll('\n', '\\n')}');
          final alert = Report.fromText(content, entity.path.split('/').last);
          io.stderr.writeln('DEBUG _collectAlertsRecursively: Parsed alert apiId=${alert.apiId}');

          // Apply status filter
          if (status != null && alert.status.toFileString() != status) continue;

          // Apply geographic filter
          if (lat != null && lon != null && radius != null) {
            final distance = _calculateHaversineDistance(
              lat, lon, alert.latitude, alert.longitude,
            );
            if (distance > radius) continue;
          }

          alerts.add((alert, entity.path));
        } catch (e, stack) {
          // Skip malformed alerts
          io.stderr.writeln('DEBUG _collectAlertsRecursively: ERROR parsing ${entity.path}: $e');
          io.stderr.writeln('DEBUG Stack: $stack');
        }
      } else {
        // No report.txt, recurse into subdirectory (e.g., active/, region folders)
        await _collectAlertsRecursively(entity, alerts, status: status, lat: lat, lon: lon, radius: radius);
      }
    }
  }

  /// Find alert by API ID (YYYY-MM-DD_title-slug)
  /// Scans all alerts and matches by apiId since folder names use different format
  Future<(Report, String)?> _getAlertByApiId(String apiId, String dataDir) async {
    final devicesDir = io.Directory('$dataDir/devices');
    if (!await devicesDir.exists()) return null;

    await for (final deviceEntity in devicesDir.list()) {
      if (deviceEntity is! io.Directory) continue;

      final alertsDir = io.Directory('${deviceEntity.path}/alerts');
      if (!await alertsDir.exists()) continue;

      // Search recursively through alerts directory (handles both flat and nested structures)
      final result = await _searchAlertsRecursively(alertsDir, apiId);
      if (result != null) return result;
    }
    return null;
  }

  /// Helper to recursively search for an alert by apiId
  Future<(Report, String)?> _searchAlertsRecursively(io.Directory dir, String apiId) async {
    await for (final entity in dir.list()) {
      if (entity is! io.Directory) continue;

      // Check if this directory contains a report.txt
      final alertFile = io.File('${entity.path}/report.txt');
      if (await alertFile.exists()) {
        try {
          final content = await alertFile.readAsString();
          final alert = Report.fromText(content, entity.path.split('/').last);

          // Check if this alert's apiId matches
          if (alert.apiId == apiId) {
            return (alert, entity.path);
          }
        } catch (e) {
          // Skip malformed alerts
        }
      } else {
        // No report.txt, recurse into subdirectory (e.g., active/, region folders)
        final result = await _searchAlertsRecursively(entity, apiId);
        if (result != null) return result;
      }
    }
    return null;
  }

  /// Check if an alert has photos (checks both root and images/ subfolder)
  Future<bool> _alertHasPhotos(String alertPath) async {
    final photoExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];

    // Check images/ subfolder first (new structure)
    final imagesDir = io.Directory('$alertPath/images');
    if (await imagesDir.exists()) {
      await for (final entity in imagesDir.list()) {
        if (entity is io.File) {
          final ext = path.extension(entity.path).toLowerCase();
          if (photoExtensions.contains(ext)) {
            return true;
          }
        }
      }
    }

    // Also check root folder for backwards compatibility
    final dir = io.Directory(alertPath);
    if (!await dir.exists()) return false;

    await for (final entity in dir.list()) {
      if (entity is io.File) {
        final ext = path.extension(entity.path).toLowerCase();
        if (photoExtensions.contains(ext)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Get list of photo filenames in an alert directory (checks both root and images/ subfolder)
  /// Returns filenames prefixed with 'images/' for photos in the images subfolder
  Future<List<String>> _getAlertPhotos(String alertPath) async {
    final photos = <String>[];
    final photoExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];

    // Check images/ subfolder first (new structure)
    final imagesDir = io.Directory('$alertPath/images');
    if (await imagesDir.exists()) {
      await for (final entity in imagesDir.list()) {
        if (entity is io.File) {
          final ext = path.extension(entity.path).toLowerCase();
          if (photoExtensions.contains(ext)) {
            photos.add('images/${path.basename(entity.path)}');
          }
        }
      }
    }

    // Also check root folder for backwards compatibility
    final dir = io.Directory(alertPath);
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is io.File) {
          final ext = path.extension(entity.path).toLowerCase();
          if (photoExtensions.contains(ext)) {
            photos.add(path.basename(entity.path));
          }
        }
      }
    }

    photos.sort();
    return photos;
  }

  /// Get the next sequential photo number in an alert's images folder
  Future<int> _getNextPhotoNumber(String alertPath) async {
    int maxNumber = 0;
    final imagesDir = io.Directory('$alertPath/images');
    if (await imagesDir.exists()) {
      await for (final entity in imagesDir.list()) {
        if (entity is io.File) {
          final filename = path.basenameWithoutExtension(entity.path);
          final match = RegExp(r'^photo(\d+)$').firstMatch(filename);
          if (match != null) {
            final num = int.tryParse(match.group(1)!) ?? 0;
            if (num > maxNumber) maxNumber = num;
          }
        }
      }
    }
    return maxNumber + 1;
  }

  /// Calculate haversine distance between two points in kilometers
  double _calculateHaversineDistance(
    double lat1, double lon1,
    double lat2, double lon2,
  ) {
    const double earthRadius = 6371; // km
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) * cos(_toRadians(lat2)) *
        sin(dLon / 2) * sin(dLon / 2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  double _toRadians(double degrees) => degrees * pi / 180;

  // ============================================================
  // Debug API - Event Actions (for testing Events API)
  // ============================================================

  /// Handle event debug actions asynchronously
  Future<shelf.Response> _handleEventAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      // Get data directory from storage config
      String? dataDir;
      try {
        dataDir = StorageConfig().baseDir;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({
            'success': false,
            'error': 'Storage not initialized',
          }),
          headers: headers,
        );
      }

      switch (action) {
        case 'event_create':
          // Create a test event
          final title = params['title'] as String? ?? 'Test Event ${DateTime.now().millisecondsSinceEpoch}';
          final content = params['content'] as String? ?? 'This is a test event created via debug API.';
          final location = params['location'] as String? ?? 'online';
          final locationName = params['location_name'] as String?;
          final appName = params['app_name'] as String? ?? 'my-events';

          // Get callsign from profile service
          String callsign = 'TEST';
          try {
            final profile = ProfileService().getProfile();
            callsign = profile.callsign;
          } catch (e) {
            // Profile service not initialized, use TEST callsign
          }

          // Initialize EventService for this app
          final eventService = EventService();
          final collectionPath = '$dataDir/devices/$callsign/$appName';

          // Initialize the events directory
          await eventService.initializeCollection(collectionPath);

          // Create the event
          final event = await eventService.createEvent(
            author: callsign,
            title: title,
            location: location,
            locationName: locationName,
            content: content,
          );

          if (event == null) {
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': 'Failed to create event',
              }),
              headers: headers,
            );
          }

          LogService().log('LogApiService: Created test event: ${event.id}');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Event created',
              'event': event.toApiJson(),
            }),
            headers: headers,
          );

        case 'event_list':
          // List all events via the public API helper
          final year = params['year'] as int?;
          final events = await EventService().getAllEventsGlobal(dataDir, year: year);
          final years = await EventService().getAvailableYearsGlobal(dataDir);

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'events': events.map((e) => e.toApiJson(summary: true)).toList(),
              'years': years,
              'total': events.length,
            }),
            headers: headers,
          );

        case 'event_delete':
          // Delete an event by ID
          final eventId = params['event_id'] as String?;
          if (eventId == null || eventId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing event_id parameter',
              }),
              headers: headers,
            );
          }

          // Find the event to get its path
          final eventPath = await EventService().getEventPath(eventId, dataDir);
          if (eventPath == null) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Event not found',
                'event_id': eventId,
              }),
              headers: headers,
            );
          }

          // Delete the event directory
          final eventDir = io.Directory(eventPath);
          if (await eventDir.exists()) {
            await eventDir.delete(recursive: true);
            LogService().log('LogApiService: Deleted event: $eventId');

            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'message': 'Event deleted',
                'event_id': eventId,
              }),
              headers: headers,
            );
          }

          return shelf.Response.notFound(
            jsonEncode({
              'success': false,
              'error': 'Event directory not found',
              'event_id': eventId,
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown event action: $action',
              'available': ['event_create', 'event_list', 'event_delete'],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Event action error: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Debug API - Blog Actions (for testing Blog API)
  // ============================================================

  /// Handle blog debug actions asynchronously
  Future<shelf.Response> _handleBlogAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      // Get data directory from storage config
      String? dataDir;
      try {
        dataDir = StorageConfig().baseDir;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({
            'success': false,
            'error': 'Storage not initialized',
          }),
          headers: headers,
        );
      }

      // Get callsign and nickname from profile service
      String callsign = 'TEST';
      String nickname = 'TEST';
      String? npub;
      try {
        final profile = ProfileService().getProfile();
        callsign = profile.callsign;
        nickname = profile.nickname ?? profile.callsign;
        npub = profile.npub;
      } catch (e) {
        // Profile service not initialized, use TEST callsign
      }

      switch (action) {
        case 'blog_create':
          // Create a test blog post
          final title = params['title'] as String? ?? 'Test Blog Post ${DateTime.now().millisecondsSinceEpoch}';
          final content = params['content'] as String? ?? 'This is a test blog post created via debug API.';
          final description = params['description'] as String?;
          final tagsStr = params['tags'] as String?;
          final tags = tagsStr != null ? tagsStr.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList() : <String>[];
          final statusStr = params['status'] as String? ?? 'published';
          final status = statusStr == 'draft' ? BlogStatus.draft : BlogStatus.published;
          final appName = params['app_name'] as String? ?? 'blog';

          // Initialize BlogService for this app
          final blogService = BlogService();
          final collectionPath = '$dataDir/devices/$callsign/$appName';

          // Initialize the blog directory
          await blogService.initializeCollection(collectionPath, creatorNpub: npub);

          // Create the blog post
          final post = await blogService.createPost(
            author: callsign,
            title: title,
            description: description,
            content: content,
            tags: tags,
            status: status,
            npub: npub,
          );

          if (post == null) {
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': 'Failed to create blog post',
              }),
              headers: headers,
            );
          }

          // Generate p2p.radio URL
          final url = 'https://p2p.radio/${nickname.toLowerCase()}/blog/${post.id}.html';

          LogService().log('LogApiService: Created test blog post: ${post.id}');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Blog post created',
              'blog_id': post.id,
              'filename': '${post.id}.md',
              'url': url,
              'blog': {
                'id': post.id,
                'title': post.title,
                'author': post.author,
                'description': post.description,
                'status': post.isPublished ? 'published' : 'draft',
                'tags': post.tags,
                'timestamp': post.timestamp,
              },
            }),
            headers: headers,
          );

        case 'blog_list':
          // List all blog posts
          final year = params['year'] as int?;
          final appName = params['app_name'] as String? ?? 'blog';

          final blogService = BlogService();
          final collectionPath = '$dataDir/devices/$callsign/$appName';

          // Check if blog directory exists
          final blogDir = io.Directory(collectionPath);
          if (!await blogDir.exists()) {
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'blogs': [],
                'total': 0,
              }),
              headers: headers,
            );
          }

          await blogService.initializeCollection(collectionPath);

          // Load posts
          final posts = await blogService.loadPosts(year: year);

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'blogs': posts.map((p) => <String, dynamic>{
                'id': p.id,
                'title': p.title,
                'author': p.author,
                'description': p.description,
                'status': p.isPublished ? 'published' : 'draft',
                'tags': p.tags,
                'timestamp': p.timestamp,
                'url': 'https://p2p.radio/${nickname.toLowerCase()}/blog/${p.id}.html',
              }).toList(),
              'total': posts.length,
            }),
            headers: headers,
          );

        case 'blog_delete':
          // Delete a blog post by ID
          final blogId = params['blog_id'] as String?;
          if (blogId == null || blogId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing blog_id parameter',
              }),
              headers: headers,
            );
          }

          final appName = params['app_name'] as String? ?? 'blog';
          final blogService = BlogService();
          final collectionPath = '$dataDir/devices/$callsign/$appName';

          await blogService.initializeCollection(collectionPath);

          // Delete the post (pass null for userNpub to allow deletion in debug mode)
          final success = await blogService.deletePost(blogId, npub);

          if (!success) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Blog post not found or permission denied',
                'blog_id': blogId,
              }),
              headers: headers,
            );
          }

          LogService().log('LogApiService: Deleted blog post: $blogId');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Blog post deleted',
              'blog_id': blogId,
            }),
            headers: headers,
          );

        case 'blog_get_url':
          // Get the public URL for a blog post
          final blogId = params['blog_id'] as String?;
          if (blogId == null || blogId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing blog_id parameter',
              }),
              headers: headers,
            );
          }

          final appName = params['app_name'] as String? ?? 'blog';
          final blogService = BlogService();
          final collectionPath = '$dataDir/devices/$callsign/$appName';

          // Check if the blog post exists
          final blogDir = io.Directory(collectionPath);
          if (!await blogDir.exists()) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Blog not found',
                'blog_id': blogId,
              }),
              headers: headers,
            );
          }

          await blogService.initializeCollection(collectionPath);
          final post = await blogService.loadFullPost(blogId);

          if (post == null) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Blog post not found',
                'blog_id': blogId,
              }),
              headers: headers,
            );
          }

          final url = 'https://p2p.radio/${nickname.toLowerCase()}/blog/${post.id}.html';

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'blog_id': blogId,
              'url': url,
              'blog': {
                'id': post.id,
                'title': post.title,
                'author': post.author,
                'status': post.isPublished ? 'published' : 'draft',
              },
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown blog action: $action',
              'available': ['blog_create', 'blog_list', 'blog_delete', 'blog_get_url'],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Blog action error: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Debug API - Device Actions (for testing remote device browsing)
  // ============================================================

  /// Handle device debug actions asynchronously
  Future<shelf.Response> _handleDeviceAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      switch (action) {
        case 'device_browse_apps':
          // Browse available apps on a remote device
          final callsign = params['callsign'] as String?;
          if (callsign == null || callsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing callsign parameter',
              }),
              headers: headers,
            );
          }

          // Check if device exists first
          final devicesService = DevicesService();
          final device = devicesService.getDevice(callsign);

          if (device == null) {
            LogService().log('LogApiService: Device $callsign not found in device list');
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Device not found: $callsign',
              }),
              headers: headers,
            );
          }

          LogService().log('LogApiService: Device $callsign found - URL: ${device.url}, isOnline: ${device.isOnline}');
          print('DEBUG: Device $callsign found - URL: ${device.url}, isOnline: ${device.isOnline}');

          final deviceAppsService = DeviceAppsService();
          final apps = await deviceAppsService.discoverApps(
            callsign,
            useCache: false, // Force fresh API check for testing
            refreshInBackground: false,
          );

          final availableApps = apps.entries
              .where((e) => e.value.isAvailable)
              .map((e) => {
                    'type': e.key,
                    'name': e.value.displayName,
                    'itemCount': e.value.itemCount,
                  })
              .toList();

          LogService().log(
              'LogApiService: Browsed apps for $callsign: ${availableApps.map((a) => a['type']).toList()}');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'callsign': callsign,
              'apps': availableApps,
              'app_count': availableApps.length,
            }),
            headers: headers,
          );

        case 'device_open_detail':
          // Open device detail page in the UI
          final callsign = params['callsign'] as String?;
          if (callsign == null || callsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing callsign parameter',
              }),
              headers: headers,
            );
          }

          // Check if device exists first
          final devicesService = DevicesService();
          final device = devicesService.getDevice(callsign);

          if (device == null) {
            LogService().log('LogApiService: Device $callsign not found in device list');
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Device not found: $callsign',
              }),
              headers: headers,
            );
          }

          LogService().log('LogApiService: Opening device detail page for $callsign');
          print('DEBUG: Opening device detail page for $callsign');

          // Trigger the debug action to open device detail
          final debugController = DebugController();
          debugController.triggerAction(
            DebugAction.openDeviceDetail,
            params: {'callsign': callsign, 'device': device},
          );

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Device detail page opened for $callsign',
              'callsign': callsign,
            }),
            headers: headers,
          );

        case 'device_test_remote_chat':
          // Full test: navigate to device -> open chat app -> open room -> send message
          final callsign = params['callsign'] as String?;
          final room = params['room'] as String? ?? 'main';
          final content = params['content'] as String?;

          if (callsign == null || callsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing callsign parameter',
              }),
              headers: headers,
            );
          }

          if (content == null || content.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing content parameter',
              }),
              headers: headers,
            );
          }

          // Check if device exists
          final devicesService = DevicesService();
          final device = devicesService.getDevice(callsign);

          if (device == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Device not found: $callsign',
              }),
              headers: headers,
            );
          }

          LogService().log('LogApiService: Testing remote chat flow for $callsign');

          // Step 1: Navigate to devices panel
          final debugController = DebugController();
          debugController.triggerAction(
            DebugAction.navigateToPanel,
            params: {'panel': 'devices'},
          );
          await Future.delayed(Duration(milliseconds: 500));

          // Step 2: Open device detail
          debugController.triggerAction(
            DebugAction.openDeviceDetail,
            params: {'callsign': callsign, 'device': device},
          );
          await Future.delayed(Duration(milliseconds: 500));

          // Step 3: Open remote chat app
          debugController.triggerAction(
            DebugAction.openRemoteChatApp,
            params: {'callsign': callsign, 'device': device},
          );
          await Future.delayed(Duration(milliseconds: 500));

          // Step 4: Open chat room
          debugController.triggerAction(
            DebugAction.openRemoteChatRoom,
            params: {'callsign': callsign, 'device': device, 'room': room},
          );
          await Future.delayed(Duration(milliseconds: 500));

          // Step 5: Send message
          debugController.triggerAction(
            DebugAction.sendRemoteChatMessage,
            params: {'callsign': callsign, 'device': device, 'room': room, 'content': content},
          );

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Remote chat test flow triggered',
              'callsign': callsign,
              'room': room,
              'steps': [
                'Navigate to devices',
                'Open device detail',
                'Open chat app',
                'Open chat room',
                'Send message',
              ],
            }),
            headers: headers,
          );

        case 'device_send_remote_chat':
          // Send a message to a remote device's chat room
          final callsign = params['callsign'] as String?;
          final room = params['room'] as String? ?? 'main';
          final content = params['content'] as String?;

          if (callsign == null || callsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing callsign parameter',
              }),
              headers: headers,
            );
          }

          if (content == null || content.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing content parameter',
              }),
              headers: headers,
            );
          }

          // Check if device exists
          final devicesService = DevicesService();
          final device = devicesService.getDevice(callsign);

          if (device == null) {
            LogService().log('LogApiService: Device $callsign not found');
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Device not found: $callsign',
              }),
              headers: headers,
            );
          }

          LogService().log('LogApiService: Sending message to $callsign room $room: $content');

          // Get profile and signing service
          final profile = ProfileService().getProfile();
          final signingService = SigningService();
          await signingService.initialize();

          if (!signingService.canSign(profile)) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Cannot sign message: NOSTR keys not configured',
              }),
              headers: headers,
            );
          }

          // Generate signed event
          final signedEvent = await signingService.generateSignedEvent(
            content,
            {
              'room': room,
              'callsign': profile.callsign,
            },
            profile,
          );

          if (signedEvent == null || signedEvent.sig == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Failed to sign message',
              }),
              headers: headers,
            );
          }

          LogService().log('LogApiService: Created signed event id=${signedEvent.id}');

          // Send to remote device
          final payload = {'event': signedEvent.toJson()};
          final response = await devicesService.makeDeviceApiRequest(
            callsign: callsign,
            method: 'POST',
            path: '/api/chat/$room/messages',
            body: jsonEncode(payload),
            headers: {'Content-Type': 'application/json'},
          );

          if (response == null) {
            LogService().log('LogApiService: No route to device $callsign');
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'No route to device $callsign',
              }),
              headers: headers,
            );
          }

          LogService().log('LogApiService: Response status=${response.statusCode}, body=${response.body}');

          if (response.statusCode == 200 || response.statusCode == 201) {
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'message': 'Message sent successfully',
                'callsign': callsign,
                'room': room,
                'eventId': signedEvent.id,
              }),
              headers: headers,
            );
          } else {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'Failed to send message: HTTP ${response.statusCode}',
                'response_body': response.body,
              }),
              headers: headers,
            );
          }

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown device action: $action',
              'available': ['device_browse_apps', 'device_open_detail', 'device_test_remote_chat', 'device_send_remote_chat'],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Device action error: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Debug API - Station Actions (for testing station connectivity)
  // ============================================================

  /// Handle station debug actions asynchronously
  Future<shelf.Response> _handleStationAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final stationService = StationService();
      final webSocketService = WebSocketService();

      switch (action) {
        case 'station_set':
          // Set preferred station URL
          final url = params['url'] as String?;
          if (url == null || url.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing url parameter',
              }),
              headers: headers,
            );
          }

          // Create station object
          final station = Station(
            url: url,
            name: params['name'] as String? ?? 'Test Station',
            callsign: params['callsign'] as String?,
            status: 'preferred',
            lastChecked: DateTime.now(),
          );

          // Add and set as preferred
          await stationService.addStation(station);
          await stationService.setPreferred(url);

          LogService().log('LogApiService: Set preferred station: $url');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Station set as preferred',
              'url': url,
            }),
            headers: headers,
          );

        case 'station_connect':
          // Connect to preferred station via WebSocket
          final url = params['url'] as String?;
          if (url != null && url.isNotEmpty) {
            // Set as preferred first
            final station = Station(
              url: url,
              name: params['name'] as String? ?? 'Test Station',
              status: 'preferred',
              lastChecked: DateTime.now(),
            );
            await stationService.addStation(station);
            await stationService.setPreferred(url);
          }

          final preferred = stationService.getPreferredStation();
          if (preferred == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'No preferred station configured',
              }),
              headers: headers,
            );
          }

          // Connect via WebSocket
          final connected = await webSocketService.connectAndHello(preferred.url);

          final isConnected = connected && webSocketService.isConnected;

          return shelf.Response.ok(
            jsonEncode({
              'success': isConnected,
              'message': isConnected ? 'Connected to station' : 'Connection failed',
              'url': preferred.url,
              'connected': isConnected,
            }),
            headers: headers,
          );

        case 'station_list':
          // List all known stations
          final stations = stationService.getAllStations();
          final preferred = stationService.getPreferredStation();

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'stations': stations.map((s) => {
                'url': s.url,
                'name': s.name,
                'callsign': s.callsign,
                'status': s.status,
                'is_preferred': s.url == preferred?.url,
              }).toList(),
              'preferred_url': preferred?.url,
              'count': stations.length,
            }),
            headers: headers,
          );

        case 'station_status':
          // Get current station connection status
          final preferred = stationService.getPreferredStation();
          final isConnected = webSocketService.isConnected;

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'connected': isConnected,
              'preferred_url': preferred?.url,
              'preferred_name': preferred?.name,
            }),
            headers: headers,
          );

        case 'station_server_start':
          // Start the local StationServerService (for station mode)
          final stationServer = StationServerService();

          // Initialize if needed
          await stationServer.initialize();

          // Start the server
          final success = await stationServer.start();
          final runningPort = stationServer.runningPort;

          LogService().log('LogApiService: Station server start result: $success, port: $runningPort');

          return shelf.Response.ok(
            jsonEncode({
              'success': success,
              'message': success ? 'Station server started' : 'Failed to start station server',
              'port': runningPort,
              'running': stationServer.isRunning,
            }),
            headers: headers,
          );

        case 'station_server_stop':
          // Stop the local StationServerService
          final stationServer = StationServerService();
          await stationServer.stop();

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Station server stopped',
              'running': false,
            }),
            headers: headers,
          );

        case 'station_server_status':
          // Get status of the local station server
          final stationServer = StationServerService();
          final status = stationServer.getStatus();

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              ...status,
            }),
            headers: headers,
          );

        case 'station_send_chat':
          // Send a chat message to a station room (with optional image)
          final room = params['room'] as String? ?? 'general';
          final content = params['content'] as String? ?? '';
          final imagePath = params['image_path'] as String?;

          // Get preferred station
          final preferred = stationService.getPreferredStation();
          if (preferred == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'No preferred station configured. Use station_set first.',
              }),
              headers: headers,
            );
          }

          final profile = ProfileService().getProfile();
          final metadata = <String, String>{};
          final logs = <String>[];

          logs.add('Station URL: ${preferred.url}');
          logs.add('Room: $room');
          logs.add('Content: $content');

          // If image path is provided, upload it first
          if (imagePath != null && imagePath.isNotEmpty) {
            logs.add('Image path: $imagePath');
            final imageFile = io.File(imagePath);
            if (!await imageFile.exists()) {
              return shelf.Response.badRequest(
                body: jsonEncode({
                  'success': false,
                  'error': 'Image file not found: $imagePath',
                  'logs': logs,
                }),
                headers: headers,
              );
            }

            final fileSize = await imageFile.length();
            logs.add('Image size: $fileSize bytes');

            // Upload the file
            logs.add('Uploading image...');
            final uploadedFilename = await stationService.uploadRoomFile(
              preferred.url,
              room,
              imagePath,
            );

            if (uploadedFilename == null) {
              logs.add('ERROR: File upload failed');
              return shelf.Response.ok(
                jsonEncode({
                  'success': false,
                  'error': 'File upload failed',
                  'logs': logs,
                }),
                headers: headers,
              );
            }

            logs.add('Upload successful: $uploadedFilename');
            metadata['file'] = uploadedFilename;
            metadata['file_size'] = fileSize.toString();
          }

          // Send the message
          logs.add('Sending message...');
          final createdAt = await stationService.postRoomMessage(
            preferred.url,
            room,
            profile.callsign,
            content,
            metadata: metadata.isNotEmpty ? metadata : null,
          );

          if (createdAt != null) {
            logs.add('Message sent successfully, created_at: $createdAt');
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'message': 'Message sent successfully',
                'room': room,
                'content': content,
                'metadata': metadata,
                'created_at': createdAt,
                'logs': logs,
              }),
              headers: headers,
            );
          } else {
            logs.add('ERROR: Failed to send message');
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'Failed to send message',
                'logs': logs,
              }),
              headers: headers,
            );
          }

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown station action: $action',
              'available': [
                'station_set',
                'station_connect',
                'station_list',
                'station_status',
                'station_server_start',
                'station_server_stop',
                'station_server_status',
                'station_send_chat',
              ],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Station action error: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Debug API - Place Actions (for testing Places feedback API)
  // ============================================================

  /// Handle place debug actions asynchronously
  Future<shelf.Response> _handlePlaceAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      late final String dataDir;
      try {
        dataDir = StorageConfig().baseDir;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({
            'success': false,
            'error': 'Storage not initialized',
          }),
          headers: headers,
        );
      }

      String? defaultCallsign;
      String? defaultNpub;
      String? defaultAuthor;
      try {
        final profile = ProfileService().getProfile();
        defaultCallsign = profile.callsign;
        defaultNpub = profile.npub;
        defaultAuthor = profile.nickname != null && profile.nickname!.isNotEmpty
            ? profile.nickname
            : profile.callsign;
      } catch (_) {}

      final placePathParam = params['place_path'] as String? ?? params['placePath'] as String?;
      var placeId = params['place_id'] as String? ?? params['placeId'] as String?;
      if ((placeId == null || placeId.isEmpty) &&
          placePathParam != null &&
          placePathParam.isNotEmpty) {
        final baseName = path.basename(placePathParam);
        placeId = baseName == 'place.txt'
            ? path.basename(path.dirname(placePathParam))
            : baseName;
      }

      if (placeId == null || placeId.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing place_id parameter',
          }),
          headers: headers,
        );
      }

      final callsign = params['callsign'] as String? ?? defaultCallsign;
      String? placePath;
      if (placePathParam != null && placePathParam.isNotEmpty) {
        final placeFile = io.File(placePathParam);
        if (await placeFile.exists()) {
          placePath = placeFile.parent.path;
        } else {
          final placeDir = io.Directory(placePathParam);
          if (await placeDir.exists()) {
            placePath = placeDir.path;
          } else {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'place_path not found',
                'place_path': placePathParam,
              }),
              headers: headers,
            );
          }
        }
      } else {
        placePath = await _resolvePlacePath(dataDir, placeId, callsign: callsign);
      }

      switch (action) {
        case 'place_like':
          final event = await PlaceFeedbackService().buildLikeEvent(placeId);
          if (event == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Unable to sign like feedback',
              }),
              headers: headers,
            );
          }

          final result = await PlaceFeedbackService().toggleLikeOnStation(placeId, event);
          if (!result.success) {
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': result.error ?? 'Station rejected feedback',
              }),
              headers: headers,
            );
          }

          final liked = result.isActive;
          if (liked == null) {
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': 'Station did not return like state',
              }),
              headers: headers,
            );
          }

          bool? localSaved;
          int? localCount;
          if (placePath != null && placePath.isNotEmpty) {
            if (liked) {
              await FeedbackFolderUtils.addFeedbackEvent(
                placePath,
                FeedbackFolderUtils.feedbackTypeLikes,
                event,
              );
            } else {
              await FeedbackFolderUtils.removeFeedbackEvent(
                placePath,
                FeedbackFolderUtils.feedbackTypeLikes,
                event.npub,
              );
            }

            final localNpubs = await FeedbackFolderUtils.readFeedbackFile(
              placePath,
              FeedbackFolderUtils.feedbackTypeLikes,
            );
            localSaved = liked ? localNpubs.contains(event.npub) : !localNpubs.contains(event.npub);
            localCount = localNpubs.length;
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'place_id': placeId,
              'liked': liked,
              'like_count': result.count ?? localCount,
              'place_path': placePath,
              'local_saved': localSaved,
            }),
            headers: headers,
          );

        case 'place_comment':
          final content = params['content'] as String?;
          if (content == null || content.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing content parameter',
              }),
              headers: headers,
            );
          }

          final author = params['author'] as String? ??
              defaultAuthor ??
              defaultCallsign ??
              'UNKNOWN';
          final requestedNpub = params['npub'] as String?;
          if (requestedNpub != null &&
              defaultNpub != null &&
              requestedNpub != defaultNpub) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'npub does not match active profile',
              }),
              headers: headers,
            );
          }
          final npub = requestedNpub ?? defaultNpub;

          final signature = await PlaceFeedbackService().signComment(placeId, content);
          if (signature == null || signature.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Unable to sign comment',
              }),
              headers: headers,
            );
          }

          final commentOk = await PlaceFeedbackService().commentOnStation(
            placeId,
            author,
            content,
            npub: npub,
            signature: signature,
          );

          if (!commentOk) {
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': 'Station rejected comment',
              }),
              headers: headers,
            );
          }

          String? commentId;
          bool? localSaved;
          if (placePath != null && placePath.isNotEmpty) {
            commentId = await FeedbackCommentUtils.writeComment(
              contentPath: placePath,
              author: author,
              content: content,
              npub: npub,
              signature: signature,
            );
            localSaved = commentId.isNotEmpty;
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'place_id': placeId,
              'comment_id': commentId,
              'place_path': placePath,
              'local_saved': localSaved,
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown place action: $action',
              'available': ['place_like', 'place_comment'],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Place action error: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  Future<String?> _resolvePlacePath(
    String dataDir,
    String folderName, {
    String? callsign,
  }) async {
    final devicesDir = io.Directory('$dataDir/devices');
    if (!await devicesDir.exists()) return null;

    Future<String?> searchCallsign(String callsign) async {
      final placesRoot = io.Directory('$dataDir/devices/$callsign/places');
      if (!await placesRoot.exists()) return null;

      await for (final entity in placesRoot.list(recursive: true)) {
        if (entity is! io.File) continue;
        if (!entity.path.endsWith('/place.txt')) continue;

        final folder = entity.parent;
        if (path.basename(folder.path) == folderName) {
          return folder.path;
        }
      }
      return null;
    }

    if (callsign != null && callsign.isNotEmpty) {
      return searchCallsign(callsign);
    }

    await for (final deviceEntity in devicesDir.list()) {
      if (deviceEntity is! io.Directory) continue;
      final deviceCallsign = path.basename(deviceEntity.path);
      final match = await searchCallsign(deviceCallsign);
      if (match != null) return match;
    }

    return null;
  }

  // ============================================================
  // Debug API - Alert Actions (for testing Alerts API)
  // ============================================================

  /// Handle alert debug actions asynchronously
  Future<shelf.Response> _handleAlertAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      // Get data directory from storage config
      String? dataDir;
      try {
        dataDir = StorageConfig().baseDir;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({
            'success': false,
            'error': 'Storage not initialized',
          }),
          headers: headers,
        );
      }

      switch (action) {
        case 'alert_create':
          // Create a test alert
          final title = params['title'] as String? ?? 'Test Alert ${DateTime.now().millisecondsSinceEpoch}';
          final description = params['description'] as String? ?? 'This is a test alert created via debug API.';
          final latitude = (params['latitude'] as num?)?.toDouble() ?? 38.7223;
          final longitude = (params['longitude'] as num?)?.toDouble() ?? -9.1393;
          final severity = params['severity'] as String? ?? 'info';
          final type = params['type'] as String? ?? 'other';
          final statusParam = params['status'] as String? ?? 'open';

          // Get callsign from profile service
          String callsign = 'TEST';
          try {
            final profile = ProfileService().getProfile();
            callsign = profile.callsign;
          } catch (e) {
            // Profile service not initialized, use TEST callsign
          }

          // Create timestamp in expected format
          final now = DateTime.now();
          final seconds = now.second.toString().padLeft(2, '0');
          final created = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_$seconds';

          // Parse severity
          ReportSeverity reportSeverity;
          switch (severity.toLowerCase()) {
            case 'emergency':
              reportSeverity = ReportSeverity.emergency;
              break;
            case 'urgent':
              reportSeverity = ReportSeverity.urgent;
              break;
            case 'attention':
              reportSeverity = ReportSeverity.attention;
              break;
            default:
              reportSeverity = ReportSeverity.info;
          }

          // Parse status
          ReportStatus reportStatus;
          switch (statusParam.toLowerCase()) {
            case 'inprogress':
            case 'in_progress':
              reportStatus = ReportStatus.inProgress;
              break;
            case 'resolved':
              reportStatus = ReportStatus.resolved;
              break;
            case 'closed':
              reportStatus = ReportStatus.closed;
              break;
            default:
              reportStatus = ReportStatus.open;
          }

          // Create alert folder name using timestamp format: YYYY-MM-DD_HH-MM_title-slug
          var titleSlug = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
          // Limit title to 100 characters
          if (titleSlug.length > 100) {
            titleSlug = titleSlug.substring(0, 100).replaceAll(RegExp(r'-+$'), '');
          }
          final folderName = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_'
              '${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}_$titleSlug';

          // Calculate region folder (rounded to 1 decimal) to match uploadPhotosToStation path
          final roundedLat = (latitude * 10).round() / 10;
          final roundedLon = (longitude * 10).round() / 10;
          final regionFolder = '${roundedLat}_$roundedLon';

          // Create the alert directory in the proper structure: alerts/active/{regionFolder}/{folderName}
          final alertDir = io.Directory('$dataDir/devices/$callsign/alerts/active/$regionFolder/$folderName');
          await alertDir.create(recursive: true);

          // Check if we should create a test photo
          final includePhoto = params['photo'] == true || params['photo'] == 'true';
          String? createdPhotoPath;

          if (includePhoto) {
            // Create images subfolder
            final imagesDir = io.Directory('${alertDir.path}/images');
            await imagesDir.create(recursive: true);

            // Use sequential naming: photo1.png
            final testPhotoName = 'photo1.png';
            createdPhotoPath = '${imagesDir.path}/$testPhotoName';

            // Create a minimal valid PNG (1x1 red pixel)
            final pngBytes = Uint8List.fromList([
              0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
              0x00, 0x00, 0x00, 0x0D, // IHDR chunk length
              0x49, 0x48, 0x44, 0x52, // IHDR
              0x00, 0x00, 0x00, 0x01, // width: 1
              0x00, 0x00, 0x00, 0x01, // height: 1
              0x08, 0x02, // bit depth: 8, color type: RGB
              0x00, 0x00, 0x00, // compression, filter, interlace
              0x90, 0x77, 0x53, 0xDE, // CRC
              0x00, 0x00, 0x00, 0x0C, // IDAT chunk length
              0x49, 0x44, 0x41, 0x54, // IDAT
              0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, // compressed data (red pixel)
              0x01, 0x01, 0x01, 0x00, // Adler-32 checksum
              0x18, 0xDD, 0x8D, 0xB4, // CRC
              0x00, 0x00, 0x00, 0x00, // IEND chunk length
              0x49, 0x45, 0x4E, 0x44, // IEND
              0xAE, 0x42, 0x60, 0x82, // CRC
            ]);

            final photoFile = io.File(createdPhotoPath);
            await photoFile.writeAsBytes(pngBytes);

            LogService().log('LogApiService: Created test photo at $createdPhotoPath');
          }

          // Create the alert object
          final alert = Report(
            folderName: folderName,
            titles: {'EN': title},
            descriptions: {'EN': description},
            latitude: latitude,
            longitude: longitude,
            type: type,
            severity: reportSeverity,
            status: reportStatus,
            created: created,
            author: callsign,
          );

          // Write report.txt
          final reportFile = io.File('${alertDir.path}/report.txt');
          await reportFile.writeAsString(alert.exportAsText());

          LogService().log('LogApiService: Created test alert: ${alert.apiId}');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Alert created${includePhoto ? " with photo" : ""}',
              'alert_id': alert.apiId,
              'folder_name': folderName,
              'alert': alert.toApiJson(),
              'photo_created': includePhoto,
              'photo_path': createdPhotoPath,
              'alert_path': alertDir.path,
            }),
            headers: headers,
          );

        case 'alert_list':
          // List all alerts via the helper
          final status = params['status'] as String?;
          final lat = (params['lat'] as num?)?.toDouble();
          final lon = (params['lon'] as num?)?.toDouble();
          final radius = (params['radius'] as num?)?.toDouble();

          io.stderr.writeln('DEBUG alert_list: dataDir=$dataDir');

          final alertsWithPaths = await _getAllAlertsGlobal(
            dataDir,
            status: status,
            lat: lat,
            lon: lon,
            radius: radius,
          );

          io.stderr.writeln('DEBUG alert_list: found ${alertsWithPaths.length} alerts');

          final alertsJson = <Map<String, dynamic>>[];
          for (final tuple in alertsWithPaths) {
            final alert = tuple.$1;
            final alertPath = tuple.$2;
            final hasPhotos = await _alertHasPhotos(alertPath);
            alertsJson.add(alert.toApiJson(summary: true, hasPhotos: hasPhotos));
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'alerts': alertsJson,
              'total': alertsJson.length,
            }),
            headers: headers,
          );

        case 'alert_delete':
          // Delete an alert by ID
          final alertId = params['alert_id'] as String?;
          if (alertId == null || alertId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing alert_id parameter',
              }),
              headers: headers,
            );
          }

          // Find the alert to get its path
          final result = await _getAlertByApiId(alertId, dataDir);
          if (result == null) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Alert not found',
                'alert_id': alertId,
              }),
              headers: headers,
            );
          }

          final alertPath = result.$2;
          final alertDir = io.Directory(alertPath);

          if (await alertDir.exists()) {
            await alertDir.delete(recursive: true);
            LogService().log('LogApiService: Deleted alert: $alertId');

            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'message': 'Alert deleted',
                'alert_id': alertId,
              }),
              headers: headers,
            );
          }

          return shelf.Response.notFound(
            jsonEncode({
              'success': false,
              'error': 'Alert directory not found',
              'alert_id': alertId,
            }),
            headers: headers,
          );

        case 'alert_point':
          // Point/unpoint an alert (call attention to it)
          final alertId = params['alert_id'] as String?;
          if (alertId == null || alertId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing alert_id parameter',
              }),
              headers: headers,
            );
          }

          // Find the alert
          final pointResult = await _getAlertByApiId(alertId, dataDir);
          if (pointResult == null) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Alert not found',
                'alert_id': alertId,
              }),
              headers: headers,
            );
          }

          final alertToPoint = pointResult.$1;
          final alertPathForPoint = pointResult.$2;

          // Get npub from params or use profile
          String? npub = params['npub'] as String?;
          if (npub == null || npub.isEmpty) {
            try {
              final profile = ProfileService().getProfile();
              npub = profile.npub;
            } catch (e) {
              // Profile not initialized
            }
          }

          if (npub == null || npub.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing npub parameter and no profile npub available',
              }),
              headers: headers,
            );
          }

          final pointedBy = await AlertFolderUtils.readPointsFile(alertPathForPoint);
          final wasPointed = pointedBy.contains(npub);
          final event = await AlertFeedbackService().buildReactionEvent(
            alertToPoint.apiId,
            wasPointed ? 'unpoint' : 'point',
            FeedbackFolderUtils.feedbackTypePoints,
          );

          if (event == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Unable to sign point feedback',
              }),
              headers: headers,
            );
          }

          final isNowActive = await FeedbackFolderUtils.toggleFeedbackEvent(
            alertPathForPoint,
            FeedbackFolderUtils.feedbackTypePoints,
            event,
          );
          if (isNowActive == null) {
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': 'Failed to apply point feedback',
              }),
              headers: headers,
            );
          }

          // Update lastModified on report.txt
          final reportFileForPoint = io.File('$alertPathForPoint/report.txt');
          if (await reportFileForPoint.exists()) {
            var content = await reportFileForPoint.readAsString();
            final now = DateTime.now().toUtc().toIso8601String();
            // Update LAST_MODIFIED if exists, or add it
            if (content.contains('LAST_MODIFIED: ')) {
              content = content.replaceFirst(
                RegExp(r'LAST_MODIFIED: [^\n]*'),
                'LAST_MODIFIED: $now',
              );
            } else {
              // Find insertion point - should be after header fields, before description
              // Report format: Title, empty line, header fields, empty line, description
              // We want to insert just before the SECOND empty line (before description)
              final lines = content.split('\n');
              var insertIdx = lines.length;
              var emptyLineCount = 0;
              for (var i = 0; i < lines.length; i++) {
                if (lines[i].trim().isEmpty && i > 0 && !lines[i - 1].startsWith('-->')) {
                  emptyLineCount++;
                  if (emptyLineCount == 2) {
                    // Found the empty line before description - insert before it
                    insertIdx = i;
                    break;
                  }
                }
              }
              lines.insert(insertIdx, 'LAST_MODIFIED: $now');
              content = lines.join('\n');
            }
            await reportFileForPoint.writeAsString(content);
          }

          final updatedPointedBy = await AlertFolderUtils.readPointsFile(alertPathForPoint);
          LogService().log('LogApiService: ${isNowActive ? "Pointed" : "Unpointed"} alert: $alertId by $npub');

          // Sync to station (best-effort, fire-and-forget)
          if (wasPointed) {
            AlertFeedbackService().unpointAlertOnStation(alertId).ignore();
          } else {
            AlertFeedbackService().pointAlertOnStation(alertId).ignore();
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': wasPointed ? 'Alert unpointed' : 'Alert pointed',
              'alert_id': alertId,
              'pointed': isNowActive,
              'point_count': updatedPointedBy.length,
              'pointed_by': updatedPointedBy,
            }),
            headers: headers,
          );

        case 'alert_verify':
          // Verify an alert (confirm accuracy)
          final verifyAlertId = params['alert_id'] as String?;
          if (verifyAlertId == null || verifyAlertId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing alert_id parameter',
              }),
              headers: headers,
            );
          }

          // Find the alert
          final verifyResult = await _getAlertByApiId(verifyAlertId, dataDir);
          if (verifyResult == null) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Alert not found',
                'alert_id': verifyAlertId,
              }),
              headers: headers,
            );
          }

          final alertToVerify = verifyResult.$1;
          final alertPathForVerify = verifyResult.$2;

          // Get npub from params or use profile
          String? verifyNpub = params['npub'] as String?;
          if (verifyNpub == null || verifyNpub.isEmpty) {
            try {
              final profile = ProfileService().getProfile();
              verifyNpub = profile.npub;
            } catch (e) {
              // Profile not initialized
            }
          }

          if (verifyNpub == null || verifyNpub.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing npub parameter and no profile npub available',
              }),
              headers: headers,
            );
          }

          final event = await AlertFeedbackService().buildVerificationEvent(alertToVerify.apiId);
          if (event == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Unable to sign verification feedback',
              }),
              headers: headers,
            );
          }

          final added = await FeedbackFolderUtils.addFeedbackEvent(
            alertPathForVerify,
            FeedbackFolderUtils.feedbackTypeVerifications,
            event,
          );

          final verifiedBy = List<String>.from(alertToVerify.verifiedBy);
          if (added && !verifiedBy.contains(event.npub)) {
            verifiedBy.add(event.npub);
          }

          final updatedVerifyAlert = alertToVerify.copyWith(
            verifiedBy: verifiedBy,
            verificationCount: verifiedBy.length,
            lastModified: added ? DateTime.now().toUtc().toIso8601String() : null,
          );

          final reportFileForVerify = io.File('$alertPathForVerify/report.txt');
          await reportFileForVerify.writeAsString(updatedVerifyAlert.exportAsText());

          LogService().log('LogApiService: ${added ? "Verified" : "Already verified"} alert: $verifyAlertId by $verifyNpub');

          if (added) {
            AlertFeedbackService().verifyAlertOnStation(verifyAlertId).catchError((e) {
              LogService().log('Failed to sync verify to station: $e');
            });
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': added ? 'Alert verified' : 'Alert already verified',
              'alert_id': verifyAlertId,
              'verified': true,
              'verification_count': updatedVerifyAlert.verificationCount,
              'verified_by': updatedVerifyAlert.verifiedBy,
            }),
            headers: headers,
          );

        case 'alert_comment':
          // Add a comment to an alert
          final alertIdForComment = params['alert_id'] as String?;
          final content = params['content'] as String?;

          if (alertIdForComment == null || alertIdForComment.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing alert_id parameter',
              }),
              headers: headers,
            );
          }

          if (content == null || content.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing content parameter',
              }),
              headers: headers,
            );
          }

          // Find the alert
          final commentResult = await _getAlertByApiId(alertIdForComment, dataDir);
          if (commentResult == null) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Alert not found',
                'alert_id': alertIdForComment,
              }),
              headers: headers,
            );
          }

          final alertPathForComment = commentResult.$2;

          // Get author from params or profile
          String author = params['author'] as String? ?? '';
          String? commentNpub = params['npub'] as String?;

          if (author.isEmpty) {
            try {
              final profile = ProfileService().getProfile();
              author = profile.callsign;
              commentNpub ??= profile.npub;
            } catch (e) {
              author = 'ANONYMOUS';
            }
          }

          final signature = await AlertFeedbackService().signComment(alertIdForComment, content);
          final commentId = await FeedbackCommentUtils.writeComment(
            contentPath: alertPathForComment,
            author: author,
            content: content,
            npub: commentNpub,
            signature: signature,
          );

          final commentFilePath = '${FeedbackFolderUtils.buildCommentsPath(alertPathForComment)}/$commentId.txt';
          String createdStr = '';
          try {
            final commentContent = await io.File(commentFilePath).readAsString();
            final parsed = FeedbackCommentUtils.parseCommentFile(commentContent, commentId);
            createdStr = parsed.created;
          } catch (_) {
            final now = DateTime.now();
            createdStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';
          }

          final reportFileForComment = io.File('$alertPathForComment/report.txt');
          if (await reportFileForComment.exists()) {
            var reportContent = await reportFileForComment.readAsString();
            final now = DateTime.now().toUtc().toIso8601String();
            if (reportContent.contains('LAST_MODIFIED: ')) {
              reportContent = reportContent.replaceFirst(
                RegExp(r'LAST_MODIFIED: [^\n]*'),
                'LAST_MODIFIED: $now',
              );
            } else {
              final lines = reportContent.split('\n');
              var insertIdx = lines.length;
              var emptyLineCount = 0;
              for (var i = 0; i < lines.length; i++) {
                if (lines[i].trim().isEmpty && i > 0 && !lines[i - 1].startsWith('-->')) {
                  emptyLineCount++;
                  if (emptyLineCount == 2) {
                    insertIdx = i;
                    break;
                  }
                }
              }
              lines.insert(insertIdx, 'LAST_MODIFIED: $now');
              reportContent = lines.join('\n');
            }
            await reportFileForComment.writeAsString(reportContent);
          }

          LogService().log('LogApiService: Added comment to alert: $alertIdForComment by $author');

          // Sync to station (best-effort, fire-and-forget)
          AlertFeedbackService().commentOnStation(
            alertIdForComment,
            author,
            content,
            npub: commentNpub,
          ).catchError((e) {
            LogService().log('Failed to sync comment to station: $e');
          });

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Comment added',
              'alert_id': alertIdForComment,
              'comment_file': '$commentId.txt',
              'author': author,
              'created': createdStr,
            }),
            headers: headers,
          );

        case 'alert_add_photo':
          // Add a photo to an existing alert
          final alertIdForPhoto = params['alert_id'] as String?;
          final imageUrl = params['url'] as String?;
          final photoName = params['name'] as String? ?? 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';

          if (alertIdForPhoto == null || alertIdForPhoto.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing required parameter: alert_id',
              }),
              headers: headers,
            );
          }

          // Get callsign from profile service
          String callsignForPhoto = 'TEST';
          try {
            final profile = ProfileService().getProfile();
            callsignForPhoto = profile.callsign;
          } catch (e) {
            // Profile service not initialized
          }

          // Find the alert folder by searching for matching alert_id
          // Alerts are stored at: alerts/active/{regionFolder}/{folderName}
          final alertsDir = io.Directory('$dataDir/devices/$callsignForPhoto/alerts');
          if (!await alertsDir.exists()) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'No alerts directory found',
              }),
              headers: headers,
            );
          }

          // Search recursively for matching alert folder
          io.Directory? foundAlertDir;
          await for (final entity in alertsDir.list(recursive: true)) {
            if (entity is io.File && entity.path.endsWith('/report.txt')) {
              try {
                final content = await entity.readAsString();
                final folderPath = entity.parent.path;
                final folderName = folderPath.split('/').last;
                final report = Report.fromText(content, folderName);
                if (report.apiId == alertIdForPhoto) {
                  foundAlertDir = entity.parent;
                  break;
                }
              } catch (e) {
                // Skip malformed reports
              }
            }
          }

          if (foundAlertDir == null) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Alert not found: $alertIdForPhoto',
              }),
              headers: headers,
            );
          }

          // Create images subfolder if it doesn't exist
          final imagesDir = io.Directory('${foundAlertDir.path}/images');
          if (!await imagesDir.exists()) {
            await imagesDir.create(recursive: true);
          }

          // Get next sequential photo number
          final nextPhotoNum = await _getNextPhotoNumber(foundAlertDir.path);

          // Determine file extension from provided name or URL
          String photoExt = '.png';
          if (photoName.contains('.')) {
            photoExt = path.extension(photoName).toLowerCase();
          } else if (imageUrl != null && imageUrl.contains('.')) {
            final urlExt = path.extension(Uri.parse(imageUrl).path).toLowerCase();
            if (['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(urlExt)) {
              photoExt = urlExt;
            }
          }

          // Use sequential naming: photo{number}.{ext}
          final sequentialPhotoName = 'photo$nextPhotoNum$photoExt';
          final photoPath = '${imagesDir.path}/$sequentialPhotoName';

          if (imageUrl != null && imageUrl.isNotEmpty) {
            // Download image from URL
            try {
              final response = await http.get(Uri.parse(imageUrl));
              if (response.statusCode == 200) {
                await io.File(photoPath).writeAsBytes(response.bodyBytes);
                LogService().log('LogApiService: Downloaded photo from $imageUrl to $photoPath');
              } else {
                return shelf.Response.internalServerError(
                  body: jsonEncode({
                    'success': false,
                    'error': 'Failed to download image: HTTP ${response.statusCode}',
                  }),
                  headers: headers,
                );
              }
            } catch (e) {
              return shelf.Response.internalServerError(
                body: jsonEncode({
                  'success': false,
                  'error': 'Failed to download image: $e',
                }),
                headers: headers,
              );
            }
          } else {
            // Create a simple placeholder PNG image (1x1 red pixel as test)
            // PNG header + IHDR + IDAT + IEND for a minimal valid PNG
            final pngBytes = <int>[
              // PNG signature
              0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
              // IHDR chunk (13 bytes of data)
              0x00, 0x00, 0x00, 0x0D, // length
              0x49, 0x48, 0x44, 0x52, // "IHDR"
              0x00, 0x00, 0x00, 0x10, // width: 16
              0x00, 0x00, 0x00, 0x10, // height: 16
              0x08, // bit depth: 8
              0x02, // color type: RGB
              0x00, // compression: deflate
              0x00, // filter: adaptive
              0x00, // interlace: none
              0x90, 0x77, 0x53, 0xDE, // CRC
              // IDAT chunk (compressed image data - solid red 16x16)
              0x00, 0x00, 0x00, 0x1D, // length: 29
              0x49, 0x44, 0x41, 0x54, // "IDAT"
              0x78, 0x9C, 0x62, 0xF8, 0xCF, 0x00, 0x00, 0x00,
              0x30, 0x00, 0x01, 0x62, 0xF8, 0xCF, 0xC0, 0xC0,
              0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0x00, 0x00, 0x19,
              0x60, 0x00, 0x19,
              0x67, 0xA3, 0x8B, 0x5E, // CRC
              // IEND chunk
              0x00, 0x00, 0x00, 0x00, // length: 0
              0x49, 0x45, 0x4E, 0x44, // "IEND"
              0xAE, 0x42, 0x60, 0x82, // CRC
            ];
            await io.File(photoPath).writeAsBytes(pngBytes);
            LogService().log('LogApiService: Created placeholder photo at $photoPath');
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Photo added to alert',
              'alert_id': alertIdForPhoto,
              'photo_path': photoPath,
              'photo_name': 'images/$sequentialPhotoName',
            }),
            headers: headers,
          );

        case 'alert_share':
          // Share an alert to station (sends NOSTR event + uploads photos)
          final alertIdToShare = params['alert_id'] as String?;
          if (alertIdToShare == null || alertIdToShare.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing alert_id parameter',
              }),
              headers: headers,
            );
          }

          // Find the alert
          final shareResult = await _getAlertByApiId(alertIdToShare, dataDir);
          if (shareResult == null) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Alert not found',
                'alert_id': alertIdToShare,
              }),
              headers: headers,
            );
          }

          final alertToShare = shareResult.$1;
          final alertPath = shareResult.$2;

          LogService().log('LogApiService: Sharing alert ${alertToShare.apiId} from $alertPath');

          // Share to station
          try {
            final alertSharingService = AlertSharingService();
            final summary = await alertSharingService.shareAlert(alertToShare);

            LogService().log('LogApiService: Share result - confirmed: ${summary.confirmed}, failed: ${summary.failed}');

            return shelf.Response.ok(
              jsonEncode({
                'success': summary.anySuccess,
                'message': summary.anySuccess
                    ? 'Alert shared to ${summary.confirmed} station(s)'
                    : 'Failed to share alert',
                'alert_id': alertIdToShare,
                'confirmed': summary.confirmed,
                'failed': summary.failed,
                'skipped': summary.skipped,
                'event_id': summary.eventId,
                'results': summary.results.map((r) => {
                  'station': r.stationUrl,
                  'success': r.success,
                  'message': r.message,
                }).toList(),
              }),
              headers: headers,
            );
          } catch (e, stack) {
            LogService().log('LogApiService: alert_share error: $e');
            LogService().log('LogApiService: Stack: $stack');
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': 'Share failed: $e',
                'alert_id': alertIdToShare,
              }),
              headers: headers,
            );
          }

        case 'alert_upload_photos':
          // Upload alert photos directly to station via HTTP (bypasses NOSTR)
          final uploadAlertId = params['alert_id'] as String?;
          final stationUrl = params['station_url'] as String?;
          if (uploadAlertId == null || uploadAlertId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing alert_id parameter',
              }),
              headers: headers,
            );
          }
          if (stationUrl == null || stationUrl.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing station_url parameter',
              }),
              headers: headers,
            );
          }

          // Find the alert
          final uploadResult = await _getAlertByApiId(uploadAlertId, dataDir);
          if (uploadResult == null) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Alert not found',
                'alert_id': uploadAlertId,
              }),
              headers: headers,
            );
          }

          final uploadAlert = uploadResult.$1;
          final uploadAlertPath = uploadResult.$2;

          LogService().log('LogApiService: Uploading photos for alert ${uploadAlert.apiId} to $stationUrl');

          try {
            final alertSharingService = AlertSharingService();
            final photosUploaded = await alertSharingService.uploadPhotosToStation(uploadAlert, stationUrl);

            LogService().log('LogApiService: Uploaded $photosUploaded photos');

            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'message': 'Uploaded $photosUploaded photo(s) to station',
                'alert_id': uploadAlertId,
                'photos_uploaded': photosUploaded,
                'station_url': stationUrl,
              }),
              headers: headers,
            );
          } catch (e, stack) {
            LogService().log('LogApiService: Photo upload error: $e');
            LogService().log('LogApiService: Stack: $stack');
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': 'Upload failed: $e',
                'alert_id': uploadAlertId,
              }),
              headers: headers,
            );
          }

        case 'alert_sync':
          // Sync alerts from station (fetches alerts and downloads photos)
          final stationAlertService = StationAlertService();
          final lat = (params['lat'] as num?)?.toDouble();
          final lon = (params['lon'] as num?)?.toDouble();
          final radiusKm = (params['radius'] as num?)?.toDouble();
          final useSince = params['use_since'] as bool? ?? false;

          LogService().log('LogApiService: Syncing alerts from station...');

          final syncResult = await stationAlertService.fetchAlerts(
            lat: lat,
            lon: lon,
            radiusKm: radiusKm,
            useSince: useSince,
          );

          return shelf.Response.ok(
            jsonEncode({
              'success': syncResult.success,
              'message': syncResult.success
                  ? 'Synced ${syncResult.alerts.length} alerts from station'
                  : (syncResult.error ?? 'Failed to sync alerts'),
              'alert_count': syncResult.alerts.length,
              'station_name': syncResult.stationName,
              'station_callsign': syncResult.stationCallsign,
              'timestamp': syncResult.timestamp,
              'alerts': syncResult.alerts.map((a) => {
                'folder_name': a.folderName,
                'title': a.titles['EN'] ?? a.folderName,
                'latitude': a.latitude,
                'longitude': a.longitude,
                'severity': a.severity.name,
                'status': a.status.name,
                'point_count': a.pointCount,
                'verification_count': a.verificationCount,
              }).toList(),
            }),
            headers: headers,
          );

        case 'alert_ui_debug':
          // Debug action to show location state and alerts with distances
          // This helps diagnose why alerts may not be showing in the UI

          // Get profile location (Settings location)
          double? profileLat;
          double? profileLon;
          String? profileLocationName;
          String profileCallsign = 'UNKNOWN';
          try {
            final profile = ProfileService().getProfile();
            profileLat = profile.latitude;
            profileLon = profile.longitude;
            profileLocationName = profile.locationName;
            profileCallsign = profile.callsign;
          } catch (e) {
            LogService().log('LogApiService: Error getting profile: $e');
          }

          // Get UserLocationService location
          double? userLocationLat;
          double? userLocationLon;
          String? userLocationSource;
          bool userLocationValid = false;
          try {
            final userLocationService = UserLocationService();
            final userLocation = userLocationService.currentLocation;
            if (userLocation != null) {
              userLocationLat = userLocation.latitude;
              userLocationLon = userLocation.longitude;
              userLocationSource = userLocation.source;
              userLocationValid = userLocation.isValid;
            }
          } catch (e) {
            LogService().log('LogApiService: Error getting user location: $e');
          }

          // Determine which location would be used (profile first, then UserLocationService)
          double? effectiveLat = profileLat;
          double? effectiveLon = profileLon;
          String effectiveSource = 'profile';
          if (effectiveLat == null || effectiveLon == null) {
            if (userLocationLat != null && userLocationLon != null && userLocationValid) {
              effectiveLat = userLocationLat;
              effectiveLon = userLocationLon;
              effectiveSource = 'user_location_service ($userLocationSource)';
            } else {
              effectiveSource = 'none';
            }
          }

          // Get cached station alerts
          final debugStationAlertService = StationAlertService();
          final cachedAlerts = debugStationAlertService.cachedAlerts;

          // Calculate distances for each alert using Haversine formula
          double calcDistance(double lat1, double lon1, double lat2, double lon2) {
            const earthRadius = 6371.0;
            final dLat = (lat2 - lat1) * 3.14159265359 / 180;
            final dLon = (lon2 - lon1) * 3.14159265359 / 180;
            final a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * 3.14159265359 / 180) *
                    cos(lat2 * 3.14159265359 / 180) *
                    sin(dLon / 2) *
                    sin(dLon / 2);
            final c = 2 * atan2(sqrt(a), sqrt(1 - a));
            return earthRadius * c;
          }

          final alertsWithDistances = cachedAlerts.map((alert) {
            double? distance;
            if (effectiveLat != null && effectiveLon != null) {
              distance = calcDistance(
                effectiveLat, effectiveLon,
                alert.latitude, alert.longitude,
              );
            }
            return {
              'folder_name': alert.folderName,
              'title': alert.titles['EN'] ?? alert.folderName,
              'latitude': alert.latitude,
              'longitude': alert.longitude,
              'distance_km': distance?.toStringAsFixed(2),
              'author': alert.author,
              'severity': alert.severity.name,
            };
          }).toList();

          // Sort by distance
          alertsWithDistances.sort((a, b) {
            final distA = double.tryParse(a['distance_km']?.toString() ?? '') ?? double.infinity;
            final distB = double.tryParse(b['distance_km']?.toString() ?? '') ?? double.infinity;
            return distA.compareTo(distB);
          });

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'profile_location': {
                'latitude': profileLat,
                'longitude': profileLon,
                'location_name': profileLocationName,
                'callsign': profileCallsign,
              },
              'user_location_service': {
                'latitude': userLocationLat,
                'longitude': userLocationLon,
                'source': userLocationSource,
                'is_valid': userLocationValid,
              },
              'effective_location': {
                'latitude': effectiveLat,
                'longitude': effectiveLon,
                'source': effectiveSource,
              },
              'cached_alerts_count': cachedAlerts.length,
              'alerts_with_distances': alertsWithDistances,
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown alert action: $action',
              'available': ['alert_create', 'alert_list', 'alert_delete', 'alert_point', 'alert_verify', 'alert_comment', 'alert_add_photo', 'alert_share', 'alert_sync', 'alert_ui_debug'],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Alert action error: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Blog API Endpoints
  // ============================================================

  /// Main handler for all /api/blog/* endpoints
  Future<shelf.Response> _handleBlogRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      String? dataDir;
      try {
        dataDir = StorageConfig().baseDir;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Storage not initialized'}),
          headers: headers,
        );
      }

      String? callsign;
      try {
        final profile = ProfileService().getProfile();
        callsign = profile.callsign;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Profile not initialized'}),
          headers: headers,
        );
      }

      // Check for X-Device-Callsign header (used by proxy)
      // If present, serve that device's blog instead of current user's blog
      final deviceCallsign = request.headers['x-device-callsign'];
      if (deviceCallsign != null && deviceCallsign.isNotEmpty) {
        callsign = deviceCallsign;
        LogService().log('Blog API: Serving blog for device $deviceCallsign (from proxy header)');
      }

      final blogApi = StationBlogApi(
        dataDir: dataDir,
        callsign: callsign,
        log: (level, message) => LogService().log('StationBlogApi [$level]: $message'),
      );

      // Remove 'api/blog' prefix for easier parsing
      String subPath = '';
      if (urlPath.startsWith('api/blog/')) {
        subPath = urlPath.substring('api/blog/'.length);
      } else if (urlPath == 'api/blog' || urlPath == 'api/blog/') {
        subPath = '';
      }

      // Remove trailing slash
      if (subPath.endsWith('/')) {
        subPath = subPath.substring(0, subPath.length - 1);
      }

      // Parse the sub-path to determine the operation
      final pathParts = subPath.isEmpty ? <String>[] : subPath.split('/');

      // Handle POST methods for comments and feedback
      if (request.method == 'POST') {
        if (pathParts.length == 2 && pathParts[1] == 'comment') {
          // POST /api/blog/{postId}/comment
          final postId = pathParts[0];
          return await _handleBlogAddComment(request, postId, blogApi, headers);
        }
        if (pathParts.length == 2 && pathParts[1] == 'like') {
          // POST /api/blog/{postId}/like
          final postId = pathParts[0];
          return await _handleBlogToggleLike(request, postId, blogApi, headers);
        }
        if (pathParts.length == 2 && pathParts[1] == 'point') {
          // POST /api/blog/{postId}/point
          final postId = pathParts[0];
          return await _handleBlogTogglePoint(request, postId, blogApi, headers);
        }
        if (pathParts.length == 2 && pathParts[1] == 'dislike') {
          // POST /api/blog/{postId}/dislike
          final postId = pathParts[0];
          return await _handleBlogToggleDislike(request, postId, blogApi, headers);
        }
        if (pathParts.length == 2 && pathParts[1] == 'subscribe') {
          // POST /api/blog/{postId}/subscribe
          final postId = pathParts[0];
          return await _handleBlogToggleSubscribe(request, postId, blogApi, headers);
        }
        if (pathParts.length == 3 && pathParts[1] == 'react') {
          // POST /api/blog/{postId}/react/{emoji}
          final postId = pathParts[0];
          final emoji = pathParts[2];
          return await _handleBlogToggleReaction(request, postId, emoji, blogApi, headers);
        }
        return shelf.Response(
          405,
          body: jsonEncode({'error': 'Method not allowed for this endpoint'}),
          headers: headers,
        );
      }

      // Handle DELETE methods for comment deletion
      if (request.method == 'DELETE') {
        if (pathParts.length == 3 && pathParts[1] == 'comment') {
          // DELETE /api/blog/{postId}/comment/{commentId}
          final postId = pathParts[0];
          final commentId = pathParts[2];
          return await _handleBlogDeleteComment(request, postId, commentId, blogApi, headers);
        }
        return shelf.Response(
          405,
          body: jsonEncode({'error': 'Method not allowed for this endpoint'}),
          headers: headers,
        );
      }

      // Handle GET methods
      if (request.method != 'GET') {
        return shelf.Response(
          405,
          body: jsonEncode({'error': 'Method not allowed'}),
          headers: headers,
        );
      }

      // GET /api/blog - List all posts
      if (subPath.isEmpty) {
        return await _handleBlogListPosts(request, blogApi, headers);
      }

      if (pathParts.length == 1) {
        // GET /api/blog/{postId} - Get single post with comments
        final postId = pathParts[0];
        return await _handleBlogGetPost(postId, blogApi, headers);
      }

      if (pathParts.length == 2 && pathParts[1] == 'feedback') {
        // GET /api/blog/{postId}/feedback - Get feedback counts and user state
        final postId = pathParts[0];
        final npub = request.url.queryParameters['npub'];
        return await _handleBlogGetFeedback(postId, npub, blogApi, headers);
      }

      if (pathParts.length >= 3 && pathParts[1] == 'files') {
        // GET /api/blog/{postId}/files/{filename} - Get attached file
        final postId = pathParts[0];
        final filename = pathParts.sublist(2).join('/');
        return await _handleBlogGetFile(postId, filename, blogApi, headers);
      }

      return shelf.Response.notFound(
        jsonEncode({'error': 'Blog endpoint not found', 'path': urlPath}),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling blog request: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// GET /api/blog - List all published blog posts
  Future<shelf.Response> _handleBlogListPosts(
    shelf.Request request,
    StationBlogApi blogApi,
    Map<String, String> headers,
  ) async {
    final queryParams = request.url.queryParameters;

    final year = queryParams['year'] != null ? int.tryParse(queryParams['year']!) : null;
    final tag = queryParams['tag'];
    final limit = queryParams['limit'] != null ? int.tryParse(queryParams['limit']!) : null;
    final offset = queryParams['offset'] != null ? int.tryParse(queryParams['offset']!) : null;

    final result = await blogApi.getBlogPosts(
      year: year,
      tag: tag,
      limit: limit,
      offset: offset,
    );

    if (result['success'] == true) {
      return shelf.Response.ok(
        jsonEncode(result),
        headers: headers,
      );
    } else {
      final httpStatus = result['http_status'] as int? ?? 500;
      return shelf.Response(
        httpStatus,
        body: jsonEncode(result),
        headers: headers,
      );
    }
  }

  /// GET /api/blog/{postId} - Get single post with comments
  Future<shelf.Response> _handleBlogGetPost(
    String postId,
    StationBlogApi blogApi,
    Map<String, String> headers,
  ) async {
    final result = await blogApi.getPostDetails(postId);

    if (result['error'] != null) {
      final httpStatus = result['http_status'] as int? ?? 404;
      return shelf.Response(
        httpStatus,
        body: jsonEncode(result),
        headers: headers,
      );
    }

    return shelf.Response.ok(
      jsonEncode(result),
      headers: headers,
    );
  }

  /// GET /api/blog/{postId}/files/{filename} - Get attached file
  Future<shelf.Response> _handleBlogGetFile(
    String postId,
    String filename,
    StationBlogApi blogApi,
    Map<String, String> headers,
  ) async {
    final filePath = await blogApi.getFilePath(postId, filename);

    if (filePath == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'File not found'}),
        headers: headers,
      );
    }

    try {
      final file = io.File(filePath);
      final bytes = await file.readAsBytes();

      // Determine content type
      final ext = path.extension(filename).toLowerCase();
      String contentType = 'application/octet-stream';
      if (ext == '.jpg' || ext == '.jpeg') {
        contentType = 'image/jpeg';
      } else if (ext == '.png') {
        contentType = 'image/png';
      } else if (ext == '.gif') {
        contentType = 'image/gif';
      } else if (ext == '.webp') {
        contentType = 'image/webp';
      } else if (ext == '.pdf') {
        contentType = 'application/pdf';
      } else if (ext == '.txt') {
        contentType = 'text/plain';
      }

      return shelf.Response.ok(
        bytes,
        headers: {
          ...headers,
          'Content-Type': contentType,
          'Content-Length': bytes.length.toString(),
        },
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Failed to read file: $e'}),
        headers: headers,
      );
    }
  }

  /// POST /api/blog/{postId}/comment - Add comment to a post
  Future<shelf.Response> _handleBlogAddComment(
    shelf.Request request,
    String postId,
    StationBlogApi blogApi,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final author = json['author'] as String?;
      final content = json['content'] as String?;
      final npub = json['npub'] as String?;
      final signature = json['signature'] as String?;

      if (author == null || author.isEmpty) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing required field: author'}),
          headers: headers,
        );
      }

      if (content == null || content.isEmpty) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing required field: content'}),
          headers: headers,
        );
      }

      final result = await blogApi.addComment(
        postId,
        author,
        content,
        npub: npub,
        signature: signature,
      );

      if (result['success'] == true) {
        return shelf.Response.ok(
          jsonEncode(result),
          headers: headers,
        );
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(
          httpStatus,
          body: jsonEncode(result),
          headers: headers,
        );
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Invalid request body: $e'}),
        headers: headers,
      );
    }
  }

  /// DELETE /api/blog/{postId}/comment/{commentId} - Delete comment
  Future<shelf.Response> _handleBlogDeleteComment(
    shelf.Request request,
    String postId,
    String commentId,
    StationBlogApi blogApi,
    Map<String, String> headers,
  ) async {
    try {
      // Get requester's npub from header
      final npub = request.headers['x-npub'] ?? request.headers['X-Npub'];

      if (npub == null || npub.isEmpty) {
        return shelf.Response(
          401,
          body: jsonEncode({'error': 'Missing X-Npub header for authorization'}),
          headers: headers,
        );
      }

      final result = await blogApi.deleteComment(postId, commentId, npub);

      if (result['success'] == true) {
        return shelf.Response.ok(
          jsonEncode(result),
          headers: headers,
        );
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(
          httpStatus,
          body: jsonEncode(result),
          headers: headers,
        );
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Error deleting comment: $e'}),
        headers: headers,
      );
    }
  }

  /// GET /api/blog/{postId}/feedback - Get all feedback counts and user state
  Future<shelf.Response> _handleBlogGetFeedback(
    String postId,
    String? npub,
    StationBlogApi blogApi,
    Map<String, String> headers,
  ) async {
    final result = await blogApi.getFeedback(postId, npub: npub);

    if (result['success'] == true) {
      return shelf.Response.ok(
        jsonEncode(result),
        headers: headers,
      );
    } else {
      final httpStatus = result['http_status'] as int? ?? 500;
      return shelf.Response(
        httpStatus,
        body: jsonEncode(result),
        headers: headers,
      );
    }
  }

  /// POST /api/blog/{postId}/like - Toggle like
  Future<shelf.Response> _handleBlogToggleLike(
    shelf.Request request,
    String postId,
    StationBlogApi blogApi,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final eventJson = jsonDecode(body) as Map<String, dynamic>;

      // Validate required fields
      if (!eventJson.containsKey('id') || !eventJson.containsKey('sig')) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing required NOSTR event fields (id, sig)'}),
          headers: headers,
        );
      }

      final result = await blogApi.toggleLike(postId, eventJson);

      if (result['success'] == true) {
        return shelf.Response.ok(
          jsonEncode(result),
          headers: headers,
        );
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(
          httpStatus,
          body: jsonEncode(result),
          headers: headers,
        );
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Invalid request: $e'}),
        headers: headers,
      );
    }
  }

  /// POST /api/blog/{postId}/point - Toggle point
  Future<shelf.Response> _handleBlogTogglePoint(
    shelf.Request request,
    String postId,
    StationBlogApi blogApi,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final eventJson = jsonDecode(body) as Map<String, dynamic>;

      // Validate required fields
      if (!eventJson.containsKey('id') || !eventJson.containsKey('sig')) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing required NOSTR event fields (id, sig)'}),
          headers: headers,
        );
      }

      final result = await blogApi.togglePoint(postId, eventJson);

      if (result['success'] == true) {
        return shelf.Response.ok(
          jsonEncode(result),
          headers: headers,
        );
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(
          httpStatus,
          body: jsonEncode(result),
          headers: headers,
        );
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Invalid request: $e'}),
        headers: headers,
      );
    }
  }

  /// POST /api/blog/{postId}/dislike - Toggle dislike
  Future<shelf.Response> _handleBlogToggleDislike(
    shelf.Request request,
    String postId,
    StationBlogApi blogApi,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final eventJson = jsonDecode(body) as Map<String, dynamic>;

      // Validate required fields
      if (!eventJson.containsKey('id') || !eventJson.containsKey('sig')) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing required NOSTR event fields (id, sig)'}),
          headers: headers,
        );
      }

      final result = await blogApi.toggleDislike(postId, eventJson);

      if (result['success'] == true) {
        return shelf.Response.ok(
          jsonEncode(result),
          headers: headers,
        );
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(
          httpStatus,
          body: jsonEncode(result),
          headers: headers,
        );
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Invalid request: $e'}),
        headers: headers,
      );
    }
  }

  /// POST /api/blog/{postId}/subscribe - Toggle subscribe
  Future<shelf.Response> _handleBlogToggleSubscribe(
    shelf.Request request,
    String postId,
    StationBlogApi blogApi,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final eventJson = jsonDecode(body) as Map<String, dynamic>;

      // Validate required fields
      if (!eventJson.containsKey('id') || !eventJson.containsKey('sig')) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing required NOSTR event fields (id, sig)'}),
          headers: headers,
        );
      }

      final result = await blogApi.toggleSubscribe(postId, eventJson);

      if (result['success'] == true) {
        return shelf.Response.ok(
          jsonEncode(result),
          headers: headers,
        );
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(
          httpStatus,
          body: jsonEncode(result),
          headers: headers,
        );
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Invalid request: $e'}),
        headers: headers,
      );
    }
  }

  /// POST /api/blog/{postId}/react/{emoji} - Toggle emoji reaction
  Future<shelf.Response> _handleBlogToggleReaction(
    shelf.Request request,
    String postId,
    String emoji,
    StationBlogApi blogApi,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final eventJson = jsonDecode(body) as Map<String, dynamic>;

      // Validate required fields
      if (!eventJson.containsKey('id') || !eventJson.containsKey('sig')) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing required NOSTR event fields (id, sig)'}),
          headers: headers,
        );
      }

      final result = await blogApi.toggleReaction(postId, eventJson, emoji);

      if (result['success'] == true) {
        return shelf.Response.ok(
          jsonEncode(result),
          headers: headers,
        );
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(
          httpStatus,
          body: jsonEncode(result),
          headers: headers,
        );
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Invalid request: $e'}),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Blog HTML Rendering
  // ============================================================

  /// Handle GET /{identifier}/blog/{filename}.html - Serve blog post as HTML
  Future<shelf.Response> _handleBlogHtmlRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      // Parse path: {identifier}/blog/{filename}.html
      final parts = urlPath.split('/');
      if (parts.length < 3 || !parts.contains('blog')) {
        return shelf.Response.notFound(
          'Blog post not found',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // Extract filename (without .html extension)
      final filename = parts.last.replaceAll('.html', '');

      // Get current user's callsign and dataDir
      String? callsign;
      String? dataDir;
      String? nickname;

      try {
        final profile = ProfileService().getProfile();
        callsign = profile.callsign;
        nickname = profile.nickname ?? callsign;
      } catch (e) {
        // Profile not initialized
      }

      try {
        dataDir = StorageConfig().baseDir;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: '<html><body><h1>500 Internal Server Error</h1><p>Storage not initialized</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      if (callsign == null) {
        return shelf.Response.internalServerError(
          body: '<html><body><h1>500 Internal Server Error</h1><p>Profile not initialized</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // Check for X-Device-Callsign header (used by proxy)
      // If present, serve that device's blog instead of current user's blog
      final deviceCallsign = request.headers['x-device-callsign'];
      if (deviceCallsign != null && deviceCallsign.isNotEmpty) {
        callsign = deviceCallsign;
        LogService().log('Blog HTML: Serving blog for device $deviceCallsign (from proxy header)');
      }

      // Initialize blog service
      final blogService = BlogService();
      final collectionPath = '$dataDir/devices/$callsign/blog';
      await blogService.initializeCollection(collectionPath);

      // Load the blog post
      final post = await blogService.loadFullPost(filename);

      if (post == null) {
        return shelf.Response.notFound(
          '<html><body><h1>404 Not Found</h1><p>Blog post not found: $filename</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // Only serve published posts
      if (!post.isPublished) {
        return shelf.Response.notFound(
          '<html><body><h1>404 Not Found</h1><p>Blog post not available</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // Render HTML
      final html = _renderBlogPostHtml(post, nickname ?? callsign);

      return shelf.Response.ok(
        html,
        headers: {'Content-Type': 'text/html; charset=utf-8'},
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Error rendering blog HTML: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: '<html><body><h1>500 Internal Server Error</h1><p>$e</p></body></html>',
        headers: {'Content-Type': 'text/html'},
      );
    }
  }

  /// Render blog post as HTML
  String _renderBlogPostHtml(BlogPost post, String authorIdentifier) {
    final buffer = StringBuffer();

    // Basic HTML structure with inline CSS
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html lang="en">');
    buffer.writeln('<head>');
    buffer.writeln('  <meta charset="UTF-8">');
    buffer.writeln('  <meta name="viewport" content="width=device-width, initial-scale=1.0">');
    buffer.writeln('  <title>${_escapeHtml(post.title)} - ${_escapeHtml(authorIdentifier)}</title>');
    buffer.writeln('  <style>');
    buffer.writeln('    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; line-height: 1.6; max-width: 800px; margin: 0 auto; padding: 20px; color: #333; }');
    buffer.writeln('    h1 { border-bottom: 2px solid #007bff; padding-bottom: 10px; }');
    buffer.writeln('    .meta { color: #666; font-size: 0.9em; margin-bottom: 20px; }');
    buffer.writeln('    .tag { background: #e3f2fd; padding: 3px 8px; border-radius: 3px; margin-right: 5px; font-size: 0.85em; }');
    buffer.writeln('    .content { margin: 30px 0; white-space: pre-wrap; }');
    buffer.writeln('    .comments { margin-top: 40px; border-top: 1px solid #ddd; padding-top: 20px; }');
    buffer.writeln('    .comment { margin: 15px 0; padding: 10px; background: #f9f9f9; border-left: 3px solid #007bff; }');
    buffer.writeln('    .comment-meta { font-size: 0.85em; color: #666; margin-bottom: 5px; }');
    buffer.writeln('    .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #ddd; font-size: 0.85em; color: #666; }');
    buffer.writeln('  </style>');
    buffer.writeln('</head>');
    buffer.writeln('<body>');

    // Header
    buffer.writeln('  <h1>${_escapeHtml(post.title)}</h1>');

    // Metadata
    buffer.writeln('  <div class="meta">');
    buffer.writeln('    <strong>Author:</strong> ${_escapeHtml(post.author)} | ');
    buffer.writeln('    <strong>Published:</strong> ${post.displayDate} at ${post.displayTime}');
    if (post.edited != null) {
      buffer.writeln('    | <strong>Edited:</strong> ${_escapeHtml(post.edited!)}');
    }
    buffer.writeln('  </div>');

    // Description
    if (post.description != null && post.description!.isNotEmpty) {
      buffer.writeln('  <div class="meta"><em>${_escapeHtml(post.description!)}</em></div>');
    }

    // Tags
    if (post.tags.isNotEmpty) {
      buffer.writeln('  <div class="meta">');
      for (final tag in post.tags) {
        buffer.writeln('    <span class="tag">${_escapeHtml(tag)}</span>');
      }
      buffer.writeln('  </div>');
    }

    // Content
    buffer.writeln('  <div class="content">${_escapeHtml(post.content)}</div>');

    // Comments
    if (post.comments.isNotEmpty) {
      buffer.writeln('  <div class="comments">');
      buffer.writeln('    <h2>Comments (${post.comments.length})</h2>');
      for (final comment in post.comments) {
        buffer.writeln('    <div class="comment">');
        buffer.writeln('      <div class="comment-meta">');
        buffer.writeln('        <strong>${_escapeHtml(comment.author)}</strong> - ${comment.displayDate} at ${comment.displayTime}');
        buffer.writeln('      </div>');
        buffer.writeln('      <div>${_escapeHtml(comment.content)}</div>');
        buffer.writeln('    </div>');
      }
      buffer.writeln('  </div>');
    }

    // Footer
    buffer.writeln('  <div class="footer">');
    buffer.writeln('    <p>Posted via geogram</p>');
    buffer.writeln('  </div>');

    buffer.writeln('</body>');
    buffer.writeln('</html>');

    return buffer.toString();
  }

  /// Escape HTML special characters
  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }
}
