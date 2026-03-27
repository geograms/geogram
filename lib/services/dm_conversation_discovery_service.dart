/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import '../models/chat_channel.dart';
import '../models/monitored_task.dart';
import 'direct_message_service.dart';
import 'log_service.dart';
import 'task_monitor_service.dart';

class DMConversationDiscoveryService {
  static const String taskId = 'chat.dm_conversation_discovery';

  Future<List<ChatChannel>> discoverConversations() async {
    final monitor = TaskMonitorService();
    final existingTask = monitor.getTask(taskId);
    if (existingTask == null) {
      monitor.register(
        MonitoredTask(
          id: taskId,
          name: 'Direct message discovery',
          description: 'Scanning direct message conversations...',
          serviceName: 'ChatBrowser',
          priority: TaskPriority.low,
          type: TaskType.oneshot,
        ),
      );
    } else {
      existingTask.description = 'Scanning direct message conversations...';
      if (existingTask.status == TaskStatus.paused) {
        return const <ChatChannel>[];
      }
    }

    monitor.reportStart(taskId);
    try {
      final conversations = await DirectMessageService().listConversations();
      final channels = conversations
          .map(
            (conversation) => ChatChannel(
              id: conversation.otherCallsign,
              type: ChatChannelType.direct,
              name: conversation.otherCallsign,
              folder: conversation.path,
              participants: [conversation.otherCallsign],
              description: 'Direct message with ${conversation.otherCallsign}',
              created: conversation.lastMessageTime ?? DateTime.now(),
              lastMessageTime: conversation.lastMessageTime,
              unreadCount: conversation.unreadCount,
            ),
          )
          .toList();

      final task = monitor.getTask(taskId);
      if (task != null) {
        final count = channels.length;
        task.description =
            'Loaded $count direct message conversation${count == 1 ? '' : 's'}';
      }
      monitor.reportSuccess(taskId);
      return channels;
    } catch (error) {
      final task = monitor.getTask(taskId);
      if (task != null) {
        task.description = 'Failed to load direct message conversations';
      }
      monitor.reportFailure(taskId, error);
      LogService().log(
        'DMConversationDiscoveryService: Failed to discover conversations: $error',
      );
      return const <ChatChannel>[];
    }
  }
}
