/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * WebSocket client for a single NOSTR relay.
 * Uses web_socket_channel (event-driven, no isolate needed).
 * Auto-reconnect with exponential backoff.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../services/log_service.dart';
import '../../util/nostr_event.dart';
import 'models/nostr_relay_config.dart';

class NostrRelayClient {
  final NostrRelayConfig config;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _running = false;
  bool _connected = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  /// Subscriptions keyed by subscription ID.
  final Map<String, Map<String, dynamic>> _activeSubscriptions = {};

  /// Callback for incoming relay responses.
  void Function(NostrRelayResponse response)? onResponse;

  /// Callback for connection state changes.
  void Function(bool connected)? onConnectionChanged;

  NostrRelayClient({required this.config});

  bool get isConnected => _connected;
  bool get isRunning => _running;

  /// Connect to the relay.
  Future<void> connect() async {
    if (_running) return;
    _running = true;
    _reconnectAttempts = 0;
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (!_running) return;
    try {
      final uri = Uri.parse(config.url);
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _connected = true;
      _reconnectAttempts = 0;
      onConnectionChanged?.call(true);
      LogService().log('NostrRelayClient: connected to ${config.url}');

      // Re-subscribe existing subscriptions after reconnect
      for (final entry in _activeSubscriptions.entries) {
        _sendRaw(jsonEncode(
          NostrRelayMessage.req(entry.key, entry.value),
        ));
      }

      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: (error) {
          LogService().log('NostrRelayClient[${config.id}]: stream error: $error');
          _handleDisconnect();
        },
        onDone: () {
          _handleDisconnect();
        },
      );
    } catch (e) {
      LogService().log('NostrRelayClient[${config.id}]: connect error: $e');
      _connected = false;
      onConnectionChanged?.call(false);
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    final response = NostrRelayMessage.parse(data);
    if (response != null) {
      onResponse?.call(response);
    }
  }

  void _handleDisconnect() {
    _connected = false;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    onConnectionChanged?.call(false);
    if (_running) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_running) return;
    _reconnectTimer?.cancel();
    // Exponential backoff: 2s, 4s, 8s, 16s, 30s max
    final delay = min(30, 2 * pow(2, _reconnectAttempts)).toInt();
    _reconnectAttempts++;
    LogService().log(
      'NostrRelayClient[${config.id}]: reconnecting in ${delay}s '
      '(attempt $_reconnectAttempts)',
    );
    _reconnectTimer = Timer(Duration(seconds: delay), _doConnect);
  }

  /// Subscribe to events matching a NIP-01 filter.
  /// Returns the subscription ID.
  String subscribe(Map<String, dynamic> filter, {String? subscriptionId}) {
    final subId = subscriptionId ?? 'sub_${DateTime.now().millisecondsSinceEpoch}';
    _activeSubscriptions[subId] = filter;
    if (_connected) {
      _sendRaw(jsonEncode(NostrRelayMessage.req(subId, filter)));
    }
    return subId;
  }

  /// Close a subscription.
  void unsubscribe(String subscriptionId) {
    _activeSubscriptions.remove(subscriptionId);
    if (_connected) {
      _sendRaw(jsonEncode(NostrRelayMessage.close(subscriptionId)));
    }
  }

  /// Publish a signed event to the relay.
  void publish(NostrEvent event) {
    if (!_connected) return;
    _sendRaw(jsonEncode(NostrRelayMessage.event(event)));
  }

  void _sendRaw(String data) {
    try {
      _channel?.sink.add(data);
    } catch (e) {
      LogService().log('NostrRelayClient[${config.id}]: send error: $e');
    }
  }

  /// Disconnect from the relay.
  void disconnect() {
    _running = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _subscription = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    if (_connected) {
      _connected = false;
      onConnectionChanged?.call(false);
    }
    _activeSubscriptions.clear();
  }
}
