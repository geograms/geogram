// XMPP server mixin for station server
// Mirrors SmtpMixin: thin wrapper around XmppServer for station integration
import 'dart:async';

import '../../services/xmpp_server.dart';
import '../station_settings.dart';

/// Mixin providing XMPP server functionality
mixin XmppServerMixin {
  // XMPP server state
  XmppServer? _xmppServer;

  // Abstract methods to be implemented by the using class
  void log(String level, String message);
  StationSettings get settings;

  /// Get the XMPP server (if running)
  XmppServer? get xmppServer => _xmppServer;

  /// Check if XMPP server is running
  bool get isXmppServerRunning => _xmppServer != null;

  /// Start XMPP server
  Future<bool> startXmppServer({required String dataDir}) async {
    if (!settings.xmppServerEnabled) {
      log('INFO', 'XMPP server is disabled');
      return false;
    }

    if (settings.sslDomain == null || settings.sslDomain!.isEmpty) {
      log('WARN', 'Cannot start XMPP server: no domain configured');
      return false;
    }

    try {
      _xmppServer = XmppServer(
        port: settings.xmppServerPort,
        domain: settings.sslDomain!,
        dataDir: dataDir,
        s2sEnabled: settings.xmppS2sEnabled,
        s2sPort: settings.xmppS2sPort,
      );

      final started = await _xmppServer!.start();
      if (started) {
        // Auto-provision station callsign as admin
        await _xmppServer!.autoProvisionAdmin(
          settings.callsign,
          'station-${settings.callsign}',
        );
        log('INFO', 'XMPP server started on port ${settings.xmppServerPort} '
            'for domain ${settings.sslDomain}');
        return true;
      } else {
        log('WARN', 'Failed to start XMPP server on port ${settings.xmppServerPort}');
        _xmppServer = null;
        return false;
      }
    } catch (e) {
      log('ERROR', 'Failed to start XMPP server: $e');
      _xmppServer = null;
      return false;
    }
  }

  /// Stop XMPP server
  Future<void> stopXmppServer() async {
    await _xmppServer?.stop();
    _xmppServer = null;
    log('INFO', 'XMPP server stopped');
  }

  /// Get XMPP server status information
  Map<String, dynamic> getXmppServerStatus() {
    if (_xmppServer == null) {
      return {
        'enabled': settings.xmppServerEnabled,
        'server_running': false,
        'port': settings.xmppServerPort,
        'domain': settings.sslDomain,
      };
    }
    return {
      'enabled': settings.xmppServerEnabled,
      ..._xmppServer!.getStatus(),
    };
  }
}
