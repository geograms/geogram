/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Stub for xmpp_server.dart — used on web where dart:io is unavailable.
 */

class XmppServer {
  static XmppServer? instance;
  String get domain => '';
  bool get isRunning => false;
  Map<String, dynamic> getStatus() => {'running': false};
  Future<bool> registerUser(String username, String password, {bool isAdmin = false}) async => false;
  List<Map<String, dynamic>> listUsers() => [];
  List<Map<String, dynamic>> listRooms() => [];
  bool kickFromRoom(String roomJid, String bareJid) => false;
}
