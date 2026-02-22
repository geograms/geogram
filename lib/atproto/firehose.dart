/*
 * AT Protocol firehose event stream.
 *
 * Manages the subscribeRepos event stream for AT Protocol federation.
 * Events are encoded as DAG-CBOR frames and stored in the sequence table.
 *
 * Frame format (binary, concatenated):
 *   header = DAG-CBOR({ "op": 1, "t": "#commit" })
 *   body   = DAG-CBOR({ commit details with ops array })
 *
 * Reference: https://atproto.com/specs/event-stream
 */

import 'dart:io';
import 'dart:typed_data';

import 'atproto_storage.dart';
import 'cid.dart';
import 'dag_cbor.dart';

/// Operation types for firehose events.
enum FirehoseOp {
  create,
  update,
  delete,
}

/// A single record operation within a commit event.
class FirehoseRecordOp {
  final FirehoseOp action;
  final String path; // collection/rkey
  final Cid? cid;

  FirehoseRecordOp({required this.action, required this.path, this.cid});

  Map<String, dynamic> toJson() => {
    'action': action.name,
    'path': path,
    if (cid != null) 'cid': CidLink(cid!),
  };
}

/// Manages the AT Protocol firehose event stream.
///
/// Encodes commit events, stores them in the sequence table, and broadcasts
/// to connected WebSocket subscribers.
class FirehoseManager {
  final AtprotoStorage storage;
  final String did;
  final List<WebSocket> _subscribers = [];

  FirehoseManager({required this.storage, required this.did});

  /// Number of connected subscribers.
  int get subscriberCount => _subscribers.length;

  /// Add a WebSocket subscriber.
  ///
  /// If [cursor] is provided, replays events after that sequence number first.
  void addSubscriber(WebSocket ws, {int? cursor}) {
    _subscribers.add(ws);

    // Replay missed events if cursor provided
    if (cursor != null) {
      final missed = storage.getEventsSince(cursor);
      for (final event in missed) {
        try {
          ws.add(event.event);
        } catch (_) {
          // Client disconnected during replay
          _subscribers.remove(ws);
          return;
        }
      }
    }

    ws.done.then((_) => _subscribers.remove(ws)).catchError((_) {
      _subscribers.remove(ws);
    });
  }

  /// Remove a WebSocket subscriber.
  void removeSubscriber(WebSocket ws) {
    _subscribers.remove(ws);
  }

  /// Emit a #commit event for a repo mutation.
  ///
  /// Encodes the event, stores it in the sequence table, and broadcasts
  /// to all connected subscribers.
  ///
  /// Returns the sequence number assigned to this event.
  int emitCommit({
    required Cid commitCid,
    required String rev,
    required List<FirehoseRecordOp> ops,
    Cid? prev,
  }) {
    final frame = encodeCommitFrame(
      did: did,
      commitCid: commitCid,
      rev: rev,
      ops: ops,
      prev: prev,
    );

    // Store in sequence table
    final seq = storage.appendEvent(frame);

    // Broadcast to subscribers
    _broadcast(frame);

    return seq;
  }

  /// Emit an #info event (server status message).
  int emitInfo(String name, String? message) {
    final frame = encodeInfoFrame(name: name, message: message);
    final seq = storage.appendEvent(frame);
    _broadcast(frame);
    return seq;
  }

  /// Get the latest sequence number.
  int? get latestSeq => storage.getLatestSeq();

  /// Get events since a cursor (for replay).
  List<({int seq, Uint8List event})> getEventsSince(int cursor, {int? limit}) {
    return storage.getEventsSince(cursor, limit: limit);
  }

  void _broadcast(Uint8List frame) {
    final stale = <WebSocket>[];
    for (final ws in _subscribers) {
      try {
        ws.add(frame);
      } catch (_) {
        stale.add(ws);
      }
    }
    for (final ws in stale) {
      _subscribers.remove(ws);
    }
  }

  /// Close all subscriber connections.
  Future<void> close() async {
    for (final ws in List.of(_subscribers)) {
      try {
        await ws.close();
      } catch (_) {}
    }
    _subscribers.clear();
  }

  // -- Static frame encoding --

  /// Encode a #commit firehose frame.
  ///
  /// Format: [4-byte BE header length][header DAG-CBOR][body DAG-CBOR]
  static Uint8List encodeCommitFrame({
    required String did,
    required Cid commitCid,
    required String rev,
    required List<FirehoseRecordOp> ops,
    Cid? prev,
  }) {
    return _encodeFrame(
      {'op': 1, 't': '#commit'},
      {
        'repo': did,
        'commit': CidLink(commitCid),
        'rev': rev,
        'time': DateTime.now().toUtc().toIso8601String(),
        'ops': ops.map((o) => o.toJson()).toList(),
        if (prev != null) 'prev': CidLink(prev),
      },
    );
  }

  /// Encode an #identity firehose frame.
  static Uint8List encodeIdentityFrame({
    required String did,
    required String handle,
  }) {
    return _encodeFrame(
      {'op': 1, 't': '#identity'},
      {
        'did': did,
        'handle': handle,
        'time': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  /// Encode an #info firehose frame.
  static Uint8List encodeInfoFrame({
    required String name,
    String? message,
  }) {
    return _encodeFrame(
      {'op': 1, 't': '#info'},
      {
        'name': name,
        if (message != null) 'message': message,
      },
    );
  }

  /// Encode a frame: [4-byte BE header length][header DAG-CBOR][body DAG-CBOR]
  static Uint8List _encodeFrame(
    Map<String, dynamic> header,
    Map<String, dynamic> body,
  ) {
    final headerBytes = DagCbor.encode(header);
    final bodyBytes = DagCbor.encode(body);
    final headerLen = headerBytes.length;

    final output = BytesBuilder(copy: false);
    // 4-byte big-endian header length
    output.addByte((headerLen >> 24) & 0xFF);
    output.addByte((headerLen >> 16) & 0xFF);
    output.addByte((headerLen >> 8) & 0xFF);
    output.addByte(headerLen & 0xFF);
    output.add(headerBytes);
    output.add(bodyBytes);
    return output.toBytes();
  }

  /// Decode a firehose frame into header and body.
  ///
  /// Returns null if the frame is malformed.
  static ({Map<String, dynamic> header, Map<String, dynamic> body})? decodeFrame(
    Uint8List frame,
  ) {
    try {
      if (frame.length < 5) return null; // 4-byte length + at least 1 byte

      // Read 4-byte big-endian header length
      final headerLen = (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];
      if (frame.length < 4 + headerLen + 1) return null;

      final headerBytes = frame.sublist(4, 4 + headerLen);
      final bodyBytes = frame.sublist(4 + headerLen);

      final headerDecoded = DagCbor.decode(headerBytes);
      if (headerDecoded is! Map<String, dynamic>) return null;

      final bodyDecoded = DagCbor.decode(bodyBytes);
      if (bodyDecoded is! Map<String, dynamic>) return null;

      return (header: headerDecoded, body: bodyDecoded);
    } catch (_) {
      return null;
    }
  }
}
