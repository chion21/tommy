import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Default set at build time (--dart-define=API_URL=...). The user can override it on the login
/// screen — handy while the server runs on a laptop behind a Cloudflare tunnel.
const defaultApiUrl = String.fromEnvironment('API_URL', defaultValue: '');

class ApiError implements Exception {
  final int status;
  final String code;
  final String message;
  ApiError(this.status, this.code, this.message);
  @override
  String toString() => '$code: $message';
}

class Api {
  static const _storage = FlutterSecureStorage();
  String? _token;
  String baseUrl = defaultApiUrl;

  Future<void> loadServer() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString('server_url') ?? defaultApiUrl;
  }

  Future<void> setServer(String url) async {
    var u = url.trim();
    if (u.isNotEmpty && !u.startsWith('http')) u = 'https://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    baseUrl = u;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', u);
  }

  String get deviceType => (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) ? 'phone' : 'pc';

  /// Random id created once per install and kept in secure storage.
  Future<String> deviceUid() async {
    var uid = await _storage.read(key: 'device_uid');
    if (uid == null) {
      uid = const Uuid().v4();
      await _storage.write(key: 'device_uid', value: uid);
    }
    return uid;
  }

  Future<bool> restore() async {
    await loadServer();
    _token = await _storage.read(key: 'token');
    if (_token == null) return false;
    try {
      final r = await _send('POST', '/auth/refresh', body: {'token': _token}, auth: false);
      await _saveToken(r['token'] as String);
      return true;
    } on ApiError catch (e) {
      if (e.code == 'NETWORK') return true; // offline: keep the old token (server allows 3 days)
      await clear();
      return false;
    }
  }

  Future<void> _saveToken(String t) async {
    _token = t;
    await _storage.write(key: 'token', value: t);
  }

  Future<void> clear() async {
    _token = null;
    await _storage.delete(key: 'token');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cached_me');
  }

  Future<void> register(String login, String password, String name) =>
      _send('POST', '/auth/register', body: {'login': login, 'password': password, 'display_name': name}, auth: false);

  Future<void> login(String login, String password, {bool replace = false}) async {
    final r = await _send('POST', '/auth/login', auth: false, body: {
      'login': login,
      'password': password,
      'device_uid': await deviceUid(),
      'device_type': deviceType,
      'label': deviceType == 'phone' ? 'Phone' : 'PC',
      'replace_device': replace,
    });
    await _saveToken(r['token'] as String);
  }

  Future<void> logout() async {
    try {
      await _send('POST', '/auth/logout');
    } catch (_) {}
    await clear();
  }

  Future<Map<String, dynamic>> me() async => await _send('GET', '/me') as Map<String, dynamic>;
  Future<Map<String, dynamic>> assistant() async => await _send('GET', '/assistant') as Map<String, dynamic>;
  Future<Map<String, dynamic>> updatePrefs(Map<String, String> prefs) async =>
      await _send('PATCH', '/assistant', body: prefs) as Map<String, dynamic>;
  Future<Map<String, dynamic>> rename(String name) async =>
      await _send('POST', '/assistant/rename', body: {'name': name}) as Map<String, dynamic>;
  Future<void> redeem(String key) => _send('POST', '/license/redeem', body: {'key': key});
  Future<List<dynamic>> memories() async => await _send('GET', '/memory') as List<dynamic>;
  Future<void> addMemory(String kind, String text) => _send('POST', '/memory', body: {'kind': kind, 'text': text});
  Future<void> deleteMemory(String id) => _send('DELETE', '/memory/$id');
  Future<Map<String, dynamic>> startLive() async => await _send('POST', '/live/session') as Map<String, dynamic>;
  Future<void> endLive(String id, int usedSeconds) =>
      _send('POST', '/live/session/$id/end', body: {'used_seconds': usedSeconds});

  Future<dynamic> _send(String method, String path, {Object? body, bool auth = true}) async {
    if (baseUrl.isEmpty) throw ApiError(0, 'NO_SERVER', 'Server address not set');
    final uri = Uri.parse('$baseUrl$path');
    final headers = {
      'Content-Type': 'application/json',
      if (auth && _token != null) 'Authorization': 'Bearer $_token',
    };
    http.Response res;
    try {
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) req.body = jsonEncode(body);
      res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 20)));
    } catch (_) {
      throw ApiError(0, 'NETWORK', 'No connection');
    }
    final data = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      final d = (data is Map && data['detail'] is Map) ? data['detail'] as Map : const {};
      throw ApiError(res.statusCode, (d['code'] ?? 'ERROR').toString(), (d['message'] ?? res.body).toString());
    }
    return data;
  }
}
