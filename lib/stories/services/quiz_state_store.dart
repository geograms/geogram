/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../services/sqlite_loader.dart';

/// Persistent state for a single quiz element
class QuizState {
  final int attemptsUsed;
  final bool solved;

  const QuizState({this.attemptsUsed = 0, this.solved = false});

  bool get isLocked => attemptsUsed >= 3 && !solved;
  int get attemptsRemaining => (3 - attemptsUsed).clamp(0, 3);
}

/// SQLite-backed persistence for quiz attempt states.
class QuizStateStore {
  final String storiesDir;
  Database? _db;

  QuizStateStore({required this.storiesDir});

  String get dbPath => '$storiesDir/stories.sqlite';

  Future<void> initialize() async {
    if (_db != null) return;

    final dir = Directory(storiesDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    _db = SQLiteLoader.openDatabase(dbPath);
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS quiz_states (
        story_id TEXT NOT NULL,
        element_id TEXT NOT NULL,
        attempts_used INTEGER NOT NULL DEFAULT 0,
        solved INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (story_id, element_id)
      );
    ''');
  }

  QuizState getState(String storyId, String elementId) {
    if (_db == null) return const QuizState();

    final rows = _db!.select(
      'SELECT attempts_used, solved FROM quiz_states WHERE story_id = ? AND element_id = ?',
      [storyId, elementId],
    );
    if (rows.isEmpty) return const QuizState();

    return QuizState(
      attemptsUsed: rows.first['attempts_used'] as int? ?? 0,
      solved: (rows.first['solved'] as int? ?? 0) == 1,
    );
  }

  void saveState(String storyId, String elementId, QuizState state) {
    if (_db == null) return;

    _db!.execute(
      '''
      INSERT OR REPLACE INTO quiz_states (story_id, element_id, attempts_used, solved)
      VALUES (?, ?, ?, ?)
      ''',
      [storyId, elementId, state.attemptsUsed, state.solved ? 1 : 0],
    );
  }

  void close() {
    _db?.dispose();
    _db = null;
  }
}
