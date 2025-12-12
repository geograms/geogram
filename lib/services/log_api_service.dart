import 'dart:async';
import 'dart:convert';
import 'dart:io' as io if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'log_service.dart';
import 'profile_service.dart';
import 'collection_service.dart';
import 'debug_controller.dart';
import 'security_service.dart';
import 'storage_config.dart';
import 'user_location_service.dart';
import 'chat_service.dart';
import 'direct_message_service.dart';
import 'devices_service.dart';
import 'app_args.dart';
import '../version.dart';
import '../models/chat_message.dart';
import '../util/nostr_event.dart';
import 'audio_service.dart';
import 'backup_service.dart';
import '../models/backup_models.dart';
import 'event_service.dart';
import '../models/report.dart';

class LogApiService {
  static final LogApiService _instance = LogApiService._internal();
  factory LogApiService() => _instance;
  LogApiService._internal();

  // Use dynamic to avoid type conflicts between stub and real dart:io
  dynamic _server;

  /// Track when the service started for uptime calculation
  DateTime? _startTime;

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
    if ((urlPath == 'api/chat' || urlPath == 'api/chat/') && request.method == 'GET') {
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
        'type': 'geogram-desktop',
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
    // Pattern: api/chat/{roomId}/messages or api/chat/{roomId}/files
    final regex = RegExp(r'^api/chat/([^/]+)/(messages|files)$');
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
      // Try to lazily initialize ChatService if not already done
      await _initializeChatServiceIfNeeded();

      final chatService = ChatService();

      // Check if chat service is initialized
      if (chatService.collectionPath == null) {
        return shelf.Response.ok(
          jsonEncode({
            'rooms': [],
            'total': 0,
            'authenticated': false,
            'message': 'No chat collection loaded',
          }),
          headers: headers,
        );
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

  /// Handle GET /api/chat/rooms/{roomId}/messages - Get messages from a room
  Future<shelf.Response> _handleChatMessagesRequest(
    shelf.Request request,
    String roomId,
    Map<String, String> headers,
  ) async {
    try {
      // Check if roomId looks like a callsign (uppercase alphanumeric)
      // If so, this is a DM channel - use DirectMessageService
      final isCallsignLike = RegExp(r'^[A-Z0-9]{3,}$').hasMatch(roomId.toUpperCase());

      if (isCallsignLike) {
        // This is a DM request - use DirectMessageService
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

      // Regular chat room - use ChatService
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
      // Check if roomId looks like a callsign (uppercase alphanumeric)
      // If so, this is a DM channel - route through DirectMessageService
      final isCallsignLike = RegExp(r'^[A-Z0-9]{3,}$').hasMatch(roomId.toUpperCase());

      if (isCallsignLike) {
        // This is a DM request - handle via DirectMessageService
        return await _handleDMViaChatAPI(request, roomId.toUpperCase(), headers);
      }

      // Regular chat room - use ChatService
      await _initializeChatServiceIfNeeded();

      final chatService = ChatService();

      // Check if chat service is initialized
      if (chatService.collectionPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'No chat collection loaded'}),
          headers: headers,
        );
      }

      // Check if room exists
      final channel = chatService.getChannel(roomId);
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
      // Order: created_at, npub, event_id, signature (signature last for readability)
      final metadata = <String, String>{};
      if (createdAt != null) metadata['created_at'] = createdAt.toString();
      if (npub != null) metadata['npub'] = npub;
      if (eventId != null) metadata['event_id'] = eventId;
      if (signature != null) metadata['signature'] = signature;

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
      final regex = RegExp(r'^api/chat/([^/]+)/messages/(.+)$');
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
    if (request.method != 'GET') {
      return shelf.Response(
        405,
        body: jsonEncode({'error': 'Method not allowed. Events API is read-only.'}),
        headers: headers,
      );
    }

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
        return await _handleEventsListEvents(request, dataDir, headers);
      }

      // Parse the sub-path to determine the operation
      final pathParts = subPath.split('/');

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
  // Alerts API Endpoints (public read-only access)
  // ============================================================

  /// Main handler for all /api/alerts/* endpoints
  Future<shelf.Response> _handleAlertsRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    if (request.method != 'GET') {
      return shelf.Response(
        405,
        body: jsonEncode({'error': 'Method not allowed. Alerts API is read-only.'}),
        headers: headers,
      );
    }

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

      // GET /api/alerts - List all alerts
      if (subPath.isEmpty) {
        return await _handleAlertsListAlerts(request, dataDir, headers);
      }

      // Parse the sub-path to determine the operation
      final pathParts = subPath.split('/');

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

    if (!await devicesDir.exists()) return alerts;

    // Scan all devices/{callsign}/alerts/
    await for (final deviceEntity in devicesDir.list()) {
      if (deviceEntity is! io.Directory) continue;

      final alertsDir = io.Directory('${deviceEntity.path}/alerts');
      if (!await alertsDir.exists()) continue;

      await for (final alertEntity in alertsDir.list()) {
        if (alertEntity is! io.Directory) continue;

        // File is named report.txt for backwards compatibility
        final alertFile = io.File('${alertEntity.path}/report.txt');
        if (!await alertFile.exists()) continue;

        try {
          final content = await alertFile.readAsString();
          final alert = Report.fromText(content, alertEntity.path.split('/').last);

          // Apply status filter
          if (status != null && alert.status.toFileString() != status) continue;

          // Apply geographic filter
          if (lat != null && lon != null && radius != null) {
            final distance = _calculateHaversineDistance(
              lat, lon, alert.latitude, alert.longitude,
            );
            if (distance > radius) continue;
          }

          alerts.add((alert, alertEntity.path));
        } catch (e) {
          // Skip malformed alerts
          LogService().log('LogApiService: Error parsing alert ${alertEntity.path}: $e');
        }
      }
    }

    // Sort by date (newest first)
    alerts.sort((a, b) => b.$1.dateTime.compareTo(a.$1.dateTime));
    return alerts;
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

      await for (final alertEntity in alertsDir.list()) {
        if (alertEntity is! io.Directory) continue;

        final alertFile = io.File('${alertEntity.path}/report.txt');
        if (!await alertFile.exists()) continue;

        try {
          final content = await alertFile.readAsString();
          final alert = Report.fromText(content, alertEntity.path.split('/').last);

          // Check if this alert's apiId matches
          if (alert.apiId == apiId) {
            return (alert, alertEntity.path);
          }
        } catch (e) {
          // Skip malformed alerts
        }
      }
    }
    return null;
  }

  /// Check if an alert has photos
  Future<bool> _alertHasPhotos(String alertPath) async {
    final dir = io.Directory(alertPath);
    if (!await dir.exists()) return false;

    await for (final entity in dir.list()) {
      if (entity is io.File) {
        final ext = path.extension(entity.path).toLowerCase();
        if (['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Get list of photo filenames in an alert directory
  Future<List<String>> _getAlertPhotos(String alertPath) async {
    final photos = <String>[];
    final dir = io.Directory(alertPath);
    if (!await dir.exists()) return photos;

    await for (final entity in dir.list()) {
      if (entity is io.File) {
        final ext = path.extension(entity.path).toLowerCase();
        if (['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext)) {
          photos.add(path.basename(entity.path));
        }
      }
    }

    photos.sort();
    return photos;
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

          // Create alert folder name (lat_lon_title format for backwards compatibility)
          final latStr = latitude.toStringAsFixed(4).replaceAll('.', '_').replaceAll('-', 'n');
          final lonStr = longitude.toStringAsFixed(4).replaceAll('.', '_').replaceAll('-', 'n');
          final titleSlug = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
          final folderName = '${latStr}_${lonStr}_$titleSlug';

          // Create the alert directory
          final alertDir = io.Directory('$dataDir/devices/$callsign/alerts/$folderName');
          await alertDir.create(recursive: true);

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
              'message': 'Alert created',
              'alert': alert.toApiJson(),
            }),
            headers: headers,
          );

        case 'alert_list':
          // List all alerts via the helper
          final status = params['status'] as String?;
          final lat = (params['lat'] as num?)?.toDouble();
          final lon = (params['lon'] as num?)?.toDouble();
          final radius = (params['radius'] as num?)?.toDouble();

          final alertsWithPaths = await _getAllAlertsGlobal(
            dataDir,
            status: status,
            lat: lat,
            lon: lon,
            radius: radius,
          );

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

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown alert action: $action',
              'available': ['alert_create', 'alert_list', 'alert_delete'],
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
}
