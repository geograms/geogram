/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Stub for xmpp_server.dart — used on web where dart:io is unavailable.
 */

class XmppS2sManager {
  bool get isRunning => false;
  Map<String, dynamic> getStatus() => {};
  Future<Map<String, dynamic>> testConnect(String domain) async => {'success': false};
}

class XmppServer {
  static XmppServer? instance;
  String get domain => '';
  bool get isRunning => false;
  bool get s2sEnabled => false;
  XmppS2sManager? get s2sManager => null;
  Map<String, dynamic> getStatus() => {'running': false};
  Map<String, dynamic>? getS2sStatus() => null;
  Future<bool> registerUser(String username, String password, {bool isAdmin = false}) async => false;
  List<Map<String, dynamic>> listUsers() => [];
  List<Map<String, dynamic>> listRooms() => [];
  bool kickFromRoom(String roomJid, String bareJid) => false;
}
