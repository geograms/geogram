/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Minimal web entry point — only Chat + Log apps.
 * Does NOT import native-only packages (media_kit, BLE, USB, tray, etc.).
 */

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'services/crash_service.dart';
import 'services/log_service.dart';
import 'version.dart';
import 'services/config_service.dart';
import 'services/app_service.dart';
import 'services/profile_service.dart';
import 'services/i18n_service.dart';
import 'services/storage_config.dart';
import 'services/web_theme_service.dart';
import 'services/app_theme_service.dart';
import 'services/chat_notification_service.dart';
import 'platform/file_system_service.dart';
import 'models/app.dart';
import 'util/app_constants.dart';
import 'util/app_type_theme.dart';
import 'util/nostr_key_generator.dart';
import 'pages/chat_browser_page.dart';
import 'pages/log_browser_page.dart';
import 'pages/profile_page.dart';

void main() async {
  print('MAIN_WEB: Starting Geogram Web (kIsWeb: $kIsWeb)');

  WidgetsFlutterBinding.ensureInitialized();

  await CrashService().initialize();
  await LogService().init();
  LogService().log('Geogram Web starting...');

  try {
    // Initialize FileSystemService (IndexedDB on web)
    await FileSystemService.instance.init();
    LogService().log('FileSystemService initialized');

    await StorageConfig().init();
    LogService().log('StorageConfig initialized: ${StorageConfig().baseDir}');

    await Future.wait([
      ConfigService().init().then(
        (_) => LogService().log('ConfigService initialized'),
      ),
      I18nService().init().then(
        (_) => LogService().log('I18nService initialized'),
      ),
    ]);

    await WebThemeService().init();
    LogService().log('WebThemeService initialized');

    await AppThemeService().initialize();
    LogService().log('AppThemeService initialized');

    await AppService().init();
    LogService().log('AppService initialized');

    await ProfileService().initialize();
    LogService().log('ProfileService initialized');

    final profile = ProfileService().getProfile();
    await AppService().setActiveCallsign(profile.callsign);
    await LogService().switchToProfile(profile.callsign);
    LogService().log('AppService callsign set: ${profile.callsign}');

    AppService().ensureDefaultApps();

    ChatNotificationService().initialize();
    LogService().log('ChatNotificationService initialized');
  } catch (e, stackTrace) {
    LogService().log('ERROR during initialization: $e');
    LogService().log('Stack trace: $stackTrace');
    print('MAIN_WEB ERROR: $e');
  }

  runApp(const GeogramWebApp());
}

class GeogramWebApp extends StatefulWidget {
  const GeogramWebApp({super.key});

  @override
  State<GeogramWebApp> createState() => _GeogramWebAppState();
}

class _GeogramWebAppState extends State<GeogramWebApp> {
  final AppThemeService _themeService = AppThemeService();

  @override
  void initState() {
    super.initState();
    _themeService.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    _themeService.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Geogram',
      debugShowCheckedModeBanner: false,
      theme: _themeService.getLightTheme(),
      darkTheme: _themeService.getDarkTheme(),
      themeMode: ThemeMode.system,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('pt'), Locale('de')],
      home: const WebHomePage(),
    );
  }
}

class WebHomePage extends StatefulWidget {
  const WebHomePage({super.key});

  @override
  State<WebHomePage> createState() => _WebHomePageState();
}

class _WebHomePageState extends State<WebHomePage> {
  final AppService _appService = AppService();
  final I18nService _i18n = I18nService();
  final ChatNotificationService _chatNotificationService =
      ChatNotificationService();
  StreamSubscription<Map<String, int>>? _unreadSubscription;
  List<App> _apps = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _i18n.languageNotifier.addListener(_rebuild);
    _appService.appsNotifier.addListener(_loadApps);
    _loadApps();
    _subscribeToUnreadCounts();
    _checkFirstLaunch();
  }

  @override
  void dispose() {
    _i18n.languageNotifier.removeListener(_rebuild);
    _appService.appsNotifier.removeListener(_loadApps);
    _unreadSubscription?.cancel();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _subscribeToUnreadCounts() {
    _unreadSubscription = _chatNotificationService.unreadCountsStream.listen((
      _,
    ) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadApps() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final allApps = await _appService.loadAppsFast();
      if (!mounted) return;
      // Filter to web-enabled app types only
      final webApps = allApps
          .where((app) => webEnabledAppTypesConst.contains(app.type))
          .toList();
      setState(() {
        _apps = webApps;
        _isLoading = false;
      });
    } catch (e) {
      LogService().log('Error loading apps: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _checkFirstLaunch() {
    final config = ConfigService().getAll();
    final firstLaunchComplete = config['firstLaunchComplete'] as bool? ?? false;

    if (!firstLaunchComplete) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showWebWelcome();
      });
    }
  }

  void _showWebWelcome() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _WebWelcomePage(
          onComplete: () {
            Navigator.of(context).pop();
            _loadApps();
          },
        ),
      ),
    );
  }

  void _openApp(App app) {
    final Widget targetPage;
    if (app.type == 'chat') {
      targetPage = ChatBrowserPage(app: app);
    } else if (app.type == 'log') {
      targetPage = const LogBrowserPage();
    } else {
      return;
    }

    LogService().log('Opening app: ${app.title} (type: ${app.type})');
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => targetPage),
    ).then((_) => _loadApps());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = ProfileService().getProfile();

    return Scaffold(
      appBar: AppBar(
        title: Text(profile.callsign.isNotEmpty
            ? profile.callsign
            : 'Geogram'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: _i18n.t('profile'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ProfilePage()),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _apps.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.web, size: 64, color: theme.colorScheme.secondary),
                  const SizedBox(height: 16),
                  Text(
                    'Geogram Web',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Chat and Log available',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final crossAxisCount = constraints.maxWidth < 600 ? 2 : 4;
                  return GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 1.9,
                    ),
                    itemCount: _apps.length,
                    itemBuilder: (context, index) {
                      final app = _apps[index];
                      final isDark = theme.brightness == Brightness.dark;
                      final gradient = getAppTypeGradient(app.type, isDark);
                      final icon = getAppTypeIcon(app.type);
                      final unread = app.type == 'chat'
                          ? _chatNotificationService.totalUnreadCount
                          : 0;

                      // Translated title
                      final titleKey = 'app_type_${app.type}';
                      final title = _i18n.t(titleKey);
                      final displayTitle =
                          title != titleKey ? title : app.title;

                      return Card(
                        elevation: 0,
                        color: theme.colorScheme.surfaceContainerLow,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: InkWell(
                          onTap: () => _openApp(app),
                          borderRadius: BorderRadius.circular(14),
                          child: Stack(
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        gradient: gradient,
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      child: Icon(
                                        icon,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        displayTitle,
                                        style: theme.textTheme.titleSmall,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (unread > 0)
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.error,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      unread > 99 ? '99+' : '$unread',
                                      style: TextStyle(
                                        color: theme.colorScheme.onError,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
    );
  }
}

/// Simplified web welcome page (no dart:isolate, no vanity generation)
class _WebWelcomePage extends StatefulWidget {
  final VoidCallback onComplete;

  const _WebWelcomePage({required this.onComplete});

  @override
  State<_WebWelcomePage> createState() => _WebWelcomePageState();
}

class _WebWelcomePageState extends State<_WebWelcomePage> {
  final I18nService _i18n = I18nService();
  late NostrKeys _keys;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _keys = NostrKeyGenerator.generateKeyPair();
  }

  void _regenerate() {
    setState(() {
      _keys = NostrKeyGenerator.generateKeyPair();
    });
  }

  Future<void> _confirm() async {
    setState(() => _saving = true);

    try {
      // Build profile from generated keys and finalize
      final profile = ProfileService().getProfile().copyWith(
        callsign: _keys.callsign,
        npub: _keys.npub,
        nsec: _keys.nsec,
      );
      await ProfileService().finalizeProfileIdentity(profile);
      ConfigService().set('firstLaunchComplete', true);

      // Recreate apps under new callsign
      await AppService().setActiveCallsign(_keys.callsign);
      await AppService().ensureDefaultApps();

      LogService().log('Web welcome: Profile finalized as ${_keys.callsign}');
      widget.onComplete();
    } catch (e) {
      LogService().log('Web welcome: Error finalizing profile: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.radio,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  'Welcome to Geogram',
                  style: theme.textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _i18n.t('your_callsign_is'),
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _keys.callsign,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: _saving ? null : _regenerate,
                  icon: const Icon(Icons.refresh),
                  label: Text(_i18n.t('generate_new')),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saving ? null : _confirm,
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_i18n.t('confirm')),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'v$appVersion',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
