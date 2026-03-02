/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * MeshCore device info — identity and radio parameters of the connected device.
 */

class MeshCoreDeviceInfo {
  /// Device's own Ed25519 public key (hex).
  final String pubKeyHex;

  /// Device advertised name.
  final String name;

  /// Firmware version string.
  final String? firmwareVersion;

  /// Board/hardware model.
  final String? boardModel;

  /// LoRa frequency in MHz.
  final double? frequencyMhz;

  /// LoRa bandwidth in kHz.
  final double? bandwidthKhz;

  /// LoRa spreading factor.
  final int? spreadingFactor;

  /// LoRa coding rate.
  final int? codingRate;

  /// TX power in dBm.
  final int? txPowerDbm;

  const MeshCoreDeviceInfo({
    required this.pubKeyHex,
    required this.name,
    this.firmwareVersion,
    this.boardModel,
    this.frequencyMhz,
    this.bandwidthKhz,
    this.spreadingFactor,
    this.codingRate,
    this.txPowerDbm,
  });

  Map<String, dynamic> toJson() => {
    'pubKeyHex': pubKeyHex,
    'name': name,
    'firmwareVersion': firmwareVersion,
    'boardModel': boardModel,
    'frequencyMhz': frequencyMhz,
    'bandwidthKhz': bandwidthKhz,
    'spreadingFactor': spreadingFactor,
    'codingRate': codingRate,
    'txPowerDbm': txPowerDbm,
  };

  factory MeshCoreDeviceInfo.fromJson(Map<String, dynamic> json) => MeshCoreDeviceInfo(
    pubKeyHex: json['pubKeyHex'] as String? ?? '',
    name: json['name'] as String? ?? '',
    firmwareVersion: json['firmwareVersion'] as String?,
    boardModel: json['boardModel'] as String?,
    frequencyMhz: (json['frequencyMhz'] as num?)?.toDouble(),
    bandwidthKhz: (json['bandwidthKhz'] as num?)?.toDouble(),
    spreadingFactor: json['spreadingFactor'] as int?,
    codingRate: json['codingRate'] as int?,
    txPowerDbm: json['txPowerDbm'] as int?,
  );
}
