/// Mirror Notification Mixin — notifies connected devices when other devices
/// with the same callsign connect or disconnect.
///
/// Shared by both `StationServer` (Desktop) and `PureStationServer` (CLI).
/// Enables multi-device sync discovery through the station relay.
library;

import 'dart:convert';
import 'dart:io';

/// Minimal client interface for mirror notifications.
abstract class MirrorClient {
  String get id;
  String? get callsign;
  String? get npub;
  String? get platform;
  String? get deviceType;
  String? get address; // Remote IP stored at connection time
  String? get deviceId; // Per-install UUID for NAT-safe dedup
  String? get nickname; // User-chosen device name
  bool get verified;
  WebSocket get socket;
}

/// Mixin providing mirror device notifications shared across station implementations.
///
/// When a device connects or disconnects, all other verified devices with the
/// same callsign are notified with an updated mirrors list.
mixin MirrorNotifyMixin {
  // ── Abstract contract ────────────────────────────────────────────

  /// Return all connected clients.
  Map<String, MirrorClient> get mirrorClients;

  /// Log a message at the given level.
  void mirrorLog(String level, String message);

  /// Safely send data to a client socket. Returns true on success.
  bool mirrorSafeSocketSend(covariant MirrorClient client, String data);

  // ── Mirror notification ─────────────────────────────────────────

  /// Build the mirrors list for a given callsign (excluding a specific client).
  List<Map<String, dynamic>> buildMirrorsList(String callsign, {String? excludeClientId}) {
    final upper = callsign.toUpperCase();
    return mirrorClients.values
        .where((c) =>
            c.callsign?.toUpperCase() == upper &&
            c.verified &&
            c.id != excludeClientId)
        .map((c) => {
              'device_id': c.id,
              'install_id': c.deviceId,
              'platform': c.platform ?? 'unknown',
              'device_type': c.deviceType ?? 'unknown',
              'npub': c.npub,
              'nickname': c.nickname,
              'verified': c.verified,
            })
        .toList();
  }

  /// Count verified mirrors for a callsign (excluding a specific client).
  int mirrorCountForCallsign(String callsign, {String? excludeClientId}) {
    return buildMirrorsList(callsign, excludeClientId: excludeClientId).length;
  }

  /// Notify all verified devices with the given callsign about their current mirrors.
  ///
  /// Called after a new device connects (hello_ack) or an existing device disconnects.
  void notifyMirrorsOfCallsign(String callsign) {
    final upper = callsign.toUpperCase();
    final matchingClients = mirrorClients.values
        .where((c) => c.callsign?.toUpperCase() == upper && c.verified)
        .toList();

    if (matchingClients.isEmpty) return;

    for (final client in matchingClients) {
      final mirrors = buildMirrorsList(callsign, excludeClientId: client.id);
      final message = jsonEncode({
        'type': 'mirrors_update',
        'callsign': callsign,
        'mirrors': mirrors,
      });
      mirrorSafeSocketSend(client, message);
    }

    mirrorLog('INFO', 'Notified ${matchingClients.length} devices of mirror update for $callsign');
  }

  /// Find zombie connections from the same physical device.
  /// Matches by callsign + npub + device_id (unique per install).
  /// Falls back to address match when device_id is absent (legacy clients).
  List<String> findZombieConnections({
    required String clientId,
    required String callsign,
    required String npub,
    required String? address,
    required String? deviceId,
  }) {
    final upper = callsign.toUpperCase();
    return mirrorClients.values
        .where((c) {
          if (c.id == clientId) return false;
          if (c.callsign?.toUpperCase() != upper) return false;
          if (c.npub != npub) return false;
          // If both have device_id, match on that (NAT-safe)
          if (deviceId != null && c.deviceId != null) {
            return c.deviceId == deviceId;
          }
          // If only one has device_id, they're clearly different installs — no dedup
          if (deviceId != null || c.deviceId != null) {
            return false;
          }
          // Fallback for legacy clients where neither has device_id: match on IP
          return address != null && c.address == address;
        })
        .map((c) => c.id)
        .toList();
  }

  /// Handle GET /api/mirrors — return mirrors for the requester's callsign.
  ///
  /// Identifies the requester by remote IP matching against connected clients.
  Future<void> handleMirrorsRequest(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;

    final remoteIp = request.connectionInfo?.remoteAddress.address;
    if (remoteIp == null) {
      request.response.statusCode = 400;
      request.response.write(jsonEncode({
        'success': false,
        'error': 'Cannot determine remote address',
      }));
      return;
    }

    // Find a verified client from this IP
    MirrorClient? requester;
    for (final client in mirrorClients.values) {
      if (client.verified && client.address == remoteIp) {
        requester = client;
        break;
      }
    }

    if (requester == null || requester.callsign == null) {
      request.response.statusCode = 403;
      request.response.write(jsonEncode({
        'success': false,
        'error': 'No verified connection from this address',
      }));
      return;
    }

    final mirrors = buildMirrorsList(requester.callsign!, excludeClientId: requester.id);
    request.response.write(jsonEncode({
      'success': true,
      'callsign': requester.callsign,
      'mirrors': mirrors,
    }));
  }
}
