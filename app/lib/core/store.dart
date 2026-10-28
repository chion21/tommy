import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'auth.dart';

/// Each person gets their own folder: <app data>/users/<uid>/ (profile.json, memory.json).
/// Secrets (Gemini key, login token) go to the OS secure storage, also keyed by uid.
class Store {
  static const _secure = FlutterSecureStorage();

  Future<Directory> userDir(String uid) async {
    final base = await getApplicationSupportDirectory();
    final safe = uid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final dir = Directory('${base.path}${Platform.pathSeparator}users${Platform.pathSeparator}$safe');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Map<String, dynamic>> readJson(String uid, String name) async {
    final f = File('${(await userDir(uid)).path}${Platform.pathSeparator}$name');
    if (!await f.exists()) return {};
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> writeJson(String uid, String name, Map<String, dynamic> data) async {
    final f = File('${(await userDir(uid)).path}${Platform.pathSeparator}$name');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    await tmp.rename(f.path); // atomic replace, no half-written files
  }

  // ---- session ----
  Future<Session?> loadSession() async {
    final s = await _secure.read(key: 'session');
    if (s == null) return null;
    try {
      return Session.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSession(Session s) => _secure.write(key: 'session', value: jsonEncode(s.toJson()));
  Future<void> clearSession() => _secure.delete(key: 'session');

  // ---- Gemini key (per user) ----
  Future<String?> geminiKey(String uid) => _secure.read(key: 'gemini_key_$uid');
  Future<void> setGeminiKey(String uid, String key) => _secure.write(key: 'gemini_key_$uid', value: key);
  Future<void> deleteGeminiKey(String uid) => _secure.delete(key: 'gemini_key_$uid');

  // ---- Claude API key (per user) ----
  Future<String?> claudeKey(String uid) => _secure.read(key: 'claude_key_$uid');
  Future<void> setClaudeKey(String uid, String key) => _secure.write(key: 'claude_key_$uid', value: key);
  Future<void> deleteClaudeKey(String uid) => _secure.delete(key: 'claude_key_$uid');

  // ---- PC ↔ phone pairing (per user) ----
  Future<Map<String, dynamic>?> pairing(String uid) async {
    final s = await _secure.read(key: 'pair_$uid');
    if (s == null) return null;
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> setPairing(String uid, Map<String, dynamic>? p) =>
      p == null ? _secure.delete(key: 'pair_$uid') : _secure.write(key: 'pair_$uid', value: jsonEncode(p));
}
