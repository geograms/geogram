/// Routing strategies for selecting transports
library;

import '../services/log_service.dart';
import 'transport.dart';
import 'transport_message.dart';

/// Abstract routing strategy interface
///
/// Routing strategies determine which transports to try and in what order
/// for delivering a message to a specific device.
abstract class RoutingStrategy {
  /// Select transports to try for reaching a device
  ///
  /// Returns an ordered list of transports to attempt (first = preferred).
  /// The list may be empty if no transport can reach the device.
  Future<List<Transport>> selectTransports({
    required String callsign,
    required TransportMessageType messageType,
    required List<Transport> availableTransports,
  });
}

/// Priority-based routing strategy (default)
///
/// Selects transports based on their priority values.
/// Lower priority values are preferred.
///
/// Priority suggestions:
/// - LAN: 10 (fastest, most reliable on local network)
/// - BLE: 20 (works offline, short range)
/// - LoRa: 25 (long range, low bandwidth)
/// - Station: 30 (longest range, requires internet)
class PriorityRoutingStrategy implements RoutingStrategy {
  /// Whether to filter transports that cannot reach the device
  final bool filterUnreachable;

  /// Timeout for reachability checks
  final Duration reachabilityTimeout;

  /// TTL for cached reachability results
  final Duration cacheTtl;

  /// Static reachability cache: key = "{transportId}:{callsign}" → (reachable, timestamp)
  static final Map<String, _ReachCacheEntry> _reachCache = {};

  PriorityRoutingStrategy({
    this.filterUnreachable = true,
    this.reachabilityTimeout = const Duration(seconds: 2),
    this.cacheTtl = const Duration(seconds: 10),
  });

  @override
  Future<List<Transport>> selectTransports({
    required String callsign,
    required TransportMessageType messageType,
    required List<Transport> availableTransports,
  }) async {
    // Filter to available transports
    var transports = availableTransports
        .where((t) => t.isAvailable && t.isInitialized)
        .toList();

    if (transports.isEmpty) return [];

    // Optionally filter to reachable transports
    if (filterUnreachable) {
      final reachableTransports = <Transport>[];
      final now = DateTime.now();

      LogService().log('PriorityRoutingStrategy: Checking canReach($callsign) for ${transports.length} transports');

      // Check reachability in parallel with timeout, using cache
      final futures = transports.map((t) async {
        final cacheKey = '${t.id}:$callsign';
        final cached = _reachCache[cacheKey];
        if (cached != null && now.difference(cached.timestamp) < cacheTtl) {
          LogService().log('PriorityRoutingStrategy: ${t.id} canReach($callsign) = ${cached.reachable} (cached)');
          if (cached.reachable) return t;
          return null;
        }

        try {
          final canReach = await t.canReach(callsign).timeout(
            reachabilityTimeout,
            onTimeout: () {
              LogService().log('PriorityRoutingStrategy: ${t.id} canReach() TIMEOUT');
              return false;
            },
          );
          _reachCache[cacheKey] = _ReachCacheEntry(canReach, now);
          LogService().log('PriorityRoutingStrategy: ${t.id} canReach($callsign) = $canReach');
          if (canReach) return t;
        } catch (e) {
          _reachCache[cacheKey] = _ReachCacheEntry(false, now);
          LogService().log('PriorityRoutingStrategy: ${t.id} canReach() ERROR: $e');
        }
        return null;
      });

      final results = await Future.wait(futures);
      reachableTransports.addAll(results.whereType<Transport>());

      // If no transports can reach, fall back to all available
      // (let them try and fail with proper error messages)
      if (reachableTransports.isEmpty) {
        LogService().log('PriorityRoutingStrategy: No transports can reach $callsign, falling back to all available');
        transports = availableTransports
            .where((t) => t.isAvailable && t.isInitialized)
            .toList();
      } else {
        LogService().log('PriorityRoutingStrategy: ${reachableTransports.length} transports can reach $callsign: ${reachableTransports.map((t) => t.id).join(', ')}');
        transports = reachableTransports;
      }
    }

    // Sort by priority (lower = better)
    transports.sort((a, b) => a.priority.compareTo(b.priority));

    return transports;
  }

  /// Clear the reachability cache (useful for testing or forced refresh)
  static void clearCache() => _reachCache.clear();
}

/// Internal cache entry for reachability results
class _ReachCacheEntry {
  final bool reachable;
  final DateTime timestamp;
  _ReachCacheEntry(this.reachable, this.timestamp);
}

/// Quality-based routing strategy
///
/// Selects transports based on historical performance metrics.
/// Considers latency, success rate, and quality scores.
class QualityRoutingStrategy implements RoutingStrategy {
  /// Weight for latency in scoring (higher = more important)
  final double latencyWeight;

  /// Weight for success rate in scoring
  final double successRateWeight;

  /// Weight for quality score in scoring
  final double qualityWeight;

  const QualityRoutingStrategy({
    this.latencyWeight = 0.3,
    this.successRateWeight = 0.4,
    this.qualityWeight = 0.3,
  });

  @override
  Future<List<Transport>> selectTransports({
    required String callsign,
    required TransportMessageType messageType,
    required List<Transport> availableTransports,
  }) async {
    // Filter to available transports
    var transports = availableTransports
        .where((t) => t.isAvailable && t.isInitialized)
        .toList();

    if (transports.isEmpty) return [];

    // Calculate scores for each transport
    final scores = <Transport, double>{};

    for (final transport in transports) {
      double score = 0;

      // Latency score (lower is better, normalize to 0-100)
      final metrics = transport.metrics;
      final latencyScore = 100 - (metrics.averageLatencyMs / 10).clamp(0, 100);
      score += latencyScore * latencyWeight;

      // Success rate score (0-100)
      final successScore = metrics.successRate * 100;
      score += successScore * successRateWeight;

      // Quality score for specific device
      try {
        final quality = await transport.getQuality(callsign).timeout(
          const Duration(seconds: 1),
          onTimeout: () => 50, // Default medium quality
        );
        score += quality * qualityWeight;
      } catch (_) {
        score += 50 * qualityWeight; // Default medium quality
      }

      scores[transport] = score;
    }

    // Sort by score (higher = better)
    transports.sort((a, b) => (scores[b] ?? 0).compareTo(scores[a] ?? 0));

    return transports;
  }
}

/// Failover routing strategy
///
/// Uses a primary transport and falls back to secondary options.
/// Useful when you want to prefer a specific transport.
class FailoverRoutingStrategy implements RoutingStrategy {
  /// Ordered list of transport IDs to try
  final List<String> transportOrder;

  const FailoverRoutingStrategy({
    required this.transportOrder,
  });

  @override
  Future<List<Transport>> selectTransports({
    required String callsign,
    required TransportMessageType messageType,
    required List<Transport> availableTransports,
  }) async {
    final result = <Transport>[];

    // Add transports in specified order
    for (final transportId in transportOrder) {
      final transport = availableTransports.firstWhere(
        (t) => t.id == transportId && t.isAvailable && t.isInitialized,
        orElse: () => throw StateError('Transport not found'),
      );
      try {
        result.add(transport);
      } catch (_) {
        // Transport not found, skip
      }
    }

    // Add any remaining transports not in the order list
    for (final transport in availableTransports) {
      if (!result.contains(transport) &&
          transport.isAvailable &&
          transport.isInitialized) {
        result.add(transport);
      }
    }

    return result;
  }
}

/// Message-type aware routing strategy
///
/// Routes different message types to different transports.
/// For example, large file transfers might prefer LAN, while
/// real-time chat might prefer the fastest available.
class MessageTypeRoutingStrategy implements RoutingStrategy {
  /// Fallback strategy for unspecified message types
  final RoutingStrategy fallbackStrategy;

  /// Strategy overrides per message type
  final Map<TransportMessageType, RoutingStrategy> typeStrategies;

  const MessageTypeRoutingStrategy({
    required this.fallbackStrategy,
    this.typeStrategies = const {},
  });

  @override
  Future<List<Transport>> selectTransports({
    required String callsign,
    required TransportMessageType messageType,
    required List<Transport> availableTransports,
  }) {
    final strategy = typeStrategies[messageType] ?? fallbackStrategy;
    return strategy.selectTransports(
      callsign: callsign,
      messageType: messageType,
      availableTransports: availableTransports,
    );
  }
}
