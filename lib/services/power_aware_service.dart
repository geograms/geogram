/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Power-Aware Service - Coordinates battery-saving behavior on mobile.
 *
 * Three power modes:
 *   - foreground: full operation (default, permanent on desktop)
 *   - background: app paused, reduce timer intervals
 *   - doze: app backgrounded >2 minutes, suspend non-essential services
 *
 * Services listen to [onModeChanged] and adjust their behavior accordingly.
 * Use [addExemption] to keep services alive during specific operations
 * (e.g., path recording keeps GPS at full fidelity).
 */

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart' show AppLifecycleState;

import 'log_service.dart';
import 'task_monitor_service.dart';

/// Power mode levels, ordered from most active to most conserved.
enum PowerMode { foreground, background, doze }

/// Singleton coordinator for mobile power management.
///
/// On desktop/web this service stays permanently in [PowerMode.foreground]
/// and never fires mode changes. On mobile it maps [AppLifecycleState] to
/// power modes and notifies listeners.
class PowerAwareService {
  PowerAwareService._();
  static final PowerAwareService _instance = PowerAwareService._();
  factory PowerAwareService() => _instance;

  PowerMode _mode = PowerMode.foreground;
  PowerMode get mode => _mode;

  Timer? _dozeTimer;
  static const _dozeDelay = Duration(minutes: 2);

  /// Exemptions prevent doze from suspending specific services.
  final Set<String> _exemptions = {};

  final StreamController<PowerMode> _controller =
      StreamController<PowerMode>.broadcast();

  /// Broadcast stream of power mode transitions.
  Stream<PowerMode> get onModeChanged => _controller.stream;

  /// Whether this platform uses power management at all.
  bool get _isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  // ------------------------------------------------------------------
  // Exemption management
  // ------------------------------------------------------------------

  /// Add an exemption to prevent doze from pausing a feature.
  void addExemption(String id) {
    _exemptions.add(id);
    LogService().log('PowerAware: exemption added: $id');
  }

  /// Remove an exemption. If no exemptions remain and we're in doze,
  /// the pending doze transition will proceed normally next time.
  void removeExemption(String id) {
    _exemptions.remove(id);
    LogService().log('PowerAware: exemption removed: $id');
  }

  bool get hasExemptions => _exemptions.isNotEmpty;

  Set<String> get exemptions => Set.unmodifiable(_exemptions);

  // ------------------------------------------------------------------
  // Lifecycle integration (called from main.dart)
  // ------------------------------------------------------------------

  /// Map an [AppLifecycleState] to a power mode transition.
  ///
  /// Only has an effect on Android/iOS. Desktop stays in foreground.
  void onLifecycleChanged(AppLifecycleState state) {
    if (!_isMobile) return;

    switch (state) {
      case AppLifecycleState.resumed:
        _transitionTo(PowerMode.foreground);
        break;
      case AppLifecycleState.inactive:
        // Short transition (e.g., incoming call) — no action
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _transitionTo(PowerMode.background);
        break;
    }
  }

  /// Force a specific mode (for debug API testing on desktop).
  void forceMode(PowerMode newMode) {
    _transitionTo(newMode, force: true);
  }

  // ------------------------------------------------------------------
  // Internal
  // ------------------------------------------------------------------

  Timer? _debounceTimer;

  void _transitionTo(PowerMode newMode, {bool force = false}) {
    // Cancel pending doze timer on any transition
    _dozeTimer?.cancel();
    _dozeTimer = null;

    if (newMode == _mode && !force) return;

    // Debounce rapid transitions (e.g., background→foreground within ms)
    // to prevent thundering herd of timer re-registrations
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _executeTransition(newMode, force: force);
    });
  }

  void _executeTransition(PowerMode newMode, {bool force = false}) {
    if (newMode == _mode && !force) return;

    final oldMode = _mode;

    if (newMode == PowerMode.foreground) {
      _mode = PowerMode.foreground;
      _onForeground();
      LogService().log('PowerAware: $oldMode -> foreground');
      _controller.add(_mode);
    } else if (newMode == PowerMode.background) {
      _mode = PowerMode.background;
      LogService().log('PowerAware: $oldMode -> background');
      _controller.add(_mode);

      // Schedule doze transition after delay
      _dozeTimer = Timer(_dozeDelay, () {
        _transitionTo(PowerMode.doze);
      });
    } else if (newMode == PowerMode.doze) {
      _mode = PowerMode.doze;
      _onDoze();
      LogService().log('PowerAware: $oldMode -> doze');
      _controller.add(_mode);
    }
  }

  void _onForeground() {
    // Resume all monitored tasks that were paused by doze
    final count = TaskMonitorService().resumeAll();
    if (count > 0) {
      LogService().log('PowerAware: resumed $count monitored tasks');
    }
  }

  void _onDoze() {
    // Pause all non-critical monitored tasks (free win for MonitoredPeriodicTimer users)
    final count = TaskMonitorService().pauseAllNonCritical();
    if (count > 0) {
      LogService().log('PowerAware: paused $count non-critical monitored tasks');
    }
  }

  // ------------------------------------------------------------------
  // Debug / status
  // ------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'mode': _mode.name,
        'isMobile': _isMobile,
        'exemptions': _exemptions.toList(),
        'dozeTimerActive': _dozeTimer?.isActive ?? false,
      };

  void dispose() {
    _dozeTimer?.cancel();
    _dozeTimer = null;
    _controller.close();
  }
}
