/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../services/i18n_service.dart';
import '../../services/log_service.dart';
import '../../services/profile_service.dart';
import '../../services/station_service.dart';
import '../../services/websocket_service.dart';
import '../../util/callsign_url.dart';
import '../models/ndf_document.dart';
import '../models/ndf_interaction_settings.dart';
import '../models/spreadsheet_content.dart';
import '../services/ndf_service.dart';
import '../services/work_storage_service.dart';
import '../widgets/document_interaction_widget.dart';
import '../widgets/document_visibility_widget.dart';
import '../widgets/spreadsheet/sheet_grid_widget.dart';

/// Spreadsheet editor page
class SpreadsheetEditorPage extends StatefulWidget {
  final String filePath;
  final String? title;
  final String? workspaceId;
  final String? documentFilename;
  final WorkStorageService? workStorage;

  const SpreadsheetEditorPage({
    super.key,
    required this.filePath,
    this.title,
    this.workspaceId,
    this.documentFilename,
    this.workStorage,
  });

  @override
  State<SpreadsheetEditorPage> createState() => _SpreadsheetEditorPageState();
}

class _SpreadsheetEditorPageState extends State<SpreadsheetEditorPage>
    with TickerProviderStateMixin {
  final I18nService _i18n = I18nService();
  final NdfService _ndfService = NdfService();

  NdfDocument? _metadata;
  SpreadsheetContent? _content;
  Map<String, SpreadsheetSheet> _sheets = {};
  String? _activeSheetId;
  bool _isLoading = true;
  bool _hasChanges = false;
  String? _error;

  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 0, vsync: this);
    _loadDocument();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadDocument() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Load metadata
      final metadata = await _ndfService.readMetadata(widget.filePath);
      if (metadata == null) {
        throw Exception('Could not read document metadata');
      }

      // Load content
      final content = await _ndfService.readSpreadsheetContent(widget.filePath);
      if (content == null) {
        throw Exception('Could not read spreadsheet content');
      }

      // Load all sheets
      final sheets = <String, SpreadsheetSheet>{};
      for (final sheetId in content.sheets) {
        final sheet = await _ndfService.readSheet(widget.filePath, sheetId);
        if (sheet != null) {
          sheets[sheetId] = sheet;
        } else {
          // Create default sheet if not found
          sheets[sheetId] = SpreadsheetSheet.create(
            id: sheetId,
            name: 'Sheet ${sheets.length + 1}',
            index: sheets.length,
          );
        }
      }

      // Ensure we have at least one sheet
      if (sheets.isEmpty) {
        final defaultSheetId = 'sheet-001';
        sheets[defaultSheetId] = SpreadsheetSheet.create(
          id: defaultSheetId,
          name: 'Sheet 1',
        );
        content.sheets.add(defaultSheetId);
        content.activeSheet = defaultSheetId;
      }

      // Update tab controller
      _tabController.dispose();
      _tabController = TabController(length: sheets.length, vsync: this);

      setState(() {
        _metadata = metadata;
        _content = content;
        _sheets = sheets;
        _activeSheetId = content.activeSheet;
        _isLoading = false;
      });

      // Set initial tab
      final activeIndex = content.sheets.indexOf(content.activeSheet);
      if (activeIndex >= 0) {
        _tabController.index = activeIndex;
      }

      _tabController.addListener(_onTabChanged);
    } catch (e) {
      LogService().log('SpreadsheetEditorPage: Error loading document: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _onTabChanged() {
    if (_content == null) return;
    final index = _tabController.index;
    if (index >= 0 && index < _content!.sheets.length) {
      setState(() {
        _activeSheetId = _content!.sheets[index];
        _content!.activeSheet = _activeSheetId!;
        _hasChanges = true;
      });
    }
  }

  Future<void> _save() async {
    if (_content == null || _metadata == null) return;

    try {
      // Update metadata modified time
      _metadata!.touch();

      // Save all sheets
      await _ndfService.saveSpreadsheet(widget.filePath, _content!, _sheets);

      // Update metadata
      await _ndfService.updateMetadata(widget.filePath, _metadata!);

      setState(() {
        _hasChanges = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('document_saved'))),
        );
      }
    } catch (e) {
      LogService().log('SpreadsheetEditorPage: Error saving document: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e')),
        );
      }
    }
  }

  Future<void> _showVisibilitySheet() async {
    final workspaceId = widget.workspaceId;
    final filename = widget.documentFilename;
    final storage = widget.workStorage;
    if (workspaceId == null || filename == null || storage == null) return;

    final workspace = await storage.loadWorkspace(workspaceId);
    if (workspace == null) return;

    var visibility = workspace.getDocumentVisibility(filename);
    var interaction = workspace.getDocumentInteraction(filename);

    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DocumentVisibilityWidget(
                      visibility: visibility,
                      onChanged: (newVis) async {
                        setSheetState(() => visibility = newVis);
                        workspace.setDocumentVisibility(filename, newVis);
                        await storage.saveWorkspace(workspace);
                      },
                      shareUrl: _buildShareUrl(workspaceId, filename),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Divider(color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: DocumentInteractionWidget(
                        interaction: interaction,
                        onChanged: (newInt) async {
                          setSheetState(() => interaction = newInt);
                          workspace.setDocumentInteraction(filename, newInt);
                          await storage.saveWorkspace(workspace);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String? _buildShareUrl(String workspaceId, String filename) {
    if (!WebSocketService().isConnected) return null;
    final station = StationService().getPreferredStation();
    final connected = StationService().getConnectedStation();
    final url = station?.url.isNotEmpty == true ? station!.url : connected?.url;
    if (url == null || url.isEmpty) return null;

    var domain = url.replaceFirst('wss://', '').replaceFirst('ws://', '');
    if (domain.endsWith('/')) domain = domain.substring(0, domain.length - 1);

    final callsign = ProfileService().getProfile().callsign;
    if (callsign.isEmpty) return null;

    return 'https://$domain/${callsignForUrl(callsign)}/work/$workspaceId/$filename';
  }

  void _onSheetChanged(SpreadsheetSheet sheet) {
    setState(() {
      _sheets[sheet.id] = sheet;
      _hasChanges = true;
    });
  }

  Future<void> _addSheet() async {
    if (_content == null) return;

    final newId = 'sheet-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final newSheet = SpreadsheetSheet.create(
      id: newId,
      name: 'Sheet ${_sheets.length + 1}',
      index: _sheets.length,
    );

    // Update tab controller
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();

    setState(() {
      _sheets[newId] = newSheet;
      _content!.sheets.add(newId);
      _hasChanges = true;
    });

    _tabController = TabController(length: _sheets.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    _tabController.index = _sheets.length - 1;
    _activeSheetId = newId;
    _content!.activeSheet = newId;
  }

  Future<void> _renameSheet(String sheetId) async {
    final sheet = _sheets[sheetId];
    if (sheet == null) return;

    final controller = TextEditingController(text: sheet.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('rename_sheet')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _i18n.t('sheet_name'),
            border: const OutlineInputBorder(),
          ),
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

    if (result != null && result.isNotEmpty && result != sheet.name) {
      setState(() {
        sheet.name = result;
        _hasChanges = true;
      });
    }
  }

  Future<void> _renameDocument() async {
    if (_metadata == null) return;

    final controller = TextEditingController(text: _metadata!.title);
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

    if (result != null && result.isNotEmpty && result != _metadata!.title) {
      setState(() {
        _metadata!.title = result;
        _hasChanges = true;
      });
    }
  }

  bool get _isDesktop {
    if (kIsWeb) return false;
    return Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  }

  Future<bool> _onWillPop() async {
    if (!_hasChanges) return true;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('unsaved_changes')),
        content: Text(_i18n.t('unsaved_changes_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('discard')),
          ),
          FilledButton(
            onPressed: () async {
              await _save();
              if (mounted) Navigator.pop(context, true);
            },
            child: Text(_i18n.t('save')),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) {
          final shouldPop = await _onWillPop();
          if (shouldPop && mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: _isDesktop ? _renameDocument : null,
            onLongPress: _isDesktop ? null : _renameDocument,
            child: Text(_metadata?.title ?? widget.title ?? _i18n.t('work_spreadsheet')),
          ),
          actions: [
            if (widget.workspaceId != null && widget.documentFilename != null)
              IconButton(
                icon: const Icon(Icons.share_outlined),
                onPressed: _showVisibilitySheet,
                tooltip: _i18n.t('share'),
              ),
            if (_hasChanges)
              IconButton(
                icon: const Icon(Icons.save),
                onPressed: _save,
                tooltip: _i18n.t('save'),
              ),
          ],
        ),
        body: _buildBody(theme),
        bottomNavigationBar: _content != null ? _buildSheetTabs(theme) : null,
      ),
    );
  }

  Widget _buildSheetTabs(ThemeData theme) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          // Add sheet button
          IconButton(
            icon: const Icon(Icons.add, size: 20),
            onPressed: _addSheet,
            tooltip: _i18n.t('add_sheet'),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            constraints: const BoxConstraints(minWidth: 36),
          ),
          VerticalDivider(
            width: 1,
            indent: 8,
            endIndent: 8,
            color: theme.colorScheme.outlineVariant,
          ),
          // Sheet tabs
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _content!.sheets.length,
              itemBuilder: (context, index) {
                final sheetId = _content!.sheets[index];
                final sheet = _sheets[sheetId];
                final isActive = sheetId == _activeSheetId;
                return GestureDetector(
                  onTap: () {
                    if (!isActive) {
                      _tabController.index = index;
                    }
                  },
                  onDoubleTap: () => _renameSheet(sheetId),
                  onLongPress: () => _renameSheet(sheetId),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: isActive
                          ? theme.colorScheme.surface
                          : null,
                      border: Border(
                        top: BorderSide(
                          color: isActive
                              ? theme.colorScheme.primary
                              : Colors.transparent,
                          width: 2,
                        ),
                        right: BorderSide(color: theme.colorScheme.outlineVariant),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      sheet?.name ?? sheetId,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: isActive ? FontWeight.w600 : null,
                        color: isActive
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
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
            Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(_i18n.t('error_loading_document')),
            const SizedBox(height: 8),
            Text(_error!, style: theme.textTheme.bodySmall),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loadDocument,
              icon: const Icon(Icons.refresh),
              label: Text(_i18n.t('retry')),
            ),
          ],
        ),
      );
    }

    if (_activeSheetId == null || !_sheets.containsKey(_activeSheetId)) {
      return Center(child: Text(_i18n.t('no_sheets')));
    }

    final activeSheet = _sheets[_activeSheetId]!;

    if (_sheets.length > 1) {
      return TabBarView(
        controller: _tabController,
        children: _content!.sheets.map((sheetId) {
          final sheet = _sheets[sheetId]!;
          return SheetGridWidget(
            key: ValueKey(sheetId),
            sheet: sheet,
            onChanged: _onSheetChanged,
          );
        }).toList(),
      );
    }

    return SheetGridWidget(
      sheet: activeSheet,
      onChanged: _onSheetChanged,
    );
  }
}
