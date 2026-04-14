/*
 * Cross-wapp event broker
 *
 * Singleton routing pub/sub between WASM modules. Each [WappEngine]
 * registers an opaque engineId on load, subscribes to topics on demand
 * (via hal_event_subscribe), and drains pending events from its private
 * queue (via hal_event_available + hal_event_recv).
 *
 * publish() fans out an event to every engine that is subscribed to the
 * topic, appending to each engine's queue. It also fires a
 * [WappEventBridgeEvent] on the host [EventBus] so Dart-side observers
 * can watch wapp pub/sub traffic for debugging or bridging.
 */

import 'dart:collection';

import 'event_bus.dart';

class _PendingEvent {
  final String topic;
  final String data;
  _PendingEvent(this.topic, this.data);
}

class _EngineState {
  final Set<String> subscribedTopics = {};
  final Queue<_PendingEvent> queue = Queue();
}

class WappEventBroker {
  WappEventBroker._();
  static final WappEventBroker instance = WappEventBroker._();

  /// Cap a single engine's queue so a runaway publisher cannot drown the
  /// host. Drops the oldest event when full.
  static const int maxQueuePerEngine = 1024;

  final Map<String, _EngineState> _engines = {};

  /// Register a wapp engine. Idempotent.
  void registerEngine(String engineId) {
    _engines.putIfAbsent(engineId, _EngineState.new);
  }

  /// Unregister and drop all queued events + subscriptions for [engineId].
  void unregisterEngine(String engineId) {
    _engines.remove(engineId);
  }

  /// Subscribe [engineId] to [topic]. Returns 0 on success, -1 if the
  /// engine is unknown.
  int subscribe(String engineId, String topic) {
    final state = _engines[engineId];
    if (state == null) return -1;
    state.subscribedTopics.add(topic);
    return 0;
  }

  /// Unsubscribe [engineId] from [topic]. Returns 0 on success, -1 if
  /// the engine is unknown.
  int unsubscribe(String engineId, String topic) {
    final state = _engines[engineId];
    if (state == null) return -1;
    state.subscribedTopics.remove(topic);
    return 0;
  }

  /// Publish [data] on [topic]. Delivered to every engine that has
  /// subscribed to the exact topic string, including [fromEngineId]
  /// itself if it is subscribed. Returns the number of engines notified.
  int publish(String fromEngineId, String topic, String data) {
    var notified = 0;
    for (final entry in _engines.entries) {
      final state = entry.value;
      if (!state.subscribedTopics.contains(topic)) continue;
      if (state.queue.length >= maxQueuePerEngine) {
        state.queue.removeFirst();
      }
      state.queue.add(_PendingEvent(topic, data));
      notified++;
    }
    EventBus().fire(WappEventBridgeEvent(
      fromEngineId: fromEngineId,
      topic: topic,
      data: data,
    ));
    return notified;
  }

  /// Bytes-of-data of the next pending event for [engineId], or 0 if
  /// the queue is empty / engine unknown. Wapps poll this from
  /// hal_event_available before calling [recv].
  int availableSize(String engineId) {
    final state = _engines[engineId];
    if (state == null || state.queue.isEmpty) return 0;
    return state.queue.first.data.length;
  }

  /// Pop the next pending event for [engineId] or return null if none.
  ({String topic, String data})? recv(String engineId) {
    final state = _engines[engineId];
    if (state == null || state.queue.isEmpty) return null;
    final ev = state.queue.removeFirst();
    return (topic: ev.topic, data: ev.data);
  }

  // ── Inspection helpers (debug API / future task monitor UI) ────────

  int subscriptionCount(String engineId) =>
      _engines[engineId]?.subscribedTopics.length ?? 0;

  int queueDepth(String engineId) => _engines[engineId]?.queue.length ?? 0;

  Iterable<String> registeredEngines() => _engines.keys;
}
