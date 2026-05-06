/// Heuristic Wi-Fi / cellular detection via interface naming.
///
/// We don't add `connectivity_plus` in PR4 (per plan: avoid the dep until a
/// platform-niceties PR). Linux and Android present interface names that
/// allow a confident guess: `wlan*` / `wlp*` / `wifi*` are Wi-Fi;
/// `rmnet*` / `wwan*` / `pdp_ip*` / `usb0` (when tethering) are cellular.
/// Anything else returns null and the caller treats it as unknown
/// (ineligible for relay-tier promotion).
library;

import 'dart:io';

class TransportProbe {
  final bool? wifi;
  final bool? cellular;
  final bool? metered;
  const TransportProbe({this.wifi, this.cellular, this.metered});
  bool get unknown => wifi == null && cellular == null && metered == null;
}

Future<TransportProbe> probeTransport() async {
  if (!(Platform.isLinux || Platform.isAndroid)) {
    return const TransportProbe();
  }
  try {
    final ifaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
    );
    var wifi = false;
    var cellular = false;
    for (final i in ifaces) {
      final n = i.name.toLowerCase();
      if (n.startsWith('wlan') ||
          n.startsWith('wlp') ||
          n.startsWith('wifi')) {
        wifi = true;
      } else if (n.startsWith('rmnet') ||
          n.startsWith('wwan') ||
          n.startsWith('pdp_ip') ||
          n == 'ccmni0' ||
          n == 'usb0') {
        cellular = true;
      }
    }
    final metered = cellular && !wifi ? true : (wifi ? false : null);
    return TransportProbe(
      wifi: wifi ? true : null,
      cellular: cellular ? true : null,
      metered: metered,
    );
  } catch (_) {
    return const TransportProbe();
  }
}
