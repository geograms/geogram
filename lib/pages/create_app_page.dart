/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'package:flutter/material.dart';
import '../services/app_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../util/app_constants.dart';
import '../util/app_type_theme.dart';

/// Full-page UI for creating a new app
/// Features a two-column layout: type selector on left, details panel on right
class CreateAppPage extends StatefulWidget {
  const CreateAppPage({super.key});

  @override
  State<CreateAppPage> createState() => _CreateAppPageState();
}

class _CreateAppPageState extends State<CreateAppPage> {
  final I18nService _i18n = I18nService();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _searchController = TextEditingController();

  String? _selectedType;
  bool _isCreating = false;
  String _searchQuery = '';
  Set<String> _existingTypes = {};
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _itemKeys = {};

  /// Get app types sorted alphabetically by localized name
  List<_AppTypeInfo> get _sortedTypes {
    final types = List<_AppTypeInfo>.from(_appTypes);
    types.sort(
      (a, b) => _i18n
          .t('app_type_${a.type}')
          .toLowerCase()
          .compareTo(_i18n.t('app_type_${b.type}').toLowerCase()),
    );
    return types;
  }

  /// Get filtered app types based on search query
  List<_AppTypeInfo> get _filteredTypes {
    if (_searchQuery.isEmpty) {
      return _sortedTypes;
    }
    final query = _searchQuery.toLowerCase();
    return _sortedTypes.where((typeInfo) {
      final title = _i18n.t('app_type_${typeInfo.type}').toLowerCase();
      final description = _getTypeDescription(typeInfo.type).toLowerCase();
      return title.contains(query) || description.contains(query);
    }).toList();
  }

  // App types with their icons (ordered by relevance)
  // Hidden types (not ready): forum, bot, postcards, market, www, news
  static const List<_AppTypeInfo> _appTypes = [
    _AppTypeInfo('places', Icons.place),
    _AppTypeInfo('blog', Icons.article),
    _AppTypeInfo('chat', Icons.chat),
    _AppTypeInfo('contacts', Icons.contacts),
    _AppTypeInfo('email', Icons.email),
    _AppTypeInfo('events', Icons.event),
    // _AppTypeInfo('forum', Icons.forum),  // Hidden: not ready
    _AppTypeInfo('alerts', Icons.campaign),
    // _AppTypeInfo('news', Icons.newspaper),  // Hidden: not ready
    // _AppTypeInfo('www', Icons.language),  // Hidden: not ready
    _AppTypeInfo('inventory', Icons.inventory_2),
    _AppTypeInfo('wallet', Icons.account_balance_wallet),
    _AppTypeInfo('log', Icons.article_outlined),
    _AppTypeInfo('backup', Icons.backup),
    _AppTypeInfo('transfer', Icons.swap_horiz),
    _AppTypeInfo('shared', Icons.folder_shared),
    // _AppTypeInfo('postcards', Icons.mail),  // Hidden: not ready
    // _AppTypeInfo('market', Icons.storefront),  // Hidden: not ready
    _AppTypeInfo('groups', Icons.groups),
    _AppTypeInfo('console', Icons.terminal),
    _AppTypeInfo('tracker', Icons.track_changes),
    _AppTypeInfo('videos', Icons.video_library),
    _AppTypeInfo('reader', Icons.menu_book),
    _AppTypeInfo('flasher', Icons.flash_on),
    _AppTypeInfo('work', Icons.work),
    _AppTypeInfo('music', Icons.library_music),
    _AppTypeInfo('stories', Icons.auto_stories),
    _AppTypeInfo('files', Icons.snippet_folder),
    _AppTypeInfo('qr', Icons.qr_code_2),
    _AppTypeInfo('conference', Icons.mic),
  ];

  // Single-instance types - use centralized constant from app_constants.dart
  static const Set<String> _singleInstanceTypes = singleInstanceTypesConst;

  @override
  void initState() {
    super.initState();
    _checkExistingTypes();
  }

  Future<void> _checkExistingTypes() async {
    try {
      final appsService = AppService();
      final appsDir = Directory(
        '${appsService.getDefaultAppsPath()}',
      );

      if (await appsDir.exists()) {
        final folders = await appsDir.list().toList();
        final existingFolderNames = folders
            .where((e) => e is Directory)
            .map((e) => e.path.split('/').last)
            .toSet();

        setState(() {
          _existingTypes = _singleInstanceTypes.intersection(
            existingFolderNames,
          );
          // Files app is always present (virtual, no folder on disk)
          _existingTypes.add('files');
          // Initialize item keys for scroll-to functionality
          for (final type in _appTypes) {
            _itemKeys[type.type] = GlobalKey();
          }
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
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _canCreate {
    if (_isCreating) return false;
    if (_selectedType == null) return false;
    if (_existingTypes.contains(_selectedType)) return false;
    return true;
  }

  Future<void> _create() async {
    if (!_canCreate || _selectedType == null) return;

    setState(() => _isCreating = true);

    try {
      final type = _selectedType!;
      final title = _i18n.t('app_type_$type');

      final app = await AppService().createApp(
        title: title,
        description: _descriptionController.text.trim(),
        type: type,
      );

      LogService().log('Created app: ${app.title}');

      if (mounted) {
        Navigator.pop(context, app);
      }
    } catch (e, stackTrace) {
      LogService().log('ERROR creating app: $e');
      LogService().log('Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating app: $e')),
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
    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('add_new_app')),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _buildAppList(),
    );
  }

  Widget _buildAppList() {
    final filteredTypes = _filteredTypes;
    final theme = Theme.of(context);

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: _i18n.t('search_apps'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerLow,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onChanged: (value) => setState(() => _searchQuery = value),
          ),
        ),
        // App list
        Expanded(
          child: filteredTypes.isEmpty
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
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: filteredTypes.length,
                  itemBuilder: (context, index) =>
                      _buildAppListItem(filteredTypes[index]),
                ),
        ),
      ],
    );
  }

  /// Get a gradient for the app type icon
  LinearGradient _getTypeGradient(String type, ThemeData theme) {
    return getAppTypeGradient(type, theme.brightness == Brightness.dark);
  }

  Widget _buildAppListItem(_AppTypeInfo typeInfo) {
    final theme = Theme.of(context);
    final isDisabled =
        _existingTypes.contains(typeInfo.type) &&
        _singleInstanceTypes.contains(typeInfo.type);
    final isExpanded = _selectedType == typeInfo.type;
    final description = _getTypeDescription(typeInfo.type);
    final features = _getTypeFeatures(typeInfo.type);

    return Padding(
      key: _itemKeys[typeInfo.type],
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: isExpanded
            ? theme.colorScheme.surfaceContainerHigh
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isDisabled
              ? null
              : () {
                  setState(() {
                    _selectedType = isExpanded ? null : typeInfo.type;
                    // Clear title when collapsing or switching types
                    _titleController.clear();
                  });
                  // Scroll to make expanded item fully visible (including bottom content)
                  if (!isExpanded) {
                    // Wait for expand animation to complete before scrolling
                    Future.delayed(const Duration(milliseconds: 280), () {
                      if (!mounted) return;
                      final key = _itemKeys[typeInfo.type];
                      if (key?.currentContext != null) {
                        Scrollable.ensureVisible(
                          key!.currentContext!,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          alignment:
                              0.8, // Show item near bottom to ensure Create button is visible
                        );
                      }
                    });
                  }
                },
          borderRadius: BorderRadius.circular(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header (always visible)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Circular gradient icon
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        gradient: _getTypeGradient(typeInfo.type, theme),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _getTypeGradient(
                              typeInfo.type,
                              theme,
                            ).colors.first.withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(typeInfo.icon, size: 26, color: Colors.white),
                    ),
                    const SizedBox(width: 16),
                    // Title + short description
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _i18n.t('app_type_${typeInfo.type}'),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            description,
                            maxLines: isExpanded ? 3 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Status badge or expand indicator
                    if (isDisabled)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _i18n.t('exists'),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      AnimatedRotation(
                        turns: isExpanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Expanded details with animation
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: isExpanded
                    ? _buildExpandedDetails(
                        typeInfo,
                        theme,
                        description,
                        features,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedDetails(
    _AppTypeInfo typeInfo,
    ThemeData theme,
    String description,
    List<String> features,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Subtle divider
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Features as horizontal chips
              if (features.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: features
                      .map(
                        (f) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check,
                                size: 14,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  f,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurface,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
              const SizedBox(height: 24),
              // Create button - more prominent
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _canCreate ? _create : null,
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isCreating
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: theme.colorScheme.onPrimary,
                          ),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.add_circle_outline, size: 22),
                            const SizedBox(width: 10),
                            Text(
                              _i18n.t('create'),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _getTypeDescription(String type) {
    // Try to get from i18n, fallback to default descriptions
    final key = 'app_type_desc_$type';
    final translated = _i18n.t(key);
    if (translated != key) return translated;

    // Fallback descriptions
    switch (type) {
      case 'shared':
        return 'Manage shared folders from a single app. Add local directories, set visibility, and browse their contents.';
      case 'forum':
        return 'Discussion forum for threaded conversations and community discussions. Topics are organized by categories with support for replies and moderation.';
      case 'chat':
        return 'Real-time messaging with support for multiple channels. Perfect for team communication or group discussions.';
      case 'blog':
        return 'Publish articles and posts for sharing your thoughts, tutorials, or updates. Supports rich content with images and formatting.';
      case 'events':
        return 'Create and manage events with dates, times, locations, and attendee registration. Great for organizing meetups or activities.';
      case 'email':
        return 'Decentralized email with NOSTR-based identity for cryptographic signatures. Send and receive emails through your station.';
      case 'news':
        return 'Share news and announcements with your network. Keep your community informed about updates and important information.';
      case 'www':
        return 'Host a personal website with full HTML, CSS, and JavaScript support. Accessible via your station URL.';
      case 'postcards':
        return 'Send and receive digital postcards with images and personal messages. A fun way to share memories and greetings.';
      case 'contacts':
        return 'Store contact information for people and organizations. Keep your network organized and accessible.';
      case 'places':
        return 'Save and share locations with maps, coordinates, and descriptions. Document interesting places or share recommendations.';
      case 'market':
        return 'List items for sale, trade, or giveaway. A simple marketplace for your community.';
      case 'alerts':
        return 'Receive and manage alerts and notifications. Stay informed about important updates and events in your network.';
      case 'groups':
        return 'Organize people into groups for easier management and communication. Create teams or interest groups.';
      case 'backup':
        return 'Securely backup your data to other devices with end-to-end encryption. Your data stays private while being safely stored across trusted contacts.';
      case 'inventory':
        return 'Track and manage your items with folder-based organization. Keep track of quantities, usage, expiry dates, and borrowed items.';
      case 'station':
        return 'Station configuration for network communication settings. Manage how your node connects to the network.';
      case 'console':
        return 'Run Alpine Linux virtual machines with TinyEMU emulator. Access a full Linux terminal, mount host folders, and connect to network services.';
      case 'reader':
        return 'Your personal reading hub for RSS feeds, manga, and e-books. Subscribe to news sources, follow manga series, and organize your digital library.';
      case 'flasher':
        return 'Flash firmware to ESP32 and other USB-connected devices. Supports multiple device families with auto-detection and progress tracking.';
      case 'work':
        return 'Create and organize workspaces with NDF documents including spreadsheets, rich text documents, presentations, and forms. Sync-based collaboration with NOSTR signatures.';
      case 'music':
        return 'Local music player with folder-based album discovery. Scan your music folders, play tracks with shuffle and repeat, track listening history and statistics.';
      case 'stories':
        return 'Tell your story your way. Create stunning visual experiences with tap-through scenes, touch hotspots, and cinematic auto-play. Share moments, build tutorials, or craft adventures that captivate your audience.';
      case 'files':
        return 'Browse and manage files on your device. View the geogram profile folder contents and navigate the filesystem. Opens documents, images, music, and videos with built-in viewers.';
      case 'qr':
        return 'Scan and generate QR codes and barcodes. Create WiFi sharing codes, URLs, contacts, and more. Organize your codes in folders and share them as images.';
      case 'conference':
        return 'Host or join P2P audio meetings. Create voice rooms on your local network or through your station. Share via link or QR code for up to 6 participants.';
      default:
        return '';
    }
  }

  List<String> _getTypeFeatures(String type) {
    // Try to get from i18n first
    final key = 'app_type_features_$type';
    final translated = _i18n.t(key);
    if (translated != key) {
      return translated.split('|');
    }

    // Fallback features
    switch (type) {
      case 'shared':
        return [
          'Add local directories',
          'Set visibility per folder',
          'Browse files in-app',
          'Restrict access by user',
        ];
      case 'forum':
        return [
          'Threaded discussions',
          'Categories and topics',
          'User moderation',
          'Pinned topics',
        ];
      case 'chat':
        return [
          'Multiple channels',
          'Text, image, and file sharing',
          'Message history',
          'Participant management',
        ];
      case 'blog':
        return [
          'Rich text editor',
          'Image embedding',
          'Draft saving',
          'Post scheduling',
        ];
      case 'events':
        return [
          'Date/time scheduling',
          'Location mapping',
          'Registration',
          'Reminders',
        ];
      case 'email':
        return [
          'NOSTR signature verification',
          'Threaded conversations',
          'Attachments with deduplication',
          'Labels and folders',
          'Multi-station identities',
        ];
      case 'news':
        return [
          'Chronological feed',
          'Categories',
          'Featured posts',
          'Notifications',
        ];
      case 'www':
        return [
          'Full web hosting',
          'Custom HTML/CSS/JS',
          'Accessible at station-url/callsign',
        ];
      case 'postcards':
        return [
          'Image attachments',
          'Personal messages',
          'Send/receive tracking',
        ];
      case 'contacts':
        return ['Contact details', 'Organization info', 'Search', 'Export'];
      case 'places':
        return ['Map integration', 'Coordinates', 'Descriptions', 'Photos'];
      case 'market':
        return ['Item listings', 'Pricing', 'Categories', 'Contact seller'];
      case 'alerts':
        return [
          'Real-time notifications',
          'Priority levels',
          'Alert history',
          'Custom filters',
        ];
      case 'groups':
        return ['Member management', 'Group roles', 'Bulk actions'];
      case 'backup':
        return [
          'End-to-end encryption',
          'Multiple providers',
          'Automatic scheduling',
          'Full restore support',
        ];
      case 'inventory':
        return [
          'Folder-based organization',
          'Quantity and usage tracking',
          'Batch/lot management with expiry',
          'Borrowing and lending',
          '200+ item types with templates',
        ];
      case 'station':
        return ['Connection settings', 'Peer management', 'Bandwidth controls'];
      case 'console':
        return [
          'Alpine Linux VM',
          'Mount host folders',
          'Network access',
          'Save/restore state',
        ];
      case 'reader':
        return [
          'RSS feed subscriptions',
          'Manga source integration',
          'E-book library',
          'Reading progress tracking',
        ];
      case 'flasher':
        return [
          'ESP32 and USB device flashing',
          'USB auto-detection by VID/PID',
          'Multiple protocol support',
          'Progress tracking with verification',
        ];
      case 'work':
        return [
          'Spreadsheets with formulas',
          'Rich text documents',
          'Presentations with slides',
          'Forms with responses',
          'Workspace collaboration',
        ];
      case 'music':
        return [
          'Folder-based album discovery',
          'Cover art detection',
          'Shuffle and repeat modes',
          'Play queue management',
          'Listening statistics',
        ];
      case 'stories':
        return [
          'Tap-through scene flow',
          'Interactive touch hotspots',
          'Auto-play with countdown',
          'Flexible text and image layouts',
          'Link to URLs or sounds',
        ];
      case 'files':
        return [
          'Profile folder browser',
          'Device file navigation',
          'Built-in document viewer',
          'Image, music, and video playback',
          'Storage location shortcuts',
        ];
      case 'qr':
        return [
          'Scan QR codes and barcodes',
          'Generate WiFi, URL, contact codes',
          'Support for EAN, UPC, Code 128',
          'Organize in folders',
          'Share as images',
        ];
      case 'conference':
        return [
          'P2P audio calls',
          'LAN and station modes',
          'QR code sharing',
          'Web browser joining',
          'Up to 6 participants',
        ];
      default:
        return [];
    }
  }
}

/// Helper class for app type information
class _AppTypeInfo {
  final String type;
  final IconData icon;

  const _AppTypeInfo(this.type, this.icon);
}
