/// Captive portal HTTP server for the Wi-Fi Direct hotspot.
///
/// Manages only the portal web server + DNS responder — the Wi-Fi Direct
/// hotspot itself is managed by [WifiDirectService].
///
/// - Captive portal detection endpoints → 302 redirect to portal home
/// - Portal home page (navigation cards for blog, chat, files, download)
/// - Download page with platform cards
/// - Static CSS
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../util/station_html_templates.dart';
import 'dns_responder.dart';
import 'log_service.dart';

class HotspotPortalService {
  static final HotspotPortalService _instance = HotspotPortalService._internal();
  factory HotspotPortalService() => _instance;
  HotspotPortalService._internal();

  static const int portalPort = 3456;
  static const String defaultGatewayIp = '192.168.49.1';

  HttpServer? _httpServer;
  final DnsResponder _dns = DnsResponder();

  String _gatewayIp = defaultGatewayIp;
  String _stationName = 'Geogram';

  bool get isRunning => _httpServer != null;
  bool get isDnsRunning => _dns.isRunning;
  int? get port => _httpServer?.port;

  /// Start the captive portal HTTP server and DNS responder.
  /// [gatewayIp] defaults to `192.168.49.1` (Wi-Fi Direct group owner).
  Future<void> start({
    String gatewayIp = defaultGatewayIp,
    String stationName = 'Geogram',
  }) async {
    if (_httpServer != null) return;

    _gatewayIp = gatewayIp;
    _stationName = stationName;

    // Start HTTP server
    _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, portalPort);
    _httpServer!.listen(_handleRequest, onError: (e) {
      LogService().log('Portal server error: $e');
    });
    LogService().log('Portal server started on port $portalPort');

    // Start DNS responder (best-effort — port 53 may require root)
    try {
      await _dns.start(gatewayIp);
    } catch (e) {
      LogService().log('DNS responder unavailable (port 53 requires root): $e');
    }
  }

  /// Stop both the HTTP server and DNS responder.
  Future<void> stop() async {
    await _httpServer?.close(force: true);
    _httpServer = null;
    await _dns.stop();
    LogService().log('Portal server stopped');
  }

  // ── Request routing ──────────────────────────────────────────────

  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;

    // Captive portal detection endpoints → redirect to portal
    if (_isCaptivePortalProbe(path)) {
      _redirectToPortal(request);
      return;
    }

    switch (path) {
      case '/':
        _servePortalHome(request);
      case '/download':
      case '/download/':
        _serveDownloadPage(request);
      case '/styles.css':
        _serveCss(request);
      case '/api/debug/hotspot-portal':
        _handleDebugApi(request);
      default:
        // Unknown paths also redirect to portal (helps with captive portal)
        if (!path.startsWith('/api/')) {
          _redirectToPortal(request);
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not found')
            ..close();
        }
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

  void _redirectToPortal(HttpRequest request) {
    final portalUrl = 'http://$_gatewayIp:$portalPort/';
    request.response
      ..statusCode = HttpStatus.found
      ..headers.set('Location', portalUrl)
      ..close();
  }

  // ── Page handlers ────────────────────────────────────────────────

  void _servePortalHome(HttpRequest request) {
    final html = StationHtmlTemplates.buildPortalHomePage(
      stationName: _stationName,
      gatewayIp: _gatewayIp,
      port: portalPort,
    );
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
      ..write(html)
      ..close();
  }

  void _serveDownloadPage(HttpRequest request) {
    final menuItems = '''
      <li><a href="/">home</a></li>
      <li class="separator">|</li>
      <li class="active"><a href="/download">download</a></li>
    ''';

    final html = StationHtmlTemplates.buildDownloadPage(
      stationName: _stationName,
      menuItems: menuItems,
    );
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
      ..write(html)
      ..close();
  }

  void _serveCss(HttpRequest request) {
    final css = '${StationHtmlTemplates.getBaseStyles()}\n'
        '${StationHtmlTemplates.getDownloadStyles()}';
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('text', 'css', charset: 'utf-8')
      ..write(css)
      ..close();
  }

  // ── Debug API ────────────────────────────────────────────────────

  Future<void> _handleDebugApi(HttpRequest request) async {
    if (request.method == 'GET') {
      final info = {
        'running': isRunning,
        'dns_running': isDnsRunning,
        'port': port,
        'gateway_ip': _gatewayIp,
        'station_name': _stationName,
      };
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(info))
        ..close();
      return;
    }

    if (request.method == 'POST') {
      try {
        final body = await utf8.decoder.bind(request).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final action = data['action'] as String?;

        switch (action) {
          case 'start':
            await start(
              gatewayIp: data['gateway_ip'] as String? ?? defaultGatewayIp,
              stationName: data['station_name'] as String? ?? _stationName,
            );
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'status': 'started', 'port': port}))
              ..close();
          case 'stop':
            await stop();
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'status': 'stopped'}))
              ..close();
          default:
            request.response
              ..statusCode = HttpStatus.badRequest
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'error': 'Unknown action: $action'}))
              ..close();
        }
      } catch (e) {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Error: $e')
          ..close();
      }
      return;
    }

    request.response
      ..statusCode = HttpStatus.methodNotAllowed
      ..close();
  }
}
