/// Bridge between WebRTC ICE failures and the BT-DHT-v2 §10 relay tier.
///
/// Listens to `WebRTCPeerManager.onIceFailed` (PR3 §9.3) and attempts to
/// open a relay-mediated session via, in order:
///   1. The user-configured `manualRelayHostPort` (PR3),
///   2. DHT-discovered relays from RELAY_TOPIC (PR4 — picks the first
///      reachable HELLO/PONG candidate).
///
/// Each pair of peers derives the same 16-byte sessionId from
/// `SHA256(sorted(npubA, npubB))[0:16]` so both halves of the
/// OPEN_SESSION handshake match deterministically without an extra
/// back-channel. The relay holds a half-session for 30s, which is
/// more than enough for both peers to converge on the same relay
/// after the ICE-failure event.
///
/// Substituting the relay byte stream for the WebRTC data channel
/// itself is still out of scope here — flutter_webrtc does not expose
/// a hook to swap the underlying transport. The mediator pairs the
/// session and surfaces its state via the debug API; using the
/// payload bytes for app data is the remaining piece and is tracked
/// separately. This file gets us to a verified, bridged byte-pipe.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../models/serverless_settings.dart';
import '../../services/log_service.dart';
import '../../services/devices_service.dart';
import '../../services/profile_service.dart';
import '../../services/serverless_settings_service.dart';
import '../../services/webrtc_peer_manager.dart';
import '../../util/task_monitor_helpers.dart';
import '../p2p_service.dart';
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

    final existing = _activeRelays[callsign];
    if (existing != null) {
      _log.info(
          'ServerlessRelayMediator: $callsign already has an active relay '
          'session (state ${existing.state.name})');
      return;
    }

    final localNpub = ProfileService().getProfile().npub.trim();
    if (localNpub.isEmpty) {
      _log.warn(
          'ServerlessRelayMediator: no local npub; cannot open relay session');
      return;
    }
    final remoteNpub = _resolveRemoteNpub(callsign);
    if (remoteNpub == null) {
      _log.warn(
          "ServerlessRelayMediator: don't know npub for $callsign; cannot "
          'pair via relay');
      return;
    }

    // Build the candidate-relay list, manual first then DHT-discovered.
    final candidates = await _candidateRelayEndpoints(settings);
    if (candidates.isEmpty) {
      _log.info(
          'ServerlessRelayMediator: no relay candidates available for '
          '$callsign (no manualRelayHostPort, no DHT RELAY_TOPIC peers)');
      return;
    }

    final sessionId = _deriveSessionId(localNpub, remoteNpub);

    for (final hp in candidates) {
      final client = RelayClient(host: hp.host, port: hp.port);
      try {
        await client.connect();
        _log.info(
            'ServerlessRelayMediator: connected to relay ${hp.host}:${hp.port}'
            ' for $callsign');
        _activeRelays[callsign] = client;
        try {
          await client.openSession(
            localNpubHex: localNpub,
            remoteNpubHex: remoteNpub,
            sessionId: sessionId,
          );
          _log.info(
              'ServerlessRelayMediator: relay session bridged for $callsign'
              ' via ${hp.host}:${hp.port} (sid=${_hex16(sessionId)})');
          return;
        } on TimeoutException catch (_) {
          _log.info(
              'ServerlessRelayMediator: ${hp.host}:${hp.port} accepted but'
              " peer didn't reach within 30s; trying next candidate");
          await client.disconnect();
          _activeRelays.remove(callsign);
          continue;
        }
      } catch (e) {
        _log.warn('ServerlessRelayMediator: ${hp.host}:${hp.port} failed: $e');
        try {
          await client.disconnect();
        } catch (_) {}
        _activeRelays.remove(callsign);
      }
    }

    _log.warn(
        'ServerlessRelayMediator: every relay candidate exhausted for '
        '$callsign');
    _taskHandle?.markError('all relay candidates failed for $callsign');
  }

  /// Build the ordered candidate list — `manualRelayHostPort` first
  /// (lets the user pin a specific relay for testing), then up to 5
  /// DHT-discovered peers from RELAY_TOPIC.
  Future<List<_HostPort>> _candidateRelayEndpoints(
      ServerlessSettings settings) async {
    final out = <_HostPort>[];
    final seen = <String>{};

    final manual = settings.manualRelayHostPort?.trim();
    if (manual != null && manual.isNotEmpty) {
      final hp = _parseHostPort(manual);
      if (hp == null) {
        _log.warn(
            'ServerlessRelayMediator: malformed manualRelayHostPort: $manual');
      } else if (seen.add('${hp.host}:${hp.port}')) {
        out.add(hp);
      }
    }

    try {
      final discovered = await P2PService().lookupRelayTierPeers();
      for (final p in discovered.take(5)) {
        final key = '${p.ip}:${p.port}';
        if (seen.add(key)) out.add(_HostPort(p.ip, p.port));
      }
    } catch (e) {
      _log.warn('ServerlessRelayMediator: RELAY_TOPIC lookup error: $e');
    }
    return out;
  }

  String? _resolveRemoteNpub(String callsign) {
    for (final dev
        in DevicesService().getDevicesByCallsign(callsign.toUpperCase())) {
      final npub = dev.npub;
      if (npub != null && npub.isNotEmpty) return npub.trim();
    }
    return null;
  }

  /// Derive a 16-byte sessionId from `SHA256(sorted(npubA, npubB))[0:16]`.
  /// Both peers derive the same value independently, so the relay's
  /// half-session matcher pairs them without any side-channel.
  static Uint8List _deriveSessionId(String npubA, String npubB) {
    final sorted = [npubA, npubB]..sort();
    final digest = sha256.convert(utf8.encode(sorted.join(':'))).bytes;
    return Uint8List.fromList(digest.sublist(0, 16));
  }

  static String _hex16(Uint8List b) {
    const chars = '0123456789abcdef';
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(chars[(x >> 4) & 0xf]);
      sb.write(chars[x & 0xf]);
    }
    return sb.toString();
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
