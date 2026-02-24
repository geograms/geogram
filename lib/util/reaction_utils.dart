/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

class ReactionUtils {
  ReactionUtils._();

  static const String reactionThumbsUp = 'thumbs-up';
  static const String reactionThumbsDown = 'thumbs-down';
  static const String reactionHeart = 'heart';
  static const String reactionFire = 'fire';
  static const String reactionHundred = 'hundred';
  static const String reactionCurious = 'curious';
  static const String reactionCelebrate = 'celebrate';
  static const String reactionLaugh = 'laugh';
  static const String reactionSad = 'sad';
  static const String reactionBeerCheers = 'beer-cheers';
  static const String reactionSurprise = 'surprise';

  static const List<String> supportedReactions = [
    reactionThumbsUp,
    reactionThumbsDown,
    reactionHeart,
    reactionFire,
    reactionHundred,
    reactionCurious,
    reactionCelebrate,
    reactionLaugh,
    reactionSad,
    reactionBeerCheers,
    reactionSurprise,
  ];

  static String normalizeReactionKey(String input) {
    final trimmed = input.trim().toLowerCase();
    if (trimmed.isEmpty) return trimmed;

    var normalized = trimmed.replaceAll(RegExp(r'[ _]+'), '-');
    while (normalized.contains('--')) {
      normalized = normalized.replaceAll('--', '-');
    }

    if (normalized == 'thumbsup') {
      return reactionThumbsUp;
    }

    if (normalized == 'thumbsdown') {
      return reactionThumbsDown;
    }

    if (normalized == 'beercheers') {
      return reactionBeerCheers;
    }

    if (normalized == reactionThumbsUp) {
      return reactionThumbsUp;
    }

    if (normalized == reactionThumbsDown) {
      return reactionThumbsDown;
    }

    if (normalized == reactionBeerCheers) {
      return reactionBeerCheers;
    }

    return normalized;
  }

  static Map<String, List<String>> normalizeReactionMap(Map<String, List<String>> raw) {
    final result = <String, List<String>>{};

    raw.forEach((key, users) {
      final normalizedKey = normalizeReactionKey(key);
      if (normalizedKey.isEmpty) return;

      final normalizedUsers = users
          .map((u) => u.trim().toUpperCase())
          .where((u) => u.isNotEmpty)
          .toSet()
          .toList()
        ..sort();

      if (normalizedUsers.isEmpty) return;

      final existing = result[normalizedKey] ?? <String>[];
      final merged = {...existing, ...normalizedUsers}.toList()..sort();
      result[normalizedKey] = merged;
    });

    return result;
  }
}
