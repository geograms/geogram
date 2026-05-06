/// Reachability state model per BT-DHT-v2 §7.2.
library;

enum ReachabilityStatus {
  /// All detection paths failed; we are relay-consumer-only.
  notReachable,

  /// Bound to a globally-routable IPv6 address (no NAT).
  reachableIPv6,

  /// UPnP-IGD AddPortMapping succeeded.
  reachableUPnP,

  /// NAT-PMP succeeded (deferred from Phase 1 per spec §7.3).
  reachableNATPMP,

  /// PCP succeeded (deferred from Phase 1 per spec §7.3).
  reachablePCP,
}

class ReachabilityState {
  final ReachabilityStatus status;
  final String? externalAddress;
  final int? externalPort;
  final DateTime detectedAt;

  /// Lease expiry (UPnP/NAT-PMP/PCP). null for IPv6 / notReachable.
  final DateTime? expiresAt;

  /// Free-form diagnostic; appears in debug API output.
  final String? note;

  const ReachabilityState({
    required this.status,
    this.externalAddress,
    this.externalPort,
    required this.detectedAt,
    this.expiresAt,
    this.note,
  });

  factory ReachabilityState.notReachable({String? note}) => ReachabilityState(
        status: ReachabilityStatus.notReachable,
        detectedAt: DateTime.now(),
        note: note,
      );

  bool get isReachable => status != ReachabilityStatus.notReachable;

  Map<String, dynamic> toJson() => {
        'status': status.name,
        if (externalAddress != null) 'externalAddress': externalAddress,
        if (externalPort != null) 'externalPort': externalPort,
        'detectedAt': detectedAt.toIso8601String(),
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
        if (note != null) 'note': note,
      };
}
