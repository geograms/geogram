import 'dart:async';
import 'dart:math';

import '../models/tracker_models.dart';
import '../models/tracker_proximity_track.dart';
import '../utils/tracker_path_utils.dart';
import 'tracker_storage_service.dart';
import '../../services/log_service.dart';
import '../../services/profile_storage.dart';

/// Represents a change in the tracker
class TrackerChange {
  final String type; // 'path', 'measurement', 'exercise', 'plan', 'share', etc.
  final String action; // 'created', 'updated', 'deleted'
  final String? id;
  final dynamic data;

  const TrackerChange({
    required this.type,
    required this.action,
    this.id,
    this.data,
  });
}

/// Main service for managing tracker operations
class TrackerService {
  static final TrackerService _instance = TrackerService._internal();
  factory TrackerService() => _instance;
  TrackerService._internal();

  TrackerStorageService? _storage;
  String? _currentPath;
  String? _ownerCallsign;
  ProfileStorage? _profileStorage;

  /// Stream controller for tracker changes
  final _changesController = StreamController<TrackerChange>.broadcast();

  /// Stream of tracker changes
  Stream<TrackerChange> get changes => _changesController.stream;

  /// Check if the service is initialized
  bool get isInitialized => _storage != null;

  /// Get the current collection path
  String? get currentPath => _currentPath;

  /// Get the owner callsign
  String? get ownerCallsign => _ownerCallsign;

  /// Set the storage to use for file operations.
  /// This must be called before initializeApp().
  void setStorage(ProfileStorage storage) {
    _profileStorage = storage;
  }

  /// Initialize the service with a collection path
  Future<void> initializeApp(String path, {String? callsign}) async {
    _currentPath = path;

    // Use provided ProfileStorage or fall back to filesystem storage
    final storage = _profileStorage ?? FilesystemProfileStorage(path);
    _storage = TrackerStorageService(path, storage);

    _ownerCallsign = callsign;
    await _storage!.initialize();
    LogService().log('TrackerService: Initialized with path $path');
  }

  /// Reset the service (for switching collections)
  void reset() {
    _storage = null;
    _currentPath = null;
    _ownerCallsign = null;
    _profileStorage = null;
  }

  // ============ Metadata Operations ============

  /// Get collection metadata
  Future<TrackerAppMetadata?> getMetadata() async {
    if (_storage == null) return null;
    return _storage!.readMetadata();
  }

  /// Create or update collection metadata
  Future<bool> saveMetadata(TrackerAppMetadata metadata) async {
    if (_storage == null) return false;
    final success = await _storage!.writeMetadata(metadata);
    if (success) {
      _notifyChange('metadata', 'updated');
    }
    return success;
  }

  // ============ Path Operations ============

  /// List paths for a year
  Future<List<TrackerPath>> listPaths({int? year}) async {
    if (_storage == null) return [];
    return _storage!.listPaths(year ?? DateTime.now().year);
  }

  /// List available years for paths
  Future<List<int>> listPathYears() async {
    if (_storage == null) return [];
    return _storage!.listYears('paths');
  }

  /// Get a specific path
  Future<TrackerPath?> getPath(String pathId, {int? year}) async {
    if (_storage == null) return null;
    return _storage!.readPath(year ?? DateTime.now().year, pathId);
  }

  /// Get path points
  Future<TrackerPathPoints?> getPathPoints(String pathId, {int? year}) async {
    if (_storage == null) return null;
    return _storage!.readPathPoints(year ?? DateTime.now().year, pathId);
  }

  /// Create a new path
  Future<TrackerPath?> createPath({
    required String title,
    String? description,
    int intervalSeconds = 60,
    List<String>? tags,
    List<TrackerPathSegment>? segments,
  }) async {
    if (_storage == null || _ownerCallsign == null) return null;

    final now = DateTime.now();
    final pathId = 'path_${TrackerPathUtils.formatDateYYYYMMDD(now)}_${_generateId()}';

    final path = TrackerPath(
      id: pathId,
      title: title,
      description: description,
      startedAt: now.toIso8601String(),
      status: TrackerPathStatus.recording,
      intervalSeconds: intervalSeconds,
      totalPoints: 0,
      tags: tags ?? const [],
      segments: segments ?? const [],
      ownerCallsign: _ownerCallsign!,
    );

    // Also create empty points file
    final points = TrackerPathPoints(
      pathId: pathId,
      points: const [],
    );

    final success = await _storage!.writePath(now.year, path);
    if (success) {
      await _storage!.writePathPoints(now.year, pathId, points);
      _notifyChange('path', 'created', id: pathId, data: path);
      return path;
    }
    return null;
  }

  /// Update an existing path (title, description, tags, segments, etc.)
  Future<TrackerPath?> updatePath(
    TrackerPath path, {
    int? year,
  }) async {
    if (_storage == null) return null;

    final yr = year ?? DateTime.now().year;
    final success = await _storage!.writePath(yr, path);
    if (success) {
      _notifyChange('path', 'updated', id: path.id, data: path);
      return path;
    }
    return null;
  }

  /// Add a point to a path (append-only CSV, O(1) per point).
  Future<bool> addPathPoint(String pathId, TrackerPoint point, {int? year}) async {
    if (_storage == null) return false;

    final yr = year ?? DateTime.now().year;
    final success = await _storage!.appendPathPointCsv(yr, pathId, point);

    if (success) {
      _notifyChange('path_point', 'created', id: pathId);
    }
    return success;
  }

  /// Update path metadata point count and distance from metadata values
  /// (avoids re-reading the full points file).
  Future<bool> updatePathStats(
    String pathId, {
    required int totalPoints,
    required double totalDistanceMeters,
    int? year,
  }) async {
    if (_storage == null) return false;
    final yr = year ?? DateTime.now().year;
    final path = await _storage!.readPath(yr, pathId);
    if (path == null) return false;

    final updated = path.copyWith(
      totalPoints: totalPoints,
      totalDistanceMeters: totalDistanceMeters,
    );
    final ok = await _storage!.writePath(yr, updated);
    if (ok) _notifyChange('path', 'updated', id: pathId, data: updated);
    return ok;
  }

  /// Complete a path recording
  Future<TrackerPath?> completePath(String pathId, {int? year}) async {
    if (_storage == null) return null;

    final yr = year ?? DateTime.now().year;
    final path = await _storage!.readPath(yr, pathId);
    if (path == null) return null;

    final points = await _storage!.readPathPoints(yr, pathId);
    final totalDistance = points?.calculateTotalDistance() ?? 0;
    final totalPoints = points?.points.length ?? path.totalPoints;

    final completedPath = path.copyWith(
      status: TrackerPathStatus.completed,
      endedAt: DateTime.now().toIso8601String(),
      totalDistanceMeters: totalDistance,
      totalPoints: totalPoints,
    );

    final success = await _storage!.writePath(yr, completedPath);
    if (success) {
      // Clean up legacy points.json if CSV exists
      await _storage!.cleanupLegacyPointsJson(yr, pathId);
      _notifyChange('path', 'updated', id: pathId, data: completedPath);
      return completedPath;
    }
    return null;
  }

  /// Complete a path recording with a specific end time.
  Future<TrackerPath?> completePathAt(
    String pathId,
    DateTime endTime, {
    int? year,
  }) async {
    if (_storage == null) return null;

    final yr = year ?? DateTime.now().year;
    final path = await _storage!.readPath(yr, pathId);
    if (path == null) return null;

    final points = await _storage!.readPathPoints(yr, pathId);
    final totalDistance = points?.calculateTotalDistance() ?? 0;
    final totalPoints = points?.points.length ?? 0;

    final completedPath = path.copyWith(
      status: TrackerPathStatus.completed,
      endedAt: endTime.toIso8601String(),
      totalDistanceMeters: totalDistance,
      totalPoints: totalPoints,
    );

    final success = await _storage!.writePath(yr, completedPath);
    if (success) {
      _notifyChange('path', 'updated', id: pathId, data: completedPath);
      return completedPath;
    }
    return null;
  }

  /// Replace all points for a path (used for trimming).
  Future<bool> replacePathPoints(
    String pathId,
    TrackerPathPoints points, {
    int? year,
  }) async {
    if (_storage == null) return false;

    final yr = year ?? DateTime.now().year;
    final success = await _storage!.writePathPoints(yr, pathId, points);
    if (!success) return false;

    final path = await _storage!.readPath(yr, pathId);
    if (path != null) {
      final updatedPath = path.copyWith(
        totalPoints: points.points.length,
        totalDistanceMeters: points.calculateTotalDistance(),
      );
      await _storage!.writePath(yr, updatedPath);
      _notifyChange('path', 'updated', id: pathId, data: updatedPath);
    }
    return true;
  }

  /// Merge multiple paths into one.
  ///
  /// Points are sorted chronologically and re-indexed.
  /// Segments from all paths are merged with adjusted point indices.
  /// Returns the new merged path, or null on failure.
  Future<TrackerPath?> mergePaths(
    List<String> pathIds, {
    int? year,
    bool deleteOriginals = false,
    String? title,
  }) async {
    if (_storage == null || _ownerCallsign == null || pathIds.length < 2) {
      return null;
    }

    final yr = year ?? DateTime.now().year;

    // Load all paths and points
    final paths = <TrackerPath>[];
    final allPoints = <TrackerPoint>[];
    final allSegments = <TrackerPathSegment>[];
    final allTags = <String>{};

    for (final id in pathIds) {
      final path = await _storage!.readPath(yr, id);
      if (path == null) continue;
      paths.add(path);

      final points = await _storage!.readPathPoints(yr, id);
      if (points != null) {
        allPoints.addAll(points.points);
      }
      allSegments.addAll(path.segments);
      allTags.addAll(path.tags);
    }

    if (paths.isEmpty) return null;

    // Sort points chronologically
    allPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Re-index points
    final reindexed = <TrackerPoint>[];
    for (var i = 0; i < allPoints.length; i++) {
      final p = allPoints[i];
      reindexed.add(TrackerPoint(
        index: i,
        timestamp: p.timestamp,
        lat: p.lat,
        lon: p.lon,
        altitude: p.altitude,
        accuracy: p.accuracy,
        speed: p.speed,
        bearing: p.bearing,
      ));
    }

    // Sort segments chronologically
    allSegments.sort((a, b) => a.startedAt.compareTo(b.startedAt));

    // Find earliest start and latest end
    paths.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final earliestStart = paths.first.startedAt;
    final latestEnd = paths
        .where((p) => p.endedAt != null)
        .fold<String?>(null, (prev, p) {
      if (prev == null) return p.endedAt;
      return p.endedAt!.compareTo(prev) > 0 ? p.endedAt : prev;
    }) ?? DateTime.now().toIso8601String();

    // Calculate merged stats
    final mergedPoints = TrackerPathPoints(
      pathId: '', // will be set below
      points: reindexed,
    );
    final totalDistance = mergedPoints.calculateTotalDistance();

    // Create new path
    final now = DateTime.now();
    final newPathId = 'path_${TrackerPathUtils.formatDateYYYYMMDD(now)}_${_generateId()}';

    final mergedPath = TrackerPath(
      id: newPathId,
      title: title ?? 'Merged Path',
      startedAt: earliestStart,
      endedAt: latestEnd,
      status: TrackerPathStatus.completed,
      intervalSeconds: paths.first.intervalSeconds,
      totalPoints: reindexed.length,
      totalDistanceMeters: totalDistance,
      bounds: reindexed.isNotEmpty ? PathBounds.fromPoints(reindexed) : null,
      tags: allTags.toList(),
      segments: allSegments,
      ownerCallsign: _ownerCallsign!,
    );

    // Write the merged path
    final pathOk = await _storage!.writePath(yr, mergedPath);
    if (!pathOk) return null;

    final pointsOk = await _storage!.writePathPoints(
      yr,
      newPathId,
      mergedPoints.copyWith(pathId: newPathId),
    );
    if (!pointsOk) return null;

    // Optionally delete originals
    if (deleteOriginals) {
      for (final id in pathIds) {
        await _storage!.deletePath(yr, id);
      }
    }

    _notifyChange('path', 'created', id: newPathId, data: mergedPath);
    return mergedPath;
  }

  /// Delete a path
  Future<bool> deletePath(String pathId, {int? year}) async {
    if (_storage == null) return false;

    final success = await _storage!.deletePath(year ?? DateTime.now().year, pathId);
    if (success) {
      _notifyChange('path', 'deleted', id: pathId);
    }
    return success;
  }

  /// Pause a path recording
  Future<TrackerPath?> pausePath(String pathId, {int? year}) async {
    if (_storage == null) return null;

    final yr = year ?? DateTime.now().year;
    final path = await _storage!.readPath(yr, pathId);
    if (path == null) return null;

    final pausedPath = path.copyWith(status: TrackerPathStatus.paused);
    final success = await _storage!.writePath(yr, pausedPath);
    if (success) {
      _notifyChange('path', 'updated', id: pathId, data: pausedPath);
      return pausedPath;
    }
    return null;
  }

  /// Resume a paused path recording
  Future<TrackerPath?> resumePath(String pathId, {int? year}) async {
    if (_storage == null) return null;

    final yr = year ?? DateTime.now().year;
    final path = await _storage!.readPath(yr, pathId);
    if (path == null) return null;

    final resumedPath = path.copyWith(status: TrackerPathStatus.recording);
    final success = await _storage!.writePath(yr, resumedPath);
    if (success) {
      _notifyChange('path', 'updated', id: pathId, data: resumedPath);
      return resumedPath;
    }
    return null;
  }

  // ============ Path Expenses Operations ============

  /// Get expenses for a path
  Future<TrackerExpenses?> getPathExpenses(String pathId, {int? year}) async {
    if (_storage == null) return null;
    return _storage!.readPathExpenses(year ?? DateTime.now().year, pathId);
  }

  /// Save expenses for a path
  Future<bool> savePathExpenses(
    String pathId,
    TrackerExpenses expenses, {
    int? year,
  }) async {
    if (_storage == null) return false;

    final yr = year ?? DateTime.now().year;
    final success = await _storage!.writePathExpenses(yr, pathId, expenses);
    if (success) {
      _notifyChange('expenses', 'updated', id: pathId, data: expenses);
    }
    return success;
  }

  /// Add an expense to a path
  Future<TrackerExpense?> addPathExpense(
    String pathId,
    TrackerExpense expense, {
    int? year,
  }) async {
    if (_storage == null) return null;

    final yr = year ?? DateTime.now().year;
    var expenses = await _storage!.readPathExpenses(yr, pathId);

    // Create new expenses file if it doesn't exist
    expenses ??= TrackerExpenses(pathId: pathId);

    final updatedExpenses = expenses.addExpense(expense);
    final success = await _storage!.writePathExpenses(yr, pathId, updatedExpenses);

    if (success) {
      _notifyChange('expense', 'created', id: pathId, data: expense);
      return expense;
    }
    return null;
  }

  /// Update an expense for a path
  Future<bool> updatePathExpense(
    String pathId,
    TrackerExpense expense, {
    int? year,
  }) async {
    if (_storage == null) return false;

    final yr = year ?? DateTime.now().year;
    final expenses = await _storage!.readPathExpenses(yr, pathId);
    if (expenses == null) return false;

    final updatedExpenses = expenses.updateExpense(expense);
    final success = await _storage!.writePathExpenses(yr, pathId, updatedExpenses);

    if (success) {
      _notifyChange('expense', 'updated', id: pathId, data: expense);
    }
    return success;
  }

  /// Delete an expense from a path
  Future<bool> deletePathExpense(
    String pathId,
    String expenseId, {
    int? year,
  }) async {
    if (_storage == null) return false;

    final yr = year ?? DateTime.now().year;
    final expenses = await _storage!.readPathExpenses(yr, pathId);
    if (expenses == null) return false;

    final updatedExpenses = expenses.removeExpense(expenseId);
    final success = await _storage!.writePathExpenses(yr, pathId, updatedExpenses);

    if (success) {
      _notifyChange('expense', 'deleted', id: pathId);
    }
    return success;
  }

  // ============ Recording State Operations ============

  /// Get the current recording state (for crash recovery)
  Future<TrackerRecordingState?> getRecordingState() async {
    if (_storage == null) return null;
    return _storage!.readRecordingState();
  }

  /// Save the current recording state
  Future<bool> saveRecordingState(TrackerRecordingState state) async {
    if (_storage == null) return false;
    return _storage!.writeRecordingState(state);
  }

  /// Clear the recording state (after recording completes)
  Future<bool> clearRecordingState() async {
    if (_storage == null) return false;
    return _storage!.deleteRecordingState();
  }

  // ============ Measurement Operations ============

  /// List measurement types for a year
  Future<List<String>> listMeasurementTypes({int? year}) async {
    if (_storage == null) return [];
    return _storage!.listMeasurementTypes(year ?? DateTime.now().year);
  }

  /// Get measurement data for a type
  Future<MeasurementData?> getMeasurement(String typeId, {int? year}) async {
    if (_storage == null) return null;
    return _storage!.readMeasurement(year ?? DateTime.now().year, typeId);
  }

  /// Add a measurement entry
  Future<MeasurementEntry?> addMeasurementEntry({
    required String typeId,
    required double value,
    String? notes,
    List<String>? tags,
    int? year,
  }) async {
    if (_storage == null) return null;

    final yr = year ?? DateTime.now().year;
    var data = await _storage!.readMeasurement(yr, typeId);

    // Create new data file if it doesn't exist
    if (data == null) {
      final config = MeasurementTypeConfig.builtInTypes[typeId];
      if (config == null) return null;

      data = MeasurementData(
        typeId: typeId,
        year: yr,
        displayName: config.displayName,
        unit: config.unit,
      );
    }

    final entry = MeasurementEntry(
      id: 'm_${TrackerPathUtils.formatDateYYYYMMDD(DateTime.now())}_${_generateId()}',
      timestamp: DateTime.now().toIso8601String(),
      value: value,
      notes: notes,
      tags: tags ?? const [],
    );

    final updatedData = data.addEntry(entry);
    final success = await _storage!.writeMeasurement(yr, updatedData);

    if (success) {
      _notifyChange('measurement', 'created', id: typeId, data: entry);
      return entry;
    }
    return null;
  }

  /// Get blood pressure data
  Future<BloodPressureData?> getBloodPressure({int? year}) async {
    if (_storage == null) return null;
    return _storage!.readBloodPressure(year ?? DateTime.now().year);
  }

  /// Delete a measurement entry
  Future<bool> deleteMeasurementEntry(
    String typeId,
    String entryId, {
    int? year,
  }) async {
    if (_storage == null) return false;

    final yr = year ?? DateTime.now().year;
    final data = await _storage!.readMeasurement(yr, typeId);
    if (data == null) return false;

    final updatedData = data.removeEntry(entryId);
    final success = await _storage!.writeMeasurement(yr, updatedData);

    if (success) {
      _notifyChange('measurement', 'deleted', id: typeId);
    }
    return success;
  }

  /// Delete a blood pressure entry
  Future<bool> deleteBloodPressureEntry(String entryId, {int? year}) async {
    if (_storage == null) return false;

    final yr = year ?? DateTime.now().year;
    final data = await _storage!.readBloodPressure(yr);
    if (data == null) return false;

    final updatedData = data.removeEntry(entryId);
    final success = await _storage!.writeBloodPressure(yr, updatedData);

    if (success) {
      _notifyChange('blood_pressure', 'deleted');
    }
    return success;
  }

  /// Add a blood pressure entry
  Future<BloodPressureEntry?> addBloodPressureEntry({
    required int systolic,
    required int diastolic,
    int? heartRate,
    String? notes,
    List<String>? tags,
    int? year,
  }) async {
    if (_storage == null) return null;

    final yr = year ?? DateTime.now().year;
    var data = await _storage!.readBloodPressure(yr);

    // Create new data file if it doesn't exist
    data ??= BloodPressureData(year: yr);

    final entry = BloodPressureEntry(
      id: 'bp_${TrackerPathUtils.formatDateYYYYMMDD(DateTime.now())}_${_generateId()}',
      timestamp: DateTime.now().toIso8601String(),
      systolic: systolic,
      diastolic: diastolic,
      heartRate: heartRate,
      notes: notes,
      tags: tags ?? const [],
    );

    final updatedData = data.addEntry(entry);
    final success = await _storage!.writeBloodPressure(yr, updatedData);

    if (success) {
      _notifyChange('blood_pressure', 'created', data: entry);
      return entry;
    }
    return null;
  }

  // ============ Exercise Operations ============

  /// List exercise types for a year
  Future<List<String>> listExerciseTypes({int? year}) async {
    if (_storage == null) return [];
    return _storage!.listExerciseTypes(year ?? DateTime.now().year);
  }

  /// Get exercise data for a type
  Future<ExerciseData?> getExercise(String exerciseId, {int? year}) async {
    if (_storage == null) return null;
    return _storage!.readExercise(year ?? DateTime.now().year, exerciseId);
  }

  /// Add an exercise entry
  Future<ExerciseEntry?> addExerciseEntry({
    required String exerciseId,
    required int count,
    int? durationSeconds,
    String? pathId,
    String? notes,
    List<String>? tags,
    int? year,
  }) async {
    if (_storage == null) return null;

    final yr = year ?? DateTime.now().year;
    var data = await _storage!.readExercise(yr, exerciseId);

    // Create new data file if it doesn't exist
    data ??= ExerciseData.fromType(exerciseId, yr);

    final entry = ExerciseEntry(
      id: 'e_${TrackerPathUtils.formatDateYYYYMMDD(DateTime.now())}_${_generateId()}',
      timestamp: DateTime.now().toIso8601String(),
      count: count,
      durationSeconds: durationSeconds,
      pathId: pathId,
      notes: notes,
      tags: tags ?? const [],
    );

    final updatedData = data.addEntry(entry);
    final success = await _storage!.writeExercise(yr, updatedData);

    if (success) {
      _notifyChange('exercise', 'created', id: exerciseId, data: entry);
      return entry;
    }
    return null;
  }

  /// Get today's count for an exercise
  Future<int> getExerciseTodayCount(String exerciseId, {int? year}) async {
    final data = await getExercise(exerciseId, year: year);
    if (data == null) return 0;
    return data.getTotalForDate(DateTime.now());
  }

  /// Get this week's count for an exercise
  Future<int> getExerciseWeekCount(String exerciseId, {int? year}) async {
    final data = await getExercise(exerciseId, year: year);
    if (data == null) return 0;
    return data.getTotalForCurrentWeek();
  }

  /// Get this week's entry count for a measurement
  Future<int> getMeasurementWeekCount(String typeId, {int? year}) async {
    final data = await getMeasurement(typeId, year: year);
    if (data == null) return 0;
    return data.getCountForCurrentWeek();
  }

  /// Delete an exercise entry
  Future<bool> deleteExerciseEntry(
    String exerciseId,
    String entryId, {
    int? year,
  }) async {
    if (_storage == null) return false;

    final yr = year ?? DateTime.now().year;
    final data = await _storage!.readExercise(yr, exerciseId);
    if (data == null) return false;

    final updatedData = data.removeEntry(entryId);
    final success = await _storage!.writeExercise(yr, updatedData);

    if (success) {
      _notifyChange('exercise', 'deleted', id: exerciseId);
    }
    return success;
  }

  // ============ Plan Operations ============

  /// List active plans
  Future<List<TrackerPlan>> listActivePlans() async {
    if (_storage == null) return [];
    return _storage!.listActivePlans();
  }

  /// List archived plans
  Future<List<ArchivedPlan>> listArchivedPlans() async {
    if (_storage == null) return [];
    return _storage!.listArchivedPlans();
  }

  /// Get an active plan
  Future<TrackerPlan?> getActivePlan(String planId) async {
    if (_storage == null) return null;
    return _storage!.readActivePlan(planId);
  }

  /// Create a new plan
  Future<TrackerPlan?> createPlan({
    required String title,
    String? description,
    required String startsAt,
    String? endsAt,
    List<PlanGoal>? goals,
  }) async {
    if (_storage == null) return null;

    final planId = _generateId();
    final plan = TrackerPlan(
      id: planId,
      title: title,
      description: description,
      status: TrackerPlanStatus.active,
      startsAt: startsAt,
      endsAt: endsAt,
      goals: goals ?? const [],
      createdAt: DateTime.now().toIso8601String(),
      updatedAt: DateTime.now().toIso8601String(),
    );

    final success = await _storage!.writeActivePlan(plan);
    if (success) {
      _notifyChange('plan', 'created', id: planId, data: plan);
      return plan;
    }
    return null;
  }

  /// Update a plan
  Future<bool> updatePlan(TrackerPlan plan) async {
    if (_storage == null) return false;

    final updatedPlan = plan.copyWith(
      updatedAt: DateTime.now().toIso8601String(),
    );

    final success = await _storage!.writeActivePlan(updatedPlan);
    if (success) {
      _notifyChange('plan', 'updated', id: plan.id, data: updatedPlan);
    }
    return success;
  }

  /// Archive a plan
  Future<bool> archivePlan(String planId, {PlanSummary? summary}) async {
    if (_storage == null) return false;

    final plan = await _storage!.readActivePlan(planId);
    if (plan == null) return false;

    final archivedPlan = ArchivedPlan.fromPlan(plan, summary);

    final archiveSuccess = await _storage!.writeArchivedPlan(archivedPlan);
    if (archiveSuccess) {
      await _storage!.deleteActivePlan(planId);
      _notifyChange('plan', 'archived', id: planId);
      return true;
    }
    return false;
  }

  /// Pause a plan
  Future<bool> pausePlan(String planId) async {
    if (_storage == null) return false;

    final plan = await _storage!.readActivePlan(planId);
    if (plan == null) return false;

    final updatedPlan = plan.copyWith(
      status: TrackerPlanStatus.paused,
      updatedAt: DateTime.now().toIso8601String(),
    );

    final success = await _storage!.writeActivePlan(updatedPlan);
    if (success) {
      _notifyChange('plan', 'updated', id: planId, data: updatedPlan);
    }
    return success;
  }

  /// Resume a paused plan
  Future<bool> resumePlan(String planId) async {
    if (_storage == null) return false;

    final plan = await _storage!.readActivePlan(planId);
    if (plan == null) return false;

    final updatedPlan = plan.copyWith(
      status: TrackerPlanStatus.active,
      updatedAt: DateTime.now().toIso8601String(),
    );

    final success = await _storage!.writeActivePlan(updatedPlan);
    if (success) {
      _notifyChange('plan', 'updated', id: planId, data: updatedPlan);
    }
    return success;
  }

  /// Complete a plan (marks as completed and archives)
  Future<bool> completePlan(String planId) async {
    if (_storage == null) return false;

    final plan = await _storage!.readActivePlan(planId);
    if (plan == null) return false;

    final completedPlan = plan.copyWith(
      status: TrackerPlanStatus.completed,
      updatedAt: DateTime.now().toIso8601String(),
    );

    // Archive with completed status
    return archivePlan(planId);
  }

  /// Get current week progress for a plan
  Future<PlanWeeklyProgress?> getPlanWeekProgress(String planId) async {
    if (_storage == null) return null;

    final plan = await _storage!.readActivePlan(planId);
    if (plan == null) return null;

    final now = DateTime.now();
    final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
    final endOfWeek = startOfWeek.add(const Duration(days: 6));

    final weekStart = _formatDate(startOfWeek);
    final weekEnd = _formatDate(endOfWeek);
    final weekStr = '${startOfWeek.year}-W${_getWeekNumber(startOfWeek).toString().padLeft(2, '0')}';

    // Calculate progress for each goal
    final goalProgresses = <GoalWeeklyProgress>[];
    int goalsAchieved = 0;

    for (final goal in plan.goals) {
      // Get exercise data for this goal
      final exerciseData = await getExercise(goal.exerciseId, year: now.year);

      // Calculate daily totals for the week
      final dailyTotals = <String, int>{};
      if (exerciseData != null) {
        for (int i = 0; i < 7; i++) {
          final day = startOfWeek.add(Duration(days: i));
          final dayStr = _formatDate(day);
          final count = exerciseData.getTotalForDate(day);
          if (count > 0) {
            dailyTotals[dayStr] = count;
          }
        }
      }

      final weekEnded = now.isAfter(endOfWeek);
      final progress = GoalWeeklyProgress.calculate(
        goal: goal,
        dailyTotals: dailyTotals,
        weekEnded: weekEnded,
      );

      goalProgresses.add(progress);
      if (progress.status == GoalProgressStatus.achieved) {
        goalsAchieved++;
      }
    }

    // Calculate overall progress
    double overallProgress = 0;
    if (goalProgresses.isNotEmpty) {
      overallProgress = goalProgresses
              .map((g) => g.progressPercent)
              .fold(0.0, (sum, p) => sum + p) /
          goalProgresses.length;
    }

    return PlanWeeklyProgress(
      planId: planId,
      week: weekStr,
      weekStart: weekStart,
      weekEnd: weekEnd,
      goals: goalProgresses,
      overallProgressPercent: overallProgress,
      goalsAchieved: goalsAchieved,
      goalsTotal: plan.goals.length,
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  int _getWeekNumber(DateTime date) {
    final firstDayOfYear = DateTime(date.year, 1, 1);
    final daysSinceFirstDay = date.difference(firstDayOfYear).inDays;
    return ((daysSinceFirstDay + firstDayOfYear.weekday) / 7).ceil();
  }

  // ============ Share Operations ============

  /// List group shares
  Future<List<GroupShare>> listGroupShares() async {
    if (_storage == null) return [];
    return _storage!.listGroupShares();
  }

  /// List temporary shares
  Future<List<TemporaryShare>> listTemporaryShares() async {
    if (_storage == null) return [];
    return _storage!.listTemporaryShares();
  }

  /// Create a group share
  Future<GroupShare?> createGroupShare({
    required String groupId,
    required String groupName,
    int updateIntervalSeconds = 300,
    ShareAccuracy accuracy = ShareAccuracy.approximate,
    List<ShareMember>? members,
  }) async {
    if (_storage == null || _ownerCallsign == null) return null;

    final now = DateTime.now();
    final shareId = groupId;

    final share = GroupShare(
      id: shareId,
      groupId: groupId,
      groupName: groupName,
      createdAt: now.toIso8601String(),
      updatedAt: now.toIso8601String(),
      updateIntervalSeconds: updateIntervalSeconds,
      shareAccuracy: accuracy,
      members: members ?? const [],
      ownerCallsign: _ownerCallsign!,
    );

    final success = await _storage!.writeGroupShare(share);
    if (success) {
      _notifyChange('share', 'created', id: shareId, data: share);
      return share;
    }
    return null;
  }

  /// Create a temporary share
  Future<TemporaryShare?> createTemporaryShare({
    required int durationMinutes,
    required List<ShareRecipient> recipients,
    String? reason,
    int updateIntervalSeconds = 60,
    ShareAccuracy accuracy = ShareAccuracy.precise,
  }) async {
    if (_storage == null || _ownerCallsign == null) return null;

    final now = DateTime.now();
    final expiresAt = now.add(Duration(minutes: durationMinutes));
    final shareId = '${TrackerPathUtils.formatDateYYYYMMDD(now)}_${_generateId()}';

    final share = TemporaryShare(
      id: shareId,
      recipients: recipients,
      createdAt: now.toIso8601String(),
      expiresAt: expiresAt.toIso8601String(),
      durationMinutes: durationMinutes,
      reason: reason,
      updateIntervalSeconds: updateIntervalSeconds,
      shareAccuracy: accuracy,
      ownerCallsign: _ownerCallsign!,
    );

    final success = await _storage!.writeTemporaryShare(share);
    if (success) {
      _notifyChange('temporary_share', 'created', id: shareId, data: share);
      return share;
    }
    return null;
  }

  // ============ Received Location Operations ============

  /// List received locations
  Future<List<ReceivedLocation>> listReceivedLocations() async {
    if (_storage == null) return [];
    return _storage!.listReceivedLocations();
  }

  /// Get received location for a callsign
  Future<ReceivedLocation?> getReceivedLocation(String callsign) async {
    if (_storage == null) return null;
    return _storage!.readReceivedLocation(callsign);
  }

  /// Update received location
  Future<bool> updateReceivedLocation(ReceivedLocation location) async {
    if (_storage == null) return false;

    final success = await _storage!.writeReceivedLocation(location);
    if (success) {
      _notifyChange('received_location', 'updated', id: location.callsign, data: location);
    }
    return success;
  }

  // ============ Proximity Operations ============

  /// Get today's proximity data
  Future<DailyProximityData?> getTodayProximity() async {
    if (_storage == null) return null;
    return _storage!.readProximity(DateTime.now());
  }

  /// Get proximity for a specific date
  Future<DailyProximityData?> getProximity(DateTime date) async {
    if (_storage == null) return null;
    return _storage!.readProximity(date);
  }

  /// List proximity dates for a year
  Future<List<DateTime>> listProximityDates({int? year}) async {
    if (_storage == null) return [];
    return _storage!.listProximityDates(year ?? DateTime.now().year);
  }

  /// Update proximity data
  Future<bool> updateProximity(DailyProximityData data) async {
    if (_storage == null) return false;

    final success = await _storage!.writeProximity(data);
    if (success) {
      _notifyChange('proximity', 'updated', data: data);
    }
    return success;
  }

  // ============ Unified Proximity Track Operations (Year/Week) ============

  /// Get all proximity tracks for a specific week
  Future<List<ProximityTrack>> getProximityTracks({
    int? year,
    int? week,
  }) async {
    if (_storage == null) return [];
    final now = DateTime.now();
    return _storage!.listProximityTracks(
      year ?? now.year,
      week ?? getWeekNumber(now),
    );
  }

  /// Get a specific proximity track
  Future<ProximityTrack?> getProximityTrack({
    required String id,
    int? year,
    int? week,
  }) async {
    if (_storage == null) return null;
    final now = DateTime.now();
    return _storage!.readProximityTrack(
      year ?? now.year,
      week ?? getWeekNumber(now),
      id,
    );
  }

  /// Update a proximity track
  Future<bool> updateProximityTrack(
    ProximityTrack track, {
    int? year,
    int? week,
  }) async {
    if (_storage == null) return false;
    final now = DateTime.now();
    final success = await _storage!.writeProximityTrack(
      year ?? now.year,
      week ?? getWeekNumber(now),
      track,
    );
    if (success) {
      _notifyChange('proximity_track', 'updated', data: track);
    }
    return success;
  }

  /// List weeks with proximity data for a year
  Future<List<int>> listProximityWeeks({int? year}) async {
    if (_storage == null) return [];
    return _storage!.listProximityWeeks(year ?? DateTime.now().year);
  }

  /// List years with proximity data
  Future<List<int>> listProximityYears() async {
    if (_storage == null) return [];
    return _storage!.listYears('proximity');
  }

  // ============ Visit Operations ============

  /// Get today's visits
  Future<DailyVisitsData?> getTodayVisits() async {
    if (_storage == null) return null;
    return _storage!.readVisits(DateTime.now());
  }

  /// Get visits for a specific date
  Future<DailyVisitsData?> getVisits(DateTime date) async {
    if (_storage == null) return null;
    return _storage!.readVisits(date);
  }

  /// List visit dates for a year
  Future<List<DateTime>> listVisitDates({int? year}) async {
    if (_storage == null) return [];
    return _storage!.listVisitDates(year ?? DateTime.now().year);
  }

  /// Get place statistics
  Future<PlaceStatsData?> getPlaceStats() async {
    if (_storage == null) return null;
    return _storage!.readPlaceStats();
  }

  /// Update visits
  Future<bool> updateVisits(DailyVisitsData data) async {
    if (_storage == null) return false;

    final success = await _storage!.writeVisits(data);
    if (success) {
      _notifyChange('visits', 'updated', data: data);
    }
    return success;
  }

  /// Add a visit
  Future<TrackerVisit?> addVisit({
    required String placeId,
    required String placeName,
    required double lat,
    required double lon,
    String? placeCategory,
    bool autoDetected = true,
    double? detectionAccuracyMeters,
  }) async {
    if (_storage == null || _ownerCallsign == null) return null;

    final now = DateTime.now();
    var data = await _storage!.readVisits(now);

    // Create new data file if it doesn't exist
    data ??= DailyVisitsData(
      date: TrackerPathUtils.formatDateISO(now),
      ownerCallsign: _ownerCallsign!,
    );

    final visit = TrackerVisit(
      id: 'visit_${TrackerPathUtils.formatDateYYYYMMDD(now)}_${_generateId()}',
      placeId: placeId,
      placeName: placeName,
      placeCategory: placeCategory,
      placeCoordinates: PlaceCoordinates(lat: lat, lon: lon),
      checkedInAt: now.toIso8601String(),
      autoDetected: autoDetected,
      detectionAccuracyMeters: detectionAccuracyMeters,
      status: 'checked_in',
    );

    final updatedData = data.addVisit(visit);
    final success = await _storage!.writeVisits(updatedData);

    if (success) {
      _notifyChange('visit', 'created', data: visit);
      return visit;
    }
    return null;
  }

  // ============ Helper Methods ============

  /// Notify listeners of a change
  void _notifyChange(String type, String action, {String? id, dynamic data}) {
    _changesController.add(TrackerChange(
      type: type,
      action: action,
      id: id,
      data: data,
    ));
  }

  /// Generate a short random ID
  String _generateId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return String.fromCharCodes(
      Iterable.generate(6, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }

  /// Dispose resources
  void dispose() {
    _changesController.close();
  }
}
