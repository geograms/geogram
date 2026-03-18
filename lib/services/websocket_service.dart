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
import 'package:path/path.dart' as p;
import '../services/log_service.dart';
import '../services/log_api_service.dart';
import '../services/mirror_config_service.dart';
import '../services/profile_service.dart';
import '../services/app_service.dart';
import '../services/signing_service.dart';
import '../services/user_location_service.dart';
import '../services/security_service.dart';
import '../services/backup_service.dart';
import '../services/config_service.dart';
import '../services/mirror_discovery_service.dart';
import '../services/email_service.dart';
import '../services/ble_foreground_service.dart';
import '../services/station_service.dart';
import '../services/storage_config.dart';
import '../services/webrtc_config.dart';
import '../services/profile_storage.dart';
import '../services/web_theme_service.dart';
import '../util/html_utils.dart';
import '../util/station_html_templates.dart';
import '../util/nostr_event.dart';
import '../util/nostr_bundle.dart';
import '../util/nostr_login_scripts.dart';
import '../util/tlsh.dart';
import '../util/event_bus.dart';
import '../util/feedback_folder_utils.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_key_generator.dart';
import '../models/monitored_task.dart';
import '../models/update_notification.dart';
import '../models/update_settings.dart' show UpdateAssetType;
import '../models/blog_post.dart';
import '../models/app.dart';
import '../models/shared_folder.dart';
import '../services/shared_folder_service.dart';
import '../services/groups_service.dart';
import '../tracker/models/tracker_visibility.dart';
import '../work/services/ndf_web_viewer_service.dart';
import '../util/task_monitor_helpers.dart';
import '../work/services/work_storage_service.dart';

/// WebSocket service for station connections (singleton)
class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _updateController = StreamController<UpdateNotification>.broadcast();
  MonitoredPeriodicTimer? _reconnectTimer;
  MonitoredPeriodicTimer? _pingTimer;
  Timer? _disconnectGraceTimer;  // Timer to mark as disconnected after grace period
  String? _stationUrl;
  bool _shouldReconnect = false;
  bool _isReconnecting = false;
  bool _lastConnectionState = false; // Track last state to avoid duplicate events
  String? _connectedStationCallsign;
  StationStunInfo? _connectedStationStunInfo; // STUN server info from connected station
  final EventBus _eventBus = EventBus();
  String? _heartbeatPath;
  DateTime? _lastPingAt;
  DateTime? _lastPongAt;
  DateTime? _lastHelloAt;
  DateTime? _lastDisconnectAt;
  DateTime? _lastReconnectAttemptAt;
  DateTime? _lastReconnectSuccessAt;
  DateTime? _lastKeepAlivePingAt;
  int _consecutivePingMisses = 0;
  int _reconnectFailures = 0;
  bool _foregroundKeepAliveEnabled = false;

  /// Grace period before marking station as disconnected (allows brief reconnection)
  static const _disconnectGracePeriod = Duration(seconds: 5);

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<UpdateNotification> get updates => _updateController.stream;

  /// Connect to station and send hello
  Future<bool> connectAndHello(String url) async {
    final profile = ProfileService().getProfile();
    try {
      // Normalize URL to WebSocket protocol
      var wsUrl = url;
      if (wsUrl.startsWith('http://')) {
        wsUrl = wsUrl.replaceFirst('http://', 'ws://');
      } else if (wsUrl.startsWith('https://')) {
        wsUrl = wsUrl.replaceFirst('https://', 'wss://');
      } else if (!wsUrl.startsWith('ws://') && !wsUrl.startsWith('wss://')) {
        wsUrl = 'ws://$wsUrl';
      }

      // Store URL for reconnection
      _stationUrl = wsUrl;
      _shouldReconnect = true;
      _recordHeartbeat('connect_start', message: wsUrl);

      // Validate that we have a usable nsec before connecting (avoid accidental new identity)
      final profile = ProfileService().getProfile();
      final hasNsec = profile.nsec.isNotEmpty &&
          NostrKeyGenerator.getPrivateKeyHex(profile.nsec) != null;
      if (!hasNsec) {
        LogService().log('Connection aborted: profile missing usable nsec. Refusing to create new identity.');
        _shouldReconnect = false;
        _recordHeartbeat('missing_nsec', message: 'Profile lacks nsec, cannot connect');
        return false;
      }

      LogService().log('══════════════════════════════════════');
      LogService().log('CONNECTING TO STATION');
      LogService().log('══════════════════════════════════════');
      LogService().log('URL: $wsUrl');

      // Connect to WebSocket
      final uri = Uri.parse(wsUrl);
      LogService().log('Platform: ${kIsWeb ? "Web" : "Native"}');
      LogService().log('Connecting to WebSocket at: $uri');

      _channel = WebSocketChannel.connect(uri);

      // On web, we need to wait for the connection to establish
      // The ready future completes when the WebSocket is ready to send/receive
      try {
        await _channel!.ready;
        LogService().log('✓ WebSocket ready (connection established)');
        _recordHeartbeat('socket_connected', connected: true);
        _consecutivePingMisses = 0;
        _lastPingAt = null;
        _lastPongAt = null;
      } catch (e) {
        LogService().log('WebSocket ready failed: $e');
        _channel = null;
        _recordHeartbeat('socket_connect_failed', message: e.toString(), connected: false);
        return false;
      }

      LogService().log('✓ WebSocket connected');

      // Start reconnection monitoring
      _startReconnectTimer();

      // Start heartbeat (ping) timer
      _startPingTimer();

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

      // Set up listener FIRST, then wait for challenge before sending HELLO
      // This enables HELLO protocol v2 challenge-response authentication
      final challengeCompleter = Completer<String?>();
      bool helloPending = true;

      // Listen for messages
      LogService().log('Setting up WebSocket message listener (${kIsWeb ? "Web" : "Native"})...');
      _subscription = _channel!.stream.listen(
        (message) {
          // Intercept challenge message before HELLO is sent
          if (helloPending) {
            try {
              final decoded = jsonDecode(message as String);
              if (decoded is Map<String, dynamic> && decoded['type'] == 'challenge') {
                final nonce = decoded['nonce'] as String?;
                LogService().log('Received challenge nonce from server');
                if (!challengeCompleter.isCompleted) {
                  challengeCompleter.complete(nonce);
                }
                return;
              }
            } catch (_) {
              // Not JSON or not a challenge, continue
            }
          }
          try {
            final rawMessage = message as String;
            LogService().log('[WS-RX] Received ${rawMessage.length} chars');

            // Handle lightweight UPDATE notifications (plain string, not JSON)
            if (rawMessage.startsWith('UPDATE:')) {
              final update = UpdateNotification.parse(rawMessage);
              if (update != null) {
                LogService().log('UPDATE notification: ${update.callsign}/${update.appType}${update.path}');
                _updateController.add(update);
              }
              return;
            }

            LogService().log('');
            LogService().log('RECEIVED MESSAGE FROM STATION');
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

            if (data['type'] == 'PING') {
              // Station heartbeat — respond with PONG to stay alive
              _channel?.sink.add(jsonEncode({
                'type': 'PONG',
                'timestamp': DateTime.now().millisecondsSinceEpoch,
              }));
            } else if (data['type'] == 'PONG') {
              // Heartbeat response - connection is alive
              LogService().log('✓ PONG received from station');
              _lastPongAt = DateTime.now();
              _consecutivePingMisses = 0;
              _recordHeartbeat('pong');
            } else if (data['type'] == 'hello_ack') {
              final success = data['success'] as bool? ?? false;
              final stationId = data['station_id'] as String?;
              if (success) {
                LogService().log('✓ Hello acknowledged!');
                LogService().log('Station ID: $stationId');
                LogService().log('Message: ${data['message']}');

                // Parse STUN server info for privacy-preserving WebRTC
                final stunServerData = data['stun_server'] as Map<String, dynamic>?;
                if (stunServerData != null) {
                  _connectedStationStunInfo = StationStunInfo.fromJson(stunServerData);
                  LogService().log('STUN server: port ${_connectedStationStunInfo!.port} (enabled: ${_connectedStationStunInfo!.enabled})');
                } else {
                  _connectedStationStunInfo = null;
                  LogService().log('STUN server: not available (WebRTC will use host candidates only)');
                }

                LogService().log('══════════════════════════════════════');
                _isReconnecting = false; // Reset reconnecting flag on successful connection
                _reconnectFailures = 0;
                _lastReconnectSuccessAt = DateTime.now();
                _recordHeartbeat('hello_ack', connected: true);
                // Cancel disconnect grace timer since we're now connected
                _disconnectGraceTimer?.cancel();
                _disconnectGraceTimer = null;
                // Fire connected event
                _fireConnectionStateChanged(true, stationCallsign: stationId);
                // Enable foreground service keep-alive on Android
                // This ensures the WebSocket stays alive even when the display is off
                _enableForegroundKeepAlive();
                // Populate station relay addresses for mirror peers
                _updateMirrorRelayAddresses();
                // Parse mirror count for multi-device sync
                final mirrorCount = data['mirror_count'] as int? ?? 0;
                MirrorDiscoveryService().handleHelloAckMirrorCount(mirrorCount);
              } else {
                LogService().log('✗ Hello rejected');
                LogService().log('Reason: ${data['message']}');
                LogService().log('══════════════════════════════════════');
              }
            } else if (data['type'] == 'mirrors_update') {
              MirrorDiscoveryService().handleMirrorsUpdate(data);
            } else if (data['type'] == 'APPS_REQUEST') {
              LogService().log('✓ Station requested collections');
              _handleAppsRequest(data['requestId'] as String?);
            } else if (data['type'] == 'APP_FILE_REQUEST') {
              LogService().log('✓ Station requested collection file');
              _handleAppFileRequest(
                data['requestId'] as String?,
                data['appName'] as String?,
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
            } else if (data['type'] == 'email_receive') {
              // Incoming email from station
              LogService().log('✓ Received email from ${data['from']}');
              EmailService().receiveEmail(data);
            } else if (data['type'] == 'email_receive_encrypted') {
              // Encrypted cached email from station (was offline when sent)
              LogService().log('✓ Received encrypted cached email');
              EmailService().receiveEncryptedEmail(data);
            } else if (data['type'] == 'email_dsn') {
              // Delivery status notification
              LogService().log('✓ Received email DSN: ${data['action']} for ${data['thread_id']}');
              EmailService().handleDSN(data);
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

      // Wait for challenge from server (up to 5 seconds, then fall back to v1)
      String? challengeNonce;
      try {
        challengeNonce = await challengeCompleter.future.timeout(
          const Duration(seconds: 5),
        );
      } on TimeoutException {
        LogService().log('No challenge received within 5s, using HELLO v1 (legacy)');
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

      // Create hello event (include challenge nonce for v2 authentication)
      final event = NostrEvent.createHello(
        npub: profile.npub,
        callsign: profile.callsign,
        nickname: profile.nickname,
        color: profile.preferredColor,
        latitude: roundedLat,
        longitude: roundedLon,
        platform: platform,
        ssid: profile.ssid,
        challenge: challengeNonce,
        deviceId: ConfigService().deviceId,
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

      // Build hello message with protocol version
      // Ensure mirror config is loaded so device_name is available
      var mirrorConfig = MirrorConfigService.instance.config;
      if (mirrorConfig == null) {
        await MirrorConfigService.instance.initialize();
        mirrorConfig = MirrorConfigService.instance.config;
      }
      final helloMessage = {
        'type': 'hello',
        if (challengeNonce != null) 'protocol': 2,
        'event': signedEvent.toJson(),
        if (mirrorConfig != null) 'device_name': mirrorConfig.deviceName,
      };

      final helloJson = jsonEncode(helloMessage);
      LogService().log('');
      LogService().log('SENDING HELLO MESSAGE (v${challengeNonce != null ? 2 : 1})');
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
      helloPending = false;
      try {
        _lastHelloAt = DateTime.now();
        _recordHeartbeat('hello_sent');
        _channel!.sink.add(helloJson);
      } catch (e) {
        LogService().log('Error sending hello: $e');
        _handleConnectionLoss();
        return false;
      }

      // Wait a bit for response
      await Future.delayed(const Duration(seconds: 2));
      return true;

    } catch (e) {
      LogService().log('');
      LogService().log('CONNECTION ERROR');
      LogService().log('══════════════════════════════════════');
      LogService().log('Error: $e');
      LogService().log('══════════════════════════════════════');
      _recordHeartbeat('connect_error', message: e.toString(), connected: false);
      return false;
    }
  }

  /// Force a fresh reconnection (e.g. after profile switch).
  /// Disconnects cleanly, then reconnects with current profile credentials.
  Future<void> reconnect() async {
    if (_stationUrl == null) return;
    final url = _stationUrl!;
    disconnect();
    await Future.delayed(const Duration(milliseconds: 200));
    await connectAndHello(url);
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
    _connectedStationStunInfo = null; // Clear STUN info on disconnect
    _lastDisconnectAt = DateTime.now();
    _recordHeartbeat('manual_disconnect', connected: false);

    // Disable foreground service keep-alive on Android
    _disableForegroundKeepAlive();

    // Clean up station relay addresses from mirror peers
    _clearMirrorRelayAddresses();

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

  /// Get STUN server info from connected station (or null if not available)
  /// Used by WebRTC to use station's self-hosted STUN instead of Google/Twilio
  StationStunInfo? get connectedStationStunInfo => _channel != null ? _connectedStationStunInfo : null;

  /// Called when app resumes from background.
  /// Verifies the WebSocket connection is still alive and reconnects if needed.
  /// This is critical on Android where background throttling may have broken the connection.
  Future<void> onAppResumed() async {
    if (!_shouldReconnect || _stationUrl == null) {
      return; // Not configured to maintain a connection
    }

    LogService().log('App resumed - verifying WebSocket connection...');

    // First, check if channel is null (definitely disconnected)
    if (_channel == null) {
      LogService().log('WebSocket channel is null - attempting reconnection...');
      await _attemptReconnect();
      return;
    }

    // Channel exists but might be broken - try to send a PING
    try {
      final pingMessage = jsonEncode({'type': 'PING'});
      _channel!.sink.add(pingMessage);
      LogService().log('App resume: WebSocket connection verified (PING sent)');
    } catch (e) {
      LogService().log('App resume: WebSocket connection broken - reconnecting...');
      _channel = null;
      _subscription?.cancel();
      _subscription = null;
      await _attemptReconnect();
    }
  }

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
  Future<void> _handleAppsRequest(String? requestId) async {
    if (requestId == null) return;

    // Skip collection requests on web - the web client doesn't serve collections
    if (kIsWeb) {
      LogService().log('Ignoring COLLECTIONS_REQUEST on web platform');
      return;
    }

    try {
      final apps = await AppService().loadApps();

      // Filter out private collections - only share public and restricted ones
      final publicApps = apps
          .where((c) => c.visibility != 'private')
          .toList();

      // Extract folder names from storage paths (raw names for navigation)
      final appNames = publicApps.map((c) {
        if (c.storagePath != null) {
          // Get the last segment of the path as folder name
          final path = c.storagePath!;
          final segments = path.split('/').where((s) => s.isNotEmpty).toList();
          return segments.isNotEmpty ? segments.last : c.title;
        }
        return c.title;
      }).toList();

      final response = {
        'type': 'APPS_RESPONSE',
        'requestId': requestId,
        'collections': appNames,
      };

      send(response);
      LogService().log('Sent ${appNames.length} collection folder names to station (filtered ${apps.length - publicApps.length} private collections)');
    } catch (e) {
      LogService().log('Error handling collections request: $e');
    }
  }

  /// Handle collection file request from station
  Future<void> _handleAppFileRequest(
    String? requestId,
    String? appName,
    String? fileName,
  ) async {
    if (requestId == null || appName == null || fileName == null) return;

    // Skip file requests on web - the web client doesn't serve files
    if (kIsWeb) {
      LogService().log('Ignoring COLLECTION_FILE_REQUEST on web platform');
      return;
    }

    try {
      final apps = await AppService().loadApps();
      // Match by folder name (last segment of storagePath) instead of title
      final app = apps.firstWhere(
        (c) {
          if (c.storagePath != null) {
            final segments = c.storagePath!.split('/').where((s) => s.isNotEmpty).toList();
            final folderName = segments.isNotEmpty ? segments.last : '';
            return folderName == appName;
          }
          return c.title == appName;
        },
        orElse: () => throw Exception('Collection not found: $appName'),
      );

      // Security check: reject access to private collections
      if (app.visibility == 'private') {
        LogService().log('⚠ Rejected file request for private collection: $appName');
        throw Exception('Access denied: Collection is private');
      }

      String fileContent;
      String actualFileName;

      final storagePath = app.storagePath;
      if (storagePath == null) {
        throw Exception('Collection has no storage path: $appName');
      }

      if (fileName == 'collection') {
        final file = File('$storagePath/app.js');
        fileContent = await file.readAsString();
        actualFileName = 'app.js';
      } else if (fileName == 'tree') {
        // Read tree.json from disk (pre-generated)
        final file = File('$storagePath/extra/tree.json');
        if (!await file.exists()) {
          throw Exception('tree.json not found for collection: $appName');
        }
        fileContent = await file.readAsString();
        actualFileName = 'extra/tree.json';
      } else if (fileName == 'data') {
        // Read data.js from disk (pre-generated)
        final file = File('$storagePath/extra/data.js');
        if (!await file.exists()) {
          throw Exception('data.js not found for collection: $appName');
        }
        fileContent = await file.readAsString();
        actualFileName = 'extra/data.js';
      } else {
        throw Exception('Unknown file: $fileName');
      }

      final response = {
        'type': 'APP_FILE_RESPONSE',
        'requestId': requestId,
        'appName': appName,
        'fileName': actualFileName,
        'fileContent': fileContent,
      };

      send(response);
      LogService().log('Sent $fileName for collection $appName (${fileContent.length} bytes)');
    } catch (e) {
      LogService().log('Error handling collection file request: $e');
    }
  }

  /// Handle HTTP request from station (for www collection proxying and blog API).
  /// Delegates to [handleLocalHttpRequest] for content, then sends the result
  /// back through the WebSocket channel.
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

      // Forward ALL proxied requests to LogApiService pipeline.
      // The device handles its own routing — blog, meet, API, static files,
      // downloads, themes — all go through the same path.
      await _forwardToLocalApi(requestId, method, path, headersJson, body);
    } catch (e) {
      LogService().log('Error handling HTTP request: $e');
      _sendHttpResponse(requestId, 500, {'Content-Type': 'text/plain'}, 'Internal Server Error: $e');
    }
  }

  /// Handle an HTTP request locally — serves device web content.
  /// Used by both WebSocket proxy and the local portal service.
  /// Returns (statusCode, contentType, body bytes).
  static Future<({int statusCode, String contentType, List<int> body})> handleLocalHttpRequest(
    String method,
    String path, {
    String? headersJson,
  }) async {
    // Handle blog API requests - render markdown to HTML
    // Path format: /api/blog/{filename}.html
    if (path.startsWith('/api/blog/') && path.endsWith('.html')) {
      return _handleBlogApiRequestLocal(path);
    }

    // Serve CSS from theme system: /styles.css (global) or /{app}/styles.css
    if (path.endsWith('/styles.css') || path == '/styles.css') {
      try {
        final themeService = WebThemeService();
        await themeService.init();
        // Determine app type from path
        final segments = path.split('/').where((s) => s.isNotEmpty).toList();
        final appType = segments.length >= 2 ? segments[0] : 'www';
        final combinedStyles = await themeService.getCombinedStyles(appType);
        return (statusCode: 200, contentType: 'text/css', body: utf8.encode(combinedStyles));
      } catch (e) {
        LogService().log('Error serving theme CSS for $path: $e');
        // Fall through to file-based serving
      }
    }

    // Serve nostr-tools JS bundle
    if (path == '/lib/nostr.bundle.js') {
      final js = getNostrBundleJs();
      return (statusCode: 200, contentType: 'application/javascript', body: utf8.encode(js));
    }

    // Serve download page with available update binaries
    if (path == '/download' || path == '/download/' || path == '/download/index.html') {
      return _handleDownloadPage();
    }

    // Serve update binary files: /updates/{version}/{filename}
    if (path.startsWith('/updates/')) {
      return _handleUpdateFileServe(path);
    }

    // Serve NDF documents from work app: /work/{workspaceId}/{filename}.ndf
    if (path.startsWith('/work/') && path.endsWith('.ndf')) {
      return _handleWorkPageLocal(path, headersJson: headersJson);
    }

    // Parse path: should be /{appName}/{filePath}
    // e.g., /blog/index.html, /www/index.html
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) {
      return (statusCode: 400, contentType: 'text/plain', body: utf8.encode('Invalid path format: $path'));
    }

    final appName = parts[0];
    final filePath = parts.length > 1 ? '/${parts.sublist(1).join('/')}' : '/';

    // Load collection - match by folder name (last segment of storagePath) or type
    final appService = AppService();
    var apps = await appService.loadApps();
    LogService().log('HTTP_REQUEST: Looking for app "$appName" among ${apps.length} apps: ${apps.map((a) => '${a.type}@${a.storagePath?.split("/").last}').join(", ")}');
    var app = apps.cast<App?>().firstWhere(
      (c) {
        if (c?.storagePath != null) {
          final segments = c!.storagePath!.split('/').where((s) => s.isNotEmpty).toList();
          final folderName = segments.isNotEmpty ? segments.last : '';
          return folderName == appName;
        }
        return c?.title == appName;
      },
      orElse: () => null,
    );

    // Fallback: match by type for single-instance apps
    app ??= apps.cast<App?>().firstWhere(
      (c) => c?.type == appName,
      orElse: () => null,
    );

    // If www collection not found, create it on-demand
    if (app == null && appName == 'www') {
      LogService().log('Creating www collection on-demand...');
      try {
        app = await appService.createApp(
          title: 'Www',
          description: '',
          type: 'www',
        );
        await appService.generateDefaultWwwIndex(app);
        LogService().log('Created www collection on-demand: ${app.storagePath}');
      } catch (e) {
        LogService().log('Error creating www collection on-demand: $e');
        return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Collection not found: $appName'));
      }
    } else if (app == null) {
      return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Collection not found: $appName'));
    }

    // Security check: reject access to private collections
    if (app.visibility == 'private') {
      LogService().log('Rejected HTTP request for private collection: $appName');
      return (statusCode: 403, contentType: 'text/plain', body: utf8.encode('Forbidden'));
    }

    final storagePath = app.storagePath;
    if (storagePath == null) {
      return (statusCode: 500, contentType: 'text/plain', body: utf8.encode('Collection has no storage path: $appName'));
    }

    // For shared collection, resolve files from shared folder entries' disk locations
    if (appName == 'shared') {
      return WebSocketService()._handleSharedFolderRequestLocal(filePath, storagePath, headersJson);
    }

    // For www collection requesting index.html, regenerate only if content changed
    if (appName == 'www' && (filePath == '/' || filePath == '/index.html')) {
      if (appService.isWwwIndexDirty) {
        LogService().log('Regenerating www index.html dynamically...');
        await appService.generateDefaultWwwIndex(app);
      }
    }

    // For blog collection requesting index.html, regenerate it dynamically
    if (appName == 'blog' && (filePath == '/' || filePath == '/index.html')) {
      LogService().log('Regenerating blog index.html dynamically...');
      await appService.generateBlogIndex(storagePath);
    }

    // For chat collection requesting index.html, regenerate it dynamically
    if (appName == 'chat' && (filePath == '/' || filePath == '/index.html')) {
      LogService().log('Regenerating chat index.html dynamically...');
      await appService.generateChatIndex(storagePath);
    }

    // Read file via ProfileStorage
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) {
      return (statusCode: 500, contentType: 'text/plain', body: utf8.encode('Storage not available'));
    }

    final appStorage = ScopedProfileStorage.fromAbsolutePath(profileStorage, storagePath);
    final relativePath = filePath.startsWith('/') ? filePath.substring(1) : filePath;
    final fileBytes = await appStorage.readBytes(relativePath);

    if (fileBytes == null) {
      LogService().log('File not found: $storagePath$filePath');
      return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Not Found'));
    }

    final contentType = _getContentType(filePath);
    return (statusCode: 200, contentType: contentType, body: fileBytes);
  }

  /// Handle shared folder requests — returns response data.
  /// Resolves shared folder entries and serves files from their actual disk locations.
  /// Path format: /{folderSlug}/{filePath} or / for index
  Future<({int statusCode, String contentType, List<int> body})> _handleSharedFolderRequestLocal(
    String filePath,
    String storagePath,
    String? headersStr,
  ) async {
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) {
      return (statusCode: 500, contentType: 'text/plain', body: utf8.encode('Storage not available'));
    }

    final scopedStorage = ScopedProfileStorage.fromAbsolutePath(profileStorage, storagePath);
    final service = SharedFolderService();
    service.setStorage(scopedStorage);
    await service.initializeApp(storagePath);

    final folders = await service.loadAll();

    // Serve styles.css for the shared app
    if (filePath == '/styles.css') {
      try {
        final themeService = WebThemeService();
        await themeService.init();
        final combinedStyles = await themeService.getCombinedStyles('shared');
        return (statusCode: 200, contentType: 'text/css', body: utf8.encode(combinedStyles));
      } catch (e) {
        LogService().log('Error serving shared styles.css: $e');
        return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Not Found'));
      }
    }

    // Index page: list all shared folders
    if (filePath == '/' || filePath == '/index.html') {
      final html = await _generateSharedIndexHtml(folders, storagePath, headersStr);
      return (statusCode: 200, contentType: 'text/html', body: utf8.encode(html));
    }

    // Parse: /{folderSlug}/{rest}
    final parts = filePath.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) {
      return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Not Found'));
    }

    final folderSlug = Uri.decodeComponent(parts[0]);
    final remainingPath = parts.length > 1 ? parts.sublist(1).map(Uri.decodeComponent).join('/') : '';

    final entry = folders.cast<SharedFolder?>().firstWhere(
      (f) => f?.sanitizedFilename == folderSlug,
      orElse: () => null,
    );

    if (entry == null) {
      LogService().log('Shared folder not found for slug: $folderSlug');
      return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Shared folder not found'));
    }

    if (entry.visibility == SharedFolderVisibility.private_) {
      return (statusCode: 403, contentType: 'text/plain', body: utf8.encode('Forbidden'));
    }

    if (entry.visibility == SharedFolderVisibility.restricted) {
      final visitorPubkey = _extractNostrPubkeyFromHeaders(headersStr);
      if (!await _isAuthorizedReader(entry, visitorPubkey)) {
        return (statusCode: 403, contentType: 'text/plain', body: utf8.encode('Forbidden'));
      }
    }

    // Serve styles.css for subfolder paths
    if (remainingPath == 'styles.css') {
      try {
        final themeService = WebThemeService();
        await themeService.init();
        final combinedStyles = await themeService.getCombinedStyles('shared');
        return (statusCode: 200, contentType: 'text/css', body: utf8.encode(combinedStyles));
      } catch (e) {
        return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Not Found'));
      }
    }

    final diskPath = entry.location;

    // Directory listing
    if (remainingPath.isEmpty || remainingPath == 'index.html') {
      final dirHtml = await _generateDirectoryListing(diskPath, entry.title, folderSlug, storagePath);
      return (statusCode: 200, contentType: 'text/html', body: utf8.encode(dirHtml));
    }

    // Serve actual file from disk
    final targetPath = '$diskPath/$remainingPath';
    final file = File(targetPath);

    if (!await file.exists()) {
      LogService().log('File not found: $targetPath');
      return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Not Found'));
    }

    final fileBytes = await file.readAsBytes();
    final contentType = _getContentType(remainingPath);
    LogService().log('Shared: Served $targetPath (${fileBytes.length} bytes)');
    return (statusCode: 200, contentType: contentType, body: fileBytes);
  }

  /// Generate an index page listing all shared folders (themed)
  Future<String> _generateSharedIndexHtml(List<SharedFolder> folders, String storagePath, String? headersStr) async {
    // Build folder cards HTML
    final contentBuf = StringBuffer();
    final visitorPubkey = _extractNostrPubkeyFromHeaders(headersStr);
    final publicFolders = <SharedFolder>[];
    for (final f in folders) {
      if (f.visibility == SharedFolderVisibility.private_) continue;
      if (f.visibility == SharedFolderVisibility.restricted) {
        if (!await _isAuthorizedReader(f, visitorPubkey)) continue;
      }
      publicFolders.add(f);
    }

    if (publicFolders.isEmpty) {
      contentBuf.writeln('<div class="shared-empty">No shared folders available.</div>');
    } else {
      for (final f in publicFolders) {
        final slug = f.sanitizedFilename;
        final icon = f.visibility == SharedFolderVisibility.restricted ? '&#128274;' : '&#128193;';
        contentBuf.writeln('<a class="folder-card" href="$slug/">');
        contentBuf.writeln('<div class="folder-card-icon">$icon</div>');
        contentBuf.writeln('<div class="folder-card-title">${_escapeHtml(f.title)}</div>');
        if (f.description.isNotEmpty) {
          contentBuf.writeln('<div class="folder-card-desc">${_escapeHtml(f.description)}</div>');
        }
        contentBuf.writeln('<span class="folder-card-badge">${_escapeHtml(f.visibility.displayName)}</span>');
        contentBuf.writeln('</a>');
      }
    }

    // Try to load themed template
    try {
      final themeService = WebThemeService();
      await themeService.init();
      final template = await themeService.getTemplate('shared');
      if (template != null) {
        final profile = ProfileService().getProfile();
        final collectionName = profile.nickname.isNotEmpty ? profile.nickname : profile.callsign;
        final menuItems = await AppService().generateDeviceMenu(
          activeApp: 'shared',
          appsPath: p.dirname(storagePath),
        );

        return themeService.processTemplate(template, {
          'COLLECTION_NAME': collectionName,
          'CONTENT': contentBuf.toString(),
          'MENU_ITEMS': menuItems,
          'HOME_URL': '../',
          'NOSTR_STYLES': getNostrLoginStyles(),
          'NOSTR_HEADER': getNostrLoginHeaderHtml(),
          'NOSTR_SCRIPTS': getNostrLoginScripts(),
          'GENERATED_DATE': DateTime.now().toIso8601String().split('T').first,
        });
      }
    } catch (e) {
      LogService().log('Error loading shared template, using fallback: $e');
    }

    // Fallback: minimal inline HTML
    return '<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Shared Folders</title></head><body><h1>Shared Folders</h1>${contentBuf.toString()}</body></html>';
  }

  /// Generate a directory listing HTML for a shared folder's disk path (themed)
  Future<String> _generateDirectoryListing(String dirPath, String title, String folderSlug, String storagePath) async {
    final dir = Directory(dirPath);

    // Build file list HTML
    final contentBuf = StringBuffer();
    if (!await dir.exists()) {
      contentBuf.writeln('<div class="file-item"><span class="file-name">Directory not found on disk.</span></div>');
    } else {
      try {
        final entries = await dir.list().toList();
        entries.sort((a, b) {
          final aIsDir = a is Directory;
          final bIsDir = b is Directory;
          if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
          return a.path.toLowerCase().compareTo(b.path.toLowerCase());
        });

        for (final entity in entries) {
          final name = entity.path.split('/').last;
          if (name.startsWith('.')) continue;
          final encodedName = Uri.encodeComponent(name);
          final escapedName = _escapeHtml(name);
          if (entity is Directory) {
            contentBuf.writeln('<div class="file-item"><a href="$encodedName/"><span class="file-icon">&#128193;</span><span class="file-name">$escapedName/</span></a><span class="file-size">-</span></div>');
          } else if (entity is File) {
            final stat = await entity.stat();
            final size = _formatFileSize(stat.size);
            contentBuf.writeln('<div class="file-item"><a href="$encodedName"><span class="file-icon">&#128196;</span><span class="file-name">$escapedName</span></a><span class="file-size">$size</span></div>');
          }
        }

        if (entries.where((e) => !e.path.split('/').last.startsWith('.')).isEmpty) {
          contentBuf.writeln('<div class="file-item"><span class="file-name">Empty folder</span></div>');
        }
      } catch (e) {
        contentBuf.writeln('<div class="file-item"><span class="file-name">Error reading directory: ${_escapeHtml(e.toString())}</span></div>');
      }
    }

    // Try to load themed template
    try {
      final themeService = WebThemeService();
      await themeService.init();
      final template = await themeService.getNamedTemplate('shared', 'directory.html');
      if (template != null) {
        final profile = ProfileService().getProfile();
        final collectionName = profile.nickname.isNotEmpty ? profile.nickname : profile.callsign;
        final menuItems = await AppService().generateDeviceMenu(
          activeApp: 'shared',
          appsPath: p.dirname(storagePath),
          depth: 2,
        );

        return themeService.processTemplate(template, {
          'COLLECTION_NAME': collectionName,
          'FOLDER_NAME': _escapeHtml(title),
          'FOLDER_SLUG': folderSlug,
          'CONTENT': contentBuf.toString(),
          'MENU_ITEMS': menuItems,
          'HOME_URL': '../../',
          'NOSTR_STYLES': getNostrLoginStyles(),
          'NOSTR_HEADER': getNostrLoginHeaderHtml(),
          'NOSTR_SCRIPTS': getNostrLoginScripts(),
          'GENERATED_DATE': DateTime.now().toIso8601String().split('T').first,
        });
      }
    } catch (e) {
      LogService().log('Error loading shared directory template, using fallback: $e');
    }

    // Fallback: minimal inline HTML
    return '<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${_escapeHtml(title)}</title></head><body><a href="../">&larr; Back</a><h1>${_escapeHtml(title)}</h1>${contentBuf.toString()}</body></html>';
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  /// Public wrapper for testing cookie extraction via debug API
  String? testExtractNostrPubkey(String? headersStr) {
    return _extractNostrPubkeyFromHeaders(headersStr);
  }

  /// Extract Nostr pubkey from HTTP headers cookie string
  String? _extractNostrPubkeyFromHeaders(String? headersStr) {
    if (headersStr == null || headersStr.isEmpty) return null;
    // Headers come as multi-line string from HttpHeaders.toString()
    // Look for cookie: line containing geogram_nostr_pubkey=<64-char-hex>
    final lines = headersStr.split('\n');
    for (final line in lines) {
      final lower = line.toLowerCase().trim();
      if (lower.startsWith('cookie:')) {
        final cookieStr = line.substring(line.indexOf(':') + 1).trim();
        final cookies = cookieStr.split(';');
        for (final cookie in cookies) {
          final parts = cookie.trim().split('=');
          if (parts.length == 2 && parts[0].trim() == 'geogram_nostr_pubkey') {
            final value = parts[1].trim();
            // Validate it's a 64-char hex string
            if (value.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
              return value.toLowerCase();
            }
          }
        }
      }
    }
    return null;
  }

  /// Check if a visitor is authorized to access a restricted shared folder
  /// Public wrapper for testing via debug API
  Future<bool> testIsAuthorizedReader(SharedFolder folder, String? visitorPubkey) async {
    return _isAuthorizedReader(folder, visitorPubkey);
  }

  Future<bool> _isAuthorizedReader(SharedFolder folder, String? visitorPubkey) async {
    if (visitorPubkey == null) return false;

    // Direct reader match (hex pubkeys)
    if (folder.allowedReaders.contains(visitorPubkey)) return true;

    // Group membership check
    if (folder.allowedGroups.isNotEmpty) {
      try {
        final profileStorage = AppService().profileStorage;
        if (profileStorage != null) {
          // Find groups app storage
          final apps = await AppService().loadApps();
          final groupsApp = apps.cast<App?>().firstWhere(
            (a) => a?.type == 'groups',
            orElse: () => null,
          );
          if (groupsApp?.storagePath != null) {
            final groupsStorage = ScopedProfileStorage.fromAbsolutePath(
              profileStorage, groupsApp!.storagePath!,
            );
            final groupsService = GroupsService();
            groupsService.setStorage(groupsStorage);

            // Convert visitor hex pubkey to npub for isMember check
            final visitorNpub = NostrCrypto.encodeNpub(visitorPubkey);

            for (final groupName in folder.allowedGroups) {
              final group = await groupsService.loadGroup(groupName);
              if (group != null && group.isMember(visitorNpub)) return true;
            }
          }
        }
      } catch (e) {
        LogService().log('Error checking group membership: $e');
      }
    }

    return false;
  }

  /// Static handler for blog API requests — returns response data.
  /// Path format: /api/blog/{filename}.html
  static Future<({int statusCode, String contentType, List<int> body})> _handleBlogApiRequestLocal(String path) async {
    final regex = RegExp(r'^/api/blog/([^/]+)\.html$');
    final match = regex.firstMatch(path);
    if (match == null) {
      return (statusCode: 400, contentType: 'text/plain', body: utf8.encode('Invalid blog path'));
    }

    final filename = match.group(1)!;
    final yearMatch = RegExp(r'^(\d{4})-').firstMatch(filename);
    if (yearMatch == null) {
      return (statusCode: 400, contentType: 'text/plain', body: utf8.encode('Invalid blog filename format'));
    }
    final year = yearMatch.group(1)!;

    final apps = await AppService().loadApps();
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) {
      return (statusCode: 500, contentType: 'text/plain', body: utf8.encode('Storage not available'));
    }

    BlogPost? foundPost;
    List<String> foundPostLikedHexPubkeys = [];

    for (final app in apps) {
      if (app.visibility == 'private') continue;
      if (app.type != 'blog') continue;
      final storagePath = app.storagePath;
      if (storagePath == null) continue;

      final appStorage = ScopedProfileStorage.fromAbsolutePath(profileStorage, storagePath);
      final postRelativePath = '$year/$filename/post.md';
      final content = await appStorage.readString(postRelativePath);

      if (content != null) {
        try {
          foundPost = BlogPost.fromText(content, filename);

          final postFolderPath = '$year/$filename';
          final feedbackCounts = await FeedbackFolderUtils.getAllFeedbackCounts(
            postFolderPath,
            storage: appStorage,
          );
          foundPost = foundPost.copyWith(
            likesCount: feedbackCounts[FeedbackFolderUtils.feedbackTypeLikes] ?? 0,
            dislikesCount: feedbackCounts[FeedbackFolderUtils.feedbackTypeDislikes] ?? 0,
            pointsCount: feedbackCounts[FeedbackFolderUtils.feedbackTypePoints] ?? 0,
          );

          final likedNpubs = await FeedbackFolderUtils.readFeedbackFile(
            postFolderPath,
            FeedbackFolderUtils.feedbackTypeLikes,
            storage: appStorage,
          );
          foundPostLikedHexPubkeys = <String>[];
          for (final npub in likedNpubs) {
            try {
              foundPostLikedHexPubkeys.add(NostrCrypto.decodeNpub(npub));
            } catch (_) {}
          }
          break;
        } catch (e) {
          LogService().log('Error parsing blog file: $e');
        }
      }
    }

    if (foundPost == null) {
      return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Blog post not found'));
    }

    if (foundPost.isDraft) {
      return (statusCode: 403, contentType: 'text/plain', body: utf8.encode('This post is not published'));
    }

    final profile = ProfileService().getProfile();
    final author = profile.nickname.isNotEmpty ? profile.nickname : profile.callsign;

    final htmlContent = md.markdownToHtml(
      foundPost.content,
      extensionSet: md.ExtensionSet.gitHubWeb,
    );

    final html = await _buildBlogHtmlPageStatic(foundPost, htmlContent, author, foundPostLikedHexPubkeys);
    LogService().log('Served blog post: ${foundPost.title} (${html.length} bytes)');
    return (statusCode: 200, contentType: 'text/html', body: utf8.encode(html));
  }

  /// Build HTML page for blog post (static version)
  static Future<String> _buildBlogHtmlPageStatic(BlogPost post, String htmlContent, String author, [List<String> likedHexPubkeys = const []]) async {
    // Reuse the same menu generation as blog listing (generateBlogIndex)
    final menuItems = await AppService().generateDeviceMenu(
      activeApp: 'blog',
    );

    // Load blog-specific styles from theme
    String blogStyles = '';
    try {
      final themeService = WebThemeService();
      await themeService.init();
      blogStyles = await themeService.getAppStyles('blog') ?? '';
    } catch (_) {}

    return StationHtmlTemplates.buildBlogPostPage(
      postTitle: post.title,
      postDate: post.displayDate,
      author: author,
      htmlContent: htmlContent,
      description: post.description,
      tags: post.tags,
      menuItems: menuItems,
      postId: post.id,
      npub: post.npub,
      likesCount: post.likesCount,
      likedHexPubkeys: likedHexPubkeys,
      globalStyles: StationHtmlTemplates.getBaseStyles(),
      appStyles: blogStyles,
    );
  }

  /// Serve an NDF document as a read-only HTML page from the work app.
  /// Path format: /work/{workspaceId}/{filename}.ndf
  static Future<({int statusCode, String contentType, List<int> body})> _handleWorkPageLocal(
    String path, {
    String? headersJson,
  }) async {
    try {
      // Parse: /work/{workspaceId}/{filename}.ndf
      final decodedPath = Uri.decodeFull(path);
      final parts = decodedPath.split('/').where((p) => p.isNotEmpty).toList();
      // ['work', workspaceId, filename.ndf]
      if (parts.length < 3 || parts[0] != 'work') {
        return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Not Found'));
      }

      final workspaceId = parts[1];
      final filename = parts.sublist(2).join('/');

      // Find work app
      final apps = await AppService().loadApps();
      final workApp = apps.cast<App?>().firstWhere(
        (a) => a?.type == 'work',
        orElse: () => null,
      );
      if (workApp?.storagePath == null) {
        return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Work app not found'));
      }

      final profileStorage = AppService().profileStorage;
      if (profileStorage == null) {
        return (statusCode: 500, contentType: 'text/plain', body: utf8.encode('Storage not available'));
      }

      final workStorage = WorkStorageService(profileStorage, workApp!.storagePath!);
      final workspace = await workStorage.loadWorkspace(workspaceId);
      if (workspace == null || !workspace.documents.contains(filename)) {
        return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Not Found'));
      }

      // Check visibility
      final visibility = workspace.getDocumentVisibility(filename);
      switch (visibility.level) {
        case TrackerVisibilityLevel.private:
          return (statusCode: 403, contentType: 'text/plain', body: utf8.encode('Forbidden'));
        case TrackerVisibilityLevel.public:
          break;
        case TrackerVisibilityLevel.unlisted:
          // For local hotspot requests, no query params available — allow access
          break;
        case TrackerVisibilityLevel.restricted:
          final visitorPubkey = WebSocketService()._extractNostrPubkeyFromHeaders(headersJson);
          if (visitorPubkey == null) {
            return (statusCode: 403, contentType: 'text/plain', body: utf8.encode('Forbidden'));
          }
          final visitorNpub = NostrCrypto.encodeNpub(visitorPubkey);
          final contactMatch = visibility.allowedContacts.any((c) => c.npub == visitorNpub);
          if (!contactMatch) {
            return (statusCode: 403, contentType: 'text/plain', body: utf8.encode('Forbidden'));
          }
          break;
      }

      // Read NDF bytes
      final ndfBytes = await workStorage.readDocumentBytes(workspaceId, filename);
      if (ndfBytes == null) {
        return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Not Found'));
      }

      // Get owner info
      String identifier = AppService().currentCallsign ?? '';
      try {
        final profile = ProfileService().getProfile();
        if (profile.callsign.isNotEmpty) {
          identifier = profile.nickname ?? profile.callsign;
        }
      } catch (_) {}

      final menuItems = await AppService().generateDeviceMenu(
        activeApp: 'work',
        depth: 2,
      );

      final html = NdfWebViewerService().buildPage(
        ndfBytes,
        ownerIdentifier: identifier,
        workspaceName: workspace.name,
        menuItems: menuItems,
        logoText: identifier,
        logoHref: '../../',
      );

      if (html == null) {
        return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('Unsupported document type'));
      }

      return (statusCode: 200, contentType: 'text/html', body: utf8.encode(html));
    } catch (e) {
      LogService().log('WebSocketService: Error serving work page: $e');
      return (statusCode: 500, contentType: 'text/plain', body: utf8.encode('Internal error'));
    }
  }

  /// Serve the download page listing available update binaries.
  /// Scans the updates directory on disk for local files and reads
  /// release.json for metadata (version, release notes).
  static Future<({int statusCode, String contentType, List<int> body})> _handleDownloadPage() async {
    final updatesDir = '${StorageConfig().baseDir}/updates';
    Map<String, String> availableAssets = {};
    String? releaseVersion;
    String? releaseNotes;

    // Read release.json for metadata (version, release notes)
    try {
      final releaseFile = File('$updatesDir/release.json');
      if (await releaseFile.exists()) {
        final content = await releaseFile.readAsString();
        final release = jsonDecode(content) as Map<String, dynamic>;
        releaseVersion = release['version'] as String?;
        releaseNotes = release['body'] as String?;
      }
    } catch (e) {
      LogService().log('Error reading release.json for download page: $e');
    }

    // Always scan disk for locally available binaries (prefer local files)
    try {
      final dir = Directory(updatesDir);
      if (await dir.exists()) {
        // Find version directories, sorted descending
        final versionDirs = <String, Directory>{};
        await for (final entity in dir.list()) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (RegExp(r'^\d+\.\d+').hasMatch(name)) {
              versionDirs[name] = entity;
            }
          }
        }

        if (versionDirs.isNotEmpty) {
          // Sort versions descending, pick latest
          final sortedVersions = versionDirs.keys.toList()
            ..sort((a, b) {
              final aParts = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
              final bParts = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();
              for (var i = 0; i < aParts.length && i < bParts.length; i++) {
                if (aParts[i] != bParts[i]) return bParts[i].compareTo(aParts[i]);
              }
              return bParts.length.compareTo(aParts.length);
            });

          final latestVersion = sortedVersions.first;
          releaseVersion ??= latestVersion;
          final latestDir = versionDirs[latestVersion]!;

          // Scan files in the latest version directory
          await for (final file in latestDir.list()) {
            if (file is File) {
              final filename = file.path.split('/').last;
              final assetType = UpdateAssetType.fromFilename(filename);
              if (assetType != UpdateAssetType.unknown) {
                availableAssets[assetType.name] = '/updates/$latestVersion/$filename';
              }
            }
          }
        }
      }
    } catch (e) {
      LogService().log('Error scanning updates directory: $e');
    }

    final profile = ProfileService().getProfile();
    final displayName = profile.nickname.isNotEmpty ? profile.nickname : profile.callsign;

    // Generate device menu with download as active
    final menuItems = await AppService().generateDeviceMenu(
      activeApp: 'download',
      appsPath: null,
    );

    final html = StationHtmlTemplates.buildDownloadPage(
      stationName: displayName,
      menuItems: menuItems,
      availableAssets: availableAssets,
      releaseVersion: releaseVersion,
      releaseNotes: releaseNotes,
    );

    return (statusCode: 200, contentType: 'text/html', body: utf8.encode(html));
  }

  /// Serve update binary files from disk: /updates/{version}/{filename}
  static Future<({int statusCode, String contentType, List<int> body})> _handleUpdateFileServe(String path) async {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 3) {
      return (statusCode: 400, contentType: 'text/plain', body: utf8.encode('Invalid path: expected /updates/{version}/{filename}'));
    }

    final version = parts[1];
    final filename = parts.sublist(2).join('/');
    final updatesDir = '${StorageConfig().baseDir}/updates';
    final filePath = '$updatesDir/$version/$filename';
    final file = File(filePath);

    if (!await file.exists()) {
      LogService().log('Update file not found: $filePath');
      return (statusCode: 404, contentType: 'text/plain', body: utf8.encode('File not found: $filename'));
    }

    try {
      final fileBytes = await file.readAsBytes();

      // Content type based on extension
      String contentType = 'application/octet-stream';
      if (filename.endsWith('.apk')) {
        contentType = 'application/vnd.android.package-archive';
      } else if (filename.endsWith('.zip')) {
        contentType = 'application/zip';
      } else if (filename.endsWith('.tar.gz') || filename.endsWith('.tgz')) {
        contentType = 'application/gzip';
      }

      LogService().log('Served update file: $filename (${(fileBytes.length / (1024 * 1024)).toStringAsFixed(1)}MB)');
      return (statusCode: 200, contentType: contentType, body: fileBytes);
    } catch (e) {
      LogService().log('Error serving update file: $e');
      return (statusCode: 500, contentType: 'text/plain', body: utf8.encode('Error reading file'));
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

      // Send response back through WebSocket to station (preserve all headers)
      _sendHttpResponse(
        requestId,
        response.statusCode,
        response.headers,
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
  static String _getContentType(String filePath) {
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
    _reconnectTimer = MonitoredPeriodicTimer(
      id: 'websocket.reconnect',
      name: 'WS Reconnect',
      description: 'WebSocket reconnection monitor',
      serviceName: 'WebSocketService',
      interval: const Duration(seconds: 10),
      priority: TaskPriority.critical,
      callback: (_) => _checkConnection(),
    );
  }

  /// Start heartbeat ping timer
  void _startPingTimer() {
    _pingTimer?.cancel();
    // Send PING every 30 seconds (matches station heartbeat interval)
    _pingTimer = MonitoredPeriodicTimer(
      id: 'websocket.ping',
      name: 'WS Ping',
      description: 'WebSocket keepalive ping',
      serviceName: 'WebSocketService',
      interval: const Duration(seconds: 30),
      priority: TaskPriority.critical,
      callback: (_) => _sendPing(),
    );
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
        _lastPingAt = DateTime.now();
        LogService().log('Sent PING to station');
        _recordHeartbeat('ping');
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

    final now = DateTime.now();

    if (_channel != null) {
      final pongAge = _lastPongAt != null ? now.difference(_lastPongAt!) : null;
      final pingAge = _lastPingAt != null ? now.difference(_lastPingAt!) : null;

      if ((pongAge == null || pongAge > const Duration(seconds: 90)) &&
          pingAge != null &&
          pingAge > const Duration(seconds: 30)) {
        _consecutivePingMisses++;
        LogService().log('WebSocket: Missing PONG (${_consecutivePingMisses}x) - checking connection health');
        _recordHeartbeat('ping_miss', message: 'Missing PONG (${_consecutivePingMisses})', connected: true);

        if (_consecutivePingMisses >= 3) {
          LogService().log('WebSocket: Forcing reconnect after repeated missed PONGs');
          _handleConnectionLoss();
          _attemptReconnect();
          return;
        }
      }

      return; // Channel exists and no action needed
    }

    // Check if channel is still active
    LogService().log('Connection lost - attempting reconnection...');
    _attemptReconnect();
  }

  /// Handle connection loss
  void _handleConnectionLoss() {
    // Clean up channel regardless of reconnect state
    _channel = null;
    _subscription?.cancel();
    _subscription = null;
    _lastDisconnectAt = DateTime.now();
    _recordHeartbeat('disconnected', connected: false);

    // Clear mirror discovery state (station-sourced mirrors no longer valid)
    MirrorDiscoveryService().clear();

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
    _lastReconnectAttemptAt = DateTime.now();
    _recordHeartbeat('reconnect_attempt', message: 'Attempting reconnect');
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
        _reconnectFailures++;
        _recordHeartbeat('reconnect_failed', message: 'Reconnection failed (${"$_reconnectFailures"} failures)');
      }
    } catch (e) {
      LogService().log('✗ Reconnection failed: $e');
      _isReconnecting = false;
      _reconnectFailures++;
      _recordHeartbeat('reconnect_error', message: e.toString());
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
      _lastKeepAlivePingAt = DateTime.now();
      _recordHeartbeat('keepalive_ping');
      _sendPing();
    };

    // Set up callback for when service restarts after Android 15+ dataSync timeout
    // This triggers a connection check and reconnection if needed
    foregroundService.onServiceRestarted = () {
      LogService().log('WebSocket: Foreground service restarted after timeout, checking connection...');
      _recordHeartbeat('service_restarted', message: 'Android foreground service restarted after dataSync timeout');
      _checkConnection();
    };

    // Extract station info and callsign for the notification
    String? stationName;
    String? stationHost;
    String? callsign;
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

    // Get the user's callsign from the current profile
    try {
      final profile = ProfileService().getProfile();
      if (profile.callsign.isNotEmpty) {
        callsign = profile.callsign;
      }
    } catch (_) {
      // Ignore profile errors
    }

    // Enable keep-alive in the foreground service with station info and callsign
    foregroundService.enableKeepAlive(
      callsign: callsign,
      stationName: stationName,
      stationUrl: stationHost,
    );
    _foregroundKeepAliveEnabled = true;
    LogService().log('WebSocket: Enabled foreground service keep-alive for ${stationName ?? stationHost ?? "station"}');
    _recordHeartbeat('keepalive_enabled', message: 'Foreground service keep-alive enabled');
  }

  /// Disable Android foreground service keep-alive for WebSocket
  /// This is called when WebSocket disconnects from the station
  void _disableForegroundKeepAlive() {
    // Only relevant on Android
    if (kIsWeb) return;
    if (!Platform.isAndroid) return;

    final foregroundService = BLEForegroundService();
    foregroundService.onKeepAlivePing = null;
    foregroundService.onServiceRestarted = null;
    foregroundService.disableKeepAlive();
    _foregroundKeepAliveEnabled = false;
    LogService().log('WebSocket: Disabled foreground service keep-alive');
    _recordHeartbeat('keepalive_disabled', message: 'Foreground service keep-alive disabled');
  }

  Future<String?> _ensureHeartbeatPath() async {
    if (_heartbeatPath != null) return _heartbeatPath;
    try {
      String base;
      if (StorageConfig().isInitialized) {
        base = StorageConfig().logsDir;
      } else {
        // Fallback to system temp — never write to Documents
        base = p.join(Directory.systemTemp.path, 'geogram', 'logs');
      }
      final dir = Directory(base);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _heartbeatPath = p.join(base, 'heartbeat.json');
      return _heartbeatPath;
    } catch (e) {
      LogService().log('WebSocket: Unable to resolve heartbeat path: $e');
      return null;
    }
  }

  Future<void> _recordHeartbeat(
    String event, {
    String? message,
    bool? connected,
  }) async {
    try {
      final path = await _ensureHeartbeatPath();
      if (path == null) return;

      final data = <String, dynamic>{
        'event': event,
        'message': message,
        'stationUrl': _stationUrl,
        'connected': connected ?? (_channel != null),
        'shouldReconnect': _shouldReconnect,
        'keepAliveEnabled': _foregroundKeepAliveEnabled,
        'lastHello': _lastHelloAt?.toIso8601String(),
        'lastPing': _lastPingAt?.toIso8601String(),
        'lastPong': _lastPongAt?.toIso8601String(),
        'lastKeepAlivePing': _lastKeepAlivePingAt?.toIso8601String(),
        'lastReconnectAttempt': _lastReconnectAttemptAt?.toIso8601String(),
        'lastReconnectSuccess': _lastReconnectSuccessAt?.toIso8601String(),
        'lastDisconnect': _lastDisconnectAt?.toIso8601String(),
        'reconnectFailures': _reconnectFailures,
        'consecutivePingMisses': _consecutivePingMisses,
        'updatedAt': DateTime.now().toIso8601String(),
      };

      final file = File(path);
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      LogService().log('WebSocket: Failed to write heartbeat: $e');
    }
  }

  /// Populate station relay addresses for all mirror peers after station connect.
  ///
  /// Derives the HTTP base URL from the connected WebSocket URL and stores a
  /// `station://host/device/{peerCallsign}` address in each peer's addresses list.
  void _updateMirrorRelayAddresses() {
    if (_stationUrl == null) return;
    try {
      final wsUri = Uri.parse(_stationUrl!);

      final configService = MirrorConfigService.instance;
      final config = configService.config;
      if (config == null || !config.enabled) return;

      for (final peer in config.peers) {
        final relayAddr = 'station://${wsUri.host}${wsUri.hasPort ? ':${wsUri.port}' : ''}/device/${peer.callsign}';
        if (!peer.addresses.contains(relayAddr)) {
          peer.addresses.add(relayAddr);
          LogService().log('MirrorRelay: added relay address for ${peer.callsign}: $relayAddr');
        }
      }
      // Save updated addresses (fire-and-forget).
      configService.saveConfig(config);
    } catch (e) {
      LogService().log('MirrorRelay: failed to update relay addresses: $e');
    }
  }

  /// Remove station relay addresses from all mirror peers on disconnect.
  void _clearMirrorRelayAddresses() {
    try {
      final configService = MirrorConfigService.instance;
      final config = configService.config;
      if (config == null) return;

      var changed = false;
      for (final peer in config.peers) {
        final before = peer.addresses.length;
        peer.addresses.removeWhere((a) => a.startsWith('station://'));
        if (peer.addresses.length != before) changed = true;
      }
      if (changed) {
        configService.saveConfig(config);
        LogService().log('MirrorRelay: cleared relay addresses');
      }
    } catch (e) {
      LogService().log('MirrorRelay: failed to clear relay addresses: $e');
    }
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
