import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../base/step_clock.dart';
import '../../theme/app_theme.dart';

/// The app icon's π, softly breathing in the theme's muted text color.
/// Still where motion is turned down, and paused when its chat is hidden.
class PiThinkingIndicator extends StatefulWidget {
  const PiThinkingIndicator({super.key, this.size = 14, this.color});

  final double size;
  final Color? color;

  static const frameTime = Duration(milliseconds: 80);

  static const period = Duration(milliseconds: 2400);

  static double opacityAt(Duration elapsed) =>
      0.85 +
      0.15 *
          math.cos(
            2 *
                math.pi *
                (elapsed.inMicroseconds % period.inMicroseconds) /
                period.inMicroseconds,
          );

  @override
  State<PiThinkingIndicator> createState() => _PiThinkingIndicatorState();
}

class _PiThinkingIndicatorState extends State<PiThinkingIndicator> {
  final StepClock _clock = StepClock(PiThinkingIndicator.frameTime);
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = _clock.keepTo(context);
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _PiPainter(
          _clock,
          widget.color ?? AppColors.textMuted,
          still: _still,
        ),
      ),
    );
  }
}

class _PiPainter extends CustomPainter {
  _PiPainter(this.clock, this.color, {required this.still})
    : super(repaint: clock);

  final StepClock clock;
  final Color color;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..scale(size.shortestSide / 2);
    final paint = Paint()
      ..color = color.withValues(
        alpha:
            color.a * (still ? 1 : PiThinkingIndicator.opacityAt(clock.time)),
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.24
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final pi = Path()
      ..moveTo(-0.65, -0.55)
      ..lineTo(0.65, -0.55)
      ..moveTo(-0.36, -0.55)
      ..lineTo(-0.36, 0.55)
      ..moveTo(0.36, -0.55)
      ..lineTo(0.36, 0.2)
      ..quadraticBezierTo(0.36, 0.55, 0.65, 0.55);
    canvas.drawPath(pi, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PiPainter old) =>
      old.color != color || old.still != still;
}
