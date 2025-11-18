import 'package:flutter/material.dart';
import '../models/relay.dart';
import '../services/relay_service.dart';
import '../services/log_service.dart';

class RelaysPage extends StatefulWidget {
  const RelaysPage({super.key});

  @override
  State<RelaysPage> createState() => _RelaysPageState();
}

class _RelaysPageState extends State<RelaysPage> {
  final RelayService _relayService = RelayService();
  List<Relay> _allRelays = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRelays();
  }

  Future<void> _loadRelays() async {
    setState(() => _isLoading = true);

    try {
      final relays = _relayService.getAllRelays();
      setState(() {
        _allRelays = relays;
        _isLoading = false;
      });
      LogService().log('Loaded ${relays.length} relays');
    } catch (e) {
      LogService().log('Error loading relays: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addCustomRelay() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => const _AddRelayDialog(),
    );

    if (result != null) {
      try {
        final relay = Relay(
          url: result['url']!,
          name: result['name']!,
          status: 'available',
          location: result['location'],
          latitude: result['latitude'] != null ? double.tryParse(result['latitude']!) : null,
          longitude: result['longitude'] != null ? double.tryParse(result['longitude']!) : null,
        );

        await _relayService.addRelay(relay);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Added relay: ${relay.name}')),
          );
        }

        _loadRelays();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error adding relay: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _setPreferred(Relay relay) async {
    try {
      await _relayService.setPreferred(relay.url);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Set as preferred: ${relay.name}')),
      );
      _loadRelays();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _setBackup(Relay relay) async {
    try {
      await _relayService.setBackup(relay.url);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added to backup: ${relay.name}')),
      );
      _loadRelays();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _setAvailable(Relay relay) async {
    try {
      await _relayService.setAvailable(relay.url);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed from selection: ${relay.name}')),
      );
      _loadRelays();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteRelay(Relay relay) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Relay'),
        content: Text('Are you sure you want to delete "${relay.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _relayService.deleteRelay(relay.url);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted relay: ${relay.name}')),
          );
        }
        _loadRelays();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting relay: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _testConnection(Relay relay) async {
    // Show loading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Testing connection to ${relay.name}...'),
        duration: const Duration(seconds: 1),
      ),
    );

    try {
      await _relayService.testConnection(relay.url);
      _loadRelays();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Connection test successful'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection test failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  List<Relay> get _selectedRelays {
    return _allRelays.where((r) => r.status == 'preferred' || r.status == 'backup').toList()
      ..sort((a, b) {
        // Preferred first
        if (a.status == 'preferred') return -1;
        if (b.status == 'preferred') return 1;
        return 0;
      });
  }

  List<Relay> get _availableRelays {
    return _allRelays.where((r) => r.status == 'available').toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Internet Relays'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadRelays,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Info Card
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Internet Relay Configuration',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '• Select ONE preferred relay (star icon)\n'
                            '• Select multiple backup relays (checkmarks) for redundancy\n'
                            '• Relays may disclose their name and location coordinates',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Selected Relays Section
                  Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Selected Relays',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (_selectedRelays.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            'No relays selected. Select at least one preferred relay.',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ),
                    )
                  else
                    ..._selectedRelays.map((relay) => _RelayCard(
                          relay: relay,
                          onSetPreferred: () => _setPreferred(relay),
                          onSetBackup: () => _setBackup(relay),
                          onSetAvailable: () => _setAvailable(relay),
                          onDelete: () => _deleteRelay(relay),
                          onTest: () => _testConnection(relay),
                        )),

                  const SizedBox(height: 32),

                  // Available Relays Section
                  Row(
                    children: [
                      Icon(
                        Icons.cloud_outlined,
                        color: Theme.of(context).colorScheme.secondary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Available Relays',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (_availableRelays.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            'All relays are selected.',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ),
                    )
                  else
                    ..._availableRelays.map((relay) => _RelayCard(
                          relay: relay,
                          onSetPreferred: () => _setPreferred(relay),
                          onSetBackup: () => _setBackup(relay),
                          onSetAvailable: null, // Already available
                          onDelete: () => _deleteRelay(relay),
                          onTest: () => _testConnection(relay),
                        )),

                  const SizedBox(height: 80),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCustomRelay,
        icon: const Icon(Icons.add),
        label: const Text('Add Relay'),
      ),
    );
  }
}

// Relay Card Widget
class _RelayCard extends StatelessWidget {
  final Relay relay;
  final VoidCallback onSetPreferred;
  final VoidCallback onSetBackup;
  final VoidCallback? onSetAvailable;
  final VoidCallback onDelete;
  final VoidCallback onTest;

  const _RelayCard({
    required this.relay,
    required this.onSetPreferred,
    required this.onSetBackup,
    required this.onSetAvailable,
    required this.onDelete,
    required this.onTest,
  });

  Color _getStatusColor(BuildContext context) {
    switch (relay.status) {
      case 'preferred':
        return Colors.green;
      case 'backup':
        return Colors.orange;
      default:
        return Theme.of(context).colorScheme.outline;
    }
  }

  IconData _getStatusIcon() {
    switch (relay.status) {
      case 'preferred':
        return Icons.star;
      case 'backup':
        return Icons.check_circle;
      default:
        return Icons.cloud_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Row
            Row(
              children: [
                Icon(
                  _getStatusIcon(),
                  color: _getStatusColor(context),
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        relay.name,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        relay.url,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      if (relay.location != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.location_on,
                              size: 14,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              relay.location!,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.primary,
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                            if (relay.latitude != null && relay.longitude != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                '(${relay.latitude!.toStringAsFixed(4)}, ${relay.longitude!.toStringAsFixed(4)})',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                      fontSize: 11,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _getStatusColor(context).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _getStatusColor(context),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    relay.statusDisplay,
                    style: TextStyle(
                      color: _getStatusColor(context),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Connection Status
            if (relay.lastChecked != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Icon(
                      relay.isConnected ? Icons.check_circle : Icons.error,
                      size: 16,
                      color: relay.isConnected ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      relay.connectionStatus,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Spacer(),
                    Text(
                      'Last checked: ${_formatTime(relay.lastChecked!)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),

            // Action Buttons
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (relay.status != 'preferred')
                  OutlinedButton.icon(
                    onPressed: onSetPreferred,
                    icon: const Icon(Icons.star, size: 16),
                    label: const Text('Set Preferred'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                if (relay.status != 'backup')
                  OutlinedButton.icon(
                    onPressed: onSetBackup,
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: const Text('Set as Backup'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                if (onSetAvailable != null)
                  OutlinedButton.icon(
                    onPressed: onSetAvailable,
                    icon: const Icon(Icons.remove_circle_outline, size: 16),
                    label: const Text('Remove'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: onTest,
                  icon: const Icon(Icons.network_check, size: 16),
                  label: const Text('Test'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: onDelete,
                  tooltip: 'Delete',
                  color: Theme.of(context).colorScheme.error,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inSeconds < 60) {
      return '${diff.inSeconds}s ago';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }
}

// Add Relay Dialog
class _AddRelayDialog extends StatefulWidget {
  const _AddRelayDialog();

  @override
  State<_AddRelayDialog> createState() => _AddRelayDialogState();
}

class _AddRelayDialogState extends State<_AddRelayDialog> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final _locationController = TextEditingController();
  final _latitudeController = TextEditingController();
  final _longitudeController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _locationController.dispose();
    _latitudeController.dispose();
    _longitudeController.dispose();
    super.dispose();
  }

  void _add() {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    final location = _locationController.text.trim();
    final latText = _latitudeController.text.trim();
    final lonText = _longitudeController.text.trim();

    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in name and URL')),
      );
      return;
    }

    if (!url.startsWith('wss://') && !url.startsWith('ws://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL must start with wss:// or ws://')),
      );
      return;
    }

    final result = <String, String>{
      'name': name,
      'url': url,
    };

    if (location.isNotEmpty) {
      result['location'] = location;
    }

    if (latText.isNotEmpty && lonText.isNotEmpty) {
      final lat = double.tryParse(latText);
      final lon = double.tryParse(lonText);

      if (lat == null || lon == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid coordinates. Use decimal format.')),
        );
        return;
      }

      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Coordinates out of range')),
        );
        return;
      }

      result['latitude'] = latText;
      result['longitude'] = lonText;
    }

    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Custom Relay'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Relay Name *',
                  hintText: 'e.g., My Custom Relay',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Relay URL *',
                  hintText: 'wss://relay.example.com',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                'Optional Location Information',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _locationController,
                decoration: const InputDecoration(
                  labelText: 'Location',
                  hintText: 'e.g., Tokyo, Japan',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.location_on),
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _latitudeController,
                      decoration: const InputDecoration(
                        labelText: 'Latitude',
                        hintText: '35.6762',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      textInputAction: TextInputAction.next,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _longitudeController,
                      decoration: const InputDecoration(
                        labelText: 'Longitude',
                        hintText: '139.6503',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '* Required fields',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _add,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
