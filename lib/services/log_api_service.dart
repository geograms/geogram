import 'dart:async';
import 'dart:convert';
import 'dart:io' as io if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'log_service.dart';
import 'profile_service.dart';
import '../version.dart';

class LogApiService {
  static final LogApiService _instance = LogApiService._internal();
  factory LogApiService() => _instance;
  LogApiService._internal();

  // Use dynamic to avoid type conflicts between stub and real dart:io
  dynamic _server;
  final int port = 45678;

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
    } catch (e) {
      LogService().log('LogApiService: Error starting server: $e');
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
      'Access-Control-Allow-Headers': 'Content-Type',
      'Content-Type': 'application/json',
    };

    if (request.method == 'OPTIONS') {
      return shelf.Response.ok('', headers: headers);
    }

    if (request.url.path == 'log' && request.method == 'GET') {
      return _handleLogRequest(request, headers);
    }

    // API status endpoint (for relay discovery compatibility)
    if ((request.url.path == 'api/status' || request.url.path == 'relay/status') &&
        request.method == 'GET') {
      return _handleStatusRequest(headers);
    }

    if (request.url.path == 'files' && request.method == 'GET') {
      return _handleFilesRequest(request, headers);
    }

    if (request.url.path == 'files/content' && request.method == 'GET') {
      return _handleFileContentRequest(request, headers);
    }

    if (request.url.path == '' || request.url.path == '/' && request.method == 'GET') {
      // Get callsign from profile service
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
            '/log': 'Get log entries (supports ?filter=text&limit=100)',
            '/files': 'Browse collections (supports ?path=subfolder)',
            '/files/content': 'Get file content (supports ?path=file/path)',
          },
        }),
        headers: headers,
      );
    }

    return shelf.Response.notFound(
      jsonEncode({'error': 'Not found'}),
      headers: headers,
    );
  }

  /// Handle /api/status and /relay/status for discovery compatibility
  shelf.Response _handleStatusRequest(Map<String, String> headers) {
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
        'type': 'desktop',
        'status': 'online',
        'callsign': callsign,
        'name': callsign.isNotEmpty ? callsign : 'Geogram Desktop',
        'hostname': io.Platform.localHostname,
        'port': port,
      }),
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
}
