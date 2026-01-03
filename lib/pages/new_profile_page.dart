/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:isolate';
import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:flutter/material.dart';
import '../models/profile.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../util/nostr_key_generator.dart';

/// Parameters for vanity key generation in isolate
class _VanityGenParams {
  final String pattern;
  final bool isStation;
  final int batchSize;
  final SendPort sendPort;

  _VanityGenParams({
    required this.pattern,
    required this.isStation,
    required this.batchSize,
    required this.sendPort,
  });
}

/// Result from vanity key generation
class _VanityGenResult {
  final int keysGenerated;
  final List<Map<String, String>> matches;

  _VanityGenResult({required this.keysGenerated, required this.matches});
}

/// Isolate entry point for vanity key generation
void _vanityGeneratorIsolate(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  receivePort.listen((message) {
    if (message == 'stop') {
      receivePort.close();
      return;
    }

    if (message is Map<String, dynamic>) {
      final pattern = message['pattern'] as String;
      final isStation = message['isStation'] as bool;
      final batchSize = message['batchSize'] as int;

      int keysGenerated = 0;
      final matches = <Map<String, String>>[];

      for (int i = 0; i < batchSize; i++) {
        final keys = NostrKeyGenerator.generateKeyPair();
        keysGenerated++;

        final callsign = isStation
            ? NostrKeyGenerator.deriveStationCallsign(keys.npub)
            : keys.callsign;

        if (callsign.contains(pattern)) {
          matches.add({
            'npub': keys.npub,
            'nsec': keys.nsec,
            'callsign': callsign,
          });
        }
      }

      mainSendPort.send({
        'keysGenerated': keysGenerated,
        'matches': matches,
      });
    }
  });
}

/// Full-screen page for creating a new profile
class NewProfilePage extends StatefulWidget {
  const NewProfilePage({super.key});

  @override
  State<NewProfilePage> createState() => _NewProfilePageState();
}

class _VanityMatch {
  final NostrKeys keys;
  final DateTime foundAt;
  bool pinned;

  _VanityMatch({required this.keys, required this.foundAt, this.pinned = false});
}

class _NewProfilePageState extends State<NewProfilePage> {
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();
  final TextEditingController _nicknameController = TextEditingController();
  final TextEditingController _vanityPatternController = TextEditingController();

  ProfileType _selectedType = ProfileType.client;
  bool _useExtension = false;
  bool _extensionAvailable = false;
  bool _checkingExtension = true;
  bool _hasExistingStation = false;

  // Pre-generated keys for callsign preview
  NostrKeys? _generatedKeys;

  // Vanity generator state
  bool _vanityRunning = false;
  int _vanityKeysGenerated = 0;
  Duration _vanityElapsedTime = Duration.zero;
  Timer? _vanityTimer;
  Stopwatch? _vanityStopwatch;
  final List<_VanityMatch> _vanityMatches = [];
  _VanityMatch? _selectedVanityMatch;

  // Isolate for vanity generation
  Isolate? _vanityIsolate;
  ReceivePort? _vanityReceivePort;
  SendPort? _vanitySendPort;

  @override
  void initState() {
    super.initState();
    _checkExtensionAvailability();
    _checkExistingStation();
    _generateNewCallsign();
    _vanityPatternController.addListener(_onVanityPatternChanged);
  }

  @override
  void dispose() {
    _stopVanityGenerator();
    _vanityPatternController.removeListener(_onVanityPatternChanged);
    _nicknameController.dispose();
    _vanityPatternController.dispose();
    super.dispose();
  }

  void _onVanityPatternChanged() {
    setState(() {});
  }

  void _checkExistingStation() {
    final profiles = _profileService.getAllProfiles();
    _hasExistingStation = profiles.any((p) => p.isRelay);
  }

  void _generateNewCallsign() {
    final keys = NostrKeyGenerator.generateKeyPair();
    setState(() {
      _generatedKeys = keys;
      _selectedVanityMatch = null;
    });
  }

  String _getDisplayCallsign() {
    if (_selectedVanityMatch != null) {
      if (_selectedType == ProfileType.station) {
        return NostrKeyGenerator.deriveStationCallsign(_selectedVanityMatch!.keys.npub);
      }
      return _selectedVanityMatch!.keys.callsign;
    }
    if (_generatedKeys == null) return '------';
    if (_selectedType == ProfileType.station) {
      return NostrKeyGenerator.deriveStationCallsign(_generatedKeys!.npub);
    }
    return _generatedKeys!.callsign;
  }

  NostrKeys? _getActiveKeys() {
    return _selectedVanityMatch?.keys ?? _generatedKeys;
  }

  Future<void> _checkExtensionAvailability() async {
    if (kIsWeb) {
      final available = await _profileService.isExtensionAvailable();
      if (mounted) {
        setState(() {
          _extensionAvailable = available;
          _checkingExtension = false;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _extensionAvailable = false;
          _checkingExtension = false;
        });
      }
    }
  }

  Future<void> _startVanityGenerator() async {
    final pattern = _vanityPatternController.text.trim().toUpperCase();
    if (pattern.isEmpty || pattern.length > 4) return;

    setState(() {
      _vanityRunning = true;
      _vanityKeysGenerated = 0;
      _vanityMatches.clear();
      _selectedVanityMatch = null;
    });

    _vanityStopwatch = Stopwatch()..start();
    _vanityTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) {
        setState(() {
          _vanityElapsedTime = _vanityStopwatch!.elapsed;
        });
      }
    });

    // Start isolate for key generation
    _vanityReceivePort = ReceivePort();
    _vanityIsolate = await Isolate.spawn(
      _vanityGeneratorIsolate,
      _vanityReceivePort!.sendPort,
    );

    // Listen for messages from isolate
    _vanityReceivePort!.listen((message) {
      if (message is SendPort) {
        // Got the send port from isolate, start generating
        _vanitySendPort = message;
        _requestNextBatch(pattern);
      } else if (message is Map<String, dynamic>) {
        // Got results from isolate
        final keysGenerated = message['keysGenerated'] as int;
        final matches = message['matches'] as List<dynamic>;

        if (mounted) {
          setState(() {
            _vanityKeysGenerated += keysGenerated;

            for (final match in matches) {
              final m = match as Map<String, dynamic>;
              _vanityMatches.insert(0, _VanityMatch(
                keys: NostrKeys(
                  npub: m['npub'] as String,
                  nsec: m['nsec'] as String,
                  callsign: m['callsign'] as String,
                ),
                foundAt: DateTime.now(),
              ));
              // Keep only 500 most recent matches (but preserve pinned)
              if (_vanityMatches.length > 500) {
                // Find the last non-pinned match to remove
                for (int i = _vanityMatches.length - 1; i >= 0; i--) {
                  if (!_vanityMatches[i].pinned) {
                    _vanityMatches.removeAt(i);
                    break;
                  }
                }
              }
            }
          });
        }

        // Request next batch if still running
        if (_vanityRunning && mounted) {
          _requestNextBatch(pattern);
        }
      }
    });
  }

  void _requestNextBatch(String pattern) {
    _vanitySendPort?.send({
      'pattern': pattern,
      'isStation': _selectedType == ProfileType.station,
      'batchSize': 1000, // Generate 1000 keys per batch
    });
  }

  void _stopVanityGenerator() {
    _vanitySendPort?.send('stop');
    _vanityIsolate?.kill(priority: Isolate.immediate);
    _vanityIsolate = null;
    _vanityReceivePort?.close();
    _vanityReceivePort = null;
    _vanitySendPort = null;

    _vanityRunning = false;
    _vanityTimer?.cancel();
    _vanityTimer = null;
    _vanityStopwatch?.stop();

    // Only call setState if widget is still mounted
    if (mounted) {
      setState(() {});
    }
  }

  void _selectVanityMatch(_VanityMatch match) {
    setState(() {
      _selectedVanityMatch = match;
    });
  }

  void _togglePin(_VanityMatch match) {
    setState(() {
      match.pinned = !match.pinned;
    });
  }

  void _create() {
    final activeKeys = _getActiveKeys();
    if (activeKeys == null && !_useExtension) return;

    Navigator.pop(context, {
      'type': _selectedType,
      'useExtension': _useExtension,
      'nickname': _nicknameController.text.trim().isEmpty
          ? null
          : _nicknameController.text.trim(),
      if (!_useExtension && activeKeys != null) ...{
        'npub': activeKeys.npub,
        'nsec': activeKeys.nsec,
        'callsign': _getDisplayCallsign(),
      },
    });
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    final tenths = (d.inMilliseconds % 1000) ~/ 100;
    if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    }
    return '${seconds}.${tenths}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('create_profile')),
        actions: [
          FilledButton.icon(
            onPressed: (_getActiveKeys() != null || _useExtension) ? _create : null,
            icon: const Icon(Icons.check, size: 18),
            label: Text(_i18n.t('create')),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.onPrimary,
              foregroundColor: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // NIP-07 Extension option (web only)
          if (kIsWeb) ...[
            _buildExtensionOption(theme),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 24),
          ],

          // Profile type selection (only show if not using extension)
          if (!_useExtension) ...[
            Text(
              _i18n.t('profile_type'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildTypeOption(
                    theme: theme,
                    type: ProfileType.client,
                    icon: Icons.person,
                    title: _i18n.t('client'),
                    description: _i18n.t('client_description'),
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildTypeOption(
                    theme: theme,
                    type: ProfileType.station,
                    icon: Icons.cell_tower,
                    title: _i18n.t('station'),
                    description: _i18n.t('station_description'),
                    color: Colors.orange,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),

            // Callsign preview with regenerate button
            Text(
              _i18n.t('your_callsign'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _getDisplayCallsign(),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: _selectedVanityMatch != null
                            ? Colors.green
                            : theme.colorScheme.primary,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: _vanityRunning ? null : _generateNewCallsign,
                    icon: const Icon(Icons.refresh),
                    tooltip: _i18n.t('generate_new'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Nickname field
            Text(
              _i18n.t('nickname_optional'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nicknameController,
              decoration: InputDecoration(
                hintText: _i18n.t('enter_nickname'),
                border: const OutlineInputBorder(),
              ),
              maxLength: 50,
            ),
            const SizedBox(height: 32),

            // Vanity Generator Section
            _buildVanityGenerator(theme),
          ],
        ],
      ),
    );
  }

  Widget _buildVanityGenerator(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                _i18n.t('vanity_generator'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _i18n.t('vanity_generator_description'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),

          // Pattern input and controls
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _vanityPatternController,
                  decoration: InputDecoration(
                    labelText: _i18n.t('pattern'),
                    hintText: 'ABCD',
                    border: const OutlineInputBorder(),
                    counterText: '',
                  ),
                  maxLength: 4,
                  textCapitalization: TextCapitalization.characters,
                  enabled: !_vanityRunning,
                ),
              ),
              const SizedBox(width: 12),
              if (_vanityRunning)
                FilledButton.tonalIcon(
                  onPressed: _stopVanityGenerator,
                  icon: const Icon(Icons.pause),
                  label: Text(_i18n.t('pause')),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.orange.withOpacity(0.2),
                    foregroundColor: Colors.orange,
                  ),
                )
              else
                FilledButton.icon(
                  onPressed: _vanityPatternController.text.trim().isNotEmpty
                      ? _startVanityGenerator
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(_i18n.t('start')),
                ),
            ],
          ),

          // Progress display
          if (_vanityKeysGenerated > 0) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  if (_vanityRunning) ...[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_i18n.t('keys_generated')}: ${_vanityKeysGenerated.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          '${_i18n.t('elapsed_time')}: ${_formatDuration(_vanityElapsedTime)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${_i18n.t('matches')}: ${_vanityMatches.length}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _vanityMatches.isNotEmpty ? Colors.green : null,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Matches list
          if (_vanityMatches.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  _i18n.t('recent_matches'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '(${_vanityMatches.length})',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: Builder(
                builder: (context) {
                  // Sort matches: pinned first, then by time
                  final sortedMatches = List<_VanityMatch>.from(_vanityMatches)
                    ..sort((a, b) {
                      if (a.pinned && !b.pinned) return -1;
                      if (!a.pinned && b.pinned) return 1;
                      return b.foundAt.compareTo(a.foundAt);
                    });
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: sortedMatches.length,
                    itemBuilder: (context, index) {
                      final match = sortedMatches[index];
                      final isSelected = _selectedVanityMatch == match;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        color: isSelected
                            ? theme.colorScheme.primaryContainer
                            : match.pinned
                                ? theme.colorScheme.tertiaryContainer.withOpacity(0.5)
                                : null,
                        child: InkWell(
                          onTap: () => _selectVanityMatch(match),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                if (isSelected)
                                  Icon(
                                    Icons.check_circle,
                                    color: theme.colorScheme.primary,
                                    size: 20,
                                  )
                                else
                                  Icon(
                                    Icons.radio_button_unchecked,
                                    color: theme.colorScheme.outline,
                                    size: 20,
                                  ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        match.keys.callsign,
                                        style: theme.textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          fontFamily: 'monospace',
                                          color: isSelected
                                              ? theme.colorScheme.onPrimaryContainer
                                              : null,
                                        ),
                                      ),
                                      Text(
                                        '${match.keys.npub.substring(0, 20)}...',
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: isSelected
                                              ? theme.colorScheme.onPrimaryContainer.withOpacity(0.7)
                                              : theme.colorScheme.onSurfaceVariant,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => _togglePin(match),
                                  icon: Icon(
                                    match.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                                    size: 20,
                                    color: match.pinned
                                        ? theme.colorScheme.tertiary
                                        : theme.colorScheme.outline,
                                  ),
                                  tooltip: match.pinned ? 'Unpin' : 'Pin',
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildExtensionOption(ThemeData theme) {
    final isSelected = _useExtension;

    return InkWell(
      onTap: _extensionAvailable
          ? () => setState(() {
                _useExtension = !_useExtension;
              })
          : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected
                ? Colors.purple
                : _extensionAvailable
                    ? Colors.grey[300]!
                    : Colors.grey[200]!,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: isSelected
              ? Colors.purple.withOpacity(0.1)
              : _extensionAvailable
                  ? null
                  : Colors.grey[100],
        ),
        child: Row(
          children: [
            Icon(
              Icons.extension,
              size: 40,
              color: _extensionAvailable
                  ? (isSelected ? Colors.purple : Colors.grey[600])
                  : Colors.grey[400],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        _i18n.t('login_with_extension'),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _extensionAvailable
                              ? (isSelected ? Colors.purple : null)
                              : Colors.grey[500],
                        ),
                      ),
                      if (_checkingExtension) ...[
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ] else if (_extensionAvailable) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _i18n.t('available'),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _extensionAvailable
                        ? _i18n.t('extension_login_description')
                        : _i18n.t('extension_not_available'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            if (_extensionAvailable)
              Checkbox(
                value: _useExtension,
                onChanged: (value) {
                  setState(() {
                    _useExtension = value ?? false;
                  });
                },
                activeColor: Colors.purple,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeOption({
    required ThemeData theme,
    required ProfileType type,
    required IconData icon,
    required String title,
    required String description,
    required Color color,
  }) {
    final isSelected = _selectedType == type && !_useExtension;
    final isDisabled = _useExtension || (type == ProfileType.station && _hasExistingStation);

    return InkWell(
      onTap: isDisabled
          ? null
          : () => setState(() => _selectedType = type),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected
                ? color
                : isDisabled
                    ? Colors.grey[200]!
                    : Colors.grey[300]!,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: isSelected
              ? color.withOpacity(0.1)
              : isDisabled
                  ? Colors.grey[100]
                  : null,
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 40,
              color: isDisabled
                  ? Colors.grey[400]
                  : (isSelected ? color : Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: isDisabled ? Colors.grey[400] : (isSelected ? color : null),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              type == ProfileType.station && _hasExistingStation
                  ? _i18n.t('station_already_exists')
                  : description,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: isDisabled ? Colors.grey[400] : Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
