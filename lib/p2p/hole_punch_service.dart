/// Public, app-facing API for hole-punched UDP sessions.
///
/// Anything in geogram (and any future plugin or external Dart code
/// that imports the geogram package) can establish a direct UDP path
/// to a peer by callsign and exchange small payloads:
///
/// ```dart
/// final session = await HolePunchService().connect('X3TEGE');
/// if (session != null) {
///   session.send(Uint8List.fromList([1,2,3]));
///   session.onData.listen((bytes) => print('peer said ${bytes.length} bytes'));
/// }
/// ```
///
/// Single-frame payloads only in v1 — `kMaxPayloadBytes` is roughly
/// 1255 bytes (one UDP datagram minus IP/UDP/protocol header overhead).
/// Larger transfers and unidirectional streams are documented as
/// follow-up work; the existing reliable-frame layer can be wrapped
/// with a fragmentation/window layer without changing this API.
///
/// The service is a process-wide singleton. It piggy-backs on the
/// existing infrastructure:
///  - DhtNode's UDP socket (shared, NAT mapping kept warm by DHT
///    keepalives)
///  - WebTorrent tracker signaling for the endpoint exchange
///  - IcePunch for the simultaneous open + port prediction
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../services/devices_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/webtorrent_signaling_channel.dart';
import 'hole_punch_protocol.dart';
import 'ice_punch.dart';
import 'p2p_service.dart';

class HolePunchService {
  HolePunchService._();
  static final HolePunchService _instance = HolePunchService._();
  factory HolePunchService() => _instance;

  final LogService _log = LogService();
  final Map<String, HolePunchSession> _sessions = {}; // by upper-case callsign
  final Map<String, _PendingHandshake> _pending = {};

  final _incomingCtl = StreamController<HolePunchSession>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _wtSub;
  bool _started = false;

  /// Fires when the remote peer initiates a session toward us
  /// (geoconnect_offer arrives, hole punch lands, HELLO received).
  /// Existing app code can subscribe and route inbound payloads.
  Stream<HolePunchSession> get incomingSessions => _incomingCtl.stream;

  bool get isStarted => _started;

  /// Start listening on the WebTorrent signaling channel for inbound
  /// connection requests. Idempotent — safe to call multiple times.
  void start() {
    if (_started) return;
    _started = true;
    _wtSub =
        WebTorrentSignalingChannel().signalingMessages.listen(_onSignal);
    P2PService().icePunch.onUnsolicitedFrame = (_) {
      // Frame already cached on IcePunch._pendingIncoming; consumed
      // when we issue the matching punch from _handleInboundOffer.
    };
    _log.info('HolePunchService: started');
  }

  Future<void> stop() async {
    _started = false;
    await _wtSub?.cancel();
    _wtSub = null;
    for (final s in _sessions.values) {
      s.close('service stopped');
    }
    _sessions.clear();
    _pending.clear();
    P2PService().icePunch.onUnsolicitedFrame = null;
  }

  /// Get the current ready session for [callsign], or null. Doesn't
  /// trigger a connect.
  HolePunchSession? getSession(String callsign) {
    final cs = callsign.toUpperCase();
    final s = _sessions[cs];
    if (s == null || s.isClosed) return null;
    return s;
  }

  /// Connect to [callsign]. Returns the existing session if already
  /// open, otherwise runs the WebTorrent endpoint exchange + UDP hole
  /// punch + HELLO/HELLO_ACK handshake. Returns null on failure
  /// (peer not reachable, no public endpoint, hole punch failed,
  /// etc.). Concurrent calls coalesce onto the same handshake future.
  Future<HolePunchSession?> connect(String callsign,
      {Duration timeout = const Duration(seconds: 12)}) async {
    final cs = callsign.toUpperCase();
    final existing = _sessions[cs];
    if (existing != null && existing.isReady) return existing;
    if (existing != null && existing.isClosed) _sessions.remove(cs);

    final pending = _pending[cs];
    if (pending != null) return pending.completer.future;

    if (!_started) start();

    final dev = DevicesService().getDevice(cs);
    final theirNpub = dev?.npub ?? '';
    if (theirNpub.isEmpty) {
      _log.warn('HolePunchService: no npub for $cs');
      return null;
    }

    final dht = P2PService().dht;
    final socket = P2PService().dhtSocket;
    if (dht == null || socket == null) {
      _log.warn('HolePunchService: DHT not running');
      return null;
    }
    final myIp = dht.externalIp;
    final myPort = dht.externalPort;
    if (myIp == null || myPort == null) {
      _log.warn('HolePunchService: no public endpoint (BEP 42)');
      return null;
    }

    final p = _PendingHandshake();
    _pending[cs] = p;

    final sessionId = _newSessionId();
    p.sessionId = sessionId;
    final myPredicted = <int>[for (var i = 1; i <= 4; i++) myPort + i];
    final ok = await WebTorrentSignalingChannel().sendSignal(
      toCallsign: cs,
      signal: {
        'type': 'geoconnect_offer',
        'from_callsign': _myCallsign,
        'to_callsign': cs,
        'session_id': _hex(sessionId),
        'endpoint': {'ip': myIp, 'port': myPort},
        'predicted_ports': myPredicted,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );
    if (!ok) {
      _pending.remove(cs);
      p.completer.complete(null);
      return null;
    }
    _log.info(
        'HolePunchService: sent geoconnect_offer to $cs from $myIp:$myPort'
        ' session=${_hex(sessionId).substring(0, 8)}');

    final answerEp = await p.answerCompleter.future
        .timeout(const Duration(seconds: 6), onTimeout: () => null);
    if (answerEp == null) {
      _log.warn('HolePunchService: no geoconnect_answer from $cs');
      _pending.remove(cs);
      p.completer.complete(null);
      return null;
    }

    final session = await _doHolePunch(
      cs,
      sessionId,
      socket,
      answerEp,
      asInitiator: true,
    ).timeout(timeout, onTimeout: () => null);
    _pending.remove(cs);
    p.completer.complete(session);
    return session;
  }

  Map<String, dynamic> getStatus() {
    return {
      'started': _started,
      'session_count': _sessions.length,
      'pending_handshakes': _pending.length,
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

  Future<HolePunchSession?> _doHolePunch(
    String callsign,
    Uint8List sessionId,
    dynamic socket,
    _Endpoint theirEp, {
    required bool asInitiator,
  }) async {
    final dht = P2PService().dht!;
    final ourCandidate = IceCandidate(ip: dht.externalIp!, port: dht.externalPort!);
    final theirCandidate = IceCandidate(ip: theirEp.ip, port: theirEp.port);
    final conn = await P2PService().icePunch.punch(
          sharedSocket: socket,
          ourCandidate: ourCandidate,
          theirCandidate: theirCandidate,
          predictedPorts: theirEp.predictedPorts,
        );
    if (conn == null) {
      _log.warn('HolePunchService: hole punch failed for $callsign');
      return null;
    }
    final session = HolePunchSession(
      callsign: callsign,
      remoteIp: theirEp.ip,
      remotePort: conn.effectivePort,
      connection: conn,
      sessionId: sessionId,
      onClosedCallback: (cs, reason) {
        _sessions.remove(cs);
        _log.info('HolePunchService: session $cs closed: $reason');
      },
    );
    _sessions[callsign] = session;
    if (asInitiator) {
      await session.openOutbound();
      if (!session.isReady) return null;
    } else {
      await session.openInbound(_dummyHello(sessionId));
    }
    _log.info(
        'HolePunchService: session ready with $callsign at'
        ' ${theirEp.ip}:${conn.effectivePort}');
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
    final predicted = ((envelope['predicted_ports'] as List?) ?? const [])
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

    _log.info(
        'HolePunchService: received geoconnect_offer from $from at'
        ' ${ep.ip}:${ep.port} session=${sessIdHex.substring(0, 8)}');

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

    final session = await _doHolePunch(
      from,
      sessionId,
      socket,
      ep.copyWith(predictedPorts: predicted),
      asInitiator: false,
    );
    if (session != null && !_incomingCtl.isClosed) {
      _incomingCtl.add(session);
    }
  }

  void _handleInboundAnswer(Map<String, dynamic> envelope) {
    final from = (envelope['from_callsign'] as String?)?.toUpperCase();
    if (from == null) return;
    final pending = _pending[from];
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

  HolePunchFrame _dummyHello(Uint8List sessionId) {
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
