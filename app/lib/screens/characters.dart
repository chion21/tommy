import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/themes.dart';
import '../widgets/character_art.dart';

/// Separate page for choosing a character: big cards, tap to preview full screen, then "use".
class CharactersScreen extends StatefulWidget {
  final AppState app;
  const CharactersScreen({super.key, required this.app});

  @override
  State<CharactersScreen> createState() => _CharactersScreenState();
}

class _CharactersScreenState extends State<CharactersScreen> {
  late bool _girls = widget.app.character.female;

  void _preview(Character c) {
    final app = widget.app;
    Navigator.push(context, MaterialPageRoute(builder: (ctx) {
      final wide = MediaQuery.of(ctx).size.width > MediaQuery.of(ctx).size.height;
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          CharacterArt(c: c, wide: wide, showInitial: true),
          SafeArea(
            child: Column(children: [
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ),
              const Spacer(),
              Text(c.label, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.check),
                label: Text(app.t('use_character')),
                onPressed: () {
                  app.setPref('character', c.id);
                  Navigator.pop(ctx);
                },
              ),
              const SizedBox(height: 32),
            ]),
          ),
        ]),
      );
    }));
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final list = characters.where((c) => c.female == _girls).toList();
        final primary = app.theme.primary;
        return Scaffold(
          appBar: AppBar(title: Text(app.t('character'))),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: true, label: Text(app.t('girls'))),
                  ButtonSegment(value: false, label: Text(app.t('boys'))),
                ],
                selected: {_girls},
                onSelectionChanged: (s) => setState(() => _girls = s.first),
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220, childAspectRatio: 9 / 16, mainAxisSpacing: 12, crossAxisSpacing: 12),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final c = list[i];
                  final sel = app.character.id == c.id;
                  return GestureDetector(
                    onTap: () => _preview(c),
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: sel ? primary : Colors.white24, width: sel ? 3 : 1),
                      ),
                      child: Stack(fit: StackFit.expand, children: [
                        CharacterArt(c: c),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(8),
                            color: Colors.black54,
                            child: Text(sel ? '✓ ${c.label}' : c.label, textAlign: TextAlign.center,
                                style: TextStyle(fontWeight: FontWeight.w700, color: sel ? primary : Colors.white)),
                          ),
                        ),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ]),
        );
      },
    );
  }
}
