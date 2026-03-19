/// Captive portal route handler for the Wi-Fi Direct hotspot.
///
/// Manages DNS responder and provides a shelf request handler that plugs into
/// [LogApiService]'s existing HTTP server on port 3456. Does NOT bind its own
/// HTTP server — the routes are served through [LogApiService._handleRequest].
///
/// Serves the device's own web page (same as p2p.radio/{callsign}) by
/// delegating to [WebSocketService.handleLocalHttpRequest].
library;

import 'package:shelf/shelf.dart' as shelf;

import 'dns_responder.dart';
import 'log_service.dart';
import 'websocket_service.dart';

class HotspotPortalService {
  static final HotspotPortalService _instance =
      HotspotPortalService._internal();
  factory HotspotPortalService() => _instance;
  HotspotPortalService._internal();

  static const int portalPort = 3456;
  static const String defaultGatewayIp = '192.168.49.1';

  final DnsResponder _dns = DnsResponder();

  String _gatewayIp = defaultGatewayIp;
  String _stationName = 'Geogram';
  bool _active = false;

  bool get isActive => _active;
  bool get isDnsRunning => _dns.isRunning;

  /// Start the captive portal (DNS responder only — HTTP routes are served
  /// via [handleShelfRequest] through LogApiService).
  Future<void> start({
    String gatewayIp = defaultGatewayIp,
    String stationName = 'Geogram',
  }) async {
    if (_active) return;

    _gatewayIp = gatewayIp;
    _stationName = stationName;
    _active = true;

    // Start DNS responder (best-effort — port 53 may require root)
    try {
      await _dns.start(gatewayIp);
    } catch (e) {
      LogService()
          .log('DNS responder unavailable (port 53 requires root): $e');
    }

    LogService().log('Portal activated (routes via LogApiService)');
  }

  /// Stop the DNS responder and deactivate portal routes.
  Future<void> stop() async {
    _active = false;
    await _dns.stop();
    LogService().log('Portal deactivated');
  }

  // ── Shelf request handler ───────────────────────────────────────

  /// Handle a shelf request if it matches a portal/page route.
  /// Returns a [shelf.Response] for handled paths, or `null` to let
  /// LogApiService handle it normally (e.g. `/api/*` routes).
  ///
  /// Serves the device's own web page by delegating to
  /// [WebSocketService.handleLocalHttpRequest].
  Future<shelf.Response?> handleShelfRequest(shelf.Request request) async {
    final path = '/${request.url.path}';

    // Captive portal detection endpoints → redirect to portal home
    if (_isCaptivePortalProbe(path)) {
      return _redirectToPortal();
    }

    // API routes always fall through to LogApiService
    if (path.startsWith('/api')) {
      return null;
    }

    // Meetings, events, and tile routes are served by LogApiService.
    if (path.startsWith('/meet/') || path.startsWith('/events') ||
        path.startsWith('/tiles/')) {
      return null;
    }

    // Work document pages are served dynamically by LogApiService.
    // Also handle /apps/work/ paths (station-proxied requests).
    if (path.startsWith('/work/') || path == '/work' ||
        path.startsWith('/apps/work/')) {
      return null;
    }

    // Story pages are served dynamically by LogApiService.
    if (path.startsWith('/stories/') || path == '/stories') {
      return null;
    }

    // Map URL paths to device content paths
    final devicePath = _mapToDevicePath(path);
    if (devicePath == null) {
      return null; // fall through to LogApiService
    }

    try {
      final result = await WebSocketService.handleLocalHttpRequest(
        request.method,
        devicePath,
      );

      final headers = <String, String>{'Content-Type': result.contentType};

      // Add Content-Disposition for binary file downloads
      if (devicePath.startsWith('/updates/')) {
        final filename = devicePath.split('/').last;
        headers['Content-Disposition'] = 'attachment; filename="$filename"';
        headers['Content-Length'] = result.body.length.toString();
      }

      return shelf.Response(
        result.statusCode,
        body: result.body,
        headers: headers,
      );
    } catch (e) {
      LogService().log('Portal error serving $path: $e');
      return shelf.Response.internalServerError(
        body: 'Internal Server Error',
        headers: {'Content-Type': 'text/plain'},
      );
    }
  }

  /// Map a portal URL path to the device content path format
  /// used by [WebSocketService.handleLocalHttpRequest].
  String? _mapToDevicePath(String path) {
    // Homepage → www/index.html
    if (path == '/' || path == '/index.html') {
      return '/www/index.html';
    }

    // Blog post rendering (markdown → HTML)
    // /blog/2025-12-04_hello-everyone.html → /api/blog/2025-12-04_hello-everyone.html
    if (path.startsWith('/blog/') && path.endsWith('.html') && path != '/blog/index.html') {
      final filename = path.substring('/blog/'.length);
      return '/api/blog/$filename';
    }

    // Blog index
    if (path == '/blog' || path == '/blog/' || path == '/blog/index.html') {
      return '/blog/index.html';
    }

    // Chat index
    if (path == '/chat' || path == '/chat/' || path == '/chat/index.html') {
      return '/chat/index.html';
    }

    // Top-level CSS → www/styles.css
    if (path == '/styles.css') {
      return '/www/styles.css';
    }

    // Download page
    if (path == '/download' || path == '/download/' || path == '/download/index.html') {
      return '/download';
    }

    // Update binary files: /updates/{version}/{filename}
    if (path.startsWith('/updates/')) {
      return path;
    }

    // Shared folders
    if (path.startsWith('/shared/') || path == '/shared') {
      return path;
    }

    // Blog HTML with identifier prefix: /{identifier}/blog/{filename}.html
    // Handled by LogApiService._handleBlogHtmlRequest, not the portal
    if (path.contains('/blog/') && path.endsWith('.html') && !path.startsWith('/blog/')) {
      return null;
    }

    // Any other /{app}/{file} path — pass through directly
    // (e.g., /blog/styles.css, /chat/styles.css, /www/some-file.png)
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isNotEmpty) {
      return path;
    }

    return null;
  }

  bool _isCaptivePortalProbe(String path) {
    return const {
      '/generate_204', // Android
      '/gen_204', // Android alternate
      '/hotspot-detect.html', // Apple
      '/library/test/success.html', // Apple alternate
      '/connecttest.txt', // Windows
      '/ncsi.txt', // Windows alternate
      '/canonical.html', // Firefox
      '/success.txt', // Firefox alternate
    }.contains(path);
  }

  shelf.Response _redirectToPortal() {
    final portalUrl = 'http://$_gatewayIp:$portalPort/';
    return shelf.Response.found(portalUrl);
  }

  // ── Debug API (JSON status) ───────────────────────────────────

  /// Returns portal status as JSON — called from LogApiService debug routes.
  Map<String, dynamic> get debugInfo => {
        'active': isActive,
        'dns_running': isDnsRunning,
        'gateway_ip': _gatewayIp,
        'station_name': _stationName,
      };
}
