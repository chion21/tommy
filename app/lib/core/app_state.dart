import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'actions.dart';
import 'auth.dart';
import 'brain.dart';
import 'gemini.dart';
import 'native.dart';
import 'persona.dart';
import 'store.dart';
import 'strings.dart';
import 'themes.dart';
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
  final Map<String, DateTime> _recentEvents = {};

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
    if ((profile['display_name'] as String).isEmpty && session!.displayName.isNotEmpty) {
      profile['display_name'] = session!.displayName;
    }
    final mem = await store.readJson(uid, 'memory.json');
    memories = ((mem['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    final hist = await store.readJson(uid, 'chat.json');
    chat = ((hist['items'] as List?) ?? []).map((e) => Map<String, String>.from(e as Map)).toList();
    final key = await store.geminiKey(uid) ?? '';
    geminiActive = key.isNotEmpty;
    geminiMasked = geminiActive ? maskKey(key) : '';
    _brain = geminiActive ? Brain(key) : null;
    notifyListeners();
    _startEvents();
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

  Future<void> logout() async {
    await stopLoop();
    await _eventsSub?.cancel();
    if (session?.provider == 'google') await auth.signOutGoogle();
    await store.clearSession();
    session = null;
    profile = Map.of(_defaults);
    memories = [];
    chat = [];
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

  // ---------- talking ----------
  void _setVoice(VoiceState s, [String st = '']) {
    voice = s;
    status = st;
    notifyListeners();
  }

  String _system() => buildSystemPrompt(
        name: name,
        female: voiceFemale,
        persona: profile['persona'] as String,
        userName: userName,
        callMe: profile['call_me'] as String,
        speechLanguage: profile['speech_language'] as String,
        memories: memories.map((m) => m['text'] as String).take(40).toList(),
        handsFree: _loopOn,
        platform: Platform.isAndroid ? 'android' : 'windows',
        now: DateTime.now(),
      );

  /// Mic button: if the always-listening loop is running, it stops/starts it; otherwise listens once.
  Future<void> micPressed() async {
    if (!geminiActive) {
      _setVoice(VoiceState.idle, t('need_key'));
      return;
    }
    if (voice == VoiceState.speaking) {
      await io.stopSpeaking();
      return;
    }
    if (_loopOn) {
      await stopLoop();
      return;
    }
    if (profile['hands_free'] == true) {
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
    io.cancel();
    await _process(typed: text.trim(), handsFree: false);
  }

  /// Always-listening loop (while the app runs; on Android also in the background via a foreground service).
  Future<void> startLoop() async {
    if (_loopOn || !geminiActive) return;
    if (!await io.hasMicPermission()) {
      _setVoice(VoiceState.idle, t('mic_denied'));
      return;
    }
    _loopOn = true;
    await Native.requestPermissions();
    await Native.startKeepAlive(name, t('bg_listening'));
    notifyListeners();
    var failures = 0;
    while (_loopOn && geminiActive) {
      try {
        await _turn(handsFree: true, waitFor: const Duration(seconds: 25));
        failures = 0;
      } catch (e) {
        failures++;
        _setVoice(VoiceState.idle, err(e));
        await Future.delayed(Duration(seconds: failures > 3 ? 20 : 3));
      }
    }
    _loopOn = false;
    _setVoice(VoiceState.idle);
  }

  Future<void> stopLoop() async {
    _loopOn = false;
    io.cancel();
    await Native.stopKeepAlive();
    _setVoice(VoiceState.idle);
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
      final r = await brain.think(
        system: _system(),
        history: chat,
        wav: wav,
        typed: typed,
        event: event,
      );
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
      if (r.remember.trim().isNotEmpty) {
        try {
          await addMemory(r.remember, kind: 'personal');
        } catch (_) {}
      }
      if (r.action == 'stop') {
        await _say(r.reply);
        await stopLoop();
        return;
      }
      final say = _say(r.reply);
      if (r.action != 'none') await runAction(r);
      await say;
      _setVoice(handsFree ? VoiceState.listening : VoiceState.idle, '');
    } finally {
      _busy = false;
    }
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
      final callMe = profile['call_me'] as String;
      String line;
      if (e['type'] == 'call') {
        _pendingEvent = 'Incoming phone call from "$who" (ringing now). Ask or follow what they want: answer_call or reject_call.';
        line = t('call_announce', vars: {'who': who.isEmpty ? t('unknown') : who, 'me': callMe});
      } else {
        final text = (e['text'] ?? '').toString();
        _pendingEvent = 'New $app message from "$who": "$text". They may want you to reply (whatsapp action) or ignore it.';
        line = t('msg_announce', vars: {'who': who, 'app': app, 'text': text.length > 120 ? '${text.substring(0, 120)}…' : text, 'me': callMe});
      }
      io.cancel(); // stop the current listen so we can speak
      await Future.delayed(const Duration(milliseconds: 300));
      await _say(line);
      if (!_loopOn) await _turn(handsFree: false, waitFor: const Duration(seconds: 10));
    });
  }
}

