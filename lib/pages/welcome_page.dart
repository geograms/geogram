/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../services/config_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../util/nostr_key_generator.dart';
import '../util/nostr_crypto.dart';
import '../dialogs/import_nsec_dialog.dart';

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
      final batchSize = message['batchSize'] as int;

      int keysGenerated = 0;
      final matches = <Map<String, String>>[];

      for (int i = 0; i < batchSize; i++) {
        final keys = NostrKeyGenerator.generateKeyPair();
        keysGenerated++;

        // Client callsigns use the default X1 prefix
        final callsign = keys.callsign;

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

/// A vanity match found by the generator
class _VanityMatch {
  final NostrKeys keys;
  final DateTime foundAt;
  bool pinned;

  _VanityMatch({required this.keys, required this.foundAt, this.pinned = false});
}

/// Full-screen welcome page shown after onboarding to display the generated callsign.
/// Allows iterating through callsigns without creating folders until user confirms.
/// Includes a vanity generator to find callsigns matching a pattern.
class WelcomePage extends StatefulWidget {
  final VoidCallback onComplete;

  const WelcomePage({super.key, required this.onComplete});

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();
  final TextEditingController _vanityPatternController = TextEditingController();

  // Preview keys - not persisted until user confirms
  late String _previewNpub;
  late String _previewNsec;
  late String _previewCallsign;

  // Previous keys - for "go back" functionality
  String? _previousNpub;
  String? _previousNsec;
  String? _previousCallsign;

  bool _isGenerating = false;
  bool _isFinalizing = false;

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

  // Lifecycle flag to prevent setState during dispose
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _generatePreviewKeys();
    _vanityPatternController.addListener(_onVanityPatternChanged);
  }

  @override
  void dispose() {
    _disposed = true;
    _stopVanityGenerator();
    _vanityPatternController.removeListener(_onVanityPatternChanged);
    _vanityPatternController.dispose();
    super.dispose();
  }

  void _onVanityPatternChanged() {
    setState(() {});
  }

  /// Generate new keys for preview only (no disk I/O, no folder creation)
  void _generatePreviewKeys() {
    final keys = NostrKeyGenerator.generateKeyPair();
    _previewNpub = keys.npub;
    _previewNsec = keys.nsec;
    _previewCallsign = keys.callsign;
    LogService().log('WelcomePage: Generated preview callsign: $_previewCallsign');
  }

  /// Get the currently displayed callsign (from vanity match or preview)
  String _getDisplayCallsign() {
    if (_selectedVanityMatch != null) {
      return _selectedVanityMatch!.keys.callsign;
    }
    return _previewCallsign;
  }

  /// Get the active keys (from vanity match or preview)
  (String npub, String nsec, String callsign) _getActiveKeys() {
    if (_selectedVanityMatch != null) {
      return (
        _selectedVanityMatch!.keys.npub,
        _selectedVanityMatch!.keys.nsec,
        _selectedVanityMatch!.keys.callsign,
      );
    }
    return (_previewNpub, _previewNsec, _previewCallsign);
  }

  /// Regenerate preview keys (fast, no persistence)
  void _regeneratePreview() {
    if (_isGenerating) return;

    setState(() {
      _isGenerating = true;
      _selectedVanityMatch = null;

      // Save current keys as previous (for go back)
      _previousNpub = _previewNpub;
      _previousNsec = _previewNsec;
      _previousCallsign = _previewCallsign;
    });

    // Small delay for visual feedback
    Future.delayed(const Duration(milliseconds: 100), () {
      _generatePreviewKeys();
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    });
  }

  /// Go back to the previous callsign
  void _goBackToPrevious() {
    if (_previousCallsign == null) return;

    setState(() {
      // Swap current and previous
      final tempNpub = _previewNpub;
      final tempNsec = _previewNsec;
      final tempCallsign = _previewCallsign;

      _previewNpub = _previousNpub!;
      _previewNsec = _previousNsec!;
      _previewCallsign = _previousCallsign!;

      _previousNpub = tempNpub;
      _previousNsec = tempNsec;
      _previousCallsign = tempCallsign;

      _selectedVanityMatch = null;
    });

    LogService().log('WelcomePage: Went back to previous callsign: $_previewCallsign');
  }

  /// Start the vanity generator
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
      'batchSize': 1000,
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

    if (mounted && !_disposed) {
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

  Future<void> _importNsecAndFinalize() async {
    if (_isFinalizing) return;

    if (_vanityRunning) {
      _stopVanityGenerator();
    }

    final result = await showImportNsecDialog(
      context: context,
      i18n: _i18n,
      allowProfileType: false,
      showQrOnMobileOnly: true,
    );
    if (result == null || !mounted) return;

    setState(() => _isFinalizing = true);

    try {
      final profile = _profileService.getProfile();
      profile.npub = result['npub'] as String;
      profile.nsec = result['nsec'] as String;
      profile.callsign = result['callsign'] as String;
      final nickname = result['nickname'] as String?;
      if (nickname != null && nickname.isNotEmpty) {
        profile.nickname = nickname;
      }

      await _profileService.saveProfile(profile);
      await _profileService.finalizeProfileIdentity(profile);

      final firstLaunchComplete = ConfigService().getNestedValue('firstLaunchComplete', false);
      if (firstLaunchComplete != true) {
        ConfigService().set('firstLaunchComplete', true);
      }

      LogService().log('WelcomePage: Imported profile with callsign: ${profile.callsign}');
      widget.onComplete();
    } catch (e) {
      LogService().log('WelcomePage: Error importing profile: $e');
      if (mounted) {
        setState(() => _isFinalizing = false);
      }
    }
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

  /// Finalize the profile with the chosen keys and create folders
  Future<void> _finalizeProfile() async {
    if (_isFinalizing) return;

    setState(() => _isFinalizing = true);

    try {
      // Get the active keys (from vanity match or preview)
      final (npub, nsec, callsign) = _getActiveKeys();

      // Update the profile with the chosen keys
      final profile = _profileService.getProfile();
      profile.npub = npub;
      profile.nsec = nsec;
      profile.callsign = callsign;

      // Save profile and create default collections/folders
      await _profileService.saveProfile(profile);
      await _profileService.finalizeProfileIdentity(profile);

      // Mark first launch as complete (if not already set by onboarding)
      final firstLaunchComplete = ConfigService().getNestedValue('firstLaunchComplete', false);
      if (firstLaunchComplete != true) {
        ConfigService().set('firstLaunchComplete', true);
      }

      LogService().log('WelcomePage: Finalized profile with callsign: $callsign');

      widget.onComplete();
    } catch (e) {
      LogService().log('WelcomePage: Error finalizing profile: $e');
      if (mounted) {
        setState(() => _isFinalizing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 48,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header with icon
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
                                  _i18n.t('welcome_to_geogram'),
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _i18n.t('welcome_message'),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 32),

                      // Callsign section
                      Text(
                        _i18n.t('your_callsign'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Callsign display card
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          children: [
                            Icon(
                              Icons.badge,
                              size: 48,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // Go back button (only visible if there's a previous callsign)
                                if (_previousCallsign != null)
                                  IconButton(
                                    onPressed: _isGenerating || _isFinalizing ? null : _goBackToPrevious,
                                    icon: const Icon(Icons.undo),
                                    tooltip: 'Go back to previous',
                                    color: theme.colorScheme.primary,
                                  )
                                else
                                  const SizedBox(width: 48), // Placeholder for alignment
                                const SizedBox(width: 8),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  child: Text(
                                    _getDisplayCallsign(),
                                    key: ValueKey(_getDisplayCallsign()),
                                    style: theme.textTheme.headlineMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: theme.colorScheme.primary,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const SizedBox(width: 48), // Balance the layout
                              ],
                            ),
                            const SizedBox(height: 16),
                            // Buttons: Generate new + Continue
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: _isGenerating || _isFinalizing ? null : _regeneratePreview,
                                  icon: _isGenerating
                                      ? SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: theme.colorScheme.primary,
                                          ),
                                        )
                                      : const Icon(Icons.refresh, size: 18),
                                  label: Text(_i18n.t('generate_new')),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _isFinalizing ? null : _importNsecAndFinalize,
                                  icon: const Icon(Icons.key, size: 18),
                                  label: Text(_i18n.t('import_nsec')),
                                ),
                                FilledButton.icon(
                                  onPressed: _isFinalizing || _vanityRunning ? null : _finalizeProfile,
                                  icon: _isFinalizing
                                      ? SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: theme.colorScheme.onPrimary,
                                          ),
                                        )
                                      : const Icon(Icons.check, size: 18),
                                  label: Text(_i18n.t('onboarding_continue')),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _i18n.t('welcome_import_existing'),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Vanity generator
                      _buildVanityGenerator(theme),

                      const SizedBox(height: 16),

                      // Hint text
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
                              Icons.info_outline,
                              size: 20,
                              color: theme.colorScheme.secondary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _i18n.t('welcome_customize_hint'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
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
                    backgroundColor: Colors.orange.withValues(alpha: 0.2),
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
              constraints: const BoxConstraints(maxHeight: 200),
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
                                ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5)
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
                                              ? theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7)
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
}
