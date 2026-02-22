/*
 * Alerts collection adapter for AT Protocol.
 *
 * Maps Geogram Report model to radio.geogram.alerts.report records.
 *
 * Lexicon: radio.geogram.alerts.report
 * Required: type, region, severity, createdAt
 * Optional: title, description, latitude, longitude, expiresAt
 */

import '../../models/report.dart';
import '../repo.dart';
import 'collection_adapter.dart';

/// Adapter mapping Report <-> radio.geogram.alerts.report AT Proto records.
class AlertsCollection extends CollectionAdapter {
  @override
  String get nsid => 'radio.geogram.alerts.report';

  @override
  String get displayName => 'Alerts';

  /// Provider function to list all reports from Geogram storage.
  final Future<List<Report>> Function() listReports;

  AlertsCollection({required this.listReports});

  /// Convert a Geogram Report to an AT Proto record map.
  static Map<String, dynamic> toRecord(Report report) {
    // Map severity to lexicon enum
    final severityStr = switch (report.severity) {
      ReportSeverity.emergency => 'critical',
      ReportSeverity.urgent => 'warning',
      ReportSeverity.attention => 'warning',
      ReportSeverity.info => 'info',
    };

    // Derive region from coordinates
    final latRounded = (report.latitude * 10).round() / 10;
    final lonRounded = (report.longitude * 10).round() / 10;
    final region = '${latRounded}_$lonRounded';

    final record = <String, dynamic>{
      '\$type': 'radio.geogram.alerts.report',
      'type': report.type,
      'region': region,
      'severity': severityStr,
      'createdAt': report.dateTime.toUtc().toIso8601String(),
      'latitude': report.latitude,
      'longitude': report.longitude,
    };

    // Pick title from multilingual map (prefer EN)
    final title = report.titles['EN'] ?? report.titles.values.firstOrNull;
    if (title != null && title.isNotEmpty) {
      record['title'] = title;
    }

    // Pick description from multilingual map (prefer EN)
    final description = report.descriptions['EN'] ?? report.descriptions.values.firstOrNull;
    if (description != null && description.isNotEmpty) {
      record['description'] = description;
    }

    if (report.expires != null) {
      final expDt = report.expirationDateTime;
      if (expDt != null) {
        record['expiresAt'] = expDt.toUtc().toIso8601String();
      }
    }

    if (report.address != null && report.address!.isNotEmpty) {
      record['address'] = report.address;
    }

    if (report.author.isNotEmpty) {
      record['author'] = report.author;
    }

    if (report.status != ReportStatus.open) {
      record['status'] = report.status.name;
    }

    return record;
  }

  /// Convert an AT Proto record map back to a Report.
  static Report fromRecord(String rkey, Map<String, dynamic> record) {
    final createdAt = record['createdAt'] as String? ?? DateTime.now().toIso8601String();
    final dt = DateTime.tryParse(createdAt) ?? DateTime.now();

    // Map severity back
    final severityStr = record['severity'] as String? ?? 'info';
    final severity = switch (severityStr) {
      'critical' => ReportSeverity.emergency,
      'warning' => ReportSeverity.urgent,
      'info' => ReportSeverity.info,
      _ => ReportSeverity.info,
    };

    final titles = <String, String>{};
    if (record['title'] != null) {
      titles['EN'] = record['title'] as String;
    }

    final descriptions = <String, String>{};
    if (record['description'] != null) {
      descriptions['EN'] = record['description'] as String;
    }

    return Report(
      folderName: rkey,
      created: '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}_${dt.second.toString().padLeft(2, '0')}',
      author: record['author'] as String? ?? '',
      latitude: (record['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (record['longitude'] as num?)?.toDouble() ?? 0,
      severity: severity,
      type: record['type'] as String? ?? '',
      status: ReportStatus.fromString(record['status'] as String? ?? 'open'),
      address: record['address'] as String?,
      titles: titles,
      descriptions: descriptions,
    );
  }

  @override
  Future<int> syncAll(AtprotoRepo repo) async {
    final reports = await listReports();
    var created = 0;

    for (final report in reports) {
      // Only sync open/in-progress reports (not resolved/closed)
      if (report.status == ReportStatus.closed) continue;

      final rkey = CollectionAdapter.rkeyFromTimestamp(report.created);
      final record = toRecord(report);

      if (createIfAbsent(repo, rkey, record)) {
        created++;
      }
    }

    return created;
  }
}
