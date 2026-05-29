/// Worker isolate that streams an update download to disk.
///
/// Lives in its own isolate so the byte pump survives:
///   * desktop window minimize (the Flutter embedder throttles the main
///     isolate when the window is hidden, which freezes the download loop),
///   * Android backgrounding (the main UI isolate is suspended; the
///     foreground service keeps the process alive, and a worker isolate
///     keeps ticking inside it).
///
/// The main isolate orchestrates: resolves paths, runs the HEAD probe,
/// spawns this isolate, forwards progress to the foreground-service
/// notification, and runs APK integrity verification on completion.
///
/// Wire format (`Map<String, dynamic>` over SendPort):
///   { 'type': 'ready',     'cancelPort': SendPort }
///   { 'type': 'progress',  'downloaded': int, 'total': int }
///   { 'type': 'completed', 'path': String, 'bytes': int }
///   { 'type': 'failed',    'error': String, 'cancelled': bool }
///
/// Cancel by sending `'cancel'` on `cancelPort`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_client;

/// Args bundle for [downloadIsolateEntry]. Must be primitive / SendPort only.
class DownloadIsolateArgs {
  final SendPort sendPort;
  final String url;
  final String partialPath;
  final String finalPath;
  final int existingBytes;
  final bool supportsResume;
  final int knownContentLength;
  final String userAgent;

  const DownloadIsolateArgs({
    required this.sendPort,
    required this.url,
    required this.partialPath,
    required this.finalPath,
    required this.existingBytes,
    required this.supportsResume,
    required this.knownContentLength,
    required this.userAgent,
  });
}

/// Top-level isolate entry point. Spawn with [Isolate.spawn].
Future<void> downloadIsolateEntry(DownloadIsolateArgs args) async {
  final cancelPort = ReceivePort();
  args.sendPort.send({
    'type': 'ready',
    'cancelPort': cancelPort.sendPort,
  });

  var cancelled = false;
  final cancelSub = cancelPort.listen((msg) {
    if (msg == 'cancel') cancelled = true;
  });

  HttpClient? rawClient;
  io_client.IOClient? client;
  IOSink? sink;
  StreamSubscription<List<int>>? chunkSub;

  try {
    final partialFile = File(args.partialPath);

    // Decide resume vs fresh.
    var startByte = 0;
    if (args.supportsResume && args.existingBytes > 0) {
      startByte = args.existingBytes;
    } else if (args.existingBytes > 0) {
      // Server does not support resume — discard the partial.
      try {
        await partialFile.delete();
      } catch (_) {}
    }

    final request = http.Request('GET', Uri.parse(args.url));
    request.headers['User-Agent'] = args.userAgent;
    if (startByte > 0) {
      request.headers['Range'] = 'bytes=$startByte-';
    }

    rawClient = HttpClient();
    rawClient.connectionTimeout = const Duration(seconds: 30);
    client = io_client.IOClient(rawClient);

    final response = await client.send(request);
    if (response.statusCode != 200 && response.statusCode != 206) {
      args.sendPort.send({
        'type': 'failed',
        'error': 'HTTP ${response.statusCode}',
        'cancelled': false,
      });
      return;
    }

    final expectedLength =
        response.contentLength ?? (args.knownContentLength - startByte);
    final totalSize = startByte + expectedLength;

    sink = partialFile.openWrite(
        mode: startByte > 0 ? FileMode.append : FileMode.write);

    var downloaded = startByte;
    var lastEvent = DateTime.now().subtract(const Duration(seconds: 1));

    final completer = Completer<void>();
    chunkSub = response.stream.listen(
      (chunk) {
        if (cancelled) return;
        sink!.add(chunk);
        downloaded += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastEvent).inMilliseconds >= 100) {
          args.sendPort.send({
            'type': 'progress',
            'downloaded': downloaded,
            'total': totalSize,
          });
          lastEvent = now;
        }
      },
      onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );

    await completer.future;

    await sink.flush();
    await sink.close();
    sink = null;

    if (cancelled) {
      args.sendPort.send({
        'type': 'failed',
        'error': 'cancelled',
        'cancelled': true,
      });
      return;
    }

    // Final byte-count check — server cut the stream short.
    if (totalSize > 0 && downloaded < totalSize) {
      args.sendPort.send({
        'type': 'failed',
        'error':
            'short read: $downloaded of $totalSize bytes (partial preserved at ${args.partialPath})',
        'cancelled': false,
      });
      return;
    }

    await partialFile.rename(args.finalPath);
    args.sendPort.send({
      'type': 'completed',
      'path': args.finalPath,
      'bytes': downloaded,
    });
  } catch (e) {
    args.sendPort.send({
      'type': 'failed',
      'error': '$e',
      'cancelled': cancelled,
    });
  } finally {
    try {
      await chunkSub?.cancel();
    } catch (_) {}
    try {
      await sink?.close();
    } catch (_) {}
    try {
      client?.close();
    } catch (_) {}
    try {
      rawClient?.close(force: true);
    } catch (_) {}
    await cancelSub.cancel();
    cancelPort.close();
  }
}
