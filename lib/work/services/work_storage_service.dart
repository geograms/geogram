/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:typed_data';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../models/workspace.dart';
import '../models/ndf_document.dart';
import 'ndf_service.dart';

/// Service for managing workspace storage
/// Now uses ProfileStorage abstraction for encrypted storage support
class WorkStorageService {
  final ProfileStorage _storage;
  final String _relativePath;

  WorkStorageService(this._storage, this._relativePath);

  /// Get the workspaces directory relative path
  String get workspacesPath => '$_relativePath/workspaces';

  /// Get the path for a specific workspace
  String workspacePath(String workspaceId) => '$workspacesPath/$workspaceId';

  /// Get the workspace.json path for a workspace
  String workspaceConfigPath(String workspaceId) =>
      '${workspacePath(workspaceId)}/workspace.json';

  /// Initialize the storage directory structure
  Future<void> initialize() async {
    if (!await _storage.directoryExists(workspacesPath)) {
      await _storage.createDirectory(workspacesPath);
      LogService().log('WorkStorageService: Created workspaces directory');
    }
  }

  /// Load all workspaces
  Future<List<Workspace>> loadWorkspaces() async {
    final workspaces = <Workspace>[];

    if (!await _storage.directoryExists(workspacesPath)) {
      return workspaces;
    }

    final entries = await _storage.listDirectory(workspacesPath);
    for (final entry in entries) {
      if (entry.isDirectory) {
        try {
          final workspaceId = entry.name;
          final workspace = await loadWorkspace(workspaceId);
          if (workspace != null) {
            workspaces.add(workspace);
          }
        } catch (e) {
          LogService().log('WorkStorageService: Error loading workspace ${entry.path}: $e');
        }
      }
    }

    // Sort by modified date (newest first)
    workspaces.sort((a, b) => b.modified.compareTo(a.modified));
    return workspaces;
  }

  /// Load a specific workspace by ID
  Future<Workspace?> loadWorkspace(String workspaceId) async {
    final configPath = workspaceConfigPath(workspaceId);

    if (!await _storage.exists(configPath)) {
      return null;
    }

    try {
      final content = await _storage.readString(configPath);
      if (content == null) return null;
      final json = jsonDecode(content) as Map<String, dynamic>;
      return Workspace.fromJson(json);
    } catch (e) {
      LogService().log('WorkStorageService: Error parsing workspace $workspaceId: $e');
      return null;
    }
  }

  /// Save a workspace
  Future<void> saveWorkspace(Workspace workspace) async {
    final wsPath = workspacePath(workspace.id);

    if (!await _storage.directoryExists(wsPath)) {
      await _storage.createDirectory(wsPath);
    }

    await _storage.writeString(workspaceConfigPath(workspace.id), workspace.toJsonString());
    LogService().log('WorkStorageService: Saved workspace ${workspace.id}');
  }

  /// Create a new workspace
  Future<Workspace> createWorkspace({
    required String name,
    required String ownerNpub,
    String? description,
  }) async {
    // Generate unique folder ID from name
    final baseId = Workspace.generateId(name);
    var id = baseId;
    var counter = 1;

    // Check for collisions
    while (await _storage.directoryExists(workspacePath(id))) {
      counter++;
      id = '$baseId ($counter)';
    }

    final workspace = Workspace.create(
      id: id,
      name: name,
      ownerNpub: ownerNpub,
      description: description,
    );

    await saveWorkspace(workspace);
    return workspace;
  }

  /// Delete a workspace
  Future<void> deleteWorkspace(String workspaceId) async {
    if (await _storage.directoryExists(workspacePath(workspaceId))) {
      await _storage.deleteDirectory(workspacePath(workspaceId), recursive: true);
      LogService().log('WorkStorageService: Deleted workspace $workspaceId');
    }
  }

  /// List all NDF documents in a workspace
  Future<List<NdfDocumentRef>> listDocuments(String workspaceId) async {
    final documents = <NdfDocumentRef>[];
    final wsPath = workspacePath(workspaceId);

    if (!await _storage.directoryExists(wsPath)) {
      return documents;
    }

    final entries = await _storage.listDirectory(wsPath);
    for (final entry in entries) {
      if (!entry.isDirectory && entry.name.endsWith('.ndf')) {
        try {
          final ref = await _readDocumentRef(workspaceId, entry.name, entry.size ?? 0);
          if (ref != null) {
            documents.add(ref);
          }
        } catch (e) {
          LogService().log('WorkStorageService: Error reading NDF ${entry.name}: $e');
        }
      }
    }

    // Sort by modified date (newest first)
    documents.sort((a, b) => b.modified.compareTo(a.modified));
    return documents;
  }

  /// Read NDF document metadata from storage
  Future<NdfDocumentRef?> _readDocumentRef(String workspaceId, String filename, int fileSize) async {
    final ndfPath = documentPath(workspaceId, filename);
    final ndfService = NdfService();

    // Read NDF archive as bytes
    final bytes = await _storage.readBytes(ndfPath);
    if (bytes == null) return null;

    // Read metadata using bytes-based method
    final metadata = ndfService.readMetadataFromBytes(bytes);

    if (metadata != null) {
      return NdfDocumentRef(
        filename: filename,
        type: metadata.type,
        title: metadata.title,
        description: metadata.description,
        logo: metadata.logo,
        thumbnail: metadata.thumbnail,
        modified: metadata.modified,
        fileSize: fileSize,
      );
    }

    // Fallback if metadata cannot be read
    final basename = filename.replaceAll('.ndf', '');
    return NdfDocumentRef(
      filename: filename,
      type: NdfDocumentType.document,
      title: basename.replaceAll('-', ' ').replaceAll('_', ' '),
      modified: DateTime.now(),
      fileSize: fileSize,
    );
  }

  /// Get the path for the workspace logo file
  String? workspaceLogoPath(String workspaceId, String? logoFilename) {
    if (logoFilename == null) return null;
    return '${workspacePath(workspaceId)}/$logoFilename';
  }

  /// Read the workspace logo bytes
  Future<Uint8List?> readWorkspaceLogo(String workspaceId) async {
    final workspace = await loadWorkspace(workspaceId);
    if (workspace?.logo == null) return null;

    final logoPath = workspaceLogoPath(workspaceId, workspace!.logo);
    if (logoPath == null) return null;

    return _storage.readBytes(logoPath);
  }

  /// Save a workspace logo
  Future<String> saveWorkspaceLogo(String workspaceId, Uint8List logoBytes, String extension) async {
    final filename = 'logo.$extension';
    final logoPath = '${workspacePath(workspaceId)}/$filename';
    await _storage.writeBytes(logoPath, logoBytes);

    // Update workspace with logo filename
    final workspace = await loadWorkspace(workspaceId);
    if (workspace != null) {
      workspace.logo = filename;
      workspace.touch();
      await saveWorkspace(workspace);
    }

    LogService().log('WorkStorageService: Saved workspace logo $filename');
    return filename;
  }

  /// Delete the workspace logo
  Future<void> deleteWorkspaceLogo(String workspaceId) async {
    final workspace = await loadWorkspace(workspaceId);
    if (workspace?.logo == null) return;

    final logoPath = workspaceLogoPath(workspaceId, workspace!.logo);
    if (logoPath != null) {
      await _storage.delete(logoPath);
    }

    workspace.logo = null;
    workspace.touch();
    await saveWorkspace(workspace);

    LogService().log('WorkStorageService: Deleted workspace logo');
  }

  /// Get the relative path for an NDF document in a workspace
  String documentPath(String workspaceId, String filename) =>
      '${workspacePath(workspaceId)}/$filename';

  /// Get the feedback directory path for a document
  /// Structure: workspaces/{id}/feedback/{sanitized_filename}/
  String documentFeedbackPath(String workspaceId, String filename) {
    final safeName = filename.replaceAll('.ndf', '').replaceAll(RegExp(r'[^\w-]'), '_');
    return '${workspacePath(workspaceId)}/feedback/$safeName';
  }

  /// Get the ProfileStorage instance (for passing to FeedbackFolderUtils)
  ProfileStorage get storage => _storage;

  /// Read NDF document bytes
  Future<Uint8List?> readDocumentBytes(String workspaceId, String filename) async {
    return _storage.readBytes(documentPath(workspaceId, filename));
  }

  /// Write NDF document bytes
  Future<void> writeDocumentBytes(String workspaceId, String filename, Uint8List bytes) async {
    await _storage.writeBytes(documentPath(workspaceId, filename), bytes);
    LogService().log('WorkStorageService: Wrote document $filename to $workspaceId');
  }

  /// Delete an NDF document
  Future<void> deleteDocument(String workspaceId, String filename) async {
    final docPath = documentPath(workspaceId, filename);
    if (await _storage.exists(docPath)) {
      await _storage.delete(docPath);
      LogService().log('WorkStorageService: Deleted document $filename from $workspaceId');

      // Update workspace to remove document reference
      final workspace = await loadWorkspace(workspaceId);
      if (workspace != null) {
        workspace.removeDocument(filename);
        await saveWorkspace(workspace);
      }
    }
  }

}
