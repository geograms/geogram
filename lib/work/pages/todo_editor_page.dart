/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/i18n_service.dart';
import '../../services/log_service.dart';
import '../../services/profile_service.dart';
import '../../services/station_service.dart';
import '../../services/websocket_service.dart';
import '../../util/callsign_url.dart';
import '../../widgets/transcribe_button_widget.dart';
import '../models/ndf_document.dart';
import '../models/ndf_interaction_settings.dart';
import '../models/todo_content.dart';
import '../services/ndf_service.dart';
import '../services/work_storage_service.dart';
import '../widgets/document_interaction_widget.dart';
import '../widgets/document_visibility_widget.dart';
import '../widgets/todo/todo_item_card_widget.dart';

/// TODO list editor page
class TodoEditorPage extends StatefulWidget {
  final String filePath;
  final String? title;
  final String? workspaceId;
  final String? documentFilename;
  final WorkStorageService? workStorage;

  const TodoEditorPage({
    super.key,
    required this.filePath,
    this.title,
    this.workspaceId,
    this.documentFilename,
    this.workStorage,
  });

  @override
  State<TodoEditorPage> createState() => _TodoEditorPageState();
}

class _TodoEditorPageState extends State<TodoEditorPage> {
  final I18nService _i18n = I18nService();
  final NdfService _ndfService = NdfService();
  final FocusNode _focusNode = FocusNode();

  NdfDocument? _metadata;
  TodoContent? _content;
  List<TodoItem> _items = [];
  bool _isLoading = true;
  bool _hasChanges = false;
  bool _isSaving = false;
  String? _error;
  Set<String> _expandedItems = {};

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadDocument() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final metadata = await _ndfService.readMetadata(widget.filePath);
      if (metadata == null) {
        throw Exception('Could not read document metadata');
      }

      final content = await _ndfService.readTodoContent(widget.filePath);
      if (content == null) {
        throw Exception('Could not read TODO content');
      }

      final items = await _ndfService.readTodoItems(widget.filePath, content.items);

      // Initialize expanded items based on settings
      Set<String> expandedItems = {};
      if (content.settings.defaultExpanded) {
        expandedItems = items.map((i) => i.id).toSet();
      }

      setState(() {
        _metadata = metadata;
        _content = content;
        _items = items;
        _expandedItems = expandedItems;
        _isLoading = false;
      });
    } catch (e) {
      LogService().log('TodoEditorPage: Error loading document: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_content == null || _metadata == null) return;
    if (_isSaving) return;

    _isSaving = true;
    setState(() { _hasChanges = false; });  // Optimistic: clear immediately

    try {
      _metadata!.touch();
      _content!.touch();
      await _ndfService.saveTodo(widget.filePath, _content!, _items);
      await _ndfService.updateMetadata(widget.filePath, _metadata!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('document_saved'))),
        );
      }
    } catch (e) {
      LogService().log('TodoEditorPage: Error saving document: $e');
      if (mounted) {
        setState(() { _hasChanges = true; });  // Rollback on failure
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e')),
        );
      }
    } finally {
      _isSaving = false;
    }
  }

  void _addItem() async {
    final result = await Navigator.push<TodoItem>(
      context,
      MaterialPageRoute(
        builder: (context) => _TodoItemFormPage(
          i18n: _i18n,
          title: _i18n.t('work_todo_add_item'),
          getPriorityIcon: _getPriorityIcon,
          getPriorityColor: _getPriorityColor,
          getPriorityLabel: _getPriorityLabel,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _items.add(result);
        _content?.addItem(result.id);
        _hasChanges = true;
      });
    }
  }

  void _editItem(TodoItem item) async {
    final result = await Navigator.push<TodoItem>(
      context,
      MaterialPageRoute(
        builder: (context) => _TodoItemFormPage(
          i18n: _i18n,
          title: _i18n.t('work_todo_edit_item'),
          initialTitle: item.title,
          initialDescription: item.description,
          initialPriority: item.priority,
          getPriorityIcon: _getPriorityIcon,
          getPriorityColor: _getPriorityColor,
          getPriorityLabel: _getPriorityLabel,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        item.title = result.title;
        item.description = result.description;
        item.priority = result.priority;
        _hasChanges = true;
      });
    }
  }

  void _deleteItem(TodoItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_todo_delete_item')),
        content: Text(_i18n.t('work_todo_delete_item_confirm').replaceAll('{name}', item.title)),
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
      setState(() {
        _items.removeWhere((i) => i.id == item.id);
        _content?.removeItem(item.id);
        _expandedItems.remove(item.id);
        _hasChanges = true;
      });

      // Delete item file from archive
      try {
        await _ndfService.deleteTodoItem(widget.filePath, item.id);
      } catch (e) {
        LogService().log('TodoEditorPage: Error deleting item file: $e');
      }
    }
  }

  void _toggleItemCompleted(TodoItem item) {
    setState(() {
      item.toggleCompleted();
      _hasChanges = true;
    });
  }

  void _toggleItemExpanded(String itemId) {
    setState(() {
      if (_expandedItems.contains(itemId)) {
        _expandedItems.remove(itemId);
      } else {
        _expandedItems.add(itemId);
      }
    });
  }

  void _addPicture(TodoItem item) async {
    final isMobile = Platform.isAndroid || Platform.isIOS;

    if (isMobile) {
      _showPictureSourceSheet(item);
    } else {
      _pickFromGallery(item);
    }
  }

  void _showPictureSourceSheet(TodoItem item) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text(_i18n.t('work_todo_take_photo')),
              onTap: () {
                Navigator.pop(context);
                _takePhoto(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(_i18n.t('work_todo_from_gallery')),
              onTap: () {
                Navigator.pop(context);
                _pickFromGallery(item);
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<void> _takePhoto(TodoItem item) async {
    try {
      final picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.camera);
      if (image != null) {
        await _saveImageToItem(item, File(image.path));
      }
    } catch (e) {
      LogService().log('TodoEditorPage: Error taking photo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error taking photo: $e')),
        );
      }
    }
  }

  Future<void> _pickFromGallery(TodoItem item) async {
    try {
      final picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);
      if (image != null) {
        await _saveImageToItem(item, File(image.path));
      }
    } catch (e) {
      LogService().log('TodoEditorPage: Error picking image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking image: $e')),
        );
      }
    }
  }

  Future<void> _saveImageToItem(TodoItem item, File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final ext = imageFile.path.split('.').last.toLowerCase();
      final assetPath = 'images/${item.id}-${DateTime.now().millisecondsSinceEpoch}.$ext';

      await _ndfService.saveAsset(widget.filePath, assetPath, bytes);

      setState(() {
        item.addPicture(assetPath);
        _hasChanges = true;
      });
    } catch (e) {
      LogService().log('TodoEditorPage: Error saving image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving image: $e')),
        );
      }
    }
  }

  void _removePicture(TodoItem item, String path) {
    setState(() {
      item.removePicture(path);
      _hasChanges = true;
    });
  }

  void _addLink(TodoItem item) async {
    final titleController = TextEditingController();
    final urlController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_todo_add_link')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: InputDecoration(
                labelText: _i18n.t('work_todo_link_title'),
                border: const OutlineInputBorder(),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: urlController,
              decoration: InputDecoration(
                labelText: _i18n.t('work_todo_link_url'),
                border: const OutlineInputBorder(),
                hintText: 'https://',
              ),
              keyboardType: TextInputType.url,
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
            child: Text(_i18n.t('save')),
          ),
        ],
      ),
    );

    if (result == true &&
        titleController.text.trim().isNotEmpty &&
        urlController.text.trim().isNotEmpty) {
      final link = TodoLink.create(
        title: titleController.text.trim(),
        url: urlController.text.trim(),
      );

      setState(() {
        item.addLink(link);
        _hasChanges = true;
      });
    }
  }

  void _removeLink(TodoItem item, String linkId) {
    setState(() {
      item.removeLink(linkId);
      _hasChanges = true;
    });
  }

  void _openLink(TodoLink link) async {
    try {
      final uri = Uri.parse(link.url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      LogService().log('TodoEditorPage: Error opening link: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening link: $e')),
        );
      }
    }
  }

  void _addUpdate(TodoItem item) async {
    final contentController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_todo_add_update')),
        content: TextField(
          controller: contentController,
          decoration: InputDecoration(
            labelText: _i18n.t('work_todo_update_content'),
            border: const OutlineInputBorder(),
          ),
          maxLines: 3,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('save')),
          ),
        ],
      ),
    );

    if (result == true && contentController.text.trim().isNotEmpty) {
      final update = TodoUpdate.create(content: contentController.text.trim());

      setState(() {
        item.addUpdate(update);
        _hasChanges = true;
      });
    }
  }

  void _removeUpdate(TodoItem item, String updateId) {
    setState(() {
      item.removeUpdate(updateId);
      _hasChanges = true;
    });
  }

  List<TodoItem> _getSortedItems() {
    final items = List<TodoItem>.from(_items);
    final settings = _content?.settings ?? TodoSettings();

    // Filter out completed if needed
    if (!settings.showCompleted) {
      items.removeWhere((i) => i.isCompleted);
    }

    // Sort - always apply priority as secondary sort within each group
    switch (settings.sortOrder) {
      case TodoSortOrder.createdAsc:
        items.sort((a, b) {
          final cmp = a.createdAt.compareTo(b.createdAt);
          if (cmp != 0) return cmp;
          return a.priority.sortWeight.compareTo(b.priority.sortWeight);
        });
        break;
      case TodoSortOrder.createdDesc:
        items.sort((a, b) {
          final cmp = b.createdAt.compareTo(a.createdAt);
          if (cmp != 0) return cmp;
          return a.priority.sortWeight.compareTo(b.priority.sortWeight);
        });
        break;
      case TodoSortOrder.completedFirst:
        items.sort((a, b) {
          if (a.isCompleted != b.isCompleted) {
            return a.isCompleted ? -1 : 1;
          }
          final priorityCmp = a.priority.sortWeight.compareTo(b.priority.sortWeight);
          if (priorityCmp != 0) return priorityCmp;
          return b.createdAt.compareTo(a.createdAt);
        });
        break;
      case TodoSortOrder.pendingFirst:
        items.sort((a, b) {
          if (a.isCompleted != b.isCompleted) {
            return a.isCompleted ? 1 : -1;
          }
          final priorityCmp = a.priority.sortWeight.compareTo(b.priority.sortWeight);
          if (priorityCmp != 0) return priorityCmp;
          return b.createdAt.compareTo(a.createdAt);
        });
        break;
      case TodoSortOrder.priorityHighFirst:
        items.sort((a, b) {
          final priorityCmp = a.priority.sortWeight.compareTo(b.priority.sortWeight);
          if (priorityCmp != 0) return priorityCmp;
          return b.createdAt.compareTo(a.createdAt);
        });
        break;
    }

    return items;
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

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      final isCtrlPressed = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;

      if (isCtrlPressed && event.logicalKey == LogicalKeyboardKey.keyS) {
        _save();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: PopScope(
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
              onTap: _renameDocument,
              child: Text(_content?.title ?? widget.title ?? _i18n.t('work_todo')),
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
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: _handleMenuAction,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        const Icon(Icons.edit_outlined),
                        const SizedBox(width: 8),
                        Text(_i18n.t('work_todo_rename')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'settings',
                    child: Row(
                      children: [
                        const Icon(Icons.settings_outlined),
                        const SizedBox(width: 8),
                        Text(_i18n.t('settings')),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: _buildBody(),
          floatingActionButton: FloatingActionButton(
            onPressed: _addItem,
            child: const Icon(Icons.add),
          ),
        ),
      ),
    );
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

  void _handleMenuAction(String action) {
    switch (action) {
      case 'rename':
        _renameDocument();
        break;
      case 'settings':
        _showSettings();
        break;
    }
  }

  void _renameDocument() async {
    if (_content == null) return;

    final controller = TextEditingController(text: _content!.title);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_todo_rename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _i18n.t('work_todo_title'),
            border: const OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
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

    if (result != null && result.isNotEmpty && result != _content!.title) {
      setState(() {
        _content!.title = result;
        if (_metadata != null) {
          _metadata!.title = result;
        }
        _hasChanges = true;
      });
    }
  }

  void _showSettings() async {
    if (_content == null) return;

    final settings = _content!.settings;
    var showCompleted = settings.showCompleted;
    var sortOrder = settings.sortOrder;
    var defaultExpanded = settings.defaultExpanded;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(_i18n.t('work_todo_settings')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_i18n.t('work_todo_show_completed')),
                  value: showCompleted,
                  onChanged: (val) => setDialogState(() => showCompleted = val),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_i18n.t('work_todo_default_expanded')),
                  value: defaultExpanded,
                  onChanged: (val) => setDialogState(() => defaultExpanded = val),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<TodoSortOrder>(
                  initialValue: sortOrder,
                  decoration: InputDecoration(
                    labelText: _i18n.t('work_todo_sort_order'),
                    border: const OutlineInputBorder(),
                  ),
                  items: TodoSortOrder.values.map((order) {
                    return DropdownMenuItem(
                      value: order,
                      child: Text(_getSortOrderLabel(order)),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => sortOrder = val);
                    }
                  },
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
                child: Text(_i18n.t('save')),
              ),
            ],
          );
        },
      ),
    );

    if (result == true) {
      setState(() {
        _content!.settings = TodoSettings(
          showCompleted: showCompleted,
          sortOrder: sortOrder,
          defaultExpanded: defaultExpanded,
        );
        _hasChanges = true;
      });
    }
  }

  String _getSortOrderLabel(TodoSortOrder order) {
    switch (order) {
      case TodoSortOrder.createdAsc:
        return _i18n.t('work_todo_sort_created_asc');
      case TodoSortOrder.createdDesc:
        return _i18n.t('work_todo_sort_created_desc');
      case TodoSortOrder.completedFirst:
        return _i18n.t('work_todo_sort_completed_first');
      case TodoSortOrder.pendingFirst:
        return _i18n.t('work_todo_sort_pending_first');
      case TodoSortOrder.priorityHighFirst:
        return _i18n.t('work_todo_sort_priority');
    }
  }

  String _getPriorityLabel(TodoPriority priority) {
    switch (priority) {
      case TodoPriority.high:
        return _i18n.t('work_todo_priority_high');
      case TodoPriority.normal:
        return _i18n.t('work_todo_priority_normal');
      case TodoPriority.low:
        return _i18n.t('work_todo_priority_low');
    }
  }

  IconData _getPriorityIcon(TodoPriority priority) {
    switch (priority) {
      case TodoPriority.high:
        return Icons.keyboard_double_arrow_up;
      case TodoPriority.normal:
        return Icons.remove;
      case TodoPriority.low:
        return Icons.keyboard_double_arrow_down;
    }
  }

  Color _getPriorityColor(TodoPriority priority) {
    switch (priority) {
      case TodoPriority.high:
        return Colors.red;
      case TodoPriority.normal:
        return Colors.grey;
      case TodoPriority.low:
        return Colors.blue;
    }
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      final theme = Theme.of(context);
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

    final sortedItems = _getSortedItems();

    if (sortedItems.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.checklist_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(_i18n.t('work_todo_no_items')),
            const SizedBox(height: 8),
            Text(
              _i18n.t('work_todo_add_first'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sortedItems.length,
      itemBuilder: (context, index) {
        final item = sortedItems[index];
        return TodoItemCardWidget(
          key: ValueKey(item.id),
          item: item,
          isExpanded: _expandedItems.contains(item.id),
          ndfFilePath: widget.filePath,
          onToggleCompleted: () => _toggleItemCompleted(item),
          onToggleExpanded: () => _toggleItemExpanded(item.id),
          onEdit: () => _editItem(item),
          onDelete: () => _deleteItem(item),
          onAddPicture: () => _addPicture(item),
          onRemovePicture: (path) => _removePicture(item, path),
          onAddLink: () => _addLink(item),
          onRemoveLink: (linkId) => _removeLink(item, linkId),
          onOpenLink: _openLink,
          onAddUpdate: () => _addUpdate(item),
          onRemoveUpdate: (updateId) => _removeUpdate(item, updateId),
        );
      },
    );
  }
}

/// Full-screen form page for adding/editing a TODO item
class _TodoItemFormPage extends StatefulWidget {
  final I18nService i18n;
  final String title;
  final String? initialTitle;
  final String? initialDescription;
  final TodoPriority? initialPriority;
  final IconData Function(TodoPriority) getPriorityIcon;
  final Color Function(TodoPriority) getPriorityColor;
  final String Function(TodoPriority) getPriorityLabel;

  const _TodoItemFormPage({
    required this.i18n,
    required this.title,
    this.initialTitle,
    this.initialDescription,
    this.initialPriority,
    required this.getPriorityIcon,
    required this.getPriorityColor,
    required this.getPriorityLabel,
  });

  @override
  State<_TodoItemFormPage> createState() => _TodoItemFormPageState();
}

class _TodoItemFormPageState extends State<_TodoItemFormPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _descController;
  late TodoPriority _priority;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle ?? '');
    _descController = TextEditingController(text: widget.initialDescription ?? '');
    _priority = widget.initialPriority ?? TodoPriority.normal;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    super.dispose();
  }

  void _save() {
    if (_titleController.text.trim().isEmpty) return;

    final item = TodoItem.create(
      title: _titleController.text.trim(),
      description: _descController.text.trim().isNotEmpty
          ? _descController.text.trim()
          : null,
      priority: _priority,
    );

    Navigator.pop(context, item);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          FilledButton(
            onPressed: _save,
            child: Text(widget.i18n.t('save')),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _titleController,
              decoration: InputDecoration(
                labelText: widget.i18n.t('work_todo_item_title'),
                border: const OutlineInputBorder(),
                suffixIcon: TranscribeButtonWidget(
                  i18n: widget.i18n,
                  onTranscribed: (text) {
                    if (_titleController.text.isEmpty) {
                      _titleController.text = text;
                    } else {
                      _titleController.text += ' $text';
                    }
                  },
                ),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descController,
              decoration: InputDecoration(
                labelText: widget.i18n.t('work_todo_item_description'),
                border: const OutlineInputBorder(),
                suffixIcon: TranscribeButtonWidget(
                  i18n: widget.i18n,
                  onTranscribed: (text) {
                    if (_descController.text.isEmpty) {
                      _descController.text = text;
                    } else {
                      _descController.text += ' $text';
                    }
                  },
                ),
              ),
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<TodoPriority>(
              value: _priority,
              decoration: InputDecoration(
                labelText: widget.i18n.t('work_todo_priority'),
                border: const OutlineInputBorder(),
              ),
              items: TodoPriority.values.map((p) {
                return DropdownMenuItem(
                  value: p,
                  child: Row(
                    children: [
                      Icon(
                        widget.getPriorityIcon(p),
                        size: 18,
                        color: widget.getPriorityColor(p),
                      ),
                      const SizedBox(width: 8),
                      Text(widget.getPriorityLabel(p)),
                    ],
                  ),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) {
                  setState(() => _priority = val);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
