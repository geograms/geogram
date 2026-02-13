/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Email Browser Page - Lists email threads across stations
 */

import 'dart:async';
import 'package:flutter/material.dart';
import '../models/app.dart';
import '../models/email_thread.dart';
import '../services/app_service.dart';
import '../services/email_service.dart';
import '../services/profile_storage.dart';
import '../util/event_bus.dart';
import 'email_thread_page.dart';
import 'email_compose_page.dart';

/// Email folder types
enum EmailFolder { inbox, sent, outbox, drafts, archive, spam, garbage, label }

class _NavigationRailLayout {
  final bool extended;
  final double width;

  const _NavigationRailLayout({required this.extended, required this.width});
}

class _FolderStats {
  final int totalMessages;
  final int unreadMessages;

  const _FolderStats({
    required this.totalMessages,
    required this.unreadMessages,
  });

  static const empty = _FolderStats(totalMessages: 0, unreadMessages: 0);
}

enum _BulkThreadAction {
  move,
  archive,
  reportSpam,
  delete,
  markRead,
  markUnread,
}

/// Email browser page with folder navigation and thread list
class EmailBrowserPage extends StatefulWidget {
  /// The email app entry (provides storagePath)
  final App? app;

  /// Initial folder to display
  final EmailFolder initialFolder;

  /// Initial station (null for unified view)
  final String? initialStation;

  /// Initial label (for label folder)
  final String? initialLabel;

  /// Optional thread to open/select once the list is loaded.
  final String? initialThreadId;

  const EmailBrowserPage({
    super.key,
    this.app,
    this.initialFolder = EmailFolder.inbox,
    this.initialStation,
    this.initialLabel,
    this.initialThreadId,
  });

  @override
  State<EmailBrowserPage> createState() => _EmailBrowserPageState();
}

class _EmailBrowserPageState extends State<EmailBrowserPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final EmailService _emailService = EmailService();

  List<EmailThread> _threads = [];
  EmailThread? _selectedThread;
  EmailFolder _currentFolder = EmailFolder.inbox;
  String? _currentStation; // null = unified (all stations)
  String? _currentLabel;
  bool _isLoading = true;
  String? _error;
  List<String> _labels = [];
  bool _isWideScreen = false;
  Map<EmailFolder, _FolderStats> _folderStats = {};
  final Set<String> _selectedThreadIds = <String>{};
  bool _isApplyingBulkAction = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  static const double _collapsedRailWidth = 72;
  static const double _minExpandedRailWidth = 152;
  static const double _maxExpandedRailWidth = 200;
  static const double _minDesktopContentWidth = 620;
  static const double _desktopBreakpoint = 960;

  static const List<EmailFolder> _folderOrder = [
    EmailFolder.inbox,
    EmailFolder.sent,
    EmailFolder.outbox,
    EmailFolder.drafts,
    EmailFolder.archive,
    EmailFolder.spam,
    EmailFolder.garbage,
  ];

  StreamSubscription<EmailChangeEvent>? _emailSubscription;
  EventSubscription<EmailNotificationEvent>? _notificationSubscription;
  bool _didHandleInitialThreadOpen = false;

  bool get _isSelectionMode => _selectedThreadIds.isNotEmpty;

  Future<_FolderStats> _computeStatsForStation(
    Future<List<EmailThread>> future,
  ) async {
    final threads = await future;
    final filteredThreads = _currentStation != null
        ? threads.where((t) => t.station == _currentStation)
        : threads;

    var totalMessages = 0;
    var unreadMessages = 0;
    for (final thread in filteredThreads) {
      totalMessages += 1;
      if (thread.isUnread) {
        unreadMessages += 1;
      }
    }

    return _FolderStats(
      totalMessages: totalMessages,
      unreadMessages: unreadMessages,
    );
  }

  _FolderStats _computeStatsFromThreads(Iterable<EmailThread> threads) {
    var totalMessages = 0;
    var unreadMessages = 0;
    for (final thread in threads) {
      totalMessages += 1;
      if (thread.isUnread) {
        unreadMessages += 1;
      }
    }

    return _FolderStats(
      totalMessages: totalMessages,
      unreadMessages: unreadMessages,
    );
  }

  _FolderStats get _activeFolderStats {
    if (_currentFolder == EmailFolder.label) {
      return _computeStatsFromThreads(_threads);
    }
    return _folderStats[_currentFolder] ?? _FolderStats.empty;
  }

  PreferredSizeWidget _buildAppBar(ThemeData theme) {
    if (_isSelectionMode) {
      final selectedCount = _selectedThreadIds.length;
      return AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel selection',
          onPressed: _isApplyingBulkAction ? null : _clearSelection,
        ),
        title: Text('$selectedCount selected'),
        actions: [
          IconButton(
            icon: const Icon(Icons.drive_file_move_outline),
            tooltip: 'Move selected',
            onPressed: _isApplyingBulkAction
                ? null
                : () => _applyBulkAction(_BulkThreadAction.move),
          ),
          IconButton(
            icon: const Icon(Icons.archive_outlined),
            tooltip: 'Archive selected',
            onPressed: _isApplyingBulkAction
                ? null
                : () => _applyBulkAction(_BulkThreadAction.archive),
          ),
          IconButton(
            icon: const Icon(Icons.report_outlined),
            tooltip: 'Report selected as spam',
            onPressed: _isApplyingBulkAction
                ? null
                : () => _applyBulkAction(_BulkThreadAction.reportSpam),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete selected',
            onPressed: _isApplyingBulkAction
                ? null
                : () => _applyBulkAction(_BulkThreadAction.delete),
          ),
          PopupMenuButton<_BulkThreadAction>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More actions',
            onSelected: (action) {
              if (_isApplyingBulkAction) return;
              _applyBulkAction(action);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _BulkThreadAction.markRead,
                child: ListTile(
                  leading: Icon(Icons.mark_email_read_outlined),
                  title: Text('Mark selected as read'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _BulkThreadAction.markUnread,
                child: ListTile(
                  leading: Icon(Icons.mark_email_unread_outlined),
                  title: Text('Mark selected as unread'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      );
    }

    final subtitle = _currentLabel != null
        ? 'Label: $_currentLabel'
        : _getFolderTitle();

    return AppBar(
      automaticallyImplyLeading: false,
      leading: Navigator.canPop(context)
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
              tooltip: 'Back',
            )
          : null,
      titleSpacing: 16,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Mail',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            subtitle,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.checklist),
          tooltip: 'Select conversations',
          onPressed: _isSelectionMode
              ? null
              : _enterSelectionModeForVisibleThreads,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.menu),
          onSelected: (value) {
            switch (value) {
              case 'refresh':
                _refresh();
                break;
              case 'labels':
                _showLabelsSheet();
                break;
              case 'select':
                _enterSelectionModeForVisibleThreads();
                break;
              case 'accounts':
              case 'settings':
                _handleMenuAction(value);
                break;
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'refresh',
              child: ListTile(
                leading: Icon(Icons.refresh),
                title: Text('Refresh'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            if (_labels.isNotEmpty)
              const PopupMenuItem(
                value: 'labels',
                child: ListTile(
                  leading: Icon(Icons.label_outline),
                  title: Text('Labels'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            const PopupMenuItem(
              value: 'select',
              child: ListTile(
                leading: Icon(Icons.checklist),
                title: Text('Select conversations'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'accounts',
              child: ListTile(
                leading: Icon(Icons.account_circle),
                title: Text('Accounts'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: 'settings',
              child: ListTile(
                leading: Icon(Icons.settings),
                title: Text('Settings'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _buildSearchBar(theme, showFolderMenu: !_isWideScreen),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _currentFolder = widget.initialFolder;
    _currentStation = widget.initialStation;
    _currentLabel = widget.initialLabel;
    _searchController.addListener(() {
      if (!mounted) return;
      setState(() => _searchQuery = _searchController.text);
    });
    _initialize();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _emailSubscription?.cancel();
    _notificationSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      // Set up ProfileStorage for the email app (same pattern as ChatBrowserPage)
      final storagePath = widget.app?.storagePath;
      if (storagePath != null) {
        final profileStorage = AppService().profileStorage;
        if (profileStorage != null) {
          final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
            profileStorage,
            storagePath,
          );
          _emailService.setStorage(scopedStorage);
        } else {
          _emailService.setStorage(FilesystemProfileStorage(storagePath));
        }
      }

      await _emailService.initialize();
      _emailSubscription = _emailService.onEmailChange.listen(_onEmailChange);
      _notificationSubscription = EventBus().on<EmailNotificationEvent>(
        _onEmailNotification,
      );
      await _loadLabels();
      await _loadFolderCounts();
      await _loadThreads();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to initialize email: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadFolderCounts() async {
    final counts = <EmailFolder, _FolderStats>{};
    counts[EmailFolder.inbox] = await _computeStatsForStation(
      _emailService.getInbox(),
    );
    counts[EmailFolder.sent] = await _computeStatsForStation(
      _emailService.getSent(),
    );
    counts[EmailFolder.outbox] = await _computeStatsForStation(
      _emailService.getOutbox(),
    );
    counts[EmailFolder.drafts] = await _computeStatsForStation(
      _emailService.getDrafts(),
    );
    counts[EmailFolder.archive] = await _computeStatsForStation(
      _emailService.getArchive(),
    );
    counts[EmailFolder.spam] = await _computeStatsForStation(
      _emailService.getSpam(),
    );
    counts[EmailFolder.garbage] = await _computeStatsForStation(
      _emailService.getGarbage(),
    );
    if (mounted) {
      setState(() => _folderStats = counts);
    }
  }

  void _onEmailNotification(EmailNotificationEvent event) {
    if (!mounted) return;

    // Determine snackbar color based on action
    Color backgroundColor;
    IconData icon;
    switch (event.action) {
      case 'delivered':
        backgroundColor = Colors.green;
        icon = Icons.check_circle;
        break;
      case 'failed':
        backgroundColor = Colors.red;
        icon = Icons.error;
        break;
      case 'pending_approval':
        backgroundColor = Colors.orange;
        icon = Icons.hourglass_empty;
        break;
      case 'sending':
        backgroundColor = Colors.blue;
        icon = Icons.send;
        break;
      case 'pending':
        backgroundColor = Colors.blue;
        icon = Icons.schedule;
        break;
      case 'delayed':
        backgroundColor = Colors.amber;
        icon = Icons.schedule;
        break;
      default:
        backgroundColor = Colors.blue;
        icon = Icons.info;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(event.message)),
          ],
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.fixed,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _loadLabels() async {
    final labels = await _emailService.getLabels();
    if (mounted) {
      setState(() => _labels = labels);
    }
  }

  Future<void> _createLabel() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Label'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Label name',
            hintText: 'e.g., Work, Personal, Important',
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(context, name);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await _emailService.createLabel(result);
      await _loadLabels();
    }
  }

  Future<void> _deleteLabel(String label) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Label?'),
        content: Text(
          'Are you sure you want to delete the label "$label"?\n\n'
          'Emails with this label will not be deleted, only the label will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _emailService.deleteLabel(label);
      await _loadLabels();
      if (_currentLabel == label) {
        _selectFolder(EmailFolder.inbox);
      }
    }
  }

  void _onEmailChange(EmailChangeEvent event) {
    // Reload threads and folder counts when changes occur
    _loadFolderCounts();
    _loadThreads();
  }

  Future<void> _loadThreads() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      List<EmailThread> threads;

      // All folders are unified - no per-station filtering needed
      switch (_currentFolder) {
        case EmailFolder.inbox:
          threads = await _emailService.getInbox();
          break;
        case EmailFolder.sent:
          threads = await _emailService.getSent();
          break;
        case EmailFolder.outbox:
          threads = await _emailService.getOutbox();
          break;
        case EmailFolder.drafts:
          threads = await _emailService.getDrafts();
          break;
        case EmailFolder.archive:
          threads = await _emailService.getArchive();
          break;
        case EmailFolder.spam:
          threads = await _emailService.getSpam();
          break;
        case EmailFolder.garbage:
          threads = await _emailService.getGarbage();
          break;
        case EmailFolder.label:
          if (_currentLabel != null) {
            threads = await _emailService.getThreadsByLabel(_currentLabel!);
          } else {
            threads = [];
          }
          break;
      }

      if (mounted) {
        setState(() {
          _threads = threads;
          _selectedThreadIds.removeWhere(
            (id) => !_threads.any((t) => t.threadId == id),
          );
          _isLoading = false;
          if (_selectedThread != null &&
              !_threads.any((t) => t.threadId == _selectedThread!.threadId)) {
            _selectedThread = null;
          }
        });
        await _openInitialThreadIfNeeded(threads);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _openInitialThreadIfNeeded(List<EmailThread> threads) async {
    if (_didHandleInitialThreadOpen) return;

    final targetThreadId = widget.initialThreadId?.trim();
    if (targetThreadId == null || targetThreadId.isEmpty) {
      _didHandleInitialThreadOpen = true;
      return;
    }

    EmailThread? targetThread;
    for (final thread in threads) {
      if (thread.threadId == targetThreadId) {
        targetThread = thread;
        break;
      }
    }
    if (targetThread == null || !mounted) return;

    _didHandleInitialThreadOpen = true;
    final isWide = MediaQuery.sizeOf(context).width >= _desktopBreakpoint;
    if (isWide) {
      setState(() {
        _selectedThread = targetThread;
      });
      return;
    }

    final selectedThread = targetThread;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => EmailThreadPage(thread: selectedThread),
      ),
    );
    if (mounted) {
      await _loadThreads();
    }
  }

  Future<void> _refresh() async {
    await _loadFolderCounts();
    await _loadThreads();
    await _emailService.processOutbox();
  }

  List<EmailThread> get _visibleThreads {
    if (_searchQuery.trim().isEmpty) return _threads;
    final query = _searchQuery.toLowerCase();
    return _threads.where((thread) {
      final haystack = [
        thread.subject,
        thread.from,
        ...thread.to,
        ...thread.cc,
        ...thread.labels,
        thread.preview,
        thread.station,
      ].join(' ').toLowerCase();
      return haystack.contains(query);
    }).toList();
  }

  String _getFolderTitle() {
    switch (_currentFolder) {
      case EmailFolder.inbox:
        return _currentStation != null
            ? '${_folderLabelWithCount(EmailFolder.inbox)} - $_currentStation'
            : _folderLabelWithCount(EmailFolder.inbox);
      case EmailFolder.sent:
        return _currentStation != null
            ? '${_folderLabelWithCount(EmailFolder.sent)} - $_currentStation'
            : _folderLabelWithCount(EmailFolder.sent);
      case EmailFolder.outbox:
        return _currentStation != null
            ? '${_folderLabelWithCount(EmailFolder.outbox)} - $_currentStation'
            : _folderLabelWithCount(EmailFolder.outbox);
      case EmailFolder.drafts:
        return _folderLabelWithCount(EmailFolder.drafts);
      case EmailFolder.archive:
        return _folderLabelWithCount(EmailFolder.archive);
      case EmailFolder.spam:
        return _currentStation != null
            ? '${_folderLabelWithCount(EmailFolder.spam)} - $_currentStation'
            : _folderLabelWithCount(EmailFolder.spam);
      case EmailFolder.garbage:
        return _folderLabelWithCount(EmailFolder.garbage);
      case EmailFolder.label:
        final count = _threads.length;
        return '${_currentLabel ?? 'Label'} ($count)';
    }
  }

  IconData _getFolderIcon(EmailFolder folder) {
    switch (folder) {
      case EmailFolder.inbox:
        return Icons.inbox;
      case EmailFolder.sent:
        return Icons.send;
      case EmailFolder.outbox:
        return Icons.outbox;
      case EmailFolder.drafts:
        return Icons.drafts;
      case EmailFolder.archive:
        return Icons.archive;
      case EmailFolder.spam:
        return Icons.report;
      case EmailFolder.garbage:
        return Icons.delete;
      case EmailFolder.label:
        return Icons.label;
    }
  }

  void _selectFolder(EmailFolder folder, {String? station, String? label}) {
    setState(() {
      _currentFolder = folder;
      _currentStation = station;
      _currentLabel = label;
      _selectedThread = null;
      _selectedThreadIds.clear();
    });
    _loadThreads();
  }

  void _selectThread(EmailThread thread) {
    if (_isSelectionMode) {
      _toggleThreadSelection(thread);
      return;
    }

    // Drafts should open in compose mode for editing
    if (thread.isDraft) {
      Navigator.of(context)
          .push<EmailThread>(
            MaterialPageRoute(
              builder: (context) => EmailComposePage(editDraft: thread),
            ),
          )
          .then((_) => _loadThreads());
      return;
    }

    if (_isWideScreen) {
      setState(() {
        _selectedThread = thread;
      });
    } else {
      // Navigate to thread page on mobile
      Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (context) => EmailThreadPage(thread: thread),
            ),
          )
          .then((_) => _loadThreads());
    }
  }

  void _enterSelectionModeForVisibleThreads() {
    if (_visibleThreads.isEmpty) return;
    setState(() {
      _selectedThreadIds.clear();
      _selectedThreadIds.add(_visibleThreads.first.threadId);
    });
  }

  void _startThreadSelection(EmailThread thread) {
    setState(() {
      _selectedThreadIds.add(thread.threadId);
    });
  }

  void _toggleThreadSelection(EmailThread thread) {
    setState(() {
      if (_selectedThreadIds.contains(thread.threadId)) {
        _selectedThreadIds.remove(thread.threadId);
      } else {
        _selectedThreadIds.add(thread.threadId);
      }
    });
  }

  void _clearSelection() {
    if (!_isSelectionMode) return;
    setState(() {
      _selectedThreadIds.clear();
      _isApplyingBulkAction = false;
    });
  }

  Future<void> _applyBulkAction(_BulkThreadAction action) async {
    if (_selectedThreadIds.isEmpty || _isApplyingBulkAction) return;

    final selectedThreads = _threads
        .where((thread) => _selectedThreadIds.contains(thread.threadId))
        .toList();
    if (selectedThreads.isEmpty) {
      _clearSelection();
      return;
    }

    EmailStatus? moveTargetStatus;
    if (action == _BulkThreadAction.move) {
      moveTargetStatus = await _showMoveDestinationPicker(
        selectedThreads.length,
      );
      if (moveTargetStatus == null) return;
    }
    if (!mounted) return;

    if (action == _BulkThreadAction.delete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete selected?'),
          content: Text(
            'Move ${selectedThreads.length} selected conversation${selectedThreads.length == 1 ? '' : 's'} to trash?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() => _isApplyingBulkAction = true);

    try {
      var affectedCount = 0;
      for (final thread in selectedThreads) {
        switch (action) {
          case _BulkThreadAction.archive:
            await _emailService.archiveThread(thread);
            affectedCount += 1;
            break;
          case _BulkThreadAction.move:
            if (moveTargetStatus != null && thread.status != moveTargetStatus) {
              await _emailService.moveThread(thread, moveTargetStatus);
              affectedCount += 1;
            }
            break;
          case _BulkThreadAction.reportSpam:
            await _emailService.markAsSpam(thread);
            affectedCount += 1;
            break;
          case _BulkThreadAction.delete:
            await _emailService.deleteThread(thread);
            affectedCount += 1;
            break;
          case _BulkThreadAction.markRead:
            if (thread.status == EmailStatus.received && thread.isUnread) {
              await _emailService.markThreadRead(thread);
              affectedCount += 1;
            }
            break;
          case _BulkThreadAction.markUnread:
            if (thread.status == EmailStatus.received && !thread.isUnread) {
              await _emailService.markThreadUnread(thread);
              affectedCount += 1;
            }
            break;
        }

        if (_selectedThread?.threadId == thread.threadId) {
          _selectedThread = null;
        }
      }

      if (mounted) {
        if (affectedCount > 0) {
          final actionLabel = switch (action) {
            _BulkThreadAction.move =>
              'moved to ${_bulkMoveDestinationLabel(moveTargetStatus!)}',
            _BulkThreadAction.archive => 'archived',
            _BulkThreadAction.reportSpam => 'reported as spam',
            _BulkThreadAction.delete => 'moved to trash',
            _BulkThreadAction.markRead => 'marked as read',
            _BulkThreadAction.markUnread => 'marked as unread',
          };
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '$affectedCount conversation${affectedCount == 1 ? '' : 's'} $actionLabel',
              ),
            ),
          );
        } else if (action == _BulkThreadAction.markRead ||
            action == _BulkThreadAction.markUnread) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No inbox conversations matched this action'),
            ),
          );
        } else if (action == _BulkThreadAction.move &&
            moveTargetStatus != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Selected conversations are already in ${_bulkMoveDestinationLabel(moveTargetStatus)}',
              ),
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _selectedThreadIds.clear();
          _isApplyingBulkAction = false;
        });
      }
      await _loadFolderCounts();
      await _loadThreads();
    }
  }

  Future<EmailStatus?> _showMoveDestinationPicker(int selectedCount) {
    return showModalBottomSheet<EmailStatus>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'Move $selectedCount selected conversation${selectedCount == 1 ? '' : 's'}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('Inbox'),
              onTap: () => Navigator.pop(context, EmailStatus.received),
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('Archive'),
              onTap: () => Navigator.pop(context, EmailStatus.archived),
            ),
            ListTile(
              leading: const Icon(Icons.report_outlined),
              title: const Text('Spam'),
              onTap: () => Navigator.pop(context, EmailStatus.spam),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Trash'),
              onTap: () => Navigator.pop(context, EmailStatus.deleted),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _bulkMoveDestinationLabel(EmailStatus status) {
    switch (status) {
      case EmailStatus.received:
        return 'Inbox';
      case EmailStatus.archived:
        return 'Archive';
      case EmailStatus.spam:
        return 'Spam';
      case EmailStatus.deleted:
        return 'Trash';
      case EmailStatus.draft:
        return 'Drafts';
      case EmailStatus.pending:
        return 'Outbox';
      case EmailStatus.sent:
        return 'Sent';
      case EmailStatus.failed:
        return 'Outbox';
    }
  }

  Future<void> _composeEmail() async {
    final result = await Navigator.of(context).push<EmailThread>(
      MaterialPageRoute(builder: (context) => EmailComposePage()),
    );

    if (result != null) {
      await _loadThreads();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _isWideScreen = constraints.maxWidth >= _desktopBreakpoint;
        final theme = Theme.of(context);
        final railLayout = _resolveNavigationRailLayout(
          theme,
          constraints.maxWidth,
        );

        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: theme.colorScheme.surfaceVariant.withValues(
            alpha: 0.25,
          ),
          appBar: _buildAppBar(theme),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _composeEmail,
            tooltip: 'Compose',
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Compose'),
          ),
          drawer: _isWideScreen ? null : _buildFolderDrawer(theme),
          body: _isWideScreen
              ? _buildDesktopLayout(theme, railLayout)
              : _buildMobileLayout(theme),
        );
      },
    );
  }

  Widget _buildDesktopLayout(
    ThemeData theme,
    _NavigationRailLayout railLayout,
  ) {
    return Row(
      children: [
        SizedBox(
          width: railLayout.width,
          child: _buildNavigationRail(theme, railLayout),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 5,
          child: Column(
            children: [
              _buildFolderHeader(theme),
              Expanded(child: _buildThreadList()),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 6,
          child: _selectedThread != null
              ? EmailThreadPage(thread: _selectedThread!, embedded: true)
              : _buildEmptyState(),
        ),
      ],
    );
  }

  Widget _buildMobileLayout(ThemeData theme) {
    return _buildThreadList();
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'labels':
        _showLabelsSheet();
        break;
      case 'settings':
        // TODO: Open email settings
        break;
      case 'accounts':
        // TODO: Open accounts management
        break;
    }
  }

  void _showLabelsSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text(
                'Labels',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.add),
                onPressed: () {
                  Navigator.pop(context);
                  _createLabel();
                },
                tooltip: 'Create Label',
              ),
            ),
            const Divider(height: 1),
            if (_labels.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No labels yet',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else
              ...(_labels
                  .map(
                    (label) => ListTile(
                      leading: const Icon(Icons.label),
                      title: Text(label),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, size: 20),
                        onPressed: () {
                          Navigator.pop(context);
                          _deleteLabel(label);
                        },
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _selectFolder(EmailFolder.label, label: label);
                      },
                    ),
                  )
                  .toList()),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme, {required bool showFolderMenu}) {
    return Material(
      elevation: 1,
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            if (showFolderMenu)
              IconButton(
                icon: const Icon(Icons.folder_open),
                splashRadius: 20,
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                tooltip: 'Folders',
              ),
            Icon(
              Icons.search,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: 'Search subject, sender, or recipient',
                  border: InputBorder.none,
                  isDense: true,
                ),
                textInputAction: TextInputAction.search,
              ),
            ),
            if (_searchQuery.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close),
                splashRadius: 18,
                tooltip: 'Clear search',
                onPressed: () {
                  _searchController.clear();
                  FocusScope.of(context).unfocus();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderDrawer(ThemeData theme) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: const Text(
                'Folders',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: _folderOrder.map((folder) {
                  final stats = _folderStats[folder] ?? _FolderStats.empty;
                  return ListTile(
                    leading: Icon(_getFolderIcon(folder)),
                    title: Text(_folderLabelWithCount(folder)),
                    trailing: _buildFolderStatsTrailing(theme, stats),
                    selected: folder == _currentFolder,
                    onTap: () {
                      Navigator.pop(context);
                      _selectFolder(folder);
                    },
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  _NavigationRailLayout _resolveNavigationRailLayout(
    ThemeData theme,
    double totalWidth,
  ) {
    // Keep labels visible whenever the label text can fit the rail width.
    final textStyle =
        theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600) ??
        const TextStyle(fontWeight: FontWeight.w600);
    final longestLabel = _folderOrder
        .map(_folderLabel)
        .reduce((a, b) => a.length >= b.length ? a : b);

    final painter = TextPainter(
      text: TextSpan(text: longestLabel, style: textStyle),
      maxLines: 1,
      textDirection: Directionality.of(context),
    )..layout();

    // Icon + spacing + padding required by NavigationRail destination.
    final requiredExpandedWidth = (painter.width + 96).clamp(
      _minExpandedRailWidth,
      _maxExpandedRailWidth,
    );

    final maxRailWidthFromViewport = (totalWidth - _minDesktopContentWidth)
        .clamp(_collapsedRailWidth, _maxExpandedRailWidth);

    if (maxRailWidthFromViewport >= requiredExpandedWidth) {
      return _NavigationRailLayout(
        extended: true,
        width: requiredExpandedWidth,
      );
    }

    return const _NavigationRailLayout(
      extended: false,
      width: _collapsedRailWidth,
    );
  }

  Widget _buildNavigationRail(
    ThemeData theme,
    _NavigationRailLayout railLayout,
  ) {
    final selectedIndex = _folderOrder.contains(_currentFolder)
        ? _folderOrder.indexOf(_currentFolder)
        : 0;
    final folderLabelStyle = theme.textTheme.bodyLarge?.copyWith(
      fontWeight: FontWeight.w600,
    );

    return NavigationRail(
      backgroundColor: theme.colorScheme.surface,
      minWidth: _collapsedRailWidth,
      minExtendedWidth: railLayout.width,
      extended: railLayout.extended,
      selectedIndex: selectedIndex,
      destinations: _folderOrder.map((folder) {
        final stats = _folderStats[folder] ?? _FolderStats.empty;
        return NavigationRailDestination(
          icon: _buildNavIcon(theme, folder, false, stats),
          selectedIcon: _buildNavIcon(theme, folder, true, stats),
          label: Text(_folderLabelWithCount(folder), style: folderLabelStyle),
        );
      }).toList(),
      onDestinationSelected: (index) => _selectFolder(_folderOrder[index]),
      trailing: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: IconButton(
          icon: const Icon(Icons.label_outline),
          tooltip: 'Labels',
          onPressed: _showLabelsSheet,
        ),
      ),
    );
  }

  Widget _buildNavIcon(
    ThemeData theme,
    EmailFolder folder,
    bool isSelected,
    _FolderStats stats,
  ) {
    final color = isSelected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(_getFolderIcon(folder), color: color),
        if (stats.unreadMessages > 0)
          Positioned(
            right: -8,
            top: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _shortCount(stats.unreadMessages),
                style: TextStyle(
                  color: theme.colorScheme.onError,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget? _buildFolderStatsTrailing(ThemeData theme, _FolderStats stats) {
    if (stats.unreadMessages <= 0) return null;

    return Text(
      '${_shortCount(stats.unreadMessages)} unread',
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  String _shortCount(int value) {
    if (value < 1000) return '$value';
    final inK = value / 1000;
    if (inK >= 10) return '${inK.floor()}k';
    return '${inK.toStringAsFixed(1)}k';
  }

  Widget _buildFolderHeader(ThemeData theme) {
    final threadCount = _visibleThreads.length;
    final folderStats = _activeFolderStats;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          _buildFilterPill(
            label: _folderLabelWithCount(_currentFolder),
            icon: _getFolderIcon(_currentFolder),
            background: theme.colorScheme.primaryContainer,
            foreground: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 8),
          if (_currentStation != null)
            _buildFilterPill(
              label: _currentStation!,
              icon: Icons.cloud_outlined,
              background: theme.colorScheme.secondaryContainer,
              foreground: theme.colorScheme.onSecondaryContainer,
            ),
          if (_currentLabel != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _buildFilterPill(
                label: _currentLabel!,
                icon: Icons.label_outline,
                background: theme.colorScheme.tertiaryContainer,
                foreground: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          const Spacer(),
          Text(
            '${folderStats.unreadMessages} unread'
            ' · $threadCount thread${threadCount == 1 ? '' : 's'}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterPill({
    required String label,
    required IconData icon,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderChips(ThemeData theme) {
    final chipLabelStyle = theme.textTheme.bodyLarge?.copyWith(
      fontWeight: FontWeight.w600,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      color: theme.colorScheme.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ..._folderOrder.map(
              (folder) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(_folderLabel(folder), style: chipLabelStyle),
                  avatar: Icon(_getFolderIcon(folder), size: 18),
                  selected: _currentFolder == folder,
                  onSelected: (_) => _selectFolder(folder),
                  selectedColor: theme.colorScheme.primaryContainer,
                  labelStyle: TextStyle(
                    color: _currentFolder == folder
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
            ActionChip(
              avatar: const Icon(Icons.label_outline, size: 18),
              label: const Text('Labels'),
              onPressed: _showLabelsSheet,
            ),
          ],
        ),
      ),
    );
  }

  String _folderLabel(EmailFolder folder) {
    switch (folder) {
      case EmailFolder.inbox:
        return 'Inbox';
      case EmailFolder.sent:
        return 'Sent';
      case EmailFolder.outbox:
        return 'Outbox';
      case EmailFolder.drafts:
        return 'Drafts';
      case EmailFolder.archive:
        return 'Archive';
      case EmailFolder.spam:
        return 'Spam';
      case EmailFolder.garbage:
        return 'Trash';
      case EmailFolder.label:
        return 'Label';
    }
  }

  String _folderLabelWithCount(EmailFolder folder) {
    final base = _folderLabel(folder);
    final count = folder == EmailFolder.label
        ? _threads.length
        : (_folderStats[folder]?.totalMessages ?? 0);
    return '$base ($count)';
  }

  Widget _buildThreadList() {
    final threads = _visibleThreads;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                style: TextStyle(color: Colors.red[300]),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _loadThreads,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (threads.isEmpty) {
      return _buildEmptyFolder();
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        itemCount: threads.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final thread = threads[index];
          return _buildSwipeableThreadTile(thread);
        },
      ),
    );
  }

  Widget _buildSwipeableThreadTile(EmailThread thread) {
    if (_isSelectionMode) {
      return _buildThreadTile(thread);
    }

    final theme = Theme.of(context);
    return Dismissible(
      key: Key(thread.threadId),
      background: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.error,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: Row(
          children: const [
            Icon(Icons.delete, color: Colors.white),
            SizedBox(width: 8),
            Text('Delete', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
      secondaryBackground: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.secondary,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: const [
            Text('Archive', style: TextStyle(color: Colors.white)),
            SizedBox(width: 8),
            Icon(Icons.archive, color: Colors.white),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await _emailService.deleteThread(thread);
          if (_selectedThread?.threadId == thread.threadId) {
            setState(() => _selectedThread = null);
          }
          _loadThreads();
          return false;
        } else {
          await _emailService.archiveThread(thread);
          if (_selectedThread?.threadId == thread.threadId) {
            setState(() => _selectedThread = null);
          }
          _loadThreads();
          return false;
        }
      },
      child: _buildThreadTile(thread),
    );
  }

  Widget _buildThreadTile(EmailThread thread) {
    final theme = Theme.of(context);
    final isThreadSelected = _selectedThreadIds.contains(thread.threadId);
    final isSelected = _selectedThread?.threadId == thread.threadId;
    final isUnread = thread.isUnread;
    final hasAttachment = thread.hasAttachments;
    final baseTileColor = isUnread
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
        : theme.colorScheme.surface;
    final tileColor = isThreadSelected
        ? theme.colorScheme.secondaryContainer
        : isSelected
        ? theme.colorScheme.primaryContainer
        : baseTileColor;
    final borderColor = isThreadSelected
        ? theme.colorScheme.secondary
        : isSelected
        ? theme.colorScheme.primary
        : isUnread
        ? theme.colorScheme.primary.withValues(alpha: 0.65)
        : theme.colorScheme.outlineVariant.withValues(alpha: 0.45);
    final borderWidth = isUnread ? 1.6 : 0.8;

    // Determine display name based on folder
    String displayName;
    if (_currentFolder == EmailFolder.sent ||
        _currentFolder == EmailFolder.outbox ||
        _currentFolder == EmailFolder.drafts) {
      displayName = thread.to.isNotEmpty ? thread.to.first : 'No recipient';
    } else {
      displayName = thread.from;
    }

    return Card(
      elevation: isSelected || isThreadSelected ? 3 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor, width: borderWidth),
      ),
      color: tileColor,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (_isSelectionMode) {
            _toggleThreadSelection(thread);
            return;
          }
          _selectThread(thread);
        },
        onLongPress: () {
          if (_isSelectionMode) {
            _toggleThreadSelection(thread);
            return;
          }
          _startThreadSelection(thread);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_isSelectionMode)
                    Padding(
                      padding: const EdgeInsets.only(right: 8, top: 2),
                      child: Checkbox(
                        value: isThreadSelected,
                        onChanged: (_) => _toggleThreadSelection(thread),
                      ),
                    ),
                  if (isUnread)
                    Container(
                      width: 5,
                      height: 54,
                      margin: const EdgeInsets.only(right: 10, top: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  CircleAvatar(
                    backgroundColor: isUnread
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceVariant,
                    child: Text(
                      displayName.isNotEmpty
                          ? displayName[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        color: isUnread
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurface,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    displayName,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: isUnread
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    thread.subject.isNotEmpty
                                        ? thread.subject
                                        : '(No subject)',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          fontWeight: isUnread
                                              ? FontWeight.w700
                                              : FontWeight.w600,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  _formatDate(thread.lastMessageTime),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: isUnread
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.onSurfaceVariant,
                                    fontWeight: isUnread
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                _buildStatusChip(thread, compact: true),
                                if (!_isSelectionMode)
                                  IconButton(
                                    icon: const Icon(
                                      Icons.more_horiz,
                                      size: 18,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 28,
                                      minHeight: 28,
                                    ),
                                    tooltip: 'Actions',
                                    onPressed: () => _showThreadActions(thread),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                thread.preview.isNotEmpty
                    ? thread.preview
                    : 'No message preview',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: isUnread
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                  height: 1.2,
                  fontSize: 13,
                  fontWeight: isUnread ? FontWeight.w500 : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (isUnread)
                    _buildFilterPill(
                      label: 'Unread',
                      icon: Icons.mark_email_unread_outlined,
                      background: theme.colorScheme.primary,
                      foreground: theme.colorScheme.onPrimary,
                    ),
                  if (hasAttachment)
                    _buildFilterPill(
                      label: 'Attachment',
                      icon: Icons.attach_file,
                      background: theme.colorScheme.surfaceVariant,
                      foreground: theme.colorScheme.onSurface,
                    ),
                  if (thread.priority == EmailPriority.high)
                    _buildFilterPill(
                      label: 'High priority',
                      icon: Icons.flag,
                      background: theme.colorScheme.errorContainer,
                      foreground: theme.colorScheme.onErrorContainer,
                    ),
                  ...thread.labels.take(2).map(_buildLabelChip),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(EmailThread thread, {bool compact = false}) {
    final theme = Theme.of(context);
    final color = _statusColor(thread.status, theme);
    final padding = compact
        ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 6);
    final radius = compact ? 8.0 : 10.0;
    final iconSize = compact ? 8.0 : 10.0;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.brightness_1, size: iconSize, color: color),
          const SizedBox(width: 4),
          Text(
            _statusLabel(thread.status),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: compact ? 10 : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLabelChip(String label) {
    final theme = Theme.of(context);
    return InputChip(
      label: Text(label),
      avatar: const Icon(Icons.label, size: 16),
      backgroundColor: theme.colorScheme.surfaceVariant,
      labelStyle: TextStyle(color: theme.colorScheme.onSurface),
      onPressed: () => _selectFolder(EmailFolder.label, label: label),
    );
  }

  Color _statusColor(EmailStatus status, ThemeData theme) {
    switch (status) {
      case EmailStatus.draft:
        return theme.colorScheme.secondary;
      case EmailStatus.pending:
        return Colors.orange;
      case EmailStatus.sent:
        return theme.colorScheme.primary;
      case EmailStatus.received:
        return Colors.teal;
      case EmailStatus.failed:
        return theme.colorScheme.error;
      case EmailStatus.spam:
        return Colors.deepOrange;
      case EmailStatus.deleted:
        return Colors.grey;
      case EmailStatus.archived:
        return Colors.blueGrey;
    }
  }

  String _statusLabel(EmailStatus status) {
    switch (status) {
      case EmailStatus.draft:
        return 'Draft';
      case EmailStatus.pending:
        return 'Outbox';
      case EmailStatus.sent:
        return 'Sent';
      case EmailStatus.received:
        return 'Inbox';
      case EmailStatus.failed:
        return 'Failed';
      case EmailStatus.spam:
        return 'Spam';
      case EmailStatus.deleted:
        return 'Trash';
      case EmailStatus.archived:
        return 'Archived';
    }
  }

  String _formatDate(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute';
  }

  void _showThreadActions(EmailThread thread) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (thread.isDraft)
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Edit Draft'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(this.context)
                      .push<EmailThread>(
                        MaterialPageRoute(
                          builder: (context) =>
                              EmailComposePage(editDraft: thread),
                        ),
                      )
                      .then((_) => _loadThreads());
                },
              ),
            if (!thread.isDraft) ...[
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(this.context)
                      .push<EmailThread>(
                        MaterialPageRoute(
                          builder: (context) =>
                              EmailComposePage(replyTo: thread),
                        ),
                      )
                      .then((_) => _loadThreads());
                },
              ),
              ListTile(
                leading: const Icon(Icons.reply_all),
                title: const Text('Reply All'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(this.context)
                      .push<EmailThread>(
                        MaterialPageRoute(
                          builder: (context) =>
                              EmailComposePage(replyTo: thread, replyAll: true),
                        ),
                      )
                      .then((_) => _loadThreads());
                },
              ),
              ListTile(
                leading: const Icon(Icons.forward),
                title: const Text('Forward'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(this.context)
                      .push<EmailThread>(
                        MaterialPageRoute(
                          builder: (context) =>
                              EmailComposePage(forwardFrom: thread),
                        ),
                      )
                      .then((_) => _loadThreads());
                },
              ),
            ],
            if (thread.status != EmailStatus.archived)
              ListTile(
                leading: const Icon(Icons.archive),
                title: const Text('Archive'),
                onTap: () async {
                  Navigator.pop(context);
                  await _emailService.archiveThread(thread);
                  if (_selectedThread?.threadId == thread.threadId) {
                    setState(() => _selectedThread = null);
                  }
                  _loadThreads();
                  if (mounted) {
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(content: Text('Thread archived')),
                    );
                  }
                },
              ),
            if (thread.status == EmailStatus.archived ||
                thread.status == EmailStatus.deleted ||
                thread.status == EmailStatus.spam)
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('Restore to Inbox'),
                onTap: () async {
                  Navigator.pop(context);
                  await _emailService.restoreThread(thread);
                  if (_selectedThread?.threadId == thread.threadId) {
                    setState(() => _selectedThread = null);
                  }
                  _loadThreads();
                  if (mounted) {
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(content: Text('Thread restored to inbox')),
                    );
                  }
                },
              ),
            if (thread.status == EmailStatus.received && thread.isUnread)
              ListTile(
                leading: const Icon(Icons.mark_email_read_outlined),
                title: const Text('Mark as read'),
                onTap: () async {
                  Navigator.pop(context);
                  await _emailService.markThreadRead(thread);
                  _loadThreads();
                },
              ),
            if (thread.status == EmailStatus.received && !thread.isUnread)
              ListTile(
                leading: const Icon(Icons.mark_email_unread_outlined),
                title: const Text('Mark as unread'),
                onTap: () async {
                  Navigator.pop(context);
                  await _emailService.markThreadUnread(thread);
                  _loadThreads();
                },
              ),
            if (thread.status != EmailStatus.spam)
              ListTile(
                leading: const Icon(Icons.report),
                title: const Text('Report as spam'),
                onTap: () async {
                  Navigator.pop(context);
                  await _emailService.markAsSpam(thread);
                  if (_selectedThread?.threadId == thread.threadId) {
                    setState(() => _selectedThread = null);
                  }
                  _loadThreads();
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete),
              title: const Text('Delete'),
              onTap: () async {
                Navigator.pop(context);
                await _emailService.deleteThread(thread);
                if (_selectedThread?.threadId == thread.threadId) {
                  setState(() => _selectedThread = null);
                }
                _loadThreads();
              },
            ),
            if (thread.status == EmailStatus.deleted)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text(
                  'Delete Permanently',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await _emailService.permanentlyDelete(thread);
                  if (_selectedThread?.threadId == thread.threadId) {
                    setState(() => _selectedThread = null);
                  }
                  _loadThreads();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyFolder() {
    String message;
    IconData icon;

    switch (_currentFolder) {
      case EmailFolder.inbox:
        message = 'No emails in inbox';
        icon = Icons.inbox;
        break;
      case EmailFolder.sent:
        message = 'No sent emails';
        icon = Icons.send;
        break;
      case EmailFolder.outbox:
        message = 'No pending emails';
        icon = Icons.outbox;
        break;
      case EmailFolder.drafts:
        message = 'No drafts';
        icon = Icons.drafts;
        break;
      case EmailFolder.archive:
        message = 'No archived emails';
        icon = Icons.archive;
        break;
      case EmailFolder.spam:
        message = 'No spam';
        icon = Icons.report;
        break;
      case EmailFolder.garbage:
        message = 'Trash is empty';
        icon = Icons.delete;
        break;
      case EmailFolder.label:
        message = 'No emails with this label';
        icon = Icons.label;
        break;
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              message,
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.mail_outline,
            size: 72,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'Select a conversation to read',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Stay on top of multi-station mail with the preview pane.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
