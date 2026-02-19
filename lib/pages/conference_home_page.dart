/// Conference Home Page — landing page for the standalone conference app.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/conference_service.dart';
import '../services/i18n_service.dart';
import '../util/app_type_theme.dart';
import 'conference_host_page.dart';
import 'conference_join_page.dart';
import 'conference_call_page.dart';

class ConferenceHomePage extends StatefulWidget {
  const ConferenceHomePage({super.key});

  @override
  State<ConferenceHomePage> createState() => _ConferenceHomePageState();
}

class _ConferenceHomePageState extends State<ConferenceHomePage> {
  final _conferenceService = ConferenceService();
  final _i18n = I18nService();
  StreamSubscription? _stateSub;
  ConferenceState _state = ConferenceState.idle;

  @override
  void initState() {
    super.initState();
    _state = _conferenceService.state;
    _stateSub = _conferenceService.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final gradient = getAppTypeGradient('conference', isDark);

    return Scaffold(
      appBar: AppBar(title: Text(_i18n.t('app_type_conference'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Icon
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    gradient: gradient,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.mic, size: 40, color: Colors.white),
                ),
                const SizedBox(height: 32),

                // Host button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ConferenceHostPage(),
                      ),
                    ),
                    icon: const Icon(Icons.add_call),
                    label: const Text(
                      'Host a Conference',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Join button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ConferenceJoinPage(),
                      ),
                    ),
                    icon: const Icon(Icons.call),
                    label: const Text(
                      'Join a Conference',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),

                // Return to call button (shown when active)
                if (_state == ConferenceState.active) ...[
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ConferenceCallPage(),
                        ),
                      ),
                      icon: const Icon(Icons.call_end),
                      label: const Text(
                        'Return to Call',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
