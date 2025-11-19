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
      final collectionNames = collections.map((c) => c.title).toList();

      final response = {
        'type': 'COLLECTIONS_RESPONSE',
        'requestId': requestId,
        'collections': collectionNames,
      };

      send(response);
      LogService().log('Sent ${collectionNames.length} collection names to relay');
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

      String fileContent;
      String actualFileName;

      if (fileName == 'collection') {
        final file = File('${collection.storagePath}/collection.js');
        fileContent = await file.readAsString();
        actualFileName = 'collection.js';
      } else if (fileName == 'tree-data') {
        // Generate tree-data dynamically by scanning collection directory
        final treeData = await _generateTreeData(collection.storagePath);
        fileContent = treeData;
        actualFileName = 'extra/tree-data.js';
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

  /// Generate tree-data.js dynamically by scanning collection directory
  Future<String> _generateTreeData(String collectionPath) async {
    final entries = <Map<String, dynamic>>[];
    final collectionDir = Directory(collectionPath);

    // Recursively scan all files and directories
    await for (var entity in collectionDir.list(recursive: true, followLinks: false)) {
      // Skip hidden files, metadata files, and the extra directory itself
      final relativePath = entity.path.substring(collectionPath.length + 1);
      if (relativePath.startsWith('.') ||
          relativePath == 'collection.js' ||
          relativePath == 'extra' ||
          relativePath.startsWith('extra/')) {
        continue;
      }

      if (entity is Directory) {
        entries.add({
          'path': relativePath,
          'name': entity.path.split('/').last,
          'type': 'directory',
        });
      } else if (entity is File) {
        final stat = await entity.stat();
        final bytes = await entity.readAsBytes();
        final sha1Hash = sha1.convert(bytes).toString();
        final mimeType = lookupMimeType(entity.path) ?? 'application/octet-stream';

        // Calculate TLSH (Trend Micro Locality Sensitive Hash)
        // TLSH is used for fuzzy matching and finding similar files
        final tlshHash = TLSH.hash(bytes);

        final hashes = <String, dynamic>{
          'sha1': sha1Hash,
        };
        if (tlshHash != null) {
          hashes['tlsh'] = tlshHash;
        }

        entries.add({
          'path': relativePath,
          'name': entity.path.split('/').last,
          'type': 'file',
          'size': stat.size,
          'mimeType': mimeType,
          'hashes': hashes,
          'metadata': {
            'mime_type': mimeType,
          },
        });
      }
    }

    // Sort entries: directories first, then files, alphabetically
    entries.sort((a, b) {
      if (a['type'] == 'directory' && b['type'] != 'directory') return -1;
      if (a['type'] != 'directory' && b['type'] == 'directory') return 1;
      return (a['path'] as String).compareTo(b['path'] as String);
    });

    // Generate JavaScript file content
    final now = DateTime.now().toIso8601String();
    final jsonData = JsonEncoder.withIndent('  ').convert(entries);

    return '''// Geogram Collection File Tree
// Generated: $now
window.TREE_DATA = $jsonData;
''';
  }

  /// Cleanup
  void dispose() {
    disconnect();
    _messageController.close();
  }
}
