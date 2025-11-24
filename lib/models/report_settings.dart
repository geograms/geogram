/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Settings for report collections
class ReportSettings {
  /// Default TTL for new reports (in seconds, 30 days)
  final int defaultTtl;

  /// Auto-archive resolved reports after days
  final int autoArchiveResolved;

  /// Enable verification system
  final bool enableVerification;

  /// Minimum verifications needed for "verified" badge
  final int minVerifications;

  /// Enable duplicate detection
  final bool enableDuplicateDetection;

  /// Distance threshold for duplicate detection (meters)
  final double duplicateDistanceThreshold;

  /// Enable subscriptions
  final bool enableSubscriptions;

  /// Show expired reports in main view
  final bool showExpired;

  ReportSettings({
    this.defaultTtl = 2592000, // 30 days
    this.autoArchiveResolved = 90, // 90 days
    this.enableVerification = true,
    this.minVerifications = 3,
    this.enableDuplicateDetection = true,
    this.duplicateDistanceThreshold = 100.0, // 100 meters
    this.enableSubscriptions = true,
    this.showExpired = false,
  });

  /// Create from JSON
  factory ReportSettings.fromJson(Map<String, dynamic> json) {
    return ReportSettings(
      defaultTtl: json['defaultTtl'] as int? ?? 2592000,
      autoArchiveResolved: json['autoArchiveResolved'] as int? ?? 90,
      enableVerification: json['enableVerification'] as bool? ?? true,
      minVerifications: json['minVerifications'] as int? ?? 3,
      enableDuplicateDetection: json['enableDuplicateDetection'] as bool? ?? true,
      duplicateDistanceThreshold: (json['duplicateDistanceThreshold'] as num?)?.toDouble() ?? 100.0,
      enableSubscriptions: json['enableSubscriptions'] as bool? ?? true,
      showExpired: json['showExpired'] as bool? ?? false,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'defaultTtl': defaultTtl,
      'autoArchiveResolved': autoArchiveResolved,
      'enableVerification': enableVerification,
      'minVerifications': minVerifications,
      'enableDuplicateDetection': enableDuplicateDetection,
      'duplicateDistanceThreshold': duplicateDistanceThreshold,
      'enableSubscriptions': enableSubscriptions,
      'showExpired': showExpired,
    };
  }

  /// Copy with modifications
  ReportSettings copyWith({
    int? defaultTtl,
    int? autoArchiveResolved,
    bool? enableVerification,
    int? minVerifications,
    bool? enableDuplicateDetection,
    double? duplicateDistanceThreshold,
    bool? enableSubscriptions,
    bool? showExpired,
  }) {
    return ReportSettings(
      defaultTtl: defaultTtl ?? this.defaultTtl,
      autoArchiveResolved: autoArchiveResolved ?? this.autoArchiveResolved,
      enableVerification: enableVerification ?? this.enableVerification,
      minVerifications: minVerifications ?? this.minVerifications,
      enableDuplicateDetection: enableDuplicateDetection ?? this.enableDuplicateDetection,
      duplicateDistanceThreshold: duplicateDistanceThreshold ?? this.duplicateDistanceThreshold,
      enableSubscriptions: enableSubscriptions ?? this.enableSubscriptions,
      showExpired: showExpired ?? this.showExpired,
    );
  }
}
