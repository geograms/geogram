/// Hole-punch transport — direct UDP between peers, NAT-traversal
/// coordinated via WebTorrent tracker signaling.
///
/// Replaces the WebRTC ICE path for the cross-network case. Endpoints
/// are exchanged via the existing WebTorrent signaling channel; UDP
/// hole punching is performed by `IcePunch` on the same socket the
/// DHT uses (so the NAT mapping is kept warm by DHT keepalives);
/// reliability comes from `HolePunchSession` (sequence + ACK +
/// retransmit).
///
/// Priority 18: ahead of WebRTC (15) where available, ahead of DHT
/// (25) and station (30). Falls through cleanly when the peer hasn't
/// joined our WebTorrent rendezvous yet (canReach returns false).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../p2p/hole_punch_protocol.dart';
import '../../p2p/ice_punch.dart';
import '../../p2p/p2p_service.dart';
import '../../services/devices_service.dart';
import '../../services/log_service.dart';
import '../../services/profile_service.dart';
import '../../services/webtorrent_signaling_channel.dart';
import '../transport.dart';
import '../transport_message.dart';

class HolePunchTransport extends Transport with TransportMixin {
  HolePunchTransport();

  @override
  String get id => 'hole_punch';

  @override
  String get name => 'P2P UDP (hole-punch)';

  /// Between WebRTC (15) and DHT (25). When the WebTorrent rendezvous
  /// has the peer + we have our public endpoint from BEP 42, this beats
  /// WebRTC because it doesn't need ICE to converge.
  @override
  int get priority => 18;

  @override
  bool get isAvailable => !kIsWeb;

  StreamSubscription<Map<String, dynamic>>? _wtSub;
  final Map<String, HolePunchSession> _sessions = {}; // by callsign
  final Map<String, _PendingHandshake> _pendingByCallsign = {};

  @override
  Future<void> initialize() async {
    LogService().log('HolePunchTransport: Initializing...');
    _wtSub = WebTorrentSignalingChannel().signalingMessages.listen(_onSignal);
    // Hook IcePunch's unsolicited-frame callback — when a peer punches
    // first and a GP01 frame arrives before we've issued our own punch,
    // we still need to see it so an inbound HELLO can be honored.
    P2PService().icePunch.onUnsolicitedFrame = _onUnsolicitedFrame;
    markInitialized();
    LogService().log('HolePunchTransport: Initialized');
  }

  @override
  Future<void> dispose() async {
    await _wtSub?.cancel();
    _wtSub = null;
    for (final s in _sessions.values) {
      s.close('transport disposed');
    }
    _sessions.clear();
    _pendingByCallsign.clear();
    P2PService().icePunch.onUnsolicitedFrame = null;
    await disposeMixin();
  }

  @override
  Future<bool> canReach(String callsign) async {
    final cs = callsign.toUpperCase();
    final existing = _sessions[cs];
    if (existing != null && existing.isReady) return true;
    if (kIsWeb) return false;
    // Need: a public endpoint (BEP 42), an open DHT socket, and an
    // npub for the peer (so we can address the WebTorrent rendezvous).
    final dht = P2PService().dht;
    if (dht == null || P2PService().dhtSocket == null) return false;
    if (dht.externalIp == null || dht.externalPort == null) return false;
    final dev = DevicesService().getDevice(cs);
    if (dev == null || dev.npub == null || dev.npub!.isEmpty) return false;
    if (!WebTorrentSignalingChannel().isStarted) return false;
    return WebTorrentSignalingChannel().connectedTrackerCount > 0;
  }

  @override
  Future<int> getQuality(String callsign) async {
    final cs = callsign.toUpperCase();
    final s = _sessions[cs];
    if (s != null && s.isReady) return 80;
    if (await canReach(cs)) return 50;
    return 0;
  }

  @override
  Future<TransportResult> send(
    TransportMessage message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final t0 = DateTime.now();
    final cs = message.targetCallsign.toUpperCase();
    final session = await _ensureSession(cs)
        .timeout(const Duration(seconds: 12), onTimeout: () => null);
    if (session == null) {
      final r = TransportResult.failure(
          error: 'hole-punch handshake timeout', transportUsed: id);
      recordMetrics(r);
      return r;
    }

    // Encode the TransportMessage as JSON, prefix a 4-byte big-endian
    // length so multi-frame fragments could be reassembled later. v1
    // ships single-frame payloads only — bigger gets rejected.
    final encoded = _encodeMessage(message);
    if (encoded.length > kMaxPayloadBytes) {
      final r = TransportResult.failure(
          error: 'payload ${encoded.length}B > $kMaxPayloadBytes',
          transportUsed: id);
      recordMetrics(r);
      return r;
    }

    final ok = await session.send(encoded, timeout: timeout);
    final r = ok
        ? TransportResult.success(
            transportUsed: id, latency: DateTime.now().difference(t0))
        : TransportResult.failure(
            error: 'no DATA_ACK from $cs', transportUsed: id);
    recordMetrics(r);
    return r;
  }

  @override
  Future<void> sendAsync(TransportMessage message) async {
    await send(message, timeout: const Duration(seconds: 8));
  }

  Map<String, dynamic> getStatus() {
    return {
      'started': isInitialized,
      'session_count': _sessions.length,
      'pending_handshakes': _pendingByCallsign.length,
      'sessions': [
        for (final s in _sessions.values)
          {
            'callsign': s.callsign,
            'remote': '${s.remoteIp}:${s.connection.effectivePort}',
            'ready': s.isReady,
            'closed': s.isClosed,
            'last_activity': s.connection.lastActivity.toIso8601String(),
          }
      ],
    };
  }

  // ── internals ───────────────────────────────────────────────────

  /// Returns a ready session for [callsign], starting a fresh
  /// handshake if needed. Caches concurrent waiters so repeated sends
  /// during a handshake don't kick a second one.
  Future<HolePunchSession?> _ensureSession(String callsign) async {
    final existing = _sessions[callsign];
    if (existing != null && existing.isReady) return existing;
    if (existing != null && existing.isClosed) {
      _sessions.remove(callsign);
    }

    final pending = _pendingByCallsign[callsign];
    if (pending != null) return pending.completer.future;

    final dev = DevicesService().getDevice(callsign);
    final theirNpub = dev?.npub ?? '';
    if (theirNpub.isEmpty) {
      LogService().log(
          'HolePunchTransport: no npub for $callsign, cannot signal endpoint');
      return null;
    }

    final dht = P2PService().dht;
    final socket = P2PService().dhtSocket;
    if (dht == null || socket == null) {
      LogService().log('HolePunchTransport: DHT not running, no socket');
      return null;
    }
    final myIp = dht.externalIp;
    final myPort = dht.externalPort;
    if (myIp == null || myPort == null) {
      LogService().log(
          'HolePunchTransport: no public endpoint yet (BEP 42 not received)');
      return null;
    }

    final p = _PendingHandshake();
    _pendingByCallsign[callsign] = p;

    // Send geoconnect_offer via WebTorrent tracker.
    final sessionId = _newSessionId();
    p.sessionId = sessionId;

    final myPredicted = <int>[for (var i = 1; i <= 4; i++) myPort + i];
    final ok = await WebTorrentSignalingChannel().sendSignal(
      toCallsign: callsign,
      signal: {
        'type': 'geoconnect_offer',
        'from_callsign': _myCallsign,
        'to_callsign': callsign,
        'session_id': _hex(sessionId),
        'endpoint': {'ip': myIp, 'port': myPort},
        'predicted_ports': myPredicted,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );
    if (!ok) {
      _pendingByCallsign.remove(callsign);
      return null;
    }
    LogService().log(
        'HolePunchTransport: sent geoconnect_offer to $callsign'
        ' from $myIp:$myPort (session=${_hex(sessionId).substring(0, 8)})');

    // Wait up to 6s for the geoconnect_answer.
    final answerEndpoint = await p.answerCompleter.future
        .timeout(const Duration(seconds: 6), onTimeout: () => null);
    if (answerEndpoint == null) {
      LogService().log(
          'HolePunchTransport: no geoconnect_answer from $callsign');
      _pendingByCallsign.remove(callsign);
      p.completer.complete(null);
      return null;
    }

    final session =
        await _doHolePunchAndOpen(callsign, sessionId, socket, answerEndpoint);
    _pendingByCallsign.remove(callsign);
    p.completer.complete(session);
    return session;
  }

  Future<HolePunchSession?> _doHolePunchAndOpen(
    String callsign,
    Uint8List sessionId,
    dynamic socket,
    _Endpoint theirEndpoint,
  ) async {
    final ourCandidate = IceCandidate(
      ip: P2PService().dht!.externalIp!,
      port: P2PService().dht!.externalPort!,
    );
    final theirCandidate = IceCandidate(
      ip: theirEndpoint.ip,
      port: theirEndpoint.port,
    );
    final conn = await P2PService().icePunch.punch(
          sharedSocket: socket,
          ourCandidate: ourCandidate,
          theirCandidate: theirCandidate,
          predictedPorts: theirEndpoint.predictedPorts,
        );
    if (conn == null) {
      LogService().log(
          'HolePunchTransport: hole punch failed for $callsign');
      return null;
    }
    final session = HolePunchSession(
      callsign: callsign,
      remoteIp: theirEndpoint.ip,
      remotePort: conn.effectivePort,
      connection: conn,
      sessionId: sessionId,
      onData: (payload) => _onSessionData(callsign, payload),
      onClosed: (cs, reason) {
        _sessions.remove(cs);
        LogService().log('HolePunchTransport: session $cs closed: $reason');
      },
    );
    _sessions[callsign] = session;
    await session.openOutbound();
    if (!session.isReady) return null;
    LogService().log(
        'HolePunchTransport: session ready with $callsign at'
        ' ${theirEndpoint.ip}:${conn.effectivePort}');
    return session;
  }

  void _onSignal(Map<String, dynamic> envelope) {
    final type = envelope['type'] as String?;
    if (type == 'geoconnect_offer') {
      _handleInboundOffer(envelope);
    } else if (type == 'geoconnect_answer') {
      _handleInboundAnswer(envelope);
    }
  }

  Future<void> _handleInboundOffer(Map<String, dynamic> envelope) async {
    final from = (envelope['from_callsign'] as String?)?.toUpperCase();
    if (from == null || from.isEmpty) return;
    final ep = _Endpoint.fromJson(envelope['endpoint']);
    if (ep == null) return;
    final predicted =
        ((envelope['predicted_ports'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList();
    final sessIdHex = envelope['session_id'] as String? ?? '';
    if (sessIdHex.isEmpty) return;
    final sessionId = _hexBytes(sessIdHex);
    if (sessionId == null) return;

    final dht = P2PService().dht;
    final socket = P2PService().dhtSocket;
    if (dht == null || socket == null) return;
    final myIp = dht.externalIp;
    final myPort = dht.externalPort;
    if (myIp == null || myPort == null) return;

    LogService().log(
        'HolePunchTransport: received geoconnect_offer from $from at'
        ' ${ep.ip}:${ep.port} session=${sessIdHex.substring(0, 8)}');

    // Reply with our endpoint right away so the sender can start
    // their hole-punch leg.
    final myPredicted = <int>[for (var i = 1; i <= 4; i++) myPort + i];
    await WebTorrentSignalingChannel().sendSignal(
      toCallsign: from,
      signal: {
        'type': 'geoconnect_answer',
        'from_callsign': _myCallsign,
        'to_callsign': from,
        'session_id': sessIdHex,
        'endpoint': {'ip': myIp, 'port': myPort},
        'predicted_ports': myPredicted,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );

    // Punch toward them in parallel; the first incoming GP01 from this
    // peer will land via _onUnsolicitedFrame and turn into our session.
    final ourCandidate = IceCandidate(ip: myIp, port: myPort);
    final theirCandidate = IceCandidate(
      ip: ep.ip,
      port: ep.port,
    );
    final ep2 = ep.copyWith(predictedPorts: predicted);
    final conn = await P2PService().icePunch.punch(
          sharedSocket: socket,
          ourCandidate: ourCandidate,
          theirCandidate: theirCandidate,
          predictedPorts: predicted,
        );
    if (conn == null) {
      LogService().log(
          'HolePunchTransport: inbound-side hole punch failed for $from');
      return;
    }
    // Build a session keyed by the OFFERER's sessionId so its HELLO
    // matches our session.
    final session = HolePunchSession(
      callsign: from,
      remoteIp: ep2.ip,
      remotePort: conn.effectivePort,
      connection: conn,
      sessionId: sessionId,
      onData: (payload) => _onSessionData(from, payload),
      onClosed: (cs, reason) {
        _sessions.remove(cs);
        LogService().log('HolePunchTransport: session $cs closed: $reason');
      },
    );
    _sessions[from] = session;
    // Listen-only mode: the sender will fire HELLO; we'll respond with
    // HELLO_ACK from inside the session's _handleIncomingBytes.
    session.openInbound(_dummyHelloFrame(sessionId));
  }

  void _handleInboundAnswer(Map<String, dynamic> envelope) {
    final from = (envelope['from_callsign'] as String?)?.toUpperCase();
    if (from == null) return;
    final pending = _pendingByCallsign[from];
    if (pending == null) return;
    final sessIdHex = envelope['session_id'] as String? ?? '';
    final ours = _hex(pending.sessionId ?? Uint8List(0));
    if (sessIdHex != ours) return;
    final ep = _Endpoint.fromJson(envelope['endpoint']);
    if (ep == null) return;
    final predicted = ((envelope['predicted_ports'] as List?) ?? const [])
        .map((e) => (e as num).toInt())
        .toList();
    if (!pending.answerCompleter.isCompleted) {
      pending.answerCompleter
          .complete(ep.copyWith(predictedPorts: predicted));
    }
  }

  void _onUnsolicitedFrame(dynamic datagram) {
    // The session is already listening on the underlying connection's
    // onData stream; this hook is informational so we know the punch
    // landed before we issued ours. No-op for now.
  }

  void _onSessionData(String callsign, Uint8List payload) {
    try {
      final msg = _decodeMessage(payload);
      if (msg != null) emitIncomingMessage(msg);
    } catch (e) {
      LogService().log(
          'HolePunchTransport: failed to decode payload from $callsign: $e');
    }
  }

  String get _myCallsign {
    final p = ProfileService().getProfile();
    return p.callsign.isNotEmpty ? p.callsign.toUpperCase() : 'UNKNOWN';
  }

  Uint8List _newSessionId() {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(8, (_) => r.nextInt(256)));
  }

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List? _hexBytes(String s) {
    if (s.length % 2 != 0) return null;
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final byte = int.tryParse(s.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }

  Uint8List _encodeMessage(TransportMessage m) {
    final json = jsonEncode({
      'id': m.id,
      'target': m.targetCallsign,
      'type': m.type.name,
      if (m.method != null) 'method': m.method,
      if (m.path != null) 'path': m.path,
      if (m.headers != null) 'headers': m.headers,
      if (m.payload != null) 'payload': m.payload,
      if (m.signedEvent != null) 'signed_event': m.signedEvent,
    });
    return Uint8List.fromList(utf8.encode(json));
  }

  TransportMessage? _decodeMessage(Uint8List bytes) {
    try {
      final v = jsonDecode(utf8.decode(bytes));
      if (v is! Map<String, dynamic>) return null;
      final typeName = v['type'] as String?;
      final type = TransportMessageType.values.firstWhere(
        (e) => e.name == typeName,
        orElse: () => TransportMessageType.directMessage,
      );
      return TransportMessage(
        id: v['id'] as String? ?? 'recv-${DateTime.now().millisecondsSinceEpoch}',
        targetCallsign: (v['target'] as String? ?? '').toUpperCase(),
        type: type,
        method: v['method'] as String?,
        path: v['path'] as String?,
        headers: (v['headers'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
        payload: v['payload'],
        signedEvent: v['signed_event'] as Map<String, dynamic>?,
        sourceTransportId: id,
      );
    } catch (_) {
      return null;
    }
  }

  HolePunchFrame _dummyHelloFrame(Uint8List sessionId) {
    return HolePunchFrame(
      type: HolePunchType.hello,
      sessionId: sessionId,
      seq: 0,
      ack: 0,
      payload: Uint8List(0),
    );
  }
}

class _Endpoint {
  final String ip;
  final int port;
  final List<int> predictedPorts;
  _Endpoint(this.ip, this.port, this.predictedPorts);

  static _Endpoint? fromJson(dynamic v) {
    if (v is! Map) return null;
    final ip = v['ip'];
    final port = v['port'];
    if (ip is! String || port is! num) return null;
    return _Endpoint(ip, port.toInt(), const <int>[]);
  }

  _Endpoint copyWith({List<int>? predictedPorts}) =>
      _Endpoint(ip, port, predictedPorts ?? this.predictedPorts);
}

class _PendingHandshake {
  Uint8List? sessionId;
  final Completer<HolePunchSession?> completer = Completer<HolePunchSession?>();
  final Completer<_Endpoint?> answerCompleter = Completer<_Endpoint?>();
}
