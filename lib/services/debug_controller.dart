/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'package:flutter/foundation.dart';

/// Debug action types that can be triggered via API
enum DebugAction {
  /// Navigate to a specific panel
  navigateToPanel,

  /// Show a toast message
  showToast,

  /// Trigger BLE scan
  bleScan,

  /// Trigger BLE advertising
  bleAdvertise,

  /// Trigger BLE HELLO handshake with a device
  bleHello,

  /// Send data via BLE to a device
  bleSend,

  /// Refresh devices list
  refreshDevices,

  /// Trigger local network scan
  localNetworkScan,

  /// Connect to station
  connectStation,

  /// Disconnect from station
  disconnectStation,

  /// Send direct message to a device
  sendDM,

  /// Sync DMs with a device
  syncDM,
}

/// Toast message to be displayed
class ToastMessage {
  final String message;
  final Duration duration;
  final DateTime timestamp;

  ToastMessage({
    required this.message,
    this.duration = const Duration(seconds: 3),
  }) : timestamp = DateTime.now();
}

/// Debug action event with parameters
class DebugActionEvent {
  final DebugAction action;
  final Map<String, dynamic> params;
  final DateTime timestamp;

  DebugActionEvent({
    required this.action,
    this.params = const {},
  }) : timestamp = DateTime.now();

  @override
  String toString() => 'DebugActionEvent($action, $params)';
}

/// Panel indices for navigation
class PanelIndex {
  static const int collections = 0;
  static const int maps = 1;
  static const int devices = 2;
  static const int settings = 3;
  static const int logs = 4;

  /// Get panel name from index
  static String getName(int index) {
    switch (index) {
      case collections:
        return 'collections';
      case maps:
        return 'maps';
      case devices:
        return 'devices';
      case settings:
        return 'settings';
      case logs:
        return 'logs';
      default:
        return 'unknown';
    }
  }

  /// Get index from panel name
  static int? fromName(String name) {
    switch (name.toLowerCase()) {
      case 'collections':
      case 'home':
        return collections;
      case 'maps':
      case 'map':
        return maps;
      case 'devices':
      case 'bluetooth':
      case 'ble':
        return devices;
      case 'settings':
      case 'config':
        return settings;
      case 'logs':
      case 'log':
      case 'debug':
        return logs;
      default:
        return null;
    }
  }
}

/// Controller for debug actions triggered via API
/// Singleton that broadcasts actions to listeners (e.g., UI)
class DebugController {
  static final DebugController _instance = DebugController._internal();
  factory DebugController() => _instance;
  DebugController._internal();

  /// Stream controller for debug actions
  final _actionController = StreamController<DebugActionEvent>.broadcast();

  /// Stream of debug action events
  Stream<DebugActionEvent> get actionStream => _actionController.stream;

  /// Notifier for panel navigation (listened by HomePage)
  final ValueNotifier<int?> panelNotifier = ValueNotifier<int?>(null);

  /// Notifier for toast messages (listened by HomePage)
  final ValueNotifier<ToastMessage?> toastNotifier = ValueNotifier<ToastMessage?>(null);

  /// History of executed actions (for debugging)
  final List<DebugActionEvent> _actionHistory = [];
  List<DebugActionEvent> get actionHistory => List.unmodifiable(_actionHistory);

  /// Trigger a debug action
  void triggerAction(DebugAction action, {Map<String, dynamic>? params}) {
    final event = DebugActionEvent(
      action: action,
      params: params ?? {},
    );
    _actionHistory.add(event);

    // Keep only last 100 actions
    if (_actionHistory.length > 100) {
      _actionHistory.removeAt(0);
    }

    _actionController.add(event);
  }

  /// Navigate to a specific panel
  void navigateToPanel(int panelIndex) {
    panelNotifier.value = panelIndex;
    triggerAction(
      DebugAction.navigateToPanel,
      params: {'panel': panelIndex, 'name': PanelIndex.getName(panelIndex)},
    );
  }

  /// Navigate to panel by name
  bool navigateToPanelByName(String name) {
    final index = PanelIndex.fromName(name);
    if (index != null) {
      navigateToPanel(index);
      return true;
    }
    return false;
  }

  /// Show a toast message on the UI
  void showToast(String message, {int? durationSeconds}) {
    final duration = durationSeconds != null
        ? Duration(seconds: durationSeconds)
        : const Duration(seconds: 3);
    toastNotifier.value = ToastMessage(message: message, duration: duration);
    triggerAction(
      DebugAction.showToast,
      params: {'message': message, 'duration_seconds': duration.inSeconds},
    );
  }

  /// Trigger BLE scan
  void triggerBLEScan() {
    triggerAction(DebugAction.bleScan);
  }

  /// Trigger BLE advertising
  void triggerBLEAdvertise({String? callsign}) {
    triggerAction(
      DebugAction.bleAdvertise,
      params: {'callsign': callsign},
    );
  }

  /// Trigger BLE HELLO handshake with a device
  void triggerBLEHello({String? deviceId}) {
    triggerAction(
      DebugAction.bleHello,
      params: {'device_id': deviceId},
    );
  }

  /// Trigger BLE data send to a device
  void triggerBLESend({String? deviceId, String? data, int? size}) {
    triggerAction(
      DebugAction.bleSend,
      params: {
        'device_id': deviceId,
        'data': data,
        'size': size,
      },
    );
  }

  /// Trigger device refresh
  void triggerDeviceRefresh() {
    triggerAction(DebugAction.refreshDevices);
  }

  /// Trigger local network scan
  void triggerLocalNetworkScan() {
    triggerAction(DebugAction.localNetworkScan);
  }

  /// Trigger station connection
  void triggerConnectStation({String? stationUrl}) {
    triggerAction(
      DebugAction.connectStation,
      params: {'url': stationUrl},
    );
  }

  /// Trigger station disconnection
  void triggerDisconnectStation() {
    triggerAction(DebugAction.disconnectStation);
  }

  /// Trigger sending a direct message
  void triggerSendDM({required String callsign, required String content}) {
    triggerAction(
      DebugAction.sendDM,
      params: {'callsign': callsign, 'content': content},
    );
  }

  /// Trigger DM sync with a device
  void triggerSyncDM({required String callsign, String? deviceUrl}) {
    triggerAction(
      DebugAction.syncDM,
      params: {'callsign': callsign, 'url': deviceUrl},
    );
  }

  /// Get available actions for API response
  static List<Map<String, dynamic>> getAvailableActions() {
    return [
      {
        'action': 'navigate',
        'description': 'Navigate to a panel',
        'params': {
          'panel': 'Panel name: collections, maps, devices, settings, logs',
        },
      },
      {
        'action': 'toast',
        'description': 'Show a toast/snackbar message on the UI',
        'params': {
          'message': 'Text message to display',
          'duration': '(optional) Duration in seconds (default: 3)',
        },
      },
      {
        'action': 'ble_scan',
        'description': 'Start BLE device discovery scan',
        'params': {},
      },
      {
        'action': 'ble_advertise',
        'description': 'Start BLE advertising',
        'params': {
          'callsign': '(optional) Callsign to advertise',
        },
      },
      {
        'action': 'ble_hello',
        'description': 'Send HELLO handshake to a BLE device',
        'params': {
          'device_id': '(optional) BLE device ID to connect to, or first discovered device',
        },
      },
      {
        'action': 'ble_send',
        'description': 'Send data to a BLE device (for testing)',
        'params': {
          'device_id': '(optional) BLE device ID to send to',
          'data': '(optional) String data to send',
          'size': '(optional) Generate random data of this size in bytes',
        },
      },
      {
        'action': 'refresh_devices',
        'description': 'Refresh all devices (BLE, local network, station)',
        'params': {},
      },
      {
        'action': 'local_scan',
        'description': 'Scan local network for devices',
        'params': {},
      },
      {
        'action': 'connect_station',
        'description': 'Connect to a station',
        'params': {
          'url': '(optional) Station WebSocket URL',
        },
      },
      {
        'action': 'disconnect_station',
        'description': 'Disconnect from current station',
        'params': {},
      },
      {
        'action': 'send_dm',
        'description': 'Send a direct message to another device',
        'params': {
          'callsign': 'Target device callsign (required)',
          'content': 'Message content (required)',
        },
      },
      {
        'action': 'sync_dm',
        'description': 'Sync DM messages with a remote device',
        'params': {
          'callsign': 'Target device callsign (required)',
          'url': '(optional) Device URL for direct sync',
        },
      },
    ];
  }

  /// Parse and execute action from API request
  /// Returns result map with success status and message
  Map<String, dynamic> executeAction(String action, Map<String, dynamic> params) {
    switch (action.toLowerCase()) {
      case 'navigate':
        final panel = params['panel'] as String?;
        if (panel == null) {
          return {'success': false, 'error': 'Missing panel parameter'};
        }
        final success = navigateToPanelByName(panel);
        if (success) {
          return {
            'success': true,
            'message': 'Navigated to $panel panel',
            'panel_index': PanelIndex.fromName(panel),
          };
        }
        return {
          'success': false,
          'error': 'Unknown panel: $panel',
          'available': ['collections', 'maps', 'devices', 'settings', 'logs'],
        };

      case 'toast':
        final message = params['message'] as String?;
        if (message == null || message.isEmpty) {
          return {'success': false, 'error': 'Missing message parameter'};
        }
        final duration = params['duration'] as int?;
        showToast(message, durationSeconds: duration);
        return {'success': true, 'message': 'Toast displayed: $message'};

      case 'ble_scan':
        triggerBLEScan();
        return {'success': true, 'message': 'BLE scan triggered'};

      case 'ble_advertise':
        triggerBLEAdvertise(callsign: params['callsign'] as String?);
        return {'success': true, 'message': 'BLE advertising triggered'};

      case 'ble_hello':
        triggerBLEHello(deviceId: params['device_id'] as String?);
        return {'success': true, 'message': 'BLE HELLO handshake triggered'};

      case 'ble_send':
        triggerBLESend(
          deviceId: params['device_id'] as String?,
          data: params['data'] as String?,
          size: params['size'] as int?,
        );
        return {
          'success': true,
          'message': 'BLE data send triggered',
          'size': params['size'] ?? params['data']?.toString().length ?? 0,
        };

      case 'refresh_devices':
        triggerDeviceRefresh();
        return {'success': true, 'message': 'Device refresh triggered'};

      case 'local_scan':
        triggerLocalNetworkScan();
        return {'success': true, 'message': 'Local network scan triggered'};

      case 'connect_station':
        triggerConnectStation(stationUrl: params['url'] as String?);
        return {'success': true, 'message': 'Station connection triggered'};

      case 'disconnect_station':
        triggerDisconnectStation();
        return {'success': true, 'message': 'Station disconnection triggered'};

      case 'send_dm':
        final callsign = params['callsign'] as String?;
        final content = params['content'] as String?;
        if (callsign == null || callsign.isEmpty) {
          return {'success': false, 'error': 'Missing callsign parameter'};
        }
        if (content == null || content.isEmpty) {
          return {'success': false, 'error': 'Missing content parameter'};
        }
        triggerSendDM(callsign: callsign, content: content);
        return {
          'success': true,
          'message': 'DM send triggered to $callsign',
          'callsign': callsign,
        };

      case 'sync_dm':
        final callsign = params['callsign'] as String?;
        if (callsign == null || callsign.isEmpty) {
          return {'success': false, 'error': 'Missing callsign parameter'};
        }
        triggerSyncDM(callsign: callsign, deviceUrl: params['url'] as String?);
        return {
          'success': true,
          'message': 'DM sync triggered with $callsign',
          'callsign': callsign,
        };

      default:
        return {
          'success': false,
          'error': 'Unknown action: $action',
          'available_actions': getAvailableActions().map((a) => a['action']).toList(),
        };
    }
  }

  /// Dispose resources
  void dispose() {
    _actionController.close();
  }
}
