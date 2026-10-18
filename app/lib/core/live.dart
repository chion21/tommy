import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One function call Gemini asked us to run.
class LiveCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;
  LiveCall(this.id, this.name, this.args);
}

class LiveError implements Exception {
  final String code; // KEY_INVALID | QUOTA | NETWORK | FAILED
  final String detail;
  LiveError(this.code, [this.detail = '']);
  @override
  String toString() => 'Live $code $detail';
}

/// Gemini Live: a two-way, real-time voice connection. We stream the microphone in, Gemini streams its
/// voice back while it is still thinking — this is what makes replies start in about a second.
/// Protocol: wss BidiGenerateContent (JSON messages: setup → realtimeInput / clientContent / toolResponse).
class LiveSession {
  final String apiKey;
  final String model; // e.g. gemini-2.5-flash-native-audio-…
  final String system;
  final String voiceName;
  final List<Map<String, dynamic>> functions;
  final bool proactive; // let the model stay silent when speech isn't meant for it

  // callbacks
  final void Function(Uint8List pcm24k) onAudio;
  final void Function(String text) onHeard; // what the person said (piece by piece)
  final void Function(String text) onSaid; // what Tommy said (piece by piece)
  final void Function() onTurnComplete;
  final void Function() onInterrupted;
  final Future<Map<String, dynamic>> Function(LiveCall call) onCall;
  final void Function(Object error) onClosed;

  LiveSession({
    required this.apiKey,
    required this.model,
    required this.system,
    required this.voiceName,
    required this.functions,
    required this.onAudio,
    required this.onHeard,
    required this.onSaid,
    required this.onTurnComplete,
    required this.onInterrupted,
    required this.onCall,
    required this.onClosed,
    this.proactive = true,
  });

  WebSocket? _ws;
  bool _open = false;
  bool _closedByUs = false;
  DateTime lastActivity = DateTime.now();
  bool get isOpen => _open;

  Future<void> connect() async {
    final version = proactive ? 'v1alpha' : 'v1beta';
    final url = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.$version'
        '.GenerativeService.BidiGenerateContent?key=$apiKey';
    try {
      _ws = await WebSocket.connect(url).timeout(const Duration(seconds: 12));
    } catch (e) {
      throw LiveError('NETWORK', '$e');
    }
    _ws!.pingInterval = const Duration(seconds: 20);
    final ready = Completer<void>();
    _ws!.listen(
      (data) => _onMessage(data, ready),
      onDone: () {
        final wasOpen = _open;
        _open = false;
        final code = _ws?.closeCode;
        final reason = _ws?.closeReason ?? '';
        final err = _errorFor(code, reason);
        if (!ready.isCompleted) ready.completeError(err);
        if (wasOpen && !_closedByUs) onClosed(err);
      },
      onError: (e) {
        if (!ready.isCompleted) ready.completeError(LiveError('NETWORK', '$e'));
      },
      cancelOnError: false,
    );

    final setup = <String, dynamic>{
      'model': 'models/$model',
      'generationConfig': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {
          'voiceConfig': {'prebuiltVoiceConfig': {'voiceName': voiceName}},
        },
      },
      'systemInstruction': {'parts': [{'text': system}]},
      'tools': [
        {'functionDeclarations': functions},
        {'googleSearch': {}},
      ],
      'inputAudioTranscription': {},
      'outputAudioTranscription': {},
      'realtimeInputConfig': {
        'automaticActivityDetection': {
          'startOfSpeechSensitivity': 'START_SENSITIVITY_HIGH',
          'endOfSpeechSensitivity': 'END_SENSITIVITY_HIGH',
          'prefixPaddingMs': 120,
          'silenceDurationMs': 450,
        },
      },
      'contextWindowCompression': {'slidingWindow': {}},
      if (proactive) 'proactivity': {'proactiveAudio': true},
    };
    _send({'setup': setup});
    await ready.future.timeout(const Duration(seconds: 12), onTimeout: () => throw LiveError('NETWORK', 'setup timeout'));
    _open = true;
  }

  LiveError _errorFor(int? code, String reason) {
    final r = reason.toLowerCase();
    if (r.contains('quota') || r.contains('exhausted') || r.contains('rate')) return LiveError('QUOTA', reason);
    if (r.contains('api key') || r.contains('api_key') || r.contains('permission') || code == 1008 && r.contains('key')) {
      return LiveError('KEY_INVALID', reason);
    }
    if (code == null || code == 1006) return LiveError('NETWORK', reason);
    return LiveError('FAILED', 'close $code $reason');
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  void _onMessage(dynamic data, Completer<void> ready) {
    Map<String, dynamic> m;
    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      m = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (m.containsKey('setupComplete')) {
      if (!ready.isCompleted) ready.complete();
      return;
    }
    final sc = m['serverContent'] as Map<String, dynamic>?;
    if (sc != null) {
      lastActivity = DateTime.now();
      final inT = (sc['inputTranscription'] as Map?)?['text'];
      if (inT is String && inT.isNotEmpty) onHeard(inT);
      final outT = (sc['outputTranscription'] as Map?)?['text'];
      if (outT is String && outT.isNotEmpty) onSaid(outT);
      if (sc['interrupted'] == true) onInterrupted();
      final turn = sc['modelTurn'] as Map<String, dynamic>?;
      for (final p in (turn?['parts'] as List? ?? const [])) {
        final inline = (p as Map)['inlineData'] as Map?;
        final d = inline?['data'];
        if (d is String && d.isNotEmpty) onAudio(base64Decode(d));
      }
      if (sc['turnComplete'] == true) onTurnComplete();
    }
    final tc = m['toolCall'] as Map<String, dynamic>?;
    if (tc != null) {
      lastActivity = DateTime.now();
      for (final c in (tc['functionCalls'] as List? ?? const [])) {
        final call = LiveCall((c['id'] ?? '').toString(), (c['name'] ?? '').toString(),
            Map<String, dynamic>.from((c['args'] as Map?) ?? const {}));
        unawaited(_runCall(call));
      }
    }
    if (m.containsKey('goAway')) {
      // the server will close this connection soon; the app reconnects on the next speech
      _open = false;
    }
  }

  Future<void> _runCall(LiveCall c) async {
    Map<String, dynamic> result;
    try {
      result = await onCall(c);
    } catch (e) {
      result = {'ok': false, 'error': '$e'};
    }
    _send({
      'toolResponse': {
        'functionResponses': [
          {'id': c.id, 'name': c.name, 'response': result},
        ],
      },
    });
  }

  /// 16 kHz, 16-bit mono microphone audio.
  void sendAudio(Uint8List pcm16k) {
    if (!_open) return;
    lastActivity = DateTime.now();
    _send({
      'realtimeInput': {
        'audio': {'data': base64Encode(pcm16k), 'mimeType': 'audio/pcm;rate=16000'},
      },
    });
  }

  /// The mic paused (silence) — lets Gemini finish the turn without waiting.
  void audioEnded() {
    if (_open) _send({'realtimeInput': {'audioStreamEnd': true}});
  }

  /// Typed text, or an event like an incoming call.
  void sendText(String text) {
    if (!_open) return;
    lastActivity = DateTime.now();
    _send({
      'clientContent': {
        'turns': [
          {'role': 'user', 'parts': [{'text': text}]},
        ],
        'turnComplete': true,
      },
    });
  }

  Future<void> close() async {
    _closedByUs = true;
    _open = false;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
  }
}
