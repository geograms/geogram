import 'package:flutter/foundation.dart';

import '../models/chat_channel.dart';
import '../models/monitored_task.dart';
import 'distributed_chat_service.dart';
import 'log_service.dart';
import 'profile_storage.dart';
import 'task_monitor_service.dart';

class DChatRoomDiscoveryService {
  static const String taskId = 'chat.dchat_room_discovery';

  Future<List<ChatChannel>> discoverRooms({
    required String appPath,
    required ProfileStorage storage,
    required String profileCallsign,
    required String profileNpub,
    String? profileNsec,
  }) async {
    final monitor = TaskMonitorService();
    final existingTask = monitor.getTask(taskId);
    if (existingTask == null) {
      monitor.register(
        MonitoredTask(
          id: taskId,
          name: 'Distributed chat discovery',
          description: 'Scanning decentralized chat rooms...',
          serviceName: 'ChatBrowser',
          priority: TaskPriority.low,
          type: TaskType.oneshot,
        ),
      );
    } else {
      existingTask.description = 'Scanning decentralized chat rooms...';
      if (existingTask.status == TaskStatus.paused) {
        return const <ChatChannel>[];
      }
    }

    monitor.reportStart(taskId);
    try {
      final roomJsonList = await compute(_discoverRoomsInBackground, {
        'appPath': appPath,
        'storageBasePath': storage.basePath,
        'storageEncrypted': storage.isEncrypted,
        'profileCallsign': profileCallsign,
        'profileNpub': profileNpub,
        'profileNsec': profileNsec,
      });
      final rooms = roomJsonList
          .map((json) => ChatChannel.fromJson(Map<String, dynamic>.from(json)))
          .toList();
      final task = monitor.getTask(taskId);
      if (task != null) {
        final count = rooms.length;
        task.description =
            'Loaded $count decentralized chat room${count == 1 ? '' : 's'}';
      }
      monitor.reportSuccess(taskId);
      return rooms;
    } catch (error) {
      final task = monitor.getTask(taskId);
      if (task != null) {
        task.description = 'Failed to load decentralized chat rooms';
      }
      monitor.reportFailure(taskId, error);
      LogService().log(
        'DChatRoomDiscoveryService: Failed to discover rooms: $error',
      );
      return const <ChatChannel>[];
    }
  }
}

Future<List<Map<String, dynamic>>> _discoverRoomsInBackground(
  Map<String, dynamic> params,
) async {
  final appPath = params['appPath'] as String;
  final storageBasePath = params['storageBasePath'] as String;
  final storageEncrypted = params['storageEncrypted'] as bool? ?? false;
  final profileCallsign = params['profileCallsign'] as String;
  final profileNpub = params['profileNpub'] as String;
  final profileNsec = params['profileNsec'] as String?;

  late final ProfileStorage storage;
  if (storageEncrypted) {
    if (profileNsec == null || profileNsec.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    storage = EncryptedProfileStorage(
      callsign: profileCallsign,
      nsec: profileNsec,
      basePath: storageBasePath,
    );
  } else {
    storage = FilesystemProfileStorage(storageBasePath);
  }

  final service = DistributedChatService(
    appPath: appPath,
    storage: storage,
    profileCallsign: profileCallsign,
    profileNpub: profileNpub,
    profileNsec: profileNsec == null || profileNsec.isEmpty
        ? null
        : profileNsec,
  );
  final rooms = await service.listRooms();
  return rooms.map((room) => room.toJson()).toList();
}
