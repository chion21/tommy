import 'package:flutter/material.dart';

import '../core/app_state.dart';

/// Neon light around the screen edge. Colour shows the state; while speaking it cycles
/// through the theme's colours and breathes.
class EdgeGlow extends StatefulWidget {
  final List<Color> colors;
  final VoiceState state;
  final Widget child;
  const EdgeGlow({super.key, required this.colors, required this.state, required this.child});

  @override
  State<EdgeGlow> createState() => _EdgeGlowState();
}

class _EdgeGlowState extends State<EdgeGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 8))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Color _color(double v) {
    final cs = widget.colors;
    switch (widget.state) {
      case VoiceState.idle:
        return cs.first.withValues(alpha: 0.35);
      case VoiceState.listening:
        return const Color(0xFF00E676);
      case VoiceState.thinking:
        return const Color(0xFF2979FF);
      case VoiceState.speaking:
        final x = v * cs.length;
        final i = x.floor() % cs.length;
        return Color.lerp(cs[i], cs[(i + 1) % cs.length], x - x.floor())!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final color = _color(_c.value);
        final breathe = widget.state == VoiceState.idle ? 0.0 : (0.5 + 0.5 * (1 - (2 * ((_c.value * 6) % 1) - 1).abs()));
        return Stack(children: [
          Positioned.fill(child: child!),
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: color, width: 3),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 14 + 10 * breathe, spreadRadius: 1)],
                ),
              ),
            ),
          ),
        ]);
      },
    );
  }
}
