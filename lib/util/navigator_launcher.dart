/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

// Shared utility for launching external map navigation apps.
// Handles Android (geo: intent), iOS (Apple Maps), and desktop/web (OpenStreetMap).

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';

import '../services/log_service.dart';

/// Launch an external map/navigation app for the given coordinates.
Future<void> launchExternalNavigator(double latitude, double longitude) async {
  try {
    Uri mapUri;

    if (!kIsWeb && Platform.isAndroid) {
      mapUri = Uri.parse('geo:$latitude,$longitude?q=$latitude,$longitude');
      await launchUrl(mapUri);
    } else if (!kIsWeb && Platform.isIOS) {
      mapUri = Uri.parse('https://maps.apple.com/?q=$latitude,$longitude');
      await launchUrl(mapUri);
    } else {
      mapUri = Uri.parse('https://www.openstreetmap.org/?mlat=$latitude&mlon=$longitude&zoom=15');
      if (await canLaunchUrl(mapUri)) {
        await launchUrl(mapUri, mode: LaunchMode.externalApplication);
      }
    }
  } catch (e) {
    LogService().log('NavigatorLauncher: Error opening navigator: $e');
    rethrow;
  }
}
