/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * APRS-IS TCP client — connects to the APRS Internet Service,
 * authenticates, receives TNC2 packets, and maintains keepalive.
 *
 * TCP socket handling runs in a background isolate to avoid freezing
 * the Flutter UI. Raw TNC2 lines cross the isolate boundary as
 * List<String> batches; parsing into AprsPacket happens on the main
 * isolate (lightweight — a batch of ~100 strings takes <1ms).
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'aprs_service.dart';
import 'models/aprs_packet.dart';

/// Parameters sent to the background isolate on spawn.
class _IsolateParams {
  final SendPort sendPort;
  final String callsign;
  final int passcode;
  final String host;
  final int port;
  final double latitude;
  final double longitude;
  final double radiusKm;

  const _IsolateParams({
    required this.sendPort,
    required this.callsign,
    required this.passcode,
    required this.host,
    required this.port,
    required this.latitude,
    required this.longitude,
    required this.radiusKm,
  });
}

class AprsIsClient {
  static const String _defaultHost = 'rotate.aprs2.net';
  static const int _defaultPort = 10152;

  final String callsign;
  double latitude;
  double longitude;
  double radiusKm;
  final String host;
  final int port;

  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _commandPort;

  bool _running = false;
  bool _connected = false;
  bool _verified = false;

  AprsIsClient({
    required this.callsign,
    required this.latitude,
    required this.longitude,
    required this.radiusKm,
    this.host = _defaultHost,
    this.port = _defaultPort,
  });

  bool get isConnected => _connected;
  bool get isVerified => _verified;

  /// Compute APRS-IS passcode from callsign.
  static int aprsPasscode(String callsign) {
    final base = callsign.toUpperCase().split('-')[0];
    int hash = 0x73e2;
    for (int i = 0; i < base.length; i++) {
      hash ^= base.codeUnitAt(i) << 8;
      if (++i < base.length) {
        hash ^= base.codeUnitAt(i);
      }
    }
    return hash & 0x7FFF;
  }

  /// Start the connection loop. Idempotent — calling while running is a no-op.
  Future<void> connect() async {
    if (_running) return;
    _running = true;
    _spawnIsolate();
  }

  /// Disconnect and stop reconnection attempts.
  void disconnect() {
    _running = false;
    _commandPort?.send({'cmd': 'stop'});
    _killIsolate();
    _connected = false;
    _verified = false;
  }

  /// Update the server-side filter while connected.
  void updateFilter({double? latitude, double? longitude, double? radiusKm}) {
    if (latitude != null) this.latitude = latitude;
    if (longitude != null) this.longitude = longitude;
    if (radiusKm != null) this.radiusKm = radiusKm;
    _commandPort?.send({
      'cmd': 'filter',
      'lat': this.latitude,
      'lon': this.longitude,
      'radius': this.radiusKm,
    });
  }

  // ---------------------------------------------------------------------------
  // Isolate lifecycle
  // ---------------------------------------------------------------------------

  void _spawnIsolate() {
    _receivePort = ReceivePort();
    _receivePort!.listen(_handleIsolateMessage);

    final params = _IsolateParams(
      sendPort: _receivePort!.sendPort,
      callsign: callsign,
      passcode: aprsPasscode(callsign),
      host: host,
      port: port,
      latitude: latitude,
      longitude: longitude,
      radiusKm: radiusKm,
    );

    Isolate.spawn(_isolateEntry, params).then((iso) {
      _isolate = iso;
    }).catchError((e) {
      AprsService().emitEvent(
        AprsEvent(AprsEventType.error, 'Isolate spawn failed: $e'),
      );
      _scheduleRespawn();
    });
  }

  void _killIsolate() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _commandPort = null;
  }

  void _scheduleRespawn() {
    if (!_running) return;
    Future.delayed(const Duration(seconds: 10), () {
      if (_running) _spawnIsolate();
    });
  }

  // ---------------------------------------------------------------------------
  // Messages from background isolate
  // ---------------------------------------------------------------------------

  void _handleIsolateMessage(dynamic msg) {
    if (msg is SendPort) {
      _commandPort = msg;
      return;
    }

    if (msg is String) {
      if (msg == 'connected') {
        _connected = true;
        AprsService().emitEvent(const AprsEvent(AprsEventType.connected));
      } else if (msg == 'verified') {
        _verified = true;
      } else if (msg == 'disconnected') {
        final wasConnected = _connected;
        _connected = false;
        _verified = false;
        if (wasConnected) {
          AprsService().emitEvent(
            const AprsEvent(AprsEventType.disconnected),
          );
        }
      } else if (msg == 'exited') {
        // Isolate exited its run loop — respawn if still running
        _killIsolate();
        _scheduleRespawn();
      } else if (msg.startsWith('error:')) {
        AprsService().emitEvent(
          AprsEvent(AprsEventType.error, msg.substring(6)),
        );
      }
      return;
    }

    if (msg is List<String>) {
      // Batch of raw TNC2 lines from the background isolate
      for (final raw in msg) {
        final packet = _parseTnc2(raw);
        if (packet != null) {
          AprsService().addPacket(packet);
        }
      }
      return;
    }
  }

  // ---------------------------------------------------------------------------
  // Background isolate entry point (top-level static)
  // ---------------------------------------------------------------------------

  static Future<void> _isolateEntry(_IsolateParams params) async {
    final mainPort = params.sendPort;
    final cmdPort = ReceivePort();
    mainPort.send(cmdPort.sendPort);

    bool running = true;
    Socket? socket;
    Timer? keepaliveTimer;

    // Current filter values (updated via commands)
    double filterLat = params.latitude;
    double filterLon = params.longitude;
    double filterRadius = params.radiusKm;

    // Listen for commands from the main isolate
    cmdPort.listen((msg) {
      if (msg is Map) {
        final cmd = msg['cmd'];
        if (cmd == 'filter') {
          filterLat = (msg['lat'] as num).toDouble();
          filterLon = (msg['lon'] as num).toDouble();
          filterRadius = (msg['radius'] as num).toDouble();
          try {
            socket?.write(
              '#filter r/$filterLat/$filterLon/$filterRadius\r\n',
            );
            socket?.flush();
          } catch (_) {}
        } else if (cmd == 'stop') {
          running = false;
          keepaliveTimer?.cancel();
          try {
            socket?.destroy();
          } catch (_) {}
        }
      }
    });

    // Connection loop with reconnect
    while (running) {
      try {
        socket = await Socket.connect(
          params.host,
          params.port,
          timeout: const Duration(seconds: 15),
        );

        // Wait for server banner
        final bannerCompleter = Completer<void>();
        final lineBuffer = StringBuffer();
        bool bannerReceived = false;
        bool authenticated = false;

        // Line batch buffer — accumulate raw TNC2 lines and flush periodically
        final lineBatch = <String>[];
        Timer? batchTimer;

        void flushBatch() {
          if (lineBatch.isNotEmpty) {
            mainPort.send(List<String>.from(lineBatch));
            lineBatch.clear();
          }
        }

        batchTimer = Timer.periodic(
          const Duration(milliseconds: 200),
          (_) => flushBatch(),
        );

        void handleLine(String line) {
          if (line.startsWith('#')) {
            // Server comment / control line
            if (!bannerReceived) {
              bannerReceived = true;
              if (!bannerCompleter.isCompleted) {
                bannerCompleter.complete();
              }
            }
            if (line.contains('logresp') && line.contains('verified')) {
              mainPort.send('verified');
            }
            return;
          }
          // Raw TNC2 packet — add to batch
          lineBatch.add(line);
        }

        void onData(List<int> data) {
          lineBuffer.write(utf8.decode(data, allowMalformed: true));
          final text = lineBuffer.toString();
          final lines = text.split('\n');

          lineBuffer.clear();
          if (!text.endsWith('\n')) {
            lineBuffer.write(lines.removeLast());
          } else {
            if (lines.isNotEmpty && lines.last.isEmpty) {
              lines.removeLast();
            }
          }

          for (final raw in lines) {
            final line = raw.replaceAll('\r', '').trim();
            if (line.isEmpty) continue;
            handleLine(line);
          }
        }

        // Subscribe to socket data
        final sub = socket.listen(
          onData,
          onError: (_) {
            if (!bannerCompleter.isCompleted) {
              bannerCompleter.completeError('socket error');
            }
          },
          onDone: () {
            if (!bannerCompleter.isCompleted) {
              bannerCompleter.completeError('socket closed');
            }
          },
        );

        // Wait for banner (with timeout)
        try {
          await bannerCompleter.future.timeout(
            const Duration(seconds: 10),
          );
        } catch (_) {
          batchTimer.cancel();
          flushBatch();
          await sub.cancel();
          socket.destroy();
          mainPort.send('error:Banner timeout');
          if (running) {
            await Future.delayed(const Duration(seconds: 10));
          }
          continue;
        }

        // Authenticate
        final authLine = 'user ${params.callsign} pass ${params.passcode} '
            'vers Geogram 1.0 '
            'filter r/$filterLat/$filterLon/$filterRadius';
        socket.write('$authLine\r\n');
        await socket.flush();
        authenticated = true;

        mainPort.send('connected');

        // Keepalive timer
        keepaliveTimer?.cancel();
        keepaliveTimer = Timer.periodic(
          const Duration(minutes: 10),
          (_) {
            try {
              socket?.write('#heartbeat\r\n');
              socket?.flush();
            } catch (_) {}
          },
        );

        // Wait until socket closes or we're told to stop
        final doneCompleter = Completer<void>();
        sub.onDone(() {
          if (!doneCompleter.isCompleted) doneCompleter.complete();
        });
        sub.onError((_) {
          if (!doneCompleter.isCompleted) doneCompleter.complete();
        });

        await doneCompleter.future;

        // Cleanup this connection
        batchTimer.cancel();
        flushBatch();
        keepaliveTimer?.cancel();
        keepaliveTimer = null;
        await sub.cancel();
        socket.destroy();
        socket = null;

        mainPort.send('disconnected');
      } catch (e) {
        mainPort.send('error:Connect failed: $e');
        try {
          socket?.destroy();
        } catch (_) {}
        socket = null;
      }

      // Reconnect delay
      if (running) {
        await Future.delayed(const Duration(seconds: 10));
      }
    }

    // Isolate is exiting its run loop
    cmdPort.close();
    mainPort.send('exited');
  }

  // ---------------------------------------------------------------------------
  // TNC2 parser (runs on main isolate)
  // ---------------------------------------------------------------------------

  static AprsPacket? _parseTnc2(String raw) {
    final colonIdx = raw.indexOf(':');
    if (colonIdx < 0 || colonIdx + 1 >= raw.length) return null;

    final header = raw.substring(0, colonIdx);
    final infoField = raw.substring(colonIdx + 1);

    final gtIdx = header.indexOf('>');
    if (gtIdx < 0) return null;

    final fromCallsign = header.substring(0, gtIdx);
    final afterGt = header.substring(gtIdx + 1);

    String toCallsign;
    String? path;
    final commaIdx = afterGt.indexOf(',');
    if (commaIdx >= 0) {
      toCallsign = afterGt.substring(0, commaIdx);
      path = afterGt.substring(commaIdx + 1);
    } else {
      toCallsign = afterGt;
    }

    final type = _classifyInfoField(infoField);

    String? messageText;
    String? messageId;
    if (type == AprsPacketType.message) {
      final parsed = _parseMessage(infoField);
      messageText = parsed?.$1;
      messageId = parsed?.$2;
    }

    return AprsPacket(
      fromCallsign: fromCallsign,
      toCallsign: toCallsign,
      path: path,
      infoField: infoField,
      rawTnc2: raw,
      timestamp: DateTime.now().toUtc(),
      type: type,
      messageText: messageText,
      messageId: messageId,
    );
  }

  static AprsPacketType _classifyInfoField(String info) {
    if (info.isEmpty) return AprsPacketType.other;
    final c = info[0];
    if (c == '!' || c == '/' || c == '=' || c == '@') {
      return AprsPacketType.position;
    }
    if (c == ':') return AprsPacketType.message;
    if (c == '>') return AprsPacketType.status;
    if (c == '_') return AprsPacketType.weather;
    if (c == 'T') return AprsPacketType.telemetry;
    return AprsPacketType.other;
  }

  static (String, String?)? _parseMessage(String info) {
    if (info.length < 11 || info[0] != ':') return null;
    final secondColon = info.indexOf(':', 1);
    if (secondColon < 0) return null;

    final body = info.substring(secondColon + 1);

    final braceIdx = body.indexOf('{');
    if (braceIdx >= 0) {
      return (body.substring(0, braceIdx), body.substring(braceIdx + 1));
    }
    return (body, null);
  }
}
