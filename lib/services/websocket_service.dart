import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:markdown/markdown.dart' as md;
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/collection_service.dart';
import '../util/nostr_event.dart';
import '../util/tlsh.dart';
import '../models/update_notification.dart';
import '../models/blog_post.dart';

/// WebSocket service for relay connections
class WebSocketService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _updateController = StreamController<UpdateNotification>.broadcast();
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  String? _relayUrl;
  bool _shouldReconnect = false;
  bool _isReconnecting = false;

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<UpdateNotification> get updates => _updateController.stream;

  /// Connect to relay and send hello
  Future<bool> connectAndHello(String url) async {
    try {
      // Store URL for reconnection
      _relayUrl = url;
      _shouldReconnect = true;

      LogService().log('══════════════════════════════════════');
      LogService().log('CONNECTING TO RELAY');
      LogService().log('══════════════════════════════════════');
      LogService().log('URL: $url');

      // Connect to WebSocket
      final uri = Uri.parse(url);
      _channel = WebSocketChannel.connect(uri);

      LogService().log('✓ WebSocket connected');

      // Start reconnection monitoring
      _startReconnectTimer();

      // Start heartbeat (ping) timer
      _startPingTimer();

      // Get user profile
      final profile = ProfileService().getProfile();
      LogService().log('User callsign: ${profile.callsign}');
      LogService().log('User npub: ${profile.npub.substring(0, 20)}...');

      // Create hello event (include nickname for friendly URL support)
      final event = NostrEvent.createHello(
        npub: profile.npub,
        callsign: profile.callsign,
        nickname: profile.nickname,
      );
      event.calculateId();
      event.signWithNsec(profile.nsec);

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
      if (profile.nickname.isNotEmpty) {
        LogService().log('Nickname: ${profile.nickname}');
      }
      LogService().log('Content: ${event.content}');
      LogService().log('');
      LogService().log('Full message:');
      LogService().log(helloJson);
      LogService().log('══════════════════════════════════════');

      // Send hello
      try {
        _channel!.sink.add(helloJson);
      } catch (e) {
        LogService().log('Error sending hello: $e');
        _handleConnectionLoss();
        return false;
      }

      // Listen for messages
      _subscription = _channel!.stream.listen(
        (message) {
          try {
            final rawMessage = message as String;

            // Handle lightweight UPDATE notifications (plain string, not JSON)
            if (rawMessage.startsWith('UPDATE:')) {
              final update = UpdateNotification.parse(rawMessage);
              if (update != null) {
                print('');
                print('╔══════════════════════════════════════════════════════════════╗');
                print('║  RECEIVED UPDATE NOTIFICATION                                ║');
                print('╠══════════════════════════════════════════════════════════════╣');
                print('║  From relay: ${update.callsign}');
                print('║  Type: ${update.collectionType}');
                print('║  Path: ${update.path}');
                print('╚══════════════════════════════════════════════════════════════╝');
                print('');
                _updateController.add(update);
              }
              return;
            }

            LogService().log('');
            LogService().log('RECEIVED MESSAGE FROM RELAY');
            LogService().log('══════════════════════════════════════');
            LogService().log('Raw message: $rawMessage');

            final data = jsonDecode(rawMessage) as Map<String, dynamic>;
            LogService().log('Message type: ${data['type']}');

            if (data['type'] == 'PONG') {
              // Heartbeat response - connection is alive
              LogService().log('✓ PONG received from relay');
            } else if (data['type'] == 'hello_ack') {
              final success = data['success'] as bool? ?? false;
              if (success) {
                LogService().log('✓ Hello acknowledged!');
                LogService().log('Relay ID: ${data['relay_id']}');
                LogService().log('Message: ${data['message']}');
                LogService().log('══════════════════════════════════════');
                _isReconnecting = false; // Reset reconnecting flag on successful connection
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
          _handleConnectionLoss();
        },
        onDone: () {
          LogService().log('WebSocket connection closed');
          _handleConnectionLoss();
        },
        cancelOnError: true,
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
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _subscription?.cancel();
    try {
      _channel?.sink.close();
    } catch (e) {
      // Ignore errors when closing - connection might already be closed
    }
    _channel = null;
    _subscription = null;
  }

  /// Send message to relay
  void send(Map<String, dynamic> message) {
    if (_channel != null) {
      try {
        final json = jsonEncode(message);
        LogService().log('Sending to relay: $json');
        _channel!.sink.add(json);
      } catch (e) {
        LogService().log('Error sending message: $e');
        _handleConnectionLoss();
      }
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

      // Extract folder names from storage paths (raw names for navigation)
      final collectionNames = publicCollections.map((c) {
        if (c.storagePath != null) {
          // Get the last segment of the path as folder name
          final path = c.storagePath!;
          final segments = path.split('/').where((s) => s.isNotEmpty).toList();
          return segments.isNotEmpty ? segments.last : c.title;
        }
        return c.title;
      }).toList();

      final response = {
        'type': 'COLLECTIONS_RESPONSE',
        'requestId': requestId,
        'collections': collectionNames,
      };

      send(response);
      LogService().log('Sent ${collectionNames.length} collection folder names to relay (filtered ${collections.length - publicCollections.length} private collections)');
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
      // Match by folder name (last segment of storagePath) instead of title
      final collection = collections.firstWhere(
        (c) {
          if (c.storagePath != null) {
            final segments = c.storagePath!.split('/').where((s) => s.isNotEmpty).toList();
            final folderName = segments.isNotEmpty ? segments.last : '';
            return folderName == collectionName;
          }
          return c.title == collectionName;
        },
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

  /// Handle HTTP request from relay (for www collection proxying and blog API)
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

      // Check if this is a blog API request
      if (path.startsWith('/api/blog/')) {
        await _handleBlogApiRequest(requestId, path);
        return;
      }

      // Parse path: should be /collections/{collectionName}/{filePath}
      final parts = path.split('/').where((p) => p.isNotEmpty).toList();
      if (parts.length < 2 || parts[0] != 'collections') {
        throw Exception('Invalid path format: $path');
      }

      final collectionName = parts[1];
      final filePath = parts.length > 2 ? '/${parts.sublist(2).join('/')}' : '/';

      // Load collection - match by folder name (last segment of storagePath)
      final collections = await CollectionService().loadCollections();
      final collection = collections.firstWhere(
        (c) {
          if (c.storagePath != null) {
            final segments = c.storagePath!.split('/').where((s) => s.isNotEmpty).toList();
            final folderName = segments.isNotEmpty ? segments.last : '';
            return folderName == collectionName;
          }
          return c.title == collectionName;
        },
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

  /// Handle blog API request from relay
  /// Path format: /api/blog/{filename}.html
  Future<void> _handleBlogApiRequest(String requestId, String path) async {
    try {
      // Extract filename from path: /api/blog/2025-12-04_hello-everyone.html
      final regex = RegExp(r'^/api/blog/([^/]+)\.html$');
      final match = regex.firstMatch(path);

      if (match == null) {
        _sendHttpResponse(requestId, 400, {'Content-Type': 'text/plain'}, 'Invalid blog path');
        return;
      }

      final filename = match.group(1)!;  // e.g., "2025-12-04_hello-everyone"

      // Extract year from filename (format: YYYY-MM-DD_title)
      final yearMatch = RegExp(r'^(\d{4})-').firstMatch(filename);
      if (yearMatch == null) {
        _sendHttpResponse(requestId, 400, {'Content-Type': 'text/plain'}, 'Invalid blog filename format');
        return;
      }
      final year = yearMatch.group(1)!;

      // Search for blog post in all public collections
      final collections = await CollectionService().loadCollections();
      BlogPost? foundPost;
      String? collectionName;

      for (final collection in collections) {
        // Skip private collections
        if (collection.visibility == 'private') continue;

        final storagePath = collection.storagePath;
        if (storagePath == null) continue;

        final blogPath = '$storagePath/blog/$year/$filename.md';
        final blogFile = File(blogPath);

        if (await blogFile.exists()) {
          try {
            final content = await blogFile.readAsString();
            foundPost = BlogPost.fromText(content, filename);
            collectionName = collection.title;
            break;
          } catch (e) {
            LogService().log('Error parsing blog file: $e');
          }
        }
      }

      if (foundPost == null) {
        _sendHttpResponse(requestId, 404, {'Content-Type': 'text/plain'}, 'Blog post not found');
        return;
      }

      // Only serve published posts
      if (foundPost.isDraft) {
        _sendHttpResponse(requestId, 403, {'Content-Type': 'text/plain'}, 'This post is not published');
        return;
      }

      // Get user profile for author info
      final profile = ProfileService().getProfile();
      final author = profile.nickname.isNotEmpty ? profile.nickname : profile.callsign;

      // Convert markdown content to HTML
      final htmlContent = md.markdownToHtml(
        foundPost.content,
        extensionSet: md.ExtensionSet.gitHubWeb,
      );

      // Build full HTML page
      final html = _buildBlogHtmlPage(foundPost, htmlContent, author);

      _sendHttpResponse(requestId, 200, {'Content-Type': 'text/html'}, html);
      LogService().log('Sent blog post: ${foundPost.title} (${html.length} bytes)');
    } catch (e) {
      LogService().log('Error handling blog API request: $e');
      _sendHttpResponse(requestId, 500, {'Content-Type': 'text/plain'}, 'Internal Server Error: $e');
    }
  }

  /// Build HTML page for blog post
  String _buildBlogHtmlPage(BlogPost post, String htmlContent, String author) {
    final tagsHtml = post.tags.isNotEmpty
        ? '<div class="tags">${post.tags.map((t) => '<span class="tag">#$t</span>').join(' ')}</div>'
        : '';

    return '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${_escapeHtml(post.title)} - $author</title>
  <style>
    * { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
      line-height: 1.6;
      max-width: 800px;
      margin: 0 auto;
      padding: 20px;
      background: #fafafa;
      color: #333;
    }
    article {
      background: white;
      padding: 40px;
      border-radius: 8px;
      box-shadow: 0 2px 8px rgba(0,0,0,0.1);
    }
    h1 { margin-top: 0; color: #1a1a1a; }
    .meta {
      color: #666;
      font-size: 14px;
      margin-bottom: 20px;
      padding-bottom: 20px;
      border-bottom: 1px solid #eee;
    }
    .tags { margin-top: 10px; }
    .tag {
      display: inline-block;
      background: #e0f0ff;
      color: #0066cc;
      padding: 2px 8px;
      border-radius: 4px;
      font-size: 12px;
      margin-right: 5px;
    }
    img { max-width: 100%; height: auto; }
    code {
      background: #f4f4f4;
      padding: 2px 6px;
      border-radius: 3px;
      font-family: 'SF Mono', Monaco, monospace;
    }
    pre {
      background: #2d2d2d;
      color: #f8f8f2;
      padding: 16px;
      border-radius: 6px;
      overflow-x: auto;
    }
    pre code { background: none; padding: 0; color: inherit; }
    blockquote {
      border-left: 4px solid #0066cc;
      margin: 20px 0;
      padding-left: 20px;
      color: #555;
    }
    a { color: #0066cc; }
    footer {
      margin-top: 40px;
      padding-top: 20px;
      border-top: 1px solid #eee;
      text-align: center;
      font-size: 12px;
      color: #999;
    }
  </style>
</head>
<body>
  <article>
    <h1>${_escapeHtml(post.title)}</h1>
    <div class="meta">
      <span>By <strong>$author</strong></span>
      <span> · </span>
      <span>${post.displayDate}</span>
      $tagsHtml
    </div>
    <div class="content">
      $htmlContent
    </div>
  </article>
  <footer>
    Powered by <a href="https://geogram.radio">geogram</a>
  </footer>
</body>
</html>''';
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

  /// Start reconnection monitoring timer
  void _startReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _checkConnection();
    });
  }

  /// Start heartbeat ping timer
  void _startPingTimer() {
    _pingTimer?.cancel();
    // Send PING every 60 seconds (well before the 5-minute idle timeout)
    _pingTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      _sendPing();
    });
  }

  /// Send PING message to keep connection alive
  void _sendPing() {
    if (_channel != null && _shouldReconnect) {
      try {
        final pingMessage = {
          'type': 'PING',
        };
        final json = jsonEncode(pingMessage);
        _channel!.sink.add(json);
        LogService().log('Sent PING to relay');
      } catch (e) {
        LogService().log('Error sending PING: $e');
      }
    }
  }

  /// Check connection and attempt reconnection if needed
  void _checkConnection() {
    if (!_shouldReconnect || _isReconnecting) {
      return;
    }

    // Check if channel is still active
    if (_channel == null) {
      LogService().log('Connection lost - attempting reconnection...');
      _attemptReconnect();
    }
  }

  /// Handle connection loss
  void _handleConnectionLoss() {
    if (!_shouldReconnect || _isReconnecting) {
      return;
    }

    _channel = null;
    _subscription?.cancel();
    _subscription = null;

    LogService().log('Connection lost - will attempt reconnection in 10 seconds');
  }

  /// Attempt to reconnect to relay
  Future<void> _attemptReconnect() async {
    if (!_shouldReconnect || _isReconnecting || _relayUrl == null) {
      return;
    }

    _isReconnecting = true;
    LogService().log('Attempting to reconnect to relay...');

    try {
      await connectAndHello(_relayUrl!);
      LogService().log('✓ Reconnection successful!');
    } catch (e) {
      LogService().log('✗ Reconnection failed: $e');
      _isReconnecting = false;
    }
  }

  /// Cleanup
  void dispose() {
    disconnect();
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _messageController.close();
    _updateController.close();
  }
}
