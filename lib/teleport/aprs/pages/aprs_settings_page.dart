/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * APRS bridge settings — placeholder for future configuration.
 */

import 'package:flutter/material.dart';

class AprsSettingsPage extends StatelessWidget {
  final String appPath;

  const AprsSettingsPage({super.key, required this.appPath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('APRS Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Card(
            child: ListTile(
              leading: Icon(Icons.construction),
              title: Text('Configuration options coming soon'),
              subtitle: Text(
                'APRS backend connection settings will be added here.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
