/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../../services/i18n_service.dart';
import '../models/ndf_interaction_settings.dart';

/// Reusable widget for configuring NDF document interaction permissions.
/// Controls whether likes and comments are enabled for a document.
/// Designed to be embedded alongside DocumentVisibilityWidget in a settings sheet.
class DocumentInteractionWidget extends StatelessWidget {
  final NdfInteractionSettings interaction;
  final ValueChanged<NdfInteractionSettings> onChanged;

  const DocumentInteractionWidget({
    super.key,
    required this.interaction,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final i18n = I18nService();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          i18n.t('interactions'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(i18n.t('permit_likes')),
          subtitle: Text(i18n.t('permit_likes_desc')),
          value: interaction.permitLikes,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => onChanged(interaction.copyWith(permitLikes: v)),
        ),
        SwitchListTile(
          title: Text(i18n.t('permit_comments')),
          subtitle: Text(i18n.t('permit_comments_desc')),
          value: interaction.permitComments,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => onChanged(interaction.copyWith(permitComments: v)),
        ),
      ],
    );
  }
}
