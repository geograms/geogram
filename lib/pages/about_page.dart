import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../version.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  void _launchURL(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open $url'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('About Geogram'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // App Icon and Title
            Center(
              child: Column(
                children: [
                  Icon(
                    Icons.radio,
                    size: 80,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Geogram Desktop',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Version $appVersion',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Tagline
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Resilient, Decentralized Communication',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),

            const SizedBox(height: 32),

            // Description
            Text(
              'About',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              'Geogram is a comprehensive offline-first communication ecosystem designed for environments with limited or no internet connectivity.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            Text(
              'It integrates radio communications (APRS/FM), BLE beacons, NOSTR-based messaging, and hybrid online/offline apps to enable proximity-based and radio-aware communication without internet dependency.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),

            const SizedBox(height: 32),

            // Features
            Text(
              'Key Features',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            _buildFeature(
              context,
              Icons.offline_bolt,
              'Offline-First Design',
              'Core functionality works without internet',
            ),
            _buildFeature(
              context,
              Icons.devices,
              'Multi-Platform',
              'Android, Desktop, Web, and embedded devices',
            ),
            _buildFeature(
              context,
              Icons.hub,
              'Mesh Networking',
              'Automatic relay through nearby devices via BLE',
            ),
            _buildFeature(
              context,
              Icons.lock,
              'End-to-End Encryption',
              'Messages secured with NOSTR cryptography',
            ),
            _buildFeature(
              context,
              Icons.location_on,
              'Geographic Routing',
              'Grid-based message delivery to specific locations',
            ),
            _buildFeature(
              context,
              Icons.compare_arrows,
              'Interoperability',
              'Compatible with existing APRS infrastructure',
            ),

            const SizedBox(height: 32),

            // Communication Channels
            Text(
              'Communication Channels',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            _buildChannel(
              context,
              Icons.radio,
              'Radio (APRS/FM)',
              'Long-range voice and data transmission',
            ),
            _buildChannel(
              context,
              Icons.bluetooth,
              'Bluetooth Low Energy',
              'Short-range mesh networking',
            ),
            _buildChannel(
              context,
              Icons.language,
              'NOSTR Protocol',
              'Decentralized, censorship-resistant messaging',
            ),
            _buildChannel(
              context,
              Icons.forward,
              'Relay System',
              'Store-and-forward message delivery',
            ),

            const SizedBox(height: 32),

            // Collections Feature
            Text(
              'Collections',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              'Geogram Desktop includes a powerful Collections feature for sharing files and folders offline:',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 12),
            _buildFeature(
              context,
              Icons.folder,
              'File Sharing',
              'Create collections of files to share with others',
            ),
            _buildFeature(
              context,
              Icons.vpn_key,
              'NOSTR-Based IDs',
              'Collections identified by npub keys',
            ),
            _buildFeature(
              context,
              Icons.security,
              'Access Control',
              'Public, private, or restricted visibility',
            ),
            _buildFeature(
              context,
              Icons.sync,
              'Offline Sync',
              'Share collections via BLE or local network',
            ),

            const SizedBox(height: 32),

            // License
            Text(
              'License',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              'Copyright 2025 Geogram Contributors\n\n'
              'Licensed under the Apache License, Version 2.0',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _launchURL(
                context,
                'https://www.apache.org/licenses/LICENSE-2.0',
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('View License'),
            ),

            const SizedBox(height: 32),

            // Links
            Text(
              'Links',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            _buildLink(
              context,
              Icons.code,
              'GitHub Repository',
              'https://github.com/geograms/central',
            ),
            _buildLink(
              context,
              Icons.bug_report,
              'Report Issues',
              'https://github.com/geograms/central/issues',
            ),
            _buildLink(
              context,
              Icons.description,
              'Documentation',
              'https://github.com/geograms/central/blob/main/docs/README.md',
            ),
            _buildLink(
              context,
              Icons.forum,
              'Discussions',
              'https://github.com/geograms/central/discussions',
            ),

            const SizedBox(height: 32),

            // Attribution
            Center(
              child: Text(
                'Built with ❤️ for resilient,\ndecentralized communication',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildFeature(
    BuildContext context,
    IconData icon,
    String title,
    String description,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 24,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannel(
    BuildContext context,
    IconData icon,
    String title,
    String description,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 32,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLink(
    BuildContext context,
    IconData icon,
    String title,
    String url,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _launchURL(context, url),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                ),
              ),
              Icon(
                Icons.open_in_new,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
