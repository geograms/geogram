/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BlueAPRS — APRS over Bluetooth Low Energy bridge service.
 *
 * Acts as both an iGate (BLE ↔ APRS-IS) and a repeater (BLE ↔ BLE).
 * Reuses the existing BLE chat protocol with a `_aprs` system channel
 * and the `aprs` capability flag.
 *
 * Architecture:
 *   BLE Clients ── BLEMessageService ── BlueAprsService ── AprsService ── APRS-IS
 *                   (channel: _aprs)      (bridge)          (existing)
 */

import 'dart:async';
import 'dart:convert';

import '../../models/ble_message.dart';
import '../../services/ble_message_service.dart';
import '../../services/log_service.dart';
import 'aprs_service.dart';
import 'models/aprs_packet.dart';

/// APRS over BLE bridge — singleton service.
class BlueAprsService {
  static final BlueAprsService _instance = BlueAprsService._internal();
  factory BlueAprsService() => _instance;
  BlueAprsService._internal();

  static const String _aprsChannel = '_aprs';
  static const Duration _rateLimitWindow = Duration(seconds: 30);

  bool _active = false;
  bool get isActive => _active;

  // Beacon
  Timer? _beaconTimer;
  int _beaconIntervalSec = 300;
  bool _beaconEnabled = false;

  // Subscriptions
  StreamSubscription<BLEChatMessage>? _bleChatSub;
  StreamSubscription<AprsEvent>? _aprsEventSub;

  // Callsign tracking: deviceId → callsign (from HELLO handshake author field)
  final Map<String, String> _bleCallsigns = {};

  // Rate limiting: deviceId → last transmit time
  final Map<String, DateTime> _rateLimits = {};

  // Dedup for APRS-IS → BLE push (avoid re-pushing same packet)
  final Set<String> _pushedPacketHashes = {};
  static const int _maxPushedHashes = 500;

  // Stats
  int _txCount = 0;
  int _rxCount = 0;
  int _repeatCount = 0;

  int get txCount => _txCount;
  int get rxCount => _rxCount;
  int get repeatCount => _repeatCount;

  // Simulated BLE client inbox for debug API testing
  final Map<String, List<Map<String, dynamic>>> _simulatedInbox = {};

  /// Simulated (test) clients registered via debug API
  final Set<String> _simulatedDeviceIds = {};

  /// Activate the BlueAPRS bridge.
  void activate() {
    if (_active) return;
    _active = true;

    final ble = BLEMessageService();
    ble.enableAprsCapability();

    // iGate TX: listen for BLE messages on _aprs channel
    _bleChatSub = ble.incomingChats
        .where((msg) => msg.channel == _aprsChannel)
        .listen(_onBleChat);

    // iGate RX: listen for APRS-IS events
    _aprsEventSub = AprsService().events
        .where((e) => e.type == AprsEventType.messageReceived)
        .listen((_) => _pushRelevantPacketsToBle());

    LogService().log('BlueAprsService: activated');
  }

  /// Start periodic beacon broadcasting.
  void startBeacon(int intervalSec) {
    stopBeacon();
    _beaconIntervalSec = intervalSec;
    _beaconEnabled = true;
    _beaconTimer = Timer.periodic(
      Duration(seconds: intervalSec),
      (_) => _sendBeacon(),
    );
    LogService().log('BlueAprsService: beacon started (${intervalSec}s interval)');
  }

  /// Stop beacon broadcasting.
  void stopBeacon() {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _beaconEnabled = false;
  }

  /// Broadcast position beacon to BLE clients on _aprs channel.
  void _sendBeacon() {
    if (!_active) return;
    final aprs = AprsService();
    final lat = aprs.savedLatitude;
    final lon = aprs.savedLongitude;
    final callsign = aprs.callsign;
    if (lat == null || lon == null || callsign == null) return;

    final payload = BLEAprsPayload(
      type: 'position',
      from: callsign,
      text: '',
      lat: lat,
      lon: lon,
      comment: 'BlueAPRS beacon',
    );

    final contentJson = json.encode(payload.toJson());

    try {
      BLEMessageService().broadcastChat(
        channel: _aprsChannel,
        content: contentJson,
      );
      LogService().log('BlueAprsService: beacon sent ($lat, $lon)');
    } catch (e) {
      LogService().log('BlueAprsService: beacon send failed: $e');
    }

    // Also deliver to simulated clients
    for (final simId in _simulatedDeviceIds) {
      _simulatedInbox.putIfAbsent(simId, () => []).add({
        'from': callsign,
        'text': '',
        'type': 'position',
        'lat': lat,
        'lon': lon,
        'comment': 'BlueAPRS beacon',
        'timestamp': DateTime.now().toIso8601String(),
        'source': 'beacon',
      });
    }
  }

  /// Deactivate the BlueAPRS bridge.
  void deactivate() {
    if (!_active) return;
    _active = false;
    stopBeacon();
    _bleChatSub?.cancel();
    _bleChatSub = null;
    _aprsEventSub?.cancel();
    _aprsEventSub = null;
    _bleCallsigns.clear();
    _rateLimits.clear();
    _pushedPacketHashes.clear();
    _simulatedInbox.clear();
    _simulatedDeviceIds.clear();
    _txCount = 0;
    _rxCount = 0;
    _repeatCount = 0;
    LogService().log('BlueAprsService: deactivated');
  }

  /// Get status for debug API.
  Map<String, dynamic> getStatus() {
    final clients = <Map<String, dynamic>>[];
    for (final entry in _bleCallsigns.entries) {
      clients.add({
        'deviceId': entry.key,
        'callsign': entry.value,
        'simulated': _simulatedDeviceIds.contains(entry.key),
      });
    }
    return {
      'active': _active,
      'beaconEnabled': _beaconEnabled,
      'beaconIntervalSec': _beaconIntervalSec,
      'bleClients': clients,
      'stats': {
        'txCount': _txCount,
        'rxCount': _rxCount,
        'repeatCount': _repeatCount,
      },
    };
  }

  // ---------------------------------------------------------------------------
  // iGate TX: BLE → APRS-IS
  // ---------------------------------------------------------------------------

  /// Handle incoming BLE chat on _aprs channel.
  void _onBleChat(BLEChatMessage msg) {
    // Track callsign from author
    if (msg.author.isNotEmpty) {
      _bleCallsigns[msg.deviceId] = msg.author;
    }

    // Rate limit (skip for simulated test clients)
    final now = DateTime.now();
    if (!_simulatedDeviceIds.contains(msg.deviceId)) {
      final lastTx = _rateLimits[msg.deviceId];
      if (lastTx != null && now.difference(lastTx) < _rateLimitWindow) {
        LogService().log(
          'BlueAprsService: rate-limited ${msg.author} (${msg.deviceId})',
        );
        return;
      }
    }

    // Parse APRS payload from content JSON
    BLEAprsPayload payload;
    try {
      final decoded = json.decode(msg.content);
      if (decoded is! Map<String, dynamic>) {
        LogService().log('BlueAprsService: invalid APRS payload (not a map)');
        return;
      }
      payload = BLEAprsPayload.fromJson(decoded);
    } catch (e) {
      LogService().log('BlueAprsService: failed to parse APRS payload: $e');
      return;
    }

    // Validate
    final error = payload.validate();
    if (error != null) {
      LogService().log('BlueAprsService: invalid APRS payload: $error');
      return;
    }

    _rateLimits[msg.deviceId] = now;

    final aprs = AprsService();

    // Route based on type
    switch (payload.type) {
      case 'message':
        final sent = aprs.sendMessage(payload.to!, payload.text);
        if (sent != null) {
          _txCount++;
          LogService().log(
            'BlueAprsService: iGate TX message ${msg.author} → ${payload.to}: ${payload.text}',
          );
        }
        break;

      case 'geochat':
        final sent = aprs.sendGeoChat(payload.text);
        if (sent != null) {
          _txCount++;
          LogService().log(
            'BlueAprsService: iGate TX geochat from ${msg.author}: ${payload.text}',
          );
        }
        break;

      case 'position':
        // Position-only report — send as geochat with comment
        final comment = payload.comment ?? payload.text;
        if (comment.isNotEmpty) {
          final sent = aprs.sendGeoChat(comment);
          if (sent != null) {
            _txCount++;
            LogService().log(
              'BlueAprsService: iGate TX position from ${msg.author}',
            );
          }
        }
        break;
    }

    // BLE → BLE repeater: forward to other APRS-capable BLE clients
    _repeatToOtherClients(msg.deviceId, msg.content);
  }

  /// Public entry point for debug API injection (simulates BLE client).
  Map<String, dynamic> injectBleAprsMessage({
    required String callsign,
    required BLEAprsPayload payload,
    String? deviceId,
  }) {
    final devId = deviceId ?? _deviceIdForCallsign(callsign) ?? 'sim-unknown';

    // Track callsign
    _bleCallsigns[devId] = callsign;

    // Build synthetic BLEChatMessage
    final msg = BLEChatMessage(
      deviceId: devId,
      author: callsign,
      content: json.encode(payload.toJson()),
      channel: _aprsChannel,
      timestamp: DateTime.now(),
    );

    _onBleChat(msg);

    return {
      'success': true,
      'forwarded': true,
      'deviceId': devId,
    };
  }

  // ---------------------------------------------------------------------------
  // iGate RX: APRS-IS → BLE
  // ---------------------------------------------------------------------------

  /// Check recent APRS messages and push relevant ones to BLE clients.
  void _pushRelevantPacketsToBle() {
    final aprs = AprsService();
    final messages = aprs.messages;
    if (messages.isEmpty || _bleCallsigns.isEmpty) return;

    // Build reverse map: callsign → deviceId
    final callsignToDevice = <String, String>{};
    for (final entry in _bleCallsigns.entries) {
      callsignToDevice[entry.value.toUpperCase()] = entry.key;
    }

    // Check last few messages for ones addressed to our BLE clients
    final checkCount = messages.length < 10 ? messages.length : 10;
    for (int i = messages.length - 1;
        i >= messages.length - checkCount && i >= 0;
        i--) {
      final pkt = messages[i];
      if (pkt.isOutgoing) continue;

      final addressee = pkt.messageAddressee?.toUpperCase();
      if (addressee == null) continue;

      final targetDeviceId = callsignToDevice[addressee];
      if (targetDeviceId == null) continue;

      // Dedup
      final hash = '${pkt.fromCallsign}\x00${pkt.messageText}\x00${pkt.timestamp.millisecondsSinceEpoch}';
      if (_pushedPacketHashes.contains(hash)) continue;
      _pushedPacketHashes.add(hash);
      if (_pushedPacketHashes.length > _maxPushedHashes) {
        _pushedPacketHashes.remove(_pushedPacketHashes.first);
      }

      // Build _aprs channel payload for BLE client
      final aprsPayload = BLEAprsPayload(
        from: pkt.fromCallsign,
        to: addressee,
        text: pkt.messageText ?? '',
        type: 'message',
        msgId: pkt.messageId,
        lat: pkt.latitude,
        lon: pkt.longitude,
      );

      _sendToBleClient(targetDeviceId, aprsPayload);
      _rxCount++;

      LogService().log(
        'BlueAprsService: iGate RX pushed ${pkt.fromCallsign} → $addressee to BLE',
      );
    }
  }

  /// Push relevant packets for a specific injected APRS packet (debug API).
  Map<String, dynamic> injectAprsPacket({
    required String from,
    required String to,
    required String text,
    double? lat,
    double? lon,
  }) {
    final aprs = AprsService();

    // Build a synthetic AprsPacket and add it to the service
    final infoField = ':${to.toUpperCase().padRight(9)}:$text{1';
    final rawTnc2 = '$from>APRS::${to.toUpperCase().padRight(9)}:$text{1';
    final packet = AprsPacket(
      fromCallsign: from,
      toCallsign: 'APRS',
      infoField: infoField,
      rawTnc2: rawTnc2,
      timestamp: DateTime.now().toUtc(),
      type: AprsPacketType.message,
      messageAddressee: to.toUpperCase(),
      messageText: text,
      messageId: '1',
      latitude: lat,
      longitude: lon,
    );

    aprs.addPacket(packet);

    // Now push to BLE
    final callsignUpper = to.toUpperCase();
    String? targetDeviceId;
    for (final entry in _bleCallsigns.entries) {
      if (entry.value.toUpperCase() == callsignUpper) {
        targetDeviceId = entry.key;
        break;
      }
    }

    if (targetDeviceId != null) {
      final aprsPayload = BLEAprsPayload(
        from: from,
        to: callsignUpper,
        text: text,
        type: 'message',
        msgId: '1',
        lat: lat,
        lon: lon,
      );
      _sendToBleClient(targetDeviceId, aprsPayload);
      _rxCount++;
      LogService().log(
        'BlueAprsService: iGate RX pushed $from → $callsignUpper to BLE',
      );
      return {
        'success': true,
        'routedToBle': true,
        'targetDeviceId': targetDeviceId,
      };
    }

    return {
      'success': true,
      'routedToBle': false,
      'error': 'No BLE client with callsign $to',
    };
  }

  // ---------------------------------------------------------------------------
  // BLE → BLE Repeater
  // ---------------------------------------------------------------------------

  /// Forward an APRS message to all other APRS-capable BLE clients.
  void _repeatToOtherClients(String senderDeviceId, String contentJson) {
    final ble = BLEMessageService();
    final clients = ble.connectedClients;

    for (final clientId in clients) {
      if (clientId == senderDeviceId) continue;
      if (!ble.peerSupportsAprs(clientId)) continue;

      _sendRawToBleClient(clientId, contentJson);
      _repeatCount++;
    }

    // Also forward to simulated clients (for testing)
    for (final simId in _simulatedDeviceIds) {
      if (simId == senderDeviceId) continue;

      // Parse and store in simulated inbox
      try {
        final decoded = json.decode(contentJson);
        if (decoded is Map<String, dynamic>) {
          final payload = BLEAprsPayload.fromJson(decoded);
          _simulatedInbox.putIfAbsent(simId, () => []).add({
            'from': payload.from ?? _bleCallsigns[senderDeviceId] ?? 'unknown',
            'to': payload.to,
            'text': payload.text,
            'type': payload.type,
            'timestamp': DateTime.now().toIso8601String(),
            'source': 'repeat',
          });
          _repeatCount++;
        }
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // BLE send helpers
  // ---------------------------------------------------------------------------

  /// Send a structured APRS payload to a BLE client.
  void _sendToBleClient(String deviceId, BLEAprsPayload payload) {
    final contentJson = json.encode(payload.toJson());

    // If this is a simulated client, store in inbox instead
    if (_simulatedDeviceIds.contains(deviceId)) {
      _simulatedInbox.putIfAbsent(deviceId, () => []).add({
        'from': payload.from ?? 'unknown',
        'to': payload.to,
        'text': payload.text,
        'type': payload.type,
        'msgId': payload.msgId,
        'timestamp': DateTime.now().toIso8601String(),
      });
      return;
    }

    _sendRawToBleClient(deviceId, contentJson);
  }

  /// Send raw JSON content on the _aprs channel to a BLE client.
  void _sendRawToBleClient(String deviceId, String contentJson) {
    try {
      BLEMessageService().sendChatToClient(
        deviceId: deviceId,
        content: contentJson,
        channel: _aprsChannel,
      );
    } catch (e) {
      LogService().log(
        'BlueAprsService: failed to send to BLE client $deviceId: $e',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Simulated client management (debug API)
  // ---------------------------------------------------------------------------

  /// Register a simulated BLE client for testing.
  Map<String, dynamic> registerSimulatedClient({
    required String deviceId,
    required String callsign,
  }) {
    _bleCallsigns[deviceId] = callsign;
    _simulatedDeviceIds.add(deviceId);
    _simulatedInbox.putIfAbsent(deviceId, () => []);

    LogService().log(
      'BlueAprsService: registered simulated client $deviceId ($callsign)',
    );

    final clients = <Map<String, dynamic>>[];
    for (final entry in _bleCallsigns.entries) {
      clients.add({
        'deviceId': entry.key,
        'callsign': entry.value,
        'simulated': _simulatedDeviceIds.contains(entry.key),
      });
    }

    return {
      'success': true,
      'registeredClients': clients,
    };
  }

  /// Get simulated client inbox.
  Map<String, dynamic> getClientInbox(String deviceId) {
    final messages = _simulatedInbox[deviceId];
    if (messages == null) {
      return {
        'success': false,
        'error': 'No simulated client with deviceId $deviceId',
      };
    }
    return {
      'success': true,
      'messages': messages,
    };
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Find deviceId for a callsign.
  String? _deviceIdForCallsign(String callsign) {
    final upper = callsign.toUpperCase();
    for (final entry in _bleCallsigns.entries) {
      if (entry.value.toUpperCase() == upper) return entry.key;
    }
    return null;
  }
}
