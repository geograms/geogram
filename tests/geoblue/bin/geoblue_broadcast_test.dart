import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:geoblue/geoblue.dart';

import '../lib/bleak_bridge.dart';

// Broadcast sender test:
// 1) Perform HELLO handshake with ESP32.
// 2) Send one BLE broadcast frame (topic + content).
// 3) Wait for ESP32 listener receipt on channel geoblue_broadcast_receipt.
// This confirms listener-side delivery using BLE only (no serial dependency).
const _broadcastReceiptChannel = 'geoblue_broadcast_receipt';

Future<int> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('help', negatable: false, help: 'Show this usage help.')
    ..addOption('callsign', defaultsTo: 'GBLINUX')
    ..addOption('nickname', defaultsTo: 'GeoBlue Linux')
    ..addOption('address', help: 'Target BLE MAC address (optional)')
    ..addOption('scan-seconds', defaultsTo: '10')
    ..addOption('hello-timeout', defaultsTo: '25')
    ..addOption('receipt-timeout', defaultsTo: '25')
    ..addOption('topic', defaultsTo: 'geoblue_global_chat')
    ..addOption('content')
    ..addOption('bridge-script', defaultsTo: 'bin/geoblue_bleak_bridge.py');

  late ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } catch (e) {
    stderr.writeln('Argument error: $e');
    stderr.writeln(parser.usage);
    return 2;
  }

  if (parsed['help'] == true) {
    stdout.writeln(parser.usage);
    return 0;
  }

  final callsign = parsed['callsign']!.toString().toUpperCase();
  final nickname = parsed['nickname']!.toString();
  final forcedAddress = parsed['address']?.toString();
  final scanSeconds = int.tryParse(parsed['scan-seconds']!.toString()) ?? 10;
  final helloTimeout = int.tryParse(parsed['hello-timeout']!.toString()) ?? 25;
  final receiptTimeout =
      int.tryParse(parsed['receipt-timeout']!.toString()) ?? 25;
  final topic = parsed['topic']!.toString();
  final content = (parsed['content']?.toString().trim().isNotEmpty ?? false)
      ? parsed['content']!.toString()
      : 'GEOBLUE-BROADCAST-${DateTime.now().millisecondsSinceEpoch}';

  final scriptPath = _resolveLocalPath(parsed['bridge-script']!.toString());
  if (!File(scriptPath).existsSync()) {
    stderr.writeln('Bridge script not found: $scriptPath');
    return 2;
  }

  final bridge = BleakBridge(pythonScriptPath: scriptPath);
  await bridge.start();

  final localProfile = GeoBlueProfile(
    callsign: callsign,
    nickname: nickname,
    platform: 'linux',
  );

  final session = GeoBlueSession(
    localProfile: localProfile,
    send: (frame) async {
      await bridge.sendFrame(frame, timeout: const Duration(seconds: 60));
      stdout.writeln('TX ${frame.type.wireName} id=${frame.id}');
    },
    autoAckHello: false,
  );

  var connectedReady = false;
  var peerCallsign = '';
  var shuttingDown = false;
  final ackedHelloIds = <String>{};
  final receiptCompleter = Completer<GeoBlueFrame>();

  Future<void> sendHelloAckIfNeeded(GeoBlueFrame frame) async {
    if (frame.type != GeoBlueFrameType.hello) {
      return;
    }
    if (!connectedReady) {
      return;
    }
    if (!ackedHelloIds.add(frame.id)) {
      return;
    }

    final ack = GeoBlueFrameBuilder.helloAck(
      requestId: frame.id,
      profile: localProfile,
    );
    await bridge.sendFrame(ack, timeout: const Duration(seconds: 30));
    stdout.writeln('TX ${ack.type.wireName} id=${ack.id}');
  }

  final incomingSub = session.incomingFrames.listen((frame) {
    final from =
        frame.payload['from']?.toString() ??
        (frame.payload['profile'] as Map?)?['callsign']?.toString() ??
        frame.payload['callsign']?.toString() ??
        'unknown';

    if (frame.type == GeoBlueFrameType.hello && from != 'unknown') {
      peerCallsign = from;
    }

    if (frame.type == GeoBlueFrameType.helloAck) {
      final ackCallsign = frame.payload['callsign']?.toString();
      if (ackCallsign != null && ackCallsign.isNotEmpty) {
        peerCallsign = ackCallsign;
      }
    }

    if (frame.type == GeoBlueFrameType.data && !receiptCompleter.isCompleted) {
      final channel = frame.payload['channel']?.toString();
      final receiptContent = frame.payload['content']?.toString() ?? '';
      if (channel == _broadcastReceiptChannel && receiptContent == content) {
        receiptCompleter.complete(frame);
      }
    }
  });

  StreamSubscription<GeoBlueFrame>? bridgeSub;

  try {
    stdout.writeln(
      'Scanning for Geogram BLE devices ($scanSeconds seconds)...',
    );
    final scanResult = await bridge.scan(
      timeout: Duration(seconds: scanSeconds),
    );
    final devices =
        (scanResult['devices'] as List?)?.cast<Map>() ?? const <Map>[];

    if (devices.isEmpty) {
      stderr.writeln('No Geogram BLE devices found.');
      return 1;
    }

    for (final dev in devices) {
      stdout.writeln(
        ' - ${dev['address']}  name=${dev['name']} rssi=${dev['rssi']}',
      );
    }

    final target = _selectTarget(devices, forcedAddress);
    if (target == null) {
      stderr.writeln('Could not resolve target device.');
      return 1;
    }

    final targetAddress = target['address']!.toString();
    stdout.writeln('Connecting to $targetAddress...');
    final connect = await bridge.connect(targetAddress);
    stdout.writeln('Connected (MTU=${connect['mtu_size'] ?? 'unknown'}).');

    connectedReady = true;
    bridgeSub = bridge.frames.listen((frame) async {
      if (shuttingDown) {
        return;
      }
      await sendHelloAckIfNeeded(frame);
      if (shuttingDown) {
        return;
      }
      try {
        await session.handleIncomingFrame(frame);
      } catch (e) {
        if (!shuttingDown) {
          stderr.writeln('Frame handling error: $e');
        }
      }
    });

    stdout.writeln('Running HELLO handshake...');
    final helloAck = await session.sendHelloAndWaitAck(
      timeout: Duration(seconds: helloTimeout),
    );

    final ackCallsign = helloAck.payload['callsign']?.toString();
    if (ackCallsign != null && ackCallsign.isNotEmpty) {
      peerCallsign = ackCallsign;
    }
    stdout.writeln(
      'HELLO OK with ${peerCallsign.isEmpty ? 'peer' : peerCallsign}',
    );

    final broadcast = GeoBlueFrameBuilder.broadcast(
      from: callsign,
      topic: topic,
      content: content,
    );
    await bridge.sendFrame(broadcast, timeout: const Duration(seconds: 30));
    final stopwatch = Stopwatch()..start();
    stdout.writeln(
      'Broadcast sent topic="$topic" content="$content" to listener=${peerCallsign.isEmpty ? 'unknown' : peerCallsign}',
    );

    await receiptCompleter.future.timeout(Duration(seconds: receiptTimeout));
    stopwatch.stop();
    stdout.writeln(
      'Broadcast receipt received in ${stopwatch.elapsedMilliseconds} ms',
    );

    return 0;
  } catch (e, st) {
    stderr.writeln('GeoBlue broadcast test failed: $e');
    stderr.writeln(st);
    return 1;
  } finally {
    shuttingDown = true;
    await bridgeSub?.cancel();
    await incomingSub.cancel();
    await session.dispose();
    await bridge.dispose();
  }
}

String _resolveLocalPath(String path) {
  final f = File(path);
  if (f.existsSync()) {
    return f.path;
  }

  final scriptDir = File(Platform.script.toFilePath()).parent.path;
  final fromScript = File('$scriptDir/$path');
  if (fromScript.existsSync()) {
    return fromScript.path;
  }

  final fromCwd = File('${Directory.current.path}/tests/geoblue/$path');
  if (fromCwd.existsSync()) {
    return fromCwd.path;
  }

  return path;
}

Map<String, dynamic>? _selectTarget(List<Map> devices, String? forcedAddress) {
  if (forcedAddress != null && forcedAddress.isNotEmpty) {
    for (final dev in devices) {
      if (dev['address']?.toString().toLowerCase() ==
          forcedAddress.toLowerCase()) {
        return dev.cast<String, dynamic>();
      }
    }
    return null;
  }

  return devices.first.cast<String, dynamic>();
}
