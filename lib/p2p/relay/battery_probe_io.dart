/// Battery probe (Linux + Android via /sys/class/power_supply).
///
/// Reads `capacity` and `status` from the first BAT* node. On platforms
/// where the path doesn't exist (macOS, Windows, iOS), returns `unknown`
/// so the caller treats the host as ineligible for relay-tier promotion
/// rather than mis-promoting a battery-constrained device.
library;

import 'dart:io';

class BatteryStatus {
  final int? percent;
  final bool? plugged;
  const BatteryStatus({this.percent, this.plugged});
  bool get unknown => percent == null && plugged == null;
}

Future<BatteryStatus> probeBattery() async {
  if (!(Platform.isLinux || Platform.isAndroid)) {
    return const BatteryStatus();
  }
  try {
    final root = Directory('/sys/class/power_supply');
    if (!await root.exists()) return const BatteryStatus();
    int? percent;
    bool? plugged;
    await for (final ent in root.list()) {
      final name = ent.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.startsWith('BAT')) {
        final cap = File('${ent.path}/capacity');
        final st = File('${ent.path}/status');
        if (await cap.exists()) {
          percent = int.tryParse((await cap.readAsString()).trim());
        }
        if (await st.exists()) {
          final s = (await st.readAsString()).trim().toLowerCase();
          plugged = s == 'charging' || s == 'full';
        }
        if (percent != null) break;
      } else if ((name.startsWith('AC') || name == 'Mains') &&
          plugged == null) {
        final online = File('${ent.path}/online');
        if (await online.exists()) {
          plugged = (await online.readAsString()).trim() == '1';
        }
      }
    }
    return BatteryStatus(percent: percent, plugged: plugged);
  } catch (_) {
    return const BatteryStatus();
  }
}
