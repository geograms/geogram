/// Server-side of the BT-DHT-v2 §10.4 relay protocol.
///
/// Both `PureStationServer` (CLI) and `StationServer` (Desktop) `with`
/// this mixin to provide the byte-pipe relay tier. The relay never
/// inspects payloads (§10.5) — sessions are matched by `(remote npub,
/// local npub, sessionId)` and `DATA` frames are forwarded as-is.
///
/// Promotion is gated upstream by `RelayPromotionController` (battery,
/// Wi-Fi, opt-in). The mixin only handles the wire side: bind/accept,
/// match/forward, idle and bandwidth caps.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/monitored_task.dart';
import '../../p2p/relay/relay_protocol.dart';
import '../../services/log_service.dart';
import '../../services/serverless_settings_service.dart';
import '../../util/task_monitor_helpers.dart';

mixin ServerlessRelayMixin {
  // Abstract dependencies — supplied by the station class.

  /// Tagged log emitter; same shape as the existing station mixins.
  void relayLog(String level, String message);

  // ── Mixin state ──────────────────────────────────────────────────

  ServerSocket? _serverSocket;
  MonitoredIsolateHandle? _acceptHandle;
  bool _serving = false;
  int? _servingPort;
  int get servingPort => _servingPort ?? 0;
  bool get isServingRelay => _serving;

  /// Pending half-sessions keyed by `(remoteNpub, localNpub, sessionIdHex)`
  /// awaiting a matching `OPEN_SESSION` from the other side.
  final Map<String, _PendingHalf> _pending = {};

  /// Established sessions keyed by sessionIdHex.
  final Map<String, _RelaySession> _sessions = {};

  /// 24-hour rolling bandwidth counter (bytes forwarded across all sessions).
  int _bytesForwardedToday = 0;
  DateTime _bandwidthWindowStart = DateTime.now();

  // ── Public API ───────────────────────────────────────────────────

  /// Begin accepting relay connections on [port]. Returns the actual port
  /// (useful when 0 was passed to OS-assign). Re-call to rebind.
  Future<int> startServingRelay(int port) async {
    if (_serving) {
      relayLog('info', 'ServerlessRelay: already serving on $_servingPort');
      return _servingPort!;
    }
    final socket =
        await ServerSocket.bind(InternetAddress.anyIPv4, port, shared: true);
    _serverSocket = socket;
    _servingPort = socket.port;
    _serving = true;
    _acceptHandle = MonitoredIsolateHandle(
      id: 'serverless.relay_accept',
      name: 'Serverless relay accept',
      description:
          'Accepts inbound TCP connections for the BT-DHT-v2 relay tier',
      serviceName: 'ServerlessRelay',
      priority: TaskPriority.normal,
    );
    _acceptHandle!.markRunning();
    socket.listen(
      _onIncomingSocket,
      onError: (e) {
        relayLog('warn', 'ServerlessRelay: accept error: $e');
        _acceptHandle?.markError(e);
      },
      onDone: () {
        _acceptHandle?.markIdle();
      },
    );
    relayLog('info',
        'ServerlessRelay: serving on tcp/$_servingPort (max sessions: ${_maxSessions()})');
    return _servingPort!;
  }

  /// Stop accepting; close all open sessions.
  Future<void> stopServingRelay() async {
    if (!_serving) return;
    _serving = false;
    try {
      await _serverSocket?.close();
    } catch (_) {}
    _serverSocket = null;
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    _pending.clear();
    _acceptHandle?.dispose();
    _acceptHandle = null;
    relayLog('info', 'ServerlessRelay: stopped');
  }

  /// Snapshot of active sessions for the debug API.
  List<Map<String, dynamic>> relaySessionSnapshot() {
    final out = <Map<String, dynamic>>[];
    for (final s in _sessions.values) {
      out.add({
        'session_id': s.sessionId,
        'npub_a': s.npubA,
        'npub_b': s.npubB,
        'opened_at': s.openedAt.toIso8601String(),
        'bytes_a_to_b': s.bytesAtoB,
        'bytes_b_to_a': s.bytesBtoA,
        'idle_sec': DateTime.now().difference(s.lastActivity).inSeconds,
      });
    }
    return out;
  }

  // ── Internals ────────────────────────────────────────────────────

  int _maxSessions() =>
      ServerlessSettingsService().current.maxRelaySessions;
  int _bandwidthCapBytes() =>
      ServerlessSettingsService().current.bandwidthCapMBPerDay * 1024 * 1024;

  void _rolloverBandwidthWindow() {
    if (DateTime.now().difference(_bandwidthWindowStart).inHours >= 24) {
      _bytesForwardedToday = 0;
      _bandwidthWindowStart = DateTime.now();
    }
  }

  void _onIncomingSocket(Socket socket) {
    if (_sessions.length >= _maxSessions()) {
      relayLog('warn',
          'ServerlessRelay: rejecting socket from ${socket.remoteAddress.address}: at session cap');
      socket.destroy();
      return;
    }
    _rolloverBandwidthWindow();
    if (_bytesForwardedToday >= _bandwidthCapBytes()) {
      relayLog('warn',
          'ServerlessRelay: rejecting socket: 24h bandwidth cap reached');
      socket.destroy();
      return;
    }
    final endpoint = _RelayEndpoint(socket, this);
    endpoint.start();
  }

  /// Frame sink — invoked by `_RelayEndpoint` when one side sends a frame.
  /// Routes to the matching peer or, for OPEN_SESSION, parks the
  /// half-session waiting for its mate.
  void _onEndpointFrame(_RelayEndpoint endpoint, RelayMessage frame) {
    final sidHex = _hex(frame.sessionId);
    switch (frame.type) {
      case RelayMessageType.hello:
        endpoint.write(RelayMessage(
          type: RelayMessageType.pong,
          sessionId: frame.sessionId,
          payload: Uint8List(0),
        ));
        break;

      case RelayMessageType.openSession:
        try {
          final body =
              jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
          final localNpub = body['local_npub'] as String?;
          final remoteNpub = body['remote_npub'] as String?;
          if (localNpub == null || remoteNpub == null) {
            relayLog('warn',
                'ServerlessRelay: OPEN_SESSION missing npubs; rejecting');
            endpoint.close();
            return;
          }

          // Match key from the other side's perspective:
          // their local_npub == our remote_npub, and vice versa.
          final mateKey = '$localNpub:$remoteNpub:$sidHex';
          final waiting = _pending.remove(mateKey);
          if (waiting != null) {
            // Pair them up.
            waiting.timeoutTimer?.cancel();
            final session = _RelaySession(
              sessionId: sidHex,
              npubA: waiting.localNpub,
              npubB: localNpub,
              endpointA: waiting.endpoint,
              endpointB: endpoint,
              parent: this,
            );
            _sessions[sidHex] = session;
            session.start();
            relayLog('info',
                'ServerlessRelay: bridged $sidHex (${_short(waiting.localNpub)} ↔ ${_short(localNpub)})');
          } else {
            // Park as half-session; expire after 30s per spec §10.4.
            final ourKey = '$remoteNpub:$localNpub:$sidHex';
            final half = _PendingHalf(
              localNpub: localNpub,
              remoteNpub: remoteNpub,
              endpoint: endpoint,
              key: ourKey,
            );
            half.timeoutTimer = Timer(const Duration(seconds: 30), () {
              final removed = _pending.remove(ourKey);
              if (removed != null) {
                relayLog('info',
                    'ServerlessRelay: half-session $sidHex expired (no peer)');
                removed.endpoint.close();
              }
            });
            _pending[ourKey] = half;
          }
        } catch (e) {
          relayLog('warn', 'ServerlessRelay: malformed OPEN_SESSION: $e');
          endpoint.close();
        }
        break;

      case RelayMessageType.data:
        final session = _sessions[sidHex];
        if (session == null) return;
        session.forward(endpoint, frame);
        break;

      case RelayMessageType.closeSession:
        final session = _sessions.remove(sidHex);
        session?.dispose();
        break;

      case RelayMessageType.pong:
        // Server doesn't expect PONG; ignore.
        break;
    }
  }

  void _onSessionClosed(String sessionId) {
    _sessions.remove(sessionId);
  }

  void _accountForwardedBytes(int n) {
    _rolloverBandwidthWindow();
    _bytesForwardedToday += n;
  }

  static String _hex(Uint8List bytes) {
    const chars = '0123456789abcdef';
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(chars[(b >> 4) & 0xf]);
      sb.write(chars[b & 0xf]);
    }
    return sb.toString();
  }

  static String _short(String npub) =>
      npub.length <= 12 ? npub : '${npub.substring(0, 8)}…';
}

class _PendingHalf {
  final String localNpub;
  final String remoteNpub;
  final _RelayEndpoint endpoint;
  final String key;
  Timer? timeoutTimer;
  _PendingHalf({
    required this.localNpub,
    required this.remoteNpub,
    required this.endpoint,
    required this.key,
  });
}

class _RelayEndpoint {
  final Socket socket;
  final ServerlessRelayMixin parent;
  Uint8List _readBuffer = Uint8List(0);
  bool _closed = false;
  final void Function(int bytes)? _onActivity;

  _RelayEndpoint(this.socket, this.parent, {void Function(int)? onActivity})
      : _onActivity = onActivity;

  void start() {
    socket.listen(
      _onData,
      onError: (e) {
        parent.relayLog('warn',
            'ServerlessRelay: endpoint socket error: $e');
        close();
      },
      onDone: close,
    );
  }

  void _onData(List<int> chunk) {
    final next = Uint8List(_readBuffer.length + chunk.length)
      ..setRange(0, _readBuffer.length, _readBuffer)
      ..setRange(_readBuffer.length, _readBuffer.length + chunk.length, chunk);
    final (frames, remainder) = RelayMessage.decodeAll(next);
    _readBuffer = remainder;
    for (final f in frames) {
      _onActivity?.call(f.payload.length);
      parent._onEndpointFrame(this, f);
    }
  }

  void write(RelayMessage frame) {
    if (_closed) return;
    try {
      socket.add(frame.encode());
    } catch (e) {
      parent.relayLog('warn', 'ServerlessRelay: write error: $e');
      close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      socket.destroy();
    } catch (_) {}
  }
}

class _RelaySession {
  final String sessionId;
  final String npubA;
  final String npubB;
  final _RelayEndpoint endpointA;
  final _RelayEndpoint endpointB;
  final ServerlessRelayMixin parent;
  final DateTime openedAt = DateTime.now();
  DateTime lastActivity = DateTime.now();
  int bytesAtoB = 0;
  int bytesBtoA = 0;
  Timer? _idleTimer;

  _RelaySession({
    required this.sessionId,
    required this.npubA,
    required this.npubB,
    required this.endpointA,
    required this.endpointB,
    required this.parent,
  });

  void start() {
    _idleTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      // 5 minute idle timeout per spec §10.4.
      if (DateTime.now().difference(lastActivity) >
          const Duration(minutes: 5)) {
        parent.relayLog(
            'info', 'ServerlessRelay: closing idle session $sessionId');
        dispose();
      }
    });
  }

  void forward(_RelayEndpoint from, RelayMessage frame) {
    lastActivity = DateTime.now();
    parent._accountForwardedBytes(frame.payload.length);
    if (identical(from, endpointA)) {
      bytesAtoB += frame.payload.length;
      endpointB.write(frame);
    } else {
      bytesBtoA += frame.payload.length;
      endpointA.write(frame);
    }
  }

  void dispose() {
    _idleTimer?.cancel();
    _idleTimer = null;
    endpointA.close();
    endpointB.close();
    parent._onSessionClosed(sessionId);
  }
}
