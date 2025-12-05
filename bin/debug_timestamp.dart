// Debug timestamp round-trip

void main() {
  // Simulate what desktop does when signing
  final now = DateTime.now();
  final unixTimestamp = now.millisecondsSinceEpoch ~/ 1000;
  print('Desktop local DateTime.now(): $now');
  print('Desktop Unix timestamp (signing): $unixTimestamp');

  // Simulate what server does when storing
  // Server receives created_at = unixTimestamp
  final serverDt = DateTime.fromMillisecondsSinceEpoch(unixTimestamp * 1000);
  print('Server DateTime.fromMilli(): $serverDt');
  print('Server DateTime is UTC: ${serverDt.isUtc}');

  // Server formats to string (uses local time components)
  final dateStr = '${serverDt.year.toString().padLeft(4, '0')}-'
      '${serverDt.month.toString().padLeft(2, '0')}-'
      '${serverDt.day.toString().padLeft(2, '0')}';
  final timeStr = '${serverDt.hour.toString().padLeft(2, '0')}:'
      '${serverDt.minute.toString().padLeft(2, '0')}_'
      '${serverDt.second.toString().padLeft(2, '0')}';
  print('Server stores: $dateStr $timeStr');

  // Simulate verification parsing (uses DateTime.utc)
  final parts = '$dateStr $timeStr'.split(' ');
  final dateParts = parts[0].split('-');
  final timeParts = parts[1].replaceAll('_', ':').split(':');
  final parsedDt = DateTime.utc(
    int.parse(dateParts[0]),
    int.parse(dateParts[1]),
    int.parse(dateParts[2]),
    int.parse(timeParts[0]),
    int.parse(timeParts[1]),
    int.parse(timeParts[2]),
  );
  final parsedUnix = parsedDt.millisecondsSinceEpoch ~/ 1000;
  print('Verification parses as UTC: $parsedDt');
  print('Verification Unix timestamp: $parsedUnix');

  print('');
  print('TIMESTAMPS MATCH: ${unixTimestamp == parsedUnix}');
  print('Difference: ${parsedUnix - unixTimestamp} seconds');

  // Also test with DateTime.utc for server side
  print('\n--- If server used DateTime.fromMilli...UTC ---');
  final serverDtUtc = DateTime.fromMillisecondsSinceEpoch(unixTimestamp * 1000, isUtc: true);
  print('Server DateTime (UTC): $serverDtUtc');

  final dateStrUtc = '${serverDtUtc.year.toString().padLeft(4, '0')}-'
      '${serverDtUtc.month.toString().padLeft(2, '0')}-'
      '${serverDtUtc.day.toString().padLeft(2, '0')}';
  final timeStrUtc = '${serverDtUtc.hour.toString().padLeft(2, '0')}:'
      '${serverDtUtc.minute.toString().padLeft(2, '0')}_'
      '${serverDtUtc.second.toString().padLeft(2, '0')}';
  print('Server stores (UTC): $dateStrUtc $timeStrUtc');

  final parts2 = '$dateStrUtc $timeStrUtc'.split(' ');
  final dateParts2 = parts2[0].split('-');
  final timeParts2 = parts2[1].replaceAll('_', ':').split(':');
  final parsedDt2 = DateTime.utc(
    int.parse(dateParts2[0]),
    int.parse(dateParts2[1]),
    int.parse(dateParts2[2]),
    int.parse(timeParts2[0]),
    int.parse(timeParts2[1]),
    int.parse(timeParts2[2]),
  );
  final parsedUnix2 = parsedDt2.millisecondsSinceEpoch ~/ 1000;
  print('Verification Unix (UTC flow): $parsedUnix2');
  print('TIMESTAMPS MATCH (UTC flow): ${unixTimestamp == parsedUnix2}');
}
