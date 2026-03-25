library;

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart' as shelf;

import '../connection/routing_strategy.dart';
import '../connection/transport_message.dart';
import '../util/managed_http_client.dart';
import 'devices_service.dart';
import 'log_service.dart';
import 'profile_service.dart';

class PeerRelayEnvelope {
  final String id;
  final String kind;
  final String fromCallsign;
  final String toCallsign;
  final String? transportType;
  final String? requestId;
  final String? method;
  final String? path;
  final Map<String, String>? headers;
  final dynamic payload;
  final Map<String, dynamic>? signedEvent;
  final Map<String, dynamic>? signal;
  final DateTime createdAt;

  const PeerRelayEnvelope({
    required this.id,
    required this.kind,
    required this.fromCallsign,
    required this.toCallsign,
    this.transportType,
    this.requestId,
    this.method,
    this.path,
    this.headers,
    this.payload,
    this.signedEvent,
    this.signal,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'from_callsign': fromCallsign,
        'to_callsign': toCallsign,
        if (transportType != null) 'transport_type': transportType,
        if (requestId != null) 'request_id': requestId,
        if (method != null) 'method': method,
        if (path != null) 'path': path,
        if (headers != null) 'headers': headers,
        if (payload != null) 'payload': payload,
        if (signedEvent != null) 'signed_event': signedEvent,
        if (signal != null) 'signal': signal,
        'created_at': createdAt.toIso8601String(),
      };

  factory PeerRelayEnvelope.fromJson(Map<String, dynamic> json) {
    Map<String, String>? headers;
    final rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      headers = rawHeaders.map(
        (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
      );
    }

    return PeerRelayEnvelope(
      id: json['id'] as String,
      kind: json['kind'] as String,
      fromCallsign: (json['from_callsign'] as String).toUpperCase(),
      toCallsign: (json['to_callsign'] as String).toUpperCase(),
      transportType: json['transport_type'] as String?,
      requestId: json['request_id'] as String?,
      method: json['method'] as String?,
      path: json['path'] as String?,
      headers: headers,
      payload: json['payload'],
      signedEvent: (json['signed_event'] as Map?)?.cast<String, dynamic>(),
      signal: (json['signal'] as Map?)?.cast<String, dynamic>(),
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  factory PeerRelayEnvelope.fromTransportMessage(
    TransportMessage message, {
    required String fromCallsign,
  }) {
    final requestId = message.type == TransportMessageType.apiResponse
        ? _extractResponseRequestId(message.payload) ?? message.id
        : message.id;

    return PeerRelayEnvelope(
      id: message.id,
      kind: 'transport',
      fromCallsign: fromCallsign.toUpperCase(),
      toCallsign: message.targetCallsign.toUpperCase(),
      transportType: message.type.name,
      requestId: requestId,
      method: message.method,
      path: message.path,
      headers: message.headers,
      payload: message.payload,
      signedEvent: message.signedEvent,
      createdAt: message.createdAt,
    );
  }

  factory PeerRelayEnvelope.signal({
    required String toCallsign,
    required String fromCallsign,
    required Map<String, dynamic> signal,
  }) {
    return PeerRelayEnvelope(
      id: signal['id'] as String? ??
          '${DateTime.now().millisecondsSinceEpoch}-${signal['session_id'] ?? 'signal'}',
      kind: 'signal',
      fromCallsign: fromCallsign.toUpperCase(),
      toCallsign: toCallsign.toUpperCase(),
      signal: signal,
      createdAt: DateTime.now(),
    );
  }

  static String? _extractResponseRequestId(dynamic payload) {
    if (payload is Map) {
      final requestId = payload['id'];
      return requestId is String ? requestId : null;
    }
    if (payload is String && payload.isNotEmpty) {
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map && decoded['id'] is String) {
          return decoded['id'] as String;
        }
      } catch (_) {}
    }
    return null;
  }
}

class PeerRelayService {
  static final PeerRelayService _instance = PeerRelayService._internal();
  factory PeerRelayService() => _instance;
  PeerRelayService._internal();

  static const Duration _pollTimeout = Duration(seconds: 20);
  static const Duration _pollRequestTimeout = Duration(seconds: 30);
  static const Duration _candidateRefreshInterval = Duration(seconds: 15);
  static const Duration _queueRetention = Duration(minutes: 3);
  static const Duration _seenRetention = Duration(minutes: 5);
  static const int _maxRelayCandidates = 3;
  static const int _maxMessagesPerPoll = 25;

  final ManagedHttpClient _client = ManagedHttpClient();
  final _transportController = StreamController<PeerRelayEnvelope>.broadcast();
  final _signalController = StreamController<Map<String, dynamic>>.broadcast();

  final Map<String, List<_QueuedRelayEnvelope>> _queuedByTarget = {};
  final Map<String, Completer<void>> _pollWaiters = {};
  final Map<String, DateTime> _seenEnvelopeIds = {};
  final Map<String, _RelayPollerState> _pollers = {};

  Timer? _candidateRefreshTimer;
  bool _initialized = false;

  Stream<PeerRelayEnvelope> get transportEnvelopes => _transportController.stream;
  Stream<Map<String, dynamic>> get signalingMessages => _signalController.stream;

  List<String> get activeRelayUrls => _pollers.keys.toList()..sort();

  bool get hasRelayCandidates => _selectRelayCandidates().isNotEmpty;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _candidateRefreshTimer = Timer.periodic(
      _candidateRefreshInterval,
      (_) => _syncPollers(),
    );
    unawaited(_syncPollers());
    LogService().log('PeerRelayService: Initialized');
  }

  Future<void> dispose() async {
    _candidateRefreshTimer?.cancel();
    _candidateRefreshTimer = null;
    _initialized = false;
    _pollers.clear();
    _pollWaiters.clear();
    _queuedByTarget.clear();
    _seenEnvelopeIds.clear();
    await _transportController.close();
    await _signalController.close();
    _client.close();
    LogService().log('PeerRelayService: Disposed');
  }

  void notifyRelayCandidatesChanged() {
    if (!_initialized) return;
    unawaited(_syncPollers());
  }

  bool canRelayTo(String callsign) {
    if (!_initialized) return false;
    final normalized = callsign.toUpperCase();
    return normalized.isNotEmpty &&
        normalized != _myCallsign &&
        _selectRelayCandidates().isNotEmpty;
  }

  Future<bool> sendTransportMessage(TransportMessage message) async {
    final envelope = PeerRelayEnvelope.fromTransportMessage(
      message,
      fromCallsign: _myCallsign,
    );
    return _sendEnvelope(envelope);
  }

  Future<bool> sendSignalingMessage(
    String toCallsign,
    Map<String, dynamic> signal,
  ) async {
    final envelope = PeerRelayEnvelope.signal(
      toCallsign: toCallsign,
      fromCallsign: _myCallsign,
      signal: signal,
    );
    return _sendEnvelope(envelope);
  }

  Map<String, dynamic> getStatus() {
    final candidates = _selectRelayCandidates();
    return {
      'initialized': _initialized,
      'my_callsign': _myCallsign,
      'relay_candidates': candidates
          .map(
            (candidate) => {
              'callsign': candidate.callsign,
              'url': candidate.baseUrl,
            },
          )
          .toList(),
      'active_relays': activeRelayUrls,
      'queued_targets': _queuedByTarget.map(
        (key, value) => MapEntry(key, value.length),
      ),
    };
  }

  Future<shelf.Response> handleSendRequest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final envelope = PeerRelayEnvelope.fromJson(body);
      _enqueueEnvelope(envelope);
      return shelf.Response.ok(
        jsonEncode({
          'success': true,
          'queued_for': envelope.toCallsign,
          'id': envelope.id,
        }),
        headers: headers,
      );
    } catch (e) {
      LogService().log('PeerRelayService: send request error: $e');
      return shelf.Response.badRequest(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: headers,
      );
    }
  }

  Future<shelf.Response> handlePollRequest(
    shelf.Request request,
    Map<String, String> headers,
  ) async {
    final callsign =
        request.url.queryParameters['callsign']?.trim().toUpperCase() ?? '';
    if (callsign.isEmpty) {
      return shelf.Response.badRequest(
        body: jsonEncode({
          'success': false,
          'error': 'Missing callsign',
        }),
        headers: headers,
      );
    }

    final timeoutSeconds =
        int.tryParse(request.url.queryParameters['timeout'] ?? '') ??
        _pollTimeout.inSeconds;
    final timeout = Duration(
      seconds: timeoutSeconds.clamp(1, _pollRequestTimeout.inSeconds),
    );

    final messages = await _dequeueOrWait(
      callsign,
      timeout: timeout,
      limit: _maxMessagesPerPoll,
    );
    return shelf.Response.ok(
      jsonEncode({
        'success': true,
        'messages': messages.map((message) => message.toJson()).toList(),
      }),
      headers: headers,
    );
  }

  Future<bool> _sendEnvelope(PeerRelayEnvelope envelope) async {
    final candidates = _selectRelayCandidates();
    if (candidates.isEmpty) {
      LogService().log(
        'PeerRelayService: No relay candidate available for ${envelope.toCallsign}',
      );
      return false;
    }

    var anySuccess = false;
    for (final candidate in candidates) {
      final uri = Uri.parse('${candidate.baseUrl}/api/p2p/relay/send');
      try {
        final response = await _client
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(envelope.toJson()),
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          anySuccess = true;
        } else {
          LogService().log(
            'PeerRelayService: relay ${candidate.baseUrl} rejected ${envelope.id} '
            'with ${response.statusCode}',
          );
        }
      } catch (e) {
        LogService().log(
          'PeerRelayService: relay send via ${candidate.baseUrl} failed: $e',
        );
      }
    }
    return anySuccess;
  }

  Future<void> _syncPollers() async {
    if (!_initialized) return;

    final candidates = _selectRelayCandidates();
    final desired = {for (final candidate in candidates) candidate.baseUrl: candidate};

    for (final baseUrl in _pollers.keys.toList()) {
      if (!desired.containsKey(baseUrl)) {
        _pollers.remove(baseUrl);
      }
    }

    for (final candidate in candidates) {
      if (_pollers.containsKey(candidate.baseUrl)) continue;
      final state = _RelayPollerState(candidate: candidate, token: _nextToken());
      _pollers[candidate.baseUrl] = state;
      unawaited(_runPollLoop(state));
    }

    PriorityRoutingStrategy.clearCache();
  }

  Future<void> _runPollLoop(_RelayPollerState state) async {
    while (_initialized) {
      final current = _pollers[state.candidate.baseUrl];
      if (current == null || current.token != state.token) {
        return;
      }

      final uri = Uri.parse('${state.candidate.baseUrl}/api/p2p/relay/poll')
          .replace(
        queryParameters: {
          'callsign': _myCallsign,
          'timeout': _pollTimeout.inSeconds.toString(),
        },
      );

      try {
        final response = await _client
            .get(uri)
            .timeout(_pollRequestTimeout);
        if (response.statusCode != 200) {
          LogService().log(
            'PeerRelayService: poll ${state.candidate.baseUrl} failed '
            'with ${response.statusCode}',
          );
          await Future.delayed(const Duration(seconds: 3));
          continue;
        }

        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final messages = body['messages'] as List<dynamic>? ?? const [];
        for (final raw in messages) {
          if (raw is! Map<String, dynamic>) continue;
          final envelope = PeerRelayEnvelope.fromJson(raw);
          if (_markEnvelopeSeen(envelope.id)) {
            _dispatchEnvelope(envelope);
          }
        }
      } catch (e) {
        LogService().log(
          'PeerRelayService: poll ${state.candidate.baseUrl} error: $e',
        );
        await Future.delayed(const Duration(seconds: 3));
      }
    }
  }

  void _dispatchEnvelope(PeerRelayEnvelope envelope) {
    if (envelope.kind == 'signal' && envelope.signal != null) {
      if (!_signalController.isClosed) {
        _signalController.add(envelope.signal!);
      }
      return;
    }

    if (!_transportController.isClosed) {
      _transportController.add(envelope);
    }
  }

  void _enqueueEnvelope(PeerRelayEnvelope envelope) {
    _purgeExpiredQueueEntries();
    final key = envelope.toCallsign.toUpperCase();
    final queue = _queuedByTarget.putIfAbsent(key, () => <_QueuedRelayEnvelope>[]);
    queue.add(_QueuedRelayEnvelope(envelope: envelope, queuedAt: DateTime.now()));
    _pollWaiters.remove(key)?.complete();
  }

  Future<List<PeerRelayEnvelope>> _dequeueOrWait(
    String callsign, {
    required Duration timeout,
    required int limit,
  }) async {
    _purgeExpiredQueueEntries();

    final immediate = _takeQueuedEnvelopes(callsign, limit);
    if (immediate.isNotEmpty) {
      return immediate;
    }

    final waiter = Completer<void>();
    _pollWaiters[callsign] = waiter;
    try {
      await waiter.future.timeout(timeout);
    } catch (_) {
      // Timeout is expected for long-polling.
    } finally {
      final current = _pollWaiters[callsign];
      if (current == waiter) {
        _pollWaiters.remove(callsign);
      }
    }

    return _takeQueuedEnvelopes(callsign, limit);
  }

  List<PeerRelayEnvelope> _takeQueuedEnvelopes(String callsign, int limit) {
    final key = callsign.toUpperCase();
    final queue = _queuedByTarget[key];
    if (queue == null || queue.isEmpty) return const [];

    final taken = queue.take(limit).map((item) => item.envelope).toList();
    queue.removeRange(0, taken.length);
    if (queue.isEmpty) {
      _queuedByTarget.remove(key);
    }
    return taken;
  }

  bool _markEnvelopeSeen(String id) {
    _purgeExpiredSeenEntries();
    if (_seenEnvelopeIds.containsKey(id)) {
      return false;
    }
    _seenEnvelopeIds[id] = DateTime.now();
    return true;
  }

  void _purgeExpiredQueueEntries() {
    final now = DateTime.now();
    _queuedByTarget.removeWhere((_, queue) {
      queue.removeWhere(
        (item) => now.difference(item.queuedAt) > _queueRetention,
      );
      return queue.isEmpty;
    });
  }

  void _purgeExpiredSeenEntries() {
    final now = DateTime.now();
    _seenEnvelopeIds.removeWhere(
      (_, seenAt) => now.difference(seenAt) > _seenRetention,
    );
  }

  List<_RelayCandidate> _selectRelayCandidates() {
    final myCallsign = _myCallsign;
    final devices = DevicesService().getAllDevices();
    final candidates = <_RelayCandidate>[];
    final seenUrls = <String>{};

    for (final device in devices) {
      if (device.callsign.toUpperCase() == myCallsign) continue;
      if (!device.canRelay) continue;

      final relayUrl = device.relayUrl ?? device.url;
      if (relayUrl == null || relayUrl.isEmpty) continue;
      if (!seenUrls.add(relayUrl)) continue;

      candidates.add(
        _RelayCandidate(
          callsign: device.callsign.toUpperCase(),
          baseUrl: relayUrl,
        ),
      );
    }

    candidates.sort((a, b) {
      final byUrl = a.baseUrl.compareTo(b.baseUrl);
      if (byUrl != 0) return byUrl;
      return a.callsign.compareTo(b.callsign);
    });

    if (candidates.length > _maxRelayCandidates) {
      return candidates.take(_maxRelayCandidates).toList(growable: false);
    }
    return candidates;
  }

  String get _myCallsign {
    try {
      final profile = ProfileService().getProfile();
      return profile.callsign.toUpperCase();
    } catch (_) {
      return 'UNKNOWN';
    }
  }

  String _nextToken() =>
      '${DateTime.now().microsecondsSinceEpoch}-${activeRelayUrls.length}';
}

class _QueuedRelayEnvelope {
  final PeerRelayEnvelope envelope;
  final DateTime queuedAt;

  const _QueuedRelayEnvelope({
    required this.envelope,
    required this.queuedAt,
  });
}

class _RelayCandidate {
  final String callsign;
  final String baseUrl;

  const _RelayCandidate({
    required this.callsign,
    required this.baseUrl,
  });
}

class _RelayPollerState {
  final _RelayCandidate candidate;
  final String token;

  const _RelayPollerState({
    required this.candidate,
    required this.token,
  });
}
