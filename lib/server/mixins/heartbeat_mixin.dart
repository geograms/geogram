import 'dart:async';
import 'dart:convert';

/// Mixin providing WebSocket client heartbeat (PING/PONG) and stale connection cleanup.
///
/// Stations must implement the abstract members to bridge their specific
/// client map, logging, socket-send, and cleanup helpers.
mixin HeartbeatMixin {
  // ── Constants ──────────────────────────────────────────────────────────
  static const int heartbeatIntervalSeconds = 30;
  static const int staleClientTimeoutSeconds = 300;

  // ── State (owned by the mixin) ─────────────────────────────────────────
  Timer? _heartbeatTimer;

  // ── Abstract contract ──────────────────────────────────────────────────
  /// All currently connected clients keyed by ID.
  /// The values must expose at least `lastActivity` (DateTime) and
  /// `callsign` (String?).
  Map<String, dynamic> get heartbeatClients;

  /// Log a message at the given level.
  void heartbeatLog(String level, String message);

  /// Safely send [data] to the client identified by the map value.
  bool heartbeatSend(dynamic client, String data);

  /// Remove a client by ID with the given reason.
  void heartbeatRemoveClient(String clientId, {String reason});

  /// Run periodic cleanup (expired bans, stale rate-limit entries, etc.).
  void heartbeatCleanup();

  // ── Public API ─────────────────────────────────────────────────────────
  void startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: heartbeatIntervalSeconds),
      (_) => performHeartbeat(),
    );
    heartbeatLog('INFO',
        'Heartbeat started (interval: ${heartbeatIntervalSeconds}s, timeout: ${staleClientTimeoutSeconds}s)');
  }

  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void performHeartbeat() {
    final now = DateTime.now();
    final staleThreshold =
        now.subtract(const Duration(seconds: staleClientTimeoutSeconds));
    final clientsToRemove = <String>[];

    for (final entry in heartbeatClients.entries) {
      final clientId = entry.key;
      final client = entry.value;

      if ((client.lastActivity as DateTime).isBefore(staleThreshold)) {
        heartbeatLog('WARN',
            'Stale client detected: ${client.callsign ?? clientId} (last activity: ${client.lastActivity})');
        clientsToRemove.add(clientId);
        continue;
      }

      heartbeatSend(client, jsonEncode({
        'type': 'PING',
        'timestamp': now.millisecondsSinceEpoch,
      }));
    }

    for (final clientId in clientsToRemove) {
      heartbeatRemoveClient(clientId, reason: 'stale connection');
    }

    if (clientsToRemove.isNotEmpty) {
      heartbeatLog('INFO',
          'Removed ${clientsToRemove.length} stale client(s). Active clients: ${heartbeatClients.length}');
    }

    heartbeatCleanup();
  }
}
