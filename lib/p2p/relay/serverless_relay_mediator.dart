/// Bridge between WebRTC ICE failures and the BT-DHT-v2 §10 relay tier.
///
/// Listens to `WebRTCPeerManager.onIceFailed` (PR3 §9.3) and attempts to
/// open a relay-mediated session via either:
///   1. The user-configured `manualRelayHostPort` (PR3),
///   2. (future PR4) DHT-discovered relays from RELAY_TOPIC.
///
/// In PR3 the mediator establishes a relay session and exposes its
/// connection state via the debug API, but does NOT yet substitute the
/// relay byte-stream for the WebRTC data channel — flutter_webrtc doesn't
/// natively accept an external socket as a data-channel transport. Full
/// data-path bridging is the largest remaining piece and is best handled
/// alongside Phase-4 self-bootstrapping relays (where the byte path can
/// be exercised end-to-end in test).
library;

import 'dart:async';

import '../../services/log_service.dart';
import '../../services/serverless_settings_service.dart';
import '../../services/webrtc_peer_manager.dart';
import '../../util/task_monitor_helpers.dart';
import 'relay_client.dart';

class ServerlessRelayMediator {
  ServerlessRelayMediator._();
  static final ServerlessRelayMediator _instance =
      ServerlessRelayMediator._();
  factory ServerlessRelayMediator() => _instance;

  final LogService _log = LogService();
  StreamSubscription<String>? _failureSub;
  MonitoredIsolateHandle? _taskHandle;

  /// Active relay-mediated session per callsign. PR3 only tracks state;
  /// PR4 will use these to forward bytes once the data path is wired.
  final Map<String, RelayClient> _activeRelays = {};
  Map<String, RelayClient> get activeRelays =>
      Map.unmodifiable(_activeRelays);

  bool _started = false;
  bool get isStarted => _started;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _taskHandle = MonitoredIsolateHandle(
      id: 'serverless.relay_mediator',
      name: 'Serverless relay mediator',
      description:
          'Opens a BT-DHT-v2 relay-tier session when WebRTC ICE fails',
      serviceName: 'ServerlessRelayMediator',
    );
    _taskHandle!.markRunning();
    _failureSub = WebRTCPeerManager().onIceFailed.listen(_onIceFailed);
    _log.info('ServerlessRelayMediator: started');
  }

  Future<void> stop() async {
    _started = false;
    await _failureSub?.cancel();
    _failureSub = null;
    for (final c in _activeRelays.values) {
      try {
        await c.disconnect();
      } catch (_) {}
    }
    _activeRelays.clear();
    _taskHandle?.dispose();
    _taskHandle = null;
  }

  Future<void> _onIceFailed(String callsign) async {
    final settings = ServerlessSettingsService().current;
    if (!settings.enableServerless) return;

    final endpoint = settings.manualRelayHostPort?.trim();
    if (endpoint == null || endpoint.isEmpty) {
      _log.info(
          'ServerlessRelayMediator: ICE failed for $callsign but no manual '
          'relay configured (PR4 will discover via RELAY_TOPIC)');
      return;
    }

    final hp = _parseHostPort(endpoint);
    if (hp == null) {
      _log.warn(
          'ServerlessRelayMediator: malformed manualRelayHostPort: $endpoint');
      return;
    }

    final existing = _activeRelays[callsign];
    if (existing != null) {
      _log.info(
          'ServerlessRelayMediator: $callsign already has an active relay '
          'session (state ${existing.state.name})');
      return;
    }

    final client = RelayClient(host: hp.host, port: hp.port);
    _activeRelays[callsign] = client;
    try {
      await client.connect();
      _log.info(
          'ServerlessRelayMediator: connected to relay $endpoint for '
          '$callsign');
      // openSession requires both peer npubs; in PR3 we don't yet have a
      // back-channel to coordinate sessionId with the remote, so we stop
      // at the connect step. Full openSession integration arrives with
      // PR4 + a session-id agreed via the DHT geogram_query signaling
      // path.
    } catch (e) {
      _log.warn('ServerlessRelayMediator: connect failed: $e');
      _activeRelays.remove(callsign);
      _taskHandle?.markError(e);
    }
  }

  static _HostPort? _parseHostPort(String s) {
    final idx = s.lastIndexOf(':');
    if (idx <= 0 || idx == s.length - 1) return null;
    final host = s.substring(0, idx);
    final port = int.tryParse(s.substring(idx + 1));
    if (port == null || port <= 0 || port > 65535) return null;
    return _HostPort(host, port);
  }
}

class _HostPort {
  final String host;
  final int port;
  const _HostPort(this.host, this.port);
}
