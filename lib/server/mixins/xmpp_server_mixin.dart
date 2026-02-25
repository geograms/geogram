// XMPP server mixin for station server
// Mirrors SmtpMixin: thin wrapper around XmppServer for station integration
import 'dart:async';

import '../../services/xmpp_server.dart';

/// Mixin providing XMPP server functionality.
/// Both StationServer and PureStationServer mix this in — all XMPP server
/// lifecycle code lives here to avoid duplication.
mixin XmppServerMixin {
  // XMPP server state
  XmppServer? _xmppServer;

  // Abstract methods to be implemented by the using class
  void log(String level, String message);

  /// Get the XMPP server (if running)
  XmppServer? get xmppServer => _xmppServer;

  /// Check if XMPP server is running
  bool get isXmppServerRunning => _xmppServer != null;

  /// Start XMPP server with the given parameters.
  /// S2S federation is enabled by default (port 5269).
  Future<bool> startXmppServer({
    required String dataDir,
    required String domain,
    required String callsign,
    int port = 5222,
    bool s2sEnabled = true,
    int s2sPort = 5269,
  }) async {
    if (domain.isEmpty) {
      log('WARN', 'Cannot start XMPP server: no domain configured');
      return false;
    }

    try {
      _xmppServer = XmppServer(
        port: port,
        domain: domain,
        dataDir: dataDir,
        s2sEnabled: s2sEnabled,
        s2sPort: s2sPort,
      );

      final started = await _xmppServer!.start();
      if (started) {
        // Auto-provision station callsign as admin
        await _xmppServer!.autoProvisionAdmin(
          callsign,
          'station-$callsign',
        );
        log('INFO', 'XMPP server started on port $port for domain $domain'
            '${s2sEnabled ? " (S2S on port $s2sPort)" : ""}');
        return true;
      } else {
        log('WARN', 'Failed to start XMPP server on port $port');
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
        'server_running': false,
      };
    }
    return _xmppServer!.getStatus();
  }
}
