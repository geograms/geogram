/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Network Monitor Service - Monitors LAN connectivity
 * Fires ConnectionStateChangedEvent when network states change
 *
 * Note: This service only monitors LAN (local network interface) availability.
 * Internet connectivity checks were removed to avoid privacy-concerning pings
 * to external servers. Services that need connectivity should check their
 * specific endpoints instead (e.g., MapTileService checks tile servers).
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'log_service.dart';
import 'power_aware_service.dart';
import '../models/monitored_task.dart';
import '../util/event_bus.dart';
import '../util/task_monitor_helpers.dart';

/// Service that monitors network connectivity and fires events on changes
class NetworkMonitorService {
  static final NetworkMonitorService _instance = NetworkMonitorService._internal();
  factory NetworkMonitorService() => _instance;
  NetworkMonitorService._internal();

  final EventBus _eventBus = EventBus();

  /// Check interval for network state
  static const Duration _checkInterval = Duration(seconds: 10);

  /// Timer for periodic checks
  MonitoredAsyncPeriodicTimer? _checkTimer;

  /// Power-aware subscription
  StreamSubscription<PowerMode>? _powerSubscription;

  /// Last known states (to avoid duplicate events)
  bool _lastLanAvailable = false;

  /// Whether the service has been initialized
  bool _initialized = false;

  /// Current network state getter
  bool get hasLan => _lastLanAvailable;

  /// Initialize the service and start monitoring
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    if (kIsWeb) {
      // On web, LAN is not detectable
      _lastLanAvailable = false;
      return;
    }

    LogService().log('NetworkMonitor: Initializing LAN monitoring');

    // Check initial state
    await _checkNetworkState();

    // Start periodic checks
    _checkTimer = MonitoredAsyncPeriodicTimer(
      id: 'network_monitor.lan_check',
      name: 'LAN State Check',
      description: 'Checks LAN/network connectivity',
      serviceName: 'NetworkMonitorService',
      interval: _checkInterval,
      priority: TaskPriority.normal,
      callback: (_) async => await _checkNetworkState(),
    );

    // Listen for power mode changes (mobile battery saving)
    _powerSubscription = PowerAwareService().onModeChanged.listen(_onPowerModeChanged);
  }

  /// Stop monitoring and clean up
  void dispose() {
    _checkTimer?.cancel();
    _checkTimer = null;
    _powerSubscription?.cancel();
    _powerSubscription = null;
    _initialized = false;
  }

  /// Adjust polling interval based on power mode.
  void _onPowerModeChanged(PowerMode mode) {
    _checkTimer?.cancel();
    _checkTimer = null;

    switch (mode) {
      case PowerMode.foreground:
        _checkTimer = MonitoredAsyncPeriodicTimer(
          id: 'network_monitor.lan_check',
          name: 'LAN State Check',
          description: 'Checks LAN/network connectivity',
          serviceName: 'NetworkMonitorService',
          interval: _checkInterval,
          priority: TaskPriority.normal,
          callback: (_) async => await _checkNetworkState(),
        );
        LogService().log('NetworkMonitor: foreground — polling every 10s');
        break;
      case PowerMode.background:
        _checkTimer = MonitoredAsyncPeriodicTimer(
          id: 'network_monitor.lan_check',
          name: 'LAN State Check',
          description: 'Checks LAN/network connectivity (background)',
          serviceName: 'NetworkMonitorService',
          interval: const Duration(seconds: 60),
          priority: TaskPriority.normal,
          callback: (_) async => await _checkNetworkState(),
        );
        LogService().log('NetworkMonitor: background — polling every 60s');
        break;
      case PowerMode.doze:
        // Stop polling entirely in doze
        LogService().log('NetworkMonitor: doze — polling paused');
        break;
    }
  }

  /// Force a network state check (can be called after network changes)
  Future<void> checkNow() async {
    await _checkNetworkState();
  }

  /// Check current network state and fire events if changed
  Future<void> _checkNetworkState() async {
    if (kIsWeb) return;

    try {
      // Check LAN availability (do we have a local network interface?)
      final hasLan = await _checkLanAvailable();
      if (hasLan != _lastLanAvailable) {
        _fireLanStateChanged(hasLan);
      }
    } catch (e) {
      LogService().log('NetworkMonitor: Error checking network state: $e');
    }
  }

  /// Check if we have a local network interface with a private IP
  Future<bool> _checkLanAvailable() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          // Check for private network addresses
          if (_isPrivateIp(ip)) {
            return true;
          }
        }
      }
      return false;
    } catch (e) {
      LogService().log('NetworkMonitor: Error checking LAN: $e');
      return false;
    }
  }

  /// Check if IP is a private network address
  bool _isPrivateIp(String ip) {
    // 10.0.0.0 - 10.255.255.255
    if (ip.startsWith('10.')) return true;
    // 172.16.0.0 - 172.31.255.255
    if (ip.startsWith('172.')) {
      final parts = ip.split('.');
      if (parts.length >= 2) {
        final second = int.tryParse(parts[1]) ?? 0;
        if (second >= 16 && second <= 31) return true;
      }
    }
    // 192.168.0.0 - 192.168.255.255
    if (ip.startsWith('192.168.')) return true;
    return false;
  }

  /// Fire LAN state changed event
  void _fireLanStateChanged(bool isAvailable) {
    _lastLanAvailable = isAvailable;
    LogService().log('ConnectionStateChanged: lan ${isAvailable ? "available" : "unavailable"}');

    _eventBus.fire(ConnectionStateChangedEvent(
      connectionType: ConnectionType.lan,
      isConnected: isAvailable,
    ));
  }
}
