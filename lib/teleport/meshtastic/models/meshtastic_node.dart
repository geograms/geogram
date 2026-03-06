/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Meshtastic node — a device on the mesh network.
 */

import 'dart:typed_data';

class MeshtasticNode {
  final int nodeNum;
  final String userId;
  final String longName;
  final String shortName;
  final int hwModel;
  final Uint8List publicKey;
  final double? latitude;
  final double? longitude;
  final int altitude;
  final double snr;
  final int lastHeard;
  final int batteryLevel;
  final double voltage;

  MeshtasticNode({
    required this.nodeNum,
    this.userId = '',
    this.longName = '',
    this.shortName = '',
    this.hwModel = 0,
    Uint8List? publicKey,
    this.latitude,
    this.longitude,
    this.altitude = 0,
    this.snr = 0.0,
    this.lastHeard = 0,
    this.batteryLevel = 0,
    this.voltage = 0.0,
  }) : publicKey = publicKey ?? Uint8List(0);

  String get displayName {
    if (longName.isNotEmpty) return longName;
    if (shortName.isNotEmpty) return shortName;
    if (userId.isNotEmpty) return userId;
    return '!${nodeNum.toRadixString(16)}';
  }

  String get nodeNumHex => nodeNum.toRadixString(16);

  bool get hasPosition => latitude != null && longitude != null;

  Map<String, dynamic> toJson() => {
        'nodeNum': nodeNum,
        'userId': userId,
        'longName': longName,
        'shortName': shortName,
        'hwModel': hwModel,
        'latitude': latitude,
        'longitude': longitude,
        'altitude': altitude,
        'snr': snr,
        'lastHeard': lastHeard,
        'batteryLevel': batteryLevel,
        'voltage': voltage,
      };

  factory MeshtasticNode.fromJson(Map<String, dynamic> json) =>
      MeshtasticNode(
        nodeNum: json['nodeNum'] as int,
        userId: json['userId'] as String? ?? '',
        longName: json['longName'] as String? ?? '',
        shortName: json['shortName'] as String? ?? '',
        hwModel: json['hwModel'] as int? ?? 0,
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        altitude: json['altitude'] as int? ?? 0,
        snr: (json['snr'] as num?)?.toDouble() ?? 0.0,
        lastHeard: json['lastHeard'] as int? ?? 0,
        batteryLevel: json['batteryLevel'] as int? ?? 0,
        voltage: (json['voltage'] as num?)?.toDouble() ?? 0.0,
      );

  MeshtasticNode copyWith({
    String? longName,
    String? shortName,
    double? latitude,
    double? longitude,
    int? altitude,
    double? snr,
    int? lastHeard,
    int? batteryLevel,
    double? voltage,
  }) =>
      MeshtasticNode(
        nodeNum: nodeNum,
        userId: userId,
        longName: longName ?? this.longName,
        shortName: shortName ?? this.shortName,
        hwModel: hwModel,
        publicKey: publicKey,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        altitude: altitude ?? this.altitude,
        snr: snr ?? this.snr,
        lastHeard: lastHeard ?? this.lastHeard,
        batteryLevel: batteryLevel ?? this.batteryLevel,
        voltage: voltage ?? this.voltage,
      );
}
