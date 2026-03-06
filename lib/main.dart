import 'dart:async';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' if (dart.library.html) 'platform/io_stub.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'services/crash_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart'
    if (dart.library.html) 'platform/window_manager_stub.dart';
import 'services/log_service.dart';
import 'services/log_api_service.dart';
import 'version.dart';
import 'services/debug_controller.dart';
import 'services/usb_attachment_service.dart';
import 'services/file_viewer_service.dart';
import 'services/config_service.dart';
import 'services/app_service.dart';
import 'services/encrypted_storage_service.dart';
import 'services/profile_service.dart';
import 'services/profile_storage.dart';
import 'services/station_service.dart';
import 'services/station_node_service.dart';
import 'services/station_discovery_service.dart';
import 'services/notification_service.dart';
import 'services/i18n_service.dart';
import 'services/chat_notification_service.dart';
import 'services/station_content_notification_service.dart';
import 'services/now_service.dart';
import 'services/now_notification_bridge.dart';
import 'services/station_chat_queue_service.dart';
import 'services/dm_notification_service.dart';
import 'services/backup_notification_service.dart';
import 'services/message_attention_service.dart';
import 'services/update_service.dart';
import 'services/devices_service.dart';
import 'services/ble_permission_service.dart';
import 'services/storage_config.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/web_theme_service.dart';
import 'services/app_theme_service.dart';
import 'services/app_args.dart';
import 'services/security_service.dart';
import 'services/network_monitor_service.dart';
import 'services/user_location_service.dart';
import 'services/direct_message_service.dart';
import 'services/dm_queue_service.dart';
import 'services/message_retention_service.dart';
import 'services/websocket_service.dart';
import 'services/backup_service.dart';
import 'teleport/aprs/aprs_service.dart';
import 'teleport/irc/irc_service.dart';
import 'teleport/xmpp/xmpp_service.dart';
import 'teleport/nostr/nostr_client_service.dart';
import 'teleport/atproto/atproto_client_service.dart';
import 'teleport/meshcore/meshcore_service.dart';
import 'teleport/bitchat/bitchat_service.dart';
import 'services/window_state_service.dart';
import 'services/tray_service.dart';
import 'services/group_sync_service.dart';
import 'services/map_tile_service.dart';
import 'cli/pure_storage_config.dart';
import 'connection/connection_manager.dart';
import 'connection/transports/lan_transport.dart';
import 'connection/transports/ble_transport.dart';
import 'services/ble_identity_service.dart';
import 'services/ble_foreground_service.dart';
import 'connection/transports/bluetooth_classic_transport.dart';
import 'connection/transports/station_transport.dart';
import 'connection/transports/webrtc_transport.dart';
import 'connection/transports/usb_aoa_transport.dart';
import 'models/app.dart';
import 'util/file_icon_helper.dart';
import 'util/event_bus.dart';
import 'util/app_type_theme.dart';
import 'pages/profile_page.dart';
import 'pages/about_page.dart';
import 'pages/update_page.dart';
import 'pages/stations_page.dart';
// import 'pages/notifications_page.dart'; // TODO: Not yet implemented
import 'pages/chat_browser_page.dart';
import 'pages/email_browser_page.dart';
import 'pages/forum_browser_page.dart';
import 'pages/blog_browser_page.dart';
import 'pages/now_page.dart';
import 'pages/remote_blog_browser_page.dart';
import 'pages/remote_chat_room_page.dart';
import 'pages/remote_chat_browser_page.dart' show ChatRoom;
import 'models/device_source.dart';
import 'teleport/irc/pages/irc_chat_page.dart';
import 'teleport/telegram/pages/telegram_chat_page.dart';
import 'teleport/aprs/pages/aprs_conversation_page.dart';
import 'teleport/aprs/models/aprs_conversation.dart';
import 'pages/log_browser_page.dart';
import 'pages/events_browser_page.dart';
import 'pages/news_browser_page.dart';
import 'pages/postcards_browser_page.dart';
import 'pages/contacts_browser_page.dart';
import 'pages/places_browser_page.dart';
import 'pages/console_browser_page.dart';
import 'pages/market_browser_page.dart';
import 'pages/inventory_browser_page.dart';
import 'tracker/pages/tracker_browser_page.dart';
import 'tracker/services/tracker_service.dart';
import 'tracker/services/proximity_detection_service.dart';
import 'pages/wallet_browser_page.dart';
import 'pages/report_browser_page.dart';
import 'pages/groups_browser_page.dart';
import 'pages/maps_browser_page.dart';
import 'pages/station_dashboard_page.dart';
import 'pages/devices_browser_page.dart';
import 'pages/bot_page.dart';
import 'pages/backup_browser_page.dart';
import 'pages/video_browser_page.dart';
import 'pages/transfer_page.dart';
import 'pages/dm_chat_page.dart';
import 'pages/photo_viewer_page.dart';
import 'pages/document_viewer_editor_page.dart';
import 'reader/pages/reader_home_page.dart';
import 'flasher/pages/flasher_page.dart';
import 'work/pages/work_page.dart';
import 'usenet/pages/usenet_app_page.dart';
import 'music/pages/music_home_page.dart';
import 'pages/files_browser_page.dart';
import 'stories/pages/stories_home_page.dart';
import 'pages/qr_browser_page.dart';
import 'pages/shared_browser_page.dart';
import 'pages/teleport_browser_page.dart';
import 'pages/conference_home_page.dart';
import 'pages/karma_page.dart';
import 'pages/website_browser_page.dart';
import 'pages/profile_management_page.dart';
import 'pages/create_app_page.dart';
import 'pages/onboarding_page.dart';
import 'pages/welcome_page.dart';
import 'pages/security_settings_page.dart';
import 'pages/storage_settings_page.dart';
import 'pages/task_settings_page.dart';
import 'pages/theme_settings_page.dart';
import 'pages/mirror_settings_page.dart';
import 'pages/mirror_wizard_page.dart';
import 'pages/hotspot_settings_page.dart';
import 'widgets/profile_switcher.dart';
import 'widgets/transfer/incoming_transfer_dialog.dart';
import 'transfer/services/p2p_transfer_service.dart';
import 'cli/console.dart';

void main() async {
  print('MAIN: Starting Geogram (kIsWeb: $kIsWeb)'); // Debug

  // Parse command line arguments early (before any other initialization)
  if (!kIsWeb) {
    // For Flutter desktop apps, Platform.executableArguments contains Flutter engine args
    // On Linux, we read /proc/self/cmdline to get the actual command-line arguments
    // On Windows/macOS, we use Platform.executableArguments directly
    List<String> allArgs = [];
    if (Platform.isLinux) {
      try {
        final cmdline = File('/proc/self/cmdline').readAsStringSync();
        allArgs = cmdline
            .split('\x00')
            .where((s) => s.isNotEmpty)
            .skip(1)
            .toList();
      } catch (e) {
        allArgs = Platform.executableArguments;
      }
    } else {
      allArgs = Platform.executableArguments;
    }

    // Parse arguments into AppArgs singleton
    AppArgs().parse(allArgs);

    // Handle --help flag
    if (AppArgs().showHelp) {
      print(AppArgs.getHelpText());
      exit(0);
    }

    // Handle --version flag
    if (AppArgs().showVersion) {
      print('Geogram Desktop v$appVersion');
      exit(0);
    }

    // Log parsed arguments
    if (AppArgs().verbose) {
      print('MAIN: Parsed arguments: ${AppArgs().toMap()}');
    }

    // Check for CLI mode
    if (AppArgs().cliMode) {
      // Run CLI mode without Flutter
      await runCliMode(allArgs);
      return;
    }
  }

  // Initialize crash handling BEFORE Flutter binding
  // This ensures we catch crashes during initialization
  await CrashService().initialize();
  _setupCrashHandlers();

  WidgetsFlutterBinding.ensureInitialized();

  // Check if launched via a file VIEW intent (Android cold start).
  // Must happen before heavy initialization — if a file intent is detected,
  // run a lightweight viewer app and skip all service init.
  if (!kIsWeb && Platform.isAndroid) {
    if (await FileViewerService.checkLaunchIntent()) {
      final info = FileViewerService.launchFile!;
      runApp(FileViewerApp(
        filePath: info['path']!,
        mimeType: info['mimeType']!,
      ));
      return;
    }
  }

  // Initialize media_kit for cross-platform video playback
  // Wrapped in try-catch to prevent crash if native libraries fail to load
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    print('MAIN: MediaKit initialization failed: $e');
    // Continue without video support - app can still function
  }

  // Re-initialize CrashService with proper paths now that binding is ready
  await CrashService().reinitialize();

  // Apply Android intent extras (test mode, etc.)
  await AppArgs().applyAndroidExtras();

  // Initialize window manager for desktop platforms (not web or mobile)
  // Note: Actual window positioning happens after ConfigService is initialized
  if (!kIsWeb) {
    try {
      await windowManager.ensureInitialized();
    } catch (e) {
      // Silently fail if window_manager is not available
      // This handles Android and iOS platforms
    }
  }

  // Initialize log service first to capture any initialization errors
  await LogService().init();
  LogService().log('Geogram Desktop starting...');

  // Log command line configuration
  if (!kIsWeb && AppArgs().isInitialized) {
    LogService().log(
      'CLI args: port=${AppArgs().port}, dataDir=${AppArgs().dataDir ?? "default"}',
    );
  }

  try {
    // PHASE 1: Critical services (must complete before UI)
    // These are fast and required for the app to function

    // Initialize storage configuration first (all other services depend on it)
    // Use custom data directory from CLI args if specified
    await StorageConfig().init(customBaseDir: AppArgs().dataDir);
    // Note: LogService file logging is deferred until profile is activated
    // via LogService().switchToProfile() - logs are now per-profile
    await CrashService().reinitialize();
    LogService().log('StorageConfig initialized: ${StorageConfig().baseDir}');

    // Also initialize PureStorageConfig with same base directory
    // This enables CLI components (like PureStationServer) to be used in GUI mode
    await PureStorageConfig().init(customBaseDir: StorageConfig().baseDir);
    LogService().log('PureStorageConfig initialized (shared with CLI)');

    // Initialize config and i18n in parallel (both are independent)
    await Future.wait([
      ConfigService().init().then(
        (_) => LogService().log('ConfigService initialized'),
      ),
      I18nService().init().then(
        (_) => LogService().log('I18nService initialized'),
      ),
    ]);

    // Restore window position and size on desktop platforms
    if (!kIsWeb) {
      try {
        final windowStateService = WindowStateService();
        final savedState = await windowStateService.getSavedState();
        final validatedState = await windowStateService.validateState(
          savedState,
        );

        final windowOptions = WindowOptions(
          size: validatedState.size,
          center: validatedState.shouldCenter,
          backgroundColor: Colors.transparent,
          skipTaskbar: false,
          titleBarStyle: TitleBarStyle.normal,
        );

        await windowManager.waitUntilReadyToShow(windowOptions, () async {
          // Set size constraints to prevent Linux resize bug where dragging
          // one edge can unexpectedly expand the other dimension
          await windowManager.setMinimumSize(const Size(800, 600));
          // Use 4K as maximum - windows should not grow larger than this
          await windowManager.setMaximumSize(const Size(3840, 2160));

          // Apply saved position if not centering
          if (!validatedState.shouldCenter && validatedState.position != null) {
            await windowManager.setPosition(validatedState.position!);
          }

          // Apply maximized state
          if (validatedState.isMaximized) {
            await windowManager.maximize();
          }

          if (!AppArgs().minimized) {
            await windowManager.show();
            await windowManager.focus();
          }

          // Start listening for window changes to persist state
          await windowStateService.startListening();
        });
        LogService().log(
          'Window state restored: ${validatedState.size.width}x${validatedState.size.height}, maximized=${validatedState.isMaximized}',
        );
      } catch (e) {
        // Fallback: show window with defaults if restoration fails
        LogService().log('Window state restoration failed: $e');
        try {
          await windowManager.waitUntilReadyToShow(
            const WindowOptions(size: Size(1200, 800), center: true),
            () async {
              // Set size constraints even in fallback mode
              await windowManager.setMinimumSize(const Size(800, 600));
              await windowManager.setMaximumSize(const Size(3840, 2160));
              if (!AppArgs().minimized) {
                await windowManager.show();
                await windowManager.focus();
              }
            },
          );
        } catch (_) {}
      }
    }

    // Initialize web theme service (extracts bundled themes on first run)
    await WebThemeService().init();
    LogService().log('WebThemeService initialized');

    // Initialize app theme service
    await AppThemeService().initialize();
    LogService().log('AppThemeService initialized');

    // Initialize profile and app services
    await AppService().init();
    LogService().log('AppService initialized');

    await ProfileService().initialize();
    LogService().log('ProfileService initialized');

    // Set active callsign for app storage path
    final profile = ProfileService().getProfile();
    // Set nsec for encrypted storage access (must be before setActiveCallsign)
    if (profile.nsec.isNotEmpty) {
      AppService().setNsec(profile.nsec);
    }
    await AppService().setActiveCallsign(profile.callsign);

    // Switch logs to profile-specific directory
    await LogService().switchToProfile(profile.callsign);
    LogService().log('AppService callsign set: ${profile.callsign}');

    // Ensure default apps exist for this profile (non-blocking)
    AppService().ensureDefaultApps();
    LogService().log('Default apps creation started');

    // Initialize notification service (needed for UI badges)
    await NotificationService().initialize();
    LogService().log('NotificationService initialized');

    // Initialize chat notification service (needed for unread counts)
    ChatNotificationService().initialize();
    LogService().log('ChatNotificationService initialized');

    // Initialize station content notification service (blog/events/places in Now feed)
    StationContentNotificationService().initialize();
    LogService().log('StationContentNotificationService initialized');

    // Initialize station chat queue processing (keeps retrying queued sends)
    StationChatQueueService().initialize();
    LogService().log('StationChatQueueService initialized');

    // Initialize USB attachment service (Android only, for ESP32 auto-detection)
    if (!kIsWeb && Platform.isAndroid) {
      UsbAttachmentService().initialize();
      LogService().log('UsbAttachmentService initialized');
    }

    // Initialize file viewer service (Android only, for external file viewing)
    if (!kIsWeb && Platform.isAndroid) {
      FileViewerService().initialize();
      LogService().log('FileViewerService initialized');
    }

    // Initialize DM notification service (for push notifications on mobile)
    // Skip permission request on first launch - onboarding will handle it
    bool firstLaunch = false;
    if (!kIsWeb && Platform.isAndroid) {
      final firstLaunchComplete = ConfigService().getNestedValue(
        'firstLaunchComplete',
        false,
      );
      firstLaunch = firstLaunchComplete != true;
    }
    await DMNotificationService().initialize(
      skipPermissionRequest: firstLaunch,
    );
    LogService().log(
      'DMNotificationService initialized (skipPermission: $firstLaunch)',
    );

    await BackupNotificationService().initialize(
      skipPermissionRequest: firstLaunch,
    );
    LogService().log(
      'BackupNotificationService initialized (skipPermission: $firstLaunch)',
    );

    await MessageAttentionService().initialize();
    LogService().log('MessageAttentionService initialized');

    await TrayService().initialize();
    LogService().log('TrayService initialized');

    // Handle --minimized startup: hide to tray or minimize to taskbar
    if (AppArgs().minimized) {
      if (TrayService().isSupported) {
        await TrayService().hideToTrayDirect();
        LogService().log('Started minimized to system tray');
      } else {
        // Windows: show then minimize to taskbar
        await windowManager.show();
        await windowManager.minimize();
        LogService().log('Started minimized to taskbar');
      }
    }
  } catch (e, stackTrace) {
    LogService().log('ERROR during critical initialization: $e');
    LogService().log('Stack trace: $stackTrace');
    print('MAIN ERROR: $e');
    print('MAIN STACK: $stackTrace');
  }

  // Start the app immediately - don't wait for non-critical services
  print('MAIN: Starting app (deferred services will initialize in background)');
  runApp(const GeogramApp());

  // PHASE 2: Deferred services (initialize after first frame)
  // These can take time and shouldn't block the UI
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      // Check if app recovered from a crash
      if (!kIsWeb && Platform.isAndroid) {
        final recoveredFromCrash = await CrashService().didRecoverFromCrash();
        if (recoveredFromCrash) {
          LogService().warn(
            'App recovered from a previous crash - check crash logs in Settings > Security for details',
          );
          await CrashService().clearRecoveredFromCrash();
        }
      }

      // Initialize location service (GPS on mobile, IP-based on desktop/web)
      // Must run after ProfileService to load saved location
      await UserLocationService().initialize();
      LogService().log('UserLocationService initialized (deferred)');

      // NOTE: StationService initialization moved after firstLaunchComplete check
      // to ensure the user's chosen callsign (from WelcomePage) is used for p2p.radio registration

      // Initialize ConnectionManager with transports after StationService
      // This is needed for DevicesService to route requests properly
      // Transport priority: USB (5) > LAN (10) > WebRTC (15) > Station (30) > BT Classic (35) > BLE (40)
      final connectionManager = ConnectionManager();
      connectionManager.registerTransport(UsbAoaTransport());
      connectionManager.registerTransport(LanTransport());
      connectionManager.registerTransport(WebRTCTransport());
      connectionManager.registerTransport(StationTransport());
      connectionManager.registerTransport(BluetoothClassicTransport());
      connectionManager.registerTransport(BleTransport());
      await connectionManager.initialize();
      LogService().log(
        'ConnectionManager initialized with USB + LAN + WebRTC + Station + BT Classic + BLE transports (deferred)',
      );

      // UpdateService may check for updates - defer it
      await UpdateService().initialize();
      LogService().log('UpdateService initialized (deferred)');

      // Start station auto-discovery (background task)
      StationDiscoveryService().start();
      LogService().log('StationDiscoveryService started (deferred)');

      // Start peer discovery API service (port 3456 for local device discovery)
      // Enable via CLI flags if specified (--http-api, --debug-api)
      if (AppArgs().httpApi && !SecurityService().httpApiEnabled) {
        SecurityService().httpApiEnabled = true;
        LogService().log('HTTP API enabled via --http-api flag');
      }
      if (AppArgs().debugApi && !SecurityService().debugApiEnabled) {
        SecurityService().debugApiEnabled = true;
        LogService().log('Debug API enabled via --debug-api flag');
      }

      // Only start if HTTP API is enabled in security settings or via CLI
      if (SecurityService().httpApiEnabled) {
        await LogApiService().start();
        LogService().log(
          'Peer discovery API started on port ${LogApiService().port} (deferred)',
        );
      } else {
        LogService().log('Peer discovery API disabled by security settings');
      }

      // Check if first launch is complete (user has seen onboarding screen)
      final firstLaunchComplete =
          ConfigService().getNestedValue('firstLaunchComplete', false) as bool;

      // For first-time users on Android, skip BLE initialization here
      // The onboarding screen will request permissions and then reinitialize BLE
      if (!kIsWeb && Platform.isAndroid && !firstLaunchComplete) {
        LogService().log(
          'DevicesService: Skipping BLE init for first launch - onboarding will handle permissions',
        );
        // Initialize DevicesService but skip BLE on first launch
        await DevicesService().initialize(skipBLE: true);
        LogService().log(
          'DevicesService initialized (deferred, BLE skipped for onboarding)',
        );
      } else {
        // For returning users on Android, check permissions without requesting
        // Skip BLE permissions in internet-only mode
        if (!kIsWeb &&
            Platform.isAndroid &&
            firstLaunchComplete &&
            !AppArgs().internetOnly) {
          LogService().log(
            'Checking BLE permissions on Android (returning user)...',
          );

          // Check permissions using permission_handler directly (doesn't trigger Bluetooth initialization)
          final scanStatus = await Permission.bluetoothScan.status;
          final connectStatus = await Permission.bluetoothConnect.status;
          final advertiseStatus = await Permission.bluetoothAdvertise.status;

          final hasAllPermissions =
              scanStatus.isGranted &&
              connectStatus.isGranted &&
              advertiseStatus.isGranted;

          LogService().log(
            'BLE permissions check: hasAllPermissions=$hasAllPermissions',
          );

          if (!hasAllPermissions) {
            LogService().log(
              'BLE permissions not granted - skipping BLE initialization (user can enable in settings)',
            );
            // Initialize DevicesService but skip BLE
            await DevicesService().initialize(skipBLE: true);
            LogService().log(
              'DevicesService initialized (deferred, BLE skipped - permissions not granted)',
            );
          } else {
            // Initialize DevicesService with BLE for returning users with permissions
            await DevicesService().initialize();
            LogService().log('DevicesService initialized (deferred)');
          }
        } else {
          // Initialize DevicesService with BLE for all non-Android platforms
          await DevicesService().initialize();
          LogService().log('DevicesService initialized (deferred)');
        }
      }

      // Auto-start ProximityDetectionService (enabled by default, opt-out)
      // Skip on first launch - onboarding will handle permissions first
      final proximityDisabled =
          ConfigService().getNestedValue('tracker.proximityTrackingEnabled') ==
          false;
      LogService().log(
        '[PROXIMITY] Auto-start check - disabled=$proximityDisabled, firstLaunch=${!firstLaunchComplete}',
      );

      if (!proximityDisabled && firstLaunchComplete) {
        try {
          // Get or find tracker app path
          var appPath = ConfigService().getNestedValue(
            'tracker.proximityAppPath',
          );

          if (appPath is! String || appPath.isEmpty) {
            // Auto-find tracker app
            LogService().log(
              '[PROXIMITY] No saved path, searching for tracker app...',
            );
            final tracker = AppService().getAppByType('tracker');
            if (tracker?.storagePath != null) {
              appPath = tracker!.storagePath;
              ConfigService().setNestedValue(
                'tracker.proximityAppPath',
                appPath,
              );
              LogService().log('[PROXIMITY] Found tracker app: $appPath');
            }
          }

          if (appPath is String && appPath.isNotEmpty) {
            final profileCallsign = ProfileService().getProfile().callsign;
            // Set up storage for TrackerService (encrypted or filesystem)
            final profileStorage = AppService().profileStorage;
            if (profileStorage != null) {
              final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
                profileStorage,
                appPath,
              );
              TrackerService().setStorage(scopedStorage);
            } else {
              TrackerService().setStorage(FilesystemProfileStorage(appPath));
            }
            await TrackerService().initializeApp(
              appPath,
              callsign: profileCallsign,
            );
            await ProximityDetectionService().start(TrackerService());
            LogService().log(
              '[PROXIMITY] Background tracking STARTED - app: $appPath',
            );
          } else {
            LogService().log(
              '[PROXIMITY] No tracker app found, tracking not started',
            );
          }
        } catch (e) {
          LogService().log('[PROXIMITY] Failed to auto-start: $e');
        }
      } else if (!firstLaunchComplete) {
        LogService().log(
          '[PROXIMITY] Skipped on first launch - will start after onboarding',
        );
      } else {
        LogService().log('[PROXIMITY] Tracking disabled by user setting');
      }

      // StationService - skip on first launch, onboarding will start it after profile is finalized
      if (firstLaunchComplete) {
        await StationService().initialize();
        LogService().log('StationService initialized (deferred)');
      } else {
        LogService().log(
          'StationService skipped on first launch - will start after onboarding',
        );
      }

      // Initialize NetworkMonitorService to track LAN/Internet connectivity
      await NetworkMonitorService().initialize();
      LogService().log('NetworkMonitorService initialized');

      // Initialize BackupService for E2E encrypted backups
      await BackupService().initialize();
      LogService().log('BackupService initialized');

      // Initialize DMQueueService for background DM delivery (optimistic UI)
      await DMQueueService().initialize();
      LogService().log('DMQueueService initialized');

      // Start message retention cleanup timer (purges expired DM messages every 30 min)
      MessageRetentionService().startCleanupTimer();
      LogService().log('MessageRetentionService cleanup timer started');

      // Auto-start APRS-IS background service
      if (firstLaunchComplete) {
        final aprsStorage = AppService().profileStorage;
        final profile = ProfileService().getProfile();
        if (aprsStorage != null && profile.fullCallsign.isNotEmpty) {
          AprsService()
              .autoStart(aprsStorage, callsign: profile.fullCallsign)
              .catchError((e) {
            LogService().log('APRS auto-start failed: $e');
          });
        }

        // Auto-start IRC background service
        final ircStorage = AppService().profileStorage;
        if (ircStorage != null) {
          IrcService().autoStart(ircStorage).catchError((e) {
            LogService().log('IRC auto-start failed: $e');
          });
        }

        // Auto-start XMPP background service
        final xmppStorage = AppService().profileStorage;
        if (xmppStorage != null) {
          XmppService().autoStart(xmppStorage).catchError((e) {
            LogService().log('XMPP auto-start failed: $e');
          });
        }

        // Auto-start NOSTR client background service
        final nostrStorage = AppService().profileStorage;
        if (nostrStorage != null) {
          NostrClientService().autoStart(nostrStorage).catchError((e) {
            LogService().log('NOSTR auto-start failed: $e');
          });
        }

        // Auto-start AT Proto / Bluesky bridge background service
        final atprotoStorage = AppService().profileStorage;
        if (atprotoStorage != null) {
          AtprotoClientService().autoStart(atprotoStorage).catchError((e) {
            LogService().log('AT Proto auto-start failed: $e');
          });
        }

        // Auto-start MeshCore LoRa mesh background service
        final meshcoreStorage = AppService().profileStorage;
        if (meshcoreStorage != null) {
          MeshCoreService().autoStart(meshcoreStorage).catchError((e) {
            LogService().log('MeshCore auto-start failed: $e');
          });
        }

        // Auto-start BitChat BLE mesh background service
        final bitchatStorage = AppService().profileStorage;
        if (bitchatStorage != null) {
          BitchatService().autoStart(bitchatStorage).catchError((e) {
            LogService().log('BitChat auto-start failed: $e');
          });
        }
      }

      // Ensure chat rooms exist for all device folders with chat enabled
      GroupSyncService()
          .ensureFolderChatRooms()
          .then((_) {
            LogService().log('GroupSyncService: Folder chat rooms verified');
          })
          .catchError((e) {
            LogService().log(
              'GroupSyncService: Error verifying chat rooms: $e',
            );
          });
    } catch (e, stackTrace) {
      LogService().log('ERROR during deferred initialization: $e');
      LogService().log('Stack trace: $stackTrace');
    }
  });
  return; // Early return since runApp is already called
}

/// Set up global crash handlers for Flutter errors
void _setupCrashHandlers() {
  // Handle Flutter framework errors (widget build errors, etc.)
  FlutterError.onError = (FlutterErrorDetails details) {
    // Use details.toString() for full context (widget tree, render object info)
    // instead of just exceptionAsString() which only gives the error message
    final fullError = details.toString();

    // Log the error with full context
    CrashService().logCrashSync('FlutterError', fullError, details.stack);

    // Present error in debug mode
    FlutterError.presentError(details);

    // For fatal errors, notify native for potential restart (with full context)
    if (details.silent != true) {
      CrashService().notifyNativeCrash(fullError, stackTrace: details.stack);
    }
  };

  // Handle async errors that escape zones (platform dispatcher errors)
  PlatformDispatcher.instance.onError = (error, stack) {
    CrashService().logCrashSync('PlatformDispatcher', error, stack);
    CrashService().notifyNativeCrash(error.toString(), stackTrace: stack);
    // Return true to prevent the error from propagating
    return true;
  };
}

class GeogramApp extends StatefulWidget {
  const GeogramApp({super.key});

  @override
  State<GeogramApp> createState() => _GeogramAppState();
}

class _GeogramAppState extends State<GeogramApp> with WidgetsBindingObserver {
  final AppThemeService _themeService = AppThemeService();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  EventSubscription<DMNotificationTappedEvent>? _dmNotificationSubscription;
  EventSubscription<EmailNotificationTappedEvent>?
  _emailNotificationSubscription;
  EventSubscription<NavigateToDevicesEvent>? _navigateToDevicesSubscription;
  EventSubscription<ChatNotificationTappedEvent>? _chatNotificationSubscription;
  EventSubscription<TransferOfferReceivedEvent>? _transferOfferSubscription;
  EventSubscription<MirrorPairCompletedEvent>? _mirrorPairSubscription;
  EventSubscription<NowNotificationTappedEvent>? _nowNotificationSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _themeService.addListener(_onThemeChanged);

    // Subscribe to DM notification tap events for deep linking (foreground only)
    _dmNotificationSubscription = EventBus().on<DMNotificationTappedEvent>((
      event,
    ) {
      print(
        'NOTIFICATION_DEBUG: *** DMNotificationTappedEvent received for ${event.targetCallsign} ***',
      );
      LogService().log(
        'GeogramApp: DM notification tapped for ${event.targetCallsign}',
      );
      _navigateToDMChat(event.targetCallsign);
    });
    _emailNotificationSubscription = EventBus().on<EmailNotificationTappedEvent>(
      (event) {
        LogService().log(
          'GeogramApp: Email notification tapped for thread ${event.threadId}',
        );
        unawaited(_navigateToEmailThread(event.threadId));
      },
    );

    // Subscribe to chat room notification tap events for deep linking
    _chatNotificationSubscription = EventBus().on<ChatNotificationTappedEvent>((
      event,
    ) {
      LogService().log(
        'GeogramApp: Chat notification tapped for room ${event.roomId}',
      );
      _navigateToChatRoom(event.roomId);
    });

    // Subscribe to navigate-to-devices events (e.g., summary notification tap)
    _navigateToDevicesSubscription = EventBus().on<NavigateToDevicesEvent>((_) {
      DebugController().navigateToPanel(PanelIndex.devices);
    });

    // Subscribe to incoming P2P transfer offers
    _transferOfferSubscription = EventBus().on<TransferOfferReceivedEvent>((
      event,
    ) {
      LogService().log(
        'GeogramApp: Transfer offer received from ${event.senderCallsign}',
      );
      _showTransferOfferDialog(event);
    });

    // Subscribe to mirror pairing completed (device B receives this)
    _mirrorPairSubscription = EventBus().on<MirrorPairCompletedEvent>((event) {
      if (_navigatorKey.currentContext == null) return;
      showDialog(
        context: _navigatorKey.currentContext!,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Mirror Active'),
          content: Text('You are now a mirror with ${event.peerCallsign}'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context); // close dialog
                // Pop back to main UI
                _navigatorKey.currentState?.popUntil((route) => route.isFirst);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      );
    });

    // Subscribe to generic Now notification taps (irc, telegram, aprs, alert, blog, events, places)
    _nowNotificationSubscription = EventBus().on<NowNotificationTappedEvent>((event) {
      LogService().log(
        'GeogramApp: Now notification tapped for ${event.appType}:${event.sourceId}',
      );
      _navigateToNowSource(event.appType, event.sourceId, event.sourceName);
    });

    // Check for pending notification on startup (handles cold start)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingNotification();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _themeService.removeListener(_onThemeChanged);
    _dmNotificationSubscription?.cancel();
    _emailNotificationSubscription?.cancel();
    _chatNotificationSubscription?.cancel();
    _navigateToDevicesSubscription?.cancel();
    _transferOfferSubscription?.cancel();
    _mirrorPairSubscription?.cancel();
    _nowNotificationSubscription?.cancel();
    // Close all encrypted storage connections
    EncryptedStorageService().closeAllArchives();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print(
      'NOTIFICATION_DEBUG: ${DateTime.now()} didChangeAppLifecycleState: $state',
    );
    // Flush IRC/XMPP message queues on app suspend/close to avoid data loss
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      ConfigService().saveNow();
      IrcService().flushWrites();
      XmppService().flushWrites();
      BitchatService().flushWrites();
    }

    if (state == AppLifecycleState.resumed) {
      // Verify native channel is working (may be stale after Android killed the engine)
      if (!kIsWeb && Platform.isAndroid) {
        BLEForegroundService().verifyChannelReady().then((isReady) {
          if (!isReady) {
            LogService().log('WARNING: Native channel not ready on resume');
          }
        });
      }

      // Verify WebSocket connection is still alive (Android background may have broken it)
      WebSocketService().onAppResumed();

      // Refresh BLE advertising (Android may have throttled it while screen was off)
      BLEIdentityService().refreshAdvertising();

      // Delay check to allow SharedPreferences write to complete in background isolate
      Future.delayed(const Duration(milliseconds: 500), () {
        print(
          'NOTIFICATION_DEBUG: ${DateTime.now()} delayed _checkPendingNotification',
        );
        _checkPendingNotification();
      });
    }
  }

  /// Check for pending notification action and navigate accordingly
  /// Uses SharedPreferences for cross-isolate communication (background notification tap)
  Future<void> _checkPendingNotification() async {
    print('NOTIFICATION_DEBUG: _checkPendingNotification called');
    final action = await DMNotificationService().consumePendingAction();
    print('NOTIFICATION_DEBUG: consumePendingAction returned: $action');
    if (action == null) return;

    print('NOTIFICATION_DEBUG: Processing ${action.type}:${action.data}');
    LogService().log(
      'GeogramApp: Processing pending notification: ${action.type}:${action.data}',
    );

    switch (action.type) {
      case 'dm':
        _navigateToDMChat(action.data);
        break;
      case 'nav':
        DebugController().navigateToPanel(2); // Devices panel
        break;
      case 'chat':
        _navigateToChatRoom(action.data);
        break;
      case 'email':
        await _navigateToEmailThread(action.data);
        break;
      case 'now':
        // Generic Now item: data = "appType:sourceId:sourceName"
        final parts = action.data.split(':');
        if (parts.length >= 2) {
          final appType = parts[0];
          final sourceId = parts[1];
          final sourceName = parts.length >= 3 ? parts.sublist(2).join(':') : '';
          _navigateToNowSource(appType, sourceId, sourceName);
        }
        break;
    }
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  /// Navigate to DM chat, waiting for navigator if needed (handles cold start timing)
  void _navigateToDMChat(String callsign) {
    print('NOTIFICATION_DEBUG: _navigateToDMChat called for $callsign');
    print(
      'NOTIFICATION_DEBUG: _navigatorKey.currentState = ${_navigatorKey.currentState}',
    );
    // If navigator is ready, navigate immediately
    if (_navigatorKey.currentState != null) {
      print('NOTIFICATION_DEBUG: Navigator ready, pushing DMChatPage');
      _navigatorKey.currentState!.push(
        MaterialPageRoute(
          builder: (context) =>
              DMChatPage(otherCallsign: callsign.toUpperCase()),
        ),
      );
      return;
    }

    // Navigator not ready yet (cold start) - wait for next frame and retry
    LogService().log('GeogramApp: Navigator not ready, waiting for next frame');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigateToDMChat(callsign);
    });
  }

  /// Navigate to a chat room, waiting for navigator if needed (handles cold start timing)
  void _navigateToChatRoom(String roomId) {
    if (_navigatorKey.currentState != null) {
      // Get the connected station, or use default P2P Radio station
      final stationService = StationService();
      final preferred = stationService.getPreferredStation();

      String stationUrl;
      String stationName;
      String? stationCallsign;

      if (preferred != null) {
        stationUrl = preferred.url;
        stationName = preferred.name;
        stationCallsign = preferred.callsign;
      } else {
        stationUrl = 'wss://p2p.radio';
        stationName = 'P2P Radio';
        stationCallsign = 'p2p_radio';
      }

      // Convert WebSocket URL to HTTP URL for API calls
      String remoteUrl = stationUrl;
      if (remoteUrl.startsWith('ws://')) {
        remoteUrl = remoteUrl.replaceFirst('ws://', 'http://');
      } else if (remoteUrl.startsWith('wss://')) {
        remoteUrl = remoteUrl.replaceFirst('wss://', 'https://');
      }

      LogService().log(
        'GeogramApp: Navigating to chat room $roomId at $remoteUrl',
      );

      _navigatorKey.currentState!.push(
        MaterialPageRoute(
          builder: (context) => ChatBrowserPage(
            remoteDeviceUrl: remoteUrl,
            remoteDeviceCallsign: stationCallsign,
            remoteDeviceName: stationName,
            initialRoomId: roomId,
          ),
        ),
      );
      return;
    }

    // Navigator not ready yet (cold start) - wait for next frame and retry
    LogService().log('GeogramApp: Navigator not ready for chat, waiting for next frame');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigateToChatRoom(roomId);
    });
  }

  Future<void> _navigateToEmailThread(String threadId) async {
    if (threadId.trim().isEmpty) return;

    if (_navigatorKey.currentState == null) {
      LogService().log('GeogramApp: Navigator not ready for email deep link');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_navigateToEmailThread(threadId));
      });
      return;
    }

    App? emailApp = AppService().getAppByType('email');
    if (emailApp == null) {
      try {
        emailApp = await AppService().createApp(title: 'Email', type: 'email');
      } catch (e) {
        LogService().log(
          'GeogramApp: Could not create email app for deep link: $e',
        );
        emailApp = AppService().getAppByType('email');
      }
    }
    if (emailApp == null) {
      LogService().log(
        'GeogramApp: Email app unavailable for notification deep link',
      );
      return;
    }

    _navigatorKey.currentState!.push(
      MaterialPageRoute(
        builder: (context) => EmailBrowserPage(
          app: emailApp,
          initialFolder: EmailFolder.inbox,
          initialThreadId: threadId,
        ),
      ),
    );
  }

  /// Navigate to a Now source by appType (mirrors NowPage._navigateToSource)
  void _navigateToNowSource(String appType, String sourceId, String sourceName) {
    if (_navigatorKey.currentState == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigateToNowSource(appType, sourceId, sourceName);
      });
      return;
    }

    switch (appType) {
      case 'irc':
        final parts = sourceId.split(':');
        if (parts.length >= 2) {
          _navigatorKey.currentState!.push(MaterialPageRoute(
            builder: (_) => IrcChatPage(serverId: parts[0], channel: parts.sublist(1).join(':')),
          ));
        }
        break;
      case 'telegram':
        final chatId = int.tryParse(sourceId);
        if (chatId != null) {
          _navigatorKey.currentState!.push(MaterialPageRoute(
            builder: (_) => TelegramChatPage(chatId: chatId, chatTitle: sourceName),
          ));
        }
        break;
      case 'aprs':
        final isTag = sourceId.startsWith('#');
        _navigatorKey.currentState!.push(MaterialPageRoute(
          builder: (_) => AprsConversationPage(
            conversationId: sourceId,
            conversationType: isTag ? AprsConversationType.tag : AprsConversationType.direct,
            partnerPosition: AprsService().lastKnownPositions[sourceId],
          ),
        ));
        break;
      case 'alert':
        _navigatorKey.currentState!.pushNamed('/alerts', arguments: sourceId);
        break;
      case 'chat':
        final station = StationService().getPreferredStation();
        if (station != null && station.url.isNotEmpty) {
          final device = RemoteDevice(
            callsign: station.callsign ?? 'STATION',
            name: station.name,
            url: station.url.replaceFirst('wss://', 'https://').replaceFirst('ws://', 'http://'),
            apps: [],
            source: DeviceSourceType.station,
          );
          _navigatorKey.currentState!.push(MaterialPageRoute(
            builder: (_) => RemoteChatRoomPage(
              device: device,
              room: ChatRoom(id: sourceId, name: sourceName, memberCount: 0, visibility: 'public'),
            ),
          ));
        }
        break;
      case 'blog':
        final station = StationService().getPreferredStation();
        if (station != null && station.url.isNotEmpty) {
          final device = RemoteDevice(
            callsign: station.callsign ?? 'STATION',
            name: station.name,
            url: station.url.replaceFirst('wss://', 'https://').replaceFirst('ws://', 'http://'),
            apps: [],
            source: DeviceSourceType.station,
          );
          _navigatorKey.currentState!.push(MaterialPageRoute(
            builder: (_) => RemoteBlogBrowserPage(device: device),
          ));
        }
        break;
      case 'events':
        final station = StationService().getPreferredStation();
        if (station != null && station.url.isNotEmpty) {
          _navigatorKey.currentState!.push(MaterialPageRoute(
            builder: (_) => EventsBrowserPage(
              remoteDeviceUrl: station.url.replaceFirst('wss://', 'https://').replaceFirst('ws://', 'http://'),
              remoteDeviceCallsign: station.callsign,
              remoteDeviceName: station.name,
            ),
          ));
        }
        break;
      case 'places':
        final station = StationService().getPreferredStation();
        if (station != null && station.url.isNotEmpty) {
          final url = station.url.replaceFirst('wss://', 'https://').replaceFirst('ws://', 'http://');
          _navigatorKey.currentState!.push(MaterialPageRoute(
            builder: (_) => ReportBrowserPage(
              remoteDeviceUrl: url,
              remoteDeviceCallsign: station.callsign,
              remoteDeviceName: station.name,
            ),
          ));
        }
        break;
    }
  }

  /// Show incoming transfer offer dialog
  void _showTransferOfferDialog(TransferOfferReceivedEvent event) async {
    final offer = P2PTransferService().getOffer(event.offerId);
    if (offer == null) return;
    if (_navigatorKey.currentContext == null) return;

    final accepted = await IncomingTransferDialog.show(
      _navigatorKey.currentContext!,
      offer,
    );

    LogService().log(
      'GeogramApp: Transfer offer ${event.offerId} ${accepted == true ? "accepted" : "declined"}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Geogram',
      debugShowCheckedModeBanner: false,
      theme: _themeService.getLightTheme(),
      darkTheme: _themeService.getDarkTheme(),
      themeMode: ThemeMode.system,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('pt'), Locale('de')],
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        return SafeArea(
          top: false,
          bottom: true,
          left: true,
          right: true,
          child: child,
        );
      },
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  int _unreadDmCount = 0;
  int _unreadNowCount = 0;
  StreamSubscription<Map<String, int>>? _unreadSubscription;
  StreamSubscription<int>? _unreadNowSubscription;
  StreamSubscription<DebugActionEvent>? _debugActionSubscription;
  StreamSubscription? _stationStateSubscription;
  EventSubscription<NavigateToHomeEvent>? _navigateHomeSubscription;
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();
  final DebugController _debugController = DebugController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  bool _isSearchFocused = false;

  // Hidden pages (not ready): BotPage
  // Indices: 0=Apps, 1=Now, 2=Maps, 3=Devices, 4=Log
  List<Widget> get _pages => [
    AppsPage(searchQuery: _searchQuery, onAppSelected: _clearSearchAndUnfocus),
    const NowPage(),
    const MapsBrowserPage(),
    const DevicesBrowserPage(),
    // BotPage(),  // Hidden: not ready
    const LogBrowserPage(),
  ];

  @override
  void initState() {
    super.initState();
    // Listen to language changes to rebuild the UI
    _i18n.languageNotifier.addListener(_onLanguageChanged);
    // Listen to profile changes to update title
    _profileService.profileNotifier.addListener(_onProfileChanged);
    // Listen for update availability notifications
    UpdateService().updateAvailable.addListener(_onUpdateAvailable);
    // Listen for debug navigation requests
    _debugController.panelNotifier.addListener(_onDebugNavigate);
    // Listen for debug toast requests
    _debugController.toastNotifier.addListener(_onDebugToast);
    // Listen for debug action events (for station chat navigation)
    _debugActionSubscription = _debugController.actionStream.listen(
      _onDebugAction,
    );
    // Listen for navigate to home events (e.g., from Settings back button)
    _navigateHomeSubscription = EventBus().on<NavigateToHomeEvent>((_) {
      if (mounted && _selectedIndex != 0) {
        setState(() => _selectedIndex = 0);
      }
    });

    // Subscribe to DM unread count changes
    _unreadDmCount = DirectMessageService().totalUnreadCount;
    _unreadSubscription = DirectMessageService().unreadCountsStream.listen((
      counts,
    ) {
      final total = counts.values.fold(0, (sum, count) => sum + count);
      if (total != _unreadDmCount && mounted) {
        setState(() {
          _unreadDmCount = total;
        });
      }
    });

    // Initialize NowService and notification bridge, subscribe to unread count
    NowService().initialize();
    NowNotificationBridge().initialize();
    _unreadNowCount = NowService().unreadCount;
    _unreadNowSubscription = NowService().unreadCountStream.listen((count) {
      if (count != _unreadNowCount && mounted) {
        setState(() {
          _unreadNowCount = count;
        });
      }
    });

    // Subscribe to station state changes to update the icon
    _stationStateSubscription = StationNodeService().stateStream.listen((_) {
      if (mounted) {
        setState(() {}); // Rebuild to update station icon
      }
    });
    // Force initial rebuild to show current station state (station may already be running)
    Future.microtask(() {
      if (mounted) setState(() {});
    });

    // Check for first launch and show profile setup
    _checkFirstLaunch();

    // Listen to search focus changes
    _searchFocusNode.addListener(_onSearchFocusChanged);
  }

  void _onSearchFocusChanged() {
    if (mounted) {
      setState(() => _isSearchFocused = _searchFocusNode.hasFocus);
    }
  }

  void _clearSearchAndUnfocus() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _searchQuery = '';
      _isSearchFocused = false;
    });
  }

  @override
  void dispose() {
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _i18n.languageNotifier.removeListener(_onLanguageChanged);
    _profileService.profileNotifier.removeListener(_onProfileChanged);
    UpdateService().updateAvailable.removeListener(_onUpdateAvailable);
    _debugController.panelNotifier.removeListener(_onDebugNavigate);
    _debugController.toastNotifier.removeListener(_onDebugToast);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debugActionSubscription?.cancel();
    _navigateHomeSubscription?.cancel();
    _unreadSubscription?.cancel();
    _unreadNowSubscription?.cancel();
    _stationStateSubscription?.cancel();
    super.dispose();
  }

  /// Handle debug API navigation requests
  void _onDebugNavigate() {
    if (!mounted) return;
    final panelIndex = _debugController.panelNotifier.value;
    if (panelIndex != null && panelIndex >= 0 && panelIndex < _pages.length) {
      setState(() {
        _selectedIndex = panelIndex;
        NowService().feedVisible = (panelIndex == 1);
      });
      // Reset the notifier to allow repeated navigations to same panel
      _debugController.panelNotifier.value = null;
      LogService().log('Debug: Navigated to panel $panelIndex');
    }
  }

  /// Handle debug API toast requests
  void _onDebugToast() {
    final toast = _debugController.toastNotifier.value;
    if (toast != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(toast.message),
          duration: toast.duration,
          behavior: SnackBarBehavior.floating,
        ),
      );
      // Reset the notifier to allow repeated toasts
      _debugController.toastNotifier.value = null;
      LogService().log('Debug: Toast shown: ${toast.message}');
    }
  }

  /// Handle debug action events
  void _onDebugAction(DebugActionEvent event) {
    if (event.action == DebugAction.openStationChat) {
      _handleOpenStationChat();
    } else if (event.action == DebugAction.openLocalChat) {
      _handleOpenLocalChat();
    } else if (event.action == DebugAction.openWelcomePage) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => WelcomePage(
            onComplete: () => Navigator.of(context).pop(),
          ),
        ),
      );
    } else if (event.action == DebugAction.openDM) {
      final callsign = event.params['callsign'] as String?;
      if (callsign != null) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                DMChatPage(otherCallsign: callsign.toUpperCase()),
          ),
        );
      }
    } else if (event.action == DebugAction.openFlasherMonitor) {
      _handleOpenFlasherMonitor(event.params['device_path'] as String?);
    } else if (event.action == DebugAction.openExternalFile) {
      _handleOpenExternalFile(
        event.params['path'] as String,
        event.params['mimeType'] as String?,
      );
    } else if (event.action == DebugAction.mirrorOpenSettings) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const MirrorSettingsPage()),
      );
    } else if (event.action == DebugAction.mirrorOpenWizard) {
      Navigator.push(
        context,
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const MirrorWizardPage(),
        ),
      );
    }
  }

  /// Handle opening external file in appropriate viewer
  void _handleOpenExternalFile(String path, String? mimeType) {
    LogService().log('HomePage: Opening external file: $path ($mimeType)');

    final ext = path.split('.').last.toLowerCase();
    final isImage = {'jpg', 'jpeg', 'png'}.contains(ext);
    final isVideo = {
      'mp4',
      'avi',
      'mkv',
      'mov',
      'wmv',
      'flv',
      'webm',
    }.contains(ext);
    final isPdf = ext == 'pdf';

    if (!mounted) return;

    if (isImage || isVideo) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PhotoViewerPage(imagePaths: [path])),
      );
    } else if (isPdf) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DocumentViewerEditorPage(
            filePath: path,
            viewerType: DocumentViewerType.pdf,
          ),
        ),
      );
    }
  }

  /// Handle opening Flasher on Monitor tab with optional auto-connect
  void _handleOpenFlasherMonitor(String? devicePath) async {
    LogService().log(
      'HomePage: Opening Flasher Monitor (devicePath: $devicePath)',
    );

    // Find flasher app
    var flasherApp = AppService().getAppByType('flasher');

    // Auto-create flasher app if it doesn't exist
    if (flasherApp == null) {
      LogService().log(
        'HomePage: No flasher app found, creating one automatically',
      );
      try {
        flasherApp = await AppService().createApp(
          title: _i18n.t('app_type_flasher'),
          type: 'flasher',
        );
        LogService().log(
          'HomePage: Created flasher app: ${flasherApp.storagePath}',
        );
      } catch (e) {
        LogService().log('HomePage: Failed to create flasher app: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to create Flasher: $e'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
    }

    if (flasherApp.storagePath == null) {
      LogService().log('HomePage: Flasher app has no storage path');
      return;
    }

    // Navigate to apps panel first
    setState(() => _selectedIndex = 0);

    // Navigate to FlasherPage with Monitor tab and auto-connect
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FlasherPage(
            basePath: flasherApp!.storagePath!,
            initialTab: 2, // Monitor tab
            autoConnectPort: devicePath,
          ),
        ),
      );
      LogService().log('HomePage: Navigated to FlasherPage Monitor tab');
    }
  }

  /// Handle opening the station chat app and first chat room
  void _handleOpenStationChat() {
    print('HomePage: Opening station chat via debug action');

    // Get the connected station, or use default P2P Radio station
    final stationService = StationService();
    final preferred = stationService.getPreferredStation();

    // Use default station if none configured
    String stationUrl;
    String stationName;
    String? stationCallsign;

    if (preferred != null) {
      stationUrl = preferred.url;
      stationName = preferred.name;
      stationCallsign = preferred.callsign;
      print('HomePage: Using preferred station: $stationName');
    } else {
      // Use default P2P Radio station
      stationUrl = 'wss://p2p.radio';
      stationName = 'P2P Radio';
      stationCallsign = 'p2p_radio';
      print('HomePage: No preferred station, using default P2P Radio');
    }

    // Convert WebSocket URL to HTTP URL for API calls (same as UI does)
    String remoteUrl = stationUrl;
    if (remoteUrl.startsWith('ws://')) {
      remoteUrl = remoteUrl.replaceFirst('ws://', 'http://');
    } else if (remoteUrl.startsWith('wss://')) {
      remoteUrl = remoteUrl.replaceFirst('wss://', 'https://');
    }

    print('HomePage: Opening ChatBrowserPage with URL: $remoteUrl');

    // Navigate to ChatBrowserPage with remote device parameters (same as UI)
    // Auto-select the 'general' room
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatBrowserPage(
            remoteDeviceUrl: remoteUrl,
            remoteDeviceCallsign: stationCallsign,
            remoteDeviceName: stationName,
            initialRoomId: 'general',
          ),
        ),
      );
      print('HomePage: Navigation pushed with initialRoomId=general');
    }
  }

  /// Handle opening a local chat app (for testing encrypted storage)
  void _handleOpenLocalChat() async {
    print('HomePage: Opening local chat app via debug action');

    // Find a chat app
    final chatApp = AppService().getAppByType('chat');

    if (chatApp == null) {
      print('HomePage: No chat app found, creating one');
      // Create a chat app if none exists
      try {
        final newApp = await AppService().createApp(
          title: 'Chat',
          type: 'chat',
        );
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatBrowserPage(app: newApp),
            ),
          );
        }
      } catch (e) {
        print('HomePage: Failed to create chat app: $e');
      }
      return;
    }

    print(
      'HomePage: Found chat app: ${chatApp.title} at ${chatApp.storagePath}',
    );

    // Navigate to ChatBrowserPage with the local app
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => ChatBrowserPage(app: chatApp)),
      );
      print('HomePage: Navigation pushed for local chat app');
    }
  }

  /// Check if this is the first launch and show welcome dialog or onboarding
  void _checkFirstLaunch() {
    final config = ConfigService().getAll();
    final firstLaunchComplete = config['firstLaunchComplete'] as bool? ?? false;

    if (!firstLaunchComplete) {
      // Show welcome/onboarding after first frame
      // NOTE: Default apps are NOT created here - they are created when
      // the user confirms their callsign in WelcomePage via finalizeProfileIdentity()
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted) {
          // Check if --skip-intro flag was passed (useful for automated testing)
          if (AppArgs().skipIntro) {
            // Mark first launch as complete, create apps, and skip all intro screens
            ConfigService().set('firstLaunchComplete', true);
            await _createDefaultApps();
            LogService().log('Skipping intro screens (--skip-intro flag)');
            return;
          }

          // On Android, show full onboarding with permissions
          // On other platforms, show simple welcome dialog
          if (!kIsWeb && Platform.isAndroid) {
            _showOnboarding();
          } else {
            _showWelcomeDialog();
          }
        }
      });
    }
  }

  /// Show the Android onboarding flow
  void _showOnboarding() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => OnboardingPage(
          onComplete: () async {
            Navigator.of(context).pop();
            // Pre-download offline maps in background
            _preDownloadOfflineMaps();
            // Show the welcome page after onboarding
            // NOTE: firstLaunchComplete is set in WelcomePage when user finalizes profile
            _showWelcomeDialog();

            // Start ProximityDetectionService now that onboarding is complete
            // (was skipped during deferred initialization)
            _startProximityServiceAfterOnboarding();
          },
        ),
      ),
    );
  }

  /// Start ProximityDetectionService after onboarding completes
  Future<void> _startProximityServiceAfterOnboarding() async {
    final proximityDisabled =
        ConfigService().getNestedValue('tracker.proximityTrackingEnabled') ==
        false;

    if (proximityDisabled) {
      LogService().log('[PROXIMITY] Tracking disabled by user setting');
      return;
    }

    try {
      var appPath = ConfigService().getNestedValue('tracker.proximityAppPath');

      if (appPath is! String || appPath.isEmpty) {
        final tracker = AppService().getAppByType('tracker');
        if (tracker?.storagePath != null) {
          appPath = tracker!.storagePath;
          ConfigService().setNestedValue('tracker.proximityAppPath', appPath);
        }
      }

      if (appPath is String && appPath.isNotEmpty) {
        final profileCallsign = ProfileService().getProfile().callsign;
        // Set up storage for TrackerService (encrypted or filesystem)
        final profileStorage = AppService().profileStorage;
        if (profileStorage != null) {
          final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
            profileStorage,
            appPath,
          );
          TrackerService().setStorage(scopedStorage);
        } else {
          TrackerService().setStorage(FilesystemProfileStorage(appPath));
        }
        await TrackerService().initializeApp(
          appPath,
          callsign: profileCallsign,
        );
        await ProximityDetectionService().start(TrackerService());
        LogService().log(
          '[PROXIMITY] Started after onboarding - app: $appPath',
        );
      }
    } catch (e) {
      LogService().log('[PROXIMITY] Failed to start after onboarding: $e');
    }
  }

  /// Start StationService after onboarding completes
  Future<void> _startStationServiceAfterOnboarding() async {
    try {
      await StationService().initialize();
      LogService().log('StationService initialized after onboarding');
    } catch (e) {
      LogService().log('StationService failed to start after onboarding: $e');
    }
  }

  /// Create default apps for first launch
  Future<void> _createDefaultApps() async {
    final appService = AppService();

    LogService().log(
      'Creating default apps. Path: ${appService.getDefaultAppsPath()}',
    );

    for (final type in AppService.defaultAppTypes) {
      try {
        final title = _i18n.t('app_type_$type');
        LogService().log('Creating default app: $type (title: $title)');
        await appService.createApp(title: title, type: type);
        LogService().log('Created default app: $type');
      } catch (e, stackTrace) {
        // App might already exist, skip
        LogService().log('Failed creating $type app: $e');
        LogService().log('Stack trace: $stackTrace');
      }
    }

    LogService().log('Default apps creation complete');
  }

  /// Pre-download offline maps on first launch (100km radius around current position)
  /// Runs in background, doesn't block UI. Uses station if available, falls back to direct internet.
  void _preDownloadOfflineMaps() async {
    // Check if already pre-downloaded
    final hasPreDownloaded =
        ConfigService().get('offlineMapPreDownloaded') == true;
    if (hasPreDownloaded) return;

    final locationService = UserLocationService();

    // Wait for GPS position (up to 30 seconds)
    for (int i = 0; i < 30; i++) {
      final location = locationService.currentLocation;
      if (location != null && location.isValid) break;
      await Future.delayed(const Duration(seconds: 1));
    }

    final location = locationService.currentLocation;
    if (location == null || !location.isValid) {
      LogService().log('First-launch map download: No GPS position, skipping');
      return;
    }

    final lat = location.latitude;
    final lng = location.longitude;

    LogService().log('First-launch map download: Starting for ($lat, $lng)');

    try {
      final downloaded = await MapTileService().downloadTilesForRadius(
        lat: lat,
        lng: lng,
        radiusKm: 100,
        minZoom: 8,
        maxZoom: 12,
      );

      // Mark as done
      ConfigService().set('offlineMapPreDownloaded', true);
      LogService().log(
        'First-launch map download: Complete ($downloaded tiles)',
      );
    } catch (e) {
      LogService().log('First-launch map download: Error: $e');
    }
  }

  /// Show welcome page with generated callsign (full-screen)
  void _showWelcomeDialog() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => WelcomePage(
          onComplete: () {
            Navigator.of(context).pop();
            // Start StationService now that profile is finalized
            _startStationServiceAfterOnboarding();
          },
        ),
      ),
    );
  }

  void _onLanguageChanged() {
    if (mounted) setState(() {});
  }

  void _onProfileChanged() {
    if (mounted) setState(() {});
  }

  /// Called when UpdateService detects an available update
  void _onUpdateAvailable() {
    final updateService = UpdateService();
    final settings = updateService.getSettings();

    // Only show notification if enabled in settings and update is actually available
    if (!updateService.updateAvailable.value || !settings.notifyOnUpdate) {
      return;
    }

    // Don't show banner if UpdatePage is currently visible
    if (updateService.isUpdatePageVisible) {
      return;
    }

    // Don't show banner during onboarding - let user complete initial setup first
    final firstLaunchComplete =
        ConfigService().getNestedValue('firstLaunchComplete', false) as bool;
    if (!firstLaunchComplete) {
      return;
    }

    final latestRelease = updateService.getLatestRelease();
    if (latestRelease == null || !mounted) return;
    if (!updateService.shouldNotifyForRelease(latestRelease)) {
      return;
    }

    // Show a MaterialBanner at the top of the screen
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        padding: const EdgeInsets.all(16),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _i18n.t('update_available'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              _i18n.t(
                'update_available_version',
                params: [latestRelease.version],
              ),
            ),
          ],
        ),
        leading: const Icon(Icons.system_update, color: Colors.blue),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              unawaited(
                updateService.dismissUpdateNotification(latestRelease.version),
              );
            },
            child: Text(_i18n.t('later')),
          ),
          FilledButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              // Navigate directly to Updates page
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UpdatePage()),
              );
            },
            child: Text(_i18n.t('view_update')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Don't allow back gesture to exit app when on Apps (index 0)
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // Close settings drawer if it's open
        final scaffoldState = Scaffold.maybeOf(context);
        if (scaffoldState?.isEndDrawerOpen == true) {
          scaffoldState?.closeEndDrawer();
          return;
        }
        // Check if DevicesBrowserPage needs to handle back (viewing device details)
        if (_selectedIndex == 3 && DevicesBrowserPage.onBackPressed != null) {
          // Let DevicesBrowserPage handle it - it will clear the selected device
          final handled = DevicesBrowserPage.onBackPressed!();
          if (handled) {
            // Back was handled by DevicesBrowserPage, don't navigate away
            return;
          }
        }
        if (_selectedIndex != 0) {
          // Navigate back to Apps panel
          setState(() {
            _selectedIndex = 0;
          });
        }
        // If already on Apps, do nothing (stay there)
      },
      child: Scaffold(
        // Disable swipe gesture to open settings drawer - only open via menu icon
        endDrawerEnableOpenDragGesture: false,
        // Show AppBar only on Apps panel (index 0) and Now panel (index 1) for full-screen Map/Devices
        appBar: _selectedIndex == 0 || _selectedIndex == 1
            ? AppBar(
                automaticallyImplyLeading: false,
                leading: _isSearchFocused
                    ? IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: _clearSearchAndUnfocus,
                      )
                    : null,
                title: Row(
                  children: [
                    // Show ProfileSwitcher only when search is not focused
                    if (!_isSearchFocused) ...[
                      const ProfileSwitcher(),
                      const SizedBox(width: 12),
                    ],
                    // Search field
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          decoration: InputDecoration(
                            hintText: _i18n.t('search_apps'),
                            hintStyle: TextStyle(
                              fontSize: 14,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            prefixIcon: const Icon(Icons.search, size: 20),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 18),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _searchQuery = '');
                                    },
                                  )
                                : null,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(20),
                              borderSide: BorderSide.none,
                            ),
                            filled: true,
                            fillColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 0,
                            ),
                            isDense: true,
                          ),
                          style: const TextStyle(fontSize: 14),
                          onChanged: (value) =>
                              setState(() => _searchQuery = value),
                        ),
                      ),
                    ),
                  ],
                ),
                actions: [
                  // Mark all as read button on Now panel
                  if (_selectedIndex == 1 && _unreadNowCount > 0)
                    IconButton(
                      icon: const Icon(Icons.done_all),
                      tooltip: _i18n.t('now_mark_all_read'),
                      onPressed: () {
                        NowService().markAllAsRead();
                      },
                    ),
                  // Show station indicator if current profile is a station
                  if (_profileService.getProfile().isRelay)
                    IconButton(
                      icon: Icon(
                        Icons.cell_tower,
                        color: StationNodeService().isRunning
                            ? Colors.green
                            : null,
                      ),
                      tooltip: _i18n.t('station_dashboard'),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const StationDashboardPage(),
                          ),
                        );
                      },
                    ),
                  // Menu icon - opens settings drawer from right
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.menu),
                      tooltip: _i18n.t('settings'),
                      onPressed: () {
                        Scaffold.of(context).openEndDrawer();
                      },
                    ),
                  ),
                ],
              )
            : null,
        drawer: NavigationDrawer(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (int index) {
            setState(() {
              _selectedIndex = index;
              NowService().feedVisible = (index == 1);
            });
            Navigator.pop(context);
          },
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Text(
                _i18n.t('navigation'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            NavigationDrawerDestination(
              icon: const Icon(Icons.apps_outlined),
              selectedIcon: const Icon(Icons.apps),
              label: Text(_i18n.t('apps')),
            ),
            NavigationDrawerDestination(
              icon: Badge(
                isLabelVisible: _unreadNowCount > 0,
                label: Text(
                  _unreadNowCount > 99 ? '99+' : _unreadNowCount.toString(),
                ),
                child: const Icon(Icons.dynamic_feed_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: _unreadNowCount > 0,
                label: Text(
                  _unreadNowCount > 99 ? '99+' : _unreadNowCount.toString(),
                ),
                child: const Icon(Icons.dynamic_feed),
              ),
              label: Text(_i18n.t('now')),
            ),
            NavigationDrawerDestination(
              icon: const Icon(Icons.map_outlined),
              selectedIcon: const Icon(Icons.map),
              label: Text(_i18n.t('map')),
            ),
            NavigationDrawerDestination(
              icon: Badge(
                isLabelVisible: _unreadDmCount > 0,
                label: Text(
                  _unreadDmCount > 99 ? '99+' : _unreadDmCount.toString(),
                ),
                child: const Icon(Icons.devices_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: _unreadDmCount > 0,
                label: Text(
                  _unreadDmCount > 99 ? '99+' : _unreadDmCount.toString(),
                ),
                child: const Icon(Icons.devices),
              ),
              label: Text(_i18n.t('devices')),
            ),
            // NavigationDrawerDestination for Bot - Hidden: not ready
            // NavigationDrawerDestination(
            //   icon: const Icon(Icons.smart_toy_outlined),
            //   selectedIcon: const Icon(Icons.smart_toy),
            //   label: Text(_i18n.t('bot')),
            // ),
            const Divider(),
            NavigationDrawerDestination(
              icon: const Icon(Icons.article_outlined),
              selectedIcon: const Icon(Icons.article),
              label: Text(_i18n.t('log')),
            ),
          ],
        ),
        endDrawer: Drawer(
          child: SafeArea(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _i18n.t('settings'),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(_i18n.t('profile')),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const ProfilePage(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.security_outlined),
                  title: Text(_i18n.t('security')),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const SecuritySettingsPage(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: Text(_i18n.t('storage')),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const StorageSettingsPage(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.task_alt),
                  title: Text(_i18n.t('task_monitor')),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const TaskSettingsPage(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.settings_input_antenna),
                  title: Text(_i18n.t('connections')),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const StationsPage(),
                      ),
                    );
                  },
                ),
                if (Platform.isAndroid)
                  ListTile(
                    leading: const Icon(Icons.wifi_tethering),
                    title: Text(_i18n.t('hotspot')),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const HotspotSettingsPage(),
                        ),
                      );
                    },
                  ),
                if (_profileService.getProfile().isRelay)
                  ListTile(
                    leading: const Icon(Icons.cell_tower, color: Colors.orange),
                    title: Text(_i18n.t('station_settings')),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const StationDashboardPage(),
                        ),
                      );
                    },
                  ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.language),
                  title: Text(_i18n.t('language')),
                  subtitle: Text(_i18n.getLanguageName(_i18n.currentLanguage)),
                  onTap: () async {
                    Navigator.pop(context);
                    final selectedLanguage = await showDialog<String>(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          title: Text(_i18n.t('select_language')),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: _i18n.supportedLanguages.map((
                              languageCode,
                            ) {
                              return RadioListTile<String>(
                                title: Text(
                                  _i18n.getLanguageName(languageCode),
                                ),
                                value: languageCode,
                                groupValue: _i18n.currentLanguage,
                                onChanged: (String? value) {
                                  Navigator.pop(context, value);
                                },
                              );
                            }).toList(),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(_i18n.t('cancel')),
                            ),
                          ],
                        );
                      },
                    );
                    if (selectedLanguage != null &&
                        selectedLanguage != _i18n.currentLanguage) {
                      await _i18n.setLanguage(selectedLanguage);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.color_lens_outlined),
                  title: Text(_i18n.t('app_theme')),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const ThemeSettingsPage(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.system_update),
                  title: Text(_i18n.t('software_updates')),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const UpdatePage(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.info_outlined),
                  title: Text(_i18n.t('about')),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => AboutPage()),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        body: _pages[_selectedIndex],
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex < 4 ? _selectedIndex : 0,
          onDestinationSelected: (int index) {
            setState(() {
              _selectedIndex = index;
              NowService().feedVisible = (index == 1);
            });
          },
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.apps_outlined),
              selectedIcon: const Icon(Icons.apps),
              label: _i18n.t('apps'),
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: _unreadNowCount > 0,
                label: Text(
                  _unreadNowCount > 99 ? '99+' : _unreadNowCount.toString(),
                ),
                child: const Icon(Icons.dynamic_feed_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: _unreadNowCount > 0,
                label: Text(
                  _unreadNowCount > 99 ? '99+' : _unreadNowCount.toString(),
                ),
                child: const Icon(Icons.dynamic_feed),
              ),
              label: _i18n.t('now'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.map_outlined),
              selectedIcon: const Icon(Icons.map),
              label: _i18n.t('map'),
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: _unreadDmCount > 0,
                label: Text(
                  _unreadDmCount > 99 ? '99+' : _unreadDmCount.toString(),
                ),
                child: const Icon(Icons.devices_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: _unreadDmCount > 0,
                label: Text(
                  _unreadDmCount > 99 ? '99+' : _unreadDmCount.toString(),
                ),
                child: const Icon(Icons.devices),
              ),
              label: _i18n.t('devices'),
            ),
            // NavigationDestination for Bot - Hidden: not ready
            // NavigationDestination(
            //   icon: const Icon(Icons.smart_toy_outlined),
            //   selectedIcon: const Icon(Icons.smart_toy),
            //   label: _i18n.t('bot'),
            // ),
          ],
        ),
      ),
    );
  }
}

// Apps Page
class AppsPage extends StatefulWidget {
  final String searchQuery;
  final VoidCallback? onAppSelected;

  const AppsPage({super.key, this.searchQuery = '', this.onAppSelected});

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _DefaultAppType {
  final String type;
  final IconData icon;
  const _DefaultAppType(this.type, this.icon);
}

class _AppsPageState extends State<AppsPage> {
  final AppService _appService = AppService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final ChatNotificationService _chatNotificationService =
      ChatNotificationService();
  StreamSubscription<Map<String, int>>? _unreadSubscription;
  StreamSubscription<DebugActionEvent>? _debugActionSubscription;
  Map<String, int> _unreadCounts = {};

  List<App> _allApps = [];
  bool _isLoading = true;

  /// Get filtered apps based on search query from parent
  List<App> get _filteredApps {
    if (widget.searchQuery.isEmpty) {
      return _allApps;
    }
    final query = widget.searchQuery.toLowerCase();
    return _allApps.where((app) {
      // Search by title
      final title = app.title.toLowerCase();
      if (title.contains(query)) return true;
      // Search by translated type name
      final typeName = _i18n.t('app_type_${app.type}').toLowerCase();
      if (typeName.contains(query)) return true;
      // Search by type description
      final descKey = 'app_type_desc_${app.type}';
      final description = _i18n.t(descKey).toLowerCase();
      if (description != descKey.toLowerCase() && description.contains(query)) {
        return true;
      }
      return false;
    }).toList();
  }

  // Default single-instance app types that should always appear
  // These match the types in CreateAppPage
  static const List<_DefaultAppType> _defaultAppTypes = [
    _DefaultAppType('places', Icons.place),
    _DefaultAppType('blog', Icons.article),
    _DefaultAppType('chat', Icons.chat),
    _DefaultAppType('email', Icons.email),
    _DefaultAppType('contacts', Icons.contacts),
    _DefaultAppType('events', Icons.event),
    _DefaultAppType('alerts', Icons.campaign),
    _DefaultAppType('inventory', Icons.inventory_2),
    _DefaultAppType('wallet', Icons.account_balance_wallet),
    _DefaultAppType('log', Icons.article_outlined),
    _DefaultAppType('backup', Icons.backup),
    _DefaultAppType('console', Icons.terminal),
    _DefaultAppType('reader', Icons.menu_book),
    _DefaultAppType('karma', Icons.emoji_events),
  ];

  @override
  void initState() {
    super.initState();
    _i18n.languageNotifier.addListener(_onLanguageChanged);
    _profileService.activeProfileNotifier.addListener(_onProfileChanged);
    _appService.appsNotifier.addListener(_onAppsChanged);
    _debugActionSubscription = DebugController().actionStream.listen(
      _handleDebugAction,
    );
    LogService().log('AppsPage: initState - setting up listeners');
    _loadApps();
    _subscribeToUnreadCounts();
  }

  void _onProfileChanged() {
    if (!mounted) return;
    // Profile changed, reload apps for the new profile
    LogService().log('Profile changed, reloading apps');
    _loadApps();
  }

  void _onAppsChanged() {
    if (!mounted) return;
    // Apps were created/updated/deleted, reload the list
    LogService().log('AppsPage: appsNotifier triggered, reloading');
    _loadApps();
  }

  void _subscribeToUnreadCounts() {
    _unreadCounts = _chatNotificationService.unreadCounts;
    _unreadSubscription = _chatNotificationService.unreadCountsStream.listen((
      counts,
    ) {
      if (mounted) {
        setState(() {
          _unreadCounts = counts;
        });
      }
    });
  }

  void _onLanguageChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _i18n.languageNotifier.removeListener(_onLanguageChanged);
    _profileService.activeProfileNotifier.removeListener(_onProfileChanged);
    _appService.appsNotifier.removeListener(_onAppsChanged);
    _unreadSubscription?.cancel();
    _debugActionSubscription?.cancel();
    super.dispose();
  }

  /// Build a WorkPage with ProfileStorage from AppService
  Widget _buildWorkPage(App app) {
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) {
      // Fallback: if no profile storage, show error
      return Center(child: Text(_i18n.t('work_storage_not_available')));
    }

    // Extract relative path from absolute storagePath
    final storagePath = app.storagePath ?? '';
    final basePath = profileStorage.basePath;
    String relativePath;

    if (storagePath.startsWith(basePath)) {
      // Remove basePath prefix and clean up leading slashes
      relativePath = storagePath.substring(basePath.length);
      while (relativePath.startsWith('/')) {
        relativePath = relativePath.substring(1);
      }
      // Also remove trailing slashes
      while (relativePath.endsWith('/')) {
        relativePath = relativePath.substring(0, relativePath.length - 1);
      }
    } else {
      // Fallback: use basename
      relativePath =
          storagePath.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
    }

    return WorkPage(
      storage: profileStorage,
      relativePath: relativePath,
      appTitle: app.title,
    );
  }

  Future<void> _loadApps() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final apps = await _appService.loadAppsFast();
      if (!mounted) return;
      _updateAppsList(apps, isComplete: true);

      final types = apps.map((c) => c.type).toList();
      LogService().log('AppsPage: Loaded ${apps.length} apps: $types');
    } catch (e) {
      LogService().log('Error loading apps: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _updateAppsList(List<App> apps, {required bool isComplete}) {
    if (!mounted) return;

    // Pre-fetch usage counts once — avoids O(N log N) config lookups in sort
    final config = ConfigService();
    final usageCache = <String, int>{};
    for (final app in apps) {
      usageCache[app.type] =
          config.getNestedValue('apps.usage.${app.type}', 0) as int;
    }

    apps.sort((a, b) {
      if (a.isFavorite != b.isFavorite) {
        return a.isFavorite ? -1 : 1;
      }
      final aUsage = usageCache[a.type] ?? 0;
      final bUsage = usageCache[b.type] ?? 0;
      if (aUsage != bUsage) {
        return bUsage.compareTo(aUsage);
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    setState(() {
      _allApps = apps;
      _isLoading = !isComplete;
    });
  }

  Future<void> _createNewApp() async {
    final result = await Navigator.push<App>(
      context,
      MaterialPageRoute(builder: (context) => const CreateAppPage()),
    );

    if (result != null) {
      // App was created, reload the list
      _loadApps();
    }
  }

  void _toggleFavorite(App app) {
    _appService.toggleFavorite(app);
    setState(() {});
    LogService().log('Toggled favorite for ${app.title}');
  }

  void _handleDebugAction(DebugActionEvent event) {
    if (event.action == DebugAction.openConsole) {
      unawaited(
        _openConsoleApp(sessionId: event.params['session_id'] as String?),
      );
    }
  }

  Future<void> _deleteApp(App app) async {
    // No confirmation needed - data is not deleted from disk and apps can be re-added
    if (!mounted) return;
    try {
      await _appService.deleteApp(app);
      LogService().log('Deleted app: ${app.title}');
      _loadApps();
    } catch (e) {
      LogService().log('Error deleting app: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error deleting app: $e')));
      }
    }
  }

  /// Record app usage to enable sorting by frequency
  void _recordAppUsage(String appType) {
    final config = ConfigService();
    final key = 'apps.usage.$appType';
    final currentCount = config.getNestedValue(key, 0) as int;
    config.setNestedValue(key, currentCount + 1);
  }

  /// Check if an app is a placeholder (not yet created on disk)
  bool _isPlaceholder(App app) {
    return app.id.startsWith('__placeholder_');
  }

  /// Create an app from a placeholder when triggered via debug API
  Future<App?> _createAppFromPlaceholder(App placeholder) async {
    try {
      final created = await _appService.createApp(
        title: placeholder.title,
        type: placeholder.type,
      );
      await _loadApps();
      return created;
    } catch (e) {
      LogService().log(
        'AppsPage: Failed to create placeholder ${placeholder.type}: $e',
      );
      return null;
    }
  }

  Future<App?> _findConsoleAppEntry() async {
    return _appService.getAppByType('console');
  }

  Future<void> _openConsoleApp({String? sessionId}) async {
    App? consoleApp;
    try {
      consoleApp = _allApps.firstWhere(
        (c) => c.type == 'console' && !_isPlaceholder(c),
      );
    } catch (_) {}

    if (consoleApp == null) {
      try {
        final placeholder = _allApps.firstWhere((c) => c.type == 'console');
        consoleApp = await _createAppFromPlaceholder(placeholder);
      } catch (_) {}
    }

    if (consoleApp != null && _isPlaceholder(consoleApp)) {
      consoleApp = await _createAppFromPlaceholder(consoleApp);
    }

    consoleApp ??= await _findConsoleAppEntry();
    if (!mounted || consoleApp == null) {
      try {
        final title = _i18n.t('app_type_console');
        consoleApp = await _appService.createApp(title: title, type: 'console');
        await _loadApps();
        LogService().log(
          'AppsPage: Created console app for debug open_console',
        );
      } catch (e) {
        LogService().log(
          'AppsPage: Console app not found and create failed: $e',
        );
        return;
      }
    }

    final appPath = consoleApp.storagePath ?? '';
    final appTitle = consoleApp.title;

    _recordAppUsage(consoleApp.type);
    LogService().log(
      'AppsPage: Opening console via debug action (session: ${sessionId ?? "first"})',
    );

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ConsoleBrowserPage(appPath: appPath, appTitle: appTitle),
      ),
    );

    if (mounted) {
      _loadApps();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filteredApps = _filteredApps;

    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _allApps.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.folder_special_outlined,
                    size: 64,
                    color: theme.colorScheme.secondary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _i18n.t('no_apps_yet'),
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _i18n.t('create_your_first_app'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : filteredApps.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.search_off,
                    size: 64,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _i18n.t('no_apps_found'),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _i18n.t('try_different_search'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadApps,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Calculate number of columns based on screen width
                  final screenWidth = constraints.maxWidth;
                  final crossAxisCount = screenWidth < 600
                      ? 2 // Mobile/Small: 2 columns
                      : screenWidth < 900
                      ? 4 // Tablet: 4 columns
                      : screenWidth < 1400
                      ? 6 // Desktop: 6 columns
                      : screenWidth < 1800
                      ? 7 // Large desktop: 7 columns
                      : 8; // Extra large: 8 columns

                  return CustomScrollView(
                    slivers: [
                      // App grid
                      if (filteredApps.isNotEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          sliver: SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: crossAxisCount,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                  childAspectRatio: 1.9,
                                ),
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final appEntry = filteredApps[index];
                              return _AppGridCard(
                                app: appEntry,
                                onTap: () {
                                  // Clear search when app is selected
                                  widget.onAppSelected?.call();
                                  _recordAppUsage(appEntry.type);
                                  LogService().log(
                                    'Opened app: ${appEntry.title}',
                                  );
                                  // Route to appropriate page based on app type
                                  final Widget targetPage =
                                      appEntry.type == 'chat'
                                      ? ChatBrowserPage(app: appEntry)
                                      : appEntry.type == 'email'
                                      ? EmailBrowserPage(app: appEntry)
                                      : appEntry.type == 'forum'
                                      ? ForumBrowserPage(app: appEntry)
                                      : appEntry.type == 'blog'
                                      ? BlogBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'news'
                                      ? NewsBrowserPage(app: appEntry)
                                      : appEntry.type == 'events'
                                      ? EventsBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'postcards'
                                      ? PostcardsBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'contacts'
                                      ? ContactsBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'places'
                                      ? PlacesBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'market'
                                      ? MarketBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'inventory'
                                      ? InventoryBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                          i18n: _i18n,
                                        )
                                      : appEntry.type == 'tracker'
                                      ? TrackerBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                          i18n: _i18n,
                                        )
                                      : appEntry.type == 'alerts'
                                      ? ReportBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'groups'
                                      ? GroupsBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'backup'
                                      ? const BackupBrowserPage()
                                      : appEntry.type == 'station'
                                      ? const StationDashboardPage()
                                      : appEntry.type == 'transfer'
                                      ? const TransferPage()
                                      : appEntry.type == 'wallet'
                                      ? WalletBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                          i18n: _i18n,
                                        )
                                      : appEntry.type == 'console'
                                      ? ConsoleBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'log'
                                      ? const LogBrowserPage()
                                      : appEntry.type == 'videos'
                                      ? VideoBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'transfer'
                                      ? const TransferPage()
                                      : appEntry.type == 'reader'
                                      ? ReaderHomePage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                          i18n: _i18n,
                                        )
                                      : appEntry.type == 'flasher'
                                      ? FlasherPage(
                                          basePath: appEntry.storagePath ?? '',
                                        )
                                      : appEntry.type == 'work'
                                      ? _buildWorkPage(appEntry)
                                      : appEntry.type == 'usenet'
                                      ? const UsenetAppPage()
                                      : appEntry.type == 'music'
                                      ? MusicHomePage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                          i18n: _i18n,
                                        )
                                      : appEntry.type == 'stories'
                                      ? StoriesHomePage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                          i18n: _i18n,
                                        )
                                      : appEntry.type == 'files'
                                      ? FilesBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                          i18n: _i18n,
                                        )
                                      : appEntry.type == 'qr'
                                      ? QrBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'www'
                                      ? WebsiteBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                          i18n: _i18n,
                                        )
                                      : appEntry.type == 'conference'
                                      ? const ConferenceHomePage()
                                      : appEntry.type == 'shared'
                                      ? SharedBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'teleport'
                                      ? TeleportBrowserPage(
                                          appPath: appEntry.storagePath ?? '',
                                          appTitle: appEntry.title,
                                        )
                                      : appEntry.type == 'karma'
                                      ? const KarmaPage()
                                      : AppBrowserPage(app: appEntry);

                                  LogService().log(
                                    'Opening app: ${appEntry.title} (type: ${appEntry.type}) -> ${targetPage.runtimeType}',
                                  );
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => targetPage,
                                    ),
                                  ).then((_) => _loadApps());
                                },
                                onFavoriteToggle: () =>
                                    _toggleFavorite(appEntry),
                                onDelete: () => _deleteApp(appEntry),
                                unreadCount: appEntry.type == 'chat'
                                    ? _chatNotificationService.totalUnreadCount
                                    : 0,
                              );
                            }, childCount: filteredApps.length),
                          ),
                        ),

                    ],
                  );
                },
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewApp,
        icon: const Icon(Icons.add),
        label: Text(_i18n.t('add_new_app')),
      ),
    );
  }
}

// App Grid Card Widget (compact design for grid layout)
class _AppGridCard extends StatelessWidget {
  final App app;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onDelete;
  final int unreadCount;

  const _AppGridCard({
    required this.app,
    required this.onTap,
    required this.onFavoriteToggle,
    required this.onDelete,
    this.unreadCount = 0,
  });

  /// Get display title with proper capitalization and translation for app types
  String _getDisplayTitle() {
    final i18n = I18nService();
    if (app.title.isNotEmpty) {
      // Try to get translated label for known app types
      final key = 'app_type_${app.type}';
      final translated = i18n.t(key);
      if (translated != key) {
        return translated;
      }
      // Special case for www -> WWW
      if (app.title.toLowerCase() == 'www') {
        return 'WWW';
      }
      return app.title[0].toUpperCase() + app.title.substring(1);
    }
    return app.title;
  }

  /// Get appropriate icon based on app type
  IconData _getAppIcon() => getAppTypeIcon(app.type);

  /// Get gradient colors for app type icon
  LinearGradient _getTypeGradient(bool isDark) =>
      getAppTypeGradient(app.type, isDark);

  void _showContextMenu(BuildContext context, Offset position) {
    final i18n = I18nService();
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'favorite',
          child: Row(
            children: [
              Icon(
                app.isFavorite ? Icons.star : Icons.star_border,
                color: app.isFavorite ? Colors.amber : null,
              ),
              const SizedBox(width: 8),
              Text(i18n.t('favorite')),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              const Icon(Icons.delete_outline),
              const SizedBox(width: 8),
              Text(i18n.t('delete')),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'favorite') {
        onFavoriteToggle();
      } else if (value == 'delete') {
        onDelete();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();
    final isAndroid = !kIsWeb && Platform.isAndroid;
    final isDark = theme.brightness == Brightness.dark;
    final gradient = _getTypeGradient(isDark);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        onTap: onTap,
        onLongPress: isAndroid
            ? () {
                final RenderBox box = context.findRenderObject() as RenderBox;
                final Offset position = box.localToGlobal(Offset.zero);
                _showContextMenu(context, position);
              }
            : null,
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Badge(
                      isLabelVisible: unreadCount > 0,
                      label: Text('$unreadCount'),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          gradient: gradient,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: gradient.colors.first.withValues(
                                alpha: 0.25,
                              ),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          _getAppIcon(),
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        _getDisplayTitle(),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          height: 1.15,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Favorite badge (top-left corner)
            if (app.isFavorite)
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.star, size: 10, color: Colors.white),
                ),
              ),
            // Menu button (bottom-right corner, only on desktop)
            if (!isAndroid)
              Positioned(
                bottom: 2,
                right: 2,
                child: PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_horiz,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  tooltip: i18n.t('options'),
                  onSelected: (value) {
                    if (value == 'favorite') {
                      onFavoriteToggle();
                    } else if (value == 'delete') {
                      onDelete();
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem<String>(
                      value: 'favorite',
                      child: Row(
                        children: [
                          Icon(
                            app.isFavorite ? Icons.star : Icons.star_border,
                            color: app.isFavorite ? Colors.amber : null,
                          ),
                          const SizedBox(width: 8),
                          Text(i18n.t('favorite')),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'delete',
                      child: Row(
                        children: [
                          const Icon(Icons.remove_circle_outline),
                          const SizedBox(width: 8),
                          Text(i18n.t('remove')),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// App Card Widget (original list design - kept for reference)
class _AppCard extends StatelessWidget {
  final App app;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onDelete;
  final VoidCallback onOpenFolder;

  const _AppCard({
    required this.app,
    required this.onTap,
    required this.onFavoriteToggle,
    required this.onDelete,
    required this.onOpenFolder,
  });

  /// Get appropriate icon based on app type
  IconData _getAppIcon() => getAppTypeIcon(app.type);

  /// Get gradient colors for app type icon
  LinearGradient _getTypeGradient(bool isDark) =>
      getAppTypeGradient(app.type, isDark);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final gradient = _getTypeGradient(isDark);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Circular gradient icon
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: gradient,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: gradient.colors.first.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(_getAppIcon(), color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                app.title,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                app.isFavorite ? Icons.star : Icons.star_border,
                                color: app.isFavorite ? Colors.amber : null,
                                size: 22,
                              ),
                              onPressed: onFavoriteToggle,
                              tooltip: 'Toggle Favorite',
                              visualDensity: VisualDensity.compact,
                            ),
                            IconButton(
                              icon: const Icon(Icons.folder_open, size: 22),
                              onPressed: onOpenFolder,
                              tooltip: 'Open Folder',
                              visualDensity: VisualDensity.compact,
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 22),
                              onPressed: onDelete,
                              tooltip: 'Delete',
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                        if (app.description.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              app.description,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _InfoChip(
                    icon: Icons.calendar_today_outlined,
                    label: app.formattedDate,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Info Chip Widget
class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

// GeoChat Page
class GeoChatPage extends StatelessWidget {
  const GeoChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    final i18n = I18nService();
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            i18n.t('geochat'),
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            i18n.t('your_conversations_will_appear_here'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// DevicesPage has been moved to pages/devices_browser_page.dart
// LogPage has been moved to pages/log_browser_page.dart
// SettingsPage has been removed - settings are now in the EndDrawer

// ============================================================================
// APP BROWSER PAGE
// ============================================================================

class AppBrowserPage extends StatefulWidget {
  final App app;

  const AppBrowserPage({super.key, required this.app});

  @override
  State<AppBrowserPage> createState() => _AppBrowserPageState();
}

class _AppBrowserPageState extends State<AppBrowserPage> {
  final AppService _appService = AppService();
  final I18nService _i18n = I18nService();
  final TextEditingController _searchController = TextEditingController();
  List<FileNode> _allFiles = [];
  List<FileNode> _filteredFiles = [];
  bool _isLoading = true;
  final Set<String> _expandedFolders = {}; // Track expanded folder paths

  @override
  void initState() {
    super.initState();
    _i18n.languageNotifier.addListener(_onLanguageChanged);
    _loadFiles();
  }

  void _onLanguageChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _i18n.languageNotifier.removeListener(_onLanguageChanged);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFiles() async {
    setState(() => _isLoading = true);

    try {
      final files = await _appService.loadFileTree(widget.app);
      setState(() {
        _allFiles = files;
        _filteredFiles = files;
        _isLoading = false;
      });
      LogService().log('Loaded ${files.length} items in app');
    } catch (e) {
      LogService().log('Error loading files: $e');
      setState(() => _isLoading = false);
    }
  }

  void _filterFiles(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredFiles = _allFiles;
      } else {
        _filteredFiles = _searchInFileTree(_allFiles, query.toLowerCase());
      }
    });
  }

  List<FileNode> _searchInFileTree(List<FileNode> nodes, String query) {
    final results = <FileNode>[];

    for (var node in nodes) {
      // Check if current node matches
      final nameMatches = node.name.toLowerCase().contains(query);

      if (node.isDirectory && node.children != null) {
        // Search in children
        final matchingChildren = _searchInFileTree(node.children!, query);

        if (nameMatches || matchingChildren.isNotEmpty) {
          // Include this folder if it matches or has matching children
          results.add(
            FileNode(
              path: node.path,
              name: node.name,
              size: node.size,
              isDirectory: true,
              children: matchingChildren.isEmpty
                  ? node.children
                  : matchingChildren,
              fileCount: node.fileCount,
            ),
          );
          // Auto-expand folders with matching content
          _expandedFolders.add(node.path);
        }
      } else if (nameMatches) {
        // File matches
        results.add(node);
      }
    }

    return results;
  }

  Future<void> _addFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        dialogTitle: _i18n.t('select_files_to_add'),
      );

      if (result != null && result.files.isNotEmpty) {
        final paths = result.files.map((f) => f.path!).toList();
        LogService().log('Adding ${paths.length} files to app');

        await _appService.addFiles(widget.app, paths);
        LogService().log('Files added successfully');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _i18n.t('added_files', params: [paths.length.toString()]),
              ),
            ),
          );
        }

        _loadFiles();
      }
    } catch (e) {
      LogService().log('Error adding files: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _i18n.t('error_adding_files', params: [e.toString()]),
            ),
          ),
        );
      }
    }
  }

  Future<void> _addFolder() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: _i18n.t('select_folder_to_add'),
      );

      if (result != null) {
        LogService().log('Adding folder to app: $result');

        await _appService.addFolder(widget.app, result);
        LogService().log('Folder added successfully');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('folder_added_successfully'))),
          );
        }

        _loadFiles();
      }
    } catch (e) {
      LogService().log('Error adding folder: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _i18n.t('error_adding_folder', params: [e.toString()]),
            ),
          ),
        );
      }
    }
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();

    final folderName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('create_folder')),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: _i18n.t('folder_name'),
            hintText: _i18n.t('enter_folder_name'),
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            Navigator.pop(context, controller.text.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context, controller.text.trim());
            },
            child: Text(_i18n.t('create')),
          ),
        ],
      ),
    );

    controller.dispose();

    if (folderName != null && folderName.isNotEmpty) {
      try {
        LogService().log('Creating folder: $folderName');

        await _appService.createFolder(widget.app, folderName);
        LogService().log('Folder created successfully');

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(_i18n.t('folder_created'))));
        }

        _loadFiles();
      } catch (e) {
        LogService().log('Error creating folder: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _i18n.t('error_creating_folder', params: [e.toString()]),
              ),
            ),
          );
        }
      }
    }
  }

  Future<void> _editSettings() async {
    final updated = await showDialog<bool>(
      context: context,
      builder: (context) => EditAppDialog(app: widget.app),
    );

    if (updated == true) {
      setState(() {});
    }
  }

  Future<void> _refreshAppFiles() async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('regenerating_app_files'))),
      );

      // Force regeneration of all app files
      await _appService.ensureAppFilesUpdated(widget.app, force: true);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('app_files_regenerated'))),
        );
      }
    } catch (e) {
      LogService().log('Error refreshing app files: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _i18n.t('error_regenerating_files', params: [e.toString()]),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.app.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshAppFiles,
            tooltip: _i18n.t('refresh_app_files'),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _editSettings,
            tooltip: _i18n.t('app_settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          // App Info
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.app.description.isNotEmpty)
                  Text(
                    widget.app.description,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${widget.app.filesCount} ${widget.app.filesCount == 1 ? _i18n.t('file') : _i18n.t('files')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(width: 16),
                    Icon(
                      Icons.storage_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      widget.app.formattedSize,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(width: 16),
                    Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _i18n.t(widget.app.visibility),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: _i18n.t('search_files'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _filterFiles('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              onChanged: _filterFiles,
            ),
          ),

          // Add Files/Folders Buttons
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _addFiles,
                    icon: const Icon(Icons.add),
                    label: Text(_i18n.t('add_files')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _addFolder,
                    icon: const Icon(Icons.folder_open),
                    label: Text(_i18n.t('add_folder')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _createFolder,
                    icon: const Icon(Icons.create_new_folder),
                    label: Text(_i18n.t('create_folder')),
                  ),
                ),
              ],
            ),
          ),

          // Files List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredFiles.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.folder_open,
                          size: 64,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _searchController.text.isEmpty
                              ? _i18n.t('no_files_yet')
                              : _i18n.t('no_matching_files'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _searchController.text.isEmpty
                              ? _i18n.t('add_files_to_get_started')
                              : _i18n.t('try_a_different_search'),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadFiles,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _filteredFiles.length,
                      itemBuilder: (context, index) {
                        final file = _filteredFiles[index];
                        return _FileNodeTile(
                          fileNode: file,
                          expandedFolders: _expandedFolders,
                          appPath: widget.app.storagePath ?? '',
                          onToggleExpand: (path) {
                            setState(() {
                              if (_expandedFolders.contains(path)) {
                                _expandedFolders.remove(path);
                              } else {
                                _expandedFolders.add(path);
                              }
                            });
                          },
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// File Node Tile Widget
class _FileNodeTile extends StatefulWidget {
  final FileNode fileNode;
  final int indentLevel;
  final Set<String> expandedFolders;
  final void Function(String) onToggleExpand;
  final String appPath;

  const _FileNodeTile({
    required this.fileNode,
    required this.expandedFolders,
    required this.onToggleExpand,
    required this.appPath,
    this.indentLevel = 0,
  });

  @override
  State<_FileNodeTile> createState() => _FileNodeTileState();
}

class _FileNodeTileState extends State<_FileNodeTile> {
  dynamic _thumbnailFile; // File on native, null on web

  @override
  void initState() {
    super.initState();
    // Only load thumbnails on native platforms (not web)
    if (!kIsWeb &&
        !widget.fileNode.isDirectory &&
        FileIconHelper.isImage(widget.fileNode.name)) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    if (kIsWeb) return; // No local file access on web

    try {
      final filePath = '${widget.appPath}/${widget.fileNode.path}';
      final file = File(filePath);
      if (await file.exists()) {
        setState(() {
          _thumbnailFile = file;
        });
      }
    } catch (e) {
      // Ignore thumbnail errors
    }
  }

  String _formatSize(int size) {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatSubtitle() {
    final i18n = I18nService();
    if (widget.fileNode.isDirectory) {
      final fileCount = widget.fileNode.fileCount;
      final size = _formatSize(widget.fileNode.size);
      if (fileCount == 1) {
        return '1 ${i18n.t('file')} • $size';
      } else {
        return '$fileCount ${i18n.t('files')} • $size';
      }
    } else {
      return _formatSize(widget.fileNode.size);
    }
  }

  Future<void> _openFile() async {
    if (widget.fileNode.isDirectory) return;

    final i18n = I18nService();

    // On web, file operations are not supported
    if (kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File operations not supported on web')),
        );
      }
      return;
    }

    try {
      final filePath = '${widget.appPath}/${widget.fileNode.path}';
      final file = File(filePath);

      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(i18n.t('file_not_found'))));
        }
        return;
      }

      final uri = Uri.file(filePath);
      LogService().log('Opening file: $filePath');

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(i18n.t('cannot_open_file_type'))),
          );
        }
        LogService().log('Cannot launch file: $filePath');
      }
    } catch (e) {
      LogService().log('Error opening file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(i18n.t('error_opening_file', params: [e.toString()])),
          ),
        );
      }
    }
  }

  Widget _buildLeading(BuildContext context) {
    if (widget.fileNode.isDirectory) {
      // Folder icon
      return Icon(
        Icons.folder,
        size: 40,
        color: Theme.of(context).colorScheme.primary,
      );
    } else if (!kIsWeb && _thumbnailFile != null) {
      // Image thumbnail (only on native platforms)
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          _thumbnailFile!,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Icon(
              FileIconHelper.getIconForFile(widget.fileNode.name),
              size: 40,
              color: FileIconHelper.getColorForFile(
                widget.fileNode.name,
                context,
              ),
            );
          },
        ),
      );
    } else {
      // File type icon
      return Icon(
        FileIconHelper.getIconForFile(widget.fileNode.name),
        size: 40,
        color: FileIconHelper.getColorForFile(widget.fileNode.name, context),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isExpanded = widget.expandedFolders.contains(widget.fileNode.path);
    final hasChildren =
        widget.fileNode.isDirectory &&
        widget.fileNode.children != null &&
        widget.fileNode.children!.isNotEmpty;

    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.only(
            left: 16.0 + (widget.indentLevel * 24.0),
          ),
          leading: _buildLeading(context),
          title: Text(widget.fileNode.name),
          subtitle: Text(_formatSubtitle()),
          trailing: widget.fileNode.isDirectory && hasChildren
              ? Icon(
                  isExpanded ? Icons.expand_more : Icons.chevron_right,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                )
              : null,
          onTap: widget.fileNode.isDirectory && hasChildren
              ? () {
                  widget.onToggleExpand(widget.fileNode.path);
                }
              : widget.fileNode.isDirectory
              ? null
              : _openFile,
        ),
        // Show children only if directory is expanded
        if (widget.fileNode.isDirectory && hasChildren && isExpanded)
          ...widget.fileNode.children!.map(
            (child) => _FileNodeTile(
              fileNode: child,
              expandedFolders: widget.expandedFolders,
              onToggleExpand: widget.onToggleExpand,
              appPath: widget.appPath,
              indentLevel: widget.indentLevel + 1,
            ),
          ),
      ],
    );
  }
}

// ============================================================================
// EDIT APP DIALOG
// ============================================================================

class EditAppDialog extends StatefulWidget {
  final App app;

  const EditAppDialog({super.key, required this.app});

  @override
  State<EditAppDialog> createState() => _EditAppDialogState();
}

class _EditAppDialogState extends State<EditAppDialog> {
  final AppService _appService = AppService();
  final I18nService _i18n = I18nService();
  late TextEditingController _titleController;
  late TextEditingController _descriptionController;
  late String _visibility;
  late String _encryption;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.app.title);
    _descriptionController = TextEditingController(
      text: widget.app.description,
    );
    _visibility = widget.app.visibility;
    _encryption = widget.app.encryption;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();

    if (title.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_i18n.t('please_enter_a_title'))));
      return;
    }

    setState(() => _isSaving = true);

    try {
      // Capture old title before updating
      final oldTitle = widget.app.title;

      // Update app properties
      widget.app.title = title;
      widget.app.description = _descriptionController.text.trim();
      widget.app.visibility = _visibility;
      widget.app.encryption = _encryption;

      // Save to disk (will rename folder if title changed)
      await _appService.updateApp(widget.app, oldTitle: oldTitle);

      LogService().log('Updated app settings: ${widget.app.title}');

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e, stackTrace) {
      LogService().log('ERROR updating app: $e');
      LogService().log('Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _i18n.t('error_updating_app', params: [e.toString()]),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_i18n.t('app_settings')),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // App ID (read-only)
              Text(
                _i18n.t('app_id'),
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  widget.app.id,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontFamily: 'Courier New'),
                ),
              ),
              const SizedBox(height: 16),

              // Title
              TextField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: _i18n.t('app_title'),
                  border: const OutlineInputBorder(),
                ),
                enabled: !_isSaving,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),

              // Description
              TextField(
                controller: _descriptionController,
                decoration: InputDecoration(
                  labelText: _i18n.t('description'),
                  border: const OutlineInputBorder(),
                ),
                maxLines: 3,
                enabled: !_isSaving,
              ),
              const SizedBox(height: 16),

              const Divider(),
              const SizedBox(height: 8),

              Text(
                _i18n.t('permissions'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),

              // Visibility
              DropdownButtonFormField<String>(
                initialValue: _visibility,
                decoration: InputDecoration(
                  labelText: _i18n.t('visibility'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'public',
                    child: Text(_i18n.t('public')),
                  ),
                  DropdownMenuItem(
                    value: 'private',
                    child: Text(_i18n.t('private')),
                  ),
                  DropdownMenuItem(
                    value: 'restricted',
                    child: Text(_i18n.t('restricted')),
                  ),
                ],
                onChanged: _isSaving
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _visibility = value);
                        }
                      },
              ),
              const SizedBox(height: 16),

              // Encryption
              DropdownButtonFormField<String>(
                initialValue: _encryption,
                decoration: InputDecoration(
                  labelText: _i18n.t('encryption'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'none',
                    child: Text(_i18n.t('encryption_none')),
                  ),
                  DropdownMenuItem(
                    value: 'aes256',
                    child: Text(_i18n.t('encryption_aes256')),
                  ),
                ],
                onChanged: _isSaving
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _encryption = value);
                        }
                      },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.pop(context, false),
          child: Text(_i18n.t('cancel')),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_i18n.t('save')),
        ),
      ],
    );
  }
}

/// Minimal app used when Geogram is launched via a file VIEW intent.
/// Shows the appropriate viewer and exits on Back press.
class FileViewerApp extends StatelessWidget {
  final String filePath;
  final String mimeType;

  const FileViewerApp({
    super.key,
    required this.filePath,
    required this.mimeType,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) {
            SystemNavigator.pop();
          }
        },
        child: _buildViewer(),
      ),
    );
  }

  Widget _buildViewer() {
    if (mimeType == 'application/pdf') {
      return DocumentViewerEditorPage(
        filePath: filePath,
        readOnly: true,
      );
    }
    // Images and videos
    return PhotoViewerPage(imagePaths: [filePath]);
  }
}
