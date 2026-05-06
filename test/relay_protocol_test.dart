import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geogram/p2p/relay/relay_protocol.dart';

void main() {
  group('RelayMessage codec', () {
    final sid = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

    test('round-trips a HELLO frame', () {
      final frame = RelayMessage(
        type: RelayMessageType.hello,
        sessionId: sid,
        payload: Uint8List(0),
      );
      final wire = frame.encode();
      expect(wire.length, equals(1 + 16 + 4));
      expect(wire[0], equals(RelayMessageType.hello));

      final (decoded, consumed) = RelayMessage.decodeOne(wire, 0);
      expect(consumed, equals(wire.length));
      expect(decoded, isNotNull);
      expect(decoded!.type, equals(RelayMessageType.hello));
      expect(decoded.sessionId, equals(sid));
      expect(decoded.payload.length, equals(0));
    });

    test('round-trips a DATA frame with a non-trivial payload', () {
      final payload = Uint8List.fromList([for (var i = 0; i < 1024; i++) i & 0xff]);
      final frame = RelayMessage(
        type: RelayMessageType.data,
        sessionId: sid,
        payload: payload,
      );
      final wire = frame.encode();
      final (decoded, consumed) = RelayMessage.decodeOne(wire, 0);
      expect(consumed, equals(wire.length));
      expect(decoded, isNotNull);
      expect(decoded!.payload, equals(payload));
    });

    test('decodeAll drains a stream of multiple frames', () {
      final frame1 = RelayMessage(
        type: RelayMessageType.openSession,
        sessionId: sid,
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final frame2 = RelayMessage(
        type: RelayMessageType.data,
        sessionId: sid,
        payload: Uint8List.fromList([0xaa, 0xbb]),
      );
      final wire = Uint8List.fromList([...frame1.encode(), ...frame2.encode()]);
      final (frames, remainder) = RelayMessage.decodeAll(wire);
      expect(frames.length, equals(2));
      expect(remainder.length, equals(0));
      expect(frames[0].type, equals(RelayMessageType.openSession));
      expect(frames[1].type, equals(RelayMessageType.data));
    });

    test('decodeAll preserves a partial trailing frame as remainder', () {
      final frame = RelayMessage(
        type: RelayMessageType.data,
        sessionId: sid,
        payload: Uint8List.fromList([1, 2, 3, 4, 5]),
      );
      final full = frame.encode();
      // Drop the final 2 bytes.
      final partial = Uint8List.fromList(full.sublist(0, full.length - 2));
      final (frames, remainder) = RelayMessage.decodeAll(partial);
      expect(frames.length, equals(0));
      expect(remainder.length, equals(partial.length));
    });

    test('rejects sessionId of wrong length', () {
      expect(
        () => RelayMessage(
          type: RelayMessageType.hello,
          sessionId: Uint8List(8),
          payload: Uint8List(0),
        ),
        throwsArgumentError,
      );
    });
  });
}
