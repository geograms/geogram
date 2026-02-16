import 'dart:convert';

import 'package:meta/meta.dart';

enum GeoBlueFrameType {
  hello,
  helloAck,
  data,
  broadcast,
  error,
}

extension GeoBlueFrameTypeWire on GeoBlueFrameType {
  String get wireName {
    switch (this) {
      case GeoBlueFrameType.hello:
        return 'hello';
      case GeoBlueFrameType.helloAck:
        return 'hello_ack';
      case GeoBlueFrameType.data:
        return 'data';
      case GeoBlueFrameType.broadcast:
        return 'broadcast';
      case GeoBlueFrameType.error:
        return 'error';
    }
  }

  static GeoBlueFrameType? fromWire(String? value) {
    switch (value) {
      case 'hello':
        return GeoBlueFrameType.hello;
      case 'hello_ack':
        return GeoBlueFrameType.helloAck;
      case 'data':
        return GeoBlueFrameType.data;
      case 'broadcast':
        return GeoBlueFrameType.broadcast;
      case 'error':
        return GeoBlueFrameType.error;
      default:
        return null;
    }
  }
}

@immutable
class GeoBlueProfile {
  final String callsign;
  final String? nickname;
  final String? npub;
  final String? board;
  final String? platform;

  const GeoBlueProfile({
    required this.callsign,
    this.nickname,
    this.npub,
    this.board,
    this.platform,
  });

  factory GeoBlueProfile.fromJson(Map<String, dynamic> json) {
    return GeoBlueProfile(
      callsign: json['callsign']?.toString() ?? 'NOCALL',
      nickname: json['nickname']?.toString(),
      npub: json['npub']?.toString(),
      board: json['board']?.toString(),
      platform: json['platform']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'callsign': callsign,
    };
    if (nickname != null && nickname!.isNotEmpty) {
      out['nickname'] = nickname;
    }
    if (npub != null && npub!.isNotEmpty) {
      out['npub'] = npub;
    }
    if (board != null && board!.isNotEmpty) {
      out['board'] = board;
    }
    if (platform != null && platform!.isNotEmpty) {
      out['platform'] = platform;
    }
    return out;
  }
}

@immutable
class GeoBlueFrame {
  static const int protocolVersion = 1;

  final int version;
  final String id;
  final GeoBlueFrameType type;
  final int seq;
  final int total;
  final Map<String, dynamic> payload;

  const GeoBlueFrame({
    this.version = protocolVersion,
    required this.id,
    required this.type,
    this.seq = 0,
    this.total = 1,
    required this.payload,
  });

  factory GeoBlueFrame.fromJson(Map<String, dynamic> json) {
    final type = GeoBlueFrameTypeWire.fromWire(json['type']?.toString());
    if (type == null) {
      throw ArgumentError('Unknown geoblue frame type: ${json['type']}');
    }
    return GeoBlueFrame(
      version: _asInt(json['v']) ?? protocolVersion,
      id: json['id']?.toString() ?? GeoBlueFrameId.generate(),
      type: type,
      seq: _asInt(json['seq']) ?? 0,
      total: _asInt(json['total']) ?? 1,
      payload: (json['payload'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'v': version,
      'id': id,
      'type': type.wireName,
      'seq': seq,
      'total': total,
      'payload': payload,
    };
  }

  String toJsonString() => jsonEncode(toJson());

  static int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }
}

class GeoBlueFrameId {
  static int _counter = 0;

  static String generate() {
    _counter = (_counter + 1) & 0x7fffffff;
    final now = DateTime.now().millisecondsSinceEpoch;
    return 'gb-$now-$_counter';
  }
}

class GeoBlueFrameBuilder {
  static GeoBlueFrame hello({
    required GeoBlueProfile profile,
    List<String> capabilities = const <String>['hello', 'data', 'broadcast'],
    String? id,
  }) {
    return GeoBlueFrame(
      id: id ?? GeoBlueFrameId.generate(),
      type: GeoBlueFrameType.hello,
      payload: <String, dynamic>{
        'profile': profile.toJson(),
        'capabilities': capabilities,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
    );
  }

  static GeoBlueFrame helloAck({
    required String requestId,
    required GeoBlueProfile profile,
    List<String> capabilities = const <String>['hello', 'data', 'broadcast'],
    bool success = true,
    String? message,
  }) {
    final payload = <String, dynamic>{
      'success': success,
      'profile': profile.toJson(),
      'capabilities': capabilities,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    if (message != null && message.isNotEmpty) {
      payload['message'] = message;
    }
    return GeoBlueFrame(
      id: requestId,
      type: GeoBlueFrameType.helloAck,
      payload: payload,
    );
  }

  static GeoBlueFrame data({
    required String from,
    required String content,
    String channel = 'main',
    String? to,
    String? id,
  }) {
    final payload = <String, dynamic>{
      'from': from,
      'channel': channel,
      'content': content,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    if (to != null && to.isNotEmpty) {
      payload['to'] = to;
    }
    return GeoBlueFrame(
      id: id ?? GeoBlueFrameId.generate(),
      type: GeoBlueFrameType.data,
      payload: payload,
    );
  }

  static GeoBlueFrame broadcast({
    required String from,
    required String content,
    String topic = 'general',
    String? id,
  }) {
    return GeoBlueFrame(
      id: id ?? GeoBlueFrameId.generate(),
      type: GeoBlueFrameType.broadcast,
      payload: <String, dynamic>{
        'from': from,
        'topic': topic,
        'content': content,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
    );
  }

  static GeoBlueFrame error({
    required String requestId,
    required String message,
    String? code,
  }) {
    final payload = <String, dynamic>{
      'error': message,
    };
    if (code != null && code.isNotEmpty) {
      payload['code'] = code;
    }
    return GeoBlueFrame(
      id: requestId,
      type: GeoBlueFrameType.error,
      payload: payload,
    );
  }
}
