/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';

import '../../tracker/models/tracker_visibility.dart';
import 'ndf_interaction_settings.dart';

/// Collaborator role in a workspace
enum CollaboratorRole {
  editor,
  viewer,
}

/// A collaborator in a workspace
class WorkspaceCollaborator {
  final String npub;
  final CollaboratorRole role;
  final DateTime added;
  final String? name;
  final String? callsign;

  WorkspaceCollaborator({
    required this.npub,
    required this.role,
    required this.added,
    this.name,
    this.callsign,
  });

  factory WorkspaceCollaborator.fromJson(Map<String, dynamic> json) {
    return WorkspaceCollaborator(
      npub: json['npub'] as String,
      role: CollaboratorRole.values.firstWhere(
        (r) => r.name == json['role'],
        orElse: () => CollaboratorRole.viewer,
      ),
      added: DateTime.parse(json['added'] as String),
      name: json['name'] as String?,
      callsign: json['callsign'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'npub': npub,
    'role': role.name,
    'added': added.toIso8601String(),
    if (name != null) 'name': name,
    if (callsign != null) 'callsign': callsign,
  };
}

/// A folder within a workspace
class WorkspaceFolder {
  final String id;
  String name;
  final String? parentId;
  final DateTime created;
  DateTime modified;

  WorkspaceFolder({
    required this.id,
    required this.name,
    this.parentId,
    required this.created,
    required this.modified,
  });

  factory WorkspaceFolder.create({
    required String name,
    String? parentId,
  }) {
    final now = DateTime.now();
    final id = 'folder-${now.millisecondsSinceEpoch.toRadixString(36)}';
    return WorkspaceFolder(
      id: id,
      name: name,
      parentId: parentId,
      created: now,
      modified: now,
    );
  }

  factory WorkspaceFolder.fromJson(Map<String, dynamic> json) {
    return WorkspaceFolder(
      id: json['id'] as String,
      name: json['name'] as String,
      parentId: json['parent_id'] as String?,
      created: DateTime.parse(json['created'] as String),
      modified: DateTime.parse(json['modified'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (parentId != null) 'parent_id': parentId,
    'created': created.toIso8601String(),
    'modified': modified.toIso8601String(),
  };
}

/// A workspace containing NDF documents and folders
class Workspace {
  final String id;
  String name;
  String? description;
  String? logo; // filename in workspace folder (e.g., "logo.png")
  final DateTime created;
  DateTime modified;
  final String ownerNpub;
  final List<WorkspaceCollaborator> collaborators;
  final List<String> documents;
  final List<WorkspaceFolder> folders;
  final Map<String, String?> documentFolders; // document filename -> folder id (null = root)
  final Map<String, TrackerVisibility> documentVisibility; // document filename -> visibility settings
  final Map<String, NdfInteractionSettings> documentInteraction; // document filename -> interaction settings

  Workspace({
    required this.id,
    required this.name,
    this.description,
    this.logo,
    required this.created,
    required this.modified,
    required this.ownerNpub,
    List<WorkspaceCollaborator>? collaborators,
    List<String>? documents,
    List<WorkspaceFolder>? folders,
    Map<String, String?>? documentFolders,
    Map<String, TrackerVisibility>? documentVisibility,
    Map<String, NdfInteractionSettings>? documentInteraction,
  }) : collaborators = collaborators ?? [],
       documents = documents ?? [],
       folders = folders ?? [],
       documentFolders = documentFolders ?? {},
       documentVisibility = documentVisibility ?? {},
       documentInteraction = documentInteraction ?? {};

  factory Workspace.create({
    required String id,
    required String name,
    required String ownerNpub,
    String? description,
    String? logo,
  }) {
    final now = DateTime.now();
    return Workspace(
      id: id,
      name: name,
      description: description,
      logo: logo,
      created: now,
      modified: now,
      ownerNpub: ownerNpub,
    );
  }

  factory Workspace.fromJson(Map<String, dynamic> json) {
    final docFoldersJson = json['document_folders'] as Map<String, dynamic>?;
    final docFolders = <String, String?>{};
    if (docFoldersJson != null) {
      for (final entry in docFoldersJson.entries) {
        docFolders[entry.key] = entry.value as String?;
      }
    }

    final docVisJson = json['document_visibility'] as Map<String, dynamic>?;
    final docVis = <String, TrackerVisibility>{};
    if (docVisJson != null) {
      for (final entry in docVisJson.entries) {
        docVis[entry.key] = TrackerVisibility.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    }

    return Workspace(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      logo: json['logo'] as String?,
      created: DateTime.parse(json['created'] as String),
      modified: DateTime.parse(json['modified'] as String),
      ownerNpub: json['owner_npub'] as String,
      collaborators: (json['collaborators'] as List<dynamic>?)
          ?.map((c) => WorkspaceCollaborator.fromJson(c as Map<String, dynamic>))
          .toList() ?? [],
      documents: (json['documents'] as List<dynamic>?)
          ?.map((d) => d as String)
          .toList() ?? [],
      folders: (json['folders'] as List<dynamic>?)
          ?.map((f) => WorkspaceFolder.fromJson(f as Map<String, dynamic>))
          .toList() ?? [],
      documentFolders: docFolders,
      documentVisibility: docVis,
      documentInteraction: _parseInteraction(json['document_interaction']),
    );
  }

  static Map<String, NdfInteractionSettings> _parseInteraction(dynamic raw) {
    final map = <String, NdfInteractionSettings>{};
    if (raw is Map<String, dynamic>) {
      for (final entry in raw.entries) {
        map[entry.key] = NdfInteractionSettings.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    }
    return map;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (description != null) 'description': description,
    if (logo != null) 'logo': logo,
    'created': created.toIso8601String(),
    'modified': modified.toIso8601String(),
    'owner_npub': ownerNpub,
    'collaborators': collaborators.map((c) => c.toJson()).toList(),
    'documents': documents,
    'folders': folders.map((f) => f.toJson()).toList(),
    'document_folders': documentFolders,
    if (documentVisibility.isNotEmpty)
      'document_visibility': {
        for (final e in documentVisibility.entries) e.key: e.value.toJson(),
      },
    if (documentInteraction.isNotEmpty)
      'document_interaction': {
        for (final e in documentInteraction.entries) e.key: e.value.toJson(),
      },
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Touch the modified timestamp
  void touch() {
    modified = DateTime.now();
  }

  /// Add a collaborator
  void addCollaborator(WorkspaceCollaborator collaborator) {
    collaborators.removeWhere((c) => c.npub == collaborator.npub);
    collaborators.add(collaborator);
    touch();
  }

  /// Remove a collaborator
  void removeCollaborator(String npub) {
    collaborators.removeWhere((c) => c.npub == npub);
    touch();
  }

  /// Add a document filename to a folder (null = root)
  void addDocument(String filename, {String? folderId}) {
    if (!documents.contains(filename)) {
      documents.add(filename);
    }
    documentFolders[filename] = folderId;
    touch();
  }

  /// Remove a document filename
  void removeDocument(String filename) {
    documents.remove(filename);
    documentFolders.remove(filename);
    touch();
  }

  /// Add a folder
  void addFolder(WorkspaceFolder folder) {
    folders.add(folder);
    touch();
  }

  /// Remove a folder and move its contents to parent
  void removeFolder(String folderId) {
    final folder = folders.where((f) => f.id == folderId).firstOrNull;
    if (folder == null) return;

    // Move documents in this folder to parent
    for (final entry in documentFolders.entries.toList()) {
      if (entry.value == folderId) {
        documentFolders[entry.key] = folder.parentId;
      }
    }

    // Move subfolders to parent
    for (final subfolder in folders.where((f) => f.parentId == folderId)) {
      folders[folders.indexOf(subfolder)] = WorkspaceFolder(
        id: subfolder.id,
        name: subfolder.name,
        parentId: folder.parentId,
        created: subfolder.created,
        modified: DateTime.now(),
      );
    }

    folders.removeWhere((f) => f.id == folderId);
    touch();
  }

  /// Get folders in a specific parent (null = root)
  List<WorkspaceFolder> getFoldersIn(String? parentId) {
    return folders.where((f) => f.parentId == parentId).toList();
  }

  /// Get documents in a specific folder (null = root)
  List<String> getDocumentsIn(String? folderId) {
    return documents.where((d) => documentFolders[d] == folderId).toList();
  }

  /// Move document to folder
  void moveDocument(String filename, String? toFolderId) {
    if (documents.contains(filename)) {
      documentFolders[filename] = toFolderId;
      touch();
    }
  }

  /// Rename document (update filename references)
  void renameDocument(String oldFilename, String newFilename) {
    final index = documents.indexOf(oldFilename);
    if (index != -1) {
      documents[index] = newFilename;
      // Preserve folder assignment
      final folderId = documentFolders[oldFilename];
      documentFolders.remove(oldFilename);
      documentFolders[newFilename] = folderId;
      touch();
    }
  }

  /// Get visibility settings for a document (defaults to private)
  TrackerVisibility getDocumentVisibility(String filename) {
    return documentVisibility[filename] ?? TrackerVisibility.private;
  }

  /// Set visibility settings for a document
  void setDocumentVisibility(String filename, TrackerVisibility visibility) {
    documentVisibility[filename] = visibility;
    touch();
  }

  /// Get interaction settings for a document (defaults to none)
  NdfInteractionSettings getDocumentInteraction(String filename) {
    return documentInteraction[filename] ?? NdfInteractionSettings.none;
  }

  /// Set interaction settings for a document
  void setDocumentInteraction(String filename, NdfInteractionSettings settings) {
    documentInteraction[filename] = settings;
    touch();
  }

  /// Generate a filesystem-safe ID from name
  static String generateId(String name) {
    // Sanitize for filesystem: replace forbidden chars with underscore
    var id = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'[\x00-\x1F]'), '')
        .trim();

    // Remove leading/trailing dots
    while (id.startsWith('.')) {
      id = id.substring(1);
    }
    while (id.endsWith('.')) {
      id = id.substring(0, id.length - 1);
    }

    // Limit length
    if (id.length > 200) {
      id = id.substring(0, 200);
    }

    return id.isEmpty ? 'workspace' : id.trim();
  }
}
