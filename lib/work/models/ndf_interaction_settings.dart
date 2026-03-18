/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Interaction settings for NDF documents.
/// Controls what visitors can do beyond viewing (likes, comments).
/// Reusable across all NDF document types.
class NdfInteractionSettings {
  final bool permitLikes;
  final bool permitComments;

  const NdfInteractionSettings({
    this.permitLikes = false,
    this.permitComments = false,
  });

  static const NdfInteractionSettings none = NdfInteractionSettings();

  static const NdfInteractionSettings likesOnly = NdfInteractionSettings(
    permitLikes: true,
  );

  static const NdfInteractionSettings all = NdfInteractionSettings(
    permitLikes: true,
    permitComments: true,
  );

  Map<String, dynamic> toJson() => {
    if (permitLikes) 'permit_likes': true,
    if (permitComments) 'permit_comments': true,
  };

  factory NdfInteractionSettings.fromJson(Map<String, dynamic> json) {
    return NdfInteractionSettings(
      permitLikes: json['permit_likes'] as bool? ?? false,
      permitComments: json['permit_comments'] as bool? ?? false,
    );
  }

  NdfInteractionSettings copyWith({
    bool? permitLikes,
    bool? permitComments,
  }) {
    return NdfInteractionSettings(
      permitLikes: permitLikes ?? this.permitLikes,
      permitComments: permitComments ?? this.permitComments,
    );
  }

  bool get hasAnyInteraction => permitLikes || permitComments;
}
