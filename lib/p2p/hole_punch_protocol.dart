/// Reliable-delivery framing for hole-punched UDP connections.
///
/// Wraps `DirectConnection` (lib/p2p/ice_punch.dart) with a small
/// sequence/ACK/retransmit layer so chat-sized payloads survive packet
/// loss. Frame layout — fixed-width, big-endian integers:
///
///   [4B magic "GP01"][1B type][8B sessionId][4B seq][4B ack][4B len][N payload]
///
/// Keepalive every 25s. Retransmit unacked DATA every 500ms, max 5
/// retries (~2.5s total) before declaring the message lost. Connection
/// is dead after 60s with no inbound. No fragmentation: single frame
/// must fit in one UDP datagram. We assume an MTU of 1280 bytes after
/// IP+UDP+NAT overhead, which leaves ~1255 bytes for the payload.
///
/// Pure Dart, runs from CLI. No Flutter imports.
library;

import 'dart:async';
import 'dart:typed_data';

import 'ice_punch.dart';
import '../services/log_service.dart';

const int _kMagic = 0x47503031; // 'GP01' in big-endian
const int kHolePunchHeaderLen = 4 + 1 + 8 + 4 + 4 + 4; // = 25 bytes
const int kMaxPayloadBytes = 1255; // ~1280 MTU minus IP/UDP/header overhead

class HolePunchType {
  HolePunchType._();
  static const int hello = 0x01;
  static const int helloAck = 0x02;
  static const int data = 0x03;
  static const int dataAck = 0x04;
  static const int keepalive = 0x05;
  static const int bye = 0x06;
}

class HolePunchFrame {
  final int type;
  final Uint8List sessionId; // exactly 8 bytes
  final int seq;
  final int ack;
  final Uint8List payload;

  HolePunchFrame({
    required this.type,
    required this.sessionId,
    required this.seq,
    required this.ack,
    required this.payload,
  }) : assert(sessionId.length == 8, 'sessionId must be 8 bytes');

  Uint8List encode() {
    if (payload.length > kMaxPayloadBytes) {
      throw ArgumentError(
          'payload too large: ${payload.length} > $kMaxPayloadBytes');
    }
    final out = Uint8List(kHolePunchHeaderLen + payload.length);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, _kMagic);
    out[4] = type & 0xff;
    out.setRange(5, 13, sessionId);
    bd.setUint32(13, seq);
    bd.setUint32(17, ack);
    bd.setUint32(21, payload.length);
    out.setRange(kHolePunchHeaderLen, out.length, payload);
    return out;
  }

  /// Returns null if the bytes don't form a valid HolePunch frame.
  static HolePunchFrame? decode(Uint8List bytes) {
    if (bytes.length < kHolePunchHeaderLen) return null;
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0) != _kMagic) return null;
    final type = bytes[4];
    final sessionId = Uint8List.fromList(bytes.sublist(5, 13));
    final seq = bd.getUint32(13);
    final ack = bd.getUint32(17);
    final len = bd.getUint32(21);
    if (kHolePunchHeaderLen + len > bytes.length) return null;
    if (len > kMaxPayloadBytes) return null;
    final payload = Uint8List.fromList(
        bytes.sublist(kHolePunchHeaderLen, kHolePunchHeaderLen + len));
    return HolePunchFrame(
      type: type,
      sessionId: sessionId,
      seq: seq,
      ack: ack,
      payload: payload,
    );
  }
}

/// State for a single hole-punched session with one peer. Drives
/// HELLO/HELLO_ACK handshake, DATA reliability, keepalive, and shutdown.
///
/// Public surface for app code:
///  - [send] — fire a payload, awaits DATA_ACK
///  - [onData] — broadcast Stream<Uint8List> of inbound payloads
///  - [onClose] — broadcast Stream<String> emitting a close reason once
///  - [isReady] / [isClosed]
class HolePunchSession {
  final String callsign;
  final String remoteIp;
  final int remotePort;
  final DirectConnection connection;
  final Uint8List sessionId; // 8 random bytes per session

  /// Optional internal hook used by HolePunchTransport for
  /// TransportMessage decode. App code should subscribe to [onData]
  /// instead.
  final void Function(Uint8List payload)? onDataCallback;
  final void Function(String callsign, String reason)? onClosedCallback;

  final _dataCtl = StreamController<Uint8List>.broadcast();
  final _closeCtl = StreamController<String>.broadcast();

  /// Inbound payload stream — fires for each DATA frame the peer
  /// sends. Frames are delivered in network order with at-most-once
  /// delivery (duplicates suppressed by dedupe).
  Stream<Uint8List> get onData => _dataCtl.stream;

  /// Fires once with the close reason when the session ends.
  Stream<String> get onClose => _closeCtl.stream;

  // Sequence numbers
  int _outSeq = 0;
  int _highestAckedSeq = 0;
  int _lastInSeq = 0; // highest seq we've received from peer
  // Pending sends keyed by seq, waiting for DATA_ACK.
  final Map<int, _Pending> _pendingByOutSeq = {};
  final Map<int, Uint8List> _seenInData = {}; // dedupe on inbound

  bool _handshakeDone = false;
  bool _closed = false;
  Completer<void>? _readyCompleter;
  Timer? _keepaliveTimer;
  Timer? _staleTimer;
  StreamSubscription<Uint8List>? _dataSub;

  HolePunchSession({
    required this.callsign,
    required this.remoteIp,
    required this.remotePort,
    required this.connection,
    required this.sessionId,
    this.onDataCallback,
    this.onClosedCallback,
  });

  bool get isReady => _handshakeDone && !_closed;
  bool get isClosed => _closed;

  /// Wire the session to the underlying DirectConnection's data stream
  /// and send the initial HELLO.
  Future<void> openOutbound() async {
    _readyCompleter = Completer<void>();
    _dataSub = connection.onData.listen(_handleIncomingBytes);
    _startTimers();
    _sendFrame(type: HolePunchType.hello, payload: Uint8List(0));
    return _readyCompleter!.future
        .timeout(const Duration(seconds: 8), onTimeout: () {
      close('hello timeout');
    });
  }

  /// Wire the session as a responder — we received the inbound HELLO
  /// from the peer, so the handshake is already half-done. Reply with
  /// HELLO_ACK and mark ready.
  Future<void> openInbound(HolePunchFrame helloFrame) async {
    _dataSub = connection.onData.listen(_handleIncomingBytes);
    _startTimers();
    _sendFrame(
      type: HolePunchType.helloAck,
      payload: Uint8List(0),
      ackOverride: helloFrame.seq,
    );
    _handshakeDone = true;
  }

  /// Send a payload. Returns true once a DATA_ACK comes back, false on
  /// timeout. Caller chunks before calling — single payload must fit
  /// in [kMaxPayloadBytes].
  Future<bool> send(Uint8List payload, {Duration timeout = const Duration(seconds: 8)}) async {
    if (_closed) return false;
    if (!_handshakeDone) {
      try {
        await _readyCompleter?.future
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        return false;
      }
    }
    if (payload.length > kMaxPayloadBytes) {
      LogService().log(
          'HolePunchSession[$callsign]: payload too large (${payload.length}), '
          'caller must chunk');
      return false;
    }
    final seq = ++_outSeq;
    final pending = _Pending(
      seq: seq,
      payload: payload,
      completer: Completer<bool>(),
      retriesLeft: 5,
    );
    _pendingByOutSeq[seq] = pending;
    _sendFrame(type: HolePunchType.data, payload: payload, seqOverride: seq);
    pending.retransmitTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _retransmit(seq),
    );
    try {
      return await pending.completer.future.timeout(timeout, onTimeout: () {
        pending.retransmitTimer?.cancel();
        _pendingByOutSeq.remove(seq);
        return false;
      });
    } catch (_) {
      return false;
    }
  }

  void close(String reason) {
    if (_closed) return;
    _closed = true;
    LogService().log('HolePunchSession[$callsign]: closing — $reason');
    try {
      _sendFrame(type: HolePunchType.bye, payload: Uint8List(0));
    } catch (_) {}
    _keepaliveTimer?.cancel();
    _staleTimer?.cancel();
    for (final p in _pendingByOutSeq.values) {
      p.retransmitTimer?.cancel();
      if (!p.completer.isCompleted) p.completer.complete(false);
    }
    _pendingByOutSeq.clear();
    _dataSub?.cancel();
    connection.close();
    if (!_closeCtl.isClosed) {
      _closeCtl.add(reason);
      _closeCtl.close();
    }
    if (!_dataCtl.isClosed) _dataCtl.close();
    onClosedCallback?.call(callsign, reason);
  }

  // ── internals ───────────────────────────────────────────────────

  void _startTimers() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_closed) return;
      _sendFrame(type: HolePunchType.keepalive, payload: Uint8List(0));
    });
    _staleTimer?.cancel();
    _staleTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_closed) return;
      final age = DateTime.now().difference(connection.lastActivity);
      if (age > const Duration(seconds: 60)) {
        close('stale: no inbound for ${age.inSeconds}s');
      }
    });
  }

  void _retransmit(int seq) {
    final p = _pendingByOutSeq[seq];
    if (p == null) return;
    if (_highestAckedSeq >= seq) {
      p.retransmitTimer?.cancel();
      _pendingByOutSeq.remove(seq);
      if (!p.completer.isCompleted) p.completer.complete(true);
      return;
    }
    p.retriesLeft--;
    if (p.retriesLeft <= 0) {
      p.retransmitTimer?.cancel();
      _pendingByOutSeq.remove(seq);
      if (!p.completer.isCompleted) p.completer.complete(false);
      return;
    }
    _sendFrame(
        type: HolePunchType.data, payload: p.payload, seqOverride: seq);
  }

  void _sendFrame({
    required int type,
    required Uint8List payload,
    int? seqOverride,
    int? ackOverride,
  }) {
    if (_closed) return;
    final frame = HolePunchFrame(
      type: type,
      sessionId: sessionId,
      seq: seqOverride ?? 0,
      ack: ackOverride ?? _lastInSeq,
      payload: payload,
    );
    connection.send(frame.encode());
  }

  void _handleIncomingBytes(Uint8List bytes) {
    final frame = HolePunchFrame.decode(bytes);
    if (frame == null) return;
    // Match by sessionId — protect against stray packets on the same
    // (ip, port) tuple from a stale session.
    if (!_sessionMatches(frame.sessionId)) return;

    switch (frame.type) {
      case HolePunchType.hello:
        // Echo HELLO_ACK so the other side can mark ready.
        _sendFrame(
          type: HolePunchType.helloAck,
          payload: Uint8List(0),
          ackOverride: frame.seq,
        );
        _handshakeDone = true;
        break;
      case HolePunchType.helloAck:
        _handshakeDone = true;
        if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
          _readyCompleter!.complete();
        }
        break;
      case HolePunchType.data:
        if (frame.seq > _lastInSeq) _lastInSeq = frame.seq;
        // Dedupe — ack the seq even if we've already delivered.
        if (!_seenInData.containsKey(frame.seq)) {
          _seenInData[frame.seq] = frame.payload;
          if (_seenInData.length > 1024) {
            // Bounded — drop oldest by clearing.
            _seenInData.clear();
            _seenInData[frame.seq] = frame.payload;
          }
          onDataCallback?.call(frame.payload);
          if (!_dataCtl.isClosed) _dataCtl.add(frame.payload);
        }
        _sendFrame(
          type: HolePunchType.dataAck,
          payload: Uint8List(0),
          ackOverride: frame.seq,
        );
        break;
      case HolePunchType.dataAck:
        if (frame.ack > _highestAckedSeq) _highestAckedSeq = frame.ack;
        final p = _pendingByOutSeq.remove(frame.ack);
        if (p != null) {
          p.retransmitTimer?.cancel();
          if (!p.completer.isCompleted) p.completer.complete(true);
        }
        break;
      case HolePunchType.keepalive:
        // No-op; the connection's lastActivity already tracked this.
        break;
      case HolePunchType.bye:
        close('peer sent BYE');
        break;
    }
  }

  bool _sessionMatches(Uint8List incoming) {
    if (incoming.length != sessionId.length) return false;
    for (var i = 0; i < sessionId.length; i++) {
      if (incoming[i] != sessionId[i]) return false;
    }
    return true;
  }
}

class _Pending {
  final int seq;
  final Uint8List payload;
  final Completer<bool> completer;
  int retriesLeft;
  Timer? retransmitTimer;
  _Pending({
    required this.seq,
    required this.payload,
    required this.completer,
    required this.retriesLeft,
  });
}
