import 'package:flutter/material.dart';

import '../services/sibling_discovery_service.dart';
import '../pages/device_sync_page.dart';

/// Sync button for the AppBar.
///
/// Listens to [SiblingDiscoveryService.siblings] and shows a sync icon
/// with a badge count when sibling devices are available.
/// Invisible when no siblings are discovered.
class SyncButton extends StatelessWidget {
  const SyncButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<SiblingDevice>>(
      valueListenable: SiblingDiscoveryService().siblings,
      builder: (context, siblings, _) {
        if (siblings.isEmpty) return const SizedBox.shrink();

        return IconButton(
          icon: Badge(
            label: Text('${siblings.length}'),
            child: const Icon(Icons.sync),
          ),
          tooltip: '${siblings.length} sibling device(s)',
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
