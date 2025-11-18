import 'package:flutter/material.dart';
import '../models/notification_settings.dart';
import '../services/notification_service.dart';
import '../services/log_service.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final NotificationService _notificationService = NotificationService();
  NotificationSettings? _settings;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);

    try {
      final settings = _notificationService.getSettings();
      setState(() {
        _settings = settings;
        _isLoading = false;
      });
      LogService().log('Loaded notification settings');
    } catch (e) {
      LogService().log('Error loading notification settings: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateSettings(NotificationSettings newSettings) async {
    setState(() {
      _settings = newSettings;
    });
    await _notificationService.updateSettings(newSettings);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _settings == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Notifications'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
      ),
      body: ListView(
        children: [
          // Master Enable/Disable
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _settings!.enableNotifications
                  ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3)
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _settings!.enableNotifications
                    ? Theme.of(context).colorScheme.primary.withOpacity(0.3)
                    : Theme.of(context).colorScheme.outline.withOpacity(0.2),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _settings!.enableNotifications
                      ? Icons.notifications_active
                      : Icons.notifications_off,
                  color: _settings!.enableNotifications
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  size: 32,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Enable Notifications',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _settings!.enableNotifications
                            ? 'All notifications are enabled'
                            : 'All notifications are disabled',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _settings!.enableNotifications,
                  onChanged: (value) {
                    _updateSettings(_settings!.copyWith(enableNotifications: value));
                  },
                ),
              ],
            ),
          ),

          // Notification Types Section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Icon(
                  Icons.category,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Notification Types',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
          ),

          _buildNotificationTile(
            context: context,
            icon: Icons.message,
            title: 'New Messages',
            subtitle: 'Notify when you receive new messages',
            value: _settings!.notifyNewMessages,
            enabled: _settings!.enableNotifications,
            onChanged: (value) {
              _updateSettings(_settings!.copyWith(notifyNewMessages: value));
            },
          ),

          _buildNotificationTile(
            context: context,
            icon: Icons.bluetooth_connected,
            title: 'Nearby Devices',
            subtitle: 'Notify when devices are detected nearby',
            value: _settings!.notifyNearbyDevices,
            enabled: _settings!.enableNotifications,
            onChanged: (value) {
              _updateSettings(_settings!.copyWith(notifyNearbyDevices: value));
            },
          ),

          _buildNotificationTile(
            context: context,
            icon: Icons.folder_special,
            title: 'Collection Updates',
            subtitle: 'Notify when collections are updated or synced',
            value: _settings!.notifyCollectionUpdates,
            enabled: _settings!.enableNotifications,
            onChanged: (value) {
              _updateSettings(_settings!.copyWith(notifyCollectionUpdates: value));
            },
          ),

          _buildNotificationTile(
            context: context,
            icon: Icons.cloud_outlined,
            title: 'Relay Status',
            subtitle: 'Notify about relay connection changes',
            value: _settings!.notifyRelayStatus,
            enabled: _settings!.enableNotifications,
            onChanged: (value) {
              _updateSettings(_settings!.copyWith(notifyRelayStatus: value));
            },
          ),

          _buildNotificationTile(
            context: context,
            icon: Icons.warning_outlined,
            title: 'System Alerts',
            subtitle: 'Important system notifications and errors',
            value: _settings!.notifySystemAlerts,
            enabled: _settings!.enableNotifications,
            onChanged: (value) {
              _updateSettings(_settings!.copyWith(notifySystemAlerts: value));
            },
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Divider(),
          ),

          // Sound & Vibration Section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Icon(
                  Icons.volume_up,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Alert Settings',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
          ),

          _buildNotificationTile(
            context: context,
            icon: Icons.volume_up,
            title: 'Sound',
            subtitle: 'Play sound for notifications',
            value: _settings!.soundEnabled,
            enabled: _settings!.enableNotifications,
            onChanged: (value) {
              _updateSettings(_settings!.copyWith(soundEnabled: value));
            },
          ),

          _buildNotificationTile(
            context: context,
            icon: Icons.vibration,
            title: 'Vibration',
            subtitle: 'Vibrate for notifications',
            value: _settings!.vibrationEnabled,
            enabled: _settings!.enableNotifications,
            onChanged: (value) {
              _updateSettings(_settings!.copyWith(vibrationEnabled: value));
            },
          ),

          const SizedBox(height: 16),

          // Info Card
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'About Notifications',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Notifications help you stay informed about important events in Geogram. '
                        'Settings are saved automatically and stored locally in your configuration file.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildNotificationTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required bool enabled,
    required ValueChanged<bool> onChanged,
  }) {
    return ListTile(
      leading: Icon(
        icon,
        color: enabled
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.5),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: enabled
              ? Theme.of(context).colorScheme.onSurface
              : Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.5),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: enabled
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.5),
        ),
      ),
      trailing: Switch(
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
      enabled: enabled,
    );
  }
}
