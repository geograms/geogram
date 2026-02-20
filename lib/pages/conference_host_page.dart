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
  final _nameController = TextEditingController(text: 'My Meeting');
  final _conferenceService = ConferenceService();
  bool _starting = false;
  String? _error;
  int _maxSpeakers = 6;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _startConference() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _starting = true;
      _error = null;
    });

    try {
      await _conferenceService.hostConference(
        roomName: name,
        maxSpeakers: _maxSpeakers,
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
                labelText: 'Meeting name',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.label),
              ),
              textCapitalization: TextCapitalization.sentences,
              enabled: !_starting,
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
                    onChanged: _starting
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
            const SizedBox(height: 24),
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
            ],
            FilledButton.icon(
              onPressed: _starting ? null : _startConference,
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
