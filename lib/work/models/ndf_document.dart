/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';

/// NDF document types supported by the Work app
enum NdfDocumentType {
  spreadsheet,
  document,
  presentation,
  form,
  todo,
  voicememo,
  websnapshot,
  meeting,
  accounting,
}

/// Metadata for an NDF document (from ndf.json inside the archive)
class NdfDocument {
  final String ndfVersion;
  final NdfDocumentType type;
  final String id;
  String title;
  String? description;
  String? logo; // asset reference (e.g., "asset://logo.png")
  String? thumbnail; // asset reference (e.g., "asset://thumbnails/preview.png")
  String? language;
  final DateTime created;
  DateTime modified;
  int revision;
  List<String> tags;
  String? contentHash;
  List<String>? requiredFeatures;
  List<String>? extensions;

  NdfDocument({
    required this.ndfVersion,
    required this.type,
    required this.id,
    required this.title,
    this.description,
    this.logo,
    this.thumbnail,
    this.language,
    required this.created,
    required this.modified,
    this.revision = 1,
    List<String>? tags,
    this.contentHash,
    this.requiredFeatures,
    this.extensions,
  }) : tags = tags ?? [];

  factory NdfDocument.create({
    required NdfDocumentType type,
    required String title,
    String? description,
    String? logo,
    String? thumbnail,
    String? language,
  }) {
    final now = DateTime.now();
    final id = 'ndf-${now.millisecondsSinceEpoch.toRadixString(36)}';
    return NdfDocument(
      ndfVersion: '1.0.0',
      type: type,
      id: id,
      title: title,
      description: description,
      logo: logo,
      thumbnail: thumbnail,
      language: language ?? 'en',
      created: now,
      modified: now,
    );
  }

  factory NdfDocument.fromJson(Map<String, dynamic> json) {
    return NdfDocument(
      ndfVersion: json['ndf'] as String? ?? '1.0.0',
      type: NdfDocumentType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => NdfDocumentType.document,
      ),
      id: json['id'] as String,
      title: json['title'] as String,
      description: json['description'] as String?,
      logo: json['logo'] as String?,
      thumbnail: json['thumbnail'] as String?,
      language: json['language'] as String?,
      created: DateTime.parse(json['created'] as String),
      modified: DateTime.parse(json['modified'] as String),
      revision: json['revision'] as int? ?? 1,
      tags: (json['tags'] as List<dynamic>?)
          ?.map((t) => t as String)
          .toList() ?? [],
      contentHash: json['content_hash'] as String?,
      requiredFeatures: (json['required_features'] as List<dynamic>?)
          ?.map((f) => f as String)
          .toList(),
      extensions: (json['extensions'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'ndf': ndfVersion,
    'type': type.name,
    'id': id,
    'title': title,
    if (description != null) 'description': description,
    if (logo != null) 'logo': logo,
    if (thumbnail != null) 'thumbnail': thumbnail,
    if (language != null) 'language': language,
    'created': created.toIso8601String(),
    'modified': modified.toIso8601String(),
    'revision': revision,
    if (tags.isNotEmpty) 'tags': tags,
    if (contentHash != null) 'content_hash': contentHash,
    if (requiredFeatures != null) 'required_features': requiredFeatures,
    if (extensions != null) 'extensions': extensions,
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Touch the modified timestamp and increment revision
  void touch() {
    modified = DateTime.now();
    revision++;
  }

  /// Get the file extension for this document type
  String get fileExtension => '.ndf';

  /// Get icon name for this document type
  String get iconName {
    switch (type) {
      case NdfDocumentType.spreadsheet:
        return 'table_chart';
      case NdfDocumentType.document:
        return 'description';
      case NdfDocumentType.presentation:
        return 'slideshow';
      case NdfDocumentType.form:
        return 'assignment';
      case NdfDocumentType.todo:
        return 'checklist';
      case NdfDocumentType.voicememo:
        return 'mic';
      case NdfDocumentType.websnapshot:
        return 'language';
      case NdfDocumentType.meeting:
        return 'groups';
      case NdfDocumentType.accounting:
        return 'account_balance_wallet';
    }
  }
}

/// Reference to an NDF document file within a workspace
class NdfDocumentRef {
  final String filename;
  final NdfDocumentType type;
  final String title;
  final String? description;
  final String? logo; // asset reference (e.g., "asset://logo.png")
  final String? thumbnail; // asset reference (e.g., "asset://thumbnails/preview.png")
  final DateTime modified;
  final int? fileSize;

  NdfDocumentRef({
    required this.filename,
    required this.type,
    required this.title,
    this.description,
    this.logo,
    this.thumbnail,
    required this.modified,
    this.fileSize,
  });
}
