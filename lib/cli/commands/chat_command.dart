/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Chat command: list, info, create, delete, rename, history, say, delmsg
 */

import '../../station.dart';
import 'command.dart';
import 'command_context.dart';

/// chat — manage chat rooms and messages
class ChatCommand extends Command {
  @override
  String get name => 'chat';
  @override
  String get description =>
      'Manage chat rooms (list|info|create|delete|rename|history|say|delmsg)';
  @override
  String get usage => 'chat <subcommand>';
  @override
  CommandCategory get category => CommandCategory.chat;
  @override
  bool get requiresStation => true;
  @override
  List<String> get contextPaths => const ['/chat'];

  @override
  List<SubCommand> get subcommands => [
        SubCommand(
          name: 'list',
          description: 'List all chat rooms',
          execute: _list,
          completer: _roomIdCompleter,
        ),
        SubCommand(
          name: 'info',
          description: 'Show chat room details',
          execute: _info,
          completer: _roomIdCompleter,
        ),
        SubCommand(
          name: 'create',
          description: 'Create a new chat room',
          execute: _create,
        ),
        SubCommand(
          name: 'delete',
          description: 'Delete a chat room',
          execute: _delete,
          completer: _roomIdCompleter,
        ),
        SubCommand(
          name: 'rename',
          description: 'Rename a chat room',
          execute: _rename,
          completer: _roomIdCompleter,
        ),
        SubCommand(
          name: 'history',
          description: 'Show chat room message history',
          execute: _history,
          completer: _roomIdCompleter,
        ),
        SubCommand(
          name: 'say',
          description: 'Post a message to a chat room',
          execute: _say,
          completer: _roomIdCompleter,
        ),
        SubCommand(
          name: 'delmsg',
          description: 'Delete a message from a chat room',
          execute: _delmsg,
          completer: _roomIdCompleter,
        ),
      ];

  @override
  Future<void> execute(CommandContext ctx) async {
    // No sub-command — show room list
    await _list(ctx);
  }

  /// Completer that returns available chat room IDs.
  static List<String> _roomIdCompleter(CommandContext ctx) {
    final station = ctx.station as StationServer;
    return station.chatRooms.keys.toList();
  }

  // ---------------------------------------------------------------------------
  // Sub-command implementations
  // ---------------------------------------------------------------------------

  static Future<void> _list(CommandContext ctx) async {
    final station = ctx.station as StationServer;
    final rooms = station.chatRooms.values.toList();

    ctx.writeln();
    ctx.bold('Chat Rooms (${rooms.length})');
    ctx.writeln('-' * 50);

    for (final room in rooms) {
      ctx.writeln(
        '${room.id.padRight(15)} '
        '${room.name.padRight(20)} '
        '${room.messages.length} msgs',
      );
    }
    ctx.writeln();
  }

  static Future<void> _info(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    final roomId = ctx.args.isNotEmpty ? ctx.args[0] : ctx.currentChatRoom;
    if (roomId == null) {
      ctx.error('Usage: chat info <room_id>');
      return;
    }

    final room = station.chatRooms[roomId];
    if (room == null) {
      ctx.error('Room not found: $roomId');
      return;
    }

    ctx.writeln();
    ctx.bold('Chat Room: ${room.name}');
    ctx.writeln('-' * 40);
    ctx.writeln('ID:          ${room.id}');
    ctx.writeln('Name:        ${room.name}');
    ctx.writeln(
        'Description: ${room.description.isEmpty ? '(none)' : room.description}');
    ctx.writeln('Creator:     ${room.creatorCallsign}');
    ctx.writeln('Created:     ${room.createdAt.toLocal()}');
    ctx.writeln('Last Active: ${room.lastActivity.toLocal()}');
    ctx.writeln('Messages:    ${room.messages.length}');
    ctx.writeln('Public:      ${room.isPublic ? 'Yes' : 'No'}');
    ctx.writeln();
  }

  static Future<void> _create(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    if (ctx.args.length < 2) {
      ctx.error('Usage: chat create <id> <name> [description]');
      return;
    }

    final id = ctx.args[0];
    final name = ctx.args[1];
    final description = ctx.args.length > 2 ? ctx.args.sublist(2).join(' ') : null;

    final room = station.createChatRoom(id, name, description: description);
    if (room != null) {
      ctx.success('Chat room created: $name ($id)');
    } else {
      ctx.error('Room with ID "$id" already exists');
    }
  }

  static Future<void> _delete(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    final roomId = ctx.args.isNotEmpty ? ctx.args[0] : ctx.currentChatRoom;
    if (roomId == null) {
      ctx.error('Usage: chat delete <room_id>');
      return;
    }

    if (roomId == 'general') {
      ctx.error('Cannot delete the general room');
      return;
    }

    if (station.deleteChatRoom(roomId)) {
      ctx.success('Chat room deleted: $roomId');
    } else {
      ctx.error('Room not found: $roomId');
    }
  }

  static Future<void> _rename(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    String? roomId;
    String? newName;

    if (ctx.currentChatRoom != null && ctx.args.isNotEmpty) {
      // Context mode: rename <new_name>
      roomId = ctx.currentChatRoom;
      newName = ctx.args[0];
    } else if (ctx.args.length >= 2) {
      // Full mode: chat rename <room_id> <new_name>
      roomId = ctx.args[0];
      newName = ctx.args[1];
    }

    if (roomId == null || newName == null) {
      ctx.error('Usage: chat rename <room_id> <new_name>');
      return;
    }

    if (station.renameChatRoom(roomId, newName)) {
      ctx.success('Room renamed to: $newName');
    } else {
      ctx.error('Room not found: $roomId');
    }
  }

  static Future<void> _history(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    String? roomId;
    int? limit;

    if (ctx.currentChatRoom != null) {
      // Context mode: history [count]
      roomId = ctx.currentChatRoom;
      limit = ctx.args.isNotEmpty ? int.tryParse(ctx.args[0]) : null;
    } else {
      // Full mode: chat history <room_id> [count]
      if (ctx.args.isEmpty) {
        ctx.error('Usage: chat history <room_id> [count]');
        return;
      }
      roomId = ctx.args[0];
      limit = ctx.args.length > 1 ? int.tryParse(ctx.args[1]) : null;
    }

    final room = station.chatRooms[roomId];
    if (room == null) {
      ctx.error('Room not found: $roomId');
      return;
    }

    final messages = room.messages;
    if (messages.isEmpty) {
      return; // Silent if no messages
    }

    // Get last N messages
    final count = limit ?? 20;
    final startIdx = messages.length > count ? messages.length - count : 0;
    final recentMessages = messages.sublist(startIdx);

    for (final msg in recentMessages) {
      final time = msg.timestamp.toLocal();
      final timeStr = '${time.year}-'
          '${time.month.toString().padLeft(2, '0')}-'
          '${time.day.toString().padLeft(2, '0')} '
          '${time.hour.toString().padLeft(2, '0')}:'
          '${time.minute.toString().padLeft(2, '0')}';

      // Determine verification indicator
      String verifyIndicator;
      if (msg.hasSignature) {
        final isVerified = station.verifyMessage(msg);
        verifyIndicator =
            isVerified ? '\x1B[32m✓\x1B[0m' : '\x1B[31m✗\x1B[0m';
      } else {
        verifyIndicator = '\x1B[90m○\x1B[0m'; // No signature (gray circle)
      }

      ctx.writeln(
        '\x1B[33m[$timeStr]\x1B[0m $verifyIndicator '
        '\x1B[36m${msg.senderCallsign}:\x1B[0m ${msg.content}',
      );
    }
  }

  static Future<void> _say(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    String? roomId;
    String? message;

    if (ctx.currentChatRoom != null && ctx.args.isNotEmpty) {
      // Context mode: say <message...>  (room from context)
      roomId = ctx.currentChatRoom;
      message = ctx.args.join(' ');
    } else if (ctx.args.length >= 2) {
      // Full mode: chat say <room_id> <message...>
      roomId = ctx.args[0];
      message = ctx.args.sublist(1).join(' ');
    }

    if (roomId == null || message == null || message.isEmpty) {
      ctx.error('Usage: chat say <room_id> <message>');
      return;
    }

    if (station.chatRooms[roomId] == null) {
      ctx.error('Room not found: $roomId');
      return;
    }

    await station.postMessage(roomId, message);
    ctx.writeln('Message sent');
  }

  static Future<void> _delmsg(CommandContext ctx) async {
    final station = ctx.station as StationServer;

    String? roomId;
    String? messageId;

    if (ctx.currentChatRoom != null && ctx.args.length >= 1) {
      // Context mode: delmsg <message_id>
      roomId = ctx.currentChatRoom;
      messageId = ctx.args[0];
    } else if (ctx.args.length >= 2) {
      // Full mode: chat delmsg <room_id> <message_id>
      roomId = ctx.args[0];
      messageId = ctx.args[1];
    }

    if (roomId == null || messageId == null) {
      ctx.error('Usage: chat delmsg <room_id> <message_id>');
      return;
    }

    if (station.deleteMessage(roomId, messageId)) {
      ctx.success('Message deleted');
    } else {
      ctx.error('Message not found');
    }
  }
}
