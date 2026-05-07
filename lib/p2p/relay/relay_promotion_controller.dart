/// BT-DHT-v2 §10.1 self-bootstrapping relay-tier promotion controller.
///
/// Evaluates the promotion criteria periodically and on relevant events
/// (reachability change, settings change). When all criteria pass, calls
/// the active station's `ServerlessRelayMixin.startServingRelay()` and
/// announces the listening port on `RELAY_TOPIC`. When any criterion
/// fails, demotes immediately.
///
/// Criteria (§10.1):
/// - reachability is one of REACHABLE_*
/// - user opted in (`settings.relayMode = true`)
/// - device is on Wi-Fi (gated by `settings.relayOnlyOnWifi`)
/// - non-metered connection (gated by `settings.relayOnlyWhenUnmetered`)
/// - plugged-in OR battery > `settings.batteryThresholdPct`
library;

import 'dart:async';

import '../../models/monitored_task.dart';
import '../../services/log_service.dart';
import '../../services/serverless_settings_service.dart';
import '../../util/task_monitor_helpers.dart';
import '../dht_topics.dart';
import '../p2p_service.dart';
import '../reachability/reachability_service.dart';
import '../reachability/reachability_state.dart';
import 'battery_probe_io.dart' if (dart.library.html) 'battery_probe_stub.dart';
import 'connectivity_probe_io.dart'
    if (dart.library.html) 'connectivity_probe_stub.dart';

/// Adapter the controller uses to start/stop the actual TCP listener.
/// Implemented by station classes via `ServerlessRelayMixin`. The
/// controller doesn't depend on the mixin directly so it stays usable
/// from contexts where neither station class is constructed (CLI tools,
/// tests).
abstract class RelayServer {
  Future<int> startServingRelay(int port);
  Future<void> stopServingRelay();
  bool get isServingRelay;
  int get servingPort;
}

class RelayPromotionController {
  RelayPromotionController._();
  static final RelayPromotionController _instance =
      RelayPromotionController._();
  factory RelayPromotionController() => _instance;

  final LogService _log = LogService();
  RelayServer? _server;
  StreamSubscription<ReachabilityState>? _reachSub;
  MonitoredAsyncPeriodicTimer? _evalTimer;
  MonitoredIsolateHandle? _taskHandle;

  bool _started = false;
  bool _promoted = false;
  String? _lastReason;

  bool get isStarted => _started;
  bool get isPromoted => _promoted;
  String? get lastReason => _lastReason;

  /// Bind to the active station's relay server. Pass null to clear (e.g.
  /// when a station is shutting down).
  void setServer(RelayServer? server) {
    _server = server;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _taskHandle = MonitoredIsolateHandle(
      id: 'serverless.relay_promotion',
      name: 'Serverless relay promotion',
      description:
          'Evaluates BT-DHT-v2 §10.1 criteria and promotes/demotes the relay tier',
      serviceName: 'RelayPromotionController',
    );
    _taskHandle!.markRunning();

    _reachSub = ReachabilityService().onChange.listen((_) => _evaluate());
    _evalTimer = MonitoredAsyncPeriodicTimer(
      id: 'serverless.relay_promotion.evaluate',
      name: 'Relay promotion eval',
      description:
          'Re-checks battery / connectivity / reachability for promotion',
      serviceName: 'RelayPromotionController',
      interval: const Duration(minutes: 1),
      priority: TaskPriority.low,
      callback: (_) => _evaluate(),
    );
    await _evaluate();
  }

  Future<void> stop() async {
    _started = false;
    await _reachSub?.cancel();
    _reachSub = null;
    _evalTimer?.cancel();
    _evalTimer = null;
    if (_promoted) {
      await _demote('controller stopped');
    }
    _taskHandle?.dispose();
    _taskHandle = null;
  }

  /// Manual override (debug API). Bypasses all criteria.
  Future<void> forcePromote() async {
    if (_server == null) {
      _log.warn('RelayPromotion: no server attached, cannot promote');
      return;
    }
    if (_promoted) return;
    await _promote(forced: true);
  }

  Future<void> forceDemote() => _demote('manual override');

  // ── internals ────────────────────────────────────────────────────

  Future<void> _evaluate() async {
    final settings = ServerlessSettingsService().current;
    final reach = ReachabilityService().currentState;
    final battery = await probeBattery();
    final transport = await probeTransport();

    String? reason;
    if (!settings.enableServerless) {
      reason = 'serverless disabled';
    } else if (!settings.relayMode) {
      reason = 'relay mode opted-out';
    } else if (!reach.isReachable) {
      reason = 'not reachable (${reach.status.name})';
    } else if (settings.relayOnlyOnWifi && transport.wifi != true) {
      reason = 'not on Wi-Fi';
    } else if (settings.relayOnlyWhenUnmetered && transport.metered == true) {
      reason = 'connection is metered';
    } else if (battery.percent != null &&
        !(battery.plugged == true) &&
        battery.percent! < settings.batteryThresholdPct) {
      reason = 'battery ${battery.percent}% < ${settings.batteryThresholdPct}%';
    }

    _lastReason = reason;

    if (reason == null) {
      if (!_promoted) await _promote();
    } else {
      if (_promoted) await _demote(reason);
    }
  }

  Future<void> _promote({bool forced = false}) async {
    final reach = ReachabilityService().currentState;
    final port = reach.externalPort ?? 0;
    if (_server == null) {
      _log.warn('RelayPromotion: no server attached');
      return;
    }
    try {
      final actual = await _server!.startServingRelay(port);
      // Announce on RELAY_TOPIC + legacy hash so DHT consumers can find
      // us. P2PService's reannounce loop will keep us alive afterwards
      // because the announce uses persist=true by default.
      final topicHex = _hex(DhtTopics.relayTopic());
      final ok = await P2PService().announceRelayTierPort(actual);
      if (ok) {
        _log.info(
            'RelayPromotion: announced RELAY_TOPIC=$topicHex on port $actual'
            ' ${forced ? "(forced)" : ""}');
      } else {
        _log.warn(
            'RelayPromotion: announce failed (DHT not running?); peers'
            " won't auto-discover us until reannounce");
      }
      _promoted = true;
      _log.info(
          'Relay promoted: serving on tcp/$actual ${forced ? "(forced)" : ""}');
    } catch (e) {
      _log.warn('RelayPromotion: promote failed: $e');
      _taskHandle?.markError(e);
    }
  }

  Future<void> _demote(String reason) async {
    if (_server == null) return;
    try {
      await _server!.stopServingRelay();
    } catch (_) {}
    _promoted = false;
    _log.info('Relay demoted: $reason');
  }

  static String _hex(List<int> bytes) {
    const chars = '0123456789abcdef';
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(chars[(b >> 4) & 0xf]);
      sb.write(chars[b & 0xf]);
    }
    return sb.toString();
  }
}
