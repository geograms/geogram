/*
 * HostEventBridge — republishes host [EventBus] events onto the cross-
 * wapp [WappEventBroker] under stable `system.*` topic names.
 *
 * This is the "trigger" side of the event bus: wapps can call
 * `hal_event_subscribe("system.wapp.loaded")` (or any other bridged
 * topic) and react to host-level events, not just events from other
 * wapps. Without this bridge, host and wapp event namespaces would be
 * fully isolated.
 *
 * One-way only — wapp events do NOT get republished on the host
 * EventBus by this bridge. That direction is already handled by
 * [WappEventBroker.publish] firing [WappEventBridgeEvent].
 *
 * Published topics:
 *
 *   system.app.started       — geogram launcher finished booting
 *   system.wapp.loaded       — a wapp finished module_init
 *   system.wapp.unloaded     — a wapp page disposed
 *   system.wapp.crashed      — a wapp threw during load / tick / event
 *   system.error             — an ErrorEvent fired on the host bus
 *
 * Payloads are JSON strings. The schema per topic is stable; do not
 * rename fields without adding a version bump.
 */

import 'dart:convert';

import 'event_bus.dart';
import 'wapp_event_broker.dart';

class HostEventBridge {
  HostEventBridge._();
  static final HostEventBridge instance = HostEventBridge._();

  /// Synthetic engineId used as the `fromEngineId` on bridged events.
  /// Wapps can check `from` in the `WappEventBridgeEvent` payload to
  /// distinguish host-originated events from wapp-originated ones.
  static const String hostEngineId = 'host';

  /// Cancel callbacks for every bridged subscription. Stored as
  /// closures rather than typed [EventSubscription] instances because
  /// Dart generics are invariant — a `List<EventSubscription<AppEvent>>`
  /// cannot hold the subclass subscriptions we actually create.
  final List<void Function()> _cancelers = [];
  bool _installed = false;

  /// Subscribe to host events and republish them on the wapp broker.
  /// Idempotent — second calls are no-ops.
  void install() {
    if (_installed) return;
    _installed = true;

    _bridge<AppStartedEvent>(
      'system.app.started',
      (_) => const {},
    );
    _bridge<WappLoadedEvent>(
      'system.wapp.loaded',
      (e) => {'wappId': e.wappId, 'wappName': e.wappName},
    );
    _bridge<WappUnloadedEvent>(
      'system.wapp.unloaded',
      (e) => {'wappId': e.wappId, 'wappName': e.wappName},
    );
    _bridge<WappCrashedEvent>(
      'system.wapp.crashed',
      (e) => {
        'wappId': e.wappId,
        'phase': e.phase,
        'error': e.error.toString(),
      },
    );
    _bridge<ErrorEvent>(
      'system.error',
      (e) => {'source': e.source, 'message': e.message},
    );
  }

  void _bridge<T extends AppEvent>(
    String topic,
    Map<String, dynamic> Function(T event) encode,
  ) {
    final sub = EventBus().on<T>((event) {
      final payload = json.encode(encode(event));
      WappEventBroker.instance.publish(hostEngineId, topic, payload);
    });
    _cancelers.add(sub.cancel);
  }

  /// Tear down every subscription. Tests should call this between
  /// cases so the singleton doesn't leak handlers across runs.
  void uninstall() {
    for (final cancel in _cancelers) {
      cancel();
    }
    _cancelers.clear();
    _installed = false;
  }
}
