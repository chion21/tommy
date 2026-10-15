import 'package:flutter/material.dart';

import '../core/app_state.dart';

/// Shows what the assistant remembers. The user can add or delete items.
class MemoryScreen extends StatefulWidget {
  final AppState app;
  const MemoryScreen({super.key, required this.app});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  List<dynamic> _items = [];
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.app.api.memories();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      _toast(widget.app.err(e));
    }
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _add() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    try {
      await widget.app.api.addMemory('personal', text);
      _ctrl.clear();
      await _load();
    } catch (e) {
      _toast(widget.app.err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Scaffold(
      appBar: AppBar(title: Text(app.t('memory'))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(child: TextField(controller: _ctrl, decoration: InputDecoration(hintText: app.t('memory_hint')))),
            IconButton(onPressed: _add, icon: const Icon(Icons.add_circle)),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _items.length,
            itemBuilder: (_, i) {
              final m = _items[i] as Map;
              return ListTile(
                leading: Icon(m['kind'] == 'shortcut' ? Icons.bolt : Icons.favorite_border),
                title: Text(m['text'] as String),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await app.api.deleteMemory(m['id'] as String);
                    await _load();
                  },
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
