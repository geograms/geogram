/// Web/iOS stub: no battery info.
library;

class BatteryStatus {
  final int? percent;
  final bool? plugged;
  const BatteryStatus({this.percent, this.plugged});
  bool get unknown => percent == null && plugged == null;
}

Future<BatteryStatus> probeBattery() async => const BatteryStatus();
