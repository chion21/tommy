import 'package:flutter/material.dart';

import '../core/app_state.dart';

/// What the assistant remembers — stored only in this person's own folder.
class MemoryScreen extends StatefulWidget {
  final AppState app;
  const MemoryScreen({super.key, required this.app});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final _ctrl = TextEditingController();

  Future<void> _add() async {
    try {
      await widget.app.addMemory(_ctrl.text);
      _ctrl.clear();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.app.err(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(app.t('memory'))),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      onSubmitted: (_) => _add(),
                      decoration: InputDecoration(hintText: app.t('memory_add_hint')),
                    ),
                  ),
                  IconButton(onPressed: _add, icon: const Icon(Icons.add_circle)),
                ]),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: app.memories.length,
                  itemBuilder: (_, i) {
                    final m = app.memories[i];
                    return ListTile(
                      leading: Icon(m['kind'] == 'shortcut' ? Icons.bolt : Icons.favorite_border),
                      title: Text(m['text'] as String),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => app.deleteMemory(m['id'] as String),
                      ),
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
