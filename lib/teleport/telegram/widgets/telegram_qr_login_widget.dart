/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * QR code login widget — displays a scannable QR from TDLib's link string.
 */

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../telegram_auth_service.dart';

class TelegramQrLoginWidget extends StatefulWidget {
  final TelegramAuthService authService;
  final String? qrLink;

  const TelegramQrLoginWidget({
    super.key,
    required this.authService,
    this.qrLink,
  });

  @override
  State<TelegramQrLoginWidget> createState() => _TelegramQrLoginWidgetState();
}

class _TelegramQrLoginWidgetState extends State<TelegramQrLoginWidget> {
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    if (widget.qrLink == null || widget.qrLink!.isEmpty) {
      _requestQrCode();
    }
  }

  Future<void> _requestQrCode() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      await widget.authService.requestQrCode();
    } catch (_) {}
    if (mounted) setState(() => _requesting = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = widget.qrLink;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          if (link != null && link.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: link,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Scan this QR code from Telegram on your phone',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Open Telegram > Settings > Devices > Link Desktop Device',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ] else ...[
            const SizedBox(height: 48),
            if (_requesting)
              const CircularProgressIndicator()
            else ...[
              Text(
                'Tap below to generate a QR code',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _requestQrCode,
                child: const Text('Generate QR Code'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
