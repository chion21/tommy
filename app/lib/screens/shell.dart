import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../widgets/character_art.dart';
import '../widgets/edge_glow.dart';
import '../widgets/orb.dart';
import '../widgets/waveform.dart';
import 'settings.dart';

/// Main screen. Phone / narrow window: bottom bar. PC / wide window (≥ 900 px): side bar on the left.
class Shell extends StatefulWidget {
  final AppState app;
  const Shell({super.key, required this.app});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  /// Demo cycle until the Gemini Live voice connection is added (next step).
  Future<void> _micPressed() async {
    final app = widget.app;
    if (!app.geminiActive) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(app.t('need_key'))));
      setState(() => _tab = 3);
      return;
    }
    if (app.voice != VoiceState.idle) {
      app.setVoice(VoiceState.idle);
      return;
    }
    for (final s in [VoiceState.listening, VoiceState.thinking, VoiceState.speaking]) {
      app.setVoice(s);
      await Future.delayed(const Duration(milliseconds: 1600));
      if (!mounted) return;
    }
    app.setVoice(VoiceState.idle);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final pages = [
      _Home(app: app),
      _Placeholder(text: app.t('coming_soon'), icon: Icons.chat_bubble_outline),
      _Placeholder(text: app.t('coming_soon'), icon: Icons.bolt),
      SettingsScreen(app: app),
    ];
    final items = [
      (Icons.home_rounded, 'home', 0),
      (Icons.chat_bubble_outline, 'chat', 1),
      (Icons.bolt, 'triggers', 2),
      (Icons.settings, 'settings', 3),
    ];

    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 900;
      final body = EdgeGlow(colors: app.theme.glow, state: app.voice, child: pages[_tab]);
      if (wide) {
        return Scaffold(
          body: SafeArea(
            child: Row(children: [
              _SideBar(app: app, items: items, index: _tab, onTab: (i) => setState(() => _tab = i), onMic: _micPressed),
              Expanded(child: Padding(padding: const EdgeInsets.all(8), child: body)),
            ]),
          ),
        );
      }
      return Scaffold(
        body: SafeArea(child: body),
        bottomNavigationBar: _BottomBar(
            app: app, items: items, index: _tab, onTab: (i) => setState(() => _tab = i), onMic: _micPressed),
      );
    });
  }
}

class _Home extends StatelessWidget {
  final AppState app;
  const _Home({required this.app});

  @override
  Widget build(BuildContext context) {
    final th = app.theme;
    final status = switch (app.voice) {
      VoiceState.idle => app.t('idle'),
      VoiceState.listening => app.t('listening'),
      VoiceState.thinking => app.t('thinking'),
      VoiceState.speaking => app.t('speaking'),
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(fit: StackFit.expand, children: [
        CharacterArt(c: app.character, showInitial: false),
        DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [th.background.withValues(alpha: 0.80), Colors.transparent, th.background.withValues(alpha: 0.90)],
        ))),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640), // keeps things tidy on a big PC screen
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(app.t('hello'), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                Text(app.t('subtitle'), style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
                const Spacer(),
                Center(child: CrystalOrb(color: th.primary, state: app.voice)),
                const SizedBox(height: 8),
                Center(child: Text(status, style: TextStyle(color: th.primary, fontWeight: FontWeight.w600))),
                const SizedBox(height: 8),
                Waveform(color: th.primary, active: app.voice == VoiceState.speaking || app.voice == VoiceState.listening),
                const Spacer(),
                TextField(
                  decoration: InputDecoration(
                    hintText: app.t('ask'),
                    filled: true,
                    fillColor: Colors.black.withValues(alpha: 0.45),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                    suffixIcon: Icon(Icons.send_rounded, color: th.primary),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _MicButton extends StatelessWidget {
  final AppState app;
  final VoidCallback onMic;
  final double size;
  const _MicButton({required this.app, required this.onMic, this.size = 60});

  @override
  Widget build(BuildContext context) {
    final c = app.theme.primary;
    return GestureDetector(
      onTap: onMic,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: c, width: 2),
          boxShadow: [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 16)],
        ),
        child: Icon(app.voice == VoiceState.idle ? Icons.graphic_eq : Icons.stop_rounded, color: c, size: size * 0.5),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const _NavItem({required this.icon, required this.label, required this.selected, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = selected ? color : Colors.white60;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: c),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, color: c), overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}

typedef _Item = (IconData, String, int);

class _BottomBar extends StatelessWidget {
  final AppState app;
  final List<_Item> items;
  final int index;
  final ValueChanged<int> onTab;
  final VoidCallback onMic;
  const _BottomBar({required this.app, required this.items, required this.index, required this.onTab, required this.onMic});

  @override
  Widget build(BuildContext context) {
    Widget item(_Item it) => Expanded(
        child: _NavItem(icon: it.$1, label: app.t(it.$2), selected: index == it.$3, color: app.theme.primary,
            onTap: () => onTab(it.$3)));
    return SafeArea(
      child: SizedBox(
        height: 76,
        child: Row(children: [
          item(items[0]),
          item(items[1]),
          Expanded(child: Center(child: _MicButton(app: app, onMic: onMic))),
          item(items[2]),
          item(items[3]),
        ]),
      ),
    );
  }
}

class _SideBar extends StatelessWidget {
  final AppState app;
  final List<_Item> items;
  final int index;
  final ValueChanged<int> onTab;
  final VoidCallback onMic;
  const _SideBar({required this.app, required this.items, required this.index, required this.onTab, required this.onMic});

  @override
  Widget build(BuildContext context) {
    Widget item(_Item it) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _NavItem(icon: it.$1, label: app.t(it.$2), selected: index == it.$3, color: app.theme.primary,
            onTap: () => onTab(it.$3)));
    return SizedBox(
      width: 96,
      child: Column(children: [
        const SizedBox(height: 16),
        Text(app.name, style: TextStyle(color: app.theme.primary, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
        const SizedBox(height: 24),
        item(items[0]),
        item(items[1]),
        const SizedBox(height: 12),
        _MicButton(app: app, onMic: onMic, size: 64),
        const SizedBox(height: 12),
        item(items[2]),
        const Spacer(),
        item(items[3]),
        const SizedBox(height: 16),
      ]),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final String text;
  final IconData icon;
  const _Placeholder({required this.text, required this.icon});
  @override
  Widget build(BuildContext context) =>
      Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 48), Text(text)]));
}
