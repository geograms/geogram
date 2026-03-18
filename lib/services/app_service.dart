import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'package:mime/mime.dart';
import '../models/app.dart';
import 'i18n_service.dart';
import '../models/chat_channel.dart';
import '../models/chat_security.dart';
import '../models/chat_settings.dart';
import '../models/forum_section.dart';
import '../platform/file_system_service.dart';
import '../util/app_constants.dart';
import '../util/nostr_key_generator.dart';
import '../util/tlsh.dart';
import '../util/html_utils.dart';
import '../util/nostr_login_scripts.dart';
import '../util/web_navigation.dart';
import 'config_service.dart';
import 'chat_service.dart';
import 'encrypted_storage_stub.dart' if (dart.library.ui) 'encrypted_storage_service.dart';
import 'profile_service.dart';
import 'profile_storage.dart';
import 'storage_config.dart';
import 'web_theme_service.dart';
import 'blog_service.dart' hide ChatSecurity;
import 'conference_service.dart';
import 'conference_archive_service.dart';
import 'event_service.dart';
import '../tracker/models/tracker_visibility.dart';
import '../work/services/work_storage_service.dart';


/// Service for managing apps on disk (or in memory for web)
class AppService {
  static final AppService _instance = AppService._internal();
  factory AppService() => _instance;
  AppService._internal();

  Directory? _devicesDir;
  Directory? _appsDir;
  String? _currentCallsign;
  String? _currentNsec;
  bool _useEncryptedStorage = false;
  final ConfigService _configService = ConfigService();
  final EncryptedStorageService _encryptedStorageService = EncryptedStorageService();
  ProfileStorage? _profileStorage;

  /// In-memory app store for web platform
  final Map<String, App> _webApps = {};

  /// Notifier for when callsign/apps change (incremented on change)
  final callsignNotifier = ValueNotifier<int>(0);

  /// Notifier for when apps are created, updated, or deleted
  final appsNotifier = ValueNotifier<int>(0);

  /// Get the default apps directory path
  String getDefaultAppsPath() {
    if (kIsWeb) {
      return '/web/apps';  // Virtual path for web
    }
    if (_appsDir == null) {
      throw Exception('AppService not initialized. Call init() and setActiveCallsign() first.');
    }
    return _appsDir!.path;
  }

  /// Get the devices directory path (base for all callsign folders)
  String getDevicesPath() {
    if (kIsWeb) {
      return '/web/devices';  // Virtual path for web
    }
    if (_devicesDir == null) {
      throw Exception('AppService not initialized. Call init() first.');
    }
    return _devicesDir!.path;
  }

  /// Get the current active callsign
  String? get currentCallsign => _currentCallsign;

  /// Whether the current profile uses encrypted storage
  bool get useEncryptedStorage => _useEncryptedStorage;

  /// Get the profile storage instance for the current profile
  /// This can be passed to other services that need file access
  ProfileStorage? get profileStorage => _profileStorage;

  /// Set the nsec for encrypted storage access
  /// Must be called before accessing encrypted profiles
  void setNsec(String nsec) {
    _currentNsec = nsec;
    // Recreate storage if we have a callsign and are using encrypted storage
    if (_currentCallsign != null && _useEncryptedStorage && _appsDir != null) {
      _profileStorage = EncryptedProfileStorage(
        callsign: _currentCallsign!,
        nsec: nsec,
        basePath: _appsDir!.path,
      );
    }
  }

  /// Initialize the app service (basic setup)
  ///
  /// Uses StorageConfig for path management. StorageConfig must be initialized
  /// before calling this method.
  Future<void> init() async {
    try {
      // On web, initialize virtual file system
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        await fs.init();

        // Create virtual devices directory
        await fs.createDirectory('/web/devices', recursive: true);

        stderr.writeln('AppService initialized (web mode - IndexedDB storage)');
        return;
      }

      final storageConfig = StorageConfig();
      if (!storageConfig.isInitialized) {
        throw StateError(
          'StorageConfig must be initialized before AppService. '
          'Call StorageConfig().init() first.',
        );
      }

      _devicesDir = Directory(storageConfig.devicesDir);

      if (!await _devicesDir!.exists()) {
        await _devicesDir!.create(recursive: true);
      }

      // Use stderr for init logs since LogService might not be ready
      stderr.writeln('AppService initialized: ${_devicesDir!.path}');
    } catch (e) {
      stderr.writeln('Error initializing AppService: $e');
      rethrow;
    }
  }

  /// Set the active callsign and configure the apps directory
  /// This should be called after ProfileService is initialized
  Future<void> setActiveCallsign(String callsign) async {
    // Sanitize callsign for folder name (alphanumeric, underscore, dash)
    final sanitizedCallsign = _sanitizeCallsign(callsign);
    _currentCallsign = sanitizedCallsign;

    // On web, create virtual apps directory
    if (kIsWeb) {
      final fs = FileSystemService.instance;
      final appsPath = '/web/devices/$sanitizedCallsign';
      await fs.createDirectory(appsPath, recursive: true);
      _profileStorage = FilesystemProfileStorage(appsPath);

      stderr.writeln('AppService active callsign (web): $sanitizedCallsign');
      stderr.writeln('Virtual apps directory: $appsPath');

      // Notify listeners that callsign changed
      callsignNotifier.value++;
      return;
    }

    if (_devicesDir == null) {
      throw Exception('AppService not initialized. Call init() first.');
    }

    _appsDir = Directory(p.join(_devicesDir!.path, sanitizedCallsign));

    // Check if this profile uses encrypted storage
    _useEncryptedStorage = _encryptedStorageService.isEncryptedStorageEnabled(sanitizedCallsign);

    if (_useEncryptedStorage) {
      // Don't create folder - data is in encrypted archive
      stderr.writeln('AppService active callsign: $sanitizedCallsign (encrypted storage)');
      stderr.writeln('Apps directory: ${_appsDir!.path} (virtual - data in encrypted archive)');

      // Create encrypted storage if we have nsec
      if (_currentNsec != null) {
        _profileStorage = EncryptedProfileStorage(
          callsign: sanitizedCallsign,
          nsec: _currentNsec!,
          basePath: _appsDir!.path,
        );
      }
    } else {
      if (!await _appsDir!.exists()) {
        await _appsDir!.create(recursive: true);
      }
      stderr.writeln('AppService active callsign: $sanitizedCallsign');
      stderr.writeln('Apps directory: ${_appsDir!.path}');

      // Create filesystem storage
      _profileStorage = FilesystemProfileStorage(_appsDir!.path);
    }

    // Notify listeners that callsign changed
    callsignNotifier.value++;
  }

  /// All known app/app types that can be routed to via URL
  /// Re-exported from app_constants.dart for convenience
  static List<String> get knownAppTypes => knownAppTypesConst;

  /// Default app types that should be created for every profile
  /// These are the core apps that users expect to be available
  static const List<String> defaultAppTypes = [
    'chat',
    'contacts',
    'email',
    'places',
    'events',
    'transfer',
    'tracker',
    'blog',
    'alerts',
    'log',
    'karma',
  ];

  /// Ensure default apps exist for the current profile
  /// This should be called after setActiveCallsign to create any missing default apps
  Future<void> ensureDefaultApps() async {
    if (_currentCallsign == null) {
      stderr.writeln('ensureDefaultApps: No active callsign set');
      return;
    }

    // Skip if using encrypted storage - apps are already in the archive
    if (_useEncryptedStorage) {
      stderr.writeln('ensureDefaultApps: Skipping - using encrypted storage');
      return;
    }

    // Check which default types already have folders — no full app scan needed
    for (final type in defaultAppTypes) {
      final dir = Directory('${_appsDir!.path}/$type');
      if (!await dir.exists()) {
        try {
          stderr.writeln('Creating default app: $type');
          final app = await createApp(
            title: I18nService().t('app_type_$type'),
            description: '',
            type: type,
          );
          stderr.writeln('Created default app: $type');
          if (type == 'www' && app.storagePath != null) {
            await generateDefaultWwwIndex(app);
          }
        } catch (e) {
          stderr.writeln('Error creating default app $type: $e');
        }
      }
    }
  }

  /// Generate default index.html for www app using the default theme
  /// This is public so it can be called from WebsocketService for on-demand creation
  Future<void> generateDefaultWwwIndex(App app) async {
    if (kIsWeb) return; // Skip on web platform

    try {
      final themeService = WebThemeService();
      await themeService.init();

      // Get the www template
      final template = await themeService.getTemplate('www');
      if (template == null) {
        stderr.writeln('Warning: www template not found, skipping index.html generation');
        return;
      }

      // Get app-specific styles (global styles served separately via /styles.css)
      final combinedStyles = await themeService.getAppStyles('www') ?? '';

      // Use nickname as display name, falling back to callsign
      final profile = ProfileService().getProfile();
      final displayName = profile.displayName.isNotEmpty ? profile.displayName : (_currentCallsign ?? 'My Website');
      final description = 'A personal website published via geogram';

      // Derive apps directory from the www app's storage path
      final appsPath = app.storagePath != null
          ? Directory(app.storagePath!).parent.path
          : null;

      // Build dynamic content
      final contentBuffer = StringBuffer();

      // Check for blog with public posts
      final blogInfo = await _getPublicBlogInfo(appsPath);
      List<Map<String, dynamic>> recentPosts = [];

      if (blogInfo != null && blogInfo['postCount'] > 0) {
        // Generate blog index page
        await generateBlogIndex(blogInfo['appPath'] as String);

        // Get recent posts for homepage
        final cache = await getBlogCacheOrRegenerate(blogInfo['appPath'] as String);
        final posts = (cache['posts'] as List?) ?? [];
        recentPosts = posts
            .where((p) => p['status'] == 'published')
            .take(5)
            .cast<Map<String, dynamic>>()
            .toList();
      }

      // Posts section using Terminimal theme structure
      contentBuffer.writeln('<div class="posts">');

      if (recentPosts.isNotEmpty) {
        for (final post in recentPosts) {
          final title = escapeHtml(post['title'] as String? ?? 'Untitled');
          final excerpt = escapeHtml(post['excerpt'] as String? ?? post['description'] as String? ?? '');
          final created = post['created'] as String? ?? '';
          final postId = post['id'] as String? ?? '';

          contentBuffer.writeln('''
<div class="post on-list">
  <h1 class="post-title"><a href="./blog/$postId.html">$title</a></h1>
  <div class="post-meta-inline">
    <span class="post-date">$created</span>
  </div>
  ${excerpt.isNotEmpty ? '<div class="post-content"><p>$excerpt</p><a class="read-more" href="./blog/$postId.html">Read more →</a></div>' : ''}
</div>''');
        }
      } else {
        contentBuffer.writeln('<div class="post"><p>No posts yet.</p></div>');
      }

      contentBuffer.writeln('</div>');

      // Generate dynamic menu items based on available public apps
      final menuItems = await generateDeviceMenu(
        activeApp: 'home',
        appsPath: appsPath,
        isRootLevel: true,
      );

      // Process template with dynamic content
      final html = themeService.processTemplate(template, {
        'TITLE': displayName,
        'COLLECTION_NAME': displayName,
        'APP_NAME': displayName,
        'APP_DESCRIPTION': description,
        'CONTENT': contentBuffer.toString(),
        'MENU_ITEMS': menuItems,
        'DATA_JSON': '{"files": []}',
        'SCRIPTS': '',
        'NOSTR_STYLES': getNostrLoginStyles(),
        'NOSTR_HEADER': getNostrLoginHeaderHtml(),
        'NOSTR_SCRIPTS': getNostrLoginScripts(),
        'GENERATED_DATE': DateTime.now().toIso8601String(),
      });

      // Write index.html and styles.css to the app folder via ProfileStorage
      if (_profileStorage != null && app.storagePath != null) {
        final appStorage = ScopedProfileStorage.fromAbsolutePath(_profileStorage!, app.storagePath!);
        await appStorage.writeString('index.html', html);
        await appStorage.writeString('styles.css', combinedStyles);
        stderr.writeln('Generated default www index.html + styles.css: ${app.storagePath}');
      } else {
        final indexFile = File('${app.storagePath}/index.html');
        await indexFile.writeAsString(html);
        final stylesFile = File('${app.storagePath}/styles.css');
        await stylesFile.writeAsString(combinedStyles);
        stderr.writeln('Generated default www index.html + styles.css: ${app.storagePath}');
      }
    } catch (e) {
      stderr.writeln('Error generating default www index.html: $e');
    }
  }

  /// Get device type string based on platform
  String _getDeviceType() {
    if (kIsWeb) return 'Web';
    try {
      if (Platform.isAndroid) return 'Android';
      if (Platform.isIOS) return 'iOS';
      if (Platform.isLinux) return 'Linux';
      if (Platform.isMacOS) return 'macOS';
      if (Platform.isWindows) return 'Windows';
      return 'Device';
    } catch (_) {
      return 'Device';
    }
  }

  /// Get month name
  String _getMonthName(int month) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return months[month - 1];
  }

  /// Generate blog cache - scans all posts and writes cache.json
  /// Returns the cache data and writes it to {blogAppPath}/cache.json
  Future<Map<String, dynamic>> generateBlogCache(String blogAppPath) async {
    final posts = <Map<String, dynamic>>[];

    // Use ProfileStorage if available
    if (_profileStorage != null) {
      final appStorage = ScopedProfileStorage.fromAbsolutePath(_profileStorage!, blogAppPath);
      if (!await appStorage.directoryExists('')) {
        return _writeBlogCache(blogAppPath, posts);
      }

      // Scan year directories (2024, 2025, etc.)
      final entries = await appStorage.listDirectory('');
      for (final entry in entries) {
        if (entry.isDirectory && RegExp(r'^\d{4}$').hasMatch(entry.name)) {
          final yearName = entry.name;
          // Scan post folders inside year directory
          final postEntries = await appStorage.listDirectory(yearName);
          for (final postEntry in postEntries) {
            if (postEntry.isDirectory) {
              final postContent = await appStorage.readString('$yearName/${postEntry.name}/post.md');
              if (postContent != null) {
                final postData = _parsePostContent(postContent, postEntry.name, yearName);
                if (postData != null) {
                  posts.add(postData);
                }
              }
            }
          }
        }
      }
    } else {
      final blogDir = Directory(blogAppPath);
      if (!await blogDir.exists()) {
        return _writeBlogCache(blogAppPath, posts);
      }

      // Scan year directories (2024, 2025, etc.)
      await for (final yearEntity in blogDir.list()) {
        if (yearEntity is Directory) {
          final yearName = yearEntity.path.split('/').last;
          if (!RegExp(r'^\d{4}$').hasMatch(yearName)) continue;

          await for (final postEntity in yearEntity.list()) {
            if (postEntity is Directory) {
              final postFile = File('${postEntity.path}/post.md');
              if (await postFile.exists()) {
                final content = await postFile.readAsString();
                final postFolder = postEntity.path.split('/').last;
                final postData = _parsePostContent(content, postFolder, yearName);
                if (postData != null) {
                  posts.add(postData);
                }
              }
            }
          }
        }
      }
    }

    // Sort by created date (newest first)
    posts.sort((a, b) => (b['created'] as String).compareTo(a['created'] as String));

    return _writeBlogCache(blogAppPath, posts);
  }

  /// Parse post.md content string and extract metadata
  Map<String, dynamic>? _parsePostContent(String content, String postFolder, String year) {
    try {
      final lines = content.split('\n');

      if (lines.isEmpty || !lines[0].startsWith('# BLOG: ')) {
        return null;
      }

      String? title = lines[0].substring(8).trim();
      String? author;
      String? created;
      String? edited;
      String? description;
      String status = 'draft';
      List<String> tags = [];

      for (final line in lines.skip(1)) {
        if (line.startsWith('AUTHOR: ')) {
          author = line.substring(8).trim();
        } else if (line.startsWith('CREATED: ')) {
          created = line.substring(9).trim();
        } else if (line.startsWith('EDITED: ')) {
          edited = line.substring(8).trim();
        } else if (line.startsWith('DESCRIPTION: ')) {
          description = line.substring(13).trim();
        } else if (line.startsWith('STATUS: ')) {
          status = line.substring(8).trim().toLowerCase();
        } else if (line.startsWith('--> tags: ')) {
          tags = line.substring(10).split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
        } else if (line.isEmpty && author != null && created != null) {
          // End of header
          break;
        }
      }

      if (title.isEmpty || author == null || created == null) {
        return null;
      }

      // Extract excerpt from content (first 250 chars after header+metadata)
      String? excerpt;
      // Find where actual content starts: skip header line, metadata lines,
      // and arrow-prefixed lines (e.g. --> tags:, --> npub:)
      bool pastHeader = false;
      int contentStartIndex = -1;
      for (int i = 1; i < lines.length; i++) {
        final line = lines[i];
        if (!pastHeader) {
          // Still in metadata section
          if (line.startsWith('AUTHOR: ') ||
              line.startsWith('CREATED: ') ||
              line.startsWith('EDITED: ') ||
              line.startsWith('DESCRIPTION: ') ||
              line.startsWith('STATUS: ') ||
              line.startsWith('--> ') ||
              line.isEmpty) {
            continue;
          }
          // First non-metadata, non-empty line = content start
          pastHeader = true;
          contentStartIndex = i;
          break;
        }
      }
      if (contentStartIndex > 0) {
        final contentLines = lines.sublist(contentStartIndex)
            .where((l) => l.trim().isNotEmpty && !l.startsWith('--> '))
            .toList();
        if (contentLines.isNotEmpty) {
          final fullContent = contentLines.take(5).join(' ');
          excerpt = fullContent.length > 250 ? '${fullContent.substring(0, 250)}...' : fullContent;
        }
      }

      return {
        'id': postFolder,
        'title': title,
        'author': author,
        'created': created,
        'edited': edited,
        'description': description,
        'excerpt': excerpt ?? description,
        'status': status,
        'tags': tags,
        'year': year,
        'path': '$year/$postFolder/post.md',
      };
    } catch (e) {
      return null;
    }
  }

  /// Write cache.json file and return the cache data
  Future<Map<String, dynamic>> _writeBlogCache(String blogPath, List<Map<String, dynamic>> posts) async {
    final publishedCount = posts.where((p) => p['status'] == 'published').length;
    final draftCount = posts.where((p) => p['status'] == 'draft').length;

    final cache = {
      'generated': DateTime.now().toIso8601String(),
      'totalPosts': posts.length,
      'publishedCount': publishedCount,
      'draftCount': draftCount,
      'posts': posts,
    };

    // Write cache.json via ProfileStorage
    if (_profileStorage != null) {
      final appStorage = ScopedProfileStorage.fromAbsolutePath(_profileStorage!, blogPath);
      await appStorage.writeString('cache.json', jsonEncode(cache));
    } else {
      final cacheFile = File('$blogPath/cache.json');
      await cacheFile.writeAsString(jsonEncode(cache));
    }

    return cache;
  }

  /// Generate blog index.html listing all published posts
  Future<void> generateBlogIndex(String blogAppPath) async {
    if (kIsWeb) return;

    try {
      final themeService = WebThemeService();
      await themeService.init();

      // Get the blog template
      final template = await themeService.getTemplate('blog');
      if (template == null) return;

      // Get app-specific styles (global styles served separately via /styles.css)
      final combinedStyles = await themeService.getAppStyles('blog') ?? '';

      // Get cache data
      final cache = await getBlogCacheOrRegenerate(blogAppPath);
      final posts = (cache['posts'] as List?) ?? [];

      // Filter only published posts
      final publishedPosts = posts
          .where((p) => p['status'] == 'published')
          .toList();

      // Build posts list HTML using Terminimal theme structure
      final postsHtml = StringBuffer();
      if (publishedPosts.isEmpty) {
        postsHtml.writeln('<div class="post"><p>No posts yet.</p></div>');
      } else {
        for (final post in publishedPosts) {
          final title = escapeHtml(post['title'] as String? ?? 'Untitled');
          final excerpt = escapeHtml(post['excerpt'] as String? ?? post['description'] as String? ?? '');
          final created = post['created'] as String? ?? '';
          final postId = post['id'] as String? ?? '';
          final tags = (post['tags'] as List?)?.cast<String>() ?? [];

          // Format date for display
          String displayDate = created;
          try {
            final dt = DateTime.parse(created.replaceAll('_', ':'));
            displayDate = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
          } catch (_) {}

          postsHtml.writeln('''
<div class="post on-list">
  <a href="$postId.html" class="blog-card-link">
    <h2 class="post-title">$title</h2>
    ${excerpt.isNotEmpty ? '<p class="blog-excerpt">$excerpt</p>' : ''}
    <div class="blog-card-footer">
      <span class="blog-card-date">$displayDate</span>
      ${tags.isNotEmpty ? '<span class="blog-card-tags">${tags.map((t) => '#${escapeHtml(t)}').join(' ')}</span>' : ''}
      <span class="blog-card-read">Read more →</span>
    </div>
  </a>
</div>''');
        }
      }

      // Generate dynamic menu items based on available public apps
      final menuItems = await generateDeviceMenu(
        activeApp: 'blog',
        appsPath: p.dirname(blogAppPath),
      );

      // Use nickname as display name, falling back to callsign
      final blogDisplayName = ProfileService().getProfile().displayName.isNotEmpty
          ? ProfileService().getProfile().displayName
          : (_currentCallsign ?? 'Blog');

      // Process template
      final html = themeService.processTemplate(template, {
        'TITLE': blogDisplayName,
        'COLLECTION_NAME': blogDisplayName,
        'APP_NAME': blogDisplayName,
        'APP_DESCRIPTION': '${publishedPosts.length} post${publishedPosts.length != 1 ? 's' : ''}',
        'CONTENT': postsHtml.toString(),
        'MENU_ITEMS': menuItems,
        'DATA_JSON': jsonEncode({'posts': publishedPosts}),
        'NOSTR_STYLES': getNostrLoginStyles(),
        'NOSTR_HEADER': getNostrLoginHeaderHtml(),
        'NOSTR_SCRIPTS': getNostrLoginScripts(),
      });

      // Write index.html + styles.css via ProfileStorage
      if (_profileStorage != null) {
        final appStorage = ScopedProfileStorage.fromAbsolutePath(_profileStorage!, blogAppPath);
        await appStorage.writeString('index.html', html);
        await appStorage.writeString('styles.css', combinedStyles);
      } else {
        final indexFile = File('$blogAppPath/index.html');
        await indexFile.writeAsString(html);
        final stylesFile = File('$blogAppPath/styles.css');
        await stylesFile.writeAsString(combinedStyles);
      }
    } catch (e) {
      stderr.writeln('Error generating blog index: $e');
    }
  }

  /// Get info about public blog posts using the cache
  /// [appsPath] - Optional path to the apps directory. If null, uses _appsDir
  Future<Map<String, dynamic>?> _getPublicBlogInfo([String? appsPath]) async {
    final dirPath = appsPath ?? _appsDir?.path;
    if (dirPath == null) return null;

    try {
      if (_profileStorage != null) {
        final appsStorage = ScopedProfileStorage.fromAbsolutePath(_profileStorage!, dirPath);
        if (!await appsStorage.directoryExists('')) return null;

        final entries = await appsStorage.listDirectory('');
        for (final entry in entries) {
          if (!entry.isDirectory) continue;
          final folderName = entry.name;

          final appJsContent = await appsStorage.readString('$folderName/app.js');
          if (appJsContent == null) continue;

          // Check if this is a blog app
          final isBlog = appJsContent.contains('"type": "blog"') ||
                        appJsContent.contains('"type":"blog"') ||
                        folderName == 'blog';

          if (isBlog) {
            // Check app visibility
            try {
              final appData = jsonDecode(appJsContent) as Map<String, dynamic>;
              if (appData['visibility'] == 'private') continue;
            } catch (_) {}

            // Read cache if recent, otherwise regenerate
            final appAbsPath = appsStorage.getAbsolutePath(folderName);
            final cache = await getBlogCacheOrRegenerate(appAbsPath);
            final publishedCount = cache['publishedCount'] as int? ?? 0;

            if (publishedCount > 0) {
              return {
                'postCount': publishedCount,
                'appPath': appAbsPath,
              };
            }
          }
        }
      } else {
        final appsDir = Directory(dirPath);
        if (!await appsDir.exists()) return null;

        // Look for blog apps
        await for (final entity in appsDir.list()) {
          if (entity is Directory) {
            final folderName = entity.path.split('/').last;
            final appJs = File('${entity.path}/app.js');

            if (await appJs.exists()) {
              final content = await appJs.readAsString();

              final isBlog = content.contains('"type": "blog"') ||
                            content.contains('"type":"blog"') ||
                            folderName == 'blog';

              if (isBlog) {
                try {
                  final appData = jsonDecode(content) as Map<String, dynamic>;
                  if (appData['visibility'] == 'private') continue;
                } catch (_) {}

                final cache = await getBlogCacheOrRegenerate(entity.path);
                final publishedCount = cache['publishedCount'] as int? ?? 0;

                if (publishedCount > 0) {
                  return {
                    'postCount': publishedCount,
                    'appPath': entity.path,
                  };
                }
              }
            }
          }
        }
      }
    } catch (e) {
      // Silent fail
    }

    return null;
  }

  /// Detect which apps have public content in the given apps directory.
  /// Checks each app for existence, non-private visibility, AND actual content.
  /// [appsPath] defaults to the current profile's apps directory.
  /// [storage] optional ProfileStorage; falls back to filesystem when null.
  Future<Map<String, bool>> getPublicApps({
    String? appsPath,
    ProfileStorage? storage,
  }) async {
    final result = <String, bool>{
      'blog': false,
      'chat': false,
      'events': false,
      'places': false,
      'files': false,
      'shared': false,
      'alerts': false,
      'meet': false,
      'work': false,
    };

    final effectiveStorage = storage ?? _profileStorage;
    final dirPath = appsPath ?? _appsDir?.path;
    if (dirPath == null) return result;

    try {
      for (final appType in result.keys) {
        if (appType == 'meet' || appType == 'work') continue; // handled separately below
        // Check directory exists and is not private
        if (!await _appIsPublic(appType, dirPath, effectiveStorage)) continue;
        // Check for actual content per app type
        result[appType] = await _appHasContent(appType, dirPath, effectiveStorage);
      }
    } catch (_) {}

    // Meet: show if there's an active conference or archived meetings
    try {
      if (ConferenceService().isActive) {
        result['meet'] = true;
      } else {
        final archives = await ConferenceArchiveService().listArchives();
        result['meet'] = archives.isNotEmpty;
      }
    } catch (_) {}

    // Work: show if any workspace has documents with public or unlisted visibility
    try {
      final apps = await loadApps();
      for (final app in apps) {
        if (app.type != 'work') continue;
        final storagePath = app.storagePath;
        if (storagePath == null) continue;
        final workStorage = WorkStorageService(
          effectiveStorage ?? FilesystemProfileStorage(storagePath),
          effectiveStorage != null ? storagePath : '',
        );
        final workspaces = await workStorage.loadWorkspaces();
        for (final ws in workspaces) {
          for (final doc in ws.documents) {
            final vis = ws.getDocumentVisibility(doc);
            if (vis.level == TrackerVisibilityLevel.public ||
                vis.level == TrackerVisibilityLevel.unlisted) {
              result['work'] = true;
              break;
            }
          }
          if (result['work']!) break;
        }
        if (result['work']!) break;
      }
    } catch (_) {}

    return result;
  }

  /// Check if an app directory exists and is not marked private.
  Future<bool> _appIsPublic(
      String appType, String dirPath, ProfileStorage? storage) async {
    if (storage != null) {
      final scoped = ScopedProfileStorage.fromAbsolutePath(storage, dirPath);
      if (!await scoped.directoryExists(appType)) return false;
      final appJs = await scoped.readString('$appType/app.js');
      if (appJs == null) return false;
      try {
        final data = jsonDecode(appJs) as Map<String, dynamic>;
        if (data['visibility'] == 'private') return false;
      } catch (_) {}
      return true;
    } else {
      if (!await Directory('$dirPath/$appType').exists()) return false;
      final appJsFile = File('$dirPath/$appType/app.js');
      if (!await appJsFile.exists()) return false;
      try {
        final data =
            jsonDecode(await appJsFile.readAsString()) as Map<String, dynamic>;
        if (data['visibility'] == 'private') return false;
      } catch (_) {}
      return true;
    }
  }

  /// Check if an app has actual content to display.
  Future<bool> _appHasContent(
      String appType, String dirPath, ProfileStorage? storage) async {
    final appPath = '$dirPath/$appType';
    try {
      switch (appType) {
        case 'blog':
          // Blog needs published posts
          final cache = await getBlogCacheOrRegenerate(appPath);
          return (cache['publishedCount'] as int? ?? 0) > 0;
        case 'chat':
          // Chat is interactive — available if it has channel structure
          if (storage != null) {
            final scoped =
                ScopedProfileStorage.fromAbsolutePath(storage, appPath);
            return await scoped.exists('extra/channels.json');
          }
          return await File('$appPath/extra/channels.json').exists();
        case 'shared':
          // Shared has content if any .json folder entries exist (excluding metadata files)
          const metaFiles = {'tree.json', 'app.js', 'data.js'};
          if (storage != null) {
            final scoped =
                ScopedProfileStorage.fromAbsolutePath(storage, appPath);
            final entries = await scoped.listDirectory('');
            return entries.any((e) =>
                e.name.endsWith('.json') && !metaFiles.contains(e.name));
          }
          final dir = Directory(appPath);
          if (!await dir.exists()) return false;
          final entries = await dir.list().toList();
          return entries.any((e) =>
              e is File &&
              e.path.endsWith('.json') &&
              !metaFiles.contains(e.path.split('/').last));
        case 'events':
          // Events: check for year subdirectories with event folders
          // (events are served dynamically, not from index.html)
          if (storage != null) {
            final scoped =
                ScopedProfileStorage.fromAbsolutePath(storage, appPath);
            final entries = await scoped.listDirectory('');
            return entries.any((e) =>
                e.isDirectory && RegExp(r'^\d{4}$').hasMatch(e.name));
          }
          final evDir = Directory(appPath);
          if (!await evDir.exists()) return false;
          final evEntries = await evDir.list().toList();
          return evEntries.any((e) =>
              e is Directory &&
              RegExp(r'^\d{4}$').hasMatch(e.path.split('/').last));
        default:
          // Places, files, alerts: need a generated index.html
          if (storage != null) {
            final scoped =
                ScopedProfileStorage.fromAbsolutePath(storage, appPath);
            return await scoped.exists('index.html');
          }
          return await File('$appPath/index.html').exists();
      }
    } catch (_) {
      return false;
    }
  }

  /// Generate device menu items based on actually available public apps.
  /// [activeApp] the currently active app ID.
  /// [appsPath] defaults to the current profile's apps directory.
  /// [storage] optional ProfileStorage; falls back to the profile's storage.
  /// [isRootLevel] true for pages served at the device root (/{callsign}/).
  Future<String> generateDeviceMenu({
    required String activeApp,
    String? appsPath,
    ProfileStorage? storage,
    bool isRootLevel = false,
    int depth = 1,
  }) async {
    final apps = await getPublicApps(appsPath: appsPath, storage: storage);

    // Check if download page should be shown (updates directory has version subdirs with files)
    bool hasDownload = false;
    try {
      final updatesDir = Directory('${StorageConfig().baseDir}/updates');
      if (await updatesDir.exists()) {
        await for (final entity in updatesDir.list()) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (RegExp(r'^\d+\.\d+').hasMatch(name)) {
              hasDownload = true;
              break;
            }
          }
        }
      }
    } catch (_) {}

    return WebNavigation.generateDeviceMenuItems(
      activeApp: activeApp,
      hasBlog: apps['blog']!,
      hasChat: apps['chat']!,
      hasEvents: apps['events']!,
      hasPlaces: apps['places']!,
      hasFiles: apps['files']!,
      hasShared: apps['shared']!,
      hasMeet: apps['meet'] ?? false,
      hasWork: apps['work'] ?? false,
      hasAlerts: apps['alerts']!,
      hasDownload: hasDownload,
      isRootLevel: isRootLevel,
      depth: depth,
    );
  }

  /// Generate chat index.html with IRC-style retro interface
  /// This is public so it can be called from WebsocketService for on-demand creation
  Future<void> generateChatIndex(String chatAppPath) async {
    if (kIsWeb) return;

    try {
      final themeService = WebThemeService();
      await themeService.init();

      // Get the chat template
      final template = await themeService.getTemplate('chat');
      if (template == null) return;

      // Get app-specific styles (global styles served separately via /styles.css)
      final combinedStyles = await themeService.getAppStyles('chat') ?? '';

      // Get chat rooms
      final chatService = ChatService();
      if (chatService.appPath == null) {
        // Set profile storage for encrypted storage support
        if (_profileStorage != null) {
          final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
            _profileStorage!,
            chatAppPath,
          );
          chatService.setStorage(scopedStorage);
        } else {
          chatService.setStorage(FilesystemProfileStorage(chatAppPath));
        }
        await chatService.initializeApp(chatAppPath, creatorNpub: ProfileService().getProfile().npub);
      }

      final channels = chatService.channels;

      // Build channel list HTML for sidebar
      final channelsHtml = StringBuffer();
      final defaultRoom = channels.isNotEmpty ? channels.first.id : 'main';

      for (final channel in channels) {
        final isActive = channel.id == defaultRoom;
        channelsHtml.writeln('''
<div class="channel-item${isActive ? ' active' : ''}" data-room-id="${escapeHtml(channel.id)}">
  <span class="channel-name">#${escapeHtml(channel.name ?? channel.id)}</span>
</div>''');
      }

      // Get recent messages for the default room
      final messages = await chatService.loadMessages(defaultRoom);
      final recentMessages = messages.take(50).toList();

      // Build messages HTML in IRC style
      final messagesHtml = StringBuffer();
      String? currentDate;

      for (final msg in recentMessages) {
        // Add date separator if date changed
        final msgDate = msg.timestamp.split(' ').first;
        if (currentDate != msgDate) {
          currentDate = msgDate;
          messagesHtml.writeln('<div class="date-separator">$msgDate</div>');
        }

        // Format time from timestamp
        final time = msg.timestamp.split(' ').length > 1
            ? msg.timestamp.split(' ')[1].replaceAll('_', ':').substring(0, 5)
            : '00:00';
        final author = escapeHtml(msg.author);
        final content = escapeHtml(msg.content ?? '');

        messagesHtml.writeln('''
<div class="message" data-timestamp="${escapeHtml(msg.timestamp)}">
  <div class="message-header">
    <span class="message-author">$author</span>
    <span class="message-time">$time</span>
  </div>
  <div class="message-content">$content</div>
</div>''');
      }

      // Build data JSON for JavaScript
      // Use relative path so API calls go to the device, not the station
      final channelsList = channels.map((c) => <String, dynamic>{
        'id': c.id,
        'name': c.name ?? c.id,
        'type': c.type.name,
      }).toList();
      final dataJson = jsonEncode({
        'channels': channelsList,
        'currentRoom': defaultRoom,
        'apiBasePath': '../api/chat/rooms',
      });

      // Determine which apps are available for this app
      // Generate dynamic menu items based on available public apps
      final menuItems = await generateDeviceMenu(
        activeApp: 'chat',
        appsPath: p.dirname(chatAppPath),
      );

      // Use nickname as display name, falling back to callsign
      final chatDisplayName = ProfileService().getProfile().displayName.isNotEmpty
          ? ProfileService().getProfile().displayName
          : (_currentCallsign ?? 'Chat');

      // Process template
      final html = themeService.processTemplate(template, {
        'TITLE': chatDisplayName,
        'COLLECTION_NAME': chatDisplayName,
        'APP_NAME': chatDisplayName,
        'APP_DESCRIPTION': '${channels.length} channel${channels.length != 1 ? 's' : ''}',
        'CONTENT': messagesHtml.toString(),
        'CHANNELS_LIST': channelsHtml.toString(),
        'DATA_JSON': dataJson,
        'SCRIPTS': '${getNostrLoginScripts()}\n${themeService.getChatScripts()}',
        'MENU_ITEMS': menuItems,
        'HOME_URL': '../',
        'NOSTR_STYLES': getNostrLoginStyles(),
        'NOSTR_HEADER': getNostrLoginHeaderHtml(),
        'GENERATED_DATE': DateTime.now().toIso8601String().split('T').first,
      });

      // Write index.html + styles.css via ProfileStorage
      if (_profileStorage != null) {
        final appStorage = ScopedProfileStorage.fromAbsolutePath(_profileStorage!, chatAppPath);
        await appStorage.writeString('index.html', html);
        await appStorage.writeString('styles.css', combinedStyles);
      } else {
        final indexFile = File('$chatAppPath/index.html');
        await indexFile.writeAsString(html);
        final stylesFile = File('$chatAppPath/styles.css');
        await stylesFile.writeAsString(combinedStyles);
      }
    } catch (e) {
      stderr.writeln('Error generating chat index: $e');
    }
  }

  /// Get blog cache - reads existing if less than a day old, otherwise regenerates
  Future<Map<String, dynamic>> getBlogCacheOrRegenerate(String blogPath) async {
    // Use ProfileStorage if available
    if (_profileStorage != null) {
      final appStorage = ScopedProfileStorage.fromAbsolutePath(_profileStorage!, blogPath);
      final content = await appStorage.readString('cache.json');
      if (content != null) {
        try {
          final cache = jsonDecode(content) as Map<String, dynamic>;
          // Check if cache is less than a day old
          final generated = cache['generated'] as String?;
          if (generated != null) {
            final generatedDate = DateTime.tryParse(generated);
            if (generatedDate != null) {
              final age = DateTime.now().difference(generatedDate);
              if (age.inHours < 24) {
                return cache;
              }
            }
          }
        } catch (_) {
          // Cache corrupted, regenerate
        }
      }
    } else {
      final cacheFile = File('$blogPath/cache.json');
      if (await cacheFile.exists()) {
        final stat = await cacheFile.stat();
        final age = DateTime.now().difference(stat.modified);

        if (age.inHours < 24) {
          try {
            final content = await cacheFile.readAsString();
            return jsonDecode(content) as Map<String, dynamic>;
          } catch (_) {
            // Cache corrupted, regenerate
          }
        }
      }
    }

    // Cache doesn't exist or is too old, regenerate
    return generateBlogCache(blogPath);
  }

  /// Sanitize callsign for use as folder name
  String _sanitizeCallsign(String callsign) {
    // Keep only alphanumeric, underscore, and dash characters
    return callsign
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')  // Collapse multiple underscores
        .replaceAll(RegExp(r'^_|_$'), ''); // Remove leading/trailing underscores
  }

  /// Get the apps directory
  /// Note: This throws on web as Directory operations are not supported
  Directory get appsDirectory {
    if (kIsWeb) {
      throw UnsupportedError('appsDirectory is not available on web platform');
    }
    if (_appsDir == null) {
      throw Exception('AppService not initialized. Call init() first.');
    }
    return _appsDir!;
  }

  /// Load all apps from disk (including from custom locations)
  /// On web, loads apps from virtual file system (IndexedDB)
  ///
  /// For faster startup, consider using [loadAppsFast] instead
  /// which does a single batch directory listing with no per-app I/O.
  Future<List<App>> loadApps() async {
    final apps = <App>[];
    await for (final app in loadAppsStream()) {
      apps.add(app);
    }
    return apps;
  }

  /// Load all apps in a single batch — no stream, no per-app I/O for known types.
  /// Shared_folder apps get minimal metadata (folder name as title);
  /// full metadata can be loaded lazily if needed.
  /// Works transparently with both filesystem and encrypted storage.
  Future<List<App>> loadAppsFast() async {
    if (kIsWeb) {
      return loadApps(); // fallback for web
    }
    if (_profileStorage == null) {
      throw Exception('AppService not initialized.');
    }

    final results = <App>[];
    results.add(_createMinimalApp('files', _profileStorage!.basePath));

    final entries = await _profileStorage!.listDirectory('');
    for (final entry in entries) {
      if (entry.isDirectory) {
        final folderName = entry.name;
        if (folderName == 'files') continue; // already added above
        if (folderName == 'logs') continue; // legacy system folder, skip
        if (folderName == 'mirror') continue; // internal sync folder, not an app
        final storagePath = _profileStorage!.getAbsolutePath(folderName);
        if (singleInstanceTypesConst.contains(folderName)) {
          results.add(_createMinimalApp(folderName, storagePath));
        } else {
          // Unknown folder — try to load from app.js
          final app = await _loadAppFromStorage(folderName);
          if (app != null) results.add(app);
        }
      }
    }

    return results;
  }

  /// Load apps progressively as a stream.
  /// This allows the UI to display apps as they load instead of
  /// waiting for all apps to be scanned.
  ///
  /// Example usage:
  /// ```dart
  /// AppService().loadAppsStream().listen((app) {
  ///   setState(() => _apps.add(app));
  /// });
  /// ```
  Stream<App> loadAppsStream() async* {
    // On web, load from virtual file system
    if (kIsWeb) {
      yield* _loadWebAppsStream();
      return;
    }

    if (_profileStorage == null) {
      throw Exception('AppService not initialized. Call setActiveCallsign() first.');
    }

    // Always yield files app (no folder needed)
    yield _createMinimalApp('files', _profileStorage!.basePath);

    // Single directory listing via abstract storage layer
    final entries = await _profileStorage!.listDirectory('');
    for (final entry in entries) {
      if (entry.isDirectory) {
        final folderName = entry.name;
        if (folderName == 'files') continue; // already added above
        if (folderName == 'logs') continue; // legacy system folder, skip
        if (folderName == 'mirror') continue; // internal sync folder, not an app
        try {
          if (singleInstanceTypesConst.contains(folderName)) {
            // Known single-instance type — skip app.js entirely
            final storagePath = _profileStorage!.getAbsolutePath(folderName);
            yield _createMinimalApp(folderName, storagePath);
          } else {
            // Unknown folder — needs app.js for metadata
            final app = await _loadAppFromStorage(folderName);
            if (app != null) yield app;
          }
        } catch (e) {
          stderr.writeln('Error loading app from $folderName: $e');
        }
      }
    }
  }

  /// Load apps from encrypted storage
  /// Load an app from ProfileStorage (encrypted or filesystem)
  Future<App?> _loadAppFromStorage(String folderName) async {
    if (_profileStorage == null) return null;

    final appJsPath = '$folderName/app.js';

    // Check if app.js exists
    if (!await _profileStorage!.exists(appJsPath)) {
      // Check if this is a chat folder created by CLI
      final channelsExists = await _profileStorage!.exists('$folderName/extra/channels.json');
      final mainExists = await _profileStorage!.directoryExists('$folderName/main');

      if (channelsExists || mainExists) {
        stderr.writeln('Auto-creating app.js for encrypted chat folder: $folderName');
        await _autoCreateChatAppForStorage(folderName);
        if (!await _profileStorage!.exists(appJsPath)) {
          return null;
        }
      } else if (folderName == 'contacts') {
        stderr.writeln('Auto-creating app.js for encrypted contacts folder: $folderName');
        await _autoCreateContactsAppForStorage(folderName);
        if (!await _profileStorage!.exists(appJsPath)) {
          return null;
        }
      } else {
        return null;
      }
    }

    try {
      final content = await _profileStorage!.readString(appJsPath);
      if (content == null) return null;

      // Extract JSON from JavaScript file
      final startIndex = content.indexOf('window.APP_DATA = {');
      if (startIndex == -1) return null;

      final jsonStart = content.indexOf('{', startIndex);
      final jsonEnd = content.lastIndexOf('};');
      if (jsonStart == -1 || jsonEnd == -1) return null;

      final jsonContent = content.substring(jsonStart, jsonEnd + 1);
      final data = json.decode(jsonContent) as Map<String, dynamic>;

      final appData = data['app'] as Map<String, dynamic>?;
      if (appData == null) return null;

      // Check for cached stats
      final cachedStats = data['cachedStats'] as Map<String, dynamic>?;
      final hasCachedStats = cachedStats != null &&
          cachedStats['fileCount'] != null &&
          cachedStats['totalSize'] != null;

      final storagePath = _profileStorage!.getAbsolutePath(folderName);

      final app = App(
        id: appData['id'] as String? ?? '',
        title: appData['title'] as String? ?? 'Untitled',
        description: appData['description'] as String? ?? '',
        type: appData['type'] as String? ?? 'shared',
        updated: appData['updated'] as String? ?? DateTime.now().toIso8601String(),
        storagePath: storagePath,
        isOwned: true,
        visibility: 'public',
        allowedReaders: const [],
        encryption: 'none',
        filesCount: hasCachedStats ? (cachedStats['fileCount'] as int? ?? 0) : 0,
        totalSize: hasCachedStats ? (cachedStats['totalSize'] as int? ?? 0) : 0,
      );

      // Set favorite status from config
      app.isFavorite = _configService.isFavorite(app.id);

      // Load security settings from storage
      await _loadSecuritySettingsFromStorage(app, folderName);

      return app;
    } catch (e) {
      stderr.writeln('Error parsing encrypted app.js for $folderName: $e');
      return null;
    }
  }

  /// Load security settings from ProfileStorage
  Future<void> _loadSecuritySettingsFromStorage(App app, String folderName) async {
    if (_profileStorage == null) return;

    final securityPath = '$folderName/extra/security.json';
    final content = await _profileStorage!.readString(securityPath);
    if (content == null) return;

    try {
      final data = json.decode(content) as Map<String, dynamic>;
      app.visibility = data['visibility'] as String? ?? 'public';
      app.encryption = data['encryption'] as String? ?? 'none';
      final readers = data['allowedReaders'] as List<dynamic>?;
      app.allowedReaders = readers?.map((e) => e.toString()).toList() ?? [];
    } catch (e) {
      stderr.writeln('Error loading security settings for $folderName: $e');
    }
  }

  /// Auto-create chat app.js for encrypted storage
  Future<void> _autoCreateChatAppForStorage(String folderName) async {
    if (_profileStorage == null) return;

    try {
      final keys = NostrKeyGenerator.generateKeyPair();
      _configService.storeAppKeys(keys);

      final app = App(
        id: keys.npub,
        title: 'Chat',
        description: '',
        type: 'chat',
        updated: DateTime.now().toIso8601String(),
        storagePath: _profileStorage!.getAbsolutePath(folderName),
        isOwned: true,
        isFavorite: false,
        filesCount: 0,
        totalSize: 0,
      );

      await _profileStorage!.writeString(
        '$folderName/app.js',
        app.generateAppJs(),
      );
    } catch (e) {
      stderr.writeln('Error auto-creating chat app.js for storage: $e');
    }
  }

  /// Auto-create contacts app.js for encrypted storage
  Future<void> _autoCreateContactsAppForStorage(String folderName) async {
    if (_profileStorage == null) return;

    try {
      final keys = NostrKeyGenerator.generateKeyPair();
      _configService.storeAppKeys(keys);

      final app = App(
        id: keys.npub,
        title: 'Contacts',
        description: '',
        type: 'contacts',
        updated: DateTime.now().toIso8601String(),
        storagePath: _profileStorage!.getAbsolutePath(folderName),
        isOwned: true,
        isFavorite: false,
        filesCount: 0,
        totalSize: 0,
      );

      await _profileStorage!.writeString(
        '$folderName/app.js',
        app.generateAppJs(),
      );
    } catch (e) {
      stderr.writeln('Error auto-creating contacts app.js for storage: $e');
    }
  }

  /// Load web apps from virtual file system
  Stream<App> _loadWebAppsStream() async* {
    // First yield any cached in-memory apps
    for (final app in _webApps.values) {
      yield app;
    }

    // Then try to load from IndexedDB
    if (_currentCallsign == null) return;

    final fs = FileSystemService.instance;
    final appsPath = '/web/devices/$_currentCallsign';

    if (!await fs.exists(appsPath)) return;

    final entities = await fs.list(appsPath);
    for (final entity in entities) {
      if (entity.isDirectory) {
        try {
          final app = await _loadWebAppFromFolder(entity.path);
          if (app != null && !_webApps.containsKey(app.id)) {
            _webApps[app.id] = app;
            yield app;
          }
        } catch (e) {
          stderr.writeln('Error loading web app from ${entity.path}: $e');
        }
      }
    }
  }

  /// Load an app from virtual file system (web)
  Future<App?> _loadWebAppFromFolder(String folderPath) async {
    final fs = FileSystemService.instance;
    final appJsPath = '$folderPath/app.js';

    if (!await fs.exists(appJsPath)) {
      return null;
    }

    try {
      final content = await fs.readAsString(appJsPath);

      // Extract JSON from JavaScript file
      final startIndex = content.indexOf('window.APP_DATA = {');
      if (startIndex == -1) return null;

      final jsonStart = content.indexOf('{', startIndex);
      final jsonEnd = content.lastIndexOf('};');
      if (jsonStart == -1 || jsonEnd == -1) return null;

      final jsonContent = content.substring(jsonStart, jsonEnd + 1);
      final data = json.decode(jsonContent) as Map<String, dynamic>;

      final appData = data['app'] as Map<String, dynamic>?;
      if (appData == null) return null;

      // Check for cached stats
      final cachedStats = data['cachedStats'] as Map<String, dynamic>?;

      final app = App(
        id: appData['id'] as String? ?? '',
        title: appData['title'] as String? ?? 'Untitled',
        description: appData['description'] as String? ?? '',
        type: appData['type'] as String? ?? 'shared',
        updated: appData['updated'] as String? ?? DateTime.now().toIso8601String(),
        storagePath: folderPath,
        isOwned: true,
        visibility: 'public',
        allowedReaders: const [],
        encryption: 'none',
        filesCount: cachedStats?['fileCount'] as int? ?? 0,
        totalSize: cachedStats?['totalSize'] as int? ?? 0,
      );

      // Set favorite status from config
      app.isFavorite = _configService.isFavorite(app.id);

      return app;
    } catch (e) {
      stderr.writeln('Error parsing web app.js: $e');
      return null;
    }
  }

  /// Create a minimal App for known single-instance types.
  /// Get a single app by type without scanning the directory.
  /// For single-instance types the folder name equals the type.
  /// Returns null if the folder doesn't exist.
  App? getAppByType(String type) {
    if (_profileStorage == null) return null;
    final path = _profileStorage!.getAbsolutePath(type);
    return _createMinimalApp(type, path);
  }

  /// Skips app.js parsing — the folder name is the type.
  App _createMinimalApp(String type, String storagePath) {
    final title = I18nService().t('app_type_$type');
    final app = App(
      id: type,
      title: title,
      type: type,
      updated: DateTime.now().toIso8601String(),
      storagePath: storagePath,
      isOwned: true,
    );
    app.isFavorite = _configService.isFavorite(app.id);
    return app;
  }

  Future<bool> _autoCreateContactsAppJs(Directory folder) async {
    final folderName = folder.path.split('/').last;
    if (folderName != 'contacts') {
      return false;
    }

    try {
      stderr.writeln('Auto-creating app.js for contacts folder: ${folder.path}');
      await _ensureContactsSupportFiles(folder);

      final keys = NostrKeyGenerator.generateKeyPair();
      _configService.storeAppKeys(keys);

      final app = App(
        id: keys.npub,
        title: 'Contacts',
        description: '',
        type: 'contacts',
        updated: DateTime.now().toIso8601String(),
        storagePath: folder.path,
        isOwned: true,
        isFavorite: false,
        filesCount: 0,
        totalSize: 0,
      );

      final appJsFile = File('${folder.path}/app.js');
      await appJsFile.writeAsString(app.generateAppJs());
      return true;
    } catch (e) {
      stderr.writeln('Error auto-creating contacts app.js: $e');
      return false;
    }
  }

  Future<void> _ensureContactsSupportFiles(Directory folder) async {
    final mediaDir = Directory('${folder.path}/media');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }

    final extraDir = Directory('${folder.path}/extra');
    if (!await extraDir.exists()) {
      await extraDir.create(recursive: true);
    }

    final securityFile = File('${folder.path}/extra/security.json');
    if (!await securityFile.exists()) {
      final profileService = ProfileService();
      final currentProfile = profileService.getProfile();
      final securityData = {
        'version': '1.0',
        'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
        'moderators': <String>[],
        'bannedNpubs': <String>[],
      };
      await securityFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(securityData),
      );
    }
  }

  /// Schedule background generation of tree.json and other files
  void _scheduleBackgroundGeneration(Directory folder, App app) {
    // Use Future.delayed to not block the current load
    Future.delayed(const Duration(milliseconds: 100), () async {
      try {
        stderr.writeln('Background: Generating tree.json for ${app.title}');
        await _generateAndSaveTreeJson(folder);

        // For files and www types, also ensure data.js and index.html exist
        if (app.type == 'shared' || app.type == 'www') {
          if (!await _hasRequiredFiles(folder)) {
            await _generateAndSaveDataJs(folder);
            await _generateAndSaveIndexHtml(folder);
          }
        }

        // Update file count after generation
        await _countAppFiles(app, folder);
        await _saveCachedStats(app, folder);

        // Notify that app was updated
        appsNotifier.value++;
      } catch (e) {
        stderr.writeln('Background generation error for ${app.title}: $e');
      }
    });
  }

  /// Save cached stats to app.js for faster subsequent loads
  Future<void> _saveCachedStats(App app, Directory folder) async {
    try {
      final appJsFile = File('${folder.path}/app.js');
      if (!await appJsFile.exists()) return;

      final content = await appJsFile.readAsString();

      // Extract existing data
      final startIndex = content.indexOf('window.APP_DATA = {');
      if (startIndex == -1) return;

      final jsonStart = content.indexOf('{', startIndex);
      final jsonEnd = content.lastIndexOf('};');
      if (jsonStart == -1 || jsonEnd == -1) return;

      final jsonContent = content.substring(jsonStart, jsonEnd + 1);
      final data = json.decode(jsonContent) as Map<String, dynamic>;

      // Add/update cached stats
      data['cachedStats'] = {
        'fileCount': app.filesCount,
        'totalSize': app.totalSize,
        'lastScanned': DateTime.now().toIso8601String(),
      };

      // Write back
      final newContent = 'window.APP_DATA = ${json.encode(data)};';
      await appJsFile.writeAsString(newContent);
    } catch (e) {
      // Non-critical - just log and continue
      stderr.writeln('Could not save cached stats: $e');
    }
  }

  /// Count files and calculate total size in an app
  Future<void> _countAppFiles(App app, Directory folder) async {
    int fileCount = 0;
    int totalSize = 0;

    try {
      // Read from tree.json (which should already be generated/validated)
      final treeJsonFile = File('${folder.path}/extra/tree.json');
      bool usedTreeJson = false;

      if (await treeJsonFile.exists()) {
        final content = await treeJsonFile.readAsString();

        // Only try to parse if content is not empty
        if (content.trim().isNotEmpty) {
          try {
            final entries = json.decode(content) as List<dynamic>;

            // Count files recursively from nested tree.json structure
            void countRecursive(List<dynamic> items) {
              for (var entry in items) {
                if (entry['type'] == 'file') {
                  fileCount++;
                  totalSize += entry['size'] as int? ?? 0;
                } else if (entry['type'] == 'directory' && entry['children'] != null) {
                  countRecursive(entry['children'] as List<dynamic>);
                }
              }
            }
            countRecursive(entries);
            usedTreeJson = true;
          } catch (parseError) {
            // JSON parse failed, will fallback to directory scan
            stderr.writeln('Warning: Could not parse tree.json, falling back to directory scan');
          }
        }
      }

      if (!usedTreeJson) {
        // Fallback: scan filesystem directly if tree.json doesn't exist or is invalid
        await _scanDirectoryForCount(folder, (count, size) {
          fileCount += count;
          totalSize += size;
        });
      }
    } catch (e) {
      stderr.writeln('Error counting files: $e');
    }

    app.filesCount = fileCount;
    app.totalSize = totalSize;
  }

  /// Scan directory recursively to count files (fallback when tree.json doesn't exist)
  Future<void> _scanDirectoryForCount(Directory dir, void Function(int count, int size) onCount) async {
    try {
      final entities = await dir.list().toList();

      for (var entity in entities) {
        if (entity is File) {
          // Skip system files
          final fileName = entity.path.split('/').last;
          if (!fileName.startsWith('.') &&
              fileName != 'app.js' &&
              fileName != 'tree.json' &&
              fileName != 'data.js') {
            try {
              final stat = await entity.stat();
              onCount(1, stat.size);
            } catch (e) {
              // Skip files that can't be accessed
            }
          }
        } else if (entity is Directory) {
          // Skip system directories
          final dirName = entity.path.split('/').last;
          if (!dirName.startsWith('.') && dirName != 'extra') {
            await _scanDirectoryForCount(entity, onCount);
          }
        }
      }
    } catch (e) {
      stderr.writeln('Error scanning directory ${dir.path}: $e');
    }
  }

  /// Create a new app
  Future<App> createApp({
    required String title,
    String description = '',
    String type = 'shared',
  }) async {
    try {
      // Generate NOSTR key pair (npub/nsec)
      final keys = NostrKeyGenerator.generateKeyPair();
      final id = keys.npub; // Use npub as app ID

      stderr.writeln('Creating app with ID (npub): $id');

      // Store keys in config
      _configService.storeAppKeys(keys);

      // On web, use virtual file system (IndexedDB)
      if (kIsWeb) {
        return await _createWebApp(id: id, title: title, description: description, type: type);
      }

      if (_appsDir == null || _profileStorage == null) {
        throw Exception('AppService not initialized. Call init() first.');
      }

      // All types use the type name as folder name (single-instance)
      String folderName = type;

      stderr.writeln('Using fixed folder name for $type: $folderName');

      // Check if this type already exists
      if (await _profileStorage!.directoryExists(folderName)) {
        // Check if the folder is essentially empty (only hidden/system files)
        // This can happen if the app was "deleted" but folder remained
        final entries = await _profileStorage!.listDirectory(folderName);
        final hasAppJs = entries.any((e) => e.name == 'app.js');
        final hasUserContent = entries.any((e) {
          // Hidden files/folders (starting with .) and system folders are not user content
          return !e.name.startsWith('.') && e.name != 'extra' && e.name != 'media';
        });

        if (hasAppJs) {
          // Genuinely installed app — refuse to overwrite
          throw Exception('A $type app already exists');
        }

        if (hasUserContent) {
          // Synced folder with data but no app.js — adopt it by writing
          // metadata into the existing folder instead of rejecting it
          stderr.writeln('Adopting synced folder for $type (has content but no app.js)');
          await _profileStorage!.createDirectory('$folderName/extra');
          final storagePath = _profileStorage!.getAbsolutePath(folderName);
          final app = App(
            id: id,
            title: title,
            description: description,
            type: type,
            updated: DateTime.now().toIso8601String(),
            storagePath: storagePath,
            isOwned: true,
            isFavorite: false,
            filesCount: 0,
            totalSize: 0,
          );
          await _writeAppFilesWithStorage(app, folderName);
          stderr.writeln('Adopted synced folder as $type app');
          appsNotifier.value++;
          return app;
        }

        // Folder exists but is empty - delete it and recreate fresh
        stderr.writeln('Found empty $type folder, recreating...');
        await _profileStorage!.deleteDirectory(folderName, recursive: true);
      }

      stderr.writeln('Creating folder: $folderName');

      // Create folder structure using storage abstraction
      await _profileStorage!.createDirectory(folderName);
      await _profileStorage!.createDirectory('$folderName/extra');

      stderr.writeln('Folders created successfully');

      // Create skeleton template files based on type
      await _createSkeletonFilesWithStorage(type, folderName);

      // Get the storage path (virtual for encrypted, real for filesystem)
      final storagePath = _profileStorage!.getAbsolutePath(folderName);

      // Create app object
      final app = App(
        id: id,
        title: title,
        description: description,
        type: type,
        updated: DateTime.now().toIso8601String(),
        storagePath: storagePath,
        isOwned: true,
        isFavorite: false,
        filesCount: 0,
        totalSize: 0,
      );

      stderr.writeln('Writing app files...');

      // Write app files using storage abstraction
      await _writeAppFilesWithStorage(app, folderName);

      stderr.writeln('App created successfully');

      // Notify listeners that apps changed
      appsNotifier.value++;

      return app;
    } catch (e, stackTrace) {
      stderr.writeln('Error in createApp: $e');
      stderr.writeln('Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Create an app using direct filesystem (for custom root paths)
  Future<App> _createFilesystemApp({
    required String id,
    required String title,
    required String description,
    required String type,
    required String customRootPath,
  }) async {
    // Sanitize folder name
    var folderName = title
        .replaceAll(' ', '_')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
    if (folderName.length > 50) folderName = folderName.substring(0, 50);
    folderName = folderName.replaceAll(RegExp(r'_+$'), '');
    if (folderName.isEmpty) folderName = 'collection';

    // Create folder with uniqueness check
    var appFolder = Directory('$customRootPath/$folderName');
    int counter = 1;
    while (await appFolder.exists()) {
      appFolder = Directory('$customRootPath/${folderName}_$counter');
      counter++;
    }

    // Create folder structure
    await appFolder.create(recursive: true);
    await Directory('${appFolder.path}/extra').create();

    // Create skeleton files
    await _createSkeletonFiles(type, appFolder);

    // Create app object
    final app = App(
      id: id,
      title: title,
      description: description,
      type: type,
      updated: DateTime.now().toIso8601String(),
      storagePath: appFolder.path,
      isOwned: true,
      isFavorite: false,
      filesCount: 0,
      totalSize: 0,
    );

    // Write app files
    await _writeAppFiles(app, appFolder);

    appsNotifier.value++;
    return app;
  }

  /// Create an app for web platform with persistence to IndexedDB
  Future<App> _createWebApp({
    required String id,
    required String title,
    required String description,
    required String type,
  }) async {
    stderr.writeln('Creating web app (IndexedDB): $title [$type]');

    if (_currentCallsign == null) {
      throw Exception('No active callsign set');
    }

    final fs = FileSystemService.instance;

    // All types use the type name as folder name
    String folderName = type;

    final basePath = '/web/devices/$_currentCallsign';
    var appPath = '$basePath/$folderName';

    // Check if already exists
      if (await fs.exists(appPath)) {
        // Check if the folder is essentially empty (can be recreated)
        final entities = await fs.list(appPath);
        final hasUserContent = entities.any((entity) {
          return !entity.name.startsWith('.') &&
              entity.name != 'extra' &&
              entity.name != 'media';
        });

        if (hasUserContent) {
          throw Exception('A $type app already exists');
        }

        // Folder exists but is empty - delete it and recreate fresh
        await fs.delete(appPath, recursive: true);
      }


    // Create folder structure
    await fs.createDirectory(appPath, recursive: true);
    await fs.createDirectory('$appPath/extra', recursive: true);

    final app = App(
      id: id,
      title: title,
      description: description,
      type: type,
      updated: DateTime.now().toIso8601String(),
      storagePath: appPath,
      isOwned: true,
      isFavorite: false,
      filesCount: 0,
      totalSize: 0,
    );

    // Write app.js
    await _writeWebAppFiles(app, appPath);

    // Store in memory cache
    _webApps[id] = app;

    stderr.writeln('Web app created successfully: ${app.title}');

    // Notify listeners
    appsNotifier.value++;

    return app;
  }

  /// Write app files to web virtual file system
  Future<void> _writeWebAppFiles(App app, String folderPath) async {
    final fs = FileSystemService.instance;

    // Generate app.js content
    final appJs = '''window.APP_DATA = ${json.encode({
      'app': {
        'id': app.id,
        'title': app.title,
        'description': app.description,
        'type': app.type,
        'updated': app.updated,
      },
      'cachedStats': {
        'fileCount': app.filesCount,
        'totalSize': app.totalSize,
        'lastScanned': DateTime.now().toIso8601String(),
      },
    }, toEncodable: (o) => o.toString())};''';

    await fs.writeAsString('$folderPath/app.js', appJs);

    // Write empty tree.json
    await fs.writeAsString('$folderPath/extra/tree.json', '[]');

    // Write security.json with defaults
    final securityJson = json.encode({
      'visibility': app.visibility,
      'encryption': app.encryption,
      'allowedReaders': app.allowedReaders,
    });
    await fs.writeAsString('$folderPath/extra/security.json', securityJson);
  }

  /// Create skeleton template files based on app type
  Future<void> _createSkeletonFiles(String type, Directory appFolder) async {
    try {
      if (type == 'www') {
        // Create default index.html for website type
        final indexFile = File('${appFolder.path}/index.html');
        final indexContent = '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 50px auto;
            padding: 20px;
            line-height: 1.6;
        }
        h1 {
            color: #333;
        }
        p {
            color: #666;
        }
    </style>
</head>
<body>
    <h1>Welcome to Your Website</h1>
    <p>This is the default homepage. Edit this file to create your website.</p>
    <p>You can add more HTML files, CSS stylesheets, JavaScript files, and images to build your site.</p>
</body>
</html>
''';
        await indexFile.writeAsString(indexContent);
        stderr.writeln('Created skeleton index.html for www type');
      } else if (type == 'chat') {
        // Initialize chat app structure
        await _initializeChatApp(appFolder);
        stderr.writeln('Created chat app skeleton');
      } else if (type == 'forum') {
        // Initialize forum app structure
        await _initializeForumApp(appFolder);
        stderr.writeln('Created forum app skeleton');
      } else if (type == 'postcards') {
        // Initialize postcards app structure
        await _initializePostcardsApp(appFolder);
        stderr.writeln('Created postcards app skeleton');
      } else if (type == 'contacts') {
        // Initialize contacts app structure
        await _initializeContactsApp(appFolder);
        stderr.writeln('Created contacts app skeleton');
      } else if (type == 'places') {
        // Initialize places app structure
        await _initializePlacesApp(appFolder);
        stderr.writeln('Created places app skeleton');
      } else if (type == 'groups') {
        // Initialize groups app structure
        await _initializeGroupsApp(appFolder);
        stderr.writeln('Created groups app skeleton');
      } else if (type == 'station') {
        // Initialize station app structure
        await _initializeRelayApp(appFolder);
        stderr.writeln('Created station app skeleton');
      } else if (type == 'console') {
        // Initialize console app structure
        await _initializeConsoleApp(appFolder);
        stderr.writeln('Created console app skeleton');
      } else if (type == 'qr') {
        // Initialize QR codes app structure
        await _initializeQrApp(appFolder);
        stderr.writeln('Created qr app skeleton');
      } else if (type == 'teleport') {
        // Initialize teleport app structure
        await _initializeTeleportApp(appFolder);
        stderr.writeln('Created teleport app skeleton');
      }
      // Add more skeleton templates for other types here
    } catch (e) {
      stderr.writeln('Error creating skeleton files: $e');
      // Don't fail app creation if skeleton creation fails
    }
  }

  /// Create skeleton template files using storage abstraction
  Future<void> _createSkeletonFilesWithStorage(String type, String folderName) async {
    if (_profileStorage == null) return;

    try {
      if (type == 'www') {
        // Create default index.html for website type
        final indexContent = '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 50px auto;
            padding: 20px;
            line-height: 1.6;
        }
        h1 {
            color: #333;
        }
        p {
            color: #666;
        }
    </style>
</head>
<body>
    <h1>Welcome to Your Website</h1>
    <p>This is the default homepage. Edit this file to create your website.</p>
    <p>You can add more HTML files, CSS stylesheets, JavaScript files, and images to build your site.</p>
</body>
</html>
''';
        await _profileStorage!.writeString('$folderName/index.html', indexContent);
        stderr.writeln('Created skeleton index.html for www type');
      } else if (type == 'chat') {
        await _initializeChatAppWithStorage(folderName);
        stderr.writeln('Created chat app skeleton');
      } else if (type == 'forum') {
        await _initializeForumAppWithStorage(folderName);
        stderr.writeln('Created forum app skeleton');
      } else if (type == 'postcards') {
        await _initializePostcardsAppWithStorage(folderName);
        stderr.writeln('Created postcards app skeleton');
      } else if (type == 'contacts') {
        await _initializeContactsAppWithStorage(folderName);
        stderr.writeln('Created contacts app skeleton');
      } else if (type == 'places') {
        await _initializePlacesAppWithStorage(folderName);
        stderr.writeln('Created places app skeleton');
      } else if (type == 'groups') {
        await _initializeGroupsAppWithStorage(folderName);
        stderr.writeln('Created groups app skeleton');
      } else if (type == 'station') {
        await _initializeRelayAppWithStorage(folderName);
        stderr.writeln('Created station app skeleton');
      } else if (type == 'console') {
        await _initializeConsoleAppWithStorage(folderName);
        stderr.writeln('Created console app skeleton');
      } else if (type == 'qr') {
        await _initializeQrAppWithStorage(folderName);
        stderr.writeln('Created qr app skeleton');
      } else if (type == 'teleport') {
        await _initializeTeleportAppWithStorage(folderName);
        stderr.writeln('Created teleport app skeleton');
      }
    } catch (e) {
      stderr.writeln('Error creating skeleton files: $e');
    }
  }

  /// Auto-create app.js for a chat folder created by CLI
  /// This allows the desktop to recognize chat apps created via CLI
  Future<void> _autoCreateChatApp(Directory folder) async {
    try {
      // Generate a app ID
      final keys = NostrKeyGenerator.generateKeyPair();
      final id = keys.npub;

      // Store keys in config
      _configService.storeAppKeys(keys);

      // Ensure extra directory exists
      final extraDir = Directory('${folder.path}/extra');
      if (!await extraDir.exists()) {
        await extraDir.create(recursive: true);
      }

      // Create app object
      final app = App(
        id: id,
        title: 'Chat',
        description: 'Chat messages',
        type: 'chat',
        updated: DateTime.now().toIso8601String(),
        storagePath: folder.path,
        isOwned: true,
        isFavorite: false,
        filesCount: 0,
        totalSize: 0,
      );

      // Write app.js
      final appJsFile = File('${folder.path}/app.js');
      await appJsFile.writeAsString(app.generateAppJs());

      // Write security.json if it doesn't exist
      final securityFile = File('${folder.path}/extra/security.json');
      if (!await securityFile.exists()) {
        await securityFile.writeAsString(app.generateSecurityJson());
      }

      stderr.writeln('Auto-created chat app: ${folder.path}');
    } catch (e) {
      stderr.writeln('Error auto-creating chat app: $e');
    }
  }

  /// Initialize chat app with main channel and metadata files
  Future<void> _initializeChatApp(Directory appFolder) async {
    // Create main channel folder
    final mainDir = Directory('${appFolder.path}/main');
    await mainDir.create();

    // Create main channel year folder
    final year = DateTime.now().year;
    final yearDir = Directory('${mainDir.path}/$year');
    await yearDir.create();

    // Create files subfolder in year directory
    final filesDir = Directory('${yearDir.path}/files');
    await filesDir.create();

    // Create files folder in main directory (for non-dated files)
    final mainFilesDir = Directory('${mainDir.path}/files');
    await mainFilesDir.create();

    // Create main channel config.json
    final mainConfig = ChatChannelConfig.defaults(
      id: 'main',
      name: 'Main Chat',
      description: 'Public group chat for everyone',
    );
    final configFile = File('${mainDir.path}/config.json');
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(mainConfig.toJson()),
    );

    // Create channels.json in extra/
    final channelsFile = File('${appFolder.path}/extra/channels.json');
    final channelsData = {
      'version': '1.0',
      'channels': [
        {
          'id': 'main',
          'type': 'group',
          'name': 'Main Chat',
          'folder': 'main',
          'participants': ['*'],
          'created': DateTime.now().toIso8601String(),
        }
      ]
    };
    await channelsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(channelsData),
    );

    // Create participants.json in extra/
    final participantsFile =
        File('${appFolder.path}/extra/participants.json');
    final participantsData = {
      'version': '1.0',
      'participants': {},
    };
    await participantsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(participantsData),
    );

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityFile = File('${appFolder.path}/extra/security.json');
    final security = ChatSecurity(
      adminNpub: currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
    );
    final securityData = {
      'version': '1.0',
      ...security.toJson(),
    };
    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(securityData),
    );

    // Create settings.json with signing enabled by default
    final settingsFile = File('${appFolder.path}/extra/settings.json');
    final settings = ChatSettings(signMessages: true);
    await settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );

    stderr.writeln('Chat app initialized with main channel');
    if (currentProfile.npub.isNotEmpty) {
      stderr.writeln('Set ${currentProfile.callsign} (${currentProfile.npub}) as admin');
    }
  }

  /// Initialize forum app with default sections and metadata files
  Future<void> _initializeForumApp(Directory appFolder) async {
    // Define default sections
    final defaultSections = [
      {
        'id': 'announcements',
        'name': 'Announcements',
        'folder': 'announcements',
        'description': 'Important announcements and updates',
        'order': 1,
        'readonly': false,
      },
      {
        'id': 'general',
        'name': 'General Discussion',
        'folder': 'general',
        'description': 'General topics and discussions',
        'order': 2,
        'readonly': false,
      },
      {
        'id': 'help',
        'name': 'Help & Support',
        'folder': 'help',
        'description': 'Get help and support from the community',
        'order': 3,
        'readonly': false,
      },
    ];

    // Create section folders and config files
    for (var sectionData in defaultSections) {
      final sectionDir = Directory('${appFolder.path}/${sectionData['folder']}');
      await sectionDir.create();

      // Create section config.json with default settings
      final config = ForumSectionConfig.defaults(
        id: sectionData['id'] as String,
        name: sectionData['name'] as String,
        description: sectionData['description'] as String?,
      );

      final configFile = File('${sectionDir.path}/config.json');
      await configFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(config.toJson()),
      );
    }

    // Create sections.json in extra/
    final sectionsFile = File('${appFolder.path}/extra/sections.json');
    final sectionsData = {
      'version': '1.0',
      'sections': defaultSections,
    };
    await sectionsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(sectionsData),
    );

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityFile = File('${appFolder.path}/extra/security.json');
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(securityData),
    );

    // Create settings.json with signing enabled by default
    final settingsFile = File('${appFolder.path}/extra/settings.json');
    final settingsData = {
      'version': '1.0',
      'signMessages': true,
      'requireSignatures': false,
    };
    await settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settingsData),
    );

    stderr.writeln('Forum app initialized with ${defaultSections.length} sections');
    if (currentProfile.npub.isNotEmpty) {
      stderr.writeln('Set ${currentProfile.callsign} (${currentProfile.npub}) as admin');
    }
  }

  /// Initialize postcards app with directory structure
  Future<void> _initializePostcardsApp(Directory appFolder) async {
    // Create postcards directory
    final postcardsDir = Directory('${appFolder.path}/postcards');
    await postcardsDir.create();

    // Create current year directory
    final year = DateTime.now().year;
    final yearDir = Directory('${postcardsDir.path}/$year');
    await yearDir.create();

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityFile = File('${appFolder.path}/extra/security.json');
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(securityData),
    );

    stderr.writeln('Postcards app initialized');
    if (currentProfile.npub.isNotEmpty) {
      stderr.writeln('Set ${currentProfile.callsign} (${currentProfile.npub}) as admin');
    }
  }

  /// Initialize contacts app with directory structure
  Future<void> _initializeContactsApp(Directory appFolder) async {
    // Create media directory for profile pictures
    final mediaDir = Directory('${appFolder.path}/media');
    await mediaDir.create();

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityFile = File('${appFolder.path}/extra/security.json');
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(securityData),
    );

    stderr.writeln('Contacts app initialized');
    if (currentProfile.npub.isNotEmpty) {
      stderr.writeln('Set ${currentProfile.callsign} (${currentProfile.npub}) as admin');
    }
  }

  /// Initialize places app with directory structure
  Future<void> _initializePlacesApp(Directory appFolder) async {
    // Create places directory
    final placesDir = Directory('${appFolder.path}/places');
    await placesDir.create();

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityFile = File('${appFolder.path}/extra/security.json');
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(securityData),
    );

    stderr.writeln('Places app initialized');
    if (currentProfile.npub.isNotEmpty) {
      stderr.writeln('Set ${currentProfile.callsign} (${currentProfile.npub}) as admin');
    }
  }

  /// Initialize groups app with admins.txt and root configuration
  Future<void> _initializeGroupsApp(Directory appFolder) async {
    // Get current profile to set as app admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();

    // Create group.json at root
    final groupJsonFile = File('${appFolder.path}/group.json');
    final now = DateTime.now();
    final timestamp = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

    final groupData = {
      'app': {
        'id': 'unique-app-id',
        'title': 'Groups',
        'description': 'Community moderation and curation groups',
        'type': 'groups',
        'created': timestamp,
        'updated': timestamp,
      }
    };
    await groupJsonFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(groupData),
    );

    // Create admins.txt at root
    final adminsFile = File('${appFolder.path}/admins.txt');
    final adminsContent = '''# ADMINS: Groups App
# Created: $timestamp

${currentProfile.callsign}
--> npub: ${currentProfile.npub}
--> signature:
''';
    await adminsFile.writeAsString(adminsContent);

    stderr.writeln('Groups app initialized');
    if (currentProfile.npub.isNotEmpty) {
      stderr.writeln('Set ${currentProfile.callsign} (${currentProfile.npub}) as app admin');
    }
  }

  /// Initialize station app with basic structure
  /// Note: The actual station configuration is managed by StationNodeService
  Future<void> _initializeRelayApp(Directory appFolder) async {
    // Get current profile
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final now = DateTime.now();
    final timestamp = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

    // Create station.json at root (basic metadata - actual station config is separate)
    final stationJsonFile = File('${appFolder.path}/station.json');
    final stationData = {
      'app': {
        'id': 'station-app',
        'title': 'Station',
        'description': 'Configure this device as a station node',
        'type': 'station',
        'created': timestamp,
        'updated': timestamp,
      },
      'owner': {
        'callsign': currentProfile.callsign,
        'npub': currentProfile.npub,
      },
    };
    await stationJsonFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(stationData),
    );

    stderr.writeln('Station app initialized');
  }

  /// Initialize console app structure
  Future<void> _initializeConsoleApp(Directory appFolder) async {
    // Create sessions directory
    final sessionsDir = Directory('${appFolder.path}/sessions');
    await sessionsDir.create();

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityFile = File('${appFolder.path}/extra/security.json');
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(securityData),
    );

    stderr.writeln('Console app initialized');
  }

  // ============ Storage-based initialization methods ============

  /// Initialize chat app using storage abstraction
  Future<void> _initializeChatAppWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    final year = DateTime.now().year;

    // Create directory structure
    await _profileStorage!.createDirectory('$folderName/main');
    await _profileStorage!.createDirectory('$folderName/main/$year');
    await _profileStorage!.createDirectory('$folderName/main/$year/files');
    await _profileStorage!.createDirectory('$folderName/main/files');

    // Create main channel config.json
    final mainConfig = ChatChannelConfig.defaults(
      id: 'main',
      name: 'Main Chat',
      description: 'Public group chat for everyone',
    );
    await _profileStorage!.writeJson('$folderName/main/config.json', mainConfig.toJson());

    // Create channels.json in extra/
    final channelsData = {
      'version': '1.0',
      'channels': [
        {
          'id': 'main',
          'type': 'group',
          'name': 'Main Chat',
          'folder': 'main',
          'participants': ['*'],
          'created': DateTime.now().toIso8601String(),
        }
      ]
    };
    await _profileStorage!.writeJson('$folderName/extra/channels.json', channelsData);

    // Create participants.json in extra/
    final participantsData = {
      'version': '1.0',
      'participants': <String, dynamic>{},
    };
    await _profileStorage!.writeJson('$folderName/extra/participants.json', participantsData);

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final security = ChatSecurity(
      adminNpub: currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
    );
    final securityData = {
      'version': '1.0',
      ...security.toJson(),
    };
    await _profileStorage!.writeJson('$folderName/extra/security.json', securityData);

    // Create settings.json with signing enabled by default
    final settings = ChatSettings(signMessages: true);
    await _profileStorage!.writeJson('$folderName/extra/settings.json', settings.toJson());

    stderr.writeln('Chat app initialized with main channel');
  }

  /// Initialize forum app using storage abstraction
  Future<void> _initializeForumAppWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    final defaultSections = [
      {'id': 'announcements', 'name': 'Announcements', 'folder': 'announcements', 'description': 'Important announcements and updates', 'order': 1, 'readonly': false},
      {'id': 'general', 'name': 'General Discussion', 'folder': 'general', 'description': 'General discussions and community chat', 'order': 2, 'readonly': false},
      {'id': 'help', 'name': 'Help & Support', 'folder': 'help', 'description': 'Ask questions and get help', 'order': 3, 'readonly': false},
    ];

    // Create section directories and config files
    for (final section in defaultSections) {
      final sectionFolder = section['folder'] as String;
      await _profileStorage!.createDirectory('$folderName/$sectionFolder');
      await _profileStorage!.writeJson('$folderName/$sectionFolder/config.json', section);
    }

    // Create sections.json in extra/
    final sectionsData = {
      'version': '1.0',
      'sections': defaultSections,
    };
    await _profileStorage!.writeJson('$folderName/extra/sections.json', sectionsData);

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await _profileStorage!.writeJson('$folderName/extra/security.json', securityData);

    stderr.writeln('Forum app initialized');
  }

  /// Initialize postcards app using storage abstraction
  Future<void> _initializePostcardsAppWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    await _profileStorage!.createDirectory('$folderName/postcards');
    await _profileStorage!.createDirectory('$folderName/media');

    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await _profileStorage!.writeJson('$folderName/extra/security.json', securityData);

    stderr.writeln('Postcards app initialized');
  }

  /// Initialize contacts app using storage abstraction
  Future<void> _initializeContactsAppWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    // Create contacts.json
    final contactsData = {
      'version': '1.0',
      'contacts': <Map<String, dynamic>>[],
    };
    await _profileStorage!.writeJson('$folderName/contacts.json', contactsData);

    // Create security.json
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
    };
    await _profileStorage!.writeJson('$folderName/extra/security.json', securityData);

    stderr.writeln('Contacts app initialized');
  }

  /// Initialize places app using storage abstraction
  Future<void> _initializePlacesAppWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    // Create places.json
    final placesData = {
      'version': '1.0',
      'places': <Map<String, dynamic>>[],
    };
    await _profileStorage!.writeJson('$folderName/places.json', placesData);

    // Create security.json
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
    };
    await _profileStorage!.writeJson('$folderName/extra/security.json', securityData);

    stderr.writeln('Places app initialized');
  }

  /// Initialize groups app using storage abstraction
  Future<void> _initializeGroupsAppWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    // Create groups.json
    final groupsData = {
      'version': '1.0',
      'groups': <Map<String, dynamic>>[],
    };
    await _profileStorage!.writeJson('$folderName/groups.json', groupsData);

    // Create security.json
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
    };
    await _profileStorage!.writeJson('$folderName/extra/security.json', securityData);

    stderr.writeln('Groups app initialized');
  }

  /// Initialize station/relay app using storage abstraction
  Future<void> _initializeRelayAppWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    // Create config.json
    final configData = {
      'version': '1.0',
      'enabled': false,
      'port': 8080,
    };
    await _profileStorage!.writeJson('$folderName/config.json', configData);

    // Create security.json
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
    };
    await _profileStorage!.writeJson('$folderName/extra/security.json', securityData);

    stderr.writeln('Station app initialized');
  }

  /// Initialize console app using storage abstraction
  Future<void> _initializeConsoleAppWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    await _profileStorage!.createDirectory('$folderName/sessions');

    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await _profileStorage!.writeJson('$folderName/extra/security.json', securityData);

    stderr.writeln('Console app initialized');
  }

  /// Initialize QR codes app structure
  Future<void> _initializeQrApp(Directory appFolder) async {
    // Create created and scanned directories
    await Directory('${appFolder.path}/created').create();
    await Directory('${appFolder.path}/scanned').create();

    stderr.writeln('QR app initialized');
  }

  /// Initialize QR codes app using storage abstraction
  Future<void> _initializeQrAppWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    // Create created and scanned directories
    await _profileStorage!.createDirectory('$folderName/created');
    await _profileStorage!.createDirectory('$folderName/scanned');

    stderr.writeln('QR app initialized');
  }

  /// Initialize teleport app structure
  Future<void> _initializeTeleportApp(Directory appFolder) async {
    await Directory('${appFolder.path}/bridges').create();
    await Directory('${appFolder.path}/media').create();

    final configFile = File('${appFolder.path}/config.json');
    final configData = {
      'version': '1.0',
      'bridges': <Map<String, dynamic>>[],
      'updated_at': DateTime.now().toIso8601String(),
    };
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(configData),
    );

    stderr.writeln('Teleport app initialized');
  }

  /// Initialize teleport app using storage abstraction
  Future<void> _initializeTeleportAppWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    await _profileStorage!.createDirectory('$folderName/bridges');
    await _profileStorage!.createDirectory('$folderName/media');

    final configData = {
      'version': '1.0',
      'bridges': <Map<String, dynamic>>[],
      'updated_at': DateTime.now().toIso8601String(),
    };
    await _profileStorage!.writeJson('$folderName/config.json', configData);

    stderr.writeln('Teleport app initialized');
  }

  /// Generate and save tree.json using storage abstraction
  Future<void> _generateAndSaveTreeJsonWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    // For new apps, just create an empty tree
    final treeData = {
      'version': '1.0',
      'generated': DateTime.now().toIso8601String(),
      'files': <Map<String, dynamic>>[],
    };
    await _profileStorage!.writeJson('$folderName/tree.json', treeData);
  }

  /// Generate and save data.js using storage abstraction
  Future<void> _generateAndSaveDataJsWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    // For new apps, create minimal data.js
    final dataJs = '''const appData = {
  version: "1.0",
  generated: "${DateTime.now().toIso8601String()}",
  files: []
};
''';
    await _profileStorage!.writeString('$folderName/data.js', dataJs);
  }

  /// Generate and save index.html using storage abstraction
  Future<void> _generateAndSaveIndexHtmlWithStorage(String folderName) async {
    if (_profileStorage == null) return;

    final indexHtml = '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>App</title>
</head>
<body>
    <h1>App Files</h1>
    <p>No files yet.</p>
</body>
</html>
''';
    await _profileStorage!.writeString('$folderName/index.html', indexHtml);
  }

  /// Write app metadata files to disk
  Future<void> _writeAppFiles(
    App app,
    Directory folder,
  ) async {
    // Write app.js
    final appJsFile = File('${folder.path}/app.js');
    await appJsFile.writeAsString(app.generateAppJs());

    // Write extra/security.json
    final securityJsonFile = File('${folder.path}/extra/security.json');
    await securityJsonFile.writeAsString(app.generateSecurityJson());

    // Only generate tree.json, data.js, and index.html for files and www types
    // Other types (groups, chat, forum, etc.) have their own structure
    if (app.type == 'shared' || app.type == 'www') {
      // Generate and write tree.json, data.js, and index.html
      // For new apps, generate synchronously so app is fully ready
      stderr.writeln('Generating tree.json, data.js, and index.html...');
      await _generateAndSaveTreeJson(folder);
      await _generateAndSaveDataJs(folder);
      await _generateAndSaveIndexHtml(folder);
      stderr.writeln('App files generated successfully');
    } else {
      stderr.writeln('Skipping tree.json/data.js/index.html generation for ${app.type} type');
    }
  }

  /// Write app metadata files using storage abstraction
  Future<void> _writeAppFilesWithStorage(
    App app,
    String folderName,
  ) async {
    if (_profileStorage == null) return;

    // Write app.js
    await _profileStorage!.writeString(
      '$folderName/app.js',
      app.generateAppJs(),
    );

    // Write extra/security.json
    await _profileStorage!.writeString(
      '$folderName/extra/security.json',
      app.generateSecurityJson(),
    );

    // Only generate tree.json, data.js, and index.html for files and www types
    if (app.type == 'shared' || app.type == 'www') {
      stderr.writeln('Generating tree.json, data.js, and index.html...');
      await _generateAndSaveTreeJsonWithStorage(folderName);
      await _generateAndSaveDataJsWithStorage(folderName);
      await _generateAndSaveIndexHtmlWithStorage(folderName);
      stderr.writeln('App files generated successfully');
    } else {
      stderr.writeln('Skipping tree.json/data.js/index.html generation for ${app.type} type');
    }
  }

  /// Delete an app
  Future<void> deleteApp(App app) async {
    if (app.storagePath == null) {
      throw Exception('App has no storage path');
    }

    // Use storage abstraction if available
    if (_profileStorage != null) {
      // Get relative path from storage path
      final basePath = _profileStorage!.basePath;
      final storagePath = app.storagePath!;
      String relativePath;

      if (storagePath.startsWith(basePath)) {
        relativePath = storagePath.substring(basePath.length);
        if (relativePath.startsWith('/')) {
          relativePath = relativePath.substring(1);
        }
      } else {
        // Path is outside profile storage, use direct filesystem
        final folder = Directory(storagePath);
        if (await folder.exists()) {
          await folder.delete(recursive: true);
        }
        if (app.isFavorite) {
          _configService.toggleFavorite(app.id);
        }
        return;
      }

      if (relativePath.isNotEmpty) {
        await _profileStorage!.deleteDirectory(relativePath, recursive: true);
      }
    } else {
      // Fall back to direct filesystem
      final folder = Directory(app.storagePath!);
      if (await folder.exists()) {
        await folder.delete(recursive: true);
      }
    }

    // Remove from favorites if present
    if (app.isFavorite) {
      _configService.toggleFavorite(app.id);
    }
  }

  /// Toggle favorite status of an app
  void toggleFavorite(App app) {
    _configService.toggleFavorite(app.id);
    app.isFavorite = !app.isFavorite;
  }

  /// Load security settings from security.json
  Future<void> _loadSecuritySettings(App app, Directory folder) async {
    try {
      final securityFile = File('${folder.path}/extra/security.json');
      if (await securityFile.exists()) {
        final content = await securityFile.readAsString();
        final data = json.decode(content) as Map<String, dynamic>;
        app.visibility = data['visibility'] as String? ?? 'public';
        app.allowedReaders = (data['allowedReaders'] as List<dynamic>?)?.cast<String>() ?? [];
        app.encryption = data['encryption'] as String? ?? 'none';
      }
    } catch (e) {
      stderr.writeln('Error loading security settings: $e');
    }
  }

  /// Update app metadata
  Future<void> updateApp(App app, {String? oldTitle}) async {
    if (app.storagePath == null) {
      throw Exception('App has no storage path');
    }

    // Update timestamp
    app.updated = DateTime.now().toIso8601String();

    // Use storage abstraction if available
    if (_profileStorage != null) {
      final basePath = _profileStorage!.basePath;
      final storagePath = app.storagePath!;
      String? relativePath;

      if (storagePath.startsWith(basePath)) {
        relativePath = storagePath.substring(basePath.length);
        if (relativePath.startsWith('/')) {
          relativePath = relativePath.substring(1);
        }
      }

      if (relativePath != null && relativePath.isNotEmpty) {
        // Check if folder exists in storage
        if (!await _profileStorage!.directoryExists(relativePath)) {
          throw Exception('App folder does not exist');
        }

        // Note: folder renaming is not supported for encrypted storage
        // Title changes only update metadata, not folder name
        if (oldTitle != null && oldTitle != app.title && !_useEncryptedStorage) {
          await _renameAppFolder(app, oldTitle);
          // Update relativePath after rename
          final newStoragePath = app.storagePath!;
          if (newStoragePath.startsWith(basePath)) {
            relativePath = newStoragePath.substring(basePath.length);
            if (relativePath.startsWith('/')) {
              relativePath = relativePath.substring(1);
            }
          }
        }

        // Write updated metadata files
        await _writeAppFilesWithStorage(app, relativePath);
        stderr.writeln('Updated app: ${app.title}');
        return;
      }
    }

    // Fall back to direct filesystem operations
    final folder = Directory(app.storagePath!);
    if (!await folder.exists()) {
      throw Exception('App folder does not exist');
    }

    // If title changed, rename the folder
    if (oldTitle != null && oldTitle != app.title) {
      await _renameAppFolder(app, oldTitle);
    }

    // Write updated metadata files
    final updatedFolder = Directory(app.storagePath!);
    await _writeAppFiles(app, updatedFolder);

    stderr.writeln('Updated app: ${app.title}');
  }

  /// Rename app folder based on new title
  Future<void> _renameAppFolder(App app, String oldTitle) async {
    final oldFolder = Directory(app.storagePath!);
    if (!await oldFolder.exists()) {
      throw Exception('App folder does not exist');
    }

    // Get parent directory
    final parentPath = oldFolder.parent.path;

    // Sanitize new folder name from title
    String newFolderName = _sanitizeFolderName(app.title);

    // Find unique folder name if needed
    var newFolder = Directory('$parentPath/$newFolderName');
    int counter = 1;
    while (await newFolder.exists() && newFolder.path != oldFolder.path) {
      newFolder = Directory('$parentPath/${newFolderName}_$counter');
      counter++;
    }

    // Skip if same path (case-insensitive filesystem might cause issues)
    if (newFolder.path == oldFolder.path) {
      stderr.writeln('Folder path unchanged: ${newFolder.path}');
      return;
    }

    stderr.writeln('Renaming folder: ${oldFolder.path} -> ${newFolder.path}');

    // Rename the folder
    try {
      await oldFolder.rename(newFolder.path);
      app.storagePath = newFolder.path;
      stderr.writeln('Folder renamed successfully');
    } catch (e) {
      stderr.writeln('Error renaming folder: $e');
      throw Exception('Failed to rename app directory: $e');
    }
  }

  /// Sanitize folder name (remove invalid characters, replace spaces)
  String _sanitizeFolderName(String title) {
    // Replace spaces with underscores
    String folderName = title.replaceAll(' ', '_');

    // Remove/replace invalid characters for Windows and Linux
    // Invalid: \ / : * ? " < > | and control characters
    folderName = folderName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    // Remove control characters (ASCII 0-31 and 127)
    folderName = folderName.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');

    // Convert to lowercase
    folderName = folderName.toLowerCase();

    // Truncate to 50 characters
    if (folderName.length > 50) {
      folderName = folderName.substring(0, 50);
    }

    // Remove trailing underscores or dots (dots can cause issues on Windows)
    folderName = folderName.replaceAll(RegExp(r'[_.]+$'), '');

    // Ensure folder name is not empty
    if (folderName.isEmpty) {
      folderName = 'collection';
    }

    return folderName;
  }

  /// Add files to an app (copy operation)
  Future<void> addFiles(App app, List<String> filePaths) async {
    if (app.storagePath == null) {
      throw Exception('App has no storage path');
    }

    final appDir = Directory(app.storagePath!);
    if (!await appDir.exists()) {
      throw Exception('App folder does not exist');
    }

    for (final filePath in filePaths) {
      final sourceFile = File(filePath);
      if (!await sourceFile.exists()) {
        stderr.writeln('Source file does not exist: $filePath');
        continue;
      }

      final fileName = filePath.split('/').last;
      final destFile = File('${appDir.path}/$fileName');

      // Copy file
      await sourceFile.copy(destFile.path);
      stderr.writeln('Copied file: $fileName');
    }

    // Recount files and update metadata
    await _countAppFiles(app, appDir);

    // Regenerate tree.json, data.js, and index.html
    await _generateAndSaveTreeJson(appDir);
    await _generateAndSaveDataJs(appDir);
    await _generateAndSaveIndexHtml(appDir);

    await updateApp(app);
  }

  /// Create a new empty folder in the app
  Future<void> createFolder(App app, String folderName) async {
    if (app.storagePath == null) {
      throw Exception('App has no storage path');
    }

    final appDir = Directory(app.storagePath!);
    if (!await appDir.exists()) {
      throw Exception('App folder does not exist');
    }

    // Sanitize folder name
    final sanitized = folderName
        .trim()
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');

    if (sanitized.isEmpty) {
      throw Exception('Invalid folder name');
    }

    final newFolder = Directory('${appDir.path}/$sanitized');

    if (await newFolder.exists()) {
      throw Exception('Folder already exists');
    }

    await newFolder.create(recursive: false);
    stderr.writeln('Created folder: $sanitized');

    // Regenerate tree.json, data.js, and index.html
    await _generateAndSaveTreeJson(appDir);
    await _generateAndSaveDataJs(appDir);
    await _generateAndSaveIndexHtml(appDir);

    // Update metadata
    await updateApp(app);
  }

  /// Add a folder to an app (recursive copy)
  Future<void> addFolder(App app, String folderPath) async {
    if (app.storagePath == null) {
      throw Exception('App has no storage path');
    }

    final appDir = Directory(app.storagePath!);
    if (!await appDir.exists()) {
      throw Exception('App folder does not exist');
    }

    final sourceDir = Directory(folderPath);
    if (!await sourceDir.exists()) {
      throw Exception('Source folder does not exist: $folderPath');
    }

    final folderName = folderPath.split('/').last;
    final destDir = Directory('${appDir.path}/$folderName');

    // Copy folder recursively
    await _copyDirectory(sourceDir, destDir);
    stderr.writeln('Copied folder: $folderName');

    // Recount files and update metadata
    await _countAppFiles(app, appDir);

    // Regenerate tree.json, data.js, and index.html
    await _generateAndSaveTreeJson(appDir);
    await _generateAndSaveDataJs(appDir);
    await _generateAndSaveIndexHtml(appDir);

    await updateApp(app);
  }

  /// Recursively copy a directory
  Future<void> _copyDirectory(Directory source, Directory dest) async {
    if (!await dest.exists()) {
      await dest.create(recursive: true);
    }

    final entities = await source.list(recursive: false).toList();
    for (final entity in entities) {
      if (entity is File) {
        final newPath = '${dest.path}/${entity.path.split('/').last}';
        await entity.copy(newPath);
      } else if (entity is Directory) {
        final dirName = entity.path.split('/').last;
        final newDir = Directory('${dest.path}/$dirName');
        await _copyDirectory(entity, newDir);
      }
    }
  }

  /// Build file tree from app directory
  Future<List<FileNode>> _buildFileTree(Directory appDir) async {
    final fileNodes = <FileNode>[];

    try {
      final entities = await appDir.list(recursive: false).toList();
      for (final entity in entities) {
        final name = entity.path.split('/').last;

        // Skip metadata folders and files
        if (name == 'extra' || name == 'app.js') {
          continue;
        }

        if (entity is File) {
          final stat = await entity.stat();
          fileNodes.add(FileNode(
            path: name,
            name: name,
            size: stat.size,
            isDirectory: false,
          ));
        } else if (entity is Directory) {
          final children = await _buildFileTreeRecursive(entity, name);
          int totalSize = 0;
          int fileCount = 0;
          for (var child in children) {
            totalSize += child.size;
            if (child.isDirectory) {
              fileCount += child.fileCount;
            } else {
              fileCount += 1;
            }
          }
          fileNodes.add(FileNode(
            path: name,
            name: name,
            size: totalSize,
            isDirectory: true,
            children: children,
            fileCount: fileCount,
          ));
        }
      }
    } catch (e) {
      stderr.writeln('Error building file tree: $e');
    }

    // Sort: directories first, then files, both alphabetically
    fileNodes.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return fileNodes;
  }

  /// Build file tree recursively
  Future<List<FileNode>> _buildFileTreeRecursive(Directory dir, String basePath) async {
    final fileNodes = <FileNode>[];

    try {
      final entities = await dir.list(recursive: false).toList();
      for (final entity in entities) {
        final name = entity.path.split('/').last;
        final relativePath = '$basePath/$name';

        if (entity is File) {
          final stat = await entity.stat();
          fileNodes.add(FileNode(
            path: relativePath,
            name: name,
            size: stat.size,
            isDirectory: false,
          ));
        } else if (entity is Directory) {
          final children = await _buildFileTreeRecursive(entity, relativePath);
          int totalSize = 0;
          int fileCount = 0;
          for (var child in children) {
            totalSize += child.size;
            if (child.isDirectory) {
              fileCount += child.fileCount;
            } else {
              fileCount += 1;
            }
          }
          fileNodes.add(FileNode(
            path: relativePath,
            name: name,
            size: totalSize,
            isDirectory: true,
            children: children,
            fileCount: fileCount,
          ));
        }
      }
    } catch (e) {
      stderr.writeln('Error building file tree recursively: $e');
    }

    // Sort: directories first, then files, both alphabetically
    fileNodes.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return fileNodes;
  }

  /// Load file tree from app
  Future<List<FileNode>> loadFileTree(App app) async {
    if (app.storagePath == null) {
      throw Exception('App has no storage path');
    }

    final appDir = Directory(app.storagePath!);
    return await _buildFileTree(appDir);
  }

  /// Scan directory non-recursively to avoid "too many open files"
  /// This processes directories one level at a time with proper cleanup
  Future<List<FileSystemEntity>> _scanDirectoryNonRecursive(Directory root) async {
    final allEntities = <FileSystemEntity>[];
    final dirsToProcess = <Directory>[root];

    while (dirsToProcess.isNotEmpty) {
      final currentDir = dirsToProcess.removeAt(0);

      try {
        // Process one directory at a time, immediately converting to list to close stream
        final entities = await currentDir.list(recursive: false, followLinks: false).toList();

        for (var entity in entities) {
          // Skip if it's the root directory itself
          if (entity.path == root.path) continue;

          allEntities.add(entity);

          // If it's a directory, add to queue for processing
          if (entity is Directory) {
            dirsToProcess.add(entity);
          }
        }
      } catch (e) {
        stderr.writeln('Error scanning directory ${currentDir.path}: $e');
      }
    }

    return allEntities;
  }

  /// Generate and save tree.json with proper nested structure
  Future<void> _generateAndSaveTreeJson(Directory folder) async {
    try {
      // Check if this is a www type app to determine if index.html should be included
      bool isWwwType = false;
      final appJsFile = File('${folder.path}/app.js');
      if (await appJsFile.exists()) {
        final content = await appJsFile.readAsString();
        isWwwType = content.contains('"type": "www"');
      }

      // Build nested tree structure recursively
      final entries = await _buildTreeJsonRecursive(folder, folder.path, isWwwType);

      // Write to tree.json
      final treeJsonFile = File('${folder.path}/extra/tree.json');
      final jsonContent = JsonEncoder.withIndent('  ').convert(entries);
      await treeJsonFile.writeAsString(jsonContent);

      // Count total files for logging
      int fileCount = 0;
      void countFiles(List<Map<String, dynamic>> items) {
        for (var item in items) {
          if (item['type'] == 'file') {
            fileCount++;
          } else if (item['children'] != null) {
            countFiles(item['children'] as List<Map<String, dynamic>>);
          }
        }
      }
      countFiles(entries);

      stderr.writeln('Generated tree.json with $fileCount files');
    } catch (e) {
      stderr.writeln('Error generating tree.json: $e');
      rethrow;
    }
  }

  /// Build nested tree structure recursively for tree.json
  Future<List<Map<String, dynamic>>> _buildTreeJsonRecursive(
    Directory dir,
    String rootPath,
    bool isWwwType,
  ) async {
    final entries = <Map<String, dynamic>>[];

    try {
      final entities = await dir.list(recursive: false, followLinks: false).toList();

      for (var entity in entities) {
        final name = entity.path.split('/').last;

        // Skip hidden files, metadata files, and the extra directory
        if (name.startsWith('.') ||
            name == 'app.js' ||
            (!isWwwType && name == 'index.html') ||
            name == 'extra') {
          continue;
        }

        if (entity is Directory) {
          // Recursively build children
          final children = await _buildTreeJsonRecursive(entity, rootPath, isWwwType);

          // Calculate total size of directory
          int totalSize = 0;
          void sumSize(List<Map<String, dynamic>> items) {
            for (var item in items) {
              if (item['type'] == 'file') {
                totalSize += (item['size'] as int?) ?? 0;
              } else if (item['children'] != null) {
                sumSize(item['children'] as List<Map<String, dynamic>>);
              }
            }
          }
          sumSize(children);

          entries.add({
            'name': name,
            'type': 'directory',
            'size': totalSize,
            'children': children,
          });
        } else if (entity is File) {
          final stat = await entity.stat();
          entries.add({
            'name': name,
            'type': 'file',
            'size': stat.size,
          });
        }
      }

      // Sort: directories first, then alphabetically
      entries.sort((a, b) {
        if (a['type'] == 'directory' && b['type'] != 'directory') return -1;
        if (a['type'] != 'directory' && b['type'] == 'directory') return 1;
        return (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase());
      });
    } catch (e) {
      stderr.writeln('Error building tree for ${dir.path}: $e');
    }

    return entries;
  }

  /// Generate and save data.js with full metadata
  Future<void> _generateAndSaveDataJs(Directory folder) async {
    try {
      final entries = <Map<String, dynamic>>[];
      final filesToProcess = <File>[];
      final directoriesToAdd = <Map<String, dynamic>>[];

      // Check if this is a www type app to determine if index.html should be included
      bool isWwwType = false;
      final appJsFile = File('${folder.path}/app.js');
      if (await appJsFile.exists()) {
        final content = await appJsFile.readAsString();
        isWwwType = content.contains('"type": "www"');
      }

      // First pass: collect all entities without reading files
      // Use non-recursive scan to avoid "too many open files" error
      final entities = await _scanDirectoryNonRecursive(folder);

      for (var entity in entities) {
        final relativePath = entity.path.substring(folder.path.length + 1);

        // Skip hidden files, metadata files, and the extra directory
        // For www type apps, include index.html as it's content, not metadata
        if (relativePath.startsWith('.') ||
            relativePath == 'app.js' ||
            (!isWwwType && relativePath == 'index.html') ||
            relativePath == 'extra' ||
            relativePath.startsWith('extra/')) {
          continue;
        }

        if (entity is Directory) {
          directoriesToAdd.add({
            'path': relativePath,
            'name': entity.path.split('/').last,
            'type': 'directory',
          });
        } else if (entity is File) {
          filesToProcess.add(entity);
        }
      }

      // Add directories first
      entries.addAll(directoriesToAdd);

      // Process files in batches to avoid too many open file handles
      const batchSize = 20;
      for (var i = 0; i < filesToProcess.length; i += batchSize) {
        final end = (i + batchSize < filesToProcess.length) ? i + batchSize : filesToProcess.length;
        final batch = filesToProcess.sublist(i, end);

        for (var file in batch) {
          try {
            final relativePath = file.path.substring(folder.path.length + 1);
            final stat = await file.stat();

            // Read file with explicit error handling
            late List<int> bytes;
            try {
              bytes = await file.readAsBytes();
            } catch (e) {
              stderr.writeln('Warning: Could not read file $relativePath: $e');
              // Add entry without hashes if file can't be read
              entries.add({
                'path': relativePath,
                'name': file.path.split('/').last,
                'type': 'file',
                'size': stat.size,
                'mimeType': 'application/octet-stream',
                'hashes': {},
                'metadata': {
                  'mime_type': 'application/octet-stream',
                },
              });
              continue;
            }

            // Compute hashes
            final sha1Hash = sha1.convert(bytes).toString();
            final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
            final tlshHash = TLSH.hash(Uint8List.fromList(bytes));

            final hashes = <String, dynamic>{
              'sha1': sha1Hash,
            };
            if (tlshHash != null) {
              hashes['tlsh'] = tlshHash;
            }

            entries.add({
              'path': relativePath,
              'name': file.path.split('/').last,
              'type': 'file',
              'size': stat.size,
              'mimeType': mimeType,
              'hashes': hashes,
              'metadata': {
                'mime_type': mimeType,
              },
            });

            // Clear bytes from memory
            bytes = [];
          } catch (e) {
            stderr.writeln('Warning: Error processing file ${file.path}: $e');
          }
        }

        // Small delay between batches to allow OS to close file handles
        if (i + batchSize < filesToProcess.length) {
          await Future.delayed(Duration(milliseconds: 10));
        }
      }

      // Sort entries
      entries.sort((a, b) {
        if (a['type'] == 'directory' && b['type'] != 'directory') return -1;
        if (a['type'] != 'directory' && b['type'] == 'directory') return 1;
        return (a['path'] as String).compareTo(b['path'] as String);
      });

      // Write to data.js
      final dataJsFile = File('${folder.path}/extra/data.js');
      final now = DateTime.now().toIso8601String();
      final jsonData = JsonEncoder.withIndent('  ').convert(entries);
      final jsContent = '''// Geogram App Data with Metadata
// Generated: $now
window.APP_DATA_FULL = $jsonData;
''';
      await dataJsFile.writeAsString(jsContent);

      stderr.writeln('Generated data.js with ${entries.length} entries (${filesToProcess.length} files processed)');
    } catch (e) {
      stderr.writeln('Error generating data.js: $e');
      rethrow;
    }
  }

  /// Generate and save index.html for app browsing
  Future<void> _generateAndSaveIndexHtml(Directory folder) async {
    try {
      // Check if this is a www type app - if so, skip generating browser index.html
      final appJsFile = File('${folder.path}/app.js');
      if (await appJsFile.exists()) {
        final content = await appJsFile.readAsString();
        // Check if this is a www type app
        if (content.contains('"type": "www"')) {
          stderr.writeln('Skipping index.html generation for www type app');
          return; // Don't overwrite www type's custom index.html
        }
      }

      // Continue with normal index.html generation for other types
      final indexHtmlFile = File('${folder.path}/index.html');
      final htmlContent = _generateIndexHtmlContent();
      await indexHtmlFile.writeAsString(htmlContent);
      stderr.writeln('Generated index.html');
    } catch (e) {
      stderr.writeln('Error generating index.html: $e');
      rethrow;
    }
  }

  /// Generate HTML content for app browser
  String _generateIndexHtmlContent() {
    return '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>App Browser</title>
    <style>
        @font-face {
            font-family: 'VT323';
            font-style: normal;
            font-weight: 400;
            src: url(data:font/woff2;base64,d09GMgABAAAAABsMAA4AAAAAMkQAABqxAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGhYbIByCWgZgAIE8EQgKgbgkg5JXC4N0AAE2AiQDhwQGBQcgB4MbWCkjEZUcBWRfE+KW7Qwkg1bBVqxm/P/fxjZv3s/MJiGJZZVIopG0k0j1TNIgRBKhkUgiGglRySSRaFr/+b3u95zz3O85537P/c//P+f/nP/9z/mf/zv/+9//ufe///l3vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu8=) format('woff2');
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }


        @keyframes scanline {
            0% { transform: translateY(-100%); }
            100% { transform: translateY(100%); }
        }

        @keyframes flicker {
            0% { opacity: 0.97; }
            50% { opacity: 1; }
            100% { opacity: 0.97; }
        }

        @keyframes textGlow {
            0%, 100% { text-shadow: 0 0 10px #0f0, 0 0 20px #0f0, 0 0 30px #0f0; }
            50% { text-shadow: 0 0 15px #0f0, 0 0 25px #0f0, 0 0 35px #0f0; }
        }

        body {
            font-family: 'Courier New', 'VT323', monospace;
            background: #000;
            color: #0f0;
            line-height: 1.4;
            overflow-x: hidden;
            position: relative;
        }

        body::before {
            content: '';
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: repeating-linear-gradient(
                0deg,
                rgba(0, 0, 0, 0.15),
                rgba(0, 0, 0, 0.15) 1px,
                transparent 1px,
                transparent 2px
            );
            pointer-events: none;
            z-index: 1000;
            animation: flicker 0.15s infinite;
        }

        body::after {
            content: '';
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 3px;
            background: rgba(0, 255, 0, 0.1);
            animation: scanline 8s linear infinite;
            pointer-events: none;
            z-index: 999;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            position: relative;
            z-index: 1;
        }


        .header {
            border: 2px solid #0f0;
            padding: 15px;
            margin-bottom: 20px;
            box-shadow: 0 0 20px rgba(0, 255, 0, 0.3);
        }

        .header h1 {
            color: #0f0;
            font-size: 32px;
            margin-bottom: 10px;
            text-transform: uppercase;
            letter-spacing: 2px;
            font-weight: bold;
        }

        .header .subtitle {
            color: #0f0;
            font-size: 14px;
            margin-bottom: 5px;
        }

        .header .meta {
            color: #ff0;
            font-size: 12px;
        }

        .stats-box {
            border: 1px solid #0f0;
            padding: 10px;
            margin-bottom: 15px;
            background: rgba(0, 255, 0, 0.03);
        }

        .stats {
            display: flex;
            justify-content: space-between;
            flex-wrap: wrap;
            gap: 15px;
        }

        .stat {
            flex: 1;
            min-width: 200px;
            border: 1px dashed #0f0;
            padding: 10px;
            text-align: center;
        }

        .stat-label {
            color: #f0f;
            font-size: 11px;
            text-transform: uppercase;
            margin-bottom: 5px;
        }

        .stat-value {
            color: #0ff;
            font-size: 20px;
            text-shadow: 0 0 10px #0ff;
            font-weight: bold;
        }

        .search-box {
            border: 1px solid #0f0;
            padding: 10px;
            margin-bottom: 15px;
            background: rgba(0, 255, 0, 0.03);
        }

        .search-prompt {
            color: #ff0;
            margin-bottom: 5px;
        }

        .search-input {
            width: 100%;
            background: #000;
            border: 1px solid #0f0;
            color: #0f0;
            padding: 8px;
            font-family: 'Courier New', monospace;
            font-size: 14px;
            outline: none;
        }

        .search-input:focus {
            box-shadow: 0 0 10px rgba(0, 255, 0, 0.5);
        }


        .content {
            border: 2px solid #0f0;
            padding: 15px;
            min-height: 400px;
            background: rgba(0, 0, 0, 0.8);
            box-shadow: inset 0 0 20px rgba(0, 255, 0, 0.1);
        }

        .file-tree {
            list-style: none;
        }

        .file-tree ul {
            list-style: none;
        }

        .file-tree li {
            list-style: none;
        }

        .file-item {
            padding: 5px 0;
            cursor: pointer;
            transition: all 0.2s;
            position: relative;
            padding-left: 5px;
        }

        .file-item:hover {
            background: rgba(0, 255, 0, 0.1);
            padding-left: 10px;
        }

        .file-item:hover::before {
            content: '>';
            position: absolute;
            left: 0;
            color: #ff0;
        }

        .file-item.selected {
            background: rgba(255, 255, 0, 0.2);
            padding-left: 10px;
        }

        .file-item.selected::before {
            content: '►';
            position: absolute;
            left: 0;
            color: #ff0;
            font-weight: bold;
        }

        .file-item.directory {
            color: #0ff;
        }

        .result-item.selected {
            background: rgba(255, 255, 0, 0.2);
            padding-left: 15px;
        }

        .file-name {
            display: inline-block;
        }

        .file-size {
            color: #f0f;
            float: right;
            font-size: 12px;
        }

        .nested {
            padding-left: 20px;
            display: none;
        }

        .nested.open {
            display: block;
        }

        .expand-icon {
            display: inline-block;
            width: 15px;
            color: #ff0;
        }

        .result-item {
            padding: 10px;
            border-bottom: 1px dotted #0f0;
            cursor: pointer;
            transition: all 0.2s;
        }

        .result-item:hover {
            background: rgba(0, 255, 0, 0.1);
            padding-left: 15px;
        }

        .result-name {
            color: #0ff;
            margin-bottom: 5px;
            font-size: 14px;
        }

        .result-path {
            color: #ff0;
            font-size: 12px;
            margin-bottom: 3px;
        }

        .result-meta {
            color: #f0f;
            font-size: 11px;
        }

        .no-results {
            text-align: center;
            padding: 40px;
            color: #f00;
            border: 1px dashed #f00;
        }


        .footer {
            margin-top: 20px;
            border-top: 1px solid #0f0;
            padding-top: 10px;
            text-align: center;
            color: #0f0;
            font-size: 11px;
        }

        .footer a {
            color: #0ff;
            text-decoration: none;
        }

        .footer a:hover {
            text-decoration: underline;
            text-shadow: 0 0 10px #0ff;
        }

        @media (max-width: 768px) {
            .stat {
                min-width: 100%;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1><span id="app-title">LOADING SYSTEM...</span></h1>
            <div class="subtitle" id="app-description"></div>
            <div class="meta">LATEST UPDATE: <span id="app-meta"></span></div>
        </div>

        <div class="stats-box">
            <div class="stats">
                <div class="stat">
                    <div class="stat-label">▒ TOTAL FILES ▒</div>
                    <div class="stat-value" id="total-files">0</div>
                </div>
                <div class="stat">
                    <div class="stat-label">▒ DIRECTORIES ▒</div>
                    <div class="stat-value" id="total-folders">0</div>
                </div>
                <div class="stat">
                    <div class="stat-label">▒ TOTAL BYTES ▒</div>
                    <div class="stat-value" id="total-size">0 B</div>
                </div>
            </div>
        </div>

        <div class="search-box">
            <div class="search-prompt">SEARCH [?]:</div>
            <input type="text" class="search-input" id="search-input" placeholder="Type to search files...">
        </div>

        <div class="content">
            <div id="file-list"></div>
        </div>

        <div class="footer">
            ┌────────────────────────────────────────────────────────────────┐<br>
            │ GEOGRAM COLLECTION BROWSER v1.0 - OFFLINE-FIRST COMMUNICATION │<br>
            └────────────────────────────────────────────────────────────────┘
        </div>
    </div>

    <script src="app.js"></script>
    <script src="extra/data.js"></script>
    <script>
        const appData = window.APP_DATA?.app || {};
        const fileData = window.APP_DATA_FULL || [];
        let searchTimeout = null;
        let currentSearchQuery = '';
        let selectedIndex = 0;
        let navigableItems = [];
        let currentPath = [];

        // Initialize
        document.addEventListener('DOMContentLoaded', () => {
            loadAppInfo();
            setupSearch();
            setupKeyboardShortcuts();
            calculateStats();
            renderFileList();
            restoreState();
        });

        // Handle browser back/forward navigation
        window.addEventListener('popstate', (e) => {
            if (e.state && e.state.expandedPaths) {
                restoreStateFromData(e.state);
            }
        });

        function loadAppInfo() {
            const title = appData.title || 'App';
            document.getElementById('app-title').textContent = title;
            document.getElementById('app-description').textContent = appData.description || '';

            // Format date as YYYY-MM-DD HH:MM:SS
            const date = new Date(appData.updated);
            const year = date.getFullYear();
            const month = String(date.getMonth() + 1).padStart(2, '0');
            const day = String(date.getDate()).padStart(2, '0');
            const hours = String(date.getHours()).padStart(2, '0');
            const minutes = String(date.getMinutes()).padStart(2, '0');
            const seconds = String(date.getSeconds()).padStart(2, '0');
            const isoDateTime = \`\${year}-\${month}-\${day} \${hours}:\${minutes}:\${seconds}\`;

            document.getElementById('app-meta').textContent = isoDateTime;
            // Update browser tab title
            document.title = title;
        }

        function setupKeyboardShortcuts() {
            document.addEventListener('keydown', (e) => {
                const searchInput = document.getElementById('search-input');

                // If typing in search, don't handle navigation keys
                if (document.activeElement === searchInput && !['Escape', 'ArrowUp', 'ArrowDown', 'Enter'].includes(e.key)) {
                    return;
                }

                // ? - Focus search
                if (e.key === '?' && document.activeElement !== searchInput) {
                    e.preventDefault();
                    searchInput.focus();
                    searchInput.select();
                    return;
                }

                // ESC - Clear search and keep focus
                if (e.key === 'Escape' && document.activeElement === searchInput) {
                    e.preventDefault();
                    searchInput.value = '';
                    currentSearchQuery = '';
                    renderFileList();
                    return;
                }

                // Arrow Down - Move selection down
                if (e.key === 'ArrowDown') {
                    e.preventDefault();
                    if (navigableItems.length > 0) {
                        selectedIndex = (selectedIndex + 1) % navigableItems.length;
                        updateSelection();
                    }
                    return;
                }

                // Arrow Up - Move selection up
                if (e.key === 'ArrowUp') {
                    e.preventDefault();
                    if (navigableItems.length > 0) {
                        selectedIndex = (selectedIndex - 1 + navigableItems.length) % navigableItems.length;
                        updateSelection();
                    }
                    return;
                }

                // Enter - Open/expand selected item
                if (e.key === 'Enter') {
                    e.preventDefault();
                    if (navigableItems.length > 0 && navigableItems[selectedIndex]) {
                        navigableItems[selectedIndex].click();
                    }
                    return;
                }

                // Backspace - Go back one folder
                if (e.key === 'Backspace' && document.activeElement !== searchInput) {
                    e.preventDefault();
                    if (currentPath.length > 0) {
                        goBackOneFolder();
                    }
                    return;
                }

                // Arrow Left - Collapse selected folder or parent folder if on a file
                if (e.key === 'ArrowLeft' && document.activeElement !== searchInput) {
                    e.preventDefault();
                    if (navigableItems.length > 0 && navigableItems[selectedIndex]) {
                        const item = navigableItems[selectedIndex];
                        if (item.classList.contains('directory')) {
                            // If on a folder, collapse it if it's open
                            const li = item.parentElement;
                            const nested = li?.querySelector('.nested');
                            if (nested && nested.classList.contains('open')) {
                                const expandIcon = item.querySelector('.expand-icon');
                                nested.classList.remove('open');
                                if (expandIcon) expandIcon.textContent = '+';
                                refreshNavigableItems();
                                saveState();
                            }
                        } else {
                            // If on a file, collapse its parent folder
                            const li = item.parentElement;
                            const parentUl = li?.parentElement;
                            if (parentUl && parentUl.classList.contains('nested') && parentUl.classList.contains('open')) {
                                parentUl.classList.remove('open');
                                const parentDiv = parentUl.previousElementSibling;
                                if (parentDiv) {
                                    const expandIcon = parentDiv.querySelector('.expand-icon');
                                    if (expandIcon) expandIcon.textContent = '+';
                                }
                                refreshNavigableItems();
                                saveState();
                            }
                        }
                    }
                    return;
                }

                // Arrow Right - Expand selected folder
                if (e.key === 'ArrowRight' && document.activeElement !== searchInput) {
                    e.preventDefault();
                    if (navigableItems.length > 0 && navigableItems[selectedIndex]) {
                        const item = navigableItems[selectedIndex];
                        if (item.classList.contains('directory')) {
                            const li = item.parentElement;
                            const nested = li?.querySelector('.nested');
                            if (nested && !nested.classList.contains('open')) {
                                const expandIcon = item.querySelector('.expand-icon');
                                nested.classList.add('open');
                                if (expandIcon) expandIcon.textContent = '-';
                                // Track path
                                const nameSpan = item.querySelector('.file-name');
                                if (nameSpan) {
                                    currentPath.push(nameSpan.textContent);
                                }
                                refreshNavigableItems();
                                saveState();
                            }
                        }
                    }
                    return;
                }
            });
        }

        function updateSelection() {
            // Remove previous selection
            navigableItems.forEach(item => item.classList.remove('selected'));

            // Add selection to current item
            if (navigableItems[selectedIndex]) {
                navigableItems[selectedIndex].classList.add('selected');
                // Scroll into view
                navigableItems[selectedIndex].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
            }
        }

        function goBackOneFolder() {
            if (currentPath.length === 0) return;

            // Remove last folder from path
            currentPath.pop();

            // Find all expanded folders and close the deepest one
            const allExpanded = document.querySelectorAll('.nested.open');
            if (allExpanded.length > 0) {
                const deepest = allExpanded[allExpanded.length - 1];
                deepest.classList.remove('open');
                const parentDiv = deepest.previousElementSibling;
                if (parentDiv) {
                    const expandIcon = parentDiv.querySelector('.expand-icon');
                    if (expandIcon) {
                        expandIcon.textContent = '+';
                    }
                }
            }

            // Refresh navigable items
            refreshNavigableItems();

            // Save state after going back
            saveState();
        }

        function getFileIcon(item) {
            if (item.type === 'directory') return '[DIR]';

            const ext = item.name.split('.').pop().toLowerCase();
            const mimeType = item.mimeType || '';

            // Executables and binaries
            if (['exe', 'com', 'bat', 'sh'].includes(ext)) return '[EXE]';

            // Archives
            if (['zip', 'tar', 'gz', 'rar', '7z', 'arc', 'lzh'].includes(ext)) return '[ARC]';

            // Images
            if (mimeType.startsWith('image/') || ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'pcx'].includes(ext)) {
                return '[IMG]';
            }

            // Documents
            if (['txt', 'doc', 'pdf', 'nfo'].includes(ext)) return '[DOC]';

            // Code/Text
            if (['c', 'cpp', 'h', 'js', 'py', 'asm', 'bas'].includes(ext)) return '[SRC]';

            // Data
            if (['dat', 'db', 'cfg', 'ini', 'json'].includes(ext)) return '[DAT]';

            // Default
            return '[FILE]';
        }

        function calculateStats() {
            let totalFiles = 0;
            let totalFolders = 0;
            let totalSize = 0;

            fileData.forEach(item => {
                if (item.type === 'directory') {
                    totalFolders++;
                } else {
                    totalFiles++;
                    totalSize += item.size || 0;
                }
            });

            document.getElementById('total-files').textContent = totalFiles;
            document.getElementById('total-folders').textContent = totalFolders;
            document.getElementById('total-size').textContent = formatSize(totalSize);
        }

        function formatSize(bytes) {
            if (bytes < 1024) return bytes + ' B';
            if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
            if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
            return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
        }

        function refreshNavigableItems() {
            // Get all file-item and result-item elements
            const allItems = Array.from(document.querySelectorAll('.file-item, .result-item'));

            // Filter to only include visible items (not inside collapsed folders)
            navigableItems = allItems.filter(item => {
                let element = item;
                while (element && element !== document.body) {
                    if (element.classList && element.classList.contains('nested') && !element.classList.contains('open')) {
                        return false; // Item is inside a collapsed folder
                    }
                    element = element.parentElement;
                }
                return true; // Item is visible
            });

            selectedIndex = Math.min(selectedIndex, Math.max(0, navigableItems.length - 1));
            updateSelection();
        }

        function renderFileList() {
            const container = document.getElementById('file-list');
            const query = currentSearchQuery.toLowerCase();

            // If searching, show filtered results
            if (query) {
                const results = fileData.filter(item => {
                    const nameMatch = item.name.toLowerCase().includes(query);
                    const pathMatch = item.path.toLowerCase().includes(query);
                    const mimeMatch = item.mimeType && item.mimeType.toLowerCase().includes(query);
                    return nameMatch || pathMatch || mimeMatch;
                });

                if (results.length === 0) {
                    container.innerHTML = \`
                        <div class="no-results">
                            *** SEARCH FAILED ***<br><br>
                            NO MATCHES FOUND FOR: "\${currentSearchQuery}"<br><br>
                            PRESS [ESC] TO CLEAR SEARCH
                        </div>
                    \`;
                    navigableItems = [];
                    return;
                }

                container.innerHTML = '';
                results.forEach(item => {
                    const div = document.createElement('div');
                    div.className = 'result-item';

                    const sizeStr = item.type !== 'directory' ? formatSize(item.size) : '<DIR>';
                    const mimeStr = item.mimeType ? \` TYPE: \${item.mimeType}\` : '';

                    div.innerHTML = \`
                        <div class="result-name">\${getFileIcon(item)} \${item.name}</div>
                        <div class="result-path">PATH: \${item.path}</div>
                        <div class="result-meta">SIZE: \${sizeStr}\${mimeStr}</div>
                    \`;

                    div.addEventListener('click', () => {
                        if (item.type !== 'directory') {
                            openFile(item.path, false);
                        }
                    });

                    // Right-click to open in new tab
                    if (item.type !== 'directory') {
                        div.addEventListener('contextmenu', (e) => {
                            e.preventDefault();
                            openFile(item.path, true);
                        });
                    }

                    container.appendChild(div);
                });

                refreshNavigableItems();
                return;
            }

            // Otherwise show file tree
            const tree = {};
            fileData.forEach(item => {
                const parts = item.path.split('/');
                let current = tree;

                parts.forEach((part, index) => {
                    if (!current[part]) {
                        current[part] = {
                            name: part,
                            type: index === parts.length - 1 ? item.type : 'directory',
                            size: index === parts.length - 1 ? item.size : 0,
                            path: item.path,
                            mimeType: item.mimeType,
                            children: {}
                        };
                    }
                    current = current[part].children;
                });
            });

            container.innerHTML = '';
            const ul = document.createElement('ul');
            ul.className = 'file-tree';
            renderTreeNode(tree, ul);
            container.appendChild(ul);

            refreshNavigableItems();
        }

        function renderTreeNode(node, container) {
            const entries = Object.values(node).sort((a, b) => {
                // Folders first, then alphabetically
                if (a.type === 'directory' && b.type !== 'directory') return -1;
                if (a.type !== 'directory' && b.type === 'directory') return 1;
                return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
            });

            entries.forEach(item => {
                const li = document.createElement('li');
                const div = document.createElement('div');
                div.className = \`file-item \${item.type}\`;

                const expandIcon = document.createElement('span');
                expandIcon.className = 'expand-icon';
                if (item.type === 'directory') {
                    expandIcon.textContent = '+';
                } else {
                    expandIcon.textContent = ' ';
                }
                div.appendChild(expandIcon);

                const icon = document.createElement('span');
                icon.textContent = getFileIcon(item) + ' ';
                div.appendChild(icon);

                const name = document.createElement('span');
                name.className = 'file-name';
                name.textContent = item.name;
                div.appendChild(name);

                if (item.type !== 'directory') {
                    const size = document.createElement('span');
                    size.className = 'file-size';
                    size.textContent = formatSize(item.size);
                    div.appendChild(size);
                } else {
                    const size = document.createElement('span');
                    size.className = 'file-size';
                    size.textContent = '<DIR>';
                    div.appendChild(size);
                }

                div.addEventListener('click', (e) => {
                    e.stopPropagation();
                    if (item.type === 'directory') {
                        const nested = li.querySelector('.nested');
                        const expandIcon = div.querySelector('.expand-icon');
                        if (nested) {
                            const isOpen = nested.classList.toggle('open');
                            expandIcon.textContent = isOpen ? '-' : '+';

                            // Update current path
                            if (isOpen) {
                                currentPath.push(item.name);
                            } else {
                                const index = currentPath.indexOf(item.name);
                                if (index > -1) {
                                    currentPath.splice(index, 1);
                                }
                            }

                            // Refresh navigable items after expanding/collapsing
                            refreshNavigableItems();

                            // Save state after folder change
                            saveState();
                        }
                    } else {
                        openFile(item.path, false);
                    }
                });

                // Right-click to open in new tab
                if (item.type !== 'directory') {
                    div.addEventListener('contextmenu', (e) => {
                        e.preventDefault();
                        openFile(item.path, true);
                    });
                }

                li.appendChild(div);

                if (item.type === 'directory' && Object.keys(item.children).length > 0) {
                    const nested = document.createElement('ul');
                    nested.className = 'nested';  // Collapsed by default
                    renderTreeNode(item.children, nested);
                    li.appendChild(nested);
                }

                container.appendChild(li);
            });
        }

        function setupSearch() {
            const searchInput = document.getElementById('search-input');
            searchInput.addEventListener('input', (e) => {
                clearTimeout(searchTimeout);
                searchTimeout = setTimeout(() => {
                    currentSearchQuery = e.target.value.trim();
                    renderFileList();
                }, 300);
            });
        }

        function openFile(path, newTab = false) {
            if (newTab) {
                window.open(path, '_blank');
            } else {
                // Save current state before navigating
                saveState();
                window.location.href = path;
            }
        }

        // Save current browser state
        function saveState() {
            const expandedPaths = [];
            document.querySelectorAll('.nested.open').forEach(nested => {
                const parentDiv = nested.previousElementSibling;
                if (parentDiv) {
                    const nameSpan = parentDiv.querySelector('.file-name');
                    if (nameSpan) {
                        expandedPaths.push(nameSpan.textContent);
                    }
                }
            });

            const state = {
                expandedPaths: expandedPaths,
                selectedIndex: selectedIndex,
                searchQuery: currentSearchQuery
            };

            // Push state to history
            history.replaceState(state, '', window.location.href);
        }

        // Restore state from URL hash or history
        function restoreState() {
            const state = history.state;
            if (state && state.expandedPaths) {
                restoreStateFromData(state);
            }
        }

        // Restore state from data object
        function restoreStateFromData(state) {
            if (!state) return;

            // Restore search query
            if (state.searchQuery) {
                const searchInput = document.getElementById('search-input');
                searchInput.value = state.searchQuery;
                currentSearchQuery = state.searchQuery;
            }

            // Wait for file list to render
            setTimeout(() => {
                // Restore expanded folders
                if (state.expandedPaths && state.expandedPaths.length > 0) {
                    state.expandedPaths.forEach(folderName => {
                        const allDivs = document.querySelectorAll('.file-item.directory');
                        allDivs.forEach(div => {
                            const nameSpan = div.querySelector('.file-name');
                            if (nameSpan && nameSpan.textContent === folderName) {
                                const li = div.parentElement;
                                const nested = li?.querySelector('.nested');
                                if (nested && !nested.classList.contains('open')) {
                                    const expandIcon = div.querySelector('.expand-icon');
                                    nested.classList.add('open');
                                    if (expandIcon) expandIcon.textContent = '-';
                                }
                            }
                        });
                    });

                    // Refresh navigable items and restore selection
                    refreshNavigableItems();

                    if (state.selectedIndex !== undefined && state.selectedIndex < navigableItems.length) {
                        selectedIndex = state.selectedIndex;
                        updateSelection();
                    }
                }
            }, 50);
        }
    </script>
</body>
</html>
''';
  }

  /// Validate that tree.json matches actual directory contents
  Future<bool> _validateTreeJson(Directory folder) async {
    try {
      final treeJsonFile = File('${folder.path}/extra/tree.json');
      if (!await treeJsonFile.exists()) {
        stderr.writeln('tree.json does not exist, needs regeneration');
        return false;
      }

      // Check if tree.json was modified recently (within last hour)
      // If so, assume it's valid to avoid expensive directory scanning
      final stat = await treeJsonFile.stat();
      final now = DateTime.now();
      final age = now.difference(stat.modified);

      if (age.inMinutes < 60) {
        // File is recent, assume valid
        return true;
      }

      // For older files, just check if file exists without full validation
      // Full validation is too expensive for large apps
      return true;
    } catch (e) {
      stderr.writeln('Error validating tree.json: $e');
      return false;
    }
  }

  /// Check if app has all required files
  Future<bool> _hasRequiredFiles(Directory folder) async {
    final appJs = File('${folder.path}/app.js');
    final treeJson = File('${folder.path}/extra/tree.json');
    final dataJs = File('${folder.path}/extra/data.js');
    final indexHtml = File('${folder.path}/index.html');

    return await appJs.exists() &&
           await treeJson.exists() &&
           await dataJs.exists() &&
           await indexHtml.exists();
  }

  /// Ensure app files are up to date
  Future<void> ensureAppFilesUpdated(App app, {bool force = false}) async {
    if (app.storagePath == null) {
      return;
    }

    final folder = Directory(app.storagePath!);
    if (!await folder.exists()) {
      return;
    }

    if (force) {
      // Force regeneration regardless of current state
      stderr.writeln('Force regenerating app files for ${app.title}...');
      await _generateAndSaveTreeJson(folder);
      await _generateAndSaveDataJs(folder);
      await _generateAndSaveIndexHtml(folder);
      return;
    }

    // Check if tree.json is valid
    final isValid = await _validateTreeJson(folder);

    if (!isValid || !await _hasRequiredFiles(folder)) {
      stderr.writeln('Regenerating app files for ${app.title}...');
      await _generateAndSaveTreeJson(folder);
      await _generateAndSaveDataJs(folder);
      await _generateAndSaveIndexHtml(folder);
    }
  }

  /// Generate homepage index.html that aggregates content from all apps
  ///
  /// Creates a landing page with:
  /// - Navigation cards to all apps
  /// - Recent blog posts
  /// - Upcoming events
  /// - Places summary
  /// - Chat rooms list
  Future<void> generateHomepage({
    String? callsign,
    String? title,
    String? description,
  }) async {
    if (kIsWeb) {
      stderr.writeln('Homepage generation not supported on web');
      return;
    }

    final targetCallsign = callsign ?? _currentCallsign;
    if (targetCallsign == null) {
      stderr.writeln('No callsign specified for homepage generation');
      return;
    }

    final callsignDir = Directory(p.join(_devicesDir!.path, targetCallsign));
    if (!await callsignDir.exists()) {
      stderr.writeln('Callsign directory not found: ${callsignDir.path}');
      return;
    }

    try {
      // Initialize WebThemeService if needed
      final themeService = WebThemeService();
      await themeService.init();

      // Get template
      final template = await themeService.getTemplate('home');
      if (template == null) {
        stderr.writeln('Home template not found');
        return;
      }

      // Get app-specific styles (global styles served separately via /styles.css)
      final combinedStyles = await themeService.getAppStyles('home') ?? '';

      // Aggregate data from apps
      final recentPosts = await _getRecentBlogPosts(targetCallsign, limit: 5);
      final upcomingEvents = await _getUpcomingEvents(targetCallsign, limit: 5);
      final placesCount = await _getPlacesCount(targetCallsign);
      final chatRooms = await _getChatRoomsList(targetCallsign);

      // Build data object for JavaScript
      final dataObject = {
        'recentPosts': recentPosts,
        'upcomingEvents': upcomingEvents,
        'placesCount': placesCount,
        'chatRooms': chatRooms,
      };

      // Build HTML content for each section
      final recentPostsHtml = _buildRecentPostsHtml(recentPosts);
      final upcomingEventsHtml = _buildUpcomingEventsHtml(upcomingEvents);
      final featuredPlacesHtml = ''; // Can be expanded later
      final chatRoomsHtml = _buildChatRoomsHtml(chatRooms);

      // Process template
      final html = themeService.processTemplate(template, {
        'TITLE': title ?? targetCallsign,
        'APP_NAME': title ?? targetCallsign,
        'APP_DESCRIPTION': description ?? 'Welcome to $targetCallsign',
        'COLLECTION_NAME': title ?? targetCallsign,
        'COLLECTION_DESCRIPTION': description ?? 'Welcome to $targetCallsign',
        'RECENT_POSTS': recentPostsHtml,
        'UPCOMING_EVENTS': upcomingEventsHtml,
        'PLACES_COUNT': placesCount.toString(),
        'FEATURED_PLACES': featuredPlacesHtml,
        'CHAT_ROOMS': chatRoomsHtml,
        'DATA_JSON': json.encode(dataObject),
        'GENERATED_DATE': DateTime.now().toIso8601String(),
        'SCRIPTS': '',
      });

      // Write index.html + styles.css
      final indexFile = File('${callsignDir.path}/index.html');
      await indexFile.writeAsString(html);
      final stylesFile = File('${callsignDir.path}/styles.css');
      await stylesFile.writeAsString(combinedStyles);
      stderr.writeln('Generated homepage: ${indexFile.path}');
    } catch (e) {
      stderr.writeln('Error generating homepage: $e');
    }
  }

  /// Get recent blog posts from all blog apps
  Future<List<Map<String, dynamic>>> _getRecentBlogPosts(String callsign, {int limit = 5}) async {
    final posts = <Map<String, dynamic>>[];

    try {
      final callsignDir = Directory(p.join(_devicesDir!.path, callsign));
      if (!await callsignDir.exists()) return posts;

      // Look for blog apps
      await for (final entity in callsignDir.list()) {
        if (entity is Directory) {
          final appJs = File('${entity.path}/app.js');
          if (await appJs.exists()) {
            final content = await appJs.readAsString();
            if (content.contains('"type": "blog"')) {
              // This is a blog app - load posts
              final blogService = BlogService();
              await blogService.initializeApp(entity.path);
              final blogPosts = await blogService.loadPosts(publishedOnly: true);

              for (final post in blogPosts.take(limit - posts.length)) {
                // Parse timestamp (format: YYYY-MM-DD HH:MM_ss) to get date and year
                final postDate = post.timestamp.length >= 10 ? post.timestamp.substring(0, 10) : '';
                final postYear = post.timestamp.length >= 4 ? post.timestamp.substring(0, 4) : '';
                posts.add({
                  'title': post.title,
                  'slug': post.id,
                  'date': postDate,
                  'author': post.author,
                  'excerpt': _truncateText(post.content, 150),
                  'url': '${entity.path.split('/').last}/$postYear/${post.id}.html',
                });
              }
            }
          }
        }
        if (posts.length >= limit) break;
      }

      // Sort by date (newest first)
      posts.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
    } catch (e) {
      stderr.writeln('Error loading blog posts: $e');
    }

    return posts.take(limit).toList();
  }

  /// Get upcoming events from all event apps
  Future<List<Map<String, dynamic>>> _getUpcomingEvents(String callsign, {int limit = 5}) async {
    final events = <Map<String, dynamic>>[];
    final now = DateTime.now();

    try {
      final callsignDir = Directory(p.join(_devicesDir!.path, callsign));
      if (!await callsignDir.exists()) return events;

      // Look for events apps
      await for (final entity in callsignDir.list()) {
        if (entity is Directory) {
          final appJs = File('${entity.path}/app.js');
          if (await appJs.exists()) {
            final content = await appJs.readAsString();
            if (content.contains('"type": "events"')) {
              // This is an events app - load events
              final eventService = EventService();
              await eventService.initializeApp(entity.path);
              final loadedEvents = await eventService.loadEvents();

              for (final event in loadedEvents) {
                // Only include public future events
                if (event.visibility != 'public') continue;

                // Parse startDate string to DateTime
                DateTime? eventStartDate;
                if (event.startDate != null) {
                  try {
                    eventStartDate = DateTime.parse(event.startDate!);
                  } catch (_) {}
                }
                if (eventStartDate != null && eventStartDate.isAfter(now)) {
                  events.add({
                    'id': event.id,
                    'title': event.title,
                    'date': event.startDate ?? '',
                    'location': event.location,
                    'description': _truncateText(event.content, 100),
                    'url': '${entity.path.split('/').last}/${event.id}.html',
                  });
                }
              }
            }
          }
        }
      }

      // Sort by date (soonest first)
      events.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
    } catch (e) {
      stderr.writeln('Error loading events: $e');
    }

    return events.take(limit).toList();
  }

  /// Get count of public places
  Future<int> _getPlacesCount(String callsign) async {
    int count = 0;

    try {
      final callsignDir = Directory(p.join(_devicesDir!.path, callsign));
      if (!await callsignDir.exists()) return count;

      // Look for places apps
      await for (final entity in callsignDir.list()) {
        if (entity is Directory) {
          final appJs = File('${entity.path}/app.js');
          if (await appJs.exists()) {
            final content = await appJs.readAsString();
            if (content.contains('"type": "places"')) {
              // Count public place folders only
              await for (final placeEntity in entity.list()) {
                if (placeEntity is Directory) {
                  final placeJson = File('${placeEntity.path}/place.json');
                  if (await placeJson.exists()) {
                    // Check visibility is public
                    try {
                      final placeContent = await placeJson.readAsString();
                      final placeData = jsonDecode(placeContent) as Map<String, dynamic>;
                      if (placeData['visibility'] == 'public') {
                        count++;
                      }
                    } catch (_) {
                      // Skip places that can't be parsed
                    }
                  }
                }
              }
            }
          }
        }
      }
    } catch (e) {
      stderr.writeln('Error counting places: $e');
    }

    return count;
  }

  /// Get list of public chat rooms
  Future<List<Map<String, dynamic>>> _getChatRoomsList(String callsign) async {
    final rooms = <Map<String, dynamic>>[];

    try {
      final callsignDir = Directory(p.join(_devicesDir!.path, callsign));
      if (!await callsignDir.exists()) return rooms;

      // Look for chat apps
      await for (final entity in callsignDir.list()) {
        if (entity is Directory) {
          final appJs = File('${entity.path}/app.js');
          if (await appJs.exists()) {
            final content = await appJs.readAsString();
            if (content.contains('"type": "chat"')) {
              // This is a chat app - load channels
              final chatService = ChatService();
              // Set profile storage for encrypted storage support
              if (_profileStorage != null) {
                final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
                  _profileStorage!,
                  entity.path,
                );
                chatService.setStorage(scopedStorage);
              } else {
                chatService.setStorage(FilesystemProfileStorage(entity.path));
              }
              await chatService.initializeApp(entity.path);

              for (final channel in chatService.channels) {
                // Check if channel is public (via config or by having '*' in participants)
                final isPublic = channel.config?.visibility == 'PUBLIC' ||
                    channel.participants.contains('*');
                if (isPublic) {
                  rooms.add({
                    'id': channel.id,
                    'name': channel.name,
                    'description': channel.description ?? '',
                    'url': '${entity.path.split('/').last}/#${channel.id}',
                  });
                }
              }
            }
          }
        }
      }
    } catch (e) {
      stderr.writeln('Error loading chat rooms: $e');
    }

    return rooms;
  }

  /// Build HTML for recent posts section
  String _buildRecentPostsHtml(List<Map<String, dynamic>> posts) {
    if (posts.isEmpty) {
      return '<p class="empty-message">No recent posts</p>';
    }

    final buffer = StringBuffer();
    for (final post in posts) {
      final date = post['date'] != null && post['date'].isNotEmpty
          ? DateTime.tryParse(post['date'])
          : null;
      final dateStr = date != null
          ? '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}'
          : '';

      buffer.writeln('''
        <div class="post-card">
          <h3 class="post-card-title"><a href="${escapeHtml(post['url'] ?? '')}">${escapeHtml(post['title'] ?? 'Untitled')}</a></h3>
          <p class="post-card-meta">${escapeHtml(post['author'] ?? '')} &middot; $dateStr</p>
          <p class="post-card-excerpt">${escapeHtml(post['excerpt'] ?? '')}</p>
        </div>
      ''');
    }
    return buffer.toString();
  }

  /// Build HTML for upcoming events section
  String _buildUpcomingEventsHtml(List<Map<String, dynamic>> events) {
    if (events.isEmpty) {
      return '<p class="empty-message">No upcoming events</p>';
    }

    final buffer = StringBuffer();
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

    for (final event in events) {
      final date = event['date'] != null && event['date'].isNotEmpty
          ? DateTime.tryParse(event['date'])
          : null;
      final dayStr = date?.day.toString() ?? '';
      final monthStr = date != null ? months[date.month - 1] : '';

      buffer.writeln('''
        <div class="event-item">
          <div class="event-date">
            <span class="event-date-day">$dayStr</span>
            <span class="event-date-month">$monthStr</span>
          </div>
          <div class="event-details">
            <h3 class="event-title"><a href="${escapeHtml(event['url'] ?? '')}">${escapeHtml(event['title'] ?? 'Untitled')}</a></h3>
            <p class="event-info">${escapeHtml(event['location'] ?? '')}</p>
          </div>
        </div>
      ''');
    }
    return buffer.toString();
  }

  /// Build HTML for chat rooms section
  String _buildChatRoomsHtml(List<Map<String, dynamic>> rooms) {
    if (rooms.isEmpty) {
      return '<p class="empty-message">No public chat rooms</p>';
    }

    final buffer = StringBuffer();
    for (final room in rooms) {
      buffer.writeln('''
        <a href="${escapeHtml(room['url'] ?? '')}" class="chat-room-card">
          <div class="chat-room-icon">&#128172;</div>
          <div class="chat-room-info">
            <div class="chat-room-name">${escapeHtml(room['name'] ?? 'Unnamed')}</div>
          </div>
        </a>
      ''');
    }
    return buffer.toString();
  }

  /// Truncate text to specified length
  String _truncateText(String text, int maxLength) {
    // Remove markdown formatting
    final cleanText = text
        .replaceAll(RegExp(r'#{1,6}\s'), '')  // Headers
        .replaceAll(RegExp(r'\*{1,2}([^*]+)\*{1,2}'), r'$1')  // Bold/italic
        .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1')  // Links
        .replaceAll(RegExp(r'`[^`]+`'), '')  // Inline code
        .replaceAll(RegExp(r'\n+'), ' ')  // Newlines
        .trim();

    if (cleanText.length <= maxLength) return cleanText;
    return '${cleanText.substring(0, maxLength)}...';
  }

  /// Escape HTML special characters
}
