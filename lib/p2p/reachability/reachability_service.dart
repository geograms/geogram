/// Reachability detection orchestrator (BT-DHT-v2 §7).
///
/// Walks the IPv6 → UPnP-IGD chain, exposes the current state, schedules
/// UPnP lease renewal at 50% TTL, and recomputes on coarse network change.
/// NAT-PMP and PCP are deferred (spec §7.3 explicitly allows shipping
/// Phase 1 with `upnp2`/UPnP only). All timers register with TaskMonitor
/// per project rule "no untracked timers".
library;

import 'dart:async';
import 'dart:math';

import '../../models/monitored_task.dart';
import '../../services/log_service.dart';
import '../../util/task_monitor_helpers.dart';
import 'ipv6_probe_io.dart' if (dart.library.html) 'ipv6_probe_stub.dart';
import 'reachability_state.dart';
import 'upnp_igd_io.dart' if (dart.library.html) 'upnp_igd_stub.dart';

class ReachabilityService {
  ReachabilityService._();
  static final ReachabilityService _instance = ReachabilityService._();
  factory ReachabilityService() => _instance;

  final LogService _log = LogService();
  final _changes = StreamController<ReachabilityState>.broadcast();

  ReachabilityState _state = ReachabilityState.notReachable(note: 'idle');
  bool _running = false;
  int? _chosenPort;

  MonitoredPeriodicTimer? _renewTimer;
  MonitoredPeriodicTimer? _recheckTimer;

  ReachabilityState get currentState => _state;
  Stream<ReachabilityState> get onChange => _changes.stream;
  int? get chosenPort => _chosenPort;

  /// [chosenPort] is the externally-announced port (UDP). Pass null to let
  /// the service pick a randomized high port (49152..65535) per spec §6.3.
  Future<void> start({int? chosenPort}) async {
    if (_running) return;
    _running = true;
    _chosenPort = chosenPort ?? _randomHighPort();
    _log.info(
        'Reachability: starting detection on port $_chosenPort');
    await _detect();

    _recheckTimer = MonitoredPeriodicTimer(
      id: 'reachability.recheck',
      name: 'Reachability re-detect',
      description: 'Periodic IPv6/UPnP redetection',
      serviceName: 'ReachabilityService',
      interval: const Duration(minutes: 15),
      priority: TaskPriority.low,
      callback: (_) => _detect(),
    );
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _renewTimer?.cancel();
    _renewTimer = null;
    _recheckTimer?.cancel();
    _recheckTimer = null;
    if (_state.status == ReachabilityStatus.reachableUPnP &&
        _chosenPort != null) {
      try {
        await upnpDeletePortMapping(externalPort: _chosenPort!);
      } catch (_) {}
    }
    _state = ReachabilityState.notReachable(note: 'stopped');
    _emit();
  }

  /// Force-rerun the detection chain.
  Future<ReachabilityState> refresh() async {
    await _detect();
    return _state;
  }

  Future<void> _detect() async {
    final port = _chosenPort ?? _randomHighPort();
    _chosenPort = port;

    // 1. IPv6
    try {
      final v6 = await probeIpv6(port);
      if (v6.socketBindOk && v6.globalAddress != null) {
        _setState(ReachabilityState(
          status: ReachabilityStatus.reachableIPv6,
          externalAddress: v6.globalAddress,
          externalPort: port,
          detectedAt: DateTime.now(),
          note: 'IPv6 global unicast',
        ));
        _renewTimer?.cancel();
        _renewTimer = null;
        return;
      }
    } catch (e) {
      _log.warn('Reachability: IPv6 probe error: $e');
    }

    // 2. UPnP-IGD
    try {
      const lease = Duration(hours: 1);
      final m = await upnpAddPortMapping(
        externalPort: port,
        internalPort: port,
        description: 'geogram',
        leaseDuration: lease,
      );
      if (m.ok) {
        _setState(ReachabilityState(
          status: ReachabilityStatus.reachableUPnP,
          externalAddress: m.externalAddress,
          externalPort: m.externalPort ?? port,
          detectedAt: DateTime.now(),
          expiresAt: DateTime.now().add(lease),
          note: 'UPnP-IGD AddPortMapping',
        ));
        _scheduleRenewal(lease);
        return;
      } else {
        _log.info('Reachability: UPnP failed: ${m.error}');
      }
    } catch (e) {
      _log.warn('Reachability: UPnP probe error: $e');
    }

    // 3. NAT-PMP / PCP — deferred (spec §7.3).
    _setState(ReachabilityState.notReachable(
        note: 'IPv6+UPnP failed; NAT-PMP/PCP deferred'));
    _renewTimer?.cancel();
    _renewTimer = null;
  }

  void _scheduleRenewal(Duration lease) {
    _renewTimer?.cancel();
    // Renew at 50% expiry per §7.2.
    final renewIn = Duration(seconds: max(60, lease.inSeconds ~/ 2));
    _renewTimer = MonitoredPeriodicTimer(
      id: 'reachability.lease_renew',
      name: 'UPnP lease renew',
      description: 'Renews UPnP-IGD port mapping at 50% TTL',
      serviceName: 'ReachabilityService',
      interval: renewIn,
      priority: TaskPriority.low,
      callback: (_) => _detect(),
    );
  }

  void _setState(ReachabilityState s) {
    final changed = s.status != _state.status ||
        s.externalAddress != _state.externalAddress ||
        s.externalPort != _state.externalPort;
    _state = s;
    if (changed) {
      _log.info(
          'Reachability: state ${s.status.name} at ${s.externalAddress ?? "?"}:${s.externalPort ?? "?"}');
      _emit();
    }
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(_state);
  }

  static int _randomHighPort() {
    // 49152..65535 inclusive (spec §6.3).
    return 49152 + Random.secure().nextInt(65536 - 49152);
  }
}
