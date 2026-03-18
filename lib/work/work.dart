/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Work module for NDF document workspaces
///
/// Usage:
/// ```dart
/// import 'package:geogram/work/work.dart';
///
/// final storage = WorkStorageService('/path/to/work');
/// final workspaces = await storage.loadWorkspaces();
/// ```
library;

// Models
export 'models/workspace.dart';
export 'models/ndf_document.dart';
export 'models/ndf_interaction_settings.dart';
export 'models/ndf_permission.dart';
export 'models/spreadsheet_content.dart';
export 'models/document_content.dart';
export 'models/form_content.dart';

// Services
export 'services/ndf_service.dart';
export 'services/ndf_web_viewer_service.dart';
export 'services/work_storage_service.dart';
export 'services/formula_service.dart';

// Pages
export 'pages/work_page.dart';
export 'pages/workspace_detail_page.dart';
export 'pages/spreadsheet_editor_page.dart';
export 'pages/document_editor_page.dart';
export 'pages/form_editor_page.dart';

// Widgets
export 'widgets/spreadsheet/sheet_grid_widget.dart';
export 'widgets/document/rich_text_widget.dart';
export 'widgets/document_interaction_widget.dart';
export 'widgets/document_visibility_widget.dart';
export 'widgets/form/form_field_widget.dart';
