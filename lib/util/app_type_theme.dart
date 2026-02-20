/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

/// Centralized theming utilities for app/collection types
/// This file has Flutter dependencies - for pure Dart constants, use app_constants.dart

/// Get the icon for an app/collection type
IconData getAppTypeIcon(String type) {
  switch (type) {
    case 'chat':
      return Icons.chat;
    case 'email':
      return Icons.email;
    case 'blog':
      return Icons.article;
    case 'forum':
      return Icons.forum;
    case 'contacts':
      return Icons.contacts;
    case 'events':
      return Icons.event;
    case 'places':
      return Icons.place;
    case 'news':
      return Icons.newspaper;
    case 'www':
      return Icons.language;
    case 'documents':
      return Icons.description;
    case 'photos':
      return Icons.photo_library;
    case 'alerts':
      return Icons.campaign;
    case 'market':
      return Icons.store;
    case 'groups':
      return Icons.groups;
    case 'postcards':
      return Icons.mail;
    case 'shared':
      return Icons.folder_shared;
    case 'inventory':
      return Icons.inventory_2;
    case 'wallet':
      return Icons.account_balance_wallet;
    case 'log':
      return Icons.article_outlined;
    case 'backup':
      return Icons.backup;
    case 'console':
      return Icons.terminal;
    case 'tracker':
      return Icons.track_changes;
    case 'station':
      return Icons.cell_tower;
    case 'videos':
      return Icons.video_library;
    case 'transfer':
      return Icons.swap_horiz;
    case 'reader':
      return Icons.menu_book;
    case 'flasher':
      return Icons.flash_on;
    case 'work':
      return Icons.work;
    case 'usenet':
      return Icons.forum;
    case 'music':
      return Icons.library_music;
    case 'stories':
      return Icons.auto_stories;
    case 'files':
      return Icons.snippet_folder;
    case 'qr':
      return Icons.qr_code_2;
    case 'conference':
      return Icons.mic;
    default:
      return Icons.folder;
  }
}

/// Get the gradient colors for an app/collection type
LinearGradient getAppTypeGradient(String type, bool isDark) {
  switch (type) {
    case 'chat':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF1565C0), const Color(0xFF0D47A1)]
            : [const Color(0xFF42A5F5), const Color(0xFF1E88E5)],
      );
    case 'email':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF00838F), const Color(0xFF006064)]
            : [const Color(0xFF26C6DA), const Color(0xFF00ACC1)],
      );
    case 'blog':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFFAD1457), const Color(0xFF880E4F)]
            : [const Color(0xFFEC407A), const Color(0xFFD81B60)],
      );
    case 'places':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF2E7D32), const Color(0xFF1B5E20)]
            : [const Color(0xFF66BB6A), const Color(0xFF43A047)],
      );
    case 'events':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFFE65100), const Color(0xFFBF360C)]
            : [const Color(0xFFFF9800), const Color(0xFFF57C00)],
      );
    case 'alerts':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFFC62828), const Color(0xFFB71C1C)]
            : [const Color(0xFFEF5350), const Color(0xFFE53935)],
      );
    case 'backup':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF00838F), const Color(0xFF006064)]
            : [const Color(0xFF26C6DA), const Color(0xFF00ACC1)],
      );
    case 'inventory':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF6A1B9A), const Color(0xFF4A148C)]
            : [const Color(0xFFAB47BC), const Color(0xFF8E24AA)],
      );
    case 'wallet':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF558B2F), const Color(0xFF33691E)]
            : [const Color(0xFF9CCC65), const Color(0xFF7CB342)],
      );
    case 'contacts':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF5D4037), const Color(0xFF4E342E)]
            : [const Color(0xFF8D6E63), const Color(0xFF6D4C41)],
      );
    case 'groups':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF0277BD), const Color(0xFF01579B)]
            : [const Color(0xFF29B6F6), const Color(0xFF039BE5)],
      );
    case 'shared':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF455A64), const Color(0xFF37474F)]
            : [const Color(0xFF78909C), const Color(0xFF607D8B)],
      );
    case 'log':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF37474F), const Color(0xFF263238)]
            : [const Color(0xFF546E7A), const Color(0xFF455A64)],
      );
    case 'console':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF1A237E), const Color(0xFF0D47A1)]
            : [const Color(0xFF3F51B5), const Color(0xFF303F9F)],
      );
    case 'tracker':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF4527A0), const Color(0xFF311B92)]
            : [const Color(0xFF7E57C2), const Color(0xFF5E35B1)],
      );
    case 'forum':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF00695C), const Color(0xFF004D40)]
            : [const Color(0xFF26A69A), const Color(0xFF00897B)],
      );
    case 'www':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF4527A0), const Color(0xFF311B92)]
            : [const Color(0xFF7E57C2), const Color(0xFF5E35B1)],
      );
    case 'news':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF283593), const Color(0xFF1A237E)]
            : [const Color(0xFF5C6BC0), const Color(0xFF3F51B5)],
      );
    case 'market':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF827717), const Color(0xFF616121)]
            : [const Color(0xFFCDDC39), const Color(0xFFAFB42B)],
      );
    case 'postcards':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFFBF360C), const Color(0xFF8D6E63)]
            : [const Color(0xFFFF8A65), const Color(0xFFFFAB91)],
      );
    case 'videos':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF6A1B9A), const Color(0xFF8E24AA)]
            : [const Color(0xFFCE93D8), const Color(0xFFAB47BC)],
      );
    case 'transfer':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF1565C0), const Color(0xFF00695C)]
            : [const Color(0xFF42A5F5), const Color(0xFF26A69A)],
      );
    case 'reader':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF795548), const Color(0xFF5D4037)]
            : [const Color(0xFFA1887F), const Color(0xFF8D6E63)],
      );
    case 'flasher':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFFFF6F00), const Color(0xFFE65100)]
            : [const Color(0xFFFFB74D), const Color(0xFFFFA726)],
      );
    case 'work':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF1565C0), const Color(0xFF0D47A1)]
            : [const Color(0xFF42A5F5), const Color(0xFF1E88E5)],
      );
    case 'usenet':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF6A1B9A), const Color(0xFF4A148C)]
            : [const Color(0xFFAB47BC), const Color(0xFF8E24AA)],
      );
    case 'music':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFFD84315), const Color(0xFFBF360C)]
            : [const Color(0xFFFF7043), const Color(0xFFF4511E)],
      );
    case 'stories':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFFEF6C00), const Color(0xFFE65100)]
            : [const Color(0xFFFFA726), const Color(0xFFFF9800)],
      );
    case 'files':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFFF57F17), const Color(0xFFE65100)]
            : [const Color(0xFFFFCA28), const Color(0xFFFFA000)],
      );
    case 'qr':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF212121), const Color(0xFF424242)]
            : [const Color(0xFF616161), const Color(0xFF424242)],
      );
    case 'conference':
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF00838F), const Color(0xFF00695C)]
            : [const Color(0xFF26C6DA), const Color(0xFF00BFA5)],
      );
    default:
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF455A64), const Color(0xFF37474F)]
            : [const Color(0xFF78909C), const Color(0xFF607D8B)],
      );
  }
}
