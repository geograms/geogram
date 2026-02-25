/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

class AtprotoLinkTarget {
  final String? profileActor;
  final String? postUri;

  const AtprotoLinkTarget({this.profileActor, this.postUri});

  bool get isInternal => profileActor != null || postUri != null;
}

class AtprotoLinkParser {
  static AtprotoLinkTarget parse(String raw) {
    final normalized = _normalize(raw);

    if (normalized.startsWith('at://')) {
      final match = RegExp(r'^at://([^/]+)(?:/(.+))?$').firstMatch(normalized);
      if (match == null) return const AtprotoLinkTarget();
      final actor = (match.group(1) ?? '').trim();
      if (actor.isEmpty) return const AtprotoLinkTarget();
      final path = (match.group(2) ?? '').trim();
      final parts = path.isEmpty ? const <String>[] : path.split('/');
      if (parts.length >= 2 && parts[0] == 'app.bsky.feed.post') {
        return AtprotoLinkTarget(
          profileActor: actor,
          postUri: 'at://$actor/${parts[0]}/${parts[1]}',
        );
      }
      return AtprotoLinkTarget(profileActor: actor);
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null) return const AtprotoLinkTarget();

    final host = uri.host.toLowerCase();
    if (host == 'bsky.app' || host.endsWith('.bsky.app')) {
      final seg = uri.pathSegments;
      if (seg.length >= 2 && seg[0] == 'profile') {
        final actor = seg[1];
        if (actor.isEmpty) return const AtprotoLinkTarget();
        if (seg.length >= 4 && seg[2] == 'post') {
          final rkey = seg[3];
          if (rkey.isNotEmpty) {
            return AtprotoLinkTarget(
              profileActor: actor,
              postUri: 'at://$actor/app.bsky.feed.post/$rkey',
            );
          }
        }
        return AtprotoLinkTarget(profileActor: actor);
      }
    }

    return const AtprotoLinkTarget();
  }

  static String _normalize(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.startsWith('at://')) {
      return trimmed;
    }
    if (trimmed.startsWith('www.')) return 'https://$trimmed';
    return trimmed;
  }
}
