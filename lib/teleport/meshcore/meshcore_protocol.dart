/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * MeshCore binary protocol — encode/decode for BLE commands.
 * Pure Dart, no Flutter dependency. Reusable from CLI.
 *
 * Reference: MeshCore companion radio BLE protocol v3.
 * All timestamps are 4-byte little-endian unsigned Unix epoch.
 * Text is UTF-8, max 133 bytes.
 */

import 'dart:convert';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Command codes (App → Device)
// ---------------------------------------------------------------------------

class MeshCoreCmd {
  static const int appStart           = 0x01;
  static const int sendTxtMsg         = 0x02;
  static const int sendChannelTxtMsg  = 0x03;
  static const int getContacts        = 0x04;
  static const int setDeviceTime      = 0x06;
  static const int syncNextMessage    = 0x0A;
  static const int deviceQuery        = 0x16;
  static const int getChannel         = 0x1F;
  static const int sendPosition       = 0x24;
  static const int setLoginCode       = 0x3A;
}

// ---------------------------------------------------------------------------
// Response codes (Device → App)
// ---------------------------------------------------------------------------

class MeshCoreResp {
  static const int selfInfo           = 0x05;
  static const int contactsList       = 0x06;
  static const int contactMessage     = 0x07;
  static const int channelMessage     = 0x08;
  static const int noMoreMessages     = 0x09;
  static const int deviceInfo         = 0x10;
  static const int channelInfo        = 0x11;
}

// ---------------------------------------------------------------------------
// Push codes (Device → App, unsolicited)
// ---------------------------------------------------------------------------

class MeshCorePush {
  static const int logMessage         = 0x80;
  static const int advert             = 0x82;
  static const int msgWaiting         = 0x83;
  static const int sendConfirmed      = 0x84;
  static const int currentTime        = 0x85;
  static const int batteryLevel       = 0x86;
  static const int noRouteFound       = 0x87;
  static const int pathTrace          = 0x88;
  static const int loginCodeRequired  = 0x89;
  static const int rawMeshPacket      = 0x8A;
}

// ---------------------------------------------------------------------------
// Text type prefixes
// ---------------------------------------------------------------------------

class MeshCoreTxtType {
  static const int plain     = 0x00;
  static const int emojis    = 0x01;
  static const int auto      = 0x02;
}

/// Maximum text length in bytes for a single MeshCore message.
const int meshCoreMaxTextBytes = 133;

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

/// Encode `CMD_APP_START` — signals the app has connected.
Uint8List encodeAppStart() => Uint8List.fromList([MeshCoreCmd.appStart]);

/// Encode `CMD_DEVICE_QUERY` — request device info.
Uint8List encodeDeviceQuery() => Uint8List.fromList([MeshCoreCmd.deviceQuery]);

/// Encode `CMD_SET_DEVICE_TIME` — sync clock to the companion.
Uint8List encodeSetDeviceTime(DateTime time) {
  final epoch = time.toUtc().millisecondsSinceEpoch ~/ 1000;
  final data = ByteData(5);
  data.setUint8(0, MeshCoreCmd.setDeviceTime);
  data.setUint32(1, epoch, Endian.little);
  return data.buffer.asUint8List();
}

/// Encode `CMD_GET_CONTACTS` — request the full contact list.
Uint8List encodeGetContacts() => Uint8List.fromList([MeshCoreCmd.getContacts]);

/// Encode `CMD_SYNC_NEXT_MESSAGE` — poll next queued message.
Uint8List encodeSyncNextMessage() => Uint8List.fromList([MeshCoreCmd.syncNextMessage]);

/// Encode `CMD_GET_CHANNEL` — request info for channel [index] (0-7).
Uint8List encodeGetChannel(int index) =>
    Uint8List.fromList([MeshCoreCmd.getChannel, index & 0xFF]);

/// Encode `CMD_SEND_TXT_MSG` — send a direct message to a contact.
/// [pubKey32] is the recipient's 32-byte Ed25519 public key.
/// [text] is UTF-8 encoded, max 133 bytes.
/// [txtType] defaults to plain text.
Uint8List encodeSendTxtMsg(
  Uint8List pubKey32,
  String text, {
  int txtType = MeshCoreTxtType.plain,
}) {
  assert(pubKey32.length == 32, 'pubKey must be 32 bytes');
  final textBytes = utf8.encode(text);
  final epoch = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  // [cmd, txtType, pubKey:32, timestamp:4LE, text...]
  final buf = ByteData(1 + 1 + 32 + 4 + textBytes.length);
  buf.setUint8(0, MeshCoreCmd.sendTxtMsg);
  buf.setUint8(1, txtType);
  final bytes = buf.buffer.asUint8List();
  bytes.setRange(2, 34, pubKey32);
  buf.setUint32(34, epoch, Endian.little);
  bytes.setRange(38, 38 + textBytes.length, textBytes);
  return bytes;
}

/// Encode `CMD_SEND_CHANNEL_TXT_MSG` — send a message to a channel.
/// [channelIdx] is the channel index (0-7).
Uint8List encodeSendChannelTxtMsg(
  int channelIdx,
  String text, {
  int txtType = MeshCoreTxtType.plain,
}) {
  final textBytes = utf8.encode(text);
  final epoch = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  // [cmd, txtType, channelIdx, timestamp:4LE, text...]
  final buf = ByteData(1 + 1 + 1 + 4 + textBytes.length);
  buf.setUint8(0, MeshCoreCmd.sendChannelTxtMsg);
  buf.setUint8(1, txtType);
  buf.setUint8(2, channelIdx & 0xFF);
  buf.setUint32(3, epoch, Endian.little);
  final bytes = buf.buffer.asUint8List();
  bytes.setRange(7, 7 + textBytes.length, textBytes);
  return bytes;
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Base class for decoded MeshCore responses.
sealed class MeshCoreResponse {
  final int code;
  const MeshCoreResponse(this.code);
}

/// Device self-identity: returned after CMD_APP_START.
class SelfInfoResponse extends MeshCoreResponse {
  final Uint8List pubKey; // 32 bytes
  final String name;
  final double? frequency;
  final double? bandwidth;
  final int? spreadingFactor;
  final int? txPower;

  SelfInfoResponse({
    required this.pubKey,
    required this.name,
    this.frequency,
    this.bandwidth,
    this.spreadingFactor,
    this.txPower,
  }) : super(MeshCoreResp.selfInfo);
}

/// A direct message from a contact.
class ContactMessageResponse extends MeshCoreResponse {
  final Uint8List senderPrefix; // 6-byte pub key prefix
  final DateTime timestamp;
  final String text;
  final int txtType;
  final double? snr; // v3 protocol

  ContactMessageResponse({
    required this.senderPrefix,
    required this.timestamp,
    required this.text,
    this.txtType = MeshCoreTxtType.plain,
    this.snr,
  }) : super(MeshCoreResp.contactMessage);

  /// Hex-encoded sender prefix for matching against known contacts.
  String get senderPrefixHex =>
      senderPrefix.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// A channel message.
class ChannelMessageResponse extends MeshCoreResponse {
  final int channelIndex;
  final DateTime timestamp;
  final String text;
  final int txtType;
  final double? snr;
  final Uint8List? senderPrefix;

  ChannelMessageResponse({
    required this.channelIndex,
    required this.timestamp,
    required this.text,
    this.txtType = MeshCoreTxtType.plain,
    this.snr,
    this.senderPrefix,
  }) : super(MeshCoreResp.channelMessage);

  String? get senderPrefixHex =>
      senderPrefix?.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// No more queued messages — polling complete.
class NoMoreMessagesResponse extends MeshCoreResponse {
  NoMoreMessagesResponse() : super(MeshCoreResp.noMoreMessages);
}

/// Device hardware/firmware info.
class DeviceInfoResponse extends MeshCoreResponse {
  final String firmwareVersion;
  final String boardModel;

  DeviceInfoResponse({
    required this.firmwareVersion,
    required this.boardModel,
  }) : super(MeshCoreResp.deviceInfo);
}

/// Contact list entry from CMD_GET_CONTACTS.
class ContactListEntry {
  final Uint8List pubKey; // 32 bytes
  final String name;
  final int lastSeen; // Unix epoch
  final bool isRepeater;

  ContactListEntry({
    required this.pubKey,
    required this.name,
    required this.lastSeen,
    this.isRepeater = false,
  });

  String get pubKeyHex =>
      pubKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Contacts list response.
class ContactsListResponse extends MeshCoreResponse {
  final List<ContactListEntry> contacts;

  ContactsListResponse({required this.contacts})
      : super(MeshCoreResp.contactsList);
}

/// Channel info response.
class ChannelInfoResponse extends MeshCoreResponse {
  final int channelIndex;
  final String name;

  ChannelInfoResponse({required this.channelIndex, required this.name})
      : super(MeshCoreResp.channelInfo);
}

/// Push: new message waiting on device.
class PushMsgWaiting extends MeshCoreResponse {
  PushMsgWaiting() : super(MeshCorePush.msgWaiting);
}

/// Push: send confirmed (ACK received by mesh).
class PushSendConfirmed extends MeshCoreResponse {
  final Uint8List? recipientPrefix;

  PushSendConfirmed({this.recipientPrefix})
      : super(MeshCorePush.sendConfirmed);
}

/// Push: advertisement from another node.
class PushAdvert extends MeshCoreResponse {
  final Uint8List pubKey;
  final String name;
  final double? snr;

  PushAdvert({required this.pubKey, required this.name, this.snr})
      : super(MeshCorePush.advert);
}

/// Push: no route found for a message.
class PushNoRouteFound extends MeshCoreResponse {
  PushNoRouteFound() : super(MeshCorePush.noRouteFound);
}

/// Push: login code required before commands are accepted.
class PushLoginCodeRequired extends MeshCoreResponse {
  PushLoginCodeRequired() : super(MeshCorePush.loginCodeRequired);
}

/// Push: battery level report.
class PushBatteryLevel extends MeshCoreResponse {
  final int percent;

  PushBatteryLevel({required this.percent})
      : super(MeshCorePush.batteryLevel);
}

/// Unknown or unhandled response.
class UnknownResponse extends MeshCoreResponse {
  final Uint8List rawData;

  UnknownResponse(super.code, this.rawData);
}

// ---------------------------------------------------------------------------
// Decode entry point
// ---------------------------------------------------------------------------

/// Decode a raw BLE response packet from the MeshCore device.
/// The first byte is the response/push code.
MeshCoreResponse decodeResponse(Uint8List data) {
  if (data.isEmpty) return UnknownResponse(0, data);

  final code = data[0];
  final payload = data.length > 1 ? data.sublist(1) : Uint8List(0);

  switch (code) {
    case MeshCoreResp.selfInfo:
      return _decodeSelfInfo(payload);
    case MeshCoreResp.contactsList:
      return _decodeContactsList(payload);
    case MeshCoreResp.contactMessage:
      return _decodeContactMessage(payload);
    case MeshCoreResp.channelMessage:
      return _decodeChannelMessage(payload);
    case MeshCoreResp.noMoreMessages:
      return NoMoreMessagesResponse();
    case MeshCoreResp.deviceInfo:
      return _decodeDeviceInfo(payload);
    case MeshCoreResp.channelInfo:
      return _decodeChannelInfo(payload);
    case MeshCorePush.msgWaiting:
      return PushMsgWaiting();
    case MeshCorePush.sendConfirmed:
      return PushSendConfirmed(
        recipientPrefix: payload.length >= 6 ? payload.sublist(0, 6) : null,
      );
    case MeshCorePush.advert:
      return _decodeAdvert(payload);
    case MeshCorePush.noRouteFound:
      return PushNoRouteFound();
    case MeshCorePush.loginCodeRequired:
      return PushLoginCodeRequired();
    case MeshCorePush.batteryLevel:
      return PushBatteryLevel(
        percent: payload.isNotEmpty ? payload[0] : 0,
      );
    default:
      return UnknownResponse(code, data);
  }
}

// ---------------------------------------------------------------------------
// Internal decoders
// ---------------------------------------------------------------------------

SelfInfoResponse _decodeSelfInfo(Uint8List payload) {
  // [pubKey:32, name:NUL-terminated, then radio params]
  if (payload.length < 32) {
    return SelfInfoResponse(
      pubKey: Uint8List(32),
      name: '',
    );
  }

  final pubKey = payload.sublist(0, 32);
  final rest = payload.sublist(32);

  // Name is NUL-terminated
  final nameEnd = rest.indexOf(0);
  final nameBytes = nameEnd >= 0 ? rest.sublist(0, nameEnd) : rest;
  final name = utf8.decode(nameBytes, allowMalformed: true);

  // Radio params follow after name + NUL (if present)
  double? frequency, bandwidth;
  int? sf, txPower;
  final paramsStart = 32 + (nameEnd >= 0 ? nameEnd + 1 : nameBytes.length);
  if (payload.length >= paramsStart + 12) {
    final bd = ByteData.sublistView(payload, paramsStart);
    frequency = bd.getFloat32(0, Endian.little).toDouble();
    bandwidth = bd.getFloat32(4, Endian.little).toDouble();
    sf = bd.getUint8(8);
    txPower = bd.getUint8(9);
  }

  return SelfInfoResponse(
    pubKey: pubKey,
    name: name,
    frequency: frequency,
    bandwidth: bandwidth,
    spreadingFactor: sf,
    txPower: txPower,
  );
}

ContactsListResponse _decodeContactsList(Uint8List payload) {
  // Contacts are packed: [pubKey:32, flags:1, lastSeen:4LE, name:NUL-terminated]
  final contacts = <ContactListEntry>[];
  int offset = 0;

  while (offset + 37 <= payload.length) {
    final pubKey = payload.sublist(offset, offset + 32);
    final flags = payload[offset + 32];
    final bd = ByteData.sublistView(payload, offset + 33);
    final lastSeen = bd.getUint32(0, Endian.little);
    offset += 37;

    // Read NUL-terminated name
    int nameEnd = offset;
    while (nameEnd < payload.length && payload[nameEnd] != 0) {
      nameEnd++;
    }
    final name = utf8.decode(
      payload.sublist(offset, nameEnd),
      allowMalformed: true,
    );
    offset = nameEnd < payload.length ? nameEnd + 1 : nameEnd;

    contacts.add(ContactListEntry(
      pubKey: pubKey,
      name: name,
      lastSeen: lastSeen,
      isRepeater: (flags & 0x01) != 0,
    ));
  }

  return ContactsListResponse(contacts: contacts);
}

ContactMessageResponse _decodeContactMessage(Uint8List payload) {
  // [senderPrefix:6, txtType:1, timestamp:4LE, snr:1(signed), text...]
  if (payload.length < 12) {
    return ContactMessageResponse(
      senderPrefix: Uint8List(6),
      timestamp: DateTime.now().toUtc(),
      text: '',
    );
  }

  final senderPrefix = payload.sublist(0, 6);
  final txtType = payload[6];
  final bd = ByteData.sublistView(payload, 7);
  final epoch = bd.getUint32(0, Endian.little);
  final timestamp = DateTime.fromMillisecondsSinceEpoch(
    epoch * 1000,
    isUtc: true,
  );

  // SNR as signed byte (v3 protocol)
  final snrRaw = bd.getInt8(4);
  final snr = snrRaw / 4.0; // Quarter-dB resolution

  final text = utf8.decode(
    payload.sublist(12),
    allowMalformed: true,
  );

  return ContactMessageResponse(
    senderPrefix: senderPrefix,
    timestamp: timestamp,
    text: text,
    txtType: txtType,
    snr: snr,
  );
}

ChannelMessageResponse _decodeChannelMessage(Uint8List payload) {
  // [channelIdx:1, senderPrefix:6, txtType:1, timestamp:4LE, snr:1, text...]
  if (payload.length < 13) {
    return ChannelMessageResponse(
      channelIndex: 0,
      timestamp: DateTime.now().toUtc(),
      text: '',
    );
  }

  final channelIdx = payload[0];
  final senderPrefix = payload.sublist(1, 7);
  final txtType = payload[7];
  final bd = ByteData.sublistView(payload, 8);
  final epoch = bd.getUint32(0, Endian.little);
  final timestamp = DateTime.fromMillisecondsSinceEpoch(
    epoch * 1000,
    isUtc: true,
  );
  final snrRaw = bd.getInt8(4);
  final snr = snrRaw / 4.0;

  final text = utf8.decode(
    payload.sublist(13),
    allowMalformed: true,
  );

  return ChannelMessageResponse(
    channelIndex: channelIdx,
    timestamp: timestamp,
    text: text,
    txtType: txtType,
    snr: snr,
    senderPrefix: senderPrefix,
  );
}

DeviceInfoResponse _decodeDeviceInfo(Uint8List payload) {
  // Two NUL-terminated strings: firmware version and board model
  final firstNul = payload.indexOf(0);
  if (firstNul < 0) {
    return DeviceInfoResponse(
      firmwareVersion: utf8.decode(payload, allowMalformed: true),
      boardModel: '',
    );
  }

  final fw = utf8.decode(payload.sublist(0, firstNul), allowMalformed: true);
  final rest = payload.sublist(firstNul + 1);
  final secondNul = rest.indexOf(0);
  final board = secondNul >= 0
      ? utf8.decode(rest.sublist(0, secondNul), allowMalformed: true)
      : utf8.decode(rest, allowMalformed: true);

  return DeviceInfoResponse(firmwareVersion: fw, boardModel: board);
}

ChannelInfoResponse _decodeChannelInfo(Uint8List payload) {
  if (payload.isEmpty) {
    return ChannelInfoResponse(channelIndex: 0, name: '');
  }

  final idx = payload[0];
  final nameBytes = payload.sublist(1);
  final nameEnd = nameBytes.indexOf(0);
  final name = utf8.decode(
    nameEnd >= 0 ? nameBytes.sublist(0, nameEnd) : nameBytes,
    allowMalformed: true,
  );

  return ChannelInfoResponse(channelIndex: idx, name: name);
}

PushAdvert _decodeAdvert(Uint8List payload) {
  if (payload.length < 32) {
    return PushAdvert(pubKey: Uint8List(32), name: '');
  }

  final pubKey = payload.sublist(0, 32);
  final rest = payload.sublist(32);

  double? snr;
  int nameStart = 0;

  // If there's at least one byte before name, it might be SNR
  if (rest.isNotEmpty) {
    final snrRaw = ByteData.sublistView(rest).getInt8(0);
    snr = snrRaw / 4.0;
    nameStart = 1;
  }

  final nameBytes = rest.sublist(nameStart);
  final nameEnd = nameBytes.indexOf(0);
  final name = utf8.decode(
    nameEnd >= 0 ? nameBytes.sublist(0, nameEnd) : nameBytes,
    allowMalformed: true,
  );

  return PushAdvert(pubKey: pubKey, name: name, snr: snr);
}

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

/// Convert hex string to bytes.
Uint8List hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final bytes = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

/// Convert bytes to hex string.
String bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
