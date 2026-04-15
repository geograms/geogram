/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../services/i18n_service.dart';
import '../../models/accounting_content.dart';
import '../../models/spreadsheet_content.dart';

/// Category colors palette (visually distinct, works on dark and light themes)
const _categoryColors = <Color>[
  Color(0xFF4CAF50), // green
  Color(0xFF2196F3), // blue
  Color(0xFFFF9800), // orange
  Color(0xFF9C27B0), // purple
  Color(0xFFF44336), // red
  Color(0xFF00BCD4), // cyan
  Color(0xFFFF5722), // deep orange
  Color(0xFF3F51B5), // indigo
  Color(0xFFCDDC39), // lime
  Color(0xFF795548), // brown
  Color(0xFFE91E63), // pink
  Color(0xFF009688), // teal
  Color(0xFFFFC107), // amber
  Color(0xFF607D8B), // blue grey
  Color(0xFF8BC34A), // light green
];

/// Data for a single category slice
class _CategorySlice {
  final String category;
  final String label;
  final double amount;
  final double percentage;
  final Color color;

  _CategorySlice({
    required this.category,
    required this.label,
    required this.amount,
    required this.percentage,
    required this.color,
  });
}

/// Whether to show breakdown for current month or current year
enum BreakdownPeriod { monthly, yearly }

/// Widget showing expense category breakdown as pie chart + ranked list
class AccountingCategoryBreakdownWidget extends StatefulWidget {
  final List<AccountingEntry> entries;
  final String currencyCode;
  final String Function(String) getCategoryLabel;

  const AccountingCategoryBreakdownWidget({
    super.key,
    required this.entries,
    required this.currencyCode,
    required this.getCategoryLabel,
  });

  @override
  State<AccountingCategoryBreakdownWidget> createState() =>
      _AccountingCategoryBreakdownWidgetState();
}

class _AccountingCategoryBreakdownWidgetState
    extends State<AccountingCategoryBreakdownWidget> {
  BreakdownPeriod _period = BreakdownPeriod.monthly;

  List<AccountingEntry> _filterEntries() {
    final now = DateTime.now();
    return widget.entries.where((e) {
      if (e.type != AccountingEntryType.expense) return false;
      if (_period == BreakdownPeriod.monthly) {
        return e.date.year == now.year && e.date.month == now.month;
      } else {
        return e.date.year == now.year;
      }
    }).toList();
  }

  List<_CategorySlice> _buildSlices(List<AccountingEntry> filtered) {
    if (filtered.isEmpty) return [];

    // Sum by category
    final totals = <String, double>{};
    for (final entry in filtered) {
      totals[entry.category] = (totals[entry.category] ?? 0) + entry.amount;
    }

    final grandTotal = totals.values.fold(0.0, (a, b) => a + b);
    if (grandTotal == 0) return [];

    // Sort by amount descending
    final sorted = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sorted.asMap().entries.map((entry) {
      final idx = entry.key;
      final cat = entry.value;
      return _CategorySlice(
        category: cat.key,
        label: widget.getCategoryLabel(cat.key),
        amount: cat.value,
        percentage: (cat.value / grandTotal) * 100,
        color: _categoryColors[idx % _categoryColors.length],
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();
    final filtered = _filterEntries();
    final slices = _buildSlices(filtered);
    final currency = CurrencyFormat.byCode(widget.currencyCode);

    String formatAmount(double amount) {
      if (currency != null) {
        final decimals = currency.isCrypto ? 4 : 2;
        final formatted = amount.toStringAsFixed(decimals);
        if (currency.symbolBefore) return '${currency.symbol}$formatted';
        return '$formatted ${currency.symbol}';
      }
      return '${amount.toStringAsFixed(2)} ${widget.currencyCode}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Period toggle
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<BreakdownPeriod>(
            segments: [
              ButtonSegment(
                value: BreakdownPeriod.monthly,
                label: Text(
                  _getMonthLabel(),
                  style: const TextStyle(fontSize: 12),
                ),
                icon: const Icon(Icons.calendar_view_month, size: 18),
              ),
              ButtonSegment(
                value: BreakdownPeriod.yearly,
                label: Text(
                  '${DateTime.now().year}',
                  style: const TextStyle(fontSize: 12),
                ),
                icon: const Icon(Icons.calendar_today, size: 18),
              ),
            ],
            selected: {_period},
            onSelectionChanged: (selected) {
              setState(() => _period = selected.first);
            },
          ),
        ),

        if (slices.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                _period == BreakdownPeriod.monthly
                    ? i18n.t('work_accounting_no_expenses_month')
                    : i18n.t('work_accounting_no_expenses_year'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          )
        else ...[
          const SizedBox(height: 8),
          // Pie chart + ranked list side by side on wide screens, stacked on narrow
          LayoutBuilder(builder: (context, constraints) {
            final isWide = constraints.maxWidth > 500;
            final chart = SizedBox(
              height: 140,
              width: isWide ? 160 : double.infinity,
              child: CustomPaint(
                painter: _PieChartPainter(
                  slices: slices,
                  brightness: theme.brightness,
                ),
                size: Size(isWide ? 160 : double.infinity, 140),
              ),
            );

            final list = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: slices.map((slice) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: slice.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        slice.label,
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      formatAmount(slice.amount),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 42,
                      child: Text(
                        '${slice.percentage.toStringAsFixed(1)}%',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              )).toList(),
            );

            if (isWide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  chart,
                  Expanded(child: list),
                ],
              );
            }
            return Column(children: [chart, const SizedBox(height: 4), list]);
          }),
          const SizedBox(height: 4),
        ],
      ],
    );
  }

  String _getMonthLabel() {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return months[DateTime.now().month - 1];
  }
}

/// Custom painter for the pie chart
class _PieChartPainter extends CustomPainter {
  final List<_CategorySlice> slices;
  final Brightness brightness;

  _PieChartPainter({required this.slices, required this.brightness});

  @override
  void paint(Canvas canvas, Size size) {
    if (slices.isEmpty) return;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) / 2) - 8;
    final innerRadius = radius * 0.55; // donut chart

    double startAngle = -math.pi / 2; // start from top

    for (final slice in slices) {
      final sweepAngle = (slice.percentage / 100) * 2 * math.pi;

      // Draw arc
      final path = Path()
        ..moveTo(
          center.dx + innerRadius * math.cos(startAngle),
          center.dy + innerRadius * math.sin(startAngle),
        )
        ..arcTo(
          Rect.fromCircle(center: center, radius: radius),
          startAngle,
          sweepAngle,
          false,
        )
        ..arcTo(
          Rect.fromCircle(center: center, radius: innerRadius),
          startAngle + sweepAngle,
          -sweepAngle,
          false,
        )
        ..close();

      canvas.drawPath(
        path,
        Paint()
          ..color = slice.color
          ..style = PaintingStyle.fill,
      );

      // Thin separator between slices
      canvas.drawPath(
        path,
        Paint()
          ..color = brightness == Brightness.dark
              ? const Color(0xFF1E1E1E)
              : Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );

      startAngle += sweepAngle;
    }

    // Center total label
    final total = slices.fold(0.0, (sum, s) => sum + s.amount);
    final totalText = total.toStringAsFixed(0);
    final textPainter = TextPainter(
      text: TextSpan(
        text: totalText,
        style: TextStyle(
          color: brightness == Brightness.dark ? Colors.white : Colors.black87,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(center.dx - textPainter.width / 2,
          center.dy - textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _PieChartPainter oldDelegate) {
    return oldDelegate.slices != slices || oldDelegate.brightness != brightness;
  }
}
