import 'package:flutter/material.dart';

import '../models/vm_state.dart';
import '../services/vm_controller.dart';

class SetupView extends StatelessWidget {
  final VmController controller;

  const SetupView({super.key, required this.controller});

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
              const Icon(Icons.cloud_download, size: 64, color: Colors.blue),
              const SizedBox(height: 24),
              const Text(
                'Geogram Dev VM Setup',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _stageText(controller.state.downloadStage),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              LinearProgressIndicator(
                value: controller.state.downloadProgress > 0
                    ? controller.state.downloadProgress
                    : null,
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: controller.download.speedText,
                builder: (_, speed, _) {
                  final pct =
                      (controller.state.downloadProgress * 100).toStringAsFixed(1);
                  return Text(
                    speed.isNotEmpty ? '$pct% — $speed' : '$pct%',
                    style: Theme.of(context).textTheme.bodySmall,
                  );
                },
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (controller.state.downloadStage == DownloadStage.idle)
                    FilledButton.icon(
                      onPressed: controller.startDownload,
                      icon: const Icon(Icons.download),
                      label: const Text('Download & Install'),
                    )
                  else
                    OutlinedButton(
                      onPressed: controller.cancelDownload,
                      child: const Text('Cancel'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _stageText(DownloadStage stage) {
    switch (stage) {
      case DownloadStage.idle:
        return 'QEMU and VM image need to be downloaded (~12 GB).';
      case DownloadStage.qemu:
        return 'Downloading QEMU...';
      case DownloadStage.image:
        return 'Downloading VM image...';
      case DownloadStage.extracting:
        return 'Extracting files...';
      case DownloadStage.verifying:
        return 'Verifying checksums...';
    }
  }
}
