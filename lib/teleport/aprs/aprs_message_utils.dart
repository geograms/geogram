/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * APRS message utilities — constants, text splitting, and display merging.
 * Reusable across the APRS bridge (service, UI, debug API).
 */

import 'models/aprs_packet.dart';

/// Maximum characters in a single APRS message packet body.
const int aprsMaxMessageLen = 67;

/// Maximum comment length in an APRS position report (geo-chat).
const int aprsMaxCommentLen = 107;

/// Available body characters for a tag message (auto-prepends `#tag `).
int aprsAvailableChars(String? tag) {
  if (tag != null && tag.startsWith('#')) {
    return aprsMaxMessageLen - tag.length - 1; // "#tag" + space
  }
  return aprsMaxMessageLen;
}

/// Number of APRS parts needed for [text] at the given [maxChunkLen].
int aprsPartCount(String text, int maxChunkLen) {
  if (text.isEmpty || maxChunkLen <= 0) return 0;
  if (text.length <= maxChunkLen) return 1;
  return splitAprsText(text, maxChunkLen).length;
}

/// Split [text] into chunks of at most [maxLen] characters.
///
/// Splits at word boundaries (last space before limit) when possible;
/// hard-breaks mid-word only when a single word exceeds the limit.
///
/// Returns a single-element list if [text] already fits.
List<String> splitAprsText(String text, int maxLen) {
  if (text.length <= maxLen) return [text];

  final chunks = <String>[];
  var remaining = text;

  while (remaining.isNotEmpty) {
    if (remaining.length <= maxLen) {
      chunks.add(remaining);
      break;
    }

    // Try to find a space to split at (word boundary)
    var splitAt = remaining.lastIndexOf(' ', maxLen);
    if (splitAt <= 0) {
      // No space found — hard-break at maxLen
      splitAt = maxLen;
    }

    chunks.add(remaining.substring(0, splitAt).trimRight());
    remaining = remaining.substring(splitAt).trimLeft();
  }

  return chunks;
}

/// Merge consecutive messages from the same sender within [mergeWindow]
/// into single display packets. Returns a new list — the original is not
/// modified.
///
/// Messages are grouped when:
/// - Same `fromCallsign` (case-insensitive)
/// - Same direction (both incoming or both outgoing)
/// - Timestamps within [mergeWindow] of each other
/// - Both have non-null `messageText`
///
/// The merged packet uses the last part's timestamp and messageId, joins
/// text with newlines, and is only marked acked if ALL parts are acked.
List<AprsPacket> mergeConsecutiveMessages(
  List<AprsPacket> messages, {
  String? myCallsign,
  Duration mergeWindow = const Duration(seconds: 30),
}) {
  if (messages.length < 2) return List.of(messages);

  final myCall = myCallsign?.toUpperCase() ?? '';
  final result = <AprsPacket>[];
  var i = 0;

  while (i < messages.length) {
    final first = messages[i];
    final firstIsOut =
        first.isOutgoing || first.fromCallsign.toUpperCase() == myCall;

    // Collect consecutive mergeable messages
    final group = <AprsPacket>[first];
    var j = i + 1;

    while (j < messages.length) {
      final next = messages[j];
      final nextIsOut =
          next.isOutgoing || next.fromCallsign.toUpperCase() == myCall;

      if (next.messageText == null || first.messageText == null) break;
      if (next.fromCallsign.toUpperCase() != first.fromCallsign.toUpperCase()) {
        break;
      }
      if (nextIsOut != firstIsOut) break;
      if (next.timestamp.difference(group.last.timestamp).abs() >
          mergeWindow) {
        break;
      }

      group.add(next);
      j++;
    }

    if (group.length == 1) {
      result.add(first);
    } else {
      // Merge group into one display packet
      final last = group.last;
      final mergedText = group.map((p) => p.messageText ?? '').join('\n');
      final allAcked = group.every((p) => p.isAcked);

      result.add(last.copyWith(
        messageText: mergedText,
        timestamp: last.timestamp,
        messageId: last.messageId,
        isAcked: allAcked,
      ));
    }

    i = j;
  }

  return result;
}
