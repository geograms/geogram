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
  final List<String> imageThumbUrls;
  final List<String> imageFullUrls;
  final List<String> imageAlts;
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
    this.imageThumbUrls = const [],
    this.imageFullUrls = const [],
    this.imageAlts = const [],
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
      imageThumbUrls: (json['imageThumbUrls'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      imageFullUrls: (json['imageFullUrls'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      imageAlts: (json['imageAlts'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
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
    'imageThumbUrls': imageThumbUrls,
    'imageFullUrls': imageFullUrls,
    'imageAlts': imageAlts,
    'links': links,
    'isLikedByMe': isLikedByMe,
    'isRepostedByMe': isRepostedByMe,
  };

  AtprotoFeedItem copyWith({
    String? uri,
    String? cid,
    String? authorDid,
    String? authorHandle,
    String? displayName,
    String? avatarUrl,
    String? text,
    DateTime? createdAt,
    int? replyCount,
    int? repostCount,
    int? likeCount,
    String? indexedAt,
    String? parentUri,
    String? rootUri,
    String? externalUrl,
    String? externalTitle,
    String? externalDescription,
    String? externalThumbUrl,
    List<String>? imageThumbUrls,
    List<String>? imageFullUrls,
    List<String>? imageAlts,
    List<String>? links,
    bool? isLikedByMe,
    bool? isRepostedByMe,
  }) {
    return AtprotoFeedItem(
      uri: uri ?? this.uri,
      cid: cid ?? this.cid,
      authorDid: authorDid ?? this.authorDid,
      authorHandle: authorHandle ?? this.authorHandle,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
      replyCount: replyCount ?? this.replyCount,
      repostCount: repostCount ?? this.repostCount,
      likeCount: likeCount ?? this.likeCount,
      indexedAt: indexedAt ?? this.indexedAt,
      parentUri: parentUri ?? this.parentUri,
      rootUri: rootUri ?? this.rootUri,
      externalUrl: externalUrl ?? this.externalUrl,
      externalTitle: externalTitle ?? this.externalTitle,
      externalDescription: externalDescription ?? this.externalDescription,
      externalThumbUrl: externalThumbUrl ?? this.externalThumbUrl,
      imageThumbUrls: imageThumbUrls ?? this.imageThumbUrls,
      imageFullUrls: imageFullUrls ?? this.imageFullUrls,
      imageAlts: imageAlts ?? this.imageAlts,
      links: links ?? this.links,
      isLikedByMe: isLikedByMe ?? this.isLikedByMe,
      isRepostedByMe: isRepostedByMe ?? this.isRepostedByMe,
    );
  }
}
