#!/usr/bin/env dart
// Standalone test: loads echo_lib.wasm, invokes functions, starts HTTP server.
// Usage: LD_LIBRARY_PATH=wasm_bridge/target/release dart run tool/test_wasm_library.dart

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

// --- FFI types (same as wasm_ffi.dart) ---
typedef _CreateNative = Pointer<Void> Function();
typedef _Create = Pointer<Void> Function();
typedef _SendNative = Void Function(Pointer<Void>, Pointer<Utf8>);
typedef _Send = void Function(Pointer<Void>, Pointer<Utf8>);
typedef _ReceiveNative = Pointer<Utf8> Function(Pointer<Void>, Double);
typedef _Receive = Pointer<Utf8> Function(Pointer<Void>, double);
typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _Destroy = void Function(Pointer<Void>);

late final DynamicLibrary _lib;
late final _Create _create;
late final _Send _send;
late final _Receive _recv;
late final _Destroy _destroy;

void _loadFfi() {
  _lib = DynamicLibrary.open('libwasm_bridge.so');
  _create = _lib.lookupFunction<_CreateNative, _Create>('wasm_json_client_create');
  _send = _lib.lookupFunction<_SendNative, _Send>('wasm_json_client_send');
  _recv = _lib.lookupFunction<_ReceiveNative, _Receive>('wasm_json_client_receive');
  _destroy = _lib.lookupFunction<_DestroyNative, _Destroy>('wasm_json_client_destroy');
}

// --- Minimal client ---
class _Bridge {
  final Pointer<Void> _client;
  int _reqId = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  late final ReceivePort _port;
  Isolate? _isolate;

  _Bridge(this._client);

  Future<void> startReceiveLoop() async {
    _port = ReceivePort();
    _port.listen((msg) {
      if (msg is! String) return;
      final json = jsonDecode(msg) as Map<String, dynamic>;
      final extra = json['@extra']?.toString();
      if (extra != null && _pending.containsKey(extra)) {
        _pending.remove(extra)!.complete(json);
      } else {
        final type = json['@type'];
        if (type == 'moduleLog') {
          print('  [log] ${json['message']}');
        }
      }
    });

    _isolate = await Isolate.spawn(_recvLoop, _RecvParams(
      clientAddr: _client.address,
      sendPort: _port.sendPort,
    ));
  }

  static void _recvLoop(_RecvParams p) {
    final lib = DynamicLibrary.open('libwasm_bridge.so');
    final recv = lib.lookupFunction<_ReceiveNative, _Receive>('wasm_json_client_receive');
    final client = Pointer<Void>.fromAddress(p.clientAddr);
    while (true) {
      final r = recv(client, 1.0);
      if (r != nullptr) {
        final s = r.toDartString();
        if (s.isNotEmpty) p.sendPort.send(s);
      }
    }
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> req) {
    final id = 'r_${++_reqId}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    final payload = {...req, '@extra': id};
    final s = jsonEncode(payload).toNativeUtf8();
    _send(_client, s);
    malloc.free(s);
    return c.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _pending.remove(id);
      return {'@type': 'error', 'message': 'timeout'};
    });
  }

  void close() {
    _isolate?.kill();
    _port.close();
    _destroy(_client);
  }
}

class _RecvParams {
  final int clientAddr;
  final SendPort sendPort;
  _RecvParams({required this.clientAddr, required this.sendPort});
}

// --- HTML rendering ---
String _css() => '''
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, sans-serif; background: #0e1621; color: #e0e0e0; line-height: 1.6; }
.container { max-width: 720px; margin: 0 auto; padding: 2rem 1rem; }
h1 { color: #fff; font-size: 1.8rem; display: inline; }
h2 { color: #8ab4d8; font-size: 1.1rem; margin: 1.5rem 0 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; }
.badge { display: inline-block; margin-left: 0.5rem; padding: 0.15rem 0.5rem; background: #2B5278; color: #fff; border-radius: 4px; font-size: 0.8rem; vertical-align: middle; }
.subtitle { color: #8899a6; margin-top: 0.5rem; }
.breadcrumb { margin-bottom: 0.5rem; }
.breadcrumb a { color: #5b9bd5; text-decoration: none; }
.card { background: #1e2d3d; border-radius: 8px; padding: 1rem 1.25rem; margin-bottom: 0.75rem; border-left: 3px solid #2B5278; }
.card h3 a { color: #5b9bd5; text-decoration: none; }
.card p { color: #b0bec5; font-size: 0.95rem; }
.meta { color: #607d8b; font-size: 0.85rem; margin-top: 0.5rem; }
table { width: 100%; border-collapse: collapse; margin-bottom: 1rem; }
th, td { padding: 0.5rem 0.75rem; text-align: left; border-bottom: 1px solid #263238; }
th { color: #8ab4d8; font-size: 0.85rem; text-transform: uppercase; }
code { font-family: monospace; font-size: 0.9em; color: #80cbc4; }
pre { background: #1a2332; padding: 1rem; border-radius: 6px; overflow-x: auto; font-size: 0.85rem; }
pre code { color: #b0bec5; }
footer { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid #263238; }
footer a { color: #5b9bd5; text-decoration: none; font-size: 0.9rem; }
a { color: #5b9bd5; }
''';

String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

// --- Main ---
Future<void> main() async {
  _loadFfi();
  print('=== WASM Library Test ===\n');

  final client = _create();
  final bridge = _Bridge(client);
  await bridge.startReceiveLoop();

  // Give isolate time to spin up
  await Future.delayed(const Duration(milliseconds: 200));

  // Load the echo_lib
  final wasmPath = '${Directory.current.path}/wapps/modules/echo_lib/echo_lib.wasm';
  print('Loading $wasmPath ...');
  final loadResult = await bridge.request({
    '@type': 'loadModule',
    'path': wasmPath,
  });
  print('Load result: ${const JsonEncoder.withIndent("  ").convert(loadResult)}\n');

  if (loadResult['@type'] == 'error') {
    print('FAILED to load module');
    bridge.close();
    exit(1);
  }

  final moduleId = loadResult['id'] as String;
  final kind = loadResult['kind'] ?? 'unknown';
  print('Module "$moduleId" loaded as $kind\n');

  // Get schema
  print('--- Schema ---');
  final schemaResult = await bridge.request({
    '@type': 'getSchema',
    'libraryId': moduleId,
  });
  final schema = schemaResult['schema'] as Map<String, dynamic>? ?? {};
  print(const JsonEncoder.withIndent('  ').convert(schema));
  print('');

  // Invoke echo
  print('--- Invoke echo("hello world") ---');
  final echoResult = await bridge.request({
    '@type': 'invokeFunction',
    'libraryId': moduleId,
    'function': 'echo',
    'args': {'text': 'hello world'},
  });
  print('Result: ${jsonEncode(echoResult['result'])}\n');

  // Invoke upcase
  print('--- Invoke upcase("hello world") ---');
  final upcaseResult = await bridge.request({
    '@type': 'invokeFunction',
    'libraryId': moduleId,
    'function': 'upcase',
    'args': {'text': 'hello world'},
  });
  print('Result: ${jsonEncode(upcaseResult['result'])}\n');

  // Start HTTP server
  const port = 8181;
  print('--- Starting HTTP server on port $port ---\n');

  final functions = schema['functions'] as List<dynamic>? ?? [];

  FutureOr<shelf.Response> handler(shelf.Request request) async {
    final path = request.url.path;

    if (request.method == 'GET' && path == 'api/schema') {
      return shelf.Response.ok(
        const JsonEncoder.withIndent('  ').convert(schema),
        headers: {'content-type': 'application/json'},
      );
    }

    if (request.method == 'GET' && (path == 'api' || path == 'api/')) {
      final cards = StringBuffer();
      for (final fn in functions) {
        final name = fn['name'] ?? '';
        final desc = fn['description'] ?? '';
        final params = fn['params'] as Map<String, dynamic>? ?? {};
        final paramList = params.keys.map((k) => '<code>${_esc(k)}</code>').join(', ');
        cards.writeln('''
        <div class="card">
          <h3><a href="/api/$name">$name</a></h3>
          <p>${_esc(desc)}</p>
          <div class="meta">
            ${paramList.isNotEmpty ? 'Params: $paramList' : 'No parameters'}
            &middot; <code>POST /api/$name</code>
          </div>
        </div>''');
      }
      final id = schema['id'] ?? moduleId;
      final version = schema['version'] ?? '';
      return shelf.Response.ok('''<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_esc(id)} API</title><style>${_css()}</style></head>
<body><div class="container">
<header><h1>${_esc(id)}</h1>${version != '' ? '<span class="badge">v$version</span>' : ''}
<p class="subtitle">${_esc(schema['description'] ?? '')}</p></header>
<section><h2>Functions</h2>$cards</section>
<footer><a href="/api/schema">Raw JSON Schema</a></footer>
</div></body></html>''', headers: {'content-type': 'text/html'});
    }

    if (path.startsWith('api/') && path.length > 4) {
      final fnName = path.substring(4);
      final fn = functions.cast<Map<String, dynamic>?>().firstWhere(
        (f) => f?['name'] == fnName,
        orElse: () => null,
      );

      if (fn == null) {
        return shelf.Response.notFound('Function "$fnName" not found');
      }

      if (request.method == 'GET') {
        final params = fn['params'] as Map<String, dynamic>? ?? {};
        final returns = fn['returns'] as Map<String, dynamic>? ?? {};
        final paramsRows = StringBuffer();
        final curlParams = <String, String>{};
        for (final e in params.entries) {
          final p = e.value as Map<String, dynamic>? ?? {};
          paramsRows.writeln('<tr><td><code>${_esc(e.key)}</code></td><td><code>${p['type'] ?? 'any'}</code></td><td>${_esc(p['description'] ?? '')}</td></tr>');
          curlParams[e.key] = p['type'] == 'string' ? 'value' : '0';
        }
        final returnsRows = StringBuffer();
        for (final e in returns.entries) {
          final r = e.value as Map<String, dynamic>? ?? {};
          returnsRows.writeln('<tr><td><code>${_esc(e.key)}</code></td><td><code>${r['type'] ?? 'any'}</code></td><td>${_esc(r['description'] ?? '')}</td></tr>');
        }
        final curl = "curl -X POST http://localhost:$port/api/$fnName \\\n  -H 'Content-Type: application/json' \\\n  -d '${jsonEncode(curlParams)}'";
        return shelf.Response.ok('''<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_esc(fnName)} — ${_esc(schema['id'] ?? moduleId)}</title><style>${_css()}</style></head>
<body><div class="container">
<header><p class="breadcrumb"><a href="/api">&larr; All Functions</a></p>
<h1>${_esc(fnName)}</h1>
<p class="subtitle">${_esc(fn['description'] ?? '')}</p></header>
<section><h2>Parameters</h2>
${params.isEmpty ? '<p>No parameters</p>' : '<table><thead><tr><th>Name</th><th>Type</th><th>Description</th></tr></thead><tbody>$paramsRows</tbody></table>'}
</section>
<section><h2>Returns</h2>
${returns.isEmpty ? '<p>No return value</p>' : '<table><thead><tr><th>Name</th><th>Type</th><th>Description</th></tr></thead><tbody>$returnsRows</tbody></table>'}
</section>
<section><h2>Example</h2><pre><code>${_esc(curl)}</code></pre></section>
</div></body></html>''', headers: {'content-type': 'text/html'});
      }

      if (request.method == 'POST') {
        String body;
        try { body = await request.readAsString(); } catch (_) { body = '{}'; }
        dynamic args;
        try { args = jsonDecode(body); } catch (_) {
          return shelf.Response(400, body: '{"error":"Invalid JSON"}', headers: {'content-type': 'application/json'});
        }
        final result = await bridge.request({
          '@type': 'invokeFunction',
          'libraryId': moduleId,
          'function': fnName,
          'args': args,
        });
        if (result['@type'] == 'error') {
          return shelf.Response(500, body: jsonEncode({'error': result['message']}), headers: {'content-type': 'application/json'});
        }
        return shelf.Response.ok(jsonEncode(result['result']), headers: {'content-type': 'application/json'});
      }
    }

    return shelf.Response.notFound('Not found');
  }

  await shelf_io.serve(handler, InternetAddress.loopbackIPv4, port);
  print('HTTP server running at http://localhost:$port/api');
  print('Press Ctrl+C to stop.\n');

  // Keep running
  await Completer<void>().future;
}
