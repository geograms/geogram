/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared logic for DELETE /api/feedback/{contentType}/{id}/comment/{commentId}
 * — used by both PureStationServer (CLI) and StationServer (Desktop) so the
 * authorization rules stay in one place.
 */

import '../../services/event_service.dart';
import 'feedback_handler.dart';

class FeedbackDeleteHelper {
  FeedbackDeleteHelper._();

  /// Resolve the owner npub of the parent content. Used so the parent's
  /// author can delete any comment on their own content (visitors can
  /// only delete their own). Currently knows about events; returns null
  /// for content types where ownership isn't tracked here yet.
  static Future<String?> resolveOwnerNpub({
    required String contentType,
    required String contentId,
    required String? dataDir,
  }) async {
    if (dataDir == null) return null;
    if (contentType == 'event' || contentType == 'events') {
      try {
        final ev =
            await EventService().findEventByIdGlobal(contentId, dataDir);
        return ev?.npub;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Run the deleteComment flow end-to-end. Returns the same result map
  /// the rest of the feedback API uses (`{success, ...}` or
  /// `{error, http_status, ...}`), so callers just write the result back.
  static Future<Map<String, dynamic>> deleteComment({
    required FeedbackHandler feedbackApi,
    required String contentType,
    required String contentId,
    required String commentId,
    required String requesterNpub,
    required String? dataDir,
    String? callsign,
  }) async {
    final ownerNpub = await resolveOwnerNpub(
      contentType: contentType,
      contentId: contentId,
      dataDir: dataDir,
    );
    return feedbackApi.deleteComment(
      contentType: contentType,
      contentId: contentId,
      commentId: commentId,
      requesterNpub: requesterNpub,
      ownerNpub: ownerNpub,
      callsign: callsign,
    );
  }
}
