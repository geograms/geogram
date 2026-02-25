/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

class AtprotoSession {
  final String did;
  final String handle;
  final String accessJwt;
  final String refreshJwt;

  const AtprotoSession({
    required this.did,
    required this.handle,
    required this.accessJwt,
    required this.refreshJwt,
  });

  factory AtprotoSession.fromJson(Map<String, dynamic> json) {
    return AtprotoSession(
      did: json['did'] as String? ?? '',
      handle: json['handle'] as String? ?? '',
      accessJwt: json['accessJwt'] as String? ?? '',
      refreshJwt: json['refreshJwt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'did': did,
    'handle': handle,
    'accessJwt': accessJwt,
    'refreshJwt': refreshJwt,
  };

  bool get isValid =>
      did.isNotEmpty &&
      handle.isNotEmpty &&
      accessJwt.isNotEmpty &&
      refreshJwt.isNotEmpty;
}
