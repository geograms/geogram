/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Email Compose Page - Compose new emails, replies, and forwards
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../util/chat_format.dart';
import '../models/email_account.dart';
import '../models/email_message.dart';
import '../models/email_thread.dart';
import '../services/email_service.dart';
import '../services/profile_service.dart';
import '../services/contact_service.dart';
import '../services/app_service.dart';
import '../services/station_service.dart';

/// Email compose page for new messages, replies, and forwards
class EmailComposePage extends StatefulWidget {
  /// Reply to existing thread
  final EmailThread? replyTo;

  /// Reply to all recipients
  final bool replyAll;

  /// Forward from existing thread
  final EmailThread? forwardFrom;

  /// Edit existing draft
  final EmailThread? editDraft;

  /// Pre-filled recipients
  final List<String>? initialTo;

  /// Pre-filled subject
  final String? initialSubject;

  const EmailComposePage({
    Key? key,
    this.replyTo,
    this.replyAll = false,
    this.forwardFrom,
    this.editDraft,
    this.initialTo,
    this.initialSubject,
  }) : super(key: key);

  @override
  State<EmailComposePage> createState() => _EmailComposePageState();
}

class _EmailComposePageState extends State<EmailComposePage> {
  final EmailService _emailService = EmailService();
  final ProfileService _profileService = ProfileService();
  final ContactService _contactService = ContactService();

  final _formKey = GlobalKey<FormState>();
  final _toController = TextEditingController();
  final _ccController = TextEditingController();
  final _bccController = TextEditingController();
  final _subjectController = TextEditingController();
  final _bodyController = TextEditingController();

  bool _showCc = false;
  bool _showBcc = false;
  bool _isSending = false;
  bool _isDirty = false;

  EmailAccount? _selectedAccount;
  EmailPriority _priority = EmailPriority.normal;

  /// Existing thread being edited (for drafts)
  EmailThread? _existingThread;

  /// Cached list of contacts with emails for autocomplete
  List<Map<String, String?>> _emailContacts = [];

  /// Cached frequent contacts for autocomplete
  List<Map<String, String?>> _frequentContacts = [];

  /// Selected attachments (path -> name)
  final List<_AttachmentInfo> _attachments = [];

  /// Maximum attachment size (10 MB)
  static const int _maxAttachmentSize = 10 * 1024 * 1024; // 10 MB

  /// Maximum total attachments size (10 MB total)
  static const int _maxTotalAttachmentsSize = 10 * 1024 * 1024; // 10 MB

  @override
  void initState() {
    super.initState();
    _initializeForm();
    _loadEmailContacts();
  }

  Future<void> _loadEmailContacts() async {
    // Load frequent contacts first (for quick suggestions)
    final frequent = await _emailService.loadFrequentContacts();
    if (mounted) {
      setState(() {
        _frequentContacts = frequent
            .map(
              (f) => {
                'displayName': f.name.isNotEmpty ? f.name : f.email,
                'email': f.email,
                'callsign': '',
                'profilePicture': null,
                'isFrequent': 'true',
                'count': f.count.toString(),
              },
            )
            .toList();
      });
    }

    // Initialize contact service with contacts collection
    final contactsCollection = AppService().getAppByType('contacts');

    if (contactsCollection != null && contactsCollection.storagePath != null) {
      await _contactService.initializeApp(contactsCollection.storagePath!);
      final contacts = await _contactService.getContactsWithEmails();
      if (mounted) {
        setState(() => _emailContacts = contacts);
      }
    }
  }

  void _initializeForm() {
    // Select default account or create one from preferred station
    var accounts = _emailService.accounts;
    if (accounts.isEmpty) {
      // Auto-create account from preferred station
      final station = StationService().getPreferredStation();
      if (station != null && station.url.isNotEmpty) {
        final profile = _profileService.getProfile();
        // Extract domain from WebSocket URL (wss://p2p.radio -> p2p.radio)
        final stationDomain = station.url
            .replaceFirst(RegExp(r'^wss?://'), '')
            .replaceFirst(RegExp(r'/.*$'), '');

        final account = EmailAccount.fromStation(
          stationDomain: stationDomain,
          nickname: profile.nickname.isNotEmpty
              ? profile.nickname
              : profile.callsign.toLowerCase(),
          callsign: profile.callsign,
          npub: profile.npub,
          stationName: station.name,
        );
        account.isConnected = station.isConnected;
        _emailService.registerAccount(account);
        accounts = _emailService.accounts;
      }
    }

    if (accounts.isNotEmpty) {
      _selectedAccount = accounts.first;
    }

    // Handle reply
    if (widget.replyTo != null) {
      _initializeReply();
    }
    // Handle forward
    else if (widget.forwardFrom != null) {
      _initializeForward();
    }
    // Handle edit draft
    else if (widget.editDraft != null) {
      _initializeDraft();
    }
    // Handle initial values
    else {
      if (widget.initialTo != null && widget.initialTo!.isNotEmpty) {
        _toController.text = widget.initialTo!.join(', ');
      }
      if (widget.initialSubject != null) {
        _subjectController.text = widget.initialSubject!;
      }
    }

    // Listen for changes
    _toController.addListener(_markDirty);
    _ccController.addListener(_markDirty);
    _bccController.addListener(_markDirty);
    _subjectController.addListener(_markDirty);
    _bodyController.addListener(_markDirty);
  }

  void _initializeReply() {
    final thread = widget.replyTo!;
    final myEmail = _selectedAccount?.email ?? '';

    // Set subject with Re: prefix
    final subject = thread.subject;
    if (!subject.toLowerCase().startsWith('re:')) {
      _subjectController.text = 'Re: $subject';
    } else {
      _subjectController.text = subject;
    }

    // Set recipients
    if (widget.replyAll) {
      // Reply to sender and all other recipients
      final recipients = <String>{};

      // Add original sender
      if (thread.from != myEmail) {
        recipients.add(thread.from);
      }

      // Add original To recipients (except self)
      for (final to in thread.to) {
        if (to != myEmail) {
          recipients.add(to);
        }
      }

      _toController.text = recipients.join(', ');

      // CC original CC recipients (except self)
      final ccRecipients = thread.cc.where((cc) => cc != myEmail).toList();
      if (ccRecipients.isNotEmpty) {
        _ccController.text = ccRecipients.join(', ');
        _showCc = true;
      }
    } else {
      // Reply only to sender
      _toController.text = thread.from;
    }

    // Quote original message
    if (thread.messages.isNotEmpty) {
      final lastMessage = thread.messages.last;
      final quotedLines = lastMessage.content
          .split('\n')
          .map((line) => '> $line')
          .join('\n');
      _bodyController.text = '\n\n--- Original Message ---\n$quotedLines';
    }

    // Try to select matching account for this station
    final matchingAccount = _emailService.getAccount(thread.station);
    if (matchingAccount != null) {
      _selectedAccount = matchingAccount;
    }
  }

  void _initializeForward() {
    final thread = widget.forwardFrom!;

    // Set subject with Fwd: prefix
    final subject = thread.subject;
    if (!subject.toLowerCase().startsWith('fwd:')) {
      _subjectController.text = 'Fwd: $subject';
    } else {
      _subjectController.text = subject;
    }

    // Build forwarded content
    final buffer = StringBuffer();
    buffer.writeln('\n\n---------- Forwarded message ----------');
    buffer.writeln('From: ${thread.from}');
    buffer.writeln('To: ${thread.to.join(', ')}');
    buffer.writeln('Subject: ${thread.subject}');
    buffer.writeln('');

    for (final message in thread.messages) {
      buffer.writeln('${message.author} wrote:');
      buffer.writeln(message.content);
      buffer.writeln('');
    }

    _bodyController.text = buffer.toString();
  }

  void _initializeDraft() {
    final thread = widget.editDraft!;
    _existingThread = thread;

    // Load recipients
    final toList = thread.to.where((t) => t != '(draft)').toList();
    _toController.text = toList.join(', ');

    if (thread.cc.isNotEmpty) {
      _ccController.text = thread.cc.join(', ');
      _showCc = true;
    }

    if (thread.bcc.isNotEmpty) {
      _bccController.text = thread.bcc.join(', ');
      _showBcc = true;
    }

    // Load subject
    final subject = thread.subject;
    _subjectController.text = subject != '(No Subject)' ? subject : '';

    // Load priority
    _priority = thread.priority;

    // Load message content (from first/only message in draft)
    if (thread.messages.isNotEmpty) {
      _bodyController.text = thread.messages.first.content;
    }
  }

  void _markDirty() {
    if (!_isDirty) {
      setState(() => _isDirty = true);
    }
  }

  @override
  void dispose() {
    _toController.dispose();
    _ccController.dispose();
    _bccController.dispose();
    _subjectController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    if (!_isDirty) return true;

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unsaved Changes'),
        content: const Text('Save this email as a draft?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('Discard'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Save Draft'),
          ),
        ],
      ),
    );

    if (result == 'save') {
      await _saveDraft();
      return true;
    } else if (result == 'discard') {
      return true;
    }
    return false;
  }

  Future<void> _saveDraft() async {
    if (_toController.text.isEmpty &&
        _subjectController.text.isEmpty &&
        _bodyController.text.isEmpty) {
      return; // Nothing to save
    }

    final profile = _profileService.getProfile();

    try {
      final to = _parseRecipients(_toController.text);
      final cc = _parseRecipients(_ccController.text);
      final bcc = _parseRecipients(_bccController.text);

      // Update existing draft or create new one
      final thread =
          _existingThread?.copyWith(
            station: _selectedAccount?.station ?? _existingThread!.station,
            from: _selectedAccount?.email ?? _existingThread!.from,
            to: to.isEmpty ? ['(draft)'] : to,
            cc: cc,
            bcc: bcc,
            subject: _subjectController.text.isEmpty
                ? '(No Subject)'
                : _subjectController.text,
            priority: _priority,
            messages: [], // Clear messages, will add updated content below
          ) ??
          EmailThread(
            station: _selectedAccount?.station ?? 'local',
            from: _selectedAccount?.email ?? profile.callsign,
            to: to.isEmpty ? ['(draft)'] : to,
            cc: cc,
            bcc: bcc,
            subject: _subjectController.text.isEmpty
                ? '(No Subject)'
                : _subjectController.text,
            created: ChatFormat.formatTimestamp(DateTime.now()),
            status: EmailStatus.draft,
            threadId:
                DateTime.now().millisecondsSinceEpoch.toRadixString(36) +
                (DateTime.now().microsecond * 1000).toRadixString(36),
            priority: _priority,
          );

      // Add message content
      if (_bodyController.text.isNotEmpty) {
        final message = EmailMessage.now(
          author: profile.callsign,
          content: _bodyController.text,
        );
        thread.addMessage(message);
      }

      // Delete old draft if folder path changed (e.g., subject changed)
      if (_existingThread != null && _existingThread!.folderPath != null) {
        final oldFolderName = _existingThread!.generateFolderName();
        final newFolderName = thread.generateFolderName();
        if (oldFolderName != newFolderName) {
          await _emailService.deleteThread(_existingThread!);
        }
      }

      // Save to drafts folder
      await _emailService.saveThread(thread);
      _existingThread = thread;

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Draft saved')));
        _isDirty = false;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save draft: $e')));
      }
    }
  }

  List<String> _parseRecipients(String text) {
    if (text.trim().isEmpty) return [];
    return text
        .split(RegExp(r'[,;]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;

    // Require a station account for sending
    if (_selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No email account selected. Please configure an account first.',
          ),
        ),
      );
      return;
    }

    setState(() => _isSending = true);

    try {
      final to = _parseRecipients(_toController.text);
      final cc = _parseRecipients(_ccController.text);
      final bcc = _parseRecipients(_bccController.text);

      // If replying, add message to existing thread
      if (widget.replyTo != null) {
        final replyThread = widget.replyTo!;

        // Move to outbox first so attachments are written in the final folder.
        await _emailService.markAsPending(replyThread);

        final attachmentMetadata = await _copyAttachmentsToThread(replyThread);
        await _emailService.createSignedMessage(
          thread: replyThread,
          content: _bodyController.text,
          metadata: attachmentMetadata,
        );

        // Track recipients for frequent contacts
        final allRecipients = [...to, ...cc, ...bcc];
        await _emailService.trackRecipients(allRecipients);

        // Try to send via WebSocket - delivery confirmation comes via DSN
        await _emailService.sendViaWebSocket(replyThread);

        if (mounted) {
          Navigator.pop(context, replyThread);
        }
        return;
      }

      // Create new thread directly as pending (outbox)
      final thread = EmailThread(
        station: _selectedAccount!.station,
        from: _selectedAccount!.email,
        to: to,
        cc: cc,
        bcc: bcc,
        subject: _subjectController.text.isEmpty
            ? '(No Subject)'
            : _subjectController.text,
        created: ChatFormat.formatTimestamp(DateTime.now()),
        status: EmailStatus.pending, // Directly to outbox
        threadId:
            DateTime.now().millisecondsSinceEpoch.toRadixString(36) +
            (DateTime.now().microsecond * 1000).toRadixString(36),
        priority: _priority,
      );

      // Save thread first to create the folder
      await _emailService.saveThread(thread);

      // Copy attachments to thread folder and build metadata
      final attachmentMetadata = await _copyAttachmentsToThread(thread);

      // Add signed message with attachment metadata
      await _emailService.createSignedMessage(
        thread: thread,
        content: _bodyController.text,
        metadata: attachmentMetadata,
      );

      // Save again with the message
      await _emailService.saveThread(thread);

      // Track recipients for frequent contacts
      final allRecipients = [...to, ...cc, ...bcc];
      await _emailService.trackRecipients(allRecipients);

      // Try to send immediately via WebSocket
      // Note: This only queues the email for sending - actual delivery
      // confirmation comes via DSN (Delivery Status Notification)
      await _emailService.sendViaWebSocket(thread);

      // Don't show any message here - wait for DSN confirmation
      // The email stays in outbox until the station confirms delivery
      if (mounted) {
        Navigator.pop(context, thread);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to send: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) {
          final shouldPop = await _onWillPop();
          if (shouldPop && mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (await _onWillPop()) {
                if (mounted) Navigator.pop(context);
              }
            },
          ),
          title: Text(_getTitle()),
          actions: [
            // Attachment button
            IconButton(
              icon: const Icon(Icons.attach_file),
              onPressed: _attachFile,
              tooltip: 'Attach file',
            ),
            // More options
            PopupMenuButton<String>(
              onSelected: _handleMenuAction,
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'priority',
                  child: ListTile(
                    leading: const Icon(Icons.flag),
                    title: const Text('Priority'),
                    trailing: Text(_priority.name),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'save_draft',
                  child: ListTile(
                    leading: Icon(Icons.drafts),
                    title: Text('Save Draft'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'discard',
                  child: ListTile(
                    leading: Icon(Icons.delete, color: Colors.red),
                    title: Text('Discard', style: TextStyle(color: Colors.red)),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            // Send button
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: FilledButton.icon(
                onPressed: _isSending ? null : _send,
                icon: _isSending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, size: 18),
                label: const Text('Send'),
              ),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                _buildAccountSelector(),
                const SizedBox(height: 12),
                _buildRecipientsCard(),
                const SizedBox(height: 12),
                _buildSubjectCard(),
                const SizedBox(height: 12),
                _buildBodyCard(),
                if (_attachments.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildAttachmentsList(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getTitle() {
    if (widget.replyTo != null) {
      return widget.replyAll ? 'Reply All' : 'Reply';
    }
    if (widget.forwardFrom != null) {
      return 'Forward';
    }
    return 'Compose';
  }

  Widget _buildAccountSelector() {
    final accounts = _emailService.accounts;
    final hasMultipleAccounts = accounts.length > 1;
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'From',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            accounts.isEmpty
                ? Text(
                    'No account configured',
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontStyle: FontStyle.italic,
                    ),
                  )
                : hasMultipleAccounts
                ? DropdownButtonFormField<EmailAccount>(
                    value: _selectedAccount,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: accounts.map((account) {
                      return DropdownMenuItem(
                        value: account,
                        child: Row(
                          children: [
                            Icon(
                              account.isConnected
                                  ? Icons.cloud_done
                                  : Icons.cloud_off,
                              size: 16,
                              color: account.isConnected
                                  ? Colors.green
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(account.email)),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (account) {
                      setState(() => _selectedAccount = account);
                    },
                  )
                : Row(
                    children: [
                      Icon(
                        _selectedAccount?.isConnected == true
                            ? Icons.cloud_done
                            : Icons.cloud_off,
                        size: 16,
                        color: _selectedAccount?.isConnected == true
                            ? Colors.green
                            : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _selectedAccount?.email ?? 'No account',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildMetaChip(
                  icon: _selectedAccount?.isConnected == true
                      ? Icons.cloud_done
                      : Icons.cloud_off,
                  label: _selectedAccount?.isConnected == true
                      ? 'Connected'
                      : 'Offline',
                  color: _selectedAccount?.isConnected == true
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.error,
                ),
                _buildMetaChip(
                  icon: Icons.flag,
                  label: 'Priority: ${_priority.name}',
                  color: theme.colorScheme.primary,
                  onTap: _showPriorityDialog,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaChip({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecipientsCard() {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recipients',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            _buildRecipientField(
              controller: _toController,
              label: 'To',
              required: true,
            ),
            if (_showCc)
              _buildRecipientField(
                controller: _ccController,
                label: 'Cc',
                onRemove: () => setState(() {
                  _ccController.clear();
                  _showCc = false;
                }),
              ),
            if (_showBcc)
              _buildRecipientField(
                controller: _bccController,
                label: 'Bcc',
                onRemove: () => setState(() {
                  _bccController.clear();
                  _showBcc = false;
                }),
              ),
            if (!_showCc || !_showBcc)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    if (!_showCc)
                      TextButton.icon(
                        onPressed: () => setState(() => _showCc = true),
                        icon: const Icon(Icons.person_add_alt, size: 18),
                        label: const Text('Add Cc'),
                      ),
                    if (!_showBcc)
                      TextButton.icon(
                        onPressed: () => setState(() => _showBcc = true),
                        icon: const Icon(Icons.visibility_off, size: 18),
                        label: const Text('Add Bcc'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubjectCard() {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: TextFormField(
          controller: _subjectController,
          decoration: const InputDecoration(
            labelText: 'Subject',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.next,
          style: theme.textTheme.titleMedium,
        ),
      ),
    );
  }

  Widget _buildBodyCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: TextFormField(
          controller: _bodyController,
          decoration: const InputDecoration(
            hintText: 'Compose email...',
            border: OutlineInputBorder(),
          ),
          maxLines: null,
          minLines: 12,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
        ),
      ),
    );
  }

  Widget _buildRecipientField({
    required TextEditingController controller,
    required String label,
    bool required = false,
    VoidCallback? onRemove,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildAutocompleteField(
              controller: controller,
              required: required,
            ),
          ),
          if (onRemove != null)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: onRemove,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
        ],
      ),
    );
  }

  Widget _buildAutocompleteField({
    required TextEditingController controller,
    bool required = false,
  }) {
    TextEditingController? fieldController;

    void syncBackToController() {
      final source = fieldController;
      if (source == null) return;
      if (controller.value == source.value) return;
      controller.value = source.value;
    }

    return Autocomplete<Map<String, String?>>(
      initialValue: TextEditingValue(text: controller.text),
      optionsBuilder: (TextEditingValue textEditingValue) {
        final text = textEditingValue.text;

        // Get the last recipient being typed (after comma or semicolon)
        final parts = text.split(RegExp(r'[,;]'));
        final currentInput = parts.last.trim().toLowerCase();

        // If empty or just starting, show top frequent contacts
        if (currentInput.isEmpty) {
          return _frequentContacts.take(5);
        }

        // Merge frequent contacts and regular contacts, frequent first
        final results = <Map<String, String?>>[];
        final seenEmails = <String>{};

        // First add matching frequent contacts
        for (final contact in _frequentContacts) {
          final displayName = contact['displayName']?.toLowerCase() ?? '';
          final email = contact['email']?.toLowerCase() ?? '';
          if (displayName.contains(currentInput) ||
              email.contains(currentInput)) {
            if (!seenEmails.contains(email)) {
              results.add(contact);
              seenEmails.add(email);
            }
          }
        }

        // Then add matching regular contacts
        for (final contact in _emailContacts) {
          final displayName = contact['displayName']?.toLowerCase() ?? '';
          final email = contact['email']?.toLowerCase() ?? '';
          final callsign = contact['callsign']?.toLowerCase() ?? '';
          if (displayName.contains(currentInput) ||
              email.contains(currentInput) ||
              callsign.contains(currentInput)) {
            if (!seenEmails.contains(email)) {
              results.add(contact);
              seenEmails.add(email);
            }
          }
        }

        return results.take(8);
      },
      displayStringForOption: (option) {
        // Return just the email for the text field
        return option['email'] ?? '';
      },
      onSelected: (Map<String, String?> selection) {
        final activeController = fieldController ?? controller;

        // Append the selected email to existing recipients
        final text = activeController.text;
        final parts = text.split(RegExp(r'[,;]'));

        // Remove the partial text and add the full email
        parts.removeLast();
        parts.add(selection['email'] ?? '');

        // Join with comma and add trailing comma for next entry
        final updated = parts.where((p) => p.trim().isNotEmpty).join(', ');
        final nextText = updated.isNotEmpty ? '$updated, ' : '';
        activeController.value = TextEditingValue(
          text: nextText,
          selection: TextSelection.fromPosition(
            TextPosition(offset: nextText.length),
          ),
        );
        syncBackToController();
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300, maxWidth: 350),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: Theme.of(
                        context,
                      ).primaryColor.withValues(alpha: 0.1),
                      backgroundImage:
                          (!kIsWeb && option['profilePicture'] != null)
                          ? FileImage(File(option['profilePicture']!))
                          : null,
                      child: (kIsWeb || option['profilePicture'] == null)
                          ? Text(
                              (option['displayName'] ?? '?')[0].toUpperCase(),
                              style: TextStyle(
                                color: Theme.of(context).primaryColor,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                    ),
                    title: Text(
                      option['displayName'] ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      option['email'] ?? '',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    dense: true,
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
      fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
        fieldController = textController;

        return TextFormField(
          controller: textController,
          focusNode: focusNode,
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: 'Enter recipients',
            isDense: true,
          ),
          validator: required
              ? (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'At least one recipient is required';
                  }
                  return null;
                }
              : null,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          onChanged: (_) => syncBackToController(),
          onFieldSubmitted: (_) => onFieldSubmitted(),
        );
      },
    );
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'priority':
        _showPriorityDialog();
        break;
      case 'save_draft':
        _saveDraft();
        break;
      case 'discard':
        _discardDraft();
        break;
    }
  }

  Future<void> _showPriorityDialog() async {
    final result = await showDialog<EmailPriority>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set Priority'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: EmailPriority.values.map((p) {
            return RadioListTile<EmailPriority>(
              title: Text(p.name[0].toUpperCase() + p.name.substring(1)),
              value: p,
              groupValue: _priority,
              onChanged: (value) => Navigator.pop(context, value),
            );
          }).toList(),
        ),
      ),
    );

    if (result != null) {
      setState(() => _priority = result);
    }
  }

  void _discardDraft() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard Draft?'),
        content: const Text('This email will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(this.context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
  }

  Future<void> _attachFile() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Attachments not supported on web')),
      );
      return;
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );

      if (result != null) {
        int currentTotalSize = _attachments.fold(0, (sum, a) => sum + a.size);

        for (final file in result.files) {
          if (file.path == null) continue;

          final fileObj = File(file.path!);
          final fileSize = await fileObj.length();

          // Check individual file size (10MB limit)
          if (fileSize > _maxAttachmentSize) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    '${file.name} is too large (max 10 MB per file)',
                  ),
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
              );
            }
            continue;
          }

          // Check total size (10MB limit)
          if (currentTotalSize + fileSize > _maxTotalAttachmentsSize) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text(
                    'Total attachments size exceeded (max 10 MB)',
                  ),
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
              );
            }
            break;
          }

          // Check for duplicate
          if (_attachments.any((a) => a.path == file.path)) {
            continue;
          }

          // Determine if it's an image
          final extension = file.extension?.toLowerCase() ?? '';
          final isImage = [
            'jpg',
            'jpeg',
            'png',
            'gif',
            'webp',
            'bmp',
          ].contains(extension);

          setState(() {
            _attachments.add(
              _AttachmentInfo(
                path: file.path!,
                name: file.name,
                size: fileSize,
                isImage: isImage,
              ),
            );
            _isDirty = true;
          });
          currentTotalSize += fileSize;
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error picking file: $e')));
      }
    }
  }

  void _removeAttachment(int index) {
    setState(() {
      _attachments.removeAt(index);
      _isDirty = true;
    });
  }

  Widget _buildAttachmentsList() {
    if (_attachments.isEmpty) return const SizedBox.shrink();

    final totalSize = _attachments.fold(0, (sum, a) => sum + a.size);
    final totalSizeMB = (totalSize / (1024 * 1024)).toStringAsFixed(1);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                const Icon(Icons.attach_file, size: 18),
                const SizedBox(width: 6),
                Text(
                  '${_attachments.length} attachment${_attachments.length > 1 ? 's' : ''} ($totalSizeMB MB)',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _attachments.asMap().entries.map((entry) {
                final index = entry.key;
                final attachment = entry.value;
                return Chip(
                  avatar: Icon(
                    attachment.isImage ? Icons.image : Icons.insert_drive_file,
                    size: 16,
                  ),
                  label: Text(
                    attachment.name.length > 20
                        ? '${attachment.name.substring(0, 17)}...'
                        : attachment.name,
                    style: const TextStyle(fontSize: 12),
                  ),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () => _removeAttachment(index),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// Generate SHA1 hash for attachment filename
  String _generateAttachmentFilename(String originalName, List<int> bytes) {
    final hash = sha1.convert(bytes).toString().substring(0, 40);
    return '${hash}_$originalName';
  }

  /// Copy attachments to thread folder and return metadata
  Future<Map<String, String>?> _copyAttachmentsToThread(
    EmailThread thread,
  ) async {
    if (_attachments.isEmpty || kIsWeb) return null;

    final metadata = <String, String>{};
    final attachmentNames = <String>[];

    for (final attachment in _attachments) {
      try {
        final sourceFile = File(attachment.path);
        final bytes = await sourceFile.readAsBytes();
        final hashedName = _generateAttachmentFilename(attachment.name, bytes);

        // Write attachment via ProfileStorage (works for both filesystem and encrypted)
        await _emailService.writeAttachment(
          thread,
          hashedName,
          Uint8List.fromList(bytes),
        );

        attachmentNames.add(hashedName);
      } catch (e) {
        print('Error copying attachment ${attachment.name}: $e');
      }
    }

    if (attachmentNames.isNotEmpty) {
      // For single file, use 'file' or 'image' key
      // For multiple files, use comma-separated list
      if (attachmentNames.length == 1) {
        final name = attachmentNames.first;
        final ext = p.extension(name).toLowerCase();
        final isImage = [
          '.jpg',
          '.jpeg',
          '.png',
          '.gif',
          '.webp',
          '.bmp',
        ].contains(ext);
        metadata[isImage ? 'image' : 'file'] = name;
      } else {
        // Multiple files - comma separated
        metadata['files'] = attachmentNames.join(',');
      }
    }

    return metadata.isEmpty ? null : metadata;
  }
}

/// Helper class to store attachment info
class _AttachmentInfo {
  final String path;
  final String name;
  final int size;
  final bool isImage;

  _AttachmentInfo({
    required this.path,
    required this.name,
    required this.size,
    required this.isImage,
  });

  String get sizeDisplay {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
