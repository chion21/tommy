import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/app_state.dart';

/// Spinning crystal with tilted rings. Spins faster and pulses while the assistant is active.
class CrystalOrb extends StatefulWidget {
  final Color color;
  final VoiceState state;
  final double size;
  const CrystalOrb({super.key, required this.color, required this.state, this.size = 220});

  @override
  State<CrystalOrb> createState() => _CrystalOrbState();
}

class _CrystalOrbState extends State<CrystalOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 60))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          size: Size.square(widget.size),
          painter: _OrbPainter(_c.value * 60, widget.color, widget.state),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  final double t; // seconds
  final Color color;
  final VoiceState state;
  _OrbPainter(this.t, this.color, this.state);

  double get _speed => switch (state) {
        VoiceState.idle => 0.35,
        VoiceState.listening => 0.8,
        VoiceState.thinking => 1.8,
        VoiceState.speaking => 1.1,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final pulse = state == VoiceState.speaking
        ? 1 + 0.06 * math.sin(t * 12)
        : state == VoiceState.listening
            ? 1 + 0.03 * math.sin(t * 5)
            : 1.0;

    // soft glow
    canvas.drawCircle(c, r * 0.55 * pulse,
        Paint()..shader = RadialGradient(colors: [color.withValues(alpha: 0.45), Colors.transparent])
            .createShader(Rect.fromCircle(center: c, radius: r * 0.6)));

    // rings
    for (var i = 0; i < 2; i++) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(t * _speed * (i == 0 ? 0.6 : -0.45) + i * 0.9);
      final ring = Rect.fromCenter(center: Offset.zero, width: r * 1.8, height: r * (0.55 + 0.15 * i));
      canvas.drawOval(ring, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = color.withValues(alpha: 0.85 - 0.3 * i));
      // sparkle running along the ring
      final a = t * _speed * 2 + i * math.pi;
      canvas.drawCircle(Offset(math.cos(a) * ring.width / 2, math.sin(a) * ring.height / 2), 3.2,
          Paint()..color = Colors.white);
      canvas.restore();
    }

    // crystal: octahedron seen at an angle, rotating around its vertical axis
    final spin = t * _speed;
    final h = r * 0.42 * pulse, w = r * 0.30 * pulse;
    final top = c.translate(0, -h), bottom = c.translate(0, h * 0.9);
    final pts = List.generate(4, (k) {
      final a = spin + k * math.pi / 2;
      return Offset(c.dx + math.cos(a) * w, c.dy + math.sin(a) * w * 0.28);
    });
    for (var k = 0; k < 4; k++) {
      final p1 = pts[k], p2 = pts[(k + 1) % 4];
      final facing = math.sin(spin + k * math.pi / 2 + math.pi / 4); // fake lighting
      final shade = Color.lerp(color, Colors.white, (facing + 1) / 4)!;
      final dark = Color.lerp(color, Colors.black, 0.45)!;
      if ((p1.dy + p2.dy) / 2 >= c.dy - 0.01) {
        canvas.drawPath(Path()..addPolygon([top, p1, p2], true), Paint()..color = shade);
        canvas.drawPath(Path()..addPolygon([bottom, p1, p2], true), Paint()..color = dark);
      }
    }
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.5);
    for (final p in pts) {
      canvas.drawLine(top, p, edge);
    }
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) => true;
}
