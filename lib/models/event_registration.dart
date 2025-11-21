/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Registration type for events
enum RegistrationType {
  going,
  interested,
}

/// Entry in registration list
class RegistrationEntry {
  final String callsign;
  final String npub;

  RegistrationEntry({
    required this.callsign,
    required this.npub,
  });

  @override
  String toString() => '$callsign, $npub';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RegistrationEntry &&
          runtimeType == other.runtimeType &&
          callsign == other.callsign &&
          npub == other.npub;

  @override
  int get hashCode => callsign.hashCode ^ npub.hashCode;
}

/// Model representing event registration (going/interested lists)
class EventRegistration {
  final List<RegistrationEntry> going;
  final List<RegistrationEntry> interested;

  EventRegistration({
    this.going = const [],
    this.interested = const [],
  });

  /// Get count of people going
  int get goingCount => going.length;

  /// Get count of people interested
  int get interestedCount => interested.length;

  /// Get total registration count
  int get totalCount => goingCount + interestedCount;

  /// Check if user is going
  bool isGoing(String callsign) {
    return going.any((e) => e.callsign == callsign);
  }

  /// Check if user is interested
  bool isInterested(String callsign) {
    return interested.any((e) => e.callsign == callsign);
  }

  /// Check if user is registered (either going or interested)
  bool isRegistered(String callsign) {
    return isGoing(callsign) || isInterested(callsign);
  }

  /// Get user's registration type
  RegistrationType? getRegistrationType(String callsign) {
    if (isGoing(callsign)) return RegistrationType.going;
    if (isInterested(callsign)) return RegistrationType.interested;
    return null;
  }

  /// Export registration as text format for file storage
  String exportAsText() {
    final buffer = StringBuffer();

    buffer.writeln('# REGISTRATION');
    buffer.writeln();
    buffer.writeln('GOING:');
    for (var entry in going) {
      buffer.writeln('${entry.callsign}, ${entry.npub}');
    }
    buffer.writeln();
    buffer.writeln('INTERESTED:');
    for (var entry in interested) {
      buffer.writeln('${entry.callsign}, ${entry.npub}');
    }

    return buffer.toString();
  }

  /// Parse registration from file text
  static EventRegistration fromText(String text) {
    final lines = text.split('\n');
    final going = <RegistrationEntry>[];
    final interested = <RegistrationEntry>[];

    String? currentSection;

    for (var line in lines) {
      final trimmed = line.trim();

      if (trimmed == 'GOING:') {
        currentSection = 'going';
      } else if (trimmed == 'INTERESTED:') {
        currentSection = 'interested';
      } else if (trimmed.isNotEmpty &&
          trimmed != '# REGISTRATION' &&
          trimmed.contains(',')) {
        final parts = trimmed.split(',').map((s) => s.trim()).toList();
        if (parts.length == 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
          final entry = RegistrationEntry(
            callsign: parts[0],
            npub: parts[1],
          );

          if (currentSection == 'going') {
            going.add(entry);
          } else if (currentSection == 'interested') {
            interested.add(entry);
          }
        }
      }
    }

    return EventRegistration(
      going: going,
      interested: interested,
    );
  }

  /// Create a copy with updated fields
  EventRegistration copyWith({
    List<RegistrationEntry>? going,
    List<RegistrationEntry>? interested,
  }) {
    return EventRegistration(
      going: going ?? this.going,
      interested: interested ?? this.interested,
    );
  }

  @override
  String toString() {
    return 'EventRegistration(going: ${going.length}, interested: ${interested.length})';
  }
}
