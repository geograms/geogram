/// Web stub: no native networking, never reports a globally-routable IPv6.
library;

class Ipv6ProbeResult {
  final String? globalAddress;
  final bool socketBindOk;
  const Ipv6ProbeResult({this.globalAddress, this.socketBindOk = false});
}

Future<Ipv6ProbeResult> probeIpv6(int desiredPort) async =>
    const Ipv6ProbeResult();
