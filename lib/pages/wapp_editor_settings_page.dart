import 'package:flutter/material.dart';

import '../services/wapp_editor_settings.dart';

/// Settings page for the GeoUI code/log editor surfaces. Lets the
/// user override the font family, the editor font size, the log
/// font size and the line height. Persisted via ConfigService through
/// WappEditorSettings; CodeEditorField + LogViewField pick changes up
/// on next rebuild.
class WappEditorSettingsPage extends StatefulWidget {
  const WappEditorSettingsPage({super.key});

  @override
  State<WappEditorSettingsPage> createState() =>
      _WappEditorSettingsPageState();
}

class _WappEditorSettingsPageState extends State<WappEditorSettingsPage> {
  final _settings = WappEditorSettings();

  static const _fontFamilies = <String>[
    'monospace',
    'Courier New',
    'Menlo',
    'Consolas',
    'DejaVu Sans Mono',
    'Liberation Mono',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Editor settings'),
        actions: [
          IconButton(
            tooltip: 'Reset to defaults',
            icon: const Icon(Icons.restore),
            onPressed: () {
              setState(() => _settings.resetToDefaults());
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Editor settings reset')),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSection(
            theme,
            'Preview',
            _buildPreview(theme),
          ),
          const SizedBox(height: 16),
          _buildSection(
            theme,
            'Font family',
            DropdownButtonFormField<String>(
              initialValue: _settings.fontFamily,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final f in _fontFamilies)
                  DropdownMenuItem(value: f, child: Text(f)),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() => _settings.fontFamily = v);
                }
              },
            ),
          ),
          const SizedBox(height: 16),
          _buildSlider(
            theme,
            label: 'Editor font size',
            value: _settings.fontSize,
            min: 10,
            max: 28,
            onChanged: (v) =>
                setState(() => _settings.fontSize = v.roundToDouble()),
          ),
          const SizedBox(height: 16),
          _buildSlider(
            theme,
            label: 'Log font size',
            value: _settings.logFontSize,
            min: 10,
            max: 24,
            onChanged: (v) =>
                setState(() => _settings.logFontSize = v.roundToDouble()),
          ),
          const SizedBox(height: 16),
          _buildSlider(
            theme,
            label: 'Line height',
            value: _settings.lineHeight,
            min: 1.0,
            max: 2.0,
            divisions: 10,
            onChanged: (v) => setState(() => _settings.lineHeight = v),
            valueLabel: _settings.lineHeight.toStringAsFixed(2),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(ThemeData theme, String title, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        child,
      ],
    );
  }

  Widget _buildSlider(
    ThemeData theme, {
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    int? divisions,
    String? valueLabel,
  }) {
    final shown =
        valueLabel ?? value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1);
    return _buildSection(
      theme,
      '$label  ·  $shown',
      Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions ?? (max - min).round(),
        label: shown,
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildPreview(ThemeData theme) {
    final preview = '#include "../hal/geogram_wasm_hal.h"\n'
        '\n'
        'void module_init(void) {\n'
        '    hal_log(1, "[hello] init", 12);\n'
        '}\n';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        preview,
        style: TextStyle(
          fontFamily: _settings.fontFamily,
          fontSize: _settings.fontSize,
          height: _settings.lineHeight,
          color: Colors.white,
        ),
      ),
    );
  }
}
