import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:geoblue/geoblue.dart';

import '../lib/bleak_bridge.dart';

Future<int> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('help', negatable: false, help: 'Show this usage help.')
    ..addOption('callsign', defaultsTo: 'GBLINUX')
    ..addOption('nickname', defaultsTo: 'GeoBlue Linux')
    ..addOption('address', help: 'Target BLE MAC address (optional)')
    ..addOption('scan-seconds', defaultsTo: '8')
    ..addOption('bridge-script', defaultsTo: 'bin/geoblue_bleak_bridge.py')
    ..addOption('hello-timeout', defaultsTo: '20');

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
      await bridge.sendFrame(frame);
      stdout.writeln('TX ${frame.type.wireName} id=${frame.id}');
    },
    autoAckHello: false,
  );

  var gotPeerHello = false;
  var connectedReady = false;
  final ackedHelloIds = <String>{};

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
    try {
      await bridge.sendFrame(ack);
      stdout.writeln('TX ${ack.type.wireName} id=${ack.id}');
    } catch (e) {
      stderr.writeln('Failed to send HELLO_ACK for ${frame.id}: $e');
    }
  }

  final sub = session.incomingFrames.listen((frame) {
    final from = (frame.payload['profile'] as Map?)?['callsign']?.toString() ??
        frame.payload['from']?.toString() ??
        'unknown';
    stdout.writeln('RX ${frame.type.wireName} id=${frame.id} from=$from payload=${frame.payload}');
    if (frame.type == GeoBlueFrameType.hello) {
      gotPeerHello = true;
    }
  });
  StreamSubscription<GeoBlueFrame>? frameSub;

  try {
    stdout.writeln('Scanning for Geogram BLE devices ($scanSeconds seconds)...');
    final scanResult = await bridge.scan(timeout: Duration(seconds: scanSeconds));
    final devices = (scanResult['devices'] as List?)?.cast<Map>() ?? const <Map>[];

    if (devices.isEmpty) {
      stderr.writeln('No Geogram BLE devices found.');
      return 1;
    }

    for (final dev in devices) {
      stdout.writeln(' - ${dev['address']}  name=${dev['name']} rssi=${dev['rssi']}');
    }

    final target = _selectTarget(devices, forcedAddress);
    if (target == null) {
      stderr.writeln('Could not resolve target device.');
      return 1;
    }

    final targetAddress = target['address']!.toString();
    stdout.writeln('Connecting to $targetAddress...');
    await bridge.connect(targetAddress);
    connectedReady = true;
    frameSub = bridge.frames.listen((frame) async {
      await sendHelloAckIfNeeded(frame);
      await session.handleIncomingFrame(frame);
    });
    stdout.writeln('Connected. Waiting for proactive HELLO and sending HELLO...');

    final helloAck = await session.sendHelloAndWaitAck(
      timeout: Duration(seconds: helloTimeout),
    );

    stdout.writeln('Received HELLO_ACK id=${helloAck.id} payload=${helloAck.payload}');

    final deadline = DateTime.now().add(Duration(seconds: helloTimeout));
    while (!gotPeerHello && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (!gotPeerHello) {
      stderr.writeln('Did not receive peer HELLO within timeout.');
      return 1;
    }

    stdout.writeln('HELLO exchange complete in both directions.');
    return 0;
  } catch (e, st) {
    stderr.writeln('GeoBlue test failed: $e');
    stderr.writeln(st);
    return 1;
  } finally {
    await frameSub?.cancel();
    await sub.cancel();
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
