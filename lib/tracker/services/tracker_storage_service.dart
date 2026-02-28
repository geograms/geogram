import 'dart:convert';

import '../models/tracker_models.dart';
import '../models/tracker_proximity_track.dart';
import '../utils/tracker_path_utils.dart';
import '../../services/log_service.dart';
import '../../services/profile_storage.dart';

/// Service for handling tracker file I/O operations
class TrackerStorageService {
  final String basePath;
  final ProfileStorage _storage;

  TrackerStorageService(this.basePath, this._storage);

  /// Helper to get relative path from absolute path
  String _relativePath(String absolutePath) {
    if (absolutePath.startsWith(basePath)) {
      var rel = absolutePath.substring(basePath.length);
      if (rel.startsWith('/')) rel = rel.substring(1);
      return rel;
    }
    return absolutePath;
  }

  // ============ Path Operations ============

  /// Read path metadata
  Future<TrackerPath?> readPath(int year, String pathId) async {
    try {
      final filePath = TrackerPathUtils.pathMetadataFile(basePath, year, pathId);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return TrackerPath.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading path: $e');
      return null;
    }
  }

  /// Write path metadata
  Future<bool> writePath(int year, TrackerPath path) async {
    try {
      final filePath = TrackerPathUtils.pathMetadataFile(basePath, year, path.id);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(path.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing path: $e');
      return false;
    }
  }

  /// Read path points — tries CSV first, falls back to legacy JSON.
  Future<TrackerPathPoints?> readPathPoints(int year, String pathId) async {
    try {
      // Try CSV first (new format)
      final csvFilePath = TrackerPathUtils.pathPointsCsvFile(basePath, year, pathId);
      final csvRelative = _relativePath(csvFilePath);
      final csvContent = await _storage.readString(csvRelative);
      if (csvContent != null && csvContent.trim().isNotEmpty) {
        return TrackerPathPoints.fromCsv(pathId, csvContent);
      }

      // Fall back to legacy JSON
      final jsonFilePath = TrackerPathUtils.pathPointsFile(basePath, year, pathId);
      final jsonRelative = _relativePath(jsonFilePath);
      final jsonContent = await _storage.readString(jsonRelative);
      if (jsonContent == null) return null;

      final json = jsonDecode(jsonContent) as Map<String, dynamic>;
      return TrackerPathPoints.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading path points: $e');
      return null;
    }
  }

  /// Write path points in CSV format.
  Future<bool> writePathPoints(int year, String pathId, TrackerPathPoints points) async {
    try {
      final csvFilePath = TrackerPathUtils.pathPointsCsvFile(basePath, year, pathId);
      final relativePath = _relativePath(csvFilePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      final csv = points.toCsv();
      await _storage.writeString(relativePath, csv.isEmpty ? '' : '$csv\n');
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing path points: $e');
      return false;
    }
  }

  /// Append a single point to the CSV file (O(1) per point).
  Future<bool> appendPathPointCsv(int year, String pathId, TrackerPoint point) async {
    try {
      final csvFilePath = TrackerPathUtils.pathPointsCsvFile(basePath, year, pathId);
      final relativePath = _relativePath(csvFilePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.appendString(relativePath, '${point.toCsvLine()}\n');
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error appending path point CSV: $e');
      return false;
    }
  }

  /// Remove legacy points.json when points.csv exists.
  Future<void> cleanupLegacyPointsJson(int year, String pathId) async {
    try {
      final jsonFilePath = TrackerPathUtils.pathPointsFile(basePath, year, pathId);
      final jsonRelative = _relativePath(jsonFilePath);
      if (await _storage.exists(jsonRelative)) {
        await _storage.delete(jsonRelative);
      }
    } catch (e) {
      LogService().log('TrackerStorageService: Error cleaning up legacy JSON: $e');
    }
  }

  /// Delete a path and its points
  Future<bool> deletePath(int year, String pathId) async {
    try {
      final dirPath = TrackerPathUtils.pathDir(basePath, year, pathId);
      final relativePath = _relativePath(dirPath);
      if (await _storage.exists(relativePath)) {
        await _storage.deleteDirectory(relativePath);
      }
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error deleting path: $e');
      return false;
    }
  }

  /// List all paths for a year
  Future<List<TrackerPath>> listPaths(int year) async {
    try {
      final dirPath = TrackerPathUtils.pathsDir(basePath, year);
      final relativePath = _relativePath(dirPath);
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final paths = <TrackerPath>[];
      for (final entry in entries) {
        if (entry.isDirectory) {
          final pathId = entry.name;
          final path = await readPath(year, pathId);
          if (path != null) {
            paths.add(path);
          }
        }
      }
      return paths;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing paths: $e');
      return [];
    }
  }

  // ============ Path Expenses Operations ============

  /// Read path expenses
  Future<TrackerExpenses?> readPathExpenses(int year, String pathId) async {
    try {
      final filePath = TrackerPathUtils.pathExpensesFile(basePath, year, pathId);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return TrackerExpenses.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading path expenses: $e');
      return null;
    }
  }

  /// Write path expenses
  Future<bool> writePathExpenses(int year, String pathId, TrackerExpenses expenses) async {
    try {
      final filePath = TrackerPathUtils.pathExpensesFile(basePath, year, pathId);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(expenses.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing path expenses: $e');
      return false;
    }
  }

  // ============ Measurement Operations ============

  /// Read measurement data for a type and year
  Future<MeasurementData?> readMeasurement(int year, String typeId) async {
    try {
      final filePath = TrackerPathUtils.measurementFile(basePath, year, typeId);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return MeasurementData.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading measurement: $e');
      return null;
    }
  }

  /// Write measurement data
  Future<bool> writeMeasurement(int year, MeasurementData data) async {
    try {
      final filePath = TrackerPathUtils.measurementFile(basePath, year, data.typeId);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(data.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing measurement: $e');
      return false;
    }
  }

  /// Read blood pressure data for a year
  Future<BloodPressureData?> readBloodPressure(int year) async {
    try {
      final filePath = TrackerPathUtils.measurementFile(basePath, year, 'blood_pressure');
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return BloodPressureData.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading blood pressure: $e');
      return null;
    }
  }

  /// Write blood pressure data
  Future<bool> writeBloodPressure(int year, BloodPressureData data) async {
    try {
      final filePath = TrackerPathUtils.measurementFile(basePath, year, 'blood_pressure');
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(data.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing blood pressure: $e');
      return false;
    }
  }

  /// List measurement types that have data for a year
  Future<List<String>> listMeasurementTypes(int year) async {
    try {
      final dirPath = TrackerPathUtils.measurementsDir(basePath, year);
      final relativePath = _relativePath(dirPath);
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final types = <String>[];
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.json')) {
          types.add(entry.name.replaceAll('.json', ''));
        }
      }
      return types;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing measurement types: $e');
      return [];
    }
  }

  // ============ Exercise Operations ============

  /// Read exercise data for a type and year
  Future<ExerciseData?> readExercise(int year, String exerciseId) async {
    try {
      final filePath = TrackerPathUtils.exerciseFile(basePath, year, exerciseId);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return ExerciseData.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading exercise: $e');
      return null;
    }
  }

  /// Write exercise data
  Future<bool> writeExercise(int year, ExerciseData data) async {
    try {
      final filePath = TrackerPathUtils.exerciseFile(basePath, year, data.exerciseId);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(data.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing exercise: $e');
      return false;
    }
  }

  /// Read custom exercises data for a year
  Future<CustomExercisesData?> readCustomExercises(int year) async {
    try {
      final filePath = TrackerPathUtils.customExercisesFile(basePath, year);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return CustomExercisesData.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading custom exercises: $e');
      return null;
    }
  }

  /// Write custom exercises data
  Future<bool> writeCustomExercises(int year, CustomExercisesData data) async {
    try {
      final filePath = TrackerPathUtils.customExercisesFile(basePath, year);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(data.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing custom exercises: $e');
      return false;
    }
  }

  /// List exercise types that have data for a year
  Future<List<String>> listExerciseTypes(int year) async {
    try {
      final dirPath = TrackerPathUtils.exercisesDir(basePath, year);
      final relativePath = _relativePath(dirPath);
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final types = <String>[];
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.json')) {
          types.add(entry.name.replaceAll('.json', ''));
        }
      }
      return types;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing exercise types: $e');
      return [];
    }
  }

  // ============ Plan Operations ============

  /// Read an active plan
  Future<TrackerPlan?> readActivePlan(String planId) async {
    try {
      final filePath = TrackerPathUtils.activePlanFile(basePath, planId);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return TrackerPlan.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading active plan: $e');
      return null;
    }
  }

  /// Write an active plan
  Future<bool> writeActivePlan(TrackerPlan plan) async {
    try {
      final filePath = TrackerPathUtils.activePlanFile(basePath, plan.id);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(plan.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing active plan: $e');
      return false;
    }
  }

  /// Read an archived plan
  Future<ArchivedPlan?> readArchivedPlan(String planId) async {
    try {
      final filePath = TrackerPathUtils.archivedPlanFile(basePath, planId);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return ArchivedPlan.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading archived plan: $e');
      return null;
    }
  }

  /// Write an archived plan
  Future<bool> writeArchivedPlan(ArchivedPlan plan) async {
    try {
      final filePath = TrackerPathUtils.archivedPlanFile(basePath, plan.id);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(plan.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing archived plan: $e');
      return false;
    }
  }

  /// Delete an active plan
  Future<bool> deleteActivePlan(String planId) async {
    try {
      final filePath = TrackerPathUtils.activePlanFile(basePath, planId);
      final relativePath = _relativePath(filePath);
      if (await _storage.exists(relativePath)) {
        await _storage.delete(relativePath);
      }
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error deleting active plan: $e');
      return false;
    }
  }

  /// List all active plans
  Future<List<TrackerPlan>> listActivePlans() async {
    try {
      final dirPath = TrackerPathUtils.activePlansDir(basePath);
      final relativePath = _relativePath(dirPath);
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final plans = <TrackerPlan>[];
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.json')) {
          final planId = entry.name.replaceAll('plan_', '').replaceAll('.json', '');
          final plan = await readActivePlan(planId);
          if (plan != null) {
            plans.add(plan);
          }
        }
      }
      return plans;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing active plans: $e');
      return [];
    }
  }

  /// List all archived plans
  Future<List<ArchivedPlan>> listArchivedPlans() async {
    try {
      final dirPath = TrackerPathUtils.archivedPlansDir(basePath);
      final relativePath = _relativePath(dirPath);
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final plans = <ArchivedPlan>[];
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.json')) {
          final planId = entry.name.replaceAll('plan_', '').replaceAll('.json', '');
          final plan = await readArchivedPlan(planId);
          if (plan != null) {
            plans.add(plan);
          }
        }
      }
      return plans;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing archived plans: $e');
      return [];
    }
  }

  // ============ Share Operations ============

  /// Read a group share
  Future<GroupShare?> readGroupShare(String shareId) async {
    try {
      final filePath = TrackerPathUtils.groupShareFile(basePath, shareId);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return GroupShare.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading group share: $e');
      return null;
    }
  }

  /// Write a group share
  Future<bool> writeGroupShare(GroupShare share) async {
    try {
      final filePath = TrackerPathUtils.groupShareFile(basePath, share.id);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(share.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing group share: $e');
      return false;
    }
  }

  /// Delete a group share
  Future<bool> deleteGroupShare(String shareId) async {
    try {
      final filePath = TrackerPathUtils.groupShareFile(basePath, shareId);
      final relativePath = _relativePath(filePath);
      if (await _storage.exists(relativePath)) {
        await _storage.delete(relativePath);
      }
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error deleting group share: $e');
      return false;
    }
  }

  /// List all group shares
  Future<List<GroupShare>> listGroupShares() async {
    try {
      final dirPath = TrackerPathUtils.sharingGroupsDir(basePath);
      final relativePath = _relativePath(dirPath);
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final shares = <GroupShare>[];
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.json')) {
          final shareId = entry.name.replaceAll('share_', '').replaceAll('.json', '');
          final share = await readGroupShare(shareId);
          if (share != null) {
            shares.add(share);
          }
        }
      }
      return shares;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing group shares: $e');
      return [];
    }
  }

  /// Read a temporary share
  Future<TemporaryShare?> readTemporaryShare(String shareId) async {
    try {
      final filePath = TrackerPathUtils.temporaryShareFile(basePath, shareId);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return TemporaryShare.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading temporary share: $e');
      return null;
    }
  }

  /// Write a temporary share
  Future<bool> writeTemporaryShare(TemporaryShare share) async {
    try {
      final filePath = TrackerPathUtils.temporaryShareFile(basePath, share.id);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(share.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing temporary share: $e');
      return false;
    }
  }

  /// Delete a temporary share
  Future<bool> deleteTemporaryShare(String shareId) async {
    try {
      final filePath = TrackerPathUtils.temporaryShareFile(basePath, shareId);
      final relativePath = _relativePath(filePath);
      if (await _storage.exists(relativePath)) {
        await _storage.delete(relativePath);
      }
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error deleting temporary share: $e');
      return false;
    }
  }

  /// List all temporary shares
  Future<List<TemporaryShare>> listTemporaryShares() async {
    try {
      final dirPath = TrackerPathUtils.sharingTemporaryDir(basePath);
      final relativePath = _relativePath(dirPath);
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final shares = <TemporaryShare>[];
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.json')) {
          final shareId = entry.name.replaceAll('share_', '').replaceAll('.json', '');
          final share = await readTemporaryShare(shareId);
          if (share != null) {
            shares.add(share);
          }
        }
      }
      return shares;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing temporary shares: $e');
      return [];
    }
  }

  // ============ Received Location Operations ============

  /// Read a received location for a callsign
  Future<ReceivedLocation?> readReceivedLocation(String callsign) async {
    try {
      final filePath = TrackerPathUtils.receivedLocationFile(basePath, callsign);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return ReceivedLocation.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading received location: $e');
      return null;
    }
  }

  /// Write a received location
  Future<bool> writeReceivedLocation(ReceivedLocation location) async {
    try {
      final filePath = TrackerPathUtils.receivedLocationFile(basePath, location.callsign);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(location.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing received location: $e');
      return false;
    }
  }

  /// Delete a received location
  Future<bool> deleteReceivedLocation(String callsign) async {
    try {
      final filePath = TrackerPathUtils.receivedLocationFile(basePath, callsign);
      final relativePath = _relativePath(filePath);
      if (await _storage.exists(relativePath)) {
        await _storage.delete(relativePath);
      }
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error deleting received location: $e');
      return false;
    }
  }

  /// List all received locations
  Future<List<ReceivedLocation>> listReceivedLocations() async {
    try {
      final dirPath = TrackerPathUtils.locationsDir(basePath);
      final relativePath = _relativePath(dirPath);
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final locations = <ReceivedLocation>[];
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('_location.json')) {
          final callsign = entry.name.replaceAll('_location.json', '');
          final location = await readReceivedLocation(callsign);
          if (location != null) {
            locations.add(location);
          }
        }
      }
      return locations;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing received locations: $e');
      return [];
    }
  }

  // ============ Proximity Operations ============

  /// Read daily proximity data
  Future<DailyProximityData?> readProximity(DateTime date) async {
    try {
      final dateStr = TrackerPathUtils.formatDateYYYYMMDD(date);
      final filePath = TrackerPathUtils.proximityFile(basePath, date.year, dateStr);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return DailyProximityData.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading proximity: $e');
      return null;
    }
  }

  /// Write daily proximity data
  Future<bool> writeProximity(DailyProximityData data) async {
    try {
      // Parse date from data.date (YYYY-MM-DD format)
      final dateParts = data.date.split('-');
      final year = int.parse(dateParts[0]);
      final dateStr = data.date.replaceAll('-', '');

      final filePath = TrackerPathUtils.proximityFile(basePath, year, dateStr);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(data.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing proximity: $e');
      return false;
    }
  }

  /// List proximity files for a year
  Future<List<DateTime>> listProximityDates(int year) async {
    try {
      final dirPath = TrackerPathUtils.proximityDir(basePath, year);
      final relativePath = _relativePath(dirPath);
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final dates = <DateTime>[];
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.json')) {
          final dateStr = entry.name.replaceAll('proximity_', '').replaceAll('.json', '');
          final date = TrackerPathUtils.parseDateYYYYMMDD(dateStr);
          if (date != null) {
            dates.add(date);
          }
        }
      }
      dates.sort((a, b) => b.compareTo(a)); // Most recent first
      return dates;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing proximity dates: $e');
      return [];
    }
  }

  // ============ Visit Operations ============

  /// Read daily visits data
  Future<DailyVisitsData?> readVisits(DateTime date) async {
    try {
      final dateStr = TrackerPathUtils.formatDateYYYYMMDD(date);
      final filePath = TrackerPathUtils.visitsFile(basePath, date.year, dateStr);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return DailyVisitsData.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading visits: $e');
      return null;
    }
  }

  /// Write daily visits data
  Future<bool> writeVisits(DailyVisitsData data) async {
    try {
      // Parse date from data.date (YYYY-MM-DD format)
      final dateParts = data.date.split('-');
      final year = int.parse(dateParts[0]);
      final dateStr = data.date.replaceAll('-', '');

      final filePath = TrackerPathUtils.visitsFile(basePath, year, dateStr);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(data.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing visits: $e');
      return false;
    }
  }

  /// Read place stats
  Future<PlaceStatsData?> readPlaceStats() async {
    try {
      final filePath = TrackerPathUtils.visitsStatsFile(basePath);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return PlaceStatsData.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading place stats: $e');
      return null;
    }
  }

  /// Write place stats
  Future<bool> writePlaceStats(PlaceStatsData data) async {
    try {
      final filePath = TrackerPathUtils.visitsStatsFile(basePath);
      final relativePath = _relativePath(filePath);
      final parentDir = relativePath.contains('/')
          ? relativePath.substring(0, relativePath.lastIndexOf('/'))
          : '';
      if (parentDir.isNotEmpty) {
        await _storage.createDirectory(parentDir);
      }
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(data.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing place stats: $e');
      return false;
    }
  }

  /// List visit dates for a year
  Future<List<DateTime>> listVisitDates(int year) async {
    try {
      final dirPath = TrackerPathUtils.visitsDir(basePath, year);
      final relativePath = _relativePath(dirPath);
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final dates = <DateTime>[];
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.json')) {
          final dateStr = entry.name.replaceAll('visits_', '').replaceAll('.json', '');
          final date = TrackerPathUtils.parseDateYYYYMMDD(dateStr);
          if (date != null) {
            dates.add(date);
          }
        }
      }
      dates.sort((a, b) => b.compareTo(a)); // Most recent first
      return dates;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing visit dates: $e');
      return [];
    }
  }

  // ============ Unified Proximity Track Operations (Year/Week) ============

  /// Get the relative directory path for proximity tracks of a specific week
  String _proximityWeekRelativeDir(int year, int week) {
    final weekFolder = 'W${week.toString().padLeft(2, '0')}';
    return 'proximity/$year/$weekFolder';
  }

  /// Read a proximity track file
  Future<ProximityTrack?> readProximityTrack(int year, int week, String id) async {
    try {
      final relativePath = '${_proximityWeekRelativeDir(year, week)}/$id-track.json';
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return ProximityTrack.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading proximity track: $e');
      return null;
    }
  }

  /// Write a proximity track file
  Future<bool> writeProximityTrack(int year, int week, ProximityTrack track) async {
    try {
      final dirPath = _proximityWeekRelativeDir(year, week);
      await _storage.createDirectory(dirPath);
      final relativePath = '$dirPath/${track.id}-track.json';
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(track.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing proximity track: $e');
      return false;
    }
  }

  /// List all proximity tracks for a specific week
  Future<List<ProximityTrack>> listProximityTracks(int year, int week) async {
    try {
      final relativePath = _proximityWeekRelativeDir(year, week);
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final tracks = <ProximityTrack>[];
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('-track.json')) {
          try {
            final content = await _storage.readString('$relativePath/${entry.name}');
            if (content != null) {
              final json = jsonDecode(content) as Map<String, dynamic>;
              tracks.add(ProximityTrack.fromJson(json));
            }
          } catch (_) {
            // Skip invalid files
          }
        }
      }

      // Sort by total time descending
      tracks.sort((a, b) =>
          b.weekSummary.totalSeconds.compareTo(a.weekSummary.totalSeconds));
      return tracks;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing proximity tracks: $e');
      return [];
    }
  }

  /// List weeks with proximity data for a year
  Future<List<int>> listProximityWeeks(int year) async {
    try {
      final relativePath = 'proximity/$year';
      if (!await _storage.exists(relativePath)) return [];

      final entries = await _storage.listDirectory(relativePath);
      final weeks = <int>[];
      for (final entry in entries) {
        if (entry.isDirectory && entry.name.startsWith('W')) {
          final week = int.tryParse(entry.name.substring(1));
          if (week != null && week >= 1 && week <= 53) {
            weeks.add(week);
          }
        }
      }
      weeks.sort((a, b) => b.compareTo(a)); // Most recent first
      return weeks;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing proximity weeks: $e');
      return [];
    }
  }

  // ============ Metadata Operations ============

  /// Read collection metadata
  Future<TrackerAppMetadata?> readMetadata() async {
    try {
      final filePath = TrackerPathUtils.metadataFile(basePath);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return TrackerAppMetadata.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading metadata: $e');
      return null;
    }
  }

  /// Write collection metadata
  Future<bool> writeMetadata(TrackerAppMetadata metadata) async {
    try {
      final filePath = TrackerPathUtils.metadataFile(basePath);
      final relativePath = _relativePath(filePath);
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(metadata.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing metadata: $e');
      return false;
    }
  }

  // ============ Recording State Operations ============

  /// Read the active recording state (for crash recovery)
  Future<TrackerRecordingState?> readRecordingState() async {
    try {
      final filePath = TrackerPathUtils.recordingStateFile(basePath);
      final relativePath = _relativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return TrackerRecordingState.fromJson(json);
    } catch (e) {
      LogService().log('TrackerStorageService: Error reading recording state: $e');
      return null;
    }
  }

  /// Write the active recording state
  Future<bool> writeRecordingState(TrackerRecordingState state) async {
    try {
      final filePath = TrackerPathUtils.recordingStateFile(basePath);
      final relativePath = _relativePath(filePath);
      await _storage.writeString(
        relativePath,
        const JsonEncoder.withIndent('  ').convert(state.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error writing recording state: $e');
      return false;
    }
  }

  /// Delete the recording state (after recording completes)
  Future<bool> deleteRecordingState() async {
    try {
      final filePath = TrackerPathUtils.recordingStateFile(basePath);
      final relativePath = _relativePath(filePath);
      if (await _storage.exists(relativePath)) {
        await _storage.delete(relativePath);
      }
      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error deleting recording state: $e');
      return false;
    }
  }

  // ============ Initialization ============

  /// Initialize the tracker directory structure
  Future<bool> initialize() async {
    try {
      // Create subdirectories using storage abstraction
      await _storage.createDirectory('paths');
      await _storage.createDirectory('measurements');
      await _storage.createDirectory('exercises');
      await _storage.createDirectory('plans/active');
      await _storage.createDirectory('plans/archived');
      await _storage.createDirectory('sharing/groups');
      await _storage.createDirectory('sharing/temporary');
      await _storage.createDirectory('locations');
      await _storage.createDirectory('proximity');
      await _storage.createDirectory('visits');
      await _storage.createDirectory('extra');

      return true;
    } catch (e) {
      LogService().log('TrackerStorageService: Error initializing: $e');
      return false;
    }
  }

  /// Check if the tracker has been initialized
  Future<bool> isInitialized() async {
    try {
      // Check if base directory exists (empty path = root of storage)
      return await _storage.exists('');
    } catch (e) {
      return false;
    }
  }

  /// List available years for a data type
  Future<List<int>> listYears(String subPath) async {
    try {
      if (!await _storage.exists(subPath)) return [];

      final entries = await _storage.listDirectory(subPath);
      final years = <int>[];
      for (final entry in entries) {
        if (entry.isDirectory) {
          final year = int.tryParse(entry.name);
          if (year != null) {
            years.add(year);
          }
        }
      }
      years.sort((a, b) => b.compareTo(a)); // Most recent first
      return years;
    } catch (e) {
      LogService().log('TrackerStorageService: Error listing years: $e');
      return [];
    }
  }
}
