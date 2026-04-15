/*
 * Shared heuristic that maps a wapp folder name / id to a Material
 * icon used as the visual fallback when a manifest doesn't supply an
 * explicit icon. Both the launcher grid (`main.dart` `WappManifest`)
 * and the wapp Store card view (`wapp_page.dart` `_buildWappCard`)
 * call this so the same wapp looks the same on both surfaces.
 *
 * The function is case-insensitive and matches substrings, so
 * "tools.geogram.terminal" and "terminal" both resolve to
 * Icons.terminal. Order of the checks matters — more specific
 * substrings come first.
 */

import 'package:flutter/material.dart';

IconData wappIconFor(String nameOrId) {
  final lower = nameOrId.toLowerCase();
  if (lower.contains('install') || lower.contains('store')) {
    return Icons.storefront;
  }
  if (lower.contains('creator')) return Icons.construction;
  if (lower.contains('terminal')) return Icons.terminal;
  if (lower.contains('chat')) return Icons.chat;
  if (lower.contains('radio')) return Icons.radio;
  if (lower.contains('map')) return Icons.map;
  if (lower.contains('file')) return Icons.folder;
  if (lower.contains('settings')) return Icons.settings;
  if (lower.contains('tester') || lower.contains('test')) {
    return Icons.science;
  }
  if (lower.contains('task')) return Icons.task_alt;
  if (lower.contains('widget')) return Icons.dashboard;
  return Icons.extension;
}
