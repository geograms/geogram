/// Web stub: no transport-type detection.
library;

class TransportProbe {
  final bool? wifi;
  final bool? cellular;
  final bool? metered;
  const TransportProbe({this.wifi, this.cellular, this.metered});
  bool get unknown => wifi == null && cellular == null && metered == null;
}

Future<TransportProbe> probeTransport() async => const TransportProbe();
