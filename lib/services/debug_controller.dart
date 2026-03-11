/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../connection/connection_manager.dart';
import '../connection/transports/usb_aoa_transport.dart';
import 'package:path/path.dart' as path;
import 'chat_service.dart';
import 'app_service.dart';
import 'config_service.dart';
import 'profile_service.dart';
import 'storage_config.dart';
import '../util/nostr_key_generator.dart';
import 'conference_service.dart';
import 'devices_service.dart';
import 'log_service.dart';
import 'usb_aoa_service.dart';
import 'profile_storage.dart';
import 'shared_folder_service.dart';
import '../models/shared_folder.dart';
import '../teleport/bitchat/bitchat_service.dart';
import '../teleport/meshtastic/meshtastic_service.dart';
import '../teleport/meshtastic/models/meshtastic_config.dart';
import '../reader/services/manga_download_coordinator.dart';
import '../reader/services/manga_extension_service.dart';
import '../reader/utils/reader_path_utils.dart';

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

  /// Send DM via BLE to a specific callsign (bypasses ConnectionManager)
  bleSendDM,

  /// Refresh devices list
  refreshDevices,

  /// Trigger local network scan
  localNetworkScan,

  /// Connect to station
  connectStation,

  /// Disconnect from station
  disconnectStation,

  /// Refresh chat channels
  refreshChat,

  /// Send direct message to a device
  sendDM,

  /// Sync DMs with a device
  syncDM,

  /// Add a device with URL (for testing)
  addDevice,

  /// Start voice recording (for testing)
  voiceRecord,

  /// Stop voice recording and return file path (for testing)
  voiceStop,

  /// Get voice recording status (for testing)
  voiceStatus,

  /// Enable backup provider mode with settings
  backupProviderEnable,

  /// Create test data files for backup testing
  backupCreateTestData,

  /// Send backup invite to a provider
  backupSendInvite,

  /// Accept backup invite from a client (provider side)
  backupAcceptInvite,

  /// Start backup to a provider
  backupStart,

  /// Get backup status
  backupGetStatus,

  /// Start restore from a provider
  backupRestore,

  /// List backup snapshots from a provider
  backupListSnapshots,

  /// Open device detail page for a specific device
  openDeviceDetail,

  /// Open remote chat app on a device
  openRemoteChatApp,

  /// Open a specific remote chat room
  openRemoteChatRoom,

  /// Send message to remote chat room
  sendRemoteChatMessage,

  /// Open station chat app and first chat room
  openStationChat,

  /// Open external file in viewer (images, videos, PDFs from Android intent)
  openExternalFile,

  /// Open welcome page (first-launch screen)
  openWelcomePage,

  /// Open local chat collection (for testing encrypted storage)
  openLocalChat,

  /// Select a specific chat room by ID
  selectChatRoom,

  /// Send a chat message with optional image to the selected room
  sendChatMessage,

  /// Send a file in a direct message
  sendDMFile,

  /// Open DM conversation with a specific device
  openDM,

  /// Open Console collection and auto-launch first session (debug API)
  openConsole,

  /// Enable or disable mirror sync mode
  mirrorEnable,

  /// Request sync from a peer (destination side)
  mirrorRequestSync,

  /// Get current mirror sync status
  mirrorGetStatus,

  /// Add an allowed peer for sync (source side)
  mirrorAddAllowedPeer,

  /// Remove an allowed peer
  mirrorRemoveAllowedPeer,

  /// Open Mirror Settings page
  mirrorOpenSettings,

  /// Open Mirror Wizard page
  mirrorOpenWizard,

  /// Open Flasher on Monitor tab (triggered by USB attachment)
  openFlasherMonitor,

  /// P2P Transfer: Navigate to transfer panel
  p2pNavigate,

  /// P2P Transfer: Send files to a device
  p2pSend,

  /// P2P Transfer: List incoming offers
  p2pListIncoming,

  /// P2P Transfer: List outgoing offers
  p2pListOutgoing,

  /// P2P Transfer: Accept an incoming offer
  p2pAccept,

  /// P2P Transfer: Reject an incoming offer
  p2pReject,

  /// P2P Transfer: Get transfer status
  p2pStatus,

  /// Get background task monitor status
  taskStatus,

  /// Pause a monitored background task
  taskPause,

  /// Resume a paused background task
  taskResume,

  /// List all known devices with online status
  listDevices,

  /// Get encrypted storage status
  encryptStorageStatus,

  /// Enable encrypted storage (migrate to encrypted archive)
  encryptStorageEnable,

  /// Disable encrypted storage (extract to folders)
  encryptStorageDisable,

  /// List all profiles
  profileList,

  /// Delete a profile by callsign
  profileDelete,

  /// Get NOSTR relay status and feed info
  nostrStatus,

  /// Connect to a NOSTR relay
  nostrConnect,

  /// Disconnect from a NOSTR relay
  nostrDisconnect,

  /// Start the captive portal HTTP server + DNS
  hotspotPortalStart,

  /// Stop the captive portal server and DNS
  hotspotPortalStop,

  /// Get portal server status
  hotspotPortalStatus,

  /// Get Meshtastic service status
  meshtasticStatus,

  /// Enable Meshtastic service
  meshtasticEnable,

  /// Set Meshtastic log level
  meshtasticLogLevel,

  /// Search for a place on the map
  mapSearch,

  /// Route to coordinates on the map
  mapRoute,

  /// Search manga extensions
  mangaSearch,

  /// Pin user location on the map
  mapPinLocation,
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

  DebugActionEvent({required this.action, this.params = const {}})
    : timestamp = DateTime.now();

  @override
  String toString() => 'DebugActionEvent($action, $params)';
}

/// Panel indices for navigation
class PanelIndex {
  static const int apps = 0;
  static const int now = 1;
  static const int maps = 2;
  static const int devices = 3;
  static const int settings = 4;
  static const int logs = 5;

  /// Get panel name from index
  static String getName(int index) {
    switch (index) {
      case apps:
        return 'apps';
      case now:
        return 'now';
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
      case 'apps':
      case 'home':
        return apps;
      case 'now':
      case 'feed':
      case 'activity':
        return now;
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
  final ValueNotifier<ToastMessage?> toastNotifier =
      ValueNotifier<ToastMessage?>(null);

  /// History of executed actions (for debugging)
  final List<DebugActionEvent> _actionHistory = [];
  List<DebugActionEvent> get actionHistory => List.unmodifiable(_actionHistory);

  /// Trigger a debug action
  void triggerAction(DebugAction action, {Map<String, dynamic>? params}) {
    final event = DebugActionEvent(action: action, params: params ?? {});
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
    triggerAction(DebugAction.bleAdvertise, params: {'callsign': callsign});
  }

  /// Trigger BLE HELLO handshake with a device
  void triggerBLEHello({String? deviceId}) {
    triggerAction(DebugAction.bleHello, params: {'device_id': deviceId});
  }

  /// Trigger BLE data send to a device
  void triggerBLESend({String? deviceId, String? data, int? size}) {
    triggerAction(
      DebugAction.bleSend,
      params: {'device_id': deviceId, 'data': data, 'size': size},
    );
  }

  /// Trigger BLE DM send to a specific callsign (bypasses ConnectionManager)
  void triggerBLESendDM({required String callsign, required String content}) {
    triggerAction(
      DebugAction.bleSendDM,
      params: {'callsign': callsign, 'content': content},
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

  /// Trigger chat channels refresh
  Future<void> triggerChatRefresh() async {
    final chatService = ChatService();
    if (chatService.appPath != null) {
      await chatService.refreshChannels();
    }
    triggerAction(DebugAction.refreshChat);
  }

  /// Trigger station connection
  void triggerConnectStation({String? stationUrl}) {
    triggerAction(DebugAction.connectStation, params: {'url': stationUrl});
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

  /// Trigger adding a device with URL (for testing)
  void triggerAddDevice({required String callsign, required String url}) {
    triggerAction(
      DebugAction.addDevice,
      params: {'callsign': callsign, 'url': url},
    );
  }

  /// Trigger voice recording start
  void triggerVoiceRecord({String? outputDir}) {
    triggerAction(DebugAction.voiceRecord, params: {'output_dir': outputDir});
  }

  /// Trigger voice recording stop
  void triggerVoiceStop() {
    triggerAction(DebugAction.voiceStop);
  }

  /// Trigger voice status check
  void triggerVoiceStatus() {
    triggerAction(DebugAction.voiceStatus);
  }

  /// Trigger opening station chat app and first chat room
  void triggerOpenStationChat() {
    triggerAction(DebugAction.openStationChat);
  }

  /// Trigger opening local chat collection (for testing encrypted storage)
  void triggerOpenLocalChat() {
    triggerAction(DebugAction.openLocalChat);
  }

  /// Trigger opening the welcome page (for testing onboarding flow)
  void triggerOpenWelcomePage() {
    triggerAction(DebugAction.openWelcomePage);
  }

  /// Simulate the WelcomePage finalize flow: generate new identity, update profile,
  /// finalize, and clean up orphaned folders. For testing first-launch callsign bug fix.
  Future<Map<String, dynamic>> _handleWelcomeFinalize() async {
    try {
      final profileService = ProfileService();
      final profile = profileService.getProfile();
      final oldCallsign = profile.callsign;

      // Generate a new identity (simulating user choosing a different callsign)
      final keys = NostrKeyGenerator.generateKeyPair();
      profile.npub = keys.npub;
      profile.nsec = keys.nsec;
      profile.callsign = keys.callsign;

      await profileService.saveProfile(profile);
      await profileService.finalizeProfileIdentity(profile);

      // Clean up orphaned folder (same as WelcomePage._cleanupOldCallsignFolder)
      String? cleanedUp;
      if (oldCallsign != keys.callsign && oldCallsign.isNotEmpty) {
        final devicesDir = StorageConfig().devicesDir;
        final oldDir = Directory(path.join(devicesDir, oldCallsign));
        if (oldDir.existsSync()) {
          oldDir.deleteSync(recursive: true);
          cleanedUp = oldCallsign;
          LogService().log(
            'Debug: Cleaned up old callsign folder: $oldCallsign',
          );
        }
      }

      // Mark first launch complete
      ConfigService().set('firstLaunchComplete', true);

      return {
        'success': true,
        'old_callsign': oldCallsign,
        'new_callsign': keys.callsign,
        'cleaned_up': cleanedUp,
        'message': 'Profile finalized with new callsign',
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Trigger selecting a chat room by ID
  void triggerSelectChatRoom(String roomId) {
    triggerAction(DebugAction.selectChatRoom, params: {'room_id': roomId});
  }

  /// Trigger sending a chat message with optional image
  void triggerSendChatMessage({String? content, String? imagePath}) {
    triggerAction(
      DebugAction.sendChatMessage,
      params: {'content': content ?? '', 'image_path': imagePath},
    );
  }

  /// Trigger sending a file in a direct message
  void triggerSendDMFile({required String callsign, required String filePath}) {
    triggerAction(
      DebugAction.sendDMFile,
      params: {'callsign': callsign, 'file_path': filePath},
    );
  }

  /// Trigger opening DM conversation with a device
  void triggerOpenDM({required String callsign}) {
    triggerAction(DebugAction.openDM, params: {'callsign': callsign});
  }

  /// Trigger opening the Console collection (for debug API automation)
  void triggerOpenConsole({String? sessionId}) {
    triggerAction(DebugAction.openConsole, params: {'session_id': sessionId});
  }

  /// Trigger mirror enable/disable
  void triggerMirrorEnable({required bool enabled}) {
    triggerAction(DebugAction.mirrorEnable, params: {'enabled': enabled});
  }

  /// Trigger mirror sync request from a peer
  void triggerMirrorRequestSync({
    required String peerUrl,
    required String folder,
  }) {
    triggerAction(
      DebugAction.mirrorRequestSync,
      params: {'peer_url': peerUrl, 'folder': folder},
    );
  }

  /// Trigger mirror status request
  void triggerMirrorGetStatus() {
    triggerAction(DebugAction.mirrorGetStatus);
  }

  /// Add an allowed peer for mirror sync
  void triggerMirrorAddAllowedPeer({
    required String npub,
    required String callsign,
  }) {
    triggerAction(
      DebugAction.mirrorAddAllowedPeer,
      params: {'npub': npub, 'callsign': callsign},
    );
  }

  /// Remove an allowed peer from mirror sync
  void triggerMirrorRemoveAllowedPeer({required String npub}) {
    triggerAction(DebugAction.mirrorRemoveAllowedPeer, params: {'npub': npub});
  }

  /// Trigger opening Mirror Settings page
  void triggerMirrorOpenSettings() {
    triggerAction(DebugAction.mirrorOpenSettings);
  }

  /// Trigger opening Mirror Wizard page
  void triggerMirrorOpenWizard() {
    triggerAction(DebugAction.mirrorOpenWizard);
  }

  /// Trigger opening Flasher on Monitor tab with optional auto-connect
  void triggerOpenFlasherMonitor({String? devicePath}) {
    triggerAction(
      DebugAction.openFlasherMonitor,
      params: {'device_path': devicePath},
    );
  }

  /// Trigger external file viewer navigation
  void triggerOpenExternalFile({required String path, String? mimeType}) {
    triggerAction(
      DebugAction.openExternalFile,
      params: {'path': path, 'mimeType': mimeType},
    );
  }

  /// Trigger P2P transfer navigation
  void triggerP2PNavigate() {
    triggerAction(DebugAction.p2pNavigate);
  }

  /// Trigger P2P send files
  void triggerP2PSend({required String callsign, required String folder}) {
    triggerAction(
      DebugAction.p2pSend,
      params: {'callsign': callsign, 'folder': folder},
    );
  }

  /// Trigger P2P list incoming offers
  void triggerP2PListIncoming() {
    triggerAction(DebugAction.p2pListIncoming);
  }

  /// Trigger P2P list outgoing offers
  void triggerP2PListOutgoing() {
    triggerAction(DebugAction.p2pListOutgoing);
  }

  /// Trigger P2P accept offer
  void triggerP2PAccept({
    required String offerId,
    required String destination,
  }) {
    triggerAction(
      DebugAction.p2pAccept,
      params: {'offer_id': offerId, 'destination': destination},
    );
  }

  /// Trigger P2P reject offer
  void triggerP2PReject({required String offerId}) {
    triggerAction(DebugAction.p2pReject, params: {'offer_id': offerId});
  }

  /// Trigger P2P status check
  void triggerP2PStatus({required String offerId}) {
    triggerAction(DebugAction.p2pStatus, params: {'offer_id': offerId});
  }

  /// Get available actions for API response
  static List<Map<String, dynamic>> getAvailableActions() {
    return [
      {
        'action': 'navigate',
        'description': 'Navigate to a panel',
        'params': {'panel': 'Panel name: apps, maps, devices, settings, logs'},
      },
      {
        'action': 'map_search',
        'description': 'Search for a place on the map by name or coordinates',
        'params': {
          'query':
              'Search query (place name or coordinates like "38.72, -9.14")',
        },
      },
      {
        'action': 'map_route',
        'description':
            'Calculate route from current map center to coordinates (auto-downloads road data if needed)',
        'params': {
          'toLat': 'Destination latitude',
          'toLon': 'Destination longitude',
          'mode':
              '(optional) Travel mode: driving or walking (default: driving)',
        },
      },
      {
        'action': 'map_pin_location',
        'description': 'Pin user location on the map at specific coordinates',
        'params': {'lat': 'Latitude', 'lon': 'Longitude'},
      },
      {
        'action': 'manga_search',
        'description': 'Search manga extensions for a title',
        'params': {
          'query': 'Search query (manga title)',
          'extension_id': '(optional) Specific extension ID, or searches all',
        },
      },
      {
        'action': 'manga_browse',
        'description':
            'Browse a catalog page (popular, latest) from an extension',
        'params': {
          'extension_id': 'Extension ID (e.g. mangapill)',
          'tab': '(optional) Browse tab index (default: 0)',
        },
      },
      {
        'action': 'manga_download',
        'description': 'Download manga chapters via background coordinator',
        'params': {
          'extension_id': 'Extension ID (e.g. mangapill)',
          'manga_id': 'Manga ID/URL from extension',
          'manga_title': 'Manga title (used for folder name)',
          'max_chapters': '(optional) Max chapters to download (default: 1)',
        },
      },
      {
        'action': 'manga_download_status',
        'description': 'Get manga download coordinator status',
        'params': {},
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
        'params': {'callsign': '(optional) Callsign to advertise'},
      },
      {
        'action': 'ble_hello',
        'description': 'Send HELLO handshake to a BLE device',
        'params': {
          'device_id':
              '(optional) BLE device ID to connect to, or first discovered device',
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
        'action': 'ble_send_dm',
        'description': 'Send DM directly via BLE (bypasses LAN/Station)',
        'params': {
          'callsign': 'Target device callsign (required)',
          'content': 'Message content (required)',
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
        'action': 'usb_status',
        'description': 'Get USB AOA transport diagnostic status',
        'params': {},
      },
      {
        'action': 'usb_restart_hello',
        'description': 'Restart USB AOA hello handshake retry mechanism',
        'params': {},
      },
      {
        'action': 'refresh_chat',
        'description': 'Refresh chat channels from channels.json',
        'params': {},
      },
      {
        'action': 'connect_station',
        'description': 'Connect to a station',
        'params': {'url': '(optional) Station WebSocket URL'},
      },
      {
        'action': 'disconnect_station',
        'description': 'Disconnect from current station',
        'params': {},
      },
      {
        'action': 'bot_download_model',
        'description': 'Download a bot model via TransferService',
        'params': {
          'model_type': 'Model type: vision or music (required)',
          'model_id': 'Model ID to download (required)',
          'station_url': '(optional) Station URL override',
          'station_callsign': '(optional) Station callsign override',
        },
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
      {
        'action': 'add_device',
        'description': 'Add a device with URL (for testing DM auto-push)',
        'params': {
          'callsign': 'Device callsign (required)',
          'url': 'Device HTTP API URL (required)',
        },
      },
      {
        'action': 'voice_record',
        'description': 'Start voice recording (for testing)',
        'params': {
          'duration':
              '(optional) Max recording duration in seconds (default: 5)',
        },
      },
      {
        'action': 'voice_stop',
        'description': 'Stop voice recording and get file path',
        'params': {},
      },
      {
        'action': 'voice_status',
        'description': 'Get voice recording status',
        'params': {},
      },
      {
        'action': 'backup_provider_enable',
        'description': 'Enable backup provider mode with storage settings',
        'params': {
          'enabled': '(optional) true/false (default: true)',
          'max_storage_gb': '(optional) Max total storage in GB (default: 10)',
          'max_client_storage_gb':
              '(optional) Max per-client storage in GB (default: 1)',
          'max_snapshots': '(optional) Max snapshots per client (default: 10)',
        },
      },
      {
        'action': 'backup_create_test_data',
        'description': 'Create test files for backup testing',
        'params': {
          'file_count': '(optional) Number of files to create (default: 5)',
          'file_size_kb': '(optional) Size of each file in KB (default: 10)',
        },
      },
      {
        'action': 'backup_send_invite',
        'description': 'Send backup invite to a provider device',
        'params': {
          'callsign': 'Target provider callsign (required)',
          'interval_days': '(optional) Backup interval in days (default: 1)',
        },
      },
      {
        'action': 'backup_accept_invite',
        'description': 'Accept backup invite from a client (provider side)',
        'params': {
          'client_npub': 'Client NPUB (required)',
          'client_callsign': 'Client callsign (required)',
          'max_storage_gb': '(optional) Storage quota in GB (default: 1)',
          'max_snapshots': '(optional) Max snapshots (default: 10)',
        },
      },
      {
        'action': 'backup_start',
        'description': 'Start backup to a provider',
        'params': {'provider_callsign': 'Provider callsign (required)'},
      },
      {
        'action': 'backup_status',
        'description': 'Get current backup/restore status',
        'params': {},
      },
      {
        'action': 'backup_restore',
        'description': 'Start restore from a provider snapshot',
        'params': {
          'provider_callsign': 'Provider callsign (required)',
          'snapshot_id': 'Snapshot date YYYY-MM-DD (required)',
        },
      },
      {
        'action': 'backup_list_snapshots',
        'description': 'List available snapshots from a provider',
        'params': {'provider_callsign': 'Provider callsign (required)'},
      },
      {
        'action': 'place_like',
        'description': 'Toggle like for a place via station feedback API',
        'params': {
          'place_id': 'Place folder name (required)',
          'callsign': '(optional) Place owner callsign for local cache update',
          'place_path':
              '(optional) Absolute path to place folder for local cache update',
        },
      },
      {
        'action': 'place_comment',
        'description': 'Add a comment to a place via station feedback API',
        'params': {
          'place_id': 'Place folder name (required)',
          'content': 'Comment text (required)',
          'author': '(optional) Comment author callsign',
          'npub': '(optional) Comment author npub',
          'callsign': '(optional) Place owner callsign for local cache update',
          'place_path':
              '(optional) Absolute path to place folder for local cache update',
        },
      },
      {
        'action': 'open_station_chat',
        'description':
            'Open chat app and first chat room of the connected station',
        'params': {},
      },
      {
        'action': 'welcome_open',
        'description': 'Open the Welcome page (first-launch screen)',
        'params': {},
      },
      {
        'action': 'welcome_finalize',
        'description':
            'Simulate finalizing the Welcome page with a new identity (for testing first-launch flow)',
        'params': {},
      },
      {
        'action': 'select_chat_room',
        'description':
            'Select a chat room by ID in the currently open chat browser',
        'params': {'room_id': 'Room ID to select (e.g., "general")'},
      },
      {
        'action': 'send_chat_message',
        'description':
            'Send a message with optional image to the selected chat room',
        'params': {
          'content': '(optional) Message text',
          'image_path': '(optional) Path to image file to attach',
        },
      },
      {
        'action': 'send_dm_file',
        'description': 'Send a file in a direct message to another device',
        'params': {
          'callsign': 'Target device callsign (required)',
          'file_path': 'Absolute path to the file to send (required)',
        },
      },
      {
        'action': 'open_dm',
        'description': 'Open direct message conversation with a device',
        'params': {'callsign': 'Target device callsign (required)'},
      },
      {
        'action': 'open_console',
        'description':
            'Open the Console collection and auto-launch the first session',
        'params': {
          'session_id':
              '(optional) Session ID to focus (default: first session)',
        },
      },
      {
        'action': 'console_status',
        'description': 'Get Console terminal status and logs',
        'params': {},
      },
      {
        'action': 'mirror_enable',
        'description': 'Enable or disable mirror sync mode',
        'params': {'enabled': 'true/false (required)'},
      },
      {
        'action': 'mirror_request_sync',
        'description': 'Request simple mirror sync from a peer',
        'params': {
          'peer_url':
              'Peer HTTP URL, e.g., http://192.168.1.100:3456 (required)',
          'folder': 'Folder path to sync, e.g., collections/blog (required)',
          'peer_callsign': 'Peer callsign, e.g., X1ABC (required)',
        },
      },
      {
        'action': 'mirror_get_status',
        'description': 'Get current mirror sync status',
        'params': {},
      },
      {
        'action': 'mirror_add_allowed_peer',
        'description': 'Add a peer allowed to sync from this device',
        'params': {
          'npub': 'Peer NOSTR public key (required)',
          'callsign': 'Peer callsign for logging (required)',
        },
      },
      {
        'action': 'mirror_remove_allowed_peer',
        'description': 'Remove an allowed sync peer',
        'params': {'npub': 'Peer NOSTR public key to remove (required)'},
      },
      {
        'action': 'mirror_sync_all',
        'description': 'Full sync with all configured peers and enabled apps',
        'params': {},
      },
      {
        'action': 'mirror_config',
        'description':
            'Show current mirror configuration (peers, apps, addresses)',
        'params': {},
      },
      {
        'action': 'mirror_open_settings',
        'description': 'Open Mirror Settings page on the device',
        'params': {},
      },
      {
        'action': 'mirror_open_wizard',
        'description': 'Open Mirror Wizard page on the device',
        'params': {},
      },
      {
        'action': 'profile_list',
        'description': 'List all profiles with their IDs and callsigns',
        'params': {},
      },
      {
        'action': 'profile_delete',
        'description': 'Delete a profile by callsign',
        'params': {'callsign': 'Callsign of the profile to delete (required)'},
      },
      {
        'action': 'open_flasher_monitor',
        'description': 'Open Flasher on Monitor tab with optional auto-connect',
        'params': {
          'device_path': '(optional) Serial port path to auto-connect',
        },
      },
      {
        'action': 'p2p_navigate',
        'description': 'Navigate to P2P Transfer panel',
        'params': {},
      },
      {
        'action': 'p2p_send',
        'description': 'Send files to another device via P2P transfer',
        'params': {
          'callsign': 'Target device callsign (required)',
          'folder':
              'Absolute path to folder containing files to send (required)',
        },
      },
      {
        'action': 'p2p_list_incoming',
        'description': 'List pending incoming transfer offers',
        'params': {},
      },
      {
        'action': 'p2p_list_outgoing',
        'description': 'List pending outgoing transfer offers',
        'params': {},
      },
      {
        'action': 'p2p_accept',
        'description': 'Accept an incoming transfer offer',
        'params': {
          'offer_id': 'Offer ID to accept (required)',
          'destination': 'Absolute path to destination folder (required)',
        },
      },
      {
        'action': 'p2p_reject',
        'description': 'Reject an incoming transfer offer',
        'params': {'offer_id': 'Offer ID to reject (required)'},
      },
      {
        'action': 'p2p_status',
        'description': 'Get status of a transfer offer',
        'params': {'offer_id': 'Offer ID to check (required)'},
      },
      {
        'action': 'list_devices',
        'description': 'List all known devices with online status',
        'params': {},
      },
      {
        'action': 'encrypt_storage_status',
        'description': 'Get encrypted storage status for current profile',
        'params': {},
      },
      {
        'action': 'encrypt_storage_enable',
        'description':
            'Enable encrypted storage for current profile (migrate files to encrypted archive)',
        'params': {
          'nsec':
              '(optional) NOSTR secret key for encryption - uses profile nsec if not provided',
        },
      },
      {
        'action': 'encrypt_storage_disable',
        'description':
            'Disable encrypted storage for current profile (extract files to folders)',
        'params': {
          'nsec':
              '(optional) NOSTR secret key for decryption - uses profile nsec if not provided',
        },
      },
      {
        'action': 'conference_host',
        'description': 'Host a new SFU audio conference (LAN or station mode)',
        'params': {
          'room_name': '(optional) Meeting name (default: "Test Meeting")',
          'max_speakers': '(optional) Max speakers including host (default: 6)',
        },
      },
      {
        'action': 'conference_join',
        'description': 'Join an existing conference',
        'params': {
          'url':
              '(optional) WebSocket URL for LAN mode (ws://host:port/meet/ws)',
          'room_id': '(optional) Room ID for station mode',
          'role': '(optional) "speaker" or "listener" (default: "listener")',
        },
      },
      {
        'action': 'conference_status',
        'description': 'Get current conference status',
        'params': {},
      },
      {
        'action': 'conference_end',
        'description': 'End or leave the current conference',
        'params': {},
      },
      {
        'action': 'conference_mute',
        'description': 'Toggle mute in current conference',
        'params': {},
      },
      {
        'action': 'conference_request_speaker',
        'description': 'Request speaker access from the host (listener only)',
        'params': {},
      },
      {
        'action': 'conference_start_screen_share',
        'description': 'Start sharing the local screen in the current meeting',
        'params': {},
      },
      {
        'action': 'conference_stop_screen_share',
        'description': 'Stop sharing the local screen in the current meeting',
        'params': {},
      },
      {
        'action': 'conference_request_screen_share',
        'description':
            'Request host permission to share the local screen (joiner only)',
        'params': {},
      },
      {
        'action': 'conference_send_chat',
        'description': 'Send a text message to the meeting chat',
        'params': {'content': 'Message text (required)'},
      },
      {
        'action': 'conference_promote',
        'description': 'Promote a listener to speaker (host only)',
        'params': {'callsign': 'Callsign of participant to promote (required)'},
      },
      {
        'action': 'conference_demote',
        'description': 'Demote a speaker to listener (host only)',
        'params': {'callsign': 'Callsign of participant to demote (required)'},
      },
      {
        'action': 'conference_approve_screen_share',
        'description': 'Approve a participant screen-share request (host only)',
        'params': {
          'callsign':
              'Callsign of participant to approve for screen sharing (required)',
        },
      },
      {
        'action': 'create_app',
        'description': 'Create a new app/collection by type',
        'params': {
          'type': 'App type (required, e.g. conference, chat, blog)',
          'title': '(optional) App title (default: type name)',
        },
      },
      {
        'action': 'open_app',
        'description': 'Open an existing app by type',
        'params': {'type': 'App type to open (required)'},
      },
      {
        'action': 'shared_add',
        'description': 'Add a shared folder entry to the Shared app',
        'params': {
          'title': 'Folder title (required)',
          'location': 'Absolute path to folder on disk (required)',
          'visibility':
              '(optional) public, private, restricted (default: public)',
          'description': '(optional) Folder description',
        },
      },
      {
        'action': 'shared_list',
        'description': 'List all shared folder entries',
        'params': {},
      },
      {
        'action': 'bitchat_status',
        'description':
            'Get BitChat service status (identity, BLE state, peers, messages)',
        'params': {},
      },
      {
        'action': 'bitchat_enable',
        'description':
            'Enable BitChat service (generate identity if needed, start BLE)',
        'params': {},
      },
      {
        'action': 'meshtastic_status',
        'description':
            'Get Meshtastic service status (BLE state, nodes, channels, messages)',
        'params': {},
      },
      {
        'action': 'meshtastic_enable',
        'description': 'Enable Meshtastic service (create config if needed)',
        'params': {},
      },
      {
        'action': 'meshtastic_log_level',
        'description':
            'Set Meshtastic log level (off, error, warn, info, debug)',
        'params': {'level': 'string (off|error|warn|info|debug)'},
      },
    ];
  }

  /// Parse and execute action from API request
  /// Returns result map with success status and message
  Future<Map<String, dynamic>> executeAction(
    String action,
    Map<String, dynamic> params,
  ) async {
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
          'available': ['apps', 'maps', 'devices', 'settings', 'logs'],
        };

      case 'map_search':
        final query = params['query'] as String?;
        if (query == null || query.isEmpty) {
          return {'success': false, 'error': 'Missing query parameter'};
        }
        // Navigate to maps panel first
        navigateToPanelByName('maps');
        // Fire debug action event for the maps page to handle
        _actionController.add(
          DebugActionEvent(action: DebugAction.mapSearch, params: params),
        );
        return {'success': true, 'message': 'Map search triggered for: $query'};

      case 'map_route':
        final toLat = params['toLat'];
        final toLon = params['toLon'];
        if (toLat == null || toLon == null) {
          return {'success': false, 'error': 'Missing toLat/toLon parameters'};
        }
        navigateToPanelByName('maps');
        _actionController.add(
          DebugActionEvent(action: DebugAction.mapRoute, params: params),
        );
        return {
          'success': true,
          'message': 'Map route triggered to: $toLat, $toLon',
        };

      case 'map_pin_location':
        final lat = params['lat'];
        final lon = params['lon'];
        if (lat == null || lon == null) {
          return {'success': false, 'error': 'Missing lat/lon parameters'};
        }
        navigateToPanelByName('maps');
        _actionController.add(
          DebugActionEvent(action: DebugAction.mapPinLocation, params: params),
        );
        return {
          'success': true,
          'message': 'Map pin location set to: $lat, $lon',
        };

      case 'manga_search':
        final query = params['query'] as String?;
        if (query == null || query.isEmpty) {
          return {'success': false, 'error': 'Missing query parameter'};
        }
        try {
          final extService = MangaExtensionService();
          if (!extService.isInitialized) {
            final appsPath = AppService().getDefaultAppsPath();
            final readerPath = '$appsPath/reader';
            final extensionsDir = ReaderPathUtils.extensionsDir(readerPath);
            await extService.initialize(extensionsDir);
          }
          final extensionId = params['extension_id'] as String?;
          List<ExtensionSearchResult> results;
          if (extensionId != null) {
            final searchResults = await extService.search(extensionId, query);
            results = searchResults
                .map(
                  (r) => ExtensionSearchResult(
                    extensionId: extensionId,
                    result: r,
                  ),
                )
                .toList();
          } else {
            results = await extService.searchAllExtensions(query);
          }
          return {
            'success': true,
            'extensions': extService.extensions
                .map((e) => {'id': e.id, 'name': e.name})
                .toList(),
            'results': results
                .map(
                  (r) => {
                    'extension': r.extensionId,
                    'id': r.result.id,
                    'title': r.result.title,
                    'thumbnail': r.result.thumbnail,
                  },
                )
                .toList(),
          };
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }

      case 'manga_browse':
        try {
          final extService = MangaExtensionService();
          if (!extService.isInitialized) {
            final appsPath = AppService().getDefaultAppsPath();
            final readerPath = '$appsPath/reader';
            final extensionsDir = ReaderPathUtils.extensionsDir(readerPath);
            await extService.initialize(extensionsDir);
          }
          final extensionId = params['extension_id'] as String?;
          if (extensionId == null || extensionId.isEmpty) {
            return {
              'success': false,
              'error': 'Missing extension_id parameter',
            };
          }
          final tabIndex = int.tryParse(params['tab']?.toString() ?? '0') ?? 0;
          final ext = extService.getExtension(extensionId);
          if (ext == null) {
            return {
              'success': false,
              'error': 'Extension not found: $extensionId',
            };
          }
          final results = await extService.browse(extensionId, tabIndex);
          return {
            'success': true,
            'extension': extensionId,
            'tab': tabIndex,
            'tab_name': tabIndex < ext.browse.length
                ? ext.browse[tabIndex].name
                : 'unknown',
            'count': results.length,
            'results': results
                .take(10)
                .map(
                  (r) => {
                    'id': r.id,
                    'title': r.title,
                    'thumbnail': r.thumbnail,
                  },
                )
                .toList(),
          };
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }

      case 'manga_detail':
        try {
          final extService = MangaExtensionService();
          if (!extService.isInitialized) {
            final appsPath = AppService().getDefaultAppsPath();
            final readerPath = '$appsPath/reader';
            final extensionsDir = ReaderPathUtils.extensionsDir(readerPath);
            await extService.initialize(extensionsDir);
          }
          final extensionId = params['extension_id'] as String?;
          final mangaId = params['manga_id'] as String?;
          if (extensionId == null || mangaId == null) {
            return {
              'success': false,
              'error': 'Missing extension_id or manga_id',
            };
          }
          final seriesInfo = await extService.getSeriesInfo(
            extensionId,
            mangaId,
          );
          final chapters = await extService.listChapters(extensionId, mangaId);
          return {
            'success': true,
            'series_info': seriesInfo,
            'chapters_count': chapters.length,
            'first_chapters': chapters
                .take(3)
                .map((c) => {'id': c.id, 'number': c.number, 'title': c.title})
                .toList(),
            'last_chapters': chapters.length > 3
                ? chapters
                      .skip(chapters.length - 3)
                      .map(
                        (c) => {
                          'id': c.id,
                          'number': c.number,
                          'title': c.title,
                        },
                      )
                      .toList()
                : [],
          };
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }

      case 'manga_download':
        try {
          final extService = MangaExtensionService();
          if (!extService.isInitialized) {
            final appsPath = AppService().getDefaultAppsPath();
            final readerPath = '$appsPath/reader';
            final extensionsDir = ReaderPathUtils.extensionsDir(readerPath);
            await extService.initialize(extensionsDir);
          }
          final extensionId = params['extension_id'] as String?;
          final mangaId = params['manga_id'] as String?;
          final mangaTitle = params['manga_title'] as String?;
          final maxChapters = params['max_chapters'] as int? ?? 1;
          if (extensionId == null || mangaId == null || mangaTitle == null) {
            return {
              'success': false,
              'error': 'Missing extension_id, manga_id, or manga_title',
            };
          }
          final chapters = await extService.listChapters(extensionId, mangaId);
          if (chapters.isEmpty) {
            return {'success': false, 'error': 'No chapters found'};
          }
          final appsPath = AppService().getDefaultAppsPath();
          final readerPath = '$appsPath/reader';
          final slug = ReaderPathUtils.slugify(mangaTitle);
          final seriesDir = '$readerPath/manga/library/series/$slug';
          // Ensure directory exists
          final dir = Directory(seriesDir);
          if (!await dir.exists()) await dir.create(recursive: true);
          // Ensure library source exists
          final dataFile = File('$readerPath/manga/library/data.json');
          if (!await dataFile.exists()) {
            await dataFile.parent.create(recursive: true);
            await dataFile.writeAsString(
              const JsonEncoder.withIndent('  ').convert({
                'id': 'library',
                'name': 'Library',
                'type': 'manga',
                'is_local': true,
                'url': '$readerPath/manga/library/series',
                'created_at': DateTime.now().toIso8601String(),
                'modified_at': DateTime.now().toIso8601String(),
              }),
            );
          }
          final toDownload = chapters.take(maxChapters).toList();
          final coordinator = MangaDownloadCoordinator();
          coordinator.enqueue(
            seriesDir: seriesDir,
            extensionId: extensionId,
            seriesTitle: mangaTitle,
            chapters: toDownload,
          );
          return {
            'success': true,
            'queued': toDownload.length,
            'series_dir': seriesDir,
            'chapters': toDownload
                .map((c) => {'id': c.id, 'number': c.number})
                .toList(),
          };
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }

      case 'manga_download_status':
        try {
          final coordinator = MangaDownloadCoordinator();
          final downloads = coordinator.downloads;
          return {
            'success': true,
            'active': coordinator.isActive,
            'paused': coordinator.isPaused,
            'queue_length': coordinator.queueLength,
            'downloads': downloads
                .map(
                  (d) => {
                    'series': d.seriesTitle,
                    'chapter': d.chapterName,
                    'is_active': d.isActive,
                    'error': d.error,
                  },
                )
                .toList(),
          };
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }

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

      case 'ble_send_dm':
        final callsign = params['callsign'] as String?;
        final content = params['content'] as String?;
        if (callsign == null || callsign.isEmpty) {
          return {'success': false, 'error': 'Missing callsign parameter'};
        }
        if (content == null || content.isEmpty) {
          return {'success': false, 'error': 'Missing content parameter'};
        }
        triggerBLESendDM(callsign: callsign, content: content);
        return {
          'success': true,
          'message': 'BLE DM send triggered to $callsign',
          'callsign': callsign,
        };

      case 'refresh_devices':
        triggerDeviceRefresh();
        return {'success': true, 'message': 'Device refresh triggered'};

      case 'local_scan':
        triggerLocalNetworkScan();
        return {'success': true, 'message': 'Local network scan triggered'};

      case 'usb_status':
        // Diagnose USB AOA transport status
        final usbService = UsbAoaService();
        final connManager = ConnectionManager();
        final usbTransport = connManager.getTransport('usb_aoa');

        final localCallsign = AppService().currentCallsign;
        final status = {
          'success': true,
          'local_callsign': localCallsign,
          'usb_service': {
            'isInitialized': usbService.isInitialized,
            'connectionState': usbService.connectionState.toString(),
            'remoteCallsign': usbService.remoteCallsign,
            'isConnected': usbService.isConnected,
            'isAvailable': UsbAoaService.isAvailable,
            'isReading': usbService.isReading,
            'pollTimeoutCount': usbService.pollTimeoutCount,
          },
          'usb_transport': {
            'registered': usbTransport != null,
            'isAvailable': usbTransport?.isAvailable ?? false,
            'isInitialized': usbTransport?.isInitialized ?? false,
          },
          'connection_manager': {
            'isInitialized': connManager.isInitialized,
            'transportCount': connManager.transports.length,
            'transportIds': connManager.transports.map((t) => t.id).toList(),
          },
        };

        LogService().log('USB Status Diagnostic: $status');
        return status;

      case 'usb_restart_hello':
        // Restart USB AOA hello handshake
        final cm = ConnectionManager();
        final transport = cm.getTransport('usb_aoa');
        if (transport == null) {
          return {'success': false, 'error': 'USB transport not registered'};
        }
        // Import the specific type to access restartHelloRetry
        if (transport is! UsbAoaTransport) {
          return {
            'success': false,
            'error': 'Transport is not UsbAoaTransport',
          };
        }
        transport.restartHelloRetry();
        return {'success': true, 'message': 'USB hello retry restarted'};

      case 'usb_scan':
        // Manually scan for USB devices and attempt connection
        final usbService = UsbAoaService();
        if (!usbService.isInitialized) {
          return {'success': false, 'error': 'USB service not initialized'};
        }
        try {
          final devices = await usbService.listDevices();
          final deviceList = devices
              .map(
                (d) => {
                  'vid': d.vidHex,
                  'pid': d.pidHex,
                  'devPath': d.devPath,
                  'sysPath': d.sysPath,
                  'manufacturer': d.manufacturer,
                  'product': d.product,
                  'isAoaDevice': d.isAoaDevice,
                  'isAndroidDevice': d.isAndroidDevice,
                },
              )
              .toList();

          LogService().log('USB Scan: Found ${devices.length} device(s)');
          for (final d in devices) {
            LogService().log(
              '  - ${d.vidHex}:${d.pidHex} ${d.manufacturer ?? ""} ${d.product ?? ""} isAoa=${d.isAoaDevice}',
            );
          }

          // If not connected and devices found, try to connect
          if (!usbService.isConnected && devices.isNotEmpty) {
            LogService().log('USB Scan: Attempting auto-connect...');
            await usbService.open();
          }

          return {
            'success': true,
            'devices': deviceList,
            'count': devices.length,
            'isConnected': usbService.isConnected,
            'connectionState': usbService.connectionState.toString(),
          };
        } catch (e) {
          LogService().log('USB Scan error: $e');
          return {'success': false, 'error': e.toString()};
        }

      case 'refresh_chat':
        await triggerChatRefresh();
        return {'success': true, 'message': 'Chat channels refreshed'};

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

      case 'add_device':
        final callsign = params['callsign'] as String?;
        final url = params['url'] as String?;
        if (callsign == null || callsign.isEmpty) {
          return {'success': false, 'error': 'Missing callsign parameter'};
        }
        if (url == null || url.isEmpty) {
          return {'success': false, 'error': 'Missing url parameter'};
        }
        // Try to fetch device's nickname from its status API
        String? nickname;
        try {
          final statusUrl = '$url/api/status';
          final response = await http
              .get(Uri.parse(statusUrl))
              .timeout(const Duration(seconds: 2));
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body) as Map<String, dynamic>;
            nickname = data['nickname'] as String?;
          }
        } catch (_) {
          // Ignore errors fetching status
        }
        // Call DevicesService directly to add the device as online
        final devicesService = DevicesService();
        await devicesService.addDevice(
          callsign,
          url: url,
          name: nickname,
          isOnline: true,
        );
        // Also add the appropriate connection method based on URL
        final device = devicesService.getDevice(callsign);
        if (device != null) {
          // Determine connection method from URL
          final connectionMethod =
              url.contains('localhost') || url.contains('127.0.0.1')
              ? 'wifi_local'
              : 'lan';
          if (!device.connectionMethods.contains(connectionMethod)) {
            device.connectionMethods = [
              ...device.connectionMethods,
              connectionMethod,
            ];
          }
        }
        triggerAddDevice(callsign: callsign, url: url);
        return {
          'success': true,
          'message': 'Device added: $callsign at $url',
          'callsign': callsign,
          'url': url,
          'nickname': nickname,
        };

      case 'remove_device':
        final rmCallsign = params['callsign'] as String?;
        if (rmCallsign == null || rmCallsign.isEmpty) {
          return {'success': false, 'error': 'Missing callsign parameter'};
        }
        final permanent = params['permanent'] as bool? ?? true;
        await DevicesService().removeDevice(rmCallsign, permanent: permanent);
        return {
          'success': true,
          'message': 'Device removed: $rmCallsign (permanent: $permanent)',
          'callsign': rmCallsign,
          'permanent': permanent,
        };

      case 'restore_device':
        final restoreCallsign = params['callsign'] as String?;
        if (restoreCallsign == null || restoreCallsign.isEmpty) {
          return {'success': false, 'error': 'Missing callsign parameter'};
        }
        DevicesService().restoreDevice(restoreCallsign);
        return {
          'success': true,
          'message': 'Device restored: $restoreCallsign',
          'callsign': restoreCallsign,
        };

      case 'get_removed_devices':
        final removedSet = DevicesService().getRemovedDevices();
        return {
          'success': true,
          'removedDevices': removedSet.toList(),
          'total': removedSet.length,
        };

      case 'open_station_chat':
        triggerOpenStationChat();
        return {
          'success': true,
          'message': 'Opening station chat app and first chat room',
        };

      case 'open_local_chat':
        triggerOpenLocalChat();
        return {'success': true, 'message': 'Opening local chat collection'};

      case 'welcome_open':
        triggerOpenWelcomePage();
        return {'success': true, 'message': 'Opening welcome page'};

      case 'welcome_finalize':
        return await _handleWelcomeFinalize();

      case 'select_chat_room':
        final roomId = params['room_id'] as String?;
        if (roomId == null || roomId.isEmpty) {
          return {'success': false, 'error': 'Missing room_id parameter'};
        }
        triggerSelectChatRoom(roomId);
        return {'success': true, 'message': 'Selecting chat room: $roomId'};

      case 'send_chat_message':
        final content = params['content'] as String? ?? '';
        final imagePath = params['image_path'] as String?;
        if (content.isEmpty && imagePath == null) {
          return {
            'success': false,
            'error': 'Either content or image_path is required',
          };
        }
        triggerSendChatMessage(content: content, imagePath: imagePath);
        return {
          'success': true,
          'message':
              'Sending chat message${imagePath != null ? " with image" : ""}',
        };

      case 'send_dm_file':
        final callsign = params['callsign'] as String?;
        final filePath = params['file_path'] as String?;
        if (callsign == null || callsign.isEmpty) {
          return {'success': false, 'error': 'Missing callsign parameter'};
        }
        if (filePath == null || filePath.isEmpty) {
          return {'success': false, 'error': 'Missing file_path parameter'};
        }
        triggerSendDMFile(callsign: callsign, filePath: filePath);
        return {
          'success': true,
          'message': 'DM file send triggered to $callsign',
          'callsign': callsign,
          'file_path': filePath,
        };

      case 'open_dm':
        final callsign = params['callsign'] as String?;
        if (callsign == null || callsign.isEmpty) {
          return {'success': false, 'error': 'Missing callsign parameter'};
        }
        triggerOpenDM(callsign: callsign);
        return {
          'success': true,
          'message': 'Opening DM conversation with $callsign',
          'callsign': callsign,
        };

      case 'open_console':
        // Navigate to Collections panel and broadcast console open
        navigateToPanel(PanelIndex.apps);
        triggerOpenConsole(sessionId: params['session_id'] as String?);
        return {'success': true, 'message': 'Console open triggered'};

      case 'console_status':
        // Tail console-related logs (last 50 containing "Console")
        final logs = LogService().messages
            .where((m) => m.contains('Console'))
            .toList();
        final logTail = logs.length > 50
            ? logs.sublist(logs.length - 50)
            : logs;

        // Find console collection if available
        final consoleApp = AppService().getAppByType('console');

        return {
          'success': true,
          'type': 'cli_terminal',
          'console_app': consoleApp != null
              ? {
                  'id': consoleApp.id,
                  'title': consoleApp.title,
                  'path': consoleApp.storagePath,
                }
              : null,
          'log_tail': logTail,
        };

      case 'open_flasher_monitor':
        final devicePath = params['device_path'] as String?;
        triggerOpenFlasherMonitor(devicePath: devicePath);
        return {
          'success': true,
          'message': 'Opening Flasher on Monitor tab',
          'device_path': devicePath,
        };

      case 'list_devices':
        final devicesService = DevicesService();
        final devices = devicesService.getAllDevices();
        final deviceList = devices
            .map(
              (d) => <String, dynamic>{
                'callsign': d.callsign,
                'nickname': d.nickname,
                'isOnline': d.isOnline,
                'connectionMethods': d.connectionMethods,
                'url': d.url,
                'npub': d.npub,
              },
            )
            .toList();
        return {
          'success': true,
          'count': deviceList.length,
          'devices': deviceList,
        };

      case 'conference_host':
        return _conferenceHost(params);

      case 'conference_join':
        return _conferenceJoin(params);

      case 'conference_status':
        return _conferenceStatus();

      case 'conference_end':
        return _conferenceEnd();

      case 'conference_mute':
        return _conferenceMute();

      case 'conference_request_speaker':
        return _conferenceRequestSpeaker();

      case 'conference_start_screen_share':
        return _conferenceStartScreenShare();

      case 'conference_stop_screen_share':
        return _conferenceStopScreenShare();

      case 'conference_request_screen_share':
        return _conferenceRequestScreenShare();

      case 'conference_send_chat':
        return _conferenceSendChat(params);

      case 'conference_promote':
        return _conferencePromote(params);

      case 'conference_demote':
        return _conferenceDemote(params);

      case 'conference_approve_screen_share':
        return _conferenceApproveScreenShare(params);

      case 'create_app':
        return _createApp(params);

      case 'open_app':
        return _openApp(params);

      case 'shared_add':
        return _sharedAdd(params);

      case 'shared_list':
        return _sharedList();

      case 'bitchat_status':
        return _bitchatStatus();

      case 'bitchat_enable':
        return _bitchatEnable();

      case 'meshtastic_status':
        return _meshtasticStatus();

      case 'meshtastic_enable':
        return _meshtasticEnable();

      case 'meshtastic_log_level':
        return _meshtasticLogLevel(params);

      default:
        return {
          'success': false,
          'error': 'Unknown action: $action',
          'available_actions': getAvailableActions()
              .map((a) => a['action'])
              .toList(),
        };
    }
  }

  // ── Conference debug actions ────────────────────────────────────

  Future<Map<String, dynamic>> _conferenceHost(
    Map<String, dynamic> params,
  ) async {
    try {
      final roomName = params['room_name'] as String? ?? 'Test Meeting';
      final maxSpeakers = params['max_speakers'] as int? ?? 6;
      final room = await ConferenceService().hostConference(
        roomName: roomName,
        maxSpeakers: maxSpeakers,
      );
      final meetUrls = await ConferenceService().getMeetUrls();
      return {
        'success': true,
        'message': 'Conference hosted (SFU, max $maxSpeakers speakers)',
        'room': room.toJson(),
        'meet_urls': meetUrls,
        'station_meet_url': ConferenceService().stationMeetUrl,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _conferenceJoin(
    Map<String, dynamic> params,
  ) async {
    try {
      final wsUrl = params['url'] as String?;
      final roomId = params['room_id'] as String?;
      final roleStr = params['role'] as String? ?? 'listener';
      final role = roleStr == 'speaker'
          ? ConferenceParticipantRole.speaker
          : ConferenceParticipantRole.listener;

      if (wsUrl != null) {
        await ConferenceService().joinLan(wsUrl, participantRole: role);
      } else if (roomId != null) {
        await ConferenceService().joinStation(roomId, participantRole: role);
      } else {
        return {'success': false, 'error': 'Provide url or room_id'};
      }
      return {
        'success': true,
        'message': 'Joined conference as $roleStr',
        'room': ConferenceService().room?.toJson(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Map<String, dynamic> _conferenceStatus() {
    final cs = ConferenceService();
    return {
      'success': true,
      'state': cs.state.name,
      'role': cs.role?.name,
      'is_muted': cs.isLocalMuted,
      'remote_audio_stream_count': cs.remoteAudioStreams.length,
      'remote_screen_stream_count': cs.remoteScreenStream == null ? 0 : 1,
      'local_screen_sharing': cs.isLocalScreenSharing,
      'active_screen_sharer': cs.activeScreenSharer,
      'room': cs.room?.toJson(),
      'chat_transcript_path': cs.chatTranscriptPath,
      'pending_speaker_requests': cs.pendingSpeakerRequests,
      'pending_screen_share_requests': cs.pendingScreenShareRequests,
      'chat_messages': cs.chatMessages
          .map(
            (message) => {
              'author': message.author,
              'timestamp': message.timestamp,
              'content': message.content,
              'metadata': message.metadata,
            },
          )
          .toList(),
    };
  }

  Future<Map<String, dynamic>> _conferenceEnd() async {
    try {
      await ConferenceService().endConference();
      return {'success': true, 'message': 'Conference ended'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Map<String, dynamic> _conferenceMute() {
    try {
      ConferenceService().toggleMute();
      return {'success': true, 'is_muted': ConferenceService().isLocalMuted};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _conferenceRequestSpeaker() async {
    try {
      await ConferenceService().requestToSpeak();
      return {
        'success': true,
        'message': 'Speaker request sent',
        'pending_speaker_requests': ConferenceService().pendingSpeakerRequests,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _conferenceStartScreenShare() async {
    try {
      await ConferenceService().startScreenShare();
      return {
        'success': true,
        'message': 'Screen sharing started',
        'active_screen_sharer': ConferenceService().activeScreenSharer,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _conferenceStopScreenShare() async {
    try {
      await ConferenceService().stopScreenShare();
      return {
        'success': true,
        'message': 'Screen sharing stopped',
        'active_screen_sharer': ConferenceService().activeScreenSharer,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _conferenceRequestScreenShare() async {
    try {
      await ConferenceService().requestToShareScreen();
      return {
        'success': true,
        'message': 'Screen-share request sent',
        'pending_screen_share_requests':
            ConferenceService().pendingScreenShareRequests,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _conferenceSendChat(
    Map<String, dynamic> params,
  ) async {
    try {
      final content = params['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        return {'success': false, 'error': 'Missing content parameter'};
      }
      await ConferenceService().sendChatMessage(content);
      return {
        'success': true,
        'message': 'Chat message sent',
        'chat_messages': ConferenceService().chatMessages
            .map(
              (message) => {
                'author': message.author,
                'timestamp': message.timestamp,
                'content': message.content,
                'metadata': message.metadata,
              },
            )
            .toList(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _conferencePromote(
    Map<String, dynamic> params,
  ) async {
    try {
      final callsign = params['callsign'] as String?;
      if (callsign == null) {
        return {'success': false, 'error': 'Missing callsign parameter'};
      }
      await ConferenceService().promoteToSpeaker(callsign);
      return {
        'success': true,
        'message': '$callsign promoted to speaker',
        'room': ConferenceService().room?.toJson(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _conferenceDemote(
    Map<String, dynamic> params,
  ) async {
    try {
      final callsign = params['callsign'] as String?;
      if (callsign == null) {
        return {'success': false, 'error': 'Missing callsign parameter'};
      }
      await ConferenceService().demoteToListener(callsign);
      return {
        'success': true,
        'message': '$callsign demoted to listener',
        'room': ConferenceService().room?.toJson(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _conferenceApproveScreenShare(
    Map<String, dynamic> params,
  ) async {
    try {
      final callsign = params['callsign'] as String?;
      if (callsign == null) {
        return {'success': false, 'error': 'Missing callsign parameter'};
      }
      await ConferenceService().approveScreenShare(callsign);
      return {
        'success': true,
        'message': '$callsign approved for screen sharing',
        'room': ConferenceService().room?.toJson(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── App management debug actions ────────────────────────────────

  Future<Map<String, dynamic>> _createApp(Map<String, dynamic> params) async {
    try {
      final type = params['type'] as String?;
      if (type == null) {
        return {'success': false, 'error': 'Missing type parameter'};
      }
      final title = params['title'] as String? ?? type;
      final app = await AppService().createApp(title: title, type: type);
      return {
        'success': true,
        'message': 'Created app: ${app.title} (${app.type})',
        'app_id': app.id,
        'app_type': app.type,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _openApp(Map<String, dynamic> params) async {
    try {
      final type = params['type'] as String?;
      if (type == null) {
        return {'success': false, 'error': 'Missing type parameter'};
      }
      // Find the app by type
      final apps = await AppService().loadApps();
      final app = apps.where((a) => a.type == type).firstOrNull;
      if (app == null) {
        return {
          'success': false,
          'error': 'No app found with type: $type',
          'available_types': apps.map((a) => a.type).toList(),
        };
      }
      // Emit a navigate action with the app info
      _actionController.add(
        DebugActionEvent(
          action: DebugAction.navigateToPanel,
          params: {'panel': 'app', 'app_type': type, 'app_id': app.id},
        ),
      );
      return {
        'success': true,
        'message': 'Opening app: ${app.title} (${app.type})',
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── Shared folder debug actions ──────────────────────────────────

  Future<Map<String, dynamic>> _sharedAdd(Map<String, dynamic> params) async {
    try {
      final title = params['title'] as String?;
      final location = params['location'] as String?;

      if (title == null || location == null) {
        return {'success': false, 'error': 'Missing required: title, location'};
      }

      // Ensure the shared app exists
      final apps = await AppService().loadApps();
      var sharedApp = apps.where((a) => a.type == 'shared').firstOrNull;
      sharedApp ??= await AppService().createApp(
        title: 'Shared',
        type: 'shared',
      );

      final storagePath = sharedApp.storagePath;
      if (storagePath == null) {
        return {'success': false, 'error': 'Shared app has no storage path'};
      }

      // Set up service
      final profileStorage = AppService().profileStorage;
      if (profileStorage == null) {
        return {'success': false, 'error': 'Profile storage not available'};
      }

      final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
        profileStorage,
        storagePath,
      );
      final service = SharedFolderService();
      service.setStorage(scopedStorage);
      await service.initializeApp(storagePath);

      // Create and save the entry
      final visibility = params['visibility'] as String? ?? 'public';
      final description = params['description'] as String? ?? '';

      final folder = SharedFolder(
        title: title,
        location: location,
        visibility: SharedFolderVisibility.fromValue(visibility),
        description: description,
      );

      final saved = await service.save(folder);

      return {
        'success': true,
        'message': 'Added shared folder: $title → $location',
        'entry': {
          'id': saved.id,
          'title': saved.title,
          'location': saved.location,
          'visibility': saved.visibility.value,
          'slug': saved.sanitizedFilename,
        },
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _sharedList() async {
    try {
      final apps = await AppService().loadApps();
      final sharedApp = apps.where((a) => a.type == 'shared').firstOrNull;
      if (sharedApp == null) {
        return {
          'success': true,
          'folders': [],
          'message': 'No shared app found',
        };
      }

      final storagePath = sharedApp.storagePath;
      if (storagePath == null) {
        return {'success': true, 'folders': []};
      }

      final profileStorage = AppService().profileStorage;
      if (profileStorage == null) {
        return {'success': false, 'error': 'Profile storage not available'};
      }

      final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
        profileStorage,
        storagePath,
      );
      final service = SharedFolderService();
      service.setStorage(scopedStorage);
      await service.initializeApp(storagePath);

      final folders = await service.loadAll();

      return {
        'success': true,
        'count': folders.length,
        'folders': folders
            .map(
              (f) => {
                'id': f.id,
                'title': f.title,
                'location': f.location,
                'visibility': f.visibility.value,
                'slug': f.sanitizedFilename,
              },
            )
            .toList(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── BitChat debug actions ──────────────────────────────────────

  Future<Map<String, dynamic>> _bitchatStatus() async {
    final service = BitchatService();
    final status = service.getStatus();
    final cacheInfo = await service.cacheService?.inspect();
    return {
      'success': true,
      ...status,
      if (cacheInfo != null) 'cache': cacheInfo,
    };
  }

  Future<Map<String, dynamic>> _bitchatEnable() async {
    try {
      final service = BitchatService();
      if (!service.isEnabled) {
        final storage = AppService().profileStorage;
        if (storage == null) {
          return {'success': false, 'error': 'No profile storage available'};
        }
        service.setStorage(storage);
        await service.ensureIdentity();
        await service.enableAsync();
      }
      return {
        'success': true,
        'message': 'BitChat enabled',
        ...service.getStatus(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── Meshtastic debug actions ────────────────────────────────────

  Future<Map<String, dynamic>> _meshtasticStatus() async {
    final service = MeshtasticService();
    final status = service.getStatus();
    final cacheInfo = await service.cacheService?.inspect();
    return {
      'success': true,
      ...status,
      if (cacheInfo != null) 'cache': cacheInfo,
    };
  }

  Future<Map<String, dynamic>> _meshtasticEnable() async {
    try {
      final service = MeshtasticService();
      if (!service.isEnabled) {
        final storage = AppService().profileStorage;
        if (storage == null) {
          return {'success': false, 'error': 'No profile storage available'};
        }
        service.setStorage(storage);
        await service.enableAsync();
      }
      return {
        'success': true,
        'message': 'Meshtastic enabled',
        ...service.getStatus(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _meshtasticLogLevel(
    Map<String, dynamic> params,
  ) async {
    final levelStr = params['level'] as String?;
    if (levelStr == null) {
      return {
        'success': true,
        'logLevel': MeshtasticService().logLevel.name,
        'available': MeshtasticLogLevel.values.map((l) => l.name).toList(),
      };
    }

    final level = MeshtasticLogLevel.values.firstWhere(
      (l) => l.name == levelStr,
      orElse: () => MeshtasticLogLevel.info,
    );

    MeshtasticService().setLogLevel(level);
    return {
      'success': true,
      'logLevel': level.name,
      'message': 'Log level set to ${level.name}',
    };
  }

  /// Dispose resources
  void dispose() {
    _actionController.close();
  }
}
