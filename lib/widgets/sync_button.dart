import 'package:flutter/material.dart';

import '../services/mirror_discovery_service.dart';
import '../pages/device_sync_page.dart';

/// Sync button for the AppBar.
///
/// Listens to [MirrorDiscoveryService.mirrors] and shows a sync icon
/// with a badge count when mirror devices are available.
/// Invisible when no mirrors are discovered.
class SyncButton extends StatelessWidget {
  const SyncButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<MirrorDevice>>(
      valueListenable: MirrorDiscoveryService().mirrors,
      builder: (context, mirrors, _) {
        if (mirrors.isEmpty) return const SizedBox.shrink();

        return IconButton(
          icon: Badge(
            label: Text(
              '${mirrors.length}',
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
            backgroundColor: Colors.grey,
            offset: const Offset(6, -6),
            child: const Icon(Icons.sync),
          ),
          tooltip: '${mirrors.length} mirror device(s)',
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DeviceSyncPage()),
            );
          },
        );
      },
    );
  }
}
