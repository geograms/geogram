/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Signal authentication page — QR code device linking only.
 * No tabs needed (unlike Telegram which has Phone + QR).
 * Listens to SignalService auth state and auto-transitions to chat list on `ready`.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/app_service.dart';
import '../../../services/profile_service.dart';
import '../models/signal_auth_state.dart';
import '../signal_service.dart';
import '../widgets/signal_qr_link_widget.dart';
import 'signal_chat_list_page.dart';

class SignalAuthPage extends StatefulWidget {
  final String appPath;

  const SignalAuthPage({super.key, required this.appPath});

  @override
  State<SignalAuthPage> createState() => _SignalAuthPageState();
}

class _SignalAuthPageState extends State<SignalAuthPage> {
  StreamSubscription<SignalEvent>? _eventSub;
  SignalAuthStateData _authState = const SignalAuthStateData(
    state: SignalAuthState.uninitialized,
  );
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initService();
  }

  Future<void> _initService() async {
    setState(() => _connecting = true);

    try {
      final service = SignalService();
      final profileStorage = AppService().profileStorage;
      if (profileStorage == null) {
        throw StateError('No profile storage');
      }

      service.setStorage(profileStorage);

      // Derive the teleport relative path from appPath
      final basePath = profileStorage.basePath;
      String teleportPath;
      if (widget.appPath.startsWith(basePath)) {
        teleportPath = widget.appPath.substring(basePath.length);
        while (teleportPath.startsWith('/') || teleportPath.startsWith('\\')) {
          teleportPath = teleportPath.substring(1);
        }
      } else {
        teleportPath = widget.appPath.split('/').last;
      }

      final callsign = ProfileService().getProfile().callsign;
      await service.initialize(teleportPath, callsign);

      _eventSub = service.events.listen((event) {
        if (event.type == SignalEventType.authStateChanged) {
          final data = event.data as SignalAuthStateData;
          setState(() => _authState = data);

          if (data.state == SignalAuthState.ready && mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) =>
                    SignalChatListPage(appPath: widget.appPath),
              ),
            );
          }
        }
      });

      // If already connected, reset stale state and request a fresh QR
      if (service.isRunning) {
        service.authService?.resetState();
        await service.authService?.requestLinkDevice();
        return;
      }

      await service.connect();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authService = SignalService().authService;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Signal Login'),
      ),
      body: _connecting
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline,
                            size: 48, color: theme.colorScheme.error),
                        const SizedBox(height: 16),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: theme.colorScheme.error)),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () {
                            setState(() => _error = null);
                            _initService();
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : authService == null
                  ? const Center(child: Text('Service not available'))
                  : _authState.state == SignalAuthState.linked
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 16),
                              Text(
                                'Device linked, syncing...',
                                style: theme.textTheme.titleMedium,
                              ),
                            ],
                          ),
                        )
                      : SignalQrLinkWidget(
                          authService: authService,
                          provisioningUrl: _authState.provisioningUrl,
                          errorMessage: _authState.state ==
                                  SignalAuthState.error
                              ? _authState.errorMessage
                              : null,
                        ),
    );
  }
}
