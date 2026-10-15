import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/themes.dart';
import 'memory.dart';

class SettingsScreen extends StatelessWidget {
  final AppState app;
  const SettingsScreen({super.key, required this.app});

  void _toast(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(text: app.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(app.t('assistant_name')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctrl, maxLength: 20, autofocus: true),
          Text(app.t('renames_left', vars: {'n': '${app.assistant['renames_left']}'})),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: Text(app.t('save')))],
      ),
    );
    if (newName == null || newName.isEmpty || newName == app.name) return;
    try {
      await app.rename(newName);
      // Next step in the build: open the wake-word recording screen ("হেই <name>" ×5) here.
    } catch (e) {
      if (context.mounted) _toast(context, app.err(e));
    }
  }

  Future<void> _redeem(BuildContext context) async {
    final ctrl = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(app.t('license_key')),
        content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'TOMMY-XXXX-XXXX-XXXX')),
        actions: [FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: Text(app.t('activate')))],
      ),
    );
    if (key == null || key.trim().isEmpty) return;
    try {
      await app.api.redeem(key);
      await app.refresh();
    } catch (e) {
      if (context.mounted) _toast(context, app.err(e));
    }
  }

  Future<void> _set(BuildContext context, String k, String v) async {
    try {
      await app.setPref(k, v);
    } catch (e) {
      if (context.mounted) _toast(context, app.err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = app.assistant;
    final usage = (app.me['usage'] as Map?) ?? const {};
    final minsLeft = ((usage['ai_seconds_left'] ?? 0) as num) ~/ 60;
    final voices = ((a['options'] as Map?)?['voices'] as Map?) ??
        const {'aoede': 'female', 'kore': 'female', 'leda': 'female', 'puck': 'male', 'charon': 'male'};
    const langNames = {'bn': 'বাংলা', 'en': 'English', 'hi': 'हिन्दी'};

    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          leading: const Icon(Icons.workspace_premium),
          title: Text('${app.t('plan')}: ${app.me['plan'] ?? '-'}'),
          subtitle: Text(app.t('ai_minutes_left', vars: {'n': '$minsLeft'})),
          trailing: TextButton(onPressed: () => _redeem(context), child: Text(app.t('activate'))),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.badge_outlined),
        title: Text(app.t('assistant_name')),
        subtitle: Text('${app.name} · ${app.t('renames_left', vars: {'n': '${a['renames_left']}'})}'),
        onTap: () => _rename(context),
      ),
      const Divider(),
      Text(app.t('theme'), style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final th in tommyThemes)
          GestureDetector(
            onTap: () => _set(context, 'theme', th.id),
            child: Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [th.primary, th.background]),
                border: Border.all(color: a['theme'] == th.id ? Colors.white : Colors.transparent, width: 3),
              ),
              alignment: Alignment.bottomCenter,
              child: Text(th.label, style: const TextStyle(fontSize: 10)),
            ),
          ),
      ]),
      const Divider(),
      Text(app.t('voice'), style: Theme.of(context).textTheme.titleMedium),
      Wrap(spacing: 8, children: [
        for (final e in voices.entries)
          ChoiceChip(
            label: Text('${e.key[0].toUpperCase()}${e.key.substring(1)} · ${app.t(e.value as String)}'),
            selected: a['voice'] == e.key,
            onSelected: (_) => _set(context, 'voice', e.key),
          ),
      ]),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.translate),
        title: Text(app.t('app_language')),
        trailing: DropdownButton<String>(
          value: a['ui_language'] as String? ?? 'bn',
          items: [for (final e in langNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => v == null ? null : _set(context, 'ui_language', v),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.record_voice_over),
        title: Text(app.t('talk_language')),
        trailing: DropdownButton<String>(
          value: a['speech_language'] as String? ?? 'auto',
          items: [
            DropdownMenuItem(value: 'auto', child: Text(app.t('auto'))),
            for (final e in langNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) => v == null ? null : _set(context, 'speech_language', v),
        ),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.psychology_alt_outlined),
        title: Text(app.t('memory')),
        subtitle: Text(app.t('memory_hint')),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MemoryScreen(app: app))),
      ),
      ListTile(leading: const Icon(Icons.logout), title: Text(app.t('logout')), onTap: app.logout),
    ]);
  }
}
