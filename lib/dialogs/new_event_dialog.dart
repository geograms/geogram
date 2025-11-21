/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../services/i18n_service.dart';

/// Dialog for creating a new event
class NewEventDialog extends StatefulWidget {
  const NewEventDialog({Key? key}) : super(key: key);

  @override
  State<NewEventDialog> createState() => _NewEventDialogState();
}

class _NewEventDialogState extends State<NewEventDialog> {
  final _formKey = GlobalKey<FormState>();
  final _i18n = I18nService();
  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  final _locationNameController = TextEditingController();
  final _contentController = TextEditingController();

  bool _isMultiDay = false;
  DateTime _eventDate = DateTime.now();
  DateTime? _startDate;
  DateTime? _endDate;
  bool _isOnline = true;

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _locationNameController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _selectEventDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _eventDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        _eventDate = picked;
      });
    }
  }

  Future<void> _selectStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        _startDate = picked;
        // If end date is before start date, clear it
        if (_endDate != null && _endDate!.isBefore(_startDate!)) {
          _endDate = null;
        }
      });
    }
  }

  Future<void> _selectEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? _startDate ?? DateTime.now(),
      firstDate: _startDate ?? DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        _endDate = picked;
      });
    }
  }

  String? _formatDate(DateTime? date) {
    if (date == null) return null;
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  void _create() {
    if (_formKey.currentState!.validate()) {
      // Check multi-day validation
      if (_isMultiDay && (_startDate == null || _endDate == null)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('select_both_dates')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final location = _isOnline ? 'online' : _locationController.text.trim();

      Navigator.pop(context, {
        'title': _titleController.text.trim(),
        'eventDate': _isMultiDay ? null : _eventDate,
        'startDate': _isMultiDay ? _formatDate(_startDate) : null,
        'endDate': _isMultiDay ? _formatDate(_endDate) : null,
        'location': location,
        'locationName': _locationNameController.text.trim().isNotEmpty
            ? _locationNameController.text.trim()
            : null,
        'content': _contentController.text.trim(),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 700),
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                _i18n.t('new_event'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              // Form fields
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Event title
                      TextFormField(
                        controller: _titleController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('event_title'),
                          hintText: _i18n.t('enter_event_title'),
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return _i18n.t('title_is_required');
                          }
                          if (value.trim().length < 3) {
                            return _i18n.t('title_min_3_chars');
                          }
                          return null;
                        },
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      // Multi-day toggle
                      SwitchListTile(
                        title: Text(_i18n.t('multi_day_event')),
                        value: _isMultiDay,
                        onChanged: (value) {
                          setState(() {
                            _isMultiDay = value;
                            if (!value) {
                              _startDate = null;
                              _endDate = null;
                            }
                          });
                        },
                        contentPadding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: 8),
                      // Date picker based on multi-day setting
                      if (_isMultiDay) ...[
                        // Multi-day: Start and End dates
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _selectStartDate,
                                icon: const Icon(Icons.calendar_today, size: 18),
                                label: Text(
                                  _startDate != null
                                      ? _formatDate(_startDate)!
                                      : _i18n.t('start_date'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _selectEndDate,
                                icon: const Icon(Icons.calendar_today, size: 18),
                                label: Text(
                                  _endDate != null
                                      ? _formatDate(_endDate)!
                                      : _i18n.t('end_date'),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        // Single day: Event date
                        OutlinedButton.icon(
                          onPressed: _selectEventDate,
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text(
                            '${_i18n.t('event_date')}: ${_formatDate(_eventDate)}',
                          ),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 48),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      // Location type toggle
                      SwitchListTile(
                        title: Text(_i18n.t('online_event')),
                        value: _isOnline,
                        onChanged: (value) {
                          setState(() {
                            _isOnline = value;
                            if (value) {
                              _locationController.clear();
                            }
                          });
                        },
                        contentPadding: EdgeInsets.zero,
                      ),
                      // Location field (if not online)
                      if (!_isOnline) ...[
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _locationController,
                          decoration: InputDecoration(
                            labelText: _i18n.t('location_coords'),
                            hintText: '40.7128,-74.0060',
                            border: const OutlineInputBorder(),
                            helperText: _i18n.t('enter_latitude_longitude'),
                          ),
                          validator: (value) {
                            if (!_isOnline && (value == null || value.trim().isEmpty)) {
                              return _i18n.t('location_required');
                            }
                            if (!_isOnline && !value!.contains(',')) {
                              return _i18n.t('invalid_coords_format');
                            }
                            return null;
                          },
                          textInputAction: TextInputAction.next,
                        ),
                      ],
                      const SizedBox(height: 16),
                      // Location name (optional)
                      TextFormField(
                        controller: _locationNameController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('location_name'),
                          hintText: _i18n.t('enter_location_name'),
                          border: const OutlineInputBorder(),
                        ),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      // Content
                      TextFormField(
                        controller: _contentController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('description'),
                          hintText: _i18n.t('enter_event_description'),
                          border: const OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        maxLines: 8,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return _i18n.t('description_required');
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(_i18n.t('cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _create,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(_i18n.t('create_event')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
