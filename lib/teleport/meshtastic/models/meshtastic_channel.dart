/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Meshtastic channel configuration (0-7 per device).
 */

import 'dart:convert';
import 'dart:typed_data';

enum MeshtasticChannelRole { disabled, primary, secondary }

class MeshtasticChannelConfig {
  final int index;
  final String name;
  final Uint8List psk;
  final MeshtasticChannelRole role;

  MeshtasticChannelConfig({
    required this.index,
    this.name = '',
    Uint8List? psk,
    this.role = MeshtasticChannelRole.disabled,
  }) : psk = psk ?? Uint8List(0);

  String get displayName {
    if (name.isNotEmpty) return name;
    if (role == MeshtasticChannelRole.primary) return 'LongFast';
    return 'Channel $index';
  }

  bool get isEnabled => role != MeshtasticChannelRole.disabled;

  Map<String, dynamic> toJson() => {
        'index': index,
        'name': name,
        'psk': base64Encode(psk),
        'role': role.name,
      };

  factory MeshtasticChannelConfig.fromJson(Map<String, dynamic> json) {
    Uint8List psk;
    try {
      psk = base64Decode(json['psk'] as String? ?? '');
    } catch (_) {
      psk = Uint8List(0);
    }
    return MeshtasticChannelConfig(
      index: json['index'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      psk: psk,
      role: MeshtasticChannelRole.values.firstWhere(
        (r) => r.name == json['role'],
        orElse: () => MeshtasticChannelRole.disabled,
      ),
    );
  }
}
