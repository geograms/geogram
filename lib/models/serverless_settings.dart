/// User-facing settings for the BT-DHT-v2 serverless P2P stack.
///
/// One file covers all four phases — fields belonging to phases that haven't
/// landed yet are inert (their consumer code doesn't exist). They live here
/// so we don't churn the schema across PRs.
library;

class ServerlessSettings {
  /// Master switch. When false, ReachabilityService and the relay-promotion
  /// controller stay idle; existing transports behave as before.
  bool enableServerless;

  /// DHT participation toggle (PR1+).
  bool dhtEnabled;

  /// Self-bootstrapping relay tier opt-in (PR4+, default off per spec §10.2).
  bool relayMode;

  /// Promotion criteria thresholds (PR4+).
  int batteryThresholdPct;
  int bandwidthCapMBPerDay;
  int maxRelaySessions;
  bool relayOnlyOnWifi;
  bool relayOnlyWhenUnmetered;

  /// Phase-3 fallback: manually-configured relay endpoint, e.g. "1.2.3.4:9876".
  String? manualRelayHostPort;

  /// DHT UDP port. null => randomize in 49152..65535 on first run, then
  /// persist across restarts so routing-table cache stays warm.
  int? chosenDhtPort;

  ServerlessSettings({
    this.enableServerless = true,
    this.dhtEnabled = true,
    this.relayMode = false,
    this.batteryThresholdPct = 50,
    this.bandwidthCapMBPerDay = 500,
    this.maxRelaySessions = 10,
    this.relayOnlyOnWifi = true,
    this.relayOnlyWhenUnmetered = true,
    this.manualRelayHostPort,
    this.chosenDhtPort,
  });

  Map<String, dynamic> toJson() => {
        'enableServerless': enableServerless,
        'dhtEnabled': dhtEnabled,
        'relayMode': relayMode,
        'batteryThresholdPct': batteryThresholdPct,
        'bandwidthCapMBPerDay': bandwidthCapMBPerDay,
        'maxRelaySessions': maxRelaySessions,
        'relayOnlyOnWifi': relayOnlyOnWifi,
        'relayOnlyWhenUnmetered': relayOnlyWhenUnmetered,
        if (manualRelayHostPort != null)
          'manualRelayHostPort': manualRelayHostPort,
        if (chosenDhtPort != null) 'chosenDhtPort': chosenDhtPort,
      };

  factory ServerlessSettings.fromJson(Map<String, dynamic> json) =>
      ServerlessSettings(
        enableServerless: json['enableServerless'] as bool? ?? true,
        dhtEnabled: json['dhtEnabled'] as bool? ?? true,
        relayMode: json['relayMode'] as bool? ?? false,
        batteryThresholdPct: json['batteryThresholdPct'] as int? ?? 50,
        bandwidthCapMBPerDay: json['bandwidthCapMBPerDay'] as int? ?? 500,
        maxRelaySessions: json['maxRelaySessions'] as int? ?? 10,
        relayOnlyOnWifi: json['relayOnlyOnWifi'] as bool? ?? true,
        relayOnlyWhenUnmetered: json['relayOnlyWhenUnmetered'] as bool? ?? true,
        manualRelayHostPort: json['manualRelayHostPort'] as String?,
        chosenDhtPort: json['chosenDhtPort'] as int?,
      );
}
