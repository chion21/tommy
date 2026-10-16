import 'package:flutter/material.dart';

import '../core/themes.dart';

/// Character picture; until the image file exists, shows a soft gradient with the name's initial.
class CharacterArt extends StatelessWidget {
  final Character c;
  final BoxFit fit;
  final bool showInitial;
  const CharacterArt({super.key, required this.c, this.fit = BoxFit.cover, this.showInitial = true});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      c.asset,
      fit: fit,
      errorBuilder: (_, __, ___) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(colors: [c.hint.withValues(alpha: 0.55), const Color(0xFF07070A)], radius: 0.95),
        ),
        child: showInitial
            ? Center(
                child: Text(c.label[0],
                    style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: Colors.white.withValues(alpha: 0.85))))
            : const SizedBox.expand(),
      ),
    );
  }
}
