import 'package:flutter_test/flutter_test.dart';
import 'package:geogram/teleport/aprs/aprs_service.dart';
import 'package:geogram/teleport/aprs/models/aprs_packet.dart';

void main() {
  final aprs = AprsService();

  AprsPacket buildGeoChatPacket({
    required String from,
    required String comment,
    required DateTime timestamp,
    double lat = 38.72,
    double lon = -9.14,
  }) {
    return AprsPacket(
      fromCallsign: from,
      toCallsign: 'APRS',
      infoField:
          '!${lat.toStringAsFixed(5)}/${lon.toStringAsFixed(5)}\$$comment',
      rawTnc2:
          '$from>APRS:!${lat.toStringAsFixed(5)}/${lon.toStringAsFixed(5)}\$$comment',
      timestamp: timestamp.toUtc(),
      type: AprsPacketType.position,
      latitude: lat,
      longitude: lon,
      comment: comment,
    );
  }

  setUp(() {
    aprs.disable();
    aprs.clearDisplay();
  });

  tearDown(() {
    aprs.disable();
    aprs.clearDisplay();
  });

  test(
    'repeated incoming geo-chat within an hour removes the recent copies',
    () {
      final now = DateTime.utc(2026, 3, 10, 12, 0);
      final first = buildGeoChatPacket(
        from: 'W5XYZ-9',
        comment: 'Hello from the hill',
        timestamp: now.subtract(const Duration(minutes: 30)),
      );
      final second = buildGeoChatPacket(
        from: 'W5XYZ-9',
        comment: 'Hello from the hill',
        timestamp: now,
        lat: 38.73,
        lon: -9.15,
      );

      aprs.addPacket(first);
      expect(aprs.geoChatMessages, hasLength(1));

      aprs.addPacket(second);
      expect(aprs.geoChatMessages, isEmpty);
    },
  );

  test('older identical geo-chat outside the window is preserved', () {
    final now = DateTime.utc(2026, 3, 10, 12, 0);
    final oldHuman = buildGeoChatPacket(
      from: 'W5XYZ-9',
      comment: 'Hello from the hill',
      timestamp: now.subtract(const Duration(hours: 3)),
    );
    final recentFirst = buildGeoChatPacket(
      from: 'W5XYZ-9',
      comment: 'Hello from the hill',
      timestamp: now.subtract(const Duration(minutes: 30)),
      lat: 38.73,
      lon: -9.15,
    );
    final recentRepeat = buildGeoChatPacket(
      from: 'W5XYZ-9',
      comment: 'Hello from the hill',
      timestamp: now,
      lat: 38.74,
      lon: -9.16,
    );

    aprs.addPacket(oldHuman);
    aprs.addPacket(recentFirst);
    aprs.addPacket(recentRepeat);

    expect(aprs.geoChatMessages, hasLength(1));
    expect(aprs.geoChatMessages.single.timestamp, oldHuman.timestamp);
  });
}
