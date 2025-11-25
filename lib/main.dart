import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' if (dart.library.html) 'platform/io_stub.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart' if (dart.library.html) 'platform/window_manager_stub.dart';
import 'services/log_service.dart';
import 'services/log_api_service.dart';
import 'services/config_service.dart';
import 'services/collection_service.dart';
import 'services/profile_service.dart';
import 'services/relay_service.dart';
import 'services/relay_discovery_service.dart';
import 'services/notification_service.dart';
import 'services/i18n_service.dart';
import 'models/collection.dart';
import 'util/file_icon_helper.dart';
import 'pages/profile_page.dart';
import 'pages/about_page.dart';
import 'pages/relays_page.dart';
import 'pages/location_page.dart';
import 'pages/notifications_page.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  try {
    // Initialize services
    await ConfigService().init();
    LogService().log('ConfigService initialized');

    // Initialize i18n service (internationalization)
    await I18nService().init();
    LogService().log('I18nService initialized');

    await CollectionService().init();
    LogService().log('CollectionService initialized');

    await ProfileService().initialize();
    LogService().log('ProfileService initialized');

    await RelayService().initialize();
    LogService().log('RelayService initialized');

    await NotificationService().initialize();
    LogService().log('NotificationService initialized');

    // Start relay auto-discovery
    RelayDiscoveryService().start();
    LogService().log('RelayDiscoveryService started');

    // Start log API service
    await LogApiService().start();
    LogService().log('LogApiService started on port 45678');
  } catch (e, stackTrace) {
    LogService().log('ERROR during initialization: $e');
    LogService().log('Stack trace: $stackTrace');
  }

  runApp(const GeogramApp());
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
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();

  static const List<Widget> _pages = [
    CollectionsPage(),
    GeoChatPage(),
    DevicesPage(),
    SettingsPage(),
    LogPage(),
  ];

  /// Get title text from profile or default app name
  String _getTitleText() {
    final profile = _profileService.getProfile();
    if (profile.callsign.isNotEmpty) {
      if (profile.nickname.isNotEmpty) {
        return '${profile.callsign} - ${profile.nickname}';
      }
      return profile.callsign;
    }
    return _i18n.t('app_name');
  }

  @override
  void initState() {
    super.initState();
    // Listen to language changes to rebuild the UI
    _i18n.languageNotifier.addListener(_onLanguageChanged);
    // Listen to profile changes to update title
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.folder_special),
            const SizedBox(width: 8),
            Text(_getTitleText()),
          ],
        ),
      ),
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
            icon: const Icon(Icons.folder_special_outlined),
            selectedIcon: const Icon(Icons.folder_special),
            label: Text(_i18n.t('collections')),
          ),
          NavigationDrawerDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: Text(_i18n.t('geochat')),
          ),
          NavigationDrawerDestination(
            icon: const Icon(Icons.devices_outlined),
            selectedIcon: const Icon(Icons.devices),
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
        selectedIndex: _selectedIndex < 4 ? _selectedIndex : 0,
        onDestinationSelected: (int index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.folder_special_outlined),
            selectedIcon: const Icon(Icons.folder_special),
            label: _i18n.t('collections'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: _i18n.t('geochat'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.devices_outlined),
            selectedIcon: const Icon(Icons.devices),
            label: _i18n.t('devices'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: _i18n.t('settings'),
          ),
        ],
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
  final I18nService _i18n = I18nService();
  final TextEditingController _searchController = TextEditingController();

  List<Collection> _allCollections = [];
  List<Collection> _filteredCollections = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _i18n.languageNotifier.addListener(_onLanguageChanged);
    LogService().log('Collections page opened');
    _loadCollections();
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

  bool _isFixedCollectionType(Collection collection) {
    const fixedTypes = {
      'chat', 'forum', 'blog', 'events', 'news',
      'www', 'postcards', 'contacts', 'places', 'market', 'report'
    };
    return fixedTypes.contains(collection.type);
  }

  Future<void> _loadCollections() async {
    setState(() => _isLoading = true);

    try {
      final collections = await _collectionService.loadCollections();

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
        _filteredCollections = sortedCollections;
        _isLoading = false;
      });

      LogService().log('Loaded ${collections.length} collections (${fixedCollections.length} fixed, ${fileCollections.length} file)');
    } catch (e) {
      LogService().log('Error loading collections: $e');
      setState(() => _isLoading = false);
    }
  }

  void _filterCollections(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredCollections = _allCollections;
      } else {
        _filteredCollections = _allCollections.where((collection) {
          return collection.title.toLowerCase().contains(query.toLowerCase()) ||
                 collection.description.toLowerCase().contains(query.toLowerCase());
        }).toList();
      }
    });
  }

  Future<void> _createNewCollection() async {
    await showDialog(
      context: context,
      builder: (context) => _CreateCollectionDialog(
        onCreated: () {
          _loadCollections();
        },
      ),
    );
  }

  Future<void> _toggleFavorite(Collection collection) async {
    await _collectionService.toggleFavorite(collection);
    setState(() {});
    LogService().log('Toggled favorite for ${collection.title}');
  }

  Future<void> _openFolder(Collection collection) async {
    if (collection.storagePath == null) {
      LogService().log('Collection has no storage path');
      return;
    }

    try {
      final uri = Uri.file(collection.storagePath!);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        LogService().log('Opened folder: ${collection.storagePath}');
      } else {
        LogService().log('Cannot open folder: ${collection.storagePath}');
      }
    } catch (e) {
      LogService().log('Error opening folder: $e');
    }
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
          // Search Bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: _i18n.t('search'),
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
              ),
              onChanged: _filterCollections,
            ),
          ),

          // Collections List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredCollections.isEmpty
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
                                  : _i18n.t('no_collections_found'),
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
                            final fixedCollections = _filteredCollections.where(_isFixedCollectionType).toList();
                            final fileCollections = _filteredCollections.where((c) => !_isFixedCollectionType(c)).toList();

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
                                                                        : collection.type == 'report'
                                                                            ? ReportBrowserPage(
                                                                                collectionPath: collection.storagePath ?? '',
                                                                                collectionTitle: collection.title,
                                                                              )
                                                                            : CollectionBrowserPage(collection: collection);

                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (context) => targetPage,
                                                ),
                                              ).then((_) => _loadCollections());
                                            },
                                            onFavoriteToggle: () => _toggleFavorite(collection),
                                            onDelete: () => _deleteCollection(collection),
                                            onOpenFolder: () => _openFolder(collection),
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
                                                                                  : collection.type == 'report'
                                                                                      ? ReportBrowserPage(
                                                                                          collectionPath: collection.storagePath ?? '',
                                                                                          collectionTitle: collection.title,
                                                                                        )
                                                                                      : CollectionBrowserPage(collection: collection);

                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (context) => targetPage,
                                                ),
                                              ).then((_) => _loadCollections());
                                            },
                                            onFavoriteToggle: () => _toggleFavorite(collection),
                                            onDelete: () => _deleteCollection(collection),
                                            onOpenFolder: () => _openFolder(collection),
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
        label: Text(_i18n.t('create_new_collection')),
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
  final VoidCallback onOpenFolder;

  const _CollectionGridCard({
    required this.collection,
    required this.onTap,
    required this.onFavoriteToggle,
    required this.onDelete,
    required this.onOpenFolder,
  });

  /// Check if this is a fixed collection type
  bool _isFixedCollectionType() {
    const fixedTypes = {
      'chat', 'forum', 'blog', 'events', 'news',
      'www', 'postcards', 'contacts', 'places', 'market'
    };
    return fixedTypes.contains(collection.type);
  }

  /// Get display title with proper capitalization for fixed types
  String _getDisplayTitle() {
    if (_isFixedCollectionType() && collection.title.isNotEmpty) {
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
      default:
        return Icons.folder_special;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();

    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Main content: Icon, title, and stats
                  Expanded(
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Icon(
                            _getCollectionIcon(),
                            size: 26,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _getDisplayTitle(),
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                    height: 1.15,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${collection.filesCount} files • ${collection.formattedSize}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontSize: 12,
                                    height: 1.15,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Bottom: Action buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: Icon(
                          collection.isFavorite ? Icons.star : Icons.star_border,
                          size: 13,
                        ),
                        onPressed: onFavoriteToggle,
                        tooltip: i18n.t('favorite'),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 20,
                          minHeight: 20,
                        ),
                        color: collection.isFavorite ? Colors.amber : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.folder_open, size: 13),
                        onPressed: onOpenFolder,
                        tooltip: i18n.t('open_folder'),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 20,
                          minHeight: 20,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 13),
                        onPressed: onDelete,
                        tooltip: i18n.t('delete'),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 20,
                          minHeight: 20,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Favorite badge overlay
            if (collection.isFavorite)
              Positioned(
                top: 4,
                right: 4,
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
                    icon: Icons.insert_drive_file_outlined,
                    label: '${collection.filesCount} ${collection.filesCount == 1 ? i18n.t('file') : i18n.t('files')}',
                  ),
                  const SizedBox(width: 8),
                  _InfoChip(
                    icon: Icons.storage_outlined,
                    label: collection.formattedSize,
                  ),
                  const SizedBox(width: 8),
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

// Create Collection Dialog
class _CreateCollectionDialog extends StatefulWidget {
  final VoidCallback onCreated;

  const _CreateCollectionDialog({required this.onCreated});

  @override
  State<_CreateCollectionDialog> createState() => _CreateCollectionDialogState();
}

class _CreateCollectionDialogState extends State<_CreateCollectionDialog> {
  final I18nService _i18n = I18nService();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  bool _isCreating = false;
  bool _useAutoFolder = true;
  String? _selectedFolderPath;
  String _collectionType = 'files';
  Set<String> _existingTypes = {};

  @override
  void initState() {
    super.initState();
    _checkExistingTypes();
  }

  Future<void> _checkExistingTypes() async {
    try {
      // Quick check for existing collection types by scanning folder names only
      // This avoids expensive loadCollections() call which validates all collections
      final collectionsService = CollectionService();
      final collectionsDir = Directory('${collectionsService.getDefaultCollectionsPath()}');

      if (await collectionsDir.exists()) {
        final folders = await collectionsDir.list().toList();
        final existingFolderNames = folders
            .where((e) => e is Directory)
            .map((e) => e.path.split('/').last)
            .toSet();

        // Known fixed collection types (non-files types use type name as folder name)
        final fixedTypes = {
          'forum', 'chat', 'blog', 'events', 'news', 'www',
          'postcards', 'contacts', 'places', 'market', 'report'
        };

        setState(() {
          _existingTypes = fixedTypes.intersection(existingFolderNames);
        });
      }
    } catch (e) {
      LogService().log('Error checking existing types: $e');
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select root folder for collection',
      );

      if (result != null) {
        setState(() {
          _selectedFolderPath = result;
        });
        LogService().log('Selected folder: $result');
      }
    } catch (e) {
      LogService().log('Error picking folder: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error selecting folder: $e')),
        );
      }
    }
  }

  Future<void> _create() async {
    final title = _titleController.text.trim();

    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('title_required'))),
      );
      return;
    }

    // For non-files types, validate
    if (_collectionType != 'files') {
      if (_existingTypes.contains(_collectionType)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('A ${_collectionType} collection already exists')),
        );
        return;
      }
    } else {
      // Only validate folder selection for files type
      if (!_useAutoFolder && _selectedFolderPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select a root folder')),
        );
        return;
      }
    }

    setState(() => _isCreating = true);

    try {
      LogService().log('Creating collection with title: $title');

      final collection = await CollectionService().createCollection(
        title: title,
        description: _descriptionController.text.trim(),
        type: _collectionType,
        customRootPath: _collectionType == 'files'
            ? (_useAutoFolder ? null : _selectedFolderPath)
            : null,
      );

      LogService().log('Created collection: ${collection.title}');

      if (mounted) {
        Navigator.pop(context);
        widget.onCreated();
      }
    } catch (e, stackTrace) {
      LogService().log('ERROR creating collection: $e');
      LogService().log('Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating collection: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCreating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_i18n.t('create_collection_title')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Type dropdown (moved to first position)
            DropdownButtonFormField<String>(
              value: _collectionType,
              decoration: InputDecoration(
                labelText: _i18n.t('type'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: 'files',
                  child: Text(_i18n.t('collection_type_files')),
                ),
                DropdownMenuItem(
                  value: 'forum',
                  enabled: !_existingTypes.contains('forum'),
                  child: Text(
                    '${_i18n.t('collection_type_forum')}${_existingTypes.contains('forum') ? ' ${_i18n.t('already_exists')}' : ''}',
                    style: _existingTypes.contains('forum')
                        ? TextStyle(color: Colors.grey)
                        : null,
                  ),
                ),
                DropdownMenuItem(
                  value: 'chat',
                  enabled: !_existingTypes.contains('chat'),
                  child: Text(
                    '${_i18n.t('collection_type_chat')}${_existingTypes.contains('chat') ? ' ${_i18n.t('already_exists')}' : ''}',
                    style: _existingTypes.contains('chat')
                        ? TextStyle(color: Colors.grey)
                        : null,
                  ),
                ),
                DropdownMenuItem(
                  value: 'blog',
                  enabled: !_existingTypes.contains('blog'),
                  child: Text(
                    '${_i18n.t('collection_type_blog')}${_existingTypes.contains('blog') ? ' ${_i18n.t('already_exists')}' : ''}',
                    style: _existingTypes.contains('blog')
                        ? TextStyle(color: Colors.grey)
                        : null,
                  ),
                ),
                DropdownMenuItem(
                  value: 'events',
                  enabled: !_existingTypes.contains('events'),
                  child: Text(
                    '${_i18n.t('collection_type_events')}${_existingTypes.contains('events') ? ' ${_i18n.t('already_exists')}' : ''}',
                    style: _existingTypes.contains('events')
                        ? TextStyle(color: Colors.grey)
                        : null,
                  ),
                ),
                DropdownMenuItem(
                  value: 'news',
                  enabled: !_existingTypes.contains('news'),
                  child: Text(
                    '${_i18n.t('collection_type_news')}${_existingTypes.contains('news') ? ' ${_i18n.t('already_exists')}' : ''}',
                    style: _existingTypes.contains('news')
                        ? TextStyle(color: Colors.grey)
                        : null,
                  ),
                ),
                DropdownMenuItem(
                  value: 'www',
                  enabled: !_existingTypes.contains('www'),
                  child: Text(
                    '${_i18n.t('collection_type_www')}${_existingTypes.contains('www') ? ' ${_i18n.t('already_exists')}' : ''}',
                    style: _existingTypes.contains('www')
                        ? TextStyle(color: Colors.grey)
                        : null,
                  ),
                ),
                DropdownMenuItem(
                  value: 'postcards',
                  enabled: !_existingTypes.contains('postcards'),
                  child: Text(
                    '${_i18n.t('collection_type_postcards')}${_existingTypes.contains('postcards') ? ' ${_i18n.t('already_exists')}' : ''}',
                    style: _existingTypes.contains('postcards')
                        ? TextStyle(color: Colors.grey)
                        : null,
                  ),
                ),
                DropdownMenuItem(
                  value: 'contacts',
                  enabled: !_existingTypes.contains('contacts'),
                  child: Text(
                    '${_i18n.t('collection_type_contacts')}${_existingTypes.contains('contacts') ? ' ${_i18n.t('already_exists')}' : ''}',
                    style: _existingTypes.contains('contacts')
                        ? TextStyle(color: Colors.grey)
                        : null,
                  ),
                ),
                DropdownMenuItem(
                  value: 'places',
                  enabled: !_existingTypes.contains('places'),
                  child: Text(
                    '${_i18n.t('collection_type_places')}${_existingTypes.contains('places') ? ' ${_i18n.t('already_exists')}' : ''}',
                    style: _existingTypes.contains('places')
                        ? TextStyle(color: Colors.grey)
                        : null,
                  ),
                ),
                DropdownMenuItem(
                  value: 'market',
                  enabled: !_existingTypes.contains('market'),
                  child: Text(
                    '${_i18n.t('collection_type_market')}${_existingTypes.contains('market') ? ' ${_i18n.t('already_exists')}' : ''}',
                    style: _existingTypes.contains('market')
                        ? TextStyle(color: Colors.grey)
                        : null,
                  ),
                ),
                DropdownMenuItem(
                  value: 'report',
                  enabled: !_existingTypes.contains('report'),
                  child: Text(
                    '${_i18n.t('collection_type_report')}${_existingTypes.contains('report') ? ' ${_i18n.t('already_exists')}' : ''}',
                    style: _existingTypes.contains('report')
                        ? TextStyle(color: Colors.grey)
                        : null,
                  ),
                ),
              ].where((item) {
                // Hide disabled items (existing fixed types) instead of greying them out
                if (item.value == 'files') return true; // Always show files
                return item.enabled ?? true;
              }).toList(),
              onChanged: _isCreating ? null : (value) {
                if (value != null) {
                  setState(() {
                    _collectionType = value;
                    // Auto-set title for non-files types
                    if (value != 'files') {
                      _titleController.text = value;
                    } else {
                      // Clear title when switching back to files type
                      if (_titleController.text == 'www' ||
                          _titleController.text == 'forum' ||
                          _titleController.text == 'chat' ||
                          _titleController.text == 'blog' ||
                          _titleController.text == 'events' ||
                          _titleController.text == 'news' ||
                          _titleController.text == 'postcards' ||
                          _titleController.text == 'contacts' ||
                          _titleController.text == 'places' ||
                          _titleController.text == 'market') {
                        _titleController.text = '';
                      }
                    }
                  });
                }
              },
            ),
            // Only show title and description for 'files' type
            if (_collectionType == 'files') ...[
              const SizedBox(height: 16),
              TextField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: _i18n.t('collection_title'),
                  hintText: _i18n.t('collection_title_hint'),
                  border: const OutlineInputBorder(),
                ),
                autofocus: true,
                enabled: !_isCreating,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _descriptionController,
                decoration: InputDecoration(
                  labelText: _i18n.t('collection_description'),
                  hintText: _i18n.t('collection_description_hint'),
                  border: const OutlineInputBorder(),
                ),
                maxLines: 3,
                enabled: !_isCreating,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!_isCreating) {
                    _create();
                  }
                },
              ),
              const SizedBox(height: 16),
            ],
            // Only show folder selection for 'files' type
            if (_collectionType == 'files') ...[
              const Divider(),
              const SizedBox(height: 8),
              // Auto folder checkbox
              CheckboxListTile(
                title: const Text('Use default folder'),
                subtitle: Text(
                  _useAutoFolder
                      ? '~/Documents/geogram/collections'
                      : 'Choose custom location',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: _useAutoFolder,
                enabled: !_isCreating,
                onChanged: (value) {
                  setState(() {
                    _useAutoFolder = value ?? true;
                    if (_useAutoFolder) {
                      _selectedFolderPath = null;
                    }
                  });
                },
                contentPadding: EdgeInsets.zero,
              ),
              // Folder picker (shown when auto folder is disabled)
              if (!_useAutoFolder) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _isCreating ? null : _pickFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose Root Folder'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
              if (_selectedFolderPath != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder,
                        size: 20,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _selectedFolderPath!,
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isCreating ? null : () => Navigator.pop(context),
          child: Text(_i18n.t('cancel')),
        ),
        FilledButton(
          onPressed: _isCreating ? null : _create,
          child: _isCreating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_i18n.t('create')),
        ),
      ],
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

// Devices Page
class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final i18n = I18nService();
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.devices,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            i18n.t('devices'),
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            i18n.t('connected_devices_will_be_listed_here'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

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

  @override
  void initState() {
    super.initState();
    // Listen to language changes to rebuild the UI
    _i18n.languageNotifier.addListener(_onLanguageChanged);
  }

  @override
  void dispose() {
    _i18n.languageNotifier.removeListener(_onLanguageChanged);
    super.dispose();
  }

  void _onLanguageChanged() {
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
          leading: const Icon(Icons.settings_input_antenna),
          title: Text(_i18n.t('connections')),
          subtitle: Text(_i18n.t('manage_relays_and_network')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const RelaysPage()),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: Text(_i18n.t('notifications')),
          subtitle: Text(_i18n.t('configure_notifications')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const NotificationsPage()),
            );
          },
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.language),
          title: Text(_i18n.t('language')),
          subtitle: Text(_i18n.getLanguageName(_i18n.currentLanguage)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _showLanguageDialog,
        ),
        ListTile(
          leading: const Icon(Icons.info_outlined),
          title: Text(_i18n.t('about')),
          subtitle: Text(_i18n.t('app_version_and_info')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const AboutPage()),
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
