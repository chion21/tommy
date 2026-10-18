import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'actions.dart';
import 'archive.dart';
import 'auth.dart';
import 'brain.dart';
import 'gemini.dart';
import 'link.dart';
import 'live.dart';
import 'native.dart';
import 'pc.dart';
import 'persona.dart';
import 'speaker.dart';
import 'store.dart';
import 'strings.dart';
import 'themes.dart';
import 'tools.dart';
import 'voice.dart';

enum VoiceState { idle, listening, thinking, speaking }

class AppError implements Exception {
  final String code;
  AppError(this.code);
}

const maxRenames = 5;
const maxMemories = 100;

const _defaults = <String, dynamic>{
  'assistant_name': 'টমি',
  'renames_used': 0,
  'theme': 'crimson',
  'character': 'f1',
  'voice': 'aoede',
  'ui_language': 'bn',
  'speech_language': 'auto',
  'display_name': '',
  'persona': 'agent',
  'call_me': 'স্যার',
  'hands_free': true, // keep listening and answer when called by name
  'announce': true, // say incoming calls/messages aloud (Android)
  'license_key': '',
  'light': 'theme', // edge light: theme | a colour | mix (RGB) | off
  'live_mode': true,
  'voice_quality': 'sweet', // sweet = native-audio voice (as in v0.6) · fast = quickest model, plainer voice // Gemini Live: replies start in ~1 s and tasks run as functions
};

const voices = <String, bool>{'aoede': true, 'kore': true, 'leda': true, 'puck': false, 'charon': false}; // true = female

final _card = RegExp(r'(?:\d[ -]?){12,19}');
final _secretWords = RegExp(r'(password|passcode|\bpin\b|otp|cvv|পাসওয়ার্ড|পিন|ওটিপি|पासवर्ड)', caseSensitive: false);
bool isSensitive(String t) => _card.hasMatch(t) || _secretWords.hasMatch(t);

final licenseFormat = RegExp(r'^TOMMY-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$');

/// Everything the UI needs. All personal data lives in the logged-in person's own folder.
class AppState extends ChangeNotifier {
  final auth = Auth();
  final store = Store();
  final io = VoiceIO();

  bool ready = false;
  Session? session;
  Map<String, dynamic> profile = Map.of(_defaults);
  List<Map<String, dynamic>> memories = [];
  List<Map<String, String>> chat = []; // {'role': 'user'|'model', 'text': ...}
  bool geminiActive = false;
  String geminiMasked = '';
  VoiceState voice = VoiceState.idle;
  String status = ''; // short line under the orb (errors, hints)

  Brain? _brain;
  bool _loopOn = false;
  bool _busy = false;
  String? _pendingEvent; // incoming call/message waiting for the person's decision
  StreamSubscription? _eventsSub;
  DeviceLink? link;
  ChatArchive? archive;
  List<String> pastPoints = []; // summaries of earlier conversations (in every prompt)
  bool _summarising = false;
  Pairing? pendingPairing; // PC: QR being shown, waiting for the phone
  final Map<String, DateTime> _recentEvents = {};
  DateTime? _qrShownAt; // PC: when the QR was shown (a phone may log in with it for 5 minutes)

  // ---- Gemini Live (fast voice) ----
  final _mic = LiveMic();
  final _speaker = PcmSpeaker();
  LiveSession? _live;
  Future<bool>? _connecting;
  Completer<bool>? _liveExit; // completes when the live loop should end (true = stopped by the person)
  DateTime _liveBlockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _liveUnavailable = false; // this key has no Live model
  bool _fastOk = true; // thinking-off setting accepted by the model
  final List<Uint8List> _held = []; // answer audio held back until we know it was meant for Tommy
  bool _turnAllowed = false;
  final List<Uint8List> _preroll = [];
  final List<Uint8List> _queued = [];
  bool _sending = false;
  DateTime _lastLoud = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _segStart = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastHeard = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTalk = DateTime.fromMillisecondsSinceEpoch(0);
  double _noise = -50, _echo = -60;
  final _heardBuf = StringBuffer();
  final _saidBuf = StringBuffer();
  bool _turnHadAudio = false;
  Timer? _liveTimer;
  Timer? _backToListen;
  final List<DateTime> _liveFailures = [];
  String liveModelName = '';
  int lastLatencyMs = 0; // end of the person's speech → first sound of the answer
  bool _latencyMeasured = false;
  bool get liveOn => _live?.isOpen ?? false;
  int _loopGen = 0;

  bool get loggedIn => session != null;
  String get uid => session!.uid;
  String get lang => profile['ui_language'] as String;
  String get name => profile['assistant_name'] as String;
  int get renamesLeft => maxRenames - (profile['renames_used'] as int);
  bool get listeningLoop => _loopOn;
  String get userName {
    final n = (profile['display_name'] as String).trim();
    if (n.isNotEmpty) return n;
    if (session != null && session!.displayName.isNotEmpty) return session!.displayName;
    return session?.email.split('@').first ?? '';
  }

  TommyTheme get theme => themeById(profile['theme'] as String);
  Character get character => characterById(profile['character'] as String);
  bool get voiceFemale => voices[profile['voice']] ?? true;
  bool get linked => link != null;
  bool get peerOnline => link?.peerOnline ?? false;
  String get peerLabel => link == null ? '' : (link!.peerName.isNotEmpty ? link!.peerName : link!.peer.toUpperCase());

  String t(String key, {Map<String, String> vars = const {}}) =>
      tr(lang, key, vars: {'name': name, 'user': userName, ...vars});
  String err(Object e) => e is AuthError
      ? trError(lang, e.code)
      : e is AppError
          ? trError(lang, e.code)
          : e is BrainError
              ? trError(lang, 'AI_${e.code}')
              : e.toString();

  // ---------- start / login ----------
  Future<void> init() async {
    session = await store.loadSession();
    if (session != null) await _loadUser();
    ready = true;
    notifyListeners();
  }

  Future<void> _loadUser() async {
    final saved = await store.readJson(uid, 'profile.json');
    profile = {..._defaults, ...saved};
    if (profile['persona'] == 'partner') profile['persona'] = normalizePersona('partner', voices[profile['voice']] ?? true);
    if ((profile['display_name'] as String).isEmpty && session!.displayName.isNotEmpty) {
      profile['display_name'] = session!.displayName;
    }
    final mem = await store.readJson(uid, 'memory.json');
    memories = ((mem['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    archive = ChatArchive(store, uid);
    pastPoints = await archive!.recentPoints();
    final hist = await store.readJson(uid, 'chat.json');
    chat = ((hist['items'] as List?) ?? []).map((e) => Map<String, String>.from(e as Map)).toList();
    final key = await store.geminiKey(uid) ?? '';
    geminiActive = key.isNotEmpty;
    geminiMasked = geminiActive ? maskKey(key) : '';
    _brain = geminiActive ? Brain(key) : null;
    notifyListeners();
    _startEvents();
    unawaited(_startLink());
    if (geminiActive) unawaited(summariseFinished()); // points for conversations from earlier days
    if (geminiActive && profile['hands_free'] == true) unawaited(startLoop());
    if (geminiActive) {
      if (await checkGeminiKey(key) == KeyCheck.invalid) {
        geminiActive = false;
        _brain = null;
        await stopLoop();
        notifyListeners();
      }
    }
  }

  Future<void> _start(Session s) async {
    session = s;
    await store.saveSession(s);
    await _loadUser();
  }

  Future<void> register(String login, String pass, String name) async => _start(await auth.register(login, pass, name));
  Future<void> login(String login, String pass) async => _start(await auth.login(login, pass));
  Future<void> loginGoogle() async => _start(await auth.google());
  Future<void> sendReset(String email) => auth.sendPasswordReset(email);

  /// Is this login an account saved on this device (then the password can be reset right here)?
  Future<bool> isDeviceAccount(String login) => auth.local.exists(login);

  /// Forgot password (device account): new password, then logged in. For safety the saved Gemini key is
  /// removed and must be added again; chats, memories and settings stay.
  Future<void> resetDevicePassword(String login, String newPassword) async {
    final s = await auth.local.resetPassword(login, newPassword);
    await store.deleteGeminiKey(s.uid);
    await _start(s);
  }

  Future<void> logout() async {
    await stopLoop();
    await _eventsSub?.cancel();
    await link?.stop();
    link = null;
    if (session?.provider == 'google') await auth.signOutGoogle();
    await store.clearSession();
    session = null;
    profile = Map.of(_defaults);
    memories = [];
    chat = [];
    archive = null;
    pastPoints = [];
    geminiActive = false;
    _brain = null;
    voice = VoiceState.idle;
    notifyListeners();
  }

  // ---------- profile ----------
  Future<void> setPref(String key, Object value) async {
    profile = {...profile, key: value};
    notifyListeners();
    await store.writeJson(uid, 'profile.json', profile);
    if (key == 'hands_free') value == true ? unawaited(startLoop()) : await stopLoop();
    if (key == 'live_mode' && _loopOn) {
      await stopLoop();
      await Future.delayed(const Duration(milliseconds: 400));
      unawaited(startLoop());
    }
    // a new voice/role/name takes effect from the next live connection
    if (['persona', 'voice', 'voice_quality', 'call_me', 'speech_language', 'display_name'].contains(key) && _live != null) {
      unawaited(_live!.close());
      _live = null;
      if (_loopOn) unawaited(_ensureLive());
    }
  }

  Future<void> rename(String newName) async {
    final n = newName.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (n == name) return;
    if (n.runes.where((r) => String.fromCharCode(r).trim().isNotEmpty).length < 2 || n.length > 20) {
      throw AppError('NAME_TOO_SHORT');
    }
    if (renamesLeft <= 0) throw AppError('RENAME_LIMIT');
    profile = {...profile, 'assistant_name': n, 'renames_used': (profile['renames_used'] as int) + 1};
    notifyListeners();
    await store.writeJson(uid, 'profile.json', profile);
    if (_live != null) {
      unawaited(_live!.close());
      _live = null;
    }
  }

  /// Licence key: format is checked now; it is verified online once the licence server is connected.
  Future<void> saveLicense(String key) async {
    final k = key.trim().toUpperCase().replaceAll(' ', '');
    if (!licenseFormat.hasMatch(k)) throw AppError('BAD_KEY');
    await setPref('license_key', k);
  }

  // ---------- Gemini key ----------
  Future<KeyCheck> activateGeminiKey(String key) async {
    final k = key.trim();
    final res = await checkGeminiKey(k);
    if (res == KeyCheck.valid) {
      await store.setGeminiKey(uid, k);
      geminiActive = true;
      geminiMasked = maskKey(k);
      _brain = Brain(k);
      notifyListeners();
      if (profile['hands_free'] == true) unawaited(startLoop());
    }
    return res;
  }

  Future<void> removeGeminiKey() async {
    await stopLoop();
    await store.deleteGeminiKey(uid);
    geminiActive = false;
    geminiMasked = '';
    _brain = null;
    notifyListeners();
  }

  // ---------- memory ----------
  Future<void> addMemory(String text, {String kind = 'personal'}) async {
    final tx = text.trim();
    if (tx.isEmpty) return;
    if (isSensitive(tx)) throw AppError('SENSITIVE');
    if (memories.length >= maxMemories) throw AppError('MEMORY_LIMIT');
    if (memories.any((m) => (m['text'] as String).toLowerCase() == tx.toLowerCase())) return;
    memories = [
      {'id': DateTime.now().microsecondsSinceEpoch.toString(), 'text': tx, 'kind': kind},
      ...memories,
    ];
    notifyListeners();
    await store.writeJson(uid, 'memory.json', {'items': memories});
  }

  Future<void> deleteMemory(String id) async {
    memories = memories.where((m) => m['id'] != id).toList();
    notifyListeners();
    await store.writeJson(uid, 'memory.json', {'items': memories});
  }

  /// Tommy corrects its own memory ("না, আমার অফিস এখন গুলশানে"). Returns false if nothing matched (then saved as new).
  Future<bool> updateMemory(String oldWords, String newText) async {
    final o = oldWords.trim().toLowerCase();
    final n = newText.trim();
    if (n.isEmpty) return false;
    if (isSensitive(n)) throw AppError('SENSITIVE');
    final i = o.isEmpty ? -1 : memories.indexWhere((m) => (m['text'] as String).toLowerCase().contains(o));
    if (i < 0) {
      await addMemory(n);
      return false;
    }
    memories = [...memories];
    memories[i] = {...memories[i], 'text': n};
    notifyListeners();
    await store.writeJson(uid, 'memory.json', {'items': memories});
    return true;
  }

  /// Deletes memories containing these words. Returns how many.
  Future<int> forgetMemory(String words) async {
    final w = words.trim().toLowerCase();
    if (w.length < 2) return 0;
    final before = memories.length;
    memories = memories.where((m) => !(m['text'] as String).toLowerCase().contains(w)).toList();
    final n = before - memories.length;
    if (n > 0) {
      notifyListeners();
      await store.writeJson(uid, 'memory.json', {'items': memories});
    }
    return n;
  }

  // ---------- talking ----------
  void _setVoice(VoiceState s, [String st = '']) {
    voice = s;
    status = st;
    notifyListeners();
  }

  String _system({bool live = false}) => buildSystemPrompt(
        name: name,
        female: voiceFemale,
        persona: profile['persona'] as String,
        userName: userName,
        callMe: profile['call_me'] as String,
        speechLanguage: profile['speech_language'] as String,
        memories: memories.where((m) => m['kind'] != 'rule').map((m) => m['text'] as String).take(40).toList(),
        rules: memories.where((m) => m['kind'] == 'rule').map((m) => m['text'] as String).take(30).toList(),
        handsFree: live ? profile['hands_free'] == true : _loopOn,
        platform: Platform.isAndroid ? 'android' : 'windows',
        now: DateTime.now(),
        linkedDevice: link == null ? '' : '${link!.peer} ${peerOnline ? 'online' : 'offline'}',
        pastPoints: pastPoints,
        live: live,
        recent: live ? (chat.length > 10 ? chat.sublist(chat.length - 10) : chat) : const [],
      );

  /// Mic button: if the listening loop is running, it stops it; otherwise starts listening.
  Future<void> micPressed() async {
    if (!geminiActive) {
      _setVoice(VoiceState.idle, t('need_key'));
      return;
    }
    if (voice == VoiceState.speaking || _speaker.speaking) {
      await io.stopSpeaking();
      await _speaker.stop();
      if (_loopOn) _setVoice(VoiceState.listening, t('idle'));
      return;
    }
    if (_loopOn) {
      await stopLoop();
      return;
    }
    if (profile['hands_free'] == true || _useLive) {
      _lastTalk = DateTime.now(); // pressed the button = talking to Tommy now
      unawaited(startLoop());
      return;
    }
    await _turn(handsFree: false);
  }

  /// Typed message from the text box.
  Future<void> sendText(String text) async {
    if (text.trim().isEmpty) return;
    if (!geminiActive) {
      _setVoice(VoiceState.idle, t('need_key'));
      return;
    }
    if (_loopOn && _useLive && await _ensureLive()) {
      _lastTalk = DateTime.now();
      _heardBuf.write(text.trim());
      _live!.sendText(text.trim());
      return;
    }
    io.cancel();
    await _process(typed: text.trim(), handsFree: false);
  }

  bool get _useLive =>
      profile['live_mode'] == true && !_liveUnavailable && DateTime.now().isAfter(_liveBlockedUntil);

  /// Always-listening loop (while the app runs; on Android also in the background via a foreground service).
  Future<void> startLoop() async {
    if (_loopOn || !geminiActive) return;
    if (!await io.hasMicPermission()) {
      _setVoice(VoiceState.idle, t('mic_denied'));
      return;
    }
    _loopOn = true;
    final gen = ++_loopGen;
    await Native.requestPermissions();
    await Native.startKeepAlive(name, t('bg_listening'));
    notifyListeners();
    var failures = 0;
    while (_loopOn && geminiActive && gen == _loopGen) {
      if (_useLive) {
        final byPerson = await _runLive();
        if (byPerson) break;
        continue; // Live not possible right now → classic mode below until it is
      }
      try {
        await _turn(handsFree: true, waitFor: const Duration(seconds: 25));
        failures = 0;
        if (profile['hands_free'] != true && DateTime.now().difference(_lastTalk) > const Duration(seconds: 60)) break;
      } catch (e) {
        failures++;
        _setVoice(VoiceState.idle, err(e));
        await Future.delayed(Duration(seconds: failures > 3 ? 20 : 3));
      }
    }
    if (gen != _loopGen) return; // a newer loop has started meanwhile
    _loopOn = false;
    await Native.stopKeepAlive();
    _setVoice(VoiceState.idle);
  }

  Future<void> stopLoop() async {
    _loopGen++;
    _loopOn = false;
    io.cancel();
    if (_liveExit != null && !_liveExit!.isCompleted) _liveExit!.complete(true);
    await Native.stopKeepAlive();
    _setVoice(VoiceState.idle);
  }

  // ---------- Gemini Live loop ----------
  /// Streams the mic to Gemini Live. Returns true when the person stopped it, false if Live failed.
  Future<bool> _runLive() async {
    final exit = Completer<bool>();
    _liveExit = exit;
    try {
      await _mic.start(_onMicChunk);
    } catch (e) {
      _liveBlockedUntil = DateTime.now().add(const Duration(minutes: 10));
      return false;
    }
    _setVoice(VoiceState.listening, t('idle'));
    unawaited(_speaker.warmUp());
    _liveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _liveTick());
    final byPerson = await exit.future;
    _liveTimer?.cancel();
    _backToListen?.cancel();
    await _mic.stop();
    await _speaker.stop();
    await _live?.close();
    _live = null;
    _sending = false;
    _preroll.clear();
    _queued.clear();
    io.level.add(0);
    return byPerson;
  }

  void _liveTick() {
    final now = DateTime.now();
    // close an idle connection after a minute (saves the free daily quota); reconnecting takes only ~0.15 s
    final l = _live;
    if (l != null && !_sending && !_speaker.speaking && now.difference(l.lastActivity) > const Duration(seconds: 60)) {
      unawaited(l.close());
      _live = null;
      notifyListeners();
    }
    // button-started conversation (hands-free off) ends after a minute of silence
    if (profile['hands_free'] != true && !_sending && !_speaker.speaking &&
        now.difference(_lastTalk) > const Duration(seconds: 60)) {
      unawaited(stopLoop());
    }
  }

  void _onMicChunk(Uint8List pcm, double db) {
    final now = DateTime.now();
    io.level.add(((db + 60) / 60).clamp(0.0, 1.0));
    final talking = _speaker.speaking;
    final thr = (_noise + 12).clamp(-50.0, -22.0);
    // while Tommy talks, only a clearly louder voice counts (so its own echo doesn't interrupt it)
    final need = talking ? math.max(thr + 12, _echo + 10) : thr;
    final loud = db > need;
    if (talking && !_sending) _echo = _echo * 0.9 + db * 0.1;
    if (!talking && !_sending && !loud) _noise = _noise * 0.95 + db * 0.05;

    _preroll.add(pcm);
    var bytes = _preroll.fold<int>(0, (a, b) => a + b.length);
    while (bytes > 16000 && _preroll.length > 1) {
      bytes -= _preroll.first.length; // keep ~0.5 s before the speech starts
      _preroll.removeAt(0);
    }

    if (loud) {
      _lastLoud = now;
      if (!_sending) {
        _sending = true;
        _segStart = now;
        _latencyMeasured = false;
        // words Tommy decided to ignore earlier must not stick to the next real question
        if (!_turnHadAudio && now.difference(_lastHeard) > const Duration(seconds: 6)) _heardBuf.clear();
        final pre = List<Uint8List>.of(_preroll)..removeLast();
        for (final p in pre) {
          _sendOrQueue(p);
        }
        unawaited(_ensureLive());
      }
    }
    if (!_sending) return;
    _sendOrQueue(pcm);
    // music/TV that never turns into words: treat it as background noise and stop sending
    if (now.difference(_segStart) > const Duration(seconds: 12) && _lastHeard.isBefore(_segStart)) {
      _noise = db - 2;
      _sending = false;
      _live?.audioEnded();
      return;
    }
    if (now.difference(_lastLoud) > const Duration(milliseconds: 1200)) {
      _sending = false;
      _live?.audioEnded();
    }
  }

  void _sendOrQueue(Uint8List pcm) {
    final l = _live;
    if (l != null && l.isOpen) {
      l.sendAudio(pcm);
    } else {
      _queued.add(pcm);
      var total = _queued.fold<int>(0, (a, b) => a + b.length);
      while (total > 32000 * 8 && _queued.isNotEmpty) {
        total -= _queued.first.length;
        _queued.removeAt(0);
      }
    }
  }

  Future<bool> _ensureLive() {
    if (_live?.isOpen == true) return Future.value(true);
    return _connecting ??= _openLive().whenComplete(() => _connecting = null);
  }

  Future<bool> _openLive() async {
    final brain = _brain;
    if (brain == null || !_loopOn) return false;
    String? model;
    try {
      model = await brain.liveModel(sweet: profile['voice_quality'] != 'fast');
    } catch (e) {
      _liveFailed(e);
      return false;
    }
    if (model == null) {
      _liveUnavailable = true; // this key has no Live model → classic mode
      _exitLive();
      return false;
    }
    liveModelName = model;
    for (var attempt = 0; attempt < 2; attempt++) {
      final session = LiveSession(
        apiKey: brain.key,
        model: model,
        system: _system(live: true),
        voiceName: geminiVoice[profile['voice']] ?? 'Aoede',
        functions: toolDeclarations,
        fast: _fastOk,
        onAudio: _onLiveAudio,
        onHeard: (tx) {
          _lastHeard = DateTime.now();
          _heardBuf.write(tx);
          if (!_turnAllowed && _calledByName(_heardBuf.toString())) _releaseHeld();
          if (!_speaker.speaking) {
            status = _heardBuf.toString();
            notifyListeners();
          }
        },
        onSaid: (tx) {
          _saidBuf.write(tx);
          status = _saidBuf.toString();
          notifyListeners();
        },
        onTurnComplete: _onLiveTurnDone,
        onInterrupted: () {
          unawaited(_speaker.stop());
          _onLiveTurnDone();
        },
        onCall: _runLiveTool,
        onClosed: (e) {
          _live = null;
          notifyListeners();
          _liveFailed(e);
        },
      );
      try {
        await session.connect();
        _live = session;
        _liveFailures.clear();
        for (final q in _queued) {
          session.sendAudio(q);
        }
        _queued.clear();
        if (!_sending) session.audioEnded();
        notifyListeners();
        return true;
      } on LiveError catch (e) {
        if (e.code == 'FAILED' && _fastOk) {
          _fastOk = false; // this model doesn't accept the "no thinking" setting → retry without it
          continue;
        }
        _liveFailed(e);
        return false;
      } catch (e) {
        _liveFailed(e);
        return false;
      }
    }
    return false;
  }

  void _liveFailed(Object e) {
    final code = e is LiveError ? e.code : (e is BrainError ? e.code : 'FAILED');
    if (code == 'CLOSED') return; // normal end of a connection; _liveTick reconnects
    if (code == 'KEY_INVALID') {
      _setVoice(VoiceState.idle, trError(lang, 'AI_KEY_INVALID'));
      _liveBlockedUntil = DateTime.now().add(const Duration(minutes: 30));
      _exitLive();
      return;
    }
    if (code == 'QUOTA') {
      status = trError(lang, 'AI_QUOTA');
      notifyListeners();
      _liveBlockedUntil = DateTime.now().add(const Duration(minutes: 10));
      _exitLive();
      return;
    }
    _liveFailures.add(DateTime.now());
    _liveFailures.removeWhere((d) => DateTime.now().difference(d) > const Duration(minutes: 2));
    if (_liveFailures.length >= 3) {
      _liveBlockedUntil = DateTime.now().add(const Duration(minutes: 5)); // keep working in classic mode meanwhile
      _exitLive();
    }
  }

  void _exitLive() {
    if (_liveExit != null && !_liveExit!.isCompleted) _liveExit!.complete(false);
  }

  /// Hands-free: is this speech meant for Tommy? (said its name / "hey…", or we are mid-conversation)
  bool get _conversationActive =>
      profile['hands_free'] != true || DateTime.now().difference(_lastTalk) < const Duration(seconds: 45);

  bool _calledByName(String heard) {
    final h = heard.toLowerCase().trim();
    if (h.isEmpty) return false;
    final n = name.toLowerCase();
    if (h.contains(n)) return true;
    const wakes = ['hey', 'hei', 'hi ', 'হেই', 'হে ', 'এই ', 'ওই ', 'tommy', 'tomi', 'টমি', 'हे ', 'हेय'];
    final start = h.length > 14 ? h.substring(0, 14) : h;
    return wakes.any(start.contains) || wakes.any((w) => w.length > 3 && h.contains(w));
  }

  void _releaseHeld() {
    _turnAllowed = true;
    for (final p in _held) {
      _onLiveAudio(p);
    }
    _held.clear();
  }

  void _onLiveAudio(Uint8List pcm) {
    if (!_turnAllowed) {
      if (_conversationActive || _calledByName(_heardBuf.toString())) {
        _turnAllowed = true;
      } else {
        _held.add(pcm); // wait for the words: answer only if Tommy was called
        return;
      }
    }
    _backToListen?.cancel();
    if (!_turnHadAudio && !_latencyMeasured) {
      final ms = DateTime.now().difference(_lastLoud).inMilliseconds;
      if (ms > 0 && ms < 20000) lastLatencyMs = ms;
      _latencyMeasured = true;
    }
    _turnHadAudio = true;
    _lastTalk = DateTime.now();
    if (voice != VoiceState.speaking) {
      voice = VoiceState.speaking;
      notifyListeners();
    }
    unawaited(_speaker.add(pcm));
  }

  void _onLiveTurnDone() {
    if (!_turnAllowed && _held.isNotEmpty) {
      if (_calledByName(_heardBuf.toString())) {
        _releaseHeld();
      } else {
        // not meant for Tommy (TV, people talking) → stay quiet
        _held.clear();
        _heardBuf.clear();
        _saidBuf.clear();
        _turnHadAudio = false;
        return;
      }
    }
    _turnAllowed = false;
    unawaited(_speaker.finish());
    final heard = _heardBuf.toString().trim();
    final said = _saidBuf.toString().trim();
    _heardBuf.clear();
    _saidBuf.clear();
    if (said.isNotEmpty || _turnHadAudio) {
      _lastTalk = DateTime.now();
      unawaited(_addTurn(heard, said));
    }
    _turnHadAudio = false;
    _backToListen?.cancel();
    final wait = _speaker.endsAt.difference(DateTime.now());
    _backToListen = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (_loopOn) _setVoice(VoiceState.listening, said.isNotEmpty ? said : t('idle'));
    });
  }

  Future<void> _addTurn(String heard, String said) async {
    if (heard.isEmpty && said.isEmpty) return;
    chat = [
      ...chat,
      if (heard.isNotEmpty) {'role': 'user', 'text': heard},
      if (said.isNotEmpty) {'role': 'model', 'text': said},
    ];
    if (chat.length > 60) chat = chat.sublist(chat.length - 60);
    notifyListeners();
    unawaited(store.writeJson(uid, 'chat.json', {'items': chat}));
    if (heard.isNotEmpty) await archive?.add('user', heard);
    if (said.isNotEmpty) await archive?.add('model', said);
    unawaited(summariseFinished());
  }

  /// Runs one function Gemini Live asked for and tells it how it went.
  Future<Map<String, dynamic>> _runLiveTool(LiveCall c) async {
    if (!_conversationActive && !_calledByName(_heardBuf.toString())) {
      return fail('Ignored: that speech was not addressed to you. Stay silent.');
    }
    _turnAllowed = true;
    _lastTalk = DateTime.now();
    final device = (c.args['device'] ?? '').toString();
    if ((device == 'pc' || device == 'phone') && device != DeviceLink.thisDevice) {
      if (link == null) return fail('No other device is linked. Link it with the QR code in Settings.');
      if (!peerOnline) return fail('The $device is offline.');
      final sent = await link!.sendCommand(c.name, jsonEncode(c.args), '__json');
      return sent ? ok({'sent_to': device, 'note': 'The other device does it now; its result is not reported back.'})
          : fail('Could not reach the $device.');
    }
    status = t('working');
    notifyListeners();
    final r = await runTool(c.name, c.args);
    if (r['ok'] != true) status = t('stuck');
    notifyListeners();
    return r;
  }

  /// Every action Tommy can do (from Gemini Live, or sent from the linked device).
  Future<Map<String, dynamic>> runTool(String name, Map<String, dynamic> a) async {
    String arg(String k) => (a[k] ?? '').toString().trim();
    switch (name) {
      case 'look_at_screen':
      case 'click_on':
        final brain = _brain;
        if (brain == null) return fail('no AI key');
        if (!Platform.isWindows) {
          final scr = await Native.screen();
          return scr == null ? fail('Turn on Tommy hands in Settings to let me see the phone screen.') : ok(scr);
        }
        final shot = await Pc.screenshot();
        if (shot == null) return fail('Could not take a screenshot.');
        try {
          if (name == 'look_at_screen') return ok({'screen': await brain.vision(shot, arg('question'))});
          final p = await brain.locate(shot, arg('target'));
          if (p == null) return fail('"${arg('target')}" is not visible on the screen.', {'screen': await brain.vision(shot, 'What is on the screen?')});
          return await Pc.clickAt(p.$1, p.$2, double: a['double'] == true) ? ok({'clicked_at': [p.$1, p.$2]}) : fail('Could not click.');
        } catch (e) {
          return fail(err(e));
        }
      case 'remember':
        try {
          await addMemory(arg('fact'), kind: arg('kind') == 'rule' ? 'rule' : 'personal');
          return ok({'saved': arg('fact')});
        } catch (e) {
          return fail(err(e));
        }
      case 'update_memory':
        return await updateMemory(arg('old'), arg('new')) ? ok() : fail('That memory was not found, so it was saved as new.');
      case 'forget':
        final n = await forgetMemory(arg('fact'));
        return n > 0 ? ok({'deleted': n}) : fail('No memory matched "${arg('fact')}".');
      case 'recall':
        final found = await archive?.search(arg('query')) ?? const <String>[];
        return found.isEmpty ? fail('Nothing found in earlier conversations.') : ok({'found': found});
      case 'research':
        final brain = _brain;
        if (brain == null) return fail('no AI key');
        final deep = a['deep'] == true;
        status = t(deep ? 'deep_researching' : 'researching');
        notifyListeners();
        try {
          final text = await brain.research(arg('question'), deep: deep, language: profile['speech_language'] as String);
          if (text.isEmpty) return fail('Nothing found.');
          await _addTurn('', text);
          return ok({'answer': text.length > 4000 ? text.substring(0, 4000) : text});
        } catch (e) {
          return fail(err(e));
        }
      case 'stop_listening':
        Timer(const Duration(seconds: 3), () => unawaited(stopLoop()));
        return ok();
    }
    return runDeviceTool(name, a);
  }

  Future<void> _turn({required bool handsFree, Duration waitFor = const Duration(seconds: 8)}) async {
    if (_busy) {
      await Future.delayed(const Duration(milliseconds: 300));
      return;
    }
    _setVoice(VoiceState.listening, handsFree ? t('idle') : t('listening'));
    final wav = await io.listenOnce(waitFor: waitFor);
    if (wav == null) {
      if (!handsFree) _setVoice(VoiceState.idle);
      return;
    }
    await _process(wav: wav, handsFree: handsFree);
  }

  Future<void> _process({Uint8List? wav, String? typed, required bool handsFree}) async {
    final brain = _brain;
    if (brain == null) return;
    _busy = true;
    try {
      _setVoice(VoiceState.thinking, t('thinking'));
      final event = _pendingEvent;
      var r = await brain.think(
        system: _system(),
        history: chat,
        wav: wav,
        typed: typed,
        event: event,
      );
      if (r.action == 'recall' && !r.ignore) {
        // look it up in all earlier conversations, then let the brain answer from what was found
        final pre = r.reply.isNotEmpty ? _say(r.reply) : Future<void>.value();
        final found = await archive?.search('${r.arg} ${r.heard}') ?? const <String>[];
        final heard = r.heard;
        r = await brain.think(
          system: _system(),
          history: chat,
          typed: heard.isNotEmpty ? heard : (typed ?? ''),
          event: '[Recall results for "${r.arg}"]\n${found.isEmpty ? '(nothing found)' : found.join('\n')}',
        );
        if (r.heard.isEmpty) r = BrainReply(heard: heard, reply: r.reply, action: r.action == 'recall' ? 'none' : r.action,
            arg: r.arg, text: r.text, remember: r.remember, on: r.on);
        if (r.action == 'recall') r = BrainReply(heard: r.heard, reply: r.reply, remember: r.remember);
        await pre; // finish "let me remember…" before the answer
      }
      if ((r.action == 'research' || r.action == 'deep_research') && !r.ignore) {
        final deep = r.action == 'deep_research';
        final pre = r.reply.isNotEmpty ? _say(r.reply) : Future<void>.value();
        status = t(deep ? 'deep_researching' : 'researching');
        notifyListeners();
        final question = r.arg.isNotEmpty ? r.arg : r.heard;
        final answer = await brain.research(question, deep: deep, language: profile['speech_language'] as String);
        await pre;
        final heard = r.heard.isNotEmpty ? r.heard : (typed ?? question);
        await _addTurn(heard, answer.isEmpty ? '…' : answer);
        r = await brain.think(
          system: _system(),
          history: chat,
          typed: heard,
          event: '[Research results — the full answer is already shown on screen. Say the main answer in 2-3 short '
              'spoken sentences, then "বিস্তারিত স্ক্রিনে দিলাম".]\n$answer',
        );
        _pendingEvent = null;
        if (r.reply.isNotEmpty) {
          chat = [...chat, {'role': 'model', 'text': r.reply}];
          await _say(r.reply);
        }
        _setVoice(handsFree ? VoiceState.listening : VoiceState.idle, '');
        return;
      }
      if (r.ignore || (r.reply.isEmpty && r.action == 'none')) {
        _setVoice(handsFree ? VoiceState.listening : VoiceState.idle, handsFree ? t('idle') : '');
        return;
      }
      _pendingEvent = null;
      chat = [
        ...chat,
        {'role': 'user', 'text': r.heard.isNotEmpty ? r.heard : (typed ?? '…')},
        {'role': 'model', 'text': r.reply},
      ];
      if (chat.length > 60) chat = chat.sublist(chat.length - 60);
      unawaited(store.writeJson(uid, 'chat.json', {'items': chat}));
      await archive?.add('user', r.heard.isNotEmpty ? r.heard : (typed ?? ''));
      await archive?.add('model', r.reply);
      if (r.remember.trim().isNotEmpty) {
        try {
          final rule = RegExp(r'^(rule|নিয়ম)\s*[:：-]', caseSensitive: false).hasMatch(r.remember.trim()) ||
              RegExp(r'(next time|এরপর|পরের বার|সবসময়|always)', caseSensitive: false).hasMatch(r.remember);
          await addMemory(r.remember, kind: rule ? 'rule' : 'personal');
        } catch (_) {}
      }
      if (r.action == 'stop') {
        await _say(r.reply);
        await stopLoop();
        return;
      }
      final target = r.on == 'here' ? DeviceLink.thisDevice : r.on;
      if (r.action != 'none' && target != DeviceLink.thisDevice) {
        final sent = peerOnline && await link!.sendCommand(r.action, r.arg, r.text);
        await _say(sent ? r.reply : t('peer_offline', vars: {'dev': t(target == 'pc' ? 'dev_pc' : 'dev_phone')}));
      } else {
        final say = _say(r.reply);
        if (r.action != 'none') await runAction(r);
        await say;
      }
      _setVoice(handsFree ? VoiceState.listening : VoiceState.idle, '');
    } finally {
      _busy = false;
      unawaited(summariseFinished());
    }
  }

  /// Turns finished conversations into bullet points (runs quietly in the background, one at a time).
  Future<void> summariseFinished({bool includeCurrent = false}) async {
    final a = archive;
    final brain = _brain;
    if (a == null || brain == null || _summarising) return;
    _summarising = true;
    try {
      for (var i = 0; i < 5; i++) {
        final next = await a.nextToSummarise(includeCurrent: includeCurrent);
        if (next == null) break;
        final (chunk, until) = next;
        final transcript = chunk
            .map((t) => '${(t['ts'] as String).substring(0, 16).replaceFirst('T', ' ')} '
                '${t['role'] == 'user' ? (userName.isEmpty ? 'Person' : userName) : name}: ${t['text']}')
            .join('\n');
        final points = (await brain.summarise(transcript)).where((p) => !isSensitive(p)).toList();
        await a.addSummary(chunk, until, points);
      }
      pastPoints = await a.recentPoints();
      notifyListeners();
    } catch (_) {
      // try again after the next conversation
    } finally {
      _summarising = false;
    }
  }

  Future<void> clearHistory() async {
    await archive?.deleteAll();
    chat = [];
    pastPoints = [];
    await store.writeJson(uid, 'chat.json', {'items': chat});
    notifyListeners();
  }

  Future<void> _say(String text) async {
    if (text.trim().isEmpty) return;
    _setVoice(VoiceState.speaking, text);
    final brain = _brain;
    final wav = brain == null
        ? null
        : await brain.speak(text, geminiVoice[profile['voice']] ?? 'Aoede', style: ttsStyle(profile['persona'] as String));
    if (wav != null) {
      await io.playWav(wav);
    } else {
      await io.speakDevice(text, profile['speech_language'] == 'auto' ? lang : profile['speech_language'] as String);
    }
  }

  // ---------- PC ↔ phone link (QR) ----------
  Future<void> _startLink() async {
    await link?.stop();
    link = null;
    final p = Pairing.fromJson(await store.pairing(uid));
    if (p == null) return;
    await _connectLink(p);
  }

  Future<void> _connectLink(Pairing p) async {
    await link?.stop();
    final l = DeviceLink(
      me: DeviceLink.thisDevice,
      myName: Platform.isAndroid ? '${userName.isEmpty ? '' : '$userName-এর '}Phone' : Platform.localHostname,
      pairing: p,
      onChange: () {
        if (pendingPairing != null && link?.peerOnline == true) {
          pendingPairing = null; // the phone scanned the PC's QR
          unawaited(store.setPairing(uid, link!.pairing.withPeer(link!.peerName).toJson()));
        }
        notifyListeners();
      },
      onMessage: _onLinkMessage,
    );
    link = l;
    notifyListeners();
    await l.start();
  }

  /// PC: make a new QR and wait for the phone.
  Future<Pairing> newPairingQr() async {
    _qrShownAt = DateTime.now();
    final p = Pairing.create();
    pendingPairing = p;
    await store.setPairing(uid, p.toJson());
    await _connectLink(p);
    return p;
  }

  /// Phone: scanned the PC's QR.
  Future<bool> pairFromQr(String raw) async {
    final p = Pairing.fromQr(raw);
    if (p == null) return false;
    await link?.stop();
    await store.setPairing(uid, p.toJson());
    await _connectLink(p);
    return true;
  }

  /// Phone login page: scan the QR shown on the logged-in PC → same account here, no password.
  Future<bool> loginWithQr(String raw) async {
    final p = Pairing.fromQr(raw);
    if (p == null) return false;
    final got = Completer<Map<String, dynamic>>();
    final temp = DeviceLink(
      me: DeviceLink.thisDevice,
      myName: 'Phone',
      pairing: p,
      onChange: () {},
      onMessage: (m) {
        if (m['type'] == 'login_bundle' && !got.isCompleted) got.complete(m);
      },
    );
    await temp.start();
    final asker = Timer.periodic(const Duration(seconds: 2), (_) => temp.send({'type': 'login_req'}));
    unawaited(temp.send({'type': 'login_req'}));
    Map<String, dynamic>? b;
    try {
      b = await got.future.timeout(const Duration(seconds: 40));
    } catch (_) {
      b = null;
    }
    asker.cancel();
    await temp.stop();
    if (b == null) throw AppError('QR_LOGIN_FAILED');
    final s0 = Session.fromJson(Map<String, dynamic>.from(b['session'] as Map));
    final s = Session(uid: s0.uid, email: s0.email, displayName: s0.displayName, provider: 'qr');
    await store.writeJson(s.uid, 'profile.json', Map<String, dynamic>.from(b['profile'] as Map? ?? {}));
    final mem = (b['memories'] as List?) ?? const [];
    if (mem.isNotEmpty) await store.writeJson(s.uid, 'memory.json', {'items': mem});
    final key = (b['gemini'] ?? '').toString();
    if (key.isNotEmpty) await store.setGeminiKey(s.uid, key);
    await store.setPairing(s.uid, p.withPeer(p.peerName).toJson());
    await _start(s);
    return true;
  }

  Future<void> unpair() async {
    await link?.stop();
    link = null;
    pendingPairing = null;
    await store.setPairing(uid, null);
    notifyListeners();
  }

  Future<void> _onLinkMessage(Map<String, dynamic> m) async {
    if (m['type'] == 'login_req') {
      // the phone scanned this PC's QR on its login page → send it this account (only right after showing the QR)
      final shown = _qrShownAt;
      if (session == null || shown == null || DateTime.now().difference(shown) > const Duration(minutes: 5)) return;
      await link?.send({
        'type': 'login_bundle',
        'session': session!.toJson(),
        'profile': profile,
        'memories': memories,
        'gemini': await store.geminiKey(uid) ?? '',
      });
      return;
    }
    if (m['type'] != 'cmd') return;
    if (m['text'] == '__json') {
      Map<String, dynamic> args = {};
      try {
        args = Map<String, dynamic>.from(jsonDecode((m['arg'] ?? '{}').toString()) as Map);
      } catch (_) {}
      args.remove('device');
      status = t('remote_cmd', vars: {'dev': t(DeviceLink.thisDevice == 'pc' ? 'dev_phone' : 'dev_pc')});
      notifyListeners();
      await runTool((m['action'] ?? '').toString(), args);
      return;
    }
    final r = BrainReply(action: (m['action'] ?? 'none').toString(), arg: (m['arg'] ?? '').toString(),
        text: (m['text'] ?? '').toString());
    status = t('remote_cmd', vars: {'dev': t(DeviceLink.thisDevice == 'pc' ? 'dev_phone' : 'dev_pc')});
    notifyListeners();
    await runAction(r);
  }

  // ---------- incoming calls / messages (Android) ----------
  void _startEvents() {
    _eventsSub?.cancel();
    _eventsSub = Native.events().listen((e) async {
      if (profile['announce'] != true || !geminiActive) return;
      final key = '${e['type']}|${e['title']}|${e['text']}';
      final last = _recentEvents[key];
      if (last != null && DateTime.now().difference(last) < const Duration(seconds: 30)) return;
      _recentEvents[key] = DateTime.now();
      final who = (e['title'] ?? '').toString();
      final app = (e['app'] ?? '').toString();
      final persona = normalizePersona(profile['persona'] as String, voiceFemale);
      var callMe = profile['call_me'] as String;
      if (isPartner(persona) && (callMe.isEmpty || callMe == 'স্যার')) callMe = 'জান';
      if (persona == 'friend' && (callMe.isEmpty || callMe == 'স্যার')) callMe = 'দোস্ত';
      String line;
      if (e['type'] == 'call') {
        _pendingEvent = 'Incoming phone call from "$who" (ringing now). Ask or follow what they want: answer_call or reject_call.';
        line = t('call_announce', vars: {'who': who.isEmpty ? t('unknown') : who, 'me': callMe});
      } else {
        final text = (e['text'] ?? '').toString();
        _pendingEvent = 'New $app message from "$who": "$text". They may want you to reply (whatsapp action) or ignore it.';
        line = t('msg_announce', vars: {'who': who, 'app': app, 'text': text.length > 120 ? '${text.substring(0, 120)}…' : text, 'me': callMe});
      }
      // wake up by itself (even if it was not listening) and announce it in its own voice and role
      _lastTalk = DateTime.now();
      if (!_loopOn && _useLive) {
        unawaited(startLoop());
        for (var i = 0; i < 30 && !_loopOn; i++) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      if (_loopOn && _useLive && await _ensureLive()) {
        _live!.sendText('[Current event: $_pendingEvent] Wake up and tell me about it now in one or two short sentences '
            'in your role\'s own sweet style (e.g. "$line"), then ask what to do.');
        return;
      }
      io.cancel(); // stop the current listen so we can speak
      await Future.delayed(const Duration(milliseconds: 300));
      await _say(line);
      if (!_loopOn) await _turn(handsFree: false, waitFor: const Duration(seconds: 10));
    });
  }
}

