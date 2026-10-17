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
  const BrainReply({this.ignore = false, this.heard = '', this.reply = '', this.action = 'none', this.arg = '',
      this.text = '', this.remember = ''});
}

class BrainError implements Exception {
  final String code; // KEY_INVALID | QUOTA | NETWORK | NO_MODEL | FAILED
  final String detail;
  BrainError(this.code, [this.detail = '']);
  @override
  String toString() => '$code $detail';
}

/// Talks to Google Gemini with the person's own AI Studio key. Picks the best available models automatically.
class Brain {
  static const _api = 'https://generativelanguage.googleapis.com/v1beta';
  final String key;
  String? _chatModel;
  String? _ttsModel;
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
    for (final m in (data['models'] as List? ?? [])) {
      final methods = ((m as Map)['supportedGenerationMethods'] as List? ?? []).cast<String>();
      if (methods.contains('generateContent')) names.add((m['name'] as String).replaceFirst('models/', ''));
    }
    bool bad(String n) => ['image', 'tts', 'live', 'embedding', 'audio', 'robotics', 'computer', 'learnlm', 'gemma', 'aqa']
        .any(n.contains);
    final chat = names.where((n) => n.contains('flash') && !bad(n)).toList()..sort((a, b) => _rank(a).compareTo(_rank(b)));
    if (chat.isEmpty) throw BrainError('NO_MODEL', names.join(','));
    _chatModel = chat.first;
    final tts = names.where((n) => n.contains('tts')).toList()
      ..sort((a, b) => (a.contains('flash') ? 0 : 1).compareTo(b.contains('flash') ? 0 : 1));
    _ttsModel = tts.isEmpty ? null : tts.first;
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

  static final _schema = {
    'type': 'OBJECT',
    'properties': {
      'ignore': {'type': 'BOOLEAN'},
      'heard': {'type': 'STRING'},
      'reply': {'type': 'STRING'},
      'action': {
        'type': 'STRING',
        'enum': ['none', 'open_url', 'youtube', 'web_search', 'open_app', 'call', 'whatsapp', 'answer_call', 'reject_call', 'stop'],
      },
      'arg': {'type': 'STRING'},
      'text': {'type': 'STRING'},
      'remember': {'type': 'STRING'},
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
    );
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
      if (e.code == 'QUOTA' || e.code == 'FAILED') _ttsBroken = e.code == 'FAILED'; // quota: try again later
      if (e.code == 'KEY_INVALID') rethrow;
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
