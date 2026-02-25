/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Pure Dart IRC client — connects to an IRC server, handles registration,
 * channel ops, message exchange, and keepalive.
 *
 * TCP socket handling runs in a background isolate (same pattern as
 * AprsIsClient). Parsed IRC events cross the isolate boundary as maps.
 * No Flutter dependency — usable from CLI station too.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../../services/log_service.dart';
import 'models/irc_server_config.dart';

/// Parameters sent to the background isolate on spawn.
class _IsolateParams {
  final SendPort sendPort;
  final String host;
  final int port;
  final bool useTls;
  final String nickname;
  final String? fallbackNickname;
  final String realname;
  final String? password;
  final List<String> autoJoinChannels;

  const _IsolateParams({
    required this.sendPort,
    required this.host,
    required this.port,
    required this.useTls,
    required this.nickname,
    this.fallbackNickname,
    this.realname = '',
    this.password,
    this.autoJoinChannels = const [],
  });
}

class IrcClient {
  final IrcServerConfig config;
  final String nickname;
  final String? fallbackNickname;
  final String realname;

  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _commandPort;

  bool _running = false;
  bool _connected = false;
  String _currentNick = '';

  /// Callback for IRC events — set by IrcService.
  void Function(Map<String, dynamic> event)? onEvent;

  IrcClient({required this.config, required this.nickname, this.fallbackNickname, this.realname = ''}) {
    _currentNick = nickname;
  }

  bool get isConnected => _connected;
  String get currentNick => _currentNick;

  /// Start the connection loop. Idempotent.
  Future<void> connect() async {
    if (_running) return;
    _running = true;
    _spawnIsolate();
  }

  /// Disconnect and stop reconnection attempts.
  void disconnect() {
    _running = false;
    _commandPort?.send({'cmd': 'stop'});
    _killIsolate();
    _connected = false;
  }

  /// Send a raw IRC line to the server.
  void sendRaw(String line) {
    if (_commandPort == null) {
      LogService().log('IrcClient[${config.id}]: _commandPort is NULL — not sent');
      return;
    }
    _commandPort!.send({'cmd': 'send', 'line': line});
  }

  /// Join a channel.
  void joinChannel(String channel) {
    sendRaw('JOIN $channel');
  }

  /// Part a channel.
  void partChannel(String channel, [String? reason]) {
    sendRaw(reason != null ? 'PART $channel :$reason' : 'PART $channel');
  }

  /// Send a PRIVMSG to a channel or user.
  void sendMessage(String target, String text) {
    // Handle /me as CTCP ACTION
    if (text.startsWith('/me ')) {
      final action = text.substring(4);
      sendRaw('PRIVMSG $target :\x01ACTION $action\x01');
    } else {
      sendRaw('PRIVMSG $target :$text');
    }
  }


  /// Send a typing notification (IRCv3 typing).
  void sendTyping(String target, bool isTyping) {
    if (_commandPort == null) return;
    _commandPort!.send({
      'cmd': 'typing',
      'target': target,
      'status': isTyping ? 'active' : 'done',
    });
  }

  /// Change nickname.
  void changeNick(String newNick) {
    sendRaw('NICK $newNick');
  }

  /// Request channel list from server.
  void requestChannelList() {
    sendRaw('LIST');
  }

  /// Request NAMES for a channel.
  void requestNames(String channel) {
    sendRaw('NAMES $channel');
  }

  /// Set channel topic.
  void setTopic(String channel, String topic) {
    sendRaw('TOPIC $channel :$topic');
  }

  // ---------------------------------------------------------------------------
  // Isolate lifecycle
  // ---------------------------------------------------------------------------

  void _spawnIsolate() {
    _receivePort = ReceivePort();
    _receivePort!.listen(_handleIsolateMessage);

    final params = _IsolateParams(
      sendPort: _receivePort!.sendPort,
      host: config.host,
      port: config.port,
      useTls: config.useTls,
      nickname: nickname,
      fallbackNickname: fallbackNickname,
      realname: realname,
      password: config.password,
      autoJoinChannels: config.autoJoinChannels,
    );

    Isolate.spawn(_isolateEntry, params).then((iso) {
      _isolate = iso;
    }).catchError((e) {
      _emitEvent({'type': 'error', 'message': 'Isolate spawn failed: $e'});
      _scheduleRespawn();
    });
  }

  void _killIsolate() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _commandPort = null;
  }

  void _scheduleRespawn() {
    if (!_running) return;
    Future.delayed(const Duration(seconds: 10), () {
      if (_running) _spawnIsolate();
    });
  }

  // ---------------------------------------------------------------------------
  // Messages from background isolate
  // ---------------------------------------------------------------------------

  void _handleIsolateMessage(dynamic msg) {
    if (msg is SendPort) {
      _commandPort = msg;
      return;
    }

    if (msg is Map) {
      final event = Map<String, dynamic>.from(msg);
      final type = event['type'] as String?;

      if (type == 'connected') {
        _connected = true;
      } else if (type == 'disconnected') {
        _connected = false;
      } else if (type == 'exited') {
        _killIsolate();
        _scheduleRespawn();
        return;
      } else if (type == 'nick_changed') {
        _currentNick = event['nick'] as String;
      }

      _emitEvent(event);
    }
  }

  void _emitEvent(Map<String, dynamic> event) {
    event['serverId'] = config.id;
    onEvent?.call(event);
  }

  // ---------------------------------------------------------------------------
  // Background isolate entry point
  // ---------------------------------------------------------------------------

  static Future<void> _isolateEntry(_IsolateParams params) async {
    final mainPort = params.sendPort;
    final cmdPort = ReceivePort();
    mainPort.send(cmdPort.sendPort);

    bool running = true;
    Socket? socket;
    Timer? pingTimer;
    bool typingCap = false;

    // Listen for commands from main isolate
    cmdPort.listen((msg) {
      if (msg is Map) {
        final cmd = msg['cmd'];
        if (cmd == 'send') {
          final line = msg['line'] as String?;
          if (line != null && socket != null) {
            try {
              socket.write('$line\r\n');
              socket.flush();
            } catch (e) {
              mainPort.send({'type': 'error', 'message': 'Send failed: $e'});
            }
          }
        } else if (cmd == 'typing') {
          final target = msg['target'] as String?;
          final status = msg['status'] as String? ?? 'active';
          if (target != null && socket != null) {
            try {
              if (typingCap) {
                socket.write('@+typing=$status TAGMSG $target\r\n');
                socket.flush();
              }
            } catch (e) {
              mainPort.send({'type': 'error', 'message': 'Typing send failed: $e'});
            }
          }
        } else if (cmd == 'stop') {
          running = false;
          pingTimer?.cancel();
          try {
            socket?.write('QUIT :Leaving\r\n');
            socket?.flush();
          } catch (_) {}
          try {
            socket?.destroy();
          } catch (_) {}
        }
      }
    });

    // Connection loop with reconnect
    while (running) {
      try {
        if (params.useTls) {
          socket = await SecureSocket.connect(
            params.host,
            params.port,
            timeout: const Duration(seconds: 15),
          );
        } else {
          socket = await Socket.connect(
            params.host,
            params.port,
            timeout: const Duration(seconds: 15),
          );
        }

        final lineBuffer = StringBuffer();
        String currentNick = params.nickname;
        bool triedFallback = false;
        bool tagsCap = false;
        bool capNegotiating = false;

        // Accumulate NAMES replies
        final namesBuffer = <String, List<String>>{};
        // Accumulate LIST replies
        final listBuffer = <Map<String, dynamic>>[];

        void handleLine(String line) {
          // Handle PING/PONG
          if (line.startsWith('PING ')) {
            final payload = line.substring(5);
            try {
              socket?.write('PONG $payload\r\n');
              socket?.flush();
            } catch (_) {}
            return;
          }

          // Parse IRC message: [:prefix] command [params] [:trailing]
          final parsed = _parseIrcLine(line);
          if (parsed == null) return;

          final command = parsed['command'] as String;
          final prefix = parsed['prefix'] as String?;
          final paramsL = parsed['params'] as List<String>;
          final trailing = parsed['trailing'] as String?;

          switch (command) {
            // CAP negotiation (IRCv3)
            case 'CAP':
              if (paramsL.length >= 2) {
                final subCmd = paramsL[1].toUpperCase();
                if (subCmd == 'LS') {
                  final caps = (trailing ?? '').split(' ').where((c) => c.isNotEmpty).toList();
                  final supported = caps.toSet();
                  final req = <String>[];
                  if (supported.contains('message-tags')) req.add('message-tags');
                  if (supported.contains('typing')) req.add('typing');
                  if (supported.contains('draft/typing')) req.add('draft/typing');
                  if (req.isNotEmpty) {
                    capNegotiating = true;
                    socket?.write('CAP REQ :${req.join(' ')}\r\n');
                    socket?.flush();
                  } else if (capNegotiating) {
                    socket?.write('CAP END\r\n');
                    socket?.flush();
                    capNegotiating = false;
                  }
                } else if (subCmd == 'ACK') {
                  final ack = (trailing ?? '').split(' ').where((c) => c.isNotEmpty).toList();
                  if (ack.contains('message-tags')) tagsCap = true;
                  if (ack.contains('typing') || ack.contains('draft/typing')) typingCap = true;
                  if (capNegotiating) {
                    socket?.write('CAP END\r\n');
                    socket?.flush();
                    capNegotiating = false;
                  }
                } else if (subCmd == 'NAK') {
                  if (capNegotiating) {
                    socket?.write('CAP END\r\n');
                    socket?.flush();
                    capNegotiating = false;
                  }
                }
              }
              break;

            // RPL_WELCOME — registration complete
            case '001':
              mainPort.send({'type': 'connected'});

              // Identify with NickServ if password configured
              if (params.password != null && params.password!.isNotEmpty) {
                socket?.write('PRIVMSG NickServ :IDENTIFY ${params.password}\r\n');
                socket?.flush();
              }

              // Auto-join channels
              for (final ch in params.autoJoinChannels) {
                if (ch.isNotEmpty) {
                  socket?.write('JOIN $ch\r\n');
                  socket?.flush();
                }
              }
              break;

            // RPL_TOPIC — channel topic
            case '332':
              if (paramsL.length >= 2 && trailing != null) {
                mainPort.send({
                  'type': 'topic',
                  'channel': paramsL[1],
                  'topic': trailing,
                });
              }
              break;

            // RPL_NAMREPLY — names list
            case '353':
              if (paramsL.length >= 3 && trailing != null) {
                final channel = paramsL[2];
                final nicks = trailing.split(' ').where((n) => n.isNotEmpty).toList();
                namesBuffer.putIfAbsent(channel, () => []).addAll(nicks);
              }
              break;

            // RPL_ENDOFNAMES
            case '366':
              if (paramsL.length >= 2) {
                final channel = paramsL[1];
                final nicks = namesBuffer.remove(channel) ?? [];
                // Strip mode prefixes (@, +, %, ~, &)
                final cleaned = nicks.map((n) {
                  if (n.isNotEmpty && '@+%~&'.contains(n[0])) return n.substring(1);
                  return n;
                }).toList();
                mainPort.send({
                  'type': 'names',
                  'channel': channel,
                  'users': cleaned,
                });
              }
              break;

            // RPL_LIST — channel list entry
            case '322':
              if (paramsL.length >= 3) {
                listBuffer.add({
                  'channel': paramsL[1],
                  'userCount': int.tryParse(paramsL[2]) ?? 0,
                  'topic': trailing ?? '',
                });
              }
              break;

            // RPL_LISTEND
            case '323':
              mainPort.send({
                'type': 'channel_list',
                'channels': List<Map<String, dynamic>>.from(listBuffer),
              });
              listBuffer.clear();
              break;

            // ERR_NICKNAMEINUSE
            case '433':
              if (!triedFallback &&
                  params.fallbackNickname != null &&
                  params.fallbackNickname!.isNotEmpty &&
                  params.fallbackNickname != currentNick) {
                // Try callsign as fallback before appending _
                currentNick = params.fallbackNickname!;
                triedFallback = true;
              } else {
                currentNick = '${currentNick}_';
              }
              socket?.write('NICK $currentNick\r\n');
              socket?.flush();
              mainPort.send({'type': 'nick_changed', 'nick': currentNick});
              break;

            // NICK change
            case 'NICK':
              final who = _extractNick(prefix);
              final newNick = trailing ?? (paramsL.isNotEmpty ? paramsL[0] : '');
              if (who == currentNick) {
                currentNick = newNick;
                mainPort.send({'type': 'nick_changed', 'nick': newNick});
              }
              mainPort.send({
                'type': 'nick_change',
                'oldNick': who,
                'newNick': newNick,
              });
              break;

            // JOIN
            case 'JOIN':
              final who = _extractNick(prefix);
              final channel = trailing ?? (paramsL.isNotEmpty ? paramsL[0] : '');
              mainPort.send({
                'type': 'join',
                'nick': who,
                'channel': channel,
              });
              break;

            // PART
            case 'PART':
              final who = _extractNick(prefix);
              final channel = paramsL.isNotEmpty ? paramsL[0] : '';
              mainPort.send({
                'type': 'part',
                'nick': who,
                'channel': channel,
                'reason': trailing ?? '',
              });
              break;

            // QUIT
            case 'QUIT':
              final who = _extractNick(prefix);
              mainPort.send({
                'type': 'quit',
                'nick': who,
                'reason': trailing ?? '',
              });
              break;

            // PRIVMSG
            case 'PRIVMSG':
              final who = _extractNick(prefix);
              final target = paramsL.isNotEmpty ? paramsL[0] : '';
              final text = trailing ?? '';

              // CTCP ACTION
              if (text.startsWith('\x01ACTION ') && text.endsWith('\x01')) {
                final action = text.substring(8, text.length - 1);
                mainPort.send({
                  'type': 'action',
                  'sender': who,
                  'target': target,
                  'text': action,
                });
              } else {
                mainPort.send({
                  'type': 'privmsg',
                  'sender': who,
                  'target': target,
                  'text': text,
                });
              }
              break;

            // TAGMSG (IRCv3 message tags, typing notifications)
            case 'TAGMSG':
              final who = _extractNick(prefix);
              final target = paramsL.isNotEmpty ? paramsL[0] : '';
              final tags = parsed['tags'] as Map<String, String>?;
              if (tags != null) {
                final typing = tags['+typing'] ?? tags['typing'] ?? tags['draft/typing'];
                if (typing != null && typing.isNotEmpty) {
                  mainPort.send({
                    'type': 'typing',
                    'sender': who,
                    'target': target,
                    'status': typing,
                  });
                }
              }
              break;

            // NOTICE
            case 'NOTICE':
              final who = _extractNick(prefix);
              final target = paramsL.isNotEmpty ? paramsL[0] : '';
              mainPort.send({
                'type': 'notice',
                'sender': who,
                'target': target,
                'text': trailing ?? '',
              });
              break;

            // TOPIC change
            case 'TOPIC':
              final channel = paramsL.isNotEmpty ? paramsL[0] : '';
              mainPort.send({
                'type': 'topic',
                'channel': channel,
                'topic': trailing ?? '',
              });
              break;

            // KICK
            case 'KICK':
              final who = _extractNick(prefix);
              final channel = paramsL.isNotEmpty ? paramsL[0] : '';
              final kicked = paramsL.length > 1 ? paramsL[1] : '';
              mainPort.send({
                'type': 'kick',
                'channel': channel,
                'kicker': who,
                'kicked': kicked,
                'reason': trailing ?? '',
              });
              break;
          }
        }

        void onData(List<int> data) {
          lineBuffer.write(utf8.decode(data, allowMalformed: true));
          final text = lineBuffer.toString();
          final lines = text.split('\n');

          lineBuffer.clear();
          if (!text.endsWith('\n')) {
            lineBuffer.write(lines.removeLast());
          } else {
            if (lines.isNotEmpty && lines.last.isEmpty) {
              lines.removeLast();
            }
          }

          for (final raw in lines) {
            final line = raw.replaceAll('\r', '').trim();
            if (line.isEmpty) continue;
            handleLine(line);
          }
        }

        // Subscribe to socket data
        final sub = socket.listen(
          onData,
          onError: (_) {},
          onDone: () {},
        );

        // CAP negotiation
        socket.write('CAP LS 302\r\n');
        await socket.flush();

        // Register: NICK + USER
        socket.write('NICK ${params.nickname}\r\n');
        final rn = params.realname.isNotEmpty ? params.realname : params.nickname;
        socket.write('USER ${params.nickname} 0 * :$rn\r\n');
        await socket.flush();

        // Client PING timer (every 120 seconds)
        pingTimer?.cancel();
        pingTimer = Timer.periodic(
          const Duration(seconds: 120),
          (_) {
            try {
              socket?.write('PING :geogram\r\n');
              socket?.flush();
            } catch (_) {}
          },
        );

        // Wait until socket closes
        final doneCompleter = Completer<void>();
        sub.onDone(() {
          if (!doneCompleter.isCompleted) doneCompleter.complete();
        });
        sub.onError((_) {
          if (!doneCompleter.isCompleted) doneCompleter.complete();
        });

        await doneCompleter.future;

        // Cleanup
        pingTimer.cancel();
        pingTimer = null;
        await sub.cancel();
        socket.destroy();
        socket = null;

        mainPort.send({'type': 'disconnected'});
      } catch (e) {
        mainPort.send({'type': 'error', 'message': 'Connect failed: $e'});
        try {
          socket?.destroy();
        } catch (_) {}
        socket = null;
      }

      // Reconnect delay
      if (running) {
        await Future.delayed(const Duration(seconds: 10));
      }
    }

    // Isolate exiting
    cmdPort.close();
    mainPort.send({'type': 'exited'});
  }

  // ---------------------------------------------------------------------------
  // IRC line parser
  // ---------------------------------------------------------------------------

  /// Parse a raw IRC line into prefix, command, params, trailing.
  /// Format: [:prefix] command [params...] [:trailing]
  static Map<String, dynamic>? _parseIrcLine(String line) {
    if (line.isEmpty) return null;

    Map<String, String>? tags;
    String? prefix;
    int idx = 0;

    // Extract tags
    if (line[0] == '@') {
      final spaceIdx = line.indexOf(' ');
      if (spaceIdx < 0) return null;
      tags = _parseTags(line.substring(1, spaceIdx));
      idx = spaceIdx + 1;
    }

    // Extract prefix
    if (idx < line.length && line[idx] == ':') {
      final spaceIdx = line.indexOf(' ');
      if (spaceIdx < 0) return null;
      prefix = line.substring(1, spaceIdx);
      idx = spaceIdx + 1;
    }

    // Find trailing
    String? trailing;
    final trailingIdx = line.indexOf(' :', idx);
    String paramsPart;
    if (trailingIdx >= 0) {
      paramsPart = line.substring(idx, trailingIdx);
      trailing = line.substring(trailingIdx + 2);
    } else {
      paramsPart = line.substring(idx);
    }

    final parts = paramsPart.split(' ').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return null;

    final command = parts[0].toUpperCase();
    final params = parts.sublist(1);

    return {
      'tags': tags,
      'prefix': prefix,
      'command': command,
      'params': params,
      'trailing': trailing,
    };
  }


  /// Parse IRCv3 message tags into a map (handles escaped tag values).
  static Map<String, String> _parseTags(String raw) {
    final tags = <String, String>{};
    if (raw.isEmpty) return tags;
    final parts = raw.split(';');
    for (final part in parts) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      if (eq == -1) {
        tags[part] = '';
      } else {
        final key = part.substring(0, eq);
        final value = part.substring(eq + 1);
        tags[key] = _unescapeTagValue(value);
      }
    }
    return tags;
  }

  /// Unescape IRCv3 tag values (\: \s \r \n \\).
  static String _unescapeTagValue(String value) {
    if (!value.contains('\\')) return value;
    final out = StringBuffer();
    for (int i = 0; i < value.length; i++) {
      final ch = value[i];
      if (ch == '\\' && i + 1 < value.length) {
        final next = value[i + 1];
        switch (next) {
          case ':':
            out.write(';');
            break;
          case 's':
            out.write(' ');
            break;
          case 'r':
            out.write('\r');
            break;
          case 'n':
            out.write('\n');
            break;
          case '\\':
            out.write('\\');
            break;
          default:
            out.write(next);
            break;
        }
        i++;
      } else {
        out.write(ch);
      }
    }
    return out.toString();
  }

  /// Extract nickname from a prefix like "nick!user@host".
  static String _extractNick(String? prefix) {
    if (prefix == null) return '';
    final bangIdx = prefix.indexOf('!');
    return bangIdx >= 0 ? prefix.substring(0, bangIdx) : prefix;
  }
}
