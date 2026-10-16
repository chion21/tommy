import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/gemini.dart';
import '../core/themes.dart';
import '../widgets/character_art.dart';
import 'characters.dart';
import 'memory.dart';

class SettingsScreen extends StatefulWidget {
  final AppState app;
  const SettingsScreen({super.key, required this.app});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _keyCtrl = TextEditingController();
  bool _checking = false;

  AppState get app => widget.app;

  void _toast(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _verifyKey() async {
    setState(() => _checking = true);
    final res = await app.activateGeminiKey(_keyCtrl.text);
    if (!mounted) return;
    setState(() => _checking = false);
    if (res == KeyCheck.valid) _keyCtrl.clear();
    _toast(app.t(switch (res) { KeyCheck.valid => 'key_ok', KeyCheck.invalid => 'key_bad', KeyCheck.network => 'key_net' }));
  }

  Future<String?> _ask(String title, String initial, {String? help, int? maxLength}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctrl, autofocus: true, maxLength: maxLength),
          if (help != null) Text(help),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(app.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: Text(app.t('save'))),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ...children,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final p = app.profile;
    final primary = app.theme.primary;
    const langNames = {'bn': 'বাংলা', 'en': 'English', 'hi': 'हिन्दी'};

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          // ---------- Gemini API key ----------
          Card(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: app.geminiActive ? Colors.greenAccent : Colors.redAccent, width: 1.2)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.key_rounded),
                  const SizedBox(width: 8),
                  Expanded(child: Text(app.t('gemini_title'), style: const TextStyle(fontWeight: FontWeight.w700))),
                  Chip(
                    label: Text(app.geminiActive ? app.t('active') : app.t('inactive')),
                    backgroundColor: (app.geminiActive ? Colors.green : Colors.red).withValues(alpha: 0.2),
                  ),
                ]),
                if (app.geminiActive) ...[
                  const SizedBox(height: 4),
                  Text(app.geminiMasked, style: const TextStyle(fontFamily: 'monospace')),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                        onPressed: app.removeGeminiKey, icon: const Icon(Icons.delete_outline), label: Text(app.t('remove_key'))),
                  ),
                ] else ...[
                  const SizedBox(height: 8),
                  Text(app.t('gemini_hint'), style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _keyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(hintText: 'AIza…', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    TextButton(
                      onPressed: () => launchUrl(Uri.parse('https://aistudio.google.com/apikey'),
                          mode: LaunchMode.externalApplication),
                      child: Text(app.t('get_key')),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _checking ? null : _verifyKey,
                      child: Text(_checking ? app.t('checking') : app.t('verify')),
                    ),
                  ]),
                ],
              ]),
            ),
          ),

          // ---------- profile ----------
          _section(app.t('profile'), [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(app.t('your_name')),
              subtitle: Text(app.userName),
              onTap: () async {
                final v = await _ask(app.t('your_name'), app.userName, maxLength: 40);
                if (v != null && v.isNotEmpty) await app.setPref('display_name', v);
              },
            ),
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: Text(app.t('assistant_name')),
              subtitle: Text('${app.name} · ${app.t('renames_left', vars: {'n': '${app.renamesLeft}'})}'),
              onTap: () async {
                final v = await _ask(app.t('assistant_name'), app.name,
                    maxLength: 20, help: app.t('renames_left', vars: {'n': '${app.renamesLeft}'}));
                if (v == null || v.isEmpty) return;
                try {
                  await app.rename(v);
                } catch (e) {
                  _toast(app.err(e));
                }
              },
            ),
          ]),

          // ---------- character (own page) ----------
          _section(app.t('character'), [
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CharactersScreen(app: app))),
              child: Container(
                height: 140,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: primary)),
                child: Row(children: [
                  SizedBox(width: 80, child: CharacterArt(c: app.character)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(app.character.label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(app.t('choose_character'), style: const TextStyle(color: Colors.white70)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right),
                  const SizedBox(width: 8),
                ]),
              ),
            ),
          ]),

          // ---------- colours ----------
          _section(app.t('theme'), [
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final th in tommyThemes)
                GestureDetector(
                  onTap: () => app.setPref('theme', th.id),
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [th.primary, th.background]),
                      border: Border.all(color: p['theme'] == th.id ? Colors.white : Colors.transparent, width: 3),
                    ),
                    alignment: Alignment.bottomCenter,
                    child: Text(th.label, style: const TextStyle(fontSize: 9)),
                  ),
                ),
            ]),
          ]),

          // ---------- voice ----------
          _section(app.t('voice'), [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in voices.entries)
                ChoiceChip(
                  label: Text('${e.key[0].toUpperCase()}${e.key.substring(1)} · ${app.t(e.value ? 'female' : 'male')}'),
                  selected: p['voice'] == e.key,
                  onSelected: (_) => app.setPref('voice', e.key),
                ),
            ]),
          ]),

          // ---------- languages ----------
          _section(app.t('app_language'), [
            ListTile(
              leading: const Icon(Icons.translate),
              title: Text(app.t('app_language')),
              trailing: DropdownButton<String>(
                value: p['ui_language'] as String,
                items: [for (final e in langNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) {
                  if (v != null) app.setPref('ui_language', v);
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.record_voice_over),
              title: Text(app.t('talk_language')),
              trailing: DropdownButton<String>(
                value: p['speech_language'] as String,
                items: [
                  DropdownMenuItem(value: 'auto', child: Text(app.t('auto'))),
                  for (final e in langNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) {
                  if (v != null) app.setPref('speech_language', v);
                },
              ),
            ),
          ]),

          // ---------- memory & account ----------
          _section(app.t('account'), [
            ListTile(
              leading: const Icon(Icons.psychology_alt_outlined),
              title: Text(app.t('memory')),
              subtitle: Text(app.t('memory_hint')),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MemoryScreen(app: app))),
            ),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(app.session?.provider == 'offline' ? app.t('offline_account') : (app.session?.email ?? '')),
            ),
            ListTile(leading: const Icon(Icons.logout), title: Text(app.t('logout')), onTap: app.logout),
          ]),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}
