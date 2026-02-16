import 'dart:async';

import 'frame.dart';

typedef GeoBlueSendCallback = Future<void> Function(GeoBlueFrame frame);

class GeoBlueSession {
  final GeoBlueProfile localProfile;
  final List<String> localCapabilities;
  final bool autoAckHello;
  final GeoBlueSendCallback _send;

  final StreamController<GeoBlueFrame> _incomingController =
      StreamController<GeoBlueFrame>.broadcast();

  final Map<String, Completer<GeoBlueFrame>> _helloAckWaiters =
      <String, Completer<GeoBlueFrame>>{};

  GeoBlueSession({
    required this.localProfile,
    required GeoBlueSendCallback send,
    this.localCapabilities = const <String>['hello', 'data', 'broadcast'],
    this.autoAckHello = true,
  }) : _send = send;

  Stream<GeoBlueFrame> get incomingFrames => _incomingController.stream;

  Future<GeoBlueFrame> sendHelloAndWaitAck({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final hello = GeoBlueFrameBuilder.hello(
      profile: localProfile,
      capabilities: localCapabilities,
    );

    final completer = Completer<GeoBlueFrame>();
    _helloAckWaiters[hello.id] = completer;

    await _send(hello);

    try {
      return await completer.future.timeout(timeout);
    } finally {
      _helloAckWaiters.remove(hello.id);
    }
  }

  Future<void> sendData({
    required String content,
    String channel = 'main',
    String? to,
  }) {
    final frame = GeoBlueFrameBuilder.data(
      from: localProfile.callsign,
      content: content,
      channel: channel,
      to: to,
    );
    return _send(frame);
  }

  Future<void> sendBroadcast({
    required String content,
    String topic = 'general',
  }) {
    final frame = GeoBlueFrameBuilder.broadcast(
      from: localProfile.callsign,
      content: content,
      topic: topic,
    );
    return _send(frame);
  }

  Future<void> handleIncomingFrame(GeoBlueFrame frame) async {
    _incomingController.add(frame);

    if (frame.type == GeoBlueFrameType.helloAck) {
      final waiter = _helloAckWaiters.remove(frame.id);
      waiter?.complete(frame);
      return;
    }

    if (frame.type == GeoBlueFrameType.hello && autoAckHello) {
      final ack = GeoBlueFrameBuilder.helloAck(
        requestId: frame.id,
        profile: localProfile,
        capabilities: localCapabilities,
      );
      await _send(ack);
    }
  }

  Future<void> dispose() async {
    for (final completer in _helloAckWaiters.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('GeoBlueSession disposed before HELLO_ACK was received'),
        );
      }
    }
    _helloAckWaiters.clear();
    await _incomingController.close();
  }
}
