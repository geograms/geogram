/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dialogs/place_picker_dialog.dart';
import '../platform/file_image_helper.dart' as file_helper;
import '../inventory/models/currencies.dart';
import '../inventory/models/inventory_item.dart';
import '../inventory/models/inventory_batch.dart';
import '../inventory/models/inventory_borrow.dart';
import '../inventory/models/inventory_usage.dart';
import '../inventory/models/item_type_catalog.dart';
import '../inventory/models/measurement_units.dart';
import '../inventory/services/inventory_service.dart';
import '../inventory/utils/inventory_folder_utils.dart';
import '../services/i18n_service.dart';
import '../widgets/inventory/type_selector_widget.dart';

/// Page for viewing/editing an inventory item
class InventoryItemPage extends StatefulWidget {
  final String collectionPath;
  final List<String> folderPath;
  final InventoryItem? item;
  final InventoryItem? templateItem;
  final I18nService i18n;

  const InventoryItemPage({
    super.key,
    required this.collectionPath,
    required this.folderPath,
    this.item,
    this.templateItem,
    required this.i18n,
  });

  @override
  State<InventoryItemPage> createState() => _InventoryItemPageState();
}

class _InventoryItemPageState extends State<InventoryItemPage> {
  final InventoryService _service = InventoryService();
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _titleController;
  late TextEditingController _quantityController;
  late TextEditingController _locationNameController;
  late TextEditingController _notesController;

  String _selectedType = 'other';
  String _selectedUnit = 'units';
  String _location = '';
  String? _placePath;
  List<InventoryBatch> _batches = [];
  List<String> _media = [];
  List<String> _pendingMedia = []; // New media files to be added
  List<String> _removedMedia = []; // Existing media files to be removed
  List<InventoryBorrow> _borrows = []; // Active borrows for this item
  List<InventoryUsage> _usageHistory = []; // Usage history log
  Map<String, dynamic> _specs = {};
  Map<String, dynamic> _customFields = {};

  bool _isExistingItem = false;  // True if editing an existing item
  bool _inEditMode = false;      // True if currently in edit mode (vs view mode)
  bool _saving = false;
  bool _hasChanges = false;

  late String _langCode;

  @override
  void initState() {
    super.initState();
    _langCode = widget.i18n.currentLanguage.split('_').first.toUpperCase();
    _isExistingItem = widget.item != null;
    // For new items, start in edit mode; for existing items, start in view mode
    _inEditMode = widget.item == null;

    _titleController = TextEditingController(text: widget.item?.title ?? '');
    _quantityController = TextEditingController(
      text: widget.item?.quantity.toString() ?? '1',
    );
    _locationNameController = TextEditingController(
      text: widget.item?.locationName ?? '',
    );
    _notesController = TextEditingController();

    if (widget.item != null) {
      _selectedType = widget.item!.type;
      _selectedUnit = widget.item!.unit;
      _location = widget.item!.location;
      _placePath = widget.item!.placePath;
      _batches = List.from(widget.item!.batches);
      _media = List.from(widget.item!.media);
      _specs = Map.from(widget.item!.specs);
      _customFields = Map.from(widget.item!.customFields);
      _loadBorrows();
      _loadUsageHistory();
    } else if (widget.templateItem != null) {
      // Pre-populate from template (but not batches/media as those are item-specific)
      _selectedType = widget.templateItem!.type;
      _selectedUnit = widget.templateItem!.unit;
      _specs = Map.from(widget.templateItem!.specs);
      _customFields = Map.from(widget.templateItem!.customFields);
    }

    _titleController.addListener(_onChanged);
    _quantityController.addListener(_onChanged);
    _locationNameController.addListener(_onChanged);
  }

  Future<void> _loadBorrows() async {
    if (widget.item == null) return;
    final borrows = await _service.getBorrowHistory(
      widget.folderPath,
      itemId: widget.item!.id,
    );
    if (mounted) {
      setState(() {
        _borrows = borrows.where((b) => b.isActive).toList();
      });
    }
  }

  Future<void> _loadUsageHistory() async {
    if (widget.item == null) return;
    final usage = await _service.getUsageHistory(
      widget.folderPath,
      itemId: widget.item!.id,
    );
    if (mounted) {
      setState(() {
        // Sort by date descending (most recent first)
        _usageHistory = usage..sort((a, b) => b.date.compareTo(a.date));
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _quantityController.dispose();
    _locationNameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!_hasChanges) {
      setState(() => _hasChanges = true);
    }
  }

  double _calculateBatchTotal() {
    return _batches.fold(0.0, (sum, batch) => sum + batch.quantity);
  }

  /// Calculate total value of all batches (grouped by currency)
  Map<String, double> _calculateTotalValue() {
    final totals = <String, double>{};
    for (final batch in _batches) {
      if (batch.cost != null && batch.currency != null) {
        totals[batch.currency!] = (totals[batch.currency!] ?? 0) + batch.cost!;
      }
    }
    return totals;
  }

  /// Get the most common currency from batches
  String? _getDefaultCurrency() {
    final currencies = _batches
        .where((b) => b.currency != null)
        .map((b) => b.currency!)
        .toList();
    if (currencies.isEmpty) return null;

    // Count occurrences and return most common
    final counts = <String, int>{};
    for (final c in currencies) {
      counts[c] = (counts[c] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  Future<void> _showDiscardChangesDialog() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('discard_changes')),
        content: Text(widget.i18n.t('discard_changes_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.i18n.t('discard')),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      // Reset to original values
      if (widget.item != null) {
        _titleController.text = widget.item!.title;
        _selectedType = widget.item!.type;
        _selectedUnit = widget.item!.unit;
        _location = widget.item!.location;
        _placePath = widget.item!.placePath;
        _locationNameController.text = widget.item!.locationName ?? '';
        _batches = List.from(widget.item!.batches);
        _media = List.from(widget.item!.media);
        _pendingMedia.clear();
        _removedMedia.clear();
        _specs = Map.from(widget.item!.specs);
        _customFields = Map.from(widget.item!.customFields);
      }
      setState(() {
        _hasChanges = false;
        _inEditMode = false;
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    try {
      final quantity = double.tryParse(_quantityController.text) ?? 0;

      // If no batches exist but quantity is set, create an initial batch
      List<InventoryBatch> batchesToSave = List.from(_batches);
      if (batchesToSave.isEmpty && quantity > 0) {
        batchesToSave.add(InventoryBatch(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          quantity: quantity,
          datePurchased: DateTime.now(),
        ));
      }

      // Handle media changes
      // First, remove media marked for deletion
      for (final filename in _removedMedia) {
        await _service.removeMedia(widget.folderPath, filename);
      }

      // Copy pending media files to storage
      final newMediaFilenames = <String>[];
      for (final sourcePath in _pendingMedia) {
        final file = File(sourcePath);
        final originalName = file.path.split('/').last;
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final filename = '${timestamp}_$originalName';
        final savedFilename = await _service.addMedia(
          widget.folderPath,
          sourcePath,
          filename,
        );
        if (savedFilename != null) {
          newMediaFilenames.add(savedFilename);
        }
      }

      // Build final media list: existing (minus removed) + new
      final finalMedia = [
        ..._media.where((m) => !_removedMedia.contains(m)),
        ...newMediaFilenames,
      ];

      bool success = false;
      if (_isExistingItem) {
        final updatedItem = widget.item!.copyWith(
          title: _titleController.text,
          type: _selectedType,
          unit: _selectedUnit,
          batches: batchesToSave,
          media: finalMedia,
          specs: _specs,
          customFields: _customFields,
          location: _location,
          locationName: _locationNameController.text.isNotEmpty
              ? _locationNameController.text
              : null,
          metadata: _placePath != null ? {'place_path': _placePath} : {},
        );
        success = await _service.updateItem(widget.folderPath, updatedItem);
      } else {
        final newItem = await _service.createItem(
          folderPath: widget.folderPath,
          title: _titleController.text,
          type: _selectedType,
          unit: _selectedUnit,
          batches: batchesToSave,
          media: finalMedia,
          specs: _specs,
          customFields: _customFields,
          location: _location,
          locationName: _locationNameController.text.isNotEmpty
              ? _locationNameController.text
              : null,
          placePath: _placePath,
        );
        success = newItem != null;
      }

      if (mounted) {
        if (success) {
          if (_isExistingItem) {
            // For existing items, switch back to view mode
            setState(() {
              _hasChanges = false;
              _inEditMode = false;
            });
          } else {
            // For new items, pop and return
            Navigator.pop(context, true);
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(widget.i18n.t('inventory_error_saving'))),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('inventory_error_saving'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _saveAsTemplate() async {
    if (widget.item == null) return;

    final controller = TextEditingController(text: _titleController.text);
    final templateName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('inventory_save_as_template')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: widget.i18n.t('inventory_template_name'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(widget.i18n.t('save')),
          ),
        ],
      ),
    );

    if (templateName == null || templateName.isEmpty) return;

    // Copy item to templates folder
    final templateItem = await _service.copyItemAsTemplate(
      widget.folderPath,
      widget.item!.id,
      templateName,
    );

    if (mounted) {
      if (templateItem != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('inventory_template_created'))),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('error'))),
        );
      }
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('inventory_delete_item')),
        content: Text(widget.i18n.t('inventory_delete_item_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(widget.i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirm == true && widget.item != null) {
      await _service.deleteItem(widget.folderPath, widget.item!.id);
      if (mounted) {
        Navigator.pop(context, true);
      }
    }
  }

  Future<void> _selectType() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.5,
        expand: false,
        builder: (context, scrollController) => TypeSelectorWidget(
          i18n: widget.i18n,
          selectedType: _selectedType,
          scrollController: scrollController,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _selectedType = result;
        _hasChanges = true;
        // Update unit to default for this type
        final type = ItemTypeCatalog.getById(result);
        if (type != null) {
          _selectedUnit = type.defaultUnit;
        }
      });
    }
  }

  Future<void> _selectUnit() async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _UnitSelectorDialog(
        i18n: widget.i18n,
        selectedUnit: _selectedUnit,
      ),
    );

    if (result != null) {
      setState(() {
        _selectedUnit = result;
        _hasChanges = true;
      });
    }
  }

  Future<void> _selectLocation() async {
    final result = await showDialog<dynamic>(
      context: context,
      builder: (context) => _LocationPickerDialog(
        i18n: widget.i18n,
        currentLocation: _location,
        currentLocationName: _locationNameController.text,
        currentPlacePath: _placePath,
      ),
    );

    if (result != null) {
      setState(() {
        if (result is PlaceSelection) {
          _location = result.place.coordinatesString;
          _locationNameController.text = result.place.getName(_langCode);
          _placePath = result.place.folderPath;
        } else if (result is Map) {
          _location = result['location'] ?? '';
          _locationNameController.text = result['name'] ?? '';
          _placePath = null;
        }
        _hasChanges = true;
      });
    }
  }

  void _clearLocation() {
    setState(() {
      _location = '';
      _locationNameController.clear();
      _placePath = null;
      _hasChanges = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // For existing items in view mode, show the view UI
    if (_isExistingItem && !_inEditMode) {
      return _buildViewMode(context, theme);
    }

    // Edit mode or new item
    return _buildEditMode(context, theme);
  }

  Widget _buildViewMode(BuildContext context, ThemeData theme) {
    final type = ItemTypeCatalog.getById(_selectedType);
    final typeName = type?.getName(_langCode) ?? _selectedType;
    final unit = MeasurementUnits.getById(_selectedUnit);
    final unitName = unit?.getName(_langCode) ?? _selectedUnit;
    final totalValues = _calculateTotalValue();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.i18n.t('inventory_view_item')),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: widget.i18n.t('inventory_edit_details'),
            onPressed: () => setState(() => _inEditMode = true),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'template':
                  _saveAsTemplate();
                  break;
                case 'delete':
                  _delete();
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'template',
                child: ListTile(
                  leading: const Icon(Icons.content_copy),
                  title: Text(widget.i18n.t('inventory_save_as_template')),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error),
                  title: Text(
                    widget.i18n.t('delete'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header with title and main image
          if (_media.isNotEmpty) ...[
            _buildPrimaryImage(theme),
            const SizedBox(height: 16),
          ],

          // Title
          Text(
            _titleController.text,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),

          // Type badge
          Wrap(
            spacing: 8,
            children: [
              Chip(
                avatar: Icon(_getCategoryIconForType(_selectedType), size: 18),
                label: Text(typeName),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Quantity and value card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.i18n.t('inventory_quantity'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_calculateBatchTotal().toStringAsFixed(_calculateBatchTotal().truncateToDouble() == _calculateBatchTotal() ? 0 : 1)} $unitName',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (totalValues.isNotEmpty)
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                widget.i18n.t('inventory_total_value'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 4),
                              ...totalValues.entries.map((e) => Text(
                                Currencies.format(e.value, e.key),
                                style: theme.textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              )),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Quick actions
          _buildUsageSection(theme),
          const SizedBox(height: 24),

          // Location
          if (_location.isNotEmpty || _placePath != null) ...[
            _buildViewLocationSection(theme),
            const SizedBox(height: 24),
          ],

          // Batches section
          if (_batches.isNotEmpty) ...[
            _buildBatchesSection(theme),
            const SizedBox(height: 24),
          ],

          // Borrow section
          _buildBorrowSection(theme),
          const SizedBox(height: 24),

          // Usage history
          _buildUsageHistorySection(theme),
          const SizedBox(height: 24),

          // Media gallery (if more than one photo)
          if (_media.length > 1) ...[
            _buildMediaGallerySection(theme),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }

  Widget _buildPrimaryImage(ThemeData theme) {
    if (_media.isEmpty) return const SizedBox.shrink();

    final primaryMedia = _media.first;
    final fullPath = _service.getMediaPath(widget.folderPath, primaryMedia) ?? '';

    final imageWidget = file_helper.buildFileImage(
      fullPath,
      width: double.infinity,
      height: 200,
      fit: BoxFit.cover,
    );

    if (imageWidget == null) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: imageWidget,
    );
  }

  Widget _buildViewLocationSection(ThemeData theme) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.location_on),
        title: Text(_locationNameController.text.isNotEmpty
            ? _locationNameController.text
            : _location),
        subtitle: _placePath != null
            ? Text(widget.i18n.t('inventory_from_places'))
            : (_location.isNotEmpty && _locationNameController.text.isNotEmpty
                ? Text(_location)
                : null),
      ),
    );
  }

  Widget _buildMediaGallerySection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.i18n.t('inventory_media'),
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 100,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _media.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final mediaPath = _media[index];
              final fullPath = _service.getMediaPath(widget.folderPath, mediaPath) ?? '';
              final imageWidget = file_helper.buildFileImage(
                fullPath,
                width: 100,
                height: 100,
                fit: BoxFit.cover,
              );
              if (imageWidget == null) return const SizedBox.shrink();
              return ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: imageWidget,
              );
            },
          ),
        ),
      ],
    );
  }

  IconData _getCategoryIconForType(String typeId) {
    final type = ItemTypeCatalog.getById(typeId);
    if (type == null) return Icons.inventory_2;
    switch (type.category) {
      case ItemCategory.food:
        return Icons.restaurant;
      case ItemCategory.beverages:
        return Icons.local_drink;
      case ItemCategory.household:
        return Icons.home;
      case ItemCategory.electronics:
        return Icons.devices;
      case ItemCategory.tools:
        return Icons.build;
      case ItemCategory.outdoor:
      case ItemCategory.camping:
        return Icons.terrain;
      case ItemCategory.automotive:
        return Icons.directions_car;
      case ItemCategory.kitchen:
        return Icons.kitchen;
      case ItemCategory.furniture:
        return Icons.chair;
      case ItemCategory.storage:
        return Icons.storage;
      default:
        return Icons.inventory_2;
    }
  }

  Widget _buildEditMode(BuildContext context, ThemeData theme) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isExistingItem
            ? widget.i18n.t('inventory_edit_item')
            : widget.i18n.t('inventory_new_item')),
        leading: _isExistingItem
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  if (_hasChanges) {
                    _showDiscardChangesDialog();
                  } else {
                    setState(() => _inEditMode = false);
                  }
                },
              )
            : null,
        actions: [
          if (_isExistingItem && !_inEditMode)
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'template':
                    _saveAsTemplate();
                    break;
                  case 'delete':
                    _delete();
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'template',
                  child: ListTile(
                    leading: const Icon(Icons.content_copy),
                    title: Text(widget.i18n.t('inventory_save_as_template')),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline,
                        color: Theme.of(context).colorScheme.error),
                    title: Text(
                      widget.i18n.t('delete'),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(
              onPressed: _save,
              child: Text(widget.i18n.t('save')),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Title
            TextFormField(
              controller: _titleController,
              decoration: InputDecoration(
                labelText: widget.i18n.t('inventory_item_title'),
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return widget.i18n.t('inventory_title_required');
                }
                return null;
              },
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),

            // Type selector
            _buildTypeSelector(theme),
            const SizedBox(height: 16),

            // Quantity and Unit
            // When batches exist, show read-only sum; otherwise editable
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _batches.isNotEmpty
                      ? InputDecorator(
                          decoration: InputDecoration(
                            labelText: widget.i18n.t('inventory_quantity'),
                            border: const OutlineInputBorder(),
                            filled: true,
                            fillColor: theme.colorScheme.surfaceContainerHighest,
                          ),
                          child: Text(
                            _calculateBatchTotal().toStringAsFixed(
                              _calculateBatchTotal().truncateToDouble() == _calculateBatchTotal() ? 0 : 1,
                            ),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : TextFormField(
                          controller: _quantityController,
                          decoration: InputDecoration(
                            labelText: widget.i18n.t('inventory_quantity'),
                            border: const OutlineInputBorder(),
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
                          ],
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return widget.i18n.t('inventory_quantity_required');
                            }
                            if (double.tryParse(value) == null) {
                              return widget.i18n.t('inventory_invalid_number');
                            }
                            return null;
                          },
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: _buildUnitSelector(theme),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Media section
            _buildMediaSection(theme),
            const SizedBox(height: 24),

            // Location section
            _buildLocationSection(theme),
            const SizedBox(height: 24),

            // Batches section (if has batches)
            if (_batches.isNotEmpty || _isExistingItem) ...[
              _buildBatchesSection(theme),
              const SizedBox(height: 24),
            ],

            // Usage actions (only for existing items)
            if (_isExistingItem) ...[
              _buildUsageSection(theme),
              const SizedBox(height: 24),
            ],

            // Borrow section (only for existing items)
            if (_isExistingItem) ...[
              _buildBorrowSection(theme),
              const SizedBox(height: 24),
            ],

            // Usage history section (only for existing items)
            if (_isExistingItem) ...[
              _buildUsageHistorySection(theme),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTypeSelector(ThemeData theme) {
    final type = ItemTypeCatalog.getById(_selectedType);
    final typeName = type?.getName(_langCode) ?? _selectedType;
    final isReadOnly = _isExistingItem;

    return InkWell(
      onTap: isReadOnly ? null : _selectType,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: widget.i18n.t('inventory_type'),
          border: const OutlineInputBorder(),
          filled: isReadOnly,
          fillColor: isReadOnly ? theme.colorScheme.surfaceContainerHighest : null,
          suffixIcon: isReadOnly ? null : const Icon(Icons.arrow_drop_down),
        ),
        child: Text(
          typeName,
          style: isReadOnly
              ? theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildUnitSelector(ThemeData theme) {
    final unit = MeasurementUnits.getById(_selectedUnit);
    final unitName = unit?.getName(_langCode) ?? _selectedUnit;
    final isReadOnly = _batches.isNotEmpty;

    return InkWell(
      onTap: isReadOnly ? null : _selectUnit,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: widget.i18n.t('inventory_unit'),
          border: const OutlineInputBorder(),
          filled: isReadOnly,
          fillColor: isReadOnly ? theme.colorScheme.surfaceContainerHighest : null,
          suffixIcon: isReadOnly ? null : const Icon(Icons.arrow_drop_down),
        ),
        child: Text(
          unitName,
          style: isReadOnly
              ? theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildMediaSection(ThemeData theme) {
    if (kIsWeb) return const SizedBox.shrink();

    // Combine existing media (minus removed) with pending media
    final existingMedia = _media.where((m) => !_removedMedia.contains(m)).toList();
    final allMedia = [...existingMedia, ..._pendingMedia];
    final hasMedia = allMedia.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.i18n.t('inventory_media'),
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _pickImages,
          icon: const Icon(Icons.add_photo_alternate),
          label: Text(widget.i18n.t('inventory_add_photo')),
        ),
        const SizedBox(height: 8),
        Text(
          widget.i18n.t('inventory_tap_to_set_primary'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        if (hasMedia)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // Existing media
              ...existingMedia.asMap().entries.map((entry) {
                final index = entry.key;
                final mediaPath = entry.value;
                final isPrimary = index == 0 && _pendingMedia.isEmpty;
                return _buildMediaThumbnail(theme, mediaPath, true, isPrimary, index);
              }),
              // Pending media
              ..._pendingMedia.asMap().entries.map((entry) {
                final index = entry.key;
                final mediaPath = entry.value;
                final isPrimary = index == 0 && existingMedia.isEmpty;
                return _buildMediaThumbnail(theme, mediaPath, false, isPrimary, existingMedia.length + index);
              }),
            ],
          ),
      ],
    );
  }

  Widget _buildMediaThumbnail(
    ThemeData theme,
    String mediaPath,
    bool isExisting,
    bool isPrimary,
    int index,
  ) {
    final String fullPath;
    if (isExisting) {
      fullPath = _service.getMediaPath(widget.folderPath, mediaPath) ?? '';
    } else {
      fullPath = mediaPath;
    }

    final imageWidget = file_helper.buildFileImage(
      fullPath,
      width: 100,
      height: 100,
      fit: BoxFit.cover,
    );

    if (imageWidget == null) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => _togglePrimaryImage(mediaPath, isExisting),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              decoration: BoxDecoration(
                border: isPrimary
                    ? Border.all(color: theme.colorScheme.primary, width: 3)
                    : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(isPrimary ? 5 : 8),
                child: imageWidget,
              ),
            ),
          ),
          // Primary badge
          if (isPrimary)
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  widget.i18n.t('inventory_primary'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimary,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          // Delete button
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: () => _removeMedia(mediaPath, isExisting),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Pick images from file system
  Future<void> _pickImages() async {
    if (kIsWeb) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _pendingMedia.addAll(
            result.files.where((f) => f.path != null).map((file) => file.path!).toList(),
          );
          _hasChanges = true;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking images: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _togglePrimaryImage(String mediaPath, bool isExisting) {
    setState(() {
      if (isExisting) {
        // Move to front of existing media
        _media.remove(mediaPath);
        _media.insert(0, mediaPath);
      } else {
        // Move pending media to front of pending list
        _pendingMedia.remove(mediaPath);
        _pendingMedia.insert(0, mediaPath);
      }
      _hasChanges = true;
    });
  }

  void _removeMedia(String mediaPath, bool isExisting) {
    setState(() {
      if (isExisting) {
        _removedMedia.add(mediaPath);
      } else {
        _pendingMedia.remove(mediaPath);
      }
      _hasChanges = true;
    });
  }

  Widget _buildLocationSection(ThemeData theme) {
    final hasLocation = _location.isNotEmpty || _placePath != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.i18n.t('inventory_item_location'),
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        if (hasLocation) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.location_on),
              title: Text(_locationNameController.text.isNotEmpty
                  ? _locationNameController.text
                  : _location),
              subtitle: _placePath != null
                  ? Text(widget.i18n.t('inventory_from_places'))
                  : (_location.isNotEmpty ? Text(_location) : null),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearLocation,
              ),
              onTap: _selectLocation,
            ),
          ),
        ] else ...[
          OutlinedButton.icon(
            onPressed: _selectLocation,
            icon: const Icon(Icons.add_location_outlined),
            label: Text(widget.i18n.t('inventory_set_location')),
          ),
        ],
      ],
    );
  }

  Widget _buildBatchesSection(ThemeData theme) {
    final totalValues = _calculateTotalValue();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              widget.i18n.t('inventory_batches'),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _addBatch,
              icon: const Icon(Icons.add, size: 18),
              label: Text(widget.i18n.t('inventory_add_batch')),
            ),
          ],
        ),
        // Show total value if any batch has cost
        if (totalValues.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Text(
                  widget.i18n.t('inventory_total_value'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: totalValues.entries.map((e) => Text(
                    Currencies.format(e.value, e.key),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  )).toList(),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (_batches.isEmpty)
          Text(
            widget.i18n.t('inventory_no_batches'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          ..._batches.map((batch) => _buildBatchCard(theme, batch)),
      ],
    );
  }

  Widget _buildBatchCard(ThemeData theme, InventoryBatch batch) {
    final isExpired = batch.isExpired;
    final expiresSoon = batch.expiresSoon;
    final hasCost = batch.cost != null && batch.currency != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isExpired
          ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
          : expiresSoon
              ? Colors.orange.withValues(alpha: 0.1)
              : null,
      child: ListTile(
        title: Row(
          children: [
            Text('${batch.quantity} ${_selectedUnit}'),
            if (hasCost) ...[
              const Spacer(),
              Text(
                Currencies.format(batch.cost!, batch.currency!),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
        subtitle: batch.dateExpired != null
            ? Text(
                '${widget.i18n.t('inventory_expires')}: ${_formatDate(batch.dateExpired!)}',
                style: TextStyle(
                  color: isExpired
                      ? theme.colorScheme.error
                      : expiresSoon
                          ? Colors.orange
                          : null,
                ),
              )
            : null,
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _removeBatch(batch),
        ),
      ),
    );
  }

  void _addBatch() async {
    final result = await showDialog<InventoryBatch>(
      context: context,
      builder: (context) => _AddBatchDialog(
        i18n: widget.i18n,
        unit: _selectedUnit,
        defaultCurrency: _getDefaultCurrency(),
      ),
    );

    if (result != null) {
      setState(() {
        _batches.add(result);
        _hasChanges = true;
      });
    }
  }

  void _removeBatch(InventoryBatch batch) {
    setState(() {
      _batches.remove(batch);
      _hasChanges = true;
    });
  }

  Widget _buildUsageSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.i18n.t('inventory_quick_actions'),
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _showConsumeDialog(),
                icon: const Icon(Icons.remove_circle_outline),
                label: Text(widget.i18n.t('inventory_consume')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _showRefillDialog(),
                icon: const Icon(Icons.add_circle_outline),
                label: Text(widget.i18n.t('inventory_refill')),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showConsumeDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('inventory_consume')),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: widget.i18n.t('inventory_quantity'),
            suffixText: _selectedUnit,
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (value) {
            final qty = double.tryParse(value);
            Navigator.pop(context, qty);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              final qty = double.tryParse(controller.text);
              Navigator.pop(context, qty);
            },
            child: Text(widget.i18n.t('confirm')),
          ),
        ],
      ),
    );

    if (result != null && result > 0 && widget.item != null) {
      await _service.consumeItem(
        widget.folderPath,
        widget.item!.id,
        quantity: result,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('inventory_consumed_success'))),
        );
        Navigator.pop(context, true);
      }
    }
  }

  Future<void> _showRefillDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('inventory_refill')),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: widget.i18n.t('inventory_quantity'),
            suffixText: _selectedUnit,
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (value) {
            final qty = double.tryParse(value);
            Navigator.pop(context, qty);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              final qty = double.tryParse(controller.text);
              Navigator.pop(context, qty);
            },
            child: Text(widget.i18n.t('confirm')),
          ),
        ],
      ),
    );

    if (result != null && result > 0 && widget.item != null) {
      await _service.refillItem(
        widget.folderPath,
        widget.item!.id,
        quantity: result,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('inventory_refilled_success'))),
        );
        Navigator.pop(context, true);
      }
    }
  }

  Widget _buildBorrowSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              widget.i18n.t('inventory_active_borrows'),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _showLendDialog,
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: Text(widget.i18n.t('inventory_borrow')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_borrows.isEmpty)
          Text(
            widget.i18n.t('inventory_no_borrows'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          ..._borrows.map((borrow) => _buildBorrowCard(theme, borrow)),
      ],
    );
  }

  Widget _buildBorrowCard(ThemeData theme, InventoryBorrow borrow) {
    final isOverdue = borrow.isOverdue;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isOverdue
          ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
          : null,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            borrow.borrowerType == BorrowerType.callsign
                ? Icons.person
                : Icons.person_outline,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(borrow.borrowerDisplay),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${borrow.quantity} ${_selectedUnit}'),
            if (borrow.expectedReturnAt != null)
              Text(
                '${widget.i18n.t('inventory_due_date')}: ${_formatDate(borrow.expectedReturnAt!)}',
                style: TextStyle(
                  color: isOverdue ? theme.colorScheme.error : null,
                ),
              ),
          ],
        ),
        trailing: FilledButton.tonal(
          onPressed: () => _returnItem(borrow),
          child: Text(widget.i18n.t('inventory_return_item')),
        ),
        isThreeLine: true,
      ),
    );
  }

  Future<void> _showLendDialog() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _LendDialog(
        i18n: widget.i18n,
        unit: _selectedUnit,
        maxQuantity: widget.item?.quantity ?? 0,
      ),
    );

    if (result != null && widget.item != null) {
      final borrow = await _service.lendItem(
        widget.folderPath,
        widget.item!.id,
        quantity: result['quantity'] as double,
        borrowerType: result['borrowerType'] as BorrowerType,
        borrowerCallsign: result['borrowerCallsign'] as String?,
        borrowerText: result['borrowerText'] as String?,
        expectedReturnAt: result['expectedReturn'] as DateTime?,
        notes: result['notes'] as String?,
      );

      if (borrow != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('inventory_borrowed_success'))),
        );
        await _loadBorrows();
        // Also refresh the item to update quantity
        Navigator.pop(context, true);
      }
    }
  }

  Future<void> _returnItem(InventoryBorrow borrow) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('inventory_return_item')),
        content: Text(
          '${widget.i18n.t('inventory_return_confirm')}\n'
          '${borrow.quantity} ${_selectedUnit} ${widget.i18n.t('from')} ${borrow.borrowerDisplay}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.i18n.t('confirm')),
          ),
        ],
      ),
    );

    if (confirm == true && widget.item != null) {
      final success = await _service.returnItem(
        widget.folderPath,
        borrow.id,
      );

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('inventory_returned_success'))),
        );
        Navigator.pop(context, true);
      }
    }
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  String _formatDateTime(DateTime date) {
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.day}/${date.month}/${date.year} $hour:$minute';
  }

  Widget _buildUsageHistorySection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.i18n.t('inventory_activity_log'),
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        if (_usageHistory.isEmpty)
          Text(
            widget.i18n.t('inventory_no_activity'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          ..._usageHistory.map((usage) => _buildUsageCard(theme, usage)),
      ],
    );
  }

  Widget _buildUsageCard(ThemeData theme, InventoryUsage usage) {
    final icon = _getUsageIcon(usage.type);
    final color = _getUsageColor(usage.type);
    final typeLabel = _getUsageTypeLabel(usage.type);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.1),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Row(
          children: [
            Text(typeLabel),
            const SizedBox(width: 8),
            Text(
              '${usage.quantity > 0 ? '+' : ''}${usage.quantity.toStringAsFixed(usage.quantity.truncateToDouble() == usage.quantity ? 0 : 1)} ${usage.unit ?? _selectedUnit}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_formatDateTime(usage.date)),
            if (usage.notes != null && usage.notes!.isNotEmpty)
              Text(
                usage.notes!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          iconSize: 20,
          onSelected: (action) {
            switch (action) {
              case 'edit':
                _editUsage(usage);
                break;
              case 'delete':
                _deleteUsage(usage);
                break;
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  const Icon(Icons.edit_outlined, size: 20),
                  const SizedBox(width: 12),
                  Text(widget.i18n.t('edit')),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete_outline, size: 20, color: theme.colorScheme.error),
                  const SizedBox(width: 12),
                  Text(widget.i18n.t('delete'), style: TextStyle(color: theme.colorScheme.error)),
                ],
              ),
            ),
          ],
        ),
        isThreeLine: usage.notes != null && usage.notes!.isNotEmpty,
      ),
    );
  }

  IconData _getUsageIcon(UsageType type) {
    switch (type) {
      case UsageType.consume:
        return Icons.remove_circle_outline;
      case UsageType.refill:
        return Icons.add_circle_outline;
      case UsageType.adjustment:
        return Icons.tune;
    }
  }

  Color _getUsageColor(UsageType type) {
    switch (type) {
      case UsageType.consume:
        return Colors.red;
      case UsageType.refill:
        return Colors.green;
      case UsageType.adjustment:
        return Colors.blue;
    }
  }

  String _getUsageTypeLabel(UsageType type) {
    switch (type) {
      case UsageType.consume:
        return widget.i18n.t('inventory_consumed');
      case UsageType.refill:
        return widget.i18n.t('inventory_refilled');
      case UsageType.adjustment:
        return widget.i18n.t('inventory_adjusted');
    }
  }

  Future<void> _editUsage(InventoryUsage usage) async {
    final result = await showDialog<InventoryUsage>(
      context: context,
      builder: (context) => _EditUsageDialog(
        i18n: widget.i18n,
        usage: usage,
        unit: _selectedUnit,
      ),
    );

    if (result != null) {
      final success = await _service.updateUsage(widget.folderPath, result);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('inventory_activity_updated'))),
        );
        await _loadUsageHistory();
      }
    }
  }

  Future<void> _deleteUsage(InventoryUsage usage) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('inventory_delete_activity')),
        content: Text(widget.i18n.t('inventory_delete_activity_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(widget.i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final success = await _service.deleteUsage(widget.folderPath, usage.id);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('inventory_activity_deleted'))),
        );
        await _loadUsageHistory();
      }
    }
  }
}

// Unit selector dialog
class _UnitSelectorDialog extends StatefulWidget {
  final I18nService i18n;
  final String selectedUnit;

  const _UnitSelectorDialog({
    required this.i18n,
    required this.selectedUnit,
  });

  @override
  State<_UnitSelectorDialog> createState() => _UnitSelectorDialogState();
}

class _UnitSelectorDialogState extends State<_UnitSelectorDialog> {
  UnitCategory? _selectedCategory;
  late String _langCode;

  @override
  void initState() {
    super.initState();
    _langCode = widget.i18n.currentLanguage.split('_').first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.i18n.t('inventory_select_unit')),
      content: SizedBox(
        width: 400,
        height: 400,
        child: Column(
          children: [
            // Category tabs
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildCategoryChip(null, widget.i18n.t('all')),
                  ...UnitCategory.values.map(
                    (cat) => _buildCategoryChip(
                      cat,
                      _getCategoryName(cat),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Units list
            Expanded(
              child: ListView(
                children: _getFilteredUnits().map((unit) {
                  final isSelected = unit.id == widget.selectedUnit;
                  return ListTile(
                    title: Text(unit.getName(_langCode)),
                    subtitle: Text(unit.symbol),
                    trailing: isSelected
                        ? Icon(Icons.check, color: theme.colorScheme.primary)
                        : null,
                    selected: isSelected,
                    onTap: () => Navigator.pop(context, unit.id),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryChip(UnitCategory? category, String label) {
    final isSelected = _selectedCategory == category;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (_) => setState(() => _selectedCategory = category),
      ),
    );
  }

  List<MeasurementUnit> _getFilteredUnits() {
    if (_selectedCategory == null) {
      return MeasurementUnits.all;
    }
    return MeasurementUnits.byCategory(_selectedCategory!);
  }

  String _getCategoryName(UnitCategory category) {
    switch (category) {
      case UnitCategory.volume:
        return widget.i18n.t('inventory_unit_volume');
      case UnitCategory.weight:
        return widget.i18n.t('inventory_unit_weight');
      case UnitCategory.length:
        return widget.i18n.t('inventory_unit_length');
      case UnitCategory.area:
        return widget.i18n.t('inventory_unit_area');
      case UnitCategory.count:
        return widget.i18n.t('inventory_unit_count');
      case UnitCategory.time:
        return widget.i18n.t('inventory_unit_time');
      case UnitCategory.digital:
        return widget.i18n.t('inventory_unit_digital');
      case UnitCategory.temperature:
        return widget.i18n.t('inventory_unit_temperature');
      case UnitCategory.other:
        return widget.i18n.t('inventory_unit_other');
    }
  }
}

// Location picker dialog
class _LocationPickerDialog extends StatelessWidget {
  final I18nService i18n;
  final String currentLocation;
  final String currentLocationName;
  final String? currentPlacePath;

  const _LocationPickerDialog({
    required this.i18n,
    required this.currentLocation,
    required this.currentLocationName,
    this.currentPlacePath,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(i18n.t('inventory_select_location')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.place),
            title: Text(i18n.t('inventory_from_places')),
            subtitle: Text(i18n.t('inventory_select_from_places_collection')),
            onTap: () async {
              final result = await showDialog<PlaceSelection>(
                context: context,
                builder: (context) => PlacePickerDialog(i18n: i18n),
              );
              if (result != null && context.mounted) {
                Navigator.pop(context, result);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.my_location),
            title: Text(i18n.t('inventory_enter_coordinates')),
            subtitle: Text(i18n.t('inventory_enter_lat_lon')),
            onTap: () async {
              final result = await _showCoordinatesDialog(context);
              if (result != null && context.mounted) {
                Navigator.pop(context, result);
              }
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(i18n.t('cancel')),
        ),
      ],
    );
  }

  Future<Map<String, String>?> _showCoordinatesDialog(BuildContext context) async {
    final latController = TextEditingController();
    final lonController = TextEditingController();
    final nameController = TextEditingController();

    return showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.t('inventory_enter_coordinates')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: i18n.t('inventory_location_name'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: latController,
                    decoration: InputDecoration(
                      labelText: i18n.t('latitude'),
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: lonController,
                    decoration: InputDecoration(
                      labelText: i18n.t('longitude'),
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              final lat = double.tryParse(latController.text);
              final lon = double.tryParse(lonController.text);
              if (lat != null && lon != null) {
                Navigator.pop(context, {
                  'location': '$lat,$lon',
                  'name': nameController.text,
                });
              }
            },
            child: Text(i18n.t('confirm')),
          ),
        ],
      ),
    );
  }
}

// Add batch dialog
class _AddBatchDialog extends StatefulWidget {
  final I18nService i18n;
  final String unit;
  final String? defaultCurrency;

  const _AddBatchDialog({
    required this.i18n,
    required this.unit,
    this.defaultCurrency,
  });

  @override
  State<_AddBatchDialog> createState() => _AddBatchDialogState();
}

class _AddBatchDialogState extends State<_AddBatchDialog> {
  final _quantityController = TextEditingController(text: '1');
  final _costController = TextEditingController();
  DateTime? _expiryDate;
  String _selectedCurrency = 'EUR';
  String? _quantityError;
  String? _costError;

  @override
  void initState() {
    super.initState();
    _selectedCurrency = widget.defaultCurrency ?? 'EUR';
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _costController.dispose();
    super.dispose();
  }

  /// Parse a decimal number accepting either comma or dot as separator.
  /// Returns null if invalid (mixed separators or multiple of same separator).
  double? _parseDecimal(String text) {
    if (text.isEmpty) return null;

    final trimmed = text.trim();
    final dotCount = trimmed.split('.').length - 1;
    final commaCount = trimmed.split(',').length - 1;

    // Reject if both separators are present
    if (dotCount > 0 && commaCount > 0) return null;

    // Reject if more than one separator of same type
    if (dotCount > 1 || commaCount > 1) return null;

    // Normalize: replace comma with dot
    final normalized = trimmed.replaceAll(',', '.');

    return double.tryParse(normalized);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.i18n.t('inventory_add_batch')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _quantityController,
              decoration: InputDecoration(
                labelText: widget.i18n.t('inventory_quantity'),
                suffixText: widget.unit,
                border: const OutlineInputBorder(),
                errorText: _quantityError,
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              autofocus: true,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            // Cost and currency
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _costController,
                    decoration: InputDecoration(
                      labelText: widget.i18n.t('inventory_cost'),
                      hintText: widget.i18n.t('optional'),
                      border: const OutlineInputBorder(),
                      errorText: _costError,
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 1,
                  child: DropdownButtonFormField<String>(
                    value: _selectedCurrency,
                    decoration: InputDecoration(
                      labelText: widget.i18n.t('inventory_currency'),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                    ),
                    isExpanded: true,
                    items: Currencies.all.map((c) => DropdownMenuItem(
                      value: c.code,
                      child: Text(c.code, style: const TextStyle(fontSize: 14)),
                    )).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedCurrency = value);
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event),
              title: Text(_expiryDate != null
                  ? '${_expiryDate!.day}/${_expiryDate!.month}/${_expiryDate!.year}'
                  : widget.i18n.t('inventory_set_expiry_date')),
              trailing: _expiryDate != null
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _expiryDate = null),
                    )
                  : null,
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _expiryDate ?? DateTime.now().add(const Duration(days: 30)),
                  firstDate: DateTime.now(),
                  lastDate: DateTime.now().add(const Duration(days: 365 * 10)),
                );
                if (date != null) {
                  setState(() => _expiryDate = date);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.i18n.t('cancel')),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.i18n.t('add')),
        ),
      ],
    );
  }

  void _submit() {
    // Clear previous errors
    setState(() {
      _quantityError = null;
      _costError = null;
    });

    // Validate quantity
    final qty = _parseDecimal(_quantityController.text);
    if (qty == null || qty <= 0) {
      setState(() => _quantityError = widget.i18n.t('inventory_invalid_number'));
      return;
    }

    // Validate cost (optional, but must be valid if provided)
    double? cost;
    if (_costController.text.isNotEmpty) {
      cost = _parseDecimal(_costController.text);
      if (cost == null) {
        setState(() => _costError = widget.i18n.t('inventory_invalid_number'));
        return;
      }
    }

    Navigator.pop(
      context,
      InventoryBatch(
        id: InventoryFolderUtils.generateBatchId(),
        quantity: qty,
        dateExpired: _expiryDate,
        datePurchased: DateTime.now(),
        cost: cost,
        currency: cost != null ? _selectedCurrency : null,
      ),
    );
  }
}

// Lend dialog
class _LendDialog extends StatefulWidget {
  final I18nService i18n;
  final String unit;
  final double maxQuantity;

  const _LendDialog({
    required this.i18n,
    required this.unit,
    required this.maxQuantity,
  });

  @override
  State<_LendDialog> createState() => _LendDialogState();
}

class _LendDialogState extends State<_LendDialog> {
  final _quantityController = TextEditingController(text: '1');
  final _borrowerController = TextEditingController();
  BorrowerType _borrowerType = BorrowerType.text;
  DateTime? _expectedReturn;

  @override
  void dispose() {
    _quantityController.dispose();
    _borrowerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.i18n.t('inventory_borrow')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Quantity
            TextField(
              controller: _quantityController,
              decoration: InputDecoration(
                labelText: widget.i18n.t('inventory_quantity'),
                suffixText: widget.unit,
                border: const OutlineInputBorder(),
                helperText: '${widget.i18n.t('max')}: ${widget.maxQuantity.toStringAsFixed(0)}',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              autofocus: true,
            ),
            const SizedBox(height: 16),

            // Borrower type toggle
            Text(
              widget.i18n.t('inventory_borrower'),
              style: theme.textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            SegmentedButton<BorrowerType>(
              segments: [
                ButtonSegment(
                  value: BorrowerType.text,
                  label: Text(widget.i18n.t('inventory_borrower_text')),
                  icon: const Icon(Icons.person_outline),
                ),
                ButtonSegment(
                  value: BorrowerType.callsign,
                  label: Text(widget.i18n.t('inventory_borrower_callsign')),
                  icon: const Icon(Icons.person),
                ),
              ],
              selected: {_borrowerType},
              onSelectionChanged: (selection) {
                setState(() => _borrowerType = selection.first);
              },
            ),
            const SizedBox(height: 12),

            // Borrower name/callsign
            TextField(
              controller: _borrowerController,
              decoration: InputDecoration(
                labelText: _borrowerType == BorrowerType.callsign
                    ? widget.i18n.t('callsign')
                    : widget.i18n.t('name'),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),

            // Expected return date
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event),
              title: Text(_expectedReturn != null
                  ? '${_expectedReturn!.day}/${_expectedReturn!.month}/${_expectedReturn!.year}'
                  : widget.i18n.t('inventory_due_date')),
              subtitle: Text(widget.i18n.t('optional')),
              trailing: _expectedReturn != null
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _expectedReturn = null),
                    )
                  : null,
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _expectedReturn ?? DateTime.now().add(const Duration(days: 7)),
                  firstDate: DateTime.now(),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (date != null) {
                  setState(() => _expectedReturn = date);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.i18n.t('cancel')),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.i18n.t('confirm')),
        ),
      ],
    );
  }

  void _submit() {
    final qty = double.tryParse(_quantityController.text);
    final borrower = _borrowerController.text.trim();
    if (qty != null && qty > 0 && qty <= widget.maxQuantity && borrower.isNotEmpty) {
      Navigator.pop(context, {
        'quantity': qty,
        'borrowerType': _borrowerType,
        'borrowerCallsign': _borrowerType == BorrowerType.callsign ? borrower : null,
        'borrowerText': _borrowerType == BorrowerType.text ? borrower : null,
        'expectedReturn': _expectedReturn,
        'notes': null,
      });
    }
  }
}

// Edit usage dialog for editing date/time and notes
class _EditUsageDialog extends StatefulWidget {
  final I18nService i18n;
  final InventoryUsage usage;
  final String unit;

  const _EditUsageDialog({
    required this.i18n,
    required this.usage,
    required this.unit,
  });

  @override
  State<_EditUsageDialog> createState() => _EditUsageDialogState();
}

class _EditUsageDialogState extends State<_EditUsageDialog> {
  late DateTime _selectedDate;
  late TimeOfDay _selectedTime;
  late TextEditingController _notesController;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.usage.date;
    _selectedTime = TimeOfDay.fromDateTime(widget.usage.date);
    _notesController = TextEditingController(text: widget.usage.notes ?? '');
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  String _formatTime(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.i18n.t('inventory_edit_activity')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Show type and quantity (read-only)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      _getUsageIcon(widget.usage.type),
                      color: _getUsageColor(widget.usage.type),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${widget.usage.quantity > 0 ? '+' : ''}${widget.usage.quantity.toStringAsFixed(widget.usage.quantity.truncateToDouble() == widget.usage.quantity ? 0 : 1)} ${widget.unit}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: _getUsageColor(widget.usage.type),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Date picker
            Text(
              widget.i18n.t('date'),
              style: theme.textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _selectedDate,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now(),
                );
                if (date != null) {
                  setState(() => _selectedDate = date);
                }
              },
              icon: const Icon(Icons.calendar_today),
              label: Text(_formatDate(_selectedDate)),
            ),
            const SizedBox(height: 16),

            // Time picker
            Text(
              widget.i18n.t('time'),
              style: theme.textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final time = await showTimePicker(
                  context: context,
                  initialTime: _selectedTime,
                );
                if (time != null) {
                  setState(() => _selectedTime = time);
                }
              },
              icon: const Icon(Icons.access_time),
              label: Text(_formatTime(_selectedTime)),
            ),
            const SizedBox(height: 16),

            // Notes
            TextField(
              controller: _notesController,
              decoration: InputDecoration(
                labelText: widget.i18n.t('notes'),
                border: const OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.i18n.t('cancel')),
        ),
        FilledButton(
          onPressed: () {
            final updatedDate = DateTime(
              _selectedDate.year,
              _selectedDate.month,
              _selectedDate.day,
              _selectedTime.hour,
              _selectedTime.minute,
            );
            final updatedUsage = widget.usage.copyWith(
              date: updatedDate,
              notes: _notesController.text.isNotEmpty ? _notesController.text : null,
            );
            Navigator.pop(context, updatedUsage);
          },
          child: Text(widget.i18n.t('save')),
        ),
      ],
    );
  }

  IconData _getUsageIcon(UsageType type) {
    switch (type) {
      case UsageType.consume:
        return Icons.remove_circle_outline;
      case UsageType.refill:
        return Icons.add_circle_outline;
      case UsageType.adjustment:
        return Icons.tune;
    }
  }

  Color _getUsageColor(UsageType type) {
    switch (type) {
      case UsageType.consume:
        return Colors.red;
      case UsageType.refill:
        return Colors.green;
      case UsageType.adjustment:
        return Colors.blue;
    }
  }
}
