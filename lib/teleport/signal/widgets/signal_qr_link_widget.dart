/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * QR code widget for Signal device linking.
 * Displays a scannable QR code from the provisioning URL.
 * Auto-requests a QR code on first load.
 */

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../signal_auth_service.dart';

class SignalQrLinkWidget extends StatefulWidget {
  final SignalAuthService authService;
  final String? provisioningUrl;
  final String? errorMessage;

  const SignalQrLinkWidget({
    super.key,
    required this.authService,
    this.provisioningUrl,
    this.errorMessage,
  });

  @override
  State<SignalQrLinkWidget> createState() => _SignalQrLinkWidgetState();
}

class _SignalQrLinkWidgetState extends State<SignalQrLinkWidget> {
  bool _requesting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.provisioningUrl == null || widget.provisioningUrl!.isEmpty) {
      _requestLinkDevice();
    }
  }

  Future<void> _requestLinkDevice() async {
    if (_requesting) return;
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      await widget.authService.requestLinkDevice();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    if (mounted) setState(() => _requesting = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = widget.provisioningUrl;
    final error = widget.errorMessage ?? _error;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          if (error != null) ...[
            const SizedBox(height: 24),
            Icon(Icons.error_outline,
                size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _requestLinkDevice,
              child: const Text('Retry'),
            ),
          ] else if (url != null && url.isNotEmpty) ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final qrSize =
                    (constraints.maxWidth - 48).clamp(200.0, 480.0);
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: url,
                    version: QrVersions.auto,
                    size: qrSize,
                    backgroundColor: Colors.white,
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            Text(
              'Scan this QR code from Signal',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Open Signal > Settings > Linked Devices > Link New Device',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _requestLinkDevice,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh QR Code'),
            ),
          ] else ...[
            const SizedBox(height: 48),
            if (_requesting)
              const CircularProgressIndicator()
            else ...[
              const Icon(Icons.qr_code_2, size: 64, color: Color(0xFF3A76F0)),
              const SizedBox(height: 16),
              Text(
                'Link this device to Signal',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Tap below to generate a QR code for device linking',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _requestLinkDevice,
                child: const Text('Generate QR Code'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
