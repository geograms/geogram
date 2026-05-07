/// Shared HTTP handler logic for the BT-DHT-v2 serverless P2P debug API.
///
/// Both `lib/services/log_api_service.dart` (desktop, shelf-based) and
/// `lib/cli/pure_station.dart` (station, raw `HttpRequest`) route their
/// `/api/p2p/serverless/*` requests through these pure functions so the
/// behavior stays in one place. Each function returns a `(statusCode,
/// jsonBody)` tuple — the caller is responsible for serialization and
/// header handling.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hex/hex.dart' as hex_pkg;

import '../../connection/connection_manager.dart';
import '../../p2p/dht_topics.dart';
import '../../p2p/p2p_service.dart';
import '../../p2p/reachability/reachability_service.dart';
import '../../p2p/relay/relay_promotion_controller.dart';
import '../../p2p/relay/serverless_relay_mediator.dart';
import '../../services/serverless_settings_service.dart';
import '../../services/webrtc_peer_manager.dart';

typedef ServerlessHttpResult = (int statusCode, Map<String, dynamic> body);

class ServerlessP2pHandler {
  /// Dispatch a raw [HttpRequest] for any `/api/p2p/serverless/*` route.
  /// Used by both the in-app station server and the CLI station — both
  /// stations route their `/api/p2p/serverless/...` requests here so the
  /// route table stays in one place.
  static Future<void> dispatchHttpRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;

    Future<Map<String, dynamic>> readJsonBody() async {
      final raw = await utf8.decoder.bind(request).join();
      if (raw.trim().isEmpty) return <String, dynamic>{};
      try {
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return <String, dynamic>{};
      }
    }

    Future<void> reply(ServerlessHttpResult r) async {
      request.response.statusCode = r.$1;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(r.$2));
    }

    try {
      // Routes are matched against the trailing portion after the prefix.
      switch ('$method ${path.substring("/api/p2p/serverless/".length)}') {
        case 'GET status':
          return reply(status());
        case 'POST reachability/recheck':
          return reply(await reachabilityRecheck());
        case 'POST dht/topic':
          return reply(dhtTopic(await readJsonBody()));
        case 'POST dht/announce-debug':
          return reply(dhtAnnounceDebug());
        case 'GET sessions':
          return reply(sessions());
        case 'POST relay/promote':
          return reply(await relayPromote(await readJsonBody()));
        case 'POST relay/demote':
          return reply(await relayDemote());
        case 'GET relay/sessions':
          return reply(relaySessions());
        case 'GET transports':
          return reply(listTransports());
        case 'POST transports/disable':
          return reply(disableTransport(await readJsonBody()));
        case 'POST transports/enable':
          return reply(enableTransport(await readJsonBody()));
        case 'POST transports/force-only':
          return reply(forceOnlyTransports(await readJsonBody()));
      }
      // Unmatched serverless subpath.
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'error': 'Unknown serverless P2P endpoint: $method $path',
      }));
    } catch (e) {
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'error': e.toString(),
      }));
    }
  }

  /// GET /api/p2p/serverless/status
  static ServerlessHttpResult status() {
    final reach = ReachabilityService().currentState;
    final settings = ServerlessSettingsService().current;
    final p2p = P2PService();
    return (
      200,
      {
        'success': true,
        'enableServerless': settings.enableServerless,
        'reachability': reach.toJson(),
        'reachability_chosen_port': ReachabilityService().chosenPort,
        'dht_running': p2p.isRunning,
        'dht_routing_size': p2p.dhtPeerCount,
        'dht_port': p2p.dhtPort,
        'dht_blocked': p2p.isDhtBlocked,
        'public_http_url': p2p.publicHttpUrl,
        'discovered_peer_count': p2p.discoveredPeers.length,
        'legacy_topics_enabled': kEnableLegacyTopics,
      }
    );
  }

  /// POST /api/p2p/serverless/reachability/recheck
  static Future<ServerlessHttpResult> reachabilityRecheck() async {
    final s = await ReachabilityService().refresh();
    return (200, {'success': true, 'reachability': s.toJson()});
  }

  /// POST /api/p2p/serverless/dht/topic — body `{kind, input}`
  static ServerlessHttpResult dhtTopic(Map<String, dynamic> body) {
    final kind = (body['kind'] as String?)?.toLowerCase();
    final input = body['input'] as String?;
    if (kind == null || input == null) {
      return (
        400,
        {'success': false, 'error': 'kind and input are required'}
      );
    }
    try {
      Uint8List specHash;
      Uint8List? legacyHash;
      switch (kind) {
        case 'relay':
          specHash = DhtTopics.relayTopic();
          legacyHash = DhtTopics.legacyGeogramHash();
          break;
        case 'peer':
          specHash = DhtTopics.peerTopicFromNpub(input);
          if (input.startsWith('npub1')) {
            legacyHash = DhtTopics.legacyNpubHash(input);
          }
          break;
        case 'group':
          final raw = Uint8List.fromList(hex_pkg.HEX.decode(input));
          specHash = DhtTopics.groupTopic(raw);
          break;
        default:
          return (
            400,
            {
              'success': false,
              'error': 'unknown kind: $kind (expected relay|peer|group)'
            }
          );
      }
      return (
        200,
        {
          'success': true,
          'kind': kind,
          'input': input,
          'spec_info_hash': hex_pkg.HEX.encode(specHash),
          if (legacyHash != null)
            'legacy_info_hash': hex_pkg.HEX.encode(legacyHash),
        }
      );
    } catch (e) {
      return (400, {'success': false, 'error': e.toString()});
    }
  }

  /// POST /api/p2p/serverless/dht/announce-debug — placeholder for PR2+
  static ServerlessHttpResult dhtAnnounceDebug() => (
        501,
        {
          'success': false,
          'error':
              'announce-debug not implemented in PR1 — use existing /api/dht/* helpers'
        }
      );

  /// GET /api/p2p/serverless/sessions — active WebRTC peer connections.
  static ServerlessHttpResult sessions() {
    final mgr = WebRTCPeerManager();
    final out = <Map<String, dynamic>>[];
    for (final entry in mgr.peers.entries) {
      final p = entry.value;
      out.add({
        'callsign': p.callsign,
        'session_id': p.sessionId,
        'state': p.state.name,
        'connected': p.isConnected,
        'created_at': p.createdAt.toIso8601String(),
        if (p.connectedAt != null)
          'connected_at': p.connectedAt!.toIso8601String(),
        if (p.connectionDuration != null)
          'connected_for_sec': p.connectionDuration!.inSeconds,
      });
    }
    return (
      200,
      {
        'success': true,
        'count': out.length,
        'sessions': out,
      }
    );
  }

  /// POST /api/p2p/serverless/relay/promote — body `{enable: bool}`
  static Future<ServerlessHttpResult> relayPromote(
      Map<String, dynamic> body) async {
    final enable = body['enable'] as bool? ?? true;
    final c = RelayPromotionController();
    if (enable) {
      await c.forcePromote();
    } else {
      await c.forceDemote();
    }
    return (
      200,
      {
        'success': true,
        'promoted': c.isPromoted,
        'last_reason': c.lastReason,
      }
    );
  }

  /// POST /api/p2p/serverless/relay/demote
  static Future<ServerlessHttpResult> relayDemote() async {
    final c = RelayPromotionController();
    await c.forceDemote();
    return (
      200,
      {
        'success': true,
        'promoted': c.isPromoted,
        'last_reason': c.lastReason,
      }
    );
  }

  /// GET /api/p2p/serverless/relay/sessions
  static ServerlessHttpResult relaySessions() {
    final mediator = ServerlessRelayMediator();
    final mediatorSessions = mediator.activeRelays.entries
        .map((e) => {
              'callsign': e.key,
              'state': e.value.state.name,
              'host': e.value.host,
              'port': e.value.port,
            })
        .toList();
    return (
      200,
      {
        'success': true,
        'mediator_started': mediator.isStarted,
        'mediator_sessions': mediatorSessions,
        'promotion': {
          'started': RelayPromotionController().isStarted,
          'promoted': RelayPromotionController().isPromoted,
          'last_reason': RelayPromotionController().lastReason,
        },
      }
    );
  }

  // ── Transport gating (debug-only routing override) ─────────────────

  /// GET /api/p2p/serverless/transports
  static ServerlessHttpResult listTransports() {
    final cm = ConnectionManager();
    final out = <Map<String, dynamic>>[];
    for (final t in cm.transports) {
      out.add({
        'id': t.id,
        'name': t.name,
        'priority': t.priority,
        'available': t.isAvailable,
        'initialized': t.isInitialized,
        'runtime_disabled': cm.disabledTransportIds.contains(t.id),
      });
    }
    out.sort(
        (a, b) => (a['priority'] as int).compareTo(b['priority'] as int));
    return (
      200,
      {
        'success': true,
        'count': out.length,
        'disabled_count': cm.disabledTransportIds.length,
        'transports': out,
      }
    );
  }

  /// POST /api/p2p/serverless/transports/disable — body `{id}`
  static ServerlessHttpResult disableTransport(Map<String, dynamic> body) {
    final id = body['id'] as String?;
    if (id == null || id.isEmpty) {
      return (400, {'success': false, 'error': 'id is required'});
    }
    ConnectionManager().disableTransport(id);
    return (
      200,
      {
        'success': true,
        'disabled': id,
        'currently_disabled':
            ConnectionManager().disabledTransportIds.toList(),
      }
    );
  }

  /// POST /api/p2p/serverless/transports/enable — body `{id}` or `{all:true}`
  static ServerlessHttpResult enableTransport(Map<String, dynamic> body) {
    final id = body['id'] as String?;
    final all = body['all'] as bool? ?? false;
    final cm = ConnectionManager();
    if (all) {
      for (final tid in cm.disabledTransportIds.toList()) {
        cm.enableTransport(tid);
      }
    } else if (id != null && id.isNotEmpty) {
      cm.enableTransport(id);
    } else {
      return (400, {'success': false, 'error': 'id or all=true is required'});
    }
    return (
      200,
      {
        'success': true,
        'currently_disabled': cm.disabledTransportIds.toList(),
      }
    );
  }

  /// POST /api/p2p/serverless/transports/force-only — body `{keep:[..]}`
  static ServerlessHttpResult forceOnlyTransports(Map<String, dynamic> body) {
    final keepList = (body['keep'] as List?)?.cast<String>() ?? const [];
    if (keepList.isEmpty) {
      return (400, {'success': false, 'error': 'keep list must be non-empty'});
    }
    final cm = ConnectionManager();
    final keep = keepList.toSet();
    for (final t in cm.transports) {
      if (!keep.contains(t.id)) {
        cm.disableTransport(t.id);
      } else {
        cm.enableTransport(t.id);
      }
    }
    return (
      200,
      {
        'success': true,
        'kept': keepList,
        'currently_disabled': cm.disabledTransportIds.toList(),
      }
    );
  }
}
