import 'dart:math';

import 'package:flutter/material.dart';

/// SoundCloud-inspired animated audio level bar.
///
/// Displays a row of thin vertical bars that scroll left, with new amplitude
/// values appended on the right. Useful for showing live audio activity in
/// conference calls, voice recording, etc.
class AudioLevelBar extends StatefulWidget {
  /// Current amplitude, 0.0 (silence) to 1.0 (max).
  final double amplitude;

  /// Number of bars to display.
  final int barCount;

  /// Total height of the bar area.
  final double height;

  /// Bar color — defaults to theme primary.
  final Color? color;

  const AudioLevelBar({
    super.key,
    required this.amplitude,
    this.barCount = 24,
    this.height = 24.0,
    this.color,
  });

  @override
  State<AudioLevelBar> createState() => _AudioLevelBarState();
}

class _AudioLevelBarState extends State<AudioLevelBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<double> _barHeights;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _barHeights = List.filled(widget.barCount, 0.05);
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    )..addListener(_updateBars);
    _controller.repeat();
  }

  void _updateBars() {
    if (!mounted) return;
    setState(() {
      for (int i = 0; i < _barHeights.length - 1; i++) {
        _barHeights[i] = _barHeights[i + 1];
      }
      final variation = _random.nextDouble() * 0.15 - 0.075;
      _barHeights[_barHeights.length - 1] =
          (widget.amplitude + variation).clamp(0.05, 1.0);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final count = _barHeights.length;
          final barWidth =
              (constraints.maxWidth - (count - 1) * 2) / count;

          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(count, (index) {
              final h = _barHeights[index];
              final barHeight = (h * widget.height).clamp(2.0, widget.height);

              return Padding(
                padding: EdgeInsets.only(right: index < count - 1 ? 2 : 0),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 50),
                  width: barWidth.clamp(2.0, 8.0),
                  height: barHeight,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.3 + h * 0.7),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
