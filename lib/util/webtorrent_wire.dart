/// Pure-Dart helpers for the WebTorrent tracker WSS wire protocol.
///
/// Trackers speak a JSON-over-WebSocket dialect. We piggy-back on it for
/// signaling: the info_hash is a per-peer-pair rendezvous key, our actual
/// WebRTCSignal envelope is JSON-encoded into the `sdp` string field of
/// the standard offer/answer message. The tracker doesn't parse the SDP
/// so any string content works.
///
/// Runs from CLI — no Flutter imports.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Returns the per-pair rendezvous info_hash. Both peers derive the
/// same value as long as both npubs are known. Stable for the lifetime
/// of the contact pair — trackers are stateless message relays so
/// nothing is gained from time-bucketing the hash.
Uint8List sessionInfoHash({
  required String npubA,
  required String npubB,
}) {
  final lo = npubA.compareTo(npubB) <= 0 ? npubA : npubB;
  final hi = npubA.compareTo(npubB) <= 0 ? npubB : npubA;
  final input = utf8.encode('geogram-signaling-v1:$lo|$hi');
  return Uint8List.fromList(sha1.convert(input).bytes);
}

/// 20-byte random peer_id. Convention: 8 chars of "-XX0000-" + 12
/// random bytes. We mimic the WebTorrent client signature (-WW…) so
/// trackers that filter on known client prefixes accept us.
Uint8List newPeerId() {
  final r = Random.secure();
  final id = Uint8List(20);
  const prefix = '-WW0102-';
  for (var i = 0; i < prefix.length; i++) {
    id[i] = prefix.codeUnitAt(i);
  }
  for (var i = prefix.length; i < 20; i++) {
    id[i] = r.nextInt(256);
  }
  return id;
}

/// 20-byte random offer_id used to correlate offer→answer pairs across
/// the tracker.
Uint8List newOfferId() {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(20, (_) => r.nextInt(256)));
}

/// WebTorrent's binary fields (info_hash, peer_id, offer_id) ride inside
/// JSON as Latin-1 strings (one byte per char). Encoder.
String binaryToLatin1(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.writeCharCode(b);
  }
  return sb.toString();
}

/// Inverse of [binaryToLatin1].
Uint8List latin1ToBinary(String s) {
  final out = Uint8List(s.length);
  for (var i = 0; i < s.length; i++) {
    out[i] = s.codeUnitAt(i) & 0xff;
  }
  return out;
}

String hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Build an `announce` message that pre-stages a single SDP offer for
/// any peer that joins this info_hash. Used to send our offer to a
/// specific known peer (any tracker-side delivery will reach them as
/// long as they're announced on the same info_hash).
Map<String, dynamic> buildOfferAnnounce({
  required Uint8List infoHash,
  required Uint8List peerId,
  required Uint8List offerId,
  required String innerPayloadJson,
}) {
  return {
    'action': 'announce',
    'info_hash': binaryToLatin1(infoHash),
    'peer_id': binaryToLatin1(peerId),
    'numwant': 10,
    'uploaded': 0,
    'downloaded': 0,
    // left>0 marks us as a leecher. Some trackers refuse to match
    // seeds with seeds (left=0), so non-zero gets us into the
    // delivery set for offers between any pair of peers.
    'left': 1,
    'event': 'started',
    'offers': [
      {
        'offer_id': binaryToLatin1(offerId),
        'offer': {
          'type': 'offer',
          'sdp': innerPayloadJson,
        },
      },
    ],
  };
}

/// Build an `announce` reply carrying our answer to a specific peer's
/// offer. Sent in response to a tracker-delivered offer.
Map<String, dynamic> buildAnswerAnnounce({
  required Uint8List infoHash,
  required Uint8List peerId,
  required Uint8List toPeerId,
  required Uint8List offerId,
  required String innerPayloadJson,
}) {
  return {
    'action': 'announce',
    'info_hash': binaryToLatin1(infoHash),
    'peer_id': binaryToLatin1(peerId),
    'to_peer_id': binaryToLatin1(toPeerId),
    'offer_id': binaryToLatin1(offerId),
    'answer': {
      'type': 'answer',
      'sdp': innerPayloadJson,
    },
  };
}

/// Build a heartbeat announce with no offers — keeps the tracker
/// session warm and any new peers' offers flowing toward us.
/// Includes `event: 'started'` since some public WebTorrent trackers
/// only place a peer in the deliverable swarm after a started-event
/// announce.
Map<String, dynamic> buildKeepaliveAnnounce({
  required Uint8List infoHash,
  required Uint8List peerId,
}) {
  return {
    'action': 'announce',
    'info_hash': binaryToLatin1(infoHash),
    'peer_id': binaryToLatin1(peerId),
    'numwant': 10,
    'uploaded': 0,
    'downloaded': 0,
    // left>0 marks us as a leecher. Some trackers refuse to match
    // seeds with seeds (left=0), so non-zero gets us into the
    // delivery set for offers between any pair of peers.
    'left': 1,
    'event': 'started',
  };
}

/// Decoded inbound message types we react to. Trackers also send
/// `interval`, `complete`, `incomplete`, etc. — we ignore those.
enum WebTorrentInboundKind { offerForUs, answerForUs, ignored }

class WebTorrentInbound {
  final WebTorrentInboundKind kind;
  final Uint8List? infoHash;
  final Uint8List? fromPeerId;
  final Uint8List? offerId;
  final String? innerPayloadJson;
  final String? raw;
  WebTorrentInbound._(this.kind,
      {this.infoHash,
      this.fromPeerId,
      this.offerId,
      this.innerPayloadJson,
      this.raw});

  factory WebTorrentInbound.ignored(String raw) =>
      WebTorrentInbound._(WebTorrentInboundKind.ignored, raw: raw);
}

/// Parse a tracker→client message. Accepts a JSON string or pre-decoded
/// map. Returns ignored for shapes we don't care about.
WebTorrentInbound parseTrackerMessage(dynamic msg) {
  Map<String, dynamic>? m;
  if (msg is String) {
    try {
      final v = jsonDecode(msg);
      if (v is Map<String, dynamic>) m = v;
    } catch (_) {
      return WebTorrentInbound.ignored(msg);
    }
  } else if (msg is Map<String, dynamic>) {
    m = msg;
  }
  if (m == null) return WebTorrentInbound.ignored(msg.toString());

  final ihStr = m['info_hash'];
  final fromStr = m['peer_id'];
  final infoHash = ihStr is String ? latin1ToBinary(ihStr) : null;
  final fromPeerId = fromStr is String ? latin1ToBinary(fromStr) : null;

  final offer = m['offer'];
  if (offer is Map && offer['sdp'] is String) {
    final offerIdStr = m['offer_id'];
    return WebTorrentInbound._(
      WebTorrentInboundKind.offerForUs,
      infoHash: infoHash,
      fromPeerId: fromPeerId,
      offerId: offerIdStr is String ? latin1ToBinary(offerIdStr) : null,
      innerPayloadJson: offer['sdp'] as String,
    );
  }

  final answer = m['answer'];
  if (answer is Map && answer['sdp'] is String) {
    final offerIdStr = m['offer_id'];
    return WebTorrentInbound._(
      WebTorrentInboundKind.answerForUs,
      infoHash: infoHash,
      fromPeerId: fromPeerId,
      offerId: offerIdStr is String ? latin1ToBinary(offerIdStr) : null,
      innerPayloadJson: answer['sdp'] as String,
    );
  }

  return WebTorrentInbound.ignored(msg is String ? msg : jsonEncode(m));
}
