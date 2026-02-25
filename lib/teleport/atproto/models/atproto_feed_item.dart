/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

class AtprotoFeedItem {
  final String uri;
  final String cid;
  final String authorDid;
  final String authorHandle;
  final String displayName;
  final String text;
  final DateTime createdAt;
  final int replyCount;
  final int repostCount;
  final int likeCount;
  final String? parentUri;
  final String? rootUri;

  const AtprotoFeedItem({
    required this.uri,
    required this.cid,
    required this.authorDid,
    required this.authorHandle,
    required this.displayName,
    required this.text,
    required this.createdAt,
    this.replyCount = 0,
    this.repostCount = 0,
    this.likeCount = 0,
    this.parentUri,
    this.rootUri,
  });

  factory AtprotoFeedItem.fromJson(Map<String, dynamic> json) {
    return AtprotoFeedItem(
      uri: json['uri'] as String? ?? '',
      cid: json['cid'] as String? ?? '',
      authorDid: json['authorDid'] as String? ?? '',
      authorHandle: json['authorHandle'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      text: json['text'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now().toUtc(),
      replyCount: json['replyCount'] as int? ?? 0,
      repostCount: json['repostCount'] as int? ?? 0,
      likeCount: json['likeCount'] as int? ?? 0,
      parentUri: json['parentUri'] as String?,
      rootUri: json['rootUri'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'cid': cid,
    'authorDid': authorDid,
    'authorHandle': authorHandle,
    'displayName': displayName,
    'text': text,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'replyCount': replyCount,
    'repostCount': repostCount,
    'likeCount': likeCount,
    'parentUri': parentUri,
    'rootUri': rootUri,
  };
}
