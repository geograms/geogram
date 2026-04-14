/*
 * WelcomePage — first-run profile creation for iwi.
 *
 * Ported and slimmed down from geogram/lib/pages/welcome_page.dart.
 * The parent page ships a lot of extras (vanity generator, i18n,
 * station mode, permissions onboarding) that iwi doesn't need yet.
 * What's preserved: the callsign preview card, regenerate, import
 * nsec, and the "Continue" finalization handoff.
 *
 * The page does NOT write anything to disk until the user hits
 * Continue — [ProfileService.generatePreview] / [buildFromNsec] just
 * build an in-memory [IwiProfile], and [saveAndActivate] is only
 * called from [_finalize].
 */

import 'package:flutter/material.dart';

import '../models/iwi_profile.dart';
import '../services/profile_service.dart';

class WelcomePage extends StatefulWidget {
  /// Fired once the profile has been persisted and activated. The
  /// caller (IwiApp) flips the root route from WelcomePage to the
  /// launcher in response.
  final VoidCallback onComplete;

  /// When true, show a Cancel button and allow the user to dismiss
  /// the page without creating a profile. Set this when pushing the
  /// welcome page as a modal on top of an existing profile (e.g. the
  /// "Add profile…" flow from the AppBar switcher). Leave it false
  /// for the first-run boot path where there is no going back.
  final bool canCancel;

  const WelcomePage({
    super.key,
    required this.onComplete,
    this.canCancel = false,
  });

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final _nicknameController = TextEditingController();

  /// In-memory preview profile. Never persisted until [_finalize].
  IwiProfile _preview = ProfileService.instance.generatePreview();

  /// Previous preview — kept so "go back" can undo a regenerate.
  IwiProfile? _previous;

  bool _isFinalizing = false;
  String? _error;

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  void _regenerate() {
    setState(() {
      _previous = _preview;
      _preview = ProfileService.instance.generatePreview(
        nickname: _nicknameController.text.trim(),
      );
      _error = null;
    });
  }

  void _goBack() {
    final prev = _previous;
    if (prev == null) return;
    setState(() {
      _preview = prev;
      _previous = null;
      _error = null;
    });
  }

  Future<void> _importNsec() async {
    final controller = TextEditingController();
    final nsec = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import existing profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste a Nostr private key (nsec1…) below. The matching '
              'callsign and npub will be derived automatically.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'nsec1…',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (nsec == null || nsec.isEmpty) return;
    try {
      final profile = ProfileService.instance.buildFromNsec(
        nsec,
        nickname: _nicknameController.text.trim(),
      );
      setState(() {
        _previous = _preview;
        _preview = profile;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _finalize() async {
    setState(() {
      _isFinalizing = true;
      _error = null;
    });
    try {
      final profile = _preview.copyWith(
        nickname: _nicknameController.text.trim(),
      );
      await ProfileService.instance.saveAndActivate(profile);
      if (!mounted) return;
      widget.onComplete();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isFinalizing = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return PopScope(
      canPop: widget.canCancel,
      child: Scaffold(
        appBar: widget.canCancel
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Cancel',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                title: const Text('Add profile'),
              )
            : null,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 48,
                    maxWidth: 560,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: cs.primaryContainer,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.waving_hand,
                              size: 36,
                              color: cs.primary,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Welcome to geogram',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Create a profile to sign the wapps you '
                                  'build and install. You can generate a '
                                  'fresh Nostr identity or import an '
                                  'existing nsec.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),

                      // Callsign card
                      Text(
                        'Your callsign',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          children: [
                            Icon(Icons.badge, size: 48, color: cs.primary),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_previous != null)
                                  IconButton(
                                    onPressed:
                                        _isFinalizing ? null : _goBack,
                                    icon: const Icon(Icons.undo),
                                    tooltip: 'Revert to previous callsign',
                                    color: cs.primary,
                                  )
                                else
                                  const SizedBox(width: 48),
                                const SizedBox(width: 8),
                                AnimatedSwitcher(
                                  duration:
                                      const Duration(milliseconds: 200),
                                  child: Text(
                                    _preview.callsign,
                                    key: ValueKey(_preview.callsign),
                                    style: theme.textTheme.headlineMedium
                                        ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: cs.primary,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const SizedBox(width: 48),
                              ],
                            ),
                            const SizedBox(height: 12),
                            SelectableText(
                              _preview.npub,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onPrimaryContainer,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: _isFinalizing ? null : _regenerate,
                                  icon: const Icon(Icons.refresh, size: 18),
                                  label: const Text('Generate new'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _isFinalizing ? null : _importNsec,
                                  icon: const Icon(Icons.key, size: 18),
                                  label: const Text('Import nsec'),
                                ),
                                FilledButton.icon(
                                  onPressed: _isFinalizing ? null : _finalize,
                                  icon: _isFinalizing
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.check, size: 18),
                                  label: const Text('Continue'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),
                      Text(
                        'Nickname (optional)',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _nicknameController,
                        decoration: const InputDecoration(
                          hintText: 'Your display name',
                          border: OutlineInputBorder(),
                        ),
                      ),

                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: cs.errorContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.error_outline,
                                  size: 20, color: cs.error),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: TextStyle(color: cs.onErrorContainer),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.secondaryContainer.withAlpha(128),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline,
                                size: 20, color: cs.secondary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Your profile lives at '
                                '~/.local/share/geogram/profiles/<callsign>/. '
                                'Back it up by copying the folder. Your '
                                'nsec is stored inside profiles.json — keep '
                                'it secret.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
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
}
