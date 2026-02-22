/*
 * XRPC router for AT Protocol PDS.
 *
 * Routes /xrpc/{nsid} requests to handler functions.
 * Queries (GET) and procedures (POST) are registered separately.
 *
 * Reference: https://atproto.com/specs/xrpc
 */

import 'dart:convert';
import 'dart:io';

/// Handler for an XRPC endpoint.
///
/// Receives the HTTP request and parsed query parameters.
/// Must write the response body; the router handles content-type and closing.
typedef XrpcHandler = Future<void> Function(
  HttpRequest request,
  Map<String, String> params,
);

/// XRPC error response.
class XrpcError {
  final int statusCode;
  final String error;
  final String? message;

  XrpcError(this.statusCode, this.error, [this.message]);

  Map<String, dynamic> toJson() => {
    'error': error,
    if (message != null) 'message': message,
  };
}

/// Routes /xrpc/{nsid} requests to registered handlers.
class XrpcRouter {
  final Map<String, XrpcHandler> _queries = {};
  final Map<String, XrpcHandler> _procedures = {};

  /// Register a query (GET) handler for an NSID.
  void query(String nsid, XrpcHandler handler) {
    _queries[nsid] = handler;
  }

  /// Register a procedure (POST) handler for an NSID.
  void procedure(String nsid, XrpcHandler handler) {
    _procedures[nsid] = handler;
  }

  /// Handle an incoming HTTP request.
  ///
  /// [path] should be the full request path (e.g., `/xrpc/com.atproto.server.describeServer`).
  /// Returns true if the request was handled, false if the path is not an XRPC route.
  Future<bool> handle(HttpRequest request, String path) async {
    if (!path.startsWith('/xrpc/')) return false;

    final nsid = path.substring('/xrpc/'.length);
    if (nsid.isEmpty) {
      _writeError(request, XrpcError(400, 'InvalidRequest', 'Missing NSID'));
      return true;
    }

    final method = request.method;
    final params = request.uri.queryParameters;

    if (method == 'GET') {
      final handler = _queries[nsid];
      if (handler == null) {
        _writeError(request, XrpcError(501, 'MethodNotImplemented',
            'Query not found: $nsid'));
        return true;
      }
      try {
        await handler(request, params);
      } catch (e) {
        if (!request.response.headers.chunkedTransferEncoding) {
          _writeError(request, XrpcError(500, 'InternalServerError', '$e'));
        }
      }
      return true;
    }

    if (method == 'POST') {
      final handler = _procedures[nsid];
      if (handler == null) {
        _writeError(request, XrpcError(501, 'MethodNotImplemented',
            'Procedure not found: $nsid'));
        return true;
      }
      try {
        await handler(request, params);
      } catch (e) {
        if (!request.response.headers.chunkedTransferEncoding) {
          _writeError(request, XrpcError(500, 'InternalServerError', '$e'));
        }
      }
      return true;
    }

    _writeError(request, XrpcError(405, 'InvalidRequest',
        'XRPC only supports GET and POST'));
    return true;
  }

  /// Write a JSON error response.
  static void writeError(HttpRequest request, XrpcError error) {
    _writeError(request, error);
  }

  static void _writeError(HttpRequest request, XrpcError error) {
    request.response.statusCode = error.statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(error.toJson()));
  }

  /// Write a JSON success response.
  static void writeJson(HttpRequest request, Map<String, dynamic> data) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
  }

  /// Read JSON body from a POST request.
  static Future<Map<String, dynamic>> readJsonBody(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    if (body.isEmpty) return {};
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// Check if a request has a valid Bearer token.
  /// Returns the token string, or null if no valid Authorization header.
  static String? extractBearerToken(HttpRequest request) {
    final auth = request.headers.value('Authorization');
    if (auth == null) return null;
    if (!auth.startsWith('Bearer ')) return null;
    return auth.substring('Bearer '.length);
  }
}
