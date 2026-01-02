import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:http/http.dart' as http;
import '../services/log_service.dart';
import '../services/log_api_service.dart';
import '../services/profile_service.dart';
import '../services/collection_service.dart';
import '../services/signing_service.dart';
import '../services/user_location_service.dart';
import '../services/security_service.dart';
import '../services/backup_service.dart';
import '../services/ble_foreground_service.dart';
import '../services/station_service.dart';
import '../util/nostr_event.dart';
import '../util/tlsh.dart';
import '../util/event_bus.dart';
import '../models/update_notification.dart';
import '../models/blog_post.dart';

/// WebSocket service for station connections (singleton)
class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _updateController = StreamController<UpdateNotification>.broadcast();
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _disconnectGraceTimer;  // Timer to mark as disconnected after grace period
  String? _stationUrl;
  bool _shouldReconnect = false;
  bool _isReconnecting = false;
  bool _lastConnectionState = false; // Track last state to avoid duplicate events
  String? _connectedStationCallsign;
  final EventBus _eventBus = EventBus();

  /// Grace period before marking station as disconnected (allows brief reconnection)
  static const _disconnectGracePeriod = Duration(seconds: 5);

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<UpdateNotification> get updates => _updateController.stream;

  /// Connect to station and send hello
  Future<bool> connectAndHello(String url) async {
    try {
      // Store URL for reconnection
      _stationUrl = url;
      _shouldReconnect = true;

      LogService().log('══════════════════════════════════════');
      LogService().log('CONNECTING TO RELAY');
      LogService().log('══════════════════════════════════════');
      LogService().log('URL: $url');

      // Connect to WebSocket
      final uri = Uri.parse(url);
      LogService().log('Platform: ${kIsWeb ? "Web" : "Native"}');
      LogService().log('Connecting to WebSocket at: $uri');

      _channel = WebSocketChannel.connect(uri);

      // On web, we need to wait for the connection to establish
      // The ready future completes when the WebSocket is ready to send/receive
      try {
        await _channel!.ready;
        LogService().log('✓ WebSocket ready (connection established)');
      } catch (e) {
        LogService().log('WebSocket ready failed: $e');
        _channel = null;
        return false;
      }

      LogService().log('✓ WebSocket connected');

      // Start reconnection monitoring
      _startReconnectTimer();

      // Start heartbeat (ping) timer
      _startPingTimer();

      // Get user profile
      final profile = ProfileService().getProfile();
      LogService().log('User callsign: ${profile.callsign}');
      LogService().log('User npub: ${profile.npub.substring(0, 20)}...');

      // Detect platform for device type identification
      String platform;
      if (kIsWeb) {
        platform = 'Web';
      } else if (Platform.isAndroid) {
        platform = 'Android';
      } else if (Platform.isIOS) {
        platform = 'iOS';
      } else if (Platform.isMacOS) {
        platform = 'macOS';
      } else if (Platform.isWindows) {
        platform = 'Windows';
      } else if (Platform.isLinux) {
        platform = 'Linux';
      } else {
        platform = 'Desktop';
      }

      // Get location: prefer profile, fallback to UserLocationService (GPS/IP-based)
      double? latitude = profile.latitude;
      double? longitude = profile.longitude;

      // If profile has no location, try UserLocationService
      if (latitude == null || longitude == null) {
        final userLocation = UserLocationService().currentLocation;
        if (userLocation != null && userLocation.isValid) {
          latitude = userLocation.latitude;
          longitude = userLocation.longitude;
          LogService().log('HELLO: Using ${userLocation.source} location: $latitude, $longitude');
        }
      }

      // Apply location granularity from Security settings before sharing
      final (roundedLat, roundedLon) = SecurityService().applyLocationGranularity(latitude, longitude);

      // Create hello event (include nickname for friendly URL support, location for distance)
      final event = NostrEvent.createHello(
        npub: profile.npub,
        callsign: profile.callsign,
        nickname: profile.nickname,
        color: profile.preferredColor,
        latitude: roundedLat,
        longitude: roundedLon,
        platform: platform,
      );
      event.calculateId();

      // Sign using SigningService (handles both extension and nsec)
      final signingService = SigningService();
      await signingService.initialize();
      final signedEvent = await signingService.signEvent(event, profile);
      if (signedEvent == null) {
        LogService().log('Failed to sign hello event');
        return false;
      }

      // Build hello message
      final helloMessage = {
        'type': 'hello',
        'event': signedEvent.toJson(),
      };

      final helloJson = jsonEncode(helloMessage);
      LogService().log('');
      LogService().log('SENDING HELLO MESSAGE');
      LogService().log('══════════════════════════════════════');
      LogService().log('Message type: hello');
      LogService().log('Event ID: ${signedEvent.id?.substring(0, 16)}...');
      LogService().log('Callsign: ${profile.callsign}');
      if (profile.nickname.isNotEmpty) {
        LogService().log('Nickname: ${profile.nickname}');
      }
      LogService().log('Content: ${signedEvent.content}');
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
      LogService().log('Setting up WebSocket message listener (${kIsWeb ? "Web" : "Native"})...');
      _subscription = _channel!.stream.listen(
        (message) {
          try {
            final rawMessage = message as String;
            LogService().log('[WS-RX] Received ${rawMessage.length} chars');

            // Handle lightweight UPDATE notifications (plain string, not JSON)
            if (rawMessage.startsWith('UPDATE:')) {
              final update = UpdateNotification.parse(rawMessage);
              if (update != null) {
                LogService().log('UPDATE notification: ${update.callsign}/${update.collectionType}${update.path}');
                _updateController.add(update);
              }
              return;
            }

            LogService().log('');
            LogService().log('RECEIVED MESSAGE FROM RELAY');
            LogService().log('══════════════════════════════════════');
            LogService().log('Raw message: ${rawMessage.length > 500 ? "${rawMessage.substring(0, 500)}..." : rawMessage}');

            // Parse the JSON - could be array (NOSTR protocol) or object (custom protocol)
            final decoded = jsonDecode(rawMessage);

            // Handle NOSTR standard array format: ["OK", event_id, success, message]
            if (decoded is List && decoded.isNotEmpty && decoded[0] == 'OK') {
              final eventId = decoded.length > 1 ? decoded[1] as String? : null;
              final success = decoded.length > 2 ? decoded[2] as bool? ?? false : false;
              final okMessage = decoded.length > 3 ? decoded[3] as String? : null;
              LogService().log('✓ Received NOSTR OK: event=${eventId?.substring(0, 16)}..., success=$success');
              if (eventId != null && eventId.isNotEmpty) {
                _handleOkResponse(eventId, success, okMessage);
              }
              return;
            }

            final data = decoded as Map<String, dynamic>;
            LogService().log('Message type: ${data['type']}');

            if (data['type'] == 'PONG') {
              // Heartbeat response - connection is alive
              LogService().log('✓ PONG received from station');
            } else if (data['type'] == 'hello_ack') {
              final success = data['success'] as bool? ?? false;
              final stationId = data['station_id'] as String?;
              if (success) {
                LogService().log('✓ Hello acknowledged!');
                LogService().log('Station ID: $stationId');
                LogService().log('Message: ${data['message']}');
                LogService().log('══════════════════════════════════════');
                _isReconnecting = false; // Reset reconnecting flag on successful connection
                // Cancel disconnect grace timer since we're now connected
                _disconnectGraceTimer?.cancel();
                _disconnectGraceTimer = null;
                // Fire connected event
                _fireConnectionStateChanged(true, stationCallsign: stationId);
                // Enable foreground service keep-alive on Android
                // This ensures the WebSocket stays alive even when the display is off
                _enableForegroundKeepAlive();
              } else {
                LogService().log('✗ Hello rejected');
                LogService().log('Reason: ${data['message']}');
                LogService().log('══════════════════════════════════════');
              }
            } else if (data['type'] == 'COLLECTIONS_REQUEST') {
              LogService().log('✓ Station requested collections');
              _handleCollectionsRequest(data['requestId'] as String?);
            } else if (data['type'] == 'COLLECTION_FILE_REQUEST') {
              LogService().log('✓ Station requested collection file');
              _handleCollectionFileRequest(
                data['requestId'] as String?,
                data['collectionName'] as String?,
                data['fileName'] as String?,
              );
            } else if (data['type'] == 'HTTP_REQUEST') {
              LogService().log('✓ Station forwarded HTTP request: ${data['method']} ${data['path']} (requestId: ${data['requestId']})');
              _handleHttpRequest(
                data['requestId'] as String?,
                data['method'] as String?,
                data['path'] as String?,
                data['headers'] as String?,
                data['body'] as String?,
              );
            } else if (data['type'] == 'OK') {
              // NOSTR OK response: {"type": "OK", "event_id": "...", "success": true/false, "message": "..."}
              final eventId = data['event_id'] as String?;
              final success = data['success'] as bool? ?? false;
              final message = data['message'] as String?;
              LogService().log('✓ Received OK response for event ${eventId?.substring(0, 16)}...: success=$success');
              if (eventId != null) {
                _handleOkResponse(eventId, success, message);
              }
            } else if (data['type'] == 'backup_invite') {
              // Backup invite from a client
              LogService().log('✓ Received backup invite');
              BackupService().handleBackupInvite(data);
            } else if (data['type'] == 'backup_invite_response') {
              // Response to our backup invite
              LogService().log('✓ Received backup invite response');
              BackupService().handleBackupInviteResponse(data);
            } else if (data['type'] == 'backup_start') {
              // Client is starting a backup
              LogService().log('✓ Received backup start notification');
              BackupService().handleBackupStart(data);
            } else if (data['type'] == 'backup_complete') {
              // Client completed a backup
              LogService().log('✓ Received backup complete notification');
              BackupService().handleBackupComplete(data);
            } else if (data['type'] == 'backup_discovery_challenge') {
              // Discovery challenge for account restoration
              LogService().log('✓ Received backup discovery challenge');
              BackupService().handleDiscoveryChallenge(data);
            } else if (data['type'] == 'backup_discovery_response') {
              // Response to discovery challenge
              LogService().log('✓ Received backup discovery response');
              BackupService().handleDiscoveryResponse(data);
            } else if (data['type'] == 'backup_status_change') {
              // Status change notification from provider
              LogService().log('✓ Received backup status change');
              BackupService().handleStatusChange(data);
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

  /// Disconnect from station
  void disconnect() {
    LogService().log('Disconnecting from station...');
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;
    _subscription?.cancel();
    try {
      _channel?.sink.close();
    } catch (e) {
      // Ignore errors when closing - connection might already be closed
    }
    _channel = null;
    _subscription = null;

    // Disable foreground service keep-alive on Android
    _disableForegroundKeepAlive();

    // Fire disconnected event
    _fireConnectionStateChanged(false);
  }

  /// Send message to station
  void send(Map<String, dynamic> message) {
    if (_channel != null) {
      try {
        final json = jsonEncode(message);
        LogService().log('Sending to station: $json');
        _channel!.sink.add(json);
      } catch (e) {
        LogService().log('Error sending message: $e');
        _handleConnectionLoss();
      }
    }
  }

  /// Check if connected (channel exists)
  bool get isConnected => _channel != null;

  /// Get currently connected station URL (or null if not connected)
  String? get connectedUrl => _channel != null ? _stationUrl : null;

  /// Ensure WebSocket is connected and ready to send messages.
  /// Returns true if connected, false if connection failed.
  /// If disconnected, attempts to reconnect before returning.
  Future<bool> ensureConnected() async {
    // If channel exists, try a test send to verify it's alive
    if (_channel != null) {
      try {
        // Try to send a ping to verify connection is alive
        final pingMessage = jsonEncode({'type': 'PING'});
        _channel!.sink.add(pingMessage);
        LogService().log('Connection verified (PING sent)');
        return true;
      } catch (e) {
        LogService().log('Connection test failed: $e');
        // Connection is broken, clean up
        _channel = null;
        _subscription?.cancel();
        _subscription = null;
      }
    }

    // Not connected - try to reconnect if we have a URL
    if (_stationUrl != null && _shouldReconnect) {
      LogService().log('Attempting to reconnect before sending message...');
      try {
        final success = await connectAndHello(_stationUrl!);
        if (success) {
          LogService().log('✓ Reconnection successful');
          return true;
        }
      } catch (e) {
        LogService().log('✗ Reconnection failed: $e');
      }
    }

    return false;
  }

  /// Send message to station with connection verification.
  /// Returns true if message was sent, false if send failed.
  Future<bool> sendWithVerification(Map<String, dynamic> message) async {
    if (!await ensureConnected()) {
      LogService().log('Cannot send message: not connected to station');
      return false;
    }

    try {
      final json = jsonEncode(message);
      LogService().log('Sending to station (${kIsWeb ? "Web" : "Native"}): ${json.length > 200 ? "${json.substring(0, 200)}..." : json}');
      _channel!.sink.add(json);
      LogService().log('✓ Message sent to WebSocket sink');
      return true;
    } catch (e) {
      LogService().log('Error sending message: $e');
      _handleConnectionLoss();
      return false;
    }
  }

  /// Send a WebRTC signaling message (offer, answer, ICE candidate)
  /// These are forwarded by the station to the target device
  void sendWebRTCSignal(Map<String, dynamic> signal) {
    if (_channel == null) {
      LogService().log('Cannot send WebRTC signal: not connected');
      return;
    }

    try {
      final json = jsonEncode(signal);
      LogService().log('Sending WebRTC signal: ${signal['type']} to ${signal['to_callsign']}');
      _channel!.sink.add(json);
    } catch (e) {
      LogService().log('Error sending WebRTC signal: $e');
    }
  }

  // Pending OK responses keyed by event ID
  final Map<String, Completer<({bool success, String? message})>> _pendingOkResponses = {};

  /// Send a NOSTR event and wait for OK acknowledgment from the station.
  /// Returns (success: true/false, message: error message if failed).
  /// Throws TimeoutException if no response within timeout.
  Future<({bool success, String? message})> sendEventAndWaitForOk(
    Map<String, dynamic> eventMessage,
    String eventId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!await ensureConnected()) {
      LogService().log('Cannot send event: not connected to station');
      return (success: false, message: 'Not connected to station');
    }

    // Create completer for this event
    final completer = Completer<({bool success, String? message})>();
    _pendingOkResponses[eventId] = completer;

    try {
      // Send the event
      final json = jsonEncode(eventMessage);
      LogService().log('Sending NOSTR event (waiting for OK): ${json.length > 200 ? "${json.substring(0, 200)}..." : json}');
      _channel!.sink.add(json);
      LogService().log('✓ Event sent, waiting for OK response...');

      // Wait for response with timeout
      final result = await completer.future.timeout(
        timeout,
        onTimeout: () {
          LogService().log('✗ Timeout waiting for OK response for event $eventId');
          return (success: false, message: 'Timeout waiting for station response');
        },
      );

      return result;
    } catch (e) {
      LogService().log('Error sending event: $e');
      _handleConnectionLoss();
      return (success: false, message: e.toString());
    } finally {
      _pendingOkResponses.remove(eventId);
    }
  }

  /// Handle OK response from station for a pending event
  void _handleOkResponse(String eventId, bool success, String? message) {
    final completer = _pendingOkResponses[eventId];
    if (completer != null && !completer.isCompleted) {
      LogService().log('Received OK for event $eventId: success=$success, message=$message');
      completer.complete((success: success, message: message));
    } else {
      LogService().log('Received OK for unknown/completed event $eventId');
    }
  }

  /// Handle collections request from station
  Future<void> _handleCollectionsRequest(String? requestId) async {
    if (requestId == null) return;

    // Skip collection requests on web - the web client doesn't serve collections
    if (kIsWeb) {
      LogService().log('Ignoring COLLECTIONS_REQUEST on web platform');
      return;
    }

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
      LogService().log('Sent ${collectionNames.length} collection folder names to station (filtered ${collections.length - publicCollections.length} private collections)');
    } catch (e) {
      LogService().log('Error handling collections request: $e');
    }
  }

  /// Handle collection file request from station
  Future<void> _handleCollectionFileRequest(
    String? requestId,
    String? collectionName,
    String? fileName,
  ) async {
    if (requestId == null || collectionName == null || fileName == null) return;

    // Skip file requests on web - the web client doesn't serve files
    if (kIsWeb) {
      LogService().log('Ignoring COLLECTION_FILE_REQUEST on web platform');
      return;
    }

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

  /// Handle HTTP request from station (for www collection proxying and blog API)
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

    // Skip HTTP requests on web - the web client doesn't serve HTTP content
    if (kIsWeb) {
      LogService().log('Ignoring HTTP_REQUEST on web platform');
      return;
    }

    try {
      LogService().log('Station proxy HTTP request: $method $path');

      // Handle blog requests - render markdown to HTML
      // Path format: /api/blog/{filename}.html
      if (path.startsWith('/api/blog/') && path.endsWith('.html')) {
        await _handleBlogApiRequest(requestId, path);
        return;
      }

      // Forward ALL /api/* requests to local LogApiService HTTP server
      // This enables DM, chat, status, and other API calls to work through station proxy
      if (path.startsWith('/api/')) {
        await _forwardToLocalApi(requestId, method, path, headersJson, body);
        return;
      }

      // Handle blog HTML requests with device identifier prefix
      // Path format: /{callsign}/blog/{filename}.html
      if (path.contains('/blog/') && path.endsWith('.html')) {
        await _forwardToLocalApi(requestId, method, path, headersJson, body);
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

  /// Handle blog API request from station
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

  /// Forward API request to local LogApiService
  /// Uses direct function calls to bypass localhost HTTP connection
  /// (Android 9+ blocks cleartext HTTP by default, even to localhost)
  Future<void> _forwardToLocalApi(
    String requestId,
    String method,
    String path,
    String? headersJson,
    String? body,
  ) async {
    try {
      LogService().log('HTTP_REQUEST: Direct call to API: $method $path');

      // Parse headers from JSON if provided
      Map<String, String>? headers;
      if (headersJson != null && headersJson.isNotEmpty) {
        try {
          final parsed = jsonDecode(headersJson) as Map<String, dynamic>;
          headers = parsed.map((k, v) => MapEntry(k, v.toString()));
        } catch (_) {
          // Keep null headers if parsing fails
        }
      }

      // Call LogApiService directly (no HTTP connection needed)
      final response = await LogApiService().handleRequestDirect(
        method: method.toUpperCase(),
        path: path,
        headers: headers,
        body: body,
      );

      // Send response back through WebSocket to station
      _sendHttpResponse(
        requestId,
        response.statusCode,
        {'Content-Type': response.headers['Content-Type'] ?? 'application/json'},
        response.body,
        isBase64: response.isBase64,
      );

      LogService().log('HTTP_REQUEST: Response sent back to station: $method $path -> ${response.statusCode} (${response.body.length} bytes, base64: ${response.isBase64})');
    } catch (e, stack) {
      LogService().log('HTTP_REQUEST: Error in direct API call: $e');
      LogService().log('HTTP_REQUEST: Stack trace: $stack');
      _sendHttpResponse(requestId, 502, {'Content-Type': 'text/plain'}, 'Bad Gateway: $e');
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

  /// Send HTTP response to station
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
        LogService().log('Sent PING to station');
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
    // Clean up channel regardless of reconnect state
    _channel = null;
    _subscription?.cancel();
    _subscription = null;

    // Disable foreground service keep-alive on Android when connection lost
    _disableForegroundKeepAlive();

    // If not attempting reconnection, mark as disconnected immediately
    if (!_shouldReconnect) {
      _disconnectGraceTimer?.cancel();
      _disconnectGraceTimer = null;
      _fireConnectionStateChanged(false);
      return;
    }

    // Start grace period timer - if not reconnected within 5 seconds, mark as disconnected
    if (_disconnectGraceTimer == null || !_disconnectGraceTimer!.isActive) {
      LogService().log('Connection lost - starting ${_disconnectGracePeriod.inSeconds}s grace period');
      _disconnectGraceTimer = Timer(_disconnectGracePeriod, () {
        // Grace period expired without reconnection - mark as disconnected
        if (_channel == null) {
          LogService().log('Grace period expired - marking station as disconnected');
          _fireConnectionStateChanged(false);
        }
      });
    }

    LogService().log('Connection lost - will attempt reconnection');
  }

  /// Fire connection state changed event (only if state actually changed)
  void _fireConnectionStateChanged(bool connected, {String? stationCallsign}) {
    if (connected == _lastConnectionState) {
      return; // No change, don't fire duplicate event
    }

    _lastConnectionState = connected;
    if (connected) {
      _connectedStationCallsign = stationCallsign;
    }

    LogService().log('ConnectionStateChanged: station ${connected ? "connected" : "disconnected"}');

    _eventBus.fire(ConnectionStateChangedEvent(
      connectionType: ConnectionType.station,
      isConnected: connected,
      stationUrl: connected ? _stationUrl : null,
      stationCallsign: connected ? _connectedStationCallsign : null,
    ));
  }

  /// Attempt to reconnect to station
  Future<void> _attemptReconnect() async {
    if (!_shouldReconnect || _isReconnecting || _stationUrl == null) {
      return;
    }

    _isReconnecting = true;
    LogService().log('Attempting to reconnect to station...');

    try {
      final success = await connectAndHello(_stationUrl!);
      if (success) {
        LogService().log('✓ Reconnection initiated, waiting for hello_ack...');
        // Set a timeout to reset _isReconnecting if hello_ack is not received
        // hello_ack handler will cancel this and reset _isReconnecting = false
        Future.delayed(const Duration(seconds: 10), () {
          if (_isReconnecting) {
            LogService().log('✗ Reconnection timeout - no hello_ack received');
            _isReconnecting = false;
          }
        });
      } else {
        LogService().log('✗ Reconnection failed');
        _isReconnecting = false;
      }
    } catch (e) {
      LogService().log('✗ Reconnection failed: $e');
      _isReconnecting = false;
    }
  }

  /// Enable Android foreground service keep-alive for WebSocket
  /// This is called when WebSocket successfully connects to the station
  void _enableForegroundKeepAlive() {
    // Only relevant on Android - other platforms don't need this
    if (kIsWeb) return;
    if (!Platform.isAndroid) return;

    final foregroundService = BLEForegroundService();

    // Set up callback to send PING when foreground service triggers keep-alive
    foregroundService.onKeepAlivePing = () {
      LogService().log('Foreground service triggered keep-alive ping');
      _sendPing();
    };

    // Extract station info for the notification
    String? stationName;
    String? stationHost;
    if (_stationUrl != null) {
      try {
        final uri = Uri.parse(_stationUrl!);
        stationHost = uri.host;
        // Try to get the friendly name from StationService
        final stationService = StationService();
        final stations = stationService.getAllStations();
        final station = stations.where((s) => s.url == _stationUrl).firstOrNull;
        if (station != null && station.name.isNotEmpty) {
          stationName = station.name;
        }
      } catch (_) {
        // Ignore parsing errors
      }
    }

    // Enable keep-alive in the foreground service with station info
    foregroundService.enableKeepAlive(
      stationName: stationName,
      stationUrl: stationHost,
    );
    LogService().log('WebSocket: Enabled foreground service keep-alive for ${stationName ?? stationHost ?? "station"}');
  }

  /// Disable Android foreground service keep-alive for WebSocket
  /// This is called when WebSocket disconnects from the station
  void _disableForegroundKeepAlive() {
    // Only relevant on Android
    if (kIsWeb) return;
    if (!Platform.isAndroid) return;

    final foregroundService = BLEForegroundService();
    foregroundService.onKeepAlivePing = null;
    foregroundService.disableKeepAlive();
    LogService().log('WebSocket: Disabled foreground service keep-alive');
  }

  /// Cleanup
  void dispose() {
    disconnect();
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _disconnectGraceTimer?.cancel();
    _messageController.close();
    _updateController.close();
  }
}
