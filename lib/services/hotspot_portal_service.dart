/// Captive portal route handler for the Wi-Fi Direct hotspot.
///
/// Manages DNS responder and provides a shelf request handler that plugs into
/// [LogApiService]'s existing HTTP server on port 3456. Does NOT bind its own
/// HTTP server — the routes are served through [LogApiService._handleRequest].
///
/// Reuses the station server's actual pages — [StationServerService.buildHomepageHtml]
/// for the homepage, [WebNavigation] for navigation, and [StationHtmlTemplates]
/// for the download page. No separate "portal" pages.
library;

import 'package:shelf/shelf.dart' as shelf;

import '../util/station_html_templates.dart';
import '../util/web_navigation.dart';
import 'dns_responder.dart';
import 'log_service.dart';
import 'station_server_service_stub.dart'
    if (dart.library.ui) 'station_server_service.dart';

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
  /// Reuses the station server's [buildHomepageHtml] for the homepage
  /// and [StationHtmlTemplates.buildDownloadPage] with [WebNavigation]
  /// for the download page — same pages visitors see on the station.
  shelf.Response? handleShelfRequest(shelf.Request request) {
    final path = '/${request.url.path}';

    // Captive portal detection endpoints → redirect to portal home
    if (_isCaptivePortalProbe(path)) {
      return _redirectToPortal();
    }

    // API routes always fall through to LogApiService
    if (path.startsWith('/api')) {
      return null;
    }

    // Serve pages — reuse station server's actual pages
    switch (path) {
      case '/':
        return _serveHomepage();
      case '/download':
      case '/download/':
        return _serveDownloadPage();
      case '/styles.css':
        return _serveCss();
      default:
        // If station server is running, let it handle other routes
        // (chat, blog, device pages, etc.) on the shared port
        if (StationServerService().isRunning) {
          return null;
        }
        // Station server not running — redirect unknown paths to home
        return _redirectToPortal();
    }
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

  // ── Page handlers (reuse station server pages) ─────────────────

  /// Serve the station homepage — exact same page as the station server.
  shelf.Response _serveHomepage() {
    final stationServer = StationServerService();
    final html = stationServer.buildHomepageHtml();
    if (html != null) {
      return shelf.Response.ok(
        html,
        headers: {'Content-Type': 'text/html; charset=utf-8'},
      );
    }
    // Station server not initialized — minimal redirect
    return _redirectToPortal();
  }

  shelf.Response _serveDownloadPage() {
    final menuItems = WebNavigation.generateStationMenuItems(
      activeApp: 'download',
      hasChat: true,
      hasDownload: true,
    );

    final html = StationHtmlTemplates.buildDownloadPage(
      stationName: _stationName,
      menuItems: menuItems,
    );
    return shelf.Response.ok(
      html,
      headers: {'Content-Type': 'text/html; charset=utf-8'},
    );
  }

  shelf.Response _serveCss() {
    final css = '${StationHtmlTemplates.getBaseStyles()}\n'
        '${StationHtmlTemplates.getDownloadStyles()}';
    return shelf.Response.ok(
      css,
      headers: {'Content-Type': 'text/css; charset=utf-8'},
    );
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
