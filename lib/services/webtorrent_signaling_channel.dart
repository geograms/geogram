/// WebTorrent WSS tracker signaling channel.
///
/// Connects to a small list of public WebTorrent trackers and uses their
/// announce/offer/answer protocol to relay WebRTC signaling between two
/// peers identified by their npubs. Trackers don't see message content —
/// our WebRTCSignal envelope rides inside the SDP string field as JSON.
///
/// Why this exists: home routers (FRITZ!Box, etc.) ship with UPnP-IGD
/// disabled, so the DHT-rendezvous signaling path can't reach devices
/// behind a typical NAT without router-side opt-in. WebTorrent trackers
/// are public WSS endpoints reachable from any client that can do
/// outbound TLS, which works through cellular CGNAT and consumer NAT
/// alike. The actual WebRTC media path establishes peer-to-peer via
/// STUN-assisted hole punching after signaling completes — trackers
/// drop out of the loop.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../util/task_monitor_helpers.dart';
import '../util/webtorrent_wire.dart';
import 'devices_service.dart';
import 'log_service.dart';
import 'profile_service.dart';

/// Default tracker list. Public, volunteer-run, no auth. The set rotates
/// over time as operators come and go; for now we ship a small static
/// list and let users override via settings. Bumped in releases when
/// failures show one is dead long-term.
const List<String> kDefaultWebTorrentTrackers = [
  'wss://tracker.openwebtorrent.com',
  'wss://tracker.webtorrent.dev',
];

class _TrackerConn {
  final String url;
  WebSocketChannel? channel;
  StreamSubscription<dynamic>? sub;
  String state = 'disconnected';
  DateTime? lastAnnounceAt;
  String? lastError;
  int announceCount = 0;
  int reconnectAttempt = 0;
  Timer? reconnectTimer;
  _TrackerConn(this.url);
}

class WebTorrentSignalingChannel {
  WebTorrentSignalingChannel._();
  static final WebTorrentSignalingChannel _instance =
      WebTorrentSignalingChannel._();
  factory WebTorrentSignalingChannel() => _instance;

  final LogService _log = LogService();
  final _signalController = StreamController<Map<String, dynamic>>.broadcast();
  final Map<String, _TrackerConn> _conns = {};
  final Set<String> _activeRendezvous = <String>{}; // hex info_hash
  final Map<String, _InboundOffer> _inboundOffers = {}; // sessionId → stash
  final Set<String> _seenInbound = <String>{}; // dedupe across trackers

  Uint8List? _peerId;
  Timer? _keepaliveTimer;
  Timer? _resubscribeTimer;
  MonitoredIsolateHandle? _taskHandle;
  bool _started = false;
  List<String> _trackerUrls = List.unmodifiable(kDefaultWebTorrentTrackers);

  /// Stream of decoded WebRTCSignal payloads (JSON maps) addressed to us.
  Stream<Map<String, dynamic>> get signalingMessages =>
      _signalController.stream;

  bool get isStarted => _started;
  int get connectedTrackerCount =>
      _conns.values.where((c) => c.state == 'connected').length;

  String get _myNpub {
    final p = ProfileService().getProfile();
    return p.npub;
  }

  String get _myCallsign {
    final p = ProfileService().getProfile();
    return p.callsign.isNotEmpty ? p.callsign.toUpperCase() : 'UNKNOWN';
  }

  /// Start the channel. Connects to every tracker in [trackerUrls] in
  /// parallel and proactively subscribes on every known-contact
  /// rendezvous so inbound offers can reach us. Idempotent.
  Future<void> start({List<String>? trackerUrls}) async {
    if (_started) return;
    _started = true;
    if (trackerUrls != null && trackerUrls.isNotEmpty) {
      _trackerUrls = List.unmodifiable(trackerUrls);
    }
    _peerId = newPeerId();
    _taskHandle = MonitoredIsolateHandle(
      id: 'webtorrent_signaling.channel',
      name: 'WebTorrent signaling',
      description:
          'Public WebTorrent WSS trackers used as WebRTC signaling rendezvous',
      serviceName: 'WebTorrentSignalingChannel',
    );
    _taskHandle!.markRunning();
    _log.info(
        'WebTorrentSignaling: starting with ${_trackerUrls.length} trackers');
    refreshSubscriptions();
    for (final url in _trackerUrls) {
      _conns[url] = _TrackerConn(url);
      _connect(url);
    }
    // Re-announce every 60s so trackers keep our subscriptions warm.
    _keepaliveTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => _sendKeepalives());
    // Re-derive subscriptions every 5 min so newly-pinned contacts
    // become reachable without a restart.
    _resubscribeTimer = Timer.periodic(
        const Duration(minutes: 5), (_) => refreshSubscriptions());
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _resubscribeTimer?.cancel();
    _resubscribeTimer = null;
    for (final c in _conns.values) {
      c.reconnectTimer?.cancel();
      await c.sub?.cancel();
      try {
        await c.channel?.sink.close();
      } catch (_) {}
    }
    _conns.clear();
    _activeRendezvous.clear();
    _inboundOffers.clear();
    _seenInbound.clear();
    _taskHandle?.dispose();
    _taskHandle = null;
  }

  /// Force-reconnect every tracker. Used by debug API.
  void reconnectAll() {
    for (final c in _conns.values) {
      c.reconnectTimer?.cancel();
      c.reconnectAttempt = 0;
      unawaited(c.sub?.cancel());
      try {
        c.channel?.sink.close();
      } catch (_) {}
      c.state = 'disconnected';
    }
    for (final url in _conns.keys) {
      _connect(url);
    }
  }

  /// Walk every known device with an npub and add its rendezvous to the
  /// active subscription set. Called on start and periodically. Pushing
  /// keepalive announces happens on the next keepalive tick.
  void refreshSubscriptions() {
    final myNpub = _myNpub;
    if (myNpub.isEmpty) return;
    var added = 0;
    try {
      final devices = DevicesService().getAllDevices();
      for (final d in devices) {
        final npub = d.npub;
        if (npub == null || npub.isEmpty || npub == myNpub) continue;
        final ih = sessionInfoHash(npubA: myNpub, npubB: npub);
        final ihHex = hex(ih);
        if (_activeRendezvous.add(ihHex)) added++;
      }
    } catch (e) {
      _log.warn('WebTorrentSignaling: refreshSubscriptions failed: $e');
    }
    if (added > 0 && connectedTrackerCount > 0) {
      _sendKeepalives();
    }
  }

  /// Send a WebRTCSignal-shaped JSON envelope toward [toCallsign] using
  /// the WebTorrent offer protocol. Returns true if at least one tracker
  /// accepted the announce.
  Future<bool> sendSignal({
    required String toCallsign,
    required Map<String, dynamic> signal,
  }) async {
    if (!_started) return false;
    if (_peerId == null) return false;
    final myNpub = _myNpub;
    if (myNpub.isEmpty) return false;

    final dev = DevicesService().getDevice(toCallsign);
    final theirNpub = dev?.npub ?? '';
    if (theirNpub.isEmpty) {
      _log.warn(
          'WebTorrentSignaling: no npub known for $toCallsign, cannot send via tracker');
      return false;
    }

    final infoHash = sessionInfoHash(npubA: myNpub, npubB: theirNpub);
    final infoHashHex = hex(infoHash);
    _activeRendezvous.add(infoHashHex);

    // Determine whether this is an answer to a previously-cached offer
    // (so we can use the WebTorrent answer-announce shape and route it
    // back to that specific peer_id) or a fresh outbound (offer or
    // standalone signal — ICE candidate, bye).
    final sessionId = signal['session_id'] as String? ?? '';
    final type = signal['type'] as String? ?? '';
    final isAnswer = type == 'webrtc_answer';
    final stash = isAnswer ? _inboundOffers.remove(sessionId) : null;

    Map<String, dynamic> msg;
    if (stash != null) {
      msg = buildAnswerAnnounce(
        infoHash: infoHash,
        peerId: _peerId!,
        toPeerId: stash.fromPeerId,
        offerId: stash.offerId,
        innerPayloadJson: jsonEncode(signal),
      );
    } else {
      msg = buildOfferAnnounce(
        infoHash: infoHash,
        peerId: _peerId!,
        offerId: newOfferId(),
        innerPayloadJson: jsonEncode(signal),
      );
    }

    var sent = 0;
    for (final c in _conns.values) {
      if (c.state != 'connected') continue;
      if (_send(c, msg)) sent++;
    }
    if (sent == 0) {
      _log.warn(
          'WebTorrentSignaling: no connected trackers to send $type to $toCallsign');
      return false;
    }
    _log.info(
        'WebTorrentSignaling: sent $type to $toCallsign via $sent tracker(s)'
        ' (rendezvous=${infoHashHex.substring(0, 8)})');
    return true;
  }

  Map<String, dynamic> getStatus() {
    return {
      'started': _started,
      'connected_count': connectedTrackerCount,
      'tracker_count': _conns.length,
      'active_rendezvous': _activeRendezvous.length,
      // First 8 hex chars per rendezvous — enough to compare both
      // peers landed on the same hash without leaking the full ID.
      'rendezvous_prefixes':
          _activeRendezvous.map((h) => h.substring(0, 8)).toList(),
      'inbound_received': _inboundCount,
      'inbound_dispatched': _dispatchedCount,
      'cached_inbound_offers': _inboundOffers.length,
      'trackers': _conns.values
          .map((c) => {
                'url': c.url,
                'state': c.state,
                if (c.lastAnnounceAt != null)
                  'last_announce_at': c.lastAnnounceAt!.toIso8601String(),
                if (c.lastError != null) 'last_error': c.lastError,
                'announce_count': c.announceCount,
              })
          .toList(),
    };
  }

  int _inboundCount = 0;
  int _dispatchedCount = 0;

  // ── internals ───────────────────────────────────────────────────

  void _connect(String url) {
    final conn = _conns[url];
    if (conn == null) return;
    if (!_started) return;
    conn.state = 'connecting';
    conn.lastError = null;
    final ch = WebSocketChannel.connect(Uri.parse(url));
    conn.channel = ch;
    conn.sub = ch.stream.listen(
      (msg) => _handleInbound(conn, msg),
      onError: (Object e) {
        conn.lastError = e.toString();
        if (conn.state != 'disconnected') {
          conn.state = 'disconnected';
          _log.warn('WebTorrentSignaling: $url error: $e');
          _scheduleReconnect(url);
        }
      },
      onDone: () {
        if (conn.state != 'disconnected') {
          conn.state = 'disconnected';
          _log.info('WebTorrentSignaling: $url closed');
          _scheduleReconnect(url);
        }
      },
      cancelOnError: true,
    );
    // Wait for the handshake to actually succeed before pushing
    // announces. If `ready` fails, the listen callback's onError
    // handles cleanup; if it succeeds we know the upgrade survived
    // TLS, HTTP, and WSS upgrade — only then is reconnectAttempt
    // safe to reset.
    ch.ready.then((_) {
      if (!_started) return;
      if (conn.state == 'disconnected') return;
      conn.state = 'connected';
      conn.reconnectAttempt = 0;
      _log.info('WebTorrentSignaling: connected $url');
      for (final ihHex in _activeRendezvous) {
        final ih = _hexBytes(ihHex);
        final msg = buildKeepaliveAnnounce(infoHash: ih, peerId: _peerId!);
        _send(conn, msg);
      }
    }).catchError((Object e) {
      // ready failures also surface via stream.onError; nothing to do.
    });
  }

  void _scheduleReconnect(String url) {
    final conn = _conns[url];
    if (conn == null) return;
    if (!_started) return;
    conn.reconnectAttempt++;
    // 2^attempt seconds, clamped to [2s, 300s]. With reconnectAttempt
    // only resetting on successful traffic, this means broken trackers
    // back off to 5-minute retries instead of hammering every 1-2s.
    final secs = (1 << conn.reconnectAttempt.clamp(0, 8)).clamp(2, 300);
    conn.reconnectTimer?.cancel();
    conn.reconnectTimer = Timer(Duration(seconds: secs), () {
      if (!_started) return;
      _connect(url);
    });
  }

  bool _send(_TrackerConn conn, Map<String, dynamic> msg) {
    try {
      conn.channel?.sink.add(jsonEncode(msg));
      conn.lastAnnounceAt = DateTime.now();
      conn.announceCount++;
      return true;
    } catch (e) {
      conn.lastError = 'send: $e';
      return false;
    }
  }

  void _sendKeepalives() {
    if (_activeRendezvous.isEmpty) return;
    if (_peerId == null) return;
    for (final ihHex in _activeRendezvous) {
      final ih = _hexBytes(ihHex);
      final msg = buildKeepaliveAnnounce(infoHash: ih, peerId: _peerId!);
      for (final c in _conns.values) {
        if (c.state == 'connected') _send(c, msg);
      }
    }
  }

  void _handleInbound(_TrackerConn conn, dynamic raw) {
    _inboundCount++;
    // Diagnostic: log raw inbound (truncated) so we can see what the
    // tracker actually delivers vs what we expected.
    if (raw is String) {
      final trunc = raw.length > 240 ? '${raw.substring(0, 240)}…' : raw;
      _log.info('WebTorrentSignaling: <- ${conn.url}: $trunc');
    }
    final parsed = parseTrackerMessage(raw);
    if (parsed.kind == WebTorrentInboundKind.ignored) return;

    final inner = parsed.innerPayloadJson;
    if (inner == null) return;

    // Dedupe across multiple trackers — the same offer is forwarded by
    // every tracker the recipient is connected to.
    final dedupeKey =
        '${parsed.kind.name}:${hex(parsed.offerId ?? Uint8List(0))}:${inner.hashCode}';
    if (!_seenInbound.add(dedupeKey)) return;
    if (_seenInbound.length > 1024) {
      _seenInbound.clear();
      _seenInbound.add(dedupeKey);
    }

    Map<String, dynamic>? signal;
    try {
      final v = jsonDecode(inner);
      if (v is Map<String, dynamic>) signal = v;
    } catch (_) {}
    if (signal == null) return;

    final to = (signal['to_callsign'] as String?)?.toUpperCase() ?? '';
    if (to.isEmpty || to != _myCallsign) return;

    _log.info(
        'WebTorrentSignaling: received ${signal['type']} from'
        ' ${signal['from_callsign'] ?? "?"} via ${conn.url}');

    // For inbound offers, stash the (peer_id, offer_id) so that the
    // higher-level service's answer can ride the WebTorrent
    // answer-announce shape back to the original sender.
    if (parsed.kind == WebTorrentInboundKind.offerForUs &&
        parsed.offerId != null &&
        parsed.fromPeerId != null) {
      final sessionId = signal['session_id'] as String? ?? '';
      if (sessionId.isNotEmpty) {
        _inboundOffers[sessionId] = _InboundOffer(
          fromPeerId: parsed.fromPeerId!,
          offerId: parsed.offerId!,
        );
      }
    }

    _dispatchedCount++;
    _signalController.add(signal);
  }

  static Uint8List _hexBytes(String h) {
    final out = Uint8List(h.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

class _InboundOffer {
  final Uint8List fromPeerId;
  final Uint8List offerId;
  _InboundOffer({required this.fromPeerId, required this.offerId});
}
