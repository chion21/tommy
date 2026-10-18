import 'package:flutter/material.dart';

import '../core/app_state.dart';

/// Light colours the person can pick in Settings → Light.
const lightColors = <String, Color>{
  'red': Color(0xFFFF2D55),
  'purple': Color(0xFFB04DFF),
  'blue': Color(0xFF2979FF),
  'cyan': Color(0xFF00E5FF),
  'green': Color(0xFF00E676),
  'gold': Color(0xFFFFC400),
  'pink': Color(0xFFFF6FAE),
  'white': Color(0xFFF5F5F5),
};

/// Soft neon light around the screen edge.
/// [mode]: 'theme' (one colour = the theme's colour, default), a key of [lightColors] (that one colour),
/// 'mix' (RGB: colours change all the time, like before), or 'off'.
/// It gently breathes while Tommy listens/talks; it is brighter while talking.
class EdgeGlow extends StatefulWidget {
  final List<Color> colors;
  final VoiceState state;
  final String mode;
  final Widget child;
  const EdgeGlow({super.key, required this.colors, required this.state, required this.child, this.mode = 'theme'});

  @override
  State<EdgeGlow> createState() => _EdgeGlowState();
}

class _EdgeGlowState extends State<EdgeGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 8))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static const _rgb = [
    Color(0xFFFF1744), Color(0xFFFF9100), Color(0xFFFFEA00), Color(0xFF00E676),
    Color(0xFF00E5FF), Color(0xFF2979FF), Color(0xFFD500F9),
  ];

  Color _color(double v) {
    if (widget.mode == 'mix') {
      final x = v * _rgb.length;
      final i = x.floor() % _rgb.length;
      return Color.lerp(_rgb[i], _rgb[(i + 1) % _rgb.length], x - x.floor())!;
    }
    return lightColors[widget.mode] ?? widget.colors.first;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == 'off') return widget.child;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final st = widget.state;
        final pulse = 0.5 + 0.5 * (1 - (2 * ((_c.value * 5) % 1) - 1).abs()); // 0..1 breathing
        final strength = switch (st) {
          VoiceState.idle => 0.25,
          VoiceState.listening => 0.35 + 0.15 * pulse,
          VoiceState.thinking => 0.45 + 0.2 * pulse,
          VoiceState.speaking => 0.55 + 0.3 * pulse,
        };
        final color = _color(_c.value);
        return Stack(children: [
          Positioned.fill(child: child!),
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: color.withValues(alpha: strength), width: 1.6),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(color: color.withValues(alpha: strength * 0.55), blurRadius: 6 + 8 * strength),
                  ],
                ),
              ),
            ),
          ),
        ]);
      },
    );
  }
}
