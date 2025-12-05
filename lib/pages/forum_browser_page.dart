/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import '../models/collection.dart';
import '../models/forum_section.dart';
import '../models/forum_thread.dart';
import '../models/forum_post.dart';
import '../services/forum_service.dart';
import '../services/profile_service.dart';
import '../services/signing_service.dart';
import '../widgets/section_list_widget.dart';
import '../widgets/thread_list_widget.dart';
import '../widgets/post_list_widget.dart';
import '../widgets/post_input_widget.dart';
import '../widgets/new_thread_dialog.dart';

/// Page for browsing and interacting with a forum collection
class ForumBrowserPage extends StatefulWidget {
  final Collection collection;

  const ForumBrowserPage({
    Key? key,
    required this.collection,
  }) : super(key: key);

  @override
  State<ForumBrowserPage> createState() => _ForumBrowserPageState();
}

class _ForumBrowserPageState extends State<ForumBrowserPage> {
  final ForumService _forumService = ForumService();
  final ProfileService _profileService = ProfileService();

  List<ForumSection> _sections = [];
  ForumSection? _selectedSection;
  List<ForumThread> _threads = [];
  ForumThread? _selectedThread;
  List<ForumPost> _posts = [];
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;

  /// Check if current user is admin
  bool get _isAdmin {
    final currentProfile = _profileService.getProfile();
    return currentProfile.npub.isNotEmpty &&
        _forumService.security.adminNpub == currentProfile.npub;
  }

  @override
  void initState() {
    super.initState();
    _initializeForum();
  }

  /// Initialize forum service and load data
  Future<void> _initializeForum() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Initialize forum service with collection path
      final storagePath = widget.collection.storagePath;
      if (storagePath == null) {
        throw Exception('Collection storage path is null');
      }

      // Pass current user's npub to initialize admin if needed
      final currentProfile = _profileService.getProfile();
      await _forumService.initializeCollection(
        storagePath,
        creatorNpub: currentProfile.npub,
      );

      // Load sections
      _sections = _forumService.sections;

      // Select first section by default
      if (_sections.isNotEmpty) {
        await _selectSection(_sections.first);
      }

      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to initialize forum: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Select a section and load its threads
  Future<void> _selectSection(ForumSection section) async {
    setState(() {
      _selectedSection = section;
      _selectedThread = null;
      _threads = [];
      _posts = [];
      _isLoading = true;
    });

    try {
      // Load threads for selected section
      final threads = await _forumService.loadThreads(section.id);

      setState(() {
        _threads = threads;
      });
    } catch (e) {
      _showError('Failed to load threads: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Select a thread and load its posts
  Future<void> _selectThread(ForumThread thread) async {
    setState(() {
      _selectedThread = thread;
      _isLoading = true;
    });

    try {
      // Load posts for selected thread
      if (_selectedSection == null) return;

      final posts = await _forumService.loadPosts(
        _selectedSection!.id,
        thread.id,
      );

      setState(() {
        _posts = posts;
      });
    } catch (e) {
      _showError('Failed to load posts: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Send a post/reply
  Future<void> _sendPost(String content, String? filePath) async {
    if (_selectedSection == null || _selectedThread == null) return;

    final currentProfile = _profileService.getProfile();
    if (currentProfile.callsign.isEmpty) {
      _showError('No active callsign. Please set up your profile first.');
      return;
    }

    try {
      // Create post
      Map<String, String> metadata = {};

      // Handle file attachment
      String? attachedFileName;
      if (filePath != null) {
        attachedFileName = await _copyFileToThread(filePath);
        if (attachedFileName != null) {
          metadata['file'] = attachedFileName;
        }
      }

      // Load settings and check if signing is enabled
      final settings = await _loadForumSettings();
      final signingService = SigningService();
      await signingService.initialize();
      if (settings['signMessages'] == true &&
          currentProfile.npub.isNotEmpty &&
          signingService.canSign(currentProfile)) {
        // Add npub
        metadata['npub'] = currentProfile.npub;

        // Generate BIP-340 Schnorr signature (handles both extension and nsec)
        final signature = await signingService.generateSignature(
          content,
          metadata,
          currentProfile,
        );
        if (signature != null && signature.isNotEmpty) {
          metadata['signature'] = signature;
        }
      }

      // Create post object
      final post = ForumPost.now(
        author: currentProfile.callsign,
        content: content,
        isOriginalPost: false,
        metadata: metadata.isNotEmpty ? metadata : null,
      );

      // Save post
      await _forumService.addReply(
        _selectedSection!.id,
        _selectedThread!.id,
        post,
      );

      // Add to local list (optimistic update)
      setState(() {
        _posts.add(post);
      });

      _showSuccess('Post added successfully');
    } catch (e) {
      _showError('Failed to send post: $e');
    }
  }

  /// Load forum settings
  Future<Map<String, dynamic>> _loadForumSettings() async {
    try {
      final storagePath = widget.collection.storagePath;
      if (storagePath == null) return {};

      final settingsFile =
          File(path.join(storagePath, 'extra', 'settings.json'));
      if (!await settingsFile.exists()) {
        return {};
      }

      final content = await settingsFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return json;
    } catch (e) {
      return {};
    }
  }

  /// Copy file to thread's files folder
  /// Files are renamed to: {sha1}_{original_filename} to prevent overwrites
  Future<String?> _copyFileToThread(String sourceFilePath) async {
    try {
      final sourceFile = File(sourceFilePath);
      if (!await sourceFile.exists()) {
        _showError('File not found');
        return null;
      }

      // Determine destination folder
      final storagePath = widget.collection.storagePath;
      if (storagePath == null || _selectedSection == null || _selectedThread == null) {
        _showError('Invalid forum state');
        return null;
      }

      // Calculate SHA1 hash of the file
      final bytes = await sourceFile.readAsBytes();
      final hash = sha1.convert(bytes);
      final sha1Hash = hash.toString();

      // Files go in the section folder (not in individual thread files)
      final filesPath = path.join(
        storagePath,
        _selectedSection!.folder,
        'files',
      );

      final filesDir = Directory(filesPath);

      // Create files directory if it doesn't exist
      if (!await filesDir.exists()) {
        await filesDir.create(recursive: true);
      }

      // Get original filename (truncate if too long)
      String originalFileName = path.basename(sourceFilePath);
      if (originalFileName.length > 100) {
        final ext = path.extension(originalFileName);
        final nameWithoutExt = path.basenameWithoutExtension(originalFileName);
        final maxNameLength = 100 - ext.length;
        originalFileName = nameWithoutExt.substring(0, maxNameLength) + ext;
      }

      // Create new filename: {sha1}_{original_filename}
      final newFileName = '${sha1Hash}_$originalFileName';
      final destPath = path.join(filesDir.path, newFileName);
      final destFile = File(destPath);

      // Copy file (no need to check for duplicates - SHA1 ensures uniqueness)
      await sourceFile.copy(destFile.path);

      return newFileName;
    } catch (e) {
      _showError('Failed to copy file: $e');
      return null;
    }
  }

  /// Check if user can delete a post
  bool _canDeletePost(ForumPost post) {
    if (_selectedSection == null) return false;

    final currentProfile = _profileService.getProfile();
    final userNpub = currentProfile.npub;

    // Check if user is admin or moderator
    return _forumService.security.canModerate(userNpub, _selectedSection!.id);
  }

  /// Delete a post
  Future<void> _deletePost(ForumPost post) async {
    if (_selectedSection == null || _selectedThread == null) return;

    try {
      final currentProfile = _profileService.getProfile();
      final userNpub = currentProfile.npub;

      await _forumService.deletePost(
        _selectedSection!.id,
        _selectedThread!.id,
        post,
        userNpub,
      );

      // Remove from local list
      setState(() {
        _posts.removeWhere((p) =>
            p.timestamp == post.timestamp && p.author == post.author);
      });

      _showSuccess('Post deleted');
    } catch (e) {
      _showError('Failed to delete post: $e');
    }
  }

  /// Open attached file
  Future<void> _openAttachedFile(ForumPost post) async {
    if (!post.hasFile || _selectedSection == null) return;

    try {
      final storagePath = widget.collection.storagePath;
      if (storagePath == null) {
        _showError('Collection storage path is null');
        return;
      }

      // Construct file path
      final filePath = path.join(
        storagePath,
        _selectedSection!.folder,
        'files',
        post.attachedFile!,
      );

      final file = File(filePath);
      if (!await file.exists()) {
        _showError('File not found: ${post.attachedFile}');
        return;
      }

      // Open file with default application
      if (Platform.isLinux) {
        await Process.run('xdg-open', [filePath]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [filePath]);
      } else if (Platform.isWindows) {
        await Process.run('start', [filePath], runInShell: true);
      }
    } catch (e) {
      _showError('Failed to open file: $e');
    }
  }

  /// Show new thread dialog
  Future<void> _showNewThreadDialog() async {
    if (_selectedSection == null) return;

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => NewThreadDialog(
        existingThreadTitles: _threads.map((t) => t.title).toList(),
        maxTitleLength: 100,
        maxContentLength: _selectedSection!.config?.maxSizeText ?? 5000,
      ),
    );

    if (result != null) {
      try {
        setState(() {
          _isLoading = true;
        });

        final currentProfile = _profileService.getProfile();
        if (currentProfile.callsign.isEmpty) {
          _showError('No active callsign. Please set up your profile first.');
          return;
        }

        // Create original post
        Map<String, String> metadata = {};

        // Load settings and check if signing is enabled
        final settings = await _loadForumSettings();
        final signingService = SigningService();
        await signingService.initialize();
        if (settings['signMessages'] == true &&
            currentProfile.npub.isNotEmpty &&
            signingService.canSign(currentProfile)) {
          metadata['npub'] = currentProfile.npub;
          final signature = await signingService.generateSignature(
            result['content']!,
            metadata,
            currentProfile,
          );
          if (signature != null && signature.isNotEmpty) {
            metadata['signature'] = signature;
          }
        }

        final originalPost = ForumPost.now(
          author: currentProfile.callsign,
          content: result['content']!,
          isOriginalPost: true,
          metadata: metadata.isNotEmpty ? metadata : null,
        );

        // Create thread
        final thread = await _forumService.createThread(
          _selectedSection!.id,
          result['title']!,
          originalPost,
        );

        // Refresh threads by reloading the section
        final threads = await _forumService.loadThreads(_selectedSection!.id);

        setState(() {
          _threads = threads;
        });

        // Find and select the new thread from the loaded list
        final newThread = threads.firstWhere(
          (t) => t.id == thread.id,
          orElse: () => thread,
        );
        await _selectThread(newThread);

        _showSuccess('Thread created successfully');
      } catch (e) {
        _showError('Failed to create thread: $e');
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Refresh current view
  Future<void> _refresh() async {
    if (_selectedSection != null) {
      await _selectSection(_selectedSection!);
      if (_selectedThread != null) {
        // Find the thread in the refreshed list
        final refreshedThread = _threads.firstWhere(
          (t) => t.id == _selectedThread!.id,
          orElse: () => _selectedThread!,
        );
        await _selectThread(refreshedThread);
      }
    }
  }

  /// Check if user can create threads in selected section
  bool get _canCreateThread {
    if (_selectedSection == null) return false;
    return _selectedSection!.config?.allowNewThreads ?? true;
  }

  /// Show error message
  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  /// Show success message
  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: LayoutBuilder(
          builder: (context, constraints) {
            final screenWidth = MediaQuery.of(context).size.width;
            final isWideScreen = screenWidth >= 600;

            // In narrow screen, show "Forum" when on the section list
            if (!isWideScreen && _selectedSection == null && _selectedThread == null) {
              return Text(widget.collection.title);
            }

            return Text(
              _selectedThread?.title ??
                  _selectedSection?.name ??
                  widget.collection.title,
            );
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
            tooltip: 'Refresh',
          ),
          if (_selectedThread != null)
            IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: _showThreadInfo,
              tooltip: 'Thread info',
            ),
          if (_selectedThread != null && _isAdmin)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _confirmDeleteThread,
              tooltip: 'Delete thread (Admin)',
            ),
          if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _showSectionManagement,
              tooltip: 'Manage categories (Admin)',
            ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  /// Build main body
  Widget _buildBody(ThemeData theme) {
    if (!_isInitialized && _isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              _error!,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _initializeForum,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_sections.isEmpty) {
      return _buildEmptyState(theme);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Use three-panel layout for wide screens, single panel for narrow
        final isWideScreen = constraints.maxWidth >= 600;

        if (isWideScreen) {
          // Desktop/landscape: Three-panel layout
          return Row(
            children: [
              // Left panel - Section list
              SectionListWidget(
                sections: _sections,
                selectedSectionId: _selectedSection?.id,
                onSectionSelect: _selectSection,
              ),
              // Middle panel - Thread list
              ThreadListWidget(
                threads: _threads,
                selectedThreadId: _selectedThread?.id,
                onThreadSelect: _selectThread,
                onNewThread: _showNewThreadDialog,
                canCreateThread: _canCreateThread,
                onThreadMenu: _showThreadMenu,
                canModerateThread: (thread) => _isAdmin,
              ),
              // Right panel - Posts and input
              Expanded(
                child: _selectedThread == null
                    ? _buildNoThreadSelected(theme)
                    : Column(
                        children: [
                          // Post list
                          Expanded(
                            child: PostListWidget(
                              posts: _posts,
                              threadTitle: _selectedThread!.title,
                              onFileOpen: _openAttachedFile,
                              onPostDelete: _deletePost,
                              canDeletePost: _canDeletePost,
                            ),
                          ),
                          // Post input
                          PostInputWidget(
                            onSend: _sendPost,
                            maxLength: _selectedSection?.config?.maxSizeText ?? 5000,
                            allowFiles: _selectedSection?.config?.fileUpload ?? true,
                            isLocked: _selectedThread!.isLocked,
                            hintText: 'Write a reply...',
                          ),
                        ],
                      ),
              ),
            ],
          );
        } else {
          // Mobile/portrait: Single panel showing section list
          // Threads and posts open in full screen
          return _buildSectionList(theme, isMobileView: true);
        }
      },
    );
  }

  /// Build section list
  Widget _buildSectionList(ThemeData theme, {bool isMobileView = false}) {
    if (isMobileView) {
      // In mobile view, build a full-width list
      final sortedSections = List<ForumSection>.from(_sections);
      sortedSections.sort();

      return Container(
        color: theme.colorScheme.surface,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceVariant,
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outlineVariant,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.forum, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Text(
                    'Forum Categories',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: sortedSections.length,
                itemBuilder: (context, index) {
                  final section = sortedSections[index];
                  final isSelected = _selectedSection?.id == section.id;

                  return ListTile(
                    leading: Icon(
                      Icons.category,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      section.name,
                      style: TextStyle(
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? theme.colorScheme.primary : null,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (section.description != null && section.description!.isNotEmpty)
                          Text(
                            section.description!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        const SizedBox(height: 4),
                        FutureBuilder<List<ForumThread>>(
                          future: _forumService.loadThreads(section.id),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return Text(
                                'Loading...',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              );
                            }
                            final threads = snapshot.data!;
                            final totalPosts = threads.fold<int>(
                              0,
                              (sum, thread) => sum + thread.replyCount + 1, // +1 for original post
                            );
                            return Text(
                              '${threads.length} threads • $totalPosts posts',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    selected: isSelected,
                    onTap: () => _selectSectionMobile(section),
                  );
                },
              ),
            ),
          ],
        ),
      );
    }

    return SectionListWidget(
      sections: _sections,
      selectedSectionId: _selectedSection?.id,
      onSectionSelect: _selectSection,
    );
  }

  /// Select section in mobile view - navigate to thread list
  Future<void> _selectSectionMobile(ForumSection section) async {
    // Capture section for mobile navigation
    final sectionToOpen = section;

    // Load threads first
    setState(() {
      _isLoading = true;
    });

    try {
      final threads = await _forumService.loadThreads(sectionToOpen.id);

      if (!mounted) return;

      // Navigate to full-screen thread list view
      final result = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (context) => _ThreadListPage(
            section: sectionToOpen,
            threads: threads,
            forumService: _forumService,
            profileService: _profileService,
            collection: widget.collection,
            isAdmin: _isAdmin,
          ),
        ),
      );

      // Reload sections if changes were made
      if (result == true && mounted) {
        await _initializeForum();
      }
    } catch (e) {
      _showError('Failed to load threads: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Build empty state
  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.forum_outlined,
            size: 80,
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
          ),
          const SizedBox(height: 24),
          Text(
            'No forum categories found',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Forum collection is not properly initialized',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Build no thread selected state
  Widget _buildNoThreadSelected(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.topic_outlined,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Select a thread to view posts',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (_canCreateThread) ...[
            const SizedBox(height: 8),
            Text(
              'Or create a new thread',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Show thread information dialog
  void _showThreadInfo() {
    if (_selectedThread == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_selectedThread!.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildInfoRow('Author', _selectedThread!.author),
              _buildInfoRow('Created',
                  _selectedThread!.created.toString().substring(0, 16)),
              _buildInfoRow('Last Reply',
                  _selectedThread!.lastReply.toString().substring(0, 16)),
              _buildInfoRow('Replies', _selectedThread!.replyCount.toString()),
              if (_selectedThread!.isPinned)
                _buildInfoRow('Status', 'Pinned'),
              if (_selectedThread!.isLocked)
                _buildInfoRow('Status', 'Locked'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Show thread menu (admin/moderator options)
  void _showThreadMenu(ForumThread thread) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.delete,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete thread',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteThreadFromList(thread);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Confirm deletion from thread list
  void _confirmDeleteThreadFromList(ForumThread thread) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Thread'),
        content: Text(
          'Are you sure you want to delete the thread "${thread.title}"? '
          'This will permanently delete all posts in this thread.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteThreadById(thread.id);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// Delete thread by ID
  Future<void> _deleteThreadById(String threadId) async {
    if (_selectedSection == null) return;

    try {
      setState(() {
        _isLoading = true;
      });

      final currentProfile = _profileService.getProfile();
      await _forumService.deleteThread(
        sectionId: _selectedSection!.id,
        threadId: threadId,
        userNpub: currentProfile.npub,
      );

      // Clear selection if deleted thread was selected
      if (_selectedThread?.id == threadId) {
        setState(() {
          _selectedThread = null;
          _posts = [];
        });
      }

      // Reload threads
      await _selectSection(_selectedSection!);

      _showSuccess('Thread deleted successfully');
    } catch (e) {
      _showError('Failed to delete thread: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Show section management dialog (admin only)
  void _showSectionManagement() {
    if (!_isAdmin) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.admin_panel_settings,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            const Text('Manage Categories'),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // List of sections
              ..._sections.map((section) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(
                        section.readonly ? Icons.lock : Icons.folder,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(section.name),
                      subtitle: section.description != null
                          ? Text(section.description!)
                          : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit),
                            onPressed: () {
                              Navigator.pop(context);
                              _showRenameSectionDialog(section);
                            },
                            tooltip: 'Rename',
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete),
                            onPressed: () {
                              Navigator.pop(context);
                              _confirmDeleteSection(section);
                            },
                            tooltip: 'Delete',
                          ),
                        ],
                      ),
                    ),
                  )),
              const Divider(),
              // Add new section button
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('Create New Category'),
                onTap: () {
                  Navigator.pop(context);
                  _showCreateSectionDialog();
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Show create section dialog
  void _showCreateSectionDialog() {
    final idController = TextEditingController();
    final nameController = TextEditingController();
    final descriptionController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Category'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: idController,
                decoration: const InputDecoration(
                  labelText: 'Category ID',
                  hintText: 'e.g., tech-support',
                  helperText: 'Lowercase, letters, numbers, hyphens only',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a category ID';
                  }
                  if (!RegExp(r'^[a-z0-9-]+$').hasMatch(value.trim())) {
                    return 'Only lowercase letters, numbers, and hyphens';
                  }
                  if (_sections.any((s) => s.id == value.trim())) {
                    return 'Category ID already exists';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Category Name',
                  hintText: 'e.g., Tech Support',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a category name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  hintText: 'Brief description of this category',
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context);
                await _createSection(
                  idController.text.trim(),
                  nameController.text.trim(),
                  descriptionController.text.trim().isEmpty
                      ? null
                      : descriptionController.text.trim(),
                );
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    ).then((_) {
      idController.dispose();
      nameController.dispose();
      descriptionController.dispose();
    });
  }

  /// Show rename section dialog
  void _showRenameSectionDialog(ForumSection section) {
    final nameController = TextEditingController(text: section.name);
    final descriptionController =
        TextEditingController(text: section.description ?? '');
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Rename "${section.name}"'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Category Name',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a category name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context);
                await _renameSection(
                  section.id,
                  nameController.text.trim(),
                  descriptionController.text.trim().isEmpty
                      ? null
                      : descriptionController.text.trim(),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((_) {
      nameController.dispose();
      descriptionController.dispose();
    });
  }

  /// Confirm delete section
  void _confirmDeleteSection(ForumSection section) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Category'),
        content: Text(
          'Are you sure you want to delete the category "${section.name}"? '
          'This will delete all threads and posts in this category. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteSection(section.id);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// Create a new section
  Future<void> _createSection(
      String id, String name, String? description) async {
    try {
      setState(() {
        _isLoading = true;
      });

      final currentProfile = _profileService.getProfile();
      await _forumService.createSection(
        id: id,
        name: name,
        description: description,
        adminNpub: currentProfile.npub,
      );

      setState(() {
        _sections = _forumService.sections;
      });

      _showSuccess('Category "$name" created successfully');
    } catch (e) {
      _showError('Failed to create category: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Rename a section
  Future<void> _renameSection(
      String sectionId, String newName, String? newDescription) async {
    try {
      setState(() {
        _isLoading = true;
      });

      final currentProfile = _profileService.getProfile();
      await _forumService.renameSection(
        sectionId: sectionId,
        newName: newName,
        newDescription: newDescription,
        adminNpub: currentProfile.npub,
      );

      setState(() {
        _sections = _forumService.sections;
      });

      _showSuccess('Category renamed successfully');
    } catch (e) {
      _showError('Failed to rename category: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Delete a section
  Future<void> _deleteSection(String sectionId) async {
    try {
      setState(() {
        _isLoading = true;
      });

      final currentProfile = _profileService.getProfile();
      await _forumService.deleteSection(
        sectionId: sectionId,
        adminNpub: currentProfile.npub,
      );

      // Clear selection if deleted section was selected
      if (_selectedSection?.id == sectionId) {
        setState(() {
          _selectedSection = null;
          _threads = [];
          _selectedThread = null;
          _posts = [];
        });
      }

      setState(() {
        _sections = _forumService.sections;
      });

      _showSuccess('Category deleted successfully');
    } catch (e) {
      _showError('Failed to delete category: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Confirm thread deletion
  void _confirmDeleteThread() {
    if (_selectedThread == null || _selectedSection == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Thread'),
        content: Text(
          'Are you sure you want to delete the thread "${_selectedThread!.title}"? '
          'This will permanently delete all posts in this thread.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteThread();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// Delete the currently selected thread
  Future<void> _deleteThread() async {
    if (_selectedThread == null || _selectedSection == null) return;

    try {
      setState(() {
        _isLoading = true;
      });

      final currentProfile = _profileService.getProfile();
      await _forumService.deleteThread(
        sectionId: _selectedSection!.id,
        threadId: _selectedThread!.id,
        userNpub: currentProfile.npub,
      );

      // Clear thread selection and reload threads
      setState(() {
        _selectedThread = null;
        _posts = [];
      });

      await _selectSection(_selectedSection!);

      _showSuccess('Thread deleted successfully');
    } catch (e) {
      _showError('Failed to delete thread: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Build info row
  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: const TextStyle(fontSize: 12),
          ),
          const Divider(),
        ],
      ),
    );
  }
}

/// Full-screen thread list page for mobile view
class _ThreadListPage extends StatefulWidget {
  final ForumSection section;
  final List<ForumThread> threads;
  final ForumService forumService;
  final ProfileService profileService;
  final Collection collection;
  final bool isAdmin;

  const _ThreadListPage({
    Key? key,
    required this.section,
    required this.threads,
    required this.forumService,
    required this.profileService,
    required this.collection,
    required this.isAdmin,
  }) : super(key: key);

  @override
  State<_ThreadListPage> createState() => _ThreadListPageState();
}

class _ThreadListPageState extends State<_ThreadListPage> {
  late List<ForumThread> _threads;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _threads = widget.threads;
  }

  bool get _canCreateThread {
    return widget.section.config?.allowNewThreads ?? true;
  }

  Future<void> _selectThread(ForumThread thread) async {
    // Load posts for the thread
    final posts = await widget.forumService.loadPosts(
      widget.section.id,
      thread.id,
    );

    if (!mounted) return;

    // Navigate to posts page
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => _PostsPage(
          section: widget.section,
          thread: thread,
          posts: posts,
          forumService: widget.forumService,
          profileService: widget.profileService,
          collection: widget.collection,
          isAdmin: widget.isAdmin,
        ),
      ),
    );

    // Reload threads if changes were made
    if (result == true && mounted) {
      _hasChanges = true;
      await _reloadThreads();
    }
  }

  Future<void> _reloadThreads() async {
    final threads = await widget.forumService.loadThreads(widget.section.id);
    setState(() {
      _threads = threads;
    });
  }

  Future<void> _showNewThreadDialog() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => NewThreadDialog(
        existingThreadTitles: _threads.map((t) => t.title).toList(),
        maxTitleLength: 100,
        maxContentLength: widget.section.config?.maxSizeText ?? 5000,
      ),
    );

    if (result != null && mounted) {
      final profile = widget.profileService.getProfile();
      if (profile.callsign.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No active callsign. Please set up your profile first.'),
          ),
        );
        return;
      }

      // Load settings and check if signing is enabled
      final settings = await _loadForumSettings();
      Map<String, String> metadata = {};
      final signingService = SigningService();
      await signingService.initialize();
      if (settings['signMessages'] == true &&
          profile.npub.isNotEmpty &&
          signingService.canSign(profile)) {
        metadata['npub'] = profile.npub;
        final signature = await signingService.generateSignature(
          result['content']!,
          metadata,
          profile,
        );
        if (signature != null && signature.isNotEmpty) {
          metadata['signature'] = signature;
        }
      }

      final originalPost = ForumPost.now(
        author: profile.callsign,
        content: result['content']!,
        isOriginalPost: true,
        metadata: metadata.isNotEmpty ? metadata : null,
      );

      final thread = await widget.forumService.createThread(
        widget.section.id,
        result['title']!,
        originalPost,
      );

      _hasChanges = true;
      await _reloadThreads();

      // Navigate to the new thread
      final newThread = _threads.firstWhere(
        (t) => t.id == thread.id,
        orElse: () => thread,
      );
      await _selectThread(newThread);
    }
  }

  Future<Map<String, dynamic>> _loadForumSettings() async {
    try {
      final storagePath = widget.collection.storagePath;
      if (storagePath == null) return {};

      final settingsFile = File(path.join(storagePath, 'extra', 'settings.json'));
      if (!await settingsFile.exists()) {
        return {};
      }

      final content = await settingsFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return json;
    } catch (e) {
      return {};
    }
  }

  void _showThreadMenu(ForumThread thread) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.delete,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete thread',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteThread(thread);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteThread(ForumThread thread) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Thread'),
        content: Text(
          'Are you sure you want to delete the thread "${thread.title}"? '
          'This will permanently delete all posts in this thread.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final profile = widget.profileService.getProfile();
      await widget.forumService.deleteThread(
        sectionId: widget.section.id,
        threadId: thread.id,
        userNpub: profile.npub,
      );

      _hasChanges = true;
      await _reloadThreads();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Thread deleted successfully')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        if (didPop && _hasChanges) {
          Navigator.of(context).pop(true);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.section.name),
        ),
        body: _buildFullWidthThreadList(theme),
      ),
    );
  }

  Widget _buildFullWidthThreadList(ThemeData theme) {
    // Build a full-width thread list for mobile view
    final sortedThreads = List<ForumThread>.from(_threads);
    sortedThreads.sort();

    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant,
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.topic, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Threads',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (_canCreateThread)
                  FilledButton.icon(
                    onPressed: _showNewThreadDialog,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
              ],
            ),
          ),
          // Thread list
          Expanded(
            child: sortedThreads.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 64,
                          color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No threads yet',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (_canCreateThread) ...[
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _showNewThreadDialog,
                            icon: const Icon(Icons.add),
                            label: const Text('Create first thread'),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: sortedThreads.length,
                    itemBuilder: (context, index) {
                      final thread = sortedThreads[index];

                      return ListTile(
                        leading: Icon(
                          thread.isPinned ? Icons.push_pin : Icons.comment,
                          color: thread.isPinned
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                thread.title,
                                style: TextStyle(
                                  fontWeight: thread.isPinned
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                            if (thread.isLocked)
                              Icon(
                                Icons.lock,
                                size: 16,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                          ],
                        ),
                        subtitle: Text(
                          'Started by ${thread.author} • ${thread.replyCount + 1} posts',
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: widget.isAdmin
                            ? IconButton(
                                icon: const Icon(Icons.more_vert),
                                onPressed: () => _showThreadMenu(thread),
                              )
                            : null,
                        onTap: () => _selectThread(thread),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen posts page for mobile view
class _PostsPage extends StatefulWidget {
  final ForumSection section;
  final ForumThread thread;
  final List<ForumPost> posts;
  final ForumService forumService;
  final ProfileService profileService;
  final Collection collection;
  final bool isAdmin;

  const _PostsPage({
    Key? key,
    required this.section,
    required this.thread,
    required this.posts,
    required this.forumService,
    required this.profileService,
    required this.collection,
    required this.isAdmin,
  }) : super(key: key);

  @override
  State<_PostsPage> createState() => _PostsPageState();
}

class _PostsPageState extends State<_PostsPage> {
  late List<ForumPost> _posts;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _posts = widget.posts;
  }

  Future<void> _sendPost(String content, String? filePath) async {
    final profile = widget.profileService.getProfile();
    if (profile.callsign.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No active callsign. Please set up your profile first.'),
        ),
      );
      return;
    }

    try {
      Map<String, String> metadata = {};

      // Handle file attachment
      String? attachedFileName;
      if (filePath != null) {
        attachedFileName = await _copyFileToThread(filePath);
        if (attachedFileName != null) {
          metadata['file'] = attachedFileName;
        }
      }

      // Load settings and check if signing is enabled
      final settings = await _loadForumSettings();
      final signingService = SigningService();
      await signingService.initialize();
      if (settings['signMessages'] == true &&
          profile.npub.isNotEmpty &&
          signingService.canSign(profile)) {
        metadata['npub'] = profile.npub;
        final signature = await signingService.generateSignature(
          content,
          metadata,
          profile,
        );
        if (signature != null && signature.isNotEmpty) {
          metadata['signature'] = signature;
        }
      }

      final post = ForumPost.now(
        author: profile.callsign,
        content: content,
        isOriginalPost: false,
        metadata: metadata.isNotEmpty ? metadata : null,
      );

      await widget.forumService.addReply(
        widget.section.id,
        widget.thread.id,
        post,
      );

      _hasChanges = true;
      setState(() {
        _posts.add(post);
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Post added successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send post: $e')),
        );
      }
    }
  }

  Future<Map<String, dynamic>> _loadForumSettings() async {
    try {
      final storagePath = widget.collection.storagePath;
      if (storagePath == null) return {};

      final settingsFile = File(path.join(storagePath, 'extra', 'settings.json'));
      if (!await settingsFile.exists()) {
        return {};
      }

      final content = await settingsFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return json;
    } catch (e) {
      return {};
    }
  }

  Future<String?> _copyFileToThread(String sourceFilePath) async {
    try {
      final sourceFile = File(sourceFilePath);
      if (!await sourceFile.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File not found')),
          );
        }
        return null;
      }

      final storagePath = widget.collection.storagePath;
      if (storagePath == null) {
        return null;
      }

      final bytes = await sourceFile.readAsBytes();
      final hash = sha1.convert(bytes);
      final sha1Hash = hash.toString();

      final filesPath = path.join(
        storagePath,
        widget.section.folder,
        'files',
      );

      final filesDir = Directory(filesPath);
      if (!await filesDir.exists()) {
        await filesDir.create(recursive: true);
      }

      String originalFileName = path.basename(sourceFilePath);
      if (originalFileName.length > 100) {
        final ext = path.extension(originalFileName);
        final nameWithoutExt = path.basenameWithoutExtension(originalFileName);
        final maxNameLength = 100 - ext.length;
        originalFileName = nameWithoutExt.substring(0, maxNameLength) + ext;
      }

      final newFileName = '${sha1Hash}_$originalFileName';
      final destPath = path.join(filesDir.path, newFileName);
      final destFile = File(destPath);

      await sourceFile.copy(destFile.path);

      return newFileName;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to copy file: $e')),
        );
      }
      return null;
    }
  }

  bool _canDeletePost(ForumPost post) {
    final profile = widget.profileService.getProfile();
    final userNpub = profile.npub;
    return widget.forumService.security.canModerate(userNpub, widget.section.id);
  }

  Future<void> _deletePost(ForumPost post) async {
    try {
      final profile = widget.profileService.getProfile();
      final userNpub = profile.npub;

      await widget.forumService.deletePost(
        widget.section.id,
        widget.thread.id,
        post,
        userNpub,
      );

      _hasChanges = true;
      setState(() {
        _posts.removeWhere((p) =>
            p.timestamp == post.timestamp && p.author == post.author);
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Post deleted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete post: $e')),
        );
      }
    }
  }

  Future<void> _openAttachedFile(ForumPost post) async {
    if (!post.hasFile) return;

    try {
      final storagePath = widget.collection.storagePath;
      if (storagePath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Collection storage path is null')),
          );
        }
        return;
      }

      final filePath = path.join(
        storagePath,
        widget.section.folder,
        'files',
        post.attachedFile!,
      );

      final file = File(filePath);
      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('File not found: ${post.attachedFile}')),
          );
        }
        return;
      }

      if (Platform.isLinux) {
        await Process.run('xdg-open', [filePath]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [filePath]);
      } else if (Platform.isWindows) {
        await Process.run('start', [filePath], runInShell: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open file: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        if (didPop && _hasChanges) {
          Navigator.of(context).pop(true);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.thread.title),
        ),
        body: Column(
          children: [
            Expanded(
              child: PostListWidget(
                posts: _posts,
                threadTitle: widget.thread.title,
                onFileOpen: _openAttachedFile,
                onPostDelete: _deletePost,
                canDeletePost: _canDeletePost,
              ),
            ),
            PostInputWidget(
              onSend: _sendPost,
              maxLength: widget.section.config?.maxSizeText ?? 5000,
              allowFiles: widget.section.config?.fileUpload ?? true,
              isLocked: widget.thread.isLocked,
              hintText: 'Write a reply...',
            ),
          ],
        ),
      ),
    );
  }
}
