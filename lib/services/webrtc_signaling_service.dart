/// WebRTC Signaling Service
///
/// Handles offer/answer/ICE candidate exchange via station WebSocket when
/// available, with DHT rendezvous as the offline fallback.
library;

import 'dart:async';
import 'dart:math';
import '../p2p/p2p_service.dart';
import 'peer_relay_service.dart';
import 'webrtc_config.dart';
import 'websocket_service.dart';
import 'profile_service.dart';
import 'log_service.dart';

/// Callback for received WebRTC signals
typedef WebRTCSignalCallback = void Function(WebRTCSignal signal);

/// WebRTC Signaling Service (Singleton)
///
/// Responsible for:
/// - Sending WebRTC offers, answers, and ICE candidates via WebSocket or DHT
/// - Receiving and dispatching incoming signals to the peer manager
/// - Managing session IDs for connection correlation
class WebRTCSignalingService {
  static final WebRTCSignalingService _instance =
      WebRTCSignalingService._internal();
  factory WebRTCSignalingService() => _instance;
  WebRTCSignalingService._internal();

  final WebSocketService _wsService = WebSocketService();
  final PeerRelayService _peerRelayService = PeerRelayService();
  final _random = Random();

  /// Stream controller for incoming WebRTC signals
  final _signalController = StreamController<WebRTCSignal>.broadcast();

  /// Pending offers waiting for answers (sessionId -> tracker).
  /// We keep the original offer alongside the completer so the WebSocket
  /// `webrtc_error: target_not_connected` handler can transparently retry
  /// the same offer over a different signaling channel (peer relay, DHT).
  final Map<String, _PendingOffer> _pendingOffers = {};

  /// Subscription to WebSocket messages
  StreamSubscription<Map<String, dynamic>>? _wsSubscription;

  /// Subscription to DHT rendezvous signaling messages
  StreamSubscription<Map<String, dynamic>>? _dhtSubscription;

  /// Subscription to peer relay signaling messages
  StreamSubscription<Map<String, dynamic>>? _relaySubscription;

  /// Whether the service is initialized
  bool _initialized = false;

  /// Stream of incoming WebRTC signals
  Stream<WebRTCSignal> get signals => _signalController.stream;

  /// Initialize the signaling service
  void initialize() {
    if (_initialized) return;

    LogService().log('WebRTCSignalingService: Initializing...');

    // Listen for WebRTC messages from WebSocket
    _wsSubscription = _wsService.messages.listen(_handleWebSocketMessage);
    _relaySubscription = _peerRelayService.signalingMessages.listen(
      _handleRelayMessage,
    );
    _dhtSubscription = P2PService().onSignalingMessage.listen(
      _handleDhtMessage,
    );

    _initialized = true;
    LogService().log('WebRTCSignalingService: Initialized');
  }

  /// Dispose resources
  void dispose() {
    _wsSubscription?.cancel();
    _relaySubscription?.cancel();
    _dhtSubscription?.cancel();
    _signalController.close();

    // Cancel any pending offers
    for (final pending in _pendingOffers.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          StateError('Signaling service disposed while waiting for answer'),
        );
      }
    }
    _pendingOffers.clear();

    _initialized = false;
    LogService().log('WebRTCSignalingService: Disposed');
  }

  /// Generate a new session ID for a WebRTC connection
  String generateSessionId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomPart = _random
        .nextInt(0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0');
    return '$timestamp-$randomPart';
  }

  /// Get our callsign from ProfileService
  String get _myCallsign {
    final profile = ProfileService().getProfile();
    return profile.callsign.isNotEmpty ? profile.callsign : 'UNKNOWN';
  }

  /// Send a WebRTC offer and wait for answer
  ///
  /// Returns the answer signal, or throws on timeout/error.
  Future<WebRTCSignal> sendOfferAndWaitForAnswer({
    required String toCallsign,
    required String sessionId,
    required Map<String, dynamic> sdp,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final offer = WebRTCSignal.offer(
      fromCallsign: _myCallsign,
      toCallsign: toCallsign,
      sessionId: sessionId,
      sdp: sdp,
    );

    // Create completer for the answer
    final completer = Completer<WebRTCSignal>();
    final pending = _PendingOffer(completer: completer, offer: offer);
    _pendingOffers[sessionId] = pending;

    // If the DHT rendezvous endpoint isn't cached yet for this peer,
    // kick a one-shot DHT lookup before sending so the offer can ride
    // the direct DHT path instead of bouncing off WS first. Capped at
    // 4s so we don't add latency for peers we can already reach.
    if (!P2PService().canSignalPeer(toCallsign)) {
      await P2PService().findPeerNow(
        toCallsign,
        timeout: const Duration(seconds: 4),
      );
    }

    Timer? wsWatchdog;
    try {
      // Send the offer (records which path it took on the pending tracker)
      await _sendSignal(offer, pending: pending);
      LogService().log(
        'WebRTCSignaling: Sent offer to $toCallsign (session: $sessionId)'
        ' via ${pending.lastPath ?? "unknown"}',
      );

      // WS silent-failure watchdog. The station echoes back
      // `webrtc_error: target_not_connected` when the recipient isn't
      // on the same WS, and that triggers the retry path. But on some
      // station configurations (and when the station is unreachable)
      // we get neither an answer nor an error — just silence. This
      // watchdog treats >3s of WS silence as an implicit failure and
      // fires the same retry the webrtc_error handler would.
      if (pending.lastPath == 'ws') {
        wsWatchdog = Timer(const Duration(seconds: 3), () {
          if (pending.completer.isCompleted) return;
          if (pending.retryStarted) return;
          pending.retryStarted = true;
          pending.triedPaths.add('ws');
          LogService().log(
            'WebRTCSignaling: WS silent for 3s on session $sessionId,'
            ' retrying via next path',
          );
          unawaited(_retryPendingOffer(sessionId, pending));
        });
      }

      // Wait for answer with timeout
      final answer = await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pendingOffers.remove(sessionId);
          throw TimeoutException(
            'No answer received for offer to $toCallsign',
            timeout,
          );
        },
      );

      return answer;
    } catch (e) {
      _pendingOffers.remove(sessionId);
      rethrow;
    } finally {
      wsWatchdog?.cancel();
    }
  }

  /// Send a WebRTC answer (response to an offer)
  Future<void> sendAnswer({
    required String toCallsign,
    required String sessionId,
    required Map<String, dynamic> sdp,
  }) async {
    final answer = WebRTCSignal.answer(
      fromCallsign: _myCallsign,
      toCallsign: toCallsign,
      sessionId: sessionId,
      sdp: sdp,
    );

    await _sendSignal(answer);
    LogService().log(
      'WebRTCSignaling: Sent answer to $toCallsign (session: $sessionId)',
    );
  }

  /// Send an ICE candidate
  Future<void> sendIceCandidate({
    required String toCallsign,
    required String sessionId,
    required Map<String, dynamic> candidate,
  }) async {
    final signal = WebRTCSignal.iceCandidate(
      fromCallsign: _myCallsign,
      toCallsign: toCallsign,
      sessionId: sessionId,
      candidate: candidate,
    );

    await _sendSignal(signal);
    LogService().log(
      'WebRTCSignaling: Sent ICE candidate to $toCallsign (session: $sessionId)',
    );
  }

  /// Send a bye signal to close connection
  Future<void> sendBye({
    required String toCallsign,
    required String sessionId,
  }) async {
    final signal = WebRTCSignal.bye(
      fromCallsign: _myCallsign,
      toCallsign: toCallsign,
      sessionId: sessionId,
    );

    await _sendSignal(signal);
    LogService().log(
      'WebRTCSignaling: Sent bye to $toCallsign (session: $sessionId)',
    );
  }

  /// Send a signal via the first available signaling path.
  ///
  /// Order: DHT (when the peer's UDP rendezvous is cached) → WebSocket
  /// → peer relay → DHT (last-ditch). DHT goes first when we know the
  /// peer's UDP endpoint because that's a direct peer-to-peer hop with
  /// no central station in the path. The station-WebSocket path is
  /// only a useful first try when DHT discovery hasn't converged yet.
  ///
  /// Pass [pending] when sending an offer so the WebSocket-side
  /// `webrtc_error: target_not_connected` handler — and the WS
  /// silent-failure watchdog — can transparently retry on the next
  /// path. [skipPaths] excludes already-failed paths during retries.
  Future<void> _sendSignal(
    WebRTCSignal signal, {
    _PendingOffer? pending,
    Set<String> skipPaths = const {},
  }) async {
    // Prefer DHT when we have the peer's UDP rendezvous cached. This
    // avoids the station-WS round trip (and its silent-failure mode
    // when the recipient isn't on the same WebSocket).
    if (!skipPaths.contains('dht') &&
        P2PService().canSignalPeer(signal.toCallsign)) {
      final sentViaDht = await P2PService().sendSignalingMessage(
        signal.toCallsign,
        signal.toJson(),
      );
      if (sentViaDht) {
        LogService().log(
          'WebRTCSignaling: Sent ${signal.type.name} to ${signal.toCallsign} via DHT rendezvous',
        );
        pending?.lastPath = 'dht';
        pending?.triedPaths.add('dht');
        return;
      }
    }

    if (!skipPaths.contains('ws') && _wsService.isConnected) {
      _wsService.sendWebRTCSignal(signal.toJson());
      pending?.lastPath = 'ws';
      pending?.triedPaths.add('ws');
      return;
    }

    if (!skipPaths.contains('relay')) {
      final sentViaRelay = await _peerRelayService.sendSignalingMessage(
        signal.toCallsign,
        signal.toJson(),
      );
      if (sentViaRelay) {
        LogService().log(
          'WebRTCSignaling: Sent ${signal.type.name} to ${signal.toCallsign} via peer relay',
        );
        pending?.lastPath = 'relay';
        pending?.triedPaths.add('relay');
        return;
      }
    }

    // Last-ditch DHT attempt — even when canSignalPeer reported false
    // initially (it might have flipped true since), let the lower-level
    // sendSignalingMessage take a final shot.
    if (!skipPaths.contains('dht')) {
      final sentViaDht = await P2PService().sendSignalingMessage(
        signal.toCallsign,
        signal.toJson(),
      );
      if (sentViaDht) {
        LogService().log(
          'WebRTCSignaling: Sent ${signal.type.name} to ${signal.toCallsign} via DHT rendezvous (last-ditch)',
        );
        pending?.lastPath = 'dht';
        pending?.triedPaths.add('dht');
        return;
      }
    }

    LogService().log(
      'WebRTCSignaling: No signaling path for ${signal.type.name} to ${signal.toCallsign} (skipped: $skipPaths)',
    );
    throw StateError('No signaling path to ${signal.toCallsign}');
  }

  /// Handle incoming WebSocket messages.
  void _handleWebSocketMessage(Map<String, dynamic> message) {
    // The station can relay back `webrtc_error` when the target peer
    // isn't on the same WebSocket. Treat `target_not_connected` as a
    // signal to retry the offer over the next available path
    // (peer relay, DHT) — the station-WebSocket path is then implicitly
    // out of the running for this session.
    if (message['type'] == 'webrtc_error') {
      final err = message['error'] as String?;
      final sessionId = message['session_id'] as String?;
      if (err == 'target_not_connected' && sessionId != null) {
        final pending = _pendingOffers[sessionId];
        // Stations relay back webrtc_error once per delivery attempt and
        // can emit ~8 of them per offer. Only fire ONE retry: gate on
        // `retryStarted` so duplicate errors are absorbed silently.
        if (pending != null &&
            !pending.completer.isCompleted &&
            !pending.retryStarted) {
          pending.retryStarted = true;
          pending.triedPaths.add('ws');
          unawaited(_retryPendingOffer(sessionId, pending));
        }
      }
      return;
    }
    _handleIncomingSignal(message, source: 'WebSocket');
  }

  /// Re-send a pending offer over the next available signaling path,
  /// skipping any path that already failed for this session. Errors the
  /// completer when no further path is available.
  Future<void> _retryPendingOffer(
    String sessionId,
    _PendingOffer pending,
  ) async {
    try {
      // Before retrying, give the DHT a one-shot chance to discover the
      // peer's UDP rendezvous if we don't have it cached yet. The retry
      // path is reached after WS failed (silently or via webrtc_error),
      // so bouncing through DHT is the most likely successful next hop.
      if (!P2PService().canSignalPeer(pending.offer.toCallsign)) {
        await P2PService().findPeerNow(
          pending.offer.toCallsign,
          timeout: const Duration(seconds: 4),
        );
      }
      LogService().log(
        'WebRTCSignaling: Retrying offer to ${pending.offer.toCallsign} '
        '(session: $sessionId, skip: ${pending.triedPaths})',
      );
      await _sendSignal(pending.offer, pending: pending,
          skipPaths: Set.of(pending.triedPaths));
    } catch (e) {
      _pendingOffers.remove(sessionId);
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(StateError(
          'No remaining signaling path to ${pending.offer.toCallsign}: $e',
        ));
      }
    }
  }

  /// Handle incoming DHT rendezvous messages.
  void _handleDhtMessage(Map<String, dynamic> message) {
    _handleIncomingSignal(message, source: 'DHT');
  }

  /// Handle incoming peer relay messages.
  void _handleRelayMessage(Map<String, dynamic> message) {
    _handleIncomingSignal(message, source: 'PeerRelay');
  }

  void _handleIncomingSignal(
    Map<String, dynamic> message, {
    required String source,
  }) {
    final type = message['type'] as String?;
    if (type == null || !type.startsWith('webrtc_')) {
      return;
    }

    try {
      final signal = WebRTCSignal.fromJson(message);

      // Check if this is an answer to a pending offer
      if (signal.type == WebRTCSignalType.answer) {
        final pending = _pendingOffers.remove(signal.sessionId);
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.complete(signal);
          LogService().log(
            'WebRTCSignaling: Received answer from ${signal.fromCallsign} via $source (session: ${signal.sessionId})',
          );
          return;
        }
      }

      // Emit to stream for peer manager to handle
      _signalController.add(signal);

      LogService().log(
        'WebRTCSignaling: Received ${signal.type.name} from ${signal.fromCallsign} via $source (session: ${signal.sessionId})',
      );
    } catch (e) {
      LogService().log('WebRTCSignaling: Error parsing $source signal: $e');
    }
  }

  /// Check if we're connected to the station (can send signals)
  bool get isConnected => _wsService.isConnected;

  /// Check whether there is any signaling path to a peer.
  bool canSignalPeer(String callsign) {
    return _wsService.isConnected ||
        _peerRelayService.canRelayTo(callsign) ||
        P2PService().canSignalPeer(callsign);
  }
}

/// Tracks an in-flight offer so the WebSocket-error handler can retry
/// it on the next signaling channel. [triedPaths] accumulates the
/// channels we've already attempted; [lastPath] is the most recent.
class _PendingOffer {
  _PendingOffer({required this.completer, required this.offer});
  final Completer<WebRTCSignal> completer;
  final WebRTCSignal offer;
  final Set<String> triedPaths = {};
  String? lastPath;

  /// True once we've fired a retry for this session. Stops duplicate
  /// `webrtc_error` messages (stations emit ~8 of them) from queueing
  /// repeated DHT/relay sends for the same offer.
  bool retryStarted = false;
}
