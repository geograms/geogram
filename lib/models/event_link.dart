/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Model representing a link in an event
class EventLink {
  final String url;
  final String description;
  final String? password;
  final String? note;

  EventLink({
    required this.url,
    required this.description,
    this.password,
    this.note,
  });

  /// Check if link is valid
  bool get isValid {
    return url.startsWith('http://') || url.startsWith('https://');
  }

  /// Get domain from URL
  String? get domain {
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (e) {
      return null;
    }
  }

  /// Get link type based on domain
  LinkType get linkType {
    final d = domain?.toLowerCase() ?? '';

    if (d.contains('zoom.us')) return LinkType.zoom;
    if (d.contains('meet.google.com')) return LinkType.googleMeet;
    if (d.contains('teams.microsoft.com')) return LinkType.teams;
    if (d.contains('instagram.com')) return LinkType.instagram;
    if (d.contains('twitter.com') || d.contains('x.com')) return LinkType.twitter;
    if (d.contains('facebook.com')) return LinkType.facebook;
    if (d.contains('youtube.com') || d.contains('youtu.be')) return LinkType.youtube;
    if (d.contains('github.com')) return LinkType.github;
    if (d.contains('linkedin.com')) return LinkType.linkedin;
    if (d.contains('discord.com') || d.contains('discord.gg')) return LinkType.discord;

    return LinkType.website;
  }

  /// Export link as text format
  String exportAsText() {
    final buffer = StringBuffer();

    buffer.writeln('LINK: $url');
    buffer.writeln('DESCRIPTION: $description');

    if (password != null && password!.isNotEmpty) {
      buffer.writeln('PASSWORD: $password');
    }

    if (note != null && note!.isNotEmpty) {
      buffer.writeln('NOTE: $note');
    }

    return buffer.toString();
  }

  /// Create a copy with updated fields
  EventLink copyWith({
    String? url,
    String? description,
    String? password,
    String? note,
  }) {
    return EventLink(
      url: url ?? this.url,
      description: description ?? this.description,
      password: password ?? this.password,
      note: note ?? this.note,
    );
  }

  @override
  String toString() {
    return 'EventLink(url: $url, description: $description)';
  }
}

/// Type of link based on domain
enum LinkType {
  zoom,
  googleMeet,
  teams,
  instagram,
  twitter,
  facebook,
  youtube,
  github,
  linkedin,
  discord,
  website,
}

/// Parser for links.txt file
class EventLinksParser {
  /// Parse links from file text
  static List<EventLink> fromText(String text) {
    final lines = text.split('\n');
    final links = <EventLink>[];

    String? currentUrl;
    String? currentDescription;
    String? currentPassword;
    String? currentNote;

    void addCurrentLink() {
      if (currentUrl != null && currentDescription != null) {
        links.add(EventLink(
          url: currentUrl!,
          description: currentDescription!,
          password: currentPassword,
          note: currentNote,
        ));
      }
    }

    for (var line in lines) {
      final trimmed = line.trim();

      // Skip empty lines and headers
      if (trimmed.isEmpty || trimmed == '# LINKS' || trimmed.startsWith('##')) {
        continue;
      }

      if (trimmed.startsWith('LINK:')) {
        // Save previous link before starting new one
        addCurrentLink();

        currentUrl = trimmed.substring(5).trim();
        currentDescription = null;
        currentPassword = null;
        currentNote = null;
      } else if (trimmed.startsWith('DESCRIPTION:')) {
        currentDescription = trimmed.substring(12).trim();
      } else if (trimmed.startsWith('PASSWORD:')) {
        currentPassword = trimmed.substring(9).trim();
      } else if (trimmed.startsWith('NOTE:')) {
        currentNote = trimmed.substring(5).trim();
      } else if (trimmed.startsWith('-->')) {
        // Additional notes
        final noteText = trimmed.substring(3).trim();
        if (currentNote == null) {
          currentNote = noteText;
        } else {
          currentNote = '$currentNote\n$noteText';
        }
      }
    }

    // Add last link
    addCurrentLink();

    return links;
  }

  /// Export links to text format
  static String toText(List<EventLink> links) {
    final buffer = StringBuffer();

    buffer.writeln('# LINKS');
    buffer.writeln();

    for (var link in links) {
      buffer.write(link.exportAsText());
      if (link != links.last) {
        buffer.writeln();
      }
    }

    return buffer.toString();
  }
}
