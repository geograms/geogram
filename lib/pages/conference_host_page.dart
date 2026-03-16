/// Conference Host Page — create and manage an audio conference.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/conference_schedule_entry.dart' show MeetingVisibility;
import '../models/group.dart';
import '../services/app_service.dart';
import '../services/conference_service.dart';
import '../services/contact_service.dart';
import '../services/devices_service.dart';
import '../services/groups_service.dart';
import '../services/i18n_service.dart';
import '../services/profile_storage.dart';
import '../tracker/models/tracker_visibility.dart';
import '../util/nostr_crypto.dart';
import 'conference_call_page.dart';
import 'contact_picker_page.dart';

class ConferenceHostPage extends StatefulWidget {
  const ConferenceHostPage({super.key});

  @override
  State<ConferenceHostPage> createState() => _ConferenceHostPageState();
}

class _ConferenceHostPageState extends State<ConferenceHostPage> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _passwordController = TextEditingController();
  final _conferenceService = ConferenceService();
  bool _starting = false;
  bool _scheduling = false;
  String? _error;
  int _maxSpeakers = 6;
  DateTime? _scheduledAt;
  bool _approvalRequired = false;
  late String _meetingKeyword;

  // Visibility state
  MeetingVisibility _visibility = MeetingVisibility.public;
  List<Group> _availableGroups = [];
  final Set<String> _selectedGroups = {};
  // hex pubkey → display label
  final Map<String, String> _allowedContacts = {};

  @override
  void initState() {
    super.initState();
    _meetingKeyword = ConferenceService.randomMeetingKeyword();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  List<AllowedContact> _buildAllowedContacts() {
    final now = DateTime.now().toIso8601String();
    return _allowedContacts.entries.map((e) {
      final npub = NostrCrypto.encodeNpub(e.key);
      return AllowedContact(
        callsign: e.value,
        npub: npub,
        addedAt: now,
      );
    }).toList();
  }

  List<AllowedGroup> _buildAllowedGroups() {
    final now = DateTime.now().toIso8601String();
    return _selectedGroups.map((name) {
      final group = _availableGroups.firstWhere(
        (g) => g.name == name,
        orElse: () => Group(
          name: name, title: name, description: '',
          type: GroupType.association, created: now, updated: now,
        ),
      );
      return AllowedGroup(
        groupId: group.name,
        groupName: group.title,
        addedAt: now,
      );
    }).toList();
  }

  Future<void> _startConference() async {
    final name = _nameController.text.trim();

    setState(() {
      _starting = true;
      _error = null;
    });

    try {
      await _conferenceService.hostConference(
        roomName: name,
        maxSpeakers: _maxSpeakers,
        roomIdOverride: _conferenceService.roomIdFromKeyword(_meetingKeyword),
        description: _descriptionController.text.trim(),
        password: _passwordController.text.trim().isEmpty
            ? null
            : _passwordController.text.trim(),
        approvalRequired: _approvalRequired,
        visibility: _visibility,
        allowedContacts: _buildAllowedContacts(),
        allowedGroups: _buildAllowedGroups(),
      );
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ConferenceCallPage()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _scheduleConference() async {
    final name = _nameController.text.trim();

    setState(() {
      _scheduling = true;
      _error = null;
    });

    try {
      final schedule = await _conferenceService.scheduleConference(
        roomName: name,
        maxSpeakers: _maxSpeakers,
        scheduledAt: _scheduledAt,
        description: _descriptionController.text.trim(),
        roomIdOverride: _conferenceService.roomIdFromKeyword(_meetingKeyword),
        visibility: _visibility,
        allowedContacts: _buildAllowedContacts(),
        allowedGroups: _buildAllowedGroups(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            schedule.scheduledAt == null
                ? 'Meeting scheduled. Start it when you are ready.'
                : 'Meeting scheduled for ${_formatDateTime(schedule.scheduledAt!)}.',
          ),
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scheduling = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pickScheduledAt() async {
    final now = DateTime.now();
    final initial = _scheduledAt ?? now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) {
      return;
    }
    setState(() {
      _scheduledAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _loadGroups() async {
    if (_availableGroups.isNotEmpty) return;
    try {
      final appService = AppService();
      final groupsApp = appService.getAppByType('groups');
      if (groupsApp?.storagePath == null) return;
      final groupsService = GroupsService();
      final profileStorage = appService.profileStorage;
      if (profileStorage != null) {
        groupsService.setStorage(ScopedProfileStorage.fromAbsolutePath(
          profileStorage, groupsApp!.storagePath!));
      } else {
        groupsService.setStorage(
          FilesystemProfileStorage(groupsApp!.storagePath!));
      }
      await groupsService.initializeApp(groupsApp.storagePath!);
      final groups = await groupsService.loadGroups();
      if (mounted) {
        setState(() => _availableGroups = groups);
      }
    } catch (_) {}
  }

  Future<void> _addContacts() async {
    final results = await Navigator.push<List<ContactPickerResult>>(
      context,
      MaterialPageRoute(
        builder: (_) => ContactPickerPage(
          i18n: I18nService(),
          multiSelect: true,
        ),
      ),
    );
    if (results == null || !mounted) return;

    final appService = AppService();
    final contactsApp = appService.getAppByType('contacts');
    if (contactsApp?.storagePath == null) return;
    final contactService = ContactService();
    final profileStorage = appService.profileStorage;
    if (profileStorage != null) {
      contactService.setStorage(ScopedProfileStorage.fromAbsolutePath(
        profileStorage, contactsApp!.storagePath!));
    } else {
      contactService.setStorage(
        FilesystemProfileStorage(contactsApp!.storagePath!));
    }
    await contactService.initializeApp(contactsApp.storagePath!);

    final devicesService = DevicesService();
    for (final r in results) {
      final fullContact = await contactService.loadContact(
        r.contact.callsign, groupPath: r.contact.groupPath);
      if (fullContact?.npub != null && fullContact!.npub!.isNotEmpty) {
        try {
          final hex = NostrCrypto.decodeNpub(fullContact.npub!);
          if (hex.isNotEmpty) {
            final callsign = fullContact.callsign;
            final device = devicesService.getDevice(callsign);
            final nickname = device?.nickname;
            final label = nickname != null && nickname.isNotEmpty
                ? '$nickname ($callsign)'
                : callsign;
            _allowedContacts[hex] = label;
          }
        } catch (_) {}
      }
    }
    if (mounted) setState(() {});
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    final day =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    final time =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return '$day $time';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = _starting || _scheduling;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Host Meeting'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.mic, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Create an audio meeting',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'You are the host (SFU). Speakers connect to you directly. '
              'Listeners receive all speaker audio without a microphone.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Meeting name (optional)',
                hintText: 'Leave empty to use the meeting code',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.label),
              ),
              textCapitalization: TextCapitalization.sentences,
              enabled: !disabled,
            ),
            const SizedBox(height: 12),
            // Meeting code keyword
            Row(
              children: [
                Icon(Icons.tag, size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text('Meeting code: ', style: theme.textTheme.bodyMedium),
                Text(
                  _meetingKeyword,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Pick another keyword',
                  visualDensity: VisualDensity.compact,
                  onPressed: disabled
                      ? null
                      : () => setState(() {
                            _meetingKeyword =
                                ConferenceService.randomMeetingKeyword();
                          }),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'What is this meeting about?',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.notes),
              ),
              textCapitalization: TextCapitalization.sentences,
              maxLines: 2,
              enabled: !disabled,
            ),
            const SizedBox(height: 16),
            // Max speakers slider
            Row(
              children: [
                Icon(Icons.mic, size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  'Max speakers: $_maxSpeakers',
                  style: theme.textTheme.bodyMedium,
                ),
                Expanded(
                  child: Slider(
                    value: _maxSpeakers.toDouble(),
                    min: 2,
                    max: 10,
                    divisions: 8,
                    label: '$_maxSpeakers',
                    onChanged: disabled
                        ? null
                        : (v) => setState(() => _maxSpeakers = v.round()),
                  ),
                ),
              ],
            ),
            Text(
              'Listeners are unlimited',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),

            // ── Visibility ──
            DropdownButtonFormField<MeetingVisibility>(
              value: _visibility,
              decoration: const InputDecoration(
                labelText: 'Visibility',
                prefixIcon: Icon(Icons.visibility_outlined),
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: MeetingVisibility.public,
                  child: Row(children: [
                    Icon(Icons.public, size: 20),
                    SizedBox(width: 8),
                    Text('Public — everyone'),
                  ]),
                ),
                DropdownMenuItem(
                  value: MeetingVisibility.private,
                  child: Row(children: [
                    Icon(Icons.lock, size: 20),
                    SizedBox(width: 8),
                    Text('Private — just me'),
                  ]),
                ),
                DropdownMenuItem(
                  value: MeetingVisibility.restricted,
                  child: Row(children: [
                    Icon(Icons.group, size: 20),
                    SizedBox(width: 8),
                    Text('Restricted — selected people'),
                  ]),
                ),
                DropdownMenuItem(
                  value: MeetingVisibility.unlisted,
                  child: Row(children: [
                    Icon(Icons.link, size: 20),
                    SizedBox(width: 8),
                    Text('Unlisted — link only'),
                  ]),
                ),
              ],
              onChanged: disabled ? null : (value) {
                if (value != null) {
                  setState(() => _visibility = value);
                  if (value == MeetingVisibility.restricted) {
                    _loadGroups();
                  }
                }
              },
            ),

            // Restricted access: groups + contacts
            if (_visibility == MeetingVisibility.restricted) ...[
              const SizedBox(height: 16),
              Text('Allowed groups', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              if (_availableGroups.isEmpty)
                Text(
                  'No groups available',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                ..._availableGroups.map((group) => CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(group.title),
                  subtitle: Text('${group.members.length} members'),
                  value: _selectedGroups.contains(group.name),
                  onChanged: disabled ? null : (checked) {
                    setState(() {
                      if (checked == true) {
                        _selectedGroups.add(group.name);
                      } else {
                        _selectedGroups.remove(group.name);
                      }
                    });
                  },
                )),
              const SizedBox(height: 16),
              Text('Allowed contacts', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: disabled ? null : _addContacts,
                icon: const Icon(Icons.person_add),
                label: const Text('Add contacts'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 40),
                ),
              ),
              if (_allowedContacts.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: _allowedContacts.entries.map((entry) => Chip(
                    label: Text(entry.value),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: disabled ? null : () {
                      setState(() => _allowedContacts.remove(entry.key));
                    },
                  )).toList(),
                ),
              ],
            ],

            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(
                labelText: 'Meeting password (optional)',
                hintText: 'Leave empty for open access',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
              obscureText: true,
              enabled: !disabled,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Require approval to join'),
              subtitle: const Text('Participants wait until you approve them'),
              secondary: const Icon(Icons.front_hand),
              value: _approvalRequired,
              onChanged: disabled
                  ? null
                  : (v) => setState(() => _approvalRequired = v),
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Schedule',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _scheduledAt == null
                          ? 'Leave the start time empty if you want to publish the meeting link now and start it later yourself.'
                          : 'Scheduled start: ${_formatDateTime(_scheduledAt!)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        OutlinedButton.icon(
                          onPressed: disabled
                              ? null
                              : _pickScheduledAt,
                          icon: const Icon(Icons.schedule),
                          label: Text(
                            _scheduledAt == null
                                ? 'Pick start time'
                                : 'Change start time',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: (disabled || _scheduledAt == null)
                              ? null
                              : () => setState(() => _scheduledAt = null),
                          icon: const Icon(Icons.event_busy),
                          label: const Text('Start manually'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
            ],
            OutlinedButton.icon(
              onPressed: disabled ? null : _scheduleConference,
              icon: _scheduling
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.event_available),
              label: Text(
                _scheduling
                    ? 'Scheduling...'
                    : (_scheduledAt == null
                          ? 'Schedule for later'
                          : 'Schedule meeting'),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: disabled ? null : _startConference,
              icon: _starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.call),
              label: Text(_starting ? 'Starting...' : 'Start Meeting'),
            ),
          ],
        ),
      ),
    );
  }
}
