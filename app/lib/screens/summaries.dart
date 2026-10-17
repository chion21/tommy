import 'package:flutter/material.dart';

import '../core/app_state.dart';

/// "What we talked about": every earlier conversation as short bullet points.
class SummariesScreen extends StatefulWidget {
  final AppState app;
  const SummariesScreen({super.key, required this.app});

  @override
  State<SummariesScreen> createState() => _SummariesScreenState();
}

class _SummariesScreenState extends State<SummariesScreen> {
  List<Map<String, dynamic>> _items = [];
  int _turns = 0;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = widget.app.archive;
    if (a == null) return;
    final items = await a.summaries();
    final turns = (await a.turns()).length;
    if (mounted) setState(() {
      _items = items.reversed.toList();
      _turns = turns;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Scaffold(
      appBar: AppBar(title: Text(app.t('history_title')), actions: [
        IconButton(
          tooltip: app.t('history_clear'),
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                content: Text(app.t('history_clear_q')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: Text(app.t('cancel'))),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(app.t('history_clear'))),
                ],
              ),
            );
            if (ok == true) {
              await app.clearHistory();
              await _load();
            }
          },
        ),
      ]),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text(app.t('history_hint', vars: {'n': '$_turns'}), style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: _working
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome),
                label: Text(app.t('history_now')),
                onPressed: _working || !app.geminiActive
                    ? null
                    : () async {
                        setState(() => _working = true);
                        await app.summariseFinished(includeCurrent: true);
                        await _load();
                        if (mounted) setState(() => _working = false);
                      },
              ),
            ),
            const SizedBox(height: 12),
            if (_items.isEmpty) Text(app.t('history_empty')),
            for (final s in _items)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text((s['from'] as String).substring(0, 16).replaceFirst('T', '  '),
                        style: TextStyle(color: app.theme.primary, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    for (final p in (s['points'] as List).cast<String>())
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('•  '),
                          Expanded(child: Text(p)),
                        ]),
                      ),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
