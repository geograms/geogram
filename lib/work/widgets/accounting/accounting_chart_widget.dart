/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/accounting_content.dart';
import '../../models/spreadsheet_content.dart';

/// Period data for chart rendering
class _PeriodData {
  final String label;
  final double income;
  final double expense;

  _PeriodData({required this.label, required this.income, required this.expense});

  double get net => income - expense;
}

/// Bar chart showing income vs expenses by week or month
class AccountingChartWidget extends StatelessWidget {
  final List<AccountingEntry> entries;
  final AccountingViewPeriod viewPeriod;
  final String currencyCode;

  const AccountingChartWidget({
    super.key,
    required this.entries,
    required this.viewPeriod,
    required this.currencyCode,
  });

  List<_PeriodData> _groupEntries() {
    if (entries.isEmpty) return [];

    final groups = <String, _PeriodData>{};
    final sortedEntries = List<AccountingEntry>.from(entries)
      ..sort((a, b) => a.date.compareTo(b.date));

    for (final entry in sortedEntries) {
      String key;
      String label;

      if (viewPeriod == AccountingViewPeriod.weekly) {
        // ISO week number
        final weekNumber = _weekNumber(entry.date);
        final year = entry.date.year;
        key = '$year-W$weekNumber';
        label = 'W$weekNumber';
      } else {
        key = DateFormat('yyyy-MM').format(entry.date);
        label = DateFormat('MMM').format(entry.date);
        // Add year if not current year
        if (entry.date.year != DateTime.now().year) {
          label += " '${entry.date.year % 100}";
        }
      }

      final existing = groups[key];
      final income = (existing?.income ?? 0) +
          (entry.type == AccountingEntryType.income ? entry.amount : 0);
      final expense = (existing?.expense ?? 0) +
          (entry.type == AccountingEntryType.expense ? entry.amount : 0);

      groups[key] = _PeriodData(label: label, income: income, expense: expense);
    }

    // Sort by key (chronological)
    final sortedKeys = groups.keys.toList()..sort();
    return sortedKeys.map((k) => groups[k]!).toList();
  }

  int _weekNumber(DateTime date) {
    final dayOfYear = date.difference(DateTime(date.year, 1, 1)).inDays + 1;
    return ((dayOfYear - date.weekday + 10) / 7).floor();
  }

  @override
  Widget build(BuildContext context) {
    final periods = _groupEntries();
    if (periods.isEmpty) {
      return const SizedBox.shrink();
    }

    final currency = CurrencyFormat.byCode(currencyCode);
    final symbol = currency?.symbol ?? currencyCode;

    return SizedBox(
      height: 200,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: (periods.length * 72.0).clamp(200, double.infinity),
          child: CustomPaint(
            painter: _ChartPainter(
              periods: periods,
              currencySymbol: symbol,
              brightness: Theme.of(context).brightness,
            ),
            size: const Size(double.infinity, 200),
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<_PeriodData> periods;
  final String currencySymbol;
  final Brightness brightness;

  _ChartPainter({
    required this.periods,
    required this.currencySymbol,
    required this.brightness,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (periods.isEmpty) return;

    final textColor = brightness == Brightness.dark ? Colors.white70 : Colors.black87;
    final gridColor = brightness == Brightness.dark ? Colors.white12 : Colors.black12;

    // Layout
    const topPadding = 10.0;
    const bottomPadding = 40.0; // Space for labels + net
    final chartHeight = size.height - topPadding - bottomPadding;
    final barWidth = size.width / periods.length;
    const barGap = 4.0;
    final singleBarWidth = (barWidth - barGap * 3) / 2;

    // Find max value for scale
    double maxVal = 0;
    for (final p in periods) {
      if (p.income > maxVal) maxVal = p.income;
      if (p.expense > maxVal) maxVal = p.expense;
    }
    if (maxVal == 0) maxVal = 1;

    // Draw baseline
    final baselineY = topPadding + chartHeight;
    canvas.drawLine(
      Offset(0, baselineY),
      Offset(size.width, baselineY),
      Paint()..color = gridColor..strokeWidth = 1,
    );

    // Draw bars and labels
    for (int i = 0; i < periods.length; i++) {
      final p = periods[i];
      final x = i * barWidth;

      // Income bar (green)
      final incomeHeight = (p.income / maxVal) * chartHeight;
      final incomeRect = Rect.fromLTWH(
        x + barGap,
        baselineY - incomeHeight,
        singleBarWidth,
        incomeHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndCorners(incomeRect, topLeft: const Radius.circular(2), topRight: const Radius.circular(2)),
        Paint()..color = Colors.green.withValues(alpha: 0.7),
      );

      // Expense bar (red)
      final expenseHeight = (p.expense / maxVal) * chartHeight;
      final expenseRect = Rect.fromLTWH(
        x + barGap * 2 + singleBarWidth,
        baselineY - expenseHeight,
        singleBarWidth,
        expenseHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndCorners(expenseRect, topLeft: const Radius.circular(2), topRight: const Radius.circular(2)),
        Paint()..color = Colors.red.withValues(alpha: 0.7),
      );

      // Period label
      final labelPainter = TextPainter(
        text: TextSpan(
          text: p.label,
          style: TextStyle(color: textColor, fontSize: 10),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      labelPainter.paint(
        canvas,
        Offset(x + (barWidth - labelPainter.width) / 2, baselineY + 2),
      );

      // Net balance label
      final net = p.net;
      final netColor = net >= 0 ? Colors.green : Colors.red;
      final netSign = net >= 0 ? '+' : '';
      final netText = '$netSign${net.toStringAsFixed(0)}';
      final netPainter = TextPainter(
        text: TextSpan(
          text: netText,
          style: TextStyle(color: netColor, fontSize: 9, fontWeight: FontWeight.bold),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      netPainter.paint(
        canvas,
        Offset(x + (barWidth - netPainter.width) / 2, baselineY + 16),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) {
    return oldDelegate.periods != periods ||
        oldDelegate.currencySymbol != currencySymbol ||
        oldDelegate.brightness != brightness;
  }
}
