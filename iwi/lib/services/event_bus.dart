/*
 * geogram event bus
 *
 * Type-safe broadcast event channel for cross-component communication
 * inside the geogram Flutter host (iwi/). API mirrors the parent repo's
 * lib/util/event_bus.dart so a shared package can be extracted later.
 *
 * Use this for host-side signalling between services, the launcher, and
 * the UI. Cross-WASM-module pub/sub goes through wapp_event_broker.dart
 * — that broker fires [WappEventBridgeEvent] here so Dart-side observers
 * can also listen in.
 */

import 'dart:async';

/// Base class for every event fired through [EventBus].
abstract class AppEvent {
  final DateTime timestamp;
  AppEvent() : timestamp = DateTime.now();
}

/// Subscription handle returned by [EventBus.on]. Call [cancel] to detach.
class EventSubscription<T extends AppEvent> {
  final StreamSubscription<T> _subscription;
  EventSubscription(this._subscription);
  void cancel() => _subscription.cancel();
}

/// Singleton broadcast bus for [AppEvent]s.
class EventBus {
  EventBus._internal();
  static final EventBus _instance = EventBus._internal();
  factory EventBus() => _instance;

  final Map<Type, StreamController<dynamic>> _controllers = {};

  StreamController<T> _getController<T extends AppEvent>() {
    return _controllers.putIfAbsent(T, () => StreamController<T>.broadcast())
        as StreamController<T>;
  }

  /// Subscribe to events of type [T].
  EventSubscription<T> on<T extends AppEvent>(void Function(T event) handler) {
    final controller = _getController<T>();
    final subscription = controller.stream.listen(handler);
    return EventSubscription<T>(subscription);
  }

  /// Fire an event to all subscribers of its concrete type.
  void fire<T extends AppEvent>(T event) {
    // Use runtimeType so subclasses dispatch correctly even when fire() is
    // called via the base type.
    final controller = _controllers[event.runtimeType];
    if (controller != null && !controller.isClosed) {
      controller.add(event);
    }
  }

  bool hasSubscribers<T extends AppEvent>() {
    final controller = _controllers[T];
    return controller != null && controller.hasListener;
  }

  /// Close all controllers. Test-only helper.
  void reset() {
    for (final controller in _controllers.values) {
      controller.close();
    }
    _controllers.clear();
  }
}

// ── Common host events ──────────────────────────────────────────────

/// Fire-once after the launcher has finished initialising. Background
/// services that should run after startup can subscribe to this.
class AppStartedEvent extends AppEvent {}

/// A wapp finished loading and its module_init returned successfully.
class WappLoadedEvent extends AppEvent {
  final String wappId;
  final String wappName;
  WappLoadedEvent({required this.wappId, required this.wappName});
}

/// A wapp was unloaded (page closed, dispose called).
class WappUnloadedEvent extends AppEvent {
  final String wappId;
  final String wappName;
  WappUnloadedEvent({required this.wappId, required this.wappName});
}

/// A wapp crashed during init/tick/handle_event.
class WappCrashedEvent extends AppEvent {
  final String wappId;
  final String phase; // 'init' | 'tick' | 'handle_event' | 'load'
  final Object error;
  WappCrashedEvent({
    required this.wappId,
    required this.phase,
    required this.error,
  });
}

/// Cross-WASM-module event bridged from the WappEventBroker so that
/// host-side observers can watch wapp pub/sub traffic.
class WappEventBridgeEvent extends AppEvent {
  /// engineId of the publishing wapp.
  final String fromEngineId;

  /// Topic the event was published on.
  final String topic;

  /// JSON / opaque payload as a string.
  final String data;

  WappEventBridgeEvent({
    required this.fromEngineId,
    required this.topic,
    required this.data,
  });
}

/// A user-visible error or warning. Notification backends (later pillar)
/// will subscribe to this to surface it.
class ErrorEvent extends AppEvent {
  final String source;
  final String message;
  final Object? error;
  ErrorEvent({required this.source, required this.message, this.error});
}

/// The active UI locale changed. Fired by the Settings language row
/// after writing to [PreferencesService.localePreference]. Every
/// open [WappPage] subscribes and reloads its translations so string
/// attributes swap without requiring a wapp reload.
class LocaleChangedEvent extends AppEvent {
  /// New effective locale tag (`pt_PT`, `en`, etc). Stringly-typed
  /// so consumers can compare or extract the language-only prefix
  /// without importing PreferencesService.
  final String locale;
  LocaleChangedEvent({required this.locale});
}
