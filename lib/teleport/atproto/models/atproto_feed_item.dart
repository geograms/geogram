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
  final String? avatarUrl;
  final String text;
  final DateTime createdAt;
  final int replyCount;
  final int repostCount;
  final int likeCount;
  final String? indexedAt;
  final String? parentUri;
  final String? rootUri;
  final String? externalUrl;
  final String? externalTitle;
  final String? externalDescription;
  final String? externalThumbUrl;
  final List<String> links;
  final bool isLikedByMe;
  final bool isRepostedByMe;

  const AtprotoFeedItem({
    required this.uri,
    required this.cid,
    required this.authorDid,
    required this.authorHandle,
    required this.displayName,
    this.avatarUrl,
    required this.text,
    required this.createdAt,
    this.replyCount = 0,
    this.repostCount = 0,
    this.likeCount = 0,
    this.indexedAt,
    this.parentUri,
    this.rootUri,
    this.externalUrl,
    this.externalTitle,
    this.externalDescription,
    this.externalThumbUrl,
    this.links = const [],
    this.isLikedByMe = false,
    this.isRepostedByMe = false,
  });

  factory AtprotoFeedItem.fromJson(Map<String, dynamic> json) {
    return AtprotoFeedItem(
      uri: json['uri'] as String? ?? '',
      cid: json['cid'] as String? ?? '',
      authorDid: json['authorDid'] as String? ?? '',
      authorHandle: json['authorHandle'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      avatarUrl: json['avatarUrl'] as String?,
      text: json['text'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now().toUtc(),
      replyCount: json['replyCount'] as int? ?? 0,
      repostCount: json['repostCount'] as int? ?? 0,
      likeCount: json['likeCount'] as int? ?? 0,
      indexedAt: json['indexedAt'] as String?,
      parentUri: json['parentUri'] as String?,
      rootUri: json['rootUri'] as String?,
      externalUrl: json['externalUrl'] as String?,
      externalTitle: json['externalTitle'] as String?,
      externalDescription: json['externalDescription'] as String?,
      externalThumbUrl: json['externalThumbUrl'] as String?,
      links: (json['links'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      isLikedByMe: json['isLikedByMe'] as bool? ?? false,
      isRepostedByMe: json['isRepostedByMe'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'cid': cid,
    'authorDid': authorDid,
    'authorHandle': authorHandle,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'text': text,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'replyCount': replyCount,
    'repostCount': repostCount,
    'likeCount': likeCount,
    'indexedAt': indexedAt,
    'parentUri': parentUri,
    'rootUri': rootUri,
    'externalUrl': externalUrl,
    'externalTitle': externalTitle,
    'externalDescription': externalDescription,
    'externalThumbUrl': externalThumbUrl,
    'links': links,
    'isLikedByMe': isLikedByMe,
    'isRepostedByMe': isRepostedByMe,
  };
}
