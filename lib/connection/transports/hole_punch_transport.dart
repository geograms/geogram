/// Hole-punch transport — adapter that exposes HolePunchService to
/// ConnectionManager.
///
/// All the heavy lifting (signaling, hole punch, reliable framing,
/// session management) lives in `lib/p2p/hole_punch_service.dart`.
/// This file only translates between TransportMessage (the chat-app
/// shape) and the byte-stream API the service exposes, so the rest
/// of the app's transport routing keeps working.
///
/// External callers — anything that wants to use hole-punch directly
/// for non-chat data — should use `HolePunchService` instead of going
/// through this transport.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../p2p/hole_punch_protocol.dart';
import '../../p2p/hole_punch_service.dart';
import '../../p2p/p2p_service.dart';
import '../../services/devices_service.dart';
import '../../services/log_service.dart';
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

  StreamSubscription<HolePunchSession>? _incomingSub;
  final Map<String, StreamSubscription<Uint8List>> _dataSubs = {};

  @override
  Future<void> initialize() async {
    LogService().log('HolePunchTransport: Initializing...');
    HolePunchService().start();
    _incomingSub =
        HolePunchService().incomingSessions.listen(_onIncomingSession);
    markInitialized();
    LogService().log('HolePunchTransport: Initialized');
  }

  @override
  Future<void> dispose() async {
    await _incomingSub?.cancel();
    _incomingSub = null;
    for (final sub in _dataSubs.values) {
      await sub.cancel();
    }
    _dataSubs.clear();
    await disposeMixin();
  }

  @override
  Future<bool> canReach(String callsign) async {
    final cs = callsign.toUpperCase();
    final existing = HolePunchService().getSession(cs);
    if (existing != null && existing.isReady) return true;
    if (kIsWeb) return false;
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
    final s = HolePunchService().getSession(callsign);
    if (s != null && s.isReady) return 80;
    if (await canReach(callsign)) return 50;
    return 0;
  }

  @override
  Future<TransportResult> send(
    TransportMessage message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final t0 = DateTime.now();
    final cs = message.targetCallsign.toUpperCase();
    final session = await HolePunchService().connect(cs);
    if (session == null || !session.isReady) {
      final r = TransportResult.failure(
          error: 'hole-punch session unavailable', transportUsed: id);
      recordMetrics(r);
      return r;
    }
    _ensureDataSub(session);

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

  Map<String, dynamic> getStatus() => HolePunchService().getStatus();

  // ── internals ───────────────────────────────────────────────────

  void _onIncomingSession(HolePunchSession session) {
    _ensureDataSub(session);
  }

  void _ensureDataSub(HolePunchSession session) {
    if (_dataSubs.containsKey(session.callsign)) return;
    _dataSubs[session.callsign] = session.onData.listen(
      (bytes) => _onPayload(session.callsign, bytes),
      onDone: () {
        _dataSubs.remove(session.callsign);
      },
    );
  }

  void _onPayload(String callsign, Uint8List bytes) {
    try {
      final msg = _decodeMessage(bytes);
      if (msg != null) emitIncomingMessage(msg);
    } catch (e) {
      LogService()
          .log('HolePunchTransport: failed to decode payload from $callsign: $e');
    }
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
}
