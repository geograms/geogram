/*
 * NotificationService — unified notification surface for geogram.
 *
 * Every user-visible notification in geogram (from host services or
 * from wapps) must go through this service. No wapp or service should
 * call ScaffoldMessenger or notify-send directly; routing through here
 * lets us add per-wapp mute settings, notification history, do-not-
 * disturb windows, and multi-backend delivery (in-app + system tray +
 * future: mesh relay) without touching every call site.
 *
 * Wire protocol for wapps (via hal_msg_send):
 *
 *   {"type":"notify",
 *    "level":"info|success|warning|error",
 *    "title":"...",
 *    "body":"...",
 *    "tag":"optional dedupe key",
 *    "scope":"app|system|both"}
 *
 * The host routes the message through this service from wapp_page's
 * _drainOutbox handler.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/platform.dart' as platform;
import 'event_bus.dart';

enum NotificationLevel { info, success, warning, error }

/// Where a notification should be delivered.
enum NotificationScope {
  /// In-app only (snackbar / banner). Default.
  app,

  /// System tray / OS notification only.
  system,

  /// Both in-app and system tray.
  both,
}

/// Value object describing one notification.
class GeogramNotification {
  final NotificationLevel level;
  final String title;
  final String? body;

  /// Opaque identifier for where this notification came from. Used by
  /// the history / debug UI. Convention: `"wapp:<wappName>"` for
  /// wapp-sourced notifications, `"host:<service>"` for host-sourced.
  final String source;

  /// Optional deduplication key. Reserved for a future debounce layer.
  final String? tag;

  final NotificationScope scope;
  final DateTime timestamp;

  GeogramNotification({
    required this.level,
    required this.title,
    this.body,
    required this.source,
    this.tag,
    this.scope = NotificationScope.app,
  }) : timestamp = DateTime.now();
}

/// A delivery backend. Implementations must be side-effect-only —
/// throwing or hanging is silently swallowed by the service so a
/// broken backend cannot starve the others.
abstract class NotificationBackend {
  String get name;

  /// Whether this backend handles [scope]. Returning false causes the
  /// service to skip this backend for that delivery.
  bool handlesScope(NotificationScope scope);

  Future<void> show(GeogramNotification n);
}

// ── In-app display ──────────────────────────────────────────────────
//
// There is deliberately no InAppNotificationBackend. In-app display is
// handled by [NotificationLayer] (see below) — it subscribes directly
// to [NotificationShownEvent] on the [EventBus] and maintains a stack
// of visible cards. Using an overlay instead of ScaffoldMessenger
// lets multiple notifications be visible simultaneously (Android-style
// stacking), which SnackBar cannot do — it queues and shows one at a
// time, replacing the current one when a new one arrives.

// ── System tray backend (Linux / macOS) ─────────────────────────────

class SystemTrayNotificationBackend implements NotificationBackend {
  @override
  String get name => 'system-tray';

  @override
  bool handlesScope(NotificationScope scope) =>
      scope == NotificationScope.system || scope == NotificationScope.both;

  @override
  Future<void> show(GeogramNotification n) async {
    // Native OS routing (notify-send / osascript) lives in the
    // platform abstraction so this file stays dart:io-free and the
    // web build can compile it. On web the call is a no-op; the
    // in-app NotificationLayer is the only source of truth.
    await platform.showSystemNotification(
      title: n.title,
      body: n.body,
      error: n.level == NotificationLevel.error,
    );
  }
}

// ── Service ─────────────────────────────────────────────────────────

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final List<NotificationBackend> _backends = [];

  /// Rolling in-memory history. Capped at [maxHistory]. Reserved for a
  /// future history / debug UI.
  final List<GeogramNotification> history = [];
  static const int maxHistory = 200;

  EventSubscription<ErrorEvent>? _errorSub;
  bool _initialised = false;

  /// One-shot initialiser. On desktop platforms registers the system
  /// tray backend. Subscribes to [ErrorEvent] so internal errors
  /// auto-surface as error-level notifications. In-app display is
  /// handled separately by [NotificationLayer] subscribing to
  /// [NotificationShownEvent] — nothing to do here for that channel.
  ///
  /// Must be called exactly once — second calls are no-ops.
  void init() {
    if (_initialised) return;
    _initialised = true;

    // The system-tray backend defers its actual per-OS routing to
    // the platform abstraction, so we always register it — on web
    // its show() becomes a no-op anyway.
    _backends.add(SystemTrayNotificationBackend());

    _errorSub = EventBus().on<ErrorEvent>((e) {
      show(GeogramNotification(
        level: NotificationLevel.error,
        title: 'Error',
        body: e.message,
        source: e.source,
        scope: NotificationScope.app,
      ));
    });
  }

  /// Dispatch [n] to every backend that declares it handles the
  /// notification's scope. Backend errors are swallowed so one broken
  /// backend cannot prevent the others from firing.
  void show(GeogramNotification n) {
    history.add(n);
    if (history.length > maxHistory) {
      history.removeAt(0);
    }
    EventBus().fire(NotificationShownEvent(n));
    for (final backend in _backends) {
      if (!backend.handlesScope(n.scope)) continue;
      unawaited(backend.show(n).catchError((_) {}));
    }
  }

  /// Test helper — resets internal state so tests don't leak across
  /// cases. Not used at runtime.
  @visibleForTesting
  void reset() {
    _errorSub?.cancel();
    _errorSub = null;
    _backends.clear();
    history.clear();
    _initialised = false;
  }
}

/// Fired on [EventBus] after a notification is handed to backends.
/// History / debug UIs and [NotificationLayer] subscribe to this for
/// live updates.
class NotificationShownEvent extends AppEvent {
  final GeogramNotification notification;
  NotificationShownEvent(this.notification);
}

// ── NotificationLayer — stacking in-app overlay ──────────────────────
//
// Wrap the app's home with this widget to get Android-style stacking
// notifications. Each [NotificationShownEvent] with scope other than
// system-only pushes a new card onto the visible stack at the top-
// right. Cards auto-dismiss after 3 seconds (info/success) or 6
// seconds (warning/error). Maximum of [maxVisible] cards at once;
// older ones are evicted when the stack overflows. Each card has a
// manual close button.

class NotificationLayer extends StatefulWidget {
  final Widget child;
  const NotificationLayer({super.key, required this.child});

  @override
  State<NotificationLayer> createState() => _NotificationLayerState();
}

class _NotificationLayerState extends State<NotificationLayer> {
  static const int maxVisible = 5;

  final List<_VisibleNotification> _visible = [];
  EventSubscription<NotificationShownEvent>? _sub;
  int _nextKey = 0;

  @override
  void initState() {
    super.initState();
    _sub = EventBus().on<NotificationShownEvent>(_onShown);
  }

  void _onShown(NotificationShownEvent e) {
    final n = e.notification;
    // Skip system-only scope — that's for the OS tray, not in-app.
    if (n.scope == NotificationScope.system) return;
    if (!mounted) return;

    final entry = _VisibleNotification(n, _nextKey++);
    setState(() {
      _visible.add(entry);
      while (_visible.length > maxVisible) {
        _visible.removeAt(0);
      }
    });

    final durationMs =
        n.level == NotificationLevel.error ? 6000 : 3000;
    Future.delayed(Duration(milliseconds: durationMs), () {
      if (!mounted) return;
      setState(() => _visible.removeWhere((v) => v.key == entry.key));
    });
  }

  void _dismiss(int key) {
    setState(() => _visible.removeWhere((v) => v.key == key));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_visible.isNotEmpty)
          Positioned(
            top: 16,
            right: 16,
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // stretch so each card gets the full 340px width from
              // the Positioned. With `end` the cards receive unbounded
              // width constraints and the Row/Expanded chain inside
              // each card cannot resolve, causing a 99k-pixel overflow.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final v in _visible)
                  Padding(
                    key: ValueKey(v.key),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _NotificationCard(
                      notification: v.notification,
                      onDismiss: () => _dismiss(v.key),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _VisibleNotification {
  final GeogramNotification notification;
  final int key;
  _VisibleNotification(this.notification, this.key);
}

class _NotificationCard extends StatelessWidget {
  final GeogramNotification notification;
  final VoidCallback onDismiss;
  const _NotificationCard({
    required this.notification,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final color = switch (n.level) {
      NotificationLevel.info => Colors.blueGrey.shade800,
      NotificationLevel.success => Colors.green.shade800,
      NotificationLevel.warning => Colors.orange.shade900,
      NotificationLevel.error => Colors.red.shade900,
    };
    final icon = switch (n.level) {
      NotificationLevel.info => Icons.info_outline,
      NotificationLevel.success => Icons.check_circle_outline,
      NotificationLevel.warning => Icons.warning_amber_outlined,
      NotificationLevel.error => Icons.error_outline,
    };
    return Material(
      color: color,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    n.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  if (n.body != null && n.body!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      n.body!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // No IconButton here — IconButton's built-in Tooltip
            // requires an Overlay ancestor, which NotificationLayer
            // does not have when installed via MaterialApp.builder
            // (it sits above the Navigator's Overlay). Using a plain
            // InkWell keeps the tap target without the tooltip.
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onDismiss,
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.close, size: 16, color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
