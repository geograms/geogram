import 'dart:async';
import 'dart:convert';
import 'dart:io' as io if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;
import 'package:mime/mime.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'hotspot_portal_service.dart';
import '../util/managed_http_client.dart' show streamDownloadToFile;
import 'log_service.dart';
import 'config_service.dart';
import 'profile_service.dart';
import 'signing_service.dart';
import 'app_service.dart';
import 'debug_controller.dart';
import 'now_service.dart';
import '../models/now_item.dart';
import 'task_monitor_service.dart';
import 'power_aware_service.dart';
import 'security_service.dart';
import 'storage_config.dart';
import 'user_location_service.dart';
import 'chat_service.dart';
import 'profile_storage.dart';
import 'direct_message_service.dart';
import 'message_retention_service.dart';
import 'devices_service.dart';
import 'mirror_discovery_service.dart';
import 'conference_service.dart';
import 'conference_archive_service.dart';
import 'conference_schedule_service.dart';
import 'conference_web_page_service.dart';
import 'event_web_page_service.dart';
import 'device_apps_service.dart';
import 'remote_blog_actions.dart';
import 'remote_content_client.dart';
import 'remote_event_actions.dart';
import 'chat_file_upload_manager.dart';
import 'app_args.dart';
import '../connection/connection_manager.dart';
import '../connection/transport_message.dart';
import '../teleport/aprs/aprs_is_client.dart';
import '../teleport/aprs/aprs_message_utils.dart';
import '../teleport/aprs/aprs_service.dart';
import '../teleport/aprs/models/aprs_packet.dart';
import '../teleport/aprs/blue_aprs_service.dart';
import '../models/ble_message.dart';
import 'location_provider_service.dart';
import '../teleport/telegram/telegram_service.dart';
import '../teleport/signal/models/signal_auth_state.dart';
import '../teleport/signal/signal_service.dart';
import '../teleport/irc/irc_service.dart';
import '../teleport/xmpp/xmpp_service.dart';
import '../teleport/xmpp/models/xmpp_server_config.dart';
import 'xmpp_server_stub.dart' if (dart.library.io) 'xmpp_server.dart';
import '../teleport/nostr/nostr_client_service.dart';
import '../teleport/nostr/models/nostr_relay_config.dart';
import '../teleport/atproto/atproto_client_service.dart';
import '../teleport/atproto/atproto_local_pds_service.dart';
import '../teleport/irc/models/irc_server_config.dart';
import 'file_index_service.dart';
import 'sqlite_loader.dart';
import 'local_backup_service.dart';
import '../version.dart';
import '../models/chat_channel.dart';
import '../models/chat_message.dart';
import '../models/conference_archive_entry.dart';
import '../models/conference_schedule_entry.dart';
import '../util/chat_format.dart';
import '../util/html_utils.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
import '../work/models/ndf_permission.dart';
import '../util/reaction_utils.dart';
import '../util/nostr_bundle.dart';
import '../util/feedback_folder_utils.dart';
import '../util/contributor_folder_utils.dart';
import 'audio_service.dart';
import 'backup_service.dart';
import '../models/backup_models.dart';
import 'event_service.dart';
import '../models/event.dart';
import 'blog_service.dart';
import 'report_service.dart';
import '../models/blog_post.dart';
import '../models/report.dart';
import 'alert_feedback_service.dart';
import 'alert_sharing_service.dart';
import 'mirror_auto_sync_service.dart';
import 'mirror_config_service.dart';
import 'mirror_sync_service.dart';
import '../models/mirror_config.dart';
import 'encrypted_storage_stub.dart' if (dart.library.ui) 'encrypted_storage_service.dart';
import 'place_feedback_service.dart';
import 'place_service.dart';
import 'place_sharing_service.dart';
import 'station_place_service.dart';
import '../models/place.dart';
import 'station_alert_service.dart';
import '../api/handlers/apps_handler.dart';
import '../api/handlers/blog_handler.dart';
import '../api/handlers/video_handler.dart';
import 'station_service.dart';
import 'station_server_service_stub.dart' if (dart.library.ui) 'station_server_service.dart';
import 'peer_relay_service.dart';
import 'websocket_service.dart';
import 'web_theme_service.dart';
import 'cli_console_controller.dart';
import 'email_service.dart';
import '../models/email_thread.dart';
import '../bot/models/music_model_info.dart';
import '../bot/models/vision_model_info.dart';
import '../bot/services/music_model_manager.dart';
import '../bot/services/vision_model_manager.dart';
import '../models/station.dart';
import '../util/alert_folder_utils.dart';
import '../wallet/services/wallet_service.dart';
import '../wallet/services/wallet_sync_service.dart';
import '../wallet/models/debt_ledger.dart';
import '../wallet/models/debt_entry.dart';
import '../wallet/models/debt_summary.dart';
import '../util/feedback_comment_utils.dart';
import '../util/feedback_folder_utils.dart';
import '../p2p/p2p_service.dart';
import '../transfer/models/transfer_models.dart';
import '../transfer/models/transfer_offer.dart';
import '../transfer/services/transfer_service.dart';
import '../transfer/services/p2p_transfer_service.dart';
import '../pages/transfer_send_page.dart';
import '../util/event_bus.dart';
import '../util/event_activity_notifier.dart';
import '../util/station_html_templates.dart';
import '../server/mixins/chat_modification_mixin.dart';
import '../server/mixins/content_browse_mixin.dart';
import '../server/mixins/contributor_submit_mixin.dart';
import '../models/shared_folder.dart';
import 'shared_folder_service.dart';
import 'groups_service.dart';
import 'hotspot_portal_service.dart';
import '../models/app.dart';
import '../tracker/models/tracker_visibility.dart';
import '../work/models/workspace.dart';
import '../work/services/ndf_service.dart';
import '../work/services/ndf_web_viewer_service.dart';
import '../work/services/work_storage_service.dart';
import '../stories/models/story_content.dart';
import '../stories/models/story_element.dart';
import '../stories/models/story_scene.dart';
import '../stories/services/stories_storage_service.dart';
import '../stories/services/story_ndf_service.dart';
import '../stories/services/story_web_viewer_service.dart';
import '../util/nostr_login_scripts.dart';
import '../work/models/ndf_document.dart';
import '../work/models/ndf_interaction_settings.dart';
import 'package:archive/archive.dart';
import 'file_browser_cache_service.dart';
import '../util/video_metadata_extractor.dart';
import '../api/handlers/feedback_handler.dart';
import '../api/handlers/feedback_delete_helper.dart';
import 'contact_service.dart';
import '../models/contact.dart';

class _MeetSessionSnapshot {
  final String state;
  final ConferenceArchiveEntry? archive;
  final ConferenceScheduleEntry? schedule;

  const _MeetSessionSnapshot._({
    required this.state,
    this.archive,
    this.schedule,
  });

  const _MeetSessionSnapshot.active() : this._(state: 'active');
  const _MeetSessionSnapshot.scheduled(ConferenceScheduleEntry schedule)
      : this._(state: 'scheduled', schedule: schedule);
  const _MeetSessionSnapshot.archive(ConferenceArchiveEntry archive)
      : this._(state: 'archive', archive: archive);
}

class LogApiService
    with ChatModificationMixin, ContentBrowseMixin, ContributorSubmitMixin {
  static final LogApiService _instance = LogApiService._internal();
  factory LogApiService() => _instance;
  LogApiService._internal();

  @override
  ProfileStorage get contentBrowseStorage {
    final dataDir = StorageConfig().baseDir;
    final callsign = ProfileService().getProfile().callsign;
    return FilesystemProfileStorage('$dataDir/devices/$callsign');
  }

  @override
  ProfileStorage get contributorStorage => contentBrowseStorage;

  @override
  void contributorLog(String level, String message) =>
      LogService().log('Contributor [$level]: $message');

  @override
  void onContributionSubmitted(String eventPath, String callsign) {
    // Pending submissions surface via the Now panel through
    // EventActivityNotifier scanning. Just log for diagnostics; the
    // notifier watcher picks up the new folder on its next tick.
    LogService().log(
      'Contributor: new pending submission from $callsign in $eventPath',
    );
  }

  @override
  void contentBrowseLog(String level, String message) =>
      LogService().log('ContentBrowse [$level]: $message');

  // Use dynamic to avoid type conflicts between stub and real dart:io
  dynamic _server;

  /// Track when the service started for uptime calculation
  DateTime? _startTime;

  /// Flag indicating the SetupMirror page is currently open
  static bool mirrorSetupOpen = false;

  final Map<String, StreamSubscription<double>> _botDownloadSubscriptions = {};

  /// Console controller for /api/cli
  CliConsoleController? _cliController;
  final AtprotoLocalPdsService _atprotoLocalPds = AtprotoLocalPdsService();

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
      if (chatService.appPath != null) {
        return true;
      }

      // Find chat collection in active profile's directory
      final appsDir = AppService().appsDirectory;
      if (appsDir == null) {
        LogService().log('LogApiService: No collections directory available');
        return false;
      }

      final chatDir = io.Directory('$appsDir/chat');
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

      // Set profile storage for encrypted storage support
      final profileStorage = AppService().profileStorage;
      if (profileStorage != null) {
        final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
          profileStorage,
          chatDir.path,
        );
        chatService.setStorage(scopedStorage);
      } else {
        chatService.setStorage(FilesystemProfileStorage(chatDir.path));
      }

      // Initialize ChatService with the chat collection
      await chatService.initializeApp(chatDir.path, creatorNpub: npub);
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
    List<int>? bodyBytes,
  }) async {
    try {
      // Create a mock shelf.Request
      // shelf.Request expects URL without leading slash for the path portion
      final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
      final uri = Uri.parse('http://localhost:$port/$normalizedPath');

      // For POST/PUT requests with body, we need to include it.
      // shelf.Request body accepts String OR List<int> — bodyBytes
      // wins for binary uploads (proxied images/video) so we don't
      // round-trip through utf8 and corrupt bytes.
      final request = shelf.Request(
        method,
        uri,
        headers: headers,
        body: bodyBytes ?? body,
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

    // Portal routes — always serve portal pages (for LAN and hotspot users)
    final portal = HotspotPortalService();
    final portalResponse = await portal.handleShelfRequest(request);
    if (portalResponse != null) return portalResponse;

    final urlPath = request.url.path;

    if (request.method == 'GET') {
      if (urlPath == 'styles.css') {
        return await _handleThemeStylesRequest(headers);
      }
      if (urlPath == 'lib/nostr.bundle.js') {
        return _handleNostrBundleRequest(headers);
      }
      if (urlPath == 'meet/styles.css' || urlPath == 'api/meet/styles.css') {
        return await _handleThemeStylesRequest(headers, appType: 'meet');
      }
      if (urlPath == 'meet/active') {
        return _handleMeetActiveRequest(headers);
      }
      if (urlPath == 'meet/info') {
        return _handleMeetInfoRequest(headers);
      }
      if (urlPath.startsWith('meet/')) {
        final response = await _handleMeetRoute(request, urlPath, headers);
        if (response != null) {
          return response;
        }
      }
      if (urlPath.startsWith('tiles/')) {
        return _handleLocalTileRequest(request, urlPath, headers);
      }
      if (urlPath == 'events/styles.css') {
        return await _handleThemeStylesRequest(headers, appType: 'events');
      }
      if (urlPath == 'blog/styles.css') {
        return await _handleThemeStylesRequest(headers, appType: 'blog');
      }
      if (urlPath == 'events' || urlPath.startsWith('events/')) {
        final response = await _handleEventsRoute(request, urlPath, headers);
        if (response != null) {
          return response;
        }
      }
    }

    // Work document routes — GET for HTML pages, POST/DELETE for feedback actions
    // Placed outside the GET block so feedback POST/DELETE also works
    // Handle both direct paths (work/...) and station-proxied paths (apps/work/...)
    var workUrlPath = urlPath;
    if (workUrlPath.startsWith('apps/work/')) {
      workUrlPath = workUrlPath.substring(5); // Strip 'apps/' prefix
    }
    if (workUrlPath.startsWith('work/')) {
      final response = await _handleWorkRoute(request, workUrlPath, headers);
      if (response != null) {
        return response;
      }
    }

    // Stories routes — gallery and individual story viewer
    if (urlPath.startsWith('stories/')) {
      final response = await _handleStoriesRoute(request, urlPath, headers);
      if (response != null) {
        return response;
      }
    }

    // Local AT Proto PDS endpoints (served on device API port, e.g. 3456)
    if (urlPath.startsWith('xrpc/') ||
        urlPath.startsWith('api/atproto/') ||
        urlPath == 'did.json' ||
        urlPath == '.well-known/did.json') {
      await _ensureAtprotoPdsStarted();
      final atprotoResponse = await _atprotoLocalPds.handleRequest(
        request,
        urlPath,
        headers,
      );
      if (atprotoResponse != null) {
        return atprotoResponse;
      }
    }

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

    // Meet endpoints: /api/meet/*
    if (urlPath == 'api/meet/active' && request.method == 'GET') {
      return _handleMeetActiveRequest(headers);
    }
    if (urlPath == 'api/meet/info' && request.method == 'GET') {
      return _handleMeetInfoRequest(headers);
    }
    if (urlPath.startsWith('api/meet/session/') && request.method == 'GET') {
      final code = urlPath.substring('api/meet/session/'.length);
      if (code.isNotEmpty) {
        return await _handleMeetSessionStateRequest(code, headers);
      }
    }
    if (urlPath.startsWith('api/meet/') && request.method == 'GET') {
      final response = await _handleMeetRoute(
        request,
        urlPath.substring('api/'.length),
        headers,
      );
      if (response != null) {
        return response;
      }
    }

    // Files endpoint: /api/files or /files (legacy)
    if ((urlPath == 'api/files' || urlPath == 'files') && request.method == 'GET') {
      return _handleFilesRequest(request, headers);
    }

    // File content endpoint: /api/files/content or /files/content (legacy)
    if ((urlPath == 'api/files/content' || urlPath == 'files/content') && request.method == 'GET') {
      return _handleFileContentRequest(request, headers);
    }

    // Mirror discovery debug endpoints
    if (urlPath == 'api/debug/mirrors' && request.method == 'GET') {
      return _handleDebugMirrors(headers);
    }
    if (urlPath == 'api/debug/peer-relay' &&
        request.method == 'GET' &&
        SecurityService().debugApiEnabled) {
      return shelf.Response.ok(
        jsonEncode(PeerRelayService().getStatus()),
        headers: headers,
      );
    }
    if (urlPath == 'api/debug/sync-trigger' && request.method == 'POST') {
      return await _handleDebugSyncTrigger(request, headers);
    }

    // Now (activity feed) debug endpoints
    if (urlPath.startsWith('api/debug/now') && SecurityService().debugApiEnabled) {
      return await _handleNowDebugRequest(request, urlPath, headers);
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

    // Chat room files listing
    if (urlPath.startsWith('api/chat/') && urlPath.endsWith('/files')) {
      final roomId = _extractRoomIdFromPath(urlPath);
      if (roomId != null && request.method == 'GET') {
        return await _handleChatFilesRequest(request, roomId, headers);
      }
    }

    // Chat room file download: /api/chat/{roomId}/files/{filename}
    final chatFileMatch = RegExp(r'^api/chat/(?:rooms/)?([^/]+)/files/(.+)$').firstMatch(urlPath);
    if (chatFileMatch != null && request.method == 'GET') {
      final roomId = Uri.decodeComponent(chatFileMatch.group(1)!);
      final filename = Uri.decodeComponent(chatFileMatch.group(2)!);
      return await _handleChatFileDownloadRequest(request, roomId, filename, headers);
    }

    // Chat message reactions
    if (urlPath.startsWith('api/chat/') &&
        urlPath.contains('/messages/') &&
        urlPath.endsWith('/reactions')) {
      return await _handleChatMessageReactionRequest(request, urlPath, headers);
    }

    // Chat modifications log endpoint
    // GET /api/chat/{roomId}/modifications?since=ISO_TIMESTAMP
    if (urlPath.startsWith('api/chat/') && urlPath.endsWith('/modifications') && request.method == 'GET') {
      return await _handleChatModificationsRequest(request, urlPath, headers);
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

    // GET/POST /api/dm/{callsign}/retention - get or set message retention
    final dmRetentionMatch = RegExp(r'^api/dm/([^/]+)/retention$').firstMatch(urlPath);
    if (dmRetentionMatch != null) {
      final targetCallsign = Uri.decodeComponent(dmRetentionMatch.group(1)!).toUpperCase();
      if (request.method == 'GET') {
        return await _handleDMGetRetention(request, targetCallsign, headers);
      } else if (request.method == 'POST') {
        return await _handleDMSetRetention(request, targetCallsign, headers);
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

    // Mirror Sync API endpoints
    if (urlPath.startsWith('api/mirror/')) {
      return await _handleMirrorRequest(request, urlPath, headers);
    }

    // P2P Transfer API endpoints
    if (urlPath.startsWith('api/p2p/')) {
      return await _handleP2PRequest(request, urlPath, headers);
    }

    // Apps discovery endpoint: single call returns all app availability + counts
    if (urlPath == 'api/apps' && request.method == 'GET') {
      return await _handleAppsDiscoveryRequest(headers);
    }

    // Generic content browse — /api/content/{appType}/…  backed by the
    // AppContentProvider registry. Handled entirely in the shared
    // mixin so every app type automatically surfaces here without a
    // per-app route.
    final contentResult =
        await handleContentBrowseShelf(request, urlPath);
    if (contentResult != null) return contentResult;

    // Contributor submissions (visitor-side upload to a remote event)
    final contributorResult =
        await handleContributorShelf(request, urlPath);
    if (contributorResult != null) return contributorResult;

    // Events API endpoints (public read-only access to events)
    if (urlPath == 'api/events' || urlPath == 'api/events/' || urlPath.startsWith('api/events/')) {
      return await _handleEventsRequest(request, urlPath, headers);
    }

    // Feedback API endpoints (signed views, likes, comments, …). The station
    // implementations duplicate this routing in three places already; mirror
    // it here too rather than risk diverging behaviours, but call into the
    // same shared FeedbackHandler so the actual logic stays single-sourced.
    if (urlPath.startsWith('api/feedback/')) {
      return await _handleFeedbackRequest(request, urlPath, headers);
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

    // Blog HTML rendering endpoint: /blog/{filename}.html or /{identifier}/blog/{filename}.html
    // Direct access (local device) or via station proxy
    if ((urlPath.startsWith('blog/') || urlPath.contains('/blog/')) && urlPath.endsWith('.html')) {
      return await _handleBlogHtmlRequest(request, urlPath, headers);
    }

    // Video API endpoints (public read access to video metadata and thumbnails)
    if (urlPath == 'api/videos' || urlPath == 'api/videos/' || urlPath.startsWith('api/videos/')) {
      return await _handleVideoRequest(request, urlPath, headers);
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

    // Wallet API endpoints
    if (urlPath == 'api/wallet/debts' || urlPath == 'api/wallet/debts/' || urlPath.startsWith('api/wallet/debts/')) {
      return await _handleWalletDebtsRequest(request, urlPath, headers);
    }
    if (urlPath == 'api/wallet/requests' || urlPath == 'api/wallet/requests/' || urlPath.startsWith('api/wallet/requests/')) {
      return await _handleWalletRequestsRequest(request, urlPath, headers);
    }
    if (urlPath == 'api/wallet/sync' && request.method == 'POST') {
      return await _handleWalletSyncRequest(request, headers);
    }

    // Console command API
    if (urlPath == 'api/cli' && request.method == 'POST') {
      return await _handleCliCommand(request, headers);
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

  Future<void> _ensureAtprotoPdsStarted() async {
    try {
      final storage = AppService().profileStorage;
      if (storage == null) return;
      final atproto = AtprotoClientService();
      await _atprotoLocalPds.start(storage: storage, config: atproto.config);
    } catch (e) {
      LogService().log('LogApiService: failed to start local AT Proto PDS: $e');
    }
  }

  /// Handle /api/cli endpoint - execute console commands
  Future<shelf.Response> _handleCliCommand(shelf.Request request, Map<String, String> headers) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final command = data['command'] as String?;

      if (command == null || command.trim().isEmpty) {
        return shelf.Response(400,
          body: jsonEncode({'status': 'error', 'error': 'Missing command'}),
          headers: headers,
        );
      }

      if (_cliController == null) {
        _cliController = CliConsoleController();
        await _cliController!.initialize();
      }

      final output = await _cliController!.processCommand(command);
      return shelf.Response.ok(
        jsonEncode({
          'status': 'ok',
          'output': output,
          'path': _cliController!.currentPath,
        }),
        headers: headers,
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'status': 'error', 'error': e.toString()}),
        headers: headers,
      );
    }
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
          '/styles.css': 'Global web theme stylesheet for device-hosted pages',
          '/meet/active': 'Active meeting info (room ID, signaling mode/port) or 404',
          '/meet/info': 'Room info (participants list) on the local device web server',
          '/meet/{code}': 'Meeting join page (HTML) on the local device web server',
          '/events/': 'Events listing page (HTML) with visibility filtering',
          '/events/{eventId}': 'Event detail page (HTML)',
          '/api/meet/active': 'Active meeting info (room ID, signaling port) or 404',
          '/api/meet/info': 'Room info (participants list)',
          '/api/meet/{code}': 'Meeting join page (HTML) for browser access via station',
          '/api/log': 'Get log entries (supports ?filter=text&limit=100)',
          '/api/files': 'Browse collections (supports ?path=subfolder)',
          '/api/files/content': 'Get file content (supports ?path=file/path)',
          '/api/chat/': 'List chat rooms (supports NOSTR auth for private rooms)',
          '/api/chat/{roomId}/messages': 'GET messages, POST to send (supports NOSTR-signed events)',
          '/api/chat/{roomId}/files': 'List files in a chat room',
          '/api/dm/conversations': 'List direct message conversations',
          '/api/dm/{callsign}/messages': 'GET/POST direct messages with a device',
          '/api/dm/{callsign}/retention': 'GET/POST message retention (disappearing messages) for a DM conversation',
          '/api/dm/sync/{callsign}': 'Sync DM messages with remote device',
          '/api/backup/settings': 'GET/PUT backup provider settings',
          '/api/backup/availability': 'GET provider availability (requires NOSTR auth)',
          '/api/backup/clients': 'GET list of backup clients (as provider)',
          '/api/backup/clients/{callsign}': 'GET/DELETE specific backup client',
          '/api/backup/providers': 'GET list of backup providers (as client)',
          '/api/backup/providers/{callsign}': 'POST invite, PUT update, DELETE remove provider',
          '/api/backup/start': 'POST start backup to provider',
          '/api/backup/status': 'GET current backup/restore status',
          '/api/backup/restore': 'POST start restore from provider',
          '/api/backup/discover': 'POST start discovery, GET /api/backup/discover/{id} for status',
          '/api/apps': 'GET aggregated app availability and item counts',
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
          '/api/wallet/debts': 'GET list debts, POST create debt',
          '/api/wallet/debts/{id}': 'GET debt details',
          '/api/wallet/debts/{id}/entries': 'POST add entry to debt',
          '/api/wallet/debts/{id}/verify': 'GET verify debt signatures',
          '/api/wallet/requests': 'GET list pending sync requests',
          '/api/wallet/requests/{id}/approve': 'POST approve sync request',
          '/api/wallet/requests/{id}/reject': 'POST reject sync request',
          '/api/wallet/sync': 'POST receive wallet sync data',
          '/api/mirror/challenge': 'GET authentication challenge (prevents replay attacks)',
          '/api/mirror/request': 'POST request simple mirror sync (with signed challenge)',
          '/api/mirror/manifest': 'GET folder manifest for sync',
          '/api/mirror/file': 'GET file content for sync',
          '/api/mirror/upload': 'POST upload a file to peer',
          '/api/mirror/pair': 'POST reciprocal pairing (registers both devices as peers)',
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
      'name': MirrorConfigService.instance.config?.deviceName ?? (callsign.isNotEmpty ? callsign : 'Geogram Desktop'),
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

    // Add device_id and mirror_enabled for LAN mirror discovery
    response['device_id'] = ConfigService().deviceId;
    response['mirror_enabled'] = MirrorConfigService.instance.isEnabled;
    response['can_relay'] = true;
    response['relay_http_port'] = port;

    // Add uptime in seconds
    if (_startTime != null) {
      response['uptime'] = DateTime.now().difference(_startTime!).inSeconds;
    }

    // Add mirror setup flag if open
    if (mirrorSetupOpen) {
      response['mirror_setup_open'] = true;
    }

    return shelf.Response.ok(
      jsonEncode(response),
      headers: headers,
    );
  }

  /// Handle GET /api/meet/info — returns room info (same as signaling server /meet/info).
  shelf.Response _handleMeetInfoRequest(Map<String, String> headers) {
    final conf = ConferenceService();
    if (!conf.isActive || conf.room == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'No active meeting'}),
        headers: headers,
      );
    }

    final room = conf.room!;
    final response = {
      'room_id': room.roomId,
      'room_name': room.roomName,
      'host_callsign': room.hostCallsign,
      'participant_count': room.participants.length,
      'speaker_count': room.speakerCount,
      'listener_count': room.listenerCount,
      'participants': room.participants.values.map((p) => p.callsign).toList(),
      'speakers': room.speakers.map((p) => p.callsign).toList(),
      'active_screen_sharer': room.activeScreenSharerCallsign,
      'max_participants': room.maxSpeakers,
    };

    return shelf.Response.ok(
      jsonEncode(response),
      headers: headers,
    );
  }

  Future<shelf.Response?> _handleMeetRoute(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    final rest = urlPath.substring('meet/'.length);
    final segments = rest.split('/').where((segment) => segment.isNotEmpty).toList();
    if (segments.isEmpty) {
      return _handleMeetListingPage(request, headers);
    }

    final code = segments.first;
    if (segments.length == 1) {
      return _handleMeetJoinPage(request, code, headers);
    }

    if (segments.length == 2 && segments[1] == 'state.json') {
      return _handleMeetSessionStateRequest(code, headers);
    }

    if (segments.length == 2 && segments[1] == 'archive.ndf') {
      return _handleMeetArchiveNdfDownload(code, headers);
    }

    final relativeFilePath = segments.sublist(1).join('/');
    return _handleMeetArchiveAssetRequest(request, code, relativeFilePath, headers);
  }

  String _meetRoomId(String code) {
    final callsign = ProfileService().getProfile().callsign;
    return '$code@$callsign';
  }

  Future<_MeetSessionSnapshot?> _resolveMeetSessionSnapshot(String code) async {
    final conf = ConferenceService();
    final activeRoom = conf.room;
    if (conf.isActive &&
        activeRoom != null &&
        activeRoom.hostCallsign.toUpperCase() ==
            ProfileService().getProfile().callsign.toUpperCase() &&
        (conf.roomCode ?? '').toUpperCase() == code.toUpperCase()) {
      return const _MeetSessionSnapshot.active();
    }

    final roomId = _meetRoomId(code);
    final schedule = await ConferenceScheduleService().findScheduleByRoomId(roomId);
    if (schedule != null && !schedule.isCompleted) {
      return _MeetSessionSnapshot.scheduled(schedule);
    }

    final archive = await ConferenceArchiveService().findArchiveByRoomId(roomId);
    if (archive != null) {
      return _MeetSessionSnapshot.archive(archive);
    }

    return null;
  }

  Future<shelf.Response> _handleMeetSessionStateRequest(
    String code,
    Map<String, String> headers,
  ) async {
    final snapshot = await _resolveMeetSessionSnapshot(code);
    if (snapshot == null) {
      return shelf.Response.notFound(
        jsonEncode({'state': 'not_found', 'code': code}),
        headers: headers,
      );
    }

    if (snapshot.state == 'active') {
      final conf = ConferenceService();
      final room = conf.room!;
      return shelf.Response.ok(
        jsonEncode({
          'state': 'active',
          'room_id': room.roomId,
          'room_name': room.roomName,
          'host_callsign': room.hostCallsign,
          'participant_count': room.participants.length,
          'max_participants': room.maxSpeakers,
          'station_meet_url': conf.shareableStationMeetUrl,
          'signaling_mode': room.signalingMode.name,
        }),
        headers: headers,
      );
    }

    if (snapshot.state == 'scheduled') {
      final schedule = snapshot.schedule!;
      return shelf.Response.ok(
        jsonEncode({
          'state': 'scheduled',
          ...schedule.toJson(),
        }),
        headers: headers,
      );
    }

    final archive = snapshot.archive!;
    return shelf.Response.ok(
      jsonEncode({
        'state': 'archive',
        ...archive.toJson(),
      }),
      headers: headers,
    );
  }

  Future<shelf.Response> _handleMeetArchiveAssetRequest(
    shelf.Request request,
    String code,
    String relativeFilePath,
    Map<String, String> headers,
  ) async {
    final isCoverImage = relativeFilePath.startsWith('cover.');
    if (relativeFilePath.isEmpty ||
        relativeFilePath.contains('..') ||
        (!relativeFilePath.startsWith('files/') &&
            !relativeFilePath.startsWith('recordings/') &&
            !relativeFilePath.startsWith('transcripts/') &&
            !isCoverImage)) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Asset not found'}),
        headers: headers,
      );
    }

    final archive = await ConferenceArchiveService().findArchiveByRoomId(
      _meetRoomId(code),
    );
    if (archive == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Meeting archive not found'}),
        headers: headers,
      );
    }

    final bytes = await ConferenceArchiveService().readArchiveFileBytes(
      archive,
      relativeFilePath,
    );
    if (bytes == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Asset not found'}),
        headers: headers,
      );
    }

    final isInline = request.url.queryParameters['inline'] == '1';
    final contentType =
        lookupMimeType(relativeFilePath, headerBytes: bytes) ??
        'application/octet-stream';
    final filename = relativeFilePath.split('/').last;
    final total = bytes.length;

    // Support Range requests (required for <video>/<audio> seeking & MP4 MOOV).
    final rangeHeader = request.headers['range'];
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring(6); // "start-end"
      final parts = spec.split('-');
      final start = parts[0].isNotEmpty ? int.parse(parts[0]) : 0;
      final end = (parts.length > 1 && parts[1].isNotEmpty)
          ? int.parse(parts[1])
          : total - 1;
      final length = end - start + 1;
      return shelf.Response(
        206,
        body: bytes.sublist(start, end + 1),
        headers: {
          ...headers,
          'Content-Type': contentType,
          'Content-Length': length.toString(),
          'Content-Range': 'bytes $start-$end/$total',
          'Accept-Ranges': 'bytes',
          if (!isInline)
            'Content-Disposition': 'attachment; filename="$filename"',
        },
      );
    }

    return shelf.Response.ok(
      bytes,
      headers: {
        ...headers,
        'Content-Type': contentType,
        'Content-Length': total.toString(),
        'Accept-Ranges': 'bytes',
        if (!isInline)
          'Content-Disposition': 'attachment; filename="$filename"',
      },
    );
  }

  Future<shelf.Response> _handleMeetArchiveNdfDownload(
    String code,
    Map<String, String> headers,
  ) async {
    final archive = await ConferenceArchiveService().findArchiveByRoomId(
      _meetRoomId(code),
    );
    if (archive == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Meeting archive not found'}),
        headers: headers,
      );
    }

    final bytes = await AppService().profileStorage!.readBytes(
      archive.relativePath,
    );
    if (bytes == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Archive file not found'}),
        headers: headers,
      );
    }

    final sanitizedName = archive.roomName.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return shelf.Response.ok(
      bytes,
      headers: {
        ...headers,
        'Content-Type': 'application/zip',
        'Content-Disposition': 'attachment; filename="$sanitizedName.ndf"',
        'Content-Length': bytes.length.toString(),
      },
    );
  }

  /// Handle GET /api/meet/{code} — serves an HTML join page for the meeting.
  Future<shelf.Response> _handleMeetJoinPage(
    shelf.Request request,
    String code,
    Map<String, String> headers,
  ) async {
    final snapshot = await _resolveMeetSessionSnapshot(code);
    if (snapshot == null) {
      final htmlHeaders = Map<String, String>.from(headers);
      htmlHeaders['Content-Type'] = 'text/html; charset=utf-8';
      return shelf.Response.notFound(
        _meetNotFoundHtml(code),
        headers: htmlHeaders,
      );
    }

    final htmlHeaders = Map<String, String>.from(headers);
    htmlHeaders['Content-Type'] = 'text/html; charset=utf-8';
    final hostNickname = ProfileService().getProfile().nickname;
    late final ConferenceWebPageConfig config;

    if (snapshot.state == 'active') {
      final conf = ConferenceService();
      final room = conf.room!;
      final signalingWsUrl = room.signalingMode == ConferenceSignalingMode.lan
          ? _lanSignalingWsUrl(request, conf)
          : WebSocketService().connectedUrl;
      config = ConferenceWebPageConfig(
        roomId: room.roomId,
        roomName: room.roomName,
        hostCallsign: room.hostCallsign,
        hostNickname: hostNickname,
        participantCount: room.participants.length,
        maxParticipants: room.maxSpeakers,
        transportMode: room.signalingMode.name,
        signalingWsUrl: signalingWsUrl,
        logoText: room.roomName,
        pageMode: 'active',
        sessionStateUrl: '$code/state.json',
        stationMeetUrl: conf.shareableStationMeetUrl,
        description: room.description,
      );
    } else if (snapshot.state == 'scheduled') {
      final schedule = snapshot.schedule!;
      config = ConferenceWebPageConfig(
        roomId: schedule.roomId,
        roomName: schedule.roomName,
        hostCallsign: schedule.hostCallsign,
        hostNickname: hostNickname,
        participantCount: 0,
        maxParticipants: schedule.maxSpeakers,
        transportMode: schedule.stationMeetUrl?.isNotEmpty == true
            ? ConferenceSignalingMode.station.name
            : ConferenceSignalingMode.lan.name,
        logoText: schedule.roomName,
        pageMode: 'scheduled',
        sessionStateUrl: '$code/state.json',
        stationMeetUrl: schedule.stationMeetUrl,
        scheduledAt: schedule.scheduledAt,
        description: schedule.description,
        statusText: schedule.scheduledAt == null
            ? 'Meeting scheduled. The host will start it when ready.'
            : 'Meeting scheduled for ${schedule.scheduledAt!.toLocal()}',
      );
    } else {
      final archive = snapshot.archive!;
      final messages = await ConferenceArchiveService().loadMessages(archive);
      config = ConferenceWebPageConfig(
        roomId: archive.roomId,
        roomName: archive.roomName,
        hostCallsign: archive.hostCallsign,
        hostNickname: hostNickname,
        participantCount: archive.participants.length,
        maxParticipants: archive.speakers.length,
        transportMode: archive.signalingMode,
        logoText: archive.roomName,
        pageMode: 'archive',
        sessionStateUrl: '$code/state.json',
        stationMeetUrl: archive.stationMeetUrl,
        startedAt: archive.startedAt,
        endedAt: archive.endedAt,
        initialMessages: messages.map((message) => message.toJson()).toList(),
        archiveFiles: archive.files
            .map(
              (asset) => {
                ...asset.toJson(),
                'url': Uri(
                  pathSegments: [code, ...asset.relativePath.split('/')],
                ).toString(),
              },
            )
            .toList(),
        archiveRecordings: archive.recordings
            .map(
              (asset) => {
                ...asset.toJson(),
                'url': Uri(
                  pathSegments: [code, ...asset.relativePath.split('/')],
                ).toString(),
              },
            )
            .toList(),
        archiveVoiceTranscripts: archive.voiceTranscripts
            .map(
              (asset) => {
                ...asset.toJson(),
                'url': Uri(
                  pathSegments: [code, ...asset.relativePath.split('/')],
                ).toString(),
              },
            )
            .toList(),
        archiveSessions: archive.sessions
            .map((s) => s.toJson())
            .toList(),
        archiveNdfUrl: '$code/archive.ndf',
        archiveCoverImageUrl: archive.coverImagePath != null
            ? '$code/${archive.coverImagePath}?inline=1'
            : null,
        statusText: 'Meeting archive',
      );
    }

    final assets = await ConferenceWebPageService().buildJoinPage(config);
    return shelf.Response.ok(assets.html, headers: htmlHeaders);
  }

  /// Extract hex pubkey from geogram_nostr_pubkey cookie.
  String? _extractNostrPubkeyFromCookie(shelf.Request request) {
    final cookieHeader = request.headers['cookie'];
    if (cookieHeader == null) return null;
    for (final cookie in cookieHeader.split(';')) {
      final parts = cookie.trim().split('=');
      if (parts.length == 2 && parts[0].trim() == 'geogram_nostr_pubkey') {
        final value = parts[1].trim();
        if (value.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
          return value.toLowerCase();
        }
      }
    }
    return null;
  }

  Future<shelf.Response> _handleMeetListingPage(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    // 1. Identify viewer via cookie or Authorization header
    String? userNpub;
    final hexPubkey = _extractNostrPubkeyFromCookie(request);
    if (hexPubkey != null) {
      try {
        userNpub = NostrCrypto.encodeNpub(hexPubkey);
      } catch (_) {}
    }
    userNpub ??= _verifyNostrAuth(request);

    // 2. Load archives, filter by NDF view permissions
    final conf = ConferenceService();
    final allArchives = await ConferenceArchiveService().listArchives();
    final activeRoomId = (conf.isActive && conf.room != null)
        ? conf.room!.roomId
        : null;
    final visible = <ConferenceArchiveEntry>[];
    for (final entry in allArchives) {
      if (activeRoomId != null && entry.roomId == activeRoomId) continue;
      // Unlisted archives are never shown in the listing
      if (entry.visibility == MeetingVisibility.unlisted) continue;
      final perms = await ConferenceArchiveService().loadPermissions(entry);
      if (perms == null) {
        visible.add(entry);
        continue;
      }
      if (userNpub != null &&
          perms.hasPermission(userNpub, NdfPermissionAction.view)) {
        visible.add(entry);
      } else if (userNpub == null &&
          perms.allowAnonymousView &&
          perms.access[NdfPermissionAction.view]?.type ==
              NdfAccessType.public) {
        visible.add(entry);
      }
    }

    // 3. Active meeting + schedules (filtered by visibility)
    Map<String, dynamic>? activeMeeting;
    if (conf.isActive && conf.room != null) {
      final room = conf.room!;
      final showActive = room.visibility == MeetingVisibility.public ||
          (room.visibility == MeetingVisibility.restricted && userNpub != null &&
              room.allowedContacts.any((c) => c.npub == userNpub));
      if (showActive) {
        activeMeeting = {
          'code': room.roomId.split('@').first,
          'roomName': room.roomName,
          'hostCallsign': room.hostCallsign,
          'participantCount': room.participants.length,
          'state': 'active',
        };
      }
    }
    final allSchedules = await ConferenceScheduleService()
        .listSchedules(includeCompleted: false);
    // Filter schedules by visibility
    final schedules = allSchedules.where((s) {
      if (s.visibility == MeetingVisibility.public) return true;
      if (s.visibility == MeetingVisibility.unlisted) return false;
      if (s.visibility == MeetingVisibility.private) return false;
      // Restricted: check if user is in allowed contacts
      if (s.visibility == MeetingVisibility.restricted && userNpub != null) {
        return s.allowedContacts.any((c) => c.npub == userNpub);
      }
      return false;
    }).toList();

    // 4. Build data payload
    final data = <String, dynamic>{
      'meetings': visible
          .map((e) => <String, dynamic>{
                'code': e.roomId.split('@').first,
                'roomName': e.roomName,
                'hostCallsign': e.hostCallsign,
                'startedAt': e.startedAt.toIso8601String(),
                'endedAt': e.endedAt?.toIso8601String(),
                'participantCount': e.participants.length,
                'messageCount': e.messageCount,
                'fileCount': e.files.length,
                'recordingCount': e.recordings.length,
                'tags': e.tags,
                'state': 'archive',
              })
          .toList(),
      if (activeMeeting != null) 'active': activeMeeting,
      'scheduled': schedules
          .map((s) => <String, dynamic>{
                'code': s.roomId.split('@').first,
                'roomName': s.roomName,
                'hostCallsign': s.hostCallsign,
                'scheduledAt': s.scheduledAt?.toIso8601String(),
                'state': 'scheduled',
              })
          .toList(),
      'authenticated': userNpub != null,
    };

    // 5. Generate device menu and render listing page
    final menuItems = await AppService().generateDeviceMenu(activeApp: 'meet');
    final assets = await ConferenceWebPageService().buildListingPage(
      data: data,
      logoText: 'Meetings',
      menuItems: menuItems,
    );
    final htmlHeaders = Map<String, String>.from(headers);
    htmlHeaders['Content-Type'] = 'text/html; charset=utf-8';
    return shelf.Response.ok(assets.html, headers: htmlHeaders);
  }

  String _meetNotFoundHtml(String code) {
    return '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Meeting Not Found</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
           display: flex; justify-content: center; align-items: center; min-height: 100vh;
           margin: 0; background: #1a1a2e; color: #eee; }
    .card { background: #16213e; border-radius: 16px; padding: 40px; max-width: 420px;
            text-align: center; box-shadow: 0 8px 32px rgba(0,0,0,0.3); }
    .icon { font-size: 64px; margin-bottom: 16px; }
    h1 { margin: 0 0 8px; font-size: 24px; }
    .subtitle { color: #a0a0b0; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">&#128528;</div>
    <h1>Meeting Not Found</h1>
    <p class="subtitle">The meeting "$code" is not active or has ended.</p>
  </div>
</body>
</html>''';
  }

  // ── Local tile serving ─────────────────────────────────────────────────

  Future<shelf.Response> _handleLocalTileRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    // Parse: tiles/{z}/{x}/{y}.png or tiles/{layer}/{z}/{x}/{y}.png
    final regex = RegExp(r'tiles/(?:[^/]+/)?(\d+)/(\d+)/(\d+)\.png');
    final match = regex.firstMatch(urlPath);
    if (match == null) {
      return shelf.Response.notFound('Invalid tile path');
    }
    final z = match.group(1)!;
    final x = match.group(2)!;
    final y = match.group(3)!;
    final layer = request.url.queryParameters['layer'] ?? 'standard';
    final tilesDir = StorageConfig().tilesDir;
    var file = io.File('$tilesDir/$layer/$z/$x/$y.png');
    if (!await file.exists()) {
      // Also check cache/ subdirectory (flutter_map tile cache layout)
      file = io.File('$tilesDir/cache/$layer/$z/$x/$y.png');
    }
    if (!await file.exists()) {
      return shelf.Response.notFound('');
    }
    return shelf.Response.ok(
      await file.readAsBytes(),
      headers: {
        ...headers,
        'Content-Type': 'image/png',
        'Cache-Control': 'public, max-age=86400',
      },
    );
  }

  // ── Events HTML routes ────────────────────────────────────────────────

  Future<shelf.Response?> _handleEventsRoute(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    // Strip prefix: "events" or "events/"
    final rest = urlPath.startsWith('events/')
        ? urlPath.substring('events/'.length)
        : '';
    final segments =
        rest.split('/').where((s) => s.isNotEmpty).toList();

    // /events or /events/
    if (segments.isEmpty) {
      return _handleEventsListingPage(request, headers);
    }

    final eventId = Uri.decodeComponent(segments.first);

    // /events/{eventId}/files/{path} → proxy to existing API file handler
    if (segments.length >= 3 && segments[1] == 'files') {
      final filePath = segments.sublist(2).map(Uri.decodeComponent).join('/');
      String? dataDir;
      try {
        dataDir = StorageConfig().baseDir;
      } catch (_) {
        return shelf.Response.internalServerError(
          body: 'Storage not initialized',
          headers: headers,
        );
      }
      // Resolve slug to real event ID for file serving
      final realId = await _resolveEventId(eventId, dataDir);
      if (realId == null) return null;
      return _handleEventsGetFile(realId, filePath, dataDir, headers,
          request: request);
    }

    // /events/{eventId}
    if (segments.length == 1) {
      return _handleEventDetailPage(request, eventId, headers);
    }

    return null;
  }

  /// Resolve an event identifier (folder ID or slug) to the real folder ID.
  Future<String?> _resolveEventId(String idOrSlug, String dataDir) async {
    final allEvents = await EventService().getAllEventsGlobal(dataDir);
    // Try by ID first
    for (final e in allEvents) {
      if (e.id == idOrSlug) return e.id;
    }
    // Fall back to slug
    for (final e in allEvents) {
      if (e.slug == idOrSlug) return e.id;
    }
    return null;
  }

  Future<shelf.Response> _handleEventsListingPage(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    // 1. Identify viewer via cookie or Authorization header
    String? userNpub;
    final hexPubkey = _extractNostrPubkeyFromCookie(request);
    if (hexPubkey != null) {
      try {
        userNpub = NostrCrypto.encodeNpub(hexPubkey);
      } catch (_) {}
    }
    userNpub ??= _verifyNostrAuth(request);

    // 2. Load events
    String? dataDir;
    try {
      dataDir = StorageConfig().baseDir;
    } catch (_) {
      return shelf.Response.internalServerError(
        body: 'Storage not initialized',
        headers: headers,
      );
    }
    final eventService = EventService();
    final allEvents = await eventService.getAllEventsGlobal(dataDir);
    final years = await eventService.getAvailableYearsGlobal(dataDir);

    // 3. Filter by visibility
    final viewerCallsign = await _resolveViewerCallsign(userNpub);
    final visible = <Event>[];
    for (final event in allEvents) {
      final vis = event.visibility;
      if (vis == 'public' || vis == 'request_access') {
        // request_access is publicly listed — the detail page is the
        // place where access is gated.
        visible.add(event);
        continue;
      }
      if (vis == 'private' || vis == 'unlisted') {
        // Never shown in listing. Owner / admin / explicit grants need to
        // navigate via the share URL or the desktop UI.
        continue;
      }
      if (vis == 'group') {
        // Show only if user is in one of the event's groups OR listed in
        // accessCallsigns OR is admin/author.
        final isAdminOrAuthor = userNpub != null &&
            (event.npub == userNpub || event.isAdmin(userNpub));
        bool allowed = isAdminOrAuthor;
        if (!allowed && userNpub != null) {
          allowed = await _eventViewerInGroup(event, userNpub);
        }
        if (!allowed && viewerCallsign != null) {
          final cs = viewerCallsign.toUpperCase();
          allowed = event.accessCallsigns
              .map((c) => c.toUpperCase())
              .contains(cs);
        }
        if (allowed) visible.add(event);
        continue;
      }
      // Unknown visibility → treat as public
      visible.add(event);
    }

    // 4. Build data payload
    final data = <String, dynamic>{
      'events': visible
          .map((e) => e.toApiJson(summary: true))
          .toList(),
      'years': years,
      'total': visible.length,
      'authenticated': userNpub != null,
    };

    // 5. Render
    final menuItems =
        await AppService().generateDeviceMenu(activeApp: 'events');
    final assets = await EventWebPageService().buildListingPage(
      data: data,
      logoText: 'Events',
      menuItems: menuItems,
    );
    final htmlHeaders = Map<String, String>.from(headers);
    htmlHeaders['Content-Type'] = 'text/html; charset=utf-8';
    return shelf.Response.ok(assets.html, headers: htmlHeaders);
  }

  /// True when the request originated from the same machine. Used by the
  /// listing endpoints to skip the visibility filter for the local Flutter
  /// app — the user always sees their own events regardless of the
  /// visibility they chose.
  bool _isLocalRequest(shelf.Request request) {
    final remote = request.context['shelf.io.connection_info'];
    try {
      final addr = (remote as dynamic)?.remoteAddress?.address as String?;
      if (addr == null) return false;
      return addr == '127.0.0.1' || addr == '::1' || addr == 'localhost';
    } catch (_) {
      return false;
    }
  }

  /// Map a NOSTR npub back to a callsign by checking the local profile and
  /// any known contacts. Returns null when no match is found — callsign
  /// grants then simply don't apply for that viewer.
  ///
  /// ContactService is a singleton and may not have been initialized in
  /// this isolate by the time the HTTP API needs it (the contacts page is
  /// usually what initializes it). Resolve through the AppService so the
  /// lookup works whether the contacts page has been opened or not.
  Future<String?> _resolveViewerCallsign(String? npub) async {
    if (npub == null || npub.isEmpty) return null;
    try {
      final ownProfile = ProfileService().getProfile();
      if (ownProfile.npub == npub) return ownProfile.callsign;
    } catch (_) {}
    try {
      final svc = await _ensureContactServiceReady();
      if (svc == null) return null;
      final contacts = await svc.loadContacts();
      for (final c in contacts) {
        if (c.npub == npub) return c.callsign;
      }
    } catch (_) {}
    return null;
  }

  /// Initialize the contact service singleton against the user's contacts
  /// app, returning null when there's no contacts app installed yet.
  Future<ContactService?> _ensureContactServiceReady() async {
    final contactsApp = AppService().getAppByType('contacts');
    final storagePath = contactsApp?.storagePath;
    if (storagePath == null || storagePath.isEmpty) return null;
    final svc = ContactService();
    svc.setStorage(FilesystemProfileStorage(storagePath));
    await svc.initializeApp(storagePath);
    return svc;
  }

  /// Upserts a contact for an access requester. If a contact with this
  /// callsign or npub already exists, leaves it alone; otherwise creates
  /// one under the contacts app so the picker shows
  /// "displayName (callsign)" instead of an opaque "X1HFG3" later.
  ///
  /// Best-effort: any failure (no contacts app, ContactService not
  /// initialised in this isolate, duplicate detection, ...) is logged
  /// and ignored — the caller's main job is recording the request.
  Future<void> _upsertRequesterContact({
    required String callsign,
    required String npub,
    required String nickname,
  }) async {
    try {
      final svc = await _ensureContactServiceReady();
      if (svc == null) return;

      // Skip if anything already represents this person.
      final existing = await svc.loadContacts();
      for (final c in existing) {
        if (c.callsign.toUpperCase() == callsign.toUpperCase()) return;
        if (c.npub != null && c.npub == npub) return;
      }

      final now = DateTime.now().toUtc();
      final ts =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';
      final displayName = nickname.isNotEmpty ? nickname : callsign;
      final contact = Contact(
        callsign: callsign,
        displayName: displayName,
        npub: npub,
        created: ts,
        firstSeen: ts,
        tags: const ['from-event-access-request'],
      );
      final err = await svc.saveContact(contact);
      if (err != null) {
        LogService().log('access-request: contact upsert skipped: $err');
      } else {
        LogService().log(
          'access-request: contact upserted $callsign'
          '${nickname.isNotEmpty ? " ($nickname)" : ""}',
        );
      }
    } catch (e) {
      LogService().log('access-request: contact upsert failed: $e');
    }
  }

  /// True when the event's per-event access_requests.json carries an
  /// 'approved' entry for this npub. The visibility filter consults
  /// this so a past approval grants the viewer access even when no
  /// Contact links the npub to a callsign locally — the access_requests
  /// file is the authoritative record of decided requests.
  Future<bool> _hasApprovedAccessRequest(Event event, String npub) async {
    try {
      final dataDir = StorageConfig().baseDir;
      final eventPath = await EventService().getEventPath(event.id, dataDir);
      if (eventPath == null) return false;
      final file = io.File('$eventPath/feedback/access_requests.json');
      if (!await file.exists()) return false;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return false;
      final list = jsonDecode(content) as List<dynamic>;
      for (final raw in list.whereType<Map<String, dynamic>>()) {
        if (raw['npub'] == npub &&
            ((raw['status'] as String?) ?? 'pending') == 'approved') {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// True when the viewer (npub) is a member of any group listed on the
  /// event's groupAccess list.
  Future<bool> _eventViewerInGroup(Event event, String npub) async {
    if (event.groupAccess.isEmpty) return false;
    for (final groupName in event.groupAccess) {
      try {
        final members = await GroupsService().loadMembers(groupName);
        if (members.any((m) => m.npub == npub)) return true;
      } catch (_) {
        // Missing / unreadable group → treat as no-grant.
      }
    }
    return false;
  }

  Future<shelf.Response> _handleEventDetailPage(
    shelf.Request request,
    String eventId,
    Map<String, String> headers,
  ) async {
    // 1. Identify viewer
    String? userNpub;
    final hexPubkey = _extractNostrPubkeyFromCookie(request);
    if (hexPubkey != null) {
      try {
        userNpub = NostrCrypto.encodeNpub(hexPubkey);
      } catch (_) {}
    }
    userNpub ??= _verifyNostrAuth(request);

    // 2. Load event — resolve ID/slug, then do a full load (with links, etc.)
    String? dataDir;
    try {
      dataDir = StorageConfig().baseDir;
    } catch (_) {
      return shelf.Response.internalServerError(
        body: 'Storage not initialized',
        headers: headers,
      );
    }
    // Try full load by ID first (searches collections + devices)
    var event = await EventService().findEventByIdGlobal(eventId, dataDir);
    // Fall back to slug lookup
    if (event == null) {
      final allEvents = await EventService().getAllEventsGlobal(dataDir);
      final bySlug = allEvents.cast<Event?>().firstWhere(
        (e) => e?.slug == eventId,
        orElse: () => null,
      );
      if (bySlug != null) {
        // Full load via findEventByIdGlobal with the real ID
        event = await EventService().findEventByIdGlobal(bySlug.id, dataDir);
        event ??= bySlug;
      }
    }
    if (event == null) {
      final htmlHeaders = Map<String, String>.from(headers);
      htmlHeaders['Content-Type'] = 'text/html; charset=utf-8';
      return shelf.Response.notFound(
        await _eventNotFoundHtml(eventId),
        headers: htmlHeaders,
      );
    }

    // 3. Visibility check
    //
    // Five states (see Event model):
    //   public          → always allowed
    //   unlisted        → allowed when ?key=<unlistedKey> matches; the URL
    //                     itself is the secret. Owner/admin always allowed
    //                     (so they can preview without the key).
    //   group           → allowed when viewer is in groupAccess OR listed
    //                     in accessCallsigns OR is admin/author.
    //   request_access  → same allow-list as group/private; non-allowed
    //                     viewers still get the page (so the "Request
    //                     access" UI can show) but the page payload is
    //                     stripped to a minimal teaser. The web template
    //                     renders the request UI when content is empty.
    //   private         → like group + accessCallsigns + author/admin only.
    final vis = event.visibility;
    final isOwnerOrAdmin = userNpub != null &&
        (event.npub == userNpub || event.isAdmin(userNpub));
    final viewerCallsign = await _resolveViewerCallsign(userNpub);
    final hasGroupGrant = userNpub == null
        ? false
        : await _eventViewerInGroup(event, userNpub);
    final hasCallsignGrant = viewerCallsign != null &&
        event.accessCallsigns
            .map((c) => c.toUpperCase())
            .contains(viewerCallsign.toUpperCase());
    // Final fallback: an approved entry in the event's own
    // access_requests.json. Catches viewers whose request was approved
    // before the contact-upsert flow existed, or anyone whose npub
    // doesn't have a local Contact mapping yet.
    final hasApprovedRequest = userNpub == null
        ? false
        : await _hasApprovedAccessRequest(event, userNpub);
    final allowed = isOwnerOrAdmin ||
        hasGroupGrant ||
        hasCallsignGrant ||
        hasApprovedRequest;

    if (vis == 'unlisted') {
      final providedKey =
          request.url.queryParameters['key']?.trim() ?? '';
      final keyMatches = providedKey.isNotEmpty &&
          providedKey == (event.unlistedKey ?? '');
      if (!keyMatches && !isOwnerOrAdmin) {
        // Treat as not-found so the URL itself doesn't reveal the event
        // exists when the key is missing or wrong.
        final htmlHeaders = Map<String, String>.from(headers);
        htmlHeaders['Content-Type'] = 'text/html; charset=utf-8';
        return shelf.Response.notFound(
          await _eventNotFoundHtml(eventId),
          headers: htmlHeaders,
        );
      }
    } else if (vis == 'private' || vis == 'group') {
      if (!allowed) {
        final htmlHeaders = Map<String, String>.from(headers);
        htmlHeaders['Content-Type'] = 'text/html; charset=utf-8';
        return shelf.Response.notFound(
          await _eventNotFoundHtml(eventId),
          headers: htmlHeaders,
        );
      }
    }
    // request_access falls through with allowed=false; the template uses
    // the data['access_request_required'] flag below to decide what to
    // render. Public, unlisted-with-key, group/private+grant land here too.

    // 4. Build full JSON with feedback data
    final data = event.toApiJson(summary: false);

    // Strip private content when the viewer hasn't been granted access on
    // a request_access event. Only metadata + the request prompt go out.
    if (vis == 'request_access' && !allowed) {
      data['content'] = '';
      data['agenda'] = null;
      data['photos'] = const [];
      data.remove('flyer');
      data['trailer'] = null;
      data['updates'] = const [];
      data['links'] = const [];
      data['contacts'] = const [];
      data['access_request_required'] = true;
    } else {
      data['access_request_required'] = false;
    }

    // Surface the unlisted key only to the owner / admin so they can copy
    // the share URL — never to anyone else, even if they had the key in
    // the URL (they already have it; no need to echo).
    if (isOwnerOrAdmin && event.unlistedKey != null) {
      data['unlisted_key'] = event.unlistedKey;
    } else {
      data.remove('unlisted_key');
    }

    // Resolve place coordinates for map display
    if (event.hasPlaceReference && !event.hasCoordinates) {
      try {
        final placePath = event.placePath!;
        String? resolvedPath;
        if (path.isAbsolute(placePath)) {
          resolvedPath = placePath;
        } else {
          final callsign = event.author.isNotEmpty
              ? event.author
              : ProfileService().getProfile().callsign;
          if (callsign.isNotEmpty) {
            final basePath = StorageConfig().getCallsignDir(callsign);
            resolvedPath = path.normalize(path.join(basePath, placePath));
          }
        }
        if (resolvedPath != null) {
          final placeFile = io.File(path.join(resolvedPath, 'place.txt'));
          if (await placeFile.exists()) {
            final content = await placeFile.readAsString();
            final place = PlaceService().parsePlaceContent(
              content: content,
              filePath: placeFile.path,
              folderPath: resolvedPath,
            );
            if (place != null) {
              data['place_latitude'] = place.latitude;
              data['place_longitude'] = place.longitude;
            }
          }
        }
      } catch (e) {
        LogService().log('EventDetail: Error resolving place coordinates: $e');
      }
    }

    // Load feedback likes for the like button. Reads the canonical
    // FeedbackFolderUtils path ("feedback/likes.txt") so the count and
    // liked-by list stay in sync with the Flutter EventLikeButton, which
    // writes through that same helper. Falls back to the legacy
    // ".feedback/likes.txt" so existing likes from before the convergence
    // still show up until the next write moves them across.
    final eventPath = await EventService().getEventPath(event.id, dataDir);
    if (eventPath != null) {
      var likesFile = io.File('$eventPath/feedback/likes.txt');
      if (!await likesFile.exists()) {
        final legacy = io.File('$eventPath/.feedback/likes.txt');
        if (await legacy.exists()) likesFile = legacy;
      }
      if (await likesFile.exists()) {
        final content = await likesFile.readAsString();
        final feedbackLikes = content
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        data['feedback_likes'] = feedbackLikes;
        data['feedback_like_count'] = feedbackLikes.length;
      }
    }
    // Include hex pubkeys for the JS like check
    if (data['feedback_likes'] != null) {
      final npubLikes = data['feedback_likes'] as List<String>;
      final hexPubkeys = <String>[];
      for (final npub in npubLikes) {
        try {
          hexPubkeys.add(NostrCrypto.decodeNpub(npub));
        } catch (_) {}
      }
      data['feedback_liked_hex_pubkeys'] = hexPubkeys;
    }
    // Surface signed-view stats so the page can render the count and the
    // browser-side JS can compare its post-record response.
    try {
      final ownerCallsign = event.author.isNotEmpty
          ? event.author
          : ProfileService().getProfile().callsign;
      if (ownerCallsign.isNotEmpty && event.id.length >= 4) {
        // Event ids start with the year (YYYY-MM-DD_…); _resolveEventPath in
        // feedback_handler relies on the same convention.
        final year = event.id.substring(0, 4);
        if (int.tryParse(year) != null) {
          final storage = FilesystemProfileStorage(
            '$dataDir/devices/$ownerCallsign',
          );
          final stats = await FeedbackFolderUtils.getViewStats(
            'events/$year/${event.id}',
            storage: storage,
          );
          data['view_count'] = stats['total_views'] ?? 0;
          data['unique_viewers'] = stats['unique_viewers'] ?? 0;
        }
      }
    } catch (e) {
      LogService().log('EventDetail: getViewStats failed: $e');
      data['view_count'] = 0;
      data['unique_viewers'] = 0;
    }

    // Load NOSTR-signed comments from feedback/comments/ so the web template
    // can render them. The Event model's `comments` field is a legacy
    // in-memory bucket; the canonical store is the feedback folder, same
    // place feedback_handler writes through.
    try {
      final ownerCs = event.author.isNotEmpty
          ? event.author
          : ProfileService().getProfile().callsign;
      if (ownerCs.isNotEmpty && event.id.length >= 4) {
        final year = event.id.substring(0, 4);
        if (int.tryParse(year) != null) {
          final cstorage = FilesystemProfileStorage(
            '$dataDir/devices/$ownerCs',
          );
          final fbComments = await FeedbackCommentUtils.loadComments(
            'events/$year/${event.id}',
            storage: cstorage,
          );
          data['comments'] = fbComments
              .map((c) => {
                    'id': c.id,
                    'author': c.author,
                    'timestamp': c.created,
                    'content': c.content,
                    if (c.npub != null && c.npub!.isNotEmpty) 'npub': c.npub,
                  })
              .toList();
        }
      }
    } catch (e) {
      LogService().log('EventDetail: loadComments failed: $e');
    }

    // Expose the event author's pubkey in hex too so the page JS can
    // compare it against window.GeogramNostr.pubkey (also hex) and show
    // the comment-delete chip on every card when the visitor is the
    // author. The bech32 npub is already in `data['npub']`.
    if (event.npub != null && event.npub!.isNotEmpty) {
      try {
        data['author_pubkey_hex'] = NostrCrypto.decodeNpub(event.npub!);
      } catch (_) {}
    }
    data['authenticated'] = userNpub != null;

    // 5. Render
    final menuItems =
        await AppService().generateDeviceMenu(activeApp: 'events');
    final assets = await EventWebPageService().buildEventPage(
      data: data,
      logoText: 'Events',
      menuItems: menuItems,
    );
    final htmlHeaders = Map<String, String>.from(headers);
    htmlHeaders['Content-Type'] = 'text/html; charset=utf-8';
    return shelf.Response.ok(assets.html, headers: htmlHeaders);
  }

  /// Themed "Event not found" page. Re-uses the same global stylesheet
  /// the events listing/detail pages render with, so the 404 sits inside
  /// the same look-and-feel instead of dropping the visitor into an
  /// orphaned dark-blue card. CSS variables (--accent, --background,
  /// --color, --border-color) come from WebThemeService.getGlobalStyles().
  Future<String> _eventNotFoundHtml(String eventId) async {
    String globalStyles = '';
    try {
      final theme = WebThemeService();
      await theme.init();
      globalStyles = await theme.getGlobalStyles() ?? '';
    } catch (_) {
      // Fall through with empty styles — the page still renders, just
      // without theme variables.
    }
    return '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Event Not Found</title>
  <style>$globalStyles</style>
  <style>
    body {
      display: flex; justify-content: center; align-items: center;
      min-height: 100vh; margin: 0;
    }
    .card {
      background: var(--background);
      color: var(--color);
      border: 1px solid var(--border-color);
      border-radius: 6px;
      padding: 32px 40px;
      max-width: 480px;
      text-align: center;
      box-shadow: var(--shadow);
    }
    .card h1 {
      color: var(--accent);
      margin: 0 0 12px;
      font-size: 1.4rem;
    }
    .card p { opacity: 0.85; margin: 0 0 18px; }
    .card a {
      color: var(--accent);
      text-decoration: none;
      border-bottom: 1px dashed var(--accent-alpha-70);
    }
    .card a:hover { border-bottom-style: solid; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Event not found</h1>
    <p>The event could not be found, or you don't have access.</p>
    <a href="/events/">Browse events</a>
  </div>
</body>
</html>''';
  }

  /// Handle POST /api/debug {"action": "meet_set_cover", "code": "old", "path": "/tmp/cover.jpg"}
  Future<shelf.Response> _handleMeetAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    if (action == 'meet_set_cover') {
      final code = params['code'] as String?;
      final imagePath = params['path'] as String?;
      if (code == null || imagePath == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing code or path'}),
          headers: headers,
        );
      }
      final archive = await ConferenceArchiveService().findArchiveByRoomId(
        _meetRoomId(code),
      );
      if (archive == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Archive not found'}),
          headers: headers,
        );
      }
      final updated =
          await ConferenceArchiveService().setCoverImage(archive, imagePath);
      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'cover_image_path': updated.coverImagePath,
        }),
        headers: headers,
      );
    }
    if (action == 'meet_generate_cover') {
      final code = params['code'] as String?;
      if (code == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing code'}),
          headers: headers,
        );
      }
      final archive = await ConferenceArchiveService().findArchiveByRoomId(
        _meetRoomId(code),
      );
      if (archive == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Archive not found'}),
          headers: headers,
        );
      }
      final coverBytes = ConferenceArchiveService.generateCoverImage(
        roomName: archive.roomName,
        startedAt: archive.startedAt,
        hostCallsign: archive.hostCallsign,
      );
      final tempDir = await io.Directory.systemTemp.createTemp('cover_');
      final tempFile = io.File('${tempDir.path}/cover.jpg');
      await tempFile.writeAsBytes(coverBytes);
      final updated =
          await ConferenceArchiveService().setCoverImage(archive, tempFile.path);
      await tempDir.delete(recursive: true);
      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'cover_image_path': updated.coverImagePath,
        }),
        headers: headers,
      );
    }
    return shelf.Response.notFound(
      jsonEncode({'error': 'Unknown meet action: $action'}),
      headers: headers,
    );
  }

  /// Handle GET /api/meet/active — returns active meeting info or 404.
  shelf.Response _handleMeetActiveRequest(Map<String, String> headers) {
    final conf = ConferenceService();
    if (!conf.isActive || conf.room == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'No active meeting'}),
        headers: headers,
      );
    }

    final room = conf.room!;
    final response = {
      'room_id': room.roomId,
      'room_name': room.roomName,
      'host_callsign': room.hostCallsign,
      'signaling_mode': room.signalingMode.name,
      'signaling_port': conf.signalingPort,
      'participant_count': room.participants.length,
      'max_participants': room.maxSpeakers,
      'station_meet_url': conf.shareableStationMeetUrl,
    };

    return shelf.Response.ok(
      jsonEncode(response),
      headers: headers,
    );
  }

  Future<shelf.Response> _handleThemeStylesRequest(
    Map<String, String> headers, {
    String? appType,
  }) async {
    try {
      final themeService = WebThemeService();
      await themeService.init();
      final content = appType == null
          ? (await themeService.getGlobalStyles() ?? '')
          : (await themeService.getAppStyles(appType) ?? '');
      return shelf.Response.ok(
        content,
        headers: {
          ...headers,
          'Content-Type': 'text/css; charset=utf-8',
        },
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: '/* Failed to load theme styles: $e */',
        headers: {
          ...headers,
          'Content-Type': 'text/css; charset=utf-8',
        },
      );
    }
  }

  shelf.Response _handleNostrBundleRequest(Map<String, String> headers) {
    return shelf.Response.ok(
      getNostrBundleJs(),
      headers: {
        ...headers,
        'Content-Type': 'application/javascript; charset=utf-8',
        'Cache-Control': 'public, max-age=86400',
      },
    );
  }

  String? _lanSignalingWsUrl(shelf.Request request, ConferenceService conf) {
    final signalingPort = conf.signalingPort;
    if (signalingPort == null) {
      return null;
    }
    final requestedUri = request.requestedUri;
    final scheme = requestedUri.scheme == 'https' ? 'wss' : 'ws';
    final authority = requestedUri.host.isNotEmpty ? requestedUri.host : 'localhost';
    return '$scheme://$authority:$signalingPort/meet/ws';
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
      final appsBase = path.join(homeDir, 'Documents', 'geogram', 'collections');

      // Resolve the requested path
      final requestedPath = relativePath.isEmpty
          ? appsBase
          : path.join(appsBase, relativePath);

      // Security: ensure path is within collections directory
      final normalizedBase = path.normalize(appsBase);
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
          final appPath = _getAppPath(relativePath, appsBase);
          if (appPath != null && !await _isAppPublic(appPath)) {
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
        final appPath = _getAppPath(relativePath, appsBase);
        if (appPath != null && !await _isAppPublic(appPath)) {
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
          if (isDirectory && !await _isAppPublic(entity.path)) {
            continue;
          }

          // For collections, try to get size from tree.json
          int? size;
          if (isDirectory) {
            size = await _getAppSize(entity.path);
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
        entries = await _getEntriesFromTreeJson(relativePath, appsBase);
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
          'base': appsBase,
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
  String? _getAppPath(String relativePath, String appsBase) {
    if (relativePath.isEmpty) return null;
    final parts = relativePath.split('/');
    if (parts.isEmpty) return null;
    return path.join(appsBase, parts.first);
  }

  /// Check if a collection is public by reading its security.json
  Future<bool> _isAppPublic(String appPath) async {
    try {
      final securityFile = io.File(path.join(appPath, 'extra', 'security.json'));
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
  Future<int> _getAppSize(String appPath) async {
    try {
      final treeJsonFile = io.File(path.join(appPath, 'extra', 'tree.json'));
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
    String appsBase,
  ) async {
    final entries = <Map<String, dynamic>>[];

    try {
      // Parse the path: first part is collection name, rest is subpath
      final parts = relativePath.split('/');
      if (parts.isEmpty) return entries;

      final appFolderName = parts.first;
      final appPath = path.join(appsBase, appFolderName);
      final subPath = parts.length > 1 ? parts.sublist(1).join('/') : '';

      // Read tree.json
      final treeJsonFile = io.File(path.join(appPath, 'extra', 'tree.json'));
      if (!await treeJsonFile.exists()) {
        // Fall back to filesystem if tree.json doesn't exist
        return await _listDirectoryFallback(path.join(appsBase, relativePath));
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
            return await _listDirectoryFallback(path.join(appsBase, relativePath));
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
      return await _listDirectoryFallback(path.join(appsBase, relativePath));
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
      final appsBase = path.join(homeDir, 'Documents', 'geogram', 'collections');

      // Resolve the requested path
      final requestedPath = path.join(appsBase, relativePath);

      // Security: ensure path is within collections directory
      final normalizedBase = path.normalize(appsBase);
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
      final appPath = _getAppPath(relativePath, appsBase);
      if (appPath != null && !await _isAppPublic(appPath)) {
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

      // Handle contributor actions before the generic event_ prefix
      // (so contributor_* actions don't get routed to _handleEventAction).
      if (action.toLowerCase().startsWith('contributor_') ||
          action.toLowerCase() == 'remote_contribution_submit') {
        return await _handleContributorAction(
            action.toLowerCase(), params, headers);
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

      if (action.toLowerCase() == 'chat_post_local') {
        return await _handleStationAction(action.toLowerCase(), params, headers);
      }

      // Handle bot actions separately (they are async)
      if (action.toLowerCase().startsWith('bot_')) {
        return await _handleBotAction(action.toLowerCase(), params, headers);
      }

      // Handle meet actions separately (they are async)
      if (action.toLowerCase().startsWith('meet_')) {
        return await _handleMeetAction(action.toLowerCase(), params, headers);
      }

      // Handle power mode simulation (for testing battery saving on desktop)
      if (action.toLowerCase() == 'power_mode') {
        return _handlePowerModeAction(params, headers);
      }

      // Handle device actions separately (they are async). `remote_`
      // actions share the same handler — they simulate what a remote-
      // device panel does from the UI (sign locally, POST remotely).
      if (action.toLowerCase().startsWith('device_') ||
          action.toLowerCase().startsWith('remote_')) {
        return await _handleDeviceAction(action.toLowerCase(), params, headers);
      }

      // Handle transfer debug actions separately (they are async)
      if (action.toLowerCase().startsWith('transfer_')) {
        return await _handleTransferAction(action.toLowerCase(), params, headers);
      }

      // Handle contact debug actions
      if (action.toLowerCase().startsWith('contact_')) {
        return await _handleContactDebugAction(action.toLowerCase(), params, headers);
      }

      // Handle email debug actions
      if (action.toLowerCase().startsWith('email_')) {
        return await _handleEmailAction(action.toLowerCase(), params, headers);
      }

      // Handle profile debug actions
      if (action.toLowerCase().startsWith('profile_')) {
        return await _handleProfileAction(action.toLowerCase(), params, headers);
      }

      // Handle mirror sync debug actions
      if (action.toLowerCase().startsWith('mirror_')) {
        return await _handleMirrorAction(action.toLowerCase(), params, headers);
      }

      // Handle DHT/P2P discovery debug actions
      if (action.toLowerCase().startsWith('dht_')) {
        return await _handleDhtAction(action.toLowerCase(), params, headers);
      }

      // Handle P2P transfer debug actions
      if (action.toLowerCase().startsWith('p2p_')) {
        return await _handleP2PAction(action.toLowerCase(), params, headers);
      }

      // Handle encrypted storage debug actions
      if (action.toLowerCase().startsWith('encrypt_storage_')) {
        return await _handleEncryptStorageAction(action.toLowerCase(), params, headers);
      }

      // Handle shared folder debug actions
      if (action.toLowerCase().startsWith('shared_')) {
        return await _handleSharedAction(action.toLowerCase(), params, headers);
      }

      // Handle local backup debug actions
      if (action.toLowerCase().startsWith('local_backup_')) {
        return await _handleLocalBackupAction(action.toLowerCase(), params, headers);
      }

      // Handle Telegram cache debug actions
      if (action.toLowerCase().startsWith('telegram_')) {
        return await _handleTelegramAction(action.toLowerCase(), params, headers);
      }

      // Handle Signal bridge debug actions
      if (action.toLowerCase().startsWith('signal_')) {
        return await _handleSignalAction(action.toLowerCase(), params, headers);
      }

      // Handle APRS debug actions
      if (action.toLowerCase().startsWith('aprs_')) {
        return await _handleAprsAction(action.toLowerCase(), params, headers);
      }

      // Handle BlueAPRS debug actions
      if (action.toLowerCase().startsWith('blue_aprs_')) {
        return _handleBlueAprsAction(action.toLowerCase(), params, headers);
      }

      // Handle IRC debug actions
      if (action.toLowerCase().startsWith('irc_')) {
        return await _handleIrcAction(action.toLowerCase(), params, headers);
      }

      // Handle XMPP server debug actions (must be before xmpp_ client actions)
      if (action.toLowerCase().startsWith('xmpp_server_')) {
        return await _handleXmppServerAction(action.toLowerCase(), params, headers);
      }

      // Handle XMPP debug actions
      if (action.toLowerCase().startsWith('xmpp_')) {
        return await _handleXmppAction(action.toLowerCase(), params, headers);
      }

      // Handle NOSTR client debug actions
      if (action.toLowerCase().startsWith('nostr_')) {
        return _handleNostrAction(action.toLowerCase(), params, headers);
      }

      // Handle AT Proto / Bluesky debug actions
      if (action.toLowerCase().startsWith('atproto_')) {
        return await _handleAtprotoAction(action.toLowerCase(), params, headers);
      }

      // Handle task monitor debug actions
      if (action.toLowerCase().startsWith('task_')) {
        return _handleTaskAction(action.toLowerCase(), params, headers);
      }

      // Handle hotspot portal debug actions
      if (action.toLowerCase().startsWith('hotspot_portal_')) {
        return await _handleHotspotPortalAction(action.toLowerCase(), params, headers);
      }

      // Handle karma debug actions
      if (action.toLowerCase().startsWith('karma_')) {
        return await _handleKarmaAction(action.toLowerCase(), params, headers);
      }

      final debugController = DebugController();
      final result = await debugController.executeAction(action, params);

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
  // Debug API - Power Mode Actions
  // ============================================================

  /// Handle power mode simulation for testing battery saving on desktop.
  ///
  /// POST /api/debug {"action": "power_mode", "mode": "background|doze|foreground"}
  /// GET  /api/debug {"action": "power_mode"} — returns current state
  shelf.Response _handlePowerModeAction(
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) {
    final modeStr = params['mode'] as String?;
    if (modeStr == null) {
      // Return current status
      return shelf.Response.ok(
        jsonEncode(PowerAwareService().toJson()),
        headers: headers,
      );
    }

    final mode = PowerMode.values.where((m) => m.name == modeStr).firstOrNull;
    if (mode == null) {
      return shelf.Response.badRequest(
        body: jsonEncode({
          'error': 'Invalid mode: $modeStr',
          'valid_modes': PowerMode.values.map((m) => m.name).toList(),
        }),
        headers: headers,
      );
    }

    PowerAwareService().forceMode(mode);
    return shelf.Response.ok(
      jsonEncode({
        'success': true,
        'mode': mode.name,
        ...PowerAwareService().toJson(),
      }),
      headers: headers,
    );
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

    final callsign = ProfileService().getProfile().callsign;
    final testDir = io.Directory(path.join(storageConfig.getCallsignDir(callsign), 'test-backup-data'));
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

  NostrEvent? _verifyNostrAuthEvent(shelf.Request request) {
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Nostr ')) {
      return null;
    }

    try {
      final base64Event = authHeader.substring(6);
      final eventJson = utf8.decode(base64Decode(base64Event));
      final eventData = jsonDecode(eventJson) as Map<String, dynamic>;
      final event = NostrEvent.fromJson(eventData);

      if (!event.verify()) {
        LogService().log('LogApiService: NOSTR auth failed - invalid signature');
        return null;
      }

      if (!_isFreshNostrEvent(event)) {
        LogService().log('LogApiService: NOSTR auth failed - event too old');
        return null;
      }

      return event;
    } catch (e) {
      LogService().log('LogApiService: NOSTR auth failed - parse error: $e');
      return null;
    }
  }

  bool _isFreshNostrEvent(NostrEvent event) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return (now - event.createdAt).abs() <= 300;
  }

  NostrEvent? _verifyBackupAuthEvent(
    shelf.Request request, {
    String? expectedCallsign,
    List<String>? allowedActions,
  }) {
    final event = _verifyNostrAuthEvent(request);
    if (event == null) return null;

    final backupTag = event.getTagValue('t');
    if (backupTag != 'backup') {
      LogService().log('LogApiService: Backup auth failed - missing backup tag');
      return null;
    }

    if (expectedCallsign != null) {
      final tagCallsign = event.getTagValue('callsign');
      if (tagCallsign == null || tagCallsign.toUpperCase() != expectedCallsign.toUpperCase()) {
        LogService().log('LogApiService: Backup auth failed - callsign mismatch');
        return null;
      }
    }

    if (allowedActions != null && allowedActions.isNotEmpty) {
      final action = event.getTagValue('action');
      if (action == null || !allowedActions.contains(action)) {
        LogService().log('LogApiService: Backup auth failed - action mismatch: $action');
        return null;
      }
    }

    return event;
  }

  NostrEvent? _verifyBackupOwnerAuth(
    shelf.Request request, {
    List<String>? allowedActions,
  }) {
    final event = _verifyBackupAuthEvent(request, allowedActions: allowedActions);
    if (event == null) return null;

    final profile = ProfileService().getProfile();
    if (event.npub != profile.npub) {
      LogService().log('LogApiService: Backup auth failed - npub mismatch');
      return null;
    }

    final callsignTag = event.getTagValue('callsign');
    if (callsignTag == null || callsignTag.toUpperCase() != profile.callsign.toUpperCase()) {
      LogService().log('LogApiService: Backup auth failed - callsign mismatch');
      return null;
    }

    return event;
  }

  BackupClientRelationship? _verifyBackupClientAuth(
    shelf.Request request,
    String callsign, {
    bool requireActive = true,
  }) {
    final event = _verifyBackupAuthEvent(request, expectedCallsign: callsign);
    if (event == null) return null;

    final backupService = BackupService();
    final client = backupService.getClient(callsign);
    if (client == null) {
      LogService().log('LogApiService: Backup auth failed - client not found: $callsign');
      return null;
    }
    if (client.clientNpub != event.npub) {
      LogService().log('LogApiService: Backup auth failed - client npub mismatch');
      return null;
    }
    if (requireActive && client.status != BackupRelationshipStatus.active) {
      LogService().log('LogApiService: Backup auth failed - client not active');
      return null;
    }

    return client;
  }

  shelf.Response _backupAuthDenied(Map<String, String> headers, {String? error}) {
    return shelf.Response.forbidden(
      jsonEncode({'error': error ?? 'Unauthorized backup request'}),
      headers: headers,
    );
  }

  /// Load room config from disk (config.json in room folder)
  Future<ChatChannelConfig?> _loadRoomConfig(String appPath, String roomId) async {
    try {
      final configPath = '$appPath/$roomId/config.json';
      final configFile = io.File(configPath);
      if (await configFile.exists()) {
        final content = await configFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        // Add id and name if missing (required by ChatChannelConfig)
        json['id'] ??= roomId;
        json['name'] ??= json['name'] ?? roomId;
        return ChatChannelConfig.fromJson(json);
      }
    } catch (e) {
      LogService().log('LogApiService: Error loading room config for $roomId: $e');
    }
    return null;
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

    // Get visibility from config
    // If config not loaded in channel, try to load from disk
    var config = channel.config;
    if (config == null && chatService.appPath != null) {
      config = await _loadRoomConfig(chatService.appPath!, roomId);
    }

    // Security: Default to RESTRICTED if config is missing (fail closed)
    final visibility = config?.visibility ?? 'RESTRICTED';

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
      if (!initialized || chatService.appPath == null) {
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

      await _initializeChatServiceIfNeeded(createIfMissing: true);

      final chatService = ChatService();
      final channel = chatService.getChannel(roomId);
      // Geogram callsigns start with 'X' followed by alphanumerics (e.g., X1ABC)
      // This prevents words like 'GENERAL' from being misinterpreted as callsigns
      final isCallsignLike = RegExp(r'^X[A-Z0-9]{2,}$').hasMatch(roomId.toUpperCase());

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
      if (chatService.appPath == null) {
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
        // Geogram timestamps use underscore before seconds: YYYY-MM-DD HH:MM_SS
        final normalized = afterParam.replaceAll('_', ':');
        startDate = DateTime.tryParse(normalized);
      }
      if (beforeParam != null) {
        final normalized = beforeParam.replaceAll('_', ':');
        endDate = DateTime.tryParse(normalized);
      }

      // Load messages (file-level filtering is day-granularity)
      var messages = await chatService.loadMessages(
        roomId,
        startDate: startDate,
        endDate: endDate,
        limit: 10000, // Load generously, filter by time below
      );

      // Apply time-level filtering for after/before parameters
      if (startDate != null) {
        messages = messages.where((m) => m.dateTime.isAfter(startDate!)).toList();
      }
      if (endDate != null) {
        messages = messages.where((m) => m.dateTime.isBefore(endDate!)).toList();
      }

      // Apply limit after time filtering
      if (messages.length > limit + 1) {
        messages = messages.sublist(messages.length - (limit + 1));
      }

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
      await _initializeChatServiceIfNeeded(createIfMissing: true);

      final chatService = ChatService();
      final channel = chatService.getChannel(roomId);
      // Geogram callsigns start with 'X' followed by alphanumerics (e.g., X1ABC)
      // This prevents words like 'GENERAL' from being misinterpreted as callsigns
      final isCallsignLike = RegExp(r'^X[A-Z0-9]{2,}$').hasMatch(roomId.toUpperCase());

      if (channel == null && isCallsignLike) {
        return await _handleDMViaChatAPI(request, roomId.toUpperCase(), headers);
      }

      // Check if chat service is initialized
      if (chatService.appPath == null) {
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

      } else if (body.containsKey('content') &&
          body.containsKey('signature') &&
          body.containsKey('pubkey')) {
        // Flat NOSTR-signed message from remote user
        content = body['content'] as String;
        final senderCallsign = body['callsign'] as String?;
        final pubkey = body['pubkey'] as String;
        signature = body['signature'] as String?;
        eventId = body['event_id'] as String?;
        final rawCreatedAt = body['created_at'];

        if (senderCallsign == null || senderCallsign.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'error': 'Missing callsign for signed message',
              'code': 'MISSING_CALLSIGN',
            }),
            headers: headers,
          );
        }

        // Derive npub from pubkey
        npub = body['npub'] as String?;
        if (npub == null || npub.isEmpty) {
          try {
            npub = NostrCrypto.encodeNpub(pubkey);
          } catch (e) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'error': 'Invalid pubkey',
                'code': 'INVALID_PUBKEY',
              }),
              headers: headers,
            );
          }
        }

        // Parse created_at
        final ts = rawCreatedAt is int
            ? rawCreatedAt
            : int.tryParse(rawCreatedAt?.toString() ?? '');
        createdAt = ts ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);

        // Verify NOSTR signature
        if (signature == null ||
            signature!.isEmpty ||
            eventId == null ||
            eventId!.isEmpty) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Missing signature or event_id for signed message',
              'code': 'MISSING_SIGNATURE',
            }),
            headers: headers,
          );
        }

        try {
          final event = NostrEvent(
            id: eventId!,
            pubkey: pubkey,
            createdAt: createdAt!,
            kind: 1,
            tags: [
              ['t', 'chat'],
              ['room', roomId],
              ['callsign', senderCallsign],
            ],
            content: content,
            sig: signature!,
          );
          if (!event.verify()) {
            return shelf.Response.forbidden(
              jsonEncode({
                'error': 'Invalid signature',
                'code': 'INVALID_SIGNATURE',
              }),
              headers: headers,
            );
          }
        } catch (e) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Signature verification failed: $e',
              'code': 'SIGNATURE_ERROR',
            }),
            headers: headers,
          );
        }

        // Check room access for actual sender
        final canAccess =
            await _canAccessChatRoom(roomId, npub, callsign: senderCallsign);
        if (!canAccess) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Sender not authorized for this room',
              'code': 'AUTHOR_ACCESS_DENIED',
            }),
            headers: headers,
          );
        }

        author = senderCallsign;

      } else {
        return shelf.Response.forbidden(
          jsonEncode({
            'error': 'NOSTR signed event required',
            'code': 'SIGNATURE_REQUIRED',
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

        // Extract file metadata from event tags (for file messages)
        final fileTag = event.getTagValue('file');
        final fileSizeTag = event.getTagValue('file_size');
        final fileNameTag = event.getTagValue('file_name');
        final sha1Tag = event.getTagValue('sha1');

        // Store file metadata in a temporary map to merge later
        if (fileTag != null) {
          body['_file_from_event'] = fileTag;
        }
        if (fileSizeTag != null) {
          body['_file_size_from_event'] = fileSizeTag;
        }
        if (fileNameTag != null) {
          body['_file_name_from_event'] = fileNameTag;
        }
        if (sha1Tag != null) {
          body['_sha1_from_event'] = sha1Tag;
        }

      } else {
        return shelf.Response.forbidden(
          jsonEncode({
            'error': 'NOSTR signed event required',
            'code': 'SIGNATURE_REQUIRED',
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
          if (key is String && value != null) {
            metadata[key] = value.toString();
          }
        });
      }

      // Add file metadata from event tags (priority over body metadata)
      if (body['_file_from_event'] != null) {
        metadata['file'] = body['_file_from_event'].toString();
      }
      if (body['_file_size_from_event'] != null) {
        metadata['file_size'] = body['_file_size_from_event'].toString();
      }
      if (body['_file_name_from_event'] != null) {
        metadata['file_name'] = body['_file_name_from_event'].toString();
      }
      if (body['_sha1_from_event'] != null) {
        metadata['sha1'] = body['_sha1_from_event'].toString();
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

      ChatMessage message;
      if (createdAt != null) {
        final timestampStr = ChatFormat.epochToTimestamp(createdAt);
        message = ChatMessage(
          author: author,
          timestamp: timestampStr,
          content: content,
          metadata: metadata,
        );
      } else {
        message = ChatMessage.now(
          author: author,
          content: content,
          metadata: metadata,
        );
      }

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
      if (chatService.appPath == null) {
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

      final appPath = chatService.appPath!;
      final channelPath = path.join(appPath, channel.folder);
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

  /// Handle GET /api/chat/{roomId}/files/{filename} - Download file from chat room
  Future<shelf.Response> _handleChatFileDownloadRequest(
    shelf.Request request,
    String roomId,
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

      io.File? targetFile;

      // First try via ChatService if initialized
      await _initializeChatServiceIfNeeded();
      final chatService = ChatService();

      if (chatService.appPath != null) {
        final channel = chatService.getChannel(roomId);
        if (channel != null) {
          final appPath = chatService.appPath!;
          final channelPath = path.join(appPath, channel.folder);

          // For main channel, search in year/files/ subfolders
          if (channel.isMain) {
            final channelDir = io.Directory(channelPath);
            if (await channelDir.exists()) {
              await for (final yearEntity in channelDir.list()) {
                if (yearEntity is io.Directory) {
                  final yearName = path.basename(yearEntity.path);
                  if (RegExp(r'^\d{4}$').hasMatch(yearName)) {
                    final filePath = path.join(yearEntity.path, 'files', filename);
                    final file = io.File(filePath);
                    if (await file.exists()) {
                      targetFile = file;
                      break;
                    }
                  }
                }
              }
            }
          } else {
            // For other channels, files are in channel/files/
            final filePath = path.join(channelPath, 'files', filename);
            final file = io.File(filePath);
            if (await file.exists()) {
              targetFile = file;
            }
          }
        }
      }

      // Fallback: check devices/{myCallsign}/chat/{roomId}/files/ path
      // This handles cases where files are stored directly in the device's chat directory
      if (targetFile == null) {
        final myCallsign = ProfileService().getProfile().callsign;
        final devicesPath = StorageConfig().devicesDir;
        final fallbackPath = path.join(devicesPath, myCallsign, 'chat', roomId.toLowerCase(), 'files', filename);
        final fallbackFile = io.File(fallbackPath);
        if (await fallbackFile.exists()) {
          targetFile = fallbackFile;
        }
      }

      if (targetFile == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'File not found'}),
          headers: headers,
        );
      }

      // Determine MIME type using standard pattern
      final ext = path.extension(filename).toLowerCase();
      String contentType = 'application/octet-stream';
      final mimeTypes = {
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
        '.png': 'image/png',
        '.gif': 'image/gif',
        '.webp': 'image/webp',
        '.mp4': 'video/mp4',
        '.mov': 'video/quicktime',
        '.webm': 'video/webm',
        '.mp3': 'audio/mpeg',
        '.m4a': 'audio/mp4',
        '.wav': 'audio/wav',
        '.ogg': 'audio/ogg',
        '.pdf': 'application/pdf',
      };
      if (mimeTypes.containsKey(ext)) {
        contentType = mimeTypes[ext]!;
      }

      final fileBytes = await targetFile.readAsBytes();
      return shelf.Response.ok(
        fileBytes,
        headers: {
          ...headers,
          'Content-Type': contentType,
          'Content-Length': fileBytes.length.toString(),
          'Cache-Control': 'public, max-age=86400',
        },
      );
    } catch (e) {
      LogService().log('LogApiService: Error serving chat file: $e');
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
        // Delete message - accepts NIP-09 kind 5 or legacy kind 1
        final event = verifyModificationEvent(
          request.headers['authorization'],
          'delete',
          roomId,
        );
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

        // For kind 5 events, validate the ["e"] tag matches the stored event ID
        final storedEventId = message.metadata['event_id'];
        if (!validateDeletionTarget(event, storedEventId)) {
          return shelf.Response.forbidden(
            jsonEncode({
              'error': 'Event ID mismatch in deletion event',
              'code': 'EVENT_ID_MISMATCH',
            }),
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

        LogService().log('LogApiService: Message deleted from $roomId at $timestamp by ${event.npub} (kind ${event.kind})');

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
        final event = verifyModificationEvent(
          request.headers['authorization'],
          'edit',
          roomId,
        );
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

        // Verify callsign matches if provided (skip for moderator edits —
        // the mod's callsign won't match the original author's callsign;
        // authorization is handled by ChatService.editMessage)
        if (callsignTag != null && callsignTag != message.author) {
          final isMod = chatService.security.canModerate(event.npub, roomId);
          if (!isMod) {
            return shelf.Response.forbidden(
              jsonEncode({
                'error': 'Callsign mismatch',
                'code': 'CALLSIGN_MISMATCH',
              }),
              headers: headers,
            );
          }
        }

        // New content is in the event content field
        final newContent = event.content;
        if (newContent.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'New content cannot be empty'}),
            headers: headers,
          );
        }

        // Edit the message (ChatService handles authorization - author or moderator)
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

  /// Handle modifications log request
  /// GET /api/chat/{roomId}/modifications?since=ISO_TIMESTAMP
  Future<shelf.Response> _handleChatModificationsRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      await _initializeChatServiceIfNeeded();
      final chatService = ChatService();

      // Extract roomId from path: api/chat/{roomId}/modifications
      final regex = RegExp(r'^api/chat/(?:rooms/)?([^/]+)/modifications$');
      final match = regex.firstMatch(urlPath);
      if (match == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Invalid path format'}),
          headers: headers,
        );
      }

      final roomId = Uri.decodeComponent(match.group(1)!);
      final sinceParam = request.url.queryParameters['since'];
      DateTime? since;
      if (sinceParam != null && sinceParam.isNotEmpty) {
        since = DateTime.tryParse(sinceParam);
      }

      final modifications = await chatService.getModifications(roomId, since: since);

      return shelf.Response.ok(
        jsonEncode({
          'roomId': roomId,
          'modifications': modifications,
          'count': modifications.length,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error fetching modifications: $e');
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
      // Geogram callsigns start with 'X' followed by alphanumerics (e.g., X1ABC)
      // This prevents words like 'GENERAL' from being misinterpreted as callsigns
      final isCallsignLike = RegExp(r'^X[A-Z0-9]{2,}$').hasMatch(roomId.toUpperCase());

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

      if (chatService.appPath == null) {
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

  /// Handle GET /api/dm/{callsign}/retention - get retention period
  Future<shelf.Response> _handleDMGetRetention(
    shelf.Request request,
    String targetCallsign,
    Map<String, String> headers,
  ) async {
    try {
      final dmService = DirectMessageService();
      await dmService.initialize();

      final period = await dmService.getRetention(targetCallsign);
      final key = retentionToKey(period) ?? 'forever';

      return shelf.Response.ok(
        jsonEncode({
          'callsign': targetCallsign,
          'retention': key,
          'label': retentionLabel(period),
        }),
        headers: headers,
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/dm/{callsign}/retention - set retention period
  /// Body: {"retention": "1d"} — valid values: 1d, 1w, 1m, 1y, forever (or null)
  Future<shelf.Response> _handleDMSetRetention(
    shelf.Request request,
    String targetCallsign,
    Map<String, String> headers,
  ) async {
    try {
      final bodyStr = await request.readAsString();
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final retKey = body['retention'] as String?;
      final period = keyToRetention(retKey);

      final dmService = DirectMessageService();
      await dmService.initialize();
      await dmService.setRetention(targetCallsign, period);

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'callsign': targetCallsign,
          'retention': retentionToKey(period) ?? 'forever',
          'label': retentionLabel(period),
        }),
        headers: headers,
      );
    } catch (e) {
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
  /// Tracks upload progress for sender's UI
  Future<shelf.Response> _handleDMFileGetRequest(
    shelf.Request request,
    String senderCallsign,
    String filename,
    Map<String, String> headers,
  ) async {
    // Get the receiver's callsign (the device requesting the file)
    final receiverCallsign = request.headers['x-device-callsign']?.toUpperCase() ?? senderCallsign;
    final uploadManager = ChatFileUploadManager();

    try {
      // Security: prevent path traversal
      if (filename.contains('..') || filename.contains('/') || filename.contains('\\')) {
        uploadManager.failUpload(receiverCallsign, filename, 'Invalid filename');
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
        uploadManager.failUpload(receiverCallsign, filename, 'File not found');
        return shelf.Response.notFound(
          jsonEncode({'error': 'File not found'}),
          headers: headers,
        );
      }

      final file = io.File(filePath);
      if (!await file.exists()) {
        uploadManager.failUpload(receiverCallsign, filename, 'File not found');
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
      final totalBytes = fileBytes.length;

      // Start tracking upload
      uploadManager.startUpload(receiverCallsign, filename, totalBytes);
      LogService().log('LogApiService: Serving DM file to $receiverCallsign: $filename ($totalBytes bytes)');

      // Stream the file in chunks with progress tracking
      const chunkSize = 32 * 1024; // 32KB chunks
      var bytesSent = 0;

      Stream<List<int>> fileStream() async* {
        for (var offset = 0; offset < totalBytes; offset += chunkSize) {
          final end = (offset + chunkSize > totalBytes) ? totalBytes : offset + chunkSize;
          final chunk = fileBytes.sublist(offset, end);
          bytesSent += chunk.length;

          // Update progress
          uploadManager.updateProgress(receiverCallsign, filename, bytesSent);

          yield chunk;

          // Small delay to allow UI updates and prevent overwhelming slow connections
          if (bytesSent < totalBytes) {
            await Future.delayed(const Duration(milliseconds: 5));
          }
        }

        // Mark upload as completed
        uploadManager.completeUpload(receiverCallsign, filename);
        LogService().log('LogApiService: DM file upload completed: $filename to $receiverCallsign');
      }

      return shelf.Response.ok(
        fileStream(),
        headers: {
          ...headers,
          'Content-Type': contentType,
          'Content-Length': totalBytes.toString(),
        },
      );
    } catch (e) {
      LogService().log('LogApiService: Error serving DM file: $e');
      uploadManager.failUpload(receiverCallsign, filename, e.toString());
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
          return await _handleBackupSettingsGet(request, headers);
        } else if (method == 'PUT') {
          return await _handleBackupSettingsPut(request, headers);
        }
      }

      // GET /api/backup/availability - Provider availability (LAN query)
      if ((subPath == 'availability' || subPath == 'availability/') && method == 'GET') {
        return await _handleBackupAvailabilityGet(request, headers);
      }

      // POST /api/backup/message - Internal backup message relay (device-to-device)
      if ((subPath == 'message' || subPath == 'message/') && method == 'POST') {
        return await _handleBackupMessage(request, headers);
      }

      // GET /api/backup/clients - List clients (provider endpoint)
      if (subPath == 'clients' || subPath == 'clients/') {
        if (method == 'GET') {
          return await _handleBackupClientsGet(request, headers);
        }
      }

      // GET/DELETE /api/backup/clients/{callsign} - Client details or remove
      if (subPath.startsWith('clients/') && !subPath.contains('/snapshots')) {
        final callsign = _extractCallsignFromBackupPath(subPath, 'clients/');
        if (callsign != null) {
          if (method == 'GET') {
            return await _handleBackupClientGet(request, callsign, headers);
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
            return await _handleBackupSnapshotsGet(request, callsign, headers);
          }
        }
      }

      // PUT /api/backup/clients/{callsign}/snapshots/{date}/note - Update note
      final noteMatch = RegExp(r'^clients/([^/]+)/snapshots/([\w.-]+)/note/?$').firstMatch(subPath);
      if (noteMatch != null) {
        final callsign = noteMatch.group(1)!.toUpperCase();
        final snapshotId = noteMatch.group(2)!;
        if (method == 'PUT') {
          return await _handleBackupSnapshotNotePut(request, callsign, snapshotId, headers);
        }
      }

      // GET/PUT /api/backup/clients/{callsign}/snapshots/{date} - Manifest
      final snapshotMatch = RegExp(r'^clients/([^/]+)/snapshots/([\w.-]+)/?$').firstMatch(subPath);
      if (snapshotMatch != null) {
        final callsign = snapshotMatch.group(1)!.toUpperCase();
        final snapshotId = snapshotMatch.group(2)!;
        if (method == 'GET') {
          return await _handleBackupManifestGet(request, callsign, snapshotId, headers);
        } else if (method == 'PUT') {
          return await _handleBackupManifestPut(request, callsign, snapshotId, headers);
        }
      }

      // GET/PUT /api/backup/clients/{callsign}/snapshots/{date}/files/{name}
      final fileMatch = RegExp(r'^clients/([^/]+)/snapshots/([\w.-]+)/files/(.+)$').firstMatch(subPath);
      if (fileMatch != null) {
        final callsign = fileMatch.group(1)!.toUpperCase();
        final snapshotId = fileMatch.group(2)!;
        final fileName = fileMatch.group(3)!;
        if (method == 'GET') {
          return await _handleBackupFileGet(request, callsign, snapshotId, fileName, headers);
        } else if (method == 'PUT') {
          return await _handleBackupFilePut(request, callsign, snapshotId, fileName, headers);
        }
      }

      // GET /api/backup/providers - List providers (client endpoint)
      if (subPath == 'providers' || subPath == 'providers/') {
        if (method == 'GET') {
          return await _handleBackupProvidersGet(request, headers);
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
            return await _handleBackupProviderRemove(request, callsign, headers);
          } else if (method == 'GET') {
            return await _handleBackupProviderGet(request, callsign, headers);
          }
        }
      }

      // POST /api/backup/start - Start backup
      if (subPath == 'start' && method == 'POST') {
        return await _handleBackupStart(request, headers);
      }

      // GET /api/backup/status - Get backup/restore status
      if (subPath == 'status' && method == 'GET') {
        return await _handleBackupStatusGet(request, headers);
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
          return await _handleBackupDiscoverStatus(request, discoveryId, headers);
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

  /// POST /api/backup/message - Receive backup control messages from other devices
  Future<shelf.Response> _handleBackupMessage(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      if (body.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing message payload'}),
          headers: headers,
        );
      }

      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Invalid message format'}),
          headers: headers,
        );
      }

      final type = data['type'] as String?;
      if (type == null || type.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing message type'}),
          headers: headers,
        );
      }

      final backupService = BackupService();
      await backupService.initialize();

      final authEvent = _verifyBackupMessageAuth(request, data, backupService);
      if (authEvent == null) {
        return _backupAuthDenied(headers, error: 'Invalid backup message auth');
      }
      data['from'] ??= authEvent.getTagValue('callsign');

      switch (type) {
        case 'backup_invite':
          backupService.handleBackupInvite(data);
          break;
        case 'backup_invite_response':
          backupService.handleBackupInviteResponse(data);
          break;
        case 'backup_start':
          backupService.handleBackupStart(data);
          break;
        case 'backup_complete':
          await backupService.handleBackupComplete(data);
          break;
        case 'backup_discovery_challenge':
          backupService.handleDiscoveryChallenge(data);
          break;
        case 'backup_discovery_response':
          backupService.handleDiscoveryResponse(data);
          break;
        case 'backup_status_change':
          backupService.handleStatusChange(data);
          break;
        default:
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'Unsupported backup message type', 'type': type}),
            headers: headers,
          );
      }

      return shelf.Response.ok(
        jsonEncode({'success': true}),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Error handling backup message: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  NostrEvent? _verifyBackupMessageAuth(
    shelf.Request request,
    Map<String, dynamic> data,
    BackupService backupService,
  ) {
    final event = _parseBackupEventFromMessage(data['event']) ??
        _verifyNostrAuthEvent(request);
    if (event == null) return null;

    if (event.getTagValue('t') != 'backup') {
      LogService().log('LogApiService: Backup message auth failed - missing backup tag');
      return null;
    }

    final type = data['type'] as String?;
    if (type == null || type.isEmpty) return null;

    final action = event.getTagValue('action');
    if (!_isBackupMessageActionValid(type, action)) {
      LogService().log('LogApiService: Backup message auth failed - action mismatch');
      return null;
    }

    final from = data['from'] as String? ?? event.getTagValue('callsign');
    if (from == null || from.isEmpty) {
      LogService().log('LogApiService: Backup message auth failed - missing callsign');
      return null;
    }

    final tagCallsign = event.getTagValue('callsign');
    if (tagCallsign == null || tagCallsign.toUpperCase() != from.toUpperCase()) {
      LogService().log('LogApiService: Backup message auth failed - callsign mismatch');
      return null;
    }

    final target = data['target'] as String?;
    final targetTag = event.getTagValue('target');
    if (target != null && targetTag != null && targetTag.toUpperCase() != target.toUpperCase()) {
      LogService().log('LogApiService: Backup message auth failed - target mismatch');
      return null;
    }

    switch (type) {
      case 'backup_start':
      case 'backup_complete':
        final client = backupService.getClient(from);
        if (client == null || client.clientNpub != event.npub) {
          LogService().log('LogApiService: Backup message auth failed - client mismatch');
          return null;
        }
        break;
      case 'backup_status_change':
        final client = backupService.getClient(from);
        final provider = backupService.getProvider(from);
        if (client == null && provider == null) {
          LogService().log('LogApiService: Backup message auth failed - relationship missing');
          return null;
        }
        if (client != null && client.clientNpub != event.npub) {
          LogService().log('LogApiService: Backup message auth failed - client npub mismatch');
          return null;
        }
        if (provider != null && provider.providerNpub.isNotEmpty && provider.providerNpub != event.npub) {
          LogService().log('LogApiService: Backup message auth failed - provider npub mismatch');
          return null;
        }
        break;
      case 'backup_invite_response':
        final provider = backupService.getProvider(from);
        if (provider != null && provider.providerNpub.isNotEmpty && provider.providerNpub != event.npub) {
          LogService().log('LogApiService: Backup message auth failed - provider mismatch');
          return null;
        }
        break;
      default:
        break;
    }

    return event;
  }

  NostrEvent? _parseBackupEventFromMessage(dynamic eventData) {
    if (eventData is Map) {
      try {
        final event = NostrEvent.fromJson(Map<String, dynamic>.from(eventData));
        if (!event.verify()) {
          LogService().log('LogApiService: Backup message auth failed - invalid signature');
          return null;
        }
        if (!_isFreshNostrEvent(event)) {
          LogService().log('LogApiService: Backup message auth failed - event too old');
          return null;
        }
        return event;
      } catch (e) {
        LogService().log('LogApiService: Backup message auth failed - parse error: $e');
        return null;
      }
    }
    return null;
  }

  bool _isBackupMessageActionValid(String type, String? action) {
    switch (type) {
      case 'backup_invite':
        return action == 'backup_invite';
      case 'backup_invite_response':
        return action == 'backup_invite_response';
      case 'backup_start':
        return action == 'backup_start';
      case 'backup_complete':
        return action == 'backup_complete';
      case 'backup_status_change':
        return action == 'backup_status_change';
      case 'backup_discovery_challenge':
        return action == 'discovery_query';
      case 'backup_discovery_response':
        return action == 'discovery_response';
      default:
        return false;
    }
  }

  // === Provider Settings Endpoints ===

  /// GET /api/backup/settings - Get provider settings
  Future<shelf.Response> _handleBackupSettingsGet(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup settings access denied');
    }

    final settings = backupService.providerSettings;

    return shelf.Response.ok(
      jsonEncode(settings?.toJson() ?? {
        'enabled': false,
        'max_total_storage_bytes': 0,
        'default_max_client_storage_bytes': 0,
        'default_max_snapshots': 0,
        'auto_accept_from_contacts': false,
      }),
      headers: headers,
    );
  }

  /// PUT /api/backup/settings - Update provider settings
  Future<shelf.Response> _handleBackupSettingsPut(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup settings update denied');
    }

    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;

    final backupService = BackupService();
    await backupService.initialize();
    final currentSettings = backupService.providerSettings ?? BackupProviderSettings(
      enabled: false,
      maxTotalStorageBytes: 0,
      defaultMaxClientStorageBytes: 0,
      defaultMaxSnapshots: 0,
      autoAcceptFromContacts: false,
      updatedAt: DateTime.now(),
    );

    int? readInt(List<String> keys) {
      for (final key in keys) {
        final value = data[key];
        if (value is int) return value;
        if (value is String) {
          final parsed = int.tryParse(value);
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    bool? readBool(List<String> keys) {
      for (final key in keys) {
        final value = data[key];
        if (value is bool) return value;
        if (value is String) {
          final normalized = value.toLowerCase();
          if (normalized == 'true') return true;
          if (normalized == 'false') return false;
        }
      }
      return null;
    }

    // Update settings
    final newSettings = BackupProviderSettings(
      enabled: readBool(['enabled']) ?? currentSettings.enabled,
      maxTotalStorageBytes: readInt(['max_total_storage_bytes', 'maxTotalStorageBytes']) ??
          currentSettings.maxTotalStorageBytes,
      defaultMaxClientStorageBytes: readInt([
            'default_max_client_storage_bytes',
            'defaultMaxClientStorageBytes',
          ]) ??
          currentSettings.defaultMaxClientStorageBytes,
      defaultMaxSnapshots: readInt(['default_max_snapshots', 'defaultMaxSnapshots']) ??
          currentSettings.defaultMaxSnapshots,
      autoAcceptFromContacts: readBool(['auto_accept_from_contacts', 'autoAcceptFromContacts']) ??
          currentSettings.autoAcceptFromContacts,
      updatedAt: DateTime.now(),
    );

    await backupService.saveProviderSettings(newSettings);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'settings': newSettings.toJson()}),
      headers: headers,
    );
  }

  /// GET /api/backup/availability - Provider availability for LAN queries
  Future<shelf.Response> _handleBackupAvailabilityGet(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    if (_verifyBackupAuthEvent(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup availability auth required');
    }

    final backupService = BackupService();
    await backupService.initialize();

    final settings = backupService.providerSettings ?? BackupProviderSettings();
    final profile = ProfileService().getProfile();

    return shelf.Response.ok(
      jsonEncode({
        'enabled': settings.enabled,
        'callsign': profile.callsign,
        'npub': profile.npub,
        'max_total_storage_bytes': settings.maxTotalStorageBytes,
        'default_max_client_storage_bytes': settings.defaultMaxClientStorageBytes,
        'default_max_snapshots': settings.defaultMaxSnapshots,
        'updated_at': settings.updatedAt.toIso8601String(),
      }),
      headers: headers,
    );
  }

  // === Provider Client Management Endpoints ===

  /// GET /api/backup/clients - List all clients
  Future<shelf.Response> _handleBackupClientsGet(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup clients access denied');
    }

    final clients = backupService.getClients();

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
    shelf.Request request,
    String callsign,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup client access denied');
    }

    final clients = backupService.getClients();
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
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup client update denied');
    }

    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final action = data['action'] as String?;

    if (action == 'accept') {
      int? readInt(List<String> keys) {
        for (final key in keys) {
          final value = data[key];
          if (value is int) return value;
          if (value is String) {
            final parsed = int.tryParse(value);
            if (parsed != null) return parsed;
          }
        }
        return null;
      }

      final maxStorageBytes = readInt(['max_storage_bytes', 'maxStorageBytes']) ??
          backupService.providerSettings?.defaultMaxClientStorageBytes ?? 1073741824;
      final maxSnapshots = readInt(['max_snapshots', 'maxSnapshots']) ??
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
    await backupService.initialize();

    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup client removal denied');
    }

    await backupService.removeClient(callsign, deleteData: deleteData);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'message': 'Client removed', 'dataDeleted': deleteData}),
      headers: headers,
    );
  }

  /// GET /api/backup/clients/{callsign}/snapshots - List snapshots
  Future<shelf.Response> _handleBackupSnapshotsGet(
    shelf.Request request,
    String callsign,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupClientAuth(request, callsign) == null) {
      return _backupAuthDenied(headers, error: 'Backup snapshot list denied');
    }

    final snapshots = await backupService.getSnapshots(callsign);
    final client = backupService.getClient(callsign);
    final totalBytes = snapshots.fold<int>(0, (sum, s) => sum + s.totalBytes);

    return shelf.Response.ok(
      jsonEncode({
        'snapshots': snapshots.map((s) => s.toJson()).toList(),
        'total': snapshots.length,
        if (client != null) ...{
          'max_storage_bytes': client.maxStorageBytes,
          'current_storage_bytes': client.currentStorageBytes,
          'max_snapshots': client.maxSnapshots,
          'remaining_bytes': (client.maxStorageBytes - client.currentStorageBytes).clamp(0, client.maxStorageBytes),
        },
        'total_snapshot_bytes': totalBytes,
      }),
      headers: headers,
    );
  }

  /// PUT /api/backup/clients/{callsign}/snapshots/{date}/note - Update snapshot note
  Future<shelf.Response> _handleBackupSnapshotNotePut(
    shelf.Request request,
    String callsign,
    String snapshotId,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupClientAuth(request, callsign) == null) {
      return _backupAuthDenied(headers, error: 'Backup snapshot note denied');
    }

    final body = await request.readAsString();
    String note = '';
    if (body.isNotEmpty) {
      try {
        final json = jsonDecode(body);
        if (json is Map<String, dynamic>) {
          final value = json['note'];
          if (value is String) {
            note = value;
          } else if (value != null) {
            note = value.toString();
          }
        } else if (json is String) {
          note = json;
        }
      } catch (_) {
        note = body;
      }
    }

    await backupService.setSnapshotNote(callsign, snapshotId, note);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'snapshot_id': snapshotId, 'note': note}),
      headers: headers,
    );
  }

  /// GET /api/backup/clients/{callsign}/snapshots/{date} - Get manifest
  Future<shelf.Response> _handleBackupManifestGet(
    shelf.Request request,
    String callsign,
    String snapshotId,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupClientAuth(request, callsign) == null) {
      return _backupAuthDenied(headers, error: 'Backup manifest access denied');
    }

    final manifest = await backupService.getManifest(callsign, snapshotId);

    if (manifest == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Manifest not found', 'callsign': callsign, 'snapshotId': snapshotId}),
        headers: headers,
      );
    }

    // Return raw encrypted manifest as binary
    return shelf.Response.ok(
      manifest,
      headers: {
        ...headers,
        'Content-Type': 'application/octet-stream',
      },
    );
  }

  /// PUT /api/backup/clients/{callsign}/snapshots/{date} - Upload manifest
  Future<shelf.Response> _handleBackupManifestPut(
    shelf.Request request,
    String callsign,
    String snapshotId,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupClientAuth(request, callsign) == null) {
      return _backupAuthDenied(headers, error: 'Backup manifest upload denied');
    }

    final rawBytes = await request.read().expand((chunk) => chunk).toList();
    if (rawBytes.isEmpty) {
      return shelf.Response.badRequest(
        body: jsonEncode({'error': 'Missing manifest payload'}),
        headers: headers,
      );
    }

    final contentType = request.headers['content-type'] ?? '';
    final transferEncoding = request.headers['content-transfer-encoding'] ?? '';
    final bodyString = utf8.decode(rawBytes, allowMalformed: true);

    Uint8List? manifestBytes;
    if (transferEncoding.toLowerCase() == 'base64') {
      manifestBytes = Uint8List.fromList(base64Decode(bodyString));
    } else if (contentType.contains('application/json')) {
      try {
        final decoded = jsonDecode(bodyString);
        if (decoded is Map) {
          final dynamic value = decoded['manifest'] ?? decoded['data'];
          if (value is String) {
            manifestBytes = Uint8List.fromList(base64Decode(value));
          } else if (value is List) {
            manifestBytes = Uint8List.fromList(value.cast<int>());
          }
        } else if (decoded is String) {
          manifestBytes = Uint8List.fromList(base64Decode(decoded));
        } else if (decoded is List) {
          manifestBytes = Uint8List.fromList(decoded.cast<int>());
        }
      } catch (_) {
        // If JSON parsing fails, fall back to raw base64 string.
        manifestBytes = Uint8List.fromList(base64Decode(bodyString));
      }
    } else {
      manifestBytes = Uint8List.fromList(rawBytes);
    }

    if (manifestBytes == null) {
      return shelf.Response.badRequest(
        body: jsonEncode({'error': 'Invalid manifest payload'}),
        headers: headers,
      );
    }

    await backupService.saveManifest(callsign, snapshotId, manifestBytes);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'message': 'Manifest saved'}),
      headers: headers,
    );
  }

  /// GET /api/backup/clients/{callsign}/snapshots/{date}/files/{name} - Get encrypted file
  Future<shelf.Response> _handleBackupFileGet(
    shelf.Request request,
    String callsign,
    String snapshotId,
    String fileName,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupClientAuth(request, callsign) == null) {
      return _backupAuthDenied(headers, error: 'Backup file access denied');
    }

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
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupClientAuth(request, callsign) == null) {
      return _backupAuthDenied(headers, error: 'Backup file upload denied');
    }

    final rawBytes = await request.read().expand((chunk) => chunk).toList();
    if (rawBytes.isEmpty) {
      return shelf.Response.badRequest(
        body: jsonEncode({'error': 'Missing file payload'}),
        headers: headers,
      );
    }

    final contentType = request.headers['content-type'] ?? '';
    final transferEncoding = request.headers['content-transfer-encoding'] ?? '';
    final bodyString = utf8.decode(rawBytes, allowMalformed: true);

    Uint8List fileData;
    if (transferEncoding.toLowerCase() == 'base64') {
      fileData = Uint8List.fromList(base64Decode(bodyString));
    } else if (contentType.contains('application/json')) {
      try {
        final decoded = jsonDecode(bodyString);
        if (decoded is Map) {
          final dynamic value = decoded['data'] ?? decoded['file'];
          if (value is String) {
            fileData = Uint8List.fromList(base64Decode(value));
          } else if (value is List) {
            fileData = Uint8List.fromList(value.cast<int>());
          } else {
            fileData = Uint8List.fromList(rawBytes);
          }
        } else if (decoded is String) {
          fileData = Uint8List.fromList(base64Decode(decoded));
        } else if (decoded is List) {
          fileData = Uint8List.fromList(decoded.cast<int>());
        } else {
          fileData = Uint8List.fromList(rawBytes);
        }
      } catch (_) {
        // JSON parsing failed, treat as raw base64 string.
        fileData = Uint8List.fromList(base64Decode(bodyString));
      }
    } else {
      fileData = Uint8List.fromList(rawBytes);
    }

    await backupService.saveEncryptedFile(callsign, snapshotId, fileName, fileData);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'message': 'File saved', 'size': fileData.length}),
      headers: headers,
    );
  }

  // === Client Provider Management Endpoints ===

  /// GET /api/backup/providers - List providers
  Future<shelf.Response> _handleBackupProvidersGet(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup providers access denied');
    }

    final providers = backupService.getProviders();

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
    shelf.Request request,
    String callsign,
    Map<String, String> headers,
  ) async {
    final backupService = BackupService();
    await backupService.initialize();

    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup provider access denied');
    }

    final providers = backupService.getProviders();
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
    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup invite denied');
    }

    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    int? readInt(List<String> keys) {
      for (final key in keys) {
        final value = data[key];
        if (value is int) return value;
        if (value is String) {
          final parsed = int.tryParse(value);
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    final intervalDays = readInt(['backup_interval_days', 'interval_days', 'intervalDays']) ?? 1;

    final backupService = BackupService();
    await backupService.initialize();
    unawaited(backupService.sendInvite(callsign, intervalDays));

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
    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup provider update denied');
    }

    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;

    final backupService = BackupService();
    await backupService.initialize();
    final providers = backupService.getProviders();
    final provider = providers.where((p) => p.providerCallsign == callsign).firstOrNull;

    if (provider == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Provider not found', 'callsign': callsign}),
        headers: headers,
      );
    }

    // Update provider settings (e.g., interval)
    int? readInt(List<String> keys) {
      for (final key in keys) {
        final value = data[key];
        if (value is int) return value;
        if (value is String) {
          final parsed = int.tryParse(value);
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    final newInterval = readInt(['backup_interval_days', 'interval_days', 'intervalDays']);
    if (newInterval != null) {
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
    shelf.Request request,
    String callsign,
    Map<String, String> headers,
  ) async {
    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup provider removal denied');
    }

    final backupService = BackupService();
    await backupService.initialize();
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
    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup start denied');
    }

    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final providerCallsign = (data['provider_callsign'] ?? data['providerCallsign']) as String?;

    if (providerCallsign == null) {
      return shelf.Response.badRequest(
        body: jsonEncode({'error': 'Missing providerCallsign'}),
        headers: headers,
      );
    }

    final backupService = BackupService();
    await backupService.initialize();
    final status = await backupService.startBackup(providerCallsign);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'status': status.toJson()}),
      headers: headers,
    );
  }

  /// GET /api/backup/status - Get current backup/restore status
  Future<shelf.Response> _handleBackupStatusGet(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup status denied');
    }

    final backupService = BackupService();
    await backupService.initialize();
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
    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup restore denied');
    }

    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final providerCallsign = (data['provider_callsign'] ?? data['providerCallsign']) as String?;
    final snapshotId = (data['snapshot_id'] ?? data['snapshotId']) as String?;

    if (providerCallsign == null || snapshotId == null) {
      return shelf.Response.badRequest(
        body: jsonEncode({'error': 'Missing providerCallsign or snapshotId'}),
        headers: headers,
      );
    }

    final backupService = BackupService();
    await backupService.initialize();
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
    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup discovery denied');
    }

    final body = await request.readAsString();
    final data = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
    int? readInt(List<String> keys) {
      for (final key in keys) {
        final value = data[key];
        if (value is int) return value;
        if (value is String) {
          final parsed = int.tryParse(value);
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    final timeoutSeconds = readInt(['timeout_seconds', 'timeoutSeconds']) ?? 30;

    final backupService = BackupService();
    await backupService.initialize();
    final discoveryId = await backupService.startDiscovery(timeoutSeconds);

    return shelf.Response.ok(
      jsonEncode({'success': true, 'discoveryId': discoveryId}),
      headers: headers,
    );
  }

  /// GET /api/backup/discover/{id} - Get discovery status
  Future<shelf.Response> _handleBackupDiscoverStatus(
    shelf.Request request,
    String discoveryId,
    Map<String, String> headers,
  ) async {
    if (_verifyBackupOwnerAuth(request) == null) {
      return _backupAuthDenied(headers, error: 'Backup discovery status denied');
    }

    final backupService = BackupService();
    await backupService.initialize();
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
  // ============================================================
  // Apps Discovery Endpoint
  // ============================================================

  /// Handle GET /api/apps — aggregated app availability + counts
  Future<shelf.Response> _handleAppsDiscoveryRequest(
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

      String callsign = '';
      try {
        final profile = ProfileService().getProfile();
        callsign = profile.callsign;
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Profile not initialized'}),
          headers: headers,
        );
      }

      final storage = FilesystemProfileStorage('$dataDir/devices/$callsign');
      final handler = AppsHandler(
        storage: storage,
        log: (level, message) => LogService().log('AppsHandler [$level]: $message'),
      );

      final result = await handler.getApps();
      final statusCode = result['http_status'] as int? ?? 200;

      return shelf.Response(
        statusCode,
        body: jsonEncode(result),
        headers: headers,
      );
    } catch (e) {
      LogService().log('Error in apps discovery API: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': 'Internal server error',
          'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        }),
        headers: headers,
      );
    }
  }

  // Feedback API Endpoints (signed events: views, likes, comments, …)
  // ============================================================

  FeedbackHandler? _feedbackApi;

  FeedbackHandler _getFeedbackApi() {
    if (_feedbackApi != null) return _feedbackApi!;
    final profile = ProfileService().getProfile();
    final dataDir = StorageConfig().baseDir;
    _feedbackApi = FeedbackHandler(
      storage: FilesystemProfileStorage(
        '$dataDir/devices/${profile.callsign}',
      ),
      log: (level, message) =>
          LogService().log('FeedbackHandler: [$level] $message'),
    );
    return _feedbackApi!;
  }

  /// Routes /api/feedback/{contentType}/{contentId}/[action] to the shared
  /// FeedbackHandler. Same wire format as the station implementations
  /// (lib/station.dart, lib/cli/pure_station.dart,
  /// lib/services/station_server_service.dart) — each one duplicates this
  /// dispatch table because they all consume different request types
  /// (HttpRequest vs shelf.Request).
  Future<shelf.Response> _handleFeedbackRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      final segments = urlPath.split('/');
      // segments[0] == 'api', segments[1] == 'feedback'
      if (segments.length < 4) {
        return shelf.Response(400,
            body: jsonEncode({'error': 'Invalid feedback path'}),
            headers: headers);
      }
      final contentType = segments[2];
      final contentId = Uri.decodeComponent(segments[3]);
      final callsign = request.url.queryParameters['callsign'];

      final feedbackApi = _getFeedbackApi();
      Map<String, dynamic> result;

      if (request.method == 'GET') {
        if (segments.length == 4) {
          final params = request.url.queryParameters;
          final includeComments = params['include_comments'] == 'true';
          final commentLimit =
              int.tryParse(params['comment_limit'] ?? '') ?? 20;
          final commentOffset =
              int.tryParse(params['comment_offset'] ?? '') ?? 0;
          result = await feedbackApi.getFeedback(
            contentType: contentType,
            contentId: contentId,
            npub: params['npub'],
            callsign: callsign,
            includeComments: includeComments,
            commentLimit: commentLimit,
            commentOffset: commentOffset,
          );
        } else if (segments.length == 5 && segments[4] == 'stats') {
          result = await feedbackApi.getStats(
            contentType: contentType,
            contentId: contentId,
            callsign: callsign,
          );
        } else {
          return shelf.Response(400,
              body: jsonEncode({'error': 'Invalid feedback path'}),
              headers: headers);
        }
      } else if (request.method == 'POST') {
        if (segments.length < 5) {
          return shelf.Response(400,
              body: jsonEncode({'error': 'Missing feedback action'}),
              headers: headers);
        }
        final action = segments[4];
        final body = await request.readAsString();
        Map<String, dynamic> jsonBody = <String, dynamic>{};
        if (body.isNotEmpty) {
          try {
            jsonBody = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400,
                body: jsonEncode({'error': 'Invalid JSON body'}),
                headers: headers);
          }
        }
        switch (action) {
          case 'like':
            result = await feedbackApi.toggleFeedback(
              contentType: contentType,
              contentId: contentId,
              feedbackType: FeedbackFolderUtils.feedbackTypeLikes,
              actionName: 'like',
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'point':
            result = await feedbackApi.toggleFeedback(
              contentType: contentType,
              contentId: contentId,
              feedbackType: FeedbackFolderUtils.feedbackTypePoints,
              actionName: 'point',
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'dislike':
            result = await feedbackApi.toggleFeedback(
              contentType: contentType,
              contentId: contentId,
              feedbackType: FeedbackFolderUtils.feedbackTypeDislikes,
              actionName: 'dislike',
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'subscribe':
            result = await feedbackApi.toggleFeedback(
              contentType: contentType,
              contentId: contentId,
              feedbackType: FeedbackFolderUtils.feedbackTypeSubscribe,
              actionName: 'subscribe',
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'verify':
            result = await feedbackApi.verifyContent(
              contentType: contentType,
              contentId: contentId,
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'view':
            result = await feedbackApi.recordView(
              contentType: contentType,
              contentId: contentId,
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'comment':
            final author = jsonBody['author'] as String?;
            final content = jsonBody['content'] as String?;
            if (author == null || author.isEmpty ||
                content == null || content.isEmpty) {
              return shelf.Response(400,
                  body: jsonEncode({'error': 'Missing author or content'}),
                  headers: headers);
            }
            result = await feedbackApi.addComment(
              contentType: contentType,
              contentId: contentId,
              author: author,
              content: content,
              npub: jsonBody['npub'] as String?,
              signature: jsonBody['signature'] as String?,
              callsign: callsign,
            );
            break;
          default:
            return shelf.Response(400,
                body: jsonEncode({'error': 'Unknown feedback action: $action'}),
                headers: headers);
        }
        // Fire the shared notifier for events whose author should see
        // the new activity. Limited to event content for now (the only
        // place where the local user is "the author" in this shape).
        if (result['success'] == true &&
            (action == 'comment' || action == 'like') &&
            (contentType == 'event' || contentType == 'events')) {
          unawaited(_notifyEventActivity(contentId));
        }
      } else if (request.method == 'DELETE') {
        // /api/feedback/{contentType}/{contentId}/comment/{commentId}
        if (segments.length != 6 || segments[4] != 'comment') {
          return shelf.Response(400,
              body: jsonEncode(
                  {'error': 'DELETE only supported on /comment/{id}'}),
              headers: headers);
        }
        String? dataDir;
        try {
          dataDir = StorageConfig().baseDir;
        } catch (_) {}
        result = await FeedbackDeleteHelper.deleteComment(
          feedbackApi: feedbackApi,
          contentType: contentType,
          contentId: contentId,
          commentId: Uri.decodeComponent(segments[5]),
          requesterNpub: request.headers['x-npub'] ??
              request.headers['X-Npub'] ??
              '',
          dataDir: dataDir,
          callsign: callsign,
        );
      } else {
        return shelf.Response(405,
            body: jsonEncode({'error': 'Method not allowed'}),
            headers: headers);
      }

      final status = (result['http_status'] as int?) ?? 200;
      result.remove('http_status');
      return shelf.Response(
        status,
        body: jsonEncode(result),
        headers: headers,
      );
    } catch (e) {
      LogService().log('LogApiService: Feedback handler error: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Resolve an event's on-disk path and trigger the shared notifier so
  /// the owner gets a Now-panel entry + badge for the new activity.
  /// Best-effort — failures are swallowed so a notifier hiccup never
  /// breaks the underlying write.
  Future<void> _notifyEventActivity(String eventId) async {
    try {
      final dataDir = StorageConfig().baseDir;
      final ev =
          await EventService().findEventByIdGlobal(eventId, dataDir);
      if (ev == null) return;
      final path = await EventService().getEventPath(ev.id, dataDir);
      if (path == null) return;
      await EventActivityNotifier.scanEvent(
        eventPath: path,
        eventId: ev.id,
        eventTitle: ev.title,
      );
    } catch (e) {
      LogService().log('Notify event activity failed: $e');
    }
  }

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

      // Parse the sub-path to determine the operation. shelf's request.url.path
      // keeps percent-encoding (so "Return%20home" doesn't decode to a space)
      // — every consumer here looks up events by id, so decode each segment
      // before passing it on, otherwise the lookup never matches.
      final pathParts =
          subPath.split('/').map(Uri.decodeComponent).toList();

      if (pathParts.length >= 2 && pathParts[1] == 'media') {
        return await _handleEventMediaRequest(
          request,
          pathParts,
          dataDir,
          headers,
        );
      }

      // POST /api/events/{eventId}/like - Toggle like
      if (pathParts.length == 2 && pathParts[1] == 'like' && request.method == 'POST') {
        final eventId = pathParts[0];
        return await _handleEventToggleLike(request, eventId, dataDir, headers);
      }

      // POST /api/events/{eventId}/request-access - Submit an access
      // request for a request_access-gated event. Body should include
      // {npub, callsign?, message?}; the entry is appended to
      // {event}/feedback/access_requests.json so the owner can see it.
      if (pathParts.length == 2 &&
          pathParts[1] == 'request-access' &&
          request.method == 'POST') {
        final eventId = pathParts[0];
        return await _handleEventRequestAccess(
          request, eventId, dataDir, headers,
        );
      }

      // GET /api/events/{eventId}/access-requests
      //   → JSON list of pending + decided requests (owner-only).
      // POST /api/events/{eventId}/access-requests/{npub}/{action}
      //   action ∈ {approve, deny}. Approving adds the requester's
      //   callsign to ACCESS_CALLSIGNS:; denying remembers the answer
      //   so future POSTs from the same npub no-op.
      if (pathParts.length == 2 &&
          pathParts[1] == 'access-requests' &&
          request.method == 'GET') {
        return await _handleEventAccessRequestsList(
          pathParts[0], dataDir, headers,
        );
      }
      // GET /api/events/{eventId}/access-status?npub=NPUB
      //   → {status: 'granted' | 'pending' | 'denied' | 'none'}
      // Used by the station homepage so each "Recent Events" tile
      // shows whether the logged-in NOSTR identity already has
      // access. Public endpoint; the npub is the only input.
      if (pathParts.length == 2 &&
          pathParts[1] == 'access-status' &&
          request.method == 'GET') {
        return await _handleEventAccessStatus(
          request, pathParts[0], dataDir, headers,
        );
      }
      if (pathParts.length == 4 &&
          pathParts[1] == 'access-requests' &&
          (pathParts[3] == 'approve' || pathParts[3] == 'deny') &&
          request.method == 'POST') {
        return await _handleEventAccessRequestDecision(
          pathParts[0], pathParts[2], pathParts[3], dataDir, headers,
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
        return await _handleEventsGetFile(eventId, filePath, dataDir, headers,
            request: request);
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

    // Identify viewer for visibility filtering — same logic as the HTML
    // listing handler so unlisted/private events stay hidden from the
    // public JSON endpoint too. Connections from the local desktop (the
    // Flutter app talking to its own server, no cookie) are treated as
    // the owner so the user always sees their own events regardless of
    // visibility — without it, switching an event to private would make
    // it disappear from the user's own browser.
    String? userNpub;
    final hexPubkey = _extractNostrPubkeyFromCookie(request);
    if (hexPubkey != null) {
      try {
        userNpub = NostrCrypto.encodeNpub(hexPubkey);
      } catch (_) {}
    }
    userNpub ??= _verifyNostrAuth(request);
    final viewerCallsign = await _resolveViewerCallsign(userNpub);
    final ownerNpub = ProfileService().getProfile().npub;
    final isLocalRequest = _isLocalRequest(request);

    final events = await eventService.getAllEventsGlobal(dataDir, year: year);
    final visible = <Event>[];
    for (final event in events) {
      final vis = event.visibility;
      // Always show events owned by the local profile to a local request.
      // The desktop Flutter app uses this endpoint to render its events
      // browser — it has no NOSTR cookie, so without this branch the
      // user's own private events would disappear from their own UI.
      final ownsThisEvent = event.npub != null &&
          ownerNpub != null &&
          event.npub == ownerNpub;
      if (isLocalRequest && ownsThisEvent) {
        visible.add(event);
        continue;
      }
      if (vis == 'public' || vis == 'request_access') {
        visible.add(event);
        continue;
      }
      if (vis == 'private' || vis == 'unlisted') {
        // Owner / admin / explicit grants: include. Unlisted is *only*
        // listed for the owner — anyone else has the share link or
        // nothing.
        final isOwnerOrAdmin = userNpub != null &&
            (event.npub == userNpub || event.isAdmin(userNpub));
        if (vis == 'unlisted') {
          if (isOwnerOrAdmin) visible.add(event);
          continue;
        }
        bool allowed = isOwnerOrAdmin;
        if (!allowed && userNpub != null) {
          allowed = await _eventViewerInGroup(event, userNpub);
        }
        if (!allowed && viewerCallsign != null) {
          final cs = viewerCallsign.toUpperCase();
          allowed = event.accessCallsigns
              .map((c) => c.toUpperCase())
              .contains(cs);
        }
        if (allowed) visible.add(event);
        continue;
      }
      if (vis == 'group') {
        final isOwnerOrAdmin = userNpub != null &&
            (event.npub == userNpub || event.isAdmin(userNpub));
        bool allowed = isOwnerOrAdmin;
        if (!allowed && userNpub != null) {
          allowed = await _eventViewerInGroup(event, userNpub);
        }
        if (!allowed && viewerCallsign != null) {
          final cs = viewerCallsign.toUpperCase();
          allowed = event.accessCallsigns
              .map((c) => c.toUpperCase())
              .contains(cs);
        }
        if (allowed) visible.add(event);
        continue;
      }
      // Unknown visibility → treat as public.
      visible.add(event);
    }

    final years = await eventService.getAvailableYearsGlobal(dataDir);

    // Enrich each event summary with live feedback counts (likes /
    // comments / views) so the station homepage tiles can show the
    // same engagement numbers the in-app browser does. Also surface
    // the owning device's profile nickname so the tile can render
    // "Nickname (CALLSIGN)".
    String? deviceNickname;
    try {
      final p = ProfileService().getProfile();
      deviceNickname = p.nickname.isEmpty ? null : p.nickname;
    } catch (_) {}
    final enriched = <Map<String, dynamic>>[];
    for (final e in visible) {
      final json = e.toApiJson(summary: true);
      try {
        final eventPath = await eventService.getEventPath(e.id, dataDir);
        if (eventPath != null) {
          // likes — line count of feedback/likes.txt (with the legacy
          // ".feedback/" fallback the detail handler already uses)
          int likes = 0;
          int comments = 0;
          int views = 0;
          try {
            var likesFile = io.File('$eventPath/feedback/likes.txt');
            if (!await likesFile.exists()) {
              final legacy = io.File('$eventPath/.feedback/likes.txt');
              if (await legacy.exists()) likesFile = legacy;
            }
            if (await likesFile.exists()) {
              likes = (await likesFile.readAsString())
                  .split('\n')
                  .where((l) => l.trim().isNotEmpty)
                  .length;
            }
          } catch (_) {}
          try {
            final commentsDir = io.Directory('$eventPath/feedback/comments');
            if (await commentsDir.exists()) {
              comments = await commentsDir
                  .list()
                  .where((entity) => entity is io.File &&
                      entity.path.endsWith('.txt'))
                  .length;
            }
          } catch (_) {}
          try {
            final viewsFile = io.File('$eventPath/feedback/views.txt');
            if (await viewsFile.exists()) {
              views = (await viewsFile.readAsString())
                  .split('\n')
                  .where((l) => l.trim().isNotEmpty)
                  .length;
            }
          } catch (_) {}
          json['like_count'] = likes;
          json['comment_count'] = comments;
          json['view_count'] = views;
        }
      } catch (_) {}
      if (deviceNickname != null) {
        json['device_nickname'] = deviceNickname;
      }
      enriched.add(json);
    }

    return shelf.Response.ok(
      jsonEncode({
        'events': enriched,
        'years': years,
        'total': visible.length,
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
    Map<String, String> headers, {
    shelf.Request? request,
  }) async {
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

    final ext = path.extension(filePath).toLowerCase();
    final wantsThumb =
        request?.url.queryParameters['thumb'] == '1';

    // Thumbnail mode: hand back a small JPEG so the gallery grid loads fast
    // instead of forcing every browser to download every full-resolution
    // photo / video. Cached through FileBrowserCacheService so the desktop
    // file browser sees the same thumbnails on first hover and we don't
    // regenerate them per request.
    if (wantsThumb && _isGalleryMediaExt(ext)) {
      final thumb = await _eventThumbnailBytes(file, ext);
      if (thumb != null) {
        return shelf.Response.ok(
          thumb.bytes,
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, OPTIONS',
            'Content-Type': thumb.contentType,
            'Content-Length': thumb.bytes.length.toString(),
            // Long cache — bytes are content-addressed by source mtime in the
            // service-level cache so a fresh upload invalidates naturally.
            'Cache-Control': 'public, max-age=604800',
          },
        );
      }
      // Fall through to full file when thumbnail generation fails.
    }

    // Determine MIME type
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

  static const _galleryImageExts = {
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp',
  };
  static const _galleryVideoExts = {
    '.mp4', '.mov', '.webm', '.mkv', '.avi', '.wmv', '.flv',
  };

  bool _isGalleryMediaExt(String ext) =>
      _galleryImageExts.contains(ext) || _galleryVideoExts.contains(ext);

  /// Small thumbnail (~480px wide JPEG) for an event flyer, cached through
  /// FileBrowserCacheService so a later browse / re-load of the gallery
  /// reuses the same bytes.
  Future<_EventThumb?> _eventThumbnailBytes(io.File source, String ext) async {
    try {
      final stat = await source.stat();
      final cache = FileBrowserCacheService();
      await cache.initialize();

      // Cache hit?
      if (await cache.hasThumbnail(source.path, stat.modified)) {
        final cachedPath =
            await cache.getThumbnailTempPath(source.path);
        if (cachedPath != null) {
          final cachedFile = io.File(cachedPath);
          if (await cachedFile.exists()) {
            final bytes = await cachedFile.readAsBytes();
            // Cached files keep their original extension; treat png as png,
            // everything else as jpeg.
            final ct = cachedPath.toLowerCase().endsWith('.png')
                ? 'image/png'
                : 'image/jpeg';
            return _EventThumb(bytes, ct);
          }
        }
      }

      Uint8List? bytes;
      String cacheExt = 'jpg';
      String contentType = 'image/jpeg';

      if (_galleryImageExts.contains(ext)) {
        // Decode + downscale + re-encode as JPEG so the grid loads quickly.
        final original = await source.readAsBytes();
        final decoded = img.decodeImage(original);
        if (decoded == null) return null;
        final resized = decoded.width > 480
            ? img.copyResize(
                decoded,
                width: 480,
                interpolation: img.Interpolation.average,
              )
            : decoded;
        bytes = Uint8List.fromList(img.encodeJpg(resized, quality: 75));
      } else if (_galleryVideoExts.contains(ext)) {
        // Reuse the same media_kit-based extractor as the file browser, so a
        // video that has already been thumbnailed there hits the cache here
        // (and vice versa).
        final tempDir = io.Directory.systemTemp;
        final outPath =
            '${tempDir.path}/event_thumb_${source.path.hashCode}.png';
        final thumbPath = await VideoMetadataExtractor.generateThumbnail(
          source.path,
          outPath,
          atSeconds: 1,
        );
        if (thumbPath == null) return null;
        bytes = await io.File(thumbPath).readAsBytes();
        cacheExt = 'png';
        contentType = 'image/png';
        try {
          await io.File(thumbPath).delete();
        } catch (_) {}
      }

      if (bytes == null) return null;

      // Persist into the shared file-browser cache so the same thumbnail is
      // served on next request and the file browser picks it up too.
      try {
        await cache.saveThumbnail(
          source.path,
          bytes,
          stat.modified,
          extension: cacheExt,
        );
      } catch (_) {
        // Cache failures are non-fatal; the thumbnail still gets served.
      }

      return _EventThumb(bytes, contentType);
    } catch (e) {
      LogService().log('Event thumbnail generation failed: $e');
      return null;
    }
  }

  /// POST /api/events/{eventId}/like - Toggle like via signed NOSTR event
  Future<shelf.Response> _handleEventToggleLike(
    shelf.Request request,
    String eventId,
    String dataDir,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final eventJson = jsonDecode(body) as Map<String, dynamic>;

      if (!eventJson.containsKey('id') || !eventJson.containsKey('sig')) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing required NOSTR event fields (id, sig)'}),
          headers: headers,
        );
      }

      // Extract pubkey from signed event
      final pubkey = eventJson['pubkey'] as String?;
      if (pubkey == null || pubkey.isEmpty) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing pubkey in signed event'}),
          headers: headers,
        );
      }

      // Find event (by ID or slug)
      final allEvents = await EventService().getAllEventsGlobal(dataDir);
      var event = allEvents.cast<Event?>().firstWhere(
        (e) => e?.id == eventId,
        orElse: () => null,
      );
      event ??= allEvents.cast<Event?>().firstWhere(
        (e) => e?.slug == eventId,
        orElse: () => null,
      );
      if (event == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found'}),
          headers: headers,
        );
      }

      // Get event path for feedback storage
      final eventPath = await EventService().getEventPath(event.id, dataDir);
      if (eventPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event path not found'}),
          headers: headers,
        );
      }

      // Convert hex pubkey to npub
      String npub;
      try {
        npub = NostrCrypto.encodeNpub(pubkey);
      } catch (_) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Invalid pubkey'}),
          headers: headers,
        );
      }

      // Read current likes. Use the canonical FeedbackFolderUtils path
      // ("feedback/likes.txt") so likes added through the web Like button
      // show up in the Flutter EventLikeButton — which reads through the
      // same helper — and vice versa. Seeds the new file from the legacy
      // ".feedback/likes.txt" location once so existing likes survive
      // the convergence; subsequent toggles always write the new path.
      final likesFile = io.File('$eventPath/feedback/likes.txt');
      List<String> likes = [];
      if (await likesFile.exists()) {
        final content = await likesFile.readAsString();
        likes = content
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
      } else {
        final legacy = io.File('$eventPath/.feedback/likes.txt');
        if (await legacy.exists()) {
          final content = await legacy.readAsString();
          likes = content
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList();
        }
      }

      // Toggle
      final wasLiked = likes.contains(npub);
      if (wasLiked) {
        likes.remove(npub);
      } else {
        likes.add(npub);
      }

      // Write back
      await likesFile.parent.create(recursive: true);
      await likesFile.writeAsString(likes.join('\n'));

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'liked': !wasLiked,
          'like_count': likes.length,
        }),
        headers: headers,
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Failed to toggle like: $e'}),
        headers: headers,
      );
    }
  }

  /// POST /api/events/{eventId}/request-access
  ///
  /// Records an access request from a NOSTR-identified visitor for an
  /// event whose visibility is `request_access`. The request is appended
  /// to {event}/feedback/access_requests.json — a JSON array of objects
  /// {npub, callsign, message, requested_at, status='pending'} so the
  /// owner can review them in the desktop UI later.
  ///
  /// Body: {npub, callsign?, message?}
  Future<shelf.Response> _handleEventRequestAccess(
    shelf.Request request,
    String eventId,
    String dataDir,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final json = body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(body) as Map<String, dynamic>;
      final npub = (json['npub'] as String?)?.trim() ?? '';
      if (npub.isEmpty || !npub.startsWith('npub1')) {
        return shelf.Response(400,
            body: jsonEncode({'error': 'Missing or invalid npub'}),
            headers: headers);
      }
      final callsign = (json['callsign'] as String?)?.trim() ?? '';
      final nickname = (json['nickname'] as String?)?.trim() ?? '';
      final message = (json['message'] as String?)?.trim() ?? '';

      final event = await EventService().findEventByIdGlobal(eventId, dataDir);
      if (event == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found'}),
          headers: headers,
        );
      }
      if (event.visibility != 'request_access') {
        return shelf.Response(400,
            body: jsonEncode({
              'error':
                  'Event does not accept access requests (visibility=${event.visibility})',
            }),
            headers: headers);
      }

      final eventPath = await EventService().getEventPath(event.id, dataDir);
      if (eventPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event path not found'}),
          headers: headers,
        );
      }

      final requestsFile = io.File('$eventPath/feedback/access_requests.json');
      List<dynamic> existing = [];
      if (await requestsFile.exists()) {
        try {
          final content = await requestsFile.readAsString();
          if (content.trim().isNotEmpty) {
            existing = jsonDecode(content) as List<dynamic>;
          }
        } catch (_) {}
      }

      // If the owner already decided on this requester, remember the
      // answer instead of generating a fresh pending entry. The page
      // shows whatever final status we already have so the requester
      // doesn't get to spam the inbox with the same request.
      final prior = existing.firstWhere(
        (e) => e is Map<String, dynamic> && e['npub'] == npub,
        orElse: () => null,
      );
      var firedNotification = false;
      if (prior is Map<String, dynamic>) {
        final priorStatus = (prior['status'] as String?) ?? 'pending';
        if (priorStatus == 'approved' || priorStatus == 'denied') {
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'status': priorStatus,
              'message': priorStatus == 'approved'
                  ? 'Access already granted'
                  : 'Request previously denied',
            }),
            headers: headers,
          );
        }
        // Refresh the pending entry's metadata in place rather than
        // appending a duplicate.
        prior['callsign'] = callsign.isNotEmpty
            ? callsign
            : prior['callsign'] ?? '';
        prior['nickname'] = nickname.isNotEmpty
            ? nickname
            : prior['nickname'] ?? '';
        prior['message'] = message.isNotEmpty
            ? message
            : prior['message'] ?? '';
        prior['requested_at'] = DateTime.now().toUtc().toIso8601String();
      } else {
        existing.add({
          'npub': npub,
          'callsign': callsign,
          'nickname': nickname,
          'message': message,
          'requested_at': DateTime.now().toUtc().toIso8601String(),
          'status': 'pending',
        });
        firedNotification = true;
      }

      await requestsFile.parent.create(recursive: true);
      await requestsFile.writeAsString(jsonEncode(existing));

      // Surface a "now" entry via the shared notifier so the owner sees
      // the pending request show up in the Now panel + drawer badge.
      // The notifier handles dedup/labelling for every event-activity
      // type (access-requests / comments / likes / future) so we don't
      // grow per-type emit code at every write site.
      if (firedNotification) {
        try {
          await EventActivityNotifier.scanEvent(
            eventPath: eventPath,
            eventId: event.id,
            eventTitle: event.title,
          );
        } catch (e) {
          LogService().log('Now event fire failed: $e');
        }
        // Upsert a Contact for this requester so the owner sees their
        // profile nickname (if they shared one in their kind-0 metadata)
        // alongside the callsign in the Allowed-callsigns picker — and
        // anywhere else the contact is later looked up. Best-effort:
        // failures are non-fatal, the pending entry is the source of
        // truth either way.
        if (callsign.isNotEmpty) {
          await _upsertRequesterContact(
            callsign: callsign,
            npub: npub,
            nickname: nickname,
          );
        }
      }

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'status': 'pending',
          'pending': existing
              .where((e) =>
                  e is Map<String, dynamic> &&
                  (e['status'] ?? 'pending') == 'pending')
              .length,
        }),
        headers: headers,
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Failed to record access request: $e'}),
        headers: headers,
      );
    }
  }

  /// GET /api/events/{eventId}/access-requests — owner-only.
  /// Returns the JSON list as-is (pending + approved + denied entries) so
  /// the desktop UI can render an inbox.
  Future<shelf.Response> _handleEventAccessRequestsList(
    String eventId,
    String dataDir,
    Map<String, String> headers,
  ) async {
    try {
      final event = await EventService().findEventByIdGlobal(eventId, dataDir);
      if (event == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found'}),
          headers: headers,
        );
      }
      final eventPath = await EventService().getEventPath(event.id, dataDir);
      if (eventPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event path not found'}),
          headers: headers,
        );
      }
      final file = io.File('$eventPath/feedback/access_requests.json');
      if (!await file.exists()) {
        return shelf.Response.ok(
          jsonEncode({'requests': const []}),
          headers: headers,
        );
      }
      try {
        final content = await file.readAsString();
        final list = content.trim().isEmpty
            ? const []
            : jsonDecode(content) as List<dynamic>;
        return shelf.Response.ok(
          jsonEncode({'requests': list}),
          headers: headers,
        );
      } catch (e) {
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Corrupted requests file: $e'}),
          headers: headers,
        );
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Failed to list access requests: $e'}),
        headers: headers,
      );
    }
  }

  /// GET /api/events/{eventId}/access-status?npub=NPUB
  ///
  /// Public probe used by the station homepage so each "Recent Events"
  /// tile can paint a real status (granted / pending / denied / none)
  /// without leaking content. Resolves the npub against the event's
  /// access_requests.json AND the event's accessCallsigns list (mapped
  /// via Contacts), so a callsign added directly by the owner — no
  /// request needed — still shows as granted.
  Future<shelf.Response> _handleEventAccessStatus(
    shelf.Request request,
    String eventId,
    String dataDir,
    Map<String, String> headers,
  ) async {
    final npub = request.url.queryParameters['npub']?.trim() ?? '';
    if (npub.isEmpty || !npub.startsWith('npub1')) {
      return shelf.Response.ok(
        jsonEncode({'status': 'none'}),
        headers: headers,
      );
    }
    try {
      final event = await EventService().findEventByIdGlobal(eventId, dataDir);
      if (event == null) {
        return shelf.Response.notFound(
          jsonEncode({'status': 'none'}),
          headers: headers,
        );
      }
      // Owner / admin / explicit grants check.
      final isOwnerOrAdmin =
          event.npub == npub || event.isAdmin(npub);
      if (isOwnerOrAdmin) {
        return shelf.Response.ok(
          jsonEncode({'status': 'granted'}),
          headers: headers,
        );
      }
      // Map npub → callsign via local contacts; if that callsign is in
      // accessCallsigns, the visibility filter would let them through.
      final viewerCallsign = await _resolveViewerCallsign(npub);
      if (viewerCallsign != null &&
          event.accessCallsigns
              .map((c) => c.toUpperCase())
              .contains(viewerCallsign.toUpperCase())) {
        return shelf.Response.ok(
          jsonEncode({'status': 'granted'}),
          headers: headers,
        );
      }
      // Group membership — same lookup the detail handler uses.
      if (await _eventViewerInGroup(event, npub)) {
        return shelf.Response.ok(
          jsonEncode({'status': 'granted'}),
          headers: headers,
        );
      }
      // Otherwise consult access_requests.json for a pending / denied
      // entry from this npub.
      final eventPath = await EventService().getEventPath(event.id, dataDir);
      if (eventPath != null) {
        final file = io.File('$eventPath/feedback/access_requests.json');
        if (await file.exists()) {
          try {
            final content = await file.readAsString();
            if (content.trim().isNotEmpty) {
              final list = jsonDecode(content) as List<dynamic>;
              for (final raw in list.whereType<Map<String, dynamic>>()) {
                if (raw['npub'] == npub) {
                  final s = (raw['status'] as String?) ?? 'pending';
                  // Normalise the status taxonomy used by the homepage JS
                  // (granted | pending | denied | none). 'approved' on the
                  // request inbox = 'granted' here.
                  final normalized = s == 'approved' ? 'granted' : s;
                  return shelf.Response.ok(
                    jsonEncode({'status': normalized}),
                    headers: headers,
                  );
                }
              }
            }
          } catch (_) {}
        }
      }
      return shelf.Response.ok(
        jsonEncode({'status': 'none'}),
        headers: headers,
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'status': 'none', 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// POST /api/events/{eventId}/access-requests/{npub}/{action}
  ///
  /// Updates an entry's status. Approving also appends the requester's
  /// callsign to ACCESS_CALLSIGNS: on event.txt so the visibility filter
  /// honours the grant on the next request. Denying flips status to
  /// 'denied' so future POSTs to /request-access from the same npub no-op.
  Future<shelf.Response> _handleEventAccessRequestDecision(
    String eventId,
    String npub,
    String action,
    String dataDir,
    Map<String, String> headers,
  ) async {
    try {
      final event = await EventService().findEventByIdGlobal(eventId, dataDir);
      if (event == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event not found'}),
          headers: headers,
        );
      }
      final eventPath = await EventService().getEventPath(event.id, dataDir);
      if (eventPath == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Event path not found'}),
          headers: headers,
        );
      }
      final file = io.File('$eventPath/feedback/access_requests.json');
      if (!await file.exists()) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'No requests recorded'}),
          headers: headers,
        );
      }
      final content = await file.readAsString();
      final list = (content.trim().isEmpty
          ? <dynamic>[]
          : jsonDecode(content) as List<dynamic>);
      final entryIdx = list.indexWhere(
        (e) => e is Map<String, dynamic> && e['npub'] == npub,
      );
      if (entryIdx < 0) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Request not found for npub'}),
          headers: headers,
        );
      }
      final entry = list[entryIdx] as Map<String, dynamic>;
      final newStatus = action == 'approve' ? 'approved' : 'denied';
      entry['status'] = newStatus;
      entry['decided_at'] = DateTime.now().toUtc().toIso8601String();
      list[entryIdx] = entry;
      await file.writeAsString(jsonEncode(list));

      // On approve, persist the callsign on the event so the visibility
      // filter lets the requester through next time. EventService's
      // updateEvent depends on its _appPath being initialised which isn't
      // guaranteed in the HTTP context, so we re-serialise event.txt
      // directly via the same exportAsText round-trip.
      if (newStatus == 'approved') {
        final csRaw = (entry['callsign'] as String?)?.trim() ?? '';
        final cs = csRaw.toUpperCase();
        if (cs.isNotEmpty &&
            !event.accessCallsigns
                .map((c) => c.toUpperCase())
                .contains(cs)) {
          try {
            final eventFile = io.File('$eventPath/event.txt');
            if (await eventFile.exists()) {
              final updated = event.copyWith(
                accessCallsigns: [...event.accessCallsigns, cs],
              );
              await eventFile.writeAsString(updated.exportAsText());
            }
          } catch (e) {
            LogService().log('access-request approve: persist failed: $e');
          }
        }
      }

      // Drop the matching Now entry so the owner doesn't keep seeing
      // the decided request in the panel.
      try {
        NowService().removeItem('access-request:${event.id}:$npub');
      } catch (_) {}

      return shelf.Response.ok(
        jsonEncode({'success': true, 'status': newStatus}),
        headers: headers,
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Failed to update access request: $e'}),
        headers: headers,
      );
    }
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

      // Check if alert has photos (alertPath is absolute from _getAllAlertsGlobal)
      final alertDirStorage = FilesystemProfileStorage(alertPath);
      final hasPhotos = await _alertHasPhotos('', alertDirStorage);

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
    final alertStorage = result.$3;

    // Get list of photos
    final photos = await _getAlertPhotos(alertPath, alertStorage);

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
    final fileStorage = result.$3;

    // Sanitize path to prevent directory traversal
    if (filePath.contains('..')) {
      return shelf.Response.forbidden(
        jsonEncode({'error': 'Invalid path'}),
        headers: headers,
      );
    }

    final relativePath = '$alertPath/$filePath';
    if (!await fileStorage.exists(relativePath)) {
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
    final bytes = await fileStorage.readBytes(relativePath);
    if (bytes == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'File not found', 'path': filePath}),
        headers: headers,
      );
    }

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
  /// Scans alerts directory and matches by apiId since folder names use different format.
  /// Returns (Report, relativePath, ProfileStorage) where relativePath is relative to storage root.
  Future<(Report, String, ProfileStorage)?> _getAlertByApiId(String apiId, String dataDir) async {
    final profile = ProfileService().getProfile();
    final storage = FilesystemProfileStorage('$dataDir/devices/${profile.callsign}');
    if (!await storage.directoryExists('alerts')) return null;

    final entries = await storage.listDirectory('alerts', recursive: true);
    for (final entry in entries) {
      if (entry.isDirectory || entry.name != 'report.txt') continue;

      try {
        final content = await storage.readString(entry.path);
        if (content == null) continue;
        final alertDirPath = entry.path.replaceFirst('/report.txt', '').replaceFirst('\\report.txt', '');
        final folderName = alertDirPath.split('/').last.split('\\').last;
        final alert = Report.fromText(content, folderName);

        if (alert.apiId == apiId) {
          return (alert, alertDirPath, storage);
        }
      } catch (e) {
        // Skip malformed alerts
      }
    }
    return null;
  }

  /// Check if an alert has photos (checks both root and images/ subfolder)
  /// [alertPath] is relative to [storage] root.
  Future<bool> _alertHasPhotos(String alertPath, ProfileStorage storage) async {
    final photoExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];

    // Check images/ subfolder first (new structure)
    final imagesPath = alertPath.isEmpty ? 'images' : '$alertPath/images';
    if (await storage.directoryExists(imagesPath)) {
      final imageEntries = await storage.listDirectory(imagesPath);
      for (final entry in imageEntries) {
        if (!entry.isDirectory) {
          final ext = path.extension(entry.name).toLowerCase();
          if (photoExtensions.contains(ext)) {
            return true;
          }
        }
      }
    }

    // Also check root folder for backwards compatibility
    if (!await storage.directoryExists(alertPath.isEmpty ? '.' : alertPath)) return false;

    final rootEntries = await storage.listDirectory(alertPath.isEmpty ? '.' : alertPath);
    for (final entry in rootEntries) {
      if (!entry.isDirectory) {
        final ext = path.extension(entry.name).toLowerCase();
        if (photoExtensions.contains(ext)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Get list of photo filenames in an alert directory (checks both root and images/ subfolder)
  /// Returns filenames prefixed with 'images/' for photos in the images subfolder.
  /// [alertPath] is relative to [storage] root.
  Future<List<String>> _getAlertPhotos(String alertPath, ProfileStorage storage) async {
    final photos = <String>[];
    final photoExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];

    // Check images/ subfolder first (new structure)
    final imagesPath = alertPath.isEmpty ? 'images' : '$alertPath/images';
    if (await storage.directoryExists(imagesPath)) {
      final imageEntries = await storage.listDirectory(imagesPath);
      for (final entry in imageEntries) {
        if (!entry.isDirectory) {
          final ext = path.extension(entry.name).toLowerCase();
          if (photoExtensions.contains(ext)) {
            photos.add('images/${entry.name}');
          }
        }
      }
    }

    // Also check root folder for backwards compatibility
    final rootPath = alertPath.isEmpty ? '.' : alertPath;
    if (await storage.directoryExists(rootPath)) {
      final rootEntries = await storage.listDirectory(rootPath);
      for (final entry in rootEntries) {
        if (!entry.isDirectory) {
          final ext = path.extension(entry.name).toLowerCase();
          if (photoExtensions.contains(ext)) {
            photos.add(entry.name);
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

      void configureEventStorage(EventService service, String appPath) {
        final profileStorage = AppService().profileStorage;
        if (profileStorage != null) {
          service.setStorage(
            ScopedProfileStorage.fromAbsolutePath(profileStorage, appPath),
          );
        } else {
          service.setStorage(FilesystemProfileStorage(appPath));
        }
      }

      switch (action) {
        case 'event_create':
          // Create a test event
          final title = params['title'] as String? ?? 'Test Event ${DateTime.now().millisecondsSinceEpoch}';
          final content = params['content'] as String? ?? 'This is a test event created via debug API.';
          final location = params['location'] as String? ?? 'online';
          final locationName = params['location_name'] as String?;
          final appName = params['app_name'] as String? ?? 'my-events';
          final visibility = params['visibility'] as String?;
          final groupAccess = (params['group_access'] as String?)
              ?.split(',')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList();

          // Get callsign from profile service
          String callsign = 'TEST';
          String? npub;
          try {
            final profile = ProfileService().getProfile();
            callsign = profile.callsign;
            npub = profile.npub;
          } catch (e) {
            // Profile service not initialized, use TEST callsign
          }

          // Initialize EventService for this app
          final eventService = EventService();
          final appPath = '$dataDir/devices/$callsign/$appName';
          configureEventStorage(eventService, appPath);

          // Initialize the events directory
          await eventService.initializeApp(appPath);

          // Create the event
          final customSlug = params['custom_slug'] as String?;
          final event = await eventService.createEvent(
            author: callsign,
            title: title,
            location: location,
            locationName: locationName,
            content: content,
            visibility: visibility,
            groupAccess: groupAccess,
            npub: npub,
            customSlug: customSlug,
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

        case 'event_upload':
          // Upload an existing local event to the station
          final eventId = params['event_id'] as String?;
          if (eventId == null || eventId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({'success': false, 'error': 'Missing event_id parameter'}),
              headers: headers,
            );
          }

          // Get callsign
          String callsign = 'UNKNOWN';
          try {
            callsign = ProfileService().getProfile().callsign;
          } catch (_) {}

          final appName = params['app_name'] as String? ?? 'my-events';
          final year = eventId.substring(0, 4);

          // Search for the event in the app directory (events stored at {appDir}/{year}/{eventId}/)
          String? eventPath;
          final candidatePaths = [
            '$dataDir/devices/$callsign/$appName/$year/$eventId',
            '$dataDir/devices/$callsign/$appName/events/$year/$eventId',
          ];
          for (final candidate in candidatePaths) {
            if (await io.Directory(candidate).exists()) {
              eventPath = candidate;
              break;
            }
          }

          // Fallback: try getEventPath which scans all devices/apps
          eventPath ??= await EventService().getEventPath(eventId, dataDir!);

          if (eventPath == null) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Event not found',
                'event_id': eventId,
                'searched': candidatePaths,
              }),
              headers: headers,
            );
          }

          // Get station URL
          final stationService = StationService();
          if (!stationService.isInitialized) {
            await stationService.initialize();
          }
          final preferred = stationService.getPreferredStation();
          final station = (preferred != null && preferred.url.isNotEmpty)
              ? preferred
              : stationService.getConnectedStation();
          if (station == null || station.url.isEmpty) {
            return shelf.Response.internalServerError(
              body: jsonEncode({'success': false, 'error': 'No station configured'}),
              headers: headers,
            );
          }

          var baseUrl = station.url;
          if (baseUrl.startsWith('wss://')) {
            baseUrl = baseUrl.replaceFirst('wss://', 'https://');
          } else if (baseUrl.startsWith('ws://')) {
            baseUrl = baseUrl.replaceFirst('ws://', 'http://');
          }

          final uploadRelativePath = '$year/$eventId/event.txt';

          final eventFile = io.File('$eventPath/event.txt');
          if (!await eventFile.exists()) {
            return shelf.Response.notFound(
              jsonEncode({'success': false, 'error': 'event.txt not found in event folder'}),
              headers: headers,
            );
          }

          final bytes = await eventFile.readAsBytes();
          final baseUri = Uri.parse(baseUrl);
          final uploadUri = baseUri.replace(
            pathSegments: [
              ...baseUri.pathSegments,
              callsign,
              'api',
              'events',
              'files',
              ...uploadRelativePath.split('/'),
            ],
          );

          final uploadResponse = await http.post(
            uploadUri,
            headers: {
              'Content-Type': 'text/plain',
              'X-Callsign': callsign,
            },
            body: bytes,
          ).timeout(const Duration(seconds: 30));

          if (uploadResponse.statusCode == 200 || uploadResponse.statusCode == 201) {
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'event_id': eventId,
                'station': baseUrl,
                'uploaded_path': uploadRelativePath,
                'size': bytes.length,
              }),
              headers: headers,
            );
          } else {
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': 'Station rejected upload: ${uploadResponse.statusCode}',
                'body': uploadResponse.body,
              }),
              headers: headers,
            );
          }

        case 'event_list_station':
          // Fetch events from the remote station
          final stationService2 = StationService();
          if (!stationService2.isInitialized) {
            await stationService2.initialize();
          }
          final preferred2 = stationService2.getPreferredStation();
          final station2 = (preferred2 != null && preferred2.url.isNotEmpty)
              ? preferred2
              : stationService2.getConnectedStation();
          if (station2 == null || station2.url.isEmpty) {
            return shelf.Response.internalServerError(
              body: jsonEncode({'success': false, 'error': 'No station configured'}),
              headers: headers,
            );
          }

          var stationUrl = station2.url;
          if (stationUrl.startsWith('wss://')) {
            stationUrl = stationUrl.replaceFirst('wss://', 'https://');
          } else if (stationUrl.startsWith('ws://')) {
            stationUrl = stationUrl.replaceFirst('ws://', 'http://');
          }

          final stationUri = Uri.parse('$stationUrl/api/events');
          final stationResp = await http.get(
            stationUri,
            headers: {'Accept': 'application/json'},
          ).timeout(const Duration(seconds: 30));

          if (stationResp.statusCode != 200) {
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': 'Station returned ${stationResp.statusCode}',
              }),
              headers: headers,
            );
          }

          final stationData = jsonDecode(stationResp.body) as Map<String, dynamic>;
          final eventsList = stationData['events'] as List<dynamic>? ?? [];
          final eventsJson = eventsList.map((e) {
            final m = e as Map<String, dynamic>;
            return {
              'id': m['id'],
              'title': m['title'],
              'author': m['author'],
              'visibility': m['visibility'],
              'timestamp': m['timestamp'],
              'location': m['location'],
            };
          }).toList();

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'station': stationUrl,
              'count': eventsList.length,
              'events': eventsJson,
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown event action: $action',
              'available': ['event_create', 'event_list', 'event_delete', 'event_upload', 'event_list_station'],
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

      void configureBlogStorage(BlogService service, String appPath) {
        final profileStorage = AppService().profileStorage;
        if (profileStorage != null) {
          service.setStorage(
            ScopedProfileStorage.fromAbsolutePath(profileStorage, appPath),
          );
        } else {
          service.setStorage(FilesystemProfileStorage(appPath));
        }
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
          final appPath = '$dataDir/devices/$callsign/$appName';
          configureBlogStorage(blogService, appPath);

          // Initialize the blog directory
          await blogService.initializeApp(appPath, creatorNpub: npub);

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

          // Generate blog URL (relative — station domain prepended by client)
          final url = '/${nickname.toLowerCase()}/blog/${post.id}.html';

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
          final appPath = '$dataDir/devices/$callsign/$appName';
          configureBlogStorage(blogService, appPath);

          // Check if blog directory exists
          final blogDir = io.Directory(appPath);
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

          await blogService.initializeApp(appPath);

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
                'url': '/${nickname.toLowerCase()}/blog/${p.id}.html',
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
          final appPath = '$dataDir/devices/$callsign/$appName';
          configureBlogStorage(blogService, appPath);

          await blogService.initializeApp(appPath);

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

        case 'blog_local_view':
          // Read a post via the same code path the local
          // BlogBrowserPage uses (BlogService.loadFullPostWithFeedback).
          // Reports the counts and comment list as the UI would see
          // them — used to validate that engagement coming in through
          // remote endpoints is visible to the author's own GUI.
          final postId = params['postId'] as String?;
          final appName = params['app_name'] as String? ?? 'blog';
          if (postId == null || postId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'postId is required',
              }),
              headers: headers,
            );
          }
          final service = BlogService();
          final appPath = '$dataDir/devices/$callsign/$appName';
          configureBlogStorage(service, appPath);
          await service.initializeApp(appPath);
          final profile = ProfileService().getProfile();
          final post = await service.loadFullPostWithFeedback(
            postId,
            userNpub: profile.npub.isEmpty ? null : profile.npub,
          );
          if (post == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Post not found'}),
              headers: headers,
            );
          }
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'post': {
                'id': post.id,
                'title': post.title,
                'likes_count': post.likesCount,
                'dislikes_count': post.dislikesCount,
                'points_count': post.pointsCount,
                'subscribe_count': post.subscribeCount,
                'has_liked': post.hasLiked,
                'has_disliked': post.hasDisliked,
                'comment_count': post.comments.length,
                'comments': post.comments
                    .map((c) => {
                          'author': c.author,
                          'timestamp': c.timestamp,
                          'content': c.content,
                          'npub': c.npub,
                        })
                    .toList(),
              },
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
          final appPath = '$dataDir/devices/$callsign/$appName';
          configureBlogStorage(blogService, appPath);

          // Check if the blog post exists
          final blogDir = io.Directory(appPath);
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

          await blogService.initializeApp(appPath);
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

          final url = '/${nickname.toLowerCase()}/blog/${post.id}.html';

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

          // Match the same compact payload shape used by RemoteChatRoomPage
          // to keep BLE message size and server parsing behavior consistent.
          final payload = {
            'callsign': profile.callsign,
            'content': content,
            'npub': profile.npub,
            'pubkey': signedEvent.pubkey,
            'event_id': signedEvent.id,
            'signature': signedEvent.sig,
            'created_at': signedEvent.createdAt,
          };
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

        case 'device_api_request':
          // Generic remote device API request (for transport debugging/automation)
          final callsign = params['callsign'] as String?;
          final path = params['path'] as String?;
          final method = (params['method'] as String? ?? 'GET').toUpperCase();
          final transport = params['transport'] as String? ?? 'all';
          final rawHeaders = params['headers'];
          final rawBody = params['body'];

          if (callsign == null || callsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing callsign parameter',
              }),
              headers: headers,
            );
          }

          if (path == null || path.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing path parameter',
              }),
              headers: headers,
            );
          }

          final normalizedCallsign = callsign.toUpperCase();

          final devicesService = DevicesService();
          final device = devicesService.getDevice(normalizedCallsign);
          if (device == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Device not found: $normalizedCallsign',
              }),
              headers: headers,
            );
          }

          Map<String, String>? requestHeaders;
          if (rawHeaders is Map) {
            requestHeaders = rawHeaders.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            );
          }

          String? requestBody;
          if (rawBody != null) {
            requestBody = rawBody is String ? rawBody : jsonEncode(rawBody);
          }

          devicesService.syncDeviceToConnectionManager(normalizedCallsign);

          final connectionManager = ConnectionManager();
          if (!connectionManager.isInitialized) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'ConnectionManager not initialized',
              }),
              headers: headers,
            );
          }

          // Force specific transport by excluding all others
          final allIds = {
            'lan',
            'ble',
            'dht',
            'peer_relay',
            'station',
            'webrtc',
            'bluetooth_classic',
            'usb_aoa',
          };
          Set<String>? excludeTransports;
          if (transport != 'all') {
            if (!allIds.contains(transport)) {
              return shelf.Response.badRequest(
                body: jsonEncode({
                  'success': false,
                  'error': 'Invalid transport: $transport',
                }),
                headers: headers,
              );
            }
            excludeTransports = allIds.difference({transport});
          }

          final stopwatch = Stopwatch()..start();
          final result = await connectionManager.apiRequest(
            callsign: normalizedCallsign,
            method: method,
            path: path,
            headers: requestHeaders,
            body: requestBody,
            excludeTransports: excludeTransports,
          );
          stopwatch.stop();

          final availableTransportIds = await connectionManager.getAvailableTransports(normalizedCallsign);

          String responseBody = '';
          final responseData = result.responseData;
          if (responseData is String) {
            responseBody = responseData;
          } else if (responseData is List<int>) {
            responseBody = utf8.decode(responseData, allowMalformed: true);
          } else if (responseData != null) {
            responseBody = jsonEncode(responseData);
          }

          dynamic parsedBody;
          try {
            if (responseBody.isNotEmpty) {
              parsedBody = jsonDecode(responseBody);
            }
          } catch (_) {
            parsedBody = null;
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': result.success,
              'callsign': normalizedCallsign,
              'method': method,
              'path': path,
              'transport_requested': transport,
              'transport_used': result.transportUsed,
              'available_transports': availableTransportIds,
              'latency_ms': stopwatch.elapsedMilliseconds,
              'status_code': result.statusCode,
              'error': result.error,
              'body': responseBody,
              if (parsedBody != null) 'parsed_body': parsedBody,
            }),
            headers: headers,
          );

        case 'device_ping':
          final callsign = params['callsign'] as String?;
          if (callsign == null || callsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({'success': false, 'error': 'Missing callsign parameter'}),
              headers: headers,
            );
          }
          final transport = params['transport'] as String? ?? 'all';
          final normalizedCallsign = callsign.toUpperCase();

          final devicesService = DevicesService();
          final device = devicesService.getDevice(normalizedCallsign);
          if (device == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({'success': false, 'error': 'Device not found: $normalizedCallsign'}),
              headers: headers,
            );
          }

          devicesService.syncDeviceToConnectionManager(normalizedCallsign);

          final connectionManager = ConnectionManager();
          if (!connectionManager.isInitialized) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'ConnectionManager not initialized'}),
              headers: headers,
            );
          }

          // Force specific transport by excluding all others
          final allIds = {
            'lan',
            'ble',
            'dht',
            'peer_relay',
            'station',
            'webrtc',
            'bluetooth_classic',
            'usb_aoa',
          };
          Set<String>? excludeTransports;
          if (transport != 'all') {
            excludeTransports = allIds.difference({transport});
          }

          final stopwatch = Stopwatch()..start();
          final result = await connectionManager.apiRequest(
            callsign: normalizedCallsign,
            method: 'GET',
            path: '/api/status',
            excludeTransports: excludeTransports,
          );
          stopwatch.stop();

          final availableTransportIds = await connectionManager.getAvailableTransports(normalizedCallsign);

          return shelf.Response.ok(
            jsonEncode({
              'success': result.success,
              'callsign': normalizedCallsign,
              'transport_requested': transport,
              'transport_used': result.transportUsed,
              'latency_ms': stopwatch.elapsedMilliseconds,
              'available_transports': availableTransportIds,
              'status_code': result.statusCode,
              'error': result.error,
            }),
            headers: headers,
          );

        case 'device_send_dm':
          final callsign = params['callsign'] as String?;
          final content = params['content'] as String?;
          if (callsign == null || callsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({'success': false, 'error': 'Missing callsign parameter'}),
              headers: headers,
            );
          }
          if (content == null || content.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({'success': false, 'error': 'Missing content parameter'}),
              headers: headers,
            );
          }

          final transport = params['transport'] as String? ?? 'all';
          final normalizedCallsign = callsign.toUpperCase();

          final devicesService = DevicesService();
          final device = devicesService.getDevice(normalizedCallsign);
          if (device == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({'success': false, 'error': 'Device not found: $normalizedCallsign'}),
              headers: headers,
            );
          }

          devicesService.syncDeviceToConnectionManager(normalizedCallsign);

          final connectionManager = ConnectionManager();
          if (!connectionManager.isInitialized) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'ConnectionManager not initialized'}),
              headers: headers,
            );
          }

          final profile = ProfileService().getProfile();
          final signingService = SigningService();
          await signingService.initialize();
          if (!signingService.canSign(profile)) {
            return shelf.Response.badRequest(
              body: jsonEncode({'success': false, 'error': 'Cannot sign DM: NOSTR keys not configured'}),
              headers: headers,
            );
          }

          final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final signedEvent = await signingService.generateSignedEvent(
            content,
            {
              'room': normalizedCallsign,
              'callsign': profile.callsign,
            },
            profile,
            createdAt: createdAt,
          );
          if (signedEvent == null || signedEvent.sig == null || signedEvent.id == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({'success': false, 'error': 'Failed to sign DM'}),
              headers: headers,
            );
          }

          final allIds = {
            'lan',
            'ble',
            'dht',
            'peer_relay',
            'station',
            'webrtc',
            'bluetooth_classic',
            'usb_aoa',
          };
          Set<String>? excludeTransports;
          if (transport != 'all') {
            if (!allIds.contains(transport)) {
              return shelf.Response.badRequest(
                body: jsonEncode({'success': false, 'error': 'Invalid transport: $transport'}),
                headers: headers,
              );
            }
            excludeTransports = allIds.difference({transport});
          }

          final message = TransportMessage.directMessage(
            targetCallsign: normalizedCallsign,
            signedEvent: signedEvent.toJson(),
          );

          final stopwatch = Stopwatch()..start();
          final result = await connectionManager.send(
            message,
            excludeTransports: excludeTransports,
          );
          stopwatch.stop();

          final availableTransportIds = await connectionManager.getAvailableTransports(normalizedCallsign);

          return shelf.Response.ok(
            jsonEncode({
              'success': result.success,
              'callsign': normalizedCallsign,
              'transport_requested': transport,
              'transport_used': result.transportUsed,
              'available_transports': availableTransportIds,
              'latency_ms': stopwatch.elapsedMilliseconds,
              'status_code': result.statusCode,
              'error': result.error,
              'event_id': signedEvent.id,
            }),
            headers: headers,
          );

        case 'remote_blog_fetch':
        case 'remote_blog_like':
        case 'remote_blog_dislike':
        case 'remote_blog_point':
        case 'remote_blog_subscribe':
        case 'remote_blog_react':
        case 'remote_blog_comment':
        case 'remote_blog_view':
          return await _handleRemoteBlogAction(action, params, headers);

        case 'remote_content_list':
        case 'remote_content_get':
        case 'remote_event_fetch':
        case 'remote_event_view':
        case 'remote_event_like':
        case 'remote_event_dislike':
        case 'remote_event_comment':
          return await _handleRemoteEventAction(action, params, headers);

        case 'remote_contribution_submit':
        case 'contributor_approve':
        case 'contributor_reject':
        case 'contributor_list_pending':
          return await _handleContributorAction(action, params, headers);

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown device action: $action',
              'available': [
                'device_browse_apps',
                'device_open_detail',
                'device_test_remote_chat',
                'device_send_remote_chat',
                'device_api_request',
                'device_ping',
                'device_send_dm',
                'remote_blog_fetch',
                'remote_blog_like',
                'remote_blog_dislike',
                'remote_blog_point',
                'remote_blog_subscribe',
                'remote_blog_react',
                'remote_blog_comment',
                'remote_blog_view',
              ],
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

  /// Simulates the remote-blog UI panel actions via debug API.
  /// Exercises the exact same code path the GUI takes — signs NOSTR
  /// events locally, POSTs through DevicesService (ConnectionManager),
  /// and returns the server's reply plus a re-fetched post snapshot
  /// so tests can verify the new counts.
  Future<shelf.Response> _handleRemoteBlogAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    final callsign = (params['callsign'] as String?)?.trim();
    final postId = (params['postId'] as String?)?.trim();
    if (callsign == null || callsign.isEmpty ||
        postId == null || postId.isEmpty) {
      return shelf.Response.badRequest(
        body: jsonEncode({
          'success': false,
          'error': 'callsign and postId are required',
        }),
        headers: headers,
      );
    }

    RemoteBlogActionResult result;
    switch (action) {
      case 'remote_blog_fetch':
        result = await RemoteBlogActions.fetchDetail(
          remoteCallsign: callsign, postId: postId);
        break;
      case 'remote_blog_like':
        result = await RemoteBlogActions.sendFeedback(
          remoteCallsign: callsign,
          postId: postId,
          feedbackType: FeedbackFolderUtils.feedbackTypeLikes,
          actionName: 'like',
          authorNpub: params['authorNpub'] as String?,
        );
        break;
      case 'remote_blog_dislike':
        result = await RemoteBlogActions.sendFeedback(
          remoteCallsign: callsign,
          postId: postId,
          feedbackType: FeedbackFolderUtils.feedbackTypeDislikes,
          actionName: 'dislike',
          authorNpub: params['authorNpub'] as String?,
        );
        break;
      case 'remote_blog_point':
        result = await RemoteBlogActions.sendFeedback(
          remoteCallsign: callsign,
          postId: postId,
          feedbackType: FeedbackFolderUtils.feedbackTypePoints,
          actionName: 'point',
          authorNpub: params['authorNpub'] as String?,
        );
        break;
      case 'remote_blog_subscribe':
        result = await RemoteBlogActions.sendFeedback(
          remoteCallsign: callsign,
          postId: postId,
          feedbackType: FeedbackFolderUtils.feedbackTypeSubscribe,
          actionName: 'subscribe',
          authorNpub: params['authorNpub'] as String?,
        );
        break;
      case 'remote_blog_react':
        final emoji = (params['emoji'] as String?)?.trim();
        if (emoji == null || emoji.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'emoji is required for remote_blog_react',
            }),
            headers: headers,
          );
        }
        result = await RemoteBlogActions.sendFeedback(
          remoteCallsign: callsign,
          postId: postId,
          feedbackType: emoji,
          actionName: 'reaction',
          authorNpub: params['authorNpub'] as String?,
        );
        break;
      case 'remote_blog_comment':
        final content = (params['content'] as String?)?.trim();
        if (content == null || content.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'content is required for remote_blog_comment',
            }),
            headers: headers,
          );
        }
        result = await RemoteBlogActions.sendComment(
          remoteCallsign: callsign,
          postId: postId,
          content: content,
        );
        break;
      case 'remote_blog_view':
        result = await RemoteBlogActions.recordView(
          remoteCallsign: callsign, postId: postId);
        break;
      default:
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Unsupported action: $action',
          }),
          headers: headers,
        );
    }

    // Re-fetch the post so the caller sees the new counts without
    // another round-trip — this is what the UI does after every
    // write. Skip when the action itself was a fetch.
    Map<String, dynamic>? after;
    if (action != 'remote_blog_fetch') {
      final refresh = await RemoteBlogActions.fetchDetail(
        remoteCallsign: callsign, postId: postId);
      if (refresh.success && refresh.body != null) {
        after = {
          'likes_count': refresh.body!['likes_count'],
          'dislikes_count': refresh.body!['dislikes_count'],
          'points_count': refresh.body!['points_count'],
          'subscribe_count': refresh.body!['subscribe_count'],
          'view_count': refresh.body!['view_count'],
          'comment_count': refresh.body!['comment_count'],
        };
      }
    }

    return shelf.Response.ok(
      jsonEncode({
        ...result.toJson(),
        if (after != null) 'post_snapshot': after,
      }),
      headers: headers,
    );
  }

  /// Drives the remote-events / generic-content panel via debug
  /// API. Exercises the same code path the UI uses
  /// ([RemoteContent] for reads, [RemoteEventActions] for writes)
  /// so tests can prove the button works without a human tap.
  Future<shelf.Response> _handleRemoteEventAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    final callsign = (params['callsign'] as String?)?.trim();
    if (callsign == null || callsign.isEmpty) {
      return shelf.Response.badRequest(
        body: jsonEncode({
          'success': false,
          'error': 'callsign is required',
        }),
        headers: headers,
      );
    }

    Object result;
    switch (action) {
      case 'remote_content_list':
        final appType = (params['appType'] as String?)?.trim();
        if (appType == null || appType.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'appType is required',
            }),
            headers: headers,
          );
        }
        final query = <String, String>{};
        final q = params['query'];
        if (q is Map) {
          q.forEach((k, v) {
            if (k is String && v != null) query[k] = v.toString();
          });
        }
        final r = await RemoteContent.list(
          remoteCallsign: callsign,
          appType: appType,
          query: query.isEmpty ? null : query,
        );
        result = r.toJson();
        break;
      case 'remote_content_get':
        final appType = (params['appType'] as String?)?.trim();
        final itemId = (params['itemId'] as String?)?.trim();
        if (appType == null || appType.isEmpty ||
            itemId == null || itemId.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'appType and itemId are required',
            }),
            headers: headers,
          );
        }
        final r = await RemoteContent.get(
          remoteCallsign: callsign,
          appType: appType,
          itemId: itemId,
        );
        result = r.toJson();
        break;
      case 'remote_event_fetch':
        final eventId = (params['eventId'] as String? ??
                params['postId'] as String?)
            ?.trim();
        if (eventId == null || eventId.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'eventId is required',
            }),
            headers: headers,
          );
        }
        final r = await RemoteContent.get(
          remoteCallsign: callsign,
          appType: 'events',
          itemId: eventId,
        );
        result = r.toJson();
        break;
      case 'remote_event_view':
      case 'remote_event_like':
      case 'remote_event_dislike':
      case 'remote_event_comment':
        final eventId = (params['eventId'] as String? ??
                params['postId'] as String?)
            ?.trim();
        if (eventId == null || eventId.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'eventId is required',
            }),
            headers: headers,
          );
        }
        RemoteEventActionResult write;
        switch (action) {
          case 'remote_event_view':
            write = await RemoteEventActions.recordView(
              remoteCallsign: callsign, eventId: eventId);
            break;
          case 'remote_event_like':
            write = await RemoteEventActions.like(
              remoteCallsign: callsign,
              eventId: eventId,
              authorNpub: params['authorNpub'] as String?,
            );
            break;
          case 'remote_event_dislike':
            write = await RemoteEventActions.dislike(
              remoteCallsign: callsign,
              eventId: eventId,
              authorNpub: params['authorNpub'] as String?,
            );
            break;
          case 'remote_event_comment':
            final content = (params['content'] as String?)?.trim();
            if (content == null || content.isEmpty) {
              return shelf.Response.badRequest(
                body: jsonEncode({
                  'success': false,
                  'error': 'content is required for remote_event_comment',
                }),
                headers: headers,
              );
            }
            write = await RemoteEventActions.sendComment(
              remoteCallsign: callsign,
              eventId: eventId,
              content: content,
            );
            break;
          default:
            write = const RemoteEventActionResult(
                success: false, error: 'unreachable');
        }
        // Fetch the updated detail so callers can verify deltas
        // the same way remote_blog_* does.
        final after = await RemoteContent.get(
          remoteCallsign: callsign,
          appType: 'events',
          itemId: eventId,
        );
        result = {
          ...write.toJson(),
          if (after.success && after.data != null)
            'post_snapshot': {
              'view_count': after.data!['view_count'],
              'like_count': after.data!['like_count'],
              'dislike_count': after.data!['dislikes_count'],
              'comment_count': after.data!['comment_count'],
            },
        };
        break;
      default:
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Unsupported action: $action',
          }),
          headers: headers,
        );
    }

    return shelf.Response.ok(jsonEncode(result), headers: headers);
  }

  // ============================================================
  // Debug API - Contributor Debug Actions
  // ============================================================

  /// Drives the visitor-side submission end-to-end from the local
  /// device so tests can prove the flow without a human picking
  /// files in the UI. Signs with the active profile's nsec and hits
  /// the target device via ConnectionManager.
  ///
  /// Actions:
  ///   remote_contribution_submit  — sign + POST one file to a
  ///       remote device's event
  ///   event_contributor_approve   — move a pending contributor on
  ///       the LOCAL device to the approved folder (author action)
  ///   event_contributor_reject    — delete a pending contributor
  ///       on the LOCAL device
  ///   event_contributors_pending  — list pending contributors on
  ///       the local device (author inspection)
  Future<shelf.Response> _handleContributorAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final storage = contentBrowseStorage;
      if (action == 'contributor_list_pending') {
        final eventId = (params['eventId'] as String?)?.trim();
        if (eventId == null || eventId.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({'success': false, 'error': 'eventId required'}),
            headers: headers,
          );
        }
        final eventPath = await _resolveLocalEventPath(storage, eventId);
        if (eventPath == null) {
          return shelf.Response.notFound(
            jsonEncode({'success': false, 'error': 'Event not found'}),
            headers: headers,
          );
        }
        final callsigns = await ContributorFolderUtils.listPendingCallsigns(
            eventPath: eventPath, storage: storage);
        final pending = <Map<String, dynamic>>[];
        for (final cs in callsigns) {
          final folder =
              ContributorFolderUtils.pendingFolder(eventPath, cs);
          final files = await ContributorFolderUtils.listMediaFiles(
              folderPath: folder, storage: storage);
          final meta = await ContributorFolderUtils.readMeta(
              folderPath: folder, storage: storage);
          pending.add({
            'callsign': cs,
            'files': files,
            if (meta?.npub != null) 'npub': meta!.npub,
            if (meta?.created.isNotEmpty == true) 'created': meta!.created,
            if (meta?.description.isNotEmpty == true)
              'description': meta!.description,
          });
        }
        return shelf.Response.ok(
          jsonEncode({'success': true, 'pending': pending}),
          headers: headers,
        );
      }

      if (action == 'contributor_approve' ||
          action == 'contributor_reject') {
        final eventId = (params['eventId'] as String?)?.trim();
        final callsign = (params['callsign'] as String?)?.trim().toUpperCase();
        if (eventId == null || eventId.isEmpty || callsign == null ||
            callsign.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode(
                {'success': false, 'error': 'eventId + callsign required'}),
            headers: headers,
          );
        }
        final eventPath = await _resolveLocalEventPath(storage, eventId);
        if (eventPath == null) {
          return shelf.Response.notFound(
            jsonEncode({'success': false, 'error': 'Event not found'}),
            headers: headers,
          );
        }
        final applied = action == 'contributor_approve'
            ? await ContributorFolderUtils.approve(
                eventPath: eventPath, callsign: callsign, storage: storage)
            : await ContributorFolderUtils.reject(
                eventPath: eventPath, callsign: callsign, storage: storage);
        return shelf.Response.ok(
          jsonEncode({
            'success': applied,
            'action': action,
            'callsign': callsign,
          }),
          headers: headers,
        );
      }

      // remote_contribution_submit: sign + POST to a remote device.
      final remoteCallsign = (params['callsign'] as String?)?.trim();
      final eventId = (params['eventId'] as String?)?.trim();
      final filename = (params['filename'] as String?)?.trim();
      final sourcePath = (params['sourcePath'] as String?)?.trim();
      if (remoteCallsign == null || remoteCallsign.isEmpty ||
          eventId == null || eventId.isEmpty ||
          filename == null || filename.isEmpty ||
          sourcePath == null || sourcePath.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'callsign + eventId + filename + sourcePath required',
          }),
          headers: headers,
        );
      }
      final file = io.File(sourcePath);
      if (!await file.exists()) {
        return shelf.Response.notFound(
          jsonEncode({'success': false, 'error': 'sourcePath not found'}),
          headers: headers,
        );
      }
      final bytes = await file.readAsBytes();
      final profile = ProfileService().getProfile();
      final nsec = profile.nsec;
      final npub = profile.npub;
      if (nsec.isEmpty || npub.isEmpty) {
        return shelf.Response.internalServerError(
          body: jsonEncode({
            'success': false,
            'error': 'Local profile has no NOSTR identity',
          }),
          headers: headers,
        );
      }
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final pubkeyHex = NostrCrypto.decodeNpub(npub);
      final fileHash = crypto.sha256.convert(bytes).toString();
      final ev = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: createdAt,
        kind: NostrEventKind.textNote,
        tags: [
          ['e', eventId],
          ['f', filename],
          ['callsign', profile.callsign],
          ['kind', 'event_contribution'],
        ],
        content: fileHash,
      );
      ev.calculateId();
      final signature = ev.signWithNsec(nsec);

      final resp = await DevicesService().makeDeviceApiRequest(
        callsign: remoteCallsign,
        method: 'POST',
        path: '/api/events/${Uri.encodeComponent(eventId)}'
            '/contributors/${Uri.encodeComponent(profile.callsign)}'
            '/submit/${Uri.encodeComponent(filename)}',
        headers: {
          'Content-Type': 'application/octet-stream',
          'X-Nostr-Npub': npub,
          'X-Nostr-Signature': signature,
          'X-Nostr-Timestamp': createdAt.toString(),
        },
        bodyBytes: bytes,
      );
      if (resp == null) {
        return shelf.Response.ok(
          jsonEncode({
            'success': false,
            'error': 'Transport unavailable or request failed',
          }),
          headers: headers,
        );
      }
      Map<String, dynamic>? body;
      try {
        body = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {}
      return shelf.Response.ok(
        jsonEncode({
          'success': resp.statusCode == 200,
          'status_code': resp.statusCode,
          'response': body ?? resp.body,
        }),
        headers: headers,
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  Future<String?> _resolveLocalEventPath(
      ProfileStorage storage, String eventId) async {
    try {
      final entries = await storage.listDirectory('events', recursive: true);
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        if (!entry.name.endsWith('event.txt')) continue;
        final parts = entry.path.split('/');
        final idIdx = parts.lastIndexOf('event.txt') - 1;
        if (idIdx < 0) continue;
        if (parts[idIdx] != eventId) continue;
        return entry.path.replaceAll(RegExp(r'/event\.txt$'), '');
      }
    } catch (_) {}
    return null;
  }

  // ============================================================
  // Debug API - Transfer Debug Actions
  // ============================================================

  Future<shelf.Response> _handleTransferAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      switch (action) {
        case 'transfer_http_download':
          final remoteUrl = params['remote_url'] as String?;
          final localPath =
              (params['local_path'] as String?) ?? '/tmp/transfer-debug.bin';
          final expectedBytes = params['expected_bytes'] as int?;

          if (remoteUrl == null || remoteUrl.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'error': 'Missing remote_url',
                'usage':
                    '{"action":"transfer_http_download","remote_url":"http://example.com/file.bin","local_path":"/tmp/file.bin"}',
              }),
              headers: headers,
            );
          }

          final svc = TransferService();
          if (!svc.isInitialized) {
            await svc.initialize();
          }

          final transfer = await svc.requestDownload(
            TransferRequest(
              direction: TransferDirection.download,
              callsign: 'http',
              remotePath: Uri.parse(remoteUrl).path,
              remoteUrl: remoteUrl,
              localPath: localPath,
              expectedBytes: expectedBytes,
              requestingApp: 'debug-api',
              metadata: {'debug': true},
            ),
          );

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'transfer_id': transfer.id,
              'local_path': transfer.localPath,
              'remote_url': remoteUrl,
            }),
            headers: headers,
          );
      }

      return shelf.Response.badRequest(
        body: jsonEncode({
          'error': 'Unknown transfer action',
          'action': action,
          'supported': ['transfer_http_download'],
        }),
        headers: headers,
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Transfer debug action error: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Debug API - Contact Debug Actions
  // ============================================================

  /// Handle contact debug actions
  Future<shelf.Response> _handleContactDebugAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    if (action == 'contact_debug') {
      try {
        // Get data directory from StorageConfig
        String? dataDir;
        try {
          dataDir = StorageConfig().baseDir;
        } catch (e) {
          return shelf.Response.ok(
            jsonEncode({'error': 'Storage not initialized: $e'}),
            headers: headers,
          );
        }

        // Get callsign from profile
        String callsign = 'unknown';
        try {
          final profile = ProfileService().getProfile();
          callsign = profile.callsign;
        } catch (e) {
          // Profile not initialized
        }

        // Build collection path pattern
        final appPath = '$dataDir/devices/$callsign';

        final result = <String, dynamic>{
          'action': 'contact_debug',
          'dataDir': dataDir,
          'callsign': callsign,
          'appPath': appPath,
        };

        // Check fast.json
        final fastJsonPath = '$appPath/contacts/fast.json';
        final fastJsonFile = io.File(fastJsonPath);
        result['fastJsonPath'] = fastJsonPath;
        result['fastJsonExists'] = await fastJsonFile.exists();

        if (await fastJsonFile.exists()) {
          final content = await fastJsonFile.readAsString();
          final jsonList = jsonDecode(content) as List<dynamic>;
          result['fastJsonCount'] = jsonList.length;
          result['fastJsonContacts'] = jsonList.take(5).map((c) => {
            'callsign': c['callsign'],
            'displayName': c['displayName'],
            'filePath': c['filePath'],
          }).toList();
        }

        // Check contacts directory
        final contactsDir = io.Directory('$appPath/contacts');
        result['contactsDirExists'] = await contactsDir.exists();

        // List contact files if directory exists
        if (await contactsDir.exists()) {
          final entities = await contactsDir.list().toList();
          final txtFiles = entities
              .whereType<io.File>()
              .where((f) => f.path.endsWith('.txt'))
              .take(10)
              .map((f) => path.basename(f.path))
              .toList();
          result['contactFiles'] = txtFiles;
        }

        // If callsign provided, check specific contact
        final targetCallsign = params['callsign'] as String?;
        if (targetCallsign != null) {
          final contactFile = io.File('$appPath/contacts/$targetCallsign.txt');
          result['targetCallsign'] = targetCallsign;
          result['contactFilePath'] = contactFile.path;
          result['contactFileExists'] = await contactFile.exists();
          if (await contactFile.exists()) {
            final fileContent = await contactFile.readAsString();
            result['contactFileSize'] = fileContent.length;
            result['contactFilePreview'] = fileContent.substring(0, fileContent.length > 200 ? 200 : fileContent.length);
          }
        }

        return shelf.Response.ok(jsonEncode(result), headers: headers);
      } catch (e, stack) {
        return shelf.Response.ok(
          jsonEncode({'error': e.toString(), 'stack': stack.toString()}),
          headers: headers,
        );
      }
    }

    return shelf.Response.badRequest(
      body: jsonEncode({'error': 'Unknown contact action: $action'}),
      headers: headers,
    );
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
          final apiPort = port;

          final stationConfig =
              (ConfigService().get('stationServer') as Map?)?.cast<String, dynamic>();
          if (stationConfig != null && stationConfig['enabled'] == true) {
            ConfigService().set('stationServer', {
              ...stationConfig,
              'enabled': false,
            });
          }

          // Initialize if needed
          await stationServer.initialize();

          // The debug API already occupies the app API port, so use a
          // dedicated station port by default when the station config still
          // points at the API listener.
          if (!stationServer.isRunning && stationServer.settings.port == apiPort) {
            final updatedSettings = StationServerSettings.fromJson(
              stationServer.settings.toJson(),
            );
            updatedSettings.port = apiPort + 1;
            await stationServer.updateSettings(updatedSettings);
          }

          // Start the server. The service begins accepting connections before
          // slower post-bind setup finishes, so avoid blocking the debug API on
          // model downloads and other non-essential startup work.
          final success = await stationServer.start().timeout(
                const Duration(seconds: 5),
                onTimeout: () => stationServer.isRunning,
              );
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

        case 'chat_post_local':
          // Create a local chat message through ChatService so station activity
          // publishing follows the same path as normal client usage.
          final room = params['room'] as String? ?? 'main';
          final content = params['content'] as String?;
          if (content == null || content.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'content is required',
              }),
              headers: headers,
            );
          }

          final initialized = await _initializeChatServiceIfNeeded(
            createIfMissing: true,
          );
          if (!initialized) {
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': 'Chat service not available',
              }),
              headers: headers,
            );
          }

          final chatService = ChatService();
          final channel = chatService.getChannel(room);
          if (channel == null) {
            return shelf.Response.notFound(
              jsonEncode({
                'success': false,
                'error': 'Room not found',
                'room': room,
              }),
              headers: headers,
            );
          }

          final profile = ProfileService().getProfile();
          final message = ChatMessage.now(
            author: profile.callsign,
            content: content,
            metadata: {
              if (profile.npub.isNotEmpty) 'npub': profile.npub,
            },
          );

          await chatService.saveMessage(room, message);

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Local chat message created',
              'room': room,
              'timestamp': message.timestamp,
              'author': message.author,
              'content': message.content,
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
          final result = await stationService.postRoomMessage(
            preferred.url,
            room,
            profile.callsign,
            content,
            metadata: metadata.isNotEmpty ? metadata : null,
          );

          if (result.sent) {
            logs.add('Message sent successfully, created_at: ${result.createdAt}');
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'message': 'Message sent successfully',
                'room': room,
                'content': content,
                'metadata': metadata,
                'created_at': result.createdAt,
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

        case 'station_delete_chat':
          // Delete a chat message from a station room
          final room = params['room'] as String? ?? 'general';
          final timestamp = params['timestamp'] as String?;
          final eventId = params['event_id'] as String?;
          final useLocal = params['local'] == true || params['local'] == 'true';

          if (timestamp == null || timestamp.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'timestamp is required (e.g. "2026-02-18 19:47_53")',
              }),
              headers: headers,
            );
          }

          final deleteLogs = <String>[];

          if (useLocal) {
            // Delete from local station directly (no NOSTR auth needed for testing)
            deleteLogs.add('Mode: local (direct ChatService)');
            deleteLogs.add('Room: $room');
            deleteLogs.add('Timestamp: $timestamp');

            try {
              await _initializeChatServiceIfNeeded();
              final chatService = ChatService();
              final message = await chatService.findMessage(room, timestamp);
              if (message == null) {
                deleteLogs.add('ERROR: Message not found');
                return shelf.Response.ok(
                  jsonEncode({
                    'success': false,
                    'message': 'Message not found at $timestamp',
                    'logs': deleteLogs,
                  }),
                  headers: headers,
                );
              }
              deleteLogs.add('Found message by ${message.author}: ${message.content}');
              await chatService.deleteMessageByTimestamp(
                channelId: room,
                timestamp: timestamp,
                authorCallsign: message.author,
                actorNpub: message.npub ?? '',
              );
              deleteLogs.add('Deleted successfully');
              return shelf.Response.ok(
                jsonEncode({
                  'success': true,
                  'message': 'Message deleted (local)',
                  'room': room,
                  'timestamp': timestamp,
                  'deleted_author': message.author,
                  'deleted_content': message.content,
                  'logs': deleteLogs,
                }),
                headers: headers,
              );
            } catch (e) {
              deleteLogs.add('ERROR: $e');
              return shelf.Response.ok(
                jsonEncode({
                  'success': false,
                  'message': 'Local delete failed: $e',
                  'logs': deleteLogs,
                }),
                headers: headers,
              );
            }
          }

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

          deleteLogs.add('Station URL: ${preferred.url}');
          deleteLogs.add('Room: $room');
          deleteLogs.add('Timestamp: $timestamp');
          if (eventId != null) deleteLogs.add('Event ID: $eventId');

          final deleteResult = await stationService.deleteRoomMessage(
            preferred.url,
            room,
            timestamp,
            eventId: eventId,
          );

          deleteLogs.add('Result: $deleteResult');

          return shelf.Response.ok(
            jsonEncode({
              'success': deleteResult,
              'message': deleteResult ? 'Message deleted' : 'Failed to delete message',
              'room': room,
              'timestamp': timestamp,
              'event_id': eventId,
              'logs': deleteLogs,
            }),
            headers: headers,
          );

        case 'station_edit_chat':
          // Edit a chat message in a station room
          final room = params['room'] as String? ?? 'general';
          final timestamp = params['timestamp'] as String?;
          final content = params['content'] as String?;
          final eventId = params['event_id'] as String?;

          if (timestamp == null || timestamp.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'timestamp is required (e.g. "2026-02-18 19:47_53")',
              }),
              headers: headers,
            );
          }
          if (content == null || content.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'content is required (the new message text)',
              }),
              headers: headers,
            );
          }

          final preferredStation = stationService.getPreferredStation();
          if (preferredStation == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'No preferred station configured. Use station_set first.',
              }),
              headers: headers,
            );
          }

          final editResult = await stationService.editRoomMessage(
            preferredStation.url,
            room,
            timestamp,
            content,
            eventId: eventId,
          );

          return shelf.Response.ok(
            jsonEncode({
              'success': editResult,
              'message': editResult ? 'Message edited' : 'Failed to edit message',
              'room': room,
              'timestamp': timestamp,
              'content': content,
            }),
            headers: headers,
          );

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
                'chat_post_local',
                'station_send_chat',
                'station_delete_chat',
                'station_edit_chat',
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

      // Actions that don't require a placeId
      if (action == 'place_create') {
        return _handlePlaceCreate(params, headers, dataDir, defaultCallsign, defaultNpub);
      }
      if (action == 'place_list_station') {
        return _handlePlaceListStation(headers);
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
      ProfileStorage? placeStorage;
      if (placePathParam != null && placePathParam.isNotEmpty) {
        // Convert absolute place_path to relative path + storage
        // placePathParam may be a file (place.txt) or directory
        // The device dir is: $dataDir/devices/$callsign
        final cs = callsign ?? defaultCallsign ?? '';
        final deviceBase = '$dataDir/devices/$cs';
        final storage = FilesystemProfileStorage(deviceBase);
        final normalizedParam = path.normalize(placePathParam);
        final normalizedBase = path.normalize(deviceBase);

        String absPath = normalizedParam;
        // If it's a file path (e.g., place.txt), use parent directory
        if (normalizedParam.endsWith('place.txt') || normalizedParam.endsWith('.txt')) {
          absPath = path.dirname(normalizedParam);
        }

        // Convert absolute path to relative
        if (absPath.startsWith(normalizedBase)) {
          var relPath = absPath.substring(normalizedBase.length);
          while (relPath.startsWith('/') || relPath.startsWith('\\')) {
            relPath = relPath.substring(1);
          }
          while (relPath.endsWith('/') || relPath.endsWith('\\')) {
            relPath = relPath.substring(0, relPath.length - 1);
          }
          if (await storage.directoryExists(relPath)) {
            placePath = relPath;
            placeStorage = storage;
          }
        }

        if (placePath == null) {
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'place_path not found',
              'place_path': placePathParam,
            }),
            headers: headers,
          );
        }
      } else {
        final resolved = await _resolvePlacePath(dataDir, placeId, callsign: callsign);
        if (resolved != null) {
          placePath = resolved.$1;
          placeStorage = resolved.$2;
        }
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
          if (placePath != null && placePath.isNotEmpty && placeStorage != null) {
            if (liked) {
              await FeedbackFolderUtils.addFeedbackEvent(
                placePath,
                FeedbackFolderUtils.feedbackTypeLikes,
                event,
                storage: placeStorage,
              );
            } else {
              await FeedbackFolderUtils.removeFeedbackEvent(
                placePath,
                FeedbackFolderUtils.feedbackTypeLikes,
                event.npub,
                storage: placeStorage,
              );
            }

            final localNpubs = await FeedbackFolderUtils.readFeedbackFile(
              placePath,
              FeedbackFolderUtils.feedbackTypeLikes,
              storage: placeStorage,
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
          if (placePath != null && placePath.isNotEmpty && placeStorage != null) {
            commentId = await FeedbackCommentUtils.writeComment(
              contentPath: placePath,
              author: author,
              content: content,
              npub: npub,
              signature: signature,
              storage: placeStorage,
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

        case 'place_delete':
          if (placePath == null || placeStorage == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Place not found locally',
                'place_id': placeId,
              }),
              headers: headers,
            );
          }
          await placeStorage.deleteDirectory(placePath, recursive: true);
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'deleted_path': placePath,
              'place_id': placeId,
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown place action: $action',
              'available': ['place_create', 'place_list_station', 'place_delete', 'place_like', 'place_comment'],
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

  Future<(String, ProfileStorage)?> _resolvePlacePath(
    String dataDir,
    String folderName, {
    String? callsign,
  }) async {
    Future<(String, ProfileStorage)?> searchCallsign(String cs) async {
      final storage = FilesystemProfileStorage('$dataDir/devices/$cs');
      if (!await storage.directoryExists('places')) return null;

      final entries = await storage.listDirectory('places', recursive: true);
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        if (!entry.name.endsWith('place.txt')) continue;

        // entry.path is like "places/region/folder-name/place.txt"
        // We want the parent directory path: "places/region/folder-name"
        final parentPath = entry.path.contains('/')
            ? entry.path.substring(0, entry.path.lastIndexOf('/'))
            : entry.path.contains('\\')
                ? entry.path.substring(0, entry.path.lastIndexOf('\\'))
                : '';
        final parentName = parentPath.split('/').last.split('\\').last;
        if (parentName == folderName) {
          return (parentPath, storage);
        }
      }
      return null;
    }

    if (callsign != null && callsign.isNotEmpty) {
      return searchCallsign(callsign);
    }

    final devicesDir = io.Directory('$dataDir/devices');
    if (!await devicesDir.exists()) return null;

    await for (final deviceEntity in devicesDir.list()) {
      if (deviceEntity is! io.Directory) continue;
      final deviceCallsign = path.basename(deviceEntity.path);
      final match = await searchCallsign(deviceCallsign);
      if (match != null) return match;
    }

    return null;
  }

  /// Handle place_create debug action
  Future<shelf.Response> _handlePlaceCreate(
    Map<String, dynamic> params,
    Map<String, String> headers,
    String dataDir,
    String? defaultCallsign,
    String? defaultNpub,
  ) async {
    final callsign = params['callsign'] as String? ?? defaultCallsign;
    if (callsign == null || callsign.isEmpty) {
      return shelf.Response.badRequest(
        body: jsonEncode({'success': false, 'error': 'No callsign available'}),
        headers: headers,
      );
    }

    final name = params['name'] as String? ?? 'Debug Test Place';
    final latitude = (params['latitude'] as num?)?.toDouble() ?? 38.7223;
    final longitude = (params['longitude'] as num?)?.toDouble() ?? -9.1393;
    final radius = (params['radius'] as num?)?.toInt() ?? 100;
    final description = params['description'] as String? ?? '';
    final type = params['type'] as String?;
    final visibility = params['visibility'] as String? ?? 'public';
    final upload = params['upload'] != false; // default true

    final now = DateTime.now();
    final created = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}_'
        '${now.second.toString().padLeft(2, '0')}';

    final place = Place(
      name: name,
      created: created,
      author: callsign,
      latitude: latitude,
      longitude: longitude,
      radius: radius,
      description: description,
      type: type,
      visibility: visibility,
      metadataNpub: defaultNpub,
    );

    final deviceBase = '$dataDir/devices/$callsign';
    final storage = FilesystemProfileStorage(deviceBase);
    PlaceService().setStorage(storage);
    await PlaceService().initializeApp('places');

    final saveError = await PlaceService().savePlace(place);
    if (saveError != null) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': saveError}),
        headers: headers,
      );
    }

    final relativeFolderPath = await PlaceService().getPlaceFolderPath(place);
    final placeId = place.placeFolderName;
    int uploadedCount = 0;

    if (upload && relativeFolderPath != null) {
      final absoluteFolderPath = path.join(deviceBase, relativeFolderPath);
      final updatedPlace = place.copyWith(folderPath: absoluteFolderPath);
      final placesBase = path.join(deviceBase, 'places');
      uploadedCount = await PlaceSharingService().uploadPlaceToStations(
        updatedPlace,
        placesBase,
      );
    }

    return shelf.Response.ok(
      jsonEncode({
        'success': true,
        'place_id': placeId,
        'place_name': name,
        'folder_path': relativeFolderPath,
        'uploaded_count': uploadedCount,
      }),
      headers: headers,
    );
  }

  /// Handle place_list_station debug action
  Future<shelf.Response> _handlePlaceListStation(
    Map<String, String> headers,
  ) async {
    final result = await StationPlaceService().fetchPlaces();
    if (!result.success) {
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': result.error ?? 'Failed to fetch places from station',
        }),
        headers: headers,
      );
    }

    final placesJson = result.places.map((entry) => {
      'name': entry.place.name,
      'author': entry.place.author,
      'latitude': entry.place.latitude,
      'longitude': entry.place.longitude,
      'type': entry.place.type,
      'callsign': entry.callsign,
      'relativePath': entry.relativePath,
    }).toList();

    return shelf.Response.ok(
      jsonEncode({
        'success': true,
        'count': result.places.length,
        'places': placesJson,
      }),
      headers: headers,
    );
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

          final reportService = ReportService();
          final appPath = '$dataDir/devices/$callsign/alerts';
          final profileStorage = AppService().profileStorage;
          final reportStorage = profileStorage != null
              ? ScopedProfileStorage.fromAbsolutePath(profileStorage, appPath)
              : FilesystemProfileStorage(appPath);
          reportService.setStorage(reportStorage);
          await reportService.initializeApp(appPath);

          var report = await reportService.createReport(
            title: title,
            description: description,
            author: callsign,
            latitude: latitude,
            longitude: longitude,
            severity: reportSeverity,
            type: type,
          );

          if (reportStatus != ReportStatus.open) {
            report = report.copyWith(status: reportStatus);
            await reportService.saveReport(
              report,
              notifyRelays: false,
              updateLastModified: false,
            );
          }

          final reportRelativePath =
              'active/${report.regionFolder}/${report.folderName}';
          final alertPath = await reportStorage.getAbsolutePath(reportRelativePath);

          final includePhoto = params['photo'] == true || params['photo'] == 'true';
          String? createdPhotoPath;

          if (includePhoto) {
            await reportStorage.createDirectory('$reportRelativePath/images');

            // Use sequential naming: photo1.png
            final photoRelativePath = '$reportRelativePath/images/photo1.png';

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

            await reportStorage.writeBytes(photoRelativePath, pngBytes);
            createdPhotoPath = await reportStorage.getAbsolutePath(photoRelativePath);

            LogService().log('LogApiService: Created test photo at $createdPhotoPath');
          }

          LogService().log('LogApiService: Created test alert: ${report.apiId}');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Alert created${includePhoto ? " with photo" : ""}',
              'alert_id': report.apiId,
              'folder_name': report.folderName,
              'alert': report.toApiJson(),
              'photo_created': includePhoto,
              'photo_path': createdPhotoPath,
              'alert_path': alertPath,
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
            // alertPath is absolute from _getAllAlertsGlobal
            final alertDirStorage = FilesystemProfileStorage(alertPath);
            final hasPhotos = await _alertHasPhotos('', alertDirStorage);
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
          final deleteStorage = result.$3;

          if (await deleteStorage.directoryExists(alertPath)) {
            await deleteStorage.deleteDirectory(alertPath, recursive: true);
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
          final pointStorage = pointResult.$3;

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

          final pointedBy = await AlertFolderUtils.readPointsFile(alertPathForPoint, storage: pointStorage);
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
            storage: pointStorage,
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
          final reportPathForPoint = '$alertPathForPoint/report.txt';
          final existingReportForPoint = await pointStorage.readString(reportPathForPoint);
          if (existingReportForPoint != null) {
            var content = existingReportForPoint;
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
            await pointStorage.writeString(reportPathForPoint, content);
          }

          final updatedPointedBy = await AlertFolderUtils.readPointsFile(alertPathForPoint, storage: pointStorage);
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
          final verifyStorage = verifyResult.$3;

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
            storage: verifyStorage,
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

          await verifyStorage.writeString('$alertPathForVerify/report.txt', updatedVerifyAlert.exportAsText());

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
          final commentStorage = commentResult.$3;

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
            storage: commentStorage,
          );

          final commentFilePath = '${FeedbackFolderUtils.buildCommentsPath(alertPathForComment)}/$commentId.txt';
          String createdStr = '';
          try {
            final commentContent = await commentStorage.readString(commentFilePath);
            if (commentContent != null) {
              final parsed = FeedbackCommentUtils.parseCommentFile(commentContent, commentId);
              createdStr = parsed.created;
            }
          } catch (_) {
            final now = DateTime.now();
            createdStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';
          }

          final reportPathForComment = '$alertPathForComment/report.txt';
          final existingReportForComment = await commentStorage.readString(reportPathForComment);
          if (existingReportForComment != null) {
            var reportContent = existingReportForComment;
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
            await commentStorage.writeString(reportPathForComment, reportContent);
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
            // Stream download to file to avoid buffering large images in memory
            try {
              final result = await streamDownloadToFile(
                Uri.parse(imageUrl),
                photoPath,
                maxBytes: 50 * 1024 * 1024,
              );
              if (result.success) {
                LogService().log('LogApiService: Downloaded photo from $imageUrl to $photoPath');
              } else {
                return shelf.Response.internalServerError(
                  body: jsonEncode({
                    'success': false,
                    'error': 'Failed to download image',
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
          final alertPathForShare = shareResult.$2;
          // ignore: unused_local_variable
          final shareStorage = shareResult.$3;

          LogService().log('LogApiService: Sharing alert ${alertToShare.apiId} from $alertPathForShare');

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
          // ignore: unused_local_variable
          final uploadAlertPath = uploadResult.$2;
          // ignore: unused_local_variable
          final uploadStorage = uploadResult.$3;

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

      final blogHandlerStorage = FilesystemProfileStorage('$dataDir/devices/$callsign');
      final blogApi = BlogHandler(
        storage: blogHandlerStorage,
        log: (level, message) => LogService().log('BlogHandler [$level]: $message'),
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
    BlogHandler blogApi,
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
    BlogHandler blogApi,
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
    BlogHandler blogApi,
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
    BlogHandler blogApi,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final author = json['author'] as String?;
      final content = json['content'] as String?;
      final npub = json['npub'] as String?;
      final signature = json['signature'] as String?;
      // `created_at` is the timestamp the client used when signing.
      // The server must reuse it to reconstruct the same event id.
      final createdAtRaw = json['created_at'];
      final createdAt = createdAtRaw is num ? createdAtRaw.toInt() : null;

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
        createdAt: createdAt,
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
    BlogHandler blogApi,
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
    BlogHandler blogApi,
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
    BlogHandler blogApi,
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
    BlogHandler blogApi,
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
    BlogHandler blogApi,
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
    BlogHandler blogApi,
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
    BlogHandler blogApi,
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
  // Video API Endpoints
  // ============================================================

  /// Main handler for all /api/videos/* endpoints
  Future<shelf.Response> _handleVideoRequest(
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
      final deviceCallsign = request.headers['x-device-callsign'];
      if (deviceCallsign != null && deviceCallsign.isNotEmpty) {
        callsign = deviceCallsign;
        LogService().log('Video API: Serving videos for device $deviceCallsign (from proxy header)');
      }

      final videoStorage = FilesystemProfileStorage('$dataDir/devices/$callsign');
      final videoApi = VideoHandler(
        dataDir: dataDir,
        callsign: callsign,
        storage: videoStorage,
        log: (level, message) => LogService().log('VideoHandler [$level]: $message'),
      );

      // Remove 'api/videos' prefix for easier parsing
      String subPath = '';
      if (urlPath.startsWith('api/videos/')) {
        subPath = urlPath.substring('api/videos/'.length);
      } else if (urlPath == 'api/videos' || urlPath == 'api/videos/') {
        subPath = '';
      }

      // Remove trailing slash
      if (subPath.endsWith('/')) {
        subPath = subPath.substring(0, subPath.length - 1);
      }

      // Parse the sub-path to determine the operation
      final pathParts = subPath.isEmpty ? <String>[] : subPath.split('/');

      // Handle POST methods for feedback
      if (request.method == 'POST') {
        if (pathParts.length == 2 && pathParts[1] == 'comment') {
          // POST /api/videos/{videoId}/comment
          final videoId = pathParts[0];
          return await _handleVideoAddComment(request, videoId, videoApi, headers);
        }
        if (pathParts.length == 2 && pathParts[1] == 'like') {
          // POST /api/videos/{videoId}/like
          final videoId = pathParts[0];
          return await _handleVideoToggleFeedback(request, videoId, 'like', videoApi, headers);
        }
        if (pathParts.length == 2 && pathParts[1] == 'point') {
          // POST /api/videos/{videoId}/point
          final videoId = pathParts[0];
          return await _handleVideoToggleFeedback(request, videoId, 'point', videoApi, headers);
        }
        if (pathParts.length == 2 && pathParts[1] == 'dislike') {
          // POST /api/videos/{videoId}/dislike
          final videoId = pathParts[0];
          return await _handleVideoToggleFeedback(request, videoId, 'dislike', videoApi, headers);
        }
        if (pathParts.length == 2 && pathParts[1] == 'view') {
          // POST /api/videos/{videoId}/view
          final videoId = pathParts[0];
          return await _handleVideoRecordView(request, videoId, videoApi, headers);
        }
        if (pathParts.length == 3 && pathParts[1] == 'react') {
          // POST /api/videos/{videoId}/react/{emoji}
          final videoId = pathParts[0];
          final emoji = pathParts[2];
          return await _handleVideoToggleReaction(request, videoId, emoji, videoApi, headers);
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
          // DELETE /api/videos/{videoId}/comment/{commentId}
          final videoId = pathParts[0];
          final commentId = pathParts[2];
          return await _handleVideoDeleteComment(request, videoId, commentId, videoApi, headers);
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

      // GET /api/videos - List all videos
      if (subPath.isEmpty) {
        return await _handleVideoList(request, videoApi, headers);
      }

      // GET /api/videos/categories - List categories
      if (subPath == 'categories') {
        final result = await videoApi.getCategories();
        return shelf.Response.ok(jsonEncode(result), headers: headers);
      }

      // GET /api/videos/tags - List all tags
      if (subPath == 'tags') {
        final result = await videoApi.getTags();
        return shelf.Response.ok(jsonEncode(result), headers: headers);
      }

      // GET /api/videos/folders - List folder structure
      if (subPath == 'folders' || subPath.startsWith('folders/')) {
        final folderPath = subPath == 'folders' ? null : subPath.substring('folders/'.length);
        final result = await videoApi.getFolders(path: folderPath);
        return shelf.Response.ok(jsonEncode(result), headers: headers);
      }

      if (pathParts.length == 1) {
        // GET /api/videos/{videoId} - Get single video details
        final videoId = pathParts[0];
        final npub = request.url.queryParameters['npub'];
        return await _handleVideoGetDetails(videoId, npub, videoApi, headers);
      }

      if (pathParts.length == 2 && pathParts[1] == 'thumbnail') {
        // GET /api/videos/{videoId}/thumbnail - Get thumbnail image
        final videoId = pathParts[0];
        return await _handleVideoGetThumbnail(videoId, videoApi, headers);
      }

      if (pathParts.length == 2 && pathParts[1] == 'feedback') {
        // GET /api/videos/{videoId}/feedback - Get feedback counts
        final videoId = pathParts[0];
        final npub = request.url.queryParameters['npub'];
        final result = await videoApi.getFeedback(videoId, npub: npub);
        if (result['error'] != null) {
          final httpStatus = result['http_status'] as int? ?? 500;
          return shelf.Response(httpStatus, body: jsonEncode(result), headers: headers);
        }
        return shelf.Response.ok(jsonEncode(result), headers: headers);
      }

      if (pathParts.length == 2 && pathParts[1] == 'comments') {
        // GET /api/videos/{videoId}/comments - List comments
        final videoId = pathParts[0];
        final limit = int.tryParse(request.url.queryParameters['limit'] ?? '');
        final offset = int.tryParse(request.url.queryParameters['offset'] ?? '');
        final result = await videoApi.getComments(videoId, limit: limit, offset: offset);
        if (result['error'] != null) {
          final httpStatus = result['http_status'] as int? ?? 500;
          return shelf.Response(httpStatus, body: jsonEncode(result), headers: headers);
        }
        return shelf.Response.ok(jsonEncode(result), headers: headers);
      }

      return shelf.Response.notFound(
        jsonEncode({'error': 'Video endpoint not found'}),
        headers: headers,
      );
    } catch (e) {
      LogService().log('Video API error: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Internal server error', 'message': e.toString()}),
        headers: headers,
      );
    }
  }

  /// GET /api/videos - List all videos
  Future<shelf.Response> _handleVideoList(
    shelf.Request request,
    VideoHandler videoApi,
    Map<String, String> headers,
  ) async {
    final category = request.url.queryParameters['category'];
    final tag = request.url.queryParameters['tag'];
    final folder = request.url.queryParameters['folder'];
    final limit = int.tryParse(request.url.queryParameters['limit'] ?? '');
    final offset = int.tryParse(request.url.queryParameters['offset'] ?? '');

    final result = await videoApi.getVideos(
      category: category,
      tag: tag,
      folder: folder,
      limit: limit,
      offset: offset,
    );

    return shelf.Response.ok(jsonEncode(result), headers: headers);
  }

  /// GET /api/videos/{videoId} - Get video details
  Future<shelf.Response> _handleVideoGetDetails(
    String videoId,
    String? requesterNpub,
    VideoHandler videoApi,
    Map<String, String> headers,
  ) async {
    final result = await videoApi.getVideoDetails(videoId, requesterNpub: requesterNpub);

    if (result['error'] != null) {
      final httpStatus = result['http_status'] as int? ?? 500;
      return shelf.Response(httpStatus, body: jsonEncode(result), headers: headers);
    }

    return shelf.Response.ok(jsonEncode(result), headers: headers);
  }

  /// GET /api/videos/{videoId}/thumbnail - Get thumbnail image
  Future<shelf.Response> _handleVideoGetThumbnail(
    String videoId,
    VideoHandler videoApi,
    Map<String, String> headers,
  ) async {
    final result = await videoApi.getThumbnail(videoId);

    if (result['error'] != null) {
      final httpStatus = result['http_status'] as int? ?? 404;
      return shelf.Response(httpStatus, body: jsonEncode(result), headers: headers);
    }

    // Serve the thumbnail file
    final filePath = result['filePath'] as String;
    final mimeType = result['mimeType'] as String;
    final file = io.File(filePath);

    if (!await file.exists()) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Thumbnail file not found'}),
        headers: headers,
      );
    }

    final bytes = await file.readAsBytes();
    return shelf.Response.ok(
      bytes,
      headers: {
        'Content-Type': mimeType,
        'Content-Length': bytes.length.toString(),
        'Cache-Control': 'public, max-age=86400',
      },
    );
  }

  /// POST /api/videos/{videoId}/comment - Add comment
  Future<shelf.Response> _handleVideoAddComment(
    shelf.Request request,
    String videoId,
    VideoHandler videoApi,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final author = data['author'] as String?;
      final content = data['content'] as String?;
      final npub = data['npub'] as String?;
      final signature = data['signature'] as String?;

      if (author == null || author.isEmpty) {
        return shelf.Response(400, body: jsonEncode({'error': 'Author is required'}), headers: headers);
      }
      if (content == null || content.isEmpty) {
        return shelf.Response(400, body: jsonEncode({'error': 'Content is required'}), headers: headers);
      }

      final result = await videoApi.addComment(videoId, author, content, npub: npub, signature: signature);

      if (result['success'] == true) {
        return shelf.Response.ok(jsonEncode(result), headers: headers);
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(httpStatus, body: jsonEncode(result), headers: headers);
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Invalid request: $e'}),
        headers: headers,
      );
    }
  }

  /// DELETE /api/videos/{videoId}/comment/{commentId} - Delete comment
  Future<shelf.Response> _handleVideoDeleteComment(
    shelf.Request request,
    String videoId,
    String commentId,
    VideoHandler videoApi,
    Map<String, String> headers,
  ) async {
    try {
      final npub = request.url.queryParameters['npub'];
      if (npub == null || npub.isEmpty) {
        return shelf.Response(401, body: jsonEncode({'error': 'Authentication required (npub)'}), headers: headers);
      }

      final result = await videoApi.deleteComment(videoId, commentId, npub);

      if (result['success'] == true) {
        return shelf.Response.ok(jsonEncode(result), headers: headers);
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(httpStatus, body: jsonEncode(result), headers: headers);
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Invalid request: $e'}),
        headers: headers,
      );
    }
  }

  /// POST /api/videos/{videoId}/like, point, dislike - Toggle feedback
  Future<shelf.Response> _handleVideoToggleFeedback(
    shelf.Request request,
    String videoId,
    String feedbackType,
    VideoHandler videoApi,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final eventJson = jsonDecode(body) as Map<String, dynamic>;

      if (!eventJson.containsKey('id') || !eventJson.containsKey('sig')) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing required NOSTR event fields (id, sig)'}),
          headers: headers,
        );
      }

      Map<String, dynamic> result;
      switch (feedbackType) {
        case 'like':
          result = await videoApi.toggleLike(videoId, eventJson);
          break;
        case 'point':
          result = await videoApi.togglePoint(videoId, eventJson);
          break;
        case 'dislike':
          result = await videoApi.toggleDislike(videoId, eventJson);
          break;
        default:
          return shelf.Response(400, body: jsonEncode({'error': 'Invalid feedback type'}), headers: headers);
      }

      if (result['success'] == true) {
        return shelf.Response.ok(jsonEncode(result), headers: headers);
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(httpStatus, body: jsonEncode(result), headers: headers);
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Invalid request: $e'}),
        headers: headers,
      );
    }
  }

  /// POST /api/videos/{videoId}/view - Record view
  Future<shelf.Response> _handleVideoRecordView(
    shelf.Request request,
    String videoId,
    VideoHandler videoApi,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final eventJson = jsonDecode(body) as Map<String, dynamic>;

      if (!eventJson.containsKey('id') || !eventJson.containsKey('sig')) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing required NOSTR event fields (id, sig)'}),
          headers: headers,
        );
      }

      final result = await videoApi.recordView(videoId, eventJson);

      if (result['success'] == true) {
        return shelf.Response.ok(jsonEncode(result), headers: headers);
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(httpStatus, body: jsonEncode(result), headers: headers);
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Invalid request: $e'}),
        headers: headers,
      );
    }
  }

  /// POST /api/videos/{videoId}/react/{emoji} - Toggle emoji reaction
  Future<shelf.Response> _handleVideoToggleReaction(
    shelf.Request request,
    String videoId,
    String emoji,
    VideoHandler videoApi,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final eventJson = jsonDecode(body) as Map<String, dynamic>;

      if (!eventJson.containsKey('id') || !eventJson.containsKey('sig')) {
        return shelf.Response(
          400,
          body: jsonEncode({'error': 'Missing required NOSTR event fields (id, sig)'}),
          headers: headers,
        );
      }

      final result = await videoApi.toggleReaction(videoId, emoji, eventJson);

      if (result['success'] == true) {
        return shelf.Response.ok(jsonEncode(result), headers: headers);
      } else {
        final httpStatus = result['http_status'] as int? ?? 500;
        return shelf.Response(httpStatus, body: jsonEncode(result), headers: headers);
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
      // Parse path: blog/{filename}.html or {identifier}/blog/{filename}.html
      final parts = urlPath.split('/');
      if (parts.length < 2 || !parts.contains('blog')) {
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
      // If it matches our own callsign, it's still our own blog (not a proxy request)
      final deviceCallsign = request.headers['x-device-callsign'];
      final isOwnBlog = deviceCallsign == null ||
          deviceCallsign.isEmpty ||
          deviceCallsign == callsign;
      if (!isOwnBlog) {
        callsign = deviceCallsign;
        LogService().log('Blog HTML: Serving blog for device $deviceCallsign (from proxy header)');
      }

      // Read blog post by searching all blog-type apps
      final ProfileStorage baseStorage;
      if (isOwnBlog) {
        final storage = AppService().profileStorage;
        if (storage == null) {
          return shelf.Response.internalServerError(
            body: '<html><body><h1>500 Internal Server Error</h1><p>Storage not available</p></body></html>',
            headers: {'Content-Type': 'text/html'},
          );
        }
        baseStorage = storage;
      } else {
        baseStorage = FilesystemProfileStorage('$dataDir/devices/$deviceCallsign');
      }

      final year = filename.length >= 4 ? filename.substring(0, 4) : '';
      BlogPost? foundPost;
      String? postRelativePath;
      ProfileStorage? blogStorage;

      // Search all blog-type apps for this post
      final apps = await AppService().loadApps();
      for (final app in apps) {
        if (app.visibility == 'private') continue;
        if (app.type != 'blog') continue;
        final storagePath = app.storagePath;
        if (storagePath == null) continue;

        final appStorage = ScopedProfileStorage.fromAbsolutePath(baseStorage, storagePath);
        final candidatePath = '$year/$filename/post.md';
        final content = await appStorage.readString(candidatePath);
        if (content != null) {
          try {
            foundPost = BlogPost.fromText(content, filename);
            // Store path relative to app storage for feedback lookup
            postRelativePath = '$year/$filename';
            blogStorage = appStorage;
            break;
          } catch (e) {
            LogService().log('Error parsing blog file: $e');
          }
        }
      }

      if (foundPost == null) {
        return shelf.Response.notFound(
          '<html><body><h1>404 Not Found</h1><p>Blog post not found: $filename</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // Only serve published posts
      if (!foundPost.isPublished) {
        return shelf.Response.notFound(
          '<html><body><h1>404 Not Found</h1><p>Blog post not available</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      final post = foundPost;

      // Read liked npubs and convert to hex pubkeys for client-side checking
      final likedNpubs = await FeedbackFolderUtils.readFeedbackFile(
        postRelativePath!,
        FeedbackFolderUtils.feedbackTypeLikes,
        storage: blogStorage!,
      );
      final likedHexPubkeys = <String>[];
      for (final npub in likedNpubs) {
        try {
          likedHexPubkeys.add(NostrCrypto.decodeNpub(npub));
        } catch (_) {}
      }

      // Generate menu items — same as blog listing (generateBlogIndex)
      final blogMenuItems = await AppService().generateDeviceMenu(
        activeApp: 'blog',
      );

      // Load blog-specific styles from theme
      String blogAppStyles = '';
      try {
        final themeService = WebThemeService();
        await themeService.init();
        blogAppStyles = await themeService.getAppStyles('blog') ?? '';
      } catch (_) {}

      // Render HTML
      final html = _renderBlogPostHtml(post, nickname ?? callsign, likedHexPubkeys, blogMenuItems, blogAppStyles);

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

  String _renderBlogPostHtml(BlogPost post, String authorIdentifier, List<String> likedHexPubkeys, String menuItems, String appStyles) {
    // Pre-render plain text content to HTML paragraphs
    final htmlContent = post.content.split('\n\n')
      .where((p) => p.trim().isNotEmpty)
      .map((p) => '<p>${escapeHtml(p.trim())}</p>')
      .join('\n');

    // Build comments HTML
    String commentsHtml = '';
    if (post.comments.isNotEmpty) {
      final commentCards = post.comments.map((comment) => '''
        <div class="comment">
          <div class="comment-meta">
            <span class="comment-author">${escapeHtml(comment.author)}</span>
            <span class="comment-date">${comment.displayDate}</span>
          </div>
          <p>${escapeHtml(comment.content)}</p>
        </div>''').join('\n');
      commentsHtml = '''
      <div class="comments-section">
        <h2>Comments (${post.comments.length})</h2>
        $commentCards
      </div>''';
    }

    return StationHtmlTemplates.buildBlogPostPage(
      postTitle: post.title,
      postDate: post.displayDate,
      description: post.description,
      author: authorIdentifier,
      htmlContent: htmlContent,
      tags: post.tags,
      menuItems: menuItems,
      logoText: authorIdentifier,
      logoHref: '../',
      postId: post.id,
      npub: post.npub,
      likesCount: post.likesCount,
      likedHexPubkeys: likedHexPubkeys,
      commentsHtml: commentsHtml,
      showSignedBadge: post.isSigned,
      globalStyles: StationHtmlTemplates.getBaseStyles(),
      appStyles: appStyles,
      backUrl: './',
      backLabel: '\u2190 Back to blog',
    );
  }



  // ============================================================
  // Work / NDF Document Web Viewer
  // ============================================================

  /// Handle GET work/{workspace-id}/{filename}.ndf — serve NDF document as HTML
  Future<shelf.Response?> _handleWorkRoute(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      // Parse path: work/{workspaceId}/{filename}.ndf
      // Also handle work/styles.css
      if (urlPath == 'work/styles.css') {
        return await _handleThemeStylesRequest(headers, appType: 'work');
      }

      final decodedPath = Uri.decodeFull(urlPath);

      // Listing pages: work/ or work/{workspaceId}/
      if (request.method == 'GET' && !decodedPath.contains('.ndf')) {
        return await _handleWorkListingRoute(request, decodedPath, headers);
      }

      // Split path at the .ndf boundary to separate document path from action
      final ndfIdx = decodedPath.indexOf('.ndf');
      if (ndfIdx < 0) return null;

      final docPath = decodedPath.substring(0, ndfIdx + 4); // up to and including .ndf
      final actionPath = decodedPath.substring(ndfIdx + 4);  // after .ndf (e.g., /like, /comment, /comment/{id})
      final action = actionPath.startsWith('/') ? actionPath.substring(1) : '';

      final docParts = docPath.split('/');
      // Expect: ['work', workspaceId, filename.ndf]
      if (docParts.length < 3) return null;

      final workspaceId = docParts[1];
      final filename = docParts.sublist(2).join('/');

      // Get current profile info
      String? callsign;
      String? nickname;
      String? dataDir;
      try {
        final profile = ProfileService().getProfile();
        if (profile.callsign.isNotEmpty) callsign = profile.callsign;
        if (profile.nickname.isNotEmpty) nickname = profile.nickname;
      } catch (_) {}
      callsign ??= AppService().currentCallsign;
      nickname ??= callsign;
      try {
        dataDir = StorageConfig().baseDir;
      } catch (_) {}

      if (callsign == null || dataDir == null) {
        return shelf.Response.internalServerError(
          body: '<html><body><h1>500</h1><p>Profile not initialized</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // Find work app
      final apps = await AppService().loadApps();
      App? workApp;
      for (final app in apps) {
        if (app.type == 'work') {
          workApp = app;
          break;
        }
      }

      if (workApp?.storagePath == null) {
        return shelf.Response.notFound(
          '<html><body><h1>404</h1><p>Work app not found</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // Create work storage
      final baseStorage = AppService().profileStorage;
      if (baseStorage == null) {
        return shelf.Response.internalServerError(
          body: '<html><body><h1>500</h1><p>Storage not available</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      final workStorage = WorkStorageService(baseStorage, workApp!.storagePath!);

      // Load workspace
      final workspace = await workStorage.loadWorkspace(workspaceId);
      if (workspace == null) {
        return shelf.Response.notFound(
          '<html><body><h1>404</h1><p>Workspace not found</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // Check document exists in workspace
      if (!workspace.documents.contains(filename)) {
        return shelf.Response.notFound(
          '<html><body><h1>404</h1><p>Document not found</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // Check visibility
      final visibility = workspace.getDocumentVisibility(filename);
      switch (visibility.level) {
        case TrackerVisibilityLevel.private:
          return shelf.Response.forbidden(
            '<html><body><h1>403</h1><p>This document is private</p></body></html>',
            headers: {'Content-Type': 'text/html'},
          );

        case TrackerVisibilityLevel.unlisted:
          final key = request.url.queryParameters['key'];
          if (key == null || !visibility.validateUnlistedKey(key)) {
            return shelf.Response.notFound(
              '<html><body><h1>404</h1><p>Not found</p></body></html>',
              headers: {'Content-Type': 'text/html'},
            );
          }
          break; // Proceed to render

        case TrackerVisibilityLevel.restricted:
          final hexPubkey = _extractNostrPubkeyFromCookie(request);
          if (hexPubkey == null) {
            return shelf.Response.forbidden(
              '<html><body><h1>403</h1><p>Authentication required</p></body></html>',
              headers: {'Content-Type': 'text/html'},
            );
          }
          // Convert hex pubkey to npub for access check
          String? visitorNpub;
          try {
            visitorNpub = NostrCrypto.encodeNpub(hexPubkey);
          } catch (_) {}
          if (visitorNpub == null) {
            return shelf.Response.forbidden(
              '<html><body><h1>403</h1><p>Invalid identity</p></body></html>',
              headers: {'Content-Type': 'text/html'},
            );
          }
          // Check if contact is in allowed list
          final contactMatch = visibility.allowedContacts.any(
            (c) => c.npub == visitorNpub,
          );
          if (!contactMatch) {
            // Check group membership
            bool groupMatch = false;
            if (visibility.allowedGroups.isNotEmpty) {
              try {
                final profileStorage = AppService().profileStorage;
                if (profileStorage != null) {
                  final allApps = await AppService().loadApps();
                  final groupsApp = allApps.cast<App?>().firstWhere(
                    (a) => a?.type == 'groups',
                    orElse: () => null,
                  );
                  if (groupsApp?.storagePath != null) {
                    final groupsStorage = ScopedProfileStorage.fromAbsolutePath(
                      profileStorage, groupsApp!.storagePath!,
                    );
                    final groupsService = GroupsService();
                    groupsService.setStorage(groupsStorage);
                    for (final ag in visibility.allowedGroups) {
                      final group = await groupsService.loadGroup(ag.groupId);
                      if (group != null && group.isMember(visitorNpub)) {
                        groupMatch = true;
                        break;
                      }
                    }
                  }
                }
              } catch (_) {}
            }
            if (!groupMatch) {
              return shelf.Response.forbidden(
                '<html><body><h1>403</h1><p>Access denied</p></body></html>',
                headers: {'Content-Type': 'text/html'},
              );
            }
          }
          break; // Proceed to render

        case TrackerVisibilityLevel.public:
          break; // Proceed to render
      }

      // Serve assets from inside the NDF archive
      if (action.startsWith('assets/')) {
        if (request.method != 'GET') return null;
        final ndfBytes = await workStorage.readDocumentBytes(workspaceId, filename);
        if (ndfBytes == null) return shelf.Response.notFound('Not found');
        return _handleNdfAssetRequest(ndfBytes, action);
      }

      // Handle feedback actions (like, comment, feedback) on sub-paths
      if (action.isNotEmpty) {
        return await _handleWorkFeedbackAction(
          request, action, workStorage, workspaceId, filename, workspace, headers,
        );
      }

      // Read NDF document bytes (GET only for HTML rendering)
      if (request.method != 'GET') return null;
      var ndfBytes = await workStorage.readDocumentBytes(workspaceId, filename);
      if (ndfBytes == null) {
        return shelf.Response.notFound(
          '<html><body><h1>404</h1><p>Document file not found</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // --- HTML cache: serve cached index.html if revision matches ---
      final ndfService = NdfService();
      final metadata = ndfService.readMetadataFromBytes(ndfBytes);
      final currentRevision = metadata?.revision ?? 0;

      // Check for cached index.html inside the archive
      final cachedHtmlBytes = ndfService.readArchiveFileFromBytes(ndfBytes, 'index.html');
      if (cachedHtmlBytes != null) {
        final cachedHtml = utf8.decode(cachedHtmlBytes);
        final cachedRevision = NdfWebViewerService.extractCacheRevision(cachedHtml);
        if (cachedRevision != null && cachedRevision == currentRevision) {
          // Cache hit — serve directly
          return shelf.Response.ok(
            cachedHtml,
            headers: {'Content-Type': 'text/html; charset=utf-8'},
          );
        }
      }

      // Cache miss — generate HTML
      // Generate navigation menu
      final menuItems = await AppService().generateDeviceMenu(
        activeApp: 'work',
        depth: 2,
      );

      // Load interaction settings and feedback data for the page
      final interaction = workspace.getDocumentInteraction(filename);
      final feedbackPath = workStorage.documentFeedbackPath(workspaceId, filename);
      int likesCount = 0;
      List<String> likedHexPubkeys = [];
      List<FeedbackComment> comments = [];
      if (interaction.permitLikes) {
        likesCount = await FeedbackFolderUtils.getFeedbackCount(
          feedbackPath, FeedbackFolderUtils.feedbackTypeLikes,
          storage: workStorage.storage,
        );
        final likedNpubs = await FeedbackFolderUtils.readFeedbackFile(
          feedbackPath, FeedbackFolderUtils.feedbackTypeLikes,
          storage: workStorage.storage,
        );
        for (final npub in likedNpubs) {
          try { likedHexPubkeys.add(NostrCrypto.decodeNpub(npub)); } catch (_) {}
        }
      }
      if (interaction.permitComments) {
        comments = await FeedbackCommentUtils.loadComments(
          feedbackPath, storage: workStorage.storage,
        );
      }

      // Generate HTML page
      final identifier = nickname ?? callsign ?? '';
      final ownerNpub = workspace.ownerNpub;
      final html = NdfWebViewerService().buildPage(
        ndfBytes,
        ownerIdentifier: identifier,
        workspaceName: workspace.name,
        menuItems: menuItems,
        logoText: identifier,
        logoHref: '../../',
        interaction: interaction,
        likesCount: likesCount,
        likedHexPubkeys: likedHexPubkeys,
        comments: comments,
        ownerNpub: ownerNpub,
        documentFilename: filename,
      );

      if (html == null) {
        return shelf.Response.notFound(
          '<html><body><h1>404</h1><p>Unsupported document type</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // Write cached HTML with revision marker into the archive
      final cachedContent = NdfWebViewerService.prependCacheRevision(html, currentRevision);
      try {
        final updatedBytes = ndfService.updateArchiveStringEntriesInBytes(
          ndfBytes, {'index.html': cachedContent},
        );
        await workStorage.writeDocumentBytes(workspaceId, filename, updatedBytes);
      } catch (e) {
        LogService().log('LogApiService: Failed to cache index.html: $e');
      }

      return shelf.Response.ok(
        html,
        headers: {'Content-Type': 'text/html; charset=utf-8'},
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Error handling work route: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: '<html><body><h1>500</h1><p>$e</p></body></html>',
        headers: {'Content-Type': 'text/html'},
      );
    }
  }

  /// Serve a file from inside an NDF (ZIP) archive via HTTP.
  /// Returns null if the request method is not GET.
  shelf.Response? _handleNdfAssetRequest(Uint8List ndfBytes, String assetPath) {
    final fileBytes = NdfService().readArchiveFileFromBytes(ndfBytes, assetPath);
    if (fileBytes == null) return shelf.Response.notFound('Asset not found');
    final mimeType = lookupMimeType(assetPath, headerBytes: fileBytes) ?? 'application/octet-stream';
    return shelf.Response.ok(fileBytes, headers: {
      'Content-Type': mimeType,
      'Cache-Control': 'public, max-age=31536000, immutable',
    });
  }

  /// Handle feedback actions on work documents: like, comment, feedback, comment/{id}
  /// Called from _handleWorkRoute when the URL has a sub-path after .ndf
  Future<shelf.Response> _handleWorkFeedbackAction(
    shelf.Request request,
    String action,
    WorkStorageService workStorage,
    String workspaceId,
    String filename,
    Workspace workspace,
    Map<String, String> headers,
  ) async {
    final feedbackPath = workStorage.documentFeedbackPath(workspaceId, filename);
    final interaction = workspace.getDocumentInteraction(filename);
    final storage = workStorage.storage;
    final ownerNpub = workspace.ownerNpub;
    return _handleNdfFeedbackAction(
      request, action, feedbackPath, interaction, storage, ownerNpub, headers,
    );
  }

  /// Generic NDF feedback action handler — used by Work and Stories routes.
  Future<shelf.Response> _handleNdfFeedbackAction(
    shelf.Request request,
    String action,
    String feedbackPath,
    NdfInteractionSettings interaction,
    ProfileStorage storage,
    String ownerNpub,
    Map<String, String> headers,
  ) async {
    // POST .ndf/like
    if (action == 'like' && request.method == 'POST') {
      if (!interaction.permitLikes) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Likes not permitted'}), headers: headers);
      }
      final body = await request.readAsString();
      final event = NostrEvent.fromJson(jsonDecode(body) as Map<String, dynamic>);
      if (event.id == null || event.sig == null) {
        return shelf.Response(401,
          body: jsonEncode({'error': 'Missing signature'}), headers: headers);
      }
      final result = await FeedbackFolderUtils.toggleFeedbackEvent(
        feedbackPath, FeedbackFolderUtils.feedbackTypeLikes, event, storage: storage);
      if (result == null) {
        return shelf.Response(401,
          body: jsonEncode({'error': 'Invalid signature'}), headers: headers);
      }
      final count = await FeedbackFolderUtils.getFeedbackCount(
        feedbackPath, FeedbackFolderUtils.feedbackTypeLikes, storage: storage);
      return shelf.Response.ok(
        jsonEncode({'success': true, 'action': result ? 'added' : 'removed',
          'liked': result, 'like_count': count}),
        headers: headers);
    }

    // POST .ndf/comment
    if (action == 'comment' && request.method == 'POST') {
      if (!interaction.permitComments) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Comments not permitted'}), headers: headers);
      }
      final data = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final author = data['author'] as String? ?? '';
      final content = data['content'] as String? ?? '';
      final npub = data['npub'] as String?;
      final signature = data['signature'] as String?;
      if (author.isEmpty || content.isEmpty) {
        return shelf.Response(400,
          body: jsonEncode({'error': 'author and content required'}), headers: headers);
      }
      if (npub == null || signature == null) {
        return shelf.Response(401,
          body: jsonEncode({'error': 'npub and signature required'}), headers: headers);
      }
      final commentId = await FeedbackCommentUtils.writeComment(
        contentPath: feedbackPath, author: author, content: content,
        npub: npub, signature: signature, storage: storage);
      return shelf.Response.ok(
        jsonEncode({'success': true, 'comment_id': commentId}), headers: headers);
    }

    // DELETE .ndf/comment/{commentId}
    if (action.startsWith('comment/') && request.method == 'DELETE') {
      final commentId = action.substring('comment/'.length);
      final requesterNpub = request.headers['x-npub'];
      if (requesterNpub == null || requesterNpub.isEmpty) {
        return shelf.Response(401,
          body: jsonEncode({'error': 'X-Npub header required'}), headers: headers);
      }
      final isOwner = ownerNpub == requesterNpub;
      final comment = await FeedbackCommentUtils.getComment(
        feedbackPath, commentId, storage: storage);
      if (comment == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Comment not found'}), headers: headers);
      }
      if (!isOwner && comment.npub != requesterNpub) {
        return shelf.Response.forbidden(
          jsonEncode({'error': 'Not authorized'}), headers: headers);
      }
      await FeedbackCommentUtils.deleteComment(feedbackPath, commentId, storage: storage);
      return shelf.Response.ok(jsonEncode({'success': true}), headers: headers);
    }

    // GET .ndf/feedback
    if (action == 'feedback' && request.method == 'GET') {
      final likesCount = interaction.permitLikes
          ? await FeedbackFolderUtils.getFeedbackCount(
              feedbackPath, FeedbackFolderUtils.feedbackTypeLikes, storage: storage)
          : 0;
      final comments = interaction.permitComments
          ? await FeedbackCommentUtils.loadComments(feedbackPath, storage: storage)
          : <FeedbackComment>[];
      final npub = request.url.queryParameters['npub'];
      bool? hasLiked;
      if (npub != null && npub.isNotEmpty && interaction.permitLikes) {
        hasLiked = await FeedbackFolderUtils.hasFeedback(
          feedbackPath, FeedbackFolderUtils.feedbackTypeLikes, npub, storage: storage);
      }
      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'permit_likes': interaction.permitLikes,
          'permit_comments': interaction.permitComments,
          'likes': likesCount,
          'comments': comments.map((c) => c.toJson()).toList(),
          if (hasLiked != null) 'has_liked': hasLiked,
        }),
        headers: headers);
    }

    return shelf.Response.notFound(
      jsonEncode({'error': 'Unknown action: $action'}), headers: headers);
  }

  // ============================================================
  // Work File Explorer
  // ============================================================

  /// Handle work listing routes: work/ (all workspaces) or work/{id}/ (workspace contents)
  Future<shelf.Response?> _handleWorkListingRoute(
    shelf.Request request,
    String decodedPath,
    Map<String, String> headers,
  ) async {
    // Get profile info
    String? callsign;
    String? nickname;
    try {
      final profile = ProfileService().getProfile();
      if (profile.callsign.isNotEmpty) callsign = profile.callsign;
      if (profile.nickname.isNotEmpty) nickname = profile.nickname;
    } catch (_) {}
    callsign ??= AppService().currentCallsign;
    nickname ??= callsign;
    final identifier = nickname ?? callsign ?? '';

    // Find work app
    final apps = await AppService().loadApps();
    App? workApp;
    for (final app in apps) {
      if (app.type == 'work') { workApp = app; break; }
    }
    if (workApp?.storagePath == null) {
      return shelf.Response.notFound(
        '<html><body><h1>404</h1><p>Work app not found</p></body></html>',
        headers: {'Content-Type': 'text/html'},
      );
    }

    final baseStorage = AppService().profileStorage;
    if (baseStorage == null) {
      return shelf.Response.internalServerError(
        body: '<html><body><h1>500</h1><p>Storage not available</p></body></html>',
        headers: {'Content-Type': 'text/html'},
      );
    }

    final workStorage = WorkStorageService(baseStorage, workApp!.storagePath!);

    // Extract visitor identity
    String? visitorNpub;
    final hexPubkey = _extractNostrPubkeyFromCookie(request);
    if (hexPubkey != null) {
      try { visitorNpub = NostrCrypto.encodeNpub(hexPubkey); } catch (_) {}
    }

    final menuItems = await AppService().generateDeviceMenu(activeApp: 'work');

    // Parse path segments after "work/"
    final pathAfterWork = decodedPath.length > 5 ? decodedPath.substring(5) : '';
    final trimmed = pathAfterWork.endsWith('/') ? pathAfterWork.substring(0, pathAfterWork.length - 1) : pathAfterWork;

    if (trimmed.isEmpty) {
      // work/ → list all workspaces
      return await _buildWorkspacesListingPage(
        workStorage, identifier, visitorNpub, menuItems, headers,
      );
    } else {
      // work/{workspaceId}/ → list documents in workspace
      return await _buildWorkspaceContentsPage(
        workStorage, trimmed, identifier, visitorNpub, menuItems, headers,
      );
    }
  }

  /// Build the workspaces listing page (work/)
  Future<shelf.Response> _buildWorkspacesListingPage(
    WorkStorageService workStorage,
    String identifier,
    String? visitorNpub,
    String menuItems,
    Map<String, String> headers,
  ) async {
    final workspaces = await workStorage.loadWorkspaces();
    final nostrHeaderHtml = getNostrLoginHeaderHtml();
    final nostrStyles = getNostrLoginStyles();
    final nostrScripts = getNostrLoginScripts();
    final globalStyles = StationHtmlTemplates.getBaseStyles();

    // Build workspace cards — only show workspaces that have at least one public/unlisted/restricted doc
    final cardsHtml = StringBuffer();
    int visibleCount = 0;
    for (final ws in workspaces) {
      int publicDocs = 0;
      for (final doc in ws.documents) {
        final vis = ws.getDocumentVisibility(doc);
        if (vis.level == TrackerVisibilityLevel.public ||
            vis.level == TrackerVisibilityLevel.unlisted ||
            (vis.level == TrackerVisibilityLevel.restricted && visitorNpub != null)) {
          publicDocs++;
        }
      }
      if (publicDocs == 0) continue;
      visibleCount++;

      cardsHtml.write('''
      <a href="${Uri.encodeComponent(ws.id)}/" class="ws-card">
        <div class="ws-card-icon">\ud83d\udcc1</div>
        <div class="ws-card-body">
          <h3 class="ws-card-title">${escapeHtml(ws.name)}</h3>
          ${ws.description != null && ws.description!.isNotEmpty ? '<p class="ws-card-desc">${escapeHtml(ws.description!)}</p>' : ''}
          <div class="ws-card-meta">$publicDocs document${publicDocs != 1 ? 's' : ''}</div>
        </div>
      </a>''');
    }

    final html = '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>Work${identifier.isNotEmpty ? ' - ${escapeHtml(identifier)}' : ''}</title>
  <style>$globalStyles
${_getWorkExplorerStyles()}
  </style>
  $nostrStyles
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="../" style="text-decoration: none;">
          <div class="logo">${escapeHtml(identifier)}</div>
        </a>
      </div>
      $nostrHeaderHtml
    </div>
    ${menuItems.isNotEmpty ? '<nav class="menu"><ul class="menu__inner">$menuItems</ul></nav>' : ''}
  </header>
  <div class="content">
    <h1 class="explorer-title">Work</h1>
    <div class="explorer-grid">
      $cardsHtml
    </div>
    ${visibleCount == 0 ? '<p class="empty-message">No documents published yet.</p>' : ''}
  </div>
  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright"><span>published via geogram</span></div>
    </div>
  </footer>
</div>
<script>$nostrScripts</script>
</body>
</html>''';

    return shelf.Response.ok(html, headers: {'Content-Type': 'text/html; charset=utf-8'});
  }

  /// Build a workspace contents page (work/{workspaceId}/)
  Future<shelf.Response> _buildWorkspaceContentsPage(
    WorkStorageService workStorage,
    String workspaceId,
    String identifier,
    String? visitorNpub,
    String menuItems,
    Map<String, String> headers,
  ) async {
    final workspace = await workStorage.loadWorkspace(workspaceId);
    if (workspace == null) {
      return shelf.Response.notFound(
        '<html><body><h1>404</h1><p>Workspace not found</p></body></html>',
        headers: {'Content-Type': 'text/html'},
      );
    }

    final nostrHeaderHtml = getNostrLoginHeaderHtml();
    final nostrStyles = getNostrLoginStyles();
    final nostrScripts = getNostrLoginScripts();
    final globalStyles = StationHtmlTemplates.getBaseStyles();

    // Load document metadata
    final docRefs = await workStorage.listDocuments(workspaceId);
    final docRefMap = <String, NdfDocumentRef>{};
    for (final ref in docRefs) {
      docRefMap[ref.filename] = ref;
    }

    // Get root folders and documents
    final rootFolders = workspace.getFoldersIn(null);
    final rootDocs = workspace.getDocumentsIn(null);

    final contentHtml = StringBuffer();

    // Render folders first
    for (final folder in rootFolders) {
      final folderDocs = workspace.getDocumentsIn(folder.id);
      // Count visible docs in folder
      int visCount = 0;
      for (final doc in folderDocs) {
        final vis = workspace.getDocumentVisibility(doc);
        if (_isDocVisible(vis, visitorNpub)) visCount++;
      }
      if (visCount == 0) continue;

      contentHtml.write('''
      <div class="folder-section">
        <h2 class="folder-name">\ud83d\udcc1 ${escapeHtml(folder.name)}</h2>
        <div class="doc-list">''');

      for (final docFilename in folderDocs) {
        final vis = workspace.getDocumentVisibility(docFilename);
        if (!_isDocVisible(vis, visitorNpub)) continue;
        final ref = docRefMap[docFilename];
        contentHtml.write(_buildDocCard(docFilename, ref, vis));
      }

      contentHtml.write('</div></div>');
    }

    // Render root-level documents
    final visibleRootDocs = <String>[];
    for (final doc in rootDocs) {
      final vis = workspace.getDocumentVisibility(doc);
      if (_isDocVisible(vis, visitorNpub)) visibleRootDocs.add(doc);
    }

    if (visibleRootDocs.isNotEmpty) {
      if (rootFolders.isNotEmpty) {
        contentHtml.write('<h2 class="folder-name">Documents</h2>');
      }
      contentHtml.write('<div class="doc-list">');
      for (final docFilename in visibleRootDocs) {
        final vis = workspace.getDocumentVisibility(docFilename);
        final ref = docRefMap[docFilename];
        contentHtml.write(_buildDocCard(docFilename, ref, vis));
      }
      contentHtml.write('</div>');
    }

    final totalVisible = contentHtml.isEmpty;

    final html = '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>${escapeHtml(workspace.name)}${identifier.isNotEmpty ? ' - ${escapeHtml(identifier)}' : ''}</title>
  <style>$globalStyles
${_getWorkExplorerStyles()}
  </style>
  $nostrStyles
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="../../" style="text-decoration: none;">
          <div class="logo">${escapeHtml(identifier)}</div>
        </a>
      </div>
      $nostrHeaderHtml
    </div>
    ${menuItems.isNotEmpty ? '<nav class="menu"><ul class="menu__inner">$menuItems</ul></nav>' : ''}
  </header>
  <div class="content">
    <div class="explorer-breadcrumb">
      <a href="./">Work</a> &gt; <span>${escapeHtml(workspace.name)}</span>
    </div>
    <h1 class="explorer-title">${escapeHtml(workspace.name)}</h1>
    ${workspace.description != null && workspace.description!.isNotEmpty ? '<p class="explorer-desc">${escapeHtml(workspace.description!)}</p>' : ''}
    $contentHtml
    ${totalVisible ? '<p class="empty-message">No accessible documents in this workspace.</p>' : ''}
  </div>
  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright"><span>published via geogram</span></div>
    </div>
  </footer>
</div>
<script>$nostrScripts</script>
</body>
</html>''';

    return shelf.Response.ok(html, headers: {'Content-Type': 'text/html; charset=utf-8'});
  }

  /// Check if a document is visible to the current visitor
  bool _isDocVisible(TrackerVisibility vis, String? visitorNpub) {
    switch (vis.level) {
      case TrackerVisibilityLevel.public:
        return true;
      case TrackerVisibilityLevel.unlisted:
        return true; // Show in listing but require key to open
      case TrackerVisibilityLevel.restricted:
        return visitorNpub != null; // Show to authenticated users (access checked on open)
      case TrackerVisibilityLevel.private:
        return false;
    }
  }

  /// Build a document card HTML snippet
  String _buildDocCard(String filename, NdfDocumentRef? ref, TrackerVisibility vis) {
    final title = ref?.title ?? filename.replaceAll('.ndf', '');
    final type = ref?.type.name ?? 'document';
    final icon = _docTypeIcon(type);
    final href = vis.level == TrackerVisibilityLevel.unlisted
        ? '${Uri.encodeComponent(filename)}?key=${Uri.encodeComponent(vis.unlistedId ?? '')}'
        : Uri.encodeComponent(filename);

    return '''
      <a href="$href" class="doc-card">
        <div class="doc-card-icon">$icon</div>
        <div class="doc-card-body">
          <div class="doc-card-title">${escapeHtml(title)}</div>
          <div class="doc-card-type">${escapeHtml(type)}</div>
        </div>
      </a>''';
  }

  /// Get icon for document type
  String _docTypeIcon(String type) {
    switch (type) {
      case 'spreadsheet': return '\ud83d\udcca';
      case 'document': return '\ud83d\udcc4';
      case 'presentation': return '\ud83d\udcfd';
      case 'form': return '\ud83d\udccb';
      case 'todo': return '\u2611';
      case 'voicememo': return '\ud83c\udfa4';
      case 'meeting': return '\ud83c\udfa5';
      default: return '\ud83d\udcc4';
    }
  }

  /// CSS for the work file explorer pages
  String _getWorkExplorerStyles() {
    return '''
.explorer-title {
  color: var(--accent);
  margin: 0 0 16px;
  padding-bottom: 10px;
  border-bottom: 2px dashed var(--accent);
}
.explorer-desc {
  margin: 0 0 16px;
  opacity: 0.7;
  font-size: 0.9rem;
}
.explorer-breadcrumb {
  font-size: 0.85rem;
  margin-bottom: 8px;
  opacity: 0.7;
}
.explorer-breadcrumb a { color: var(--accent); text-decoration: none; }
.explorer-breadcrumb a:hover { text-decoration: underline; }
.explorer-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 16px;
}
.ws-card {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  text-decoration: none;
  color: var(--color);
  border: 1px solid var(--border-color);
  border-radius: 8px;
  padding: 16px;
  transition: border-color 0.15s;
}
.ws-card:hover { border-color: var(--accent); }
.ws-card-icon { font-size: 1.5rem; }
.ws-card-body { flex: 1; min-width: 0; }
.ws-card-title { margin: 0 0 4px; font-size: 1rem; color: var(--accent); }
.ws-card-desc { margin: 0 0 4px; font-size: 0.8rem; opacity: 0.6; }
.ws-card-meta { font-size: 0.75rem; opacity: 0.5; }
.folder-section { margin-bottom: 24px; }
.folder-name {
  font-size: 1rem;
  margin: 0 0 10px;
  color: var(--accent-alpha-70);
}
.doc-list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
  gap: 10px;
}
.doc-card {
  display: flex;
  align-items: center;
  gap: 10px;
  text-decoration: none;
  color: var(--color);
  border: 1px solid var(--border-color);
  border-radius: 6px;
  padding: 10px 14px;
  transition: border-color 0.15s;
}
.doc-card:hover { border-color: var(--accent); }
.doc-card-icon { font-size: 1.3rem; }
.doc-card-body { flex: 1; min-width: 0; }
.doc-card-title {
  font-size: 0.9rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.doc-card-type { font-size: 0.7rem; opacity: 0.5; text-transform: capitalize; }
.empty-message { text-align: center; opacity: 0.5; margin-top: 40px; }
''';
  }

  // ============================================================
  // Stories Web Viewer
  // ============================================================

  /// Handle stories/* routes — gallery and individual story viewer
  Future<shelf.Response?> _handleStoriesRoute(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    try {
      // stories/styles.css
      if (urlPath == 'stories/styles.css') {
        return await _handleThemeStylesRequest(headers, appType: 'stories');
      }

      // Get current profile info
      String? callsign;
      String? nickname;
      try {
        final profile = ProfileService().getProfile();
        if (profile.callsign.isNotEmpty) callsign = profile.callsign;
        if (profile.nickname.isNotEmpty) nickname = profile.nickname;
      } catch (_) {}
      callsign ??= AppService().currentCallsign;
      nickname ??= callsign;

      if (callsign == null) {
        return shelf.Response.internalServerError(
          body: '<html><body><h1>500</h1><p>Profile not initialized</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      // Find stories app
      final apps = await AppService().loadApps();
      App? storiesApp;
      for (final app in apps) {
        if (app.type == 'stories') {
          storiesApp = app;
          break;
        }
      }

      if (storiesApp?.storagePath == null) {
        return shelf.Response.notFound(
          '<html><body><h1>404</h1><p>Stories app not found</p></body></html>',
          headers: {'Content-Type': 'text/html'},
        );
      }

      final profileStorage = AppService().profileStorage;
      final storiesStorage = StoriesStorageService(
        basePath: storiesApp!.storagePath!,
        storage: profileStorage,
      );
      final storyNdfService = StoryNdfService(storage: profileStorage);
      final identifier = nickname ?? callsign ?? '';

      // Extract visitor identity from cookie
      String? visitorNpub;
      final hexPubkey = _extractNostrPubkeyFromCookie(request);
      if (hexPubkey != null) {
        try { visitorNpub = NostrCrypto.encodeNpub(hexPubkey); } catch (_) {}
      }

      final decodedPath = Uri.decodeFull(urlPath);

      // Gallery page: stories/ or stories/index.html
      if (decodedPath == 'stories' || decodedPath == 'stories/' || decodedPath == 'stories/index.html') {
        if (request.method != 'GET') return null;
        return await _handleStoriesGallery(
          storiesStorage, storyNdfService, profileStorage,
          identifier, visitorNpub, headers,
        );
      }

      // Individual story: stories/{filename}.ndf[/action]
      final ndfIdx = decodedPath.indexOf('.ndf');
      if (ndfIdx < 0) return null;

      final docPath = decodedPath.substring(0, ndfIdx + 4);
      final actionPath = decodedPath.substring(ndfIdx + 4);
      final action = actionPath.startsWith('/') ? actionPath.substring(1) : '';

      // Extract filename from stories/{filename}.ndf
      final parts = docPath.split('/');
      if (parts.length < 2) return null;
      final filename = parts.sublist(1).join('/');

      return await _handleStoryViewer(
        request, storiesStorage, storyNdfService, profileStorage,
        filename, action, identifier, visitorNpub, headers,
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Error handling stories route: $e');
      LogService().log('LogApiService: Stack: $stack');
      return shelf.Response.internalServerError(
        body: '<html><body><h1>500</h1><p>$e</p></body></html>',
        headers: {'Content-Type': 'text/html'},
      );
    }
  }

  /// Build the stories gallery page
  Future<shelf.Response> _handleStoriesGallery(
    StoriesStorageService storiesStorage,
    StoryNdfService storyNdfService,
    ProfileStorage? profileStorage,
    String identifier,
    String? visitorNpub,
    Map<String, String> headers,
  ) async {
    final stories = await storiesStorage.loadStories();
    final entries = <StoryGalleryEntry>[];

    for (final story in stories) {
      if (story.filePath == null) continue;

      // Read NDF bytes for thumbnail and permissions
      Uint8List? ndfBytes;
      if (profileStorage != null) {
        final relPath = story.filePath!.startsWith('${profileStorage.basePath}/')
            ? story.filePath!.substring(profileStorage.basePath.length + 1)
            : story.filePath!;
        ndfBytes = await profileStorage.readBytes(relPath);
      } else {
        final file = io.File(story.filePath!);
        if (await file.exists()) ndfBytes = await file.readAsBytes();
      }
      if (ndfBytes == null) continue;

      // Check permissions
      final archive = ZipDecoder().decodeBytes(ndfBytes);
      NdfPermission? permission;
      for (final entry in archive) {
        if (entry.name == 'permissions.json' && entry.isFile) {
          try {
            final content = utf8.decode(entry.content as List<int>);
            permission = NdfPermission.fromJson(
              jsonDecode(content) as Map<String, dynamic>,
            );
          } catch (_) {}
          break;
        }
      }

      // Access check: allow if anonymous view allowed, or visitor has permission
      if (permission != null && !permission.allowAnonymousView) {
        if (visitorNpub == null) continue;
        if (!permission.hasPermission(visitorNpub, NdfPermissionAction.view)) {
          // Check group membership
          bool groupAccess = false;
          try {
            groupAccess = await _checkGroupAccess(visitorNpub, permission);
          } catch (_) {}
          if (!groupAccess) continue;
        }
      }

      // Thumbnail URL — served via the story's asset endpoint
      String? thumbnailUrl;
      for (final entry in archive) {
        if (entry.name == 'assets/thumbnails/preview.png' && entry.isFile) {
          thumbnailUrl = '${story.filename}/assets/thumbnails/preview.png';
          break;
        }
      }

      entries.add(StoryGalleryEntry(
        filename: story.filename,
        title: story.title,
        description: story.description,
        tags: story.tags,
        thumbnailUrl: thumbnailUrl,
        sceneCount: story.content?.sceneCount ?? 0,
        modified: story.modified,
      ));
    }

    final menuItems = await AppService().generateDeviceMenu(
      activeApp: 'stories',
    );

    final html = StoryWebViewerService().buildGalleryPage(
      entries,
      ownerIdentifier: identifier,
      menuItems: menuItems,
      logoText: identifier,
      logoHref: '../',
    );

    return shelf.Response.ok(
      html,
      headers: {'Content-Type': 'text/html; charset=utf-8'},
    );
  }

  /// Handle an individual story page or feedback action
  Future<shelf.Response?> _handleStoryViewer(
    shelf.Request request,
    StoriesStorageService storiesStorage,
    StoryNdfService storyNdfService,
    ProfileStorage? profileStorage,
    String filename,
    String action,
    String identifier,
    String? visitorNpub,
    Map<String, String> headers,
  ) async {
    // Read NDF bytes
    final storyPath = '${storiesStorage.storiesDir}/$filename';
    Uint8List? ndfBytes;
    if (profileStorage != null) {
      final relPath = storyPath.startsWith('${profileStorage.basePath}/')
          ? storyPath.substring(profileStorage.basePath.length + 1)
          : storyPath;
      ndfBytes = await profileStorage.readBytes(relPath);
    } else {
      final file = io.File(storyPath);
      if (await file.exists()) ndfBytes = await file.readAsBytes();
    }

    if (ndfBytes == null) {
      return shelf.Response.notFound(
        '<html><body><h1>404</h1><p>Story not found</p></body></html>',
        headers: {'Content-Type': 'text/html'},
      );
    }

    // Read permissions
    final archive = ZipDecoder().decodeBytes(ndfBytes);
    NdfPermission? permission;
    NdfInteractionSettings interaction = const NdfInteractionSettings();
    String ownerNpub = '';

    for (final entry in archive) {
      if (entry.name == 'permissions.json' && entry.isFile) {
        try {
          final content = utf8.decode(entry.content as List<int>);
          permission = NdfPermission.fromJson(
            jsonDecode(content) as Map<String, dynamic>,
          );
          ownerNpub = permission.owners.isNotEmpty ? permission.owners.first.npub : '';
        } catch (_) {}
        break;
      }
    }

    // Read interaction settings from ndf.json
    for (final entry in archive) {
      if (entry.name == 'ndf.json' && entry.isFile) {
        try {
          final content = utf8.decode(entry.content as List<int>);
          final json = jsonDecode(content) as Map<String, dynamic>;
          final interactionJson = json['interaction'] as Map<String, dynamic>?;
          if (interactionJson != null) {
            interaction = NdfInteractionSettings.fromJson(interactionJson);
          }
        } catch (_) {}
        break;
      }
    }

    // Access check
    if (permission != null && !permission.allowAnonymousView) {
      if (visitorNpub == null) {
        return _buildStoryAccessDeniedPage(headers);
      }
      if (!permission.hasPermission(visitorNpub, NdfPermissionAction.view)) {
        bool groupAccess = false;
        try {
          groupAccess = await _checkGroupAccess(visitorNpub, permission);
        } catch (_) {}
        if (!groupAccess) {
          return _buildStoryAccessDeniedPage(headers);
        }
      }
    }

    // Serve assets from inside the NDF archive
    if (action.startsWith('assets/')) {
      if (request.method != 'GET') return null;
      return _handleNdfAssetRequest(ndfBytes!, action);
    }

    // Quiz answer validation endpoint
    if (action == 'quiz' && request.method == 'POST') {
      return await _handleStoryQuizSubmit(
        request, ndfBytes!, storyNdfService, storiesStorage,
        profileStorage, filename, visitorNpub, headers,
      );
    }

    // Quiz state query endpoint
    if (action == 'quiz-state' && request.method == 'GET') {
      return await _handleStoryQuizStateWithRequest(
        request, storiesStorage, profileStorage, filename, visitorNpub, headers,
      );
    }

    // Handle feedback sub-paths
    if (action.isNotEmpty) {
      if (profileStorage == null) {
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Storage not available'}), headers: headers);
      }
      final feedbackPath = '${storiesStorage.storiesDir}/feedback/$filename';
      return await _handleNdfFeedbackAction(
        request, action, feedbackPath, interaction, profileStorage, ownerNpub, headers,
      );
    }

    // Render story page (GET only)
    if (request.method != 'GET') return null;

    // Generate blurred images for quiz scenes (cached in NDF archive)
    ndfBytes = await _ensureQuizBlurredImages(
      ndfBytes!, storyNdfService, storiesStorage, profileStorage, filename,
    );

    final menuItems = await AppService().generateDeviceMenu(
      activeApp: 'stories',
    );

    // Load feedback data
    final feedbackPath = '${storiesStorage.storiesDir}/feedback/$filename';
    int likesCount = 0;
    List<String> likedHexPubkeys = [];
    List<FeedbackComment> comments = [];
    if (profileStorage != null) {
      if (interaction.permitLikes) {
        likesCount = await FeedbackFolderUtils.getFeedbackCount(
          feedbackPath, FeedbackFolderUtils.feedbackTypeLikes,
          storage: profileStorage,
        );
        final likedNpubs = await FeedbackFolderUtils.readFeedbackFile(
          feedbackPath, FeedbackFolderUtils.feedbackTypeLikes,
          storage: profileStorage,
        );
        for (final npub in likedNpubs) {
          try { likedHexPubkeys.add(NostrCrypto.decodeNpub(npub)); } catch (_) {}
        }
      }
      if (interaction.permitComments) {
        comments = await FeedbackCommentUtils.loadComments(
          feedbackPath, storage: profileStorage,
        );
      }
    }

    final html = StoryWebViewerService().buildStoryPage(
      ndfBytes,
      ownerIdentifier: identifier,
      menuItems: menuItems,
      logoText: identifier,
      logoHref: './',
      interaction: interaction,
      likesCount: likesCount,
      likedHexPubkeys: likedHexPubkeys,
      comments: comments,
      ownerNpub: ownerNpub,
      storyFilename: filename,
    );

    if (html == null) {
      return shelf.Response.notFound(
        '<html><body><h1>404</h1><p>Could not render story</p></body></html>',
        headers: {'Content-Type': 'text/html'},
      );
    }

    return shelf.Response.ok(
      html,
      headers: {'Content-Type': 'text/html; charset=utf-8'},
    );
  }

  /// Build a visitor identifier for quiz state tracking (IP + optional pubkey).
  String _quizVisitorId(shelf.Request request, String? visitorNpub) {
    final ip = (request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'] ?? 'unknown')
        .split(',').first.trim();
    return visitorNpub != null ? '${ip}_$visitorNpub' : ip;
  }

  /// Read quiz state JSON for a story. Returns map of elementId -> { attemptsUsed, solved }.
  Future<Map<String, dynamic>> _readQuizStateFile(
    StoriesStorageService storiesStorage,
    ProfileStorage? profileStorage,
    String filename,
  ) async {
    final statePath = '${storiesStorage.storiesDir}/quiz_state/$filename.json';
    try {
      String? content;
      if (profileStorage != null) {
        final relPath = statePath.startsWith('${profileStorage.basePath}/')
            ? statePath.substring(profileStorage.basePath.length + 1) : statePath;
        final bytes = await profileStorage.readBytes(relPath);
        if (bytes != null) content = utf8.decode(bytes);
      } else {
        final file = io.File(statePath);
        if (await file.exists()) content = await file.readAsString();
      }
      if (content != null) return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {}
    return {};
  }

  /// Write quiz state JSON for a story.
  Future<void> _writeQuizStateFile(
    StoriesStorageService storiesStorage,
    ProfileStorage? profileStorage,
    String filename,
    Map<String, dynamic> stateData,
  ) async {
    final statePath = '${storiesStorage.storiesDir}/quiz_state/$filename.json';
    final content = const JsonEncoder.withIndent('  ').convert(stateData);
    if (profileStorage != null) {
      final relPath = statePath.startsWith('${profileStorage.basePath}/')
          ? statePath.substring(profileStorage.basePath.length + 1) : statePath;
      await profileStorage.writeBytes(relPath, Uint8List.fromList(utf8.encode(content)));
    } else {
      final file = io.File(statePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }
  }

  /// Load story content from NDF bytes.
  StoryContent? _loadStoryContentFromBytes(Uint8List ndfBytes) {
    try {
      final archive = ZipDecoder().decodeBytes(ndfBytes);
      Map<String, dynamic>? mainJson;
      for (final entry in archive) {
        if (entry.name == 'content/main.json' && entry.isFile) {
          mainJson = jsonDecode(utf8.decode(entry.content as List<int>)) as Map<String, dynamic>;
          break;
        }
      }
      if (mainJson == null) return null;
      final scenes = <String, StoryScene>{};
      for (final entry in archive) {
        if (entry.name.startsWith('content/scenes/') && entry.name.endsWith('.json') && entry.isFile) {
          final sceneJson = jsonDecode(utf8.decode(entry.content as List<int>)) as Map<String, dynamic>;
          final scene = StoryScene.fromJson(sceneJson);
          scenes[scene.id] = scene;
        }
      }
      return StoryContent.fromJson(mainJson, loadedScenes: scenes);
    } catch (_) {
      return null;
    }
  }

  /// Handle POST quiz answer submission.
  Future<shelf.Response> _handleStoryQuizSubmit(
    shelf.Request request,
    Uint8List ndfBytes,
    StoryNdfService storyNdfService,
    StoriesStorageService storiesStorage,
    ProfileStorage? profileStorage,
    String filename,
    String? visitorNpub,
    Map<String, String> headers,
  ) async {
    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final elementId = body['elementId'] as String?;
      final answer = (body['answer'] as String?)?.trim();
      if (elementId == null || answer == null || answer.isEmpty) {
        return shelf.Response(400,
          body: jsonEncode({'error': 'elementId and answer required'}), headers: headers);
      }

      // Load story content to find the quiz element and its answer
      final content = _loadStoryContentFromBytes(ndfBytes);
      if (content == null) {
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Failed to load story content'}), headers: headers);
      }

      // Find the quiz element
      StoryElement? quizElement;
      StoryScene? quizScene;
      for (final scene in content.orderedScenes) {
        for (final el in scene.elements) {
          if (el.id == elementId && el.type == ElementType.quiz) {
            quizElement = el;
            quizScene = scene;
            break;
          }
        }
        if (quizElement != null) break;
      }
      if (quizElement == null) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'Quiz element not found'}), headers: headers);
      }

      final correctAnswer = quizElement.quizAnswer ?? '';
      final visitorId = _quizVisitorId(request, visitorNpub);
      const maxAttempts = 3;

      // Read current state
      final stateData = await _readQuizStateFile(storiesStorage, profileStorage, filename);
      final visitorStates = (stateData[visitorId] as Map<String, dynamic>?) ?? {};
      final elementState = (visitorStates[elementId] as Map<String, dynamic>?) ?? {};
      int attemptsUsed = (elementState['attemptsUsed'] as num?)?.toInt() ?? 0;
      bool solved = elementState['solved'] == true;

      // Already solved or locked
      if (solved) {
        return shelf.Response.ok(
          jsonEncode({'correct': true, 'attemptsRemaining': 0}), headers: headers);
      }
      if (attemptsUsed >= maxAttempts) {
        return shelf.Response.ok(
          jsonEncode({'correct': false, 'attemptsRemaining': 0}), headers: headers);
      }

      // Validate answer
      final isCorrect = answer.toLowerCase() == correctAnswer.toLowerCase();
      if (!isCorrect) {
        attemptsUsed++;
        visitorStates[elementId] = {'attemptsUsed': attemptsUsed, 'solved': false};
        stateData[visitorId] = visitorStates;
        await _writeQuizStateFile(storiesStorage, profileStorage, filename, stateData);
        return shelf.Response.ok(
          jsonEncode({'correct': false, 'attemptsRemaining': maxAttempts - attemptsUsed}),
          headers: headers);
      }

      // Correct answer — mark solved
      visitorStates[elementId] = {'attemptsUsed': attemptsUsed, 'solved': true};
      stateData[visitorId] = visitorStates;
      await _writeQuizStateFile(storiesStorage, profileStorage, filename, stateData);

      // Return original unblurred image as data URL
      String? imageDataUrl;
      final bgAsset = quizScene!.background.asset;
      if (bgAsset != null) {
        final assetPath = bgAsset.startsWith('asset://') ? bgAsset.substring(8) : bgAsset;
        final originalBytes = NdfService().readArchiveFileFromBytes(ndfBytes, 'assets/$assetPath');
        if (originalBytes != null) {
          final mimeType = lookupMimeType(assetPath, headerBytes: originalBytes) ?? 'image/jpeg';
          imageDataUrl = 'data:$mimeType;base64,${base64Encode(originalBytes)}';
        }
      }

      return shelf.Response.ok(
        jsonEncode({'correct': true, 'imageDataUrl': imageDataUrl}),
        headers: headers);
    } catch (e) {
      LogService().log('LogApiService: Quiz submit error: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Internal error'}), headers: headers);
    }
  }

  /// Handle GET quiz state query — returns visitor's state for all quiz elements.
  Future<shelf.Response> _handleStoryQuizStateWithRequest(
    shelf.Request request,
    StoriesStorageService storiesStorage,
    ProfileStorage? profileStorage,
    String filename,
    String? visitorNpub,
    Map<String, String> headers,
  ) async {
    try {
      final visitorId = _quizVisitorId(request, visitorNpub);
      final stateData = await _readQuizStateFile(storiesStorage, profileStorage, filename);
      final visitorStates = (stateData[visitorId] as Map<String, dynamic>?) ?? {};
      return shelf.Response.ok(jsonEncode(visitorStates), headers: headers);
    } catch (e) {
      return shelf.Response.ok(jsonEncode({}), headers: headers);
    }
  }

  /// Generate blurred images for quiz scenes and cache them in the NDF archive.
  Future<Uint8List> _ensureQuizBlurredImages(
    Uint8List ndfBytes,
    StoryNdfService storyNdfService,
    StoriesStorageService storiesStorage,
    ProfileStorage? profileStorage,
    String filename,
  ) async {
    try {
      final content = _loadStoryContentFromBytes(ndfBytes);
      if (content == null) return ndfBytes;

      final blurFiles = <String, Uint8List>{};

      for (final scene in content.orderedScenes) {
        final hasQuiz = scene.elements.any((e) => e.type == ElementType.quiz);
        if (!hasQuiz) continue;

        final bgAsset = scene.background.asset;
        if (bgAsset == null || bgAsset.isEmpty) continue;

        final assetPath = bgAsset.startsWith('asset://') ? bgAsset.substring(8) : bgAsset;
        final baseName = assetPath.split('/').last;
        final dotIdx = baseName.lastIndexOf('.');
        final nameOnly = dotIdx > 0 ? baseName.substring(0, dotIdx) : baseName;
        final blurPath = 'assets/quiz_blur/${nameOnly}_blur.jpg';

        // Check if blur already exists in archive
        final existing = NdfService().readArchiveFileFromBytes(ndfBytes, blurPath);
        if (existing != null) continue;

        // Read original image
        final originalBytes = NdfService().readArchiveFileFromBytes(ndfBytes, 'assets/$assetPath');
        if (originalBytes == null) continue;

        // Generate blurred version
        final decoded = img.decodeImage(originalBytes);
        if (decoded == null) continue;

        // Downscale to max 800px width
        var blurred = decoded;
        if (decoded.width > 800) {
          blurred = img.copyResize(decoded, width: 800, interpolation: img.Interpolation.linear);
        }
        blurred = img.gaussianBlur(blurred, radius: 15);
        final blurredBytes = Uint8List.fromList(img.encodeJpg(blurred, quality: 60));
        blurFiles[blurPath] = blurredBytes;
      }

      if (blurFiles.isEmpty) return ndfBytes;

      // Write blurred images into the NDF archive
      final updatedBytes = NdfService().updateArchiveEntriesInBytes(ndfBytes, blurFiles);

      // Persist updated archive
      final storyPath = '${storiesStorage.storiesDir}/$filename';
      if (profileStorage != null) {
        final relPath = storyPath.startsWith('${profileStorage.basePath}/')
            ? storyPath.substring(profileStorage.basePath.length + 1) : storyPath;
        await profileStorage.writeBytes(relPath, updatedBytes);
      } else {
        await io.File(storyPath).writeAsBytes(updatedBytes);
      }

      return updatedBytes;
    } catch (e) {
      LogService().log('LogApiService: Failed to generate quiz blur images: $e');
      return ndfBytes;
    }
  }

  shelf.Response _buildStoryAccessDeniedPage(Map<String, String> headers) {
    final nostrStyles = getNostrLoginStyles();
    final nostrScripts = getNostrLoginScripts();
    final nostrHeaderHtml = getNostrLoginHeaderHtml();
    final globalStyles = StationHtmlTemplates.getBaseStyles();

    return shelf.Response.forbidden(
      '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Access Denied</title>
  $nostrStyles
  <style>$globalStyles
.container { max-width: 600px; margin: 0 auto; padding: 40px 20px; text-align: center; }
h1 { color: var(--accent); }
p { margin: 16px 0; opacity: 0.7; }
  </style>
</head>
<body>
<div class="container">
  <header class="header"><div class="header__inner">$nostrHeaderHtml</div></header>
  <h1>403 - Access Denied</h1>
  <p>This story requires authentication. Connect with Nostr to access it.</p>
</div>
<script>
document.addEventListener('nostr-connected', function() { location.reload(); });
</script>
<script>$nostrScripts</script>
</body>
</html>''',
      headers: {'Content-Type': 'text/html; charset=utf-8'},
    );
  }

  /// Check if a visitor has group-based access to an NDF permission
  Future<bool> _checkGroupAccess(String visitorNpub, NdfPermission permission) async {
    // Look for groups in the access list
    final viewAccess = permission.access[NdfPermissionAction.view];
    if (viewAccess == null) return false;
    if (viewAccess.type != NdfAccessType.allowlist) return false;
    // Check group membership — same pattern as work routes
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) return false;
    final allApps = await AppService().loadApps();
    final groupsApp = allApps.cast<App?>().firstWhere(
      (a) => a?.type == 'groups',
      orElse: () => null,
    );
    if (groupsApp?.storagePath == null) return false;
    final groupsStorage = ScopedProfileStorage.fromAbsolutePath(
      profileStorage, groupsApp!.storagePath!,
    );
    final groupsService = GroupsService();
    groupsService.setStorage(groupsStorage);

    // Check all owner npubs as potential group references
    for (final owner in permission.owners) {
      // Owners always have access, but here we're checking group membership
      // for non-owners. The allowlist npubs may reference group IDs.
    }

    // Check allowlist entries that might be group members
    final npubs = viewAccess.npubs;
    if (npubs == null) return false;
    // Try each npub as a group ID
    for (final id in npubs) {
      try {
        final group = await groupsService.loadGroup(id);
        if (group != null && group.isMember(visitorNpub)) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  // ============ Wallet API Handlers ============

  /// Initialize wallet service by finding or creating wallet collection
  Future<bool> _initializeWalletService() async {
    try {
      final appService = AppService();
      var walletApp = appService.getAppByType('wallet');

      // Create wallet collection if it doesn't exist
      if (walletApp == null || walletApp.storagePath == null) {
        LogService().log('Wallet API: No wallet collection found, creating one...');

        // Create wallet collection
        final newApp = await appService.createApp(
          title: 'Wallet',
          type: 'wallet',
        );

        if (newApp.storagePath == null) {
          LogService().log('Wallet API: Failed to create wallet collection');
          return false;
        }

        walletApp = newApp;
        LogService().log('Wallet API: Created wallet collection at ${newApp.storagePath}');
      }

      final walletPath = walletApp!.storagePath!;
      await WalletService().initializeApp(walletPath);
      await WalletSyncService().initialize(walletPath);
      LogService().log('Wallet API: Initialized wallet from $walletPath');
      return true;
    } catch (e) {
      LogService().log('Wallet API: Error initializing wallet: $e');
      return false;
    }
  }

  /// Handle wallet debts API requests
  Future<shelf.Response> _handleWalletDebtsRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    final walletService = WalletService();

    // Auto-initialize wallet if not already initialized
    if (!walletService.isInitialized) {
      final initResult = await _initializeWalletService();
      if (!initResult) {
        return shelf.Response.ok(
          jsonEncode({'error': 'Wallet not initialized - no wallet collection found', 'code': 'WALLET_NOT_INITIALIZED'}),
          headers: headers,
        );
      }
    }

    // GET /api/wallet/debts - List all debts
    if ((urlPath == 'api/wallet/debts' || urlPath == 'api/wallet/debts/') && request.method == 'GET') {
      try {
        final debts = await walletService.listAllDebts();
        return shelf.Response.ok(
          jsonEncode({
            'debts': debts.map((d) => _debtSummaryToJson(d)).toList(),
            'count': debts.length,
          }),
          headers: headers,
        );
      } catch (e) {
        LogService().log('Wallet API: Error listing debts: $e');
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Failed to list debts', 'message': e.toString()}),
          headers: headers,
        );
      }
    }

    // POST /api/wallet/debts - Create new debt
    if ((urlPath == 'api/wallet/debts' || urlPath == 'api/wallet/debts/') && request.method == 'POST') {
      try {
        final body = await request.readAsString();
        final data = jsonDecode(body) as Map<String, dynamic>;

        final profile = ProfileService().getProfile();

        final ledger = await walletService.createDebt(
          description: data['description'] as String? ?? '',
          creditor: data['creditor'] as String? ?? profile.callsign,
          creditorNpub: data['creditor_npub'] as String? ?? profile.npub,
          creditorName: data['creditor_name'] as String?,
          debtor: data['debtor'] as String? ?? '',
          debtorNpub: data['debtor_npub'] as String? ?? '',
          debtorName: data['debtor_name'] as String?,
          amount: (data['amount'] as num?)?.toDouble() ?? 0,
          currency: data['currency'] as String? ?? 'EUR',
          dueDate: data['due_date'] as String?,
          terms: data['terms'] as String?,
          content: data['content'] as String?,
          additionalTerms: data['additional_terms'] as String?,
          governingJurisdiction: data['governing_jurisdiction'] as String?,
          includeTerms: data['include_terms'] as bool? ?? true,
          annualInterestRate: (data['annual_interest_rate'] as num?)?.toDouble(),
          numberOfInstallments: data['number_of_installments'] as int? ?? 1,
          paymentIntervalDays: data['payment_interval_days'] as int? ?? 30,
          folderPath: data['folder'] as String?,
          profile: profile,
        );

        if (ledger == null) {
          return shelf.Response.internalServerError(
            body: jsonEncode({'error': 'Failed to create debt'}),
            headers: headers,
          );
        }

        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'debt_id': ledger.id,
            'debt': _ledgerToJson(ledger),
          }),
          headers: headers,
        );
      } catch (e) {
        LogService().log('Wallet API: Error creating debt: $e');
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Failed to create debt', 'message': e.toString()}),
          headers: headers,
        );
      }
    }

    // Extract debt ID from path: api/wallet/debts/{id}
    final pathMatch = RegExp(r'^api/wallet/debts/([^/]+)(?:/(.*))?$').firstMatch(urlPath);
    if (pathMatch == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Invalid wallet path'}),
        headers: headers,
      );
    }

    final debtId = pathMatch.group(1)!;
    final subPath = pathMatch.group(2);

    // GET /api/wallet/debts/{id} - Get debt details
    if ((subPath == null || subPath.isEmpty) && request.method == 'GET') {
      try {
        final ledger = await walletService.findDebt(debtId);
        if (ledger == null) {
          return shelf.Response.notFound(
            jsonEncode({'error': 'Debt not found', 'debt_id': debtId}),
            headers: headers,
          );
        }

        return shelf.Response.ok(
          jsonEncode(_ledgerToJson(ledger)),
          headers: headers,
        );
      } catch (e) {
        LogService().log('Wallet API: Error getting debt $debtId: $e');
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Failed to get debt', 'message': e.toString()}),
          headers: headers,
        );
      }
    }

    // DELETE /api/wallet/debts/{id} - Delete debt
    if ((subPath == null || subPath.isEmpty) && request.method == 'DELETE') {
      try {
        final success = await walletService.deleteDebt(debtId);
        if (!success) {
          return shelf.Response.notFound(
            jsonEncode({'error': 'Debt not found or could not be deleted', 'debt_id': debtId}),
            headers: headers,
          );
        }

        return shelf.Response.ok(
          jsonEncode({'success': true, 'debt_id': debtId}),
          headers: headers,
        );
      } catch (e) {
        LogService().log('Wallet API: Error deleting debt $debtId: $e');
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Failed to delete debt', 'message': e.toString()}),
          headers: headers,
        );
      }
    }

    // GET /api/wallet/debts/{id}/verify - Verify debt signatures
    if (subPath == 'verify' && request.method == 'GET') {
      try {
        final ledger = await walletService.findDebt(debtId);
        if (ledger == null) {
          return shelf.Response.notFound(
            jsonEncode({'error': 'Debt not found', 'debt_id': debtId}),
            headers: headers,
          );
        }

        final isValid = await walletService.verifyDebt(ledger);

        // Build verification details
        final entryVerifications = <Map<String, dynamic>>[];
        for (final entry in ledger.entries) {
          entryVerifications.add({
            'index': ledger.entries.indexOf(entry),
            'type': entry.type.name,
            'has_signature': entry.signature != null && entry.signature!.isNotEmpty,
            'signer_npub': entry.npub,
            'timestamp': entry.timestamp,
          });
        }

        return shelf.Response.ok(
          jsonEncode({
            'debt_id': debtId,
            'valid': isValid,
            'entry_count': ledger.entries.length,
            'entries': entryVerifications,
          }),
          headers: headers,
        );
      } catch (e) {
        LogService().log('Wallet API: Error verifying debt $debtId: $e');
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Failed to verify debt', 'message': e.toString()}),
          headers: headers,
        );
      }
    }

    // POST /api/wallet/debts/{id}/entries - Add entry to debt
    if (subPath == 'entries' && request.method == 'POST') {
      try {
        final body = await request.readAsString();
        final data = jsonDecode(body) as Map<String, dynamic>;

        final entryType = data['type'] as String? ?? 'note';
        final profile = ProfileService().getProfile();
        bool success = false;

        switch (entryType) {
          case 'confirm':
            success = await walletService.confirmDebt(
              debtId: debtId,
              author: profile.callsign,
              profile: profile,
              content: data['content'] as String? ?? '',
            );
            break;
          case 'reject':
            success = await walletService.rejectDebt(
              debtId: debtId,
              author: profile.callsign,
              profile: profile,
              content: data['content'] as String? ?? data['reason'] as String? ?? '',
            );
            break;
          case 'payment':
            // Get the current debt to calculate new balance
            final paymentLedger = await walletService.findDebt(debtId);
            if (paymentLedger == null) {
              return shelf.Response.notFound(
                jsonEncode({'error': 'Debt not found'}),
                headers: headers,
              );
            }
            final paymentAmount = (data['amount'] as num?)?.toDouble() ?? 0;
            final paymentNewBalance = paymentLedger.currentBalance - paymentAmount;
            success = await walletService.recordPayment(
              debtId: debtId,
              author: profile.callsign,
              profile: profile,
              amount: paymentAmount,
              newBalance: paymentNewBalance,
              method: data['method'] as String?,
              content: data['content'] as String? ?? '',
            );
            break;
          case 'confirm_payment':
            success = await walletService.confirmPayment(
              debtId: debtId,
              author: profile.callsign,
              profile: profile,
              content: data['content'] as String? ?? '',
            );
            break;
          case 'work_session':
            success = await walletService.recordWorkSession(
              debtId: debtId,
              author: profile.callsign,
              profile: profile,
              durationMinutes: data['duration_minutes'] as int? ?? 0,
              description: data['description'] as String?,
              content: data['content'] as String? ?? '',
            );
            break;
          case 'confirm_session':
            // Get the current debt to calculate new balance
            final sessionLedger = await walletService.findDebt(debtId);
            if (sessionLedger == null) {
              return shelf.Response.notFound(
                jsonEncode({'error': 'Debt not found'}),
                headers: headers,
              );
            }
            final confirmedMinutes = data['duration_minutes'] as int? ?? 0;
            final sessionNewBalance = (sessionLedger.currentBalance - confirmedMinutes).toInt();
            success = await walletService.confirmWorkSession(
              debtId: debtId,
              author: profile.callsign,
              profile: profile,
              newBalanceMinutes: sessionNewBalance,
              content: data['content'] as String? ?? '',
            );
            break;
          case 'status_change':
            final statusStr = data['new_status'] as String? ?? 'open';
            final newStatus = DebtEntry.parseStatus(statusStr) ?? DebtStatus.open;
            success = await walletService.changeStatus(
              debtId: debtId,
              author: profile.callsign,
              profile: profile,
              newStatus: newStatus,
              content: data['content'] as String? ?? '',
            );
            break;
          case 'note':
            success = await walletService.addNote(
              debtId: debtId,
              author: profile.callsign,
              profile: profile,
              content: data['content'] as String? ?? '',
            );
            break;
          case 'witness':
            success = await walletService.addWitness(
              debtId: debtId,
              author: profile.callsign,
              profile: profile,
              content: data['content'] as String? ?? '',
            );
            break;
          case 'uncollectable':
            success = await walletService.declareUncollectable(
              debtId: debtId,
              profile: profile,
              reason: data['reason'] as String? ?? 'Declared uncollectable via API',
              content: data['content'] as String? ?? '',
            );
            break;
          case 'unpayable':
            success = await walletService.declareUnpayable(
              debtId: debtId,
              profile: profile,
              reason: data['reason'] as String? ?? 'Declared unpayable via API',
              content: data['content'] as String? ?? '',
            );
            break;
          default:
            return shelf.Response.badRequest(
              body: jsonEncode({'error': 'Unknown entry type', 'type': entryType}),
              headers: headers,
            );
        }

        if (!success) {
          return shelf.Response.internalServerError(
            body: jsonEncode({'error': 'Failed to add entry', 'type': entryType}),
            headers: headers,
          );
        }

        // Re-fetch the updated debt
        final updatedLedger = await walletService.findDebt(debtId);
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'entry_type': entryType,
            'debt': updatedLedger != null ? _ledgerToJson(updatedLedger) : null,
          }),
          headers: headers,
        );
      } catch (e) {
        LogService().log('Wallet API: Error adding entry to debt $debtId: $e');
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Failed to add entry', 'message': e.toString()}),
          headers: headers,
        );
      }
    }

    // POST /api/wallet/debts/{id}/sign - Sign the latest unsigned entry by current user
    if (subPath == 'sign' && request.method == 'POST') {
      try {
        final ledger = await walletService.findDebt(debtId);
        if (ledger == null) {
          return shelf.Response.notFound(
            jsonEncode({'error': 'Debt not found', 'debt_id': debtId}),
            headers: headers,
          );
        }

        final profile = ProfileService().getProfile();

        // Find entries that should be signed by this user but aren't
        final unsignedEntries = <int>[];
        for (int i = 0; i < ledger.entries.length; i++) {
          final entry = ledger.entries[i];
          // Check if this entry's author matches our callsign and it's not signed
          if (entry.author == profile.callsign &&
              (entry.signature == null || entry.signature!.isEmpty)) {
            unsignedEntries.add(i);
          }
        }

        if (unsignedEntries.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'No entries require signature',
              'debt_id': debtId,
            }),
            headers: headers,
          );
        }

        // For now, we can add a confirmation entry which will sign the chain
        final success = await walletService.confirmDebt(
          debtId: debtId,
          author: profile.callsign,
          profile: profile,
          content: 'Signed via API',
        );

        final updatedLedger = await walletService.findDebt(debtId);
        return shelf.Response.ok(
          jsonEncode({
            'success': success,
            'signed_entries': unsignedEntries.length,
            'debt': updatedLedger != null ? _ledgerToJson(updatedLedger) : null,
          }),
          headers: headers,
        );
      } catch (e) {
        LogService().log('Wallet API: Error signing debt $debtId: $e');
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Failed to sign debt', 'message': e.toString()}),
          headers: headers,
        );
      }
    }

    return shelf.Response.notFound(
      jsonEncode({'error': 'Unknown wallet endpoint', 'path': urlPath}),
      headers: headers,
    );
  }

  /// Handle wallet sync requests API
  Future<shelf.Response> _handleWalletRequestsRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    // Auto-initialize wallet if not already initialized
    if (!WalletService().isInitialized) {
      final initResult = await _initializeWalletService();
      if (!initResult) {
        return shelf.Response.ok(
          jsonEncode({'error': 'Could not initialize wallet', 'code': 'WALLET_NOT_INITIALIZED'}),
          headers: headers,
        );
      }
    }

    final syncService = WalletSyncService();

    // GET /api/wallet/requests - List pending requests
    if ((urlPath == 'api/wallet/requests' || urlPath == 'api/wallet/requests/') && request.method == 'GET') {
      try {
        final requests = await syncService.getPendingRequests();
        return shelf.Response.ok(
          jsonEncode({
            'requests': requests.map((r) => r.toJson()).toList(),
            'count': requests.length,
          }),
          headers: headers,
        );
      } catch (e) {
        LogService().log('Wallet API: Error listing requests: $e');
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Failed to list requests', 'message': e.toString()}),
          headers: headers,
        );
      }
    }

    // Extract request ID from path: api/wallet/requests/{id}/action
    final pathMatch = RegExp(r'^api/wallet/requests/([^/]+)/(\w+)$').firstMatch(urlPath);
    if (pathMatch == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Invalid wallet requests path'}),
        headers: headers,
      );
    }

    final requestId = pathMatch.group(1)!;
    final action = pathMatch.group(2)!;

    // POST /api/wallet/requests/{id}/approve - Approve request
    if (action == 'approve' && request.method == 'POST') {
      try {
        final profile = ProfileService().getProfile();
        final success = await syncService.approveRequest(requestId, profile);

        if (!success) {
          return shelf.Response.notFound(
            jsonEncode({'error': 'Request not found or could not be approved', 'request_id': requestId}),
            headers: headers,
          );
        }

        return shelf.Response.ok(
          jsonEncode({'success': true, 'request_id': requestId, 'action': 'approved'}),
          headers: headers,
        );
      } catch (e) {
        LogService().log('Wallet API: Error approving request $requestId: $e');
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Failed to approve request', 'message': e.toString()}),
          headers: headers,
        );
      }
    }

    // POST /api/wallet/requests/{id}/reject - Reject request
    if (action == 'reject' && request.method == 'POST') {
      try {
        final body = await request.readAsString();
        String? reason;
        if (body.isNotEmpty) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          reason = data['reason'] as String?;
        }

        final success = await syncService.rejectRequest(requestId, reason: reason);

        if (!success) {
          return shelf.Response.notFound(
            jsonEncode({'error': 'Request not found or could not be rejected', 'request_id': requestId}),
            headers: headers,
          );
        }

        return shelf.Response.ok(
          jsonEncode({'success': true, 'request_id': requestId, 'action': 'rejected'}),
          headers: headers,
        );
      } catch (e) {
        LogService().log('Wallet API: Error rejecting request $requestId: $e');
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Failed to reject request', 'message': e.toString()}),
          headers: headers,
        );
      }
    }

    return shelf.Response.notFound(
      jsonEncode({'error': 'Unknown wallet requests action', 'action': action}),
      headers: headers,
    );
  }

  /// Handle wallet sync POST request
  Future<shelf.Response> _handleWalletSyncRequest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      // Auto-initialize wallet if not already initialized
      if (!WalletService().isInitialized) {
        final initResult = await _initializeWalletService();
        if (!initResult) {
          return shelf.Response.ok(
            jsonEncode({'error': 'Could not initialize wallet', 'code': 'WALLET_NOT_INITIALIZED'}),
            headers: headers,
          );
        }
      }

      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final syncService = WalletSyncService();
      final result = await syncService.receiveSyncData(data);

      return shelf.Response.ok(
        jsonEncode(result),
        headers: headers,
      );
    } catch (e) {
      LogService().log('Wallet API: Error processing sync: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Failed to process sync', 'message': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Convert a DebtLedger to JSON for API response
  Map<String, dynamic> _ledgerToJson(DebtLedger ledger) {
    return {
      'id': ledger.id,
      'description': ledger.description,
      'creditor': ledger.creditor,
      'creditor_npub': ledger.creditorNpub,
      'creditor_name': ledger.creditorName,
      'debtor': ledger.debtor,
      'debtor_npub': ledger.debtorNpub,
      'debtor_name': ledger.debtorName,
      'original_amount': ledger.originalAmount,
      'currency': ledger.currency,
      'due_date': ledger.dueDate,
      'status': DebtEntry.statusToString(ledger.status),
      'created_at': ledger.createdAt?.toIso8601String(),
      'modified_at': ledger.modifiedAt?.toIso8601String(),
      'current_balance': ledger.currentBalance,
      'total_paid': ledger.totalPaid,
      'entries': ledger.entries.map((e) => _entryToJson(e)).toList(),
    };
  }

  /// Convert a DebtEntry to JSON for API response
  Map<String, dynamic> _entryToJson(DebtEntry entry) {
    return {
      'type': entry.type.name,
      'timestamp': entry.timestamp,
      'author': entry.author,
      'author_npub': entry.npub,
      'content': entry.content,
      'amount': entry.amount,
      'currency': entry.currency,
      'has_signature': entry.signature != null && entry.signature!.isNotEmpty,
      'signer_npub': entry.npub,
      'metadata': entry.metadata,
    };
  }

  /// Convert a DebtSummary to JSON for API response
  Map<String, dynamic> _debtSummaryToJson(DebtSummary summary) {
    return {
      'id': summary.id,
      'description': summary.description,
      'status': summary.status.name,
      'is_time_based': summary.isTimeBased,
      'currency': summary.currency,
      'original_amount': summary.originalAmount,
      'current_balance': summary.currentBalance,
      'total_paid': summary.totalPaid,
      'creditor': summary.creditor,
      'creditor_npub': summary.creditorNpub,
      'creditor_name': summary.creditorName,
      'debtor': summary.debtor,
      'debtor_npub': summary.debtorNpub,
      'debtor_name': summary.debtorName,
      'due_date': summary.dueDate,
      'created_at': summary.createdAt?.toIso8601String(),
      'modified_at': summary.modifiedAt?.toIso8601String(),
      'entry_count': summary.entryCount,
      'payment_count': summary.paymentCount,
      'is_established': summary.isEstablished,
      'all_signatures_valid': summary.allSignaturesValid,
      'is_overdue': summary.isOverdue,
      'progress': summary.progress,
    };
  }

  // ============================================================
  // Debug API - Email Actions
  // ============================================================

  /// Handle email debug actions asynchronously
  Future<shelf.Response> _handleEmailAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final emailService = EmailService();
      await emailService.initialize();

      switch (action) {
        case 'email_compose':
          // Create a draft email
          final to = params['to'] as String?;
          final subject = params['subject'] as String?;
          final content = params['content'] as String?;
          final cc = params['cc'] as String?;
          final station = params['station'] as String?;

          if (to == null || to.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing "to" parameter (email address)',
              }),
              headers: headers,
            );
          }

          if (subject == null || subject.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing "subject" parameter',
              }),
              headers: headers,
            );
          }

          final profile = ProfileService().getProfile();
          final stationService = StationService();
          final preferredStation = stationService.getPreferredStation();
          final stationDomain = station ?? preferredStation?.name ?? 'localhost';
          final fromEmail = '${profile.callsign.toLowerCase()}@$stationDomain';

          final toList = to.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          final ccList = cc?.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList() ?? [];

          // Create draft
          final thread = await emailService.createDraft(
            from: fromEmail,
            to: toList,
            subject: subject,
            cc: ccList,
            station: stationDomain,
          );

          // Add initial message if content provided
          if (content != null && content.isNotEmpty) {
            await emailService.createSignedMessage(
              thread: thread,
              content: content,
            );
          }

          LogService().log('LogApiService: Email draft created: ${thread.threadId}');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Draft email created',
              'thread_id': thread.threadId,
              'from': fromEmail,
              'to': toList,
              'subject': subject,
              'station': stationDomain,
            }),
            headers: headers,
          );

        case 'email_send':
          // Compose and send an email in one action
          final to = params['to'] as String?;
          final subject = params['subject'] as String?;
          final content = params['content'] as String?;
          final cc = params['cc'] as String?;
          final station = params['station'] as String?;

          if (to == null || to.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing "to" parameter (email address)',
              }),
              headers: headers,
            );
          }

          if (subject == null || subject.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing "subject" parameter',
              }),
              headers: headers,
            );
          }

          if (content == null || content.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing "content" parameter',
              }),
              headers: headers,
            );
          }

          final profile = ProfileService().getProfile();
          final stationService = StationService();
          final preferredStation = stationService.getPreferredStation();
          final stationDomain = station ?? preferredStation?.name ?? 'localhost';
          final fromEmail = '${profile.callsign.toLowerCase()}@$stationDomain';

          final toList = to.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          final ccList = cc?.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList() ?? [];

          // Create draft first
          final thread = await emailService.createDraft(
            from: fromEmail,
            to: toList,
            subject: subject,
            cc: ccList,
            station: stationDomain,
          );

          // Add message content
          await emailService.createSignedMessage(
            thread: thread,
            content: content,
          );

          // Mark as pending for delivery
          await emailService.markAsPending(thread);

          // Attempt to send via WebSocket
          final ws = WebSocketService();
          bool sent = false;
          String deliveryStatus = 'pending';

          if (ws.isConnected) {
            sent = await emailService.sendViaWebSocket(thread);
            if (sent) {
              deliveryStatus = 'sent_to_station';
              LogService().log('LogApiService: Email sent to station: ${thread.threadId}');
            } else {
              deliveryStatus = 'queued_locally';
              LogService().log('LogApiService: Email queued locally: ${thread.threadId}');
            }
          } else {
            deliveryStatus = 'queued_no_connection';
            LogService().log('LogApiService: Email queued (no station connection): ${thread.threadId}');
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Email created and queued for delivery',
              'thread_id': thread.threadId,
              'from': fromEmail,
              'to': toList,
              'subject': subject,
              'station': stationDomain,
              'delivery_status': deliveryStatus,
              'websocket_connected': ws.isConnected,
            }),
            headers: headers,
          );

        case 'email_send_with_image':
        case 'email_send_with_attachment':
          // Compose and send an email with a local image attachment
          final to = params['to'] as String?;
          final subject = params['subject'] as String?;
          final content = params['content'] as String?;
          final cc = params['cc'] as String?;
          final station = params['station'] as String?;
          final imagePathRaw =
              (params['image_path'] ?? params['attachment_path']) as String?;
          final imageNameOverride = params['image_name'] as String?;

          if (to == null || to.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing "to" parameter (email address)',
              }),
              headers: headers,
            );
          }

          if (subject == null || subject.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing "subject" parameter',
              }),
              headers: headers,
            );
          }

          if (content == null || content.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing "content" parameter',
              }),
              headers: headers,
            );
          }

          if (imagePathRaw == null || imagePathRaw.trim().isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing "image_path" parameter',
              }),
              headers: headers,
            );
          }

          if (kIsWeb) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Attachments are not supported on web for this debug action',
              }),
              headers: headers,
            );
          }

          final imagePath = imagePathRaw.trim();
          final imageFile = io.File(imagePath);
          if (!await imageFile.exists()) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Image file not found',
                'image_path': imagePath,
              }),
              headers: headers,
            );
          }

          final imageBytes = await imageFile.readAsBytes();
          if (imageBytes.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Image file is empty',
                'image_path': imagePath,
              }),
              headers: headers,
            );
          }

          final originalName = (imageNameOverride != null &&
                  imageNameOverride.trim().isNotEmpty)
              ? imageNameOverride.trim()
              : path.basename(imageFile.path);
          final sanitizedName = originalName.replaceAll(RegExp(r'[\\/]'), '_');

          const supportedImageExtensions = {
            '.jpg',
            '.jpeg',
            '.png',
            '.gif',
            '.webp',
            '.bmp',
          };
          final extension = path.extension(sanitizedName).toLowerCase();
          if (!supportedImageExtensions.contains(extension)) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Unsupported image extension',
                'supported_extensions': supportedImageExtensions.toList(),
                'image_name': sanitizedName,
              }),
              headers: headers,
            );
          }

          final profile = ProfileService().getProfile();
          final stationService = StationService();
          final preferredStation = stationService.getPreferredStation();
          final stationDomain = station ?? preferredStation?.name ?? 'localhost';
          final fromEmail = '${profile.callsign.toLowerCase()}@$stationDomain';

          final toList = to
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
          final ccList = cc
                  ?.split(',')
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList() ??
              [];

          final thread = await emailService.createDraft(
            from: fromEmail,
            to: toList,
            subject: subject,
            cc: ccList,
            station: stationDomain,
          );

          // Move to outbox first so attachment is written in final folder.
          await emailService.markAsPending(thread);

          final hash = sha1.convert(imageBytes).toString().substring(0, 40);
          final storedAttachmentName = '${hash}_$sanitizedName';
          await emailService.writeAttachment(
            thread,
            storedAttachmentName,
            Uint8List.fromList(imageBytes),
          );

          await emailService.createSignedMessage(
            thread: thread,
            content: content,
            metadata: {'image': storedAttachmentName},
          );

          final ws = WebSocketService();
          String deliveryStatus = 'pending';
          if (ws.isConnected) {
            final sent = await emailService.sendViaWebSocket(thread);
            if (sent) {
              deliveryStatus = 'sent_to_station';
              LogService().log(
                'LogApiService: Email with image sent to station: ${thread.threadId} ($storedAttachmentName)',
              );
            } else {
              deliveryStatus = 'queued_locally';
              LogService().log(
                'LogApiService: Email with image queued locally: ${thread.threadId} ($storedAttachmentName)',
              );
            }
          } else {
            deliveryStatus = 'queued_no_connection';
            LogService().log(
              'LogApiService: Email with image queued (no station connection): ${thread.threadId} ($storedAttachmentName)',
            );
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Email with image created and queued for delivery',
              'thread_id': thread.threadId,
              'from': fromEmail,
              'to': toList,
              'subject': subject,
              'station': stationDomain,
              'delivery_status': deliveryStatus,
              'websocket_connected': ws.isConnected,
              'attachment': {
                'source_path': imageFile.absolute.path,
                'stored_name': storedAttachmentName,
                'size_bytes': imageBytes.length,
              },
            }),
            headers: headers,
          );

        case 'email_list':
          // List emails in a folder
          final folder = params['folder'] as String? ?? 'inbox';

          // Unified folders - station parameter is kept for API compatibility
          // but all emails are stored in unified folders
          List<EmailThread> threads;
          switch (folder.toLowerCase()) {
            case 'inbox':
              threads = await emailService.getInbox();
              break;
            case 'sent':
              threads = await emailService.getSent();
              break;
            case 'outbox':
              threads = await emailService.getOutbox();
              break;
            case 'drafts':
              threads = await emailService.getDrafts();
              break;
            case 'spam':
              threads = await emailService.getSpam();
              break;
            case 'garbage':
            case 'trash':
              threads = await emailService.getGarbage();
              break;
            default:
              threads = await emailService.getInbox();
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'folder': folder,
              'count': threads.length,
              'threads': threads.map((t) => {
                'thread_id': t.threadId,
                'from': t.from,
                'to': t.to,
                'subject': t.subject,
                'created': t.created,
                'status': t.status.name,
                'message_count': t.messages.length,
              }).toList(),
            }),
            headers: headers,
          );

        case 'email_status':
          // Get email service status
          final stationService = StationService();
          final ws = WebSocketService();
          final preferredStation = stationService.getPreferredStation();

          final accounts = emailService.accounts;
          final connectedAccounts = emailService.connectedAccounts;

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'service_initialized': true,
              'websocket_connected': ws.isConnected,
              'preferred_station': preferredStation?.name,
              'accounts': accounts.map((a) => {
                'station': a.station,
                'email': a.email,
                'connected': a.isConnected,
              }).toList(),
              'connected_account_count': connectedAccounts.length,
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown email action: $action',
              'available_actions': [
                'email_compose',
                'email_send',
                'email_send_with_image',
                'email_send_with_attachment',
                'email_list',
                'email_status',
              ],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Error in email action: $e\n$stack');
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
  // Mirror Sync API
  // ============================================================

  /// Handle mirror sync API requests
  Future<shelf.Response> _handleMirrorRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    // GET /api/mirror/challenge - Get a challenge for authentication
    if (urlPath == 'api/mirror/challenge' && request.method == 'GET') {
      return await _handleMirrorChallenge(request, headers);
    }

    // POST /api/mirror/request - Request sync permission (with signed challenge)
    if (urlPath == 'api/mirror/request' && request.method == 'POST') {
      return await _handleMirrorSyncRequest(request, headers);
    }

    // GET /api/mirror/manifest - Get folder manifest
    if (urlPath == 'api/mirror/manifest' && request.method == 'GET') {
      return await _handleMirrorManifest(request, headers);
    }

    // GET /api/mirror/file - Download a file
    if (urlPath == 'api/mirror/file' && request.method == 'GET') {
      return await _handleMirrorFile(request, headers);
    }

    // POST /api/mirror/upload - Upload a file from peer
    if (urlPath == 'api/mirror/upload' && request.method == 'POST') {
      return await _handleMirrorUpload(request, headers);
    }

    // POST /api/mirror/pair - Reciprocal pairing
    if (urlPath == 'api/mirror/pair' && request.method == 'POST') {
      return await _handleMirrorPair(request, headers);
    }

    return shelf.Response.notFound(
      jsonEncode({'error': 'Mirror endpoint not found'}),
      headers: headers,
    );
  }

  /// Handle GET /api/mirror/challenge - Generate authentication challenge
  Future<shelf.Response> _handleMirrorChallenge(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final folder = request.url.queryParameters['folder'];

      if (folder == null || folder.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing folder parameter',
            'code': 'INVALID_REQUEST',
          }),
          headers: headers,
        );
      }

      // Folder existence is verified later in verifyRequest() using the
      // correct peer callsign (not the active profile's callsign).

      // Generate challenge
      final mirrorService = MirrorSyncService.instance;
      final challenge = mirrorService.generateChallenge(folder);

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'nonce': challenge.nonce,
          'folder': challenge.folder,
          'expires_at': challenge.expiresAt.millisecondsSinceEpoch ~/ 1000,
        }),
        headers: headers,
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Mirror challenge error: $e');
      LogService().log('Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/mirror/request - Request sync permission (with signed challenge)
  Future<shelf.Response> _handleMirrorSyncRequest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      if (body.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing request body',
            'code': 'INVALID_REQUEST',
          }),
          headers: headers,
        );
      }

      final data = jsonDecode(body) as Map<String, dynamic>;
      final eventJson = data['event'] as Map<String, dynamic>?;
      final folder = data['folder'] as String?;

      if (eventJson == null) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing event field',
            'code': 'INVALID_REQUEST',
          }),
          headers: headers,
        );
      }

      if (folder == null || folder.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing folder field',
            'code': 'INVALID_REQUEST',
          }),
          headers: headers,
        );
      }

      // Parse NOSTR event
      final event = NostrEvent.fromJson(eventJson);

      // Verify request
      final mirrorService = MirrorSyncService.instance;
      final result = await mirrorService.verifyRequest(event, folder);

      if (!result.allowed) {
        final statusCode = result.error == 'PEER_NOT_ALLOWED' ||
                result.error == 'FOLDER_NOT_ALLOWED'
            ? 403
            : result.error == 'FOLDER_NOT_FOUND'
                ? 404
                : 401;

        return shelf.Response(
          statusCode,
          body: jsonEncode({
            'success': false,
            'allowed': false,
            'error': result.error,
            'code': result.error,
          }),
          headers: headers,
        );
      }

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'allowed': true,
          'token': result.token,
          'expires_at': result.expiresAt,
          'peer_callsign': event.callsign,
        }),
        headers: headers,
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Mirror request error: $e');
      LogService().log('Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  /// Handle GET /api/mirror/manifest - Get folder manifest
  Future<shelf.Response> _handleMirrorManifest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final folder = request.url.queryParameters['folder'];
      final token = request.url.queryParameters['token'];

      if (token == null || token.isEmpty) {
        return shelf.Response(
          401,
          body: jsonEncode({
            'success': false,
            'error': 'Missing token',
            'code': 'INVALID_TOKEN',
          }),
          headers: headers,
        );
      }

      if (folder == null || folder.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing folder parameter',
          }),
          headers: headers,
        );
      }

      // Validate token
      final mirrorService = MirrorSyncService.instance;
      final tokenData = mirrorService.validateToken(token);

      if (tokenData == null) {
        return shelf.Response(
          401,
          body: jsonEncode({
            'success': false,
            'error': 'Invalid or expired token',
            'code': 'INVALID_TOKEN',
          }),
          headers: headers,
        );
      }

      // Verify requested folder matches token's folder
      if (tokenData.folder != folder) {
        return shelf.Response(
          403,
          body: jsonEncode({
            'success': false,
            'error': 'Token not valid for requested folder',
            'code': 'FOLDER_MISMATCH',
          }),
          headers: headers,
        );
      }

      // Use the shared callsign from the token — NOT the active profile,
      // because the active profile may differ from the mirrored callsign.
      final callsignDir = StorageConfig().getCallsignDir(tokenData.peerCallsign);
      final folderPath = '$callsignDir/$folder';

      // If folder doesn't exist on disk, return an empty manifest so the
      // peer can detect all its local files as pushable uploads.
      final folderExists = await io.Directory(folderPath).exists();

      MirrorManifest manifest;
      if (!folderExists) {
        manifest = MirrorManifest(
          folder: folder,
          totalFiles: 0,
          totalBytes: 0,
          files: [],
          generatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );
      } else {
        final indexPath = StorageConfig().getFileIndexPath(tokenData.peerCallsign);
        final fileIndex = FileIndexService(indexPath);
        final storage = AppService().profileStorage;
        try {
          manifest = await mirrorService.generateManifest(
            storage != null ? '${tokenData.peerCallsign}/$folder' : folderPath,
            storage: storage,
            fileIndex: fileIndex,
          );
        } finally {
          fileIndex.close();
        }
      }

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'folder': manifest.folder,
          'total_files': manifest.totalFiles,
          'total_bytes': manifest.totalBytes,
          'files': manifest.files.map((f) => f.toJson()).toList(),
          'generated_at': manifest.generatedAt,
        }),
        headers: headers,
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Mirror manifest error: $e');
      LogService().log('Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  /// Handle GET /api/mirror/file - Download a file
  Future<shelf.Response> _handleMirrorFile(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final filePath = request.url.queryParameters['path'];
      final token = request.url.queryParameters['token'];

      if (token == null || token.isEmpty) {
        return shelf.Response(
          401,
          body: jsonEncode({
            'success': false,
            'error': 'Missing token',
            'code': 'INVALID_TOKEN',
          }),
          headers: headers,
        );
      }

      if (filePath == null || filePath.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing path parameter',
          }),
          headers: headers,
        );
      }

      // Validate token
      final mirrorService = MirrorSyncService.instance;
      final tokenData = mirrorService.validateToken(token);

      if (tokenData == null) {
        return shelf.Response(
          401,
          body: jsonEncode({
            'success': false,
            'error': 'Invalid or expired token',
            'code': 'INVALID_TOKEN',
          }),
          headers: headers,
        );
      }

      final folder = tokenData.folder;

      // Use the shared callsign from the token — NOT the active profile.
      final callsignDir = StorageConfig().getCallsignDir(tokenData.peerCallsign);
      final folderPath = '$callsignDir/$folder';
      final fullPath = '$folderPath/$filePath';

      // Security: Ensure path doesn't escape folder
      final normalizedPath = path.normalize(fullPath);
      if (!normalizedPath.startsWith(path.normalize(folderPath))) {
        return shelf.Response(
          403,
          body: jsonEncode({
            'success': false,
            'error': 'Invalid path',
            'code': 'PATH_TRAVERSAL',
          }),
          headers: headers,
        );
      }

      // Read file from the peer callsign's folder on disk
      Uint8List bytes;
      final file = io.File(fullPath);
      if (!await file.exists()) {
        return shelf.Response.notFound(
          jsonEncode({
            'success': false,
            'error': 'File not found',
            'code': 'FILE_NOT_FOUND',
          }),
          headers: headers,
        );
      }
      bytes = await file.readAsBytes();

      // Compute SHA1
      final sha1Hash = sha1.convert(bytes).toString();

      // Determine content type
      final ext = path.extension(fullPath).toLowerCase();
      final contentType = _getContentType(ext);

      // Handle Range requests for large files
      final rangeHeader = request.headers['range'];
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final rangeSpec = rangeHeader.substring(6);
        final parts = rangeSpec.split('-');
        final start = int.tryParse(parts[0]) ?? 0;
        final end = parts.length > 1 && parts[1].isNotEmpty
            ? int.tryParse(parts[1]) ?? bytes.length - 1
            : bytes.length - 1;

        if (start >= bytes.length || start > end) {
          return shelf.Response(
            416,
            body: jsonEncode({
              'success': false,
              'error': 'Range not satisfiable',
              'code': 'RANGE_NOT_SATISFIABLE',
            }),
            headers: {...headers, 'Content-Range': 'bytes */${bytes.length}'},
          );
        }

        final rangeBytes = bytes.sublist(start, end + 1);
        return shelf.Response(
          206,
          body: rangeBytes,
          headers: {
            'Content-Type': contentType,
            'Content-Length': rangeBytes.length.toString(),
            'Content-Range': 'bytes $start-$end/${bytes.length}',
            'X-SHA1': sha1Hash,
            'Access-Control-Allow-Origin': '*',
          },
        );
      }

      return shelf.Response.ok(
        bytes,
        headers: {
          'Content-Type': contentType,
          'Content-Length': bytes.length.toString(),
          'X-SHA1': sha1Hash,
          'Access-Control-Allow-Origin': '*',
        },
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Mirror file error: $e');
      LogService().log('Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/mirror/upload - Upload a file from peer
  Future<shelf.Response> _handleMirrorUpload(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final filePath = request.url.queryParameters['path'];
      final token = request.url.queryParameters['token'];
      final expectedSha1 = request.url.queryParameters['sha1'];

      if (token == null || token.isEmpty) {
        return shelf.Response(
          401,
          body: jsonEncode({
            'success': false,
            'error': 'Missing token',
            'code': 'INVALID_TOKEN',
          }),
          headers: headers,
        );
      }

      if (filePath == null || filePath.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing path parameter',
          }),
          headers: headers,
        );
      }

      // Validate token
      final mirrorService = MirrorSyncService.instance;
      final tokenData = mirrorService.validateToken(token);

      if (tokenData == null) {
        return shelf.Response(
          401,
          body: jsonEncode({
            'success': false,
            'error': 'Invalid or expired token',
            'code': 'INVALID_TOKEN',
          }),
          headers: headers,
        );
      }

      final folder = tokenData.folder;

      // Use the shared callsign from the token — NOT the active profile.
      final callsignDir = StorageConfig().getCallsignDir(tokenData.peerCallsign);
      final folderPath = '$callsignDir/$folder';
      final fullPath = '$folderPath/$filePath';

      // Security: Ensure path doesn't escape folder
      final normalizedPath = path.normalize(fullPath);
      if (!normalizedPath.startsWith(path.normalize(folderPath))) {
        return shelf.Response(
          403,
          body: jsonEncode({
            'success': false,
            'error': 'Invalid path',
            'code': 'PATH_TRAVERSAL',
          }),
          headers: headers,
        );
      }

      // Read raw body bytes
      final bytes = await request.read().expand((chunk) => chunk).toList();
      final bodyBytes = Uint8List.fromList(bytes);

      // Verify SHA1 if provided
      if (expectedSha1 != null && expectedSha1.isNotEmpty) {
        final actualSha1 = sha1.convert(bodyBytes).toString();
        if (actualSha1 != expectedSha1) {
          return shelf.Response(
            400,
            body: jsonEncode({
              'success': false,
              'error': 'SHA1 mismatch: expected $expectedSha1, got $actualSha1',
              'code': 'SHA1_MISMATCH',
            }),
            headers: headers,
          );
        }
      }

      // Write file to the peer callsign's folder on disk
      final file = io.File(fullPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bodyBytes);

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'path': filePath,
          'size': bodyBytes.length,
        }),
        headers: headers,
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Mirror upload error: $e');
      LogService().log('Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/mirror/pair - Reciprocal pairing
  Future<shelf.Response> _handleMirrorPair(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;

      final peerNpub = body['npub'] as String?;
      final peerCallsign = body['callsign'] as String?;
      final peerDeviceName = body['device_name'] as String?;
      final peerPlatform = body['platform'] as String?;
      var peerAddress = body['address'] as String?;
      final peerApps = (body['apps'] as List<dynamic>?)?.cast<String>() ?? [];

      if (peerNpub == null || peerNpub.isEmpty ||
          peerCallsign == null || peerCallsign.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing npub or callsign',
          }),
          headers: headers,
        );
      }

      // Extract client IP from shelf connection info as fallback address
      if (peerAddress == null || peerAddress.isEmpty) {
        final connInfo = request.context['shelf.io.connection_info']
            as io.HttpConnectionInfo?;
        if (connInfo != null) {
          final clientIp = connInfo.remoteAddress.address;
          // Use default mirror port since the peer didn't tell us theirs
          peerAddress = '$clientIp:${AppArgs().port}';
          LogService().log(
              'LogApiService: Peer sent no address, using client IP: $peerAddress');
        }
      }

      // 1. Register the remote peer as allowed to sync from us
      MirrorSyncService.instance.addAllowedPeer(peerNpub, peerCallsign);

      // 2. Create a MirrorPeer in our config (reciprocal pairing)
      final apps = <String, AppSyncConfig>{};
      for (final appId in peerApps) {
        apps[appId] = AppSyncConfig(
          appId: appId,
          style: SyncStyle.sendReceive,
          enabled: true,
        );
      }

      final peer = MirrorPeer(
        peerId: peerNpub,
        npub: peerNpub,
        name: peerDeviceName ?? peerCallsign,
        callsign: peerCallsign,
        addresses: peerAddress != null ? [peerAddress] : [],
        apps: apps,
        platform: peerPlatform,
      );

      await MirrorConfigService.instance.addPeer(peer);

      // 3. Enable mirror if not already
      if (!MirrorConfigService.instance.isEnabled) {
        await MirrorConfigService.instance.setEnabled(true);
      }

      // 4. Notify UI
      EventBus().fire(MirrorPairCompletedEvent(peerCallsign: peerCallsign));

      // 5. Return our info so the requester can add us
      final profile = ProfileService().getProfile();
      final config = MirrorConfigService.instance.config;

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'npub': profile.npub,
          'callsign': profile.callsign,
          'device_name': config?.deviceName ?? 'Unknown',
          'platform': io.Platform.operatingSystem,
        }),
        headers: headers,
      );
    } catch (e, stack) {
      LogService().log('LogApiService: Mirror pair error: $e');
      LogService().log('Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  /// Get content type for file extension
  String _getContentType(String ext) {
    switch (ext) {
      case '.json':
        return 'application/json';
      case '.md':
      case '.txt':
        return 'text/plain; charset=utf-8';
      case '.html':
      case '.htm':
        return 'text/html; charset=utf-8';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.pdf':
        return 'application/pdf';
      case '.mp3':
        return 'audio/mpeg';
      case '.mp4':
        return 'video/mp4';
      case '.webm':
        return 'video/webm';
      default:
        return 'application/octet-stream';
    }
  }

  // ============================================================
  // P2P Transfer API
  // ============================================================

  /// Handle P2P transfer API requests
  Future<shelf.Response> _handleP2PRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    if (urlPath == 'api/p2p/relay/send' && request.method == 'POST') {
      return await PeerRelayService().handleSendRequest(request, headers);
    }

    if (urlPath == 'api/p2p/relay/poll' && request.method == 'GET') {
      return await PeerRelayService().handlePollRequest(request, headers);
    }

    if (urlPath == 'api/p2p/relay/status' && request.method == 'GET') {
      return shelf.Response.ok(
        jsonEncode(PeerRelayService().getStatus()),
        headers: headers,
      );
    }

    // POST /api/p2p/offer - Receive offer from sender (called by remote instance)
    if (urlPath == 'api/p2p/offer' && request.method == 'POST') {
      return await _handleP2PReceiveOffer(request, headers);
    }

    // POST /api/p2p/offer/{offerId}/accept - Receiver accepted (called by remote instance)
    final acceptMatch = RegExp(r'^api/p2p/offer/([^/]+)/accept$').firstMatch(urlPath);
    if (acceptMatch != null && request.method == 'POST') {
      return await _handleP2POfferAccepted(request, acceptMatch.group(1)!, headers);
    }

    // POST /api/p2p/offer/{offerId}/reject - Receiver rejected (called by remote instance)
    final rejectMatch = RegExp(r'^api/p2p/offer/([^/]+)/reject$').firstMatch(urlPath);
    if (rejectMatch != null && request.method == 'POST') {
      return await _handleP2POfferRejected(request, rejectMatch.group(1)!, headers);
    }

    // POST /api/p2p/offer/{offerId}/progress - Transfer progress (called by remote instance)
    final progressMatch = RegExp(r'^api/p2p/offer/([^/]+)/progress$').firstMatch(urlPath);
    if (progressMatch != null && request.method == 'POST') {
      return await _handleP2POfferProgress(request, progressMatch.group(1)!, headers);
    }

    // POST /api/p2p/offer/{offerId}/complete - Transfer completed (called by remote instance)
    final completeMatch = RegExp(r'^api/p2p/offer/([^/]+)/complete$').firstMatch(urlPath);
    if (completeMatch != null && request.method == 'POST') {
      return await _handleP2POfferComplete(request, completeMatch.group(1)!, headers);
    }

    // GET /api/p2p/offer/{offerId}/manifest - Get offer manifest
    final manifestMatch = RegExp(r'^api/p2p/offer/([^/]+)/manifest$').firstMatch(urlPath);
    if (manifestMatch != null && request.method == 'GET') {
      return await _handleP2PManifest(request, manifestMatch.group(1)!, headers);
    }

    // GET /api/p2p/offer/{offerId}/file - Download a file
    final fileMatch = RegExp(r'^api/p2p/offer/([^/]+)/file$').firstMatch(urlPath);
    if (fileMatch != null && request.method == 'GET') {
      return await _handleP2PFile(request, fileMatch.group(1)!, headers);
    }

    return shelf.Response.notFound(
      jsonEncode({
        'success': false,
        'error': 'Unknown P2P endpoint',
      }),
      headers: headers,
    );
  }

  /// Handle POST /api/p2p/offer - Receive offer from remote sender
  Future<shelf.Response> _handleP2PReceiveOffer(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final bodyStr = await request.readAsString();
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;

      LogService().log('P2P API: Received offer from ${body['senderCallsign']}');

      // Pass to P2P service to handle
      final p2pService = P2PTransferService();
      p2pService.handleIncomingOffer(body);

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'message': 'Offer received',
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('P2P API: Error receiving offer: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/p2p/offer/{offerId}/accept - Receiver accepted
  Future<shelf.Response> _handleP2POfferAccepted(
    shelf.Request request,
    String offerId,
    Map<String, String> headers,
  ) async {
    try {
      // Parse request body to get receiver callsign
      String? receiverCallsign;
      try {
        final bodyStr = await request.readAsString();
        if (bodyStr.isNotEmpty) {
          final bodyJson = jsonDecode(bodyStr) as Map<String, dynamic>;
          receiverCallsign = bodyJson['receiverCallsign'] as String?;
        }
      } catch (_) {
        // Body parsing failed, continue without callsign
      }

      LogService().log('P2P API: Offer $offerId was accepted by receiver${receiverCallsign != null ? " ($receiverCallsign)" : ""}');

      final p2pService = P2PTransferService();
      final offer = p2pService.getOffer(offerId);

      if (offer == null) {
        return shelf.Response.notFound(
          jsonEncode({'success': false, 'error': 'Offer not found'}),
          headers: headers,
        );
      }

      // Update offer status - receiver has accepted
      p2pService.handleTransferResponse({
        'type': 'transfer_response',
        'offerId': offerId,
        'accepted': true,
        if (receiverCallsign != null) 'receiverCallsign': receiverCallsign,
      });

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'message': 'Acceptance acknowledged',
          'offerId': offerId,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('P2P API: Error handling accept: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/p2p/offer/{offerId}/reject - Receiver rejected
  Future<shelf.Response> _handleP2POfferRejected(
    shelf.Request request,
    String offerId,
    Map<String, String> headers,
  ) async {
    try {
      LogService().log('P2P API: Offer $offerId was rejected by receiver');

      final p2pService = P2PTransferService();
      final offer = p2pService.getOffer(offerId);

      if (offer == null) {
        return shelf.Response.notFound(
          jsonEncode({'success': false, 'error': 'Offer not found'}),
          headers: headers,
        );
      }

      // Update offer status - receiver rejected
      p2pService.handleTransferResponse({
        'type': 'transfer_response',
        'offerId': offerId,
        'accepted': false,
      });

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'message': 'Rejection acknowledged',
          'offerId': offerId,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('P2P API: Error handling reject: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/p2p/offer/{offerId}/progress - Transfer progress
  Future<shelf.Response> _handleP2POfferProgress(
    shelf.Request request,
    String offerId,
    Map<String, String> headers,
  ) async {
    try {
      // Parse request body
      final bodyStr = await request.readAsString();
      Map<String, dynamic> body = {};
      if (bodyStr.isNotEmpty) {
        try {
          body = jsonDecode(bodyStr) as Map<String, dynamic>;
        } catch (_) {}
      }

      final bytesReceived = body['bytesReceived'] as int? ?? 0;
      final filesCompleted = body['filesCompleted'] as int? ?? 0;
      final currentFile = body['currentFile'] as String?;

      final p2pService = P2PTransferService();
      final offer = p2pService.getOffer(offerId);

      if (offer == null) {
        return shelf.Response.notFound(
          jsonEncode({'success': false, 'error': 'Offer not found'}),
          headers: headers,
        );
      }

      // Update offer with progress
      p2pService.handleProgressUpdate({
        'type': 'transfer_progress',
        'offerId': offerId,
        'bytesReceived': bytesReceived,
        'filesCompleted': filesCompleted,
        if (currentFile != null) 'currentFile': currentFile,
      });

      return shelf.Response.ok(
        jsonEncode({'success': true}),
        headers: headers,
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle POST /api/p2p/offer/{offerId}/complete - Transfer completed
  Future<shelf.Response> _handleP2POfferComplete(
    shelf.Request request,
    String offerId,
    Map<String, String> headers,
  ) async {
    try {
      // Parse request body
      final bodyStr = await request.readAsString();
      Map<String, dynamic> body = {};
      if (bodyStr.isNotEmpty) {
        try {
          body = jsonDecode(bodyStr) as Map<String, dynamic>;
        } catch (_) {}
      }

      final success = body['success'] as bool? ?? false;
      final bytesReceived = body['bytesReceived'] as int? ?? 0;
      final filesReceived = body['filesReceived'] as int? ?? 0;
      final error = body['error'] as String?;

      LogService().log('P2P API: Offer $offerId completed - success: $success, files: $filesReceived, bytes: $bytesReceived');

      final p2pService = P2PTransferService();
      final offer = p2pService.getOffer(offerId);

      if (offer == null) {
        return shelf.Response.notFound(
          jsonEncode({'success': false, 'error': 'Offer not found'}),
          headers: headers,
        );
      }

      // Update offer with completion status
      p2pService.handleTransferComplete({
        'type': 'transfer_complete',
        'offerId': offerId,
        'success': success,
        'bytesReceived': bytesReceived,
        'filesReceived': filesReceived,
        if (error != null) 'error': error,
      });

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'message': 'Completion acknowledged',
          'offerId': offerId,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('P2P API: Error handling complete: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle GET /api/p2p/offer/{offerId}/manifest - Get offer manifest
  Future<shelf.Response> _handleP2PManifest(
    shelf.Request request,
    String offerId,
    Map<String, String> headers,
  ) async {
    try {
      final p2pService = P2PTransferService();
      final manifest = p2pService.getOfferManifest(offerId);

      if (manifest == null) {
        return shelf.Response.notFound(
          jsonEncode({
            'success': false,
            'error': 'Offer not found or expired',
            'code': 'OFFER_NOT_FOUND',
          }),
          headers: headers,
        );
      }

      return shelf.Response.ok(
        jsonEncode(manifest),
        headers: {...headers, 'Content-Type': 'application/json'},
      );
    } catch (e) {
      LogService().log('LogApiService: P2P manifest error: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  /// Handle GET /api/p2p/offer/{offerId}/file - Download a file
  Future<shelf.Response> _handleP2PFile(
    shelf.Request request,
    String offerId,
    Map<String, String> headers,
  ) async {
    try {
      final filePath = request.url.queryParameters['path'];
      final token = request.url.queryParameters['token'];

      if (token == null || token.isEmpty) {
        return shelf.Response(
          401,
          body: jsonEncode({
            'success': false,
            'error': 'Missing token',
            'code': 'INVALID_TOKEN',
          }),
          headers: headers,
        );
      }

      if (filePath == null || filePath.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({
            'success': false,
            'error': 'Missing path parameter',
          }),
          headers: headers,
        );
      }

      final p2pService = P2PTransferService();

      // Validate token
      final tokenOfferId = p2pService.validateToken(token);
      if (tokenOfferId == null || tokenOfferId != offerId) {
        return shelf.Response(
          401,
          body: jsonEncode({
            'success': false,
            'error': 'Invalid or expired token',
            'code': 'INVALID_TOKEN',
          }),
          headers: headers,
        );
      }

      // Get actual file path
      final actualPath = p2pService.getFilePath(offerId, filePath);
      if (actualPath == null) {
        return shelf.Response.notFound(
          jsonEncode({
            'success': false,
            'error': 'File not found in offer',
            'code': 'FILE_NOT_FOUND',
          }),
          headers: headers,
        );
      }

      final file = io.File(actualPath);
      if (!await file.exists()) {
        return shelf.Response.notFound(
          jsonEncode({
            'success': false,
            'error': 'File not found on disk',
            'code': 'FILE_NOT_FOUND',
          }),
          headers: headers,
        );
      }

      // Get file length and compute SHA1
      final fileLength = await file.length();

      // For SHA1, we need to read the file - but do it efficiently
      final sha1Digest = await sha1.bind(file.openRead()).first;
      final sha1Hash = sha1Digest.toString();

      // Determine content type
      final ext = path.extension(actualPath).toLowerCase();
      final contentType = _getContentType(ext);

      // Handle Range requests for large files
      final rangeHeader = request.headers['range'];
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final rangeSpec = rangeHeader.substring(6);
        final parts = rangeSpec.split('-');
        final start = int.tryParse(parts[0]) ?? 0;
        final end = parts.length > 1 && parts[1].isNotEmpty
            ? int.tryParse(parts[1]) ?? fileLength - 1
            : fileLength - 1;

        if (start >= fileLength || start > end) {
          return shelf.Response(
            416,
            body: jsonEncode({
              'success': false,
              'error': 'Range not satisfiable',
              'code': 'RANGE_NOT_SATISFIABLE',
            }),
            headers: {...headers, 'Content-Range': 'bytes */$fileLength'},
          );
        }

        // Stream the range with progress tracking
        final rangeLength = end - start + 1;
        final rangeStream = file.openRead(start, end + 1).transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, sink) {
              sink.add(chunk);
              p2pService.updateUploadProgress(offerId, chunk.length);
            },
          ),
        );

        return shelf.Response(
          206,
          body: rangeStream,
          headers: {
            'Content-Type': contentType,
            'Content-Length': rangeLength.toString(),
            'Content-Range': 'bytes $start-$end/$fileLength',
            'X-SHA1': sha1Hash,
            'Access-Control-Allow-Origin': '*',
          },
        );
      }

      // Stream file with progress tracking
      final stream = file.openRead().transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            sink.add(chunk);
            p2pService.updateUploadProgress(offerId, chunk.length);
          },
        ),
      );

      return shelf.Response.ok(
        stream,
        headers: {
          'Content-Type': contentType,
          'Content-Length': fileLength.toString(),
          'X-SHA1': sha1Hash,
          'Access-Control-Allow-Origin': '*',
        },
      );
    } catch (e, stack) {
      LogService().log('LogApiService: P2P file error: $e');
      LogService().log('Stack: $stack');
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
  // Debug API - Profile Actions
  // ============================================================

  /// Handle profile debug actions asynchronously
  Future<shelf.Response> _handleProfileAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final profileService = ProfileService();

      switch (action) {
        case 'profile_list':
          final profiles = profileService.getAllProfiles();
          final activeId = profileService.activeProfileId;

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'active_profile_id': activeId,
              'profiles': profiles.map((p) => {
                'id': p.id,
                'callsign': p.callsign,
                'npub': p.npub,
                'nickname': p.nickname,
                'active': p.id == activeId,
              }).toList(),
            }),
            headers: headers,
          );

        case 'profile_delete':
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

          final profiles = profileService.getAllProfiles();
          final matchIndex = profiles.indexWhere(
            (p) => p.callsign.toUpperCase() == callsign.toUpperCase(),
          );
          final profile = matchIndex >= 0 ? profiles[matchIndex] : null;

          if (profile == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Profile not found for callsign: $callsign',
                'available_callsigns': profiles.map((p) => p.callsign).toList(),
              }),
              headers: headers,
            );
          }

          final deleted = await profileService.deleteProfile(profile.id);

          if (!deleted) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Cannot delete profile (it may be the last one)',
              }),
              headers: headers,
            );
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'deleted_callsign': callsign.toUpperCase(),
              'message': 'Profile deleted',
            }),
            headers: headers,
          );

        case 'profile_switch':
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

          final profiles = profileService.getAllProfiles();
          final matchIdx = profiles.indexWhere(
            (p) => p.callsign.toUpperCase() == callsign.toUpperCase(),
          );
          final target = matchIdx >= 0 ? profiles[matchIdx] : null;

          if (target == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Profile not found for callsign: $callsign',
                'available_callsigns': profiles.map((p) => p.callsign).toList(),
              }),
              headers: headers,
            );
          }

          await profileService.switchToProfile(target.id);

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'switched_to': target.callsign,
              'message': 'Profile switched to ${target.callsign}',
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown profile action: $action',
              'available': [
                'profile_list',
                'profile_delete',
                'profile_switch',
              ],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Profile action error: $e');
      LogService().log('Stack: $stack');
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
  // Debug API - Mirror Actions
  // ============================================================

  /// Handle mirror debug actions asynchronously
  Future<shelf.Response> _handleMirrorAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final mirrorService = MirrorSyncService.instance;

      switch (action) {
        case 'mirror_enable':
          final enabled = params['enabled'];
          if (enabled == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing enabled parameter',
              }),
              headers: headers,
            );
          }

          final isEnabled = enabled == true || enabled == 'true';
          await MirrorConfigService.instance.setEnabled(isEnabled);

          LogService().log('LogApiService: Mirror ${isEnabled ? 'enabled' : 'disabled'}');

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Mirror ${isEnabled ? 'enabled' : 'disabled'}',
              'enabled': isEnabled,
            }),
            headers: headers,
          );

        case 'mirror_request_sync':
          final peerUrl = params['peer_url'] as String?;
          final folder = params['folder'] as String?;
          final peerCallsign = params['peer_callsign'] as String?;

          if (peerUrl == null || peerUrl.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing peer_url parameter',
              }),
              headers: headers,
            );
          }

          if (folder == null || folder.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing folder parameter',
              }),
              headers: headers,
            );
          }

          if (peerCallsign == null || peerCallsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing peer_callsign parameter',
              }),
              headers: headers,
            );
          }

          // Perform sync
          final result = await mirrorService.syncFolder(peerUrl, folder, peerCallsign: peerCallsign);

          return shelf.Response.ok(
            jsonEncode({
              'success': result.success,
              'error': result.error,
              'files_added': result.filesAdded,
              'files_modified': result.filesModified,
              'files_deleted': result.filesDeleted,
              'bytes_transferred': result.bytesTransferred,
              'duration_ms': result.duration.inMilliseconds,
            }),
            headers: headers,
          );

        case 'mirror_get_status':
          final status = mirrorService.status;
          final allowedPeers = mirrorService.allowedPeers;

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'enabled': MirrorConfigService.instance.isEnabled,
              'status': status.toJson(),
              'allowed_peers': allowedPeers.entries
                  .map((e) => {'npub': e.key, 'callsign': e.value})
                  .toList(),
            }),
            headers: headers,
          );

        case 'mirror_add_allowed_peer':
          final npub = params['npub'] as String?;
          final callsign = params['callsign'] as String?;

          if (npub == null || npub.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing npub parameter',
              }),
              headers: headers,
            );
          }

          if (callsign == null || callsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing callsign parameter',
              }),
              headers: headers,
            );
          }

          mirrorService.addAllowedPeer(npub, callsign);

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Added allowed peer $callsign',
              'npub': npub,
              'callsign': callsign,
            }),
            headers: headers,
          );

        case 'mirror_remove_allowed_peer':
          final npub = params['npub'] as String?;

          if (npub == null || npub.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing npub parameter',
              }),
              headers: headers,
            );
          }

          mirrorService.removeAllowedPeer(npub);

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Removed allowed peer',
              'npub': npub,
            }),
            headers: headers,
          );

        case 'mirror_sync_all':
          final configService = MirrorConfigService.instance;
          final config = configService.config;
          final peers = config?.peers ?? [];

          if (peers.isEmpty) {
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'peers_synced': 0,
                'peers_skipped': 0,
                'total_added': 0,
                'total_modified': 0,
                'total_uploaded': 0,
                'errors': 0,
                'details': [],
                'message': 'No peers configured',
              }),
              headers: headers,
            );
          }

          var peersSynced = 0;
          var peersSkipped = 0;
          var totalAdded = 0;
          var totalModified = 0;
          var totalUploaded = 0;
          var errors = 0;
          final details = <Map<String, dynamic>>[];

          for (final peer in peers) {
            if (peer.addresses.isEmpty) {
              peersSkipped++;
              continue;
            }
            final peerUrl = 'http://${peer.addresses.first}';
            final enabledApps = configService.getEnabledAppsForPeer(peer.peerId);

            var peerHadSync = false;
            for (final appId in enabledApps) {
              final appConfig = peer.apps[appId];
              if (appConfig == null) continue;
              final style = appConfig.style;
              if (style == SyncStyle.paused) continue;
              try {
                final result = await mirrorService.syncFolder(
                  peerUrl,
                  appId,
                  peerCallsign: peer.callsign,
                  syncStyle: style,
                  ignorePatterns: appConfig.ignorePatterns,
                );
                final detail = <String, dynamic>{
                  'peer': peer.callsign,
                  'app': appId,
                  'added': result.filesAdded,
                  'modified': result.filesModified,
                  'uploaded': result.filesUploaded,
                };
                if (!result.success) {
                  detail['error'] = result.error;
                  errors++;
                } else {
                  totalAdded += result.filesAdded;
                  totalModified += result.filesModified;
                  totalUploaded += result.filesUploaded;
                  peerHadSync = true;
                }
                details.add(detail);
              } catch (e) {
                errors++;
                details.add({
                  'peer': peer.callsign,
                  'app': appId,
                  'error': e.toString(),
                });
              }
            }

            if (peerHadSync) peersSynced++;
            await configService.markPeerSynced(peer.peerId);
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'peers_synced': peersSynced,
              'peers_skipped': peersSkipped,
              'total_added': totalAdded,
              'total_modified': totalModified,
              'total_uploaded': totalUploaded,
              'errors': errors,
              'details': details,
            }),
            headers: headers,
          );

        case 'mirror_config':
          final configService = MirrorConfigService.instance;
          final config = configService.config;

          if (config == null) {
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'enabled': false,
                'message': 'No mirror config loaded',
              }),
              headers: headers,
            );
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'enabled': config.enabled,
              'device_id': config.deviceId,
              'device_name': config.deviceName,
              'peers': config.peers.map((p) => {
                'peer_id': p.peerId,
                'name': p.name,
                'callsign': p.callsign,
                'platform': p.platform,
                'addresses': p.addresses,
                'apps': p.apps.map((k, v) => MapEntry(k, {
                  'enabled': v.enabled,
                  'style': v.style.name,
                  'state': v.state.name,
                })),
              }).toList(),
            }),
            headers: headers,
          );

        case 'mirror_exclude_rules':
          final rules = MirrorConfigService.instance.config?.excludeRules ?? [];
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'rules': rules.map((r) => r.toJson()).toList(),
            }),
            headers: headers,
          );

        case 'mirror_set_exclude_rules':
          final rulesJson = params['rules'] as List<dynamic>?;
          if (rulesJson == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Missing rules array'}),
              headers: headers,
            );
          }
          final rules = rulesJson
              .map((e) => SyncExcludeRule.fromJson(e as Map<String, dynamic>))
              .toList();
          await MirrorConfigService.instance.saveExcludeRules(rules);
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'rules_count': rules.length,
            }),
            headers: headers,
          );

        case 'mirror_auto_sync_status':
          final autoSync = MirrorAutoSyncService.instance;
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              ...autoSync.toJson(),
            }),
            headers: headers,
          );

        case 'mirror_auto_sync_trigger':
          final autoSync = MirrorAutoSyncService.instance;
          final result = await autoSync.syncAllPeers();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              ...result.toJson(),
            }),
            headers: headers,
          );

        case 'mirror_relay_status':
          final configService = MirrorConfigService.instance;
          final config = configService.config;
          final wsService = WebSocketService();
          final stationConnected = wsService.connectedUrl != null;

          final peerRelays = <Map<String, dynamic>>[];
          if (config != null) {
            for (final peer in config.peers) {
              peerRelays.add({
                'callsign': peer.callsign,
                'direct_address': peer.directAddress,
                'station_relay_url': peer.stationRelayUrl,
                'addresses': peer.addresses,
              });
            }
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'station_connected': stationConnected,
              'station_url': wsService.connectedUrl,
              'peers': peerRelays,
            }),
            headers: headers,
          );

        case 'mirror_open_settings':
          DebugController().triggerMirrorOpenSettings();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Navigated to mirror settings',
            }),
            headers: headers,
          );

        case 'mirror_open_wizard':
          DebugController().triggerMirrorOpenWizard();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Navigated to mirror wizard',
            }),
            headers: headers,
          );

        case 'mirror_diff_test':
          // Test diffManifest correctness using REAL profile data.
          //
          // Required: "folder" param (e.g., "blog").
          //
          // Phase 1 (self-compare): Generate manifest from raw filesystem,
          // then run diffManifest with storage. Should produce 0 diffs.
          //
          // Phase 2 (cross-device simulation): Copy the folder to temp,
          // mutate some files (add, delete, modify), generate manifest
          // from the mutated copy. Then run diffManifest against real
          // local data. Should detect all mutations.
          final mirrorService = MirrorSyncService.instance;
          final storage = AppService().profileStorage;
          final profile = ProfileService().getProfile();
          final callsignDir = StorageConfig().getCallsignDir(profile.callsign);
          final testFolder = params['folder'] as String?;
          if (testFolder == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing "folder" param (e.g., "blog")',
              }),
              headers: headers,
            );
          }

          final folderPath = '$callsignDir/$testFolder';
          if (!await io.Directory(folderPath).exists()) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Folder "$testFolder" not found at $folderPath',
              }),
              headers: headers,
            );
          }

          final tempDir = await io.Directory.systemTemp.createTemp('mirror_diff_diag_');
          final indexPath = '${tempDir.path}/diag_fileindex.sqlite';
          final fileIndex = FileIndexService(indexPath);

          try {
            // === Phase 1: Self-compare ===
            // Generate manifest from raw filesystem (like server does)
            final selfManifest = await mirrorService.generateManifest(folderPath);

            // Run diffManifest with storage (like client does)
            final localPath = '${profile.callsign}/$testFolder';
            final globalExcludeRules = MirrorConfigService.instance.config?.excludeRules ?? const [];
            final selfChanges = await mirrorService.diffManifest(
              selfManifest,
              localPath,
              syncStyle: SyncStyle.sendReceive,
              excludeRules: globalExcludeRules,
              storage: storage,
              fileIndex: fileIndex,
            );

            // === Phase 2: Cross-device simulation ===
            // Copy folder to temp and mutate it
            final mutatedDir = io.Directory('${tempDir.path}/$testFolder');
            await mutatedDir.create(recursive: true);
            // Copy all files
            await for (final entity in io.Directory(folderPath).list(recursive: true)) {
              final relPath = path.relative(entity.path, from: folderPath);
              if (entity is io.File) {
                final dest = io.File('${mutatedDir.path}/$relPath');
                await dest.parent.create(recursive: true);
                await entity.copy(dest.path);
              }
            }

            // Mutation 1: Add a new file (simulates remote-only file)
            final addedFile = io.File('${mutatedDir.path}/_test_remote_only.txt');
            await addedFile.writeAsString('remote only file');

            // Mutation 2: Delete a file if possible (simulates local-only)
            String? deletedFile;
            final mutatedFiles = await mutatedDir.list(recursive: true)
                .where((e) => e is io.File)
                .cast<io.File>()
                .toList();
            if (mutatedFiles.length > 1) {
              final toDelete = mutatedFiles
                  .where((f) => !f.path.endsWith('_test_remote_only.txt'))
                  .first;
              deletedFile = path.relative(toDelete.path, from: mutatedDir.path);
              await toDelete.delete();
            }

            // Mutation 3: Modify a file's content (change hash + mtime)
            String? modifiedFile;
            final remainingFiles = await mutatedDir.list(recursive: true)
                .where((e) => e is io.File && !e.path.endsWith('_test_remote_only.txt'))
                .cast<io.File>()
                .toList();
            if (remainingFiles.isNotEmpty) {
              final toModify = remainingFiles.first;
              modifiedFile = path.relative(toModify.path, from: mutatedDir.path);
              final original = await toModify.readAsString();
              await toModify.writeAsString('$original\n_MUTATED_BY_TEST');
            }

            // Generate manifest from mutated folder (simulates "remote device")
            final mutatedManifest = await mirrorService.generateManifest(mutatedDir.path);

            // Run diffManifest: compare mutated manifest against real local data
            // This is exactly what happens when desktop compares against Android
            final crossChanges = await mirrorService.diffManifest(
              mutatedManifest,
              localPath,
              syncStyle: SyncStyle.sendReceive,
              excludeRules: globalExcludeRules,
              storage: storage,
              fileIndex: fileIndex,
            );

            // Run again with fresh FileIndexService to check cache effect
            final fileIndex2 = FileIndexService('${tempDir.path}/diag2.sqlite');
            final crossChanges2 = await mirrorService.diffManifest(
              mutatedManifest,
              localPath,
              syncStyle: SyncStyle.sendReceive,
              excludeRules: globalExcludeRules,
              storage: storage,
              fileIndex: fileIndex2,
            );
            fileIndex2.close();

            // Expected mutations:
            // - _test_remote_only.txt → add (exists in mutated, not local)
            // - deletedFile → upload (exists local, not in mutated)
            // - modifiedFile → modify or upload (different hash)
            final expectedCount = 1 + (deletedFile != null ? 1 : 0) + (modifiedFile != null ? 1 : 0);

            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'callsign': profile.callsign,
                'storage_type': storage.runtimeType.toString(),
                'folder': testFolder,
                'phase1_self_compare': {
                  'manifest_files': selfManifest.totalFiles,
                  'diff_count': selfChanges.length,
                  'correct': selfChanges.isEmpty,
                  'changes': selfChanges.take(10).map((c) => '${c.type.name}:${c.path}').toList(),
                },
                'phase2_cross_device': {
                  'mutated_manifest_files': mutatedManifest.totalFiles,
                  'local_manifest_files': selfManifest.totalFiles,
                  'mutations_applied': {
                    'added': '_test_remote_only.txt',
                    'deleted': deletedFile,
                    'modified': modifiedFile,
                  },
                  'expected_diff_count': expectedCount,
                  'diff_count_cached': crossChanges.length,
                  'diff_count_fresh': crossChanges2.length,
                  'correct_cached': crossChanges.length == expectedCount,
                  'correct_fresh': crossChanges2.length == expectedCount,
                  'changes_cached': crossChanges.map((c) => '${c.type.name}:${c.path}').toList(),
                  'changes_fresh': crossChanges2.map((c) => '${c.type.name}:${c.path}').toList(),
                },
              }),
              headers: headers,
            );
          } finally {
            fileIndex.close();
            try {
              await tempDir.delete(recursive: true);
            } catch (_) {}
          }

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown mirror action: $action',
              'available': [
                'mirror_enable',
                'mirror_request_sync',
                'mirror_get_status',
                'mirror_add_allowed_peer',
                'mirror_remove_allowed_peer',
                'mirror_sync_all',
                'mirror_config',
                'mirror_auto_sync_status',
                'mirror_auto_sync_trigger',
                'mirror_relay_status',
                'mirror_open_settings',
                'mirror_open_wizard',
                'mirror_diff_test',
                'mirror_exclude_rules',
                'mirror_set_exclude_rules',
              ],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Mirror action error: $e');
      LogService().log('Stack: $stack');
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
  // Debug API - P2P Transfer Actions
  // ============================================================

  /// Handle P2P transfer debug actions asynchronously
  Future<shelf.Response> _handleP2PAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final p2pService = P2PTransferService();

      switch (action) {
        case 'p2p_navigate':
          // Navigate to Transfer panel (collections panel, then open transfer)
          final debugController = DebugController();
          debugController.navigateToPanel(PanelIndex.apps);
          debugController.triggerP2PNavigate();

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Navigating to P2P Transfer panel',
            }),
            headers: headers,
          );

        case 'p2p_send':
          final callsign = params['callsign'] as String?;
          final folder = params['folder'] as String?;

          if (callsign == null || callsign.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing callsign parameter',
              }),
              headers: headers,
            );
          }

          if (folder == null || folder.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing folder parameter',
              }),
              headers: headers,
            );
          }

          // Check folder exists
          final folderDir = io.Directory(folder);
          if (!await folderDir.exists()) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Folder does not exist: $folder',
              }),
              headers: headers,
            );
          }

          // Build file list from folder
          final items = <SendItem>[];
          await for (final entity in folderDir.list(recursive: false)) {
            if (entity is io.File) {
              final stat = await entity.stat();
              items.add(SendItem(
                path: entity.path,
                name: path.basename(entity.path),
                isDirectory: false,
                sizeBytes: stat.size,
              ));
            } else if (entity is io.Directory) {
              // Calculate directory size recursively
              int dirSize = 0;
              await for (final f in io.Directory(entity.path).list(recursive: true)) {
                if (f is io.File) {
                  final fStat = await f.stat();
                  dirSize += fStat.size;
                }
              }
              items.add(SendItem(
                path: entity.path,
                name: path.basename(entity.path),
                isDirectory: true,
                sizeBytes: dirSize,
              ));
            }
          }

          if (items.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Folder is empty: $folder',
              }),
              headers: headers,
            );
          }

          // Send the offer
          final offer = await p2pService.sendOffer(
            recipientCallsign: callsign,
            items: items,
          );

          if (offer == null) {
            return shelf.Response.internalServerError(
              body: jsonEncode({
                'success': false,
                'error': 'Failed to create transfer offer',
              }),
              headers: headers,
            );
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'offer_id': offer.offerId,
              'recipient': callsign,
              'files': offer.totalFiles,
              'total_bytes': offer.totalBytes,
              'status': offer.status.name,
            }),
            headers: headers,
          );

        case 'p2p_list_incoming':
          final offers = p2pService.incomingOffers;
          final offerList = offers.map((o) => {
            'offer_id': o.offerId,
            'sender_callsign': o.senderCallsign,
            'total_files': o.totalFiles,
            'total_bytes': o.totalBytes,
            'expires_at': o.expiresAt.millisecondsSinceEpoch ~/ 1000,
            'status': o.status.name,
          }).toList();

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'offers': offerList,
            }),
            headers: headers,
          );

        case 'p2p_list_outgoing':
          final offers = p2pService.outgoingOffers;
          final offerList = offers.map((o) => {
            'offer_id': o.offerId,
            'receiver_callsign': o.receiverCallsign,
            'total_files': o.totalFiles,
            'total_bytes': o.totalBytes,
            'expires_at': o.expiresAt.millisecondsSinceEpoch ~/ 1000,
            'status': o.status.name,
            'bytes_transferred': o.bytesTransferred,
            'files_completed': o.filesCompleted,
          }).toList();

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'offers': offerList,
            }),
            headers: headers,
          );

        case 'p2p_accept':
          final offerId = params['offer_id'] as String?;
          final destination = params['destination'] as String?;

          if (offerId == null || offerId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing offer_id parameter',
              }),
              headers: headers,
            );
          }

          if (destination == null || destination.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing destination parameter',
              }),
              headers: headers,
            );
          }

          final offer = p2pService.getOffer(offerId);
          if (offer == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Unknown offer: $offerId',
              }),
              headers: headers,
            );
          }

          // Accept the offer (this starts the download asynchronously)
          await p2pService.acceptOffer(offerId, destination);

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Offer accepted, download starting',
              'offer_id': offerId,
              'destination': destination,
              'total_files': offer.totalFiles,
              'total_bytes': offer.totalBytes,
            }),
            headers: headers,
          );

        case 'p2p_reject':
          final offerId = params['offer_id'] as String?;

          if (offerId == null || offerId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing offer_id parameter',
              }),
              headers: headers,
            );
          }

          final offer = p2pService.getOffer(offerId);
          if (offer == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Unknown offer: $offerId',
              }),
              headers: headers,
            );
          }

          await p2pService.rejectOffer(offerId);

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Offer rejected',
              'offer_id': offerId,
            }),
            headers: headers,
          );

        case 'p2p_status':
          final offerId = params['offer_id'] as String?;

          if (offerId == null || offerId.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing offer_id parameter',
              }),
              headers: headers,
            );
          }

          final offer = p2pService.getOffer(offerId);
          if (offer == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Unknown offer: $offerId',
              }),
              headers: headers,
            );
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'offer_id': offerId,
              'status': offer.status.name,
              'bytes_transferred': offer.bytesTransferred,
              'total_bytes': offer.totalBytes,
              'files_completed': offer.filesCompleted,
              'total_files': offer.totalFiles,
              'current_file': offer.currentFile,
              'error': offer.error,
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown P2P action: $action',
              'available': [
                'p2p_navigate',
                'p2p_send',
                'p2p_list_incoming',
                'p2p_list_outgoing',
                'p2p_accept',
                'p2p_reject',
                'p2p_status',
              ],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: P2P action error: $e');
      LogService().log('Stack: $stack');
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
  // Debug API - DHT/P2P Discovery Actions
  // ============================================================

  /// Handle DHT/P2P discovery debug actions
  Future<shelf.Response> _handleDhtAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final p2pService = P2PService();

      switch (action) {
        case 'dht_status':
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              ...p2pService.getStatus(),
            }),
            headers: headers,
          );

        case 'dht_start':
          if (p2pService.isRunning) {
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'message': 'P2P service already running',
                ...p2pService.getStatus(),
              }),
              headers: headers,
            );
          }
          await p2pService.start();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'P2P service started',
              ...p2pService.getStatus(),
            }),
            headers: headers,
          );

        case 'dht_stop':
          await p2pService.stop();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'P2P service stopped',
            }),
            headers: headers,
          );

        case 'dht_find_user':
          final npub = params['npub'] as String?;
          if (npub == null || npub.isEmpty) {
            return shelf.Response(400,
              body: jsonEncode({
                'success': false,
                'error': 'npub parameter required',
              }),
              headers: headers,
            );
          }
          final peers = await p2pService.findDevicesForUser(npub);
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'npub': npub,
              'devices': peers.map((p) => {
                'ip': p.ip,
                'port': p.port,
              }).toList(),
            }),
            headers: headers,
          );

        case 'dht_find_user_light':
          final npub = params['npub'] as String?;
          if (npub == null || npub.isEmpty) {
            return shelf.Response(400,
              body: jsonEncode({
                'success': false,
                'error': 'npub parameter required',
              }),
              headers: headers,
            );
          }
          final peers = await p2pService.findDevicesForUserLight(npub);
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'npub': npub,
              'devices': peers.map((p) => {
                'ip': p.ip,
                'port': p.port,
              }).toList(),
            }),
            headers: headers,
          );

        case 'dht_known_targets':
          final targets = await p2pService.getKnownPeerTargetsDebug();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'targets': targets,
            }),
            headers: headers,
          );

        case 'dht_probe_once':
          await p2pService.runKnownPeerProbeNow();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Known-peer DHT probe completed',
            }),
            headers: headers,
          );

        case 'dht_geogram_query':
          final ip = params['ip'] as String?;
          final port = params['port'] as int?;
          if (ip == null || ip.isEmpty || port == null || port <= 0) {
            return shelf.Response(400,
              body: jsonEncode({
                'success': false,
                'error': 'ip and port parameters required',
              }),
              headers: headers,
            );
          }

          final response = await p2pService.sendGeogramQuery(ip, port);
          return shelf.Response.ok(
            jsonEncode({
              'success': response != null,
              'ip': ip,
              'port': port,
              'response': response,
            }),
            headers: headers,
          );

        case 'dht_geogram_punch':
          final ip = params['ip'] as String?;
          final port = params['port'] as int?;
          if (ip == null || ip.isEmpty || port == null || port <= 0) {
            return shelf.Response(400,
              body: jsonEncode({
                'success': false,
                'error': 'ip and port parameters required',
              }),
              headers: headers,
            );
          }

          final response = await p2pService.sendGeogramPunch(ip, port);
          return shelf.Response.ok(
            jsonEncode({
              'success': response != null,
              'ip': ip,
              'port': port,
              'response': response,
            }),
            headers: headers,
          );

        case 'dht_add_node':
          final ip = params['ip'] as String?;
          final port = params['port'] as int?;
          if (ip == null || port == null) {
            return shelf.Response(400,
              body: jsonEncode({
                'success': false,
                'error': 'ip and port parameters required',
              }),
              headers: headers,
            );
          }
          await p2pService.addNode(ip, port);
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Pinged DHT node $ip:$port',
            }),
            headers: headers,
          );

        default:
          return shelf.Response(400,
            body: jsonEncode({
              'success': false,
              'error': 'Unknown DHT action: $action',
              'available': [
                'dht_status',
                'dht_start',
                'dht_stop',
                'dht_find_user',
                'dht_find_user_light',
                'dht_known_targets',
                'dht_probe_once',
                'dht_geogram_query',
                'dht_geogram_punch',
                'dht_add_node',
              ],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: DHT action error: $e');
      LogService().log('Stack: $stack');
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
  // Debug API - Encrypted Storage Actions
  // ============================================================

  /// Handle encrypted storage debug actions
  Future<shelf.Response> _handleEncryptStorageAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final encryptedService = EncryptedStorageService();
      final profileService = ProfileService();
      final profile = profileService.getProfile();

      // Get nsec from params or profile
      final nsec = params['nsec'] as String? ?? profile.nsec;

      switch (action) {
        case 'encrypt_storage_status':
          final status = await encryptedService.getStatus(profile.callsign);
          return shelf.Response.ok(
            jsonEncode({
              ...status.toJson(),
              'has_nsec': nsec != null && nsec.isNotEmpty,
            }),
            headers: headers,
          );

        case 'encrypt_storage_enable':
          // Check if nsec is available
          if (nsec == null || nsec.isEmpty) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'Encryption requires nsec (NOSTR secret key)',
                'code': 'NSEC_REQUIRED',
              }),
              headers: headers,
            );
          }

          // Check if already using encrypted storage
          if (encryptedService.isEncryptedStorageEnabled(profile.callsign)) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'Profile is already using encrypted storage',
                'code': 'ALREADY_ENCRYPTED',
              }),
              headers: headers,
            );
          }

          // Migrate to encrypted storage
          LogService().log('LogApiService: Starting encrypted migration for ${profile.callsign}');
          final result = await encryptedService.migrateToEncrypted(profile.callsign, nsec);

          return shelf.Response.ok(
            jsonEncode(result.toJson()),
            headers: headers,
          );

        case 'encrypt_storage_disable':
          // Check if nsec is available
          if (nsec == null || nsec.isEmpty) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'Decryption requires nsec (NOSTR secret key)',
                'code': 'NSEC_REQUIRED',
              }),
              headers: headers,
            );
          }

          // Check if using encrypted storage
          if (!encryptedService.isEncryptedStorageEnabled(profile.callsign)) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'Profile is not using encrypted storage',
                'code': 'NOT_ENCRYPTED',
              }),
              headers: headers,
            );
          }

          // Migrate to folders
          LogService().log('LogApiService: Starting decryption for ${profile.callsign}');
          final result = await encryptedService.migrateToFolders(profile.callsign, nsec);

          return shelf.Response.ok(
            jsonEncode(result.toJson()),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown encrypted storage action: $action',
              'available': [
                'encrypt_storage_status',
                'encrypt_storage_enable',
                'encrypt_storage_disable',
              ],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Encrypted storage action error: $e');
      LogService().log('Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'error': e.toString(),
        }),
        headers: headers,
      );
    }
  }

  /// Handle shared folder debug actions
  Future<shelf.Response> _handleSharedAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final profileStorage = AppService().profileStorage;
      if (profileStorage == null) {
        return shelf.Response.ok(
          jsonEncode({'success': false, 'error': 'No profile storage'}),
          headers: headers,
        );
      }

      // Find shared app
      final apps = await AppService().loadApps();
      final sharedApp = apps.cast<App?>().firstWhere(
        (a) => a?.type == 'shared',
        orElse: () => null,
      );
      if (sharedApp?.storagePath == null) {
        return shelf.Response.ok(
          jsonEncode({'success': false, 'error': 'No shared app found'}),
          headers: headers,
        );
      }

      final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
        profileStorage, sharedApp!.storagePath!,
      );
      final service = SharedFolderService();
      service.setStorage(scopedStorage);
      await service.initializeApp(sharedApp.storagePath!);

      switch (action) {
        case 'shared_list':
          final folders = await service.loadAll();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'folders': folders.map((f) => {
                ...f.toJson(),
                'filePath': f.filePath,
              }).toList(),
            }),
            headers: headers,
          );

        case 'shared_test_cookie':
          // Test cookie parsing from headers string
          // Params: headers (raw header string to parse)
          final headersStr = params['headers'] as String?;
          final wsService = WebSocketService();
          final extracted = wsService.testExtractNostrPubkey(headersStr);
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'input': headersStr,
              'extractedPubkey': extracted,
            }),
            headers: headers,
          );

        case 'shared_test_access':
          // Test access control by simulating cookie-based access
          // Params: pubkey (optional hex pubkey to test)
          final testPubkey = params['pubkey'] as String?;
          final folders = await service.loadAll();
          final wsService = WebSocketService();

          final results = <Map<String, dynamic>>[];
          for (final folder in folders) {
            final accessible = folder.visibility == SharedFolderVisibility.public
                ? true
                : folder.visibility == SharedFolderVisibility.private_
                    ? false
                    : await wsService.testIsAuthorizedReader(folder, testPubkey);
            results.add({
              'title': folder.title,
              'visibility': folder.visibility.value,
              'accessible': accessible,
              'allowedReaders': folder.allowedReaders,
              'allowedGroups': folder.allowedGroups,
            });
          }
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'testPubkey': testPubkey,
              'results': results,
            }),
            headers: headers,
          );

        case 'shared_update':
          // Update a shared folder's fields (for testing save roundtrip)
          // Params: id (folder ID), allowedReaders (list of hex pubkeys), allowedGroups (list), visibility
          final folderId = params['id'] as String?;
          if (folderId == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Missing id parameter'}),
              headers: headers,
            );
          }
          final folders = await service.loadAll();
          final folder = folders.cast<SharedFolder?>().firstWhere(
            (f) => f?.id == folderId,
            orElse: () => null,
          );
          if (folder == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Folder not found: $folderId'}),
              headers: headers,
            );
          }
          final updated = folder.copyWith(
            visibility: params['visibility'] != null
                ? SharedFolderVisibility.fromValue(params['visibility'] as String)
                : null,
            allowedReaders: (params['allowedReaders'] as List<dynamic>?)?.cast<String>(),
            allowedGroups: (params['allowedGroups'] as List<dynamic>?)?.cast<String>(),
          );
          await service.update(updated);
          // Re-read to confirm
          final reloaded = await service.loadAll();
          final confirmed = reloaded.cast<SharedFolder?>().firstWhere(
            (f) => f?.id == folderId,
            orElse: () => null,
          );
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'folder': confirmed != null ? {
                ...confirmed.toJson(),
                'filePath': confirmed.filePath,
              } : null,
            }),
            headers: headers,
          );

        default:
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'Unknown shared action: $action',
              'available': ['shared_list', 'shared_test_access', 'shared_test_cookie', 'shared_update'],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Shared action error: $e');
      LogService().log('Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  Future<shelf.Response> _handleTelegramAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final cacheService = TelegramService().cacheService;

      // Connect Telegram service programmatically (for debug testing)
      if (action == 'telegram_connect') {
        if (cacheService != null) {
          return shelf.Response.ok(
            jsonEncode({'success': true, 'message': 'Already connected'}),
            headers: headers,
          );
        }
        try {
          final callsign = ProfileService().getProfile().callsign;
          final profileStorage = AppService().profileStorage;
          if (profileStorage == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'No profile storage'}),
              headers: headers,
            );
          }
          final service = TelegramService();
          service.setStorage(profileStorage);
          await service.initialize('teleport', callsign);
          await service.connect();
          return shelf.Response.ok(
            jsonEncode({'success': true, 'message': 'Telegram connected'}),
            headers: headers,
          );
        } catch (e) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'Connect failed: $e'}),
            headers: headers,
          );
        }
      }

      // For inspect, fall back to direct filesystem access when service isn't running
      if (action == 'telegram_cache_inspect' && cacheService == null) {
        final result = _inspectCacheFromFilesystem(params);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'note': 'offline inspection (service not running)', ...result}),
          headers: headers,
        );
      }

      if (cacheService == null) {
        return shelf.Response.ok(
          jsonEncode({'success': false, 'error': 'Telegram cache service not initialized'}),
          headers: headers,
        );
      }

      switch (action) {
        case 'telegram_load_chat':
          final chatIdParam = params['chat_id'];
          final chatId = chatIdParam is int
              ? chatIdParam
              : chatIdParam is String
                  ? int.tryParse(chatIdParam)
                  : null;
          if (chatId == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'chat_id required'}),
              headers: headers,
            );
          }
          try {
            final chatService = TelegramService().chatService;
            if (chatService == null) {
              return shelf.Response.ok(
                jsonEncode({'success': false, 'error': 'Chat service not available'}),
                headers: headers,
              );
            }
            await chatService.openChat(chatId);
            final messages = await chatService.getChatHistory(chatId);
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'chat_id': chatId,
                'messages_loaded': messages.length,
                'media_messages': messages.where((m) => m.media != null).length,
              }),
              headers: headers,
            );
          } catch (e) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Load failed: $e'}),
              headers: headers,
            );
          }

        case 'telegram_cache_inspect':
          final chatIdParam = params['chat_id'];
          final chatId = chatIdParam is int
              ? chatIdParam
              : chatIdParam is String
                  ? int.tryParse(chatIdParam)
                  : null;
          final result = cacheService.inspectCache(chatId: chatId);
          return shelf.Response.ok(
            jsonEncode({'success': true, ...result}),
            headers: headers,
          );

        case 'telegram_cache_clear':
          final chatIdParam = params['chat_id'];
          final chatId = chatIdParam is int
              ? chatIdParam
              : chatIdParam is String
                  ? int.tryParse(chatIdParam)
                  : null;
          final result = cacheService.clearCache(chatId: chatId);
          return shelf.Response.ok(
            jsonEncode({'success': true, ...result}),
            headers: headers,
          );

        default:
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'Unknown telegram action: $action'}),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Telegram action error: $e');
      LogService().log('Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Offline cache inspection — reads DB files directly from the profile directory.
  Map<String, dynamic> _inspectCacheFromFilesystem(Map<String, dynamic> params) {
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) {
      return {'error': 'No profile storage'};
    }

    // Find the telegram cache dir
    final basePath = profileStorage.getAbsolutePath('');
    final cacheDir = io.Directory(path.join(basePath, 'teleport', 'telegram', 'cache'));
    if (!cacheDir.existsSync()) {
      return {'error': 'Cache directory does not exist', 'path': cacheDir.path};
    }

    final chatIdParam = params['chat_id'];
    final chatId = chatIdParam is int
        ? chatIdParam
        : chatIdParam is String
            ? int.tryParse(chatIdParam)
            : null;

    if (chatId != null) {
      final dbPath = path.join(cacheDir.path, 'chat_$chatId.db');
      final dbFile = io.File(dbPath);
      if (!dbFile.existsSync()) {
        return {'error': 'No cache DB for chat $chatId'};
      }
      try {
        final db = SQLiteLoader.openDatabase(dbPath);
        try {
          final countResult = db.select('SELECT count(*) as cnt FROM messages');
          final count = countResult.first['cnt'] as int;
          final sample = db.select(
            'SELECT id, content_type, date, media_file_id, media_local_path '
            'FROM messages ORDER BY date DESC LIMIT 5',
          );
          final rows = sample
              .map((r) => {
                    'id': r['id'],
                    'content_type': r['content_type'],
                    'date': r['date'],
                    'media_file_id': r['media_file_id'],
                    'media_local_path': r['media_local_path'],
                  })
              .toList();
          return {'chat_id': chatId, 'message_count': count, 'sample': rows};
        } finally {
          db.dispose();
        }
      } catch (e) {
        return {'error': 'Failed to inspect chat $chatId: $e'};
      }
    }

    // List all DB files
    final files = cacheDir
        .listSync()
        .whereType<io.File>()
        .where((f) => f.path.endsWith('.db'))
        .map((f) => {
              'name': f.uri.pathSegments.last,
              'size_bytes': f.lengthSync(),
            })
        .toList();
    return {'cache_dir': cacheDir.path, 'databases': files};
  }

  Future<shelf.Response> _handleSignalAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final service = SignalService();

      switch (action) {
        case 'signal_connect':
          if (service.isRunning) {
            // Already running — trigger requestLinkDevice if not yet ready
            if (service.authState.state != SignalAuthState.ready) {
              await service.authService?.requestLinkDevice();
              await Future.delayed(const Duration(seconds: 3));
            }
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'message': 'Already connected',
                'auth_state': service.authState.state.name,
              }),
              headers: headers,
            );
          }
          try {
            final callsign = ProfileService().getProfile().callsign;
            final profileStorage = AppService().profileStorage;
            if (profileStorage == null) {
              return shelf.Response.ok(
                jsonEncode({'success': false, 'error': 'No profile storage'}),
                headers: headers,
              );
            }
            service.setStorage(profileStorage);
            await service.initialize('teleport', callsign);
            await service.connect();
            // Also trigger requestLinkDevice — detects existing
            // registration and starts the receive loop
            await service.authService?.requestLinkDevice();
            // Wait briefly for auth state to propagate
            await Future.delayed(const Duration(seconds: 3));
            final authState = service.authState.state.name;
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'message': 'Signal connected',
                'auth_state': authState,
              }),
              headers: headers,
            );
          } catch (e) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Connect failed: $e'}),
              headers: headers,
            );
          }

        case 'signal_status':
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'running': service.isRunning,
              'auth_state': service.authService?.currentState?.state.name,
            }),
            headers: headers,
          );

        case 'signal_conversations':
          try {
            final chatService = service.chatService;
            if (chatService == null) {
              return shelf.Response.ok(
                jsonEncode({'success': false, 'error': 'Chat service not available'}),
                headers: headers,
              );
            }
            final conversations = await chatService.loadConversations();
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'total': conversations.length,
                'conversations': conversations
                    .map((c) => {
                        'id': c.id,
                        'title': c.title,
                        'type': c.type.name,
                        'phone_number': c.phoneNumber,
                        'member_count': c.memberCount,
                        'unread_count': c.unreadCount,
                    })
                    .toList(),
              }),
              headers: headers,
            );
          } catch (e) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Failed: $e'}),
              headers: headers,
            );
          }

        case 'signal_load_chat':
          final chatId = (params['conversation_id'] ?? params['chat_id']) as String?;
          if (chatId == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'conversation_id required'}),
              headers: headers,
            );
          }
          try {
            final chatService = service.chatService;
            if (chatService == null) {
              return shelf.Response.ok(
                jsonEncode({'success': false, 'error': 'Chat service not available'}),
                headers: headers,
              );
            }
            final messages = await chatService.getMessages(chatId);
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'conversation_id': chatId,
                'messages_loaded': messages.length,
                'messages': messages.map((m) => {
                  'text': m.text,
                  'sender': m.senderName ?? m.senderUuid,
                  'timestamp': m.timestamp,
                  'content_type': m.contentType,
                  'is_outgoing': m.isOutgoing,
                  'sender_uuid': m.senderUuid,
                }).toList(),
              }),
              headers: headers,
            );
          } catch (e) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Load failed: $e'}),
              headers: headers,
            );
          }

        case 'signal_cache_inspect':
          final cacheService = service.cacheService;
          if (cacheService == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Signal cache service not initialized'}),
              headers: headers,
            );
          }
          final chatId = params['chat_id'] as String?;
          final result = cacheService.inspectCache(conversationId: chatId);
          return shelf.Response.ok(
            jsonEncode({'success': true, ...result}),
            headers: headers,
          );

        case 'signal_cache_clear':
          final cacheService = service.cacheService;
          if (cacheService == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Signal cache service not initialized'}),
              headers: headers,
            );
          }
          final chatId = params['chat_id'] as String?;
          final result = cacheService.clearCache(conversationId: chatId);
          return shelf.Response.ok(
            jsonEncode({'success': true, ...result}),
            headers: headers,
          );

        case 'signal_send':
          final chatId = (params['conversation_id'] ?? params['chat_id']) as String?;
          final text = params['text'] as String?;
          if (chatId == null || text == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'conversation_id and text required'}),
              headers: headers,
            );
          }
          try {
            final chatService = service.chatService;
            if (chatService == null) {
              return shelf.Response.ok(
                jsonEncode({'success': false, 'error': 'Chat service not available'}),
                headers: headers,
              );
            }
            final msg = await chatService.sendMessage(chatId, text);
            return shelf.Response.ok(
              jsonEncode({
                'success': true,
                'chat_id': chatId,
                'text': text,
                'message': msg != null
                    ? {
                        'text': msg.text,
                        'timestamp': msg.timestamp,
                        'is_outgoing': msg.isOutgoing,
                        'sender_uuid': msg.senderUuid,
                        'content_type': msg.contentType,
                      }
                    : null,
              }),
              headers: headers,
            );
          } catch (e) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Send failed: $e'}),
              headers: headers,
            );
          }

        default:
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'Unknown signal action: $action'}),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Signal action error: $e');
      LogService().log('Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  // ============================================================
  // APRS Debug Actions
  // ============================================================

  Future<shelf.Response> _handleAprsAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final aprs = AprsService();
      switch (action) {
        case 'aprs_status':
          // Use saved APRS position first, then LocationProvider, then UserLocation.
          final myLat = aprs.savedLatitude ??
              LocationProviderService().currentPosition?.latitude ??
              UserLocationService().currentLocation?.latitude;
          final myLon = aprs.savedLongitude ??
              LocationProviderService().currentPosition?.longitude ??
              UserLocationService().currentLocation?.longitude;
          final myLocSource = aprs.hasLocation
              ? 'saved'
              : (LocationProviderService().currentPosition?.source ??
                  UserLocationService().currentLocation?.source);

          // Include last 5 stream packets with parsed positions + distance
          final recentStream = <Map<String, dynamic>>[];
          final pkts = aprs.streamPackets;
          for (int i = pkts.length - 1; i >= 0 && recentStream.length < 5; i--) {
            final p = pkts[i];
            double? distKm;
            if (p.hasPosition && myLat != null && myLon != null) {
              distKm = _aprsHaversineKm(myLat, myLon, p.latitude!, p.longitude!);
            }
            recentStream.add({
              'from': p.fromCallsign,
              'type': p.type.name,
              'lat': p.latitude,
              'lon': p.longitude,
              'distKm': distKm != null ? (distKm * 10).round() / 10.0 : null,
              'info': p.infoField.length > 60
                  ? '${p.infoField.substring(0, 60)}...'
                  : p.infoField,
            });
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'enabled': aprs.isEnabled,
              'connected': aprs.isRunning,
              'radiusKm': aprs.radiusKm,
              'myLat': myLat,
              'myLon': myLon,
              'myLocSource': myLocSource,
              'streamPackets': aprs.streamPackets.length,
              'messages': aprs.messages.length,
              'knownPositions': aprs.lastKnownPositions.length,
              'recentStream': recentStream,
            }),
            headers: headers,
          );

        case 'aprs_set_radius':
          final radius = (params['radiusKm'] as num?)?.toDouble();
          if (radius == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'radiusKm required'}),
              headers: headers,
            );
          }
          aprs.radiusKm = radius;
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'radiusKm': aprs.radiusKm,
            }),
            headers: headers,
          );

        case 'aprs_set_location':
          final lat = (params['lat'] as num?)?.toDouble();
          final lon = (params['lon'] as num?)?.toDouble();
          if (lat == null || lon == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'lat and lon required'}),
              headers: headers,
            );
          }
          // Set location on both services — AprsService for immediate
          // filter update, UserLocationService for UI display.
          aprs.setLocation(lat, lon);
          UserLocationService().setManualLocation(lat, lon);
          return shelf.Response.ok(
            jsonEncode({'success': true, 'lat': lat, 'lon': lon}),
            headers: headers,
          );

        case 'aprs_enable':
          if (!aprs.hasLocation) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Set location first'}),
              headers: headers,
            );
          }
          if (!aprs.isEnabled) {
            final profileStorage = AppService().profileStorage;
            if (profileStorage != null) aprs.setStorage(profileStorage);
            final profile = ProfileService().getProfile();
            aprs.enable(callsign: profile.fullCallsign);
          }
          return shelf.Response.ok(
            jsonEncode({'success': true, 'enabled': aprs.isEnabled}),
            headers: headers,
          );

        case 'aprs_disable':
          aprs.disable();
          return shelf.Response.ok(
            jsonEncode({'success': true, 'enabled': aprs.isEnabled}),
            headers: headers,
          );

        case 'aprs_cache_inspect':
          final cache = aprs.cacheService;
          if (cache == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Cache not initialized'}),
              headers: headers,
            );
          }
          final info = await cache.inspect();
          return shelf.Response.ok(
            jsonEncode({'success': true, ...info}),
            headers: headers,
          );

        case 'aprs_cache_clear':
          final cache = aprs.cacheService;
          if (cache == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'Cache not initialized'}),
              headers: headers,
            );
          }
          await cache.clear();
          return shelf.Response.ok(
            jsonEncode({'success': true}),
            headers: headers,
          );

        case 'aprs_logs':
          final allLogs = LogService().messages;
          final aprsLogs = allLogs
              .where((l) {
                final low = l.toLowerCase();
                return low.contains('aprs') ||
                    low.contains('filter') ||
                    low.contains('userlocation') ||
                    low.contains('geoip') ||
                    low.contains('geolocation') ||
                    low.contains('[location]') ||
                    low.contains('locationprovider') ||
                    low.contains('public ip');
              })
              .toList();
          // Return last 30 APRS-related log entries
          final recent = aprsLogs.length > 30
              ? aprsLogs.sublist(aprsLogs.length - 30)
              : aprsLogs;
          return shelf.Response.ok(
            jsonEncode({'success': true, 'count': recent.length, 'logs': recent}),
            headers: headers,
          );

        case 'aprs_send':
          final destination = params['destination'] as String?;
          final text = params['text'] as String?;
          if (destination == null || text == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'destination and text required'}),
              headers: headers,
            );
          }
          if (!aprs.isEnabled || !aprs.isRunning) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'APRS not connected'}),
              headers: headers,
            );
          }
          final maxChunk = aprsAvailableChars(
            destination.startsWith('#') ? destination : null,
          );
          final parts = aprsPartCount(text, maxChunk);
          final sent = aprs.sendMessage(destination, text);
          return shelf.Response.ok(
            jsonEncode({
              'success': sent != null,
              'destination': destination,
              'text': text,
              'messageId': sent?.messageId,
              'parts': parts,
            }),
            headers: headers,
          );

        case 'aprs_send_oneshot':
          final destination = params['destination'] as String?;
          final text = params['text'] as String?;
          final callsign = params['callsign'] as String? ?? aprs.callsign;
          if (destination == null || text == null || callsign == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'callsign, destination and text required'}),
              headers: headers,
            );
          }
          final result = await AprsIsClient.sendOneShot(
            callsign: callsign,
            destination: destination,
            message: text,
          );
          return shelf.Response.ok(
            jsonEncode({'success': result['sent'] == true, ...result}),
            headers: headers,
          );

        case 'aprs_geochat':
          final myLat = aprs.savedLatitude;
          final myLon = aprs.savedLongitude;
          final chatMsgs = aprs.geoChatMessages.map((m) {
            double? distKm;
            if (m.hasPosition && myLat != null && myLon != null) {
              distKm = _aprsHaversineKm(myLat, myLon, m.latitude!, m.longitude!);
            }
            return {
              'sender': m.fromCallsign,
              'lat': m.latitude,
              'lon': m.longitude,
              'comment': m.comment,
              'timestamp': m.timestamp.toIso8601String(),
              'isOutgoing': m.isOutgoing,
              'distKm': distKm != null ? (distKm * 10).round() / 10.0 : null,
            };
          }).toList();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'count': chatMsgs.length,
              'messages': chatMsgs,
            }),
            headers: headers,
          );

        case 'aprs_clear_geochat':
          aprs.clearGeoChat();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'count': aprs.geoChatMessages.length,
            }),
            headers: headers,
          );

        case 'aprs_inject_geochat':
          final from = params['from'] as String?;
          final comment = params['comment'] as String?;
          if (from == null || comment == null || comment.isEmpty) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'from and comment required',
              }),
              headers: headers,
            );
          }
          final lat =
              (params['lat'] as num?)?.toDouble() ?? aprs.savedLatitude ?? 0.0;
          final lon =
              (params['lon'] as num?)?.toDouble() ?? aprs.savedLongitude ?? 0.0;
          final minutesAgo = (params['minutesAgo'] as num?)?.toDouble() ?? 0.0;
          final timestamp = DateTime.now().toUtc().subtract(
            Duration(milliseconds: (minutesAgo * 60000).round()),
          );
          final infoField =
              '!${lat.toStringAsFixed(5)}/${lon.toStringAsFixed(5)}\$$comment';
          final packet = AprsPacket(
            fromCallsign: from,
            toCallsign: 'APRS',
            infoField: infoField,
            rawTnc2: '$from>APRS:$infoField',
            timestamp: timestamp,
            type: AprsPacketType.position,
            latitude: lat,
            longitude: lon,
            comment: comment,
          );

          aprs.addPacket(packet);

          final matchingVisible = aprs.geoChatMessages.any((msg) =>
              !msg.isOutgoing &&
              msg.fromCallsign == from &&
              msg.comment == comment);
          final nowItems = NowService().items
              .where((item) =>
                  item.appType == 'aprs' &&
                  item.sourceId == 'geochat' &&
                  item.callsign == from &&
                  item.summary == comment)
              .length;

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'from': from,
              'comment': comment,
              'timestamp': timestamp.toIso8601String(),
              'visibleInGeoChat': matchingVisible,
              'geoChatCount': aprs.geoChatMessages.length,
              'nowItems': nowItems,
            }),
            headers: headers,
          );

        case 'aprs_send_geochat':
          final text = params['text'] as String?;
          if (text == null || text.isEmpty) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'text required'}),
              headers: headers,
            );
          }
          if (!aprs.isEnabled || !aprs.isRunning) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'APRS not connected'}),
              headers: headers,
            );
          }
          final sent = aprs.sendGeoChat(text);
          return shelf.Response.ok(
            jsonEncode({
              'success': sent != null,
              'text': text,
              'lat': sent?.latitude,
              'lon': sent?.longitude,
            }),
            headers: headers,
          );

        case 'aprs_conversations':
          final convos = aprs.getConversations();
          final list = convos.map((c) => {
            'id': c.id,
            'type': c.type.name,
            'messageCount': c.messageCount,
            'lastMessage': c.lastMessage?.messageText,
            'lastMessageTime': c.lastMessageTime?.toIso8601String(),
          }).toList();
          return shelf.Response.ok(
            jsonEncode({'success': true, 'conversations': list}),
            headers: headers,
          );

        case 'aprs_tags':
          final op = params['op'] as String? ?? 'list';
          final tag = params['tag'] as String?;
          switch (op) {
            case 'add':
              if (tag == null) {
                return shelf.Response.ok(
                  jsonEncode({'success': false, 'error': 'tag required'}),
                  headers: headers,
                );
              }
              aprs.addTag(tag);
              return shelf.Response.ok(
                jsonEncode({'success': true, 'tags': aprs.subscribedTags.toList()}),
                headers: headers,
              );
            case 'remove':
              if (tag == null) {
                return shelf.Response.ok(
                  jsonEncode({'success': false, 'error': 'tag required'}),
                  headers: headers,
                );
              }
              aprs.removeTag(tag);
              return shelf.Response.ok(
                jsonEncode({'success': true, 'tags': aprs.subscribedTags.toList()}),
                headers: headers,
              );
            default:
              return shelf.Response.ok(
                jsonEncode({'success': true, 'tags': aprs.subscribedTags.toList()}),
                headers: headers,
              );
          }

        default:
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'Unknown APRS action: $action'}),
            headers: headers,
          );
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  static double _aprsHaversineKm(
    double lat1, double lon1, double lat2, double lon2,
  ) {
    const earthRadius = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
        sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  // ============================================================
  // BlueAPRS Debug Actions
  // ============================================================

  shelf.Response _handleBlueAprsAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) {
    try {
      final blueAprs = BlueAprsService();

      switch (action) {
        case 'blue_aprs_status':
          return shelf.Response.ok(
            jsonEncode({'success': true, ...blueAprs.getStatus()}),
            headers: headers,
          );

        case 'blue_aprs_register_client':
          final deviceId = params['deviceId'] as String?;
          final callsign = params['callsign'] as String?;
          if (deviceId == null || callsign == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'deviceId and callsign required'}),
              headers: headers,
            );
          }
          final result = blueAprs.registerSimulatedClient(
            deviceId: deviceId,
            callsign: callsign,
          );
          return shelf.Response.ok(
            jsonEncode(result),
            headers: headers,
          );

        case 'blue_aprs_inject_ble':
          final callsign = params['callsign'] as String?;
          final text = params['text'] as String? ?? '';
          final type = params['type'] as String? ?? 'message';
          final to = params['to'] as String?;
          final lat = (params['lat'] as num?)?.toDouble();
          final lon = (params['lon'] as num?)?.toDouble();
          final comment = params['comment'] as String?;
          if (callsign == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'callsign required'}),
              headers: headers,
            );
          }
          if (!blueAprs.isActive) {
            // Auto-activate if APRS is enabled
            if (AprsService().isEnabled) {
              blueAprs.activate();
            } else {
              return shelf.Response.ok(
                jsonEncode({'success': false, 'error': 'BlueAPRS not active (enable APRS first)'}),
                headers: headers,
              );
            }
          }
          final payload = BLEAprsPayload(
            to: to,
            text: text,
            type: type,
            lat: lat,
            lon: lon,
            comment: comment,
          );
          final result = blueAprs.injectBleAprsMessage(
            callsign: callsign,
            payload: payload,
          );
          return shelf.Response.ok(
            jsonEncode(result),
            headers: headers,
          );

        case 'blue_aprs_inject_aprs':
          final from = params['from'] as String?;
          final to = params['to'] as String?;
          final text = params['text'] as String?;
          final lat = (params['lat'] as num?)?.toDouble();
          final lon = (params['lon'] as num?)?.toDouble();
          if (from == null || to == null || text == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'from, to, and text required'}),
              headers: headers,
            );
          }
          if (!blueAprs.isActive) {
            if (AprsService().isEnabled) {
              blueAprs.activate();
            } else {
              return shelf.Response.ok(
                jsonEncode({'success': false, 'error': 'BlueAPRS not active (enable APRS first)'}),
                headers: headers,
              );
            }
          }
          final result = blueAprs.injectAprsPacket(
            from: from,
            to: to,
            text: text,
            lat: lat,
            lon: lon,
          );
          return shelf.Response.ok(
            jsonEncode(result),
            headers: headers,
          );

        case 'blue_aprs_client_inbox':
          final deviceId = params['deviceId'] as String?;
          if (deviceId == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'deviceId required'}),
              headers: headers,
            );
          }
          final result = blueAprs.getClientInbox(deviceId);
          return shelf.Response.ok(
            jsonEncode(result),
            headers: headers,
          );

        case 'blue_aprs_enable':
          final enabled = params['enabled'] as bool? ?? true;
          AprsService().blueAprsEnabled = enabled;
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'blueAprsEnabled': AprsService().blueAprsEnabled,
              'active': blueAprs.isActive,
            }),
            headers: headers,
          );

        case 'blue_aprs_beacon':
          final enabled = params['enabled'] as bool? ?? true;
          final intervalSec = params['intervalSec'] as int? ?? 300;
          final aprs = AprsService();
          if (enabled) {
            aprs.blueAprsBeaconIntervalSec = intervalSec;
            aprs.blueAprsBeaconEnabled = true;
          } else {
            aprs.blueAprsBeaconEnabled = false;
          }
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'beaconEnabled': aprs.blueAprsBeaconEnabled,
              'beaconIntervalSec': aprs.blueAprsBeaconIntervalSec,
              ...blueAprs.getStatus(),
            }),
            headers: headers,
          );

        default:
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'Unknown BlueAPRS action: $action'}),
            headers: headers,
          );
      }
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  // ============================================================
  // IRC Debug Actions
  // ============================================================

  Future<shelf.Response> _handleIrcAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    final irc = IrcService();

    switch (action) {
      case 'irc_status':
        return shelf.Response.ok(
          jsonEncode({'success': true, ...irc.getStatus()}),
          headers: headers,
        );

      case 'irc_connect':
        final serverId = params['serverId'] as String?;
        if (serverId == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId required'}),
            headers: headers,
          );
        }
        irc.connect(serverId);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'connecting', 'serverId': serverId}),
          headers: headers,
        );

      case 'irc_disconnect':
        final serverId = params['serverId'] as String?;
        if (serverId == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId required'}),
            headers: headers,
          );
        }
        irc.disconnect(serverId);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'disconnected', 'serverId': serverId}),
          headers: headers,
        );

      case 'irc_join':
        final serverId = params['serverId'] as String?;
        final channel = params['channel'] as String?;
        if (serverId == null || channel == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId and channel required'}),
            headers: headers,
          );
        }
        irc.joinChannel(serverId, channel);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'joining', 'channel': channel}),
          headers: headers,
        );

      case 'irc_part':
        final serverId = params['serverId'] as String?;
        final channel = params['channel'] as String?;
        if (serverId == null || channel == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId and channel required'}),
            headers: headers,
          );
        }
        irc.partChannel(serverId, channel);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'parting', 'channel': channel}),
          headers: headers,
        );

      case 'irc_send':
        final serverId = params['serverId'] as String?;
        final target = params['target'] as String? ?? params['channel'] as String?;
        final text = params['text'] as String?;
        if (serverId == null || target == null || text == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId, target, and text required'}),
            headers: headers,
          );
        }
        final msg = irc.sendMessage(serverId, target, text);
        return shelf.Response.ok(
          jsonEncode({'success': msg != null, 'sent': msg != null}),
          headers: headers,
        );

      case 'irc_list':
        final serverId = params['serverId'] as String?;
        if (serverId == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId required'}),
            headers: headers,
          );
        }
        irc.requestChannelList(serverId);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'requesting channel list'}),
          headers: headers,
        );

      case 'irc_add_server':
        final name = params['name'] as String?;
        final host = params['host'] as String?;
        if (name == null || host == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'name and host required'}),
            headers: headers,
          );
        }
        final port = (params['port'] as num?)?.toInt() ?? 6697;
        final useTls = params['useTls'] as bool? ?? true;
        final id = '${host}_${DateTime.now().millisecondsSinceEpoch}';
        final config = IrcServerConfig(
          id: id,
          name: name,
          host: host,
          port: port,
          useTls: useTls,
          password: params['password'] as String?,
          autoJoinChannels: (params['autoJoinChannels'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [],
          autoConnect: params['autoConnect'] as bool? ?? false,
        );
        await irc.addServer(config);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'serverId': id}),
          headers: headers,
        );

      case 'irc_load_chat':
        final loadServerId = params['serverId'] as String?;
        final loadChannel = params['channel'] as String?;
        if (loadServerId == null || loadChannel == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId and channel required'}),
            headers: headers,
          );
        }
        await irc.loadCachedMessages(loadServerId, loadChannel);
        irc.markChannelRead(loadServerId, loadChannel);
        final msgs = irc.getMessages(loadServerId, loadChannel);
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'channel': loadChannel,
            'messagesLoaded': msgs.length,
            'messages': msgs.take(30).map((m) => {
                  'sender': m.sender,
                  'text': m.text.length > 80 ? m.text.substring(0, 80) : m.text,
                  'isOutgoing': m.isOutgoing,
                  'type': m.type.name,
                  'timestamp': m.timestamp.toIso8601String(),
                }).toList(),
          }),
          headers: headers,
        );

      case 'irc_cache_inspect':
        final cache = irc.cacheService;
        if (cache == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'cache not initialized'}),
            headers: headers,
          );
        }
        final info = await cache.inspect();
        return shelf.Response.ok(
          jsonEncode({'success': true, ...info}),
          headers: headers,
        );

      case 'irc_cache_clear':
        final cache = irc.cacheService;
        if (cache == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'cache not initialized'}),
            headers: headers,
          );
        }
        await cache.clear();
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'cleared'}),
          headers: headers,
        );

      default:
        return shelf.Response.ok(
          jsonEncode({'success': false, 'error': 'Unknown IRC action: $action'}),
          headers: headers,
        );
    }
  }

  // ============================================================
  // XMPP Server Debug Actions
  // ============================================================

  Future<shelf.Response> _handleXmppServerAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    final xmppServer = XmppServer.instance;

    switch (action) {
      case 'xmpp_server_status':
        if (xmppServer == null) {
          return shelf.Response.ok(
            jsonEncode({'success': true, 'running': false, 'enabled': false}),
            headers: {'content-type': 'application/json'},
          );
        }
        return shelf.Response.ok(
          jsonEncode({'success': true, ...xmppServer.getStatus()}),
          headers: {'content-type': 'application/json'},
        );

      case 'xmpp_server_register':
        final username = params['username'] as String?;
        final password = params['password'] as String?;
        if (username == null || password == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'username and password required'}),
            headers: {'content-type': 'application/json'},
          );
        }
        if (xmppServer == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'XMPP server not running'}),
            headers: {'content-type': 'application/json'},
          );
        }
        final registered = await xmppServer.registerUser(username, password);
        return shelf.Response.ok(
          jsonEncode({
            'success': registered,
            'error': registered ? null : 'Registration failed (username may be taken)',
            'jid': registered ? '$username@${xmppServer.domain}' : null,
          }),
          headers: {'content-type': 'application/json'},
        );

      case 'xmpp_server_users':
        if (xmppServer == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'XMPP server not running'}),
            headers: {'content-type': 'application/json'},
          );
        }
        return shelf.Response.ok(
          jsonEncode({'success': true, 'users': xmppServer.listUsers()}),
          headers: {'content-type': 'application/json'},
        );

      case 'xmpp_server_rooms':
        if (xmppServer == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'XMPP server not running'}),
            headers: {'content-type': 'application/json'},
          );
        }
        return shelf.Response.ok(
          jsonEncode({'success': true, 'rooms': xmppServer.listRooms()}),
          headers: {'content-type': 'application/json'},
        );

      case 'xmpp_server_kick':
        final roomJid = params['roomJid'] as String?;
        final bareJid = params['bareJid'] as String?;
        if (roomJid == null || bareJid == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'roomJid and bareJid required'}),
            headers: {'content-type': 'application/json'},
          );
        }
        if (xmppServer == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'XMPP server not running'}),
            headers: {'content-type': 'application/json'},
          );
        }
        final kicked = xmppServer.kickFromRoom(roomJid, bareJid);
        return shelf.Response.ok(
          jsonEncode({'success': kicked, 'error': kicked ? null : 'User not found in room'}),
          headers: {'content-type': 'application/json'},
        );

      case 'xmpp_server_s2s_status':
        if (xmppServer == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'XMPP server not running'}),
            headers: {'content-type': 'application/json'},
          );
        }
        final s2sStatus = xmppServer.getS2sStatus();
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            's2s_enabled': xmppServer.s2sEnabled,
            ...?s2sStatus,
          }),
          headers: {'content-type': 'application/json'},
        );

      case 'xmpp_server_s2s_connect':
        final domain = params['domain'] as String?;
        if (domain == null || domain.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'domain required'}),
            headers: {'content-type': 'application/json'},
          );
        }
        if (xmppServer == null || xmppServer.s2sManager == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'XMPP S2S not running'}),
            headers: {'content-type': 'application/json'},
          );
        }
        final result = await xmppServer.s2sManager!.testConnect(domain);
        return shelf.Response.ok(
          jsonEncode(result),
          headers: {'content-type': 'application/json'},
        );

      case 'xmpp_server_s2s_test':
        final domain = params['domain'] as String?;
        if (domain == null || domain.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'domain required'}),
            headers: {'content-type': 'application/json'},
          );
        }
        if (xmppServer == null || xmppServer.s2sManager == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'XMPP S2S not running'}),
            headers: {'content-type': 'application/json'},
          );
        }
        // Test by initiating connection and checking state
        final testResult = await xmppServer.s2sManager!.testConnect(domain);
        final status = xmppServer.s2sManager!.getStatus();
        return shelf.Response.ok(
          jsonEncode({
            ...testResult,
            'connections': status,
          }),
          headers: {'content-type': 'application/json'},
        );

      default:
        return shelf.Response.ok(
          jsonEncode({'success': false, 'error': 'Unknown xmpp_server action: $action'}),
          headers: {'content-type': 'application/json'},
        );
    }
  }

  // ============================================================
  // XMPP Debug Actions
  // ============================================================

  Future<shelf.Response> _handleXmppAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    final xmpp = XmppService();

    switch (action) {
      case 'xmpp_status':
        return shelf.Response.ok(
          jsonEncode({'success': true, ...xmpp.getStatus()}),
          headers: headers,
        );

      case 'xmpp_connect':
        final serverId = params['serverId'] as String?;
        if (serverId == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId required'}),
            headers: headers,
          );
        }
        xmpp.connect(serverId);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'connecting', 'serverId': serverId}),
          headers: headers,
        );

      case 'xmpp_disconnect':
        final serverId = params['serverId'] as String?;
        if (serverId == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId required'}),
            headers: headers,
          );
        }
        await xmpp.disconnectServer(serverId);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'disconnected', 'serverId': serverId}),
          headers: headers,
        );

      case 'xmpp_join':
        final serverId = params['serverId'] as String?;
        final roomJid = params['roomJid'] as String?;
        if (serverId == null || roomJid == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId and roomJid required'}),
            headers: headers,
          );
        }
        xmpp.joinRoom(serverId, roomJid);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'joining', 'roomJid': roomJid}),
          headers: headers,
        );

      case 'xmpp_part':
        final serverId = params['serverId'] as String?;
        final roomJid = params['roomJid'] as String?;
        if (serverId == null || roomJid == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId and roomJid required'}),
            headers: headers,
          );
        }
        xmpp.leaveRoom(serverId, roomJid);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'leaving', 'roomJid': roomJid}),
          headers: headers,
        );

      case 'xmpp_send':
        final serverId = params['serverId'] as String?;
        final roomJid = params['roomJid'] as String?;
        final text = params['text'] as String?;
        if (serverId == null || roomJid == null || text == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId, roomJid, and text required'}),
            headers: headers,
          );
        }
        final msg = xmpp.sendMessage(serverId, roomJid, text);
        return shelf.Response.ok(
          jsonEncode({'success': msg != null, 'sent': msg != null}),
          headers: headers,
        );

      case 'xmpp_discover':
        final serverId = params['serverId'] as String?;
        if (serverId == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId required'}),
            headers: headers,
          );
        }
        xmpp.discoverRooms(serverId);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'discovering rooms'}),
          headers: headers,
        );

      case 'xmpp_register':
        final regHost = params['host'] as String?;
        if (regHost == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'host required'}),
            headers: headers,
          );
        }
        final regResult = await xmpp.registerAccount(
          host: regHost,
          port: (params['port'] as num?)?.toInt() ?? 5222,
          username: params['username'] as String?,
          password: params['password'] as String?,
          directTls: params['directTls'] as bool? ?? false,
          conferenceService: params['conferenceService'] as String?,
          autoConnect: params['autoConnect'] as bool? ?? true,
        );
        return shelf.Response.ok(
          jsonEncode(regResult),
          headers: headers,
        );

      case 'xmpp_add_server':
        final name = params['name'] as String?;
        final host = params['host'] as String?;
        final jid = params['jid'] as String?;
        if (name == null || host == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'name and host required'}),
            headers: headers,
          );
        }
        final port = (params['port'] as num?)?.toInt() ?? 5222;
        final id = '${host}_${DateTime.now().millisecondsSinceEpoch}';
        final config = XmppServerConfig(
          id: id,
          name: name,
          host: host,
          port: port,
          directTls: params['directTls'] as bool? ?? false,
          jid: jid,
          password: params['password'] as String?,
          conferenceService: params['conferenceService'] as String?,
          autoJoinRooms: (params['autoJoinRooms'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [],
          autoConnect: params['autoConnect'] as bool? ?? false,
        );
        await xmpp.addServer(config);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'serverId': id}),
          headers: headers,
        );

      case 'xmpp_load_chat':
        final loadServerId = params['serverId'] as String?;
        final loadRoomJid = params['roomJid'] as String?;
        if (loadServerId == null || loadRoomJid == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'serverId and roomJid required'}),
            headers: headers,
          );
        }
        await xmpp.loadCachedMessages(loadServerId, loadRoomJid);
        xmpp.markRoomRead(loadServerId, loadRoomJid);
        final msgs = xmpp.getMessages(loadServerId, loadRoomJid);
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'roomJid': loadRoomJid,
            'messagesLoaded': msgs.length,
            'messages': msgs.take(30).map((m) => {
                  'sender': m.sender,
                  'text': m.text.length > 80 ? m.text.substring(0, 80) : m.text,
                  'isOutgoing': m.isOutgoing,
                  'type': m.type.name,
                  'timestamp': m.timestamp.toIso8601String(),
                }).toList(),
          }),
          headers: headers,
        );

      case 'xmpp_cache_inspect':
        final cache = xmpp.cacheService;
        if (cache == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'cache not initialized'}),
            headers: headers,
          );
        }
        final info = await cache.inspect();
        return shelf.Response.ok(
          jsonEncode({'success': true, ...info}),
          headers: headers,
        );

      case 'xmpp_cache_clear':
        final cache = xmpp.cacheService;
        if (cache == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'cache not initialized'}),
            headers: headers,
          );
        }
        await cache.clear();
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'cleared'}),
          headers: headers,
        );

      default:
        return shelf.Response.ok(
          jsonEncode({'success': false, 'error': 'Unknown XMPP action: $action'}),
          headers: headers,
        );
    }
  }

  // ============================================================
  // AT Proto / Bluesky Debug Actions
  // ============================================================

  Future<shelf.Response> _handleAtprotoAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    final atproto = AtprotoClientService();

    switch (action) {
      case 'atproto_status':
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'authenticated': atproto.isAuthenticated,
            'enabled': atproto.config.enabled,
            'pdsUrl': atproto.config.pdsUrl,
            'appViewUrl': atproto.config.appViewUrl,
            'identifier': atproto.config.identifier,
            'hasPassword': atproto.config.password.trim().isNotEmpty,
            'did': atproto.session?.did,
            'handle': atproto.session?.handle,
            'feedCount': atproto.feed.length,
          }),
          headers: headers,
        );

      case 'atproto_self_check':
        final actor = ((params['actor'] as String?)?.trim().isNotEmpty == true)
            ? (params['actor'] as String).trim()
            : (atproto.session?.did.isNotEmpty == true
                  ? atproto.session!.did
                  : (atproto.session?.handle.isNotEmpty == true
                        ? atproto.session!.handle
                        : atproto.config.identifier));
        if (actor.trim().isEmpty) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'No actor available for self check',
            }),
            headers: headers,
          );
        }
        try {
          final profile = await atproto.fetchProfile(actor);
          final posts = await atproto.fetchAuthorFeed(actor, limit: 20);
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'actor': actor,
              'isLocalActor': atproto.isLocalActor(actor),
              'profile': profile?.toJson(),
              'postCount': posts.length,
              'items': posts.map((e) => e.toJson()).toList(),
            }),
            headers: headers,
          );
        } catch (e) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'Self check failed',
              'details': '$e',
              'actor': actor,
            }),
            headers: headers,
          );
        }

      case 'atproto_read_feed':
        final actor = (params['actor'] as String?)?.trim();
        if (actor == null || actor.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'actor parameter required (handle or did)',
            }),
            headers: headers,
          );
        }

        final limit = ((params['limit'] as num?)?.toInt() ?? 10).clamp(1, 100);
        final appView = (params['appview'] as String?)?.trim().isNotEmpty == true
            ? (params['appview'] as String).trim()
            : atproto.config.appViewUrl;
        final base = appView.endsWith('/') ? appView.substring(0, appView.length - 1) : appView;
        final uri = Uri.parse(
          '$base/xrpc/app.bsky.feed.getAuthorFeed'
          '?actor=${Uri.encodeQueryComponent(actor)}'
          '&limit=$limit',
        );

        try {
          final response = await http.get(uri);
          if (response.statusCode < 200 || response.statusCode >= 300) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'status': response.statusCode,
                'error': 'Failed to read feed',
                'uri': uri.toString(),
                'body': response.body,
              }),
              headers: headers,
            );
          }

          final body = jsonDecode(response.body) as Map<String, dynamic>;
          final raw = body['feed'] as List<dynamic>? ?? const [];
          final items = <Map<String, dynamic>>[];
          for (final entry in raw) {
            if (entry is! Map<String, dynamic>) continue;
            final postWrap = entry['post'];
            if (postWrap is! Map<String, dynamic>) continue;
            final author = postWrap['author'] as Map<String, dynamic>? ?? const {};
            final record = postWrap['record'] as Map<String, dynamic>? ?? const {};

            items.add({
              'uri': postWrap['uri'],
              'cid': postWrap['cid'],
              'authorDid': author['did'],
              'authorHandle': author['handle'],
              'displayName': author['displayName'] ?? author['handle'],
              'text': record['text'],
              'createdAt': record['createdAt'],
              'replyCount': postWrap['replyCount'] ?? 0,
              'repostCount': postWrap['repostCount'] ?? 0,
              'likeCount': postWrap['likeCount'] ?? 0,
            });
          }

          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'actor': actor,
              'appview': base,
              'count': items.length,
              'items': items,
            }),
            headers: headers,
          );
        } catch (e) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'Exception while reading feed',
              'details': '$e',
            }),
            headers: headers,
          );
        }

      case 'atproto_sync_feed':
        await atproto.syncFeed();
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'authenticated': atproto.isAuthenticated,
            'feedCount': atproto.feed.length,
            'did': atproto.session?.did,
            'handle': atproto.session?.handle,
          }),
          headers: headers,
        );

      case 'atproto_like_from_feed':
        final actor = (params['actor'] as String?)?.trim();
        final targetActor = (actor == null || actor.isEmpty) ? 'bsky.app' : actor;
        try {
          final feed = await atproto.fetchAuthorFeed(targetActor, limit: 1);
          if (feed.isEmpty) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': 'No posts found for actor',
                'actor': targetActor,
              }),
              headers: headers,
            );
          }
          final target = feed.first;
          final ok = await atproto.likePost(target);
          return shelf.Response.ok(
            jsonEncode({
              'success': ok,
              'actor': targetActor,
              'subjectUri': target.uri,
              'subjectCid': target.cid,
            }),
            headers: headers,
          );
        } catch (e) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'Like test failed',
              'details': '$e',
              'actor': targetActor,
            }),
            headers: headers,
          );
        }

      case 'atproto_read_replies':
        final uri = (params['uri'] as String?)?.trim();
        if (uri == null || uri.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'uri parameter required (AT URI of a post)',
            }),
            headers: headers,
          );
        }
        final depth = ((params['depth'] as num?)?.toInt() ?? 6).clamp(1, 20);
        try {
          final replies = await atproto.fetchReplies(uri, depth: depth);
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'uri': uri,
              'depth': depth,
              'count': replies.length,
              'items': replies.map((e) => e.toJson()).toList(),
            }),
            headers: headers,
          );
        } catch (e) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'Replies read failed',
              'details': '$e',
              'uri': uri,
            }),
            headers: headers,
          );
        }

      case 'atproto_read_media':
        final actor = (params['actor'] as String?)?.trim();
        if (actor == null || actor.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'actor parameter required (handle or DID)',
            }),
            headers: headers,
          );
        }
        try {
          final posts = await atproto.fetchAuthorMediaFeed(
            actor,
            limit: ((params['limit'] as num?)?.toInt() ?? 20).clamp(1, 100),
          );
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'actor': actor,
              'count': posts.length,
              'items': posts.map((e) => e.toJson()).toList(),
            }),
            headers: headers,
          );
        } catch (e) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'Media read failed',
              'details': '$e',
              'actor': actor,
            }),
            headers: headers,
          );
        }

      case 'atproto_list_followers':
      case 'atproto_list_following':
        final actor = (params['actor'] as String?)?.trim();
        if (actor == null || actor.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'actor parameter required (handle or DID)',
            }),
            headers: headers,
          );
        }
        try {
          final list = action == 'atproto_list_followers'
              ? await atproto.fetchFollowers(
                  actor,
                  limit: ((params['limit'] as num?)?.toInt() ?? 50).clamp(
                    1,
                    100,
                  ),
                )
              : await atproto.fetchFollowing(
                  actor,
                  limit: ((params['limit'] as num?)?.toInt() ?? 50).clamp(
                    1,
                    100,
                  ),
                );
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'actor': actor,
              'type': action == 'atproto_list_followers'
                  ? 'followers'
                  : 'following',
              'count': list.length,
              'items': list.map((e) => e.toJson()).toList(),
            }),
            headers: headers,
          );
        } catch (e) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'Graph list failed',
              'details': '$e',
              'actor': actor,
            }),
            headers: headers,
          );
        }

      case 'atproto_follow_actor':
        final actor = (params['actor'] as String?)?.trim();
        if (actor == null || actor.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'actor parameter required (handle or DID)',
            }),
            headers: headers,
          );
        }
        final ok = await atproto.followActor(actor);
        return shelf.Response.ok(
          jsonEncode({'success': ok, 'actor': actor}),
          headers: headers,
        );

      case 'atproto_following_list':
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'count': atproto.followedActors.length,
            'actors': atproto.followedActors,
          }),
          headers: headers,
        );

      case 'atproto_following_activity':
        final items = await atproto.fetchFollowingActivity();
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'count': items.length,
            'items': items.map((e) => e.toJson()).toList(),
          }),
          headers: headers,
        );

      case 'atproto_search_people':
        final query = (params['query'] as String?)?.trim();
        if (query == null || query.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'query parameter required',
            }),
            headers: headers,
          );
        }
        final people = await atproto.searchPeople(
          query,
          limit: ((params['limit'] as num?)?.toInt() ?? 25).clamp(1, 100),
        );
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'query': query,
            'count': people.length,
            'items': people.map((e) => e.toJson()).toList(),
          }),
          headers: headers,
        );

      case 'atproto_search_posts':
        final query = (params['query'] as String?)?.trim();
        if (query == null || query.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'query parameter required',
            }),
            headers: headers,
          );
        }
        final posts = await atproto.searchPosts(
          query,
          limit: ((params['limit'] as num?)?.toInt() ?? 25).clamp(1, 100),
        );
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'query': query,
            'count': posts.length,
            'items': posts.map((e) => e.toJson()).toList(),
          }),
          headers: headers,
        );

      default:
        return shelf.Response.ok(
          jsonEncode({'success': false, 'error': 'Unknown AT Proto action: $action'}),
          headers: headers,
        );
    }
  }

  // ============================================================
  // NOSTR Client Debug Actions
  // ============================================================

  Future<shelf.Response> _handleNostrAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    final nostr = NostrClientService();

    switch (action) {
      case 'nostr_status':
        return shelf.Response.ok(
          jsonEncode({'success': true, ...nostr.getStatus()}),
          headers: headers,
        );

      case 'nostr_connect':
        final relayId = params['relayId'] as String?;
        final url = params['url'] as String?;
        if (relayId == null && url == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'relayId or url required'}),
            headers: headers,
          );
        }
        if (relayId != null) {
          nostr.connect(relayId);
          return shelf.Response.ok(
            jsonEncode({'success': true, 'action': 'connecting', 'relayId': relayId}),
            headers: headers,
          );
        }
        // Add and connect by URL
        final relayUrl = url!;
        final id = NostrRelayConfig.idFromUrl(relayUrl);
        if (!nostr.relays.any((r) => r.id == id)) {
          await nostr.addRelay(NostrRelayConfig(
            id: id,
            url: relayUrl,
            name: NostrRelayConfig.nameFromUrl(relayUrl),
          ));
        }
        nostr.connect(id);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'connecting', 'relayId': id, 'url': relayUrl}),
          headers: headers,
        );

      case 'nostr_disconnect':
        final relayId = params['relayId'] as String?;
        if (relayId == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'relayId required'}),
            headers: headers,
          );
        }
        nostr.disconnect(relayId);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'action': 'disconnected', 'relayId': relayId}),
          headers: headers,
        );

      case 'nostr_follow':
        final pubkey = params['pubkey'] as String?;
        if (pubkey == null || pubkey.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'pubkey required'}),
            headers: headers,
          );
        }
        final followed = await nostr.followUser(pubkey);
        return shelf.Response.ok(
          jsonEncode({'success': followed, 'action': 'follow', 'pubkey': pubkey}),
          headers: headers,
        );

      case 'nostr_unfollow':
        final pubkey = params['pubkey'] as String?;
        if (pubkey == null || pubkey.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'pubkey required'}),
            headers: headers,
          );
        }
        final unfollowed = await nostr.unfollowUser(pubkey);
        return shelf.Response.ok(
          jsonEncode({'success': unfollowed, 'action': 'unfollow', 'pubkey': pubkey}),
          headers: headers,
        );

      case 'nostr_like':
        final eventId = params['eventId'] as String?;
        final authorPubkey = params['authorPubkey'] as String?;
        if (eventId == null || authorPubkey == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'eventId and authorPubkey required'}),
            headers: headers,
          );
        }
        final liked = await nostr.likeEvent(eventId, authorPubkey);
        return shelf.Response.ok(
          jsonEncode({'success': liked, 'action': 'like', 'eventId': eventId}),
          headers: headers,
        );


      case 'nostr_reply':
        final eventId = params['eventId'] as String?;
        final authorPubkey = params['authorPubkey'] as String?;
        final content = params['content'] as String?;
        if (eventId == null || content == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'eventId and content required'}),
            headers: headers,
          );
        }
        final item = nostr.findFeedItemById(eventId);
        if (item != null) {
          final sent = await nostr.publishReply(content, item.event);
          return shelf.Response.ok(
            jsonEncode({'success': sent, 'action': 'reply', 'eventId': eventId}),
            headers: headers,
          );
        }
        if (authorPubkey == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'authorPubkey required if event not cached'}),
            headers: headers,
          );
        }
        final tags = [
          ['e', eventId, '', 'root'],
          ['e', eventId, '', 'reply'],
          ['p', authorPubkey],
        ];
        final sent = await nostr.publishWithTags(content, tags: tags);
        return shelf.Response.ok(
          jsonEncode({'success': sent, 'action': 'reply', 'eventId': eventId}),
          headers: headers,
        );

      case 'nostr_search':
        final query = params['query'] as String? ?? '';
        final matches = nostr.searchFeed(query).map((item) {
          return {
            'id': item.id,
            'pubkey': item.pubkey,
            'npub': item.event.npub,
            'created_at': item.createdAt,
            'content': item.content,
            'relay': item.relayUrl,
            'display_name': item.displayName,
          };
        }).toList();
        return shelf.Response.ok(
          jsonEncode({'success': true, 'query': query, 'items': matches}),
          headers: headers,
        );

      default:
        return shelf.Response.ok(
          jsonEncode({'success': false, 'error': 'Unknown NOSTR action: $action'}),
          headers: headers,
        );
    }
  }

  // ============================================================
  // Task Monitor Debug Actions
  // ============================================================

  shelf.Response _handleTaskAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) {
    final monitor = TaskMonitorService();
    switch (action) {
      case 'task_status':
        return shelf.Response.ok(
          jsonEncode(monitor.toJson()),
          headers: headers,
        );

      case 'task_pause':
        final id = params['id'] as String?;
        if (id == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'id parameter required'}),
            headers: headers,
          );
        }
        final ok = monitor.pause(id);
        return shelf.Response.ok(
          jsonEncode({
            'success': ok,
            if (!ok) 'error': monitor.getTask(id) == null
                ? 'task not found'
                : 'cannot pause critical task',
          }),
          headers: headers,
        );

      case 'task_resume':
        final id = params['id'] as String?;
        if (id == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'id parameter required'}),
            headers: headers,
          );
        }
        final ok = monitor.resume(id);
        return shelf.Response.ok(
          jsonEncode({
            'success': ok,
            if (!ok) 'error': monitor.getTask(id) == null
                ? 'task not found'
                : 'task is not paused',
          }),
          headers: headers,
        );

      case 'task_pause_performance':
        final count = monitor.pausePerformanceTasks();
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'count': count,
            'message': count == 0
                ? 'no periodic runtime tasks were paused'
                : 'paused $count periodic runtime tasks',
          }),
          headers: headers,
        );

      case 'task_resume_performance':
        final count = monitor.resumePerformanceTasks();
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'count': count,
            'message': count == 0
                ? 'no periodic runtime tasks were resumed'
                : 'resumed $count periodic runtime tasks',
          }),
          headers: headers,
        );

      default:
        return shelf.Response.ok(
          jsonEncode({'success': false, 'error': 'Unknown task action: $action'}),
          headers: headers,
        );
    }
  }

  /// Handle local backup debug actions.
  Future<shelf.Response> _handleLocalBackupAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    final service = LocalBackupService();
    service.initialize();

    try {
      switch (action) {
        case 'local_backup_set_folder':
          final folderPath = params['path'] as String?;
          if (folderPath == null || folderPath.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({'success': false, 'error': 'Missing path parameter'}),
              headers: headers,
            );
          }
          service.setBackupFolder(folderPath);
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Backup folder set',
              'path': folderPath,
            }),
            headers: headers,
          );

        case 'local_backup_create':
          final snapshot = await service.createBackup();
          if (snapshot == null) {
            return shelf.Response.ok(
              jsonEncode({
                'success': false,
                'error': service.status.error ?? 'Backup failed',
              }),
              headers: headers,
            );
          }
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Backup created',
              'snapshot': snapshot.toJson(),
            }),
            headers: headers,
          );

        case 'local_backup_list':
          final snapshots = await service.listSnapshots();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'snapshots': snapshots.map((s) => s.toJson()).toList(),
            }),
            headers: headers,
          );

        case 'local_backup_restore':
          final fileName = params['file'] as String?;
          if (fileName == null || fileName.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({'success': false, 'error': 'Missing file parameter'}),
              headers: headers,
            );
          }
          final folder = service.settings.backupFolderPath;
          if (folder == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'No backup folder configured'}),
              headers: headers,
            );
          }
          final filePath = path.join(folder, fileName);
          final success = await service.restoreSnapshot(filePath);
          return shelf.Response.ok(
            jsonEncode({
              'success': success,
              'message': success ? 'Restore complete' : (service.status.error ?? 'Restore failed'),
            }),
            headers: headers,
          );

        case 'local_backup_delete':
          final fileName = params['file'] as String?;
          if (fileName == null || fileName.isEmpty) {
            return shelf.Response.badRequest(
              body: jsonEncode({'success': false, 'error': 'Missing file parameter'}),
              headers: headers,
            );
          }
          final folder = service.settings.backupFolderPath;
          if (folder == null) {
            return shelf.Response.ok(
              jsonEncode({'success': false, 'error': 'No backup folder configured'}),
              headers: headers,
            );
          }
          final filePath = path.join(folder, fileName);
          final deleted = await service.deleteSnapshot(filePath);
          return shelf.Response.ok(
            jsonEncode({
              'success': deleted,
              'message': deleted ? 'Snapshot deleted' : 'File not found',
            }),
            headers: headers,
          );

        case 'local_backup_status':
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'settings': service.settings.toJson(),
              'status': service.status.toJson(),
              'auto_backup_running': service.isAutoBackupRunning,
            }),
            headers: headers,
          );

        default:
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'Unknown local backup action: $action'}),
            headers: headers,
          );
      }
    } catch (e) {
      LogService().log('LocalBackupAction error: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  // ============================================================
  // Hotspot Portal Debug Actions
  // ============================================================

  Future<shelf.Response> _handleHotspotPortalAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    final portal = HotspotPortalService();

    try {
      switch (action) {
        case 'hotspot_portal_status':
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'active': portal.isActive,
              'dns_running': portal.isDnsRunning,
              'port': HotspotPortalService.portalPort,
            }),
            headers: headers,
          );

        case 'hotspot_portal_start':
          await portal.start(
            gatewayIp: params['gateway_ip'] as String? ?? HotspotPortalService.defaultGatewayIp,
            stationName: params['station_name'] as String? ?? 'Geogram',
          );
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'action': 'started',
              'port': HotspotPortalService.portalPort,
            }),
            headers: headers,
          );

        case 'hotspot_portal_stop':
          await portal.stop();
          return shelf.Response.ok(
            jsonEncode({'success': true, 'action': 'stopped'}),
            headers: headers,
          );

        default:
          return shelf.Response.ok(
            jsonEncode({
              'success': false,
              'error': 'Unknown hotspot portal action: $action',
              'available': ['hotspot_portal_start', 'hotspot_portal_stop', 'hotspot_portal_status'],
            }),
            headers: headers,
          );
      }
    } catch (e) {
      LogService().log('HotspotPortalAction error: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// GET /api/debug/mirrors — returns current mirror discovery state.
  shelf.Response _handleDebugMirrors(Map<String, String> headers) {
    final mirrors = MirrorDiscoveryService().mirrors.value;
    return shelf.Response.ok(
      jsonEncode({
        'success': true,
        'count': mirrors.length,
        'mirrors': mirrors.map((s) => {
          'device_id': s.deviceId,
          'install_id': s.installId,
          'display_name': s.displayName,
          'callsign': s.callsign,
          'platform': s.platform,
          'device_type': s.deviceType,
          'connection_type': s.connectionType,
          'npub': s.npub,
          'verified': s.verified,
          'direct_address': s.directAddress,
          'station_relay_url': s.stationRelayUrl,
          'last_seen': s.lastSeen.toIso8601String(),
        }).toList(),
      }),
      headers: headers,
    );
  }

  /// POST /api/debug/sync-trigger — run full diff against a mirror device.
  ///
  /// Body: {"device_id": "..."} or {} to auto-select the first mirror.
  /// Returns per-folder diffs showing adds, modifies, deletes, uploads.
  Future<shelf.Response> _handleDebugSyncTrigger(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final body = await request.readAsString();
      final data = body.isNotEmpty
          ? jsonDecode(body) as Map<String, dynamic>
          : <String, dynamic>{};
      final deviceId = data['device_id'] as String?;
      final explicitPeerUrl = data['peer_url'] as String?;

      String? peerUrl;
      String? mirrorInfo;

      if (explicitPeerUrl != null) {
        // Direct peer URL provided (e.g., via ADB port forward)
        peerUrl = explicitPeerUrl;
        mirrorInfo = 'direct: $peerUrl';
      } else {
        final mirrors = MirrorDiscoveryService().mirrors.value;
        if (mirrors.isEmpty) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'No mirrors connected'}),
            headers: headers,
          );
        }

        final targetMirror = deviceId != null
            ? mirrors.where((s) => s.deviceId == deviceId).firstOrNull
            : mirrors.first;

        if (targetMirror == null) {
          return shelf.Response.notFound(
            jsonEncode({'success': false, 'error': 'Mirror not found: $deviceId'}),
            headers: headers,
          );
        }

        // Build peer URL the same way DeviceSyncPage does
        peerUrl = targetMirror.directAddress ?? targetMirror.stationRelayUrl;
        if (peerUrl == null) {
          final wsUrl = WebSocketService().connectedUrl;
          if (wsUrl != null) {
            final stationUrl = wsUrl
                .replaceFirst('ws://', 'http://')
                .replaceFirst('wss://', 'https://');
            peerUrl = '$stationUrl/device/${targetMirror.callsign}?target=${targetMirror.deviceId}';
          }
        }
        if (peerUrl == null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': 'Cannot determine peer URL'}),
            headers: headers,
          );
        }
        mirrorInfo = '${targetMirror.deviceId} (${targetMirror.platform}, ${targetMirror.connectionType})';
      }

      // Run the same diff logic as DeviceSyncPage._loadDiffs
      final mirror = MirrorSyncService.instance;
      final storage = AppService().profileStorage;
      final profile = ProfileService().getProfile();
      final folders = kSyncableFolders;

      final diffs = <String, dynamic>{};
      final errors = <String, String>{};

      for (final folder in folders) {
        try {
          final syncResult = await mirror.requestSync(peerUrl, folder);
          if (!syncResult.allowed || syncResult.token == null) {
            if (syncResult.error != null) errors[folder] = syncResult.error!;
            continue;
          }

          final manifest = await mirror.fetchManifest(
            peerUrl, folder, syncResult.token!,
          );
          if (manifest == null) {
            errors[folder] = 'Failed to fetch manifest';
            continue;
          }

          final localPath = '${profile.callsign}/$folder';
          final changes = await mirror.diffManifest(
            manifest, localPath,
            syncStyle: SyncStyle.sendReceive,
            storage: storage,
          );

          if (changes.isNotEmpty) {
            diffs[folder] = {
              'total': changes.length,
              'adds': changes.where((c) => c.type == FileChangeType.add).length,
              'modifies': changes.where((c) => c.type == FileChangeType.modify).length,
              'deletes': changes.where((c) => c.type == FileChangeType.delete).length,
              'uploads': changes.where((c) => c.type == FileChangeType.upload).length,
              'files': changes.map((c) => {
                'path': c.path,
                'type': c.type.name,
              }).toList(),
            };
          }
        } catch (e) {
          errors[folder] = e.toString();
        }
      }

      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'mirror': mirrorInfo,
          'peer_url': peerUrl,
          'folders_with_diffs': diffs.length,
          'diffs': diffs,
          if (errors.isNotEmpty) 'errors': errors,
        }),
        headers: headers,
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  /// Handle /api/debug/now/* endpoints
  Future<shelf.Response> _handleNowDebugRequest(
    shelf.Request request,
    String urlPath,
    Map<String, String> headers,
  ) async {
    final nowService = NowService();

    // GET /api/debug/now — list current feed items
    if (urlPath == 'api/debug/now' && request.method == 'GET') {
      final items = nowService.items.map((i) => i.toJson()).toList();
      return shelf.Response.ok(
        jsonEncode({
          'items': items,
          'total': items.length,
          'unread': nowService.unreadCount,
        }),
        headers: headers,
      );
    }

    // POST /api/debug/now/inject — inject a test NowItemEvent
    if (urlPath == 'api/debug/now/inject' && request.method == 'POST') {
      try {
        final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        final appType = body['appType'] as String? ?? 'chat';
        final sourceId = body['sourceId'] as String? ?? 'test-room';
        final sourceName = body['sourceName'] as String? ?? 'Test Room';
        final callsign = body['callsign'] as String? ?? 'TEST';
        final summary = body['summary'] as String? ?? 'Test message';
        final priority = body['priority'] as int? ?? NowPriority.chat;
        final id = body['id'] as String? ??
            '$appType:$sourceId:${DateTime.now().toIso8601String()}';

        EventBus().fire(NowItemEvent(
          id: id,
          appType: appType,
          sourceId: sourceId,
          sourceName: sourceName,
          callsign: callsign,
          summary: summary,
          priority: priority,
        ));

        return shelf.Response.ok(
          jsonEncode({'success': true, 'id': id}),
          headers: headers,
        );
      } catch (e) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': e.toString()}),
          headers: headers,
        );
      }
    }

    // POST /api/debug/now/reply — simulate sending a reply from a Now card
    // Body: {"appType":"aprs","sourceId":"geochat","text":"hello"}
    if (urlPath == 'api/debug/now/reply' && request.method == 'POST') {
      try {
        final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        final appType = body['appType'] as String?;
        final sourceId = body['sourceId'] as String?;
        final text = body['text'] as String?;
        if (appType == null || sourceId == null || text == null || text.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'appType, sourceId, and text required'}),
            headers: headers,
          );
        }

        String? error;
        switch (appType) {
          case 'aprs':
            if (sourceId == 'geochat') {
              final sent = AprsService().sendGeoChat(text);
              if (sent == null) error = 'sendGeoChat returned null (not connected or no position)';
            } else {
              AprsService().sendMessage(sourceId, text);
            }
            break;
          default:
            error = 'now/reply debug only supports aprs for now';
        }

        if (error != null) {
          return shelf.Response.ok(
            jsonEncode({'success': false, 'error': error}),
            headers: headers,
          );
        }
        return shelf.Response.ok(
          jsonEncode({'success': true, 'appType': appType, 'sourceId': sourceId, 'text': text}),
          headers: headers,
        );
      } catch (e) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': e.toString()}),
          headers: headers,
        );
      }
    }

    // POST /api/debug/now/clear — clear all items
    if (urlPath == 'api/debug/now/clear' && request.method == 'POST') {
      nowService.clearAll();
      return shelf.Response.ok(
        jsonEncode({'success': true}),
        headers: headers,
      );
    }

    // POST /api/debug/now/mark-read — mark all as read
    if (urlPath == 'api/debug/now/mark-read' && request.method == 'POST') {
      nowService.markAllAsRead();
      return shelf.Response.ok(
        jsonEncode({'success': true}),
        headers: headers,
      );
    }

    // GET /api/debug/now/settings — get all group settings
    if (urlPath == 'api/debug/now/settings' && request.method == 'GET') {
      final settings = <String, dynamic>{};
      for (final entry in nowService.allGroupSettings.entries) {
        settings[entry.key] = entry.value.toJson();
      }
      return shelf.Response.ok(
        jsonEncode({'settings': settings}),
        headers: headers,
      );
    }

    // POST /api/debug/now/settings — set group settings
    if (urlPath == 'api/debug/now/settings' && request.method == 'POST') {
      try {
        final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        final group = body['group'] as String? ?? '_default';
        final maxItems = body['maxItems'] as int? ?? NowGroupSettings.defaultMaxItems;
        final expiryMinutes = body['expiryMinutes'] as int? ?? NowGroupSettings.defaultExpiryMinutes;
        final priorityOverride = body['priorityOverride'] as int?;
        final pinned = body['pinned'] as bool? ?? false;
        nowService.setGroupSettings(
          group,
          NowGroupSettings(
            maxItems: maxItems,
            expiryMinutes: expiryMinutes,
            priorityOverride: priorityOverride,
            pinned: pinned,
          ),
        );
        return shelf.Response.ok(
          jsonEncode({
            'success': true,
            'group': group,
            'maxItems': maxItems,
            'expiryMinutes': expiryMinutes,
            'priorityOverride': priorityOverride,
            'pinned': pinned,
          }),
          headers: headers,
        );
      } catch (e) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': e.toString()}),
          headers: headers,
        );
      }
    }

    // POST /api/debug/now/remove-group — remove a source group from the feed
    if (urlPath == 'api/debug/now/remove-group' && request.method == 'POST') {
      try {
        final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        final appType = body['appType'] as String?;
        final sourceId = body['sourceId'] as String?;
        if (appType == null || sourceId == null) {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'appType and sourceId required'}),
            headers: headers,
          );
        }
        nowService.removeGroup(appType, sourceId);
        return shelf.Response.ok(
          jsonEncode({'success': true, 'removed': '$appType:$sourceId'}),
          headers: headers,
        );
      } catch (e) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': e.toString()}),
          headers: headers,
        );
      }
    }

    return shelf.Response.notFound(
      jsonEncode({'error': 'Unknown now endpoint: $urlPath'}),
      headers: headers,
    );
  }

  // ============================================================
  // Karma Debug Actions
  // ============================================================

  Future<shelf.Response> _handleKarmaAction(
    String action,
    Map<String, dynamic> params,
    Map<String, String> headers,
  ) async {
    try {
      final stationServer = StationServerService();

      // Ensure karma store is initialized
      if (stationServer.dataDir == null) {
        await stationServer.initialize();
      }

      switch (action) {
        case 'karma_award':
          final callsign = params['callsign'] as String?;
          final karmaAction = params['karma_action'] as String?;
          final meta = (params['meta'] as Map<String, dynamic>?) ?? {};

          if (callsign == null || karmaAction == null) {
            return shelf.Response.badRequest(
              body: jsonEncode({
                'success': false,
                'error': 'Missing callsign or karma_action',
              }),
              headers: headers,
            );
          }

          final points = await stationServer.karmaRecord(
            callsign: callsign,
            action: karmaAction,
            meta: meta,
          );
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'callsign': callsign.toUpperCase(),
              'action': karmaAction,
              'points_awarded': points,
            }),
            headers: headers,
          );

        case 'karma_profile':
          final callsign = (params['callsign'] as String?) ??
              ProfileService().getProfile().callsign;
          final profile = await stationServer.karmaStore.readProfile(
            callsign.toUpperCase(),
          );
          final todayPoints = await stationServer.karmaStore.getTodayPoints(
            callsign.toUpperCase(),
          );
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'callsign': callsign.toUpperCase(),
              'profile': profile?.toJson(),
              'today_points': todayPoints,
            }),
            headers: headers,
          );

        case 'karma_history':
          final callsign = (params['callsign'] as String?) ??
              ProfileService().getProfile().callsign;
          final limit = (params['limit'] as int?) ?? 50;
          final events = await stationServer.karmaStore.readEvents(
            callsign.toUpperCase(),
            limit: limit,
          );
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'callsign': callsign.toUpperCase(),
              'events': events.map((e) => e.toJson()).toList(),
              'count': events.length,
            }),
            headers: headers,
          );

        case 'karma_leaderboard':
          final period = (params['period'] as String?) ?? 'alltime';
          final entries = await stationServer.karmaStore.readLeaderboard(period);
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'period': period,
              'entries': entries.map((e) => e.toJson()).toList(),
            }),
            headers: headers,
          );

        case 'karma_recompute':
          await stationServer.karmaLeaderboard.recomputeAll();
          return shelf.Response.ok(
            jsonEncode({
              'success': true,
              'message': 'Leaderboards recomputed',
            }),
            headers: headers,
          );

        default:
          return shelf.Response.badRequest(
            body: jsonEncode({
              'success': false,
              'error': 'Unknown karma action: $action',
              'available': [
                'karma_award',
                'karma_profile',
                'karma_history',
                'karma_leaderboard',
                'karma_recompute',
              ],
            }),
            headers: headers,
          );
      }
    } catch (e, stack) {
      LogService().log('LogApiService: Karma action error: $e');
      LogService().log('Stack: $stack');
      return shelf.Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }
}

/// Thumbnail bytes + content type returned by [_eventThumbnailBytes].
class _EventThumb {
  final Uint8List bytes;
  final String contentType;
  const _EventThumb(this.bytes, this.contentType);
}
