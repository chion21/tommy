import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Audio-style bar wave. `level` (0..1) will come from the live audio stream; for now it animates by itself.
class Waveform extends StatefulWidget {
  final Color color;
  final bool active;
  const Waveform({super.key, required this.color, required this.active});

  @override
  State<Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<Waveform> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          size: const Size(double.infinity, 46),
          painter: _WavePainter(_c.value, widget.color, widget.active),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final double v;
  final Color color;
  final bool active;
  _WavePainter(this.v, this.color, this.active);

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 48;
    final gap = size.width / bars;
    final p = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = gap * 0.45;
    for (var i = 0; i < bars; i++) {
      final x = i * gap + gap / 2;
      final envelope = math.sin(math.pi * i / bars); // taller in the middle
      final h = active
          ? (4 + 18 * envelope * (0.5 + 0.5 * math.sin(v * 2 * math.pi * 3 + i * 0.7)).abs())
          : 1.5;
      canvas.drawLine(Offset(x, size.height / 2 - h), Offset(x, size.height / 2 + h), p);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => true;
}
