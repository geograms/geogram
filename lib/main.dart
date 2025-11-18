import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'services/log_service.dart';
import 'services/config_service.dart';
import 'services/collection_service.dart';
import 'services/profile_service.dart';
import 'services/relay_service.dart';
import 'services/notification_service.dart';
import 'models/collection.dart';
import 'util/file_icon_helper.dart';
import 'pages/profile_page.dart';
import 'pages/about_page.dart';
import 'pages/relays_page.dart';
import 'pages/location_page.dart';
import 'pages/notifications_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize log service first to capture any initialization errors
  await LogService().init();
  LogService().log('Geogram Desktop starting...');

  try {
    // Initialize services
    await ConfigService().init();
    LogService().log('ConfigService initialized');

    await CollectionService().init();
    LogService().log('CollectionService initialized');

    await ProfileService().initialize();
    LogService().log('ProfileService initialized');

    await RelayService().initialize();
    LogService().log('RelayService initialized');

    await NotificationService().initialize();
    LogService().log('NotificationService initialized');
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

  static const List<Widget> _pages = [
    CollectionsPage(),
    GeoChatPage(),
    DevicesPage(),
    LogPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.folder_special),
            SizedBox(width: 8),
            Text('Geogram'),
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
        children: const [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Text(
              'Navigation',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          NavigationDrawerDestination(
            icon: Icon(Icons.folder_special_outlined),
            selectedIcon: Icon(Icons.folder_special),
            label: Text('Collections'),
          ),
          NavigationDrawerDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: Text('GeoChat'),
          ),
          NavigationDrawerDestination(
            icon: Icon(Icons.devices_outlined),
            selectedIcon: Icon(Icons.devices),
            label: Text('Devices'),
          ),
          NavigationDrawerDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: Text('Log'),
          ),
          Divider(),
          NavigationDrawerDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: Text('Settings'),
          ),
        ],
      ),
      body: _pages[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (int index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.folder_special_outlined),
            selectedIcon: Icon(Icons.folder_special),
            label: 'Collections',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'GeoChat',
          ),
          NavigationDestination(
            icon: Icon(Icons.devices_outlined),
            selectedIcon: Icon(Icons.devices),
            label: 'Devices',
          ),
          NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: 'Log',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
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
  final TextEditingController _searchController = TextEditingController();

  List<Collection> _allCollections = [];
  List<Collection> _filteredCollections = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    LogService().log('Collections page opened');
    _loadCollections();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCollections() async {
    setState(() => _isLoading = true);

    try {
      final collections = await _collectionService.loadCollections();

      // Sort: favorites first, then alphabetically
      collections.sort((a, b) {
        if (a.isFavorite != b.isFavorite) {
          return a.isFavorite ? -1 : 1;
        }
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });

      setState(() {
        _allCollections = collections;
        _filteredCollections = collections;
        _isLoading = false;
      });

      LogService().log('Loaded ${collections.length} collections');
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

  Future<void> _deleteCollection(Collection collection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Collection'),
        content: Text('Are you sure you want to delete "${collection.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
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
                hintText: 'Search collections...',
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
                                  ? 'No collections yet'
                                  : 'No collections found',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _allCollections.isEmpty
                                  ? 'Create your first collection'
                                  : 'Try a different search',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadCollections,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: _filteredCollections.length,
                          itemBuilder: (context, index) {
                            final collection = _filteredCollections[index];
                            return _CollectionCard(
                              collection: collection,
                              onTap: () {
                                LogService().log('Opened collection: ${collection.title}');
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => CollectionBrowserPage(
                                      collection: collection,
                                    ),
                                  ),
                                ).then((_) => _loadCollections());
                              },
                              onFavoriteToggle: () => _toggleFavorite(collection),
                              onDelete: () => _deleteCollection(collection),
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
        label: const Text('New Collection'),
      ),
    );
  }
}

// Collection Card Widget
class _CollectionCard extends StatelessWidget {
  final Collection collection;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onDelete;

  const _CollectionCard({
    required this.collection,
    required this.onTap,
    required this.onFavoriteToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
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
                    Icons.folder_special,
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
                    label: '${collection.filesCount} files',
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
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  bool _isCreating = false;
  bool _useAutoFolder = true;
  String? _selectedFolderPath;

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
        const SnackBar(content: Text('Please enter a title')),
      );
      return;
    }

    if (!_useAutoFolder && _selectedFolderPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a root folder')),
      );
      return;
    }

    setState(() => _isCreating = true);

    try {
      LogService().log('Creating collection with title: $title');

      final collection = await CollectionService().createCollection(
        title: title,
        description: _descriptionController.text.trim(),
        customRootPath: _useAutoFolder ? null : _selectedFolderPath,
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
      title: const Text('New Collection'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'Enter collection title',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              enabled: !_isCreating,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'Enter collection description',
                border: OutlineInputBorder(),
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
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isCreating ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isCreating ? null : _create,
          child: _isCreating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
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
            'GeoChat',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Your conversations will appear here',
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
            'Devices',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Connected devices will be listed here',
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
  final TextEditingController _filterController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isPaused = false;
  String _filterText = '';

  @override
  void initState() {
    super.initState();
    _logService.addListener(_onLogUpdate);

    // Add some initial logs for demonstration
    Future.delayed(Duration.zero, () {
      _logService.log('Geogram Desktop started');
      _logService.log('Log system initialized');
    });
  }

  @override
  void dispose() {
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
        content: Text(_isPaused ? 'Log paused' : 'Log resumed'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _clearLog() {
    _logService.clear();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Log cleared'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _copyToClipboard() {
    final logText = _getFilteredLogs();
    if (logText.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: logText));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Log copied to clipboard'),
          duration: Duration(seconds: 1),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Log is empty'),
          duration: Duration(seconds: 1),
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
                  tooltip: _isPaused ? 'Resume' : 'Pause',
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
                      decoration: const InputDecoration(
                        hintText: 'Filter',
                        hintStyle: TextStyle(color: Colors.grey),
                        prefixIcon: Icon(Icons.search, color: Colors.white),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
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
                  tooltip: 'Clear',
                  onPressed: _clearLog,
                ),
                // Copy Button
                IconButton(
                  icon: const Icon(Icons.copy),
                  color: Colors.white,
                  tooltip: 'Copy to Clipboard',
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
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Settings',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('Profile'),
          subtitle: const Text('Manage your profile'),
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
          title: const Text('Location'),
          subtitle: const Text('Set your location on the map'),
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
          title: const Text('Connections'),
          subtitle: const Text('Manage internet relays and network settings'),
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
          title: const Text('Notifications'),
          subtitle: const Text('Configure notifications'),
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
          leading: const Icon(Icons.info_outlined),
          title: const Text('About'),
          subtitle: const Text('App version and information'),
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
  final TextEditingController _searchController = TextEditingController();
  List<FileNode> _allFiles = [];
  List<FileNode> _filteredFiles = [];
  bool _isLoading = true;
  final Set<String> _expandedFolders = {}; // Track expanded folder paths

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  @override
  void dispose() {
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
        dialogTitle: 'Select files to add',
      );

      if (result != null && result.files.isNotEmpty) {
        final paths = result.files.map((f) => f.path!).toList();
        LogService().log('Adding ${paths.length} files to collection');

        await _collectionService.addFiles(widget.collection, paths);
        LogService().log('Files added successfully');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Added ${paths.length} file(s)')),
          );
        }

        _loadFiles();
      }
    } catch (e) {
      LogService().log('Error adding files: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding files: $e')),
        );
      }
    }
  }

  Future<void> _addFolder() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select folder to add',
      );

      if (result != null) {
        LogService().log('Adding folder to collection: $result');

        await _collectionService.addFolder(widget.collection, result);
        LogService().log('Folder added successfully');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Folder added successfully')),
          );
        }

        _loadFiles();
      }
    } catch (e) {
      LogService().log('Error adding folder: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding folder: $e')),
        );
      }
    }
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();

    final folderName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Folder'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Folder Name',
            hintText: 'Enter folder name',
            border: OutlineInputBorder(),
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context, controller.text.trim());
            },
            child: const Text('Create'),
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
            SnackBar(content: Text('Created folder: $folderName')),
          );
        }

        _loadFiles();
      } catch (e) {
        LogService().log('Error creating folder: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error creating folder: $e')),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.collection.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _editSettings,
            tooltip: 'Collection Settings',
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
                      '${widget.collection.filesCount} files',
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
                      widget.collection.visibility,
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
                hintText: 'Search files...',
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
                    label: const Text('Add Files'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _addFolder,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Add Folder'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _createFolder,
                    icon: const Icon(Icons.create_new_folder),
                    label: const Text('Create Folder'),
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
                              _searchController.text.isEmpty ? 'No files yet' : 'No matching files',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _searchController.text.isEmpty
                                  ? 'Add files or folders to get started'
                                  : 'Try a different search term',
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
  File? _thumbnailFile;

  @override
  void initState() {
    super.initState();
    if (!widget.fileNode.isDirectory && FileIconHelper.isImage(widget.fileNode.name)) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
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
    if (widget.fileNode.isDirectory) {
      final fileCount = widget.fileNode.fileCount;
      final size = _formatSize(widget.fileNode.size);
      if (fileCount == 1) {
        return '1 file • $size';
      } else {
        return '$fileCount files • $size';
      }
    } else {
      return _formatSize(widget.fileNode.size);
    }
  }

  Future<void> _openFile() async {
    if (widget.fileNode.isDirectory) return;

    try {
      final filePath = '${widget.collectionPath}/${widget.fileNode.path}';
      final file = File(filePath);

      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File not found')),
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
            const SnackBar(content: Text('Cannot open this file type')),
          );
        }
        LogService().log('Cannot launch file: $filePath');
      }
    } catch (e) {
      LogService().log('Error opening file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening file: $e')),
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
    } else if (_thumbnailFile != null) {
      // Image thumbnail
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
        const SnackBar(content: Text('Please enter a title')),
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
          SnackBar(content: Text('Error updating collection: $e')),
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
      title: const Text('Collection Settings'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Collection ID (read-only)
              Text(
                'Collection ID',
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
                decoration: const InputDecoration(
                  labelText: 'Title',
                  border: OutlineInputBorder(),
                ),
                enabled: !_isSaving,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),

              // Description
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
                enabled: !_isSaving,
              ),
              const SizedBox(height: 16),

              const Divider(),
              const SizedBox(height: 8),

              Text(
                'Permissions',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),

              // Visibility
              DropdownButtonFormField<String>(
                initialValue: _visibility,
                decoration: const InputDecoration(
                  labelText: 'Visibility',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'public', child: Text('Public')),
                  DropdownMenuItem(value: 'private', child: Text('Private')),
                  DropdownMenuItem(value: 'restricted', child: Text('Restricted')),
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
                decoration: const InputDecoration(
                  labelText: 'Encryption',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('None')),
                  DropdownMenuItem(value: 'aes256', child: Text('AES-256')),
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
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
