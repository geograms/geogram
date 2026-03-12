import 'package:flutter/material.dart';

import '../services/vm_controller.dart';

class ErrorView extends StatelessWidget {
  final VmController controller;

  const ErrorView({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    return Center(
      child: Card(
        elevation: 4,
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 24),
              Text(
                state.errorMessage ?? 'An error occurred',
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              if (state.errorDetails != null) ...[
                const SizedBox(height: 16),
                ExpansionTile(
                  title: const Text('Details'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        state.errorDetails!,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: controller.retry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
