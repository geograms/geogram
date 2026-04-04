/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../services/i18n_service.dart';
import '../../services/log_service.dart';
import '../../services/station_service.dart';
import '../../services/websocket_service.dart';
import '../../util/callsign_url.dart';
import '../models/ndf_document.dart';
import '../models/ndf_interaction_settings.dart';
import '../models/accounting_content.dart';
import '../models/spreadsheet_content.dart';
import '../services/ndf_service.dart';
import '../services/work_storage_service.dart';
import '../widgets/document_interaction_widget.dart';
import '../widgets/document_visibility_widget.dart';
import '../widgets/accounting/accounting_entry_card_widget.dart';
import '../widgets/accounting/accounting_chart_widget.dart';

/// Accounting editor page for tracking income and expenses
class AccountingEditorPage extends StatefulWidget {
  final String filePath;
  final String? title;
  final String? workspaceId;
  final String? documentFilename;
  final WorkStorageService? workStorage;

  const AccountingEditorPage({
    super.key,
    required this.filePath,
    this.title,
    this.workspaceId,
    this.documentFilename,
    this.workStorage,
  });

  @override
  State<AccountingEditorPage> createState() => _AccountingEditorPageState();
}

/// Map of category keys to i18n keys for display
const _categoryI18nKeys = {
  'Food': 'work_accounting_cat_food',
  'Transport': 'work_accounting_cat_transport',
  'Housing': 'work_accounting_cat_housing',
  'Utilities': 'work_accounting_cat_utilities',
  'Health': 'work_accounting_cat_health',
  'Education': 'work_accounting_cat_education',
  'Entertainment': 'work_accounting_cat_entertainment',
  'Shopping': 'work_accounting_cat_shopping',
  'Other': 'work_accounting_cat_other',
  'Salary': 'work_accounting_cat_salary',
  'Freelance': 'work_accounting_cat_freelance',
  'Investment': 'work_accounting_cat_investment',
  'Gift': 'work_accounting_cat_gift',
  'Other Income': 'work_accounting_cat_other_income',
};

class _AccountingEditorPageState extends State<AccountingEditorPage> {
  final I18nService _i18n = I18nService();
  final NdfService _ndfService = NdfService();
  final FocusNode _focusNode = FocusNode();

  NdfDocument? _metadata;
  AccountingContent? _content;
  List<AccountingEntry> _entries = [];
  bool _isLoading = true;
  bool _hasChanges = false;
  bool _isSaving = false;
  String? _error;
  AccountingEntryType? _filterType; // null = all

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

      final content = await _ndfService.readAccountingContent(widget.filePath);
      if (content == null) {
        throw Exception('Could not read accounting content');
      }

      final entries = await _ndfService.readAccountingEntries(widget.filePath, content.entries);

      setState(() {
        _metadata = metadata;
        _content = content;
        _entries = entries;
        _isLoading = false;
      });
    } catch (e) {
      LogService().log('AccountingEditorPage: Error loading document: $e');
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
    setState(() { _hasChanges = false; });

    try {
      _metadata!.touch();
      _content!.touch();
      await _ndfService.saveAccounting(widget.filePath, _content!, _entries);
      await _ndfService.updateMetadata(widget.filePath, _metadata!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('document_saved'))),
        );
      }
    } catch (e) {
      LogService().log('AccountingEditorPage: Error saving document: $e');
      if (mounted) {
        setState(() { _hasChanges = true; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e')),
        );
      }
    } finally {
      _isSaving = false;
    }
  }

  void _addEntry() async {
    if (_content == null) return;

    final result = await Navigator.push<AccountingEntry>(
      context,
      MaterialPageRoute(
        builder: (context) => _AccountingEntryFormPage(
          i18n: _i18n,
          title: _i18n.t('work_accounting_add_entry'),
          customCategories: _content!.customCategories,
          getCategoryLabel: _getCategoryLabel,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _entries.add(result);
        _content?.addEntry(result.id);
        _hasChanges = true;
      });
    }
  }

  void _editEntry(AccountingEntry entry) async {
    if (_content == null) return;

    final result = await Navigator.push<AccountingEntry>(
      context,
      MaterialPageRoute(
        builder: (context) => _AccountingEntryFormPage(
          i18n: _i18n,
          title: _i18n.t('work_accounting_edit_entry'),
          initialDescription: entry.description,
          initialAmount: entry.amount,
          initialDate: entry.date,
          initialType: entry.type,
          initialCategory: entry.category,
          customCategories: _content!.customCategories,
          getCategoryLabel: _getCategoryLabel,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        entry.description = result.description;
        entry.date = result.date;
        entry.amount = result.amount;
        entry.type = result.type;
        entry.category = result.category;
        _hasChanges = true;
      });
    }
  }

  void _deleteEntry(AccountingEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_accounting_delete_entry')),
        content: Text(_i18n.t('work_accounting_delete_entry_confirm').replaceAll('{name}', entry.description)),
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
        _entries.removeWhere((e) => e.id == entry.id);
        _content?.removeEntry(entry.id);
        _hasChanges = true;
      });

      try {
        await _ndfService.deleteAccountingEntry(widget.filePath, entry.id);
      } catch (e) {
        LogService().log('AccountingEditorPage: Error deleting entry file: $e');
      }
    }
  }

  String _getCategoryLabel(String category) {
    final key = _categoryI18nKeys[category];
    if (key != null) return _i18n.t(key);
    return category; // Custom category, show as-is
  }

  List<AccountingEntry> _getSortedFilteredEntries() {
    var items = List<AccountingEntry>.from(_entries);

    // Filter
    if (_filterType != null) {
      items = items.where((e) => e.type == _filterType).toList();
    }

    // Sort
    final sortOrder = _content?.settings.sortOrder ?? AccountingSortOrder.dateDesc;
    switch (sortOrder) {
      case AccountingSortOrder.dateDesc:
        items.sort((a, b) => b.date.compareTo(a.date));
      case AccountingSortOrder.dateAsc:
        items.sort((a, b) => a.date.compareTo(b.date));
      case AccountingSortOrder.amountDesc:
        items.sort((a, b) => b.amount.compareTo(a.amount));
      case AccountingSortOrder.amountAsc:
        items.sort((a, b) => a.amount.compareTo(b.amount));
    }

    return items;
  }

  double get _totalIncome => _entries
      .where((e) => e.type == AccountingEntryType.income)
      .fold(0.0, (sum, e) => sum + e.amount);

  double get _totalExpenses => _entries
      .where((e) => e.type == AccountingEntryType.expense)
      .fold(0.0, (sum, e) => sum + e.amount);

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
              child: Text(_content?.title ?? widget.title ?? _i18n.t('work_accounting')),
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
                        Text(_i18n.t('work_accounting_rename')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'currency',
                    child: Row(
                      children: [
                        const Icon(Icons.currency_exchange),
                        const SizedBox(width: 8),
                        Text(_i18n.t('work_accounting_change_currency')),
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
            onPressed: _addEntry,
            child: const Icon(Icons.add),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loadDocument,
              child: Text(_i18n.t('retry')),
            ),
          ],
        ),
      );
    }

    if (_content == null) {
      return const Center(child: Text('No content'));
    }

    final sortedEntries = _getSortedFilteredEntries();
    final currency = CurrencyFormat.byCode(_content!.currency);
    final net = _totalIncome - _totalExpenses;

    return Column(
      children: [
        // Summary card
        _buildSummaryCard(currency, net),

        // Chart (expandable)
        if (_content!.settings.showChart && _entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: AccountingChartWidget(
              entries: _entries,
              viewPeriod: _content!.settings.viewPeriod,
              currencyCode: _content!.currency,
            ),
          ),

        // Filter chips
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              FilterChip(
                label: Text(_i18n.t('work_accounting_filter_all')),
                selected: _filterType == null,
                onSelected: (_) => setState(() => _filterType = null),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: Text(_i18n.t('work_accounting_filter_income')),
                selected: _filterType == AccountingEntryType.income,
                onSelected: (_) => setState(() =>
                    _filterType = _filterType == AccountingEntryType.income ? null : AccountingEntryType.income),
                selectedColor: Colors.green.withValues(alpha: 0.2),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: Text(_i18n.t('work_accounting_filter_expense')),
                selected: _filterType == AccountingEntryType.expense,
                onSelected: (_) => setState(() =>
                    _filterType = _filterType == AccountingEntryType.expense ? null : AccountingEntryType.expense),
                selectedColor: Colors.red.withValues(alpha: 0.2),
              ),
            ],
          ),
        ),

        // Entry list
        Expanded(
          child: sortedEntries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.account_balance_wallet_outlined,
                          size: 64, color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 16),
                      Text(_i18n.t('work_accounting_no_entries'),
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(_i18n.t('work_accounting_add_first'),
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              )),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: sortedEntries.length,
                  itemBuilder: (context, index) {
                    final entry = sortedEntries[index];
                    return AccountingEntryCardWidget(
                      entry: entry,
                      currencyCode: _content!.currency,
                      onEdit: () => _editEntry(entry),
                      onDelete: () => _deleteEntry(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSummaryCard(CurrencyFormat? currency, double net) {
    final theme = Theme.of(context);
    final netColor = net >= 0 ? Colors.green : Colors.red;

    String formatAmount(double amount) {
      if (currency != null) {
        final displayDecimals = currency.isCrypto ? 4 : 2;
        final formatted = amount.toStringAsFixed(displayDecimals);
        if (currency.symbolBefore) return '${currency.symbol}$formatted';
        return '$formatted ${currency.symbol}';
      }
      return '${amount.toStringAsFixed(2)} ${_content!.currency}';
    }

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_i18n.t('work_accounting_total_income'),
                      style: theme.textTheme.labelSmall),
                  Text(formatAmount(_totalIncome),
                      style: theme.textTheme.titleSmall?.copyWith(color: Colors.green)),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_i18n.t('work_accounting_total_expenses'),
                      style: theme.textTheme.labelSmall),
                  Text(formatAmount(_totalExpenses),
                      style: theme.textTheme.titleSmall?.copyWith(color: Colors.red)),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_i18n.t('work_accounting_net_balance'),
                      style: theme.textTheme.labelSmall),
                  Text(
                    '${net >= 0 ? '+' : ''}${formatAmount(net.abs())}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: netColor,
                      fontWeight: FontWeight.bold,
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

  void _handleMenuAction(String action) {
    switch (action) {
      case 'rename':
        _renameDocument();
      case 'currency':
        _showCurrencyPicker();
      case 'settings':
        _showSettings();
    }
  }

  void _renameDocument() async {
    if (_content == null) return;

    final controller = TextEditingController(text: _content!.title);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_accounting_rename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _i18n.t('title'),
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

  void _showCurrencyPicker() async {
    if (_content == null) return;

    // Build currency list: EUR first, then remaining fiat, then crypto
    final currencies = <CurrencyFormat>[];
    final eur = CurrencyFormat.byCode('EUR');
    if (eur != null) currencies.add(eur);
    for (final c in CurrencyFormat.fiatCurrencies) {
      if (c.code != 'EUR') currencies.add(c);
    }
    for (final c in CurrencyFormat.cryptoCurrencies) {
      currencies.add(c);
    }

    final result = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(_i18n.t('work_accounting_currency')),
        children: currencies.map((c) {
          final isSelected = c.code == _content!.currency;
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(context, c.code),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(c.symbol,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                Expanded(child: Text('${c.name} (${c.code})')),
                if (isSelected)
                  const Icon(Icons.check, color: Colors.green, size: 20),
              ],
            ),
          );
        }).toList(),
      ),
    );

    if (result != null && result != _content!.currency) {
      setState(() {
        _content!.currency = result;
        _hasChanges = true;
      });
    }
  }

  void _showSettings() async {
    if (_content == null) return;

    final settings = _content!.settings;
    var sortOrder = settings.sortOrder;
    var viewPeriod = settings.viewPeriod;
    var showChart = settings.showChart;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(_i18n.t('work_accounting_settings')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_i18n.t('work_accounting_show_chart')),
                  value: showChart,
                  onChanged: (val) => setDialogState(() => showChart = val),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<AccountingViewPeriod>(
                  value: viewPeriod,
                  decoration: InputDecoration(
                    labelText: _i18n.t('work_accounting_view_weekly'),
                    border: const OutlineInputBorder(),
                  ),
                  items: AccountingViewPeriod.values.map((vp) {
                    return DropdownMenuItem(
                      value: vp,
                      child: Text(vp == AccountingViewPeriod.weekly
                          ? _i18n.t('work_accounting_view_weekly')
                          : _i18n.t('work_accounting_view_monthly')),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) setDialogState(() => viewPeriod = val);
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<AccountingSortOrder>(
                  value: sortOrder,
                  decoration: InputDecoration(
                    labelText: _i18n.t('sort_order'),
                    border: const OutlineInputBorder(),
                  ),
                  items: AccountingSortOrder.values.map((order) {
                    return DropdownMenuItem(
                      value: order,
                      child: Text(_getSortOrderLabel(order)),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) setDialogState(() => sortOrder = val);
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
        _content!.settings = AccountingSettings(
          sortOrder: sortOrder,
          viewPeriod: viewPeriod,
          showChart: showChart,
        );
        _hasChanges = true;
      });
    }
  }

  String _getSortOrderLabel(AccountingSortOrder order) {
    switch (order) {
      case AccountingSortOrder.dateDesc:
        return _i18n.t('work_accounting_sort_date_desc');
      case AccountingSortOrder.dateAsc:
        return _i18n.t('work_accounting_sort_date_asc');
      case AccountingSortOrder.amountDesc:
        return _i18n.t('work_accounting_sort_amount_desc');
      case AccountingSortOrder.amountAsc:
        return _i18n.t('work_accounting_sort_amount_asc');
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
    return buildStationAppUrl(url, 'work/$workspaceId/$filename');
  }
}

// ============================================================
// ENTRY FORM PAGE
// ============================================================

class _AccountingEntryFormPage extends StatefulWidget {
  final I18nService i18n;
  final String title;
  final String? initialDescription;
  final double? initialAmount;
  final DateTime? initialDate;
  final AccountingEntryType? initialType;
  final String? initialCategory;
  final List<String> customCategories;
  final String Function(String) getCategoryLabel;

  const _AccountingEntryFormPage({
    required this.i18n,
    required this.title,
    this.initialDescription,
    this.initialAmount,
    this.initialDate,
    this.initialType,
    this.initialCategory,
    required this.customCategories,
    required this.getCategoryLabel,
  });

  @override
  State<_AccountingEntryFormPage> createState() => _AccountingEntryFormPageState();
}

class _AccountingEntryFormPageState extends State<_AccountingEntryFormPage> {
  late final TextEditingController _descriptionController;
  late final TextEditingController _amountController;
  late DateTime _date;
  late AccountingEntryType _type;
  late String _category;

  @override
  void initState() {
    super.initState();
    _descriptionController = TextEditingController(text: widget.initialDescription ?? '');
    _amountController = TextEditingController(
      text: widget.initialAmount != null ? widget.initialAmount!.toStringAsFixed(2) : '',
    );
    _date = widget.initialDate ?? DateTime.now();
    _type = widget.initialType ?? AccountingEntryType.expense;
    _category = widget.initialCategory ?? defaultExpenseCategories.first;
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  List<String> get _availableCategories {
    final defaults = _type == AccountingEntryType.income
        ? defaultIncomeCategories
        : defaultExpenseCategories;
    return [...defaults, ...widget.customCategories];
  }

  void _submit() {
    final description = _descriptionController.text.trim();
    final amountText = _amountController.text.trim();
    if (description.isEmpty || amountText.isEmpty) return;

    final amount = double.tryParse(amountText);
    if (amount == null || amount <= 0) return;

    final entry = AccountingEntry.create(
      description: description,
      date: _date,
      amount: amount,
      type: _type,
      category: _category,
    );

    Navigator.pop(context, entry);
  }

  void _addCustomCategory() async {
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('work_accounting_add_category')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: widget.i18n.t('work_accounting_category_name'),
            border: const OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
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

    if (result != null && result.trim().isNotEmpty) {
      final name = result.trim();
      if (!widget.customCategories.contains(name)) {
        widget.customCategories.add(name);
      }
      setState(() {
        _category = name;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = widget.i18n;
    final categories = _availableCategories;

    // Ensure current category is in the list
    if (!categories.contains(_category)) {
      _category = categories.first;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          FilledButton(
            onPressed: _submit,
            child: Text(i18n.t('save')),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Type toggle
            SegmentedButton<AccountingEntryType>(
              segments: [
                ButtonSegment(
                  value: AccountingEntryType.expense,
                  label: Text(i18n.t('work_accounting_type_expense')),
                  icon: const Icon(Icons.arrow_downward),
                ),
                ButtonSegment(
                  value: AccountingEntryType.income,
                  label: Text(i18n.t('work_accounting_type_income')),
                  icon: const Icon(Icons.arrow_upward),
                ),
              ],
              selected: {_type},
              onSelectionChanged: (selected) {
                setState(() {
                  _type = selected.first;
                  // Reset category to first available for this type
                  final cats = _availableCategories;
                  if (!cats.contains(_category)) {
                    _category = cats.first;
                  }
                });
              },
            ),
            const SizedBox(height: 16),

            // Description
            TextField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: i18n.t('work_accounting_description'),
                border: const OutlineInputBorder(),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),

            // Amount
            TextField(
              controller: _amountController,
              decoration: InputDecoration(
                labelText: i18n.t('work_accounting_amount'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.attach_money),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
              ],
            ),
            const SizedBox(height: 16),

            // Date
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
                side: BorderSide(color: Theme.of(context).colorScheme.outline),
              ),
              leading: const Icon(Icons.calendar_today),
              title: Text(i18n.t('work_accounting_date')),
              subtitle: Text(DateFormat.yMMMd().format(_date)),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setState(() => _date = picked);
                }
              },
            ),
            const SizedBox(height: 16),

            // Category
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: categories.contains(_category) ? _category : categories.first,
                    decoration: InputDecoration(
                      labelText: i18n.t('work_accounting_category'),
                      border: const OutlineInputBorder(),
                    ),
                    items: categories.map((cat) {
                      return DropdownMenuItem(
                        value: cat,
                        child: Text(widget.getCategoryLabel(cat)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _category = val);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: i18n.t('work_accounting_add_category'),
                  onPressed: _addCustomCategory,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
