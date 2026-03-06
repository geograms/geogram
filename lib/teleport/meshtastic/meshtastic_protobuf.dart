/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Hand-coded protobuf encoder/decoder for Meshtastic wire messages.
 * Pure Dart, no generated code, no protobuf dependency.
 * Implements varint, fixed32, length-delimited wire types.
 *
 * Also includes BLE framing helpers (0x94C3 + 2-byte BE length).
 */

import 'dart:convert';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------

const int _wireVarint = 0;
const int _wireFixed64 = 1;
const int _wireLengthDelimited = 2;
const int _wireFixed32 = 5;

// ---------------------------------------------------------------------------
// Protobuf Writer
// ---------------------------------------------------------------------------

class ProtobufWriter {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  void writeVarintField(int fieldNumber, int value) {
    _writeTag(fieldNumber, _wireVarint);
    _writeRawVarint(value);
  }

  void writeBoolField(int fieldNumber, bool value) {
    if (!value) return; // false is default, skip
    writeVarintField(fieldNumber, 1);
  }

  void writeFixed32Field(int fieldNumber, int value) {
    _writeTag(fieldNumber, _wireFixed32);
    final b = Uint8List(4);
    ByteData.sublistView(b).setUint32(0, value, Endian.little);
    _buf.add(b);
  }

  void writeFloatField(int fieldNumber, double value) {
    _writeTag(fieldNumber, _wireFixed32);
    final b = Uint8List(4);
    ByteData.sublistView(b).setFloat32(0, value, Endian.little);
    _buf.add(b);
  }

  void writeSfixed32Field(int fieldNumber, int value) {
    _writeTag(fieldNumber, _wireFixed32);
    final b = Uint8List(4);
    ByteData.sublistView(b).setInt32(0, value, Endian.little);
    _buf.add(b);
  }

  void writeBytesField(int fieldNumber, Uint8List value) {
    if (value.isEmpty) return;
    _writeTag(fieldNumber, _wireLengthDelimited);
    _writeRawVarint(value.length);
    _buf.add(value);
  }

  void writeStringField(int fieldNumber, String value) {
    if (value.isEmpty) return;
    final encoded = utf8.encode(value);
    _writeTag(fieldNumber, _wireLengthDelimited);
    _writeRawVarint(encoded.length);
    _buf.add(encoded);
  }

  void writeSubmessageField(int fieldNumber, ProtobufWriter sub) {
    final bytes = sub.toBytes();
    if (bytes.isEmpty) return;
    _writeTag(fieldNumber, _wireLengthDelimited);
    _writeRawVarint(bytes.length);
    _buf.add(bytes);
  }

  Uint8List toBytes() => Uint8List.fromList(_buf.toBytes());

  void _writeTag(int fieldNumber, int wireType) {
    _writeRawVarint((fieldNumber << 3) | wireType);
  }

  void _writeRawVarint(int value) {
    // Handle as unsigned 64-bit
    var v = value & 0xFFFFFFFFFFFFFFFF;
    while (v > 0x7F) {
      _buf.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    _buf.addByte(v & 0x7F);
  }
}

// ---------------------------------------------------------------------------
// Protobuf Reader
// ---------------------------------------------------------------------------

class ProtobufReader {
  final Uint8List _data;
  int _pos = 0;

  ProtobufReader(this._data);

  bool get hasMore => _pos < _data.length;
  int get position => _pos;
  int get remaining => _data.length - _pos;

  /// Returns (fieldNumber, wireType) or null if no more data.
  (int, int)? readTag() {
    if (!hasMore) return null;
    final tag = readVarint();
    return (tag >> 3, tag & 0x7);
  }

  int readVarint() {
    int result = 0;
    int shift = 0;
    while (_pos < _data.length) {
      final b = _data[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) throw FormatException('Varint too long');
    }
    throw FormatException('Unexpected end of varint');
  }

  int readFixed32() {
    if (_pos + 4 > _data.length) throw FormatException('Unexpected end');
    final value =
        ByteData.sublistView(_data, _pos, _pos + 4).getUint32(0, Endian.little);
    _pos += 4;
    return value;
  }

  int readSfixed32() {
    if (_pos + 4 > _data.length) throw FormatException('Unexpected end');
    final value =
        ByteData.sublistView(_data, _pos, _pos + 4).getInt32(0, Endian.little);
    _pos += 4;
    return value;
  }

  double readFloat() {
    if (_pos + 4 > _data.length) throw FormatException('Unexpected end');
    final value = ByteData.sublistView(_data, _pos, _pos + 4)
        .getFloat32(0, Endian.little);
    _pos += 4;
    return value;
  }

  int readFixed64() {
    if (_pos + 8 > _data.length) throw FormatException('Unexpected end');
    final value =
        ByteData.sublistView(_data, _pos, _pos + 8).getUint64(0, Endian.little);
    _pos += 8;
    return value;
  }

  Uint8List readBytes() {
    final length = readVarint();
    if (_pos + length > _data.length) throw FormatException('Unexpected end');
    final result = Uint8List.sublistView(_data, _pos, _pos + length);
    _pos += length;
    return Uint8List.fromList(result);
  }

  String readString() => utf8.decode(readBytes());

  ProtobufReader readSubmessage() {
    final bytes = readBytes();
    return ProtobufReader(bytes);
  }

  void skipField(int wireType) {
    switch (wireType) {
      case _wireVarint:
        readVarint();
      case _wireFixed64:
        _pos += 8;
      case _wireLengthDelimited:
        final len = readVarint();
        _pos += len;
      case _wireFixed32:
        _pos += 4;
      default:
        throw FormatException('Unknown wire type: $wireType');
    }
  }
}

// ---------------------------------------------------------------------------
// Meshtastic PortNum values
// ---------------------------------------------------------------------------

class MeshtasticPortnum {
  static const int unknownApp = 0;
  static const int textMessageApp = 1;
  static const int remoteHardwareApp = 2;
  static const int positionApp = 3;
  static const int nodeinfoApp = 4;
  static const int routingApp = 32;
  static const int adminApp = 6;
  static const int telemetryApp = 67;
  static const int tracerouteApp = 70;
  static const int neighborinfoApp = 71;
  static const int mapReportApp = 73;
}

// ---------------------------------------------------------------------------
// Data (decoded payload within MeshPacket)
// ---------------------------------------------------------------------------

class MeshtasticData {
  final int portnum;
  final Uint8List payload;
  final bool wantResponse;
  final int dest;
  final int source;
  final int requestId;
  final int replyId;
  final int emoji;

  const MeshtasticData({
    required this.portnum,
    required this.payload,
    this.wantResponse = false,
    this.dest = 0,
    this.source = 0,
    this.requestId = 0,
    this.replyId = 0,
    this.emoji = 0,
  });

  factory MeshtasticData.decode(ProtobufReader reader) {
    int portnum = 0;
    Uint8List payload = Uint8List(0);
    bool wantResponse = false;
    int dest = 0, source = 0, requestId = 0, replyId = 0, emoji = 0;

    while (reader.hasMore) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          portnum = reader.readVarint();
        case 2:
          payload = reader.readBytes();
        case 3:
          wantResponse = reader.readVarint() != 0;
        case 4:
          dest = reader.readVarint();
        case 5:
          source = reader.readVarint();
        case 6:
          requestId = reader.readVarint();
        case 7:
          replyId = reader.readVarint();
        case 8:
          emoji = reader.readVarint();
        default:
          reader.skipField(wire);
      }
    }
    return MeshtasticData(
      portnum: portnum,
      payload: payload,
      wantResponse: wantResponse,
      dest: dest,
      source: source,
      requestId: requestId,
      replyId: replyId,
      emoji: emoji,
    );
  }

  ProtobufWriter encode() {
    final w = ProtobufWriter();
    if (portnum != 0) w.writeVarintField(1, portnum);
    w.writeBytesField(2, payload);
    if (wantResponse) w.writeBoolField(3, true);
    if (dest != 0) w.writeVarintField(4, dest);
    if (source != 0) w.writeVarintField(5, source);
    if (requestId != 0) w.writeVarintField(6, requestId);
    if (replyId != 0) w.writeVarintField(7, replyId);
    if (emoji != 0) w.writeVarintField(8, emoji);
    return w;
  }
}

// ---------------------------------------------------------------------------
// MeshPacket
// ---------------------------------------------------------------------------

/// Priority enum for MeshPacket.
class MeshtasticPriority {
  static const int unset = 0;
  static const int min = 1;
  static const int background = 10;
  static const int defaultPriority = 64;
  static const int reliable = 70;
  static const int ack = 120;
  static const int max = 127;
}

class MeshtasticMeshPacket {
  final int from;
  final int to;
  final int channel;
  final MeshtasticData? decoded;
  final Uint8List? encrypted;
  final int id;
  final int rxTime;
  final double rxSnr;
  final int rxRssi;
  final int hopLimit;
  final bool wantAck;
  final int priority;
  final int hopStart;
  final int viaMqtt;

  const MeshtasticMeshPacket({
    required this.from,
    required this.to,
    this.channel = 0,
    this.decoded,
    this.encrypted,
    required this.id,
    this.rxTime = 0,
    this.rxSnr = 0.0,
    this.rxRssi = 0,
    this.hopLimit = 3,
    this.wantAck = false,
    this.priority = 0,
    this.hopStart = 0,
    this.viaMqtt = 0,
  });

  factory MeshtasticMeshPacket.decode(ProtobufReader reader) {
    int from = 0, to = 0, channel = 0, id = 0, rxTime = 0;
    double rxSnr = 0.0;
    int rxRssi = 0, hopLimit = 3, priority = 0, hopStart = 0, viaMqtt = 0;
    bool wantAck = false;
    MeshtasticData? decoded;
    Uint8List? encrypted;

    while (reader.hasMore) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          from = reader.readVarint();
        case 2:
          to = reader.readVarint();
        case 3:
          channel = reader.readVarint();
        case 4:
          decoded = MeshtasticData.decode(reader.readSubmessage());
        case 5:
          encrypted = reader.readBytes();
        case 6:
          id = reader.readFixed32();
        case 7:
          rxTime = reader.readFixed32();
        case 8:
          rxSnr = reader.readFloat();
        case 9:
          hopLimit = reader.readVarint();
        case 10:
          wantAck = reader.readVarint() != 0;
        case 11:
          priority = reader.readVarint();
        case 12:
          rxRssi = reader.readVarint();
        case 15:
          hopStart = reader.readVarint();
        case 16:
          viaMqtt = reader.readVarint();
        default:
          reader.skipField(wire);
      }
    }
    return MeshtasticMeshPacket(
      from: from,
      to: to,
      channel: channel,
      decoded: decoded,
      encrypted: encrypted,
      id: id,
      rxTime: rxTime,
      rxSnr: rxSnr,
      rxRssi: rxRssi,
      hopLimit: hopLimit,
      wantAck: wantAck,
      priority: priority,
      hopStart: hopStart,
      viaMqtt: viaMqtt,
    );
  }

  ProtobufWriter encode() {
    final w = ProtobufWriter();
    if (from != 0) w.writeVarintField(1, from);
    if (to != 0) w.writeVarintField(2, to);
    if (channel != 0) w.writeVarintField(3, channel);
    if (decoded != null) w.writeSubmessageField(4, decoded!.encode());
    if (encrypted != null) w.writeBytesField(5, encrypted!);
    if (id != 0) w.writeFixed32Field(6, id);
    if (rxTime != 0) w.writeFixed32Field(7, rxTime);
    if (rxSnr != 0.0) w.writeFloatField(8, rxSnr);
    if (hopLimit != 0) w.writeVarintField(9, hopLimit);
    if (wantAck) w.writeBoolField(10, true);
    if (priority != 0) w.writeVarintField(11, priority);
    if (rxRssi != 0) w.writeVarintField(12, rxRssi);
    if (hopStart != 0) w.writeVarintField(15, hopStart);
    if (viaMqtt != 0) w.writeVarintField(16, viaMqtt);
    return w;
  }
}

// ---------------------------------------------------------------------------
// User
// ---------------------------------------------------------------------------

class MeshtasticUser {
  final String id;
  final String longName;
  final String shortName;
  final Uint8List macaddr;
  final int hwModel;
  final bool isLicensed;
  final int role;
  final Uint8List publicKey;

  MeshtasticUser({
    this.id = '',
    this.longName = '',
    this.shortName = '',
    Uint8List? macaddr,
    this.hwModel = 0,
    this.isLicensed = false,
    this.role = 0,
    Uint8List? publicKey,
  })  : macaddr = macaddr ?? Uint8List(0),
        publicKey = publicKey ?? Uint8List(0);

  factory MeshtasticUser.decode(ProtobufReader reader) {
    String id = '', longName = '', shortName = '';
    Uint8List macaddr = Uint8List(0), publicKey = Uint8List(0);
    int hwModel = 0, role = 0;
    bool isLicensed = false;

    while (reader.hasMore) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          id = reader.readString();
        case 2:
          longName = reader.readString();
        case 3:
          shortName = reader.readString();
        case 4:
          macaddr = reader.readBytes();
        case 5:
          hwModel = reader.readVarint();
        case 6:
          isLicensed = reader.readVarint() != 0;
        case 7:
          role = reader.readVarint();
        case 8:
          publicKey = reader.readBytes();
        default:
          reader.skipField(wire);
      }
    }
    return MeshtasticUser(
      id: id,
      longName: longName,
      shortName: shortName,
      macaddr: macaddr,
      hwModel: hwModel,
      isLicensed: isLicensed,
      role: role,
      publicKey: publicKey,
    );
  }

  ProtobufWriter encode() {
    final w = ProtobufWriter();
    w.writeStringField(1, id);
    w.writeStringField(2, longName);
    w.writeStringField(3, shortName);
    if (macaddr.isNotEmpty) w.writeBytesField(4, macaddr);
    if (hwModel != 0) w.writeVarintField(5, hwModel);
    if (isLicensed) w.writeBoolField(6, true);
    if (role != 0) w.writeVarintField(7, role);
    if (publicKey.isNotEmpty) w.writeBytesField(8, publicKey);
    return w;
  }
}

// ---------------------------------------------------------------------------
// Position
// ---------------------------------------------------------------------------

class MeshtasticPosition {
  final int latitudeI; // degrees * 1e7
  final int longitudeI; // degrees * 1e7
  final int altitude;
  final int time;
  final int satsInView;

  const MeshtasticPosition({
    this.latitudeI = 0,
    this.longitudeI = 0,
    this.altitude = 0,
    this.time = 0,
    this.satsInView = 0,
  });

  double get latitude => latitudeI / 1e7;
  double get longitude => longitudeI / 1e7;

  factory MeshtasticPosition.decode(ProtobufReader reader) {
    int latI = 0, lonI = 0, alt = 0, time = 0, sats = 0;

    while (reader.hasMore) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          latI = wire == _wireFixed32
              ? reader.readSfixed32()
              : reader.readVarint();
        case 2:
          lonI = wire == _wireFixed32
              ? reader.readSfixed32()
              : reader.readVarint();
        case 3:
          alt = reader.readVarint();
        case 4:
          time = wire == _wireFixed32
              ? reader.readFixed32()
              : reader.readVarint();
        case 15:
          sats = reader.readVarint();
        default:
          reader.skipField(wire);
      }
    }
    return MeshtasticPosition(
      latitudeI: latI,
      longitudeI: lonI,
      altitude: alt,
      time: time,
      satsInView: sats,
    );
  }

  ProtobufWriter encode() {
    final w = ProtobufWriter();
    if (latitudeI != 0) w.writeSfixed32Field(1, latitudeI);
    if (longitudeI != 0) w.writeSfixed32Field(2, longitudeI);
    if (altitude != 0) w.writeVarintField(3, altitude);
    if (time != 0) w.writeFixed32Field(4, time);
    if (satsInView != 0) w.writeVarintField(15, satsInView);
    return w;
  }
}

// ---------------------------------------------------------------------------
// DeviceMetrics (within Telemetry)
// ---------------------------------------------------------------------------

class MeshtasticDeviceMetrics {
  final int batteryLevel;
  final double voltage;
  final double channelUtilization;
  final double airUtilTx;
  final int uptimeSeconds;

  const MeshtasticDeviceMetrics({
    this.batteryLevel = 0,
    this.voltage = 0.0,
    this.channelUtilization = 0.0,
    this.airUtilTx = 0.0,
    this.uptimeSeconds = 0,
  });

  factory MeshtasticDeviceMetrics.decode(ProtobufReader reader) {
    int battery = 0, uptime = 0;
    double voltage = 0, chanUtil = 0, airUtil = 0;

    while (reader.hasMore) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          battery = reader.readVarint();
        case 2:
          voltage = reader.readFloat();
        case 3:
          chanUtil = reader.readFloat();
        case 4:
          airUtil = reader.readFloat();
        case 5:
          uptime = reader.readVarint();
        default:
          reader.skipField(wire);
      }
    }
    return MeshtasticDeviceMetrics(
      batteryLevel: battery,
      voltage: voltage,
      channelUtilization: chanUtil,
      airUtilTx: airUtil,
      uptimeSeconds: uptime,
    );
  }
}

// ---------------------------------------------------------------------------
// NodeInfo
// ---------------------------------------------------------------------------

class MeshtasticNodeInfo {
  final int num;
  final MeshtasticUser? user;
  final MeshtasticPosition? position;
  final double snr;
  final int lastHeard;
  final MeshtasticDeviceMetrics? deviceMetrics;

  const MeshtasticNodeInfo({
    required this.num,
    this.user,
    this.position,
    this.snr = 0.0,
    this.lastHeard = 0,
    this.deviceMetrics,
  });

  factory MeshtasticNodeInfo.decode(ProtobufReader reader) {
    int num = 0, lastHeard = 0;
    double snr = 0.0;
    MeshtasticUser? user;
    MeshtasticPosition? position;
    MeshtasticDeviceMetrics? deviceMetrics;

    while (reader.hasMore) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          num = reader.readVarint();
        case 2:
          user = MeshtasticUser.decode(reader.readSubmessage());
        case 3:
          position = MeshtasticPosition.decode(reader.readSubmessage());
        case 4:
          snr = reader.readFloat();
        case 5:
          lastHeard = wire == _wireFixed32
              ? reader.readFixed32()
              : reader.readVarint();
        case 6:
          deviceMetrics =
              MeshtasticDeviceMetrics.decode(reader.readSubmessage());
        default:
          reader.skipField(wire);
      }
    }
    return MeshtasticNodeInfo(
      num: num,
      user: user,
      position: position,
      snr: snr,
      lastHeard: lastHeard,
      deviceMetrics: deviceMetrics,
    );
  }
}

// ---------------------------------------------------------------------------
// MyNodeInfo
// ---------------------------------------------------------------------------

class MeshtasticMyNodeInfo {
  final int myNodeNum;
  final int rebootCount;
  final int minAppVersion;

  const MeshtasticMyNodeInfo({
    required this.myNodeNum,
    this.rebootCount = 0,
    this.minAppVersion = 0,
  });

  factory MeshtasticMyNodeInfo.decode(ProtobufReader reader) {
    int myNodeNum = 0, rebootCount = 0, minAppVersion = 0;

    while (reader.hasMore) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          myNodeNum = reader.readVarint();
        case 8:
          rebootCount = reader.readVarint();
        case 11:
          minAppVersion = reader.readVarint();
        default:
          reader.skipField(wire);
      }
    }
    return MeshtasticMyNodeInfo(
      myNodeNum: myNodeNum,
      rebootCount: rebootCount,
      minAppVersion: minAppVersion,
    );
  }
}

// ---------------------------------------------------------------------------
// ChannelSettings
// ---------------------------------------------------------------------------

class MeshtasticChannelSettings {
  final int channelNum;
  final Uint8List psk;
  final String name;
  final int id;
  final bool uplinkEnabled;
  final bool downlinkEnabled;

  MeshtasticChannelSettings({
    this.channelNum = 0,
    Uint8List? psk,
    this.name = '',
    this.id = 0,
    this.uplinkEnabled = false,
    this.downlinkEnabled = false,
  }) : psk = psk ?? Uint8List(0);

  factory MeshtasticChannelSettings.decode(ProtobufReader reader) {
    int channelNum = 0, id = 0;
    Uint8List psk = Uint8List(0);
    String name = '';
    bool uplink = false, downlink = false;

    while (reader.hasMore) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          channelNum = reader.readVarint();
        case 2:
          psk = reader.readBytes();
        case 3:
          name = reader.readString();
        case 4:
          id = wire == _wireFixed32
              ? reader.readFixed32()
              : reader.readVarint();
        case 5:
          uplink = reader.readVarint() != 0;
        case 6:
          downlink = reader.readVarint() != 0;
        default:
          reader.skipField(wire);
      }
    }
    return MeshtasticChannelSettings(
      channelNum: channelNum,
      psk: psk,
      name: name,
      id: id,
      uplinkEnabled: uplink,
      downlinkEnabled: downlink,
    );
  }

  ProtobufWriter encode() {
    final w = ProtobufWriter();
    if (channelNum != 0) w.writeVarintField(1, channelNum);
    if (psk.isNotEmpty) w.writeBytesField(2, psk);
    w.writeStringField(3, name);
    if (id != 0) w.writeFixed32Field(4, id);
    if (uplinkEnabled) w.writeBoolField(5, true);
    if (downlinkEnabled) w.writeBoolField(6, true);
    return w;
  }
}

// ---------------------------------------------------------------------------
// Channel
// ---------------------------------------------------------------------------

class MeshtasticProtoChannelRole {
  static const int disabled = 0;
  static const int primary = 1;
  static const int secondary = 2;
}

class MeshtasticChannel {
  final int index;
  final MeshtasticChannelSettings? settings;
  final int role;

  const MeshtasticChannel({
    this.index = 0,
    this.settings,
    this.role = MeshtasticProtoChannelRole.disabled,
  });

  factory MeshtasticChannel.decode(ProtobufReader reader) {
    int index = 0, role = 0;
    MeshtasticChannelSettings? settings;

    while (reader.hasMore) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          index = reader.readVarint();
        case 2:
          settings = MeshtasticChannelSettings.decode(reader.readSubmessage());
        case 3:
          role = reader.readVarint();
        default:
          reader.skipField(wire);
      }
    }
    return MeshtasticChannel(index: index, settings: settings, role: role);
  }
}

// ---------------------------------------------------------------------------
// FromRadio
// ---------------------------------------------------------------------------

class MeshtasticFromRadio {
  final int id;
  final MeshtasticMeshPacket? packet;
  final MeshtasticMyNodeInfo? myInfo;
  final MeshtasticNodeInfo? nodeInfo;
  final MeshtasticChannel? channel;
  final int configCompleteId;

  const MeshtasticFromRadio({
    this.id = 0,
    this.packet,
    this.myInfo,
    this.nodeInfo,
    this.channel,
    this.configCompleteId = 0,
  });

  factory MeshtasticFromRadio.decode(Uint8List data) {
    final reader = ProtobufReader(data);
    int id = 0, configCompleteId = 0;
    MeshtasticMeshPacket? packet;
    MeshtasticMyNodeInfo? myInfo;
    MeshtasticNodeInfo? nodeInfo;
    MeshtasticChannel? channel;

    while (reader.hasMore) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          id = reader.readVarint();
        case 2:
          packet = MeshtasticMeshPacket.decode(reader.readSubmessage());
        case 5:
          myInfo = MeshtasticMyNodeInfo.decode(reader.readSubmessage());
        case 6:
          nodeInfo = MeshtasticNodeInfo.decode(reader.readSubmessage());
        case 9:
          channel = MeshtasticChannel.decode(reader.readSubmessage());
        case 12:
          configCompleteId = reader.readVarint();
        default:
          reader.skipField(wire);
      }
    }
    return MeshtasticFromRadio(
      id: id,
      packet: packet,
      myInfo: myInfo,
      nodeInfo: nodeInfo,
      channel: channel,
      configCompleteId: configCompleteId,
    );
  }
}

// ---------------------------------------------------------------------------
// ToRadio
// ---------------------------------------------------------------------------

class MeshtasticToRadio {
  final MeshtasticMeshPacket? packet;
  final int wantConfigId;

  const MeshtasticToRadio({this.packet, this.wantConfigId = 0});

  Uint8List encode() {
    final w = ProtobufWriter();
    if (packet != null) w.writeSubmessageField(1, packet!.encode());
    if (wantConfigId != 0) w.writeVarintField(3, wantConfigId);
    return w.toBytes();
  }
}

// ---------------------------------------------------------------------------
// ServiceEnvelope (for MQTT)
// ---------------------------------------------------------------------------

class MeshtasticServiceEnvelope {
  final MeshtasticMeshPacket? packet;
  final String channelId;
  final String gatewayId;

  const MeshtasticServiceEnvelope({
    this.packet,
    this.channelId = '',
    this.gatewayId = '',
  });

  factory MeshtasticServiceEnvelope.decode(Uint8List data) {
    final reader = ProtobufReader(data);
    MeshtasticMeshPacket? packet;
    String channelId = '', gatewayId = '';

    while (reader.hasMore) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          packet = MeshtasticMeshPacket.decode(reader.readSubmessage());
        case 2:
          channelId = reader.readString();
        case 3:
          gatewayId = reader.readString();
        default:
          reader.skipField(wire);
      }
    }
    return MeshtasticServiceEnvelope(
      packet: packet,
      channelId: channelId,
      gatewayId: gatewayId,
    );
  }

  Uint8List encode() {
    final w = ProtobufWriter();
    if (packet != null) w.writeSubmessageField(1, packet!.encode());
    w.writeStringField(2, channelId);
    w.writeStringField(3, gatewayId);
    return w.toBytes();
  }
}

// ---------------------------------------------------------------------------
// BLE framing helpers
// ---------------------------------------------------------------------------

/// Frame a protobuf payload for BLE transport.
/// Prepends 0x94, 0xC3, and 2-byte big-endian length.
Uint8List frameBlePacket(Uint8List payload) {
  final frame = Uint8List(4 + payload.length);
  frame[0] = 0x94;
  frame[1] = 0xC3;
  frame[2] = (payload.length >> 8) & 0xFF;
  frame[3] = payload.length & 0xFF;
  frame.setRange(4, frame.length, payload);
  return frame;
}

/// Deframe BLE data. Returns (payload, consumedBytes) or null if incomplete.
/// Accumulates in a buffer and extracts complete frames.
(Uint8List, int)? deframeBleData(Uint8List data, [int offset = 0]) {
  if (data.length - offset < 4) return null;
  if (data[offset] != 0x94 || data[offset + 1] != 0xC3) return null;

  final length = (data[offset + 2] << 8) | data[offset + 3];
  if (data.length - offset < 4 + length) return null;

  final payload = Uint8List.sublistView(data, offset + 4, offset + 4 + length);
  return (Uint8List.fromList(payload), 4 + length);
}
