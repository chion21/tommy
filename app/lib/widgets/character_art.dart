import 'package:flutter/material.dart';

import '../core/themes.dart';

/// Character picture. [wide] = use the landscape PC picture; otherwise the portrait phone one.
/// If the picture is missing, falls back to the other shape, then to a soft gradient with the initial.
class CharacterArt extends StatelessWidget {
  final Character c;
  final bool wide;
  final BoxFit fit;
  final bool showInitial;
  final Alignment alignment;
  const CharacterArt({super.key, required this.c, this.wide = false, this.fit = BoxFit.cover,
      this.showInitial = true, this.alignment = Alignment.center});

  Widget _placeholder() => DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(colors: [c.hint.withValues(alpha: 0.55), const Color(0xFF07070A)], radius: 0.95),
        ),
        child: showInitial
            ? Center(
                child: Text(c.label[0],
                    style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: Colors.white.withValues(alpha: 0.85))))
            : const SizedBox.expand(),
      );

  @override
  Widget build(BuildContext context) {
    final first = wide ? c.pcAsset : c.phoneAsset;
    final second = wide ? c.phoneAsset : c.pcAsset;
    return Image.asset(
      first,
      fit: fit,
      alignment: alignment,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, __, ___) => Image.asset(second, fit: fit, alignment: alignment,
          filterQuality: FilterQuality.high, errorBuilder: (_, __, ___) => _placeholder()),
    );
  }
}
