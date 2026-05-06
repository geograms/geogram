/// NOSTR-DM signaling channel for WebRTC (BT-DHT-v2 §8).
///
/// Pure-Dart NIP-44 v2 encrypted DMs as the rendezvous for SDP and ICE
/// exchange. The data shape is the spec's:
/// ```
/// {
///   "type":    "offer" | "answer" | "candidate" | "bye",
///   "session": <16-byte hex session id>,
///   "data":    <SDP string | candidate object>,
///   "ts":      <unix ms>
/// }
/// ```
/// Payload is wrapped in a kind-30078 `applicationSpecificData` event with
/// tags `[["p", recipientNpubHex], ["d", "geogram-signaling-v1"]]` so it
/// is parameterized-replaceable per recipient and trickle-friendly.
///
/// The channel reuses `NostrClientService` for relay connections — no new
/// sockets — and publishes to every connected write-enabled relay.
/// Listeners deduplicate by event id (the same event can arrive on
/// multiple relays).
library;

import 'dart:async';
import 'dart:convert';

import '../../models/profile.dart';
import '../../services/log_service.dart';
import '../../services/profile_service.dart';
import '../../services/signing_service.dart';
import '../../services/webrtc_config.dart';
import '../../util/nip44_v2.dart';
import '../../util/nostr_crypto.dart';
import '../../util/nostr_event.dart';
import 'models/nostr_relay_config.dart';
import 'nostr_client_service.dart';

const String kSignalingDTag = 'geogram-signaling-v1';
const String kPresenceDTag = 'geogram-presence-v1';

class NostrSignalingChannel {
  NostrSignalingChannel._();
  static final NostrSignalingChannel _instance = NostrSignalingChannel._();
  factory NostrSignalingChannel() => _instance;

  final LogService _log = LogService();
  final _signals = StreamController<WebRTCSignal>.broadcast();
  final Set<String> _seenEventIds = {};
  StreamSubscription<NostrEvent>? _rawSub;
  bool _started = false;

  /// Stream of inbound signaling messages addressed to this profile.
  /// Listeners are responsible for routing by `toCallsign`/`sessionId`.
  Stream<WebRTCSignal> get incomingSignals => _signals.stream;

  bool get isStarted => _started;

  /// Subscribe to NIP-44 DMs across the user's configured NOSTR relays.
  /// Idempotent — call from `WebRTCSignalingService.initialize`.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final profile = ProfileService().getProfile();
    if (profile.npub.isEmpty) {
      _log.warn('NostrSignaling: no profile npub, channel idle');
      return;
    }

    final ourPubHex = NostrCrypto.decodeNpub(profile.npub);

    final clients = NostrClientService();

    // Bootstrap default relays if the user hasn't configured any. The
    // serverless P2P signaling path can't function without at least one
    // connected relay, and on a fresh install no relays are populated
    // until the user visits the NOSTR settings page. `addRelay` just
    // persists the config — we then call `connect` explicitly so the
    // websocket actually opens. Already-configured relays will have been
    // connected by `NostrClientService.autoStart` at app boot.
    if (clients.relays.isEmpty) {
      for (final relay in NostrRelayConfig.defaults) {
        await clients.addRelay(relay);
        if (relay.enabled) clients.connect(relay.id);
      }
      _log.info(
          'NostrSignaling: bootstrapped ${NostrRelayConfig.defaults.length} default relays for serverless P2P');
    } else {
      // Ensure pre-configured-but-disconnected relays are dialed.
      for (final relay in clients.relays) {
        if (relay.enabled && !clients.isConnected(relay.id)) {
          clients.connect(relay.id);
        }
      }
    }

    // Open a narrow signaling-only subscription on every read-enabled
    // relay. Persists across reconnects (relay clients re-emit their
    // active subscription set on each reconnect).
    final n = clients.subscribeAll({
      'kinds': [NostrEventKind.applicationSpecificData],
      '#p': [ourPubHex],
      '#d': [kSignalingDTag],
    }, subscriptionId: 'geogram-signaling');
    _log.info('NostrSignaling: subscribed on $n relay(s)');

    _rawSub = clients.rawEvents.listen((event) {
      if (event.kind != NostrEventKind.applicationSpecificData) return;
      // Filter: must be signaling-tagged AND addressed to us.
      bool sigTag = false;
      bool pTag = false;
      for (final t in event.tags) {
        if (t.length < 2) continue;
        if (t[0] == 'd' && t[1] == kSignalingDTag) sigTag = true;
        if (t[0] == 'p' && t[1] == ourPubHex) pTag = true;
      }
      if (!sigTag || !pTag) return;
      if (event.id != null && !_seenEventIds.add(event.id!)) return;
      _decodeAndDispatch(event, profile);
    });
    _log.info(
        'NostrSignaling: started for ${profile.callsign} (${clients.relays.length} relays)');
  }

  Future<void> stop() async {
    _started = false;
    await _rawSub?.cancel();
    _rawSub = null;
  }

  /// Send a [signal] to the holder of [toNpub] (bech32 npub1...). Returns
  /// the number of relays the EVENT frame was sent to. The caller does
  /// not wait for OK acks — at least one publish is good enough since the
  /// receiver subscribes on the same relay set.
  Future<int> sendSignal({
    required String toNpub,
    required WebRTCSignal signal,
  }) async {
    // Lazy self-start so a direct sendSignal call (e.g. from
    // /api/p2p/serverless/signal in tests) ensures relays are
    // bootstrapped + connected even if WebRTCSignalingService.initialize
    // hasn't fired yet.
    if (!_started) await start();

    final profile = ProfileService().getProfile();
    if (profile.nsec.isEmpty || profile.npub.isEmpty) {
      _log.warn('NostrSignaling: cannot send — profile missing keys');
      return 0;
    }
    String theirPubHex;
    String ourPubHex;
    try {
      theirPubHex = NostrCrypto.decodeNpub(toNpub);
      ourPubHex = NostrCrypto.decodeNpub(profile.npub);
    } catch (e) {
      _log.warn('NostrSignaling: bad npub: $e');
      return 0;
    }
    final ourSecHex = NostrCrypto.decodeNsec(profile.nsec);

    final payload = {
      'type': _signalTypeWire(signal.type),
      'session': signal.sessionId,
      'data': signal.sdp ?? signal.candidate,
      'ts': signal.timestamp,
      'from_callsign': signal.fromCallsign,
      'to_callsign': signal.toCallsign,
    };
    final ciphertext = Nip44V2.encrypt(
      jsonEncode(payload),
      ourSecHex,
      theirPubHex,
    );

    final event = NostrEvent(
      pubkey: ourPubHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.applicationSpecificData,
      tags: [
        ['p', theirPubHex],
        ['d', kSignalingDTag],
      ],
      content: ciphertext,
    );

    final signed = await SigningService().signEvent(event, profile);
    if (signed == null) {
      _log.warn('NostrSignaling: signing failed');
      return 0;
    }
    // Relays connect asynchronously after addRelay. Retry briefly so the
    // first signal isn't lost when this is the bootstrap call that just
    // installed defaults.
    var sent = NostrClientService().publishSigned(signed);
    var attempt = 0;
    while (sent == 0 && attempt < 3) {
      await Future<void>.delayed(const Duration(seconds: 1));
      sent = NostrClientService().publishSigned(signed);
      attempt++;
    }
    _log.info(
        'NostrSignaling: sent ${signal.type.name} to ${_shortNpub(toNpub)} via $sent relay(s)'
        '${attempt > 0 ? " (after ${attempt}s wait)" : ""}');
    return sent;
  }

  // ─── internals ────────────────────────────────────────────────────

  void _decodeAndDispatch(NostrEvent event, Profile profile) {
    try {
      final ourSecHex = NostrCrypto.decodeNsec(profile.nsec);
      final plaintext = Nip44V2.decrypt(
        event.content,
        ourSecHex,
        event.pubkey,
      );
      final json = jsonDecode(plaintext) as Map<String, dynamic>;
      final typeStr = json['type'] as String?;
      final sessionId = json['session'] as String?;
      final ts = json['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch;
      final fromCallsign = json['from_callsign'] as String? ?? '';
      final toCallsign = json['to_callsign'] as String? ?? profile.callsign;
      if (typeStr == null || sessionId == null) return;

      WebRTCSignalType? type;
      Map<String, dynamic>? sdp;
      Map<String, dynamic>? candidate;
      switch (typeStr) {
        case 'offer':
          type = WebRTCSignalType.offer;
          sdp = (json['data'] as Map?)?.cast<String, dynamic>();
          break;
        case 'answer':
          type = WebRTCSignalType.answer;
          sdp = (json['data'] as Map?)?.cast<String, dynamic>();
          break;
        case 'candidate':
          type = WebRTCSignalType.iceCandidate;
          candidate = (json['data'] as Map?)?.cast<String, dynamic>();
          break;
        case 'bye':
          type = WebRTCSignalType.bye;
          break;
      }
      if (type == null) return;
      _signals.add(WebRTCSignal(
        type: type,
        fromCallsign: fromCallsign,
        toCallsign: toCallsign,
        sessionId: sessionId,
        sdp: sdp,
        candidate: candidate,
        timestamp: ts,
      ));
    } catch (e) {
      _log.warn('NostrSignaling: decrypt/decode error: $e');
    }
  }

  static String _signalTypeWire(WebRTCSignalType t) {
    switch (t) {
      case WebRTCSignalType.offer:
        return 'offer';
      case WebRTCSignalType.answer:
        return 'answer';
      case WebRTCSignalType.iceCandidate:
        return 'candidate';
      case WebRTCSignalType.bye:
        return 'bye';
    }
  }

  static String _shortNpub(String npub) {
    if (npub.length <= 12) return npub;
    return '${npub.substring(0, 8)}…${npub.substring(npub.length - 4)}';
  }
}

