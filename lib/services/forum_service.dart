/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'package:path/path.dart' as path;
import '../models/forum_section.dart';
import '../models/forum_thread.dart';
import '../models/forum_post.dart';
import '../models/chat_security.dart';
import '../util/chat_format.dart';
import 'profile_storage.dart';

/// Service for managing forum collections and posts
///
/// IMPORTANT: All file operations go through the ProfileStorage abstraction.
/// Never use File() or Directory() directly in this service.
class ForumService {
  static final ForumService _instance = ForumService._internal();
  factory ForumService() => _instance;
  ForumService._internal();

  /// Profile storage for file operations (encrypted or filesystem)
  /// MUST be set before using the service.
  late ProfileStorage _storage;

  /// Loaded sections
  List<ForumSection> _sections = [];

  /// Security settings (admin/moderators)
  ChatSecurity _security = ChatSecurity();

  /// Whether using encrypted storage
  bool get useEncryptedStorage => _storage.isEncrypted;

  /// Set the profile storage for file operations
  /// MUST be called before initializeApp
  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  /// Initialize forum service for a collection
  Future<void> initializeApp(String appPath, {String? creatorNpub}) async {
    print('ForumService: Initializing with collection path: $appPath');
    await _loadSections();
    await _loadSecurity();

    // If this is a new forum (no admin set) and creator npub provided, set as admin
    if (_security.adminNpub == null && creatorNpub != null && creatorNpub.isNotEmpty) {
      print('ForumService: Setting creator as admin: $creatorNpub');
      final newSecurity = ChatSecurity(adminNpub: creatorNpub);
      await saveSecurity(newSecurity);
    }
  }

  /// Get loaded sections
  List<ForumSection> get sections => List.unmodifiable(_sections);

  /// Get security settings
  ChatSecurity get security => _security;

  /// Load sections from sections.json
  Future<void> _loadSections() async {
    final content = await _storage.readString('extra/sections.json');

    if (content == null) {
      // Create default sections if file doesn't exist
      _sections = _createDefaultSections();
      await _saveSections();
      return;
    }

    try {
      final json = jsonDecode(content) as Map<String, dynamic>;
      final sectionsList = json['sections'] as List;

      _sections = sectionsList
          .map((s) => ForumSection.fromJson(s as Map<String, dynamic>))
          .toList();

      // Sort by order
      _sections.sort();
    } catch (e) {
      print('Error loading sections: $e');
      _sections = _createDefaultSections();
    }
  }

  /// Create default sections
  List<ForumSection> _createDefaultSections() {
    return [
      ForumSection(
        id: 'announcements',
        name: 'Announcements',
        folder: 'announcements',
        description: 'Official announcements and updates',
        order: 1,
        readonly: false,
      ),
      ForumSection(
        id: 'general',
        name: 'General Discussion',
        folder: 'general',
        description: 'General topics and community discussion',
        order: 2,
        readonly: false,
      ),
      ForumSection(
        id: 'help',
        name: 'Help & Support',
        folder: 'help',
        description: 'Get help and support from the community',
        order: 3,
        readonly: false,
      ),
    ];
  }

  /// Save sections to sections.json
  Future<void> _saveSections() async {
    final json = {
      'version': '1.0',
      'sections': _sections.map((s) => s.toJson()).toList(),
    };
    final content = const JsonEncoder.withIndent('  ').convert(json);

    if (!await _storage.exists('extra')) {
      await _storage.createDirectory('extra');
    }
    await _storage.writeString('extra/sections.json', content);
  }

  /// Load security settings from security.json
  Future<void> _loadSecurity() async {
    final content = await _storage.readString('extra/security.json');

    if (content == null) {
      // New forum - create empty security (admin will be set when needed)
      _security = ChatSecurity();
      return;
    }

    try {
      final json = jsonDecode(content) as Map<String, dynamic>;
      _security = ChatSecurity.fromJson(json);
    } catch (e) {
      print('Error loading security: $e');
      _security = ChatSecurity();
    }
  }

  /// Save security settings to security.json
  Future<void> saveSecurity(ChatSecurity security) async {
    _security = security;

    final json = {
      'version': '1.0',
      ..._security.toJson(),
    };
    final content = const JsonEncoder.withIndent('  ').convert(json);

    if (!await _storage.exists('extra')) {
      await _storage.createDirectory('extra');
    }
    await _storage.writeString('extra/security.json', content);
  }

  /// Get section by ID
  ForumSection? getSection(String sectionId) {
    try {
      return _sections.firstWhere((s) => s.id == sectionId);
    } catch (e) {
      return null;
    }
  }

  /// Load threads for a section
  Future<List<ForumThread>> loadThreads(String sectionId) async {
    final section = getSection(sectionId);
    if (section == null) return [];

    if (!await _storage.exists(section.folder)) {
      print('ForumService: Section directory does not exist');
      return [];
    }

    List<ForumThread> threads = [];

    final entries = await _storage.listDirectory(section.folder);
    final threadEntries = entries.where((e) =>
        !e.isDirectory &&
        e.name.endsWith('.txt') &&
        !e.name.endsWith('config.json'));

    print('ForumService: Found ${threadEntries.length} thread files');

    for (var entry in threadEntries) {
      try {
        final content = await _storage.readString(entry.path);
        if (content != null) {
          final thread = _parseThreadMetadataFromContent(content, sectionId, entry.path, entry.name);
          if (thread != null) {
            threads.add(thread);
          }
        }
      } catch (e) {
        print('Error parsing thread ${entry.path}: $e');
      }
    }

    // Sort threads (pinned first, then by last reply)
    threads.sort();

    return threads;
  }

  /// Parse thread metadata from content string
  ForumThread? _parseThreadMetadataFromContent(
      String content, String sectionId, String filePath, String filename) {
    try {
      final lines = content.split('\n');

      if (lines.length < 6) return null;

      // Parse header (with blank line after title)
      if (!lines[0].startsWith('# THREAD: ')) return null;
      final title = lines[0].substring(10).trim();

      // Skip blank line at index 1

      if (!lines[2].startsWith('AUTHOR: ')) return null;
      final author = lines[2].substring(8).trim();

      if (!lines[3].startsWith('CREATED: ')) return null;
      final createdStr = lines[3].substring(9).trim();
      final created = ChatFormat.parseTimestamp(createdStr);

      if (!lines[4].startsWith('SECTION: ')) return null;
      final section = lines[4].substring(9).trim();

      // Count replies (lines starting with "> 2")
      int replyCount = 0;
      DateTime lastReply = created;

      for (var line in lines) {
        if (line.trim().startsWith('> 2')) {
          replyCount++;
          // Extract timestamp from reply
          try {
            final parts = line.trim().substring(2).split(' -- ');
            if (parts.isNotEmpty) {
              final replyTimestamp = ChatFormat.parseTimestamp(parts[0].trim());
              if (replyTimestamp.isAfter(lastReply)) {
                lastReply = replyTimestamp;
              }
            }
          } catch (e) {
            // Skip invalid timestamp
          }
        }
      }

      final threadId = path.basenameWithoutExtension(filename);

      return ForumThread(
        id: threadId,
        title: title,
        sectionId: section,
        author: author,
        created: created,
        lastReply: lastReply,
        replyCount: replyCount,
        filePath: filePath,
      );
    } catch (e) {
      print('Error parsing thread metadata: $e');
      return null;
    }
  }

  /// Load posts for a thread
  Future<List<ForumPost>> loadPosts(String sectionId, String threadId) async {
    final section = getSection(sectionId);
    if (section == null) return [];

    final content = await _storage.readString('${section.folder}/$threadId.txt');
    if (content == null) return [];

    return parseThreadText(content);
  }

  /// Parse thread text content (static for testing)
  static List<ForumPost> parseThreadText(String content) {
    final lines = content.split('\n');
    if (lines.length < 6) return [];

    List<ForumPost> posts = [];

    // Skip header (first 6 lines: title, blank, author, created, section, blank)
    // Parse original post (everything until first reply marker)
    String author = '';
    String timestamp = '';

    if (lines[2].startsWith('AUTHOR: ')) {
      author = lines[2].substring(8).trim();
    }
    if (lines[3].startsWith('CREATED: ')) {
      timestamp = lines[3].substring(9).trim();
    }

    // Find content between header and first reply or end
    int contentStart = 6; // After 6-line header (title, blank, author, created, section, blank)
    int contentEnd = lines.length;

    // Find first reply marker
    for (int i = contentStart; i < lines.length; i++) {
      if (lines[i].trim().startsWith('> 2')) {
        contentEnd = i;
        break;
      }
    }

    // Extract original post
    final originalPost = _parsePostSection(
      lines.sublist(contentStart, contentEnd).join('\n'),
      author,
      timestamp,
      true,
    );

    if (originalPost != null) {
      posts.add(originalPost);
    }

    // Parse replies (split by "> 2" pattern)
    final repliesText = lines.sublist(contentEnd).join('\n');
    final replySections = repliesText.split('> 2');

    for (int i = 1; i < replySections.length; i++) {
      try {
        final section = '2${replySections[i]}'; // Restore the "2" prefix
        final reply = _parseReplySection(section);
        if (reply != null) {
          posts.add(reply);
        }
      } catch (e) {
        print('Error parsing reply section: $e');
        continue;
      }
    }

    return posts;
  }

  /// Parse post section (original post)
  static ForumPost? _parsePostSection(
    String section,
    String author,
    String timestamp,
    bool isOriginal,
  ) {
    if (section.trim().isEmpty) return null;

    final lines = section.split('\n');

    // Extract content and metadata
    StringBuffer contentBuffer = StringBuffer();
    Map<String, String> metadata = {};
    bool inContent = true;

    for (var line in lines) {
      if (line.trim().startsWith('--> ')) {
        inContent = false;
        // Parse metadata
        final metaLine = line.trim().substring(4); // Remove "--> "
        final colonIndex = metaLine.indexOf(': ');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex);
          final value = metaLine.substring(colonIndex + 2);
          metadata[key] = value;
        }
      } else if (inContent && line.trim().isNotEmpty) {
        if (contentBuffer.isNotEmpty) {
          contentBuffer.writeln();
        }
        contentBuffer.write(line);
      }
    }

    return ForumPost(
      author: author,
      timestamp: timestamp,
      content: contentBuffer.toString().trim(),
      isOriginalPost: isOriginal,
      metadata: metadata,
    );
  }

  /// Parse reply section
  static ForumPost? _parseReplySection(String section) {
    final lines = section.split('\n');
    if (lines.isEmpty) return null;

    // Parse header: "2025-11-21 15:15_23 -- CALLSIGN"
    final header = lines[0].trim();
    final parts = header.split(' -- ');
    if (parts.length != 2) return null;

    final timestamp = parts[0].trim();
    final author = parts[1].trim();

    return _parsePostSection(
      lines.sublist(1).join('\n'),
      author,
      timestamp,
      false,
    );
  }

  /// Create a new thread
  Future<ForumThread> createThread(
    String sectionId,
    String title,
    ForumPost originalPost,
  ) async {
    final section = getSection(sectionId);
    if (section == null) {
      throw Exception('Section not found: $sectionId');
    }

    // Sanitize title for filename
    final threadId = _sanitizeFilename(title);
    final threadFilePath = '${section.folder}/$threadId.txt';

    // Build thread content
    final buffer = StringBuffer();
    buffer.writeln('# THREAD: $title');
    buffer.writeln('');
    buffer.writeln('AUTHOR: ${originalPost.author}');
    buffer.writeln('CREATED: ${originalPost.timestamp}');
    buffer.writeln('SECTION: $sectionId');
    buffer.writeln('');
    buffer.write(originalPost.exportAsText());
    final content = buffer.toString();

    // Create section directory if needed
    if (!await _storage.exists(section.folder)) {
      await _storage.createDirectory(section.folder);
    }

    // Check if thread already exists
    if (await _storage.exists(threadFilePath)) {
      throw Exception('Thread already exists: $title');
    }

    print('ForumService: Creating thread file at: $threadFilePath');
    await _storage.writeString(threadFilePath, content);
    print('ForumService: Thread file created successfully');

    return ForumThread(
      id: threadId,
      title: title,
      sectionId: sectionId,
      author: originalPost.author,
      created: originalPost.dateTime,
      filePath: threadFilePath,
    );
  }

  /// Add reply to a thread
  Future<void> addReply(
    String sectionId,
    String threadId,
    ForumPost reply,
  ) async {
    final section = getSection(sectionId);
    if (section == null) {
      throw Exception('Section not found: $sectionId');
    }

    final threadFilePath = '${section.folder}/$threadId.txt';
    final replyText = '\n${reply.exportAsText()}\n';

    // Read-append-write pattern for storage abstraction
    final existingContent = await _storage.readString(threadFilePath);
    if (existingContent == null) {
      throw Exception('Thread not found: $threadId');
    }

    await _storage.writeString(threadFilePath, existingContent + replyText);
  }

  /// Delete a post (admin/moderator only)
  Future<void> deletePost(
    String sectionId,
    String threadId,
    ForumPost post,
    String? userNpub,
  ) async {
    // Check permissions
    if (!_security.canModerate(userNpub, sectionId)) {
      throw Exception('Insufficient permissions to delete post');
    }

    final section = getSection(sectionId);
    if (section == null) {
      throw Exception('Section not found: $sectionId');
    }

    final threadFilePath = '${section.folder}/$threadId.txt';

    if (!await _storage.exists(threadFilePath)) {
      throw Exception('Thread not found: $threadId');
    }

    // If deleting original post, delete entire thread
    if (post.isOriginalPost) {
      await _storage.delete(threadFilePath);
      return;
    }

    // Load all posts
    final content = await _storage.readString(threadFilePath);
    if (content == null) {
      throw Exception('Thread not found: $threadId');
    }

    final posts = parseThreadText(content);

    // Remove the target post
    posts.removeWhere((p) =>
        p.timestamp == post.timestamp &&
        p.author == post.author &&
        !p.isOriginalPost);

    // Rewrite file
    if (posts.isEmpty) {
      throw Exception('Cannot delete all posts');
    }

    await _rewriteThreadFile(threadFilePath, posts, content);
  }

  /// Rewrite thread file with updated posts
  Future<void> _rewriteThreadFile(
      String filePath, List<ForumPost> posts, String existingContent) async {
    if (posts.isEmpty) {
      throw Exception('Cannot write empty thread');
    }

    final lines = existingContent.split('\n');

    // Extract header (first 6 lines: title, blank, author, created, section, blank)
    final header = lines.take(6).join('\n');

    final buffer = StringBuffer();
    buffer.writeln(header);

    // Write original post (first post)
    buffer.write(posts[0].exportAsText());

    // Write replies
    for (int i = 1; i < posts.length; i++) {
      buffer.write('\n');
      buffer.write(posts[i].exportAsText());
    }

    await _storage.writeString(filePath, buffer.toString());
  }

  /// Sanitize filename
  String _sanitizeFilename(String name) {
    return 'thread-${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '-').replaceAll(RegExp(r'-+'), '-').replaceAll(RegExp(r'^-|-$'), '')}';
  }

  /// Refresh sections
  Future<void> refreshSections() async {
    await _loadSections();
    await _loadSecurity();
  }

  /// Create a new section (admin only)
  Future<ForumSection> createSection({
    required String id,
    required String name,
    String? description,
    int order = 999,
    bool readonly = false,
    String? adminNpub,
  }) async {
    // Check if user is admin
    if (adminNpub != null && _security.adminNpub != adminNpub) {
      throw Exception('Only admin can create sections');
    }

    // Check if section ID already exists
    if (_sections.any((s) => s.id == id)) {
      throw Exception('Section with ID "$id" already exists');
    }

    // Sanitize folder name
    final folder = id.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '-');

    // Create section config
    final config = ForumSectionConfig.defaults(
      id: id,
      name: name,
      description: description,
    );
    final configContent = const JsonEncoder.withIndent('  ').convert(config.toJson());

    await _storage.createDirectory(folder);
    await _storage.writeString('$folder/config.json', configContent);

    // Create section object
    final section = ForumSection(
      id: id,
      name: name,
      folder: folder,
      description: description,
      order: order,
      readonly: readonly,
      config: config,
    );

    // Update sections.json
    await _updateSectionsJson(section);

    // Reload sections
    await refreshSections();

    return section;
  }

  /// Rename a section (admin only)
  Future<void> renameSection({
    required String sectionId,
    required String newName,
    String? newDescription,
    String? adminNpub,
  }) async {
    // Check if user is admin
    if (adminNpub != null && _security.adminNpub != adminNpub) {
      throw Exception('Only admin can rename sections');
    }

    // Find section (used for validation)
    _sections.firstWhere(
      (s) => s.id == sectionId,
      orElse: () => throw Exception('Section not found'),
    );

    // Load and update sections.json
    final content = await _storage.readString('extra/sections.json');
    if (content == null) {
      throw Exception('Sections file not found');
    }

    final data = jsonDecode(content) as Map<String, dynamic>;

    final sections = (data['sections'] as List<dynamic>).map((s) {
      final sectionData = s as Map<String, dynamic>;
      if (sectionData['id'] == sectionId) {
        return {
          ...sectionData,
          'name': newName,
          if (newDescription != null) 'description': newDescription,
        };
      }
      return sectionData;
    }).toList();

    data['sections'] = sections;
    final updatedContent = const JsonEncoder.withIndent('  ').convert(data);

    await _storage.writeString('extra/sections.json', updatedContent);

    // Reload sections
    await refreshSections();
  }

  /// Delete a section (admin only)
  Future<void> deleteSection({
    required String sectionId,
    String? adminNpub,
  }) async {
    // Check if user is admin
    if (adminNpub != null && _security.adminNpub != adminNpub) {
      throw Exception('Only admin can delete sections');
    }

    // Find section
    final section = _sections.firstWhere(
      (s) => s.id == sectionId,
      orElse: () => throw Exception('Section not found'),
    );

    // Delete section folder and all its contents
    if (await _storage.exists(section.folder)) {
      await _storage.deleteDirectory(section.folder, recursive: true);
    }

    // Load and update sections.json
    final content = await _storage.readString('extra/sections.json');
    if (content == null) {
      throw Exception('Sections file not found');
    }

    final data = jsonDecode(content) as Map<String, dynamic>;

    final sections = (data['sections'] as List<dynamic>)
        .where((s) => (s as Map<String, dynamic>)['id'] != sectionId)
        .toList();

    data['sections'] = sections;
    final updatedContent = const JsonEncoder.withIndent('  ').convert(data);

    await _storage.writeString('extra/sections.json', updatedContent);

    // Reload sections
    await refreshSections();
  }

  /// Update sections.json with a new section
  Future<void> _updateSectionsJson(ForumSection section) async {
    Map<String, dynamic> data;
    final content = await _storage.readString('extra/sections.json');

    if (content != null) {
      data = jsonDecode(content) as Map<String, dynamic>;
    } else {
      data = {
        'version': '1.0',
        'sections': [],
      };
    }

    final sections = data['sections'] as List<dynamic>;
    sections.add({
      'id': section.id,
      'name': section.name,
      'folder': section.folder,
      if (section.description != null) 'description': section.description,
      'order': section.order,
      'readonly': section.readonly,
    });

    data['sections'] = sections;
    final updatedContent = const JsonEncoder.withIndent('  ').convert(data);

    await _storage.writeString('extra/sections.json', updatedContent);
  }

  /// Delete a thread (admin/moderator only)
  Future<void> deleteThread({
    required String sectionId,
    required String threadId,
    String? userNpub,
  }) async {
    // Check if user is admin (moderators not yet implemented for forums)
    if (userNpub != null && _security.adminNpub != userNpub) {
      throw Exception('Only admin can delete threads');
    }

    // Find section
    final section = getSection(sectionId);
    if (section == null) {
      throw Exception('Section not found');
    }

    final entries = await _storage.listDirectory(section.folder);
    final threadEntries = entries.where((e) =>
        !e.isDirectory &&
        e.name.endsWith('.txt') &&
        !e.name.endsWith('config.json'));

    String? threadPath;
    for (var entry in threadEntries) {
      try {
        final content = await _storage.readString(entry.path);
        if (content != null) {
          final thread = _parseThreadMetadataFromContent(content, sectionId, entry.path, entry.name);
          if (thread != null && thread.id == threadId) {
            threadPath = entry.path;
            break;
          }
        }
      } catch (e) {
        continue;
      }
    }

    if (threadPath == null) {
      throw Exception('Thread not found');
    }

    await _storage.delete(threadPath);
  }
}
