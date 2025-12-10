import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/i18n_service.dart';
import '../version.dart';

class AboutPage extends StatelessWidget {
  AboutPage({super.key});

  final I18nService _i18n = I18nService();

  void _launchURL(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('could_not_open_url', params: [url])),
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
        title: Text(_i18n.t('about_geogram')),
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
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.asset(
                      'assets/geogram_icon_transparent.png',
                      width: 100,
                      height: 100,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _i18n.t('connected_together'),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _i18n.t('version_number', params: [appVersion]),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Description
            Text(
              _i18n.t('about'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              _i18n.t('about_description_1'),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('about_description_2'),
              style: Theme.of(context).textTheme.bodyLarge,
            ),

            const SizedBox(height: 32),

            // Features
            Text(
              _i18n.t('key_features'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            _buildFeature(
              context,
              Icons.link,
              _i18n.t('feature_p2p_title'),
              _i18n.t('feature_p2p_desc'),
            ),
            _buildFeature(
              context,
              Icons.lock,
              _i18n.t('feature_encryption_title'),
              _i18n.t('feature_encryption_desc'),
            ),
            _buildFeature(
              context,
              Icons.offline_bolt,
              _i18n.t('feature_offline_title'),
              _i18n.t('feature_offline_desc'),
            ),
            _buildFeature(
              context,
              Icons.devices,
              _i18n.t('feature_multiplatform_title'),
              _i18n.t('feature_multiplatform_desc'),
            ),
            _buildFeature(
              context,
              Icons.hub,
              _i18n.t('feature_routing_title'),
              _i18n.t('feature_routing_desc'),
            ),
            _buildFeature(
              context,
              Icons.verified_user,
              _i18n.t('feature_verified_title'),
              _i18n.t('feature_verified_desc'),
            ),

            const SizedBox(height: 32),

            // Communication Channels
            Text(
              _i18n.t('connection_methods'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            _buildChannel(
              context,
              Icons.wifi,
              _i18n.t('channel_lan_title'),
              _i18n.t('channel_lan_desc'),
            ),
            _buildChannel(
              context,
              Icons.link,
              _i18n.t('channel_webrtc_title'),
              _i18n.t('channel_webrtc_desc'),
            ),
            _buildChannel(
              context,
              Icons.cloud_outlined,
              _i18n.t('channel_station_title'),
              _i18n.t('channel_station_desc'),
            ),
            _buildChannel(
              context,
              Icons.bluetooth,
              _i18n.t('channel_bluetooth_title'),
              _i18n.t('channel_bluetooth_desc'),
            ),

            const SizedBox(height: 32),

            // Collections Feature
            Text(
              _i18n.t('collections'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              _i18n.t('collections_description'),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 12),
            _buildFeature(
              context,
              Icons.folder,
              _i18n.t('collection_sharing_title'),
              _i18n.t('collection_sharing_desc'),
            ),
            _buildFeature(
              context,
              Icons.vpn_key,
              _i18n.t('collection_nostr_title'),
              _i18n.t('collection_nostr_desc'),
            ),
            _buildFeature(
              context,
              Icons.security,
              _i18n.t('collection_access_title'),
              _i18n.t('collection_access_desc'),
            ),
            _buildFeature(
              context,
              Icons.sync,
              _i18n.t('collection_sync_title'),
              _i18n.t('collection_sync_desc'),
            ),

            const SizedBox(height: 32),

            // License
            Text(
              _i18n.t('license'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              _i18n.t('license_text'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _launchURL(
                context,
                'https://www.apache.org/licenses/LICENSE-2.0',
              ),
              icon: const Icon(Icons.open_in_new),
              label: Text(_i18n.t('view_license')),
            ),

            const SizedBox(height: 32),

            // Links
            Text(
              _i18n.t('links'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            _buildLink(
              context,
              Icons.code,
              _i18n.t('github_repository'),
              'https://github.com/geograms/central',
            ),
            _buildLink(
              context,
              Icons.bug_report,
              _i18n.t('report_issues'),
              'https://github.com/geograms/central/issues',
            ),
            _buildLink(
              context,
              Icons.description,
              _i18n.t('documentation'),
              'https://github.com/geograms/central/blob/main/docs/README.md',
            ),
            _buildLink(
              context,
              Icons.forum,
              _i18n.t('discussions'),
              'https://github.com/geograms/central/discussions',
            ),

            const SizedBox(height: 32),

            // Attribution
            Center(
              child: Text(
                _i18n.t('about_footer'),
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
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
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
