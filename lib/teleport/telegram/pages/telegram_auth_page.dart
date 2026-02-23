/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Authentication page with Phone and QR code tabs.
 * Listens to TelegramService auth state and auto-transitions.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/app_service.dart';
import '../../../services/profile_service.dart';
import '../models/telegram_auth_state.dart';
import '../telegram_service.dart';
import '../widgets/telegram_phone_login_widget.dart';
import '../widgets/telegram_qr_login_widget.dart';
import 'telegram_chat_list_page.dart';

class TelegramAuthPage extends StatefulWidget {
  final String appPath;

  const TelegramAuthPage({super.key, required this.appPath});

  @override
  State<TelegramAuthPage> createState() => _TelegramAuthPageState();
}

class _TelegramAuthPageState extends State<TelegramAuthPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  StreamSubscription<TelegramEvent>? _eventSub;
  TelegramAuthStateData _authState = const TelegramAuthStateData(
    state: TelegramAuthState.uninitialized,
  );
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initService();
  }

  Future<void> _initService() async {
    setState(() => _connecting = true);

    try {
      final service = TelegramService();
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
        if (event.type == TelegramEventType.authStateChanged) {
          final data = event.data as TelegramAuthStateData;
          setState(() => _authState = data);

          if (data.state == TelegramAuthState.ready && mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) =>
                    TelegramChatListPage(appPath: widget.appPath),
              ),
            );
          }
        }
      });

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
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authService = TelegramService().authService;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Telegram Login'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Phone', icon: Icon(Icons.phone)),
            Tab(text: 'QR Code', icon: Icon(Icons.qr_code)),
          ],
        ),
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
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        TelegramPhoneLoginWidget(
                          authService: authService,
                          authState: _authState.state,
                        ),
                        TelegramQrLoginWidget(
                          authService: authService,
                          qrLink: _authState.qrLink,
                        ),
                      ],
                    ),
    );
  }
}
