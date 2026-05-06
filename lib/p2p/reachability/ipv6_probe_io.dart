/// IPv6 reachability probe (native).
///
/// Per BT-DHT-v2 §7.4: enumerate NetworkInterface.list(), keep only IPv6
/// addresses that aren't loopback/link-local/ULA, and attempt a UDP bind on
/// the desired port. If both steps succeed, we treat the host as
/// globally reachable over IPv6.
library;

import 'dart:io';

class Ipv6ProbeResult {
  final String? globalAddress;
  final bool socketBindOk;
  const Ipv6ProbeResult({this.globalAddress, this.socketBindOk = false});
}

Future<Ipv6ProbeResult> probeIpv6(int desiredPort) async {
  final List<NetworkInterface> ifaces;
  try {
    ifaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv6,
    );
  } catch (_) {
    return const Ipv6ProbeResult();
  }

  for (final iface in ifaces) {
    for (final addr in iface.addresses) {
      if (addr.type != InternetAddressType.IPv6) continue;
      if (!_isGloballyRoutableV6(addr.address)) continue;

      RawDatagramSocket? sock;
      try {
        sock = await RawDatagramSocket.bind(addr, desiredPort);
        return Ipv6ProbeResult(
          globalAddress: addr.address,
          socketBindOk: true,
        );
      } catch (_) {
        // Try next address.
      } finally {
        sock?.close();
      }
    }
  }
  return const Ipv6ProbeResult();
}

/// Returns false for `::1`, `fe80::/10`, `fc00::/7`, and unspecified `::`.
bool _isGloballyRoutableV6(String addr) {
  final lower = addr.toLowerCase();
  if (lower == '::1' || lower == '::') return false;
  if (lower.startsWith('fe8') ||
      lower.startsWith('fe9') ||
      lower.startsWith('fea') ||
      lower.startsWith('feb')) {
    // fe80::/10 — link-local
    return false;
  }
  // fc00::/7 — Unique Local Addresses
  if (lower.startsWith('fc') || lower.startsWith('fd')) return false;
  return true;
}
