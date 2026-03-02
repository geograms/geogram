/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * MeshCore channel — one of 8 group channels (index 0-7) on the device.
 */

class MeshCoreChannel {
  /// Channel index (0-7).
  final int index;

  /// Channel name (set by the device owner).
  final String name;

  const MeshCoreChannel({
    required this.index,
    required this.name,
  });

  /// Display name: name if set, otherwise "Channel N".
  String get displayName => name.isNotEmpty ? name : 'Channel $index';

  Map<String, dynamic> toJson() => {
    'index': index,
    'name': name,
  };

  factory MeshCoreChannel.fromJson(Map<String, dynamic> json) => MeshCoreChannel(
    index: json['index'] as int,
    name: json['name'] as String? ?? '',
  );
}
