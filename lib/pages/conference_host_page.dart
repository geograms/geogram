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
  final _nameController = TextEditingController(text: 'My Conference');
  final _conferenceService = ConferenceService();
  bool _starting = false;
  String? _error;

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
      await _conferenceService.hostConference(roomName: name);
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
        title: const Text('Host Conference'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.mic, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Create an audio conference',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Others can join from the local network or via your station.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Conference name',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.label),
              ),
              textCapitalization: TextCapitalization.sentences,
              enabled: !_starting,
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
              label: Text(_starting ? 'Starting...' : 'Start Conference'),
            ),
          ],
        ),
      ),
    );
  }
}
