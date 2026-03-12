import 'dart:io';

import 'package:flutter/material.dart';

import '../services/vm_controller.dart';

class ReadyView extends StatelessWidget {
  final VmController controller;

  const ReadyView({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        elevation: 4,
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.computer, size: 64, color: Colors.green),
              const SizedBox(height: 24),
              const Text(
                'Geogram Dev VM',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Ready to launch',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.green,
                    ),
              ),
              const SizedBox(height: 24),
              _SettingsRow(
                label: 'Memory',
                value: controller.memory,
                options: const ['2G', '4G', '8G', '16G'],
                onChanged: (v) => controller.memory = v,
              ),
              const SizedBox(height: 12),
              _SettingsRow(
                label: 'CPUs',
                value: '${controller.cpus}',
                options: List.generate(
                  Platform.numberOfProcessors,
                  (i) => '${i + 1}',
                ),
                onChanged: (v) => controller.cpus = int.parse(v),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: controller.startVm,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start VM',
                      style: TextStyle(fontSize: 18)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  const _SettingsRow({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 80, child: Text(label)),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: options.contains(value) ? value : options.first,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: options
                .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }
}
