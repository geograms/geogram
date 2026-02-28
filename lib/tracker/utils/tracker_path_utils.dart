/// Utility functions for building tracker file paths
class TrackerPathUtils {
  TrackerPathUtils._();

  // ============ Base Paths ============

  /// Get the paths directory for a year
  static String pathsDir(String basePath, int year) =>
      '$basePath/paths/$year';

  /// Get a specific path directory
  static String pathDir(String basePath, int year, String pathId) =>
      '$basePath/paths/$year/$pathId';

  /// Get path metadata file
  static String pathMetadataFile(String basePath, int year, String pathId) =>
      '${pathDir(basePath, year, pathId)}/path.json';

  /// Get path points file (legacy JSON format)
  static String pathPointsFile(String basePath, int year, String pathId) =>
      '${pathDir(basePath, year, pathId)}/points.json';

  /// Get path points CSV file (append-only, crash-safe)
  static String pathPointsCsvFile(String basePath, int year, String pathId) =>
      '${pathDir(basePath, year, pathId)}/points.csv';

  /// Get path expenses file
  static String pathExpensesFile(String basePath, int year, String pathId) =>
      '${pathDir(basePath, year, pathId)}/expenses.json';

  // ============ Measurements ============

  /// Get measurements directory for a year
  static String measurementsDir(String basePath, int year) =>
      '$basePath/measurements/$year';

  /// Get measurement file for a type
  static String measurementFile(String basePath, int year, String typeId) =>
      '${measurementsDir(basePath, year)}/$typeId.json';

  // ============ Exercises ============

  /// Get exercises directory for a year
  static String exercisesDir(String basePath, int year) =>
      '$basePath/exercises/$year';

  /// Get exercise file for a type
  static String exerciseFile(String basePath, int year, String exerciseId) =>
      '${exercisesDir(basePath, year)}/$exerciseId.json';

  /// Get custom exercises file for a year
  static String customExercisesFile(String basePath, int year) =>
      '${exercisesDir(basePath, year)}/custom.json';

  // ============ Plans ============

  /// Get active plans directory
  static String activePlansDir(String basePath) =>
      '$basePath/plans/active';

  /// Get archived plans directory
  static String archivedPlansDir(String basePath) =>
      '$basePath/plans/archived';

  /// Get active plan file
  static String activePlanFile(String basePath, String planId) =>
      '${activePlansDir(basePath)}/plan_$planId.json';

  /// Get archived plan file
  static String archivedPlanFile(String basePath, String planId) =>
      '${archivedPlansDir(basePath)}/plan_$planId.json';

  // ============ Sharing ============

  /// Get sharing groups directory
  static String sharingGroupsDir(String basePath) =>
      '$basePath/sharing/groups';

  /// Get sharing temporary directory
  static String sharingTemporaryDir(String basePath) =>
      '$basePath/sharing/temporary';

  /// Get group share file
  static String groupShareFile(String basePath, String shareId) =>
      '${sharingGroupsDir(basePath)}/share_$shareId.json';

  /// Get temporary share file
  static String temporaryShareFile(String basePath, String shareId) =>
      '${sharingTemporaryDir(basePath)}/share_$shareId.json';

  // ============ Locations ============

  /// Get locations directory
  static String locationsDir(String basePath) =>
      '$basePath/locations';

  /// Get received location file for a callsign
  static String receivedLocationFile(String basePath, String callsign) =>
      '${locationsDir(basePath)}/${callsign}_location.json';

  // ============ Proximity ============

  /// Get proximity directory for a year
  static String proximityDir(String basePath, int year) =>
      '$basePath/proximity/$year';

  /// Get proximity file for a date (YYYYMMDD)
  static String proximityFile(String basePath, int year, String dateStr) =>
      '${proximityDir(basePath, year)}/proximity_$dateStr.json';

  // ============ Visits ============

  /// Get visits directory for a year
  static String visitsDir(String basePath, int year) =>
      '$basePath/visits/$year';

  /// Get visits file for a date (YYYYMMDD)
  static String visitsFile(String basePath, int year, String dateStr) =>
      '${visitsDir(basePath, year)}/visits_$dateStr.json';

  /// Get visits stats file
  static String visitsStatsFile(String basePath) =>
      '$basePath/visits/stats.json';

  // ============ Metadata ============

  /// Get collection metadata file
  static String metadataFile(String basePath) =>
      '$basePath/metadata.json';

  /// Get settings file
  static String settingsFile(String basePath) =>
      '$basePath/settings.json';

  /// Get security file
  static String securityFile(String basePath) =>
      '$basePath/extra/security.json';

  /// Get recording state file (for crash recovery)
  static String recordingStateFile(String basePath) =>
      '$basePath/recording_state.json';

  // ============ Date Helpers ============

  /// Format date as YYYYMMDD string
  static String formatDateYYYYMMDD(DateTime date) {
    final year = date.year.toString();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year$month$day';
  }

  /// Format date as YYYY-MM-DD string
  static String formatDateISO(DateTime date) {
    final year = date.year.toString();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// Parse YYYYMMDD string to DateTime
  static DateTime? parseDateYYYYMMDD(String dateStr) {
    if (dateStr.length != 8) return null;
    try {
      final year = int.parse(dateStr.substring(0, 4));
      final month = int.parse(dateStr.substring(4, 6));
      final day = int.parse(dateStr.substring(6, 8));
      return DateTime(year, month, day);
    } catch (e) {
      return null;
    }
  }
}
