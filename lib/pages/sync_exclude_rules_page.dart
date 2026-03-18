/// Sync Exclude Rules Page.
///
/// Manage file exclusion rules for mirror sync.
library;

import 'package:flutter/material.dart';

import '../models/mirror_config.dart';
import '../services/mirror_config_service.dart';

class SyncExcludeRulesPage extends StatefulWidget {
  const SyncExcludeRulesPage({super.key});

  @override
  State<SyncExcludeRulesPage> createState() => _SyncExcludeRulesPageState();
}

class _SyncExcludeRulesPageState extends State<SyncExcludeRulesPage> {
  final MirrorConfigService _configService = MirrorConfigService.instance;
  List<SyncExcludeRule> _rules = [];

  @override
  void initState() {
    super.initState();
    _rules = List.from(_configService.config?.excludeRules ?? []);
  }

  Future<void> _save() async {
    await _configService.saveExcludeRules(_rules);
  }

  void _addRule() {
    final patternCtl = TextEditingController();
    var mode = ExcludeMode.modifiedOnly;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add exclude rule'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: patternCtl,
                decoration: const InputDecoration(
                  labelText: 'Pattern',
                  hintText: 'e.g. app.js, *.log, cache/*',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              Text('Mode',
                  style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 8),
              RadioListTile<ExcludeMode>(
                title: const Text('Ignore when modified'),
                subtitle: const Text(
                    'New files are still added, updates are skipped'),
                value: ExcludeMode.modifiedOnly,
                groupValue: mode,
                onChanged: (v) => setDialogState(() => mode = v!),
                dense: true,
              ),
              RadioListTile<ExcludeMode>(
                title: const Text('Always ignore'),
                subtitle: const Text(
                    'Completely excluded from sync'),
                value: ExcludeMode.always,
                groupValue: mode,
                onChanged: (v) => setDialogState(() => mode = v!),
                dense: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final pattern = patternCtl.text.trim();
                if (pattern.isEmpty) return;
                setState(() {
                  _rules.add(SyncExcludeRule(pattern: pattern, mode: mode));
                });
                _save();
                Navigator.pop(ctx);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _editRule(int index) {
    final rule = _rules[index];
    final patternCtl = TextEditingController(text: rule.pattern);
    var mode = rule.mode;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Edit exclude rule'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: patternCtl,
                decoration: const InputDecoration(
                  labelText: 'Pattern',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              Text('Mode',
                  style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 8),
              RadioListTile<ExcludeMode>(
                title: const Text('Ignore when modified'),
                subtitle: const Text(
                    'New files are still added, updates are skipped'),
                value: ExcludeMode.modifiedOnly,
                groupValue: mode,
                onChanged: (v) => setDialogState(() => mode = v!),
                dense: true,
              ),
              RadioListTile<ExcludeMode>(
                title: const Text('Always ignore'),
                subtitle: const Text(
                    'Completely excluded from sync'),
                value: ExcludeMode.always,
                groupValue: mode,
                onChanged: (v) => setDialogState(() => mode = v!),
                dense: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final pattern = patternCtl.text.trim();
                if (pattern.isEmpty) return;
                setState(() {
                  _rules[index] =
                      SyncExcludeRule(pattern: pattern, mode: mode);
                });
                _save();
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _deleteRule(int index) {
    setState(() {
      _rules.removeAt(index);
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Excluded Files'),
      ),
      body: _rules.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.filter_alt_off,
                        size: 48,
                        color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    Text(
                      'No exclude rules',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Add rules to skip specific files, paths, or extensions during sync.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _rules.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final rule = _rules[index];
                final isAlways = rule.mode == ExcludeMode.always;
                return ListTile(
                  leading: Icon(
                    isAlways ? Icons.block : Icons.edit_off,
                    color: isAlways ? Colors.red : Colors.orange,
                  ),
                  title: Text(
                    rule.pattern,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  subtitle: Text(
                    isAlways
                        ? 'Always ignored'
                        : 'Ignored when modified',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, size: 20),
                        onPressed: () => _editRule(index),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, size: 20),
                        onPressed: () => _deleteRule(index),
                      ),
                    ],
                  ),
                  onTap: () => _editRule(index),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addRule,
        child: const Icon(Icons.add),
      ),
    );
  }
}
