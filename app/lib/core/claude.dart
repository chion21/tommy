import 'dart:convert';

import 'package:http/http.dart' as http;

import 'gemini.dart' show KeyCheck;

/// Claude (Anthropic API) as Tommy's brain: understands, decides and runs the actions (tools).
/// Hearing (speech → text) and the voice stay with Gemini, because Claude has no live voice.
/// Uses the person's own Claude API key from console.anthropic.com (billed separately from a Claude chat plan).
class ClaudeError implements Exception {
  final String code; // KEY_INVALID | QUOTA | NETWORK | FAILED
  final String detail;
  ClaudeError(this.code, [this.detail = '']);
  @override
  String toString() => 'Claude $code $detail';
}

const _api = 'https://api.anthropic.com/v1';
Map<String, String> _headers(String key) =>
    {'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json'};

/// Checks a Claude API key (lists models — no tokens used).
Future<KeyCheck> checkClaudeKey(String key) async {
  final k = key.trim();
  if (!k.startsWith('sk-ant-') || k.contains(' ')) return KeyCheck.invalid;
  try {
    final r = await http.get(Uri.parse('$_api/models?limit=1'), headers: _headers(k)).timeout(const Duration(seconds: 15));
    if (r.statusCode == 200) return KeyCheck.valid;
    if (r.statusCode == 401 || r.statusCode == 403) return KeyCheck.invalid;
    return KeyCheck.network;
  } catch (_) {
    return KeyCheck.network;
  }
}

/// Gemini-style function declarations → Claude tools (JSON Schema with lowercase types).
List<Map<String, dynamic>> claudeTools(List<Map<String, dynamic>> geminiFns) {
  dynamic conv(dynamic v) {
    if (v is Map) {
      return {
        for (final e in v.entries)
          e.key.toString(): e.key == 'type' && e.value is String ? (e.value as String).toLowerCase() : conv(e.value),
      };
    }
    if (v is List) return v.map(conv).toList();
    return v;
  }

  return [
    for (final f in geminiFns)
      {
        'name': f['name'],
        'description': f['description'],
        'input_schema': f['parameters'] == null ? {'type': 'object', 'properties': {}} : conv(f['parameters']),
      }
  ];
}

class ClaudeBrain {
  final String key;
  final bool smart; // true = Sonnet (smarter), false = Haiku (fastest, cheapest)
  String? _model;
  ClaudeBrain(this.key, {this.smart = false});

  String get model => _model ?? '?';

  Future<Map<String, dynamic>> _call(String method, String path, [Map<String, dynamic>? body]) async {
    http.Response r;
    try {
      final uri = Uri.parse('$_api/$path');
      r = method == 'GET'
          ? await http.get(uri, headers: _headers(key)).timeout(const Duration(seconds: 20))
          : await http.post(uri, headers: _headers(key), body: jsonEncode(body)).timeout(const Duration(seconds: 60));
    } catch (e) {
      throw ClaudeError('NETWORK', '$e');
    }
    final text = utf8.decode(r.bodyBytes);
    if (r.statusCode == 401 || r.statusCode == 403) throw ClaudeError('KEY_INVALID', text);
    if (r.statusCode == 429 || r.statusCode == 529 || text.contains('credit balance')) throw ClaudeError('QUOTA', text);
    if (r.statusCode >= 400) throw ClaudeError('FAILED', 'HTTP ${r.statusCode}: ${text.length > 300 ? text.substring(0, 300) : text}');
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// Newest Haiku (fast) or Sonnet (smart) this key can use.
  Future<String> _pick() async {
    if (_model != null) return _model!;
    final data = await _call('GET', 'models?limit=100');
    final ids = ((data['data'] as List?) ?? const []).map((m) => (m as Map)['id'].toString()).toList(); // newest first
    final want = smart ? 'sonnet' : 'haiku';
    final pick = ids.where((i) => i.contains(want)).toList();
    final any = pick.isNotEmpty ? pick : ids.where((i) => i.contains('sonnet') || i.contains('haiku')).toList();
    if (any.isEmpty && ids.isEmpty) throw ClaudeError('FAILED', 'no model');
    _model = any.isNotEmpty ? any.first : ids.first;
    return _model!;
  }

  /// One conversation turn with tools. [runTool] carries out each action and returns its result.
  /// Returns Tommy's spoken reply.
  Future<String> chat({
    required String system,
    required List<Map<String, String>> history, // {'role': 'user'|'model', 'text'}
    required String userText,
    required List<Map<String, dynamic>> tools,
    required Future<Map<String, dynamic>> Function(String name, Map<String, dynamic> args) runTool,
    void Function(String name)? onTool,
    void Function(String text)? onSayNow, // words before an action ("চালাচ্ছি…") — spoken right away
  }) async {
    final model = await _pick();
    // Claude needs alternating user/assistant messages starting with the user
    final messages = <Map<String, dynamic>>[];
    for (final h in history.length > 16 ? history.sublist(history.length - 16) : history) {
      final role = h['role'] == 'user' ? 'user' : 'assistant';
      final t = (h['text'] ?? '').trim();
      if (t.isEmpty) continue;
      if (messages.isEmpty && role != 'user') continue;
      if (messages.isNotEmpty && messages.last['role'] == role) {
        messages.last['content'] = '${messages.last['content']}\n$t';
      } else {
        messages.add({'role': role, 'content': t});
      }
    }
    if (messages.isNotEmpty && messages.last['role'] == 'user') {
      messages.last['content'] = '${messages.last['content']}\n$userText';
    } else {
      messages.add({'role': 'user', 'content': userText});
    }

    final spoken = StringBuffer();
    for (var step = 0; step < 8; step++) {
      final data = await _call('POST', 'messages', {
        'model': model,
        'max_tokens': 1024,
        'system': '$system\n\nYour reply is spoken aloud: short natural sentences, plain text only.',
        'messages': messages,
        'tools': tools,
      });
      final content = (data['content'] as List?) ?? const [];
      final results = <Map<String, dynamic>>[];
      final stepText = content
          .where((b) => (b as Map)['type'] == 'text')
          .map((b) => (b as Map)['text'].toString())
          .join(' ')
          .trim();
      if (data['stop_reason'] == 'tool_use') {
        if (stepText.isNotEmpty) onSayNow?.call(stepText);
      } else {
        spoken.write(stepText);
      }
      for (final b in content) {
        final m = b as Map;
        if (m['type'] == 'tool_use') {
          onTool?.call(m['name'].toString());
          Map<String, dynamic> res;
          try {
            res = await runTool(m['name'].toString(), Map<String, dynamic>.from((m['input'] as Map?) ?? const {}));
          } catch (e) {
            res = {'ok': false, 'error': '$e'};
          }
          results.add({'type': 'tool_result', 'tool_use_id': m['id'], 'content': jsonEncode(res)});
        }
      }
      if (data['stop_reason'] != 'tool_use' || results.isEmpty) break;
      messages.add({'role': 'assistant', 'content': content});
      messages.add({'role': 'user', 'content': results});
    }
    return spoken.toString().trim();
  }
}
