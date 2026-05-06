/// DHT topic constants and derivation per BT-DHT-v2 §6.4 / §16.
///
/// Topic info_hashes are 20-byte SHA1 outputs derived deterministically at
/// runtime — NEVER hardcoded — so future protocol versions can coexist with
/// v1 nodes during migration windows.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hex/hex.dart';

import '../util/nostr_crypto.dart';

/// Spec input strings (§16). Implementations MUST derive at runtime.
const String kRelayTopicInput = 'geogram/v1/relay';
const String kPeerTopicSuffix = 'geogram/v1/peer';
const String kGroupTopicSuffix = 'geogram/v1/group';

/// 4-week migration window during which legacy hashes are dual-announced
/// and dual-queried alongside the spec-compliant ones. Flip to false in a
/// follow-up release once the soak completes.
const bool kEnableLegacyTopics = true;

/// Derived 20-byte info_hashes for the three Geogram topic kinds.
class DhtTopics {
  /// Global relay-tier rendezvous (§6.4 RELAY_TOPIC). Reachable instances
  /// announce here; consumers query it to discover candidate relays.
  static Uint8List relayTopic() => _sha1Bytes(utf8.encode(kRelayTopicInput));

  /// Per-recipient rendezvous (§6.4 PEER_TOPIC).
  ///
  /// Spec: SHA1(npub_bytes || "geogram/v1/peer") — note the input is the
  /// 32-byte secp256k1 x-only pubkey, NOT the bech32 `npub1...` string.
  static Uint8List peerTopic(Uint8List npubBytes) {
    if (npubBytes.length != 32) {
      throw ArgumentError(
        'peerTopic requires 32-byte npub pubkey, got ${npubBytes.length}',
      );
    }
    final input = Uint8List(npubBytes.length + kPeerTopicSuffix.length)
      ..setRange(0, npubBytes.length, npubBytes)
      ..setRange(npubBytes.length, npubBytes.length + kPeerTopicSuffix.length,
          utf8.encode(kPeerTopicSuffix));
    return _sha1Bytes(input);
  }

  /// Per-group rendezvous (§6.4 GROUP_TOPIC).
  static Uint8List groupTopic(Uint8List groupIdBytes) {
    final input = Uint8List(groupIdBytes.length + kGroupTopicSuffix.length)
      ..setRange(0, groupIdBytes.length, groupIdBytes)
      ..setRange(groupIdBytes.length,
          groupIdBytes.length + kGroupTopicSuffix.length,
          utf8.encode(kGroupTopicSuffix));
    return _sha1Bytes(input);
  }

  /// Convenience: decode a bech32 `npub1...` string and compute peerTopic.
  /// Falls back to hashing the 64-char hex pubkey if the input isn't bech32.
  static Uint8List peerTopicFromNpub(String npubOrHex) {
    final pubkeyHex = npubOrHex.startsWith('npub1')
        ? NostrCrypto.decodeNpub(npubOrHex)
        : npubOrHex;
    return peerTopic(Uint8List.fromList(HEX.decode(pubkeyHex)));
  }

  // === Legacy hash helpers (migration only) ===

  /// Pre-spec global hash: SHA1("geogram"). Used by the codebase before
  /// BT-DHT-v2. Kept for the dual-announce window.
  static Uint8List legacyGeogramHash() =>
      _sha1Bytes(utf8.encode('geogram'));

  /// Pre-spec per-npub hash: `SHA1(bech32-npub-string)`. Note this hashes
  /// the bech32 string, not the underlying 32-byte pubkey — that's the bug
  /// the spec fixes.
  static Uint8List legacyNpubHash(String bech32Npub) =>
      _sha1Bytes(utf8.encode(bech32Npub));

  /// Pre-spec per-pair rendezvous: SHA1("geogram:rendezvous:v1:<a>:<b>")
  /// where a and b are the two callsigns sorted alphabetically.
  static Uint8List legacyPairRendezvousHash(String callsignA, String callsignB) {
    final sorted = [callsignA, callsignB]..sort();
    return _sha1Bytes(
        utf8.encode('geogram:rendezvous:v1:${sorted[0]}:${sorted[1]}'));
  }
}

Uint8List _sha1Bytes(List<int> input) =>
    Uint8List.fromList(sha1.convert(input).bytes);
