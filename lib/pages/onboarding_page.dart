import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/ble_permission_service.dart';
import '../services/devices_service.dart';
import '../services/dm_notification_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';

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

    // Request Bluetooth permissions (Android only)
    // This includes BLUETOOTH_SCAN, BLUETOOTH_CONNECT, BLUETOOTH_ADVERTISE, and battery optimization
    try {
      if (!kIsWeb && Platform.isAndroid) {
        LogService().log('Onboarding: Requesting BLE permissions...');
        final granted = await BLEPermissionService().requestAllPermissions();
        LogService().log('Onboarding: BLE permissions granted: $granted');

        // Initialize BLE now that permissions are granted
        LogService().log('Onboarding: Initializing BLE after permissions...');
        await DevicesService().initializeBLEAfterOnboarding();
        LogService().log('Onboarding: BLE initialized');
      }
    } catch (e) {
      LogService().log('Onboarding: Error during BLE setup: $e');
      // Continue even if Bluetooth permission request fails
    }

    // Request notification permission (Android 13+)
    try {
      if (!kIsWeb && Platform.isAndroid) {
        LogService().log('Onboarding: Requesting notification permission...');
        final granted = await DMNotificationService().requestNotificationPermission();
        LogService().log('Onboarding: Notification permission granted: $granted');
      }
    } catch (e) {
      LogService().log('Onboarding: Error requesting notification permission: $e');
      // Continue even if notification permission request fails
    }

    // Complete onboarding regardless of permission result
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Prevent back gesture/button from skipping onboarding
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 48, // Account for padding
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header with icon on left, text on right
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.asset(
                            'assets/geogram_icon_transparent.png',
                            width: 64,
                            height: 64,
                            fit: BoxFit.contain,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _i18n.t('onboarding_welcome_title'),
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _i18n.t('onboarding_welcome_subtitle'),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _i18n.t('onboarding_intro_description'),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

              const SizedBox(height: 24),

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

              // Bluetooth permission
              _buildPermissionItem(
                theme,
                Icons.bluetooth,
                _i18n.t('onboarding_permission_bluetooth'),
                _i18n.t('onboarding_permission_bluetooth_short'),
              ),

              // Battery optimization exemption (Android only)
              if (!kIsWeb && Platform.isAndroid)
                _buildPermissionItem(
                  theme,
                  Icons.battery_saver,
                  'Battery Optimization',
                  'Run in background for device discovery',
                ),

              // Notification permission (Android only)
              if (!kIsWeb && Platform.isAndroid)
                _buildPermissionItem(
                  theme,
                  Icons.notifications_outlined,
                  'Notifications',
                  'Receive alerts for new messages',
                ),

              // Install permission
              _buildPermissionItem(
                theme,
                Icons.system_update,
                _i18n.t('onboarding_permission_install'),
                _i18n.t('onboarding_permission_install_short'),
              ),

              const SizedBox(height: 16),

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

              const SizedBox(height: 20),

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
            );
          },
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
