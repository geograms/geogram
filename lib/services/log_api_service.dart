import 'dart:async';
import 'dart:convert';
import 'dart:io' as io if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'log_service.dart';
import 'profile_service.dart';
import 'collection_service.dart';
import 'debug_controller.dart';
import 'security_service.dart';
import 'user_location_service.dart';
import 'chat_service.dart';
import 'direct_message_service.dart';
import 'devices_service.dart';
import 'app_args.dart';
import '../version.dart';
import '../models/chat_message.dart';
import '../util/nostr_event.dart';

class LogApiService {
  static final LogApiService _instance = LogApiService._internal();
  factory LogApiService() => _instance;
  LogApiService._internal();

  // Use dynamic to avoid type conflicts between stub and real dart:io
  dynamic _server;

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
  Future<bool> _initializeChatServiceIfNeeded() async {
    try {
      final chatService = ChatService();

      // Already initialized
      if (chatService.collectionPath != null) {
        return true;
      }

      // Find chat collection in active profile's directory
      final collectionsDir = CollectionService().collectionsDirectory;
      if (collectionsDir == null) {
        return false;
      }

      final chatDir = io.Directory('$collectionsDir/chat');
      if (!await chatDir.exists()) {
        return false;
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
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
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

    try {
      final profile = ProfileService().getProfile();
      callsign = profile.callsign;
      nickname = profile.nickname;
      color = profile.preferredColor;

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

    // Admin can access everything
    final security = chatService.security;
    if (npub != null && security.isAdmin(npub)) {
      return true;
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
        // Check if user can access this room
        final canAccess = await _canAccessChatRoom(channel.id, authNpub);

        // Only include rooms the user can access (or public rooms)
        final visibility = channel.config?.visibility ?? 'PUBLIC';
        if (!canAccess && visibility != 'PUBLIC') {
          continue;
        }

        rooms.add({
          'id': channel.id,
          'name': channel.name,
          'description': channel.description,
          'type': channel.isMain ? 'main' : (channel.isDirect ? 'direct' : 'group'),
          'visibility': visibility,
          'participants': channel.participants,
          'lastMessage': channel.lastMessageTime?.toIso8601String(),
          'folder': channel.folder,
        });
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
}
