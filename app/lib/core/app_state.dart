import 'package:flutter/material.dart';

import 'auth.dart';
import 'gemini.dart';
import 'store.dart';
import 'strings.dart';
import 'themes.dart';

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
};

const voices = <String, bool>{'aoede': true, 'kore': true, 'leda': true, 'puck': false, 'charon': false}; // true = female

final _card = RegExp(r'(?:\d[ -]?){12,19}');
final _secretWords = RegExp(r'(password|passcode|\bpin\b|otp|cvv|পাসওয়ার্ড|পিন|ওটিপি|पासवर्ड)', caseSensitive: false);
bool isSensitive(String t) => _card.hasMatch(t) || _secretWords.hasMatch(t);

/// Everything the UI needs. All personal data lives in the logged-in person's own folder.
class AppState extends ChangeNotifier {
  final auth = Auth();
  final store = Store();

  bool ready = false;
  Session? session;
  Map<String, dynamic> profile = Map.of(_defaults);
  List<Map<String, dynamic>> memories = [];
  bool geminiActive = false;
  String geminiMasked = '';
  VoiceState voice = VoiceState.idle;

  bool get loggedIn => session != null;
  String get uid => session!.uid;
  String get lang => profile['ui_language'] as String;
  String get name => profile['assistant_name'] as String;
  int get renamesLeft => maxRenames - (profile['renames_used'] as int);
  String get userName {
    final n = (profile['display_name'] as String).trim();
    if (n.isNotEmpty) return n;
    if (session != null && session!.displayName.isNotEmpty) return session!.displayName;
    return session?.email.split('@').first ?? '';
  }

  TommyTheme get theme => themeById(profile['theme'] as String);
  Character get character => characterById(profile['character'] as String);

  String t(String key, {Map<String, String> vars = const {}}) =>
      tr(lang, key, vars: {'name': name, 'user': userName, ...vars});
  String err(Object e) => e is AuthError ? trError(lang, e.code) : e is AppError ? trError(lang, e.code) : e.toString();

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
    final key = await store.geminiKey(uid) ?? '';
    geminiActive = key.isNotEmpty;
    geminiMasked = geminiActive ? maskKey(key) : '';
    notifyListeners();
    if (geminiActive) {
      // quietly re-check: a revoked key switches off; no internet keeps it on
      if (await checkGeminiKey(key) == KeyCheck.invalid) {
        geminiActive = false;
        notifyListeners();
      }
    }
  }

  Future<void> _start(Session s) async {
    session = s;
    await store.saveSession(s);
    await _loadUser();
  }

  Future<void> register(String email, String pass, String name) async => _start(await auth.register(email, pass, name));
  Future<void> login(String email, String pass) async => _start(await auth.login(email, pass));
  Future<void> loginGoogle() async => _start(await auth.google());
  Future<void> sendReset(String email) => auth.sendPasswordReset(email);

  Future<void> loginOffline(String displayName) async {
    await _start(Session(uid: 'local', email: '', displayName: displayName.trim(), provider: 'offline'));
    if (displayName.trim().isNotEmpty) await setPref('display_name', displayName.trim());
  }

  Future<void> logout() async {
    if (session?.provider == 'google') await auth.signOutGoogle();
    await store.clearSession();
    session = null;
    profile = Map.of(_defaults);
    memories = [];
    geminiActive = false;
    voice = VoiceState.idle;
    notifyListeners();
  }

  // ---------- profile ----------
  Future<void> setPref(String key, Object value) async {
    profile = {...profile, key: value};
    notifyListeners();
    await store.writeJson(uid, 'profile.json', profile);
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

  // ---------- Gemini key ----------
  /// Saves the key only if Google confirms it works.
  Future<KeyCheck> activateGeminiKey(String key) async {
    final k = key.trim();
    final res = await checkGeminiKey(k);
    if (res == KeyCheck.valid) {
      await store.setGeminiKey(uid, k);
      geminiActive = true;
      geminiMasked = maskKey(k);
      notifyListeners();
    }
    return res;
  }

  Future<void> removeGeminiKey() async {
    await store.deleteGeminiKey(uid);
    geminiActive = false;
    geminiMasked = '';
    notifyListeners();
  }

  // ---------- memory ----------
  Future<void> addMemory(String text) async {
    final tx = text.trim();
    if (tx.isEmpty) return;
    if (isSensitive(tx)) throw AppError('SENSITIVE');
    if (memories.length >= maxMemories) throw AppError('MEMORY_LIMIT');
    memories = [
      {'id': DateTime.now().microsecondsSinceEpoch.toString(), 'text': tx, 'kind': 'personal'},
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

  void setVoice(VoiceState s) {
    voice = s;
    notifyListeners();
  }
}
