import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// What Tommy decided after hearing something.
class BrainReply {
  final bool ignore; // speech was not meant for Tommy (hands-free mode)
  final String heard; // what the person said (transcript)
  final String reply; // what Tommy says back
  final String action; // none | open_url | youtube | web_search | open_app | call | whatsapp | answer_call | reject_call | stop
  final String arg;
  final String text;
  final String remember; // a fact worth saving to memory, or ''
  final String on; // here | pc | phone — which device should do the action
  const BrainReply({this.ignore = false, this.heard = '', this.reply = '', this.action = 'none', this.arg = '',
      this.text = '', this.remember = '', this.on = 'here'});
}

class BrainError implements Exception {
  final String code; // KEY_INVALID | QUOTA | NETWORK | NO_MODEL | FAILED
  final String detail;
  BrainError(this.code, [this.detail = '']);
  @override
  String toString() => '$code $detail';
}

/// Fastest Live voice models first (measured by tool/live_latency.py; see docs/live_latency.txt).
/// Measured 18 Oct 2026 (end of speech → first sound): gemini-3.8-live 0.6–1.0 s, 3.1-flash-live 0.7–1.4 s,
/// 2.5 native-audio 1.4–3.6 s.
const preferredLive = <String>[
  'gemini-3.8-live',
  'gemini-3.1-flash-live-preview',
  'gemini-2.5-flash-native-audio-preview-09-2025',
  'gemini-2.5-flash-native-audio-latest',
];

/// The sweet native-audio voice the person liked (v0.6 used "-latest").
const sweetLive = <String>[
  'gemini-2.5-flash-native-audio-latest',
  'gemini-2.5-flash-native-audio-preview-09-2025',
  'gemini-2.5-flash-native-audio-preview-12-2025',
];

/// Talks to Google Gemini with the person's own AI Studio key. Picks the best available models automatically.
class Brain {
  static const _api = 'https://generativelanguage.googleapis.com/v1beta';
  final String key;
  String? _chatModel;
  String? _ttsModel;
  String? _liveModel;
  List<String> _ttsModels = [];
  List<String> _liveModels = [];
  bool _ttsBroken = false;
  Brain(this.key);

  Future<Map<String, dynamic>> _call(String path, Map<String, dynamic>? body, {Duration timeout = const Duration(seconds: 40)}) async {
    http.Response r;
    try {
      final uri = Uri.parse('$_api/$path');
      final headers = {'Content-Type': 'application/json', 'x-goog-api-key': key};
      r = body == null
          ? await http.get(uri, headers: headers).timeout(timeout)
          : await http.post(uri, headers: headers, body: jsonEncode(body)).timeout(timeout);
    } catch (e) {
      throw BrainError('NETWORK', '$e');
    }
    final text = utf8.decode(r.bodyBytes);
    if (r.statusCode == 429) throw BrainError('QUOTA', text);
    if (r.statusCode == 400 && text.contains('API_KEY')) throw BrainError('KEY_INVALID', text);
    if (r.statusCode == 401 || r.statusCode == 403) throw BrainError('KEY_INVALID', text);
    if (r.statusCode >= 400) throw BrainError('FAILED', 'HTTP ${r.statusCode}: ${text.length > 300 ? text.substring(0, 300) : text}');
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> _pickModels() async {
    if (_chatModel != null) return;
    final data = await _call('models?pageSize=1000', null);
    final names = <String>[];
    final live = <String>[];
    for (final m in (data['models'] as List? ?? [])) {
      final methods = ((m as Map)['supportedGenerationMethods'] as List? ?? []).cast<String>();
      final n = (m['name'] as String).replaceFirst('models/', '');
      if (methods.contains('generateContent')) names.add(n);
      if (methods.contains('bidiGenerateContent')) live.add(n);
    }
    // real-time voice model: prefer "native audio" (most human voice), newest first
    const notChat = ['image', 'tts', 'transcribe', 'translate', 'robotics', 'thinking'];
    final okLive = live.where((n) => !notChat.any(n.contains)).toList()
      ..sort((a, b) {
        final pa = preferredLive.indexOf(a), pb = preferredLive.indexOf(b);
        if (pa != pb) return (pa < 0 ? 99 : pa) - (pb < 0 ? 99 : pb);
        return _rank(a).compareTo(_rank(b));
      });
    _liveModels = okLive;
    _liveModel = okLive.isEmpty ? null : okLive.first;
    bool bad(String n) => ['image', 'tts', 'live', 'embedding', 'audio', 'robotics', 'computer', 'learnlm', 'gemma', 'aqa']
        .any(n.contains);
    final chat = names.where((n) => n.contains('flash') && !bad(n)).toList()..sort((a, b) => _rank(a).compareTo(_rank(b)));
    if (chat.isEmpty) throw BrainError('NO_MODEL', names.join(','));
    _chatModel = chat.first;
    // newest flash TTS first (old preview TTS models can stop working)
    _ttsModels = names.where((n) => n.contains('tts')).toList()
      ..sort((a, b) {
        final fa = a.contains('flash') ? 0 : 1, fb = b.contains('flash') ? 0 : 1;
        if (fa != fb) return fa - fb;
        return _rank(a).compareTo(_rank(b));
      });
    _ttsModel = _ttsModels.isEmpty ? null : _ttsModels.first;
  }

  /// Newer + non-lite + non-preview first.
  int _rank(String n) {
    final v = RegExp(r'gemini-(\d+)(?:\.(\d+))?').firstMatch(n);
    final ver = v == null ? 0 : int.parse(v.group(1)!) * 10 + int.parse(v.group(2) ?? '0');
    var score = -ver * 10;
    if (n.contains('lite')) score += 3;
    if (n.contains('preview') || n.contains('exp')) score += 2;
    if (RegExp(r'-\d{2}-\d{2}').hasMatch(n) || RegExp(r'-\d{3}$').hasMatch(n)) score += 1;
    return score;
  }

  String get chatModel => _chatModel ?? '?';

  /// Gemini Live model for fast two-way voice, or null if this key has none.
  /// [sweet] = the "native audio" voice (the sweet, emotional one from v0.6, ~1.5 s);
  /// otherwise the fastest model (~0.8 s, plainer voice).
  Future<String?> liveModel({bool sweet = true}) async {
    await _pickModels();
    if (sweet) {
      for (final m in sweetLive) {
        if (_liveModels.contains(m)) return m;
      }
      final native = _liveModels.where((n) => n.contains('native-audio')).toList();
      if (native.isNotEmpty) return native.first;
    }
    return _liveModel;
  }

  /// Speech → text only (used when Claude is the brain). Empty if nothing was said.
  Future<String> transcribe(Uint8List wav) async {
    await _pickModels();
    final data = await _call('models/$_chatModel:generateContent', {
      'contents': [
        {
          'parts': [
            {'inlineData': {'mimeType': 'audio/wav', 'data': base64Encode(wav)}},
            {'text': 'Write down exactly what is said in this recording, in the original language and script '
                '(Bangla in Bangla script). If there is no clear speech (silence, noise, music, TV), return an empty string. '
                'Return only the words.'}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0,
        if (_chatModel!.startsWith('gemini-2.5')) 'thinkingConfig': {'thinkingBudget': 0},
      },
    }, timeout: const Duration(seconds: 25));
    final cands = (data['candidates'] as List?) ?? const [];
    if (cands.isEmpty) return '';
    final parts = (((cands.first as Map)['content'] as Map?)?['parts'] as List?) ?? const [];
    final t = parts.map((p) => ((p as Map)['text'] ?? '').toString()).join().trim();
    return t.replaceAll(RegExp(r'^["“]|["”]$'), '').trim();
  }

  /// Looks at a screenshot and answers a question about it (what windows/buttons are there, what went wrong…).
  Future<String> vision(Uint8List jpeg, String question) async {
    await _pickModels();
    final data = await _call('models/$_chatModel:generateContent', {
      'contents': [
        {
          'parts': [
            {'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(jpeg)}},
            {'text': 'This is a screenshot of the person\'s computer screen. $question\n'
                'Answer briefly and concretely: open windows/apps, visible buttons/fields, any error text.'}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.2,
        if (_chatModel!.startsWith('gemini-2.5')) 'thinkingConfig': {'thinkingBudget': 0},
      },
    }, timeout: const Duration(seconds: 40));
    final cands = (data['candidates'] as List?) ?? const [];
    if (cands.isEmpty) return '';
    final parts = (((cands.first as Map)['content'] as Map?)?['parts'] as List?) ?? const [];
    return parts.map((p) => ((p as Map)['text'] ?? '').toString()).join().trim();
  }

  /// Finds [target] on a screenshot → centre point in 0..1000 coordinates (x, y), or null.
  Future<(int, int)?> locate(Uint8List jpeg, String target) async {
    await _pickModels();
    final data = await _call('models/$_chatModel:generateContent', {
      'contents': [
        {
          'parts': [
            {'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(jpeg)}},
            {'text': 'Find this on the screenshot: "$target". Return its centre point as x and y in 0-1000 '
                'normalised coordinates (0,0 = top-left, 1000,1000 = bottom-right). found=false if it is not visible.'}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0,
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'OBJECT',
          'properties': {'found': {'type': 'BOOLEAN'}, 'x': {'type': 'INTEGER'}, 'y': {'type': 'INTEGER'}},
          'required': ['found'],
        },
        if (_chatModel!.startsWith('gemini-2.5')) 'thinkingConfig': {'thinkingBudget': 0},
      },
    }, timeout: const Duration(seconds: 40));
    final cands = (data['candidates'] as List?) ?? const [];
    if (cands.isEmpty) return null;
    final parts = (((cands.first as Map)['content'] as Map?)?['parts'] as List?) ?? const [];
    try {
      final j = jsonDecode(parts.map((p) => ((p as Map)['text'] ?? '').toString()).join()) as Map;
      if (j['found'] != true) return null;
      return ((j['x'] as num).round(), (j['y'] as num).round());
    } catch (_) {
      return null;
    }
  }

  /// Looks things up on the web (Google Search) and answers as neat bullet points.
  /// [deep] = a longer, more thorough report.
  Future<String> research(String question, {bool deep = false, String language = 'auto'}) async {
    await _pickModels();
    final lang = switch (language) {
      'bn' => 'Write in Bangla.',
      'en' => 'Write in English.',
      'hi' => 'Write in Hindi.',
      _ => 'Write in the language of the question (Bangla question → Bangla answer).',
    };
    final ask = deep
        ? 'Do deep research on this using Google Search. Check several sources. Then write a well-organised report: '
            'a 1-2 line summary first, then short headed sections with bullet points (•), important numbers/dates, '
            'pros/cons or options if relevant, and a final "সিদ্ধান্ত / Conclusion" line. Be accurate; say if sources disagree. $lang\n\nQuestion: $question'
        : 'Research this using Google Search and answer clearly in 3-8 bullet points (•), most important first, '
            'with key numbers/dates. Be accurate. $lang\n\nQuestion: $question';
    final data = await _call('models/$_chatModel:generateContent', {
      'contents': [
        {'parts': [{'text': ask}]}
      ],
      'tools': [
        {'google_search': {}}
      ],
      'generationConfig': {
        'temperature': 0.4,
        if (!deep && _chatModel!.startsWith('gemini-2.5')) 'thinkingConfig': {'thinkingBudget': 0},
      },
    }, timeout: Duration(seconds: deep ? 120 : 45));
    final cands = (data['candidates'] as List?) ?? const [];
    if (cands.isEmpty) return '';
    final c = cands.first as Map;
    final parts = ((c['content'] as Map?)?['parts'] as List?) ?? const [];
    var text = parts.map((p) => ((p as Map)['text'] ?? '').toString()).join().trim();
    final chunks = ((c['groundingMetadata'] as Map?)?['groundingChunks'] as List?) ?? const [];
    final sources = <String>[];
    for (final ch in chunks) {
      final w = (ch as Map)['web'] as Map?;
      final title = (w?['title'] ?? '').toString();
      if (title.isNotEmpty && !sources.contains(title)) sources.add(title);
      if (sources.length >= 5) break;
    }
    if (sources.isNotEmpty) text += '\n\nউৎস / Sources: ${sources.join(', ')}';
    return text;
  }

  static final _schema = {
    'type': 'OBJECT',
    'properties': {
      'ignore': {'type': 'BOOLEAN'},
      'heard': {'type': 'STRING'},
      'reply': {'type': 'STRING'},
      'action': {
        'type': 'STRING',
        'enum': ['none', 'open_url', 'youtube', 'web_search', 'research', 'deep_research', 'open_app', 'call', 'whatsapp',
            'answer_call', 'reject_call', 'recall', 'stop'],
      },
      'arg': {'type': 'STRING'},
      'text': {'type': 'STRING'},
      'remember': {'type': 'STRING'},
      'on': {'type': 'STRING', 'enum': ['here', 'pc', 'phone']},
    },
    'required': ['ignore', 'heard', 'reply', 'action'],
  };

  /// One turn of conversation. Give either [wav] (recorded speech) or [typed] text.
  Future<BrainReply> think({
    required String system,
    required List<Map<String, String>> history, // [{'role': 'user'|'model', 'text': ...}]
    Uint8List? wav,
    String? typed,
    String? event, // e.g. an incoming call waiting for an answer
  }) async {
    await _pickModels();
    final contents = <Map<String, dynamic>>[
      for (final h in history.length > 16 ? history.sublist(history.length - 16) : history)
        {'role': h['role'], 'parts': [{'text': h['text']}]},
    ];
    final parts = <Map<String, dynamic>>[];
    if (event != null && event.isNotEmpty) parts.add({'text': '[Current event: $event]'});
    if (wav != null) {
      parts.add({'inlineData': {'mimeType': 'audio/wav', 'data': base64Encode(wav)}});
    } else {
      parts.add({'text': typed ?? ''});
    }
    contents.add({'role': 'user', 'parts': parts});

    final gen = <String, dynamic>{
      'temperature': 0.9,
      'maxOutputTokens': 1024,
      'responseMimeType': 'application/json',
      'responseSchema': _schema,
    };
    if (_chatModel!.startsWith('gemini-2.5')) gen['thinkingConfig'] = {'thinkingBudget': 0}; // faster answers
    final data = await _call('models/$_chatModel:generateContent', {
      'systemInstruction': {'parts': [{'text': system}]},
      'contents': contents,
      'generationConfig': gen,
    });
    final cands = (data['candidates'] as List?) ?? const [];
    final first = cands.isEmpty ? null : cands.first as Map?;
    final partsOut = ((first?['content'] as Map?)?['parts'] as List?) ?? const [];
    final text = partsOut.map((p) => ((p as Map)['text'] ?? '').toString()).join();
    Map<String, dynamic> j;
    try {
      j = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return BrainReply(heard: typed ?? '', reply: text.trim());
    }
    return BrainReply(
      ignore: j['ignore'] == true,
      heard: (j['heard'] ?? '').toString(),
      reply: (j['reply'] ?? '').toString(),
      action: (j['action'] ?? 'none').toString(),
      arg: (j['arg'] ?? '').toString(),
      text: (j['text'] ?? '').toString(),
      remember: (j['remember'] ?? '').toString(),
      on: (j['on'] ?? 'here').toString(),
    );
  }

  /// Turns one finished conversation into short bullet points worth remembering (same language as the talk).
  Future<List<String>> summarise(String transcript) async {
    await _pickModels();
    final data = await _call('models/$_chatModel:generateContent', {
      'contents': [
        {
          'parts': [
            {
              'text': 'Summarise this conversation between a person and their assistant as 1-6 short bullet points '
                  'worth remembering later: what they talked about, decisions, plans, promises, names, dates, feelings. '
                  'Write in the language the person used (Bangla stays Bangla). Skip greetings and small talk. '
                  'Never include passwords, PINs, OTPs or card/bank numbers. Return a JSON array of strings.\n\n$transcript'
            }
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.3,
        'responseMimeType': 'application/json',
        'responseSchema': {'type': 'ARRAY', 'items': {'type': 'STRING'}},
        if (_chatModel!.startsWith('gemini-2.5')) 'thinkingConfig': {'thinkingBudget': 0},
      },
    });
    final cands = (data['candidates'] as List?) ?? const [];
    if (cands.isEmpty) return [];
    final parts = (((cands.first as Map)['content'] as Map?)?['parts'] as List?) ?? const [];
    final text = parts.map((p) => ((p as Map)['text'] ?? '').toString()).join();
    try {
      return (jsonDecode(text) as List).map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  /// Natural voice from Gemini TTS → WAV bytes, or null (caller then uses the device voice).
  Future<Uint8List?> speak(String text, String voiceName, {String style = ''}) async {
    if (_ttsBroken || text.trim().isEmpty) return null;
    await _pickModels();
    if (_ttsModel == null) return null;
    try {
      final data = await _call('models/$_ttsModel:generateContent', {
        'contents': [
          {'parts': [{'text': style.isEmpty ? text : '$style: $text'}]}
        ],
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {'voiceConfig': {'prebuiltVoiceConfig': {'voiceName': voiceName}}},
        },
      }, timeout: const Duration(seconds: 30));
      for (final c in (data['candidates'] as List? ?? [])) {
        for (final p in (((c as Map)['content'] as Map?)?['parts'] as List? ?? [])) {
          final inline = (p as Map)['inlineData'] as Map?;
          if (inline != null && inline['data'] != null) {
            final pcm = base64Decode(inline['data'] as String);
            final mime = (inline['mimeType'] ?? '') as String;
            final rate = int.tryParse(RegExp(r'rate=(\d+)').firstMatch(mime)?.group(1) ?? '') ?? 24000;
            return mime.contains('wav') ? pcm : wavFromPcm16(pcm, rate);
          }
        }
      }
    } on BrainError catch (e) {
      if (e.code == 'KEY_INVALID') rethrow;
      if (e.code == 'FAILED') {
        // this TTS model doesn't work → try the next one next time; none left → device voice
        _ttsModels.remove(_ttsModel);
        _ttsModel = _ttsModels.isEmpty ? null : _ttsModels.first;
        _ttsBroken = _ttsModel == null;
      }
    }
    return null;
  }
}

Uint8List wavFromPcm16(Uint8List pcm, int rate, {int channels = 1}) {
  final b = BytesBuilder();
  void str(String s) => b.add(ascii.encode(s));
  void u32(int v) => b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) => b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));
  str('RIFF');
  u32(36 + pcm.length);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1);
  u16(channels);
  u32(rate);
  u32(rate * channels * 2);
  u16(channels * 2);
  u16(16);
  str('data');
  u32(pcm.length);
  b.add(pcm);
  return b.toBytes();
}
