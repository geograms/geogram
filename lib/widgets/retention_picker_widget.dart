/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Reusable retention period picker dialog.
 * Can be used from DM settings, group chat settings, etc.
 */

import 'package:flutter/material.dart';
import '../services/message_retention_service.dart';

/// Show a dialog for picking a message retention period.
/// Returns the selected [RetentionPeriod], or null if cancelled.
Future<RetentionPeriod?> showRetentionPicker(
  BuildContext context,
  RetentionPeriod current,
) async {
  return showDialog<RetentionPeriod>(
    context: context,
    builder: (context) => _RetentionPickerDialog(current: current),
  );
}

class _RetentionPickerDialog extends StatefulWidget {
  final RetentionPeriod current;
  const _RetentionPickerDialog({required this.current});

  @override
  State<_RetentionPickerDialog> createState() => _RetentionPickerDialogState();
}

class _RetentionPickerDialogState extends State<_RetentionPickerDialog> {
  late RetentionPeriod _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.current;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Disappearing messages'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Set a timer for messages in this conversation. '
            'Both devices will independently delete expired messages.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          for (final period in const [
            RetentionPeriod.forever,
            RetentionPeriod.oneDay,
            RetentionPeriod.oneWeek,
            RetentionPeriod.oneMonth,
            RetentionPeriod.oneYear,
          ])
            RadioListTile<RetentionPeriod>(
              title: Text(retentionLabel(period)),
              value: period,
              groupValue: _selected,
              onChanged: (v) => setState(() => _selected = v!),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
