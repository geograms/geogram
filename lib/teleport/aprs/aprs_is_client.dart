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

import '../../models/monitored_task.dart';
import '../../services/log_service.dart';
import '../../util/task_monitor_helpers.dart';
import 'aprs_message_utils.dart';
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
  static const int _defaultPort = 14580;

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
  MonitoredIsolateHandle? _taskHandle;

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
    _taskHandle = MonitoredIsolateHandle(
      id: 'aprs.is_client',
      name: 'APRS-IS Connection',
      description: 'APRS-IS TCP connection loop',
      serviceName: 'AprsIsClient',
      priority: TaskPriority.normal,
    );
    _spawnIsolate();
  }

  /// Disconnect and stop reconnection attempts.
  void disconnect() {
    _running = false;
    _taskHandle?.markIdle();
    _taskHandle?.dispose();
    _taskHandle = null;
    _commandPort?.send({'cmd': 'stop'});
    _killIsolate();
    _connected = false;
    _verified = false;
  }

  /// Send a raw TNC2 line to the APRS-IS server.
  void sendRaw(String line) {
    if (_commandPort == null) {
      LogService().log('AprsIsClient.sendRaw: _commandPort is NULL — not sent');
      return;
    }
    _commandPort!.send({'cmd': 'send', 'line': line});
  }

  /// Update the server-side filter while connected.
  void updateFilter({double? latitude, double? longitude, double? radiusKm}) {
    if (latitude != null) this.latitude = latitude;
    if (longitude != null) this.longitude = longitude;
    if (radiusKm != null) this.radiusKm = radiusKm;
    if (_commandPort == null) {
      LogService().log('AprsIsClient.updateFilter: _commandPort is NULL — filter not sent');
      return;
    }
    LogService().log('AprsIsClient.updateFilter: sending filter lat=${this.latitude} lon=${this.longitude} r=${this.radiusKm}');
    _commandPort!.send({
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
        _taskHandle?.markRunning();
        AprsService().emitEvent(const AprsEvent(AprsEventType.connected));
      } else if (msg == 'verified') {
        _verified = true;
      } else if (msg == 'disconnected') {
        final wasConnected = _connected;
        _connected = false;
        _verified = false;
        _taskHandle?.markIdle();
        if (wasConnected) {
          AprsService().emitEvent(
            const AprsEvent(AprsEventType.disconnected),
          );
        }
      } else if (msg == 'exited') {
        // Isolate exited its run loop — respawn if still running
        _killIsolate();
        _scheduleRespawn();
      } else if (msg.startsWith('send_ok:')) {
        LogService().log('AprsIsClient: sent ${msg.substring(8)}');
      } else if (msg.startsWith('filter_sent:')) {
        LogService().log('AprsIsClient: ${msg.substring(12)}');
      } else if (msg.startsWith('error:')) {
        LogService().log('AprsIsClient: ${msg.substring(6)}');
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
          final filterLine =
              '#filter r/$filterLat/$filterLon/$filterRadius';
          if (socket != null) {
            try {
              socket!.write('$filterLine\r\n');
              socket!.flush();
              mainPort.send('filter_sent:$filterLine');
            } catch (e) {
              mainPort.send('error:Filter send failed: $e');
            }
          } else {
            mainPort.send('error:Filter not sent — socket is null');
          }
        } else if (cmd == 'send') {
          final line = msg['line'] as String?;
          if (line != null && socket != null) {
            try {
              socket!.write('$line\r\n');
              socket!.flush();
              mainPort.send('send_ok:$line');
            } catch (e) {
              mainPort.send('error:Send failed: $e');
            }
          } else {
            mainPort.send('error:Send failed — socket is null');
          }
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

        // Authenticate — only include filter if we have a real position.
        // On port 14580, no filter = no packets until a #filter is sent.
        final hasPosition = filterLat != 0.0 || filterLon != 0.0;
        final baseCallsign = params.callsign.toUpperCase();
        final filterSuffix = hasPosition
            ? ' filter r/$filterLat/$filterLon/$filterRadius g/$baseCallsign/BLN*'
            : ' filter g/$baseCallsign/BLN*';
        final authLine = 'user ${params.callsign} pass ${params.passcode} '
            'vers Geogram 1.0$filterSuffix';
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

    String? messageAddressee;
    String? messageText;
    String? messageId;
    if (type == AprsPacketType.message) {
      final parsed = _parseMessage(infoField);
      messageAddressee = parsed?.$1;
      messageText = parsed?.$2;
      messageId = parsed?.$3;
    }

    // Parse position from position packets
    double? latitude;
    double? longitude;
    String? comment;
    if (type == AprsPacketType.position) {
      final pos = _parsePosition(infoField);
      if (pos != null) {
        latitude = pos.$1;
        longitude = pos.$2;
      }
      comment = _extractPositionComment(infoField);
    }

    return AprsPacket(
      fromCallsign: fromCallsign,
      toCallsign: toCallsign,
      path: path,
      infoField: infoField,
      rawTnc2: raw,
      timestamp: DateTime.now().toUtc(),
      type: type,
      latitude: latitude,
      longitude: longitude,
      messageAddressee: messageAddressee,
      messageText: messageText,
      messageId: messageId,
      comment: comment,
    );
  }

  static AprsPacketType _classifyInfoField(String info) {
    if (info.isEmpty) return AprsPacketType.other;
    final c = info[0];
    if (c == '!' || c == '/' || c == '=' || c == '@') {
      return AprsPacketType.position;
    }
    // Mic-E encoded position (current ` and old ')
    if (c == '`' || c == '\x27') return AprsPacketType.position;
    if (c == ':') return AprsPacketType.message;
    if (c == '>') return AprsPacketType.status;
    if (c == '_') return AprsPacketType.weather;
    if (c == 'T') return AprsPacketType.telemetry;
    // Object (;) and Item (]) also carry position
    if (c == ';' || c == ')') return AprsPacketType.position;
    return AprsPacketType.other;
  }

  static (String, String, String?)? _parseMessage(String info) {
    if (info.length < 11 || info[0] != ':') return null;
    final secondColon = info.indexOf(':', 1);
    if (secondColon < 0) return null;
    final addressee = info.substring(1, secondColon).trim();
    if (addressee.isEmpty) return null;

    final body = info.substring(secondColon + 1);

    final braceIdx = body.indexOf('{');
    if (braceIdx >= 0) {
      return (addressee, body.substring(0, braceIdx), body.substring(braceIdx + 1));
    }
    return (addressee, body, null);
  }

  // ---------------------------------------------------------------------------
  // APRS position parser
  // ---------------------------------------------------------------------------

  /// Parse lat/lon from an APRS position info field.
  /// Handles uncompressed and compressed formats.
  ///
  /// Uncompressed: `!DDMM.MMN/DDDMM.MMWx` or with timestamp `/DDHHMMzDDMM.MMN/DDDMM.MMWx`
  /// Compressed:   `!/YYYYXXXX$csT`  (base-91 encoded)
  static (double, double)? _parsePosition(String info) {
    if (info.isEmpty) return null;

    final c = info[0];

    // Mic-E: position encoded in destination address + info field
    // We can't decode Mic-E without the dest callsign, so skip for now.
    // (Mic-E latitude is in the destination field, not the info field.)
    if (c == '`' || c == '\x27') return null;

    // Object: ;NAME_____*DDHHMMzDDMM.MMN/DDDMM.MMWs
    if (c == ';') {
      // Object name is 9 chars, then * or _, then optional timestamp
      if (info.length < 11) return null;
      final afterName = info.substring(10);
      // afterName starts with * or _, then 7-char timestamp, then position
      if (afterName.isEmpty) return null;
      final tsByte = afterName[0];
      if (tsByte == '*' || tsByte == '_') {
        if (afterName.length < 8) return null;
        final posData = afterName.substring(8);
        if (posData.isNotEmpty && _isDigit(posData[0])) {
          return _parseUncompressedPosition(posData);
        } else if (posData.length >= 13) {
          return _parseCompressedPosition(posData);
        }
      }
      return null;
    }

    // Item: )NAME!DDMM.MMN/DDDMM.MMWs or )NAME_...
    if (c == ')') {
      // Find ! or _ delimiter after item name (3–9 chars)
      final delimIdx = info.indexOf('!', 1);
      final delimIdx2 = info.indexOf('_', 1);
      int dIdx = -1;
      if (delimIdx > 0 && delimIdx < 11) dIdx = delimIdx;
      if (delimIdx2 > 0 && delimIdx2 < 11 && (dIdx < 0 || delimIdx2 < dIdx)) {
        dIdx = delimIdx2;
      }
      if (dIdx < 0 || dIdx + 1 >= info.length) return null;
      final posData = info.substring(dIdx + 1);
      if (posData.isNotEmpty && _isDigit(posData[0])) {
        return _parseUncompressedPosition(posData);
      }
      return null;
    }

    // Standard position formats
    String posData;
    if (c == '/' || c == '@') {
      // Has timestamp — DTI (1 char) + DDHHMMz (7 chars) = 8 chars to skip
      if (info.length < 9) return null;
      posData = info.substring(8);
    } else {
      // '!' or '=' — position starts immediately after the indicator
      posData = info.substring(1);
    }

    if (posData.isEmpty) return null;

    if (_isDigit(posData[0])) {
      return _parseUncompressedPosition(posData);
    } else {
      return _parseCompressedPosition(posData);
    }
  }

  /// Parse uncompressed APRS position: `DDMM.MMNsDDDMM.MMWc`
  /// where s = symbol table ID (any char), c = symbol code.
  static (double, double)? _parseUncompressedPosition(String data) {
    // Need at least: DDMM.MMN + symtable + DDDMM.MMW + symcode = 19 chars
    if (data.length < 19) return null;

    // Latitude: DDMM.MM[N/S] at indices 0–7
    final latDeg = int.tryParse(data.substring(0, 2));
    final latMin = double.tryParse(data.substring(2, 7));
    final latHemi = data[7];
    if (latDeg == null || latMin == null) return null;
    if (latHemi != 'N' && latHemi != 'S') return null;

    // Index 8 is the symbol table ID (any printable char, NOT necessarily '/')

    // Longitude: DDDMM.MM[E/W] at indices 9–17
    final lonDeg = int.tryParse(data.substring(9, 12));
    final lonMin = double.tryParse(data.substring(12, 17));
    final lonHemi = data[17];
    if (lonDeg == null || lonMin == null) return null;
    if (lonHemi != 'E' && lonHemi != 'W') return null;

    double lat = latDeg + latMin / 60.0;
    double lon = lonDeg + lonMin / 60.0;
    if (latHemi == 'S') lat = -lat;
    if (lonHemi == 'W') lon = -lon;

    // Sanity check
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return (lat, lon);
  }

  /// Parse compressed APRS position: 13 chars `/YYYYXXXXcsT`
  /// where YYYY=lat, XXXX=lon in base-91, c=symbol code, s=compressed
  /// course/speed, T=compression type byte.
  static (double, double)? _parseCompressedPosition(String data) {
    // Need symbol table char + 4 lat + 4 lon + symbol code + 2 cs + type = 13
    if (data.length < 13) return null;

    // data[0] is symbol table identifier (e.g. '/' or '\')
    // data[1..4] is base-91 latitude
    // data[5..8] is base-91 longitude
    final latVal = _base91Decode(data, 1, 4);
    final lonVal = _base91Decode(data, 5, 4);
    if (latVal == null || lonVal == null) return null;

    final lat = 90.0 - latVal / 380926.0;
    final lon = -180.0 + lonVal / 190463.0;

    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return (lat, lon);
  }

  /// Decode a base-91 encoded value from [count] chars starting at [offset].
  static double? _base91Decode(String data, int offset, int count) {
    double val = 0;
    for (int i = 0; i < count; i++) {
      final ch = data.codeUnitAt(offset + i) - 33;
      if (ch < 0 || ch > 90) return null;
      val = val * 91 + ch;
    }
    return val;
  }

  /// Extract comment text from a position info field.
  /// Returns null or empty string when there is no comment.
  static String? _extractPositionComment(String info) {
    if (info.isEmpty) return null;
    final c = info[0];

    // Mic-E, Object, Item — skip (complex formats)
    if (c == '`' || c == '\x27' || c == ';' || c == ')') return null;

    String posData;
    if (c == '/' || c == '@') {
      // Timestamped: DTI (1 char) + DDHHMMz (7 chars) = skip 8
      if (info.length < 9) return null;
      posData = info.substring(8);
    } else if (c == '!' || c == '=') {
      posData = info.substring(1);
    } else {
      return null;
    }

    if (posData.isEmpty) return null;

    int posLen;
    if (_isDigit(posData[0])) {
      // Uncompressed: 19 chars (DDMM.MMN/DDDMM.MMW + symbol code)
      posLen = 19;
    } else {
      // Compressed: 13 chars (symtable + 4 lat + 4 lon + symbol + 2 cs + type)
      posLen = 13;
    }

    if (posData.length <= posLen) return null;
    final comment = posData.substring(posLen).trim();
    return comment.isEmpty ? null : comment;
  }

  static bool _isDigit(String ch) =>
      ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57;

  // ---------------------------------------------------------------------------
  // One-shot send — standalone function, no service singleton needed
  // ---------------------------------------------------------------------------

  /// Send a single APRS message via a short-lived TCP connection.
  ///
  /// Connects to APRS-IS, authenticates, sends the message, optionally waits
  /// for an ACK, then disconnects. Completely independent of [AprsService].
  ///
  /// Returns a result map with:
  ///   `sent`: true if the line was written to the socket
  ///   `acked`: true if an ACK was received within [ackTimeout]
  ///   `line`: the raw TNC2 line that was sent
  ///   `error`: error message if something went wrong
  ///
  /// Example:
  /// ```dart
  /// final result = await AprsIsClient.sendOneShot(
  ///   callsign: 'CR7BBQ',
  ///   destination: 'N0CALL',
  ///   message: 'Hello from Geogram!',
  /// );
  /// ```
  static Future<Map<String, dynamic>> sendOneShot({
    required String callsign,
    required String destination,
    required String message,
    String host = _defaultHost,
    int port = _defaultPort,
    Duration ackTimeout = const Duration(seconds: 15),
  }) async {
    final passcode = aprsPasscode(callsign);

    // Build the TNC2 message line
    final destPadded = destination.toUpperCase().padRight(9);
    final seqNo = DateTime.now().millisecondsSinceEpoch % 100000;
    final fullText = message.length > aprsMaxMessageLen
        ? message.substring(0, aprsMaxMessageLen)
        : message;
    final line = '${callsign.toUpperCase()}>APRS,TCPIP*::$destPadded:$fullText{$seqNo';

    Socket? socket;
    try {
      // Connect
      socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 10));

      final lineBuffer = StringBuffer();
      bool bannerSeen = false;
      bool verified = false;
      bool acked = false;
      final completer = Completer<void>();

      // Listen for server responses
      final sub = socket.listen(
        (data) {
          lineBuffer.write(utf8.decode(data, allowMalformed: true));
          final text = lineBuffer.toString();
          final lines = text.split('\n');
          lineBuffer.clear();
          if (!text.endsWith('\n')) {
            lineBuffer.write(lines.removeLast());
          } else if (lines.isNotEmpty && lines.last.isEmpty) {
            lines.removeLast();
          }

          for (final raw in lines) {
            final l = raw.replaceAll('\r', '').trim();
            if (l.isEmpty) continue;

            if (l.startsWith('#')) {
              bannerSeen = true;
              if (l.contains('logresp') && l.contains('verified')) {
                verified = true;
              }
              continue;
            }

            // Check for ACK addressed to us
            if (l.contains(':ack$seqNo')) {
              acked = true;
              if (!completer.isCompleted) completer.complete();
            }
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      // Wait for banner
      await Future.delayed(const Duration(seconds: 2));
      if (!bannerSeen) {
        await sub.cancel();
        socket.destroy();
        return {'sent': false, 'acked': false, 'line': line, 'error': 'No banner received'};
      }

      // Authenticate (no filter needed — we only send)
      final authLine = 'user $callsign pass $passcode vers Geogram 1.0';
      socket.write('$authLine\r\n');
      await socket.flush();

      // Brief pause for auth response
      await Future.delayed(const Duration(milliseconds: 500));

      // Send the message
      socket.write('$line\r\n');
      await socket.flush();

      // Wait for ACK (or timeout)
      await completer.future.timeout(ackTimeout, onTimeout: () {});

      await sub.cancel();
      socket.destroy();

      return {
        'sent': true,
        'acked': acked,
        'verified': verified,
        'line': line,
        'seqNo': seqNo,
      };
    } catch (e) {
      socket?.destroy();
      return {'sent': false, 'acked': false, 'line': line, 'error': '$e'};
    }
  }
}
