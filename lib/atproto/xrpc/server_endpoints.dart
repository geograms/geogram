/*
 * AT Protocol server XRPC endpoints.
 *
 * Implements:
 * - com.atproto.server.describeServer (GET)
 * - com.atproto.server.createSession (POST)
 * - com.atproto.server.refreshSession (POST)
 * - com.atproto.server.deleteSession (POST)
 * - com.atproto.server.getSession (GET)
 *
 * Reference: https://docs.bsky.app/docs/api/com-atproto-server
 */

import '../did_service.dart';
import '../jwt_service.dart';
import '../xrpc_router.dart';

/// Register server XRPC endpoints on the router.
void registerServerEndpoints(
  XrpcRouter router, {
  required DidService didService,
  required JwtService jwtService,
  required String Function() getAdminPassword,
}) {
  // GET com.atproto.server.describeServer
  router.query('com.atproto.server.describeServer', (request, params) async {
    XrpcRouter.writeJson(request, {
      'did': didService.did,
      'availableUserDomains': <String>[],
      'inviteCodeRequired': false,
      'links': <String, dynamic>{},
    });
  });

  // POST com.atproto.server.createSession
  router.procedure('com.atproto.server.createSession', (request, params) async {
    final body = await XrpcRouter.readJsonBody(request);
    final identifier = body['identifier'] as String?;
    final password = body['password'] as String?;

    if (identifier == null || password == null) {
      XrpcRouter.writeError(
        request,
        XrpcError(
          400,
          'InvalidRequest',
          'identifier and password are required',
        ),
      );
      return;
    }

    // Validate password; identifier is accepted as a user-facing alias.
    if (password != getAdminPassword()) {
      XrpcRouter.writeError(
        request,
        XrpcError(401, 'AuthenticationRequired', 'Invalid password'),
      );
      return;
    }

    final tokens = jwtService.createSession();
    XrpcRouter.writeJson(request, tokens.toJson());
  });

  // POST com.atproto.server.refreshSession
  router.procedure('com.atproto.server.refreshSession', (
    request,
    params,
  ) async {
    final token = XrpcRouter.extractBearerToken(request);
    if (token == null) {
      XrpcRouter.writeError(
        request,
        XrpcError(401, 'AuthenticationRequired', 'Missing refresh token'),
      );
      return;
    }

    final tokens = jwtService.refreshSession(token);
    if (tokens == null) {
      XrpcRouter.writeError(
        request,
        XrpcError(
          401,
          'AuthenticationRequired',
          'Invalid or expired refresh token',
        ),
      );
      return;
    }

    XrpcRouter.writeJson(request, tokens.toJson());
  });

  // POST com.atproto.server.deleteSession
  router.procedure('com.atproto.server.deleteSession', (request, params) async {
    final token = XrpcRouter.extractBearerToken(request);
    if (token == null) {
      XrpcRouter.writeError(
        request,
        XrpcError(401, 'AuthenticationRequired', 'Missing refresh token'),
      );
      return;
    }

    jwtService.deleteSession(token);
    request.response.statusCode = 200;
  });

  // GET com.atproto.server.getSession
  router.query('com.atproto.server.getSession', (request, params) async {
    final token = XrpcRouter.extractBearerToken(request);
    if (token == null) {
      XrpcRouter.writeError(
        request,
        XrpcError(401, 'AuthenticationRequired', 'Missing access token'),
      );
      return;
    }

    final did = jwtService.verifyAccessToken(token);
    if (did == null) {
      XrpcRouter.writeError(
        request,
        XrpcError(
          401,
          'AuthenticationRequired',
          'Invalid or expired access token',
        ),
      );
      return;
    }

    XrpcRouter.writeJson(request, {'did': did, 'handle': didService.handle});
  });
}
