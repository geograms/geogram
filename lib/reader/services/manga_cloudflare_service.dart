/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'manga_extension_service.dart';
import '../../services/log_service.dart';

/// Service for handling Cloudflare challenges via WebView
class MangaCloudflareService {
  static final MangaCloudflareService _instance =
      MangaCloudflareService._internal();
  factory MangaCloudflareService() => _instance;
  MangaCloudflareService._internal();

  /// Show a dialog to solve a Cloudflare challenge
  /// Returns cookies on success, null on failure/timeout
  Future<Map<String, String>?> solveChallenge({
    required BuildContext context,
    required String url,
    required String extensionId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // Platform check: WebView only works on mobile platforms
    if (!Platform.isAndroid && !Platform.isIOS) {
      // On desktop, show instructions for manual cookie extraction
      return _showDesktopWorkaround(context, url, extensionId);
    }

    // On mobile, we would use webview_flutter here
    // For now, show the manual workaround
    return _showDesktopWorkaround(context, url, extensionId);
  }

  /// Show dialog for manual cookie entry (desktop fallback)
  Future<Map<String, String>?> _showDesktopWorkaround(
    BuildContext context,
    String url,
    String extensionId,
  ) async {
    final cookieController = TextEditingController();
    final result = await showDialog<Map<String, String>?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cloudflare Protection'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This site requires Cloudflare verification.\n\n'
              '1. Open this URL in your browser:\n'
              '$url\n\n'
              '2. Complete the challenge\n'
              '3. Copy the cf_clearance cookie value and paste below:',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: cookieController,
              decoration: const InputDecoration(
                labelText: 'cf_clearance cookie value',
                hintText: 'Paste cookie value here',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = cookieController.text.trim();
              if (value.isNotEmpty) {
                Navigator.pop(ctx, {'cf_clearance': value});
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    cookieController.dispose();

    // Save cookies if provided
    if (result != null) {
      await MangaExtensionService().saveCookies(extensionId, result);
      LogService().log(
          'MangaCloudflareService: Saved CF cookies for $extensionId');
    }

    return result;
  }
}
