import 'package:flutter/material.dart';

import '../services/vm_controller.dart';

class ConnectingView extends StatelessWidget {
  final VmController controller;

  const ConnectingView({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        elevation: 4,
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 64,
                height: 64,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 24),
              const Text(
                'Starting VM...',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Booting virtual machine...',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: controller.stopVm,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
