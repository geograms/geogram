/*
 * Timestamp ID (TID) generator for AT Protocol.
 *
 * TIDs are 13-character base32-sortable identifiers encoding:
 * - Microsecond timestamp (top 53 bits)
 * - 10-bit clock ID (bottom 10 bits)
 *
 * Character set: 234567abcdefghijklmnopqrstuvwxyz (base32-sortable)
 * The encoding ensures lexicographic ordering matches temporal ordering.
 *
 * Reference: https://atproto.com/specs/record-key#record-key-type-tid
 */

import 'dart:math';

/// AT Protocol Timestamp ID generator.
class Tid {
  static const _chars = '234567abcdefghijklmnopqrstuvwxyz';
  static const int _tidLength = 13;

  /// 10-bit clock ID, assigned randomly per process.
  static final int _clockId = Random.secure().nextInt(1024);

  /// Last timestamp used, for monotonicity.
  static int _lastTimestamp = 0;

  /// Generate a new TID for the current microsecond.
  ///
  /// Guarantees monotonically increasing values within a process
  /// even if the system clock goes backwards.
  static String next() {
    var timestamp = DateTime.now().microsecondsSinceEpoch;

    // Ensure monotonicity
    if (timestamp <= _lastTimestamp) {
      timestamp = _lastTimestamp + 1;
    }
    _lastTimestamp = timestamp;

    // Pack: 53-bit timestamp << 10 | 10-bit clockId
    // Total: 63 bits, fits in a 13-char base32 string (65 bits capacity)
    final packed = (timestamp << 10) | _clockId;
    return _encode(packed);
  }

  /// Generate a TID from a specific [DateTime].
  ///
  /// Useful for importing existing content with its original timestamp.
  static String fromDateTime(DateTime dt) {
    final timestamp = dt.microsecondsSinceEpoch;
    final packed = (timestamp << 10) | _clockId;
    return _encode(packed);
  }

  /// Parse a TID string back to its embedded timestamp.
  static DateTime parse(String tid) {
    if (tid.length != _tidLength) {
      throw FormatException('TID must be $_tidLength characters, got ${tid.length}');
    }
    final packed = _decode(tid);
    final microseconds = packed >> 10;
    return DateTime.fromMicrosecondsSinceEpoch(microseconds);
  }

  /// Check whether a string is a valid TID.
  static bool isValid(String s) {
    if (s.length != _tidLength) return false;
    for (final c in s.codeUnits) {
      if (_chars.indexOf(String.fromCharCode(c)) < 0) return false;
    }
    return true;
  }

  static String _encode(int value) {
    final chars = List<String>.filled(_tidLength, '');
    for (var i = _tidLength - 1; i >= 0; i--) {
      chars[i] = _chars[value & 0x1f];
      value >>= 5;
    }
    return chars.join();
  }

  static int _decode(String tid) {
    var result = 0;
    for (var i = 0; i < tid.length; i++) {
      final idx = _chars.indexOf(tid[i]);
      if (idx < 0) {
        throw FormatException('Invalid TID character: ${tid[i]}');
      }
      result = (result << 5) | idx;
    }
    return result;
  }
}
