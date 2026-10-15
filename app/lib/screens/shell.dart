import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../widgets/edge_glow.dart';
import '../widgets/orb.dart';
import '../widgets/waveform.dart';
import 'settings.dart';

/// Main screen with the bottom bar: Home, Chat, [mic], Triggers, Settings.
class Shell extends StatefulWidget {
  final AppState app;
  const Shell({super.key, required this.app});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  /// Demo cycle until the Gemini Live connection is plugged in (next build step).
  Future<void> _micPressed() async {
    final app = widget.app;
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
    return Scaffold(
      body: SafeArea(
        child: EdgeGlow(
          colors: app.theme.glow,
          state: app.voice,
          child: pages[_tab],
        ),
      ),
      bottomNavigationBar: _BottomBar(
        app: app,
        index: _tab,
        onTab: (i) => setState(() => _tab = i),
        onMic: _micPressed,
      ),
    );
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
    return Stack(fit: StackFit.expand, children: [
      // character art (falls back to a gradient until the image is added)
      Image.asset(th.characterAsset, fit: BoxFit.cover, errorBuilder: (_, __, ___) => DecoratedBox(
        decoration: BoxDecoration(gradient: RadialGradient(
            colors: [th.primary.withValues(alpha: 0.25), th.background], radius: 0.9)),
      )),
      DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [th.background.withValues(alpha: 0.75), Colors.transparent, th.background.withValues(alpha: 0.85)],
      ))),
      Padding(
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
    ]);
  }
}

class _BottomBar extends StatelessWidget {
  final AppState app;
  final int index;
  final ValueChanged<int> onTab;
  final VoidCallback onMic;
  const _BottomBar({required this.app, required this.index, required this.onTab, required this.onMic});

  @override
  Widget build(BuildContext context) {
    final c = app.theme.primary;
    Widget item(int i, IconData icon, String key) => Expanded(
          child: InkWell(
            onTap: () => onTab(i),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: index == i ? c : Colors.white60),
              Text(app.t(key), style: TextStyle(fontSize: 11, color: index == i ? c : Colors.white60)),
            ]),
          ),
        );
    return SafeArea(
      child: SizedBox(
        height: 72,
        child: Row(children: [
          item(0, Icons.home_rounded, 'home'),
          item(1, Icons.chat_bubble_outline, 'chat'),
          Expanded(
            child: GestureDetector(
              onTap: onMic,
              child: Container(
                width: 60, height: 60,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c, width: 2),
                    boxShadow: [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 16)]),
                child: Icon(app.voice == VoiceState.idle ? Icons.graphic_eq : Icons.stop_rounded, color: c, size: 30),
              ),
            ),
          ),
          item(2, Icons.bolt, 'triggers'),
          item(3, Icons.settings, 'settings'),
        ]),
      ),
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
