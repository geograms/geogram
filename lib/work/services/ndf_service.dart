/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../services/log_service.dart';
import '../models/ndf_document.dart';
import '../models/ndf_permission.dart';
import '../models/spreadsheet_content.dart';
import '../models/document_content.dart';
import '../models/form_content.dart';
import '../models/presentation_content.dart';
import '../models/todo_content.dart';
import '../models/voicememo_content.dart';
import '../models/meeting_content.dart';
import '../models/websnapshot_content.dart';
import '../models/accounting_content.dart';

/// Service for reading and writing NDF (Nostr Data Format) documents
class NdfService {
  // ============================================================
  // BYTES-BASED METHODS (for encrypted storage support)
  // ============================================================

  /// Read NDF metadata from bytes
  NdfDocument? readMetadataFromBytes(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);

      for (final entry in archive) {
        if (entry.name == 'ndf.json' && entry.isFile) {
          final content = utf8.decode(entry.content as List<int>);
          final json = jsonDecode(content) as Map<String, dynamic>;
          return NdfDocument.fromJson(json);
        }
      }

      LogService().log('NdfService: ndf.json not found in archive');
      return null;
    } catch (e) {
      LogService().log('NdfService: Error reading NDF metadata from bytes: $e');
      return null;
    }
  }

  /// Read a specific file from NDF archive bytes
  Uint8List? readArchiveFileFromBytes(Uint8List archiveBytes, String archivePath) {
    try {
      final archive = ZipDecoder().decodeBytes(archiveBytes);

      for (final entry in archive) {
        if (entry.name == archivePath && entry.isFile) {
          return Uint8List.fromList(entry.content as List<int>);
        }
      }

      return null;
    } catch (e) {
      LogService().log('NdfService: Error reading $archivePath from archive: $e');
      return null;
    }
  }

  /// Read JSON content from NDF archive bytes
  Map<String, dynamic>? readArchiveJsonFromBytes(Uint8List archiveBytes, String archivePath) {
    final bytes = readArchiveFileFromBytes(archiveBytes, archivePath);
    if (bytes == null) return null;

    try {
      final content = utf8.decode(bytes);
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      LogService().log('NdfService: Error parsing JSON from $archivePath: $e');
      return null;
    }
  }

  /// Read thumbnail bytes from NDF archive bytes
  Uint8List? readThumbnailFromBytes(Uint8List archiveBytes) {
    try {
      final archive = ZipDecoder().decodeBytes(archiveBytes);

      // Find ndf.json first to get thumbnail reference
      NdfDocument? metadata;
      for (final entry in archive) {
        if (entry.name == 'ndf.json' && entry.isFile) {
          final content = utf8.decode(entry.content as List<int>);
          final json = jsonDecode(content) as Map<String, dynamic>;
          metadata = NdfDocument.fromJson(json);
          break;
        }
      }

      if (metadata?.thumbnail == null) return null;

      final thumbRef = metadata!.thumbnail!;
      if (!thumbRef.startsWith('asset://')) return null;

      final assetPath = 'assets/${thumbRef.substring(8)}';
      return readArchiveFileFromBytes(archiveBytes, assetPath);
    } catch (e) {
      LogService().log('NdfService: Error reading thumbnail from bytes: $e');
      return null;
    }
  }

  /// Read logo bytes from NDF archive bytes
  Uint8List? readLogoFromBytes(Uint8List archiveBytes) {
    try {
      final archive = ZipDecoder().decodeBytes(archiveBytes);

      // Find ndf.json first to get logo reference
      NdfDocument? metadata;
      for (final entry in archive) {
        if (entry.name == 'ndf.json' && entry.isFile) {
          final content = utf8.decode(entry.content as List<int>);
          final json = jsonDecode(content) as Map<String, dynamic>;
          metadata = NdfDocument.fromJson(json);
          break;
        }
      }

      if (metadata?.logo == null) return null;

      final logoRef = metadata!.logo!;
      if (!logoRef.startsWith('asset://')) return null;

      final assetPath = 'assets/${logoRef.substring(8)}';
      return readArchiveFileFromBytes(archiveBytes, assetPath);
    } catch (e) {
      LogService().log('NdfService: Error reading logo from bytes: $e');
      return null;
    }
  }

  /// Create a new NDF document and return as bytes
  Uint8List createDocumentAsBytes({
    required NdfDocument metadata,
    required NdfPermission permissions,
    Map<String, dynamic>? mainContent,
  }) {
    final archive = Archive();

    // Add ndf.json
    final ndfJson = utf8.encode(metadata.toJsonString());
    archive.addFile(ArchiveFile('ndf.json', ndfJson.length, ndfJson));

    // Add permissions.json
    final permissionsJson = utf8.encode(permissions.toJsonString());
    archive.addFile(ArchiveFile('permissions.json', permissionsJson.length, permissionsJson));

    // Add content/main.json if provided
    if (mainContent != null) {
      final mainJson = utf8.encode(const JsonEncoder.withIndent('  ').convert(mainContent));
      archive.addFile(ArchiveFile('content/main.json', mainJson.length, mainJson));
    }

    // Create default content based on document type
    if (mainContent == null) {
      final defaultContent = _createDefaultContent(metadata.type, metadata.title);
      final contentJson = utf8.encode(const JsonEncoder.withIndent('  ').convert(defaultContent));
      archive.addFile(ArchiveFile('content/main.json', contentJson.length, contentJson));

      // For presentations, also create the initial slide
      if (metadata.type == NdfDocumentType.presentation) {
        final initialSlide = PresentationSlide.title(
          id: 'slide-001',
          index: 0,
          title: metadata.title,
        );
        final slideJson = utf8.encode(initialSlide.toJsonString());
        archive.addFile(ArchiveFile('content/slides/slide-001.json', slideJson.length, slideJson));
      }
    }

    // Create empty directories structure
    _addEmptyDirectories(archive);

    // Encode the ZIP
    final zipData = ZipEncoder().encode(archive);
    if (zipData == null) {
      throw Exception('Failed to encode NDF archive');
    }

    return Uint8List.fromList(zipData);
  }

  // ============================================================
  // FILE-BASED METHODS (original implementations)
  // ============================================================

  /// Read NDF metadata from a file
  Future<NdfDocument?> readMetadata(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }

      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // Find ndf.json in archive
      for (final entry in archive) {
        if (entry.name == 'ndf.json' && entry.isFile) {
          final content = utf8.decode(entry.content as List<int>);
          final json = jsonDecode(content) as Map<String, dynamic>;
          return NdfDocument.fromJson(json);
        }
      }

      LogService().log('NdfService: ndf.json not found in $filePath');
      return null;
    } catch (e) {
      LogService().log('NdfService: Error reading NDF metadata from $filePath: $e');
      return null;
    }
  }

  /// Read NDF permissions from a file
  Future<NdfPermission?> readPermissions(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }

      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // Find permissions.json in archive
      for (final entry in archive) {
        if (entry.name == 'permissions.json' && entry.isFile) {
          final content = utf8.decode(entry.content as List<int>);
          final json = jsonDecode(content) as Map<String, dynamic>;
          return NdfPermission.fromJson(json);
        }
      }

      LogService().log('NdfService: permissions.json not found in $filePath');
      return null;
    } catch (e) {
      LogService().log('NdfService: Error reading NDF permissions from $filePath: $e');
      return null;
    }
  }

  /// Read a specific file from an NDF archive
  Future<Uint8List?> readArchiveFile(String filePath, String archivePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }

      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      for (final entry in archive) {
        if (entry.name == archivePath && entry.isFile) {
          return Uint8List.fromList(entry.content as List<int>);
        }
      }

      return null;
    } catch (e) {
      LogService().log('NdfService: Error reading $archivePath from $filePath: $e');
      return null;
    }
  }

  /// Read JSON content from an NDF archive
  Future<Map<String, dynamic>?> readArchiveJson(String filePath, String archivePath) async {
    final bytes = await readArchiveFile(filePath, archivePath);
    if (bytes == null) return null;

    try {
      final content = utf8.decode(bytes);
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      LogService().log('NdfService: Error parsing JSON from $archivePath: $e');
      return null;
    }
  }

  /// Create a new NDF document
  Future<String> createDocument({
    required String outputPath,
    required NdfDocument metadata,
    required NdfPermission permissions,
    Map<String, dynamic>? mainContent,
  }) async {
    final archive = Archive();

    // Add ndf.json
    final ndfJson = utf8.encode(metadata.toJsonString());
    archive.addFile(ArchiveFile('ndf.json', ndfJson.length, ndfJson));

    // Add permissions.json
    final permissionsJson = utf8.encode(permissions.toJsonString());
    archive.addFile(ArchiveFile('permissions.json', permissionsJson.length, permissionsJson));

    // Add content/main.json if provided
    if (mainContent != null) {
      final mainJson = utf8.encode(const JsonEncoder.withIndent('  ').convert(mainContent));
      archive.addFile(ArchiveFile('content/main.json', mainJson.length, mainJson));
    }

    // Create default content based on document type
    if (mainContent == null) {
      final defaultContent = _createDefaultContent(metadata.type, metadata.title);
      final contentJson = utf8.encode(const JsonEncoder.withIndent('  ').convert(defaultContent));
      archive.addFile(ArchiveFile('content/main.json', contentJson.length, contentJson));

      // For presentations, also create the initial slide
      if (metadata.type == NdfDocumentType.presentation) {
        final initialSlide = PresentationSlide.title(
          id: 'slide-001',
          index: 0,
          title: metadata.title,
        );
        final slideJson = utf8.encode(initialSlide.toJsonString());
        archive.addFile(ArchiveFile('content/slides/slide-001.json', slideJson.length, slideJson));
      }
    }

    // Create empty directories structure
    _addEmptyDirectories(archive);

    // Write the ZIP file
    final zipData = ZipEncoder().encode(archive);
    if (zipData == null) {
      throw Exception('Failed to encode NDF archive');
    }

    final file = File(outputPath);
    await file.writeAsBytes(zipData);

    LogService().log('NdfService: Created NDF document at $outputPath');
    return outputPath;
  }

  /// Add empty directory placeholders
  /// Note: ZIP archives don't support truly empty directories.
  /// Directory structure is created implicitly by file paths in the archive.
  void _addEmptyDirectories(Archive archive) {
    // This method is intentionally a no-op.
    // In the future, we could add .gitkeep-like placeholder files
    // if we need to preserve empty directory structure.
  }

  /// Create default content based on document type
  Map<String, dynamic> _createDefaultContent(NdfDocumentType type, String title) {
    switch (type) {
      case NdfDocumentType.spreadsheet:
        return {
          'type': 'spreadsheet',
          'active_sheet': 'sheet-001',
          'sheets': ['sheet-001'],
          'named_ranges': {},
          'global_styles': {
            'default': {
              'font': {'family': 'sans-serif', 'size': 11},
              'alignment': {'h': 'left', 'v': 'middle'},
            },
          },
        };

      case NdfDocumentType.document:
        return {
          'type': 'document',
          'schema': 'ndf-richtext-1.0',
          'content': [
            {
              'type': 'heading',
              'level': 1,
              'id': 'h-001',
              'content': [{'type': 'text', 'value': title}],
            },
            {
              'type': 'paragraph',
              'id': 'p-001',
              'content': [{'type': 'text', 'value': ''}],
            },
          ],
          'styles': {
            'page': {
              'size': 'A4',
              'margins': {'top': 72, 'bottom': 72, 'left': 72, 'right': 72},
            },
          },
        };

      case NdfDocumentType.presentation:
        return {
          'type': 'presentation',
          'schema': 'ndf-slides-1.0',
          'aspect_ratio': '16:9',
          'dimensions': {'width': 1920, 'height': 1080},
          'slides': ['slide-001'],
          'theme': {
            'colors': {
              'primary': '#1E3A5F',
              'secondary': '#4A90D9',
              'accent': '#F5A623',
              'background': '#FFFFFF',
              'text': '#333333',
            },
            'fonts': {
              'heading': {'family': 'sans-serif', 'weight': 700},
              'body': {'family': 'sans-serif', 'weight': 400},
            },
          },
          'transitions': {
            'default': {'type': 'fade', 'duration': 300},
          },
        };

      case NdfDocumentType.form:
        final now = DateTime.now();
        return {
          'type': 'form',
          'id': 'form-${now.millisecondsSinceEpoch.toRadixString(36)}',
          'schema': 'ndf-form-1.0',
          'title': title,
          'description': '',
          'version': 1,
          'created': now.toIso8601String(),
          'modified': now.toIso8601String(),
          'settings': {
            'allow_anonymous': false,
            'require_signature': true,
            'multiple_submissions': false,
            'editable_after_submit': false,
          },
          'fields': [],
          'layout': {
            'type': 'linear',
          },
        };

      case NdfDocumentType.todo:
        final now = DateTime.now();
        return {
          'type': 'todo',
          'id': 'todo-${now.millisecondsSinceEpoch.toRadixString(36)}',
          'schema': 'ndf-todo-1.0',
          'title': title,
          'version': 1,
          'created': now.toIso8601String(),
          'modified': now.toIso8601String(),
          'settings': {
            'show_completed': true,
            'sort_order': 'createdDesc',
            'default_expanded': false,
          },
          'items': [],
        };

      case NdfDocumentType.voicememo:
        final now = DateTime.now();
        return {
          'type': 'voicememo',
          'id': 'voicememo-${now.millisecondsSinceEpoch.toRadixString(36)}',
          'schema': 'ndf-voicememo-1.0',
          'title': title,
          'version': 1,
          'created': now.toIso8601String(),
          'modified': now.toIso8601String(),
          'settings': {
            'allow_comments': true,
            'allow_ratings': true,
            'rating_type': 'both',
            'default_sort': 'recordedDesc',
            'show_transcriptions': true,
          },
          'clips': [],
        };

      case NdfDocumentType.websnapshot:
        final now = DateTime.now();
        return {
          'type': 'websnapshot',
          'id': 'websnapshot-${now.millisecondsSinceEpoch.toRadixString(36)}',
          'schema': 'ndf-websnapshot-1.0',
          'title': title,
          'target_url': '',
          'version': 1,
          'created': now.toIso8601String(),
          'modified': now.toIso8601String(),
          'settings': {
            'default_depth': 'single',
            'include_scripts': true,
            'include_styles': true,
            'include_images': true,
            'include_fonts': true,
            'max_asset_size_mb': 10,
          },
          'snapshots': [],
        };

      case NdfDocumentType.meeting:
        return MeetingContent.create(title: title).toJson();

      case NdfDocumentType.accounting:
        final now = DateTime.now();
        return {
          'type': 'accounting',
          'id': 'acct-${now.millisecondsSinceEpoch.toRadixString(36)}',
          'schema': 'ndf-accounting-1.0',
          'title': title,
          'version': 1,
          'created': now.toIso8601String(),
          'modified': now.toIso8601String(),
          'currency': 'EUR',
          'settings': {
            'sort_order': 'dateDesc',
            'view_period': 'monthly',
            'show_chart': true,
          },
          'entries': [],
          'custom_categories': [],
        };
    }
  }

  /// Update NDF metadata in an existing file
  Future<void> updateMetadata(String filePath, NdfDocument metadata) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('NDF file not found: $filePath');
    }

    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // Create new archive with updated metadata
    final newArchive = Archive();

    for (final entry in archive) {
      if (entry.name == 'ndf.json') {
        // Replace with new metadata
        final ndfJson = utf8.encode(metadata.toJsonString());
        newArchive.addFile(ArchiveFile('ndf.json', ndfJson.length, ndfJson));
      } else {
        // Copy existing entry
        newArchive.addFile(entry);
      }
    }

    // Write updated archive
    final zipData = ZipEncoder().encode(newArchive);
    if (zipData == null) {
      throw Exception('Failed to encode updated NDF archive');
    }

    await file.writeAsBytes(zipData);
    LogService().log('NdfService: Updated metadata in $filePath');
  }

  /// List all files in an NDF archive
  Future<List<String>> listArchiveFiles(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return [];
      }

      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      return archive.map((e) => e.name).toList();
    } catch (e) {
      LogService().log('NdfService: Error listing archive files from $filePath: $e');
      return [];
    }
  }

  // ============================================================
  // SPREADSHEET CONTENT METHODS
  // ============================================================

  /// Read spreadsheet main content
  Future<SpreadsheetContent?> readSpreadsheetContent(String filePath) async {
    final json = await readArchiveJson(filePath, 'content/main.json');
    if (json == null) return null;
    try {
      return SpreadsheetContent.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing spreadsheet content: $e');
      return null;
    }
  }

  /// Read a spreadsheet sheet
  Future<SpreadsheetSheet?> readSheet(String filePath, String sheetId) async {
    final json = await readArchiveJson(filePath, 'content/$sheetId.json');
    if (json == null) return null;
    try {
      return SpreadsheetSheet.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing sheet $sheetId: $e');
      return null;
    }
  }

  /// Save spreadsheet content and sheets
  Future<void> saveSpreadsheet(
    String filePath,
    SpreadsheetContent content,
    Map<String, SpreadsheetSheet> sheets,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/main.json': content.toJsonString(),
      for (final entry in sheets.entries)
        'content/${entry.key}.json': entry.value.toJsonString(),
    });
  }

  /// Save a single sheet
  Future<void> saveSheet(
    String filePath,
    SpreadsheetSheet sheet,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/${sheet.id}.json': sheet.toJsonString(),
    });
  }

  // ============================================================
  // DOCUMENT CONTENT METHODS
  // ============================================================

  /// Read document content
  Future<DocumentContent?> readDocumentContent(String filePath) async {
    final json = await readArchiveJson(filePath, 'content/main.json');
    if (json == null) return null;
    try {
      return DocumentContent.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing document content: $e');
      return null;
    }
  }

  /// Save document content
  Future<void> saveDocumentContent(
    String filePath,
    DocumentContent content,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/main.json': content.toJsonString(),
    });
  }

  // ============================================================
  // FORM CONTENT METHODS
  // ============================================================

  /// Read form content
  Future<FormContent?> readFormContent(String filePath) async {
    final json = await readArchiveJson(filePath, 'content/main.json');
    if (json == null) return null;
    try {
      return FormContent.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing form content: $e');
      return null;
    }
  }

  /// Save form content
  Future<void> saveFormContent(
    String filePath,
    FormContent content,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/main.json': content.toJsonString(),
    });
  }

  /// Read form responses
  Future<List<FormResponse>> readFormResponses(String filePath) async {
    final files = await listArchiveFiles(filePath);
    final responses = <FormResponse>[];

    for (final file in files) {
      if (file.startsWith('social/responses/') && file.endsWith('.json')) {
        final json = await readArchiveJson(filePath, file);
        if (json != null) {
          try {
            responses.add(FormResponse.fromJson(json));
          } catch (e) {
            LogService().log('NdfService: Error parsing response $file: $e');
          }
        }
      }
    }

    // Sort by submission date (newest first)
    responses.sort((a, b) => b.submittedAt.compareTo(a.submittedAt));
    return responses;
  }

  /// Save a form response
  Future<void> saveFormResponse(
    String filePath,
    FormResponse response,
  ) async {
    await _updateArchiveFiles(filePath, {
      'social/responses/${response.id}.json': response.toJsonString(),
    });
  }

  /// Read the responses spreadsheet
  Future<SpreadsheetSheet?> readResponsesSpreadsheet(String filePath) async {
    final json = await readArchiveJson(filePath, 'content/responses-sheet.json');
    if (json == null) return null;
    try {
      return SpreadsheetSheet.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing responses spreadsheet: $e');
      return null;
    }
  }

  /// Save the responses spreadsheet
  Future<void> saveResponsesSpreadsheet(
    String filePath,
    SpreadsheetSheet sheet,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/responses-sheet.json': sheet.toJsonString(),
    });
  }

  // ============================================================
  // PRESENTATION CONTENT METHODS
  // ============================================================

  /// Read presentation main content
  Future<PresentationContent?> readPresentationContent(String filePath) async {
    final json = await readArchiveJson(filePath, 'content/main.json');
    if (json == null) return null;
    try {
      return PresentationContent.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing presentation content: $e');
      return null;
    }
  }

  /// Read a presentation slide
  Future<PresentationSlide?> readSlide(String filePath, String slideId) async {
    final json = await readArchiveJson(filePath, 'content/slides/$slideId.json');
    if (json == null) return null;
    try {
      return PresentationSlide.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing slide $slideId: $e');
      return null;
    }
  }

  /// Save presentation content and slides
  Future<void> savePresentation(
    String filePath,
    PresentationContent content,
    Map<String, PresentationSlide> slides,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/main.json': content.toJsonString(),
      for (final entry in slides.entries)
        'content/slides/${entry.key}.json': entry.value.toJsonString(),
    });
  }

  /// Save a single presentation slide
  Future<void> savePresentationSlide(
    String filePath,
    PresentationSlide slide,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/slides/${slide.id}.json': slide.toJsonString(),
    });
  }

  /// Delete a presentation slide
  Future<void> deletePresentationSlide(
    String filePath,
    String slideId,
  ) async {
    await deleteArchiveFiles(filePath, ['content/slides/$slideId.json']);
  }

  // ============================================================
  // TODO CONTENT METHODS
  // ============================================================

  /// Read TODO main content
  Future<TodoContent?> readTodoContent(String filePath) async {
    final json = await readArchiveJson(filePath, 'content/main.json');
    if (json == null) return null;
    try {
      return TodoContent.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing TODO content: $e');
      return null;
    }
  }

  /// Read a TODO item
  Future<TodoItem?> readTodoItem(String filePath, String itemId) async {
    final json = await readArchiveJson(filePath, 'content/items/$itemId.json');
    if (json == null) return null;
    try {
      return TodoItem.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing TODO item $itemId: $e');
      return null;
    }
  }

  /// Read all TODO items
  Future<List<TodoItem>> readTodoItems(String filePath, List<String> itemIds) async {
    final items = <TodoItem>[];
    for (final itemId in itemIds) {
      final item = await readTodoItem(filePath, itemId);
      if (item != null) {
        items.add(item);
      }
    }
    return items;
  }

  /// Save TODO content and items
  Future<void> saveTodo(
    String filePath,
    TodoContent content,
    List<TodoItem> items,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/main.json': content.toJsonString(),
      for (final item in items)
        'content/items/${item.id}.json': item.toJsonString(),
    });
  }

  /// Save a single TODO item
  Future<void> saveTodoItem(
    String filePath,
    TodoItem item,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/items/${item.id}.json': item.toJsonString(),
    });
  }

  /// Delete a TODO item
  Future<void> deleteTodoItem(
    String filePath,
    String itemId,
  ) async {
    await deleteArchiveFiles(filePath, ['content/items/$itemId.json']);
  }

  // ============================================================
  // ACCOUNTING CONTENT METHODS
  // ============================================================

  /// Read accounting content from main.json
  Future<AccountingContent?> readAccountingContent(String filePath) async {
    final json = await readArchiveJson(filePath, 'content/main.json');
    if (json == null) return null;
    try {
      return AccountingContent.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing accounting content: $e');
      return null;
    }
  }

  /// Read a single accounting entry
  Future<AccountingEntry?> readAccountingEntry(String filePath, String entryId) async {
    final json = await readArchiveJson(filePath, 'content/entries/$entryId.json');
    if (json == null) return null;
    try {
      return AccountingEntry.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing accounting entry $entryId: $e');
      return null;
    }
  }

  /// Read all accounting entries
  Future<List<AccountingEntry>> readAccountingEntries(String filePath, List<String> entryIds) async {
    final entries = <AccountingEntry>[];
    for (final entryId in entryIds) {
      final entry = await readAccountingEntry(filePath, entryId);
      if (entry != null) {
        entries.add(entry);
      }
    }
    return entries;
  }

  /// Save accounting content and entries
  Future<void> saveAccounting(
    String filePath,
    AccountingContent content,
    List<AccountingEntry> entries,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/main.json': content.toJsonString(),
      for (final entry in entries)
        'content/entries/${entry.id}.json': entry.toJsonString(),
    });
  }

  /// Save a single accounting entry
  Future<void> saveAccountingEntry(
    String filePath,
    AccountingEntry entry,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/entries/${entry.id}.json': entry.toJsonString(),
    });
  }

  /// Delete an accounting entry
  Future<void> deleteAccountingEntry(
    String filePath,
    String entryId,
  ) async {
    await deleteArchiveFiles(filePath, ['content/entries/$entryId.json']);
  }

  // ============================================================
  // LOGO METHODS
  // ============================================================

  /// Embed a logo into an NDF document
  Future<void> embedLogo(String filePath, Uint8List logoBytes, String extension) async {
    final assetPath = 'assets/logo.$extension';
    await _updateArchiveFilesBytes(filePath, {assetPath: logoBytes});

    // Update metadata with logo reference
    final metadata = await readMetadata(filePath);
    if (metadata != null) {
      metadata.logo = 'asset://logo.$extension';
      metadata.touch();
      await updateMetadata(filePath, metadata);
    }

    LogService().log('NdfService: Embedded logo in $filePath');
  }

  /// Read logo bytes from an NDF archive
  Future<Uint8List?> readLogo(String filePath) async {
    final metadata = await readMetadata(filePath);
    if (metadata?.logo == null) return null;

    // Parse asset reference (e.g., "asset://logo.png")
    final logoRef = metadata!.logo!;
    if (!logoRef.startsWith('asset://')) return null;

    final assetPath = logoRef.substring(8); // Remove "asset://"
    return readArchiveFile(filePath, 'assets/$assetPath');
  }

  /// Remove logo from an NDF archive
  Future<void> removeLogo(String filePath) async {
    final metadata = await readMetadata(filePath);
    if (metadata?.logo == null) return;

    final logoRef = metadata!.logo!;
    if (logoRef.startsWith('asset://')) {
      final assetPath = 'assets/${logoRef.substring(8)}';
      await deleteArchiveFiles(filePath, [assetPath]);
    }

    metadata.logo = null;
    metadata.touch();
    await updateMetadata(filePath, metadata);

    LogService().log('NdfService: Removed logo from $filePath');
  }

  // ============================================================
  // THUMBNAIL METHODS
  // ============================================================

  /// Embed a thumbnail into an NDF document
  Future<void> embedThumbnail(String filePath, Uint8List imageBytes) async {
    const assetPath = 'assets/thumbnails/preview.png';
    await _updateArchiveFilesBytes(filePath, {assetPath: imageBytes});

    // Update metadata with thumbnail reference
    final metadata = await readMetadata(filePath);
    if (metadata != null) {
      metadata.thumbnail = 'asset://thumbnails/preview.png';
      metadata.touch();
      await updateMetadata(filePath, metadata);
    }

    LogService().log('NdfService: Embedded thumbnail in $filePath');
  }

  /// Read thumbnail bytes from an NDF archive
  Future<Uint8List?> readThumbnail(String filePath) async {
    final metadata = await readMetadata(filePath);
    if (metadata?.thumbnail == null) return null;

    final thumbRef = metadata!.thumbnail!;
    if (!thumbRef.startsWith('asset://')) return null;

    final assetPath = thumbRef.substring(8);
    return readArchiveFile(filePath, 'assets/$assetPath');
  }

  /// Remove thumbnail from an NDF archive
  Future<void> removeThumbnail(String filePath) async {
    final metadata = await readMetadata(filePath);
    if (metadata?.thumbnail == null) return;

    final thumbRef = metadata!.thumbnail!;
    if (thumbRef.startsWith('asset://')) {
      final assetPath = 'assets/${thumbRef.substring(8)}';
      await deleteArchiveFiles(filePath, [assetPath]);
    }

    metadata.thumbnail = null;
    metadata.touch();
    await updateMetadata(filePath, metadata);

    LogService().log('NdfService: Removed thumbnail from $filePath');
  }

  // ============================================================
  // ASSET METHODS
  // ============================================================

  /// Read an asset from the archive
  Future<Uint8List?> readAsset(String filePath, String assetPath) async {
    // assetPath should be like "images/photo.jpg"
    return readArchiveFile(filePath, 'assets/$assetPath');
  }

  /// Save an asset to the archive
  Future<void> saveAsset(
    String filePath,
    String assetPath,
    Uint8List data,
  ) async {
    await _updateArchiveFilesBytes(filePath, {
      'assets/$assetPath': data,
    });
  }

  /// List all assets in the archive
  Future<List<String>> listAssets(String filePath) async {
    final files = await listArchiveFiles(filePath);
    return files
        .where((f) => f.startsWith('assets/') && !f.endsWith('/'))
        .map((f) => f.substring(7)) // Remove 'assets/' prefix
        .toList();
  }

  /// Extract an asset to a temporary file and return its path
  Future<String?> extractAssetToTemp(
    String filePath,
    String assetPath,
  ) async {
    final data = await readAsset(filePath, assetPath);
    if (data == null) return null;

    final tempDir = Directory.systemTemp;
    final ext = assetPath.split('.').last;
    final tempFile = File(
      '${tempDir.path}/ndf_asset_${DateTime.now().millisecondsSinceEpoch}.$ext',
    );
    await tempFile.writeAsBytes(data);
    return tempFile.path;
  }

  // ============================================================
  // VOICE MEMO CONTENT METHODS
  // ============================================================

  /// Read voice memo main content
  Future<VoiceMemoContent?> readVoiceMemoContent(String filePath) async {
    final json = await readArchiveJson(filePath, 'content/main.json');
    if (json == null) return null;
    try {
      return VoiceMemoContent.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing voice memo content: $e');
      return null;
    }
  }

  /// Read a voice memo clip
  Future<VoiceMemoClip?> readVoiceMemoClip(String filePath, String clipId) async {
    final json = await readArchiveJson(filePath, 'content/clips/$clipId.json');
    if (json == null) return null;
    try {
      return VoiceMemoClip.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing clip $clipId, trying without transcription: $e');
      // Try loading without transcription rather than dropping the entire clip
      try {
        json.remove('transcription');
        return VoiceMemoClip.fromJson(json);
      } catch (e2) {
        LogService().log('NdfService: Failed to load clip $clipId even without transcription: $e2');
        return null;
      }
    }
  }

  /// Read all voice memo clips
  Future<List<VoiceMemoClip>> readVoiceMemoClips(String filePath, List<String> clipIds) async {
    final clips = <VoiceMemoClip>[];
    for (final clipId in clipIds) {
      final clip = await readVoiceMemoClip(filePath, clipId);
      if (clip != null) {
        clips.add(clip);
      }
    }
    return clips;
  }

  /// Save voice memo content and clips
  Future<void> saveVoiceMemo(
    String filePath,
    VoiceMemoContent content,
    List<VoiceMemoClip> clips,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/main.json': content.toJsonString(),
      for (final clip in clips)
        'content/clips/${clip.id}.json': clip.toJsonString(),
    });
  }

  /// Save a single voice memo clip
  Future<void> saveVoiceMemoClip(
    String filePath,
    VoiceMemoClip clip,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/clips/${clip.id}.json': clip.toJsonString(),
    });
  }

  /// Delete a voice memo clip and its audio file
  Future<void> deleteVoiceMemoClip(
    String filePath,
    String clipId,
    String audioFile,
  ) async {
    await deleteArchiveFiles(filePath, [
      'content/clips/$clipId.json',
      'assets/$audioFile',
    ]);
  }

  /// Save clip audio to the archive
  Future<void> saveClipAudio(
    String filePath,
    String clipId,
    Uint8List audioBytes, {
    String extension = 'wav',
  }) async {
    await _updateArchiveFilesBytes(filePath, {
      'assets/audio/$clipId.$extension': audioBytes,
    });
  }

  /// Read clip audio from the archive
  Future<Uint8List?> readClipAudio(String filePath, String audioFile) async {
    return readArchiveFile(filePath, 'assets/$audioFile');
  }

  /// Read clip ratings
  Future<List<ClipRating>> readClipRatings(String filePath, String clipId) async {
    final files = await listArchiveFiles(filePath);
    final ratings = <ClipRating>[];

    for (final file in files) {
      if (file.startsWith('social/clips/$clipId/ratings/') && file.endsWith('.json')) {
        final json = await readArchiveJson(filePath, file);
        if (json != null) {
          try {
            ratings.add(ClipRating.fromJson(json));
          } catch (e) {
            LogService().log('NdfService: Error parsing rating $file: $e');
          }
        }
      }
    }

    // Sort by creation date
    ratings.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return ratings;
  }

  /// Save a clip rating
  Future<void> saveClipRating(
    String filePath,
    String clipId,
    ClipRating rating,
  ) async {
    await _updateArchiveFiles(filePath, {
      'social/clips/$clipId/ratings/${rating.id}.json': rating.toJsonString(),
    });
  }

  /// Delete all social data for a clip (ratings and comments)
  Future<void> deleteClipSocialData(String filePath, String clipId) async {
    final files = await listArchiveFiles(filePath);
    final toDelete = files
        .where((f) => f.startsWith('social/clips/$clipId/'))
        .toList();

    if (toDelete.isNotEmpty) {
      await deleteArchiveFiles(filePath, toDelete);
    }
  }

  // ============================================================
  // WEB SNAPSHOT CONTENT METHODS
  // ============================================================

  /// Read web snapshot main content
  Future<WebSnapshotContent?> readWebSnapshotContent(String filePath) async {
    final json = await readArchiveJson(filePath, 'content/main.json');
    if (json == null) return null;
    try {
      return WebSnapshotContent.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing web snapshot content: $e');
      return null;
    }
  }

  /// Save web snapshot content
  Future<void> saveWebSnapshotContent(
    String filePath,
    WebSnapshotContent content,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/main.json': content.toJsonString(),
    });
  }

  /// Read a web snapshot metadata
  Future<WebSnapshot?> readWebSnapshot(String filePath, String snapshotId) async {
    final json = await readArchiveJson(filePath, 'content/snapshots/$snapshotId.json');
    if (json == null) return null;
    try {
      return WebSnapshot.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing snapshot $snapshotId: $e');
      return null;
    }
  }

  /// Read all web snapshots
  Future<List<WebSnapshot>> readWebSnapshots(String filePath, List<String> snapshotIds) async {
    final snapshots = <WebSnapshot>[];
    for (final snapshotId in snapshotIds) {
      final snapshot = await readWebSnapshot(filePath, snapshotId);
      if (snapshot != null) {
        snapshots.add(snapshot);
      }
    }
    return snapshots;
  }

  /// Save a web snapshot metadata
  Future<void> saveWebSnapshot(
    String filePath,
    WebSnapshot snapshot,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/snapshots/${snapshot.id}.json': snapshot.toJsonString(),
    });
  }

  /// Delete a web snapshot and all its assets
  Future<void> deleteWebSnapshot(String filePath, String snapshotId) async {
    final files = await listArchiveFiles(filePath);
    final toDelete = <String>[
      'content/snapshots/$snapshotId.json',
    ];

    // Add all assets belonging to this snapshot
    for (final file in files) {
      if (file.startsWith('assets/snapshots/$snapshotId/')) {
        toDelete.add(file);
      }
    }

    await deleteArchiveFiles(filePath, toDelete);
  }

  /// Save snapshot assets to the archive
  Future<void> saveSnapshotAssets(
    String filePath,
    String snapshotId,
    Map<String, Uint8List> assets,
  ) async {
    final assetMap = <String, Uint8List>{};
    for (final entry in assets.entries) {
      assetMap['assets/snapshots/$snapshotId/${entry.key}'] = entry.value;
    }
    await _updateArchiveFilesBytes(filePath, assetMap);
  }

  /// Read a snapshot asset
  Future<Uint8List?> readSnapshotAsset(
    String filePath,
    String snapshotId,
    String assetPath,
  ) async {
    return readArchiveFile(filePath, 'assets/snapshots/$snapshotId/$assetPath');
  }

  /// List all assets for a snapshot
  Future<List<String>> listSnapshotAssets(String filePath, String snapshotId) async {
    final files = await listArchiveFiles(filePath);
    final prefix = 'assets/snapshots/$snapshotId/';
    return files
        .where((f) => f.startsWith(prefix) && !f.endsWith('/'))
        .map((f) => f.substring(prefix.length))
        .toList();
  }

  /// Extract all snapshot assets to a temp directory for viewing
  Future<String?> extractSnapshotToTemp(String filePath, String snapshotId) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // Create temp directory for this snapshot
      final tempDir = Directory.systemTemp;
      final snapshotDir = Directory('${tempDir.path}/websnapshot_$snapshotId');
      if (await snapshotDir.exists()) {
        await snapshotDir.delete(recursive: true);
      }
      await snapshotDir.create(recursive: true);

      final prefix = 'assets/snapshots/$snapshotId/';

      // Extract all files for this snapshot
      for (final entry in archive) {
        if (entry.isFile && entry.name.startsWith(prefix)) {
          final relativePath = entry.name.substring(prefix.length);
          final outFile = File('${snapshotDir.path}/$relativePath');
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(entry.content as List<int>);
        }
      }

      return snapshotDir.path;
    } catch (e) {
      LogService().log('NdfService: Error extracting snapshot to temp: $e');
      return null;
    }
  }

  // ============================================================
  // MEETING CONTENT METHODS
  // ============================================================

  /// Read meeting main content
  Future<MeetingContent?> readMeetingContent(String filePath) async {
    final json = await readArchiveJson(filePath, 'content/main.json');
    if (json == null) return null;
    try {
      return MeetingContent.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing meeting content: $e');
      return null;
    }
  }

  /// Read a meeting recording metadata
  Future<MeetingRecording?> readMeetingRecording(String filePath, String recordingId) async {
    final json = await readArchiveJson(filePath, 'content/recordings/$recordingId.json');
    if (json == null) return null;
    try {
      return MeetingRecording.fromJson(json);
    } catch (e) {
      LogService().log('NdfService: Error parsing recording $recordingId: $e');
      return null;
    }
  }

  /// Read all meeting recordings
  Future<List<MeetingRecording>> readMeetingRecordings(
    String filePath,
    List<String> recordingIds,
  ) async {
    final recordings = <MeetingRecording>[];
    for (final id in recordingIds) {
      final recording = await readMeetingRecording(filePath, id);
      if (recording != null) {
        recordings.add(recording);
      }
    }
    return recordings;
  }

  /// Save meeting content and recordings
  Future<void> saveMeeting(
    String filePath,
    MeetingContent content,
    List<MeetingRecording> recordings,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/main.json': content.toJsonString(),
      for (final recording in recordings)
        'content/recordings/${recording.id}.json': recording.toJsonString(),
    });
  }

  /// Save a single meeting recording metadata
  Future<void> saveMeetingRecording(
    String filePath,
    MeetingRecording recording,
  ) async {
    await _updateArchiveFiles(filePath, {
      'content/recordings/${recording.id}.json': recording.toJsonString(),
    });
  }

  /// Read recording video bytes from the archive
  Future<Uint8List?> readRecordingVideo(String filePath, String videoFile) async {
    return readArchiveFile(filePath, 'assets/$videoFile');
  }

  /// Save recording video to the archive
  Future<void> saveRecordingVideo(
    String filePath,
    String recordingId,
    Uint8List videoBytes,
  ) async {
    await _updateArchiveFilesBytes(filePath, {
      'assets/video/$recordingId.mp4': videoBytes,
    });
  }

  // ============================================================
  // PUBLIC ARCHIVE HELPERS (for external service use)
  // ============================================================

  /// Update multiple text files in an archive (public wrapper)
  Future<void> updateArchiveFilesPublic(
    String filePath,
    Map<String, String> files,
  ) async {
    await _updateArchiveFiles(filePath, files);
  }

  /// Update multiple binary files in an archive (public wrapper)
  Future<void> updateArchiveFilesBytesPublic(
    String filePath,
    Map<String, Uint8List> files,
  ) async {
    await _updateArchiveFilesBytes(filePath, files);
  }

  // ============================================================
  // PRIVATE HELPER METHODS
  // ============================================================

  /// Update multiple text files in an archive
  Future<void> _updateArchiveFiles(
    String filePath,
    Map<String, String> files,
  ) async {
    final bytesMap = <String, Uint8List>{};
    for (final entry in files.entries) {
      bytesMap[entry.key] = Uint8List.fromList(utf8.encode(entry.value));
    }
    await _updateArchiveFilesBytes(filePath, bytesMap);
  }

  /// Update multiple binary files in an archive
  Future<void> _updateArchiveFilesBytes(
    String filePath,
    Map<String, Uint8List> files,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('NDF file not found: $filePath');
    }

    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // Create new archive
    final newArchive = Archive();
    final addedPaths = <String>{};

    // Copy existing entries, replacing those in files map
    for (final entry in archive) {
      if (files.containsKey(entry.name)) {
        // Replace with new content
        final newData = files[entry.name]!;
        newArchive.addFile(ArchiveFile(entry.name, newData.length, newData));
        addedPaths.add(entry.name);
      } else {
        // Copy existing entry
        newArchive.addFile(entry);
      }
    }

    // Add new files that didn't exist before
    for (final entry in files.entries) {
      if (!addedPaths.contains(entry.key)) {
        newArchive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
      }
    }

    // Write updated archive
    final zipData = ZipEncoder().encode(newArchive);
    if (zipData == null) {
      throw Exception('Failed to encode updated NDF archive');
    }

    await file.writeAsBytes(zipData);
    LogService().log('NdfService: Updated ${files.length} files in $filePath');
  }

  /// Update multiple binary files in an archive in-memory (no filesystem I/O).
  /// Returns the updated archive bytes.
  Uint8List updateArchiveEntriesInBytes(Uint8List archiveBytes, Map<String, Uint8List> files) {
    final archive = ZipDecoder().decodeBytes(archiveBytes);
    final newArchive = Archive();
    final addedPaths = <String>{};

    for (final entry in archive) {
      if (files.containsKey(entry.name)) {
        final newData = files[entry.name]!;
        newArchive.addFile(ArchiveFile(entry.name, newData.length, newData));
        addedPaths.add(entry.name);
      } else {
        newArchive.addFile(entry);
      }
    }

    for (final entry in files.entries) {
      if (!addedPaths.contains(entry.key)) {
        newArchive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
      }
    }

    final zipData = ZipEncoder().encode(newArchive);
    if (zipData == null) {
      throw Exception('Failed to encode updated NDF archive');
    }
    return Uint8List.fromList(zipData);
  }

  /// Update multiple text files in an archive in-memory (no filesystem I/O).
  /// Returns the updated archive bytes.
  Uint8List updateArchiveStringEntriesInBytes(Uint8List archiveBytes, Map<String, String> files) {
    final bytesMap = <String, Uint8List>{};
    for (final entry in files.entries) {
      bytesMap[entry.key] = Uint8List.fromList(utf8.encode(entry.value));
    }
    return updateArchiveEntriesInBytes(archiveBytes, bytesMap);
  }

  /// Delete files from an archive
  Future<void> deleteArchiveFiles(
    String filePath,
    List<String> paths,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('NDF file not found: $filePath');
    }

    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // Create new archive without deleted files
    final newArchive = Archive();
    final pathSet = paths.toSet();

    for (final entry in archive) {
      if (!pathSet.contains(entry.name)) {
        newArchive.addFile(entry);
      }
    }

    // Write updated archive
    final zipData = ZipEncoder().encode(newArchive);
    if (zipData == null) {
      throw Exception('Failed to encode updated NDF archive');
    }

    await file.writeAsBytes(zipData);
    LogService().log('NdfService: Deleted ${paths.length} files from $filePath');
  }
}
