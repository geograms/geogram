import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'log_service.dart';

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
        io.InternetAddress.loopbackIPv4,
        port,
      );

      LogService().log('LogApiService: Started on http://localhost:$port');
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

    if (request.url.path == '' || request.url.path == '/' && request.method == 'GET') {
      return shelf.Response.ok(
        jsonEncode({
          'service': 'Geogram Desktop Log API',
          'version': '1.0.0',
          'endpoints': {
            '/log': 'Get log entries (supports ?filter=text&limit=100)',
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
}
