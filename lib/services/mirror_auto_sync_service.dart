/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Mirror Auto-Sync Service
 *
 * Manages periodic automatic synchronization across all paired mirror peers.
 * Subscribes to MirrorConfigService config changes to start/stop/adjust the
 * timer based on enabled state, autoSync flag, and syncIntervalMinutes.
 */

import 'dart:async';

import 'package:http/http.dart' as http;

import '../models/mirror_config.dart';
import '../models/monitored_task.dart';
import '../util/task_monitor_helpers.dart';
import 'log_service.dart';
import 'mirror_config_service.dart';
import 'mirror_sync_service.dart';

/// Aggregate result from syncing all peers.
class MirrorSyncAllResult {
  final int filesAdded;
  final int filesModified;
  final int filesUploaded;
  final int errors;
  final int peersSkipped;
  final int peersSynced;
  final List<Map<String, dynamic>> details;

  const MirrorSyncAllResult({
    this.filesAdded = 0,
    this.filesModified = 0,
    this.filesUploaded = 0,
    this.errors = 0,
    this.peersSkipped = 0,
    this.peersSynced = 0,
    this.details = const [],
  });

  Map<String, dynamic> toJson() => {
        'files_added': filesAdded,
        'files_modified': filesModified,
        'files_uploaded': filesUploaded,
        'errors': errors,
        'peers_skipped': peersSkipped,
        'peers_synced': peersSynced,
        'details': details,
      };
}

/// Service that manages periodic mirror auto-sync.
class MirrorAutoSyncService {
  static final MirrorAutoSyncService _instance = MirrorAutoSyncService._();
  static MirrorAutoSyncService get instance => _instance;

  MirrorAutoSyncService._();

  MonitoredAsyncPeriodicTimer? _timer;
  StreamSubscription<MirrorConfig>? _configSubscription;
  bool _isSyncing = false;
  bool _active = false;
  int _intervalMinutes = 15;
  DateTime? _lastSyncAt;

  /// Whether the auto-sync timer is currently active.
  bool get isActive => _active;

  /// Current interval in minutes.
  int get intervalMinutes => _intervalMinutes;

  /// Timestamp of last auto-sync run.
  DateTime? get lastSyncAt => _lastSyncAt;

  /// Whether a sync is currently in progress.
  bool get isSyncing => _isSyncing;

  /// Start listening to config changes and evaluate the timer.
  void start() {
    _configSubscription?.cancel();
    _configSubscription =
        MirrorConfigService.instance.configStream.listen(_evaluateTimer);

    // Evaluate immediately with current config.
    final config = MirrorConfigService.instance.config;
    if (config != null) {
      _evaluateTimer(config);
    }
  }

  /// Stop the timer and config subscription.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _configSubscription?.cancel();
    _configSubscription = null;
    _active = false;
    LogService().log('MirrorAutoSync: stopped');
  }

  /// Evaluate whether the timer should be running based on config.
  void _evaluateTimer(MirrorConfig config) {
    final shouldRun =
        config.enabled && config.preferences.autoSync && config.peers.isNotEmpty;

    final interval = config.preferences.syncIntervalMinutes;

    if (!shouldRun) {
      if (_active) {
        _timer?.cancel();
        _timer = null;
        _active = false;
        LogService().log('MirrorAutoSync: timer stopped (disabled or no peers)');
      }
      return;
    }

    // If interval changed or timer not running, (re)start.
    if (!_active || interval != _intervalMinutes) {
      _timer?.cancel();
      _intervalMinutes = interval;
      _active = true;
      _timer = MonitoredAsyncPeriodicTimer(
        id: 'mirror_sync.auto',
        name: 'Mirror Sync',
        description: 'Automatic mirror peer synchronization',
        serviceName: 'MirrorAutoSyncService',
        interval: Duration(minutes: _intervalMinutes),
        priority: TaskPriority.low,
        callback: (_) async => await _onTick(),
      );
      LogService()
          .log('MirrorAutoSync: timer started (every ${_intervalMinutes}min)');
    }
  }

  /// Timer tick handler — runs sync if not already syncing.
  Future<void> _onTick() async {
    if (_isSyncing) {
      LogService().log('MirrorAutoSync: tick skipped — sync in progress');
      return;
    }
    LogService().log('MirrorAutoSync: tick — starting sync');
    final result = await syncAllPeers();
    LogService().log(
      'MirrorAutoSync: sync done — '
      '+${result.filesAdded} new, ~${result.filesModified} updated, '
      '↑${result.filesUploaded} uploaded, ${result.errors} error(s)',
    );
  }

  /// Resolve the best URL for a peer, trying direct first then station relay.
  ///
  /// Returns `(url, usedRelay)` or `null` if no address available.
  Future<(String, bool)?> _resolveUrl(MirrorPeer peer) async {
    final direct = peer.directAddress;
    if (direct != null && direct.isNotEmpty) {
      // Try a quick connectivity check (HEAD to /api/mirror/challenge).
      final directUrl = 'http://$direct';
      try {
        final resp = await http
            .head(Uri.parse('$directUrl/api/mirror/challenge?folder=ping'))
            .timeout(const Duration(seconds: 3));
        if (resp.statusCode < 500) {
          return (directUrl, false);
        }
      } catch (_) {
        // Direct unreachable — fall through to relay.
      }
    }

    // Try station relay.
    final relay = peer.stationRelayUrl;
    if (relay != null && relay.isNotEmpty) {
      return (relay, true);
    }

    // Fallback: use direct even without probing (legacy behavior).
    if (direct != null && direct.isNotEmpty) {
      return ('http://$direct', false);
    }

    return null;
  }

  /// Sync all peers and their enabled apps.
  ///
  /// If [tryRelay] is true (default), falls back to station relay when direct
  /// connection fails. Pass [onProgress] to receive per-file status updates.
  Future<MirrorSyncAllResult> syncAllPeers({
    void Function(SyncStatus)? onProgress,
    bool tryRelay = true,
  }) async {
    if (_isSyncing) {
      return const MirrorSyncAllResult();
    }
    _isSyncing = true;

    final configService = MirrorConfigService.instance;
    final syncService = MirrorSyncService.instance;
    final peers = configService.config?.peers ?? [];

    var totalAdded = 0;
    var totalModified = 0;
    var totalUploaded = 0;
    var errors = 0;
    var skipped = 0;
    var peersSynced = 0;
    final details = <Map<String, dynamic>>[];

    try {
      for (final peer in peers) {
        // Resolve URL with optional relay fallback.
        bool usedRelay = false;
        late final String peerUrl;

        if (tryRelay) {
          final resolved = await _resolveUrl(peer);
          if (resolved == null) {
            skipped++;
            continue;
          }
          peerUrl = resolved.$1;
          usedRelay = resolved.$2;
        } else {
          if (peer.addresses.isEmpty) {
            skipped++;
            continue;
          }
          peerUrl = 'http://${peer.addresses.first}';
        }

        final enabledApps = configService.getEnabledAppsForPeer(peer.peerId);
        var peerHadSync = false;

        for (final appId in enabledApps) {
          final appConfig = peer.apps[appId];
          if (appConfig == null) continue;
          final style = appConfig.style;
          if (style == SyncStyle.paused) continue;

          try {
            final result = await syncService.syncFolder(
              peerUrl,
              appId,
              peerCallsign: peer.callsign,
              syncStyle: style,
              ignorePatterns: appConfig.ignorePatterns,
              excludeRules: configService.config?.excludeRules ?? const [],
              onProgress: onProgress,
            );

            final detail = <String, dynamic>{
              'peer': peer.callsign,
              'app': appId,
              'added': result.filesAdded,
              'modified': result.filesModified,
              'uploaded': result.filesUploaded,
              if (usedRelay) 'relay': true,
            };

            if (result.success) {
              totalAdded += result.filesAdded;
              totalModified += result.filesModified;
              totalUploaded += result.filesUploaded;
              peerHadSync = true;
            } else {
              detail['error'] = result.error;
              errors++;
            }
            details.add(detail);
          } catch (e) {
            errors++;
            details.add({
              'peer': peer.callsign,
              'app': appId,
              'error': e.toString(),
            });
          }
        }

        if (peerHadSync) peersSynced++;
        await configService.markPeerSynced(peer.peerId);
      }

      _lastSyncAt = DateTime.now();
    } finally {
      _isSyncing = false;
    }

    return MirrorSyncAllResult(
      filesAdded: totalAdded,
      filesModified: totalModified,
      filesUploaded: totalUploaded,
      errors: errors,
      peersSkipped: skipped,
      peersSynced: peersSynced,
      details: details,
    );
  }

  /// Status info for debug API.
  Map<String, dynamic> toJson() => {
        'active': _active,
        'interval_minutes': _intervalMinutes,
        'is_syncing': _isSyncing,
        'last_sync_at': _lastSyncAt?.toIso8601String(),
      };
}
