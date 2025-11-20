import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/collection_service.dart';
import '../util/nostr_event.dart';
import '../util/tlsh.dart';

/// WebSocket service for relay connections
class WebSocketService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  /// Connect to relay and send hello
  Future<bool> connectAndHello(String url) async {
    try {
      LogService().log('══════════════════════════════════════');
      LogService().log('CONNECTING TO RELAY');
      LogService().log('══════════════════════════════════════');
      LogService().log('URL: $url');

      // Connect to WebSocket
      final uri = Uri.parse(url);
      _channel = WebSocketChannel.connect(uri);

      LogService().log('✓ WebSocket connected');

      // Get user profile
      final profile = ProfileService().getProfile();
      LogService().log('User callsign: ${profile.callsign}');
      LogService().log('User npub: ${profile.npub.substring(0, 20)}...');

      // Create hello event
      final event = NostrEvent.createHello(
        npub: profile.npub,
        callsign: profile.callsign,
      );
      event.calculateId();
      event.sign(profile.nsec);

      // Build hello message
      final helloMessage = {
        'type': 'hello',
        'event': event.toJson(),
      };

      final helloJson = jsonEncode(helloMessage);
      LogService().log('');
      LogService().log('SENDING HELLO MESSAGE');
      LogService().log('══════════════════════════════════════');
      LogService().log('Message type: hello');
      LogService().log('Event ID: ${event.id?.substring(0, 16)}...');
      LogService().log('Callsign: ${profile.callsign}');
      LogService().log('Content: ${event.content}');
      LogService().log('');
      LogService().log('Full message:');
      LogService().log(helloJson);
      LogService().log('══════════════════════════════════════');

      // Send hello
      _channel!.sink.add(helloJson);

      // Listen for messages
      _subscription = _channel!.stream.listen(
        (message) {
          try {
            LogService().log('');
            LogService().log('RECEIVED MESSAGE FROM RELAY');
            LogService().log('══════════════════════════════════════');
            LogService().log('Raw message: $message');

            final data = jsonDecode(message as String) as Map<String, dynamic>;
            LogService().log('Message type: ${data['type']}');

            if (data['type'] == 'hello_ack') {
              final success = data['success'] as bool? ?? false;
              if (success) {
                LogService().log('✓ Hello acknowledged!');
                LogService().log('Relay ID: ${data['relay_id']}');
                LogService().log('Message: ${data['message']}');
                LogService().log('══════════════════════════════════════');
              } else {
                LogService().log('✗ Hello rejected');
                LogService().log('Reason: ${data['message']}');
                LogService().log('══════════════════════════════════════');
              }
            } else if (data['type'] == 'COLLECTIONS_REQUEST') {
              LogService().log('✓ Relay requested collections');
              _handleCollectionsRequest(data['requestId'] as String?);
            } else if (data['type'] == 'COLLECTION_FILE_REQUEST') {
              LogService().log('✓ Relay requested collection file');
              _handleCollectionFileRequest(
                data['requestId'] as String?,
                data['collectionName'] as String?,
                data['fileName'] as String?,
              );
            } else if (data['type'] == 'HTTP_REQUEST') {
              LogService().log('✓ Relay forwarded HTTP request');
              _handleHttpRequest(
                data['requestId'] as String?,
                data['method'] as String?,
                data['path'] as String?,
                data['headers'] as String?,
                data['body'] as String?,
              );
            }

            _messageController.add(data);
          } catch (e) {
            LogService().log('Error parsing message: $e');
          }
        },
        onError: (error) {
          LogService().log('WebSocket error: $error');
        },
        onDone: () {
          LogService().log('WebSocket connection closed');
        },
      );

      // Wait a bit for response
      await Future.delayed(const Duration(seconds: 2));
      return true;

    } catch (e) {
      LogService().log('');
      LogService().log('CONNECTION ERROR');
      LogService().log('══════════════════════════════════════');
      LogService().log('Error: $e');
      LogService().log('══════════════════════════════════════');
      return false;
    }
  }

  /// Disconnect from relay
  void disconnect() {
    LogService().log('Disconnecting from relay...');
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
    _subscription = null;
  }

  /// Send message to relay
  void send(Map<String, dynamic> message) {
    if (_channel != null) {
      final json = jsonEncode(message);
      LogService().log('Sending to relay: $json');
      _channel!.sink.add(json);
    }
  }

  /// Check if connected
  bool get isConnected => _channel != null;

  /// Handle collections request from relay
  Future<void> _handleCollectionsRequest(String? requestId) async {
    if (requestId == null) return;

    try {
      final collections = await CollectionService().loadCollections();

      // Filter out private collections - only share public and restricted ones
      final publicCollections = collections
          .where((c) => c.visibility != 'private')
          .toList();

      final collectionNames = publicCollections.map((c) => c.title).toList();

      final response = {
        'type': 'COLLECTIONS_RESPONSE',
        'requestId': requestId,
        'collections': collectionNames,
      };

      send(response);
      LogService().log('Sent ${collectionNames.length} collection names to relay (filtered ${collections.length - publicCollections.length} private collections)');
    } catch (e) {
      LogService().log('Error handling collections request: $e');
    }
  }

  /// Handle collection file request from relay
  Future<void> _handleCollectionFileRequest(
    String? requestId,
    String? collectionName,
    String? fileName,
  ) async {
    if (requestId == null || collectionName == null || fileName == null) return;

    try {
      final collections = await CollectionService().loadCollections();
      final collection = collections.firstWhere(
        (c) => c.title == collectionName,
        orElse: () => throw Exception('Collection not found: $collectionName'),
      );

      // Security check: reject access to private collections
      if (collection.visibility == 'private') {
        LogService().log('⚠ Rejected file request for private collection: $collectionName');
        throw Exception('Access denied: Collection is private');
      }

      String fileContent;
      String actualFileName;

      final storagePath = collection.storagePath;
      if (storagePath == null) {
        throw Exception('Collection has no storage path: $collectionName');
      }

      if (fileName == 'collection') {
        final file = File('$storagePath/collection.js');
        fileContent = await file.readAsString();
        actualFileName = 'collection.js';
      } else if (fileName == 'tree') {
        // Read tree.json from disk (pre-generated)
        final file = File('$storagePath/extra/tree.json');
        if (!await file.exists()) {
          throw Exception('tree.json not found for collection: $collectionName');
        }
        fileContent = await file.readAsString();
        actualFileName = 'extra/tree.json';
      } else if (fileName == 'data') {
        // Read data.js from disk (pre-generated)
        final file = File('$storagePath/extra/data.js');
        if (!await file.exists()) {
          throw Exception('data.js not found for collection: $collectionName');
        }
        fileContent = await file.readAsString();
        actualFileName = 'extra/data.js';
      } else {
        throw Exception('Unknown file: $fileName');
      }

      final response = {
        'type': 'COLLECTION_FILE_RESPONSE',
        'requestId': requestId,
        'collectionName': collectionName,
        'fileName': actualFileName,
        'fileContent': fileContent,
      };

      send(response);
      LogService().log('Sent $fileName for collection $collectionName (${fileContent.length} bytes)');
    } catch (e) {
      LogService().log('Error handling collection file request: $e');
    }
  }

  /// Handle HTTP request from relay (for www collection proxying)
  Future<void> _handleHttpRequest(
    String? requestId,
    String? method,
    String? path,
    String? headersJson,
    String? body,
  ) async {
    if (requestId == null || method == null || path == null) {
      LogService().log('Invalid HTTP request: missing parameters');
      return;
    }

    try {
      LogService().log('HTTP Request: $method $path');

      // Parse path: should be /collections/{collectionName}/{filePath}
      final parts = path.split('/').where((p) => p.isNotEmpty).toList();
      if (parts.length < 2 || parts[0] != 'collections') {
        throw Exception('Invalid path format: $path');
      }

      final collectionName = parts[1];
      final filePath = parts.length > 2 ? '/${parts.sublist(2).join('/')}' : '/';

      // Load collection
      final collections = await CollectionService().loadCollections();
      final collection = collections.firstWhere(
        (c) => c.title == collectionName,
        orElse: () => throw Exception('Collection not found: $collectionName'),
      );

      // Security check: reject access to private collections
      if (collection.visibility == 'private') {
        LogService().log('⚠ Rejected HTTP request for private collection: $collectionName');
        _sendHttpResponse(requestId, 403, {'Content-Type': 'text/plain'}, 'Forbidden');
        return;
      }

      final storagePath = collection.storagePath;
      if (storagePath == null) {
        throw Exception('Collection has no storage path: $collectionName');
      }

      // Construct file path
      final fullPath = '$storagePath$filePath';
      final file = File(fullPath);

      if (!await file.exists()) {
        LogService().log('File not found: $fullPath');
        _sendHttpResponse(requestId, 404, {'Content-Type': 'text/plain'}, 'Not Found');
        return;
      }

      // Read file content
      final fileBytes = await file.readAsBytes();
      final fileContent = base64Encode(fileBytes);

      // Determine content type
      final contentType = _getContentType(filePath);

      // Send successful response
      _sendHttpResponse(
        requestId,
        200,
        {'Content-Type': contentType},
        fileContent,
        isBase64: true,
      );

      LogService().log('Sent HTTP response: 200 OK (${fileBytes.length} bytes)');
    } catch (e) {
      LogService().log('Error handling HTTP request: $e');
      _sendHttpResponse(requestId, 500, {'Content-Type': 'text/plain'}, 'Internal Server Error: $e');
    }
  }

  /// Send HTTP response to relay
  void _sendHttpResponse(
    String requestId,
    int statusCode,
    Map<String, String> headers,
    String body, {
    bool isBase64 = false,
  }) {
    final response = {
      'type': 'HTTP_RESPONSE',
      'requestId': requestId,
      'statusCode': statusCode,
      'responseHeaders': jsonEncode(headers),
      'responseBody': body,
      'isBase64': isBase64,
    };

    send(response);
  }

  /// Get content type based on file extension
  String _getContentType(String filePath) {
    final ext = filePath.toLowerCase().split('.').last;
    switch (ext) {
      case 'html':
      case 'htm':
        return 'text/html';
      case 'css':
        return 'text/css';
      case 'js':
        return 'application/javascript';
      case 'json':
        return 'application/json';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'svg':
        return 'image/svg+xml';
      case 'ico':
        return 'image/x-icon';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  /// Cleanup
  void dispose() {
    disconnect();
    _messageController.close();
  }
}
