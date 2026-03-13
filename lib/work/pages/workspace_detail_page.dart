/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:image_picker/image_picker.dart';

import '../../services/i18n_service.dart';
import '../../services/log_service.dart';
import '../../services/profile_service.dart';
import '../../services/profile_storage.dart';
import '../models/workspace.dart';
import '../models/ndf_document.dart';
import '../models/ndf_permission.dart';
import '../models/websnapshot_content.dart' show sanitizeFilename;
import '../services/work_storage_service.dart';
import '../services/ndf_service.dart';
import 'spreadsheet_editor_page.dart';
import 'document_editor_page.dart';
import 'form_editor_page.dart';
import 'presentation_editor_page.dart';
import 'todo_editor_page.dart';
import 'voicememo_editor_page.dart';
import 'websnapshot_editor_page.dart';

/// Workspace detail page showing documents and folders
class WorkspaceDetailPage extends StatefulWidget {
  final ProfileStorage storage;
  final String relativePath;
  final String workspaceId;

  const WorkspaceDetailPage({
    super.key,
    required this.storage,
    required this.relativePath,
    required this.workspaceId,
  });

  @override
  State<WorkspaceDetailPage> createState() => _WorkspaceDetailPageState();
}

class _WorkspaceDetailPageState extends State<WorkspaceDetailPage> {
  final I18nService _i18n = I18nService();
  final ImagePicker _imagePicker = ImagePicker();
  late WorkStorageService _storage;
  late NdfService _ndfService;
  Workspace? _workspace;
  List<NdfDocumentRef> _documents = [];
  bool _isLoading = true;
  String? _error;
  String? _currentFolderId; // null = root folder
  Uint8List? _workspaceLogo; // Cached workspace logo
  final Map<String, Uint8List> _thumbnailCache = {}; // filename -> thumbnail bytes
  final Map<String, Uint8List> _logoCache = {}; // filename -> logo bytes
  bool _isGridView = true; // Toggle between grid and list view

  @override
  void initState() {
    super.initState();
    _storage = WorkStorageService(widget.storage, widget.relativePath);
    _ndfService = NdfService();
    _loadWorkspace();
  }

  Future<void> _loadWorkspace() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final workspace = await _storage.loadWorkspace(widget.workspaceId);
      if (workspace == null) {
        setState(() {
          _error = 'Workspace not found';
          _isLoading = false;
        });
        return;
      }

      final documents = await _storage.listDocuments(widget.workspaceId);

      // Load workspace logo
      Uint8List? workspaceLogo;
      if (workspace.logo != null) {
        workspaceLogo = await _storage.readWorkspaceLogo(widget.workspaceId);
      }

      // Pre-load document thumbnails and logos using bytes-based methods
      for (final doc in documents) {
        if (doc.thumbnail != null && !_thumbnailCache.containsKey(doc.filename)) {
          final ndfBytes = await _storage.readDocumentBytes(widget.workspaceId, doc.filename);
          if (ndfBytes != null) {
            final thumbBytes = _ndfService.readThumbnailFromBytes(ndfBytes);
            if (thumbBytes != null) {
              _thumbnailCache[doc.filename] = thumbBytes;
            }
          }
        }
        if (doc.logo != null && !_logoCache.containsKey(doc.filename)) {
          final ndfBytes = await _storage.readDocumentBytes(widget.workspaceId, doc.filename);
          if (ndfBytes != null) {
            final logoBytes = _ndfService.readLogoFromBytes(ndfBytes);
            if (logoBytes != null) {
              _logoCache[doc.filename] = logoBytes;
            }
          }
        }
      }

      setState(() {
        _workspace = workspace;
        _documents = documents;
        _workspaceLogo = workspaceLogo;
        _isLoading = false;
      });
    } catch (e) {
      LogService().log('WorkspaceDetailPage: Error loading workspace: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Get the breadcrumb path for the current folder
  List<WorkspaceFolder> _getBreadcrumbPath() {
    if (_workspace == null || _currentFolderId == null) return [];

    final path = <WorkspaceFolder>[];
    String? folderId = _currentFolderId;

    while (folderId != null) {
      final folder = _workspace!.folders.where((f) => f.id == folderId).firstOrNull;
      if (folder == null) break;
      path.insert(0, folder);
      folderId = folder.parentId;
    }

    return path;
  }

  /// Get folders in the current folder
  List<WorkspaceFolder> _getCurrentFolders() {
    if (_workspace == null) return [];
    return _workspace!.getFoldersIn(_currentFolderId);
  }

  /// Get documents in the current folder
  List<NdfDocumentRef> _getCurrentDocuments() {
    if (_workspace == null) return [];
    final docsInFolder = _workspace!.getDocumentsIn(_currentFolderId);
    return _documents.where((d) => docsInFolder.contains(d.filename)).toList();
  }

  Future<void> _showWorkspaceSettingsDialog() async {
    final theme = Theme.of(context);

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(_i18n.t('work_workspace_settings')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Logo section
                  Text(
                    _i18n.t('work_workspace_logo'),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: _workspaceLogo != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(11),
                              child: Image.memory(
                                _workspaceLogo!,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Icon(
                                    Icons.broken_image,
                                    size: 40,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  );
                                },
                              ),
                            )
                          : Icon(
                              Icons.image_outlined,
                              size: 40,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final image = await _imagePicker.pickImage(
                            source: ImageSource.gallery,
                            maxWidth: 512,
                            maxHeight: 512,
                          );
                          if (image != null) {
                            final bytes = await image.readAsBytes();
                            final extension = image.path.split('.').last.toLowerCase();
                            await _storage.saveWorkspaceLogo(
                              widget.workspaceId,
                              bytes,
                              extension,
                            );
                            final newLogo = await _storage.readWorkspaceLogo(widget.workspaceId);
                            setState(() {
                              _workspaceLogo = newLogo;
                            });
                            setDialogState(() {});
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(_i18n.t('work_logo_updated'))),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.upload),
                        label: Text(_i18n.t('work_change_logo')),
                      ),
                      if (_workspaceLogo != null) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () async {
                            await _storage.deleteWorkspaceLogo(widget.workspaceId);
                            setState(() {
                              _workspaceLogo = null;
                            });
                            setDialogState(() {});
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(_i18n.t('work_logo_removed'))),
                              );
                            }
                          },
                          icon: Icon(
                            Icons.delete_outline,
                            color: theme.colorScheme.error,
                          ),
                          tooltip: _i18n.t('work_remove_logo'),
                        ),
                      ],
                    ],
                  ),
                  if (_workspaceLogo != null && _documents.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Center(
                      child: FilledButton.icon(
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(_i18n.t('work_apply_logo_all')),
                              content: Text(
                                _i18n.t('work_apply_logo_confirm')
                                    .replaceAll('{count}', _documents.length.toString()),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: Text(_i18n.t('cancel')),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: Text(_i18n.t('work_apply_logo_all')),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await _applyLogoToAllDocuments();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(_i18n.t('work_logo_applied_all'))),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.sync),
                        label: Text(_i18n.t('work_apply_logo_all')),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_i18n.t('save')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _applyLogoToAllDocuments() async {
    if (_workspaceLogo == null || _workspace?.logo == null) return;

    final extension = _workspace!.logo!.split('.').last;

    for (final doc in _documents) {
      try {
        String filePath;
        String? tempFilePath;

        if (_storage.storage.isEncrypted) {
          // For encrypted storage: extract to temp, modify, save back
          final ndfBytes = await _storage.readDocumentBytes(widget.workspaceId, doc.filename);
          if (ndfBytes == null) continue;
          final tempDir = await Directory.systemTemp.createTemp('geogram_ndf_');
          tempFilePath = p.join(tempDir.path, doc.filename);
          await File(tempFilePath).writeAsBytes(ndfBytes);
          filePath = tempFilePath;
        } else {
          // For filesystem storage, use absolute path
          filePath = _storage.storage.getAbsolutePath(_storage.documentPath(widget.workspaceId, doc.filename));
        }

        await _ndfService.embedLogo(filePath, _workspaceLogo!, extension);

        // If using temp file, save back to encrypted storage
        if (tempFilePath != null) {
          final modifiedBytes = await File(tempFilePath).readAsBytes();
          await _storage.writeDocumentBytes(widget.workspaceId, doc.filename, modifiedBytes);
          // Cleanup
          final tempFile = File(tempFilePath);
          await tempFile.delete();
          await tempFile.parent.delete();
        }
      } catch (e) {
        LogService().log('WorkspaceDetailPage: Error applying logo to ${doc.filename}: $e');
      }
    }
    await _loadWorkspace();
  }

  Future<void> _createFolder() async {
    final nameController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_create_folder')),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(
            labelText: _i18n.t('work_folder_name'),
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('create')),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.trim().isNotEmpty) {
      try {
        final folder = WorkspaceFolder.create(
          name: nameController.text.trim(),
          parentId: _currentFolderId,
        );

        _workspace?.addFolder(folder);
        if (_workspace != null) {
          await _storage.saveWorkspace(_workspace!);
        }

        LogService().log('WorkspaceDetailPage: Created folder ${folder.id}');
        await _loadWorkspace();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('folder_created'))),
          );
        }
      } catch (e) {
        LogService().log('WorkspaceDetailPage: Error creating folder: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error creating folder: $e')),
          );
        }
      }
    }
  }

  /// Generate a unique filename from a title
  /// Returns a filesystem-safe filename with .ndf extension
  Future<String> _generateUniqueFilename(String title) async {
    // Sanitize the title for filesystem compatibility
    var baseName = sanitizeFilename(title);
    if (baseName.isEmpty) {
      baseName = 'document';
    }

    // Check if this filename already exists
    var filename = '$baseName.ndf';
    var counter = 1;

    while (true) {
      final docPath = _storage.documentPath(widget.workspaceId, filename);
      final exists = await _storage.storage.exists(docPath);
      if (!exists) {
        break;
      }
      counter++;
      filename = '$baseName ($counter).ndf';
    }

    return filename;
  }

  Future<void> _createDocument(NdfDocumentType type) async {
    final titleController = TextEditingController();

    final typeName = _getDocumentTypeName(type);
    titleController.text = '$typeName ${_documents.length + 1}';

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_new_document')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(_getDocumentTypeIcon(type), size: 32),
                const SizedBox(width: 12),
                Text(
                  typeName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: titleController,
              decoration: InputDecoration(
                labelText: _i18n.t('work_document_title'),
                border: const OutlineInputBorder(),
              ),
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => Navigator.pop(context, true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('create')),
          ),
        ],
      ),
    );

    if (result == true && titleController.text.trim().isNotEmpty) {
      try {
        final title = titleController.text.trim();
        final profile = ProfileService().getProfile();

        // Create NDF document metadata
        final metadata = NdfDocument.create(
          type: type,
          title: title,
        );

        // Create permissions
        final permissions = NdfPermission.create(
          documentId: metadata.id,
          ownerNpub: profile.npub,
          ownerName: profile.nickname.isNotEmpty ? profile.nickname : null,
          ownerCallsign: profile.callsign,
        );

        // Generate filename from title (filesystem-safe, unique)
        final filename = await _generateUniqueFilename(title);

        // Create the NDF file as bytes
        var ndfBytes = _ndfService.createDocumentAsBytes(
          metadata: metadata,
          permissions: permissions,
        );

        // Write NDF bytes to storage
        await _storage.writeDocumentBytes(widget.workspaceId, filename, ndfBytes);

        // Embed workspace logo if available (using temp file approach)
        if (_workspaceLogo != null && _workspace?.logo != null) {
          try {
            final extension = _workspace!.logo!.split('.').last;
            final tempDir = await Directory.systemTemp.createTemp('geogram_ndf_');
            final tempFilePath = p.join(tempDir.path, filename);
            await File(tempFilePath).writeAsBytes(ndfBytes);
            await _ndfService.embedLogo(tempFilePath, _workspaceLogo!, extension);
            final modifiedBytes = await File(tempFilePath).readAsBytes();
            await _storage.writeDocumentBytes(widget.workspaceId, filename, modifiedBytes);
            // Cleanup
            await File(tempFilePath).delete();
            await tempDir.delete();
          } catch (e) {
            LogService().log('WorkspaceDetailPage: Failed to embed logo in new document: $e');
          }
        }

        // Update workspace - add to current folder
        _workspace?.addDocument(filename, folderId: _currentFolderId);
        if (_workspace != null) {
          await _storage.saveWorkspace(_workspace!);
        }

        LogService().log('WorkspaceDetailPage: Created document $filename');
        await _loadWorkspace();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('document_created'))),
          );
        }
      } catch (e) {
        LogService().log('WorkspaceDetailPage: Error creating document: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error creating document: $e')),
          );
        }
      }
    }
  }

  void _showNewItemMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.create_new_folder),
                title: Text(_i18n.t('work_folder')),
                subtitle: Text(_i18n.t('work_folder_desc')),
                onTap: () {
                  Navigator.pop(context);
                  _createFolder();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.table_chart),
                title: Text(_i18n.t('work_spreadsheet')),
                subtitle: Text(_i18n.t('work_spreadsheet_desc')),
                onTap: () {
                  Navigator.pop(context);
                  _createDocument(NdfDocumentType.spreadsheet);
                },
              ),
              ListTile(
                leading: const Icon(Icons.description),
                title: Text(_i18n.t('work_document')),
                subtitle: Text(_i18n.t('work_document_desc')),
                onTap: () {
                  Navigator.pop(context);
                  _createDocument(NdfDocumentType.document);
                },
              ),
              ListTile(
                leading: const Icon(Icons.slideshow),
                title: Text(_i18n.t('work_presentation')),
                subtitle: Text(_i18n.t('work_presentation_desc')),
                onTap: () {
                  Navigator.pop(context);
                  _createDocument(NdfDocumentType.presentation);
                },
              ),
              ListTile(
                leading: const Icon(Icons.assignment),
                title: Text(_i18n.t('work_form')),
                subtitle: Text(_i18n.t('work_form_desc')),
                onTap: () {
                  Navigator.pop(context);
                  _createDocument(NdfDocumentType.form);
                },
              ),
              ListTile(
                leading: const Icon(Icons.checklist),
                title: Text(_i18n.t('work_todo')),
                subtitle: Text(_i18n.t('work_todo_desc')),
                onTap: () {
                  Navigator.pop(context);
                  _createDocument(NdfDocumentType.todo);
                },
              ),
              ListTile(
                leading: const Icon(Icons.mic),
                title: Text(_i18n.t('work_voicememo')),
                subtitle: Text(_i18n.t('work_voicememo_desc')),
                onTap: () {
                  Navigator.pop(context);
                  _createDocument(NdfDocumentType.voicememo);
                },
              ),
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(_i18n.t('work_websnapshot')),
                subtitle: Text(_i18n.t('work_websnapshot_desc')),
                onTap: () {
                  Navigator.pop(context);
                  _createDocument(NdfDocumentType.websnapshot);
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _renameDocument(NdfDocumentRef doc) async {
    final controller = TextEditingController(text: doc.title);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('rename_document')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _i18n.t('document_title'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(_i18n.t('rename')),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && result != doc.title) {
      try {
        // Generate new filename from new title
        final newFilename = await _generateUniqueFilename(result);
        final oldFilename = doc.filename;

        // Read document bytes
        final ndfBytes = await _storage.readDocumentBytes(widget.workspaceId, oldFilename);
        if (ndfBytes == null) {
          throw Exception('Failed to read document');
        }

        // Update metadata in temp file
        final tempDir = await Directory.systemTemp.createTemp('geogram_ndf_');
        final tempFilePath = p.join(tempDir.path, oldFilename);
        await File(tempFilePath).writeAsBytes(ndfBytes);

        final metadata = await _ndfService.readMetadata(tempFilePath);
        if (metadata != null) {
          metadata.title = result;
          metadata.touch();
          await _ndfService.updateMetadata(tempFilePath, metadata);

          // Read modified bytes and write to new filename
          final modifiedBytes = await File(tempFilePath).readAsBytes();
          await _storage.writeDocumentBytes(widget.workspaceId, newFilename, modifiedBytes);

          // Delete old file if filename changed
          if (newFilename != oldFilename) {
            await _storage.deleteDocument(widget.workspaceId, oldFilename);

            // Update workspace to use new filename
            if (_workspace != null) {
              _workspace!.renameDocument(oldFilename, newFilename);
              await _storage.saveWorkspace(_workspace!);
            }
          }

          // Cleanup temp file
          await File(tempFilePath).delete();
          await tempDir.delete();

          await _loadWorkspace();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_i18n.t('document_renamed'))),
            );
          }
        }
      } catch (e) {
        LogService().log('WorkspaceDetailPage: Error renaming document: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error renaming document: $e')),
          );
        }
      }
    }
  }

  Future<void> _editDocumentDescription(NdfDocumentRef doc) async {
    final controller = TextEditingController(text: doc.description ?? '');

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_edit_description')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _i18n.t('description'),
            hintText: _i18n.t('work_no_description'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(_i18n.t('save')),
          ),
        ],
      ),
    );

    if (result != null && result != (doc.description ?? '')) {
      try {
        String filePath;
        String? tempFilePath;

        if (_storage.storage.isEncrypted) {
          final ndfBytes = await _storage.readDocumentBytes(widget.workspaceId, doc.filename);
          if (ndfBytes == null) {
            throw Exception('Failed to read document');
          }
          final tempDir = await Directory.systemTemp.createTemp('geogram_ndf_');
          tempFilePath = p.join(tempDir.path, doc.filename);
          await File(tempFilePath).writeAsBytes(ndfBytes);
          filePath = tempFilePath;
        } else {
          filePath = _storage.storage.getAbsolutePath(_storage.documentPath(widget.workspaceId, doc.filename));
        }

        final metadata = await _ndfService.readMetadata(filePath);
        if (metadata != null) {
          metadata.description = result.isEmpty ? null : result;
          metadata.touch();
          await _ndfService.updateMetadata(filePath, metadata);

          if (tempFilePath != null) {
            final modifiedBytes = await File(tempFilePath).readAsBytes();
            await _storage.writeDocumentBytes(widget.workspaceId, doc.filename, modifiedBytes);
            final tempFile = File(tempFilePath);
            await tempFile.delete();
            await tempFile.parent.delete();
          }

          await _loadWorkspace();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_i18n.t('work_description_updated'))),
            );
          }
        }
      } catch (e) {
        LogService().log('WorkspaceDetailPage: Error updating description: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error updating description: $e')),
          );
        }
      }
    }
  }

  Future<void> _moveDocument(NdfDocumentRef doc) async {
    if (_workspace == null) return;

    // Find current folder of this document
    final currentFolderId = _workspace!.documentFolders[doc.filename];

    final selectedFolderId = await showDialog<String?>(
      context: context,
      builder: (context) => _FolderPickerDialog(
        i18n: _i18n,
        folders: _workspace!.folders,
        currentFolderId: currentFolderId,
      ),
    );

    // Check if user selected a folder (including root which returns empty string)
    if (selectedFolderId == null) return; // User cancelled

    final targetFolderId = selectedFolderId.isEmpty ? null : selectedFolderId;
    if (targetFolderId == currentFolderId) return; // Same folder, no change

    try {
      _workspace!.moveDocument(doc.filename, targetFolderId);
      await _storage.saveWorkspace(_workspace!);
      await _loadWorkspace();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('document_moved'))),
        );
      }
    } catch (e) {
      LogService().log('WorkspaceDetailPage: Error moving document: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error moving document: $e')),
        );
      }
    }
  }

  Future<void> _deleteDocument(NdfDocumentRef doc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_document')),
        content: Text(_i18n.t('delete_document_confirm').replaceAll('{name}', doc.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _storage.deleteDocument(widget.workspaceId, doc.filename);
        await _loadWorkspace();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('document_deleted'))),
          );
        }
      } catch (e) {
        LogService().log('WorkspaceDetailPage: Error deleting document: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting document: $e')),
          );
        }
      }
    }
  }

  Future<void> _deleteFolder(WorkspaceFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_folder')),
        content: Text(_i18n.t('delete_folder_confirm').replaceAll('{name}', folder.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        _workspace?.removeFolder(folder.id);
        if (_workspace != null) {
          await _storage.saveWorkspace(_workspace!);
        }
        await _loadWorkspace();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('folder_deleted'))),
          );
        }
      } catch (e) {
        LogService().log('WorkspaceDetailPage: Error deleting folder: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting folder: $e')),
          );
        }
      }
    }
  }

  void _openFolder(WorkspaceFolder folder) {
    setState(() {
      _currentFolderId = folder.id;
    });
  }

  void _navigateToFolder(String? folderId) {
    setState(() {
      _currentFolderId = folderId;
    });
  }

  Future<void> _openDocument(NdfDocumentRef doc) async {
    String filePath;
    String? tempFilePath;

    if (_storage.storage.isEncrypted) {
      // For encrypted storage: extract to temp file
      final ndfBytes = await _storage.readDocumentBytes(widget.workspaceId, doc.filename);
      if (ndfBytes == null) {
        LogService().log('WorkspaceDetailPage: Failed to read document ${doc.filename}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('error_loading_document'))),
          );
        }
        return;
      }

      // Create temp file
      final tempDir = await Directory.systemTemp.createTemp('geogram_ndf_');
      tempFilePath = p.join(tempDir.path, doc.filename);
      final tempFile = File(tempFilePath);
      await tempFile.writeAsBytes(ndfBytes);
      filePath = tempFilePath;
      LogService().log('WorkspaceDetailPage: Extracted ${doc.filename} to temp: $tempFilePath');
    } else {
      // For filesystem storage, use absolute path
      filePath = _storage.storage.getAbsolutePath(_storage.documentPath(widget.workspaceId, doc.filename));
    }

    // Callback to save changes back and cleanup temp file
    Future<void> onEditorClosed() async {
      if (tempFilePath != null && _storage.storage.isEncrypted) {
        try {
          // Read modified file and save back to encrypted storage
          final tempFile = File(tempFilePath);
          if (await tempFile.exists()) {
            final modifiedBytes = await tempFile.readAsBytes();
            await _storage.writeDocumentBytes(widget.workspaceId, doc.filename, modifiedBytes);
            LogService().log('WorkspaceDetailPage: Saved changes from temp back to encrypted storage');

            // Cleanup temp file and directory
            final tempDir = tempFile.parent;
            await tempFile.delete();
            await tempDir.delete();
            LogService().log('WorkspaceDetailPage: Cleaned up temp file');
          }
        } catch (e) {
          LogService().log('WorkspaceDetailPage: Error saving changes from temp: $e');
        }
      }
      await _loadWorkspace();
    }

    switch (doc.type) {
      case NdfDocumentType.spreadsheet:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => SpreadsheetEditorPage(
              filePath: filePath,
              title: doc.title,
            ),
          ),
        ).then((_) => onEditorClosed());
        break;

      case NdfDocumentType.document:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DocumentEditorPage(
              filePath: filePath,
              title: doc.title,
            ),
          ),
        ).then((_) => onEditorClosed());
        break;

      case NdfDocumentType.form:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => FormEditorPage(
              filePath: filePath,
              title: doc.title,
            ),
          ),
        ).then((_) => onEditorClosed());
        break;

      case NdfDocumentType.presentation:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PresentationEditorPage(
              filePath: filePath,
              title: doc.title,
            ),
          ),
        ).then((_) => onEditorClosed());
        break;

      case NdfDocumentType.todo:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TodoEditorPage(
              filePath: filePath,
              title: doc.title,
            ),
          ),
        ).then((_) => onEditorClosed());
        break;

      case NdfDocumentType.voicememo:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VoiceMemoEditorPage(
              filePath: filePath,
              title: doc.title,
            ),
          ),
        ).then((_) => onEditorClosed());
        break;

      case NdfDocumentType.websnapshot:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => WebSnapshotEditorPage(
              filePath: filePath,
              title: doc.title,
            ),
          ),
        ).then((_) => onEditorClosed());
        break;

      case NdfDocumentType.meeting:
        // Meeting NDF documents are read-only archives opened from Meetings
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Meeting documents are opened from the Meetings archive')),
        );
        break;
    }
  }

  String _getDocumentTypeName(NdfDocumentType type) {
    switch (type) {
      case NdfDocumentType.spreadsheet:
        return _i18n.t('work_spreadsheet');
      case NdfDocumentType.document:
        return _i18n.t('work_document');
      case NdfDocumentType.presentation:
        return _i18n.t('work_presentation');
      case NdfDocumentType.form:
        return _i18n.t('work_form');
      case NdfDocumentType.todo:
        return _i18n.t('work_todo');
      case NdfDocumentType.voicememo:
        return _i18n.t('work_voicememo');
      case NdfDocumentType.websnapshot:
        return _i18n.t('work_websnapshot');
      case NdfDocumentType.meeting:
        return 'Meeting';
    }
  }

  IconData _getDocumentTypeIcon(NdfDocumentType type) {
    switch (type) {
      case NdfDocumentType.spreadsheet:
        return Icons.table_chart;
      case NdfDocumentType.document:
        return Icons.description;
      case NdfDocumentType.presentation:
        return Icons.slideshow;
      case NdfDocumentType.form:
        return Icons.assignment;
      case NdfDocumentType.todo:
        return Icons.checklist;
      case NdfDocumentType.voicememo:
        return Icons.mic;
      case NdfDocumentType.websnapshot:
        return Icons.language;
      case NdfDocumentType.meeting:
        return Icons.groups;
    }
  }

  Color _getDocumentTypeColor(NdfDocumentType type, ThemeData theme) {
    switch (type) {
      case NdfDocumentType.spreadsheet:
        return Colors.green;
      case NdfDocumentType.document:
        return Colors.blue;
      case NdfDocumentType.presentation:
        return Colors.orange;
      case NdfDocumentType.form:
        return Colors.purple;
      case NdfDocumentType.todo:
        return Colors.teal;
      case NdfDocumentType.voicememo:
        return Colors.deepOrange;
      case NdfDocumentType.websnapshot:
        return Colors.indigo;
      case NdfDocumentType.meeting:
        return Colors.blueGrey;
    }
  }

  /// Get the parent folder ID of the current folder
  String? _getParentFolderId() {
    if (_currentFolderId == null || _workspace == null) return null;
    final currentFolder = _workspace!.folders.where((f) => f.id == _currentFolderId).firstOrNull;
    return currentFolder?.parentId;
  }

  /// Handle back navigation - returns true if handled (consumed), false to allow default behavior
  bool _handleBack() {
    if (_currentFolderId != null) {
      // Navigate to parent folder
      final parentId = _getParentFolderId();
      setState(() {
        _currentFolderId = parentId;
      });
      return true; // Consumed the back action
    }
    return false; // Allow default back behavior (exit workspace)
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: _currentFolderId == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _handleBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (!_handleBack()) {
                Navigator.of(context).pop();
              }
            },
          ),
          title: Text(_workspace?.name ?? _i18n.t('loading')),
          actions: [
            IconButton(
              icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view),
              tooltip: _isGridView ? 'List view' : 'Grid view',
              onPressed: () {
                setState(() {
                  _isGridView = !_isGridView;
                });
              },
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (action) {
                if (action == 'settings') {
                  _showWorkspaceSettingsDialog();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'settings',
                  child: Row(
                    children: [
                      const Icon(Icons.settings_outlined),
                      const SizedBox(width: 8),
                      Text(_i18n.t('work_workspace_settings')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'collaborators',
                  child: Row(
                    children: [
                      const Icon(Icons.people_outline),
                      const SizedBox(width: 8),
                      Text(_i18n.t('work_collaborators')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'sync',
                  child: Row(
                    children: [
                      const Icon(Icons.sync),
                      const SizedBox(width: 8),
                      Text(_i18n.t('work_sync')),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: _buildBody(theme),
        floatingActionButton: FloatingActionButton(
          onPressed: _showNewItemMenu,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
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
              _i18n.t('error_loading_workspace'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loadWorkspace,
              icon: const Icon(Icons.refresh),
              label: Text(_i18n.t('retry')),
            ),
          ],
        ),
      );
    }

    final folders = _getCurrentFolders();
    final documents = _getCurrentDocuments();
    final breadcrumbs = _getBreadcrumbPath();
    final isEmpty = folders.isEmpty && documents.isEmpty;

    return Column(
      children: [
        // Breadcrumb navigation
        if (_currentFolderId != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: theme.colorScheme.surfaceContainerLow,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  InkWell(
                    onTap: () => _navigateToFolder(null),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.home, size: 16, color: theme.colorScheme.primary),
                          const SizedBox(width: 4),
                          Text(
                            _workspace?.name ?? '',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  for (final folder in breadcrumbs) ...[
                    Icon(Icons.chevron_right, size: 16, color: theme.colorScheme.onSurfaceVariant),
                    InkWell(
                      onTap: folder.id == _currentFolderId
                          ? null
                          : () => _navigateToFolder(folder.id),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Text(
                          folder.name,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: folder.id == _currentFolderId
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.primary,
                            fontWeight: folder.id == _currentFolderId
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

        // Content
        Expanded(
          child: isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _currentFolderId != null ? Icons.folder_open : Icons.description_outlined,
                        size: 64,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _currentFolderId != null
                            ? _i18n.t('work_folder_empty')
                            : _i18n.t('work_no_documents'),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _i18n.t('work_no_documents_hint'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadWorkspace,
                  child: _isGridView
                      ? GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 130,
                            childAspectRatio: 0.85,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                          ),
                          itemCount: folders.length + documents.length,
                          itemBuilder: (context, index) {
                            if (index < folders.length) {
                              return _buildFolderCard(folders[index], theme);
                            }
                            return _buildDocumentCard(documents[index - folders.length], theme);
                          },
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: folders.length + documents.length,
                          itemBuilder: (context, index) {
                            if (index < folders.length) {
                              return _buildFolderListTile(folders[index], theme);
                            }
                            return _buildDocumentListTile(documents[index - folders.length], theme);
                          },
                        ),
                ),
        ),
      ],
    );
  }

  Widget _buildFolderListTile(WorkspaceFolder folder, ThemeData theme) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.folder,
          color: theme.colorScheme.primary,
        ),
      ),
      title: Text(
        folder.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _formatDate(folder.modified),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: PopupMenuButton<String>(
        icon: Icon(
          Icons.more_vert,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        onSelected: (action) {
          if (action == 'delete') {
            _deleteFolder(folder);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete_outline, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Text(
                  _i18n.t('delete'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ),
          ),
        ],
      ),
      onTap: () => _openFolder(folder),
    );
  }

  Widget _buildDocumentListTile(NdfDocumentRef doc, ThemeData theme) {
    final typeColor = _getDocumentTypeColor(doc.type, theme);
    final hasLogo = _logoCache.containsKey(doc.filename);
    final typeName = _getDocumentTypeName(doc.type);

    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: typeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _getDocumentTypeIcon(doc.type),
              color: typeColor,
            ),
          ),
          // Logo overlay in bottom-right of icon
          if (hasLogo)
            Positioned(
              right: -4,
              bottom: -4,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 2,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Image.memory(
                    _logoCache[doc.filename]!,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return const Icon(Icons.broken_image, color: Colors.grey);
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
      title: Text(
        doc.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          Text(
            typeName,
            style: theme.textTheme.bodySmall?.copyWith(
              color: typeColor,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '•',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatDate(doc.modified),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (doc.fileSize != null) ...[
            const SizedBox(width: 8),
            Text(
              '•',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatFileSize(doc.fileSize!),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      trailing: PopupMenuButton<String>(
        icon: Icon(
          Icons.more_vert,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        onSelected: (action) {
          switch (action) {
            case 'rename':
              _renameDocument(doc);
              break;
            case 'description':
              _editDocumentDescription(doc);
              break;
            case 'move':
              _moveDocument(doc);
              break;
            case 'settings':
              _showDocumentSettingsDialog(doc);
              break;
            case 'delete':
              _deleteDocument(doc);
              break;
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'rename',
            child: Row(
              children: [
                const Icon(Icons.edit_outlined),
                const SizedBox(width: 8),
                Text(_i18n.t('rename')),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'description',
            child: Row(
              children: [
                const Icon(Icons.short_text),
                const SizedBox(width: 8),
                Text(_i18n.t('work_edit_description')),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'move',
            child: Row(
              children: [
                const Icon(Icons.drive_file_move_outlined),
                const SizedBox(width: 8),
                Text(_i18n.t('move_document')),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'settings',
            child: Row(
              children: [
                const Icon(Icons.settings_outlined),
                const SizedBox(width: 8),
                Text(_i18n.t('work_document_settings')),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete_outline, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Text(
                  _i18n.t('delete'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ),
          ),
        ],
      ),
      onTap: () => _openDocument(doc),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildFolderCard(WorkspaceFolder folder, ThemeData theme) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openFolder(folder),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Folder icon header
            Expanded(
              child: Container(
                width: double.infinity,
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                child: Stack(
                  children: [
                    Center(
                      child: Icon(
                        Icons.folder,
                        size: 44,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    // Three-dot menu in upper-right corner
                    Positioned(
                      right: 0,
                      top: 0,
                      child: PopupMenuButton<String>(
                        icon: Icon(
                          Icons.more_vert,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        padding: EdgeInsets.zero,
                        onSelected: (action) {
                          if (action == 'delete') {
                            _deleteFolder(folder);
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_outline,
                                    color: theme.colorScheme.error),
                                const SizedBox(width: 8),
                                Text(
                                  _i18n.t('delete'),
                                  style: TextStyle(color: theme.colorScheme.error),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Bottom bar
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _formatDate(folder.modified),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 10,
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

  Widget _buildDocumentCard(NdfDocumentRef doc, ThemeData theme) {
    final typeColor = _getDocumentTypeColor(doc.type, theme);
    final hasThumbnail = _thumbnailCache.containsKey(doc.filename);
    final hasLogo = _logoCache.containsKey(doc.filename);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDocument(doc),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Main content area with optional thumbnail background
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: typeColor.withValues(alpha: 0.15),
                  image: hasThumbnail
                      ? DecorationImage(
                          image: MemoryImage(_thumbnailCache[doc.filename]!),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: Stack(
                  children: [
                    // Gradient overlay for readability when thumbnail exists
                    if (hasThumbnail)
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.1),
                              Colors.black.withValues(alpha: 0.4),
                            ],
                          ),
                        ),
                      ),
                    // Centered type icon
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: hasThumbnail
                              ? Colors.black.withValues(alpha: 0.4)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          _getDocumentTypeIcon(doc.type),
                          size: 40,
                          color: hasThumbnail ? Colors.white : typeColor,
                        ),
                      ),
                    ),
                    // Three-dot menu in upper-right corner
                    Positioned(
                      right: 0,
                      top: 0,
                      child: PopupMenuButton<String>(
                        icon: Icon(
                          Icons.more_vert,
                          size: 20,
                          color: hasThumbnail
                              ? Colors.white
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        padding: EdgeInsets.zero,
                        onSelected: (action) {
                          switch (action) {
                            case 'rename':
                              _renameDocument(doc);
                              break;
                            case 'description':
                              _editDocumentDescription(doc);
                              break;
                            case 'move':
                              _moveDocument(doc);
                              break;
                            case 'settings':
                              _showDocumentSettingsDialog(doc);
                              break;
                            case 'delete':
                              _deleteDocument(doc);
                              break;
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'rename',
                            child: Row(
                              children: [
                                const Icon(Icons.edit_outlined),
                                const SizedBox(width: 8),
                                Text(_i18n.t('rename')),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'description',
                            child: Row(
                              children: [
                                const Icon(Icons.short_text),
                                const SizedBox(width: 8),
                                Text(_i18n.t('work_edit_description')),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'move',
                            child: Row(
                              children: [
                                const Icon(Icons.drive_file_move_outlined),
                                const SizedBox(width: 8),
                                Text(_i18n.t('move_document')),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'settings',
                            child: Row(
                              children: [
                                const Icon(Icons.settings_outlined),
                                const SizedBox(width: 8),
                                Text(_i18n.t('work_document_settings')),
                              ],
                            ),
                          ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_outline,
                                    color: theme.colorScheme.error),
                                const SizedBox(width: 8),
                                Text(
                                  _i18n.t('delete'),
                                  style: TextStyle(color: theme.colorScheme.error),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Bottom bar with title, date, and logo
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title on its own line
                  Text(
                    doc.title,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  // Date and logo row
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _formatDate(doc.modified),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 10,
                          ),
                        ),
                      ),
                      // Logo in bottom-right corner
                      if (hasLogo)
                        Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.15),
                                blurRadius: 1,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(1),
                            child: Image.memory(
                              _logoCache[doc.filename]!,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return const Icon(Icons.broken_image, color: Colors.grey);
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDocumentSettingsDialog(NdfDocumentRef doc) async {
    final theme = Theme.of(context);
    final filePath = _storage.documentPath(widget.workspaceId, doc.filename);
    final metadata = await _ndfService.readMetadata(filePath);
    if (metadata == null) return;

    final descriptionController = TextEditingController(text: metadata.description ?? '');
    Uint8List? currentThumbnail = _thumbnailCache[doc.filename];
    Uint8List? currentLogo = _logoCache[doc.filename];

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(_i18n.t('work_document_settings')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Description field
                  Text(
                    _i18n.t('description'),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: descriptionController,
                    decoration: InputDecoration(
                      hintText: _i18n.t('work_no_description'),
                      border: const OutlineInputBorder(),
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 16),

                  // Thumbnail section
                  Text(
                    _i18n.t('work_document_thumbnail'),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      width: 160,
                      height: 90,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: currentThumbnail != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(7),
                              child: Image.memory(
                                currentThumbnail!,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Icon(
                                    Icons.broken_image,
                                    size: 40,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  );
                                },
                              ),
                            )
                          : Icon(
                              Icons.image_outlined,
                              size: 40,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final image = await _imagePicker.pickImage(
                            source: ImageSource.gallery,
                            maxWidth: 800,
                            maxHeight: 600,
                          );
                          if (image != null) {
                            final bytes = await image.readAsBytes();
                            await _ndfService.embedThumbnail(filePath, bytes);
                            currentThumbnail = bytes;
                            _thumbnailCache[doc.filename] = bytes;
                            setDialogState(() {});
                          }
                        },
                        icon: const Icon(Icons.upload),
                        label: Text(_i18n.t('work_set_thumbnail')),
                      ),
                      if (currentThumbnail != null) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () async {
                            await _ndfService.removeThumbnail(filePath);
                            currentThumbnail = null;
                            _thumbnailCache.remove(doc.filename);
                            setDialogState(() {});
                          },
                          icon: Icon(
                            Icons.delete_outline,
                            color: theme.colorScheme.error,
                          ),
                          tooltip: _i18n.t('work_remove_thumbnail'),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Logo section
                  Text(
                    _i18n.t('work_document_logo'),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: currentLogo != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(7),
                              child: Image.memory(
                                currentLogo!,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Icon(
                                    Icons.broken_image,
                                    size: 32,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  );
                                },
                              ),
                            )
                          : Icon(
                              Icons.image_outlined,
                              size: 32,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final image = await _imagePicker.pickImage(
                            source: ImageSource.gallery,
                            maxWidth: 256,
                            maxHeight: 256,
                          );
                          if (image != null) {
                            final bytes = await image.readAsBytes();
                            final extension = image.path.split('.').last.toLowerCase();
                            await _ndfService.embedLogo(filePath, bytes, extension);
                            currentLogo = bytes;
                            _logoCache[doc.filename] = bytes;
                            setDialogState(() {});
                          }
                        },
                        icon: const Icon(Icons.upload),
                        label: Text(_i18n.t('work_set_logo')),
                      ),
                      if (currentLogo != null) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () async {
                            await _ndfService.removeLogo(filePath);
                            currentLogo = null;
                            _logoCache.remove(doc.filename);
                            setDialogState(() {});
                          },
                          icon: Icon(
                            Icons.delete_outline,
                            color: theme.colorScheme.error,
                          ),
                          tooltip: _i18n.t('work_remove_logo'),
                        ),
                      ],
                    ],
                  ),
                  // Apply workspace logo option
                  if (_workspaceLogo != null && currentLogo == null) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () async {
                        final extension = _workspace?.logo?.split('.').last ?? 'png';
                        await _ndfService.embedLogo(filePath, _workspaceLogo!, extension);
                        currentLogo = _workspaceLogo;
                        _logoCache[doc.filename] = _workspaceLogo!;
                        setDialogState(() {});
                      },
                      icon: const Icon(Icons.sync),
                      label: Text(_i18n.t('work_apply_workspace_logo')),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_i18n.t('cancel')),
              ),
              FilledButton(
                onPressed: () async {
                  // Update description
                  final newDesc = descriptionController.text.trim();
                  if (newDesc != (metadata.description ?? '')) {
                    metadata.description = newDesc.isEmpty ? null : newDesc;
                    metadata.touch();
                    await _ndfService.updateMetadata(filePath, metadata);
                  }
                  if (mounted) {
                    Navigator.pop(context);
                    await _loadWorkspace();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(_i18n.t('document_saved'))),
                    );
                  }
                },
                child: Text(_i18n.t('save')),
              ),
            ],
          );
        },
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        return '${diff.inMinutes}m ago';
      }
      return '${diff.inHours}h ago';
    }
    if (diff.inDays == 1) {
      return 'Yesterday';
    }
    if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    }

    return '${date.day}/${date.month}/${date.year}';
  }
}

/// Dialog for selecting a folder within the workspace
class _FolderPickerDialog extends StatelessWidget {
  final I18nService i18n;
  final List<WorkspaceFolder> folders;
  final String? currentFolderId;

  const _FolderPickerDialog({
    required this.i18n,
    required this.folders,
    this.currentFolderId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Build folder tree structure
    final rootFolders = folders.where((f) => f.parentId == null).toList();

    return AlertDialog(
      title: Text(i18n.t('select_folder')),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            // Root option
            ListTile(
              leading: Icon(
                Icons.folder_special,
                color: currentFolderId == null
                    ? theme.colorScheme.primary
                    : null,
              ),
              title: Text(
                i18n.t('root_folder'),
                style: currentFolderId == null
                    ? TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      )
                    : null,
              ),
              trailing: currentFolderId == null
                  ? Icon(Icons.check, color: theme.colorScheme.primary)
                  : null,
              onTap: () => Navigator.pop(context, ''), // Empty string = root
            ),
            if (rootFolders.isNotEmpty) const Divider(),
            // Folder tree
            ..._buildFolderTree(context, rootFolders, 0),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context), // null = cancelled
          child: Text(i18n.t('cancel')),
        ),
      ],
    );
  }

  List<Widget> _buildFolderTree(
    BuildContext context,
    List<WorkspaceFolder> folderList,
    int depth,
  ) {
    final theme = Theme.of(context);
    final widgets = <Widget>[];

    for (final folder in folderList) {
      final isCurrentFolder = folder.id == currentFolderId;
      final childFolders = folders.where((f) => f.parentId == folder.id).toList();

      widgets.add(
        ListTile(
          contentPadding: EdgeInsets.only(left: 16.0 + (depth * 24.0), right: 16),
          leading: Icon(
            Icons.folder,
            color: isCurrentFolder ? theme.colorScheme.primary : null,
          ),
          title: Text(
            folder.name,
            style: isCurrentFolder
                ? TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  )
                : null,
          ),
          trailing: isCurrentFolder
              ? Icon(Icons.check, color: theme.colorScheme.primary)
              : null,
          onTap: () => Navigator.pop(context, folder.id),
        ),
      );

      // Add child folders recursively
      if (childFolders.isNotEmpty) {
        widgets.addAll(_buildFolderTree(context, childFolders, depth + 1));
      }
    }

    return widgets;
  }
}
