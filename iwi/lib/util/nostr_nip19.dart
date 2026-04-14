/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NIP-19 decoder for nostr: URIs (note/npub/nevent/nprofile/naddr).
 *
 * Vendored from geogram/lib/util/nostr_nip19.dart — keep in sync
 * manually until a shared package lands.
 */

import 'dart:typed_data';

import 'package:bech32/bech32.dart';
import 'package:hex/hex.dart';

class NostrNip19Result {
  final String type;
  final String? hex;
  final Map<int, List<Uint8List>> tlv;

  const NostrNip19Result({
    required this.type,
    this.hex,
    this.tlv = const {},
  });

  String? get eventIdHex {
    if (type == 'note') return hex;
    if (type == 'nevent') {
      final values = tlv[0];
      if (values != null && values.isNotEmpty) {
        return HEX.encode(values.first);
      }
    }
    return null;
  }

  String? get pubkeyHex {
    if (type == 'npub') return hex;
    if (type == 'nprofile') {
      final values = tlv[0];
      if (values != null && values.isNotEmpty) {
        return HEX.encode(values.first);
      }
    }
    if (type == 'naddr') {
      final values = tlv[2];
      if (values != null && values.isNotEmpty) {
        return HEX.encode(values.first);
      }
    }
    return null;
  }
}

class NostrNip19 {
  static NostrNip19Result? decode(String uri) {
    final value = uri.startsWith('nostr:') ? uri.substring(6) : uri;
    try {
      final decoded = const Bech32Codec().decode(value);
      final hrp = decoded.hrp.toLowerCase();
      final bytes = _convertBits(
        Uint8List.fromList(decoded.data),
        5,
        8,
        false,
      );

      if (hrp == 'note' || hrp == 'npub') {
        return NostrNip19Result(type: hrp, hex: HEX.encode(bytes));
      }

      if (hrp == 'nevent' || hrp == 'nprofile' || hrp == 'naddr') {
        return NostrNip19Result(type: hrp, tlv: _decodeTlv(bytes));
      }
    } catch (_) {}
    return null;
  }

  static Map<int, List<Uint8List>> _decodeTlv(Uint8List data) {
    final result = <int, List<Uint8List>>{};
    var i = 0;
    while (i + 1 < data.length) {
      final type = data[i];
      final length = data[i + 1];
      i += 2;
      if (i + length > data.length) break;
      final value = Uint8List.fromList(data.sublist(i, i + length));
      result.putIfAbsent(type, () => []).add(value);
      i += length;
    }
    return result;
  }

  static Uint8List _convertBits(
    Uint8List data,
    int from,
    int to,
    bool pad,
  ) {
    var acc = 0;
    var bits = 0;
    final maxv = (1 << to) - 1;
    final result = <int>[];

    for (final value in data) {
      if (value < 0 || (value >> from) != 0) {
        return Uint8List(0);
      }
      acc = (acc << from) | value;
      bits += from;
      while (bits >= to) {
        bits -= to;
        result.add((acc >> bits) & maxv);
      }
    }

    if (pad) {
      if (bits > 0) {
        result.add((acc << (to - bits)) & maxv);
      }
    } else if (bits >= from || ((acc << (to - bits)) & maxv) != 0) {
      return Uint8List(0);
    }

    return Uint8List.fromList(result);
  }
}
