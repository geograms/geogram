import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:geoblue/geoblue.dart';

class BleakBridgeEvent {
  final String kind;
  final Map<String, dynamic> data;

  BleakBridgeEvent(this.kind, this.data);
}

class BleakBridge {
  final String pythonScriptPath;
  final Duration defaultTimeout;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  final StreamController<BleakBridgeEvent> _eventsController =
      StreamController<BleakBridgeEvent>.broadcast();
  final StreamController<GeoBlueFrame> _framesController =
      StreamController<GeoBlueFrame>.broadcast();

  final Map<String, Completer<Map<String, dynamic>>> _pending =
      <String, Completer<Map<String, dynamic>>>{};

  int _requestCounter = 0;

  BleakBridge({
    required this.pythonScriptPath,
    this.defaultTimeout = const Duration(seconds: 15),
  });

  Stream<BleakBridgeEvent> get events => _eventsController.stream;
  Stream<GeoBlueFrame> get frames => _framesController.stream;

  Future<void> start() async {
    if (_process != null) {
      return;
    }

    _process = await Process.start(
      'python3',
      <String>[pythonScriptPath],
      mode: ProcessStartMode.normal,
    );

    _stdoutSub = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStdoutLine);

    _stderrSub = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stderr.writeln('[bleak-bridge] $line');
    });

    final exitFuture = _process!.exitCode.then((code) {
      if (code != 0) {
        for (final completer in _pending.values) {
          if (!completer.isCompleted) {
            completer.completeError(
              StateError('bleak bridge exited with code $code'),
            );
          }
        }
      }
      _pending.clear();
    });

    unawaited(exitFuture);
  }

  Future<Map<String, dynamic>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) {
    return _command(
      'scan',
      <String, dynamic>{'timeout': timeout.inMilliseconds / 1000.0},
      timeout: timeout + const Duration(seconds: 5),
    );
  }

  Future<Map<String, dynamic>> connect(String address) {
    return _command(
      'connect',
      <String, dynamic>{'address': address},
      timeout: const Duration(seconds: 20),
    );
  }

  Future<Map<String, dynamic>> disconnect() {
    return _command('disconnect', const <String, dynamic>{});
  }

  Future<Map<String, dynamic>> sendFrame(GeoBlueFrame frame) {
    return _command(
      'send',
      <String, dynamic>{'frame': frame.toJson()},
      timeout: const Duration(seconds: 15),
    );
  }

  Future<Map<String, dynamic>> stop() {
    return _command('stop', const <String, dynamic>{}, timeout: const Duration(seconds: 3));
  }

  Future<void> dispose() async {
    try {
      await stop();
    } catch (_) {
      // best effort
    }

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();

    if (_process != null) {
      _process!.kill(ProcessSignal.sigterm);
      _process = null;
    }

    await _eventsController.close();
    await _framesController.close();
  }

  Future<Map<String, dynamic>> _command(
    String cmd,
    Map<String, dynamic> payload, {
    Duration? timeout,
  }) async {
    if (_process == null) {
      throw StateError('BleakBridge is not started');
    }

    final requestId = (++_requestCounter).toString();
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;

    final req = <String, dynamic>{
      'cmd': cmd,
      'request_id': requestId,
      ...payload,
    };

    _process!.stdin.writeln(jsonEncode(req));
    _process!.stdin.flush();

    final effectiveTimeout = timeout ?? defaultTimeout;
    try {
      return await completer.future.timeout(effectiveTimeout);
    } finally {
      _pending.remove(requestId);
    }
  }

  void _handleStdoutLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }

    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      json = decoded;
    } catch (_) {
      return;
    }

    final requestId = json['request_id']?.toString();
    final reply = json['reply_to']?.toString();
    if (requestId != null && reply != null) {
      final completer = _pending[requestId];
      if (completer != null && !completer.isCompleted) {
        final ok = json['ok'] == true;
        if (ok) {
          completer.complete(json);
        } else {
          completer.completeError(
            StateError(json['error']?.toString() ?? 'unknown bridge error'),
          );
        }
      }
      return;
    }

    final eventKind = json['event']?.toString();
    if (eventKind == null) {
      return;
    }

    if (eventKind == 'frame') {
      final rawFrame = json['frame'];
      if (rawFrame is Map<String, dynamic>) {
        try {
          _framesController.add(GeoBlueFrame.fromJson(rawFrame));
        } catch (_) {
          // ignore malformed frame
        }
      }
      return;
    }

    _eventsController.add(BleakBridgeEvent(eventKind, json));
  }
}
