/// Consumer-side client for the BT-DHT-v2 §10 self-bootstrapping relay
/// tier.
///
/// Usage:
/// 1. Construct with a target relay endpoint (host:port).
/// 2. Call `connect()`; emits [onState] transitions.
/// 3. Call `openSession(localNpubHex, remoteNpubHex)`. The relay will
///    bridge once a matching `OPEN_SESSION` from the other side arrives
///    (within 30s; otherwise it rejects).
/// 4. Stream payload bytes via [send]; receive via [incoming].
/// 5. Close with [closeSession] or [disconnect].
///
/// Transport choice (PR3): plain TCP. Per spec §10.4 "TLS via Noise or
/// DTLS"; deferring TLS to follow-up — the bytes the relay sees are e2e
/// encrypted at WebRTC's data channel layer (DTLS) so plain TCP between
/// peer and relay is acceptable for the PR3 manual-relay scenario. PR4
/// (auto-promoted relays) is the right place to harden this.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../services/log_service.dart';
import 'relay_protocol.dart';

enum RelayClientState {
  disconnected,
  connecting,
  connected,
  sessionPending,
  sessionOpen,
  failed,
  closed,
}

class RelayClient {
  /// Relay host (IP or DNS name).
  final String host;

  /// Relay TCP port.
  final int port;

  RelayClient({required this.host, required this.port});

  final LogService _log = LogService();
  Socket? _socket;
  Uint8List _readBuffer = Uint8List(0);
  RelayClientState _state = RelayClientState.disconnected;
  final _stateCtl = StreamController<RelayClientState>.broadcast();
  final _incomingCtl = StreamController<Uint8List>.broadcast();
  Uint8List? _sessionId;
  Completer<void>? _sessionCompleter;

  RelayClientState get state => _state;
  Stream<RelayClientState> get onState => _stateCtl.stream;

  /// Application bytes received from the bridged peer.
  Stream<Uint8List> get incoming => _incomingCtl.stream;

  /// Establish the TCP connection. Throws [SocketException] on failure.
  Future<void> connect({Duration timeout = const Duration(seconds: 5)}) async {
    if (_state == RelayClientState.connected ||
        _state == RelayClientState.sessionOpen ||
        _state == RelayClientState.sessionPending) {
      return;
    }
    _setState(RelayClientState.connecting);
    try {
      _socket = await Socket.connect(host, port, timeout: timeout);
      _socket!.listen(
        _onData,
        onError: (e) {
          _log.warn('RelayClient: socket error: $e');
          _setState(RelayClientState.failed);
        },
        onDone: () {
          _setState(RelayClientState.closed);
        },
      );
      _setState(RelayClientState.connected);
      _log.info('RelayClient: connected to $host:$port');
    } catch (e) {
      _setState(RelayClientState.failed);
      rethrow;
    }
  }

  /// Latency-probe via HELLO/PONG. Returns the round-trip time, or null on
  /// timeout. Not session-bound — used during relay selection (§10.6).
  Future<Duration?> ping(
      {Duration timeout = const Duration(seconds: 3)}) async {
    if (_socket == null) return null;
    final completer = Completer<Duration>();
    _pendingPong = (Duration d) {
      if (!completer.isCompleted) completer.complete(d);
    };
    _writeFrame(RelayMessage(
      type: RelayMessageType.hello,
      sessionId: _zeroSessionId(),
      payload: Uint8List(0),
    ));
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      _pendingPong = null;
    }
  }

  /// Open a bridged session keyed on (localNpub, remoteNpub, sessionId).
  /// The future completes when the relay confirms the bridge by forwarding
  /// any DATA frame, or fails after [matchTimeout].
  Future<void> openSession({
    required String localNpubHex,
    required String remoteNpubHex,
    required Uint8List sessionId,
    Duration matchTimeout = const Duration(seconds: 30),
  }) async {
    if (_socket == null || _state == RelayClientState.failed) {
      throw StateError('RelayClient not connected');
    }
    _sessionId = Uint8List.fromList(sessionId);
    _sessionCompleter = Completer<void>();
    _setState(RelayClientState.sessionPending);

    final body = utf8.encode(jsonEncode({
      'local_npub': localNpubHex,
      'remote_npub': remoteNpubHex,
    }));
    _writeFrame(RelayMessage(
      type: RelayMessageType.openSession,
      sessionId: _sessionId!,
      payload: Uint8List.fromList(body),
    ));

    try {
      await _sessionCompleter!.future.timeout(matchTimeout);
    } on TimeoutException {
      _setState(RelayClientState.failed);
      throw TimeoutException(
          'RelayClient: no peer matched within ${matchTimeout.inSeconds}s');
    }
  }

  /// Send a DATA frame to the bridged peer.
  void send(Uint8List bytes) {
    if (_state != RelayClientState.sessionOpen &&
        _state != RelayClientState.sessionPending) {
      throw StateError('RelayClient: send while in $_state');
    }
    if (_sessionId == null) {
      throw StateError('RelayClient: no session id');
    }
    _writeFrame(RelayMessage(
      type: RelayMessageType.data,
      sessionId: _sessionId!,
      payload: bytes,
    ));
  }

  /// Graceful CLOSE_SESSION; idempotent.
  Future<void> closeSession() async {
    if (_sessionId != null && _socket != null) {
      try {
        _writeFrame(RelayMessage(
          type: RelayMessageType.closeSession,
          sessionId: _sessionId!,
          payload: Uint8List(0),
        ));
      } catch (_) {}
    }
    _sessionId = null;
  }

  /// Tear down the underlying TCP connection.
  Future<void> disconnect() async {
    await closeSession();
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    _setState(RelayClientState.closed);
  }

  // ─── internals ────────────────────────────────────────────────────

  void Function(Duration rtt)? _pendingPong;
  DateTime? _pingStart;

  void _writeFrame(RelayMessage frame) {
    if (frame.type == RelayMessageType.hello) {
      _pingStart = DateTime.now();
    }
    _socket?.add(frame.encode());
  }

  void _onData(List<int> chunk) {
    final next = Uint8List(_readBuffer.length + chunk.length)
      ..setRange(0, _readBuffer.length, _readBuffer)
      ..setRange(_readBuffer.length, _readBuffer.length + chunk.length, chunk);
    final (frames, remainder) = RelayMessage.decodeAll(next);
    _readBuffer = remainder;
    for (final f in frames) {
      _handleFrame(f);
    }
  }

  void _handleFrame(RelayMessage f) {
    switch (f.type) {
      case RelayMessageType.pong:
        if (_pingStart != null && _pendingPong != null) {
          _pendingPong!(DateTime.now().difference(_pingStart!));
          _pingStart = null;
        }
        break;
      case RelayMessageType.data:
        if (_state == RelayClientState.sessionPending) {
          _setState(RelayClientState.sessionOpen);
          if (_sessionCompleter != null &&
              !_sessionCompleter!.isCompleted) {
            _sessionCompleter!.complete();
          }
        }
        if (!_incomingCtl.isClosed) _incomingCtl.add(f.payload);
        break;
      case RelayMessageType.closeSession:
        _setState(RelayClientState.closed);
        break;
      case RelayMessageType.hello:
      case RelayMessageType.openSession:
        // Server-initiated frames; relays in the spec only forward, so
        // these arriving here means a misbehaving relay. Drop.
        break;
    }
  }

  void _setState(RelayClientState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }

  static Uint8List _zeroSessionId() => Uint8List(16);
}
