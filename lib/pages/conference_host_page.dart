/// Conference Host Page — create and manage an audio conference.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/conference_service.dart';
import 'conference_call_page.dart';

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

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _passwordController.dispose();
    super.dispose();
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
        description: _descriptionController.text.trim(),
        password: _passwordController.text.trim().isEmpty
            ? null
            : _passwordController.text.trim(),
        approvalRequired: _approvalRequired,
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
              enabled: !_starting && !_scheduling,
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
              enabled: !_starting && !_scheduling,
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
                    onChanged: (_starting || _scheduling)
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
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(
                labelText: 'Meeting password (optional)',
                hintText: 'Leave empty for open access',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
              obscureText: true,
              enabled: !_starting && !_scheduling,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Require approval to join'),
              subtitle: const Text('Participants wait until you approve them'),
              secondary: const Icon(Icons.front_hand),
              value: _approvalRequired,
              onChanged: (_starting || _scheduling)
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
                          onPressed: (_starting || _scheduling)
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
                          onPressed: (_starting || _scheduling || _scheduledAt == null)
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
              onPressed: (_starting || _scheduling) ? null : _scheduleConference,
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
              onPressed: (_starting || _scheduling) ? null : _startConference,
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
