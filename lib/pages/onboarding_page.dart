import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/i18n_service.dart';

/// Onboarding page for Android that introduces Geogram and requests permissions
class OnboardingPage extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingPage({super.key, required this.onComplete});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final I18nService _i18n = I18nService();
  bool _isRequestingPermissions = false;

  Future<void> _requestPermissionsAndContinue() async {
    if (_isRequestingPermissions) return;

    setState(() => _isRequestingPermissions = true);

    try {
      // Request location permission
      if (!kIsWeb) {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (serviceEnabled) {
          LocationPermission permission = await Geolocator.checkPermission();
          if (permission == LocationPermission.denied) {
            permission = await Geolocator.requestPermission();
          }
        }
      }
    } catch (e) {
      // Continue even if permission request fails
    }

    // Complete onboarding regardless of permission result
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),

              // Header with icon
              Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    Icons.satellite_alt,
                    size: 40,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Title
              Center(
                child: Text(
                  _i18n.t('onboarding_welcome_title'),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  _i18n.t('onboarding_welcome_subtitle'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 24),

              // Description
              Text(
                _i18n.t('onboarding_intro_description'),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),

              const SizedBox(height: 32),

              // Permissions section
              Text(
                _i18n.t('onboarding_permissions_title'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),

              // Location permission
              _buildPermissionItem(
                theme,
                Icons.location_on_outlined,
                _i18n.t('onboarding_permission_location'),
                _i18n.t('onboarding_permission_location_short'),
              ),

              // Internet permission
              _buildPermissionItem(
                theme,
                Icons.wifi,
                _i18n.t('onboarding_permission_internet'),
                _i18n.t('onboarding_permission_internet_short'),
              ),

              // Install permission
              _buildPermissionItem(
                theme,
                Icons.system_update,
                _i18n.t('onboarding_permission_install'),
                _i18n.t('onboarding_permission_install_short'),
              ),

              const SizedBox(height: 24),

              // Privacy note
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.privacy_tip_outlined,
                      size: 20,
                      color: theme.colorScheme.secondary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _i18n.t('onboarding_privacy_short'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // Continue button
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _isRequestingPermissions ? null : _requestPermissionsAndContinue,
                  child: _isRequestingPermissions
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_i18n.t('onboarding_continue')),
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionItem(
    ThemeData theme,
    IconData icon,
    String title,
    String description,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 20, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
