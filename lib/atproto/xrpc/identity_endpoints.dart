/*
 * AT Protocol identity XRPC endpoints.
 *
 * Implements:
 * - com.atproto.identity.resolveHandle (GET)
 *
 * Reference: https://docs.bsky.app/docs/api/com-atproto-identity
 */

import '../did_service.dart';
import '../xrpc_router.dart';

/// Register identity XRPC endpoints on the router.
void registerIdentityEndpoints(
  XrpcRouter router, {
  required DidService didService,
}) {
  // GET com.atproto.identity.resolveHandle
  router.query('com.atproto.identity.resolveHandle',
      (request, params) async {
    final handle = params['handle'];
    if (handle == null || handle.isEmpty) {
      XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
          'handle parameter is required'));
      return;
    }

    // Single-user PDS: only resolve our own handle
    if (handle == didService.handle) {
      XrpcRouter.writeJson(request, {
        'did': didService.did,
      });
      return;
    }

    XrpcRouter.writeError(request, XrpcError(400, 'InvalidRequest',
        'Unable to resolve handle'));
  });
}
