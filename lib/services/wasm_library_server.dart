/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * HTTP server for WASM library modules — exposes library functions
 * as a browsable API with HTML documentation and JSON invocation.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'log_service.dart';
import 'wasm_module_service.dart';

/// HTTP server that serves a WASM library's API.
///
/// Routes:
///   GET  /api           — HTML index page listing all functions
///   GET  /api/`<name>`  — HTML detail page for one function
///   POST /api/`<name>`  — invoke function with JSON body, return JSON result
///   GET  /api/schema    — raw JSON schema
class WasmLibraryServer {
  final String libraryId;
  final int port;

  HttpServer? _server;
  Map<String, dynamic>? _schema;

  WasmLibraryServer({required this.libraryId, required this.port});

  bool get isRunning => _server != null;

  /// Start the HTTP server.
  Future<void> start() async {
    // Fetch and cache schema
    final result = await WasmModuleService().getLibrarySchema(libraryId);
    if (result['@type'] == 'error') {
      throw StateError('Failed to get schema for $libraryId: ${result['message']}');
    }
    _schema = result['schema'] as Map<String, dynamic>?;

    final handler = const shelf.Pipeline()
        .addMiddleware(shelf.logRequests(logger: (msg, isError) {
          if (isError) {
            LogService().error('WasmLibraryServer[$libraryId]: $msg');
          }
        }))
        .addHandler(_router);

    _server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, port);
    LogService().log('WasmLibraryServer[$libraryId]: serving on http://localhost:$port/api');
  }

  /// Stop the HTTP server.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    LogService().log('WasmLibraryServer[$libraryId]: stopped');
  }

  FutureOr<shelf.Response> _router(shelf.Request request) {
    final path = request.url.path;

    // GET /api/schema
    if (request.method == 'GET' && path == 'api/schema') {
      return _handleSchema();
    }

    // GET /api — index page
    if (request.method == 'GET' && path == 'api') {
      return _handleIndex();
    }

    // GET /api/<fn> — detail page
    if (request.method == 'GET' && path.startsWith('api/')) {
      final fnName = path.substring(4);
      if (fnName.isNotEmpty) {
        return _handleFunctionDetail(fnName);
      }
    }

    // POST /api/<fn> — invoke
    if (request.method == 'POST' && path.startsWith('api/')) {
      final fnName = path.substring(4);
      if (fnName.isNotEmpty) {
        return _handleInvoke(request, fnName);
      }
    }

    return shelf.Response.notFound('Not found');
  }

  shelf.Response _handleSchema() {
    return shelf.Response.ok(
      const JsonEncoder.withIndent('  ').convert(_schema ?? {}),
      headers: {'content-type': 'application/json'},
    );
  }

  shelf.Response _handleIndex() {
    final schema = _schema ?? {};
    final id = schema['id'] as String? ?? libraryId;
    final version = schema['version'] as String? ?? '';
    final description = schema['description'] as String? ?? '';
    final functions = schema['functions'] as List<dynamic>? ?? [];

    final functionCards = StringBuffer();
    for (final fn in functions) {
      final name = fn['name'] as String? ?? '';
      final desc = fn['description'] as String? ?? '';
      final params = fn['params'] as Map<String, dynamic>? ?? {};

      final paramList = params.entries
          .map((e) => '<code>${_esc(e.key)}</code>')
          .join(', ');

      functionCards.writeln('''
      <div class="card">
        <h3><a href="/api/$name">$name</a></h3>
        <p>$desc</p>
        <div class="meta">
          ${paramList.isNotEmpty ? 'Params: $paramList' : 'No parameters'}
          &middot;
          <code>POST /api/$name</code>
        </div>
      </div>''');
    }

    final html = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_esc(id)} API</title>
<style>
${_css()}
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>${_esc(id)}</h1>
    ${version.isNotEmpty ? '<span class="badge">v$version</span>' : ''}
    <p class="subtitle">${_esc(description)}</p>
  </header>
  <section>
    <h2>Functions</h2>
    $functionCards
  </section>
  <footer>
    <a href="/api/schema">Raw JSON Schema</a>
  </footer>
</div>
</body>
</html>''';

    return shelf.Response.ok(html, headers: {'content-type': 'text/html'});
  }

  shelf.Response _handleFunctionDetail(String fnName) {
    final schema = _schema ?? {};
    final functions = schema['functions'] as List<dynamic>? ?? [];

    final fn = functions.cast<Map<String, dynamic>?>().firstWhere(
      (f) => f?['name'] == fnName,
      orElse: () => null,
    );

    if (fn == null) {
      return shelf.Response.notFound('Function "$fnName" not found');
    }

    final desc = fn['description'] as String? ?? '';
    final params = fn['params'] as Map<String, dynamic>? ?? {};
    final returns = fn['returns'] as Map<String, dynamic>? ?? {};

    final paramsRows = StringBuffer();
    final curlParams = <String, String>{};
    for (final entry in params.entries) {
      final p = entry.value as Map<String, dynamic>? ?? {};
      final type = p['type'] as String? ?? 'any';
      final pdesc = p['description'] as String? ?? '';
      paramsRows.writeln('''
        <tr>
          <td><code>${_esc(entry.key)}</code></td>
          <td><code>$type</code></td>
          <td>${_esc(pdesc)}</td>
        </tr>''');
      curlParams[entry.key] = type == 'string' ? 'value' : '0';
    }

    final returnsRows = StringBuffer();
    for (final entry in returns.entries) {
      final r = entry.value as Map<String, dynamic>? ?? {};
      final type = r['type'] as String? ?? 'any';
      final rdesc = r['description'] as String? ?? '';
      returnsRows.writeln('''
        <tr>
          <td><code>${_esc(entry.key)}</code></td>
          <td><code>$type</code></td>
          <td>${_esc(rdesc)}</td>
        </tr>''');
    }

    final curlBody = jsonEncode(curlParams);
    final curlExample =
        "curl -X POST http://localhost:$port/api/$fnName \\\n"
        "  -H 'Content-Type: application/json' \\\n"
        "  -d '$curlBody'";

    final html = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_esc(fnName)} — ${_esc(schema['id'] as String? ?? libraryId)}</title>
<style>
${_css()}
</style>
</head>
<body>
<div class="container">
  <header>
    <p class="breadcrumb"><a href="/api">&larr; All Functions</a></p>
    <h1>${_esc(fnName)}</h1>
    <p class="subtitle">${_esc(desc)}</p>
  </header>
  <section>
    <h2>Parameters</h2>
    ${params.isEmpty ? '<p>No parameters</p>' : '''
    <table>
      <thead><tr><th>Name</th><th>Type</th><th>Description</th></tr></thead>
      <tbody>$paramsRows</tbody>
    </table>'''}
  </section>
  <section>
    <h2>Returns</h2>
    ${returns.isEmpty ? '<p>No return value</p>' : '''
    <table>
      <thead><tr><th>Name</th><th>Type</th><th>Description</th></tr></thead>
      <tbody>$returnsRows</tbody>
    </table>'''}
  </section>
  <section>
    <h2>Example</h2>
    <pre><code>${_esc(curlExample)}</code></pre>
  </section>
</div>
</body>
</html>''';

    return shelf.Response.ok(html, headers: {'content-type': 'text/html'});
  }

  Future<shelf.Response> _handleInvoke(shelf.Request request, String fnName) async {
    String body;
    try {
      body = await request.readAsString();
    } catch (_) {
      body = '{}';
    }

    dynamic args;
    try {
      args = jsonDecode(body);
    } catch (_) {
      return shelf.Response(
        400,
        body: jsonEncode({'error': 'Invalid JSON body'}),
        headers: {'content-type': 'application/json'},
      );
    }

    try {
      final result = await WasmModuleService().invokeLibraryFunction(
        libraryId,
        fnName,
        args,
      );

      if (result['@type'] == 'error') {
        return shelf.Response(
          500,
          body: jsonEncode({'error': result['message'] ?? 'invoke failed'}),
          headers: {'content-type': 'application/json'},
        );
      }

      return shelf.Response.ok(
        jsonEncode(result['result'] ?? {}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  static String _esc(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  static String _css() {
    return '''
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: #0e1621;
  color: #e0e0e0;
  line-height: 1.6;
}
.container { max-width: 720px; margin: 0 auto; padding: 2rem 1rem; }
header { margin-bottom: 2rem; }
h1 { color: #fff; font-size: 1.8rem; display: inline; }
h2 { color: #8ab4d8; font-size: 1.1rem; margin: 1.5rem 0 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; }
.badge {
  display: inline-block; margin-left: 0.5rem; padding: 0.15rem 0.5rem;
  background: #2B5278; color: #fff; border-radius: 4px; font-size: 0.8rem;
  vertical-align: middle;
}
.subtitle { color: #8899a6; margin-top: 0.5rem; }
.breadcrumb { margin-bottom: 0.5rem; }
.breadcrumb a { color: #5b9bd5; text-decoration: none; }
.breadcrumb a:hover { text-decoration: underline; }
.card {
  background: #1e2d3d; border-radius: 8px; padding: 1rem 1.25rem;
  margin-bottom: 0.75rem; border-left: 3px solid #2B5278;
}
.card h3 { margin-bottom: 0.25rem; }
.card h3 a { color: #5b9bd5; text-decoration: none; }
.card h3 a:hover { text-decoration: underline; }
.card p { color: #b0bec5; font-size: 0.95rem; }
.meta { color: #607d8b; font-size: 0.85rem; margin-top: 0.5rem; }
table { width: 100%; border-collapse: collapse; margin-bottom: 1rem; }
th, td { padding: 0.5rem 0.75rem; text-align: left; border-bottom: 1px solid #263238; }
th { color: #8ab4d8; font-size: 0.85rem; text-transform: uppercase; }
code { font-family: 'SF Mono', 'Fira Code', monospace; font-size: 0.9em; color: #80cbc4; }
pre {
  background: #1a2332; padding: 1rem; border-radius: 6px;
  overflow-x: auto; font-size: 0.85rem;
}
pre code { color: #b0bec5; }
footer { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid #263238; }
footer a { color: #5b9bd5; text-decoration: none; font-size: 0.9rem; }
footer a:hover { text-decoration: underline; }
a { color: #5b9bd5; }
''';
  }
}
