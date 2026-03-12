import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:geoblue/geoblue.dart';

import '../lib/bleak_bridge.dart';

// Forward unicast integrity test:
// 1) Perform HELLO handshake.
// 2) Send deterministic 1000-byte payload desktop -> ESP32.
// 3) Receive echo on same channel and verify exact byte-for-byte match.
// 4) Print send and roundtrip timing.
const _testChannel = 'geoblue_unicast_test';

Future<int> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('help', negatable: false, help: 'Show this usage help.')
    ..addOption('callsign', defaultsTo: 'GBLINUX')
    ..addOption('nickname', defaultsTo: 'GeoBlue Linux')
    ..addOption('address', help: 'Target BLE MAC address (optional)')
    ..addOption('scan-seconds', defaultsTo: '8')
    ..addOption('hello-timeout', defaultsTo: '20')
    ..addOption('echo-timeout', defaultsTo: '60')
    ..addOption('payload-file', defaultsTo: 'data/payload_1000.txt')
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
  final scanSeconds = int.tryParse(parsed['scan-seconds']!.toString()) ?? 8;
  final helloTimeout = int.tryParse(parsed['hello-timeout']!.toString()) ?? 20;
  final echoTimeout = int.tryParse(parsed['echo-timeout']!.toString()) ?? 60;

  final payloadPath = _resolveLocalPath(parsed['payload-file']!.toString());
  final payloadFile = File(payloadPath);
  if (!payloadFile.existsSync()) {
    stderr.writeln('Payload file not found: $payloadPath');
    return 2;
  }
  final payloadText = await payloadFile.readAsString();
  final payloadBytes = await payloadFile.readAsBytes();

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
  final echoCompleter = Completer<GeoBlueFrame>();

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

    if (!echoCompleter.isCompleted && frame.type == GeoBlueFrameType.data) {
      final channel = frame.payload['channel']?.toString();
      if (channel == _testChannel) {
        echoCompleter.complete(frame);
      }
    }
  });

  StreamSubscription<GeoBlueFrame>? bridgeSub;

  try {
    stdout.writeln('Payload file: $payloadPath (${payloadBytes.length} bytes)');
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

    final frame = GeoBlueFrameBuilder.data(
      from: callsign,
      to: peerCallsign.isEmpty ? null : peerCallsign,
      channel: _testChannel,
      content: payloadText,
    );

    final stopwatch = Stopwatch()..start();
    await bridge.sendFrame(frame, timeout: Duration(seconds: echoTimeout));
    final desktopToEspMs = stopwatch.elapsedMilliseconds;

    final echo = await echoCompleter.future.timeout(
      Duration(seconds: echoTimeout),
    );
    final roundTripMs = stopwatch.elapsedMilliseconds;
    stopwatch.stop();

    final echoContent = echo.payload['content']?.toString() ?? '';
    final sameContent = echoContent == payloadText;

    stdout.writeln('Unicast send bytes: ${payloadBytes.length}');
    stdout.writeln('Desktop -> ESP32 send time: ${desktopToEspMs} ms');
    stdout.writeln(
      'Desktop -> ESP32 -> Desktop roundtrip time: ${roundTripMs} ms',
    );
    stdout.writeln('Content preserved: $sameContent');

    if (!sameContent) {
      final firstDiff = _firstDiffIndex(payloadText, echoContent);
      stderr.writeln('Payload mismatch at index: $firstDiff');
      return 1;
    }

    return 0;
  } catch (e, st) {
    stderr.writeln('GeoBlue unicast test failed: $e');
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

int _firstDiffIndex(String a, String b) {
  final max = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < max; i++) {
    if (a.codeUnitAt(i) != b.codeUnitAt(i)) {
      return i;
    }
  }
  if (a.length != b.length) {
    return max;
  }
  return -1;
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
