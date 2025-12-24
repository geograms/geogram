import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' if (dart.library.html) 'platform/io_stub.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart' if (dart.library.html) 'platform/window_manager_stub.dart';
import 'services/log_service.dart';
import 'services/log_api_service.dart';
import 'version.dart';
import 'services/debug_controller.dart';
import 'services/config_service.dart';
import 'services/collection_service.dart';
import 'services/profile_service.dart';
import 'services/station_service.dart';
import 'services/station_discovery_service.dart';
import 'services/notification_service.dart';
import 'services/i18n_service.dart';
import 'services/chat_notification_service.dart';
import 'services/dm_notification_service.dart';
import 'services/update_service.dart';
import 'services/devices_service.dart';
import 'services/ble_permission_service.dart';
import 'services/storage_config.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/web_theme_service.dart';
import 'services/app_args.dart';
import 'services/security_service.dart';
import 'services/network_monitor_service.dart';
import 'services/user_location_service.dart';
import 'services/direct_message_service.dart';
import 'services/backup_service.dart';
import 'cli/pure_storage_config.dart';
import 'connection/connection_manager.dart';
import 'connection/transports/lan_transport.dart';
import 'connection/transports/ble_transport.dart';
import 'connection/transports/bluetooth_classic_transport.dart';
import 'connection/transports/station_transport.dart';
import 'connection/transports/webrtc_transport.dart';
import 'models/collection.dart';
import 'util/file_icon_helper.dart';
import 'pages/profile_page.dart';
import 'pages/about_page.dart';
import 'pages/update_page.dart';
import 'pages/stations_page.dart';
import 'pages/location_page.dart';
// import 'pages/notifications_page.dart'; // TODO: Not yet implemented
import 'pages/chat_browser_page.dart';
import 'pages/forum_browser_page.dart';
import 'pages/blog_browser_page.dart';
import 'pages/events_browser_page.dart';
import 'pages/news_browser_page.dart';
import 'pages/postcards_browser_page.dart';
import 'pages/contacts_browser_page.dart';
import 'pages/places_browser_page.dart';
import 'pages/market_browser_page.dart';
import 'pages/report_browser_page.dart';
import 'pages/groups_browser_page.dart';
import 'pages/maps_browser_page.dart';
import 'pages/station_dashboard_page.dart';
import 'pages/devices_browser_page.dart';
import 'pages/backup_browser_page.dart';
import 'pages/profile_management_page.dart';
import 'pages/create_collection_page.dart';
import 'pages/onboarding_page.dart';
import 'pages/security_settings_page.dart';
import 'widgets/profile_switcher.dart';
import 'cli/console.dart';

void main() async {
  print('MAIN: Starting Geogram (kIsWeb: $kIsWeb)'); // Debug

  // Parse command line arguments early (before any other initialization)
  if (!kIsWeb) {
    // For Flutter desktop apps, Platform.executableArguments contains Flutter engine args
    // On Linux, we read /proc/self/cmdline to get the actual command-line arguments
    List<String> allArgs = [];
    try {
      final cmdline = File('/proc/self/cmdline').readAsStringSync();
      allArgs = cmdline.split('\x00').where((s) => s.isNotEmpty).skip(1).toList();
    } catch (e) {
      // Fallback to executableArguments (may be empty for desktop)
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

  WidgetsFlutterBinding.ensureInitialized();

  // Apply Android intent extras (test mode, etc.)
  await AppArgs().applyAndroidExtras();

  // Initialize window manager for desktop platforms (not web or mobile)
  if (!kIsWeb) {
    try {
      // Only import and use window_manager on desktop platforms
      // This code will be tree-shaken out on web builds
      await windowManager.ensureInitialized();

      const windowOptions = WindowOptions(
        size: Size(1200, 800),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.normal,
      );

      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
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
    LogService().log('CLI args: port=${AppArgs().port}, dataDir=${AppArgs().dataDir ?? "default"}');
  }

  try {
    // PHASE 1: Critical services (must complete before UI)
    // These are fast and required for the app to function

    // Initialize storage configuration first (all other services depend on it)
    // Use custom data directory from CLI args if specified
    await StorageConfig().init(customBaseDir: AppArgs().dataDir);
    LogService().log('StorageConfig initialized: ${StorageConfig().baseDir}');

    // Also initialize PureStorageConfig with same base directory
    // This enables CLI components (like PureStationServer) to be used in GUI mode
    await PureStorageConfig().init(customBaseDir: StorageConfig().baseDir);
    LogService().log('PureStorageConfig initialized (shared with CLI)');

    // Initialize config and i18n in parallel (both are independent)
    await Future.wait([
      ConfigService().init().then((_) => LogService().log('ConfigService initialized')),
      I18nService().init().then((_) => LogService().log('I18nService initialized')),
    ]);

    // Initialize web theme service (extracts bundled themes on first run)
    await WebThemeService().init();
    LogService().log('WebThemeService initialized');

    // Initialize profile and collection services
    await CollectionService().init();
    LogService().log('CollectionService initialized');

    await ProfileService().initialize();
    LogService().log('ProfileService initialized');

    // Set active callsign for collection storage path
    final profile = ProfileService().getProfile();
    await CollectionService().setActiveCallsign(profile.callsign);
    LogService().log('CollectionService callsign set: ${profile.callsign}');

    // Initialize notification service (needed for UI badges)
    await NotificationService().initialize();
    LogService().log('NotificationService initialized');

    // Initialize chat notification service (needed for unread counts)
    ChatNotificationService().initialize();
    LogService().log('ChatNotificationService initialized');

    // Initialize DM notification service (for push notifications on mobile)
    // Skip permission request on first launch - onboarding will handle it
    bool firstLaunch = false;
    if (!kIsWeb && Platform.isAndroid) {
      final firstLaunchComplete = ConfigService().getNestedValue('firstLaunchComplete', false);
      firstLaunch = firstLaunchComplete != true;
    }
    await DMNotificationService().initialize(skipPermissionRequest: firstLaunch);
    LogService().log('DMNotificationService initialized (skipPermission: $firstLaunch)');

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
      // Initialize location service (GPS on mobile, IP-based on desktop/web)
      // Must run after ProfileService to load saved location
      await UserLocationService().initialize();
      LogService().log('UserLocationService initialized (deferred)');

      // StationService can involve network calls - defer it
      await StationService().initialize();
      LogService().log('StationService initialized (deferred)');

      // Initialize ConnectionManager with transports after StationService
      // This is needed for DevicesService to route requests properly
      // Transport priority: LAN (10) > WebRTC (15) > Station (30) > BT Classic (35) > BLE (40)
      final connectionManager = ConnectionManager();
      connectionManager.registerTransport(LanTransport());
      connectionManager.registerTransport(WebRTCTransport());
      connectionManager.registerTransport(StationTransport());
      connectionManager.registerTransport(BluetoothClassicTransport());
      connectionManager.registerTransport(BleTransport());
      await connectionManager.initialize();
      LogService().log('ConnectionManager initialized with LAN + WebRTC + Station + BT Classic + BLE transports (deferred)');

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
        LogService().log('Peer discovery API started on port ${LogApiService().port} (deferred)');
      } else {
        LogService().log('Peer discovery API disabled by security settings');
      }

      // Check if first launch is complete (user has seen onboarding screen)
      final firstLaunchComplete = ConfigService().getNestedValue('firstLaunchComplete', false) as bool;

      // For first-time users on Android, skip BLE initialization here
      // The onboarding screen will request permissions and then reinitialize BLE
      if (!kIsWeb && Platform.isAndroid && !firstLaunchComplete) {
        LogService().log('DevicesService: Skipping BLE init for first launch - onboarding will handle permissions');
        // Initialize DevicesService but skip BLE on first launch
        await DevicesService().initialize(skipBLE: true);
        LogService().log('DevicesService initialized (deferred, BLE skipped for onboarding)');
      } else {
        // For returning users on Android, check permissions without requesting
        // Skip BLE permissions in internet-only mode
        if (!kIsWeb && Platform.isAndroid && firstLaunchComplete && !AppArgs().internetOnly) {
          LogService().log('Checking BLE permissions on Android (returning user)...');

          // Check permissions using permission_handler directly (doesn't trigger Bluetooth initialization)
          final scanStatus = await Permission.bluetoothScan.status;
          final connectStatus = await Permission.bluetoothConnect.status;
          final advertiseStatus = await Permission.bluetoothAdvertise.status;

          final hasAllPermissions = scanStatus.isGranted &&
                                   connectStatus.isGranted &&
                                   advertiseStatus.isGranted;

          LogService().log('BLE permissions check: hasAllPermissions=$hasAllPermissions');

          if (!hasAllPermissions) {
            LogService().log('BLE permissions not granted - skipping BLE initialization (user can enable in settings)');
            // Initialize DevicesService but skip BLE
            await DevicesService().initialize(skipBLE: true);
            LogService().log('DevicesService initialized (deferred, BLE skipped - permissions not granted)');
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

      // Initialize NetworkMonitorService to track LAN/Internet connectivity
      await NetworkMonitorService().initialize();
      LogService().log('NetworkMonitorService initialized');

      // Initialize BackupService for E2E encrypted backups
      await BackupService().initialize();
      LogService().log('BackupService initialized');
    } catch (e, stackTrace) {
      LogService().log('ERROR during deferred initialization: $e');
      LogService().log('Stack trace: $stackTrace');
    }
  });
  return; // Early return since runApp is already called
}

class GeogramApp extends StatelessWidget {
  const GeogramApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Geogram',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
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
  StreamSubscription<Map<String, int>>? _unreadSubscription;
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();
  final DebugController _debugController = DebugController();

  static const List<Widget> _pages = [
    CollectionsPage(),
    MapsBrowserPage(),
    DevicesBrowserPage(),
    SettingsPage(),
    LogPage(),
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

    // Subscribe to DM unread count changes
    _unreadDmCount = DirectMessageService().totalUnreadCount;
    _unreadSubscription = DirectMessageService().unreadCountsStream.listen((counts) {
      final total = counts.values.fold(0, (sum, count) => sum + count);
      if (total != _unreadDmCount) {
        setState(() {
          _unreadDmCount = total;
        });
      }
    });

    // Check for first launch and show profile setup
    _checkFirstLaunch();
  }

  @override
  void dispose() {
    _i18n.languageNotifier.removeListener(_onLanguageChanged);
    _profileService.profileNotifier.removeListener(_onProfileChanged);
    UpdateService().updateAvailable.removeListener(_onUpdateAvailable);
    _debugController.panelNotifier.removeListener(_onDebugNavigate);
    _debugController.toastNotifier.removeListener(_onDebugToast);
    _unreadSubscription?.cancel();
    super.dispose();
  }

  /// Handle debug API navigation requests
  void _onDebugNavigate() {
    final panelIndex = _debugController.panelNotifier.value;
    if (panelIndex != null && panelIndex >= 0 && panelIndex < _pages.length) {
      setState(() {
        _selectedIndex = panelIndex;
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

  /// Check if this is the first launch and show welcome dialog or onboarding
  void _checkFirstLaunch() {
    final config = ConfigService().getAll();
    final firstLaunchComplete = config['firstLaunchComplete'] as bool? ?? false;

    if (!firstLaunchComplete) {
      // Create default collections and show welcome/onboarding after first frame
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted) {
          await _createDefaultCollections();
          if (mounted) {
            // Check if --skip-intro flag was passed (useful for automated testing)
            if (AppArgs().skipIntro) {
              // Mark first launch as complete and skip all intro screens
              ConfigService().set('firstLaunchComplete', true);
              LogService().log('Skipping intro screens (--skip-intro flag)');
              return;
            }

            // On Android, show full onboarding with permissions
            // On other platforms, show simple welcome dialog
            if (!kIsWeb && Platform.isAndroid) {
              _showOnboarding();
            } else {
              // Mark first launch as complete for non-Android platforms
              ConfigService().set('firstLaunchComplete', true);
              _showWelcomeDialog();
            }
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
          onComplete: () {
            // Mark first launch as complete
            ConfigService().set('firstLaunchComplete', true);
            Navigator.of(context).pop();
            // Show the welcome dialog after onboarding
            _showWelcomeDialog();
          },
        ),
      ),
    );
  }

  /// Create default collections for first launch
  Future<void> _createDefaultCollections() async {
    final collectionService = CollectionService();
    final defaultTypes = ['chat', 'blog', 'alerts'];

    LogService().log('Creating default collections. Path: ${collectionService.getDefaultCollectionsPath()}');

    for (final type in defaultTypes) {
      try {
        final title = _i18n.t('collection_type_$type');
        LogService().log('Creating default collection: $type (title: $title)');
        await collectionService.createCollection(
          title: title,
          type: type,
        );
        LogService().log('Created default collection: $type');
      } catch (e, stackTrace) {
        // Collection might already exist, skip
        LogService().log('Failed creating $type collection: $e');
        LogService().log('Stack trace: $stackTrace');
      }
    }

    LogService().log('Default collections creation complete');
  }

  /// Show welcome dialog with generated callsign
  void _showWelcomeDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ValueListenableBuilder<int>(
        valueListenable: _profileService.profileNotifier,
        builder: (context, _, __) {
          final profile = _profileService.getProfile();

          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: Text(_i18n.t('welcome_to_geogram')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_i18n.t('welcome_message')),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.badge,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _i18n.t('your_callsign'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Text(
                              profile.callsign,
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _i18n.t('welcome_customize_hint'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await _profileService.regenerateActiveProfileIdentity();
                    // ValueListenableBuilder will auto-rebuild when profileNotifier changes
                  },
                  child: Text(_i18n.t('generate_new')),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  child: Text(_i18n.t('onboarding_continue')),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _onLanguageChanged() {
    setState(() {});
  }

  void _onProfileChanged() {
    setState(() {});
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
    final firstLaunchComplete = ConfigService().getNestedValue('firstLaunchComplete', false) as bool;
    if (!firstLaunchComplete) {
      return;
    }

    final latestRelease = updateService.getLatestRelease();
    if (latestRelease == null || !mounted) return;

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
              _i18n.t('update_available_version', params: [latestRelease.version]),
            ),
          ],
        ),
        leading: const Icon(Icons.system_update, color: Colors.blue),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
            },
            child: Text(_i18n.t('later')),
          ),
          FilledButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              // Navigate to Updates page and start download immediately
              setState(() {
                _selectedIndex = 3; // Settings tab
              });
              // After settings page loads, navigate to Updates with autoInstall
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const UpdatePage(autoInstall: true)),
                  );
                }
              });
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
      // Don't allow back gesture to exit app when on Collections (index 0)
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // Check if DevicesBrowserPage needs to handle back (viewing device details)
        if (_selectedIndex == 2 && DevicesBrowserPage.onBackPressed != null) {
          // Let DevicesBrowserPage handle it - it will clear the selected device
          final handled = DevicesBrowserPage.onBackPressed!();
          if (handled) {
            // Back was handled by DevicesBrowserPage, don't navigate away
            return;
          }
        }
        if (_selectedIndex != 0) {
          // Navigate back to Collections panel
          setState(() {
            _selectedIndex = 0;
          });
        }
        // If already on Collections, do nothing (stay there)
      },
      child: Scaffold(
        // Show AppBar only on Apps panel (index 0) for full-screen Map/Devices
        appBar: _selectedIndex == 0 ? AppBar(
          automaticallyImplyLeading: false,
          title: const ProfileSwitcher(),
          actions: [
            // Show station indicator if current profile is a station
            if (_profileService.getProfile().isRelay)
              IconButton(
                icon: const Icon(Icons.cell_tower),
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
            // Settings icon
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: _i18n.t('settings'),
              onPressed: () {
                setState(() {
                  _selectedIndex = 3; // Navigate to Settings
                });
              },
            ),
          ],
        ) : null,
      drawer: NavigationDrawer(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (int index) {
          setState(() {
            _selectedIndex = index;
          });
          Navigator.pop(context);
        },
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Text(
              _i18n.t('navigation'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          NavigationDrawerDestination(
            icon: const Icon(Icons.apps_outlined),
            selectedIcon: const Icon(Icons.apps),
            label: Text(_i18n.t('apps')),
          ),
          NavigationDrawerDestination(
            icon: const Icon(Icons.map_outlined),
            selectedIcon: const Icon(Icons.map),
            label: Text(_i18n.t('map')),
          ),
          NavigationDrawerDestination(
            icon: Badge(
              isLabelVisible: _unreadDmCount > 0,
              label: Text(_unreadDmCount > 99 ? '99+' : _unreadDmCount.toString()),
              child: const Icon(Icons.devices_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: _unreadDmCount > 0,
              label: Text(_unreadDmCount > 99 ? '99+' : _unreadDmCount.toString()),
              child: const Icon(Icons.devices),
            ),
            label: Text(_i18n.t('devices')),
          ),
          const Divider(),
          NavigationDrawerDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: Text(_i18n.t('settings')),
          ),
          NavigationDrawerDestination(
            icon: const Icon(Icons.article_outlined),
            selectedIcon: const Icon(Icons.article),
            label: Text(_i18n.t('log')),
          ),
        ],
      ),
      body: _pages[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex < 3 ? _selectedIndex : 0,
        onDestinationSelected: (int index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.apps_outlined),
            selectedIcon: const Icon(Icons.apps),
            label: _i18n.t('apps'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.map_outlined),
            selectedIcon: const Icon(Icons.map),
            label: _i18n.t('map'),
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _unreadDmCount > 0,
              label: Text(_unreadDmCount > 99 ? '99+' : _unreadDmCount.toString()),
              child: const Icon(Icons.devices_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: _unreadDmCount > 0,
              label: Text(_unreadDmCount > 99 ? '99+' : _unreadDmCount.toString()),
              child: const Icon(Icons.devices),
            ),
            label: _i18n.t('devices'),
          ),
        ],
      ),
      ),
    );
  }
}

// Collections Page
class CollectionsPage extends StatefulWidget {
  const CollectionsPage({super.key});

  @override
  State<CollectionsPage> createState() => _CollectionsPageState();
}

class _CollectionsPageState extends State<CollectionsPage> {
  final CollectionService _collectionService = CollectionService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final ChatNotificationService _chatNotificationService = ChatNotificationService();
  StreamSubscription<Map<String, int>>? _unreadSubscription;
  Map<String, int> _unreadCounts = {};

  List<Collection> _allCollections = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _i18n.languageNotifier.addListener(_onLanguageChanged);
    _profileService.activeProfileNotifier.addListener(_onProfileChanged);
    _collectionService.collectionsNotifier.addListener(_onCollectionsChanged);
    LogService().log('CollectionsPage: initState - setting up listeners');
    _loadCollections();
    _subscribeToUnreadCounts();
  }

  void _onProfileChanged() {
    // Profile changed, reload collections for the new profile
    LogService().log('Profile changed, reloading collections');
    _loadCollections();
  }

  void _onCollectionsChanged() {
    // Collections were created/updated/deleted, reload the list
    LogService().log('CollectionsPage: collectionsNotifier triggered, reloading');
    _loadCollections();
  }

  void _subscribeToUnreadCounts() {
    _unreadCounts = _chatNotificationService.unreadCounts;
    _unreadSubscription = _chatNotificationService.unreadCountsStream.listen((counts) {
      setState(() {
        _unreadCounts = counts;
      });
    });
  }

  void _onLanguageChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _i18n.languageNotifier.removeListener(_onLanguageChanged);
    _profileService.activeProfileNotifier.removeListener(_onProfileChanged);
    _collectionService.collectionsNotifier.removeListener(_onCollectionsChanged);
    _unreadSubscription?.cancel();
    super.dispose();
  }

  bool _isFixedCollectionType(Collection collection) {
    const fixedTypes = {
      'chat', 'forum', 'blog', 'events', 'news',
      'www', 'postcards', 'contacts', 'places', 'market', 'alerts', 'groups', 'station', 'backup'
    };
    return fixedTypes.contains(collection.type);
  }

  Future<void> _loadCollections() async {
    setState(() => _isLoading = true);

    try {
      // Use progressive loading for faster perceived performance
      final collections = <Collection>[];

      await for (final collection in _collectionService.loadCollectionsStream()) {
        collections.add(collection);

        // Update UI progressively every few collections for responsiveness
        if (collections.length <= 3 || collections.length % 5 == 0) {
          _updateCollectionsList(List.from(collections), isComplete: false);
        }
      }

      // Final update with all collections
      _updateCollectionsList(collections, isComplete: true);

      final types = collections.map((c) => c.type).toList();
      LogService().log('CollectionsPage: Loaded ${collections.length} collections: $types');
    } catch (e) {
      LogService().log('Error loading collections: $e');
      setState(() => _isLoading = false);
    }
  }

  void _updateCollectionsList(List<Collection> collections, {required bool isComplete}) {
    // Separate fixed and file collections
    final fixedCollections = collections.where(_isFixedCollectionType).toList();
    final fileCollections = collections.where((c) => !_isFixedCollectionType(c)).toList();

    // Sort each group: favorites first, then alphabetically
    void sortGroup(List<Collection> group) {
      group.sort((a, b) {
        if (a.isFavorite != b.isFavorite) {
          return a.isFavorite ? -1 : 1;
        }
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    }

    sortGroup(fixedCollections);
    sortGroup(fileCollections);

    // Combine: fixed first, then file collections
    final sortedCollections = [...fixedCollections, ...fileCollections];

    setState(() {
      _allCollections = sortedCollections;
      _isLoading = !isComplete;
    });
  }


  Future<void> _createNewCollection() async {
    final result = await Navigator.push<Collection>(
      context,
      MaterialPageRoute(
        builder: (context) => const CreateCollectionPage(),
      ),
    );

    if (result != null) {
      // Collection was created, reload the list
      _loadCollections();
    }
  }

  void _toggleFavorite(Collection collection) {
    _collectionService.toggleFavorite(collection);
    setState(() {});
    LogService().log('Toggled favorite for ${collection.title}');
  }

  Future<void> _deleteCollection(Collection collection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_collection')),
        content: Text(_i18n.t('delete_collection_confirm_msg', params: [collection.title])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await _collectionService.deleteCollection(collection);
        LogService().log('Deleted collection: ${collection.title}');
        _loadCollections();
      } catch (e) {
        LogService().log('Error deleting collection: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting collection: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Collections List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _allCollections.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.folder_special_outlined,
                              size: 64,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _allCollections.isEmpty
                                  ? _i18n.t('no_collections_yet')
                                  : _i18n.t('no_apps_found'),
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _allCollections.isEmpty
                                  ? _i18n.t('create_your_first_collection')
                                  : _i18n.t('try_a_different_search'),
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadCollections,
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

                            // Separate fixed and file collections from filtered list
                            final fixedCollections = _allCollections.where(_isFixedCollectionType).toList();
                            final fileCollections = _allCollections.where((c) => !_isFixedCollectionType(c)).toList();

                            return CustomScrollView(
                              slivers: [
                                // Fixed collections grid
                                if (fixedCollections.isNotEmpty)
                                  SliverPadding(
                                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                    sliver: SliverGrid(
                                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: crossAxisCount,
                                        crossAxisSpacing: 8,
                                        mainAxisSpacing: 8,
                                        childAspectRatio: 1.9,
                                      ),
                                      delegate: SliverChildBuilderDelegate(
                                        (context, index) {
                                          final collection = fixedCollections[index];
                                          return _CollectionGridCard(
                                  collection: collection,
                                  onTap: () {
                                    LogService().log('Opened collection: ${collection.title}');
                                    // Route to appropriate page based on collection type
                                    final Widget targetPage = collection.type == 'chat'
                                        ? ChatBrowserPage(collection: collection)
                                        : collection.type == 'forum'
                                            ? ForumBrowserPage(collection: collection)
                                            : collection.type == 'blog'
                                                ? BlogBrowserPage(
                                                    collectionPath: collection.storagePath ?? '',
                                                    collectionTitle: collection.title,
                                                  )
                                                : collection.type == 'news'
                                                    ? NewsBrowserPage(collection: collection)
                                                    : collection.type == 'events'
                                                        ? EventsBrowserPage(
                                                            collectionPath: collection.storagePath ?? '',
                                                            collectionTitle: collection.title,
                                                          )
                                                        : collection.type == 'postcards'
                                                            ? PostcardsBrowserPage(
                                                                collectionPath: collection.storagePath ?? '',
                                                                collectionTitle: collection.title,
                                                              )
                                                            : collection.type == 'contacts'
                                                                ? ContactsBrowserPage(
                                                                    collectionPath: collection.storagePath ?? '',
                                                                    collectionTitle: collection.title,
                                                                  )
                                                                : collection.type == 'places'
                                                                    ? PlacesBrowserPage(
                                                                        collectionPath: collection.storagePath ?? '',
                                                                        collectionTitle: collection.title,
                                                                      )
                                                                    : collection.type == 'market'
                                                                        ? MarketBrowserPage(
                                                                            collectionPath: collection.storagePath ?? '',
                                                                            collectionTitle: collection.title,
                                                                          )
                                                                        : collection.type == 'alerts'
                                                                            ? ReportBrowserPage(
                                                                                collectionPath: collection.storagePath ?? '',
                                                                                collectionTitle: collection.title,
                                                                              )
                                                                            : collection.type == 'groups'
                                                                                ? GroupsBrowserPage(
                                                                                    collectionPath: collection.storagePath ?? '',
                                                                                    collectionTitle: collection.title,
                                                                                  )
                                                                                : collection.type == 'backup'
                                                                                    ? const BackupBrowserPage()
                                                                                    : collection.type == 'station'
                                                                                        ? const StationDashboardPage()
                                                                                        : CollectionBrowserPage(collection: collection);

                                              LogService().log('Opening collection: ${collection.title} (type: ${collection.type}) -> ${targetPage.runtimeType}');
                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (context) => targetPage,
                                                ),
                                              ).then((_) => _loadCollections());
                                            },
                                            onFavoriteToggle: () => _toggleFavorite(collection),
                                            onDelete: () => _deleteCollection(collection),
                                            unreadCount: collection.type == 'chat' ? _chatNotificationService.totalUnreadCount : 0,
                                          );
                                        },
                                        childCount: fixedCollections.length,
                                      ),
                                    ),
                                  ),

                                // Separator between fixed and file collections
                                if (fixedCollections.isNotEmpty && fileCollections.isNotEmpty)
                                  SliverToBoxAdapter(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                      child: Divider(
                                        thickness: 1,
                                        color: Theme.of(context).colorScheme.outlineVariant,
                                      ),
                                    ),
                                  ),

                                // File collections grid
                                if (fileCollections.isNotEmpty)
                                  SliverPadding(
                                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                                    sliver: SliverGrid(
                                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: crossAxisCount,
                                        crossAxisSpacing: 8,
                                        mainAxisSpacing: 8,
                                        childAspectRatio: 1.9,
                                      ),
                                      delegate: SliverChildBuilderDelegate(
                                        (context, index) {
                                          final collection = fileCollections[index];
                                          return _CollectionGridCard(
                                            collection: collection,
                                            onTap: () {
                                              LogService().log('Opened collection: ${collection.title}');
                                              // Route to appropriate page based on collection type
                                              final Widget targetPage = collection.type == 'chat'
                                                  ? ChatBrowserPage(collection: collection)
                                                  : collection.type == 'forum'
                                                      ? ForumBrowserPage(collection: collection)
                                                      : collection.type == 'blog'
                                                          ? BlogBrowserPage(
                                                              collectionPath: collection.storagePath ?? '',
                                                              collectionTitle: collection.title,
                                                            )
                                                          : collection.type == 'news'
                                                              ? NewsBrowserPage(collection: collection)
                                                              : collection.type == 'events'
                                                                  ? EventsBrowserPage(
                                                                      collectionPath: collection.storagePath ?? '',
                                                                      collectionTitle: collection.title,
                                                                    )
                                                                  : collection.type == 'postcards'
                                                                      ? PostcardsBrowserPage(
                                                                          collectionPath: collection.storagePath ?? '',
                                                                          collectionTitle: collection.title,
                                                                        )
                                                                      : collection.type == 'contacts'
                                                                          ? ContactsBrowserPage(
                                                                              collectionPath: collection.storagePath ?? '',
                                                                              collectionTitle: collection.title,
                                                                            )
                                                                          : collection.type == 'places'
                                                                              ? PlacesBrowserPage(
                                                                                  collectionPath: collection.storagePath ?? '',
                                                                                  collectionTitle: collection.title,
                                                                                )
                                                                              : collection.type == 'market'
                                                                                  ? MarketBrowserPage(
                                                                                      collectionPath: collection.storagePath ?? '',
                                                                                      collectionTitle: collection.title,
                                                                                    )
                                                                                  : collection.type == 'alerts'
                                                                                      ? ReportBrowserPage(
                                                                                          collectionPath: collection.storagePath ?? '',
                                                                                          collectionTitle: collection.title,
                                                                                        )
                                                                                      : collection.type == 'groups'
                                                                                          ? GroupsBrowserPage(
                                                                                              collectionPath: collection.storagePath ?? '',
                                                                                              collectionTitle: collection.title,
                                                                                            )
                                                                                          : CollectionBrowserPage(collection: collection);

                                              LogService().log('Opening collection: ${collection.title} (type: ${collection.type}) -> ${targetPage.runtimeType}');
                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (context) => targetPage,
                                                ),
                                              ).then((_) => _loadCollections());
                                            },
                                            onFavoriteToggle: () => _toggleFavorite(collection),
                                            onDelete: () => _deleteCollection(collection),
                                            unreadCount: 0, // File collections don't track unread
                                          );
                                        },
                                        childCount: fileCollections.length,
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewCollection,
        icon: const Icon(Icons.add),
        label: Text(_i18n.t('add_new_collection')),
      ),
    );
  }
}

// Collection Grid Card Widget (compact design for grid layout)
class _CollectionGridCard extends StatelessWidget {
  final Collection collection;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onDelete;
  final int unreadCount;

  const _CollectionGridCard({
    required this.collection,
    required this.onTap,
    required this.onFavoriteToggle,
    required this.onDelete,
    this.unreadCount = 0,
  });

  /// Check if this is a fixed collection type
  bool _isFixedCollectionType() {
    const fixedTypes = {
      'chat', 'forum', 'blog', 'events', 'news',
      'www', 'postcards', 'contacts', 'places', 'market', 'groups', 'alerts', 'station'
    };
    return fixedTypes.contains(collection.type);
  }

  /// Get display title with proper capitalization and translation for fixed types
  String _getDisplayTitle() {
    final i18n = I18nService();
    if (_isFixedCollectionType() && collection.title.isNotEmpty) {
      // Try to get translated label for known collection types
      final key = 'collection_type_${collection.type}';
      final translated = i18n.t(key);
      if (translated != key) {
        return translated;
      }
      // Special case for www -> WWW
      if (collection.title.toLowerCase() == 'www') {
        return 'WWW';
      }
      return collection.title[0].toUpperCase() + collection.title.substring(1);
    }
    return collection.title;
  }

  /// Get appropriate icon based on collection type
  IconData _getCollectionIcon() {
    switch (collection.type) {
      case 'chat':
        return Icons.chat;
      case 'forum':
        return Icons.forum;
      case 'blog':
        return Icons.article;
      case 'events':
        return Icons.event;
      case 'news':
        return Icons.newspaper;
      case 'www':
        return Icons.language;
      case 'postcards':
        return Icons.credit_card;
      case 'contacts':
        return Icons.contacts;
      case 'places':
        return Icons.place;
      case 'market':
        return Icons.store;
      case 'groups':
        return Icons.groups;
      case 'alerts':
        return Icons.campaign;
      case 'backup':
        return Icons.backup;
      case 'station':
        return Icons.cell_tower;
      default:
        return Icons.folder_special;
    }
  }

  void _showContextMenu(BuildContext context, Offset position) {
    final i18n = I18nService();
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

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
                collection.isFavorite ? Icons.star : Icons.star_border,
                color: collection.isFavorite ? Colors.amber : null,
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

    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        onLongPress: isAndroid
            ? () {
                final RenderBox box = context.findRenderObject() as RenderBox;
                final Offset position = box.localToGlobal(Offset.zero);
                _showContextMenu(context, position);
              }
            : null,
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Badge(
                      isLabelVisible: unreadCount > 0,
                      label: Text('$unreadCount'),
                      child: Icon(
                        _getCollectionIcon(),
                        size: 32,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _getDisplayTitle(),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          height: 1.15,
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
            if (collection.isFavorite)
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.star,
                    size: 10,
                    color: Colors.white,
                  ),
                ),
              ),
            // Menu button (top-right corner, only on desktop)
            if (!isAndroid)
              Positioned(
                top: 2,
                right: 2,
                child: PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert,
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
                            collection.isFavorite ? Icons.star : Icons.star_border,
                            color: collection.isFavorite ? Colors.amber : null,
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
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// Collection Card Widget (original list design - kept for reference)
class _CollectionCard extends StatelessWidget {
  final Collection collection;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onDelete;
  final VoidCallback onOpenFolder;

  const _CollectionCard({
    required this.collection,
    required this.onTap,
    required this.onFavoriteToggle,
    required this.onDelete,
    required this.onOpenFolder,
  });

  /// Get appropriate icon based on collection type
  IconData _getCollectionIcon() {
    switch (collection.type) {
      case 'chat':
        return Icons.chat;
      case 'forum':
        return Icons.forum;
      case 'blog':
        return Icons.article;
      case 'events':
        return Icons.event;
      case 'www':
        return Icons.language;
      case 'postcards':
        return Icons.credit_card;
      case 'contacts':
        return Icons.contacts;
      case 'places':
        return Icons.place;
      case 'market':
        return Icons.store;
      default:
        return Icons.folder_special;
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = I18nService();
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
                  Icon(
                    _getCollectionIcon(),
                    color: Theme.of(context).colorScheme.primary,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                collection.title,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                collection.isFavorite
                                    ? Icons.star
                                    : Icons.star_border,
                                color: collection.isFavorite
                                    ? Colors.amber
                                    : null,
                              ),
                              onPressed: onFavoriteToggle,
                              tooltip: 'Toggle Favorite',
                            ),
                            IconButton(
                              icon: const Icon(Icons.folder_open),
                              onPressed: onOpenFolder,
                              tooltip: 'Open Folder',
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: onDelete,
                              tooltip: 'Delete',
                            ),
                          ],
                        ),
                        if (collection.description.isNotEmpty)
                          Text(
                            collection.description,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
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
                    label: collection.formattedDate,
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

  const _InfoChip({
    required this.icon,
    required this.label,
  });

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
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
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

// Log Page
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final LogService _logService = LogService();
  final I18nService _i18n = I18nService();
  final TextEditingController _filterController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isPaused = false;
  String _filterText = '';

  @override
  void initState() {
    super.initState();
    _i18n.languageNotifier.addListener(_onLanguageChanged);
    _logService.addListener(_onLogUpdate);

    // Add some initial logs for demonstration
    Future.delayed(Duration.zero, () {
      _logService.log('Geogram Desktop started');
      _logService.log('Log system initialized');
    });
  }

  void _onLanguageChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _i18n.languageNotifier.removeListener(_onLanguageChanged);
    _logService.removeListener(_onLogUpdate);
    _filterController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onLogUpdate(String message) {
    if (!_isPaused && mounted) {
      setState(() {});
      // Auto-scroll to bottom
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _togglePause() {
    setState(() {
      _isPaused = !_isPaused;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_isPaused ? _i18n.t('log_paused') : _i18n.t('log_resumed')),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _clearLog() {
    _logService.clear();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_i18n.t('log_cleared')),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _copyToClipboard() {
    final logText = _getFilteredLogs();
    if (logText.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: logText));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('log_copied_to_clipboard')),
          duration: const Duration(seconds: 1),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('log_is_empty')),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  String _getFilteredLogs() {
    final messages = _logService.messages;
    if (_filterText.isEmpty) {
      return messages.join('\n');
    }
    return messages
        .where((msg) => msg.toLowerCase().contains(_filterText.toLowerCase()))
        .join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDark ? Colors.black : Colors.grey[900],
      child: Column(
        children: [
          // Controls Bar
          Container(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                // Pause/Resume Button
                IconButton(
                  icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                  color: Colors.white,
                  tooltip: _isPaused ? _i18n.t('resume') : _i18n.t('pause'),
                  onPressed: _togglePause,
                ),
                const SizedBox(width: 8),
                // Filter Input
                Expanded(
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: TextField(
                      controller: _filterController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: _i18n.t('filter_logs'),
                        hintStyle: const TextStyle(color: Colors.grey),
                        prefixIcon: const Icon(Icons.search, color: Colors.white),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onChanged: (value) {
                        setState(() {
                          _filterText = value;
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Clear Button
                IconButton(
                  icon: const Icon(Icons.clear_all),
                  color: Colors.white,
                  tooltip: _i18n.t('clear_logs'),
                  onPressed: _clearLog,
                ),
                // Copy Button
                IconButton(
                  icon: const Icon(Icons.copy),
                  color: Colors.white,
                  tooltip: _i18n.t('copy_to_clipboard_button'),
                  onPressed: _copyToClipboard,
                ),
              ],
            ),
          ),
          // Log Display
          Expanded(
            child: Container(
              color: Colors.black,
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SelectableText(
                    _getFilteredLogs(),
                    textAlign: TextAlign.left,
                    style: const TextStyle(
                      fontFamily: 'Courier New',
                      fontSize: 13,
                      color: Colors.white,
                      height: 1.5,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Settings Page
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();

  @override
  void initState() {
    super.initState();
    // Listen to language changes to rebuild the UI
    _i18n.languageNotifier.addListener(_onLanguageChanged);
    _profileService.profileNotifier.addListener(_onProfileChanged);
  }

  @override
  void dispose() {
    _i18n.languageNotifier.removeListener(_onLanguageChanged);
    _profileService.profileNotifier.removeListener(_onProfileChanged);
    super.dispose();
  }

  void _onLanguageChanged() {
    setState(() {});
  }

  void _onProfileChanged() {
    setState(() {});
  }

  Future<void> _showLanguageDialog() async {
    final selectedLanguage = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(_i18n.t('select_language')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: _i18n.supportedLanguages.map((languageCode) {
              return RadioListTile<String>(
                title: Text(_i18n.getLanguageName(languageCode)),
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

    if (selectedLanguage != null && selectedLanguage != _i18n.currentLanguage) {
      await _i18n.setLanguage(selectedLanguage);
    }
  }

  Future<void> _showWebThemeDialog() async {
    final themeService = WebThemeService();
    final themes = await themeService.getAvailableThemes();
    final currentTheme = themeService.getCurrentTheme();

    if (!mounted) return;

    final selectedTheme = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(_i18n.t('select_web_theme')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: themes.map((themeName) {
                return RadioListTile<String>(
                  title: Text(themeName[0].toUpperCase() + themeName.substring(1)),
                  subtitle: Text(themeName == 'default'
                    ? _i18n.t('web_theme_default_desc')
                    : _i18n.t('web_theme_custom_desc')),
                  value: themeName,
                  groupValue: currentTheme,
                  onChanged: (String? value) {
                    Navigator.pop(context, value);
                  },
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                // Open themes folder
                if (!kIsWeb) {
                  final themesPath = themeService.themesDir;
                  final uri = Uri.directory(themesPath);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri);
                  }
                }
              },
              child: Text(_i18n.t('open_themes_folder')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_i18n.t('cancel')),
            ),
          ],
        );
      },
    );

    if (selectedTheme != null && selectedTheme != currentTheme) {
      themeService.setCurrentTheme(selectedTheme);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _i18n.t('settings'),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: Text(_i18n.t('profile')),
          subtitle: Text(_i18n.t('manage_your_profile')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const ProfilePage()),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.location_on_outlined),
          title: Text(_i18n.t('location')),
          subtitle: Text(_i18n.t('set_location_on_map')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const LocationPage()),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.security_outlined),
          title: Text(_i18n.t('security')),
          subtitle: Text(_i18n.t('security_and_privacy')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SecuritySettingsPage()),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.settings_input_antenna),
          title: Text(_i18n.t('connections')),
          subtitle: Text(_i18n.t('manage_stations_and_network')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const StationsPage()),
            );
          },
        ),
        // Show station settings only for station profiles
        if (_profileService.getProfile().isRelay)
          ListTile(
            leading: const Icon(Icons.cell_tower, color: Colors.orange),
            title: Text(_i18n.t('station_settings')),
            subtitle: Text(_i18n.t('configure_station_server')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const StationDashboardPage()),
              );
            },
          ),
        // TODO: Notifications settings - not yet implemented
        // ListTile(
        //   leading: const Icon(Icons.notifications_outlined),
        //   title: Text(_i18n.t('notifications')),
        //   subtitle: Text(_i18n.t('configure_notifications')),
        //   trailing: const Icon(Icons.chevron_right),
        //   onTap: () {
        //     Navigator.push(
        //       context,
        //       MaterialPageRoute(builder: (context) => const NotificationsPage()),
        //     );
        //   },
        // ),
        // const Divider(),
        ListTile(
          leading: const Icon(Icons.language),
          title: Text(_i18n.t('language')),
          subtitle: Text(_i18n.getLanguageName(_i18n.currentLanguage)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _showLanguageDialog,
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: Text(_i18n.t('web_theme')),
          subtitle: Text(WebThemeService().getCurrentTheme()[0].toUpperCase() +
            WebThemeService().getCurrentTheme().substring(1)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _showWebThemeDialog,
        ),
        ListTile(
          leading: const Icon(Icons.system_update),
          title: Text(_i18n.t('software_updates')),
          subtitle: Text(_i18n.t('software_updates_subtitle')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const UpdatePage()),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.info_outlined),
          title: Text(_i18n.t('about')),
          subtitle: Text(_i18n.t('app_version_and_info')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => AboutPage()),
            );
          },
        ),
      ],
    );
  }
}

// ============================================================================
// COLLECTION BROWSER PAGE
// ============================================================================

class CollectionBrowserPage extends StatefulWidget {
  final Collection collection;

  const CollectionBrowserPage({super.key, required this.collection});

  @override
  State<CollectionBrowserPage> createState() => _CollectionBrowserPageState();
}

class _CollectionBrowserPageState extends State<CollectionBrowserPage> {
  final CollectionService _collectionService = CollectionService();
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
      final files = await _collectionService.loadFileTree(widget.collection);
      setState(() {
        _allFiles = files;
        _filteredFiles = files;
        _isLoading = false;
      });
      LogService().log('Loaded ${files.length} items in collection');
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
          results.add(FileNode(
            path: node.path,
            name: node.name,
            size: node.size,
            isDirectory: true,
            children: matchingChildren.isEmpty ? node.children : matchingChildren,
            fileCount: node.fileCount,
          ));
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
        LogService().log('Adding ${paths.length} files to collection');

        await _collectionService.addFiles(widget.collection, paths);
        LogService().log('Files added successfully');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('added_files', params: [paths.length.toString()]))),
          );
        }

        _loadFiles();
      }
    } catch (e) {
      LogService().log('Error adding files: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('error_adding_files', params: [e.toString()]))),
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
        LogService().log('Adding folder to collection: $result');

        await _collectionService.addFolder(widget.collection, result);
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
          SnackBar(content: Text(_i18n.t('error_adding_folder', params: [e.toString()]))),
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

        await _collectionService.createFolder(widget.collection, folderName);
        LogService().log('Folder created successfully');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('folder_created'))),
          );
        }

        _loadFiles();
      } catch (e) {
        LogService().log('Error creating folder: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('error_creating_folder', params: [e.toString()]))),
          );
        }
      }
    }
  }

  Future<void> _editSettings() async {
    final updated = await showDialog<bool>(
      context: context,
      builder: (context) => EditCollectionDialog(
        collection: widget.collection,
      ),
    );

    if (updated == true) {
      setState(() {});
    }
  }

  Future<void> _refreshCollectionFiles() async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('regenerating_collection_files'))),
      );

      // Force regeneration of all collection files
      await _collectionService.ensureCollectionFilesUpdated(widget.collection, force: true);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('collection_files_regenerated'))),
        );
      }
    } catch (e) {
      LogService().log('Error refreshing collection files: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('error_regenerating_files', params: [e.toString()]))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.collection.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshCollectionFiles,
            tooltip: _i18n.t('refresh_collection_files'),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _editSettings,
            tooltip: _i18n.t('collection_settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Collection Info
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.collection.description.isNotEmpty)
                  Text(
                    widget.collection.description,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.folder_outlined, size: 16, color: Theme.of(context).colorScheme.secondary),
                    const SizedBox(width: 4),
                    Text(
                      '${widget.collection.filesCount} ${widget.collection.filesCount == 1 ? _i18n.t('file') : _i18n.t('files')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(width: 16),
                    Icon(Icons.storage_outlined, size: 16, color: Theme.of(context).colorScheme.secondary),
                    const SizedBox(width: 4),
                    Text(
                      widget.collection.formattedSize,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(width: 16),
                    Icon(Icons.lock_outline, size: 16, color: Theme.of(context).colorScheme.secondary),
                    const SizedBox(width: 4),
                    Text(
                      _i18n.t(widget.collection.visibility),
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
                              _searchController.text.isEmpty ? _i18n.t('no_files_yet') : _i18n.t('no_matching_files'),
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _searchController.text.isEmpty
                                  ? _i18n.t('add_files_to_get_started')
                                  : _i18n.t('try_a_different_search'),
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                              collectionPath: widget.collection.storagePath ?? '',
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
  final String collectionPath;

  const _FileNodeTile({
    required this.fileNode,
    required this.expandedFolders,
    required this.onToggleExpand,
    required this.collectionPath,
    this.indentLevel = 0,
  });

  @override
  State<_FileNodeTile> createState() => _FileNodeTileState();
}

class _FileNodeTileState extends State<_FileNodeTile> {
  dynamic _thumbnailFile;  // File on native, null on web

  @override
  void initState() {
    super.initState();
    // Only load thumbnails on native platforms (not web)
    if (!kIsWeb && !widget.fileNode.isDirectory && FileIconHelper.isImage(widget.fileNode.name)) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    if (kIsWeb) return;  // No local file access on web

    try {
      final filePath = '${widget.collectionPath}/${widget.fileNode.path}';
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
      final filePath = '${widget.collectionPath}/${widget.fileNode.path}';
      final file = File(filePath);

      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(i18n.t('file_not_found'))),
          );
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
          SnackBar(content: Text(i18n.t('error_opening_file', params: [e.toString()]))),
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
              color: FileIconHelper.getColorForFile(widget.fileNode.name, context),
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
    final hasChildren = widget.fileNode.isDirectory && widget.fileNode.children != null && widget.fileNode.children!.isNotEmpty;

    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.only(left: 16.0 + (widget.indentLevel * 24.0)),
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
          ...widget.fileNode.children!.map((child) => _FileNodeTile(
                fileNode: child,
                expandedFolders: widget.expandedFolders,
                onToggleExpand: widget.onToggleExpand,
                collectionPath: widget.collectionPath,
                indentLevel: widget.indentLevel + 1,
              )),
      ],
    );
  }
}

// ============================================================================
// EDIT COLLECTION DIALOG
// ============================================================================

class EditCollectionDialog extends StatefulWidget {
  final Collection collection;

  const EditCollectionDialog({super.key, required this.collection});

  @override
  State<EditCollectionDialog> createState() => _EditCollectionDialogState();
}

class _EditCollectionDialogState extends State<EditCollectionDialog> {
  final CollectionService _collectionService = CollectionService();
  final I18nService _i18n = I18nService();
  late TextEditingController _titleController;
  late TextEditingController _descriptionController;
  late String _visibility;
  late String _encryption;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.collection.title);
    _descriptionController = TextEditingController(text: widget.collection.description);
    _visibility = widget.collection.visibility;
    _encryption = widget.collection.encryption;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('please_enter_a_title'))),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      // Capture old title before updating
      final oldTitle = widget.collection.title;

      // Update collection properties
      widget.collection.title = title;
      widget.collection.description = _descriptionController.text.trim();
      widget.collection.visibility = _visibility;
      widget.collection.encryption = _encryption;

      // Save to disk (will rename folder if title changed)
      await _collectionService.updateCollection(
        widget.collection,
        oldTitle: oldTitle,
      );

      LogService().log('Updated collection settings: ${widget.collection.title}');

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e, stackTrace) {
      LogService().log('ERROR updating collection: $e');
      LogService().log('Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('error_updating_collection', params: [e.toString()]))),
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
      title: Text(_i18n.t('collection_settings')),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Collection ID (read-only)
              Text(
                _i18n.t('collection_id'),
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
                  widget.collection.id,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'Courier New',
                      ),
                ),
              ),
              const SizedBox(height: 16),

              // Title
              TextField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: _i18n.t('collection_title'),
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
                  DropdownMenuItem(value: 'public', child: Text(_i18n.t('public'))),
                  DropdownMenuItem(value: 'private', child: Text(_i18n.t('private'))),
                  DropdownMenuItem(value: 'restricted', child: Text(_i18n.t('restricted'))),
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
                  DropdownMenuItem(value: 'none', child: Text(_i18n.t('encryption_none'))),
                  DropdownMenuItem(value: 'aes256', child: Text(_i18n.t('encryption_aes256'))),
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
