/// WebRTC Signaling Service
///
/// Handles offer/answer/ICE candidate exchange via station WebSocket when
/// available, with DHT rendezvous as the offline fallback.
library;

import 'dart:async';
import 'dart:math';
import '../p2p/p2p_service.dart';
import '../teleport/nostr/nostr_signaling_channel.dart';
import 'devices_service.dart';
import 'peer_relay_service.dart';
import 'serverless_settings_service.dart';
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

  /// Pending offers waiting for answers (sessionId -> completer)
  final Map<String, Completer<WebRTCSignal>> _pendingOffers = {};

  /// Subscription to WebSocket messages
  StreamSubscription<Map<String, dynamic>>? _wsSubscription;

  /// Subscription to DHT rendezvous signaling messages
  StreamSubscription<Map<String, dynamic>>? _dhtSubscription;

  /// Subscription to peer relay signaling messages
  StreamSubscription<Map<String, dynamic>>? _relaySubscription;

  /// Subscription to NIP-44 NOSTR-DM signaling messages (BT-DHT-v2 §8).
  StreamSubscription<WebRTCSignal>? _nostrSubscription;

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

    // BT-DHT-v2 §8: NOSTR NIP-44 DM signaling. Gated on the master switch
    // so users with serverless P2P disabled do not pay the relay
    // subscription cost.
    final settings = ServerlessSettingsService();
    if (settings.current.enableServerless &&
        settings.current.nostrSignalingEnabled) {
      unawaited(NostrSignalingChannel().start());
      _nostrSubscription =
          NostrSignalingChannel().incomingSignals.listen(_handleNostrSignal);
      LogService().log('WebRTCSignalingService: NOSTR-DM path enabled');
    }

    _initialized = true;
    LogService().log('WebRTCSignalingService: Initialized');
  }

  /// Dispose resources
  void dispose() {
    _wsSubscription?.cancel();
    _relaySubscription?.cancel();
    _dhtSubscription?.cancel();
    _nostrSubscription?.cancel();
    _signalController.close();

    // Cancel any pending offers
    for (final completer in _pendingOffers.values) {
      if (!completer.isCompleted) {
        completer.completeError(
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
    _pendingOffers[sessionId] = completer;

    try {
      // Send the offer
      await _sendSignal(offer);
      LogService().log(
        'WebRTCSignaling: Sent offer to $toCallsign (session: $sessionId)',
      );

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

  /// Send a signal via WebSocket when connected, otherwise over DHT rendezvous.
  Future<void> _sendSignal(WebRTCSignal signal) async {
    if (_wsService.isConnected) {
      _wsService.sendWebRTCSignal(signal.toJson());
      return;
    }

    final sentViaRelay = await _peerRelayService.sendSignalingMessage(
      signal.toCallsign,
      signal.toJson(),
    );
    if (sentViaRelay) {
      LogService().log(
        'WebRTCSignaling: Sent ${signal.type.name} to ${signal.toCallsign} via peer relay',
      );
      return;
    }

    // BT-DHT-v2 §8: NIP-44 NOSTR DM. Works whenever we know the peer's
    // npub and at least one configured NOSTR relay is connected — i.e.
    // the serverless path that doesn't require Geogram station infrastructure.
    final settings = ServerlessSettingsService().current;
    if (settings.enableServerless && settings.nostrSignalingEnabled) {
      final theirNpub = _resolveNpubForCallsign(signal.toCallsign);
      if (theirNpub != null) {
        final n = await NostrSignalingChannel().sendSignal(
          toNpub: theirNpub,
          signal: signal,
        );
        if (n > 0) {
          LogService().log(
            'WebRTCSignaling: Sent ${signal.type.name} to ${signal.toCallsign} '
            'via NOSTR DM ($n relays)',
          );
          return;
        }
      }
    }

    final sentViaDht = await P2PService().sendSignalingMessage(
      signal.toCallsign,
      signal.toJson(),
    );
    if (!sentViaDht) {
      LogService().log(
        'WebRTCSignaling: No signaling path for ${signal.type.name} to ${signal.toCallsign}',
      );
      throw StateError('No signaling path to ${signal.toCallsign}');
    }

    LogService().log(
      'WebRTCSignaling: Sent ${signal.type.name} to ${signal.toCallsign} via DHT rendezvous',
    );
  }

  /// Look up the recipient's bech32 npub by callsign via DevicesService.
  /// Returns null when the device isn't known or has no npub recorded.
  String? _resolveNpubForCallsign(String callsign) {
    try {
      final dev = DevicesService().getDevice(callsign);
      final npub = dev?.npub;
      if (npub == null || npub.isEmpty) return null;
      return npub.startsWith('npub1') ? npub : null;
    } catch (_) {
      return null;
    }
  }

  /// Handle incoming WebSocket messages.
  void _handleWebSocketMessage(Map<String, dynamic> message) {
    _handleIncomingSignal(message, source: 'WebSocket');
  }

  /// Handle incoming DHT rendezvous messages.
  void _handleDhtMessage(Map<String, dynamic> message) {
    _handleIncomingSignal(message, source: 'DHT');
  }

  /// Handle incoming peer relay messages.
  void _handleRelayMessage(Map<String, dynamic> message) {
    _handleIncomingSignal(message, source: 'PeerRelay');
  }

  /// Handle incoming NOSTR-DM signals (already decrypted into WebRTCSignal).
  void _handleNostrSignal(WebRTCSignal signal) {
    if (signal.type == WebRTCSignalType.answer) {
      final completer = _pendingOffers.remove(signal.sessionId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(signal);
        LogService().log(
          'WebRTCSignaling: Received answer from ${signal.fromCallsign} '
          'via NostrDM (session: ${signal.sessionId})',
        );
        return;
      }
    }
    _signalController.add(signal);
    LogService().log(
      'WebRTCSignaling: Received ${signal.type.name} from '
      '${signal.fromCallsign} via NostrDM (session: ${signal.sessionId})',
    );
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
        final completer = _pendingOffers.remove(signal.sessionId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(signal);
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
