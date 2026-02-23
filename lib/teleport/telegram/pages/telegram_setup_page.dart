/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * First-run setup: enter api_id and api_hash from my.telegram.org.
 */

import 'package:flutter/material.dart';

import '../../../services/app_service.dart';
import '../../../services/profile_storage.dart';
import '../telegram_service.dart';
import '../telegram_storage_service.dart';
import 'telegram_auth_page.dart';

class TelegramSetupPage extends StatefulWidget {
  final String appPath;

  const TelegramSetupPage({super.key, required this.appPath});

  @override
  State<TelegramSetupPage> createState() => _TelegramSetupPageState();
}

class _TelegramSetupPageState extends State<TelegramSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _apiIdController = TextEditingController(
    text: '${TelegramService.defaultApiId}',
  );
  final _apiHashController = TextEditingController(
    text: TelegramService.defaultApiHash,
  );
  bool _saving = false;

  @override
  void dispose() {
    _apiIdController.dispose();
    _apiHashController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    try {
      final profileStorage = AppService().profileStorage;
      if (profileStorage == null) {
        throw StateError('No profile storage available');
      }

      final scoped = ScopedProfileStorage.fromAbsolutePath(
        profileStorage,
        widget.appPath,
      );
      final storage = TelegramStorageService.fromScoped(scoped);
      await storage.ensureDirectories();

      await storage.writeConfig({
        'api_id': int.parse(_apiIdController.text.trim()),
        'api_hash': _apiHashController.text.trim(),
        'created': DateTime.now().toUtc().toIso8601String(),
      });

      await storage.registerBridge(enabled: false);

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => TelegramAuthPage(appPath: widget.appPath),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Telegram Setup')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.telegram, size: 48, color: const Color(0xFF0088CC)),
              const SizedBox(height: 16),
              Text(
                'Connect your Telegram account',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Custom API credentials are optional. Default credentials '
                'are pre-filled. Only change these if you have your own '
                'from my.telegram.org.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _apiIdController,
                decoration: const InputDecoration(
                  labelText: 'API ID',
                  hintText: '${TelegramService.defaultApiId}',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  if (int.tryParse(v.trim()) == null) return 'Must be a number';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _apiHashController,
                decoration: const InputDecoration(
                  labelText: 'API Hash',
                  hintText: 'e.g. 0123456789abcdef0123456789abcdef',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  if (v.trim().length < 16) return 'Too short';
                  return null;
                },
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
