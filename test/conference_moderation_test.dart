import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:geogram/server/mixins/conference_mixin.dart';
import 'package:geogram/services/conference_signaling_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConferenceSignalingServer moderation', () {
    late ConferenceSignalingServer server;
    late int port;

    setUp(() async {
      server = ConferenceSignalingServer(
        roomId: 'test@HOST',
        roomName: 'Test Room',
        hostCallsign: 'HOST',
        maxSpeakers: 6,
      );
      port = await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    /// Connect a WebSocket and send hello, returning a queue wrapper that
    /// allows reading multiple messages without "already listened" errors.
    Future<_WsQueue> connectAndHello(
      String callsign, {
      String role = 'listener',
      String? password,
    }) async {
      final ws = await WebSocket.connect('ws://localhost:$port/meet/ws');
      final q = _WsQueue(ws);
      ws.add(jsonEncode({
        'type': 'conference_hello',
        'callsign': callsign,
        'role': role,
        if (password != null) 'password': password,
      }));
      return q;
    }

    /// Connect a raw WebSocket (no hello), returning a queue wrapper.
    Future<_WsQueue> connectRaw() async {
      final ws = await WebSocket.connect('ws://localhost:$port/meet/ws');
      return _WsQueue(ws);
    }

    // ── Kick / Ban tests ──────────────────────────────────────────

    test('kick removes participant and sends conference_kicked', () async {
      final q = await connectAndHello('JOINER1');
      final welcome = await q.next;
      expect(welcome['type'], 'conference_welcome');
      expect(server.participantCount, 2); // HOST + JOINER1

      // Kick the participant
      server.kickParticipant('JOINER1');

      final kicked = await q.next;
      expect(kicked['type'], 'conference_kicked');
      expect(kicked['ban'], false);

      // Wait for socket to close
      await q.ws.done.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );

      expect(server.participantCount, 1); // Only HOST
      await q.close();
    });

    test('ban prevents rejoin', () async {
      // First connect
      final q1 = await connectAndHello('BANNED_USER');
      final welcome = await q1.next;
      expect(welcome['type'], 'conference_welcome');

      // Kick with ban
      server.kickParticipant('BANNED_USER', ban: true);
      await q1.next; // conference_kicked
      await q1.ws.done.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );

      // Try to rejoin — use raw connect + manual hello
      final q2 = await connectRaw();
      q2.ws.add(jsonEncode({
        'type': 'conference_hello',
        'callsign': 'BANNED_USER',
        'role': 'listener',
      }));

      final error = await q2.next;
      expect(error['type'], 'conference_error');
      expect(error['error'], 'banned');

      await q2.ws.done.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );

      // Verify still only host in room
      expect(server.participantCount, 1);
      await q2.close();
    });

    // ── Password tests ─────────────────────────────────────────────

    test('password-protected room rejects wrong password', () async {
      await server.stop();

      server = ConferenceSignalingServer(
        roomId: 'test@HOST',
        roomName: 'Password Room',
        hostCallsign: 'HOST',
        maxSpeakers: 6,
        password: 'secret123',
      );
      port = await server.start();

      // Try with wrong password
      final q = await connectRaw();
      q.ws.add(jsonEncode({
        'type': 'conference_hello',
        'callsign': 'JOINER1',
        'role': 'listener',
        'password': 'wrongpass',
      }));

      final error = await q.next;
      expect(error['type'], 'conference_error');
      expect(error['error'], 'invalid_password');

      await q.ws.done.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );

      expect(server.participantCount, 1); // Only HOST
      await q.close();
    });

    test('password-protected room rejects missing password', () async {
      await server.stop();

      server = ConferenceSignalingServer(
        roomId: 'test@HOST',
        roomName: 'Password Room',
        hostCallsign: 'HOST',
        maxSpeakers: 6,
        password: 'secret123',
      );
      port = await server.start();

      // Try with no password
      final q = await connectRaw();
      q.ws.add(jsonEncode({
        'type': 'conference_hello',
        'callsign': 'JOINER1',
        'role': 'listener',
      }));

      final error = await q.next;
      expect(error['type'], 'conference_error');
      expect(error['error'], 'invalid_password');
      await q.close();
    });

    test('password-protected room accepts correct password', () async {
      await server.stop();

      server = ConferenceSignalingServer(
        roomId: 'test@HOST',
        roomName: 'Password Room',
        hostCallsign: 'HOST',
        maxSpeakers: 6,
        password: 'secret123',
      );
      port = await server.start();

      final q = await connectAndHello('JOINER1', password: 'secret123');
      final welcome = await q.next;
      expect(welcome['type'], 'conference_welcome');
      expect(welcome['has_password'], true);
      expect(server.participantCount, 2);

      await q.close();
    });

    // ── Approval mode tests ──────────────────────────────────────

    test('approval mode parks joiner in waiting room', () async {
      await server.stop();

      server = ConferenceSignalingServer(
        roomId: 'test@HOST',
        roomName: 'Approval Room',
        hostCallsign: 'HOST',
        maxSpeakers: 6,
        approvalRequired: true,
      );

      final hostMessages = <Map<String, dynamic>>[];
      server.onHostMessage = (msg) => hostMessages.add(msg);

      port = await server.start();

      // Join — should get pending, not welcome
      final q = await connectAndHello('WAITER');
      final pending = await q.next;
      expect(pending['type'], 'conference_join_pending');

      // Verify host received the join request
      expect(hostMessages.any((m) => m['type'] == 'conference_join_request'),
          true);
      final joinReq = hostMessages
          .firstWhere((m) => m['type'] == 'conference_join_request');
      expect(joinReq['callsign'], 'WAITER');

      // Still only host in the room
      expect(server.participantCount, 1);

      // Approve the joiner
      server.handleJoinResponse('WAITER', approved: true);

      final welcome = await q.next;
      expect(welcome['type'], 'conference_welcome');
      expect(server.participantCount, 2);

      await q.close();
    });

    test('approval mode — denied joiner gets error', () async {
      await server.stop();

      server = ConferenceSignalingServer(
        roomId: 'test@HOST',
        roomName: 'Approval Room',
        hostCallsign: 'HOST',
        maxSpeakers: 6,
        approvalRequired: true,
      );
      server.onHostMessage = (_) {};

      port = await server.start();

      final q = await connectAndHello('DENIED_USER');
      final pending = await q.next;
      expect(pending['type'], 'conference_join_pending');

      // Deny
      server.handleJoinResponse('DENIED_USER', approved: false);

      final error = await q.next;
      expect(error['type'], 'conference_error');
      expect(error['error'], 'join_denied');

      expect(server.participantCount, 1);
      await q.close();
    });

    // ── Chat delete test ──────────────────────────────────────────

    test('deleteChatMessage broadcasts conference_chat_delete', () async {
      final q = await connectAndHello('JOINER1');
      await q.next; // welcome

      // Delete a chat message
      server.deleteChatMessage('msg-123');

      final deleteMsg = await q.next;
      expect(deleteMsg['type'], 'conference_chat_delete');
      expect(deleteMsg['conference_id'], 'msg-123');

      await q.close();
    });

    // ── Enforcement order tests ──────────────────────────────────

    test('ban check happens before password check', () async {
      await server.stop();

      server = ConferenceSignalingServer(
        roomId: 'test@HOST',
        roomName: 'Combined Room',
        hostCallsign: 'HOST',
        maxSpeakers: 6,
        password: 'secret',
        approvalRequired: true,
      );
      server.onHostMessage = (_) {};
      port = await server.start();

      // First: connect, get parked, get approved
      final q1 = await connectAndHello('BADUSER', password: 'secret');
      await q1.next; // join_pending
      server.handleJoinResponse('BADUSER', approved: true);
      await q1.next; // welcome

      // Kick with ban
      server.kickParticipant('BADUSER', ban: true);
      await q1.next; // conference_kicked
      await q1.ws.done.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );

      // Now try to rejoin with correct password — should get banned error,
      // NOT a password error or pending status
      final q2 = await connectRaw();
      q2.ws.add(jsonEncode({
        'type': 'conference_hello',
        'callsign': 'BADUSER',
        'role': 'listener',
        'password': 'secret',
      }));

      final error = await q2.next;
      expect(error['type'], 'conference_error');
      expect(error['error'], 'banned',
          reason: 'Ban check must happen before password check');
      await q2.close();
    });

    test('password check happens before approval check', () async {
      await server.stop();

      server = ConferenceSignalingServer(
        roomId: 'test@HOST',
        roomName: 'Combined Room',
        hostCallsign: 'HOST',
        maxSpeakers: 6,
        password: 'secret',
        approvalRequired: true,
      );
      server.onHostMessage = (_) {};
      port = await server.start();

      // Try to join with wrong password — should get password error,
      // NOT join_pending
      final q = await connectRaw();
      q.ws.add(jsonEncode({
        'type': 'conference_hello',
        'callsign': 'NEWUSER',
        'role': 'listener',
        'password': 'wrongpass',
      }));

      final error = await q.next;
      expect(error['type'], 'conference_error');
      expect(error['error'], 'invalid_password',
          reason: 'Password check must happen before approval check');
      await q.close();
    });

    test('correct password + approval mode → join_pending', () async {
      await server.stop();

      server = ConferenceSignalingServer(
        roomId: 'test@HOST',
        roomName: 'Combined Room',
        hostCallsign: 'HOST',
        maxSpeakers: 6,
        password: 'secret',
        approvalRequired: true,
      );
      server.onHostMessage = (_) {};
      port = await server.start();

      final q = await connectAndHello('NEWUSER', password: 'secret');
      final pending = await q.next;
      expect(pending['type'], 'conference_join_pending',
          reason:
              'Correct password + approval mode should park in waiting room');

      await q.close();
    });

    // ── Runtime settings update tests ────────────────────────────

    test('updateSettings changes password at runtime', () async {
      // No password initially
      final q1 = await connectAndHello('JOINER1');
      final welcome = await q1.next;
      expect(welcome['type'], 'conference_welcome');
      await q1.close();
      await Future.delayed(const Duration(milliseconds: 100));

      // Set password
      server.updateSettings(password: 'newpass');

      // New joiner should be rejected without password
      final q2 = await connectRaw();
      q2.ws.add(jsonEncode({
        'type': 'conference_hello',
        'callsign': 'JOINER2',
        'role': 'listener',
      }));

      final error = await q2.next;
      expect(error['type'], 'conference_error');
      expect(error['error'], 'invalid_password');

      // Should work with the new password
      final q3 = await connectAndHello('JOINER3', password: 'newpass');
      final welcome3 = await q3.next;
      expect(welcome3['type'], 'conference_welcome');

      await q2.close();
      await q3.close();
    });

    test('updateSettings toggles approval mode at runtime', () async {
      // No approval initially
      final q1 = await connectAndHello('JOINER1');
      final welcome1 = await q1.next;
      expect(welcome1['type'], 'conference_welcome');
      await q1.close();
      await Future.delayed(const Duration(milliseconds: 100));

      // Enable approval mode
      server.updateSettings(approvalRequired: true);
      server.onHostMessage = (_) {};

      // New joiner should be parked
      final q2 = await connectAndHello('JOINER2');
      final pending = await q2.next;
      expect(pending['type'], 'conference_join_pending');

      await q2.close();
    });

    // ── /meet/info endpoint includes has_password ─────────────────

    test('/meet/info reports has_password', () async {
      await server.stop();

      server = ConferenceSignalingServer(
        roomId: 'test@HOST',
        roomName: 'PW Room',
        hostCallsign: 'HOST',
        maxSpeakers: 6,
        password: 'secret',
      );
      port = await server.start();

      // Use curl via Process since TestWidgetsFlutterBinding overrides
      // HttpClient and returns 400 for all requests.
      final result = await Process.run(
          'curl', ['-s', 'http://localhost:$port/meet/info']);
      final info = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(info['has_password'], true);
    });
  });

  // ── ConferenceMixin unit tests ──────────────────────────────────

  group('ConferenceMixin moderation', () {
    late _TestConferenceMixin mixin;

    setUp(() {
      mixin = _TestConferenceMixin();
    });

    test('banned user cannot join room', () {
      // Create room
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_create',
        'room_id': 'room1',
        'room_name': 'Test',
        'max_speakers': 6,
      });

      // Join as user
      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room1',
        'role': 'listener',
      });

      // Verify joined
      final rooms = mixin.getConferenceRooms();
      expect(rooms.first['participants'], contains('JOINER'));

      // Kick with ban
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_kick',
        'room_id': 'room1',
        'callsign': 'JOINER',
        'ban': true,
      });

      // Verify kicked notification sent
      expect(
        mixin.sentMessages.any((m) {
          final msg = jsonDecode(m.data) as Map<String, dynamic>;
          return msg['type'] == 'conference_kicked';
        }),
        true,
      );

      // Try to rejoin
      mixin.sentMessages.clear();
      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room1',
        'role': 'listener',
      });

      // Should get banned error
      expect(
        mixin.sentMessages.any((m) {
          final msg = jsonDecode(m.data) as Map<String, dynamic>;
          return msg['type'] == 'conference_error' && msg['error'] == 'banned';
        }),
        true,
      );
    });

    test('password check rejects wrong password', () {
      // Create room with password
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_create',
        'room_id': 'room2',
        'room_name': 'PW Room',
        'max_speakers': 6,
        'password': 'mypass',
      });

      // Try to join without password
      mixin.sentMessages.clear();
      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room2',
        'role': 'listener',
      });

      expect(
        mixin.sentMessages.any((m) {
          final msg = jsonDecode(m.data) as Map<String, dynamic>;
          return msg['type'] == 'conference_error' &&
              msg['error'] == 'invalid_password';
        }),
        true,
      );
    });

    test('password check accepts correct password', () {
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_create',
        'room_id': 'room3',
        'room_name': 'PW Room',
        'max_speakers': 6,
        'password': 'mypass',
      });

      mixin.sentMessages.clear();
      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room3',
        'role': 'listener',
        'password': 'mypass',
      });

      expect(
        mixin.sentMessages.any((m) {
          final msg = jsonDecode(m.data) as Map<String, dynamic>;
          return msg['type'] == 'conference_welcome';
        }),
        true,
      );
    });

    test('approval mode parks joiner and approve lets them in', () {
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_create',
        'room_id': 'room4',
        'room_name': 'Approval Room',
        'max_speakers': 6,
        'approval_required': true,
      });

      mixin.sentMessages.clear();
      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room4',
        'role': 'listener',
      });

      // Joiner should get join_pending
      expect(
        mixin.sentMessages.any((m) {
          final msg = jsonDecode(m.data) as Map<String, dynamic>;
          return m.clientId == 'joiner-client' &&
              msg['type'] == 'conference_join_pending';
        }),
        true,
      );

      // Host should get join_request
      expect(
        mixin.sentMessages.any((m) {
          final msg = jsonDecode(m.data) as Map<String, dynamic>;
          return m.clientId == 'host-client' &&
              msg['type'] == 'conference_join_request' &&
              msg['callsign'] == 'JOINER';
        }),
        true,
      );

      // Not in room yet
      final rooms = mixin.getConferenceRooms();
      expect(rooms.first['participants'], isNot(contains('JOINER')));

      // Approve
      mixin.sentMessages.clear();
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_join_response',
        'room_id': 'room4',
        'callsign': 'JOINER',
        'approved': true,
      });

      // Joiner should get welcome
      expect(
        mixin.sentMessages.any((m) {
          final msg = jsonDecode(m.data) as Map<String, dynamic>;
          return m.clientId == 'joiner-client' &&
              msg['type'] == 'conference_welcome';
        }),
        true,
      );

      // Now in room
      final roomsAfter = mixin.getConferenceRooms();
      expect(roomsAfter.first['participants'], contains('JOINER'));
    });

    test('approval mode deny rejects joiner', () {
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_create',
        'room_id': 'room5',
        'room_name': 'Deny Room',
        'max_speakers': 6,
        'approval_required': true,
      });

      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room5',
        'role': 'listener',
      });

      mixin.sentMessages.clear();
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_join_response',
        'room_id': 'room5',
        'callsign': 'JOINER',
        'approved': false,
      });

      expect(
        mixin.sentMessages.any((m) {
          final msg = jsonDecode(m.data) as Map<String, dynamic>;
          return m.clientId == 'joiner-client' &&
              msg['type'] == 'conference_error' &&
              msg['error'] == 'join_denied';
        }),
        true,
      );
    });

    test('chat delete broadcasts to room', () {
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_create',
        'room_id': 'room6',
        'room_name': 'Chat Room',
        'max_speakers': 6,
      });

      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room6',
        'role': 'listener',
      });

      mixin.sentMessages.clear();
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_chat_delete',
        'room_id': 'room6',
        'conference_id': 'msg-42',
      });

      expect(
        mixin.sentMessages.any((m) {
          final msg = jsonDecode(m.data) as Map<String, dynamic>;
          return msg['type'] == 'conference_chat_delete' &&
              msg['conference_id'] == 'msg-42';
        }),
        true,
      );
    });

    test('settings update changes room state', () {
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_create',
        'room_id': 'room7',
        'room_name': 'Settings Room',
        'max_speakers': 6,
      });

      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_settings_update',
        'room_id': 'room7',
        'approval_required': true,
        'password': 'newpass',
      });

      // Now try to join without password
      mixin.sentMessages.clear();
      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room7',
        'role': 'listener',
      });

      // Should get invalid_password (not join_pending, because password
      // check comes before approval check)
      expect(
        mixin.sentMessages.any((m) {
          final msg = jsonDecode(m.data) as Map<String, dynamic>;
          return msg['type'] == 'conference_error' &&
              msg['error'] == 'invalid_password';
        }),
        true,
      );
    });

    test('enforcement order: ban → password → approval', () {
      // Create room with all protections
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_create',
        'room_id': 'room8',
        'room_name': 'Full Protection',
        'max_speakers': 6,
        'password': 'pass',
        'approval_required': true,
      });

      // Join successfully (need password, then approval)
      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room8',
        'role': 'listener',
        'password': 'pass',
      });

      // Approve
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_join_response',
        'room_id': 'room8',
        'callsign': 'JOINER',
        'approved': true,
      });

      // Now kick with ban
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_kick',
        'room_id': 'room8',
        'callsign': 'JOINER',
        'ban': true,
      });

      // Try to rejoin with correct password — should get banned,
      // not invalid_password
      mixin.sentMessages.clear();
      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room8',
        'role': 'listener',
        'password': 'pass',
      });

      final joinerResponses = mixin.sentMessages
          .where((m) => m.clientId == 'joiner-client')
          .map((m) => jsonDecode(m.data) as Map<String, dynamic>)
          .toList();

      expect(joinerResponses.length, 1);
      expect(joinerResponses.first['type'], 'conference_error');
      expect(joinerResponses.first['error'], 'banned');
    });

    test('banned user chat messages are silently dropped', () {
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_create',
        'room_id': 'room9',
        'room_name': 'Chat Guard',
        'max_speakers': 6,
      });

      // Join
      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room9',
        'role': 'listener',
      });

      // Kick with ban
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_kick',
        'room_id': 'room9',
        'callsign': 'JOINER',
        'ban': true,
      });

      // Try to send chat (if somehow still connected)
      mixin.sentMessages.clear();
      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_chat_message',
        'room_id': 'room9',
        'message': {'content': 'spam'},
      });

      // No chat messages should have been broadcast
      final chatBroadcasts = mixin.sentMessages
          .map((m) => jsonDecode(m.data) as Map<String, dynamic>)
          .where((m) => m['type'] == 'conference_chat_message')
          .toList();

      expect(chatBroadcasts, isEmpty);
    });

    test('non-host cannot kick', () {
      mixin.handleConferenceMessage('host-client', {
        'type': 'conference_create',
        'room_id': 'room10',
        'room_name': 'AuthZ Test',
        'max_speakers': 6,
      });

      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_join',
        'room_id': 'room10',
        'role': 'listener',
      });

      mixin.handleConferenceMessage('joiner2-client', {
        'type': 'conference_join',
        'room_id': 'room10',
        'role': 'listener',
      });

      // Joiner tries to kick — should be ignored
      mixin.sentMessages.clear();
      mixin.handleConferenceMessage('joiner-client', {
        'type': 'conference_kick',
        'room_id': 'room10',
        'callsign': 'JOINER2',
        'ban': true,
      });

      // No kicked message should be sent
      final kicked = mixin.sentMessages
          .map((m) => jsonDecode(m.data) as Map<String, dynamic>)
          .where((m) => m['type'] == 'conference_kicked')
          .toList();

      expect(kicked, isEmpty);

      // JOINER2 still in room
      final rooms = mixin.getConferenceRooms();
      expect(rooms.first['participants'], contains('JOINER2'));
    });
  });
}

// ── Test helpers ──────────────────────────────────────────────────

/// A message queue wrapper around a WebSocket. Listens once on the
/// underlying broadcast stream and queues messages so that multiple
/// reads don't trigger "Stream has already been listened to".
class _WsQueue {
  final WebSocket ws;
  final _queue = <Map<String, dynamic>>[];
  final _waiters = <Completer<Map<String, dynamic>>>[];
  late final StreamSubscription _sub;
  bool _done = false;

  _WsQueue(this.ws) {
    _sub = ws.listen((data) {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(msg);
      } else {
        _queue.add(msg);
      }
    }, onDone: () {
      _done = true;
      for (final w in _waiters) {
        w.completeError(StateError('WebSocket closed'));
      }
      _waiters.clear();
    }, onError: (e) {
      _done = true;
      for (final w in _waiters) {
        if (!w.isCompleted) w.completeError(e);
      }
      _waiters.clear();
    });
  }

  /// Get next message, waiting if needed.
  Future<Map<String, dynamic>> get next {
    if (_queue.isNotEmpty) {
      return Future.value(_queue.removeAt(0));
    }
    if (_done) {
      return Future.error(StateError('WebSocket closed'));
    }
    final c = Completer<Map<String, dynamic>>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 5));
  }

  Future<void> close() async {
    await _sub.cancel();
    try {
      await ws.close();
    } catch (_) {}
  }
}

class _SentMessage {
  final String clientId;
  final String data;
  _SentMessage(this.clientId, this.data);
}

class _TestConferenceMixin with ConferenceMixin {
  final List<_SentMessage> sentMessages = [];
  final Map<String, String> _clientCallsigns = {
    'host-client': 'HOST',
    'joiner-client': 'JOINER',
    'joiner2-client': 'JOINER2',
  };

  @override
  void conferenceLog(String level, String message) {
    // Silent in tests
  }

  @override
  bool conferenceSendToClient(String clientId, String data) {
    sentMessages.add(_SentMessage(clientId, data));
    return true;
  }

  @override
  String? conferenceFindClientId(String callsign) {
    for (final entry in _clientCallsigns.entries) {
      if (entry.value.toUpperCase() == callsign.toUpperCase()) {
        return entry.key;
      }
    }
    return null;
  }

  @override
  String? conferenceGetClientCallsign(String clientId) {
    return _clientCallsigns[clientId];
  }
}
